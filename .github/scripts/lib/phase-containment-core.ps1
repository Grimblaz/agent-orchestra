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

# Issue #951 D1: 'brief-review' sits at projection 2, the same projection as
# 'plan-stress-test', because a brief's review catches at plan time exactly as
# a plan stress-test does. The two stages differ in ADJUDICATION STANDARD, not
# in pipeline location — a judge ruled on a plan-stress-test finding, whereas a
# brief-review finding was upheld by a prosecution panel plus a convergence
# filter and no judge at all. Recorded knowingly (D1): this encodes adjudication
# grade into a field that names pipeline location. The code-review surface
# already conflates three counting variants under one caught_stage, so the
# conflation is pre-existing rather than introduced here; splitting the two
# dimensions is routed to the parser/schema follow-up (#951 D7).
$script:StageProjections = @{
    'design-challenge'     = 1
    'plan-stress-test'     = 2
    'brief-review'         = 2
    'code-review'          = 3
    'post-review-observer' = 4
}

#endregion

#region Valid enum sets

$script:ValidIntroducedPhases  = @('experience', 'design', 'plan', 'implementation')
$script:ValidCatchablePhases   = @('experience', 'design', 'plan', 'implementation')
$script:ValidCaughtStages      = @('design-challenge', 'plan-stress-test', 'brief-review', 'code-review', 'post-review-observer')
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
#
# Issue #951: the alternation below MUST name the same set as
# $script:ValidCaughtStages. Byte-equality against the schema does NOT imply
# that — the two guards that existed before #951 asserted
# projections/valid-stages/schema-enum set-equality on one side and
# pattern byte-equality on the other, with nothing joining them, so updating
# three of the five sites left both guards green while every block for the
# missing stage silently failed Rule 12 and was then discarded by the
# emission check's finding_key prefix gate. The four-way set-equality guard
# (Get-PhaseContainmentStageSetDriftStatus, exercised by the core test suite)
# closes that join; do not weaken it back to a three-way.
$script:FindingKeyPattern = '^(code-review|design-challenge|plan-stress-test|brief-review|post-review-observer):.+'

#endregion

#region Get-BlockScalarSpans / Test-IndexInBlockScalarSpan (private)

function script:Get-BlockScalarSpans {
    <#
    .SYNOPSIS
        Finds every YAML block-scalar (`key: |` / `key: >`) CONTENT span in a
        text, so callers can exclude structural-looking substrings that fall
        inside block-scalar string content from being treated as real YAML
        structure (CM1/CM4 fix, judge-sustained PR #833 review; relocated
        here from phase-containment-emission-check-core.ps1 by the #863 M6
        fix so Get-PhaseContainmentBlock below can reuse it without a
        circular dot-source — this file has no dependency on the emission
        check core, and the emission check core already dot-sources this
        file, so callers there are unaffected by the move).
    .DESCRIPTION
        Hand-rolled scan only — no ConvertFrom-Yaml / powershell-yaml
        (file-level SECURITY invariant at the top of this file).

        A block-scalar key line is any line matching `key: |` or `key: >`
        (optionally with a chomping indicator +/- and/or an explicit
        indentation-indicator digit), anchored at end-of-line. Every
        subsequent line that is either blank or indented strictly MORE than
        the key line is part of that block scalar's content; the first
        non-blank line indented at or less than the key line's own
        indentation ends the span (or end-of-text, if none).
    .PARAMETER Text
        The text to scan (a whole body or an already-isolated region).
    .OUTPUTS
        Array of [PSCustomObject]@{ Start; End } character-offset spans
        (End exclusive), covering only the block-scalar's CONTENT lines (not
        the `key: |`/`key: >` line itself). Empty array when none found.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text
    )
    $spans = [System.Collections.Generic.List[PSCustomObject]]::new()
    if ([string]::IsNullOrEmpty($Text)) {
        return , $spans.ToArray()
    }

    $keyLinePattern = '(?m)^([ \t]*)\S[^\r\n]*:[ \t]*[|>][+-]?\d?[ \t]*\r?$'
    $keyLineMatches = [regex]::Matches($Text, $keyLinePattern)
    foreach ($keyMatch in $keyLineMatches) {
        $keyIndent = $keyMatch.Groups[1].Value.Length
        $keyLineEnd = $Text.IndexOf("`n", $keyMatch.Index, [System.StringComparison]::Ordinal)
        if ($keyLineEnd -lt 0) {
            # The key line is the last line in the text; no content follows.
            continue
        }
        $contentStart = $keyLineEnd + 1
        $pos = $contentStart
        $contentEnd = $Text.Length
        while ($pos -le $Text.Length) {
            $nextNewline = $Text.IndexOf("`n", $pos, [System.StringComparison]::Ordinal)
            $lineText = if ($nextNewline -ge 0) { $Text.Substring($pos, $nextNewline - $pos) } else { $Text.Substring($pos) }
            if ($lineText.Trim().Length -eq 0) {
                # Blank line: still part of the block scalar.
                if ($nextNewline -lt 0) { $contentEnd = $Text.Length; break }
                $pos = $nextNewline + 1
                continue
            }
            $lineIndent = [regex]::Match($lineText, '^[ \t]*').Value.Length
            if ($lineIndent -le $keyIndent) {
                $contentEnd = $pos
                break
            }
            if ($nextNewline -lt 0) { $contentEnd = $Text.Length; break }
            $pos = $nextNewline + 1
        }
        if ($contentEnd -gt $contentStart) {
            $spans.Add([PSCustomObject]@{ Start = $contentStart; End = $contentEnd })
        }
    }
    return , $spans.ToArray()
}

function script:Test-IndexInBlockScalarSpan {
    <#
    .SYNOPSIS
        Reports whether a character offset falls inside any of the supplied
        block-scalar spans (CM1/CM4 fix, judge-sustained PR #833 review;
        relocated here alongside Get-BlockScalarSpans by the #863 M6 fix).
    .PARAMETER Index
        The character offset to test.
    .PARAMETER Spans
        The Get-BlockScalarSpans result to test against.
    .OUTPUTS
        [bool]
    #>
    param(
        [Parameter(Mandatory)][int]$Index,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Spans
    )
    foreach ($span in $Spans) {
        if ($Index -ge $span.Start -and $Index -lt $span.End) {
            return $true
        }
    }
    return $false
}

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

        Block-scalar gating (#863 M6, judge-sustained code-review): an
        open-tag-shaped substring whose start index falls inside another
        marker's YAML block-scalar (`key: |` / `key: >`) CONTENT span (per
        Get-BlockScalarSpans/Test-IndexInBlockScalarSpan) is string data,
        not a real structural marker — e.g. a `requirement-contract: |` or
        `disposition_rationale: |` scalar that happens to quote or discuss
        a `<!-- phase-containment-{ID} -->` literal. This mirrors the same
        gating Get-RealJudgeRulingsHeadMatches already applies to
        judge-rulings heads (the #768 forgery class this closes for phase-
        containment blocks too). Such a candidate is skipped silently (not
        even a malformed-block warning — it was never a real marker
        attempt) and the scan resumes immediately past it.
    #>
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][string]$Id,
        [ref]$SkippedCount
    )

    $openTag  = "<!-- phase-containment-$Id -->"
    $closeTag = "<!-- /phase-containment-$Id -->"

    $blockScalarSpans = Get-BlockScalarSpans -Text $Text
    $allBlocks  = [System.Collections.Generic.List[string]]::new()
    $searchFrom = 0

    while ($true) {
        $startIdx = $Text.IndexOf($openTag, $searchFrom, [System.StringComparison]::Ordinal)
        if ($startIdx -lt 0) { break }

        if (Test-IndexInBlockScalarSpan -Index $startIdx -Spans $blockScalarSpans) {
            $searchFrom = $startIdx + $openTag.Length
            continue
        }

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
        appended_at       = $null
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
        elseif ($line -match '^\s*appended_at\s*:\s*(.+)$') {
            # Issue #863 s4: block-level re-annotation timestamp. Captured
            # raw here (no format validation at parse time — a malformed
            # value must be distinguishable from "absent" so the dedup
            # layer can route it into InvalidEntryCount instead of quietly
            # treating it as absent-and-fallback). Strict Z-format
            # validation happens at runtime in
            # phase-containment-rolling-history-core.ps1's dedup path.
            $result['appended_at'] = ($Matches[1].Trim() -replace '\s+#.*$', '' -replace '^[''"]|[''"]$', '')
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
        One of: code-review, design-challenge, plan-stress-test,
        brief-review, post-review-observer. Must stay in step with
        $script:ValidCaughtStages -- the prefix this builds is what the
        emission check attributes a block to, and a prefix naming a stage
        the enum does not carry produces a block no surface will count.
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

#region Get-PhaseContainmentStageSetDriftStatus (issue #951)

function Get-PhaseContainmentStageSetDriftStatus {
    <#
    .SYNOPSIS
        Reports whether all FOUR caught_stage-naming sites name the same set:
        $script:StageProjections' keys, $script:ValidCaughtStages, the schema's
        caught_stage enum, and the finding_key pattern's surface alternation.
    .DESCRIPTION
        WHY FOUR AND NOT THREE. Before issue #951 two guards existed and
        neither joined these last two sites: a three-way set-equality over
        projections/valid-stages/schema-enum, and a separate byte-equality
        between $script:FindingKeyPattern and the schema's finding_key pattern.
        Byte-equality between two copies of the alternation says the copies
        agree with EACH OTHER; it says nothing about whether they agree with
        caught_stage. So updating three of the five sites for a new stage left
        both guards green while every block for that stage silently failed
        Rule 12 and was discarded at the emission check's finding_key prefix
        gate — rows present, parseable, schema-valid, and invisible.
    .PARAMETER Projections
    .PARAMETER ValidStages
    .PARAMETER SchemaEnum
    .PARAMETER FindingKeyPattern
        Supplied explicitly rather than read from the live constants, so the
        suite can feed deliberately-omitted sets and prove this function
        actually fails on them. A guard only checked against a passing input
        is a guard nobody has seen fail.
    .OUTPUTS
        [PSCustomObject] HasDrift [bool], DriftDetails [string[]].
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Projections,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$ValidStages,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$SchemaEnum,
        [Parameter(Mandatory)][string]$FindingKeyPattern
    )

    $driftDetails = [System.Collections.Generic.List[string]]::new()

    $alternationMatch = [regex]::Match($FindingKeyPattern, '^\^\(([^)]*)\)')
    if (-not $alternationMatch.Success) {
        $driftDetails.Add("finding_key pattern '$FindingKeyPattern' does not start with a '^(a|b|c)' surface alternation, so its stage set cannot be read.")
        return [PSCustomObject]@{ HasDrift = $true; DriftDetails = $driftDetails.ToArray() }
    }
    $alternation = @($alternationMatch.Groups[1].Value -split '\|' | Where-Object { $_ -ne '' })

    $sets = @(
        @{ Name = 'StageProjections.Keys';    Values = $Projections  },
        @{ Name = 'ValidCaughtStages';        Values = $ValidStages  },
        @{ Name = 'schema caught_stage enum'; Values = $SchemaEnum   },
        @{ Name = 'finding_key alternation';  Values = $alternation  }
    )

    $reference = ($sets[0].Values | Sort-Object) -join ','
    foreach ($s in $sets[1..3]) {
        $candidate = ($s.Values | Sort-Object) -join ','
        if ($candidate -cne $reference) {
            $driftDetails.Add(
                "caught_stage set drift: $($sets[0].Name)=[$reference] vs $($s.Name)=[$candidate]. " +
                'All four sites must name the same set — a stage present in some but not all is either rejected by validation or silently discarded by the finding_key prefix gate.'
            )
        }
    }

    return [PSCustomObject]@{
        HasDrift     = ($driftDetails.Count -gt 0)
        DriftDetails = $driftDetails.ToArray()
    }
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

#region Get-PhaseContainmentReasonContractDriftStatus (issue #969)

function Get-PhaseContainmentReasonContractDriftStatus {
    <#
    .SYNOPSIS
        Reports whether the brief-review reason vocabulary's PROSE still agrees
        with the CODE it describes.
    .DESCRIPTION
        WHY THIS EXISTS. Issue #969 opened on two sentences that were true when
        written and were not re-checked when the code beneath them changed —
        one of them invalidated TWICE inside a single pull request's own fix
        loop. Correcting the sentences leaves that class fully intact; the
        class only closes when the drift fails a check.

        WHAT IT COVERS, AND WHAT IT DOES NOT. Adding a reason to this
        vocabulary touches six sites. This function reads five of them:

          1. the parser's documented `.OUTPUTS` enum, against the reason
             literals the parser body actually returns;
          2. the reason ladder's maintenance comment — both its count and its
             ordered name list — against the ladder's own branches;
          3. the reason -> flag dispatch switch's explicit arms, against the
             parser's returned set;
          4. the aggregator's documented `.OUTPUTS` enum AND its cross-body
             priority sentence, against the reasons the ladder emits;
          5. the entry point's per-reason maintainer-message block, against the
             brief-only reasons the ladder emits.

        The sixth site — the parser body itself — is the source of truth that
        legs 1 and 3 read, so it is not separately checkable. An earlier
        revision of this synopsis claimed the set was three; it was not, and
        the two then-uncovered sites (4 and 5) were exactly where a ninth
        reason could ship stale. Reported as review finding M5 on PR #988.

        BOTH SIDES ARE READ FROM SOURCE. Nothing here compares source against a
        list this function authored. A check holding one side constant cannot
        fail for the reason it exists and goes stale exactly as the docstring
        did.

        EVERY RETURN IS ENUMERATED, AND A RETURN THIS PARSER CANNOT READ IS
        DRIFT. Most of the parser's returns leave through a shared
        `& $none <literal>` closure rather than a direct `Reason = <literal>`
        assignment — and ALL THREE values #969 found undocumented were
        closure-shaped. Both quote styles are accepted. A return whose reason
        argument is NOT a literal (a variable, an expression), or a closure
        reached through an alias, is reported as drift rather than skipped:
        review finding M2 on PR #988 demonstrated that skipping it made a new
        reason simultaneously invisible to leg 1 and leg 3, so it would ship
        undocumented AND absorbed by the dispatch switch's `default` arm.

        UNREADABLE IS DRIFT, NEVER SILENCE. Every parse below reports drift
        when its input cannot be read. A rewrap, a bullet-list conversion or a
        rename can make a prose side unparseable, and a check that treats
        "could not read it" as "nothing to check" goes green permanently —
        which is this issue's own defect one level up.

        SET EQUALITY, NOT CONTAINMENT. The defect direction is
        documented -/-> returned (a returned value missing from the docs). The
        opposite direction — a documented value the code can no longer return —
        is also drift, and is reported separately so the message names which
        way the two sets parted.

        KNOWN RESIDUAL (finding M1 on PR #988, ruled low). Leg 2 classifies a
        ladder branch as brief-only by looking for a variable named for the
        brief surface in its guard condition. A lawful brief-only branch whose
        flag is named some other way is counted as SHARED, silently. The
        convention is stated as a precondition at the ladder itself, where the
        author edits; it is not enforced from the flag's own semantics.
    .PARAMETER Source
        Full text of `.github/scripts/lib/phase-containment-emission-check-core.ps1`.
        Supplied as text rather than read from a fixed path so the suite can
        feed deliberately drifted copies and prove this function fails on them.
        A guard only ever checked against a passing input is a guard nobody has
        seen fail.
    .PARAMETER EntryPointSource
        Full text of `.github/scripts/phase-containment-emission-check.ps1`, for
        leg 5. Empty is drift, not a skipped leg.
    .OUTPUTS
        [PSCustomObject] HasDrift [bool], DriftDetails [string[]],
        DocumentedReasons [string[]], ReturnedReasons [string[]],
        SwitchArms [string[]], LadderEmittedReasons [string[]] (source order),
        LadderBriefOnlyReasons [string[]] (source order),
        LadderBriefOnlyCount [int] (-1 when unreadable),
        LadderStatedCount [int] (-1 when unreadable),
        LadderStatedReasons [string[]], AggregatorDocumentedReasons [string[]],
        AggregatorPriorityOrder [string[]], EntryPointReasons [string[]].
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Source,
        [Parameter(Mandatory)][AllowEmptyString()][string]$EntryPointSource
    )

    # Every regex literal below is a SINGLE-quoted PowerShell string, so no
    # PowerShell interpolation runs over it and a `\$` reaches the engine as an
    # escaped dollar rather than an end-of-line anchor. Embedded single quotes
    # are doubled.
    $driftDetails  = [System.Collections.Generic.List[string]]::new()
    $documented    = @()
    $returned      = @()
    $switchArms    = @()
    $ladderEmitted = @()
    $briefReasons  = @()
    $statedReasons = @()
    $aggDocumented = @()
    $aggPriority   = @()
    $entryReasons  = @()
    $ladderCount   = -1
    $statedCount   = -1

    # A reason token, in either quote style. Deliberately wider than the
    # lowercase-kebab the current eight happen to use: a check that only sees
    # the spelling convention already in the file cannot fail for a value that
    # breaks it, which is the shape it most needs to catch.
    $reasonToken = '[''"]([A-Za-z][A-Za-z0-9_-]*)[''"]'

    $emit = {
        param([string]$Detail)
        $driftDetails.Add($Detail)
    }

    # Prose anchors match against a NORMALIZED copy: comment markers stripped,
    # every whitespace run collapsed to one space. Without it every anchor is a
    # hostage to line wrapping — the aggregator's own priority sentence already
    # wraps mid-phrase, and a check that reports "unreadable" because someone
    # reflowed a comment trains its reader to ignore it. Reflow-tolerance is
    # not laxness: an anchor that survives rewrapping still fails on a changed
    # claim, which is the drift being hunted.
    $prose = ($Source -replace '(?m)^[ \t]*#', ' ') -replace '\s+', ' '

    # -- Leg 1: the parser's documented enum vs. the reasons it returns -------

    $fnAnchor = 'function script:Get-BriefReviewSustainedCountInternal'
    $fnStart = $Source.IndexOf($fnAnchor, [System.StringComparison]::Ordinal)
    if ($fnStart -lt 0) {
        & $emit "reason-contract: the parser '$fnAnchor' could not be located in the supplied source, so neither its documented enum nor its returned set could be read."
    }
    else {
        # The function's own closing brace is the first `}` in column 0 after
        # its declaration; every nested brace in this file is indented.
        $tail = $Source.Substring($fnStart)
        $fnEnd = [regex]::Match($tail, '(?m)^\}')
        $fnSpan = if ($fnEnd.Success) { $tail.Substring(0, $fnEnd.Index + $fnEnd.Length) } else { $tail }
        if (-not $fnEnd.Success) {
            & $emit 'reason-contract: the parser''s closing brace could not be located, so the enumerated span is unbounded and its result is not trustworthy.'
        }

        $docMatch = [regex]::Match($fnSpan, '(?s)\.OUTPUTS\b.*?\bReason\s*\(([^)]*)\)')
        if (-not $docMatch.Success) {
            & $emit 'reason-contract: the documented Reason enum could not be read from the parser''s .OUTPUTS block. Unreadable prose is drift, not a clean check — the contract this compares against no longer exists in a form any reader can parse.'
        }
        else {
            $documented = @(
                @([regex]::Matches($docMatch.Groups[1].Value, $reasonToken) |
                        ForEach-Object { $_.Groups[1].Value }) | Sort-Object -Unique
            )
        }

        # Scan the CODE, not the prose: the block comment and the line comments
        # inside this function legitimately quote example reason literals, and
        # counting those would make the enumeration report values the function
        # never returns.
        $fnCode = $fnSpan -replace '(?s)<#.*?#>', '' -replace '(?m)^\s*#.*$', ''

        $returnedSet = [System.Collections.Generic.HashSet[string]]::new()

        # Closure-shaped returns, via the call operator. The captured closure
        # NAME is checked too: aliasing the closure (`$n = $none; & $n '...'`)
        # would otherwise hide every return made through the alias.
        foreach ($m in [regex]::Matches($fnCode, '&\s*\$(\w+)\s+([^\s)]+)')) {
            $closureName = $m.Groups[1].Value
            $arg = $m.Groups[2].Value
            if ($closureName -ne 'none') {
                & $emit "reason-contract: a reason is returned through a closure named '`$$closureName' rather than '`$none'. This enumerator follows '`$none' only, so returns made through an alias are invisible to it — alias the closure and the values it carries stop being checked."
                continue
            }
            $lit = [regex]::Match($arg, "^$reasonToken")
            if ($lit.Success) { [void]$returnedSet.Add($lit.Groups[1].Value) }
            else {
                & $emit "reason-contract: a reason is returned through the closure as a non-literal argument ('$arg'), which this enumerator cannot resolve. A value it cannot read is invisible to BOTH the documented-enum check and the dispatch-arm check, so it would ship undocumented and absorbed by the switch's default arm."
            }
        }

        # Direct field assignments. `Reason = $reason` inside the closure body
        # is the closure's own parameter, not a returned value — it is the one
        # documented non-literal, and it is exempt by exact match so a DIFFERENT
        # variable still reports.
        foreach ($m in [regex]::Matches($fnCode, '(?m)Reason\s*=\s*(\S+)')) {
            $val = $m.Groups[1].Value
            if ($val -ceq '$reason') { continue }
            $lit = [regex]::Match($val, "^$reasonToken")
            if ($lit.Success) { [void]$returnedSet.Add($lit.Groups[1].Value) }
            else {
                & $emit "reason-contract: a Reason field is assigned the non-literal value '$val', which this enumerator cannot resolve. See the closure case above for why an unreadable return is worse than an undocumented one."
            }
        }

        $returned = @(@($returnedSet) | Sort-Object)

        if ($returned.Count -eq 0) {
            & $emit 'reason-contract: no returned Reason value could be enumerated from the parser body. Either both return shapes have changed or the span is wrong; a zero-value enumeration must never read as agreement.'
        }

        if ($docMatch.Success -and $returned.Count -gt 0) {
            $undocumented = @($returned | Where-Object { $documented -notcontains $_ })
            if ($undocumented.Count -gt 0) {
                & $emit ("reason-contract: the parser returns Reason value(s) its .OUTPUTS block does not document: $($undocumented -join ', '). " +
                    "Documented=[$($documented -join ', ')] Returned=[$($returned -join ', ')].")
            }
            $unreturnable = @($documented | Where-Object { $returned -notcontains $_ })
            if ($unreturnable.Count -gt 0) {
                & $emit ("reason-contract: the parser's .OUTPUTS block documents Reason value(s) the function can no longer return: $($unreturnable -join ', '). " +
                    "Documented=[$($documented -join ', ')] Returned=[$($returned -join ', ')].")
            }
        }
    }

    # -- Leg 2: the ladder's maintenance comment vs. the ladder itself --------

    $ladderAnchor = '$reason = if (-not $anyCouldNotVerify)'
    $ladderStart = $Source.IndexOf($ladderAnchor, [System.StringComparison]::Ordinal)
    $ladderEnd = if ($ladderStart -ge 0) { $Source.IndexOf('return [PSCustomObject]@{', $ladderStart, [System.StringComparison]::Ordinal) } else { -1 }
    $ladderBranches = [System.Collections.Generic.List[object]]::new()
    if ($ladderStart -lt 0 -or $ladderEnd -lt 0) {
        & $emit 'reason-contract: the reason ladder could not be located, so neither the count nor the ordered list its maintenance comment states could be checked against anything.'
    }
    else {
        # Walked line by line rather than joined from two independent regex
        # match sets: pairing a branch with its emitted reason by match index
        # desyncs the moment one branch carries a comment the other does not.
        $current = $null
        $flush = {
            if ($null -ne $current) { $ladderBranches.Add($current) }
        }
        foreach ($line in ($Source.Substring($ladderStart, $ladderEnd - $ladderStart) -split "`r?`n")) {
            if ($line -match '^\s*(?:\$reason\s*=\s*if|elseif)\s*\((?<cond>.*)\)\s*\{\s*$') {
                & $flush
                $current = [PSCustomObject]@{ Condition = $Matches['cond']; Reason = $null }
            }
            elseif ($line -match '^\s*else\s*\{\s*$') {
                & $flush
                $current = [PSCustomObject]@{ Condition = ''; Reason = $null }
            }
            elseif ($null -ne $current -and $null -eq $current.Reason -and $line -match "^\s*$reasonToken\s*$") {
                $current.Reason = $Matches[1]
            }
        }
        & $flush

        $named = @($ladderBranches | Where-Object { $null -ne $_.Reason })
        $ladderEmitted = @($named | ForEach-Object { $_.Reason })
        if ($ladderEmitted.Count -eq 0) {
            & $emit 'reason-contract: no ladder branch emitted a readable reason literal. A zero-branch ladder is a parse failure, not a ladder with nothing in it.'
        }
        # A branch is brief-only when its guard names a brief-surface flag.
        # Every variable in the condition is read, so a compound guard is seen.
        # See the KNOWN RESIDUAL note in .DESCRIPTION for what this cannot see.
        $briefReasons = @(
            $named | Where-Object {
                @([regex]::Matches($_.Condition, '\$(\w+)') | ForEach-Object { $_.Groups[1].Value }) |
                    Where-Object { $_ -match 'brief' }
            } | ForEach-Object { $_.Reason }
        )
        $ladderCount = $briefReasons.Count
    }

    # The stated count is searched over the WHOLE file, not the region above
    # the ladder: a claim that drifted into another block is still a claim a
    # maintainer reads, and a windowed search would report its absence. The
    # trailing alternation catches near-miss phrasings ("reason branches") that
    # an exact-phrase search would let stand as a second, contradicting claim.
    $statedMatches = @([regex]::Matches($prose, '(?i)\b(one|two|three|four|five|six|seven|eight|nine|ten|\d+)\s+brief-review-only\s+reasons?(?:\s+branches)?\b'))
    if ($statedMatches.Count -ne 1) {
        & $emit "reason-contract: expected exactly one 'N brief-review-only reasons' claim in the file; found $($statedMatches.Count). Zero means the maintenance count is unreadable (the guidance a future author consults before inserting a branch is gone); more than one means two claims can drift apart."
    }
    else {
        $words = @{ one = 1; two = 2; three = 3; four = 4; five = 5; six = 6; seven = 7; eight = 8; nine = 9; ten = 10 }
        $raw = $statedMatches[0].Groups[1].Value.ToLowerInvariant()
        $parsedCount = 0
        if ($words.ContainsKey($raw)) { $statedCount = $words[$raw] }
        elseif ([int]::TryParse($raw, [ref]$parsedCount)) { $statedCount = $parsedCount }
        else {
            # Bounded parse, for the reason the parser above uses TryParse on
            # `filtered_count`: an unbounded `[int]` cast throws on overflow,
            # and a guard that throws has neither passed nor reported drift.
            & $emit "reason-contract: the maintenance count '$raw' is not a readable number (out of range for [int]). Unreadable is drift, not a skipped check."
        }
        if ($statedCount -ge 0 -and $ladderCount -ge 0 -and $statedCount -ne $ladderCount) {
            & $emit "reason-contract: the ladder's maintenance comment states $statedCount brief-review-only reason(s); the ladder itself has $ladderCount ($($briefReasons -join ', ')). This is the comment a future author consults BEFORE inserting a branch, so a wrong count is consulted at exactly the moment it misleads."
        }
    }

    # The comment does not only carry a quantity — it names the six reasons IN
    # ORDER and then spends fifteen lines justifying why each sits where it
    # does, which is the part a maintainer actually acts on. Pinning only the
    # integer left the names and the order free to drift (finding M7, PR #988),
    # and the ladder walk above already produced both in source order.
    $listMatch = [regex]::Match($prose, 'brief-review-only reasons at the TOP of the ladder, in this order:(.*?)\.')
    if (-not $listMatch.Success) {
        & $emit 'reason-contract: the maintenance comment''s ordered brief-only reason list could not be read. Unreadable is drift — the count alone does not tell a future author which branch goes where.'
    }
    else {
        $statedReasons = @(
            ($listMatch.Groups[1].Value -split ',') |
                ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }
        )
        if ($ladderCount -ge 0 -and (($statedReasons -join ' > ') -cne ($briefReasons -join ' > '))) {
            & $emit "reason-contract: the maintenance comment's ordered brief-only reason list does not match the ladder. Comment=[$($statedReasons -join ', ')] Ladder=[$($briefReasons -join ', ')]."
        }
    }

    # -- Leg 3: the dispatch switch has an explicit arm per returned reason ---
    #
    # The switch's `default` arm sets the head-corrupt flag, so a reason with
    # no arm is not dropped — it is REPORTED AS A CORRUPT HEAD, sending the
    # maintainer to diagnose corruption that is not there.
    #
    # Two values are exempt by construction, not by convenience:
    #   'ok'          — returned only with ParseStatus 'ok', and the switch is
    #                   entered only on 'could-not-verify', so it cannot arrive.
    #   'head-corrupt' — the absorbing default's intended destination.
    # Both exemptions are properties of the surrounding code AND are pinned by
    # standing behavioural tests, not by this check: review finding M3 on PR
    # #988 challenged them and defense showed each mutation turns a live test
    # red (`phase-containment-brief-review.Tests.ps1`, the ParseStatus-'ok' and
    # head-corrupt fixtures). A NEW reason is covered by neither exemption.
    $switchStart = $Source.IndexOf('switch ($briefTally.Reason)', [System.StringComparison]::Ordinal)
    if ($switchStart -lt 0) {
        & $emit 'reason-contract: the brief-review reason dispatch switch could not be located, so per-reason arm coverage could not be checked.'
    }
    else {
        $braceIdx = $Source.IndexOf('{', $switchStart)
        $depth = 0
        $close = -1
        for ($i = $braceIdx; $i -lt $Source.Length -and $braceIdx -ge 0; $i++) {
            if ($Source[$i] -eq '{') { $depth++ }
            elseif ($Source[$i] -eq '}') {
                $depth--
                if ($depth -eq 0) { $close = $i; break }
            }
        }
        if ($close -lt 0) {
            & $emit 'reason-contract: the dispatch switch''s closing brace could not be located, so its arms could not be enumerated.'
        }
        else {
            $switchSpan = $Source.Substring($braceIdx, $close - $braceIdx + 1)
            $switchArms = @(
                @([regex]::Matches($switchSpan, "(?m)^\s*$reasonToken\s*\{") |
                        ForEach-Object { $_.Groups[1].Value }) | Sort-Object -Unique
            )
            if ($returned.Count -gt 0) {
                $exempt = @('ok', 'head-corrupt')
                $needArm = @($returned | Where-Object { $exempt -notcontains $_ })
                $missingArm = @($needArm | Where-Object { $switchArms -notcontains $_ })
                if ($missingArm.Count -gt 0) {
                    & $emit ("reason-contract: reason value(s) with no explicit dispatch arm: $($missingArm -join ', '). " +
                        'The switch''s default arm sets the head-corrupt flag, so each of these is currently reported to the maintainer as a corrupt head.')
                }
                $deadArm = @($switchArms | Where-Object { $returned -notcontains $_ })
                if ($deadArm.Count -gt 0) {
                    & $emit "reason-contract: dispatch arm(s) for reason value(s) the parser can no longer return: $($deadArm -join ', ')."
                }
            }
        }
    }

    # -- Leg 4: the aggregator's documented enum AND priority vs. the ladder --
    #
    # This leg exists because a comment written in this PR claimed the
    # aggregator's enum was pinned when nothing pinned it (finding M6, PR
    # #988). Claiming a pin that does not exist is worse than claiming nothing:
    # it tells the next maintainer that hand-verification is unnecessary.
    if ($ladderEmitted.Count -gt 0) {
        $aggMatch = [regex]::Match($prose, 'Reason \[string\] — one of:(.*?)\.')
        if (-not $aggMatch.Success) {
            & $emit 'reason-contract: the aggregator''s documented Reason enum could not be read from its .OUTPUTS block. Unreadable is drift.'
        }
        else {
            $aggDocumented = @(
                @([regex]::Matches($aggMatch.Groups[1].Value, $reasonToken) |
                        ForEach-Object { $_.Groups[1].Value }) | Sort-Object -Unique
            )
            $ladderSet = @(@($ladderEmitted) | Sort-Object -Unique)
            $aggMissing = @($ladderSet | Where-Object { $aggDocumented -notcontains $_ })
            $aggExtra = @($aggDocumented | Where-Object { $ladderSet -notcontains $_ })
            if ($aggMissing.Count -gt 0) {
                & $emit "reason-contract: the aggregator's .OUTPUTS enum omits reason value(s) its own ladder emits: $($aggMissing -join ', ')."
            }
            if ($aggExtra.Count -gt 0) {
                & $emit "reason-contract: the aggregator's .OUTPUTS enum documents reason value(s) its ladder cannot emit: $($aggExtra -join ', ')."
            }
        }

        $prioMatch = [regex]::Match($prose, 'Cross-body priority, highest first:(.*?)\.')
        if (-not $prioMatch.Success) {
            & $emit 'reason-contract: the aggregator''s cross-body priority sentence could not be read. Unreadable is drift — this sentence is how a reader knows which of two bodies'' reasons wins.'
        }
        else {
            $aggPriority = @(
                ($prioMatch.Groups[1].Value -split '>') |
                    ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }
            )
            # The ladder's FIRST branch is 'ok', which fires when no body was
            # could-not-verify at all — the weakest cross-body signal, not the
            # strongest. Everything else keeps ladder order, first occurrence
            # wins ('head-corrupt' is reached twice).
            $seen = [System.Collections.Generic.HashSet[string]]::new()
            $expected = [System.Collections.Generic.List[string]]::new()
            foreach ($r in $ladderEmitted) {
                if ($r -ceq 'ok') { continue }
                if ($seen.Add($r)) { $expected.Add($r) }
            }
            if ($ladderEmitted -ccontains 'ok') { $expected.Add('ok') }
            if (($aggPriority -join ' > ') -cne ($expected -join ' > ')) {
                & $emit "reason-contract: the aggregator's cross-body priority sentence does not match the ladder's own order. Sentence=[$($aggPriority -join ' > ')] Ladder=[$($expected -join ' > ')]."
            }
        }
    }

    # -- Leg 5: the entry point has a message for every brief-only reason -----
    #
    # A brief-only reason with no branch here falls through to the generic
    # "partial, do not trust" line, which is precisely the diagnosis this block
    # exists to replace. Nothing about the library breaks, so no behavioural
    # test sees it (finding M5 / N1, PR #988).
    if ([string]::IsNullOrWhiteSpace($EntryPointSource)) {
        & $emit 'reason-contract: no entry-point source was supplied, so the per-reason maintainer-message block could not be checked. An unchecked leg is drift, not a leg that passed.'
    }
    elseif ($briefReasons.Count -gt 0) {
        $entryAnchor = "if (`$Surface -eq 'brief-review')"
        $entryStart = $EntryPointSource.IndexOf($entryAnchor, [System.StringComparison]::Ordinal)
        if ($entryStart -lt 0) {
            & $emit 'reason-contract: the entry point''s brief-review per-reason message block could not be located.'
        }
        else {
            $entryBrace = $EntryPointSource.IndexOf('{', $entryStart)
            $depth = 0
            $entryClose = -1
            for ($i = $entryBrace; $i -lt $EntryPointSource.Length -and $entryBrace -ge 0; $i++) {
                if ($EntryPointSource[$i] -eq '{') { $depth++ }
                elseif ($EntryPointSource[$i] -eq '}') {
                    $depth--
                    if ($depth -eq 0) { $entryClose = $i; break }
                }
            }
            if ($entryClose -lt 0) {
                & $emit 'reason-contract: the entry point''s brief-review block closing brace could not be located.'
            }
            else {
                $entrySpan = $EntryPointSource.Substring($entryBrace, $entryClose - $entryBrace + 1)
                $entryReasons = @(
                    @([regex]::Matches($entrySpan, "\`$reason\s+-eq\s+$reasonToken") |
                            ForEach-Object { $_.Groups[1].Value }) | Sort-Object -Unique
                )
                $entryMissing = @($briefReasons | Where-Object { $entryReasons -notcontains $_ })
                if ($entryMissing.Count -gt 0) {
                    & $emit "reason-contract: the entry point has no per-reason message for brief-only reason(s): $($entryMissing -join ', '). Each falls through to the generic 'partial, do not trust' line, which is the diagnosis that block exists to replace."
                }
            }
        }
    }

    return [PSCustomObject]@{
        HasDrift                    = ($driftDetails.Count -gt 0)
        DriftDetails                = $driftDetails.ToArray()
        DocumentedReasons           = @($documented)
        ReturnedReasons             = @($returned)
        SwitchArms                  = @($switchArms)
        LadderEmittedReasons        = @($ladderEmitted)
        LadderBriefOnlyReasons      = @($briefReasons)
        LadderBriefOnlyCount        = $ladderCount
        LadderStatedCount           = $statedCount
        LadderStatedReasons         = @($statedReasons)
        AggregatorDocumentedReasons = @($aggDocumented)
        AggregatorPriorityOrder     = @($aggPriority)
        EntryPointReasons           = @($entryReasons)
    }
}

#endregion
