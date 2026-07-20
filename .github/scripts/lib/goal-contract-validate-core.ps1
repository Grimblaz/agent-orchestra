#Requires -Version 7.0

<#
.SYNOPSIS
    Core validator library for the goal-contract plan-seat variant (issue
    #873, frame-slice s1; requirement contract AC1).

.DESCRIPTION
    Where this sits relative to the sibling #872 parser
    (.github/scripts/lib/goal-contract-core.ps1): that file PARSES a
    goal-contract block out of a comment body and validates its shape
    against the schema. This file VALIDATES a goal-contract's completion
    claim by re-deriving it from committed code -- it consumes the #872
    parser's Get-GCContractBlock / ConvertFrom-GCContractBlock /
    Test-GCContractHash functions rather than re-deriving any of that
    logic itself (872-D6, no re-derivation). Parse-vs-validate: #872 answers
    "is this a well-formed, approved contract?"; #873 answers "did the run
    actually satisfy it?". This file, s1, implements only the contract-intake
    portion of that second question -- the detached-worktree execution
    environment (s2), target-check execution (s3), the suite green-floor
    invariant (s4), and the test-diff-integrity invariant (s5) are net-new
    frame slices that extend Invoke-GoalContractValidate's body in later
    commits. The thin CLI wrapper goal-contract-validate.ps1 that dot-sources
    this file is s6.

      Get-GCPinnedCommentBody -Issue <int> -Marker <string> [-Repo <string>]
                               [-GhCliPath <string>]
        Callable, marker-pinned, paginated, byte-safe reader for the comment
        that hosts a goal-contract-variant plan's contract block. Fetches
        ALL comments on the issue via `gh api repos/{owner}/{repo}/issues/
        {n}/comments --paginate` (never `gh issue view`, which caps at 100
        comments) and reads the JSON `body` field only -- never
        console-rendered output (872-D3 byte-source rule; this repo has
        documented OEM-mangling history, issue #862). Selects the comment
        by literal marker-substring containment (mirroring
        find-or-upsert-comment.ps1's own matched-comment filter), NEVER by
        position ("latest block wins" is exactly the bug this function
        exists to avoid: a later comment that happens to embed a
        goal-contract-shaped block, but does not carry the pinning marker,
        must never be selected over the marker-designated comment). Zero
        matches and two-or-more matches both fail closed to $null -- an
        ambiguous marker match is a refusal condition for the caller, not a
        "pick one" decision made in this function. Deliberately does not
        call into find-or-upsert-comment.ps1's Find-OrUpsertComment: that
        function's read prologue is embedded inside a POST/PATCH write path,
        and a validator must never risk that side effect.

      Resolve-GCVerdictDisposition [-IsRefused] [-RefusalReasons <string[]>]
                                    [-HasFailure] [-HasReviewRequired]
                                    [-ReviewReason <string>]
                                    [-Targets <object[]>]
        Pure exit-code precedence-lattice resolver, decoupled from
        Invoke-GoalContractValidate's control flow so every signal
        combination (including combinations s1 cannot yet drive end-to-end,
        since target/suite/diff-integrity checks do not exist until
        s3/s4/s5) is directly unit-testable. Precedence: refused (pre-run) >
        fail > pass-review-required > pass, mapping to exit codes 2, 1, 3,
        and 0 respectively. -ReviewReason is the Reason tag s6+ will use to
        distinguish this slice's infra/harness-error disposition from a
        future target-level review-required disposition (e.g. a falsifier-
        absent advisory flag from s3, or a diff-integrity flag from s5) --
        both land on the same pass-review-required/exit-3 tier, but Reason
        keeps them distinguishable in the emitted verdict.

      Invoke-GoalContractValidate -Issue <int> -RepoRoot <string>
                                   [-Marker <string>] [-Repo <string>]
                                   [-GhCliPath <string>] [-GitCliPath <string>]
                                   [-PwshCliPath <string>] [-DiffDefaultRef <string>]
        Public entry point (Invoke-* per architecture-rules.md:15), and the
        module's sole terminal verdict-producing entry point (R16: this
        section describes the actual shipped, fully-wired s1-s6 behavior --
        it previously described the retired s1-only intake-gate-stops-here
        shape). The full sequence:

          1. Get-GCPinnedCommentBody (plan-issue-pinned, paginated,
             byte-safe read). $null -> refused: contract-comment-unresolvable.
          2. Get-GCContractBlock (#872 parser). Returns $null for three
             distinct causes -- zero head markers (absent), two-or-more head
             markers (ambiguous arity), and a single head marker with a
             missing/indented terminator (truncated) -- and the library
             itself cannot distinguish which occurred (see its own doc
             comment). This function does not pretend otherwise: all three
             map to the SAME fail-closed refusal, naming all three honestly
             rather than inventing a false-precision taxonomy the lib
             doesn't support.
          3. ConvertFrom-GCContractBlock (#872 parser), wrapped in try/catch.
             The ONE loud throw that function raises -- the missing
             powershell-yaml module (goal-contract-core.ps1:261-265) -- is
             caught here and mapped to the infra-error pass-review-required
             disposition, NEVER to exit-1 fail: an environment defect must
             not be reported as the run failing.
          4. Non-empty Violations (schema failure, e.g. an unrecognized
             schema_version) -> refused, using the Violations array content
             verbatim (prefixed for traceability). This function does not
             invent a more specific taxonomy than ConvertFrom-GCContractBlock
             actually returns (its Violations messages are the only source
             of refusal-reason granularity available).
          5. The 64-zero placeholder hash is refused as contract-not-approved
             BEFORE Test-GCContractHash ever runs (ordering is load-bearing:
             a placeholder contract's real digest is never checked, so the
             refusal reason is always contract-not-approved, never
             contract-hash-mismatch, for a draft contract).
          6. Test-GCContractHash (#872 parser) false -> refused:
             contract-hash-mismatch.
          7. With every intake gate passed, this function creates a
             detached disposable worktree (Invoke-GCWorktreeSession), runs
             the full suite (Invoke-GCSuitePhase, the s4 green floor), runs
             every targets[] check (Invoke-GCTargetChecks, s3), then the
             test-diff-integrity phase (Invoke-GCDiffIntegrityPhase, s5) --
             in that fixed order, inside the SAME disposable worktree, torn
             down in a `finally` regardless of outcome. Any otherwise-
             uncaught exception anywhere in this sequence (R9: a bad
             -PwshCliPath/-GitCliPath, an unresolvable downstream value,
             etc.) is caught and mapped to the same infra-error
             pass-review-required disposition as step 3's throw, never left
             to crash the process with an undifferentiated exit 1.
          8. The worktree session's and diff-integrity phase's own results
             are folded into Resolve-GCVerdictDisposition (suite/target
             failure -> fail; any mandatory-review flag with no failure ->
             pass-review-required; otherwise pass) and assembled into the
             final verdict via New-GCVerdictReport -- the SINGLE exit point
             for every return path in this function (including every
             intake refusal above), so every returned verdict carries the
             identical field-locked shape and every untrusted-contract- or
             tree-derived field is inert-rendered before it is ever echoed
             (U7).

        Invoke-GoalContractValidate therefore returns a REAL terminal
        verdict (Targets and Flags populated from the actual worktree run,
        never a provisional/placeholder shape) on every call -- the
        #874 predicate/loop contract consumes this verdict's ExitCode
        directly.

      Test-GCTreeClean -Path <string> [-GitCliPath <string>]
        Cleanliness-assertion primitive: runs `git -C <Path> status
        --porcelain` and returns whether the tree at that path is clean.
        Reused for two distinct callers: New-GCDisposableWorktree's
        pre-worktree dirty-invoking-tree refusal (AC2), and
        Invoke-GCWorktreeSession's post-phase assertion inside the
        worktree. Dirt discovered after the suite phase or after the checks
        phase is a mandatory-review flag by contract -- this function only
        provides the primitive; s3/s4 interpret the boolean into a verdict
        signal once those phase bodies exist.

      New-GCDisposableWorktree -RepoRoot <string> [-GitCliPath <string>]
        Creates a detached, disposable `git worktree` checkout of the
        invoking repo's own HEAD at a GUID-suffixed unique path under
        [IO.Path]::GetTempPath() (mirroring pester-sharded-core.ps1:163-164),
        outside the repo tree. Refuses a dirty invoking tree FIRST (AC2,
        `refused: uncommitted-changes`), before any worktree is created.
        Resolves HEAD to an explicit SHA via `rev-parse HEAD` and passes
        that SHA (never the symbolic `HEAD` ref) to `git worktree add
        --detach <path> <sha>` -- full command form, <path> BEFORE the
        commit-ish (U25). Detached is mandatory: a branch checkout would
        hard-fail if that branch is already checked out elsewhere (U4/F9).
        Net-new: no production `git worktree add` precedent existed before
        this slice.

      Remove-GCDisposableWorktree -RepoRoot <string> -WorktreePath <string>
                                   [-GitCliPath <string>] [-RetryDelayMs <int>]
        Teardown primitive: `git worktree remove --force <path>` followed
        by `git worktree prune`, with one bounded retry after a short delay
        if the first removal attempt fails. On persistent failure (e.g. a
        Windows handle lock held by an orphaned check descendant, U2) this
        function NEVER throws -- it returns `Removed = $false` with
        `OrphanedPath` set to the un-removed path, so the caller can surface
        it in the eventual verdict (s6) instead of losing it as a warning.

      Invoke-GCWorktreeSession -RepoRoot <string> [-SuitePhase <scriptblock>]
                                [-ChecksPhase <scriptblock>]
                                [-GitCliPath <string>] [-RetryDelayMs <int>]
        Wires New-GCDisposableWorktree, the fixed suite-then-checks
        execution order, the cleanliness assertion after each phase, and
        Remove-GCDisposableWorktree teardown (in a `finally`, so it always
        runs) into one composable session. s2 does not implement the
        suite-runner or check-runner bodies -- those are s3 (checks) and s4
        (suite) -- so `-SuitePhase`/`-ChecksPhase` are optional scriptblock
        seams invoked with the worktree path as their only argument; s3/s4
        plug their real bodies into these parameters rather than this
        function inventing suite/check semantics it isn't scoped to own
        yet. A dirty invoking tree short-circuits before any worktree or
        phase runs (`Refused = $true`, `RefusalReason = 'refused:
        uncommitted-changes'`). If a phase scriptblock throws, the `finally`
        still tears down the worktree before the exception propagates to
        the caller -- this function does not swallow phase errors, only
        guarantees teardown alongside them.

      Invoke-GCTargetCheck -Target <object> -WorktreePath <string>
                            [-TimeoutSeconds <int> = 300]
                            [-OutputCapBytes <int> = 65536]
                            [-PwshCliPath <string> = 'pwsh']
        Runs ONE `targets[]` entry's `check` from committed state inside the
        worktree, via `pwsh -NoProfile -NoLogo -NonInteractive -Command
        <check>` (873-D7: the check string is untrusted comment-sourced data,
        M7 note; this function executes it as a knowing execution surface
        without attempting to sanitize or interpret its content beyond that
        -- the trust model is edit-coherence, already settled). `expected` is
        never parsed as a pass/fail predicate -- only the process exit code
        decides. A blank/whitespace-only `check` is refused as a per-target
        floor (`Outcome = 'fail'`, `Reason = 'refused: blank-check'`) WITHOUT
        spawning a process. A missing or blank `falsifier` field adds the
        purely-informational `'falsifier-absent'` advisory flag -- it never
        changes `Outcome` (genuine vacuity detection is undecidable, U13).
        The timeout (default 300s) is enforced with a PREEMPTIVE
        TREE-KILL, never `Stop-Job`/`Wait-Job` (U2: `Stop-Job` does not kill
        descendant OS processes, which orphans grandchildren that hold
        worktree handles and break teardown): `System.Diagnostics.Process` +
        `Kill($true)` (the pwsh 7 / .NET Core 3+ tree-kill overload), with a
        `taskkill /PID <pid> /T /F` fallback if `Kill($true)` itself throws
        on Windows. A timeout ALWAYS maps `Outcome` to `'fail'` (never
        `refused`, never review-required). The exit code is marshalled
        explicitly by reading the `Process` object's own `ExitCode` property
        after it has exited (normally or via kill) -- never inferred from a
        job's `State`, which can report `Completed` even when the underlying
        check failed. Captured stdout/stderr are stream-bounded via
        `Register-ObjectEvent` + a byte-capped `StringBuilder` (default cap
        64KB each): once the accumulated buffer reaches the cap, further
        output is dropped and a `'...[output truncated: cap reached]...'`
        marker is appended, and `StdOutTruncated`/`StdErrTruncated` record
        which stream(s) hit it. Known limitation (issue #894): the cap is
        only checked between complete lines, because .NET's
        `OutputDataReceived`/`ErrorDataReceived` fire once per whole line
        (or at EOF) -- a single very large newline-free line is fully
        materialized in memory before the cap check can run, so peak
        memory during that one line is not bounded by the cap.

      Invoke-GCTargetChecks -Targets <object[]> -WorktreePath <string>
                             [-TimeoutSeconds <int> = 300]
                             [-OutputCapBytes <int> = 65536]
                             [-BudgetWallClock <string>]
                             [-PwshCliPath <string> = 'pwsh']
        Runs every `targets[]` entry via Invoke-GCTargetCheck (fixed
        iteration order) and aggregates the per-target results. Bounds total
        check time against the contract's own `budget.wall_clock` field
        (parsed by ConvertTo-GCWallClockSeconds) -- this is an ADVISORY
        total ceiling across all targets, not a hard per-target replacement
        for TimeoutSeconds: exceeding it never changes any target's
        `Outcome`, it only sets the aggregate `BudgetExceeded` flag for a
        later slice (s6) to surface as a mandatory-review signal, mirroring
        the unrecognized-`invariants[]` flag pattern. An absent or
        unparseable `budget.wall_clock` degrades to "no ceiling applied"
        (`BudgetExceeded = $false`, `BudgetWallClockSeconds = $null`) rather
        than guessing at an ambiguous contract field. Standalone at s3: not
        yet threaded into Invoke-GCWorktreeSession's `-ChecksPhase` seam or
        Invoke-GoalContractValidate's control flow -- s6 wires this function
        into `-ChecksPhase` and folds its result into
        Resolve-GCVerdictDisposition alongside the s1/s4/s5 signals.

      ConvertTo-GCWallClockSeconds -Value <string>
        Pure parser for the contract's `budget.wall_clock` field (schema
        type: free-form string, e.g. `"4h"`). Accepts a bare integer
        (seconds) or an integer with a single `h`/`m`/`s` suffix
        (case-insensitive). Any other shape (e.g. compound durations like
        `"1h30m"`, or non-numeric text) returns `$null` deliberately: the
        ceiling this feeds is advisory-only, so an unparseable value must
        degrade to "no ceiling", never a guessed interpretation.

      Test-GCSuiteGatePass -Result <object>
        Pure green-floor gate predicate (frame-slice s4, AC1; the U1
        CRITICAL fix). Returns $true only when ALL THREE hold:
        `$Result.ExitCode -eq 0`, `$Result.TotalFailed -eq 0`, and
        `($Result.TotalPassed + $Result.TotalFailed) -gt 0` (the ran-guard).
        Isolated as its own function -- decoupled from the
        Invoke-PesterSharded call itself -- so every false-GREEN shape
        (TestsPath-not-found, zero-discovered, MinTestCount-floor) is
        directly unit-testable against a hand-constructed mock result
        object, without a real Pester sub-run per test case. Never throws:
        a $null $Result, or one missing ExitCode/TotalFailed, fails closed
        to $false.

      Invoke-GCSuitePhase -WorktreePath <string> [-TimeoutSeconds <int> = 1800]
                           [-MinTestCount <int> = 200] [-PwshCliPath <string> = 'pwsh']
        Runs the full suite inside the worktree via Invoke-PesterSharded
        with an EXPLICIT `-TestsPath <WorktreePath>/.github/scripts/Tests`
        -- never the $PSScriptRoot-relative default this function otherwise
        falls back to (U4). Runner-copy policy: dot-sources
        `<WorktreePath>/.github/scripts/lib/pester-sharded-core.ps1` -- the
        copy that lives INSIDE THE WORKTREE -- inside a CHILD pwsh process
        (never the copy in the invoking repo, and never in-process), because
        Invoke-PesterSharded is a plain function call with no killable
        process handle of its own; shelling out to a child process gives
        this function a real System.Diagnostics.Process handle around the
        ENTIRE suite run, killable with the same preemptive tree-kill
        discipline the s3 function Invoke-GCTargetCheck uses
        (`Kill($true)`, `taskkill /T /F` fallback) (U2/U3). A timeout, a
        missing runner-lib copy in the worktree, or a missing/unparseable
        result file after a non-timeout exit ALL map to the identical
        fail-closed shape (`ExitCode=1, TotalFailed=0, TimedOut` as
        applicable) -- Test-GCSuiteGatePass rejects this on ExitCode even
        though TotalFailed reads 0, closing the exact false-GREEN gap this
        slice exists to fix. Standalone at s4, like s3: not yet threaded
        into the `-SuitePhase` seam on Invoke-GCWorktreeSession or the
        control flow inside Invoke-GoalContractValidate; a later slice
        wires it in and folds the verdict from Test-GCSuiteGatePass into
        Resolve-GCVerdictDisposition alongside the s1/s3/s5 signals. NO
        FLAKE-QUENCH (U5, judge-sustained HIGH, dropped from the plan
        entirely): this function contains no retry-the-suite-on-failure
        logic of any kind -- any failure, flaky or not, is `fail`.

.NOTES
    Trust framing (M7, inherited from goal-contract-core.ps1's own .NOTES):
    every field this validator reads ultimately comes from an untrusted,
    externally-writable GitHub comment. s1/s2 never execute `targets[].check`
    or feed prose fields into a prompt -- they only read structural fields
    (contract_hash, schema_version via the #872 schema gate) needed for
    intake decisions. s3's Invoke-GCTargetCheck is the first function in this
    file that treats contract content (`targets[].check`) as a knowing
    execution surface (873-D7) -- it executes the check as a shell command
    via pwsh without sanitizing or interpreting its content beyond that; the
    trust model is edit-coherence (already settled), not this function's
    concern to re-litigate.

    Soundness boundary + runner-version invariant (s4, U14 -- documentation
    only, not runtime logic): the green floor Test-GCSuiteGatePass enforces
    is only satisfiable where the target suite is genuinely all-green AT THE
    RUNNER VERSION IN USE. This validator has no independent
    production-behavior signal beyond (a) the existing Pester suite already
    in the target repo (this section) and (b) the `targets[].check`
    commands the contract itself defines (s3) -- a production regression
    touched by NEITHER of those is
    structurally invisible to this gate; the validator does not and cannot
    detect it. A validator run assumes it executes under a runner version
    where the target suite is expected to be green; it does not itself
    verify pwsh/Pester-version compatibility between the invoking
    environment and the worktree under audit.

      Resolve-GCDiffBase -WorktreePath <string> -RunSha <string>
                          [-DefaultRef <string> = 'origin/main']
                          [-GitCliPath <string> = 'git']
        Frame-slice s5 (AC1/AC2), the diff-base primitive for the
        test-diff-integrity invariant. Computes `git merge-base <default-sha>
        <run-sha>` using EXPLICIT SHA arguments in a PINNED working
        directory (`-C $WorktreePath`) -- never symbolic `HEAD`, which could
        resolve to whatever branch the invoking process happens to be on
        rather than this run's own commit. `<default-sha>` is resolved via
        `rev-parse $DefaultRef` against a ref that must ALREADY BE PRESENT
        locally: this function NEVER calls `git fetch` (a worktree shares
        the operator's object store and remote-tracking refs, so a fetch
        here would mutate the operator's real repo's refs as a side
        effect) -- an absent ref refuses (`refused: default-ref-unresolvable`)
        rather than fetching. When `merge-base(default, run) == run-sha`
        there is no run diff to audit -- refuses `refused: no-run-diff`,
        and the message states only the OBSERVED condition (merge-base
        equals the run sha) rather than fabricating a definitive cause: no
        commits beyond the default, a direct-to-default commit, and an
        already-merged tip are all indistinguishable from git state alone,
        so the message names all three honestly instead of guessing which
        one occurred.

      Test-GCTestFileDeletion -WorktreePath <string> -BaseSha <string>
                               -RunSha <string> [-AllowlistPathspecs <string[]>]
                               [-GitCliPath <string> = 'git']
        Mandatory-review flag (never a block): `git diff --diff-filter=DR
        --no-renames <base> <run> -- <allowlist>`. The `--no-renames` forces
        git to NEVER collapse a delete+create pair into a rename, so a
        renamed-and-gutted test file still surfaces as a deletion of the old
        path -- `--diff-filter=D` alone would miss this evasion because
        git's default rename heuristic reclassifies a high-similarity
        delete+create pair as a single `R` status, which `--diff-filter=D`
        does not match. PF2: a `git diff` command failure returns
        `GitError = $true` / `ErrorDetail = "<sentinel text>"` with an EMPTY
        `DeletedFiles` -- the error sentinel never lands inside
        `DeletedFiles` itself, so `Invoke-GCDiffIntegrityPhase` can route it
        to the dedicated `diff-integrity-git-error` Kind instead of the
        `test-file-deletion` Kind a real deletion would use.

      Get-GCShouldCommandCount -Content <string>
        Pure AST-aware counter: parses PowerShell source via
        `[System.Management.Automation.Language.Parser]::ParseInput` and
        counts CommandAst nodes whose command name is literally `Should` --
        never a substring/regex match, which would mis-hit comments, string
        literals, `SupportsShouldProcess`, and `$PSCmdlet.ShouldProcess`
        (none of which are Pester assertions).

      Test-GCAssertionWeakening -WorktreePath <string> -BaseSha <string>
                                 -RunSha <string> -ChangedTestFilePaths <string[]>
                                 [-GitCliPath <string> = 'git']
        Compares the AST Should-count (via Get-GCShouldCommandCount) for
        each changed `*.Tests.ps1` file's content at base vs. run (read via
        `git show <sha>:<path>`, never a working-tree read); a DECREASE
        flags the file. Only compares files present at BOTH commits --
        deletion-class changes are Test-GCTestFileDeletion's concern.
        Always carries an honest `HeuristicNote`: count-preserving
        weakening (`Should -Be $x` -> `Should -Not -BeNullOrEmpty`) is
        undetectable by count alone, and this signal does not claim to
        catch it.

      Get-GCHelperLibSet -RepoRoot <string>
        Grounds the "helper-lib" half of the allowlist as a RULE, not a
        frozen list: greps every `.github/scripts/Tests/**/*.Tests.ps1`
        file for dot-source references (both a direct literal ending
        `.ps1`, e.g. `. (Join-Path $x 'lib/name.ps1')`, and one-hop `.
        $script:CoreFile`-style variable indirection, resolved against that
        variable's own assignment line in the same file) and returns the
        `.github/scripts/lib/*.ps1` files actually referenced -- computed
        live at run time, never a hard-coded literal array.

      Test-GCFixtureOrHelperModification -WorktreePath <string> -BaseSha <string>
                                          -RunSha <string> [-HelperLibPaths <string[]>]
                                          [-GitCliPath <string> = 'git']
        Mandatory-review flag: any changed file under
        `.github/scripts/Tests/fixtures/**` OR any changed file in the
        live-computed helper-lib set (Get-GCHelperLibSet). PF2: same
        `GitError`/`ErrorDetail`/dedicated-Kind routing as
        Test-GCTestFileDeletion above on a `git diff` command failure.

      Test-GCUnrecognizedInvariants -Invariants <string[]>
        Pure predicate: the contract's `invariants[]` array may carry any
        repo-specific string, but this validator interprets only
        `full-pester-suite-no-new-failures` (s4's green floor) and
        `test-diff-integrity` (this section). Any OTHER literal is returned
        so the caller can raise it as an `unchecked` mandatory-review flag
        -- never a silent skip.

      Invoke-GCDiffIntegrityPhase -WorktreePath <string> -RunSha <string>
                                   [-RepoRoot <string>] [-Invariants <string[]>]
                                   [-DefaultRef <string> = 'origin/main']
                                   [-GitCliPath <string> = 'git']
        Composes the diff-base resolution and all three detectors above
        (plus the unrecognized-invariant check) into one seam, mirroring
        s3/s4's own aggregate entry points (Invoke-GCTargetChecks,
        Invoke-GCSuitePhase). A `Resolve-GCDiffBase` refusal short-circuits
        before any detector runs. Every detector result is a FLAG, never a
        block -- this function has no fail/pass verdict of its own.
        Standalone at s5, like s3/s4: not yet threaded into
        Invoke-GCWorktreeSession's seams or Invoke-GoalContractValidate's
        control flow; s6 wires it in and folds `Flags` into
        Resolve-GCVerdictDisposition's `-HasReviewRequired` signal
        alongside the s1/s3/s4 signals.
#>

# Sibling-lib dot-source, mirroring the repo convention (e.g.
# cost-rolling-history.ps1:21, followup-gate-core.ps1:40-41): reuse the #872
# parser's Get-GCContractBlock / ConvertFrom-GCContractBlock /
# Test-GCContractHash rather than re-deriving any of that logic (872-D6).
. (Join-Path $PSScriptRoot 'goal-contract-core.ps1')

# The 64-zero placeholder digest (872-D3): a draft contract is structurally
# distinguishable from an approved one only by contract_hash still holding
# this literal value.
$script:GCVPlaceholderHash = '0' * 64

# Private: the repeated "take the first output line, trim it" idiom used
# everywhere this file reads a single-value `git` invocation (rev-parse HEAD,
# rev-parse <ref>, merge-base). Centralized so the four call sites below
# (Invoke-GoalContractValidate's RunSha, New-GCDisposableWorktree's HeadSha,
# and Resolve-GCDiffBase's DefaultSha/MergeBaseSha) share one idiom instead of
# repeating the `([string](@($raw) | Select-Object -First 1)).Trim()` shape.
# Each call site still owns its own $LASTEXITCODE / blank check -- this
# helper only does the extraction, never the refusal decision.
function script:ConvertTo-GCFirstLineTrimmed {
    param(
        [Parameter(Mandatory = $false)][AllowNull()]$Raw
    )
    return ([string](@($Raw) | Select-Object -First 1)).Trim()
}

# Private: shape-tolerant key/property presence check (CE-Gate F1 fix).
# $Target.PSObject.Properties.Match(<name>) alone only enumerates a
# [System.Collections.Hashtable]'s own CLR TYPE members (Keys, Values,
# Count, IsReadOnly, IsFixedSize, SyncRoot) -- NEVER the hashtable's actual
# keys -- so it always reports 0 for a real Hashtable key, even one holding
# genuine content. ConvertFrom-GCContractBlock -> ConvertFrom-Yaml (the
# sibling #872 parser) returns a Hashtable, so this is the shape every
# production contract target actually arrives in; only pscustomobject-style
# test fixtures happened to make the old check work. Dot-access
# ($Target.<name>) and .ContainsKey() both correctly resolve/detect a real
# Hashtable value via PowerShell's dynamic Hashtable adapter -- only the
# .PSObject.Properties.Match() presence CHECK itself was broken. This is the
# ONE shared point of truth for that presence check, used at every call site
# that needs it (both the s3 Invoke-GCTargetCheck falsifier-advisory gate
# and the s6 New-GCVerdictReport falsifier-passthrough gate) -- duplicating
# the corrected logic at only one of the two call sites is what let the
# other regress unguarded for so long.
function script:Test-GCPropertyPresent {
    param(
        [Parameter(Mandatory = $false)][AllowNull()]$Target,
        [Parameter(Mandatory)][string]$Name
    )

    if ($null -eq $Target) {
        return $false
    }
    if ($Target -is [System.Collections.IDictionary]) {
        return $Target.Contains($Name)
    }
    return ($Target.PSObject.Properties.Match($Name).Count -gt 0)
}

function Get-GCPinnedCommentBody {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][int]$Issue,
        [Parameter(Mandatory)][string]$Marker,
        # R7: the remote-resolution fallback below reads from THIS path, not
        # the process CWD -- a blank/absent value falls back to the process
        # CWD (pre-R7 behavior), which only matters for callers that never
        # supply one.
        [Parameter(Mandatory = $false)][AllowNull()][AllowEmptyString()][string]$RepoRoot,
        [Parameter(Mandatory = $false)][string]$Repo,
        [Parameter(Mandatory = $false)][string]$GhCliPath = 'gh',
        [Parameter(Mandatory = $false)][string]$GitCliPath = 'git'
    )

    if ([string]::IsNullOrWhiteSpace($Repo)) {
        try {
            # R7: resolve against -RepoRoot (falling back to the process CWD
            # only when no RepoRoot was supplied) and honor -GitCliPath --
            # the wrapper's own docstring already claims resolution is from
            # -RepoRoot; this was previously false as implemented (bare
            # `git config`, hardcoded literal `git`, ignoring any
            # -GitCliPath override threaded in from Invoke-GoalContractValidate).
            if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
                $remoteUrl = & $GitCliPath config --get remote.origin.url 2>$null
            } else {
                $remoteUrl = & $GitCliPath -C $RepoRoot config --get remote.origin.url 2>$null
            }
            if ($remoteUrl -and $remoteUrl -match '[:/]([^/:]+)/([^/]+?)(?:\.git)?\s*$') {
                $Repo = "$($Matches[1])/$($Matches[2])"
            }
        } catch {
            $Repo = $null
        }
    }

    if ([string]::IsNullOrWhiteSpace($Repo)) {
        Write-Warning 'Get-GCPinnedCommentBody: could not resolve owner/repo from git remote; cannot read comments.'
        return $null
    }

    # Uncapped, paginated read (never `gh issue view`, which caps at 100
    # comments -- mirroring the followup-gate-core.ps1:415-433 precedent).
    # gh api auto-concatenates pages of a JSON-array response into one flat
    # array under plain --paginate; no --slurp flattening step is needed
    # here (contrast frame-credit-ledger-core.ps1's --paginate --slurp shape,
    # which exists for a different response wrapping and is not used here).
    $apiPath = "repos/$Repo/issues/$Issue/comments"
    try {
        $rawJson = & $GhCliPath api $apiPath --paginate 2>$null
    } catch {
        Write-Warning "Get-GCPinnedCommentBody: gh api $apiPath --paginate threw an exception: $($_.Exception.Message)"
        return $null
    }
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "Get-GCPinnedCommentBody: gh api $apiPath --paginate failed (exit $LASTEXITCODE)."
        return $null
    }
    if ([string]::IsNullOrWhiteSpace($rawJson)) {
        Write-Warning "Get-GCPinnedCommentBody: gh api $apiPath returned no comments."
        return $null
    }

    try {
        $parsed = $rawJson | ConvertFrom-Json -ErrorAction Stop
    } catch {
        Write-Warning "Get-GCPinnedCommentBody: failed to parse gh api response: $($_.Exception.Message)"
        return $null
    }

    # Marker-pinned selection -- literal substring containment, mirroring
    # Find-OrUpsertComment's own matched-comment filter
    # (find-or-upsert-comment.ps1:171-173) -- but this function never routes
    # through that write/upsert path; it only reads.
    $matched = @(@($parsed) | Where-Object { $_.body -and ($_.body -like "*$Marker*") })

    if ($matched.Count -eq 0) {
        Write-Warning "Get-GCPinnedCommentBody: no comment on issue $Issue carries marker '$Marker'."
        return $null
    }
    if ($matched.Count -gt 1) {
        Write-Warning "Get-GCPinnedCommentBody: $($matched.Count) comments on issue $Issue carry marker '$Marker'; refusing to guess (ambiguous)."
        return $null
    }

    return [string]$matched[0].body
}

function Resolve-GCVerdictDisposition {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [switch]$IsRefused,
        [string[]]$RefusalReasons = @(),
        [switch]$HasFailure,
        [switch]$HasReviewRequired,
        [Parameter(Mandatory = $false)][AllowNull()][string]$ReviewReason,
        [object[]]$Targets = @()
    )

    # Precedence lattice: refused (pre-run) > fail > pass-review-required >
    # pass. Evaluated top-down so a caller that (legitimately, once s3-s6
    # land) supplies multiple co-occurring signals always resolves to the
    # single highest-precedence disposition, never a blend.
    if ($IsRefused) {
        return [pscustomobject]@{
            Verdict  = 'refused'
            ExitCode = 2
            Reason   = $null
            Refusals = @($RefusalReasons)
            Targets  = @($Targets)
        }
    }
    if ($HasFailure) {
        return [pscustomobject]@{
            Verdict  = 'fail'
            ExitCode = 1
            Reason   = $null
            Refusals = @()
            Targets  = @($Targets)
        }
    }
    if ($HasReviewRequired) {
        return [pscustomobject]@{
            Verdict  = 'pass-review-required'
            ExitCode = 3
            Reason   = $ReviewReason
            Refusals = @()
            Targets  = @($Targets)
        }
    }
    return [pscustomobject]@{
        Verdict  = 'pass'
        ExitCode = 0
        Reason   = $null
        Refusals = @()
        Targets  = @($Targets)
    }
}

# Private: assembles the mandatory-review Flags list (worktree-dirt,
# teardown-orphan, and budget signals) from a completed Invoke-GCWorktreeSession
# result and its diff-integrity result, alongside the diff-integrity phase's
# own Flags. Isolated from Invoke-GoalContractValidate's body below so that
# function stays focused on the refused/fail/review-required/pass sequence
# rather than flag bookkeeping; a $null -DiffResult or -Session degrades
# gracefully (no flags from that source), never throws.
function script:Get-GCMandatoryReviewFlags {
    param(
        [Parameter(Mandatory = $false)][AllowNull()][object]$DiffResult,
        [Parameter(Mandatory = $false)][AllowNull()][object]$Session
    )

    $flags = [System.Collections.Generic.List[object]]::new()
    if ($DiffResult) {
        foreach ($flag in @($DiffResult.Flags)) {
            $flags.Add($flag) | Out-Null
        }
    }
    if ($Session -and $Session.ChecksResult -and $Session.ChecksResult.BudgetExceeded) {
        $flags.Add([pscustomobject]@{ Kind = 'target-checks-budget-exceeded'; Detail = "budget.wall_clock=$($Session.ChecksResult.BudgetWallClockSeconds)s" }) | Out-Null
    }
    if ($Session -and $Session.OrphanedPath) {
        $flags.Add([pscustomobject]@{ Kind = 'worktree-teardown-orphaned'; Detail = $Session.OrphanedPath }) | Out-Null
    }
    if ($Session -and $Session.SuiteCleanliness -and -not $Session.SuiteCleanliness.IsClean) {
        $flags.Add([pscustomobject]@{ Kind = 'worktree-dirt-after-suite-phase'; Detail = $null }) | Out-Null
    }
    if ($Session -and $Session.ChecksCleanliness -and -not $Session.ChecksCleanliness.IsClean) {
        $flags.Add([pscustomobject]@{ Kind = 'worktree-dirt-after-checks-phase'; Detail = $null }) | Out-Null
    }

    return @($flags)
}

function Invoke-GoalContractValidate {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][int]$Issue,
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory = $false)][string]$Marker,
        [Parameter(Mandatory = $false)][string]$Repo,
        [Parameter(Mandatory = $false)][string]$GhCliPath = 'gh',
        [Parameter(Mandatory = $false)][string]$GitCliPath = 'git',
        [Parameter(Mandatory = $false)][string]$PwshCliPath = 'pwsh',
        [Parameter(Mandatory = $false)][string]$DiffDefaultRef = 'origin/main',
        # s6/Part E: INTERNAL, test/fixture-harness-only override for
        # Invoke-PesterSharded's MinTestCount floor (default 200). A tiny
        # fixture suite cannot clear that floor, so the fixture harness
        # (never a production run) sets this explicitly. The thin CLI
        # wrapper goal-contract-validate.ps1 does NOT expose this on its
        # public parameter surface -- only code that calls this function
        # directly (fixture/test code) can reach it, so it cannot weaken the
        # s4 green-floor gate for a real production validation run.
        [Parameter(Mandatory = $false)][int]$MinTestCount = 200
    )

    if ([string]::IsNullOrWhiteSpace($Marker)) {
        $Marker = "<!-- plan-issue-$Issue -->"
    }

    # 1. Plan-issue-pinned, paginated, byte-safe read.
    $body = Get-GCPinnedCommentBody -Issue $Issue -Marker $Marker -RepoRoot $RepoRoot -Repo $Repo -GhCliPath $GhCliPath -GitCliPath $GitCliPath
    if ($null -eq $body) {
        # R1: every intake-refusal return is routed through
        # New-GCVerdictReport -- the single exit point -- so it always
        # carries the same 6-field shape (incl. Flags) every other path
        # produces, AND so refusal-reason text (some of which echoes
        # untrusted contract-derived content, e.g. the schema-violation
        # refusal below) is always inert-rendered before it is ever echoed.
        $disposition = Resolve-GCVerdictDisposition -IsRefused -RefusalReasons @('refused: contract-comment-unresolvable')
        return New-GCVerdictReport -Disposition $disposition -ContractTargets @() -Flags @()
    }

    # 2. Block extraction (#872 parser). $null folds three honest,
    #    lib-undifferentiated causes into one fail-closed refusal.
    $payload = Get-GCContractBlock -CommentBody $body
    if ($null -eq $payload) {
        $disposition = Resolve-GCVerdictDisposition -IsRefused -RefusalReasons @('refused: contract-block-unresolvable (absent, ambiguous, or truncated -- see contract comment)')
        return New-GCVerdictReport -Disposition $disposition -ContractTargets @() -Flags @()
    }

    # 3. Schema parse/validate (#872 parser). The ONE loud throw (missing
    #    powershell-yaml module) maps to the infra-error disposition, never
    #    exit-1 fail.
    $parseResult = $null
    try {
        $parseResult = ConvertFrom-GCContractBlock -Payload $payload -RepoRoot $RepoRoot
    } catch {
        $disposition = Resolve-GCVerdictDisposition -HasReviewRequired -ReviewReason "infra-error: $($_.Exception.Message)"
        return New-GCVerdictReport -Disposition $disposition -ContractTargets @() -Flags @()
    }

    if ($parseResult.Violations -and @($parseResult.Violations).Count -gt 0) {
        $reasons = @(@($parseResult.Violations) | ForEach-Object { "refused: contract-schema-violation: $_" })
        $disposition = Resolve-GCVerdictDisposition -IsRefused -RefusalReasons $reasons
        return New-GCVerdictReport -Disposition $disposition -ContractTargets @() -Flags @()
    }

    $contractHashField = $parseResult.Contract.contract_hash

    # 4. Placeholder refusal MUST precede the real hash comparison (ordering
    #    is load-bearing): a draft contract's digest is never checked.
    if ($contractHashField -eq $script:GCVPlaceholderHash) {
        $disposition = Resolve-GCVerdictDisposition -IsRefused -RefusalReasons @('refused: contract-not-approved')
        return New-GCVerdictReport -Disposition $disposition -ContractTargets @() -Flags @()
    }

    # 5. Approved-contract integrity check (#872 parser).
    if (-not (Test-GCContractHash -Payload $payload -Expected $contractHashField)) {
        $disposition = Resolve-GCVerdictDisposition -IsRefused -RefusalReasons @('refused: contract-hash-mismatch')
        return New-GCVerdictReport -Disposition $disposition -ContractTargets @() -Flags @()
    }

    # Intake gates all passed. s6: fold the worktree/target/suite/
    # diff-integrity signals into the same Resolve-GCVerdictDisposition
    # lattice the intake gates use above, producing the real terminal
    # verdict #874 consumes -- assembled via New-GCVerdictReport so every
    # untrusted-contract-derived field is inert-rendered before it is ever
    # echoed (U7).
    $contractTargets = @($parseResult.Contract.targets)
    $invariantsList = @($parseResult.Contract.invariants)
    $budgetWallClock = $null
    if ($parseResult.Contract.budget) {
        $budgetWallClock = [string]$parseResult.Contract.budget.wall_clock
    }

    # NOTE ON SCRIPTBLOCK VARIABLE RESOLUTION (R19, doc-fix only -- no
    # runtime behavior change): these are plain scriptblock literals, not
    # .GetNewClosure()'d. They do NOT capture this function's locals via
    # lexical closure -- a plain PowerShell scriptblock resolves variables
    # via DYNAMIC scoping through the call stack AT INVOCATION TIME, not via
    # the block's own lexical defining location (independently verified: a
    # scriptblock invoked from a callee resolves a colliding variable name
    # to the CALLING scope's value, not the defining scope's value). This
    # works here ONLY because Invoke-GCWorktreeSession always invokes these
    # blocks from a call chain rooted at THIS function (Invoke-
    # GoalContractValidate is still an ancestor frame when each block runs),
    # so $contractTargets/$budgetWallClock/$invariantsList/$MinTestCount/
    # $PwshCliPath/$DiffDefaultRef/$GitCliPath all resolve up that live call
    # stack -- a fragile invariant, not a closure guarantee. Do NOT
    # introduce a same-named local variable in an intermediate caller (it
    # would shadow the intended value), and do NOT move this invocation into
    # a job/runspace (a different scoping model entirely) without
    # re-verifying variable resolution. A GetNewClosure()'d scriptblock would
    # instead isolate command resolution into its own private scope, which
    # breaks resolving sibling dot-sourced functions (Invoke-GCSuitePhase
    # etc.) normally when invoked from Invoke-GCWorktreeSession -- reproduced
    # under Pester's nested BeforeAll/It scriptblock execution model -- so
    # GetNewClosure() is deliberately avoided here, not merely omitted by
    # oversight.
    $suitePhase = {
        param($path)
        Invoke-GCSuitePhase -WorktreePath $path -MinTestCount $MinTestCount -PwshCliPath $PwshCliPath
    }

    $checksPhase = {
        param($path)
        Invoke-GCTargetChecks -Targets $contractTargets -WorktreePath $path -BudgetWallClock $budgetWallClock -PwshCliPath $PwshCliPath
    }

    $diffIntegrityPhase = {
        param($path, $headSha)
        # PF1 (post-fix targeted prosecution, HIGH; supersedes R11): RunSha
        # is the worktree's PRE-CHECKS HeadSha, threaded in as this
        # scriptblock's second argument by Invoke-GCWorktreeSession (sourced
        # from $worktree.HeadSha, which New-GCDisposableWorktree resolves via
        # `rev-parse HEAD` at worktree-creation time, BEFORE the suite or
        # checks phase ever runs) -- never a fresh `rev-parse HEAD` resolved
        # here, after the checks phase has already executed.
        #
        # R11's original claim -- "nothing in the suite/checks phases commits
        # inside the disposable worktree, so its HEAD never moves" -- is
        # FALSE under this module's own stated threat model: `targets[].check`
        # is untrusted comment-sourced content (873-D7) executed with the
        # worktree as its working directory (Invoke-GCTargetCheck's
        # -WorkingDirectory), so a malicious check can run `git commit`
        # inside the worktree. That commit leaves `git status --porcelain`
        # EMPTY (so the post-checks Test-GCTreeClean tamper-detection flag
        # never fires) while it MOVES the worktree's HEAD. A fresh
        # post-checks `rev-parse HEAD` would then pick up the attacker's
        # crafted commit, and this phase would audit THAT commit instead of
        # the commit that was actually suite-tested and check-executed --
        # letting a run that deleted/weakened a test earlier "restore" it via
        # a check-time commit and read clean. Resolving HeadSha once, before
        # any phase runs, closes both this tamper vector and the original R11
        # TOCTOU concern (a commit landing on the invoking branch mid-run) in
        # one fix: it is the single tamper-immune source of truth for "the
        # commit that was actually validated."
        Invoke-GCDiffIntegrityPhase -WorktreePath $path -RunSha $headSha -RepoRoot $path -Invariants $invariantsList -DefaultRef $DiffDefaultRef -GitCliPath $GitCliPath
    }

    # R9: everything from worktree creation through the final disposition is
    # wrapped in try/catch -- widening infra-error handling beyond the
    # single missing-powershell-yaml catch above (step 3). Every other
    # infra-level exception (a bad -PwshCliPath/-GitCliPath causing
    # Process.Start() or a git invocation to throw, an unexpected re-thrown
    # session-phase error, an unresolvable downstream value) previously
    # escaped uncaught, and since the wrapper script has no top-level
    # try/catch, `pwsh -File` would crash with exit code 1 -- which the
    # documented #874 predicate/loop contract reads as "target failed,
    # retry," not "environment broken, stop." Nothing inside this block ever
    # represents a genuine fail/pass/review-required disposition via a
    # thrown exception (those are always returned as a normal value, never
    # thrown), so mapping every throw here to the SAME infra-error
    # pass-review-required disposition can never mask a real target/suite
    # fail's exit code.
    try {
        $session = Invoke-GCWorktreeSession -RepoRoot $RepoRoot -SuitePhase $suitePhase -ChecksPhase $checksPhase -DiffIntegrityPhase $diffIntegrityPhase -GitCliPath $GitCliPath

        if ($session.Refused) {
            $disposition = Resolve-GCVerdictDisposition -IsRefused -RefusalReasons @($session.RefusalReason)
            return New-GCVerdictReport -Disposition $disposition -ContractTargets $contractTargets -Flags @()
        }

        # s5's own refusal (e.g. refused: no-run-diff, refused:
        # default-ref-unresolvable) means the validator could not complete
        # the audit at all -- the same "declines to render a judgment"
        # semantics as the intake refusals above, so it takes the same
        # top-of-lattice precedence (AC2 fixture 6: merge-base==run-sha
        # refuses no-run-diff).
        $diffResult = $session.DiffIntegrityResult
        if ($diffResult -and $diffResult.Refused) {
            $disposition = Resolve-GCVerdictDisposition -IsRefused -RefusalReasons @($diffResult.RefusalReason)
            # R5: mandatory-review flags already collected from the
            # suite+checks phases (e.g. an orphan-worktree/dirt/budget
            # signal) must not be silently dropped just because the
            # diff-integrity phase itself refused -- fold them in here too,
            # same as the non-refused path below.
            $preRefusalFlags = script:Get-GCMandatoryReviewFlags -DiffResult $diffResult -Session $session
            return New-GCVerdictReport -Disposition $disposition -ContractTargets $contractTargets -Flags @($preRefusalFlags)
        }

        $targetResults = @()
        if ($session.ChecksResult) {
            $targetResults = @($session.ChecksResult.Targets)
        }

        # Mandatory-review flags collected regardless of the eventual fail/pass
        # disposition, so a worktree teardown orphan or check-induced dirt is
        # ALWAYS surfaced in the verdict's Flags -- never a separate outcome
        # (Part A).
        $flags = script:Get-GCMandatoryReviewFlags -DiffResult $diffResult -Session $session

        # Suite failure -> overall fail (s4 green floor). Any target failure ->
        # overall fail (s3). Both precede review-required in the lattice.
        $suitePassed = Test-GCSuiteGatePass -Result $session.SuiteResult
        $anyTargetFailed = (@($targetResults | Where-Object { $_.Outcome -eq 'fail' })).Count -gt 0
        $hasFailure = (-not $suitePassed) -or $anyTargetFailed

        if ($hasFailure) {
            $disposition = Resolve-GCVerdictDisposition -HasFailure -Targets $targetResults
            return New-GCVerdictReport -Disposition $disposition -ContractTargets $contractTargets -Flags @($flags)
        }

        # No suite/target failure: any diff-integrity flag alone (incl. an
        # unrecognized-invariant literal) or any worktree/budget flag ->
        # pass-review-required. No flags at all -> pass.
        if (@($flags).Count -gt 0) {
            $disposition = Resolve-GCVerdictDisposition -HasReviewRequired -ReviewReason 'review-required: mandatory-review flags present (see Flags)' -Targets $targetResults
            return New-GCVerdictReport -Disposition $disposition -ContractTargets $contractTargets -Flags @($flags)
        }

        $disposition = Resolve-GCVerdictDisposition -Targets $targetResults
        return New-GCVerdictReport -Disposition $disposition -ContractTargets $contractTargets -Flags @()
    } catch {
        $disposition = Resolve-GCVerdictDisposition -HasReviewRequired -ReviewReason "infra-error: $($_.Exception.Message)"
        return New-GCVerdictReport -Disposition $disposition -ContractTargets $contractTargets -Flags @()
    }
}

# -----------------------------------------------------------------------------
# s2: detached disposable-worktree execution environment (frame-slice s2,
# AC1/AC2). These functions are net-new (no production `git worktree add`
# precedent) and are not yet threaded into Invoke-GoalContractValidate's
# control flow above -- that function still implements only the s1
# contract-intake gates. s3 (target-check execution) and s4 (suite green
# floor) plug their bodies into Invoke-GCWorktreeSession's -ChecksPhase and
# -SuitePhase seams; a later slice folds the resulting session object into
# Resolve-GCVerdictDisposition alongside the intake gates.
# -----------------------------------------------------------------------------

function Test-GCTreeClean {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory = $false)][string]$GitCliPath = 'git'
    )

    $porcelain = & $GitCliPath -C $Path status --porcelain 2>$null
    if ($LASTEXITCODE -ne 0) {
        # R3 (HIGH, live-reproduced): fail CLOSED, never open. A failed git
        # invocation (corrupted index, stale lock file, invalid path, etc.)
        # previously produced empty stdout, which read as IsClean=$true -- a
        # false "clean" report. This primitive backs the AC2 pre-worktree
        # dirty-tree refusal AND, more seriously, the post-checks-phase
        # tamper-detection cleanliness assertion that runs right after
        # untrusted targets[].check commands executed -- a silent false
        # "clean" there would hide real tamper.
        return [pscustomobject]@{
            IsClean   = $false
            Porcelain = @("git status --porcelain failed (exit $LASTEXITCODE) at '$Path'; treating as NOT clean (fail-closed)")
        }
    }
    $lines = @($porcelain | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

    return [pscustomobject]@{
        IsClean   = ($lines.Count -eq 0)
        Porcelain = $lines
    }
}

# Private: one removal attempt (`worktree remove --force` + `worktree
# prune`). Isolated so Remove-GCDisposableWorktree's bounded retry can call
# it twice without duplicating the git invocation shape.
function script:Invoke-GCWorktreeRemoveAttempt {
    param(
        [Parameter(Mandatory)][string]$GitCliPath,
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$WorktreePath
    )

    # R18: stdout is discarded via Out-Null (not just stderr via 2>$null) --
    # this function's return value is structurally consumed by callers
    # (Remove-GCDisposableWorktree derives its Removed bool from it), and an
    # un-redirected native-command stdout becomes part of THIS function's
    # own unclaimed pipeline output, silently prepending onto the eventual
    # `return $removeSucceeded` value. This works today only because git
    # emits progress messages to stderr, not stdout -- a future git version
    # or platform difference emitting to stdout could otherwise silently
    # pollute the return value's truthiness.
    & $GitCliPath -C $RepoRoot worktree remove --force $WorktreePath 2>$null | Out-Null
    $removeSucceeded = ($LASTEXITCODE -eq 0)
    # Prune runs regardless of the remove outcome (best-effort admin-file
    # reconciliation); its own exit code is not load-bearing for Removed.
    & $GitCliPath -C $RepoRoot worktree prune 2>$null | Out-Null
    return $removeSucceeded
}

function New-GCDisposableWorktree {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory = $false)][string]$GitCliPath = 'git'
    )

    # AC2: refuse a dirty invoking tree FIRST -- before any worktree exists.
    $cleanliness = Test-GCTreeClean -Path $RepoRoot -GitCliPath $GitCliPath
    if (-not $cleanliness.IsClean) {
        return [pscustomobject]@{
            Success       = $false
            RefusalReason = 'refused: uncommitted-changes'
            Path          = $null
            HeadSha       = $null
        }
    }

    $headShaRaw = & $GitCliPath -C $RepoRoot rev-parse HEAD 2>$null
    $headSha = script:ConvertTo-GCFirstLineTrimmed -Raw $headShaRaw
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($headSha)) {
        return [pscustomobject]@{
            Success       = $false
            RefusalReason = 'refused: head-sha-unresolvable'
            Path          = $null
            HeadSha       = $null
        }
    }

    # GUID-suffixed unique path outside the repo tree -- collision is
    # structurally impossible, mirroring pester-sharded-core.ps1:163-164.
    $worktreePath = Join-Path ([IO.Path]::GetTempPath()) "goal-validate-$([Guid]::NewGuid().ToString('N'))"

    # Full command form, <path> BEFORE the commit-ish (U25) -- the
    # compressed "--detach <sha>" shorthand omits the path and lets git pick
    # its own directory name instead of our unique, outside-the-repo path.
    # Detached is mandatory: a branch checkout hard-fails if that branch is
    # already checked out elsewhere (U4/F9).
    # R18: see script:Invoke-GCWorktreeRemoveAttempt's identical stdout-
    # discipline note above -- this function's return value is also
    # structurally consumed by callers.
    & $GitCliPath -C $RepoRoot worktree add --detach $worktreePath $headSha 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) {
        return [pscustomobject]@{
            Success       = $false
            RefusalReason = 'refused: worktree-create-failed'
            Path          = $null
            HeadSha       = $headSha
        }
    }

    return [pscustomobject]@{
        Success       = $true
        RefusalReason = $null
        Path          = $worktreePath
        HeadSha       = $headSha
    }
}

function Remove-GCDisposableWorktree {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$WorktreePath,
        [Parameter(Mandatory = $false)][string]$GitCliPath = 'git',
        [Parameter(Mandatory = $false)][int]$RetryDelayMs = 1000
    )

    $removed = $false
    try {
        $removed = script:Invoke-GCWorktreeRemoveAttempt -GitCliPath $GitCliPath -RepoRoot $RepoRoot -WorktreePath $WorktreePath
    } catch {
        $removed = $false
    }

    if (-not $removed) {
        # One bounded retry after a short delay (the persistent-failure
        # scenario this guards is a Windows handle lock held by an orphaned
        # check descendant -- worth one brief re-check before giving up).
        Start-Sleep -Milliseconds $RetryDelayMs
        try {
            $removed = script:Invoke-GCWorktreeRemoveAttempt -GitCliPath $GitCliPath -RepoRoot $RepoRoot -WorktreePath $WorktreePath
        } catch {
            $removed = $false
        }
    }

    if ($removed) {
        return [pscustomobject]@{ Removed = $true; OrphanedPath = $null }
    }

    # Persistent failure: NEVER throw to the caller (U2). Record the
    # orphaned path so it surfaces in the eventual verdict (s6 wires this
    # in) instead of becoming a warning that gets silently lost.
    Write-Warning "Remove-GCDisposableWorktree: '$WorktreePath' could not be removed after one retry; recording as orphaned."
    return [pscustomobject]@{ Removed = $false; OrphanedPath = $WorktreePath }
}

function Invoke-GCWorktreeSession {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory = $false)][scriptblock]$SuitePhase,
        [Parameter(Mandatory = $false)][scriptblock]$ChecksPhase,
        # s6 seam: invoked with the worktree path as its only argument, AFTER
        # ChecksPhase but still inside the try block -- the diff-integrity
        # phase needs the worktree's committed tree to still exist, and the
        # `finally` teardown below must still be the ONLY place that ever
        # removes it (mirrors the SuitePhase/ChecksPhase seam contract s2
        # already established; this function does not invent diff-integrity
        # semantics of its own, s6 supplies the real body).
        [Parameter(Mandatory = $false)][scriptblock]$DiffIntegrityPhase,
        [Parameter(Mandatory = $false)][string]$GitCliPath = 'git',
        [Parameter(Mandatory = $false)][int]$RetryDelayMs = 1000
    )

    $worktree = New-GCDisposableWorktree -RepoRoot $RepoRoot -GitCliPath $GitCliPath
    if (-not $worktree.Success) {
        return [pscustomobject]@{
            Refused             = $true
            RefusalReason       = $worktree.RefusalReason
            WorktreePath        = $null
            HeadSha             = $null
            SuiteResult         = $null
            ChecksResult        = $null
            DiffIntegrityResult = $null
            SuiteCleanliness    = $null
            ChecksCleanliness   = $null
            OrphanedPath        = $null
        }
    }

    $suiteResult = $null
    $checksResult = $null
    $diffIntegrityResult = $null
    $suiteCleanliness = $null
    $checksCleanliness = $null
    $orphanedPath = $null

    try {
        # Fixed order (s2 RC, extended by s6): suite first, against the
        # pristine checkout, THEN target checks, THEN diff-integrity -- all
        # three still inside this try block so the worktree is guaranteed to
        # exist for every phase and teardown still only ever happens once,
        # in `finally`, below.
        if ($SuitePhase) {
            $suiteResult = & $SuitePhase $worktree.Path
        }
        $suiteCleanliness = Test-GCTreeClean -Path $worktree.Path -GitCliPath $GitCliPath

        if ($ChecksPhase) {
            $checksResult = & $ChecksPhase $worktree.Path
        }
        $checksCleanliness = Test-GCTreeClean -Path $worktree.Path -GitCliPath $GitCliPath

        if ($DiffIntegrityPhase) {
            # PF1 (post-fix targeted prosecution, HIGH): pass the worktree's
            # PRE-CHECKS $worktree.HeadSha (captured by New-GCDisposableWorktree
            # before ANY phase runs) as the phase's second positional argument,
            # never letting the phase re-resolve `rev-parse HEAD` fresh after
            # the checks phase has already run. See the closure's own comment
            # in Invoke-GoalContractValidate for the full threat-model
            # rationale.
            $diffIntegrityResult = & $DiffIntegrityPhase $worktree.Path $worktree.HeadSha
        }
    }
    finally {
        # Always runs, including when a phase scriptblock throws: teardown
        # is guaranteed alongside the exception, not instead of it.
        $teardown = Remove-GCDisposableWorktree -RepoRoot $RepoRoot -WorktreePath $worktree.Path -GitCliPath $GitCliPath -RetryDelayMs $RetryDelayMs
        if (-not $teardown.Removed) {
            $orphanedPath = $teardown.OrphanedPath
        }
    }

    return [pscustomobject]@{
        Refused             = $false
        RefusalReason       = $null
        WorktreePath        = $worktree.Path
        HeadSha             = $worktree.HeadSha
        SuiteResult         = $suiteResult
        ChecksResult        = $checksResult
        DiffIntegrityResult = $diffIntegrityResult
        SuiteCleanliness    = $suiteCleanliness
        ChecksCleanliness   = $checksCleanliness
        OrphanedPath        = $orphanedPath
    }
}

# -----------------------------------------------------------------------------
# s3: target-check execution with a preemptive tree-killable timeout
# (frame-slice s3, AC1). `targets[].check` is untrusted comment-sourced data
# (M7); the trust boundary is edit-coherence (873-D7) -- this section
# executes it as a shell command via pwsh without attempting to sanitize or
# interpret its content beyond that. These functions are net-new (no
# production Process.Kill($true)-timeout precedent existed before this
# slice) and are standalone at s3: not yet threaded into
# Invoke-GCWorktreeSession's -ChecksPhase seam or Invoke-GoalContractValidate's
# control flow. s6 wires Invoke-GCTargetChecks into -ChecksPhase and folds
# its result into Resolve-GCVerdictDisposition alongside the s1/s4/s5
# signals.
# -----------------------------------------------------------------------------

function ConvertTo-GCWallClockSeconds {
    [CmdletBinding()]
    [OutputType([Nullable[int]])]
    param(
        [Parameter(Mandatory = $false)][AllowNull()][string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $null
    }

    # Accepted shapes: a bare integer (seconds), or an integer with a single
    # h/m/s suffix (case-insensitive) -- e.g. "4h", "300s", "90m". Any other
    # shape (e.g. compound "1h30m", non-numeric) is deliberately left
    # unparsed: the ceiling this feeds is advisory-only, so an unparseable
    # budget.wall_clock value degrades to "no ceiling applied" rather than a
    # guessed interpretation of an ambiguous contract field.
    if ($Value -match '^\s*(\d+)\s*([hHmMsS])?\s*$') {
        # R21: a bare [int] cast on the digit run (and, separately, on the
        # h/m-multiplied result) Int32-overflows and THROWS for a large
        # value like "99999999999h" -- reachable via the untrusted
        # budget.wall_clock contract field, and an uncaught throw here would
        # ride R9's now-caught infra-error path to a review-required
        # disposition instead of the documented "degrade to $null, no
        # ceiling applied" contract for an unparseable/out-of-range value.
        # [long]::TryParse never throws on an oversized digit run, and the
        # explicit Int32 bounds check after multiplication catches an
        # in-range magnitude whose h/m-scaled result would itself overflow.
        $magnitude = [long]0
        if (-not [long]::TryParse($Matches[1], [ref]$magnitude)) {
            return $null
        }
        $seconds = [long]0
        switch ($Matches[2]) {
            { $_ -in @('h', 'H') } { $seconds = $magnitude * 3600 }
            { $_ -in @('m', 'M') } { $seconds = $magnitude * 60 }
            default { $seconds = $magnitude }
        }
        if ($seconds -gt [int]::MaxValue -or $seconds -lt [int]::MinValue) {
            return $null
        }
        return [int]$seconds
    }

    return $null
}

# Private: shared preemptive-tree-kill process runner (RC item 2/3, U2/U3
# discipline). Both Invoke-GCTargetCheck (below, s3) and Invoke-GCSuitePhase
# (s4) need the identical start/redirect/timeout/kill/cleanup mechanics --
# only WHAT they do with the redirected output differs (Invoke-GCTargetCheck
# captures it into a byte-capped buffer for the report; Invoke-GCSuitePhase
# discards it, since its real result travels via a separate result file).
# This function owns the mechanics; callers own their own
# -StdOutAction/-StdErrAction (and -MessageData, when the action needs shared
# state) exactly as the pre-extraction call sites did. NEVER
# Stop-Job/Wait-Job (U2: does not kill descendant OS processes, orphaning
# grandchildren that hold worktree handles and break teardown):
# System.Diagnostics.Process + Kill($true) (the pwsh 7 / .NET Core 3+
# tree-kill overload), with a taskkill /PID <pid> /T /F fallback if
# Kill($true) itself throws on Windows.
function script:Invoke-GCTreeKillableProcess {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$FileName,
        [Parameter(Mandatory)][string[]]$ArgumentList,
        [Parameter(Mandatory = $false)][string]$WorkingDirectory,
        [Parameter(Mandatory)][int]$TimeoutSeconds,
        [Parameter(Mandatory = $false)][scriptblock]$StdOutAction = { },
        [Parameter(Mandatory = $false)][scriptblock]$StdErrAction = { },
        [Parameter(Mandatory = $false)][AllowNull()][object]$MessageData
    )

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $FileName
    foreach ($arg in $ArgumentList) {
        $psi.ArgumentList.Add($arg)
    }
    if (-not [string]::IsNullOrWhiteSpace($WorkingDirectory)) {
        $psi.WorkingDirectory = $WorkingDirectory
    }
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true

    $proc = [System.Diagnostics.Process]::new()
    $proc.StartInfo = $psi

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $timedOut = $false
    $exitCode = $null

    $sourceIdOut = "GCVProcOut_$([guid]::NewGuid().ToString('N'))"
    $sourceIdErr = "GCVProcErr_$([guid]::NewGuid().ToString('N'))"

    try {
        Register-ObjectEvent -InputObject $proc -EventName OutputDataReceived -SourceIdentifier $sourceIdOut -MessageData $MessageData -Action $StdOutAction | Out-Null
        Register-ObjectEvent -InputObject $proc -EventName ErrorDataReceived -SourceIdentifier $sourceIdErr -MessageData $MessageData -Action $StdErrAction | Out-Null

        $proc.Start() | Out-Null
        $proc.BeginOutputReadLine()
        $proc.BeginErrorReadLine()

        $exited = $proc.WaitForExit([Math]::Max(0, $TimeoutSeconds) * 1000)

        if (-not $exited) {
            $timedOut = $true
            try {
                $proc.Kill($true)
            } catch {
                if ($IsWindows) {
                    try { & taskkill /PID $proc.Id /T /F 2>$null | Out-Null } catch { }
                }
            }
            $null = $proc.WaitForExit(10000)
        } else {
            # Ensure the async output/error event pump fully drains before
            # the caller reads any captured buffers (the documented .NET
            # pattern for redirected + event-based process output: call the
            # parameterless WaitForExit() after the timed overload returns
            # $true).
            $proc.WaitForExit()
        }

        # Marshal the exit code explicitly from the Process object's own
        # ExitCode property -- never from a job's State, which can report
        # Completed even when the underlying check failed.
        try {
            $exitCode = $proc.ExitCode
        } catch {
            $exitCode = $null
        }
    } finally {
        Unregister-Event -SourceIdentifier $sourceIdOut -ErrorAction SilentlyContinue
        Unregister-Event -SourceIdentifier $sourceIdErr -ErrorAction SilentlyContinue
        Remove-Job -Name $sourceIdOut -Force -ErrorAction SilentlyContinue
        Remove-Job -Name $sourceIdErr -Force -ErrorAction SilentlyContinue
        $proc.Dispose()
    }
    $stopwatch.Stop()

    return [pscustomobject]@{
        ExitCode  = $exitCode
        TimedOut  = $timedOut
        ElapsedMs = $stopwatch.ElapsedMilliseconds
    }
}

function Invoke-GCTargetCheck {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][object]$Target,
        [Parameter(Mandatory)][string]$WorktreePath,
        [Parameter(Mandatory = $false)][int]$TimeoutSeconds = 300,
        [Parameter(Mandatory = $false)][int]$OutputCapBytes = 65536,
        [Parameter(Mandatory = $false)][string]$PwshCliPath = 'pwsh'
    )

    $targetId = [string]$Target.id

    # RC item 6: a missing OR blank falsifier is a purely-informational
    # advisory flag -- genuine vacuity detection is undecidable (U13), so
    # this is a cheap non-vacuity nudge, never a pass/fail gate.
    $advisoryFlags = [System.Collections.Generic.List[string]]::new()
    $hasFalsifier = $false
    if (script:Test-GCPropertyPresent -Target $Target -Name 'falsifier') {
        $hasFalsifier = -not [string]::IsNullOrWhiteSpace([string]$Target.falsifier)
    }
    if (-not $hasFalsifier) {
        $advisoryFlags.Add('falsifier-absent')
    }

    $check = [string]$Target.check

    # RC item 5: a blank/whitespace-only check is a per-target floor -- a
    # target that checks nothing cannot honestly report pass. No process is
    # spawned.
    if ([string]::IsNullOrWhiteSpace($check)) {
        return [pscustomobject]@{
            Id              = $targetId
            Outcome         = 'fail'
            ExitCode        = $null
            TimedOut        = $false
            Reason          = 'refused: blank-check'
            AdvisoryFlags   = @($advisoryFlags)
            StdOut          = ''
            StdErr          = ''
            StdOutTruncated = $false
            StdErrTruncated = $false
            ElapsedMs       = 0
        }
    }

    # Stream-bounded capture (RC item 7 / U20): a synchronized hashtable so
    # the async OutputDataReceived/ErrorDataReceived event actions (which run
    # disconnected from this function's lexical scope) can safely mutate
    # shared state. The accumulated in-memory buffer is genuinely capped,
    # not just the eventual report excerpt -- but the cap check only runs
    # between complete lines: OutputDataReceived/ErrorDataReceived fire once
    # per whole line (or at EOF), so a single very large newline-free line
    # is fully materialized before the cap can engage, and peak memory for
    # that one line is unbounded. Known, accepted limitation (issue #894).
    $outState = [hashtable]::Synchronized(@{
        StdOut          = [System.Text.StringBuilder]::new()
        StdOutBytes     = 0
        StdOutTruncated = $false
        StdErr          = [System.Text.StringBuilder]::new()
        StdErrBytes     = 0
        StdErrTruncated = $false
        CapBytes        = $OutputCapBytes
    })

    $stdOutAction = {
        $line = $EventArgs.Data
        if ($null -eq $line) { return }
        $state = $Event.MessageData
        if ($state.StdOutTruncated) { return }
        $bytes = [System.Text.Encoding]::UTF8.GetByteCount($line) + 1
        if (($state.StdOutBytes + $bytes) -gt $state.CapBytes) {
            [void]$state.StdOut.Append('...[output truncated: cap reached]...')
            $state.StdOutTruncated = $true
            return
        }
        [void]$state.StdOut.AppendLine($line)
        $state.StdOutBytes += $bytes
    }
    $stdErrAction = {
        $line = $EventArgs.Data
        if ($null -eq $line) { return }
        $state = $Event.MessageData
        if ($state.StdErrTruncated) { return }
        $bytes = [System.Text.Encoding]::UTF8.GetByteCount($line) + 1
        if (($state.StdErrBytes + $bytes) -gt $state.CapBytes) {
            [void]$state.StdErr.Append('...[output truncated: cap reached]...')
            $state.StdErrTruncated = $true
            return
        }
        [void]$state.StdErr.AppendLine($line)
        $state.StdErrBytes += $bytes
    }

    # RC items 2/3 (PREEMPTIVE TREE-KILL) and RC item 3 (explicit ExitCode
    # marshalling) both live in the shared script:Invoke-GCTreeKillableProcess
    # helper -- see that function's own doc comment for the discipline this
    # relies on (U2/U3).
    $procResult = script:Invoke-GCTreeKillableProcess -FileName $PwshCliPath -ArgumentList @('-NoProfile', '-NoLogo', '-NonInteractive', '-Command', $check) -WorkingDirectory $WorktreePath -TimeoutSeconds $TimeoutSeconds -StdOutAction $stdOutAction -StdErrAction $stdErrAction -MessageData $outState

    # RC item 4: timeout ALWAYS maps to fail -- never refused, never
    # review-required.
    $outcome = 'pass'
    $reason = $null
    if ($procResult.TimedOut) {
        $outcome = 'fail'
        $reason = "timeout: check exceeded ${TimeoutSeconds}s and was tree-killed"
    } elseif ($procResult.ExitCode -ne 0) {
        $outcome = 'fail'
    }

    return [pscustomobject]@{
        Id              = $targetId
        Outcome         = $outcome
        ExitCode        = $procResult.ExitCode
        TimedOut        = $procResult.TimedOut
        Reason          = $reason
        AdvisoryFlags   = @($advisoryFlags)
        StdOut          = $outState.StdOut.ToString()
        StdErr          = $outState.StdErr.ToString()
        StdOutTruncated = $outState.StdOutTruncated
        StdErrTruncated = $outState.StdErrTruncated
        ElapsedMs       = $procResult.ElapsedMs
    }
}

function Invoke-GCTargetChecks {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][object[]]$Targets,
        [Parameter(Mandatory)][string]$WorktreePath,
        [Parameter(Mandatory = $false)][int]$TimeoutSeconds = 300,
        [Parameter(Mandatory = $false)][int]$OutputCapBytes = 65536,
        [Parameter(Mandatory = $false)][AllowNull()][string]$BudgetWallClock,
        [Parameter(Mandatory = $false)][string]$PwshCliPath = 'pwsh'
    )

    $results = [System.Collections.Generic.List[object]]::new()
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    foreach ($target in @($Targets)) {
        $results.Add((Invoke-GCTargetCheck -Target $target -WorktreePath $WorktreePath -TimeoutSeconds $TimeoutSeconds -OutputCapBytes $OutputCapBytes -PwshCliPath $PwshCliPath))
    }

    $stopwatch.Stop()

    # RC item 7: advisory total ceiling across all targets -- never a hard
    # per-target replacement for TimeoutSeconds above, and never changes any
    # individual target's Outcome. Exceeding it only sets the aggregate
    # BudgetExceeded flag for s6 to surface as a mandatory-review signal.
    $budgetSeconds = ConvertTo-GCWallClockSeconds -Value $BudgetWallClock
    $budgetExceeded = ($null -ne $budgetSeconds) -and ($stopwatch.Elapsed.TotalSeconds -gt $budgetSeconds)

    return [pscustomobject]@{
        Targets                = @($results)
        TotalElapsedMs         = $stopwatch.ElapsedMilliseconds
        BudgetWallClockSeconds = $budgetSeconds
        BudgetExceeded         = $budgetExceeded
    }
}

# -----------------------------------------------------------------------------
# s4: suite invariant -- the green floor (frame-slice s4, AC1/AC3). THE FIX
# THIS SLICE EXISTS FOR (U1, CRITICAL, stress-test-sustained): Invoke-PesterSharded
# (pester-sharded-core.ps1:84) returns `ExitCode=1, TotalFailed=0` in THREE
# distinct situations -- TestsPath not found (:100-103), zero .Tests.ps1
# files discovered (:109-112), and the MinTestCount floor (default 200) not
# met (:397-400, which sets ExitCode but does NOT increment TotalFailed).
# Gating the green floor on `TotalFailed -eq 0` alone reports a suite that
# never ran as PASS -- exactly the false-GREEN defect this validator exists
# to prevent, reintroduced at this consumer. Test-GCSuiteGatePass is the
# fix, isolated as its own pure function so every shape is directly
# unit-testable against a hand-constructed mock result object, without a
# real Pester sub-run per test case.
#
# NO FLAKE-QUENCH (U5, judge-sustained HIGH, dropped from this plan
# entirely): any suite failure -- flaky or not -- is `fail`. The
# `Compare-RunResults` reuse seam this would have needed is not a reusable
# suppression primitive: it is `script:`-scoped inside
# pester-sharded-core.ps1 (:416) and detects determinism FLIPS between two
# -DeterminismCheck runs, not a suppressor, and `FailedFiles` folds in
# crash/missing-result entries that a retry-to-green would silently quench
# as "flaky". This section contains NO retry-the-suite-on-failure logic.
# -----------------------------------------------------------------------------

function Test-GCSuiteGatePass {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $false)][AllowNull()][object]$Result
    )

    if ($null -eq $Result) {
        return $false
    }

    $hasExitCode = $Result.PSObject.Properties.Match('ExitCode').Count -gt 0
    $hasTotalFailed = $Result.PSObject.Properties.Match('TotalFailed').Count -gt 0
    if (-not $hasExitCode -or -not $hasTotalFailed) {
        return $false
    }

    # R10: the documented contract is "never throws, fails closed to
    # $false" for a $null/missing ExitCode/TotalFailed -- but a
    # PRESENT-but-$null ExitCode/TotalFailed previously passed the
    # property-existence check above and then got silently [int]-cast to 0
    # (live-reproduced: {ExitCode=$null;TotalFailed=$null;TotalPassed=250}
    # returned $true, a false-GREEN from the gate itself), while a
    # non-numeric ExitCode threw instead of failing closed. Explicit
    # null-then-TryParse checks close both gaps before any [int] cast runs.
    $exitCodeRaw = $Result.ExitCode
    $totalFailedRaw = $Result.TotalFailed
    if ($null -eq $exitCodeRaw -or $null -eq $totalFailedRaw) {
        return $false
    }

    $exitCode = 0
    $totalFailed = 0
    if (-not [int]::TryParse([string]$exitCodeRaw, [ref]$exitCode)) {
        return $false
    }
    if (-not [int]::TryParse([string]$totalFailedRaw, [ref]$totalFailed)) {
        return $false
    }

    $totalPassed = 0
    if ($Result.PSObject.Properties.Match('TotalPassed').Count -gt 0) {
        $totalPassedRaw = $Result.TotalPassed
        if ($null -ne $totalPassedRaw) {
            [void][int]::TryParse([string]$totalPassedRaw, [ref]$totalPassed)
        }
    }

    # The three-part gate (U1 CRITICAL fix): ExitCode==0 AND TotalFailed==0
    # AND (Passed+Failed)>0 -- NEVER TotalFailed alone. ExitCode alone
    # already rejects the TestsPath-not-found, zero-discovered, and
    # MinTestCount-floor shapes (all three set ExitCode=1); the ran-guard
    # (clause 3) is an independent defensive floor against a hypothetical
    # ExitCode=0-but-nothing-ran shape.
    return ($exitCode -eq 0) -and ($totalFailed -eq 0) -and (($totalPassed + $totalFailed) -gt 0)
}

# Private: the single fail-closed result shape this section ever returns for
# a non-green outcome that did not come from a real, parsed Invoke-PesterSharded
# result (timeout, missing runner-lib copy, missing/unparseable result file).
# Centralized so every fail-closed exit path in Invoke-GCSuitePhase produces
# the identical shape Test-GCSuiteGatePass rejects on ExitCode.
function script:New-GCFailClosedSuiteResult {
    param([switch]$TimedOut)
    [pscustomobject]@{
        ExitCode     = 1
        TotalPassed  = 0
        TotalFailed  = 0
        WallClockMs  = $null
        MissingFiles = @()
        FailedFiles  = @()
        TimedOut     = [bool]$TimedOut
    }
}

function Invoke-GCSuitePhase {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$WorktreePath,
        [Parameter(Mandatory = $false)][int]$TimeoutSeconds = 1800,
        [Parameter(Mandatory = $false)][int]$MinTestCount = 200,
        [Parameter(Mandatory = $false)][string]$PwshCliPath = 'pwsh'
    )

    $libPath = Join-Path $WorktreePath '.github/scripts/lib/pester-sharded-core.ps1'
    $testsPath = Join-Path $WorktreePath '.github/scripts/Tests'

    # Fail-closed BEFORE spawning anything: an absent runner copy in the
    # worktree must never be silently treated as "nothing to run, so pass".
    if (-not (Test-Path -LiteralPath $libPath -PathType Leaf)) {
        Write-Warning "Invoke-GCSuitePhase: worktree runner lib not found at '$libPath'."
        return script:New-GCFailClosedSuiteResult
    }

    $tempDir = Join-Path ([IO.Path]::GetTempPath()) "goal-validate-suite-$([Guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
    $resultFile = Join-Path $tempDir 'suite-result.json'
    $launchFile = Join-Path $tempDir 'suite-launcher.ps1'

    # RC item 1: shell out to a CHILD pwsh process that dot-sources the
    # copy of pester-sharded-core.ps1 living INSIDE THE WORKTREE and calls
    # Invoke-PesterSharded with an EXPLICIT -TestsPath -- never the copy in
    # the invoking repo, never the $PSScriptRoot-relative default this
    # function otherwise falls back to. Single-quote literals in a
    # here-string are safe (mirroring the Get-ShardLauncherScript pattern
    # already used by pester-sharded-core.ps1); paths are embedded via
    # @"..."@ substitution with '' escaping for embedded single quotes.
    $launcherContent = @"
#Requires -Version 7.0
try {
    . '$($libPath -replace "'", "''")'
    `$r = Invoke-PesterSharded -TestsPath '$($testsPath -replace "'", "''")' -MinTestCount $MinTestCount
    `$out = [ordered]@{
        ExitCode     = `$r.ExitCode
        TotalPassed  = `$r.TotalPassed
        TotalFailed  = `$r.TotalFailed
        WallClockMs  = `$r.WallClockMs
        MissingFiles = @(`$r.MissingFiles)
        FailedFiles  = @(`$r.FailedFiles)
    }
    `$out | ConvertTo-Json -Compress -Depth 5 | Set-Content -LiteralPath '$($resultFile -replace "'", "''")' -Encoding UTF8
    exit ([int]`$r.ExitCode)
} catch {
    Write-Error `$_
    exit 2
}
"@
    [IO.File]::WriteAllText($launchFile, $launcherContent, [Text.UTF8Encoding]::new($false))

    # Redirected and drained asynchronously (discarded, not captured, via the
    # shared helper's default no-op -StdOutAction/-StdErrAction): the child
    # pwsh process running the full sharded suite otherwise INHERITS this
    # process's own console handles, so its host/warning/verbosity chatter
    # would leak straight into whatever invoked Invoke-GoalContractValidate
    # -- corrupting the wrapper script's documented stdout-is-parseable-JSON
    # contract (Part D) once this phase is actually wired into the real
    # pipeline (s6). The real result is already communicated via
    # $resultFile below, never via these streams, so draining without
    # capturing is sufficient; leaving them un-redirected risked both the
    # console leak AND an eventual pipe-buffer deadlock on a verbose run.
    #
    # RC item 3: PREEMPTIVE TREE-KILL around the ENTIRE suite run -- the
    # same discipline the s3 function Invoke-GCTargetCheck uses (U2/U3),
    # both via the shared script:Invoke-GCTreeKillableProcess helper.
    $procResult = script:Invoke-GCTreeKillableProcess -FileName $PwshCliPath -ArgumentList @('-NoProfile', '-NoLogo', '-NonInteractive', '-File', $launchFile) -TimeoutSeconds $TimeoutSeconds

    if ($procResult.TimedOut) {
        Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
        # RC item 3: a suite-phase timeout ALWAYS maps to fail.
        return script:New-GCFailClosedSuiteResult -TimedOut
    }

    $resultObj = $null
    if (Test-Path -LiteralPath $resultFile) {
        try {
            $resultObj = Get-Content -LiteralPath $resultFile -Raw | ConvertFrom-Json
        } catch {
            $resultObj = $null
        }
    }
    Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue

    if ($null -eq $resultObj) {
        # Child exited without a parseable result file (e.g. crashed before
        # writing it) -- fail-closed, never a silent pass.
        return script:New-GCFailClosedSuiteResult
    }

    return [pscustomobject]@{
        ExitCode     = [int]$resultObj.ExitCode
        TotalPassed  = [int]$resultObj.TotalPassed
        TotalFailed  = [int]$resultObj.TotalFailed
        WallClockMs  = $resultObj.WallClockMs
        MissingFiles = @($resultObj.MissingFiles)
        FailedFiles  = @($resultObj.FailedFiles)
        TimedOut     = $false
    }
}

# -----------------------------------------------------------------------------
# s5: test-diff integrity invariant (frame-slice s5, AC1/AC2). Every signal in
# this section is a MANDATORY-REVIEW FLAG, never a block -- s6 folds a
# non-empty Flags array into Resolve-GCVerdictDisposition's
# -HasReviewRequired path alongside the s1/s3/s4 signals. Net-new: no
# production `git merge-base` explicit-SHA precedent, AST `Should`-count
# precedent, or `--diff-filter=DR --no-renames` test-deletion precedent
# existed before this slice. These functions are standalone at s5, like s3/s4:
# not yet threaded into Invoke-GCWorktreeSession's seams or
# Invoke-GoalContractValidate's control flow.
# -----------------------------------------------------------------------------

# The only two invariants[] literals this validator interprets (872's schema
# requires at least these two; the array may legally carry more). Any other
# literal is surfaced by Test-GCUnrecognizedInvariants below.
$script:GCVKnownInvariants = @('full-pester-suite-no-new-failures', 'test-diff-integrity')

function Resolve-GCDiffBase {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$WorktreePath,
        [Parameter(Mandatory)][string]$RunSha,
        [Parameter(Mandatory = $false)][string]$DefaultRef = 'origin/main',
        [Parameter(Mandatory = $false)][string]$GitCliPath = 'git'
    )

    # RC item 1: resolve <default-sha> from a ref that is ALREADY PRESENT
    # locally -- NEVER `git fetch`. A worktree shares the operator's object
    # store and remote-tracking refs, so a fetch here would mutate the
    # operator's real repo's refs as a side effect. An absent ref refuses
    # rather than fetching.
    $defaultShaRaw = & $GitCliPath -C $WorktreePath rev-parse $DefaultRef 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($defaultShaRaw)) {
        return [pscustomobject]@{
            Refused       = $true
            RefusalReason = "refused: default-ref-unresolvable (the local ref '$DefaultRef' is not present; refusing rather than fetching, since a fetch inside a disposable worktree would mutate the operator's real remote-tracking refs)"
            DefaultSha    = $null
            RunSha        = $RunSha
            MergeBaseSha  = $null
        }
    }
    $defaultSha = script:ConvertTo-GCFirstLineTrimmed -Raw $defaultShaRaw

    # Explicit SHA arguments in a PINNED working directory (-C $WorktreePath)
    # -- never symbolic HEAD, which could resolve to whatever branch the
    # invoking process happens to be on rather than this run's own commit.
    $mergeBaseRaw = & $GitCliPath -C $WorktreePath merge-base $defaultSha $RunSha 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($mergeBaseRaw)) {
        return [pscustomobject]@{
            Refused       = $true
            RefusalReason = "refused: merge-base-unresolvable (git merge-base $defaultSha $RunSha failed; the two commits may not share history)"
            DefaultSha    = $defaultSha
            RunSha        = $RunSha
            MergeBaseSha  = $null
        }
    }
    $mergeBaseSha = script:ConvertTo-GCFirstLineTrimmed -Raw $mergeBaseRaw

    # RC item 2: merge-base == run-sha means there is no run diff to audit.
    # The message states only the OBSERVED condition, not a guessed cause --
    # no commits beyond the default, a direct-to-default commit, and an
    # already-merged tip are all indistinguishable from git state alone.
    if ($mergeBaseSha -eq $RunSha) {
        return [pscustomobject]@{
            Refused       = $true
            RefusalReason = "refused: no-run-diff (merge-base($defaultSha, $RunSha) equals the run sha $RunSha; observed condition only -- this cannot be distinguished, from git state alone, between the run introducing no commits beyond the default branch, the run committing directly to the default branch, or the run's tip already being merged into the default branch)"
            DefaultSha    = $defaultSha
            RunSha        = $RunSha
            MergeBaseSha  = $mergeBaseSha
        }
    }

    return [pscustomobject]@{
        Refused       = $false
        RefusalReason = $null
        DefaultSha    = $defaultSha
        RunSha        = $RunSha
        MergeBaseSha  = $mergeBaseSha
    }
}

function Test-GCTestFileDeletion {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$WorktreePath,
        [Parameter(Mandatory)][string]$BaseSha,
        [Parameter(Mandatory)][string]$RunSha,
        [Parameter(Mandatory = $false)][string[]]$AllowlistPathspecs = @('.github/scripts/Tests'),
        [Parameter(Mandatory = $false)][string]$GitCliPath = 'git'
    )

    # RC item 3: --diff-filter=DR (deletion, including what would otherwise
    # register as a rename) combined with --no-renames (forces git to NEVER
    # collapse a delete+create pair into a rename) -- deliberate: a plain
    # --diff-filter=D alone misses a rename-and-gut evasion, because git's
    # default rename heuristic reclassifies a high-similarity delete+create
    # pair as a single R status, which --diff-filter=D does not match.
    $diffArgs = @('-C', $WorktreePath, 'diff', '--name-only', '--diff-filter=DR', '--no-renames', $BaseSha, $RunSha, '--') + @($AllowlistPathspecs)
    $rawOutput = & $GitCliPath @diffArgs 2>$null
    if ($LASTEXITCODE -ne 0) {
        # R4: fail CLOSED toward MORE review, never toward "nothing changed"
        # -- this signal is an advisory mandatory-review flag, never a hard
        # gate, so erring toward more review-flagging on a git-diff failure
        # is the safe direction (mirrors R3's fail-closed discipline for
        # Test-GCTreeClean, reapplied here since this detector suppressed
        # stderr with no $LASTEXITCODE check).
        #
        # PF2 (post-fix targeted prosecution, LOW): the error sentinel text
        # travels on GitError/ErrorDetail, never stuffed into DeletedFiles --
        # DeletedFiles is reserved for actual deleted-file paths so a
        # git-command failure can never be mistaken, downstream, for a
        # literal (attacker-influenceable) filename under the same Kind a
        # real deletion finding would use. Invoke-GCDiffIntegrityPhase reads
        # GitError to route this case to the dedicated
        # 'diff-integrity-git-error' Kind instead of 'test-file-deletion'.
        return [pscustomobject]@{
            Flagged      = $true
            DeletedFiles = @()
            GitError     = $true
            ErrorDetail  = "git diff failed (exit $LASTEXITCODE) while checking for deleted test files between $BaseSha and $RunSha; unable to verify -- flagging for review"
        }
    }
    $deletedFiles = @(@($rawOutput) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_.Trim() })

    return [pscustomobject]@{
        Flagged      = ($deletedFiles.Count -gt 0)
        DeletedFiles = $deletedFiles
        GitError     = $false
        ErrorDetail  = $null
    }
}

function Get-GCShouldCommandCount {
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory = $false)][AllowNull()][AllowEmptyString()][string]$Content
    )

    if ([string]::IsNullOrEmpty($Content)) {
        return 0
    }

    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($Content, [ref]$tokens, [ref]$parseErrors)
    if ($null -eq $ast) {
        return 0
    }

    # RC item 4: AST-aware, not substring -- count actual `Should` COMMAND
    # invocations (CommandAst nodes whose command name is 'Should'), never a
    # substring/regex match, which mis-hits comments, string literals,
    # SupportsShouldProcess, and $PSCmdlet.ShouldProcess (none of which are
    # Pester assertions; none of those shapes are a CommandAst named
    # 'Should', so they are excluded structurally, not by extra filtering).
    $commandAsts = $ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Should'
        }, $true)

    return @($commandAsts).Count
}

function Test-GCAssertionWeakening {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$WorktreePath,
        [Parameter(Mandatory)][string]$BaseSha,
        [Parameter(Mandatory)][string]$RunSha,
        [Parameter(Mandatory = $false)][AllowEmptyCollection()][string[]]$ChangedTestFilePaths = @(),
        [Parameter(Mandatory = $false)][string]$GitCliPath = 'git'
    )

    # RC item 4: labelled an honest heuristic -- count-preserving weakening
    # (Should -Be $exactValue -> Should -Not -BeNullOrEmpty) keeps the same
    # count and is NOT detectable by count alone. This note travels with the
    # result regardless of whether anything was flagged.
    $heuristicNote = 'honest heuristic: counts Should command invocations via AST parsing and flags a DECREASE between base and run; count-preserving weakening (e.g. Should -Be $exactValue replaced with Should -Not -BeNullOrEmpty) keeps the same count and is not detectable by this signal.'

    $regressedFiles = [System.Collections.Generic.List[object]]::new()

    foreach ($path in @($ChangedTestFilePaths)) {
        $baseContentLines = & $GitCliPath -C $WorktreePath show "${BaseSha}:${path}" 2>$null
        $baseExists = ($LASTEXITCODE -eq 0)
        $runContentLines = & $GitCliPath -C $WorktreePath show "${RunSha}:${path}" 2>$null
        $runExists = ($LASTEXITCODE -eq 0)

        # Only compare when the file exists at BOTH commits -- a file absent
        # at one side is deletion-class territory (Test-GCTestFileDeletion's
        # concern), not an assertion-count regression.
        if (-not $baseExists -or -not $runExists) {
            continue
        }

        $baseCount = Get-GCShouldCommandCount -Content (@($baseContentLines) -join "`n")
        $runCount = Get-GCShouldCommandCount -Content (@($runContentLines) -join "`n")

        if ($runCount -lt $baseCount) {
            $regressedFiles.Add([pscustomobject]@{
                    Path      = $path
                    BaseCount = $baseCount
                    RunCount  = $runCount
                })
        }
    }

    return [pscustomobject]@{
        Flagged       = ($regressedFiles.Count -gt 0)
        Files         = @($regressedFiles)
        HeuristicNote = $heuristicNote
    }
}

# Private: detects `.github/scripts/lib/*.ps1` dot-source references within
# one Tests file's already-line-split content, against a known set of real
# lib filenames. Shared by Get-GCHelperLibSet's live-worktree read AND its
# R8 merge-base-commit read below, so the detection logic (quoted-literal,
# one-hop $script: variable indirection, and R13's unquoted-bareword shape)
# lives in exactly one place.
function script:Get-GCDotSourcedLibNamesInLines {
    param(
        # AllowEmptyString is required ALONGSIDE AllowEmptyCollection: a
        # Mandatory [string[]] parameter validates each ELEMENT for
        # null/empty too (a real PowerShell gotcha), and a file split on
        # newlines routinely produces empty-string elements (e.g. a
        # trailing newline, or a blank line in the source).
        [Parameter(Mandatory)][AllowEmptyCollection()][AllowEmptyString()][string[]]$Lines,
        [Parameter(Mandatory)][AllowEmptyCollection()][AllowEmptyString()][string[]]$LibFileNames
    )

    $dq = [char]34
    $literalPattern = "['$dq]([^'$dq]*\.ps1)['$dq]"
    $found = [System.Collections.Generic.HashSet[string]]::new()
    $indirectVars = [System.Collections.Generic.List[string]]::new()

    # RC item 5, pass 1: direct dot-source lines -- e.g. `. (Join-Path $x
    # 'lib/name.ps1')`, `. (Join-Path $x '..' 'lib' 'name.ps1')`. A quoted
    # literal ending .ps1 whose BASENAME names a real lib file is taken
    # directly (grounded by real existence, not path-shape guessing).
    foreach ($line in $Lines) {
        if ($line -match '^\s*\.\s+(.+)$') {
            $rest = $Matches[1]
            $literalMatches = [regex]::Matches($rest, $literalPattern)
            if ($literalMatches.Count -gt 0) {
                foreach ($mm in $literalMatches) {
                    $leaf = Split-Path -Leaf $mm.Groups[1].Value
                    if ($LibFileNames -contains $leaf) { [void]$found.Add($leaf) }
                }
            } elseif ($rest -match '^\$(?:script:)?([A-Za-z0-9_]+)\s*$') {
                # RC item 5, pass-2 candidate: `. $script:CoreFile`-style
                # indirection -- the dot-source line names a bare variable,
                # not a literal.
                $indirectVars.Add($Matches[1])
            } elseif ($rest -match '(\S+\.ps1)\s*$') {
                # R13: an UNQUOTED bareword dot-source (no quotes at all),
                # e.g. `. $PSScriptRoot\lib\foo.ps1` -- matched neither the
                # quoted-literal branch above nor the bare-variable-only
                # indirection branch, and was previously silently missed.
                $leaf = Split-Path -Leaf $Matches[1]
                if ($LibFileNames -contains $leaf) { [void]$found.Add($leaf) }
            }
        }
    }

    # Pass 2: resolve each indirection variable against its OWN assignment
    # line(s) in the same file (e.g. `$script:LibFile = Join-Path
    # $script:RepoRoot '.github/scripts/lib/name.ps1'`).
    foreach ($varName in @($indirectVars | Select-Object -Unique)) {
        $assignPattern = '\$(?:script:)?' + [regex]::Escape($varName) + '\s*=\s*(.+)$'
        foreach ($line in $Lines) {
            if ($line -match $assignPattern) {
                $assignRhs = $Matches[1]
                $literalMatches = [regex]::Matches($assignRhs, $literalPattern)
                foreach ($mm in $literalMatches) {
                    $leaf = Split-Path -Leaf $mm.Groups[1].Value
                    if ($LibFileNames -contains $leaf) { [void]$found.Add($leaf) }
                }
            }
        }
    }

    return @($found)
}

function Get-GCHelperLibSet {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        # R8: when supplied, the set is computed from THIS commit (intended:
        # the diff-integrity phase's own merge-base) via `git ls-tree`/`git
        # show`, never the run's OWN live worktree state. Without this, an
        # adversarial run could de-reference a helper's dot-source line
        # (Should-count unchanged, file not deleted -- undetected by the
        # other two detectors), then gut the now-unreferenced helper,
        # evading detection since it would silently drop out of a
        # live-computed allowlist. A blank/absent -BaseSha keeps the pre-R8
        # live-worktree-read behavior (relied on by this function's own
        # standalone unit tests, which write uncommitted fixture files with
        # no git repo at all).
        [Parameter(Mandatory = $false)][AllowNull()][AllowEmptyString()][string]$BaseSha,
        [Parameter(Mandatory = $false)][string]$GitCliPath = 'git'
    )

    if (-not [string]::IsNullOrWhiteSpace($BaseSha)) {
        $libListRaw = & $GitCliPath -C $RepoRoot ls-tree -r --name-only $BaseSha -- '.github/scripts/lib' 2>$null
        if ($LASTEXITCODE -ne 0) { return @() }
        $libFileNames = @(@($libListRaw) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and $_.Trim() -match '\.ps1$' } | ForEach-Object { Split-Path -Leaf $_.Trim() })
        if ($libFileNames.Count -eq 0) { return @() }

        $testsListRaw = & $GitCliPath -C $RepoRoot ls-tree -r --name-only $BaseSha -- '.github/scripts/Tests' 2>$null
        if ($LASTEXITCODE -ne 0) { return @() }
        $testsFilePaths = @(@($testsListRaw) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and $_.Trim() -match '\.Tests\.ps1$' } | ForEach-Object { $_.Trim() })

        $found = [System.Collections.Generic.HashSet[string]]::new()
        foreach ($tfPath in $testsFilePaths) {
            $rawContent = & $GitCliPath -C $RepoRoot show "${BaseSha}:${tfPath}" 2>$null
            if ($LASTEXITCODE -ne 0) { continue }
            foreach ($leaf in (script:Get-GCDotSourcedLibNamesInLines -Lines @($rawContent) -LibFileNames $libFileNames)) {
                [void]$found.Add($leaf)
            }
        }

        return @($found | Sort-Object | ForEach-Object { ".github/scripts/lib/$_" })
    }

    $libDir = Join-Path $RepoRoot '.github/scripts/lib'
    $testsDir = Join-Path $RepoRoot '.github/scripts/Tests'

    if (-not (Test-Path -LiteralPath $libDir -PathType Container) -or -not (Test-Path -LiteralPath $testsDir -PathType Container)) {
        return @()
    }

    $libFileNames = @(Get-ChildItem -LiteralPath $libDir -Filter '*.ps1' -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
    if ($libFileNames.Count -eq 0) {
        return @()
    }

    $testsFiles = Get-ChildItem -LiteralPath $testsDir -Filter '*.Tests.ps1' -Recurse -ErrorAction SilentlyContinue
    $found = [System.Collections.Generic.HashSet[string]]::new()

    foreach ($tf in $testsFiles) {
        $content = Get-Content -LiteralPath $tf.FullName -Raw -ErrorAction SilentlyContinue
        if ([string]::IsNullOrEmpty($content)) { continue }
        $lines = $content -split "`n"
        foreach ($leaf in (script:Get-GCDotSourcedLibNamesInLines -Lines $lines -LibFileNames $libFileNames)) {
            [void]$found.Add($leaf)
        }
    }

    return @($found | Sort-Object | ForEach-Object { ".github/scripts/lib/$_" })
}

function Test-GCFixtureOrHelperModification {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$WorktreePath,
        [Parameter(Mandatory)][string]$BaseSha,
        [Parameter(Mandatory)][string]$RunSha,
        [Parameter(Mandatory = $false)][string[]]$HelperLibPaths = @(),
        [Parameter(Mandatory = $false)][string]$GitCliPath = 'git'
    )

    # RC item 5: any changed file under .github/scripts/Tests/fixtures/** OR
    # any changed file in the live-computed helper-lib set.
    $pathspecs = @('.github/scripts/Tests/fixtures') + @($HelperLibPaths)
    $diffArgs = @('-C', $WorktreePath, 'diff', '--name-only', $BaseSha, $RunSha, '--') + $pathspecs
    $rawOutput = & $GitCliPath @diffArgs 2>$null
    if ($LASTEXITCODE -ne 0) {
        # R4: same fail-CLOSED-toward-more-review discipline as
        # Test-GCTestFileDeletion above -- an advisory flag, never a hard
        # gate, so a git-diff failure must never silently read as "nothing
        # changed".
        #
        # PF2 (post-fix targeted prosecution, LOW): same GitError/ErrorDetail
        # routing as Test-GCTestFileDeletion above -- the error sentinel text
        # never lands in ChangedFiles, so it can never be mistaken for a
        # literal changed-file path under the 'fixture-or-helper-modification'
        # Kind. Invoke-GCDiffIntegrityPhase reads GitError to route this case
        # to the dedicated 'diff-integrity-git-error' Kind instead.
        return [pscustomobject]@{
            Flagged      = $true
            ChangedFiles = @()
            GitError     = $true
            ErrorDetail  = "git diff failed (exit $LASTEXITCODE) while checking fixtures/helper files between $BaseSha and $RunSha; unable to verify -- flagging for review"
        }
    }
    $changedFiles = @(@($rawOutput) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_.Trim() })

    return [pscustomobject]@{
        Flagged      = ($changedFiles.Count -gt 0)
        ChangedFiles = $changedFiles
        GitError     = $false
        ErrorDetail  = $null
    }
}

function Test-GCUnrecognizedInvariants {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory = $false)][string[]]$Invariants = @()
    )

    # RC item 7: any invariants[] literal beyond the two this validator
    # interprets is surfaced here -- never a silent skip.
    return @(@($Invariants) | Where-Object { $script:GCVKnownInvariants -notcontains $_ })
}

function Invoke-GCDiffIntegrityPhase {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$WorktreePath,
        [Parameter(Mandatory)][string]$RunSha,
        [Parameter(Mandatory = $false)][string]$RepoRoot,
        [Parameter(Mandatory = $false)][string[]]$Invariants = @(),
        [Parameter(Mandatory = $false)][string]$DefaultRef = 'origin/main',
        [Parameter(Mandatory = $false)][string]$GitCliPath = 'git'
    )

    if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
        $RepoRoot = $WorktreePath
    }

    $base = Resolve-GCDiffBase -WorktreePath $WorktreePath -RunSha $RunSha -DefaultRef $DefaultRef -GitCliPath $GitCliPath
    if ($base.Refused) {
        return [pscustomobject]@{
            Refused       = $true
            RefusalReason = $base.RefusalReason
            DefaultSha    = $base.DefaultSha
            MergeBaseSha  = $base.MergeBaseSha
            Flags         = @()
        }
    }

    $flags = [System.Collections.Generic.List[object]]::new()

    # RC item 5 grounds the helper-lib half of the allowlist BEFORE the
    # deletion detector runs, so a deleted helper lib is caught by the same
    # allowlist the deletion detector uses (RC item 6). R8: sourced from the
    # MERGE-BASE commit ($base.MergeBaseSha), never the run's own live
    # worktree state -- otherwise an adversarial run could de-reference a
    # helper's dot-source line, then gut the now-unreferenced helper,
    # evading detection since it would silently drop out of a
    # live-computed allowlist.
    $helperLibPaths = Get-GCHelperLibSet -RepoRoot $RepoRoot -BaseSha $base.MergeBaseSha -GitCliPath $GitCliPath

    $deletion = Test-GCTestFileDeletion -WorktreePath $WorktreePath -BaseSha $base.MergeBaseSha -RunSha $RunSha -AllowlistPathspecs (@('.github/scripts/Tests') + $helperLibPaths) -GitCliPath $GitCliPath
    if ($deletion.GitError) {
        # PF2: a git-command failure is a distinct signal from an actual
        # deletion finding -- route it through the same dedicated
        # 'diff-integrity-git-error' Kind the changed-test-files diff below
        # already uses, never the 'test-file-deletion' Kind a real deletion
        # would use (which would make the error sentinel text look like a
        # literal deleted-file path in Files).
        $flags.Add([pscustomobject]@{ Kind = 'diff-integrity-git-error'; Detail = $deletion.ErrorDetail })
    } elseif ($deletion.Flagged) {
        $flags.Add([pscustomobject]@{ Kind = 'test-file-deletion'; Files = $deletion.DeletedFiles })
    }

    $changedTestFilesRaw = & $GitCliPath -C $WorktreePath diff --name-only $base.MergeBaseSha $RunSha -- '.github/scripts/Tests' 2>$null
    if ($LASTEXITCODE -ne 0) {
        # R4: same fail-CLOSED-toward-more-review discipline as the other
        # s5 detectors -- a git-diff failure here must never silently
        # collapse to an empty changed-file list (which would make
        # assertion-weakening detection quietly skip every file in this
        # range). Surfaced as its own mandatory-review flag since this diff
        # feeds a detector rather than being one itself.
        $flags.Add([pscustomobject]@{ Kind = 'diff-integrity-git-error'; Detail = "git diff --name-only failed (exit $LASTEXITCODE) while computing changed test files between $($base.MergeBaseSha) and $RunSha; assertion-weakening detection could not run for this range -- flagging for review" })
        $changedTestFiles = @()
    } else {
        $changedTestFiles = @(@($changedTestFilesRaw) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and $_.Trim() -match '\.Tests\.ps1$' } | ForEach-Object { $_.Trim() })
    }
    $weakening = Test-GCAssertionWeakening -WorktreePath $WorktreePath -BaseSha $base.MergeBaseSha -RunSha $RunSha -ChangedTestFilePaths $changedTestFiles -GitCliPath $GitCliPath
    if ($weakening.Flagged) {
        $flags.Add([pscustomobject]@{ Kind = 'assertion-weakening'; Files = $weakening.Files; HeuristicNote = $weakening.HeuristicNote })
    }

    $fixtureOrHelper = Test-GCFixtureOrHelperModification -WorktreePath $WorktreePath -BaseSha $base.MergeBaseSha -RunSha $RunSha -HelperLibPaths $helperLibPaths -GitCliPath $GitCliPath
    if ($fixtureOrHelper.GitError) {
        # PF2: same dedicated-Kind routing as the deletion detector above --
        # never 'fixture-or-helper-modification' for a git-command failure.
        $flags.Add([pscustomobject]@{ Kind = 'diff-integrity-git-error'; Detail = $fixtureOrHelper.ErrorDetail })
    } elseif ($fixtureOrHelper.Flagged) {
        $flags.Add([pscustomobject]@{ Kind = 'fixture-or-helper-modification'; Files = $fixtureOrHelper.ChangedFiles })
    }

    foreach ($literal in (Test-GCUnrecognizedInvariants -Invariants $Invariants)) {
        $flags.Add([pscustomobject]@{ Kind = 'unrecognized-invariant'; Literal = $literal })
    }

    return [pscustomobject]@{
        Refused       = $false
        RefusalReason = $null
        DefaultSha    = $base.DefaultSha
        MergeBaseSha  = $base.MergeBaseSha
        Flags         = @($flags)
    }
}

# -----------------------------------------------------------------------------
# s6: verdict emission, backtick-safe inert-render, and the thin wrapper's
# core entry point (frame-slice s6, AC1/AC2, terminal). This section wires
# s2 (worktree), s3 (target checks), s4 (suite green floor), and s5
# (diff-integrity) into Invoke-GoalContractValidate's body above via the new
# -DiffIntegrityPhase seam on Invoke-GCWorktreeSession, and assembles the
# final JSON-serializable verdict object every field of which -- once it
# originates from untrusted comment-sourced contract data (M7) -- is passed
# through Format-GCInertRender before being echoed. This is the ONE HIGH
# stress-test fix (U7): the existing script:-scoped Format-InertMarkerLabel
# (phase-containment-emission-check.ps1:148-152) single-backtick-wraps and
# breaks out on any backtick already present in the content; this function
# is net-new and backtick-SAFE.
# -----------------------------------------------------------------------------

# Private: single source of truth for the strip-to-fixed-point + fence
# logic Format-GCInertRender exposes to external callers. Split out so a
# caller that needs to know WHETHER the strip pass actually changed
# anything (F3/CE-Gate finding, below) can get that signal without
# duplicating the strip/fence logic itself. Format-GCInertRender remains
# the public entry point and is now a thin wrapper around this.
function script:Get-GCInertRenderResult {
    param(
        [Parameter(Mandatory = $false)][AllowNull()][AllowEmptyString()][string]$Content
    )

    if ($null -eq $Content) {
        return [pscustomobject]@{ Rendered = $null; Altered = $false }
    }

    # Strip HTML-comment delimiters (mirrors the stripping half of
    # phase-containment-emission-check.ps1:148-152's Format-InertMarkerLabel)
    # so this content can never be re-parsed as a live marker by a later
    # comment-scanning sweep.
    #
    # R2 (HIGH, live-reproduced): a SINGLE non-looping pass is
    # reconstructable -- an input like "<!<!---- plan-issue-9 ---->>"
    # survives one pass and reassembles into a live "<!-- plan-issue-9 -->"
    # marker, because removing the inner substring concatenates the outer
    # fragments into the exact token being stripped. Looping both replaces
    # to a fixed point (repeat until a pass makes no further change) closes
    # this: any nested/overlapping delimiter shape eventually stabilizes to
    # content with no "<!--"/"-->" substring left to reassemble.
    #
    # F3 (LOW, CE-Gate finding): this fixed-point strip is correct and must
    # NOT be weakened -- it is the R2/U7 security fix. But it has a
    # documented side effect: legitimate prose that merely happens to
    # contain a plain ASCII arrow shaped like "-->" (e.g. "3 --> 0") is
    # silently rewritten with no indicator to the reader that anything
    # changed. $Altered below (a content-free boolean -- never an echo of
    # what was stripped or the original text, which would rebuild the exact
    # reconstruction/injection channel this fixed-point loop exists to
    # close) lets a caller surface that collateral effect as an advisory
    # signal instead of leaving it silent.
    $stripped = $Content
    do {
        $previous = $stripped
        $stripped = $stripped -replace '<!--', '' -replace '-->', ''
    } while ($stripped -ne $previous)
    $altered = ($stripped -ne $Content)

    # Standard Markdown "longer fence" escaping technique: find the longest
    # run of consecutive backticks anywhere in the content, then wrap in a
    # FENCED CODE BLOCK using one MORE backtick than that longest run
    # (minimum 3). Per CommonMark's fenced-code-block rule, a fence can only
    # be closed by a line whose own backtick run is >= the OPENING fence's
    # length -- since every run inside $stripped is, by construction,
    # strictly shorter than $fenceLength, no line inside the content can
    # ever close the block early and let the remainder escape as live,
    # unfenced markdown (U7, HIGH). A block fence (not a single-line inline
    # code span) is deliberate: check-output excerpts and falsifier text can
    # be multi-line, and CommonMark's block-fence rule needs no additional
    # leading/trailing-backtick padding the way an inline code span would.
    $longestRun = 0
    foreach ($m in [regex]::Matches($stripped, '`+')) {
        if ($m.Value.Length -gt $longestRun) {
            $longestRun = $m.Value.Length
        }
    }
    $fenceLength = [Math]::Max(3, $longestRun + 1)
    $fence = '`' * $fenceLength

    return [pscustomobject]@{
        Rendered = "$fence`n$stripped`n$fence"
        Altered  = $altered
    }
}

function Format-GCInertRender {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $false)][AllowNull()][AllowEmptyString()][string]$Content
    )

    return (script:Get-GCInertRenderResult -Content $Content).Rendered
}

# Private: bounds a report excerpt's character length (independent of
# Invoke-GCTargetCheck's own 64KB in-memory capture cap, RC item 7/U20 --
# that cap protects memory during capture; this one keeps the human-readable
# report from embedding an unwieldy multi-kilobyte blob for a single field).
function script:Get-GCExcerpt {
    param(
        [Parameter(Mandatory = $false)][AllowNull()][AllowEmptyString()][string]$Content,
        [Parameter(Mandatory = $false)][int]$MaxChars = 2000
    )

    if ([string]::IsNullOrEmpty($Content)) {
        return ''
    }
    if ($Content.Length -le $MaxChars) {
        return $Content
    }
    return $Content.Substring(0, $MaxChars) + '...[excerpt truncated]...'
}

function New-GCVerdictReport {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][pscustomobject]$Disposition,
        [Parameter(Mandatory = $false)][object[]]$ContractTargets = @(),
        [Parameter(Mandatory = $false)][object[]]$Flags = @()
    )

    # #874 PREDICATE INTERFACE / EXIT-3 LOOP CONTRACT (documented here, not
    # only in the field-lock test, since this is the one function that
    # constructs the object #874 will consume):
    #
    #   ExitCode 0 (Verdict='pass')                  -- completion accepted,
    #     no review needed.
    #   ExitCode 1 (Verdict='fail')                  -- completion rejected;
    #     the run did not satisfy its contract (suite red or a target
    #     failed). A harness loop iterates/retries.
    #   ExitCode 2 (Verdict='refused')                -- the validator could
    #     not render a judgment at all (bad contract, dirty tree,
    #     unauditable diff). A harness loop treats this as a hard stop
    #     distinct from both pass and fail.
    #   ExitCode 3 (Verdict='pass-review-required')   -- completion accepted
    #     ENVIRONMENTALLY, but human review is MANDATORY before merge. A
    #     harness loop must stop-for-review on this code -- never
    #     auto-continue as if it were a plain pass -- and a PR carrying this
    #     disposition must not merge unflagged. Reason and Flags together
    #     are the review payload a human (or a future harness step) reads to
    #     decide the review, distinguishing an infra/harness-error
    #     disposition (s1) from this slice's diff-integrity/worktree-flag
    #     disposition (s6) via the Reason string, per Resolve-GCVerdictDisposition's
    #     own -ReviewReason parameter doc.
    #
    # A committed standalone verdict.schema.json is deliberately NOT
    # required (stress-test U15): this function IS the field-lock; #872's
    # schema guards untrusted CONTRACT input, this object is PRODUCED
    # output, so a producer test is the proportionate contract per the
    # plan's own Decisions section.

    $targetsById = @{}
    foreach ($ct in @($ContractTargets)) {
        $id = [string]$ct.id
        if (-not [string]::IsNullOrWhiteSpace($id)) {
            $targetsById[$id] = $ct
        }
    }

    $reportTargets = [System.Collections.Generic.List[object]]::new()
    foreach ($t in @($Disposition.Targets)) {
        $contractTarget = $null
        $tId = [string]$t.Id
        if ($targetsById.ContainsKey($tId)) {
            $contractTarget = $targetsById[$tId]
        }

        # F3 (LOW, CE-Gate finding): track whether ANY Format-GCInertRender
        # call for this target row actually altered its input (the strip
        # pass removed a "<!--"/"-->" substring) -- via
        # script:Get-GCInertRenderResult directly rather than the
        # Format-GCInertRender string-only wrapper, so the boolean signal is
        # available without re-deriving the strip logic. Folded into this
        # target's own AdvisoryFlags (reusing the existing array, no new
        # verdict field) as 'inert-render-altered' below -- content-free, so
        # it can never become an echo/reconstruction channel for what was
        # stripped.
        $anyAltered = $false

        $idResult = script:Get-GCInertRenderResult -Content $tId
        $anyAltered = $anyAltered -or $idResult.Altered

        $expected = $null
        $falsifier = $null
        $acRef = $null
        if ($contractTarget) {
            $expectedResult = script:Get-GCInertRenderResult -Content ([string]$contractTarget.expected)
            $expected = $expectedResult.Rendered
            $anyAltered = $anyAltered -or $expectedResult.Altered

            $acRefResult = script:Get-GCInertRenderResult -Content ([string]$contractTarget.ac_ref)
            $acRef = $acRefResult.Rendered
            $anyAltered = $anyAltered -or $acRefResult.Altered

            # F1 (HIGH, CE-Gate finding): use the shared, dictionary-aware
            # presence check (script:Test-GCPropertyPresent) instead of a
            # bare .PSObject.Properties.Match() call -- $contractTarget is a
            # [System.Collections.Hashtable] on the real
            # ConvertFrom-GCContractBlock -> ConvertFrom-Yaml parse path,
            # and .PSObject.Properties.Match() alone never sees a
            # Hashtable's actual keys (see script:Test-GCPropertyPresent's
            # doc comment).
            $hasFalsifier = $false
            if (script:Test-GCPropertyPresent -Target $contractTarget -Name 'falsifier') {
                $hasFalsifier = -not [string]::IsNullOrWhiteSpace([string]$contractTarget.falsifier)
            }
            if ($hasFalsifier) {
                $falsifierResult = script:Get-GCInertRenderResult -Content ([string]$contractTarget.falsifier)
                $falsifier = $falsifierResult.Rendered
                $anyAltered = $anyAltered -or $falsifierResult.Altered
            }
        }

        $stdOutExcerptResult = script:Get-GCInertRenderResult -Content (script:Get-GCExcerpt -Content $t.StdOut)
        $anyAltered = $anyAltered -or $stdOutExcerptResult.Altered
        $stdErrExcerptResult = script:Get-GCInertRenderResult -Content (script:Get-GCExcerpt -Content $t.StdErr)
        $anyAltered = $anyAltered -or $stdErrExcerptResult.Altered

        $targetAdvisoryFlags = [System.Collections.Generic.List[string]]::new()
        foreach ($existingFlag in @($t.AdvisoryFlags)) {
            $targetAdvisoryFlags.Add($existingFlag)
        }
        if ($anyAltered) {
            $targetAdvisoryFlags.Add('inert-render-altered')
        }

        $reportTargets.Add([pscustomobject]@{
                Id               = $idResult.Rendered
                AcRef            = $acRef
                Outcome          = $t.Outcome
                ExitCode         = $t.ExitCode
                TimedOut         = $t.TimedOut
                Reason           = $t.Reason
                Expected         = $expected
                Falsifier        = $falsifier
                AdvisoryFlags    = @($targetAdvisoryFlags)
                StdOutExcerpt    = $stdOutExcerptResult.Rendered
                StdErrExcerpt    = $stdErrExcerptResult.Rendered
                # R20: check output that happens to CONTAIN the genuine
                # truncation-marker text (e.g. a check that itself prints
                # "...[output truncated: cap reached]...") is indistinguishable
                # in the rendered excerpt from a real truncation. The
                # authoritative boolean is always correct even when the
                # inline marker text is ambiguous, so it is surfaced
                # explicitly here rather than leaving a reader to infer
                # truncation from the excerpt text alone.
                StdOutTruncated  = [bool]$t.StdOutTruncated
                StdErrTruncated  = [bool]$t.StdErrTruncated
            }) | Out-Null
    }

    $reportFlags = [System.Collections.Generic.List[object]]::new()
    foreach ($f in @($Flags)) {
        $detail = $null
        if ([string]$f.Kind -eq 'unrecognized-invariant') {
            $detail = Format-GCInertRender -Content ([string]$f.Literal)
        } elseif ($f.PSObject.Properties.Match('Files').Count -gt 0) {
            # R6: each Files entry is inert-rendered before joining --
            # filenames are git-diff-derived content from the audited run's
            # own tree (attacker-influenceable), and were previously joined
            # raw with no Format-GCInertRender pass, unlike every sibling
            # field in this function.
            #
            # R14: an assertion-weakening flag's Files entries are
            # [pscustomobject]@{Path;BaseCount;RunCount} objects, not plain
            # strings (unlike the other two file-bearing flag types) -- a
            # bare -join ', ' renders these as an EMPTY STRING (a
            # pscustomobject's .ToString() returns '', not a field dump),
            # silently losing all path/count information. Format each
            # non-string entry into a readable string first.
            $fileStrings = @(@($f.Files) | ForEach-Object {
                    if ($_ -is [string]) {
                        $_
                    } elseif ($null -ne $_ -and $_.PSObject.Properties.Match('Path').Count -gt 0) {
                        "$($_.Path) (was $($_.BaseCount), now $($_.RunCount))"
                    } else {
                        [string]$_
                    }
                })
            $detail = ((@($fileStrings) | ForEach-Object { Format-GCInertRender -Content $_ }) -join ', ')
        } elseif ($f.PSObject.Properties.Match('Detail').Count -gt 0) {
            $detail = Format-GCInertRender -Content ([string]$f.Detail)
        }
        $reportFlags.Add([pscustomobject]@{
                Kind   = [string]$f.Kind
                Detail = $detail
            }) | Out-Null
    }

    # Every refusal reason is inert-rendered: several (contract-schema-
    # violation, no-run-diff's cause-disambiguation prose) quote validator-
    # or contract-derived text verbatim; over-applying to the rest is always
    # safe (a plain reason just gets fenced).
    $reportRefusals = @(@($Disposition.Refusals) | ForEach-Object { Format-GCInertRender -Content ([string]$_) })

    return [pscustomobject]@{
        Verdict  = $Disposition.Verdict
        ExitCode = $Disposition.ExitCode
        Reason   = $Disposition.Reason
        Refusals = $reportRefusals
        Targets  = @($reportTargets)
        Flags    = @($reportFlags)
    }
}
