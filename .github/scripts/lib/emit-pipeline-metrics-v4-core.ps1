#Requires -Version 7.0
<#
.SYNOPSIS
    Core library for emit-pipeline-metrics-v4 (issue #769 s2).

.DESCRIPTION
    Invoke-PipelineMetricsV4Emit builds a canonical v4 <!-- pipeline-metrics -->
    PR body and writes it to -BodyFile, returning a result object
    ([pscustomobject] with ExitCode/SentinelWritten) instead of calling `exit`.

    The thin wrapper emit-pipeline-metrics-v4.ps1 dot-sources this file, calls the
    function, and translates ExitCode to a process exit code. Tests dot-source
    this file and call the function in-process — the dot-source + in-process call
    pattern mandated by the #257 script-safety contract (no child pwsh per test).

    Three outcome cases (M5):
      Case 1 — New-PipelineMetricsV4Block throws (empty/invalid -V3BaseYaml, or
               pre-existing v4 block): writes fallback body with
               <!-- cost-capture-failed --> sentinel, returns ExitCode=1.
      Case 2 — Block built but Test-PipelineMetricsV4Block reports invalid
               (empty credits, ≠1 marker): writes fallback body with sentinel,
               returns ExitCode=1.
      Case 3 — Success: writes full body, returns ExitCode=0.

    Critical invariants (M8, M21):
      - The <!-- cost-capture-failed --> sentinel is written in the catch block
        and guarded in finally so any abnormal exit also ships it.
      - The sentinel token does NOT match <!--\s*pipeline-metrics.
      - The sentinel, when present, does not inflate the pipeline-metrics
        marker count inside Test-PipelineMetricsV4Block.
#>

# ---------------------------------------------------------------------------
# Library dot-sources (siblings in lib/)
# ---------------------------------------------------------------------------
. (Join-Path $PSScriptRoot 'frame-credit-ledger-core.ps1')
. (Join-Path $PSScriptRoot 'Get-FCLOriginContext.ps1')

function Invoke-PipelineMetricsV4Emit {
    <#
    .SYNOPSIS
        Build and write the v4 pipeline-metrics PR body; return ExitCode/SentinelWritten.

    .PARAMETER BodyFile
        Path to write the completed PR body file.

    .PARAMETER V3BaseYaml
        v3 base fields as plain YAML (no pipeline-metrics wrapper).

    .PARAMETER Credits
        Array of credit-row pscustomobjects from the frame accumulator.

    .PARAMETER DispatchCostSamples
        Array of dispatch-cost-sample pscustomobjects.

    .PARAMETER IssueNumber
        When > 0 and Credits is empty, harvest credits from the s-acc
        file-based accumulator (.tmp/issue-{N}/fclcredits.jsonl).

    .PARAMETER RichBody
        Optional full markdown PR body already composed by the conductor. When
        provided, the v4 block is appended to it so the final file carries both
        the human-readable PR content AND the metrics block. On failure the rich
        body is still written followed by the sentinel so Closes #N always
        survives in the shipped PR body.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$BodyFile,
        [string]$V3BaseYaml = '',
        [pscustomobject[]]$Credits = @(),
        [pscustomobject[]]$DispatchCostSamples = @(),
        [int]$IssueNumber = 0,
        [string]$RichBody = ''
    )

    $ErrorActionPreference = 'Stop'

    # Track whether the sentinel has already been written so the finally block
    # does not duplicate it on the normal-success path.
    $sentinelWritten = $false

    try {
        # s-acc: harvest from file-based accumulator when Credits not provided.
        if ($IssueNumber -gt 0 -and $Credits.Count -eq 0) {
            $accScript = Join-Path $PSScriptRoot 'Get-FCLAccumulatedCredits.ps1'
            if (Test-Path -LiteralPath $accScript) {
                . $accScript
                $Credits = @(Get-FCLAccumulatedCredits -IssueNumber $IssueNumber)
            } else {
                Write-Warning "harvest script not found at $accScript — proceeding with explicitly-passed credits only"
            }
        }

        # Build v4 block (Case 1 throw surface: empty V3BaseYaml or pre-existing v4).
        $v4Body = New-PipelineMetricsV4Block `
            -V3BaseYaml $V3BaseYaml `
            -Credits $Credits `
            -DispatchCostSamples $DispatchCostSamples

        # Validate (Case 2 surface: empty credits or ≠1 marker).
        $testResult = Test-PipelineMetricsV4Block -PRBody $v4Body
        if (-not $testResult.Valid) {
            throw "Test-PipelineMetricsV4Block validation failed: $($testResult.FailureReason)"
        }

        # Case 3 — success: compose final body (rich content + v4 block).
        $finalBody = if ([string]::IsNullOrWhiteSpace($RichBody)) {
            $v4Body  # backwards-compat: no rich body passed
        } else {
            "$RichBody`n`n$v4Body"
        }

        $sentinelWritten = $true
        Set-Content -Path $BodyFile -Value $finalBody -Encoding utf8NoBOM
        return [pscustomobject]@{ ExitCode = 0; SentinelWritten = $false }
    }
    catch {
        # Case 1 or 2: write fallback body + sentinel.
        $fallbackBase = if ([string]::IsNullOrWhiteSpace($RichBody)) {
            if (-not [string]::IsNullOrWhiteSpace($V3BaseYaml)) {
                $V3BaseYaml
            } else {
                'metrics_emission_failed: true'
            }
        } else {
            $RichBody
        }
        $fallbackBody = "$fallbackBase`n`n<!-- cost-capture-failed -->"

        Set-Content -Path $BodyFile -Value $fallbackBody -Encoding utf8NoBOM
        $sentinelWritten = $true

        # Non-terminating warning keeps this function safe for in-process test
        # callers; the load-bearing failure signals are ExitCode=1 + the sentinel.
        Write-Warning "emit-pipeline-metrics-v4 failed: $_"
        return [pscustomobject]@{ ExitCode = 1; SentinelWritten = $true }
    }
    finally {
        # Sentinel durability guard: catches abnormal exits that occur between
        # try-start and the catch (rare in PS7 but guard it per M8).
        # Only writes the sentinel when:
        #   - It was not already written by the catch block, AND
        #   - The body file exists (i.e. a partial write landed), AND
        #   - The sentinel is not already present in the file content.
        if (-not $sentinelWritten -and (Test-Path -LiteralPath $BodyFile)) {
            try {
                $existing = Get-Content -LiteralPath $BodyFile -Raw
                if ($existing -notmatch [regex]::Escape('<!-- cost-capture-failed -->')) {
                    $existing += "`n`n<!-- cost-capture-failed -->"
                    Set-Content -Path $BodyFile -Value $existing -Encoding utf8NoBOM
                }
            }
            catch {
                Write-Warning "emit-pipeline-metrics-v4 finally: could not write sentinel — $_"
            }
        }
    }
}
