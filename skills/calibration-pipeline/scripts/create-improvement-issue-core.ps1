#Requires -Version 7.0

# #837 R1 (judge-sustained, critical): filing (the `gh issue create` side
# effect) now routes through the shared safe-operations filing primitive so
# every filed improvement issue carries a -FilingProvenance stamp like the
# other §837-wired surfaces, instead of calling `gh issue create` directly.
. "$PSScriptRoot/../../safe-operations/scripts/Add-FollowUpIssue.ps1"

# ── Private helpers (CII prefix) ─────────────────────────────────────

function Get-CIIFlexProperty {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    if ($Object -is [hashtable]) { return $Object[$Name] }
    if ($Object.PSObject.Properties.Name -contains $Name) { return $Object.$Name }
    return $null
}

function Get-CIICategory {
    param([string]$PatternKey)
    $parts = $PatternKey -split ':', 2
    if ($parts.Count -gt 1) { return $parts[1] } else { return $PatternKey }
}

function Test-CIIPatternKeyExists {
    param([object[]]$Proposals, [string]$PatternKey)
    foreach ($prop in $Proposals) {
        $propKey = Get-CIIFlexProperty -Object $prop -Name 'pattern_key'
        if ($propKey -eq $PatternKey) {
            $fixNum = Get-CIIFlexProperty -Object $prop -Name 'fix_issue_number'
            if ($null -ne $fixNum) { return $true }
        }
    }
    return $false
}

function Search-CIIConsolidationCandidate {
    param(
        [string]$Repo,
        [string]$GhCliPath
    )
    # §2d uses label-based filtering only — NO --search flag
    $output = & $GhCliPath issue list --repo $Repo --state open --label 'priority: medium' --json 'number,title' 2>$null
    if ($LASTEXITCODE -ne 0) { return $null }
    $issues = $output | ConvertFrom-Json -ErrorAction SilentlyContinue
    $filtered = $issues | Where-Object { $_.title -match '\[Systemic Fix\]' }
    if ($filtered -and @($filtered).Count -gt 0) {
        return @{ Number = @($filtered)[0].number; Title = @($filtered)[0].title }
    }
    return $null
}

function Search-CIIGitHubDedup {
    param(
        [string]$PatternKey,
        [string]$SystemicFixType,
        [string]$Repo,
        [string]$GhCliPath
    )
    $category = Get-CIICategory -PatternKey $PatternKey
    $output = & $GhCliPath issue list --repo $Repo --state open --search "[Systemic Fix] $SystemicFixType $category" --json 'number,title' 2>$null
    if ($LASTEXITCODE -ne 0) { return $null }
    $issues = $output | ConvertFrom-Json -ErrorAction SilentlyContinue
    if ($issues -and $issues.Count -gt 0) {
        return @{ Number = $issues[0].number; Title = $issues[0].title }
    }
    return $null
}

function Get-CIICeilingAdvisory {
    param(
        [string]$TargetFile,
        [int]$FixTypeLevel,
        [string]$ComplexityJsonPath
    )
    if ($TargetFile -notmatch '\.agent\.md$') { return $null }
    if ($FixTypeLevel -lt 4) { return $null }
    if (-not $ComplexityJsonPath -or -not (Test-Path $ComplexityJsonPath)) { return $null }

    $complexity = Get-Content -Raw -Path $ComplexityJsonPath | ConvertFrom-Json
    if ($null -eq $complexity) { return $null }
    $basename = Split-Path -Leaf $TargetFile
    $overCeiling = @($complexity.agents_over_ceiling)

    if ($basename -in $overCeiling) {
        $advisory = "⚠️ D10 ceiling advisory: $basename is at the guidance complexity ceiling. "
        if ($FixTypeLevel -ge 5) {
            $advisory += 'Consider compression/extraction before adding agent-prompt rules.'
        }
        else {
            $advisory += 'Consider compression/extraction before adding guidance.'
        }
        return $advisory
    }
    return $null
}

function Get-CIIClassifiedLevel {
    param(
        [string]$SystemicFixType,
        [int]$FixTypeLevel,
        [string]$ProposedChange,
        [string]$FixTypeOverride
    )

    $defaultLevels = @{
        'plan-template' = 3
        'instruction'   = 4
        'skill'         = 4
        'agent-prompt'  = 5
    }

    if ($FixTypeOverride) {
        return @{
            ClassifiedLevel = $FixTypeLevel
            SuggestedLevel  = $null
        }
    }

    $classifiedLevel = if ($defaultLevels.ContainsKey($SystemicFixType)) {
        $defaultLevels[$SystemicFixType]
    }
    else {
        $FixTypeLevel
    }

    $suggestedLevel = $null
    if ($ProposedChange -match 'wording-lock|contract test|structural check') {
        $suggestedLevel = 1
    }
    elseif ($ProposedChange -match 'pre-flight|validation script') {
        $suggestedLevel = 2
    }
    elseif ($ProposedChange -match 'template field|fill-in-the-blank') {
        $suggestedLevel = 3
    }

    return @{
        ClassifiedLevel = $classifiedLevel
        SuggestedLevel  = $suggestedLevel
    }
}

function New-CIIIssueBody {
    param(
        [string]$PatternKey,
        [int[]]$EvidencePrs,
        [string]$FirstEmittedAt,
        [int]$ClassifiedLevel,
        $SuggestedLevel,
        [string]$TargetFile,
        [string]$ProposedChange,
        [string]$SystemicFixType,
        [string]$CeilingAdvisory,
        [string]$FixTypeOverride,
        [bool]$UpstreamPreflightPassed
    )

    $sb = [System.Text.StringBuilder]::new()
    $category = Get-CIICategory -PatternKey $PatternKey
    [void]$sb.AppendLine("## [Systemic Fix] $SystemicFixType — $category")
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine("**Pattern key**: ``$PatternKey``")
    [void]$sb.AppendLine("**Target file**: ``$TargetFile``")
    [void]$sb.AppendLine("**First emitted**: $FirstEmittedAt")
    [void]$sb.AppendLine("**Evidence PRs**: $(($EvidencePrs | ForEach-Object { "#$_" }) -join ', ')")
    [void]$sb.AppendLine("**Fix-type level**: $ClassifiedLevel (D-259-7)")
    if ($SuggestedLevel -and $SuggestedLevel -ne $ClassifiedLevel) {
        [void]$sb.AppendLine("**Suggested level** (keyword heuristic): $SuggestedLevel")
    }
    if ($FixTypeOverride) {
        [void]$sb.AppendLine("**Override justification**: $FixTypeOverride")
    }
    [void]$sb.AppendLine("**Upstream pre-flight**: $(if ($UpstreamPreflightPassed) { 'passed' } else { 'failed' })")
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('### Proposed Change')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine($ProposedChange)

    if ($ClassifiedLevel -ge 5) {
        [void]$sb.AppendLine('')
        [void]$sb.AppendLine('### Why not structural?')
        [void]$sb.AppendLine('')
        [void]$sb.AppendLine("This pattern was classified at level $ClassifiedLevel ($SystemicFixType). Consider whether a structural fix (wording-lock, contract test, or validation script) could prevent recurrence at a lower level.")
    }

    if ($CeilingAdvisory) {
        [void]$sb.AppendLine('')
        [void]$sb.AppendLine('### D10 Ceiling Advisory')
        [void]$sb.AppendLine('')
        [void]$sb.AppendLine($CeilingAdvisory)
    }

    return $sb.ToString()
}

function Update-CIICalibrationLinkage {
    param(
        [string]$CalibrationPath,
        [string]$PatternKey,
        [int]$IssueNumber
    )
    if (-not $CalibrationPath -or -not (Test-Path $CalibrationPath)) { return }

    $cal = Get-Content -Raw -Path $CalibrationPath | ConvertFrom-Json
    if ($null -eq $cal) { return }
    $proposals = @(if ($cal.PSObject.Properties.Name -contains 'proposals_emitted') { $cal.proposals_emitted } else { @() })

    $changed = $false
    foreach ($prop in $proposals) {
        $propKey = Get-CIIFlexProperty -Object $prop -Name 'pattern_key'
        if ($propKey -eq $PatternKey) {
            if ($prop -is [PSCustomObject]) {
                if ($prop.PSObject.Properties.Name -contains 'fix_issue_number') {
                    $prop.fix_issue_number = $IssueNumber
                }
                else {
                    $prop | Add-Member -NotePropertyName 'fix_issue_number' -NotePropertyValue $IssueNumber
                }
            }
            $changed = $true
            break
        }
    }

    if ($changed) {
        $tmpPath = "$CalibrationPath.tmp"
        $cal | ConvertTo-Json -Depth 10 | Set-Content -Path $tmpPath -Encoding UTF8
        $null = Get-Content -Raw -Path $tmpPath | ConvertFrom-Json
        Move-Item -Path $tmpPath -Destination $CalibrationPath -Force
    }
}

function New-CIIResult {
    param(
        [int]$ExitCode = 0,
        [string]$Action,
        [string]$Output = '',
        $ErrorMessage = $null,
        $IssueNumber = $null,
        $ConsolidationTarget = $null,
        $ClassifiedLevel = $null,
        $SuggestedLevel = $null,
        $CeilingAdvisory = $null,
        # #837 R1: carried only on the 'would-create' proposal shape returned
        # by New-ImprovementIssueProposal, so the caller can file it.
        $Title = $null,
        $Body = $null,
        $Labels = $null
    )
    return @{
        ExitCode            = $ExitCode
        Action              = $Action
        Output              = $Output
        Error               = $ErrorMessage
        IssueNumber         = $IssueNumber
        ConsolidationTarget = $ConsolidationTarget
        ClassifiedLevel     = $ClassifiedLevel
        SuggestedLevel      = $SuggestedLevel
        CeilingAdvisory     = $CeilingAdvisory
        Title               = $Title
        Body                = $Body
        Labels              = $Labels
    }
}

# ── Main functions ─────────────────────────────────────────────────────

function New-ImprovementIssueProposal {
    <#
    .SYNOPSIS
        Assembles a classified improvement-issue proposal without filing it.

    .DESCRIPTION
        #837 R1 (judge-sustained, critical, owner-ratified option 1): this
        is the assemble-only half of the split. It runs every gate that
        used to run inline in Invoke-CreateImprovementIssue -- §2d
        consolidation -> calibration dedup -> GitHub search dedup -> D10
        ceiling advisory -> D-259-7 classification -> title/body assembly
        -- and returns either an early-exit result (consolidation-candidate
        / skipped-dedup, unchanged from prior behavior) or a
        'would-create' proposal carrying the assembled Title/Body/Labels
        for the caller to file. This function never calls
        `gh issue create` or any other filing side effect.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PatternKey,
        [Parameter(Mandatory)][int[]]$EvidencePrs,
        [Parameter(Mandatory)][string]$FirstEmittedAt,
        [Parameter(Mandatory)][int]$FixTypeLevel,
        [Parameter(Mandatory)][string]$TargetFile,
        [Parameter(Mandatory)][string]$ProposedChange,
        [Parameter(Mandatory)][string]$SystemicFixType,
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][bool]$UpstreamPreflightPassed,
        [string]$CalibrationPath,
        [string]$ComplexityJsonPath,
        [string]$GhCliPath = 'gh',
        [string]$FixTypeOverride,
        [string[]]$Labels = @('priority: medium'),
        [switch]$SkipConsolidation
    )

    # ── Gate 1: §2d consolidation ────────────────────────────────
    if (-not $SkipConsolidation) {
        $consolidation = Search-CIIConsolidationCandidate `
            -SystemicFixType $SystemicFixType -TargetFile $TargetFile `
            -Repo $Repo -GhCliPath $GhCliPath
        if ($consolidation) {
            return New-CIIResult -Action 'consolidation-candidate' `
                -Output "Consolidation candidate found: #$($consolidation.Number)" `
                -ConsolidationTarget $consolidation.Number
        }
    }

    # ── Gate 2: Calibration dedup ────────────────────────────────
    if ($CalibrationPath -and (Test-Path $CalibrationPath)) {
        $cal = Get-Content -Raw -Path $CalibrationPath | ConvertFrom-Json
        if ($null -eq $cal) { $cal = [PSCustomObject]@{} }
        $proposals = @(if ($cal.PSObject.Properties.Name -contains 'proposals_emitted') { $cal.proposals_emitted } else { @() })
        if (Test-CIIPatternKeyExists -Proposals $proposals -PatternKey $PatternKey) {
            return New-CIIResult -Action 'skipped-dedup' `
                -Output "Skipped: pattern_key '$PatternKey' already has fix_issue_number"
        }
    }

    # ── Gate 3: GitHub search dedup ──────────────────────────────
    $ghDedup = Search-CIIGitHubDedup `
        -PatternKey $PatternKey -SystemicFixType $SystemicFixType `
        -Repo $Repo -GhCliPath $GhCliPath
    if ($ghDedup) {
        return New-CIIResult -Action 'skipped-dedup' `
            -Output "Skipped: existing issue #$($ghDedup.Number) found via GitHub search"
    }

    # ── D10 ceiling advisory ─────────────────────────────────────
    $ceilingAdvisory = Get-CIICeilingAdvisory `
        -TargetFile $TargetFile -FixTypeLevel $FixTypeLevel `
        -ComplexityJsonPath $ComplexityJsonPath

    # ── Classification ───────────────────────────────────────────
    $classification = Get-CIIClassifiedLevel `
        -SystemicFixType $SystemicFixType -FixTypeLevel $FixTypeLevel `
        -ProposedChange $ProposedChange -FixTypeOverride $FixTypeOverride

    # ── Assemble title/body (no filing side effect) ──────────────
    $body = New-CIIIssueBody `
        -PatternKey $PatternKey -EvidencePrs $EvidencePrs `
        -FirstEmittedAt $FirstEmittedAt `
        -ClassifiedLevel $classification.ClassifiedLevel `
        -SuggestedLevel $classification.SuggestedLevel `
        -TargetFile $TargetFile -ProposedChange $ProposedChange `
        -SystemicFixType $SystemicFixType `
        -CeilingAdvisory $ceilingAdvisory `
        -FixTypeOverride $FixTypeOverride `
        -UpstreamPreflightPassed $UpstreamPreflightPassed

    $category = Get-CIICategory -PatternKey $PatternKey
    $title = "[Systemic Fix] $SystemicFixType — $category"

    return New-CIIResult -Action 'would-create' `
        -Title $title -Body $body -Labels $Labels `
        -ClassifiedLevel $classification.ClassifiedLevel `
        -SuggestedLevel $classification.SuggestedLevel `
        -CeilingAdvisory $ceilingAdvisory
}

function Invoke-CreateImprovementIssue {
    <#
    .SYNOPSIS
        Assembles a classified improvement-issue proposal and files it.

    .DESCRIPTION
        #837 R1: thin wrapper around New-ImprovementIssueProposal. Non-
        filing outcomes (consolidation-candidate, skipped-dedup) pass
        through unchanged. The 'would-create' outcome is filed via
        safe-operations' Add-FollowUpIssue -- the same production filing
        primitive every other §837-wired surface uses -- rather than a bare
        `gh issue create`, stamped `-FilingProvenance 'pre-gate-legacy'`.

        Why 'pre-gate-legacy' and not an interactively-gated value
        ('gate-approved' / 'gate-modified' / 'direct-request' /
        'queue-consumed'): safe-operations SKILL.md §2e's Filing Approval
        Gate is a parent-conversation-only interactive checkpoint (see
        §2e "Gate ownership"), and this calibration script is headless --
        there is no callable production §2e orchestrator to hand the
        proposal to yet. Process-Review.agent.md §4.8's upstream-gotcha
        path shows the intended shape once that orchestrator exists
        (Process-Review proposes, Code-Conductor gates and files); this
        surface should adopt that same propose/gate split then. Until it
        does, 'pre-gate-legacy' is the reserved, honest transitional stamp
        for "filed without interactive gating" -- not a fabricated gate
        call, per the owner-ratified #837 R1 fix.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PatternKey,
        [Parameter(Mandatory)][int[]]$EvidencePrs,
        [Parameter(Mandatory)][string]$FirstEmittedAt,
        [Parameter(Mandatory)][int]$FixTypeLevel,
        [Parameter(Mandatory)][string]$TargetFile,
        [Parameter(Mandatory)][string]$ProposedChange,
        [Parameter(Mandatory)][string]$SystemicFixType,
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][bool]$UpstreamPreflightPassed,
        [string]$CalibrationPath,
        [string]$ComplexityJsonPath,
        [string]$GhCliPath = 'gh',
        [string]$FixTypeOverride,
        [string[]]$Labels = @('priority: medium'),
        [switch]$SkipConsolidation
    )

    $proposal = New-ImprovementIssueProposal @PSBoundParameters
    if ($proposal.Action -ne 'would-create') {
        return $proposal
    }

    # Add-FollowUpIssue has no -Repo parameter -- it always targets the
    # ambient `gh` repo context -- but calibration-improvement issues may
    # target an upstream hub repo distinct from the local checkout (see the
    # `Repo = '{agent-orchestra-repo or current repo}'` construction in
    # Process-Review.agent.md § Step 4). GH_REPO is gh's documented env-var
    # override for exactly this case; it is set for the duration of the
    # call and restored afterward rather than left as a process-wide change.
    $previousGhRepo = $env:GH_REPO
    try {
        $env:GH_REPO = $Repo

        # Calibration-improvement issues are standalone systemic-fix issues
        # -- they are not children of any single tracked GitHub issue (the
        # evidence is a set of PRs, not an owning issue) -- so ParentIssue
        # is intentionally empty. (Add-FollowUpIssue's -ParentIssue is
        # Mandatory but untyped without [AllowNull()], so $null itself is
        # rejected at parameter binding; an empty string satisfies Mandatory
        # while still carrying no real parent.) Add-FollowUpIssue already
        # degrades this gracefully to a 'text-fallback' parent-link-mode
        # instead of failing (verified: `gh issue view ''` exits non-zero
        # immediately with "invalid issue format" rather than blocking on
        # interactive input, and Add-FollowUpIssue's own parentId/childId
        # check already handles a failed lookup via Write-Warning, not a
        # thrown error).
        $issueUrl = Add-FollowUpIssue `
            -ParentIssue '' `
            -Title $proposal.Title `
            -Body $proposal.Body `
            -Labels $proposal.Labels `
            -OriginatingPr "$($EvidencePrs | Select-Object -First 1)" `
            -FilingProvenance 'pre-gate-legacy'
    }
    finally {
        $env:GH_REPO = $previousGhRepo
    }

    if (-not $issueUrl) {
        return New-CIIResult -ExitCode 1 -Action 'error' `
            -ErrorMessage 'Add-FollowUpIssue failed to file the improvement issue' `
            -ClassifiedLevel $proposal.ClassifiedLevel `
            -SuggestedLevel $proposal.SuggestedLevel `
            -CeilingAdvisory $proposal.CeilingAdvisory
    }

    # Parse issue number from URL
    $issueNumber = if ("$issueUrl" -match '/issues/(\d+)') { [int]$Matches[1] } else { $null }

    # ── Calibration linkage ──────────────────────────────────────
    if ($issueNumber -and $CalibrationPath) {
        Update-CIICalibrationLinkage -CalibrationPath $CalibrationPath `
            -PatternKey $PatternKey -IssueNumber $issueNumber
    }

    return New-CIIResult -Action 'created' `
        -Output "Created issue #$issueNumber" `
        -IssueNumber $issueNumber `
        -ClassifiedLevel $proposal.ClassifiedLevel `
        -SuggestedLevel $proposal.SuggestedLevel `
        -CeilingAdvisory $proposal.CeilingAdvisory
}
