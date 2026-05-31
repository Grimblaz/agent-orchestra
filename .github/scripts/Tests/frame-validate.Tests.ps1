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
    the checks. Quick-validate integration tests exercise the CI aggregate wire.
#>

Describe 'Frame validator check functions' -Tag 'unit' {

    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
        $script:LibFile = Join-Path $script:RepoRoot '.github/scripts/lib/frame-validate-core.ps1'
        $script:QuickValidateLibFile = Join-Path $script:RepoRoot '.github/scripts/lib/quick-validate-core.ps1'
        . $script:LibFile
        . $script:QuickValidateLibFile

        $script:JoinFrameValidateTestPath = {
            param(
                [Parameter(Mandatory)][string]$Root,
                [Parameter(Mandatory)][string]$RelativePath
            )

            $path = $Root
            foreach ($part in @($RelativePath -split '[\\/]' | Where-Object { $_.Length -gt 0 })) {
                $path = Join-Path -Path $path -ChildPath $part
            }

            return $path
        }

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

            $agentsDir = & $script:JoinFrameValidateTestPath -Root $Root -RelativePath 'agents'
            $skillDir = & $script:JoinFrameValidateTestPath -Root $Root -RelativePath 'skills/test-skill'
            $commandsDir = & $script:JoinFrameValidateTestPath -Root $Root -RelativePath 'commands'

            New-Item -ItemType Directory -Path $agentsDir -Force | Out-Null
            New-Item -ItemType Directory -Path $skillDir -Force | Out-Null
            New-Item -ItemType Directory -Path $commandsDir -Force | Out-Null

            if (-not $WithoutPortCatalog) {
                $portsDir = & $script:JoinFrameValidateTestPath -Root $Root -RelativePath 'frame/ports'
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

            $path = & $script:JoinFrameValidateTestPath -Root $Root -RelativePath $RelativePath
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

        $script:AddFrameAdapterRaw = {
            param(
                [Parameter(Mandatory)][string]$Root,
                [Parameter(Mandatory)][string]$RelativePath,
                [Parameter(Mandatory)][string]$Content
            )

            $path = & $script:JoinFrameValidateTestPath -Root $Root -RelativePath $RelativePath
            New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
            Set-Content -Path $path -Value $Content -Encoding utf8NoBOM
            return $path
        }

        $script:GetFrameValidateLivePortNames = {
            param([Parameter(Mandatory)][string]$Root)

            $catalog = Get-FVPortCatalog -RootPath $Root
            $catalog.Exists | Should -BeTrue
            return [string[]]@($catalog.Names | Where-Object { $_ -ne 'process-retrospective' } | Sort-Object)
        }

        $script:GetFrameValidateExpectedRolesByPort = {
            return @{
                'ce-gate-api'        = [string[]]@('auto-na', 'explicit-skip', 'work')
                'ce-gate-browser'    = [string[]]@('auto-na', 'explicit-skip', 'work')
                'ce-gate-canvas'     = [string[]]@('auto-na', 'explicit-skip', 'work')
                'ce-gate-cli'        = [string[]]@('auto-na', 'explicit-skip', 'work')
                'design'             = [string[]]@('auto-na', 'explicit-skip', 'work')
                'experience'         = [string[]]@('auto-na', 'explicit-skip', 'work')
                'implement-code'     = [string[]]@('auto-na', 'explicit-skip', 'work')
                'implement-docs'     = [string[]]@('auto-na', 'explicit-skip', 'work')
                'implement-refactor' = [string[]]@('auto-na', 'explicit-skip', 'work')
                'implement-test'     = [string[]]@('auto-na', 'explicit-skip', 'work')
                'plan'               = [string[]]@('auto-na', 'explicit-skip', 'work')
                'post-fix-review'    = [string[]]@('explicit-skip', 'work')
                'post-pr'            = [string[]]@('explicit-skip', 'work')
                'process-review'     = [string[]]@('explicit-skip', 'work')
                'release-hygiene'    = [string[]]@('explicit-skip', 'work')
                'review'             = [string[]]@('explicit-skip', 'work')
            }
        }

        $script:NewFrameValidateProviderDeclarationKey = {
            param(
                [Parameter(Mandatory)][string]$Role,
                [Parameter(Mandatory)][string]$Path,
                [Parameter(Mandatory)][string[]]$Provides
            )

            $providesText = @($Provides | Sort-Object) -join ', '
            return "$Role|$Path|$providesText"
        }

        $script:GetFrameValidateExpectedProviderDeclarationKeys = {
            $expectedDeclarationsByRole = @{
                'work'          = [ordered]@{
                    'agents/Code-Review-Response.agent.md'                   = 'review'
                    'agents/Code-Smith.agent.md'                             = 'implement-code'
                    'agents/Doc-Keeper.agent.md'                             = 'implement-docs'
                    'agents/Experience-Owner.agent.md'                       = 'experience'
                    'agents/Issue-Planner.agent.md'                          = 'plan'
                    'agents/Process-Review.agent.md'                         = 'process-review'
                    'agents/Refactor-Specialist.agent.md'                    = 'implement-refactor'
                    'agents/Solution-Designer.agent.md'                      = 'design'
                    'agents/Test-Writer.agent.md'                            = 'implement-test'
                    'skills/adversarial-review/adapters/judge-only.md'       = 'review'
                    'skills/adversarial-review/adapters/lite.md'             = 'review'
                    'skills/adversarial-review/adapters/post-fix.md'         = 'post-fix-review'
                    'skills/adversarial-review/adapters/proxy-github.md'     = 'review'
                    'skills/adversarial-review/adapters/standard.md'         = 'review'
                    'skills/customer-experience/adapters/ce-gate-api.md'     = 'ce-gate-api'
                    'skills/customer-experience/adapters/ce-gate-browser.md' = 'ce-gate-browser'
                    'skills/customer-experience/adapters/ce-gate-canvas.md'  = 'ce-gate-canvas'
                    'skills/customer-experience/adapters/ce-gate-cli.md'     = 'ce-gate-cli'
                    'skills/implementation-discipline/adapters/implement-code-adapter.md' = 'implement-code'
                    'skills/refactoring-methodology/adapters/implement-refactor-adapter.md' = 'implement-refactor'
                    'skills/plugin-release-hygiene/SKILL.md'                 = 'release-hygiene'
                    'skills/post-pr-review/SKILL.md'                         = 'post-pr'
                    'skills/process-retrospective/SKILL.md'                  = 'process-retrospective'
                }
                'auto-na'       = [ordered]@{
                    'skills/customer-experience/adapters/ce-gate-api-auto-na-adapter.md'            = 'ce-gate-api'
                    'skills/customer-experience/adapters/ce-gate-browser-auto-na-adapter.md'        = 'ce-gate-browser'
                    'skills/customer-experience/adapters/ce-gate-canvas-auto-na-adapter.md'         = 'ce-gate-canvas'
                    'skills/customer-experience/adapters/ce-gate-cli-auto-na-adapter.md'            = 'ce-gate-cli'
                    'skills/customer-experience/adapters/experience-auto-na-adapter.md'             = 'experience'
                    'skills/design-exploration/adapters/design-auto-na-adapter.md'                  = 'design'
                    'skills/documentation-finalization/adapters/implement-docs-auto-na-adapter.md'  = 'implement-docs'
                    'skills/implementation-discipline/adapters/implement-code-auto-na-adapter.md'   = 'implement-code'
                    'skills/plan-authoring/adapters/plan-auto-na-adapter.md'                        = 'plan'
                    'skills/refactoring-methodology/adapters/implement-refactor-auto-na-adapter.md' = 'implement-refactor'
                    'skills/test-driven-development/adapters/implement-test-auto-na-adapter.md'     = 'implement-test'
                }
                'explicit-skip' = [ordered]@{
                    'skills/adversarial-review/adapters/post-fix-review-explicit-skip-adapter.md'         = 'post-fix-review'
                    'skills/adversarial-review/adapters/review-explicit-skip-adapter.md'                  = 'review'
                    'skills/customer-experience/adapters/ce-gate-api-explicit-skip-adapter.md'            = 'ce-gate-api'
                    'skills/customer-experience/adapters/ce-gate-browser-explicit-skip-adapter.md'        = 'ce-gate-browser'
                    'skills/customer-experience/adapters/ce-gate-canvas-explicit-skip-adapter.md'         = 'ce-gate-canvas'
                    'skills/customer-experience/adapters/ce-gate-cli-explicit-skip-adapter.md'            = 'ce-gate-cli'
                    'skills/customer-experience/adapters/experience-explicit-skip-adapter.md'             = 'experience'
                    'skills/design-exploration/adapters/design-explicit-skip-adapter.md'                  = 'design'
                    'skills/documentation-finalization/adapters/implement-docs-explicit-skip-adapter.md'  = 'implement-docs'
                    'skills/implementation-discipline/adapters/implement-code-explicit-skip-adapter.md'   = 'implement-code'
                    'skills/plan-authoring/adapters/plan-explicit-skip-adapter.md'                        = 'plan'
                    'skills/plugin-release-hygiene/adapters/release-hygiene-explicit-skip-adapter.md'     = 'release-hygiene'
                    'skills/post-pr-review/adapters/post-pr-explicit-skip-adapter.md'                     = 'post-pr'
                    'skills/process-analysis/adapters/process-review-explicit-skip-adapter.md'                     = 'process-review'
                    'skills/process-retrospective/adapters/process-retrospective-explicit-skip-adapter.md'        = 'process-retrospective'
                    'skills/refactoring-methodology/adapters/implement-refactor-explicit-skip-adapter.md'         = 'implement-refactor'
                    'skills/test-driven-development/adapters/implement-test-explicit-skip-adapter.md'             = 'implement-test'
                }
            }

            $keys = [System.Collections.Generic.List[string]]::new()
            foreach ($role in @('work', 'auto-na', 'explicit-skip')) {
                foreach ($path in @($expectedDeclarationsByRole[$role].Keys)) {
                    $keys.Add((& $script:NewFrameValidateProviderDeclarationKey -Role $role -Path $path -Provides @($expectedDeclarationsByRole[$role][$path])))
                }
            }

            return [string[]]@($keys.ToArray() | Sort-Object)
        }

        $script:GetFrameValidateActualProviderDeclarationKeys = {
            param([Parameter(Mandatory)][string]$Root)

            $keys = [System.Collections.Generic.List[string]]::new()
            foreach ($adapter in @(Get-FVAdapterMetadata -RootPath $Root)) {
                if (@($adapter.Provides).Count -eq 0) { continue }

                $relativePath = Get-FVRelativePath -RootPath $Root -Path $adapter.File.FullName
                $role = & $script:GetFrameValidateAdapterRole -File $adapter.File
                $keys.Add((& $script:NewFrameValidateProviderDeclarationKey -Role $role -Path $relativePath -Provides @($adapter.Provides)))
            }

            return [string[]]@($keys.ToArray() | Sort-Object)
        }

        $script:GetFrameValidateAdapterRole = {
            param([Parameter(Mandatory)][System.IO.FileInfo]$File)

            if ($File.Name -like '*-auto-na-adapter.md') { return 'auto-na' }
            if ($File.Name -like '*-explicit-skip-adapter.md') { return 'explicit-skip' }
            return 'work'
        }

        $script:GetFrameValidateFrontmatterLines = {
            param([Parameter(Mandatory)][System.IO.FileInfo]$File)

            $content = Get-Content -LiteralPath $File.FullName -Raw
            $match = [regex]::Match($content, '(?ms)\A---\r?\n(?<yaml>.*?)\r?\n---(?:\r?\n|\z)')
            if (-not $match.Success) { return [string[]]@() }
            return [string[]]($match.Groups['yaml'].Value -split "`r?`n")
        }

        $script:GetFrameValidateExplicitSkipFiles = {
            param([Parameter(Mandatory)][string]$Root)

            $skillsPath = Join-Path -Path $Root -ChildPath 'skills'
            if (-not (Test-Path -LiteralPath $skillsPath)) { return [System.IO.FileInfo[]]@() }

            return [System.IO.FileInfo[]]@(
                Get-ChildItem -LiteralPath $skillsPath -Directory |
                    ForEach-Object {
                        $adaptersPath = Join-Path -Path $_.FullName -ChildPath 'adapters'
                        if (Test-Path -LiteralPath $adaptersPath) {
                            Get-ChildItem -LiteralPath $adaptersPath -Filter '*-explicit-skip-adapter.md' -File
                        }
                    } |
                    Sort-Object -Property FullName
            )
        }

        $script:GetFrameValidateDispatcherFiles = {
            param([Parameter(Mandatory)][string]$Root)

            $agentsPath = Join-Path -Path $Root -ChildPath 'agents'
            $commandsPath = Join-Path -Path $Root -ChildPath 'commands'
            $dispatcherFiles = [System.Collections.Generic.List[System.IO.FileInfo]]::new()

            if (Test-Path -LiteralPath $agentsPath) {
                foreach ($file in @(Get-ChildItem -LiteralPath $agentsPath -Filter '*.md' -File)) {
                    if ($file.Name -notlike '*.agent.md' -and $file.Name -cmatch '^[a-z].*\.md$') {
                        $dispatcherFiles.Add($file)
                    }
                }
            }

            if (Test-Path -LiteralPath $commandsPath) {
                foreach ($file in @(Get-ChildItem -LiteralPath $commandsPath -Filter '*.md' -File)) {
                    $dispatcherFiles.Add($file)
                }
            }

            return [System.IO.FileInfo[]]@($dispatcherFiles.ToArray() | Sort-Object -Property FullName)
        }

        $script:GetFrameValidatePredicateIdentifiers = {
            param([Parameter(Mandatory)][string]$Predicate)

            $ast = ConvertTo-FVPredicate -Predicate $Predicate
            if (Test-FVParseError -Value $ast) {
                throw "Predicate '$Predicate' failed to parse: $($ast.Message)"
            }

            $identifiers = [System.Collections.Generic.List[string]]::new()
            $visit = {
                param($Node)

                if ($null -eq $Node) { return }
                if ($Node -is [string] -or $Node -is [ValueType]) { return }

                if ($Node -is [System.Collections.IEnumerable]) {
                    foreach ($item in $Node) {
                        & $visit $item
                    }
                    return
                }

                $kindProperty = $Node.PSObject.Properties['Kind']
                if ($null -ne $kindProperty) {
                    if ($kindProperty.Value -eq 'Identifier' -or $kindProperty.Value -eq 'Call') {
                        $identifiers.Add([string]$Node.Name)
                    }
                }

                foreach ($property in @($Node.PSObject.Properties)) {
                    if ($property.Name -notin @('Kind', 'Name', 'LiteralType', 'Value', 'Operator', 'Position')) {
                        & $visit $property.Value
                    }
                }
            }

            & $visit $ast
            return [string[]]@(
                $identifiers.ToArray() |
                    Sort-Object -Unique
            )
        }

        $script:GetFrameValidateAllowedPredicateIdentifiers = {
            return [System.Collections.Generic.HashSet[string]]::new([string[]]@(
                    'changeset.touchesSource'
                    'changeset.touchesTestableCode'
                    'changeset.touchedAreaHasRefactorableDebt'
                    'changeset.changesBehaviorOrInterface'
                    'changeset.touchesCliSurface'
                    'changeset.touchesBrowserSurface'
                    'changeset.touchesCanvasSurface'
                    'changeset.touchesApiSurface'
                    'changeset.touchesPluginEntryPoint'
                    'changeset.isPipelineEntryTrivial'
                    'changeset.touchesTestableCodeOrTests'
                    'changeset.touchedAreaHasDebt'
                    'changeset.touchesBehaviorOrInterfaceDocsExtended'
                    'changeset.touches'
                    'changeset.totalLines'
                    'changeset.complexity'
                    'scope.isReReview'
                    'scope.isProxyGithub'
                    'review.sustainedCriticalOrHigh'
                    'ceGate.defectsFound'
                    'never'
                    'changeset.isPipelineEntryTrivial'
                    'changeset.touchesBehaviorOrInterfaceDocsExtended'
                    'changeset.touchedAreaHasDebt'
                    'changeset.touchesTestableCodeOrTests'
                ), [System.StringComparer]::Ordinal)
        }

        $script:GetFrameValidateNonAllowlistedPredicateIdentifiers = {
            param(
                [Parameter(Mandatory)][string]$Predicate,
                [Parameter(Mandatory)][System.Collections.Generic.HashSet[string]]$AllowedIdentifiers
            )

            return [string[]]@(
                & $script:GetFrameValidatePredicateIdentifiers -Predicate $Predicate |
                    Where-Object { -not $AllowedIdentifiers.Contains($_) } |
                    Sort-Object -Unique
            )
        }

        $script:NewQuickValidateSupportFixture = {
            param([Parameter(Mandatory)][string]$Root)

            $configDir = & $script:JoinFrameValidateTestPath -Root $Root -RelativePath '.github/config'
            New-Item -ItemType Directory -Path $configDir -Force | Out-Null

            $complexityScriptPath = Join-Path $Root 'mock-measure-guidance-complexity.ps1'
            Set-Content -Path $complexityScriptPath -Value 'Write-Output ''{"agents_over_ceiling":[]}''' -Encoding utf8NoBOM

            $settingsPath = Join-Path $configDir 'PSScriptAnalyzerSettings.psd1'
            Set-Content -Path $settingsPath -Value '@{ IncludeRules = @() }' -Encoding utf8NoBOM

            return [PSCustomObject]@{
                GuidanceComplexityScriptPath = $complexityScriptPath
                PSScriptAnalyzerSettingsPath = $settingsPath
                ScriptsPath                  = & $script:JoinFrameValidateTestPath -Root $Root -RelativePath '.github/scripts'
            }
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

        It 'does not require every port to have an adapter declaration' {
            $root = & $script:NewFrameValidateFixture -Ports @('experience', 'review')

            $result = Test-FVAdapterSymmetry -RootPath $root

            & $script:AssertCheckResult -Result $result -ExpectedName 'AdapterSymmetry'
            $result.Passed | Should -BeTrue
            $result.Detail | Should -Be ''
        }

        It 'uses frame port filename stems without reading YAML body names' {
            $root = & $script:NewFrameValidateFixture -Ports @('experience')
            $portFile = & $script:JoinFrameValidateTestPath -Root $root -RelativePath 'frame/ports/experience.yaml'
            Set-Content -Path $portFile -Value 'name: not-the-port-name' -Encoding utf8NoBOM
            & $script:AddFrameAdapter -Root $root -RelativePath 'agents\stem-port.agent.md' -Provides @('experience') | Out-Null

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

        It 'discovers skill adapter files alongside agent, skill, and command scan surfaces' {
            $root = & $script:NewFrameValidateFixture -Ports @('experience')
            $resolvedRoot = (Get-Item -LiteralPath $root).FullName
            & $script:AddFrameAdapter -Root $root -RelativePath 'agents\discovered.agent.md' -Provides @('experience') | Out-Null
            & $script:AddFrameAdapter -Root $root -RelativePath 'agents\lowercase-shell.md' -Provides @('experience') | Out-Null
            & $script:AddFrameAdapter -Root $root -RelativePath 'commands\discovered-command.md' -Provides @('experience') | Out-Null
            & $script:AddFrameAdapter -Root $root -RelativePath 'skills\test-skill\adapters\experience-auto-na-adapter.md' -Provides @('experience') | Out-Null
            & $script:AddFrameAdapter -Root $root -RelativePath 'skills\test-skill\adapters\experience-explicit-skip-adapter.md' -Provides @('experience') | Out-Null
            & $script:AddFrameAdapter -Root $root -RelativePath 'skills\test-skill\adapters\variant.md' -Provides @('experience') | Out-Null

            $discoveredPaths = [string[]]@(
                Get-FVAdapterFiles -RootPath $resolvedRoot |
                    ForEach-Object { Get-FVRelativePath -RootPath $resolvedRoot -Path $_.FullName } |
                    Sort-Object
            )

            $expectedPaths = [string[]]@(
                'agents/discovered.agent.md'
                'agents/lowercase-shell.md'
                'commands/discovered-command.md'
                'skills/test-skill/SKILL.md'
                'skills/test-skill/adapters/experience-auto-na-adapter.md'
                'skills/test-skill/adapters/experience-explicit-skip-adapter.md'
                'skills/test-skill/adapters/variant.md'
            ) | Sort-Object

            $discoveredPaths | Should -Be $expectedPaths
        }

        It 'fails a typoed reveiw provides declaration with deterministic adapter symmetry detail' {
            $root = & $script:NewFrameValidateFixture -Ports @('review')
            $resolvedRoot = (Get-Item -LiteralPath $root).FullName
            & $script:AddFrameAdapter -Root $root -RelativePath 'skills\test-skill\adapters\typo-review.md' -Provides @('reveiw') | Out-Null

            $result = Test-FVAdapterSymmetry -RootPath $resolvedRoot

            & $script:AssertCheckResult -Result $result -ExpectedName 'AdapterSymmetry'
            $result.Passed | Should -BeFalse
            $result.Detail | Should -Be "1 invalid provides declaration(s): skills/test-skill/adapters/typo-review.md provides 'reveiw'; valid ports: review"
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

        It 'accepts valid YAML scalar comments, inline arrays, indented lists, block scalars, and escaped double quotes' {
            $root = & $script:NewFrameValidateFixture -Ports @('experience', 'review')

            & $script:AddFrameAdapterRaw -Root $root -RelativePath 'agents\commented-scalar.agent.md' -Content @'
---
name: commented-scalar
provides: review # comment
applies-when: changeset.totalLines < 200 # comment
---

# Commented Scalar
'@ | Out-Null

            & $script:AddFrameAdapterRaw -Root $root -RelativePath 'commands\inline-array.md' -Content @'
---
name: inline-array
provides: [experience, review] # comment
applies-when: "port == \"experience\""
---

# Inline Array
'@ | Out-Null

            & $script:AddFrameAdapterRaw -Root $root -RelativePath 'skills\test-skill\SKILL.md' -Content @'
---
name: test-skill
description: Test skill. Use when validating frame fixtures. DO NOT USE FOR: production.
provides: # comment
  - experience
  - review # comment
applies-when: >-
    changeset.touches('docs/**') and changeset.changesBehaviorOrInterface()
---

# Test Skill

## Gotchas

None.
'@ | Out-Null

            & $script:AddFrameAdapterRaw -Root $root -RelativePath 'skills\test-skill\adapters\literal-block.md' -Content @'
---
name: literal-block
provides: experience
applies-when: |+
  not changeset.touchesSource()
---

# Literal Block
'@ | Out-Null

            $result = Invoke-FrameValidate -RootPath $root

            & $script:AssertAggregateResult -Result $result -ExpectedPassCount 2 -ExpectedFailCount 0 -ExpectedExitCode 0
            foreach ($check in @($result.Results)) {
                $check.Passed | Should -BeTrue
                $check.Detail | Should -Be ''
            }
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

    Context 'Live adapter declaration locks' {

        It 'has the expected adapter role set for every non-deferred live port' {
            $expectedRolesByPort = & $script:GetFrameValidateExpectedRolesByPort
            $portNames = & $script:GetFrameValidateLivePortNames -Root $script:RepoRoot
            $metadataByPort = @{}

            foreach ($adapter in @(Get-FVAdapterMetadata -RootPath $script:RepoRoot)) {
                foreach ($providedPort in @($adapter.Provides)) {
                    if (-not $metadataByPort.ContainsKey($providedPort)) {
                        $metadataByPort[$providedPort] = [System.Collections.Generic.List[string]]::new()
                    }

                    $metadataByPort[$providedPort].Add((& $script:GetFrameValidateAdapterRole -File $adapter.File))
                }
            }

            $violations = [System.Collections.Generic.List[string]]::new()
            foreach ($portName in $portNames) {
                if (-not $expectedRolesByPort.ContainsKey($portName)) {
                    $violations.Add("$portName has no expected adapter role mapping")
                    continue
                }

                $expectedRoles = [string[]]@($expectedRolesByPort[$portName] | Sort-Object -Unique)
                $actualRoles = if ($metadataByPort.ContainsKey($portName)) {
                    [string[]]@($metadataByPort[$portName].ToArray() | Sort-Object -Unique)
                }
                else {
                    [string[]]@()
                }

                if (($actualRoles -join ', ') -ne ($expectedRoles -join ', ')) {
                    $violations.Add("$portName expected roles [$($expectedRoles -join ', ')]; actual roles [$($actualRoles -join ', ')]")
                }
            }

            ($violations -join "`n") | Should -Be ''
        }

        It 'allows only the documented provider declaration paths for each adapter role' {
            $expectedProviderDeclarations = & $script:GetFrameValidateExpectedProviderDeclarationKeys
            $actualProviderDeclarations = & $script:GetFrameValidateActualProviderDeclarationKeys -Root $script:RepoRoot

            ($actualProviderDeclarations -join "`n") | Should -Be ($expectedProviderDeclarations -join "`n")
        }

        It 'adapter hashtable count matches filesystem count for each predicate role (forward-drift guard)' {
            # This is the COUNT-PARITY forward-drift guard (issue #559 F1).
            # Catches "a new predicate adapter was added to the filesystem without updating
            # the expectedDeclarationsByRole hashtable" — complementary to the per-path
            # Test-Path assertions which cover set-equality for currently-listed paths.
            # Keys are in format "role|path|provides"; count by role prefix.
            $allExpectedKeys = & $script:GetFrameValidateExpectedProviderDeclarationKeys
            $autoNaExpected = @($allExpectedKeys | Where-Object { $_ -like 'auto-na|*' }).Count
            $autoNaActual   = @(Get-ChildItem -Path (Join-Path $script:RepoRoot 'skills') -Recurse -Filter '*-auto-na-adapter.md').Count
            $autoNaExpected | Should -Be $autoNaActual -Because 'every auto-na adapter on disk must be listed in the expected hashtable'

            $explicitSkipExpected = @($allExpectedKeys | Where-Object { $_ -like 'explicit-skip|*' }).Count
            $explicitSkipActual   = @(Get-ChildItem -Path (Join-Path $script:RepoRoot 'skills') -Recurse -Filter '*-explicit-skip-adapter.md').Count
            $explicitSkipExpected | Should -Be $explicitSkipActual -Because 'every explicit-skip adapter on disk must be listed in the expected hashtable'
        }

        It 'every predicate adapter file declares adapter-type: predicate frontmatter (frontmatter-presence guard)' {
            # Issue #559 M7 (sustained): the count-parity guard above verifies filesystem
            # vs hashtable counts, but does not verify frontmatter integrity. A file with
            # the right filename suffix but wrong/missing `adapter-type:` field would pass
            # count-parity. This guard closes that gap by asserting every file matching
            # the predicate suffix convention declares `adapter-type: predicate`.
            $predicateFiles = @(Get-ChildItem -Path (Join-Path $script:RepoRoot 'skills') -Recurse -Include '*-auto-na-adapter.md','*-explicit-skip-adapter.md')
            $predicateFiles.Count | Should -BeGreaterThan 0 -Because 'the predicate adapter directory should not be empty'

            foreach ($file in $predicateFiles) {
                $content = Get-Content -Path $file.FullName -Raw
                $content | Should -Match '(?m)^adapter-type:\s+predicate\s*$' -Because "$($file.Name) should declare 'adapter-type: predicate' in its YAML frontmatter"
            }
        }

        It 'has exactly the deferred-skeleton providers for process-retrospective' {
            $expectedPaths = [string[]]@(
                'skills/process-retrospective/SKILL.md'
                'skills/process-retrospective/adapters/process-retrospective-explicit-skip-adapter.md'
            ) | Sort-Object

            $processRetrospectiveProviders = [System.Collections.Generic.List[string]]::new()
            foreach ($adapter in @(Get-FVAdapterMetadata -RootPath $script:RepoRoot)) {
                foreach ($providedPort in @($adapter.Provides)) {
                    if ($providedPort -eq 'process-retrospective') {
                        $relativePath = Get-FVRelativePath -RootPath $script:RepoRoot -Path $adapter.File.FullName
                        $processRetrospectiveProviders.Add($relativePath)
                    }
                }
            }

            ($processRetrospectiveProviders.ToArray() | Sort-Object | ForEach-Object { $_ }) |
                Should -Be $expectedPaths -Because 'deferred port has skeleton SKILL.md + explicit-skip adapter only'
        }

        It 'keeps supporting methodology skills free of provider declarations' {
            $supportingSkillPaths = @(
                'skills/routing-tables/SKILL.md'
                'skills/session-memory-contract/SKILL.md'
                'skills/subagent-env-handshake/SKILL.md'
            )

            $violations = [System.Collections.Generic.List[string]]::new()
            foreach ($supportingSkillPath in $supportingSkillPaths) {
                $file = Get-Item -LiteralPath (Join-Path -Path $script:RepoRoot -ChildPath $supportingSkillPath)
                $frontmatter = Get-FVAdapterFrontmatter -File $file
                if (@($frontmatter.Provides).Count -ne 0) {
                    $violations.Add("$supportingSkillPath declares provides: $(@($frontmatter.Provides) -join ', ')")
                }
            }

            ($violations -join "`n") | Should -Be ''
        }

        It 'keeps standard and lite review predicates exclusive from judge-only and proxy scopes' {
            $expectedPredicatesByPath = @{
                'skills/adversarial-review/adapters/standard.md'     = 'changeset.totalLines >= 200 and not scope.isReReview and not scope.isProxyGithub'
                'skills/adversarial-review/adapters/lite.md'         = 'changeset.totalLines < 200 and not scope.isReReview and not scope.isProxyGithub'
                'skills/adversarial-review/adapters/judge-only.md'   = 'scope.isReReview'
                'skills/adversarial-review/adapters/proxy-github.md' = 'scope.isProxyGithub'
            }

            foreach ($relativePath in @($expectedPredicatesByPath.Keys | Sort-Object)) {
                $file = Get-Item -LiteralPath (Join-Path -Path $script:RepoRoot -ChildPath $relativePath)
                $frontmatter = Get-FVAdapterFrontmatter -File $file

                @($frontmatter.AppliesWhen) | Should -Be @($expectedPredicatesByPath[$relativePath])
            }
        }

        It 'requires every explicit-skip adapter to declare the D9 reason-required line' {
            $deferredPortsWithExplicitSkip = 1  # process-retrospective has a declared-but-deferred explicit-skip
            $expectedExplicitSkipCount = @(& $script:GetFrameValidateLivePortNames -Root $script:RepoRoot).Count + $deferredPortsWithExplicitSkip
            $explicitSkipFiles = & $script:GetFrameValidateExplicitSkipFiles -Root $script:RepoRoot
            $violations = [System.Collections.Generic.List[string]]::new()

            if ($explicitSkipFiles.Count -ne $expectedExplicitSkipCount) {
                $violations.Add("expected $expectedExplicitSkipCount explicit-skip adapter file(s); found $($explicitSkipFiles.Count)")
            }

            foreach ($explicitSkipFile in $explicitSkipFiles) {
                $frontmatterLines = & $script:GetFrameValidateFrontmatterLines -File $explicitSkipFile
                if ($frontmatterLines -notcontains 'reason-required: true') {
                    $relativePath = Get-FVRelativePath -RootPath $script:RepoRoot -Path $explicitSkipFile.FullName
                    $violations.Add("$relativePath is missing literal frontmatter line 'reason-required: true'")
                }
            }

            ($violations -join "`n") | Should -Be ''
        }

        It 'keeps lowercase agent shells and commands free of provides declarations' {
            $dispatcherFiles = & $script:GetFrameValidateDispatcherFiles -Root $script:RepoRoot
            $dispatcherFiles | Should -Not -BeNullOrEmpty

            $violations = [System.Collections.Generic.List[string]]::new()
            foreach ($dispatcherFile in $dispatcherFiles) {
                $frontmatter = Get-FVAdapterFrontmatter -File $dispatcherFile
                if (@($frontmatter.Provides).Count -ne 0) {
                    $relativePath = Get-FVRelativePath -RootPath $script:RepoRoot -Path $dispatcherFile.FullName
                    $violations.Add("$relativePath declares provides: $(@($frontmatter.Provides) -join ', ')")
                }
            }

            ($violations -join "`n") | Should -Be ''
        }

        It 'uses only allowlisted DSL identifiers and functions in adapter applies-when predicates' {
            $allowedIdentifiers = & $script:GetFrameValidateAllowedPredicateIdentifiers

            $violations = [System.Collections.Generic.List[string]]::new()
            $predicateCount = 0

            foreach ($adapter in @(Get-FVAdapterMetadata -RootPath $script:RepoRoot)) {
                foreach ($predicate in @($adapter.AppliesWhen)) {
                    $predicateCount++
                    $relativePath = Get-FVRelativePath -RootPath $script:RepoRoot -Path $adapter.File.FullName

                    foreach ($identifier in @(& $script:GetFrameValidateNonAllowlistedPredicateIdentifiers -Predicate $predicate -AllowedIdentifiers $allowedIdentifiers)) {
                        $violations.Add("$relativePath applies-when '$predicate' uses non-allowlisted identifier/function '$identifier'")
                    }
                }
            }

            if ($predicateCount -eq 0) {
                $violations.Add('no adapter applies-when predicates were discovered for DSL allowlist validation')
            }

            ($violations -join "`n") | Should -Be ''
        }

        It 'catches bare non-allowlisted predicate identifiers' {
            $allowedIdentifiers = & $script:GetFrameValidateAllowedPredicateIdentifiers

            $violations = & $script:GetFrameValidateNonAllowlistedPredicateIdentifiers -Predicate 'bogus == true' -AllowedIdentifiers $allowedIdentifiers

            $violations | Should -Be @('bogus')
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

        It 'reports a comment-only applies-when as a file-specific predicate parse error' {
            $root = & $script:NewFrameValidateFixture -Ports @('experience')
            & $script:AddFrameAdapterRaw -Root $root -RelativePath 'agents\comment-only.agent.md' -Content @'
---
name: comment-only
provides: experience
applies-when: # TODO
---

# Comment Only
'@ | Out-Null

            $result = Invoke-FrameValidate -RootPath $root

            & $script:AssertAggregateResult -Result $result -ExpectedPassCount 1 -ExpectedFailCount 1 -ExpectedExitCode 1
            $symmetry = $result.Results | Where-Object { $_.Name -eq 'AdapterSymmetry' }
            $predicate = $result.Results | Where-Object { $_.Name -eq 'PredicateParse' }

            & $script:AssertCheckResult -Result $symmetry -ExpectedName 'AdapterSymmetry'
            $symmetry.Passed | Should -BeTrue
            $symmetry.Detail | Should -Be ''

            & $script:AssertCheckResult -Result $predicate -ExpectedName 'PredicateParse'
            $predicate.Passed | Should -BeFalse
            $predicate.Detail | Should -Match '1 applies-when parse error'
            $predicate.Detail | Should -Match 'agents/comment-only\.agent\.md'
            $predicate.Detail | Should -Match ([regex]::Escape("applies-when ''; parse error at position 0: Predicate is required."))
            $predicate.Detail | Should -Not -Match 'Cannot bind argument to parameter'
        }

        It 'scans skill adapter variant files for malformed declarations' {
            $root = & $script:NewFrameValidateFixture -Ports @('experience')
            & $script:AddFrameAdapterRaw -Root $root -RelativePath 'skills\test-skill\adapters\broken-variant.md' -Content @'
---
name: broken-variant
provides: missing-port
applies-when: port ==
---

# Broken Variant
'@ | Out-Null

            $result = Invoke-FrameValidate -RootPath $root

            & $script:AssertAggregateResult -Result $result -ExpectedPassCount 0 -ExpectedFailCount 2 -ExpectedExitCode 1
            $symmetry = $result.Results | Where-Object { $_.Name -eq 'AdapterSymmetry' }
            $predicate = $result.Results | Where-Object { $_.Name -eq 'PredicateParse' }

            $symmetry.Detail | Should -Match 'skills/test-skill/adapters/broken-variant\.md'
            $symmetry.Detail | Should -Match "provides 'missing-port'"
            $predicate.Detail | Should -Match 'skills/test-skill/adapters/broken-variant\.md'
            $predicate.Detail | Should -Match ([regex]::Escape('port =='))
        }
    }

    Context 'Invoke-QuickValidate integration' {

        It 'surfaces frame validator failure through quick-validate aggregation' {
            Mock Get-Module { return @{ Name = 'PSScriptAnalyzer'; Version = '1.22.0' } } -ParameterFilter { $Name -eq 'PSScriptAnalyzer' -and $ListAvailable }

            $root = & $script:NewFrameValidateFixture -Ports @('experience')
            & $script:AddFrameAdapter -Root $root -RelativePath 'agents\typo-provides.agent.md' -Provides @('experiense') -AppliesWhen @("port == 'experience'") | Out-Null
            $support = & $script:NewQuickValidateSupportFixture -Root $root

            $result = Invoke-QuickValidate `
                -RootPath $root `
                -GuidanceComplexityScriptPath $support.GuidanceComplexityScriptPath `
                -PSScriptAnalyzerSettingsPath $support.PSScriptAnalyzerSettingsPath `
                -ScriptsPath $support.ScriptsPath

            $frameValidator = @($result.Results | Where-Object { $_.Name -eq 'FrameValidator' })
            $frameValidator | Should -HaveCount 1
            $frameValidator[0].Passed | Should -BeFalse
            $frameValidator[0].Detail | Should -Match 'AdapterSymmetry'
            $frameValidator[0].Detail | Should -Match '1 invalid provides declaration'
            $frameValidator[0].Detail | Should -Match 'agents/typo-provides\.agent\.md'
            $frameValidator[0].Detail | Should -Match "provides 'experiense'"

            $psAnalyzer = $result.Results | Where-Object { $_.Name -eq 'PSScriptAnalyzer' }
            $psAnalyzer.Passed | Should -BeTrue
            @($result.Results | Where-Object { $_.Passed -eq $false } | Select-Object -ExpandProperty Name) | Should -Be @('FrameValidator')
            $result.ExitCode | Should -Be 1
            $result.FailCount | Should -Be 1
            $result.SkipCount | Should -Be 0
            $result.TotalCount | Should -Be @($result.Results).Count
            $result.PassCount | Should -Be ($result.TotalCount - 1)
        }

        It 'prints detail for a passing frame validator check when adapter symmetry is skipped' {
            Mock Get-Module { return @{ Name = 'PSScriptAnalyzer'; Version = '1.22.0' } } -ParameterFilter { $Name -eq 'PSScriptAnalyzer' -and $ListAvailable }

            $root = & $script:NewFrameValidateFixture -WithoutPortCatalog
            $support = & $script:NewQuickValidateSupportFixture -Root $root

            $result = Invoke-QuickValidate `
                -RootPath $root `
                -GuidanceComplexityScriptPath $support.GuidanceComplexityScriptPath `
                -PSScriptAnalyzerSettingsPath $support.PSScriptAnalyzerSettingsPath `
                -ScriptsPath $support.ScriptsPath `
                -InformationVariable infoOutput

            $frameValidator = @($result.Results | Where-Object { $_.Name -eq 'FrameValidator' })
            $frameValidator | Should -HaveCount 1
            $frameValidator[0].Passed | Should -BeTrue
            $frameValidator[0].Detail | Should -Match 'AdapterSymmetry: frame/ports missing; adapter symmetry skipped'

            $output = ($infoOutput | ForEach-Object { [string]$_.MessageData }) -join "`n"
            $output | Should -Match '\[PASS\] FrameValidator.*adapter symmetry skipped'
        }
    }
}
