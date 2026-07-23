#Requires -Version 7.0
<#
.SYNOPSIS
    Goal-run worktree lifecycle primitives -- provisioner, active-state file,
    and teardown (issue #874, plan step 2, AC3 provisioning + teardown half).
    Also carries Invoke-GoalRunDeferredTeardownRetry (plan step 3), the
    standalone deferred-teardown-retry entry point session-cleanup-detector-
    core.ps1 renders a call to and a future /goal-run agent body can call
    directly.
.DESCRIPTION
    Standalone and independently testable: no cleanup-detector integration
    lives here beyond the one standalone retry entry point noted above (the
    exclusion/reporting/aging-nudge logic itself lives in
    session-cleanup-detector-core.ps1, plan step 3). What ships here:

      New-GoalRunWorktree -RepoRoot <string> -IssueNumber <int>
                           [-WorktreeRoot <string>] [-GitCliPath <string>]
        Provisioner. Modeled on New-GCDisposableWorktree's discipline
        (.github/scripts/lib/goal-contract-validate-core.ps1:972) -- clean-
        tree refusal first, structured [pscustomobject] return, `| Out-Null`
        stdout discipline -- but this is NOT a parameterization of that
        function (which detaches HEAD into a temp dir with no branch). This
        creates a NAMED branch `goal-run/issue-{N}-{token}` at a configurable
        short root outside the checkout (default `{repo-parent}/gr-{issue}-
        {token}`) and sets `core.longpaths` at `worktree add`. `{token}` is a
        GUID-style collision-proof suffix (mirrors New-GCDisposableWorktree's
        `[Guid]::NewGuid().ToString('N')` precedent) so two concurrent runs
        for the same issue never collide on branch name or directory.

      New-GoalRunActiveState -WorktreePath <string> -Ceilings <obj>
                              -Baseline <obj> -Arm <string>
                              -ExecutorSessionId <string> -ContractHash <string>
        Writes `goal-run-active.json` at the worktree root: ceilings,
        baseline, arm, executor session id, launch-pinned contract_hash,
        launch timestamp (`launched_at`), a heartbeat timestamp
        (`heartbeat_at`, seeded equal to `launched_at`), and
        `teardown_deferred` (bool, default false).

      Get-GoalRunActiveState -WorktreePath <string>
        Reads `goal-run-active.json` back. Returns $null when the file does
        not exist (never throws on a missing file).

      Update-GoalRunActiveStateHeartbeat -WorktreePath <string>
        Updates `heartbeat_at` to the current UTC timestamp and persists it.
        This is the read/write/update primitive the requirement contract
        calls for -- the actual "update at each chain-stage boundary" call
        sites are later #874 scope (live-vs-crashed discrimination, the s3
        detector-exclusion gate).

      Set-GoalRunActiveStateTeardownDeferred -WorktreePath <string> -Value <bool>
        Updates `teardown_deferred` and persists it. Used internally by
        Remove-GoalRunWorktree on retry exhaustion; also directly testable.

      Remove-GoalRunWorktree -RepoRoot <string> -WorktreePath <string>
                              [-GitCliPath <string>] [-RetryDelayMs <int>]
                              [-MaxAttempts <int>]
        Teardown for every exit path. Bounded retry + backoff on `git
        worktree remove` failure, reusing the retry pattern from
        Remove-GCDisposableWorktree (goal-contract-validate-core.ps1:1032,
        same `-RetryDelayMs` naming). On exhausting retries, defers and
        flags: sets `teardown_deferred: true` on the state file (best-effort;
        never throws) -- a durable "note on the run's terminal comment"
        happens in a later step once the halt-comment machinery has a live
        call-site, not here. After every removal attempt, the actual
        post-attempt state is diagnosed honestly through the SAME six-value
        outcome vocabulary as
        skills/session-startup/scripts/session-startup-git-helpers.ps1's
        Get-WorktreeRemovalOutcome -- 'removed', 'removed-partial-root-held',
        'removed-partial-content-remains', 'stale-registration', 'failed',
        'verification-indeterminate' -- so a later step-3 detector
        integration can consume the same literal strings. This file does
        NOT dot-source that git-helpers file (keeping this lib self-
        contained and independently testable); the diagnosis logic here is a
        deliberate parallel implementation over the same vocabulary, not a
        shared call. Never force-removes a locked worktree on the porcelain
        'locked' flag alone -- only when the directory is confirmed absent
        via Test-Path (mirrors the corrected #522 clause in
        skills/session-startup/scripts/post-merge-cleanup.ps1: real git
        never sets the 'prunable' porcelain marker on a locked worktree, so
        the gate keys on Test-Path-verified absence, not on 'prunable').
        Returns [pscustomobject]@{ Outcome; TeardownDeferred; Attempts;
        WorktreePath }. Never throws.
#>

$script:GoalRunActiveStateFileName = 'goal-run-active.json'

# ---------------------------------------------------------------------------
# State-file primitives
# ---------------------------------------------------------------------------

function script:Save-GoalRunActiveState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$StatePath,
        [Parameter(Mandatory)]$State
    )

    # Explicit -Depth: the ConvertTo-Json default of 2 would silently flatten
    # nested ceilings/baseline objects, mirroring the same rationale already
    # documented at goal-run-halt-core.ps1's Test-GoalRunHaltReport.
    $json = $State | ConvertTo-Json -Depth 20
    Set-Content -LiteralPath $StatePath -Value $json -Encoding utf8 -NoNewline
}

function New-GoalRunActiveState {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$WorktreePath,
        [Parameter(Mandatory)]$Ceilings,
        [Parameter(Mandatory)]$Baseline,
        [Parameter(Mandatory)][string]$Arm,
        [Parameter(Mandatory)][string]$ExecutorSessionId,
        [Parameter(Mandatory)][string]$ContractHash
    )

    $now = (Get-Date).ToUniversalTime().ToString('o')
    $state = [ordered]@{
        ceilings            = $Ceilings
        baseline            = $Baseline
        arm                 = $Arm
        executor_session_id = $ExecutorSessionId
        contract_hash       = $ContractHash
        launched_at         = $now
        heartbeat_at        = $now
        teardown_deferred   = $false
    }

    $statePath = Join-Path $WorktreePath $script:GoalRunActiveStateFileName
    script:Save-GoalRunActiveState -StatePath $statePath -State $state

    return [pscustomobject]@{ Path = $statePath; State = [pscustomobject]$state }
}

function Get-GoalRunActiveState {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$WorktreePath
    )

    $statePath = Join-Path $WorktreePath $script:GoalRunActiveStateFileName
    if (-not (Test-Path -LiteralPath $statePath)) {
        return $null
    }

    $raw = Get-Content -LiteralPath $statePath -Raw
    # -DateKind String: ConvertFrom-Json otherwise auto-coerces any
    # ISO-8601-shaped string (launched_at/heartbeat_at) into a [datetime]
    # object, silently changing the field's type on every read and breaking
    # equality against the plain string this lib always writes.
    return ($raw | ConvertFrom-Json -DateKind String)
}

function Update-GoalRunActiveStateHeartbeat {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$WorktreePath
    )

    $statePath = Join-Path $WorktreePath $script:GoalRunActiveStateFileName
    $state = Get-GoalRunActiveState -WorktreePath $WorktreePath
    if ($null -eq $state) {
        throw "Update-GoalRunActiveStateHeartbeat: no state file found at $statePath"
    }

    $state.heartbeat_at = (Get-Date).ToUniversalTime().ToString('o')
    script:Save-GoalRunActiveState -StatePath $statePath -State $state
    return $state
}

function Set-GoalRunActiveStateTeardownDeferred {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$WorktreePath,
        [Parameter(Mandatory)][bool]$Value
    )

    $statePath = Join-Path $WorktreePath $script:GoalRunActiveStateFileName
    $state = Get-GoalRunActiveState -WorktreePath $WorktreePath
    if ($null -eq $state) {
        throw "Set-GoalRunActiveStateTeardownDeferred: no state file found at $statePath"
    }

    $state.teardown_deferred = $Value
    script:Save-GoalRunActiveState -StatePath $statePath -State $state
    return $state
}

# ---------------------------------------------------------------------------
# Provisioner
# ---------------------------------------------------------------------------

# Private: clean-tree refusal check. Duplicated (not dot-sourced) from
# Test-GCTreeClean's fail-closed shape rather than importing
# goal-contract-validate-core.ps1 wholesale -- that file is a large,
# unrelated contract-validation surface, and this lib is meant to stay
# standalone/independently testable per the requirement contract's
# non-goals. Same fail-closed discipline: a failed `git status --porcelain`
# invocation is treated as NOT clean, never as an empty-output false "clean".
function script:Test-GoalRunTreeClean {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory = $false)][string]$GitCliPath = 'git'
    )

    $porcelain = & $GitCliPath -C $Path status --porcelain 2>$null
    if ($LASTEXITCODE -ne 0) {
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

function New-GoalRunWorktree {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][int]$IssueNumber,
        [Parameter(Mandatory = $false)][string]$WorktreeRoot,
        [Parameter(Mandatory = $false)][string]$GitCliPath = 'git'
    )

    # Clean-tree refusal FIRST -- before any worktree exists (mirrors
    # New-GCDisposableWorktree's AC2 ordering).
    $cleanliness = script:Test-GoalRunTreeClean -Path $RepoRoot -GitCliPath $GitCliPath
    if (-not $cleanliness.IsClean) {
        return [pscustomobject]@{
            Success       = $false
            RefusalReason = 'refused: uncommitted-changes'
            Path          = $null
            BranchName    = $null
        }
    }

    if ([string]::IsNullOrWhiteSpace($WorktreeRoot)) {
        $WorktreeRoot = Split-Path -Parent $RepoRoot
    }

    # GUID-suffixed unique token -- collision is structurally impossible,
    # mirroring New-GCDisposableWorktree's `[Guid]::NewGuid().ToString('N')`
    # precedent, so two concurrent goal-run provisions for the same issue
    # never collide on branch name or directory.
    $token = [Guid]::NewGuid().ToString('N')
    $branchName = "goal-run/issue-$IssueNumber-$token"
    $worktreePath = Join-Path $WorktreeRoot "gr-$IssueNumber-$token"

    # R18-equivalent stdout discipline: native `git worktree add` stdout is
    # discarded via Out-Null, not just stderr, since this function's return
    # value is structurally consumed by callers.
    & $GitCliPath -C $RepoRoot worktree add -b $branchName $worktreePath 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) {
        return [pscustomobject]@{
            Success       = $false
            RefusalReason = 'refused: worktree-create-failed'
            Path          = $null
            BranchName    = $null
        }
    }

    # Long-path support for Windows checkouts. Best-effort/non-fatal: a
    # failure here does not roll back an otherwise-successful provision.
    & $GitCliPath -C $worktreePath config core.longpaths true 2>$null | Out-Null

    return [pscustomobject]@{
        Success       = $true
        RefusalReason = $null
        Path          = $worktreePath
        BranchName    = $branchName
    }
}

# ---------------------------------------------------------------------------
# Teardown
# ---------------------------------------------------------------------------

# Private: path normalization for the porcelain worktree-path comparison
# (mirrors session-startup-git-helpers.ps1's ConvertTo-SCDPathForComparison
# shape -- duplicated, not imported, for the same standalone-lib reason as
# Test-GoalRunTreeClean above).
function script:ConvertTo-GoalRunPathForComparison {
    [CmdletBinding()]
    [OutputType([string])]
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
    try {
        return [System.IO.Path]::GetFullPath($Path).Replace('\', '/').TrimEnd('/')
    }
    catch {
        return $Path.Replace('\', '/').TrimEnd('/')
    }
}

# Private: resolves whether $WorktreePath is currently registered/locked/
# prunable per `git worktree list --porcelain`. IsRegistered is $null only
# on a probe error (non-zero exit / no output), which the outcome-diagnosis
# function below treats as 'verification-indeterminate'.
function script:Get-GoalRunWorktreePorcelainInfo {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$WorktreePath,
        [Parameter(Mandatory = $false)][string]$GitCliPath = 'git'
    )

    $normTarget = script:ConvertTo-GoalRunPathForComparison -Path $WorktreePath

    $porcelainRaw = & $GitCliPath -C $RepoRoot worktree list --porcelain 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $porcelainRaw) {
        return [pscustomobject]@{ IsRegistered = $null; IsLocked = $false; IsPrunable = $false }
    }

    $text = ((@($porcelainRaw) -join "`n") -replace "`r`n", "`n" -replace "`r", "`n").Trim()
    if ([string]::IsNullOrWhiteSpace($text)) {
        return [pscustomobject]@{ IsRegistered = $false; IsLocked = $false; IsPrunable = $false }
    }

    foreach ($block in [regex]::Split($text, "`n\s*`n")) {
        $lines = @($block -split "`n" | ForEach-Object { $_.TrimEnd() })
        $worktreeLine = $lines | Where-Object { $_ -like 'worktree *' } | Select-Object -First 1
        if (-not $worktreeLine) { continue }

        $normLine = script:ConvertTo-GoalRunPathForComparison -Path $worktreeLine.Substring('worktree '.Length)
        if ([string]::Equals($normLine, $normTarget, [System.StringComparison]::OrdinalIgnoreCase)) {
            return [pscustomobject]@{
                IsRegistered = $true
                IsLocked     = [bool]($lines | Where-Object { $_ -eq 'locked' -or $_ -like 'locked *' })
                IsPrunable   = [bool]($lines | Where-Object { $_ -eq 'prunable' -or $_ -like 'prunable *' })
            }
        }
    }

    return [pscustomobject]@{ IsRegistered = $false; IsLocked = $false; IsPrunable = $false }
}

# Private: verified on-disk state -- 'absent' | 'empty' | 'non-empty'.
function script:Resolve-GoalRunWorktreeFsState {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$WorktreePath)

    if (-not (Test-Path -LiteralPath $WorktreePath)) { return 'absent' }
    $children = @(Get-ChildItem -LiteralPath $WorktreePath -Force -ErrorAction SilentlyContinue)
    if ($children.Count -eq 0) { return 'empty' }
    return 'non-empty'
}

# Private: pure post-removal-attempt diagnosis over the registered x
# {absent,empty,non-empty} matrix. Returns the SAME six-value closed enum as
# session-startup-git-helpers.ps1's Get-WorktreeRemovalOutcome (literal
# vocabulary reused; the function itself is a deliberate parallel
# implementation, not a shared call -- see file header).
function script:Get-GoalRunWorktreeRemovalOutcome {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$WorktreePath,
        [Parameter(Mandatory = $false)][string]$GitCliPath = 'git'
    )

    $registered = $null
    $fsState = $null
    try {
        $registered = (script:Get-GoalRunWorktreePorcelainInfo -RepoRoot $RepoRoot -WorktreePath $WorktreePath -GitCliPath $GitCliPath).IsRegistered
    }
    catch { $registered = $null }
    try {
        $fsState = script:Resolve-GoalRunWorktreeFsState -WorktreePath $WorktreePath
    }
    catch { $fsState = $null }

    if ($null -eq $registered -or $null -eq $fsState) {
        return 'verification-indeterminate'
    }

    if ($registered) {
        switch ($fsState) {
            'absent' { return 'stale-registration' }
            'empty' { return 'removed-partial-root-held' }
            'non-empty' { return 'failed' }
            default { return 'verification-indeterminate' }
        }
    }
    else {
        switch ($fsState) {
            'absent' { return 'removed' }
            'empty' { return 'removed-partial-root-held' }
            'non-empty' { return 'removed-partial-content-remains' }
            default { return 'verification-indeterminate' }
        }
    }
}

# Private: determines whether the ONLY untracked/uncommitted content in the
# worktree is the known goal-run state file itself -- i.e. every porcelain
# line is an untracked ('??') entry naming exactly
# $script:GoalRunActiveStateFileName. A routine, healthy run always leaves
# this file behind as untracked content, which makes a plain `git worktree
# remove` refuse even though there is nothing genuinely unsaved to protect.
# Fails CLOSED ($false) on any probe error, a clean-looking porcelain (0
# lines -- that case should never reach here since a clean tree's plain
# remove would already have succeeded), or any line that doesn't exactly
# match the expected shape -- callers must treat "cannot confirm" as "not
# known-safe to force", mirroring the file's existing never-force-on-a-flag-
# alone philosophy (see the locked-worktree clause below). Scoped to the
# worktree itself (`git -C $WorktreePath`), NOT $RepoRoot -- the worktree
# lives on its own freshly branched HEAD and `-C $RepoRoot` would not
# reflect the worktree's own local dirty state at all.
function script:Test-GoalRunWorktreeOnlyExpectedContent {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$WorktreePath,
        [Parameter(Mandatory = $false)][string]$GitCliPath = 'git'
    )

    if (-not (Test-Path -LiteralPath $WorktreePath)) { return $false }

    $porcelain = & $GitCliPath -C $WorktreePath status --porcelain --ignored=no 2>$null
    if ($LASTEXITCODE -ne 0) { return $false }

    $lines = @($porcelain | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($lines.Count -eq 0) { return $false }

    foreach ($line in $lines) {
        # Short porcelain format is "XY PATH": 2-char status + one space.
        # Anything other than an untracked ('??') entry naming exactly the
        # known state file fails closed.
        if ($line.Length -lt 4) { return $false }
        $status = $line.Substring(0, 2)
        $path = $line.Substring(3).Trim().Trim('"')
        if ($status -ne '??') { return $false }
        if ($path -ne $script:GoalRunActiveStateFileName) { return $false }
    }

    return $true
}

# Private: one removal attempt, decision tree mirroring
# post-merge-cleanup.ps1's corrected D5/#522 clause -- locked+absent gets a
# double-force removal (nothing left to lock), locked+present is never
# force-removed here (caller skips the attempt entirely), prunable+absent
# clears the stale registration, and the default path tries a plain removal
# before escalating to --force when independently known prunable OR when
# Test-GoalRunWorktreeOnlyExpectedContent confirms the only dirty content is
# the goal-run's own state file (issue #874, PR1 fix -- a routine, healthy
# run always leaves that file behind as untracked, which otherwise makes the
# plain remove refuse on essentially every mainline teardown). Any OTHER
# dirty content is never force-removed here -- it falls through to the
# existing retry/defer path unchanged, so unexpected/genuine unsaved work is
# never destroyed.
function script:Invoke-GoalRunWorktreeRemovalAttempt {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$GitCliPath,
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$WorktreePath,
        [Parameter(Mandatory)][bool]$IsLocked,
        [Parameter(Mandatory)][bool]$IsPrunable,
        [Parameter(Mandatory)][bool]$DirAbsent
    )

    if ($IsLocked -and $DirAbsent) {
        & $GitCliPath -C $RepoRoot worktree remove --force --force $WorktreePath 2>$null | Out-Null
    }
    elseif ($IsPrunable -and $DirAbsent) {
        & $GitCliPath -C $RepoRoot worktree remove --force $WorktreePath 2>$null | Out-Null
    }
    else {
        & $GitCliPath -C $RepoRoot worktree remove $WorktreePath 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) {
            $onlyExpectedContent = -not $IsPrunable -and -not $DirAbsent -and
                (script:Test-GoalRunWorktreeOnlyExpectedContent -WorktreePath $WorktreePath -GitCliPath $GitCliPath)
            if ($IsPrunable -or $onlyExpectedContent) {
                & $GitCliPath -C $RepoRoot worktree remove --force $WorktreePath 2>$null | Out-Null
            }
        }
    }
    # Prune runs regardless of the remove outcome (best-effort admin-file
    # reconciliation); its own exit code is never load-bearing here -- the
    # honest post-attempt outcome is always re-derived via verified probes.
    & $GitCliPath -C $RepoRoot worktree prune 2>$null | Out-Null
}

function Remove-GoalRunWorktree {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$WorktreePath,
        [Parameter(Mandatory = $false)][string]$GitCliPath = 'git',
        [Parameter(Mandatory = $false)][int]$RetryDelayMs = 1000,
        [Parameter(Mandatory = $false)][int]$MaxAttempts = 2
    )

    $terminalOutcomes = @('removed', 'stale-registration')
    $attempts = 0
    $outcome = $null

    $info = script:Get-GoalRunWorktreePorcelainInfo -RepoRoot $RepoRoot -WorktreePath $WorktreePath -GitCliPath $GitCliPath
    $dirAbsent = -not (Test-Path -LiteralPath $WorktreePath)

    if ($info.IsLocked -and -not $dirAbsent) {
        # Directory still present: manual-review territory, never force-
        # removed on the lock flag alone (D5/#522) -- no attempt is made.
        $outcome = script:Get-GoalRunWorktreeRemovalOutcome -RepoRoot $RepoRoot -WorktreePath $WorktreePath -GitCliPath $GitCliPath
    }
    else {
        while ($attempts -lt $MaxAttempts) {
            $attempts++
            $currentDirAbsent = -not (Test-Path -LiteralPath $WorktreePath)
            script:Invoke-GoalRunWorktreeRemovalAttempt -GitCliPath $GitCliPath -RepoRoot $RepoRoot -WorktreePath $WorktreePath `
                -IsLocked $info.IsLocked -IsPrunable $info.IsPrunable -DirAbsent $currentDirAbsent

            $outcome = script:Get-GoalRunWorktreeRemovalOutcome -RepoRoot $RepoRoot -WorktreePath $WorktreePath -GitCliPath $GitCliPath
            if ($terminalOutcomes -contains $outcome) { break }

            if ($attempts -lt $MaxAttempts) {
                Start-Sleep -Milliseconds ($RetryDelayMs * $attempts)
            }
        }
    }

    $deferred = ($terminalOutcomes -notcontains $outcome)

    if ($deferred) {
        # Defer-and-flag: best-effort, never throws. The state file may
        # itself be gone (e.g. 'removed-partial-root-held' wiped its
        # contents), in which case there is nothing left to flag -- the
        # return object below is still the authoritative TeardownDeferred
        # signal for the caller.
        try {
            $statePath = Join-Path $WorktreePath $script:GoalRunActiveStateFileName
            if (Test-Path -LiteralPath $statePath) {
                Set-GoalRunActiveStateTeardownDeferred -WorktreePath $WorktreePath -Value $true | Out-Null
            }
        }
        catch {
            Write-Warning "Remove-GoalRunWorktree: could not persist teardown_deferred flag at '$WorktreePath' -- $($_.Exception.Message)"
        }
    }

    return [pscustomobject]@{
        Outcome          = $outcome
        TeardownDeferred = $deferred
        Attempts         = $attempts
        WorktreePath     = $WorktreePath
    }
}

# ---------------------------------------------------------------------------
# Deferred-teardown retry (issue #874, plan step 3, AC3 detector-protection
# half). Standalone entry point -- deliberately not buried inside
# session-cleanup-detector-core.ps1's own report-generation flow, so a
# future /goal-run agent-body invocation can call this same function
# directly, in addition to the owner-confirmed composite command the
# detector renders in its report.
# ---------------------------------------------------------------------------

function Invoke-GoalRunDeferredTeardownRetry {
    <#
    .SYNOPSIS
        Retries teardown for a goal-run worktree whose state file previously
        recorded teardown_deferred: true (Remove-GoalRunWorktree exhausted
        its retries and deferred). No-ops (never throws) when the state file
        is absent/unreadable or does not carry teardown_deferred: true --
        callers should treat Attempted=$false as "nothing to do here", not
        as an error.
    .OUTPUTS
        [pscustomobject]@{ Attempted; Reason; Outcome; TeardownDeferred; Attempts; WorktreePath }
        Reason is $null when Attempted=$true; otherwise one of
        'no-state-file' | 'not-deferred'.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$WorktreePath,
        [Parameter(Mandatory = $false)][string]$GitCliPath = 'git',
        [Parameter(Mandatory = $false)][int]$RetryDelayMs = 1000,
        [Parameter(Mandatory = $false)][int]$MaxAttempts = 2
    )

    $state = $null
    try {
        $state = Get-GoalRunActiveState -WorktreePath $WorktreePath
    }
    catch {
        $state = $null
    }

    if ($null -eq $state) {
        return [pscustomobject]@{
            Attempted        = $false
            Reason           = 'no-state-file'
            Outcome          = $null
            TeardownDeferred = $null
            Attempts         = 0
            WorktreePath     = $WorktreePath
        }
    }

    if (-not [bool]$state.teardown_deferred) {
        return [pscustomobject]@{
            Attempted        = $false
            Reason           = 'not-deferred'
            Outcome          = $null
            TeardownDeferred = $false
            Attempts         = 0
            WorktreePath     = $WorktreePath
        }
    }

    $removal = Remove-GoalRunWorktree -RepoRoot $RepoRoot -WorktreePath $WorktreePath -GitCliPath $GitCliPath -RetryDelayMs $RetryDelayMs -MaxAttempts $MaxAttempts

    return [pscustomobject]@{
        Attempted        = $true
        Reason           = $null
        Outcome          = $removal.Outcome
        TeardownDeferred = $removal.TeardownDeferred
        Attempts         = $removal.Attempts
        WorktreePath     = $removal.WorktreePath
    }
}
