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
        $script:ClaudeDispatcherPath = Join-Path $script:RepoRoot 'skills/adversarial-review/platforms/claude.md'
        $script:ClaudeDispatcherContent = Get-Content -Path $script:ClaudeDispatcherPath -Raw -ErrorAction Stop
        $script:RoutingConfigPath = Join-Path $script:RepoRoot 'skills/routing-tables/assets/routing-config.json'
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
                ExpectedProsecutionMarker   = 'Use code review perspectives'
                RequiresDefaultRouteNote    = $false
                ExpectedSubagents           = @('code-critic', 'code-review-response')
                ExpectedReviewStatePatterns = @(
                    '/memories/session/review-state-\{ISSUE_ID\}\.md',
                    'review_mode: full',
                    'prosecution_complete: true',
                    'defense_complete: true',
                    'judgment_complete: true',
                    'last_updated'
                )
            },
            [pscustomobject]@{
                Name                        = 'orchestra-review-lite'
                Path                        = Join-Path $script:CommandsDirectory 'orchestra-review-lite.md'
                ExpectedProsecutionMarker   = 'Use lite code review perspectives'
                RequiresDefaultRouteNote    = $false
                ExpectedSubagents           = @('code-critic')
                ExpectedReviewStatePatterns = @(
                    'does not write terminal review-state persistence',
                    'no terminal-state persistence is required by this adapter'
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
                return $Content
            }

            return $match.Groups['body'].Value
        }

        $script:GetEffectiveContract = {
            param([string]$CommandContent)

            return ($CommandContent + "`n" + $script:ClaudeDispatcherContent)
        }

        $script:MatchesAnyPattern = {
            param(
                [string]$Content,
                [string[]]$Patterns
            )

            foreach ($pattern in $Patterns) {
                if ($Content -match $pattern) {
                    return $true
                }
            }

            return $false
        }

        $script:AssertNoAffirmativeSingletonRecovery = {
            param(
                [string]$Content,
                [string]$CommandName
            )

            $recoveryWindows = [regex]::Matches(
                $Content,
                '(?is).{0,120}(?:2-of-3|two-of-three|two of three|pipeline-degraded).{0,120}'
            )

            foreach ($window in $recoveryWindows) {
                $window.Value | Should -Match '(?is)\b(?:no|not|never|without|does not|must not|halt-strict|halt strict|halt|stop|instead)\b' -Because "$CommandName must not document 2-of-3 or pipeline-degraded as an available singleton body-load recovery path"
            }
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

            $content = & $script:GetEffectiveContract -CommandContent (& $script:ReadContent -Path $spec.Path)
            $frontmatter = & $script:ParseFrontmatter -Content $content
            $expectedHeading = '# /' + ($spec.Name -replace '^orchestra-', 'orchestra:')

            $frontmatter.description | Should -Not -BeNullOrEmpty -Because "$($spec.Name) must declare a description in frontmatter"
            $frontmatter.'argument-hint' | Should -Not -BeNullOrEmpty -Because "$($spec.Name) must declare an argument-hint in frontmatter"
            $content | Should -Match ('(?m)^' + [regex]::Escape($expectedHeading) + '\r?$') -Because "$($spec.Name) must expose the slash-command heading"
        }
    }

    It 'locks the prosecution marker expectations per command' {
        foreach ($spec in $script:CommandSpecs) {
            $commandContent = & $script:ReadContent -Path $spec.Path
            $content = if ($null -eq $spec.ExpectedProsecutionMarker) {
                $commandContent
            }
            else {
                & $script:GetEffectiveContract -CommandContent $commandContent
            }

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
            $content = & $script:GetEffectiveContract -CommandContent (& $script:ReadContent -Path $spec.Path)

            foreach ($subagent in $spec.ExpectedSubagents) {
                $content | Should -Match ([regex]::Escape("subagent_type: $subagent")) -Because "$($spec.Name) must route to $subagent"
            }
        }
    }

    It 'locks the authoritative dispatch wording for each command mode contract' {
        foreach ($spec in $script:CommandSpecs) {
            $commandContent = & $script:ReadContent -Path $spec.Path

            $commandContent | Should -Match 'skills/adversarial-review/platforms/claude\.md' -Because "$($spec.Name) must delegate detailed dispatch rules to the shared Claude dispatcher checklist"

            $dispatchSection = & $script:GetDispatchSection -Content (& $script:GetEffectiveContract -CommandContent $commandContent)

            foreach ($pattern in $spec.ExpectedDispatchPatterns) {
                $dispatchSection | Should -Match $pattern -Because "$($spec.Name) must keep its dispatch wording authoritative so carried context cannot silently redefine the review mode or payload contract"
            }
        }
    }

    It 'documents body-load recovery for the redundant full-review prosecution passes' {
        $content = & $script:GetEffectiveContract -CommandContent (& $script:ReadContent -Path (Join-Path $script:CommandsDirectory 'orchestra-review.md'))

        $content | Should -Match '(?is)(?:three-pass|three|3|redundant).{0,180}(?:Code-Critic\s+)?prosecution|(?:Code-Critic\s+)?prosecution.{0,180}(?:three-pass|three|3|redundant)' -Because '/orchestra:review must document that the full pipeline uses redundant prosecution passes before degraded recovery can apply'

        $bodyLoadFailureIsPassFailure = & $script:MatchesAnyPattern -Content $content -Patterns @(
            '(?is)(?:Code-Critic|prosecution).{0,260}(?:body-load|body load|shared-body|shared body|body).{0,180}(?:fail|failure|failed|missing|malformed|not load|cannot load)',
            '(?is)(?:body-load|body load|shared-body|shared body|body).{0,180}(?:fail|failure|failed|missing|malformed|not load|cannot load).{0,260}(?:Code-Critic|prosecution)'
        )
        $bodyLoadFailureIsPassFailure | Should -BeTrue -Because '/orchestra:review must classify a failed or malformed Code-Critic prosecution body-load as a failed prosecution pass'

        $content | Should -Match '(?is)\bretry\b.{0,80}\bonce\b|\bonce\b.{0,80}\bretry\b' -Because '/orchestra:review must retry a failed or malformed prosecution body-load pass once before degrading'
        $content | Should -Match '(?is)\bpipeline-degraded\b' -Because '/orchestra:review must make the degraded prosecution path visible'
        $content | Should -Match '(?is)(?:merged\s+)?prosecution ledger|adapter''s allowed merged prosecution ledger' -Because '/orchestra:review must continue only with an explicit merged prosecution ledger when enough prosecution passes remain'
        $content | Should -Match '(?is)(?:quorum|survive|at least.{0,60}generalist.{0,120}specialist)' -Because '/orchestra:review must say the pipeline continues only when the quorum requirement is met (at least 1 generalist and 1 specialist survive) — generic pass-count language without explicit generalist+specialist does not satisfy this requirement'
    }

    It 'documents halt-strict body-load behavior for composite defense and judge stages' {
        $compositeSpecs = @(
            [pscustomobject]@{
                Name = 'orchestra-review'
                Path = Join-Path $script:CommandsDirectory 'orchestra-review.md'
            },
            [pscustomobject]@{
                Name = 'orchestra-review-lite'
                Path = Join-Path $script:CommandsDirectory 'orchestra-review-lite.md'
            }
        )

        $stageSpecs = @(
            [pscustomobject]@{
                Name         = 'defense'
                Body         = 'Code-Critic'
                StagePattern = 'defense'
            },
            [pscustomobject]@{
                Name         = 'judge'
                Body         = 'Code-Review-Response'
                StagePattern = 'judge|judgment'
            }
        )

        foreach ($command in $compositeSpecs) {
            $content = & $script:GetEffectiveContract -CommandContent (& $script:ReadContent -Path $command.Path)

            foreach ($stage in $stageSpecs) {
                $bodyPattern = [regex]::Escape($stage.Body)
                $strictBodyLoadFailure = & $script:MatchesAnyPattern -Content $content -Patterns @(
                    "(?is)(?:$($stage.StagePattern)|$bodyPattern).{0,260}(?:body-load|body load|shared-body|shared body|body).{0,220}(?:fail|failure|failed|missing|malformed|not load|cannot load).{0,260}(?:halt-strict|halt strict|halt|stop|cannot continue|do not continue)",
                    "(?is)(?:body-load|body load|shared-body|shared body|body).{0,220}(?:fail|failure|failed|missing|malformed|not load|cannot load).{0,260}(?:$($stage.StagePattern)|$bodyPattern).{0,260}(?:halt-strict|halt strict|halt|stop|cannot continue|do not continue)",
                    "(?is)(?:body-load|body load|shared-body|shared body|body).{0,220}(?:fail|failure|failed|missing|malformed|not load|cannot load).{0,260}(?:halt-strict|halt strict|halt|stop|cannot continue|do not continue).{0,260}(?:$($stage.StagePattern)|$bodyPattern)"
                )
                $strictBodyLoadFailure | Should -BeTrue -Because "$($command.Name) must state that composite $($stage.Name) body-load failure halts strict"
            }

            $singletonRecoveryWindows = [regex]::Matches(
                $content,
                '(?is).{0,140}(?:defense|judge|judgment|Code-Review-Response).{0,140}(?:pipeline-degraded|2-of-3|two-of-three|two of three|degradation|degraded).{0,140}|.{0,140}(?:pipeline-degraded|2-of-3|two-of-three|two of three|degradation|degraded).{0,140}(?:defense|judge|judgment|Code-Review-Response).{0,140}'
            )

            foreach ($window in $singletonRecoveryWindows) {
                $window.Value | Should -Match '(?is)\b(?:no|not|never|without|does not|must not|only|except|halt-strict|halt strict|halt|stop)\b' -Because "$($command.Name) must not imply that composite defense or judge body-load failures can use degraded prosecution recovery"
            }
        }
    }

    It 'documents halt-strict body-load behavior for singleton review command stages' {
        $singletonSpecs = @(
            [pscustomobject]@{
                Name             = 'orchestra-review-lite'
                Path             = Join-Path $script:CommandsDirectory 'orchestra-review-lite.md'
                Stage            = 'prosecution'
                Body             = 'Code-Critic'
                SingletonPattern = '(?is)(?:one|single).{0,120}(?:all-perspectives\s+|compact\s+)?prosecution pass|prosecution pass.{0,120}(?:one|single)'
            },
            [pscustomobject]@{
                Name             = 'orchestra-review-prosecute'
                Path             = Join-Path $script:CommandsDirectory 'orchestra-review-prosecute.md'
                Stage            = 'prosecution'
                Body             = 'Code-Critic'
                SingletonPattern = '(?is)Run only the Code-Critic prosecution stage|single.{0,80}prosecution|prosecution.{0,160}stops before defense and judge'
            },
            [pscustomobject]@{
                Name             = 'orchestra-review-defend'
                Path             = Join-Path $script:CommandsDirectory 'orchestra-review-defend.md'
                Stage            = 'defense'
                Body             = 'Code-Critic'
                SingletonPattern = '(?is)Run only the Code-Critic defense stage|single.{0,80}defense|defense.{0,160}stops before judge'
            },
            [pscustomobject]@{
                Name             = 'orchestra-review-judge'
                Path             = Join-Path $script:CommandsDirectory 'orchestra-review-judge.md'
                Stage            = 'judge|judgment'
                Body             = 'Code-Review-Response'
                SingletonPattern = '(?is)Run only the Code-Review-Response judge stage|single.{0,80}(?:judge|judgment)|Use the `Agent` tool with `subagent_type: code-review-response`'
            }
        )

        foreach ($spec in $singletonSpecs) {
            $commandContent = & $script:ReadContent -Path $spec.Path
            $content = & $script:GetEffectiveContract -CommandContent $commandContent
            $bodyPattern = [regex]::Escape($spec.Body)

            $content | Should -Match $spec.SingletonPattern -Because "$($spec.Name) must document its stage as a singleton rather than a redundant prosecution set"

            $strictBodyLoadFailure = & $script:MatchesAnyPattern -Content $content -Patterns @(
                "(?is)Singleton $($spec.Stage) paths are halt-strict",
                "(?is)Singleton $($spec.Stage) paths are halt-strict:.{0,260}stop",
                "(?is)Singleton $($spec.Stage) paths are halt-strict:.{0,260}body load fails",
                "(?is)Singleton $($spec.Stage) paths are halt-strict:.{0,260}$bodyPattern"
            )
            $strictBodyLoadFailure | Should -BeTrue -Because "$($spec.Name) must make $($spec.Body) $($spec.Stage) body-load failure halt-strict"

            & $script:AssertNoAffirmativeSingletonRecovery -Content $commandContent -CommandName $spec.Name
        }
    }

    It 'locks the review-state persistence wording for each review command' {
        foreach ($spec in $script:CommandSpecs) {
            $content = & $script:GetEffectiveContract -CommandContent (& $script:ReadContent -Path $spec.Path)

            $content | Should -Match '(?ms)^\*\*Review-state persistence\*\*:\s*\r?\n' -Because "$($spec.Name) must document review-state persistence"

            foreach ($pattern in $spec.ExpectedReviewStatePatterns) {
                $content | Should -Match $pattern -Because "$($spec.Name) must preserve its review-state persistence contract wording"
            }
        }
    }
}
