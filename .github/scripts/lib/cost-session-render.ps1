#Requires -Version 7.0
<#
.SYNOPSIS
    Callable, dot-sourceable cost-session render entry point (issue #824, Step 4a).
.DESCRIPTION
    Invoke-CostSessionRender: extracts the walk -> attribution -> completeness ->
    eligibility -> preservation -> render pipeline that used to live inline inside
    frame-credit-ledger.ps1's Step 6 cost-processing block, so a second caller
    (the issue #824 Step 4b startup harvest) can re-run the identical sequence
    against a different target (a historical merged PR's branch/session) instead
    of the live PR-creation context.

    This function is a pure compute-and-return pipeline: it does NOT call
    Find-OrUpsertComment or post anything itself. It returns a structured result
    (the composed cost section, the completeness/eligibility result, the token
    sum, and the decision inputs a caller needs to perform its own degraded-
    comment retraction/post) so the live PR-creation caller and the future
    harvest caller can each apply their own write strategy (a fresh comment vs.
    a section-splice) on top of the same computed data.

    Identity/context inputs that vary by caller (PR number, branch, slug, parent
    cwd, repo root, PR body, prior comments, orchestrated-origin flag) are all
    accepted as parameters. Inputs that are always the same regardless of
    caller (the cost-rate-table path, walker timeout env-var names, the cost
    budget) stay as internal defaults, resolved inside the function exactly as
    they were resolved inline before this extraction.
.NOTES
    Dependencies (must already be dot-sourced by the caller — this file does
    not dot-source them itself, matching cost-baseline-harvest.ps1's own
    caller-owns-dependencies convention). This list is authoritative and was
    empirically verified (issue #824 post-review fix, Group 1) by
    dot-sourcing exactly this set in a fresh process and confirming
    Invoke-CostSessionRender runs its real logic (no
    CommandNotFoundException) rather than silently no-op'ing via its own
    internal fail-open try/catch:
      - lib/path-normalize.ps1        (Get-NormalizedPath — used by cost-walker.ps1)
      - lib/cost-walker.ps1           (Invoke-CostTranscriptWalk, Get-CostWalkerCurrentSessionId)
      - lib/cost-walker-copilot.ps1   (Invoke-CostCopilotWalk, Resolve-CostCopilotOutfileTemplate)
      - lib/cost-attribution.ps1      (Get-CostAttribution, Get-EventProvider)
      - lib/cost-anomaly.ps1          (Get-CostAnomalyFlags)
      - lib/cost-rolling-history.ps1  (Get-CostPatternDataFromComment, ConvertFrom-CostPatternYaml)
      - lib/cost-checkpoint-core.ps1  (Get-MostRecentRegimeCheckpoint)
      - lib/cost-completeness.ps1     (Get-SessionCompleteness, Resolve-BaselineEligibility, Resolve-CostDataPreservation)
      - lib/cost-pattern-renderer.ps1 (Format-CostPatternMarkdown, Format-CostPatternYaml)
      - lib/cost-fcl-helpers.ps1      (the script:-scoped FCL cost-pipeline
                                        helpers this function calls directly —
                                        see that file's own header for the
                                        full list and the issue #824
                                        post-review root-cause history)
    This file (cost-session-render.ps1) is dot-sourced last, after all of the
    above.
#>

function Invoke-CostSessionRender {
    <#
    .SYNOPSIS
        Runs the walk -> attribution -> completeness -> eligibility -> preservation
        -> render pipeline for one cost session and returns a structured result.
    .DESCRIPTION
        See the file-level .DESCRIPTION above. Callers own posting: this function
        never calls Find-OrUpsertComment. The two degraded-comment side effects
        that used to fire inline (retracting a stale standalone degraded comment
        once real events reappear, and auto-posting a new standalone degraded
        comment on genuine degradation) are reduced to boolean decisions plus
        composed bodies in the return value — the caller performs the actual
        posts using its own -Pr/-Marker wiring, exactly as it did before this
        extraction.
    .PARAMETER Pr
        The PR number the render is being composed for. Passed through to
        Format-CostPatternMarkdown/-Yaml, Compose-FCLDegradedCostComment, and used
        to build the degraded-comment discovery marker.
    .PARAMETER Branch
        The branch identity for this cost session (the live checkout's current
        branch for the PR-creation caller; a historical PR's branch for a future
        harvest caller).
    .PARAMETER Slug
        The cost-transcript slug identity for this session (caller-resolved —
        e.g. via Get-CostTranscriptSlug for the live caller).
    .PARAMETER ParentCwd
        The parent cwd used to identify/walk this session's transcripts.
    .PARAMETER RepoRoot
        The repo root used to resolve internal, caller-invariant paths (the cost
        rate table, the regime-checkpoints YAML, the Copilot OTEL jsonl default).
    .PARAMETER PrBody
        The PR body text (used only to resolve a linked issue number for the
        walk parameters).
    .PARAMETER PriorComments
        The PR's existing comments (used to locate a prior cost-pattern-data
        comment for preservation, and a prior standalone degraded comment for
        the retraction decision). May be $null.
    .PARAMETER IsOrchestrated
        Whether this PR is orchestrated-origin (gates both degraded-comment
        decisions, matching the pre-extraction inline behavior).
    .PARAMETER AdmitCorroboratedFallback
        Issue #825 s3. Opt-in switch, off by default — threaded straight through
        to Invoke-CostTranscriptWalk's own -AdmitCorroboratedFallback (added by
        s1). The live PR-creation caller never sets this (M10: that path stays
        fail-closed). The s3 targeted-repair entry point
        (Invoke-CostAttributionRepair, cost-baseline-harvest.ps1) is the one
        caller that turns it on, for one maintainer-named PR at a time.
    .PARAMETER CorroborationWindowStart
    .PARAMETER CorroborationWindowEnd
        Issue #825 s3 (post-review fix, M8 wiring gap). Threaded straight
        through to Invoke-CostTranscriptWalk's own -CorroborationWindowStart/
        -End (added by s1, bounds Tier-2-admitted events only). $null by
        default and never set by the live PR-creation caller. Invoke-
        CostAttributionRepair is the one caller that supplies these — the
        target PR's own createdAt/mergedAt — so the M8 same-repo reused-
        branch-name collision guard is actually enforced on the one path that
        ships in issue #825 (the automatic-drain path where this would also
        matter is deferred to #841). Without this, Tier-2 admission on the
        shipped path runs unbounded despite the walker itself supporting the
        bound.
    .OUTPUTS
        [hashtable] with keys: CostSection, Completeness, TokenSum, Attribution,
        SessionId, CostEventsCount, UsePriorCostSection, DegradedMarker,
        ShouldRetractDegraded, RetractDegradedBody, ShouldPostDegraded,
        PostDegradedBody.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][int]$Pr,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Branch,
        [AllowEmptyString()][string]$Slug = '',
        [Parameter(Mandatory)][string]$ParentCwd,
        [Parameter(Mandatory)][string]$RepoRoot,
        [AllowEmptyString()][string]$PrBody = '',
        [AllowNull()]$PriorComments = $null,
        [bool]$IsOrchestrated = $false,
        [switch]$AdmitCorroboratedFallback,
        [Nullable[datetime]]$CorroborationWindowStart = $null,
        [Nullable[datetime]]$CorroborationWindowEnd = $null
    )

    $costBudgetSeconds = 19
    $costStopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    # $costSection and $degradedMarker are the only pre-declared locals here.
    # Every other working variable below (costEvents, costAttribution,
    # completeness, currentTokenSum, currentSessionId, usePriorCostSection,
    # the ShouldRetract/PostDegraded decision variables) is intentionally left
    # undeclared until its first real assignment, matching exactly where the
    # pre-extraction inline block first assigned each one. PowerShell variable
    # names are case-insensitive; pre-declaring a local (even to $null) before
    # its real assignment CAN shadow a same-named OUTER/closure variable that
    # a later-called (possibly test-mocked) function reads — this is not
    # theoretical: the existing test suite (the cost-integration.Tests.ps1 file's
    # "Baseline eligibility caller wiring" context) mocks Get-SessionCompleteness
    # as a closure that reads a bare `$Completeness` scriptblock parameter by
    # name; PowerShell variable lookup is case-insensitive, so pre-declaring
    # this function's own local `$completeness` before that mock is CALLED
    # shadows the outer `$Completeness` and silently breaks the mock (issue
    # #824 post-review fix M17 regression, caught empirically — see git
    # history for the RED reproduction). Reads of a genuinely never-assigned
    # variable are already safe (silently $null, no exception) under DEFAULT
    # (non-strict) PowerShell, so no pre-declaration is needed for the
    # catch/return path below; $costSection is the one exception because a
    # legitimate non-exception code path (the 6g budget-exhaustion edge case)
    # can also leave it unassigned this iteration, matching the original
    # inline block's own pre-declaration of $costSection at the same outer
    # position.
    $costSection = ''
    $degradedMarker = "<!-- cost-pattern-data-degraded-$Pr -->"

    try {
        # Env override for the cost render budget (issue #825 CE Gate): on a
        # large-profile machine (large ~/.claude/projects) the walk can legitimately
        # exceed the 19s default before step-6g composes the section, so the section
        # can never be rendered without a bigger budget. Resolved INSIDE this try so an
        # unreachable FCL helper degrades to the 19s default via the outer fail-open
        # catch (preserving the #824 dependency-chain contract) instead of throwing.
        # Reuses Get-FCLCostWalkerTimeoutSeconds' exact shape, matching the walker-timeout
        # overrides below: env present + valid positive int -> use it; else the default.
        $costBudgetSeconds = script:Get-FCLCostWalkerTimeoutSeconds -EnvironmentVariableName 'FRAME_CREDIT_LEDGER_TEST_COST_BUDGET_SECONDS' -DefaultSeconds $costBudgetSeconds

        # 6a. Walkers
        $costEvents = @()
        $claudeWalk = $null
        $copilotWalk = $null
        $copilotOtelJsonlPath = ''
        # Issue #825 s2, M6: out-parameter ref for the walker's Tier-2
        # rejected-dir count (see cost-walker.ps1's -RejectedDirCountVar,
        # added by s1). AdmitCorroboratedFallback defaults off (this
        # function's own switch, threaded straight through below) so this
        # stays 0 for the live PR-create caller (M10 — that path stays
        # fail-closed); the s3 targeted-repair entry point
        # (Invoke-CostAttributionRepair) is the one caller that turns the
        # switch on and produces a nonzero count. Threaded through
        # regardless so the annotation wiring below is correct either way.
        $rejectedDirCountRef = [ref]0
        if (-not [string]::IsNullOrWhiteSpace($Slug) -and -not [string]::IsNullOrWhiteSpace($Branch)) {
            $resolvedIssueNumber = script:Resolve-FCLLinkedIssueNumber -PrBody $PrBody -Branch ([string]$Branch)
            $walkParameters = @{
                Slug                = $Slug
                Branch              = $Branch
                ParentCwd           = $ParentCwd
                RepoRoot            = $RepoRoot  # D2: used by identity-based slug discovery
                RejectedDirCountVar = $rejectedDirCountRef
            }
            if ($AdmitCorroboratedFallback) {
                # Issue #825 s3: opt-in Tier-2 corroborated-fallback trust ladder,
                # this caller only (M10 — never set by the live PR-create path).
                $walkParameters['AdmitCorroboratedFallback'] = $true

                # C2 (issue #825 post-review fix): a SECOND, branch-prefix-ONLY
                # resolution (PrBody forced empty) feeds specifically the Tier-2
                # corroboration gate. $resolvedIssueNumber (body-inclusive, below)
                # stays reserved for phase-marker windowing, where trusting the PR
                # body is legitimate — the Tier-2 trust ladder must not accept an
                # author-controllable PR-body issue reference as its corroboration
                # signal. Scoped to the AdmitCorroboratedFallback branch only —
                # Tier2IssueNumber is meaningless (and unconsumed) on the live
                # PR-create path, which never turns Tier 2 on. Set UNCONDITIONALLY
                # (even when $null) — cost-walker.ps1's Tier2 gate distinguishes an
                # explicitly-supplied $null (fail closed) from an omitted parameter
                # (legacy fallback to -IssueNumber) via ContainsKey; omitting this key
                # here whenever resolution comes back empty would silently re-admit
                # the PR-body-derived -IssueNumber as the Tier-2 fallback, defeating
                # this fix for the exact case it targets (branch doesn't match the
                # issue-prefix pattern, so only the PR body names an issue).
                $tier2ResolvedIssueNumber = script:Resolve-FCLLinkedIssueNumber -PrBody '' -Branch ([string]$Branch)
                $walkParameters['Tier2IssueNumber'] = if ($null -ne $tier2ResolvedIssueNumber) { [int]$tier2ResolvedIssueNumber } else { $null }
            }
            if ($null -ne $CorroborationWindowStart) {
                # Issue #825 s3 (post-review fix, M8 wiring gap): bounds Tier-2
                # admission to the caller-supplied window (Invoke-
                # CostAttributionRepair passes the target PR's own
                # createdAt/mergedAt). A $null bound is not enforced by the
                # walker (see cost-walker.ps1), matching that function's own
                # contract.
                $walkParameters['CorroborationWindowStart'] = $CorroborationWindowStart
            }
            if ($null -ne $CorroborationWindowEnd) {
                $walkParameters['CorroborationWindowEnd'] = $CorroborationWindowEnd
            }
            if ($null -ne $resolvedIssueNumber) {
                $walkParameters['IssueNumber'] = [int]$resolvedIssueNumber
            }

            $claudeTimeoutSeconds = script:Get-FCLCostWalkerTimeoutSeconds -EnvironmentVariableName 'FRAME_CREDIT_LEDGER_TEST_CLAUDE_WALKER_TIMEOUT_SECONDS' -DefaultSeconds 10
            $copilotTimeoutSeconds = script:Get-FCLCostWalkerTimeoutSeconds -EnvironmentVariableName 'FRAME_CREDIT_LEDGER_TEST_COPILOT_WALKER_TIMEOUT_SECONDS' -DefaultSeconds 6

            $claudeWalk = script:Invoke-FCLCostWalkerWithTimeout `
                -WalkerName 'claude' `
                -CommandName 'Invoke-CostTranscriptWalk' `
                -Parameters $walkParameters `
                -TimeoutSeconds $claudeTimeoutSeconds

            $copilotOtelJsonlPath = script:Resolve-FCLCostCopilotOtelJsonlPath -RepoRoot $RepoRoot
            $copilotWalkParameters = @{
                Branch                  = [string]$Branch
                RepoRoot                = $RepoRoot
                OtelJsonlPath           = $copilotOtelJsonlPath
                WorkspaceFolderBasename = (Split-Path -Leaf $RepoRoot)
            }
            $copilotWalk = script:Invoke-FCLCostWalkerWithTimeout `
                -WalkerName 'copilot' `
                -CommandName 'Invoke-CostCopilotWalk' `
                -Parameters $copilotWalkParameters `
                -TimeoutSeconds $copilotTimeoutSeconds

            $costEvents = @($claudeWalk.Events) + @($copilotWalk.Events)
        }

        if ($null -ne $claudeWalk -and $claudeWalk.Failed -eq $true -and ($null -eq $copilotWalk -or @($copilotWalk.Events).Count -eq 0)) {
            throw 'Claude cost walker failed and no Copilot events were available for fallback attribution'
        }

        # 6b. Attribution
        # Resolve the cost-scripts dir from $RepoRoot directly (rather than
        # $PSScriptRoot, which for a function is bound to the FILE the function
        # is DEFINED in — this file's own lib/ directory, not
        # frame-credit-ledger.ps1's directory — and would double up the 'lib/'
        # segment below). $RepoRoot + '.github/scripts' is exactly the value
        # $PSScriptRoot resolved to for the pre-extraction inline block (whose
        # code lived directly inside frame-credit-ledger.ps1), so this is
        # behavior-preserving for the existing caller while also being correct
        # now that the logic lives in a separate file.
        $costScriptsDir = Join-Path $RepoRoot '.github/scripts'
        $costAttribution = Get-CostAttribution -Events $costEvents -RateTablePath (Join-Path $costScriptsDir 'lib/cost-rate-table.json')
        script:Set-FCLCostCoverageMetadata -Attribution $costAttribution -Events $costEvents -ClaudeWalk $claudeWalk -CopilotWalk $copilotWalk -CopilotOtelJsonlPath $copilotOtelJsonlPath

        # 6c. Rolling history (has its own 10s timeout via Get-CostRollingHistory)
        $rollingResult = @{ timed_out = $false; entries = @() }
        $remainingCostBudgetSeconds = script:Get-FCLRemainingCostBudgetSeconds -Stopwatch $costStopwatch -BudgetSeconds $costBudgetSeconds
        if ($remainingCostBudgetSeconds -gt 0) {
            try { $rollingResult = Get-CostRollingHistory -TimeoutSeconds ([Math]::Min(10, $remainingCostBudgetSeconds)) }
            catch { $rollingResult = @{ timed_out = $true; entries = @() } }
        }
        script:Set-FCLRollingMetaCoverageCount -RollingResult $rollingResult -Attribution $costAttribution

        # 6d. Regime checkpoint
        $checkpoint = $null
        if ((script:Get-FCLRemainingCostBudgetSeconds -Stopwatch $costStopwatch -BudgetSeconds $costBudgetSeconds) -gt 0) {
            try {
                $cpPath = Join-Path $RepoRoot '.github/scripts/cost-regime-checkpoints.yaml'
                if (Test-Path $cpPath) { $checkpoint = Get-MostRecentRegimeCheckpoint -Path $cpPath -Coverage ([string]$costAttribution['coverage']) }
            }
            catch { $checkpoint = $null }
        }

        # 6e. Completeness + preservation

        # Compute current token sum from attribution (populated predicate, issue #777 s2).
        # Use totals['tokens'] as the authoritative full-session sum (includes overhead +
        # unattributed tokens that are never placed into any port bucket — CR2).
        # Fall back to ports-only sum if totals is unavailable (e.g., old data format).
        # Computed BEFORE Get-SessionCompleteness/Resolve-BaselineEligibility (issue #824
        # s3) so the eligibility wrapper's mid-session predicate has TokenSum available.
        [long]$currentTokenSum = 0
        $currentTotalsTokens = if ($null -ne $costAttribution -and $costAttribution.ContainsKey('totals') -and
                                    $null -ne $costAttribution['totals'] -and $costAttribution['totals'].ContainsKey('tokens')) {
            $costAttribution['totals']['tokens']
        } else { $null }
        if ($null -ne $currentTotalsTokens) {
            $currentTokenSum += script:Get-FCLTokenSumFromBucket -Bucket $currentTotalsTokens
        } elseif ($null -ne $costAttribution -and $costAttribution.ContainsKey('ports')) {
            foreach ($portBucket in $costAttribution['ports'].Values) {
                if ($null -ne $portBucket -and $portBucket.ContainsKey('tokens')) {
                    $currentTokenSum += script:Get-FCLTokenSumFromBucket -Bucket $portBucket['tokens']
                }
            }
        }

        $completenessParameters = @{ Events = $costEvents }
        if (-not [string]::IsNullOrWhiteSpace($Branch)) {
            $completenessParameters['Branch'] = [string]$Branch
        }
        $completeness = Get-SessionCompleteness @completenessParameters

        # Issue #824 s3: resolve rolling-baseline eligibility + capture_point disclosure.
        # Reassigns $completeness to the SAME (in-place-mutated) hashtable exactly once,
        # before it reaches all three consumers below: Format-CostPatternMarkdown,
        # Format-CostPatternYaml, and Resolve-CostDataPreservation (plan stress-test M1 —
        # every consumer must read one post-eligibility object, not a stale copy).
        $completeness = Resolve-BaselineEligibility -CompletenessResult $completeness -TokenSum $currentTokenSum -Events $costEvents -Branch ([string]$Branch)

        # Capture-time session identity (issue #824 s3), persisted into the YAML block so
        # the s4 harvest can re-walk and verify the originating transcript next session.
        # Derived from the transcript FILE's name on disk (grounding fix — real transcript
        # events carry no embedded sessionId field; see Get-CostWalkerCurrentSessionId's
        # docstring), reusing the same identity parameters already resolved above for the
        # walkers themselves (do not recompute).
        $currentSessionId = ''
        if (-not [string]::IsNullOrWhiteSpace($Slug) -and -not [string]::IsNullOrWhiteSpace($Branch)) {
            $currentSessionId = Get-CostWalkerCurrentSessionId -Slug $Slug -Branch ([string]$Branch) -ParentCwd $ParentCwd -RepoRoot $RepoRoot
        }

        $priorCostData = $null
        $priorComment = $null
        if ($null -ne $PriorComments) {
            $priorComment = @($PriorComments | Where-Object { $_.body -match '<!-- cost-pattern-data' }) | Select-Object -Last 1
            if ($priorComment) {
                # Fix #760-D1-c: parse the actual prior comment body rather than using a
                # hardcoded stub, and use a flat shape so Resolve-CostDataPreservation can
                # read $Prior['completeness'] as a string (not a nested hashtable).
                $priorYaml = script:Get-CostPatternDataFromComment -Body $priorComment.body
                if ($null -ne $priorYaml) {
                    $priorCostData = script:ConvertFrom-CostPatternYaml -Yaml $priorYaml
                }
                # Fix #760-C3: a populated prior cost-pattern-data block must never be
                # clobbered by an empty/partial current walk.  A block that predates the
                # session_completeness field parses with a null 'completeness' (and a fully
                # unextractable body yields $null priorCostData).  In both cases the marker's
                # presence means a genuine render already exists — the old contract only wrote
                # the block on a populated render — so default any prior block lacking an
                # explicit completeness to 'complete'.  Resolve-CostDataPreservation then
                # preserves it instead of overwriting with the empty/partial current.
                if ($null -eq $priorCostData) {
                    $priorCostData = @{ completeness = 'complete' }
                }
                elseif ([string]::IsNullOrWhiteSpace([string]$priorCostData['completeness'])) {
                    $priorCostData['completeness'] = 'complete'
                }
            }
        }

        # Fix #760-D1-b: wire the Resolve-CostDataPreservation result instead of discarding it.
        # This drives the skip-when-absent gate below (AC1 + AC2).
        # (currentTokenSum is computed earlier, above the completeness/eligibility calls —
        # issue #824 s3 reorder — and reused here unchanged, per DD3/M9.)

        # Compute prior token sum from parsed prior YAML (if available).
        # cost-rolling-history ConvertFrom-CostPatternYaml does not parse totals.tokens, so
        # use ports-only sum for prior. This is consistent with what was stored.
        [long]$priorTokenSum = 0
        if ($null -ne $priorCostData -and $priorCostData.ContainsKey('ports')) {
            $priorPorts = $priorCostData['ports']
            # ports is a hashtable keyed by port name (ConvertFrom-CostPatternYaml line 327)
            $priorPortValues = if ($priorPorts -is [hashtable]) { $priorPorts.Values } elseif ($priorPorts -is [array]) { $priorPorts } else { @() }
            foreach ($portBucket in $priorPortValues) {
                if ($null -ne $portBucket -and $portBucket.ContainsKey('tokens')) {
                    $priorTokenSum += script:Get-FCLTokenSumFromBucket -Bucket $portBucket['tokens']
                }
            }
        }

        $preservationResult = Resolve-CostDataPreservation -Current $completeness -Prior $priorCostData -CurrentTokenSum $currentTokenSum -PriorTokenSum $priorTokenSum

        # Issue #824 s3 DD7: recurrence guard. Warns once when the current capture is
        # baseline-ineligible AND every entry in the already-fetched rolling history is
        # also ineligible — a signal distinct from cold start (empty history) or a
        # degraded/timed-out fetch, which must stay silent (see
        # script:Test-FCLRecurrenceGuardShouldWarn for the full predicate).
        if (script:Test-FCLRecurrenceGuardShouldWarn -CurrentExcluded ([bool]$completeness['excluded_from_rolling_baseline']) -RollingResult $rollingResult) {
            [Console]::Error.WriteLine('frame-credit-ledger: all recent captures baseline-ineligible — possible eligibility regression')
        }

        # Fix #760-D1-a: skip-when-absent gate — if preservation says to use_prior, reuse the
        # prior comment's cost section verbatim.  This fires when the projects root is absent
        # (CI enforce on ubuntu-latest) AND the prior comment had a complete render, preventing
        # an empty walk from overwriting a populated cost-pattern-data block.  Invariant: a
        # populated block is NEVER replaced by an empty one.
        $usePriorCostSection = $preservationResult['use_prior'] -eq $true

        # Issue #794 review fix H (post-fix review F1): decide whether to retract a stale
        # standalone degraded-telemetry comment once real cost events show up on a later
        # run of the same orchestrated-origin PR. Without this, a degraded comment posted
        # elsewhere (AC6, below) persists indefinitely, misleadingly asserting "no cost
        # events" beside real data. This decision is branch-independent: it must fire
        # whenever real events are found and a prior degraded comment exists, regardless of
        # which cost-data-rendering path ($usePriorCostSection true or false) the rest of
        # this function takes below -- a current run can find real events while still using
        # the prior comment's rendered section verbatim (e.g. current completeness is
        # 'partial' while the prior comment is 'complete'), so gating this solely on the
        # use_prior branch would miss that case. Guard mirrors the degraded-post guard's
        # IsOrchestrated check, but keys off real events being present rather than absent.
        # The actual Find-OrUpsertComment call is left to the caller (see file-level
        # .DESCRIPTION) — this function only decides + composes the body.
        $priorDegradedComment = if ($null -ne $PriorComments) {
            @($PriorComments | Where-Object { $_.body -like "*$degradedMarker*" }) | Select-Object -First 1
        } else { $null }
        if ($IsOrchestrated -and $null -ne $priorDegradedComment -and @($costEvents).Count -gt 0) {
            $shouldRetractDegraded = $true
            $retractDegradedBody = "$degradedMarker`n_Telemetry recovered — see the main cost-pattern-data comment above for current data._"
        }

        if ($usePriorCostSection -and $null -ne $priorComment) {
            $priorYamlForSection = script:Get-CostPatternDataFromComment -Body $priorComment.body
            $preservationNotice = $preservationResult['notice']
            $noticeBlock = if ($null -ne $preservationNotice -and $preservationNotice -ne '') {
                "> [!NOTE]`n> $preservationNotice`n`n"
            } else { '' }
            if ($null -ne $priorYamlForSection) {
                # Fix #760-F3: preserve the full visible section (heading + rendered markdown
                # table + YAML block) from the prior comment, not only the hidden YAML comment.
                # Without this, the human-readable Cost Pattern table disappears when preservation
                # fires, even though the underlying data (rolling-baseline YAML) survives.
                $sectionMatch = [regex]::Match(
                    $priorComment.body,
                    $script:FCLCostPatternSectionRegex
                )
                $priorSection = if ($sectionMatch.Success) {
                    $sectionMatch.Groups['section'].Value.TrimEnd()
                } else {
                    # Fallback: visible heading unavailable — use YAML block only.
                    "<!-- cost-pattern-data`n$priorYamlForSection`n-->"
                }
                $costSection = $noticeBlock + $priorSection
            }
            else {
                # Fix #760-F9: prior block exists (loose selector matched) but the strict
                # extractor could not parse its body (malformed block — missing closing -->,
                # no newline after marker, etc.).  C3 defaulted priorCostData to 'complete'
                # above, which correctly triggers use_prior=true, but without this fallback
                # the rebuild path left $costSection='' and erased the prior block — the
                # exact opposite of the D1 invariant.  Carry the raw block verbatim instead.
                $rawBlockMatch = [regex]::Match(
                    $priorComment.body,
                    '<!--\s*cost-pattern-data[\s\S]*?-->'
                )
                if ($rawBlockMatch.Success) {
                    $costSection = $noticeBlock + $rawBlockMatch.Value
                }
                # else: truly no cost block in the body despite the selector match — leave
                # $costSection as-is (empty string). This path is not normally reachable.
            }
        }
        else {
            # 6f. Anomaly flags — only compute when not using prior (AC2: guard on use_prior)
            $anomalyFlags = @()
            if (-not $rollingResult.timed_out -and (script:Get-FCLRemainingCostBudgetSeconds -Stopwatch $costStopwatch -BudgetSeconds $costBudgetSeconds) -gt 0) {
                try { $anomalyFlags = @(Get-CostAnomalyFlags -ThisRun $costAttribution -RollingHistory @($rollingResult.entries) -RegimeCheckpoint $checkpoint) }
                catch { $anomalyFlags = @() }
            }

            # 6g. Render fresh cost section
            if ((script:Get-FCLRemainingCostBudgetSeconds -Stopwatch $costStopwatch -BudgetSeconds $costBudgetSeconds) -gt 0) {
                # Issue #825 s2, M12: the renderer stays pure (no $env: reads inside
                # cost-pattern-renderer.ps1, so the sharded Pester runner stays
                # deterministic) — this caller computes both environment-state flags
                # and threads them in. GITHUB_ACTIONS='true' mirrors the existing
                # repo-wide CI-detection convention (see render-portfolio.ps1);
                # ProjectsRootPresent reuses the same root-absence check the
                # degraded_reason='env-absent' classification already relies on
                # (script:Test-FCLClaudeProjectsRootAbsent, cost-fcl-helpers.ps1).
                # DegradedReason (L11, issue #825 post-review fix): threaded from the
                # already-computed $costAttribution so a local walker TIMEOUT renders
                # a distinct message from a genuine empty walk instead of colliding on
                # the same generic "searched and none matched" text.
                $renderContext = @{
                    IsCi                = ($env:GITHUB_ACTIONS -eq 'true')
                    ProjectsRootPresent = -not (script:Test-FCLClaudeProjectsRootAbsent)
                    DegradedReason      = [string]$costAttribution['degraded_reason']
                }
                $costMarkdown = Format-CostPatternMarkdown -Attribution $costAttribution -Completeness $completeness -AnomalyFlags $anomalyFlags -RollingMeta $rollingResult -Pr $Pr -Branch ([string]$Branch) -RenderContext $renderContext -RejectedDirCount ([int]$rejectedDirCountRef.Value)
                $costYaml = Format-CostPatternYaml -Attribution $costAttribution -Completeness $completeness -AnomalyFlags $anomalyFlags -Pr $Pr -Branch ([string]$Branch) -SessionId $currentSessionId -HeadRef ([string]$Branch)
                $costSection = $costMarkdown + "`n" + $costYaml
            }

            # Issue #794 s4 (Part 2 / AC6): decide whether to auto-post a degraded-honest
            # cost-pattern-data comment when the walker genuinely found no telemetry for an
            # orchestrated-origin PR. Sits downstream of the non-clobber guard above
            # ($usePriorCostSection is $false here, meaning either there is no prior comment,
            # or the current data is allowed to win) — a real walk with events, or a
            # populated prior comment, always wins and this branch never fires for those
            # cases (6f/6g only run at all when $costEvents is non-empty OR there is no
            # populated prior to protect). env-absent is intentionally EXCLUDED — it is the
            # expected/routine CI shape (frame-enforce.yml on ubuntu-latest, see workflow's
            # landmine comment), not a genuine anomaly worth an auto-posted comment. The
            # actual Find-OrUpsertComment call is left to the caller.
            $degradedReasonForPost = [string]$costAttribution['degraded_reason']
            $genuineDegradation = $degradedReasonForPost -in @('budget-exceeded', 'no-transcript-found')
            if ($IsOrchestrated -and $genuineDegradation -and @($costEvents).Count -eq 0) {
                $postDegradedBody = script:Compose-FCLDegradedCostComment -DegradedReason $degradedReasonForPost -Pr $Pr -Branch ([string]$Branch)
                $shouldPostDegraded = $true
            }
        }
    }
    catch {
        [Console]::Error.WriteLine("frame-credit-ledger: cost pattern composition failed: $($_.Exception.Message)")
        $costSection = ''
    }
    $costStopwatch.Stop()

    # M17 (issue #824 post-review fix): guarantee every return-surface local
    # exists before the return statement below reads it, so this function's
    # own fail-open contract holds even under Set-StrictMode (a genuinely
    # unassigned read throws under strict mode, which would defeat the catch
    # block above — the catch sets $costSection = '' specifically so a
    # composition failure never propagates, but the return statement itself
    # could still throw on any local the try block never reached). This guard
    # is placed HERE — after the try/catch has already fully run — rather
    # than as an upfront pre-declaration before the try block, because an
    # upfront pre-declaration would create these locals in THIS function's
    # scope before any inner call (e.g. Get-SessionCompleteness) executes,
    # and PowerShell's case-insensitive, call-stack-based variable lookup
    # means a test mock reading a same-named bare variable from an ancestor
    # scope (cost-integration.Tests.ps1's Get-SessionCompleteness mock reads
    # a bare $Completeness scriptblock parameter) would then resolve to THIS
    # function's own (still-$null) local instead of continuing up to the
    # real outer value — silently shadowing it. Placing the guard after the
    # try/catch avoids that entirely: by this point every inner call has
    # already resolved its own variable lookups using the correct (no-shadow)
    # scope chain, so filling in a safe default here cannot retroactively
    # change what any already-completed inner call saw. Uses
    # `Get-Variable -Scope 0` (strictly this function's own local scope, no
    # ancestor walk) rather than `Test-Path variable:...` — the latter has
    # the identical ancestor-walk behavior as a bare variable read and would
    # reintroduce the same shadowing hazard this guard exists to avoid.
    if ($null -eq (Get-Variable -Name 'costEvents' -Scope 0 -ErrorAction SilentlyContinue)) { $costEvents = @() }
    if ($null -eq (Get-Variable -Name 'completeness' -Scope 0 -ErrorAction SilentlyContinue)) { $completeness = $null }
    if ($null -eq (Get-Variable -Name 'costAttribution' -Scope 0 -ErrorAction SilentlyContinue)) { $costAttribution = $null }
    if ($null -eq (Get-Variable -Name 'currentTokenSum' -Scope 0 -ErrorAction SilentlyContinue)) { [long]$currentTokenSum = 0 }
    if ($null -eq (Get-Variable -Name 'currentSessionId' -Scope 0 -ErrorAction SilentlyContinue)) { $currentSessionId = '' }
    if ($null -eq (Get-Variable -Name 'usePriorCostSection' -Scope 0 -ErrorAction SilentlyContinue)) { $usePriorCostSection = $false }
    if ($null -eq (Get-Variable -Name 'shouldRetractDegraded' -Scope 0 -ErrorAction SilentlyContinue)) { $shouldRetractDegraded = $false }
    if ($null -eq (Get-Variable -Name 'retractDegradedBody' -Scope 0 -ErrorAction SilentlyContinue)) { $retractDegradedBody = $null }
    if ($null -eq (Get-Variable -Name 'shouldPostDegraded' -Scope 0 -ErrorAction SilentlyContinue)) { $shouldPostDegraded = $false }
    if ($null -eq (Get-Variable -Name 'postDegradedBody' -Scope 0 -ErrorAction SilentlyContinue)) { $postDegradedBody = $null }

    return @{
        CostSection           = $costSection
        Completeness          = $completeness
        TokenSum              = $currentTokenSum
        Attribution           = $costAttribution
        SessionId             = $currentSessionId
        CostEventsCount       = @($costEvents).Count
        UsePriorCostSection   = $usePriorCostSection
        DegradedMarker        = $degradedMarker
        ShouldRetractDegraded = $shouldRetractDegraded
        RetractDegradedBody   = $retractDegradedBody
        ShouldPostDegraded    = $shouldPostDegraded
        PostDegradedBody      = $postDegradedBody
    }
}
