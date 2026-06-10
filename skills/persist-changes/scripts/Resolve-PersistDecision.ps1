function Resolve-PersistDecision {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Inputs
    )

    $branch               = $Inputs.branch
    $isDetached           = [bool]$Inputs.isDetached
    $defaultBranch        = $Inputs.defaultBranch
    $headRemote           = $Inputs.headRemote
    $headRemoteWritable   = [bool]$Inputs.headRemoteWritable
    $commitPolicyDisabled = [bool]$Inputs.commitPolicyDisabled
    $hasFixFiles          = [bool]$Inputs.hasFixFiles
    $isUpToDate           = [bool]$Inputs.isUpToDate
    $nonFastForwardProbe  = [bool]$Inputs.nonFastForwardProbe

    # Edge case: null/empty headRemote defaults to 'origin'
    $effectiveHeadRemote = if ([string]::IsNullOrEmpty($headRemote)) { 'origin' } else { $headRemote }

    $result = @{
        commit             = $false
        push               = $false
        push_target_remote = $null
        refuse_reason      = $null
        not_pushed_reason  = $null
        manual_instruction = $null
    }

    # Guard 1: detached HEAD
    if ($isDetached) {
        $result.refuse_reason = 'detached'
        return $result
    }

    # Guard 2: default branch
    if ($branch -eq $defaultBranch) {
        $result.refuse_reason = 'default-branch'
        return $result
    }

    # Guard 3: nothing to push
    if (-not $hasFixFiles -or $isUpToDate) {
        $result.not_pushed_reason = 'nothing-to-push'
        return $result
    }

    # Past the guards: commit is true
    $result.commit = $true

    # Push gate 4a: commit-policy opt-out
    if ($commitPolicyDisabled) {
        $result.not_pushed_reason  = 'opt-out'
        $result.manual_instruction = "Commit-Policy disabled — changes committed to '$branch'. Push manually: git push $effectiveHeadRemote HEAD:$branch"
        return $result
    }

    # Push gate 4b: no write access
    if (-not $headRemoteWritable) {
        $result.not_pushed_reason = 'fork-no-write'
        return $result
    }

    # Push gate 4c: non-fast-forward
    if ($nonFastForwardProbe) {
        $result.not_pushed_reason = 'non-ff'
        return $result
    }

    # Push gate 4d: happy path
    $result.push               = $true
    $result.push_target_remote = $effectiveHeadRemote
    return $result
}
