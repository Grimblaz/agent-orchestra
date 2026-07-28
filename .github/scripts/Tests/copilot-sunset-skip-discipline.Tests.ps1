#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
.SYNOPSIS
    Durable contract: every Copilot-sunset -Skip added for #651 carries the required reason token.
.DESCRIPTION
    AC5 / Design F7: each de-obligated Pester It -Skip must carry the
    '# TODO(#651-option1-remove)' token so Option-1 removal is a grep-guided
    checklist, not archaeology.
#>
Describe 'Copilot sunset skip discipline (#651)' {
    BeforeAll {
        $script:TestsRoot = (Resolve-Path (Join-Path $PSScriptRoot '.')).Path
    }

    It 'every -Skip annotation added for the Copilot sunset carries the #651-option1-remove token' {
        # Find de-obligating It -Skip lines.
        #
        # `-Skip` followed by a parenthesised condition -- `-Skip:(-not $IsWindows)` -- is
        # platform gating, not a Copilot de-obligation: the test still runs, on the hosts
        # where it applies. Enrolling those on the #651 Option-1 removal checklist would be
        # wrong, because Option-1 removal must not delete platform-gated tests.
        #
        # Everything else stays in scope. Bare `-Skip {` -- the form every real Copilot
        # de-obligation in this repository uses -- still matches, and so does an
        # unconditional `-Skip:$true`, so the de-obligation escape hatch stays covered.
        $skipLines = Get-ChildItem -Path $script:TestsRoot -Filter '*.Tests.ps1' -Recurse |
            Select-String -Pattern "It\s+'[^']*'\s+-Skip(?!:\s*\()" |
            Where-Object { $_.Line -notmatch '#651-option1-remove' }

        $skipLines | ForEach-Object { Write-Host "Missing token: $($_.Filename):$($_.LineNumber): $($_.Line.Trim())" }
        $skipLines | Should -BeNullOrEmpty -Because 'every -Skip added for the Copilot sunset must carry the #651-option1-remove reason token (AC5 / Design F7)'
    }
}
