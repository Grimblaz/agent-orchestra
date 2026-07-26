#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
.SYNOPSIS
    Coverage for .github/scripts/lib/goal-run-prompt-core.ps1 (issue #874,
    plan step 5, AC1 minus scope_boundaries).
#>

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
    $script:LibPath = Join-Path $script:RepoRoot '.github/scripts/lib/goal-run-prompt-core.ps1'
    . $script:LibPath

    # A well-formed #872 contract Hashtable, shaped the same way
    # ConvertFrom-GCContractBlock -> ConvertFrom-Yaml actually returns one
    # in production (nested Hashtables/arrays of Hashtables), not a
    # pscustomobject-only test convenience shape.
    function script:New-WellFormedGoalContract {
        @{
            schema_version              = 1
            issue                       = 874
            contract_hash               = ('a' * 64)
            targets                     = @(
                @{
                    id        = 'T1'
                    ac_ref    = 'AC1'
                    category  = 'structure-presence'
                    check     = 'pwsh -NoProfile -File .github/scripts/example-check.ps1'
                    expected  = 'exit 0; example check passes'
                    falsifier = 'A vacuous pass would look like an accumulator silently resetting null to zero.'
                    source    = $null
                }
            )
            invariants                  = @('full-pester-suite-no-new-failures', 'test-diff-integrity')
            evidence_obligations        = @{
                checkpoint_commits     = 'per-target-green'
                run_log                 = 'deviation entries plus experience observations per checkpoint'
                experience_obligations  = @(
                    @{ scenario = 'S2'; surface = 'cli' }
                )
                required_markers        = @('pipeline-metrics-credits', 'goal-run-class')
            }
            general_experience_standard = 'Canonical clause and four guardrails, verbatim from #848 D8.'
            halt_conditions              = @('unachievable-target', 'invariant-conflict', 'budget-exhausted', 'gate-input-needed', 'chain-stage-failure')
            budget                      = @{
                tokens            = 100000
                wall_clock        = '4h'
                chain_sub_ceiling = 2
                non_convergence   = 'halt-report'
            }
        }
    }
}

Describe 'goal-run-prompt-core.ps1: Test-Path resolves the lib file' -Tag 'unit' {
    It 'exists at the expected path' {
        (Test-Path -LiteralPath $script:LibPath) | Should -Be $true
    }
}

Describe 'New-GoalRunPromptText' -Tag 'unit' {

    BeforeEach {
        $script:Rendered = New-GoalRunPromptText -Contract (script:New-WellFormedGoalContract) -Issue 874 -WorktreePath 'C:\gr-874-token'
    }

    It 'renders the issue number and worktree path from the parameters, not hallucinated content' {
        $script:Rendered | Should -Match '#874'
        $script:Rendered | Should -Match ([regex]::Escape('C:\gr-874-token'))
    }

    It 'renders every invariant from the parsed contract' {
        $script:Rendered | Should -Match 'full-pester-suite-no-new-failures'
        $script:Rendered | Should -Match 'test-diff-integrity'
    }

    It 'renders the evidence obligations sourced from the parsed contract' {
        $script:Rendered | Should -Match 'per-target-green'
        $script:Rendered | Should -Match 'deviation entries plus experience observations per checkpoint'
        $script:Rendered | Should -Match 'scenario: S2 \(surface: cli\)'
        $script:Rendered | Should -Match 'pipeline-metrics-credits, goal-run-class'
    }

    It 'renders every halt condition from the parsed contract' {
        foreach ($cond in @('unachievable-target', 'invariant-conflict', 'budget-exhausted', 'gate-input-needed', 'chain-stage-failure')) {
            $script:Rendered | Should -Match $cond
        }
    }

    It 'renders a budget line sourced from the parsed contract budget object' {
        $script:Rendered | Should -Match 'tokens=100000'
        $script:Rendered | Should -Match 'wall_clock=4h'
        $script:Rendered | Should -Match 'chain_sub_ceiling=2'
        $script:Rendered | Should -Match 'non_convergence=halt-report'
    }

    It 'renders a predicate command that invokes the launch-pin-checking wrapper (M1 fix), not the raw validator directly, against the supplied issue and worktree path' {
        # F3 fix: the script path and worktree path are now single-quote-wrapped.
        $script:Rendered | Should -Match ([regex]::Escape("goal-run-predicate.ps1' -Issue 874 -RepoRoot 'C:\gr-874-token'"))
        $script:Rendered | Should -Not -Match ([regex]::Escape('goal-contract-validate.ps1'))
    }

    It 'single-quotes the worktree path so a space-containing path is not split by -RepoRoot (F3)' {
        $renderedWithSpace = New-GoalRunPromptText -Contract (script:New-WellFormedGoalContract) -Issue 874 -WorktreePath 'C:\Users\First Last\gr-874-token'
        $renderedWithSpace | Should -Match ([regex]::Escape("-RepoRoot 'C:\Users\First Last\gr-874-token'"))
    }

    It 'never renders a live plan-issue marker literal (marker-substring-containment self-match guard)' {
        $script:Rendered | Should -Not -Match '<!--\s*plan-issue-874\s*-->'
    }

    It 'never renders scope_boundaries content (explicitly excluded from this PR)' {
        $script:Rendered | Should -Not -Match 'scope_boundaries'
    }
}

Describe 'Resolve-GoalRunValidatorExitDisposition' -Tag 'unit' {

    It 'maps exit 0 to satisfied' {
        $result = Resolve-GoalRunValidatorExitDisposition -ExitCode 0 -Reason $null
        $result.Disposition | Should -Be 'satisfied'
    }

    It 'maps exit 1 to not-satisfied' {
        $result = Resolve-GoalRunValidatorExitDisposition -ExitCode 1 -Reason $null
        $result.Disposition | Should -Be 'not-satisfied'
    }

    It 'maps exit 2 (refused) to halt, not not-satisfied -- refused means the validator never attempted an assessment' {
        $result = Resolve-GoalRunValidatorExitDisposition -ExitCode 2 -Reason $null
        $result.Disposition | Should -Be 'halt'
        $result.Disposition | Should -Not -Be 'not-satisfied'
    }

    It 'includes the exit code in the exit-2 halt Reason text when no Reason was supplied' {
        $result = Resolve-GoalRunValidatorExitDisposition -ExitCode 2 -Reason $null
        $result.Reason | Should -Match 'exit 2'
    }

    It 'folds a supplied Reason into the exit-2 halt Reason text' {
        $result = Resolve-GoalRunValidatorExitDisposition -ExitCode 2 -Reason 'refused: contract-hash-mismatch'
        $result.Reason | Should -Match 'exit 2'
        $result.Reason | Should -Match 'refused: contract-hash-mismatch'
    }

    It 'produces distinguishable halt Reason text between exit-2 refused and exit-3 infra-error even though both halt' {
        $refused = Resolve-GoalRunValidatorExitDisposition -ExitCode 2 -Reason $null
        $infraError = Resolve-GoalRunValidatorExitDisposition -ExitCode 3 -Reason 'infra-error: powershell-yaml module is required but could not be loaded'
        $refused.Disposition | Should -Be 'halt'
        $infraError.Disposition | Should -Be 'halt'
        $refused.Reason | Should -Not -Be $infraError.Reason
        $refused.Reason | Should -Match 'exit 2'
        $infraError.Reason | Should -Match 'infra-error:'
    }

    It 'maps a flag-bearing exit 3 (mandatory-review flags, no infra-error prefix) to satisfied' {
        $result = Resolve-GoalRunValidatorExitDisposition -ExitCode 3 -Reason 'review-required: mandatory-review flags present (see Flags)'
        $result.Disposition | Should -Be 'satisfied'
    }

    Context '912-s3: exit-2 Refusals threading (AC7)' {
        # goal-contract-validate-core.ps1's exit-2 refused verdict always
        # sets Reason to $null -- the distinguishing literals live in the
        # separate Refusals array instead (:594-601). Before this fix,
        # Resolve-GoalRunValidatorExitDisposition never accepted Refusals at
        # all, so every exit-2 refusal collapsed to the same generic
        # fallback text regardless of cause. Each literal is also wrapped by
        # Format-GCInertRender's fenced-code-block escaping, which these
        # tests reproduce with the real helper so the fencing-strip path is
        # exercised, not assumed.

        # Format-GCInertRender is already in scope: goal-run-prompt-core.ps1
        # dot-sources goal-contract-validate-core.ps1 at its own top, and
        # this file's top-level BeforeAll dot-sources goal-run-prompt-core.ps1.

        It 'distinguishes refused: uncommitted-changes from refused: no-run-diff at the disposition (the named AC7 example)' {
            $fencedUncommitted = Format-GCInertRender -Content 'refused: uncommitted-changes'
            $fencedNoRunDiff = Format-GCInertRender -Content 'refused: no-run-diff (merge-base(abc1234, def5678) equals the run sha def5678; observed condition only)'

            $uncommitted = Resolve-GoalRunValidatorExitDisposition -ExitCode 2 -Reason $null -Refusals @($fencedUncommitted)
            $noRunDiff = Resolve-GoalRunValidatorExitDisposition -ExitCode 2 -Reason $null -Refusals @($fencedNoRunDiff)

            $uncommitted.Disposition | Should -Be 'halt'
            $noRunDiff.Disposition | Should -Be 'halt'
            $uncommitted.Reason | Should -Not -Be $noRunDiff.Reason
            $uncommitted.Reason | Should -Match 'uncommitted-changes'
            $noRunDiff.Reason | Should -Match 'no-run-diff'
        }

        It 'substring-matches the no-run-diff refusal rather than requiring exact equality, because the literal embeds commit shas that vary per run' {
            $firstRun = Format-GCInertRender -Content 'refused: no-run-diff (merge-base(aaaaaaa, bbbbbbb) equals the run sha bbbbbbb; observed condition only)'
            $secondRun = Format-GCInertRender -Content 'refused: no-run-diff (merge-base(ccccccc, ddddddd) equals the run sha ddddddd; observed condition only)'

            $first = Resolve-GoalRunValidatorExitDisposition -ExitCode 2 -Reason $null -Refusals @($firstRun)
            $second = Resolve-GoalRunValidatorExitDisposition -ExitCode 2 -Reason $null -Refusals @($secondRun)

            # The two full Reason strings differ (different shas) but both
            # substring-match the stable 'refused: no-run-diff' prefix.
            $first.Reason | Should -Not -Be $second.Reason
            $first.Reason | Should -Match 'refused: no-run-diff'
            $second.Reason | Should -Match 'refused: no-run-diff'
        }

        It 'strips the Format-GCInertRender fenced-code-block wrap so the plain refusal literal is readable, not the raw fence' {
            $fenced = Format-GCInertRender -Content 'refused: blank-check-floor'
            $fenced | Should -Match '```'

            $result = Resolve-GoalRunValidatorExitDisposition -ExitCode 2 -Reason $null -Refusals @($fenced)

            $result.Reason | Should -Match 'refused: blank-check-floor'
            $result.Reason | Should -Not -Match '```'
        }

        It 'surfaces the stripped literal on the disposition''s own Refusals field, not only folded into Reason text' {
            $fenced = Format-GCInertRender -Content 'refused: uncommitted-changes'
            $result = Resolve-GoalRunValidatorExitDisposition -ExitCode 2 -Reason $null -Refusals @($fenced)

            $result.Refusals | Should -Not -BeNullOrEmpty
            $result.Refusals[0] | Should -Be 'refused: uncommitted-changes'
        }

        It 'keeps the pre-fix generic exit-2 fallback text when -Refusals is omitted (existing call sites unaffected)' {
            $result = Resolve-GoalRunValidatorExitDisposition -ExitCode 2 -Reason $null
            $result.Reason | Should -Match 'validator did not attempt assessment'
        }
    }

    It 'maps an infra-error-prefixed exit 3 to halt -- the money test: confirms it resolves to neither satisfied nor not-satisfied' {
        $result = Resolve-GoalRunValidatorExitDisposition -ExitCode 3 -Reason 'infra-error: powershell-yaml module is required but could not be loaded'
        $result.Disposition | Should -Be 'halt'
        $result.Disposition | Should -Not -Be 'satisfied'
        $result.Disposition | Should -Not -Be 'not-satisfied'
    }

    It 'maps an exit 3 with no Reason at all to satisfied (no infra-error prefix present)' {
        $result = Resolve-GoalRunValidatorExitDisposition -ExitCode 3 -Reason $null
        $result.Disposition | Should -Be 'satisfied'
    }

    It 'fails closed to halt on an unrecognized exit code' {
        $result = Resolve-GoalRunValidatorExitDisposition -ExitCode 99 -Reason $null
        $result.Disposition | Should -Be 'halt'
    }

    Context 'M23: exit-3-with-lost-Reason must fail closed, not open' {

        It 'still resolves an exit 3 with no Reason to satisfied when -ParseFailed is NOT set (case a: a legitimate flag-bearing verdict that genuinely omits Reason -- unregressed)' {
            $result = Resolve-GoalRunValidatorExitDisposition -ExitCode 3 -Reason $null
            $result.Disposition | Should -Be 'satisfied'
        }

        It 'resolves an exit 3 with no Reason to halt when -ParseFailed IS set (case b: the subprocess output could not be parsed, Reason was lost -- fails closed instead of open)' {
            $result = Resolve-GoalRunValidatorExitDisposition -ExitCode 3 -Reason $null -ParseFailed
            $result.Disposition | Should -Be 'halt'
            $result.Disposition | Should -Not -Be 'satisfied'
        }

        It 'does not let -ParseFailed override an infra-error-prefixed Reason (already halts for a different, more specific reason)' {
            $result = Resolve-GoalRunValidatorExitDisposition -ExitCode 3 -Reason 'infra-error: worktree session threw' -ParseFailed
            $result.Disposition | Should -Be 'halt'
            $result.Reason | Should -Match 'infra-error:'
        }

        It 'does not let -ParseFailed affect a flag-bearing exit 3 that DOES carry a Reason (only the null-Reason ambiguity is in scope)' {
            $result = Resolve-GoalRunValidatorExitDisposition -ExitCode 3 -Reason 'review-required: mandatory-review flags present (see Flags)' -ParseFailed
            $result.Disposition | Should -Be 'satisfied'
        }
    }
}

Describe 'Invoke-GoalRunValidatorProcess: ParseFailed signal (M23)' -Tag 'unit' {
    # These exercise the REAL subprocess-invocation function (dot-sourced
    # into this test scope, callable without the `script:` prefix once
    # dot-sourced -- mirrored from the production call sites in this same
    # file and in goal-run-chain-core.ps1) against small fixture "validator"
    # scripts, rather than injecting a fake result object -- proving the
    # ParseFailed signal is actually produced at the source, not merely
    # plumbed through downstream.

    It 'reports ParseFailed = $true and Reason = $null when the subprocess produces no output at all (exit 3)' {
        $fakeValidator = Join-Path $TestDrive 'fake-validator-no-output.ps1'
        Set-Content -LiteralPath $fakeValidator -Value 'exit 3' -Encoding utf8

        $result = Invoke-GoalRunValidatorProcess -Issue 874 -RepoRoot $script:RepoRoot -PwshCliPath 'pwsh' -ValidatorScriptPath $fakeValidator

        $result.ExitCode | Should -Be 3
        $result.Reason | Should -BeNullOrEmpty
        $result.ParseFailed | Should -Be $true
    }

    It 'reports ParseFailed = $true and Reason = $null when the subprocess output cannot be parsed as JSON (exit 3)' {
        $fakeValidator = Join-Path $TestDrive 'fake-validator-malformed.ps1'
        Set-Content -LiteralPath $fakeValidator -Value "Write-Output 'not valid json at all {{{'; exit 3" -Encoding utf8

        $result = Invoke-GoalRunValidatorProcess -Issue 874 -RepoRoot $script:RepoRoot -PwshCliPath 'pwsh' -ValidatorScriptPath $fakeValidator

        $result.ExitCode | Should -Be 3
        $result.Reason | Should -BeNullOrEmpty
        $result.ParseFailed | Should -Be $true
    }

    It 'reports ParseFailed = $false when the subprocess output is well-formed JSON that genuinely omits Reason (exit 3, case a -- legitimate flag-bearing verdict)' {
        $fakeValidator = Join-Path $TestDrive 'fake-validator-wellformed-no-reason.ps1'
        $fakeContent = @'
Write-Output '{"Flags":["worktree-dirt"]}'
exit 3
'@
        Set-Content -LiteralPath $fakeValidator -Value $fakeContent -Encoding utf8

        $result = Invoke-GoalRunValidatorProcess -Issue 874 -RepoRoot $script:RepoRoot -PwshCliPath 'pwsh' -ValidatorScriptPath $fakeValidator

        $result.ExitCode | Should -Be 3
        $result.Reason | Should -BeNullOrEmpty
        $result.ParseFailed | Should -Be $false
    }

    It 'reports ParseFailed = $false and the parsed Reason when the subprocess output is well-formed JSON carrying a Reason' {
        $fakeValidator = Join-Path $TestDrive 'fake-validator-wellformed-with-reason.ps1'
        $fakeContent = @'
Write-Output '{"Reason":"review-required: mandatory-review flags present"}'
exit 3
'@
        Set-Content -LiteralPath $fakeValidator -Value $fakeContent -Encoding utf8

        $result = Invoke-GoalRunValidatorProcess -Issue 874 -RepoRoot $script:RepoRoot -PwshCliPath 'pwsh' -ValidatorScriptPath $fakeValidator

        $result.ExitCode | Should -Be 3
        $result.Reason | Should -Be 'review-required: mandatory-review flags present'
        $result.ParseFailed | Should -Be $false
    }

    Context '912-s3: Refusals threading (AC7)' {
        # Before this fix, this function read only $parsed.Reason and
        # silently discarded $parsed.Refusals -- exercised here against the
        # real subprocess-invocation path (a fixture "validator" script),
        # not an injected fake result object, so the read is proven at the
        # source.

        It 'reads Refusals from a well-formed exit-2 refused verdict, preserving array identity for a single entry' {
            $fakeValidator = Join-Path $TestDrive 'fake-validator-refused-single.ps1'
            $fakeContent = @'
Write-Output '{"Verdict":"refused","ExitCode":2,"Reason":null,"Refusals":["refused: uncommitted-changes"]}'
exit 2
'@
            Set-Content -LiteralPath $fakeValidator -Value $fakeContent -Encoding utf8

            $result = Invoke-GoalRunValidatorProcess -Issue 874 -RepoRoot $script:RepoRoot -PwshCliPath 'pwsh' -ValidatorScriptPath $fakeValidator

            $result.ExitCode | Should -Be 2
            $result.Reason | Should -BeNullOrEmpty
            ($result.Refusals -is [array]) | Should -Be $true
            $result.Refusals.Count | Should -Be 1
            $result.Refusals[0] | Should -Be 'refused: uncommitted-changes'
        }

        It 'reads multiple Refusals entries when the verdict carries more than one' {
            $fakeValidator = Join-Path $TestDrive 'fake-validator-refused-multi.ps1'
            $fakeContent = @'
Write-Output '{"Verdict":"refused","ExitCode":2,"Reason":null,"Refusals":["refused: uncommitted-changes","refused: no-run-diff (merge-base(aaa, bbb) equals the run sha bbb)"]}'
exit 2
'@
            Set-Content -LiteralPath $fakeValidator -Value $fakeContent -Encoding utf8

            $result = Invoke-GoalRunValidatorProcess -Issue 874 -RepoRoot $script:RepoRoot -PwshCliPath 'pwsh' -ValidatorScriptPath $fakeValidator

            $result.Refusals.Count | Should -Be 2
            $result.Refusals | Should -Contain 'refused: uncommitted-changes'
        }

        It 'reports an empty Refusals array (not a one-element array containing $null) for a non-refused verdict that omits the field' {
            $fakeValidator = Join-Path $TestDrive 'fake-validator-pass.ps1'
            $fakeContent = @'
Write-Output '{"ExitCode":0,"Reason":null}'
exit 0
'@
            Set-Content -LiteralPath $fakeValidator -Value $fakeContent -Encoding utf8

            $result = Invoke-GoalRunValidatorProcess -Issue 874 -RepoRoot $script:RepoRoot -PwshCliPath 'pwsh' -ValidatorScriptPath $fakeValidator

            @($result.Refusals).Count | Should -Be 0
        }
    }
}

Describe 'Resolve-GoalRunLoopPredicate: M23 ParseFailed pass-through' -Tag 'unit' {

    BeforeAll {
        $script:M23PinnedHash = ('a' * 64)
    }

    It 'halts (fails closed) when the validator invoker result carries ParseFailed=$true on an exit-3/null-Reason result' {
        $pinCheck = { param($Issue, $LaunchPinnedHash, $Marker, $RepoRoot, $Repo, $GhCliPath, $GitCliPath) [pscustomobject]@{ Pinned = $true; Reason = $null; LiveHash = $LaunchPinnedHash } }
        $invoker = { param($Issue, $RepoRoot, $PwshCliPath, $ValidatorScriptPath) [pscustomobject]@{ ExitCode = 3; Reason = $null; ParseFailed = $true } }
        $result = Resolve-GoalRunLoopPredicate -Issue 874 -RepoRoot 'C:\gr-874-token' -LaunchPinnedHash $script:M23PinnedHash -PinCheck $pinCheck -ValidatorInvoker $invoker
        $result.Disposition | Should -Be 'halt'
    }

    It 'stays satisfied when the validator invoker result carries no ParseFailed property at all (pre-fix test doubles are not regressed)' {
        $pinCheck = { param($Issue, $LaunchPinnedHash, $Marker, $RepoRoot, $Repo, $GhCliPath, $GitCliPath) [pscustomobject]@{ Pinned = $true; Reason = $null; LiveHash = $LaunchPinnedHash } }
        $invoker = { param($Issue, $RepoRoot, $PwshCliPath, $ValidatorScriptPath) [pscustomobject]@{ ExitCode = 3; Reason = $null } }
        $result = Resolve-GoalRunLoopPredicate -Issue 874 -RepoRoot 'C:\gr-874-token' -LaunchPinnedHash $script:M23PinnedHash -PinCheck $pinCheck -ValidatorInvoker $invoker
        $result.Disposition | Should -Be 'satisfied'
    }
}

Describe 'Test-GoalRunContractHashPinned' -Tag 'unit' {

    BeforeAll {
        $script:MatchingPayload = "schema_version: 1`nissue: 874"
        $script:MatchingHash = Get-GCContractHash -Payload $script:MatchingPayload
        $script:MatchingBody = "<!-- plan-issue-874 -->`n---`nplan-variant: goal-contract`n---`n`n<!-- goal-contract`n$script:MatchingPayload`n-->"
    }

    It 'reports Pinned = $true when the live contract hash matches the launch-pinned hash' {
        $reader = { param($Issue, $Marker, $RepoRoot, $Repo, $GhCliPath, $GitCliPath) $script:MatchingBody }
        $result = Test-GoalRunContractHashPinned -Issue 874 -LaunchPinnedHash $script:MatchingHash -CommentBodyReader $reader
        $result.Pinned | Should -Be $true
    }

    It 'reports Pinned = $false when the live contract hash no longer matches the launch-pinned hash (post-approval edit)' {
        $reader = { param($Issue, $Marker, $RepoRoot, $Repo, $GhCliPath, $GitCliPath) $script:MatchingBody }
        $staleHash = 'f' * 64
        $result = Test-GoalRunContractHashPinned -Issue 874 -LaunchPinnedHash $staleHash -CommentBodyReader $reader
        $result.Pinned | Should -Be $false
        $result.Reason | Should -Be 'contract-hash-mismatch-since-launch'
    }

    It 'reports Pinned = $false when the pinned comment cannot be resolved' {
        $reader = { param($Issue, $Marker, $RepoRoot, $Repo, $GhCliPath, $GitCliPath) $null }
        $result = Test-GoalRunContractHashPinned -Issue 874 -LaunchPinnedHash $script:MatchingHash -CommentBodyReader $reader
        $result.Pinned | Should -Be $false
        $result.Reason | Should -Be 'contract-comment-unresolvable'
    }

    It 'reports Pinned = $false when the comment body carries no extractable contract block' {
        $reader = { param($Issue, $Marker, $RepoRoot, $Repo, $GhCliPath, $GitCliPath) 'no contract block in here at all' }
        $result = Test-GoalRunContractHashPinned -Issue 874 -LaunchPinnedHash $script:MatchingHash -CommentBodyReader $reader
        $result.Pinned | Should -Be $false
        $result.Reason | Should -Be 'contract-block-unresolvable'
    }

    It 'does NOT merely re-check self-consistency -- a self-consistent live contract still fails when it differs from the launch-pinned value' {
        # The live payload is internally self-consistent on its own hash
        # (Test-GCContractHash against ITS OWN field would pass), but the
        # launch-pinned value is from a different (earlier-approved) payload.
        $selfConsistentButDifferentPayload = "schema_version: 1`nissue: 999"
        $reader = { param($Issue, $Marker, $RepoRoot, $Repo, $GhCliPath, $GitCliPath) "<!-- goal-contract`n$selfConsistentButDifferentPayload`n-->" }
        $result = Test-GoalRunContractHashPinned -Issue 874 -LaunchPinnedHash $script:MatchingHash -CommentBodyReader $reader
        $result.Pinned | Should -Be $false
    }

    Context '912-s3: Get-GCPinnedCommentBody four null-causes are distinguishable (AC6)' {
        # Get-GCPinnedCommentBody (goal-contract-validate-core.ps1) returns
        # plain $null for four distinct causes and previously all four
        # collapsed to the single generic 'contract-comment-unresolvable'
        # Reason above. This function does not change
        # Get-GCPinnedCommentBody's return contract; it recovers the cause
        # from the real Write-Warning text the function already emits (each
        # reader here reproduces that exact wording, and calls Write-Warning
        # itself the same way the real function does, so the capture path is
        # exercised against real text, not an assumed shape).

        It 'distinguishes repo/owner-unresolvable from the generic fallback' {
            $reader = {
                param($Issue, $Marker, $RepoRoot, $Repo, $GhCliPath, $GitCliPath)
                Write-Warning 'Get-GCPinnedCommentBody: could not resolve owner/repo from git remote; cannot read comments.'
                return $null
            }
            $result = Test-GoalRunContractHashPinned -Issue 874 -LaunchPinnedHash $script:MatchingHash -CommentBodyReader $reader
            $result.Pinned | Should -Be $false
            $result.Reason | Should -Be 'contract-comment-unresolvable: repo-unresolvable'
        }

        It 'distinguishes a failed gh api read from the generic fallback' {
            $reader = {
                param($Issue, $Marker, $RepoRoot, $Repo, $GhCliPath, $GitCliPath)
                Write-Warning 'Get-GCPinnedCommentBody: gh api repos/o/r/issues/874/comments --paginate failed (exit 1).'
                return $null
            }
            $result = Test-GoalRunContractHashPinned -Issue 874 -LaunchPinnedHash $script:MatchingHash -CommentBodyReader $reader
            $result.Pinned | Should -Be $false
            $result.Reason | Should -Be 'contract-comment-unresolvable: gh-read-failed'
        }

        It 'distinguishes no comment carrying the marker from the generic fallback' {
            $reader = {
                param($Issue, $Marker, $RepoRoot, $Repo, $GhCliPath, $GitCliPath)
                Write-Warning "Get-GCPinnedCommentBody: no comment on issue 874 carries marker '<!-- plan-issue-874 -->'."
                return $null
            }
            $result = Test-GoalRunContractHashPinned -Issue 874 -LaunchPinnedHash $script:MatchingHash -CommentBodyReader $reader
            $result.Pinned | Should -Be $false
            $result.Reason | Should -Be 'contract-comment-unresolvable: marker-not-found'
        }

        It 'distinguishes an ambiguous multi-marker match (an integrity event, not infra) from the generic fallback' {
            $reader = {
                param($Issue, $Marker, $RepoRoot, $Repo, $GhCliPath, $GitCliPath)
                Write-Warning "Get-GCPinnedCommentBody: 2 comments on issue 874 carry marker '<!-- plan-issue-874 -->'; refusing to guess (ambiguous)."
                return $null
            }
            $result = Test-GoalRunContractHashPinned -Issue 874 -LaunchPinnedHash $script:MatchingHash -CommentBodyReader $reader
            $result.Pinned | Should -Be $false
            $result.Reason | Should -Be 'contract-comment-unresolvable: marker-ambiguous'
        }

        It 'produces four mutually-distinct Reason values across all four causes plus the no-warning fallback' {
            $causes = @(
                { Write-Warning 'Get-GCPinnedCommentBody: could not resolve owner/repo from git remote; cannot read comments.' },
                { Write-Warning 'Get-GCPinnedCommentBody: gh api repos/o/r/issues/874/comments --paginate returned no comments.' },
                { Write-Warning "Get-GCPinnedCommentBody: no comment on issue 874 carries marker '<!-- plan-issue-874 -->'." },
                { Write-Warning "Get-GCPinnedCommentBody: 3 comments on issue 874 carry marker '<!-- plan-issue-874 -->'; refusing to guess (ambiguous)." }
            )
            $reasons = @($causes | ForEach-Object {
                    $warnAction = $_
                    $reader = { param($Issue, $Marker, $RepoRoot, $Repo, $GhCliPath, $GitCliPath) & $warnAction; return $null }.GetNewClosure()
                    (Test-GoalRunContractHashPinned -Issue 874 -LaunchPinnedHash $script:MatchingHash -CommentBodyReader $reader).Reason
                })
            ($reasons | Select-Object -Unique).Count | Should -Be 4
        }

        It 'still resolves to the original generic value when the reader returns $null with no warning at all (pre-existing callers unaffected)' {
            $reader = { param($Issue, $Marker, $RepoRoot, $Repo, $GhCliPath, $GitCliPath) $null }
            $result = Test-GoalRunContractHashPinned -Issue 874 -LaunchPinnedHash $script:MatchingHash -CommentBodyReader $reader
            $result.Reason | Should -Be 'contract-comment-unresolvable'
        }
    }
}

Describe 'Resolve-GoalRunLoopPredicate' -Tag 'unit' {

    BeforeAll {
        $script:PinnedHash = ('a' * 64)
    }

    It 'proceeds to invoke the validator and returns satisfied on a matching hash and exit 0' {
        $pinCheck = { param($Issue, $LaunchPinnedHash, $Marker, $RepoRoot, $Repo, $GhCliPath, $GitCliPath) [pscustomobject]@{ Pinned = $true; Reason = $null; LiveHash = $LaunchPinnedHash } }
        $script:invokerCallCount = 0
        $invoker = {
            param($Issue, $RepoRoot, $PwshCliPath, $ValidatorScriptPath)
            $script:invokerCallCount++
            [pscustomobject]@{ ExitCode = 0; Reason = $null }
        }
        $result = Resolve-GoalRunLoopPredicate -Issue 874 -RepoRoot 'C:\gr-874-token' -LaunchPinnedHash $script:PinnedHash -PinCheck $pinCheck -ValidatorInvoker $invoker
        $result.Disposition | Should -Be 'satisfied'
        $script:invokerCallCount | Should -Be 1
    }

    It 'halts with invariant-conflict on a hash mismatch BEFORE invoking the validator (mismatch short-circuits -- no check invocation happens)' {
        $pinCheck = { param($Issue, $LaunchPinnedHash, $Marker, $RepoRoot, $Repo, $GhCliPath, $GitCliPath) [pscustomobject]@{ Pinned = $false; Reason = 'contract-hash-mismatch-since-launch'; LiveHash = 'deadbeef' } }
        $script:invokerCallCount = 0
        $invoker = {
            param($Issue, $RepoRoot, $PwshCliPath, $ValidatorScriptPath)
            $script:invokerCallCount++
            [pscustomobject]@{ ExitCode = 0; Reason = $null }
        }
        $result = Resolve-GoalRunLoopPredicate -Issue 874 -RepoRoot 'C:\gr-874-token' -LaunchPinnedHash $script:PinnedHash -PinCheck $pinCheck -ValidatorInvoker $invoker
        $result.Disposition | Should -Be 'halt'
        $result.HaltReason | Should -Be 'invariant-conflict'
        $result.ValidatorRan | Should -Be $false
        $script:invokerCallCount | Should -Be 0 -Because 'a hash mismatch must short-circuit before the validator is ever invoked'
    }

    It 'halts with chain-stage-failure when the validator returns an infra-error-prefixed exit 3' {
        $pinCheck = { param($Issue, $LaunchPinnedHash, $Marker, $RepoRoot, $Repo, $GhCliPath, $GitCliPath) [pscustomobject]@{ Pinned = $true; Reason = $null; LiveHash = $LaunchPinnedHash } }
        $invoker = { param($Issue, $RepoRoot, $PwshCliPath, $ValidatorScriptPath) [pscustomobject]@{ ExitCode = 3; Reason = 'infra-error: worktree session threw' } }
        $result = Resolve-GoalRunLoopPredicate -Issue 874 -RepoRoot 'C:\gr-874-token' -LaunchPinnedHash $script:PinnedHash -PinCheck $pinCheck -ValidatorInvoker $invoker
        $result.Disposition | Should -Be 'halt'
        $result.HaltReason | Should -Be 'chain-stage-failure'
        $result.ValidatorRan | Should -Be $true
    }

    It 'halts with chain-stage-failure when the validator returns exit 2 (refused), and the Reason text stays distinguishable from the exit-3 infra-error halt' {
        $pinCheck = { param($Issue, $LaunchPinnedHash, $Marker, $RepoRoot, $Repo, $GhCliPath, $GitCliPath) [pscustomobject]@{ Pinned = $true; Reason = $null; LiveHash = $LaunchPinnedHash } }
        $invoker = { param($Issue, $RepoRoot, $PwshCliPath, $ValidatorScriptPath) [pscustomobject]@{ ExitCode = 2; Reason = $null } }
        $result = Resolve-GoalRunLoopPredicate -Issue 874 -RepoRoot 'C:\gr-874-token' -LaunchPinnedHash $script:PinnedHash -PinCheck $pinCheck -ValidatorInvoker $invoker
        $result.Disposition | Should -Be 'halt'
        $result.HaltReason | Should -Be 'chain-stage-failure'
        $result.ExitCode | Should -Be 2
        $result.ValidatorRan | Should -Be $true
        $result.Reason | Should -Match 'exit 2'
        $result.Reason | Should -Not -Match 'infra-error:'
    }

    It 'returns not-satisfied when the validator returns exit 1' {
        $pinCheck = { param($Issue, $LaunchPinnedHash, $Marker, $RepoRoot, $Repo, $GhCliPath, $GitCliPath) [pscustomobject]@{ Pinned = $true; Reason = $null; LiveHash = $LaunchPinnedHash } }
        $invoker = { param($Issue, $RepoRoot, $PwshCliPath, $ValidatorScriptPath) [pscustomobject]@{ ExitCode = 1; Reason = $null } }
        $result = Resolve-GoalRunLoopPredicate -Issue 874 -RepoRoot 'C:\gr-874-token' -LaunchPinnedHash $script:PinnedHash -PinCheck $pinCheck -ValidatorInvoker $invoker
        $result.Disposition | Should -Be 'not-satisfied'
    }
}
