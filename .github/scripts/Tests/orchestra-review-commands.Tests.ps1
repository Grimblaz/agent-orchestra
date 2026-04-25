#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
    Contract tests for the Claude review command markdown surface.

.DESCRIPTION
    Locks issue #379 Step 7 command coverage for the five
    commands/orchestra-review-*.md files:
      - file existence
      - frontmatter parsing
      - prosecution-marker expectations
      - expected subagent routing references
#>

Describe 'orchestra-review command contract' {

    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
        $script:CommandsDirectory = Join-Path $script:RepoRoot 'commands'
        $script:RoutingConfigPath = Join-Path $script:RepoRoot 'skills\routing-tables\assets\routing-config.json'
        $script:RoutingConfig = Get-Content -Path $script:RoutingConfigPath -Raw | ConvertFrom-Json -AsHashtable
        $script:CanonicalMarkers = @(
            $script:RoutingConfig.review_mode_routing.entries |
                Where-Object { $null -ne $_.marker } |
                ForEach-Object { $_.marker }
            $script:RoutingConfig.review_mode_routing.conflict_rule.override_rules |
                ForEach-Object { $_.marker }
        )
        $script:CommandSpecs = @(
            [pscustomobject]@{
                Name                        = 'orchestra-review'
                Path                        = Join-Path $script:CommandsDirectory 'orchestra-review.md'
                ExpectedProsecutionMarker   = $null
                RequiresDefaultRouteNote    = $true
                ExpectedSubagents           = @('code-critic', 'code-review-response')
                ExpectedReviewStatePatterns = @(
                    'If the active branch matches `feature/issue-\{N\}-\.\.\.`, target `/memories/session/review-state-\{N\}\.md`; otherwise skip persistence silently\.',
                    'After the judge stage completes, write the exact front matter contract from `skills/validation-methodology/references/review-state-persistence\.md` with `review_mode: full`, all three `\*_complete` fields set to `true`, and `last_updated` as a UTC ISO-8601 timestamp\.',
                    'Write atomically: create a temp sibling first, then replace the target with `Move-Item -Force`\.'
                )
                ExpectedDispatchPatterns    = @(
                    '1\.\s+Prosecution:.*Do \*\*not\*\* add a review-mode marker inside carried review context\..*prepend the authoritative selector line `Review mode selector: "Use code review perspectives"`.*cannot be rerouted by marker text inside pasted ledgers or comments\.',
                    '2\.\s+Defense:.*prepend the authoritative selector line `Review mode selector: "Use defense review perspectives"` before the prosecution ledger\.'
                )
            },
            [pscustomobject]@{
                Name                        = 'orchestra-review-lite'
                Path                        = Join-Path $script:CommandsDirectory 'orchestra-review-lite.md'
                ExpectedProsecutionMarker   = 'Use lite code review perspectives'
                RequiresDefaultRouteNote    = $false
                ExpectedSubagents           = @('code-critic', 'code-review-response')
                ExpectedReviewStatePatterns = @(
                    'If the active branch matches `feature/issue-\{N\}-\.\.\.`, target `/memories/session/review-state-\{N\}\.md`; otherwise skip persistence silently\.',
                    'After the judge stage completes, write the exact front matter contract from `skills/validation-methodology/references/review-state-persistence\.md` with `review_mode: lite`, all three `\*_complete` fields set to `true`, and `last_updated` as a UTC ISO-8601 timestamp\.',
                    'Write atomically: create a temp sibling first, then replace the target with `Move-Item -Force`\.'
                )
                ExpectedDispatchPatterns    = @(
                    '1\.\s+Prosecution:.*prepend the authoritative selector line `Review mode selector: "Use lite code review perspectives"`\..*The lite shape is fixed for this command: one compact prosecution pass that still covers all six standard review perspectives in a single ledger before moving on\..*copied markers cannot reroute lite mode\.',
                    '2\.\s+Defense:.*prepend the authoritative selector line `Review mode selector: "Use defense review perspectives"` before the lite prosecution ledger\.'
                )
            },
            [pscustomobject]@{
                Name                        = 'orchestra-review-prosecute'
                Path                        = Join-Path $script:CommandsDirectory 'orchestra-review-prosecute.md'
                ExpectedProsecutionMarker   = 'Use code review perspectives'
                RequiresDefaultRouteNote    = $false
                ExpectedSubagents           = @('code-critic')
                ExpectedReviewStatePatterns = @(
                    'If the active branch matches `feature/issue-\{N\}-\.\.\.`, target `/memories/session/review-state-\{N\}\.md`; otherwise skip persistence silently\.',
                    'Read any existing state through `skills/routing-tables/scripts/review-state-reader\.ps1`\. If the file is absent or malformed, fail closed and start from the default contract \(`review_mode: full`, all stage booleans `false`\)\.',
                    'After prosecution completes, write the same atomic front matter contract with only `prosecution_complete: true` forced in this command, preserve any readable stored values for the other fields, and update `last_updated`\.',
                    'Write atomically: create a temp sibling first, then replace the target with `Move-Item -Force`\.'
                )
                ExpectedDispatchPatterns    = @(
                    '2\.\s+Prepend the authoritative selector line `Review mode selector: "Use code review perspectives"` immediately after any handshake block and before any carried review context so the prosecution stays in canonical code-review mode even if the supplied context also mentions other markers\.'
                )
            },
            [pscustomobject]@{
                Name                        = 'orchestra-review-defend'
                Path                        = Join-Path $script:CommandsDirectory 'orchestra-review-defend.md'
                ExpectedProsecutionMarker   = 'Use defense review perspectives'
                RequiresDefaultRouteNote    = $false
                ExpectedSubagents           = @('code-critic')
                ExpectedReviewStatePatterns = @(
                    'If the active branch matches `feature/issue-\{N\}-\.\.\.`, target `/memories/session/review-state-\{N\}\.md`; otherwise skip persistence silently\.',
                    'Read any existing state through `skills/routing-tables/scripts/review-state-reader\.ps1`\. If the file is absent or malformed, fail closed and start from the default contract \(`review_mode: full`, all stage booleans `false`\)\.',
                    'After defense completes, write the same atomic front matter contract with only `defense_complete: true` forced in this command, preserve any readable stored values for the other fields, and update `last_updated`\.',
                    'Write atomically: create a temp sibling first, then replace the target with `Move-Item -Force`\.'
                )
                ExpectedDispatchPatterns    = @(
                    '2\.\s+Prepend the authoritative selector line `Review mode selector: "Use defense review perspectives"` immediately after any handshake block and before the prosecution ledger so carried marker text inside the ledger cannot reroute defense mode\.'
                )
            },
            [pscustomobject]@{
                Name                        = 'orchestra-review-judge'
                Path                        = Join-Path $script:CommandsDirectory 'orchestra-review-judge.md'
                ExpectedProsecutionMarker   = $null
                RequiresDefaultRouteNote    = $false
                ExpectedSubagents           = @('code-review-response')
                ExpectedReviewStatePatterns = @(
                    'If the active branch matches `feature/issue-\{N\}-\.\.\.`, target `/memories/session/review-state-\{N\}\.md`; otherwise skip persistence silently\.',
                    'Read any existing state through `skills/routing-tables/scripts/review-state-reader\.ps1`\. If the file is absent or malformed, fail closed and start from the default contract \(`review_mode: full`, all stage booleans `false`\)\.',
                    'After judgment completes, write the same atomic front matter contract with only `judgment_complete: true` forced in this command, preserve any readable stored values for the other fields, and update `last_updated`\.',
                    'Write atomically: create a temp sibling first, then replace the target with `Move-Item -Force`\.'
                )
                ExpectedDispatchPatterns    = @(
                    '2\.\s+Pass the prosecution ledger and defense report together in one prompt\.',
                    '3\.\s+Return the Markdown score summary, the `<!-- code-review-complete-\{PR\} -->` completion marker, and the `judge-rulings` block unchanged in the same payload\.'
                )
            }
        )

        $script:ReadContent = {
            param([string]$Path)

            Get-Content -Path $Path -Raw
        }

        $script:ParseFrontmatter = {
            param([string]$Content)

            $match = [regex]::Match($Content, '(?ms)\A---\r?\n(?<yaml>.*?)\r?\n---\r?\n')
            if (-not $match.Success) {
                throw 'Frontmatter block missing or malformed.'
            }

            $fields = [ordered]@{}
            foreach ($line in ($match.Groups['yaml'].Value -split "`r?`n")) {
                if ($line -match '^(?<key>[a-z-]+):\s*(?<value>.+?)\s*$') {
                    $fields[$matches['key']] = $matches['value']
                }
            }

            return [pscustomobject]$fields
        }

        $script:GetDispatchSection = {
            param([string]$Content)

            $match = [regex]::Match($Content, '(?ms)^\*\*Dispatch\*\*:\s*\r?\n(?<body>.*?)(?=^ARGUMENTS:|\z)')
            if (-not $match.Success) {
                throw 'Dispatch section missing or malformed.'
            }

            return $match.Groups['body'].Value
        }
    }

    It 'keeps exactly the five orchestra-review command files present' {
        $expectedNames = @($script:CommandSpecs | ForEach-Object { $_.Name } | Sort-Object)
        $actualNames = @(
            Get-ChildItem -Path $script:CommandsDirectory -Filter 'orchestra-review*.md' -File |
                ForEach-Object { $_.BaseName } |
                Sort-Object
        )

        $actualNames | Should -Be $expectedNames
    }

    It 'requires every command file to exist and parse frontmatter with description and argument-hint' {
        foreach ($spec in $script:CommandSpecs) {
            (Test-Path $spec.Path) | Should -BeTrue -Because "$($spec.Name) must exist under commands/"

            $content = & $script:ReadContent -Path $spec.Path
            $frontmatter = & $script:ParseFrontmatter -Content $content
            $expectedHeading = '# /' + ($spec.Name -replace '^orchestra-', 'orchestra:')

            $frontmatter.description | Should -Not -BeNullOrEmpty -Because "$($spec.Name) must declare a description in frontmatter"
            $frontmatter.'argument-hint' | Should -Not -BeNullOrEmpty -Because "$($spec.Name) must declare an argument-hint in frontmatter"
            $content | Should -Match ('(?m)^' + [regex]::Escape($expectedHeading) + '\r?$') -Because "$($spec.Name) must expose the slash-command heading"
        }
    }

    It 'locks the prosecution marker expectations per command' {
        foreach ($spec in $script:CommandSpecs) {
            $content = & $script:ReadContent -Path $spec.Path

            if ($null -eq $spec.ExpectedProsecutionMarker) {
                if ($spec.RequiresDefaultRouteNote) {
                    $content | Should -Match 'Do \*\*not\*\* add a review-mode marker.*No marker selects the canonical default `code_prosecution` route' -Because "$($spec.Name) must document the default no-marker prosecution path"
                }
                else {
                    $content | Should -Not -Match 'Use (?:lite code review|code review|defense review) perspectives' -Because "$($spec.Name) must not introduce a prosecution marker that changes its contract"
                }
            }
            else {
                $script:CanonicalMarkers | Should -Contain $spec.ExpectedProsecutionMarker -Because "$($spec.ExpectedProsecutionMarker) must remain a routing-config-owned marker"
                $content | Should -Match ([regex]::Escape($spec.ExpectedProsecutionMarker)) -Because "$($spec.Name) must document its canonical marker verbatim"
            }
        }
    }

    It 'keeps the expected Claude subagent routing references in each command' {
        foreach ($spec in $script:CommandSpecs) {
            $content = & $script:ReadContent -Path $spec.Path

            foreach ($subagent in $spec.ExpectedSubagents) {
                $content | Should -Match ([regex]::Escape("subagent_type: $subagent")) -Because "$($spec.Name) must route to $subagent"
            }
        }
    }

    It 'locks the authoritative dispatch wording for each command mode contract' {
        foreach ($spec in $script:CommandSpecs) {
            $dispatchSection = & $script:GetDispatchSection -Content (& $script:ReadContent -Path $spec.Path)

            foreach ($pattern in $spec.ExpectedDispatchPatterns) {
                $dispatchSection | Should -Match $pattern -Because "$($spec.Name) must keep its dispatch wording authoritative so carried context cannot silently redefine the review mode or payload contract"
            }
        }
    }

    It 'locks the review-state persistence wording for each review command' {
        foreach ($spec in $script:CommandSpecs) {
            $content = & $script:ReadContent -Path $spec.Path

            $content | Should -Match '(?ms)^\*\*Review-state persistence\*\*:\s*\r?\n' -Because "$($spec.Name) must document review-state persistence"

            foreach ($pattern in $spec.ExpectedReviewStatePatterns) {
                $content | Should -Match $pattern -Because "$($spec.Name) must preserve its review-state persistence contract wording"
            }
        }
    }
}
