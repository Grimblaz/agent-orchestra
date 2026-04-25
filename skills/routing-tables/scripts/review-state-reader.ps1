#Requires -Version 7.0

function Get-ReviewStateFilePath {
    param(
        [Parameter(Mandatory)]
        [int]$IssueId,

        [string]$SessionMemoryPath = '/memories/session'
    )

    if ($IssueId -lt 1 -or [string]::IsNullOrWhiteSpace($SessionMemoryPath)) {
        return $null
    }

    return Join-Path -Path $SessionMemoryPath -ChildPath ("review-state-{0}.md" -f $IssueId)
}

function Read-ReviewStateFile {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }

    $content = Get-Content -LiteralPath $Path -Raw -ErrorAction SilentlyContinue
    if ([string]::IsNullOrWhiteSpace($content)) {
        return $null
    }

    $frontMatterMatch = [regex]::Match($content, '^(?:---\r?\n)(.*?)(?:\r?\n---)(?:\r?\n|$)', [System.Text.RegularExpressions.RegexOptions]::Singleline)
    if (-not $frontMatterMatch.Success) {
        return $null
    }

    $requiredFields = @(
        'issue_id',
        'review_mode',
        'prosecution_complete',
        'defense_complete',
        'judgment_complete',
        'last_updated'
    )

    $state = [ordered]@{}
    foreach ($line in ($frontMatterMatch.Groups[1].Value -split "`r?`n")) {
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }

        $parts = $line -split ':', 2
        if ($parts.Count -ne 2) {
            return $null
        }

        $state[$parts[0].Trim()] = $parts[1].Trim()
    }

    foreach ($field in $requiredFields) {
        if (-not $state.Contains($field) -or [string]::IsNullOrWhiteSpace([string]$state[$field])) {
            return $null
        }
    }

    $issueId = 0
    if (-not [int]::TryParse([string]$state.issue_id, [ref]$issueId)) {
        return $null
    }

    $parsedBooleans = @{}
    foreach ($field in @('prosecution_complete', 'defense_complete', 'judgment_complete')) {
        switch ([string]$state[$field]) {
            'true' { $parsedBooleans[$field] = $true }
            'false' { $parsedBooleans[$field] = $false }
            default { return $null }
        }
    }

    if ([string]$state.review_mode -notin @('full', 'lite')) {
        return $null
    }

    $lastUpdated = [datetimeoffset]::MinValue
    $timestampStyles = [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal
    $lastUpdatedText = [string]$state.last_updated
    if ($lastUpdatedText -notmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,7})?(?:Z|\+00:00)$') {
        return $null
    }

    if (-not [datetimeoffset]::TryParse($lastUpdatedText, [System.Globalization.CultureInfo]::InvariantCulture, $timestampStyles, [ref]$lastUpdated)) {
        return $null
    }

    if ($lastUpdated.Offset -ne [timespan]::Zero) {
        return $null
    }

    return [ordered]@{
        issue_id             = $issueId
        review_mode          = [string]$state.review_mode
        prosecution_complete = $parsedBooleans.prosecution_complete
        defense_complete     = $parsedBooleans.defense_complete
        judgment_complete    = $parsedBooleans.judgment_complete
        last_updated         = [string]$state.last_updated
    }
}

function Read-ReviewStateByIssueId {
    param(
        [Parameter(Mandatory)]
        [int]$IssueId,

        [string]$SessionMemoryPath = '/memories/session'
    )

    $path = Get-ReviewStateFilePath -IssueId $IssueId -SessionMemoryPath $SessionMemoryPath
    if ([string]::IsNullOrWhiteSpace($path)) {
        return $null
    }

    $state = Read-ReviewStateFile -Path $path
    if ($null -eq $state -or $state.issue_id -ne $IssueId) {
        return $null
    }

    return $state
}
