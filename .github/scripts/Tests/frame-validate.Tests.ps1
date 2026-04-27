#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
.SYNOPSIS
    Pester 5 unit tests for frame validator checks.

.DESCRIPTION
    Contract under test:
      Test-FVAdapterSymmetry verifies adapter provides declarations against
      frame/ports/*.yaml filename stems, with a graceful informational pass
      when the port catalog is absent.

            Test-FVPredicateParse verifies applies-when predicates are parseable.
            Invoke-FrameValidate contract tests exercise aggregate behavior across
            the checks. Quick-validate integration tests belong to a later plan step.
#>

Describe 'Frame validator check functions' -Tag 'unit' {

    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
        $script:LibFile = Join-Path $script:RepoRoot '.github\scripts\lib\frame-validate-core.ps1'
        . $script:LibFile

        $script:AssertCheckResult = {
            param(
                [Parameter(Mandatory)]$Result,
                [Parameter(Mandatory)][string]$ExpectedName
            )

            $Result | Should -Not -BeNullOrEmpty
            $propertyNames = @($Result.PSObject.Properties | Select-Object -ExpandProperty Name)
            ($propertyNames -join ',') | Should -Be 'Name,Passed,Detail'
            $Result.Name | Should -Be $ExpectedName
            ($Result.Passed -is [bool]) | Should -BeTrue
            ($Result.Detail -is [string]) | Should -BeTrue
        }

        $script:AssertAggregateResult = {
            param(
                [Parameter(Mandatory)]$Result,
                [Parameter(Mandatory)][int]$ExpectedPassCount,
                [Parameter(Mandatory)][int]$ExpectedFailCount,
                [Parameter(Mandatory)][int]$ExpectedExitCode
            )

            $Result | Should -Not -BeNullOrEmpty
            $propertyNames = @($Result.PSObject.Properties | Select-Object -ExpandProperty Name)
            ($propertyNames -join ',') | Should -Be 'Results,PassCount,FailCount,TotalCount,ExitCode'
            @($Result.Results) | Should -HaveCount 2
            @($Result.Results | Select-Object -ExpandProperty Name) | Should -Be @('AdapterSymmetry', 'PredicateParse')
            $Result.PassCount | Should -Be $ExpectedPassCount
            $Result.FailCount | Should -Be $ExpectedFailCount
            $Result.TotalCount | Should -Be 2
            $Result.ExitCode | Should -Be $ExpectedExitCode
        }

        $script:NewFrameValidateFixture = {
            param(
                [string]$Root = "TestDrive:\fv-$([System.Guid]::NewGuid().ToString('N'))",
                [string[]]$Ports = @('experience', 'review'),
                [switch]$WithoutPortCatalog
            )

            $agentsDir = Join-Path $Root 'agents'
            $skillDir = Join-Path $Root 'skills\test-skill'
            $commandsDir = Join-Path $Root 'commands'

            New-Item -ItemType Directory -Path $agentsDir -Force | Out-Null
            New-Item -ItemType Directory -Path $skillDir -Force | Out-Null
            New-Item -ItemType Directory -Path $commandsDir -Force | Out-Null

            if (-not $WithoutPortCatalog) {
                $portsDir = Join-Path $Root 'frame\ports'
                New-Item -ItemType Directory -Path $portsDir -Force | Out-Null

                foreach ($port in $Ports) {
                    Set-Content -Path (Join-Path $portsDir "$port.yaml") -Value "description: $port" -Encoding utf8NoBOM
                }
            }

            Set-Content -Path (Join-Path $skillDir 'SKILL.md') -Value @'
---
name: test-skill
description: Test skill. Use when validating frame fixtures. DO NOT USE FOR: production.
---

# Test Skill

## Gotchas

None.
'@ -Encoding utf8NoBOM

            return $Root
        }

        $script:AddFrameAdapter = {
            param(
                [Parameter(Mandatory)][string]$Root,
                [Parameter(Mandatory)][string]$RelativePath,
                [string[]]$Provides = @(),
                [string[]]$AppliesWhen = @()
            )

            $path = Join-Path $Root $RelativePath
            New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null

            $lines = [System.Collections.Generic.List[string]]::new()
            $lines.Add('---')
            $lines.Add('name: frame-fixture-adapter')
            $lines.Add('description: Frame validator fixture adapter.')

            if ($Provides.Count -gt 0) {
                $lines.Add('provides:')
                foreach ($providedPort in $Provides) {
                    $lines.Add("  - $providedPort")
                }
            }

            foreach ($predicate in $AppliesWhen) {
                $lines.Add("applies-when: $predicate")
            }

            $lines.Add('---')
            $lines.Add('')
            $lines.Add('# Fixture Adapter')

            Set-Content -Path $path -Value ($lines.ToArray() -join [Environment]::NewLine) -Encoding utf8NoBOM
            return $path
        }
    }

    It 'ships the in-process frame validator library' {
        $script:LibFile | Should -Exist
        Get-Command Test-FVAdapterSymmetry -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        Get-Command Test-FVPredicateParse -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }

    Context 'Test-FVAdapterSymmetry' {

        It 'passes a clean adapter state' {
            $root = & $script:NewFrameValidateFixture
            & $script:AddFrameAdapter -Root $root -RelativePath 'agents\valid.agent.md' -Provides @('experience', 'review') | Out-Null

            $result = Test-FVAdapterSymmetry -RootPath $root

            & $script:AssertCheckResult -Result $result -ExpectedName 'AdapterSymmetry'
            $result.Passed | Should -BeTrue
            $result.Detail | Should -Be ''
        }

        It 'fails a single dangling provides declaration' {
            $root = & $script:NewFrameValidateFixture -Ports @('experience')
            & $script:AddFrameAdapter -Root $root -RelativePath 'agents\bad.agent.md' -Provides @('typo-port') | Out-Null

            $result = Test-FVAdapterSymmetry -RootPath $root

            & $script:AssertCheckResult -Result $result -ExpectedName 'AdapterSymmetry'
            $result.Passed | Should -BeFalse
            $result.Detail | Should -Match '1 invalid provides declaration'
            $result.Detail | Should -Match 'agents/bad\.agent\.md'
            $result.Detail | Should -Match "provides 'typo-port'"
            $result.Detail | Should -Match 'valid ports: experience'
        }

        It 'fails multiple dangling provides declarations across adapter surfaces' {
            $root = & $script:NewFrameValidateFixture -Ports @('experience', 'review')
            & $script:AddFrameAdapter -Root $root -RelativePath 'agents\bad-agent.agent.md' -Provides @('missing-agent-port') | Out-Null
            & $script:AddFrameAdapter -Root $root -RelativePath 'skills\test-skill\SKILL.md' -Provides @('missing-skill-port') | Out-Null
            & $script:AddFrameAdapter -Root $root -RelativePath 'commands\bad-command.md' -Provides @('missing-command-port') | Out-Null

            $result = Test-FVAdapterSymmetry -RootPath $root

            & $script:AssertCheckResult -Result $result -ExpectedName 'AdapterSymmetry'
            $result.Passed | Should -BeFalse
            $result.Detail | Should -Match '3 invalid provides declaration'
            $result.Detail | Should -Match 'agents/bad-agent\.agent\.md'
            $result.Detail | Should -Match 'missing-agent-port'
            $result.Detail | Should -Match 'skills/test-skill/SKILL\.md'
            $result.Detail | Should -Match 'missing-skill-port'
            $result.Detail | Should -Match 'commands/bad-command\.md'
            $result.Detail | Should -Match 'missing-command-port'
        }

        It 'passes with informational detail when the frame port catalog is absent' {
            $root = & $script:NewFrameValidateFixture -WithoutPortCatalog
            & $script:AddFrameAdapter -Root $root -RelativePath 'agents\dangling.agent.md' -Provides @('anything') | Out-Null

            $result = Test-FVAdapterSymmetry -RootPath $root

            & $script:AssertCheckResult -Result $result -ExpectedName 'AdapterSymmetry'
            $result.Passed | Should -BeTrue
            $result.Detail | Should -Match 'frame/ports missing'
            $result.Detail | Should -Match 'adapter symmetry skipped'
        }
    }

    Context 'Test-FVPredicateParse' {

        It 'passes well-formed predicates from adapter frontmatter' {
            $root = & $script:NewFrameValidateFixture
            & $script:AddFrameAdapter -Root $root -RelativePath 'agents\predicate-agent.agent.md' -AppliesWhen @("port == 'experience' AND score >= 2") | Out-Null
            & $script:AddFrameAdapter -Root $root -RelativePath 'skills\test-skill\SKILL.md' -AppliesWhen @("NOT adapter.kind == 'deprecated'") | Out-Null
            & $script:AddFrameAdapter -Root $root -RelativePath 'commands\predicate-command.md' -AppliesWhen @("port in ['experience', 'review']") | Out-Null

            $result = Test-FVPredicateParse -RootPath $root

            & $script:AssertCheckResult -Result $result -ExpectedName 'PredicateParse'
            $result.Passed | Should -BeTrue
            $result.Detail | Should -Be ''
        }

        It 'fails a malformed predicate for <Case>' -ForEach @(
            @{
                Case      = 'trailing operator'
                Predicate = "port == 'experience' AND"
            }
            @{
                Case      = 'unbalanced parens'
                Predicate = "(port == 'experience'"
            }
            @{
                Case      = 'missing right-hand side'
                Predicate = 'port =='
            }
            @{
                Case      = 'double operator'
                Predicate = "port == == 'experience'"
            }
            @{
                Case      = 'consecutive operator'
                Predicate = "port == 'experience' AND OR status == 'stable'"
            }
        ) {
            param($Case, $Predicate)

            $root = & $script:NewFrameValidateFixture
            & $script:AddFrameAdapter -Root $root -RelativePath 'agents\bad-predicate.agent.md' -AppliesWhen @($Predicate) | Out-Null

            $result = Test-FVPredicateParse -RootPath $root

            & $script:AssertCheckResult -Result $result -ExpectedName 'PredicateParse'
            $result.Passed | Should -BeFalse
            $result.Detail | Should -Match '1 applies-when parse error'
            $result.Detail | Should -Match 'agents/bad-predicate\.agent\.md'
            $result.Detail | Should -Match ([regex]::Escape($Predicate))
            $result.Detail | Should -Match 'parse error at position'
        }
    }

    Context 'Invoke-FrameValidate' {

        It 'passes against the current repository state in symmetry-only mode' {
            $result = Invoke-FrameValidate -RootPath $script:RepoRoot

            & $script:AssertAggregateResult -Result $result -ExpectedPassCount 2 -ExpectedFailCount 0 -ExpectedExitCode 0
            foreach ($check in @($result.Results)) {
                & $script:AssertCheckResult -Result $check -ExpectedName $check.Name
                $check.Passed | Should -BeTrue
                $check.Detail | Should -Be ''
            }
        }

        It 'aggregates invalid provides declarations and malformed predicates from a post-428 adapter fixture' {
            $root = & $script:NewFrameValidateFixture -Ports @('experience', 'review', 'implement-code')
            & $script:AddFrameAdapter -Root $root -RelativePath 'agents\valid.agent.md' -Provides @('experience') -AppliesWhen @("port == 'experience'") | Out-Null
            & $script:AddFrameAdapter -Root $root -RelativePath 'agents\typo-provides.agent.md' -Provides @('experiense') -AppliesWhen @("port == 'experience'") | Out-Null
            & $script:AddFrameAdapter -Root $root -RelativePath 'commands\nonexistent-port.md' -Provides @('future-only-port') | Out-Null
            & $script:AddFrameAdapter -Root $root -RelativePath 'skills\test-skill\SKILL.md' -Provides @('review') -AppliesWhen @("port == 'review' AND") | Out-Null

            $result = Invoke-FrameValidate -RootPath $root

            & $script:AssertAggregateResult -Result $result -ExpectedPassCount 0 -ExpectedFailCount 2 -ExpectedExitCode 1
            $symmetry = $result.Results | Where-Object { $_.Name -eq 'AdapterSymmetry' }
            $predicate = $result.Results | Where-Object { $_.Name -eq 'PredicateParse' }

            & $script:AssertCheckResult -Result $symmetry -ExpectedName 'AdapterSymmetry'
            $symmetry.Passed | Should -BeFalse
            $symmetry.Detail | Should -Match '2 invalid provides declaration'
            $symmetry.Detail | Should -Match 'agents/typo-provides\.agent\.md'
            $symmetry.Detail | Should -Match "provides 'experiense'"
            $symmetry.Detail | Should -Match 'commands/nonexistent-port\.md'
            $symmetry.Detail | Should -Match "provides 'future-only-port'"
            $symmetry.Detail | Should -Match 'valid ports: experience, implement-code, review'

            & $script:AssertCheckResult -Result $predicate -ExpectedName 'PredicateParse'
            $predicate.Passed | Should -BeFalse
            $predicate.Detail | Should -Match '1 applies-when parse error'
            $predicate.Detail | Should -Match 'skills/test-skill/SKILL\.md'
            $predicate.Detail | Should -Match ([regex]::Escape("port == 'review' AND"))
            $predicate.Detail | Should -Match 'parse error at position'
        }

        It 'keeps predicate parsing active when the frame port catalog is absent' {
            $root = & $script:NewFrameValidateFixture -WithoutPortCatalog
            & $script:AddFrameAdapter -Root $root -RelativePath 'agents\missing-catalog.agent.md' -Provides @('anything') -AppliesWhen @("port == 'experience' AND") | Out-Null

            $result = Invoke-FrameValidate -RootPath $root

            & $script:AssertAggregateResult -Result $result -ExpectedPassCount 1 -ExpectedFailCount 1 -ExpectedExitCode 1
            $symmetry = $result.Results | Where-Object { $_.Name -eq 'AdapterSymmetry' }
            $predicate = $result.Results | Where-Object { $_.Name -eq 'PredicateParse' }

            & $script:AssertCheckResult -Result $symmetry -ExpectedName 'AdapterSymmetry'
            $symmetry.Passed | Should -BeTrue
            $symmetry.Detail | Should -Match 'frame/ports missing'
            $symmetry.Detail | Should -Match 'adapter symmetry skipped'

            & $script:AssertCheckResult -Result $predicate -ExpectedName 'PredicateParse'
            $predicate.Passed | Should -BeFalse
            $predicate.Detail | Should -Match '1 applies-when parse error'
            $predicate.Detail | Should -Match 'agents/missing-catalog\.agent\.md'
            $predicate.Detail | Should -Match ([regex]::Escape("port == 'experience' AND"))
        }
    }
}
