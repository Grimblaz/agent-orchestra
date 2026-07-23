#Requires -Version 7.0
<#
.SYNOPSIS
    Advisory wall-clock budget arm, session-identity arming, and end-of-run
    token accounting for the goal-run harness (issue #874, plan step 7,
    AC1 budget half; 874-D5 arm-scoped, Arm-I/interactive default).
.DESCRIPTION
    This file does NOT modify, and is not itself, any earlier #874 plan
    step file (goal-run-transcript-core.ps1, goal-run-status-core.ps1,
    goal-run-worktree-core.ps1, goal-run-stage-core.ps1, goal-run-prompt-
    core.ps1, goal-run-chain-core.ps1). It reuses Resolve-GoalRunHaltPrecedence
    (step 6) and Get-EventUsage (cost-attribution.ps1, step 1 leg f own
    seam) by dot-source and call only -- never copy-pasted or re-derived.
    Fix M4/M5/M9 additionally dot-sources Update-GoalRunActiveStateHeartbeat
    (goal-run-worktree-core.ps1) and Add-GoalRunLogEntry (goal-run-log-
    core.ps1, new in this fix) for the same reuse-only reason -- section 5
    below composes them, it does not reimplement them. Neither of those two
    files dot-sources this file or goal-run-chain-core.ps1, so this stays a
    one-directional dependency graph with no circular dot-source.

    ## In-loop enforcement gap -- a disclosed, deliberate non-feature

    Arm I (interactive `/goal`) has no native budget flag (`--max-budget-usd`
    is headless-only, out of scope for this PR) and no Stop hook in PR 1.
    NO budget enforcement of any kind fires during the goal loop itself in
    PR 1 -- in-loop spend is bounded only by the vendor `/goal` loop own
    limits. The probe (Documents/Design/goal-loop-capability-probe.md) found
    no settable iteration/turn ceiling exposed by the interactive surface,
    so there is nothing this step can set and record as an in-loop bound;
    the bound is purely the vendor default, and that fact is recorded here
    rather than invented as an enforcement mechanism that does not exist.

    Every function in this file enforces ONLY at a chain-stage boundary
    (post-loop, at the transition points step 6 own chain already treats as
    stage checkpoints) -- never inside the loop.

    ## Loop-vs-chain spend split -- explicitly DROPPED for this PR

    A "release-turn index" that would split whole-session spend into a
    loop-phase share and a chain-phase share is explicitly out of scope for
    this PR. Get-GoalRunSessionTokenAccounting below computes only a single
    whole-session sum -- never a loop-vs-chain breakdown. This is a
    deliberate PR-1 scope line, not a missing/broken feature.

    Sections, in file order:

      1. Session-identity registry (874-D5) -- a user-scoped (never
         CWD-scoped) registry of executor session ids. The pre-loop
         bookend registers the session BEFORE the goal loop launches; the
         wall-clock check at a chain-stage boundary consults this registry
         so a diagnostic session poking around in a preserved crashed
         worktree (not the actual registered executor session) can never
         arm the budget check.
         Get-GoalRunBudgetRegistryPath, Register-GoalRunBudgetSession,
         Test-GoalRunBudgetSessionRegistered

      2. Wall-clock arm resolution -- the actual chain-boundary check.
         Fail-loud discipline: when session identity genuinely cannot be
         verified (registry missing or unreadable), this warns loudly and
         arms anyway rather than silently treating an unverifiable run as
         within budget.
         Resolve-GoalRunBudgetArmState

      3. Chain-boundary composite wiring into step 6 precedence -- calls
         Resolve-GoalRunHaltPrecedence (goal-run-chain-core.ps1) correctly
         with the real -BudgetExhausted condition this step produces,
         without modifying that function own total-order logic.
         Invoke-GoalRunBudgetChainBoundaryCheck

      4. End-of-run token accounting (probe Decision 4) -- sums whole-
         session usage post-hoc from a session transcript, provenance-
         labeled, cross-checking a well-formed all-zero `usage` object
         against `modelUsage`/`total_cost_usd` rather than trusting a raw
         zero at face value (the #873 silent-zero defect class the probe
         confirmed appears in live vendor output on at least one build).
         Sums ALL `modelUsage` keys, not just a pinned/requested model.
         Get-GoalRunSessionTokenAccounting

      5. Chain-stage-boundary composite (M4/M5/M9, new in this fix) -- the
         ONE live call site the agents/Goal-Run.agent.md Post-Loop Chain
         prose names at every chain-stage transition point, composing the
         heartbeat update, the run-log checkpoint write, and this file own
         wall-clock/precedence composite into a single call rather than
         three separate near-identical prose passes over the same
         transition points.
         Invoke-GoalRunChainStageBoundaryHousekeeping

    Non-goals: no Stop-hook enforcement; no `--max-budget-usd` delegation;
    no hard per-turn or in-loop enforcement of any kind.
#>

. (Join-Path $PSScriptRoot 'goal-run-chain-core.ps1')
. (Join-Path $PSScriptRoot 'cost-attribution.ps1')
# M4/M5/M9 fix: the chain-stage-boundary composite (section 5 below) also
# needs the heartbeat updater (goal-run-worktree-core.ps1) and the run-log
# writer (goal-run-log-core.ps1). Neither of those two files dot-sources
# this one or goal-run-chain-core.ps1, so adding them here does not create
# the circular dot-source goal-run-chain-core.ps1 itself must avoid (it
# already gets dot-sourced BY this file, above).
. (Join-Path $PSScriptRoot 'goal-run-worktree-core.ps1')
. (Join-Path $PSScriptRoot 'goal-run-log-core.ps1')

# ---------------------------------------------------------------------------
# 1. Session-identity registry (874-D5)
# ---------------------------------------------------------------------------

function Get-GoalRunBudgetRegistryPath {
    <#
    .SYNOPSIS
        Resolves the user-scoped session-registry path for 874-D5 session-
        identity arming: $env:USERPROFILE on Windows / $HOME on POSIX,
        under a dedicated .claude/goal-run state directory -- mirroring the
        same $IsWindows-branched, never-hardcoded-literal convention step 1
        uses for the transcript root (Get-GoalRunTranscriptRoot, goal-run-
        transcript-core.ps1), applied here to a WRITE-side state file this
        harness owns rather than the vendor-owned READ-side transcript
        directory that function resolves.

        No existing user-scoped state precedent for a session-identity
        registry was found elsewhere in this repo (the closest sibling,
        goal-run-active.json, is deliberately worktree-scoped -- see the
        file header note on why arming must NOT be CWD-scoped). This path
        is therefore a new convention chosen for this step and documented
        here rather than assumed silently.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $base = if ($IsWindows) { $env:USERPROFILE } else { $HOME }
    return (Join-Path $base '.claude' 'goal-run' 'session-registry.json')
}

# Private: reads the registry file, tolerant of a missing file (Status
# 'missing', empty Sessions map, never an error) but distinguishing that
# from an unreadable or malformed file (Status 'unreadable') and a clean
# read (Status 'ok'). A plain Test-Path check alone cannot tell "missing"
# from "corrupt", and the fail-loud discipline in Resolve-GoalRunBudgetArmState
# below depends on the distinction.
function script:Get-GoalRunBudgetRegistry {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$RegistryPath
    )

    if (-not (Test-Path -LiteralPath $RegistryPath -PathType Leaf)) {
        return [pscustomobject]@{ Status = 'missing'; Sessions = @{} }
    }

    try {
        $raw = Get-Content -LiteralPath $RegistryPath -Raw -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($raw)) {
            return [pscustomobject]@{ Status = 'missing'; Sessions = @{} }
        }
        $parsed = $raw | ConvertFrom-Json -AsHashtable -ErrorAction Stop
        if ($null -eq $parsed -or -not $parsed.ContainsKey('sessions') -or $parsed['sessions'] -isnot [System.Collections.IDictionary]) {
            return [pscustomobject]@{ Status = 'unreadable'; Sessions = @{} }
        }
        return [pscustomobject]@{ Status = 'ok'; Sessions = $parsed['sessions'] }
    }
    catch {
        return [pscustomobject]@{ Status = 'unreadable'; Sessions = @{} }
    }
}

function Register-GoalRunBudgetSession {
    <#
    .SYNOPSIS
        Pre-loop bookend (874-D5): registers the executor session id in the
        user-scoped registry BEFORE the goal loop launches. The registry
        lives at a fixed user-profile path regardless of which worktree the
        executor happens to be running from, so Arm I arms the same way
        no matter the current working directory -- unlike a hypothetical
        future arm that might be CWD-scoped.
    .OUTPUTS
        [pscustomobject]@{ Success; RegistryPath }
        Best-effort, never throws: a write failure (e.g. an unwritable
        registry directory) reports Success = $false with a warning, since
        registration failing is not itself a chain-boundary condition --
        it surfaces later as a fail-loud "registry-unverifiable" state at
        the actual wall-clock check.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$SessionId,
        [Parameter(Mandatory)][int]$Issue,
        [string]$RegistryPath
    )

    if ([string]::IsNullOrWhiteSpace($RegistryPath)) {
        $RegistryPath = Get-GoalRunBudgetRegistryPath
    }

    $existing = script:Get-GoalRunBudgetRegistry -RegistryPath $RegistryPath
    $sessions = @{}
    foreach ($key in $existing.Sessions.Keys) { $sessions[$key] = $existing.Sessions[$key] }

    $sessions[$SessionId] = @{
        issue         = $Issue
        registered_at = (Get-Date).ToUniversalTime().ToString('o')
    }

    try {
        $dir = Split-Path -Parent $RegistryPath
        if ($dir -and -not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
        $json = [pscustomobject]@{ sessions = $sessions } | ConvertTo-Json -Depth 10
        Set-Content -LiteralPath $RegistryPath -Value $json -Encoding utf8 -NoNewline
        return [pscustomobject]@{ Success = $true; RegistryPath = $RegistryPath }
    }
    catch {
        Write-Warning "Register-GoalRunBudgetSession: could not persist registry at ${RegistryPath} -- $($_.Exception.Message)"
        return [pscustomobject]@{ Success = $false; RegistryPath = $RegistryPath }
    }
}

function Test-GoalRunBudgetSessionRegistered {
    <#
    .SYNOPSIS
        Checks whether SessionId is present in the user-scoped registry.
        Distinguishes a deliberate not-registered bystander (a diagnostic
        session poking around in a preserved crashed worktree, expected to
        read Status 'not-registered' with no warning -- that is correct
        behavior, not a failure) from a genuine read failure (Status
        'registry-missing' or 'registry-unreadable'), which
        Resolve-GoalRunBudgetArmState below treats as fail-loud-and-arm,
        never fail-open-and-skip.
    .OUTPUTS
        [pscustomobject]@{ Status; Entry }
        Status is 'registered' | 'not-registered' | 'registry-missing' |
        'registry-unreadable'. Entry is the registry-recorded {issue,
        registered_at} map when Status is 'registered', else $null.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$SessionId,
        [string]$RegistryPath
    )

    if ([string]::IsNullOrWhiteSpace($RegistryPath)) {
        $RegistryPath = Get-GoalRunBudgetRegistryPath
    }

    $registry = script:Get-GoalRunBudgetRegistry -RegistryPath $RegistryPath

    if ($registry.Status -eq 'missing') {
        return [pscustomobject]@{ Status = 'registry-missing'; Entry = $null }
    }
    if ($registry.Status -eq 'unreadable') {
        return [pscustomobject]@{ Status = 'registry-unreadable'; Entry = $null }
    }

    if ($registry.Sessions.ContainsKey($SessionId)) {
        return [pscustomobject]@{ Status = 'registered'; Entry = $registry.Sessions[$SessionId] }
    }

    return [pscustomobject]@{ Status = 'not-registered'; Entry = $null }
}

# ---------------------------------------------------------------------------
# 2. Wall-clock arm resolution (chain-boundary only)
# ---------------------------------------------------------------------------

function Resolve-GoalRunBudgetArmState {
    <#
    .SYNOPSIS
        The wall-clock check that runs ONLY at a chain-stage boundary
        (never inside the goal loop itself -- see the file header). Arms
        ONLY when CurrentSessionId is the registered executor session; a
        bystander/diagnostic session id never arms, regardless of elapsed
        time or current working directory.
    .DESCRIPTION
        Fail-loud discipline: when the registry itself cannot be read at
        all (a missing file or unreadable content -- as opposed to a
        readable registry that simply does not list this session), this
        function does NOT silently treat the run as unarmed and therefore
        safe. It emits a warning through -WarningEmitter and arms anyway,
        so a registry read failure can never silently suppress
        budget-exhausted forever. A readable registry that genuinely does
        not list CurrentSessionId is the deliberate bystander case and
        stays silently unarmed -- that is correct behavior, not a failure.
    .OUTPUTS
        [pscustomobject]@{ Armed; ArmReason; ElapsedMinutes; CeilingMinutes;
        BudgetExhausted }
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$CurrentSessionId,
        [Parameter(Mandatory)][datetime]$LaunchedAt,
        [Parameter(Mandatory)][double]$CeilingMinutes,
        [datetime]$Now = [datetime]::MinValue,
        [string]$RegistryPath,
        [scriptblock]$WarningEmitter
    )

    if ($Now -eq [datetime]::MinValue) { $Now = (Get-Date).ToUniversalTime() }
    if (-not $WarningEmitter) { $WarningEmitter = { param($Message) Write-Warning $Message } }

    $check = Test-GoalRunBudgetSessionRegistered -SessionId $CurrentSessionId -RegistryPath $RegistryPath

    $armed = $false
    $armReason = $null
    switch ($check.Status) {
        'registered' {
            $armed = $true
            $armReason = 'session-registered'
        }
        'not-registered' {
            $armed = $false
            $armReason = 'session-not-registered'
        }
        default {
            # 'registry-missing' or 'registry-unreadable': identity cannot
            # be verified at all. Fail loud and arm anyway -- never
            # silently proceed as if the run were within budget when it
            # genuinely could not tell.
            & $WarningEmitter "Resolve-GoalRunBudgetArmState: session registry could not be verified ($($check.Status)); arming on wall-clock alone."
            $armed = $true
            $armReason = "registry-unverifiable: $($check.Status)"
        }
    }

    # M6 fix: same Kind-unaware datetime bug as
    # Test-GoalRunInflightAppearsDead (goal-run-stage-core.ps1) -- a
    # Z-suffixed UTC string cast to [datetime] lands Kind=Local (a correct
    # local-wall-clock conversion, but raw Ticks subtraction against a
    # genuinely Utc -Now does not itself account for that offset).
    # .ToUniversalTime() is a correct no-op on an already-Utc value and a
    # correct reverse-conversion on a Local-tagged one, so normalizing both
    # operands through it here fixes the skew regardless of which Kind
    # either side arrived with.
    $elapsedMinutes = ($Now.ToUniversalTime() - $LaunchedAt.ToUniversalTime()).TotalMinutes
    $budgetExhausted = $armed -and ($elapsedMinutes -ge $CeilingMinutes)

    return [pscustomobject]@{
        Armed           = $armed
        ArmReason       = $armReason
        ElapsedMinutes  = $elapsedMinutes
        CeilingMinutes  = $CeilingMinutes
        BudgetExhausted = $budgetExhausted
    }
}

# ---------------------------------------------------------------------------
# 3. Chain-boundary composite -- wires budget-exhausted into step 6
#    Resolve-GoalRunHaltPrecedence WITHOUT modifying that function
# ---------------------------------------------------------------------------

function Invoke-GoalRunBudgetChainBoundaryCheck {
    <#
    .SYNOPSIS
        Chain-boundary composite: resolves the wall-clock arm state above,
        then calls step 6 own Resolve-GoalRunHaltPrecedence (goal-run-
        chain-core.ps1) with -BudgetExhausted wired from the real result --
        never reimplementing or modifying that function own total-order
        precedence logic. The other four precedence conditions are
        passthrough switches so a single call at the chain boundary
        resolves the full picture, budget-exhausted included, with correct
        co-occurrence handling against invariant-conflict, unachievable-
        target, gate-input-needed, and chain-stage-failure.
    .OUTPUTS
        [pscustomobject]@{ ArmState; Precedence }
        ArmState is the Resolve-GoalRunBudgetArmState output. Precedence is
        the Resolve-GoalRunHaltPrecedence output.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$CurrentSessionId,
        [Parameter(Mandatory)][datetime]$LaunchedAt,
        [Parameter(Mandatory)][double]$CeilingMinutes,
        [datetime]$Now = [datetime]::MinValue,
        [string]$RegistryPath,
        [scriptblock]$WarningEmitter,
        [switch]$InvariantConflict,
        [switch]$UnachievableTarget,
        [switch]$GateInputNeeded,
        [switch]$ChainStageFailure
    )

    $armState = Resolve-GoalRunBudgetArmState -CurrentSessionId $CurrentSessionId -LaunchedAt $LaunchedAt `
        -CeilingMinutes $CeilingMinutes -Now $Now -RegistryPath $RegistryPath -WarningEmitter $WarningEmitter

    $precedence = Resolve-GoalRunHaltPrecedence -InvariantConflict:$InvariantConflict -UnachievableTarget:$UnachievableTarget `
        -GateInputNeeded:$GateInputNeeded -BudgetExhausted:$armState.BudgetExhausted -ChainStageFailure:$ChainStageFailure

    return [pscustomobject]@{
        ArmState   = $armState
        Precedence = $precedence
    }
}

# ---------------------------------------------------------------------------
# 4. End-of-run token accounting (probe Decision 4 / 874-D5 token half)
# ---------------------------------------------------------------------------

function Get-GoalRunSessionTokenAccounting {
    <#
    .SYNOPSIS
        End-of-run token accounting: sums whole-session usage post-hoc from
        a session transcript file, provenance-labeled so a consumer can see
        where the number came from and whether it was cross-checked.
    .DESCRIPTION
        Two source shapes are read across the whole transcript, using the
        same tolerant JSONL parsing convention step 1 established
        (Get-GoalRunStatusEvent, goal-run-status-core.ps1: malformed or
        partial lines are silently skipped, never thrown):

          - 'assistant' events -- per-turn usage, extracted via step 1 leg
            f own event-usage seam (Get-EventUsage, cost-attribution.ps1)
            reused directly, never reimplemented. Summed across every
            'assistant' event in the transcript -- never split by
            loop-phase vs chain-phase; the loop-vs-chain spend split a
            "release-turn index" would need is explicitly DROPPED for this
            PR (see the file header), so only a whole-session sum is
            computed here.
          - a terminal 'result' event, when present -- carries usage /
            modelUsage / total_cost_usd. An Arm I interactive transcript
            may never carry one, since the interactive session does not
            terminate the way a --print headless invocation does; when
            present, its modelUsage is the trusted quantity source
            (summed across EVERY model-id key present, not just a
            pinned/requested one -- the probe observed an unrequested
            secondary model appearing in modelUsage) and total_cost_usd is
            an independent spend cross-check, because a well-formed
            all-zero usage object is not provably truthful on every
            platform build (the #873 silent-zero defect class, observed
            live on a real budget-breach run).

        Selection rule, in order:
          1. A terminal result event exists and its own usage object is NOT
             all-zero -- trust it directly. Provenance
             'result-event-usage'.
          2. A terminal result event exists, its usage object IS all-zero,
             but modelUsage or total_cost_usd on that SAME event is
             non-zero -- the all-zero usage is not trusted; the modelUsage
             sum becomes the reported total. Provenance
             'result-event-modelusage-crosscheck'.
          3. A terminal result event exists and usage/modelUsage/
             total_cost_usd all agree on zero or absent -- a genuine zero.
             Provenance 'result-event-usage'.
          4. No terminal result event exists at all (the expected shape for
             most Arm I interactive transcripts) -- fall back to the
             whole-session 'assistant' event usage sum. Provenance
             'assistant-turn-sum'; there is no modelUsage/total_cost_usd on
             this path to cross-check against, so UsageCrossChecked is
             honestly reported $false rather than silently implied $true.
    .OUTPUTS
        [pscustomobject]@{ State; Reason; Provenance; Tokens; TotalCostUsd;
        ModelUsageKeys; UsageWasAllZero; UsageCrossChecked; CrossCheckReason }
        State is 'accounting-unavailable' | 'accounting-present'. Tokens is
        @{ input; output; cache_creation; cache_read } (all ints, 0 when
        unavailable).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$TranscriptPath
    )

    $emptyTokens = @{ input = 0; output = 0; cache_creation = 0; cache_read = 0 }

    if (-not (Test-Path -LiteralPath $TranscriptPath -PathType Leaf)) {
        return [pscustomobject]@{
            State = 'accounting-unavailable'; Reason = 'transcript-not-found'; Provenance = $null
            Tokens = $emptyTokens; TotalCostUsd = $null; ModelUsageKeys = @()
            UsageWasAllZero = $false; UsageCrossChecked = $false; CrossCheckReason = $null
        }
    }

    $readError = $null
    $rawLines = @(Get-Content -LiteralPath $TranscriptPath -Encoding utf8 -ErrorAction SilentlyContinue -ErrorVariable readError)

    if ($readError -and $readError.Count -gt 0) {
        return [pscustomobject]@{
            State = 'accounting-unavailable'; Reason = 'transcript-read-error'; Provenance = $null
            Tokens = $emptyTokens; TotalCostUsd = $null; ModelUsageKeys = @()
            UsageWasAllZero = $false; UsageCrossChecked = $false; CrossCheckReason = $null
        }
    }

    if ($rawLines.Count -eq 0) {
        return [pscustomobject]@{
            State = 'accounting-unavailable'; Reason = 'transcript-empty'; Provenance = $null
            Tokens = $emptyTokens; TotalCostUsd = $null; ModelUsageKeys = @()
            UsageWasAllZero = $false; UsageCrossChecked = $false; CrossCheckReason = $null
        }
    }

    $summedTokens = @{ input = 0; output = 0; cache_creation = 0; cache_read = 0 }
    $sawAssistantEvent = $false
    $lastResultEvent = $null

    foreach ($rawLine in $rawLines) {
        $trimmed = $rawLine.Trim()
        if ([string]::IsNullOrEmpty($trimmed)) { continue }

        $evt = $null
        try {
            $evt = $trimmed | ConvertFrom-Json -AsHashtable -ErrorAction Stop
        }
        catch {
            # Malformed or partial/mid-write tail line: skip silently, the
            # same tolerance convention step 1 established.
            continue
        }
        if ($null -eq $evt -or $evt -isnot [System.Collections.IDictionary]) { continue }

        if ($evt['type'] -eq 'assistant') {
            $sawAssistantEvent = $true
            $eventUsage = Get-EventUsage -Evt $evt
            $summedTokens.input += $eventUsage['input']
            $summedTokens.output += $eventUsage['output']
            $summedTokens.cache_creation += $eventUsage['cache_creation']
            $summedTokens.cache_read += $eventUsage['cache_read']
            continue
        }

        if ($evt['type'] -eq 'result') {
            # Last one wins on a transcript carrying more than one -- the
            # same last-write-wins convention Get-GoalRunStatusEvent uses.
            $lastResultEvent = $evt
        }
    }

    if ($null -ne $lastResultEvent) {
        $resultUsage = $lastResultEvent['usage']
        $resultUsageIsDict = ($resultUsage -is [System.Collections.IDictionary])
        $resultTokens = if ($resultUsageIsDict) {
            @{
                input          = [int]($resultUsage['input_tokens'] ?? 0)
                output         = [int]($resultUsage['output_tokens'] ?? 0)
                cache_creation = [int]($resultUsage['cache_creation_input_tokens'] ?? 0)
                cache_read     = [int]($resultUsage['cache_read_input_tokens'] ?? 0)
            }
        }
        else {
            @{ input = 0; output = 0; cache_creation = 0; cache_read = 0 }
        }

        $resultUsageAllZero = ($resultTokens.input -eq 0 -and $resultTokens.output -eq 0 -and $resultTokens.cache_creation -eq 0 -and $resultTokens.cache_read -eq 0)

        $modelUsage = $lastResultEvent['modelUsage']
        $modelUsageIsDict = ($modelUsage -is [System.Collections.IDictionary])
        # M20 fix: modelUsage keys are free-form, transcript-derived strings
        # (model ids) read straight off the terminal 'result' event -- they
        # never passed through Select-GoalRunAllowedFields/
        # Get-GoalRunRedactedText the way goal_status.condition/reason do
        # (goal-run-transcript-core.ps1). Route them through the same
        # secret-redaction pass before they are ever returned, so a
        # secret-shaped model-id string cannot reach a durable artifact
        # unredacted.
        $modelUsageKeys = if ($modelUsageIsDict) { @($modelUsage.Keys | ForEach-Object { Get-GoalRunRedactedText -Text ([string]$_) }) } else { @() }

        $modelUsageTokens = @{ input = 0; output = 0; cache_creation = 0; cache_read = 0 }
        if ($modelUsageIsDict) {
            foreach ($modelKey in $modelUsageKeys) {
                $perModel = $modelUsage[$modelKey]
                if ($perModel -isnot [System.Collections.IDictionary]) { continue }
                $modelUsageTokens.input += [int]($perModel['inputTokens'] ?? 0)
                $modelUsageTokens.output += [int]($perModel['outputTokens'] ?? 0)
                $modelUsageTokens.cache_creation += [int]($perModel['cacheCreationInputTokens'] ?? 0)
                $modelUsageTokens.cache_read += [int]($perModel['cacheReadInputTokens'] ?? 0)
            }
        }

        $totalCostUsdRaw = $lastResultEvent['total_cost_usd']
        $totalCostUsd = $null
        if ($totalCostUsdRaw -is [double] -or $totalCostUsdRaw -is [int] -or $totalCostUsdRaw -is [long]) {
            $totalCostUsd = [double]$totalCostUsdRaw
        }

        $modelUsageNonZero = ($modelUsageTokens.input -gt 0 -or $modelUsageTokens.output -gt 0 -or $modelUsageTokens.cache_creation -gt 0 -or $modelUsageTokens.cache_read -gt 0)
        $costNonZero = ($null -ne $totalCostUsd -and $totalCostUsd -gt 0)

        if (-not $resultUsageAllZero) {
            # Healthy build: usage already agrees with reality -- trust it
            # directly. Still report whether a modelUsage cross-check was
            # even possible on this event.
            return [pscustomobject]@{
                State             = 'accounting-present'
                Reason            = $null
                Provenance        = 'result-event-usage'
                Tokens            = $resultTokens
                TotalCostUsd      = $totalCostUsd
                ModelUsageKeys    = $modelUsageKeys
                UsageWasAllZero   = $false
                UsageCrossChecked = $modelUsageIsDict
                CrossCheckReason  = $null
            }
        }

        if ($modelUsageNonZero -or $costNonZero) {
            # The #873 silent-zero defect class: a well-formed all-zero
            # usage object on a real, priced run. modelUsage/total_cost_usd
            # carry the truth -- the raw zero is never trusted at face
            # value.
            return [pscustomobject]@{
                State             = 'accounting-present'
                Reason            = $null
                Provenance        = 'result-event-modelusage-crosscheck'
                Tokens            = $modelUsageTokens
                TotalCostUsd      = $totalCostUsd
                ModelUsageKeys    = $modelUsageKeys
                UsageWasAllZero   = $true
                UsageCrossChecked = $true
                CrossCheckReason  = 'usage-all-zero-but-modelusage-or-cost-nonzero'
            }
        }

        # Genuine zero: usage, modelUsage, and total_cost_usd all agree on
        # zero or absent -- nothing was spent.
        return [pscustomobject]@{
            State             = 'accounting-present'
            Reason            = $null
            Provenance        = 'result-event-usage'
            Tokens            = $resultTokens
            TotalCostUsd      = $totalCostUsd
            ModelUsageKeys    = $modelUsageKeys
            UsageWasAllZero   = $true
            UsageCrossChecked = $modelUsageIsDict
            CrossCheckReason  = $null
        }
    }

    if ($sawAssistantEvent) {
        # No terminal result event on this transcript (the expected shape
        # for most Arm I interactive runs) -- fall back to the whole-
        # session 'assistant' event usage sum. No modelUsage/total_cost_usd
        # exists on this path to cross-check against.
        return [pscustomobject]@{
            State             = 'accounting-present'
            Reason            = $null
            Provenance        = 'assistant-turn-sum'
            Tokens            = $summedTokens
            TotalCostUsd      = $null
            ModelUsageKeys    = @()
            UsageWasAllZero   = ($summedTokens.input -eq 0 -and $summedTokens.output -eq 0 -and $summedTokens.cache_creation -eq 0 -and $summedTokens.cache_read -eq 0)
            UsageCrossChecked = $false
            CrossCheckReason  = 'no-result-event-to-crosscheck-against'
        }
    }

    return [pscustomobject]@{
        State             = 'accounting-unavailable'
        Reason            = 'no-usage-bearing-event'
        Provenance        = $null
        Tokens            = $emptyTokens
        TotalCostUsd      = $null
        ModelUsageKeys    = @()
        UsageWasAllZero   = $false
        UsageCrossChecked = $false
        CrossCheckReason  = $null
    }
}

# ---------------------------------------------------------------------------
# 5. Chain-stage-boundary composite (M4/M5/M9): the ONE live call site the
#    agents/Goal-Run.agent.md Post-Loop Chain prose names at every
#    chain-stage transition point.
# ---------------------------------------------------------------------------

function Invoke-GoalRunChainStageBoundaryHousekeeping {
    <#
    .SYNOPSIS
        The single, real, directly-named call site the Post-Loop Chain
        prose invokes at every chain-stage boundary (re-validate, CE Gate,
        review, fix-cycle, and PR-creation transitions) and at the
        loop-release point. Composes THREE previously-unwired mechanics
        into one call rather than three separate near-identical prose
        passes over the same transition points:

          1. Update-GoalRunActiveStateHeartbeat (goal-run-worktree-core.ps1,
             M5) -- refreshes heartbeat_at so Test-GoalRunInflightAppearsDead
             and the cleanup detector Get-SCDGoalRunWorktreeStatus function
             both see a live run as live.
          2. Add-GoalRunLogEntry -EntryType checkpoint (goal-run-log-core.ps1,
             M9) -- records that this stage boundary was actually reached,
             feeding the Resolve-GoalRunResumeStage -RunLogHasCheckpoint
             signal via Test-GoalRunLogHasCheckpoint.
          3. Invoke-GoalRunBudgetChainBoundaryCheck (this file, M4) --
             resolves the wall-clock arm state and composes it with the
             other four halt-precedence conditions via
             Resolve-GoalRunHaltPrecedence (goal-run-chain-core.ps1),
             wiring -BudgetExhausted from the REAL arm-state result rather
             than leaving that precedence slot permanently unset.

        A heartbeat-update failure is caught and warned, not fatal --
        housekeeping failing must never itself abort a chain-stage
        transition the way a genuine halt producer would. A run-log write
        refusal (schema-invalid or unwritable) is likewise surfaced on the
        return object rather than thrown, for the same reason.
    .OUTPUTS
        [pscustomobject]@{ Heartbeat; HeartbeatError; LogEntry; ArmState; Precedence }
        Precedence is the Resolve-GoalRunHaltPrecedence output -- callers
        check .Precedence.HasHalt / .Precedence.HaltReason exactly as any
        other chain-stage-boundary halt-precedence call already does.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$WorktreePath,
        [Parameter(Mandatory)][int]$Issue,
        [Parameter(Mandatory)][string]$CurrentSessionId,
        [Parameter(Mandatory)][datetime]$LaunchedAt,
        [Parameter(Mandatory)][double]$CeilingMinutes,
        [Parameter(Mandatory)][string]$CommitSha,
        [Parameter(Mandatory)][string]$CheckpointSummary,
        [string]$RepoRoot,
        [datetime]$Now = [datetime]::MinValue,
        [string]$RegistryPath,
        [scriptblock]$WarningEmitter,
        [switch]$InvariantConflict,
        [switch]$UnachievableTarget,
        [switch]$GateInputNeeded,
        [switch]$ChainStageFailure
    )

    $heartbeat = $null
    $heartbeatError = $null
    try {
        $heartbeat = Update-GoalRunActiveStateHeartbeat -WorktreePath $WorktreePath
    }
    catch {
        $heartbeatError = $_.Exception.Message
        Write-Warning "Invoke-GoalRunChainStageBoundaryHousekeeping: heartbeat update failed at '$WorktreePath' -- $heartbeatError"
    }

    $logEntry = Add-GoalRunLogEntry -WorktreePath $WorktreePath -Issue $Issue -EntryType 'checkpoint' `
        -Data @{ commit_sha = $CommitSha; summary = $CheckpointSummary } -RepoRoot $RepoRoot

    $budget = Invoke-GoalRunBudgetChainBoundaryCheck -CurrentSessionId $CurrentSessionId -LaunchedAt $LaunchedAt `
        -CeilingMinutes $CeilingMinutes -Now $Now -RegistryPath $RegistryPath -WarningEmitter $WarningEmitter `
        -InvariantConflict:$InvariantConflict -UnachievableTarget:$UnachievableTarget -GateInputNeeded:$GateInputNeeded -ChainStageFailure:$ChainStageFailure

    return [pscustomobject]@{
        Heartbeat      = $heartbeat
        HeartbeatError = $heartbeatError
        LogEntry       = $logEntry
        ArmState       = $budget.ArmState
        Precedence     = $budget.Precedence
    }
}
