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
    this file and call the function in-process -- the dot-source + in-process call
    pattern mandated by the #257 script-safety contract (no child pwsh per test).

    Three outcome cases (M5):
      Case 1 -- New-PipelineMetricsV4Block throws (empty/invalid -V3BaseYaml, or
               pre-existing v4 block): writes fallback body with
               <!-- cost-capture-failed --> sentinel, returns ExitCode=1.
      Case 2 -- Block built but Test-PipelineMetricsV4Block reports invalid
               (empty credits, != 1 marker): writes fallback body with sentinel,
               returns ExitCode=1.
      Case 3 -- Success: writes full body, returns ExitCode=0.

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

# ---------------------------------------------------------------------------
# script:Resolve-EmitV4Repo (issue #794 s2)
#
# Derives an 'owner/name' repo slug for the marker-harvest branch when -Repo
# is not supplied. Tries 'gh repo view' first, then falls back to parsing
# 'git remote get-url origin'. Returns $null (not throw) when both fail so
# the caller can fail open with a loud warning (CR: no throw across this
# boundary -- marker harvest must never block the rest of the emit).
# ---------------------------------------------------------------------------
function script:Resolve-EmitV4Repo {
    param(
        [string]$GhCliPath = 'gh'
    )

    try {
        $viewed = & $GhCliPath repo view --json nameWithOwner --jq '.nameWithOwner' 2>$null
        if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($viewed)) {
            $candidate = $viewed.Trim()
            if ($candidate -notmatch '^[A-Za-z0-9_.\-]+/[A-Za-z0-9_.\-]+$') { return $null }
            return $candidate
        }
    } catch {
        # fall through to git-remote parse
    }

    try {
        $remoteUrl = git remote get-url origin 2>$null
        if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($remoteUrl)) {
            $match = [regex]::Match($remoteUrl, 'github\.com[:/](.+?)(?:\.git)?$')
            if ($match.Success) {
                $candidate = $match.Groups[1].Value.Trim()
                if ($candidate -notmatch '^[A-Za-z0-9_.\-]+/[A-Za-z0-9_.\-]+$') { return $null }
                return $candidate
            }
        }
    } catch {
        # both paths failed -- return $null, caller warns and skips.
    }

    return $null
}

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
        file-based accumulator (.tmp/issue-{N}/fclcredits.jsonl). Independently
        of that gate, when > 0 and -SkipMarkerHarvest is not set, also runs the
        SMC-17 marker-harvest branch (issue #794 s2) to backfill any of the
        four pipeline-entry ports (experience/design/plan/orchestration) missing
        from the composed credits set.

    .PARAMETER RichBody
        Optional full markdown PR body already composed by the conductor. When
        provided, the v4 block is appended to it so the final file carries both
        the human-readable PR content AND the metrics block. On failure the rich
        body is still written followed by the sentinel so Closes #N always
        survives in the shipped PR body.

    .PARAMETER Repo
        Repository in 'owner/name' form, used for the marker-harvest branch's
        gh calls. When not supplied, derived via 'gh repo view' then via
        'git remote get-url origin' parsing (issue #794 s2).

    .PARAMETER GhCliPath
        Path to the gh CLI executable. Defaults to 'gh'. Overridable for test
        injection so no live network call is made from in-process Pester runs.

    .PARAMETER SkipMarkerHarvest
        Bypasses the marker-harvest branch entirely. Tests that exercise only
        the pre-existing accumulator/sentinel path should set this to avoid any
        gh involvement.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$BodyFile,
        [string]$V3BaseYaml = '',
        [pscustomobject[]]$Credits = @(),
        [pscustomobject[]]$DispatchCostSamples = @(),
        [int]$IssueNumber = 0,
        [string]$RichBody = '',
        [string]$Repo = '',
        [string]$GhCliPath = 'gh',
        [switch]$SkipMarkerHarvest
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
                Write-Warning "harvest script not found at $accScript -- proceeding with explicitly-passed credits only"
            }
        }

        # SMC-17 marker-harvest branch (issue #794 s2): independent of the accumulator
        # gate above -- fires whenever -IssueNumber is supplied and harvest is not
        # explicitly skipped, even when $Credits is already populated. Backfills any
        # of the four pipeline-entry ports (experience/design/plan/orchestration)
        # missing from the composed credits set. Never overwrites an existing row
        # for a port that Credits/accumulator already populated (port-only dedup --
        # harvested rows never carry a positive terminal-step-id, so they cannot
        # usefully collide on (port, terminal-step-id) with a real row).
        if ($IssueNumber -gt 0 -and -not $SkipMarkerHarvest) {
            # Fold-in (issue #794 review M3): isolate the harvest/merge logic in its
            # own try/catch so a harvest failure degrades gracefully -- it skips the
            # harvested rows and keeps whatever $Credits already had from the
            # accumulator/explicit param, rather than propagating into the outer
            # try/catch and discarding already-composed $Credits into the
            # cost-capture-failed sentinel path.
            try {
                $resolvedRepo = if (-not [string]::IsNullOrWhiteSpace($Repo)) { $Repo } else { script:Resolve-EmitV4Repo -GhCliPath $GhCliPath }

                if ([string]::IsNullOrWhiteSpace($resolvedRepo)) {
                    Write-Warning "Credits harvest skipped -- could not resolve repo for marker harvest; cost-pattern-presence-check.yml will likely fail on this PR if credits remain empty."
                } else {
                    $existingPorts = @($Credits | ForEach-Object { $_.port })
                    $harvested = @(Invoke-CreditInputHarvest -IssueNumber ([string]$IssueNumber) -Repo $resolvedRepo -GhCliPath $GhCliPath -MaxRetries 0)
                    foreach ($harvestedRow in $harvested) {
                        if ($existingPorts -notcontains $harvestedRow.port) {
                            $Credits += $harvestedRow
                            $existingPorts += $harvestedRow.port
                        }
                    }
                }
            } catch {
                Write-Warning "Credits harvest failed -- proceeding without harvested rows; existing Credits are preserved. Error: $($_.Exception.Message)"
            }
        }

        # Build v4 block (Case 1 throw surface: empty V3BaseYaml or pre-existing v4).
        $v4Body = New-PipelineMetricsV4Block `
            -V3BaseYaml $V3BaseYaml `
            -Credits $Credits `
            -DispatchCostSamples $DispatchCostSamples

        # Compose final body FIRST (rich content + v4 block) so validation runs
        # against the body we actually ship. A RichBody that already contains a
        # pipeline-metrics block would otherwise produce a double-marker body that
        # passes a v4-block-only check but fails the composed-body check.
        $finalBody = if ([string]::IsNullOrWhiteSpace($RichBody)) {
            $v4Body  # backwards-compat: no rich body passed
        } else {
            "$RichBody`n`n$v4Body"
        }

        # Validate (Case 2 surface: empty credits or != 1 marker), against the
        # composed final body so a duplicate marker fails into the sentinel fallback.
        $testResult = Test-PipelineMetricsV4Block -PRBody $finalBody
        if (-not $testResult.Valid) {
            throw "Test-PipelineMetricsV4Block validation failed: $($testResult.FailureReason)"
        }

        # Case 3 -- success.
        $sentinelWritten = $true
        Set-Content -LiteralPath $BodyFile -Value $finalBody -Encoding utf8NoBOM
        return [pscustomobject]@{ ExitCode = 0; SentinelWritten = $false }
    }
    catch {
        # Case 1 or 2: write fallback body + sentinel.

        # Strip any embedded pipeline-metrics block from RichBody before using it
        # as the fallback base.  If RichBody was the source of the double-marker
        # (CR-NEW-1), writing it back unchanged would leave a stale metrics block in
        # the failure body, confusing downstream consumers despite the failure
        # sentinel that follows.
        $sanitizedRichBody = if ([string]::IsNullOrWhiteSpace($RichBody)) {
            ''
        } else {
            [regex]::Replace(
                $RichBody,
                '(?s)\s*<!--\s*pipeline-metrics.*?-->\s*',
                ''
            ).Trim()
        }

        $fallbackBase = if ([string]::IsNullOrWhiteSpace($sanitizedRichBody)) {
            # Only reuse V3BaseYaml when it does NOT carry a pipeline-metrics opener;
            # reusing a poisoned base would re-ship the double-marker content that
            # caused the failure in the first place.
            if (-not [string]::IsNullOrWhiteSpace($V3BaseYaml) -and $V3BaseYaml -notmatch '<!--\s*pipeline-metrics') {
                $V3BaseYaml
            } else {
                'metrics_emission_failed: true'
            }
        } else {
            $sanitizedRichBody
        }
        $fallbackBody = "$fallbackBase`n`n<!-- cost-capture-failed -->"

        # Pre-PR warn (issue #794 s2, sub-observation 1): if the composed credits
        # set (after accumulator + marker-harvest merge, above) is still empty and
        # this is an issue-scoped invocation, warn loudly before the sentinel ships
        # so the CI failure is predictable rather than a surprise.
        if ($Credits.Count -eq 0 -and $IssueNumber -gt 0) {
            Write-Warning "credits[] is empty -- cost-pattern-presence-check.yml will fail on this PR unless this is fixed before push."
        }

        Set-Content -LiteralPath $BodyFile -Value $fallbackBody -Encoding utf8NoBOM
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
                    Set-Content -LiteralPath $BodyFile -Value $existing -Encoding utf8NoBOM
                }
            }
            catch {
                Write-Warning "emit-pipeline-metrics-v4 finally: could not write sentinel -- $_"
            }
        }
    }
}
