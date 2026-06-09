#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeDiscovery {
    # Must be defined at discovery time so ForEach can consume the arrays.
    $script:VersionFixtures = @(
        @{ MetricsVersion = '1'; PrNumber = 286; FixtureFile = 'frame-pr-286-v1.json' }
        @{ MetricsVersion = '2'; PrNumber = 338; FixtureFile = 'frame-pr-338-v2.json' }
        @{ MetricsVersion = '3'; PrNumber = 415; FixtureFile = 'frame-pr-415-v3.json' }
        @{ MetricsVersion = '4'; PrNumber = 411; FixtureFile = 'frame-pr-411-v4.json' }
    )

    $script:SyntheticFixtures = @(
        @{ FixtureKey = 'V4-review-only';                       FixtureFile = 'frame-pr-V4-review-only.json';                       PrNumber = 9001; Label = 'D9 additive-merge: review pre-populated, 11 ports back-derived' }
        @{ FixtureKey = 'docs-only-synthetic';                  FixtureFile = 'frame-pr-docs-only-synthetic.json';                  PrNumber = 9002; Label = 'docs-only PR: implement-code/test/refactor not-applicable, implement-docs passed, ce-gate-* not-applicable' }
        @{ FixtureKey = 'cegate-orchestration-crash-synthetic'; FixtureFile = 'frame-pr-cegate-orchestration-crash-synthetic.json'; PrNumber = 9003; Label = 'CE Gate orchestration crash: 2 surfaces passed/inconclusive, 2 surfaces block_kind:orchestration' }
        @{ FixtureKey = 'synthetic-backfill-preloaded';         FixtureFile = 'frame-pr-synthetic-backfill-preloaded.json';         PrNumber = 9004; Label = 'D9 round-trip: pre-populated synthetic-backfill row with block_kind preserved as-is, remaining 15 ports back-derived' }
    )
}

Describe 'Invoke-FrameBackDerive' {

    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
        $script:LibFile = Join-Path $script:RepoRoot '.github/scripts/lib/frame-back-derive-core.ps1'
        $script:FixtureDir = Join-Path $PSScriptRoot 'fixtures'
        $script:AuditFixtureDir = Join-Path $script:RepoRoot 'frame/audit-fixtures'
        $script:PortsDir = Join-Path $script:RepoRoot 'frame/ports'

        if (Test-Path $script:LibFile) {
            . $script:LibFile
        }

        $script:TempRoot = Join-Path ([System.IO.Path]::GetTempPath()) "pester-frame-back-derive-$([System.Guid]::NewGuid().ToString('N'))"
        New-Item -ItemType Directory -Path $script:TempRoot -Force | Out-Null

        $script:NewWorkDir = {
            $dir = Join-Path $script:TempRoot ([System.Guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            return $dir
        }

        $script:WriteMockGh = {
            param(
                [string]$WorkDir,
                [string]$FixturePath
            )

            $fixture = Get-Content -Raw -Path $FixturePath | ConvertFrom-Json
            $fixtureFile = Join-Path $WorkDir 'frame-pr-view.json'
            $fixture | ConvertTo-Json -Depth 10 | Set-Content -Path $fixtureFile -Encoding UTF8

            $mockPath = Join-Path $WorkDir 'gh.ps1'
            @"
param()
if (`$args.Count -ge 2 -and `$args[0] -eq 'repo' -and `$args[1] -eq 'view') {
    Write-Output '{"nameWithOwner":"Grimblaz/agent-orchestra"}'
    exit 0
}
if (`$args.Count -ge 3 -and `$args[0] -eq 'pr' -and `$args[1] -eq 'view') {
    Get-Content -Raw -Path '$($fixtureFile -replace "'", "''")'
    exit 0
}
Write-Error "Mock gh: unsupported command `$($args -join ' ')"
exit 99
"@ | Set-Content -Path $mockPath -Encoding UTF8

            return $mockPath
        }

        $script:RequireImplementation = {
            if (-not (Test-Path $script:LibFile)) {
                Set-ItResult -Skipped -Because 'frame-back-derive core library not implemented yet'
                return $false
            }

            if (-not (Get-Command Invoke-FrameBackDerive -ErrorAction SilentlyContinue)) {
                throw 'Missing implementation: Invoke-FrameBackDerive was not exported from frame-back-derive-core.ps1'
            }

            return $true
        }

        $script:Invoke = {
            param([hashtable]$Params)

            if (-not (& $script:RequireImplementation)) {
                return $null
            }

            return Invoke-FrameBackDerive @Params
        }

        $script:GetExpectedLedgerPath = {
            param([string]$Key)

            return (Join-Path $script:AuditFixtureDir ("pr-{0}.expected.yaml" -f $Key))
        }

        $script:NormalizeMultiline = {
            param([string]$Text)

            if ($null -eq $Text) {
                return ''
            }

            return (($Text -replace "`r`n", "`n" -replace "`r", "`n").TrimEnd())
        }
    }

    AfterAll {
        if (Test-Path $script:TempRoot) {
            Remove-Item -Recurse -Force -Path $script:TempRoot -ErrorAction SilentlyContinue
        }
    }

    It 'ships the in-process frame-back-derive core library' {
        $script:LibFile | Should -Exist
    }

    It 'parses successful gh JSON stdout when stderr contains a warning' {
        $workDir = & $script:NewWorkDir
        $mockPath = Join-Path $workDir 'gh-warning.ps1'
        @"
param()
if (`$args.Count -ge 1 -and `$args[0] -eq 'json') {
    `$ErrorActionPreference = 'Continue'
    Write-Error 'gh warning on stderr'
    Write-Output '{"ok":true,"number":451}'
    exit 0
}
Write-Error "Mock gh: unsupported command `$(`$args -join ' ')"
exit 99
"@ | Set-Content -Path $mockPath -Encoding UTF8

        $response = Get-FBDGitHubJson -GhCliPath $mockPath -Arguments @('json') -Context 'mock gh warning'

        $response['ok'] | Should -Be $true
        $response['number'] | Should -Be 451
    }

    It 'labels experience evidence with PR body fallback for metrics_version <MetricsVersion>' -ForEach @(
        @{ MetricsVersion = '1' }
        @{ MetricsVersion = '2' }
        @{ MetricsVersion = '3' }
        @{ MetricsVersion = '4' }
    ) {
        param($MetricsVersion)

        $credit = Get-FBDPortCredit -Port 'experience' -MetricsVersion $MetricsVersion -LinkedIssue ([ordered]@{
                Number = 123
                Source = 'pr-body'
            }) -MetricsBlock ("metrics_version: {0}" -f $MetricsVersion)

        $credit.status | Should -Be 'passed'
        $credit.evidence | Should -Match 'PR body fallback'
        $credit.evidence | Should -Not -Match 'closingIssuesReferences'
    }

    It 'keeps review inconclusive when a v4 metrics block omits stages_run' {
        $credit = Get-FBDPortCredit -Port 'review' -MetricsVersion '4' -MetricsBlock @'
metrics_version: 4
issue_number: 447
'@

        $credit.status | Should -Be 'inconclusive'
        $credit.evidence | Should -Match 'does not encode enough review detail'
    }

    It 'round-trips positive terminal-step-id through back-derived audit YAML' {
        $surface = [ordered]@{
            frame_version    = 1
            credits          = @(
                [ordered]@{
                    port               = 'implement-test'
                    status             = 'failed'
                    'terminal-step-id' = 5
                    evidence           = 'terminal cycle failed'
                }
            )
            integrity_checks = @(
                [ordered]@{
                    name     = 'marker-presence'
                    status   = 'passed'
                    evidence = 'marker present'
                }
            )
        }

        $yaml = ConvertTo-FBDAuditYaml -AuditSurface $surface
        $roundTripCredits = Get-FBDExistingCredits -MetricsBlock $yaml

        $yaml | Should -Match '(?m)^    terminal-step-id:\s*5\s*$'
        $roundTripCredits.Contains('implement-test|5') | Should -BeTrue
        $roundTripCredits['implement-test|5']['terminal-step-id'] | Should -Be 5
    }

    It 'replays metrics_version <MetricsVersion> fixture input for PR <PrNumber>' -ForEach $script:VersionFixtures {
        param($MetricsVersion, $PrNumber, $FixtureFile)

        $workDir = & $script:NewWorkDir
        $fixturePath = Join-Path $script:FixtureDir $FixtureFile
        $expectedLedgerPath = & $script:GetExpectedLedgerPath -Key ([string]$PrNumber)
        $ghPath = & $script:WriteMockGh -WorkDir $workDir -FixturePath $fixturePath

        $result = & $script:Invoke @{
            Repo         = 'Grimblaz/agent-orchestra'
            PrNumber     = $PrNumber
            OutputFormat = 'yaml'
            GhCliPath    = $ghPath
            PortsDir     = $script:PortsDir
            CacheDir     = (Join-Path $workDir 'cache')
            BackfilledAt = '2026-05-02T00:00:00Z'
        }

        if ($null -eq $result) {
            return
        }

        $expectedLedgerPath | Should -Exist
        $result.ExitCode | Should -Be 0 -Because "metrics_version $MetricsVersion should be accepted as historical input"
        (& $script:NormalizeMultiline -Text $result.Output) | Should -BeExactly (& $script:NormalizeMultiline -Text (Get-Content -Raw -Path $expectedLedgerPath))
    }

    It 'keeps design and plan inconclusive when only linked-issue evidence exists for metrics_version <MetricsVersion>' -ForEach ($script:VersionFixtures | Where-Object { $_.MetricsVersion -in @('2', '3', '4') }) {
        param($MetricsVersion, $PrNumber, $FixtureFile)

        $workDir = & $script:NewWorkDir
        $fixturePath = Join-Path $script:FixtureDir $FixtureFile
        $ghPath = & $script:WriteMockGh -WorkDir $workDir -FixturePath $fixturePath

        $result = & $script:Invoke @{
            Repo         = 'Grimblaz/agent-orchestra'
            PrNumber     = $PrNumber
            OutputFormat = 'json'
            GhCliPath    = $ghPath
            PortsDir     = $script:PortsDir
            CacheDir     = (Join-Path $workDir 'cache')
        }

        if ($null -eq $result) {
            return
        }

        $result.ExitCode | Should -Be 0
        $audit = $result.Output | ConvertFrom-Json -AsHashtable
        $experience = @($audit.credits | Where-Object { $_.port -eq 'experience' })[0]
        $design = @($audit.credits | Where-Object { $_.port -eq 'design' })[0]
        $plan = @($audit.credits | Where-Object { $_.port -eq 'plan' })[0]

        $experience.status | Should -Be 'passed'
        $design.status | Should -Be 'inconclusive'
        $plan.status | Should -Be 'inconclusive'
        $design.evidence | Should -Match 'issue linkage alone does not confirm design completion'
        $plan.evidence | Should -Match 'issue linkage alone does not confirm plan completion'
    }

    It 'keeps post-pr skipped when the fixture only proves merge state (D5 — no inconclusive for implement/post-pr)' -ForEach $script:VersionFixtures {
        param($MetricsVersion, $PrNumber, $FixtureFile)

        $workDir = & $script:NewWorkDir
        $fixturePath = Join-Path $script:FixtureDir $FixtureFile
        $ghPath = & $script:WriteMockGh -WorkDir $workDir -FixturePath $fixturePath

        $result = & $script:Invoke @{
            Repo         = 'Grimblaz/agent-orchestra'
            PrNumber     = $PrNumber
            OutputFormat = 'json'
            GhCliPath    = $ghPath
            PortsDir     = $script:PortsDir
            CacheDir     = (Join-Path $workDir 'cache')
        }

        if ($null -eq $result) {
            return
        }

        $result.ExitCode | Should -Be 0
        $audit = $result.Output | ConvertFrom-Json -AsHashtable
        $postPr = @($audit.credits | Where-Object { $_.port -eq 'post-pr' })[0]

        $postPr.status | Should -Be 'skipped' -Because 'D5 (issue #442): post-pr uses skipped, not inconclusive, when no checklist evidence exists'
        $postPr.evidence | Should -Match 'merge state alone does not confirm post-PR cleanup and archival completion'
    }

    It 'supports a live replay shape for historical PRs' -Tag 'requires-gh' {
        if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
            Set-ItResult -Skipped -Because 'gh CLI not found'
            return
        }

        if (-not (& $script:RequireImplementation)) {
            return
        }

        $workDir = & $script:NewWorkDir
        foreach ($prNumber in @(411, 415, 286, 338)) {
            $result = & $script:Invoke @{
                Repo         = 'Grimblaz/agent-orchestra'
                PrNumber     = $prNumber
                OutputFormat = 'json'
                GhCliPath    = 'gh'
                PortsDir     = $script:PortsDir
                CacheDir     = (Join-Path $workDir ('cache-' + $prNumber))
                NoCache      = $true
            }

            $result.ExitCode | Should -Be 0 -Because "PR #$prNumber should derive cleanly. Error: $($result.Error)"
        }
    }

    It 'replays synthetic fixture <FixtureKey> byte-equivalent to expected YAML (D9 additive-merge, AC2/AC4/AC5)' -ForEach $script:SyntheticFixtures {
        param($FixtureKey, $FixtureFile, $PrNumber, $Label)

        if (-not (& $script:RequireImplementation)) { return }

        $workDir = & $script:NewWorkDir
        $fixturePath = Join-Path $script:FixtureDir $FixtureFile
        $expectedLedgerPath = & $script:GetExpectedLedgerPath -Key $FixtureKey
        $ghPath = & $script:WriteMockGh -WorkDir $workDir -FixturePath $fixturePath

        $result = & $script:Invoke @{
            Repo         = 'Grimblaz/agent-orchestra'
            PrNumber     = $PrNumber
            OutputFormat = 'yaml'
            GhCliPath    = $ghPath
            PortsDir     = $script:PortsDir
            CacheDir     = (Join-Path $workDir 'cache')
            BackfilledAt = '2026-05-02T00:00:00Z'
        }

        if ($null -eq $result) { return }

        $expectedLedgerPath | Should -Exist -Because "expected fixture for $FixtureKey must exist"
        $result.ExitCode | Should -Be 0 -Because "$Label — ExitCode: $($result.ExitCode) Error: $($result.Error)"
        (& $script:NormalizeMultiline -Text $result.Output) | Should -BeExactly (& $script:NormalizeMultiline -Text (Get-Content -Raw -Path $expectedLedgerPath)) `
            -Because $Label
    }
}
