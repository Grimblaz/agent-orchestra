#Requires -Version 7.0
<#
.SYNOPSIS
    Shared git helpers for session-startup automation.

.NOTES
    Detector-safe helpers only resolve refs or read local git state and may be
    used by session-cleanup-detector-core.ps1. Cleanup-only decision helpers
    feed deletion authorization in post-merge-cleanup.ps1; keep those
    conservative and fail-open when their evidence is unavailable.
    Fail-safe static-persistence-registry: Get-SCDPersistentTrackingExclusions
    returns the set of .copilot-tracking/ artifacts that must never be deleted.
    Registry unavailability must halt loudly before any deletion; it must NOT
    fail-open toward deletion.
#>

$script:OrphanIssueRegex = '^feature/issue-(\d+)-'
$script:ClaudeBranchIssueRegex = '^claude/.*-(\d+)-[0-9a-f]{6}$'

# Issue #889 s1: manual-review reason enum — single authoritative source, consumed
# verbatim by Test-WorktreeBranchRemovalEligible callers in s2/s3/s4. Do not
# introduce a differently-worded literal elsewhere; parity is checked downstream.
$script:WorktreeEligibilityReasons = @{
    UnmergedCommits           = 'unmerged commits'
    NoIssueDerivable          = 'no issue number derivable'
    IssueStillOpen            = "issue #{0} still open"
    GhUnavailable             = "couldn't verify: gh unavailable"
    GhTimeout                 = "couldn't verify: gh timeout"
    GitSignalFailed           = "couldn't verify: git signal failed"
    # Issue #922 (AC6/I-3): before this, 'unmerged commits' carried BOTH "content
    # evidence shows this branch is not merged" and "we obtained no conclusive
    # evidence either way" — the conflation AC6 exists to remove, and the reason a
    # merge-tree-conflicting branch (the steady state for any worktree older than
    # one merge) was reported as though it had been judged. 'unmerged commits' is
    # now exclusively the conclusive negative; this literal is the inconclusive case.
    InconclusiveMergeEvidence = "couldn't verify: no conclusive merge evidence"
}

# Issue #922 (I-3/AC13/D4): the eligibility outcome, kept separate from
# ManualReviewReason so the reporting layer never has to string-match a reason to
# decide whether a candidate renders. Decision D4 renders 'definitively-unmerged'
# silently; every other not-eligible outcome renders with its cause.
$script:WorktreeEligibilityOutcomes = @{
    Eligible             = 'eligible'
    DefinitivelyUnmerged = 'definitively-unmerged'
    NotEligible          = 'not-eligible'
}

function Get-SCDPersistentTrackingExclusions {
    <#
    .SYNOPSIS
        Returns the dual-axis persistent-exclusion registry for .copilot-tracking/ artifacts.
        Subtrees: directory prefixes whose entire subtree is persistent (e.g. 'calibration').
        Filenames: root-level basenames that must never be deleted/archived.
        Callers: session-cleanup-detector-core.ps1, post-merge-cleanup.ps1.
        Registry unavailability must halt loudly before any Move-Item — do NOT fail-open.
    #>
    return @{
        Subtrees  = @('calibration')
        Filenames = @('gate-events.jsonl', 'references-state.yml', 'references-init.manifest')
    }
}

function Invoke-SCDNativeCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [scriptblock]$Command
    )

    $pref = Get-Variable -Name PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue
    if ($null -eq $pref) { return & $Command }

    $previous = $PSNativeCommandUseErrorActionPreference
    $PSNativeCommandUseErrorActionPreference = $false
    try { return & $Command }
    finally { $PSNativeCommandUseErrorActionPreference = $previous }
}

function Get-SCDDefaultBranch {
    <#
    .SYNOPSIS
        Resolves the remote default branch using the same multi-strategy pattern as
        post-merge-cleanup.ps1: symbolic-ref -> show-ref main -> show-ref master -> current HEAD -> main.
    #>
    $branch = (Invoke-SCDNativeCommand { git symbolic-ref refs/remotes/origin/HEAD 2>$null }) -replace 'refs/remotes/origin/', ''
    if ($LASTEXITCODE -ne 0) { $branch = $null }
    if (-not $branch) {
        Invoke-SCDNativeCommand { git show-ref --verify --quiet refs/remotes/origin/main 2>$null }
        if ($LASTEXITCODE -eq 0) { $branch = 'main' }
    }
    if (-not $branch) {
        Invoke-SCDNativeCommand { git show-ref --verify --quiet refs/remotes/origin/master 2>$null }
        if ($LASTEXITCODE -eq 0) { $branch = 'master' }
    }
    if (-not $branch) {
        $localHead = (Invoke-SCDNativeCommand { git symbolic-ref HEAD 2>$null })
        if ($LASTEXITCODE -eq 0 -and $localHead) {
            $branch = $localHead -replace 'refs/heads/', ''
        }
    }
    if (-not $branch) { $branch = 'main' }
    return $branch
}

function Get-RemoteDefaultRef {
    # G1: Resolve the remote-tracking ref dynamically rather than hardcoding 'origin/'.
    # Handles users who configure the default branch's upstream as e.g. 'upstream/main'.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$DefaultBranch
    )
    $upstream = Invoke-SCDNativeCommand { git rev-parse --abbrev-ref "${DefaultBranch}@{upstream}" 2>$null }
    if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($upstream)) {
        return $upstream.Trim()
    }

    # Finding K (#889 fix cycle): fall back to reading branch.<X>.remote directly
    # before defaulting to a hardcoded 'origin/<DefaultBranch>' — merged in from
    # the detector's own (previously separate, now-consolidated) config-first
    # resolver, Get-SCDRemoteDefaultRef, which correctly handled a configured
    # non-'origin' remote name even when the @{upstream} shorthand above is
    # unavailable (e.g. a fork workflow where 'main' tracks a custom remote name).
    $configuredRemote = Invoke-SCDNativeCommand { git config --get "branch.$DefaultBranch.remote" 2>$null }
    if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($configuredRemote)) {
        return "$($configuredRemote.Trim())/$DefaultBranch"
    }

    return "origin/$DefaultBranch"
}

# Issue #922 (Amendment A2.4): the signal literals a merged verdict may name, and
# the causes an undetermined verdict may name. Single authoritative source —
# Get-SCDBranchMergeVerdict is the only producer, and the evidence string the
# eligibility gate records must name the signal that actually fired rather than
# the unconditional "tree-equivalent" the pre-#922 gate recorded for every shape.
$script:BranchMergeSignals = @{
    TreeEquivalent  = 'tree-equivalent'
    # Issue #922 Amendment A3 (review of PR #950, finding M5): the content probes
    # pass --ignore-cr-at-eol, so "tree-equivalent" can mean "identical except for
    # line endings". Issue #513 asserts that tolerance directly and Amendment A1.4
    # retained it deliberately, so the BEHAVIOUR stands — but decision D1 made this
    # signal a live deletion authority on the worktree paths for the first time,
    # and #513's asserted fixture only ever covered the detached-orphan executor
    # path. Invariant I-1 says no output asserts more than its evidence supports:
    # when the equivalence rests on the tolerance, the offered command says so.
    TreeEquivalentCrOnly = 'tree-equivalent apart from line endings'
    MergeTreeNoOp   = 'merge-tree no-op'
    MergeTreeDiffers = 'merge-tree clean and divergent'
}

$script:BranchMergeUndeterminedCauses = @{
    MergeTreeConflicted = 'merge-tree conflicted'
    GitSignalFailed     = 'git signal failed'
}

function Get-SCDBranchMergeVerdict {
    <#
    .SYNOPSIS
        Issue #922 (invariant I-6, Amendments A1.1/A2.1/A2.4): the sole producer of
        a git-only merge verdict about $BranchName against the remote default.
        Content evidence only — no gh, no patch history.
    .DESCRIPTION
        Two content signals establish `merged`:
          * strict tree-equivalence — the branch tip's tree already equals the
            remote default's;
          * merge-tree no-op — merging the branch into the remote default would
            produce the remote default's own tree (the squash-then-advance shape).

        One content signal establishes `definitively-unmerged` (A2.1): merge-tree
        merges CLEANLY and the resulting tree still differs from the remote
        default. That is positive evidence that the branch carries content the
        default does not have. Where merge-tree conflicts, no conclusive verdict
        is available at all and the answer is `undetermined`.

        `git cherry` is deliberately absent (A1.1). It compares patch identities —
        "were these patches ever applied upstream", not "is this content present
        upstream now" — and was wrong in both directions: a revert breaks patch
        equivalence while leaving cherry saying merged, and a squash rewrites
        patch-ids so cherry says unmerged for fully-shipped branches. Patch
        history yields neither conclusive value.

        Line-ending tolerance (--ignore-cr-at-eol) is retained deliberately per
        A1.4; issue #513 asserts that behaviour directly.
    .OUTPUTS
        Hashtable: @{
            Verdict = 'merged' | 'definitively-unmerged' | 'undetermined'
            Signal  = <one of $script:BranchMergeSignals> | $null
            Cause   = <one of $script:BranchMergeUndeterminedCauses> | $null
        }
        Every failure to gather evidence resolves to 'undetermined' (I-5); no
        failure path produces either conclusive value.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$BranchName,

        [Parameter(Mandatory)]
        [string]$DefaultBranch
    )

    $remoteDefault = Get-RemoteDefaultRef -DefaultBranch $DefaultBranch

    $merged = {
        param([string]$Signal)
        @{ Verdict = 'merged'; Signal = $Signal; Cause = $null }
    }
    $undetermined = {
        param([string]$Cause)
        @{ Verdict = 'undetermined'; Signal = $null; Cause = $Cause }
    }

    # Signal 1: strict tree-equivalence — catches squash-merged branches whose tip
    # content is identical to the remote default even when commit history differs.
    $savedEap = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'
    try {
        Invoke-SCDNativeCommand { git diff --quiet --ignore-cr-at-eol $remoteDefault $BranchName 2>$null }
        $diffExit = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $savedEap }
    if ($diffExit -eq 0) {
        # Amendment A3 (finding M5): distinguish a genuine tree-identity from one
        # that holds only because CR-at-EOL differences were ignored. One extra
        # local git call, on the merged path only, so the evidence names what it
        # actually established. The verdict is unchanged either way — this is a
        # disclosure fix, not a narrowing of #513's deliberate tolerance.
        $savedEap = $ErrorActionPreference
        $ErrorActionPreference = 'SilentlyContinue'
        try {
            Invoke-SCDNativeCommand { git diff --quiet $remoteDefault $BranchName 2>$null }
            $strictDiffExit = $LASTEXITCODE
        }
        finally { $ErrorActionPreference = $savedEap }

        if ($strictDiffExit -eq 1) {
            return (& $merged $script:BranchMergeSignals.TreeEquivalentCrOnly)
        }
        return (& $merged $script:BranchMergeSignals.TreeEquivalent)
    }

    # Signals 2 and 3 both come out of one merge-tree run. `git merge-tree
    # --write-tree` exits 0 on a clean merge, 1 on conflicts, and otherwise on
    # error; only the clean case carries content evidence in either direction.
    $savedEap = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'
    try {
        $mergeTreeOutput = @(Invoke-SCDNativeCommand { git merge-tree --write-tree $remoteDefault $BranchName 2>$null })
        $mergeTreeExit = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $savedEap }

    $mergedTree = @($mergeTreeOutput | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1)

    if ($mergeTreeExit -eq 1) {
        # Exit 1 covers BOTH a genuine conflict and an invocation failure — a
        # bad ref exits 1 too, measured, not assumed. They are told apart by
        # stdout: a conflicting merge still writes the merged tree's OID on the
        # first line, while a failed invocation writes nothing to stdout at all.
        #
        # AC6 requires each undetermined cause to be the one that actually
        # applied. Reporting a gathering failure as "merge-tree conflicted" would
        # be Defect C's mis-attribution reproduced inside the verdict.
        if ($mergedTree.Count -eq 0) {
            return (& $undetermined $script:BranchMergeUndeterminedCauses.GitSignalFailed)
        }
        # Conflicting merge-tree: no conclusive content evidence in either
        # direction. This is the steady state for any worktree older than one
        # merge (the version-bump file set is touched by essentially every
        # commit), and Amendment A2.2 requires it to stay reachable at the
        # merged-pull-request rung rather than resolving here.
        return (& $undetermined $script:BranchMergeUndeterminedCauses.MergeTreeConflicted)
    }
    if ($mergeTreeExit -ne 0) {
        return (& $undetermined $script:BranchMergeUndeterminedCauses.GitSignalFailed)
    }

    if ($mergedTree.Count -eq 0) {
        return (& $undetermined $script:BranchMergeUndeterminedCauses.GitSignalFailed)
    }

    $mergedTreeOid = $mergedTree[0].Trim()
    $savedEap = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'
    try {
        Invoke-SCDNativeCommand { git diff --quiet --ignore-cr-at-eol $remoteDefault $mergedTreeOid 2>$null }
        $mergedTreeDiffExit = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $savedEap }

    if ($mergedTreeDiffExit -eq 0) {
        return (& $merged $script:BranchMergeSignals.MergeTreeNoOp)
    }
    if ($mergedTreeDiffExit -eq 1) {
        # Amendment A2.1: the merge succeeded cleanly and still changed the
        # default's tree, so the branch demonstrably carries content the default
        # does not have. This is the ONLY producer of the negative verdict — before
        # A2.1, A1.1's demotion of cherry left D4's silence category with no
        # constructible input at all.
        return @{
            Verdict = 'definitively-unmerged'
            Signal  = $script:BranchMergeSignals.MergeTreeDiffers
            Cause   = $null
        }
    }

    # The comparison itself failed (exit > 1): no verdict, per I-5.
    return (& $undetermined $script:BranchMergeUndeterminedCauses.GitSignalFailed)
}

function Test-BranchTreeEquivalentToDefault {
    <#
    .SYNOPSIS
        Tri-state adapter over Get-SCDBranchMergeVerdict, preserving the
        bool/$null contract Test-BranchMergedIntoDefault and the cleanup executor
        consume. Issue #889 M4 established that this check must stay purely
        git-only (no name-only `gh pr list` fallback, which would fabricate
        "tree-equivalent" evidence for a branch that merely shares a name with an
        unrelated merged PR); issue #922 moved the verdict itself into
        Get-SCDBranchMergeVerdict so the establishing signal can be named.
    .OUTPUTS
        Tri-state [bool]/$null: $true when content evidence shows the branch is
        merged; $false when content evidence conclusively shows it is not
        (Amendment A2.1's clean-merge-tree-that-differs); $null when no
        conclusive content evidence was obtained and the caller should attempt an
        independent fallback (an OID-checked merged-PR match).

        Issue #922 Amendment A1.1: `git cherry` no longer contributes, so the
        merge-tree-conflicting case now returns $null where it previously
        returned a conclusive (and frequently wrong) answer from patch history.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$BranchName,

        [Parameter(Mandatory)]
        [string]$DefaultBranch
    )

    $verdict = Get-SCDBranchMergeVerdict -BranchName $BranchName -DefaultBranch $DefaultBranch
    switch ($verdict.Verdict) {
        'merged' { return $true }
        'definitively-unmerged' { return $false }
        default { return $null }
    }
}

function Test-BranchMergedIntoDefault {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$BranchName,

        [Parameter(Mandatory)]
        [string]$DefaultBranch
    )

    $treeEquivalent = Test-BranchTreeEquivalentToDefault -BranchName $BranchName -DefaultBranch $DefaultBranch
    if ($null -ne $treeEquivalent) {
        # Definitive git-only answer (merged, or git cherry ran and showed
        # unmerged commits) — do not fall through to the gh lookup,
        # preserving this function's original short-circuit behavior.
        return $treeEquivalent
    }

    # Fallback: OID-checked merged-PR-by-head lookup (Issue #889 fix cycle, finding
    # A). The previous fallback here was a NAME-ONLY `gh pr list --head ... --state
    # merged --json number` match — a branch that merely shares a name with an
    # already-merged-and-since-advanced (or entirely unrelated) PR would be
    # misreported as merged (the M4-class false positive). Get-SCDMergedPrByHeadOid
    # requires the PR's headRefOid to equal the branch's current tip before treating
    # it as evidence, matching the same OID-checked pattern
    # Test-WorktreeBranchRemovalEligible already uses.
    $pr = Get-SCDMergedPrByHeadOid -Branch $BranchName -DefaultBranch $DefaultBranch
    if ($pr.Status -eq 'matched') {
        return $true
    }

    # Conservative: treat as unmerged for safety (covers 'no-match', 'unavailable', 'timeout')
    return $false
}

# Cleanup-only decision helpers — feed deletion authorization in post-merge-cleanup.ps1
# These helpers are cleanup-time (not session-startup-time) evaluators and should only
# be called from Remove-OrphanBranch inside post-merge-cleanup.ps1.

function Test-OrphanBranchGitHubSignalsShipped {
    <#
    .SYNOPSIS
        Tri-state check: returns $true when the parent issue is CLOSED (any stateReason)
        and a merged PR with a matching headRefOid exists against the default branch;
        $false when signals indicate the branch is not cleanly shipped;
        $null when gh is unavailable or signals cannot be retrieved.
    .PARAMETER Branch
        The local orphan branch name to check (e.g. 'feature/issue-548-squash-merge-orphan-autodelete').
    .PARAMETER DefaultBranch
        The default branch name (e.g. 'main').
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Branch,

        [Parameter(Mandatory)]
        [string]$DefaultBranch
    )

    # (1) Parse issue-ID from branch name via shared regex
    if ($Branch -notmatch $script:OrphanIssueRegex) { return $false }
    $issueNum = $Matches[1]

    # (2) Check parent issue state via gh issue view
    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) { return $null }

    # Suppress ErrorActionPreference during gh invocations: callers (e.g. post-merge-cleanup.ps1)
    # set $ErrorActionPreference = 'Stop', which converts native-process stderr into terminating errors.
    # The 2>$null redirect suppresses the stderr stream but not PowerShell's error-stream promotion.
    # Temporarily lowering the preference here keeps the existing $LASTEXITCODE-based tri-state logic intact.
    $savedEap = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'
    try {
        $issueJson = Invoke-SCDNativeCommand { gh issue view $issueNum --json state 2>$null }
        $issueExitCode = $LASTEXITCODE
        $prJson = $null
        $prExitCode = 0
        if ($issueExitCode -eq 0) {
            $prJson = Invoke-SCDNativeCommand { gh pr list --head $Branch --base $DefaultBranch --state merged --json 'number,mergedAt,headRefOid' 2>$null }
            $prExitCode = $LASTEXITCODE
        }
    }
    finally {
        $ErrorActionPreference = $savedEap
    }

    if ($issueExitCode -ne 0) { return $null }

    try {
        $issue = $issueJson | ConvertFrom-Json -ErrorAction Stop
    }
    catch { return $null }

    if ($issue.state -ne 'CLOSED') { return $false }
    # stateReason is intentionally NOT checked — any CLOSED stateReason authorizes (D-state-reason)

    # (3) Check for a merged PR with headRefOid matching the branch tip
    if ($prExitCode -ne 0) { return $null }

    try {
        $prs = $prJson | ConvertFrom-Json -ErrorAction Stop
    }
    catch { return $null }

    if ($prs.Count -eq 0) { return $false }

    # (4) Match headRefOid against local branch tip
    $branchTip = Invoke-SCDNativeCommand { git rev-parse $Branch 2>$null }
    if ($LASTEXITCODE -ne 0) { return $null }
    $branchTip = $branchTip.Trim()

    foreach ($pr in $prs) {
        if ($pr.headRefOid -eq $branchTip) { return $true }
    }

    return $false
}

function Test-OrphanBranchCommitsAbsorbed {
    <#
    .SYNOPSIS
        Tri-state check: returns $true when every commit in $Branch that is not
        reachable from $DefaultBranch has been absorbed by main (via ancestor,
        patch-equivalence, spike-only-per-issue, or tree-at-HEAD equivalence);
        $false when at least one commit is genuinely unabsorbed;
        $null when any batched git invocation fails.
    .PARAMETER Branch
        The local orphan branch name.
    .PARAMETER DefaultBranch
        The default branch name (e.g. 'main').
    .PARAMETER IssueId
        The numeric issue ID parsed from the branch name; used to scope spike-path predicate.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Branch,

        [Parameter(Mandatory)]
        [string]$DefaultBranch,

        [Parameter(Mandatory)]
        [long]$IssueId
    )

    # Resolve remote default ref (e.g. 'origin/main')
    $remoteDefault = Get-RemoteDefaultRef -DefaultBranch $DefaultBranch
    if (-not $remoteDefault) { $remoteDefault = $DefaultBranch }

    # --- Batched git invocation 1: cherry — patch-equivalence map ---
    # Lines prefixed '+' are unique to $Branch; '-' are patch-equivalent in upstream
    $cherryOutput = Invoke-SCDNativeCommand { git cherry $remoteDefault $Branch 2>$null }
    if ($LASTEXITCODE -ne 0) { return $null }
    # Parse: @{ SHA = prefix }
    $cherryMap = @{}
    foreach ($line in @($cherryOutput)) {
        if (-not [string]::IsNullOrWhiteSpace($line)) {
            $parts = $line.Trim() -split '\s+'
            if ($parts.Count -ge 2) { $cherryMap[$parts[1]] = $parts[0] }
        }
    }

    # --- Batched git invocation 2: rev-list --no-merges — residual non-merge commits not reachable from default ---
    # --no-merges excludes merge commits (which have no meaningful patch on their own — their
    # constituent commits, walked through all parents by default, carry the actual file changes).
    # Pairs with the --no-merges flag on git log below so $residualSHAs and $commitPaths cover
    # the same commit set, including second-parent ancestors of sub-feature merges.
    #
    # SAFETY ASSUMPTION (workflow-dependent): a merge commit on the branch may carry conflict-
    # resolution content unique to that commit — content absent from both of its parents — at
    # a path not touched by any non-merge residual commit. Such paths are not inspected by this
    # function. Safety relies on the calling orchestrator (Test-OrphanBranchAutoResolveEligible):
    # under the project's squash-merge-only PR convention, Test-OrphanBranchGitHubSignalsShipped
    # first requires headRefOid == git rev-parse $Branch (a merged PR's recorded head must equal
    # the current branch tip SHA). A squash-merge captures the full branch-tip-vs-base diff,
    # so any merge-commit-unique content is independently propagated to main's tree at those
    # paths. If the project's merge convention ever broadens to rebase-merge or true merge-commit
    # as the dominant PR strategy, this function should be hardened: add a fourth batched call
    # 'git rev-list $Branch --not $remoteDefault --merges' and evaluate each residual merge
    # commit's paths via 'git diff-tree -m -r --name-status <sha>' through the same spike-only /
    # tree-at-HEAD sub-cases, conservatively returning $false when paths cannot be determined.
    $revListOutput = Invoke-SCDNativeCommand { git rev-list $Branch --not $remoteDefault --no-merges 2>$null }
    if ($LASTEXITCODE -ne 0) { return $null }
    $residualSHAs = @($revListOutput | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_.Trim() })

    # No residual commits: branch is fully absorbed
    if ($residualSHAs.Count -eq 0) { return $true }

    # --- Batched git invocation 3: log --no-merges --name-status — per-commit path lists ---
    # Mirrors the --no-merges flag on rev-list above. Dropping --first-parent (was previously here)
    # means second-parent ancestors of intra-branch merge commits now appear in $commitPaths with
    # their actual file paths, so the spike-only / tree-at-HEAD sub-cases can evaluate them
    # instead of falling through to the empty-path guard and conservatively declining auto-resolve.
    $logOutput = Invoke-SCDNativeCommand { git log --no-merges --name-status "$remoteDefault..$Branch" 2>$null }
    if ($LASTEXITCODE -ne 0) { return $null }

    # Parse per-commit path lists from log output
    # Format: commit <SHA>\n...\n<status>\t<path>\n  or  R<N>\t<src>\t<dst>
    $commitPaths = @{}  # SHA -> [string[]]
    $currentSha  = $null
    foreach ($line in @($logOutput)) {
        if ($line -match '^commit\s+([0-9a-f]{40})') {
            $currentSha = $Matches[1]
            if (-not $commitPaths.ContainsKey($currentSha)) { $commitPaths[$currentSha] = [System.Collections.Generic.List[string]]::new() }
        }
        elseif ($null -ne $currentSha) {
            # Rename: R<N>\t<src>\t<dst>
            if ($line -match '^R\d+\t([^\t]+)\t([^\t]+)$') {
                $commitPaths[$currentSha].Add($Matches[1]) | Out-Null  # source path
                $commitPaths[$currentSha].Add($Matches[2]) | Out-Null  # destination path
            }
            # Other status lines: A/M/D/C/T/etc.\t<path>
            elseif ($line -match '^[A-Z]\t(.+)$') {
                $commitPaths[$currentSha].Add($Matches[1]) | Out-Null
            }
        }
    }

    # --- Collect unique touched paths across all residual commits (for batch diff-tree) ---
    $allTouchedPaths = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($sha in $residualSHAs) {
        if ($commitPaths.ContainsKey($sha)) {
            foreach ($p in $commitPaths[$sha]) { $allTouchedPaths.Add($p) | Out-Null }
        }
    }

    # --- Batched git invocation 4: ls-tree per unique touched path ---
    # Build tree-equivalence map: path -> bool (true = tree at $Branch equals tree at $remoteDefault)
    # Uses git ls-tree (not rev-parse --verify) so mode changes (e.g., chmod +x) are detected.
    $treeEquiv = @{}
    foreach ($path in $allTouchedPaths) {
        $branchTree  = Invoke-SCDNativeCommand { git ls-tree "$Branch" -- "$path" 2>$null }
        $branchTreeExit = $LASTEXITCODE
        $defaultTree = Invoke-SCDNativeCommand { git ls-tree "$remoteDefault" -- "$path" 2>$null }
        $defaultTreeExit = $LASTEXITCODE
        if ($branchTreeExit -ne 0 -or $defaultTreeExit -ne 0) {
            # git ls-tree command failure (not a valid object ref) — cannot determine equivalence
            $treeEquiv[$path] = $false
            continue
        }
        if (-not $branchTree -and -not $defaultTree) {
            # Path absent on both sides (deleted from both) — treat as equivalent
            $treeEquiv[$path] = $true
            continue
        }
        if (-not $branchTree -or -not $defaultTree) {
            # Path absent on one side only — not equivalent
            $treeEquiv[$path] = $false
            continue
        }
        # Compare full tree entries: "<mode> <type> <hash>" (strip tab-delimited path suffix)
        $branchEntry  = ($branchTree  | Select-Object -First 1).Trim() -replace '\t.*$', ''
        $defaultEntry = ($defaultTree | Select-Object -First 1).Trim() -replace '\t.*$', ''
        $treeEquiv[$path] = ($branchEntry -eq $defaultEntry)
    }

    # NOTE: The 4 "batched" invocations are above. The ls-tree calls per path are
    # additional O(touched-paths) calls — consistent with the plan's O(1) per-commit +
    # O(N) per-touched-path contract. ls-tree compares the full tree entry (mode + type + hash),
    # catching mode-only changes and correctly treating paths absent on both sides as equivalent.

    # --- Evaluate each residual commit ---
    $spikePrefixForIssue = ".tmp/issue-$IssueId/"

    foreach ($sha in $residualSHAs) {
        # Sub-case (a): commit is an ancestor of main — absorbed (vacuous; rev-list --not handles this)
        # (if sha not in residualSHAs it would already be absent, but double-check via cherry map)

        # Sub-case (b): patch-equivalent — cherry prefix is '-'
        if ($cherryMap.ContainsKey($sha) -and $cherryMap[$sha] -eq '-') { continue }

        # Sub-case (c): spike-only — every path starts with .tmp/issue-$IssueId/
        $paths = if ($commitPaths.ContainsKey($sha)) { @($commitPaths[$sha]) } else { @() }

        # Empty path list (e.g. --allow-empty commits) — explicitly rejected
        if ($paths.Count -eq 0) { return $false }

        $allSpike = $true
        foreach ($p in $paths) {
            if (-not $p.StartsWith($spikePrefixForIssue)) { $allSpike = $false; break }
        }
        if ($allSpike) { continue }

        # Sub-case (d): tree-at-HEAD — every path has tree-equivalent content on main
        $allTreeEquiv = $true
        foreach ($p in $paths) {
            if (-not $treeEquiv.ContainsKey($p) -or -not $treeEquiv[$p]) { $allTreeEquiv = $false; break }
        }
        if ($allTreeEquiv) { continue }

        # Not absorbed
        return $false
    }

    return $true
}

function Test-OrphanBranchAutoResolveEligible {
    <#
    .SYNOPSIS
        Orchestrator: returns $true when the branch is eligible for auto-delete,
        $false when signals indicate it should be skipped,
        $null when signals cannot be determined (fail-open).
    .NOTES
        Name guard: branches not matching $script:OrphanIssueRegex always return $false (not eligible).
        $null propagation has higher precedence than $false: if either helper returns $null,
        the orchestrator returns $null regardless of the other helper's result.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Branch,

        [Parameter(Mandatory)]
        [string]$DefaultBranch
    )

    # (1) Name guard: non-feature/issue-N branches are definitively not eligible
    if ($Branch -notmatch $script:OrphanIssueRegex) { return $false }
    $issueId = [long]$Matches[1]

    # (2) GitHub signals (tri-state)
    $signals = Test-OrphanBranchGitHubSignalsShipped -Branch $Branch -DefaultBranch $DefaultBranch
    if ($null -eq $signals) { return $null }
    if ($signals -ne $true) { return $false }

    # (3) Commit absorption (tri-state)
    $absorbed = Test-OrphanBranchCommitsAbsorbed -Branch $Branch -DefaultBranch $DefaultBranch -IssueId $issueId
    if ($null -eq $absorbed) { return $null }

    return ($absorbed -eq $true)
}

# ===========================================================================
# Issue #889 s1 — evidence-gated worktree/branch removal eligibility primitive.
# Foundation for s2 (structural guarding), s3 (executor rewiring), and s4
# (detector gating). Both detector and executor dot-source this file, so every
# gh/git call below saves/restores $ErrorActionPreference exactly like
# Test-OrphanBranchGitHubSignalsShipped (M7) — the executor runs under
# $ErrorActionPreference = 'Stop'.
# ===========================================================================

function Get-WorktreeBranchIssueId {
    <#
    .SYNOPSIS
        Derives the numeric issue id from a worktree/branch name, or $null when
        no id is derivable (Issue #889 s1, M6).
    .NOTES
        `^feature/issue-(\d+)-` matches feature branches.
        `^claude/.*-(\d+)-[0-9a-f]{6}$` matches claude branches: the leading
        `^claude/` guard prevents firing on unrelated names (e.g.
        'bugfix/foo-123-abc123'), and the trailing `-[0-9a-f]{6}$` anchor pins
        the issue-number segment immediately before the 6-hex disambiguator.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$BranchName
    )

    if ($BranchName -match $script:OrphanIssueRegex) {
        return [long]$Matches[1]
    }
    if ($BranchName -match $script:ClaudeBranchIssueRegex) {
        return [long]$Matches[1]
    }
    return $null
}

function Get-SCDOriginRepo {
    <#
    .SYNOPSIS
        Resolves 'owner/repo' from the 'origin' remote URL for --repo-pinning
        gh calls (M6 — prevents cross-repo wrong-issue resolution). Returns
        $null when the remote is absent or unparseable.
    #>
    [CmdletBinding()]
    param()

    $savedEap = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'
    try {
        $originUrl = Invoke-SCDNativeCommand { git remote get-url origin 2>$null }
        $exitCode = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $savedEap }

    if ($exitCode -ne 0 -or [string]::IsNullOrWhiteSpace($originUrl)) { return $null }
    if ($originUrl -match 'github\.com[:/](?<owner>[^/]+)/(?<repo>[^/]+?)(?:\.git)?$') {
        return "$($Matches.owner)/$($Matches.repo)"
    }
    return $null
}

function Invoke-SCDGhWithTimeout {
    <#
    .SYNOPSIS
        Runs a gh invocation with a concrete per-call timeout (M10). PowerShell
        has no native per-subprocess timeout, so this uses Start-Process +
        Process.WaitForExit(ms) and kills (discarding partial stdout) on
        timeout, per the plan's explicit mechanism.
    .OUTPUTS
        Hashtable: @{ Status = 'ok'|'unavailable'|'timeout'; Output = <string|$null> }
        'unavailable' covers gh-not-installed, non-zero exit, and any
        Start-Process failure — all resolve toward not-eligible identically.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string[]]$ArgumentList,

        [int]$TimeoutMs = 3000
    )

    # Start-Process performs raw process creation (no PowerShell script-engine
    # shortcut), so it needs a genuinely launchable executable. When multiple
    # gh matches exist on PATH (e.g. both a .ps1 and a .cmd shim), prefer the
    # exe/cmd/bat form; Get-Command's default resolution order is not
    # guaranteed to prefer an executable extension over a .ps1 script.
    $ghCommands = @(Get-Command gh -All -ErrorAction SilentlyContinue)
    if ($ghCommands.Count -eq 0) { return @{ Status = 'unavailable'; Output = $null } }
    $ghCommand = $ghCommands | Where-Object { $_.Source -match '\.(exe|cmd|bat)$' } | Select-Object -First 1
    if (-not $ghCommand) { $ghCommand = $ghCommands[0] }

    $stdoutFile = [System.IO.Path]::GetTempFileName()
    $stderrFile = [System.IO.Path]::GetTempFileName()
    $savedEap = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'
    try {
        try {
            $proc = Start-Process -FilePath $ghCommand.Source -ArgumentList $ArgumentList -NoNewWindow -PassThru `
                -RedirectStandardOutput $stdoutFile -RedirectStandardError $stderrFile -ErrorAction Stop
        }
        catch {
            return @{ Status = 'unavailable'; Output = $null }
        }

        $exited = $proc.WaitForExit($TimeoutMs)
        if (-not $exited) {
            try { $proc.Kill() } catch { }
            # Discard any partial stdout collected before the kill (M10).
            return @{ Status = 'timeout'; Output = $null }
        }
        if ($proc.ExitCode -ne 0) {
            return @{ Status = 'unavailable'; Output = $null }
        }

        $output = Get-Content -Path $stdoutFile -Raw -ErrorAction SilentlyContinue
        return @{ Status = 'ok'; Output = $output }
    }
    finally {
        $ErrorActionPreference = $savedEap
        Remove-Item -Path $stdoutFile, $stderrFile -ErrorAction SilentlyContinue
    }
}

function Get-SCDMergedPrByHeadOid {
    <#
    .SYNOPSIS
        OID-checked merged-PR-by-head lookup (Issue #889 s1). Requires
        headRefOid to equal the current branch tip — reuses the
        Test-OrphanBranchGitHubSignalsShipped OID-match pattern
        (git-helpers.ps1 Test-OrphanBranchGitHubSignalsShipped) rather than a
        name-only PR count, so a branch that merely shares a name with an
        already-merged-and-since-advanced PR is never misreported as eligible.
    .OUTPUTS
        Hashtable: @{ Status = 'matched'|'no-match'|'unavailable'|'timeout'; Number = <int|$null> }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Branch,

        [Parameter(Mandatory)]
        [string]$DefaultBranch
    )

    $prResult = Invoke-SCDGhWithTimeout -ArgumentList @('pr', 'list', '--head', $Branch, '--base', $DefaultBranch, '--state', 'merged', '--json', 'number,headRefOid')
    if ($prResult.Status -eq 'timeout') { return @{ Status = 'timeout'; Number = $null } }
    if ($prResult.Status -ne 'ok') { return @{ Status = 'unavailable'; Number = $null } }
    if ([string]::IsNullOrWhiteSpace($prResult.Output)) { return @{ Status = 'no-match'; Number = $null } }

    try {
        $prs = $prResult.Output | ConvertFrom-Json -ErrorAction Stop
    }
    catch { return @{ Status = 'unavailable'; Number = $null } }

    $prs = @($prs)
    if ($prs.Count -eq 0) { return @{ Status = 'no-match'; Number = $null } }

    $savedEap = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'
    try {
        $branchTip = Invoke-SCDNativeCommand { git rev-parse $Branch 2>$null }
        $tipExit = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $savedEap }
    if ($tipExit -ne 0 -or [string]::IsNullOrWhiteSpace($branchTip)) { return @{ Status = 'unavailable'; Number = $null } }
    $branchTip = $branchTip.Trim()

    foreach ($pr in $prs) {
        if ($pr.headRefOid -eq $branchTip) {
            return @{ Status = 'matched'; Number = $pr.number }
        }
    }
    return @{ Status = 'no-match'; Number = $null }
}

function Get-SCDIssueState {
    <#
    .SYNOPSIS
        --repo-pinned issue-state lookup (M6): `gh issue view <id> --repo
        <owner/repo> --json state`. Repo-pinning prevents a bare issue number
        from resolving against the wrong repository.
    .OUTPUTS
        Hashtable: @{ Status = 'ok'|'unavailable'|'timeout'; State = <string|$null> }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [long]$IssueId,

        [string]$Repo
    )

    $repoArg = if ($Repo) { $Repo } else { Get-SCDOriginRepo }
    if (-not $repoArg) { return @{ Status = 'unavailable'; State = $null } }

    $result = Invoke-SCDGhWithTimeout -ArgumentList @('issue', 'view', "$IssueId", '--repo', $repoArg, '--json', 'state')
    if ($result.Status -eq 'timeout') { return @{ Status = 'timeout'; State = $null } }
    if ($result.Status -ne 'ok') { return @{ Status = 'unavailable'; State = $null } }
    if ([string]::IsNullOrWhiteSpace($result.Output)) { return @{ Status = 'unavailable'; State = $null } }

    try {
        $issue = $result.Output | ConvertFrom-Json -ErrorAction Stop
    }
    catch { return @{ Status = 'unavailable'; State = $null } }

    return @{ Status = 'ok'; State = $issue.state }
}

function Test-SCDUniqueCommitsAllEmpty {
    <#
    .SYNOPSIS
        Issue #889 fix cycle, finding C: returns $true only when EVERY commit
        unique to $BranchName (relative to $RemoteDefaultRef) touched zero files —
        i.e. the unique-commit set is exclusively --allow-empty no-op commits.
        Used to withhold rung-2 tree-equivalence evidence from
        Test-WorktreeBranchRemovalEligible, which would otherwise be trivially
        TRUE for such a branch (no commit changed any file, so there is no diff
        against the default branch either) — fabricating "merged (tree-
        equivalent)" evidence for a branch that may still be about to receive
        real work. Mirrors the legacy Test-OrphanBranchCommitsAbsorbed's
        "if ($paths.Count -eq 0) { return $false }" empty-path rejection pattern.
    .OUTPUTS
        Tri-state [bool]/$null. $true on a confirmed all-empty unique-commit
        set; $false when at least one unique commit touched at least one path;
        $null when the determination could not be made at all (the `git log`
        invocation failed).

        Issue #922 (invariant I-5, decision D3): $null replaces the previous
        $false-on-failure return. The caller reads $false as "do not withhold
        the evidence" and immediately grants eligibility on it, so returning
        $false for a git failure fabricated tree-equivalence evidence out of an
        unrelated git error — the one path that violated this file's stated
        fail-direction intent ("any git or gh failure resolves toward NOT
        eligible (retain) — never eligible"). Callers must test for $null
        BEFORE testing `-not`, since `-not $null` is $true.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$BranchName,

        [Parameter(Mandatory)]
        [string]$RemoteDefaultRef
    )

    $savedEap = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'
    try {
        $logOutput = Invoke-SCDNativeCommand { git log --no-merges --pretty=format: --name-only "$RemoteDefaultRef..$BranchName" 2>$null }
        $logExit = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $savedEap }

    if ($logExit -ne 0) { return $null }

    foreach ($line in @($logOutput)) {
        if (-not [string]::IsNullOrWhiteSpace($line)) { return $false }
    }
    return $true
}

function Test-WorktreeBranchRemovalEligible {
    <#
    .SYNOPSIS
        Evidence-gated eligibility primitive (Issue #889 s1). Returns a closed
        tri-outcome result — eligible with named evidence, or not eligible with
        a ManualReviewReason drawn from the authoritative reason enum below.
        This is the single foundation primitive s2 (structural guarding), s3
        (executor rewiring), and s4 (detector gating) build on and call.
    .OUTPUTS
        Hashtable: @{ Eligible = <bool>; Evidence = <string|$null>;
                      ManualReviewReason = <string|$null>; Outcome = <string> }
    .NOTES
        Reason enum (single authoritative source, consumed verbatim by s2/s3/s4
        — see $script:WorktreeEligibilityReasons):
        'unmerged commits' | 'no issue number derivable' | 'issue #N still open' |
        "couldn't verify: gh unavailable" | "couldn't verify: gh timeout" |
        "couldn't verify: git signal failed" |
        "couldn't verify: no conclusive merge evidence"   (issue #922)

        Outcome enum ($script:WorktreeEligibilityOutcomes, issue #922):
        'eligible' | 'definitively-unmerged' | 'not-eligible'. Decision D4 renders
        'definitively-unmerged' silently; 'not-eligible' always renders its cause.

        Router:
          1. unique-commit count via `git rev-list <remoteDefaultRef>..<branch> --count`.
             Git failure -> retain, 'couldn't verify: git signal failed'.
          2. >=1 unique commit -> content-evidence merge verdict
             (Get-SCDBranchMergeVerdict, NO name-only gh fallback):
               'merged'                -> eligible, "merged into <ref> (<signal>)";
               'definitively-unmerged' -> not eligible, 'unmerged commits',
                                          outcome 'definitively-unmerged' (no gh spend);
               'undetermined'          -> OID-checked merged-PR-by-head ->
                                          eligible, "PR #N merged"; else not eligible,
                                          "couldn't verify: no conclusive merge evidence"
                                          (or the gathering-failure reason).
          3. 0 unique commits -> OID-checked merged-PR-by-head FIRST (D2 rung a);
             then derive issue id, and if derivable AND the issue is CLOSED ->
             eligible, "issue #N closed (no code changes)"; else not eligible
             with the appropriate reason.

        Any git/gh failure, timeout, $null, or malformed JSON resolves toward
        NOT eligible (retain) — never eligible.

        Non-goal: this primitive performs no structural (primary/current
        worktree) guarding — that is a separate shared helper (s2) called by
        the callers. It does not delete anything.

        Issue #922 (invariant I-2, decision D5): the router is split into
        Get-SCDFreeEligibilityEvidence (everything obtainable with no network
        cost) and Resolve-SCDPaidEligibility (the gh rungs). This function
        composes the two and keeps its original whole-evaluation contract for the
        cleanup executor; the detector calls the halves separately so it can run
        the free pass over EVERY candidate before ANY candidate spends gh budget.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$BranchName,

        [Parameter(Mandatory)]
        [string]$DefaultBranch,

        [string]$Repo
    )

    $free = Get-SCDFreeEligibilityEvidence -BranchName $BranchName -DefaultBranch $DefaultBranch
    if ($free.Resolved) { return $free.Result }
    return Resolve-SCDPaidEligibility -FreeEvidence $free -BranchName $BranchName -DefaultBranch $DefaultBranch -Repo $Repo
}

function Get-SCDFreeEligibilityEvidence {
    <#
    .SYNOPSIS
        Issue #922 (invariant I-2, decision D5): the network-free half of the
        eligibility router. Runs only local git, spends no gh budget, and either
        settles the candidate outright or reports which paid rung would settle it.
    .OUTPUTS
        Hashtable: @{
            Resolved      = <bool>    # $true when no gh call is needed at all
            Result        = @{ Eligible; Evidence; ManualReviewReason; Outcome }
            PaidRung      = 'rung2' | 'rung3' | $null
            PendingReason = <string|$null>   # the reason to report if the paid
                                             # rung finds no matching merged PR
        }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$BranchName,

        [Parameter(Mandatory)]
        [string]$DefaultBranch
    )

    $result = @{
        Eligible           = $false
        Evidence           = $null
        ManualReviewReason = $null
        # Issue #922 (I-3): the outcome travels alongside the reason so the
        # reporting layer never string-matches a reason to decide what renders.
        Outcome            = $script:WorktreeEligibilityOutcomes.NotEligible
    }
    $free = @{ Resolved = $true; Result = $result; PaidRung = $null; PendingReason = $null }
    $remoteDefault = Get-RemoteDefaultRef -DefaultBranch $DefaultBranch

    # Rung 1: unique-commit count (network-free, must run first)
    $savedEap = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'
    try {
        $countOutput = Invoke-SCDNativeCommand { git rev-list "$remoteDefault..$BranchName" --count 2>$null }
        $countExit = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $savedEap }

    if ($countExit -ne 0) {
        $result.ManualReviewReason = $script:WorktreeEligibilityReasons.GitSignalFailed
        return $free
    }

    # Finding I (#889 fix cycle): a successful (exit 0) but non-numeric or empty
    # `git rev-list --count` result must NOT silently default to 0 — that would
    # misroute an unparseable git signal into the zero-commit rung (rung 3) as if
    # it were a genuinely-verified zero-unique-commit branch. Require an explicit
    # successful parse before proceeding; any parse failure retains with the same
    # git-signal-failed reason as an outright rev-list exit failure.
    $uniqueCount = 0
    $countParsedOk = $false
    if ($countOutput) {
        $firstLine = (@($countOutput) | Select-Object -First 1)
        $countParsedOk = [int]::TryParse(("$firstLine").Trim(), [ref]$uniqueCount)
    }
    if (-not $countParsedOk) {
        $result.ManualReviewReason = $script:WorktreeEligibilityReasons.GitSignalFailed
        return $free
    }

    if ($uniqueCount -ge 1) {
        # Rung 2: git-only tree-equivalence first (never the name-only gh fallback — M4),
        # then the primitive's own OID-checked merged-PR-by-head rung.
        #
        # Issue #922 (I-5): a failure to gather evidence inside this rung must never
        # reach the rung's own 'unmerged commits' exit, which asserts a conclusive
        # negative. $evidenceGatheringFailed carries that distinction to the
        # no-match exit below.
        $evidenceGatheringFailed = $false
        $mergeVerdict = Get-SCDBranchMergeVerdict -BranchName $BranchName -DefaultBranch $DefaultBranch
        if ($mergeVerdict.Verdict -eq 'merged') {
            # Finding C (#889 fix cycle): a branch whose unique commits are
            # exclusively --allow-empty no-ops is trivially tree-equivalent by
            # definition (no commit changed any file) — do not accept that as
            # merge evidence; fall through to the OID-checked PR rung instead.
            $allUniqueCommitsEmpty = Test-SCDUniqueCommitsAllEmpty -BranchName $BranchName -RemoteDefaultRef $remoteDefault
            if ($null -eq $allUniqueCommitsEmpty) {
                # Issue #922 (I-5/AC7): the determination itself failed. Withhold the
                # tree-equivalence evidence rather than granting eligibility on it —
                # `-not $null` is $true, which is precisely how the pre-#922 form
                # fabricated "merged (tree-equivalent)" out of a `git log` error.
                $evidenceGatheringFailed = $true
            }
            elseif (-not $allUniqueCommitsEmpty) {
                $result.Eligible = $true
                $result.Outcome = $script:WorktreeEligibilityOutcomes.Eligible
                # Issue #922 Amendment A2.4: name the signal that actually fired.
                # The pre-#922 form was one unconditional assignment saying
                # "tree-equivalent" whichever signal established the verdict, so
                # the merge-tree-no-op shape — one of the two shapes AC1 mandates —
                # was reportable only by mislabelling its own evidence.
                $result.Evidence = "merged into $remoteDefault ($($mergeVerdict.Signal))"
                return $free
            }
        }
        elseif ($mergeVerdict.Verdict -eq 'definitively-unmerged') {
            # Issue #922 Amendment A2.1: conclusive content evidence that the branch
            # carries changes absent from the remote default.
            #
            # Amendment A3 (review of PR #950, findings M4/M6): this arm used to
            # settle here and skip the merged-pull-request rung, on the reasoning
            # that the rung is for candidates whose content evidence was
            # inconclusive. That was wrong, and it reproduced this issue's own
            # headline defect. merge-tree is merge-base-relative, so a branch that
            # SHIPPED and whose files main later deleted or renamed merges cleanly
            # and re-adds them — reading as definitively-unmerged. Decision D4 then
            # rendered it silently: a shipped worktree, dropped without a word,
            # which is Defect A with a new cause.
            #
            # The rescue costs D4's noise rationale nothing, because
            # Get-SCDMergedPrByHeadOid requires the merged PR's headRefOid to equal
            # the branch's CURRENT tip. A shipped branch whose tip has not moved
            # matches and is surfaced; an in-flight worktree has commits after its
            # PR (or no merged PR at all), gets no-match, and keeps the silent
            # outcome below. Amendment A1.3's "silence keys on the FINAL outcome,
            # never the intermediate verdict" is thereby honoured for this arm too
            # — it was the one arm still keying on the intermediate verdict.
            $free.Resolved = $false
            $free.PaidRung = 'rung2-negative'
            $free.PendingReason = $script:WorktreeEligibilityReasons.UnmergedCommits
            return $free
        }
        elseif ($mergeVerdict.Cause -eq $script:BranchMergeUndeterminedCauses.GitSignalFailed) {
            $evidenceGatheringFailed = $true
        }

        # Nothing free settles this candidate. Hand the paid rung the reason to
        # report if it finds no matching merged PR.
        #
        # Issue #922 (AC6/I-3): that reason is the INCONCLUSIVE one. The pre-#922
        # form reported 'unmerged commits' here, asserting a conclusive negative it
        # had not established — the conflation AC6 removes, and the steady state
        # for any worktree older than one merge. 'unmerged commits' is now
        # reachable only from the A2.1 verdict above. When the gathering itself
        # failed (I-5), the failure is reported instead.
        $free.Resolved = $false
        $free.PaidRung = 'rung2'
        $free.PendingReason = if ($evidenceGatheringFailed) {
            $script:WorktreeEligibilityReasons.GitSignalFailed
        }
        else {
            $script:WorktreeEligibilityReasons.InconclusiveMergeEvidence
        }
        return $free
    }

    # Rung 3: 0 unique commits. Nothing here is obtainable without gh — both the
    # OID-checked merged-PR lookup and the closed-issue derivation are network
    # calls — so the whole rung belongs to the paid phase.
    $free.Resolved = $false
    $free.PaidRung = 'rung3'
    return $free
}

function Resolve-SCDPaidEligibility {
    <#
    .SYNOPSIS
        Issue #922 (invariant I-2): the network-cost half of the eligibility
        router. Runs only for candidates Get-SCDFreeEligibilityEvidence could not
        settle locally, and only after the caller has decided the gh budget may
        be spent on this candidate.
    .OUTPUTS
        Hashtable: @{ Eligible; Evidence; ManualReviewReason; Outcome } — the same
        shape Test-WorktreeBranchRemovalEligible returns.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$FreeEvidence,

        [Parameter(Mandatory)]
        [string]$BranchName,

        [Parameter(Mandatory)]
        [string]$DefaultBranch,

        [string]$Repo
    )

    if ($FreeEvidence.Resolved) { return $FreeEvidence.Result }

    $result = $FreeEvidence.Result

    $pr = Get-SCDMergedPrByHeadOid -Branch $BranchName -DefaultBranch $DefaultBranch
    if ($pr.Status -eq 'matched') {
        $result.Eligible = $true
        $result.Outcome = $script:WorktreeEligibilityOutcomes.Eligible
        $result.Evidence = "PR #$($pr.Number) merged"
        return $result
    }

    if ($FreeEvidence.PaidRung -eq 'rung2-negative') {
        # Issue #922 Amendment A3: for a conclusively-negative candidate the
        # merged-pull-request lookup is a BEST-EFFORT rescue. Only a positive match
        # (handled above) can overturn the content evidence; every other status —
        # no-match, unavailable, timeout — leaves that evidence standing, and the
        # outcome silent per decision D4.
        #
        # This must be tested BEFORE the timeout and unavailable arms. Letting an
        # unreachable gh convert this candidate into a rendered
        # "couldn't verify: gh unavailable" line would put a manual-review line
        # against every in-flight worktree on any offline session — precisely the
        # permanent-noise condition D4 rejects by name, reintroduced through the
        # rescue meant to be free of it.
        $result.ManualReviewReason = $FreeEvidence.PendingReason
        $result.Outcome = $script:WorktreeEligibilityOutcomes.DefinitivelyUnmerged
        return $result
    }

    if ($pr.Status -eq 'timeout') {
        $result.ManualReviewReason = $script:WorktreeEligibilityReasons.GhTimeout
        return $result
    }
    if ($pr.Status -eq 'unavailable') {
        $result.ManualReviewReason = $script:WorktreeEligibilityReasons.GhUnavailable
        return $result
    }

    if ($FreeEvidence.PaidRung -eq 'rung2') {
        # 'no-match' — a same-name PR may exist but its headRefOid does not match
        # the current branch tip (M4's OID-mismatch guard), or no PR exists at all.
        $result.ManualReviewReason = $FreeEvidence.PendingReason
        return $result
    }

    if ($FreeEvidence.PaidRung -eq 'rung2-negative') {
        # Issue #922 Amendment A3: content evidence conclusively said "not merged"
        # and no merged pull request contradicted it at the branch's current tip.
        # NOW the outcome is final, and decision D4 renders it silently.
        $result.ManualReviewReason = $FreeEvidence.PendingReason
        $result.Outcome = $script:WorktreeEligibilityOutcomes.DefinitivelyUnmerged
        return $result
    }

    # Rung 3 'no-match' falls through to issue derivation.
    $issueId = Get-WorktreeBranchIssueId -BranchName $BranchName
    if (-not $issueId) {
        $result.ManualReviewReason = $script:WorktreeEligibilityReasons.NoIssueDerivable
        return $result
    }

    $issueState = Get-SCDIssueState -IssueId $issueId -Repo $Repo
    if ($issueState.Status -eq 'timeout') {
        $result.ManualReviewReason = $script:WorktreeEligibilityReasons.GhTimeout
        return $result
    }
    if ($issueState.Status -ne 'ok') {
        $result.ManualReviewReason = $script:WorktreeEligibilityReasons.GhUnavailable
        return $result
    }

    if ($issueState.State -eq 'CLOSED') {
        $result.Eligible = $true
        $result.Outcome = $script:WorktreeEligibilityOutcomes.Eligible
        $result.Evidence = "issue #$issueId closed (no code changes)"
        return $result
    }

    $result.ManualReviewReason = ($script:WorktreeEligibilityReasons.IssueStillOpen -f $issueId)
    return $result
}

# ===========================================================================
# Issue #889 s2 — removal-outcome diagnosis, pre-flight, shared primary-detection.
# Foundation consumed by s3 (executor rewiring) and s4 (detector gating).
# ===========================================================================

# Message-mapping table (Issue #889 s2, M24) — single authoritative source for
# the six Get-WorktreeRemovalOutcome literal messages. 'skipped-intact' is NOT
# a key here — that message is caller-synthesized by s3 on a pre-flight skip
# (no removal attempt made), not by this table. Consumed verbatim via
# Get-WorktreeRemovalOutcomeMessage below; do not introduce a differently-worded
# literal elsewhere.
$script:WorktreeRemovalOutcomeMessages = @{
    'removed'                         = 'removed {0}'
    'removed-partial-root-held'       = 'contents removed but the root directory was held by another process — the worktree is gone; an empty directory remains at {0}'
    'removed-partial-content-remains' = 'worktree unregistered but files remain at {0} (a process is holding content) — inspect manually'
    'stale-registration'              = 'removing stale registration — directory already gone at {0}'
    'failed'                          = 'could not remove {0} ({1})'
    'verification-indeterminate'      = 'could not verify the final state — inspect manually at {0}'
}

function ConvertTo-SCDPathForComparison {
    <#
    .SYNOPSIS
        Issue #889 fix cycle, finding E: resolves $Path through
        [System.IO.Path]::GetFullPath before the slash/case-insensitive
        comparison Test-WorktreeIsPrimary performs, matching the same
        resolution the detector's own ConvertTo-SCDNormalizedPath
        (session-cleanup-detector-core.ps1) already applies two files over. A
        lexical-only comparison (backslash/case/trailing-separator
        normalization alone, with no path resolution) cannot detect two
        paths that name the SAME directory via a relative segment, a
        trailing '.', or other path forms GetFullPath collapses to an
        identical string.
    .OUTPUTS
        [string] forward-slash-normalized, trailing-slash-trimmed absolute
        path, or the lexically-normalized (non-resolved) input on any
        GetFullPath failure — never throws.
    #>
    [CmdletBinding()]
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }

    try {
        return [System.IO.Path]::GetFullPath($Path).Replace('\', '/').TrimEnd('/')
    }
    catch {
        return $Path.Replace('\', '/').TrimEnd('/')
    }
}

function Test-WorktreeIsPrimary {
    <#
    .SYNOPSIS
        Shared primary-worktree guard (Issue #889 s2, M3/AC2). Returns $true
        when $WorktreePath is the FIRST `git worktree list --porcelain`
        record — the main worktree (or, in bare-main layouts, the bare
        record #1, which is likewise never removable — no special-casing is
        needed beyond "first record wins" since that record's path is
        compared the same way). Both the detector (s4) and the executor (s3)
        call this SAME implementation so the primary guard cannot diverge
        across call sites — this closes the exact 2026-07-20 incident gap
        where the primary checkout could be offered for deletion.
    .NOTES
        Self-contained porcelain parsing: git-helpers.ps1 is dot-sourced by
        the executor WITHOUT session-cleanup-detector-core.ps1
        (post-merge-cleanup.ps1 sources only this file), so this cannot
        delegate to that file's Get-SCDWorktreeRecords — only the first
        record is needed here, so a lightweight first-record parse is used
        instead of a full record-list parser.
        Perf note (finding F, #889 fix cycle, LOW/deferred): this function
        re-spawns `git worktree list --porcelain` on every call, including
        once per sibling-worktree record when a caller (e.g. the detector's
        Get-SCDSiblingWorktreeCleanups loop, or post-merge-cleanup.ps1's
        per-worktree Remove-SiblingWorktree/Test-WorktreeRemovalPreflight
        calls) iterates a candidate list. Callers that already hold parsed
        worktree records for their own purposes could pass them through
        instead of re-invoking git per record. Not changed here: doing so
        cleanly would widen this function's signature (or add an overload)
        across every s2/s3/s4 call site, and the added complexity is not
        justified by a real-world worktree-count scale where a handful of
        redundant `git worktree list` invocations per cleanup run is
        immaterial. Left as a documented perf note per judge guidance rather
        than a signature change.
        Fail-safe direction: any porcelain-probe failure (non-zero exit,
        empty output, unparseable first record) returns $true — treat as
        primary when unprovable. A guard whose purpose is "never remove the
        primary worktree" must never resolve an indeterminate check toward
        "not primary".
    .OUTPUTS
        [bool]
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$WorktreePath
    )

    $savedEap = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'
    try {
        $porcelainOutput = Invoke-SCDNativeCommand { git worktree list --porcelain 2>$null }
        $exitCode = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $savedEap }

    if ($exitCode -ne 0 -or -not $porcelainOutput) {
        return $true
    }

    $porcelainText = ((@($porcelainOutput) -join "`n") -replace "`r`n", "`n" -replace "`r", "`n").Trim()
    if ([string]::IsNullOrWhiteSpace($porcelainText)) {
        return $true
    }

    $firstRecordText = ([regex]::Split($porcelainText, "`n\s*`n"))[0]
    if ([string]::IsNullOrWhiteSpace($firstRecordText)) {
        return $true
    }

    $firstRecordLines = @($firstRecordText -split "`n" | ForEach-Object { $_.TrimEnd() })
    $worktreeLine = $firstRecordLines | Where-Object { $_ -like 'worktree *' } | Select-Object -First 1
    if ([string]::IsNullOrWhiteSpace($worktreeLine)) {
        # Unparseable first record — cannot prove this ISN'T primary (fail-safe).
        return $true
    }

    $firstWorktreePath = $worktreeLine.Substring('worktree '.Length)
    $normFirst = ConvertTo-SCDPathForComparison -Path $firstWorktreePath
    $normTarget = ConvertTo-SCDPathForComparison -Path $WorktreePath

    return [string]::Equals($normFirst, $normTarget, [System.StringComparison]::OrdinalIgnoreCase)
}

function Get-WorktreeRemovalOutcome {
    <#
    .SYNOPSIS
        Pure post-removal-attempt diagnosis over injected probes (Issue #889
        s2, M5). Returns exactly one closed-enum outcome value describing the
        VERIFIED post-state of a worktree-removal attempt, covering the full
        registered x {absent,empty,non-empty} matrix — no post-state
        force-fits. This is the honesty-fix core of the whole issue: it
        replaces the old Test-Path+porcelain-scan inference that produced a
        false "skipping" message for a worktree a removal attempt had
        already partially destroyed.
    .NOTES
        Pure over injected probes ONLY — this function makes no git/fs calls
        itself — so fixtures can simulate the non-atomic held-directory
        post-states that CI cannot produce for real (holding a directory
        open across a test process). 'skipped-intact' is NOT a return value
        of this function; it is caller-synthesized by the executor (s3) on a
        pre-flight skip, where no removal attempt was made at all.
    .PARAMETER WorktreePath
        The worktree path a removal was attempted against. Not used in the
        outcome derivation itself (which depends only on the two probes) —
        carried through for caller-side message formatting/logging.
    .PARAMETER RemovalExitCode
        The exit code from the `git worktree remove` attempt. Not used in
        the outcome derivation itself: a non-atomic partial removal can
        exit non-zero OR zero depending on what failed, so the verified
        probe results below — not the exit code — determine the outcome.
        Carried through for caller-side diagnostics.
    .PARAMETER PorcelainRegistrationProbe
        Scriptblock, no arguments, closing over the target path: returns
        $true (still registered in `git worktree list`), $false (not
        registered), or $null (probe error).
    .PARAMETER FileSystemProbe
        Scriptblock, no arguments, closing over the target path: returns
        'absent', 'empty', 'non-empty', or $null (probe error).
    .OUTPUTS
        [string] one of: 'removed' | 'removed-partial-root-held' |
        'removed-partial-content-remains' | 'stale-registration' | 'failed' |
        'verification-indeterminate'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$WorktreePath,

        [Parameter(Mandatory)]
        [AllowNull()]
        [Nullable[int]]$RemovalExitCode,

        [Parameter(Mandatory)]
        [scriptblock]$PorcelainRegistrationProbe,

        [Parameter(Mandatory)]
        [scriptblock]$FileSystemProbe
    )

    $registered = & $PorcelainRegistrationProbe
    $fsState = & $FileSystemProbe

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

function Get-WorktreeRemovalOutcomeMessage {
    <#
    .SYNOPSIS
        Formats the literal removal-outcome message for a
        Get-WorktreeRemovalOutcome value (Issue #889 s2, M24). Single
        authoritative mapping ($script:WorktreeRemovalOutcomeMessages above)
        — consumed by s3 so the executor's removal-reporting text matches
        the verified post-state exactly, word for word.
    .OUTPUTS
        [string]
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('removed', 'removed-partial-root-held', 'removed-partial-content-remains', 'stale-registration', 'failed', 'verification-indeterminate')]
        [string]$Outcome,

        [Parameter(Mandatory)]
        [string]$WorktreePath,

        [string]$Detail = 'see stderr for details'
    )

    $template = $script:WorktreeRemovalOutcomeMessages[$Outcome]
    return ($template -f $WorktreePath, $Detail)
}

function Test-WorktreeRemovalPreflight {
    <#
    .SYNOPSIS
        Skip-before-attempt decision (Issue #889 s2, M12/M14/AC5). Returns a
        skip decision + reason evaluated BEFORE any destructive `git
        worktree remove` call is made — never after. Skip is the fail-safe
        direction: any of the preflight's OWN probe failures (dirty-check
        errors, unreadable path — the wiped/held-dir incident condition)
        resolve toward skip, never toward "attempt".
    .NOTES
        Locked/Prunable state is supplied by the caller (s3), which already
        parses `git worktree list --porcelain` block flags for its own
        purposes (post-merge-cleanup.ps1:197-268) — this function does not
        re-implement that porcelain block scan; it only runs the `git -C
        <path> status --porcelain` dirty probe and calls the shared
        Test-WorktreeIsPrimary guard.
        M14 qualified predicate: locked-AND-NOT-prunable skips HERE with
        reason 'locked'. Locked-AND-prunable is intentionally NOT skipped at
        preflight — it falls through so s3's D5 (#522) Test-Path-verified
        clause can still clear a stale registration whose directory is
        confirmed gone, or route a dir-present case to manual review there.
        Reason values ('primary' | 'locked' | 'dirty' | "couldn't verify
        preflight state") are short literals the executor (s3) embeds inside
        its own "skipped-intact ({reason})" wrapper message — this function
        does not itself format the path-carrying user-facing sentence.
    .OUTPUTS
        Hashtable: @{ Skip = <bool>; Reason = <string|$null> }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$WorktreePath,

        [bool]$IsLocked = $false,

        [bool]$IsPrunable = $false
    )

    # Primary/current identity — the shared structural guard, checked first
    # regardless of lock/dirty state (AC2 must hold unconditionally).
    if (Test-WorktreeIsPrimary -WorktreePath $WorktreePath) {
        return @{ Skip = $true; Reason = 'primary' }
    }

    # Locked-and-not-prunable (M14 qualified predicate).
    if ($IsLocked -and -not $IsPrunable) {
        return @{ Skip = $true; Reason = 'locked' }
    }

    # Dirty check — the preflight's OWN probe. Any probe error/unreadable
    # path (the wiped/held-dir incident condition) is own-probe-error (M12):
    # skip-without-attempt, never fall through to "attempt".
    $savedEap = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'
    try {
        $statusOutput = Invoke-SCDNativeCommand { git -C $WorktreePath status --porcelain 2>$null }
        $statusExit = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $savedEap }

    if ($statusExit -ne 0) {
        return @{ Skip = $true; Reason = "couldn't verify preflight state" }
    }

    if (-not [string]::IsNullOrWhiteSpace((@($statusOutput) -join "`n"))) {
        return @{ Skip = $true; Reason = 'dirty' }
    }

    return @{ Skip = $false; Reason = $null }
}