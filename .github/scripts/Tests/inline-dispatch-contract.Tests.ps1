#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
.SYNOPSIS
    Contract tests for inline-dispatch enforcement — DRY shape enforced per #498
    and provenance-gate retirement.

.DESCRIPTION
    Verifies the Claude Code command-file DRY contract across
    commands/experience.md, commands/design.md, commands/plan.md,
    commands/orchestrate.md, and commands/polish.md.

    Issue #481 first established the load-reference pattern for agent bodies.
    Issue #498 reshaped the command-file pre-flight surface into a DRY load
    reference into skills/session-startup/SKILL.md plus a per-command D1
    body-resolution cascade. The provenance-gate retirement removes the
    (formerly second) load reference into skills/provenance-gate/SKILL.md;
    the upstream-onboarding skill now owns the framing/orientation phase.

    The Copilot asymmetry remains tracked by #414.

        Cross-tool asymmetry (D6 of #412): Copilot's .github/prompts/*.prompt.md files
        are thin one-line dispatchers without a parent-side prose surface. Copilot
        inline-dispatch enforcement is owned by the agent body and tracked in #414.

        Canonical option-label extraction continues to pull from skills/session-startup
        so that label changes cause explicit contract-test failures instead of silent drift.
#>

Describe 'inline dispatch contract' {

    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
        $script:SessionStartupSkill = Join-Path $script:RepoRoot 'skills\session-startup\SKILL.md'
        $script:ClaudeDispatcherPath = Join-Path $script:RepoRoot 'skills\adversarial-review\platforms\claude.md'
        $script:ClaudeDispatcherContent = Get-Content -Path $script:ClaudeDispatcherPath -Raw -ErrorAction Stop

        $script:GetPlanEffectiveContract = {
            $planContent = Get-Content -Path (Join-Path $script:RepoRoot 'commands\plan.md') -Raw -ErrorAction Stop
            return ($planContent + "`n" + $script:ClaudeDispatcherContent)
        }

        $script:GetCanonicalLabelYaml = {
            param(
                [string]$SkillPath,
                [string]$Heading
            )

            $content = Get-Content -Path $SkillPath -Raw -ErrorAction Stop
            $pattern = '(?ms)^' + [regex]::Escape($Heading) + '\s*\r?\n\r?\n```yaml\r?\n(?<yaml>.*?)\r?\n```'
            $match = [regex]::Match($content, $pattern)

            $match.Success | Should -BeTrue -Because "$SkillPath must publish the $Heading fenced YAML block"
            if (-not $match.Success) {
                return $null
            }

            return $match.Groups['yaml'].Value
        }

        $script:GetYamlScalarValue = {
            param(
                [System.Text.RegularExpressions.Match]$LineMatch
            )

            if ($LineMatch.Groups['single'].Success) {
                return $LineMatch.Groups['single'].Value
            }

            if ($LineMatch.Groups['double'].Success) {
                return $LineMatch.Groups['double'].Value
            }

            return $LineMatch.Groups['unquoted'].Value
        }

        $script:GetCanonicalLabelMap = {
            param(
                [string]$SkillPath,
                [string]$Heading,
                [int]$ExpectedCount
            )

            $yaml = & $script:GetCanonicalLabelYaml -SkillPath $SkillPath -Heading $Heading
            if ($null -eq $yaml) {
                return [ordered]@{}
            }

            $labels = [ordered]@{}
            $linePattern = '^\s+(?<key>\w+):\s*(?:''(?<single>[^'']*)''|"(?<double>[^"]*)"|(?<unquoted>\S.*?))\s*$'
            foreach ($line in ($yaml -split "`r?`n")) {
                if ($line -match '^\s*$' -or $line -match '^canonical_option_labels:\s*$') {
                    continue
                }

                $lineMatch = [regex]::Match($line, $linePattern)
                $lineMatch.Success | Should -BeTrue -Because "$SkillPath must keep $Heading entries as single-line YAML values"
                if (-not $lineMatch.Success) {
                    continue
                }

                $labels[$lineMatch.Groups['key'].Value] = & $script:GetYamlScalarValue -LineMatch $lineMatch
            }

            $labels.Count | Should -Be $ExpectedCount -Because "$SkillPath must expose $ExpectedCount canonical labels under $Heading"
            return $labels
        }

        $script:GetCanonicalLabelList = {
            param(
                [string]$SkillPath,
                [string]$Heading,
                [int]$ExpectedCount
            )

            $yaml = & $script:GetCanonicalLabelYaml -SkillPath $SkillPath -Heading $Heading
            if ($null -eq $yaml) {
                return @()
            }

            $labels = [System.Collections.Generic.List[string]]::new()
            $linePattern = '^\s*-\s*(?:''(?<single>[^'']*)''|"(?<double>[^"]*)"|(?<unquoted>\S.*?))\s*$'
            foreach ($line in ($yaml -split "`r?`n")) {
                if ($line -match '^\s*$' -or $line -match '^canonical_option_labels:\s*$') {
                    continue
                }

                $lineMatch = [regex]::Match($line, $linePattern)
                $lineMatch.Success | Should -BeTrue -Because "$SkillPath must keep $Heading entries as single-line YAML list items"
                if (-not $lineMatch.Success) {
                    continue
                }

                $labels.Add((& $script:GetYamlScalarValue -LineMatch $lineMatch))
            }

            $labels.Count | Should -Be $ExpectedCount -Because "$SkillPath must expose $ExpectedCount canonical labels under $Heading"
            return @($labels)
        }

        $script:SessionStartupLabels = & $script:GetCanonicalLabelMap -SkillPath $script:SessionStartupSkill -Heading '### Inline-Dispatch Option Labels' -ExpectedCount 4

        $script:BodyResolutionCommandSpecs = @(
            [pscustomobject]@{
                Name                     = '/experience'
                Path                     = 'commands\experience.md'
                BodyFile                 = 'Experience-Owner.agent.md'
                ForbiddenDirectReadPaths = @('agents/Experience-Owner.agent.md')
            },
            [pscustomobject]@{
                Name                     = '/design'
                Path                     = 'commands\design.md'
                BodyFile                 = 'Solution-Designer.agent.md'
                ForbiddenDirectReadPaths = @('agents/Solution-Designer.agent.md')
            },
            [pscustomobject]@{
                Name                     = '/plan'
                Path                     = 'commands\plan.md'
                BodyFile                 = 'Issue-Planner.agent.md'
                ForbiddenDirectReadPaths = @('agents/Issue-Planner.agent.md')
            },
            [pscustomobject]@{
                Name                     = '/polish'
                Path                     = 'commands\polish.md'
                BodyFile                 = 'UI-Iterator.agent.md'
                ForbiddenDirectReadPaths = @('agents/UI-Iterator.agent.md', 'agents/ui-iterator.md')
            },
            [pscustomobject]@{
                Name                     = '/orchestrate'
                Path                     = 'commands\orchestrate.md'
                BodyFile                 = 'Code-Conductor.agent.md'
                ForbiddenDirectReadPaths = @('agents/Code-Conductor.agent.md')
            },
            [pscustomobject]@{
                Name                     = '/code-conductor'
                Path                     = 'commands\code-conductor.md'
                BodyFile                 = 'Code-Conductor.agent.md'
                ForbiddenDirectReadPaths = @('agents/Code-Conductor.agent.md')
            },
            [pscustomobject]@{
                Name                     = '/review-github'
                Path                     = 'commands\review-github.md'
                BodyFile                 = 'Code-Conductor.agent.md'
                ForbiddenDirectReadPaths = @('agents/Code-Conductor.agent.md')
            }
        )
    }

    It 'extracts canonical inline-dispatch labels from the source skill' {
        $script:SessionStartupLabels.Count | Should -Be 4
        $script:SessionStartupLabels['cleanup_yes'] | Should -Be 'Yes — run cleanup'
        $script:SessionStartupLabels['cleanup_no'] | Should -Be 'No — skip for now'
        $script:SessionStartupLabels['drift_stop'] | Should -Be "Stop — I'll restart now"
        $script:SessionStartupLabels['drift_continue'] | Should -Be 'Continue — run under old code'
    }

    It 'requires each command file to carry DRY load references replacing inline pre-flight prose' {
        foreach ($command in $script:BodyResolutionCommandSpecs) {
            $path = Join-Path $script:RepoRoot $command.Path
            $content = Get-Content -Path $path -Raw -ErrorAction Stop
            $escapedBody = [regex]::Escape($command.BodyFile)

            $content | Should -Match ('Load `skills/session-startup/SKILL\.md` and follow Steps 4, 6, 7b, and 9 \(paired body for Step 9: `agents/' + $escapedBody + '`\)\.') -Because "$($command.Name) must carry the canonical session-startup load reference naming its paired body"

            $content | Should -Not -Match 'provenance-gate' -Because "$($command.Name) must not reference the retired provenance-gate skill"
        }
    }

    It 'requires user-facing command entry points to name the paired agent body in the load reference' {
        foreach ($command in $script:BodyResolutionCommandSpecs) {
            $path = Join-Path $script:RepoRoot $command.Path
            $content = Get-Content -Path $path -Raw -ErrorAction Stop
            $bodyPath = 'agents/' + $command.BodyFile
            $bodyPathPattern = [regex]::Escape($bodyPath)

            $content | Should -Match "(?is)(?:resolve|load|follow|paired body).{0,300}$bodyPathPattern" -Because "$($command.Name) must name the shared body path in the session-startup load reference or inline execution section"
        }
    }

    It 'requires user-facing command entry points to resolve shared bodies plugin-cache-first' {
        foreach ($command in $script:BodyResolutionCommandSpecs) {
            $path = Join-Path $script:RepoRoot $command.Path
            $content = Get-Content -Path $path -Raw -ErrorAction Stop
            $bodyPath = 'agents/' + $command.BodyFile
            $cachePath = '~/.claude/plugins/cache/agent-orchestra/agent-orchestra/*/' + $bodyPath
            $bodyPathPattern = [regex]::Escape($bodyPath)
            $cachePathPattern = [regex]::Escape($cachePath)

            $content | Should -Match "(?is)(?:resolve|load|read).{0,220}$bodyPathPattern" -Because "$($command.Name) must name the shared body it will load"
            $content | Should -Match '(?is)~/.claude/plugins/installed_plugins\.json' -Because "$($command.Name) must consult the installed plugin registry before source-repo CWD"
            $content | Should -Match '(?is)installPath' -Because "$($command.Name) must use the installed plugin registry installPath when present"
            $content | Should -Match '(?is)agent-orchestra@agent-orchestra' -Because "$($command.Name) must resolve the installed Agent Orchestra plugin entry"
            $content | Should -Match "(?is)SemVer-sorted.{0,160}$cachePathPattern" -Because "$($command.Name) must fall back to the newest SemVer-sorted plugin-cache body path"
            $content | Should -Match '(?is)\.claude-plugin/plugin\.json.{0,180}name: agent-orchestra|name: agent-orchestra.{0,180}\.claude-plugin/plugin\.json' -Because "$($command.Name) must gate any source-repo CWD fallback on the Agent Orchestra plugin manifest"
            $content | Should -Match '(?is)claude plugin install agent-orchestra@agent-orchestra' -Because "$($command.Name) must preserve the canonical remediation command"
            $content | Should -Match ([regex]::Escape('⚠️ Shared-body load failed for agents/' + $command.BodyFile)) -Because "$($command.Name) must carry the canonical halt emit string for its paired body"
            $content | Should -Match '(?is)cannot continue without the canonical methodology' -Because "$($command.Name) must carry the halt-on-fail cannot-continue message"

            $installedPluginsIndex = $content.IndexOf('~/.claude/plugins/installed_plugins.json', [System.StringComparison]::Ordinal)
            $cachePathIndex = $content.IndexOf($cachePath, [System.StringComparison]::Ordinal)
            $sourceRepoGateIndex = $content.IndexOf('.claude-plugin/plugin.json', [System.StringComparison]::Ordinal)

            $installedPluginsIndex | Should -Not -Be -1 -Because "$($command.Name) must contain the installed plugin registry path"
            $cachePathIndex | Should -Not -Be -1 -Because "$($command.Name) must contain the plugin-cache fallback path for $bodyPath"
            $sourceRepoGateIndex | Should -Not -Be -1 -Because "$($command.Name) must contain the source-repo CWD fallback gate"
            $installedPluginsIndex | Should -BeLessThan $cachePathIndex -Because "$($command.Name) must try installed_plugins.json before the glob fallback"
            $cachePathIndex | Should -BeLessThan $sourceRepoGateIndex -Because "$($command.Name) must try plugin-cache paths before the gated source-repo CWD fallback"
        }
    }

    It 'rejects unqualified direct shared-body Read instructions in user-facing command entry points' {
        foreach ($command in $script:BodyResolutionCommandSpecs) {
            $path = Join-Path $script:RepoRoot $command.Path
            $content = Get-Content -Path $path -Raw -ErrorAction Stop

            foreach ($directReadPath in $command.ForbiddenDirectReadPaths) {
                $directReadPattern = '(?im)^\s*Read\s+`?' + [regex]::Escape($directReadPath) + '`?\s+(?:and|before|$)'
                $content | Should -Not -Match $directReadPattern -Because "$($command.Name) must resolve $directReadPath plugin-cache-first instead of using an unqualified CWD-relative Read instruction"
            }
        }
    }

    It 'forbids /orchestrate, /code-conductor, and /review-github from dispatching Code-Conductor as a parent-side subagent' {
        $commandFiles = @('commands\orchestrate.md', 'commands\code-conductor.md', 'commands\review-github.md')
        foreach ($commandFile in $commandFiles) {
            $content = Get-Content -Path (Join-Path $script:RepoRoot $commandFile) -Raw -ErrorAction Stop

            $content | Should -Not -Match '(?is)subagent_type:\s*code-conductor' -Because "$commandFile must not dispatch Code-Conductor as a parent-side subagent"
            $content | Should -Not -Match '(?is)dispatch\s+the\s+`?code-conductor`?\s+subagent' -Because "$commandFile must not keep parent-side Code-Conductor subagent dispatch wording"
            $content | Should -Not -Match '(?is)The subagent will read `agents/code-conductor\.md`' -Because "$commandFile must not describe Code-Conductor as a delegated subagent shell"
        }
    }

    It 'requires /orchestrate to adopt Code-Conductor inline after D1 body resolution' {
        $content = Get-Content -Path (Join-Path $script:RepoRoot 'commands\orchestrate.md') -Raw -ErrorAction Stop

        $content | Should -Match '(?is)(load|resolve).{0,300}agents/Code-Conductor\.agent\.md' -Because '/orchestrate must carry the session-startup load reference naming the Code-Conductor paired body'

        $content | Should -Match '(?is)(adopt|run).{0,120}Code-Conductor.{0,120}(inline|role|conversation)|Code-Conductor.{0,120}(inline|role).{0,120}(rest of this conversation|conversation)' -Because '/orchestrate must adopt Code-Conductor in the parent conversation after loading the shared body'
    }

    It 'requires /orchestrate to reconstruct downstream Agent handshakes live per dispatch' {
        $content = Get-Content -Path (Join-Path $script:RepoRoot 'commands\orchestrate.md') -Raw -ErrorAction Stop

        $content | Should -Match '(?is)(before each|immediately before each|for each|for every|per-dispatch).{0,180}`?Agent`?.{0,160}dispatch.{0,240}(reconstruct|recapture|capture).{0,220}(HEAD|branch).{0,220}(CWD|dirty)' -Because '/orchestrate must document live handshake reconstruction for each downstream Agent dispatch'
        $content | Should -Match '(?is)((do not|must not).{0,160}(reuse|carry forward).{0,160}(command-entry|entry-time|single).{0,120}handshake|(command-entry|entry-time|single).{0,120}handshake.{0,160}(must not|do not).{0,120}(reuse|carry forward))' -Because '/orchestrate must explicitly reject a single command-entry-captured handshake for downstream Agent calls'
        $content | Should -Not -Match '(?is)\*\*Handshake preamble\*\*.{0,900}subagent_type:\s*code-conductor' -Because '/orchestrate must not keep the old one-shot Code-Conductor subagent handshake preamble'
    }

    It 'requires /plan to document live Code-Critic handshake recapture at dispatch time' {
        $content = & $script:GetPlanEffectiveContract

        $liveRecapturePatterns = @(
            '(?is)(?:before each|immediately before each|for each|for every|per-dispatch).{0,180}(?:Code-Critic\s+)?`?Agent`?.{0,120}dispatch.{0,240}(?:reconstruct|recapture|capture|construct).{0,220}(?:HEAD|parent_head|git rev-parse HEAD).{0,220}(?:branch|parent_branch|git rev-parse --abbrev-ref HEAD).{0,220}(?:CWD|parent_cwd|pwd).{0,220}(?:dirty fingerprint|parent_dirty_fingerprint|git status --porcelain)',
            '(?is)(?:reconstruct|recapture|capture|construct).{0,220}(?:HEAD|parent_head|git rev-parse HEAD).{0,220}(?:branch|parent_branch|git rev-parse --abbrev-ref HEAD).{0,220}(?:CWD|parent_cwd|pwd).{0,220}(?:dirty fingerprint|parent_dirty_fingerprint|git status --porcelain).{0,260}(?:before each|immediately before each|for each|for every|per-dispatch).{0,180}(?:Code-Critic\s+)?`?Agent`?.{0,120}dispatch',
            '(?is)Immediately before each Code-Critic dispatch or retry, capture.{0,260}git rev-parse HEAD.{0,180}git rev-parse --abbrev-ref HEAD.{0,120}pwd.{0,220}git status --porcelain'
        )

        $liveRecaptureDocumented = $false
        foreach ($pattern in $liveRecapturePatterns) {
            if ($content -match $pattern) {
                $liveRecaptureDocumented = $true
                break
            }
        }
        $liveRecaptureDocumented | Should -BeTrue -Because '/plan must document live recapture of HEAD, branch, CWD, and dirty fingerprint immediately before each Code-Critic dispatch'
    }

    It 'requires /plan to name fresh Code-Critic handshakes for every prosecution and defense dispatch' {
        $content = & $script:GetPlanEffectiveContract

        $content | Should -Match '(?is)parallel prosecution batch.{0,240}recapture HEAD, branch, CWD, and dirty fingerprint once.{0,220}immediately before the parallel block.{0,220}one handshake block per prosecution dispatch' -Because '/plan must make every Code-Critic prosecution pass in the standard batch use a fresh batch-time handshake'
        $content | Should -Match '(?is)`standard`:.{0,220}defense pass.{0,220}Recapture state immediately before dispatch.{0,180}fresh handshake block' -Because '/plan must make the Code-Critic defense dispatch use a freshly recaptured handshake'
    }

    It 'forbids /plan from documenting a single once-per-invocation pipeline handshake' {
        $content = Get-Content -Path (Join-Path $script:RepoRoot 'commands\plan.md') -Raw -ErrorAction Stop

        $content | Should -Not -Match '(?is)construct.{0,100}parent-side\s+environment\s+handshake.{0,100}once.{0,80}`?/plan`?.{0,80}invocation' -Because '/plan must not say or imply that one handshake is constructed once for the whole command invocation'
    }

    It 'requires /plan to explicitly reject reusing stale handshakes across pipeline dispatches' {
        $content = & $script:GetPlanEffectiveContract

        $content | Should -Match '(?is)Do not reuse an entry-time, command-entry, prior-stage, or prior-dispatch block|No command-entry or once-per-invocation handshake reuse' -Because '/plan must explicitly reject reuse of a single stale handshake across prosecution, defense, or judge dispatches'
    }

    It 'keeps /plan judge handshake context metadata-only until Code-Review-Response has Step 0 verification' {
        $content = & $script:GetPlanEffectiveContract

        $content | Should -Match '(?is)Code-Review-Response.{0,180}judge.{0,240}(contextual metadata only|context only).{0,260}(unless|until).{0,180}(shell|Code-Review-Response).{0,180}(Step 0|environment handshake verification).{0,220}(separate issue|separate follow-up|future issue)' -Because '/plan must clarify that judge handshake data is contextual metadata only unless the Code-Review-Response shell gains Step 0 verification in a separate issue'
    }

    It 'scopes /plan pipeline-degraded recovery to redundant prosecution body-load pass failures' {
        $content = & $script:GetPlanEffectiveContract

        $matchesAnyPattern = {
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

        $redundantProsecutionBodyLoadRecovery = & $matchesAnyPattern -Content $content -Patterns @(
            '(?is)(?:redundant|three|3).{0,180}(?:Code-Critic\s+)?prosecution.{0,260}(?:body-load|body load|shared-body|shared body|body).{0,220}(?:fail|failure|failed|missing|malformed|not load|cannot load)',
            '(?is)(?:Code-Critic\s+)?prosecution.{0,180}(?:redundant|three|3).{0,260}(?:body-load|body load|shared-body|shared body|body).{0,220}(?:fail|failure|failed|missing|malformed|not load|cannot load)',
            '(?is)(?:body-load|body load|shared-body|shared body|body).{0,220}(?:fail|failure|failed|missing|malformed|not load|cannot load).{0,260}(?:redundant|three|3).{0,180}(?:Code-Critic\s+)?prosecution'
        )
        $redundantProsecutionBodyLoadRecovery | Should -BeTrue -Because '/plan must explicitly scope body-load pass failure recovery to the redundant Code-Critic prosecution set'

        $content | Should -Match '(?is)\bretry\b.{0,80}\bonce\b|\bonce\b.{0,80}\bretry\b' -Because '/plan must retry a failed or malformed redundant prosecution body-load pass once before degrading'
        $content | Should -Match '(?is)\bpipeline-degraded\b' -Because '/plan must preserve the visible degraded-pipeline note for redundant prosecution partial failure'
        $content | Should -Match '(?is)continue only when enough valid passes remain to form the adapter''s allowed merged prosecution ledger' -Because '/plan must tie pipeline-degraded continuation to the allowed merged prosecution ledger'

        foreach ($singletonStage in @(
                [pscustomobject]@{ Name = 'defense'; Body = 'Code-Critic'; StagePattern = 'defense' },
                [pscustomobject]@{ Name = 'judge'; Body = 'Code-Review-Response'; StagePattern = 'judge|judgment' }
            )) {
            $bodyPattern = [regex]::Escape($singletonStage.Body)
            $strictSingletonFailure = & $matchesAnyPattern -Content $content -Patterns @(
                "(?is)(?:singleton|single|one).{0,160}(?:$($singletonStage.StagePattern)|$bodyPattern).{0,260}(?:body-load|body load|shared-body|shared body|body).{0,220}(?:fail|failure|failed|missing|malformed|not load|cannot load).{0,260}(?:halt-strict|halt strict|halt|stop|cannot continue|do not continue)",
                "(?is)(?:$($singletonStage.StagePattern)|$bodyPattern).{0,160}(?:singleton|single|one).{0,260}(?:body-load|body load|shared-body|shared body|body).{0,220}(?:fail|failure|failed|missing|malformed|not load|cannot load).{0,260}(?:halt-strict|halt strict|halt|stop|cannot continue|do not continue)",
                "(?is)(?:body-load|body load|shared-body|shared body|body).{0,220}(?:fail|failure|failed|missing|malformed|not load|cannot load).{0,260}(?:$($singletonStage.StagePattern)|$bodyPattern).{0,260}(?:halt-strict|halt strict|halt|stop|cannot continue|do not continue)"
            )
            $strictSingletonFailure | Should -BeTrue -Because "/plan must state that singleton $($singletonStage.Name) body-load failure stays halt-strict rather than pipeline-degraded"
        }

        $singletonRecoveryWindows = [regex]::Matches(
            $content,
            '(?is).{0,140}(?:defense|judge|judgment|Code-Review-Response).{0,140}(?:pipeline-degraded|2-of-3|two-of-three|two of three|degradation|degraded).{0,140}|.{0,140}(?:pipeline-degraded|2-of-3|two-of-three|two of three|degradation|degraded).{0,140}(?:defense|judge|judgment|Code-Review-Response).{0,140}'
        )

        foreach ($window in $singletonRecoveryWindows) {
            $window.Value | Should -Match '(?is)\b(?:no|not|never|without|does not|must not|only|except|halt-strict|halt strict|halt|stop)\b' -Because '/plan must not imply that singleton defense or judge body-load failures can use pipeline-degraded recovery'
        }
    }

    It 'documents the #498 DRY reshape, provenance-gate retirement, and #414 Copilot asymmetry in the test header' {
        $content = Get-Content -Path (Join-Path $script:RepoRoot '.github\scripts\Tests\inline-dispatch-contract.Tests.ps1') -Raw -ErrorAction Stop

        $content | Should -Match ([regex]::Escape('Issue #498 reshaped the command-file pre-flight surface')) -Because 'the test header must explain the #498 DRY reshape of the command-file pre-flight prose'
        $content | Should -Match ([regex]::Escape('provenance-gate retirement')) -Because 'the test header must explain the provenance-gate retirement and upstream-onboarding ownership transfer'
        $content | Should -Match ([regex]::Escape('Copilot asymmetry remains tracked by #414')) -Because 'the test header must preserve the tracked Copilot asymmetry context'
    }
}
