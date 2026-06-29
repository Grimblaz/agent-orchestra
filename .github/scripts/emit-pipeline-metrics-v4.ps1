#Requires -Version 7.0
<#
.SYNOPSIS
    Emit a canonical v4 pipeline-metrics PR body (issue #769 s2).

.DESCRIPTION
    Builds a complete PR body containing the v4 <!-- pipeline-metrics --> block
    and writes it to -BodyFile.  Called BEFORE gh pr create with the output
    path as the --body-file argument.

    Three outcome cases (M5):
      Case 1 — New-PipelineMetricsV4Block throws (empty/invalid -V3BaseYaml,
                or pre-existing v4 block): writes fallback body with
                <!-- cost-capture-failed --> sentinel, exits non-zero.
      Case 2 — Block built but Test-PipelineMetricsV4Block reports invalid
                (empty credits, ≠1 marker): writes fallback body with sentinel,
                exits non-zero.
      Case 3 — Success: writes full body, exits 0.

    Critical invariants (M8, M21):
      - The <!-- cost-capture-failed --> sentinel is written in the catch block
        and guarded in finally so any abnormal exit also ships it.
      - The sentinel token does NOT match <!--\s*pipeline-metrics.
      - The sentinel, when present, does not inflate the pipeline-metrics
        marker count inside Test-PipelineMetricsV4Block.

.PARAMETER BodyFile
    Path to write the completed PR body file.

.PARAMETER V3BaseYaml
    v3 base fields as plain YAML (no pipeline-metrics wrapper).
    Required for New-PipelineMetricsV4Block to succeed.

.PARAMETER Credits
    Array of credit-row pscustomobjects from the frame accumulator.

.PARAMETER DispatchCostSamples
    Array of dispatch-cost-sample pscustomobjects.

.PARAMETER IssueNumber
    Issue number forwarded to the s-acc harvest hook.  When > 0 and Credits
    is empty, s-acc will inject a Get-FCLAccumulatedCredits harvest call here.
    This script does NOT implement the harvest — the parameter reserves the
    injection point.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$BodyFile,
    [string]$V3BaseYaml = '',
    [pscustomobject[]]$Credits = @(),
    [pscustomobject[]]$DispatchCostSamples = @(),
    [int]$IssueNumber = 0
)

$ErrorActionPreference = 'Stop'

# Track whether the sentinel has already been written so the finally block
# does not duplicate it on the normal-success path.
$script:sentinelWritten = $false

# ---------------------------------------------------------------------------
# Library dot-sources
# ---------------------------------------------------------------------------
$coreScript = Join-Path $PSScriptRoot 'lib/frame-credit-ledger-core.ps1'
. $coreScript

$originScript = Join-Path $PSScriptRoot 'lib/Get-FCLOriginContext.ps1'
. $originScript

# ---------------------------------------------------------------------------
# Main body
# ---------------------------------------------------------------------------
try {
    # s-acc: harvest from file-based accumulator when Credits not provided
    if ($IssueNumber -gt 0 -and $Credits.Count -eq 0) {
        $accScript = Join-Path $PSScriptRoot 'lib/Get-FCLAccumulatedCredits.ps1'
        if (Test-Path -LiteralPath $accScript) {
            . $accScript
            $Credits = @(Get-FCLAccumulatedCredits -IssueNumber $IssueNumber)
        }
    }

    # Build v4 block (Case 1 throw surface: empty V3BaseYaml or pre-existing v4)
    $v4Body = New-PipelineMetricsV4Block `
        -V3BaseYaml $V3BaseYaml `
        -Credits $Credits `
        -DispatchCostSamples $DispatchCostSamples

    # Validate (Case 2 surface: empty credits or ≠1 marker)
    $testResult = Test-PipelineMetricsV4Block -PRBody $v4Body
    if (-not $testResult.Valid) {
        throw "Test-PipelineMetricsV4Block validation failed: $($testResult.FailureReason)"
    }

    # Case 3 — success; mark sentinel as "not needed" so finally does not append it.
    $script:sentinelWritten = $true
    Set-Content -Path $BodyFile -Value $v4Body -Encoding utf8NoBOM
    exit 0
}
catch {
    # Case 1 or 2: write fallback body + sentinel
    $fallbackBody = if (-not [string]::IsNullOrWhiteSpace($V3BaseYaml)) {
        $V3BaseYaml
    } else {
        'metrics_emission_failed: true'
    }
    $fallbackBody += "`n`n<!-- cost-capture-failed -->"

    Set-Content -Path $BodyFile -Value $fallbackBody -Encoding utf8NoBOM
    $script:sentinelWritten = $true

    Write-Error "emit-pipeline-metrics-v4.ps1 failed: $_"
    exit 1
}
finally {
    # Sentinel durability guard: catches abnormal exits that occur between
    # try-start and catch (rare in PS7 but guard it per M8).
    # Only writes the sentinel when:
    #   - It was not already written by the catch block, AND
    #   - The body file exists (i.e. a partial write landed), AND
    #   - The sentinel is not already present in the file content.
    if (-not $script:sentinelWritten -and (Test-Path -LiteralPath $BodyFile)) {
        try {
            $existing = Get-Content -LiteralPath $BodyFile -Raw
            if ($existing -notmatch [regex]::Escape('<!-- cost-capture-failed -->')) {
                # Content present but no sentinel and not a clean success exit —
                # append sentinel to mark the body as unreliable.
                $existing += "`n`n<!-- cost-capture-failed -->"
                Set-Content -Path $BodyFile -Value $existing -Encoding utf8NoBOM
            }
        }
        catch {
            # Best-effort: if we cannot read/write the file, emit a warning and
            # let the caller detect the missing sentinel via the non-zero exit.
            Write-Warning "emit-pipeline-metrics-v4.ps1 finally: could not write sentinel — $_"
        }
    }
}
