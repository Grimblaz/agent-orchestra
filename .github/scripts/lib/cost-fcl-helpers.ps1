#Requires -Version 7.0
<#
.SYNOPSIS
    Shared frame-credit-ledger (FCL) cost-pipeline helper functions (issue #824
    post-review fix, Group 1).
.DESCRIPTION
    Pure relocation of the `script:`-scoped helper functions that
    Invoke-CostSessionRender (cost-session-render.ps1) and its own dependency
    chain need, out of frame-credit-ledger.ps1's own script scope and into
    this shared lib file.

    Before this extraction, all of these functions were defined only inside
    frame-credit-ledger.ps1's top-level script body. That worked for the live
    PR-creation path (frame-credit-ledger.ps1 dot-sources cost-session-render.ps1
    directly, then defines these helpers later in its own script scope before
    Invoke-CostSessionRender is ever actually called), but it silently broke
    every OTHER caller that dot-sources cost-session-render.ps1 (or
    cost-baseline-harvest.ps1, which calls Invoke-CostSessionRender) without
    also dot-sourcing the whole of frame-credit-ledger.ps1 — most notably the
    issue #824 Step 4b startup harvest, whose documented dependency list
    (skills/session-startup/platforms/claude.md Step 7d) never included
    frame-credit-ledger.ps1. Every FCL-scoped call inside
    Invoke-CostSessionRender threw CommandNotFoundException, caught by that
    function's own internal try/catch, silently returning an empty
    CostSection — the harvest mechanism shipped as a permanent, invisible
    no-op.

    Function bodies below are unmodified from their frame-credit-ledger.ps1
    originals (pure relocation, not a rewrite). They stay `script:`-scoped in
    this new home — the scoping was never the problem, only the fact that the
    file defining them was unreachable from the harvest's dependency chain.

    This file also relocates the transitive helpers those 10 originally-named
    functions themselves call (New-FCLCostWalkerResult,
    New-FCLInitialSessionStateClone, Get-FCLCostScriptState,
    Get-FCLCostEventProviderSet, Get-FCLCostUnmappedSessionCount,
    Test-FCLClaudeProjectsRootAbsent, Get-FCLEffectiveCostCoverageClass,
    Get-FCLCostMetadataValue) — moving only the 10 named in the original
    review would still have left Invoke-FCLCostWalkerWithTimeout and
    Set-FCLCostCoverageMetadata throwing on their own callees.

.NOTES
    Empirical verification (issue #824 post-review fix) also found that
    Invoke-CostSessionRender's OWN dependency chain needs several whole lib
    files that were likewise absent from the documented Step 7d dot-source
    list: path-normalize.ps1, cost-walker-copilot.ps1, cost-attribution.ps1,
    cost-anomaly.ps1, cost-checkpoint-core.ps1, cost-completeness.ps1, and
    cost-pattern-renderer.ps1. Those files are unrelated to THIS extraction
    (their functions were never trapped in frame-credit-ledger.ps1 — they are
    normal top-level functions in their own lib files); the defect there was
    purely that Step 7d's list never included them. See cost-session-render.ps1
    for the now-authoritative full dependency list, and
    skills/session-startup/platforms/claude.md Step 7d for the corrected
    dot-source set that mirrors it.
#>

# M18 (issue #824 post-review fix): the Cost Pattern section-matching regex
# used to be duplicated verbatim in both cost-session-render.ps1 and
# cost-baseline-harvest.ps1 — one shared constant here, both call sites
# reference it. `##\s+Cost Pattern\b` through the closing `-->` captures the
# full visible section (heading + rendered markdown table + hidden YAML
# block) so callers can splice/replace it as one unit.
$script:FCLCostPatternSectionRegex = '(?ms)(?<section>^##\s+Cost Pattern\b.*?<!--\s*cost-pattern-data[\s\S]*?-->)'

function script:Resolve-FCLLinkedIssueNumber {
    param(
        [AllowEmptyString()][string]$PrBody,
        [AllowEmptyString()][string]$Branch
    )

    if (-not [string]::IsNullOrWhiteSpace($Branch)) {
        $branchMatch = [regex]::Match($Branch, '^feature/issue-(?<issue>\d+)(?:-|$)')
        if ($branchMatch.Success) {
            $branchIssue = 0
            if ([int]::TryParse($branchMatch.Groups['issue'].Value, [ref]$branchIssue) -and $branchIssue -gt 0) {
                return $branchIssue
            }
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($PrBody)) {
        $patterns = @(
            '(?im)\b(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?|ref(?:s|erences)?|issue)\s+(?:[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)?#(?<issue>\d+)\b',
            '(?im)^\s*issue_id\s*:\s*(?<issue>\d+)\s*$',
            '(?im)<!--\s*(?:plan|design)-issue-(?<issue>\d+)\s*-->'
        )

        foreach ($pattern in $patterns) {
            $match = [regex]::Match($PrBody, $pattern)
            if (-not $match.Success) { continue }

            $issue = 0
            if ([int]::TryParse($match.Groups['issue'].Value, [ref]$issue) -and $issue -gt 0) {
                return $issue
            }
        }
    }

    return $null
}

function script:Get-FCLCostScriptState {
    $state = @{}
    foreach ($costStateName in @(
            'CostWalkerSilentTypes',
            'CostAttributionPortMap',
            'CostCompletenessPartialReasons',
            'CostRendererPortOrder',
            'CostRendererSkillDrivenPorts',
            # C3 (issue #825 post-review fix): missing from this marshal list meant an
            # isolated runspace (New-FCLInitialSessionStateClone) never received this
            # constant — PowerShell coerces the unmarshaled $null to '', and
            # ''.StartsWith(anything) returns $true, misclassifying every real cwd as the
            # Copilot-OTEL sentinel and silently killing both Tier-1 identity discovery
            # and Tier-2 admission.
            'CostWalkerCopilotOtelCwdPrefix',
            # Issue #487 (post-render fix): same bug class as C3 above, third instance.
            # Defined at the top of this file, consumed by Invoke-CostSessionRender in
            # cost-session-render.ps1, which runs inside the worker clone — so without
            # marshaling it resolves to $null there. [regex]::Match(body, $null) does NOT
            # throw: it returns Success=True with an EMPTY match, so the
            # if ($sectionMatch.Success) guard passes, the captured section is '', and the
            # YAML-only fallback that would have preserved the data never fires. Net
            # effect: the re-emission preservation branch announced that it kept a prior
            # populated render while shipping a comment with the cost section destroyed.
            # Marshaled rather than re-dot-sourced in the worker (the issue #496 C-1
            # mechanism) because this file is function-heavy and defines
            # New-FCLInitialSessionStateClone itself, matching the C3 precedent above.
            'FCLCostPatternSectionRegex'
        )) {
        try {
            $state[$costStateName] = Get-Variable -Scope Script -Name $costStateName -ValueOnly -ErrorAction Stop
        }
        catch { $null = $_ }
    }

    return $state
}

function script:New-FCLInitialSessionStateClone {
    $iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault2()

    # Use function definitions directly so advanced-function metadata survives cloning.
    $parentFunctions = Get-ChildItem -Path Function:\ -ErrorAction SilentlyContinue
    foreach ($fn in $parentFunctions) {
        try {
            $entry = New-Object System.Management.Automation.Runspaces.SessionStateFunctionEntry($fn.Name, $fn.Definition)
            $iss.Commands.Add($entry)
        }
        catch { $null = $_ }
    }

    $autoNoneOptionsBlocklist = @('args', 'input', '_', '^', 'PWD', 'MyInvocation', 'PSCommandPath', 'PSScriptRoot', 'StackTrace', 'null')
    $parentGlobals = Get-Variable -Scope Global -ErrorAction SilentlyContinue
    foreach ($v in $parentGlobals) {
        if ($v.Options -band [System.Management.Automation.ScopedItemOptions]::Constant) { continue }
        if ($v.Options -band [System.Management.Automation.ScopedItemOptions]::ReadOnly) { continue }
        if ($v.Options -band [System.Management.Automation.ScopedItemOptions]::AllScope) { continue }
        if ($v.Options -band [System.Management.Automation.ScopedItemOptions]::Private) { continue }
        if ($autoNoneOptionsBlocklist -contains $v.Name) { continue }
        try {
            $entry = New-Object System.Management.Automation.Runspaces.SessionStateVariableEntry($v.Name, $v.Value, '')
            $iss.Variables.Add($entry)
        }
        catch { $null = $_ }
    }

    return $iss
}

function script:New-FCLCostWalkerResult {
    param(
        [AllowEmptyCollection()][object[]]$Events = @(),
        [bool]$TimedOut = $false,
        [bool]$Failed = $false,
        [AllowEmptyCollection()][string[]]$Warnings = @()
    )

    return [pscustomobject]@{
        Events   = @($Events)
        TimedOut = $TimedOut
        Failed   = $Failed
        Warnings = @($Warnings)
    }
}

function script:Invoke-FCLCostWalkerWithTimeout {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$WalkerName,
        [Parameter(Mandatory)][string]$CommandName,
        [Parameter(Mandatory)][hashtable]$Parameters,
        [Parameter(Mandatory)][int]$TimeoutSeconds
    )

    if ($TimeoutSeconds -le 0) {
        return (script:New-FCLCostWalkerResult -TimedOut $true)
    }

    if ($env:FRAME_CREDIT_LEDGER_TEST_WALKER_INLINE -eq '1') {
        try {
            $events = @(& $CommandName @Parameters)
            return (script:New-FCLCostWalkerResult -Events $events)
        }
        catch {
            [Console]::Error.WriteLine("frame-credit-ledger: cost $WalkerName walker failed: $($_.Exception.Message)")
            return (script:New-FCLCostWalkerResult -Failed $true)
        }
    }

    $runspace = $null
    $worker = $null
    try {
        $runspace = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace((script:New-FCLInitialSessionStateClone))
        $runspace.Open()
        $worker = [System.Management.Automation.PowerShell]::Create()
        $worker.Runspace = $runspace

        $costScriptState = script:Get-FCLCostScriptState
        $null = $worker.AddScript({
                param($CommandNameArg, $ParametersArg, $CostScriptStateArg)
                foreach ($costStateName in @($CostScriptStateArg.Keys)) {
                    Set-Variable -Scope Script -Name $costStateName -Value $CostScriptStateArg[$costStateName]
                }
                & $CommandNameArg @ParametersArg
            }).AddArgument($CommandName).AddArgument($Parameters).AddArgument($costScriptState)

        $async = $worker.BeginInvoke()
        $waited = $async.AsyncWaitHandle.WaitOne([int]($TimeoutSeconds * 1000))
        if (-not $waited) {
            try { $worker.Stop() } catch { $null = $_ }
            [Console]::Error.WriteLine("frame-credit-ledger: cost $WalkerName walker timed out after ${TimeoutSeconds}s; continuing with empty $WalkerName events")
            return (script:New-FCLCostWalkerResult -TimedOut $true)
        }

        $output = @()
        $failed = $false
        try { $output = @($worker.EndInvoke($async)) }
        catch {
            [Console]::Error.WriteLine("frame-credit-ledger: cost $WalkerName walker failed: $($_.Exception.Message)")
            $failed = $true
        }

        foreach ($errRecord in $worker.Streams.Error) {
            try { [Console]::Error.WriteLine([string]$errRecord) } catch { $null = $_ }
        }

        $warnings = @($worker.Streams.Warning | ForEach-Object { [string]$_ })
        return (script:New-FCLCostWalkerResult -Events $output -Failed $failed -Warnings $warnings)
    }
    catch {
        [Console]::Error.WriteLine("frame-credit-ledger: cost $WalkerName walker failed: $($_.Exception.Message)")
        return (script:New-FCLCostWalkerResult -Failed $true)
    }
    finally {
        if ($null -ne $worker) { $worker.Dispose() }
        if ($null -ne $runspace) { $runspace.Dispose() }
    }
}

function script:Resolve-FCLCostCopilotOtelJsonlPath {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$RepoRoot)

    if (-not [string]::IsNullOrWhiteSpace($env:FRAME_CREDIT_LEDGER_TEST_COPILOT_OTEL_JSONL)) {
        return [string]$env:FRAME_CREDIT_LEDGER_TEST_COPILOT_OTEL_JSONL
    }

    $settingsPath = Join-Path $RepoRoot '.vscode/settings.json'
    if (Test-Path -LiteralPath $settingsPath -PathType Leaf) {
        try {
            $settings = Get-Content -LiteralPath $settingsPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            $outfileProperty = $settings.PSObject.Properties['github.copilot.chat.otel.outfile']
            if ($null -ne $outfileProperty -and -not [string]::IsNullOrWhiteSpace([string]$outfileProperty.Value)) {
                $resolved = Resolve-CostCopilotOutfileTemplate -Template ([string]$outfileProperty.Value) -WorkspaceRoot $RepoRoot
                if ($null -ne $resolved -and -not [string]::IsNullOrWhiteSpace([string]$resolved.ResolvedPath)) {
                    return [string]$resolved.ResolvedPath
                }
            }
        }
        catch { $null = $_ }
    }

    $workspaceFolderBasename = Split-Path -Leaf $RepoRoot
    return (Join-Path ([Environment]::GetFolderPath('UserProfile')) ".copilot-otel/$workspaceFolderBasename/copilot.jsonl")
}

function script:Get-FCLCostWalkerTimeoutSeconds {
    param(
        [Parameter(Mandatory)][string]$EnvironmentVariableName,
        [Parameter(Mandatory)][int]$DefaultSeconds
    )

    $raw = [Environment]::GetEnvironmentVariable($EnvironmentVariableName, 'Process')
    $parsed = 0
    if (-not [string]::IsNullOrWhiteSpace($raw) -and [int]::TryParse($raw, [ref]$parsed) -and $parsed -gt 0) {
        return $parsed
    }

    return $DefaultSeconds
}

# Issue #794 s4 (sub-observation 4): detects the `frame-enforce.yml` CI landmine
# case (documented at that workflow's "Run frame credit enforce" step) where
# ~/.claude/projects — the Claude cost-transcript root Invoke-CostTranscriptWalk
# defaults to — does not exist on ubuntu-latest. This is the SAME root
# Invoke-CostTranscriptWalk resolves internally when no -ProjectsRoot is
# supplied (cost-walker.ps1 line ~374); we re-resolve it here rather than
# threading a new return value through the walker, so the walker's own
# multi-turn traversal logic (out of scope; re-homed to #491) is untouched.
# Test-only override mirrors the existing FRAME_CREDIT_LEDGER_TEST_* convention
# so Pester can simulate both the present-and-empty and absent-root cases
# deterministically without touching the real user profile.
function script:Test-FCLClaudeProjectsRootAbsent {
    $testOverride = [Environment]::GetEnvironmentVariable('FRAME_CREDIT_LEDGER_TEST_CLAUDE_PROJECTS_ROOT', 'Process')
    $projectsRoot = if (-not [string]::IsNullOrWhiteSpace($testOverride)) {
        $testOverride
    }
    else {
        Join-Path ([System.Environment]::GetFolderPath('UserProfile')) '.claude' 'projects'
    }

    return -not (Test-Path -LiteralPath $projectsRoot -PathType Container)
}

function script:Get-FCLCostEventProviderSet {
    param([AllowEmptyCollection()][object[]]$Events)

    $providers = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($evt in @($Events)) {
        if ($null -eq $evt) { continue }

        $provider = $null
        try { $provider = Get-EventProvider -Evt $evt }
        catch {
            if ($evt -is [System.Collections.IDictionary] -and $evt.ContainsKey('provider')) { $provider = $evt['provider'] }
            elseif ($null -ne $evt.PSObject.Properties['provider']) { $provider = $evt.provider }
        }

        if (-not [string]::IsNullOrWhiteSpace([string]$provider)) {
            $null = $providers.Add(([string]$provider).ToLowerInvariant())
        }
    }

    $ordered = [System.Collections.Generic.List[string]]::new()
    foreach ($candidate in @('claude', 'copilot')) {
        if ($providers.Contains($candidate)) { $ordered.Add($candidate) }
    }
    foreach ($provider in $providers) {
        if (-not $ordered.Contains($provider)) { $ordered.Add($provider) }
    }

    return [string[]]$ordered.ToArray()
}

function script:Get-FCLCostUnmappedSessionCount {
    param([AllowEmptyCollection()][string[]]$Warnings)

    $total = 0
    foreach ($warning in @($Warnings)) {
        $match = [regex]::Match([string]$warning, 'unmapped_session_count=(?<count>\d+)')
        if ($match.Success) { $total += [int]$match.Groups['count'].Value }
    }

    return $total
}

function script:Get-FCLCostMetadataValue {
    param(
        [AllowNull()][object]$Entry,
        [Parameter(Mandatory)][string]$Name
    )

    if ($null -eq $Entry) { return $null }
    if ($Entry -is [System.Collections.IDictionary]) { return $Entry[$Name] }
    $property = $Entry.PSObject.Properties[$Name]
    if ($null -ne $property) { return $property.Value }
    return $null
}

function script:Get-FCLEffectiveCostCoverageClass {
    param([AllowNull()][object]$Entry)

    $installStatus = script:Get-FCLCostMetadataValue -Entry $Entry -Name 'install_status'
    if ([string]$installStatus -eq 'missing-or-fallback') { return 'claude-only' }

    $coverage = script:Get-FCLCostMetadataValue -Entry $Entry -Name 'coverage'
    if (-not [string]::IsNullOrWhiteSpace([string]$coverage)) { return [string]$coverage }

    return 'claude-only'
}

function script:Set-FCLRollingMetaCoverageCount {
    param(
        [Parameter(Mandatory)][hashtable]$RollingResult,
        [Parameter(Mandatory)][hashtable]$Attribution
    )

    if ($RollingResult['timed_out'] -eq $true) { return }

    $currentCoverage = script:Get-FCLEffectiveCostCoverageClass -Entry $Attribution
    $matchingCount = 0
    foreach ($entry in @($RollingResult['entries'])) {
        if ((script:Get-FCLEffectiveCostCoverageClass -Entry $entry) -eq $currentCoverage) {
            $matchingCount++
        }
    }

    $RollingResult['matching_coverage_history_count'] = $matchingCount
}

function script:Set-FCLCostCoverageMetadata {
    param(
        [Parameter(Mandatory)][hashtable]$Attribution,
        [AllowEmptyCollection()][object[]]$Events,
        [AllowNull()]$ClaudeWalk,
        [AllowNull()]$CopilotWalk,
        [Parameter(Mandatory)][AllowEmptyString()][string]$CopilotOtelJsonlPath
    )

    [string[]]$providers = @(script:Get-FCLCostEventProviderSet -Events $Events)
    $hasClaude = $providers -contains 'claude'
    $hasCopilot = $providers -contains 'copilot'
    $copilotWarnings = if ($null -ne $CopilotWalk) { @($CopilotWalk.Warnings) } else { @() }
    $unmappedSessionCount = script:Get-FCLCostUnmappedSessionCount -Warnings $copilotWarnings
    $copilotTimedOut = ($null -ne $CopilotWalk -and $CopilotWalk.TimedOut -eq $true)
    $copilotFailed = ($null -ne $CopilotWalk -and $CopilotWalk.Failed -eq $true)
    # Issue #794 s4 (sub-observation 4): the #790 recurrence was specifically a
    # CLAUDE walker timeout — read Claude's own TimedOut/Failed flags too, not
    # only Copilot's, so degraded_reason below can be derived from EITHER walker.
    $claudeTimedOut = ($null -ne $ClaudeWalk -and $ClaudeWalk.TimedOut -eq $true)
    $claudeFailed = ($null -ne $ClaudeWalk -and $ClaudeWalk.Failed -eq $true)

    $installStatus = 'ok'
    if ([string]::IsNullOrWhiteSpace($CopilotOtelJsonlPath) -or -not (Test-Path -LiteralPath $CopilotOtelJsonlPath -PathType Leaf)) {
        $installStatus = 'missing-or-fallback'
    }

    $coverage = 'claude-only'
    if ($hasClaude -and $hasCopilot) { $coverage = 'claude+copilot' }
    elseif ($hasCopilot) { $coverage = 'copilot-only' }
    elseif ($hasClaude -and ($copilotTimedOut -or $copilotFailed -or $unmappedSessionCount -gt 0 -or $installStatus -eq 'missing-or-fallback')) { $coverage = 'claude-only-with-copilot-fallback-warning' }

    if ($providers.Count -eq 0) { $providers = @('claude') }

    # Issue #794 s4: typed degraded_reason, populated ONLY when coverage is
    # actually degraded (no events attributed at all). Priority order:
    #   1. env-absent          — the CI landmine (root literally absent); this
    #                            is expected/routine, not a genuine anomaly.
    #   2. budget-exceeded     — either walker genuinely timed out.
    #   3. no-transcript-found — root exists, walk completed, found nothing.
    $degradedReason = $null
    if ($Events.Count -eq 0) {
        if (script:Test-FCLClaudeProjectsRootAbsent) {
            $degradedReason = 'env-absent'
        }
        elseif ($claudeTimedOut -or $copilotTimedOut) {
            $degradedReason = 'budget-exceeded'
        }
        elseif ($claudeFailed -or $copilotFailed) {
            $degradedReason = 'budget-exceeded'
        }
        else {
            $degradedReason = 'no-transcript-found'
        }
    }

    $Attribution['coverage'] = $coverage
    $Attribution['install_status'] = $installStatus
    $Attribution['unmapped_session_count'] = $unmappedSessionCount
    $Attribution['provider_support'] = [string[]]$providers
    $Attribution['degraded_reason'] = $degradedReason
}

# Issue #794 s4 (Part 2 / AC6): composes a schema-valid degraded-honest
# cost-pattern-data comment for orchestrated-origin PRs where the walker
# genuinely found no telemetry. Reuses the existing 'claude-only' coverage
# value (the value Set-FCLCostCoverageMetadata already assigns for a fully
# empty walk) rather than inventing a new enum member — see
# lib/cost-pattern-data-schema.md `coverage` field for the authoritative enum.
function script:Compose-FCLDegradedCostComment {
    param(
        [Parameter(Mandatory)][string]$DegradedReason,
        [Parameter(Mandatory)][int]$Pr,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Branch
    )

    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    $generatedAt = [System.DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ', $inv)

    # Distinct discovery marker (own hidden comment line) so Find-OrUpsertComment's
    # substring lookup identifies THIS standalone degraded comment across re-runs
    # without colliding with the bare '<!-- cost-pattern-data' substring that is
    # always embedded inside the main frame-credit-ledger-{Pr} comment (Format-
    # CostPatternYaml unconditionally emits that literal, even for empty walks).
    # Kept on its own line (not appended to the YAML open tag) because
    # Get-CostPatternDataFromComment's extraction regex requires a newline
    # directly after 'cost-pattern-data' with nothing else on that line.
    $discoveryMarker = "<!-- cost-pattern-data-degraded-$Pr -->"

    $markdown = @(
        '## Cost Pattern',
        '',
        "coverage: claude-only",
        "⚠ degraded telemetry: $DegradedReason — no cost events were attributed to this PR."
    ) -join "`n"

    $yaml = @(
        '<!-- cost-pattern-data',
        'version: 1',
        'coverage: claude-only',
        'session_completeness: unknown',
        'excluded_from_rolling_baseline: true',
        "degraded_reason: $DegradedReason",
        "generated_at: $generatedAt",
        'phase_scope: branch-session-only',
        "pr: $Pr",
        "branch: $Branch",
        '-->'
    ) -join "`n"

    return $discoveryMarker + "`n`n" + $markdown + "`n`n" + $yaml
}

function script:Get-FCLRemainingCostBudgetSeconds {
    param(
        [Parameter(Mandatory)][System.Diagnostics.Stopwatch]$Stopwatch,
        [Parameter(Mandatory)][int]$BudgetSeconds
    )

    $remaining = $BudgetSeconds - [int][Math]::Ceiling($Stopwatch.Elapsed.TotalSeconds)
    if ($remaining -lt 0) { return 0 }
    return $remaining
}

# Sum the four token-count keys (input + output + cache_creation + cache_read)
# from a single token bucket. Used by both the current-ports-fallback path and
# the prior-side path (issue #777, R2). The internal $null check subsumes the
# per-loop bucket null-guard (present key, null value).
function script:Get-FCLTokenSumFromBucket {
    param([hashtable]$Bucket)
    [long]$sum = 0
    if ($null -eq $Bucket) { return $sum }
    foreach ($tk in @('input', 'output', 'cache_creation', 'cache_read')) {
        if ($Bucket.ContainsKey($tk) -and $null -ne $Bucket[$tk]) {
            $sum += [long]$Bucket[$tk]
        }
    }
    return $sum
}

# Predicate for issue #824 DD7's recurrence guard: warns when the current
# capture is baseline-ineligible AND the rolling history is healthy (fetched,
# non-empty, not timed out, not a partial fetch) AND every entry in that
# history is also excluded — i.e. no recent capture has been eligible, which
# is a signal distinct from cold start (empty history) or a degraded fetch.
function script:Test-FCLRecurrenceGuardShouldWarn {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][bool]$CurrentExcluded,
        [hashtable]$RollingResult = $null
    )

    if (-not $CurrentExcluded) { return $false }
    if ($null -eq $RollingResult) { return $false }
    if ($RollingResult['timed_out'] -eq $true) { return $false }
    if ($RollingResult.ContainsKey('partial_fetch') -and $RollingResult['partial_fetch'] -eq $true) { return $false }

    $entries = @($RollingResult['entries'])
    if ($entries.Count -eq 0) { return $false }

    foreach ($entry in $entries) {
        if ($null -eq $entry) { continue }
        if ($entry['excluded_from_rolling_baseline'] -eq $false) {
            return $false
        }
    }

    return $true
}

# ===========================================================================
# Set-FCLPrBodyCostSummary / Update-FCLPrBodyCostSummary (issue #489 s3 —
# AC1's forward-compat half, AC2's transform half, AC5's body half).
#
# Stamps a `cost_summary` additive v4 field into a PR body's hidden
# pipeline-metrics YAML block, plus a visible one-line dollar headline
# wrapped in <!-- cost-summary:begin/end --> sentinels immediately before
# that block. Two functions, matching this repo's file-local precedent that
# splits a pure text transform from its effectful writer
# (script:Update-FCLPrBodyStaleSpineFallbackMetric vs
# script:Update-FCLPrBodyMetricsBestEffort, frame-credit-ledger.ps1:808/822):
#
#   (a) Set-FCLPrBodyCostSummary    — PURE. Body-text in, body-text out.
#   (b) Update-FCLPrBodyCostSummary — writes via `gh pr edit --body-file`,
#                                     fail-open (warn to stderr, never throw).
#
# All constants (regexes, sentinel strings) are LOCAL to these two function
# bodies by design — never new top-level $script: constants. This call site
# runs inside the pipeline hook's outer worker-runspace clone
# (frame-credit-ledger.ps1:1487-1525), which copies function definitions and
# global variables but never re-runs a file's top-level dot-sources. A new
# top-level $script: constant would silently marshal as $null there (shipped
# twice: #825 C3, #487).
# ===========================================================================
function script:Set-FCLPrBodyCostSummary {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$PrBody,
        [Parameter(Mandatory)][bool]$Degraded,
        [AllowNull()][hashtable]$CostSummary = $null
    )

    if ([string]::IsNullOrEmpty($PrBody)) { return $PrBody }

    # ---- EOL detection/normalization (whole body). ----
    $eol = if ($PrBody.Contains("`r`n")) { "`r`n" } else { "`n" }
    $normalizedBody = $PrBody -replace "`r`n", "`n" -replace "`r", "`n"

    # ---- Fence-aware marker lookup: redact ```-fenced regions to a
    # same-length filler (so byte offsets stay aligned with $normalizedBody)
    # before searching for the pipeline-metrics marker, exactly as
    # Test-PipelineMetricsV4Block does (frame-credit-ledger-core.ps1:3176) —
    # a naive first-match regex would instead splice into a fenced
    # documentation example. ----
    $fencePattern = '(?s)```.*?```'
    $markerPattern = '(?s)(?<open><!--\s*pipeline-metrics\s*)(?<block>.*?)(?<close>\s*-->)'
    $redactFences = {
        param([string]$Text, [string]$Pattern)
        return [regex]::Replace($Text, $Pattern, { param($m) [string]::new('x', $m.Value.Length) })
    }

    $redacted = & $redactFences $normalizedBody $fencePattern
    $markerMatch = [regex]::Match($redacted, $markerPattern)
    if (-not $markerMatch.Success) {
        # No real (non-fenced) pipeline-metrics block to anchor against.
        # Fail open as a no-op — the writer's no-op guard skips the write.
        return $PrBody
    }

    $blockGroup = $markerMatch.Groups['block']
    $blockText = $normalizedBody.Substring($blockGroup.Index, $blockGroup.Length)
    $blockLines = @($blockText -split "`n")

    # ---- Local helper: bounds of a top-level (column-0) key's subtree.
    # Blank and '#'-comment lines are continuation, not a terminator — the
    # subtree ends at the next column-0, non-blank, non-comment line.
    # Matches this codebase's one consistent precedent (Get-FCLEntryChunks
    # :351-354 guards blanks before its break check; Get-FCLNestedScalar
    # :73-75 and Test-FCLYamlSane agree). ----
    $findTopLevelKeySubtreeBounds = {
        param([string[]]$Lines, [string]$KeyName)
        $keyPattern = '^' + [regex]::Escape($KeyName) + '\s*:\s*$'
        for ($i = 0; $i -lt $Lines.Count; $i++) {
            if ($Lines[$i] -notmatch $keyPattern) { continue }
            $end = $Lines.Count
            for ($j = $i + 1; $j -lt $Lines.Count; $j++) {
                $line = $Lines[$j]
                if ([string]::IsNullOrWhiteSpace($line)) { continue }
                $trimmed = $line.TrimStart()
                if ($trimmed.StartsWith('#')) { continue }
                if (($line.Length - $trimmed.Length) -eq 0) { $end = $j; break }
            }
            return @{ Start = $i; End = $end }
        }
        return $null
    }

    $existingBounds = & $findTopLevelKeySubtreeBounds $blockLines 'cost_summary'

    # ---- Degraded decision table (complete over prior-summary-state x degraded):
    #   degraded + no prior cost_summary -> honest degraded write (fall through)
    #   degraded + prior summary (real OR already-degraded) -> no-op, untouched
    #   not degraded -> always write normally (fall through) ----
    if ($Degraded -and $null -ne $existingBounds) {
        return $PrBody
    }

    # ---- Compose the new cost_summary YAML subtree lines. ----
    $newSubtreeLines = [System.Collections.Generic.List[string]]::new()
    $newSubtreeLines.Add('cost_summary:')

    $costUsdTotal = 0.0
    $sessionCompleteness = ''
    $capturePoint = ''
    $sourceComment = ''

    if ($Degraded) {
        $capturePoint = 'unavailable'
        $newSubtreeLines.Add('  capture_point: ' + (script:Escape-FCLScalar -Value $capturePoint))
    }
    else {
        $summary = if ($null -ne $CostSummary) { $CostSummary } else { @{} }

        if ($summary.ContainsKey('cost_usd_total') -and $null -ne $summary['cost_usd_total']) {
            $costUsdTotal = [double]$summary['cost_usd_total']
        }

        $tokens = if ($summary.ContainsKey('tokens') -and $summary['tokens'] -is [hashtable]) { $summary['tokens'] } else { @{} }
        $inv = [System.Globalization.CultureInfo]::InvariantCulture
        $tokenNames = @('input', 'output', 'cache_creation', 'cache_read')
        $tokenValues = @{}
        foreach ($tk in $tokenNames) {
            $v = 0L
            if ($tokens.ContainsKey($tk) -and $null -ne $tokens[$tk]) { $v = [long]$tokens[$tk] }
            $tokenValues[$tk] = $v
        }

        if ($summary.ContainsKey('session_completeness') -and $null -ne $summary['session_completeness']) {
            $sessionCompleteness = [string]$summary['session_completeness']
        }
        if ($summary.ContainsKey('capture_point') -and $null -ne $summary['capture_point']) {
            $capturePoint = [string]$summary['capture_point']
        }
        if ($summary.ContainsKey('source_comment') -and $null -ne $summary['source_comment']) {
            $sourceComment = [string]$summary['source_comment']
        }

        $newSubtreeLines.Add('  cost_usd_total: ' + (script:Escape-FCLScalar -Value (script:Format-CostYaml -Value $costUsdTotal)))
        $newSubtreeLines.Add('  tokens:')
        foreach ($tk in $tokenNames) {
            $newSubtreeLines.Add('    ' + $tk + ': ' + (script:Escape-FCLScalar -Value ($tokenValues[$tk]).ToString($inv)))
        }
        $newSubtreeLines.Add('  session_completeness: ' + (script:Escape-FCLScalar -Value $sessionCompleteness))
        $newSubtreeLines.Add('  capture_point: ' + (script:Escape-FCLScalar -Value $capturePoint))
        if (-not [string]::IsNullOrWhiteSpace($sourceComment)) {
            $newSubtreeLines.Add('  source_comment: ' + (script:Escape-FCLScalar -Value $sourceComment))
        }
    }

    # ---- Remove the existing cost_summary subtree (full subtree replace). ----
    if ($null -ne $existingBounds) {
        $keep = [System.Collections.Generic.List[string]]::new()
        for ($i = 0; $i -lt $blockLines.Count; $i++) {
            if ($i -ge $existingBounds.Start -and $i -lt $existingBounds.End) { continue }
            $keep.Add($blockLines[$i])
        }
        $blockLines = $keep.ToArray()
    }

    # ---- Insertion anchor: after any list section (dispatch-cost-samples:
    # then credits:, in that preference order since dispatch-cost-samples
    # always renders after credits when both are present); append at the end
    # of the block when neither list section exists. An indent-0 key placed
    # here correctly terminates Get-FCLEntryChunks's list scan; nested
    # children placed before that terminator would be silently consumed as
    # fields of the last credit entry. ----
    $insertIdx = $blockLines.Count
    $dcsBounds = & $findTopLevelKeySubtreeBounds $blockLines 'dispatch-cost-samples'
    if ($null -ne $dcsBounds) {
        $insertIdx = $dcsBounds.End
    }
    else {
        $creditsBounds = & $findTopLevelKeySubtreeBounds $blockLines 'credits'
        if ($null -ne $creditsBounds) { $insertIdx = $creditsBounds.End }
    }

    $newBlockLines = [System.Collections.Generic.List[string]]::new()
    for ($i = 0; $i -lt $insertIdx; $i++) { $newBlockLines.Add($blockLines[$i]) }
    foreach ($l in $newSubtreeLines) { $newBlockLines.Add($l) }
    for ($i = $insertIdx; $i -lt $blockLines.Count; $i++) { $newBlockLines.Add($blockLines[$i]) }

    $newBlockText = ($newBlockLines.ToArray() -join "`n")

    $prefix = $normalizedBody.Substring(0, $blockGroup.Index)
    $suffixStart = $blockGroup.Index + $blockGroup.Length
    $suffix = $normalizedBody.Substring($suffixStart)
    $bodyWithUpdatedBlock = $prefix + $newBlockText + $suffix

    # ---- Compose the visible sentinel-wrapped line. ASCII hyphen only —
    # this text round-trips through gh pr view/edit repeatedly and non-ASCII
    # separators mangle on Windows. ----
    if ($Degraded) {
        $visibleLine = '**Session cost**: unavailable (attribution degraded)'
    }
    else {
        $costMarkdown = script:Format-Cost -Value $costUsdTotal
        $visibleLine = "**Session cost**: $costMarkdown ($sessionCompleteness, $capturePoint)"
        if (-not [string]::IsNullOrWhiteSpace($sourceComment)) {
            $visibleLine += " - [full breakdown]($sourceComment)"
        }
    }

    # ---- Sentinel pathology repair + re-anchor: delegate to a dedicated
    # helper — matching/removing stale begin/end spans (including the
    # non-obvious asymmetric orphan handling) and re-anchoring the fresh span
    # against the fence-aware marker is one cohesive responsibility, and is
    # sizable enough on its own to deserve a name rather than living inline
    # in this already-long transform. See
    # script:Repair-FCLCostSummarySentinelSpan for the full rationale. ----
    $finalNormalized = script:Repair-FCLCostSummarySentinelSpan `
        -Body $bodyWithUpdatedBlock `
        -VisibleLine $visibleLine `
        -RedactFences $redactFences `
        -FencePattern $fencePattern `
        -MarkerPattern $markerPattern

    # ---- Restore the body's original EOL convention. ----
    return ($finalNormalized -replace "`n", $eol)
}

# Strips every well-formed <!-- cost-summary:begin/end --> pair (handles
# duplicated pairs) plus any orphan begin-without-end or end-before-begin
# marker line, anywhere in $Body, then splices in exactly one fresh canonical
# span (begin / $VisibleLine / end) immediately before the (fence-aware)
# pipeline-metrics marker — outside the trailing HTML comment, so it always
# renders. The hidden YAML section is authoritative — the visible span is
# always regenerated from it, never merged with stale visible text.
#
# Orphan handling is intentionally asymmetric and bounded: this writer's own
# span is always exactly 3 lines (begin, one content line, end), so an orphan
# BEGIN with no end anywhere in the document most plausibly means the
# terminating end was lost mid-write — the single line right after the begin
# is presumed to be that lost span's stale content and is removed too. An
# orphan END has no such reliable direction to look (any content that
# belonged to it may already be gone, and the line immediately before it may
# be unrelated prose), so only the marker line itself is removed for that
# case.
#
# $RedactFences/$FencePattern/$MarkerPattern are threaded in from the caller
# rather than redefined here so the fence/marker regex text has exactly one
# source of truth across both the block-location step and this repair step.
function script:Repair-FCLCostSummarySentinelSpan {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Body,
        [Parameter(Mandatory)][string]$VisibleLine,
        [Parameter(Mandatory)][scriptblock]$RedactFences,
        [Parameter(Mandatory)][string]$FencePattern,
        [Parameter(Mandatory)][string]$MarkerPattern
    )

    $lines = @($Body -split "`n")
    $beginPattern = '^\s*<!--\s*cost-summary:begin\s*-->\s*$'
    $endPattern = '^\s*<!--\s*cost-summary:end\s*-->\s*$'
    $toRemove = [System.Collections.Generic.HashSet[int]]::new()
    $openStack = [System.Collections.Generic.List[int]]::new()
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match $beginPattern) {
            $openStack.Add($i)
        }
        elseif ($lines[$i] -match $endPattern) {
            if ($openStack.Count -gt 0) {
                $beginIdx = $openStack[$openStack.Count - 1]
                $openStack.RemoveAt($openStack.Count - 1)
                for ($k = $beginIdx; $k -le $i; $k++) { [void]$toRemove.Add($k) }
            }
            else {
                [void]$toRemove.Add($i)
            }
        }
    }
    foreach ($idx in $openStack) {
        [void]$toRemove.Add($idx)
        $nextIdx = $idx + 1
        if ($nextIdx -lt $lines.Count -and -not [string]::IsNullOrWhiteSpace($lines[$nextIdx])) {
            [void]$toRemove.Add($nextIdx)
        }
    }

    $cleanedLines = [System.Collections.Generic.List[string]]::new()
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($toRemove.Contains($i)) { continue }
        $cleanedLines.Add($lines[$i])
    }
    $cleanedBody = ($cleanedLines.ToArray() -join "`n")

    $redactedCleaned = & $RedactFences $cleanedBody $FencePattern
    $anchorMatch = [regex]::Match($redactedCleaned, $MarkerPattern)
    if (-not $anchorMatch.Success) {
        # Should not happen — the block was just written by the caller. Fail
        # open: keep the block update, skip the visible-span insert.
        return $cleanedBody
    }

    $before = $cleanedBody.Substring(0, $anchorMatch.Index).TrimEnd("`n")
    $after = $cleanedBody.Substring($anchorMatch.Index)
    $spanText = @('<!-- cost-summary:begin -->', $VisibleLine, '<!-- cost-summary:end -->') -join "`n"
    if ([string]::IsNullOrEmpty($before)) {
        return $spanText + "`n`n" + $after
    }
    return $before + "`n`n" + $spanText + "`n`n" + $after
}

function script:Update-FCLPrBodyCostSummary {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int]$Pr,
        [Parameter(Mandatory)][AllowEmptyString()][string]$PrBody,
        [Parameter(Mandatory)][bool]$Degraded,
        [AllowNull()][hashtable]$CostSummary = $null
    )

    $updatedBody = $PrBody
    try {
        $updatedBody = script:Set-FCLPrBodyCostSummary -PrBody $PrBody -Degraded $Degraded -CostSummary $CostSummary
    }
    catch {
        [Console]::Error.WriteLine("frame-credit-ledger: cost-summary transform failed: $($_.Exception.Message)")
        return
    }

    if ($updatedBody -eq $PrBody) {
        # No-op guard (issue #489 AC2/AC5): a true fixed point closes the
        # encoding/EOL churn window and shrinks the concurrent-overwrite
        # exposure on every unchanged re-run.
        return
    }

    $tempPath = Join-Path ([System.IO.Path]::GetTempPath()) ("frame-credit-ledger-cost-summary-$Pr-$([System.Guid]::NewGuid().ToString('N')).md")
    try {
        $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
        [System.IO.File]::WriteAllText($tempPath, $updatedBody, $utf8NoBom)
        $null = & gh pr edit $Pr --body-file $tempPath 2>$null
        if ($global:LASTEXITCODE -ne 0) {
            [Console]::Error.WriteLine("frame-credit-ledger: PR body cost-summary update failed via gh pr edit --body-file")
        }
    }
    catch {
        [Console]::Error.WriteLine("frame-credit-ledger: PR body cost-summary update failed: $($_.Exception.Message)")
    }
    finally {
        try {
            if (Test-Path -LiteralPath $tempPath -PathType Leaf) {
                Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
            }
        }
        catch {
            [Console]::Error.WriteLine("frame-credit-ledger: temporary PR body cost-summary file cleanup failed: $($_.Exception.Message)")
        }
    }
}
