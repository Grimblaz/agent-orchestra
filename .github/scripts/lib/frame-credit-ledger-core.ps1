#Requires -Version 7.0
<#!
.SYNOPSIS
    Pure-logic library for the frame credit-ledger pre-PR warn hook (issue #429).

    Exposes eleven functions:
      - Read-PRMetricsBlock               : parse a pipeline-metrics v4 marker out of a PR body
      - Select-LastCreditByRunIndex       : pick the highest-run_index credit for (port, adapter)
      - Test-ReviewSentinelPresent        : check for <!-- review-judge-produced-{PR} --> sentinel
      - Resolve-NotPersistedSynthesis     : synthesize not-persisted credit when sentinel present
      - Build-ReviewCreditRow             : construct a v4 review credit row from judge-rulings
                                           comment + adapter integrity contract (issue #441, Step 8b)
      - ConvertFrom-JudgeRulingsComment   : parse the <!-- judge-rulings --> YAML block from a
                                           PR comment body into structured finding objects
      - Get-PortFiles                     : enumerate frame/ports/*.yaml as objects
      - Resolve-PortStatus                : classify a single port given adapters + credit
      - Compose-Comment                   : render the warn-mode unified per-port table report
      - Compose-CommentWithCostPattern    : wrapper around Compose-Comment that appends the
                                           cost telemetry section (issue #467) when non-empty
      - Compose-PreV4ShortCircuitComment  : render the literal pre-v4 short-circuit text

    No `gh` calls, no network, no filesystem writes outside reading the ports dir.
#>

# region: shared YAML helpers ---------------------------------------------------

function script:ConvertTo-FCLNormalizedLines {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    if ([string]::IsNullOrEmpty($Text)) {
        return @()
    }

    $normalized = $Text -replace "`r`n", "`n" -replace "`r", "`n"
    return $normalized -split "`n"
}

function script:Get-FCLScalar {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Block,
        [Parameter(Mandatory)][string]$Name
    )

    if ([string]::IsNullOrEmpty($Block)) {
        return $null
    }

    $pattern = '(?m)^\s*' + [regex]::Escape($Name) + '\s*:\s*(?<value>.+?)\s*$'
    $match = [regex]::Match($Block, $pattern)
    if (-not $match.Success) {
        return $null
    }

    $value = $match.Groups['value'].Value.Trim()
    # Strip surrounding quotes (single or double) when balanced.
    if ($value.Length -ge 2) {
        $first = $value[0]
        $last = $value[$value.Length - 1]
        if (($first -eq '"' -and $last -eq '"') -or ($first -eq "'" -and $last -eq "'")) {
            $value = $value.Substring(1, $value.Length - 2)
        }
    }

    return $value
}

function script:Test-FCLYamlSane {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    # Reject obviously malformed YAML by inspecting each non-blank, non-comment line.
    # Rules (kept narrow so simple shallow YAML used by the hook always passes):
    #   1. A line whose first non-whitespace character is ':' has an empty key.
    #   2. A non-list, non-comment, non-blank line that contains no ':' is invalid.
    #   3. A double-quoted scalar value must close its quote on the same line.
    foreach ($line in (script:ConvertTo-FCLNormalizedLines $Text)) {
        $stripped = $line.Trim()
        if ([string]::IsNullOrEmpty($stripped)) { continue }
        if ($stripped.StartsWith('#')) { continue }
        if ($stripped.StartsWith('-')) { continue }

        if ($stripped.StartsWith(':')) {
            return $false
        }

        if ($stripped -notmatch ':') {
            return $false
        }

        $colonIdx = $stripped.IndexOf(':')
        if ($colonIdx -eq 0) {
            return $false
        }

        $afterColon = $stripped.Substring($colonIdx + 1).Trim()
        if ($afterColon.StartsWith('"')) {
            # Must close the double quote (not counting an escaped \").
            $rest = $afterColon.Substring(1)
            $unescaped = $rest -replace '\\"', ''
            if ($unescaped -notmatch '"') {
                return $false
            }
        }
    }

    return $true
}

# Parse a YAML list-of-mappings section (e.g. credits:, integrity_checks:).
# Returns an array of [pscustomobject] with the named fields populated when present.
function script:ConvertFrom-FCLListSection {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Block,
        [Parameter(Mandatory)][string]$SectionName,
        [Parameter(Mandatory)][string[]]$Fields
    )

    if ([string]::IsNullOrEmpty($Block)) {
        return @()
    }

    $lines = script:ConvertTo-FCLNormalizedLines $Block
    $entries = [System.Collections.Generic.List[object]]::new()
    $inSection = $false
    $sectionIndent = -1
    $current = $null

    $sectionPattern = '^(?<indent>\s*)' + [regex]::Escape($SectionName) + '\s*:\s*$'

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        if ($null -eq $line) { continue }

        if (-not $inSection) {
            $m = [regex]::Match($line, $sectionPattern)
            if ($m.Success) {
                $inSection = $true
                $sectionIndent = $m.Groups['indent'].Value.Length
            }
            continue
        }

        # Skip blanks and comments inside the section.
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $trimmed = $line.TrimStart()
        if ($trimmed.StartsWith('#')) { continue }

        # Determine line indentation.
        $indent = $line.Length - $trimmed.Length

        # Section ends when we encounter a same-or-lower-indent non-list key.
        if ($indent -le $sectionIndent -and -not $trimmed.StartsWith('-')) {
            break
        }

        if ($trimmed.StartsWith('- ') -or $trimmed -eq '-') {
            # Start a new entry. Push the previous one if it exists.
            if ($null -ne $current) {
                $entries.Add([pscustomobject]$current) | Out-Null
            }
            $current = [ordered]@{}
            foreach ($f in $Fields) { $current[$f] = $null }

            # The remainder of the dash line may carry the first key:value pair.
            $rest = $trimmed.Substring(1).TrimStart()
            if (-not [string]::IsNullOrEmpty($rest)) {
                $kv = [regex]::Match($rest, '^(?<key>[A-Za-z0-9_-]+)\s*:\s*(?<value>.*)$')
                if ($kv.Success) {
                    $key = $kv.Groups['key'].Value
                    $val = $kv.Groups['value'].Value.Trim()
                    if ($val.Length -ge 2) {
                        $first = $val[0]; $last = $val[$val.Length - 1]
                        if (($first -eq '"' -and $last -eq '"') -or ($first -eq "'" -and $last -eq "'")) {
                            $val = $val.Substring(1, $val.Length - 2)
                        }
                    }
                    if ($Fields -contains $key) {
                        $current[$key] = $val
                    }
                }
            }
            continue
        }

        # Continuation key:value line for the current entry.
        if ($null -ne $current) {
            $kv = [regex]::Match($trimmed, '^(?<key>[A-Za-z0-9_-]+)\s*:\s*(?<value>.*)$')
            if ($kv.Success) {
                $key = $kv.Groups['key'].Value
                $val = $kv.Groups['value'].Value.Trim()
                if ($val.Length -ge 2) {
                    $first = $val[0]; $last = $val[$val.Length - 1]
                    if (($first -eq '"' -and $last -eq '"') -or ($first -eq "'" -and $last -eq "'")) {
                        $val = $val.Substring(1, $val.Length - 2)
                    }
                }
                if ($Fields -contains $key) {
                    $current[$key] = $val
                }
            }
        }
    }

    if ($null -ne $current) {
        $entries.Add([pscustomobject]$current) | Out-Null
    }

    return $entries.ToArray()
}

# Split a list-of-mappings YAML section into per-entry raw line chunks.
# Returns an array of strings, each containing the raw lines for one `- entry`.
# Used for nested-field extraction (Findings 2 + 5: judge-score, integrity-check,
# mode.synthetic-backfill that ConvertFrom-FCLListSection cannot represent).
function script:Get-FCLEntryChunks {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Block,
        [Parameter(Mandatory)][string]$SectionName
    )

    if ([string]::IsNullOrEmpty($Block)) { return @() }

    $lines = script:ConvertTo-FCLNormalizedLines $Block
    $chunks = [System.Collections.Generic.List[string]]::new()
    $current = [System.Collections.Generic.List[string]]::new()
    $inSection = $false
    $sectionIndent = -1
    $sectionPattern = '^(?<indent>\s*)' + [regex]::Escape($SectionName) + '\s*:\s*$'

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        if ($null -eq $line) { continue }

        if (-not $inSection) {
            $m = [regex]::Match($line, $sectionPattern)
            if ($m.Success) {
                $inSection = $true
                $sectionIndent = $m.Groups['indent'].Value.Length
            }
            continue
        }

        if ([string]::IsNullOrWhiteSpace($line)) {
            if ($current.Count -gt 0) { [void]$current.Add($line) }
            continue
        }
        $trimmed = $line.TrimStart()
        $indent = $line.Length - $trimmed.Length

        # End of section: same-or-lower indent non-list key.
        if ($indent -le $sectionIndent -and -not $trimmed.StartsWith('-')) {
            break
        }

        if ($trimmed.StartsWith('- ') -or $trimmed -eq '-') {
            if ($current.Count -gt 0) {
                [void]$chunks.Add(($current -join "`n"))
                $current = [System.Collections.Generic.List[string]]::new()
            }
        }
        [void]$current.Add($line)
    }

    if ($current.Count -gt 0) {
        [void]$chunks.Add(($current -join "`n"))
    }

    # Return as a non-pipeline value to avoid PowerShell unwrapping the array
    # to its individual elements (which @() at the call site would re-wrap into
    # a flat array, not preserve the per-chunk structure).
    return $chunks.ToArray()
}

# Build a dotted-key → scalar map from a single list-entry YAML chunk.
# Handles arbitrary nesting depth driven by indentation. The leading "- " on
# the first non-blank line is normalized so the entry-marker line aligns with
# its sibling keys.
#
# Example chunk:
#   - port: review
#     mode:
#       synthetic-backfill:
#         backfilled_at: 2026-05-01T00:00:00Z
#     judge-score:
#       findings_sustained: 3
#
# Returns:
#   @{
#     'port' = 'review'
#     'mode.synthetic-backfill.backfilled_at' = '2026-05-01T00:00:00Z'
#     'judge-score.findings_sustained' = '3'
#   }
function script:Get-FCLChunkKeyMap {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Chunk)

    $map = @{}
    if ([string]::IsNullOrEmpty($Chunk)) { return $map }

    $rawLines = $Chunk -split "`n"
    # Normalize leading "- " entry marker to "  " so the first key aligns with siblings.
    $lines = @($rawLines | ForEach-Object {
            if ($_ -match '^(?<lead>\s*)-\s(?<rest>.*)$') {
                "$($Matches['lead'])  $($Matches['rest'])"
            }
            else { $_ }
        })

    $stack = [System.Collections.Generic.List[object]]::new()

    foreach ($line in $lines) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $trimmed = $line.TrimStart()
        if ($trimmed.StartsWith('#')) { continue }
        $indent = $line.Length - $trimmed.Length

        $kv = [regex]::Match($trimmed, '^(?<key>[A-Za-z0-9_-]+)\s*:\s*(?<value>.*)$')
        if (-not $kv.Success) { continue }
        $key = $kv.Groups['key'].Value
        $val = $kv.Groups['value'].Value.Trim()

        if ($val.Length -ge 2) {
            $first = $val[0]; $last = $val[$val.Length - 1]
            if (($first -eq '"' -and $last -eq '"') -or ($first -eq "'" -and $last -eq "'")) {
                $val = $val.Substring(1, $val.Length - 2)
            }
        }

        # Pop deeper-or-equal entries off the stack so we ascend back to the
        # current indent's parent before recording the key.
        while ($stack.Count -gt 0 -and $stack[$stack.Count - 1].Indent -ge $indent) {
            $stack.RemoveAt($stack.Count - 1)
        }

        if ([string]::IsNullOrEmpty($val)) {
            # Open a sub-block; push for descendants.
            [void]$stack.Add(@{ Indent = $indent; Key = $key })
        }
        else {
            $parts = @()
            foreach ($s in $stack) { $parts += $s.Key }
            $parts += $key
            $dotted = $parts -join '.'
            $map[$dotted] = $val
        }
    }

    return $map
}

# endregion ---------------------------------------------------------------------

# region: shared port-report helpers --------------------------------------------

# Normalize an adapter's SuggestedNextStep field. Treat null/whitespace and the
# literal sentinel 'none' as "no next step"; otherwise return the trimmed
# string.
function script:Resolve-FCLNextStep {
    param($Adapter)
    if ($null -eq $Adapter) { return $null }
    $step = $Adapter.SuggestedNextStep
    if ($null -eq $step) { return $null }
    $stepStr = [string]$step
    if ([string]::IsNullOrWhiteSpace($stepStr)) { return $null }
    if ($stepStr -eq 'none') { return $null }
    return $stepStr
}

# endregion ---------------------------------------------------------------------

function Read-PRMetricsBlock {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$PrBody)

    if ([string]::IsNullOrEmpty($PrBody)) {
        return $null
    }

    $normalized = $PrBody -replace "`r`n", "`n" -replace "`r", "`n"

    $match = [regex]::Match($normalized, '(?s)<!--\s*pipeline-metrics\s*(?<block>.*?)\s*-->')
    if (-not $match.Success) {
        return $null
    }

    $block = $match.Groups['block'].Value

    try {
        if (-not (script:Test-FCLYamlSane -Text $block)) {
            return [pscustomobject]@{
                MetricsVersion = 'parse-error'
                Reason         = 'Marker block contains malformed YAML (empty key, missing colon, or unterminated quoted value).'
            }
        }

        $version = script:Get-FCLScalar -Block $block -Name 'metrics_version'
        if ([string]::IsNullOrWhiteSpace($version) -or $version -ne '4') {
            return [pscustomobject]@{ MetricsVersion = 'pre-v4' }
        }

        $frameVersionRaw = script:Get-FCLScalar -Block $block -Name 'frame_version'
        $frameVersion = $null
        if (-not [string]::IsNullOrWhiteSpace($frameVersionRaw)) {
            $parsed = 0
            if ([int]::TryParse($frameVersionRaw, [ref]$parsed)) {
                $frameVersion = $parsed
            }
            else {
                $frameVersion = $frameVersionRaw
            }
        }

        $creditsRaw = script:ConvertFrom-FCLListSection -Block $block -SectionName 'credits' `
            -Fields @('port', 'adapter', 'status', 'run_index', 'evidence',
                      'terminal-step-id', 'mode_backfilled_at', 'mode_original_pr_merged_at')

        # Findings 2 + 5 (issue #441 follow-up): the flat-key parser cannot
        # represent nested credit fields. Extract per-credit raw chunks here so
        # the credit objects can carry nested data (mode.synthetic-backfill,
        # judge-score, integrity-check, version-bump, symmetric-bump-verification)
        # that real PR bodies emit per the v4 schema.
        # Cast to [string[]] so a single-credit return value stays an array
        # (PowerShell would otherwise unwrap a 1-element array to its scalar,
        # making indexed access return characters of the string instead).
        [string[]]$creditChunks = script:Get-FCLEntryChunks -Block $block -SectionName 'credits'
        if ($null -eq $creditChunks) { $creditChunks = [string[]]@() }

        $creditsList = [System.Collections.Generic.List[object]]::new()
        for ($idx = 0; $idx -lt $creditsRaw.Count; $idx++) {
                $entry = $creditsRaw[$idx]
                $chunk = if ($idx -lt $creditChunks.Count) { [string]$creditChunks[$idx] } else { '' }
                $nestedMap = if (-not [string]::IsNullOrEmpty($chunk)) { script:Get-FCLChunkKeyMap -Chunk $chunk } else { @{} }

                $runIndexRaw = [string]$entry.run_index
                $runIndexInt = $null
                if (-not [string]::IsNullOrWhiteSpace($runIndexRaw)) {
                    $parsedRunIndex = 0
                    if ([int]::TryParse($runIndexRaw, [ref]$parsedRunIndex)) {
                        $runIndexInt = $parsedRunIndex
                    }
                }

                $terminalStepIdRaw = [string]$entry.'terminal-step-id'
                $terminalStepIdInt = $null
                if (-not [string]::IsNullOrWhiteSpace($terminalStepIdRaw)) {
                    $parsedTerminalStepId = 0
                    if ([int]::TryParse($terminalStepIdRaw, [ref]$parsedTerminalStepId)) {
                        $terminalStepIdInt = $parsedTerminalStepId
                    }
                }

                # Resolve nested-or-flat backfill timestamps. Nested form
                # (`mode.synthetic-backfill.backfilled_at`) matches the schema
                # and real PR bodies; flat form (`mode_backfilled_at`) is kept
                # for backward compatibility with older test fixtures.
                $backfilledAt = $nestedMap['mode.synthetic-backfill.backfilled_at']
                if ([string]::IsNullOrWhiteSpace([string]$backfilledAt)) { $backfilledAt = [string]$entry.mode_backfilled_at }
                $originalMergedAt = $nestedMap['mode.synthetic-backfill.original_pr_merged_at']
                if ([string]::IsNullOrWhiteSpace([string]$originalMergedAt)) { $originalMergedAt = [string]$entry.mode_original_pr_merged_at }

                # Build judge-score sub-object when any judge-score.* key is present.
                $judgeScoreKeys = @($nestedMap.Keys | Where-Object { $_ -like 'judge-score.*' })
                $judgeScore = $null
                if ($judgeScoreKeys.Count -gt 0) {
                    $jsMap = [ordered]@{}
                    foreach ($k in $judgeScoreKeys) {
                        $leaf = $k.Substring('judge-score.'.Length)
                        $jsMap[$leaf] = $nestedMap[$k]
                    }
                    $judgeScore = [pscustomobject]$jsMap
                }

                # integrity-check is a scalar in real PR bodies (e.g. `integrity-check: pass`).
                $integrityCheck = $nestedMap['integrity-check']
                if ([string]::IsNullOrWhiteSpace([string]$integrityCheck)) { $integrityCheck = $null }

                # version-bump may be a scalar (`version-bump: "2.7.0 to 2.8.0"`) or
                # nested (`version-bump.from`, `version-bump.to`). Surface whichever shape exists.
                $versionBump = $nestedMap['version-bump']
                $versionBumpFrom = $nestedMap['version-bump.from']
                $versionBumpTo = $nestedMap['version-bump.to']

                $sbvStatus = $nestedMap['symmetric-bump-verification']
                if ([string]::IsNullOrWhiteSpace([string]$sbvStatus)) {
                    $sbvStatus = $nestedMap['symmetric-bump-verification.status']
                }

                [void]$creditsList.Add([pscustomobject]@{
                    Port                          = [string]$entry.port
                    Adapter                       = [string]$entry.adapter
                    Status                        = [string]$entry.status
                    RunIndex                      = $runIndexInt
                    TerminalStepId                = $terminalStepIdInt
                    Evidence                      = [string]$entry.evidence
                    ModeBackfilledAt              = if ([string]::IsNullOrWhiteSpace([string]$backfilledAt)) { $null } else { [string]$backfilledAt }
                    ModeOriginalPrMergedAt        = if ([string]::IsNullOrWhiteSpace([string]$originalMergedAt)) { $null } else { [string]$originalMergedAt }
                    JudgeScore                    = $judgeScore
                    IntegrityCheck                = $integrityCheck
                    VersionBump                   = if ([string]::IsNullOrWhiteSpace([string]$versionBump)) { $null } else { [string]$versionBump }
                    VersionBumpFrom               = if ([string]::IsNullOrWhiteSpace([string]$versionBumpFrom)) { $null } else { [string]$versionBumpFrom }
                    VersionBumpTo                 = if ([string]::IsNullOrWhiteSpace([string]$versionBumpTo)) { $null } else { [string]$versionBumpTo }
                    SymmetricBumpVerificationStatus = if ([string]::IsNullOrWhiteSpace([string]$sbvStatus)) { $null } else { [string]$sbvStatus }
                })
        }
        $credits = @($creditsList.ToArray())

        # Integrity check entries may use either 'name' or 'check' as the identifier key.
        $integrityRaw = script:ConvertFrom-FCLListSection -Block $block -SectionName 'integrity_checks' -Fields @('name', 'check', 'status', 'evidence')
        $integrityChecks = @($integrityRaw | ForEach-Object {
                $identifier = if (-not [string]::IsNullOrEmpty([string]$_.name)) { [string]$_.name } else { [string]$_.check }
                [pscustomobject]@{
                    Name     = $identifier
                    Status   = [string]$_.status
                    Evidence = [string]$_.evidence
                }
            })

        return [pscustomobject]@{
            MetricsVersion  = 4
            FrameVersion    = $frameVersion
            Credits         = $credits
            IntegrityChecks = $integrityChecks
        }
    }
    catch {
        return [pscustomobject]@{
            MetricsVersion = 'parse-error'
            Reason         = $_.Exception.Message
        }
    }
}

# ---------------------------------------------------------------------------
# Sentinel-based not-persisted synthesis (issue #441, Step 5a)
# Sentinel marker token: <!-- review-judge-produced-{PR} -->
# ---------------------------------------------------------------------------

# Returns $true when any comment in the $Comments array contains the sentinel
# token for the given PR number.
function Test-ReviewSentinelPresent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int]$PrNumber,
        [AllowEmptyCollection()][AllowNull()][object[]]$Comments
    )

    if ($null -eq $Comments -or $Comments.Count -eq 0) { return $false }

    $token = "<!-- review-judge-produced-$PrNumber -->"
    foreach ($c in $Comments) {
        $body = ''
        if ($null -ne $c.PSObject.Properties['body']) { $body = [string]$c.body }
        elseif ($c -is [System.Collections.IDictionary] -and $c.ContainsKey('body')) { $body = [string]$c['body'] }
        if ($body -like "*$token*") { return $true }
    }
    return $false
}

# Synthesizes a `review: not-persisted` credit row when:
#   - The review-judge-produced-{PR} sentinel comment is present (Path A), AND
#   - No review port credit already exists in the metrics block (Paths B/C guard).
# Returns $null when synthesis is not applicable (no sentinel, or credit already exists).
function Resolve-NotPersistedSynthesis {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int]$PrNumber,
        [Parameter(Mandatory)][AllowNull()]$MetricsBlock,
        [AllowEmptyCollection()][AllowNull()][object[]]$Comments
    )

    # Guard: only synthesize for valid v4 metrics blocks. Pre-v4, parse-error,
    # or missing blocks do not have a Credits property and would throw
    # PropertyNotFoundException under strict mode.
    if ($null -eq $MetricsBlock) { return $null }
    if ($null -ne $MetricsBlock.PSObject.Properties['MetricsVersion']) {
        $mv = [string]$MetricsBlock.MetricsVersion
        if ($mv -eq 'parse-error' -or $mv -eq 'pre-v4') { return $null }
    }

    # Guard: a review credit already exists — do not synthesize.
    $existingCredits = if ($null -ne $MetricsBlock.PSObject.Properties['Credits']) { @($MetricsBlock.Credits) } else { @() }
    $existingReviewCredit = @($existingCredits | Where-Object { [string]$_.Port -eq 'review' })
    if ($existingReviewCredit.Count -gt 0) { return $null }

    # Check sentinel presence.
    if (-not (Test-ReviewSentinelPresent -PrNumber $PrNumber -Comments $Comments)) {
        return $null
    }

    # Find the sentinel comment URL for evidence.
    $sentinelUrl = ''
    $token = "<!-- review-judge-produced-$PrNumber -->"
    foreach ($c in @($Comments)) {
        $body = ''
        if ($null -ne $c.PSObject.Properties['body']) { $body = [string]$c.body }
        if ($body -like "*$token*") {
            if ($null -ne $c.PSObject.Properties['url']) { $sentinelUrl = [string]$c.url }
            break
        }
    }

    $evidence = if ([string]::IsNullOrWhiteSpace($sentinelUrl)) {
        "sentinel $token present but no review credit row was written."
    } else {
        "sentinel $token present (comment: $sentinelUrl) but no review credit row was written."
    }

    return [pscustomobject]@{
        Port    = 'review'
        Status  = 'not-persisted'
        Evidence = $evidence
    }
}

# ---------------------------------------------------------------------------
# ConvertFrom-JudgeRulingsComment (issue #441, Step 8b)
# ---------------------------------------------------------------------------
# Parse the <!-- judge-rulings --> YAML block from a PR comment body.
# Returns an array of pscustomobject with: id, judge_ruling, judge_confidence,
# points_awarded.  Returns an empty array when no valid block is found.

function ConvertFrom-JudgeRulingsComment {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$CommentBody
    )

    $blockMatch = [regex]::Match($CommentBody, '(?ms)<!--\s*judge-rulings\s*\r?\n(?<body>.*?)\r?\n-->')
    if (-not $blockMatch.Success) { return @() }

    $rows    = [System.Collections.Generic.List[object]]::new()
    $current = $null

    foreach ($rawLine in ($blockMatch.Groups['body'].Value -split "`r?`n")) {
        $line = $rawLine.Trim()
        if ([string]::IsNullOrWhiteSpace($line)) { continue }

        if ($line -match '^-\s+(?<key>[a-z_]+):\s+(?<value>.+?)\s*$') {
            if ($null -ne $current) { $rows.Add([pscustomobject]$current) }
            $current = [ordered]@{}
            $current[$matches['key']] = $matches['value']
            continue
        }

        if ($line -match '^(?<key>[a-z_]+):\s+(?<value>.+?)\s*$') {
            if ($null -ne $current) { $current[$matches['key']] = $matches['value'] }
            continue
        }
    }

    if ($null -ne $current) { $rows.Add([pscustomobject]$current) }
    return @($rows)
}

# ---------------------------------------------------------------------------
# Build-ReviewCreditRow (issue #441, Step 8b — Decision 2 + M1 emission)
# ---------------------------------------------------------------------------
# Construct a v4 review credit row from a judge-rulings PR comment + adapter
# integrity contract.  Used by Code-Conductor's pipeline-metrics emitter at
# PR creation time.
#
# Parameters:
#   JudgeRulingsComment — full text of a PR comment containing <!-- judge-rulings -->
#   AdapterName         — 'standard' | 'lite' | 'judge-only' | 'proxy-github' (default: 'standard')
#   AdaptersDir         — path to skills/adversarial-review/adapters/ (optional; enables
#                         live integrity-contract lookup from adapter frontmatter)
#   RunIndex            — monotonically increasing integer per (port, adapter) (default: 1)
#   Evidence            — custom evidence string; auto-generated when absent
#
# Returns a pscustomobject shaped for direct emission into credits[]:
#   port, adapter, status, run_index, evidence, judge-score, integrity-check

function script:Add-FCLTerminalStepId {
    param(
        [Parameter(Mandatory)]$Row,
        [int]$Step = 0
    )

    if ($Step -gt 0) {
        $Row | Add-Member -NotePropertyName 'terminal-step-id' -NotePropertyValue $Step
    }

    return $Row
}

function Build-ReviewCreditRow {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$JudgeRulingsComment,
        [string]$AdapterName = 'standard',
        [string]$AdaptersDir = '',
        [int]$RunIndex = 1,
        [string]$Evidence = '',
        [int]$Step = 0
    )

    # Parse findings from the judge-rulings block.
    $findings = @(ConvertFrom-JudgeRulingsComment -CommentBody $JudgeRulingsComment)

    # Determine credit status.
    # Presence of any sustained finding with P+10 (critical/high severity) → failed.
    # All findings defense-sustained or only P+1/P+5 sustained → passed.
    $hasSustainedHigh = $false
    foreach ($f in $findings) {
        if ([string]$f.judge_ruling -eq 'sustained' -and [string]$f.points_awarded -match 'P\+10\b') {
            $hasSustainedHigh = $true
            break
        }
    }
    $status = if ($hasSustainedHigh) { 'failed' } else { 'passed' }

    # Evidence string.
    $sustainedCount = @($findings | Where-Object { [string]$_.judge_ruling -eq 'sustained' }).Count
    $resolvedEvidence = if (-not [string]::IsNullOrWhiteSpace($Evidence)) {
        $Evidence
    }
    else {
        "Review completed; $sustainedCount finding(s) sustained, status: $status."
    }

    # Integrity contract from adapter frontmatter (optional live lookup).
    $passBlocks      = @(1, 2, 3)   # default for standard
    $integrityStatus = 'passed'

    if (-not [string]::IsNullOrWhiteSpace($AdaptersDir)) {
        $adapterMd = Join-Path $AdaptersDir "$AdapterName.md"
        if (Test-Path $adapterMd) {
            $content = Get-Content $adapterMd -Raw
            if ($content -match '(?ms)integrity-contract:.*?exempt:\s*(?<val>true|false)') {
                $isExempt = [System.Boolean]::Parse($matches['val'].Trim())
                if ($isExempt) {
                    $passBlocks      = @()
                    $integrityStatus = 'not-applicable'
                }
                elseif ($content -match '(?ms)integrity-contract:.*?pass-blocks:\s*\[(?<blocks>[^\]]*)\]') {
                    $blockStr  = $matches['blocks']
                    $passBlocks = @(
                        $blockStr -split '[,\s]+' |
                        Where-Object { $_ -match '^\d+$' } |
                        ForEach-Object { [int]$_ }
                    )
                }
            }
        }
    }
    elseif ($AdapterName -eq 'lite') {
        $passBlocks = @(1)
    }
    elseif ($AdapterName -in @('judge-only', 'proxy-github')) {
        $passBlocks      = @()
        $integrityStatus = 'not-applicable'
    }

    $row = [pscustomobject]@{
        port             = 'review'
        adapter          = $AdapterName
        status           = $status
        run_index        = $RunIndex
        evidence         = $resolvedEvidence
        'judge-score'    = [pscustomobject]@{
            ruling   = $status
            findings = @($findings | ForEach-Object {
                [pscustomobject]@{
                    id     = [string]$_.id
                    ruling = [string]$_.judge_ruling
                }
            })
        }
        'integrity-check' = [pscustomobject]@{
            'pass-blocks' = $passBlocks
            status        = $integrityStatus
        }
    }

    return script:Add-FCLTerminalStepId -Row $row -Step $Step
}

# Return the credit row with the highest RunIndex for a given (Port, Adapter) pair.
# When Adapter is omitted / empty, matches on Port alone.
# Returns $null when no matching entry exists.
function Select-LastCreditByRunIndex {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Credits,
        [Parameter(Mandatory)][string]$Port,
        [AllowEmptyString()][string]$Adapter = ''
    )

    $pool = @($Credits | Where-Object { [string]$_.Port -eq $Port })
    if (-not [string]::IsNullOrWhiteSpace($Adapter)) {
        $pool = @($pool | Where-Object { [string]$_.Adapter -eq $Adapter })
    }

    if ($pool.Count -eq 0) { return $null }
    if ($pool.Count -eq 1) { return $pool[0] }

    # Sort by RunIndex descending; treat $null RunIndex as 0.
    return ($pool | Sort-Object -Property { if ($null -eq $_.RunIndex) { 0 } else { [int]$_.RunIndex } } -Descending | Select-Object -First 1)
}

function Get-PortFiles {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$PortsDir)

    if ([string]::IsNullOrWhiteSpace($PortsDir) -or -not (Test-Path -LiteralPath $PortsDir -PathType Container)) {
        return , @()
    }

    $results = [System.Collections.Generic.List[object]]::new()

    $files = @()
    try {
        $files = @(Get-ChildItem -LiteralPath $PortsDir -Filter '*.yaml' -File -ErrorAction Stop)
    }
    catch {
        return , @()
    }

    foreach ($file in $files) {
        try {
            $raw = Get-Content -LiteralPath $file.FullName -Raw -ErrorAction Stop
            if ($null -eq $raw) { $raw = '' }

            if (-not (script:Test-FCLYamlSane -Text $raw)) {
                [Console]::Error.WriteLine("Get-PortFiles: skipped malformed port file '$($file.FullName)'.")
                continue
            }

            $name = script:Get-FCLScalar -Block $raw -Name 'name'
            $description = script:Get-FCLScalar -Block $raw -Name 'description'
            $applies = script:Get-FCLScalar -Block $raw -Name 'applies'
            $status = script:Get-FCLScalar -Block $raw -Name 'status'

            if ([string]::IsNullOrWhiteSpace($name)) {
                [Console]::Error.WriteLine("Get-PortFiles: skipped port file '$($file.FullName)' (missing name).")
                continue
            }

            $results.Add([pscustomobject]@{
                    Name        = $name
                    Description = $description
                    Applies     = $applies
                    Status      = $status
                }) | Out-Null
        }
        catch {
            [Console]::Error.WriteLine("Get-PortFiles: skipped port file '$($file.FullName)' due to error: $($_.Exception.Message)")
            continue
        }
    }

    return $results.ToArray()
}

function Resolve-PortStatus {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Port,
        $WorkAdapters,
        $ApplicableMap,
        $Credit
    )

    $portName = [string]$Port.Name

    $adapters = @()
    if ($null -ne $WorkAdapters) { $adapters = @($WorkAdapters) }

    # ---------------------------------------------------------------------------
    # Step 10 (issue #441): adapter parse-failure reporting.
    # Partition adapters into valid (no ParseError) and parse-error (ParseError
    # field non-null/non-empty).  When ALL adapters are parse-error entries, surface
    # Inconclusive/AdapterParseError instead of silently falling through to the
    # NoEvidence or AdapterDiscoveryFailed paths.  When some adapters are valid,
    # discard the parse-error entries and use only the valid ones.
    # ---------------------------------------------------------------------------
    $parseErrorAdapters = @($adapters | Where-Object {
        $null -ne $_.PSObject.Properties['ParseError'] -and
        -not [string]::IsNullOrWhiteSpace([string]$_.ParseError)
    })
    $validAdapters = @($adapters | Where-Object {
        $null -eq $_.PSObject.Properties['ParseError'] -or
        [string]::IsNullOrWhiteSpace([string]$_.ParseError)
    })

    if ($parseErrorAdapters.Count -gt 0 -and $validAdapters.Count -eq 0) {
        $reasons = @($parseErrorAdapters | ForEach-Object { [string]$_.ParseError }) -join '; '
        return [pscustomobject]@{
            PortName          = $portName
            Status            = 'Inconclusive'
            SubReason         = 'AdapterParseError'
            AdapterName       = ''
            SuggestedNextStep = $null
            Evidence          = "0 parseable adapters (parse error: $reasons)"
        }
    }

    # Replace the working adapter set with valid-only adapters (non-goal: do not
    # block discovery for other ports when one adapter parses badly).
    $adapters = $validAdapters

    $map = @{}
    if ($null -ne $ApplicableMap) {
        if ($ApplicableMap -is [System.Collections.IDictionary]) {
            foreach ($k in $ApplicableMap.Keys) { $map[$k] = [string]$ApplicableMap[$k] }
        }
    }

    # Build per-adapter applicability list in adapter order.
    $applicabilities = @($adapters | ForEach-Object {
            $key = [string]$_.Name
            if ($map.ContainsKey($key)) { [string]$map[$key] } else { 'unknown' }
        })

    # 1) D7 Auto-N/A: every adapter is 'false' (and at least one adapter exists).
    if ($adapters.Count -gt 0 -and ($applicabilities | Where-Object { $_ -ne 'false' }).Count -eq 0) {
        return [pscustomobject]@{
            PortName          = $portName
            Status            = 'Covered'
            SubReason         = 'AutoNotApplicable'
            AdapterName       = ''
            SuggestedNextStep = $null
            Evidence          = ''
        }
    }

    # 2) Adapter discovery failed: all-unknown AND no credit.
    if ($adapters.Count -gt 0 -and $null -eq $Credit -and ($applicabilities | Where-Object { $_ -ne 'unknown' }).Count -eq 0) {
        return [pscustomobject]@{
            PortName          = $portName
            Status            = 'Inconclusive'
            SubReason         = 'AdapterDiscoveryFailed'
            AdapterName       = ''
            SuggestedNextStep = $null
            Evidence          = ''
        }
    }

    # Helper: pick the first adapter whose applicability is 'true'.
    $firstApplicableAdapter = $null
    for ($i = 0; $i -lt $adapters.Count; $i++) {
        if ($applicabilities[$i] -eq 'true') {
            $firstApplicableAdapter = $adapters[$i]
            break
        }
    }

    # 3) Credit branch.
    if ($null -ne $Credit) {
        $creditStatus = [string]$Credit.Status
        $evidence = ''
        if ($null -ne $Credit.PSObject.Properties['Evidence']) {
            $evidence = [string]$Credit.Evidence
        }
        $applicableAdapterName = if ($firstApplicableAdapter) { [string]$firstApplicableAdapter.Name } else { '' }

        # Map credit status -> (PortStatus, SubReason, includeNextStep). When
        # includeNextStep is true the adapter's SuggestedNextStep flows through;
        # otherwise it is forced to $null.
        $creditMap = @{
            'passed'         = @{ Status = 'Covered'; SubReason = 'PassedCredit'; IncludeNextStep = $false }
            'not-applicable' = @{ Status = 'Covered'; SubReason = 'NotApplicableCredit'; IncludeNextStep = $false }
            'skipped'        = @{ Status = 'Covered'; SubReason = 'SkippedCredit'; IncludeNextStep = $false }
            'failed'         = @{ Status = 'NotCovered'; SubReason = 'AdapterFailed'; IncludeNextStep = $true }
            'inconclusive'   = @{ Status = 'Inconclusive'; SubReason = 'InconclusiveCredit'; IncludeNextStep = $true }
        }

        $entry = $creditMap[$creditStatus]
        if ($null -eq $entry) {
            $entry = @{ Status = 'Inconclusive'; SubReason = 'UnknownCreditStatus'; IncludeNextStep = $false }
        }
        $nextStep = if ($entry.IncludeNextStep) { script:Resolve-FCLNextStep -Adapter $firstApplicableAdapter } else { $null }

        return [pscustomobject]@{
            PortName          = $portName
            Status            = $entry.Status
            SubReason         = $entry.SubReason
            AdapterName       = $applicableAdapterName
            SuggestedNextStep = $nextStep
            Evidence          = $evidence
        }
    }

    # 4) Credit missing.
    if ($null -ne $firstApplicableAdapter) {
        $rawStep = $firstApplicableAdapter.SuggestedNextStep
        $rawStepStr = if ($null -eq $rawStep) { '' } else { [string]$rawStep }

        if ([string]::IsNullOrWhiteSpace($rawStepStr)) {
            return [pscustomobject]@{
                PortName          = $portName
                Status            = 'Inconclusive'
                SubReason         = 'MissingNextStepField'
                AdapterName       = [string]$firstApplicableAdapter.Name
                SuggestedNextStep = $null
                Evidence          = ''
            }
        }

        $nextStep = if ($rawStepStr -eq 'none') { $null } else { $rawStepStr }
        return [pscustomobject]@{
            PortName          = $portName
            Status            = 'NotCovered'
            SubReason         = 'MissingAdapter'
            AdapterName       = [string]$firstApplicableAdapter.Name
            SuggestedNextStep = $nextStep
            Evidence          = ''
        }
    }

    # No adapters / no applicable adapters / no credit. Treat as inconclusive.
    return [pscustomobject]@{
        PortName          = $portName
        Status            = 'Inconclusive'
        SubReason         = 'NoEvidence'
        AdapterName       = ''
        SuggestedNextStep = $null
        Evidence          = ''
    }
}

function Compose-Comment {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$MarkerToken,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$PortReports
    )

    $reports = @($PortReports | Where-Object { $_ -ne $null })

    # Auto-N/A ports are silently filtered from the rendered ledger (Design
    # Intent #1: "no noise about ports that legitimately do not apply"). They
    # are surfaced as a footnote count instead so operators know the
    # filtering happened without seeing per-port rows for non-events.
    $autoNotApplicable = @($reports | Where-Object {
            [string]$_.Status -eq 'Covered' -and [string]$_.SubReason -eq 'AutoNotApplicable'
        })
    $tableReports = @($reports | Where-Object {
            -not ([string]$_.Status -eq 'Covered' -and [string]$_.SubReason -eq 'AutoNotApplicable')
        })

    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine($MarkerToken)
    [void]$sb.AppendLine('## Frame credit ledger — port coverage report')
    [void]$sb.AppendLine('')

    # Unified per-port table (D2 single-shape parity — issue #441 Step 5b).
    # All status values appear in the same table; no three-section split.
    if ($tableReports.Count -gt 0) {
        [void]$sb.AppendLine('| Port | Status | Evidence | Next step |')
        [void]$sb.AppendLine('|------|--------|----------|-----------|')

        foreach ($r in $tableReports) {
            $portName = [string]$r.PortName

            # Determine the credit-status label and glyph.
            $creditStatus = ''
            if ($null -ne $r.PSObject.Properties['CreditStatus'] -and -not [string]::IsNullOrWhiteSpace([string]$r.CreditStatus)) {
                $creditStatus = [string]$r.CreditStatus
            } else {
                # Derive from SubReason when CreditStatus is not provided.
                $creditStatus = switch ([string]$r.SubReason) {
                    'PassedCredit'        { 'passed' }
                    'NotApplicableCredit' { 'not-applicable' }
                    'SkippedCredit'       { 'skipped' }
                    'AdapterFailed'       { 'failed' }
                    'InconclusiveCredit'  { 'inconclusive' }
                    'NotPersistedCredit'  { 'not-persisted' }
                    'MissingAdapter'      { 'missing' }
                    default               { [string]$r.SubReason }
                }
            }

            $glyph = switch ($creditStatus) {
                'passed'        { '✅' }
                'not-applicable'{ '➖' }
                'skipped'       { '⏭️' }
                'failed'        { '❌' }
                'inconclusive'  { '⚠️' }
                'not-persisted' { '🔇' }
                default         { '❓' }
            }

            $statusCell = "$glyph $creditStatus"

            $evidence = ''
            if ($null -ne $r.PSObject.Properties['Evidence']) { $evidence = [string]$r.Evidence }

            $nextStep = ''
            if ($null -ne $r.SuggestedNextStep -and -not [string]::IsNullOrWhiteSpace([string]$r.SuggestedNextStep)) {
                $nextStep = [string]$r.SuggestedNextStep
            }

            # Escape pipe characters and convert newlines to <br> in cell content
            # to avoid Markdown table row breakage. Multi-line evidence (e.g., from
            # Build-ReviewCreditRow) would otherwise terminate the table prematurely.
            $portName  = ($portName  -replace '\|', '\|') -replace "`r`n", '<br>' -replace "`n", '<br>' -replace "`r", '<br>'
            $evidence  = ($evidence  -replace '\|', '\|') -replace "`r`n", '<br>' -replace "`n", '<br>' -replace "`r", '<br>'
            $nextStep  = ($nextStep  -replace '\|', '\|') -replace "`r`n", '<br>' -replace "`n", '<br>' -replace "`r", '<br>'

            [void]$sb.AppendLine("| $portName | $statusCell | $evidence | $nextStep |")
        }
        [void]$sb.AppendLine('')
    }

    if ($autoNotApplicable.Count -gt 0) {
        [void]$sb.AppendLine(("({0} ports auto-N/A — predicates evaluated false against this changeset.)" -f $autoNotApplicable.Count))
        [void]$sb.AppendLine('')
    }

    [void]$sb.AppendLine('(Hook ran in `warn` mode; PR creation was not blocked.)')

    return $sb.ToString()
}

function Compose-CommentWithCostPattern {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$MarkerToken,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$PortReports,
        [AllowEmptyString()][string]$CostSection = ''
    )
    # 1. Call Compose-Comment to get the port-coverage section
    $portCoverageBody = Compose-Comment -MarkerToken $MarkerToken -PortReports $PortReports
    # 2. Append cost section if non-empty
    if ([string]::IsNullOrWhiteSpace($CostSection)) {
        return $portCoverageBody
    }
    return $portCoverageBody + "`n`n" + $CostSection
}

function Compose-PreV4ShortCircuitComment {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$MarkerToken)

    $lines = @(
        $MarkerToken,
        '⚠️ **Frame credit ledger — pre-v4 metrics detected**',
        '',
        'The frame credit-ledger hook reads `metrics_version: 4` frame credits. This PR''s body has only a pre-v4 `pipeline-metrics` block (the inherited v3 base, per `skills/calibration-pipeline/references/metrics-schema.md`), so port-by-port credit reporting is unavailable.',
        '',
        '**Suggested next step**: Ask Code-Conductor to re-emit pipeline-metrics at v4 (the conductor''s PR-creation flow targets v4 by default per `frame/pipeline-metrics-v4-schema.md`). If you opened this PR before v4 emission landed, close-and-reopen with a fresh `gh pr create` will regenerate the body.',
        '',
        '(Hook ran in `warn` mode; PR creation was not blocked.)'
    )

    return ($lines -join [Environment]::NewLine)
}

# Render the short-circuit comment for the case where the pipeline-metrics
# marker block exists but its YAML failed sanity validation. Distinct from
# pre-v4 (block exists, version != 4) and missing-marker (no block at all);
# emitted when Read-PRMetricsBlock returns MetricsVersion='parse-error'.
function Compose-ParseErrorShortCircuitComment {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$MarkerToken,
        [string]$Reason = ''
    )

    $reasonLine = if ([string]::IsNullOrWhiteSpace($Reason)) {
        'No additional reason was reported by the parser.'
    }
    else {
        "Parser reason: $Reason"
    }

    $lines = @(
        $MarkerToken,
        '⚠️ **Frame credit ledger — pipeline-metrics block could not be parsed**',
        '',
        'A `pipeline-metrics` marker block exists in this PR''s body, but its YAML failed sanity validation, so port-by-port credit reporting is unavailable.',
        '',
        $reasonLine,
        '',
        '**Suggested next step**: Re-run Code-Conductor''s PR-creation flow to regenerate the pipeline-metrics block (the conductor emits v4 by default per `frame/pipeline-metrics-v4-schema.md`). Editing the marker block by hand is risky — close-and-reopen with a fresh `gh pr create` is the safer path.',
        '',
        '(Hook ran in `warn` mode; PR creation was not blocked.)'
    )

    return ($lines -join [Environment]::NewLine)
}

# Render the short-circuit comment for the case where the PR body has no
# pipeline-metrics marker block at all (Read-PRMetricsBlock returned $null).
# Distinct from pre-v4 and parse-error.
function Compose-MissingMetricsShortCircuitComment {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$MarkerToken)

    $lines = @(
        $MarkerToken,
        '⚠️ **Frame credit ledger — no pipeline-metrics block found in the PR body**',
        '',
        'The frame credit-ledger hook reads `metrics_version: 4` frame credits emitted inside an HTML-comment marker block (`<!-- pipeline-metrics ... -->`). This PR''s body does not contain that block, so port-by-port credit reporting is unavailable.',
        '',
        '**Suggested next step**: Re-run Code-Conductor''s PR-creation flow so it emits a v4 `pipeline-metrics` block into the PR body (per `frame/pipeline-metrics-v4-schema.md`). If the PR was opened by hand or by a non-conductor flow, close-and-reopen with a fresh `gh pr create` will regenerate the body.',
        '',
        '(Hook ran in `warn` mode; PR creation was not blocked.)'
    )

    return ($lines -join [Environment]::NewLine)
}

# ===========================================================================
# Credit-row builders introduced by issue #442 (sub-B).
# Each function returns a PSCustomObject credit row matching the v4
# credits[] schema from frame/pipeline-metrics-v4-schema.md.
# Required fields on every row: port, status, evidence.
# ===========================================================================

# ---------------------------------------------------------------------------
# Build-CeGateCreditRow (Step 4a)
#
# Shared parameterised builder for all four CE Gate surface ports.
# Surface enum: cli | browser | canvas | api
# Status resolution order:
#   1. -EnvironmentBlocked $true  → inconclusive + block_kind
#   2. -SurfaceTouchResult $false → not-applicable
#   3. -EvidenceList non-empty   → passed
#   4. -EvidenceList empty        → inconclusive (no block_kind)
# ---------------------------------------------------------------------------
function Build-CeGateCreditRow {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('cli', 'browser', 'canvas', 'api')]
        [string]$Surface,

        [bool]$EnvironmentBlocked = $false,

        [ValidateSet('environment', 'tooling', 'runtime', 'orchestration')]
        [string]$BlockKind = '',

        [bool]$SurfaceTouchResult = $true,

        [AllowEmptyCollection()][object[]]$EvidenceList = @(),

        [string]$Evidence = '',

        [int]$Step = 0
    )

    $port = "ce-gate-$Surface"

    if ($EnvironmentBlocked -and [string]::IsNullOrWhiteSpace($BlockKind)) {
        throw "Build-CeGateCreditRow: -BlockKind is required when -EnvironmentBlocked is `$true (allowed values: environment, tooling, runtime, orchestration)"
    }

    if ($EnvironmentBlocked) {
        $resolvedEvidence = if (-not [string]::IsNullOrWhiteSpace($Evidence)) { $Evidence }
                            else { "CE Gate for $Surface surface blocked — $BlockKind." }
        $row = [pscustomobject]@{
            port       = $port
            status     = 'inconclusive'
            block_kind = $BlockKind
            evidence   = $resolvedEvidence
        }
        return script:Add-FCLTerminalStepId -Row $row -Step $Step
    }

    if (-not $SurfaceTouchResult) {
        $resolvedEvidence = if (-not [string]::IsNullOrWhiteSpace($Evidence)) { $Evidence }
                            else { "CE Gate not applicable — $Surface surface not touched." }
        $row = [pscustomobject]@{
            port     = $port
            status   = 'not-applicable'
            evidence = $resolvedEvidence
        }
        return script:Add-FCLTerminalStepId -Row $row -Step $Step
    }

    if ($EvidenceList.Count -gt 0) {
        $resolvedEvidence = if (-not [string]::IsNullOrWhiteSpace($Evidence)) { $Evidence }
                            else { $EvidenceList -join '; ' }
        $row = [pscustomobject]@{
            port     = $port
            status   = 'passed'
            evidence = $resolvedEvidence
        }
        return script:Add-FCLTerminalStepId -Row $row -Step $Step
    }

    # No evidence list and not blocked — inconclusive. Forward-emitted CE Gate inconclusive rows
    # must carry block_kind per F13/schema; 'tooling' is the appropriate value when the surface
    # was reachable but no scenario evidence was produced (builder called without evidence).
    $resolvedEvidence = if (-not [string]::IsNullOrWhiteSpace($Evidence)) { $Evidence }
                        else { "CE Gate for $Surface surface inconclusive — no scenario evidence supplied." }
    $row = [pscustomobject]@{
        port       = $port
        status     = 'inconclusive'
        block_kind = 'tooling'
        evidence   = $resolvedEvidence
    }
    return script:Add-FCLTerminalStepId -Row $row -Step $Step
}

# ---------------------------------------------------------------------------
# Shared helper: resolve pipeline-entry credit status.
# Priority: explicit-skip adapter > auto-na predicate > marker present.
# ---------------------------------------------------------------------------
function script:Resolve-PipelineEntryCreditStatus {
    param(
        [string]$AdapterName,
        [bool]$AutoNaResult,
        [bool]$MarkerPresent
    )

    if ($AdapterName -eq 'explicit-skip') { return 'skipped' }
    if ($AutoNaResult) { return 'not-applicable' }
    if ($MarkerPresent) { return 'passed' }
    # No marker and not auto-N/A: the agent did not post its completion marker — "no evidence"
    # semantics per D5/AC9. Use 'skipped', not 'not-applicable' (which is predicate-derived only).
    return 'skipped'
}

# ---------------------------------------------------------------------------
# Build-ExperienceCreditRow (Step 4b)
# ---------------------------------------------------------------------------
function Build-ExperienceCreditRow {
    [CmdletBinding()]
    param(
        [bool]$MarkerPresent = $false,
        [bool]$AutoNaResult = $false,
        [string]$AdapterName = 'work-adapter',
        [int]$IssueNumber = 0,
        [string]$Evidence = '',
        [int]$Step = 0
    )

    $status = script:Resolve-PipelineEntryCreditStatus -AdapterName $AdapterName -AutoNaResult $AutoNaResult -MarkerPresent $MarkerPresent
    $resolvedEvidence = if (-not [string]::IsNullOrWhiteSpace($Evidence)) { $Evidence }
                        elseif ($status -eq 'passed') { "Experience-Owner completion marker <!-- experience-owner-complete-$IssueNumber --> present." }
                        elseif ($status -eq 'not-applicable') { "changeset.isPipelineEntryTrivial == true; experience port not applicable." }
                        else { "$AdapterName adapter; status: $status." }

    $row = [pscustomobject]@{
        port     = 'experience'
        adapter  = $AdapterName
        status   = $status
        evidence = $resolvedEvidence
    }
    return script:Add-FCLTerminalStepId -Row $row -Step $Step
}

# ---------------------------------------------------------------------------
# Build-DesignCreditRow (Step 4b)
# ---------------------------------------------------------------------------
function Build-DesignCreditRow {
    [CmdletBinding()]
    param(
        [bool]$MarkerPresent = $false,
        [bool]$AutoNaResult = $false,
        [string]$AdapterName = 'work-adapter',
        [int]$IssueNumber = 0,
        [string]$Evidence = '',
        [int]$Step = 0
    )

    $status = script:Resolve-PipelineEntryCreditStatus -AdapterName $AdapterName -AutoNaResult $AutoNaResult -MarkerPresent $MarkerPresent
    $resolvedEvidence = if (-not [string]::IsNullOrWhiteSpace($Evidence)) { $Evidence }
                        elseif ($status -eq 'passed') { "Solution-Designer completion marker <!-- design-phase-complete-$IssueNumber --> present." }
                        elseif ($status -eq 'not-applicable') { "changeset.isPipelineEntryTrivial == true; design port not applicable." }
                        else { "$AdapterName adapter; status: $status." }

    $row = [pscustomobject]@{
        port     = 'design'
        adapter  = $AdapterName
        status   = $status
        evidence = $resolvedEvidence
    }
    return script:Add-FCLTerminalStepId -Row $row -Step $Step
}

# ---------------------------------------------------------------------------
# Build-PlanCreditRow (Step 4b)
# ---------------------------------------------------------------------------
function Build-PlanCreditRow {
    [CmdletBinding()]
    param(
        [bool]$MarkerPresent = $false,
        [bool]$AutoNaResult = $false,
        [string]$AdapterName = 'work-adapter',
        [int]$IssueNumber = 0,
        [string]$Evidence = '',
        [int]$Step = 0
    )

    $status = script:Resolve-PipelineEntryCreditStatus -AdapterName $AdapterName -AutoNaResult $AutoNaResult -MarkerPresent $MarkerPresent
    $resolvedEvidence = if (-not [string]::IsNullOrWhiteSpace($Evidence)) { $Evidence }
                        elseif ($status -eq 'passed') { "Issue-Planner completion marker <!-- plan-issue-$IssueNumber --> present." }
                        elseif ($status -eq 'not-applicable') { "changeset.isPipelineEntryTrivial == true; plan port not applicable." }
                        else { "$AdapterName adapter; status: $status." }

    $row = [pscustomobject]@{
        port     = 'plan'
        adapter  = $AdapterName
        status   = $status
        evidence = $resolvedEvidence
    }
    return script:Add-FCLTerminalStepId -Row $row -Step $Step
}

# ---------------------------------------------------------------------------
# Shared helper: resolve implement-* status from validation evidence list.
# ---------------------------------------------------------------------------
function script:Resolve-ImplementCreditStatus {
    param(
        [string]$AdapterName,
        [bool]$AutoNaResult,
        [AllowEmptyCollection()][object[]]$ValidationEvidence
    )

    if ($AdapterName -eq 'explicit-skip') { return @{ status = 'skipped'; offending = $null } }
    if ($AutoNaResult) { return @{ status = 'not-applicable'; offending = $null } }
    if ($null -eq $ValidationEvidence -or $ValidationEvidence.Count -eq 0) {
        return @{ status = 'skipped'; offending = $null }
    }

    foreach ($item in $ValidationEvidence) {
        $itemStatus = ''
        if ($item -is [hashtable]) {
            $itemStatus = [string]$item['Status']
        } else {
            $sp = $item.PSObject.Properties['Status']
            if ($null -ne $sp) { $itemStatus = [string]$sp.Value }
        }
        if ($itemStatus.ToLowerInvariant() -ne 'passed') {
            $itemName = ''
            if ($item -is [hashtable]) { $itemName = [string]$item['Name'] }
            else {
                $np = $item.PSObject.Properties['Name']
                if ($null -ne $np) { $itemName = [string]$np.Value }
            }
            return @{ status = 'failed'; offending = $itemName }
        }
    }
    return @{ status = 'passed'; offending = $null }
}

# ---------------------------------------------------------------------------
# Build-ImplementCodeCreditRow (Step 4c)
# ---------------------------------------------------------------------------
function Build-ImplementCodeCreditRow {
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()][object[]]$ValidationEvidence = @(),
        [bool]$AutoNaResult = $false,
        [string]$AdapterName = 'work-adapter',
        [string]$Evidence = '',
        [int]$Step = 0
    )

    $r = script:Resolve-ImplementCreditStatus -AdapterName $AdapterName -AutoNaResult $AutoNaResult -ValidationEvidence $ValidationEvidence
    $resolvedEvidence = if (-not [string]::IsNullOrWhiteSpace($Evidence)) { $Evidence }
                        elseif ($r.status -eq 'skipped') { 'no validator evidence supplied to the credit-row builder' }
                        elseif ($r.status -eq 'failed') { "Validator failed: $($r.offending)" }
                        else { "implement-code validation: $($r.status)." }

    $row = [pscustomobject]@{
        port     = 'implement-code'
        adapter  = $AdapterName
        status   = $r.status
        evidence = $resolvedEvidence
    }
    return script:Add-FCLTerminalStepId -Row $row -Step $Step
}

# ---------------------------------------------------------------------------
# Build-ImplementTestCreditRow (Step 4c)
# ---------------------------------------------------------------------------
function Build-ImplementTestCreditRow {
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()][object[]]$ValidationEvidence = @(),
        [bool]$AutoNaResult = $false,
        [string]$AdapterName = 'work-adapter',
        [string]$Evidence = '',
        [int]$Step = 0
    )

    $r = script:Resolve-ImplementCreditStatus -AdapterName $AdapterName -AutoNaResult $AutoNaResult -ValidationEvidence $ValidationEvidence
    $resolvedEvidence = if (-not [string]::IsNullOrWhiteSpace($Evidence)) { $Evidence }
                        elseif ($r.status -eq 'skipped') { 'no validator evidence supplied to the credit-row builder' }
                        elseif ($r.status -eq 'failed') { "Validator failed: $($r.offending)" }
                        else { "implement-test validation: $($r.status)." }

    $row = [pscustomobject]@{
        port     = 'implement-test'
        adapter  = $AdapterName
        status   = $r.status
        evidence = $resolvedEvidence
    }
    return script:Add-FCLTerminalStepId -Row $row -Step $Step
}

# ---------------------------------------------------------------------------
# Build-ImplementRefactorCreditRow (Step 4c)
# Accepts optional -DebtThreshold hashtable (forwarded for caller use).
# ---------------------------------------------------------------------------
function Build-ImplementRefactorCreditRow {
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()][object[]]$ValidationEvidence = @(),
        [bool]$AutoNaResult = $false,
        [string]$AdapterName = 'work-adapter',
        [hashtable]$DebtThreshold = @{ lineCount = 300; complexity = 10 },
        [string]$Evidence = '',
        [int]$Step = 0
    )

    $r = script:Resolve-ImplementCreditStatus -AdapterName $AdapterName -AutoNaResult $AutoNaResult -ValidationEvidence $ValidationEvidence
    $resolvedEvidence = if (-not [string]::IsNullOrWhiteSpace($Evidence)) { $Evidence }
                        elseif ($r.status -eq 'skipped') { 'no validator evidence supplied to the credit-row builder' }
                        elseif ($r.status -eq 'failed') { "Validator failed: $($r.offending)" }
                        else { "implement-refactor validation: $($r.status)." }

    $row = [pscustomobject]@{
        port     = 'implement-refactor'
        adapter  = $AdapterName
        status   = $r.status
        evidence = $resolvedEvidence
    }
    return script:Add-FCLTerminalStepId -Row $row -Step $Step
}

# ---------------------------------------------------------------------------
# Build-ImplementDocsCreditRow (Step 4c)
# ---------------------------------------------------------------------------
function Build-ImplementDocsCreditRow {
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()][object[]]$ValidationEvidence = @(),
        [bool]$AutoNaResult = $false,
        [string]$AdapterName = 'work-adapter',
        [string]$Evidence = '',
        [int]$Step = 0
    )

    $r = script:Resolve-ImplementCreditStatus -AdapterName $AdapterName -AutoNaResult $AutoNaResult -ValidationEvidence $ValidationEvidence
    $resolvedEvidence = if (-not [string]::IsNullOrWhiteSpace($Evidence)) { $Evidence }
                        elseif ($r.status -eq 'skipped') { 'no validator evidence supplied to the credit-row builder' }
                        elseif ($r.status -eq 'failed') { "Validator failed: $($r.offending)" }
                        else { "implement-docs validation: $($r.status)." }

    $row = [pscustomobject]@{
        port     = 'implement-docs'
        adapter  = $AdapterName
        status   = $r.status
        evidence = $resolvedEvidence
    }
    return script:Add-FCLTerminalStepId -Row $row -Step $Step
}

# ---------------------------------------------------------------------------
# Build-PostPrCreditRow (Step 4d)
#
# Accepts -ChecklistOutcomes @{archive; docs; version; releaseTag}.
# All true → passed; any false → failed (failing keys in evidence);
# absent/empty → skipped.
# ---------------------------------------------------------------------------
function Build-PostPrCreditRow {
    [CmdletBinding()]
    param(
        [hashtable]$ChecklistOutcomes = $null,
        [string]$Evidence = '',
        [int]$Step = 0
    )

    if ($null -eq $ChecklistOutcomes -or $ChecklistOutcomes.Count -eq 0) {
        $resolvedEvidence = if (-not [string]::IsNullOrWhiteSpace($Evidence)) { $Evidence }
                            else { 'no checklist outcomes supplied to the credit-row builder' }
        $row = [pscustomobject]@{
            port     = 'post-pr'
            status   = 'skipped'
            evidence = $resolvedEvidence
        }
        return script:Add-FCLTerminalStepId -Row $row -Step $Step
    }

    $failing = @()
    foreach ($key in @('archive', 'docs', 'version', 'releaseTag')) {
        if ($ChecklistOutcomes.ContainsKey($key)) {
            $val = $ChecklistOutcomes[$key]
            # Accept booleans directly; for strings, 'passed' and 'skipped' are non-failure values.
            $isSuccess = if ($val -is [bool]) { $val } else { [string]$val -in @('passed', 'skipped') }
            if (-not $isSuccess) { $failing += $key }
        }
    }

    if ($failing.Count -gt 0) {
        $resolvedEvidence = if (-not [string]::IsNullOrWhiteSpace($Evidence)) { $Evidence }
                            else { "Post-PR checklist failed: $($failing -join ', ')." }
        $row = [pscustomobject]@{
            port     = 'post-pr'
            status   = 'failed'
            evidence = $resolvedEvidence
        }
        return script:Add-FCLTerminalStepId -Row $row -Step $Step
    }

    $resolvedEvidence = if (-not [string]::IsNullOrWhiteSpace($Evidence)) { $Evidence }
                        else { 'Post-PR checklist passed: archive, docs, version, releaseTag.' }
    $row = [pscustomobject]@{
        port     = 'post-pr'
        status   = 'passed'
        evidence = $resolvedEvidence
    }
    return script:Add-FCLTerminalStepId -Row $row -Step $Step
}

function Invoke-CreditInputHarvest {
    <#
    .SYNOPSIS
        Harvests credit-input deferred-emission markers from a GitHub issue's comments
        and returns an array of credit rows, one per recognized port (SMC-17).

    .DESCRIPTION
        For each pipeline-entry port (experience, design, plan), scans the issue's
        comment thread for a <!-- credit-input-{port}-{ID} --> marker, parses the
        YAML payload, and calls the matching Build-*CreditRow with the parsed evidence.

        Read-after-write retry: if an upstream completion marker is present but the
        matching credit-input marker is absent, retries up to MaxRetries times with
        exponential backoff starting at InitialBackoffSec seconds.

        When -InMemoryMarkers is supplied (array of raw marker text strings from
        same-conversation post calls), those texts are parsed directly without gh
        API calls for the ports they cover.

    .PARAMETER IssueNumber
        The GitHub issue number to scan.

    .PARAMETER Repo
        The repository in owner/name format (e.g., Grimblaz/agent-orchestra).

    .PARAMETER GhCliPath
        Optional path to the gh CLI executable. Defaults to 'gh'.

    .PARAMETER InMemoryMarkers
        Optional array of raw marker text strings to parse directly (bypasses gh).

    .PARAMETER MaxRetries
        Maximum retry attempts when a completion marker is present but credit-input
        marker is absent. Defaults to 3.

    .PARAMETER InitialBackoffSec
        Initial backoff in seconds for the first retry. Doubles each retry. Defaults to 1.

    .OUTPUTS
        Array of credit-row pscustomobject values (same shape as Build-*CreditRow output).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$IssueNumber,

        [Parameter(Mandatory)]
        [string]$Repo,

        [string]$GhCliPath = 'gh',

        [string[]]$InMemoryMarkers = @(),

        [int]$MaxRetries = 3,

        [double]$InitialBackoffSec = 1
    )

    $script:PipelineEntryPorts = @('experience', 'design', 'plan')

    $script:CompletionMarkerByPort = @{
        'experience' = "<!-- experience-owner-complete-$IssueNumber -->"
        'design'     = "<!-- design-phase-complete-$IssueNumber -->"
        'plan'       = "<!-- plan-issue-$IssueNumber -->"
    }

    $script:BuilderByPort = @{
        'experience' = 'Build-ExperienceCreditRow'
        'design'     = 'Build-DesignCreditRow'
        'plan'       = 'Build-PlanCreditRow'
    }

    function script:Parse-SingleCreditInputMarker {
        param([string]$Text)

        if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
        if ($Text -notmatch '```yaml\s*([\s\S]*?)```') { return $null }

        $yaml = $Matches[1].Trim()
        $result = @{}
        foreach ($line in ($yaml -split '\r?\n')) {
            if ($line -match '^\s*(\w+)\s*:\s*"?(.*?)"?\s*$') {
                $result[$Matches[1]] = $Matches[2].Trim('"').Trim()
            }
        }

        if (-not $result.ContainsKey('port') -or [string]::IsNullOrWhiteSpace($result['port'])) {
            return $null
        }

        return $result
    }

    function script:Get-IssueComments {
        param([string]$IssueNum, [string]$RepoArg, [string]$Gh)

        try {
            $raw = & $Gh issue view $IssueNum --repo $RepoArg --json comments --paginate 2>$null
        } catch {
            return @()
        }
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($raw)) { return @() }

        try {
            $parsed = $raw | ConvertFrom-Json
            return @($parsed.comments | ForEach-Object { $_.body })
        } catch {
            return @()
        }
    }

    # Build lookup from in-memory markers (port → payload hashtable)
    $inMemoryByPort = @{}
    foreach ($markerText in $InMemoryMarkers) {
        $parsed = script:Parse-SingleCreditInputMarker -Text $markerText
        if ($null -ne $parsed -and $parsed.ContainsKey('port')) {
            $inMemoryByPort[$parsed['port']] = $parsed
        }
    }

    $results = @()

    foreach ($port in $script:PipelineEntryPorts) {
        # Use in-memory marker when available (bypasses gh for this port)
        if ($inMemoryByPort.ContainsKey($port)) {
            $payload = $inMemoryByPort[$port]
            $evidence    = if ($payload.ContainsKey('evidence')) { $payload['evidence'] } else { '' }
            $adapterName = if ($payload.ContainsKey('adapter'))  { $payload['adapter']  } else { '' }
            $builderName = $script:BuilderByPort[$port]
            if (Get-Command $builderName -ErrorAction SilentlyContinue) {
                $buildParams = @{ MarkerPresent = $true; IssueNumber = [int]$IssueNumber; Evidence = $evidence }
                if (-not [string]::IsNullOrWhiteSpace($adapterName)) { $buildParams['AdapterName'] = $adapterName }
                $results += & $builderName @buildParams
            }
            continue
        }

        # Fetch from gh with retry
        $completionMarker = $script:CompletionMarkerByPort[$port]
        $creditMarkerPrefix = "<!-- credit-input-$port-$IssueNumber"

        $payload = $null
        $attempt = 0
        $backoff = $InitialBackoffSec

        while ($attempt -le $MaxRetries) {
            $comments = script:Get-IssueComments -IssueNum $IssueNumber -RepoArg $Repo -Gh $GhCliPath
            $completionPresent = $comments | Where-Object { $_ -like "*$completionMarker*" }
            $creditComment = $comments | Where-Object { $_ -like "*$creditMarkerPrefix*" } | Select-Object -First 1

            if ($null -ne $creditComment) {
                $payload = script:Parse-SingleCreditInputMarker -Text $creditComment
                break
            }

            # Only retry when the completion marker is present but credit-input is absent
            if ($null -eq $completionPresent -or $attempt -ge $MaxRetries) { break }

            Start-Sleep -Seconds $backoff
            $backoff *= 2
            $attempt++
        }

        if ($null -ne $payload -and $null -ne $completionPresent) {
            $evidence    = if ($payload.ContainsKey('evidence')) { $payload['evidence'] } else { '' }
            $adapterName = if ($payload.ContainsKey('adapter'))  { $payload['adapter']  } else { '' }
            $builderName = $script:BuilderByPort[$port]
            if (Get-Command $builderName -ErrorAction SilentlyContinue) {
                $buildParams = @{ MarkerPresent = $true; IssueNumber = [int]$IssueNumber; Evidence = $evidence }
                if (-not [string]::IsNullOrWhiteSpace($adapterName)) { $buildParams['AdapterName'] = $adapterName }
                $results += & $builderName @buildParams
            }
        }
    }

    return $results
}
