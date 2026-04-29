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
        [array]$WorktreeRecords = $null
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
        [array]$WorktreeRecords = $null
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

        if (-not (Test-SCDBranchMatchesPrefixes -BranchName $branchName -Prefixes $UpstreamDeletedBranchPrefixes)) {
            continue
        }

        $upstreamBranch = Get-SCDConfiguredUpstreamBranch -BranchName $branchName
        if ($null -eq $upstreamBranch) {
            continue
        }

        if (Test-SCDRemoteHeadMissing -RemoteName $upstreamBranch.RemoteName -BranchPattern $upstreamBranch.BranchName) {
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
    $upstreamDeletedBranchPrefixes = @('feature/issue-')
    $fetchLookup = New-SCDStringLookup

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
                    if ($currentBranch -match 'issue-(\d+)') {
                        $branchIssueId = $Matches[1]
                    }
                    $staleBranch = @{
                        BranchName = $currentBranch
                        IssueId    = $branchIssueId
                    }
                }
            }
            else {
                $isNoUpstreamCandidate = Test-SCDBranchMatchesPrefixes -BranchName $currentBranch -Prefixes $noUpstreamBranchPrefixes

                if ($isNoUpstreamCandidate) {
                    $remoteDefault = Get-SCDRemoteDefaultRef -DefaultBranch $defaultBranch
                    Invoke-SCDNonInteractiveFetchOnce -RemoteName $remoteDefault.RemoteName -CacheKey $remoteDefault.RefName -FetchLookup $fetchLookup

                    if (Test-SCDGitRefExists -RefName $remoteDefault.RefName) {
                        if (Test-SCDMergeBaseAncestor -BranchName $currentBranch -TargetRef $remoteDefault.RefName) {
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

    $siblingWorktreeCleanups = @(Get-SCDSiblingWorktreeCleanups -CurrentWorktreePath (Get-Location).Path -DefaultBranch $defaultBranch -NoUpstreamBranchPrefixes $noUpstreamBranchPrefixes -UpstreamDeletedBranchPrefixes $upstreamDeletedBranchPrefixes -FetchLookup $fetchLookup -WorktreeRecords $worktreeRecords)
    $orphanBranchCleanups = @(Get-SCDOrphanBranchCleanups -CurrentBranch $currentBranch -DefaultBranch $defaultBranch -NoUpstreamBranchPrefixes $noUpstreamBranchPrefixes -UpstreamDeletedBranchPrefixes $upstreamDeletedBranchPrefixes -FetchLookup $fetchLookup -WorktreeRecords $worktreeRecords)

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

        $safeWorktreePath = ConvertTo-SCDPowerShellSingleQuoteEscapedText -Value $Item.WorktreePath
        $safeBranch = ConvertTo-SCDPowerShellSingleQuoteEscapedText -Value $Item.BranchName
        $out = @()
        $out += "- Current Claude worktree branch ``$($Item.BranchName)`` is reachable from ``$($Item.RemoteDefaultRef)``."
        $out += ''
        $out += "Current-worktree cleanup must be run from another checkout: ``git worktree remove '$safeWorktreePath'`` followed by ``git branch -D '$safeBranch'``."
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
                $out += '# Unknown issue ID — manually inspect and archive files in .copilot-tracking/'
            }
        }
        return $out
    }

    function Get-SiblingWorktreeCommands {
        param([array]$Items)

        $out = @()
        foreach ($item in $Items) {
            $safeWorktreePath = ConvertTo-SCDPowerShellSingleQuoteEscapedText -Value $item.WorktreePath
            $safeBranch = ConvertTo-SCDPowerShellSingleQuoteEscapedText -Value $item.BranchName
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
            $safeBranch = ConvertTo-SCDPowerShellSingleQuoteEscapedText -Value $item.BranchName
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
