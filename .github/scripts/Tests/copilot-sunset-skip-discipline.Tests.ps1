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
        # The exemption is keyed on the CONDITION being a platform predicate, not on the
        # mere presence of parentheses. `-Skip:(-not $IsWindows)` is platform gating rather
        # than a Copilot de-obligation -- the test still runs, on the hosts where it applies
        # -- and enrolling those on the #651 Option-1 removal checklist would be wrong,
        # because Option-1 removal must not delete platform-gated tests.
        #
        # Exempting every parenthesised condition instead would be a detection hole: an
        # unconditional skip wearing parentheses (`-Skip:($true)`, `-Skip:(1 -eq 1)`) or an
        # environment-scoped disable (`-Skip:($env:CI -eq 'true')`) is a de-obligation, and
        # must still land on the removal checklist. Only $IsWindows / $IsLinux / $IsMacOS,
        # optionally negated, are exempt; every other spelling -- including bare `-Skip {`
        # and `-Skip:$true` -- stays in scope.
        #
        # The name group accepts BOTH quote styles. Pester discovers `It "name"` exactly as
        # it discovers `It 'name'`, so a single-quote-only group let any double-quoted test
        # carry `-Skip` straight past this guard. 158 double-quoted It names exist in this
        # suite; none carries -Skip today, which is why the gap was latent rather than live.
        $skipLines = Get-ChildItem -Path $script:TestsRoot -Filter '*.Tests.ps1' -Recurse |
            Select-String -Pattern "It\s+(['`"])[^'`"]*\1\s+-Skip(?!:\s*\(\s*(-not\s+)?\`$Is(Windows|Linux|MacOS)\s*\))" |
            Where-Object { $_.Line -notmatch '#651-option1-remove' }

        $skipLines | ForEach-Object { Write-Host "Missing token: $($_.Filename):$($_.LineNumber): $($_.Line.Trim())" }
        $skipLines | Should -BeNullOrEmpty -Because 'every -Skip added for the Copilot sunset must carry the #651-option1-remove reason token (AC5 / Design F7)'
    }
}
