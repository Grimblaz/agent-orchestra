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
                                   [-GhCliPath <string>]
        Public entry point (Invoke-* per architecture-rules.md:15). At s1
        this function implements ONLY the contract-intake gate sequence:

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

        When every intake gate passes, s1 has nothing further to check --
        the worktree, target-check, suite, and diff-integrity invariants
        that would turn this into a real fail/pass verdict do not exist
        until s2-s6. Invoke-GoalContractValidate therefore returns a
        provisional 'pass' (ExitCode 0, Targets empty) reflecting only the
        gates this slice implements; s2-s6 extend this same function's body
        to fold worktree/target/suite/diff-integrity signals into the same
        Resolve-GCVerdictDisposition call before the verdict becomes the
        real terminal disposition #874 will consume.

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
        64KB each) so an unbounded-output check cannot exhaust memory (U20);
        once the cap is reached, further output is dropped and a
        `'...[output truncated: cap reached]...'` marker is appended, and
        `StdOutTruncated`/`StdErrTruncated` record which stream(s) hit it.

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

function Get-GCPinnedCommentBody {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][int]$Issue,
        [Parameter(Mandatory)][string]$Marker,
        [Parameter(Mandatory = $false)][string]$Repo,
        [Parameter(Mandatory = $false)][string]$GhCliPath = 'gh'
    )

    if ([string]::IsNullOrWhiteSpace($Repo)) {
        try {
            $remoteUrl = & git config --get remote.origin.url 2>$null
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

function Invoke-GoalContractValidate {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][int]$Issue,
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory = $false)][string]$Marker,
        [Parameter(Mandatory = $false)][string]$Repo,
        [Parameter(Mandatory = $false)][string]$GhCliPath = 'gh'
    )

    if ([string]::IsNullOrWhiteSpace($Marker)) {
        $Marker = "<!-- plan-issue-$Issue -->"
    }

    # 1. Plan-issue-pinned, paginated, byte-safe read.
    $body = Get-GCPinnedCommentBody -Issue $Issue -Marker $Marker -Repo $Repo -GhCliPath $GhCliPath
    if ($null -eq $body) {
        return Resolve-GCVerdictDisposition -IsRefused -RefusalReasons @('refused: contract-comment-unresolvable')
    }

    # 2. Block extraction (#872 parser). $null folds three honest,
    #    lib-undifferentiated causes into one fail-closed refusal.
    $payload = Get-GCContractBlock -CommentBody $body
    if ($null -eq $payload) {
        return Resolve-GCVerdictDisposition -IsRefused -RefusalReasons @('refused: contract-block-unresolvable (absent, ambiguous, or truncated — see contract comment)')
    }

    # 3. Schema parse/validate (#872 parser). The ONE loud throw (missing
    #    powershell-yaml module) maps to the infra-error disposition, never
    #    exit-1 fail.
    $parseResult = $null
    try {
        $parseResult = ConvertFrom-GCContractBlock -Payload $payload -RepoRoot $RepoRoot
    } catch {
        return Resolve-GCVerdictDisposition -HasReviewRequired -ReviewReason "infra-error: $($_.Exception.Message)"
    }

    if ($parseResult.Violations -and @($parseResult.Violations).Count -gt 0) {
        $reasons = @(@($parseResult.Violations) | ForEach-Object { "refused: contract-schema-violation: $_" })
        return Resolve-GCVerdictDisposition -IsRefused -RefusalReasons $reasons
    }

    $contractHashField = $parseResult.Contract.contract_hash

    # 4. Placeholder refusal MUST precede the real hash comparison (ordering
    #    is load-bearing): a draft contract's digest is never checked.
    if ($contractHashField -eq $script:GCVPlaceholderHash) {
        return Resolve-GCVerdictDisposition -IsRefused -RefusalReasons @('refused: contract-not-approved')
    }

    # 5. Approved-contract integrity check (#872 parser).
    if (-not (Test-GCContractHash -Payload $payload -Expected $contractHashField)) {
        return Resolve-GCVerdictDisposition -IsRefused -RefusalReasons @('refused: contract-hash-mismatch')
    }

    # Intake gates all passed. s1 stops here: the worktree, target-check,
    # suite, and diff-integrity invariants that would turn this into a real
    # fail/pass verdict do not exist until s2-s6, so this is a provisional
    # pass reflecting only the gates this slice implements.
    return Resolve-GCVerdictDisposition
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

    & $GitCliPath -C $RepoRoot worktree remove --force $WorktreePath 2>$null
    $removeSucceeded = ($LASTEXITCODE -eq 0)
    # Prune runs regardless of the remove outcome (best-effort admin-file
    # reconciliation); its own exit code is not load-bearing for Removed.
    & $GitCliPath -C $RepoRoot worktree prune 2>$null
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
    $headSha = [string](@($headShaRaw) | Select-Object -First 1)
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($headSha)) {
        return [pscustomobject]@{
            Success       = $false
            RefusalReason = 'refused: head-sha-unresolvable'
            Path          = $null
            HeadSha       = $null
        }
    }
    $headSha = $headSha.Trim()

    # GUID-suffixed unique path outside the repo tree -- collision is
    # structurally impossible, mirroring pester-sharded-core.ps1:163-164.
    $worktreePath = Join-Path ([IO.Path]::GetTempPath()) "goal-validate-$([Guid]::NewGuid().ToString('N'))"

    # Full command form, <path> BEFORE the commit-ish (U25) -- the
    # compressed "--detach <sha>" shorthand omits the path and lets git pick
    # its own directory name instead of our unique, outside-the-repo path.
    # Detached is mandatory: a branch checkout hard-fails if that branch is
    # already checked out elsewhere (U4/F9).
    & $GitCliPath -C $RepoRoot worktree add --detach $worktreePath $headSha 2>$null
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
        [Parameter(Mandatory = $false)][string]$GitCliPath = 'git',
        [Parameter(Mandatory = $false)][int]$RetryDelayMs = 1000
    )

    $worktree = New-GCDisposableWorktree -RepoRoot $RepoRoot -GitCliPath $GitCliPath
    if (-not $worktree.Success) {
        return [pscustomobject]@{
            Refused           = $true
            RefusalReason     = $worktree.RefusalReason
            WorktreePath      = $null
            HeadSha           = $null
            SuiteResult       = $null
            ChecksResult      = $null
            SuiteCleanliness  = $null
            ChecksCleanliness = $null
            OrphanedPath      = $null
        }
    }

    $suiteResult = $null
    $checksResult = $null
    $suiteCleanliness = $null
    $checksCleanliness = $null
    $orphanedPath = $null

    try {
        # Fixed order (s2 RC): suite first, against the pristine checkout,
        # THEN target checks. s2 wires only the order and the
        # cleanliness-assertion contract; the suite-runner and check-runner
        # bodies don't exist until s4/s3 supply -SuitePhase/-ChecksPhase.
        if ($SuitePhase) {
            $suiteResult = & $SuitePhase $worktree.Path
        }
        $suiteCleanliness = Test-GCTreeClean -Path $worktree.Path -GitCliPath $GitCliPath

        if ($ChecksPhase) {
            $checksResult = & $ChecksPhase $worktree.Path
        }
        $checksCleanliness = Test-GCTreeClean -Path $worktree.Path -GitCliPath $GitCliPath
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
        Refused           = $false
        RefusalReason     = $null
        WorktreePath      = $worktree.Path
        HeadSha           = $worktree.HeadSha
        SuiteResult       = $suiteResult
        ChecksResult      = $checksResult
        SuiteCleanliness  = $suiteCleanliness
        ChecksCleanliness = $checksCleanliness
        OrphanedPath      = $orphanedPath
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
        $magnitude = [int]$Matches[1]
        switch ($Matches[2]) {
            { $_ -in @('h', 'H') } { return $magnitude * 3600 }
            { $_ -in @('m', 'M') } { return $magnitude * 60 }
            default { return $magnitude }
        }
    }

    return $null
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
    if ($Target.PSObject.Properties.Match('falsifier').Count -gt 0) {
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

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $PwshCliPath
    foreach ($arg in @('-NoProfile', '-NoLogo', '-NonInteractive', '-Command', $check)) {
        $psi.ArgumentList.Add($arg)
    }
    $psi.WorkingDirectory = $WorktreePath
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true

    # Stream-bounded capture (RC item 7 / U20): a synchronized hashtable so
    # the async OutputDataReceived/ErrorDataReceived event actions (which run
    # disconnected from this function's lexical scope) can safely mutate
    # shared state. Capped in-memory, not just the eventual report excerpt.
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

    $sourceIdOut = "GCVOut_$([guid]::NewGuid().ToString('N'))"
    $sourceIdErr = "GCVErr_$([guid]::NewGuid().ToString('N'))"
    $proc = [System.Diagnostics.Process]::new()
    $proc.StartInfo = $psi

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $timedOut = $false
    $exitCode = $null

    try {
        Register-ObjectEvent -InputObject $proc -EventName OutputDataReceived -SourceIdentifier $sourceIdOut -MessageData $outState -Action $stdOutAction | Out-Null
        Register-ObjectEvent -InputObject $proc -EventName ErrorDataReceived -SourceIdentifier $sourceIdErr -MessageData $outState -Action $stdErrAction | Out-Null

        $proc.Start() | Out-Null
        $proc.BeginOutputReadLine()
        $proc.BeginErrorReadLine()

        $exited = $proc.WaitForExit([Math]::Max(0, $TimeoutSeconds) * 1000)

        if (-not $exited) {
            $timedOut = $true
            # PREEMPTIVE TREE-KILL (RC item 2): System.Diagnostics.Process +
            # Kill($true) (pwsh 7 / .NET Core 3+ tree-kill overload) -- NOT
            # Stop-Job/Wait-Job, which does not kill descendant OS processes
            # (U2: orphaned grandchildren hold worktree handles and break
            # teardown). taskkill /T /F is a Windows fallback if Kill($true)
            # itself throws.
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
            # this function reads the captured buffers (the documented .NET
            # pattern for redirected + event-based process output: call the
            # parameterless WaitForExit() after the timed overload returns
            # $true).
            $proc.WaitForExit()
        }

        # RC item 3: marshal the exit code explicitly from the Process
        # object's own ExitCode property -- never from a job's State, which
        # can report Completed even when the underlying check failed.
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

    # RC item 4: timeout ALWAYS maps to fail -- never refused, never
    # review-required.
    $outcome = 'pass'
    $reason = $null
    if ($timedOut) {
        $outcome = 'fail'
        $reason = "timeout: check exceeded ${TimeoutSeconds}s and was tree-killed"
    } elseif ($exitCode -ne 0) {
        $outcome = 'fail'
    }

    return [pscustomobject]@{
        Id              = $targetId
        Outcome         = $outcome
        ExitCode        = $exitCode
        TimedOut        = $timedOut
        Reason          = $reason
        AdvisoryFlags   = @($advisoryFlags)
        StdOut          = $outState.StdOut.ToString()
        StdErr          = $outState.StdErr.ToString()
        StdOutTruncated = $outState.StdOutTruncated
        StdErrTruncated = $outState.StdErrTruncated
        ElapsedMs       = $stopwatch.ElapsedMilliseconds
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

    $exitCode = [int]$Result.ExitCode
    $totalFailed = [int]$Result.TotalFailed
    $totalPassed = 0
    if ($Result.PSObject.Properties.Match('TotalPassed').Count -gt 0) {
        $totalPassed = [int]$Result.TotalPassed
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

    $psi = [Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $PwshCliPath
    foreach ($arg in @('-NoProfile', '-NoLogo', '-NonInteractive', '-File', $launchFile)) {
        $psi.ArgumentList.Add($arg)
    }
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true

    $proc = [Diagnostics.Process]::new()
    $proc.StartInfo = $psi
    $timedOut = $false

    try {
        $proc.Start() | Out-Null
        $exited = $proc.WaitForExit([Math]::Max(0, $TimeoutSeconds) * 1000)

        if (-not $exited) {
            $timedOut = $true
            # RC item 3: PREEMPTIVE TREE-KILL around the ENTIRE suite run --
            # the same discipline the s3 function Invoke-GCTargetCheck uses
            # (U2/U3): System.Diagnostics.Process + Kill($true), never
            # Stop-Job/Wait-Job, with a taskkill /T /F fallback.
            try {
                $proc.Kill($true)
            } catch {
                if ($IsWindows) {
                    try { & taskkill /PID $proc.Id /T /F 2>$null | Out-Null } catch { }
                }
            }
            $null = $proc.WaitForExit(10000)
        } else {
            $proc.WaitForExit()
        }
    } finally {
        $proc.Dispose()
    }

    if ($timedOut) {
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
