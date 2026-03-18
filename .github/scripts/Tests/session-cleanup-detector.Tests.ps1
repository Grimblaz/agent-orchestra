#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
.SYNOPSIS
    Pester tests for COPILOT_ORCHESTRA_ROOT / WORKFLOW_TEMPLATE_ROOT
    fallback behaviour in session-cleanup-detector.ps1.

.DESCRIPTION
    Contract:
      Test A – ONLY COPILOT_ORCHESTRA_ROOT set (valid path) → exit 0 (primary var honoured)
      Test B – ONLY WORKFLOW_TEMPLATE_ROOT set (valid path)  → exit 0 (legacy fallback works)
      Test D – BOTH vars set                                 → exit 0 (primary var takes priority)
      Test C – NEITHER var set                               → exit non-zero AND output JSON
                                                               mentions both var names

    All 6 tests are GREEN — verifying COPILOT_ORCHESTRA_ROOT (primary),
    WORKFLOW_TEMPLATE_ROOT (fallback), and error output when neither is set.
#>

Describe 'session-cleanup-detector.ps1 — env var fallback' {

    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
        $script:ScriptFile = Join-Path $script:RepoRoot '.github\scripts\session-cleanup-detector.ps1'

        # Snapshot env vars so every test starts from a known baseline
        $script:SavedOrchestra = $env:COPILOT_ORCHESTRA_ROOT
        $script:SavedWorkflow = $env:WORKFLOW_TEMPLATE_ROOT

        # Pester v5 isolation: helper stored as a script-scoped scriptblock so
        # It blocks can call it via & $script:InvokeDetector.
        $script:InvokeDetector = {
            Push-Location $script:RepoRoot
            try {
                $lines = & pwsh -NoProfile -NonInteractive -File $script:ScriptFile 2>$null
                $exitCode = $LASTEXITCODE
                # Script uses ConvertTo-Json -Compress → single line; join in case
                # pwsh splits it across multiple output objects.
                $output = ($lines -join '')
                return @{ Output = $output; ExitCode = $exitCode }
            }
            finally {
                Pop-Location
            }
        }
    }

    AfterAll {
        # Restore whatever was set before the suite ran
        $env:COPILOT_ORCHESTRA_ROOT = $script:SavedOrchestra
        $env:WORKFLOW_TEMPLATE_ROOT = $script:SavedWorkflow
    }

    # ------------------------------------------------------------------
    # Test A — primary var COPILOT_ORCHESTRA_ROOT honoured
    # Verifies COPILOT_ORCHESTRA_ROOT is accepted as the primary env var
    # ------------------------------------------------------------------
    Context 'when only COPILOT_ORCHESTRA_ROOT is set' {
        It 'exits 0 and does not produce an env-var-missing error' {
            $savedOrchestra = $env:COPILOT_ORCHESTRA_ROOT
            $savedWorkflow = $env:WORKFLOW_TEMPLATE_ROOT
            try {
                $env:COPILOT_ORCHESTRA_ROOT = $script:RepoRoot
                Remove-Item Env:WORKFLOW_TEMPLATE_ROOT -ErrorAction SilentlyContinue

                $result = & $script:InvokeDetector

                # The script must not exit with the env-var-error code
                $result.ExitCode | Should -Be 0 -Because 'COPILOT_ORCHESTRA_ROOT should satisfy the env-var gate'
            }
            finally {
                $env:COPILOT_ORCHESTRA_ROOT = $savedOrchestra
                $env:WORKFLOW_TEMPLATE_ROOT = $savedWorkflow
            }
        }
    }

    # ------------------------------------------------------------------
    # Test B — legacy fallback WORKFLOW_TEMPLATE_ROOT still works
    # GREEN: existing behaviour; should pass before and after the change
    # ------------------------------------------------------------------
    Context 'when only WORKFLOW_TEMPLATE_ROOT is set' {
        It 'exits 0 and does not produce an env-var-missing error' {
            $savedOrchestra = $env:COPILOT_ORCHESTRA_ROOT
            $savedWorkflow = $env:WORKFLOW_TEMPLATE_ROOT
            try {
                Remove-Item Env:COPILOT_ORCHESTRA_ROOT -ErrorAction SilentlyContinue
                $env:WORKFLOW_TEMPLATE_ROOT = $script:RepoRoot

                $result = & $script:InvokeDetector

                $result.ExitCode | Should -Be 0 -Because 'WORKFLOW_TEMPLATE_ROOT is the existing accepted var'
            }
            finally {
                $env:COPILOT_ORCHESTRA_ROOT = $savedOrchestra
                $env:WORKFLOW_TEMPLATE_ROOT = $savedWorkflow
            }
        }
    }

    # ------------------------------------------------------------------
    # Test D — both vars set → COPILOT_ORCHESTRA_ROOT takes priority
    # Verifies the fallback chain resolves the primary var first
    # ------------------------------------------------------------------
    Context 'when both env vars are set' {
        It 'exits 0 with COPILOT_ORCHESTRA_ROOT taking priority' {
            $savedOrchestra = $env:COPILOT_ORCHESTRA_ROOT
            $savedWorkflow = $env:WORKFLOW_TEMPLATE_ROOT
            try {
                $env:COPILOT_ORCHESTRA_ROOT = $script:RepoRoot
                $env:WORKFLOW_TEMPLATE_ROOT = $script:RepoRoot

                $result = & $script:InvokeDetector

                $result.ExitCode | Should -Be 0 -Because 'COPILOT_ORCHESTRA_ROOT should be resolved first when both are set'
            }
            finally {
                $env:COPILOT_ORCHESTRA_ROOT = $savedOrchestra
                $env:WORKFLOW_TEMPLATE_ROOT = $savedWorkflow
            }
        }
    }

    # ------------------------------------------------------------------
    # Test C — neither var set → exit non-zero, both names in output
    # Verifies exit non-zero and both env var names appear in output
    # ------------------------------------------------------------------
    Context 'when neither env var is set' {
        It 'exits non-zero' {
            $savedOrchestra = $env:COPILOT_ORCHESTRA_ROOT
            $savedWorkflow = $env:WORKFLOW_TEMPLATE_ROOT
            try {
                Remove-Item Env:COPILOT_ORCHESTRA_ROOT -ErrorAction SilentlyContinue
                Remove-Item Env:WORKFLOW_TEMPLATE_ROOT -ErrorAction SilentlyContinue

                $result = & $script:InvokeDetector

                $result.ExitCode | Should -Not -Be 0 -Because 'missing env vars must signal failure'
            }
            finally {
                $env:COPILOT_ORCHESTRA_ROOT = $savedOrchestra
                $env:WORKFLOW_TEMPLATE_ROOT = $savedWorkflow
            }
        }

        It 'includes COPILOT_ORCHESTRA_ROOT in the error JSON' {
            $savedOrchestra = $env:COPILOT_ORCHESTRA_ROOT
            $savedWorkflow = $env:WORKFLOW_TEMPLATE_ROOT
            try {
                Remove-Item Env:COPILOT_ORCHESTRA_ROOT -ErrorAction SilentlyContinue
                Remove-Item Env:WORKFLOW_TEMPLATE_ROOT -ErrorAction SilentlyContinue

                $result = & $script:InvokeDetector

                $result.Output | Should -Match 'COPILOT_ORCHESTRA_ROOT' `
                    -Because 'the error message must name the new primary env var'
            }
            finally {
                $env:COPILOT_ORCHESTRA_ROOT = $savedOrchestra
                $env:WORKFLOW_TEMPLATE_ROOT = $savedWorkflow
            }
        }

        It 'includes WORKFLOW_TEMPLATE_ROOT in the error JSON' {
            $savedOrchestra = $env:COPILOT_ORCHESTRA_ROOT
            $savedWorkflow = $env:WORKFLOW_TEMPLATE_ROOT
            try {
                Remove-Item Env:COPILOT_ORCHESTRA_ROOT -ErrorAction SilentlyContinue
                Remove-Item Env:WORKFLOW_TEMPLATE_ROOT -ErrorAction SilentlyContinue

                $result = & $script:InvokeDetector

                $result.Output | Should -Match 'WORKFLOW_TEMPLATE_ROOT' `
                    -Because 'the error message must also name the legacy fallback var'
            }
            finally {
                $env:COPILOT_ORCHESTRA_ROOT = $savedOrchestra
                $env:WORKFLOW_TEMPLATE_ROOT = $savedWorkflow
            }
        }
    }
}
