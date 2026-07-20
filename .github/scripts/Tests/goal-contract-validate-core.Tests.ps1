#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
.SYNOPSIS
    RED tests for .github/scripts/lib/goal-contract-validate-core.ps1
    (issue #873, frame-slice s1).

.DESCRIPTION
    Contract under test (per the plan-issue-873 s1 requirement contract):

      Get-GCPinnedCommentBody -Issue <int> -Marker <string> [-Repo <string>]
                               [-GhCliPath <string>]
        Callable, marker-pinned, paginated, byte-safe reader. Fetches ALL
        comments for an issue via `gh api repos/{owner}/{repo}/issues/{n}/
        comments --paginate`, filters to the comment(s) whose body literally
        contains -Marker, and returns that comment's .body -- never console-
        rendered output (872-D3 byte-source rule). Never routes through
        find-or-upsert-comment.ps1's Find-OrUpsertComment, whose read
        prologue is embedded inside a write/upsert function. Zero matches or
        2+ matches both fail closed to $null (ambiguous is not "pick one").

      Resolve-GCVerdictDisposition [-IsRefused] [-RefusalReasons <string[]>]
                                    [-HasFailure] [-HasReviewRequired]
                                    [-ReviewReason <string>] [-Targets <object[]>]
        Pure precedence-lattice resolver: refused (pre-run) > fail >
        pass-review-required > pass. Exit codes 2/1/3/0 respectively.
        Directly unit-tested for co-occurring signals since s1 cannot yet
        drive every combination through Invoke-GoalContractValidate (no
        target/suite checks exist until s3/s4).

      Invoke-GoalContractValidate -Issue <int> -RepoRoot <string>
                                   [-Marker <string>] [-Repo <string>]
                                   [-GhCliPath <string>]
        Public entry point. Runs the plan-issue-pinned read, then reuses
        #872's Get-GCContractBlock -> ConvertFrom-GCContractBlock ->
        Test-GCContractHash intake gates (goal-contract-core.ps1), refuses
        the 64-zero placeholder BEFORE the real hash comparison, maps the
        loud missing-powershell-yaml throw to a distinct infra-error
        pass-review-required disposition (never exit-1 fail), and folds
        every Get-GCContractBlock $null cause into one fail-closed
        contract-block-unresolvable refusal (the lib cannot distinguish
        absent/ambiguous/truncated, so honesty requires naming all three).
        s1 stops after intake: no worktree/target/suite/diff-integrity
        checks exist yet (s2-s6), so Targets stays empty and an
        all-gates-passed run returns a provisional 'pass'.

    These tests are RED until goal-contract-validate-core.ps1 lands in this
    same frame-slice s1; every failure here must be because the lib file (or
    one of its exported functions) is absent, not a syntax error in this
    test file. Each behavioral It therefore guards on function existence via
    script:Assert-GCVFunctionExists before invoking anything.

    Frame-slice s4 adds:

      Test-GCSuiteGatePass -Result <object>
        Pure green-floor gate predicate (the U1 CRITICAL fix): ExitCode==0
        AND TotalFailed==0 AND (Passed+Failed)>0 -- NEVER TotalFailed alone.
        Tested directly against hand-constructed mock result objects
        (green, one-real-red, and all three false-GREEN shapes:
        TestsPath-not-found, zero-discovered, MinTestCount-floor).

      Invoke-GCSuitePhase -WorktreePath <string> [-TimeoutSeconds <int>]
                           [-MinTestCount <int>] [-PwshCliPath <string>]
        Runs the suite via a child pwsh process that dot-sources the
        WORKTREE'S OWN pester-sharded-core.ps1 copy with an EXPLICIT
        -TestsPath, tree-killed on a wall-clock timeout. Tested against a
        stub Invoke-PesterSharded planted inside a fake worktree directory
        (never the real 200+ file suite) to keep these tests fast while
        still exercising the real child-process + tree-kill mechanics.
#>

Describe 'goal-contract-validate-core.ps1' -Tag 'unit' {

    BeforeAll {
        $script:RepoRoot    = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
        $script:LibFile     = Join-Path $script:RepoRoot '.github/scripts/lib/goal-contract-validate-core.ps1'
        $script:ParserFile  = Join-Path $script:RepoRoot '.github/scripts/lib/goal-contract-core.ps1'

        if (Test-Path -LiteralPath $script:ParserFile) {
            . $script:ParserFile
        }
        if (Test-Path -LiteralPath $script:LibFile) {
            . $script:LibFile
        }

        function script:Assert-GCVFunctionExists {
            param([Parameter(Mandatory)][string]$Name)
            (Get-Command -Name $Name -ErrorAction SilentlyContinue) | Should -Not -BeNullOrEmpty -Because "goal-contract-validate-core.ps1 must define $Name before this behavior can be verified"
        }

        $script:PlaceholderHash = '0' * 64

        # A schema-valid contract body (mirrors the fixture in
        # goal-contract-core.Tests.ps1's "round-trips a well-formed contract"
        # case) parameterized by contract_hash so tests can swap in the
        # placeholder, a real matching digest, or a mismatched digest.
        function script:New-WellFormedContractPayload {
            param([Parameter(Mandatory)][string]$ContractHash)
            @"
schema_version: 1
issue: 873
contract_hash: "$ContractHash"
targets:
  - id: T1
    ac_ref: AC1
    category: structure-presence
    check: "pwsh -NoProfile -File .github/scripts/example-check.ps1"
    expected: "exit 0; example check passes"
    falsifier: "A vacuous pass would look like an accumulator silently resetting null to zero."
    source: null
invariants:
  - full-pester-suite-no-new-failures
  - test-diff-integrity
evidence_obligations:
  checkpoint_commits: per-target-green
  run_log: deviation entries + experience observations per checkpoint
  experience_obligations:
    - scenario: S2
      surface: cli
  required_markers: [pipeline-metrics-credits, goal-run-class]
general_experience_standard: |
  Canonical clause and four guardrails, verbatim from #848 D8.
halt_conditions: [unachievable-target, invariant-conflict, budget-exhausted, gate-input-needed, chain-stage-failure]
budget:
  tokens: 100000
  wall_clock: "4h"
  chain_sub_ceiling: 2
  non_convergence: halt-report
"@
        }

        function script:New-CommentJson {
            param([Parameter(Mandatory)][string]$Body, [int]$Id = 1)
            (@{ id = $Id; body = $Body } | ConvertTo-Json -Depth 10 -Compress)
        }

        function script:New-MockGh {
            param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$CommentsJsonArray, [int]$ExitCode = 0)
            $escaped = $CommentsJsonArray -replace "'", "''"
            @"
param()
`$args -join ' ' | Out-File -FilePath '$($Path).args' -Encoding UTF8 -Append
Write-Output '$escaped'
exit $ExitCode
"@ | Set-Content -LiteralPath $Path -Encoding UTF8
        }

        # --- s2 fixtures: real temp git repos (never the invoking repo) ---
        # Self-configures LOCAL (non-global) git identity on each fixture
        # repo, mirroring newcomer-audit-wrapper.Tests.ps1's real-git-e2e
        # fixture (:262-263) -- no GIT_CONFIG_GLOBAL, no Get-RealGitFiles
        # registration, so this file can stay in the parallel shard; local
        # `git config` never touches the operator's global/system identity.
        function script:New-GCTestRepo {
            param([Parameter(Mandatory)][string]$Path)
            New-Item -ItemType Directory -Path $Path -Force | Out-Null
            & git -C $Path init -q -b main . 2>&1 | Out-Null
            & git -C $Path config user.email 'goal-validate-s2@example.com' 2>&1 | Out-Null
            & git -C $Path config user.name 'goal-validate-s2' 2>&1 | Out-Null
            $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
            [System.IO.File]::WriteAllText((Join-Path $Path 'seed.txt'), "seed`n", $utf8NoBom)
            & git -C $Path add -A 2>&1 | Out-Null
            & git -C $Path commit -q -m 'seed' 2>&1 | Out-Null
            return $Path
        }

        # A smart forwarding mock: passes every git invocation through to the
        # REAL git binary except `worktree remove`, which fails for the first
        # $FailCount calls (persistent-failure test uses a $FailCount that
        # exceeds Remove-GCDisposableWorktree's one retry; retry-then-succeed
        # tests use $FailCount = 1). This exercises the orphan-record and
        # retry paths WITHOUT ever holding a real OS-level file lock.
        function script:New-MockGitTeardownFailure {
            param(
                [Parameter(Mandatory)][string]$Path,
                [Parameter(Mandatory)][string]$CounterFile,
                [Parameter(Mandatory)][int]$FailCount
            )
            @"
param()
`$argsJoined = `$args -join ' '
if (`$argsJoined -match 'worktree remove') {
    `$count = 0
    if (Test-Path -LiteralPath '$CounterFile') { `$count = [int](Get-Content -LiteralPath '$CounterFile' -Raw) }
    `$count++
    Set-Content -LiteralPath '$CounterFile' -Value `$count -NoNewline
    if (`$count -le $FailCount) {
        exit 1
    }
}
& git @args
exit `$LASTEXITCODE
"@ | Set-Content -LiteralPath $Path -Encoding UTF8
        }

        # Manual cleanup for worktrees this file creates outside TestDrive
        # (Pester only auto-cleans TestDrive itself). Best-effort: a leaked
        # worktree from a persistent-teardown-failure test is EXPECTED and
        # cleaned here rather than by the function under test.
        function script:Remove-GCTestWorktree {
            param([Parameter(Mandatory)][string]$RepoRoot, [Parameter(Mandatory)][string]$WorktreePath)
            & git -C $RepoRoot worktree remove --force $WorktreePath 2>&1 | Out-Null
            & git -C $RepoRoot worktree prune 2>&1 | Out-Null
            if (Test-Path -LiteralPath $WorktreePath) {
                Remove-Item -LiteralPath $WorktreePath -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        # --- s5 fixtures: writes a file (creating parent dirs), commits, and
        # returns the resulting sha -- built on the same real-temp-git-repo
        # pattern as the s2 fixtures above (never the invoking repo).
        function script:Write-GCFile {
            param([Parameter(Mandatory)][string]$RepoPath, [Parameter(Mandatory)][string]$RelativePath, [Parameter(Mandatory = $false)][string]$Content = '')
            $fullPath = Join-Path $RepoPath $RelativePath
            $dir = Split-Path -Parent $fullPath
            if ($dir -and -not (Test-Path -LiteralPath $dir)) {
                New-Item -ItemType Directory -Path $dir -Force | Out-Null
            }
            [System.IO.File]::WriteAllText($fullPath, $Content, [System.Text.UTF8Encoding]::new($false))
        }

        function script:New-GCCommit {
            param([Parameter(Mandatory)][string]$RepoPath, [Parameter(Mandatory = $false)][string]$Message = 'commit')
            & git -C $RepoPath add -A 2>&1 | Out-Null
            & git -C $RepoPath commit -q -m $Message 2>&1 | Out-Null
            return (& git -C $RepoPath rev-parse HEAD).Trim()
        }

        function script:Remove-GCFile {
            param([Parameter(Mandatory)][string]$RepoPath, [Parameter(Mandatory)][string]$RelativePath)
            Remove-Item -LiteralPath (Join-Path $RepoPath $RelativePath) -Force -ErrorAction SilentlyContinue
        }

        # A smart forwarding mock: passes every git invocation through to the
        # REAL git binary, but records (never blocks -- recording is enough
        # to prove the no-fetch invariant) whenever `fetch` appears as an
        # argument, so a test can assert the marker file was never written.
        function script:New-MockGitNoFetch {
            param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$MarkerFile)
            $markerEscaped = $MarkerFile -replace "'", "''"
            @"
param()
`$argsJoined = `$args -join ' '
if (`$argsJoined -match '(^| )fetch( |`$)') {
    Set-Content -LiteralPath '$markerEscaped' -Value 'FETCH-CALLED' -NoNewline
}
& git @args
exit `$LASTEXITCODE
"@ | Set-Content -LiteralPath $Path -Encoding UTF8
        }
    }

    Context 'Get-GCPinnedCommentBody -- marker-pinned, paginated, byte-safe read' {

        It 'returns the body of the single comment carrying the marker' {
            script:Assert-GCVFunctionExists -Name 'Get-GCPinnedCommentBody'
            $mockGhPath = Join-Path $TestDrive 'gh-single-match.ps1'
            $commentsJson = "[$(script:New-CommentJson -Body 'no marker here' -Id 1),$(script:New-CommentJson -Body "<!-- plan-issue-873 -->`ncontract body" -Id 2)]"
            script:New-MockGh -Path $mockGhPath -CommentsJsonArray $commentsJson

            $result = Get-GCPinnedCommentBody -Issue 873 -Marker '<!-- plan-issue-873 -->' -Repo 'example-owner/example-repo' -GhCliPath $mockGhPath

            $result | Should -Be "<!-- plan-issue-873 -->`ncontract body"
        }

        It 'is marker-pinned, not position/latest-pinned: a later decoy comment without the marker is never selected' {
            script:Assert-GCVFunctionExists -Name 'Get-GCPinnedCommentBody'
            $mockGhPath = Join-Path $TestDrive 'gh-decoy.ps1'
            # Comment 1 (earlier) carries the real marker + the approved block.
            # Comment 2 (LATER) has no marker at all but embeds its own
            # goal-contract-shaped block -- a "latest block wins" reader would
            # incorrectly select comment 2's block instead of comment 1's.
            $correctBody = "<!-- plan-issue-873 -->`n<!-- goal-contract`nschema_version: 1`nissue: 873`n-->"
            $decoyBody = "just discussing a draft, no marker here`n<!-- goal-contract`nschema_version: 1`nissue: 999`n-->"
            $commentsJson = "[$(script:New-CommentJson -Body $correctBody -Id 100),$(script:New-CommentJson -Body $decoyBody -Id 200)]"
            script:New-MockGh -Path $mockGhPath -CommentsJsonArray $commentsJson

            $result = Get-GCPinnedCommentBody -Issue 873 -Marker '<!-- plan-issue-873 -->' -Repo 'example-owner/example-repo' -GhCliPath $mockGhPath

            $result | Should -Be $correctBody
            $result | Should -Not -Match 'issue: 999' -Because 'the later decoy comment (no marker) must never be selected over the marker-designated comment'
        }

        It 'fails closed (returns $null) when no comment carries the marker' {
            script:Assert-GCVFunctionExists -Name 'Get-GCPinnedCommentBody'
            $mockGhPath = Join-Path $TestDrive 'gh-no-match.ps1'
            $commentsJson = "[$(script:New-CommentJson -Body 'unrelated comment' -Id 1)]"
            script:New-MockGh -Path $mockGhPath -CommentsJsonArray $commentsJson

            $result = Get-GCPinnedCommentBody -Issue 873 -Marker '<!-- plan-issue-873 -->' -Repo 'example-owner/example-repo' -GhCliPath $mockGhPath -WarningAction SilentlyContinue

            $result | Should -BeNullOrEmpty
        }

        It 'fails closed (returns $null) when two comments carry the marker (ambiguous)' {
            script:Assert-GCVFunctionExists -Name 'Get-GCPinnedCommentBody'
            $mockGhPath = Join-Path $TestDrive 'gh-ambiguous.ps1'
            $commentsJson = "[$(script:New-CommentJson -Body "<!-- plan-issue-873 --> first" -Id 1),$(script:New-CommentJson -Body "<!-- plan-issue-873 --> second" -Id 2)]"
            script:New-MockGh -Path $mockGhPath -CommentsJsonArray $commentsJson

            $result = Get-GCPinnedCommentBody -Issue 873 -Marker '<!-- plan-issue-873 -->' -Repo 'example-owner/example-repo' -GhCliPath $mockGhPath -WarningAction SilentlyContinue

            $result | Should -BeNullOrEmpty
        }

        It 'reads via a paginated gh api call (never gh issue view, which caps at 100 comments)' {
            script:Assert-GCVFunctionExists -Name 'Get-GCPinnedCommentBody'
            $mockGhPath = Join-Path $TestDrive 'gh-paginate-args.ps1'
            $commentsJson = "[$(script:New-CommentJson -Body "<!-- plan-issue-873 --> body" -Id 1)]"
            script:New-MockGh -Path $mockGhPath -CommentsJsonArray $commentsJson

            $null = Get-GCPinnedCommentBody -Issue 873 -Marker '<!-- plan-issue-873 -->' -Repo 'example-owner/example-repo' -GhCliPath $mockGhPath

            $capturedArgs = Get-Content "$mockGhPath.args" -Raw
            $capturedArgs | Should -Match 'repos/example-owner/example-repo/issues/873/comments'
            $capturedArgs | Should -Match '--paginate'
        }

        It 'fails closed (returns $null) when gh api exits non-zero' {
            script:Assert-GCVFunctionExists -Name 'Get-GCPinnedCommentBody'
            $mockGhPath = Join-Path $TestDrive 'gh-failure.ps1'
            script:New-MockGh -Path $mockGhPath -CommentsJsonArray '[]' -ExitCode 1

            $result = Get-GCPinnedCommentBody -Issue 873 -Marker '<!-- plan-issue-873 -->' -Repo 'example-owner/example-repo' -GhCliPath $mockGhPath -WarningAction SilentlyContinue

            $result | Should -BeNullOrEmpty
        }
    }

    Context 'Resolve-GCVerdictDisposition -- exit-code precedence lattice' {

        It 'refused takes precedence over every other signal (pre-run gate)' {
            script:Assert-GCVFunctionExists -Name 'Resolve-GCVerdictDisposition'
            $verdict = Resolve-GCVerdictDisposition -IsRefused -RefusalReasons @('refused: contract-not-approved') -HasFailure -HasReviewRequired -ReviewReason 'infra-error: simulated'
            $verdict.Verdict | Should -Be 'refused'
            $verdict.ExitCode | Should -Be 2
            $verdict.Refusals | Should -Be @('refused: contract-not-approved')
        }

        It 'fail takes precedence over pass-review-required when not refused (co-occurring signals)' {
            script:Assert-GCVFunctionExists -Name 'Resolve-GCVerdictDisposition'
            $verdict = Resolve-GCVerdictDisposition -HasFailure -HasReviewRequired -ReviewReason 'infra-error: simulated'
            $verdict.Verdict | Should -Be 'fail'
            $verdict.ExitCode | Should -Be 1
        }

        It 'pass-review-required fires only when neither refused nor failed' {
            script:Assert-GCVFunctionExists -Name 'Resolve-GCVerdictDisposition'
            $verdict = Resolve-GCVerdictDisposition -HasReviewRequired -ReviewReason 'infra-error: simulated'
            $verdict.Verdict | Should -Be 'pass-review-required'
            $verdict.ExitCode | Should -Be 3
            $verdict.Reason | Should -Be 'infra-error: simulated'
        }

        It 'pass is the floor when no signal fires' {
            script:Assert-GCVFunctionExists -Name 'Resolve-GCVerdictDisposition'
            $verdict = Resolve-GCVerdictDisposition
            $verdict.Verdict | Should -Be 'pass'
            $verdict.ExitCode | Should -Be 0
            $verdict.Refusals | Should -BeNullOrEmpty
            $verdict.Reason | Should -BeNullOrEmpty
        }

        It 'always returns a Targets array (empty by default, passthrough when supplied)' {
            script:Assert-GCVFunctionExists -Name 'Resolve-GCVerdictDisposition'
            $default = Resolve-GCVerdictDisposition
            @($default.Targets).Count | Should -Be 0

            $withTargets = Resolve-GCVerdictDisposition -Targets @(@{ id = 'T1' })
            @($withTargets.Targets).Count | Should -Be 1
        }
    }

    Context 'Invoke-GoalContractValidate -- intake gates end-to-end' {

        It 'refuses contract-comment-unresolvable when no comment carries the plan-issue marker' {
            script:Assert-GCVFunctionExists -Name 'Invoke-GoalContractValidate'
            $mockGhPath = Join-Path $TestDrive 'gh-no-comment.ps1'
            $commentsJson = "[$(script:New-CommentJson -Body 'unrelated' -Id 1)]"
            script:New-MockGh -Path $mockGhPath -CommentsJsonArray $commentsJson

            $verdict = Invoke-GoalContractValidate -Issue 873 -RepoRoot $script:RepoRoot -Repo 'example-owner/example-repo' -GhCliPath $mockGhPath -WarningAction SilentlyContinue

            $verdict.Verdict | Should -Be 'refused'
            $verdict.ExitCode | Should -Be 2
            ($verdict.Refusals -join ' ') | Should -Match 'contract-comment-unresolvable'
        }

        It 'is marker-pinned end-to-end: a later decoy comment is never selected over the plan-issue-marked comment' {
            script:Assert-GCVFunctionExists -Name 'Invoke-GoalContractValidate'
            $mockGhPath = Join-Path $TestDrive 'gh-e2e-decoy.ps1'
            $correctPayload = script:New-WellFormedContractPayload -ContractHash $script:PlaceholderHash
            $correctBody = "<!-- plan-issue-873 -->`n<!-- goal-contract`n$correctPayload`n-->"
            $decoyBody = "no marker, just prose`n<!-- goal-contract`nschema_version: 1`nissue: 999`n-->"
            $commentsJson = "[$(script:New-CommentJson -Body $correctBody -Id 1),$(script:New-CommentJson -Body $decoyBody -Id 2)]"
            script:New-MockGh -Path $mockGhPath -CommentsJsonArray $commentsJson

            $verdict = Invoke-GoalContractValidate -Issue 873 -RepoRoot $script:RepoRoot -Repo 'example-owner/example-repo' -GhCliPath $mockGhPath -WarningAction SilentlyContinue

            # The decoy's issue: 999 must never be reached; the correct comment's
            # placeholder hash must be what drives the disposition.
            $verdict.Verdict | Should -Be 'refused'
            ($verdict.Refusals -join ' ') | Should -Match 'contract-not-approved'
        }

        It 'refuses contract-block-unresolvable when the pinned comment has no goal-contract block' {
            script:Assert-GCVFunctionExists -Name 'Invoke-GoalContractValidate'
            $mockGhPath = Join-Path $TestDrive 'gh-no-block.ps1'
            $commentsJson = "[$(script:New-CommentJson -Body '<!-- plan-issue-873 -->' -Id 1)]"
            script:New-MockGh -Path $mockGhPath -CommentsJsonArray $commentsJson

            $verdict = Invoke-GoalContractValidate -Issue 873 -RepoRoot $script:RepoRoot -Repo 'example-owner/example-repo' -GhCliPath $mockGhPath -WarningAction SilentlyContinue

            $verdict.Verdict | Should -Be 'refused'
            $verdict.ExitCode | Should -Be 2
            ($verdict.Refusals -join ' ') | Should -Match 'contract-block-unresolvable \(absent, ambiguous, or truncated'
        }

        It 'refuses contract-block-unresolvable when the pinned comment has two head markers (ambiguous arity)' {
            script:Assert-GCVFunctionExists -Name 'Invoke-GoalContractValidate'
            $mockGhPath = Join-Path $TestDrive 'gh-ambiguous-block.ps1'
            $body = "<!-- plan-issue-873 -->`n<!-- goal-contract`nschema_version: 1`n-->`n<!-- goal-contract`nschema_version: 1`n-->"
            $commentsJson = "[$(script:New-CommentJson -Body $body -Id 1)]"
            script:New-MockGh -Path $mockGhPath -CommentsJsonArray $commentsJson

            $verdict = Invoke-GoalContractValidate -Issue 873 -RepoRoot $script:RepoRoot -Repo 'example-owner/example-repo' -GhCliPath $mockGhPath -WarningAction SilentlyContinue

            $verdict.Verdict | Should -Be 'refused'
            ($verdict.Refusals -join ' ') | Should -Match 'contract-block-unresolvable'
        }

        It 'refuses contract-block-unresolvable when the head marker has no terminator (truncated)' {
            script:Assert-GCVFunctionExists -Name 'Invoke-GoalContractValidate'
            $mockGhPath = Join-Path $TestDrive 'gh-truncated-block.ps1'
            $body = "<!-- plan-issue-873 -->`n<!-- goal-contract`nschema_version: 1`nissue: 873"
            $commentsJson = "[$(script:New-CommentJson -Body $body -Id 1)]"
            script:New-MockGh -Path $mockGhPath -CommentsJsonArray $commentsJson

            $verdict = Invoke-GoalContractValidate -Issue 873 -RepoRoot $script:RepoRoot -Repo 'example-owner/example-repo' -GhCliPath $mockGhPath -WarningAction SilentlyContinue

            $verdict.Verdict | Should -Be 'refused'
            ($verdict.Refusals -join ' ') | Should -Match 'contract-block-unresolvable'
        }

        It 'refuses with the generic schema-violation content when schema_version is unknown (no invented taxonomy)' {
            script:Assert-GCVFunctionExists -Name 'Invoke-GoalContractValidate'
            $mockGhPath = Join-Path $TestDrive 'gh-bad-version.ps1'
            $body = "<!-- plan-issue-873 -->`n<!-- goal-contract`nschema_version: 99`nissue: 873`n-->"
            $commentsJson = "[$(script:New-CommentJson -Body $body -Id 1)]"
            script:New-MockGh -Path $mockGhPath -CommentsJsonArray $commentsJson

            $verdict = Invoke-GoalContractValidate -Issue 873 -RepoRoot $script:RepoRoot -Repo 'example-owner/example-repo' -GhCliPath $mockGhPath -WarningAction SilentlyContinue

            $verdict.Verdict | Should -Be 'refused'
            $verdict.ExitCode | Should -Be 2
            ($verdict.Refusals -join ' ') | Should -Match 'contract-schema-violation'
        }

        It 'refuses contract-not-approved for the 64-zero placeholder hash BEFORE running the real hash comparison' {
            script:Assert-GCVFunctionExists -Name 'Invoke-GoalContractValidate'
            $mockGhPath = Join-Path $TestDrive 'gh-placeholder.ps1'
            $payload = script:New-WellFormedContractPayload -ContractHash $script:PlaceholderHash
            $body = "<!-- plan-issue-873 -->`n<!-- goal-contract`n$payload`n-->"
            $commentsJson = "[$(script:New-CommentJson -Body $body -Id 1)]"
            script:New-MockGh -Path $mockGhPath -CommentsJsonArray $commentsJson

            $verdict = Invoke-GoalContractValidate -Issue 873 -RepoRoot $script:RepoRoot -Repo 'example-owner/example-repo' -GhCliPath $mockGhPath -WarningAction SilentlyContinue

            $verdict.Verdict | Should -Be 'refused'
            $verdict.ExitCode | Should -Be 2
            ($verdict.Refusals -join ' ') | Should -Match 'contract-not-approved' -Because 'the placeholder gate must fire before Test-GCContractHash ever runs, so the message must never be contract-hash-mismatch'
            ($verdict.Refusals -join ' ') | Should -Not -Match 'contract-hash-mismatch'
        }

        It 'refuses contract-hash-mismatch when contract_hash is set but does not match the canonicalized payload digest' {
            script:Assert-GCVFunctionExists -Name 'Invoke-GoalContractValidate'
            $mockGhPath = Join-Path $TestDrive 'gh-mismatch.ps1'
            $wrongHash = ('a' * 63) + 'b'
            $payload = script:New-WellFormedContractPayload -ContractHash $wrongHash
            $body = "<!-- plan-issue-873 -->`n<!-- goal-contract`n$payload`n-->"
            $commentsJson = "[$(script:New-CommentJson -Body $body -Id 1)]"
            script:New-MockGh -Path $mockGhPath -CommentsJsonArray $commentsJson

            $verdict = Invoke-GoalContractValidate -Issue 873 -RepoRoot $script:RepoRoot -Repo 'example-owner/example-repo' -GhCliPath $mockGhPath -WarningAction SilentlyContinue

            $verdict.Verdict | Should -Be 'refused'
            $verdict.ExitCode | Should -Be 2
            ($verdict.Refusals -join ' ') | Should -Match 'contract-hash-mismatch'
        }

        It 'passes intake when the contract_hash matches the canonicalized payload digest (s1 provisional pass; no target/suite checks yet)' {
            script:Assert-GCVFunctionExists -Name 'Invoke-GoalContractValidate'
            script:Assert-GCVFunctionExists -Name 'Get-GCContractHash'
            $mockGhPath = Join-Path $TestDrive 'gh-real-hash.ps1'

            # Two-pass construction: hash the payload with the placeholder in
            # place (Get-GCContractHash elides the contract_hash line itself,
            # so the digest is identical either way), then substitute the
            # real digest in.
            $draftPayload = script:New-WellFormedContractPayload -ContractHash $script:PlaceholderHash
            $realHash = Get-GCContractHash -Payload $draftPayload
            $approvedPayload = script:New-WellFormedContractPayload -ContractHash $realHash
            $body = "<!-- plan-issue-873 -->`n<!-- goal-contract`n$approvedPayload`n-->"
            $commentsJson = "[$(script:New-CommentJson -Body $body -Id 1)]"
            script:New-MockGh -Path $mockGhPath -CommentsJsonArray $commentsJson

            $verdict = Invoke-GoalContractValidate -Issue 873 -RepoRoot $script:RepoRoot -Repo 'example-owner/example-repo' -GhCliPath $mockGhPath -WarningAction SilentlyContinue

            $verdict.Verdict | Should -Be 'pass'
            $verdict.ExitCode | Should -Be 0
            $verdict.Refusals | Should -BeNullOrEmpty
            @($verdict.Targets).Count | Should -Be 0
        }

        It 'maps the missing-powershell-yaml infra throw to a distinct pass-review-required disposition, never exit-1 fail' {
            script:Assert-GCVFunctionExists -Name 'Invoke-GoalContractValidate'
            $mockGhPath = Join-Path $TestDrive 'gh-infra-error.ps1'
            $body = "<!-- plan-issue-873 -->`n<!-- goal-contract`nschema_version: 1`nissue: 873`n-->"
            $commentsJson = "[$(script:New-CommentJson -Body $body -Id 1)]"
            script:New-MockGh -Path $mockGhPath -CommentsJsonArray $commentsJson

            Mock Import-Module { }
            Mock Import-Module -ParameterFilter { $Name -eq 'powershell-yaml' } -MockWith { throw 'simulated: powershell-yaml module not found' }

            $verdict = Invoke-GoalContractValidate -Issue 873 -RepoRoot $script:RepoRoot -Repo 'example-owner/example-repo' -GhCliPath $mockGhPath -WarningAction SilentlyContinue

            Should -Invoke Import-Module -ParameterFilter { $Name -eq 'powershell-yaml' } -Times 1

            $verdict.Verdict | Should -Be 'pass-review-required'
            $verdict.ExitCode | Should -Be 3
            $verdict.Reason | Should -Match 'infra-error' -Because 'the infra/harness-error disposition must carry a distinct Reason tag from a future target-level review-required disposition'
            $verdict.Verdict | Should -Not -Be 'fail' -Because 'an environment defect (missing module) must never be reported as the run failing'
        }
    }

    Context 'Test-GCTreeClean -- cleanliness assertion primitive (s2, AC1)' {

        It 'reports IsClean = $true for a freshly committed repo with no changes' {
            script:Assert-GCVFunctionExists -Name 'Test-GCTreeClean'
            $repo = script:New-GCTestRepo -Path (Join-Path $TestDrive 'clean-repo')

            $result = Test-GCTreeClean -Path $repo

            $result.IsClean | Should -Be $true
            @($result.Porcelain).Count | Should -Be 0
        }

        It 'reports IsClean = $false when a tracked file is modified without committing' {
            script:Assert-GCVFunctionExists -Name 'Test-GCTreeClean'
            $repo = script:New-GCTestRepo -Path (Join-Path $TestDrive 'dirty-repo')
            [System.IO.File]::WriteAllText((Join-Path $repo 'seed.txt'), "modified`n", [System.Text.UTF8Encoding]::new($false))

            $result = Test-GCTreeClean -Path $repo

            $result.IsClean | Should -Be $false
            @($result.Porcelain).Count | Should -BeGreaterThan 0
        }

        It 'reports IsClean = $false for an untracked file (porcelain default includes untracked)' {
            script:Assert-GCVFunctionExists -Name 'Test-GCTreeClean'
            $repo = script:New-GCTestRepo -Path (Join-Path $TestDrive 'untracked-repo')
            [System.IO.File]::WriteAllText((Join-Path $repo 'new-file.txt'), "new`n", [System.Text.UTF8Encoding]::new($false))

            $result = Test-GCTreeClean -Path $repo

            $result.IsClean | Should -Be $false
        }
    }

    Context 'New-GCDisposableWorktree -- detached creation (s2, AC1/AC2)' {

        It 'refuses uncommitted-changes BEFORE creating any worktree when the invoking tree is dirty' {
            script:Assert-GCVFunctionExists -Name 'New-GCDisposableWorktree'
            $repo = script:New-GCTestRepo -Path (Join-Path $TestDrive 'refuse-dirty-repo')
            [System.IO.File]::WriteAllText((Join-Path $repo 'seed.txt'), "modified`n", [System.Text.UTF8Encoding]::new($false))

            $result = New-GCDisposableWorktree -RepoRoot $repo -WarningAction SilentlyContinue

            $result.Success | Should -Be $false
            $result.RefusalReason | Should -Be 'refused: uncommitted-changes'
            $result.Path | Should -BeNullOrEmpty

            $worktreeList = & git -C $repo worktree list
            @($worktreeList).Count | Should -Be 1 -Because 'no worktree may be created when the invoking tree is dirty'
        }

        It 'creates a DETACHED worktree at a unique path outside the repo tree, pinned to the resolved HEAD sha' {
            script:Assert-GCVFunctionExists -Name 'New-GCDisposableWorktree'
            $repo = script:New-GCTestRepo -Path (Join-Path $TestDrive 'create-repo')
            $expectedSha = (& git -C $repo rev-parse HEAD).Trim()

            $result = New-GCDisposableWorktree -RepoRoot $repo

            try {
                $result.Success | Should -Be $true
                $result.RefusalReason | Should -BeNullOrEmpty
                $result.HeadSha | Should -Be $expectedSha
                $result.Path | Should -Not -BeNullOrEmpty
                $result.Path.StartsWith($repo) | Should -Be $false -Because 'the worktree path must live outside the repo tree'
                (Test-Path -LiteralPath $result.Path -PathType Container) | Should -Be $true

                # Detached: a checked-out branch has a symbolic HEAD ref; a
                # detached checkout does not (git exits non-zero on
                # `symbolic-ref -q HEAD` for a detached HEAD).
                & git -C $result.Path symbolic-ref -q HEAD 2>&1 | Out-Null
                $LASTEXITCODE | Should -Not -Be 0 -Because 'worktree add --detach must never produce a branch checkout'

                $actualWorktreeSha = (& git -C $result.Path rev-parse HEAD).Trim()
                $actualWorktreeSha | Should -Be $expectedSha
            } finally {
                script:Remove-GCTestWorktree -RepoRoot $repo -WorktreePath $result.Path
            }
        }

        It 'generates a unique path on every call -- collision is structurally impossible' {
            script:Assert-GCVFunctionExists -Name 'New-GCDisposableWorktree'
            $repo = script:New-GCTestRepo -Path (Join-Path $TestDrive 'unique-repo')

            $first = New-GCDisposableWorktree -RepoRoot $repo
            try {
                $second = New-GCDisposableWorktree -RepoRoot $repo
                try {
                    $first.Success | Should -Be $true
                    $second.Success | Should -Be $true
                    $first.Path | Should -Not -Be $second.Path
                    $first.Path | Should -Match 'goal-validate-[0-9a-f]{32}$'
                    $second.Path | Should -Match 'goal-validate-[0-9a-f]{32}$'
                } finally {
                    script:Remove-GCTestWorktree -RepoRoot $repo -WorktreePath $second.Path
                }
            } finally {
                script:Remove-GCTestWorktree -RepoRoot $repo -WorktreePath $first.Path
            }
        }
    }

    Context 'Remove-GCDisposableWorktree -- force-remove + prune + bounded retry + orphan record (s2, AC1)' {

        It 'removes a real worktree cleanly on the first attempt' {
            script:Assert-GCVFunctionExists -Name 'Remove-GCDisposableWorktree'
            $repo = script:New-GCTestRepo -Path (Join-Path $TestDrive 'remove-clean-repo')
            $created = New-GCDisposableWorktree -RepoRoot $repo

            $result = Remove-GCDisposableWorktree -RepoRoot $repo -WorktreePath $created.Path

            $result.Removed | Should -Be $true
            $result.OrphanedPath | Should -BeNullOrEmpty
            (Test-Path -LiteralPath $created.Path) | Should -Be $false
            $worktreeList = & git -C $repo worktree list
            @($worktreeList).Count | Should -Be 1 -Because 'only the main worktree should remain after a clean removal'
        }

        It 'retries once after a failed first removal attempt, then succeeds (never throws)' {
            script:Assert-GCVFunctionExists -Name 'Remove-GCDisposableWorktree'
            $repo = script:New-GCTestRepo -Path (Join-Path $TestDrive 'remove-retry-repo')
            $created = New-GCDisposableWorktree -RepoRoot $repo
            $mockGitPath = Join-Path $TestDrive 'mock-git-retry-succeeds.ps1'
            $counterFile = Join-Path $TestDrive 'mock-git-retry-succeeds.counter'
            # FailCount = 1: the first removal attempt fails, the one bounded
            # retry succeeds.
            script:New-MockGitTeardownFailure -Path $mockGitPath -CounterFile $counterFile -FailCount 1

            # Called directly (not wrapped in { } | Should -Not -Throw): an
            # uncaught exception here fails the It block on its own, and a
            # direct call lets $result cross back out of this scope, which a
            # scriptblock invocation would not guarantee.
            try {
                $result = Remove-GCDisposableWorktree -RepoRoot $repo -WorktreePath $created.Path -GitCliPath $mockGitPath -RetryDelayMs 10 -WarningAction SilentlyContinue
            } finally {
                script:Remove-GCTestWorktree -RepoRoot $repo -WorktreePath $created.Path
            }

            $result.Removed | Should -Be $true -Because 'the one bounded retry must succeed since the mock only fails the first attempt'
            $result.OrphanedPath | Should -BeNullOrEmpty
            $counterValue = [int](Get-Content -LiteralPath $counterFile -Raw)
            $counterValue | Should -Be 2 -Because 'exactly two removal attempts (the original + one retry) must occur'
        }

        It 'never throws and records the orphaned path on persistent removal failure' {
            script:Assert-GCVFunctionExists -Name 'Remove-GCDisposableWorktree'
            $repo = script:New-GCTestRepo -Path (Join-Path $TestDrive 'remove-persistent-fail-repo')
            $created = New-GCDisposableWorktree -RepoRoot $repo
            $mockGitPath = Join-Path $TestDrive 'mock-git-persistent-fail.ps1'
            $counterFile = Join-Path $TestDrive 'mock-git-persistent-fail.counter'
            # FailCount = 2 covers both the first attempt and the one retry --
            # removal never succeeds within this function's bounded retry.
            script:New-MockGitTeardownFailure -Path $mockGitPath -CounterFile $counterFile -FailCount 2

            # An uncaught exception here fails the It block on its own; a
            # successful assignment IS the "never throws" proof.
            $result = Remove-GCDisposableWorktree -RepoRoot $repo -WorktreePath $created.Path -GitCliPath $mockGitPath -RetryDelayMs 10 -WarningAction SilentlyContinue

            $result.Removed | Should -Be $false
            $result.OrphanedPath | Should -Be $created.Path

            script:Remove-GCTestWorktree -RepoRoot $repo -WorktreePath $created.Path
        }
    }

    Context 'Invoke-GCWorktreeSession -- fixed run-order + cleanliness + teardown wiring (s2, AC1)' {

        It 'runs the suite phase before the checks phase (fixed order)' {
            script:Assert-GCVFunctionExists -Name 'Invoke-GCWorktreeSession'
            $repo = script:New-GCTestRepo -Path (Join-Path $TestDrive 'order-repo')
            $order = [System.Collections.Generic.List[string]]::new()
            $suitePhase = { param($path) $order.Add('suite') }.GetNewClosure()
            $checksPhase = { param($path) $order.Add('checks') }.GetNewClosure()

            $session = Invoke-GCWorktreeSession -RepoRoot $repo -SuitePhase $suitePhase -ChecksPhase $checksPhase

            $session.Refused | Should -Be $false
            @($order) | Should -Be @('suite', 'checks')
        }

        It 'passes the worktree path to each phase scriptblock' {
            script:Assert-GCVFunctionExists -Name 'Invoke-GCWorktreeSession'
            $repo = script:New-GCTestRepo -Path (Join-Path $TestDrive 'phase-arg-repo')
            $seenPaths = [System.Collections.Generic.List[string]]::new()
            $suitePhase = { param($path) $seenPaths.Add($path) }.GetNewClosure()

            $session = Invoke-GCWorktreeSession -RepoRoot $repo -SuitePhase $suitePhase

            $seenPaths[0] | Should -Be $session.WorktreePath
        }

        It 'asserts cleanliness after the suite phase and surfaces check-induced dirt after the checks phase' {
            script:Assert-GCVFunctionExists -Name 'Invoke-GCWorktreeSession'
            $repo = script:New-GCTestRepo -Path (Join-Path $TestDrive 'dirt-repo')
            $suitePhase = {
                param($path)
                [System.IO.File]::WriteAllText((Join-Path $path 'suite-dirt.txt'), "dirt`n", [System.Text.UTF8Encoding]::new($false))
            }

            $session = Invoke-GCWorktreeSession -RepoRoot $repo -SuitePhase $suitePhase

            $session.SuiteCleanliness.IsClean | Should -Be $false -Because 'suite-phase dirt must be visible in the surfaced cleanliness assertion (mandatory-review flag territory for s3/s4)'
            $session.ChecksCleanliness.IsClean | Should -Be $false -Because 'no checks phase ran to clean it up; the assertion still reflects the tree honestly'
        }

        It 'reports clean SuiteCleanliness and ChecksCleanliness when neither phase produces dirt' {
            script:Assert-GCVFunctionExists -Name 'Invoke-GCWorktreeSession'
            $repo = script:New-GCTestRepo -Path (Join-Path $TestDrive 'no-dirt-repo')

            $session = Invoke-GCWorktreeSession -RepoRoot $repo -SuitePhase { param($path) } -ChecksPhase { param($path) }

            $session.SuiteCleanliness.IsClean | Should -Be $true
            $session.ChecksCleanliness.IsClean | Should -Be $true
        }

        It 'refuses uncommitted-changes before any worktree or phase runs when the invoking tree is dirty' {
            script:Assert-GCVFunctionExists -Name 'Invoke-GCWorktreeSession'
            $repo = script:New-GCTestRepo -Path (Join-Path $TestDrive 'session-refuse-dirty-repo')
            [System.IO.File]::WriteAllText((Join-Path $repo 'seed.txt'), "modified`n", [System.Text.UTF8Encoding]::new($false))
            $script:phaseCalled = $false
            $suitePhase = { param($path) $script:phaseCalled = $true }

            $session = Invoke-GCWorktreeSession -RepoRoot $repo -SuitePhase $suitePhase -WarningAction SilentlyContinue

            $session.Refused | Should -Be $true
            $session.RefusalReason | Should -Be 'refused: uncommitted-changes'
            $session.WorktreePath | Should -BeNullOrEmpty
            $script:phaseCalled | Should -Be $false -Because 'no phase may run when the invoking tree is dirty'
        }

        It 'tears down the worktree via finally even when a phase scriptblock throws, and re-throws to the caller' {
            script:Assert-GCVFunctionExists -Name 'Invoke-GCWorktreeSession'
            $repo = script:New-GCTestRepo -Path (Join-Path $TestDrive 'throw-repo')
            $script:capturedPath = $null
            $suitePhase = {
                param($path)
                $script:capturedPath = $path
                throw 'simulated suite-phase failure'
            }

            { Invoke-GCWorktreeSession -RepoRoot $repo -SuitePhase $suitePhase } | Should -Throw '*simulated suite-phase failure*'

            $script:capturedPath | Should -Not -BeNullOrEmpty
            (Test-Path -LiteralPath $script:capturedPath) | Should -Be $false -Because 'teardown in finally must still remove the worktree even though the phase threw'
            $worktreeList = & git -C $repo worktree list
            @($worktreeList).Count | Should -Be 1
        }

        It 'never throws and surfaces OrphanedPath when teardown persistently fails after a clean session' {
            script:Assert-GCVFunctionExists -Name 'Invoke-GCWorktreeSession'
            $repo = script:New-GCTestRepo -Path (Join-Path $TestDrive 'session-orphan-repo')
            $mockGitPath = Join-Path $TestDrive 'mock-git-session-orphan.ps1'
            $counterFile = Join-Path $TestDrive 'mock-git-session-orphan.counter'
            # FailCount = 2 covers the first teardown attempt and the retry;
            # every OTHER git subcommand this session issues (status,
            # rev-parse, worktree add, worktree prune) forwards to the real
            # git binary untouched.
            script:New-MockGitTeardownFailure -Path $mockGitPath -CounterFile $counterFile -FailCount 2

            # An uncaught exception here fails the It block on its own; a
            # successful assignment IS the "never throws" proof.
            $session = Invoke-GCWorktreeSession -RepoRoot $repo -GitCliPath $mockGitPath -RetryDelayMs 10 -WarningAction SilentlyContinue

            $session.Refused | Should -Be $false
            $session.OrphanedPath | Should -Be $session.WorktreePath

            script:Remove-GCTestWorktree -RepoRoot $repo -WorktreePath $session.WorktreePath
        }
    }

    Context 'ConvertTo-GCWallClockSeconds -- budget.wall_clock parsing (s3, AC1)' {

        It 'parses an hour-suffixed value' {
            script:Assert-GCVFunctionExists -Name 'ConvertTo-GCWallClockSeconds'
            ConvertTo-GCWallClockSeconds -Value '4h' | Should -Be 14400
        }

        It 'parses a minute-suffixed value' {
            script:Assert-GCVFunctionExists -Name 'ConvertTo-GCWallClockSeconds'
            ConvertTo-GCWallClockSeconds -Value '90m' | Should -Be 5400
        }

        It 'parses a second-suffixed value' {
            script:Assert-GCVFunctionExists -Name 'ConvertTo-GCWallClockSeconds'
            ConvertTo-GCWallClockSeconds -Value '300s' | Should -Be 300
        }

        It 'parses a bare integer as seconds' {
            script:Assert-GCVFunctionExists -Name 'ConvertTo-GCWallClockSeconds'
            ConvertTo-GCWallClockSeconds -Value '45' | Should -Be 45
        }

        It 'returns $null for a blank value' {
            script:Assert-GCVFunctionExists -Name 'ConvertTo-GCWallClockSeconds'
            ConvertTo-GCWallClockSeconds -Value '' | Should -BeNullOrEmpty
        }

        It 'returns $null for an unparseable compound value (advisory-only degrade, never a guess)' {
            script:Assert-GCVFunctionExists -Name 'ConvertTo-GCWallClockSeconds'
            ConvertTo-GCWallClockSeconds -Value '1h30m' | Should -BeNullOrEmpty
        }
    }

    Context 'Invoke-GCTargetCheck -- single target-check execution with tree-kill timeout (s3, AC1)' {

        It 'passes a target whose check exits 0' {
            script:Assert-GCVFunctionExists -Name 'Invoke-GCTargetCheck'
            $target = [pscustomobject]@{ id = 'T-pass'; check = 'exit 0'; falsifier = 'would show as an accumulator silently resetting' }

            $result = Invoke-GCTargetCheck -Target $target -WorktreePath $TestDrive -TimeoutSeconds 10

            $result.Outcome | Should -Be 'pass'
            $result.ExitCode | Should -Be 0
            $result.TimedOut | Should -Be $false
            $result.Reason | Should -BeNullOrEmpty
        }

        It 'fails a target whose check exits non-zero, marshalling the real exit code from the Process object' {
            script:Assert-GCVFunctionExists -Name 'Invoke-GCTargetCheck'
            $target = [pscustomobject]@{ id = 'T-fail'; check = 'exit 7'; falsifier = 'would show as a swallowed error' }

            $result = Invoke-GCTargetCheck -Target $target -WorktreePath $TestDrive -TimeoutSeconds 10

            $result.Outcome | Should -Be 'fail'
            $result.ExitCode | Should -Be 7 -Because 'the exit code must be marshalled explicitly from the Process object, not inferred from a job State'
            $result.TimedOut | Should -Be $false
        }

        It 'tree-kills the WHOLE process tree on timeout -- no orphaned descendant survives, and the target result is fail' {
            script:Assert-GCVFunctionExists -Name 'Invoke-GCTargetCheck'
            $pidFile = Join-Path $TestDrive 'child.pid'
            $pidFileEscaped = $pidFile -replace "'", "''"
            $check = @"
`$c = Start-Process -FilePath (Get-Process -Id `$PID).Path -ArgumentList @('-NoProfile', '-NonInteractive', '-Command', 'Start-Sleep -Seconds 30') -PassThru
Set-Content -LiteralPath '$pidFileEscaped' -Value `$c.Id -NoNewline
Start-Sleep -Seconds 30
"@
            $target = [pscustomobject]@{ id = 'T-tree'; check = $check; falsifier = 'would show as a hung check silently reported clean' }

            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            $result = Invoke-GCTargetCheck -Target $target -WorktreePath $TestDrive -TimeoutSeconds 2
            $sw.Stop()

            $result.Outcome | Should -Be 'fail' -Because 'a timed-out check must map to fail, never refused or review-required'
            $result.TimedOut | Should -Be $true
            $result.Reason | Should -Match 'timeout'
            $sw.Elapsed.TotalSeconds | Should -BeLessThan 15 -Because 'the tree-kill must happen promptly after the 2s timeout, not wait out the 30s child sleep'

            (Test-Path -LiteralPath $pidFile) | Should -Be $true -Because 'the child process must have started and recorded its pid before the parent was killed'
            $childPid = [int](Get-Content -LiteralPath $pidFile -Raw)
            Start-Sleep -Milliseconds 500
            (Get-Process -Id $childPid -ErrorAction SilentlyContinue) | Should -BeNullOrEmpty -Because 'Kill($true) (or the taskkill /T /F fallback) must reap the entire process tree, not just the immediate check process -- Stop-Job would leave this descendant orphaned (U2)'
        }

        It 'refuses a blank/whitespace-only check as a per-target floor without spawning a process' {
            script:Assert-GCVFunctionExists -Name 'Invoke-GCTargetCheck'
            $target = [pscustomobject]@{ id = 'T-blank'; check = '   '; falsifier = 'would show as a vacuous target silently passing' }

            $result = Invoke-GCTargetCheck -Target $target -WorktreePath $TestDrive -TimeoutSeconds 5

            $result.Outcome | Should -Be 'fail'
            $result.Reason | Should -Be 'refused: blank-check'
            $result.ExitCode | Should -BeNullOrEmpty
            $result.ElapsedMs | Should -Be 0 -Because 'no process should be spawned for a blank check'
        }

        It 'flags a target with no falsifier field as advisory, without changing its pass outcome' {
            script:Assert-GCVFunctionExists -Name 'Invoke-GCTargetCheck'
            $target = [pscustomobject]@{ id = 'T-no-falsifier'; check = 'exit 0' }

            $result = Invoke-GCTargetCheck -Target $target -WorktreePath $TestDrive -TimeoutSeconds 5

            $result.Outcome | Should -Be 'pass' -Because 'falsifier-absent is purely informational and must never change the pass/fail outcome'
            $result.AdvisoryFlags | Should -Contain 'falsifier-absent'
        }

        It 'flags a target with a blank falsifier field as advisory too' {
            script:Assert-GCVFunctionExists -Name 'Invoke-GCTargetCheck'
            $target = [pscustomobject]@{ id = 'T-blank-falsifier'; check = 'exit 0'; falsifier = '   ' }

            $result = Invoke-GCTargetCheck -Target $target -WorktreePath $TestDrive -TimeoutSeconds 5

            $result.AdvisoryFlags | Should -Contain 'falsifier-absent'
        }

        It 'does not flag falsifier-absent when a non-blank falsifier is present' {
            script:Assert-GCVFunctionExists -Name 'Invoke-GCTargetCheck'
            $target = [pscustomobject]@{ id = 'T-has-falsifier'; check = 'exit 0'; falsifier = 'would look like an accumulator silently resetting null to zero' }

            $result = Invoke-GCTargetCheck -Target $target -WorktreePath $TestDrive -TimeoutSeconds 5

            $result.AdvisoryFlags | Should -Not -Contain 'falsifier-absent'
        }

        It 'caps captured stdout at the byte limit and marks it truncated rather than capturing unboundedly' {
            script:Assert-GCVFunctionExists -Name 'Invoke-GCTargetCheck'
            $check = "1..2000 | ForEach-Object { Write-Output ('line-' + `$_ + '-' + ('x' * 40)) }"
            $target = [pscustomobject]@{ id = 'T-verbose'; check = $check; falsifier = 'would show as unbounded memory growth' }

            $result = Invoke-GCTargetCheck -Target $target -WorktreePath $TestDrive -TimeoutSeconds 15 -OutputCapBytes 500

            $result.StdOutTruncated | Should -Be $true
            $result.StdOut.Length | Should -BeLessThan 2000 -Because 'the captured buffer must stay bounded near the cap, not grow to the full ~90KB the check actually writes'
            $result.StdOut | Should -Match 'truncated'
        }
    }

    Context 'Invoke-GCTargetChecks -- aggregate execution + advisory budget ceiling (s3, AC1)' {

        It 'runs every target in order and returns per-target results' {
            script:Assert-GCVFunctionExists -Name 'Invoke-GCTargetChecks'
            $targets = @(
                [pscustomobject]@{ id = 'A'; check = 'exit 0'; falsifier = 'x' },
                [pscustomobject]@{ id = 'B'; check = 'exit 1'; falsifier = 'x' }
            )

            $session = Invoke-GCTargetChecks -Targets $targets -WorktreePath $TestDrive -TimeoutSeconds 10

            @($session.Targets).Count | Should -Be 2
            $session.Targets[0].Id | Should -Be 'A'
            $session.Targets[0].Outcome | Should -Be 'pass'
            $session.Targets[1].Id | Should -Be 'B'
            $session.Targets[1].Outcome | Should -Be 'fail'
        }

        It 'does not flag BudgetExceeded when no budget.wall_clock is supplied' {
            script:Assert-GCVFunctionExists -Name 'Invoke-GCTargetChecks'
            $targets = @([pscustomobject]@{ id = 'A'; check = 'exit 0'; falsifier = 'x' })

            $session = Invoke-GCTargetChecks -Targets $targets -WorktreePath $TestDrive -TimeoutSeconds 10

            $session.BudgetExceeded | Should -Be $false
            $session.BudgetWallClockSeconds | Should -BeNullOrEmpty
        }

        It 'does not flag BudgetExceeded when elapsed time is comfortably under a large parsed budget' {
            script:Assert-GCVFunctionExists -Name 'Invoke-GCTargetChecks'
            $targets = @([pscustomobject]@{ id = 'A'; check = 'exit 0'; falsifier = 'x' })

            $session = Invoke-GCTargetChecks -Targets $targets -WorktreePath $TestDrive -TimeoutSeconds 10 -BudgetWallClock '4h'

            $session.BudgetExceeded | Should -Be $false
            $session.BudgetWallClockSeconds | Should -Be 14400
        }

        It 'flags BudgetExceeded (advisory-only) when total elapsed exceeds a parsed budget.wall_clock, without changing any target Outcome' {
            script:Assert-GCVFunctionExists -Name 'Invoke-GCTargetChecks'
            $targets = @([pscustomobject]@{ id = 'A'; check = 'exit 0'; falsifier = 'x' })

            $session = Invoke-GCTargetChecks -Targets $targets -WorktreePath $TestDrive -TimeoutSeconds 10 -BudgetWallClock '0s'

            $session.BudgetExceeded | Should -Be $true
            $session.Targets[0].Outcome | Should -Be 'pass' -Because 'the budget ceiling is advisory-only and must never override a target''s own execution outcome'
        }
    }

    Context 'Test-GCSuiteGatePass -- green-floor gate (s4, AC1, U1 CRITICAL fix)' {

        It 'passes a genuinely green result (ExitCode 0, TotalFailed 0, tests ran)' {
            script:Assert-GCVFunctionExists -Name 'Test-GCSuiteGatePass'
            $result = [pscustomobject]@{ ExitCode = 0; TotalPassed = 4420; TotalFailed = 0 }

            Test-GCSuiteGatePass -Result $result | Should -Be $true
        }

        It 'fails a genuinely red result (one real failure)' {
            script:Assert-GCVFunctionExists -Name 'Test-GCSuiteGatePass'
            $result = [pscustomobject]@{ ExitCode = 1; TotalPassed = 4419; TotalFailed = 1 }

            Test-GCSuiteGatePass -Result $result | Should -Be $false
        }

        It 'fails the TestsPath-not-found false-GREEN shape (ExitCode=1, TotalFailed=0, TotalPassed=0) -- U1 CRITICAL' {
            script:Assert-GCVFunctionExists -Name 'Test-GCSuiteGatePass'
            # Mirrors pester-sharded-core.ps1:100-103's exact early-return shape.
            $result = [pscustomobject]@{ ExitCode = 1; TotalPassed = 0; TotalFailed = 0; Results = @() }

            Test-GCSuiteGatePass -Result $result | Should -Be $false -Because 'gating on TotalFailed alone would green-light a suite that never ran because TestsPath did not exist (U1 CRITICAL)'
        }

        It 'fails the zero-discovered false-GREEN shape (identical field values, different cause -- the lib does not distinguish them observably)' {
            script:Assert-GCVFunctionExists -Name 'Test-GCSuiteGatePass'
            # pester-sharded-core.ps1:109-112 returns the identical field
            # shape as the TestsPath-not-found case above -- one gate test
            # covers both per the RC's own "otherwise one test suffices".
            $result = [pscustomobject]@{ ExitCode = 1; TotalPassed = 0; TotalFailed = 0; Results = @() }

            Test-GCSuiteGatePass -Result $result | Should -Be $false -Because 'gating on TotalFailed alone would green-light a suite where zero .Tests.ps1 files were discovered (U1 CRITICAL)'
        }

        It 'fails the MinTestCount-floor false-GREEN shape (ExitCode=1, TotalFailed=0, TotalPassed below the floor)' {
            script:Assert-GCVFunctionExists -Name 'Test-GCSuiteGatePass'
            # pester-sharded-core.ps1:397-400: MinTestCount not met sets
            # ExitCode=1 but does NOT increment TotalFailed. Unlike the two
            # shapes above, Passed+Failed IS > 0 here -- the ran-guard alone
            # would NOT catch this shape; ExitCode is what catches it.
            $result = [pscustomobject]@{ ExitCode = 1; TotalPassed = 12; TotalFailed = 0; Results = @() }

            Test-GCSuiteGatePass -Result $result | Should -Be $false -Because 'MinTestCount<200 sets ExitCode=1 without incrementing TotalFailed (U1 CRITICAL)'
        }

        It 'fails when ExitCode is 0 but no tests ran at all (defensive ran-guard clause, independent of ExitCode)' {
            script:Assert-GCVFunctionExists -Name 'Test-GCSuiteGatePass'
            $result = [pscustomobject]@{ ExitCode = 0; TotalPassed = 0; TotalFailed = 0 }

            Test-GCSuiteGatePass -Result $result | Should -Be $false -Because 'the ran-guard is an independent defensive floor, not merely redundant with ExitCode'
        }

        It 'fails closed (never throws, never defaults to pass) for a $null result' {
            script:Assert-GCVFunctionExists -Name 'Test-GCSuiteGatePass'

            Test-GCSuiteGatePass -Result $null | Should -Be $false
        }

        It 'fails closed for a result object missing ExitCode or TotalFailed entirely' {
            script:Assert-GCVFunctionExists -Name 'Test-GCSuiteGatePass'
            $malformed = [pscustomobject]@{ SomethingElse = 'x' }

            Test-GCSuiteGatePass -Result $malformed | Should -Be $false
        }
    }

    Context 'Invoke-GCSuitePhase -- explicit -TestsPath + suite-phase wall-clock timeout (s4, AC1/AC3)' {

        BeforeAll {
            # A fake "worktree" carrying its own stub pester-sharded-core.ps1
            # copy, so these tests exercise the real child-pwsh-process +
            # tree-kill mechanics without running the real 200+ file suite.
            function script:New-GCStubWorktree {
                param([Parameter(Mandatory)][string]$Path)
                New-Item -ItemType Directory -Path (Join-Path $Path '.github/scripts/lib') -Force | Out-Null
                New-Item -ItemType Directory -Path (Join-Path $Path '.github/scripts/Tests') -Force | Out-Null
                return $Path
            }
        }

        It 'calls Invoke-PesterSharded with the EXPLICIT worktree-derived -TestsPath, never a default' {
            script:Assert-GCVFunctionExists -Name 'Invoke-GCSuitePhase'
            $worktree = script:New-GCStubWorktree -Path (Join-Path $TestDrive 'explicit-testspath-worktree')
            $stubLib = Join-Path $worktree '.github/scripts/lib/pester-sharded-core.ps1'
            $captureFile = Join-Path $worktree 'captured-testspath.txt'
            $captureFileEscaped = $captureFile -replace "'", "''"
            @"
function Invoke-PesterSharded {
    param([string]`$TestsPath, [int]`$MinTestCount = 200)
    Set-Content -LiteralPath '$captureFileEscaped' -Value `$TestsPath -NoNewline -Encoding UTF8
    return [pscustomobject]@{ ExitCode = 0; TotalPassed = 5; TotalFailed = 0; WallClockMs = 10; MissingFiles = @(); FailedFiles = @() }
}
"@ | Set-Content -LiteralPath $stubLib -Encoding UTF8

            $result = Invoke-GCSuitePhase -WorktreePath $worktree -TimeoutSeconds 15

            $result.ExitCode | Should -Be 0
            (Test-Path -LiteralPath $captureFile) | Should -Be $true -Because 'the stub must have been invoked at all'
            $capturedTestsPath = (Get-Content -LiteralPath $captureFile -Raw).Trim()
            $expectedTestsPath = Join-Path $worktree '.github/scripts/Tests'
            $capturedTestsPath | Should -Be $expectedTestsPath -Because 'the -TestsPath must be explicit and worktree-derived, never the function''s own $PSScriptRoot-relative default'
        }

        It 'passes through a genuinely green stub result end-to-end (ExitCode/TotalPassed/TotalFailed marshalled correctly)' {
            script:Assert-GCVFunctionExists -Name 'Invoke-GCSuitePhase'
            $worktree = script:New-GCStubWorktree -Path (Join-Path $TestDrive 'green-worktree')
            $stubLib = Join-Path $worktree '.github/scripts/lib/pester-sharded-core.ps1'
            @'
function Invoke-PesterSharded {
    param([string]$TestsPath, [int]$MinTestCount = 200)
    return [pscustomobject]@{ ExitCode = 0; TotalPassed = 250; TotalFailed = 0; WallClockMs = 4200; MissingFiles = @(); FailedFiles = @() }
}
'@ | Set-Content -LiteralPath $stubLib -Encoding UTF8

            $result = Invoke-GCSuitePhase -WorktreePath $worktree -TimeoutSeconds 15

            $result.ExitCode | Should -Be 0
            $result.TotalPassed | Should -Be 250
            $result.TotalFailed | Should -Be 0
            $result.TimedOut | Should -Be $false
            Test-GCSuiteGatePass -Result $result | Should -Be $true
        }

        It 'passes through a genuinely red stub result end-to-end and fails the gate' {
            script:Assert-GCVFunctionExists -Name 'Invoke-GCSuitePhase'
            $worktree = script:New-GCStubWorktree -Path (Join-Path $TestDrive 'red-worktree')
            $stubLib = Join-Path $worktree '.github/scripts/lib/pester-sharded-core.ps1'
            @'
function Invoke-PesterSharded {
    param([string]$TestsPath, [int]$MinTestCount = 200)
    return [pscustomobject]@{ ExitCode = 1; TotalPassed = 248; TotalFailed = 2; WallClockMs = 4200; MissingFiles = @(); FailedFiles = @('some.Tests.ps1') }
}
'@ | Set-Content -LiteralPath $stubLib -Encoding UTF8

            $result = Invoke-GCSuitePhase -WorktreePath $worktree -TimeoutSeconds 15

            $result.ExitCode | Should -Be 1
            $result.TotalFailed | Should -Be 2
            Test-GCSuiteGatePass -Result $result | Should -Be $false
        }

        It 'preemptively tree-kills a hung suite phase on timeout and returns a fail-shaped result -- never waits out the hang' {
            script:Assert-GCVFunctionExists -Name 'Invoke-GCSuitePhase'
            $worktree = script:New-GCStubWorktree -Path (Join-Path $TestDrive 'timeout-worktree')
            $stubLib = Join-Path $worktree '.github/scripts/lib/pester-sharded-core.ps1'
            # A stub that sleeps far longer than the test-scale timeout below.
            # If this function dot-sourced the REAL repo's pester-sharded-core.ps1
            # instead of this worktree's own stub, it would return the
            # TestsPath-not-found shape almost instantly rather than hanging
            # for 30s -- so this test doubles as proof the WORKTREE'S OWN
            # copy is what actually ran.
            @'
function Invoke-PesterSharded {
    param([string]$TestsPath, [int]$MinTestCount = 200)
    Start-Sleep -Seconds 30
    return [pscustomobject]@{ ExitCode = 0; TotalPassed = 5; TotalFailed = 0; WallClockMs = 30000; MissingFiles = @(); FailedFiles = @() }
}
'@ | Set-Content -LiteralPath $stubLib -Encoding UTF8

            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            $result = Invoke-GCSuitePhase -WorktreePath $worktree -TimeoutSeconds 2
            $sw.Stop()

            $result.ExitCode | Should -Be 1 -Because 'a suite-phase timeout must map to fail, never a silent pass'
            $result.TotalFailed | Should -Be 0 -Because 'the fail-closed timeout shape mirrors the exact false-GREEN field values Test-GCSuiteGatePass must reject on ExitCode'
            $result.TimedOut | Should -Be $true
            Test-GCSuiteGatePass -Result $result | Should -Be $false -Because 'the timeout result must fail the gate even though TotalFailed reads 0'
            $sw.Elapsed.TotalSeconds | Should -BeLessThan 20 -Because 'the tree-kill must happen promptly after the 2s timeout, not wait out the 30s hang'
        }

        It 'fails closed when the worktree has no runner-lib copy at all, without spawning a process' {
            script:Assert-GCVFunctionExists -Name 'Invoke-GCSuitePhase'
            $worktree = Join-Path $TestDrive 'no-lib-worktree'
            New-Item -ItemType Directory -Path $worktree -Force | Out-Null

            $result = Invoke-GCSuitePhase -WorktreePath $worktree -TimeoutSeconds 5 -WarningAction SilentlyContinue

            $result.ExitCode | Should -Be 1
            $result.TotalFailed | Should -Be 0
            Test-GCSuiteGatePass -Result $result | Should -Be $false
        }
    }

    Context 'Resolve-GCDiffBase -- explicit-SHA merge-base + no-fetch refusal (s5, AC1/AC2)' {

        It 'computes the merge-base from EXPLICIT SHAs, honoring -RunSha regardless of what is currently checked out' {
            script:Assert-GCVFunctionExists -Name 'Resolve-GCDiffBase'
            $repo = script:New-GCTestRepo -Path (Join-Path $TestDrive 'diffbase-repo')
            script:Write-GCFile -RepoPath $repo -RelativePath 'main-file.txt' -Content "main`n"
            $mainTip = script:New-GCCommit -RepoPath $repo -Message 'main commit'
            & git -C $repo checkout -q -b feature 2>&1 | Out-Null
            script:Write-GCFile -RepoPath $repo -RelativePath 'feature-file.txt' -Content "feature`n"
            $runSha = script:New-GCCommit -RepoPath $repo -Message 'feature commit'
            & git -C $repo checkout -q main 2>&1 | Out-Null

            $result = Resolve-GCDiffBase -WorktreePath $repo -RunSha $runSha -DefaultRef 'main'

            $result.Refused | Should -Be $false
            $result.DefaultSha | Should -Be $mainTip
            $result.MergeBaseSha | Should -Be $mainTip -Because 'feature branched directly from the main tip'
        }

        It 'refuses no-run-diff, naming all three plausible causes honestly, when merge-base equals the run sha' {
            script:Assert-GCVFunctionExists -Name 'Resolve-GCDiffBase'
            $repo = script:New-GCTestRepo -Path (Join-Path $TestDrive 'no-run-diff-repo')
            script:Write-GCFile -RepoPath $repo -RelativePath 'x.txt' -Content "x`n"
            $mainTip = script:New-GCCommit -RepoPath $repo -Message 'commit'

            $result = Resolve-GCDiffBase -WorktreePath $repo -RunSha $mainTip -DefaultRef 'main'

            $result.Refused | Should -Be $true
            $result.RefusalReason | Should -Match 'no-run-diff'
            $result.RefusalReason | Should -Match 'no commits beyond'
            $result.RefusalReason | Should -Match 'committing directly to the default branch'
            $result.RefusalReason | Should -Match 'already being merged' -Because 'the message must name all three indistinguishable causes rather than guessing which one occurred'
        }

        It 'refuses default-ref-unresolvable (never fetches) when the local default ref is absent' {
            script:Assert-GCVFunctionExists -Name 'Resolve-GCDiffBase'
            $repo = script:New-GCTestRepo -Path (Join-Path $TestDrive 'no-default-ref-repo')
            $runSha = (& git -C $repo rev-parse HEAD).Trim()

            $result = Resolve-GCDiffBase -WorktreePath $repo -RunSha $runSha -DefaultRef 'origin/main'

            $result.Refused | Should -Be $true
            $result.RefusalReason | Should -Match 'default-ref-unresolvable'
        }

        It 'never calls git fetch when the default ref is absent -- refuses instead' {
            script:Assert-GCVFunctionExists -Name 'Resolve-GCDiffBase'
            $repo = script:New-GCTestRepo -Path (Join-Path $TestDrive 'no-fetch-repo')
            $runSha = (& git -C $repo rev-parse HEAD).Trim()
            $mockGitPath = Join-Path $TestDrive 'mock-git-no-fetch.ps1'
            $markerFile = Join-Path $TestDrive 'fetch-called.marker'
            script:New-MockGitNoFetch -Path $mockGitPath -MarkerFile $markerFile

            $result = Resolve-GCDiffBase -WorktreePath $repo -RunSha $runSha -DefaultRef 'origin/main' -GitCliPath $mockGitPath

            $result.Refused | Should -Be $true
            $result.RefusalReason | Should -Match 'default-ref-unresolvable'
            (Test-Path -LiteralPath $markerFile) | Should -Be $false -Because 'a fetch inside a disposable worktree would mutate the operators real remote-tracking refs; the function must refuse instead'
        }
    }

    Context 'Test-GCTestFileDeletion -- rename-aware deletion detector via --diff-filter=DR --no-renames (s5, AC1/AC2)' {

        It 'flags a plainly deleted test file' {
            script:Assert-GCVFunctionExists -Name 'Test-GCTestFileDeletion'
            $repo = script:New-GCTestRepo -Path (Join-Path $TestDrive 'plain-delete-repo')
            script:Write-GCFile -RepoPath $repo -RelativePath 'Tests/Foo.Tests.ps1' -Content @'
Describe 'Foo' { It 'x' { 1 | Should -Be 1 } }
'@
            $baseSha = script:New-GCCommit -RepoPath $repo -Message 'add test file'
            script:Remove-GCFile -RepoPath $repo -RelativePath 'Tests/Foo.Tests.ps1'
            $runSha = script:New-GCCommit -RepoPath $repo -Message 'delete test file'

            $result = Test-GCTestFileDeletion -WorktreePath $repo -BaseSha $baseSha -RunSha $runSha -AllowlistPathspecs @('.')

            $result.Flagged | Should -Be $true
            $result.DeletedFiles | Should -Contain 'Tests/Foo.Tests.ps1'
        }

        It 'flags a renamed-and-gutted test file as a deletion of the OLD path, not silently passed through as a rename' {
            script:Assert-GCVFunctionExists -Name 'Test-GCTestFileDeletion'
            $repo = script:New-GCTestRepo -Path (Join-Path $TestDrive 'rename-gut-repo')
            $baseContent = @'
Describe 'Foo' {
    It 'does something' {
        1 | Should -Be 1
    }
    It 'does another thing' {
        2 | Should -Be 2
    }
    It 'does a third thing' {
        3 | Should -Be 3
    }
}
'@
            script:Write-GCFile -RepoPath $repo -RelativePath 'Tests/Foo.Tests.ps1' -Content $baseContent
            $baseSha = script:New-GCCommit -RepoPath $repo -Message 'add test file'

            $guttedContent = @'
Describe 'Foo' {
    It 'does something' {
        1 | Should -Be 1
    }
    It 'does another thing' {
        2 | Should -Be 2
    }
}
'@
            script:Remove-GCFile -RepoPath $repo -RelativePath 'Tests/Foo.Tests.ps1'
            script:Write-GCFile -RepoPath $repo -RelativePath 'Tests/Bar.Tests.ps1' -Content $guttedContent
            $runSha = script:New-GCCommit -RepoPath $repo -Message 'rename and gut'

            # Sanity: confirm the fixture actually exercises a rename -- git's
            # DEFAULT rename detection (no --no-renames) must classify this
            # pair as a rename (status R), which a plain --diff-filter=D
            # would never match, so this test proves something real about
            # the --no-renames override below.
            $renameStatus = & git -C $repo diff --name-status --diff-filter=R $baseSha $runSha 2>$null
            @($renameStatus | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count | Should -BeGreaterThan 0 -Because 'the fixture must produce a real git-detected rename for this test to prove anything about the --no-renames override'

            $result = Test-GCTestFileDeletion -WorktreePath $repo -BaseSha $baseSha -RunSha $runSha -AllowlistPathspecs @('.')

            $result.Flagged | Should -Be $true -Because '--no-renames must force the rename-and-gut to surface as a deletion of the old path'
            $result.DeletedFiles | Should -Contain 'Tests/Foo.Tests.ps1'
        }

        It 'does not flag a file that was only modified in place at the same path' {
            script:Assert-GCVFunctionExists -Name 'Test-GCTestFileDeletion'
            $repo = script:New-GCTestRepo -Path (Join-Path $TestDrive 'modify-in-place-repo')
            script:Write-GCFile -RepoPath $repo -RelativePath 'Tests/Foo.Tests.ps1' -Content @'
Describe 'Foo' { It 'x' { 1 | Should -Be 1 } }
'@
            $baseSha = script:New-GCCommit -RepoPath $repo -Message 'add test file'
            script:Write-GCFile -RepoPath $repo -RelativePath 'Tests/Foo.Tests.ps1' -Content @'
Describe 'Foo' { It 'x' { 1 | Should -Be 2 } }
'@
            $runSha = script:New-GCCommit -RepoPath $repo -Message 'modify test file'

            $result = Test-GCTestFileDeletion -WorktreePath $repo -BaseSha $baseSha -RunSha $runSha -AllowlistPathspecs @('.')

            $result.Flagged | Should -Be $false
            @($result.DeletedFiles).Count | Should -Be 0
        }
    }

    Context 'Get-GCShouldCommandCount -- AST-aware Should-command counting (s5, AC1)' {

        It 'counts real Should command invocations' {
            script:Assert-GCVFunctionExists -Name 'Get-GCShouldCommandCount'
            $content = @'
Describe 'X' {
    It 'y' {
        1 | Should -Be 1
        2 | Should -Be 2
    }
}
'@
            Get-GCShouldCommandCount -Content $content | Should -Be 2
        }

        It 'does not count the word Should inside a comment' {
            script:Assert-GCVFunctionExists -Name 'Get-GCShouldCommandCount'
            $content = @'
# this Should not be counted
1 | Should -Be 1
'@
            Get-GCShouldCommandCount -Content $content | Should -Be 1
        }

        It 'does not count the word Should inside a string literal' {
            script:Assert-GCVFunctionExists -Name 'Get-GCShouldCommandCount'
            $content = @'
Write-Output 'The word Should appears here'
1 | Should -Be 1
'@
            Get-GCShouldCommandCount -Content $content | Should -Be 1
        }

        It 'does not count SupportsShouldProcess or $PSCmdlet.ShouldProcess (not a CommandAst named Should)' {
            script:Assert-GCVFunctionExists -Name 'Get-GCShouldCommandCount'
            $content = @'
function Foo {
    [CmdletBinding(SupportsShouldProcess)]
    param()
    if ($PSCmdlet.ShouldProcess('x')) {
        1 | Should -Be 1
    }
}
'@
            Get-GCShouldCommandCount -Content $content | Should -Be 1
        }

        It 'returns 0 for blank or null content' {
            script:Assert-GCVFunctionExists -Name 'Get-GCShouldCommandCount'
            Get-GCShouldCommandCount -Content '' | Should -Be 0
            Get-GCShouldCommandCount -Content $null | Should -Be 0
        }
    }

    Context 'Test-GCAssertionWeakening -- AST Should-count regression via git show (s5, AC1/AC2)' {

        It 'flags a file that lost a real Should assertion between base and run' {
            script:Assert-GCVFunctionExists -Name 'Test-GCAssertionWeakening'
            $repo = script:New-GCTestRepo -Path (Join-Path $TestDrive 'weaken-repo')
            script:Write-GCFile -RepoPath $repo -RelativePath 'Tests/Foo.Tests.ps1' -Content @'
Describe 'Foo' { It 'x' { 1 | Should -Be 1; 2 | Should -Be 2 } }
'@
            $baseSha = script:New-GCCommit -RepoPath $repo -Message 'two assertions'
            script:Write-GCFile -RepoPath $repo -RelativePath 'Tests/Foo.Tests.ps1' -Content @'
Describe 'Foo' { It 'x' { 1 | Should -Be 1 } }
'@
            $runSha = script:New-GCCommit -RepoPath $repo -Message 'one assertion removed'

            $result = Test-GCAssertionWeakening -WorktreePath $repo -BaseSha $baseSha -RunSha $runSha -ChangedTestFilePaths @('Tests/Foo.Tests.ps1')

            $result.Flagged | Should -Be $true
            $result.Files[0].Path | Should -Be 'Tests/Foo.Tests.ps1'
            $result.Files[0].BaseCount | Should -Be 2
            $result.Files[0].RunCount | Should -Be 1
            $result.HeuristicNote | Should -Match 'count-preserving weakening' -Because 'the result must always carry the honest heuristic caveat'
        }

        It 'does not flag when only a comment or string literal containing the word Should is added (real count unchanged)' {
            script:Assert-GCVFunctionExists -Name 'Test-GCAssertionWeakening'
            $repo = script:New-GCTestRepo -Path (Join-Path $TestDrive 'weaken-decoy-repo')
            script:Write-GCFile -RepoPath $repo -RelativePath 'Tests/Foo.Tests.ps1' -Content @'
Describe 'Foo' { It 'x' { 1 | Should -Be 1 } }
'@
            $baseSha = script:New-GCCommit -RepoPath $repo -Message 'one assertion'
            script:Write-GCFile -RepoPath $repo -RelativePath 'Tests/Foo.Tests.ps1' -Content @'
# this Should not change the count
Describe 'Foo' { It 'x' { Write-Output 'Should stay the same'; 1 | Should -Be 1 } }
'@
            $runSha = script:New-GCCommit -RepoPath $repo -Message 'decoy comment + string added, real count unchanged'

            $result = Test-GCAssertionWeakening -WorktreePath $repo -BaseSha $baseSha -RunSha $runSha -ChangedTestFilePaths @('Tests/Foo.Tests.ps1')

            $result.Flagged | Should -Be $false -Because 'the AST count is unchanged at 1; substring hits on comments/strings must never trigger a false flag'
        }

        It 'does not flag an increase in assertions' {
            script:Assert-GCVFunctionExists -Name 'Test-GCAssertionWeakening'
            $repo = script:New-GCTestRepo -Path (Join-Path $TestDrive 'weaken-increase-repo')
            script:Write-GCFile -RepoPath $repo -RelativePath 'Tests/Foo.Tests.ps1' -Content @'
Describe 'Foo' { It 'x' { 1 | Should -Be 1 } }
'@
            $baseSha = script:New-GCCommit -RepoPath $repo -Message 'one assertion'
            script:Write-GCFile -RepoPath $repo -RelativePath 'Tests/Foo.Tests.ps1' -Content @'
Describe 'Foo' { It 'x' { 1 | Should -Be 1; 2 | Should -Be 2 } }
'@
            $runSha = script:New-GCCommit -RepoPath $repo -Message 'assertion added'

            $result = Test-GCAssertionWeakening -WorktreePath $repo -BaseSha $baseSha -RunSha $runSha -ChangedTestFilePaths @('Tests/Foo.Tests.ps1')

            $result.Flagged | Should -Be $false
        }

        It 'skips a file that is absent at one of the two commits (deletion-class, not this detectors concern)' {
            script:Assert-GCVFunctionExists -Name 'Test-GCAssertionWeakening'
            $repo = script:New-GCTestRepo -Path (Join-Path $TestDrive 'weaken-deleted-repo')
            script:Write-GCFile -RepoPath $repo -RelativePath 'Tests/Foo.Tests.ps1' -Content @'
Describe 'Foo' { It 'x' { 1 | Should -Be 1 } }
'@
            $baseSha = script:New-GCCommit -RepoPath $repo -Message 'add'
            script:Remove-GCFile -RepoPath $repo -RelativePath 'Tests/Foo.Tests.ps1'
            $runSha = script:New-GCCommit -RepoPath $repo -Message 'delete'

            $result = Test-GCAssertionWeakening -WorktreePath $repo -BaseSha $baseSha -RunSha $runSha -ChangedTestFilePaths @('Tests/Foo.Tests.ps1')

            $result.Flagged | Should -Be $false
            @($result.Files).Count | Should -Be 0
        }
    }

    Context 'Get-GCHelperLibSet -- live-computed helper-lib set, not a frozen list (s5, AC1)' {

        It 'includes a lib file referenced via a direct Join-Path literal dot-source' {
            script:Assert-GCVFunctionExists -Name 'Get-GCHelperLibSet'
            $root = Join-Path $TestDrive 'direct-repo'
            script:Write-GCFile -RepoPath $root -RelativePath '.github/scripts/lib/foo-core.ps1' -Content 'function Get-Foo { }'
            script:Write-GCFile -RepoPath $root -RelativePath '.github/scripts/Tests/foo.Tests.ps1' -Content @'
. (Join-Path $PSScriptRoot '../lib/foo-core.ps1')
'@

            $result = Get-GCHelperLibSet -RepoRoot $root

            $result | Should -Contain '.github/scripts/lib/foo-core.ps1'
        }

        It 'includes a lib file referenced via one-hop $script: variable indirection (. $script:CoreFile-style)' {
            script:Assert-GCVFunctionExists -Name 'Get-GCHelperLibSet'
            $root = Join-Path $TestDrive 'indirect-repo'
            script:Write-GCFile -RepoPath $root -RelativePath '.github/scripts/lib/bar-core.ps1' -Content 'function Get-Bar { }'
            script:Write-GCFile -RepoPath $root -RelativePath '.github/scripts/Tests/bar.Tests.ps1' -Content @'
$script:CoreFile = Join-Path $PSScriptRoot '../lib/bar-core.ps1'
. $script:CoreFile
'@

            $result = Get-GCHelperLibSet -RepoRoot $root

            $result | Should -Contain '.github/scripts/lib/bar-core.ps1'
        }

        It 'does not include a lib filename that only appears in a comment, never actually dot-sourced' {
            script:Assert-GCVFunctionExists -Name 'Get-GCHelperLibSet'
            $root = Join-Path $TestDrive 'comment-only-repo'
            script:Write-GCFile -RepoPath $root -RelativePath '.github/scripts/lib/baz-core.ps1' -Content 'function Get-Baz { }'
            script:Write-GCFile -RepoPath $root -RelativePath '.github/scripts/Tests/baz.Tests.ps1' -Content @'
# see lib/baz-core.ps1 for details, but never dot-sourced here
'@

            $result = Get-GCHelperLibSet -RepoRoot $root

            $result | Should -Not -Contain '.github/scripts/lib/baz-core.ps1'
        }

        It 'never invents a phantom lib file that does not actually exist' {
            script:Assert-GCVFunctionExists -Name 'Get-GCHelperLibSet'
            $root = Join-Path $TestDrive 'phantom-repo'
            New-Item -ItemType Directory -Path (Join-Path $root '.github/scripts/lib') -Force | Out-Null
            script:Write-GCFile -RepoPath $root -RelativePath '.github/scripts/Tests/phantom.Tests.ps1' -Content @'
. (Join-Path $PSScriptRoot '../lib/does-not-exist.ps1')
'@

            $result = Get-GCHelperLibSet -RepoRoot $root

            @($result).Count | Should -Be 0
        }
    }

    Context 'Test-GCFixtureOrHelperModification -- fixture/helper mandatory-review flag (s5, AC1/AC2)' {

        It 'flags a changed file under Tests/fixtures/**' {
            script:Assert-GCVFunctionExists -Name 'Test-GCFixtureOrHelperModification'
            $repo = script:New-GCTestRepo -Path (Join-Path $TestDrive 'fixture-mod-repo')
            script:Write-GCFile -RepoPath $repo -RelativePath '.github/scripts/Tests/fixtures/sample.json' -Content '{}'
            $baseSha = script:New-GCCommit -RepoPath $repo -Message 'add fixture'
            script:Write-GCFile -RepoPath $repo -RelativePath '.github/scripts/Tests/fixtures/sample.json' -Content '{"changed":true}'
            $runSha = script:New-GCCommit -RepoPath $repo -Message 'modify fixture'

            $result = Test-GCFixtureOrHelperModification -WorktreePath $repo -BaseSha $baseSha -RunSha $runSha -HelperLibPaths @()

            $result.Flagged | Should -Be $true
            $result.ChangedFiles | Should -Contain '.github/scripts/Tests/fixtures/sample.json'
        }

        It 'flags a changed helper-lib file that IS in HelperLibPaths' {
            script:Assert-GCVFunctionExists -Name 'Test-GCFixtureOrHelperModification'
            $repo = script:New-GCTestRepo -Path (Join-Path $TestDrive 'helper-mod-repo')
            script:Write-GCFile -RepoPath $repo -RelativePath '.github/scripts/lib/helper-core.ps1' -Content 'function A { 1 }'
            $baseSha = script:New-GCCommit -RepoPath $repo -Message 'add helper'
            script:Write-GCFile -RepoPath $repo -RelativePath '.github/scripts/lib/helper-core.ps1' -Content 'function A { 2 }'
            $runSha = script:New-GCCommit -RepoPath $repo -Message 'modify helper'

            $result = Test-GCFixtureOrHelperModification -WorktreePath $repo -BaseSha $baseSha -RunSha $runSha -HelperLibPaths @('.github/scripts/lib/helper-core.ps1')

            $result.Flagged | Should -Be $true
            $result.ChangedFiles | Should -Contain '.github/scripts/lib/helper-core.ps1'
        }

        It 'does not flag a lib file change when that file is NOT in HelperLibPaths (not dot-sourced by any test)' {
            script:Assert-GCVFunctionExists -Name 'Test-GCFixtureOrHelperModification'
            $repo = script:New-GCTestRepo -Path (Join-Path $TestDrive 'unrelated-lib-repo')
            script:Write-GCFile -RepoPath $repo -RelativePath '.github/scripts/lib/unrelated.ps1' -Content 'function B { 1 }'
            $baseSha = script:New-GCCommit -RepoPath $repo -Message 'add unrelated lib'
            script:Write-GCFile -RepoPath $repo -RelativePath '.github/scripts/lib/unrelated.ps1' -Content 'function B { 2 }'
            $runSha = script:New-GCCommit -RepoPath $repo -Message 'modify unrelated lib'

            $result = Test-GCFixtureOrHelperModification -WorktreePath $repo -BaseSha $baseSha -RunSha $runSha -HelperLibPaths @()

            $result.Flagged | Should -Be $false
        }
    }

    Context 'Test-GCUnrecognizedInvariants -- unchecked mandatory-review flag (s5, AC1)' {

        It 'returns empty when only the two known literals are present' {
            script:Assert-GCVFunctionExists -Name 'Test-GCUnrecognizedInvariants'
            $result = Test-GCUnrecognizedInvariants -Invariants @('full-pester-suite-no-new-failures', 'test-diff-integrity')

            @($result).Count | Should -Be 0
        }

        It 'flags a third invariant literal beyond the two known ones -- never a silent skip' {
            script:Assert-GCVFunctionExists -Name 'Test-GCUnrecognizedInvariants'
            $result = Test-GCUnrecognizedInvariants -Invariants @('full-pester-suite-no-new-failures', 'test-diff-integrity', 'some-repo-specific-invariant')

            @($result).Count | Should -Be 1
            $result | Should -Contain 'some-repo-specific-invariant'
        }

        It 'never silently drops multiple unrecognized literals' {
            script:Assert-GCVFunctionExists -Name 'Test-GCUnrecognizedInvariants'
            $result = Test-GCUnrecognizedInvariants -Invariants @('unknown-a', 'unknown-b')

            @($result).Count | Should -Be 2
        }
    }

    Context 'Invoke-GCDiffIntegrityPhase -- composed diff-integrity seam (s5, AC1/AC2)' {

        It 'short-circuits with the no-run-diff refusal and runs no detectors when merge-base equals run-sha' {
            script:Assert-GCVFunctionExists -Name 'Invoke-GCDiffIntegrityPhase'
            $repo = script:New-GCTestRepo -Path (Join-Path $TestDrive 'phase-norundiff-repo')
            script:Write-GCFile -RepoPath $repo -RelativePath 'x.txt' -Content "x`n"
            $mainTip = script:New-GCCommit -RepoPath $repo -Message 'commit'

            $result = Invoke-GCDiffIntegrityPhase -WorktreePath $repo -RunSha $mainTip -RepoRoot $repo -DefaultRef 'main'

            $result.Refused | Should -Be $true
            $result.RefusalReason | Should -Match 'no-run-diff'
            @($result.Flags).Count | Should -Be 0
        }

        It 'aggregates deletion, weakening, fixture/helper, and unrecognized-invariant flags from one base/run diff' {
            script:Assert-GCVFunctionExists -Name 'Invoke-GCDiffIntegrityPhase'
            $repo = script:New-GCTestRepo -Path (Join-Path $TestDrive 'phase-aggregate-repo')

            # Base state: a test file with two real assertions, a fixture, a
            # helper lib dot-sourced by a Tests file, and a soon-to-be-deleted
            # test file.
            script:Write-GCFile -RepoPath $repo -RelativePath '.github/scripts/lib/helper-core.ps1' -Content 'function Get-Helper { 1 }'
            script:Write-GCFile -RepoPath $repo -RelativePath '.github/scripts/Tests/uses-helper.Tests.ps1' -Content @'
. (Join-Path $PSScriptRoot '../lib/helper-core.ps1')
Describe 'UsesHelper' { It 'x' { 1 | Should -Be 1 } }
'@
            script:Write-GCFile -RepoPath $repo -RelativePath '.github/scripts/Tests/foo.Tests.ps1' -Content @'
Describe 'Foo' { It 'x' { 1 | Should -Be 1; 2 | Should -Be 2 } }
'@
            script:Write-GCFile -RepoPath $repo -RelativePath '.github/scripts/Tests/fixtures/sample.json' -Content '{}'
            script:Write-GCFile -RepoPath $repo -RelativePath '.github/scripts/Tests/todelete.Tests.ps1' -Content @'
Describe 'ToDelete' { It 'x' { 1 | Should -Be 1 } }
'@
            $mainTip = script:New-GCCommit -RepoPath $repo -Message 'base state'
            & git -C $repo checkout -q -b feature 2>&1 | Out-Null

            # Run state: delete a test file, weaken an assertion, and modify
            # a fixture and the dot-sourced helper lib. HEAD is left on
            # `feature` (== the run sha) so the live filesystem scan inside
            # Get-GCHelperLibSet reflects the run's own tree, mirroring the
            # production worktree (which is checked out at the run's commit).
            script:Remove-GCFile -RepoPath $repo -RelativePath '.github/scripts/Tests/todelete.Tests.ps1'
            script:Write-GCFile -RepoPath $repo -RelativePath '.github/scripts/Tests/foo.Tests.ps1' -Content @'
Describe 'Foo' { It 'x' { 1 | Should -Be 1 } }
'@
            script:Write-GCFile -RepoPath $repo -RelativePath '.github/scripts/Tests/fixtures/sample.json' -Content '{"changed":true}'
            script:Write-GCFile -RepoPath $repo -RelativePath '.github/scripts/lib/helper-core.ps1' -Content 'function Get-Helper { 2 }'
            $runSha = script:New-GCCommit -RepoPath $repo -Message 'run state'

            $result = Invoke-GCDiffIntegrityPhase -WorktreePath $repo -RunSha $runSha -RepoRoot $repo -Invariants @('full-pester-suite-no-new-failures', 'test-diff-integrity', 'custom-repo-invariant') -DefaultRef 'main'

            $result.Refused | Should -Be $false
            $kinds = @($result.Flags | ForEach-Object { $_.Kind })
            $kinds | Should -Contain 'test-file-deletion'
            $kinds | Should -Contain 'assertion-weakening'
            $kinds | Should -Contain 'fixture-or-helper-modification'
            $kinds | Should -Contain 'unrecognized-invariant'

            $unrecognizedFlag = $result.Flags | Where-Object { $_.Kind -eq 'unrecognized-invariant' }
            $unrecognizedFlag.Literal | Should -Be 'custom-repo-invariant'
        }

        It 'returns no flags when nothing in the allowlist changed and only known invariants are supplied' {
            script:Assert-GCVFunctionExists -Name 'Invoke-GCDiffIntegrityPhase'
            $repo = script:New-GCTestRepo -Path (Join-Path $TestDrive 'phase-noflags-repo')
            script:Write-GCFile -RepoPath $repo -RelativePath 'README.md' -Content "seed readme`n"
            $mainTip = script:New-GCCommit -RepoPath $repo -Message 'base state'
            & git -C $repo checkout -q -b feature 2>&1 | Out-Null
            script:Write-GCFile -RepoPath $repo -RelativePath 'README.md' -Content "changed readme, outside the allowlist`n"
            $runSha = script:New-GCCommit -RepoPath $repo -Message 'run state'

            $result = Invoke-GCDiffIntegrityPhase -WorktreePath $repo -RunSha $runSha -RepoRoot $repo -Invariants @('full-pester-suite-no-new-failures', 'test-diff-integrity') -DefaultRef 'main'

            $result.Refused | Should -Be $false
            @($result.Flags).Count | Should -Be 0
        }
    }
}
