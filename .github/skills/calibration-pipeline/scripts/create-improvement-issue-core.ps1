#Requires -Version 7.0

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
        $CeilingAdvisory = $null
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
    }
}

# ── Main function ─────────────────────────────────────────────────────

function Invoke-CreateImprovementIssue {
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

    # ── Create issue ─────────────────────────────────────────────
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
    $labelArgs = @($Labels | ForEach-Object { '--label'; $_ })

    $output = & $GhCliPath issue create --repo $Repo --title $title --body $body @labelArgs 2>$null
    if ($LASTEXITCODE -ne 0) {
        return New-CIIResult -ExitCode 1 -Action 'error' `
            -ErrorMessage "gh issue create failed with exit code $LASTEXITCODE" `
            -ClassifiedLevel $classification.ClassifiedLevel `
            -SuggestedLevel $classification.SuggestedLevel `
            -CeilingAdvisory $ceilingAdvisory
    }

    # Parse issue number from URL
    $issueNumber = if ("$output" -match '/issues/(\d+)') { [int]$Matches[1] } else { $null }

    # ── Calibration linkage ──────────────────────────────────────
    if ($issueNumber -and $CalibrationPath) {
        Update-CIICalibrationLinkage -CalibrationPath $CalibrationPath `
            -PatternKey $PatternKey -IssueNumber $issueNumber
    }

    return New-CIIResult -Action 'created' `
        -Output "Created issue #$issueNumber" `
        -IssueNumber $issueNumber `
        -ClassifiedLevel $classification.ClassifiedLevel `
        -SuggestedLevel $classification.SuggestedLevel `
        -CeilingAdvisory $ceilingAdvisory
}
