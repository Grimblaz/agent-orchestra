#Requires -Version 7.0

# phase-containment-core.ps1
# Core library for phase-containment-{ID} HTML comment YAML block parsing and validation.
# Issue #762 — escape-rate ledger.
#
# SECURITY: Do NOT import powershell-yaml or use ConvertFrom-Yaml in this file.
# These are forbidden for parsing untrusted GitHub comment bodies (YamlDotNet
# billion-laughs risk). All parsing uses a hand-rolled line-regex parser only.

Set-StrictMode -Version Latest

#region Phase ordinals (TOTAL map — rejection on invalid input)

$script:PhaseOrdinals = @{
    'experience'     = 0
    'design'         = 1
    'plan'           = 2
    'implementation' = 3
}

#endregion

#region Stage projections (TOTAL map — rejection on invalid input)

$script:StageProjections = @{
    'design-challenge'     = 1
    'plan-stress-test'     = 2
    'code-review'          = 3
    'post-review-observer' = 4
}

#endregion

#region Valid enum sets

$script:ValidIntroducedPhases  = @('experience', 'design', 'plan', 'implementation')
$script:ValidCatchablePhases   = @('experience', 'design', 'plan', 'implementation')
$script:ValidCaughtStages      = @('design-challenge', 'plan-stress-test', 'code-review', 'post-review-observer')
$script:ValidSeverities        = @('critical', 'high', 'medium', 'low')
$script:ValidSystemicFixTypes  = @('instruction', 'skill', 'agent-prompt', 'plan-template', 'none')
$script:ValidCategories        = @(
    'architecture',
    'security',
    'performance',
    'pattern',
    'implementation-clarity',
    'script-automation',
    'documentation-audit'
)

#endregion

#region finding_key format (issue #772 D4)

# Must stay byte-identical to the "pattern" literal in
# skills/calibration-pipeline/schemas/phase-containment.schema.json (finding_key
# property) — the schema is the authoritative source, this is the sole consumer.
# Drift between the two is asserted by the "finding_key pattern drift" test in
# phase-containment-core.Tests.ps1 (follows the Get-PhaseContainmentEnumDriftStatus
# precedent below).
$script:FindingKeyPattern = '^(code-review|design-challenge|plan-stress-test|post-review-observer):.+'

#endregion

#region Get-PhaseContainmentBlock

function Get-PhaseContainmentBlock {
    <#
    .SYNOPSIS
        Extracts all YAML content blocks from <!-- phase-containment-{ID} --> HTML comment markers.
    .DESCRIPTION
        Returns an array of raw YAML content strings, one per block found in the text.
        Returns $null if no blocks are found.
        Strips code fences (``` yaml ... ``` or ``` ... ```) from each extracted block.
        Multiple blocks in one comment body are all returned (supporting the case where
        a judge emits multiple sustained findings into one PR comment).
    .PARAMETER Text
        The full text to search within (e.g., a GitHub issue comment body).
    .PARAMETER Id
        The ID suffix for the marker, e.g. '762' matches <!-- phase-containment-762 -->.
    .PARAMETER SkippedCount
        Optional [ref] counter incremented once per pair-match skip (issue
        #772 D6 malformed/unclosed block). Callers that need to fold
        parser-layer skips into their own drop counters (e.g.
        Invoke-PhaseContainmentCommentScan's InvalidEntryCount) pass a [ref]
        here; existing callers that omit it are unaffected.
    .OUTPUTS
        [string[]] Array of raw YAML content strings, or $null if no blocks found.
    .NOTES
        Pair-matching (issue #772 D6): if a later open tag appears before the
        next close tag, the earlier open tag is treated as an unclosed,
        malformed block. That block is skipped (with a Write-Warning, and —
        issue #772/#831 M4 — an increment of the optional -SkippedCount [ref]
        counter) and the scan resumes from the later open tag, so an
        unclosed block can no longer silently absorb the following block's
        content. A genuinely unclosed *final* block (no later open tag
        anywhere after it, so no close tag is ever found) hits the same
        "no close tag found" case below and — issue #772/#833 GH-2 — is now
        also warned and counted via -SkippedCount, matching the mid-scan
        case, before the scan stops.
    #>
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][string]$Id,
        [ref]$SkippedCount
    )

    $openTag  = "<!-- phase-containment-$Id -->"
    $closeTag = "<!-- /phase-containment-$Id -->"

    $allBlocks  = [System.Collections.Generic.List[string]]::new()
    $searchFrom = 0

    while ($true) {
        $startIdx = $Text.IndexOf($openTag, $searchFrom, [System.StringComparison]::Ordinal)
        if ($startIdx -lt 0) { break }

        $contentStart = $startIdx + $openTag.Length
        $endIdx = $Text.IndexOf($closeTag, $contentStart, [System.StringComparison]::Ordinal)
        if ($endIdx -lt 0) {
            # Unclosed final block — no close tag found anywhere after this
            # open tag. Warn and count it the same way the mid-scan
            # pair-match case does (issue #772/#833 GH-2), then stop
            # scanning; there is nothing left to resume from.
            Write-Warning "Skipping malformed phase-containment-$Id block at position ${startIdx}: no close tag found (unclosed final block)."
            if ($null -ne $SkippedCount) { $SkippedCount.Value++ }
            break
        }

        # Pair-match: if another open tag appears before this open tag's
        # close tag, this open tag is unclosed/malformed. Skip only this
        # block (warn) and resume scanning from the later open tag instead
        # of letting the unclosed block absorb the next block's content.
        $nextOpenIdx = $Text.IndexOf($openTag, $contentStart, [System.StringComparison]::Ordinal)
        if ($nextOpenIdx -ge 0 -and $nextOpenIdx -lt $endIdx) {
            Write-Warning "Skipping malformed phase-containment-$Id block at position ${startIdx}: a later open tag was found before its close tag (unclosed block)."
            if ($null -ne $SkippedCount) { $SkippedCount.Value++ }
            $searchFrom = $nextOpenIdx
            continue
        }

        $raw = $Text.Substring($contentStart, $endIdx - $contentStart).Trim()

        # Strip code fences: lines matching ``` or ``` yaml (opening) and ``` (closing)
        $lines = $raw -split '\r?\n'
        $stripped = [System.Collections.Generic.List[string]]::new()
        foreach ($line in $lines) {
            if ($line -match '^\s*```') { continue }
            $stripped.Add($line)
        }

        $result = ($stripped -join "`n").Trim()
        if ($result.Length -gt 0) { $allBlocks.Add($result) }

        $searchFrom = $endIdx + $closeTag.Length
    }

    if ($allBlocks.Count -eq 0) { return $null }
    return , $allBlocks.ToArray()
}

#endregion

#region ConvertFrom-PhaseContainmentYaml (private/internal)

function script:ConvertFrom-PhaseContainmentYamlInternal {
    <#
    .SYNOPSIS
        Hand-rolled line-regex parser for phase-containment YAML blocks.
    .DESCRIPTION
        Parses the 9 supported fields from the YAML. Returns a hashtable.
        Does NOT use ConvertFrom-Yaml or powershell-yaml.
        Unrecognized keys are ignored (additionalProperties: false is a validation
        concern, not a parse concern).
    .PARAMETER Yaml
        The raw YAML string to parse.
    .OUTPUTS
        [hashtable] Parsed field values.
    #>
    param(
        [Parameter(Mandatory)][string]$Yaml
    )

    $result = @{
        finding_key       = $null
        introduced_phase  = $null
        catchable_phase   = $null
        caught_stage      = $null
        escape_distance   = $null
        severity          = $null
        systemic_fix_type = $null
        category          = $null
        apparatus_meta    = $false
        seed              = $false
    }

    $lines = $Yaml -split '\r?\n'
    foreach ($line in $lines) {
        if ($line -match '^\s*finding_key\s*:\s*(.+)$') {
            $result['finding_key'] = ($Matches[1].Trim() -replace '\s+#.*$', '' -replace '^[''"]|[''"]$', '')
        }
        elseif ($line -match '^\s*introduced_phase\s*:\s*(.+)$') {
            $result['introduced_phase'] = ($Matches[1].Trim() -replace '\s+#.*$', '' -replace '^[''"]|[''"]$', '')
        }
        elseif ($line -match '^\s*catchable_phase\s*:\s*(.+)$') {
            $result['catchable_phase'] = ($Matches[1].Trim() -replace '\s+#.*$', '' -replace '^[''"]|[''"]$', '')
        }
        elseif ($line -match '^\s*caught_stage\s*:\s*(.+)$') {
            $result['caught_stage'] = ($Matches[1].Trim() -replace '\s+#.*$', '' -replace '^[''"]|[''"]$', '')
        }
        elseif ($line -match '^\s*escape_distance\s*:\s*(.+)$') {
            $val = ($Matches[1].Trim() -replace '\s+#.*$', '')
            $intVal = 0
            if ([int]::TryParse($val, [ref]$intVal)) {
                $result['escape_distance'] = [int]$intVal
            }
        }
        elseif ($line -match '^\s*severity\s*:\s*(.+)$') {
            $result['severity'] = ($Matches[1].Trim() -replace '\s+#.*$', '' -replace '^[''"]|[''"]$', '')
        }
        elseif ($line -match '^\s*systemic_fix_type\s*:\s*(.+)$') {
            $result['systemic_fix_type'] = ($Matches[1].Trim() -replace '\s+#.*$', '' -replace '^[''"]|[''"]$', '')
        }
        elseif ($line -match '^\s*category\s*:\s*(.+)$') {
            $result['category'] = ($Matches[1].Trim() -replace '\s+#.*$', '' -replace '^[''"]|[''"]$', '')
        }
        elseif ($line -match '^\s*apparatus_meta\s*:\s*(.+)$') {
            $val = ($Matches[1].Trim() -replace '\s+#.*$', '' -replace '^[''"]|[''"]$', '').ToLowerInvariant()
            $result['apparatus_meta'] = ($val -eq 'true')
        }
        elseif ($line -match '^\s*seed\s*:\s*(.+)$') {
            $val = ($Matches[1].Trim() -replace '\s+#.*$', '' -replace '^[''"]|[''"]$', '').ToLowerInvariant()
            $result['seed'] = ($val -eq 'true')
        }
    }

    return $result
}

# Expose ConvertFrom-PhaseContainmentYaml as a module-level function (not script-scoped only)
# so tests can call it directly. The internal implementation lives in
# script:ConvertFrom-PhaseContainmentYamlInternal to prevent the script:-qualifier
# from resolving back to this wrapper in dot-source contexts (infinite recursion).
function ConvertFrom-PhaseContainmentYaml {
    param(
        [Parameter(Mandatory)][string]$Yaml
    )
    return script:ConvertFrom-PhaseContainmentYamlInternal -Yaml $Yaml
}

#endregion

#region Test-PhaseContainmentEntry

function Test-PhaseContainmentEntry {
    <#
    .SYNOPSIS
        Validates a parsed phase-containment hashtable against the schema rules.
    .DESCRIPTION
        Returns a PSCustomObject with:
          IsValid  [bool]     — $true only when ALL validation rules pass
          Errors   [string[]] — list of error messages (empty when IsValid=$true)
    .PARAMETER Entry
        The hashtable to validate (typically the output of ConvertFrom-PhaseContainmentYaml).
    #>
    param(
        [Parameter(Mandatory)][hashtable]$Entry
    )

    $errors = [System.Collections.Generic.List[string]]::new()

    # Rule 1: All required fields must be present and non-null
    $requiredFields = @(
        'finding_key', 'introduced_phase', 'catchable_phase', 'caught_stage',
        'escape_distance', 'severity', 'systemic_fix_type', 'category'
    )
    foreach ($field in $requiredFields) {
        if (-not $Entry.ContainsKey($field) -or $null -eq $Entry[$field]) {
            $errors.Add("Required field missing or null: $field")
        }
    }

    # Short-circuit if any required field is missing — subsequent checks would throw
    if ($errors.Count -gt 0) {
        return [PSCustomObject]@{ IsValid = $false; Errors = $errors.ToArray() }
    }

    # Rule 2: introduced_phase enum
    if ($Entry['introduced_phase'] -notin $script:ValidIntroducedPhases) {
        $val = $Entry['introduced_phase']
        $errors.Add("introduced_phase '$val' is not a valid value. Expected one of: $($script:ValidIntroducedPhases -join ', ')")
    }

    # Rule 3: catchable_phase enum
    if ($Entry['catchable_phase'] -notin $script:ValidCatchablePhases) {
        $val = $Entry['catchable_phase']
        $errors.Add("catchable_phase '$val' is not a valid value. Expected one of: $($script:ValidCatchablePhases -join ', ')")
    }

    # Rule 4: caught_stage enum
    if ($Entry['caught_stage'] -notin $script:ValidCaughtStages) {
        $val = $Entry['caught_stage']
        $errors.Add("caught_stage '$val' is not a valid value. Expected one of: $($script:ValidCaughtStages -join ', ')")
    }

    # Rule 5: severity enum
    if ($Entry['severity'] -notin $script:ValidSeverities) {
        $val = $Entry['severity']
        $errors.Add("severity '$val' is not a valid value. Expected one of: $($script:ValidSeverities -join ', ')")
    }

    # Rule 6: systemic_fix_type enum
    if ($Entry['systemic_fix_type'] -notin $script:ValidSystemicFixTypes) {
        $val = $Entry['systemic_fix_type']
        $errors.Add("systemic_fix_type '$val' is not a valid value. Expected one of: $($script:ValidSystemicFixTypes -join ', ')")
    }

    # Rule 7: category enum
    if ($Entry['category'] -notin $script:ValidCategories) {
        $val = $Entry['category']
        $errors.Add("category '$val' is not a valid value. Expected one of: $($script:ValidCategories -join ', ')")
    }

    # Rule 8: escape_distance is a non-negative integer
    $escapeDistance = $Entry['escape_distance']
    if ($escapeDistance -isnot [int] -or $escapeDistance -lt 0) {
        $errors.Add("escape_distance must be a non-negative integer. Got: $escapeDistance")
    }

    # Rules 9-11 require valid ordinals/projections — skip if enum errors already found
    # (the ordinal lookup would throw on invalid values). Rule 12 (finding_key format,
    # below) does not depend on ordinals/projections and always runs regardless of
    # enum errors found here.
    $enumErrorsFound = $errors.Count -gt 0
    if (-not $enumErrorsFound) {
        $introducedOrdinal  = $script:PhaseOrdinals[$Entry['introduced_phase']]
        $catchableOrdinal   = $script:PhaseOrdinals[$Entry['catchable_phase']]
        $caughtProjection   = $script:StageProjections[$Entry['caught_stage']]

        # Rule 9: introduced_phase ordinal <= catchable_phase ordinal (reject, NOT clamp)
        if ($introducedOrdinal -gt $catchableOrdinal) {
            $errors.Add(
                "Ordering constraint violated: introduced_phase '$($Entry['introduced_phase'])' " +
                "(ordinal $introducedOrdinal) must be <= catchable_phase '$($Entry['catchable_phase'])' " +
                "(ordinal $catchableOrdinal). Out-of-range ordinal relationships are rejected, not clamped."
            )
        }

        # Rule 10: catchable_phase ordinal <= stage projection of caught_stage (reject, NOT clamp)
        if ($catchableOrdinal -gt $caughtProjection) {
            $errors.Add(
                "Ordering constraint violated: catchable_phase '$($Entry['catchable_phase'])' " +
                "(ordinal $catchableOrdinal) must be <= projection of caught_stage '$($Entry['caught_stage'])' " +
                "(projection $caughtProjection). Out-of-range ordinal relationships are rejected, not clamped."
            )
        }

        # Rule 11: Recompute escape_distance and reject if stored value differs
        if ($escapeDistance -is [int] -and $escapeDistance -ge 0) {
            $recomputed = $caughtProjection - $catchableOrdinal
            if ($escapeDistance -ne $recomputed) {
                $errors.Add(
                    "escape_distance mismatch: stored=$escapeDistance recomputed=$recomputed. " +
                    "escape_distance must equal projection(caught_stage) - ordinal(catchable_phase)."
                )
            }
        }
    }

    # Rule 12: finding_key must match the surface-prefixed format (case-sensitive —
    # issue #772 D4). Uses -cmatch to mirror the schema's ECMA-262 case-sensitive
    # "pattern" semantics; PowerShell's default -match is case-insensitive and would
    # diverge (e.g. silently accepting "Code-Review:x").
    if (-not ($Entry['finding_key'] -cmatch $script:FindingKeyPattern)) {
        $val = $Entry['finding_key']
        $errors.Add(
            "finding_key '$val' does not match expected format. Expected pattern: $script:FindingKeyPattern"
        )
    }

    $isValid = $errors.Count -eq 0
    return [PSCustomObject]@{
        IsValid = $isValid
        Errors  = $errors.ToArray()
    }
}

#endregion

#region Get-PhaseContainmentFindingKey

function Get-PhaseContainmentFindingKey {
    <#
    .SYNOPSIS
        Derives the uniform cross-surface finding_key for a phase-containment entry.
    .DESCRIPTION
        Output format: {surface}:{stable_finding_key}

        Surface-specific derivation rules:
          code-review:
            - If stable_finding_key is 'gh-{comment_id}' form, returns as-is prefixed with surface.
            - Otherwise caller provides a pre-derived stable_finding_key.
          design-challenge / plan-stress-test:
            - stable_finding_key is '{issue}:{marker}:{finding_id}' (e.g. '762:design-phase-complete-762:F1')
            - Returns '{surface}:{stable_finding_key}'

        Fallback: if stable_finding_key starts with 'warn:', returns 'warn:{finding_id}' prefixed
        with surface — signals instability.
    .PARAMETER Surface
        One of: code-review, design-challenge, plan-stress-test
    .PARAMETER StableFindingKey
        The surface-specific stable key segment (without the surface prefix).
    .OUTPUTS
        [string] The full finding_key: '{surface}:{stable_finding_key}'
    #>
    param(
        [Parameter(Mandatory)][string]$Surface,
        [Parameter(Mandatory)][string]$StableFindingKey
    )

    return "${Surface}:${StableFindingKey}"
}

#endregion

#region Get-PhaseContainmentEnumDriftStatus

function Get-PhaseContainmentEnumDriftStatus {
    <#
    .SYNOPSIS
        Verifies that the schema enums in phase-containment.schema.json match routing-config.json.
    .DESCRIPTION
        Reads routing-config.json from skills/routing-tables/assets/routing-config.json.
        Reads phase-containment.schema.json from skills/calibration-pipeline/schemas/phase-containment.schema.json.
        Checks that severity, systemic_fix_type, and category arrays match exactly (order-independent).

        Returns a PSCustomObject with:
          HasDrift     [bool]     — $true if any enum differs between the two files
          DriftDetails [string[]] — description of each divergence (empty when HasDrift=$false)
    .PARAMETER RepoRoot
        The root directory of the repository.
    #>
    param(
        [Parameter(Mandatory)][string]$RepoRoot
    )

    $driftDetails = [System.Collections.Generic.List[string]]::new()

    $routingConfigPath = Join-Path $RepoRoot 'skills/routing-tables/assets/routing-config.json'
    $schemaPath        = Join-Path $RepoRoot 'skills/calibration-pipeline/schemas/phase-containment.schema.json'

    if (-not (Test-Path -LiteralPath $routingConfigPath)) {
        $driftDetails.Add("routing-config.json not found at: $routingConfigPath")
        return [PSCustomObject]@{ HasDrift = $true; DriftDetails = $driftDetails.ToArray() }
    }

    if (-not (Test-Path -LiteralPath $schemaPath)) {
        $driftDetails.Add("phase-containment.schema.json not found at: $schemaPath")
        return [PSCustomObject]@{ HasDrift = $true; DriftDetails = $driftDetails.ToArray() }
    }

    $routingConfig = Get-Content -LiteralPath $routingConfigPath -Raw | ConvertFrom-Json
    $schema        = Get-Content -LiteralPath $schemaPath -Raw | ConvertFrom-Json

    # Extract enums from routing-config.json
    $rcSeverity        = @($routingConfig.enums.severity)
    $rcSystemicFix     = @($routingConfig.enums.systemic_fix_type)
    $rcCategory        = @($routingConfig.enums.category)

    # Extract enums from schema (properties.severity.enum, etc.)
    $schemaSeverity    = @($schema.properties.severity.enum)
    $schemaSystemicFix = @($schema.properties.systemic_fix_type.enum)
    $schemaCategory    = @($schema.properties.category.enum)

    # Compare order-independent: sort both and compare
    $compareFields = @(
        @{ Name = 'severity';         Routing = $rcSeverity;    Schema = $schemaSeverity    },
        @{ Name = 'systemic_fix_type'; Routing = $rcSystemicFix; Schema = $schemaSystemicFix },
        @{ Name = 'category';         Routing = $rcCategory;    Schema = $schemaCategory    }
    )

    foreach ($field in $compareFields) {
        $sortedRouting = ($field.Routing | Sort-Object)
        $sortedSchema  = ($field.Schema  | Sort-Object)

        $routingStr = $sortedRouting -join ','
        $schemaStr  = $sortedSchema  -join ','

        if ($routingStr -ne $schemaStr) {
            $driftDetails.Add(
                "Enum drift detected for '$($field.Name)': " +
                "routing-config.json=[$($field.Routing -join ', ')] " +
                "vs schema=[$($field.Schema -join ', ')]"
            )
        }
    }

    $hasDrift = $driftDetails.Count -gt 0
    return [PSCustomObject]@{
        HasDrift     = $hasDrift
        DriftDetails = $driftDetails.ToArray()
    }
}

#endregion
