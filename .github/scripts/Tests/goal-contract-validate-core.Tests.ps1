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

        # --- s6 fixtures: end-to-end AC2 integration + wrapper smoke tests.
        # Same real-temp-git-repo, local-(non-global)-identity convention as
        # the s2/s5 fixtures above (no GIT_CONFIG_GLOBAL, no Get-RealGitFiles
        # registration -- this file stays safe in the parallel shard per the
        # rationale already established at :148-153).

        # A full disposable-worktree-ready fixture repo: local git identity,
        # the REAL pester-sharded-core.ps1 copied in (Invoke-GCSuitePhase's
        # fail-closed runner-lib-presence check requires this file to exist
        # inside whatever tree gets validated), and a tiny two-file Pester
        # suite (three total tests) that clears a low -MinTestCount floor
        # (Part E) fast. -IncludeFailingTest plants a genuinely failing test
        # for the synthetic-red fixture (item 7).
        function script:New-GCFixtureRepo {
            param(
                [Parameter(Mandatory)][string]$Path,
                [Parameter(Mandatory = $false)][switch]$IncludeFailingTest
            )
            New-Item -ItemType Directory -Path $Path -Force | Out-Null
            & git -C $Path init -q -b main . 2>&1 | Out-Null
            & git -C $Path config user.email 'goal-validate-s6@example.com' 2>&1 | Out-Null
            & git -C $Path config user.name 'goal-validate-s6' 2>&1 | Out-Null

            $realLib = Join-Path $script:RepoRoot '.github/scripts/lib/pester-sharded-core.ps1'
            $fixtureLibDir = Join-Path $Path '.github/scripts/lib'
            New-Item -ItemType Directory -Path $fixtureLibDir -Force | Out-Null
            Copy-Item -LiteralPath $realLib -Destination (Join-Path $fixtureLibDir 'pester-sharded-core.ps1') -Force

            # ConvertFrom-GCContractBlock (the #872 parser this validator
            # reuses, 872-D6) validates the parsed contract against this
            # schema file resolved relative to -RepoRoot -- it must exist
            # inside the fixture repo too, or every fixture refuses at
            # intake with "Schema file not found" regardless of what this
            # test is actually trying to exercise.
            $realSchema = Join-Path $script:RepoRoot 'skills/plan-authoring/schemas/goal-contract.schema.json'
            $fixtureSchemaDir = Join-Path $Path 'skills/plan-authoring/schemas'
            New-Item -ItemType Directory -Path $fixtureSchemaDir -Force | Out-Null
            Copy-Item -LiteralPath $realSchema -Destination (Join-Path $fixtureSchemaDir 'goal-contract.schema.json') -Force

            $testsDir = Join-Path $Path '.github/scripts/Tests'
            New-Item -ItemType Directory -Path $testsDir -Force | Out-Null
            $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
            [System.IO.File]::WriteAllText((Join-Path $testsDir 'sample1.Tests.ps1'), "Describe 'Fixture' { It 'passes one' { 1 | Should -Be 1; 2 | Should -Be 2 } }`n", $utf8NoBom)
            [System.IO.File]::WriteAllText((Join-Path $testsDir 'sample2.Tests.ps1'), "Describe 'Fixture' { It 'passes two' { 3 | Should -Be 3 } }`n", $utf8NoBom)
            if ($IncludeFailingTest) {
                [System.IO.File]::WriteAllText((Join-Path $testsDir 'redcase.Tests.ps1'), "Describe 'Fixture' { It 'fails on purpose' { 1 | Should -Be 2 } }`n", $utf8NoBom)
            }

            & git -C $Path add -A 2>&1 | Out-Null
            & git -C $Path commit -q -m 'base' 2>&1 | Out-Null
            return $Path
        }

        # Two-pass hash construction (mirrors New-WellFormedContractPayload
        # above): a single real target whose `check` is a trivial always-
        # succeeds pwsh command (no example-check.ps1 dependency), so Part F
        # fixtures never need a real target-check script on disk.
        function script:New-GCContractPayloadForHash {
            param(
                [Parameter(Mandatory)][string]$Hash,
                [Parameter(Mandatory = $false)][string]$CheckCommand = 'exit 0',
                [Parameter(Mandatory = $false)][string[]]$ExtraInvariants = @()
            )
            $invariantsBlock = ((@('full-pester-suite-no-new-failures', 'test-diff-integrity') + @($ExtraInvariants)) | ForEach-Object { "  - $_" }) -join "`n"
            @"
schema_version: 1
issue: 873
contract_hash: "$Hash"
targets:
  - id: T1
    ac_ref: AC1
    category: structure-presence
    check: "$CheckCommand"
    expected: "exit 0"
    falsifier: "A vacuous pass would look like the check never actually running."
    source: null
invariants:
$invariantsBlock
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

        function script:New-GCApprovedContractBody {
            param(
                [Parameter(Mandatory = $false)][string]$CheckCommand = 'exit 0',
                [Parameter(Mandatory = $false)][string[]]$ExtraInvariants = @()
            )
            $draft = script:New-GCContractPayloadForHash -Hash $script:PlaceholderHash -CheckCommand $CheckCommand -ExtraInvariants $ExtraInvariants
            $realHash = Get-GCContractHash -Payload $draft
            return (script:New-GCContractPayloadForHash -Hash $realHash -CheckCommand $CheckCommand -ExtraInvariants $ExtraInvariants)
        }

        function script:New-GCPlanCommentBody {
            param([Parameter(Mandatory)][string]$ContractPayload)
            return "<!-- plan-issue-873 -->`n<!-- goal-contract`n$ContractPayload`n-->"
        }

        # Wires a mocked `gh` returning the given approved-contract body onto
        # issue 873 at $Repo, in one call.
        function script:New-GCMockGhForContract {
            param([Parameter(Mandatory)][string]$MockGhPath, [Parameter(Mandatory)][string]$ContractPayload)
            $body = script:New-GCPlanCommentBody -ContractPayload $ContractPayload
            $commentsJson = "[$(script:New-CommentJson -Body $body -Id 1)]"
            script:New-MockGh -Path $MockGhPath -CommentsJsonArray $commentsJson
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

        It 'resolves the remote from the SUPPLIED -RepoRoot, not process CWD, and honors -GitCliPath (R7)' {
            script:Assert-GCVFunctionExists -Name 'Get-GCPinnedCommentBody'
            $repoA = Join-Path $TestDrive 'r7-repo-a'
            $repoB = Join-Path $TestDrive 'r7-repo-b'
            New-Item -ItemType Directory -Path $repoA -Force | Out-Null
            New-Item -ItemType Directory -Path $repoB -Force | Out-Null
            & git -C $repoA init -q -b main . 2>&1 | Out-Null
            & git -C $repoA remote add origin 'https://github.com/owner-a/repo-a.git' 2>&1 | Out-Null
            & git -C $repoB init -q -b main . 2>&1 | Out-Null
            & git -C $repoB remote add origin 'https://github.com/owner-b/repo-b.git' 2>&1 | Out-Null

            $mockGhPath = Join-Path $TestDrive 'gh-r7-remote.ps1'
            $commentsJson = "[$(script:New-CommentJson -Body '<!-- plan-issue-873 --> no block' -Id 1)]"
            script:New-MockGh -Path $mockGhPath -CommentsJsonArray $commentsJson

            Push-Location $repoA
            try {
                $null = Get-GCPinnedCommentBody -Issue 873 -Marker '<!-- plan-issue-873 -->' -RepoRoot $repoB -GhCliPath $mockGhPath -WarningAction SilentlyContinue
            } finally {
                Pop-Location
            }

            $recordedArgs = Get-Content -LiteralPath "$mockGhPath.args" -Raw
            $recordedArgs | Should -Match 'owner-b/repo-b' -Because 'the remote must resolve from -RepoRoot (repoB), not the process CWD (repoA)'
            $recordedArgs | Should -Not -Match 'owner-a/repo-a'
        }

        It 'honors a -GitCliPath override for the remote-resolution call, never the hardcoded literal git (R7)' {
            script:Assert-GCVFunctionExists -Name 'Get-GCPinnedCommentBody'
            $repo = script:New-GCTestRepo -Path (Join-Path $TestDrive 'r7-gitclipath-repo')
            & git -C $repo remote add origin 'https://github.com/owner-c/repo-c.git' 2>&1 | Out-Null

            $mockGitPath = Join-Path $TestDrive 'r7-git-forward.ps1'
            @'
param()
$args -join ' ' | Out-File -FilePath ($PSCommandPath + '.calls') -Encoding UTF8 -Append
& git @args
exit $LASTEXITCODE
'@ | Set-Content -LiteralPath $mockGitPath -Encoding UTF8

            $mockGhPath = Join-Path $TestDrive 'gh-r7-gitclipath.ps1'
            $commentsJson = "[$(script:New-CommentJson -Body '<!-- plan-issue-873 --> no block' -Id 1)]"
            script:New-MockGh -Path $mockGhPath -CommentsJsonArray $commentsJson

            $null = Get-GCPinnedCommentBody -Issue 873 -Marker '<!-- plan-issue-873 -->' -RepoRoot $repo -GitCliPath $mockGitPath -GhCliPath $mockGhPath -WarningAction SilentlyContinue

            (Test-Path -LiteralPath "$mockGitPath.calls") | Should -Be $true -Because 'the remote-resolution call must go through the supplied -GitCliPath, never a hardcoded literal git binary'
            $recordedGitArgs = Get-Content -LiteralPath "$mockGitPath.calls" -Raw
            $recordedGitArgs | Should -Match 'config --get remote.origin.url'
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

        It 'passes intake and reaches Get-GCContractHash validation when the contract_hash matches the canonicalized payload digest' {
            # This test previously stopped at s1's provisional pass (no
            # worktree/suite/checks/diff-integrity existed yet). Now that s6
            # wires the full pipeline into Invoke-GoalContractValidate's
            # body, the intake-gate contract this test is actually
            # responsible for (hash validation reaches Get-GCContractHash
            # and is not refused) is verified against a real disposable
            # -worktree-capable fixture repo instead of the invoking repo --
            # the full end-to-end pass/fail/review-required disposition
            # space is the dedicated 's6 -- AC2 integration fixtures'
            # Context below (Part F), not this intake-focused case.
            script:Assert-GCVFunctionExists -Name 'Invoke-GoalContractValidate'
            script:Assert-GCVFunctionExists -Name 'Get-GCContractHash'
            $mockGhPath = Join-Path $TestDrive 'gh-real-hash.ps1'
            $fixtureRepo = script:New-GCFixtureRepo -Path (Join-Path $TestDrive 'intake-hash-ok-repo')

            $approvedPayload = script:New-GCApprovedContractBody
            script:New-GCMockGhForContract -MockGhPath $mockGhPath -ContractPayload $approvedPayload

            $verdict = Invoke-GoalContractValidate -Issue 873 -RepoRoot $fixtureRepo -Repo 'example-owner/example-repo' -GhCliPath $mockGhPath -DiffDefaultRef 'main' -MinTestCount 1 -WarningAction SilentlyContinue

            # The hash gate passed (never refused as contract-hash-mismatch
            # or contract-not-approved); at HEAD == main (no run commit yet)
            # the diff-integrity phase itself refuses no-run-diff, which
            # this test intentionally treats as proof the hash gate was
            # cleared, not as an assertion about the eventual disposition.
            $refusalsJoined = ($verdict.Refusals -join ' ')
            $refusalsJoined | Should -Not -Match 'contract-hash-mismatch'
            $refusalsJoined | Should -Not -Match 'contract-not-approved'
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

        It 'routes an intake-refusal return through New-GCVerdictReport, so it carries the SAME 6-field shape (incl. Flags) every other verdict path produces (R1)' {
            script:Assert-GCVFunctionExists -Name 'Invoke-GoalContractValidate'
            $mockGhPath = Join-Path $TestDrive 'gh-r1-field-shape.ps1'
            $commentsJson = "[$(script:New-CommentJson -Body 'unrelated' -Id 1)]"
            script:New-MockGh -Path $mockGhPath -CommentsJsonArray $commentsJson

            $verdict = Invoke-GoalContractValidate -Issue 873 -RepoRoot $script:RepoRoot -Repo 'example-owner/example-repo' -GhCliPath $mockGhPath -WarningAction SilentlyContinue

            $json = $verdict | ConvertTo-Json -Depth 10 -Compress
            $parsed = $json | ConvertFrom-Json
            $fieldNames = @($parsed.PSObject.Properties.Name | Sort-Object)
            $fieldNames | Should -Be @('ExitCode', 'Flags', 'Reason', 'Refusals', 'Targets', 'Verdict') -Because 'every intake-refusal return must go through New-GCVerdictReport, the single exit point, so it carries the identical field-locked shape (incl. Flags) every other path produces'
        }

        It 'inert-renders (fence-wraps) refusal text on the intake-refusal path, same as every other verdict path (R1)' {
            script:Assert-GCVFunctionExists -Name 'Invoke-GoalContractValidate'
            $mockGhPath = Join-Path $TestDrive 'gh-r1-inert-render.ps1'
            $body = "<!-- plan-issue-873 -->`n<!-- goal-contract`nschema_version: 99`nissue: 873`n-->"
            $commentsJson = "[$(script:New-CommentJson -Body $body -Id 1)]"
            script:New-MockGh -Path $mockGhPath -CommentsJsonArray $commentsJson

            $verdict = Invoke-GoalContractValidate -Issue 873 -RepoRoot $script:RepoRoot -Repo 'example-owner/example-repo' -GhCliPath $mockGhPath -WarningAction SilentlyContinue

            $verdict.Verdict | Should -Be 'refused'
            @($verdict.Refusals).Count | Should -BeGreaterThan 0
            $verdict.Refusals[0] | Should -Match '^`{3,}' -Because 'the intake-refusal path must route through New-GCVerdictReport (which fence-wraps every refusal string via Format-GCInertRender), never return the raw unwrapped disposition text -- this proves New-GCVerdictReport is the single exit point, not bypassed on this path'
            ($verdict.Refusals -join ' ') | Should -Match 'contract-schema-violation'
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

        It 'fails CLOSED (IsClean = $false), never open, when the git invocation itself fails (R3)' {
            script:Assert-GCVFunctionExists -Name 'Test-GCTreeClean'
            # An invalid/nonexistent path makes `git -C <path> status` fail
            # with a non-zero exit and empty stdout -- the exact shape that
            # previously read as IsClean=$true (a false "clean" report).
            $badPath = Join-Path $TestDrive 'r3-does-not-exist-path'

            $result = Test-GCTreeClean -Path $badPath -WarningAction SilentlyContinue

            $result.IsClean | Should -Be $false -Because 'a failed git invocation (corrupted index, stale lock, invalid path) must never be silently read as clean'
            @($result.Porcelain).Count | Should -BeGreaterThan 0
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

        It 'never lets native git worktree add/remove/prune stdout chatter pollute a structurally-consumed return value (R18)' {
            script:Assert-GCVFunctionExists -Name 'New-GCDisposableWorktree'
            script:Assert-GCVFunctionExists -Name 'Remove-GCDisposableWorktree'
            $repo = script:New-GCTestRepo -Path (Join-Path $TestDrive 'r18-stdout-chatter-repo')
            $mockGitPath = Join-Path $TestDrive 'r18-git-chatter.ps1'
            # A smart forwarding mock that ALSO writes chatter to stdout
            # (never stderr) before forwarding worktree add/remove/prune to
            # the real git binary -- simulating a future git version or
            # platform difference that emits progress text to stdout.
            @'
param()
$argsJoined = $args -join ' '
if ($argsJoined -match 'worktree (add|remove|prune)') {
    Write-Output 'chatter: some progress message on stdout'
}
& git @args
exit $LASTEXITCODE
'@ | Set-Content -LiteralPath $mockGitPath -Encoding UTF8

            $createResult = New-GCDisposableWorktree -RepoRoot $repo -GitCliPath $mockGitPath
            try {
                $createResult.Success | Should -Be $true -Because 'stdout chatter on worktree add must never be mistaken for a failure signal'
                $createResult.Success.GetType().Name | Should -Be 'Boolean' -Because 'Success must remain a scalar bool, never an array polluted by leaked native-command stdout'

                $removeResult = Remove-GCDisposableWorktree -RepoRoot $repo -WorktreePath $createResult.Path -GitCliPath $mockGitPath
                $removeResult.Removed | Should -Be $true
                $removeResult.Removed.GetType().Name | Should -Be 'Boolean' -Because 'Removed must remain a scalar bool, never an array polluted by leaked stdout chatter from worktree remove/prune'
            } finally {
                script:Remove-GCTestWorktree -RepoRoot $repo -WorktreePath $createResult.Path
            }
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

        It 'degrades to $null instead of throwing an Int32-overflow for an oversized value (R21)' {
            script:Assert-GCVFunctionExists -Name 'ConvertTo-GCWallClockSeconds'
            { ConvertTo-GCWallClockSeconds -Value '99999999999h' } | Should -Not -Throw -Because 'a bare [int] cast Int32-overflows on this magnitude, reachable via the untrusted budget.wall_clock contract field'
            ConvertTo-GCWallClockSeconds -Value '99999999999h' | Should -BeNullOrEmpty
        }

        It 'degrades to $null instead of throwing when an in-range magnitude''s h-scaled result would itself Int32-overflow (R21)' {
            script:Assert-GCVFunctionExists -Name 'ConvertTo-GCWallClockSeconds'
            # 999999999 fits in Int32 on its own, but *3600 overflows Int32.
            { ConvertTo-GCWallClockSeconds -Value '999999999h' } | Should -Not -Throw
            ConvertTo-GCWallClockSeconds -Value '999999999h' | Should -BeNullOrEmpty
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

        # F1/F2 (HIGH, CE-Gate findings): the three cases above all use a
        # [pscustomobject] fixture, on which $Target.PSObject.Properties.
        # Match('falsifier') happens to work -- so they stayed green while
        # the falsifier-presence gate was 100% broken on the REAL shape
        # ConvertFrom-GCContractBlock -> ConvertFrom-Yaml actually returns:
        # a [System.Collections.Hashtable]. On a Hashtable,
        # .PSObject.Properties.Match() enumerates the CLR TYPE's own members
        # (Keys, Values, Count, ...), never the hashtable's own keys, so the
        # match count is always 0 regardless of what the hashtable actually
        # contains. These three cases re-run the identical assertions
        # against literal Hashtable-shaped targets to close that
        # fixture/production type-shape divergence gap -- proving the fixed
        # helper (script:Test-GCPropertyPresent) is genuinely shape-tolerant
        # in both directions, not just re-fixed for the shape that already
        # passed.
        It 'flags a Hashtable-shaped target with no falsifier key as advisory, without changing its pass outcome (F1/F2 real-shape coverage)' {
            script:Assert-GCVFunctionExists -Name 'Invoke-GCTargetCheck'
            $target = @{ id = 'T-no-falsifier-hash'; check = 'exit 0' }

            $result = Invoke-GCTargetCheck -Target $target -WorktreePath $TestDrive -TimeoutSeconds 5

            $result.Outcome | Should -Be 'pass' -Because 'falsifier-absent is purely informational and must never change the pass/fail outcome'
            $result.AdvisoryFlags | Should -Contain 'falsifier-absent'
        }

        It 'flags a Hashtable-shaped target with a blank falsifier key as advisory too (F1/F2 real-shape coverage)' {
            script:Assert-GCVFunctionExists -Name 'Invoke-GCTargetCheck'
            $target = @{ id = 'T-blank-falsifier-hash'; check = 'exit 0'; falsifier = '   ' }

            $result = Invoke-GCTargetCheck -Target $target -WorktreePath $TestDrive -TimeoutSeconds 5

            $result.AdvisoryFlags | Should -Contain 'falsifier-absent'
        }

        It 'does not flag falsifier-absent when a Hashtable-shaped target carries a non-blank falsifier key (F1/F2 real-shape coverage, the exact production regression: this must NOT read as absent)' {
            script:Assert-GCVFunctionExists -Name 'Invoke-GCTargetCheck'
            $target = @{ id = 'T-has-falsifier-hash'; check = 'exit 0'; falsifier = 'would look like an accumulator silently resetting null to zero' }

            $result = Invoke-GCTargetCheck -Target $target -WorktreePath $TestDrive -TimeoutSeconds 5

            $result.AdvisoryFlags | Should -Not -Contain 'falsifier-absent' -Because 'a real Hashtable key with genuine content must be detected -- the pre-fix .PSObject.Properties.Match() check always reported this as absent regardless of content'
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

        It 'fails closed (never throws) for a PRESENT-but-$null ExitCode/TotalFailed -- the false-GREEN a bare [int] cast previously produced (R10)' {
            script:Assert-GCVFunctionExists -Name 'Test-GCSuiteGatePass'
            $result = [pscustomobject]@{ ExitCode = $null; TotalFailed = $null; TotalPassed = 250 }

            { Test-GCSuiteGatePass -Result $result } | Should -Not -Throw
            Test-GCSuiteGatePass -Result $result | Should -Be $false -Because 'a bare [int] cast silently coerces $null to 0, which previously false-GREENed this exact shape'
        }

        It 'fails closed (never throws) for a non-numeric ExitCode, which previously threw instead of failing closed (R10)' {
            script:Assert-GCVFunctionExists -Name 'Test-GCSuiteGatePass'
            $result = [pscustomobject]@{ ExitCode = 'not-a-number'; TotalFailed = 0; TotalPassed = 250 }

            { Test-GCSuiteGatePass -Result $result } | Should -Not -Throw -Because 'this function''s documented contract is "never throws, fails closed to $false"'
            Test-GCSuiteGatePass -Result $result | Should -Be $false
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

        It 'fails CLOSED toward MORE review (Flagged = $true), never "nothing changed", when the git diff invocation fails (R4)' {
            script:Assert-GCVFunctionExists -Name 'Test-GCTestFileDeletion'
            # An invalid SHA makes the underlying `git diff` fail with a
            # non-zero exit and empty stdout -- the exact shape that
            # previously read as Flagged=$false ("nothing changed").
            $repo = script:New-GCTestRepo -Path (Join-Path $TestDrive 'r4-deletion-git-error-repo')

            $result = Test-GCTestFileDeletion -WorktreePath $repo -BaseSha 'not-a-real-sha' -RunSha 'also-not-a-real-sha' -AllowlistPathspecs @('.') -WarningAction SilentlyContinue

            $result.Flagged | Should -Be $true -Because 'this is an advisory mandatory-review flag, never a hard gate -- erring toward MORE review-flagging on a git failure is the safe direction'
        }

        It 'PF2: surfaces the git-command failure via GitError/ErrorDetail, never inside DeletedFiles (never looking like a literal deleted-file path)' {
            script:Assert-GCVFunctionExists -Name 'Test-GCTestFileDeletion'
            $repo = script:New-GCTestRepo -Path (Join-Path $TestDrive 'pf2-deletion-git-error-repo')

            $result = Test-GCTestFileDeletion -WorktreePath $repo -BaseSha 'not-a-real-sha' -RunSha 'also-not-a-real-sha' -AllowlistPathspecs @('.') -WarningAction SilentlyContinue

            $result.GitError | Should -Be $true
            $result.ErrorDetail | Should -Not -BeNullOrEmpty
            @($result.DeletedFiles).Count | Should -Be 0 -Because 'the error sentinel must never masquerade as a literal deleted-file path in DeletedFiles'
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

        It 'includes a lib file referenced via an UNQUOTED bareword dot-source (no quotes at all) (R13)' {
            script:Assert-GCVFunctionExists -Name 'Get-GCHelperLibSet'
            $root = Join-Path $TestDrive 'r13-unquoted-repo'
            script:Write-GCFile -RepoPath $root -RelativePath '.github/scripts/lib/qux-core.ps1' -Content 'function Get-Qux { }'
            script:Write-GCFile -RepoPath $root -RelativePath '.github/scripts/Tests/qux.Tests.ps1' -Content @'
. $PSScriptRoot/../lib/qux-core.ps1
'@

            $result = Get-GCHelperLibSet -RepoRoot $root

            $result | Should -Contain '.github/scripts/lib/qux-core.ps1' -Because 'an unquoted dot-source matches neither the quoted-literal branch nor the bare-variable-only indirection branch, and was previously silently missed'
        }

        It 'computes the set from the MERGE-BASE commit, not the run''s own live worktree state (R8)' {
            script:Assert-GCVFunctionExists -Name 'Get-GCHelperLibSet'
            $repo = script:New-GCTestRepo -Path (Join-Path $TestDrive 'r8-mergebase-repo')
            script:Write-GCFile -RepoPath $repo -RelativePath '.github/scripts/lib/evade-core.ps1' -Content 'function Get-Evade { 1 }'
            script:Write-GCFile -RepoPath $repo -RelativePath '.github/scripts/Tests/evade.Tests.ps1' -Content @'
. (Join-Path $PSScriptRoot '../lib/evade-core.ps1')
'@
            $baseSha = script:New-GCCommit -RepoPath $repo -Message 'base: helper referenced'

            # Adversarial run: de-reference the helper (drop the dot-source
            # line) from the live worktree state, simulating an attempt to
            # shrink the helper-lib allowlist before gutting the helper.
            script:Write-GCFile -RepoPath $repo -RelativePath '.github/scripts/Tests/evade.Tests.ps1' -Content "# no longer dot-sourced here`n"
            $null = script:New-GCCommit -RepoPath $repo -Message 'run: de-reference helper'

            $liveResult = Get-GCHelperLibSet -RepoRoot $repo
            $liveResult | Should -Not -Contain '.github/scripts/lib/evade-core.ps1' -Because 'the live worktree no longer references the helper -- this is exactly the evasion window R8 closes'

            $baseResult = Get-GCHelperLibSet -RepoRoot $repo -BaseSha $baseSha
            $baseResult | Should -Contain '.github/scripts/lib/evade-core.ps1' -Because 'the merge-base commit still referenced the helper, so it must stay in the allowlist regardless of what the run under audit did to shrink it'
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

        It 'fails CLOSED toward MORE review (Flagged = $true), never "nothing changed", when the git diff invocation fails (R4)' {
            script:Assert-GCVFunctionExists -Name 'Test-GCFixtureOrHelperModification'
            $repo = script:New-GCTestRepo -Path (Join-Path $TestDrive 'r4-fixture-git-error-repo')

            $result = Test-GCFixtureOrHelperModification -WorktreePath $repo -BaseSha 'not-a-real-sha' -RunSha 'also-not-a-real-sha' -HelperLibPaths @() -WarningAction SilentlyContinue

            $result.Flagged | Should -Be $true -Because 'this is an advisory mandatory-review flag, never a hard gate -- erring toward MORE review-flagging on a git failure is the safe direction'
        }

        It 'PF2: surfaces the git-command failure via GitError/ErrorDetail, never inside ChangedFiles (never looking like a literal changed-file path)' {
            script:Assert-GCVFunctionExists -Name 'Test-GCFixtureOrHelperModification'
            $repo = script:New-GCTestRepo -Path (Join-Path $TestDrive 'pf2-fixture-git-error-repo')

            $result = Test-GCFixtureOrHelperModification -WorktreePath $repo -BaseSha 'not-a-real-sha' -RunSha 'also-not-a-real-sha' -HelperLibPaths @() -WarningAction SilentlyContinue

            $result.GitError | Should -Be $true
            $result.ErrorDetail | Should -Not -BeNullOrEmpty
            @($result.ChangedFiles).Count | Should -Be 0 -Because 'the error sentinel must never masquerade as a literal changed-file path in ChangedFiles'
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

        It 'flags a diff-integrity-git-error mandatory-review flag, never a silently-empty changed-file list, when the changed-test-files diff invocation fails (R4)' {
            script:Assert-GCVFunctionExists -Name 'Invoke-GCDiffIntegrityPhase'
            $repo = script:New-GCTestRepo -Path (Join-Path $TestDrive 'r4-diffintegrity-git-error-repo')
            script:Write-GCFile -RepoPath $repo -RelativePath 'x.txt' -Content "x`n"
            $mainTip = script:New-GCCommit -RepoPath $repo -Message 'base state'
            & git -C $repo checkout -q -b feature 2>&1 | Out-Null
            script:Write-GCFile -RepoPath $repo -RelativePath 'x.txt' -Content "changed`n"
            $runSha = script:New-GCCommit -RepoPath $repo -Message 'run state'

            $mockGitPath = Join-Path $TestDrive 'r4-git-diff-fail.ps1'
            # Targets ONLY the raw changed-test-files diff this phase issues
            # directly (no --diff-filter, pathspec exactly
            # .github/scripts/Tests) -- never Test-GCTestFileDeletion's own
            # --diff-filter=DR call or Test-GCFixtureOrHelperModification's
            # fixtures/helper-pathspec call, both of which forward through
            # to the real git binary untouched.
            @'
param()
$argsJoined = $args -join ' '
if ($argsJoined -match 'diff --name-only' -and $argsJoined -notmatch 'diff-filter' -and $argsJoined -match '-- \.github/scripts/Tests$') {
    exit 128
}
& git @args
exit $LASTEXITCODE
'@ | Set-Content -LiteralPath $mockGitPath -Encoding UTF8

            $result = Invoke-GCDiffIntegrityPhase -WorktreePath $repo -RunSha $runSha -RepoRoot $repo -DefaultRef 'main' -GitCliPath $mockGitPath -WarningAction SilentlyContinue

            $result.Refused | Should -Be $false
            $kinds = @($result.Flags | ForEach-Object { $_.Kind })
            $kinds | Should -Contain 'diff-integrity-git-error' -Because 'a failed changed-test-files diff must never silently collapse to an empty list (which would make assertion-weakening detection quietly skip every file in this range) -- it must be surfaced as its own mandatory-review flag'
        }

        It 'PF2: routes a Test-GCTestFileDeletion git-command failure through the SAME dedicated diff-integrity-git-error Kind, never the test-file-deletion Kind' {
            script:Assert-GCVFunctionExists -Name 'Invoke-GCDiffIntegrityPhase'
            $repo = script:New-GCTestRepo -Path (Join-Path $TestDrive 'pf2-phase-deletion-git-error-repo')
            script:Write-GCFile -RepoPath $repo -RelativePath 'x.txt' -Content "x`n"
            $mainTip = script:New-GCCommit -RepoPath $repo -Message 'base state'
            & git -C $repo checkout -q -b feature 2>&1 | Out-Null
            script:Write-GCFile -RepoPath $repo -RelativePath 'x.txt' -Content "changed`n"
            $runSha = script:New-GCCommit -RepoPath $repo -Message 'run state'

            $mockGitPath = Join-Path $TestDrive 'pf2-git-deletion-diff-fail.ps1'
            # Targets ONLY Test-GCTestFileDeletion's own --diff-filter=DR
            # --no-renames call -- every other git invocation (including the
            # phase's own changed-test-files diff and
            # Test-GCFixtureOrHelperModification's call) forwards through to
            # the real git binary untouched.
            @'
param()
$argsJoined = $args -join ' '
if ($argsJoined -match 'diff-filter=DR') {
    exit 128
}
& git @args
exit $LASTEXITCODE
'@ | Set-Content -LiteralPath $mockGitPath -Encoding UTF8

            $result = Invoke-GCDiffIntegrityPhase -WorktreePath $repo -RunSha $runSha -RepoRoot $repo -DefaultRef 'main' -GitCliPath $mockGitPath -WarningAction SilentlyContinue

            $result.Refused | Should -Be $false
            $kinds = @($result.Flags | ForEach-Object { $_.Kind })
            $kinds | Should -Contain 'diff-integrity-git-error' -Because 'a Test-GCTestFileDeletion git-command failure must surface under the SAME dedicated Kind the other two git-error paths use'
            $kinds | Should -Not -Contain 'test-file-deletion' -Because 'a git-command failure must never be labeled with the Kind a real deletion finding would use'
            $errorFlag = $result.Flags | Where-Object { $_.Kind -eq 'diff-integrity-git-error' } | Select-Object -First 1
            $errorFlag.Detail | Should -Not -BeNullOrEmpty
            $errorFlag.PSObject.Properties.Match('Files').Count | Should -Be 0 -Because 'the dedicated error Kind carries Detail, never a Files array shaped like the real-finding Kinds'
        }

        It 'PF2: routes a Test-GCFixtureOrHelperModification git-command failure through the SAME dedicated diff-integrity-git-error Kind, never the fixture-or-helper-modification Kind' {
            script:Assert-GCVFunctionExists -Name 'Invoke-GCDiffIntegrityPhase'
            $repo = script:New-GCTestRepo -Path (Join-Path $TestDrive 'pf2-phase-fixture-git-error-repo')
            script:Write-GCFile -RepoPath $repo -RelativePath 'x.txt' -Content "x`n"
            $mainTip = script:New-GCCommit -RepoPath $repo -Message 'base state'
            & git -C $repo checkout -q -b feature 2>&1 | Out-Null
            script:Write-GCFile -RepoPath $repo -RelativePath 'x.txt' -Content "changed`n"
            $runSha = script:New-GCCommit -RepoPath $repo -Message 'run state'

            $mockGitPath = Join-Path $TestDrive 'pf2-git-fixture-diff-fail.ps1'
            # Targets ONLY Test-GCFixtureOrHelperModification's own pathspec
            # call (fixtures pathspec, no --diff-filter at all) -- every
            # other git invocation forwards through to the real git binary
            # untouched.
            @'
param()
$argsJoined = $args -join ' '
if ($argsJoined -match 'diff --name-only' -and $argsJoined -notmatch 'diff-filter' -and $argsJoined -match 'Tests/fixtures') {
    exit 128
}
& git @args
exit $LASTEXITCODE
'@ | Set-Content -LiteralPath $mockGitPath -Encoding UTF8

            $result = Invoke-GCDiffIntegrityPhase -WorktreePath $repo -RunSha $runSha -RepoRoot $repo -DefaultRef 'main' -GitCliPath $mockGitPath -WarningAction SilentlyContinue

            $result.Refused | Should -Be $false
            $kinds = @($result.Flags | ForEach-Object { $_.Kind })
            $kinds | Should -Contain 'diff-integrity-git-error' -Because 'a Test-GCFixtureOrHelperModification git-command failure must surface under the SAME dedicated Kind the other two git-error paths use'
            $kinds | Should -Not -Contain 'fixture-or-helper-modification' -Because 'a git-command failure must never be labeled with the Kind a real fixture/helper modification finding would use'
        }

        It 'grounds the helper-lib allowlist in the MERGE-BASE commit, so a run that de-references then guts a helper cannot evade test-file-deletion detection (R8)' {
            script:Assert-GCVFunctionExists -Name 'Invoke-GCDiffIntegrityPhase'
            $repo = script:New-GCTestRepo -Path (Join-Path $TestDrive 'r8-phase-evasion-repo')
            script:Write-GCFile -RepoPath $repo -RelativePath '.github/scripts/lib/evade-core.ps1' -Content 'function Get-Evade { 1 }'
            script:Write-GCFile -RepoPath $repo -RelativePath '.github/scripts/Tests/evade.Tests.ps1' -Content @'
. (Join-Path $PSScriptRoot '../lib/evade-core.ps1')
Describe 'Evade' { It 'x' { 1 | Should -Be 1 } }
'@
            $mainTip = script:New-GCCommit -RepoPath $repo -Message 'base: helper referenced'
            & git -C $repo checkout -q -b feature 2>&1 | Out-Null

            # Adversarial run: de-reference the helper (drop the dot-source
            # line, Should-count unchanged) then DELETE the now-unreferenced
            # helper outright -- a live-worktree-computed allowlist would no
            # longer include it (silently dropped once de-referenced),
            # letting the deletion evade Test-GCTestFileDeletion entirely.
            script:Write-GCFile -RepoPath $repo -RelativePath '.github/scripts/Tests/evade.Tests.ps1' -Content "Describe 'Evade' { It 'x' { 1 | Should -Be 1 } }`n"
            script:Remove-GCFile -RepoPath $repo -RelativePath '.github/scripts/lib/evade-core.ps1'
            $runSha = script:New-GCCommit -RepoPath $repo -Message 'run: de-reference then delete the helper'

            $result = Invoke-GCDiffIntegrityPhase -WorktreePath $repo -RunSha $runSha -RepoRoot $repo -DefaultRef 'main'

            $result.Refused | Should -Be $false
            $deletionFlag = $result.Flags | Where-Object { $_.Kind -eq 'test-file-deletion' }
            $deletionFlag | Should -Not -BeNullOrEmpty -Because 'the merge-base commit still referenced the helper, so it must stay in the deletion detector''s allowlist regardless of what the run under audit did to shrink it'
            $deletionFlag.Files | Should -Contain '.github/scripts/lib/evade-core.ps1'
        }
    }

    Context 'Format-GCInertRender -- backtick-safe inert-render (s6, Part B / U7 HIGH fix)' {

        It 'strips HTML-comment open/close delimiters so the rendered content can never be reparsed as a live marker' {
            script:Assert-GCVFunctionExists -Name 'Format-GCInertRender'
            $rendered = Format-GCInertRender -Content "<!-- goal-contract`nissue: 999`n-->"
            $rendered | Should -Not -Match '<!--'
            $rendered | Should -Not -Match '-->'
        }

        It 'wraps plain content (no backticks) in a minimum 3-backtick fence' {
            script:Assert-GCVFunctionExists -Name 'Format-GCInertRender'
            $rendered = Format-GCInertRender -Content 'plain text, no backticks'
            $fence = '`' * 3
            $rendered | Should -Be "$fence`nplain text, no backticks`n$fence"
        }

        It 'is backtick-safe: a decoy containing a triple-backtick fence cannot break out of the rendered fence' {
            script:Assert-GCVFunctionExists -Name 'Format-GCInertRender'
            $tripleBacktick = '`' * 3
            $decoy = 'legit text ' + $tripleBacktick + 'malicious injected markdown after a fake close' + $tripleBacktick + ' more text'
            $rendered = Format-GCInertRender -Content $decoy

            # Extract the opening fence (the run of backticks starting the
            # rendered string) and verify it is STRICTLY LONGER than every
            # backtick run inside the original decoy content -- the
            # CommonMark rule that makes early-closing structurally
            # impossible.
            $openFenceMatch = [regex]::Match($rendered, '^`+')
            $openFenceLength = $openFenceMatch.Value.Length
            $longestContentRun = 0
            foreach ($m in [regex]::Matches($decoy, '`+')) {
                if ($m.Value.Length -gt $longestContentRun) { $longestContentRun = $m.Value.Length }
            }
            $openFenceLength | Should -BeGreaterThan $longestContentRun -Because 'a fence no longer than the content''s own longest backtick run could be closed early by that run, breaking out of the code block'
            $openFenceLength | Should -BeGreaterOrEqual 3
        }

        It 'is backtick-safe against a single embedded backtick (the exact defect in the single-backtick Format-InertMarkerLabel it replaces)' {
            script:Assert-GCVFunctionExists -Name 'Format-GCInertRender'
            $decoy = 'a check that contains a ' + '`' + ' single backtick'
            $rendered = Format-GCInertRender -Content $decoy

            $openFenceMatch = [regex]::Match($rendered, '^`+')
            $openFenceMatch.Value.Length | Should -BeGreaterThan 1 -Because 'phase-containment-emission-check.ps1:148-152''s single-backtick wrap breaks out on exactly this content shape'
        }

        It 'never throws for $null content (PowerShell coerces a $null-bound [string] parameter to empty string, so this renders the empty-content fence, not $null)' {
            script:Assert-GCVFunctionExists -Name 'Format-GCInertRender'
            { Format-GCInertRender -Content $null } | Should -Not -Throw
            $fence = '`' * 3
            Format-GCInertRender -Content $null | Should -Be "$fence`n`n$fence"
        }

        It 'preserves the content verbatim inside the fence -- only the fence-breaking risk is neutralized' {
            script:Assert-GCVFunctionExists -Name 'Format-GCInertRender'
            $content = "multi-line`ncontent with " + ('`' * 2) + ' two backticks'
            $rendered = Format-GCInertRender -Content $content
            $rendered | Should -Match ([regex]::Escape($content))
        }

        It 'strips nested/overlapping HTML-comment delimiters to a fixed point instead of reconstructing a live marker (R2 HIGH, live-reproduced)' {
            script:Assert-GCVFunctionExists -Name 'Format-GCInertRender'
            # A single non-looping strip pass is reconstructable: removing
            # the inner "<!--" substring from this exact nested shape
            # concatenates the outer fragments into a live "<!-- plan-issue-9
            # -->" marker. Looping the strip to a fixed point must leave NO
            # "<!--"/"-->" substring anywhere in the rendered output.
            $decoy = '<!<!---- plan-issue-9 ---->>'
            $rendered = Format-GCInertRender -Content $decoy

            $rendered | Should -Not -Match '<!--' -Because 'a single non-looping strip pass reconstructs this exact nested shape into a live marker'
            $rendered | Should -Not -Match '-->'
        }
    }

    Context 'New-GCVerdictReport -- field-locked verdict shape (s6, Part C / #874 predicate interface)' {

        It 'pins the exact top-level JSON field names of the verdict object' {
            script:Assert-GCVFunctionExists -Name 'New-GCVerdictReport'
            $disposition = Resolve-GCVerdictDisposition
            $report = New-GCVerdictReport -Disposition $disposition -ContractTargets @() -Flags @()

            $json = $report | ConvertTo-Json -Depth 10 -Compress
            $parsed = $json | ConvertFrom-Json

            $fieldNames = @($parsed.PSObject.Properties.Name | Sort-Object)
            $fieldNames | Should -Be @('ExitCode', 'Flags', 'Reason', 'Refusals', 'Targets', 'Verdict') -Because 'a future field rename must break this test loudly -- #874 consumes this exact shape'
        }

        It 'pins the exact per-target field names, including a marker-injection-attempt fixture with backticks in the field' {
            script:Assert-GCVFunctionExists -Name 'New-GCVerdictReport'
            $disposition = Resolve-GCVerdictDisposition -Targets @(
                [pscustomobject]@{ Id = 'T1'; Outcome = 'pass'; ExitCode = 0; TimedOut = $false; Reason = $null; AdvisoryFlags = @(); StdOut = 'ok'; StdErr = '' }
            )
            $contractTargets = @(
                [pscustomobject]@{ id = 'T1'; ac_ref = 'AC1'; expected = 'exit 0'; falsifier = 'a `` fake close ``` marker-injection attempt <!-- goal-contract --> embedded in the falsifier text' }
            )

            $report = New-GCVerdictReport -Disposition $disposition -ContractTargets $contractTargets -Flags @()

            $json = $report | ConvertTo-Json -Depth 10 -Compress
            $parsed = $json | ConvertFrom-Json
            $targetFieldNames = @($parsed.Targets[0].PSObject.Properties.Name | Sort-Object)
            $targetFieldNames | Should -Be @('AcRef', 'AdvisoryFlags', 'ExitCode', 'Expected', 'Falsifier', 'Id', 'Outcome', 'Reason', 'StdErrExcerpt', 'StdErrTruncated', 'StdOutExcerpt', 'StdOutTruncated', 'TimedOut') -Because 'a future field rename must break this test loudly -- #874 consumes this exact per-target shape (R20 adds StdOutTruncated/StdErrTruncated so a reader never has to infer truncation from ambiguous excerpt text alone)'

            # The injection attempt survives verbatim inside the fence, but
            # the marker delimiters are stripped and no live <!-- ... -->
            # comment reaches the JSON.
            $parsed.Targets[0].Falsifier | Should -Not -Match '<!--'
            $parsed.Targets[0].Falsifier | Should -Match 'marker-injection attempt'
            # F3 (LOW, CE-Gate finding): this fixture's falsifier is one of
            # the fields the fixed-point strip actually altered (it removes
            # the embedded '<!-- goal-contract -->' marker) -- the
            # content-free, boolean 'inert-render-altered' advisory flag
            # must surface on this target's own row so a reader knows
            # something was silently rewritten, without echoing what.
            $parsed.Targets[0].AdvisoryFlags | Should -Contain 'inert-render-altered'
        }

        It 'flags AdvisoryFlags with inert-render-altered when the fixed-point strip silently rewrites benign "-->" arrow prose, not just a genuine marker-injection attempt (F3)' {
            script:Assert-GCVFunctionExists -Name 'New-GCVerdictReport'
            $disposition = Resolve-GCVerdictDisposition -Targets @(
                [pscustomobject]@{ Id = 'T1'; Outcome = 'pass'; ExitCode = 0; TimedOut = $false; Reason = $null; AdvisoryFlags = @(); StdOut = ''; StdErr = '' }
            )
            $contractTargets = @(
                [pscustomobject]@{ id = 'T1'; ac_ref = 'AC1'; expected = 'exit 0'; falsifier = 'benign prose using the arrow shape: went from 3 --> 0, not a marker' }
            )

            $report = New-GCVerdictReport -Disposition $disposition -ContractTargets $contractTargets -Flags @()

            $report.Targets[0].AdvisoryFlags | Should -Contain 'inert-render-altered' -Because 'the fixed-point strip silently alters legitimate "-->" arrow prose with no other indicator to the reader; the flag must surface this content-free, without echoing the original or stripped text'
            $report.Targets[0].Falsifier | Should -Not -Match '-->' -Because 'the flag is an indicator only -- it must never weaken or bypass the R2/U7 fixed-point strip itself'
        }

        It 'does not set inert-render-altered when no target field contains HTML-comment delimiters' {
            script:Assert-GCVFunctionExists -Name 'New-GCVerdictReport'
            $disposition = Resolve-GCVerdictDisposition -Targets @(
                [pscustomobject]@{ Id = 'T1'; Outcome = 'pass'; ExitCode = 0; TimedOut = $false; Reason = $null; AdvisoryFlags = @(); StdOut = 'ok'; StdErr = '' }
            )
            $contractTargets = @(
                [pscustomobject]@{ id = 'T1'; ac_ref = 'AC1'; expected = 'exit 0'; falsifier = 'a clean falsifier with no comment-delimiter shapes' }
            )

            $report = New-GCVerdictReport -Disposition $disposition -ContractTargets $contractTargets -Flags @()

            $report.Targets[0].AdvisoryFlags | Should -Not -Contain 'inert-render-altered' -Because 'the advisory flag must only fire when a strip genuinely occurred, never unconditionally'
        }

        It 'surfaces StdOutTruncated/StdErrTruncated explicitly on the report, distinct from the excerpt text itself (R20)' {
            script:Assert-GCVFunctionExists -Name 'New-GCVerdictReport'
            $disposition = Resolve-GCVerdictDisposition -Targets @(
                [pscustomobject]@{ Id = 'T1'; Outcome = 'pass'; ExitCode = 0; TimedOut = $false; Reason = $null; AdvisoryFlags = @(); StdOut = 'ok'; StdErr = ''; StdOutTruncated = $true; StdErrTruncated = $false }
            )

            $report = New-GCVerdictReport -Disposition $disposition -ContractTargets @() -Flags @()

            $report.Targets[0].StdOutTruncated | Should -Be $true
            $report.Targets[0].StdErrTruncated | Should -Be $false
        }

        It 'pins the exact per-flag field names' {
            script:Assert-GCVFunctionExists -Name 'New-GCVerdictReport'
            $disposition = Resolve-GCVerdictDisposition -HasReviewRequired -ReviewReason 'review-required: mandatory-review flags present (see Flags)'
            $flags = @([pscustomobject]@{ Kind = 'unrecognized-invariant'; Literal = 'custom-invariant' })

            $report = New-GCVerdictReport -Disposition $disposition -ContractTargets @() -Flags $flags

            $json = $report | ConvertTo-Json -Depth 10 -Compress
            $parsed = $json | ConvertFrom-Json
            $flagFieldNames = @($parsed.Flags[0].PSObject.Properties.Name | Sort-Object)
            $flagFieldNames | Should -Be @('Detail', 'Kind')
            $parsed.Flags[0].Detail | Should -Match 'custom-invariant'
        }

        It 'inert-renders each Files entry (git-diff-derived, attacker-influenceable filenames) before joining into Detail (R6)' {
            script:Assert-GCVFunctionExists -Name 'New-GCVerdictReport'
            $disposition = Resolve-GCVerdictDisposition -HasReviewRequired -ReviewReason 'review-required: mandatory-review flags present (see Flags)'
            $flags = @([pscustomobject]@{ Kind = 'test-file-deletion'; Files = @('<!-- plan-issue-9 -->normal-file.Tests.ps1') })

            $report = New-GCVerdictReport -Disposition $disposition -ContractTargets @() -Flags $flags

            $report.Flags[0].Detail | Should -Not -Match '<!--' -Because 'a git-diff-derived filename is content from the audited run''s own tree and must be inert-rendered before being echoed, same as every other field in this function'
            $report.Flags[0].Detail | Should -Match 'normal-file.Tests.ps1'
        }

        It 'formats assertion-weakening Files entries (pscustomobject, not plain strings) into readable path+count text instead of an empty string (R14)' {
            script:Assert-GCVFunctionExists -Name 'New-GCVerdictReport'
            $disposition = Resolve-GCVerdictDisposition -HasReviewRequired -ReviewReason 'review-required: mandatory-review flags present (see Flags)'
            $flags = @([pscustomobject]@{
                    Kind  = 'assertion-weakening'
                    Files = @([pscustomobject]@{ Path = '.github/scripts/Tests/foo.Tests.ps1'; BaseCount = 3; RunCount = 1 })
                })

            $report = New-GCVerdictReport -Disposition $disposition -ContractTargets @() -Flags $flags

            $report.Flags[0].Detail | Should -Not -BeNullOrEmpty -Because 'a bare -join on a pscustomobject renders an empty string (ToString() returns ""), silently losing all path/count information'
            $report.Flags[0].Detail | Should -Match '\.github/scripts/Tests/foo\.Tests\.ps1'
            $report.Flags[0].Detail | Should -Match '3'
            $report.Flags[0].Detail | Should -Match '1'
        }

        It 'documents the exit-3 loop contract: pass-review-required must never be treated as a plain pass by a harness loop' {
            script:Assert-GCVFunctionExists -Name 'New-GCVerdictReport'
            $disposition = Resolve-GCVerdictDisposition -HasReviewRequired -ReviewReason 'review-required: mandatory-review flags present (see Flags)'
            $report = New-GCVerdictReport -Disposition $disposition -ContractTargets @() -Flags @()

            $report.Verdict | Should -Be 'pass-review-required'
            $report.ExitCode | Should -Be 3
            $report.ExitCode | Should -Not -Be 0 -Because 'exit 3 is environmentally-accepted-but-human-review-mandatory, never a plain pass a harness loop can auto-continue on'
        }
    }

    Context 'Invoke-GCWorktreeSession -- DiffIntegrityPhase seam (s6, extends s2)' {

        It 'runs the diff-integrity phase AFTER the checks phase, still before teardown' {
            script:Assert-GCVFunctionExists -Name 'Invoke-GCWorktreeSession'
            $repo = script:New-GCTestRepo -Path (Join-Path $TestDrive 'diffphase-order-repo')
            $order = [System.Collections.Generic.List[string]]::new()
            # A List (reference type) captured by .GetNewClosure() can still
            # be MUTATED from inside the closure and observed afterward here
            # -- unlike a $script:-scoped scalar assignment, which
            # .GetNewClosure() redirects into the closure's own private
            # pseudo-script-scope and is therefore invisible outside it.
            $existedDuringDiffPhase = [System.Collections.Generic.List[bool]]::new()
            $suitePhase = { param($path) $order.Add('suite') }.GetNewClosure()
            $checksPhase = { param($path) $order.Add('checks') }.GetNewClosure()
            $diffPhase = {
                param($path)
                $order.Add('diff-integrity')
                $existedDuringDiffPhase.Add((Test-Path -LiteralPath $path))
            }.GetNewClosure()

            $session = Invoke-GCWorktreeSession -RepoRoot $repo -SuitePhase $suitePhase -ChecksPhase $checksPhase -DiffIntegrityPhase $diffPhase

            $session.Refused | Should -Be $false
            @($order) | Should -Be @('suite', 'checks', 'diff-integrity')
            $existedDuringDiffPhase[0] | Should -Be $true -Because 'the worktree must still exist while the diff-integrity phase runs'
        }

        It 'passes the worktree path to the diff-integrity phase scriptblock' {
            script:Assert-GCVFunctionExists -Name 'Invoke-GCWorktreeSession'
            $repo = script:New-GCTestRepo -Path (Join-Path $TestDrive 'diffphase-arg-repo')
            $script:seenDiffPath = $null
            $diffPhase = { param($path) $script:seenDiffPath = $path }

            $session = Invoke-GCWorktreeSession -RepoRoot $repo -DiffIntegrityPhase $diffPhase

            $script:seenDiffPath | Should -Be $session.WorktreePath
        }

        It 'surfaces the diff-integrity phase result on DiffIntegrityResult' {
            script:Assert-GCVFunctionExists -Name 'Invoke-GCWorktreeSession'
            $repo = script:New-GCTestRepo -Path (Join-Path $TestDrive 'diffphase-result-repo')
            $diffPhase = { param($path) [pscustomobject]@{ Refused = $false; Flags = @('marker') } }

            $session = Invoke-GCWorktreeSession -RepoRoot $repo -DiffIntegrityPhase $diffPhase

            $session.DiffIntegrityResult.Flags | Should -Be @('marker')
        }

        It 'still tears down the worktree via finally when the diff-integrity phase throws' {
            script:Assert-GCVFunctionExists -Name 'Invoke-GCWorktreeSession'
            $repo = script:New-GCTestRepo -Path (Join-Path $TestDrive 'diffphase-throw-repo')
            $script:capturedDiffPath = $null
            $diffPhase = {
                param($path)
                $script:capturedDiffPath = $path
                throw 'simulated diff-integrity-phase failure'
            }

            { Invoke-GCWorktreeSession -RepoRoot $repo -DiffIntegrityPhase $diffPhase } | Should -Throw '*simulated diff-integrity-phase failure*'

            $script:capturedDiffPath | Should -Not -BeNullOrEmpty
            (Test-Path -LiteralPath $script:capturedDiffPath) | Should -Be $false -Because 'teardown in finally must still remove the worktree even though the diff-integrity phase threw'
        }

        It 'never invokes the diff-integrity phase when the invoking tree is dirty' {
            script:Assert-GCVFunctionExists -Name 'Invoke-GCWorktreeSession'
            $repo = script:New-GCTestRepo -Path (Join-Path $TestDrive 'diffphase-dirty-repo')
            [System.IO.File]::WriteAllText((Join-Path $repo 'seed.txt'), "modified`n", [System.Text.UTF8Encoding]::new($false))
            $script:diffPhaseCalled = $false
            $diffPhase = { param($path) $script:diffPhaseCalled = $true }

            $session = Invoke-GCWorktreeSession -RepoRoot $repo -DiffIntegrityPhase $diffPhase -WarningAction SilentlyContinue

            $session.Refused | Should -Be $true
            $script:diffPhaseCalled | Should -Be $false
        }
    }

    Context 'Invoke-GoalContractValidate -- s6 AC2 integration fixtures (real disposable-worktree end-to-end)' -Tag 'integration' {

        It 'fixture 1: a passing contract (valid targets, valid checks, clean suite) validates pass end-to-end' {
            script:Assert-GCVFunctionExists -Name 'Invoke-GoalContractValidate'
            $repo = script:New-GCFixtureRepo -Path (Join-Path $TestDrive 'ac2-passing-repo')
            & git -C $repo checkout -q -b run-branch 2>&1 | Out-Null
            [System.IO.File]::WriteAllText((Join-Path $repo 'run-marker.txt'), "run change`n", [System.Text.UTF8Encoding]::new($false))
            & git -C $repo add -A 2>&1 | Out-Null
            & git -C $repo commit -q -m 'run state: unrelated harmless change' 2>&1 | Out-Null

            $mockGhPath = Join-Path $TestDrive 'gh-ac2-passing.ps1'
            $payload = script:New-GCApprovedContractBody
            script:New-GCMockGhForContract -MockGhPath $mockGhPath -ContractPayload $payload

            $verdict = Invoke-GoalContractValidate -Issue 873 -RepoRoot $repo -Repo 'example-owner/example-repo' -GhCliPath $mockGhPath -DiffDefaultRef 'main' -MinTestCount 1 -WarningAction SilentlyContinue

            $flagKinds = ($verdict.Flags | ForEach-Object { $_.Kind }) -join ', '
            $verdict.Verdict | Should -Be 'pass' -Because "verdict=$($verdict.Verdict) reason=$($verdict.Reason) refusals=$($verdict.Refusals -join '; ') flags=$flagKinds"
            $verdict.ExitCode | Should -Be 0
            @($verdict.Targets).Count | Should -Be 1
            $verdict.Targets[0].Outcome | Should -Be 'pass'
            @($verdict.Flags).Count | Should -Be 0

            # F1 (HIGH, CE-Gate finding): this fixture's contract YAML
            # (script:New-GCContractPayloadForHash) carries a genuine,
            # non-blank falsifier field. It is parsed through the REAL
            # production path -- ConvertFrom-GCContractBlock ->
            # ConvertFrom-Yaml -- which returns a [System.Collections.
            # Hashtable], not a [pscustomobject]. Prior to the F1 fix, the
            # falsifier-presence gate's bare .PSObject.Properties.Match()
            # check always read this Hashtable's real 'falsifier' key as
            # absent (Match() only sees a Hashtable's CLR TYPE members, never
            # its own keys), so every production run reported Falsifier as
            # null and an unconditional falsifier-absent advisory flag
            # regardless of contract content. This is the end-to-end,
            # real-Hashtable-shaped proof that the fix actually closes that
            # gap (not just the isolated Invoke-GCTargetCheck unit cases).
            $verdict.Targets[0].Falsifier | Should -Match 'A vacuous pass would look like the check never actually running' -Because 'the real Hashtable-shaped falsifier field must survive verbatim to the verdict'
            $verdict.Targets[0].AdvisoryFlags | Should -Not -Contain 'falsifier-absent' -Because 'a real non-blank falsifier parsed from Hashtable-shaped YAML must never be reported as absent'
        }

        It 'fixture 2: an assertion-count regression flags pass-review-required (never fail -- flags never block)' {
            script:Assert-GCVFunctionExists -Name 'Invoke-GoalContractValidate'
            $repo = script:New-GCFixtureRepo -Path (Join-Path $TestDrive 'ac2-assertion-regress-repo')
            & git -C $repo checkout -q -b run-branch 2>&1 | Out-Null
            # sample1.Tests.ps1 has 2 Should calls at base; the run state
            # weakens it to 1 (both versions still pass green).
            [System.IO.File]::WriteAllText((Join-Path $repo '.github/scripts/Tests/sample1.Tests.ps1'), "Describe 'Fixture' { It 'passes one' { 1 | Should -Be 1 } }`n", [System.Text.UTF8Encoding]::new($false))
            & git -C $repo add -A 2>&1 | Out-Null
            & git -C $repo commit -q -m 'run state: weaken assertion count' 2>&1 | Out-Null

            $mockGhPath = Join-Path $TestDrive 'gh-ac2-assertion-regress.ps1'
            $payload = script:New-GCApprovedContractBody
            script:New-GCMockGhForContract -MockGhPath $mockGhPath -ContractPayload $payload

            $verdict = Invoke-GoalContractValidate -Issue 873 -RepoRoot $repo -Repo 'example-owner/example-repo' -GhCliPath $mockGhPath -DiffDefaultRef 'main' -MinTestCount 1 -WarningAction SilentlyContinue

            $flagKinds = ($verdict.Flags | ForEach-Object { $_.Kind }) -join ', '
            $verdict.Verdict | Should -Be 'pass-review-required' -Because "verdict=$($verdict.Verdict) refusals=$($verdict.Refusals -join '; ') flags=$flagKinds"
            $verdict.ExitCode | Should -Be 3
            $flagKinds | Should -Match 'assertion-weakening'
        }

        It 'fixture 3: a fixture-file weakening flags pass-review-required' {
            script:Assert-GCVFunctionExists -Name 'Invoke-GoalContractValidate'
            $repo = script:New-GCFixtureRepo -Path (Join-Path $TestDrive 'ac2-fixture-weaken-repo')
            $fixturesDir = Join-Path $repo '.github/scripts/Tests/fixtures'
            New-Item -ItemType Directory -Path $fixturesDir -Force | Out-Null
            [System.IO.File]::WriteAllText((Join-Path $fixturesDir 'sample.json'), '{"strict":true}', [System.Text.UTF8Encoding]::new($false))
            & git -C $repo add -A 2>&1 | Out-Null
            & git -C $repo commit -q -m 'base: add fixture file' 2>&1 | Out-Null

            & git -C $repo checkout -q -b run-branch 2>&1 | Out-Null
            [System.IO.File]::WriteAllText((Join-Path $fixturesDir 'sample.json'), '{"strict":false}', [System.Text.UTF8Encoding]::new($false))
            & git -C $repo add -A 2>&1 | Out-Null
            & git -C $repo commit -q -m 'run state: weaken fixture' 2>&1 | Out-Null

            $mockGhPath = Join-Path $TestDrive 'gh-ac2-fixture-weaken.ps1'
            $payload = script:New-GCApprovedContractBody
            script:New-GCMockGhForContract -MockGhPath $mockGhPath -ContractPayload $payload

            $verdict = Invoke-GoalContractValidate -Issue 873 -RepoRoot $repo -Repo 'example-owner/example-repo' -GhCliPath $mockGhPath -DiffDefaultRef 'main' -MinTestCount 1 -WarningAction SilentlyContinue

            $flagKinds = ($verdict.Flags | ForEach-Object { $_.Kind }) -join ', '
            $verdict.Verdict | Should -Be 'pass-review-required' -Because "verdict=$($verdict.Verdict) refusals=$($verdict.Refusals -join '; ') flags=$flagKinds"
            $verdict.ExitCode | Should -Be 3
            $flagKinds | Should -Match 'fixture-or-helper-modification'
        }

        It 'fixture 4: uncommitted-only state refuses (refused: uncommitted-changes)' {
            script:Assert-GCVFunctionExists -Name 'Invoke-GoalContractValidate'
            $repo = script:New-GCFixtureRepo -Path (Join-Path $TestDrive 'ac2-uncommitted-repo')
            [System.IO.File]::WriteAllText((Join-Path $repo 'dirty.txt'), "uncommitted`n", [System.Text.UTF8Encoding]::new($false))

            $mockGhPath = Join-Path $TestDrive 'gh-ac2-uncommitted.ps1'
            $payload = script:New-GCApprovedContractBody
            script:New-GCMockGhForContract -MockGhPath $mockGhPath -ContractPayload $payload

            $verdict = Invoke-GoalContractValidate -Issue 873 -RepoRoot $repo -Repo 'example-owner/example-repo' -GhCliPath $mockGhPath -DiffDefaultRef 'main' -MinTestCount 1 -WarningAction SilentlyContinue

            $verdict.Verdict | Should -Be 'refused'
            $verdict.ExitCode | Should -Be 2
            ($verdict.Refusals -join ' ') | Should -Match 'uncommitted-changes'
        }

        It 'fixture 5: a hash-mismatched contract refuses (refused: contract-hash-mismatch)' {
            script:Assert-GCVFunctionExists -Name 'Invoke-GoalContractValidate'
            $repo = script:New-GCFixtureRepo -Path (Join-Path $TestDrive 'ac2-hash-mismatch-repo')

            $mockGhPath = Join-Path $TestDrive 'gh-ac2-hash-mismatch.ps1'
            $wrongHash = ('b' * 63) + 'c'
            $payload = script:New-GCContractPayloadForHash -Hash $wrongHash
            script:New-GCMockGhForContract -MockGhPath $mockGhPath -ContractPayload $payload

            $verdict = Invoke-GoalContractValidate -Issue 873 -RepoRoot $repo -Repo 'example-owner/example-repo' -GhCliPath $mockGhPath -DiffDefaultRef 'main' -MinTestCount 1 -WarningAction SilentlyContinue

            $verdict.Verdict | Should -Be 'refused'
            $verdict.ExitCode | Should -Be 2
            ($verdict.Refusals -join ' ') | Should -Match 'contract-hash-mismatch'
        }

        It 'fixture 6: merge-base == run-sha refuses (refused: no-run-diff)' {
            script:Assert-GCVFunctionExists -Name 'Invoke-GoalContractValidate'
            $repo = script:New-GCFixtureRepo -Path (Join-Path $TestDrive 'ac2-mergebase-eq-runsha-repo')
            # No divergence: HEAD stays on 'main' with no further commits, so
            # merge-base('main', HEAD) == HEAD == the run sha.

            $mockGhPath = Join-Path $TestDrive 'gh-ac2-no-run-diff.ps1'
            $payload = script:New-GCApprovedContractBody
            script:New-GCMockGhForContract -MockGhPath $mockGhPath -ContractPayload $payload

            $verdict = Invoke-GoalContractValidate -Issue 873 -RepoRoot $repo -Repo 'example-owner/example-repo' -GhCliPath $mockGhPath -DiffDefaultRef 'main' -MinTestCount 1 -WarningAction SilentlyContinue

            $verdict.Verdict | Should -Be 'refused'
            $verdict.ExitCode | Should -Be 2
            ($verdict.Refusals -join ' ') | Should -Match 'no-run-diff'
        }

        It 'fixture 7 (synthetic-red): a genuinely failing suite test fails under the green floor end-to-end' {
            script:Assert-GCVFunctionExists -Name 'Invoke-GoalContractValidate'
            $repo = script:New-GCFixtureRepo -Path (Join-Path $TestDrive 'ac2-synthetic-red-repo')
            & git -C $repo checkout -q -b run-branch 2>&1 | Out-Null
            [System.IO.File]::WriteAllText((Join-Path $repo '.github/scripts/Tests/redcase.Tests.ps1'), "Describe 'Fixture' { It 'fails on purpose' { 1 | Should -Be 2 } }`n", [System.Text.UTF8Encoding]::new($false))
            & git -C $repo add -A 2>&1 | Out-Null
            & git -C $repo commit -q -m 'run state: introduce a genuine red' 2>&1 | Out-Null

            $mockGhPath = Join-Path $TestDrive 'gh-ac2-synthetic-red.ps1'
            $payload = script:New-GCApprovedContractBody
            script:New-GCMockGhForContract -MockGhPath $mockGhPath -ContractPayload $payload

            $verdict = Invoke-GoalContractValidate -Issue 873 -RepoRoot $repo -Repo 'example-owner/example-repo' -GhCliPath $mockGhPath -DiffDefaultRef 'main' -MinTestCount 1 -WarningAction SilentlyContinue

            $verdict.Verdict | Should -Be 'fail' -Because "verdict=$($verdict.Verdict) refusals=$($verdict.Refusals -join '; ')"
            $verdict.ExitCode | Should -Be 1
        }

        It 'fixture 8 (R5): folds mandatory-review flags collected before a diff-integrity refusal into the refused verdict too, never dropping them silently' {
            script:Assert-GCVFunctionExists -Name 'Invoke-GoalContractValidate'
            $repo = script:New-GCFixtureRepo -Path (Join-Path $TestDrive 'r5-diffintegrity-refusal-repo')
            # No divergence: HEAD stays on main -> merge-base(main, HEAD) ==
            # HEAD == the run sha -> the diff-integrity phase refuses
            # no-run-diff (mirrors AC2 fixture 6). A target check that
            # sleeps past a deliberately tiny budget.wall_clock produces a
            # target-checks-budget-exceeded mandatory-review flag from the
            # SAME session, collected from the checks phase BEFORE that
            # refusal fires.
            $draftPayload = @"
schema_version: 1
issue: 873
contract_hash: "$($script:PlaceholderHash)"
targets:
  - id: T1
    ac_ref: AC1
    category: structure-presence
    check: "Start-Sleep -Milliseconds 1500; exit 0"
    expected: "exit 0"
    falsifier: "A vacuous pass would look like the check never actually running."
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
  wall_clock: "1s"
  chain_sub_ceiling: 2
  non_convergence: halt-report
"@
            $realHash = Get-GCContractHash -Payload $draftPayload
            $approvedPayload = $draftPayload -replace [regex]::Escape($script:PlaceholderHash), $realHash

            $mockGhPath = Join-Path $TestDrive 'gh-r5-diffintegrity-refusal.ps1'
            script:New-GCMockGhForContract -MockGhPath $mockGhPath -ContractPayload $approvedPayload

            $verdict = Invoke-GoalContractValidate -Issue 873 -RepoRoot $repo -Repo 'example-owner/example-repo' -GhCliPath $mockGhPath -DiffDefaultRef 'main' -MinTestCount 1 -WarningAction SilentlyContinue

            $verdict.Verdict | Should -Be 'refused' -Because "verdict=$($verdict.Verdict) reason=$($verdict.Reason) refusals=$($verdict.Refusals -join '; ')"
            ($verdict.Refusals -join ' ') | Should -Match 'no-run-diff'
            $flagKinds = @($verdict.Flags | ForEach-Object { $_.Kind })
            $flagKinds | Should -Contain 'target-checks-budget-exceeded' -Because 'a mandatory-review signal collected from the checks phase before the diff-integrity refusal fired must not be silently dropped just because the eventual disposition is a refusal'
        }

        It 'fixture 9 (R9): maps a previously-uncaught infra exception (a bad -PwshCliPath) to exit-3 infra-error, never an uncaught crash' {
            script:Assert-GCVFunctionExists -Name 'Invoke-GoalContractValidate'
            $repo = script:New-GCFixtureRepo -Path (Join-Path $TestDrive 'r9-infra-exception-repo')
            & git -C $repo checkout -q -b run-branch 2>&1 | Out-Null
            [System.IO.File]::WriteAllText((Join-Path $repo 'run-marker.txt'), "run change`n", [System.Text.UTF8Encoding]::new($false))
            & git -C $repo add -A 2>&1 | Out-Null
            & git -C $repo commit -q -m 'run state' 2>&1 | Out-Null

            $mockGhPath = Join-Path $TestDrive 'gh-r9-infra-exception.ps1'
            $payload = script:New-GCApprovedContractBody
            script:New-GCMockGhForContract -MockGhPath $mockGhPath -ContractPayload $payload

            $bogusPwshPath = Join-Path $TestDrive 'r9-does-not-exist-pwsh.exe'

            $script:r9Verdict = $null
            {
                $script:r9Verdict = Invoke-GoalContractValidate -Issue 873 -RepoRoot $repo -Repo 'example-owner/example-repo' -GhCliPath $mockGhPath -PwshCliPath $bogusPwshPath -DiffDefaultRef 'main' -MinTestCount 1 -WarningAction SilentlyContinue
            } | Should -Not -Throw -Because 'an infra exception from a bad -PwshCliPath must be caught and mapped to a disposition, never crash the caller (the wrapper script has no top-level try/catch)'

            $script:r9Verdict.Verdict | Should -Be 'pass-review-required'
            $script:r9Verdict.ExitCode | Should -Be 3
            $script:r9Verdict.Reason | Should -Match 'infra-error'
        }

        It 'fixture 10 (PF1): threads the PRE-CHECKS captured HeadSha into the diff-integrity phase as -RunSha, never a fresh post-checks rev-parse HEAD' {
            script:Assert-GCVFunctionExists -Name 'Invoke-GoalContractValidate'
            $repo = script:New-GCFixtureRepo -Path (Join-Path $TestDrive 'pf1-toctou-sha-repo')
            & git -C $repo checkout -q -b run-branch 2>&1 | Out-Null
            [System.IO.File]::WriteAllText((Join-Path $repo 'run-marker.txt'), "run change`n", [System.Text.UTF8Encoding]::new($false))
            & git -C $repo add -A 2>&1 | Out-Null
            & git -C $repo commit -q -m 'run state: unrelated harmless change' 2>&1 | Out-Null
            # The sha the worktree is actually checked out at BEFORE any
            # phase runs -- New-GCDisposableWorktree resolves this same value
            # via `rev-parse HEAD` on $RepoRoot at worktree-creation time.
            $preChecksHeadSha = (& git -C $repo rev-parse HEAD).Trim()

            # A malicious `check`: simulates the PF1 threat model directly --
            # targets[].check is untrusted comment-sourced content executed
            # with the worktree as its cwd (873-D7), so a check can commit
            # inside the worktree during the checks phase. That commit moves
            # the worktree's HEAD to a NEW sha while leaving `git status
            # --porcelain` EMPTY (the tamper is itself committed, so the R3
            # post-checks cleanliness assertion never fires).
            $checkCommand = 'git commit -q --allow-empty -m ''attacker: poison commit during checks phase''; exit 0'

            $mockGhPath = Join-Path $TestDrive 'gh-pf1-toctou-sha.ps1'
            $payload = script:New-GCApprovedContractBody -CheckCommand $checkCommand
            script:New-GCMockGhForContract -MockGhPath $mockGhPath -ContractPayload $payload

            Mock Invoke-GCDiffIntegrityPhase { [pscustomobject]@{ Refused = $false; RefusalReason = $null; DefaultSha = $null; MergeBaseSha = $null; Flags = @() } }

            $verdict = Invoke-GoalContractValidate -Issue 873 -RepoRoot $repo -Repo 'example-owner/example-repo' -GhCliPath $mockGhPath -DiffDefaultRef 'main' -MinTestCount 1 -WarningAction SilentlyContinue

            # The direct proof: the diff-integrity phase must have been
            # invoked with -RunSha equal to the sha captured BEFORE the
            # checks phase ran, never the attacker's poison-commit sha (which
            # would differ, since the check moved HEAD during the run).
            Should -Invoke Invoke-GCDiffIntegrityPhase -Times 1 -ParameterFilter { $RunSha -eq $preChecksHeadSha } -Because "diff-integrity must audit the pre-checks HeadSha ($preChecksHeadSha), never a post-checks re-resolved HEAD that a malicious check could have moved"
            $verdict.ExitCode | Should -Not -Be 2 -Because 'the run should have reached the worktree phases (a refusal here would mean the test setup itself is broken, not proving anything about PF1)'
        }

        It 'fixture 11 (PF1): a run that weakens an assertion, then "restores" it via a check-time commit, is STILL flagged assertion-weakening -- proving the audited sha is the pre-attack run state, not the attacker restore' {
            script:Assert-GCVFunctionExists -Name 'Invoke-GoalContractValidate'
            $repo = script:New-GCFixtureRepo -Path (Join-Path $TestDrive 'pf1-toctou-behavior-repo')
            & git -C $repo checkout -q -b run-branch 2>&1 | Out-Null
            # Run state: weaken sample1.Tests.ps1 from 2 Should calls down to
            # 1 (mirrors AC2 fixture 2's assertion-count regression). Both
            # versions still pass green, so the suite phase (which runs
            # BEFORE the checks phase, against this exact commit) is
            # unaffected either way.
            [System.IO.File]::WriteAllText((Join-Path $repo '.github/scripts/Tests/sample1.Tests.ps1'), "Describe 'Fixture' { It 'passes one' { 1 | Should -Be 1 } }`n", [System.Text.UTF8Encoding]::new($false))
            & git -C $repo add -A 2>&1 | Out-Null
            & git -C $repo commit -q -m 'run state: weaken assertion count' 2>&1 | Out-Null

            # The malicious check: during the CHECKS phase (which runs AFTER
            # the suite phase has already validated the weakened commit),
            # restore sample1.Tests.ps1 to its original 2-assertion content
            # and commit that "restoration" inside the worktree. If the
            # diff-integrity phase re-resolved RunSha fresh (the pre-fix
            # bug), it would audit THIS restore commit -- which reads
            # identical to the original base state, so the assertion-
            # weakening detector would find no regression and the run would
            # come back a false-clean pass-review-required-free 'pass'.
            #
            # The restore content is written to a fixture file OUTSIDE the
            # worktree (under $TestDrive) and the check merely copies it
            # into place -- this keeps the `check` string itself a single
            # line with no embedded double quotes or raw newlines, both of
            # which the contract's YAML double-quoted `check: "..."` scalar
            # cannot safely carry.
            $restoreSourcePath = Join-Path $TestDrive 'pf1-restore-sample1.Tests.ps1'
            [System.IO.File]::WriteAllText($restoreSourcePath, "Describe 'Fixture' { It 'passes one' { 1 | Should -Be 1; 2 | Should -Be 2 } }`n", [System.Text.UTF8Encoding]::new($false))
            $restoreSourceForwardSlash = $restoreSourcePath -replace '\\', '/'
            $checkCommand = "Copy-Item -LiteralPath '$restoreSourceForwardSlash' -Destination '.github/scripts/Tests/sample1.Tests.ps1' -Force; git add -A; git commit -q -m 'attacker: restore weakened assertion mid-run'; exit 0"

            $mockGhPath = Join-Path $TestDrive 'gh-pf1-toctou-behavior.ps1'
            $payload = script:New-GCApprovedContractBody -CheckCommand $checkCommand
            script:New-GCMockGhForContract -MockGhPath $mockGhPath -ContractPayload $payload

            $verdict = Invoke-GoalContractValidate -Issue 873 -RepoRoot $repo -Repo 'example-owner/example-repo' -GhCliPath $mockGhPath -DiffDefaultRef 'main' -MinTestCount 1 -WarningAction SilentlyContinue

            $flagKinds = ($verdict.Flags | ForEach-Object { $_.Kind }) -join ', '
            $verdict.Verdict | Should -Be 'pass-review-required' -Because "the fix must audit the PRE-CHECKS weakened-assertion commit, not the attacker's mid-run restore commit; a 'pass' here would mean the false-GREEN vector is still open. verdict=$($verdict.Verdict) reason=$($verdict.Reason) refusals=$($verdict.Refusals -join '; ') flags=$flagKinds"
            $flagKinds | Should -Match 'assertion-weakening' -Because 'the weakened-assertion regression committed BEFORE the checks phase ran must still be detected even though a check-time commit later reverted it in the worktree'
        }
    }

    Context 'goal-contract-validate.ps1 -- thin wrapper smoke test (s6, Part D)' -Tag 'integration' {

        BeforeAll {
            $script:WrapperFile = Join-Path $script:RepoRoot '.github/scripts/goal-contract-validate.ps1'
        }

        It 'the wrapper script file exists' {
            (Test-Path -LiteralPath $script:WrapperFile -PathType Leaf) | Should -Be $true
        }

        It 'does not declare a -MinTestCount parameter on its public CLI surface (Part E)' {
            $wrapperAst = [System.Management.Automation.Language.Parser]::ParseFile($script:WrapperFile, [ref]$null, [ref]$null)
            $paramNames = @($wrapperAst.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
            $paramNames | Should -Not -Contain 'MinTestCount' -Because 'MinTestCount is reachable only from Invoke-GoalContractValidate directly (fixture/test harness), never from this production CLI surface'
        }

        It 'invoked end-to-end against one simple fixture, exits on a valid verdict code and emits parseable JSON on stdout' {
            $repo = script:New-GCFixtureRepo -Path (Join-Path $TestDrive 'wrapper-smoke-repo')
            & git -C $repo checkout -q -b run-branch 2>&1 | Out-Null
            [System.IO.File]::WriteAllText((Join-Path $repo 'run-marker.txt'), "run change`n", [System.Text.UTF8Encoding]::new($false))
            & git -C $repo add -A 2>&1 | Out-Null
            & git -C $repo commit -q -m 'run state' 2>&1 | Out-Null

            $mockGhPath = Join-Path $TestDrive 'gh-wrapper-smoke.ps1'
            $payload = script:New-GCApprovedContractBody
            script:New-GCMockGhForContract -MockGhPath $mockGhPath -ContractPayload $payload

            # This smoke test intentionally does NOT override -MinTestCount
            # (the wrapper's public CLI surface has no such parameter, Part
            # E) -- the fixture's tiny two-test suite is therefore expected
            # to trip the real 200-test floor and come back 'fail', which is
            # itself proof the production entry point cannot bypass the s4
            # green floor. The dedicated AC2 fixtures above (against
            # Invoke-GoalContractValidate directly, with -MinTestCount
            # overridden) already cover the full pass/fail/refused/review-
            # required disposition space; this test only proves the
            # wrapper's own entry-guard + JSON-emission plumbing.
            $output = & pwsh -NoProfile -NoLogo -NonInteractive -File $script:WrapperFile -Issue 873 -RepoRoot $repo -Repo 'example-owner/example-repo' -GhCliPath $mockGhPath 2>&1
            $exitCode = $LASTEXITCODE

            $exitCode | Should -BeIn @(0, 1, 2, 3) -Because 'the wrapper must always exit on ONE of the four verdict codes, never crash'
            # ConvertTo-Json emits multi-line output (one array element per
            # captured stdout line via 2>&1), so the whole array must be
            # joined back into one string before parsing -- a single line
            # (e.g. the opening '{') is not valid JSON on its own.
            $fullOutput = ($output -join "`n")
            $fullOutput | Should -Match '^\s*\{' -Because "the wrapper must emit the verdict as JSON on stdout (raw output: $fullOutput)"
            # Deliberately not wrapped in `{ ... } | Should -Not -Throw`: that
            # pattern invokes the scriptblock in a child scope, so a variable
            # assignment inside it never propagates back out here (the same
            # PowerShell scoping pitfall as .GetNewClosure() above, different
            # mechanism). If ConvertFrom-Json throws, Pester reports the
            # uncaught exception as the test failure directly, which is
            # already the clearest possible signal.
            $parsedVerdict = $fullOutput | ConvertFrom-Json
            $parsedVerdict.Verdict | Should -Not -BeNullOrEmpty
            $parsedVerdict.ExitCode | Should -Be $exitCode
        }
    }
}
