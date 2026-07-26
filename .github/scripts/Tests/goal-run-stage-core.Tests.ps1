#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
.SYNOPSIS
    Coverage for .github/scripts/lib/goal-run-stage-core.ps1 (issue #874,
    plan step 4, AC1 command + stage-machine half).
#>

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
    $script:LibPath = Join-Path $script:RepoRoot '.github/scripts/lib/goal-run-stage-core.ps1'
    . $script:LibPath

    function script:New-GRSTestRepo {
        param([Parameter(Mandatory)][string]$Path)
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
        & git -C $Path init -q -b main . 2>&1 | Out-Null
        & git -C $Path config user.email 'goal-run-stage-s4@example.com' 2>&1 | Out-Null
        & git -C $Path config user.name 'goal-run-stage-s4' 2>&1 | Out-Null
        $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
        [System.IO.File]::WriteAllText((Join-Path $Path 'seed.txt'), "seed`n", $utf8NoBom)
        & git -C $Path add -A 2>&1 | Out-Null
        & git -C $Path commit -q -m 'seed' 2>&1 | Out-Null
        return $Path
    }

    function script:Remove-GRSTestWorktree {
        param([Parameter(Mandatory)][string]$RepoRoot, [Parameter(Mandatory)][string]$WorktreePath)
        & git -C $RepoRoot worktree remove --force $WorktreePath 2>&1 | Out-Null
        & git -C $RepoRoot worktree prune 2>&1 | Out-Null
        if (Test-Path -LiteralPath $WorktreePath) {
            Remove-Item -LiteralPath $WorktreePath -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'goal-run-stage-core.ps1: Test-Path resolves the lib file' -Tag 'unit' {
    It 'exists at the expected path' {
        (Test-Path -LiteralPath $script:LibPath) | Should -Be $true
    }
}

Describe 'Resolve-GoalRunResumeStage' -Tag 'unit' {

    It 'reports blocked when the contract hash is not verified, regardless of other signals' {
        $result = Resolve-GoalRunResumeStage -ContractHashVerified $false -InflightMarkerPresent $true -ActiveStatePresent $true
        $result.ResumeStage | Should -Be 'blocked'
        $result.Reason | Should -Be 'contract-hash-unverified'
    }

    It 'reports complete when terminal emissions are verified, overriding everything else' {
        $result = Resolve-GoalRunResumeStage -ContractHashVerified $true -TerminalEmissionsVerified $true -ExplicitStageMarker 'loop-launched'
        $result.ResumeStage | Should -Be 'complete'
    }

    It 'reports pre-loop on a fresh launch with nothing present' {
        $result = Resolve-GoalRunResumeStage -ContractHashVerified $true
        $result.ResumeStage | Should -Be 'pre-loop'
        $result.Reason | Should -Be 'fresh-launch'
    }

    It 'reports pre-loop when only the inflight marker is present (crash mid pre-loop)' {
        $result = Resolve-GoalRunResumeStage -ContractHashVerified $true -InflightMarkerPresent $true
        $result.ResumeStage | Should -Be 'pre-loop'
        $result.Reason | Should -Be 'marker-posted-not-provisioned'
    }

    It 'reports loop-launched when the worktree is provisioned but the loop has not started' {
        $result = Resolve-GoalRunResumeStage -ContractHashVerified $true -InflightMarkerPresent $true -ActiveStatePresent $true
        $result.ResumeStage | Should -Be 'loop-launched'
    }

    It '#912 D1: reports loop-interrupted when the run log has a checkpoint but no explicit stage marker exists (resume re-derives progress from committed state, not the dead session)' {
        $result = Resolve-GoalRunResumeStage -ContractHashVerified $true -ActiveStatePresent $true -RunLogHasCheckpoint $true
        $result.ResumeStage | Should -Be 'loop-interrupted'
        $result.Reason | Should -Be 'run-log-implies-loop-launched-no-explicit-marker'
    }

    It '#912 D1: reports loop-interrupted when the explicit stage marker says loop-launched' {
        $result = Resolve-GoalRunResumeStage -ContractHashVerified $true -ExplicitStageMarker 'loop-launched'
        $result.ResumeStage | Should -Be 'loop-interrupted'
    }

    It 'reports chain-dispatched when the explicit stage marker says loop-released' {
        $result = Resolve-GoalRunResumeStage -ContractHashVerified $true -ExplicitStageMarker 'loop-released'
        $result.ResumeStage | Should -Be 'chain-dispatched'
    }

    It 'reports chain-dispatched (awaiting terminal emissions) when the explicit stage marker says chain-dispatched' {
        $result = Resolve-GoalRunResumeStage -ContractHashVerified $true -ExplicitStageMarker 'chain-dispatched'
        $result.ResumeStage | Should -Be 'chain-dispatched'
        $result.Reason | Should -Be 'awaiting-terminal-emissions'
    }

    It 'lets an explicit stage marker take precedence over a stale ActiveStatePresent=false signal' {
        # Even if the caller failed to detect the active-state file for some
        # reason, an explicit stage marker is authoritative.
        $result = Resolve-GoalRunResumeStage -ContractHashVerified $true -ActiveStatePresent $false -ExplicitStageMarker 'loop-released'
        $result.ResumeStage | Should -Be 'chain-dispatched'
    }
}

Describe 'Goal-run stage marker body round-trip' -Tag 'unit' {

    It 'builds and parses a stage marker body symmetrically' {
        $body = New-GoalRunStageMarkerBody -Issue 874 -Stage 'loop-launched' -ContractHash ('a' * 64) -UpdatedAt '2026-07-23T00:00:00.0000000Z'
        $parsed = ConvertFrom-GoalRunStageMarkerBody -Body $body
        $parsed.Parsed | Should -Be $true
        $parsed.Issue | Should -Be 874
        $parsed.Stage | Should -Be 'loop-launched'
        $parsed.ContractHash | Should -Be ('a' * 64)
        $parsed.UpdatedAt | Should -Be '2026-07-23T00:00:00.0000000Z'
    }

    It 'reports Parsed = $false for a body with no stage-marker head' {
        $parsed = ConvertFrom-GoalRunStageMarkerBody -Body 'not a marker at all'
        $parsed.Parsed | Should -Be $false
    }

    It 'M10 fix: round-trips an optional WorktreePath field' {
        $body = New-GoalRunStageMarkerBody -Issue 874 -Stage 'loop-launched' -ContractHash ('a' * 64) -UpdatedAt '2026-07-23T00:00:00.0000000Z' -WorktreePath 'C:\fake\gr-874-abc123'
        $parsed = ConvertFrom-GoalRunStageMarkerBody -Body $body
        $parsed.WorktreePath | Should -Be 'C:\fake\gr-874-abc123'
    }

    It 'M10 fix: WorktreePath is $null when omitted, never an empty-string placeholder' {
        $body = New-GoalRunStageMarkerBody -Issue 874 -Stage 'loop-launched' -ContractHash ('a' * 64) -UpdatedAt '2026-07-23T00:00:00.0000000Z'
        $parsed = ConvertFrom-GoalRunStageMarkerBody -Body $body
        $parsed.WorktreePath | Should -BeNullOrEmpty
        $body | Should -Not -Match 'worktree_path'
    }

    It 'M17 fix: the writer ValidateSet rejects pre-loop -- no marker is ever posted for the implicit starting stage' {
        { New-GoalRunStageMarkerBody -Issue 874 -Stage 'pre-loop' -ContractHash ('a' * 64) -UpdatedAt '2026-07-23T00:00:00.0000000Z' } | Should -Throw
    }

    It 'M17 fix: the Set-GoalRunStageMarker ValidateSet also rejects pre-loop' {
        { Set-GoalRunStageMarker -Issue 874 -Stage 'pre-loop' -ContractHash ('a' * 64) } | Should -Throw
    }
}

Describe 'Goal-run inflight marker body round-trip' -Tag 'unit' {

    It 'builds and parses an unresolved inflight marker body symmetrically' {
        $body = New-GoalRunInflightMarkerBody -Issue 874 -ContractHash ('b' * 64) -LaunchedAt '2026-07-23T00:00:00.0000000Z'
        $parsed = ConvertFrom-GoalRunInflightMarkerBody -Body $body
        $parsed.Parsed | Should -Be $true
        $parsed.Issue | Should -Be 874
        $parsed.Status | Should -Be 'unresolved'
        $parsed.ContractHash | Should -Be ('b' * 64)
        $parsed.ResolvedReason | Should -BeNullOrEmpty
    }

    It 'round-trips a resolved marker carrying a resolved_reason' {
        $body = New-GoalRunInflightMarkerBody -Issue 874 -ContractHash ('b' * 64) -LaunchedAt '2026-07-23T00:00:00.0000000Z' -Status 'resolved' -ResolvedReason 'yielded-to-lower-comment-id'
        $parsed = ConvertFrom-GoalRunInflightMarkerBody -Body $body
        $parsed.Status | Should -Be 'resolved'
        $parsed.ResolvedReason | Should -Be 'yielded-to-lower-comment-id'
    }

    It '#912 step 4: round-trips an adopted marker carrying the owner/session field' {
        $body = New-GoalRunInflightMarkerBody -Issue 912 -ContractHash ('e' * 64) -LaunchedAt '2026-07-23T00:00:00.0000000Z' -Status 'adopted' -AdoptedBySessionId 'sess-adopt-1'
        $parsed = ConvertFrom-GoalRunInflightMarkerBody -Body $body
        $parsed.Status | Should -Be 'adopted'
        $parsed.AdoptedBySessionId | Should -Be 'sess-adopt-1'
    }

    It '#912 step 4: the adopted body is NOT byte-identical to the pre-adoption unresolved body for the same issue/hash/launched-at (the observable-mutation invariant)' {
        $unresolvedBody = New-GoalRunInflightMarkerBody -Issue 912 -ContractHash ('e' * 64) -LaunchedAt '2026-07-23T00:00:00.0000000Z' -Status 'unresolved'
        $adoptedBody = New-GoalRunInflightMarkerBody -Issue 912 -ContractHash ('e' * 64) -LaunchedAt '2026-07-23T00:00:00.0000000Z' -Status 'adopted' -AdoptedBySessionId 'sess-adopt-1'
        $adoptedBody | Should -Not -Be $unresolvedBody
    }
}

Describe 'Resolve-GoalRunInflightMutexOutcome (marker-first ordering + reconcile tiebreak)' -Tag 'unit' {

    It 'lets the lowest (earliest) comment id proceed when two concurrent markers exist' {
        $result = Resolve-GoalRunInflightMutexOutcome -OwnCommentId 100 -LiveMarkerCommentIds @(100, 105)
        $result.Outcome | Should -Be 'proceed'
        $result.WinningCommentId | Should -Be 100
    }

    It 'makes the higher comment id yield when two concurrent markers exist' {
        $result = Resolve-GoalRunInflightMutexOutcome -OwnCommentId 105 -LiveMarkerCommentIds @(100, 105)
        $result.Outcome | Should -Be 'yield'
        $result.WinningCommentId | Should -Be 100
    }

    It 'proceeds when it is the only live marker' {
        $result = Resolve-GoalRunInflightMutexOutcome -OwnCommentId 42 -LiveMarkerCommentIds @()
        $result.Outcome | Should -Be 'proceed'
    }

    It 'auto-includes the own id even if the caller omitted it from the live set' {
        $result = Resolve-GoalRunInflightMutexOutcome -OwnCommentId 50 -LiveMarkerCommentIds @(60, 70)
        $result.Outcome | Should -Be 'proceed'
        $result.WinningCommentId | Should -Be 50
    }
}

Describe 'Resolve-GoalRunInflightMarkerForResolution (#912 step 4: re-fetch helper for resolution sites)' -Tag 'unit' {

    It 'selects the lowest-id LIVE (unresolved) marker, mirroring the Resolve-GoalRunInflightMutexOutcome tiebreak rule' {
        Mock -CommandName Get-GoalRunInflightMarkers -MockWith {
            @(
                [pscustomobject]@{ CommentId = 200; Status = 'unresolved'; ContractHash = ('a' * 64); LaunchedAt = '2026-07-23T00:00:00.0000000Z'; ResolvedReason = $null },
                [pscustomobject]@{ CommentId = 105; Status = 'unresolved'; ContractHash = ('b' * 64); LaunchedAt = '2026-07-22T00:00:00.0000000Z'; ResolvedReason = $null }
            )
        }

        $result = Resolve-GoalRunInflightMarkerForResolution -Issue 912

        $result.Found | Should -Be $true
        $result.CommentId | Should -Be 105
        $result.ContractHash | Should -Be ('b' * 64)
        $result.LaunchedAt | Should -Be '2026-07-22T00:00:00.0000000Z'
        $result.Reason | Should -Be 'resolved-lowest-unresolved-comment-id'
    }

    It 'applies its OWN unresolved-only filter -- a lower-id RESOLVED marker never wins over a higher-id unresolved one (the :658 filter is the caller''s, not inherited)' {
        Mock -CommandName Get-GoalRunInflightMarkers -MockWith {
            @(
                [pscustomobject]@{ CommentId = 50; Status = 'resolved'; ContractHash = ('a' * 64); LaunchedAt = '2026-07-20T00:00:00.0000000Z'; ResolvedReason = 'yielded-to-lower-comment-id' },
                [pscustomobject]@{ CommentId = 105; Status = 'unresolved'; ContractHash = ('b' * 64); LaunchedAt = '2026-07-22T00:00:00.0000000Z'; ResolvedReason = $null }
            )
        }

        $result = Resolve-GoalRunInflightMarkerForResolution -Issue 912

        $result.Found | Should -Be $true
        $result.CommentId | Should -Be 105
    }

    It 'reports no-unresolved-marker when Get-GoalRunInflightMarkers returns nothing live' {
        Mock -CommandName Get-GoalRunInflightMarkers -MockWith { @() }

        $result = Resolve-GoalRunInflightMarkerForResolution -Issue 912

        $result.Found | Should -Be $false
        $result.CommentId | Should -BeNullOrEmpty
        $result.Reason | Should -Be 'no-unresolved-marker'
    }

    It 'refuses as marker-fields-unparseable instead of letting a downstream Mandatory parameter throw, when the winning marker has Parsed=true but null ContractHash/LaunchedAt' {
        Mock -CommandName Get-GoalRunInflightMarkers -MockWith {
            @([pscustomobject]@{ CommentId = 105; Status = 'unresolved'; ContractHash = $null; LaunchedAt = $null; ResolvedReason = $null })
        }

        $result = Resolve-GoalRunInflightMarkerForResolution -Issue 912

        $result.Found | Should -Be $false
        $result.CommentId | Should -Be 105
        $result.Reason | Should -Be 'marker-fields-unparseable'
    }

    It '#912 review fix (M6): refuses as marker-fields-unparseable when LaunchedAt is non-empty GARBAGE (e.g. "TBD"), not just when it is null/empty -- the pre-fix IsNullOrEmpty-only guard let this straight through to a downstream throw' {
        Mock -CommandName Get-GoalRunInflightMarkers -MockWith {
            @([pscustomobject]@{ CommentId = 105; Status = 'unresolved'; ContractHash = ('a' * 64); LaunchedAt = 'TBD'; ResolvedReason = $null })
        }

        $result = Resolve-GoalRunInflightMarkerForResolution -Issue 912

        $result.Found | Should -Be $false
        $result.CommentId | Should -Be 105
        $result.Reason | Should -Be 'marker-fields-unparseable'
    }

    It '#912 review fix (M1): an ADOPTED marker is LIVE, not resolved -- it is found and selected the same as an unresolved one (fixes the pre-fix bug where an adopted marker held by the current session was invisible to its own eventual resolution call)' {
        Mock -CommandName Get-GoalRunInflightMarkers -MockWith {
            @([pscustomobject]@{ CommentId = 100; Status = 'adopted'; ContractHash = ('a' * 64); LaunchedAt = '2026-07-23T00:00:00.0000000Z'; ResolvedReason = $null; AdoptedBySessionId = 'sess-1' })
        }

        $result = Resolve-GoalRunInflightMarkerForResolution -Issue 912

        $result.Found | Should -Be $true
        $result.CommentId | Should -Be 100
        $result.Reason | Should -Be 'resolved-lowest-unresolved-comment-id'
    }

    It '#912 review fix (M1): tiebreaks correctly across a MIX of unresolved and adopted markers by lowest comment id, same as the all-unresolved case' {
        Mock -CommandName Get-GoalRunInflightMarkers -MockWith {
            @(
                [pscustomobject]@{ CommentId = 200; Status = 'unresolved'; ContractHash = ('a' * 64); LaunchedAt = '2026-07-23T00:00:00.0000000Z'; ResolvedReason = $null },
                [pscustomobject]@{ CommentId = 105; Status = 'adopted'; ContractHash = ('b' * 64); LaunchedAt = '2026-07-22T00:00:00.0000000Z'; ResolvedReason = $null; AdoptedBySessionId = 'sess-1' }
            )
        }

        $result = Resolve-GoalRunInflightMarkerForResolution -Issue 912

        $result.Found | Should -Be $true
        $result.CommentId | Should -Be 105
    }

    It 'integration: a genuinely unparseable ConvertFrom-GoalRunInflightMarkerBody result (Parsed=true, fields null on a hand-edited/truncated marker) flows through the real Get-GoalRunInflightMarkers into the typed refusal, not a throw' {
        $handEditedBody = "<!-- goal-run-inflight-912 -->`n## Goal-run in-flight marker`n`n- **schema_version**: 1`n- **issue**: 912`n- **status**: unresolved"
        Mock -CommandName Get-GoalRunIssueComments -MockWith {
            @([pscustomobject]@{ id = 300; url = 'https://github.com/o/r/issues/912#issuecomment-300'; body = $handEditedBody })
        }

        { Resolve-GoalRunInflightMarkerForResolution -Issue 912 } | Should -Not -Throw

        $result = Resolve-GoalRunInflightMarkerForResolution -Issue 912
        $result.Found | Should -Be $false
        $result.Reason | Should -Be 'marker-fields-unparseable'
    }
}

Describe 'Set-GoalRunInflightMarkerAdopted (#912 step 4: mutate-and-verify adoption primitive)' -Tag 'unit' {

    BeforeEach {
        $script:grsaGhPatchCalled = $false
        $script:grsaGhExitCode = 0
        function global:gh {
            param([Parameter(ValueFromRemainingArguments = $true)]$Args)
            $joined = $Args -join ' '
            if ($joined -match '^api -X PATCH ') {
                $script:grsaGhPatchCalled = $true
                $global:LASTEXITCODE = $script:grsaGhExitCode
                return ''
            }
            $global:LASTEXITCODE = 0
            return ''
        }
    }

    AfterEach {
        # Same footgun as find-or-upsert-comment.Tests.ps1: `Remove-Item
        # function:global:gh` treats `global:gh` as a literal name and
        # silently no-ops, leaking the mock into later test files.
        # `Remove-Item Function:gh` is what actually removes it.
        Remove-Item Function:gh -ErrorAction SilentlyContinue
    }

    It 'mutates the marker to status=adopted plus the session field, then verifies the mutation actually landed via a re-fetch AND survives the M7 reconfirmation read (the observable-mutation invariant)' {
        $preBody = New-GoalRunInflightMarkerBody -Issue 912 -ContractHash ('f' * 64) -LaunchedAt '2026-07-23T00:00:00.0000000Z' -Status 'unresolved'
        $postBody = New-GoalRunInflightMarkerBody -Issue 912 -ContractHash ('f' * 64) -LaunchedAt '2026-07-23T00:00:00.0000000Z' -Status 'adopted' -AdoptedBySessionId 'sess-42'

        $script:grsaReadCount = 0
        Mock -CommandName Get-GoalRunIssueComments -MockWith {
            $script:grsaReadCount++
            if ($script:grsaReadCount -eq 1) {
                return @([pscustomobject]@{ id = 100; url = 'https://github.com/o/r/issues/912#issuecomment-100'; body = $preBody })
            }
            # Both the verification read (2nd) and the M7 reconfirm read
            # (3rd) see the same landed-and-still-ours body.
            return @([pscustomobject]@{ id = 100; url = 'https://github.com/o/r/issues/912#issuecomment-100'; body = $postBody })
        }

        $result = Set-GoalRunInflightMarkerAdopted -CommentId 100 -Issue 912 -ContractHash ('f' * 64) -LaunchedAt '2026-07-23T00:00:00.0000000Z' -SessionId 'sess-42' -ReconfirmDelayMs 0

        $result.Success | Should -Be $true
        $result.Verified | Should -Be $true
        $result.Reason | Should -Be 'adopted-and-verified'
        $result.AdoptedBySessionId | Should -Be 'sess-42'
        $script:grsaGhPatchCalled | Should -Be $true
        # #912 review fix (M7): 3 reads now -- pre-check, verification, AND
        # the new TOCTOU reconfirmation read.
        Should -Invoke -CommandName Get-GoalRunIssueComments -Times 3
    }

    It '#912 review fix (M7): reports lost-to-concurrent-adopter when a concurrent adopter''s PATCH lands AFTER this session''s own verification read succeeds -- the race window the reconfirmation read exists to catch' {
        $preBody = New-GoalRunInflightMarkerBody -Issue 912 -ContractHash ('f' * 64) -LaunchedAt '2026-07-23T00:00:00.0000000Z' -Status 'unresolved'
        $ownAdoptedBody = New-GoalRunInflightMarkerBody -Issue 912 -ContractHash ('f' * 64) -LaunchedAt '2026-07-23T00:00:00.0000000Z' -Status 'adopted' -AdoptedBySessionId 'sess-42'
        $concurrentAdoptedBody = New-GoalRunInflightMarkerBody -Issue 912 -ContractHash ('f' * 64) -LaunchedAt '2026-07-23T00:00:00.0000000Z' -Status 'adopted' -AdoptedBySessionId 'sess-concurrent-winner'

        $script:grsaReadCount = 0
        Mock -CommandName Get-GoalRunIssueComments -MockWith {
            $script:grsaReadCount++
            switch ($script:grsaReadCount) {
                1 { return @([pscustomobject]@{ id = 100; url = 'https://github.com/o/r/issues/912#issuecomment-100'; body = $preBody }) }
                2 { return @([pscustomobject]@{ id = 100; url = 'https://github.com/o/r/issues/912#issuecomment-100'; body = $ownAdoptedBody }) }
                default { return @([pscustomobject]@{ id = 100; url = 'https://github.com/o/r/issues/912#issuecomment-100'; body = $concurrentAdoptedBody }) }
            }
        }

        $result = Set-GoalRunInflightMarkerAdopted -CommentId 100 -Issue 912 -ContractHash ('f' * 64) -LaunchedAt '2026-07-23T00:00:00.0000000Z' -SessionId 'sess-42' -ReconfirmDelayMs 0

        $result.Success | Should -Be $false
        $result.Verified | Should -Be $false
        $result.Reason | Should -Be 'lost-to-concurrent-adopter'
        $result.AdoptedBySessionId | Should -Be 'sess-concurrent-winner'
    }

    It '#912 review fix (M7): reports reconfirm-comment-not-found when the comment vanishes between the verification read and the reconfirmation read' {
        $preBody = New-GoalRunInflightMarkerBody -Issue 912 -ContractHash ('f' * 64) -LaunchedAt '2026-07-23T00:00:00.0000000Z' -Status 'unresolved'
        $ownAdoptedBody = New-GoalRunInflightMarkerBody -Issue 912 -ContractHash ('f' * 64) -LaunchedAt '2026-07-23T00:00:00.0000000Z' -Status 'adopted' -AdoptedBySessionId 'sess-42'

        $script:grsaReadCount = 0
        Mock -CommandName Get-GoalRunIssueComments -MockWith {
            $script:grsaReadCount++
            switch ($script:grsaReadCount) {
                1 { return @([pscustomobject]@{ id = 100; url = 'https://github.com/o/r/issues/912#issuecomment-100'; body = $preBody }) }
                2 { return @([pscustomobject]@{ id = 100; url = 'https://github.com/o/r/issues/912#issuecomment-100'; body = $ownAdoptedBody }) }
                default { return @() }
            }
        }

        $result = Set-GoalRunInflightMarkerAdopted -CommentId 100 -Issue 912 -ContractHash ('f' * 64) -LaunchedAt '2026-07-23T00:00:00.0000000Z' -SessionId 'sess-42' -ReconfirmDelayMs 0

        $result.Success | Should -Be $false
        $result.Verified | Should -Be $false
        $result.Reason | Should -Be 'reconfirm-comment-not-found'
    }

    It '#912 review fix (M7): the body-unchanged comparison uses the ACTUALLY-FETCHED pre-adoption body, not a synthetic reconstruction -- catches drift a reconstructed body would miss' {
        # Deliberately not byte-identical to what New-GoalRunInflightMarkerBody
        # would reconstruct from the same Issue/ContractHash/LaunchedAt/Status
        # inputs (trailing newline appended) -- simulating real-world drift
        # between the live body and a synthetic reconstruction.
        $actualFetchedPreBody = (New-GoalRunInflightMarkerBody -Issue 912 -ContractHash ('f' * 64) -LaunchedAt '2026-07-23T00:00:00.0000000Z' -Status 'unresolved') + "`n"

        Mock -CommandName Get-GoalRunIssueComments -MockWith {
            @([pscustomobject]@{ id = 100; url = 'https://github.com/o/r/issues/912#issuecomment-100'; body = $actualFetchedPreBody })
        }

        $result = Set-GoalRunInflightMarkerAdopted -CommentId 100 -Issue 912 -ContractHash ('f' * 64) -LaunchedAt '2026-07-23T00:00:00.0000000Z' -SessionId 'sess-42' -ReconfirmDelayMs 0

        # Before the M7 fix, $preBody was a SYNTHETIC reconstruction lacking
        # the trailing newline, so it would never equal $actualFetchedPreBody
        # and the comparison would fall through to a misleading
        # 'verification-status-mismatch' (the mock's PATCH is a no-op, so the
        # body genuinely never changed to 'adopted' either) instead of the
        # correct 'verification-body-unchanged'.
        $result.Reason | Should -Be 'verification-body-unchanged'
        $result.Success | Should -Be $false
    }

    It 'concurrent-adoption rejection: refuses with already-adopted and never PATCHes when the pre-check read shows another session already adopted this marker' {
        $alreadyAdoptedBody = New-GoalRunInflightMarkerBody -Issue 912 -ContractHash ('f' * 64) -LaunchedAt '2026-07-23T00:00:00.0000000Z' -Status 'adopted' -AdoptedBySessionId 'sess-first'

        Mock -CommandName Get-GoalRunIssueComments -MockWith {
            @([pscustomobject]@{ id = 100; url = 'https://github.com/o/r/issues/912#issuecomment-100'; body = $alreadyAdoptedBody })
        }

        $result = Set-GoalRunInflightMarkerAdopted -CommentId 100 -Issue 912 -ContractHash ('f' * 64) -LaunchedAt '2026-07-23T00:00:00.0000000Z' -SessionId 'sess-second'

        $result.Success | Should -Be $false
        $result.Reason | Should -Be 'already-adopted'
        $result.AdoptedBySessionId | Should -Be 'sess-first'
        $script:grsaGhPatchCalled | Should -Be $false
        Should -Invoke -CommandName Get-GoalRunIssueComments -Times 1
    }

    It 'reports patch-failed and does not claim Verified when the gh api PATCH call itself fails' {
        $preBody = New-GoalRunInflightMarkerBody -Issue 912 -ContractHash ('f' * 64) -LaunchedAt '2026-07-23T00:00:00.0000000Z' -Status 'unresolved'
        Mock -CommandName Get-GoalRunIssueComments -MockWith {
            @([pscustomobject]@{ id = 100; url = 'https://github.com/o/r/issues/912#issuecomment-100'; body = $preBody })
        }
        $script:grsaGhExitCode = 1

        $result = Set-GoalRunInflightMarkerAdopted -CommentId 100 -Issue 912 -ContractHash ('f' * 64) -LaunchedAt '2026-07-23T00:00:00.0000000Z' -SessionId 'sess-42'

        $result.Success | Should -Be $false
        $result.Verified | Should -Be $false
        $result.Reason | Should -Be 'patch-failed'
    }

    It 'reports verification-body-unchanged when the re-fetched body is byte-identical to the pre-adoption body despite a 0 PATCH exit code (the no-ETag/If-Match race this primitive exists to catch)' {
        $preBody = New-GoalRunInflightMarkerBody -Issue 912 -ContractHash ('f' * 64) -LaunchedAt '2026-07-23T00:00:00.0000000Z' -Status 'unresolved'
        Mock -CommandName Get-GoalRunIssueComments -MockWith {
            @([pscustomobject]@{ id = 100; url = 'https://github.com/o/r/issues/912#issuecomment-100'; body = $preBody })
        }

        $result = Set-GoalRunInflightMarkerAdopted -CommentId 100 -Issue 912 -ContractHash ('f' * 64) -LaunchedAt '2026-07-23T00:00:00.0000000Z' -SessionId 'sess-42' -ReconfirmDelayMs 0

        # #912 review fix (M18): Success must be truthful -- a verification
        # failure is not a success, even though the PATCH exit code itself
        # was 0. Before the fix this asserted Success = $true.
        $result.Success | Should -Be $false
        $result.Verified | Should -Be $false
        $result.Reason | Should -Be 'verification-body-unchanged'
    }

    It 'reports verification-comment-not-found when the verification read cannot locate the comment at all' {
        $preBody = New-GoalRunInflightMarkerBody -Issue 912 -ContractHash ('f' * 64) -LaunchedAt '2026-07-23T00:00:00.0000000Z' -Status 'unresolved'
        $script:grsaReadCount = 0
        Mock -CommandName Get-GoalRunIssueComments -MockWith {
            $script:grsaReadCount++
            if ($script:grsaReadCount -eq 1) {
                return @([pscustomobject]@{ id = 100; url = 'https://github.com/o/r/issues/912#issuecomment-100'; body = $preBody })
            }
            return @()
        }

        $result = Set-GoalRunInflightMarkerAdopted -CommentId 100 -Issue 912 -ContractHash ('f' * 64) -LaunchedAt '2026-07-23T00:00:00.0000000Z' -SessionId 'sess-42' -ReconfirmDelayMs 0

        # #912 review fix (M18): Success must be truthful here too. Before
        # the fix this asserted Success = $true.
        $result.Success | Should -Be $false
        $result.Verified | Should -Be $false
        $result.Reason | Should -Be 'verification-comment-not-found'
    }

    It 'the ContractHash carried through to the adopted body is NOT reconciled against any other value -- it is copied through unchanged (forensics-only scope)' {
        $preBody = New-GoalRunInflightMarkerBody -Issue 912 -ContractHash ('f' * 64) -LaunchedAt '2026-07-23T00:00:00.0000000Z' -Status 'unresolved'
        $capturedPatchBody = $null
        function global:gh {
            param([Parameter(ValueFromRemainingArguments = $true)]$Args)
            $joined = $Args -join ' '
            if ($joined -match '^api -X PATCH (\S+) --input (.+)$') {
                $script:capturedPatchBody = (Get-Content -LiteralPath $Matches[2].Trim() -Raw | ConvertFrom-Json).body
                $global:LASTEXITCODE = 0
                return ''
            }
            $global:LASTEXITCODE = 0
            return ''
        }
        $script:grsaReadCount = 0
        Mock -CommandName Get-GoalRunIssueComments -MockWith {
            $script:grsaReadCount++
            if ($script:grsaReadCount -eq 1) {
                return @([pscustomobject]@{ id = 100; url = 'https://github.com/o/r/issues/912#issuecomment-100'; body = $preBody })
            }
            $postBody = New-GoalRunInflightMarkerBody -Issue 912 -ContractHash ('f' * 64) -LaunchedAt '2026-07-23T00:00:00.0000000Z' -Status 'adopted' -AdoptedBySessionId 'sess-42'
            return @([pscustomobject]@{ id = 100; url = 'https://github.com/o/r/issues/912#issuecomment-100'; body = $postBody })
        }

        Set-GoalRunInflightMarkerAdopted -CommentId 100 -Issue 912 -ContractHash ('f' * 64) -LaunchedAt '2026-07-23T00:00:00.0000000Z' -SessionId 'sess-42' -ReconfirmDelayMs 0 | Out-Null

        # The PATCHed body's contract_hash is the SAME value passed in --
        # this function never compares it against a launch-pinned hash, it
        # only carries it through. Reconciliation is out of scope (see the
        # forensics-only comment on Set-GoalRunInflightMarkerAdopted).
        $expectedHashPattern = [regex]::Escape('f' * 64)
        $script:capturedPatchBody | Should -Match $expectedHashPattern
    }
}

Describe 'Get-GoalRunIssueComments' -Tag 'unit' {

    It 'M19 fix: flattens a multi-page paginated response into a single flat array normalized to id/url/body' {
        $mockGhPath = Join-Path $TestDrive 'gh-comments-paginated.ps1'
        @'
param()
if ($args[0] -eq 'api') {
    Write-Output '[[{"id":1,"html_url":"https://github.com/o/r/issues/9#issuecomment-1","body":"c1"}],[{"id":101,"html_url":"https://github.com/o/r/issues/9#issuecomment-101","body":"c101 (past the 100-comment page cap)"}]]'
    exit 0
}
exit 1
'@ | Set-Content $mockGhPath -Encoding UTF8

        $result = Get-GoalRunIssueComments -Issue 9 -Owner 'o' -Repo 'r' -GhCliPath $mockGhPath

        $result.Count | Should -Be 2
        $result[0].id | Should -Be 1
        $result[0].url | Should -Be 'https://github.com/o/r/issues/9#issuecomment-1'
        $result[0].body | Should -Be 'c1'
        $result[1].id | Should -Be 101
        $result[1].body | Should -Match 'past the 100-comment page cap'
    }

    It '#912 s7: normalizes the REST comment updated_at field to an updatedAt property' {
        $mockGhPath = Join-Path $TestDrive 'gh-comments-updatedat.ps1'
        @'
param()
if ($args[0] -eq 'api') {
    Write-Output '[[{"id":1,"html_url":"https://github.com/o/r/issues/9#issuecomment-1","body":"c1","updated_at":"2026-07-26T09:00:00Z","created_at":"2026-07-26T08:00:00Z"}]]'
    exit 0
}
exit 1
'@ | Set-Content $mockGhPath -Encoding UTF8

        $result = Get-GoalRunIssueComments -Issue 9 -Owner 'o' -Repo 'r' -GhCliPath $mockGhPath

        # ConvertFrom-Json auto-parses ISO-8601-looking string values into
        # [datetime] (Kind=Utc); a plain [datetime] string cast instead
        # converts to local Kind. Compare via ToUniversalTime() so the
        # assertion is independent of the runner's local timezone.
        ([datetime]$result[0].updatedAt).ToUniversalTime() | Should -Be (([datetime]'2026-07-26T09:00:00Z').ToUniversalTime())
    }

    It 'resolves owner/repo via gh repo view when -Owner/-Repo are not supplied' {
        $mockGhPath = Join-Path $TestDrive 'gh-comments-resolve-repo.ps1'
        @'
param()
if ($args[0] -eq 'repo') {
    Write-Output 'ambient-owner/ambient-repo'
    exit 0
}
if ($args[0] -eq 'api') {
    if ($args[1] -notmatch 'repos/ambient-owner/ambient-repo/issues/9/comments') { exit 1 }
    Write-Output '[[{"id":5,"html_url":"https://github.com/ambient-owner/ambient-repo/issues/9#issuecomment-5","body":"resolved-repo comment"}]]'
    exit 0
}
exit 1
'@ | Set-Content $mockGhPath -Encoding UTF8

        $result = Get-GoalRunIssueComments -Issue 9 -GhCliPath $mockGhPath

        $result.Count | Should -Be 1
        $result[0].body | Should -Be 'resolved-repo comment'
    }

    It 'fails open to an empty array (never throws) when the paginated gh api call fails' {
        $mockGhPath = Join-Path $TestDrive 'gh-comments-fail.ps1'
        @'
param()
exit 1
'@ | Set-Content $mockGhPath -Encoding UTF8

        $result = Get-GoalRunIssueComments -Issue 9 -Owner 'o' -Repo 'r' -GhCliPath $mockGhPath

        $result.Count | Should -Be 0
    }

    It 'uses an injected -CommentsReader directly for testability, bypassing gh entirely' {
        $reader = {
            param($Issue, $Owner, $Repo, $GhCliPath)
            @([pscustomobject]@{ id = 7; url = 'https://example/7'; body = 'injected' })
        }

        $result = Get-GoalRunIssueComments -Issue 9 -CommentsReader $reader

        $result.Count | Should -Be 1
        $result[0].body | Should -Be 'injected'
    }

    It '#912 review fix (M18): resolves owner/repo from -RepoRoot''s git remote instead of the process CWD when -Owner/-Repo are omitted' {
        $repoPath = script:New-GRSTestRepo -Path (Join-Path $TestDrive 'grs-reporoot-ownerrepo')
        & git -C $repoPath remote add origin 'https://github.com/repo-root-owner/repo-root-repo.git' 2>&1 | Out-Null

        $mockGhPath = Join-Path $TestDrive 'gh-comments-reporoot.ps1'
        @'
param()
if ($args[0] -eq 'repo') {
    # If this is ever hit, -RepoRoot resolution was skipped and the
    # process-cwd fallback ran instead -- the wrong owner/repo for this test.
    Write-Output 'process-cwd-owner/process-cwd-repo'
    exit 0
}
if ($args[0] -eq 'api') {
    if ($args[1] -notmatch 'repos/repo-root-owner/repo-root-repo/issues/9/comments') { exit 1 }
    Write-Output '[[{"id":1,"html_url":"https://github.com/repo-root-owner/repo-root-repo/issues/9#issuecomment-1","body":"from repo root remote"}]]'
    exit 0
}
exit 1
'@ | Set-Content $mockGhPath -Encoding UTF8

        $result = Get-GoalRunIssueComments -Issue 9 -RepoRoot $repoPath -GhCliPath $mockGhPath

        $result.Count | Should -Be 1
        $result[0].body | Should -Be 'from repo root remote'
    }
}

Describe 'Invoke-GoalRunMutexLaunch' -Tag 'unit' {

    It 'aborts before provisioning when the marker post itself fails' {
        Mock -CommandName New-GoalRunInflightMarker -MockWith { [pscustomobject]@{ Success = $false; CommentId = $null; Url = $null; LaunchedAt = $null } }
        Mock -CommandName Get-GoalRunInflightMarkers -MockWith { @() }
        Mock -CommandName New-GoalRunWorktree -MockWith { throw 'New-GoalRunWorktree must not be called on marker-post failure' }

        $result = Invoke-GoalRunMutexLaunch -Issue 874 -RepoRoot 'C:\fake\repo' -ContractHash ('c' * 64) -ReconfirmDelayMs 0

        $result.Outcome | Should -Be 'abort-marker-post-failed'
        Should -Invoke -CommandName New-GoalRunWorktree -Times 0
    }

    It 'yields and never provisions when reconcile finds a lower-id live marker' {
        Mock -CommandName New-GoalRunInflightMarker -MockWith { [pscustomobject]@{ Success = $true; CommentId = 105; Url = 'https://example/105'; LaunchedAt = '2026-07-23T00:00:00.0000000Z' } }
        Mock -CommandName Get-GoalRunInflightMarkers -MockWith {
            @(
                [pscustomobject]@{ CommentId = 100; Status = 'unresolved'; ContractHash = ('c' * 64); LaunchedAt = '2026-07-23T00:00:00.0000000Z'; ResolvedReason = $null },
                [pscustomobject]@{ CommentId = 105; Status = 'unresolved'; ContractHash = ('c' * 64); LaunchedAt = '2026-07-23T00:00:00.0000000Z'; ResolvedReason = $null }
            )
        }
        Mock -CommandName Set-GoalRunInflightMarkerResolved -MockWith { $true }
        Mock -CommandName New-GoalRunWorktree -MockWith { throw 'New-GoalRunWorktree must not be called when yielding' }

        $result = Invoke-GoalRunMutexLaunch -Issue 874 -RepoRoot 'C:\fake\repo' -ContractHash ('c' * 64) -Owner 'Grimblaz' -Repo 'agent-orchestra' -ReconfirmDelayMs 0

        $result.Outcome | Should -Be 'yielded'
        Should -Invoke -CommandName New-GoalRunWorktree -Times 0
        Should -Invoke -CommandName Set-GoalRunInflightMarkerResolved -Times 1
    }

    It 'M12 fix: still attempts to resolve its own marker on yield even when -Owner/-Repo are NOT supplied' {
        Mock -CommandName New-GoalRunInflightMarker -MockWith { [pscustomobject]@{ Success = $true; CommentId = 105; Url = 'https://example/105'; LaunchedAt = '2026-07-23T00:00:00.0000000Z' } }
        Mock -CommandName Get-GoalRunInflightMarkers -MockWith {
            @(
                [pscustomobject]@{ CommentId = 100; Status = 'unresolved'; ContractHash = ('c' * 64); LaunchedAt = '2026-07-23T00:00:00.0000000Z'; ResolvedReason = $null },
                [pscustomobject]@{ CommentId = 105; Status = 'unresolved'; ContractHash = ('c' * 64); LaunchedAt = '2026-07-23T00:00:00.0000000Z'; ResolvedReason = $null }
            )
        }
        Mock -CommandName Set-GoalRunInflightMarkerResolved -MockWith { $true }
        Mock -CommandName New-GoalRunWorktree -MockWith { throw 'New-GoalRunWorktree must not be called when yielding' }

        # Deliberately no -Owner/-Repo -- before the M12 fix, the yield
        # branch only attempted the resolve call when both were supplied.
        $result = Invoke-GoalRunMutexLaunch -Issue 874 -RepoRoot 'C:\fake\repo' -ContractHash ('c' * 64) -ReconfirmDelayMs 0

        $result.Outcome | Should -Be 'yielded'
        Should -Invoke -CommandName Set-GoalRunInflightMarkerResolved -Times 1
    }

    It 'provisions exactly once when reconcile confirms this run is the sole/lowest live marker' {
        Mock -CommandName New-GoalRunInflightMarker -MockWith { [pscustomobject]@{ Success = $true; CommentId = 100; Url = 'https://example/100'; LaunchedAt = '2026-07-23T00:00:00.0000000Z' } }
        Mock -CommandName Get-GoalRunInflightMarkers -MockWith {
            @([pscustomobject]@{ CommentId = 100; Status = 'unresolved'; ContractHash = ('c' * 64); LaunchedAt = '2026-07-23T00:00:00.0000000Z'; ResolvedReason = $null })
        }
        Mock -CommandName New-GoalRunWorktree -MockWith { [pscustomobject]@{ Success = $true; RefusalReason = $null; Path = 'C:\fake\gr-874'; BranchName = 'goal-run/issue-874-token' } }

        $result = Invoke-GoalRunMutexLaunch -Issue 874 -RepoRoot 'C:\fake\repo' -ContractHash ('c' * 64) -ReconfirmDelayMs 0

        $result.Outcome | Should -Be 'launched'
        $result.Worktree.Path | Should -Be 'C:\fake\gr-874'
        Should -Invoke -CommandName New-GoalRunWorktree -Times 1
        # M16 fix: the reconfirm read is a SECOND call into Get-GoalRunInflightMarkers
        # (the first is the original reconcile read) -- one extra read, not a poll loop.
        Should -Invoke -CommandName Get-GoalRunInflightMarkers -Times 2
    }

    It 'surfaces a provisioning failure distinctly from a marker-post failure, and self-resolves its own inflight marker (F2)' {
        Mock -CommandName New-GoalRunInflightMarker -MockWith { [pscustomobject]@{ Success = $true; CommentId = 100; Url = 'https://example/100'; LaunchedAt = '2026-07-23T00:00:00.0000000Z' } }
        Mock -CommandName Get-GoalRunInflightMarkers -MockWith {
            @([pscustomobject]@{ CommentId = 100; Status = 'unresolved'; ContractHash = ('c' * 64); LaunchedAt = '2026-07-23T00:00:00.0000000Z'; ResolvedReason = $null })
        }
        Mock -CommandName New-GoalRunWorktree -MockWith { [pscustomobject]@{ Success = $false; RefusalReason = 'refused: uncommitted-changes'; Path = $null; BranchName = $null } }
        Mock -CommandName Set-GoalRunInflightMarkerResolved -MockWith { $true }

        $result = Invoke-GoalRunMutexLaunch -Issue 874 -RepoRoot 'C:\fake\repo' -ContractHash ('c' * 64) -ReconfirmDelayMs 0

        $result.Outcome | Should -Be 'launch-failed-provisioning'
        # F2 fix: the run must resolve its own just-posted mutex marker before
        # returning, so an immediate retry is not blocked by an orphan marker.
        Should -Invoke -CommandName Set-GoalRunInflightMarkerResolved -Times 1 -ParameterFilter {
            $CommentId -eq 100 -and $ResolvedReason -eq 'launch-failed-provisioning'
        }
    }

    It 'M16 fix: yields on the reconfirm read when a lower-id marker appears only after the first reconcile read' {
        Mock -CommandName New-GoalRunInflightMarker -MockWith { [pscustomobject]@{ Success = $true; CommentId = 100; Url = 'https://example/100'; LaunchedAt = '2026-07-23T00:00:00.0000000Z' } }
        $script:GRMLCallCount = 0
        Mock -CommandName Get-GoalRunInflightMarkers -MockWith {
            $script:GRMLCallCount++
            if ($script:GRMLCallCount -eq 1) {
                # First read: this run appears to be the sole/lowest live marker.
                return @([pscustomobject]@{ CommentId = 100; Status = 'unresolved'; ContractHash = ('c' * 64); LaunchedAt = '2026-07-23T00:00:00.0000000Z'; ResolvedReason = $null })
            }
            # Reconfirm read: a genuinely earlier concurrent marker has now propagated.
            return @(
                [pscustomobject]@{ CommentId = 50; Status = 'unresolved'; ContractHash = ('c' * 64); LaunchedAt = '2026-07-23T00:00:00.0000000Z'; ResolvedReason = $null },
                [pscustomobject]@{ CommentId = 100; Status = 'unresolved'; ContractHash = ('c' * 64); LaunchedAt = '2026-07-23T00:00:00.0000000Z'; ResolvedReason = $null }
            )
        }
        Mock -CommandName Set-GoalRunInflightMarkerResolved -MockWith { $true }
        Mock -CommandName New-GoalRunWorktree -MockWith { throw 'New-GoalRunWorktree must not be called when the reconfirm read flips the outcome to yield' }

        $result = Invoke-GoalRunMutexLaunch -Issue 874 -RepoRoot 'C:\fake\repo' -ContractHash ('c' * 64) -ReconfirmDelayMs 0

        $result.Outcome | Should -Be 'yielded'
        Should -Invoke -CommandName New-GoalRunWorktree -Times 0
        Should -Invoke -CommandName Set-GoalRunInflightMarkerResolved -Times 1
        Should -Invoke -CommandName Get-GoalRunInflightMarkers -Times 2
    }

    It '#912 review fix (M1): yields when reconcile finds a lower-id ADOPTED (not just unresolved) marker -- an adopted marker is a live concurrent run, not an absent one' {
        Mock -CommandName New-GoalRunInflightMarker -MockWith { [pscustomobject]@{ Success = $true; CommentId = 105; Url = 'https://example/105'; LaunchedAt = '2026-07-23T00:00:00.0000000Z' } }
        Mock -CommandName Get-GoalRunInflightMarkers -MockWith {
            @(
                [pscustomobject]@{ CommentId = 100; Status = 'adopted'; ContractHash = ('c' * 64); LaunchedAt = '2026-07-23T00:00:00.0000000Z'; ResolvedReason = $null; AdoptedBySessionId = 'sess-other' },
                [pscustomobject]@{ CommentId = 105; Status = 'unresolved'; ContractHash = ('c' * 64); LaunchedAt = '2026-07-23T00:00:00.0000000Z'; ResolvedReason = $null }
            )
        }
        Mock -CommandName Set-GoalRunInflightMarkerResolved -MockWith { $true }
        Mock -CommandName New-GoalRunWorktree -MockWith { throw 'New-GoalRunWorktree must not be called when a lower-id adopted marker is live' }

        $result = Invoke-GoalRunMutexLaunch -Issue 874 -RepoRoot 'C:\fake\repo' -ContractHash ('c' * 64) -ReconfirmDelayMs 0

        $result.Outcome | Should -Be 'yielded'
        Should -Invoke -CommandName New-GoalRunWorktree -Times 0
    }

    It 'M16 fix: -ReconfirmDelayMs is honored as an actual delay before the reconfirm read (production default path)' {
        Mock -CommandName New-GoalRunInflightMarker -MockWith { [pscustomobject]@{ Success = $true; CommentId = 100; Url = 'https://example/100'; LaunchedAt = '2026-07-23T00:00:00.0000000Z' } }
        Mock -CommandName Get-GoalRunInflightMarkers -MockWith {
            @([pscustomobject]@{ CommentId = 100; Status = 'unresolved'; ContractHash = ('c' * 64); LaunchedAt = '2026-07-23T00:00:00.0000000Z'; ResolvedReason = $null })
        }
        Mock -CommandName New-GoalRunWorktree -MockWith { [pscustomobject]@{ Success = $true; RefusalReason = $null; Path = 'C:\fake\gr-874'; BranchName = 'goal-run/issue-874-token' } }

        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $result = Invoke-GoalRunMutexLaunch -Issue 874 -RepoRoot 'C:\fake\repo' -ContractHash ('c' * 64) -ReconfirmDelayMs 50
        $sw.Stop()

        $result.Outcome | Should -Be 'launched'
        $sw.ElapsedMilliseconds | Should -BeGreaterOrEqual 40
    }
}

Describe 'Test-GoalRunInflightAppearsDead (crash-atomicity)' -Tag 'unit' {

    It 'is not dead when the marker is already resolved' {
        $result = Test-GoalRunInflightAppearsDead -MarkerStatus 'resolved' -LaunchedAt (Get-Date).AddHours(-5) -HaltReportExists $false -PrExists $false -Now (Get-Date)
        $result.AppearsDead | Should -Be $false
        $result.Reason | Should -Be 'marker-already-resolved'
    }

    It '#912 D3/D4: computes elapsed-based staleness even when a halt report exists, but additively flags TerminalOutcomePresent so the caller decides what stale-plus-terminal means' {
        # Plan step 2 deletes the short-circuit-to-not-dead-on-terminal-outcome
        # behavior; AppearsDead becomes purely time-computed and
        # TerminalOutcomePresent becomes a separate additive output that
        # Resolve-GoalRunInvocationAction's new precedence composes with.
        $now = Get-Date
        $result = Test-GoalRunInflightAppearsDead -MarkerStatus 'unresolved' -LaunchedAt $now.AddHours(-10) -HaltReportExists $true -PrExists $false -Now $now -StaleThresholdMinutes 60
        $result.AppearsDead | Should -Be $true -Because 'the short-circuit to AppearsDead=$false on a terminal outcome is deleted by plan step 2'
        $result.TerminalOutcomePresent | Should -Be $true
    }

    It '#912 D3/D4: computes elapsed-based staleness even when a PR already exists, but additively flags TerminalOutcomePresent' {
        $now = Get-Date
        $result = Test-GoalRunInflightAppearsDead -MarkerStatus 'unresolved' -LaunchedAt $now.AddHours(-10) -HaltReportExists $false -PrExists $true -Now $now -StaleThresholdMinutes 60
        $result.AppearsDead | Should -Be $true
        $result.TerminalOutcomePresent | Should -Be $true
    }

    It 'is not dead within the stale threshold using LaunchedAt when no heartbeat exists' {
        $now = Get-Date
        $result = Test-GoalRunInflightAppearsDead -MarkerStatus 'unresolved' -LaunchedAt $now.AddMinutes(-10) -HaltReportExists $false -PrExists $false -Now $now -StaleThresholdMinutes 60
        $result.AppearsDead | Should -Be $false
    }

    It 'appears dead past the stale threshold using LaunchedAt when no heartbeat exists (never provisioned)' {
        $now = Get-Date
        $result = Test-GoalRunInflightAppearsDead -MarkerStatus 'unresolved' -LaunchedAt $now.AddMinutes(-90) -HaltReportExists $false -PrExists $false -Now $now -StaleThresholdMinutes 60
        $result.AppearsDead | Should -Be $true
        $result.Reason | Should -Be 'stale-no-terminal-outcome'
    }

    It 'prefers HeartbeatAt over LaunchedAt when both are present' {
        $now = Get-Date
        # Launched long ago, but heartbeat is recent -- must NOT appear dead.
        $result = Test-GoalRunInflightAppearsDead -MarkerStatus 'unresolved' -LaunchedAt $now.AddHours(-5) -HeartbeatAt $now.AddMinutes(-5) -HaltReportExists $false -PrExists $false -Now $now -StaleThresholdMinutes 60
        $result.AppearsDead | Should -Be $false
        $result.LastSeenAt | Should -Be $now.AddMinutes(-5)
    }

    It '#912 review fix (M1/M2): an ADOPTED marker is NOT short-circuited to not-dead via the "already resolved" reason -- it falls through to the same elapsed-time staleness computation an unresolved marker gets' {
        $now = Get-Date
        $result = Test-GoalRunInflightAppearsDead -MarkerStatus 'adopted' -LaunchedAt $now.AddMinutes(-90) -HaltReportExists $false -PrExists $false -Now $now -StaleThresholdMinutes 60
        $result.AppearsDead | Should -Be $true -Because 'an adopted marker is a live/held status, not a resolved one -- the pre-fix -ne ''unresolved'' filter falsely short-circuited it to AppearsDead=$false'
        $result.Reason | Should -Be 'stale-no-terminal-outcome'
    }

    It '#912 review fix (M1/M2): an ADOPTED marker within the stale threshold correctly reports not dead via elapsed-time computation, not the false marker-already-resolved reason' {
        $now = Get-Date
        $result = Test-GoalRunInflightAppearsDead -MarkerStatus 'adopted' -LaunchedAt $now.AddMinutes(-5) -HaltReportExists $false -PrExists $false -Now $now -StaleThresholdMinutes 60
        $result.AppearsDead | Should -Be $false
        $result.Reason | Should -Be 'within-stale-threshold' -Because 'the pre-fix code reported this as marker-already-resolved, which is FALSE for an adopted marker (it is not resolved -- it is a run in progress under a new session)'
    }

    It 'M6 regression: a UTC Z-suffixed LaunchedAt string cast to [datetime] alongside a genuinely UTC -Now reports near-zero elapsed, not a multi-hour skew' {
        # Casting a 'Z'-suffixed string to [datetime] lands Kind=Local (a
        # correct local-wall-clock conversion of the same instant, but Kind
        # is tagged Local, not Utc). Before the M6 fix, subtracting that
        # directly against a genuinely-Utc -Now skewed the result by the
        # local UTC offset of the machine running this test -- reproduced
        # live as ElapsedMinutes=240 on a UTC-4 machine for a run launched
        # moments earlier.
        $nowUtc = (Get-Date).ToUniversalTime()
        $launchedAtZString = $nowUtc.ToString('yyyy-MM-ddTHH:mm:ssZ')
        $launchedAtCastFromZString = [datetime]$launchedAtZString

        $result = Test-GoalRunInflightAppearsDead -MarkerStatus 'unresolved' -LaunchedAt $launchedAtCastFromZString `
            -HaltReportExists $false -PrExists $false -Now $nowUtc -StaleThresholdMinutes 60

        $result.AppearsDead | Should -Be $false
        # Near-zero, not off by anywhere near a machine UTC-offset worth
        # of minutes (60, 240, etc.) -- allow a couple of minutes of test
        # execution slack only.
        [math]::Abs($result.ElapsedMinutes) | Should -BeLessThan 2
    }
}

Describe 'Resolve-GoalRunInvocationAction' -Tag 'unit' {

    It 'launches a new run when no unresolved marker exists' {
        $result = Resolve-GoalRunInvocationAction -ExistingUnresolvedMarker $null -AppearsDead $false
        $result.Action | Should -Be 'launch-new'
    }

    It 'refuses and offers resume when an unresolved marker exists and does not appear dead' {
        $marker = [pscustomobject]@{ CommentId = 100 }
        $result = Resolve-GoalRunInvocationAction -ExistingUnresolvedMarker $marker -AppearsDead $false
        $result.Action | Should -Be 'refuse-resume-existing'
    }

    It '#912 D2/D3: adopts and resumes when an unresolved marker exists, appears dead, and no terminal outcome is present (sole action, no separate report-only dead-run outcome)' {
        $marker = [pscustomobject]@{ CommentId = 100 }
        $result = Resolve-GoalRunInvocationAction -ExistingUnresolvedMarker $marker -AppearsDead $true
        $result.Action | Should -Be 'adopt-and-resume'
    }

    It '#912 D3/D4: resolves and reports complete when the marker is stale and a terminal outcome (halt report or PR) is present' {
        $marker = [pscustomobject]@{ CommentId = 100 }
        $result = Resolve-GoalRunInvocationAction -ExistingUnresolvedMarker $marker -AppearsDead $true -TerminalOutcomePresent $true
        $result.Action | Should -Be 'resolve-and-report-complete'
    }

    It '#912 D4: TerminalOutcomePresent is load-bearing -- flipping only that input changes the action from adopt-and-resume to resolve-and-report-complete' {
        $marker = [pscustomobject]@{ CommentId = 100 }
        $withoutTerminalOutcome = Resolve-GoalRunInvocationAction -ExistingUnresolvedMarker $marker -AppearsDead $true -TerminalOutcomePresent $false
        $withTerminalOutcome = Resolve-GoalRunInvocationAction -ExistingUnresolvedMarker $marker -AppearsDead $true -TerminalOutcomePresent $true

        $withoutTerminalOutcome.Action | Should -Be 'adopt-and-resume'
        $withTerminalOutcome.Action | Should -Be 'resolve-and-report-complete'
    }

    It '#912 D3: refuses resume when the marker is fresh (not dead) even if a terminal outcome is present -- the live-run protection is never inferred from absent output' {
        $marker = [pscustomobject]@{ CommentId = 100 }
        $result = Resolve-GoalRunInvocationAction -ExistingUnresolvedMarker $marker -AppearsDead $false -TerminalOutcomePresent $true
        $result.Action | Should -Be 'refuse-resume-existing'
    }

    It '#912 AC15: the force-adopt lever adopts and resumes even when the marker would otherwise be refused as live' {
        $marker = [pscustomobject]@{ CommentId = 100 }
        $result = Resolve-GoalRunInvocationAction -ExistingUnresolvedMarker $marker -AppearsDead $false -ForceAdopt $true
        $result.Action | Should -Be 'adopt-and-resume'
    }
}

Describe 'Invoke-GoalRunAwaitStatusVerdict (bounded retry)' -Tag 'unit' {

    It 'returns released immediately when the verdict is present on the first read' {
        $reader = { param($Path) [pscustomobject]@{ State = 'present-met-true'; Event = [pscustomobject]@{ Fields = [pscustomobject]@{ met = $true } } } }
        $result = Invoke-GoalRunAwaitStatusVerdict -TranscriptPath 'fake.jsonl' -MaxRetries 5 -RetryDelayMs 1 -StatusReader $reader
        $result.Outcome | Should -Be 'released'
        $result.Attempts | Should -Be 1
    }

    It 'retries until the verdict appears within the retry window' {
        $script:GRSCallCount = 0
        $reader = {
            param($Path)
            $script:GRSCallCount++
            if ($script:GRSCallCount -lt 3) {
                return [pscustomobject]@{ State = 'status-absent'; Event = $null }
            }
            return [pscustomobject]@{ State = 'present-met-true'; Event = [pscustomobject]@{ Fields = [pscustomobject]@{ met = $true } } }
        }
        $result = Invoke-GoalRunAwaitStatusVerdict -TranscriptPath 'fake.jsonl' -MaxRetries 5 -RetryDelayMs 1 -StatusReader $reader
        $result.Outcome | Should -Be 'released'
        $result.Attempts | Should -Be 3
    }

    It 'reports retry-exhausted when the verdict never appears within the retry window' {
        $reader = { param($Path) [pscustomobject]@{ State = 'status-absent'; Event = $null } }
        $result = Invoke-GoalRunAwaitStatusVerdict -TranscriptPath 'fake.jsonl' -MaxRetries 3 -RetryDelayMs 1 -StatusReader $reader
        $result.Outcome | Should -Be 'retry-exhausted'
        $result.Attempts | Should -Be 3
    }

    It 'M15: threads -LaunchedAt through to the StatusReader as its second positional argument' {
        $script:GRSCapturedLaunchedAt = $null
        $reader = {
            param($Path, $LaunchedAtArg)
            $script:GRSCapturedLaunchedAt = $LaunchedAtArg
            [pscustomobject]@{ State = 'present-met-true'; Event = [pscustomobject]@{ Fields = [pscustomobject]@{ met = $true } } }
        }
        Invoke-GoalRunAwaitStatusVerdict -TranscriptPath 'fake.jsonl' -MaxRetries 1 -RetryDelayMs 1 -LaunchedAt '2026-07-22T09:00:00Z' -StatusReader $reader | Out-Null
        $script:GRSCapturedLaunchedAt | Should -Be '2026-07-22T09:00:00Z'
    }
}

Describe 'Resolve-GoalRunControlReturn (M13: control-return-then-read, distinct diagnostic halt)' -Tag 'unit' {

    It 'returns released and does not attempt a halt emission when the verdict appears in time' {
        Mock -CommandName Invoke-GoalRunHaltEmit -MockWith { throw 'Invoke-GoalRunHaltEmit must not be called on the released path' }
        $reader = { param($Path) [pscustomobject]@{ State = 'present-met-true'; Event = [pscustomobject]@{ Fields = [pscustomobject]@{ met = $true } } } }

        $result = Resolve-GoalRunControlReturn -TranscriptPath 'fake.jsonl' -Issue 874 -RepoRoot $script:RepoRoot -MaxRetries 3 -RetryDelayMs 1 -StatusReader $reader

        $result.Outcome | Should -Be 'released'
        Should -Invoke -CommandName Invoke-GoalRunHaltEmit -Times 0
    }

    It 'emits a distinct diagnostic halt naming the verdict-not-flushed condition on retry exhaustion' {
        Mock -CommandName Invoke-GoalRunHaltEmit -MockWith {
            param($Report, $Issue, $RepoRoot, $Owner, $Repo)
            return [pscustomobject]@{ Success = $true; Url = 'https://example/halt'; Body = 'fake' }
        }
        $reader = { param($Path) [pscustomobject]@{ State = 'status-absent'; Event = $null } }

        $result = Resolve-GoalRunControlReturn -TranscriptPath 'fake.jsonl' -Issue 874 -RepoRoot $script:RepoRoot -MaxRetries 2 -RetryDelayMs 1 -StatusReader $reader

        $result.Outcome | Should -Be 'halted-verdict-not-flushed'
        Should -Invoke -CommandName Invoke-GoalRunHaltEmit -Times 1 -ParameterFilter {
            $Report.halt_reason -eq 'chain-stage-failure' -and
            ($Report.evidence -join '|') -match 'goal_status verdict did not appear in transcript within 2 retries after loop completion'
        }
    }

    It 'validates the halt report built on retry exhaustion against the real halt schema' {
        $capturedReport = $null
        Mock -CommandName Invoke-GoalRunHaltEmit -MockWith {
            param($Report, $Issue, $RepoRoot, $Owner, $Repo)
            $script:CapturedReport = $Report
            return [pscustomobject]@{ Success = $true; Url = 'https://example/halt'; Body = 'fake' }
        }
        $reader = { param($Path) [pscustomobject]@{ State = 'status-absent'; Event = $null } }

        Resolve-GoalRunControlReturn -TranscriptPath 'fake.jsonl' -Issue 874 -RepoRoot $script:RepoRoot -MaxRetries 1 -RetryDelayMs 1 -StatusReader $reader | Out-Null

        $validation = Test-GoalRunHaltReport -Report $script:CapturedReport -RepoRoot $script:RepoRoot
        $validation.IsValid | Should -Be $true -Because ($validation.Violations -join '; ')
    }

    It '#912 AC13: does NOT overwrite an existing goal-halt-report comment that postdates this run''s -LaunchedAt (a different, newer run''s report)' {
        Mock -CommandName Invoke-GoalRunHaltEmit -MockWith { throw 'Invoke-GoalRunHaltEmit must not be called when a newer report already exists' }
        Mock -CommandName Get-GoalRunIssueComments -MockWith {
            @([pscustomobject]@{ id = 1; url = 'https://example/1'; body = '<!-- goal-halt-report-874 -->recent report'; updatedAt = '2026-07-26T12:00:00Z' })
        }
        $reader = { param($Path) [pscustomobject]@{ State = 'status-absent'; Event = $null } }

        $result = Resolve-GoalRunControlReturn -TranscriptPath 'fake.jsonl' -Issue 874 -RepoRoot $script:RepoRoot -MaxRetries 1 -RetryDelayMs 1 -StatusReader $reader -LaunchedAt '2026-07-26T10:00:00Z'

        $result.Outcome | Should -Be 'halted-verdict-not-flushed'
        $result.HaltResult.Suppressed | Should -Be $true
        $result.HaltResult.Success | Should -Be $false -Because 'nothing was posted, so Success must not falsely claim it was'
        Should -Invoke -CommandName Invoke-GoalRunHaltEmit -Times 0
    }

    It '#912 AC13: DOES overwrite an existing goal-halt-report comment that predates this run''s -LaunchedAt (a stale report)' {
        Mock -CommandName Invoke-GoalRunHaltEmit -MockWith {
            param($Report, $Issue, $RepoRoot, $Owner, $Repo)
            return [pscustomobject]@{ Success = $true; Url = 'https://example/halt'; Body = 'fake' }
        }
        Mock -CommandName Get-GoalRunIssueComments -MockWith {
            @([pscustomobject]@{ id = 1; url = 'https://example/1'; body = '<!-- goal-halt-report-874 -->stale report'; updatedAt = '2026-07-26T08:00:00Z' })
        }
        $reader = { param($Path) [pscustomobject]@{ State = 'status-absent'; Event = $null } }

        $result = Resolve-GoalRunControlReturn -TranscriptPath 'fake.jsonl' -Issue 874 -RepoRoot $script:RepoRoot -MaxRetries 1 -RetryDelayMs 1 -StatusReader $reader -LaunchedAt '2026-07-26T10:00:00Z'

        $result.Outcome | Should -Be 'halted-verdict-not-flushed'
        $result.HaltResult.Success | Should -Be $true
        Should -Invoke -CommandName Invoke-GoalRunHaltEmit -Times 1
    }

    It '#912 AC13: proceeds with the emit when no existing goal-halt-report comment matches, even with -LaunchedAt supplied' {
        Mock -CommandName Invoke-GoalRunHaltEmit -MockWith {
            param($Report, $Issue, $RepoRoot, $Owner, $Repo)
            return [pscustomobject]@{ Success = $true; Url = 'https://example/halt'; Body = 'fake' }
        }
        Mock -CommandName Get-GoalRunIssueComments -MockWith { @() }
        $reader = { param($Path) [pscustomobject]@{ State = 'status-absent'; Event = $null } }

        $result = Resolve-GoalRunControlReturn -TranscriptPath 'fake.jsonl' -Issue 874 -RepoRoot $script:RepoRoot -MaxRetries 1 -RetryDelayMs 1 -StatusReader $reader -LaunchedAt '2026-07-26T10:00:00Z'

        $result.Outcome | Should -Be 'halted-verdict-not-flushed'
        Should -Invoke -CommandName Invoke-GoalRunHaltEmit -Times 1
    }

    It '#912 review fix (M3): normalizes DateTime.Kind before comparing -LaunchedAt against an existing report''s updatedAt, so the recency verdict is correct regardless of the host machine''s local UTC offset' {
        Mock -CommandName Invoke-GoalRunHaltEmit -MockWith { throw 'Invoke-GoalRunHaltEmit must not be called when a newer report already exists' }

        # A Z-suffixed -LaunchedAt string (exactly how it always arrives in
        # production) and an ALREADY-Kind=Utc updatedAt (exactly how
        # Get-GoalRunIssueComments/ConvertFrom-Json already produces it),
        # anchored to real UTC instants 30 REAL minutes apart. Before the M3
        # fix, casting the Z-suffixed string via a bare [datetime] converts
        # it to LOCAL wall-clock time (tagged Kind=Local) while updatedAt
        # stays genuinely Utc -- comparing the two Ticks values directly
        # (DateTime comparison ignores Kind) skews the verdict by the host's
        # UTC offset, the exact bug shape the M6 fix above already documents
        # and fixes for Test-GoalRunInflightAppearsDead.
        $launchedAtUtc = [datetime]::SpecifyKind([datetime]'2026-07-26T10:00:00', [System.DateTimeKind]::Utc)
        $launchedAtZString = $launchedAtUtc.ToString('yyyy-MM-ddTHH:mm:ssZ')
        $existingReportUpdatedAtUtc = [datetime]::SpecifyKind([datetime]'2026-07-26T10:30:00', [System.DateTimeKind]::Utc)

        Mock -CommandName Get-GoalRunIssueComments -MockWith {
            @([pscustomobject]@{ id = 1; url = 'https://example/1'; body = '<!-- goal-halt-report-874 -->newer report'; updatedAt = $existingReportUpdatedAtUtc })
        }
        $reader = { param($Path) [pscustomobject]@{ State = 'status-absent'; Event = $null } }

        $result = Resolve-GoalRunControlReturn -TranscriptPath 'fake.jsonl' -Issue 874 -RepoRoot $script:RepoRoot -MaxRetries 1 -RetryDelayMs 1 -StatusReader $reader -LaunchedAt $launchedAtZString

        $result.HaltResult.Suppressed | Should -Be $true -Because 'the existing report genuinely postdates this run''s launch by 30 real minutes -- this must hold regardless of host UTC offset'
        Should -Invoke -CommandName Invoke-GoalRunHaltEmit -Times 0
    }

    It '#912 review fix (M18): the recency guard threads -RepoRoot and the injectable -CommentsReader through to Get-GoalRunIssueComments instead of the fetch always resolving from the process CWD' {
        Mock -CommandName Invoke-GoalRunHaltEmit -MockWith { throw 'Invoke-GoalRunHaltEmit must not be called when a newer report already exists' }
        $script:grcrReaderInvoked = $false
        $injectedReader = {
            param($Issue, $Owner, $Repo, $GhCliPath)
            $script:grcrReaderInvoked = $true
            @([pscustomobject]@{ id = 1; url = 'https://example/1'; body = '<!-- goal-halt-report-874 -->newer report'; updatedAt = '2026-07-26T12:00:00Z' })
        }
        $reader = { param($Path) [pscustomobject]@{ State = 'status-absent'; Event = $null } }

        $result = Resolve-GoalRunControlReturn -TranscriptPath 'fake.jsonl' -Issue 874 -RepoRoot $script:RepoRoot -MaxRetries 1 -RetryDelayMs 1 -StatusReader $reader -LaunchedAt '2026-07-26T10:00:00Z' -CommentsReader $injectedReader

        $script:grcrReaderInvoked | Should -Be $true
        $result.HaltResult.Suppressed | Should -Be $true
    }
}

Describe 'Invoke-GoalRunLaunchChain and Test-GoalRunTerminalEmissionsVerified (seams)' -Tag 'unit' {

    It 'Invoke-GoalRunLaunchChain reports not launched, naming step 6 as the owner' {
        $handle = New-GoalRunExecutorSessionHandle -SessionId 'sess-1' -TranscriptPath 'fake.jsonl'
        $result = Invoke-GoalRunLaunchChain -Issue 874 -RepoRoot $script:RepoRoot -ContractHash ('d' * 64) -WorktreePath 'C:\fake\gr-874' -ExecutorSessionHandle $handle
        $result.Launched | Should -Be $false
        $result.Reason | Should -Be 'not-implemented-pending-step6'
    }

    It 'Test-GoalRunTerminalEmissionsVerified always reports not-verified in this PR' {
        $result = Test-GoalRunTerminalEmissionsVerified -Issue 874 -RepoRoot $script:RepoRoot
        $result.Verified | Should -Be $false
    }

    It 'New-GoalRunExecutorSessionHandle carries the expected shape' {
        $handle = New-GoalRunExecutorSessionHandle -SessionId 'sess-1' -TranscriptPath 'fake.jsonl' -Arm 'in-session'
        $handle.SessionId | Should -Be 'sess-1'
        $handle.TranscriptPath | Should -Be 'fake.jsonl'
        $handle.Arm | Should -Be 'in-session'
    }
}

Describe 'Goal-run restart report body round-trip (#912 D6, step 5)' -Tag 'unit' {

    It 'builds and parses a restart report body symmetrically' {
        $body = New-GoalRunRestartReportBody -Issue 912 -WorktreePath 'C:\fake\gr-912-abc' -BranchName 'goal-run/issue-912-abc' -ClearedAt '2026-07-26T00:00:00.0000000Z'
        $parsed = ConvertFrom-GoalRunRestartReportBody -Body $body
        $parsed.Parsed | Should -Be $true
        $parsed.Issue | Should -Be 912
        $parsed.WorktreePath | Should -Be 'C:\fake\gr-912-abc'
        $parsed.BranchName | Should -Be 'goal-run/issue-912-abc'
        $parsed.ClearedAt | Should -Be '2026-07-26T00:00:00.0000000Z'
    }

    It 'reports Parsed = $false for a body with no restart-report marker' {
        $parsed = ConvertFrom-GoalRunRestartReportBody -Body 'not a restart report at all'
        $parsed.Parsed | Should -Be $false
    }

    It 'renders "unknown" for BranchName when the live branch resolution failed, never a blank field' {
        $body = New-GoalRunRestartReportBody -Issue 912 -WorktreePath 'C:\fake\gr-912-abc' -ClearedAt '2026-07-26T00:00:00.0000000Z'
        $body | Should -Match '\*\*branch_name\*\*:\s*unknown'
        $parsed = ConvertFrom-GoalRunRestartReportBody -Body $body
        $parsed.BranchName | Should -Be 'unknown'
    }
}

Describe 'Clear-GoalRunStageMarker (#912 D6, step 5: the first comment-DELETE primitive)' -Tag 'unit' {

    BeforeEach {
        $script:cgsmDeletedPaths = [System.Collections.Generic.List[string]]::new()
        $script:cgsmExitCode = 0
        function global:gh {
            param([Parameter(ValueFromRemainingArguments = $true)]$Args)
            $joined = $Args -join ' '
            if ($joined -match '^api -X DELETE (\S+)$') {
                $script:cgsmDeletedPaths.Add($Matches[1])
                $global:LASTEXITCODE = $script:cgsmExitCode
                return ''
            }
            $global:LASTEXITCODE = 0
            return ''
        }
    }

    AfterEach {
        Remove-Item Function:gh -ErrorAction SilentlyContinue
    }

    It 'deletes the single live stage-marker comment via gh api -X DELETE' {
        $body = New-GoalRunStageMarkerBody -Issue 912 -Stage 'loop-launched' -ContractHash ('a' * 64) -UpdatedAt '2026-07-26T00:00:00.0000000Z'
        Mock -CommandName Get-GoalRunIssueComments -MockWith {
            @([pscustomobject]@{ id = 555; url = 'https://github.com/o/r/issues/912#issuecomment-555'; body = $body })
        }

        $result = Clear-GoalRunStageMarker -Issue 912 -Owner 'o' -Repo 'r'

        $result.Success | Should -Be $true
        $result.DeletedCommentIds | Should -Be @(555)
        $script:cgsmDeletedPaths | Should -Contain 'repos/o/r/issues/comments/555'
    }

    It 'reports success with zero deletions when no stage marker comment exists' {
        Mock -CommandName Get-GoalRunIssueComments -MockWith { @() }

        $result = Clear-GoalRunStageMarker -Issue 912 -Owner 'o' -Repo 'r'

        $result.Success | Should -Be $true
        $result.DeletedCommentIds | Should -BeNullOrEmpty
        $script:cgsmDeletedPaths | Should -BeNullOrEmpty
    }

    It 'reports failure and lists the failed comment id when the gh api DELETE call fails, without throwing' {
        $body = New-GoalRunStageMarkerBody -Issue 912 -Stage 'loop-launched' -ContractHash ('a' * 64) -UpdatedAt '2026-07-26T00:00:00.0000000Z'
        Mock -CommandName Get-GoalRunIssueComments -MockWith {
            @([pscustomobject]@{ id = 555; url = 'https://github.com/o/r/issues/912#issuecomment-555'; body = $body })
        }
        $script:cgsmExitCode = 1

        $result = Clear-GoalRunStageMarker -Issue 912 -Owner 'o' -Repo 'r'

        $result.Success | Should -Be $false
        $result.FailedCommentIds | Should -Be @(555)
    }

    It 'falls back to the {owner}/{repo} gh api placeholder template when -Owner/-Repo are omitted' {
        $body = New-GoalRunStageMarkerBody -Issue 912 -Stage 'loop-launched' -ContractHash ('a' * 64) -UpdatedAt '2026-07-26T00:00:00.0000000Z'
        Mock -CommandName Get-GoalRunIssueComments -MockWith {
            @([pscustomobject]@{ id = 555; url = 'https://github.com/o/r/issues/912#issuecomment-555'; body = $body })
        }

        Clear-GoalRunStageMarker -Issue 912 | Out-Null

        $script:cgsmDeletedPaths | Should -Contain 'repos/{owner}/{repo}/issues/comments/555'
    }

    It '#912 review fix (M8): refuses (deletes NOTHING) when 2+ comments carry the marker, mirroring Get-GCPinnedCommentBody''s refuse-on-ambiguity precedent -- the pre-fix code hard-DELETEd every match with no ambiguity refusal at all' {
        $bodyA = New-GoalRunStageMarkerBody -Issue 912 -Stage 'loop-launched' -ContractHash ('a' * 64) -UpdatedAt '2026-07-26T00:00:00.0000000Z'
        $bodyB = New-GoalRunStageMarkerBody -Issue 912 -Stage 'loop-released' -ContractHash ('a' * 64) -UpdatedAt '2026-07-26T01:00:00.0000000Z'
        Mock -CommandName Get-GoalRunIssueComments -MockWith {
            @(
                [pscustomobject]@{ id = 555; url = 'https://github.com/o/r/issues/912#issuecomment-555'; body = $bodyA },
                [pscustomobject]@{ id = 556; url = 'https://github.com/o/r/issues/912#issuecomment-556'; body = $bodyB }
            )
        }

        $result = Clear-GoalRunStageMarker -Issue 912 -Owner 'o' -Repo 'r'

        $result.Success | Should -Be $false
        $result.Reason | Should -Be 'marker-ambiguous'
        $result.DeletedCommentIds | Should -BeNullOrEmpty
        $script:cgsmDeletedPaths | Should -BeNullOrEmpty -Because 'an ambiguous match set must refuse to guess, never delete any candidate'
    }
}

Describe 'Clear-GoalRunActiveState (#912 D6, step 5)' -Tag 'unit' {

    It 'deletes goal-run-active.json when it exists' {
        $worktreePath = Join-Path $TestDrive 'cgas-exists'
        New-Item -ItemType Directory -Path $worktreePath -Force | Out-Null
        New-GoalRunActiveState -WorktreePath $worktreePath -Ceilings @{} -Baseline @{} -Arm 'in-session' -ExecutorSessionId 'sess-1' -ContractHash ('a' * 64) | Out-Null

        $result = Clear-GoalRunActiveState -WorktreePath $worktreePath

        $result | Should -Be $true
        (Test-Path -LiteralPath (Join-Path $worktreePath 'goal-run-active.json')) | Should -Be $false
    }

    It 'reports $true (nothing to do) when the file never existed, without throwing' {
        $worktreePath = Join-Path $TestDrive 'cgas-absent'
        New-Item -ItemType Directory -Path $worktreePath -Force | Out-Null

        { Clear-GoalRunActiveState -WorktreePath $worktreePath } | Should -Not -Throw
        Clear-GoalRunActiveState -WorktreePath $worktreePath | Should -Be $true
    }
}

Describe 'Invoke-GoalRunRestart (#912 D6, step 5: operator-initiated restart lever, capture-then-clear)' -Tag 'unit' {

    BeforeEach {
        $script:grrOrder = [System.Collections.Generic.List[string]]::new()
        $script:grrCapturedReportBody = $null
    }

    It 'refuses when the heartbeat is fresh, and never posts a report or clears anything (live-run protection)' {
        Mock -CommandName New-GoalRunIssueComment -MockWith { throw 'must not post a report when refusing' }
        Mock -CommandName Clear-GoalRunStageMarker -MockWith { throw 'must not clear the stage marker when refusing' }
        Mock -CommandName Clear-GoalRunActiveState -MockWith { throw 'must not clear active state when refusing' }

        $now = (Get-Date).ToUniversalTime()
        $result = Invoke-GoalRunRestart -Issue 912 -WorktreePath 'C:\fake\gr-912' -LaunchedAt $now.AddHours(-3) -HeartbeatAt $now.AddMinutes(-5) -Now $now

        $result.Outcome | Should -Be 'refused-live-run'
        $result.ClearedStageMarker | Should -Be $false
        $result.ClearedActiveState | Should -Be $false
    }

    It 'proceeds to capture-then-clear when the heartbeat is past the stale threshold' {
        Mock -CommandName New-GoalRunIssueComment -MockWith { [pscustomobject]@{ Success = $true; CommentId = 1; Url = 'https://example/1' } }
        Mock -CommandName Clear-GoalRunStageMarker -MockWith { [pscustomobject]@{ Success = $true; DeletedCommentIds = @(); FailedCommentIds = @() } }
        Mock -CommandName Clear-GoalRunActiveState -MockWith { $true }

        $now = (Get-Date).ToUniversalTime()
        $result = Invoke-GoalRunRestart -Issue 912 -WorktreePath 'C:\fake\gr-912' -LaunchedAt $now.AddHours(-2) -Now $now

        $result.Outcome | Should -Be 'restarted'
    }

    It 'proceeds to capture-then-clear when -LaunchedAt is omitted -- no active-state evidence means nothing to refuse against' {
        Mock -CommandName New-GoalRunIssueComment -MockWith { [pscustomobject]@{ Success = $true; CommentId = 1; Url = 'https://example/1' } }
        Mock -CommandName Clear-GoalRunStageMarker -MockWith { [pscustomobject]@{ Success = $true; DeletedCommentIds = @(); FailedCommentIds = @() } }
        Mock -CommandName Clear-GoalRunActiveState -MockWith { $true }

        $result = Invoke-GoalRunRestart -Issue 912 -WorktreePath 'C:\fake\gr-912'

        $result.Outcome | Should -Not -Be 'refused-live-run'
    }

    It '#912 review fix (M6/M17): fails CLOSED with a distinct refusal when -LaunchedAt is NON-NULL but unparseable garbage (the active-state file exists but could not be read/parsed), rather than the pre-fix bare [datetime] cast throwing OR silently falling through to fail-open' {
        Mock -CommandName New-GoalRunIssueComment -MockWith { throw 'must not post a report when refusing on unparseable state' }
        Mock -CommandName Clear-GoalRunStageMarker -MockWith { throw 'must not clear the stage marker when refusing on unparseable state' }
        Mock -CommandName Clear-GoalRunActiveState -MockWith { throw 'must not clear active state when refusing on unparseable state' }

        $threw = $false
        $result = $null
        try {
            $result = Invoke-GoalRunRestart -Issue 912 -WorktreePath 'C:\fake\gr-912' -LaunchedAt 'TBD'
        }
        catch {
            $threw = $true
        }

        $threw | Should -Be $false -Because 'a garbage LaunchedAt must produce a typed refusal, not an unguarded [datetime] cast throw'
        $result.Outcome | Should -Be 'refused-unparseable-state'
        $result.Reason | Should -Be 'launched-at-unparseable'
        $result.ClearedStageMarker | Should -Be $false
        $result.ClearedActiveState | Should -Be $false
    }

    It '#912 review fix (M18): reports BranchNameResolved = $false and a null BranchName on a detached-HEAD worktree instead of recording the literal string "HEAD" as if it were a real branch name' {
        $repoRoot = Join-Path $TestDrive 'grr-detached-repo'
        script:New-GRSTestRepo -Path $repoRoot
        $worktreePath = Join-Path $TestDrive 'grr-detached-worktree'
        $headSha = (& git -C $repoRoot rev-parse HEAD).Trim()
        & git -C $repoRoot worktree add --detach $worktreePath $headSha 2>&1 | Out-Null

        try {
            Mock -CommandName New-GoalRunIssueComment -MockWith { [pscustomobject]@{ Success = $true; CommentId = 1; Url = 'https://example/1' } }
            Mock -CommandName Clear-GoalRunStageMarker -MockWith { [pscustomobject]@{ Success = $true; DeletedCommentIds = @(); FailedCommentIds = @() } }
            Mock -CommandName Clear-GoalRunActiveState -MockWith { $true }

            $now = (Get-Date).ToUniversalTime()
            $result = Invoke-GoalRunRestart -Issue 912 -WorktreePath $worktreePath -LaunchedAt $now.AddHours(-2) -Now $now

            $result.Outcome | Should -Be 'restarted'
            $result.BranchNameResolved | Should -Be $false
            $result.BranchName | Should -BeNullOrEmpty
        }
        finally {
            script:Remove-GRSTestWorktree -RepoRoot $repoRoot -WorktreePath $worktreePath
        }
    }

    It '#912 review fix (M18): reports BranchNameResolved = $true for a normal (non-detached) branch checkout' {
        $repoRoot = Join-Path $TestDrive 'grr-normal-repo'
        script:New-GRSTestRepo -Path $repoRoot
        $worktreePath = Join-Path $TestDrive 'grr-normal-worktree'
        & git -C $repoRoot worktree add -b 'goal-run/issue-912-normaltoken' $worktreePath 2>&1 | Out-Null

        try {
            Mock -CommandName New-GoalRunIssueComment -MockWith { [pscustomobject]@{ Success = $true; CommentId = 1; Url = 'https://example/1' } }
            Mock -CommandName Clear-GoalRunStageMarker -MockWith { [pscustomobject]@{ Success = $true; DeletedCommentIds = @(); FailedCommentIds = @() } }
            Mock -CommandName Clear-GoalRunActiveState -MockWith { $true }

            $now = (Get-Date).ToUniversalTime()
            $result = Invoke-GoalRunRestart -Issue 912 -WorktreePath $worktreePath -LaunchedAt $now.AddHours(-2) -Now $now

            $result.BranchNameResolved | Should -Be $true
            $result.BranchName | Should -Be 'goal-run/issue-912-normaltoken'
        }
        finally {
            script:Remove-GRSTestWorktree -RepoRoot $repoRoot -WorktreePath $worktreePath
        }
    }

    It '#912 review fix (M18): reports the honest partial-failure outcome, not unconditionally "restarted", when Clear-GoalRunStageMarker itself reports failure' {
        Mock -CommandName New-GoalRunIssueComment -MockWith { [pscustomobject]@{ Success = $true; CommentId = 1; Url = 'https://example/1' } }
        Mock -CommandName Clear-GoalRunStageMarker -MockWith { [pscustomobject]@{ Success = $false; DeletedCommentIds = @(); FailedCommentIds = @(555) } }
        Mock -CommandName Clear-GoalRunActiveState -MockWith { $true }

        $now = (Get-Date).ToUniversalTime()
        $result = Invoke-GoalRunRestart -Issue 912 -WorktreePath 'C:\fake\gr-912' -LaunchedAt $now.AddHours(-2) -Now $now

        $result.Outcome | Should -Be 'restarted-partial-marker-clear-failed'
        $result.Reason | Should -Be 'stage-marker-clear-failed'
        $result.ClearedStageMarker | Should -Be $false
    }

    It '#912 fixture (a): captures the worktree path and branch into the durable report comment BEFORE clearing either artifact' {
        $repoRoot = Join-Path $TestDrive 'grr-repo'
        script:New-GRSTestRepo -Path $repoRoot
        $worktreePath = Join-Path $TestDrive 'grr-worktree'
        $branchName = 'goal-run/issue-912-fixturetoken'
        & git -C $repoRoot worktree add -b $branchName $worktreePath 2>&1 | Out-Null

        try {
            Mock -CommandName New-GoalRunIssueComment -MockWith {
                param($Issue, $Body, $Owner, $Repo)
                $script:grrOrder.Add('report')
                $script:grrCapturedReportBody = $Body
                return [pscustomobject]@{ Success = $true; CommentId = 999; Url = 'https://example/999' }
            }
            Mock -CommandName Clear-GoalRunStageMarker -MockWith {
                $script:grrOrder.Add('clear-marker')
                return [pscustomobject]@{ Success = $true; DeletedCommentIds = @(555); FailedCommentIds = @() }
            }
            Mock -CommandName Clear-GoalRunActiveState -MockWith {
                $script:grrOrder.Add('clear-active')
                return $true
            }

            $now = (Get-Date).ToUniversalTime()
            $result = Invoke-GoalRunRestart -Issue 912 -WorktreePath $worktreePath -LaunchedAt $now.AddHours(-2) -Now $now

            $result.Outcome | Should -Be 'restarted'
            $result.BranchName | Should -Be $branchName
            $script:grrCapturedReportBody | Should -Match ([regex]::Escape($branchName))
            $script:grrCapturedReportBody | Should -Match ([regex]::Escape($worktreePath))
            $script:grrOrder[0] | Should -Be 'report'
            $script:grrOrder | Should -Contain 'clear-marker'
            $script:grrOrder | Should -Contain 'clear-active'
            $script:grrOrder.IndexOf('report') | Should -BeLessThan $script:grrOrder.IndexOf('clear-marker')
            $script:grrOrder.IndexOf('report') | Should -BeLessThan $script:grrOrder.IndexOf('clear-active')
        }
        finally {
            script:Remove-GRSTestWorktree -RepoRoot $repoRoot -WorktreePath $worktreePath
        }
    }

    It 'reports report-post-failed and clears nothing when the durable report comment itself fails to post' {
        Mock -CommandName New-GoalRunIssueComment -MockWith { [pscustomobject]@{ Success = $false; CommentId = $null; Url = $null } }
        Mock -CommandName Clear-GoalRunStageMarker -MockWith { throw 'must not clear the stage marker when the report failed to post' }
        Mock -CommandName Clear-GoalRunActiveState -MockWith { throw 'must not clear active state when the report failed to post' }

        $now = (Get-Date).ToUniversalTime()
        $result = Invoke-GoalRunRestart -Issue 912 -WorktreePath 'C:\fake\gr-912' -LaunchedAt $now.AddHours(-2) -Now $now

        $result.Outcome | Should -Be 'report-post-failed'
        $result.ClearedStageMarker | Should -Be $false
        $result.ClearedActiveState | Should -Be $false
    }

    It '#912 fixture (b)+(c): restart is refused on a fresh heartbeat, and once stale, clears both artifacts so the next invocation resolves pre-loop' {
        $tempRoot = Join-Path $TestDrive 'grr-fixture-worktree'
        New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
        $staleTimestamp = (Get-Date).ToUniversalTime().AddHours(-2).ToString('o')
        $stateJson = @{
            ceilings            = @{}
            baseline            = @{}
            arm                 = 'in-session'
            executor_session_id = 'sess-1'
            contract_hash       = ('a' * 64)
            launched_at         = $staleTimestamp
            heartbeat_at        = $staleTimestamp
            teardown_deferred   = $false
        } | ConvertTo-Json -Depth 10
        Set-Content -LiteralPath (Join-Path $tempRoot 'goal-run-active.json') -Value $stateJson -Encoding utf8 -NoNewline

        $script:grrFixtureStageComments = @(
            [pscustomobject]@{
                id   = 555
                url  = 'https://github.com/o/r/issues/912#issuecomment-555'
                body = (New-GoalRunStageMarkerBody -Issue 912 -Stage 'loop-launched' -ContractHash ('a' * 64) -UpdatedAt $staleTimestamp -WorktreePath $tempRoot)
            }
        )
        Mock -CommandName Get-GoalRunIssueComments -MockWith { $script:grrFixtureStageComments }
        Mock -CommandName New-GoalRunIssueComment -MockWith { [pscustomobject]@{ Success = $true; CommentId = 999; Url = 'https://example/999' } }

        $stageMarkerBefore = Get-GoalRunStageMarker -Issue 912
        $activeStateBefore = Get-GoalRunActiveState -WorktreePath $tempRoot

        # (b) fresh heartbeat is refused.
        $refused = Invoke-GoalRunRestart -Issue 912 -WorktreePath $stageMarkerBefore.WorktreePath -LaunchedAt $activeStateBefore.launched_at -HeartbeatAt (Get-Date).ToUniversalTime().AddMinutes(-1)
        $refused.Outcome | Should -Be 'refused-live-run'
        (Test-Path -LiteralPath (Join-Path $tempRoot 'goal-run-active.json')) | Should -Be $true -Because 'a refused restart clears nothing'

        # Now genuinely stale -- clears both durable artifacts. The stage
        # marker "delete" is simulated by emptying the mocked comment list,
        # mirroring what a real `gh api -X DELETE` would leave observable.
        $script:grrFixtureStageComments = @()
        $restarted = Invoke-GoalRunRestart -Issue 912 -WorktreePath $stageMarkerBefore.WorktreePath -LaunchedAt $activeStateBefore.launched_at -HeartbeatAt $activeStateBefore.heartbeat_at
        $restarted.Outcome | Should -Be 'restarted'

        (Test-Path -LiteralPath (Join-Path $tempRoot 'goal-run-active.json')) | Should -Be $false

        # (c) the next invocation's durable-artifact reads resolve pre-loop.
        $stageMarkerAfter = Get-GoalRunStageMarker -Issue 912
        $stageMarkerAfter.Found | Should -Be $false
        $activeStatePresentAfter = Test-Path -LiteralPath (Join-Path $tempRoot 'goal-run-active.json')

        $resume = Resolve-GoalRunResumeStage -ContractHashVerified $true -InflightMarkerPresent $false `
            -ActiveStatePresent $activeStatePresentAfter -RunLogHasCheckpoint $false -ExplicitStageMarker $stageMarkerAfter.Stage
        $resume.ResumeStage | Should -Be 'pre-loop'
        $resume.Reason | Should -Be 'fresh-launch'
    }
}
