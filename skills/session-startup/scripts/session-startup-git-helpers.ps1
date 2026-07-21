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
    UnmergedCommits    = 'unmerged commits'
    NoIssueDerivable   = 'no issue number derivable'
    IssueStillOpen     = "issue #{0} still open"
    GhUnavailable      = "couldn't verify: gh unavailable"
    GhTimeout          = "couldn't verify: gh timeout"
    GitSignalFailed    = "couldn't verify: git signal failed"
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
    return "origin/$DefaultBranch"
}

function Test-BranchTreeEquivalentToDefault {
    <#
    .SYNOPSIS
        Git-only merged-detection (Issue #889 M4): tree-equivalence, accumulated-squash
        merge-tree no-op, and git-cherry patch-equivalence — with NO gh fallback.
        Extracted from Test-BranchMergedIntoDefault so the eligibility primitive
        (Test-WorktreeBranchRemovalEligible) can call a purely git-only merged
        check that never risks the name-only gh pr list fallback's false
        "tree-equivalent" evidence for a branch that only shares a name with an
        unrelated merged PR.
    .OUTPUTS
        Tri-state [bool]/$null, matching this file's existing tri-state
        convention (e.g. Test-OrphanBranchGitHubSignalsShipped): $true when
        git-only signals show the branch is merged/absorbed; $false when git
        cherry ran successfully and shows the branch is definitively NOT
        merged (a conclusive git-only answer — callers must not fall back to
        a name-only gh lookup in this case, since it would be redundant with
        a definitive git-only "no"); $null when every git-only signal was
        inconclusive (git cherry itself failed) and the caller should attempt
        an independent fallback (gh pr list, or an OID-checked PR match).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$BranchName,

        [Parameter(Mandatory)]
        [string]$DefaultBranch
    )

    $remoteDefault = Get-RemoteDefaultRef -DefaultBranch $DefaultBranch

    # Primary: tree-equivalence check (AC1/AC6) — catches squash-merged branches
    # whose tip content is identical to the remote default even when commit history differs.
    $savedEap = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'
    try {
        Invoke-SCDNativeCommand { git diff --quiet --ignore-cr-at-eol $remoteDefault $BranchName 2>$null }
        $diffExit = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $savedEap }
    if ($diffExit -eq 0) { return $true }

    # Accumulated squash branch: if merging the branch into the current default
    # would produce the same tree, cleanup is still safe after default advances.
    $savedEap = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'
    try {
        $mergeTreeOutput = @(Invoke-SCDNativeCommand { git merge-tree --write-tree $remoteDefault $BranchName 2>$null })
        $mergeTreeExit = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $savedEap }
    if ($mergeTreeExit -eq 0) {
        $mergedTree = @($mergeTreeOutput | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1)
        if ($mergedTree.Count -gt 0) {
            $mergedTreeOid = $mergedTree[0].Trim()
            $savedEap = $ErrorActionPreference
            $ErrorActionPreference = 'SilentlyContinue'
            try {
                Invoke-SCDNativeCommand { git diff --quiet --ignore-cr-at-eol $remoteDefault $mergedTreeOid 2>$null }
                $mergedTreeDiffExit = $LASTEXITCODE
            }
            finally { $ErrorActionPreference = $savedEap }
            if ($mergedTreeDiffExit -eq 0) { return $true }
        }
    }

    # Secondary: git cherry against the resolved remote default ref (G1)
    $savedEap = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'
    try {
        $cherryOutput = Invoke-SCDNativeCommand { git cherry $remoteDefault $BranchName 2>$null }
        $cherryExit = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $savedEap }
    if ($cherryExit -eq 0) {
        # C4: cherry prefixes lines with '+' (not in upstream) or '-' (patch-equivalent
        # already in upstream). Branch is merged when there are NO '+' lines.
        # (Empty stdout is the trivial subset of "no '+' lines".)
        $unmergedLines = @($cherryOutput | Where-Object { $_ -match '^\+\s' })
        return ($unmergedLines.Count -eq 0)
    }

    # git cherry itself failed: every git-only signal was inconclusive. Return
    # $null (not $false) so the caller can distinguish "definitively unmerged"
    # from "no git-only answer" and decide whether an independent fallback
    # (gh pr list, or an OID-checked PR match) is warranted.
    return $null
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
        # unmerged commits) — do not fall through to the name-only gh lookup,
        # preserving this function's original short-circuit behavior.
        return $treeEquivalent
    }

    # Fallback: gh pr list (name-only — retained here for this function's existing
    # callers; Test-WorktreeBranchRemovalEligible does NOT use this fallback and
    # instead performs its own OID-checked PR match — see Get-SCDMergedPrByHeadOid).
    if (Get-Command gh -ErrorAction SilentlyContinue) {
        $prJson = Invoke-SCDNativeCommand { gh pr list --head $BranchName --base $DefaultBranch --state merged --json number 2>$null }
        if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($prJson)) {
            try {
                $prs = $prJson | ConvertFrom-Json -ErrorAction Stop
                return ($prs.Count -gt 0)
            }
            catch { }
        }
    }

    # Conservative: treat as unmerged for safety
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

function Test-WorktreeBranchRemovalEligible {
    <#
    .SYNOPSIS
        Evidence-gated eligibility primitive (Issue #889 s1). Returns a closed
        tri-outcome result — eligible with named evidence, or not eligible with
        a ManualReviewReason drawn from the authoritative reason enum below.
        This is the single foundation primitive s2 (structural guarding), s3
        (executor rewiring), and s4 (detector gating) build on and call.
    .OUTPUTS
        Hashtable: @{ Eligible = <bool>; Evidence = <string|$null>; ManualReviewReason = <string|$null> }
    .NOTES
        Reason enum (single authoritative source, consumed verbatim by s2/s3/s4
        — see $script:WorktreeEligibilityReasons):
        'unmerged commits' | 'no issue number derivable' | 'issue #N still open' |
        "couldn't verify: gh unavailable" | "couldn't verify: gh timeout" |
        "couldn't verify: git signal failed"

        Router:
          1. unique-commit count via `git rev-list <remoteDefaultRef>..<branch> --count`.
             Git failure -> retain, 'couldn't verify: git signal failed'.
          2. >=1 unique commit -> git-only tree-equivalence (Test-BranchTreeEquivalentToDefault,
             NO name-only gh fallback) -> eligible, "merged into <ref> (tree-equivalent)";
             else OID-checked merged-PR-by-head -> eligible, "PR #N merged";
             else not eligible, 'unmerged commits'.
          3. 0 unique commits -> OID-checked merged-PR-by-head FIRST (D2 rung a);
             then derive issue id, and if derivable AND the issue is CLOSED ->
             eligible, "issue #N closed (no code changes)"; else not eligible
             with the appropriate reason.

        Any git/gh failure, timeout, $null, or malformed JSON resolves toward
        NOT eligible (retain) — never eligible.

        Non-goal: this primitive performs no structural (primary/current
        worktree) guarding — that is a separate shared helper (s2) called by
        the callers. It does not delete anything.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$BranchName,

        [Parameter(Mandatory)]
        [string]$DefaultBranch,

        [string]$Repo
    )

    $result = @{ Eligible = $false; Evidence = $null; ManualReviewReason = $null }
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
        return $result
    }

    $uniqueCount = 0
    if ($countOutput) {
        $firstLine = (@($countOutput) | Select-Object -First 1)
        [void][int]::TryParse(("$firstLine").Trim(), [ref]$uniqueCount)
    }

    if ($uniqueCount -ge 1) {
        # Rung 2: git-only tree-equivalence first (never the name-only gh fallback — M4),
        # then the primitive's own OID-checked merged-PR-by-head rung.
        if (Test-BranchTreeEquivalentToDefault -BranchName $BranchName -DefaultBranch $DefaultBranch) {
            $result.Eligible = $true
            $result.Evidence = "merged into $remoteDefault (tree-equivalent)"
            return $result
        }

        $pr = Get-SCDMergedPrByHeadOid -Branch $BranchName -DefaultBranch $DefaultBranch
        if ($pr.Status -eq 'matched') {
            $result.Eligible = $true
            $result.Evidence = "PR #$($pr.Number) merged"
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
        # 'no-match' — a same-name PR may exist but its headRefOid does not match
        # the current branch tip (M4's OID-mismatch guard), or no PR exists at all.
        $result.ManualReviewReason = $script:WorktreeEligibilityReasons.UnmergedCommits
        return $result
    }

    # Rung 3: 0 unique commits — OID-checked merged-PR-by-head FIRST (D2 rung a),
    # then closed-issue derivation.
    $pr = Get-SCDMergedPrByHeadOid -Branch $BranchName -DefaultBranch $DefaultBranch
    if ($pr.Status -eq 'matched') {
        $result.Eligible = $true
        $result.Evidence = "PR #$($pr.Number) merged"
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

    # 'no-match' falls through to issue derivation.
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
        $result.Evidence = "issue #$issueId closed (no code changes)"
        return $result
    }

    $result.ManualReviewReason = ($script:WorktreeEligibilityReasons.IssueStillOpen -f $issueId)
    return $result
}