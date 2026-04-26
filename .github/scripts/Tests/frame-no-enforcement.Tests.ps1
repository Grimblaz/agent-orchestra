#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

Describe 'frame audit-only boundary' {

    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
        $script:FrameWrappers = @(
            (Join-Path $script:RepoRoot '.github\scripts\frame-back-derive.ps1'),
            (Join-Path $script:RepoRoot '.github\scripts\frame-audit-report.ps1')
        )
        $script:HookFiles = @(
            (Join-Path $script:RepoRoot 'hooks.json'),
            (Join-Path $script:RepoRoot 'hooks\hooks.json')
        ) | Where-Object { Test-Path $_ }
        $script:WorkflowDir = Join-Path $script:RepoRoot '.github\workflows'

        $script:RequireWrappers = {
            $missing = @($script:FrameWrappers | Where-Object { -not (Test-Path $_) })
            if ($missing.Count -gt 0) {
                Set-ItResult -Skipped -Because 'frame wrapper scripts not implemented yet'
                return $false
            }

            return $true
        }
    }

    It 'adds the frame audit wrappers without introducing an enforcement entry point' {
        foreach ($wrapper in $script:FrameWrappers) {
            $wrapper | Should -Exist
        }
    }

    It 'does not wire frame-specific behavior into hooks or workflows' {
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
