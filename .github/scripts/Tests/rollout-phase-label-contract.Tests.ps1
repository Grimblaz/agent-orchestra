#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
    Contract tests for issue #465 AC12 rollout phase labels.

.DESCRIPTION
    Locks the D5 Type A documentation target set before prose replacement.
    Type A rollout-history labels such as "Phase 3 adds" or
    "Phase 4 specialist shells" must become current-state prose.

    This test intentionally does not scan standalone Type B or Type C target
    sets. Type B process-step phase labels, such as setup wizard step phases,
    and Type C BDD feature-tier phase labels remain out of AC12 replacement
    scope. If a Type A file contains one of those non-rollout contexts, it must
    be documented below as a narrow line-context exclusion rather than added to
    the historical-wording allowlist.

    Historical wording may only remain when it is preserved in a clearly marked
    history footer. Every such allowed match must carry a reason keyed by path
    and line pattern in $script:AllowedHistoryFooterPhasePatterns.
#>

Describe 'AC12 rollout phase label contract' {

    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
        $script:RolloutPhasePattern = 'Phase [0-9]+'

        $script:TypeATargets = @(
            'README.md',
            'CLAUDE.md',
            'agents/code-conductor.md',
            'agents/code-smith.md',
            'agents/doc-keeper.md',
            'agents/test-writer.md',
            'agents/refactor-specialist.md',
            'agents/process-review.md',
            'agents/research-agent.md',
            'agents/specification.md',
            'Documents/Design/agent-body-architecture.md',
            'skills/subagent-env-handshake/SKILL.md'
        )

        # Type B process-step exclusions: setup wizard phase labels are procedural
        # steps, not rollout-history labels. This test scans only Type A files;
        # these entries cover the narrow Type B contexts that currently live inside
        # README.md.
        # Type C BDD feature-tier exclusions: BDD framework generation tiers are a
        # separate taxonomy. This test does not scan BDD skill/reference files; the
        # entry below covers the narrow Type C section title mirrored by the
        # Test-Writer shell.
        $script:NonRolloutPhaseContexts = @(
            [pscustomobject]@{
                Category = 'Type B process-step'
                Path     = 'README.md'
                Pattern  = '(?i)(/setup|setup wizard|brand-new and empty|workspace context provider|README\.md placeholder)'
                Reason   = 'README setup wizard prose describes process-step phases, not Claude plugin rollout history.'
            },
            [pscustomobject]@{
                Category = 'Type B process-step'
                Path     = 'README.md'
                Pattern  = '^\s*-\s+\*\*Phase [0-9]+\*\*'
                Reason   = 'README setup wizard bullet list is the Type B process-step taxonomy.'
            },
            [pscustomobject]@{
                Category = 'Type C BDD feature-tier'
                Path     = 'agents/test-writer.md'
                Pattern  = 'BDD Gherkin Generation \(Phase 2\)'
                Reason   = 'Test-Writer mirrors the Type C BDD feature-tier heading from the shared body.'
            }
        )

        $script:AllowedHistoryFooterPhasePatterns = @(
            # Prefer zero entries. If a later prose pass keeps historical wording in
            # a clearly marked history footer, add a scoped entry with Path, Pattern,
            # and Reason that explains why that exact line remains historical.
        )

        $script:GetAbsolutePath = {
            param([string]$RelativePath)

            return Join-Path $script:RepoRoot ($RelativePath -replace '/', [System.IO.Path]::DirectorySeparatorChar)
        }

        $script:ReadDocumentLines = {
            param([string]$RelativePath)

            $path = & $script:GetAbsolutePath -RelativePath $RelativePath
            $content = Get-Content -LiteralPath $path -Raw -ErrorAction Stop
            return @($content -split "`r?`n")
        }

        $script:GetPhaseMatches = {
            $phaseMatches = [System.Collections.Generic.List[object]]::new()

            foreach ($relativePath in $script:TypeATargets) {
                $lines = & $script:ReadDocumentLines -RelativePath $relativePath
                for ($index = 0; $index -lt $lines.Count; $index++) {
                    $line = $lines[$index]
                    foreach ($match in [regex]::Matches($line, $script:RolloutPhasePattern)) {
                        $phaseMatches.Add([pscustomobject]@{
                                RelativePath = $relativePath
                                LineNumber   = $index + 1
                                Line         = $line
                                Token        = $match.Value
                            })
                    }
                }
            }

            return @($phaseMatches)
        }

        $script:GetMatchingRule = {
            param(
                [Parameter(Mandatory = $true)]
                [pscustomobject]$PhaseMatch,
                [object[]]$Rules
            )

            if ($null -eq $Rules -or $Rules.Count -eq 0) {
                return $null
            }

            foreach ($rule in $Rules) {
                if ($rule.Path -ne $PhaseMatch.RelativePath) {
                    continue
                }

                if ($PhaseMatch.Line -match $rule.Pattern) {
                    return $rule
                }
            }

            return $null
        }

        $script:FormatPhaseMatch = {
            param([pscustomobject]$PhaseMatch)

            return '{0}:{1}: {2}' -f $PhaseMatch.RelativePath, $PhaseMatch.LineNumber, $PhaseMatch.Line.Trim()
        }
    }

    It 'scans exactly the D5 Type A target set' {
        $script:TypeATargets | Should -HaveCount 12 -Because 'D5 defines exactly twelve Type A files for the AC12 rollout-label replacement'

        foreach ($relativePath in $script:TypeATargets) {
            $path = & $script:GetAbsolutePath -RelativePath $relativePath
            Test-Path -LiteralPath $path -PathType Leaf | Should -BeTrue -Because "$relativePath is part of the D5 Type A target set"
        }
    }

    It 'documents non-rollout Type B and Type C contexts without making them history allowlist entries' {
        $script:NonRolloutPhaseContexts | Should -HaveCount 3 -Because 'the only non-rollout contexts in Type A files are README setup phases and Test-Writer BDD feature-tier prose'

        foreach ($rule in $script:NonRolloutPhaseContexts) {
            $rule.Category | Should -Match '^Type [BC] ' -Because 'each exclusion must identify the D5 taxonomy it represents'
            ($script:TypeATargets -contains $rule.Path) | Should -BeTrue -Because 'line-context exclusions may only apply inside the Type A files this test scans'
            $rule.Pattern | Should -Match 'Phase|setup|BDD|workspace|README' -Because 'each exclusion pattern must stay tied to an explicit phase-bearing non-rollout context'
            $rule.Reason | Should -Not -BeNullOrEmpty -Because 'non-rollout contexts must explain why they are not rollout history'
        }
    }

    It 'keeps historical rollout allowlist entries explicitly reasoned and path-scoped' {
        foreach ($rule in $script:AllowedHistoryFooterPhasePatterns) {
            ($script:TypeATargets -contains $rule.Path) | Should -BeTrue -Because 'history-footer allowlist entries must be scoped to one scanned Type A file'
            $rule.Pattern | Should -Not -BeNullOrEmpty -Because 'history-footer allowlist entries must identify the exact preserved line pattern'
            $rule.Pattern | Should -Match 'Phase \[0-9\]\+|Phase \[0-9\]|Phase [0-9]' -Because 'history-footer allowlist entries must be keyed to the Phase N label they preserve'
            $rule.Reason | Should -Not -BeNullOrEmpty -Because 'history-footer allowlist entries must explain why the historical wording remains'
        }
    }

    It 'rejects rollout-history Phase N labels in Type A files outside the explicit history-footer allowlist' {
        $allPhaseMatches = & $script:GetPhaseMatches

        $violations = @(
            foreach ($phaseMatch in $allPhaseMatches) {
                $nonRolloutContext = & $script:GetMatchingRule -PhaseMatch $phaseMatch -Rules $script:NonRolloutPhaseContexts
                if ($null -ne $nonRolloutContext) {
                    continue
                }

                $allowedHistory = & $script:GetMatchingRule -PhaseMatch $phaseMatch -Rules $script:AllowedHistoryFooterPhasePatterns
                if ($null -ne $allowedHistory) {
                    continue
                }

                $phaseMatch
            }
        )

        $summary = @($violations | ForEach-Object { & $script:FormatPhaseMatch -PhaseMatch $_ })
        $because = "Type A rollout-history Phase N labels must become current-state prose. Remaining matches:`n" + ($summary -join "`n")

        $violations | Should -HaveCount 0 -Because $because
    }
}
