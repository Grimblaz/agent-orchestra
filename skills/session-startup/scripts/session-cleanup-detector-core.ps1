#Requires -Version 7.0
<#
.SYNOPSIS
    Library for session-cleanup-detector logic. Dot-source this file and call Invoke-SessionCleanupDetector.

.NOTES
    Cleanup categories detected and reported by this library:
      - Current branch: flags the active branch when its upstream is merged/deleted.
      - Tracking files: flags issue-scoped .copilot-tracking/ files whose feature branch is gone.
      - Sibling worktrees: flags sibling worktrees on merged/deleted branches.
      - Orphan branches: flags unattached merged branches (squash-aware via tree-equivalence).
      - .tmp/ scratch clearing: NOT detected here. Clearing per-issue .tmp/{N}-* and
        .tmp/issue-{N}* scratch files is performed at cleanup time by Remove-IssueTmpScratch
        in post-merge-cleanup.ps1 when -TmpRoot and -IssueNumber are both provided.
#>

. "$PSScriptRoot/session-startup-git-helpers.ps1"

# ===========================================================================
# Issue #889 s4 — eligibility-gating helpers for the detector's candidate-
# append sites. These wrap the shared Test-WorktreeBranchRemovalEligible
# primitive (session-startup-git-helpers.ps1, s1) with a detector-only
# degraded-CWD short-circuit and a collection-time gh budget, neither of
# which are concerns of the primitive itself.
# ===========================================================================

# Detector-only manual-review reason for the degraded-CWD downgrade (D6/AC7).
# Not part of $script:WorktreeEligibilityReasons in session-startup-git-helpers.ps1:
# that dictionary enumerates reasons the PRIMITIVE itself produces; this reason
# is produced by the detector's own structural guard and never by the primitive.
$script:SCDDegradedCwdManualReviewReason = "couldn't verify: current worktree location not registered"

# Detector-only manual-review reason for the collection-time gh budget cap
# (finding D, #889 fix cycle). Test-SCDCollectionGhBudgetExceeded trips on EITHER
# a per-category candidate COUNT cap or the run's elapsed-time cap — neither of
# which means a gh subprocess was actually invoked and hung. Previously both
# cases were reported via $script:WorktreeEligibilityReasons.GhTimeout (the
# PRIMITIVE's own reason for a genuine per-call gh timeout inside
# Invoke-SCDGhWithTimeout), which conflated "we deliberately declined to spend
# more of this run's gh budget" with "a gh call actually hung". This reason is
# used only for the collection-budget short-circuit; GhTimeout is reserved for
# genuine per-call timeouts surfaced by the primitive itself.
$script:SCDCollectionBudgetExceededManualReviewReason = "couldn't verify: too many candidates this run"

function Test-SCDCurrentLocationMatchesWorktreeRecord {
    <#
    .SYNOPSIS
        Issue #889 s4: returns $true when $CurrentPath matches (normalized,
        case-insensitive) any record's WorktreePath in $WorktreeRecords.
        Used to detect the degraded-CWD condition — the current location
        does not correspond to any worktree `git worktree list --porcelain`
        knows about (e.g. a wiped/relocated linked worktree whose directory
        walk silently falls through to a different checkout).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$CurrentPath,

        [AllowNull()]
        [array]$WorktreeRecords
    )

    if ($null -eq $WorktreeRecords -or $WorktreeRecords.Count -eq 0) {
        return $false
    }

    $normCurrent = ConvertTo-SCDNormalizedPath -Path $CurrentPath
    if (-not $normCurrent) {
        return $false
    }

    foreach ($record in $WorktreeRecords) {
        $normRecord = ConvertTo-SCDNormalizedPath -Path $record.WorktreePath
        if ($normRecord -and [string]::Equals($normRecord, $normCurrent, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }

    return $false
}

function New-SCDCollectionGhBudget {
    <#
    .SYNOPSIS
        Issue #889 s4: collection-time gh budget for the detector's
        eligibility-gating calls. Distinct from the render-time
        $claudeCleanupLimit further down this file, which only truncates
        already-collected output and never bounds gh calls.
    #>
    [CmdletBinding()]
    param(
        # 20 comfortably exceeds the render-time $claudeCleanupLimit (10) further down
        # this file, so the collection budget is never a tighter bottleneck than the
        # existing render truncation for realistic candidate counts; it exists to bound
        # pathological cases (hundreds of stale branches), not everyday cleanup runs.
        [int]$PerCategoryLimit = 20,
        [int]$GlobalSeconds = 10
    )

    return @{
        PerCategoryLimit = $PerCategoryLimit
        GlobalSeconds    = $GlobalSeconds
        Stopwatch        = [System.Diagnostics.Stopwatch]::StartNew()
        CategoryCounts   = @{}
    }
}

function Test-SCDCollectionGhBudgetExceeded {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Budget,

        [Parameter(Mandatory)]
        [string]$Category
    )

    if ($Budget.Stopwatch.Elapsed.TotalSeconds -ge $Budget.GlobalSeconds) {
        return $true
    }

    $count = 0
    if ($Budget.CategoryCounts.ContainsKey($Category)) {
        $count = $Budget.CategoryCounts[$Category]
    }
    if ($count -ge $Budget.PerCategoryLimit) {
        return $true
    }

    $Budget.CategoryCounts[$Category] = $count + 1
    return $false
}

function Get-SCDGatedEligibility {
    <#
    .SYNOPSIS
        Issue #889 s4: shared wrapper around Test-WorktreeBranchRemovalEligible
        for every candidate-append site. Short-circuits to a manual-review
        result (never calling the primitive, never spending gh budget) when
        $IsDegradedCwd is set; otherwise spends one collection-time budget
        unit before delegating to the primitive.
    .OUTPUTS
        Hashtable: @{ Eligible = <bool>; Evidence = <string|$null>; ManualReviewReason = <string|$null> }
        (same shape as Test-WorktreeBranchRemovalEligible's own output).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Budget,

        [Parameter(Mandatory)]
        [string]$Category,

        [Parameter(Mandatory)]
        [string]$BranchName,

        [Parameter(Mandatory)]
        [string]$DefaultBranch,

        [bool]$IsDegradedCwd = $false
    )

    if ($IsDegradedCwd) {
        return @{ Eligible = $false; Evidence = $null; ManualReviewReason = $script:SCDDegradedCwdManualReviewReason }
    }

    if (Test-SCDCollectionGhBudgetExceeded -Budget $Budget -Category $Category) {
        return @{ Eligible = $false; Evidence = $null; ManualReviewReason = $script:SCDCollectionBudgetExceededManualReviewReason }
    }

    return Test-WorktreeBranchRemovalEligible -BranchName $BranchName -DefaultBranch $DefaultBranch
}

function Get-SCDManualReviewLines {
    <#
    .SYNOPSIS
        Issue #889 s4 (D6): renders manual-review lines for candidates the
        shared eligibility primitive declined to clear. Mutually exclusive
        with the eligible-line renderers (Get-SiblingWorktreeLines /
        Get-SCDOrphanBranchLines / Get-CurrentNoUpstreamWorktreeLines) — a
        candidate renders through exactly one of the two paths, never both.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Label,

        [Parameter(Mandatory)]
        [array]$Items
    )

    $out = @()
    foreach ($item in $Items) {
        $locationSuffix = if ($item.WorktreePath) { " at ``$($item.WorktreePath)``" } else { '' }
        $out += "- $Label ``$($item.BranchName)``$locationSuffix needs manual review: $($item.ManualReviewReason)"
    }
    return $out
}

function Test-SCDPersistentTrackingFile {
    param(
        [Parameter(Mandatory)]
        [string]$TrackingRootPath,

        [Parameter(Mandatory)]
        [System.IO.FileInfo]$File,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]]$PersistentSubtrees,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]]$PersistentFilenames
    )

    $filePath = [System.IO.Path]::GetFullPath($File.FullName)
    $relativePath = [System.IO.Path]::GetRelativePath($TrackingRootPath, $filePath).Replace('\', '/')

    # Root-anchored filename check: file must be at tracking root depth 0 (no path separator)
    if ($PersistentFilenames.Count -gt 0 -and -not $relativePath.Contains('/')) {
        foreach ($fname in $PersistentFilenames) {
            if ($relativePath.Equals($fname, [System.StringComparison]::OrdinalIgnoreCase)) {
                return $true
            }
        }
    }

    foreach ($subtree in $PersistentSubtrees) {
        $normalizedSubtree = $subtree.Trim('/').Replace('\', '/')
        if (-not $normalizedSubtree) {
            continue
        }

        if (
            $relativePath.Equals($normalizedSubtree, [System.StringComparison]::OrdinalIgnoreCase) -or
            $relativePath.StartsWith("$normalizedSubtree/", [System.StringComparison]::OrdinalIgnoreCase)
        ) {
            return $true
        }
    }

    return $false
}

function Get-SCDRemoteDefaultRef {
    <#
    .SYNOPSIS
        Finding K (#889 fix cycle): single-sourced on the shared
        Get-RemoteDefaultRef (session-startup-git-helpers.ps1) resolution
        strategy — upstream-tracking-ref-first (`git rev-parse --abbrev-ref
        <branch>@{upstream}`), falling back to `origin/<DefaultBranch>` —
        instead of maintaining a second, independently-diverging config-first
        strategy (`git config --get branch.<X>.remote`, falling back to
        parsing `origin/HEAD`'s symbolic-ref) here. The two strategies agree
        in the overwhelming majority of real repos (a branch's `@{upstream}`
        resolution is itself derived from the same `branch.<X>.remote` /
        `branch.<X>.merge` config this function used to read directly), so
        this file's own resolver was pure duplicated logic that could
        silently drift from the shared one. Only the RETURN SHAPE
        (RemoteName/BranchName/RefName hashtable, vs. the shared helper's
        bare "remote/branch" string) remains detector-specific — this
        wrapper derives that shape from the shared helper's single string
        result so every detector call site keeps working unchanged.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$DefaultBranch
    )

    $refString = Get-RemoteDefaultRef -DefaultBranch $DefaultBranch
    $parts = $refString -split '/', 2
    if ($parts.Count -eq 2 -and -not [string]::IsNullOrWhiteSpace($parts[0]) -and -not [string]::IsNullOrWhiteSpace($parts[1])) {
        return @{
            RemoteName = $parts[0]
            BranchName = $parts[1]
            RefName    = "refs/remotes/$($parts[0])/$($parts[1])"
        }
    }

    # Malformed/unexpected shape from the shared resolver (should not happen
    # given its own contract) — fail toward the historical 'origin'/$DefaultBranch
    # default rather than propagate an unparseable ref.
    return @{
        RemoteName = 'origin'
        BranchName = $DefaultBranch
        RefName    = "refs/remotes/origin/$DefaultBranch"
    }
}

function Get-SCDGitCommandPath {
    try {
        $command = Get-Command git -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -ne $command -and -not [string]::IsNullOrWhiteSpace($command.Source)) {
            return $command.Source
        }
    }
    catch {
        $null = $_
    }

    return 'git'
}

function Invoke-SCDNonInteractiveGit {
    param(
        [Parameter(Mandatory)]
        [string[]]$Arguments,

        [int]$TimeoutSeconds = 5
    )

    $result = @{
        ExitCode = $null
        Output   = ''
        TimedOut = $false
    }

    if ($null -eq $Arguments -or $Arguments.Count -eq 0) {
        return $result
    }

    try {
        $processStartInfo = [System.Diagnostics.ProcessStartInfo]::new()
        $processStartInfo.FileName = Get-SCDGitCommandPath
        $processStartInfo.UseShellExecute = $false
        $processStartInfo.CreateNoWindow = $true
        $processStartInfo.RedirectStandardOutput = $true
        $processStartInfo.WorkingDirectory = (Get-Location).Path
        foreach ($argument in $Arguments) {
            $processStartInfo.ArgumentList.Add($argument) | Out-Null
        }
        $processStartInfo.Environment['GIT_TERMINAL_PROMPT'] = '0'
        $processStartInfo.Environment['GCM_INTERACTIVE'] = 'Never'
        $processStartInfo.Environment['GIT_ASKPASS'] = 'echo'

        $process = [System.Diagnostics.Process]::Start($processStartInfo)
        if ($null -eq $process) {
            return $result
        }

        try {
            $timeoutMilliseconds = [System.Math]::Max(1, $TimeoutSeconds) * 1000
            if (-not $process.WaitForExit($timeoutMilliseconds)) {
                $result.TimedOut = $true
                try { $process.Kill($true) } catch { $null = $_ }
                return $result
            }

            $result.ExitCode = $process.ExitCode
            $result.Output = $process.StandardOutput.ReadToEnd()
        }
        finally {
            $process.Dispose()
        }
    }
    catch {
        $null = $_
    }

    return $result
}

function Invoke-SCDNonInteractiveFetch {
    param(
        [Parameter(Mandatory)]
        [string]$RemoteName,

        [int]$TimeoutSeconds = 5
    )

    if ([string]::IsNullOrWhiteSpace($RemoteName)) {
        return
    }

    $null = Invoke-SCDNonInteractiveGit -Arguments @('fetch', '--quiet', '--prune', $RemoteName) -TimeoutSeconds $TimeoutSeconds
}

function ConvertTo-SCDNormalizedPath {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return ''
    }

    try {
        return [System.IO.Path]::GetFullPath($Path).Replace('\', '/').TrimEnd('/')
    }
    catch {
        return ''
    }
}

function Test-SCDBranchMatchesPrefixes {
    param(
        [Parameter(Mandatory)]
        [string]$BranchName,

        [Parameter(Mandatory)]
        [string[]]$Prefixes
    )

    foreach ($branchPrefix in $Prefixes) {
        if ($BranchName.StartsWith($branchPrefix, [System.StringComparison]::Ordinal)) {
            return $true
        }
    }

    return $false
}

function ConvertTo-SCDPowerShellSingleQuoteEscapedText {
    param([AllowNull()][string]$Value)

    if ($null -eq $Value) {
        return ''
    }

    return $Value -replace "'", "''"
}

function ConvertFrom-SCDUpstreamRef {
    param(
        [AllowNull()][object]$UpstreamRef,

        [Parameter(Mandatory)]
        [string]$FallbackBranchName
    )

    $upstreamText = (($UpstreamRef | Select-Object -First 1) -as [string])
    if ([string]::IsNullOrWhiteSpace($upstreamText)) {
        return $null
    }

    $upstreamParts = $upstreamText.Trim() -split '/', 2
    $remoteName = $upstreamParts[0]
    $remoteBranchName = if ($upstreamParts.Count -gt 1) { $upstreamParts[1] } else { $FallbackBranchName }

    if ([string]::IsNullOrWhiteSpace($remoteName)) {
        return $null
    }
    if ([string]::IsNullOrWhiteSpace($remoteBranchName)) {
        $remoteBranchName = $FallbackBranchName
    }

    return @{
        RemoteName = $remoteName
        BranchName = $remoteBranchName
    }
}

function Test-SCDRemoteHeadMissing {
    param(
        [Parameter(Mandatory)]
        [string]$RemoteName,

        [Parameter(Mandatory)]
        [string]$BranchPattern
    )

    if ([string]::IsNullOrWhiteSpace($RemoteName) -or [string]::IsNullOrWhiteSpace($BranchPattern)) {
        return $false
    }

    try {
        $remoteResult = Invoke-SCDNonInteractiveGit -Arguments @('ls-remote', '--heads', $RemoteName, $BranchPattern)
        return ($remoteResult.ExitCode -eq 0 -and [string]::IsNullOrWhiteSpace($remoteResult.Output))
    }
    catch {
        return $false
    }
}

function Test-SCDGitRefExists {
    param(
        [Parameter(Mandatory)]
        [string]$RefName
    )

    if ([string]::IsNullOrWhiteSpace($RefName)) {
        return $false
    }

    try {
        git show-ref --verify --quiet $RefName 2>$null
        return ($LASTEXITCODE -eq 0)
    }
    catch {
        return $false
    }
}

function Test-SCDMergeBaseAncestor {
    param(
        [Parameter(Mandatory)]
        [string]$BranchName,

        [Parameter(Mandatory)]
        [string]$TargetRef,

        [string]$WorktreePath = ''
    )

    if ([string]::IsNullOrWhiteSpace($BranchName) -or [string]::IsNullOrWhiteSpace($TargetRef)) {
        return $false
    }

    try {
        if ([string]::IsNullOrWhiteSpace($WorktreePath)) {
            git merge-base --is-ancestor $BranchName $TargetRef 2>$null
        }
        else {
            git -C $WorktreePath merge-base --is-ancestor $BranchName $TargetRef 2>$null
        }

        return ($LASTEXITCODE -eq 0)
    }
    catch {
        return $false
    }
}

function Get-SCDWorktreeRecords {
    param([string[]]$PorcelainLines)

    $porcelainText = ($PorcelainLines | Where-Object { $null -ne $_ }) -join "`n"
    $porcelainText = $porcelainText -replace "`r`n", "`n" -replace "`r", "`n"
    if ([string]::IsNullOrWhiteSpace($porcelainText)) {
        return @()
    }

    $records = @()
    foreach ($recordText in [regex]::Split($porcelainText.Trim(), "`n\s*`n")) {
        try {
            $recordLines = @($recordText -split "`n" | ForEach-Object { $_.TrimEnd() })
            $worktreeLine = $recordLines | Where-Object { $_ -like 'worktree *' } | Select-Object -First 1
            if ([string]::IsNullOrWhiteSpace($worktreeLine)) {
                continue
            }

            $worktreePath = $worktreeLine.Substring('worktree '.Length)
            if ([string]::IsNullOrWhiteSpace($worktreePath)) {
                continue
            }

            $branchLine = $recordLines | Where-Object { $_ -like 'branch *' } | Select-Object -First 1
            $branchName = ''
            if (-not [string]::IsNullOrWhiteSpace($branchLine)) {
                $branchName = $branchLine.Substring('branch '.Length)
                if ($branchName.StartsWith('refs/heads/', [System.StringComparison]::Ordinal)) {
                    $branchName = $branchName.Substring('refs/heads/'.Length)
                }
            }

            $lockedLine = $recordLines | Where-Object { $_ -eq 'locked' -or $_ -like 'locked *' } | Select-Object -First 1
            $prunableLine = $recordLines | Where-Object { $_ -eq 'prunable' -or $_ -like 'prunable *' } | Select-Object -First 1

            $lockReason = ''
            if (-not [string]::IsNullOrWhiteSpace($lockedLine) -and $lockedLine.Length -gt 'locked'.Length) {
                $lockReason = $lockedLine.Substring('locked '.Length)
            }

            $records += @{
                WorktreePath = $worktreePath
                BranchName   = $branchName
                IsBare       = [bool]($recordLines | Where-Object { $_ -eq 'bare' -or $_ -like 'bare *' } | Select-Object -First 1)
                IsDetached   = [bool]($recordLines | Where-Object { $_ -eq 'detached' -or $_ -like 'detached *' } | Select-Object -First 1)
                IsLocked     = -not [string]::IsNullOrWhiteSpace($lockedLine)
                LockReason   = $lockReason
                IsPrunable   = -not [string]::IsNullOrWhiteSpace($prunableLine)
            }
        }
        catch {
            $null = $_
        }
    }

    return $records
}

function Get-SCDSiblingWorktreeCleanups {
    param(
        [Parameter(Mandatory)]
        [string]$CurrentWorktreePath,

        [Parameter(Mandatory)]
        [string]$DefaultBranch,

        [Parameter(Mandatory)]
        [string[]]$NoUpstreamBranchPrefixes,

        [string[]]$UpstreamDeletedBranchPrefixes = @('feature/issue-'),

        [AllowNull()]
        [System.Collections.Generic.IDictionary[string, bool]]$FetchLookup = $null,

        [AllowNull()]
        [array]$WorktreeRecords = $null,

        [hashtable]$GhBudget = (New-SCDCollectionGhBudget),

        [bool]$IsDegradedCwd = $false
    )

    $cleanups = @()
    $currentNormalizedPath = ConvertTo-SCDNormalizedPath -Path $CurrentWorktreePath
    if (-not $currentNormalizedPath) {
        return @()
    }

    try {
        if ($null -eq $WorktreeRecords) {
            $worktreePorcelain = @(git worktree list --porcelain 2>$null)
            if ($LASTEXITCODE -ne 0) {
                return @()
            }
            $records = @(Get-SCDWorktreeRecords -PorcelainLines $worktreePorcelain)
        }
        else {
            $records = $WorktreeRecords
        }

        $remoteDefault = $null
        $hasNoUpstreamCandidates = $false
        foreach ($record in $records) {
            if (-not $record.IsBare -and -not $record.IsDetached -and -not [string]::IsNullOrWhiteSpace($record.BranchName)) {
                $normalizedPath = ConvertTo-SCDNormalizedPath -Path $record.WorktreePath
                if ($normalizedPath -and -not $normalizedPath.Equals($currentNormalizedPath, [System.StringComparison]::OrdinalIgnoreCase)) {
                    if ($record.BranchName -ne $DefaultBranch -and (Test-SCDBranchMatchesPrefixes -BranchName $record.BranchName -Prefixes $NoUpstreamBranchPrefixes)) {
                        $hasNoUpstreamCandidates = $true
                        break
                    }
                }
            }
        }

        if ($hasNoUpstreamCandidates) {
            $remoteDefault = Get-SCDRemoteDefaultRef -DefaultBranch $DefaultBranch
            Invoke-SCDNonInteractiveFetchOnce -RemoteName $remoteDefault.RemoteName -CacheKey $remoteDefault.RefName -FetchLookup $FetchLookup
        }

        foreach ($record in $records) {
            try {
                if ($record.IsBare -or $record.IsDetached -or [string]::IsNullOrWhiteSpace($record.BranchName)) {
                    continue
                }

                $normalizedPath = ConvertTo-SCDNormalizedPath -Path $record.WorktreePath
                if (-not $normalizedPath) {
                    continue
                }

                if ($normalizedPath.Equals($currentNormalizedPath, [System.StringComparison]::OrdinalIgnoreCase)) {
                    continue
                }

                # Issue #889 s4 (D2/AC2): exclude the primary worktree even when it is
                # NOT the "current" record — the 2026-07-20 incident scenario where the
                # agent runs from a non-primary linked worktree and the primary checkout
                # (which `git worktree remove` can never target) shows up as a sibling.
                if (Test-WorktreeIsPrimary -WorktreePath $record.WorktreePath) {
                    continue
                }

                $branchName = $record.BranchName
                if ($branchName -eq $DefaultBranch) {
                    continue
                }

                $upstreamBranch = $null
                if ($record.IsPrunable) {
                    $upstreamBranch = Get-SCDConfiguredUpstreamBranch -BranchName $branchName
                }
                else {
                    $upstreamRef = (git -C $record.WorktreePath rev-parse --abbrev-ref '@{u}' 2>$null)
                    if ($LASTEXITCODE -eq 0) {
                        $upstreamBranch = ConvertFrom-SCDUpstreamRef -UpstreamRef $upstreamRef -FallbackBranchName $branchName
                    }
                }

                if ($null -ne $upstreamBranch) {
                    if (-not (Test-SCDBranchMatchesPrefixes -BranchName $branchName -Prefixes $UpstreamDeletedBranchPrefixes)) {
                        continue
                    }

                    if (Test-SCDRemoteHeadMissing -RemoteName $upstreamBranch.RemoteName -BranchPattern $upstreamBranch.BranchName) {
                        $eligibility = Get-SCDGatedEligibility -Budget $GhBudget -Category 'sibling' -BranchName $branchName -DefaultBranch $DefaultBranch -IsDegradedCwd $IsDegradedCwd
                        $cleanups += @{
                            BranchName         = $branchName
                            WorktreePath       = $normalizedPath
                            Reason             = $eligibility.Evidence
                            Eligible           = $eligibility.Eligible
                            ManualReviewReason = $eligibility.ManualReviewReason
                            IsLocked           = $record.IsLocked
                            LockReason         = $record.LockReason
                            IsPrunable         = $record.IsPrunable
                        }
                    }
                    continue
                }

                if (-not (Test-SCDBranchMatchesPrefixes -BranchName $branchName -Prefixes $NoUpstreamBranchPrefixes)) {
                    continue
                }

                if ($null -eq $remoteDefault) {
                    continue
                }

                if (-not (Test-SCDGitRefExists -RefName $remoteDefault.RefName)) {
                    continue
                }

                if (Test-SCDMergeBaseAncestor -BranchName $branchName -TargetRef $remoteDefault.RefName -WorktreePath $record.WorktreePath) {
                    $eligibility = Get-SCDGatedEligibility -Budget $GhBudget -Category 'sibling' -BranchName $branchName -DefaultBranch $DefaultBranch -IsDegradedCwd $IsDegradedCwd
                    $cleanups += @{
                        BranchName         = $branchName
                        WorktreePath       = $normalizedPath
                        Reason             = $eligibility.Evidence
                        RemoteDefaultRef   = $remoteDefault.RefName
                        Eligible           = $eligibility.Eligible
                        ManualReviewReason = $eligibility.ManualReviewReason
                        IsLocked           = $record.IsLocked
                        LockReason         = $record.LockReason
                        IsPrunable         = $record.IsPrunable
                    }
                }
            }
            catch {
                $null = $_
            }
        }
    }
    catch {
        $null = $_
    }

    return $cleanups
}

function New-SCDStringLookup {
    return [System.Collections.Generic.Dictionary[string, bool]]::new([System.StringComparer]::Ordinal)
}

function Add-SCDLookupValue {
    param(
        [Parameter(Mandatory)]
        [System.Collections.Generic.IDictionary[string, bool]]$Lookup,

        [string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return
    }

    if (-not $Lookup.ContainsKey($Value)) {
        $Lookup[$Value] = $true
    }
}

function Invoke-SCDNonInteractiveFetchOnce {
    param(
        [Parameter(Mandatory)]
        [string]$RemoteName,

        [string]$CacheKey = '',

        [AllowNull()]
        [System.Collections.Generic.IDictionary[string, bool]]$FetchLookup = $null
    )

    if ([string]::IsNullOrWhiteSpace($RemoteName)) {
        return
    }

    if ($null -eq $FetchLookup) {
        Invoke-SCDNonInteractiveFetch -RemoteName $RemoteName
        return
    }

    $resolvedCacheKey = if ([string]::IsNullOrWhiteSpace($CacheKey)) { $RemoteName } else { $CacheKey }
    if ($FetchLookup.ContainsKey($resolvedCacheKey)) {
        return
    }

    Add-SCDLookupValue -Lookup $FetchLookup -Value $resolvedCacheKey
    Invoke-SCDNonInteractiveFetch -RemoteName $RemoteName
}

function Get-SCDBranchConfigValue {
    param(
        [Parameter(Mandatory)]
        [string]$BranchName,

        [Parameter(Mandatory)]
        [string]$Name
    )

    if ([string]::IsNullOrWhiteSpace($BranchName) -or [string]::IsNullOrWhiteSpace($Name)) {
        return ''
    }

    try {
        $value = (git config --get "branch.$BranchName.$Name" 2>$null)
        if ($LASTEXITCODE -eq 0) {
            $text = (($value | Select-Object -First 1) -as [string])
            if (-not [string]::IsNullOrWhiteSpace($text)) {
                return $text.Trim()
            }
        }
    }
    catch {
        $null = $_
    }

    return ''
}

function Get-SCDConfiguredUpstreamBranch {
    param(
        [Parameter(Mandatory)]
        [string]$BranchName
    )

    $remoteName = Get-SCDBranchConfigValue -BranchName $BranchName -Name 'remote'
    $mergeRef = Get-SCDBranchConfigValue -BranchName $BranchName -Name 'merge'
    if ([string]::IsNullOrWhiteSpace($remoteName) -or [string]::IsNullOrWhiteSpace($mergeRef)) {
        return $null
    }

    $remoteBranchName = $mergeRef
    if ($mergeRef -match '^refs/heads/(.+)$') {
        $remoteBranchName = $Matches[1]
    }
    if ([string]::IsNullOrWhiteSpace($remoteBranchName)) {
        return $null
    }

    return @{
        RemoteName = $remoteName
        BranchName = $remoteBranchName
    }
}

function Get-SCDAttachedBranchLookup {
    param(
        [string]$CurrentBranch,

        [AllowNull()]
        [array]$WorktreeRecords = $null
    )

    $attachedBranches = New-SCDStringLookup
    Add-SCDLookupValue -Lookup $attachedBranches -Value $CurrentBranch

    try {
        if ($null -eq $WorktreeRecords) {
            $worktreePorcelain = @(git worktree list --porcelain 2>$null)
            if ($LASTEXITCODE -ne 0) {
                return $null
            }
            $records = @(Get-SCDWorktreeRecords -PorcelainLines $worktreePorcelain)
        }
        else {
            $records = $WorktreeRecords
        }

        foreach ($record in $records) {
            Add-SCDLookupValue -Lookup $attachedBranches -Value $record.BranchName
        }
    }
    catch {
        return $null
    }

    return $attachedBranches
}

function Get-SCDLocalBranchNames {
    param(
        [Parameter(Mandatory)]
        [string]$RefPrefix
    )

    try {
        $branchNames = @(git for-each-ref --format='%(refname:short)' $RefPrefix 2>$null)
        if ($LASTEXITCODE -ne 0) {
            return @()
        }

        return @($branchNames |
                ForEach-Object { ($_ -as [string]).Trim() } |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }
    catch {
        return @()
    }
}

function Get-SCDOrphanBranchCleanups {
    param(
        [string]$CurrentBranch,

        [Parameter(Mandatory)]
        [string]$DefaultBranch,

        [Parameter(Mandatory)]
        [string[]]$NoUpstreamBranchPrefixes,

        [string[]]$UpstreamDeletedBranchPrefixes = @('feature/issue-'),

        [AllowNull()]
        [System.Collections.Generic.IDictionary[string, bool]]$FetchLookup = $null,

        [AllowNull()]
        [array]$WorktreeRecords = $null,

        [hashtable]$GhBudget = (New-SCDCollectionGhBudget),

        [bool]$IsDegradedCwd = $false
    )

    $cleanups = @()
    $attachedBranchLookup = Get-SCDAttachedBranchLookup -CurrentBranch $CurrentBranch -WorktreeRecords $WorktreeRecords
    if ($null -eq $attachedBranchLookup) {
        return @()
    }

    $evaluatedNoUpstreamBranches = New-SCDStringLookup
    $noUpstreamCandidates = @()

    foreach ($branchPrefix in $NoUpstreamBranchPrefixes) {
        if ([string]::IsNullOrWhiteSpace($branchPrefix)) {
            continue
        }

        $refPrefix = "refs/heads/$($branchPrefix.TrimStart('/'))"
        foreach ($branchName in @(Get-SCDLocalBranchNames -RefPrefix $refPrefix)) {
            if ($branchName -eq $DefaultBranch -or $attachedBranchLookup.ContainsKey($branchName)) {
                continue
            }

            $remoteConfig = Get-SCDBranchConfigValue -BranchName $branchName -Name 'remote'
            $mergeConfig = Get-SCDBranchConfigValue -BranchName $branchName -Name 'merge'
            if (-not [string]::IsNullOrWhiteSpace($remoteConfig) -or -not [string]::IsNullOrWhiteSpace($mergeConfig)) {
                continue
            }

            Add-SCDLookupValue -Lookup $evaluatedNoUpstreamBranches -Value $branchName
            $noUpstreamCandidates += $branchName
        }
    }

    if ($noUpstreamCandidates.Count -gt 0) {
        $remoteDefault = Get-SCDRemoteDefaultRef -DefaultBranch $DefaultBranch
        Invoke-SCDNonInteractiveFetchOnce -RemoteName $remoteDefault.RemoteName -CacheKey $remoteDefault.RefName -FetchLookup $FetchLookup

        if (Test-SCDGitRefExists -RefName $remoteDefault.RefName) {
            foreach ($branchName in $noUpstreamCandidates) {
                if (Test-SCDMergeBaseAncestor -BranchName $branchName -TargetRef $remoteDefault.RefName) {
                    $eligibility = Get-SCDGatedEligibility -Budget $GhBudget -Category 'orphan' -BranchName $branchName -DefaultBranch $DefaultBranch -IsDegradedCwd $IsDegradedCwd
                    $cleanups += @{
                        BranchName         = $branchName
                        Reason             = $eligibility.Evidence
                        RemoteDefaultRef   = $remoteDefault.RefName
                        Eligible           = $eligibility.Eligible
                        ManualReviewReason = $eligibility.ManualReviewReason
                        Kind               = 'orphan-no-upstream'
                    }
                }
            }
        }
    }

    foreach ($branchName in @(Get-SCDLocalBranchNames -RefPrefix 'refs/heads/')) {
        if (
            $branchName -eq $DefaultBranch -or
            $attachedBranchLookup.ContainsKey($branchName) -or
            $evaluatedNoUpstreamBranches.ContainsKey($branchName)
        ) {
            continue
        }

        if (-not (Test-SCDBranchMatchesPrefixes -BranchName $branchName -Prefixes $UpstreamDeletedBranchPrefixes)) {
            continue
        }

        $upstreamBranch = Get-SCDConfiguredUpstreamBranch -BranchName $branchName
        if ($null -eq $upstreamBranch) {
            continue
        }

        if (Test-SCDRemoteHeadMissing -RemoteName $upstreamBranch.RemoteName -BranchPattern $upstreamBranch.BranchName) {
            $eligibility = Get-SCDGatedEligibility -Budget $GhBudget -Category 'orphan' -BranchName $branchName -DefaultBranch $DefaultBranch -IsDegradedCwd $IsDegradedCwd
            $cleanups += @{
                BranchName         = $branchName
                Reason             = $eligibility.Evidence
                Eligible           = $eligibility.Eligible
                ManualReviewReason = $eligibility.ManualReviewReason
                Kind               = 'orphan-upstream'
            }
        }
    }

    return $cleanups
}

function Get-SCDOrphanBranchLines {
    param([array]$Items)

    $out = @()
    foreach ($item in $Items) {
        $line = "- Orphan branch ``$($item.BranchName)`` — $($item.Reason)"
        if ($item.BranchName -match $script:OrphanIssueRegex) {
            $line += '; eligible for auto-resolve at cleanup time'
        }
        $out += $line
    }
    return $out
}

function Invoke-SessionCleanupDetector {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [string]$RepoRoot = ''
    )

    $ErrorActionPreference = 'SilentlyContinue'

    if (-not $RepoRoot) {
        $output = [pscustomobject]@{
            hookSpecificOutput = [pscustomobject]@{
                hookEventName     = 'SessionStart'
                additionalContext = 'Repo root could not be resolved for the session startup check. Ensure the agent-orchestra plugin is installed correctly (or that session-cleanup-detector.ps1 is invoked from its repo-relative location).'
            }
        } | ConvertTo-Json -Depth 3 -Compress
        return @{ ExitCode = 1; Output = $output; Error = '' }
    }

    if (-not (Get-Command Get-SCDPersistentTrackingExclusions -ErrorAction SilentlyContinue)) {
        $errorJson = [pscustomobject]@{
            hookSpecificOutput = [pscustomobject]@{
                hookEventName     = 'SessionStart'
                additionalContext = 'HALT: Get-SCDPersistentTrackingExclusions is not defined — session-startup-git-helpers.ps1 failed to load. Aborting detector to prevent false-positive cleanup recommendations.'
            }
        } | ConvertTo-Json -Depth 3 -Compress
        return @{ ExitCode = 1; Output = $errorJson; Error = 'Accessor undefined: Get-SCDPersistentTrackingExclusions' }
    }
    $exclusions = Get-SCDPersistentTrackingExclusions
    if ($null -eq $exclusions -or $null -eq $exclusions.Filenames) {
        $haltJson = [pscustomobject]@{
            hookSpecificOutput = [pscustomobject]@{
                hookEventName     = 'SessionStart'
                additionalContext = 'HALT: Get-SCDPersistentTrackingExclusions returned $null or missing Filenames — registry integrity failure. Aborting detector to prevent false-positive cleanup recommendations.'
            }
        } | ConvertTo-Json -Depth 3 -Compress
        return @{ ExitCode = 1; Output = $haltJson; Error = 'Accessor returned null or missing Filenames' }
    }
    $persistentTrackingSubtrees = if ($null -ne $exclusions.Subtrees) { [string[]]$exclusions.Subtrees } else { [string[]]@() }
    $persistentTrackingFilenames = [string[]]$exclusions.Filenames
    $noUpstreamBranchPrefixes = @('claude/')
    $upstreamDeletedBranchPrefixes = @('feature/issue-')
    $fetchLookup = New-SCDStringLookup
    $ghBudget = New-SCDCollectionGhBudget

    # ============================================================
    # STEP 0: WORKTREE REGISTRY + DEGRADED-CWD DETECTION (Issue #889 s4)
    # Computed before STEP 1 so the current-branch (site 5) check below can
    # consult $isDegradedCwd, and reused by the sibling/orphan calls further
    # down instead of a second `git worktree list --porcelain` invocation.
    # ============================================================
    $worktreeRecords = $null
    try {
        $worktreePorcelain = @(git worktree list --porcelain 2>$null)
        if ($LASTEXITCODE -eq 0) {
            $worktreeRecords = @(Get-SCDWorktreeRecords -PorcelainLines $worktreePorcelain)
        }
    }
    catch {
        $null = $_
    }

    # Issue #897 review fix (G1): use the caller-resolved $RepoRoot (the wrapper
    # derives this via `git rev-parse --show-toplevel`, which survives a
    # SessionStart hook launched from a subdirectory of the worktree) instead
    # of re-deriving from Get-Location. Get-Location returns the raw launch
    # CWD, which is a SUBDIRECTORY for a supported subdirectory launch — that
    # would never equal a `worktree list --porcelain` root record, causing
    # this site to misreport "not in a registered worktree" for an ordinary
    # in-worktree invocation. $RepoRoot is guaranteed non-empty here (the
    # empty case returns early above).
    $currentLocationPath = $RepoRoot
    # Degraded only when we have POSITIVE evidence the current location is not a
    # registered worktree — an empty/unavailable registry (common when a caller
    # never mocks `worktree list`, and never possible for a real git repo) is
    # treated as non-degraded so it never masks the git-only sibling/orphan
    # detection paths, which do not themselves depend on worktree records.
    $isDegradedCwd = ($null -ne $worktreeRecords -and $worktreeRecords.Count -gt 0 -and -not (Test-SCDCurrentLocationMatchesWorktreeRecord -CurrentPath $currentLocationPath -WorktreeRecords $worktreeRecords))

    # ============================================================
    # STEP 1: BRANCH CHECK (runs before tracking-file gate)
    # ============================================================
    $staleBranch = $null
    $currentNoUpstreamWorktree = $null
    $siblingWorktreeCleanups = @()
    $orphanBranchCleanups = @()
    $defaultBranch = 'main'   # initialise; resolved below only if needed

    $currentBranch = (git branch --show-current 2>$null)
    if ($LASTEXITCODE -ne 0) { $currentBranch = '' }

    if ($currentBranch) {
        $defaultBranch = Get-SCDDefaultBranch

        if ($currentBranch -ne $defaultBranch) {
            # Check if an upstream tracking ref is configured (never-pushed branches have none)
            $upstreamRef = (git rev-parse --abbrev-ref '@{u}' 2>$null)
            $upstreamExitCode = $LASTEXITCODE
            if ($upstreamExitCode -eq 0) {
                # Has upstream — check whether the remote branch still exists
                $upstreamBranch = ConvertFrom-SCDUpstreamRef -UpstreamRef $upstreamRef -FallbackBranchName $currentBranch
                if ($null -ne $upstreamBranch -and (Test-SCDRemoteHeadMissing -RemoteName $upstreamBranch.RemoteName -BranchPattern $upstreamBranch.BranchName)) {
                    # Remote branch is gone — stale branch detected
                    $branchIssueId = $null
                    if ($currentBranch -match $script:OrphanIssueRegex) {
                        $branchIssueId = $Matches[1]
                    }
                    # Finding G (#889 fix cycle): this was the sixth candidate-append
                    # site never routed through Get-SCDGatedEligibility — the other
                    # five (sibling x2, orphan x2, current-no-upstream) all gate
                    # through the shared primitive before being reported as
                    # cleanup-ready. This site's -FeatureBranch composite command is
                    # still independently re-verified by post-merge-cleanup.ps1's own
                    # eligibility check before any deletion occurs (M9/AC3), so
                    # gating here is a reporting-honesty fix, not a new safety net —
                    # but the manual-review reason is now surfaced so an ineligible
                    # stale branch is visibly flagged rather than silently presented
                    # as if the composite command were unconditionally safe to run.
                    $staleEligibility = Get-SCDGatedEligibility -Budget $ghBudget -Category 'current' -BranchName $currentBranch -DefaultBranch $defaultBranch -IsDegradedCwd $isDegradedCwd
                    $staleBranch = @{
                        BranchName         = $currentBranch
                        IssueId            = $branchIssueId
                        Eligible           = $staleEligibility.Eligible
                        Evidence           = $staleEligibility.Evidence
                        ManualReviewReason = $staleEligibility.ManualReviewReason
                    }
                }
            }
            else {
                $isNoUpstreamCandidate = Test-SCDBranchMatchesPrefixes -BranchName $currentBranch -Prefixes $noUpstreamBranchPrefixes

                # Issue #889 s4 (site 5, D2/AC2/AC7): structural primary-worktree guard and
                # degraded-CWD suppression, both applied before spending a fetch/ancestry
                # call. Primary is excluded because `git worktree remove` can never target
                # the primary checkout; degraded CWD is suppressed because (Get-Location).Path
                # cannot be trusted to name a real worktree when it matches no registered
                # record (this is the "current branch" category — sibling/orphan candidates
                # get a softer report-only downgrade instead of outright suppression).
                if ($isNoUpstreamCandidate -and -not $isDegradedCwd -and -not (Test-WorktreeIsPrimary -WorktreePath $currentLocationPath)) {
                    $remoteDefault = Get-SCDRemoteDefaultRef -DefaultBranch $defaultBranch
                    Invoke-SCDNonInteractiveFetchOnce -RemoteName $remoteDefault.RemoteName -CacheKey $remoteDefault.RefName -FetchLookup $fetchLookup

                    if (Test-SCDGitRefExists -RefName $remoteDefault.RefName) {
                        if (Test-SCDMergeBaseAncestor -BranchName $currentBranch -TargetRef $remoteDefault.RefName) {
                            $eligibility = Get-SCDGatedEligibility -Budget $ghBudget -Category 'current' -BranchName $currentBranch -DefaultBranch $defaultBranch
                            $currentNoUpstreamWorktree = @{
                                BranchName         = $currentBranch
                                RemoteDefaultRef   = $remoteDefault.RefName
                                WorktreePath       = $currentLocationPath
                                Eligible           = $eligibility.Eligible
                                Evidence           = $eligibility.Evidence
                                ManualReviewReason = $eligibility.ManualReviewReason
                            }
                        }
                    }
                }
            }
        }
    }

    $siblingWorktreeCleanups = @(Get-SCDSiblingWorktreeCleanups -CurrentWorktreePath $currentLocationPath -DefaultBranch $defaultBranch -NoUpstreamBranchPrefixes $noUpstreamBranchPrefixes -UpstreamDeletedBranchPrefixes $upstreamDeletedBranchPrefixes -FetchLookup $fetchLookup -WorktreeRecords $worktreeRecords -GhBudget $ghBudget -IsDegradedCwd $isDegradedCwd)
    $orphanBranchCleanups = @(Get-SCDOrphanBranchCleanups -CurrentBranch $currentBranch -DefaultBranch $defaultBranch -NoUpstreamBranchPrefixes $noUpstreamBranchPrefixes -UpstreamDeletedBranchPrefixes $upstreamDeletedBranchPrefixes -FetchLookup $fetchLookup -WorktreeRecords $worktreeRecords -GhBudget $ghBudget -IsDegradedCwd $isDegradedCwd)

    # ============================================================
    # STEP 2: TRACKING FILE CHECK (existing logic, intact)
    # ============================================================
    $cleanupNeeded = @()
    $trackingRoot = '.copilot-tracking'

    if (Test-Path $trackingRoot) {
        $trackingRootPath = [System.IO.Path]::GetFullPath((Join-Path (Get-Location) $trackingRoot))
        $trackingFiles = @(Get-ChildItem -Path $trackingRoot -Recurse -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -notmatch '^\.gitkeep$' })

        if ($trackingFiles.Count -gt 0) {
            $issueIds = @()
            $unknownFiles = @()
            foreach ($file in $trackingFiles) {
                if (Test-SCDPersistentTrackingFile -TrackingRootPath $trackingRootPath -File $file -PersistentSubtrees $persistentTrackingSubtrees -PersistentFilenames $persistentTrackingFilenames) {
                    continue
                }

                $content = Get-Content -Path $file.FullName -Raw -ErrorAction SilentlyContinue
                if ($content -match '(?m)^issue_id:\s*["\x27]?(\d+)["\x27]?') {
                    $id = $Matches[1]
                    if ($id -notin $issueIds) {
                        $issueIds += $id
                    }
                }
                else {
                    $unknownFiles += $file.FullName
                }
            }

            if ($unknownFiles.Count -gt 0 -and $issueIds -notcontains 'unknown') {
                $issueIds += 'unknown'
            }

            foreach ($id in $issueIds) {
                if ($id -eq 'unknown') {
                    $cleanupNeeded += @{
                        IssueId      = $id
                        BranchName   = $null
                        UnknownFiles = $unknownFiles
                    }
                    continue
                }

                # Check for remote branches matching feature/issue-{id}-*
                $remoteHeadMissing = Test-SCDRemoteHeadMissing -RemoteName 'origin' -BranchPattern "feature/issue-$id-*"
                $localBranches = @(git branch --list "feature/issue-$id-*" 2>$null |
                        ForEach-Object { ($_ -replace '^\* ', '').Trim() } |
                        Where-Object { $_ })
                $localBranch = $localBranches | Select-Object -First 1
                if ($LASTEXITCODE -ne 0) { $localBranches = @(); $localBranch = $null }

                if ($remoteHeadMissing) {
                    $cleanupNeeded += @{ IssueId = $id; BranchName = $localBranch; AllBranches = $localBranches }
                }
            }
        }
    }

    # ============================================================
    # STEP 3: MERGE & OUTPUT
    # ============================================================
    if ($null -eq $staleBranch -and $cleanupNeeded.Count -eq 0 -and $null -eq $currentNoUpstreamWorktree -and $siblingWorktreeCleanups.Count -eq 0 -and $orphanBranchCleanups.Count -eq 0) {
        return @{ ExitCode = 0; Output = '{}'; Error = '' }
    }

    $lines = @()

    # Helper: emit tracking-file bullet lines
    function Get-TrackingLines {
        param([array]$Items)
        $out = @()
        foreach ($item in $Items) {
            if ($item.IssueId -eq 'unknown') {
                $count = $item.UnknownFiles.Count
                $fileList = ($item.UnknownFiles | ForEach-Object { "  - ``$_``" }) -join "`n"
                $out += "- $count tracking file(s) with no issue ID found in ```.copilot-tracking/```:"
                $out += $fileList
            }
            else {
                $extra = if ($item.AllBranches.Count -gt 1) { " +$($item.AllBranches.Count - 1) more" } else { '' }
                $branchInfo = if ($item.BranchName) { " (local branch: ``$($item.BranchName)``$extra)" } else { '' }
                $out += "- Issue #$($item.IssueId)$branchInfo — remote branch merged/deleted"
            }
        }
        return $out
    }

    function Get-CurrentNoUpstreamWorktreeLines {
        param([hashtable]$Item)

        $out = @()
        if (-not $Item.Eligible) {
            $out += "- Current Claude worktree branch ``$($Item.BranchName)`` at ``$($Item.WorktreePath)`` needs manual review: $($Item.ManualReviewReason)"
            return $out
        }

        $safeWorktreePath = ConvertTo-SCDPowerShellSingleQuoteEscapedText -Value $Item.WorktreePath
        $safeBranch = ConvertTo-SCDPowerShellSingleQuoteEscapedText -Value $Item.BranchName
        $out += "- Current Claude worktree branch ``$($Item.BranchName)`` — $($Item.Evidence)."
        $out += ''
        $out += "Current-worktree cleanup must be run from another checkout: ``git worktree remove '$safeWorktreePath'`` followed by ``git branch -D '$safeBranch'``."
        return $out
    }

    function Get-SCDStaleBranchLine {
        <#
        .SYNOPSIS
            Finding G (#889 fix cycle): renders the current-branch stale-branch
            bullet, appending a manual-review annotation when the eligibility
            gate (Get-SCDGatedEligibility, computed at STEP 1 detection time)
            declined. The base "remote branch merged/deleted" wording is
            preserved unconditionally — it is a factual detection statement,
            true regardless of eligibility — and the composite -FeatureBranch
            command is still emitted either way, since post-merge-cleanup.ps1
            independently re-verifies eligibility before any deletion (M9/AC3);
            this annotation is a reporting-honesty improvement, not a new
            deletion gate.
        #>
        param([hashtable]$StaleBranch)

        $line = "- Current branch ``$($StaleBranch.BranchName)`` — remote branch merged/deleted"
        if ($StaleBranch.ContainsKey('Eligible') -and -not $StaleBranch.Eligible) {
            $line += " (needs manual review before running the cleanup command below: $($StaleBranch.ManualReviewReason))"
        }
        return $line
    }

    function Get-SiblingWorktreeLines {
        param([array]$Items)

        $out = @()
        foreach ($item in $Items) {
            $lockInfo = ''
            if ($item.IsLocked) {
                $lockInfo = if ([string]::IsNullOrWhiteSpace($item.LockReason)) { ' (locked)' } else { " (locked: $($item.LockReason))" }
            }
            elseif ($item.IsPrunable) {
                $lockInfo = ' (prunable)'
            }

            $out += "- Sibling worktree branch ``$($item.BranchName)`` at ``$($item.WorktreePath)`` — $($item.Reason)$lockInfo"
        }
        return $out
    }

    # Safe root: single-quoted in emitted commands handles $ and " characters in the path
    $safeRoot = ConvertTo-SCDPowerShellSingleQuoteEscapedText -Value $RepoRoot

    # Helper: emit cleanup command lines for tracking-file items
    function Get-TrackingCommands {
        param([array]$Items)
        $out = @()
        $out += '# Run in a PowerShell (pwsh) terminal:'
        foreach ($item in $Items) {
            if ($item.IssueId -ne 'unknown') {
                if ($item.BranchName) {
                    foreach ($b in $item.AllBranches) {
                        $safeB = ConvertTo-SCDPowerShellSingleQuoteEscapedText -Value $b
                        $out += "pwsh '$safeRoot/skills/session-startup/scripts/post-merge-cleanup.ps1' -IssueNumber $($item.IssueId) -FeatureBranch '$safeB'"
                    }
                }
                else {
                    $out += "pwsh '$safeRoot/skills/session-startup/scripts/post-merge-cleanup.ps1' -IssueNumber $($item.IssueId) -SkipRemoteDelete -SkipLocalDelete  # branch not found locally; archives tracking files only"
                }
            }
            else {
                # Unknown issue ID: emit -UntaggedTrackingFiles invocation
                $relPaths = @($item.UnknownFiles | ForEach-Object {
                    $rel = [System.IO.Path]::GetRelativePath((Get-Location).Path, $_).Replace('\', '/')
                    "'" + (ConvertTo-SCDPowerShellSingleQuoteEscapedText -Value $rel) + "'"
                })
                if ($relPaths.Count -gt 0) {
                    $out += "pwsh '$safeRoot/skills/session-startup/scripts/post-merge-cleanup.ps1' -UntaggedTrackingFiles @($($relPaths -join ','))"
                }
            }
        }
        return $out
    }

    function Get-ClaudeCleanupKey {
        param(
            [Parameter(Mandatory)]
            [string]$Kind,

            [Parameter(Mandatory)]
            [hashtable]$Item
        )

        if ($Kind -eq 'sibling') {
            return "sibling|$($Item.BranchName)|$($Item.WorktreePath)"
        }

        return "orphan|$($Item.BranchName)"
    }

    $escaped = if ($null -ne $staleBranch) { ConvertTo-SCDPowerShellSingleQuoteEscapedText -Value $staleBranch.BranchName } else { $null }
    $escapedDefault = ConvertTo-SCDPowerShellSingleQuoteEscapedText -Value $defaultBranch

    $claudeCleanupLimit = 10
    $claudeCleanupKeys = @()
    if (
        $null -ne $currentNoUpstreamWorktree -and
        (Test-SCDBranchMatchesPrefixes -BranchName $currentNoUpstreamWorktree.BranchName -Prefixes $noUpstreamBranchPrefixes)
    ) {
        $claudeCleanupKeys += "current|$($currentNoUpstreamWorktree.BranchName)"
    }
    foreach ($item in $siblingWorktreeCleanups) {
        if (Test-SCDBranchMatchesPrefixes -BranchName $item.BranchName -Prefixes $noUpstreamBranchPrefixes) {
            $claudeCleanupKeys += (Get-ClaudeCleanupKey -Kind 'sibling' -Item $item)
        }
    }
    foreach ($item in $orphanBranchCleanups) {
        if (Test-SCDBranchMatchesPrefixes -BranchName $item.BranchName -Prefixes $noUpstreamBranchPrefixes) {
            $claudeCleanupKeys += (Get-ClaudeCleanupKey -Kind 'orphan' -Item $item)
        }
    }

    $hiddenClaudeCleanupCount = 0
    $visibleSiblingWorktreeCleanups = @($siblingWorktreeCleanups)
    $visibleOrphanBranchCleanups = @($orphanBranchCleanups)
    if ($claudeCleanupKeys.Count -gt $claudeCleanupLimit) {
        $hiddenClaudeCleanupCount = $claudeCleanupKeys.Count - $claudeCleanupLimit
        $visibleClaudeCleanupLookup = New-SCDStringLookup
        foreach ($key in @($claudeCleanupKeys | Select-Object -First $claudeCleanupLimit)) {
            Add-SCDLookupValue -Lookup $visibleClaudeCleanupLookup -Value $key
        }

        $visibleSiblingWorktreeCleanups = @($siblingWorktreeCleanups | Where-Object {
                -not (Test-SCDBranchMatchesPrefixes -BranchName $_.BranchName -Prefixes $noUpstreamBranchPrefixes) -or
                $visibleClaudeCleanupLookup.ContainsKey((Get-ClaudeCleanupKey -Kind 'sibling' -Item $_))
            })
        $visibleOrphanBranchCleanups = @($orphanBranchCleanups | Where-Object {
                -not (Test-SCDBranchMatchesPrefixes -BranchName $_.BranchName -Prefixes $noUpstreamBranchPrefixes) -or
                $visibleClaudeCleanupLookup.ContainsKey((Get-ClaudeCleanupKey -Kind 'orphan' -Item $_))
            })
    }

    # Issue #889 s4 (D6): split visible candidates into eligible (render via the
    # normal per-category line renderer + composite args) and manual-review
    # (render via Get-SCDManualReviewLines, excluded from composite args) —
    # a candidate renders through exactly one of the two, never both.
    $eligibleVisibleSiblingWorktreeCleanups = @($visibleSiblingWorktreeCleanups | Where-Object { $_.Eligible })
    $manualReviewVisibleSiblingWorktreeCleanups = @($visibleSiblingWorktreeCleanups | Where-Object { -not $_.Eligible })
    $eligibleVisibleOrphanBranchCleanups = @($visibleOrphanBranchCleanups | Where-Object { $_.Eligible })
    $manualReviewVisibleOrphanBranchCleanups = @($visibleOrphanBranchCleanups | Where-Object { -not $_.Eligible })

    if ($siblingWorktreeCleanups.Count -gt 0 -or $orphanBranchCleanups.Count -gt 0) {
        $signalNames = @()
        if ($null -ne $staleBranch) { $signalNames += 'stale branch' }
        if ($cleanupNeeded.Count -gt 0) { $signalNames += 'tracking artifacts' }
        if ($null -ne $currentNoUpstreamWorktree) { $signalNames += 'current Claude worktree branch' }
        if ($siblingWorktreeCleanups.Count -gt 0) { $signalNames += 'sibling worktrees' }
        if ($orphanBranchCleanups.Count -gt 0) { $signalNames += 'orphan branches' }

        $lines += "**Post-merge cleanup detected** — $($signalNames -join ', ') found:"
        $lines += ''
        if ($null -ne $staleBranch) {
            $lines += (Get-SCDStaleBranchLine -StaleBranch $staleBranch)
            $lines += ''
        }
        if ($null -ne $currentNoUpstreamWorktree) {
            $lines += (Get-CurrentNoUpstreamWorktreeLines -Item $currentNoUpstreamWorktree)
            $lines += ''
        }
        if ($cleanupNeeded.Count -gt 0) {
            $lines += (Get-TrackingLines -Items $cleanupNeeded)
            $lines += ''
        }
        if ($eligibleVisibleSiblingWorktreeCleanups.Count -gt 0) {
            $lines += (Get-SiblingWorktreeLines -Items $eligibleVisibleSiblingWorktreeCleanups)
        }
        if ($eligibleVisibleOrphanBranchCleanups.Count -gt 0) {
            $lines += (Get-SCDOrphanBranchLines -Items $eligibleVisibleOrphanBranchCleanups)
        }
        if ($manualReviewVisibleSiblingWorktreeCleanups.Count -gt 0) {
            $lines += (Get-SCDManualReviewLines -Label 'Sibling worktree branch' -Items $manualReviewVisibleSiblingWorktreeCleanups)
        }
        if ($manualReviewVisibleOrphanBranchCleanups.Count -gt 0) {
            $lines += (Get-SCDManualReviewLines -Label 'Orphan branch' -Items $manualReviewVisibleOrphanBranchCleanups)
        }
        if ($hiddenClaudeCleanupCount -gt 0) {
            $lines += "- +$hiddenClaudeCleanupCount more — run ``git for-each-ref --format='%(refname:short)' refs/heads/claude/`` to see the full list."
        }
        if ($isDegradedCwd) {
            $lines += ''
            $lines += '_Note: the current location did not match a registered worktree, so sibling and orphan branch findings above are report-only — re-run from a registered worktree to enable one-click cleanup._'
        }
        $lines += ''
        $lines += 'To clean up, run:'
        $lines += '```powershell'
        $lines += '# Run in a PowerShell (pwsh) terminal:'

        # Build composite invocation
        $compositeArgs = @()
        if ($null -ne $staleBranch -and $staleBranch.IssueId) {
            $compositeArgs += "-IssueNumber $($staleBranch.IssueId)"
            $compositeArgs += "-FeatureBranch '$escaped'"
            # Auto-wire -TmpRoot when .tmp/ exists and we have an issue number to clear scratch for
            if (Test-Path (Join-Path $RepoRoot '.tmp')) {
                $compositeArgs += "-TmpRoot '$safeRoot/.tmp'"
            }
        }
        # C1+G4+C6: Route no-issue-id stale-branch cleanup through the composite
        # script via -FeatureBranch so the fenced block stays a single pwsh call
        # and triggers exactly one permission prompt — not raw 'git checkout && git pull
        # && git branch -d' lines that would re-introduce the multi-prompt problem.
        if ($null -ne $staleBranch -and -not $staleBranch.IssueId) {
            $compositeArgs += "-FeatureBranch '$escaped'"
        }
        if ($eligibleVisibleSiblingWorktreeCleanups.Count -gt 0) {
            $siblingPaths = $eligibleVisibleSiblingWorktreeCleanups | ForEach-Object {
                "'" + (ConvertTo-SCDPowerShellSingleQuoteEscapedText -Value $_.WorktreePath) + "'"
            }
            $compositeArgs += "-SiblingWorktrees @($($siblingPaths -join ','))"
        }
        if ($eligibleVisibleOrphanBranchCleanups.Count -gt 0) {
            $orphanNames = $eligibleVisibleOrphanBranchCleanups | ForEach-Object {
                "'" + (ConvertTo-SCDPowerShellSingleQuoteEscapedText -Value $_.BranchName) + "'"
            }
            $compositeArgs += "-OrphanBranches @($($orphanNames -join ','))"
        }
        # Untagged tracking files (unknown issue ID)
        if ($cleanupNeeded.Count -gt 0) {
            $untaggedItems = @($cleanupNeeded | Where-Object { $_.IssueId -eq 'unknown' })
            if ($untaggedItems.Count -gt 0) {
                $allUntaggedPaths = @($untaggedItems | ForEach-Object { $_.UnknownFiles } | ForEach-Object {
                    $rel = [System.IO.Path]::GetRelativePath((Get-Location).Path, $_).Replace('\', '/')
                    "'" + (ConvertTo-SCDPowerShellSingleQuoteEscapedText -Value $rel) + "'"
                })
                if ($allUntaggedPaths.Count -gt 0) {
                    $compositeArgs += "-UntaggedTrackingFiles @($($allUntaggedPaths -join ','))"
                }
            }
            # Known-issue tracking files: emit separate invocations for issues not covered by staleBranch
            $taggedCleanup = @($cleanupNeeded | Where-Object { $_.IssueId -ne 'unknown' })
            $otherIssueCleanup = @($taggedCleanup | Where-Object { $null -eq $staleBranch -or $_.IssueId -ne $staleBranch.IssueId })
            foreach ($item in $otherIssueCleanup) {
                $safeB = ConvertTo-SCDPowerShellSingleQuoteEscapedText -Value ($item.BranchName ?? '')
                if ($item.BranchName) {
                    $lines += "pwsh '$safeRoot/skills/session-startup/scripts/post-merge-cleanup.ps1' -IssueNumber $($item.IssueId) -FeatureBranch '$safeB'"
                } else {
                    $lines += "pwsh '$safeRoot/skills/session-startup/scripts/post-merge-cleanup.ps1' -IssueNumber $($item.IssueId) -SkipRemoteDelete -SkipLocalDelete"
                }
            }
        }
        if ($compositeArgs.Count -gt 0) {
            $lines += "pwsh '$safeRoot/skills/session-startup/scripts/post-merge-cleanup.ps1' $($compositeArgs -join ' ')"
        }
        $lines += '```'
        $lines += ''
    }
    elseif ($null -ne $currentNoUpstreamWorktree -and $null -eq $staleBranch -and $cleanupNeeded.Count -eq 0) {
        $lines += '**Post-merge cleanup detected** — current Claude worktree branch is merged:'
        $lines += ''
        $lines += (Get-CurrentNoUpstreamWorktreeLines -Item $currentNoUpstreamWorktree)
        $lines += ''
    }
    elseif ($null -ne $staleBranch -and $cleanupNeeded.Count -eq 0) {
        # ── Branch-only signal ─────────────────────────────────────────────────────
        $lines += '**Post-merge cleanup detected** — you''re on a stale branch:'
        $lines += ''
        $lines += (Get-SCDStaleBranchLine -StaleBranch $staleBranch)
        $lines += ''
        $lines += 'To clean up, run:'
        $lines += '```powershell'
        if ($staleBranch.IssueId) {
            $lines += '# Run in a PowerShell (pwsh) terminal:'
            $lines += "pwsh '$safeRoot/skills/session-startup/scripts/post-merge-cleanup.ps1' -IssueNumber $($staleBranch.IssueId) -FeatureBranch '$escaped'"
        }
        else {
            $lines += "git checkout '$escapedDefault' && git pull && git branch -d '$escaped'  # use -D to force if already confirmed merged"
        }
        $lines += '```'
        $lines += ''
    }
    elseif ($null -ne $staleBranch -and $cleanupNeeded.Count -gt 0) {
        $dedupedCleanup = @($cleanupNeeded | Where-Object { $_.IssueId -ne $staleBranch.IssueId })
        # ── Both signals — branch info MUST precede 'post-merge cleanup detected' ──
        $lines += '**Post-merge cleanup detected** — stale branch and tracking artifacts found:'
        $lines += ''
        $lines += (Get-SCDStaleBranchLine -StaleBranch $staleBranch)
        $lines += ''
        if ($dedupedCleanup.Count -gt 0) {
            $lines += '**Post-merge cleanup detected** — stale tracking artifacts also found:'
            $lines += ''
            $lines += (Get-TrackingLines -Items $dedupedCleanup)
            $lines += ''
        }
        $lines += 'To clean up, run:'
        $lines += '```powershell'
        if ($staleBranch.IssueId) {
            $lines += '# Run in a PowerShell (pwsh) terminal:'
            $lines += "pwsh '$safeRoot/skills/session-startup/scripts/post-merge-cleanup.ps1' -IssueNumber $($staleBranch.IssueId) -FeatureBranch '$escaped'"
            if ($dedupedCleanup.Count -gt 0) {
                $lines += (Get-TrackingCommands -Items $dedupedCleanup)
            }
        }
        else {
            $lines += "git checkout '$escapedDefault' && git pull && git branch -d '$escaped'  # use -D to force if already confirmed merged"
            if ($dedupedCleanup.Count -gt 0) {
                $lines += (Get-TrackingCommands -Items $dedupedCleanup)
            }
        }
        $lines += '```'
        $lines += ''
    }
    else {
        # ── Tracking-files-only signal (existing behaviour) ───────────────────────
        if ($null -ne $currentNoUpstreamWorktree) {
            $lines += '**Post-merge cleanup detected** — stale tracking artifacts and current Claude worktree branch found:'
        }
        else {
            $lines += '**Post-merge cleanup detected** — stale tracking artifacts found:'
        }
        $lines += ''
        if ($null -ne $currentNoUpstreamWorktree) {
            $lines += (Get-CurrentNoUpstreamWorktreeLines -Item $currentNoUpstreamWorktree)
            $lines += ''
        }
        $lines += (Get-TrackingLines -Items $cleanupNeeded)
        $lines += ''
        $lines += 'To clean up, run:'
        $lines += '```powershell'
        $lines += (Get-TrackingCommands -Items $cleanupNeeded)
        $lines += '```'
        $lines += ''
    }

    $additionalContext = $lines -join "`n"

    $output = @{
        hookSpecificOutput = @{
            hookEventName     = 'SessionStart'
            additionalContext = $additionalContext
        }
    } | ConvertTo-Json -Depth 3 -Compress

    return @{ ExitCode = 0; Output = $output; Error = '' }
}
