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
        # Find all It -Skip lines
        $skipLines = Get-ChildItem -Path $script:TestsRoot -Filter '*.Tests.ps1' -Recurse |
            Select-String -Pattern "It\s+'[^']*'\s+-Skip" |
            Where-Object { $_.Line -notmatch '#651-option1-remove' }

        $skipLines | ForEach-Object { Write-Host "Missing token: $($_.Filename):$($_.LineNumber): $($_.Line.Trim())" }
        $skipLines | Should -BeNullOrEmpty -Because 'every -Skip added for the Copilot sunset must carry the #651-option1-remove reason token (AC5 / Design F7)'
    }
}
