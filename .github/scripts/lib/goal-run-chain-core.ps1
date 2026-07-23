#Requires -Version 7.0
<#
.SYNOPSIS
    Post-loop chain testable lib for the goal-run harness (issue #874, plan
    step 6, AC1 chain half + AC2 classing/halt-producer half).
.DESCRIPTION
    Deterministic, unit-testable logic ONLY. The orchestration PROSE that
    tells a live Goal-Run session what to do and in what order (dispatch
    Experience-Owner for CE Gate, dispatch the adversarial-review skill,
    dispatch Code-Smith/Test-Writer for a fix, loop back, create the PR)
    lives in the agents/Goal-Run.agent.md "Post-Loop Chain" section, not
    here -- mirroring the split step 4 established between
    goal-run-stage-core.ps1 (mechanics) and Goal-Run.agent.md (prose).

    This file does NOT modify, and is not itself, any earlier #874 plan
    step file (goal-run-halt-core.ps1, goal-run-transcript-core.ps1,
    goal-run-status-core.ps1, goal-run-worktree-core.ps1, goal-run-stage-
    core.ps1, goal-run-prompt-core.ps1). Every one of those is reused via
    dot-source and their exported functions only -- never copy-pasted or
    re-derived. In particular, the two loop->chain seam stubs step 4 left
    in goal-run-stage-core.ps1 (Invoke-GoalRunLaunchChain,
    Test-GoalRunTerminalEmissionsVerified) are left exactly as documented
    stubs by this step; the REAL chain-launch/terminal-verification logic
    this step adds lives here under different names
    (Invoke-GoalRunChainRevalidate.../Invoke-GoalRunTerminalEmissionsVerify
    AndRepair) and is wired in by the Goal-Run.agent.md prose update this
    step also makes, not by editing the step 4 file.

    Sections, in file order:

      1. Re-validation stage -- reuses the step 5 exit-code/Reason
         disposition function directly; does not reimplement the
         exit-3-infra-error-vs-flag-bearing split or the exit-2-refused
         correction.
         Invoke-GoalRunChainRevalidate

      2. Fix-cycle cap (pure) -- the ONLY thing that decides whether the
         chain 2-cycle fix-then-re-validate budget has been exhausted; the
         actual cycle-counting loop is orchestration prose (Goal-Run.agent.md).
         Test-GoalRunFixCycleCapExceeded

      3. Halt-reason precedence (M2) -- pure, total order over the five
         halt producers named by the approved plan. This is the single
         place that decides which halt_reason wins when multiple
         conditions are true at once.
         Resolve-GoalRunHaltPrecedence

      4. Untrusted-content discipline pass-through -- composes the step 1
         secret-redaction pass (goal-run-transcript-core.ps1) with the
         halt-report emit primitive own marker-inert-rendering
         (goal-run-halt-core.ps1) so chain code never constructs a raw,
         un-redacted string for a durable artifact.
         ConvertTo-GoalRunChainSafeText, New-GoalRunChainHaltReport

      5. Classing (874-D7) -- a thin wrapper around the existing
         Invoke-PipelineMetricsV4Emit primitive (emit-pipeline-metrics-v4-
         core.ps1:81). Adds a goal_run_class scalar field (additive-safe:
         Read-PRMetricsBlock/Get-FCLScalar extract named fields only and
         ignore unknown ones, frame-credit-ledger-core.ps1:123-134,159-198)
         plus one credit row per contract required_markers entry, and
         applies the goal-run PR label.
         Build-GoalRunRequiredMarkerCreditRow, Get-GoalRunRequiredMarkerCreditRows,
         Invoke-GoalRunClassEmission, Add-GoalRunPrLabel

      6. Verified-emission terminal condition + repair -- PR existence
         alone is never the terminal signal; this reads back the label AND
         the metrics block via gh and, on a re-invocation that finds a PR
         missing either, repairs it instead of silently treating "PR
         exists" as done.
         Test-GoalRunPrEmissionsVerified, Invoke-GoalRunTerminalEmissionsVerifyAndRepair

    Explicitly out of scope for this step (commented seams only, no
    function bodies here):

      - budget-exhausted producer wiring: the wall-clock backstop is #874
        plan step 7. Resolve-GoalRunHaltPrecedence accepts a
        -BudgetExhausted switch today so its precedence slot exists, but
        nothing in this file currently sets that switch true -- step 7
        owns the trigger.
      - gate-input-needed producer wiring: chain gate demands are #848 E1.
        Resolve-GoalRunHaltPrecedence accepts a -GateInputNeeded switch for
        the same reason; #848 E1 owns what sets it.
      - scope_boundaries scope-conformance review lens: deferred to PR 2
        (874 plan step 6 non-goal). The adversarial-review dispatch this
        step Goal-Run.agent.md prose describes runs one lens short and
        says so honestly.
#>

. (Join-Path $PSScriptRoot 'goal-run-prompt-core.ps1')
. (Join-Path $PSScriptRoot 'goal-run-halt-core.ps1')
. (Join-Path $PSScriptRoot 'emit-pipeline-metrics-v4-core.ps1')

# ---------------------------------------------------------------------------
# 1. Re-validation stage (reuses the step 5 disposition function directly)
# ---------------------------------------------------------------------------

function Invoke-GoalRunChainRevalidate {
    <#
    .SYNOPSIS
        Chain-stage re-validation: invoke the validator against committed
        worktree state and apply the EXACT SAME exit-3-split-by-Reason and
        exit-2-refused-to-halt logic the step 5 loop predicate already uses.
    .DESCRIPTION
        This function does not re-derive any exit-code/Reason interpretation
        of its own. It calls the same subprocess-invocation helper the step 5
        Resolve-GoalRunLoopPredicate uses by default
        (Invoke-GoalRunValidatorProcess, goal-run-prompt-core.ps1) and then
        hands the raw ExitCode/Reason straight to
        Resolve-GoalRunValidatorExitDisposition -- the single source of
        truth for what each exit code/Reason combination means. When that
        function reports Disposition 'halt' (exit 2 refused, or an
        infra-error-prefixed exit 3), this wraps it with HaltReason
        'chain-stage-failure' -- the same bucket Resolve-GoalRunLoopPredicate
        assigns those same two halt cases to.

        M1 fix: before any of that, this function also runs the SAME
        launch-pinned contract-hash check the step 5 loop predicate runs
        first (Test-GoalRunContractHashPinned, goal-run-prompt-core.ps1),
        via -LaunchPinnedHash. Chain re-validation must not run the
        validator against a contract that changed after this run own launch
        was pinned any more than the in-loop predicate should. A mismatch
        here short-circuits BEFORE the validator is invoked and produces
        Disposition 'halt' / HaltReason 'invariant-conflict' -- a distinct
        condition from a genuine re-validation failure, and the
        highest-precedence halt producer per Resolve-GoalRunHaltPrecedence.
    .OUTPUTS
        [pscustomobject]@{ Disposition; HaltReason; Reason; ExitCode }
        Disposition is 'satisfied' | 'not-satisfied' | 'halt'. HaltReason is
        $null unless Disposition is 'halt'.
    #>
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

    # Launch-pinned hash check runs FIRST, mirroring
    # Resolve-GoalRunLoopPredicate (goal-run-prompt-core.ps1). A mismatch
    # short-circuits before the validator is ever invoked, so the checks of
    # a contract that changed after launch are never executed here either.
    $pin = & $PinCheck $Issue $LaunchPinnedHash $Marker $RepoRoot $Repo $GhCliPath $GitCliPath
    if (-not $pin.Pinned) {
        return [pscustomobject]@{
            Disposition = 'halt'
            HaltReason  = 'invariant-conflict'
            Reason      = $pin.Reason
            ExitCode    = $null
        }
    }

    if (-not $ValidatorInvoker) {
        $ValidatorInvoker = {
            param($Issue, $RepoRoot, $PwshCliPath, $ValidatorScriptPath)
            script:Invoke-GoalRunValidatorProcess -Issue $Issue -RepoRoot $RepoRoot -PwshCliPath $PwshCliPath -ValidatorScriptPath $ValidatorScriptPath
        }
    }

    $result = & $ValidatorInvoker $Issue $RepoRoot $PwshCliPath $ValidatorScriptPath

    # Reuse the step 5 disposition function directly -- do not reimplement the
    # exit-3-Reason-prefix split (infra-error vs flag-bearing pass-review-
    # required) or the exit-2-refused correction. Both live in
    # Resolve-GoalRunValidatorExitDisposition (goal-run-prompt-core.ps1) only.
    # M23 fix: pass through ParseFailed exactly as Resolve-GoalRunLoopPredicate
    # does, so a lost Reason on an exit-3 chain re-validation fails closed too.
    $disposition = Resolve-GoalRunValidatorExitDisposition -ExitCode $result.ExitCode -Reason $result.Reason -ParseFailed:([bool]$result.ParseFailed)

    $haltReason = $null
    if ($disposition.Disposition -eq 'halt') {
        # Same bucket Resolve-GoalRunLoopPredicate assigns exit-2/exit-3-
        # infra-error halts to, per the approved plan step 6 enumeration.
        $haltReason = 'chain-stage-failure'
    }

    return [pscustomobject]@{
        Disposition = $disposition.Disposition
        HaltReason  = $haltReason
        Reason      = $disposition.Reason
        ExitCode    = $result.ExitCode
    }
}

# ---------------------------------------------------------------------------
# 2. Fix-cycle cap (pure)
# ---------------------------------------------------------------------------

function Test-GoalRunFixCycleCapExceeded {
    <#
    .SYNOPSIS
        Pure predicate: has the chain fix-then-re-validate cycle budget
        (2 cycles max) been exhausted? The cap itself becomes a
        chain-stage-failure halt producer once this returns $true -- the
        orchestration prose (Goal-Run.agent.md) is responsible for calling
        this after each fix cycle and, on $true, feeding -ChainStageFailure
        into Resolve-GoalRunHaltPrecedence.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][int]$CompletedFixCycles,
        [int]$Cap = 2
    )

    return ($CompletedFixCycles -ge $Cap)
}

# ---------------------------------------------------------------------------
# 3. Halt-reason precedence (M2) -- pure, total order
# ---------------------------------------------------------------------------

function Resolve-GoalRunHaltPrecedence {
    <#
    .SYNOPSIS
        The single, total precedence rule across the five #874 halt
        producers when more than one is true at once (highest wins):
        invariant-conflict > unachievable-target > gate-input-needed >
        budget-exhausted > chain-stage-failure.
    .DESCRIPTION
        Pure input-to-output: a set of "which conditions are currently
        true" switches in, one winning halt_reason out. This function does
        not itself decide WHETHER any given condition is true -- each
        producer own detection lives elsewhere (launch-pinned-hash
        mismatch and the executor halt-claim reader for invariant-conflict;
        Invoke-GoalRunChainRevalidate/the fix-cycle cap/a stage crash for
        chain-stage-failure; the wall-clock backstop, #874 step 7, for
        budget-exhausted; the #848 E1 chain gate for gate-input-needed) --
        callers pass in the already-decided booleans.
    .OUTPUTS
        [pscustomobject]@{ HaltReason; TrueConditions; HasHalt }
        HaltReason is $null (HasHalt $false) when no switch is set.
        TrueConditions lists every condition that was true, in precedence
        order, for exhaustive test assertions over co-occurrence.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [switch]$InvariantConflict,
        [switch]$UnachievableTarget,
        [switch]$GateInputNeeded,
        [switch]$BudgetExhausted,
        [switch]$ChainStageFailure
    )

    # This ordered list IS the entire precedence rule -- no other tiebreak
    # logic exists anywhere else in this file. Reordering this list changes
    # the winner; do not reorder without updating the approved plan M2
    # enumeration and this step Pester coverage together.
    $order = @(
        [pscustomobject]@{ Name = 'invariant-conflict'; True = [bool]$InvariantConflict }
        [pscustomobject]@{ Name = 'unachievable-target'; True = [bool]$UnachievableTarget }
        [pscustomobject]@{ Name = 'gate-input-needed'; True = [bool]$GateInputNeeded }
        [pscustomobject]@{ Name = 'budget-exhausted'; True = [bool]$BudgetExhausted }
        [pscustomobject]@{ Name = 'chain-stage-failure'; True = [bool]$ChainStageFailure }
    )

    $trueConditions = @($order | Where-Object { $_.True } | ForEach-Object { $_.Name })

    $winner = $null
    foreach ($candidate in $order) {
        if ($candidate.True) {
            $winner = $candidate.Name
            break
        }
    }

    return [pscustomobject]@{
        HaltReason     = $winner
        TrueConditions = $trueConditions
        HasHalt        = [bool]$winner
    }
}

# ---------------------------------------------------------------------------
# 4. Untrusted-content discipline pass-through
# ---------------------------------------------------------------------------

function ConvertTo-GoalRunChainSafeText {
    <#
    .SYNOPSIS
        Secret-redaction leg of the two-part transcript-content barrier
        (goal-run-transcript-core.ps1), reused verbatim -- never bypassed by
        constructing a raw string directly. Marker-delimiter inert rendering
        is the OTHER leg and is handled separately by the artifact-specific
        emitter (Invoke-GoalRunHaltEmit already inert-renders evidence/
        plan_remediation before posting a halt report); callers that build
        PR body fragments outside the halt-report path must inert-render
        those fragments themselves via ConvertTo-GoalRunInertEvidenceText.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text
    )

    return Get-GoalRunRedactedText -Text $Text
}

function New-GoalRunChainHaltReport {
    <#
    .SYNOPSIS
        Builds a schema-shaped halt-report object (skills/goal-run/schemas/
        goal-halt-report.schema.json) from a winning halt_reason (as
        Resolve-GoalRunHaltPrecedence returns it) plus free-text fields,
        running every free-text field through the secret-redaction pass
        before the object is ever handed to Invoke-GoalRunHaltEmit (which
        performs its own marker-inert-rendering and schema validation, and
        refuses to post an invalid object).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][int]$Issue,
        [Parameter(Mandatory)][ValidateSet('unachievable-target', 'invariant-conflict', 'budget-exhausted', 'gate-input-needed', 'chain-stage-failure')][string]$HaltReason,
        [Parameter(Mandatory)][ValidateSet('pre-loop', 'loop', 'validate', 'ce-gate', 'review', 'fix-cycle', 'pr')][string]$Stage,
        [ValidateSet('in-session', 'manual', 'headless')][string]$Arm = 'in-session',
        [ValidateSet('executor-reported', 'validator', 'harness')][string]$ClaimProvenance = 'harness',
        [AllowNull()][string]$TargetRef = $null,
        [Parameter(Mandatory)][string]$PlanRemediation,
        [string[]]$Evidence = @(),
        [string]$RecommendedNextOwner = 'Code-Conductor',
        [hashtable]$BudgetSnapshot = @{}
    )

    $safeEvidence = @($Evidence | ForEach-Object { ConvertTo-GoalRunChainSafeText -Text ([string]$_) })
    $safeRemediation = ConvertTo-GoalRunChainSafeText -Text $PlanRemediation
    # M3 fix: target_ref and recommended_next_owner are documented as
    # contract/executor-sourced (untrusted) exactly like evidence/
    # plan_remediation above, but were previously assigned raw with no
    # redaction at all. Route them through the SAME secret-redaction leg
    # the other free-text fields already use (the inert-render leg is
    # applied separately, at comment-render time, by
    # New-GoalRunHaltCommentBody -- mirroring the existing two-layer split
    # for evidence/plan_remediation). TargetRef is nullable per the schema
    # (halt reasons like budget-exhausted/chain-stage-failure may have no
    # single target); a $null value is passed through as $null rather than
    # redacted-into-empty-string.
    $safeTargetRef = if ($null -eq $TargetRef) { $null } else { ConvertTo-GoalRunChainSafeText -Text $TargetRef }
    $safeRecommendedNextOwner = ConvertTo-GoalRunChainSafeText -Text ([string]$RecommendedNextOwner)

    return [pscustomobject]@{
        schema_version          = 1
        issue                   = $Issue
        halt_reason             = $HaltReason
        target_ref              = $safeTargetRef
        plan_remediation        = $safeRemediation
        evidence                = $safeEvidence
        recommended_next_owner  = $safeRecommendedNextOwner
        arm                     = $Arm
        stage                   = $Stage
        claim_provenance        = $ClaimProvenance
        budget_snapshot         = $BudgetSnapshot
    }
}

# ---------------------------------------------------------------------------
# 5. Classing (874-D7)
# ---------------------------------------------------------------------------

function Build-GoalRunRequiredMarkerCreditRow {
    <#
    .SYNOPSIS
        A single credits[] row for one entry of the contract
        evidence_obligations.required_markers list. status is 'declared'
        (not a pass/fail claim) -- this row records that the contract named
        this marker as required, not that the marker own content was
        independently verified; that verification, where it exists, is a
        separate concern (e.g. the halt-report schema validation itself).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$MarkerName,
        [string]$Evidence = ''
    )

    $resolvedEvidence = if (-not [string]::IsNullOrWhiteSpace($Evidence)) {
        $Evidence
    }
    else {
        "Declared in the goal-contract evidence_obligations.required_markers list."
    }

    return [pscustomobject]@{
        port     = $MarkerName
        adapter  = 'goal-run-chain'
        status   = 'declared'
        evidence = $resolvedEvidence
    }
}

function Get-GoalRunRequiredMarkerCreditRows {
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter(Mandatory)]$Contract
    )

    $markers = @($Contract.evidence_obligations.required_markers)
    return @($markers | ForEach-Object { Build-GoalRunRequiredMarkerCreditRow -MarkerName ([string]$_) })
}

function Invoke-GoalRunClassEmission {
    <#
    .SYNOPSIS
        Thin wrapper around Invoke-PipelineMetricsV4Emit (emit-pipeline-
        metrics-v4-core.ps1:81) for goal-run PR classing (874-D7). Does not
        duplicate any of that function YAML-composition, credits-
        validation, or cost-capture-failed-sentinel logic -- it only
        prepares the goal_run_class scalar field and the required-marker
        credit rows, then calls straight through.
    .DESCRIPTION
        goal_run_class is folded into -V3BaseYaml as a plain top-level
        scalar line so it lands inside the <!-- pipeline-metrics --> block
        New-PipelineMetricsV4Block composes (the v3-base content is emitted
        verbatim ahead of the v4 additions). Read-PRMetricsBlock/
        Get-FCLScalar extract only the field names they know about and
        silently ignore anything else -- additive-safe, confirmed by the
        approved plan (frame-credit-ledger-core.ps1:123-134,159-198), so no
        existing reader is affected by this new field.

        The required-marker rows are ALWAYS included (never conditionally
        dropped), together with a base 'goal-run' port row, so this wrapper
        never hands Invoke-PipelineMetricsV4Emit an empty credits[] on its
        own -- an empty credits[] fails Test-PipelineMetricsV4Block
        validation and routes the emit into its own cost-capture-failed
        fallback path (a real failure mode of the primitive this wrapper
        must not accidentally trigger).
    .OUTPUTS
        Whatever Invoke-PipelineMetricsV4Emit returns:
        [pscustomobject]@{ ExitCode; SentinelWritten }
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][int]$Issue,
        [Parameter(Mandatory)][string]$BodyFile,
        [Parameter(Mandatory)]$Contract,
        [string]$GoalRunClass = 'goal-run',
        [pscustomobject[]]$Credits = @(),
        [string]$V3BaseYaml = '',
        [string]$RichBody = '',
        [string]$Repo = '',
        [string]$GhCliPath = 'gh',
        [switch]$SkipMarkerHarvest
    )

    $baseLines = [System.Collections.Generic.List[string]]::new()
    if (-not [string]::IsNullOrWhiteSpace($V3BaseYaml)) {
        $baseLines.Add($V3BaseYaml.TrimEnd()) | Out-Null
    }
    $baseLines.Add("goal_run_class: $GoalRunClass") | Out-Null
    $baseLines.Add("goal_run_issue: $Issue") | Out-Null
    $augmentedBaseYaml = ($baseLines.ToArray() -join "`n")

    $requiredMarkerRows = @(Get-GoalRunRequiredMarkerCreditRows -Contract $Contract)
    $classRow = [pscustomobject]@{
        port     = 'goal-run'
        adapter  = 'goal-run-chain'
        status   = 'classed'
        evidence = "goal_run_class=$GoalRunClass"
    }
    $combinedCredits = @($Credits) + @($classRow) + $requiredMarkerRows

    return Invoke-PipelineMetricsV4Emit -BodyFile $BodyFile -V3BaseYaml $augmentedBaseYaml -Credits $combinedCredits -IssueNumber $Issue -RichBody $RichBody -Repo $Repo -GhCliPath $GhCliPath -SkipMarkerHarvest:$SkipMarkerHarvest
}

function Add-GoalRunPrLabel {
    <#
    .SYNOPSIS
        Applies the 'goal-run' PR label. -LabelApplier is injectable
        (defaults to a `gh pr edit --add-label` call) so callers/tests never
        need `gh` on PATH, mirroring the -CommentBodyReader convention the
        goal-run-prompt-core.ps1 Test-GoalRunContractHashPinned function uses.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][int]$PrNumber,
        [string]$LabelName = 'goal-run',
        [string]$Owner,
        [string]$Repo,
        [string]$GhCliPath = 'gh',
        [scriptblock]$LabelApplier
    )

    if (-not $LabelApplier) {
        $LabelApplier = {
            param($PrNumber, $LabelName, $Owner, $Repo, $GhCliPath)
            $labelArgs = @('pr', 'edit', [string]$PrNumber, '--add-label', $LabelName)
            if ($Owner -and $Repo) { $labelArgs += @('--repo', "$Owner/$Repo") }
            & $GhCliPath @labelArgs 2>$null
            return ($LASTEXITCODE -eq 0)
        }
    }

    $success = [bool](& $LabelApplier $PrNumber $LabelName $Owner $Repo $GhCliPath)
    return [pscustomobject]@{ Success = $success; LabelName = $LabelName; PrNumber = $PrNumber }
}

# ---------------------------------------------------------------------------
# 6. Verified-emission terminal condition + repair
# ---------------------------------------------------------------------------

function Test-GoalRunPrEmissionsVerified {
    <#
    .SYNOPSIS
        The REAL terminal-condition check step 6 owns (the goal-run-stage-
        core.ps1 Test-GoalRunTerminalEmissionsVerified function stays a
        documented stub -- this is the function the chain prose calls
        instead): reads the live PR labels AND body back via gh and
        confirms BOTH the 'goal-run' label AND a v4 pipeline-metrics block
        carrying this wrapper own 'goal-run' classing credit row are
        actually present.
        PR existence alone (a bare `gh pr create` success) is never treated
        as the terminal signal.
    .OUTPUTS
        [pscustomobject]@{ Verified; Reason; LabelPresent; MetricsPresent; Body }
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][int]$PrNumber,
        [string]$LabelName = 'goal-run',
        [string]$Owner,
        [string]$Repo,
        [string]$GhCliPath = 'gh',
        [scriptblock]$PrReader
    )

    if (-not $PrReader) {
        $PrReader = {
            param($PrNumber, $Owner, $Repo, $GhCliPath)
            $prArgs = @('pr', 'view', [string]$PrNumber, '--json', 'body,labels')
            if ($Owner -and $Repo) { $prArgs += @('--repo', "$Owner/$Repo") }
            $raw = & $GhCliPath @prArgs 2>$null
            if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($raw)) { return $null }
            try { return ($raw | Out-String | ConvertFrom-Json -ErrorAction Stop) } catch { return $null }
        }
    }

    $pr = & $PrReader $PrNumber $Owner $Repo $GhCliPath
    if ($null -eq $pr) {
        return [pscustomobject]@{ Verified = $false; Reason = 'pr-unreadable'; LabelPresent = $false; MetricsPresent = $false; Body = $null }
    }

    $labelNames = @($pr.labels | ForEach-Object { $_.name })
    $labelPresent = $labelNames -contains $LabelName

    $body = [string]$pr.body
    $metrics = Read-PRMetricsBlock -PrBody $body
    $metricsPresent = $false
    if ($null -ne $metrics -and $metrics.MetricsVersion -eq 4) {
        $metricsPresent = [bool](@($metrics.Credits) | Where-Object { $_.Port -eq 'goal-run' })
    }

    $verified = $labelPresent -and $metricsPresent
    $reason = if ($verified) {
        $null
    }
    elseif (-not $labelPresent -and -not $metricsPresent) {
        'label-and-metrics-missing'
    }
    elseif (-not $labelPresent) {
        'label-missing'
    }
    else {
        'metrics-missing'
    }

    return [pscustomobject]@{
        Verified       = $verified
        Reason         = $reason
        LabelPresent   = $labelPresent
        MetricsPresent = $metricsPresent
        Body           = $body
    }
}

function Invoke-GoalRunTerminalEmissionsVerifyAndRepair {
    <#
    .SYNOPSIS
        Checks Test-GoalRunPrEmissionsVerified and, on a re-invocation that
        finds a PR existing but missing the label and/or the classing
        metrics (e.g. the harness crashed between `gh pr create` and the
        classing step), repairs the missing piece(s) rather than silently
        treating "PR exists" as done. This is the actual completion signal
        the chain prose PR-creation stage uses.
    .OUTPUTS
        [pscustomobject]@{ Verified; Repaired; Reason; LabelRepaired; MetricsRepaired }
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][int]$PrNumber,
        [Parameter(Mandatory)]$Contract,
        [string]$GoalRunClass = 'goal-run',
        [pscustomobject[]]$Credits = @(),
        [string]$LabelName = 'goal-run',
        [string]$Owner,
        [string]$Repo,
        [string]$GhCliPath = 'gh',
        [scriptblock]$PrReader,
        [scriptblock]$LabelApplier,
        [scriptblock]$BodyWriter
    )

    $state = Test-GoalRunPrEmissionsVerified -PrNumber $PrNumber -LabelName $LabelName -Owner $Owner -Repo $Repo -GhCliPath $GhCliPath -PrReader $PrReader
    if ($state.Verified) {
        return [pscustomobject]@{ Verified = $true; Repaired = $false; Reason = $null; LabelRepaired = $false; MetricsRepaired = $false }
    }

    $labelOk = $state.LabelPresent
    if (-not $labelOk) {
        $labelResult = Add-GoalRunPrLabel -PrNumber $PrNumber -LabelName $LabelName -Owner $Owner -Repo $Repo -GhCliPath $GhCliPath -LabelApplier $LabelApplier
        $labelOk = $labelResult.Success
    }

    $metricsOk = $state.MetricsPresent
    if (-not $metricsOk) {
        if (-not $BodyWriter) {
            $BodyWriter = {
                param($PrNumber, $Owner, $Repo, $GhCliPath, $BodyFile)
                $editArgs = @('pr', 'edit', [string]$PrNumber, '--body-file', $BodyFile)
                if ($Owner -and $Repo) { $editArgs += @('--repo', "$Owner/$Repo") }
                & $GhCliPath @editArgs 2>$null
                return ($LASTEXITCODE -eq 0)
            }
        }

        $tempBodyFile = [System.IO.Path]::GetTempFileName()
        try {
            $emitResult = Invoke-GoalRunClassEmission -Issue $Contract.issue -BodyFile $tempBodyFile -Contract $Contract -GoalRunClass $GoalRunClass -Credits $Credits -RichBody ([string]$state.Body) -Repo $Repo -GhCliPath $GhCliPath -SkipMarkerHarvest
            if ($emitResult.ExitCode -eq 0) {
                $metricsOk = [bool](& $BodyWriter $PrNumber $Owner $Repo $GhCliPath $tempBodyFile)
            }
        }
        finally {
            Remove-Item -LiteralPath $tempBodyFile -ErrorAction SilentlyContinue
        }
    }

    $finalVerified = $labelOk -and $metricsOk
    return [pscustomobject]@{
        Verified        = $finalVerified
        Repaired        = $true
        Reason          = if ($finalVerified) { $null } else { 'repair-incomplete' }
        LabelRepaired   = (-not $state.LabelPresent) -and $labelOk
        MetricsRepaired = (-not $state.MetricsPresent) -and $metricsOk
    }
}
