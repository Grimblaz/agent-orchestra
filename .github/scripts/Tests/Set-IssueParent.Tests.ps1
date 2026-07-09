#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
.SYNOPSIS
    Pester coverage for skills/safe-operations/scripts/Set-IssueParent.ps1
    (plan-issue-800 s2, AC1/AC2/AC4).

.DESCRIPTION
    Unlike Add-FollowUpIssue.ps1 (which is dot-sourced for its exported
    functions and never calls `exit`), Set-IssueParent.ps1 is a standalone
    top-level script that calls `exit 0` / `exit 1` directly. Dot-sourcing a
    script with top-level `exit` merges scopes and terminates the *calling*
    process (this would kill the Pester runner). Invoking it via the call
    operator (`& $ScriptFile @params`) instead only exits that script's own
    invocation and leaves `$LASTEXITCODE` set correctly in the caller -
    verified empirically before writing this suite.

    `gh` is mocked via a `function global:gh` shim (as in
    Add-FollowUpIssue.Tests.ps1), because global functions remain visible to
    a call-operator-invoked script in the same process. All mock STATE uses
    `$global:` (not `$script:`) variables, including inside the `gh` mock
    body itself. This was verified necessary empirically: `$script:` inside
    a `function global:name` resolves *dynamically* to whichever .ps1
    file's script scope is currently executing on the call stack, not
    lexically to the scope where the function was defined. Since the mock
    runs while Set-IssueParent.ps1 (a different script file) is executing
    on the call stack, `$script:` references inside the mock silently
    resolved to Set-IssueParent.ps1's own (empty) script scope instead of
    this test file's Pester-module scope, making state invisible in both
    directions. `$global:` has no such ambiguity.

    Mis-invocation coverage (PF20) intentionally never invokes the script
    with a missing mandatory parameter - that can prompt-hang a non-
    interactive host. Instead it asserts mandatory-ness via `Get-Command`
    parameter metadata.
#>

Describe 'Set-IssueParent' {

    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
        $script:ScriptFile = Join-Path $script:RepoRoot 'skills/safe-operations/scripts/Set-IssueParent.ps1'

        if (-not (Test-Path $script:ScriptFile)) {
            throw "Set-IssueParent.ps1 not found at $script:ScriptFile"
        }

        # Temporary directory for the physical gh-call log.
        $global:SipTempDir = Join-Path ([System.IO.Path]::GetTempPath()) "gh-mock-setparent-$([System.Guid]::NewGuid().ToString('N'))"
        New-Item -ItemType Directory -Path $global:SipTempDir -Force | Out-Null
        $global:SipLogFile = Join-Path $global:SipTempDir 'gh-call.log'

        # Fixed test issue numbers used across all scenarios.
        $global:SipTestParent = 610
        $global:SipTestChild = 999

        # --- gh mock -----------------------------------------------------
        # Distinguishes the three `gh api graphql` call shapes used by the
        # script by inspecting the `-f "query=..."` payload:
        #   * contains "addSubIssue"      -> the attach mutation
        #   * otherwise                   -> the child id/body/parent pre-check
        # `gh issue edit ... --body X` mutates $global:SipMockChildBody so a
        # second invocation's pre-check reflects the prior run's write -
        # required for the repeated-failure idempotency scenario.
        #
        # All state below is $global: (never $script:) - see file header.
        function global:gh {
            param([Parameter(ValueFromRemainingArguments = $true)]$RemainingArgs)
            $joined = $RemainingArgs -join ' '
            $joined | Out-File -FilePath $global:SipLogFile -Append -Encoding UTF8
            $global:SipGhCallCount++

            if ($joined -match 'repo\s+view') {
                $global:LASTEXITCODE = 0
                return 'Grimblaz/agent-orchestra'
            }
            if ($joined -match 'api\s+graphql') {
                $fIdx = [array]::IndexOf($RemainingArgs, '-f')
                $queryArg = if ($fIdx -ge 0 -and $fIdx + 1 -lt $RemainingArgs.Count) { $RemainingArgs[$fIdx + 1] } else { '' }

                if ($queryArg -match 'addSubIssue') {
                    $global:SipAddSubIssueCallCount++
                    $global:SipGraphqlAttempt++
                    if ($global:SipGraphqlFailAll) {
                        $global:LASTEXITCODE = 1
                        return $null
                    }
                    $global:LASTEXITCODE = 0
                    return '{"data":{"addSubIssue":{"issue":{"title":"Child"}}}}'
                } else {
                    # Child pre-check: id / body / parent { number }.
                    $global:LASTEXITCODE = 0
                    $respObj = [ordered]@{
                        data = [ordered]@{
                            repository = [ordered]@{
                                issue = [ordered]@{
                                    id     = "I_child_$($global:SipTestChild)"
                                    body   = $global:SipMockChildBody
                                    parent = if ($null -eq $global:SipMockChildParentNumber) { $null } else { [ordered]@{ number = $global:SipMockChildParentNumber } }
                                }
                            }
                        }
                    }
                    return ($respObj | ConvertTo-Json -Depth 10 -Compress)
                }
            }
            if ($joined -match 'issue\s+view\s+\d+\s+--json\s+id\s+--jq\s+\.id') {
                if ($global:SipParentViewFail) {
                    $global:LASTEXITCODE = 1
                    return $null
                }
                $global:LASTEXITCODE = 0
                return "I_parent_$($global:SipTestParent)"
            }
            if ($joined -match 'issue\s+edit') {
                $idx = [array]::IndexOf($RemainingArgs, '--body')
                if ($idx -ge 0 -and $idx + 1 -lt $RemainingArgs.Count) {
                    $global:SipCapturedEditBody = $RemainingArgs[$idx + 1]
                    $global:SipEditCallCount++
                    # Simulate persistence so a subsequent invocation's
                    # pre-check reads back this run's write.
                    $global:SipMockChildBody = $global:SipCapturedEditBody
                }
                $global:LASTEXITCODE = 0
                return ''
            }
            $global:LASTEXITCODE = 0
            return ''
        }
    }

    BeforeEach {
        if (Test-Path $global:SipLogFile) { Remove-Item $global:SipLogFile -Force }
        $global:SipGhCallCount = 0
        $global:SipGraphqlAttempt = 0
        $global:SipGraphqlFailAll = $false
        $global:SipAddSubIssueCallCount = 0
        $global:SipEditCallCount = 0
        $global:SipCapturedEditBody = $null
        $global:SipMockChildBody = 'Some existing body text.'
        $global:SipMockChildParentNumber = $null
        $global:SipParentViewFail = $false
        $global:LASTEXITCODE = 0
    }

    AfterAll {
        if (Get-Command gh -ErrorAction SilentlyContinue) {
            Remove-Item Function:\gh -ErrorAction SilentlyContinue
        }
        if (Test-Path $global:SipTempDir) {
            Remove-Item -Recurse -Force $global:SipTempDir -ErrorAction SilentlyContinue
        }
        Remove-Variable -Name Sip* -Scope Global -ErrorAction SilentlyContinue
    }

    Context 'Success' {
        It 'attaches the child via addSubIssue and exits 0 when the child has no existing parent' {
            & $script:ScriptFile -ParentIssueNumber $global:SipTestParent -ChildIssueNumber $global:SipTestChild

            $LASTEXITCODE | Should -Be 0
            $global:SipAddSubIssueCallCount | Should -Be 1
        }
    }

    Context 'Mis-invocation (PF20)' {
        # PF20: never invoke the script with a missing mandatory param - that
        # can prompt-hang a non-interactive host. Assert mandatory-ness via
        # Get-Command parameter metadata instead.
        BeforeAll {
            $script:Cmd = Get-Command $script:ScriptFile
        }

        It 'declares ParentIssueNumber as a mandatory parameter' {
            $attr = $script:Cmd.Parameters['ParentIssueNumber'].Attributes |
                Where-Object { $_ -is [System.Management.Automation.ParameterAttribute] }
            $attr.Mandatory | Should -Be $true
        }

        It 'declares ChildIssueNumber as a mandatory parameter' {
            $attr = $script:Cmd.Parameters['ChildIssueNumber'].Attributes |
                Where-Object { $_ -is [System.Management.Automation.ParameterAttribute] }
            $attr.Mandatory | Should -Be $true
        }
    }

    Context 'Attach-failure path' {
        It 'exits non-zero and splices a Parent claim + text-fallback marker when GraphQL retries are exhausted' {
            $global:SipGraphqlFailAll = $true

            & $script:ScriptFile -ParentIssueNumber $global:SipTestParent -ChildIssueNumber $global:SipTestChild

            $LASTEXITCODE | Should -Not -Be 0
            $global:SipCapturedEditBody | Should -Not -BeNullOrEmpty
            $global:SipCapturedEditBody | Should -Match "(?m)^Parent: #$($global:SipTestParent)$"
            $global:SipCapturedEditBody | Should -Match ([regex]::Escape('<!-- parent-link-mode: text-fallback -->'))
        }
    }

    Context 'Repeated-failure idempotency' {
        It 'produces exactly one Parent claim line and one marker after two consecutive failed runs' {
            $global:SipGraphqlFailAll = $true

            & $script:ScriptFile -ParentIssueNumber $global:SipTestParent -ChildIssueNumber $global:SipTestChild
            $firstExit = $LASTEXITCODE
            & $script:ScriptFile -ParentIssueNumber $global:SipTestParent -ChildIssueNumber $global:SipTestChild
            $secondExit = $LASTEXITCODE

            $firstExit | Should -Not -Be 0
            $secondExit | Should -Not -Be 0

            $finalBody = $global:SipCapturedEditBody
            $finalBody | Should -Not -BeNullOrEmpty

            $claimMatches = [regex]::Matches($finalBody, "(?m)^Parent: #$($global:SipTestParent)$")
            $claimMatches.Count | Should -Be 1

            $markerMatches = [regex]::Matches($finalBody, [regex]::Escape('<!-- parent-link-mode: text-fallback -->'))
            $markerMatches.Count | Should -Be 1
        }
    }

    Context 'Re-parent guard' {
        It 'exits non-zero and never attempts an attach when the child is already attached to a different parent' {
            $global:SipMockChildParentNumber = 555

            & $script:ScriptFile -ParentIssueNumber $global:SipTestParent -ChildIssueNumber $global:SipTestChild

            $LASTEXITCODE | Should -Not -Be 0
            $global:SipAddSubIssueCallCount | Should -Be 0
        }
    }

    Context 'Already-correct-parent' {
        It 'exits 0, attempts no attach, and strips a stale text-fallback marker when the child is already attached to the requested parent' {
            $global:SipMockChildParentNumber = $global:SipTestParent
            $global:SipMockChildBody = "Parent: #$($global:SipTestParent)`n`nSome body`n<!-- parent-link-mode: text-fallback -->"

            & $script:ScriptFile -ParentIssueNumber $global:SipTestParent -ChildIssueNumber $global:SipTestChild

            $LASTEXITCODE | Should -Be 0
            $global:SipAddSubIssueCallCount | Should -Be 0
            $global:SipCapturedEditBody | Should -Not -BeNullOrEmpty
            $global:SipCapturedEditBody | Should -Not -Match ([regex]::Escape('<!-- parent-link-mode: text-fallback -->'))
            $global:SipCapturedEditBody | Should -Not -Match "(?m)^Parent: #$($global:SipTestParent)$"
        }
    }

    Context 'Parent-resolution failure (M13)' {
        It 'exits non-zero via the "addSubIssue prerequisite failed" path when the parent pre-check (gh issue view) fails and parentId resolves to null' {
            $global:SipParentViewFail = $true

            $output = & $script:ScriptFile -ParentIssueNumber $global:SipTestParent -ChildIssueNumber $global:SipTestChild 2>&1

            $LASTEXITCODE | Should -Not -Be 0
            $global:SipAddSubIssueCallCount | Should -Be 0
            ($output | Out-String) | Should -Match 'addSubIssue prerequisite failed' `
                -Because 'a failed gh issue view parent pre-check must resolve parentId to null and hit the addSubIssue prerequisite failed error path, not the GraphQL mutation retry path'
        }
    }

    Context 'Self-reference' {
        It 'exits non-zero and makes no gh calls when ParentIssueNumber equals ChildIssueNumber' {
            & $script:ScriptFile -ParentIssueNumber $global:SipTestChild -ChildIssueNumber $global:SipTestChild

            $LASTEXITCODE | Should -Not -Be 0
            $global:SipGhCallCount | Should -Be 0
            Test-Path $global:SipLogFile | Should -Be $false
        }
    }
}
