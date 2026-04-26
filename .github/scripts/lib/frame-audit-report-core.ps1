#Requires -Version 7.0
<#!
.SYNOPSIS
    Library for frame audit report aggregation. Dot-source and call Invoke-FrameAuditReport.
#>

$script:FARLibDir = Split-Path -Parent $PSCommandPath
. "$script:FARLibDir/frame-back-derive-core.ps1"

function Get-FARArray {
    param($Value)

    if ($null -eq $Value) {
        return @()
    }

    if ($Value -is [string]) {
        return @($Value)
    }

    if ($Value -is [System.Collections.IDictionary]) {
        return @($Value)
    }

    if ($Value -is [System.Collections.IEnumerable]) {
        return @($Value)
    }

    return @($Value)
}

function Get-FARGitHubJson {
    param(
        [Parameter(Mandatory)][string]$GhCliPath,
        [Parameter(Mandatory)][string[]]$Arguments,
        [Parameter(Mandatory)][string]$Context
    )

    $output = & $GhCliPath @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    $rawOutput = (@($output) | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine

    if ($exitCode -ne 0) {
        $message = $rawOutput.Trim()
        if ([string]::IsNullOrWhiteSpace($message)) {
            $message = "$Context exited with code $exitCode."
        }

        throw "$Context failed: $message"
    }

    if ([string]::IsNullOrWhiteSpace($rawOutput)) {
        throw "$Context returned no output."
    }

    try {
        return ($rawOutput | ConvertFrom-Json -AsHashtable)
    }
    catch {
        throw "$Context returned invalid JSON: $($_.Exception.Message)"
    }
}

function Get-FARBucketNames {
    return @('passed', 'failed', 'N/A', 'skipped', 'inconclusive', 'missing')
}

function New-FARBucketMap {
    $buckets = [ordered]@{}
    foreach ($bucket in (Get-FARBucketNames)) {
        $buckets[$bucket] = 0
    }

    return $buckets
}

function Get-FARBucketForCreditStatus {
    param([string]$Status)

    switch ($Status) {
        'passed' { return 'passed' }
        'failed' { return 'failed' }
        'not-applicable' { return 'N/A' }
        'skipped' { return 'skipped' }
        'inconclusive' { return 'inconclusive' }
    }

    $displayStatus = if ([string]::IsNullOrWhiteSpace($Status)) { '<blank>' } else { $Status }
    throw "Unsupported credit status '$displayStatus'. Report bucket 'missing' is reserved for ports with no credit entry."
}

function Get-FARDefaultPortsDir {
    $repoRoot = (Resolve-Path (Join-Path $script:FARLibDir '../../..')).Path
    return (Join-Path $repoRoot 'frame/ports')
}

function Get-FARPortMetadata {
    param(
        [Parameter(Mandatory)][string]$PortsDir,
        [Parameter(Mandatory)][string[]]$Ports
    )

    $metadata = [ordered]@{}
    foreach ($port in $Ports) {
        $entry = [ordered]@{
            name    = $port
            applies = 'always'
            status  = 'stable'
        }

        $portFile = Join-Path $PortsDir ($port + '.yaml')
        if (Test-Path -LiteralPath $portFile) {
            foreach ($line in (Get-Content -Path $portFile)) {
                if ($line -match '^(name|applies|status):\s*(?<value>.+?)\s*$') {
                    $entry[$matches[1]] = $matches['value']
                }
            }
        }

        $metadata[$port] = $entry
    }

    return $metadata
}

function Get-FARSelectedPrNumbers {
    param(
        [int]$PrCount,
        [datetime]$Since,
        [int[]]$PrList,
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][string]$GhCliPath
    )

    if (@($PrList).Count -gt 0) {
        $ordered = [System.Collections.Generic.List[int]]::new()
        foreach ($prNumber in $PrList) {
            if ($prNumber -gt 0 -and -not $ordered.Contains($prNumber)) {
                $ordered.Add($prNumber)
            }
        }

        return $ordered.ToArray()
    }

    $limit = if ($PrCount -gt 0) { $PrCount } else { 30 }
    $arguments = @(
        'pr',
        'list',
        '--repo',
        $Repo,
        '--state',
        'merged',
        '--limit',
        [string]$limit,
        '--json',
        'number,mergedAt,title,body'
    )

    if ($PSBoundParameters.ContainsKey('Since')) {
        $arguments += @('--search', ('merged:>={0}' -f $Since.ToString('yyyy-MM-dd')))
    }

    $response = Get-FARGitHubJson -GhCliPath $GhCliPath -Arguments $arguments -Context 'gh pr list'
    $entries = @(Get-FARArray $response)
    if (@($entries).Count -eq 0) {
        return @()
    }

    $ordered = $entries | Sort-Object -Property @(
        @{ Expression     = {
                $mergedAt = $_['mergedAt']
                if ([string]::IsNullOrWhiteSpace([string]$mergedAt)) {
                    return [datetime]::MinValue
                }

                return [datetime]$mergedAt
            }; Descending = $true 
        },
        @{ Expression = { [int]$_['number'] }; Descending = $true }
    )

    $prNumbers = [System.Collections.Generic.List[int]]::new()
    foreach ($entry in $ordered) {
        $number = $entry['number']
        if ($null -ne $number) {
            $prNumbers.Add([int]$number)
        }
    }

    return $prNumbers.ToArray()
}

function New-FARPortState {
    param(
        [Parameter(Mandatory)][string]$Port,
        [Parameter(Mandatory)]$Metadata
    )

    return [ordered]@{
        port        = $Port
        applies     = [string]$Metadata.applies
        port_status = [string]$Metadata.status
        total       = 0
        buckets     = (New-FARBucketMap)
    }
}

function New-FAREraState {
    param(
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][string[]]$Ports,
        [Parameter(Mandatory)]$PortMetadata
    )

    $portStates = [ordered]@{}
    foreach ($port in $Ports) {
        $portStates[$port] = New-FARPortState -Port $port -Metadata $PortMetadata[$port]
    }

    return [ordered]@{
        key        = $Key
        label      = $Label
        pr_numbers = [System.Collections.Generic.List[int]]::new()
        ports      = $portStates
    }
}

function Add-FARCreditToEra {
    param(
        [Parameter(Mandatory)]$EraState,
        [Parameter(Mandatory)][string[]]$Ports,
        [Parameter(Mandatory)]$AuditSurface
    )

    $seenPorts = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($credit in (Get-FARArray $AuditSurface.credits)) {
        $port = [string]$credit['port']
        if ([string]::IsNullOrWhiteSpace($port) -or -not $EraState.ports.Contains($port)) {
            continue
        }
        $bucket = Get-FARBucketForCreditStatus -Status ([string]$credit['status'])
        $portState = $EraState.ports[$port]
        $portState.total = [int]$portState.total + 1
        $portState.buckets[$bucket] = [int]$portState.buckets[$bucket] + 1
        $null = $seenPorts.Add($port)
    }

    foreach ($port in $Ports) {
        if (-not $seenPorts.Contains($port)) {
            $portState = $EraState.ports[$port]
            $portState.total = [int]$portState.total + 1
            $portState.buckets['missing'] = [int]$portState.buckets['missing'] + 1
        }
    }
}

function Add-FARMissingPrToEra {
    param(
        [Parameter(Mandatory)]$EraState,
        [Parameter(Mandatory)][string[]]$Ports
    )

    foreach ($port in $Ports) {
        $portState = $EraState.ports[$port]
        $portState.total = [int]$portState.total + 1
        $portState.buckets['missing'] = [int]$portState.buckets['missing'] + 1
    }
}

function Test-FARDerivationGapError {
    param([string]$ErrorText)

    if ([string]::IsNullOrWhiteSpace($ErrorText)) {
        return $false
    }

    return (
        $ErrorText -match 'does not contain a pipeline-metrics block' -or
        $ErrorText -match 'pipeline-metrics block without metrics_version' -or
        $ErrorText -match 'Unsupported metrics_version'
    )
}

function ConvertTo-FAREraOutput {
    param(
        [Parameter(Mandatory)]$EraState,
        [Parameter(Mandatory)][string[]]$Ports
    )

    $portRows = foreach ($port in $Ports) {
        $state = $EraState.ports[$port]
        [pscustomobject]@{
            port        = $state.port
            applies     = $state.applies
            port_status = $state.port_status
            total       = [int]$state.total
            buckets     = [pscustomobject]@{
                passed       = [int]$state.buckets['passed']
                failed       = [int]$state.buckets['failed']
                'N/A'        = [int]$state.buckets['N/A']
                skipped      = [int]$state.buckets['skipped']
                inconclusive = [int]$state.buckets['inconclusive']
                missing      = [int]$state.buckets['missing']
            }
        }
    }

    return [pscustomobject]@{
        key        = $EraState.key
        label      = $EraState.label
        pr_count   = @($EraState.pr_numbers).Count
        pr_numbers = $EraState.pr_numbers.ToArray()
        ports      = @($portRows)
    }
}

function Test-FARRecommendationCandidate {
    param(
        [Parameter(Mandatory)][string]$Port,
        [Parameter(Mandatory)]$State
    )

    if ($State.port_status -ne 'stable') {
        return $false
    }

    $missing = [int]$State.buckets['missing']
    $inconclusive = [int]$State.buckets['inconclusive']
    $skipped = [int]$State.buckets['skipped']

    if ($Port -like 'ce-gate-*' -and $inconclusive -gt 0) {
        return $false
    }

    return (((100 * $missing) + (10 * $inconclusive) + $skipped) -gt 0)
}

function Get-FARRecommendations {
    param(
        [Parameter(Mandatory)]$EraState,
        [Parameter(Mandatory)][string[]]$Ports
    )

    $candidates = foreach ($port in $Ports) {
        $state = $EraState.ports[$port]
        $missing = [int]$state.buckets['missing']
        $inconclusive = [int]$state.buckets['inconclusive']
        $skipped = [int]$state.buckets['skipped']
        if (-not (Test-FARRecommendationCandidate -Port $port -State $state)) {
            continue
        }

        $score = (100 * $missing) + (10 * $inconclusive) + $skipped

        [ordered]@{
            port         = $port
            score        = $score
            missing      = $missing
            inconclusive = $inconclusive
            skipped      = $skipped
            rationale    = ('post-pivot gaps for {0}: missing={1}, inconclusive={2}, skipped={3}.' -f $port, $missing, $inconclusive, $skipped)
        }
    }

    return @(
        $candidates |
            Sort-Object -Property @(
                @{ Expression = { [int]$_['score'] }; Descending = $true },
                @{ Expression = { [int]$_['missing'] }; Descending = $true },
                @{ Expression = { [int]$_['inconclusive'] }; Descending = $true },
                @{ Expression = { [int]$_['skipped'] }; Descending = $true },
                @{ Expression = { [string]$_['port'] }; Descending = $false }
            ) |
            Select-Object -First 3
    )
}

function Get-FARTbdPorts {
    param(
        [Parameter(Mandatory)]$PrePivotEra,
        [Parameter(Mandatory)]$PostPivotEra,
        [Parameter(Mandatory)][string[]]$Ports
    )

    $tbdPorts = foreach ($port in $Ports) {
        $postState = $PostPivotEra.ports[$port]
        if ($postState.port_status -eq 'stable') {
            continue
        }

        $preState = $PrePivotEra.ports[$port]
        [ordered]@{
            port             = $port
            port_status      = $postState.port_status
            applies          = $postState.applies
            excluded_reason  = 'Excluded from recommendation ranking until the port status is decided.'
            pre_pivot_total  = [int]$preState.total
            post_pivot_total = [int]$postState.total
        }
    }

    return @($tbdPorts)
}

function ConvertTo-FARJson {
    param([Parameter(Mandatory)]$Report)

    return ($Report | ConvertTo-Json -Depth 12)
}

function Get-FARTableLine {
    param(
        [Parameter(Mandatory)][string[]]$Columns,
        [string]$Separator = ' | '
    )

    return ($Columns -join $Separator)
}

function ConvertTo-FARText {
    param([Parameter(Mandatory)]$Report)

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('Frame audit report (audit-only)')
    $lines.Add(('Repo: {0}' -f $Report.repo))
    $lines.Add(('PR window: {0} PR(s)' -f [int]$Report.selection.pr_count))
    $lines.Add(('Era split pivot PR: {0}' -f [int]$Report.selection.era_split_pivot_pr))
    if ($Report.selection.since) {
        $lines.Add(('Since: {0}' -f $Report.selection.since))
    }
    $lines.Add('')

    foreach ($era in $Report.eras) {
        $lines.Add(('{0} ({1} PRs)' -f $era.label, [int]$era.pr_count))
        $lines.Add((Get-FARTableLine -Columns @('port', 'passed', 'failed', 'N/A', 'skipped', 'inconclusive', 'missing')))
        foreach ($port in $era.ports) {
            $lines.Add((Get-FARTableLine -Columns @(
                        [string]$port.port,
                        [string]$port.buckets.passed,
                        [string]$port.buckets.failed,
                        [string]$port.buckets.'N/A',
                        [string]$port.buckets.skipped,
                        [string]$port.buckets.inconclusive,
                        [string]$port.buckets.missing
                    )))
        }
        $lines.Add('')
    }

    $lines.Add('TBD ports')
    if (@($Report.tbd_ports).Count -eq 0) {
        $lines.Add('- none')
    }
    else {
        foreach ($port in $Report.tbd_ports) {
            $lines.Add(('- {0} ({1})' -f $port.port, $port.port_status))
        }
    }
    $lines.Add('')

    $lines.Add('Top post-pivot recommendations')
    if (@($Report.recommendations).Count -eq 0) {
        $lines.Add('- none')
    }
    else {
        foreach ($recommendation in $Report.recommendations) {
            $lines.Add(('- {0}: score={1}; missing={2}; inconclusive={3}; skipped={4}' -f $recommendation.port, $recommendation.score, $recommendation.missing, $recommendation.inconclusive, $recommendation.skipped))
        }
    }

    return ($lines -join [Environment]::NewLine)
}

function ConvertTo-FARMarkdown {
    param([Parameter(Mandatory)]$Report)

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('# Frame Audit Report')
    $lines.Add('')
    $lines.Add(('- Repo: {0}' -f $Report.repo))
    $lines.Add(('- PR window: {0} PR(s)' -f [int]$Report.selection.pr_count))
    $lines.Add(('- Era split pivot PR: {0}' -f [int]$Report.selection.era_split_pivot_pr))
    if ($Report.selection.since) {
        $lines.Add(('- Since: {0}' -f $Report.selection.since))
    }
    $lines.Add('')

    foreach ($era in $Report.eras) {
        $lines.Add(('## {0} ({1} PRs)' -f $era.label, [int]$era.pr_count))
        $lines.Add('')
        $lines.Add('| port | passed | failed | N/A | skipped | inconclusive | missing |')
        $lines.Add('| --- | ---: | ---: | ---: | ---: | ---: | ---: |')
        foreach ($port in $era.ports) {
            $lines.Add(('| {0} | {1} | {2} | {3} | {4} | {5} | {6} |' -f $port.port, $port.buckets.passed, $port.buckets.failed, $port.buckets.'N/A', $port.buckets.skipped, $port.buckets.inconclusive, $port.buckets.missing))
        }
        $lines.Add('')
    }

    $lines.Add('## TBD Ports')
    $lines.Add('')
    if (@($Report.tbd_ports).Count -eq 0) {
        $lines.Add('- none')
    }
    else {
        foreach ($port in $Report.tbd_ports) {
            $lines.Add(('- {0} ({1})' -f $port.port, $port.port_status))
        }
    }
    $lines.Add('')

    $lines.Add('## Top Post-Pivot Recommendations')
    $lines.Add('')
    if (@($Report.recommendations).Count -eq 0) {
        $lines.Add('- none')
    }
    else {
        foreach ($recommendation in $Report.recommendations) {
            $lines.Add(('- {0}: score={1}; missing={2}; inconclusive={3}; skipped={4}' -f $recommendation.port, $recommendation.score, $recommendation.missing, $recommendation.inconclusive, $recommendation.skipped))
        }
    }

    return ($lines -join [Environment]::NewLine)
}

function Invoke-FrameAuditReport {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [int]$PrCount = 30,
        [datetime]$Since,
        [int[]]$PrList = @(),
        [ValidateSet('json', 'markdown', 'text')][string]$OutputFormat = 'text',
        [int]$EraSplitPivotPr = 356,
        [string]$Repo = 'Grimblaz/agent-orchestra',
        [string]$GhCliPath = 'gh',
        [string]$PortsDir,
        [string]$CacheDir,
        [switch]$NoCache
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    try {
        if ([string]::IsNullOrWhiteSpace($PortsDir)) {
            $PortsDir = Get-FARDefaultPortsDir
        }

        $ports = Get-FBDPortOrder -PortsDir $PortsDir
        $portMetadata = Get-FARPortMetadata -PortsDir $PortsDir -Ports $ports
        $selectionParams = @{
            PrCount   = $PrCount
            Repo      = $Repo
            GhCliPath = $GhCliPath
            PrList    = $PrList
        }
        if ($PSBoundParameters.ContainsKey('Since')) {
            $selectionParams['Since'] = $Since
        }

        $selectedPrNumbers = Get-FARSelectedPrNumbers @selectionParams

        $prePivotEra = New-FAREraState -Key 'pre-pivot' -Label ('PRs < {0}' -f $EraSplitPivotPr) -Ports $ports -PortMetadata $portMetadata
        $postPivotEra = New-FAREraState -Key 'post-pivot' -Label ('PRs >= {0}' -f $EraSplitPivotPr) -Ports $ports -PortMetadata $portMetadata

        foreach ($prNumber in $selectedPrNumbers) {
            $eraState = if ($prNumber -lt $EraSplitPivotPr) { $prePivotEra } else { $postPivotEra }
            $eraState.pr_numbers.Add([int]$prNumber)

            $backDeriveResult = Invoke-FrameBackDerive -PrNumber $prNumber -OutputFormat 'json' -Repo $Repo -GhCliPath $GhCliPath -PortsDir $PortsDir -CacheDir $CacheDir -NoCache:$NoCache.IsPresent
            if ([int]$backDeriveResult.ExitCode -ne 0) {
                if (Test-FARDerivationGapError -ErrorText ([string]$backDeriveResult.Error)) {
                    Add-FARMissingPrToEra -EraState $eraState -Ports $ports
                    continue
                }

                return @{ ExitCode = 1; Output = ''; Error = ('frame-audit-report failed while deriving PR #{0}: {1}' -f $prNumber, $backDeriveResult.Error) }
            }

            try {
                $auditSurface = $backDeriveResult.Output | ConvertFrom-Json -AsHashtable
            }
            catch {
                return @{ ExitCode = 1; Output = ''; Error = ('frame-audit-report failed to parse back-derive output for PR #{0}: {1}' -f $prNumber, $_.Exception.Message) }
            }

            Add-FARCreditToEra -EraState $eraState -Ports $ports -AuditSurface $auditSurface
        }

        $report = [ordered]@{
            frame_audit_report_version = 1
            repo                       = $Repo
            selection                  = [ordered]@{
                pr_count           = @($selectedPrNumbers).Count
                pr_numbers         = @($selectedPrNumbers)
                since              = if ($PSBoundParameters.ContainsKey('Since')) { $Since.ToString('yyyy-MM-dd') } else { '' }
                era_split_pivot_pr = $EraSplitPivotPr
            }
            eras                       = @(
                (ConvertTo-FAREraOutput -EraState $prePivotEra -Ports $ports),
                (ConvertTo-FAREraOutput -EraState $postPivotEra -Ports $ports)
            )
            recommendations            = @(Get-FARRecommendations -EraState $postPivotEra -Ports $ports)
            tbd_ports                  = @(Get-FARTbdPorts -PrePivotEra $prePivotEra -PostPivotEra $postPivotEra -Ports $ports)
        }

        $serializedOutput = switch ($OutputFormat) {
            'json' { ConvertTo-FARJson -Report $report }
            'markdown' { ConvertTo-FARMarkdown -Report $report }
            'text' { ConvertTo-FARText -Report $report }
        }

        return @{ ExitCode = 0; Output = $serializedOutput; Error = '' }
    }
    catch {
        return @{ ExitCode = 1; Output = ''; Error = ('frame-audit-report failed: {0}' -f $_.Exception.Message) }
    }
}
