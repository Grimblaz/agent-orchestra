#Requires -Version 7.0
<#!
.SYNOPSIS
    Warn-only plan Verification Evidence checker for issue #579.

.DESCRIPTION
    Parses a plan markdown document supplied either inline or by path, inspects the
    Verification Evidence block, and emits non-blocking warnings for malformed or
    incomplete tree-state verification rows. The script never mutates repository
    files, never calls GitHub, and exits 0 for malformed input.
#>

[CmdletBinding()]
param(
    [string]$PlanContent,
    [string]$PlanPath
)

$script:CategoryPattern = 'text-presence|structure-presence|downstream-consumer|numeric-or-structural|named-standard'

function Get-PlanTreeStateInput {
    [CmdletBinding()]
    param(
        [hashtable]$BoundParameters,
        [string]$InlineContent,
        [string]$Path
    )

    if ($BoundParameters.ContainsKey('PlanContent') -and $null -ne $InlineContent) {
        return $InlineContent
    }

    if (-not $BoundParameters.ContainsKey('PlanPath') -or [string]::IsNullOrWhiteSpace($Path)) {
        Write-Warning 'No plan input supplied'
        return $null
    }

    try {
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
            Write-Warning "PlanPath could not be read: $Path"
            return $null
        }

        return (Get-Content -LiteralPath $Path -Raw -ErrorAction Stop)
    }
    catch {
        Write-Warning "PlanPath could not be read: $Path"
        return $null
    }
}

function Get-PlanVerificationEvidenceBlock {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Content)

    $anchorIndex = $Content.IndexOf('<!-- verification-evidence -->', [System.StringComparison]::Ordinal)
    if ($anchorIndex -lt 0) {
        Write-Warning 'Verification Evidence block missing'
        return $null
    }

    $afterAnchor = $Content.Substring($anchorIndex)
    $headingMatch = [regex]::Match($afterAnchor, '(?m)^\s*\*\*Verification Evidence\*\*\s*$')
    if (-not $headingMatch.Success) {
        Write-Warning 'Verification Evidence block missing'
        return $null
    }

    $blockStart = $anchorIndex + $headingMatch.Index + $headingMatch.Length
    $remaining = $Content.Substring($blockStart)
    $nextHeading = [regex]::Match($remaining, '(?m)^(#{1,6}\s+|\*\*[^*\r\n]+\*\*\s*$)')

    if ($nextHeading.Success) {
        return $remaining.Substring(0, $nextHeading.Index)
    }

    return $remaining
}

function Get-LoadBearingAcIds {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Content)

    $ids = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $categoryToken = [regex]::new($script:CategoryPattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    $acMatches = [regex]::Matches($Content, '\*\*AC(?<id>\d+[A-Za-z0-9-]*)\*\*\s*\((?<tags>[^)]*)\)', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)

    foreach ($acMatch in $acMatches) {
        if ($categoryToken.IsMatch($acMatch.Groups['tags'].Value)) {
            $null = $ids.Add($acMatch.Groups['id'].Value)
        }
    }

    return , $ids
}

function ConvertFrom-PlanEvidenceRow {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RowText,
        [Parameter(Mandatory)][int]$RowNumber
    )

    $rowPattern = '^\s*-\s+\*\*AC(?<id>\d+[A-Za-z0-9-]*)\*\*\s*\((?<category>' + $script:CategoryPattern + ')\)\s*:\s*(?<body>.*)$'
    $rowMatch = [regex]::Match($RowText, $rowPattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if (-not $rowMatch.Success) {
        Write-Warning "row $RowNumber unparseable"
        return $null
    }

    $body = $rowMatch.Groups['body'].Value
    $dispositionMatch = [regex]::Match($body, '\*\*(?<disposition>verified|revised|exempted|planned)(?:\s*\((?<detail>[^)]*)\))?\*\*', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if (-not $dispositionMatch.Success) {
        Write-Warning "row $RowNumber unparseable"
        return $null
    }

    $afterDisposition = $body.Substring($dispositionMatch.Index + $dispositionMatch.Length)
    $evidenceMatch = [regex]::Match($afterDisposition, '(?i)\bevidence\s*:\s*(?<evidence>.+)$')
    $evidence = if ($evidenceMatch.Success) { $evidenceMatch.Groups['evidence'].Value.Trim() } else { '' }

    return [pscustomobject]@{
        AcId             = $rowMatch.Groups['id'].Value
        Category         = $rowMatch.Groups['category'].Value.ToLowerInvariant()
        Disposition      = $dispositionMatch.Groups['disposition'].Value.ToLowerInvariant()
        DispositionTail  = $afterDisposition
        Evidence         = $evidence
        RowText          = $RowText
        RowNumber        = $RowNumber
    }
}

function Test-PlanEvidenceRationale {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Text)

    return ($Text -match '(?i)\brationale\s*:\s*\S' -or
        $Text -match '(?i)\breason\s*:\s*\S' -or
        $Text -match '(?i)\bbecause\b\s+\S')
}

function Test-PlanEvidenceShape {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Category,
        [string]$Evidence
    )

    $evidenceText = if ($null -eq $Evidence) { '' } else { $Evidence }

    switch ($Category) {
        { $_ -in @('text-presence', 'structure-presence') } {
            return ($evidenceText -match '(?i)\b(grep|rg)\b' -or
                $evidenceText -match '\S+:\d+' -or
                $evidenceText -match '(?i)\bline \d+\b' -or
                $evidenceText -match '(?i)\blines? \d+( (and|,) \d+)*\b')
        }
        'downstream-consumer' {
            return ($evidenceText -match '\S+:\d+' -or
                $evidenceText -match '(?i)\b\w+\(\)' -or
                $evidenceText -match '(?i)\b(function|method|the function)\s+\w+\b')
        }
        'numeric-or-structural' {
            return ($evidenceText -match '#\d+' -or
                $evidenceText -match '(?i)\bD\d+\b' -or
                $evidenceText -match '(?i)\b\d+[- ]line\b' -or
                $evidenceText -match '\b\d+%' -or
                $evidenceText -match '(?i)\b\d+\s+items?\b')
        }
        'named-standard' {
            return ($evidenceText -match '#\d+' -or
                $evidenceText -match '(?i)\bSMC-\d+\b' -or
                $evidenceText -match '(?i)\bD\d+\b' -or
                $evidenceText -match '(?i)\b[A-Za-z][A-Za-z0-9 ._-]{1,80}\s+at\s+\S+:\d+\b')
        }
        default {
            return $false
        }
    }
}

function Write-PlanEvidenceRowWarnings {
    [CmdletBinding()]
    param([Parameter(Mandatory)][pscustomobject]$Row)

    if ($Row.Disposition -in @('revised', 'exempted') -and -not (Test-PlanEvidenceRationale -Text $Row.DispositionTail)) {
        Write-Warning "AC$($Row.AcId) $($Row.Disposition) disposition has no rationale"
    }

    if ($Row.Disposition -eq 'verified' -and -not (Test-PlanEvidenceShape -Category $Row.Category -Evidence $Row.Evidence)) {
        Write-Warning "AC$($Row.AcId) $($Row.Category) evidence doesn't match category shape"
    }

    if ($Row.Disposition -eq 'planned' -and $Row.RowText -notmatch '(?i)\bs\d+\b') {
        Write-Warning "AC$($Row.AcId) planned disposition lacks slice anchor"
    }
}

function Invoke-PlanTreeStateVerification {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Content)

    $normalizedContent = $Content -replace "`r`n", "`n" -replace "`r", "`n"
    $block = Get-PlanVerificationEvidenceBlock -Content $normalizedContent
    if ($null -eq $block) {
        return
    }

    # Heuristic v1: only ACs explicitly category-tagged in plan text, or named
    # in the evidence block itself, are treated as load-bearing. Unlisted ACs are
    # not classified until the methodology grows a stronger parser.
    $loadBearingAcIds = Get-LoadBearingAcIds -Content $normalizedContent
    $topLevelRows = @($block -split "`n" | Where-Object { $_ -match '^-\s+' })

    if ($topLevelRows.Count -eq 0) {
        Write-Warning 'Verification Evidence block present but empty'
        return
    }

    $seenEvidenceRows = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $rowNumber = 0

    foreach ($rowText in $topLevelRows) {
        $rowNumber++

        $acNameMatch = [regex]::Match($rowText, '^\s*-\s+\*\*AC(?<id>\d+[A-Za-z0-9-]*)\*\*', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        if ($acNameMatch.Success) {
            $acId = $acNameMatch.Groups['id'].Value
            $null = $loadBearingAcIds.Add($acId)
            if (-not $seenEvidenceRows.Add($acId)) {
                Write-Warning "duplicate evidence row for AC$acId"
            }
        }

        $row = ConvertFrom-PlanEvidenceRow -RowText $rowText -RowNumber $rowNumber
        if ($null -eq $row) {
            continue
        }

        Write-PlanEvidenceRowWarnings -Row $row
    }

    foreach ($acId in $loadBearingAcIds) {
        if (-not $seenEvidenceRows.Contains($acId)) {
            Write-Warning "AC$acId marked load-bearing has no evidence row"
        }
    }
}

try {
    $inputContent = Get-PlanTreeStateInput -BoundParameters $PSBoundParameters -InlineContent $PlanContent -Path $PlanPath
    if ($null -ne $inputContent) {
        Invoke-PlanTreeStateVerification -Content $inputContent
    }
}
catch {
    Write-Warning "Plan tree-state verification failed open: $($_.Exception.Message)"
}

exit 0