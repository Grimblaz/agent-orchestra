#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

Describe 'frame enforcement boundary' {

    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
        $script:FrameWrappers = @(
            (Join-Path $script:RepoRoot '.github/scripts/frame-back-derive.ps1'),
            (Join-Path $script:RepoRoot '.github/scripts/frame-audit-report.ps1')
        )
        $script:HookFiles = @(
            (Join-Path $script:RepoRoot 'hooks.json'),
            (Join-Path $script:RepoRoot 'hooks/hooks.json')
        ) | Where-Object { Test-Path $_ }
        $script:WorkflowDir = Join-Path $script:RepoRoot '.github/workflows'

        $script:RequireWrappers = {
            $missing = @($script:FrameWrappers | Where-Object { -not (Test-Path $_) })
            if ($missing.Count -gt 0) {
                Set-ItResult -Skipped -Because 'frame wrapper scripts not implemented yet'
                return $false
            }

            return $true
        }
    }

    It 'frame-enforce workflow file exists and audit wrappers are present' {
        # Audit wrappers are still present.
        foreach ($wrapper in $script:FrameWrappers) {
            $wrapper | Should -Exist
        }
        # Enforcement workflow file ships in s2/s3.
        $enforceWorkflow = Join-Path $script:WorkflowDir 'frame-enforce.yml'
        $enforceWorkflow | Should -Exist
    }

    It 'does not wire frame-specific audit wrappers into hooks or workflows' {
        # frame-back-derive and frame-audit-report are internal audit wrappers and
        # should NOT appear in hooks or workflows. frame-credit-ledger IS intentionally
        # wired into frame-enforce.yml (that is the whole point of enforcement).
        foreach ($hookFile in $script:HookFiles) {
            $content = Get-Content -Raw -Path $hookFile
            $content | Should -Not -Match 'frame-(back-derive|audit-report)'
        }

        if (Test-Path $script:WorkflowDir) {
            $workflowHits = @(
                Get-ChildItem -Path $script:WorkflowDir -File | Select-String -Pattern 'frame-(back-derive|audit-report)' -AllMatches
            )
            $workflowHits.Count | Should -Be 0
        }
    }

    It 'enforce-activation.yaml has far-future sentinel (advisory ship constraint)' {
        $activationFile = Join-Path $script:RepoRoot 'frame/enforce-activation.yaml'
        $activationFile | Should -Exist
        $content = Get-Content -LiteralPath $activationFile -Raw
        $content | Should -Match 'activation_timestamp.*9999'
    }

    It 'keeps frame wrapper wording audit-only when the scripts arrive' {
        if (-not (& $script:RequireWrappers)) {
            return
        }

        foreach ($wrapper in $script:FrameWrappers) {
            $content = Get-Content -Raw -Path $wrapper
            $content | Should -Not -Match '(?i)\b(block|blocking|enforc|warn-only|fail the build)\b'
        }
    }
}
