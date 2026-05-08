#Requires -Version 7.0
<#
.SYNOPSIS
    Copilot OTel JSONL walker for cost telemetry (issue #488, Step 3).
.DESCRIPTION
    Reads Copilot Chat OTel JSONL, groups token-bearing inference records by session.id,
    joins each session to the git reflog by session start timestamp, and emits normalized
    assistant cost events compatible with cost-attribution.ps1.
#>

function Get-CopilotBranchSlug {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Branch
    )

    $slug = $Branch.Trim().ToLowerInvariant()
    $slug = [regex]::Replace($slug, '[^a-z0-9]+', '-')
    $slug = [regex]::Replace($slug, '-+', '-')
    return $slug.Trim('-')
}

function Resolve-CostCopilotOutfileTemplate {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Template,
        [Parameter(Mandatory)][string]$WorkspaceRoot,
        [string]$UserHome = [Environment]::GetFolderPath('UserProfile')
    )

    $workspaceFolderBasename = Split-Path -Leaf $WorkspaceRoot
    $substitutions = [System.Collections.Generic.List[string]]::new()
    $diagnostics = [System.Collections.Generic.List[string]]::new()
    $resolved = $Template

    if ($resolved.Contains('${userHome}')) {
        $resolved = $resolved.Replace('${userHome}', $UserHome)
        $substitutions.Add('userHome')
    }

    if ($resolved.Contains('${workspaceFolderBasename}')) {
        $resolved = $resolved.Replace('${workspaceFolderBasename}', $workspaceFolderBasename)
        $substitutions.Add('workspaceFolderBasename')
    }

    if ($resolved.Contains('${workspaceFolder}')) {
        $resolved = $resolved.Replace('${workspaceFolder}', $WorkspaceRoot)
        $substitutions.Add('workspaceFolder')
    }

    $resolved = [regex]::Replace($resolved, '\$\{env:([^}]+)\}', {
            param($Match)
            $envName = $Match.Groups[1].Value
            $substitutions.Add("env:$envName")
            return [Environment]::GetEnvironmentVariable($envName, 'Process') ?? ''
        })

    $diagnostics.Add('github.copilot.chat.otel.outfile does not expand VS Code template variables during file export; write a literal resolved path instead.')

    return [pscustomobject]@{
        Template                 = $Template
        ResolvedPath             = $resolved
        Substitutions            = [string[]]$substitutions.ToArray()
        TemplateSupportedByVSCode = $false
        Diagnostics              = [string[]]$diagnostics.ToArray()
    }
}

function Get-CostCopilotReflog {
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)][string]$RepoRoot
    )

    $lines = @(git -C $RepoRoot reflog --date=iso-strict --format='%h %gd: %gs' 2>$null)
    return , [string[]]$lines
}

function script:Get-CostCopilotObjectValue {
    param(
        [AllowNull()][object]$Object,
        [Parameter(Mandatory)][string]$Name
    )

    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary]) { return $Object[$Name] }
    return $Object.$Name
}

function script:Get-CostCopilotNonBlankString {
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) { return $null }

    $text = [string]$Value
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }

    return $text
}

function script:Get-CostCopilotAttributes {
    param([AllowNull()][object]$Record)

    return script:Get-CostCopilotObjectValue -Object $Record -Name 'attributes'
}

function script:Get-CostCopilotAttributeValue {
    param(
        [AllowNull()][object]$Record,
        [Parameter(Mandatory)][string]$Name
    )

    $attributes = script:Get-CostCopilotAttributes -Record $Record
    return script:Get-CostCopilotObjectValue -Object $attributes -Name $Name
}

function script:Get-CostCopilotResourceAttributeValue {
    param(
        [AllowNull()][object]$Record,
        [Parameter(Mandatory)][string]$Name
    )

    $resource = script:Get-CostCopilotObjectValue -Object $Record -Name 'resource'
    $rawAttributes = script:Get-CostCopilotObjectValue -Object $resource -Name '_rawAttributes'
    if ($null -eq $rawAttributes) { return $null }

    foreach ($pair in $rawAttributes) {
        if ($null -eq $pair -or $pair.Count -lt 2) { continue }
        if ([string]$pair[0] -eq $Name) { return $pair[1] }
    }

    return $null
}

function script:Get-CostCopilotSessionId {
    param([AllowNull()][object]$Record)

    $sessionId = script:Get-CostCopilotNonBlankString -Value (script:Get-CostCopilotAttributeValue -Record $Record -Name 'session.id')
    if ($null -ne $sessionId) { return $sessionId }

    $resourceSessionId = script:Get-CostCopilotNonBlankString -Value (script:Get-CostCopilotResourceAttributeValue -Record $Record -Name 'session.id')
    if ($null -ne $resourceSessionId) { return $resourceSessionId }

    return $null
}

function script:Get-CostCopilotRecordTimestamp {
    param([AllowNull()][object]$Record)

    foreach ($fieldName in @('hrTime', 'hrTimeObserved')) {
        $timeParts = script:Get-CostCopilotObjectValue -Object $Record -Name $fieldName
        if ($null -eq $timeParts -or $timeParts.Count -lt 1) { continue }

        $seconds = [int64]$timeParts[0]
        $nanoseconds = if ($timeParts.Count -gt 1) { [int64]$timeParts[1] } else { 0 }
        return [DateTimeOffset]::FromUnixTimeSeconds($seconds).AddTicks([int64]($nanoseconds / 100))
    }

    $timestamp = script:Get-CostCopilotObjectValue -Object $Record -Name 'timestamp'
    if ($null -ne $timestamp) {
        try { return [DateTimeOffset]::Parse([string]$timestamp).ToUniversalTime() }
        catch { return $null }
    }

    return $null
}

function script:Get-CostCopilotTokenCount {
    param(
        [AllowNull()][object]$Record,
        [Parameter(Mandatory)][string]$Name
    )

    $value = script:Get-CostCopilotAttributeValue -Record $Record -Name $Name
    if ($null -eq $value) { return 0 }

    $tokenCount = 0
    if ([int]::TryParse([string]$value, [ref]$tokenCount)) { return $tokenCount }
    return 0
}

function script:New-CostCopilotSessionBucket {
    param(
        [Parameter(Mandatory)][string]$SessionId,
        [Parameter(Mandatory)][DateTimeOffset]$Timestamp
    )

    return [ordered]@{
        SessionId    = $SessionId
        Start        = $Timestamp
        InputTokens  = 0
        OutputTokens = 0
        AgentType    = $null
        Model        = $null
    }
}

function script:Update-CostCopilotSessionBucket {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Bucket,
        [Parameter(Mandatory)]$Record,
        [Parameter(Mandatory)][DateTimeOffset]$Timestamp
    )

    if ($Timestamp -lt $Bucket['Start']) { $Bucket['Start'] = $Timestamp }

    $agentName = script:Get-CostCopilotNonBlankString -Value (script:Get-CostCopilotAttributeValue -Record $Record -Name 'gen_ai.agent.name')
    if ($null -ne $agentName) { $Bucket['AgentType'] = $agentName }

    $responseModel = script:Get-CostCopilotNonBlankString -Value (script:Get-CostCopilotAttributeValue -Record $Record -Name 'gen_ai.response.model')
    $requestModel = script:Get-CostCopilotNonBlankString -Value (script:Get-CostCopilotAttributeValue -Record $Record -Name 'gen_ai.request.model')
    $model = if ($null -ne $responseModel) { $responseModel } else { $requestModel }
    if ($null -ne $model) { $Bucket['Model'] = $model }

    $Bucket['InputTokens'] += script:Get-CostCopilotTokenCount -Record $Record -Name 'gen_ai.usage.input_tokens'
    $Bucket['OutputTokens'] += script:Get-CostCopilotTokenCount -Record $Record -Name 'gen_ai.usage.output_tokens'
}

function script:Read-CostCopilotSessions {
    param(
        [Parameter(Mandatory)][string]$OtelJsonlPath
    )

    $sessions = [ordered]@{}
    $lines = @(Get-Content -Path $OtelJsonlPath -Encoding utf8 -ErrorAction SilentlyContinue)

    foreach ($line in $lines) {
        $trimmed = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($trimmed) -or $trimmed -eq '{}') { continue }

        $record = $null
        try { $record = $trimmed | ConvertFrom-Json -AsHashtable -ErrorAction Stop }
        catch {
            Write-Warning "cost-walker-copilot: failed to parse OTel JSON line in ${OtelJsonlPath}: $_"
            continue
        }

        if ($record.Count -eq 0) { continue }

        $sessionId = script:Get-CostCopilotSessionId -Record $record
        if ([string]::IsNullOrWhiteSpace($sessionId)) { continue }

        $timestamp = script:Get-CostCopilotRecordTimestamp -Record $record
        if ($null -eq $timestamp) { continue }

        if (-not $sessions.Contains($sessionId)) {
            $sessions[$sessionId] = script:New-CostCopilotSessionBucket -SessionId $sessionId -Timestamp $timestamp
        }

        script:Update-CostCopilotSessionBucket -Bucket $sessions[$sessionId] -Record $record -Timestamp $timestamp
    }

    return @($sessions.Values | Where-Object { ([int]$_['InputTokens'] + [int]$_['OutputTokens']) -gt 0 })
}

function script:ConvertFrom-CostCopilotReflogLine {
    param([Parameter(Mandatory)][string]$Line)

    $match = [regex]::Match($Line, '^\S+\s+HEAD@\{(?<timestamp>[^}]+)\}:\s+(?<subject>.*)$')
    if (-not $match.Success) { return $null }

    try { $timestamp = [DateTimeOffset]::Parse($match.Groups['timestamp'].Value).ToUniversalTime() }
    catch { return $null }

    return [pscustomobject]@{
        Timestamp = $timestamp
        Subject   = $match.Groups['subject'].Value
    }
}

function script:Test-CostCopilotDetachedTarget {
    param([AllowNull()][string]$BranchName)

    if ([string]::IsNullOrWhiteSpace($BranchName)) { return $true }
    return [regex]::IsMatch($BranchName, '^[0-9a-f]{7,40}$', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
}

function script:ConvertTo-CostCopilotBranchTimeline {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$ReflogLines,
        [Parameter(Mandatory)][string]$TargetBranch
    )

    $timeline = [System.Collections.Generic.List[object]]::new()
    foreach ($line in $ReflogLines) {
        $entry = script:ConvertFrom-CostCopilotReflogLine -Line $line
        if ($null -ne $entry) { $timeline.Add($entry) }
    }

    $timeline = @($timeline | Sort-Object -Property Timestamp)
    $windows = [System.Collections.Generic.List[object]]::new()
    $currentBranch = $null
    $currentStart = $null
    $detachedWarnings = [System.Collections.Generic.List[string]]::new()

    foreach ($entry in $timeline) {
        $subject = [string]$entry.Subject
        $checkoutMatch = [regex]::Match($subject, '^checkout: moving from (?<from>.+) to (?<to>.+)$')
        $renameMatch = [regex]::Match($subject, '^Branch: renamed refs/heads/(?<from>.+) to refs/heads/(?<to>.+)$')

        if ($checkoutMatch.Success) {
            if ($null -ne $currentBranch -and $currentBranch -eq $TargetBranch -and $null -ne $currentStart) {
                $windows.Add([pscustomobject]@{ Start = $currentStart; End = $entry.Timestamp })
            }

            $toBranch = $checkoutMatch.Groups['to'].Value
            if (script:Test-CostCopilotDetachedTarget -BranchName $toBranch) {
                $currentBranch = $null
                $currentStart = $null
                $detachedWarnings.Add("cost-walker-copilot: copilot-reflog-detached-head at $($entry.Timestamp.ToString('o'))")
                continue
            }

            $currentBranch = $toBranch
            $currentStart = $entry.Timestamp
            continue
        }

        if ($renameMatch.Success) {
            $fromBranch = $renameMatch.Groups['from'].Value
            $toBranch = $renameMatch.Groups['to'].Value
            if ($null -eq $currentBranch -or $currentBranch -eq $fromBranch -or $toBranch -eq $TargetBranch) {
                $currentBranch = $toBranch
                $currentStart = $entry.Timestamp
            }
        }
    }

    if ($null -ne $currentBranch -and $currentBranch -eq $TargetBranch -and $null -ne $currentStart) {
        $windows.Add([pscustomobject]@{ Start = $currentStart; End = $null })
    }

    return [pscustomobject]@{
        Windows          = @($windows)
        DetachedWarnings = [string[]]$detachedWarnings.ToArray()
    }
}

function script:Test-CostCopilotSessionInBranchWindow {
    param(
        [Parameter(Mandatory)][DateTimeOffset]$SessionStart,
        [Parameter(Mandatory)]$Window
    )

    $clockSkewTolerance = [TimeSpan]::FromSeconds(5)
    $windowStart = $Window.Start.Subtract($clockSkewTolerance)
    if ($SessionStart -lt $windowStart) { return $false }
    if ($null -ne $Window.End -and $SessionStart -ge $Window.End) { return $false }
    return $true
}

function script:New-CostCopilotEvent {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Session,
        [Parameter(Mandatory)][string]$Branch,
        [Parameter(Mandatory)][string]$WorkspaceFolderBasename
    )

    $rawAgentType = script:Get-CostCopilotNonBlankString -Value ($Session['AgentType'])
    $agentType = if ($null -eq $rawAgentType) { 'GitHub Copilot Chat' } else { $rawAgentType }
    $model = script:Get-CostCopilotNonBlankString -Value ($Session['Model'])

    return [ordered]@{
        type      = 'assistant'
        provider  = 'copilot'
        agentType = $agentType
        sessionId = [string]$Session['SessionId']
        timestamp = ([DateTimeOffset]$Session['Start']).ToUniversalTime().ToString('o')
        cwd       = "copilot-otel://$WorkspaceFolderBasename"
        gitBranch = $Branch
        message   = [ordered]@{
            model   = $model
            usage   = [ordered]@{
                input_tokens                = [int]$Session['InputTokens']
                output_tokens               = [int]$Session['OutputTokens']
                cache_creation_input_tokens = $null
                cache_read_input_tokens     = $null
            }
            content = @()
        }
    }
}

function Invoke-CostCopilotWalk {
    [CmdletBinding()]
    [OutputType([object[]], [System.Collections.Generic.List[object]])]
    param(
        [Parameter(Mandatory)][string]$Branch,
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$OtelJsonlPath,
        [string]$WorkspaceFolderBasename = ''
    )

    if (-not $WorkspaceFolderBasename) {
        $WorkspaceFolderBasename = Split-Path -Leaf $RepoRoot
    }

    $sessions = @(script:Read-CostCopilotSessions -OtelJsonlPath $OtelJsonlPath)
    if ($sessions.Count -eq 0) { return @() }

    $reflogLines = @(Get-CostCopilotReflog -RepoRoot $RepoRoot)
    if ($reflogLines.Count -eq 0) {
        Write-Warning 'cost-walker-copilot: copilot-reflog-empty; empty reflog, cannot attribute Copilot OTel sessions to a branch window'
        return @()
    }

    $timeline = script:ConvertTo-CostCopilotBranchTimeline -ReflogLines $reflogLines -TargetBranch $Branch
    foreach ($warning in $timeline.DetachedWarnings) {
        Write-Warning $warning
    }

    $included = [System.Collections.Generic.List[object]]::new()
    $unmapped = [System.Collections.Generic.List[string]]::new()

    foreach ($session in @($sessions | Sort-Object -Property Start)) {
        $matched = $false
        foreach ($window in $timeline.Windows) {
            if (script:Test-CostCopilotSessionInBranchWindow -SessionStart $session['Start'] -Window $window) {
                $included.Add((script:New-CostCopilotEvent -Session $session -Branch $Branch -WorkspaceFolderBasename $WorkspaceFolderBasename))
                $matched = $true
                break
            }
        }

        if (-not $matched) {
            $unmapped.Add([string]$session['SessionId'])
        }
    }

    if ($unmapped.Count -gt 0) {
        Write-Warning "cost-walker-copilot: copilot-reflog-no-match; unmapped_session_count=$($unmapped.Count); sessions=$($unmapped -join ',')"
    }

    return $included
}
