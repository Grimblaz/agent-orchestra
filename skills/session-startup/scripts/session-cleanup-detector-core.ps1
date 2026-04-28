#Requires -Version 7.0
<#
.SYNOPSIS
    Library for session-cleanup-detector logic. Dot-source this file and call Invoke-SessionCleanupDetector.
#>

. "$PSScriptRoot/session-startup-git-helpers.ps1"

function Test-SCDPersistentTrackingFile {
    param(
        [Parameter(Mandatory)]
        [string]$TrackingRootPath,

        [Parameter(Mandatory)]
        [System.IO.FileInfo]$File,

        [Parameter(Mandatory)]
        [string[]]$PersistentSubtrees
    )

    $filePath = [System.IO.Path]::GetFullPath($File.FullName)
    $relativePath = [System.IO.Path]::GetRelativePath($TrackingRootPath, $filePath).Replace('\', '/')

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
    param(
        [Parameter(Mandatory)]
        [string]$DefaultBranch
    )

    $configuredRemote = (git config --get "branch.$DefaultBranch.remote" 2>$null)
    if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($configuredRemote)) {
        $remoteName = $configuredRemote.Trim()
        return @{
            RemoteName = $remoteName
            BranchName = $DefaultBranch
            RefName    = "refs/remotes/$remoteName/$DefaultBranch"
        }
    }

    $remoteName = 'origin'
    $branchName = $DefaultBranch

    $symbolicRef = (git symbolic-ref refs/remotes/origin/HEAD 2>$null)
    if ($LASTEXITCODE -eq 0 -and $symbolicRef -match '^refs/remotes/([^/]+)/(.+)$') {
        $remoteName = $Matches[1]
        $branchName = $Matches[2]
    }

    return @{
        RemoteName = $remoteName
        BranchName = $branchName
        RefName    = "refs/remotes/$remoteName/$branchName"
    }
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

    try {
        $processStartInfo = [System.Diagnostics.ProcessStartInfo]::new()
        $processStartInfo.FileName = 'git'
        $processStartInfo.UseShellExecute = $false
        $processStartInfo.CreateNoWindow = $true
        $processStartInfo.RedirectStandardOutput = $true
        $processStartInfo.RedirectStandardError = $true
        $processStartInfo.WorkingDirectory = (Get-Location).Path
        $processStartInfo.ArgumentList.Add('fetch') | Out-Null
        $processStartInfo.ArgumentList.Add('--quiet') | Out-Null
        $processStartInfo.ArgumentList.Add('--prune') | Out-Null
        $processStartInfo.ArgumentList.Add($RemoteName) | Out-Null
        $processStartInfo.Environment['GIT_TERMINAL_PROMPT'] = '0'
        $processStartInfo.Environment['GCM_INTERACTIVE'] = 'Never'
        $processStartInfo.Environment['GIT_ASKPASS'] = 'echo'

        $process = [System.Diagnostics.Process]::Start($processStartInfo)
        if ($null -eq $process) {
            return
        }

        try {
            $timeoutMilliseconds = [System.Math]::Max(1, $TimeoutSeconds) * 1000
            if (-not $process.WaitForExit($timeoutMilliseconds)) {
                try { $process.Kill($true) } catch {}
            }
        }
        finally {
            $process.Dispose()
        }
    }
    catch {}
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

function Test-SCDNoUpstreamBranchCandidate {
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
        catch {}
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
        [string[]]$NoUpstreamBranchPrefixes
    )

    $cleanups = @()
    $currentNormalizedPath = ConvertTo-SCDNormalizedPath -Path $CurrentWorktreePath
    if (-not $currentNormalizedPath) {
        return @()
    }

    try {
        $worktreePorcelain = @(git worktree list --porcelain 2>$null)
        if ($LASTEXITCODE -ne 0) {
            return @()
        }

        $records = @(Get-SCDWorktreeRecords -PorcelainLines $worktreePorcelain)
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

                $branchName = $record.BranchName
                if ($branchName -eq $DefaultBranch) {
                    continue
                }

                $upstreamRef = (git -C $record.WorktreePath rev-parse --abbrev-ref '@{u}' 2>$null)
                $upstreamExitCode = $LASTEXITCODE
                if ($upstreamExitCode -eq 0) {
                    $upstreamText = (($upstreamRef | Select-Object -First 1) -as [string]).Trim()
                    if ([string]::IsNullOrWhiteSpace($upstreamText)) {
                        continue
                    }

                    $upstreamParts = $upstreamText -split '/', 2
                    $remoteName = $upstreamParts[0]
                    $remoteBranchName = if ($upstreamParts.Count -gt 1) { $upstreamParts[1] } else { $branchName }
                    if ([string]::IsNullOrWhiteSpace($remoteName)) {
                        continue
                    }
                    if ([string]::IsNullOrWhiteSpace($remoteBranchName)) {
                        $remoteBranchName = $branchName
                    }

                    $remoteHeads = (git ls-remote --heads $remoteName $remoteBranchName 2>$null)
                    if ($LASTEXITCODE -eq 0 -and [string]::IsNullOrWhiteSpace($remoteHeads)) {
                        $cleanups += @{
                            BranchName   = $branchName
                            WorktreePath = $normalizedPath
                            Reason       = 'remote branch merged/deleted'
                            IsLocked     = $record.IsLocked
                            LockReason   = $record.LockReason
                            IsPrunable   = $record.IsPrunable
                        }
                    }
                    continue
                }

                if (-not (Test-SCDNoUpstreamBranchCandidate -BranchName $branchName -Prefixes $NoUpstreamBranchPrefixes)) {
                    continue
                }

                $remoteDefault = Get-SCDRemoteDefaultRef -DefaultBranch $DefaultBranch
                Invoke-SCDNonInteractiveFetch -RemoteName $remoteDefault.RemoteName

                git show-ref --verify --quiet $remoteDefault.RefName 2>$null
                if ($LASTEXITCODE -ne 0) {
                    continue
                }

                git -C $record.WorktreePath merge-base --is-ancestor $branchName $remoteDefault.RefName 2>$null
                if ($LASTEXITCODE -eq 0) {
                    $cleanups += @{
                        BranchName       = $branchName
                        WorktreePath     = $normalizedPath
                        Reason           = "reachable from ``$($remoteDefault.RefName)``"
                        RemoteDefaultRef = $remoteDefault.RefName
                        IsLocked         = $record.IsLocked
                        LockReason       = $record.LockReason
                        IsPrunable       = $record.IsPrunable
                    }
                }
            }
            catch {}
        }
    }
    catch {}

    return $cleanups
}

function New-SCDStringLookup {
    return [System.Collections.Hashtable]::new([System.StringComparer]::Ordinal)
}

function Add-SCDLookupValue {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Lookup,

        [string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return
    }

    if (-not $Lookup.ContainsKey($Value)) {
        $Lookup[$Value] = $true
    }
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
    catch {}

    return ''
}

function Get-SCDAttachedBranchLookup {
    param([string]$CurrentBranch)

    $attachedBranches = New-SCDStringLookup
    Add-SCDLookupValue -Lookup $attachedBranches -Value $CurrentBranch

    try {
        $worktreePorcelain = @(git worktree list --porcelain 2>$null)
        if ($LASTEXITCODE -ne 0) {
            return $null
        }

        $records = @(Get-SCDWorktreeRecords -PorcelainLines $worktreePorcelain)
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
        [string[]]$NoUpstreamBranchPrefixes
    )

    $cleanups = @()
    $attachedBranchLookup = Get-SCDAttachedBranchLookup -CurrentBranch $CurrentBranch
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
        Invoke-SCDNonInteractiveFetch -RemoteName $remoteDefault.RemoteName

        git show-ref --verify --quiet $remoteDefault.RefName 2>$null
        if ($LASTEXITCODE -eq 0) {
            foreach ($branchName in $noUpstreamCandidates) {
                git merge-base --is-ancestor $branchName $remoteDefault.RefName 2>$null
                if ($LASTEXITCODE -eq 0) {
                    $cleanups += @{
                        BranchName       = $branchName
                        Reason           = "reachable from ``$($remoteDefault.RefName)``"
                        RemoteDefaultRef = $remoteDefault.RefName
                        Kind             = 'orphan-no-upstream'
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

        $remoteName = Get-SCDBranchConfigValue -BranchName $branchName -Name 'remote'
        $mergeRef = Get-SCDBranchConfigValue -BranchName $branchName -Name 'merge'
        if ([string]::IsNullOrWhiteSpace($remoteName) -or [string]::IsNullOrWhiteSpace($mergeRef)) {
            continue
        }

        $remoteBranchName = $mergeRef
        if ($mergeRef -match '^refs/heads/(.+)$') {
            $remoteBranchName = $Matches[1]
        }
        if ([string]::IsNullOrWhiteSpace($remoteBranchName)) {
            continue
        }

        $remoteHeads = (git ls-remote --heads $remoteName $remoteBranchName 2>$null)
        if ($LASTEXITCODE -eq 0 -and [string]::IsNullOrWhiteSpace($remoteHeads)) {
            $cleanups += @{
                BranchName = $branchName
                Reason     = 'remote branch merged/deleted'
                Kind       = 'orphan-upstream'
            }
        }
    }

    return $cleanups
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

    $persistentTrackingSubtrees = @(
        'calibration'
    )
    $noUpstreamBranchPrefixes = @('claude/')

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
                $remoteName = ($upstreamRef -split '/', 2)[0]
                $remoteBranchName = ($upstreamRef -split '/', 2)[1]
                if ([string]::IsNullOrWhiteSpace($remoteBranchName)) { $remoteBranchName = $currentBranch }
                $remoteHeads = (git ls-remote --heads $remoteName $remoteBranchName 2>$null)
                if ($LASTEXITCODE -eq 0) {
                    if ([string]::IsNullOrWhiteSpace($remoteHeads)) {
                        # Remote branch is gone — stale branch detected
                        $branchIssueId = $null
                        if ($currentBranch -match 'issue-(\d+)') {
                            $branchIssueId = $Matches[1]
                        }
                        $staleBranch = @{
                            BranchName = $currentBranch
                            IssueId    = $branchIssueId
                        }
                    }
                }
            }
            else {
                $isNoUpstreamCandidate = Test-SCDNoUpstreamBranchCandidate -BranchName $currentBranch -Prefixes $noUpstreamBranchPrefixes

                if ($isNoUpstreamCandidate) {
                    $remoteDefault = Get-SCDRemoteDefaultRef -DefaultBranch $defaultBranch
                    Invoke-SCDNonInteractiveFetch -RemoteName $remoteDefault.RemoteName

                    git show-ref --verify --quiet $remoteDefault.RefName 2>$null
                    if ($LASTEXITCODE -eq 0) {
                        git merge-base --is-ancestor $currentBranch $remoteDefault.RefName 2>$null
                        $ancestorExitCode = $LASTEXITCODE
                        if ($ancestorExitCode -eq 0) {
                            $currentNoUpstreamWorktree = @{
                                BranchName       = $currentBranch
                                RemoteDefaultRef = $remoteDefault.RefName
                                WorktreePath     = (Get-Location).Path
                            }
                        }
                    }
                }
            }
        }
    }

    $siblingWorktreeCleanups = @(Get-SCDSiblingWorktreeCleanups -CurrentWorktreePath (Get-Location).Path -DefaultBranch $defaultBranch -NoUpstreamBranchPrefixes $noUpstreamBranchPrefixes)
    $orphanBranchCleanups = @(Get-SCDOrphanBranchCleanups -CurrentBranch $currentBranch -DefaultBranch $defaultBranch -NoUpstreamBranchPrefixes $noUpstreamBranchPrefixes)

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
                if (Test-SCDPersistentTrackingFile -TrackingRootPath $trackingRootPath -File $file -PersistentSubtrees $persistentTrackingSubtrees) {
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
                $remoteCheck = git ls-remote --heads origin "feature/issue-$id-*" 2>$null
                # Guard: git failure (network error, etc.) → skip to avoid false positives
                if ($LASTEXITCODE -ne 0) { continue }
                $localBranches = @(git branch --list "feature/issue-$id-*" 2>$null |
                        ForEach-Object { ($_ -replace '^\* ', '').Trim() } |
                        Where-Object { $_ })
                $localBranch = $localBranches | Select-Object -First 1
                if ($LASTEXITCODE -ne 0) { $localBranches = @(); $localBranch = $null }

                if ([string]::IsNullOrWhiteSpace($remoteCheck)) {
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

        $safeWorktreePath = $Item.WorktreePath -replace "'", "''"
        $safeBranch = $Item.BranchName -replace "'", "''"
        $out = @()
        $out += "- Current Claude worktree branch ``$($Item.BranchName)`` is reachable from ``$($Item.RemoteDefaultRef)``."
        $out += ''
        $out += "Current-worktree cleanup must be run from another checkout: `git worktree remove '$safeWorktreePath'` followed by `git branch -D '$safeBranch'`."
        return $out
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
    $safeRoot = $RepoRoot -replace "'", "''"

    # Helper: emit cleanup command lines for tracking-file items
    function Get-TrackingCommands {
        param([array]$Items)
        $out = @()
        $out += '# Run in a PowerShell (pwsh) terminal:'
        foreach ($item in $Items) {
            if ($item.IssueId -ne 'unknown') {
                if ($item.BranchName) {
                    foreach ($b in $item.AllBranches) {
                        $safeB = $b -replace "'", "''"
                        $out += "pwsh '$safeRoot/skills/session-startup/scripts/post-merge-cleanup.ps1' -IssueNumber $($item.IssueId) -FeatureBranch '$safeB'"
                    }
                }
                else {
                    $out += "pwsh '$safeRoot/skills/session-startup/scripts/post-merge-cleanup.ps1' -IssueNumber $($item.IssueId) -SkipRemoteDelete -SkipLocalDelete  # branch not found locally; archives tracking files only"
                }
            }
            else {
                $out += '# Unknown issue ID — manually inspect and archive files in .copilot-tracking/'
            }
        }
        return $out
    }

    function Get-SiblingWorktreeCommands {
        param([array]$Items)

        $out = @()
        foreach ($item in $Items) {
            $safeWorktreePath = $item.WorktreePath -replace "'", "''"
            $safeBranch = $item.BranchName -replace "'", "''"
            if ($item.IsLocked) {
                $out += "git worktree remove --force '$safeWorktreePath'"
            }
            else {
                $out += "git worktree remove '$safeWorktreePath'"
            }
            $out += "git branch -D '$safeBranch'"
        }
        return $out
    }

    function Get-OrphanBranchLines {
        param([array]$Items)

        $out = @()
        foreach ($item in $Items) {
            $out += "- Orphan branch ``$($item.BranchName)`` — $($item.Reason)"
        }
        return $out
    }

    function Get-OrphanBranchCommands {
        param([array]$Items)

        $out = @()
        foreach ($item in $Items) {
            $safeBranch = $item.BranchName -replace "'", "''"
            $out += "git branch -D '$safeBranch'"
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

    $escaped = if ($null -ne $staleBranch) { $staleBranch.BranchName -replace "'", "''" } else { $null }
    $escapedDefault = $defaultBranch -replace "'", "''"

    $claudeCleanupLimit = 10
    $claudeCleanupKeys = @()
    if (
        $null -ne $currentNoUpstreamWorktree -and
        (Test-SCDNoUpstreamBranchCandidate -BranchName $currentNoUpstreamWorktree.BranchName -Prefixes $noUpstreamBranchPrefixes)
    ) {
        $claudeCleanupKeys += "current|$($currentNoUpstreamWorktree.BranchName)"
    }
    foreach ($item in $siblingWorktreeCleanups) {
        if (Test-SCDNoUpstreamBranchCandidate -BranchName $item.BranchName -Prefixes $noUpstreamBranchPrefixes) {
            $claudeCleanupKeys += (Get-ClaudeCleanupKey -Kind 'sibling' -Item $item)
        }
    }
    foreach ($item in $orphanBranchCleanups) {
        if (Test-SCDNoUpstreamBranchCandidate -BranchName $item.BranchName -Prefixes $noUpstreamBranchPrefixes) {
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
                -not (Test-SCDNoUpstreamBranchCandidate -BranchName $_.BranchName -Prefixes $noUpstreamBranchPrefixes) -or
                $visibleClaudeCleanupLookup.ContainsKey((Get-ClaudeCleanupKey -Kind 'sibling' -Item $_))
            })
        $visibleOrphanBranchCleanups = @($orphanBranchCleanups | Where-Object {
                -not (Test-SCDNoUpstreamBranchCandidate -BranchName $_.BranchName -Prefixes $noUpstreamBranchPrefixes) -or
                $visibleClaudeCleanupLookup.ContainsKey((Get-ClaudeCleanupKey -Kind 'orphan' -Item $_))
            })
    }

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
            $lines += "- Current branch ``$($staleBranch.BranchName)`` — remote branch merged/deleted"
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
        if ($visibleSiblingWorktreeCleanups.Count -gt 0) {
            $lines += (Get-SiblingWorktreeLines -Items $visibleSiblingWorktreeCleanups)
        }
        if ($visibleOrphanBranchCleanups.Count -gt 0) {
            $lines += (Get-OrphanBranchLines -Items $visibleOrphanBranchCleanups)
        }
        if ($hiddenClaudeCleanupCount -gt 0) {
            $lines += "- +$hiddenClaudeCleanupCount more — run ``git for-each-ref --format='%(refname:short)' refs/heads/claude/`` to see the full list."
        }
        $lines += ''
        $lines += 'To clean up, run:'
        $lines += '```powershell'
        $lines += '# Run in a PowerShell (pwsh) terminal:'
        if ($null -ne $staleBranch) {
            if ($staleBranch.IssueId) {
                $lines += "pwsh '$safeRoot/skills/session-startup/scripts/post-merge-cleanup.ps1' -IssueNumber $($staleBranch.IssueId) -FeatureBranch '$escaped'"
            }
            else {
                $lines += "git checkout '$escapedDefault' && git pull && git branch -d '$escaped'  # use -D to force if already confirmed merged"
            }
        }
        if ($cleanupNeeded.Count -gt 0) {
            $trackingCommands = @(Get-TrackingCommands -Items $cleanupNeeded | Where-Object { $_ -ne '# Run in a PowerShell (pwsh) terminal:' })
            $lines += $trackingCommands
        }
        if ($visibleSiblingWorktreeCleanups.Count -gt 0) {
            $lines += (Get-SiblingWorktreeCommands -Items $visibleSiblingWorktreeCleanups)
        }
        if ($visibleOrphanBranchCleanups.Count -gt 0) {
            $lines += (Get-OrphanBranchCommands -Items $visibleOrphanBranchCleanups)
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
        $lines += "- Current branch ``$($staleBranch.BranchName)`` — remote branch merged/deleted"
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
        $lines += "- Current branch ``$($staleBranch.BranchName)`` — remote branch merged/deleted"
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
