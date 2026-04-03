#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
.SYNOPSIS
    Pester 5 tests for aggregate-review-scores.ps1 -CalibrationFile feature.

.DESCRIPTION
    Contract under test (new -CalibrationFile feature):
      - -CalibrationFile parameter declared with default
        .copilot-tracking/calibration/review-data.json
      - No local file -> existing behavior preserved (same YAML output fields, exit 0)
      - data_source field added to output when calibration file is present
      - Local entries supplement GitHub PR body entries (union merge)
      - Orphan local entries (pr_number not in GitHub merged list) are excluded
      - GitHub mergedAt timestamp is authoritative over local created_at

    Isolation strategy:
      - Each test uses a fresh temp directory.
      - gh-dependent tests (union merge, fallback behavior) are tagged 'requires-gh'
        and skipped when gh CLI is not available.
      - Parameter declaration tests use AST introspection (no gh needed).

    Calibration file schema (follows write-calibration-entry.ps1):
      { "calibration_version": 1, "entries": [ { pr_number, created_at, findings[], summary } ] }
#>

Describe 'aggregate-review-scores.ps1 -CalibrationFile' {

    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
        $script:ScriptFile = Join-Path $script:RepoRoot '.github\scripts\aggregate-review-scores.ps1'
        $script:LibFile = Join-Path $script:RepoRoot '.github\scripts\lib\aggregate-review-scores-core.ps1'
        . $script:LibFile

        # Master temp root — all per-test dirs live under here
        $script:TempRoot = Join-Path ([System.IO.Path]::GetTempPath()) `
            "pester-aggregate-$([System.Guid]::NewGuid().ToString('N'))"
        New-Item -ItemType Directory -Path $script:TempRoot -Force | Out-Null

        # Check gh CLI availability (gh-dependent tests are tagged requires-gh)
        $script:GhAvailable = $null -ne (Get-Command gh -ErrorAction SilentlyContinue)
        $script:CleanCalibrationRepo = 'github/docs'
        $script:CleanCalibrationLimit = 10
        $script:PipelineMetricsBlockPattern = '(?s)<!--\s*pipeline-metrics\s*(.*?)-->'
        $script:CleanCalibrationPrNumber = $null
        $script:CleanCalibrationBaselineIssuesAnalyzed = $null
        $script:CleanCalibrationWindowReady = $false
        $script:CleanCalibrationBootstrapReady = $false
        $script:CleanCalibrationWindowSignature = ''
        $script:CleanCalibrationWindowSkipReason =
        'clean calibration bootstrap query failed or returned no usable merged PR window'
        $script:CleanCalibrationBootstrapSkipReason =
        'clean calibration bootstrap did not produce a usable real PR candidate'
        $script:CleanCalibrationWindowStabilitySkipReason =
        "clean calibration bootstrap latest-$($script:CleanCalibrationLimit) github/docs window changed after bootstrap"
        $script:TestHasPipelineMetricsBlock = {
            param([AllowNull()][string]$Body)

            $bodyText = if ($null -eq $Body) { '' } else { $Body }
            return [regex]::IsMatch($bodyText, $script:PipelineMetricsBlockPattern)
        }
        $script:GetCleanCalibrationWindowSnapshot = {
            $cleanCalibrationPrListJson = & gh pr list --repo $script:CleanCalibrationRepo `
                --state merged --limit $script:CleanCalibrationLimit --json 'number,body' 2>$null
            if ($LASTEXITCODE -ne 0 -or -not $cleanCalibrationPrListJson) {
                return @()
            }

            $cleanCalibrationWindow = @($cleanCalibrationPrListJson | ConvertFrom-Json)
            return @(
                $cleanCalibrationWindow | ForEach-Object {
                    [pscustomobject]@{
                        number      = [int]$_.number
                        has_metrics = [bool](& $script:TestHasPipelineMetricsBlock -Body $_.body)
                    }
                }
            )
        }
        $script:GetCleanCalibrationWindowSignature = {
            param([object[]]$WindowSnapshot)

            if ($null -eq $WindowSnapshot -or $WindowSnapshot.Count -eq 0) {
                return ''
            }

            return (@(
                    $WindowSnapshot | ForEach-Object {
                        '{0}:{1}' -f [int]$_.number, ([int][bool]$_.has_metrics)
                    }
                ) -join ',')
        }
        $script:AssertCleanCalibrationWindowStable = {
            param([switch]$RequireBootstrapCandidate)

            if (-not $script:CleanCalibrationWindowReady) {
                Set-ItResult -Skipped -Because $script:CleanCalibrationWindowSkipReason
                return $false
            }
            if ($RequireBootstrapCandidate -and -not $script:CleanCalibrationBootstrapReady) {
                Set-ItResult -Skipped -Because $script:CleanCalibrationBootstrapSkipReason
                return $false
            }

            try {
                $currentWindowSnapshot = @(& $script:GetCleanCalibrationWindowSnapshot)
            }
            catch {
                Set-ItResult -Skipped -Because "clean calibration live-window stability check failed: $($_.Exception.Message)"
                return $false
            }

            if ($currentWindowSnapshot.Count -eq 0) {
                Set-ItResult -Skipped -Because 'clean calibration live-window stability check returned no usable merged PR window'
                return $false
            }

            $currentWindowSignature = & $script:GetCleanCalibrationWindowSignature -WindowSnapshot $currentWindowSnapshot
            if ($currentWindowSignature -ne $script:CleanCalibrationWindowSignature) {
                Set-ItResult -Skipped -Because $script:CleanCalibrationWindowStabilitySkipReason
                return $false
            }

            return $true
        }
        if ($script:GhAvailable) {
            try {
                $cleanCalibrationWindow = @(& $script:GetCleanCalibrationWindowSnapshot)
                if ($cleanCalibrationWindow.Count -gt 0) {
                    $script:CleanCalibrationWindowReady = $true
                    $script:CleanCalibrationWindowSignature = & $script:GetCleanCalibrationWindowSignature `
                        -WindowSnapshot $cleanCalibrationWindow
                    $script:CleanCalibrationBaselineIssuesAnalyzed = @(
                        $cleanCalibrationWindow |
                            Where-Object { $_.has_metrics }
                    ).Count

                    $cleanCalibrationCandidate = @(
                        $cleanCalibrationWindow |
                            Where-Object { -not $_.has_metrics } |
                            Select-Object -First 1
                    )
                    if ($cleanCalibrationCandidate.Count -gt 0) {
                        $script:CleanCalibrationPrNumber = [int]$cleanCalibrationCandidate[0].number
                        $script:CleanCalibrationBootstrapReady = $true
                    }
                }
            }
            catch {
                $script:CleanCalibrationWindowSkipReason =
                "clean calibration bootstrap query failed: $($_.Exception.Message)"
                $script:CleanCalibrationBootstrapSkipReason =
                "clean calibration bootstrap query failed: $($_.Exception.Message)"
            }
        }

        # ------------------------------------------------------------------
        # Parse script AST for parameter introspection tests (no gh needed)
        # ------------------------------------------------------------------
        $scriptContent = Get-Content -Path $script:ScriptFile -Raw
        $parseErrors = $null
        $script:ScriptAst = [System.Management.Automation.Language.Parser]::ParseInput(
            $scriptContent, [ref]$null, [ref]$parseErrors
        )
        $script:AllParams = $script:ScriptAst.FindAll(
            { $args[0] -is [System.Management.Automation.Language.ParameterAst] }, $true
        )
        $script:ParamNames = $script:AllParams | ForEach-Object { $_.Name.VariablePath.UserPath }

        # ------------------------------------------------------------------
        # Calibration fixture: one valid local entry for a real merged PR in a repo
        # whose PR bodies do not use pipeline-metrics, so local calibration data is
        # the only source for that PR.
        # ------------------------------------------------------------------
        $script:ValidCalibration = [ordered]@{
            calibration_version = 1
            entries             = @(
                [ordered]@{
                    pr_number  = $script:CleanCalibrationPrNumber
                    created_at = '2026-01-15T10:00:00Z'
                    findings   = @(
                        [ordered]@{
                            id           = 'F1'
                            category     = 'architecture'
                            judge_ruling = 'sustained'
                            review_stage = 'main'
                        }
                    )
                    summary    = [ordered]@{
                        prosecution_findings = 1
                        pass_1_findings      = 1
                        pass_2_findings      = 0
                        pass_3_findings      = 0
                        defense_disproved    = 0
                        judge_accepted       = 1
                        judge_rejected       = 0
                        judge_deferred       = 0
                    }
                }
            )
        }

        # ------------------------------------------------------------------
        # Orphan calibration fixture: pr_number=99999999 cannot exist in the repo
        # (well above any real PR number). Used to verify orphan removal.
        # ------------------------------------------------------------------
        $script:OrphanCalibration = [ordered]@{
            calibration_version = 1
            entries             = @(
                [ordered]@{
                    pr_number  = 99999999
                    created_at = '2026-03-01T08:00:00Z'
                    findings   = @()
                    summary    = [ordered]@{
                        prosecution_findings = 0
                        pass_1_findings      = 0
                        pass_2_findings      = 0
                        pass_3_findings      = 0
                        defense_disproved    = 0
                        judge_accepted       = 0
                        judge_rejected       = 0
                        judge_deferred       = 0
                    }
                }
            )
        }

        # ------------------------------------------------------------------
        # Stale-timestamp calibration fixture: created_at is ancient (year 2000),
        # which would round to an effective sample size of 0.0 if the script used
        # the local timestamp. Used to verify that GitHub's mergedAt overrides the
        # local value for a real merged PR.
        # ------------------------------------------------------------------
        $script:StaleTimestampCalibration = [ordered]@{
            calibration_version = 1
            entries             = @(
                [ordered]@{
                    pr_number  = $script:CleanCalibrationPrNumber
                    created_at = '2000-01-01T00:00:00Z'
                    findings   = @(
                        [ordered]@{
                            id           = 'F1'
                            category     = 'architecture'
                            judge_ruling = 'sustained'
                            review_stage = 'main'
                        }
                    )
                    summary    = [ordered]@{
                        prosecution_findings = 1
                        pass_1_findings      = 1
                        pass_2_findings      = 0
                        pass_3_findings      = 0
                        defense_disproved    = 0
                        judge_accepted       = 1
                        judge_rejected       = 0
                        judge_deferred       = 0
                    }
                }
            )
        }

        # ------------------------------------------------------------------
        # Helper: fresh isolated temp dir for a single test
        # ------------------------------------------------------------------
        $script:NewWorkDir = {
            $dir = Join-Path $script:TempRoot ([System.Guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            return $dir
        }

        # ------------------------------------------------------------------
        # Helper: write a calibration JSON file to an absolute path
        # ------------------------------------------------------------------
        $script:WriteCalibrationFile = {
            param([string]$Path, [object]$Data)
            $dir = Split-Path $Path -Parent
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            $Data | ConvertTo-Json -Depth 10 | Set-Content -Path $Path -Encoding UTF8
        }

        # ------------------------------------------------------------------
        # Helper: invoke Invoke-AggregateReviewScores in-process.
        # $ExtraArgs are parsed from '-Key Value' pairs into a params hashtable.
        # Returns @{ ExitCode; Output (stdout string); Error (stderr string) }
        # ------------------------------------------------------------------
        $script:InvokeAggregate = {
            param([string[]]$ExtraArgs = @())
            Push-Location $script:RepoRoot
            try {
                $params = @{ GhCliPath = 'gh' }
                $i = 0
                while ($i -lt $ExtraArgs.Count) {
                    $arg = $ExtraArgs[$i]
                    if ($arg -match '^-[-]?(.+)') {
                        $key = $Matches[1]
                        if ($i + 1 -lt $ExtraArgs.Count -and -not ($ExtraArgs[$i + 1] -match '^-')) {
                            $params[$key] = $ExtraArgs[$i + 1]
                            $i += 2
                        }
                        else {
                            $params[$key] = $true
                            $i++
                        }
                    }
                    else {
                        $i++
                    }
                }
                return Invoke-AggregateReviewScores @params
            }
            finally {
                Pop-Location
            }
        }
    }

    AfterAll {
        try {
            if (Test-Path $script:TempRoot) {
                Remove-Item -Recurse -Force -Path $script:TempRoot
            }
        }
        finally {
            # Suppress removal errors so AfterAll never throws
        }
    }

    # ==================================================================
    # Context: -CalibrationFile parameter declaration (AST-based, no gh)
    # ==================================================================
    Context '-CalibrationFile parameter declaration' {

        It 'declares a -CalibrationFile parameter in the param block' {
            # RED: the parameter does not yet exist in aggregate-review-scores.ps1.
            # Strategy: parse the script AST and look for the CalibrationFile param.
            $script:ParamNames | Should -Contain 'CalibrationFile' `
                -Because '-CalibrationFile must be declared so callers can pass a local calibration path'
        }

        It 'defaults -CalibrationFile to .copilot-tracking/calibration/review-data.json' {
            # RED: parameter does not exist yet; this will fail on the BeNullOrEmpty check.
            # Once the parameter is added, the default value text must contain the canonical path.
            $calibParam = $script:AllParams | Where-Object {
                $_.Name.VariablePath.UserPath -eq 'CalibrationFile'
            }
            $calibParam | Should -Not -BeNullOrEmpty `
                -Because '-CalibrationFile must exist before its default can be checked'

            $defaultText = $calibParam.DefaultValue.Extent.Text
            $defaultText | Should -Match '\.copilot-tracking[/\\]calibration[/\\]review-data\.json' `
                -Because 'default path must be .copilot-tracking/calibration/review-data.json'
        }
    }

    # ==================================================================
    # Context: fallback when calibration file is absent
    # Requires gh CLI to reach GitHub and produce any output at all.
    # ==================================================================
    Context 'fallback when calibration file is absent' {

        It 'exits 0 when -CalibrationFile path does not exist' -Tag 'requires-gh' {
            # Requires gh CLI
            # RED: -CalibrationFile is not a recognized parameter; invoking with it
            # produces a parameter-binding error (exit code 1).
            # Once implemented: unknown path -> behave as PR-body-only -> exit 0.
            if (-not $script:GhAvailable) { Set-ItResult -Skipped -Because 'gh CLI not found' }

            $workDir = & $script:NewWorkDir
            $nonExistentPath = Join-Path $workDir 'does-not-exist.json'

            $result = & $script:InvokeAggregate `
                -ExtraArgs @('-CalibrationFile', $nonExistentPath)

            $result.ExitCode | Should -Be 0 `
                -Because 'a missing calibration file must not abort the script'
        }

        It 'preserves existing YAML output fields when -CalibrationFile path does not exist' -Tag 'requires-gh' {
            # Requires gh CLI
            # RED: parameter-binding error makes exit code non-zero currently.
            # Once implemented: output must still contain canonical fields
            # (insufficient_data: or calibration: plus skipped_prs:), proving
            # that the existing PR-body-parsing path is unchanged.
            if (-not $script:GhAvailable) { Set-ItResult -Skipped -Because 'gh CLI not found' }

            $workDir = & $script:NewWorkDir
            $nonExistentPath = Join-Path $workDir 'does-not-exist.json'

            $result = & $script:InvokeAggregate `
                -ExtraArgs @('-CalibrationFile', $nonExistentPath)

            $result.ExitCode | Should -Be 0

            # At least one canonical output field must be present
            $hasKnownField = ($result.Output -match 'insufficient_data:') -or
            ($result.Output -match 'calibration:') -or
            ($result.Output -match 'skipped_prs:')
            $hasKnownField | Should -BeTrue `
                -Because 'existing YAML output fields must be preserved when CalibrationFile is absent'
        }
    }

    # ==================================================================
    # Context: union merge with local calibration data
    # All require gh CLI to query the real merged PR list.
    # ==================================================================
    Context 'union merge with local calibration data' {

        It 'adds a data_source field to YAML output when calibration file is present' -Tag 'requires-gh' {
            # Requires gh CLI
            # RED: -CalibrationFile is not recognized; parameter binding error.
            # Once implemented: output must contain "data_source:" (value is one of
            # "local", "github", or "merged") when a calibration file is provided.
            if (-not $script:GhAvailable) { Set-ItResult -Skipped -Because 'gh CLI not found'; return }
            if (-not (& $script:AssertCleanCalibrationWindowStable -RequireBootstrapCandidate)) {
                return
            }

            $workDir = & $script:NewWorkDir
            $calibPath = Join-Path $workDir 'calib.json'
            & $script:WriteCalibrationFile -Path $calibPath -Data $script:ValidCalibration

            $result = & $script:InvokeAggregate `
                -ExtraArgs @(
                '-Repo',
                $script:CleanCalibrationRepo,
                '-Limit',
                $script:CleanCalibrationLimit,
                '-CalibrationFile',
                $calibPath
            )

            $result.ExitCode | Should -Be 0
            $result.Output | Should -Match 'data_source:' `
                -Because 'data_source field must appear in output when a calibration file is provided'
        }

        It 'sets data_source to "github" when calibration file contains only orphan entries' -Tag 'requires-gh' {
            # Requires gh CLI
            # RED: -CalibrationFile not recognized yet.
            # Once implemented: all local entries are orphans (pr_number=99999999 not in
            # GitHub's merged PR list) so they are removed; data comes from GitHub only;
            # data_source must be "github".
            if (-not $script:GhAvailable) { Set-ItResult -Skipped -Because 'gh CLI not found' }

            $workDir = & $script:NewWorkDir
            $calibPath = Join-Path $workDir 'orphan-calib.json'
            & $script:WriteCalibrationFile -Path $calibPath -Data $script:OrphanCalibration

            $result = & $script:InvokeAggregate `
                -ExtraArgs @('-CalibrationFile', $calibPath)

            $result.ExitCode | Should -Be 0
            $result.Output | Should -Match 'data_source:\s*github' `
                -Because 'orphan entries must be excluded; data must come from GitHub only'
        }

        It 'excludes orphan local entries not present in the GitHub merged PR list' -Tag 'requires-gh' {
            # Requires gh CLI
            # RED: -CalibrationFile not recognized; exit code non-zero.
            # Once implemented: orphan entries must not add to the analyzed-issues
            # count beyond what the exact fetched clean-repo window already contributes.
            if (-not $script:GhAvailable) { Set-ItResult -Skipped -Because 'gh CLI not found'; return }
            if (-not (& $script:AssertCleanCalibrationWindowStable)) {
                return
            }

            $workDir = & $script:NewWorkDir

            $calibPath = Join-Path $workDir 'orphan-calib.json'
            & $script:WriteCalibrationFile -Path $calibPath -Data $script:OrphanCalibration
            $withOrphanResult = & $script:InvokeAggregate `
                -ExtraArgs @(
                '-Repo',
                $script:CleanCalibrationRepo,
                '-Limit',
                $script:CleanCalibrationLimit,
                '-CalibrationFile',
                $calibPath
            )

            $orphanMatch = [regex]::Match($withOrphanResult.Output, 'issues_analyzed:\s*(\d+)')

            $withOrphanResult.ExitCode | Should -Be 0 `
                -Because '-CalibrationFile with orphan-only entries must not crash the script'
            $withOrphanResult.Output | Should -Match 'data_source:\s*github' `
                -Because 'orphan local entries must not contribute local calibration data'

            if ($orphanMatch.Success) {
                [int]$orphanMatch.Groups[1].Value | Should -Be $script:CleanCalibrationBaselineIssuesAnalyzed `
                    -Because 'orphan local entries must leave issues_analyzed at the same count contributed by the fetched clean-repo window'
            }
            else {
                $withOrphanResult.Output | Should -Match 'insufficient_data:\s*true' `
                    -Because 'orphan-only calibration data must not add analyzable issues beyond the fetched clean-repo window baseline'
            }
        }

        It 'uses GitHub mergedAt timestamp as authoritative over local created_at' -Tag 'requires-gh' {
            # Requires gh CLI
            # RED: -CalibrationFile not recognized; exit code non-zero.
            # Once implemented: the local entry targets a real merged PR in a repo whose
            # PR bodies have no pipeline-metrics. If the script incorrectly uses the local
            # created_at='2000-01-01', effective_sample_size rounds to 0.0. If GitHub's
            # mergedAt is authoritative, the matched PR contributes a positive weight.
            if (-not $script:GhAvailable) { Set-ItResult -Skipped -Because 'gh CLI not found'; return }
            if (-not (& $script:AssertCleanCalibrationWindowStable -RequireBootstrapCandidate)) {
                return
            }

            $workDir = & $script:NewWorkDir

            # Run with stale-timestamp calibration file
            $calibPath = Join-Path $workDir 'stale-calib.json'
            & $script:WriteCalibrationFile -Path $calibPath -Data $script:StaleTimestampCalibration
            $withStaleResult = & $script:InvokeAggregate `
                -ExtraArgs @(
                '-Repo',
                $script:CleanCalibrationRepo,
                '-Limit',
                $script:CleanCalibrationLimit,
                '-CalibrationFile',
                $calibPath
            )

            # Extract effective_sample_size and issues_analyzed from the single run.
            $withStaleEssMatch = [regex]::Match(
                $withStaleResult.Output, 'effective_sample_size:\s*([\d.]+)'
            )
            $withStaleIssuesMatch = [regex]::Match(
                $withStaleResult.Output, 'issues_analyzed:\s*(\d+)'
            )

            $withStaleResult.ExitCode | Should -Be 0 `
                -Because '-CalibrationFile with stale timestamps must not crash the script'
            $withStaleResult.Output | Should -Match 'data_source:\s*merged' `
                -Because 'the real matching PR must keep the run on the merged GitHub plus local calibration path'

            if ($withStaleEssMatch.Success -and $withStaleIssuesMatch.Success) {
                $withStaleEss = [double]$withStaleEssMatch.Groups[1].Value
                [int]$withStaleIssuesMatch.Groups[1].Value |
                    Should -Be ($script:CleanCalibrationBaselineIssuesAnalyzed + 1) `
                        -Because 'the matched local entry must add exactly one analyzed issue beyond the fetched clean-repo window baseline'
                $withStaleEss | Should -BeGreaterThan 0.0 `
                    -Because 'GitHub mergedAt must override the stale local created_at; otherwise effective_sample_size would round to 0.0'
            }
            else {
                $withStaleResult.Output | Should -Match 'effective_sample_size:\s*[1-9]' `
                    -Because 'GitHub mergedAt must produce a non-zero effective sample size for the real matched PR'
            }
        }
    }

    # ==================================================================
    # Context: express-lane injection
    # AST/source-code presence tests — no gh CLI needed.
    # Verifies that both injection paths (local-entries loop and v2 PR-body
    # findings loop) correctly auto-set judge_ruling = 'finding-sustained'
    # for express-lane findings that omit that field.
    # ==================================================================
    Context 'express-lane injection' -Tag 'no-gh' {

        BeforeAll {
            # Array of lines — enables per-line Select-String counts
            $script:ScriptLines = Get-Content -Path $script:LibFile
        }

        It 'local-entries path contains the express-lane injection guard' {
            # Verify the guard condition is present somewhere in the script
            ($script:ScriptLines | Select-String "express_lane.*'True'") | Should -Not -BeNullOrEmpty `
                -Because 'the local-entries loop must check express_lane eq True before injecting judge_ruling'
            # Verify the injected value is present
            ($script:ScriptLines | Select-String 'finding-sustained') | Should -Not -BeNullOrEmpty `
                -Because 'the guard must inject judge_ruling = finding-sustained for express-lane findings'
        }

        It 'both injection paths (local-entries and v2 PR-body) are present in the script' {
            ($script:ScriptLines | Select-String 'express_lane.*True').Count |
                Should -BeGreaterOrEqual 2 `
                    -Because 'both the local-entries loop (Change B) and v2 PR-body loop (Change C) must contain the express-lane guard'
            ($script:ScriptLines | Select-String 'finding-sustained').Count |
                Should -BeGreaterOrEqual 2 `
                    -Because 'both injection paths must set judge_ruling to finding-sustained'
        }

        It '$isSustained treats finding-sustained as a sustained ruling' {
            ($script:ScriptLines | Select-String 'isSustained.*finding-sustained|finding-sustained.*isSustained') |
                Should -Not -BeNullOrEmpty `
                    -Because '$isSustained must combine both sustained and finding-sustained so express-lane findings are counted correctly'
        }

        It "maps legacy 'documentation' category to 'documentation-audit' in accumulateFinding" -Tag 'no-gh' {
            ($script:ScriptLines | Select-String "category -eq 'documentation'") |
                Should -Not -BeNullOrEmpty `
                    -Because '$accumulateFinding must normalize documentation to documentation-audit like it normalizes simplicity to implementation-clarity'
            ($script:ScriptLines | Select-String "category = 'documentation-audit'") |
                Should -Not -BeNullOrEmpty `
                    -Because '$accumulateFinding must assign documentation-audit as the canonical category name'
        }
    }

    # ==================================================================
    # Context: prosecution_depth output
    # RED TESTS: aggregate-review-scores.ps1 does NOT yet emit a
    # prosecution_depth: section — every test below must fail initially.
    # ==================================================================
    Context 'prosecution_depth output' {

        BeforeAll {
            # Authoritative category list (mirrors $knownCategories in the script)
            $script:DepthCategories = @(
                'architecture', 'security', 'performance', 'pattern',
                'implementation-clarity', 'script-automation', 'documentation-audit'
            )

            # Query merged PRs without pipeline-metrics blocks for calibration entries.
            # These PRs exist in the merged list (not orphaned) but lack body metrics,
            # so the script falls back to calibration entries for their data.
            $allPrJson = & gh pr list --repo 'Grimblaz/copilot-orchestra' --state merged --limit 100 --json 'number,body' 2>$null
            $script:NonMetricsPrNumbers = if ($allPrJson) {
                @(($allPrJson | ConvertFrom-Json) |
                        Where-Object { $_.body -notmatch 'pipeline-metrics' } |
                        ForEach-Object { [int]$_.number })
            }
            else {
                @(9901)  # fallback if gh fails
            }

            # Query a public repo that has no pipeline-metrics in any PR body,
            # giving pure calibration-only data for isolation tests.
            $cleanPrJson = & gh pr list --repo 'github/docs' --state merged --limit 10 --json number 2>$null
            $script:CleanRepoPrNumbers = if ($cleanPrJson) {
                @(($cleanPrJson | ConvertFrom-Json) | ForEach-Object { [int]$_.number })
            }
            else {
                @(9901)  # fallback if gh fails
            }

            # ---------------------------------------------------------------
            # Helper: generate findings array for a single category with
            # specified sustained / defense-sustained counts.
            # ---------------------------------------------------------------
            $script:MakeCategoryFindings = {
                param([string]$Category, [int]$Sustained, [int]$DefenseSustained)
                $list = [System.Collections.Generic.List[object]]::new()
                for ($i = 1; $i -le $Sustained; $i++) {
                    $list.Add([ordered]@{
                            id           = "F-${Category}-s${i}"
                            category     = $Category
                            judge_ruling = 'finding-sustained'
                            severity     = 'medium'
                            points       = 5
                            review_stage = 'main'
                        })
                }
                for ($i = 1; $i -le $DefenseSustained; $i++) {
                    $list.Add([ordered]@{
                            id           = "F-${Category}-d${i}"
                            category     = $Category
                            judge_ruling = 'defense-sustained'
                            severity     = 'medium'
                            points       = 5
                            review_stage = 'main'
                        })
                }
                return , $list.ToArray()
            }

            # ---------------------------------------------------------------
            # Helper: build a calibration object with entries and optional
            # prosecution-depth overlay fields.
            # ---------------------------------------------------------------
            $script:BuildDepthCalibration = {
                param(
                    [object[]]$Findings,
                    [string]$Override = $null,
                    [object[]]$ReactivationEvents = $null,
                    [object]$DepthState = $null,
                    [int[]]$PrNumbers = @(9901)
                )
                $entries = @()
                foreach ($prNum in $PrNumbers) {
                    $entries += [ordered]@{
                        pr_number  = $prNum
                        created_at = '2026-03-01T10:00:00Z'
                        findings   = $Findings
                        summary    = [ordered]@{
                            prosecution_findings = $Findings.Count
                            pass_1_findings      = $Findings.Count
                            pass_2_findings      = 0
                            pass_3_findings      = 0
                            defense_disproved    = 0
                            judge_accepted       = $Findings.Count
                            judge_rejected       = 0
                            judge_deferred       = 0
                        }
                    }
                }
                $calib = [ordered]@{
                    calibration_version = 1
                    entries             = $entries
                }
                if (-not [string]::IsNullOrEmpty($Override)) {
                    $calib['prosecution_depth_override'] = $Override
                }
                if ($null -ne $ReactivationEvents) {
                    $calib['re_activation_events'] = $ReactivationEvents
                }
                if ($null -ne $DepthState) {
                    $calib['prosecution_depth_state'] = $DepthState
                }
                return $calib
            }
        }

        # ------ AST-based test (no-gh) ------

        It 'script help block no longer claims READ-ONLY' -Tag 'no-gh' {
            # RED: the .DESCRIPTION section currently contains "READ-ONLY".
            # Implementation will update it to reflect prosecution_depth_state writes.
            $content = Get-Content -Path $script:ScriptFile -Raw
            $content | Should -Not -cMatch 'READ-ONLY' `
                -Because 'script description must be updated to reflect prosecution_depth_state writes'
        }

        # ------ Execution tests (requires-gh) ------

        It 'emits prosecution_depth section in YAML output' -Tag 'requires-gh' {
            # RED: script does not yet emit prosecution_depth: in output.
            if (-not $script:GhAvailable) { Set-ItResult -Skipped -Because 'gh CLI not found' }

            $workDir = & $script:NewWorkDir
            $findings = @(
                [ordered]@{ id = 'F1'; category = 'architecture'; judge_ruling = 'finding-sustained'
                    severity = 'medium'; points = 5; review_stage = 'main'
                },
                [ordered]@{ id = 'F2'; category = 'security'; judge_ruling = 'defense-sustained'
                    severity = 'medium'; points = 5; review_stage = 'main'
                }
            )
            $calib = & $script:BuildDepthCalibration -Findings $findings
            $calibPath = Join-Path $workDir 'depth-calib.json'
            & $script:WriteCalibrationFile -Path $calibPath -Data $calib

            $result = & $script:InvokeAggregate `
                -ExtraArgs @('-CalibrationFile', $calibPath)

            $result.ExitCode | Should -Be 0
            $result.Output | Should -Match 'prosecution_depth:' `
                -Because 'prosecution_depth section must appear in YAML output when v2 findings data exists'
        }

        It 'emits all 7 known categories with recommendation, sustain_rate, effective_count, sufficient_data, re_activated' -Tag 'requires-gh' {
            # RED: prosecution_depth section does not exist yet; first assertion fails.
            if (-not $script:GhAvailable) { Set-ItResult -Skipped -Because 'gh CLI not found' }

            $workDir = & $script:NewWorkDir
            $findings = @(
                [ordered]@{ id = 'F1'; category = 'architecture'; judge_ruling = 'finding-sustained'
                    severity = 'medium'; points = 5; review_stage = 'main'
                }
            )
            $calib = & $script:BuildDepthCalibration -Findings $findings
            $calibPath = Join-Path $workDir 'depth-calib.json'
            & $script:WriteCalibrationFile -Path $calibPath -Data $calib

            $result = & $script:InvokeAggregate `
                -ExtraArgs @('-CalibrationFile', $calibPath)

            $result.ExitCode | Should -Be 0

            # Unique to prosecution_depth — fails in RED
            $result.Output | Should -Match 'prosecution_depth:' `
                -Because 'prosecution_depth section must be emitted before checking per-category fields'

            foreach ($cat in $script:DepthCategories) {
                $result.Output | Should -Match "(?s)prosecution_depth:.*?${cat}:" `
                    -Because "category '$cat' must appear under prosecution_depth"
            }
            $result.Output | Should -Match 'recommendation:' `
                -Because 'recommendation field must appear in prosecution_depth categories'
            $result.Output | Should -Match 're_activated:' `
                -Because 're_activated field must appear in prosecution_depth categories'
        }

        It 'reports recommendation skip when sustain_rate below 0.05 and effective_count at least 30' -Tag 'requires-gh' {
            # Fixture: architecture — 1 sustained + 34 defense-sustained per non-metrics PR
            # Calibration dominates real data → sustain_rate ≈ 0.029 (< 0.05)
            if (-not $script:GhAvailable) { Set-ItResult -Skipped -Because 'gh CLI not found' }

            $workDir = & $script:NewWorkDir
            $findings = & $script:MakeCategoryFindings 'architecture' 1 34
            $calib = & $script:BuildDepthCalibration -Findings $findings -PrNumbers $script:NonMetricsPrNumbers
            $calibPath = Join-Path $workDir 'skip-calib.json'
            & $script:WriteCalibrationFile -Path $calibPath -Data $calib

            $result = & $script:InvokeAggregate `
                -ExtraArgs @('-CalibrationFile', $calibPath)

            $result.ExitCode | Should -Be 0
            $result.Output | Should -Match '(?s)prosecution_depth:.*?architecture:\s+recommendation:\s*skip' `
                -Because 'sustain_rate < 0.05 with effective_count >= 30 must produce recommendation: skip'
        }

        It 'reports recommendation light when sustain_rate below 0.15 and effective_count at least 20' -Tag 'requires-gh' {
            # Fixture: security — 3 sustained + 22 defense-sustained per non-metrics PR
            # Calibration dominates real data → sustain_rate ≈ 0.12 (< 0.15, >= 0.05)
            if (-not $script:GhAvailable) { Set-ItResult -Skipped -Because 'gh CLI not found' }

            $workDir = & $script:NewWorkDir
            $findings = & $script:MakeCategoryFindings 'security' 3 22
            $calib = & $script:BuildDepthCalibration -Findings $findings -PrNumbers $script:NonMetricsPrNumbers
            $calibPath = Join-Path $workDir 'light-calib.json'
            & $script:WriteCalibrationFile -Path $calibPath -Data $calib

            $result = & $script:InvokeAggregate `
                -ExtraArgs @('-CalibrationFile', $calibPath)

            $result.ExitCode | Should -Be 0
            $result.Output | Should -Match '(?s)prosecution_depth:.*?security:\s+recommendation:\s*light' `
                -Because 'sustain_rate < 0.15 with effective_count >= 20 must produce recommendation: light'
        }

        It 'reports recommendation full when sustain_rate >= 0.15' -Tag 'requires-gh' {
            # Fixture: performance — 8 sustained + 12 defense-sustained per non-metrics PR
            # Calibration dominates real data → sustain_rate ≈ 0.40 (>= 0.15)
            if (-not $script:GhAvailable) { Set-ItResult -Skipped -Because 'gh CLI not found' }

            $workDir = & $script:NewWorkDir
            $findings = & $script:MakeCategoryFindings 'performance' 8 12
            $calib = & $script:BuildDepthCalibration -Findings $findings -PrNumbers $script:NonMetricsPrNumbers
            $calibPath = Join-Path $workDir 'full-calib.json'
            & $script:WriteCalibrationFile -Path $calibPath -Data $calib

            $result = & $script:InvokeAggregate `
                -ExtraArgs @('-CalibrationFile', $calibPath)

            $result.ExitCode | Should -Be 0
            $result.Output | Should -Match '(?s)prosecution_depth:.*?performance:\s+recommendation:\s*full' `
                -Because 'sustain_rate >= 0.15 must produce recommendation: full'
        }

        It 'reports recommendation full with sufficient_data false when effective_count < 20' -Tag 'requires-gh' {
            # Fixture: one implementation-clarity finding on a clean github/docs PR.
            # github/docs latest-10 PRs do not use pipeline-metrics, so this category's
            # effective_count is driven only by the local calibration entry and remains
            # well below the 20-point prosecution-depth threshold.
            if (-not $script:GhAvailable) { Set-ItResult -Skipped -Because 'gh CLI not found'; return }
            if (-not (& $script:AssertCleanCalibrationWindowStable)) {
                return
            }

            $workDir = & $script:NewWorkDir
            $findings = & $script:MakeCategoryFindings 'implementation-clarity' 1 0
            $calib = & $script:BuildDepthCalibration `
                -Findings $findings `
                -PrNumbers $script:CleanRepoPrNumbers
            $calibPath = Join-Path $workDir 'insuff-calib.json'
            & $script:WriteCalibrationFile -Path $calibPath -Data $calib

            $result = & $script:InvokeAggregate `
                -ExtraArgs @(
                '-Repo',
                $script:CleanCalibrationRepo,
                '-Limit',
                $script:CleanCalibrationLimit,
                '-CalibrationFile',
                $calibPath
            )

            $result.ExitCode | Should -Be 0

            $categoryMatch = [regex]::Match(
                $result.Output,
                '(?ms)^    implementation-clarity:\r?\n(?:      .*\r?\n){0,5}'
            )
            $categoryMatch.Success | Should -BeTrue `
                -Because 'implementation-clarity must appear in prosecution_depth output'

            $categoryBlock = $categoryMatch.Value
            $effectiveCountMatch = [regex]::Match($categoryBlock, 'effective_count:\s*([0-9]+(?:\.[0-9]+)?)')
            $effectiveCountMatch.Success | Should -BeTrue `
                -Because 'implementation-clarity prosecution_depth output must include effective_count'
            $effectiveCount = [double]$effectiveCountMatch.Groups[1].Value
            $effectiveCount | Should -BeGreaterThan 0 `
                -Because 'the controlled implementation-clarity fixture must contribute non-zero effective_count so the insufficient-data assertion cannot pass vacuously'
            $effectiveCount | Should -BeLessThan 20 `
                -Because 'the insufficient-data guardrail is defined by effective_count < 20'
            $categoryBlock | Should -Match 'recommendation:\s*full' `
                -Because 'insufficient data (effective_count < 20) must default to recommendation: full'
            $categoryBlock | Should -Match 'sufficient_data:\s*false' `
                -Because 'effective_count < 20 must set sufficient_data: false'
        }

        It 'reports recommendation full with effective_count 0.0 for categories absent from data' -Tag 'requires-gh' {
            # Uses github/docs (no pipeline-metrics) for pure calibration isolation.
            # Architecture findings only → all other categories have effective_count 0.0.
            if (-not $script:GhAvailable) { Set-ItResult -Skipped -Because 'gh CLI not found' }

            $workDir = & $script:NewWorkDir
            $findings = @(
                [ordered]@{ id = 'F1'; category = 'architecture'; judge_ruling = 'finding-sustained'
                    severity = 'medium'; points = 5; review_stage = 'main'
                }
            )
            $calib = & $script:BuildDepthCalibration -Findings $findings -PrNumbers $script:CleanRepoPrNumbers
            $calibPath = Join-Path $workDir 'zero-calib.json'
            & $script:WriteCalibrationFile -Path $calibPath -Data $calib

            $result = & $script:InvokeAggregate `
                -ExtraArgs @('-CalibrationFile', $calibPath, '-Repo', 'github/docs', '-Limit', '10')

            $result.ExitCode | Should -Be 0
            $result.Output | Should -Match '(?s)prosecution_depth:.*?documentation-audit:\s+recommendation:\s*full' `
                -Because 'categories absent from finding data must default to recommendation: full'
            $result.Output | Should -Match '(?s)prosecution_depth:.*?documentation-audit:.*?effective_count:\s*0\.0' `
                -Because 'categories with no findings must report effective_count: 0.0'
        }

        It 'emits override_active true and forces all categories to full when prosecution_depth_override is set' -Tag 'requires-gh' {
            # RED: prosecution_depth section does not exist yet.
            if (-not $script:GhAvailable) { Set-ItResult -Skipped -Because 'gh CLI not found' }

            $workDir = & $script:NewWorkDir
            $findings = @(
                [ordered]@{ id = 'F1'; category = 'architecture'; judge_ruling = 'finding-sustained'
                    severity = 'medium'; points = 5; review_stage = 'main'
                }
            )
            $calib = & $script:BuildDepthCalibration -Findings $findings -Override 'full'
            $calibPath = Join-Path $workDir 'override-calib.json'
            & $script:WriteCalibrationFile -Path $calibPath -Data $calib

            $result = & $script:InvokeAggregate `
                -ExtraArgs @('-CalibrationFile', $calibPath)

            $result.ExitCode | Should -Be 0
            $result.Output | Should -Match '(?s)prosecution_depth:\s+override_active:\s*true' `
                -Because 'prosecution_depth_override in calibration file must set override_active: true'
            foreach ($cat in $script:DepthCategories) {
                $result.Output | Should -Match "(?s)prosecution_depth:.*?${cat}:\s+recommendation:\s*full" `
                    -Because "override must force category '$cat' to recommendation: full"
            }
        }

        It 'reports recommendation full and re_activated true when a re-activation event is active' -Tag 'requires-gh' {
            # RED: prosecution_depth section does not exist yet.
            # Fixture: re-activation event for 'pattern' with expires_at_pr=999999
            if (-not $script:GhAvailable) { Set-ItResult -Skipped -Because 'gh CLI not found' }

            $workDir = & $script:NewWorkDir
            $findings = @(
                [ordered]@{ id = 'F1'; category = 'architecture'; judge_ruling = 'finding-sustained'
                    severity = 'medium'; points = 5; review_stage = 'main'
                }
            )
            $reactivationEvents = @(
                [ordered]@{
                    category        = 'pattern'
                    triggered_at_pr = 100
                    expires_at_pr   = 999999
                    trigger_source  = 'manual_override'
                    created_at      = '2026-03-01T10:00:00Z'
                }
            )
            $calib = & $script:BuildDepthCalibration -Findings $findings `
                -ReactivationEvents $reactivationEvents
            $calibPath = Join-Path $workDir 'reactivation-calib.json'
            & $script:WriteCalibrationFile -Path $calibPath -Data $calib

            $result = & $script:InvokeAggregate `
                -ExtraArgs @('-CalibrationFile', $calibPath)

            $result.ExitCode | Should -Be 0
            $result.Output | Should -Match '(?s)prosecution_depth:.*?pattern:\s+recommendation:\s*full' `
                -Because 'active re-activation event must force recommendation: full'
            $result.Output | Should -Match '(?s)prosecution_depth:.*?pattern:.*?re_activated:\s*true' `
                -Because 'active re-activation event must set re_activated: true'
        }

        It 'applies time-decay when skip_first_observed_at exceeds 90 days' -Tag 'requires-gh' {
            # RED: prosecution_depth section does not exist yet.
            # Fixture: architecture skip_first_observed_at is 100 days ago (> 90-day default)
            if (-not $script:GhAvailable) { Set-ItResult -Skipped -Because 'gh CLI not found' }

            $workDir = & $script:NewWorkDir
            $staleDate = (Get-Date).AddDays(-100).ToString('o')
            $findings = @(
                [ordered]@{ id = 'F1'; category = 'architecture'; judge_ruling = 'finding-sustained'
                    severity = 'medium'; points = 5; review_stage = 'main'
                }
            )
            $depthState = [ordered]@{
                architecture = [ordered]@{
                    skip_first_observed_at = $staleDate
                }
            }
            $calib = & $script:BuildDepthCalibration -Findings $findings -DepthState $depthState
            $calibPath = Join-Path $workDir 'timedecay-calib.json'
            & $script:WriteCalibrationFile -Path $calibPath -Data $calib

            $result = & $script:InvokeAggregate `
                -ExtraArgs @('-CalibrationFile', $calibPath)

            $result.ExitCode | Should -Be 0
            $result.Output | Should -Match '(?s)prosecution_depth:.*?architecture:\s+recommendation:\s*light' `
                -Because 'skip_first_observed_at > 90 days must decay from skip to light'
            $result.Output | Should -Match '(?s)prosecution_depth:.*?architecture:.*?re_activated:\s*true' `
                -Because 'time-decay re-activation must set re_activated: true'
        }

        It 'priority chain: override > re-activation > time-decay > insufficient-data > threshold' -Tag 'requires-gh' {
            # RED: prosecution_depth section does not exist yet.
            # Fixture: override=full AND re-activation event AND time-decay state
            # Override must win: all categories forced to full, override_active: true
            if (-not $script:GhAvailable) { Set-ItResult -Skipped -Because 'gh CLI not found' }

            $workDir = & $script:NewWorkDir
            $findings = @(
                [ordered]@{ id = 'F1'; category = 'architecture'; judge_ruling = 'finding-sustained'
                    severity = 'medium'; points = 5; review_stage = 'main'
                }
            )
            $reactivationEvents = @(
                [ordered]@{
                    category        = 'security'
                    triggered_at_pr = 100
                    expires_at_pr   = 999999
                    trigger_source  = 'manual_override'
                    created_at      = '2026-03-01T10:00:00Z'
                }
            )
            $staleDate = (Get-Date).AddDays(-100).ToString('o')
            $depthState = [ordered]@{
                performance = [ordered]@{
                    skip_first_observed_at = $staleDate
                }
            }
            $calib = & $script:BuildDepthCalibration -Findings $findings `
                -Override 'full' -ReactivationEvents $reactivationEvents -DepthState $depthState
            $calibPath = Join-Path $workDir 'priority-calib.json'
            & $script:WriteCalibrationFile -Path $calibPath -Data $calib

            $result = & $script:InvokeAggregate `
                -ExtraArgs @('-CalibrationFile', $calibPath)

            $result.ExitCode | Should -Be 0
            # Override wins: override_active must be true
            $result.Output | Should -Match '(?s)prosecution_depth:\s+override_active:\s*true' `
                -Because 'override takes highest priority — override_active must be true'
            # All categories forced to full by override
            foreach ($cat in $script:DepthCategories) {
                $result.Output | Should -Match "(?s)prosecution_depth:.*?${cat}:\s+recommendation:\s*full" `
                    -Because "override must force '$cat' to full regardless of re-activation or time-decay signals"
            }
        }

        # ==================================================================
        # Context: write-back persistence
        # Verifies that the calibration file is updated on disk after an
        # aggregate run that modifies prosecution_depth_state or prunes
        # expired re-activation events.
        # ==================================================================
        Context 'write-back persistence' {

            It 'write-back: entering skip writes skip_first_observed_at to calibration file' -Tag 'requires-gh' {
                if (-not $script:GhAvailable) { Set-ItResult -Skipped -Because 'gh CLI not found' }

                # ARRANGE: calibration where pattern enters skip
                # (1 sustained + 34 defense-sustained -> sustain_rate ~= 0.029 < 0.05, effective_count >= 30)
                $workDir = & $script:NewWorkDir
                $findings = & $script:MakeCategoryFindings 'pattern' 1 34
                $calib = & $script:BuildDepthCalibration -Findings $findings -PrNumbers $script:NonMetricsPrNumbers
                $calibPath = Join-Path $workDir 'skip-writeback.json'
                & $script:WriteCalibrationFile -Path $calibPath -Data $calib

                # ACT
                $result = & $script:InvokeAggregate `
                    -ExtraArgs @('-CalibrationFile', $calibPath)

                # ASSERT: fixture produced skip recommendation (confirms write-back path was entered)
                $result.ExitCode | Should -Be 0
                $result.Output | Should -Match '(?s)prosecution_depth:.*?pattern:\s+recommendation:\s*skip' `
                    -Because 'fixture must produce skip recommendation so write-back path is triggered'

                # ASSERT: calibration file updated with skip_first_observed_at
                $readBack = Get-Content $calibPath -Raw | ConvertFrom-Json -AsHashtable
                $readBack | Should -Not -BeNullOrEmpty `
                    -Because 'calibration file must still be readable after run'
                $readBack['prosecution_depth_state'] | Should -Not -BeNullOrEmpty `
                    -Because 'prosecution_depth_state must be written to calibration file when a category enters skip'
                $readBack['prosecution_depth_state']['pattern'] | Should -Not -BeNullOrEmpty `
                    -Because 'pattern state must be persisted when the category enters skip'
                $skipDate = $readBack['prosecution_depth_state']['pattern']['skip_first_observed_at']
                $skipDate | Should -Not -BeNullOrEmpty `
                    -Because 'skip_first_observed_at must be written when a category first enters skip'
                { [datetime]$skipDate } | Should -Not -Throw `
                    -Because 'skip_first_observed_at must be a valid datetime string'
            }

            It 'write-back: transitioning from skip to full clears skip_first_observed_at from calibration file' -Tag 'requires-gh' {
                if (-not $script:GhAvailable) { Set-ItResult -Skipped -Because 'gh CLI not found' }

                # ARRANGE: pre-seeded skip state for pattern, but findings now show high sustain_rate
                # (8 sustained + 12 defense-sustained -> sustain_rate = 0.4 >= 0.15 -> full)
                $workDir = & $script:NewWorkDir
                $findings = & $script:MakeCategoryFindings 'pattern' 8 12
                $depthState = [ordered]@{
                    pattern = [ordered]@{
                        skip_first_observed_at = '2026-02-01T00:00:00Z'
                    }
                }
                $calib = & $script:BuildDepthCalibration -Findings $findings `
                    -PrNumbers $script:NonMetricsPrNumbers -DepthState $depthState
                $calibPath = Join-Path $workDir 'leave-skip-writeback.json'
                & $script:WriteCalibrationFile -Path $calibPath -Data $calib

                # ACT
                $result = & $script:InvokeAggregate `
                    -ExtraArgs @('-CalibrationFile', $calibPath)

                # ASSERT: pattern recommendation is now full (exited skip)
                $result.ExitCode | Should -Be 0
                $result.Output | Should -Match '(?s)prosecution_depth:.*?pattern:\s+recommendation:\s*full' `
                    -Because 'sustain_rate >= 0.15 must produce recommendation: full (pattern exited skip)'

                # ASSERT: skip_first_observed_at cleared from calibration file
                $readBack = Get-Content $calibPath -Raw | ConvertFrom-Json -AsHashtable
                $readBack | Should -Not -BeNullOrEmpty `
                    -Because 'calibration file must still be readable after run'
                $depthStateAfter = $readBack['prosecution_depth_state']
                if ($null -ne $depthStateAfter -and $null -ne $depthStateAfter['pattern']) {
                    $depthStateAfter['pattern']['skip_first_observed_at'] | Should -BeNullOrEmpty `
                        -Because 'skip_first_observed_at must be cleared when category exits skip'
                }
                # If prosecution_depth_state has no pattern key at all, the contract is also satisfied
            }

            It 'write-back: expired re-activation events are pruned on write-back' -Tag 'requires-gh' {
                if (-not $script:GhAvailable) { Set-ItResult -Skipped -Because 'gh CLI not found' }

                # ARRANGE: two re-activation events (one active, one expired) plus a skip-entering
                # category fixture so that $depthStateChanged is set and write-back runs.
                # pattern enters skip -> $depthStateChanged = $true -> write-back triggers event pruning.
                $workDir = & $script:NewWorkDir
                $findings = & $script:MakeCategoryFindings 'pattern' 1 34  # pattern -> skip
                $reactivationEvents = @(
                    [ordered]@{
                        category        = 'architecture'
                        triggered_at_pr = 90
                        expires_at_pr   = 999999  # far future — stays active
                        trigger_source  = 'manual_override'
                        created_at      = '2026-03-01T10:00:00Z'
                    },
                    [ordered]@{
                        category        = 'security'
                        triggered_at_pr = 1
                        expires_at_pr   = 2       # PR 2 is already merged — expired
                        trigger_source  = 'manual_override'
                        created_at      = '2020-01-01T00:00:00Z'
                    }
                )
                $calib = & $script:BuildDepthCalibration -Findings $findings `
                    -PrNumbers $script:NonMetricsPrNumbers -ReactivationEvents $reactivationEvents
                $calibPath = Join-Path $workDir 'prune-events-writeback.json'
                & $script:WriteCalibrationFile -Path $calibPath -Data $calib

                # ACT
                $result = & $script:InvokeAggregate `
                    -ExtraArgs @('-CalibrationFile', $calibPath)

                # ASSERT: script succeeded
                $result.ExitCode | Should -Be 0

                # ASSERT: calibration file re_activation_events contains only the active event
                $readBack = Get-Content $calibPath -Raw | ConvertFrom-Json -AsHashtable
                $eventsAfter = $readBack['re_activation_events']
                $eventsAfter | Should -Not -BeNullOrEmpty `
                    -Because 'the active re-activation event must survive pruning'
                $eventsAfter.Count | Should -Be 1 `
                    -Because 'the expired event (expires_at_pr=2) must be pruned; only the active event survives'
                [int]$eventsAfter[0]['expires_at_pr'] | Should -Be 999999 `
                    -Because 'the surviving event must be the active one with expires_at_pr=999999'
            }

            It 'writes time-decay synthetic re-activation event to calibration file' -Tag 'requires-gh' {
                if (-not $script:GhAvailable) { Set-ItResult -Skipped -Because 'gh CLI not found' }

                # ARRANGE: architecture has a stale skip_first_observed_at (100 days ago) and
                # skip-threshold findings (sustain_rate ~0.029 < 0.05, dominated by NonMetricsPRs).
                # Time-decay must fire, promote the recommendation to light, and persist a
                # synthetic re-activation event to the calibration file on disk.
                $workDir = & $script:NewWorkDir
                $staleDate = (Get-Date).AddDays(-100).ToString('o')
                $findings = & $script:MakeCategoryFindings 'architecture' 1 34
                $depthState = [ordered]@{
                    architecture = [ordered]@{
                        skip_first_observed_at = $staleDate
                    }
                }
                $calib = & $script:BuildDepthCalibration -Findings $findings `
                    -PrNumbers $script:NonMetricsPrNumbers -DepthState $depthState
                $calibPath = Join-Path $workDir 'timedecay-writeback.json'
                & $script:WriteCalibrationFile -Path $calibPath -Data $calib

                # ACT
                $result = & $script:InvokeAggregate `
                    -ExtraArgs @('-CalibrationFile', $calibPath)

                # ASSERT: time-decay promoted architecture to light (confirming the write-back path was entered)
                $result.ExitCode | Should -Be 0
                $result.Output | Should -Match '(?s)prosecution_depth:.*?architecture:\s+recommendation:\s*light' `
                    -Because 'stale skip_first_observed_at must time-decay architecture from skip to light'

                # ASSERT: synthetic re-activation event persisted to calibration file
                $readBack = Get-Content $calibPath -Raw | ConvertFrom-Json -AsHashtable
                $readBack | Should -Not -BeNullOrEmpty `
                    -Because 'calibration file must still be readable after run'
                $eventsAfter = $readBack['re_activation_events']
                $eventsAfter | Should -Not -BeNullOrEmpty `
                    -Because 'time-decay must persist a synthetic re-activation event to the calibration file'
                $eventsAfter.Count | Should -Be 1 `
                    -Because 'exactly one synthetic event must be written for the architecture time-decay trigger'
                $eventsAfter[0]['category'] | Should -Be 'architecture' `
                    -Because 'the synthetic event must record the category that triggered time-decay'
                $eventsAfter[0]['trigger_source'] | Should -Be 'time_decay' `
                    -Because 'trigger_source must be time_decay for a time-decay synthetic event'
                [int]$eventsAfter[0]['triggered_at_pr'] | Should -BeGreaterThan 0 `
                    -Because 'triggered_at_pr must equal the max merged PR number (a positive integer)'
                [int]$eventsAfter[0]['expires_at_pr'] | Should -Be ([int]$eventsAfter[0]['triggered_at_pr'] + 50) `
                    -Because 'expires_at_pr must be triggered_at_pr + 50 as computed by the time-decay logic'
            }
        }
    }

    # ==================================================================
    # systemic_patterns: section — every test below must fail initially.
    # ==================================================================
    Context 'systemic_patterns output' {

        BeforeAll {
            # $script:NonMetricsPrNumbers is populated by the prosecution_depth BeforeAll,
            # which runs before this context (contexts execute in document order).
            # Take up to 2 real non-metrics PR numbers for multi-PR fixtures.
            # Guard: ensure NonMetricsPrNumbers is available when this context runs in isolation
            if (-not $script:NonMetricsPrNumbers) {
                $script:NonMetricsPrNumbers = @(9901, 9902)
            }
            $firstTwo = @($script:NonMetricsPrNumbers | Select-Object -First 2)
            $script:SystemicPr1 = if ($firstTwo.Count -ge 1) { [int]$firstTwo[0] } else { 9901 }
            $script:SystemicPr2 = if ($firstTwo.Count -ge 2) { [int]$firstTwo[1] } else { 9902 }

            # ---------------------------------------------------------------
            # Helper: build a calibration object for systemic-pattern tests.
            # Each PR in $PrNumbers receives the same $Findings array.
            # Optional $ProposalsEmitted adds a proposals_emitted root key.
            # ---------------------------------------------------------------
            $script:BuildSystemicCalibration = {
                param(
                    [object[]]$Findings,
                    [int[]]$PrNumbers = @(9901),
                    [object[]]$ProposalsEmitted = @()
                )
                $entries = @()
                foreach ($prNum in $PrNumbers) {
                    $entries += [ordered]@{
                        pr_number  = $prNum
                        created_at = '2026-03-01T10:00:00Z'
                        findings   = $Findings
                        summary    = [ordered]@{
                            prosecution_findings = $Findings.Count
                            pass_1_findings      = $Findings.Count
                            pass_2_findings      = 0
                            pass_3_findings      = 0
                            defense_disproved    = 0
                            judge_accepted       = $Findings.Count
                            judge_rejected       = 0
                            judge_deferred       = 0
                        }
                    }
                }
                $calib = [ordered]@{
                    calibration_version = 1
                    entries             = $entries
                }
                if ($ProposalsEmitted.Count -gt 0) {
                    $calib['proposals_emitted'] = $ProposalsEmitted
                }
                return $calib
            }
        }

        It 'emits systemic_patterns section when v2 findings with systemic_fix_type exist' -Tag 'requires-gh' {
            if (-not $script:GhAvailable) { Set-ItResult -Skipped -Because 'gh CLI not found' }

            $workDir = & $script:NewWorkDir
            # One instruction:security finding per PR, 2 distinct PRs → threshold met
            $finding = [ordered]@{
                id                = 'F1'
                category          = 'security'
                judge_ruling      = 'finding-sustained'
                severity          = 'medium'
                points            = 5
                review_stage      = 'main'
                systemic_fix_type = 'instruction'
            }
            $calib = & $script:BuildSystemicCalibration `
                -Findings @($finding) `
                -PrNumbers @($script:SystemicPr1, $script:SystemicPr2)
            $calibPath = Join-Path $workDir 'systemic-basic.json'
            & $script:WriteCalibrationFile -Path $calibPath -Data $calib

            $result = & $script:InvokeAggregate `
                -ExtraArgs @('-CalibrationFile', $calibPath)

            $result.ExitCode | Should -Be 0
            $result.Output | Should -Match 'systemic_patterns:' `
                -Because 'systemic_patterns section must appear when v2 findings with systemic_fix_type exist'
            $result.Output | Should -Match 'instruction:' `
                -Because 'instruction fix type must appear under systemic_patterns'
            $result.Output | Should -Match 'security:' `
                -Because 'security category must appear under the instruction fix type'
            $result.Output | Should -Match 'meets_threshold:\s*true' `
                -Because '2 sustained findings across 2 distinct PRs must meet the threshold'
            $result.Output | Should -Match 'sustained_count:\s*2' `
                -Because 'sustained_count must reflect total sustained findings across all PR entries'
            $result.Output | Should -Match 'distinct_prs:\s*2' `
                -Because 'distinct_prs must count unique PR numbers contributing to the pattern'
        }

        It 'threshold logic: single PR does not meet threshold' -Tag 'requires-gh' {
            if (-not $script:GhAvailable) { Set-ItResult -Skipped -Because 'gh CLI not found' }

            $workDir = & $script:NewWorkDir
            # Two instruction:security findings in the SAME PR → distinct_prs = 1
            $findings = @(
                [ordered]@{ id = 'F1'; category = 'security'; judge_ruling = 'finding-sustained'
                    severity = 'medium'; points = 5; review_stage = 'main'
                    systemic_fix_type = 'instruction'
                },
                [ordered]@{ id = 'F2'; category = 'security'; judge_ruling = 'finding-sustained'
                    severity = 'medium'; points = 5; review_stage = 'main'
                    systemic_fix_type = 'instruction'
                }
            )
            $calib = & $script:BuildSystemicCalibration `
                -Findings $findings `
                -PrNumbers @($script:SystemicPr1)
            $calibPath = Join-Path $workDir 'systemic-threshold.json'
            & $script:WriteCalibrationFile -Path $calibPath -Data $calib

            $result = & $script:InvokeAggregate `
                -ExtraArgs @('-CalibrationFile', $calibPath)

            $result.ExitCode | Should -Be 0
            $result.Output | Should -Match 'systemic_patterns:' `
                -Because 'systemic_patterns section must appear even when threshold not met (section always emitted when data exists)'
            $result.Output | Should -Match 'meets_threshold:\s*false' `
                -Because 'only 1 distinct PR must produce meets_threshold: false'
        }

        It 'excludes category n/a findings from systemic patterns' -Tag 'requires-gh' {
            # Both valid (security) and n/a findings are present; section must appear
            # for the valid finding but must not contain an n/a key.
            if (-not $script:GhAvailable) { Set-ItResult -Skipped -Because 'gh CLI not found' }

            $workDir = & $script:NewWorkDir
            $findings = @(
                [ordered]@{ id = 'F1'; category = 'security'; judge_ruling = 'finding-sustained'
                    severity = 'medium'; points = 5; review_stage = 'main'
                    systemic_fix_type = 'instruction'
                },
                [ordered]@{ id = 'F2'; category = 'n/a'; judge_ruling = 'finding-sustained'
                    severity = 'medium'; points = 5; review_stage = 'main'
                    systemic_fix_type = 'instruction'
                }
            )
            $calib = & $script:BuildSystemicCalibration `
                -Findings $findings `
                -PrNumbers @($script:SystemicPr1, $script:SystemicPr2)
            $calibPath = Join-Path $workDir 'systemic-noa.json'
            & $script:WriteCalibrationFile -Path $calibPath -Data $calib

            $result = & $script:InvokeAggregate `
                -ExtraArgs @('-CalibrationFile', $calibPath)

            $result.ExitCode | Should -Be 0
            $result.Output | Should -Match 'systemic_patterns:' `
                -Because 'systemic_patterns section must appear when valid (non-n/a) findings exist'
            $result.Output | Should -Not -Match '(?s)systemic_patterns:.*?n/a:' `
                -Because 'n/a category must be excluded from systemic_patterns'
        }

        It 'excludes unknown categories from systemic patterns' -Tag 'requires-gh' {
            # Both valid (security) and unknown findings are present; section must
            # appear for the valid finding but must not contain an unknown category key.
            if (-not $script:GhAvailable) { Set-ItResult -Skipped -Because 'gh CLI not found'; return }

            $workDir = & $script:NewWorkDir
            $findings = @(
                [ordered]@{ id = 'F1'; category = 'security'; judge_ruling = 'finding-sustained'
                    severity = 'medium'; points = 5; review_stage = 'main'
                    systemic_fix_type = 'instruction'
                },
                [ordered]@{ id = 'F2'; category = 'unknown-cat'; judge_ruling = 'finding-sustained'
                    severity = 'medium'; points = 5; review_stage = 'main'
                    systemic_fix_type = 'instruction'
                }
            )
            $calib = & $script:BuildSystemicCalibration `
                -Findings $findings `
                -PrNumbers @($script:SystemicPr1, $script:SystemicPr2)
            $calibPath = Join-Path $workDir 'systemic-unknown-category.json'
            & $script:WriteCalibrationFile -Path $calibPath -Data $calib

            $result = & $script:InvokeAggregate `
                -ExtraArgs @('-CalibrationFile', $calibPath)

            $result.ExitCode | Should -Be 0
            $result.Output | Should -Match 'systemic_patterns:' `
                -Because 'systemic_patterns section must appear when valid known-category findings exist'
            $result.Output | Should -Match '(?ms)^  systemic_patterns:\r?\n(?:(?!^  \S).*\r?\n)*?      security:' `
                -Because 'known categories must still appear inside the systemic_patterns block for the same fixture'
            $result.Output | Should -Not -Match '(?ms)^  systemic_patterns:\r?\n(?:(?!^  \S).*\r?\n)*?      unknown-cat:' `
                -Because 'unknown categories must be excluded from systemic_patterns'
        }

        It 'maps legacy simplicity findings to implementation-clarity without emitting a simplicity key' -Tag 'requires-gh' {
            if (-not $script:GhAvailable) { Set-ItResult -Skipped -Because 'gh CLI not found'; return }

            $workDir = & $script:NewWorkDir
            $findings = @(
                [ordered]@{ id = 'F1'; category = 'simplicity'; judge_ruling = 'finding-sustained'
                    severity = 'medium'; points = 5; review_stage = 'main'
                    systemic_fix_type = 'instruction'
                }
            )
            $calib = & $script:BuildSystemicCalibration `
                -Findings $findings `
                -PrNumbers @($script:SystemicPr1, $script:SystemicPr2)
            $calibPath = Join-Path $workDir 'systemic-simplicity-alias.json'
            & $script:WriteCalibrationFile -Path $calibPath -Data $calib

            $result = & $script:InvokeAggregate `
                -ExtraArgs @('-CalibrationFile', $calibPath)

            $result.ExitCode | Should -Be 0
            $result.Output | Should -Match '(?ms)^  systemic_patterns:\r?\n(?:(?!^  \S).*\r?\n)*?      implementation-clarity:' `
                -Because 'legacy simplicity findings must contribute under implementation-clarity in systemic_patterns output'
            $result.Output | Should -Not -Match '(?ms)^  systemic_patterns:\r?\n(?:(?!^  \S).*\r?\n)*?      simplicity:' `
                -Because 'systemic_patterns must not emit a legacy simplicity key after alias normalization'
            $result.Output | Should -Not -Match '(?ms)^  prosecution_depth:\r?\n(?:(?!^  \S).*\r?\n)*?    simplicity:' `
                -Because 'prosecution_depth must not emit a legacy simplicity key after alias normalization'
        }
        It 'omits systemic_patterns section when all systemic_fix_type values are none' -Tag 'requires-gh' {
            # Boundary/backward-compat test: no systemic_patterns section when no findings
            # have a non-none systemic_fix_type. Passes in red state (section not yet
            # emitted) and continues passing after correct implementation.
            if (-not $script:GhAvailable) { Set-ItResult -Skipped -Because 'gh CLI not found' }

            $workDir = & $script:NewWorkDir
            $findings = @(
                [ordered]@{ id = 'F1'; category = 'security'; judge_ruling = 'finding-sustained'
                    severity = 'medium'; points = 5; review_stage = 'main'
                    systemic_fix_type = 'none'
                },
                [ordered]@{ id = 'F2'; category = 'architecture'; judge_ruling = 'finding-sustained'
                    severity = 'medium'; points = 5; review_stage = 'main'
                }
            )
            $calib = & $script:BuildSystemicCalibration `
                -Findings $findings `
                -PrNumbers @($script:SystemicPr1, $script:SystemicPr2)
            $calibPath = Join-Path $workDir 'systemic-none.json'
            & $script:WriteCalibrationFile -Path $calibPath -Data $calib

            $result = & $script:InvokeAggregate `
                -ExtraArgs @('-CalibrationFile', $calibPath)

            $result.ExitCode | Should -Be 0
            $result.Output | Should -Not -Match 'systemic_patterns:' `
                -Because 'systemic_patterns section must be omitted when all systemic_fix_type values are none or absent'
            $result.Output | Should -Match 'kaizen_metric:' `
                -Because 'kaizen_metric section must appear even when systemic_patterns is omitted (emitted unconditionally when v2IssuesAnalyzed > 0)'
        }

        It 'includes evidence pr and finding id pairs in output' -Tag 'requires-gh' {
            if (-not $script:GhAvailable) { Set-ItResult -Skipped -Because 'gh CLI not found' }

            $workDir = & $script:NewWorkDir
            # Two skill:pattern findings, same finding ids per PR → evidence carries pr + id
            $findings = @(
                [ordered]@{ id = 'F1'; category = 'pattern'; judge_ruling = 'finding-sustained'
                    severity = 'medium'; points = 5; review_stage = 'main'
                    systemic_fix_type = 'skill'
                },
                [ordered]@{ id = 'F2'; category = 'pattern'; judge_ruling = 'finding-sustained'
                    severity = 'medium'; points = 5; review_stage = 'main'
                    systemic_fix_type = 'skill'
                }
            )
            $calib = & $script:BuildSystemicCalibration `
                -Findings $findings `
                -PrNumbers @($script:SystemicPr1, $script:SystemicPr2)
            $calibPath = Join-Path $workDir 'systemic-evidence.json'
            & $script:WriteCalibrationFile -Path $calibPath -Data $calib

            $result = & $script:InvokeAggregate `
                -ExtraArgs @('-CalibrationFile', $calibPath)

            $result.ExitCode | Should -Be 0
            $result.Output | Should -Match 'systemic_patterns:' `
                -Because 'systemic_patterns section must appear before evidence fields can be checked'
            $result.Output | Should -Match 'pr:\s*\d+' `
                -Because 'evidence entries must include the contributing pr number'
            $result.Output | Should -Match 'finding:\s*F[12]' `
                -Because 'evidence entries must include the contributing finding id'
        }

        It 'emits all 4 known fix types even when empty' -Tag 'requires-gh' {
            if (-not $script:GhAvailable) { Set-ItResult -Skipped -Because 'gh CLI not found' }

            $workDir = & $script:NewWorkDir
            # Only instruction:security findings; skill/agent-prompt/plan-template must
            # appear as empty sections regardless.
            $finding = [ordered]@{
                id                = 'F1'
                category          = 'security'
                judge_ruling      = 'finding-sustained'
                severity          = 'medium'
                points            = 5
                review_stage      = 'main'
                systemic_fix_type = 'instruction'
            }
            $calib = & $script:BuildSystemicCalibration `
                -Findings @($finding) `
                -PrNumbers @($script:SystemicPr1, $script:SystemicPr2)
            $calibPath = Join-Path $workDir 'systemic-alltypes.json'
            & $script:WriteCalibrationFile -Path $calibPath -Data $calib

            $result = & $script:InvokeAggregate `
                -ExtraArgs @('-CalibrationFile', $calibPath)

            $result.ExitCode | Should -Be 0
            $result.Output | Should -Match 'systemic_patterns:' `
                -Because 'systemic_patterns section must appear before checking all 4 fix types'
            $result.Output | Should -Match 'skill:' `
                -Because 'skill fix type must appear in systemic_patterns even when no findings exist for it'
            $result.Output | Should -Match 'agent-prompt:' `
                -Because 'agent-prompt fix type must appear in systemic_patterns even when no findings exist for it'
            $result.Output | Should -Match 'plan-template:' `
                -Because 'plan-template fix type must appear in systemic_patterns even when no findings exist for it'
        }

        It 'previously_proposed is false when pattern not in proposals_emitted' -Tag 'requires-gh' {
            if (-not $script:GhAvailable) { Set-ItResult -Skipped -Because 'gh CLI not found' }

            $workDir = & $script:NewWorkDir
            $finding = [ordered]@{
                id                = 'F1'
                category          = 'security'
                judge_ruling      = 'finding-sustained'
                severity          = 'medium'
                points            = 5
                review_stage      = 'main'
                systemic_fix_type = 'instruction'
            }
            # No proposals_emitted in calibration — pattern must be unmarked
            $calib = & $script:BuildSystemicCalibration `
                -Findings @($finding) `
                -PrNumbers @($script:SystemicPr1, $script:SystemicPr2)
            $calibPath = Join-Path $workDir 'systemic-notproposed.json'
            & $script:WriteCalibrationFile -Path $calibPath -Data $calib

            $result = & $script:InvokeAggregate `
                -ExtraArgs @('-CalibrationFile', $calibPath)

            $result.ExitCode | Should -Be 0
            $result.Output | Should -Match 'systemic_patterns:' `
                -Because 'systemic_patterns section must appear before checking previously_proposed'
            $result.Output | Should -Match 'previously_proposed:\s*false' `
                -Because 'pattern absent from proposals_emitted must have previously_proposed: false'
        }

        It 'previously_proposed is true when pattern_key and evidence_prs match proposals_emitted' -Tag 'requires-gh' {
            if (-not $script:GhAvailable) { Set-ItResult -Skipped -Because 'gh CLI not found' }

            $workDir = & $script:NewWorkDir
            $finding = [ordered]@{
                id                = 'F1'
                category          = 'security'
                judge_ruling      = 'finding-sustained'
                severity          = 'medium'
                points            = 5
                review_stage      = 'main'
                systemic_fix_type = 'instruction'
            }
            $proposals = @(
                [ordered]@{
                    pattern_key  = 'instruction:security'
                    evidence_prs = @($script:SystemicPr1, $script:SystemicPr2)
                }
            )
            $calib = & $script:BuildSystemicCalibration `
                -Findings @($finding) `
                -PrNumbers @($script:SystemicPr1, $script:SystemicPr2) `
                -ProposalsEmitted $proposals
            $calibPath = Join-Path $workDir 'systemic-proposed.json'
            & $script:WriteCalibrationFile -Path $calibPath -Data $calib

            $result = & $script:InvokeAggregate `
                -ExtraArgs @('-CalibrationFile', $calibPath)

            $result.ExitCode | Should -Be 0
            $result.Output | Should -Match 'systemic_patterns:' `
                -Because 'systemic_patterns section must appear before checking previously_proposed'
            $result.Output | Should -Match 'previously_proposed:\s*true' `
                -Because 'pattern matching proposals_emitted pattern_key and evidence_prs must have previously_proposed: true'
        }

        It 'v2 PR-body findings loop never activates systemic accumulation (D49 structural check)' -Tag 'no-gh' {
            # D49: systemic accumulation is restricted to the local-calibration path only.
            # $systemicActive must be set to $true in exactly one place -- inside the
            # local-calibration fallback branch (if (-not $metricsMatch.Success)).
            # This test verifies the invariant structurally so regressions (accidentally
            # activating $systemicActive in the v2 loop) fail immediately.
            $scriptContent = Get-Content -Path $script:LibFile -Raw

            # Exactly 1 occurrence of $systemicActive = $true (local-cal path only).
            # Use [^#\n]* so the match anchor forbids # from appearing anywhere before
            # the pattern on the same line — comment lines (# $systemicActive = ...) are
            # excluded because [^#\n]* consumes only non-# chars from the line start.
            $activations = [regex]::Matches($scriptContent, '(?m)^[^#\n]*\$systemicActive\s*=\s*\$true')
            $activations.Count | Should -Be 1 `
                -Because 'D49: $systemicActive must be set to $true in exactly one place (local-calibration fallback path only)'

            # That activation must appear AFTER the local-cal branch marker and BEFORE the v2 path
            $localCalBranchPos = $scriptContent.IndexOf('-not $metricsMatch.Success')
            $localCalBranchPos | Should -BeGreaterThan 0 `
                -Because 'local-calibration branch marker must be present in the script'
            $activationPos = $activations[0].Index
            $activationPos | Should -BeGreaterThan $localCalBranchPos `
                -Because 'D49: $systemicActive activation must be inside the local-calibration fallback branch (after -not $metricsMatch.Success)'
        }
    }

    # ==================================================================
    # kaizen_metric: section — every test below must fail initially.
    # ==================================================================
    Context 'kaizen_metric output' {

        BeforeAll {
            # $script:NonMetricsPrNumbers, $script:BuildDepthCalibration,
            # $script:BuildSystemicCalibration, $script:MakeCategoryFindings,
            # $script:SystemicPr1, and $script:SystemicPr2 are populated by their
            # respective context BeforeAll blocks, which run before this context
            # (contexts execute in document order).
            $script:KaizenSystemicPr1 = $script:SystemicPr1
            $script:KaizenSystemicPr2 = $script:SystemicPr2
        }

        It 'emits kaizen_metric section after systemic_patterns' -Tag 'requires-gh' {
            if (-not $script:GhAvailable) { Set-ItResult -Skipped -Because 'gh CLI not found' }

            $workDir = & $script:NewWorkDir
            # Findings with systemic_fix_type so both systemic_patterns and kaizen_metric
            # can be computed. NonMetricsPrNumbers provides enough PRs for sufficient_data.
            $findings = @(
                [ordered]@{ id = 'F1'; category = 'architecture'; judge_ruling = 'finding-sustained'
                    severity = 'medium'; points = 5; review_stage = 'main'
                    systemic_fix_type = 'instruction'
                }
            )
            $calib = & $script:BuildDepthCalibration `
                -Findings $findings `
                -PrNumbers $script:NonMetricsPrNumbers
            $calibPath = Join-Path $workDir 'kaizen-basic.json'
            & $script:WriteCalibrationFile -Path $calibPath -Data $calib

            $result = & $script:InvokeAggregate `
                -ExtraArgs @('-CalibrationFile', $calibPath)

            $result.ExitCode | Should -Be 0
            $result.Output | Should -Match 'kaizen_metric:' `
                -Because 'kaizen_metric section must appear in output'
            $result.Output | Should -Match 'categories_with_sufficient_data:' `
                -Because 'categories_with_sufficient_data field must appear under kaizen_metric'
            $result.Output | Should -Match 'categories_at_skip_depth:' `
                -Because 'categories_at_skip_depth field must appear under kaizen_metric'
            $result.Output | Should -Match 'categories_at_light_depth:' `
                -Because 'categories_at_light_depth field must appear under kaizen_metric'
            $result.Output | Should -Match 'kaizen_rate:' `
                -Because 'kaizen_rate field must appear under kaizen_metric'
            $result.Output | Should -Match 'patterns_meeting_threshold:' `
                -Because 'patterns_meeting_threshold field must appear under kaizen_metric'
            $result.Output | Should -Match 'patterns_previously_proposed:' `
                -Because 'patterns_previously_proposed field must appear under kaizen_metric'
        }

        It 'kaizen_rate is 0.00 when no categories have sufficient data' -Tag 'requires-gh' {
            if (-not $script:GhAvailable) { Set-ItResult -Skipped -Because 'gh CLI not found' }

            $workDir = & $script:NewWorkDir
            # Only 1 PR → effective_count << 20 → sufficient_data: false for all categories
            # → denominator is 0 → kaizen_rate must be 0.00
            $findings = @(
                [ordered]@{ id = 'F1'; category = 'architecture'; judge_ruling = 'finding-sustained'
                    severity = 'medium'; points = 5; review_stage = 'main'
                }
            )
            $calib = & $script:BuildDepthCalibration -Findings $findings -PrNumbers @(9901)
            $calibPath = Join-Path $workDir 'kaizen-nosuffix.json'
            & $script:WriteCalibrationFile -Path $calibPath -Data $calib

            $result = & $script:InvokeAggregate `
                -ExtraArgs @('-CalibrationFile', $calibPath)

            $result.ExitCode | Should -Be 0
            $result.Output | Should -Match 'kaizen_rate:\s*0\.00' `
                -Because 'kaizen_rate must be 0.00 when no categories have sufficient data (denominator is 0)'
        }

        It 'kaizen_rate computed correctly when categories at reduced depth' -Tag 'requires-gh' {
            # Fixture: architecture has stale skip_first_observed_at (100 days ago) which drives
            # time-decay skip→light. NonMetricsPrNumbers gives sufficient effective_count.
            # Acceptable assertion: kaizen_rate must be present in F2 decimal format.
            if (-not $script:GhAvailable) { Set-ItResult -Skipped -Because 'gh CLI not found' }

            $workDir = & $script:NewWorkDir
            $staleDate = (Get-Date).AddDays(-100).ToString('o')
            $depthState = [ordered]@{
                architecture = [ordered]@{
                    skip_first_observed_at = $staleDate
                }
            }
            $findings = & $script:MakeCategoryFindings 'architecture' 1 34
            $calib = & $script:BuildDepthCalibration -Findings $findings `
                -PrNumbers $script:NonMetricsPrNumbers -DepthState $depthState
            $calibPath = Join-Path $workDir 'kaizen-rate.json'
            & $script:WriteCalibrationFile -Path $calibPath -Data $calib

            $result = & $script:InvokeAggregate `
                -ExtraArgs @('-CalibrationFile', $calibPath)

            $result.ExitCode | Should -Be 0
            $result.Output | Should -Match 'kaizen_rate:\s*\d+\.\d{2}' `
                -Because 'kaizen_rate must appear in F2 decimal format when categories have sufficient data'
        }

        It 'patterns_meeting_threshold counts threshold-met patterns' -Tag 'requires-gh' {
            # Two distinct systemic patterns (instruction:security, skill:pattern) each
            # across 2 distinct PRs → both meet threshold → patterns_meeting_threshold: 2
            if (-not $script:GhAvailable) { Set-ItResult -Skipped -Because 'gh CLI not found' }

            $workDir = & $script:NewWorkDir
            $findings = @(
                [ordered]@{ id = 'F1'; category = 'security'; judge_ruling = 'finding-sustained'
                    severity = 'medium'; points = 5; review_stage = 'main'
                    systemic_fix_type = 'instruction'
                },
                [ordered]@{ id = 'F2'; category = 'pattern'; judge_ruling = 'finding-sustained'
                    severity = 'medium'; points = 5; review_stage = 'main'
                    systemic_fix_type = 'skill'
                }
            )
            $calib = & $script:BuildSystemicCalibration `
                -Findings $findings `
                -PrNumbers @($script:KaizenSystemicPr1, $script:KaizenSystemicPr2)
            $calibPath = Join-Path $workDir 'kaizen-threshold.json'
            & $script:WriteCalibrationFile -Path $calibPath -Data $calib

            $result = & $script:InvokeAggregate `
                -ExtraArgs @('-CalibrationFile', $calibPath)

            $result.ExitCode | Should -Be 0
            $result.Output | Should -Match 'patterns_meeting_threshold:\s*2' `
                -Because '2 distinct patterns each appearing in 2 distinct PRs must yield patterns_meeting_threshold: 2'
        }

        It 'patterns_previously_proposed counts previously_proposed patterns' -Tag 'requires-gh' {
            # Two threshold-met patterns: instruction:security is in proposals_emitted,
            # skill:pattern is not → patterns_previously_proposed: 1
            if (-not $script:GhAvailable) { Set-ItResult -Skipped -Because 'gh CLI not found' }

            $workDir = & $script:NewWorkDir
            $findings = @(
                [ordered]@{ id = 'F1'; category = 'security'; judge_ruling = 'finding-sustained'
                    severity = 'medium'; points = 5; review_stage = 'main'
                    systemic_fix_type = 'instruction'
                },
                [ordered]@{ id = 'F2'; category = 'pattern'; judge_ruling = 'finding-sustained'
                    severity = 'medium'; points = 5; review_stage = 'main'
                    systemic_fix_type = 'skill'
                }
            )
            $proposals = @(
                [ordered]@{
                    pattern_key  = 'instruction:security'
                    evidence_prs = @($script:KaizenSystemicPr1, $script:KaizenSystemicPr2)
                }
            )
            $calib = & $script:BuildSystemicCalibration `
                -Findings $findings `
                -PrNumbers @($script:KaizenSystemicPr1, $script:KaizenSystemicPr2) `
                -ProposalsEmitted $proposals
            $calibPath = Join-Path $workDir 'kaizen-proposed.json'
            & $script:WriteCalibrationFile -Path $calibPath -Data $calib

            $result = & $script:InvokeAggregate `
                -ExtraArgs @('-CalibrationFile', $calibPath)

            $result.ExitCode | Should -Be 0
            $result.Output | Should -Match 'patterns_previously_proposed:\s*1' `
                -Because '1 of 2 threshold-met patterns matches proposals_emitted so patterns_previously_proposed must be 1'
        }
    }

    # ===================================================================
    # proposals_emitted write-back — every test below must fail initially.
    # ===================================================================
    Context 'proposals_emitted write-back' {

        It 'write-back: threshold-met unproposed patterns added to proposals_emitted in calibration file' -Tag 'requires-gh' {
            if (-not $script:GhAvailable) { Set-ItResult -Skipped -Because 'gh CLI not found' }

            # ARRANGE: two PRs each with instruction:security finding → distinct_prs=2, meets_threshold.
            $workDir = & $script:NewWorkDir
            $findings = @(
                [ordered]@{ id = 'F1'; category = 'security'; judge_ruling = 'finding-sustained'
                    severity = 'medium'; points = 5; review_stage = 'main'
                    systemic_fix_type = 'instruction'
                }
            )
            $calib = & $script:BuildSystemicCalibration `
                -Findings $findings `
                -PrNumbers @($script:SystemicPr1, $script:SystemicPr2) `
                -ProposalsEmitted @()
            $calibPath = Join-Path $workDir 'proposals-writeback.json'
            & $script:WriteCalibrationFile -Path $calibPath -Data $calib

            # ACT
            $result = & $script:InvokeAggregate `
                -ExtraArgs @('-CalibrationFile', $calibPath)

            # ASSERT: fixture produced a threshold-met pattern
            $result.ExitCode | Should -Be 0
            $result.Output | Should -Match 'meets_threshold:\s*true' `
                -Because 'fixture must produce a threshold-met pattern (2 sustained across 2 PRs)'

            # ASSERT: proposals_emitted written to calibration file with correct fields
            $readBack = Get-Content $calibPath -Raw | ConvertFrom-Json -AsHashtable
            $readBack['proposals_emitted'] | Should -Not -BeNullOrEmpty `
                -Because 'proposals_emitted must be written when a threshold-met unproposed pattern exists'
            $readBack['proposals_emitted'].Count | Should -BeGreaterOrEqual 1 `
                -Because 'at least one proposal entry (instruction:security) must be written'
            $entry = @($readBack['proposals_emitted']) | Where-Object { $_['pattern_key'] -eq 'instruction:security' }
            $entry | Should -Not -BeNullOrEmpty `
                -Because 'pattern_key instruction:security must be present in proposals_emitted'
            @($entry)[0]['evidence_prs'] | Should -Not -BeNullOrEmpty `
                -Because 'evidence_prs must be persisted alongside the pattern_key'
            @($entry)[0]['first_emitted_at'] | Should -Not -BeNullOrEmpty `
                -Because 'first_emitted_at timestamp must be persisted'
        }

        It 'write-back: pre-existing proposals_emitted entries preserved when new pattern added' -Tag 'requires-gh' {
            if (-not $script:GhAvailable) { Set-ItResult -Skipped -Because 'gh CLI not found' }

            # ARRANGE: pre-existing proposal for different key; new threshold-met pattern (instruction:security).
            $workDir = & $script:NewWorkDir
            $preExisting = @(
                [ordered]@{
                    pattern_key      = 'instruction:architecture'
                    evidence_prs     = @(8801, 8802)
                    first_emitted_at = '2025-01-01T00:00:00Z'
                }
            )
            $findings = @(
                [ordered]@{ id = 'F1'; category = 'security'; judge_ruling = 'finding-sustained'
                    severity = 'medium'; points = 5; review_stage = 'main'
                    systemic_fix_type = 'instruction'
                }
            )
            $calib = & $script:BuildSystemicCalibration `
                -Findings $findings `
                -PrNumbers @($script:SystemicPr1, $script:SystemicPr2) `
                -ProposalsEmitted $preExisting
            $calibPath = Join-Path $workDir 'proposals-preserve.json'
            & $script:WriteCalibrationFile -Path $calibPath -Data $calib

            # ACT
            $result = & $script:InvokeAggregate `
                -ExtraArgs @('-CalibrationFile', $calibPath)

            $result.ExitCode | Should -Be 0

            # ASSERT: both old and new entries present
            $readBack = Get-Content $calibPath -Raw | ConvertFrom-Json -AsHashtable
            $readBack['proposals_emitted'] | Should -Not -BeNullOrEmpty `
                -Because 'proposals_emitted must exist after write-back'
            $keys = @($readBack['proposals_emitted']) | ForEach-Object { $_['pattern_key'] }
            $keys | Should -Contain 'instruction:architecture' `
                -Because 'pre-existing proposal entry must be preserved after write-back'
            $keys | Should -Contain 'instruction:security' `
                -Because 'new threshold-met pattern must be added alongside pre-existing entries'
        }

        It 'write-back: proposals_emitted not written when no new patterns meet threshold' -Tag 'requires-gh' {
            # RED: cannot trivially pass — absence of write-back when threshold unmet.
            if (-not $script:GhAvailable) { Set-ItResult -Skipped -Because 'gh CLI not found' }

            # ARRANGE: only 1 PR → distinct_prs=1 < 2 → threshold not met → no write-back.
            $workDir = & $script:NewWorkDir
            $findings = @(
                [ordered]@{ id = 'F1'; category = 'security'; judge_ruling = 'finding-sustained'
                    severity = 'medium'; points = 5; review_stage = 'main'
                    systemic_fix_type = 'instruction'
                }
            )
            $calib = & $script:BuildSystemicCalibration `
                -Findings $findings `
                -PrNumbers @($script:SystemicPr1) `
                -ProposalsEmitted @()
            $calibPath = Join-Path $workDir 'proposals-nothreshold.json'
            & $script:WriteCalibrationFile -Path $calibPath -Data $calib

            # ACT
            $result = & $script:InvokeAggregate `
                -ExtraArgs @('-CalibrationFile', $calibPath)

            $result.ExitCode | Should -Be 0
            $result.Output | Should -Match 'meets_threshold:\s*false' `
                -Because 'fixture with 1 PR must produce meets_threshold: false'

            # ASSERT: proposals_emitted not added to calibration file
            $readBack = Get-Content $calibPath -Raw | ConvertFrom-Json -AsHashtable
            $readBack['proposals_emitted'] | Should -BeNullOrEmpty `
                -Because 'proposals_emitted must not be written when no new pattern meets threshold'
        }

        It 'write-back: superset evidence PRs produce previously_proposed: false (new proposal generated)' -Tag 'requires-gh' {
            # F3 boundary: prior proposals_emitted has evidence_prs [PR1, PR2].
            # Current run accumulates 3 distinct PRs [PR1, PR2, PR3].
            # Compare-Object finds differences → previously_proposed: false → new proposal written.
            if (-not $script:GhAvailable) { Set-ItResult -Skipped -Because 'gh CLI not found' }

            $firstThree = @($script:NonMetricsPrNumbers | Select-Object -First 3)
            if ($firstThree.Count -lt 3) { Set-ItResult -Skipped -Because 'need 3 non-metrics PRs for superset test' }
            $pr1 = [int]$firstThree[0]
            $pr2 = [int]$firstThree[1]
            $pr3 = [int]$firstThree[2]

            $workDir = & $script:NewWorkDir
            $finding = [ordered]@{
                id                = 'F1'
                category          = 'security'
                judge_ruling      = 'finding-sustained'
                severity          = 'medium'
                points            = 5
                review_stage      = 'main'
                systemic_fix_type = 'instruction'
            }
            # Prior proposals: instruction:security seen across PR1+PR2 only
            $priorProposals = @(
                [ordered]@{
                    pattern_key      = 'instruction:security'
                    evidence_prs     = @($pr1, $pr2)
                    first_emitted_at = '2025-01-01T00:00:00Z'
                }
            )
            # Current calibration has the pattern across PR1+PR2+PR3 (superset)
            $calib = & $script:BuildSystemicCalibration `
                -Findings @($finding) `
                -PrNumbers @($pr1, $pr2, $pr3) `
                -ProposalsEmitted $priorProposals
            $calibPath = Join-Path $workDir 'proposals-superset.json'
            & $script:WriteCalibrationFile -Path $calibPath -Data $calib

            $result = & $script:InvokeAggregate `
                -ExtraArgs @('-CalibrationFile', $calibPath)

            $result.ExitCode | Should -Be 0
            $result.Output | Should -Match 'systemic_patterns:' `
                -Because 'systemic_patterns section must appear before checking previously_proposed'
            $result.Output | Should -Match 'previously_proposed:\s*false' `
                -Because 'expanded evidence set (superset) must not match prior proposal -- new proposal expected'
        }
    }

    # ==================================================================
    # Context: complexity_over_ceiling_history
    # Tests for -ComplexityJsonPath parameter and complexity history
    # write-back behavior (Phase 2 D7 implementation).
    # AST tests (no-gh): verify parameter declaration and script structure.
    # Execution tests (requires-gh): verify history increment, reset,
    # idempotency, consolidation events, and YAML extraction_agents output.
    # ==================================================================
    Context 'complexity_over_ceiling_history' {

        BeforeAll {
            # Guard: ensure NonMetricsPrNumbers is available when this context runs in isolation
            if (-not $script:NonMetricsPrNumbers) {
                $allPrJsonGuard = & gh pr list --repo 'Grimblaz/copilot-orchestra' --state merged --limit 100 --json 'number,body' 2>$null
                $script:NonMetricsPrNumbers = if ($allPrJsonGuard) {
                    @(($allPrJsonGuard | ConvertFrom-Json) |
                            Where-Object { $_.body -notmatch 'pipeline-metrics' } |
                            ForEach-Object { [int]$_.number })
                }
                else { @(9901) }
            }

            # Helper: write a complexity JSON file simulating measure-guidance-complexity.ps1 output
            $script:WriteComplexityFile = {
                param([string]$Path, [string[]]$AgentsOverCeiling)
                $complexity = [ordered]@{
                    config_source       = 'test'
                    agents_over_ceiling = @($AgentsOverCeiling)
                    agents              = @($AgentsOverCeiling | ForEach-Object {
                            [ordered]@{ file = $_; total_directives = 150; section_count = 20; sections = @() }
                        })
                }
                $complexity | ConvertTo-Json -Depth 5 | Set-Content -Path $Path -Encoding UTF8
            }
        }

        # ---- AST tests (no-gh) -----------------------------------------------

        It 'script declares -ComplexityJsonPath parameter as [string]' -Tag 'no-gh' {
            $script:ParamNames | Should -Contain 'ComplexityJsonPath' `
                -Because 'aggregate-review-scores.ps1 must declare -ComplexityJsonPath to receive the complexity JSON file path from Process-Review §4.7'
            $paramAst = $script:AllParams | Where-Object { $_.Name.VariablePath.UserPath -eq 'ComplexityJsonPath' }
            $paramAst | Should -Not -BeNullOrEmpty `
                -Because '-ComplexityJsonPath parameter AST node must be found'
            $paramAst.StaticType.Name | Should -Be 'String' `
                -Because '-ComplexityJsonPath must be declared as [string]'
        }

        It 'script references guidance-complexity.json for persistent_threshold' -Tag 'no-gh' {
            $content = Get-Content -Path $script:LibFile -Raw
            $content | Should -Match 'guidance-complexity\.json' `
                -Because 'aggregate-review-scores.ps1 must read persistent_threshold from the guidance-complexity config file'
            $content | Should -Match 'persistent_threshold' `
                -Because 'script must reference the persistent_threshold config key used to gate extraction advisory'
        }

        It 'script declares complexityHistoryChanged dirty flag to gate write-back' -Tag 'no-gh' {
            $content = Get-Content -Path $script:LibFile -Raw
            $content | Should -Match 'complexityHistoryChanged' `
                -Because 'script must track whether complexity history changed so write-back is conditional (atomic + dirty-flag pattern)'
        }

        # ---- Execution tests (requires-gh) ------------------------------------

        It 'exits cleanly without -ComplexityJsonPath — backward compatible' -Tag 'requires-gh' {
            # When -ComplexityJsonPath is omitted, complexity history must not be written
            if (-not $script:GhAvailable) { Set-ItResult -Skipped -Because 'gh CLI not found' }

            $workDir = & $script:NewWorkDir
            $calibPath = Join-Path $workDir 'backward-compat.json'
            & $script:WriteCalibrationFile -Path $calibPath -Data ([ordered]@{
                    calibration_version = 1; entries = @()
                })

            $result = & $script:InvokeAggregate `
                -ExtraArgs @('-CalibrationFile', $calibPath)

            $result.ExitCode | Should -Be 0 `
                -Because 'script must exit 0 without -ComplexityJsonPath'
            $readBack = Get-Content $calibPath -Raw | ConvertFrom-Json -AsHashtable
            $readBack['complexity_over_ceiling_history'] | Should -BeNullOrEmpty `
                -Because 'complexity_over_ceiling_history must not be written when -ComplexityJsonPath is omitted'
        }

        It 'increments consecutive_count to 1 on first observation of an over-ceiling agent' -Tag 'requires-gh' {
            if (-not $script:GhAvailable) { Set-ItResult -Skipped -Because 'gh CLI not found' }

            $workDir = & $script:NewWorkDir
            $complexityPath = Join-Path $workDir 'complexity.json'
            & $script:WriteComplexityFile -Path $complexityPath -AgentsOverCeiling @('TestAgent.agent.md')

            $calibPath = Join-Path $workDir 'increment-calib.json'
            & $script:WriteCalibrationFile -Path $calibPath -Data ([ordered]@{
                    calibration_version = 1; entries = @()
                })

            $result = & $script:InvokeAggregate `
                -ExtraArgs @('-CalibrationFile', $calibPath, '-ComplexityJsonPath', $complexityPath)

            $result.ExitCode | Should -Be 0
            $readBack = Get-Content $calibPath -Raw | ConvertFrom-Json -AsHashtable
            $readBack['complexity_over_ceiling_history'] | Should -Not -BeNullOrEmpty `
                -Because 'complexity_over_ceiling_history must be written to the calibration file when an agent is over ceiling'
            [int]$readBack['complexity_over_ceiling_history']['TestAgent.agent.md']['consecutive_count'] | Should -Be 1 `
                -Because 'first observation of an over-ceiling agent must set consecutive_count to 1'
        }

        It 'sets first_observed_at and last_observed_at as valid datetime strings on first observation' -Tag 'requires-gh' {
            if (-not $script:GhAvailable) { Set-ItResult -Skipped -Because 'gh CLI not found' }

            $workDir = & $script:NewWorkDir
            $complexityPath = Join-Path $workDir 'complexity.json'
            & $script:WriteComplexityFile -Path $complexityPath -AgentsOverCeiling @('TestAgent.agent.md')

            $calibPath = Join-Path $workDir 'firstobs-calib.json'
            & $script:WriteCalibrationFile -Path $calibPath -Data ([ordered]@{
                    calibration_version = 1; entries = @()
                })

            $result = & $script:InvokeAggregate `
                -ExtraArgs @('-CalibrationFile', $calibPath, '-ComplexityJsonPath', $complexityPath)

            $result.ExitCode | Should -Be 0
            $readBack = Get-Content $calibPath -Raw | ConvertFrom-Json -AsHashtable
            $entry = $readBack['complexity_over_ceiling_history']['TestAgent.agent.md']
            $entry | Should -Not -BeNullOrEmpty `
                -Because 'history entry must exist for the observed agent'
            $entry['first_observed_at'] | Should -Not -BeNullOrEmpty `
                -Because 'first_observed_at must be set on first observation'
            $entry['last_observed_at'] | Should -Not -BeNullOrEmpty `
                -Because 'last_observed_at must be set on first observation'
            { [datetime]$entry['first_observed_at'] } | Should -Not -Throw `
                -Because 'first_observed_at must be a valid datetime string'
        }

        It 'does not re-increment consecutive_count on second run with same max PR number (idempotency)' -Tag 'requires-gh' {
            if (-not $script:GhAvailable) { Set-ItResult -Skipped -Because 'gh CLI not found' }

            $workDir = & $script:NewWorkDir
            $complexityPath = Join-Path $workDir 'complexity.json'
            & $script:WriteComplexityFile -Path $complexityPath -AgentsOverCeiling @('TestAgent.agent.md')

            $calibPath = Join-Path $workDir 'idempotency-calib.json'
            & $script:WriteCalibrationFile -Path $calibPath -Data ([ordered]@{
                    calibration_version = 1; entries = @()
                })

            # First run — establishes last_pr_number (the current max merged PR number)
            $result1 = & $script:InvokeAggregate `
                -ExtraArgs @('-CalibrationFile', $calibPath, '-ComplexityJsonPath', $complexityPath)
            $result1.ExitCode | Should -Be 0 `
                -Because 'first run must exit 0'

            # Second run — same max PR number context; must NOT re-increment
            $result2 = & $script:InvokeAggregate `
                -ExtraArgs @('-CalibrationFile', $calibPath, '-ComplexityJsonPath', $complexityPath)
            $result2.ExitCode | Should -Be 0 `
                -Because 'second run must exit 0'

            $readBack = Get-Content $calibPath -Raw | ConvertFrom-Json -AsHashtable
            [int]$readBack['complexity_over_ceiling_history']['TestAgent.agent.md']['consecutive_count'] | Should -Be 1 `
                -Because 're-running the aggregate for the same max PR number must not re-increment consecutive_count (idempotency guard by last_pr_number)'
        }

        It 'removes history entry and logs consolidation_event when agent drops below ceiling' -Tag 'requires-gh' {
            if (-not $script:GhAvailable) { Set-ItResult -Skipped -Because 'gh CLI not found' }

            $workDir = & $script:NewWorkDir

            # Pre-seed: TestAgent.agent.md was over ceiling for 2 consecutive runs
            $preSeededHistory = [ordered]@{
                'TestAgent.agent.md' = [ordered]@{
                    consecutive_count = 2
                    first_observed_at = '2026-03-01T00:00:00Z'
                    last_observed_at  = '2026-03-15T00:00:00Z'
                    last_pr_number    = 1
                }
            }
            $calib = [ordered]@{
                calibration_version             = 1
                entries                         = @()
                complexity_over_ceiling_history = $preSeededHistory
            }
            $calibPath = Join-Path $workDir 'consolidation-calib.json'
            & $script:WriteCalibrationFile -Path $calibPath -Data $calib

            # Complexity JSON: TestAgent.agent.md is now BELOW ceiling (absent from agents_over_ceiling)
            $complexityPath = Join-Path $workDir 'complexity-clean.json'
            & $script:WriteComplexityFile -Path $complexityPath -AgentsOverCeiling @()

            $result = & $script:InvokeAggregate `
                -ExtraArgs @('-CalibrationFile', $calibPath, '-ComplexityJsonPath', $complexityPath)

            $result.ExitCode | Should -Be 0
            $readBack = Get-Content $calibPath -Raw | ConvertFrom-Json -AsHashtable
            $readBack['complexity_over_ceiling_history'] | Should -BeNullOrEmpty `
                -Because 'TestAgent.agent.md dropped below ceiling — history entry must be removed'
            $readBack['consolidation_events'] | Should -Not -BeNullOrEmpty `
                -Because 'a consolidation_event must be recorded when an agent that was tracked drops below ceiling'
            [int]($readBack['consolidation_events']).Count | Should -BeGreaterOrEqual 1 `
                -Because 'at least one consolidation event must be logged for the agent that dropped below ceiling'
            ($readBack['consolidation_events'])[0]['agent'] | Should -Be 'TestAgent.agent.md' `
                -Because 'consolidation event must record the agent basename that dropped below ceiling'
        }

        It 'tracks multiple agents independently in the same run' -Tag 'requires-gh' {
            if (-not $script:GhAvailable) { Set-ItResult -Skipped -Because 'gh CLI not found' }

            $workDir = & $script:NewWorkDir
            $complexityPath = Join-Path $workDir 'complexity-multi.json'
            & $script:WriteComplexityFile -Path $complexityPath -AgentsOverCeiling @('AgentA.agent.md', 'AgentB.agent.md')

            $calibPath = Join-Path $workDir 'multi-calib.json'
            & $script:WriteCalibrationFile -Path $calibPath -Data ([ordered]@{
                    calibration_version = 1; entries = @()
                })

            $result = & $script:InvokeAggregate `
                -ExtraArgs @('-CalibrationFile', $calibPath, '-ComplexityJsonPath', $complexityPath)

            $result.ExitCode | Should -Be 0
            $readBack = Get-Content $calibPath -Raw | ConvertFrom-Json -AsHashtable
            $history = $readBack['complexity_over_ceiling_history']
            $history | Should -Not -BeNullOrEmpty `
                -Because 'complexity_over_ceiling_history must be written for multiple agents'
            [int]$history['AgentA.agent.md']['consecutive_count'] | Should -Be 1 `
                -Because 'AgentA must be independently tracked with consecutive_count 1'
            [int]$history['AgentB.agent.md']['consecutive_count'] | Should -Be 1 `
                -Because 'AgentB must be independently tracked with consecutive_count 1'
        }

        It 'emits extraction_agents in YAML output when consecutive_count meets persistent_threshold' -Tag 'requires-gh' {
            # Fix M4: use a custom config fixture with persistent_threshold=2 so the test is not
            # coupled to the production config value. Pre-seed consecutive_count=1 (threshold-1);
            # this run increments to 2 -> meets custom threshold of 2 -> extraction_agents emitted.
            # If someone changes the production threshold to 5, this test still passes.
            if (-not $script:GhAvailable) { Set-ItResult -Skipped -Because 'gh CLI not found' }

            $workDir = & $script:NewWorkDir
            $configPath = Join-Path $script:RepoRoot '.github/config/guidance-complexity.json'
            $configBackup = Get-Content -Path $configPath -Raw
            try {
                # Write custom config with persistent_threshold=2
                $customConfig = [ordered]@{
                    version              = 1
                    ceilings             = [ordered]@{}
                    default_ceiling      = [ordered]@{ max_directives = 128 }
                    persistent_threshold = 2
                }
                $customConfig | ConvertTo-Json -Depth 5 | Set-Content -Path $configPath -Encoding UTF8

                $preSeededHistory = [ordered]@{
                    'TestAgent.agent.md' = [ordered]@{
                        consecutive_count = 1
                        first_observed_at = '2026-03-01T00:00:00Z'
                        last_observed_at  = '2026-03-15T00:00:00Z'
                        last_pr_number    = 1
                    }
                }
                $calib = [ordered]@{
                    calibration_version             = 1
                    entries                         = @()
                    complexity_over_ceiling_history = $preSeededHistory
                }
                $calibPath = Join-Path $workDir 'threshold-calib.json'
                & $script:WriteCalibrationFile -Path $calibPath -Data $calib

                # This run increments TestAgent to consecutive_count=2 -> meets custom threshold of 2
                $complexityPath = Join-Path $workDir 'complexity-threshold.json'
                & $script:WriteComplexityFile -Path $complexityPath -AgentsOverCeiling @('TestAgent.agent.md')

                $result = & $script:InvokeAggregate `
                    -ExtraArgs @('-CalibrationFile', $calibPath, '-ComplexityJsonPath', $complexityPath)

                $result.ExitCode | Should -Be 0
                $result.Output | Should -Match 'extraction_agents:' `
                    -Because 'extraction_agents section must appear in YAML output when an agent meets or exceeds the custom persistent_threshold of 2'
                $result.Output | Should -Match 'TestAgent\.agent\.md' `
                    -Because 'the agent meeting the threshold must be listed under extraction_agents'
            }
            finally {
                # Restore the real config regardless of test outcome
                $configBackup | Set-Content -Path $configPath -Encoding UTF8
            }
        }

        It 'skips complexity tracking when -ComplexityJsonPath points to a non-existent file' -Tag 'requires-gh' {
            # Fix M7: verify that a non-existent -ComplexityJsonPath produces exit 0 and leaves
            # complexity_over_ceiling_history untouched (backward-compatible skip behavior).
            if (-not $script:GhAvailable) { Set-ItResult -Skipped -Because 'gh CLI not found' }

            $workDir = & $script:NewWorkDir
            $calibPath = Join-Path $workDir 'nonexistent-calib.json'
            & $script:WriteCalibrationFile -Path $calibPath -Data ([ordered]@{
                    calibration_version = 1; entries = @()
                })

            $result = & $script:InvokeAggregate `
                -ExtraArgs @('-CalibrationFile', $calibPath, `
                    '-ComplexityJsonPath', 'C:\nonexistentpath\complexity-ghost.json')

            $result.ExitCode | Should -Be 0 `
                -Because 'a non-existent -ComplexityJsonPath must not abort the script'
            $readBack = Get-Content $calibPath -Raw | ConvertFrom-Json -AsHashtable
            $readBack['complexity_over_ceiling_history'] | Should -BeNullOrEmpty `
                -Because 'complexity_over_ceiling_history must not be written when -ComplexityJsonPath points to a non-existent file'
        }

        It 'preserves first_observed_at on genuine increment (different PR number)' -Tag 'requires-gh' {
            # Fix M10: verify that first_observed_at is immutable once set — only last_observed_at
            # and consecutive_count change when the idempotency guard does NOT fire (different PR number).
            if (-not $script:GhAvailable) { Set-ItResult -Skipped -Because 'gh CLI not found' }

            $workDir = & $script:NewWorkDir
            $complexityPath = Join-Path $workDir 'complexity-m10.json'
            & $script:WriteComplexityFile -Path $complexityPath -AgentsOverCeiling @('TestAgent.agent.md')

            # Pre-seed with last_pr_number=1 (far below current max merged PR) so the
            # idempotency guard does not fire and a genuine increment occurs.
            $preSeededHistory = [ordered]@{
                'TestAgent.agent.md' = [ordered]@{
                    consecutive_count = 1
                    first_observed_at = '2026-01-01T00:00:00Z'
                    last_observed_at  = '2026-01-01T00:00:00Z'
                    last_pr_number    = 1
                }
            }
            $calib = [ordered]@{
                calibration_version             = 1
                entries                         = @()
                complexity_over_ceiling_history = $preSeededHistory
            }
            $calibPath = Join-Path $workDir 'first-observed-immutable-calib.json'
            & $script:WriteCalibrationFile -Path $calibPath -Data $calib

            $result = & $script:InvokeAggregate `
                -ExtraArgs @('-CalibrationFile', $calibPath, '-ComplexityJsonPath', $complexityPath)

            $result.ExitCode | Should -Be 0
            $readBack = Get-Content $calibPath -Raw | ConvertFrom-Json -AsHashtable
            $entry = $readBack['complexity_over_ceiling_history']['TestAgent.agent.md']
            $entry | Should -Not -BeNullOrEmpty `
                -Because 'history entry must still exist after a genuine increment'
            [int]$entry['consecutive_count'] | Should -Be 2 `
                -Because 'genuine increment (different PR number) must raise consecutive_count from 1 to 2'
            $seedTime = [DateTime]::Parse('2026-01-01T00:00:00Z', $null, [System.Globalization.DateTimeStyles]::RoundtripKind)
            $entry['first_observed_at'] | Should -Be $seedTime `
                -Because 'first_observed_at must be preserved on genuine increment — only set on first observation, never overwritten'
            $entry['last_observed_at'] | Should -Not -Be $seedTime `
                -Because 'last_observed_at must be updated to reflect the new observation time'
        }
    }
}

# ==================================================================
# Describe: -HealthReport parameter and return shape contract (Step 1 #259)
# RED tests — all fail until -HealthReport is added to core lib and wrapper,
# -OutputPath is added to wrapper only, and HealthReport key is returned
# from the success path.
# ==================================================================
Describe 'aggregate-review-scores -HealthReport parameter and return shape contract' {

    BeforeAll {
        $script:HRRepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
        $script:HRScriptFile = Join-Path $script:HRRepoRoot '.github\scripts\aggregate-review-scores.ps1'
        $script:HRLibFile = Join-Path $script:HRRepoRoot '.github\scripts\lib\aggregate-review-scores-core.ps1'
        . $script:HRLibFile

        # Isolated temp root for mock-gh artifacts
        $script:HRTempRoot = Join-Path ([System.IO.Path]::GetTempPath()) `
            "pester-healthreport-$([System.Guid]::NewGuid().ToString('N'))"
        New-Item -ItemType Directory -Path $script:HRTempRoot -Force | Out-Null

        # ---------------------------------------------------------------
        # Parse CLI wrapper AST for parameter introspection (no-gh)
        # ---------------------------------------------------------------
        $wrapperContent = Get-Content -Path $script:HRScriptFile -Raw
        $wrapperErrors = $null
        $script:HRWrapperAst = [System.Management.Automation.Language.Parser]::ParseInput(
            $wrapperContent, [ref]$null, [ref]$wrapperErrors
        )
        $script:HRWrapperParams = $script:HRWrapperAst.FindAll(
            { $args[0] -is [System.Management.Automation.Language.ParameterAst] }, $true
        )
        $script:HRWrapperParamNames = $script:HRWrapperParams |
            ForEach-Object { $_.Name.VariablePath.UserPath }

        # ---------------------------------------------------------------
        # Parse core lib AST for parameter introspection (no-gh)
        # ---------------------------------------------------------------
        $libContent = Get-Content -Path $script:HRLibFile -Raw
        $libErrors = $null
        $script:HRLibAst = [System.Management.Automation.Language.Parser]::ParseInput(
            $libContent, [ref]$null, [ref]$libErrors
        )
        $script:HRLibParams = $script:HRLibAst.FindAll(
            { $args[0] -is [System.Management.Automation.Language.ParameterAst] }, $true
        )
        $script:HRLibParamNames = $script:HRLibParams |
            ForEach-Object { $_.Name.VariablePath.UserPath }

        # ---------------------------------------------------------------
        # Helper: write a mock gh.ps1 that outputs preset PR JSON.
        # Same companion-data-file pattern as backfill-calibration.Tests.ps1
        # to avoid quoting hazards in the generated script body.
        # Returns the path to the mock script.
        # ---------------------------------------------------------------
        $script:HRWriteMockGh = {
            param([string]$WorkDir, [string]$JsonOutput)
            $dataFile = Join-Path $WorkDir 'gh-response.json'
            $mockPath = Join-Path $WorkDir 'gh.ps1'
            $JsonOutput | Set-Content -Path $dataFile -Encoding UTF8
            @"
# Mock gh CLI — outputs pre-defined JSON regardless of arguments
Get-Content -Raw -Path '$($dataFile -replace "'", "''")'
exit 0
"@ | Set-Content -Path $mockPath -Encoding UTF8
            return $mockPath
        }
    }

    AfterAll {
        if (Test-Path $script:HRTempRoot) {
            Remove-Item -Recurse -Force -Path $script:HRTempRoot -ErrorAction SilentlyContinue
        }
    }

    # ==================================================================
    # Context: parameter declarations (AST introspection, no-gh)
    # ==================================================================
    Context '-HealthReport and -OutputPath parameter declarations' {

        It 'core lib Invoke-AggregateReviewScores declares -HealthReport as [switch]' -Tag 'no-gh' {
            $script:HRLibParamNames | Should -Contain 'HealthReport' `
                -Because 'Invoke-AggregateReviewScores must declare -HealthReport [switch] to support read-only write-back suppression (D-259-15)'
            $paramAst = $script:HRLibParams | Where-Object {
                $_.Name.VariablePath.UserPath -eq 'HealthReport'
            }
            $paramAst | Should -Not -BeNullOrEmpty `
                -Because '-HealthReport AST node must be present in the core lib param block'
            $paramAst.StaticType.Name | Should -Be 'SwitchParameter' `
                -Because '-HealthReport must be declared as [switch] (StaticType = SwitchParameter)'
        }

        It 'CLI wrapper aggregate-review-scores.ps1 declares -HealthReport as [switch]' -Tag 'no-gh' {
            $script:HRWrapperParamNames | Should -Contain 'HealthReport' `
                -Because 'aggregate-review-scores.ps1 wrapper must declare -HealthReport to activate read-only mode and stdout health-report routing'
            $paramAst = $script:HRWrapperParams | Where-Object {
                $_.Name.VariablePath.UserPath -eq 'HealthReport'
            }
            $paramAst | Should -Not -BeNullOrEmpty `
                -Because '-HealthReport AST node must be present in the wrapper param block'
            $paramAst.StaticType.Name | Should -Be 'SwitchParameter' `
                -Because '-HealthReport must be declared as [switch] in the wrapper'
        }

        It 'CLI wrapper aggregate-review-scores.ps1 declares -OutputPath as [string]' -Tag 'no-gh' {
            $script:HRWrapperParamNames | Should -Contain 'OutputPath' `
                -Because 'aggregate-review-scores.ps1 wrapper must declare -OutputPath so Process-Review §4.7 can write the health report to a file (D-259-16)'
            $paramAst = $script:HRWrapperParams | Where-Object {
                $_.Name.VariablePath.UserPath -eq 'OutputPath'
            }
            $paramAst | Should -Not -BeNullOrEmpty `
                -Because '-OutputPath AST node must be present in the wrapper param block'
            $paramAst.StaticType.Name | Should -Be 'String' `
                -Because '-OutputPath must be declared as [string] in the wrapper'
        }

        It 'core lib Invoke-AggregateReviewScores does NOT declare -OutputPath (F1 fix)' -Tag 'no-gh' {
            $script:HRLibParamNames | Should -Not -Contain 'OutputPath' `
                -Because 'OutputPath controls wrapper-only file routing; passing it to Invoke-AggregateReviewScores causes a parameter-binding error when the wrapper splats PSBoundParameters (F1 critical finding — wrapper must remove OutputPath before splatting)'
        }
    }

    # ==================================================================
    # Context: return hashtable HealthReport key (mock-gh, in-process)
    # Tagged no-gh because mock gh eliminates live API dependency.
    # ==================================================================
    Context 'return hashtable HealthReport key presence and absence' {

        It 'return hashtable includes HealthReport key on sufficient-data success path' -Tag 'no-gh' {
            # ARRANGE: mock gh returns 6 recent PRs with v2 pipeline-metrics blocks
            # effectiveSampleSize ≈ 6.0 (weight ≈ 1.0 each, mergedAt = today) ≥ 5.0 threshold
            $workDir = Join-Path $script:HRTempRoot ([System.Guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $workDir -Force | Out-Null

            $today = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
            $mockBody = "<!-- pipeline-metrics`nmetrics_version: v2.0`n-->"
            $prs = @(1..6 | ForEach-Object {
                    [ordered]@{ number = $_; mergedAt = $today; body = $mockBody }
                })
            $mockGhPath = & $script:HRWriteMockGh `
                -WorkDir     $workDir `
                -JsonOutput  ($prs | ConvertTo-Json -Depth 3)

            # ACT
            $result = Invoke-AggregateReviewScores `
                -GhCliPath       $mockGhPath `
                -Repo            'test/mockowner' `
                -CalibrationFile (Join-Path $workDir 'no-calib.json')

            # ASSERT
            $result.ContainsKey('HealthReport') | Should -BeTrue `
                -Because 'successful run with sufficient data must return a HealthReport key in the hashtable (Step 1 plumbing)'
        }

        It 'return hashtable does NOT include HealthReport key when gh CLI is not found (ExitCode=1)' -Tag 'no-gh' {
            # ARRANGE: GhCliPath points to a path that does not exist → early ExitCode=1 exit
            $nonExistentGh = Join-Path $script:HRTempRoot 'no-such-subdir\gh.exe'

            # ACT
            $result = Invoke-AggregateReviewScores `
                -GhCliPath $nonExistentGh `
                -Repo      'test/mockowner'

            # ASSERT
            $result.ExitCode | Should -Be 1 `
                -Because 'missing gh CLI must produce ExitCode=1'
            $result.ContainsKey('HealthReport') | Should -BeFalse `
                -Because 'ExitCode=1 error paths must never include a HealthReport key'
        }
    }
}

# ==================================================================
# Describe: Format-HealthReport private function core content (Step 2 #259)
# RED tests — all fail until Format-HealthReport is implemented in core lib.
# All tests are in-process with constructed $Context hashtables; no gh CLI needed.
# ==================================================================
Describe 'Format-HealthReport core content' {

    BeforeAll {
        $script:FHRRepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
        $script:FHRLibFile = Join-Path $script:FHRRepoRoot '.github\scripts\lib\aggregate-review-scores-core.ps1'
        . $script:FHRLibFile

        # ---------------------------------------------------------------
        # Shared valid context used by the majority of tests.
        # Covers all 5 sections: heading, sustain rate, hotspots,
        # prosecution depth, D10 ceiling, systemic patterns.
        # ---------------------------------------------------------------
        $script:FHRValidContext = @{
            OverallSustainRate           = 0.52
            CategoryData                 = @{
                'architecture'           = @{ findings = 10; effectiveCount = 30.0; sustained = 15.5 }
                'security'               = @{ findings = 5; effectiveCount = 12.0; sustained = 6.0 }
                'performance'            = @{ findings = 3; effectiveCount = 8.0; sustained = 4.0 }
                'pattern'                = @{ findings = 2; effectiveCount = 5.0; sustained = 2.5 }
                'implementation-clarity' = @{ findings = 1; effectiveCount = 2.0; sustained = 1.0 }
            }
            ProsecutionDepthState        = @{}
            KnownCategories              = @(
                'architecture', 'security', 'performance', 'pattern',
                'implementation-clarity', 'script-automation', 'documentation-audit'
            )
            ComplexityOverCeilingHistory = @{
                'some-agent.agent.md' = @{
                    consecutive_count = 4
                    first_observed_at = '2026-01-01T00:00:00Z'
                    last_observed_at  = '2026-03-01T00:00:00Z'
                    last_pr_number    = 42
                }
            }
            PersistentThreshold          = 3
            SystemicPatterns             = @{
                'instruction' = @{
                    'architecture' = @{
                        count           = 3
                        sustained_count = 2
                        prs             = [System.Collections.Generic.HashSet[int]]@(10, 11)
                        evidence        = @()
                    }
                }
            }
            KnownSystemicFixTypes        = @('instruction', 'skill', 'agent-prompt', 'plan-template')
            ProposalsEmitted             = @()
            Generated                    = '2026-04-03T12:00:00Z'
            IssuesAnalyzed               = 15
            EffectiveSampleSize          = 42.3
            OlderWindowRate              = $null
            OlderCategoryRates           = $null
        }
    }

    # ------------------------------------------------------------------
    # Test 1: empty context → empty string (defensive early-exit)
    # ------------------------------------------------------------------
    It 'returns empty string for empty context' -Tag 'no-gh' {
        # ARRANGE
        $emptyCtx = @{}

        # ACT
        $result = Format-HealthReport $emptyCtx

        # ASSERT
        $result | Should -BeExactly '' `
            -Because 'empty context must trigger defensive early-exit and return an empty string'
    }

    # ------------------------------------------------------------------
    # Test 2: heading present
    # ------------------------------------------------------------------
    It 'output starts with # Pipeline Health Report heading' -Tag 'no-gh' {
        # ARRANGE
        $ctx = $script:FHRValidContext

        # ACT
        $result = Format-HealthReport $ctx

        # ASSERT
        $result | Should -Match '^# Pipeline Health Report' `
            -Because 'the report must open with the top-level heading # Pipeline Health Report'
    }

    # ------------------------------------------------------------------
    # Test 3: ## Overall Sustain Rate section uses → indicator stub
    # ------------------------------------------------------------------
    It '## Overall Sustain Rate section uses → indicator stub' -Tag 'no-gh' {
        # ARRANGE
        $ctx = $script:FHRValidContext

        # ACT
        $result = Format-HealthReport $ctx

        # ASSERT
        $result | Should -Match '## Overall Sustain Rate' `
            -Because '## Overall Sustain Rate section heading must be present'
        # Capture the section between ## Overall Sustain Rate and the next ## heading
        $sectionMatch = [regex]::Match($result, '(?s)## Overall Sustain Rate(.*?)(?=\n## |\z)')
        $sectionMatch.Success | Should -BeTrue `
            -Because 'regex must match the ## Overall Sustain Rate section'
        $sectionMatch.Value | Should -Match '→' `
            -Because 'ensures flat indicators are returned when OlderWindowRate is null (insufficient temporal data)'
    }

    # ------------------------------------------------------------------
    # Test 4: ## Category Hotspots shows top 3 by effectiveCount
    # ------------------------------------------------------------------
    It '## Category Hotspots shows top 3 categories by effectiveCount' -Tag 'no-gh' {
        # ARRANGE: 5 categories with distinct effectiveCount values
        # Top 3: architecture(30.0) > security(12.0) > performance(8.0)
        # Bottom 2: pattern(5.0), implementation-clarity(2.0)
        $ctx = $script:FHRValidContext

        # ACT
        $result = Format-HealthReport $ctx

        # ASSERT
        $result | Should -Match '## Category Hotspots' `
            -Because '## Category Hotspots section must be present when CategoryData has entries'

        # Capture the hotspot section only (between its heading and the next ##)
        $hotspotSection = [regex]::Match($result, '(?s)## Category Hotspots(.*?)(?=\n## |\z)').Value

        $hotspotSection | Should -Match 'architecture' `
            -Because 'architecture (effectiveCount=30.0, rank 1) must appear in the top-3 hotspot table'
        $hotspotSection | Should -Match 'security' `
            -Because 'security (effectiveCount=12.0, rank 2) must appear in the top-3 hotspot table'
        $hotspotSection | Should -Match 'performance' `
            -Because 'performance (effectiveCount=8.0, rank 3) must appear in the top-3 hotspot table'
        $hotspotSection | Should -Not -Match 'pattern\b' `
            -Because 'pattern (effectiveCount=5.0, rank 4) must NOT appear — only top 3 are shown'
        $hotspotSection | Should -Not -Match 'implementation-clarity' `
            -Because 'implementation-clarity (effectiveCount=2.0, rank 5) must NOT appear — only top 3 are shown'
    }

    # ------------------------------------------------------------------
    # Test 5: ## Prosecution Depth section present
    # ------------------------------------------------------------------
    It '## Prosecution Depth section is present with known categories' -Tag 'no-gh' {
        # ARRANGE
        $ctx = $script:FHRValidContext

        # ACT
        $result = Format-HealthReport $ctx

        # ASSERT
        $result | Should -Match '## Prosecution Depth' `
            -Because '## Prosecution Depth section must always be present when context is valid'
    }

    # ------------------------------------------------------------------
    # Test 6: ## D10 Ceiling Status omitted when history is empty
    # ------------------------------------------------------------------
    It '## D10 Ceiling Status omitted when ComplexityOverCeilingHistory is empty' -Tag 'no-gh' {
        # ARRANGE: clone valid context but clear the ceiling history
        $ctx = $script:FHRValidContext.Clone()
        $ctx['ComplexityOverCeilingHistory'] = @{}

        # ACT
        $result = Format-HealthReport $ctx

        # ASSERT
        $result | Should -Not -Match '## D10 Ceiling Status' `
            -Because '## D10 Ceiling Status must be omitted entirely when no agents are over ceiling'
    }

    # ------------------------------------------------------------------
    # Test 7: ## D10 Ceiling Status present when over-ceiling agent exists
    # ------------------------------------------------------------------
    It '## D10 Ceiling Status present when over-ceiling agent exists' -Tag 'no-gh' {
        # ARRANGE: valid context already has one over-ceiling agent
        $ctx = $script:FHRValidContext

        # ACT
        $result = Format-HealthReport $ctx

        # ASSERT
        $result | Should -Match '## D10 Ceiling Status' `
            -Because '## D10 Ceiling Status must appear when ComplexityOverCeilingHistory contains at least one agent'
    }

    # ------------------------------------------------------------------
    # Test 8: ## Systemic Pattern Alerts omitted when no patterns meet threshold
    # ------------------------------------------------------------------
    It '## Systemic Pattern Alerts omitted when no patterns meet threshold' -Tag 'no-gh' {
        # ARRANGE: clone valid context; give pattern a count below threshold
        # threshold: sustained_count >= 2 AND distinct_prs (prs.Count) >= 2
        $ctx = $script:FHRValidContext.Clone()
        $ctx['SystemicPatterns'] = @{
            'instruction' = @{
                'architecture' = @{
                    count           = 1
                    sustained_count = 1           # below threshold (< 2)
                    prs             = [System.Collections.Generic.HashSet[int]]@(10)  # only 1 PR
                    evidence        = @()
                }
            }
        }

        # ACT
        $result = Format-HealthReport $ctx

        # ASSERT
        $result | Should -Not -Match '## Systemic Pattern Alerts' `
            -Because '## Systemic Pattern Alerts must be omitted when no pattern has sustained_count >= 2 AND distinct_prs >= 2'
    }

    # ------------------------------------------------------------------
    # Test 9: ## Systemic Pattern Alerts present when pattern meets threshold
    # ------------------------------------------------------------------
    It '## Systemic Pattern Alerts present when pattern meets threshold' -Tag 'no-gh' {
        # ARRANGE: valid context has one pattern with sustained_count=2 AND prs.Count=2
        $ctx = $script:FHRValidContext

        # ACT
        $result = Format-HealthReport $ctx

        # ASSERT
        $result | Should -Match '## Systemic Pattern Alerts' `
            -Because '## Systemic Pattern Alerts must appear when at least one pattern has sustained_count >= 2 AND distinct_prs >= 2'
    }

    # ------------------------------------------------------------------
    # Test 10: ## Category Hotspots omitted when CategoryData is empty
    # ------------------------------------------------------------------
    It '## Category Hotspots section omitted when CategoryData is empty' -Tag 'no-gh' {
        # ARRANGE: clone valid context but provide empty CategoryData
        $ctx = $script:FHRValidContext.Clone()
        $ctx['CategoryData'] = @{}

        # ACT
        $result = Format-HealthReport $ctx

        # ASSERT
        $result | Should -Not -Match '## Category Hotspots' `
            -Because '## Category Hotspots section must be omitted entirely when CategoryData is empty'
    }
}

# ==================================================================
# Describe: Directional indicators via temporal split (Step 3 #259)
# RED tests — Tests 1 and 2 fail until temporal split logic is
# implemented. Tests 3 and 4 currently pass (stub always outputs →);
# they become meaningful guards once the implementation is in place.
# All tests use mock gh CLI (companion-data-file pattern). Tag: no-gh.
# ==================================================================
Describe 'Directional indicators via temporal split' {

    BeforeAll {
        $script:TSSRepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
        $script:TSSLibFile = Join-Path $script:TSSRepoRoot '.github\scripts\lib\aggregate-review-scores-core.ps1'
        . $script:TSSLibFile
        $script:TSSTempRoot = Join-Path ([System.IO.Path]::GetTempPath()) `
            "pester-tss-$([System.Guid]::NewGuid().ToString('N'))"
        New-Item -ItemType Directory -Path $script:TSSTempRoot -Force | Out-Null

        # ---------------------------------------------------------------
        # Helper: write a mock gh.ps1 that outputs preset PR JSON.
        # Companion-data-file pattern avoids quoting hazards in the
        # generated script body.
        # ---------------------------------------------------------------
        $script:TSSWriteMockGh = {
            param([string]$WorkDir, [string]$JsonOutput)
            $dataFile = Join-Path $WorkDir 'gh-response.json'
            $mockPath = Join-Path $WorkDir 'gh.ps1'
            $JsonOutput | Set-Content -Path $dataFile -Encoding UTF8
            @"
# Mock gh CLI
Get-Content -Raw -Path '$($dataFile -replace "'", "''")'
exit 0
"@ | Set-Content -Path $mockPath -Encoding UTF8
            return $mockPath
        }

        # ---------------------------------------------------------------
        # Helper: build a PR object for the mock JSON array.
        # ---------------------------------------------------------------
        function New-MockPr {
            param([int]$Number, [string]$MergedAt, [string]$Body)
            return [ordered]@{ number = $Number; mergedAt = $MergedAt; body = $Body }
        }

        # Body with 1 sustained / 2 total per PR → 50% sustain rate.
        # F1: sustained, F2: defense-sustained (counts toward weightedTotal but not weightedAccepted).
        $script:TSSHalfBody = @"
<!-- pipeline-metrics
metrics_version: 2
findings:
  - id: F1
    category: architecture
    judge_ruling: sustained
  - id: F2
    category: security
    judge_ruling: defense-sustained
-->
"@

        # Body with 2 sustained / 2 total per PR → 100% sustain rate.
        $script:TSSFullBody = @"
<!-- pipeline-metrics
metrics_version: 2
findings:
  - id: F1
    category: architecture
    judge_ruling: sustained
  - id: F2
    category: security
    judge_ruling: sustained
-->
"@

        # v1 body: pipeline-metrics block with no metrics_version field.
        # Contributes to effectiveSampleSize but not to prContributions for temporal split.
        $script:TSSV1Body = "<!-- pipeline-metrics`n-->"
    }

    AfterAll {
        Remove-Item -Recurse -Force -Path $script:TSSTempRoot -ErrorAction SilentlyContinue
    }

    # ------------------------------------------------------------------
    # Test 1: 10 PRs with improving trend → ↑ indicator in HealthReport
    # RED: fails until temporal split replaces → stub with ↑
    # ------------------------------------------------------------------
    It '10 PRs with improving trend → ↑ indicator in HealthReport' -Tag 'no-gh' {
        # ARRANGE
        $workDir = Join-Path $script:TSSTempRoot ([System.Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $workDir -Force | Out-Null

        # Old half (PRs 1-5, 12-8 days ago): 50% sustain rate each
        # New half (PRs 6-10, 5-1 days ago): 100% sustain rate each
        # Temporal split gap: 1.0 - 0.5 = 0.5 > 0.05 → ↑
        $prs = @(
            (New-MockPr -Number 1  -MergedAt ([DateTime]::UtcNow.AddDays(-12).ToString('yyyy-MM-ddTHH:mm:ssZ')) -Body $script:TSSHalfBody),
            (New-MockPr -Number 2  -MergedAt ([DateTime]::UtcNow.AddDays(-11).ToString('yyyy-MM-ddTHH:mm:ssZ')) -Body $script:TSSHalfBody),
            (New-MockPr -Number 3  -MergedAt ([DateTime]::UtcNow.AddDays(-10).ToString('yyyy-MM-ddTHH:mm:ssZ')) -Body $script:TSSHalfBody),
            (New-MockPr -Number 4  -MergedAt ([DateTime]::UtcNow.AddDays(-9).ToString('yyyy-MM-ddTHH:mm:ssZ'))  -Body $script:TSSHalfBody),
            (New-MockPr -Number 5  -MergedAt ([DateTime]::UtcNow.AddDays(-8).ToString('yyyy-MM-ddTHH:mm:ssZ'))  -Body $script:TSSHalfBody),
            (New-MockPr -Number 6  -MergedAt ([DateTime]::UtcNow.AddDays(-5).ToString('yyyy-MM-ddTHH:mm:ssZ'))  -Body $script:TSSFullBody),
            (New-MockPr -Number 7  -MergedAt ([DateTime]::UtcNow.AddDays(-4).ToString('yyyy-MM-ddTHH:mm:ssZ'))  -Body $script:TSSFullBody),
            (New-MockPr -Number 8  -MergedAt ([DateTime]::UtcNow.AddDays(-3).ToString('yyyy-MM-ddTHH:mm:ssZ'))  -Body $script:TSSFullBody),
            (New-MockPr -Number 9  -MergedAt ([DateTime]::UtcNow.AddDays(-2).ToString('yyyy-MM-ddTHH:mm:ssZ'))  -Body $script:TSSFullBody),
            (New-MockPr -Number 10 -MergedAt ([DateTime]::UtcNow.AddDays(-1).ToString('yyyy-MM-ddTHH:mm:ssZ'))  -Body $script:TSSFullBody)
        )
        $mockGhPath = & $script:TSSWriteMockGh `
            -WorkDir    $workDir `
            -JsonOutput ($prs | ConvertTo-Json -Depth 3)

        # ACT
        $result = Invoke-AggregateReviewScores `
            -GhCliPath       $mockGhPath `
            -Repo            'test/r' `
            -CalibrationFile (Join-Path $workDir 'no-calib.json')

        # ASSERT
        $result.HealthReport | Should -Match '↑' `
            -Because 'newer half sustain rate (1.0) minus older half (0.5) = 0.5 exceeds 0.05 deadzone; indicator must be ↑'
    }

    # ------------------------------------------------------------------
    # Test 2: 10 PRs with declining trend → ↓ indicator in HealthReport
    # RED: fails until temporal split replaces → stub with ↓
    # ------------------------------------------------------------------
    It '10 PRs with declining trend → ↓ indicator in HealthReport' -Tag 'no-gh' {
        # ARRANGE
        $workDir = Join-Path $script:TSSTempRoot ([System.Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $workDir -Force | Out-Null

        # Old half (PRs 1-5, 12-8 days ago): 100% sustain rate each
        # New half (PRs 6-10, 5-1 days ago): 50% sustain rate each
        # Temporal split gap: 0.5 - 1.0 = -0.5 < -0.05 → ↓
        $prs = @(
            (New-MockPr -Number 1  -MergedAt ([DateTime]::UtcNow.AddDays(-12).ToString('yyyy-MM-ddTHH:mm:ssZ')) -Body $script:TSSFullBody),
            (New-MockPr -Number 2  -MergedAt ([DateTime]::UtcNow.AddDays(-11).ToString('yyyy-MM-ddTHH:mm:ssZ')) -Body $script:TSSFullBody),
            (New-MockPr -Number 3  -MergedAt ([DateTime]::UtcNow.AddDays(-10).ToString('yyyy-MM-ddTHH:mm:ssZ')) -Body $script:TSSFullBody),
            (New-MockPr -Number 4  -MergedAt ([DateTime]::UtcNow.AddDays(-9).ToString('yyyy-MM-ddTHH:mm:ssZ'))  -Body $script:TSSFullBody),
            (New-MockPr -Number 5  -MergedAt ([DateTime]::UtcNow.AddDays(-8).ToString('yyyy-MM-ddTHH:mm:ssZ'))  -Body $script:TSSFullBody),
            (New-MockPr -Number 6  -MergedAt ([DateTime]::UtcNow.AddDays(-5).ToString('yyyy-MM-ddTHH:mm:ssZ'))  -Body $script:TSSHalfBody),
            (New-MockPr -Number 7  -MergedAt ([DateTime]::UtcNow.AddDays(-4).ToString('yyyy-MM-ddTHH:mm:ssZ'))  -Body $script:TSSHalfBody),
            (New-MockPr -Number 8  -MergedAt ([DateTime]::UtcNow.AddDays(-3).ToString('yyyy-MM-ddTHH:mm:ssZ'))  -Body $script:TSSHalfBody),
            (New-MockPr -Number 9  -MergedAt ([DateTime]::UtcNow.AddDays(-2).ToString('yyyy-MM-ddTHH:mm:ssZ'))  -Body $script:TSSHalfBody),
            (New-MockPr -Number 10 -MergedAt ([DateTime]::UtcNow.AddDays(-1).ToString('yyyy-MM-ddTHH:mm:ssZ'))  -Body $script:TSSHalfBody)
        )
        $mockGhPath = & $script:TSSWriteMockGh `
            -WorkDir    $workDir `
            -JsonOutput ($prs | ConvertTo-Json -Depth 3)

        # ACT
        $result = Invoke-AggregateReviewScores `
            -GhCliPath       $mockGhPath `
            -Repo            'test/r' `
            -CalibrationFile (Join-Path $workDir 'no-calib.json')

        # ASSERT
        $result.HealthReport | Should -Match '↓' `
            -Because 'newer half sustain rate (0.5) minus older half (1.0) = -0.5 is below -0.05 deadzone; indicator must be ↓'
    }

    # ------------------------------------------------------------------
    # Test 3: 10 PRs with similar trend → → indicator only in HealthReport
    # Deadzone guard: gap = 0.0 is within ±0.05 so neither ↑ nor ↓ appears.
    # Currently passes (stub outputs →); remains a meaningful guard post-impl.
    # ------------------------------------------------------------------
    It '10 PRs with similar trend → → indicator only in HealthReport' -Tag 'no-gh' {
        # ARRANGE
        $workDir = Join-Path $script:TSSTempRoot ([System.Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $workDir -Force | Out-Null

        # Both halves: 50% sustain rate each
        # Temporal split gap: 0.5 - 0.5 = 0.0, within ±0.05 deadzone → →
        $prs = @(
            (New-MockPr -Number 1  -MergedAt ([DateTime]::UtcNow.AddDays(-12).ToString('yyyy-MM-ddTHH:mm:ssZ')) -Body $script:TSSHalfBody),
            (New-MockPr -Number 2  -MergedAt ([DateTime]::UtcNow.AddDays(-11).ToString('yyyy-MM-ddTHH:mm:ssZ')) -Body $script:TSSHalfBody),
            (New-MockPr -Number 3  -MergedAt ([DateTime]::UtcNow.AddDays(-10).ToString('yyyy-MM-ddTHH:mm:ssZ')) -Body $script:TSSHalfBody),
            (New-MockPr -Number 4  -MergedAt ([DateTime]::UtcNow.AddDays(-9).ToString('yyyy-MM-ddTHH:mm:ssZ'))  -Body $script:TSSHalfBody),
            (New-MockPr -Number 5  -MergedAt ([DateTime]::UtcNow.AddDays(-8).ToString('yyyy-MM-ddTHH:mm:ssZ'))  -Body $script:TSSHalfBody),
            (New-MockPr -Number 6  -MergedAt ([DateTime]::UtcNow.AddDays(-5).ToString('yyyy-MM-ddTHH:mm:ssZ'))  -Body $script:TSSHalfBody),
            (New-MockPr -Number 7  -MergedAt ([DateTime]::UtcNow.AddDays(-4).ToString('yyyy-MM-ddTHH:mm:ssZ'))  -Body $script:TSSHalfBody),
            (New-MockPr -Number 8  -MergedAt ([DateTime]::UtcNow.AddDays(-3).ToString('yyyy-MM-ddTHH:mm:ssZ'))  -Body $script:TSSHalfBody),
            (New-MockPr -Number 9  -MergedAt ([DateTime]::UtcNow.AddDays(-2).ToString('yyyy-MM-ddTHH:mm:ssZ'))  -Body $script:TSSHalfBody),
            (New-MockPr -Number 10 -MergedAt ([DateTime]::UtcNow.AddDays(-1).ToString('yyyy-MM-ddTHH:mm:ssZ'))  -Body $script:TSSHalfBody)
        )
        $mockGhPath = & $script:TSSWriteMockGh `
            -WorkDir    $workDir `
            -JsonOutput ($prs | ConvertTo-Json -Depth 3)

        # ACT
        $result = Invoke-AggregateReviewScores `
            -GhCliPath       $mockGhPath `
            -Repo            'test/r' `
            -CalibrationFile (Join-Path $workDir 'no-calib.json')

        # ASSERT: gap = 0.0, within ±0.05 deadzone → must output → and NOT ↑ or ↓
        $result.HealthReport | Should -Match '→' `
            -Because 'older and newer half sustain rates are equal (0.5 vs 0.5); gap = 0.0 is within ±0.05 deadzone, indicator must be →'
        $result.HealthReport | Should -Not -Match '↑' `
            -Because 'gap = 0.0 is within deadzone; ↑ must not appear in the health report'
        $result.HealthReport | Should -Not -Match '↓' `
            -Because 'gap = 0.0 is within deadzone; ↓ must not appear in the health report'
    }

    # ------------------------------------------------------------------
    # Test 4: Only 3 PRs have findings (< 4 minimum) → all → indicators
    # Count guard: 7 v1 PRs keep effectiveSampleSize ≥ 5.0 so the
    # insufficient-data path is not triggered; only the temporal-split
    # count guard fires (prContributions.Count = 3 < 4 → all →).
    # Currently passes (stub outputs →); remains a meaningful guard post-impl.
    # ------------------------------------------------------------------
    It 'only 3 PRs have findings (fewer than 4) → → indicator only in HealthReport' -Tag 'no-gh' {
        # ARRANGE
        # 7 v1 PRs — contributes to effectiveSampleSize (≈ 7.0) but not to prContributions
        # 3 v2 PRs — prContributions.Count = 3 < 4 minimum for temporal split
        # Total effectiveSampleSize ≈ 10.0 ≥ 5.0 → passes the insufficient-data gate
        $workDir = Join-Path $script:TSSTempRoot ([System.Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $workDir -Force | Out-Null

        $today = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
        $prs = @(
            # 7 v1 PRs — effectiveSampleSize contributors only
            (New-MockPr -Number 1  -MergedAt $today -Body $script:TSSV1Body),
            (New-MockPr -Number 2  -MergedAt $today -Body $script:TSSV1Body),
            (New-MockPr -Number 3  -MergedAt $today -Body $script:TSSV1Body),
            (New-MockPr -Number 4  -MergedAt $today -Body $script:TSSV1Body),
            (New-MockPr -Number 5  -MergedAt $today -Body $script:TSSV1Body),
            (New-MockPr -Number 6  -MergedAt $today -Body $script:TSSV1Body),
            (New-MockPr -Number 7  -MergedAt $today -Body $script:TSSV1Body),
            # 3 v2 PRs with findings — prContributions.Count = 3 < 4 minimum
            (New-MockPr -Number 8  -MergedAt $today -Body $script:TSSFullBody),
            (New-MockPr -Number 9  -MergedAt $today -Body $script:TSSFullBody),
            (New-MockPr -Number 10 -MergedAt $today -Body $script:TSSFullBody)
        )
        $mockGhPath = & $script:TSSWriteMockGh `
            -WorkDir    $workDir `
            -JsonOutput ($prs | ConvertTo-Json -Depth 3)

        # ACT
        $result = Invoke-AggregateReviewScores `
            -GhCliPath       $mockGhPath `
            -Repo            'test/r' `
            -CalibrationFile (Join-Path $workDir 'no-calib.json')

        # ASSERT: count guard — 3 PRs with findings is below the minimum of 4
        # required for a meaningful temporal split, so all indicators must stay →
        $result.HealthReport | Should -Not -Match '↑' `
            -Because 'only 3 PRs have findings (below minimum of 4 for temporal split); ↑ must not appear in health report'
        $result.HealthReport | Should -Not -Match '↓' `
            -Because 'only 3 PRs have findings (below minimum of 4 for temporal split); ↓ must not appear in health report'
    }
}

# ==================================================================
# Describe: Read-only mode and insufficient data handling (Step 4 #259)
# All tests use mock gh CLI (companion-data-file pattern). Tag: no-gh.
# ==================================================================
Describe 'Read-only mode and insufficient data handling' {

    BeforeAll {
        $script:RORepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
        $script:ROLibFile = Join-Path $script:RORepoRoot '.github\scripts\lib\aggregate-review-scores-core.ps1'
        . $script:ROLibFile
        $script:ROTempRoot = Join-Path ([System.IO.Path]::GetTempPath()) `
            "pester-ro-$([System.Guid]::NewGuid().ToString('N'))"
        New-Item -ItemType Directory -Path $script:ROTempRoot -Force | Out-Null

        # ---------------------------------------------------------------
        # Helper: write a mock gh.ps1 that outputs preset PR JSON.
        # Companion-data-file pattern avoids quoting hazards.
        # ---------------------------------------------------------------
        $script:ROWriteMockGh = {
            param([string]$WorkDir, [string]$JsonOutput)
            $dataFile = Join-Path $WorkDir 'gh-response.json'
            $mockPath = Join-Path $WorkDir 'gh.ps1'
            $JsonOutput | Set-Content -Path $dataFile -Encoding UTF8
            @"
# Mock gh CLI
Get-Content -Raw -Path '$($dataFile -replace "'", "''")'
exit 0
"@ | Set-Content -Path $mockPath -Encoding UTF8
            return $mockPath
        }

        # ---------------------------------------------------------------
        # Shared v2 PR body with one architecture sustained finding.
        # Used by Tests 1 and 2 (sufficient-data write-back path).
        # ---------------------------------------------------------------
        $script:ROV2Body = @"
<!-- pipeline-metrics
metrics_version: 2
findings:
  - id: F1
    category: architecture
    judge_ruling: sustained
-->
"@

        # ---------------------------------------------------------------
        # Helper: write a minimal valid calibration JSON with architecture
        # in skip state.  When the run processes architecture findings at
        # effectiveCount < 20, the depth loop clears the catState entry and
        # sets $depthStateChanged = $true — reliably triggering write-back.
        # ---------------------------------------------------------------
        $script:ROWriteCalibFile = {
            param([string]$FilePath)
            @{
                calibration_version     = 1
                entries                 = @()
                prosecution_depth_state = @{
                    architecture = @{ skip_first_observed_at = '2026-01-01T00:00:00Z' }
                }
            } | ConvertTo-Json -Depth 5 | Set-Content -Path $FilePath -Encoding UTF8
        }
    }

    AfterAll {
        Remove-Item -Recurse -Force -Path $script:ROTempRoot -ErrorAction SilentlyContinue
    }

    # ------------------------------------------------------------------
    # Test 1: -HealthReport suppresses all calibration file writes
    # ------------------------------------------------------------------
    It '-HealthReport switch suppresses all calibration file writes' -Tag 'no-gh' {
        # ARRANGE
        $workDir = Join-Path $script:ROTempRoot ([System.Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $workDir -Force | Out-Null
        $calibFilePath = Join-Path $workDir 'calib.json'
        & $script:ROWriteCalibFile -FilePath $calibFilePath

        $today = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
        $prs = @(1..6 | ForEach-Object {
                [ordered]@{ number = $_; mergedAt = $today; body = $script:ROV2Body }
            })
        $mockGhPath = & $script:ROWriteMockGh -WorkDir $workDir -JsonOutput ($prs | ConvertTo-Json -Depth 3)

        $bytesBefore = [System.IO.File]::ReadAllBytes($calibFilePath)

        # ACT
        $result = Invoke-AggregateReviewScores `
            -GhCliPath       $mockGhPath `
            -Repo            'test/r' `
            -CalibrationFile $calibFilePath `
            -HealthReport

        # ASSERT
        $result.ExitCode | Should -Be 0 `
            -Because 'read-only mode must still complete successfully (ExitCode=0)'
        $bytesAfter = [System.IO.File]::ReadAllBytes($calibFilePath)
        ($bytesBefore -join ',') | Should -Be ($bytesAfter -join ',') `
            -Because '-HealthReport must suppress all calibration writes (read-only mode D-259-15)'
    }

    # ------------------------------------------------------------------
    # Test 2: normal mode (no -HealthReport) returns ExitCode 0, emits YAML output,
    # and writes back the calibration file.
    # Makes Test 1 meaningful — demonstrates write-back fires in normal mode.
    # ------------------------------------------------------------------
    It 'normal mode (no -HealthReport) returns ExitCode 0 and emits YAML output' -Tag 'no-gh' {
        # ARRANGE
        $workDir = Join-Path $script:ROTempRoot ([System.Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $workDir -Force | Out-Null
        $calibFilePath = Join-Path $workDir 'calib.json'
        & $script:ROWriteCalibFile -FilePath $calibFilePath

        $today = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
        $prs = @(1..6 | ForEach-Object {
                [ordered]@{ number = $_; mergedAt = $today; body = $script:ROV2Body }
            })
        $mockGhPath = & $script:ROWriteMockGh -WorkDir $workDir -JsonOutput ($prs | ConvertTo-Json -Depth 3)

        $bytesBefore = [System.IO.File]::ReadAllBytes($calibFilePath)

        # ACT: no -HealthReport (normal write mode)
        $result = Invoke-AggregateReviewScores `
            -GhCliPath       $mockGhPath `
            -Repo            'test/r' `
            -CalibrationFile $calibFilePath

        # ASSERT
        $result.ExitCode | Should -Be 0 `
            -Because 'normal mode must complete successfully (ExitCode=0)'
        $result.Output | Should -Match 'prosecution_depth:' `
            -Because 'normal mode with sufficient data must emit prosecution_depth section in YAML output'
        $bytesAfter = [System.IO.File]::ReadAllBytes($calibFilePath)
        ($bytesAfter | Compare-Object $bytesBefore).Count | Should -BeGreaterThan 0 `
            -Because 'write-back must fire in normal (non-HealthReport) mode'
    }

    # ------------------------------------------------------------------
    # Test 3: insufficient data returns HealthReport with the required message
    # ------------------------------------------------------------------
    It 'insufficient data returns HealthReport with Insufficient data message' -Tag 'no-gh' {
        # ARRANGE: 1 PR from year 2000 — weight ≈ exp(-0.023 * 9490) ≈ 0
        # effectiveSampleSize ≈ 0 < 5.0 → triggers the insufficient-data early return
        $workDir = Join-Path $script:ROTempRoot ([System.Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $workDir -Force | Out-Null

        $ancientBody = @"
<!-- pipeline-metrics
metrics_version: 2
findings:
  - id: F1
    category: architecture
    judge_ruling: sustained
-->
"@
        $prs = @([ordered]@{ number = 1; mergedAt = '2000-01-01T00:00:00Z'; body = $ancientBody })
        $mockGhPath = & $script:ROWriteMockGh -WorkDir $workDir -JsonOutput ($prs | ConvertTo-Json -Depth 3)

        # ACT
        $result = Invoke-AggregateReviewScores `
            -GhCliPath       $mockGhPath `
            -Repo            'test/r' `
            -CalibrationFile (Join-Path $workDir 'no-calib.json')

        # ASSERT
        $result.ExitCode | Should -Be 0 `
            -Because 'insufficient-data path must return ExitCode=0'
        $result.HealthReport | Should -Match '# Pipeline Health Report' `
            -Because 'insufficient-data HealthReport must open with the # Pipeline Health Report heading'
        $result.HealthReport | Should -Match 'Insufficient data' `
            -Because 'insufficient-data HealthReport must contain the "Insufficient data: {N:.2f} effective issues" message (D-259-15)'
    }

    # ------------------------------------------------------------------
    # Test 4: zero merged PRs returns HealthReport with the required message
    # ------------------------------------------------------------------
    It 'zero merged PRs returns HealthReport with No data message' -Tag 'no-gh' {
        # ARRANGE: mock gh returns [] → $mergedPRs.Count -eq 0 → early return before per-PR loop
        $workDir = Join-Path $script:ROTempRoot ([System.Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $workDir -Force | Out-Null
        $mockGhPath = & $script:ROWriteMockGh -WorkDir $workDir -JsonOutput '[]'

        # ACT
        $result = Invoke-AggregateReviewScores `
            -GhCliPath       $mockGhPath `
            -Repo            'test/r' `
            -CalibrationFile (Join-Path $workDir 'no-calib.json')

        # ASSERT
        $result.ExitCode | Should -Be 0 `
            -Because 'zero-PRs path must return ExitCode=0'
        $result.HealthReport | Should -Match '# Pipeline Health Report' `
            -Because 'zero-PRs HealthReport must open with the # Pipeline Health Report heading'
        $result.HealthReport | Should -Match 'No data' `
            -Because 'zero-PRs HealthReport must contain the "No data: no merged PRs found." message (D-259-15)'
    }
}
