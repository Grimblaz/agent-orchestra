#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
#Requires -Modules @{ ModuleName = 'powershell-yaml'; ModuleVersion = '0.4.0' }

BeforeAll {
    Import-Module powershell-yaml -MinimumVersion 0.4.0

    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
    $script:DispatcherPath = 'skills/adversarial-review/platforms/claude.md'
    $script:DispatcherMarker = '<!-- adversarial-pipeline-atomic-{ISSUE_ID} -->'
    $script:PauseReasons = @('artifact-missing', 'runtime-output-required', 'user-input-required-by-decision-class')
    $script:ExpectedAdapterNames = @('standard', 'lite', 'judge-only', 'proxy-github', 'post-fix', 'design-challenge')

    function script:Resolve-RepoPath {
        param([Parameter(Mandatory)][string]$Path)

        return Join-Path $script:RepoRoot ($Path -replace '/', [System.IO.Path]::DirectorySeparatorChar)
    }

    function script:Test-RepoPath {
        param([Parameter(Mandatory)][string]$Path)

        return Test-Path -LiteralPath (script:Resolve-RepoPath -Path $Path)
    }

    function script:Read-RepoText {
        param([Parameter(Mandatory)][string]$Path)

        return Get-Content -LiteralPath (script:Resolve-RepoPath -Path $Path) -Raw
    }

    function script:Read-RepoYaml {
        param([Parameter(Mandatory)][string]$Path)

        return ConvertFrom-Yaml -Yaml (script:Read-RepoText -Path $Path)
    }

    function script:Read-FrontMatter {
        param([Parameter(Mandatory)][string]$Path)

        $content = script:Read-RepoText -Path $Path
        $match = [regex]::Match($content, '(?ms)^---\s*\r?\n(?<yaml>.*?)\r?\n---')
        if (-not $match.Success) {
            throw "File $Path does not contain YAML frontmatter."
        }

        return ConvertFrom-Yaml -Yaml $match.Groups['yaml'].Value
    }

    function script:Test-YamlKey {
        param(
            [object]$Map,
            [string]$Key
        )

        if ($null -eq $Map) { return $false }
        if ($Map -is [System.Collections.IDictionary]) { return $Map.Contains($Key) }
        return $null -ne $Map.PSObject.Properties[$Key]
    }

    function script:Get-YamlValue {
        param(
            [object]$Map,
            [string]$Key
        )

        if (-not (script:Test-YamlKey -Map $Map -Key $Key)) { return $null }
        if ($Map -is [System.Collections.IDictionary]) { return $Map[$Key] }
        return $Map.PSObject.Properties[$Key].Value
    }

    function script:Assert-YamlBooleanTrue {
        param(
            [object]$Value,
            [Parameter(Mandatory)][string]$Because
        )

        ($Value -is [bool]) | Should -BeTrue -Because "$Because; value must be a YAML boolean, not a truthy string"
        $Value | Should -BeExactly $true -Because $Because
    }

    function script:ConvertTo-ValueArray {
        param([object]$Value)

        if ($null -eq $Value) { return @() }
        if ($Value -is [string]) { return @($Value) }
        if ($Value -is [System.Collections.IEnumerable]) { return @($Value) }
        return @($Value)
    }

    function script:Get-MarkdownSection {
        param(
            [Parameter(Mandatory)][string]$Text,
            [Parameter(Mandatory)][string]$Heading
        )

        $pattern = '(?ms)^##\s+' + [regex]::Escape($Heading) + '.*?(?=^##\s+|\z)'
        $match = [regex]::Match($Text, $pattern)
        if ($match.Success) { return $match.Value }
        return ''
    }

    function script:Get-SentinelWindow {
        param(
            [Parameter(Mandatory)][string]$Text,
            [Parameter(Mandatory)][string]$Begin,
            [Parameter(Mandatory)][string]$End
        )

        $pattern = '(?ms)' + [regex]::Escape($Begin) + '.*?' + [regex]::Escape($End)
        $match = [regex]::Match($Text, $pattern)
        if ($match.Success) { return $match.Value }
        return ''
    }

    function script:Get-FunctionBlock {
        param(
            [Parameter(Mandatory)][string]$Text,
            [Parameter(Mandatory)][string]$FunctionName,
            [Parameter(Mandatory)][string]$NextFunctionName
        )

        $pattern = '(?ms)^function\s+' + [regex]::Escape($FunctionName) + '\b.*?(?=^function\s+' + [regex]::Escape($NextFunctionName) + '\b)'
        $match = [regex]::Match($Text, $pattern)
        if ($match.Success) { return $match.Value }
        return ''
    }

    function script:ConvertTo-FlowText {
        param([Parameter(Mandatory)][string]$Text)

        $arrow = [string][char]0x2192
        return (($Text -replace $arrow, '->') -replace '\s+', ' ').Trim()
    }

    function script:Get-LegacyPassBlockReference {
        $roots = @('agents', 'commands', 'skills', 'frame', 'Documents', '.github/scripts', '.github/templates', '.github/workflows')
        $results = [System.Collections.Generic.List[object]]::new()

        foreach ($root in $roots) {
            $rootPath = script:Resolve-RepoPath -Path $root
            if (-not (Test-Path -LiteralPath $rootPath)) { continue }

            Get-ChildItem -LiteralPath $rootPath -Recurse -File -Include *.md, *.ps1, *.json, *.yml, *.yaml |
                Where-Object {
                    $relative = [System.IO.Path]::GetRelativePath($script:RepoRoot, $_.FullName) -replace '\\', '/'
                    $relative -ne '.github/scripts/Tests/atomic-adversarial-pipeline.Tests.ps1' -and
                    $relative -notlike '.github/scripts/Tests/fixtures/adversarial-pipeline/*'
                } |
                ForEach-Object {
                    $relative = [System.IO.Path]::GetRelativePath($script:RepoRoot, $_.FullName) -replace '\\', '/'
                    $lines = Get-Content -LiteralPath $_.FullName
                    for ($i = 0; $i -lt $lines.Count; $i++) {
                        if ($lines[$i] -match 'pass-blocks') {
                            $contextStart = [Math]::Max(0, $i - 3)
                            $contextEnd = [Math]::Min($lines.Count - 1, $i + 3)
                            [void]$results.Add([pscustomobject]@{
                                Path = $relative
                                Line = $i + 1
                                Text = $lines[$i]
                                Context = ($lines[$contextStart..$contextEnd] -join "`n")
                            })
                        }
                    }
                }
        }

        return $results.ToArray()
    }
}

Describe 'Atomic adversarial pipeline structural contract' {
    Context 'Parser fixtures' {
        It 'parses shuffled integrity-contract keys without order dependence' {
            $frontMatter = script:Read-FrontMatter -Path '.github/scripts/Tests/fixtures/adversarial-pipeline/key-order-shuffled-integrity-contract.md'
            $contract = script:Get-YamlValue -Map $frontMatter -Key 'integrity-contract'

            @('pipeline-stages', 'atomic', 'prosecution-passes', 'exempt') | ForEach-Object {
                script:Test-YamlKey -Map $contract -Key $_ | Should -BeTrue
            }
            @(script:ConvertTo-ValueArray -Value (script:Get-YamlValue -Map $contract -Key 'pipeline-stages')) | Should -Be @('prosecution', 'defense', 'judge')
            @(script:ConvertTo-ValueArray -Value (script:Get-YamlValue -Map $contract -Key 'prosecution-passes')) | Should -Be @(1, 2, 3)
        }

        It 'keeps legacy pass-blocks fixtures from satisfying the new unified contract' {
            $frontMatter = script:Read-FrontMatter -Path '.github/scripts/Tests/fixtures/adversarial-pipeline/legacy-plan-pass-blocks.md'
            $contract = script:Get-YamlValue -Map $frontMatter -Key 'integrity-contract'

            script:Test-YamlKey -Map $contract -Key 'pass-blocks' | Should -BeTrue
            script:Test-YamlKey -Map $contract -Key 'prosecution-passes' | Should -BeFalse
        }

        It 'captures the expected post-fix review credit shape' {
            $fixture = script:Read-RepoYaml -Path '.github/scripts/Tests/fixtures/adversarial-pipeline/post-fix-credit-shape.yaml'

            $fixture.adapter | Should -Be 'post-fix'
            @(script:ConvertTo-ValueArray -Value $fixture.'integrity-check'.'prosecution-passes') | Should -Be @(1)
            script:Test-YamlKey -Map $fixture.'integrity-check' -Key 'pass-blocks' | Should -BeFalse
        }
    }

    Context 'Canonical adversarial-review guidance' {
        It 'defines pipeline flow and atomic discipline with all interrupt boundaries' {
            $skill = script:Read-RepoText -Path 'skills/adversarial-review/SKILL.md'

            $skill | Should -Match '(?m)^## Pipeline Flow\s*$'
            $skill | Should -Match '(?m)^## Atomic Pipeline Discipline\s*$'
            $skill | Should -Match '(?is)(no[- ]surfacing|must not surface|do not surface)'
            $skill | Should -Match '(?is)(no[- ]edits|must not edit|do not edit|working-tree edits are forbidden)'
            $skill | Should -Match '(?is)(no[- ]questions|must not ask|do not ask|AskUserQuestion is forbidden)'
            $skill | Should -Match '(?is)retry\s+exception'
            $skill | Should -Match '(?is)prosecutor[- ]set\s+interrupt\s+exception'
        }
    }

    Context 'Adapter integrity contracts' {
        It 'declares the unified contract on every named adversarial adapter' {
            foreach ($adapterName in $script:ExpectedAdapterNames) {
                $path = "skills/adversarial-review/adapters/$adapterName.md"
                script:Test-RepoPath -Path $path | Should -BeTrue -Because "$adapterName must be an adapter file"
                if (-not (script:Test-RepoPath -Path $path)) { continue }

                $content = script:Read-RepoText -Path $path
                $frontMatter = script:Read-FrontMatter -Path $path
                $contract = script:Get-YamlValue -Map $frontMatter -Key 'integrity-contract'

                $content | Should -Not -Match '(?m)^\s*pass-blocks\s*:'
                script:Test-YamlKey -Map $frontMatter -Key 'integrity-contract' | Should -BeTrue -Because "$adapterName must declare integrity-contract"
                @('pipeline-stages', 'atomic', 'prosecution-passes', 'exempt') | ForEach-Object {
                    script:Test-YamlKey -Map $contract -Key $_ | Should -BeTrue -Because "$adapterName integrity-contract must include $_"
                }

                $stages = @(script:ConvertTo-ValueArray -Value (script:Get-YamlValue -Map $contract -Key 'pipeline-stages'))
                if ($stages.Count -gt 1) {
                    script:Assert-YamlBooleanTrue -Value (script:Get-YamlValue -Map $contract -Key 'atomic') -Because "$adapterName spans multiple stages and must be atomic"
                }
            }
        }

        It 'defines the design-challenge adapter as prosecution-only methodology without port ownership' {
            $path = 'skills/adversarial-review/adapters/design-challenge.md'
            script:Test-RepoPath -Path $path | Should -BeTrue
            if (-not (script:Test-RepoPath -Path $path)) { return }

            $frontMatter = script:Read-FrontMatter -Path $path
            $contract = script:Get-YamlValue -Map $frontMatter -Key 'integrity-contract'
            $designChallengeSection = script:Get-MarkdownSection -Text (script:Read-RepoText -Path 'skills/design-exploration/SKILL.md') -Heading 'Design Challenge (3-Pass, Non-Blocking)'

            @(script:ConvertTo-ValueArray -Value (script:Get-YamlValue -Map $contract -Key 'pipeline-stages')) | Should -Be @('prosecution')
            script:Test-YamlKey -Map $frontMatter -Key 'provides' | Should -BeFalse
            script:Test-YamlKey -Map $frontMatter -Key 'applies-when' | Should -BeFalse
            $designChallengeSection | Should -Match 'skills/adversarial-review/adapters/design-challenge\.md'
        }
    }

    Context 'Claude dispatcher checklist' {
        It 'is a sentinel-bounded dispatcher template with positive subagent checks' {
            script:Test-RepoPath -Path $script:DispatcherPath | Should -BeTrue
            if (-not (script:Test-RepoPath -Path $script:DispatcherPath)) { return }

            $dispatcher = script:Read-RepoText -Path $script:DispatcherPath
            @(
                '<!-- adversarial-prosecution-dispatch-begin -->',
                '<!-- adversarial-prosecution-dispatch-end -->',
                '<!-- adversarial-defense-dispatch-begin -->',
                '<!-- adversarial-defense-dispatch-end -->'
            ) | ForEach-Object {
                $dispatcher | Should -Match ([regex]::Escape($_))
            }

            $dispatcher | Should -Match 'subagent_type:\s*code-critic'
            $dispatcher | Should -Match 'subagent_type:\s*code-review-response'
        }

        It 'does not allow structured questions inside the atomic prosecution-to-defense window' {
            $dispatcher = script:Read-RepoText -Path $script:DispatcherPath
            $window = script:Get-SentinelWindow -Text $dispatcher -Begin '<!-- adversarial-prosecution-dispatch-begin -->' -End '<!-- adversarial-defense-dispatch-end -->'

            $window | Should -Not -BeNullOrEmpty
            $window | Should -Not -Match 'AskUserQuestion'
            $dispatcher | Should -Match '(?is)sub[- ]skill.*indirection.*boundary|known.*indirection.*boundary|boundary.*sub[- ]skill'
        }

        It 'emits the atomic completion marker with consistent ISSUE_ID variable usage' {
            $dispatcher = script:Read-RepoText -Path $script:DispatcherPath
            $dispatcher | Should -Match ([regex]::Escape($script:DispatcherMarker))
            $dispatcher | Should -Not -Match 'adversarial-pipeline-atomic-\{ISSUE_NUMBER\}'

            @(
                'skills/adversarial-review/platforms/claude.md',
                '.github/scripts/frame-credit-ledger.ps1',
                '.github/scripts/lib/frame-credit-ledger-core.ps1',
                'skills/frame-credit-ledger/SKILL.md',
                'frame/pipeline-metrics-v4-schema.md'
            ) | ForEach-Object {
                script:Read-RepoText -Path $_ | Should -Match ([regex]::Escape($script:DispatcherMarker)) -Because "$_ must use the same marker variable"
            }
        }
    }

    Context 'Thin consumer surfaces' {
        It 'routes all Claude adversarial consumers through the shared dispatcher checklist' {
            $consumerTexts = [ordered]@{
                'commands/plan.md' = script:Read-RepoText -Path 'commands/plan.md'
                'commands/orchestra-review.md' = script:Read-RepoText -Path 'commands/orchestra-review.md'
                'commands/orchestra-review-lite.md' = script:Read-RepoText -Path 'commands/orchestra-review-lite.md'
                'commands/orchestra-review-prosecute.md' = script:Read-RepoText -Path 'commands/orchestra-review-prosecute.md'
                'commands/orchestra-review-defend.md' = script:Read-RepoText -Path 'commands/orchestra-review-defend.md'
                'commands/orchestra-review-judge.md' = script:Read-RepoText -Path 'commands/orchestra-review-judge.md'
                'design-challenge consumer path' = (script:Read-RepoText -Path 'agents/Solution-Designer.agent.md') + "`n" + (script:Read-RepoText -Path 'skills/design-exploration/SKILL.md')
            }

            foreach ($entry in $consumerTexts.GetEnumerator()) {
                $entry.Value | Should -Match 'skills/adversarial-review/platforms/claude\.md' -Because "$($entry.Key) should Read the dispatcher checklist"
                $entry.Value | Should -Match '(?is)\b(Read|load)\b.*skills/adversarial-review/platforms/claude\.md|thin[- ]caller' -Because "$($entry.Key) should be a thin caller"
            }
        }

        It 'collapses consumer narratives while preserving Solution-Designer disposition ordering' {
            $planAuthoring = script:Read-RepoText -Path 'skills/plan-authoring/SKILL.md'
            $designExploration = script:Read-RepoText -Path 'skills/design-exploration/SKILL.md'
            $issuePlanner = script:Read-RepoText -Path 'agents/Issue-Planner.agent.md'
            $solutionDesigner = script:Read-RepoText -Path 'agents/Solution-Designer.agent.md'

            $stressPrep = script:Get-MarkdownSection -Text $planAuthoring -Heading 'Stress-Test Preparation'
            $designChallenge = script:Get-MarkdownSection -Text $designExploration -Heading 'Design Challenge (3-Pass, Non-Blocking)'
            $normalizedDesignPath = script:ConvertTo-FlowText -Text ($solutionDesigner + "`n" + $designExploration)

            $stressPrep | Should -Match 'skills/adversarial-review/platforms/claude\.md'
            $planAuthoring | Should -Match 'Plan Stress-Test.*skills/adversarial-review/platforms/claude\.md'
            $designChallenge | Should -Match 'skills/adversarial-review/platforms/claude\.md'
            $designChallenge | Should -Not -Match '(?m)^### Pass composition\s*$'
            $issuePlanner | Should -Match 'skills/adversarial-review/platforms/claude\.md'
            $normalizedDesignPath | Should -Match 'classify -> escalate load-bearing -> incorporate/dismiss remainder -> emit summary -> update issue body'
        }

        It 'keeps ce_gate false planning free of S1/S2 BDD scenario framing' {
            $planAuthoring = script:Read-RepoText -Path 'skills/plan-authoring/SKILL.md'
            $ceFalseMatches = @([regex]::Matches($planAuthoring, '(?im)^\s*-\s+.*ce_gate:\s*false.*$'))

            $ceFalseMatches.Count | Should -BeGreaterThan 0
            foreach ($match in $ceFalseMatches) {
                $match.Value | Should -Not -Match '\bS1\b|\bS2\b|BDD'
            }
        }
    }

    Context 'Solution-authoring classification gate timing' {
        It 'fires after the terminal stage for atomic multi-stage adapters and distinguishes re-audit timing' {
            $solutionAuthoring = script:Read-RepoText -Path 'skills/solution-authoring/SKILL.md'
            $section = script:Get-MarkdownSection -Text $solutionAuthoring -Heading 'Applying the gate to adversarial-review dispositions'

            $section | Should -Match '(?is)atomic.*multi[- ]stage.*adapter'
            $section | Should -Match '(?is)after.*judge|terminal.*stage'
            $section | Should -Match '(?is)prosecution[- ]only.*merged[- ]ledger|merged[- ]ledger.*prosecution[- ]only'
            $section | Should -Match '(?is)re-audit.*timing|timing.*re-audit'
        }
    }

    Context 'Review credit ledger schema and legacy terminology' {
        It 'Build-ReviewCreditRow reads and emits prosecution-passes and treats post-fix as one prosecution pass' {
            $core = script:Read-RepoText -Path '.github/scripts/lib/frame-credit-ledger-core.ps1'
            $integrityBlock = script:Get-FunctionBlock -Text $core -FunctionName 'script:Resolve-FCLReviewIntegrityContract' -NextFunctionName 'Build-ReviewCreditRow'
            $functionBlock = script:Get-FunctionBlock -Text $core -FunctionName 'Build-ReviewCreditRow' -NextFunctionName 'Build-ProcessReviewCreditRow'

            $integrityBlock | Should -Not -BeNullOrEmpty
            $integrityBlock | Should -Match 'prosecution-passes'
            $integrityBlock | Should -Match "AdapterName\s+-in\s+@\([^\)]*'post-fix'"
            $integrityBlock | Should -Match "post-fix(?s).*@\(1\)|@\(1\)(?s).*post-fix"
            $functionBlock | Should -Not -BeNullOrEmpty
            $functionBlock | Should -Match 'prosecution-passes'
            $functionBlock | Should -Match "'prosecution-passes'\s*="
            $functionBlock | Should -Match 'Resolve-FCLReviewIntegrityContract'
        }

        It 'removes active pass-blocks terminology except explicitly documented compatibility shims' {
            $legacyReferences = @(script:Get-LegacyPassBlockReference)
            $unexpected = @($legacyReferences | Where-Object {
                $_.Context -notmatch '(?is)compat[- ]shim|compatibility shim|legacy compatibility'
            })

            $unexpected | Should -Be @()
        }
    }

    Context 'Finding pause contract' {
        It 'adds requires_pipeline_pause with the same closed reasons in Code-Critic and routing config' {
            $codeCritic = script:Read-RepoText -Path 'agents/Code-Critic.agent.md'
            $findingCategories = script:Get-MarkdownSection -Text $codeCritic -Heading 'Finding Categories'
            $config = ConvertFrom-Json -InputObject (script:Read-RepoText -Path 'skills/routing-tables/assets/routing-config.json')

            $findingCategories | Should -Match 'requires_pipeline_pause:\s*\{\s*reason:\s*artifact-missing\s*\|\s*runtime-output-required\s*\|\s*user-input-required-by-decision-class\s*\}'
            $config.enums.requires_pipeline_pause_reason | Should -Not -BeNullOrEmpty
            @($config.enums.requires_pipeline_pause_reason) | Should -Be $script:PauseReasons
        }
    }
}
