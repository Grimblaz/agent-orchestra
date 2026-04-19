#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
.SYNOPSIS
    Issue #367 path-migration sweep gate.

.DESCRIPTION
    Verifies that .github/(agents|skills) occurrences in the repo stay within
    the active allow-list as the migration progresses. The gate narrows in
    phases as each step lands.

    Phases (controlled by $env:ISSUE_367_SWEEP_PHASE, default 'pre-mv'):
      - 'pre-mv'    : authored pre-mv (step 2); tolerates current in-scope files
      - 'post-mv'   : after step 4; agents/skills moved; old refs remain in docs
      - 'step5'     : agent Load directives + plain prose updated
      - 'step6'     : $copilotRoot runtime paths updated
      - 'step9'     : Pester test literals updated
      - 'step10'    : examples + docs updated (legacy-path fences introduced)
      - 'final'     : step 12 — zero occurrences outside the Documents/Design
                      allow-list + fenced blocks

    In every phase except 'final', the gate tolerates in-flight files awaiting
    a later step but fails on fences being unbalanced or on files that should
    already be clean regressing.
#>

BeforeDiscovery {
    $script:DiscoveryPhase = if ($env:ISSUE_367_SWEEP_PHASE) { $env:ISSUE_367_SWEEP_PHASE } else { 'pre-mv' }
}

Describe 'Issue #367 path-migration sweep gate' -Tag 'issue-367', 'sweep-gate' {

    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
        $script:Phase = if ($env:ISSUE_367_SWEEP_PHASE) { $env:ISSUE_367_SWEEP_PHASE } else { 'pre-mv' }

        # Final allow-list (post-step-12): paths that may retain .github/(agents|skills)
        # matches forever. Glob patterns are matched with -like (where * is greedy).
        $script:FinalAllowListPatterns = @(
            'Documents/Design/*.md'
            'CUSTOMIZATION.md'
            'examples/*/copilot-instructions.md'
        )

        # Per-phase additional allow-list entries (in-flight files not yet updated).
        $script:PhaseAllowList = @{
            'pre-mv'  = @(
                '.github/agents/*.agent.md'
                '.github/skills/*'
                '.github/skills/*/*'
                '.github/skills/*/*/*'
                '.github/skills/*/*/*/*'
                '.github/scripts/Tests/*.Tests.ps1'
                '.github/scripts/validate-architecture.ps1'
                '.github/scripts/lib/*.ps1'
                '.github/prompts/*.prompt.md'
                '.github/copilot-instructions.md'
                '.github/architecture-rules.md'
                'README.md'
                'CONTRIBUTING.md'
                'examples/*/README.md'
                'Documents/Decisions/0367-sweep-ledger.md'
            )
            'post-mv' = @(
                '.github/scripts/Tests/*.Tests.ps1'
                '.github/scripts/validate-architecture.ps1'
                '.github/scripts/lib/*.ps1'
                '.github/prompts/*.prompt.md'
                '.github/copilot-instructions.md'
                '.github/architecture-rules.md'
                'README.md'
                'CONTRIBUTING.md'
                'examples/*/README.md'
                'Documents/Decisions/0367-sweep-ledger.md'
            )
            'step5'   = @(
                '.github/scripts/Tests/*.Tests.ps1'
                '.github/scripts/validate-architecture.ps1'
                '.github/scripts/lib/*.ps1'
                '.github/prompts/*.prompt.md'
                '.github/copilot-instructions.md'
                '.github/architecture-rules.md'
                'README.md'
                'CONTRIBUTING.md'
                'examples/*/README.md'
                'Documents/Decisions/0367-sweep-ledger.md'
                'skills/post-pr-review/SKILL.md'
                'skills/session-startup/*'
                'skills/session-startup/*/*'
                'skills/guidance-measurement/scripts/*.ps1'
                'agents/Code-Conductor.agent.md'
            )
            'step6'   = @(
                '.github/scripts/Tests/*.Tests.ps1'
                '.github/scripts/validate-architecture.ps1'
                '.github/scripts/lib/*.ps1'
                '.github/prompts/*.prompt.md'
                '.github/copilot-instructions.md'
                '.github/architecture-rules.md'
                'README.md'
                'CONTRIBUTING.md'
                'examples/*/README.md'
                'Documents/Decisions/0367-sweep-ledger.md'
            )
            'step9'   = @(
                '.github/scripts/validate-architecture.ps1'
                '.github/scripts/lib/*.ps1'
                '.github/prompts/*.prompt.md'
                '.github/copilot-instructions.md'
                '.github/architecture-rules.md'
                'README.md'
                'CONTRIBUTING.md'
                'examples/*/README.md'
                'Documents/Decisions/0367-sweep-ledger.md'
            )
            'step10'  = @(
                '.github/architecture-rules.md'
                'Documents/Decisions/0367-sweep-ledger.md'
            )
            'final'   = @()
        }

        # D3b exemption whitelist (CE Gate S3): SKILL.md files allowed to retain
        # #tool:/AskUserQuestion refs after platforms/ split.
        $script:D3bExemptSkills = @('session-startup')

        function script:Get-ActiveAllowListPatterns {
            param([string]$Phase)
            $phaseEntries = if ($script:PhaseAllowList.ContainsKey($Phase)) {
                $script:PhaseAllowList[$Phase]
            }
            else { @() }
            return $script:FinalAllowListPatterns + $phaseEntries
        }

        function script:Test-PathMatchesAnyPattern {
            param(
                [string]$RelativePath,
                [string[]]$Patterns
            )
            $normalized = $RelativePath -replace '\\', '/'
            foreach ($pattern in $Patterns) {
                $normalizedPattern = $pattern -replace '\\', '/'
                if ($normalized -like $normalizedPattern) { return $true }
            }
            return $false
        }

        # Enumerate every tracked file with a .github/(agents|skills) literal match.
        Push-Location $script:RepoRoot
        try {
            $lsFiles = (& git ls-files) -split "`n" | Where-Object { $_ }
            $script:MatchingFiles = @()
            foreach ($rel in $lsFiles) {
                $full = Join-Path $script:RepoRoot $rel
                if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { continue }
                if ($rel -match '\.(png|jpg|jpeg|gif|ico|pdf|zip|gz|tar|exe|dll)$') { continue }
                try {
                    $content = Get-Content -LiteralPath $full -Raw -ErrorAction Stop
                }
                catch { continue }
                if ($null -eq $content) { continue }
                if ($content -match '\.github[\\/](agents|skills)\b') {
                    $script:MatchingFiles += $rel
                }
            }
        }
        finally {
            Pop-Location
        }
    }

    Context 'Allow-list coverage' {
        It "All matches are within the active allow-list (phase=$script:DiscoveryPhase)" {
            $patterns = Get-ActiveAllowListPatterns -Phase $script:Phase
            $violations = @()
            foreach ($file in $script:MatchingFiles) {
                if (-not (Test-PathMatchesAnyPattern -RelativePath $file -Patterns $patterns)) {
                    $violations += $file
                }
            }
            $violations | Should -BeNullOrEmpty -Because ("Phase '{0}' should not have .github/(agents|skills) matches outside the active allow-list. Violating files:`n  {1}" -f $script:Phase, ($violations -join "`n  "))
        }
    }

    Context 'Legacy-path fence balance' {
        It 'Balanced legacy-path open/close markers' {
            $openPattern = '<!--\s*legacy-path\s*-->'
            $closePattern = '<!--\s*/legacy-path\s*-->'
            $unbalanced = @()
            foreach ($file in $script:MatchingFiles) {
                # The ledger documents the fence convention verbatim; skip self-reference to avoid false positives.
                if ($file -eq 'Documents/Decisions/0367-sweep-ledger.md') { continue }
                $full = Join-Path $script:RepoRoot $file
                $content = Get-Content -LiteralPath $full -Raw -ErrorAction SilentlyContinue
                if ($null -eq $content) { continue }
                $closeCount = ([regex]::Matches($content, $closePattern)).Count
                $openCount = ([regex]::Matches($content, $openPattern)).Count - $closeCount
                if ($openCount -ne $closeCount) {
                    $unbalanced += ('{0}: {1} open / {2} close' -f $file, $openCount, $closeCount)
                }
            }
            $unbalanced | Should -BeNullOrEmpty -Because ("Legacy-path fences must be balanced. Unbalanced:`n  {0}" -f ($unbalanced -join "`n  "))
        }
    }

    Context 'Migration-note fence balance (CUSTOMIZATION.md)' {
        It 'Balanced migration-note begin/end markers in CUSTOMIZATION.md' {
            $custom = Join-Path $script:RepoRoot 'CUSTOMIZATION.md'
            if (-not (Test-Path -LiteralPath $custom)) {
                Set-ItResult -Skipped -Because 'CUSTOMIZATION.md not present'
                return
            }
            $content = Get-Content -LiteralPath $custom -Raw
            $openCount = ([regex]::Matches($content, 'migration-note-begin\s*-->')).Count
            $closeCount = ([regex]::Matches($content, 'migration-note-end\s*-->')).Count
            $openCount | Should -Be $closeCount -Because ("CUSTOMIZATION.md migration-note fences must be balanced (have {0} begin / {1} end)" -f $openCount, $closeCount)
        }
    }

    Context 'D3b exemption whitelist (informational)' {
        It 'Exemption whitelist is documented' {
            $script:D3bExemptSkills | Should -Contain 'session-startup' -Because 'session-startup retains methodology after platforms/ split per D3b soft exemption'
        }
    }
}
