#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

Describe 'Invoke-FrameBackDerive' {

    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
        $script:LibFile = Join-Path $script:RepoRoot '.github\scripts\lib\frame-back-derive-core.ps1'
        $script:FixtureDir = Join-Path $PSScriptRoot 'fixtures'
        $script:AuditFixtureDir = Join-Path $script:RepoRoot 'frame\audit-fixtures'
        $script:PortsDir = Join-Path $script:RepoRoot 'frame\ports'

        if (Test-Path $script:LibFile) {
            . $script:LibFile
        }

        $script:VersionFixtures = @(
            @{ MetricsVersion = '1'; PrNumber = 286; FixtureFile = 'frame-pr-286-v1.json' }
            @{ MetricsVersion = '2'; PrNumber = 338; FixtureFile = 'frame-pr-338-v2.json' }
            @{ MetricsVersion = '3'; PrNumber = 415; FixtureFile = 'frame-pr-415-v3.json' }
            @{ MetricsVersion = '4'; PrNumber = 411; FixtureFile = 'frame-pr-411-v4.json' }
        )

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
            param([int]$PrNumber)

            return (Join-Path $script:AuditFixtureDir ("pr-{0}.expected.yaml" -f $PrNumber))
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

    It 'replays metrics_version <MetricsVersion> fixture input for PR <PrNumber>' -ForEach $script:VersionFixtures {
        param($MetricsVersion, $PrNumber, $FixtureFile)

        $workDir = & $script:NewWorkDir
        $fixturePath = Join-Path $script:FixtureDir $FixtureFile
        $expectedLedgerPath = & $script:GetExpectedLedgerPath -PrNumber $PrNumber
        $ghPath = & $script:WriteMockGh -WorkDir $workDir -FixturePath $fixturePath

        $result = & $script:Invoke @{
            Repo         = 'Grimblaz/agent-orchestra'
            PrNumber     = $PrNumber
            OutputFormat = 'yaml'
            GhCliPath    = $ghPath
            PortsDir     = $script:PortsDir
            CacheDir     = (Join-Path $workDir 'cache')
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

    It 'keeps post-pr inconclusive when the fixture only proves merge state' -ForEach $script:VersionFixtures {
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

        $postPr.status | Should -Be 'inconclusive'
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

            $result.ExitCode | Should -Be 0
        }
    }
}
