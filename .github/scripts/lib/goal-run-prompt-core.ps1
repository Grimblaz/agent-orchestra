#Requires -Version 7.0
<#
.SYNOPSIS
    Goal-prompt assembly and launch-pinned loop predicate for the goal-run
    harness (issue #874, plan step 5, AC1 minus scope_boundaries).
.DESCRIPTION
    Two concerns, both scoped to this step:

      New-GoalRunPromptText -Contract <object> -Issue <int> -WorktreePath <string>
                             [-PredicateScriptRelativePath <string>]
        Renders the executor prompt text from a parsed #872 contract object
        (the -Contract output ConvertFrom-GCContractBlock returns) plus the issue
        number and worktree path passed in as parameters (874-D2 Arm I):
        the function reads no executor conversation context, only the
        parsed contract object and the two durable identifiers supplied by
        the caller. scope_boundaries is deliberately not rendered -- the
        #872 schema is closed (additionalProperties: false) and carries no
        such field; that rendering is deferred to a later PR. The contract
        marker reference is rendered as plain prose (never the live
        `<!-- plan-issue-{ID} -->` HTML-comment delimiters), so the
        assembled prompt text can never accidentally satisfy a
        marker-substring-containment read the way an embedded live marker
        literal would.

        M1 fix: the rendered predicate command now points at the thin CLI
        wrapper goal-run-predicate.ps1 (goal-run-predicate-core.ps1,
        Invoke-GoalRunPredicateEvaluate) instead of the raw validator
        script. The wrapper runs the launch-pinned contract-hash check
        (Test-GoalRunContractHashPinned, below) BEFORE the validator on
        every vendor-loop iteration and self-emits a halt report on a halt
        disposition, since the vendor loop itself has no halt-reporting
        mechanism -- rendering the raw validator directly, as this
        function did before this fix, never ran that check at all.

      Resolve-GoalRunValidatorExitDisposition -ExitCode <int> [-Reason <string>]
        Pure exit-code/Reason disambiguation (M1, the sharpest plan
        stress-test finding). goal-contract-validate.ps1 defines four exit
        codes: 0=pass, 1=fail, 2=refused, 3=pass-review-required. Exit 0 ->
        satisfied. Exit 1 (fail) means the validator DID assess the
        current state and the targets are not yet met -- this is a
        legitimate not-satisfied, keep-looping signal, so it maps to
        `not-satisfied`. Exit 2 (refused) is categorically different: it
        means the validator could not even attempt an assessment -- a
        pre-run precondition failure such as an unresolvable or
        unapproved contract, a contract-hash mismatch, uncommitted
        changes, a no-run-diff condition, or a blank-check floor. A
        structural precondition like that cannot resolve itself by
        looping again, so exit 2 maps to `halt` (sharing the
        `chain-stage-failure` halt_reason with the exit-3 infra-error case
        below, per the approved plan step 6 enumeration), not to
        `not-satisfied`. Exit 3 is ambiguous by exit code alone: a
        `Reason` string beginning with the literal prefix `infra-error:`
        (the infra-error tag goal-contract-validate-core.ps1 itself emits,
        e.g. a missing powershell-yaml module or an uncaught worktree-session
        exception) means the validator never actually ran the contract
        checks, so it does NOT count as satisfied -- it maps to `halt`.
        Any other exit-3 Reason (e.g. a flag-bearing pass-review-required
        verdict, such as a worktree-dirt/diff-integrity/target-budget
        flag) counts as `satisfied`, because the mandatory downstream
        review in a later step supersedes the flag. An unrecognized exit
        code fails closed to `halt` rather than guessing a pass/fail
        direction. The exit-2 halt Reason text is prefixed distinctly
        (`refused (exit 2): ...`) from the exit-3 infra-error halt Reason
        text (`infra-error: ...`) so a human reading the halt report can
        tell the two halt causes apart even though they carry the same
        halt_reason.

        M23 fix: an exit-3 subprocess result with `Reason: $null` is
        AMBIGUOUS between two genuinely different cases -- (a) the
        subprocess returned well-formed JSON that simply omits `Reason` (a
        legitimate flag-bearing verdict shape, correctly `satisfied`) and
        (b) the subprocess stdout could not be parsed as JSON at all, so
        `Reason` is null because there was no verdict object, not because
        the verdict object omitted the field. Before this fix both
        collapsed to the same `Reason: $null` shape and case (b) silently
        resolved to `satisfied` -- a signal-loss failure that fails OPEN
        (merge-permitting) instead of closed. `Invoke-GoalRunValidatorProcess`
        now also returns `ParseFailed` (`$true` only for case (b): the
        subprocess produced no output at all, or its output could not be
        parsed as JSON) and `Resolve-GoalRunValidatorExitDisposition` takes
        an optional `-ParseFailed` switch: an exit-3 result with `Reason:
        $null` (no infra-error prefix possible on a null Reason) now
        resolves to `halt` when `-ParseFailed` is set, and stays `satisfied`
        exactly as before when it is not -- the legitimate flag-bearing-
        with-no-Reason path is unregressed.

      Test-GoalRunContractHashPinned -Issue <int> -LaunchPinnedHash <string>
                                      [-Marker <string>] [-RepoRoot <string>]
                                      [-Repo <string>] [-GhCliPath <string>]
                                      [-GitCliPath <string>]
                                      [-CommentBodyReader <scriptblock>]
        Security-critical launch-pin check (M4, the second-sharpest plan
        stress-test finding). Re-fetches the LIVE contract comment
        (Get-GCPinnedCommentBody), extracts its payload (Get-GCContractBlock),
        and compares that payload against -LaunchPinnedHash via
        Test-GCContractHash -Expected <the launch-pinned value> -- an
        explicit compare-to-launch-pinned-value step, not the self-
        consistency check a bare Test-GCContractHash call against the
        contract_hash field the live contract carries itself would give
        (self-consistency alone does not protect against a post-approval
        edit that keeps that same field internally consistent).
        -CommentBodyReader
        is injectable (defaults to a thin Get-GCPinnedCommentBody wrapper)
        so callers/tests never need `gh` on PATH.

      Resolve-GoalRunLoopPredicate -Issue <int> -RepoRoot <string>
                                    -LaunchPinnedHash <string>
                                    [-Marker <string>] [-Repo <string>]
                                    [-GhCliPath <string>] [-GitCliPath <string>]
                                    [-PwshCliPath <string>]
                                    [-ValidatorScriptPath <string>]
                                    [-PinCheck <scriptblock>]
                                    [-ValidatorInvoker <scriptblock>]
        The composed loop predicate the stage machine (plan step 4) will
        call on each iteration. Calls Test-GoalRunContractHashPinned FIRST,
        before doing anything else -- on a hash mismatch this returns
        `halt` (HaltReason: invariant-conflict) and the validator is never
        invoked (the -ValidatorInvoker scriptblock is not called on this
        path, so a contract that changed after launch never has its
        changed checks executed). Only when the hash is pinned does this
        function invoke `goal-contract-validate.ps1 -Issue {N} -RepoRoot
        {worktree}` (via -ValidatorInvoker, default a real `pwsh -File`
        child-process invocation, injectable for tests) and apply
        Resolve-GoalRunValidatorExitDisposition to the result. Returns
        [pscustomobject]@{ Disposition; HaltReason; Reason; ExitCode;
        ValidatorRan } -- Disposition is one of 'satisfied' |
        'not-satisfied' | 'halt', directly consumable by the halt path of
        the stage machine (full wiring is a later step; this function
        only needs to return a shape that wiring can act on).
#>

. (Join-Path $PSScriptRoot 'goal-contract-validate-core.ps1')

# ---------------------------------------------------------------------------
# 1. Prompt assembly (pure rendering)
# ---------------------------------------------------------------------------

function New-GoalRunPromptText {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]$Contract,
        [Parameter(Mandatory)][int]$Issue,
        [Parameter(Mandatory)][string]$WorktreePath,
        [string]$PredicateScriptRelativePath = '.github/scripts/goal-run-predicate.ps1'
    )

    $invariantLines = @(@($Contract.invariants) | ForEach-Object { "- $_" })
    if ($invariantLines.Count -eq 0) { $invariantLines = @('- (none declared)') }

    $requiredMarkers = @($Contract.evidence_obligations.required_markers)
    $requiredMarkersLine = if ($requiredMarkers.Count -gt 0) { ($requiredMarkers -join ', ') } else { '(none declared)' }

    $experienceObligationLines = @(@($Contract.evidence_obligations.experience_obligations) | ForEach-Object {
            "- scenario: $($_.scenario) (surface: $($_.surface))"
        })
    if ($experienceObligationLines.Count -eq 0) { $experienceObligationLines = @('- (none declared)') }

    $haltConditionLines = @(@($Contract.halt_conditions) | ForEach-Object { "- $_" })
    if ($haltConditionLines.Count -eq 0) { $haltConditionLines = @('- (none declared)') }

    $budget = $Contract.budget
    $budgetLine = "tokens=$($budget.tokens), wall_clock=$($budget.wall_clock), chain_sub_ceiling=$($budget.chain_sub_ceiling), non_convergence=$($budget.non_convergence)"

    # M1 fix: the predicate command points at the launch-pin-checking
    # wrapper (goal-run-predicate.ps1), not the raw validator script --
    # see the file header doc comment for why the raw validator alone was
    # never sufficient here.
    $predicateCommand = "pwsh -NoProfile -File $PredicateScriptRelativePath -Issue $Issue -RepoRoot $WorktreePath"
    $fencedPredicateCommand = '`' + $predicateCommand + '`'

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("# Goal-run executor prompt (issue #$Issue)") | Out-Null
    $lines.Add('') | Out-Null
    $lines.Add('## Provenance') | Out-Null
    $lines.Add("- Contract source: the approved goal-contract block on the plan-issue-$Issue comment for issue #$Issue.") | Out-Null
    $lines.Add("- Worktree: $WorktreePath") | Out-Null
    $lines.Add('') | Out-Null
    $lines.Add('## Invariants') | Out-Null
    foreach ($l in $invariantLines) { $lines.Add($l) | Out-Null }
    $lines.Add('') | Out-Null
    $lines.Add('## Evidence obligations') | Out-Null
    $lines.Add("- checkpoint_commits: $($Contract.evidence_obligations.checkpoint_commits)") | Out-Null
    $lines.Add("- run_log: $($Contract.evidence_obligations.run_log)") | Out-Null
    $lines.Add('- experience_obligations:') | Out-Null
    foreach ($l in $experienceObligationLines) { $lines.Add("  $l") | Out-Null }
    $lines.Add("- required_markers: $requiredMarkersLine") | Out-Null
    $lines.Add('') | Out-Null
    $lines.Add('## Halt conditions') | Out-Null
    foreach ($l in $haltConditionLines) { $lines.Add($l) | Out-Null }
    $lines.Add('') | Out-Null
    $lines.Add('## Budget') | Out-Null
    $lines.Add("- $budgetLine") | Out-Null
    $lines.Add('') | Out-Null
    $lines.Add('## Predicate command') | Out-Null
    $lines.Add($fencedPredicateCommand) | Out-Null

    return ($lines.ToArray() -join "`n")
}

# ---------------------------------------------------------------------------
# 2. Predicate exit-code/Reason disambiguation (pure, M1)
# ---------------------------------------------------------------------------

function Resolve-GoalRunValidatorExitDisposition {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][int]$ExitCode,
        [Parameter(Mandatory = $false)][AllowNull()][AllowEmptyString()][string]$Reason,
        # M23 fix: distinguishes a genuinely-omitted Reason on a well-formed
        # verdict (case a, unaffected) from a Reason lost to a subprocess
        # JSON-parse failure (case b, must fail closed). Defaults to $false
        # so every existing call site that does not yet pass it keeps its
        # current behavior.
        [switch]$ParseFailed
    )

    if ($ExitCode -eq 0) {
        return [pscustomobject]@{ Disposition = 'satisfied'; Reason = $Reason }
    }
    if ($ExitCode -eq 1) {
        # Fail: the validator DID assess the current state and the
        # targets are not yet met. A loop retry can genuinely make
        # progress here, so this is a plain not-satisfied.
        return [pscustomobject]@{ Disposition = 'not-satisfied'; Reason = $Reason }
    }
    if ($ExitCode -eq 2) {
        # Refused: the validator could not even attempt an assessment --
        # a pre-run precondition failure (unresolvable/unapproved
        # contract, contract-hash mismatch, uncommitted changes,
        # no-run-diff, blank-check floor, and similar). This is NOT the
        # same as not-satisfied: retrying against a structural
        # precondition that cannot self-resolve risks the loop spinning
        # forever, so this is a distinct halt condition. The Reason text
        # is prefixed with the exit code so it stays distinguishable from
        # the exit-3 infra-error halt text below even though both share
        # the chain-stage-failure halt_reason one level up.
        $haltDetail = if ($Reason) { "refused (exit 2): $Reason" } else { 'refused (exit 2): validator did not attempt assessment (pre-run precondition failure)' }
        return [pscustomobject]@{ Disposition = 'halt'; Reason = $haltDetail }
    }
    if ($ExitCode -eq 3) {
        if ($Reason -and ($Reason -match '^infra-error:')) {
            # Validation never actually ran (bad pwsh/git path, worktree
            # lock, missing yaml module, or any other uncaught infra
            # exception) -- this does not count as satisfied, and it is
            # not a plain not-satisfied retry either: it is a distinct
            # halt condition.
            return [pscustomobject]@{ Disposition = 'halt'; Reason = $Reason }
        }
        if ([string]::IsNullOrEmpty($Reason) -and $ParseFailed) {
            # M23 fix, case (b): the subprocess stdout could not be
            # parsed as JSON at all, so Reason is null because there was no
            # verdict object -- not because a well-formed verdict object
            # genuinely omitted the field (case a, handled by the plain
            # `satisfied` return below). Signal loss here must fail CLOSED,
            # not open: a lost Reason on an ambiguous exit 3 must not be
            # silently treated as a passing/flag-bearing verdict.
            return [pscustomobject]@{ Disposition = 'halt'; Reason = 'parse-failed: exit 3 subprocess output could not be parsed as JSON; Reason was lost, failing closed' }
        }
        # A flag-bearing exit 3 (worktree-dirt / diff-integrity /
        # target-budget flags) means targets were met; the mandatory
        # downstream review in a later step supersedes the flag. This also
        # covers case (a): a well-formed JSON verdict that genuinely omits
        # Reason -- unaffected by the M23 fix above.
        return [pscustomobject]@{ Disposition = 'satisfied'; Reason = $Reason }
    }

    # Unrecognized exit code: fail closed to halt rather than guess a
    # pass/fail direction.
    return [pscustomobject]@{ Disposition = 'halt'; Reason = "unrecognized-exit-code: $ExitCode" }
}

# ---------------------------------------------------------------------------
# 3. Launch-pinned contract-hash check (M4, security-critical)
# ---------------------------------------------------------------------------

function Test-GoalRunContractHashPinned {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][int]$Issue,
        [Parameter(Mandatory)][string]$LaunchPinnedHash,
        [string]$Marker,
        [string]$RepoRoot,
        [string]$Repo,
        [string]$GhCliPath = 'gh',
        [string]$GitCliPath = 'git',
        [scriptblock]$CommentBodyReader
    )

    if ([string]::IsNullOrWhiteSpace($Marker)) {
        $Marker = "<!-- plan-issue-$Issue -->"
    }
    if (-not $CommentBodyReader) {
        $CommentBodyReader = {
            param($Issue, $Marker, $RepoRoot, $Repo, $GhCliPath, $GitCliPath)
            Get-GCPinnedCommentBody -Issue $Issue -Marker $Marker -RepoRoot $RepoRoot -Repo $Repo -GhCliPath $GhCliPath -GitCliPath $GitCliPath
        }
    }

    $body = & $CommentBodyReader $Issue $Marker $RepoRoot $Repo $GhCliPath $GitCliPath
    if ($null -eq $body) {
        return [pscustomobject]@{ Pinned = $false; Reason = 'contract-comment-unresolvable'; LiveHash = $null }
    }

    $payload = Get-GCContractBlock -CommentBody $body
    if ($null -eq $payload) {
        return [pscustomobject]@{ Pinned = $false; Reason = 'contract-block-unresolvable'; LiveHash = $null }
    }

    $liveHash = Get-GCContractHash -Payload $payload

    # Explicit compare against the LAUNCH-PINNED value -- deliberately not
    # Test-GCContractHash against the contract_hash field the live
    # contract carries itself, which would only prove the live payload is
    # self-consistent and would not catch a post-approval edit that kept
    # that same field internally consistent.
    $pinned = Test-GCContractHash -Payload $payload -Expected $LaunchPinnedHash

    if (-not $pinned) {
        return [pscustomobject]@{ Pinned = $false; Reason = 'contract-hash-mismatch-since-launch'; LiveHash = $liveHash }
    }

    return [pscustomobject]@{ Pinned = $true; Reason = $null; LiveHash = $liveHash }
}

# ---------------------------------------------------------------------------
# 4. Composed loop predicate
# ---------------------------------------------------------------------------

function script:Invoke-GoalRunValidatorProcess {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][int]$Issue,
        [Parameter(Mandatory)][string]$RepoRoot,
        [string]$PwshCliPath = 'pwsh',
        [string]$ValidatorScriptPath
    )

    if ([string]::IsNullOrWhiteSpace($ValidatorScriptPath)) {
        $ValidatorScriptPath = Join-Path $RepoRoot '.github/scripts/goal-contract-validate.ps1'
    }

    $raw = & $PwshCliPath -NoProfile -NoLogo -NonInteractive -File $ValidatorScriptPath -Issue $Issue -RepoRoot $RepoRoot 2>$null
    $exitCode = $LASTEXITCODE

    # M23 fix: distinguish "no output at all" / "output could not be parsed
    # as JSON" (ParseFailed = $true -- there was never a verdict object, so
    # a null Reason here means signal LOSS, not a legitimate omitted field)
    # from "well-formed JSON parsed cleanly, Reason just was not present on
    # it" (ParseFailed = $false -- a genuine, trustworthy omitted-Reason
    # verdict shape). Resolve-GoalRunValidatorExitDisposition cannot make
    # this distinction on its own from Reason alone, which is exactly the
    # ambiguity this fix closes.
    $reason = $null
    $parseFailed = $false
    if ($raw) {
        try {
            $parsed = ($raw | Out-String) | ConvertFrom-Json -ErrorAction Stop
            $reason = $parsed.Reason
        }
        catch {
            $reason = $null
            $parseFailed = $true
        }
    }
    else {
        # No subprocess output at all: there is no verdict object of any
        # shape to read Reason from -- same signal-loss class as a parse
        # exception, not a legitimate omitted field.
        $parseFailed = $true
    }

    return [pscustomobject]@{ ExitCode = $exitCode; Reason = $reason; ParseFailed = $parseFailed }
}

function Resolve-GoalRunLoopPredicate {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][int]$Issue,
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$LaunchPinnedHash,
        [string]$Marker,
        [string]$Repo,
        [string]$GhCliPath = 'gh',
        [string]$GitCliPath = 'git',
        [string]$PwshCliPath = 'pwsh',
        [string]$ValidatorScriptPath,
        [scriptblock]$PinCheck,
        [scriptblock]$ValidatorInvoker
    )

    if (-not $PinCheck) {
        $PinCheck = {
            param($Issue, $LaunchPinnedHash, $Marker, $RepoRoot, $Repo, $GhCliPath, $GitCliPath)
            Test-GoalRunContractHashPinned -Issue $Issue -LaunchPinnedHash $LaunchPinnedHash -Marker $Marker -RepoRoot $RepoRoot -Repo $Repo -GhCliPath $GhCliPath -GitCliPath $GitCliPath
        }
    }
    if (-not $ValidatorInvoker) {
        $ValidatorInvoker = {
            param($Issue, $RepoRoot, $PwshCliPath, $ValidatorScriptPath)
            script:Invoke-GoalRunValidatorProcess -Issue $Issue -RepoRoot $RepoRoot -PwshCliPath $PwshCliPath -ValidatorScriptPath $ValidatorScriptPath
        }
    }

    # Launch-pinned hash check runs FIRST, before anything else on this
    # iteration (M4). A mismatch halts without ever invoking the
    # validator -- the checks of the changed contract are never executed.
    $pin = & $PinCheck $Issue $LaunchPinnedHash $Marker $RepoRoot $Repo $GhCliPath $GitCliPath
    if (-not $pin.Pinned) {
        return [pscustomobject]@{
            Disposition  = 'halt'
            HaltReason   = 'invariant-conflict'
            Reason       = $pin.Reason
            ExitCode     = $null
            ValidatorRan = $false
        }
    }

    $result = & $ValidatorInvoker $Issue $RepoRoot $PwshCliPath $ValidatorScriptPath
    # M23 fix: pass through ParseFailed when the invoker result carries it
    # (a default -ValidatorInvoker call, or a test double that opts in). A
    # test double result object with no ParseFailed property reads as $null
    # here, which [switch] coerces to $false -- unchanged pre-fix behavior.
    $exitDisposition = Resolve-GoalRunValidatorExitDisposition -ExitCode $result.ExitCode -Reason $result.Reason -ParseFailed:([bool]$result.ParseFailed)

    $haltReason = $null
    if ($exitDisposition.Disposition -eq 'halt') {
        $haltReason = 'chain-stage-failure'
    }

    return [pscustomobject]@{
        Disposition  = $exitDisposition.Disposition
        HaltReason   = $haltReason
        Reason       = $exitDisposition.Reason
        ExitCode     = $result.ExitCode
        ValidatorRan = $true
    }
}
