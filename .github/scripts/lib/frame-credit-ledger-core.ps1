#Requires -Version 7.0
<#!
.SYNOPSIS
    Pure-logic library for the frame credit-ledger pre-PR warn hook (issue #429).

    Exposes these functions:
      - Read-PRMetricsBlock               : parse a pipeline-metrics v4 marker out of a PR body
      - Select-LastCreditByRunIndex       : pick the highest-run_index credit for (port, adapter)
    - Select-AuthoritativeCreditForPort : pick the visible per-port credit, honoring terminal-step identities
      - Test-ReviewSentinelPresent        : check for <!-- review-judge-produced-{PR} --> sentinel
      - Resolve-NotPersistedSynthesis     : synthesize not-persisted credit when sentinel present
      - Build-ReviewCreditRow             : construct a v4 review credit row from judge-rulings
                                           comment + adapter integrity contract (issue #441, Step 8b)
    - Resolve-AdversarialPipelineAtomicMarkerPresence
                             : classify warn-only presence of <!-- adversarial-pipeline-atomic-{ISSUE_ID} -->
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

function script:Get-FCLNestedScalar {
    # Reads a child key from a parent block in YAML text.
    # Returns the value only when the child key appears at exactly one indent level deeper than the parent key.
    # Returns $null when the parent block is absent, or the child key is absent inside it, or is at the wrong depth.
    # DO NOT replace with Get-FCLScalar — the flat regex in that function matches at any depth, defeating nesting constraints.
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Block,
        [Parameter(Mandatory)][string]$ParentKey,
        [Parameter(Mandatory)][string]$ChildKey
    )

    if ([string]::IsNullOrEmpty($Block)) {
        return $null
    }

    $lines = script:ConvertTo-FCLNormalizedLines -Text $Block

    $parentIndent = -1
    $insideParent = $false

    foreach ($line in $lines) {
        # Skip blank lines
        if ($line -match '^\s*$') { continue }

        # Determine current line indentation
        $trimmed = $line.TrimStart()
        $currentIndent = $line.Length - $trimmed.Length

        if (-not $insideParent) {
            # Look for the parent key at any column (top-level is column 0)
            $parentPattern = '^(\s*)' + [regex]::Escape($ParentKey) + '\s*:\s*$'
            if ($line -match $parentPattern) {
                $parentIndent = $Matches[1].Length
                $insideParent = $true
            }
            continue
        }

        # We are inside the parent block
        # If we see a line at same or lesser indent as parent, the block has ended
        if ($currentIndent -le $parentIndent) {
            return $null
        }

        # The child must be at exactly parentIndent + some positive indent (any depth > parent qualifies,
        # but we require the child key to appear before any sub-block ends).
        # Look for the child key at this indent level (must be deeper than parent)
        $childPattern = '^(\s+)' + [regex]::Escape($ChildKey) + '\s*:\s*(?<value>.+?)\s*$'
        if ($line -match $childPattern) {
            $childIndent = $Matches[1].Length
            # Child must be strictly deeper than parent
            if ($childIndent -gt $parentIndent) {
                $value = $line -replace ('^(\s+)' + [regex]::Escape($ChildKey) + '\s*:\s*'), ''
                return $value.Trim()
            }
        }
    }

    return $null
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

function script:ConvertTo-FCLScalarValue {
    param([AllowEmptyString()][string]$Value)

    $normalizedValue = $Value.Trim()
    if ($normalizedValue.Length -ge 2) {
        $first = $normalizedValue[0]
        $last = $normalizedValue[$normalizedValue.Length - 1]
        if (($first -eq '"' -and $last -eq '"') -or ($first -eq "'" -and $last -eq "'")) {
            $normalizedValue = $normalizedValue.Substring(1, $normalizedValue.Length - 2)
        }
    }

    return $normalizedValue
}

function script:Get-FCLDispatchCostSampleKeysAndValues {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Chunk)

    $keyOrder = [System.Collections.Generic.List[string]]::new()
    $values = @{}

    foreach ($line in @($Chunk -split "`n")) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }

        $trimmed = $line.TrimStart()
        if ($trimmed.StartsWith('#')) { continue }
        if ($trimmed -eq '-') { continue }
        if ($trimmed.StartsWith('- ')) {
            $trimmed = $trimmed.Substring(2).TrimStart()
        }

        $keyValueMatch = [regex]::Match($trimmed, '^(?<key>[A-Za-z0-9_-]+)\s*:\s*(?<value>.*)$')
        if (-not $keyValueMatch.Success) {
            throw 'row contains a non key/value line'
        }

        $fieldName = $keyValueMatch.Groups['key'].Value
        $fieldValue = script:ConvertTo-FCLScalarValue -Value $keyValueMatch.Groups['value'].Value
        [void]$keyOrder.Add($fieldName)
        $values[$fieldName] = $fieldValue
    }

    return [pscustomobject]@{
        KeyOrder = $keyOrder.ToArray()
        Values   = $values
    }
}

function script:ConvertFrom-FCLDispatchCostSampleChunk {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Chunk)

    $requiredKeys = @('step-id', 'mode', 'bytes', 'rc-conformance', 'judge-disposition')
    $modeValues = @('spine', 'legacy-fallback', 'budget-exceeded')
    $rcConformanceValues = @('pass', 'fail', 'not-evaluated')
    $judgeDispositionValues = @('accepted', 'rejected', 'deferred', 'not-evaluated')

    $parsed = script:Get-FCLDispatchCostSampleKeysAndValues -Chunk $Chunk
    $keyOrder = @($parsed.KeyOrder)
    if ($keyOrder.Count -notin @($requiredKeys.Count, ($requiredKeys.Count + 1), ($requiredKeys.Count + 2))) {
        throw 'row must contain exactly step-id, mode, bytes, rc-conformance, judge-disposition (optionally followed by provider and/or model)'
    }

    for ($keyIndex = 0; $keyIndex -lt $requiredKeys.Count; $keyIndex++) {
        if ($keyOrder[$keyIndex] -ne $requiredKeys[$keyIndex]) {
            throw 'row keys must be exactly step-id, mode, bytes, rc-conformance, judge-disposition in that order'
        }
    }
    if ($keyOrder.Count -ge 6 -and $keyOrder[5] -notin @('provider', 'model')) {
        throw 'row keys must be exactly step-id, mode, bytes, rc-conformance, judge-disposition (with optional provider or model as 6th key)'
    }
    if ($keyOrder.Count -eq 7 -and ($keyOrder[5] -ne 'provider' -or $keyOrder[6] -ne 'model')) {
        throw 'row keys must be exactly step-id, mode, bytes, rc-conformance, judge-disposition, provider, model in that order when 7 keys are present'
    }

    $values = $parsed.Values
    foreach ($requiredKey in $requiredKeys) {
        if (-not $values.ContainsKey($requiredKey) -or [string]::IsNullOrWhiteSpace([string]$values[$requiredKey])) {
            throw "row is missing $requiredKey"
        }
    }

    if ($modeValues -notcontains [string]$values['mode']) {
        throw 'mode must be spine, legacy-fallback, or budget-exceeded'
    }
    if ($rcConformanceValues -notcontains [string]$values['rc-conformance']) {
        throw 'rc-conformance must be pass, fail, or not-evaluated'
    }
    if ($judgeDispositionValues -notcontains [string]$values['judge-disposition']) {
        throw 'judge-disposition must be accepted, rejected, deferred, or not-evaluated'
    }

    $bytesValue = 0
    if (-not [int]::TryParse([string]$values['bytes'], [ref]$bytesValue)) {
        throw 'bytes must be an integer'
    }

    $providerParam = @{}
    if ($keyOrder.Count -ge 6 -and $values.ContainsKey('provider') -and -not [string]::IsNullOrWhiteSpace([string]$values['provider'])) {
        $providerParam['Provider'] = [string]$values['provider']
    }
    $modelParam = @{}
    if ($values.ContainsKey('model') -and -not [string]::IsNullOrWhiteSpace([string]$values['model'])) {
        $modelParam['Model'] = [string]$values['model']
    }
    return New-DispatchCostSampleRow `
        -StepId ([string]$values['step-id']) `
        -Mode ([string]$values['mode']) `
        -Bytes $bytesValue `
        -RcConformance ([string]$values['rc-conformance']) `
        -JudgeDisposition ([string]$values['judge-disposition']) `
        @providerParam `
        @modelParam
}

function script:Set-FCLDispatchCostSamplesSection {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$MetricsBlock,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Samples
    )

    $eol = if ($MetricsBlock.Contains("`r`n")) { "`r`n" } else { "`n" }
    $normalized = $MetricsBlock -replace "`r`n", "`n" -replace "`r", "`n"
    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($line in @($normalized -split "`n")) { [void]$lines.Add($line) }

    $sectionStart = -1
    $sectionEnd = -1
    $sectionIndent = 0
    for ($lineIndex = 0; $lineIndex -lt $lines.Count; $lineIndex++) {
        $sectionMatch = [regex]::Match($lines[$lineIndex], '^(?<indent>\s*)dispatch-cost-samples\s*:\s*$')
        if ($sectionMatch.Success) {
            $sectionStart = $lineIndex
            $sectionIndent = $sectionMatch.Groups['indent'].Value.Length
            break
        }
    }

    # Collect existing rows from current section before removal
    $existingRows = [System.Collections.Generic.List[object]]::new()
    if ($sectionStart -ge 0) {
        $sectionEnd = $lines.Count
        for ($lineIndex = $sectionStart + 1; $lineIndex -lt $lines.Count; $lineIndex++) {
            $line = $lines[$lineIndex]
            if ([string]::IsNullOrWhiteSpace($line)) { continue }

            $trimmed = $line.TrimStart()
            $indent = $line.Length - $trimmed.Length
            if ($indent -le $sectionIndent -and -not $trimmed.StartsWith('#')) {
                $sectionEnd = $lineIndex
                break
            }
        }

        $existingChunks = script:Get-FCLEntryChunks -Block $MetricsBlock -SectionName 'dispatch-cost-samples'
        foreach ($chunk in $existingChunks) {
            try {
                $existingRows.Add((script:ConvertFrom-FCLDispatchCostSampleChunk -Chunk $chunk)) | Out-Null
            } catch {
                Write-Verbose "frame-credit-ledger: discarded malformed dispatch-cost-sample chunk: $($_.Exception.Message)"
            }
        }

        for ($lineIndex = $sectionEnd - 1; $lineIndex -ge $sectionStart; $lineIndex--) {
            $lines.RemoveAt($lineIndex)
        }
    }

    # Build merged list: existing rows that aren't overridden + all incoming samples
    $mergedRows = [System.Collections.Generic.List[object]]::new()
    foreach ($existing in $existingRows) {
        $override = $null
        foreach ($incoming in @($Samples)) {
            $existingProvider = if ($existing.PSObject.Properties['provider']) { [string]$existing.provider } else { $null }
            $incomingProvider = if ($incoming.PSObject.Properties['provider']) { [string]$incoming.provider } else { $null }
            $providerMatch = ($null -eq $existingProvider -and $null -eq $incomingProvider) -or ($existingProvider -eq $incomingProvider)
            $existingModel = if ($existing.PSObject.Properties['model']) { [string]$existing.model } else { $null }
            $incomingModel = if ($incoming.PSObject.Properties['model']) { [string]$incoming.model } else { $null }
            $modelMatch = ($null -eq $existingModel -and $null -eq $incomingModel) -or ($existingModel -eq $incomingModel)
            if ([string]$existing.'step-id' -eq [string]$incoming.'step-id' -and [string]$existing.mode -eq [string]$incoming.mode -and $providerMatch -and $modelMatch) {
                $override = $incoming
                break
            }
        }
        if ($null -eq $override) { $mergedRows.Add($existing) | Out-Null }
    }
    foreach ($incoming in @($Samples)) { $mergedRows.Add($incoming) | Out-Null }

    if ($mergedRows.Count -eq 0) {
        return ($lines.ToArray() -join $eol)
    }

    $sectionLines = [System.Collections.Generic.List[string]]::new()
    [void]$sectionLines.Add('dispatch-cost-samples:')
    foreach ($sample in $mergedRows) {
        [void]$sectionLines.Add("  - step-id: $($sample.'step-id')")
        [void]$sectionLines.Add("    mode: $($sample.mode)")
        [void]$sectionLines.Add("    bytes: $($sample.bytes)")
        [void]$sectionLines.Add("    rc-conformance: $($sample.'rc-conformance')")
        [void]$sectionLines.Add("    judge-disposition: $($sample.'judge-disposition')")
        if ($sample.PSObject.Properties['provider'] -and -not [string]::IsNullOrEmpty([string]$sample.provider)) {
            [void]$sectionLines.Add("    provider: $($sample.provider)")
        }
        if ($sample.PSObject.Properties['model'] -and -not [string]::IsNullOrEmpty([string]$sample.model)) {
            [void]$sectionLines.Add("    model: $($sample.model)")
        }
    }

    $insertIndex = if ($sectionStart -ge 0) { $sectionStart } else { $lines.Count }
    if ($sectionStart -lt 0) {
        while ($insertIndex -gt 0 -and [string]::IsNullOrWhiteSpace($lines[$insertIndex - 1])) {
            $insertIndex--
        }
    }

    for ($sectionLineIndex = 0; $sectionLineIndex -lt $sectionLines.Count; $sectionLineIndex++) {
        $lines.Insert($insertIndex + $sectionLineIndex, $sectionLines[$sectionLineIndex])
    }

    return ($lines.ToArray() -join $eol)
}

function script:Set-FCLDispatchCostSamplesInPrBody {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$PrBody,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Samples
    )

    $match = [regex]::Match($PrBody, '(?s)(?<open><!--\s*pipeline-metrics\s*)(?<block>.*?)(?<close>\s*-->)')
    if (-not $match.Success) { return $PrBody }

    $updatedBlock = script:Set-FCLDispatchCostSamplesSection -MetricsBlock $match.Groups['block'].Value -Samples $Samples
    $prefix = $PrBody.Substring(0, $match.Index)
    $suffixStart = $match.Index + $match.Length
    $suffix = $PrBody.Substring($suffixStart)

    return $prefix + $match.Groups['open'].Value + $updatedBlock + $match.Groups['close'].Value + $suffix
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

        [string[]]$dispatchCostSampleChunks = script:Get-FCLEntryChunks -Block $block -SectionName 'dispatch-cost-samples'
        if ($null -eq $dispatchCostSampleChunks) { $dispatchCostSampleChunks = [string[]]@() }

        $dispatchCostSampleList = [System.Collections.Generic.List[object]]::new()
        foreach ($dispatchCostSampleChunk in @($dispatchCostSampleChunks)) {
            try {
                [void]$dispatchCostSampleList.Add((script:ConvertFrom-FCLDispatchCostSampleChunk -Chunk $dispatchCostSampleChunk))
            }
            catch {
                throw "dispatch-cost-samples: $($_.Exception.Message)"
            }
        }
        $dispatchCostSamples = @($dispatchCostSampleList.ToArray())

        return [pscustomobject]@{
            MetricsVersion      = 4
            FrameVersion        = $frameVersion
            Credits             = $credits
            IntegrityChecks     = $integrityChecks
            DispatchCostSamples = $dispatchCostSamples
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

function New-DispatchCostSampleRow {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$StepId,
        [Parameter(Mandatory)][ValidateSet('spine', 'legacy-fallback', 'budget-exceeded')][string]$Mode,
        [Parameter(Mandatory)][int]$Bytes,
        [ValidateSet('pass', 'fail', 'not-evaluated')][string]$RcConformance = 'not-evaluated',
        [ValidateSet('accepted', 'rejected', 'deferred', 'not-evaluated')][string]$JudgeDisposition = 'not-evaluated',
        [string]$Provider = $null,
        [string]$Model = $null
    )

    $row = [ordered]@{
        'step-id'           = $StepId
        mode                = $Mode
        bytes               = $Bytes
        'rc-conformance'    = $RcConformance
        'judge-disposition' = $JudgeDisposition
    }
    if (-not [string]::IsNullOrEmpty($Provider)) {
        $row['provider'] = $Provider
    }
    if (-not [string]::IsNullOrEmpty($Model)) {
        $row['model'] = $Model
    }
    return [pscustomobject]$row
}

function Add-DispatchCostSampleToPrBody {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$PrBody,
        [Parameter(Mandatory)][string]$StepId,
        [Parameter(Mandatory)][ValidateSet('spine', 'legacy-fallback', 'budget-exceeded')][string]$Mode,
        [Parameter(Mandatory)][int]$Bytes,
        [ValidateSet('pass', 'fail', 'not-evaluated')][string]$RcConformance = 'not-evaluated',
        [ValidateSet('accepted', 'rejected', 'deferred', 'not-evaluated')][string]$JudgeDisposition = 'not-evaluated',
        [string]$Provider = $null,
        [string]$Model = $null
    )

    $metrics = Read-PRMetricsBlock -PrBody $PrBody
    if ($null -eq $metrics -or $metrics.MetricsVersion -ne 4) { return $PrBody }

    $samples = [System.Collections.Generic.List[object]]::new()
    foreach ($sample in @($metrics.DispatchCostSamples)) { [void]$samples.Add($sample) }

    $existingIndex = -1
    for ($sampleIndex = 0; $sampleIndex -lt $samples.Count; $sampleIndex++) {
        $sample = $samples[$sampleIndex]
        $sampleProvider = if ($sample.PSObject.Properties['provider']) { [string]$sample.provider } else { $null }
        $providerMatch = ($null -eq $sampleProvider -and [string]::IsNullOrEmpty($Provider)) -or ($sampleProvider -eq $Provider)
        $sampleModel = if ($sample.PSObject.Properties['model']) { [string]$sample.model } else { $null }
        $modelMatch = ($null -eq $sampleModel -and [string]::IsNullOrEmpty($Model)) -or ($sampleModel -eq $Model)
        if ([string]$sample.'step-id' -eq $StepId -and [string]$sample.mode -eq $Mode -and $providerMatch -and $modelMatch) {
            $existingIndex = $sampleIndex
            break
        }
    }

    if ($existingIndex -ge 0) {
        $existingSample = $samples[$existingIndex]
        $existingProvider = if ($existingSample.PSObject.Properties['provider']) { [string]$existingSample.provider } else { $null }
        $effectiveProvider = if (-not [string]::IsNullOrEmpty($Provider)) { $Provider } elseif (-not [string]::IsNullOrEmpty($existingProvider)) { $existingProvider } else { $null }
        $existingModel = if ($existingSample.PSObject.Properties['model']) { [string]$existingSample.model } else { $null }
        $effectiveModel = if (-not [string]::IsNullOrEmpty($Model)) { $Model } elseif (-not [string]::IsNullOrEmpty($existingModel)) { $existingModel } else { $null }
        $providerParam = if (-not [string]::IsNullOrEmpty($effectiveProvider)) { @{ Provider = $effectiveProvider } } else { @{} }
        $modelParam = if (-not [string]::IsNullOrEmpty($effectiveModel)) { @{ Model = $effectiveModel } } else { @{} }
        $samples[$existingIndex] = New-DispatchCostSampleRow `
            -StepId $StepId `
            -Mode $Mode `
            -Bytes $Bytes `
            -RcConformance ([string]$existingSample.'rc-conformance') `
            -JudgeDisposition ([string]$existingSample.'judge-disposition') `
            @providerParam `
            @modelParam
    }
    else {
        $providerParam = if (-not [string]::IsNullOrEmpty($Provider)) { @{ Provider = $Provider } } else { @{} }
        $modelParam = if (-not [string]::IsNullOrEmpty($Model)) { @{ Model = $Model } } else { @{} }
        [void]$samples.Add((New-DispatchCostSampleRow `
                    -StepId $StepId `
                    -Mode $Mode `
                    -Bytes $Bytes `
                    -RcConformance $RcConformance `
                    -JudgeDisposition $JudgeDisposition `
                    @providerParam `
                    @modelParam))
    }

    return script:Set-FCLDispatchCostSamplesInPrBody -PrBody $PrBody -Samples $samples.ToArray()
}

function Update-DispatchCostSampleEvaluationInPrBody {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$PrBody,
        [Parameter(Mandatory)][string]$StepId,
        [Parameter(Mandatory)][ValidateSet('spine', 'legacy-fallback', 'budget-exceeded')][string]$Mode,
        [ValidateSet('pass', 'fail', 'not-evaluated')][string]$RcConformance,
        [ValidateSet('accepted', 'rejected', 'deferred', 'not-evaluated')][string]$JudgeDisposition,
        [string]$Provider = $null,
        [string]$Model = $null
    )

    $metrics = Read-PRMetricsBlock -PrBody $PrBody
    if ($null -eq $metrics -or $metrics.MetricsVersion -ne 4) { return $PrBody }

    $samples = [System.Collections.Generic.List[object]]::new()
    $updated = $false
    $filterByProvider = $PSBoundParameters.ContainsKey('Provider') -and -not [string]::IsNullOrEmpty($Provider)
    $filterByModel = $PSBoundParameters.ContainsKey('Model') -and -not [string]::IsNullOrEmpty($Model)
    foreach ($sample in @($metrics.DispatchCostSamples)) {
        $sampleProvider = if ($sample.PSObject.Properties['provider']) { [string]$sample.provider } else { $null }
        $sampleModel = if ($sample.PSObject.Properties['model']) { [string]$sample.model } else { $null }
        # Without -Provider: match only legacy rows lacking a provider field (backward compat).
        # With -Provider: match only rows whose provider equals the specified value.
        # This prevents cross-provider contamination once multi-provider rows coexist (post-#545).
        $providerMatch = if ($filterByProvider) { $sampleProvider -eq $Provider } else { [string]::IsNullOrEmpty($sampleProvider) }
        # Without -Model: match any row regardless of model (opt-in — back-fill callers that
        # don't know the model tier should still be able to update all matching rows).
        # With -Model: match only rows whose model equals the specified value.
        # This prevents cross-model contamination when the caller knows which model row to target.
        $modelMatch = if ($filterByModel) { $sampleModel -eq $Model } else { $true }

        if ([string]$sample.'step-id' -eq $StepId -and [string]$sample.mode -eq $Mode -and $providerMatch -and $modelMatch) {
            $updatedRcConformance = [string]$sample.'rc-conformance'
            $updatedJudgeDisposition = [string]$sample.'judge-disposition'
            if ($PSBoundParameters.ContainsKey('RcConformance')) { $updatedRcConformance = $RcConformance }
            if ($PSBoundParameters.ContainsKey('JudgeDisposition')) { $updatedJudgeDisposition = $JudgeDisposition }

            # Preserve the existing row's provider and model fields — never drop on back-fill (issue #514 F1 for provider; mirrors for model)
            $preservedProvider = if ($sample.PSObject.Properties['provider']) { [string]$sample.provider } else { $null }
            $providerArgs = @{}
            if (-not [string]::IsNullOrEmpty($preservedProvider)) { $providerArgs['Provider'] = $preservedProvider }
            $preservedModel = if ($sample.PSObject.Properties['model']) { [string]$sample.model } else { $null }
            $modelArgs = @{}
            if (-not [string]::IsNullOrEmpty($preservedModel)) { $modelArgs['Model'] = $preservedModel }

            [void]$samples.Add((New-DispatchCostSampleRow `
                        -StepId ([string]$sample.'step-id') `
                        -Mode ([string]$sample.mode) `
                        -Bytes ([int]$sample.bytes) `
                        -RcConformance $updatedRcConformance `
                        -JudgeDisposition $updatedJudgeDisposition `
                        @providerArgs `
                        @modelArgs))
            $updated = $true
        }
        else {
            [void]$samples.Add($sample)
        }
    }

    if (-not $updated) { return $PrBody }

    return script:Set-FCLDispatchCostSamplesInPrBody -PrBody $PrBody -Samples $samples.ToArray()
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

function Resolve-AdversarialPipelineAtomicMarkerPresence {
    [CmdletBinding()]
    param(
        [AllowNull()][object]$AdapterAtomicState = $false,
        [AllowEmptyString()][string]$Text = '',
        [AllowEmptyString()][string]$IssueId = '',
        [AllowEmptyString()][string]$MarkerTemplate = '<!-- adversarial-pipeline-atomic-{ISSUE_ID} -->'
    )

    $atomicValue = if ($null -eq $AdapterAtomicState) { '' } else { ([string]$AdapterAtomicState).Trim() }
    $adapterDeclaresAtomic = $false
    if ($AdapterAtomicState -is [bool]) {
        $adapterDeclaresAtomic = [bool]$AdapterAtomicState
    }
    elseif ($atomicValue.Equals('true', [System.StringComparison]::OrdinalIgnoreCase)) {
        $adapterDeclaresAtomic = $true
    }

    if (-not $adapterDeclaresAtomic) {
        return [pscustomobject]@{
            adversarial_pipeline_atomic_marker_present = 'not-applicable'
            marker = $MarkerTemplate
            warning = ''
        }
    }

    $marker = $MarkerTemplate
    if (-not [string]::IsNullOrWhiteSpace($IssueId)) {
        $marker = $MarkerTemplate.Replace('{ISSUE_ID}', $IssueId.Trim())
    }

    $markerPresent = $false
    if (-not [string]::IsNullOrEmpty($Text)) {
        if ($Text.Contains($marker)) {
            $markerPresent = $true
        }
        elseif ([string]::IsNullOrWhiteSpace($IssueId) -and $Text -match '<!--\s*adversarial-pipeline-atomic-\d+\s*-->') {
            $markerPresent = $true
        }
    }

    $status = if ($markerPresent) {
        'true'
    }
    elseif ([string]::IsNullOrWhiteSpace($IssueId)) {
        'not-applicable'
    }
    else {
        'false-warn-only'
    }
    $warning = if ($status -eq 'false-warn-only') {
        "adversarial_pipeline_atomic_marker_present=false-warn-only; expected marker $marker for an applicable atomic adversarial adapter"
    }
    else { '' }

    return [pscustomobject]@{
        adversarial_pipeline_atomic_marker_present = $status
        marker = $marker
        warning = $warning
    }
}

function script:ConvertFrom-FCLInlineIntegerList {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$ListValue)

    return @(
        $ListValue -split '[,\s]+' |
        Where-Object { $_ -match '^\d+$' } |
        ForEach-Object { [int]$_ }
    )
}

function script:Resolve-FCLReviewIntegrityContract {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$AdapterName,
        [AllowEmptyString()][string]$AdaptersDir = ''
    )

    $prosecutionPasses = @(1, 2, 3, 4, 5)
    $integrityStatus = 'passed'

    if ($AdapterName -in @('post-fix', 'lite')) {
        $prosecutionPasses = @(1)
    }
    elseif ($AdapterName -in @('judge-only', 'proxy-github')) {
        $prosecutionPasses = @()
        $integrityStatus = 'not-applicable'
    }

    if (-not [string]::IsNullOrWhiteSpace($AdaptersDir)) {
        $adapterMd = Join-Path $AdaptersDir "$AdapterName.md"
        if (Test-Path -LiteralPath $adapterMd) {
            try {
                $content = Get-Content -LiteralPath $adapterMd -Raw -ErrorAction Stop
                $isExempt = $false
                if ($content -match '(?ms)integrity-contract:.*?exempt:\s*(?<val>true|false)') {
                    $isExempt = [System.Boolean]::Parse($matches['val'].Trim())
                }

                if ($isExempt) {
                    $prosecutionPasses = @()
                    $integrityStatus = 'not-applicable'
                }
                elseif ($content -match '(?ms)integrity-contract:.*?prosecution-passes:\s*\[(?<passes>[^\]]*)\]') {
                    $prosecutionPasses = @(script:ConvertFrom-FCLInlineIntegerList -ListValue $matches['passes'])
                    $integrityStatus = 'passed'
                }
            }
            catch {
                $null = $_
            }
        }
    }

    return [pscustomobject]@{
        ProsecutionPasses = $prosecutionPasses
        IntegrityStatus   = $integrityStatus
    }
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
    # No legacy compatibility shim for pass-blocks is needed here because this
    # builder reads current-tree adapter frontmatter, not historical PR bodies.
    $integrityContract = script:Resolve-FCLReviewIntegrityContract -AdapterName $AdapterName -AdaptersDir $AdaptersDir

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
            'prosecution-passes' = $integrityContract.ProsecutionPasses
            status               = $integrityContract.IntegrityStatus
        }
    }

    return script:Add-FCLTerminalStepId -Row $row -Step $Step
}

# ---------------------------------------------------------------------------
# Build-ProcessReviewCreditRow (issue #443, Step 3)
#
# Canonical emitter for the process-review frame port (SMC-16 dedupe contract:
# this builder is the only authoritative emitter; the SMC-16 fallback path
# synthesizes a not-persisted row for legacy PRs that predate this builder).
#
# Parameters:
#   DefectsFound        — integer count of CE Gate defects (from CeGate block)
#   AdapterName         — adapter that filled the port (default: 'standard')
#   Evidence            — custom evidence string; auto-generated when absent
#
# Status resolution:
#   defectsFound > 0  → passed (process-review was triggered and ran)
#   defectsFound == 0 → not-applicable (trigger predicate false; port excluded)
#   no CeGate data    → skipped (data unavailable; warn-only)
# ---------------------------------------------------------------------------
function Build-ProcessReviewCreditRow {
    [CmdletBinding()]
    param(
        [AllowNull()][object]$DefectsFound = $null,
        [string]$AdapterName = 'standard',
        [int]$RunIndex = 1,
        [string]$Evidence = ''
    )

    if ($null -eq $DefectsFound) {
        $resolvedEvidence = if (-not [string]::IsNullOrWhiteSpace($Evidence)) { $Evidence }
                            else { 'ceGate.defectsFound not available; process-review trigger cannot be evaluated.' }
        return [pscustomobject]@{
            port      = 'process-review'
            adapter   = $AdapterName
            status    = 'skipped'
            run_index = $RunIndex
            evidence  = $resolvedEvidence
        }
    }

    $count = [int]$DefectsFound
    if ($count -gt 0) {
        $resolvedEvidence = if (-not [string]::IsNullOrWhiteSpace($Evidence)) { $Evidence }
                            else { "ceGate.defectsFound = $count; process-review triggered and ran." }
        return [pscustomobject]@{
            port      = 'process-review'
            adapter   = $AdapterName
            status    = 'passed'
            run_index = $RunIndex
            evidence  = $resolvedEvidence
        }
    }

    $resolvedEvidence = if (-not [string]::IsNullOrWhiteSpace($Evidence)) { $Evidence }
                        else { 'inferred not-applicable: no CE Gate defect signals observed; process-review trigger predicate absent.' }
    return [pscustomobject]@{
        port      = 'process-review'
        adapter   = $AdapterName
        status    = 'not-applicable'
        run_index = $RunIndex
        evidence  = $resolvedEvidence
    }
}

# Return the credit row with the highest RunIndex for a given (Port, Adapter) pair.
# When Adapter is omitted / empty, matches on Port alone.
# Returns $null when no matching entry exists.
function Select-LastCreditByRunIndex {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][Alias('Credits')][AllowEmptyCollection()][object[]]$LedgerRows,
        [Parameter(Mandatory)][string]$Port,
        [AllowEmptyString()][string]$Adapter = ''
    )

    $pool = @($LedgerRows | Where-Object { [string]$_.Port -eq $Port })
    if (-not [string]::IsNullOrWhiteSpace($Adapter)) {
        $pool = @($pool | Where-Object { [string]$_.Adapter -eq $Adapter })
    }

    if ($pool.Count -eq 0) { return $null }
    if ($pool.Count -eq 1) { return $pool[0] }

    # Sort by RunIndex descending; treat $null RunIndex as 0.
    return ($pool | Sort-Object -Property { if ($null -eq $_.RunIndex) { 0 } else { [int]$_.RunIndex } } -Descending | Select-Object -First 1)
}

function script:Get-FCLTerminalStepIdFromCredit {
    param([AllowNull()]$LedgerRow)

    if ($null -eq $LedgerRow) { return 0 }

    $raw = $null
    if ($LedgerRow -is [System.Collections.IDictionary]) {
        if ($LedgerRow.Contains('TerminalStepId')) { $raw = $LedgerRow['TerminalStepId'] }
        elseif ($LedgerRow.Contains('terminal-step-id')) { $raw = $LedgerRow['terminal-step-id'] }
    }
    else {
        if ($null -ne $LedgerRow.PSObject.Properties['TerminalStepId']) { $raw = $LedgerRow.TerminalStepId }
        elseif ($null -ne $LedgerRow.PSObject.Properties['terminal-step-id']) { $raw = $LedgerRow.'terminal-step-id' }
    }

    $step = 0
    if ($null -ne $raw -and [int]::TryParse([string]$raw, [ref]$step) -and $step -gt 0) {
        return $step
    }

    return 0
}

function script:Get-FCLRunIndexFromCredit {
    param([AllowNull()]$LedgerRow)

    if ($null -eq $LedgerRow) { return 0 }

    $raw = $null
    if ($LedgerRow -is [System.Collections.IDictionary]) {
        if ($LedgerRow.Contains('RunIndex')) { $raw = $LedgerRow['RunIndex'] }
        elseif ($LedgerRow.Contains('run_index')) { $raw = $LedgerRow['run_index'] }
    }
    else {
        if ($null -ne $LedgerRow.PSObject.Properties['RunIndex']) { $raw = $LedgerRow.RunIndex }
        elseif ($null -ne $LedgerRow.PSObject.Properties['run_index']) { $raw = $LedgerRow.run_index }
    }

    $runIndex = 0
    if ($null -ne $raw -and [int]::TryParse([string]$raw, [ref]$runIndex) -and $runIndex -gt 0) {
        return $runIndex
    }

    return 0
}

function script:Get-FCLCreditStatusPrecedence {
    param([AllowNull()]$LedgerRow)

    $status = if ($null -eq $LedgerRow) { '' } else { [string]$LedgerRow.Status }
    switch ($status) {
        'overridden'     { return 70 }   # override beats failed — must come first
        'failed'         { return 60 }
        'inconclusive'   { return 50 }
        'not-persisted'  { return 40 }
        'skipped'        { return 30 }
        'not-applicable' { return 20 }
        'passed'         { return 10 }
        default          { return 0 }
    }
}

function script:Select-FCLCreditByStatusPrecedence {
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$LedgerRows)

    $rows = @($LedgerRows | Where-Object { $null -ne $_ })
    if ($rows.Count -eq 0) { return $null }
    if ($rows.Count -eq 1) { return $rows[0] }

    return ($rows | Sort-Object -Property `
            @{ Expression = { script:Get-FCLCreditStatusPrecedence -LedgerRow $_ }; Descending = $true }, `
            @{ Expression = { script:Get-FCLRunIndexFromCredit -LedgerRow $_ }; Descending = $true } |
        Select-Object -First 1)
}

function Select-AuthoritativeCreditForPort {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][Alias('Credits')][AllowEmptyCollection()][object[]]$LedgerRows,
        [Parameter(Mandatory)][string]$Port
    )

    $pool = @($LedgerRows | Where-Object { [string]$_.Port -eq $Port })
    if ($pool.Count -eq 0) { return $null }

    $terminalRows = @($pool | Where-Object { (script:Get-FCLTerminalStepIdFromCredit -LedgerRow $_) -gt 0 })
    if ($terminalRows.Count -gt 0) {
        $latestTerminalStep = @($terminalRows | ForEach-Object { script:Get-FCLTerminalStepIdFromCredit -LedgerRow $_ } | Measure-Object -Maximum)[0].Maximum
        $latestTerminalRows = @($terminalRows | Where-Object { (script:Get-FCLTerminalStepIdFromCredit -LedgerRow $_) -eq [int]$latestTerminalStep })
        return script:Select-FCLCreditByStatusPrecedence -LedgerRows $latestTerminalRows
    }

    return Select-LastCreditByRunIndex -LedgerRows $pool -Port $Port
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

            # Read block-on-inconclusive from the nested enforce: block.
            # Default is $true (fail-safe) when the enforce: block or child key is absent.
            # DO NOT use Get-FCLScalar here — the flat regex matches at any depth, defeating enforce: namespacing (M21/R2-8).
            $rawBOI = script:Get-FCLNestedScalar -Block $raw -ParentKey 'enforce' -ChildKey 'block-on-inconclusive'
            $blockOnInconclusive = if ($null -eq $rawBOI) { $true } else { $rawBOI -eq 'true' }

            $triggerStatus = script:Get-FCLScalar -Block $raw -Name 'trigger-status'
            $triggerDeferredTo = script:Get-FCLScalar -Block $raw -Name 'trigger-deferred-to'

            $results.Add([pscustomobject]@{
                    Name                = $name
                    Description         = $description
                    Applies             = $applies
                    Status              = $status
                    BlockOnInconclusive = [bool]$blockOnInconclusive
                    TriggerStatus       = if ([string]::IsNullOrWhiteSpace($triggerStatus)) { $null } else { $triggerStatus }
                    TriggerDeferredTo   = if ([string]::IsNullOrWhiteSpace($triggerDeferredTo)) { $null } else { $triggerDeferredTo }
                }) | Out-Null
        }
        catch {
            [Console]::Error.WriteLine("Get-PortFiles: skipped port file '$($file.FullName)' due to error: $($_.Exception.Message)")
            continue
        }
    }

    return $results.ToArray()
}

function Resolve-FCLRecoveryCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PortName,
        [Parameter(Mandatory)][string]$SubReason
    )

    # Port-specific registry (checked first)
    $portRegistry = @{
        'review'             = 'Run /orchestra:review to complete the adversarial review pipeline'
        'post-fix-review'    = 'Run /orchestra:review (post-fix) after Code-Smith applies fixes'
        'ce-gate-cli'        = 'Run /experience {N} CE Gate to capture CE Gate evidence for the CLI surface'
        'ce-gate-browser'    = 'Run /experience {N} CE Gate to capture CE Gate evidence for the browser surface'
        'ce-gate-canvas'     = 'Run /experience {N} CE Gate to capture CE Gate evidence for the canvas surface'
        'ce-gate-api'        = 'Run /experience {N} CE Gate to capture CE Gate evidence for the API surface'
        'plan'               = 'Run /plan {N} to produce an implementation plan'
        'design'             = 'Run /design {N} to produce a technical design'
        'experience'         = 'Run /experience {N} to produce customer framing'
        'release-hygiene'    = 'Ensure a version bump and CHANGELOG entry are present in this PR'
        'post-pr'            = 'Run post-PR archival steps via /orchestrate after the PR merges'
        'implement-code'     = 'Ensure the implement-code credit row is present in the PR pipeline-metrics block'
        'implement-test'     = 'Ensure the implement-test credit row is present in the PR pipeline-metrics block'
        'implement-refactor' = 'Ensure the implement-refactor credit row is present in the PR pipeline-metrics block'
        'implement-docs'     = 'Ensure the implement-docs credit row is present in the PR pipeline-metrics block'
        'process-review'     = 'Run Process-Review agent to complete systemic analysis'
    }

    # Sub-reason fallback registry (when no port-specific entry or as supplement)
    $subReasonRegistry = @{
        'NoEvidence'             = "No adapters or credits found for port '$PortName'. Check that the frame spine declares this port and that credits were emitted."
        'MissingNextStepField'   = "Adapter for port '$PortName' has no SuggestedNextStep field. Update the adapter YAML to include a suggested-next-step value."
        'AdapterParseError'      = "Adapter YAML for port '$PortName' failed to parse. Fix the adapter file syntax and re-run the hook."
        'AdapterDiscoveryFailed' = "All adapters for port '$PortName' returned unknown applicability. Check that the adapter's applies-when predicate is correctly wired."
        'UnknownCreditStatus'    = "Credit for port '$PortName' has an unrecognized status. Valid statuses: passed, failed, skipped, not-applicable, inconclusive, not-persisted, overridden."
    }

    if ($portRegistry.ContainsKey($PortName)) {
        return $portRegistry[$PortName]
    }

    if ($subReasonRegistry.ContainsKey($SubReason)) {
        return $subReasonRegistry[$SubReason]
    }

    # Absolute fallback — always non-empty
    return "Check port '$PortName' (sub-reason: $SubReason): verify that the frame spine declares this port and that the producing adapter emitted a valid credit."
}

function Resolve-PortStatus {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Port,
        $WorkAdapters,
        $ApplicableMap,
        [Alias('Credit')]$LedgerRow
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
    if ($adapters.Count -gt 0 -and $null -eq $LedgerRow -and ($applicabilities | Where-Object { $_ -ne 'unknown' }).Count -eq 0) {
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
    if ($null -ne $LedgerRow) {
        $creditStatus = [string]$LedgerRow.Status
        $evidence = ''
        if ($null -ne $LedgerRow.PSObject.Properties['Evidence']) {
            $evidence = [string]$LedgerRow.Evidence
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
            'overridden'     = @{ Status = 'Covered'; SubReason = 'OverriddenCredit'; IncludeNextStep = $false }
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
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseApprovedVerbs', '', Justification = 'Public helper name retained for compatibility with existing tests and callers.')]
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
                    'DeferredPort'        { 'deferred' }
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
                'deferred'      { '⏸️' }
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
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseApprovedVerbs', '', Justification = 'Public helper name retained for compatibility with existing tests and callers.')]
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
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseApprovedVerbs', '', Justification = 'Public helper name retained for compatibility with existing tests and callers.')]
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
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseApprovedVerbs', '', Justification = 'Public helper name retained for compatibility with existing tests and callers.')]
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
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseApprovedVerbs', '', Justification = 'Public helper name retained for compatibility with existing tests and callers.')]
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
# Build-OrchestrationCreditRow
# ---------------------------------------------------------------------------
# NOTE: This function shadow-duplicates Build-ExperienceCreditRow / Build-DesignCreditRow / Build-PlanCreditRow.
# A future refactor (see issue #577 review P1.F7) should extract a shared Build-FCLPipelineEntryCreditRow
# helper accepting -Port, -CompletionMarkerTemplate, and -AgentName, mirroring the implement-* family's
# Build-FCLImplementCreditRow consolidation pattern. Tracked as routine technical debt.
function Build-OrchestrationCreditRow {
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
                        elseif ($status -eq 'passed') { "Code-Conductor scope-classification engagement-record present on issue #$IssueNumber." }
                        elseif ($status -eq 'not-applicable') { "Pipeline-entry change is trivial; orchestration port not applicable." }
                        else { "$AdapterName adapter; status: $status." }

    $row = [pscustomobject]@{
        port     = 'orchestration'
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

function script:Build-FCLImplementCreditRow {
    param(
        [Parameter(Mandatory)][string]$Port,
        [AllowEmptyCollection()][object[]]$ValidationEvidence = @(),
        [bool]$AutoNaResult = $false,
        [string]$AdapterName = 'work-adapter',
        [string]$Evidence = '',
        [int]$Step = 0
    )

    $resolution = script:Resolve-ImplementCreditStatus -AdapterName $AdapterName -AutoNaResult $AutoNaResult -ValidationEvidence $ValidationEvidence
    $resolvedEvidence = if (-not [string]::IsNullOrWhiteSpace($Evidence)) { $Evidence }
                        elseif ($resolution.status -eq 'skipped') { 'no validator evidence supplied to the credit-row builder' }
                        elseif ($resolution.status -eq 'failed') { "Validator failed: $($resolution.offending)" }
                        else { "$Port validation: $($resolution.status)." }

    $row = [pscustomobject]@{
        port     = $Port
        adapter  = $AdapterName
        status   = $resolution.status
        evidence = $resolvedEvidence
    }
    return script:Add-FCLTerminalStepId -Row $row -Step $Step
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

    return script:Build-FCLImplementCreditRow -Port 'implement-code' -ValidationEvidence $ValidationEvidence -AutoNaResult $AutoNaResult -AdapterName $AdapterName -Evidence $Evidence -Step $Step
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

    return script:Build-FCLImplementCreditRow -Port 'implement-test' -ValidationEvidence $ValidationEvidence -AutoNaResult $AutoNaResult -AdapterName $AdapterName -Evidence $Evidence -Step $Step
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

    return script:Build-FCLImplementCreditRow -Port 'implement-refactor' -ValidationEvidence $ValidationEvidence -AutoNaResult $AutoNaResult -AdapterName $AdapterName -Evidence $Evidence -Step $Step
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

    return script:Build-FCLImplementCreditRow -Port 'implement-docs' -ValidationEvidence $ValidationEvidence -AutoNaResult $AutoNaResult -AdapterName $AdapterName -Evidence $Evidence -Step $Step
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

# ---------------------------------------------------------------------------
# Build-DeferredPortCreditRow (issue #443, Step 4)
#
# Emitter for any port whose trigger predicate is formalized but deferred
# to a future issue.  The evidence string always begins with the parseable
# prefix DEFERRED(#NNN): so the 90-day tripwire and migration scripts can
# detect deferred rows via the single regex ^DEFERRED\(#\d+\):.
#
# Parameters:
#   Port              — frame port name (e.g. 'process-retrospective')
#   AdapterName       — adapter that filled the port (default: 'explicit-skip')
#   DeferredToIssue   — issue number that will ship the live producer (e.g. 348)
#   DeferredSince     — ISO date string when the deferral was recorded
#   Evidence          — suffix appended after the DEFERRED(#NNN): prefix;
#                       auto-generated when absent
# ---------------------------------------------------------------------------
function Build-DeferredPortCreditRow {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Port,
        [string]$AdapterName = 'explicit-skip',
        [Parameter(Mandatory)][int]$DeferredToIssue,
        [string]$DeferredSince = '',
        [int]$RunIndex = 1,
        [string]$Evidence = ''
    )

    $suffix = if (-not [string]::IsNullOrWhiteSpace($Evidence)) { $Evidence }
              elseif (-not [string]::IsNullOrWhiteSpace($DeferredSince)) {
                  "trigger predicate deferred to #$DeferredToIssue (since $DeferredSince); port excluded from coverage denominator until trigger-status flips to live."
              }
              else {
                  "trigger predicate deferred to #$DeferredToIssue; port excluded from coverage denominator until trigger-status flips to live."
              }

    return [pscustomobject]@{
        port      = $Port
        adapter   = $AdapterName
        status    = 'not-applicable'
        run_index = $RunIndex
        evidence  = "DEFERRED(#$DeferredToIssue): $suffix"
    }
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

    $script:PipelineEntryPorts = @('experience', 'design', 'plan', 'orchestration')

    $script:CompletionMarkerByPort = @{
        'experience'    = "<!-- experience-owner-complete-$IssueNumber -->"
        'design'        = "<!-- design-phase-complete-$IssueNumber -->"
        'plan'          = "<!-- plan-issue-$IssueNumber -->"
        'orchestration' = "<!-- engagement-record-orchestration-$IssueNumber -->"
    }

    $script:BuilderByPort = @{
        'experience'    = 'Build-ExperienceCreditRow'
        'design'        = 'Build-DesignCreditRow'
        'plan'          = 'Build-PlanCreditRow'
        'orchestration' = 'Build-OrchestrationCreditRow'
    }

    function script:ConvertFrom-SingleCreditInputMarker {
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

        # Returns a hashtable distinguishing "gh outage" from "gh succeeded, empty comments".
        # Reachable=$true with Comments=@() means gh confirmed zero comments on the issue.
        # Reachable=$false means the fetch failed (CLI error, non-zero exit, empty raw, or parse fail).
        # The fail-open emission path in Invoke-CreditInputHarvest depends on this disambiguation.
        try {
            $raw = & $Gh issue view $IssueNum --repo $RepoArg --json comments --paginate 2>$null
        } catch {
            return @{ Reachable = $false; Comments = @() }
        }
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($raw)) {
            return @{ Reachable = $false; Comments = @() }
        }

        try {
            $parsed = $raw | ConvertFrom-Json
            return @{ Reachable = $true; Comments = @($parsed.comments | ForEach-Object { $_.body }) }
        } catch {
            return @{ Reachable = $false; Comments = @() }
        }
    }

    # Build lookup from in-memory markers (port → payload hashtable)
    $inMemoryByPort = @{}
    # Also build in-memory completion-marker presence lookup so the in-memory branch enforces
    # the same burst-halt-on-engagement-record-failure invariant as the gh-fetched branch
    # (P2.F5 / burst-ordering invariant — Test-Writer scenario (l) negative test).
    $inMemoryCompletionByPort = @{}
    foreach ($markerText in $InMemoryMarkers) {
        $parsed = script:ConvertFrom-SingleCreditInputMarker -Text $markerText
        if ($null -ne $parsed -and $parsed.ContainsKey('port')) {
            $inMemoryByPort[$parsed['port']] = $parsed
        }
        # Detect completion markers by matching the per-port completion-marker prefix.
        foreach ($portKey in $script:CompletionMarkerByPort.Keys) {
            $completionPrefix = $script:CompletionMarkerByPort[$portKey]
            if ($markerText -like "*$completionPrefix*") {
                $inMemoryCompletionByPort[$portKey] = $true
            }
        }
    }

    $results = @()

    foreach ($port in $script:PipelineEntryPorts) {
        # Use in-memory marker when available (bypasses gh for this port).
        # Enforce burst-halt invariant: credit-input is only honored when the corresponding
        # engagement-record completion marker is also present (parallels the gh-fetched
        # branch's `$null -ne $completionPresent` guard at the bottom of this function).
        #
        # When in-memory completion IS present: emit the credit row directly (no gh needed).
        # When in-memory completion is NOT present but credit-input IS in-memory: fall through
        # to the gh-fetch path to check whether remote completion exists (cross-session case,
        # F9). The pre-parsed $payload is carried into the gh-fetch path so the credit-input
        # gh lookup is skipped; only the completion-marker check is performed via gh.
        if ($inMemoryByPort.ContainsKey($port) -and $inMemoryCompletionByPort.ContainsKey($port)) {
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

        # $payloadFromInMemory tracks whether the payload was pre-populated from the in-memory
        # branch (cross-session F9 path). When true, the gh credit-input lookup is skipped and
        # the completion check uses fail-open semantics: if gh is unreachable, emit the row
        # (the in-memory source is trusted; fail-open preserves the original bypass contract).
        $payloadFromInMemory = $inMemoryByPort.ContainsKey($port)
        $payload = if ($payloadFromInMemory) { $inMemoryByPort[$port] } else { $null }
        $attempt = 0
        $backoff = $InitialBackoffSec
        $completionPresent = $null
        $comments = @()
        $ghFetchSucceeded = $false

        while ($attempt -le $MaxRetries) {
            $fetchResult = script:Get-IssueComments -IssueNum $IssueNumber -RepoArg $Repo -Gh $GhCliPath
            $comments = @($fetchResult.Comments)
            $ghFetchSucceeded = [bool]$fetchResult.Reachable
            $completionPresent = $comments | Where-Object { $_ -like "*$completionMarker*" }

            if ($payloadFromInMemory) {
                # Payload already known from in-memory; no retry needed — just confirm
                # completion marker presence via gh (cross-session F9 check).
                break
            }

            # Normal gh-fetch path: look for the credit-input comment.
            $creditComment = $comments | Where-Object { $_ -like "*$creditMarkerPrefix*" } | Select-Object -First 1

            if ($null -ne $creditComment) {
                $payload = script:ConvertFrom-SingleCreditInputMarker -Text $creditComment
                break
            }

            # Only retry when the completion marker is present but credit-input is absent
            if ($null -eq $completionPresent -or $attempt -ge $MaxRetries) { break }

            Start-Sleep -Seconds $backoff
            $backoff *= 2
            $attempt++
        }

        # Emit a credit row when:
        #   • payload is present AND completion is confirmed via gh (both paths), OR
        #   • payload came from in-memory AND gh was unreachable (fail-open: the in-memory
        #     source is trusted, and gh failure must not silently drop in-session credits).
        #     When gh IS reachable but returns no completion marker, the row is suppressed
        #     (burst-halt invariant for the cross-session case).
        # $ghReachable is derived from an explicit fetch-success flag (not from $comments.Count),
        # so an issue with zero comments on a reachable gh is correctly treated as "reachable
        # but completion absent" → suppress, rather than "outage" → fail-open emit.
        $ghReachable = $ghFetchSucceeded
        $shouldEmit = ($null -ne $payload) -and (
            ($null -ne $completionPresent) -or
            ($payloadFromInMemory -and -not $ghReachable)
        )

        if ($shouldEmit) {
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

function Resolve-FCLOverrideMarker {
    <#
    .SYNOPSIS
        Finds an authorized <!-- frame-override-{PR} --> marker in PR comments.
    .DESCRIPTION
        Scans top-level PR comments (not PR body, not issue comments) for a
        <!-- frame-override-{PR} --> block. Returns the list of port names to
        override when a valid marker is found from an authorized author.
        Fail-closed: empty/missing author lookup -> no override granted.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int]$Pr,
        [AllowNull()][AllowEmptyCollection()][object[]]$Comments
    )

    if ($null -eq $Comments -or @($Comments).Count -eq 0) {
        return @()
    }

    # Authorized author associations (case-insensitive match)
    $authorizedAssociations = @('OWNER', 'MEMBER', 'COLLABORATOR')

    foreach ($comment in @($Comments)) {
        # Extract body
        $body = ''
        if ($comment.PSObject.Properties['body']) {
            $body = [string]$comment.body
        }
        if ([string]::IsNullOrWhiteSpace($body)) { continue }

        # Check for the frame-override-{PR} marker (anchored: must appear as an HTML
        # comment at the start of a line, not inside a fenced block or blockquote).
        # Grammar: <!-- frame-override-{PR}\nports: {csv}\nreason: {text}\n-->
        $markerPattern = "(?ms)<!--\s*frame-override-$Pr\s*\n\s*ports:\s*(?<ports>[^\n]+)\n\s*reason:\s*(?<reason>[^\n]+?)\s*\n\s*-->"
        $markerMatch = [regex]::Match($body, $markerPattern)
        if (-not $markerMatch.Success) { continue }

        # Reject if the marker appears inside a fenced code block (```...```)
        # Simple heuristic: count ``` before the match position; odd count = inside a block
        $beforeMarker = $body.Substring(0, $markerMatch.Index)
        $fenceCount = ([regex]::Matches($beforeMarker, '```') | Measure-Object).Count
        if ($fenceCount % 2 -ne 0) { continue }

        # Reject if inside a blockquote (line starts with >)
        $markerLine = ($body.Substring(0, $markerMatch.Index) -split '\n' | Select-Object -Last 1)
        if ($markerLine -match '^\s*>') { continue }

        # Validate reason is non-empty
        $reason = $markerMatch.Groups['reason'].Value.Trim()
        if ([string]::IsNullOrWhiteSpace($reason)) {
            [Console]::Error.WriteLine("frame-credit-ledger: override marker found on PR $Pr but reason is empty — override rejected")
            continue
        }

        # Validate author association (fail-closed: missing/empty -> reject)
        $authorAssociation = ''
        if ($comment.PSObject.Properties['authorAssociation']) {
            $authorAssociation = [string]$comment.authorAssociation
        }
        if ([string]::IsNullOrWhiteSpace($authorAssociation)) {
            [Console]::Error.WriteLine("frame-credit-ledger: override marker on PR $Pr from unknown author association — override rejected (fail-closed)")
            continue
        }
        if ($authorAssociation.ToUpperInvariant() -notin $authorizedAssociations) {
            $login = if ($comment.PSObject.Properties['author'] -and $comment.author.PSObject.Properties['login']) { [string]$comment.author.login } else { '(unknown)' }
            [Console]::Error.WriteLine("frame-credit-ledger: override marker on PR $Pr from unauthorized author '$login' (association: $authorAssociation) — override rejected")
            continue
        }

        # Parse port list (comma-separated)
        $portsRaw = $markerMatch.Groups['ports'].Value
        $overriddenPorts = @($portsRaw -split ',' | ForEach-Object { $_.Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        if ($overriddenPorts.Count -eq 0) {
            [Console]::Error.WriteLine("frame-credit-ledger: override marker on PR $Pr has empty ports list — override rejected")
            continue
        }

        $login = if ($comment.PSObject.Properties['author'] -and $comment.author.PSObject.Properties['login']) { [string]$comment.author.login } else { '(authorized)' }
        [Console]::Error.WriteLine("frame-credit-ledger: override applied on PR $Pr by '$login' (association: $authorAssociation) for ports: $($overriddenPorts -join ', '). Reason: $reason")
        return $overriddenPorts
    }

    return @()
}
