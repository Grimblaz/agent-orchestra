#Requires -Version 7.0
<#
.SYNOPSIS
    Contract test: $script:OrphanIssueRegex is defined in session-startup-git-helpers.ps1
    and consumed in session-cleanup-detector-core.ps1; no other file in
    skills/session-startup/scripts/ carries a duplicated literal regex.
#>

Describe 'OrphanIssueRegex contract' {
    BeforeAll {
        $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '../../../') | Select-Object -ExpandProperty Path
        $helpersPath   = Join-Path $repoRoot 'skills/session-startup/scripts/session-startup-git-helpers.ps1'
        $detectorPath  = Join-Path $repoRoot 'skills/session-startup/scripts/session-cleanup-detector-core.ps1'
        $scriptsDir    = Join-Path $repoRoot 'skills/session-startup/scripts'
    }

    It 'session-startup-git-helpers.ps1 defines $script:OrphanIssueRegex' {
        $content = Get-Content $helpersPath -Raw
        $content | Should -Match '\$script:OrphanIssueRegex\s*='
    }

    It 'session-cleanup-detector-core.ps1 references $script:OrphanIssueRegex' {
        $content = Get-Content $detectorPath -Raw
        $content | Should -Match '\$script:OrphanIssueRegex'
    }

    It 'no file in skills/session-startup/scripts/ carries a duplicated literal feature/issue regex outside helpers' {
        $results = Get-ChildItem -Path $scriptsDir -Filter '*.ps1' |
            Where-Object { $_.Name -ne 'session-startup-git-helpers.ps1' } |
            Select-String -Pattern 'feature/issue-(\d+' -SimpleMatch
        $results | Should -BeNullOrEmpty -Because 'the shared regex constant should be used instead of duplicating the literal'
    }
}
