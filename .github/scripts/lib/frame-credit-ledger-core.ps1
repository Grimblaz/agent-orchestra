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
                      'mode_backfilled_at', 'mode_original_pr_merged_at')
        $credits = @($creditsRaw | ForEach-Object {
                $runIndexRaw = [string]$_.run_index
                $runIndexInt = $null
                if (-not [string]::IsNullOrWhiteSpace($runIndexRaw)) {
                    $parsedRunIndex = 0
                    if ([int]::TryParse($runIndexRaw, [ref]$parsedRunIndex)) {
                        $runIndexInt = $parsedRunIndex
                    }
                }
                [pscustomobject]@{
                    Port                  = [string]$_.port
                    Adapter               = [string]$_.adapter
                    Status                = [string]$_.status
                    RunIndex              = $runIndexInt
                    Evidence              = [string]$_.evidence
                    ModeBackfilledAt      = if ([string]::IsNullOrWhiteSpace([string]$_.mode_backfilled_at)) { $null } else { [string]$_.mode_backfilled_at }
                    ModeOriginalPrMergedAt = if ([string]::IsNullOrWhiteSpace([string]$_.mode_original_pr_merged_at)) { $null } else { [string]$_.mode_original_pr_merged_at }
                }
            })

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
        [Parameter(Mandatory)]$MetricsBlock,
        [AllowEmptyCollection()][AllowNull()][object[]]$Comments
    )

    # Guard: a review credit already exists — do not synthesize.
    $existingReviewCredit = @($MetricsBlock.Credits | Where-Object { [string]$_.Port -eq 'review' })
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

function Build-ReviewCreditRow {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$JudgeRulingsComment,
        [string]$AdapterName = 'standard',
        [string]$AdaptersDir = '',
        [int]$RunIndex = 1,
        [string]$Evidence = ''
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

    return [pscustomobject]@{
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

            # Escape pipe characters in cell content to avoid table breakage.
            $portName  = $portName  -replace '\|', '\|'
            $evidence  = $evidence  -replace '\|', '\|'
            $nextStep  = $nextStep  -replace '\|', '\|'

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
