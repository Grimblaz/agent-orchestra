#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Post-merge cleanup for tracking files and feature branches.

.DESCRIPTION
    Archives all files under .copilot-tracking/ into a dated issue context
    folder, cleans empty tracking directories, and removes the feature branch
    locally/remotely.

    Supports both manual invocation and SessionStart hook-driven invocation.

.EXAMPLE
    # Parameterized (explicit)
    pwsh skills/session-startup/scripts/post-merge-cleanup.ps1 -IssueNumber 36 -FeatureBranch "feature/issue-36-janitor-to-hook"

.EXAMPLE
    # With GitHub CLI (close issue via gh)
    pwsh skills/session-startup/scripts/post-merge-cleanup.ps1 -IssueNumber 36 -FeatureBranch "feature/issue-36-janitor-to-hook" -UseGh
#>

[CmdletBinding()]
param(
    [Parameter()]
    [Nullable[int]]$IssueNumber = $null,

    [Parameter()]
    [string]$FeatureBranch = '',

    [Parameter()]
    [int]$PrNumber,

    [Parameter()]
    [string]$Repo,

    [switch]$UseGh,

    [switch]$SkipRemoteDelete,

    [switch]$SkipLocalDelete,

    [switch]$SkipGitUpdate,

    [Parameter()]
    [string[]]$OrphanBranches = @(),

    [Parameter()]
    [string[]]$SiblingWorktrees = @(),

    [Parameter()]
    [string[]]$UntaggedTrackingFiles = @(),

    [Parameter()]
    [string]$TmpRoot = ''
)

$ErrorActionPreference = 'Stop'

. "$PSScriptRoot/session-startup-git-helpers.ps1"
if (-not (Get-Command Get-SCDPersistentTrackingExclusions -ErrorAction SilentlyContinue)) {
    Write-Error "HALT: Get-SCDPersistentTrackingExclusions is not defined after loading session-startup-git-helpers.ps1. Aborting executor to prevent destruction of persistent tracking files. (mf6-executor-failsafe)"
    exit 1
}
$persistentExclusions = Get-SCDPersistentTrackingExclusions
if ($null -eq $persistentExclusions -or $null -eq $persistentExclusions.Filenames) {
    Write-Error "HALT: Get-SCDPersistentTrackingExclusions returned null or missing Filenames — registry integrity failure. Aborting executor to prevent destruction of persistent tracking files. (mf6-executor-failsafe)"
    exit 1
}
$script:PersistentTrackingFilenames = [string[]]$persistentExclusions.Filenames

# Guard: require IssueNumber, FeatureBranch, OR at least one of the new category parameters
# (C6/C1: -FeatureBranch alone is sufficient — used by detector for no-issue-id stale branches
#  so the no-issue-id path can also flow through this composite script instead of raw git.)
if ($null -eq $IssueNumber -and
    [string]::IsNullOrWhiteSpace($FeatureBranch) -and
    $OrphanBranches.Count -eq 0 -and
    $SiblingWorktrees.Count -eq 0 -and
    $UntaggedTrackingFiles.Count -eq 0 -and
    [string]::IsNullOrWhiteSpace($TmpRoot)) {
    Write-Error "Must specify -IssueNumber, -FeatureBranch, or at least one of -OrphanBranches, -SiblingWorktrees, -UntaggedTrackingFiles, -TmpRoot."
    exit 1
}

# Warn about -TmpRoot-only (scratch clearing requires -IssueNumber)
if (-not [string]::IsNullOrWhiteSpace($TmpRoot) -and $null -eq $IssueNumber) {
    Write-Warning "-TmpRoot supplied without -IssueNumber; no scratch files will be cleared."
}

function Remove-EmptyDirectory {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([string]$Root)
    if (-not (Test-Path $Root)) { return }
    Get-ChildItem -Path $Root -Recurse -Directory |
        Sort-Object FullName -Descending |
        ForEach-Object {
            $hasFiles = Get-ChildItem -Path $_.FullName -Recurse -File -ErrorAction SilentlyContinue
            if (-not $hasFiles -and $PSCmdlet.ShouldProcess($_.FullName, 'Remove empty directory')) {
                Remove-Item -LiteralPath $_.FullName -Force
            }
        }
}

function Remove-OrphanBranch {
    <#
    .NOTES
        Issue #889 s3 deviation: an earlier version of this slice replaced this
        function's internals with a call to the shared Test-WorktreeBranchRemovalEligible
        primitive (mirroring Remove-SiblingWorktree). That broke two pre-existing,
        real-git-backed test suites this executor did not know about at dispatch
        time: post-merge-cleanup-squash-merge.Tests.ps1 (issue #513/#548 — rebase-merge
        patch-equivalence, plain merge-commit, CR-EOL, spike-only, tree-at-HEAD, and
        ancestor auto-resolve sub-cases the shared primitive does not fully replicate)
        and script-wording-contract.Tests.ps1 (a static contract asserting this
        function's body contains the exact 'auto-resolve declined' / 'could not
        verify auto-resolve signals' / 'branch not reachable from default
        (merged-state re-check returned false)' skip-variant wording). Reverted to
        the original Test-BranchMergedIntoDefault + Test-OrphanBranchAutoResolveEligible
        chain for the >=1-unique-commit case (below), which already re-verifies live
        at destroy-time (not stale detector state) and preserves the richer
        Test-OrphanBranchCommitsAbsorbed absorption logic (squash/rebase/patch-
        equivalence/CR-EOL/spike-only) #513/#548 depend on.

        Post-revert follow-up: Test-BranchMergedIntoDefault's primary signal is git
        tree-equivalence (`git diff --quiet` against the default branch), which is
        trivially TRUE for any zero-unique-commit branch by definition — no commits
        means no diff, regardless of actual GitHub evidence. Left unguarded, that
        let a zero-commit claude/* orphan branch (an in-progress branch whose only
        "work" lives in GitHub issue comments, not commits — exactly the #889
        scenario) fall straight through to delete without ever reaching evidence
        checks. The unique-commit-count gate below routes that case through the
        shared Test-WorktreeBranchRemovalEligible primitive instead (OID-checked-PR-
        first, then closed-issue evidence) BEFORE Test-BranchMergedIntoDefault is
        ever called, since its tree-equivalence signal is meaningless here.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Branch,

        [Parameter(Mandatory)]
        [string]$DefaultBranch,

        [ref]$DeletedCount,

        [System.Collections.Generic.List[string]]$DeletedNames
    )

    if ($Branch -eq $DefaultBranch) {
        Write-Warning "Remove-OrphanBranch: Refusing to delete default branch '$Branch'."
        return
    }

    # Rung 1 (mirrors Test-WorktreeBranchRemovalEligible's own rung 1, s1): gate on
    # unique-commit count BEFORE ever calling Test-BranchMergedIntoDefault. A git
    # rev-list failure does not confirm zero — fall through to the existing >=1
    # chain below, which already fails closed on its own probes.
    #
    # M1 (post-dispatch discovery, flagged for coordinator review): a zero unique-
    # commit count is mathematically IDENTICAL to `git merge-base --is-ancestor
    # $Branch $DefaultBranch` — rev-list A..B --count is by definition "commits
    # reachable from B not reachable from A", so 0 means B is fully contained in
    # A's history. There is therefore NO git-only signal that can distinguish a
    # genuinely-absorbed zero-commit branch (safe) from a freshly-created,
    # about-to-receive-real-work branch (the actual #889 risk) — verified empirically
    # against a real `--no-ff` merge fixture. Routing every zero-count branch through
    # the evidence-only primitive would therefore make ANY unrecognized-name-pattern
    # branch permanently unresolvable without GitHub evidence, even when no GitHub
    # evidence could ever exist for it (no derivable issue id) — breaking
    # post-merge-cleanup-squash-merge.Tests.ps1's "plain merge-commit"/"empty orphan"
    # fixtures, which assert zero gh calls for non-session-tracked branch names.
    # Narrowed the gate to only recognized session-branch naming conventions
    # (feature/issue-N-*, claude/*-N-hex) — the only shapes the shared primitive can
    # actually derive PR/issue evidence for, and the only shapes #889's own defect
    # scenario (an in-progress claude/* branch) can occur under. Unrecognized names
    # keep the original git-only ancestry-based #513/#548 behavior unchanged.
    $remoteDefaultForCount = Get-RemoteDefaultRef -DefaultBranch $DefaultBranch
    $savedEap = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'
    try {
        $countOutput = Invoke-SCDNativeCommand { git rev-list "$remoteDefaultForCount..$Branch" --count 2>$null }
        $countExit = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $savedEap }

    # Finding I (#889 fix cycle): a non-numeric (or empty) rev-list --count result
    # despite exit 0 must not silently default to "0 unique commits" — that would
    # incorrectly route a genuinely-unparseable git signal through the
    # primitive's zero-commit rung as if verified zero. Track parse success
    # explicitly; a parse failure falls through to the existing >=1 chain below
    # (same "a git rev-list failure does not confirm zero" fail-closed intent
    # already documented above for the countExit-nonzero case).
    $uniqueCount = 0
    $countParsedOk = $false
    if ($countExit -eq 0 -and $countOutput) {
        $firstLine = (@($countOutput) | Select-Object -First 1)
        $countParsedOk = [int]::TryParse(("$firstLine").Trim(), [ref]$uniqueCount)
    }

    $derivedIssueId = Get-WorktreeBranchIssueId -BranchName $Branch

    if ($countExit -eq 0 -and $countParsedOk -and $uniqueCount -eq 0 -and $derivedIssueId) {
        $eligibility = Test-WorktreeBranchRemovalEligible -BranchName $Branch -DefaultBranch $DefaultBranch
        if (-not $eligibility.Eligible) {
            Write-Output "Skipped '$Branch' — $($eligibility.ManualReviewReason) — review before deleting"
            return
        }
        Write-Output "Removing branch '$Branch' — eligible: $($eligibility.Evidence)"
        Invoke-SCDNativeCommand { git branch -D $Branch 2>$null }
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "Failed to delete orphan branch '$Branch' (exit $LASTEXITCODE)"
            return
        }
        $DeletedCount.Value++
        $DeletedNames.Add($Branch)
        return
    }

    $isMerged = Test-BranchMergedIntoDefault -BranchName $Branch -DefaultBranch $DefaultBranch
    $autoResolveApproved = $false
    if (-not $isMerged) {
        $autoResolve = Test-OrphanBranchAutoResolveEligible -Branch $Branch -DefaultBranch $DefaultBranch
        switch ($autoResolve) {
            $true { $autoResolveApproved = $true } # fall through to delete via -D
            $null {
                Write-Output "Skipped '$Branch' — could not verify auto-resolve signals — review before deleting"
                return
            }
            default {
                Write-Output "Skipped '$Branch' — auto-resolve declined — review before deleting"
                return
            }
        }
    }

    if ($autoResolveApproved) {
        # Auto-resolve path: commits are absorbed per GitHub signals; use -D directly
        Invoke-SCDNativeCommand { git branch -D $Branch 2>$null }
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "Failed to delete orphan branch '$Branch' (exit $LASTEXITCODE)"
            return
        }
    }
    else {
        # Prefer -d (safe); escalate to -D only after re-confirming merged
        Invoke-SCDNativeCommand { git branch -d $Branch 2>$null }
        if ($LASTEXITCODE -ne 0) {
            # Re-confirm still merged before forcing
            if (Test-BranchMergedIntoDefault -BranchName $Branch -DefaultBranch $DefaultBranch) {
                Invoke-SCDNativeCommand { git branch -D $Branch 2>$null }
                if ($LASTEXITCODE -ne 0) {
                    Write-Warning "Failed to delete orphan branch '$Branch' (exit $LASTEXITCODE)"
                    return
                }
            }
            else {
                Write-Output "Skipped '$Branch' — branch not reachable from default (merged-state re-check returned false) — review before deleting"
                return
            }
        }
    }

    $DeletedCount.Value++
    $DeletedNames.Add($Branch)
}

function Get-WorktreePorcelainBlock {
    <#
    .SYNOPSIS
        Returns the `git worktree list --porcelain` block matching $WorktreePath,
        or $null when no block matches or the porcelain listing itself failed.
        Shared parsing helper for branch resolution + locked/prunable scan (Issue #889 s3).
    .NOTES
        Deliberately does NOT split records on the blank-line separator porcelain
        normally uses between them: PowerShell's own native-command output capture
        can silently collapse a genuinely blank line out of multi-line stdout
        (observed on Windows), which would merge every record into one and make a
        non-first record unfindable. Instead, each line matching `^worktree\s` is
        treated as the start of a new record — robust regardless of whether blank
        separators survive the capture round-trip.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$WorktreePath)

    $porcelain = Invoke-SCDNativeCommand { git worktree list --porcelain 2>$null }
    if ($LASTEXITCODE -ne 0 -or -not $porcelain) { return $null }

    $allLines = @(($porcelain -join "`n") -split "`r?`n")
    $normTarget = $WorktreePath.Replace('\', '/').TrimEnd('/')

    # Single-pass state machine: a record starts at a `worktree ` line and ends
    # at the next `worktree ` line, a blank line, or end-of-input — whichever
    # comes first. Once the matched record ends (by any of those three), stop.
    $currentLines = [System.Collections.Generic.List[string]]::new()
    $isMatch = $false
    foreach ($line in $allLines) {
        $isRecordStart = $line -match '^worktree\s+(.+)$'
        $isBlank = -not $isRecordStart -and [string]::IsNullOrWhiteSpace($line)

        if (($isRecordStart -or $isBlank) -and $currentLines.Count -gt 0) {
            if ($isMatch) { return ($currentLines -join "`n") }
            $currentLines = [System.Collections.Generic.List[string]]::new()
            $isMatch = $false
        }

        if ($isRecordStart) {
            $blockPath = $Matches[1].Trim()
            $normBlock = $blockPath.Replace('\', '/').TrimEnd('/')
            $isMatch = [string]::Equals($normBlock, $normTarget, [System.StringComparison]::OrdinalIgnoreCase)
            $currentLines.Add($line)
        }
        elseif (-not $isBlank -and $currentLines.Count -gt 0) {
            $currentLines.Add($line)
        }
    }
    if ($isMatch -and $currentLines.Count -gt 0) { return ($currentLines -join "`n") }
    return $null
}

function Remove-SiblingWorktree {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$WorktreePath,

        [Parameter(Mandatory)]
        [string]$DefaultBranch,

        [ref]$DeletedCount,

        [System.Collections.Generic.List[string]]$DeletedPaths,

        [System.Collections.Generic.List[string]]$DeletedOutcomes,

        [string]$Repo
    )

    # G2: Resolve branch name. Try the in-worktree query first; fall back to the
    # porcelain worktree list if the directory is missing or detached (prunable).
    $worktreeBranch = Invoke-SCDNativeCommand { git -C $WorktreePath branch --show-current 2>$null }
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($worktreeBranch)) {
        $matchedBlock = Get-WorktreePorcelainBlock -WorktreePath $WorktreePath
        if ($matchedBlock) {
            $blockLines = $matchedBlock -split "`r?`n"
            $branchLine = ($blockLines | Where-Object { $_ -match '^branch\s+refs/heads/(.+)$' } | Select-Object -First 1)
            if ($branchLine -match '^branch\s+refs/heads/(.+)$') {
                $worktreeBranch = $Matches[1].Trim()
            }
        }
        if ([string]::IsNullOrWhiteSpace($worktreeBranch)) {
            Write-Warning "Could not determine branch for worktree '$WorktreePath' — skipping"
            return
        }
    }

    # (a) Primary guard — checked FIRST and unconditionally, before any other
    # re-verification. Closes the exact 2026-07-20 incident gap: the primary
    # checkout must never even reach eligibility/preflight logic.
    if (Test-WorktreeIsPrimary -WorktreePath $WorktreePath) {
        Write-Warning "refusing to remove the primary worktree at $WorktreePath"
        return
    }

    # (b) Independent re-verification via the shared eligibility primitive —
    # the executor never trusts stale detector-time state.
    $eligibility = Test-WorktreeBranchRemovalEligible -BranchName $worktreeBranch -DefaultBranch $DefaultBranch -Repo $Repo
    if (-not $eligibility.Eligible) {
        Write-Output "detector flagged this, but re-verification declined: $($eligibility.ManualReviewReason)"
        return
    }
    Write-Output "Removing worktree '$WorktreePath' (branch '$worktreeBranch') — eligible: $($eligibility.Evidence)"

    # Locked/prunable flags from the porcelain listing feed both the preflight
    # skip decision and the D5 (#522) locked-force dispatch below.
    $isLocked = $false
    $isPrunable = $false
    $matchedBlock = Get-WorktreePorcelainBlock -WorktreePath $WorktreePath
    if ($matchedBlock) {
        if ($matchedBlock -match '(?m)^locked') { $isLocked = $true }
        if ($matchedBlock -match '(?m)^prunable') { $isPrunable = $true }
    }
    $dirAbsent = -not (Test-Path $WorktreePath)

    if ($isLocked -and $dirAbsent) {
        # D5/#522, corrected (Issue #889 fix cycle, finding B1): real git never
        # emits the porcelain 'prunable' flag for a locked worktree — the two
        # markers are mutually exclusive in practice — so the original
        # "$isPrunable -and $isLocked" dead-code branch below could never fire,
        # and a genuinely gone-but-locked directory fell through to
        # Test-WorktreeRemovalPreflight's own "locked-and-not-prunable" skip,
        # producing a false "skipped-intact (locked)" message for a directory that
        # Test-Path already independently confirms is gone. The corrected clause
        # keys on Test-Path-verified absence alone (never the porcelain 'prunable'
        # self-report) for the locked case. git requires a DOUBLE --force to
        # remove a locked worktree registration; the actual post-attempt state is
        # then verified through the same honest Get-WorktreeRemovalOutcome probe
        # every other removal path below uses — never assumed.
        Invoke-SCDNativeCommand { git worktree remove --force --force $WorktreePath 2>$null }
        $removalExitCode = $LASTEXITCODE
    }
    elseif ($isLocked) {
        # Directory still present: a locked worktree with content still on disk is
        # manual-review territory, never force-removed on the lock flag alone (D5/#522).
        Write-Output "skipped locked worktree at $WorktreePath - remove the lock first"
        return
    }
    elseif ($isPrunable -and $dirAbsent) {
        # D5/#522: directory confirmed ABSENT via Test-Path (not merely git's own
        # 'prunable' self-report). Safe to clear the stale registration — there is
        # nothing left to check for dirtiness — so this bypasses
        # Test-WorktreeRemovalPreflight's dirty probe, which would otherwise
        # spuriously own-probe-error on a directory that genuinely no longer exists.
        Invoke-SCDNativeCommand { git worktree remove --force $WorktreePath 2>$null }
        $removalExitCode = $LASTEXITCODE
    }
    else {
        $preflight = Test-WorktreeRemovalPreflight -WorktreePath $WorktreePath -IsLocked $isLocked -IsPrunable $isPrunable
        if ($preflight.Skip) {
            Write-Output "skipped-intact ($($preflight.Reason)) at $WorktreePath"
            return
        }

        # C5: Try non-force removal first. Only escalate to --force when the
        # worktree is independently known prunable — never silently --force
        # over a worktree with uncommitted changes.
        Invoke-SCDNativeCommand { git worktree remove $WorktreePath 2>$null }
        $removalExitCode = $LASTEXITCODE
        if ($removalExitCode -ne 0 -and $isPrunable) {
            Invoke-SCDNativeCommand { git worktree remove --force $WorktreePath 2>$null }
            $removalExitCode = $LASTEXITCODE
        }
    }

    # Honest post-attempt diagnosis (M5/M24) — replaces the old Test-Path+porcelain
    # inference that produced a false "skipping" message for a worktree a removal
    # attempt had already partially destroyed.
    $outcome = Get-WorktreeRemovalOutcome -WorktreePath $WorktreePath -RemovalExitCode $removalExitCode `
        -PorcelainRegistrationProbe {
            $probeBlock = Get-WorktreePorcelainBlock -WorktreePath $WorktreePath
            return ($null -ne $probeBlock)
        } `
        -FileSystemProbe {
            if (-not (Test-Path $WorktreePath)) { return 'absent' }
            $children = Get-ChildItem -Path $WorktreePath -Force -ErrorAction SilentlyContinue
            if ($null -eq $children -or @($children).Count -eq 0) { return 'empty' }
            return 'non-empty'
        }
    $outcomeMessage = Get-WorktreeRemovalOutcomeMessage -Outcome $outcome -WorktreePath $WorktreePath -Detail "exit $removalExitCode"
    Write-Output $outcomeMessage

    # Issue #889 fix cycle, finding B2: 'stale-registration' is NOT a successful
    # removal — per Get-WorktreeRemovalOutcome's own matrix, that outcome means the
    # post-attempt probe still found the worktree REGISTERED (dir absent, but git
    # worktree list still lists it) — i.e. the deregistration attempt itself
    # FAILED, even though the exit code may have been 0. A genuinely successful
    # removal of an already-dir-absent worktree yields 'removed' (not registered
    # anymore), never 'stale-registration'. Counting it here would report a
    # deregistration failure to the user as "Deleted N sibling worktree(s)" and
    # would proceed to delete the branch out from under an entry git still
    # believes is a live worktree.
    $survivedOutcomes = @('removed', 'removed-partial-root-held', 'removed-partial-content-remains')
    if ($outcome -notin $survivedOutcomes) {
        return
    }

    $DeletedCount.Value++
    $DeletedPaths.Add($WorktreePath)
    if ($null -ne $DeletedOutcomes) {
        $DeletedOutcomes.Add($outcome)
    }

    Invoke-SCDNativeCommand { git branch -d $worktreeBranch 2>$null }
    if ($LASTEXITCODE -ne 0) {
        if (Test-BranchMergedIntoDefault -BranchName $worktreeBranch -DefaultBranch $DefaultBranch) {
            Invoke-SCDNativeCommand { git branch -D $worktreeBranch 2>$null }
            if ($LASTEXITCODE -ne 0) {
                Write-Warning "Failed to delete branch '$worktreeBranch' after worktree removal"
            }
        }
        else {
            Write-Output "Removed worktree '$WorktreePath', but skipped branch '$worktreeBranch' — unmerged commits — review before deleting"
        }
    }
}

function Remove-IssueTmpScratch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $IssueNumber,

        [Parameter(Mandatory)]
        [string]$TmpRoot
    )

    $resolvedTmpRoot = $TmpRoot
    if (-not [System.IO.Path]::IsPathRooted($TmpRoot)) {
        $gitRootRaw = & git rev-parse --show-toplevel 2>$null
        $gitRoot = if ($null -ne $gitRootRaw) { $gitRootRaw.Trim() } else { '' }
        $baseDir = if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($gitRoot)) { $gitRoot } else { (Get-Location).Path }
        $resolvedTmpRoot = Join-Path $baseDir $TmpRoot
    }

    if (-not (Test-Path $resolvedTmpRoot)) {
        Write-Output "Cleaned 0 .tmp/ scratch files for issue #$IssueNumber"
        return
    }

    $escapedN = [regex]::Escape($IssueNumber)
    # Flat scope only — scratch convention uses top-level .tmp/{N}-* files; nested subdirs are not swept.
    $allTmpFiles = Get-ChildItem -Path $resolvedTmpRoot -File -ErrorAction SilentlyContinue
    $filesToRemove = @($allTmpFiles | Where-Object {
        $name = $_.Name
        # Form 1: {N}-* (literal '-' already anchors the right boundary)
        ($name -like "$IssueNumber-*") -or
        # Form 2: issue-{N}.ext, issue-{N}-rest, or bare issue-{N}
        ($name -match "^issue-$escapedN(\.|-)") -or
        ($name -eq "issue-$IssueNumber")
    })

    $removedCount = 0
    foreach ($file in $filesToRemove) {
        Remove-Item -LiteralPath $file.FullName -Force -ErrorAction SilentlyContinue
        $removedCount++
    }

    Write-Output "Cleaned $removedCount .tmp/ scratch files for issue #$IssueNumber"
}

if ($null -ne $IssueNumber) {
    Write-Output "== Post-merge cleanup: issue #$IssueNumber =="
} else {
    Write-Output "== Post-merge cleanup =="
}

# Fetch to refresh remote refs; fail-open on error
Invoke-SCDNativeCommand { git fetch origin --prune 2>$null }
if ($LASTEXITCODE -ne 0) {
    Write-Warning "Fetch failed (exit $LASTEXITCODE) — proceeding with cached refs; some merged-status checks may be stale"
}

# Determine default branch defensively (try multiple strategies before assuming 'main')
$defaultBranch = Get-SCDDefaultBranch
$remoteDefaultRef = Get-RemoteDefaultRef -DefaultBranch $defaultBranch
$remoteDefaultParts = $remoteDefaultRef -split '/', 2
if ($remoteDefaultParts.Count -eq 2 -and $remoteDefaultParts[0] -ne 'origin') {
    $upstreamRemote = $remoteDefaultParts[0]
    Invoke-SCDNativeCommand { git fetch $upstreamRemote --prune 2>$null }
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "Fetch failed for remote '$upstreamRemote' (exit $LASTEXITCODE) — proceeding with cached refs; some merged-status checks may be stale"
    }
}

# ── Orphan branch cleanup ──────────────────────────────────────────────────
$deletedOrphanCount = 0
$deletedOrphanNames = [System.Collections.Generic.List[string]]::new()
foreach ($branch in $OrphanBranches) {
    Remove-OrphanBranch -Branch $branch -DefaultBranch $defaultBranch -DeletedCount ([ref]$deletedOrphanCount) -DeletedNames $deletedOrphanNames
}
if ($deletedOrphanCount -gt 0) {
    Write-Output "Deleted $deletedOrphanCount orphan branch(es): $($deletedOrphanNames -join ', ')"
}

# ── Sibling worktree cleanup ───────────────────────────────────────────────
$deletedSiblingCount = 0
$deletedSiblingPaths = [System.Collections.Generic.List[string]]::new()
$deletedSiblingOutcomes = [System.Collections.Generic.List[string]]::new()
foreach ($worktreePath in $SiblingWorktrees) {
    Remove-SiblingWorktree -WorktreePath $worktreePath -DefaultBranch $defaultBranch -DeletedCount ([ref]$deletedSiblingCount) -DeletedPaths $deletedSiblingPaths -DeletedOutcomes $deletedSiblingOutcomes -Repo $Repo
}
if ($deletedSiblingCount -gt 0) {
    # Issue #889 CE Gate fix (F1+F2, AC4): the unqualified rollup previously
    # counted 'removed', 'removed-partial-root-held' (empty husk, nothing left
    # to inspect), and 'removed-partial-content-remains' (real files survive on
    # disk) identically, so a maintainer reading only this summary line — not
    # the honest per-entry messages above it — could not tell a fully clean
    # removal batch from one that left residue behind. Qualify the total here
    # without changing what counts toward it.
    $partialSiblingCount = @($deletedSiblingOutcomes | Where-Object { $_ -ne 'removed' }).Count
    if ($partialSiblingCount -gt 0) {
        $cleanSiblingCount = $deletedSiblingCount - $partialSiblingCount
        Write-Output "Deleted $deletedSiblingCount sibling worktree(s): $($deletedSiblingPaths -join ', ') ($cleanSiblingCount fully removed, $partialSiblingCount with residue remaining — see line(s) above)"
    } else {
        Write-Output "Deleted $deletedSiblingCount sibling worktree(s): $($deletedSiblingPaths -join ', ')"
    }
}

# ── Issue .tmp/ scratch clearing ──────────────────────────────────────────
if (-not [string]::IsNullOrWhiteSpace($TmpRoot) -and $null -ne $IssueNumber) {
    Remove-IssueTmpScratch -IssueNumber $IssueNumber -TmpRoot $TmpRoot
}

# ── Untagged tracking file archival ───────────────────────────────────────
$archivedUntaggedCount = 0
if ($UntaggedTrackingFiles.Count -gt 0) {
    # G3: Anchor on the repo root so behavior is independent of the script's CWD.
    $repoRoot = (Invoke-SCDNativeCommand { git rev-parse --show-toplevel 2>$null })
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($repoRoot)) {
        $repoRoot = (Get-Location).Path
    } else {
        $repoRoot = $repoRoot.Trim()
    }
    # C2: Resolve the canonical .copilot-tracking root for path-traversal validation.
    $trackingRootCanonical = $null
    $trackingRootDir = Join-Path $repoRoot '.copilot-tracking'
    if (Test-Path $trackingRootDir) {
        $trackingRootCanonical = (Resolve-Path -LiteralPath $trackingRootDir).Path.TrimEnd('\', '/')
    }
    $timestamp = Get-Date
    $year = $timestamp.ToString('yyyy')
    $month = $timestamp.ToString('MM')
    $unknownArchiveDir = Join-Path '.copilot-tracking-archive' (Join-Path $year (Join-Path $month 'unknown'))
    New-Item -ItemType Directory -Path $unknownArchiveDir -Force | Out-Null
    foreach ($relPath in $UntaggedTrackingFiles) {
        $absPath = Join-Path $repoRoot $relPath
        if (-not (Test-Path $absPath)) {
            Write-Warning "Untagged tracking file not found: '$relPath' — skipping"
            continue
        }
        # C2: Validate the resolved path lives under .copilot-tracking/. This blocks
        # both '..' traversal (e.g. '../../etc/hosts') and absolute paths that
        # escape the tracking root.
        $resolvedAbs = (Resolve-Path -LiteralPath $absPath).Path
        if (-not $trackingRootCanonical -or
            -not $resolvedAbs.StartsWith("$trackingRootCanonical$([System.IO.Path]::DirectorySeparatorChar)", [System.StringComparison]::OrdinalIgnoreCase) -and
            -not [string]::Equals($resolvedAbs, $trackingRootCanonical, [System.StringComparison]::OrdinalIgnoreCase)) {
            Write-Warning "Path traversal blocked: '$relPath' resolves outside .copilot-tracking/ — skipping"
            continue
        }
        # Registry guard: skip persistent root-level files (mf6-executor-failsafe, AC4)
        $relFromTrackingRoot = $resolvedAbs.Substring($trackingRootCanonical.Length).TrimStart([System.IO.Path]::DirectorySeparatorChar, '/')
        if ($script:PersistentTrackingFilenames.Count -gt 0 -and
            -not $relFromTrackingRoot.Contains([System.IO.Path]::DirectorySeparatorChar) -and
            -not $relFromTrackingRoot.Contains('/') -and
            $script:PersistentTrackingFilenames -icontains $relFromTrackingRoot) {
            Write-Warning "Persistent tracking file skipped — registry-protected, will not be archived: '$relPath'"
            continue
        }
        $fileInfo = Get-Item $absPath
        # CR-5 defensive guard: skip directories (caller should only pass files via -File,
        # but guard against API misuse that could move an entire tracking subtree)
        if ($fileInfo.PSIsContainer) {
            Write-Warning "Untagged tracking path is not a file: '$relPath' — skipping"
            continue
        }
        $ext = $fileInfo.Extension
        $nameNoExt = $fileInfo.BaseName
        $mtime = $fileInfo.LastWriteTime.ToString('yyyyMMddHHmmss')
        $destName = "$nameNoExt-$mtime$ext"
        $destPath = Join-Path $unknownArchiveDir $destName
        # Collision-safe: add suffix if needed
        $suffix = 1
        while (Test-Path $destPath) {
            $destPath = Join-Path $unknownArchiveDir "$nameNoExt-$mtime-$suffix$ext"
            $suffix++
        }
        Move-Item -LiteralPath $absPath -Destination $destPath
        $archivedUntaggedCount++
    }
    if ($archivedUntaggedCount -gt 0) {
        Write-Output "Archived $archivedUntaggedCount untagged file(s) under $year/$month/unknown/"
        Remove-EmptyDirectory -Root '.copilot-tracking'
    }
}

if ($null -ne $IssueNumber) {
    $timestamp = Get-Date
    $year = $timestamp.ToString('yyyy')
    $month = $timestamp.ToString('MM')
    $archiveRoot = Join-Path '.copilot-tracking-archive' (Join-Path $year $month)
    $archivePath = Join-Path $archiveRoot "issue-$IssueNumber"

    Write-Output "Archive target: $archivePath"
    New-Item -ItemType Directory -Path $archivePath -Force | Out-Null

    $trackingRoot = '.copilot-tracking'
    # S-C1: hoist loop-invariant path resolution out of the per-file Where-Object and foreach.
    # Guard against a missing .copilot-tracking/ dir: Resolve-Path throws (terminating) on a
    # non-existent path, which would crash an -IssueNumber cleanup run from any tree lacking
    # that dir (fresh worktree, consumer repo, or post-prune). Get-ChildItem below already
    # fails open (-ErrorAction SilentlyContinue) to an empty set, so a non-resolvable root is
    # harmless — only the string prefix for the registry guard is needed.
    $trackingRootResolved = if (Test-Path -LiteralPath $trackingRoot) {
        (Resolve-Path -LiteralPath $trackingRoot).Path
    }
    else {
        Join-Path (Get-Location).Path $trackingRoot
    }
    $allTrackingFiles = Get-ChildItem -Path $trackingRoot -Recurse -File -ErrorAction SilentlyContinue
    # Exclude .gitkeep placeholder files, then filter to only files belonging to this issue
    $trackingFiles = @($allTrackingFiles | Where-Object { $_.Name -ne '.gitkeep' } | Where-Object {
            # Registry guard: skip persistent root-level files (AC4)
            $relFromRoot = $_.FullName.Substring($trackingRootResolved.Length).TrimStart('\', '/')
            if ($script:PersistentTrackingFilenames.Count -gt 0 -and
                -not $relFromRoot.Contains('\') -and
                -not $relFromRoot.Contains('/') -and
                $script:PersistentTrackingFilenames -icontains $relFromRoot) {
                Write-Warning "Persistent tracking file skipped — registry-protected, will not be archived: '$($_.Name)'"
                return $false
            }
            $content = Get-Content -Path $_.FullName -Raw -ErrorAction SilentlyContinue
            if ($content -match '(?m)^issue_id:\s*["\x27]?(\d+)["\x27]?') {
                [int]$Matches[1] -eq $IssueNumber
            }
            else {
                Write-Warning "Skipping '$($_.Name)': no issue_id frontmatter found."
                $false
            }
        })

    $archivedCount = 0
    foreach ($file in $trackingFiles) {
        $relativePath = $file.FullName.Substring($trackingRootResolved.Length).TrimStart('\', '/')
        $destDir = Join-Path $archivePath (Split-Path $relativePath -Parent)
        New-Item -Force -ItemType Directory -Path $destDir | Out-Null
        Move-Item -LiteralPath $file.FullName -Destination (Join-Path $destDir $file.Name)
        $archivedCount++
    }

    Remove-EmptyDirectory -Root $trackingRoot

    $remaining = (Get-ChildItem -Path $trackingRoot -Recurse -File -ErrorAction SilentlyContinue | Measure-Object).Count
    Write-Output "Archived $archivedCount file(s). Tracking files remaining: $remaining"
}

if (-not $SkipGitUpdate) {
    Write-Output "Switching to $defaultBranch and pulling latest..."
    git checkout $defaultBranch
    if ($LASTEXITCODE -ne 0) { throw "git checkout $defaultBranch failed (exit $LASTEXITCODE). Cleanup aborted." }
    git pull
    if ($LASTEXITCODE -ne 0) { throw "git pull failed (exit $LASTEXITCODE). Cleanup aborted." }
}

# Nit (#889 fix cycle): compute the -FeatureBranch re-verification ONCE, before
# EITHER destructive action, so the remote delete below can never race ahead of
# the same eligibility check the local delete already required (Issue #889 s3,
# M9/AC3). Previously the remote branch ref was deleted unconditionally before
# this re-verification ran at all — a branch the re-verification would go on to
# DECLINE still had its remote ref irreversibly deleted first.
$featureEligibility = $null
if ($FeatureBranch -and (-not $SkipRemoteDelete -or -not $SkipLocalDelete)) {
    $featureEligibility = Test-WorktreeBranchRemovalEligible -BranchName $FeatureBranch -DefaultBranch $defaultBranch -Repo $Repo
    if (-not $featureEligibility.Eligible) {
        Write-Output "detector flagged this, but re-verification declined: $($featureEligibility.ManualReviewReason)"
    }
}

if (-not $SkipRemoteDelete -and $FeatureBranch -and $featureEligibility.Eligible) {
    $remoteExists = git ls-remote --heads origin $FeatureBranch 2>$null
    if ($remoteExists) {
        Write-Output "Deleting remote branch: $FeatureBranch"
        git push origin --delete $FeatureBranch
    }
    else {
        Write-Output "Remote branch not found (already deleted): $FeatureBranch"
    }
}

if (-not $SkipLocalDelete -and $FeatureBranch) {
    $localExists = git branch --list $FeatureBranch
    if ($localExists) {
        if (-not $featureEligibility.Eligible) {
            # Already reported by the shared re-verification above.
        }
        else {
            $currentBranch = git branch --show-current 2>$null
            if ($currentBranch -eq $FeatureBranch) {
                git checkout $defaultBranch
                if ($LASTEXITCODE -ne 0) { throw "git checkout $defaultBranch failed (exit $LASTEXITCODE). Cannot delete current branch." }
            }
            Write-Output "Deleting local branch: $FeatureBranch"
            git branch -D $FeatureBranch
        }
    }
    else {
        Write-Output "Local branch not found: $FeatureBranch"
    }
}

if ($null -ne $IssueNumber) {
    if ($UseGh) {
        $resolvedRepo = if ($Repo) { $Repo } else { Get-SCDOriginRepo }
        if (-not $resolvedRepo) {
            Write-Warning 'gh enabled, but repo could not be resolved. Use -Repo owner/name.'
        }
        elseif (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
            Write-Warning 'gh enabled, but GitHub CLI not found on PATH.'
        }
        else {
            $bodyLines = @(
                'Work complete.',
                '',
                $(if ($PrNumber) { "**Merged PR**: #$PrNumber" } else { $null }),
                ("**Files Archived**: ``$archivePath/``"),
                'Cleaned up via SessionStart hook.'
            ) | Where-Object { $_ -ne $null }

            gh issue comment $IssueNumber --repo $resolvedRepo --body ($bodyLines -join "`n")
        }
    }
    else {
        Write-Output 'Note: Use -UseGh to automatically post a GitHub issue comment.'
    }
}

Write-Output 'Cleanup complete.'
