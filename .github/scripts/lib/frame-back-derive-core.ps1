#Requires -Version 7.0
<#!
.SYNOPSIS
    Library for frame back-derivation logic. Dot-source and call Invoke-FrameBackDerive.
#>

function Get-FBDPropertyValue {
    param(
        [Parameter(Mandatory)]$InputObject,
        [Parameter(Mandatory)][string]$Name
    )

    if ($null -eq $InputObject) {
        return $null
    }

    if ($InputObject -is [System.Collections.IDictionary]) {
        if ($InputObject.Contains($Name)) {
            return $InputObject[$Name]
        }

        return $null
    }

    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -ne $property) {
        return $property.Value
    }

    return $null
}

function Get-FBDArray {
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

function Get-FBDMetricsBlock {
    param([string]$Body)

    if ([string]::IsNullOrWhiteSpace($Body)) {
        return $null
    }

    $match = [regex]::Match($Body, '(?s)<!--\s*pipeline-metrics\s*(?<block>.*?)\s*-->')
    if (-not $match.Success) {
        return $null
    }

    return $match.Groups['block'].Value.Trim()
}

function Get-FBDMetricScalar {
    param(
        [Parameter(Mandatory)][string]$MetricsBlock,
        [Parameter(Mandatory)][string]$Name
    )

    $pattern = '(?m)^\s*' + [regex]::Escape($Name) + '\s*:\s*(?<value>.+?)\s*$'
    $match = [regex]::Match($MetricsBlock, $pattern)
    if (-not $match.Success) {
        return $null
    }

    return $match.Groups['value'].Value.Trim()
}

function Get-FBDMetricBoolean {
    param(
        [Parameter(Mandatory)][string]$MetricsBlock,
        [Parameter(Mandatory)][string]$Name
    )

    $rawValue = Get-FBDMetricScalar -MetricsBlock $MetricsBlock -Name $Name
    if ($null -eq $rawValue) {
        return $null
    }

    switch ($rawValue.ToLowerInvariant()) {
        'true' { return $true }
        'false' { return $false }
        default { return $null }
    }
}

function Get-FBDSectionBlock {
    param(
        [Parameter(Mandatory)][string]$MetricsBlock,
        [Parameter(Mandatory)][string]$SectionName
    )

    $pattern = '(?ms)^\s*' + [regex]::Escape($SectionName) + '\s*:\s*(?<section>(?:\r?\n[ \t]{2,}.*)*)'
    $match = [regex]::Match($MetricsBlock, $pattern)
    if (-not $match.Success) {
        return ''
    }

    return $match.Groups['section'].Value
}

function Test-FBDSectionBoolean {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$SectionBlock,
        [Parameter(Mandatory)][string]$Name
    )

    if ([string]::IsNullOrWhiteSpace($SectionBlock)) {
        return $false
    }

    $pattern = '(?m)^[ \t]+' + [regex]::Escape($Name) + '\s*:\s*true\s*$'
    return [regex]::IsMatch($SectionBlock, $pattern)
}

function Test-FBDReviewFindingDetail {
    param([Parameter(Mandatory)][string]$MetricsBlock)

    return (
        [regex]::IsMatch($MetricsBlock, '(?m)^\s*findings\s*:') -and
        [regex]::IsMatch($MetricsBlock, '(?m)^\s*defense_verdict\s*:') -and
        [regex]::IsMatch($MetricsBlock, '(?m)^\s*judge_ruling\s*:')
    )
}

function Get-FBDExistingCredits {
    # D9 additive-merge: parse the credits: section from the pipeline-metrics block.
    # Returns an ordered hashtable of credit identity → credit-row for all rows already present.
    # Callers skip back-derivation for any port found here and preserve the row as-is.
    param([Parameter(Mandatory)][AllowEmptyString()][string]$MetricsBlock)

    $result = [ordered]@{}

    if ([string]::IsNullOrWhiteSpace($MetricsBlock)) {
        return $result
    }

    # Extract the indented block that follows "credits:"
    $creditsMatch = [regex]::Match($MetricsBlock, '(?ms)^\s*credits\s*:\s*\r?\n(?<section>(?:[ \t]{2,}[^\r\n]*\r?\n?)*)')
    if (-not $creditsMatch.Success) {
        return $result
    }

    $section = $creditsMatch.Groups['section'].Value

    # Split into individual items on "  - port:" boundaries; each item starts with the port value
    $itemParts = [regex]::Split($section, '(?m)^[ \t]{2}-[ \t]+port[ \t]*:[ \t]*')

    foreach ($part in $itemParts) {
        if ([string]::IsNullOrWhiteSpace($part)) { continue }

        $lines = ($part -split '\r?\n')
        $port = $lines[0].Trim()
        if ([string]::IsNullOrWhiteSpace($port)) { continue }

        $statusMatch   = [regex]::Match($part, '(?m)^\s*status\s*:\s*(\S+)')
        $blockKindMatch = [regex]::Match($part, '(?m)^\s*block_kind\s*:\s*(\S+)')
        $terminalStepMatch = [regex]::Match($part, '(?m)^\s*terminal-step-id\s*:\s*(-?\d+)\s*$')
        $evidenceMatchQ = [regex]::Match($part, '(?m)^\s*evidence\s*:\s*"((?:[^"\\]|\\.)*)"\s*$')
        $evidenceMatchU = [regex]::Match($part, '(?m)^\s*evidence\s*:\s*(.+)')

        if (-not $statusMatch.Success) { continue }

        $evidence = if ($evidenceMatchQ.Success) {
            $evidenceMatchQ.Groups[1].Value -replace '\\"', '"' -replace '\\\\', '\'
        } elseif ($evidenceMatchU.Success) {
            $evidenceMatchU.Groups[1].Value.Trim()
        } else { '' }

        $credit = [ordered]@{
            port     = $port
            status   = $statusMatch.Groups[1].Value.Trim()
        }
        if ($blockKindMatch.Success) {
            $credit['block_kind'] = $blockKindMatch.Groups[1].Value.Trim()
        }
        $terminalStepId = 0
        if ($terminalStepMatch.Success) {
            $terminalStepId = [int]$terminalStepMatch.Groups[1].Value.Trim()
            $credit['terminal-step-id'] = $terminalStepId
        }
        $credit['evidence'] = $evidence

        $hasSyntheticBackfill = [regex]::IsMatch($part, '(?m)^\s*synthetic-backfill\s*:')
        if ($hasSyntheticBackfill) {
            $backfilledAtMatch = [regex]::Match($part, '(?m)^\s*backfilled_at\s*:\s*(\S+)')
            $origMergedAtMatch = [regex]::Match($part, '(?m)^\s*original_pr_merged_at\s*:\s*(\S+)')
            $credit['mode'] = [ordered]@{
                'synthetic-backfill' = [ordered]@{
                    backfilled_at         = if ($backfilledAtMatch.Success) { $backfilledAtMatch.Groups[1].Value.Trim() } else { $null }
                    original_pr_merged_at = if ($origMergedAtMatch.Success) { $origMergedAtMatch.Groups[1].Value.Trim() } else { $null }
                }
            }
        }

        $identityStep = if ($terminalStepId -gt 0) { $terminalStepId } else { 0 }
        $identityKey = if ($identityStep -gt 0) { "$port|$identityStep" } else { $port }
        if (-not $result.Contains($identityKey)) {
            $result[$identityKey] = $credit
        }
    }

    return $result
}

function Get-FBDGitHubJson {
    param(
        [Parameter(Mandatory)][string]$GhCliPath,
        [Parameter(Mandatory)][string[]]$Arguments,
        [Parameter(Mandatory)][string]$Context
    )

    $stderrPath = [System.IO.Path]::GetTempFileName()
    try {
        $output = & $GhCliPath @Arguments 2> $stderrPath
        $commandSucceeded = $?
        $exitCode = $LASTEXITCODE
        $rawError = if (Test-Path -LiteralPath $stderrPath) { [string](Get-Content -Raw -Path $stderrPath -ErrorAction SilentlyContinue) } else { '' }
    }
    finally {
        Remove-Item -Force -LiteralPath $stderrPath -ErrorAction SilentlyContinue
    }

    $rawOutput = (@($output) | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine

    if ($null -eq $exitCode) {
        $exitCode = if ($commandSucceeded) { 0 } else { 1 }
    }
    elseif (-not $commandSucceeded -and [int]$exitCode -eq 0) {
        $exitCode = 1
    }

    if ($exitCode -ne 0) {
        $messageParts = @()
        if (-not [string]::IsNullOrWhiteSpace($rawError)) {
            $messageParts += $rawError.Trim()
        }
        if (-not [string]::IsNullOrWhiteSpace($rawOutput)) {
            $messageParts += $rawOutput.Trim()
        }

        $message = ($messageParts -join [Environment]::NewLine).Trim()
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

function Get-FBDCachePath {
    param(
        [Parameter(Mandatory)][string]$CacheDir,
        [Parameter(Mandatory)][int]$PrNumber
    )

    return (Join-Path -Path $CacheDir -ChildPath ("frame-pr-{0}.json" -f $PrNumber))
}

function Get-FBDPrPayload {
    param(
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][int]$PrNumber,
        [Parameter(Mandatory)][string]$GhCliPath,
        [string]$CacheDir,
        [switch]$NoCache
    )

    $cachePath = $null
    if (-not $NoCache.IsPresent -and -not [string]::IsNullOrWhiteSpace($CacheDir)) {
        if (-not (Test-Path -LiteralPath $CacheDir)) {
            New-Item -ItemType Directory -Path $CacheDir -Force | Out-Null
        }

        $cachePath = Get-FBDCachePath -CacheDir $CacheDir -PrNumber $PrNumber
        if (Test-Path -LiteralPath $cachePath) {
            return (Get-Content -Raw -Path $cachePath | ConvertFrom-Json -AsHashtable)
        }
    }

    $null = Get-FBDGitHubJson -GhCliPath $GhCliPath -Arguments @('repo', 'view', $Repo, '--json', 'nameWithOwner') -Context "gh repo view $Repo"
    $payload = Get-FBDGitHubJson -GhCliPath $GhCliPath -Arguments @('pr', 'view', $PrNumber, '--repo', $Repo, '--json', 'number,mergedAt,title,body,closingIssuesReferences,commits') -Context "gh pr view $PrNumber"

    if ($cachePath) {
        $payload | ConvertTo-Json -Depth 20 | Set-Content -Path $cachePath -Encoding UTF8
    }

    return $payload
}

function Get-FBDBodyIssueReference {
    param([string]$Body)

    if ([string]::IsNullOrWhiteSpace($Body)) {
        return $null
    }

    $match = [regex]::Match($Body, '(?im)\b(?:closes?|closed|fix(?:es|ed)?|resolves?|resolved|refs?|related to)\s+#(?<number>\d+)')
    if (-not $match.Success) {
        return $null
    }

    return [int]$match.Groups['number'].Value
}

function Get-FBDCommitMessages {
    param($PrPayload)

    $messages = [System.Collections.Generic.List[string]]::new()
    $commitsValue = Get-FBDPropertyValue -InputObject $PrPayload -Name 'commits'
    if ($null -eq $commitsValue) {
        return $messages.ToArray()
    }

    $commitEntries = @()
    $commitNodes = Get-FBDPropertyValue -InputObject $commitsValue -Name 'nodes'
    if ($null -ne $commitNodes) {
        $commitEntries += Get-FBDArray $commitNodes
    }
    else {
        $commitEntries += Get-FBDArray $commitsValue
    }

    foreach ($entry in $commitEntries) {
        $candidateObjects = @($entry)
        $nestedCommit = Get-FBDPropertyValue -InputObject $entry -Name 'commit'
        if ($null -ne $nestedCommit) {
            $candidateObjects += $nestedCommit
        }

        foreach ($candidate in $candidateObjects) {
            foreach ($propertyName in @('message', 'messageHeadline', 'messageBody')) {
                $message = Get-FBDPropertyValue -InputObject $candidate -Name $propertyName
                if (-not [string]::IsNullOrWhiteSpace($message)) {
                    $messages.Add([string]$message)
                }
            }
        }
    }

    return $messages.ToArray()
}

function Resolve-FBDLinkedIssue {
    param($PrPayload)

    $closingIssues = Get-FBDArray (Get-FBDPropertyValue -InputObject $PrPayload -Name 'closingIssuesReferences')
    foreach ($issue in $closingIssues) {
        $number = Get-FBDPropertyValue -InputObject $issue -Name 'number'
        if ($null -ne $number) {
            return [ordered]@{
                Number = [int]$number
                Source = 'closingIssuesReferences'
            }
        }
    }

    $bodyIssue = Get-FBDBodyIssueReference -Body ([string](Get-FBDPropertyValue -InputObject $PrPayload -Name 'body'))
    if ($null -ne $bodyIssue) {
        return [ordered]@{
            Number = [int]$bodyIssue
            Source = 'pr-body'
        }
    }

    foreach ($message in (Get-FBDCommitMessages -PrPayload $PrPayload)) {
        $commitIssue = Get-FBDBodyIssueReference -Body $message
        if ($null -ne $commitIssue) {
            return [ordered]@{
                Number = [int]$commitIssue
                Source = 'commit-message'
            }
        }
    }

    return $null
}

function Get-FBDLinkedIssueSourceLabel {
    param($LinkedIssue)

    if ($null -eq $LinkedIssue) {
        return 'unknown linked-issue source'
    }

    $source = [string](Get-FBDPropertyValue -InputObject $LinkedIssue -Name 'Source')
    switch ($source) {
        'closingIssuesReferences' { return 'closingIssuesReferences' }
        'pr-body' { return 'PR body fallback' }
        'commit-message' { return 'commit-message fallback' }
        default { return 'unknown linked-issue source' }
    }
}

function Get-FBDPortOrder {
    param([Parameter(Mandatory)][string]$PortsDir)

    $expectedOrder = @(
        'experience',
        'design',
        'plan',
        'implement-code',
        'implement-test',
        'implement-refactor',
        'implement-docs',
        'review',
        'ce-gate-cli',
        'ce-gate-browser',
        'ce-gate-canvas',
        'ce-gate-api',
        'release-hygiene',
        'post-pr',
        'post-fix-review',
        'process-review',
        'process-retrospective'
    )

    if (-not (Test-Path -LiteralPath $PortsDir)) {
        throw "PortsDir not found: $PortsDir"
    }

    $discoveredPorts = @(Get-ChildItem -Path $PortsDir -Filter '*.yaml' -File | ForEach-Object { $_.BaseName })
    $orderedPorts = [System.Collections.Generic.List[string]]::new()

    foreach ($port in $expectedOrder) {
        if ($port -in $discoveredPorts) {
            $orderedPorts.Add($port)
        }
    }

    foreach ($extraPort in ($discoveredPorts | Where-Object { $_ -notin $expectedOrder } | Sort-Object)) {
        $orderedPorts.Add($extraPort)
    }

    return $orderedPorts.ToArray()
}

function New-FBDCredit {
    param(
        [Parameter(Mandatory)][string]$Port,
        [Parameter(Mandatory)][string]$Status,
        [Parameter(Mandatory)][string]$Evidence
    )

    return [ordered]@{
        port     = $Port
        status   = $Status
        evidence = $Evidence
    }
}

function New-FBDIntegrityCheck {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Status,
        [Parameter(Mandatory)][string]$Evidence
    )

    return [ordered]@{
        name     = $Name
        status   = $Status
        evidence = $Evidence
    }
}

function Get-FBDPortCredit {
    param(
        [Parameter(Mandatory)][string]$Port,
        [Parameter(Mandatory)][string]$MetricsVersion,
        $LinkedIssue,
        [Parameter(Mandatory)][string]$MetricsBlock,
        [switch]$IsMerged
    )

    $issueNumber = $null
    if ($LinkedIssue) {
        $issueNumber = [int]$LinkedIssue.Number
    }
    $issueSourceLabel = Get-FBDLinkedIssueSourceLabel -LinkedIssue $LinkedIssue

    switch ($Port) {
        'experience' {
            switch ($MetricsVersion) {
                '1' {
                    if ($issueNumber) {
                        return New-FBDCredit -Port $Port -Status 'passed' -Evidence ("Issue #{0} was resolved from {1} for this v1-era PR." -f $issueNumber, $issueSourceLabel)
                    }

                    return New-FBDCredit -Port $Port -Status 'inconclusive' -Evidence 'The v1 fixture does not resolve a linked issue for this PR.'
                }
                '2' {
                    if ($issueNumber) {
                        return New-FBDCredit -Port $Port -Status 'passed' -Evidence ("Issue #{0} was resolved from {1} for this v2-era PR." -f $issueNumber, $issueSourceLabel)
                    }

                    return New-FBDCredit -Port $Port -Status 'inconclusive' -Evidence 'The v2 fixture does not resolve a linked issue for this PR.'
                }
                '3' {
                    if ($issueNumber) {
                        return New-FBDCredit -Port $Port -Status 'passed' -Evidence ("Linked issue #{0} resolved from {1} for a v3-era PR." -f $issueNumber, $issueSourceLabel)
                    }

                    return New-FBDCredit -Port $Port -Status 'inconclusive' -Evidence 'The v3 fixture does not resolve a linked issue for this PR.'
                }
                default {
                    if ($issueNumber) {
                        return New-FBDCredit -Port $Port -Status 'passed' -Evidence ("Linked issue #{0} resolved from {1} for a post-thin/fat pipeline PR." -f $issueNumber, $issueSourceLabel)
                    }

                    return New-FBDCredit -Port $Port -Status 'inconclusive' -Evidence 'The historical fixture does not resolve a linked issue for this PR.'
                }
            }
        }
        'design' {
            switch ($MetricsVersion) {
                '1' {
                    return New-FBDCredit -Port $Port -Status 'inconclusive' -Evidence 'The v1 fixture links an issue, but it does not preserve enough detail to distinguish design completion from generic issue linkage.'
                }
                '2' {
                    if ($issueNumber) {
                        return New-FBDCredit -Port $Port -Status 'inconclusive' -Evidence ("Linked issue #{0} was resolved, but issue linkage alone does not confirm design completion because the audit does not read issue-body markers or completion state." -f $issueNumber)
                    }

                    return New-FBDCredit -Port $Port -Status 'inconclusive' -Evidence 'The v2 fixture does not preserve enough detail to confirm design completion.'
                }
                '3' {
                    if ($issueNumber) {
                        return New-FBDCredit -Port $Port -Status 'inconclusive' -Evidence ("Linked issue #{0} was resolved, but issue linkage alone does not confirm design completion because the audit does not read issue-body markers or completion state." -f $issueNumber)
                    }

                    return New-FBDCredit -Port $Port -Status 'inconclusive' -Evidence 'The v3 fixture does not preserve enough detail to confirm design completion.'
                }
                default {
                    if ($issueNumber) {
                        return New-FBDCredit -Port $Port -Status 'inconclusive' -Evidence ("Linked issue #{0} was resolved, but issue linkage alone does not confirm design completion because the audit does not read issue-body markers or completion state." -f $issueNumber)
                    }

                    return New-FBDCredit -Port $Port -Status 'inconclusive' -Evidence 'The fixture does not preserve enough detail to confirm design completion.'
                }
            }
        }
        'plan' {
            switch ($MetricsVersion) {
                '1' {
                    return New-FBDCredit -Port $Port -Status 'inconclusive' -Evidence 'The v1 fixture links an issue, but it does not preserve enough detail to distinguish plan completion from generic issue linkage.'
                }
                '2' {
                    if ($issueNumber) {
                        return New-FBDCredit -Port $Port -Status 'inconclusive' -Evidence ("Linked issue #{0} was resolved, but issue linkage alone does not confirm plan completion because the audit does not read issue-body markers or completion state." -f $issueNumber)
                    }

                    return New-FBDCredit -Port $Port -Status 'inconclusive' -Evidence 'The v2 fixture does not preserve enough detail to confirm plan completion.'
                }
                '3' {
                    if ($issueNumber) {
                        return New-FBDCredit -Port $Port -Status 'inconclusive' -Evidence ("Linked issue #{0} was resolved, but issue linkage alone does not confirm plan completion because the audit does not read issue-body markers or completion state." -f $issueNumber)
                    }

                    return New-FBDCredit -Port $Port -Status 'inconclusive' -Evidence 'The v3 fixture does not preserve enough detail to confirm plan completion.'
                }
                default {
                    if ($issueNumber) {
                        return New-FBDCredit -Port $Port -Status 'inconclusive' -Evidence ("Linked issue #{0} was resolved, but issue linkage alone does not confirm plan completion because the audit does not read issue-body markers or completion state." -f $issueNumber)
                    }

                    return New-FBDCredit -Port $Port -Status 'inconclusive' -Evidence 'The fixture does not preserve enough detail to confirm plan completion.'
                }
            }
        }
        'implement-code' {
            # D5 (issue #442): implement-* uses skipped (not inconclusive) when no validator evidence exists in the historical record.
            switch ($MetricsVersion) {
                '1' { return New-FBDCredit -Port $Port -Status 'skipped' -Evidence 'The v1 metrics block does not encode implementation-lane detail; no validator evidence to credit.' }
                '2' { return New-FBDCredit -Port $Port -Status 'skipped' -Evidence 'The v2 metrics block does not encode implementation-lane detail; no validator evidence to credit.' }
                '3' { return New-FBDCredit -Port $Port -Status 'skipped' -Evidence 'The v3 metrics block does not expose which implementation specialist lanes ran; no validator evidence to credit.' }
                default { return New-FBDCredit -Port $Port -Status 'skipped' -Evidence 'The historical metrics block does not expose which implementation specialist lanes ran; no validator evidence to credit.' }
            }
        }
        'implement-test' {
            # D5 (issue #442): implement-* uses skipped (not inconclusive) when no validator evidence exists in the historical record.
            switch ($MetricsVersion) {
                '1' { return New-FBDCredit -Port $Port -Status 'skipped' -Evidence 'The v1 metrics block does not encode test-lane detail; no validator evidence to credit.' }
                '2' { return New-FBDCredit -Port $Port -Status 'skipped' -Evidence 'The v2 metrics block does not encode test-lane detail; no validator evidence to credit.' }
                '3' { return New-FBDCredit -Port $Port -Status 'skipped' -Evidence 'The v3 metrics block does not expose whether test-writing ran as a distinct lane; no validator evidence to credit.' }
                default { return New-FBDCredit -Port $Port -Status 'skipped' -Evidence 'The historical metrics block does not expose whether test-writing ran as a distinct lane; no validator evidence to credit.' }
            }
        }
        'implement-refactor' {
            # D5 (issue #442): implement-* uses skipped (not inconclusive) when no validator evidence exists in the historical record.
            switch ($MetricsVersion) {
                '1' { return New-FBDCredit -Port $Port -Status 'skipped' -Evidence 'The v1 metrics block does not encode refactor-lane detail; no validator evidence to credit.' }
                '2' { return New-FBDCredit -Port $Port -Status 'skipped' -Evidence 'The v2 metrics block does not encode refactor-lane detail; no validator evidence to credit.' }
                '3' { return New-FBDCredit -Port $Port -Status 'skipped' -Evidence 'No adapter-level refactor evidence is encoded in the fixture body; no validator evidence to credit.' }
                default { return New-FBDCredit -Port $Port -Status 'skipped' -Evidence 'No adapter-level refactor evidence is encoded in the historical metrics block; no validator evidence to credit.' }
            }
        }
        'implement-docs' {
            # D5 (issue #442): implement-* uses skipped (not inconclusive) when no validator evidence exists in the historical record.
            switch ($MetricsVersion) {
                '1' { return New-FBDCredit -Port $Port -Status 'skipped' -Evidence 'The v1 metrics block does not encode documentation-lane detail; no validator evidence to credit.' }
                '2' { return New-FBDCredit -Port $Port -Status 'skipped' -Evidence 'The v2 metrics block does not encode documentation-lane detail; no validator evidence to credit.' }
                '3' { return New-FBDCredit -Port $Port -Status 'skipped' -Evidence 'No adapter-level documentation evidence is encoded in the fixture body; no validator evidence to credit.' }
                default { return New-FBDCredit -Port $Port -Status 'skipped' -Evidence 'No adapter-level documentation evidence is encoded in the historical metrics block; no validator evidence to credit.' }
            }
        }
        'review' {
            switch ($MetricsVersion) {
                '1' {
                    $hasProsecutionCount = $null -ne (Get-FBDMetricScalar -MetricsBlock $MetricsBlock -Name 'prosecution_findings')
                    $hasJudgeAccepted = $null -ne (Get-FBDMetricScalar -MetricsBlock $MetricsBlock -Name 'judge_accepted')
                    $hasJudgeRejected = $null -ne (Get-FBDMetricScalar -MetricsBlock $MetricsBlock -Name 'judge_rejected')
                    if ($hasProsecutionCount -and $hasJudgeAccepted -and $hasJudgeRejected) {
                        return New-FBDCredit -Port $Port -Status 'passed' -Evidence 'The v1 metrics block records prosecution and judge counts, which is sufficient to credit review.'
                    }

                    return New-FBDCredit -Port $Port -Status 'inconclusive' -Evidence 'The v1 metrics block does not encode enough review detail to credit review.'
                }
                '2' {
                    if ((Get-FBDMetricScalar -MetricsBlock $MetricsBlock -Name 'prosecution_findings') -and (Get-FBDMetricScalar -MetricsBlock $MetricsBlock -Name 'judge_accepted') -and (Test-FBDReviewFindingDetail -MetricsBlock $MetricsBlock)) {
                        return New-FBDCredit -Port $Port -Status 'passed' -Evidence 'Prosecution and judge counts are present, and the finding includes defense and judge detail.'
                    }

                    return New-FBDCredit -Port $Port -Status 'inconclusive' -Evidence 'The v2 metrics block does not encode enough review detail to credit review.'
                }
                '3' {
                    $stagesRun = Get-FBDSectionBlock -MetricsBlock $MetricsBlock -SectionName 'stages_run'
                    if ((Test-FBDSectionBoolean -SectionBlock $stagesRun -Name 'prosecution') -and (Test-FBDSectionBoolean -SectionBlock $stagesRun -Name 'defense') -and (Test-FBDSectionBoolean -SectionBlock $stagesRun -Name 'judgment')) {
                        return New-FBDCredit -Port $Port -Status 'passed' -Evidence 'metrics_version 3 block records prosecution, defense, and judgment as completed.'
                    }

                    return New-FBDCredit -Port $Port -Status 'inconclusive' -Evidence 'The v3 metrics block does not encode enough review detail to credit review.'
                }
                default {
                    $stagesRun = Get-FBDSectionBlock -MetricsBlock $MetricsBlock -SectionName 'stages_run'
                    if ((Test-FBDSectionBoolean -SectionBlock $stagesRun -Name 'prosecution') -and (Test-FBDSectionBoolean -SectionBlock $stagesRun -Name 'defense') -and (Test-FBDSectionBoolean -SectionBlock $stagesRun -Name 'judgment')) {
                        return New-FBDCredit -Port $Port -Status 'passed' -Evidence 'metrics_version 4 block records prosecution, defense, and judgment as completed.'
                    }

                    return New-FBDCredit -Port $Port -Status 'inconclusive' -Evidence 'The v4 metrics block does not encode enough review detail to credit review.'
                }
            }
        }
        'ce-gate-cli' {
            switch ($MetricsVersion) {
                '1' { return New-FBDCredit -Port $Port -Status 'inconclusive' -Evidence 'The v1 fixture predates CE surface tagging, so the surface cannot be derived.' }
                '2' { return New-FBDCredit -Port $Port -Status 'inconclusive' -Evidence 'CE Gate passed, but the v2 fixture does not identify the audited surface.' }
                '3' { return New-FBDCredit -Port $Port -Status 'inconclusive' -Evidence 'CE Gate passed, but the historical fixture does not identify the audited surface.' }
                default { return New-FBDCredit -Port $Port -Status 'inconclusive' -Evidence 'CE Gate passed, but the PR body does not identify the surface as CLI.' }
            }
        }
        'ce-gate-browser' {
            switch ($MetricsVersion) {
                '1' { return New-FBDCredit -Port $Port -Status 'inconclusive' -Evidence 'The v1 fixture predates CE surface tagging, so the surface cannot be derived.' }
                '2' { return New-FBDCredit -Port $Port -Status 'inconclusive' -Evidence 'CE Gate passed, but the v2 fixture does not identify the audited surface.' }
                '3' { return New-FBDCredit -Port $Port -Status 'inconclusive' -Evidence 'CE Gate passed, but the historical fixture does not identify the audited surface.' }
                default { return New-FBDCredit -Port $Port -Status 'inconclusive' -Evidence 'CE Gate passed, but the PR body does not identify the surface as browser.' }
            }
        }
        'ce-gate-canvas' {
            switch ($MetricsVersion) {
                '1' { return New-FBDCredit -Port $Port -Status 'inconclusive' -Evidence 'The v1 fixture predates CE surface tagging, so the surface cannot be derived.' }
                '2' { return New-FBDCredit -Port $Port -Status 'inconclusive' -Evidence 'CE Gate passed, but the v2 fixture does not identify the audited surface.' }
                '3' { return New-FBDCredit -Port $Port -Status 'inconclusive' -Evidence 'CE Gate passed, but the historical fixture does not identify the audited surface.' }
                default { return New-FBDCredit -Port $Port -Status 'inconclusive' -Evidence 'CE Gate passed, but the PR body does not identify the surface as canvas.' }
            }
        }
        'ce-gate-api' {
            switch ($MetricsVersion) {
                '1' { return New-FBDCredit -Port $Port -Status 'inconclusive' -Evidence 'The v1 fixture predates CE surface tagging, so the surface cannot be derived.' }
                '2' { return New-FBDCredit -Port $Port -Status 'inconclusive' -Evidence 'CE Gate passed, but the v2 fixture does not identify the audited surface.' }
                '3' { return New-FBDCredit -Port $Port -Status 'inconclusive' -Evidence 'CE Gate passed, but the historical fixture does not identify the audited surface.' }
                default { return New-FBDCredit -Port $Port -Status 'inconclusive' -Evidence 'CE Gate passed, but the PR body does not identify the surface as API.' }
            }
        }
        'release-hygiene' {
            switch ($MetricsVersion) {
                '1' { return New-FBDCredit -Port $Port -Status 'inconclusive' -Evidence 'This PR predates the current release-hygiene audit path, so trigger evidence is not derivable from the fixture alone.' }
                '2' { return New-FBDCredit -Port $Port -Status 'inconclusive' -Evidence 'This PR predates the current release-hygiene audit path, so trigger evidence is not derivable from the fixture alone.' }
                default { return New-FBDCredit -Port $Port -Status 'not-applicable' -Evidence 'No release-hygiene trigger is implied by the fixture summary or metrics block.' }
            }
        }
        'post-pr' {
            # D5 (issue #442): post-pr uses skipped (not inconclusive) when no checklist evidence exists in the historical record.
            if ($IsMerged.IsPresent) {
                return New-FBDCredit -Port $Port -Status 'skipped' -Evidence 'The PR is merged, but merge state alone does not confirm post-PR cleanup and archival completion; no checklist evidence available.'
            }

            return New-FBDCredit -Port $Port -Status 'skipped' -Evidence 'The fixture does not preserve enough detail to confirm post-PR cleanup and archival completion; no checklist evidence available.'
        }
        'post-fix-review' {
            $postfixTriggered = Get-FBDMetricBoolean -MetricsBlock $MetricsBlock -Name 'postfix_triggered'
            if ($postfixTriggered -eq $true) {
                return New-FBDCredit -Port $Port -Status 'passed' -Evidence 'postfix_triggered is true, so a targeted post-fix review path applied.'
            }

            switch ($MetricsVersion) {
                '1' { return New-FBDCredit -Port $Port -Status 'not-applicable' -Evidence 'No post-fix review path is recorded, so the trigger is treated as absent.' }
                '2' { return New-FBDCredit -Port $Port -Status 'not-applicable' -Evidence 'No post-fix review path is recorded, so the trigger is treated as absent.' }
                default { return New-FBDCredit -Port $Port -Status 'not-applicable' -Evidence 'postfix_triggered is false, so no targeted post-fix review path applied.' }
            }
        }
        'process-review' {
            return New-FBDCredit -Port $Port -Status 'not-applicable' -Evidence 'The fixture encodes no systemic-gap trigger for process-review follow-up.'
        }
        'process-retrospective' {
            return New-FBDCredit -Port $Port -Status 'inconclusive' -Evidence 'Port pending decision per umbrella sub-issue #11.'
        }
        default {
            return New-FBDCredit -Port $Port -Status 'inconclusive' -Evidence 'No historical back-derivation rule exists for this port in the Step 3 audit-only implementation.'
        }
    }
}

function Get-FBDLinkedIssueIntegrityCheck {
    param($LinkedIssue)

    if ($null -eq $LinkedIssue) {
        return New-FBDIntegrityCheck -Name 'linked-issue-resolution' -Status 'inconclusive' -Evidence 'No linked issue could be resolved from closingIssuesReferences, PR body references, or commit-message fallback.'
    }

    switch ([string]$LinkedIssue.Source) {
        'closingIssuesReferences' {
            return New-FBDIntegrityCheck -Name 'linked-issue-resolution' -Status 'passed' -Evidence ("closingIssuesReferences resolved issue #{0} directly." -f ([int]$LinkedIssue.Number))
        }
        'pr-body' {
            return New-FBDIntegrityCheck -Name 'linked-issue-resolution' -Status 'passed' -Evidence ("PR body fallback resolved issue #{0} after closingIssuesReferences was absent." -f ([int]$LinkedIssue.Number))
        }
        'commit-message' {
            return New-FBDIntegrityCheck -Name 'linked-issue-resolution' -Status 'passed' -Evidence ("Commit-message fallback resolved issue #{0} after closingIssuesReferences and PR body references were absent." -f ([int]$LinkedIssue.Number))
        }
        default {
            return New-FBDIntegrityCheck -Name 'linked-issue-resolution' -Status 'inconclusive' -Evidence 'Linked issue resolution used an unknown source.'
        }
    }
}

function Get-FBDMetricsVersionIntegrityCheck {
    param([Parameter(Mandatory)][string]$MetricsVersion)

    if ($MetricsVersion -eq '4') {
        return New-FBDIntegrityCheck -Name 'metrics-version-input' -Status 'passed' -Evidence 'metrics_version 4 input was parsed without fallback.'
    }

    return New-FBDIntegrityCheck -Name 'metrics-version-input' -Status 'passed' -Evidence ("metrics_version {0} input was parsed and lifted into the v4 audit surface." -f $MetricsVersion)
}

function Get-FBDAuditSurface {
    param(
        [Parameter(Mandatory)]$PrPayload,
        [Parameter(Mandatory)][string]$MetricsVersion,
        $LinkedIssue,
        [Parameter(Mandatory)][string[]]$Ports,
        [Parameter(Mandatory)][string]$MetricsBlock,
        [string]$BackfilledAt = ''
    )

    $mergedAtValue = [string](Get-FBDPropertyValue -InputObject $PrPayload -Name 'mergedAt')
    $isMerged = -not [string]::IsNullOrWhiteSpace($mergedAtValue)

    # Resolve backfill timestamp (allow injection for deterministic tests)
    $resolvedBackfilledAt = if ([string]::IsNullOrWhiteSpace($BackfilledAt)) {
        [System.DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
    } else { $BackfilledAt }

    # Normalize mergedAt to ISO-8601 string (gh CLI may return DateTime or string)
    $rawMergedAt = Get-FBDPropertyValue -InputObject $PrPayload -Name 'mergedAt'
    $originalPrMergedAt = if ($null -ne $rawMergedAt -and -not [string]::IsNullOrWhiteSpace([string]$rawMergedAt)) {
        if ($rawMergedAt -is [System.DateTime]) {
            $rawMergedAt.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        } else { [string]$rawMergedAt }
    } else { $null }

    # D9 additive-merge: parse rows already present in the v4 credits block.
    # Present rows are preserved as-is (no synthetic-backfill); absent ports are back-derived.
    $existingCredits = Get-FBDExistingCredits -MetricsBlock $MetricsBlock

    $credits = [System.Collections.Generic.List[object]]::new()
    foreach ($port in $Ports) {
        $existingRows = @($existingCredits.Values | Where-Object { [string](Get-FBDPropertyValue -InputObject $_ -Name 'port') -eq $port })
        if ($existingRows.Count -gt 0) {
            foreach ($existingRow in $existingRows) {
                $credits.Add($existingRow)
            }
        } else {
            # Port absent — back-derive and decorate with mode.synthetic-backfill
            $derived = Get-FBDPortCredit -Port $port -MetricsVersion $MetricsVersion -LinkedIssue $LinkedIssue -MetricsBlock $MetricsBlock -IsMerged:$isMerged
            $decorated = [ordered]@{}
            foreach ($key in $derived.Keys) { $decorated[$key] = $derived[$key] }
            $decorated['mode'] = [ordered]@{
                'synthetic-backfill' = [ordered]@{
                    backfilled_at         = $resolvedBackfilledAt
                    original_pr_merged_at = $originalPrMergedAt
                }
            }
            $credits.Add($decorated)
        }
    }

    $integrityChecks = @(
        (Get-FBDLinkedIssueIntegrityCheck -LinkedIssue $LinkedIssue),
        (Get-FBDMetricsVersionIntegrityCheck -MetricsVersion $MetricsVersion),
        (New-FBDIntegrityCheck -Name 'adapter-selection-evidence' -Status 'inconclusive' -Evidence 'Historical pipeline-metrics do not encode enough detail to classify every implementation and CE surface port.')
    )

    return [ordered]@{
        frame_version    = 1
        credits          = $credits.ToArray()
        integrity_checks = $integrityChecks
    }
}

function ConvertTo-FBDAuditJson {
    param([Parameter(Mandatory)]$AuditSurface)

    return ($AuditSurface | ConvertTo-Json -Depth 10)
}

function ConvertTo-FBDYamlQuotedString {
    param([Parameter(Mandatory)][string]$Value)

    return ('"{0}"' -f (($Value -replace '\\', '\\\\') -replace '"', '\\"'))
}

function ConvertTo-FBDAuditYaml {
    param([Parameter(Mandatory)]$AuditSurface)

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add(("frame_version: {0}" -f [int]$AuditSurface.frame_version))
    $lines.Add('credits:')
    foreach ($credit in $AuditSurface.credits) {
        $lines.Add(("  - port: {0}" -f $credit.port))
        $lines.Add(("    status: {0}" -f $credit.status))
        if ($credit.Contains('block_kind') -and -not [string]::IsNullOrWhiteSpace([string]$credit.block_kind)) {
            $lines.Add(("    block_kind: {0}" -f $credit.block_kind))
        }
        $lines.Add(("    evidence: {0}" -f (ConvertTo-FBDYamlQuotedString -Value $credit.evidence)))
        if ($credit.Contains('mode') -and $null -ne $credit.mode -and $credit.mode.Contains('synthetic-backfill')) {
            $sb = $credit.mode.'synthetic-backfill'
            $lines.Add('    mode:')
            $lines.Add('      synthetic-backfill:')
            $lines.Add(("        backfilled_at: {0}" -f $sb.backfilled_at))
            $origMergedAt = if ($null -ne $sb.original_pr_merged_at) {
                if ($sb.original_pr_merged_at -is [System.DateTime]) {
                    $sb.original_pr_merged_at.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
                } else { [string]$sb.original_pr_merged_at }
            } else { 'null' }
            $lines.Add(("        original_pr_merged_at: {0}" -f $origMergedAt))
        }
    }

    $lines.Add('integrity_checks:')
    foreach ($integrityCheck in $AuditSurface.integrity_checks) {
        $lines.Add(("  - name: {0}" -f $integrityCheck.name))
        $lines.Add(("    status: {0}" -f $integrityCheck.status))
        $lines.Add(("    evidence: {0}" -f (ConvertTo-FBDYamlQuotedString -Value $integrityCheck.evidence)))
    }

    return ($lines -join [Environment]::NewLine)
}

function ConvertTo-FBDAuditText {
    param([Parameter(Mandatory)]$AuditSurface)

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add(("frame_version: {0}" -f [int]$AuditSurface.frame_version))
    $lines.Add('credits:')
    foreach ($credit in $AuditSurface.credits) {
        $lines.Add(("- {0}: {1} - {2}" -f $credit.port, $credit.status, $credit.evidence))
    }

    $lines.Add('integrity_checks:')
    foreach ($integrityCheck in $AuditSurface.integrity_checks) {
        $lines.Add(("- {0}: {1} - {2}" -f $integrityCheck.name, $integrityCheck.status, $integrityCheck.evidence))
    }

    return ($lines -join [Environment]::NewLine)
}

function Invoke-FrameBackDerive {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][int]$PrNumber,
        [ValidateSet('json', 'yaml', 'text')][string]$OutputFormat = 'yaml',
        [string]$Repo = 'Grimblaz/agent-orchestra',
        [string]$GhCliPath = 'gh',
        [string]$PortsDir,
        [string]$CacheDir,
        [switch]$NoCache,
        [string]$BackfilledAt = ''
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    try {
        if ([string]::IsNullOrWhiteSpace($PortsDir)) {
            $PortsDir = Join-Path -Path (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path -ChildPath 'frame/ports'
        }

        $prPayload = Get-FBDPrPayload -Repo $Repo -PrNumber $PrNumber -GhCliPath $GhCliPath -CacheDir $CacheDir -NoCache:$NoCache.IsPresent
        $metricsBlock = Get-FBDMetricsBlock -Body ([string](Get-FBDPropertyValue -InputObject $prPayload -Name 'body'))
        if ([string]::IsNullOrWhiteSpace($metricsBlock)) {
            return @{ ExitCode = 1; Output = ''; Error = "PR #$PrNumber does not contain a pipeline-metrics block." }
        }

        $metricsVersion = [string](Get-FBDMetricScalar -MetricsBlock $metricsBlock -Name 'metrics_version')
        if ([string]::IsNullOrWhiteSpace($metricsVersion)) {
            return @{ ExitCode = 1; Output = ''; Error = "PR #$PrNumber contains a pipeline-metrics block without metrics_version." }
        }

        if ($metricsVersion -notin @('1', '2', '3', '4')) {
            return @{ ExitCode = 1; Output = ''; Error = "Unsupported metrics_version '$metricsVersion' for PR #$PrNumber." }
        }

        $ports = Get-FBDPortOrder -PortsDir $PortsDir
        $linkedIssue = Resolve-FBDLinkedIssue -PrPayload $prPayload
        $auditSurface = Get-FBDAuditSurface -PrPayload $prPayload -MetricsVersion $metricsVersion -LinkedIssue $linkedIssue -Ports $ports -MetricsBlock $metricsBlock -BackfilledAt $BackfilledAt

        $serializedOutput = switch ($OutputFormat) {
            'json' { ConvertTo-FBDAuditJson -AuditSurface $auditSurface }
            'yaml' { ConvertTo-FBDAuditYaml -AuditSurface $auditSurface }
            'text' { ConvertTo-FBDAuditText -AuditSurface $auditSurface }
        }

        return @{ ExitCode = 0; Output = $serializedOutput; Error = '' }
    }
    catch {
        return @{ ExitCode = 1; Output = ''; Error = "frame-back-derive failed for PR #${PrNumber}: $($_.Exception.Message)" }
    }
}
