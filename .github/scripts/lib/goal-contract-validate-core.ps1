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

.NOTES
    Trust framing (M7, inherited from goal-contract-core.ps1's own .NOTES):
    every field this validator reads ultimately comes from an untrusted,
    externally-writable GitHub comment. This slice never executes
    `targets[].check` or feeds prose fields into a prompt -- it only reads
    structural fields (contract_hash, schema_version via the #872 schema
    gate) needed for intake decisions. s3's target-check execution is the
    first slice that treats contract content as a knowing execution surface
    (873-D7), not this one.
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
