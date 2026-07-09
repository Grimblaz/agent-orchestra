#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
.SYNOPSIS
    AST/Get-Command-bound doc-to-script contract test locking the §2b-bis
    fenced invocation example in skills/safe-operations/SKILL.md to the
    Set-IssueParent.ps1 script interface (plan-issue-800 s2, AC4).

.DESCRIPTION
    Regression guard for the judge-note flagged in plan-issue-800 (PF11-
    adjacent, "worth closing even though it wasn't a formally sustained
    finding"): a doc reference reverting to Add-FollowUpIssue.ps1, or a
    parameter-token drift between the doc and the script, must fail this
    test.

    Text isolation (finding the §2b-bis section, its fenced code block, and
    the one invocation line inside it) uses plain string/regex splitting -
    that part is not load-bearing. The CORE assertions - script filename
    identity and parameter-token set equality - are bound via the
    PowerShell language parser (AST) over the isolated line and via
    Get-Command against the real script, per plan-issue-800 M10 ("bind the
    contract test to the param block via AST/Get-Command rather than prose
    regex to avoid the brittleness the existing 2b-bis contract test
    demonstrates").

    EXPECTED RED STATE: skills/safe-operations/SKILL.md has NOT been fixed
    yet at the time this test is authored (plan-issue-800 step s5 - doc
    fixes at all five drift sites - is dispatched AFTER this step, s2). The
    §2b-bis fenced example still invokes `Add-FollowUpIssue.ps1
    -ParentIssueNumber ...`, so the "invokes Set-IssueParent.ps1 by
    filename" test below is EXPECTED TO FAIL until s5 lands. This is the
    correct, intended red state for this step - do not weaken the
    assertion to pass prematurely against the unfixed doc.
#>

Describe 'Set-IssueParent doc-to-script contract (SKILL.md §2b-bis)' -Tag 'contract' {

    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
        $script:SafeOpsPath = Join-Path $script:RepoRoot 'skills/safe-operations/SKILL.md'
        $script:ScriptPath = Join-Path $script:RepoRoot 'skills/safe-operations/scripts/Set-IssueParent.ps1'
        $script:Content = Get-Content -Path $script:SafeOpsPath -Raw -ErrorAction Stop

        # --- Text isolation only (NOT the core assertion): locate the
        # §2b-bis section, its first fenced ```powershell block, and the one
        # line inside it that invokes a skills/safe-operations/scripts/*.ps1
        # helper (the "CORRECT — umbrella child" attach-existing example). ---
        $sectionMatch = [regex]::Match(
            $script:Content,
            '(?s)### 2b-bis\..*?(?=\r?\n### )'
        )
        if (-not $sectionMatch.Success) {
            throw "Could not locate the §2b-bis section in $($script:SafeOpsPath)"
        }
        $section = $sectionMatch.Value

        $fenceMatch = [regex]::Match($section, '(?s)```powershell\r?\n(.*?)```')
        if (-not $fenceMatch.Success) {
            throw "Could not locate a fenced powershell block inside the §2b-bis section of $($script:SafeOpsPath)"
        }
        $fenceBody = $fenceMatch.Groups[1].Value

        $invocationLine = ($fenceBody -split '\r?\n') |
            Where-Object { $_ -match 'skills/safe-operations/scripts/\S+\.ps1' } |
            Select-Object -First 1

        if (-not $invocationLine) {
            throw "Could not find a skills/safe-operations/scripts/*.ps1 invocation line inside the §2b-bis fenced example"
        }
        $script:InvocationLine = $invocationLine.Trim()

        # --- Core assertion binding: parse the isolated line with the
        # PowerShell language parser (AST), not prose regex (M10). ---
        $tokens = $null
        $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseInput(
            $script:InvocationLine, [ref]$tokens, [ref]$parseErrors
        )
        $commandAst = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true)
        if (-not $commandAst) {
            throw "AST parse of the isolated §2b-bis invocation line produced no CommandAst: $($script:InvocationLine)"
        }

        # CommandElements[0] is the `pwsh` launcher; CommandElements[1] is
        # the script path argument.
        $scriptPathText = $commandAst.CommandElements[1].Extent.Text.Trim('"', "'")
        $script:DocScriptFileName = Split-Path -Path $scriptPathText -Leaf

        $script:DocFlagTokens = @(
            $commandAst.CommandElements |
                Where-Object { $_ -is [System.Management.Automation.Language.CommandParameterAst] } |
                ForEach-Object { $_.ParameterName }
        )
    }

    It 'extraction produced a non-empty script filename and at least one flag token (self-check on the extraction mechanics)' {
        $script:DocScriptFileName | Should -Not -BeNullOrEmpty
        $script:DocFlagTokens.Count | Should -BeGreaterThan 0
    }

    It 'the §2b-bis fenced example invokes Set-IssueParent.ps1 by filename (regression guard: a revert to Add-FollowUpIssue.ps1 must fail this test)' {
        $script:DocScriptFileName | Should -Be 'Set-IssueParent.ps1' `
            -Because 'plan-issue-800 step s5 must repoint the §2b-bis attach-existing example at the new standalone Set-IssueParent.ps1 script; EXPECTED RED until s5 lands'
    }

    It 'the documented flag tokens match exactly the actual Set-IssueParent.ps1 parameter set' {
        if (-not (Test-Path $script:ScriptPath)) {
            throw "Set-IssueParent.ps1 not found at $($script:ScriptPath)"
        }
        $cmd = Get-Command -Name $script:ScriptPath

        $commonParams = @(
            [System.Management.Automation.PSCmdlet]::CommonParameters +
            [System.Management.Automation.PSCmdlet]::OptionalCommonParameters
        )
        $actualParamNames = @(
            $cmd.Parameters.Keys | Where-Object { $commonParams -notcontains $_ }
        )

        # Order-independent set comparison.
        @($script:DocFlagTokens | Sort-Object) | Should -Be @($actualParamNames | Sort-Object) `
            -Because 'the doc example flags must be exactly -ParentIssueNumber and -ChildIssueNumber with no drift from the actual script param block'
    }
}
