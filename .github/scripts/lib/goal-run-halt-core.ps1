#Requires -Version 7.0
<#
.SYNOPSIS
    Schema-validating halt-report emitter for the goal-run harness (issue
    #874, plan step 1, AC2).
.DESCRIPTION
    This is the schema-validating EMIT PRIMITIVE only -- it does NOT decide
    halt-reason precedence (which halt_reason wins when multiple conditions
    are true at once is a later #874 step) and it does NOT get called from
    any real harness halt path yet (the harness loop that would call it on
    every halt is later #874 scope). What ships here:

      Test-GoalRunHaltReport -Report <object> -RepoRoot <string>
        Never throws. Validates -Report against
        skills/goal-run/schemas/goal-halt-report.schema.json (closed schema)
        via Test-Json, mirroring goal-contract-core.ps1's
        ConvertFrom-GCContractBlock validation step. Returns
        [pscustomobject]@{ IsValid; Violations }.

      ConvertTo-GoalRunInertEvidenceText -Text <string>
        Neutralizes `<!--`/`-->` marker-delimiter substrings anywhere inside
        arbitrary evidence/remediation prose, mirroring
        the Format-InertMarkerLabel strip convention
        (.github/scripts/phase-containment-emission-check.ps1:148-152) --
        duplicated here (not dot-sourced) because that host file is a full
        CLI script with mandatory parameter sets, not a reusable lib. Per
        the handoff-markers.md "Writing about markers safely" section,
        backtick-wrapping ALONE does not neutralize a raw-text marker scan --
        the delimiter substrings must actually be removed, which is what this
        function does.

      New-GoalRunHaltCommentBody -Report <object> -Issue <int>
        Renders the halt-report as a GitHub comment body headed by a
        self-closing `<!-- goal-halt-report-{Issue} -->` sentinel (the
        plan-issue-{ID}/design-issue-{ID} convention), with every
        evidence[]/plan_remediation string run through
        ConvertTo-GoalRunInertEvidenceText first.

      Invoke-GoalRunHaltEmit -Report <object> -Issue <int> -RepoRoot <string>
                              [-Owner <string>] [-Repo <string>]
        The emitter. THROWS (refuses to post) when Test-GoalRunHaltReport
        reports the object invalid -- this is the "refuse on every halt
        path" contract requirement. Only on a valid object does it render
        the comment body and upsert it via Find-OrUpsertComment
        (find-or-upsert-comment.ps1, dot-sourced lazily so validation-only
        callers/tests never need `gh` on PATH).
#>

. (Join-Path $PSScriptRoot 'goal-run-transcript-core.ps1')

$script:GoalRunHaltReportSchemaRelativePath = 'skills/goal-run/schemas/goal-halt-report.schema.json'

function Test-GoalRunHaltReport {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]$Report,
        [Parameter(Mandatory)][string]$RepoRoot
    )

    $violations = [System.Collections.Generic.List[string]]::new()

    $schemaPath = Join-Path $RepoRoot $script:GoalRunHaltReportSchemaRelativePath
    if (-not (Test-Path -LiteralPath $schemaPath)) {
        $violations.Add("Schema file not found at $schemaPath") | Out-Null
        return [pscustomobject]@{ IsValid = $false; Violations = $violations.ToArray() }
    }
    $schemaRaw = Get-Content -LiteralPath $schemaPath -Raw

    $json = $null
    try {
        # Explicit depth, matching the ConvertFrom-GCContractBlock rationale:
        # the ConvertTo-Json default of 2 silently flattens nested arrays
        # (evidence[]) and the budget_snapshot object.
        $json = $Report | ConvertTo-Json -Depth 20
    }
    catch {
        $violations.Add("Report object could not be serialized to JSON: $($_.Exception.Message)") | Out-Null
        return [pscustomobject]@{ IsValid = $false; Violations = $violations.ToArray() }
    }

    $testJsonError = $null
    $isValid = Test-Json -Json $json -Schema $schemaRaw -ErrorVariable testJsonError -ErrorAction SilentlyContinue

    if (-not $isValid) {
        $detail = if ($testJsonError -and $testJsonError.Count -gt 0) {
            (($testJsonError | ForEach-Object { $_.Exception.Message }) -join '; ')
        }
        else {
            'Halt-report object failed schema validation.'
        }
        $violations.Add($detail) | Out-Null
        return [pscustomobject]@{ IsValid = $false; Violations = $violations.ToArray() }
    }

    return [pscustomobject]@{ IsValid = $true; Violations = @() }
}

function ConvertTo-GoalRunInertEvidenceText {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text
    )

    return ($Text -replace '<!--\s*', '' -replace '\s*-->', '')
}

function New-GoalRunHaltCommentBody {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]$Report,
        [Parameter(Mandatory)][int]$Issue
    )

    $inertEvidence = [System.Collections.Generic.List[string]]::new()
    if ($Report.evidence) {
        foreach ($item in @($Report.evidence)) {
            $inertEvidence.Add((ConvertTo-GoalRunInertEvidenceText -Text ([string]$item))) | Out-Null
        }
    }
    $inertRemediation = ConvertTo-GoalRunInertEvidenceText -Text ([string]$Report.plan_remediation)

    $evidenceBlock = if ($inertEvidence.Count -gt 0) {
        (($inertEvidence | ForEach-Object { "- $_" })) -join "`n"
    }
    else {
        '- (none)'
    }

    $lines = @(
        "<!-- goal-halt-report-$Issue -->",
        '## Goal-run halt report',
        '',
        "- **halt_reason**: $($Report.halt_reason)",
        "- **stage**: $($Report.stage)",
        "- **arm**: $($Report.arm)",
        "- **claim_provenance**: $($Report.claim_provenance)",
        "- **target_ref**: $($Report.target_ref)",
        "- **recommended_next_owner**: $($Report.recommended_next_owner)",
        '',
        "**Plan remediation**: $inertRemediation",
        '',
        '**Evidence**:',
        $evidenceBlock
    )

    return ($lines -join "`n")
}

function Invoke-GoalRunHaltEmit {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]$Report,
        [Parameter(Mandatory)][int]$Issue,
        [Parameter(Mandatory)][string]$RepoRoot,
        [string]$Owner,
        [string]$Repo
    )

    $validation = Test-GoalRunHaltReport -Report $Report -RepoRoot $RepoRoot
    if (-not $validation.IsValid) {
        # Refuse -- never posts an invalid halt-report object, on every
        # halt path, per the requirement contract.
        throw "Invoke-GoalRunHaltEmit: refusing to post an invalid halt-report object -- $($validation.Violations -join '; ')"
    }

    . (Join-Path $RepoRoot '.github/scripts/lib/find-or-upsert-comment.ps1')

    $marker = "<!-- goal-halt-report-$Issue -->"
    $body = New-GoalRunHaltCommentBody -Report $Report -Issue $Issue

    $upsertParams = @{ Type = 'issue'; Number = $Issue; Marker = $marker; Body = $body }
    if ($Owner -and $Repo) {
        $upsertParams.Owner = $Owner
        $upsertParams.Repo = $Repo
    }

    $url = Find-OrUpsertComment @upsertParams
    return [pscustomobject]@{ Success = [bool]$url; Url = $url; Body = $body }
}
