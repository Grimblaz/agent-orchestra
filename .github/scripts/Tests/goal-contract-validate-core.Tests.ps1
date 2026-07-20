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

            $verdict.Verdict | Should -Be 'pass-review-required'
            $verdict.ExitCode | Should -Be 3
            $verdict.Reason | Should -Match 'infra-error' -Because 'the infra/harness-error disposition must carry a distinct Reason tag from a future target-level review-required disposition'
            $verdict.Verdict | Should -Not -Be 'fail' -Because 'an environment defect (missing module) must never be reported as the run failing'
        }
    }
}
