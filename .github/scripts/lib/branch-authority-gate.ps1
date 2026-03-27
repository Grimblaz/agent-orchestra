#Requires -Version 7.0

function Invoke-BranchAuthorityGit {
    param([string[]]$Arguments)

    $output = @()
    $exitCode = 1

    try {
        $output = & git @Arguments 2>$null
        $exitCode = $LASTEXITCODE
    }
    catch {
        if ($LASTEXITCODE -eq 0) {
            $exitCode = 1
        }
        else {
            $exitCode = $LASTEXITCODE
        }
    }

    return [pscustomobject]@{
        ExitCode = $exitCode
        Output   = @($output)
    }
}

function Get-BranchAuthorityFirstOutputLine {
    param([object[]]$Output)

    foreach ($entry in @($Output)) {
        foreach ($line in @("$entry" -split "`r?`n")) {
            $trimmedLine = $line.Trim()
            if (-not [string]::IsNullOrWhiteSpace($trimmedLine)) {
                return $trimmedLine
            }
        }
    }

    return $null
}

function ConvertTo-BranchAuthorityBranchList {
    param([object[]]$Output)

    $branches = [System.Collections.Generic.List[string]]::new()

    foreach ($entry in @($Output)) {
        foreach ($line in @("$entry" -split "`r?`n")) {
            $branchName = $line.Trim()
            if ($branchName.StartsWith('* ')) {
                $branchName = $branchName.Substring(2).Trim()
            }

            if (-not [string]::IsNullOrWhiteSpace($branchName) -and -not $branches.Contains($branchName)) {
                $branches.Add($branchName)
            }
        }
    }

    Write-Output -NoEnumerate ([string[]]$branches.ToArray())
}

function Get-BranchAuthorityCommitComparison {
    param([string[]]$MatchingIssueBranches)

    if ($MatchingIssueBranches.Count -eq 0) {
        return [pscustomobject]@{
            AuthorityStatus        = 'missing-issue-branch'
            AmbiguityKind          = $null
            CommitComparisonUsed   = $false
            CommitComparisonResult = $null
        }
    }

    if ($MatchingIssueBranches.Count -eq 1) {
        return [pscustomobject]@{
            AuthorityStatus        = 'verified'
            AmbiguityKind          = $null
            CommitComparisonUsed   = $false
            CommitComparisonResult = $null
        }
    }

    $branchCommits = [ordered]@{}

    foreach ($branchName in $MatchingIssueBranches) {
        $revParseResult = Invoke-BranchAuthorityGit -Arguments @('rev-parse', $branchName)
        $commitSha = if ($revParseResult.ExitCode -eq 0) {
            Get-BranchAuthorityFirstOutputLine -Output $revParseResult.Output
        }
        else {
            $null
        }

        if ([string]::IsNullOrWhiteSpace($commitSha)) {
            return [pscustomobject]@{
                AuthorityStatus        = 'proof-missing'
                AmbiguityKind          = $null
                CommitComparisonUsed   = $true
                CommitComparisonResult = 'proof-missing'
            }
        }

        $branchCommits[$branchName] = $commitSha
    }

    $uniqueCommits = @($branchCommits.Values | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
    $ambiguityKind = if ($uniqueCommits.Count -le 1) { 'same-tip-duplicate' } else { 'divergent' }

    return [pscustomobject]@{
        AuthorityStatus        = 'ambiguous'
        AmbiguityKind          = $ambiguityKind
        CommitComparisonUsed   = $true
        CommitComparisonResult = $ambiguityKind
    }
}

function New-BranchAuthorityGateDecision {
    param(
        [string]$RequestedAction,
        [string]$IntendedBranch,
        [string]$AttachedBranchContext,
        [string]$VerifiedCurrentBranch,
        [string[]]$MatchingIssueBranches,
        [string]$AuthorityStatus,
        [string]$Outcome,
        [bool]$RequiresBranchMutation,
        [AllowNull()]
        [string]$AmbiguityKind,
        [bool]$CommitComparisonUsed,
        [AllowNull()]
        [string]$CommitComparisonResult,
        [string]$SafeNextState
    )

    $normalizedMatchingIssueBranches = if ($null -eq $MatchingIssueBranches) {
        @()
    }
    else {
        @($MatchingIssueBranches)
    }

    return [pscustomobject]@{
        RequestedAction        = $RequestedAction
        IntendedBranch         = $IntendedBranch
        AdvisoryBranchContext  = $AttachedBranchContext
        VerifiedCurrentBranch  = $VerifiedCurrentBranch
        MatchingIssueBranches  = $normalizedMatchingIssueBranches
        AuthorityStatus        = $AuthorityStatus
        Outcome                = $Outcome
        RequiresBranchMutation = $RequiresBranchMutation
        AmbiguityKind          = $AmbiguityKind
        CommitComparisonUsed   = $CommitComparisonUsed
        CommitComparisonResult = $CommitComparisonResult
        SafeNextState          = $SafeNextState
    }
}

function Get-BranchAuthoritySafeNextState {
    param(
        [bool]$CurrentMatchesIntended,

        [ValidateSet('proof-missing', 'mismatch')]
        [string]$BlockReason
    )

    if ($CurrentMatchesIntended) {
        if ($BlockReason -eq 'proof-missing') {
            return 'Stay on the verified current branch and do not mutate branch state until branch authority proof is complete.'
        }

        return 'Stay on the verified current branch and do not mutate branch state until the mismatch is reconciled.'
    }

    if ($BlockReason -eq 'proof-missing') {
        return 'Reconcile branch authority proof before any branch mutation resumes.'
    }

    return 'Reconcile branch authority before any branch mutation resumes.'
}

function Get-BranchAuthorityGateDecision {
    param(
        [Parameter(Mandatory)]
        [int]$IssueNumber,

        [Parameter(Mandatory)]
        [ValidateSet('create', 'checkout', 'rename', 'cleanup')]
        [string]$RequestedAction,

        [Parameter(Mandatory)]
        [string]$IntendedBranch,

        [string]$AttachedBranchContext
    )

    $currentBranchResult = Invoke-BranchAuthorityGit -Arguments @('branch', '--show-current')
    $verifiedCurrentBranch = $null
    if ($currentBranchResult.ExitCode -eq 0) {
        $verifiedCurrentBranch = Get-BranchAuthorityFirstOutputLine -Output $currentBranchResult.Output
    }
    $currentBranchProofAvailable = $currentBranchResult.ExitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace($verifiedCurrentBranch)

    $issueBranchPattern = "feature/issue-$IssueNumber*"
    $branchListResult = Invoke-BranchAuthorityGit -Arguments @('branch', '--list', $issueBranchPattern)
    $matchingIssueBranches = ConvertTo-BranchAuthorityBranchList -Output $branchListResult.Output
    $issueBranchListProofAvailable = $branchListResult.ExitCode -eq 0

    $currentMatchesIntended = $currentBranchProofAvailable -and $verifiedCurrentBranch -eq $IntendedBranch
    $advisoryMismatch = $currentBranchProofAvailable -and -not [string]::IsNullOrWhiteSpace($AttachedBranchContext) -and $AttachedBranchContext -ne $verifiedCurrentBranch
    $requiresBranchMutation = $RequestedAction -in @('rename', 'cleanup') -or -not $currentMatchesIntended
    $comparison = Get-BranchAuthorityCommitComparison -MatchingIssueBranches $matchingIssueBranches
    $issueBranchProofMissing = $RequestedAction -ne 'create' -and $matchingIssueBranches.Count -eq 0
    $intendedBranchAlreadyExists = @($matchingIssueBranches) -contains $IntendedBranch
    $createWouldDuplicateExistingIssueBranch = $RequestedAction -eq 'create' -and $intendedBranchAlreadyExists -and -not $currentMatchesIntended
    $proofMissing = -not $currentBranchProofAvailable -or -not $issueBranchListProofAvailable -or $comparison.AuthorityStatus -eq 'proof-missing' -or $issueBranchProofMissing

    if ($proofMissing) {
        return New-BranchAuthorityGateDecision -RequestedAction $RequestedAction -IntendedBranch $IntendedBranch -AttachedBranchContext $AttachedBranchContext -VerifiedCurrentBranch $verifiedCurrentBranch -MatchingIssueBranches $matchingIssueBranches -AuthorityStatus 'proof-missing' -Outcome 'blocked' -RequiresBranchMutation $requiresBranchMutation -AmbiguityKind $comparison.AmbiguityKind -CommitComparisonUsed $comparison.CommitComparisonUsed -CommitComparisonResult $comparison.CommitComparisonResult -SafeNextState (Get-BranchAuthoritySafeNextState -CurrentMatchesIntended $currentMatchesIntended -BlockReason 'proof-missing')
    }

    if ($currentMatchesIntended -and $matchingIssueBranches.Count -eq 1 -and $matchingIssueBranches[0] -eq $IntendedBranch -and $RequestedAction -in @('create', 'checkout')) {
        return New-BranchAuthorityGateDecision -RequestedAction $RequestedAction -IntendedBranch $IntendedBranch -AttachedBranchContext $AttachedBranchContext -VerifiedCurrentBranch $verifiedCurrentBranch -MatchingIssueBranches $matchingIssueBranches -AuthorityStatus 'verified' -Outcome 'continue-no-mutation' -RequiresBranchMutation $false -AmbiguityKind $comparison.AmbiguityKind -CommitComparisonUsed $comparison.CommitComparisonUsed -CommitComparisonResult $comparison.CommitComparisonResult -SafeNextState 'Continue on the verified current branch without any branch mutation.'
    }

    if ($createWouldDuplicateExistingIssueBranch) {
        return New-BranchAuthorityGateDecision -RequestedAction $RequestedAction -IntendedBranch $IntendedBranch -AttachedBranchContext $AttachedBranchContext -VerifiedCurrentBranch $verifiedCurrentBranch -MatchingIssueBranches $matchingIssueBranches -AuthorityStatus 'verified' -Outcome 'blocked' -RequiresBranchMutation $true -AmbiguityKind $comparison.AmbiguityKind -CommitComparisonUsed $comparison.CommitComparisonUsed -CommitComparisonResult $comparison.CommitComparisonResult -SafeNextState (Get-BranchAuthoritySafeNextState -CurrentMatchesIntended $currentMatchesIntended -BlockReason 'mismatch')
    }

    if ($advisoryMismatch -or $comparison.AuthorityStatus -eq 'ambiguous') {
        return New-BranchAuthorityGateDecision -RequestedAction $RequestedAction -IntendedBranch $IntendedBranch -AttachedBranchContext $AttachedBranchContext -VerifiedCurrentBranch $verifiedCurrentBranch -MatchingIssueBranches $matchingIssueBranches -AuthorityStatus $comparison.AuthorityStatus -Outcome 'blocked' -RequiresBranchMutation $true -AmbiguityKind $comparison.AmbiguityKind -CommitComparisonUsed $comparison.CommitComparisonUsed -CommitComparisonResult $comparison.CommitComparisonResult -SafeNextState (Get-BranchAuthoritySafeNextState -CurrentMatchesIntended $currentMatchesIntended -BlockReason 'mismatch')
    }

    return New-BranchAuthorityGateDecision -RequestedAction $RequestedAction -IntendedBranch $IntendedBranch -AttachedBranchContext $AttachedBranchContext -VerifiedCurrentBranch $verifiedCurrentBranch -MatchingIssueBranches $matchingIssueBranches -AuthorityStatus 'verified' -Outcome 'allow-mutation' -RequiresBranchMutation $requiresBranchMutation -AmbiguityKind $null -CommitComparisonUsed $false -CommitComparisonResult $null -SafeNextState 'Proceed only with the requested branch mutation that live git just verified.'
}