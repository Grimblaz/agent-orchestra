#Requires -Version 7.0
<#!
.SYNOPSIS
    Pure-logic library for the frame credit-ledger pre-PR warn hook (issue #429).

    Exposes six functions:
      - Read-PRMetricsBlock               : parse a pipeline-metrics v4 marker out of a PR body
      - Get-PortFiles                     : enumerate frame/ports/*.yaml as objects
      - Resolve-PortStatus                : classify a single port given adapters + credit
      - Compose-Comment                   : render the warn-mode markdown report
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

        $creditsRaw = script:ConvertFrom-FCLListSection -Block $block -SectionName 'credits' -Fields @('port', 'status', 'evidence')
        $credits = @($creditsRaw | ForEach-Object {
                [pscustomobject]@{
                    Port     = [string]$_.port
                    Status   = [string]$_.status
                    Evidence = [string]$_.evidence
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
    $reports = @($reports | Where-Object {
            -not ([string]$_.Status -eq 'Covered' -and [string]$_.SubReason -eq 'AutoNotApplicable')
        })

    $covered = @($reports | Where-Object { [string]$_.Status -eq 'Covered' })
    $inconclusive = @($reports | Where-Object { [string]$_.Status -eq 'Inconclusive' })
    $notCovered = @($reports | Where-Object { [string]$_.Status -eq 'NotCovered' })

    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine($MarkerToken)
    [void]$sb.AppendLine('## Frame credit ledger — port coverage report')
    [void]$sb.AppendLine('')

    if ($covered.Count -gt 0) {
        [void]$sb.AppendLine(("### ✅ Covered ({0})" -f $covered.Count))
        foreach ($r in $covered) {
            $reasonLabel = switch ([string]$r.SubReason) {
                'PassedCredit' { 'passed credit' }
                'NotApplicableCredit' { 'not applicable per credit' }
                'SkippedCredit' { 'skipped credit' }
                default { [string]$r.SubReason }
            }
            [void]$sb.AppendLine(("- {0} — {1}" -f [string]$r.PortName, $reasonLabel))
        }
        [void]$sb.AppendLine('')
    }

    if ($inconclusive.Count -gt 0) {
        [void]$sb.AppendLine(("### ⚠️ Inconclusive ({0})" -f $inconclusive.Count))
        foreach ($r in $inconclusive) {
            [void]$sb.AppendLine(("- **{0}** — {1}" -f [string]$r.PortName, [string]$r.SubReason))
            $adapterName = [string]$r.AdapterName
            if (-not [string]::IsNullOrWhiteSpace($adapterName)) {
                [void]$sb.AppendLine(("  - Adapter: {0}" -f $adapterName))
            }
            $step = $r.SuggestedNextStep
            if ($null -ne $step -and -not [string]::IsNullOrWhiteSpace([string]$step)) {
                [void]$sb.AppendLine(("  - Suggested next step: ``{0}``" -f [string]$step))
            }
        }
        [void]$sb.AppendLine('')
    }

    if ($notCovered.Count -gt 0) {
        [void]$sb.AppendLine(("### 🚫 Not covered ({0})" -f $notCovered.Count))
        foreach ($r in $notCovered) {
            [void]$sb.AppendLine(("- **{0}** — {1}" -f [string]$r.PortName, [string]$r.SubReason))
            $adapterName = [string]$r.AdapterName
            if (-not [string]::IsNullOrWhiteSpace($adapterName)) {
                [void]$sb.AppendLine(("  - Adapter: {0}" -f $adapterName))
            }
            $step = $r.SuggestedNextStep
            if ($null -ne $step -and -not [string]::IsNullOrWhiteSpace([string]$step)) {
                [void]$sb.AppendLine(("  - Suggested next step: ``{0}``" -f [string]$step))
            }
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
