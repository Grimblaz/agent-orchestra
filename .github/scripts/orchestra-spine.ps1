#Requires -Version 7.0
<#
.SYNOPSIS
    Render the latest plan comment frame spine for a GitHub issue.
#>

[CmdletBinding()]
param(
    [AllowNull()][string]$Issue,
    [AllowNull()][string]$CommentsJsonPath,
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$RemainingArguments
)

[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)

try {
    . (Join-Path $PSScriptRoot 'lib/frame-spine-core.ps1')
    . (Join-Path $PSScriptRoot 'lib/frame-shared-discovery.ps1')
    . (Join-Path $PSScriptRoot 'lib/goal-contract-core.ps1')
}
catch {
    [Console]::Error.WriteLine("orchestra-spine: library load failed: $($_.Exception.Message)")
    if ($MyInvocation.InvocationName -ne '.') { exit 1 }
    throw
}

$script:OrchestraSpineRepoRoot = if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) {
    Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
}
else {
    (Get-Location).Path
}
$script:OrchestraSpinePortsDir = Join-Path -Path $script:OrchestraSpineRepoRoot -ChildPath 'frame/ports'
$script:OrchestraSpineCanonicalPortSet = $null

function Get-OrchestraSpineUsageText {
    return 'Usage: /orchestra:spine <issue-number> (positive integer issue number). If no plan comment is found, open the issue and confirm a <!-- plan-issue-{ID} --> comment exists.'
}

function Format-OrchestraSpineSafeMessage {
    param([AllowNull()][string]$Message)

    $safeMessage = if ($null -eq $Message) { '' } else { $Message }
    foreach ($tokenName in @('GH_TOKEN', 'GITHUB_TOKEN')) {
        $tokenValue = [Environment]::GetEnvironmentVariable($tokenName)
        if (-not [string]::IsNullOrEmpty($tokenValue)) {
            $safeMessage = $safeMessage.Replace($tokenValue, '[redacted]')
        }
    }

    return $safeMessage
}

function Test-OrchestraSpineIssueArgument {
    param(
        [AllowNull()][string]$Value,
        [ref]$IssueNumber
    )

    if ([string]::IsNullOrWhiteSpace($Value) -or $Value -notmatch '^[1-9]\d*$') {
        return $false
    }

    $parsed = 0
    if (-not [int]::TryParse($Value, [ref]$parsed)) {
        return $false
    }

    if ($parsed -le 0) {
        return $false
    }

    $IssueNumber.Value = $parsed
    return $true
}

function Resolve-OrchestraSpineCliArgumentValues {
    param(
        [AllowNull()][string]$IssueParameter,
        [AllowNull()][string]$CommentsJsonPathParameter,
        [AllowNull()][string[]]$AdditionalArguments
    )

    $resolved = [ordered]@{
        Issue            = $IssueParameter
        CommentsJsonPath = $CommentsJsonPathParameter
    }

    $tokens = [System.Collections.Generic.List[string]]::new()
    if (-not [string]::IsNullOrEmpty($IssueParameter) -and $IssueParameter.StartsWith('-')) {
        $tokens.Add($IssueParameter) | Out-Null
        if ($null -ne $CommentsJsonPathParameter) { $tokens.Add($CommentsJsonPathParameter) | Out-Null }
        foreach ($argument in @($AdditionalArguments)) { $tokens.Add($argument) | Out-Null }
    }
    elseif ($null -ne $AdditionalArguments -and $AdditionalArguments.Count -gt 0) {
        foreach ($argument in @($AdditionalArguments)) { $tokens.Add($argument) | Out-Null }
    }

    if ($tokens.Count -eq 0) {
        return [pscustomobject]$resolved
    }

    $resolved.Issue = $null
    $resolved.CommentsJsonPath = $null

    for ($index = 0; $index -lt $tokens.Count; $index++) {
        $token = $tokens[$index]
        switch -Regex ($token) {
            '^-Issue$' {
                if ($index + 1 -lt $tokens.Count) {
                    $index++
                    $resolved.Issue = $tokens[$index]
                }
                continue
            }
            '^-CommentsJsonPath$' {
                if ($index + 1 -lt $tokens.Count) {
                    $index++
                    $resolved.CommentsJsonPath = $tokens[$index]
                }
                continue
            }
            default {
                if ($null -eq $resolved.Issue) {
                    $resolved.Issue = $token
                }
                elseif ($null -eq $resolved.CommentsJsonPath) {
                    $resolved.CommentsJsonPath = $token
                }
            }
        }
    }

    return [pscustomobject]$resolved
}

function Get-OrchestraSpineObjectPropertyValue {
    param(
        [AllowNull()]$InputObject,
        [Parameter(Mandatory)][string]$Name
    )

    if ($null -eq $InputObject) { return $null }

    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function ConvertTo-OrchestraSpineFlatCommentList {
    param([AllowNull()]$Value)

    $comments = [System.Collections.Generic.List[object]]::new()
    if ($null -eq $Value) { return @() }

    foreach ($item in @($Value)) {
        if ($null -eq $item) { continue }

        if ($item -is [System.Array]) {
            foreach ($nested in @(ConvertTo-OrchestraSpineFlatCommentList -Value $item)) {
                $comments.Add($nested) | Out-Null
            }
            continue
        }

        if ($null -ne (Get-OrchestraSpineObjectPropertyValue -InputObject $item -Name 'body')) {
            $comments.Add($item) | Out-Null
        }
    }

    return [object[]]$comments.ToArray()
}

function ConvertFrom-OrchestraSpineCommentsJson {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$CommentsJson)

    try {
        $parsed = $CommentsJson | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        throw "Unable to parse issue comments JSON. $($_.Exception.Message)"
    }

    $commentsProperty = Get-OrchestraSpineObjectPropertyValue -InputObject $parsed -Name 'comments'
    if ($null -ne $commentsProperty) {
        return [object[]](ConvertTo-OrchestraSpineFlatCommentList -Value $commentsProperty)
    }

    return [object[]](ConvertTo-OrchestraSpineFlatCommentList -Value $parsed)
}

function ConvertTo-OrchestraSpineDateKey {
    param([AllowNull()][string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return [System.DateTimeOffset]::MinValue
    }

    try {
        return [System.DateTimeOffset]::Parse(
            $Value,
            [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal
        )
    }
    catch {
        return [System.DateTimeOffset]::MinValue
    }
}

function Select-OrchestraSpineLatestPlanComment {
    param(
        [Parameter(Mandatory)][ValidateRange(1, [int]::MaxValue)][int]$IssueNumber,
        [AllowEmptyCollection()][object[]]$Comments
    )

    $markerPattern = '<!--\s*plan-issue-' + [regex]::Escape([string]$IssueNumber) + '\s*-->'
    $selected = $null

    foreach ($comment in @($Comments)) {
        $body = [string](Get-OrchestraSpineObjectPropertyValue -InputObject $comment -Name 'body')
        if ($body -notmatch $markerPattern) { continue }

        $updatedValue = Get-OrchestraSpineObjectPropertyValue -InputObject $comment -Name 'updatedAt'
        if ($null -eq $updatedValue) { $updatedValue = Get-OrchestraSpineObjectPropertyValue -InputObject $comment -Name 'updated_at' }
        if ($null -eq $updatedValue) { $updatedValue = Get-OrchestraSpineObjectPropertyValue -InputObject $comment -Name 'createdAt' }
        if ($null -eq $updatedValue) { $updatedValue = Get-OrchestraSpineObjectPropertyValue -InputObject $comment -Name 'created_at' }

        $idValue = Get-OrchestraSpineObjectPropertyValue -InputObject $comment -Name 'id'
        $idKey = 0L
        if ($null -ne $idValue) { [void][long]::TryParse([string]$idValue, [ref]$idKey) }

        $candidate = [pscustomobject]@{
            Body    = $body
            DateKey = ConvertTo-OrchestraSpineDateKey -Value ([string]$updatedValue)
            IdKey   = $idKey
        }

        if ($null -eq $selected -or
            $candidate.DateKey -gt $selected.DateKey -or
            ($candidate.DateKey -eq $selected.DateKey -and $candidate.IdKey -gt $selected.IdKey)) {
            $selected = $candidate
        }
    }

    return $selected
}

function Get-OrchestraSpineCanonicalPortSet {
    if ($null -ne $script:OrchestraSpineCanonicalPortSet) {
        Write-Output -NoEnumerate $script:OrchestraSpineCanonicalPortSet
        return
    }

    $ports = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($portName in @(Get-FramePortFileStem -PortsDir $script:OrchestraSpinePortsDir)) {
        if (-not [string]::IsNullOrWhiteSpace($portName)) {
            [void]$ports.Add($portName)
        }
    }

    $script:OrchestraSpineCanonicalPortSet = $ports
    Write-Output -NoEnumerate $script:OrchestraSpineCanonicalPortSet
}

function ConvertTo-OrchestraSpineMarkdownCell {
    param([AllowNull()][string]$Value)

    if ($null -eq $Value) { return '' }
    return (($Value -replace "`r`n", ' ' -replace "`n", ' ').Replace('|', '\|')).Trim()
}

function ConvertTo-OrchestraSpineMarkdown {
    param(
        [Parameter(Mandatory)][ValidateRange(1, [int]::MaxValue)][int]$IssueNumber,
        [Parameter(Mandatory)]$Spine
    )

    $canonicalPorts = Get-OrchestraSpineCanonicalPortSet
    $lines = [System.Collections.Generic.List[string]]::new()
    $generatedAt = $Spine.GeneratedAt.UtcDateTime.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [System.Globalization.CultureInfo]::InvariantCulture)

    $lines.Add("# /orchestra:spine issue #$IssueNumber") | Out-Null
    $lines.Add('') | Out-Null
    $lines.Add("generated_at: $generatedAt") | Out-Null
    $lines.Add('') | Out-Null
    $lines.Add('| Port | Step | Cycle | Terminal | Warning |') | Out-Null
    $lines.Add('| --- | --- | ---: | --- | --- |') | Out-Null

    foreach ($portName in $Spine.Ports.Keys) {
        $isKnownPort = $canonicalPorts.Contains([string]$portName)
        $warning = if ($isKnownPort) { '' } else { "[unknown-port] $portName" }

        foreach ($token in @($Spine.Ports[$portName])) {
            $terminal = if ($token.Terminal -eq $true) { 'yes' } else { 'no' }
            $cycle = if ([int]$token.Cycle -gt 0) { [string][int]$token.Cycle } else { '' }

            $lines.Add(('| {0} | {1} | {2} | {3} | {4} |' -f @(
                        (ConvertTo-OrchestraSpineMarkdownCell -Value ([string]$portName)),
                        (ConvertTo-OrchestraSpineMarkdownCell -Value ([string]$token.StepId)),
                        $cycle,
                        $terminal,
                        (ConvertTo-OrchestraSpineMarkdownCell -Value $warning)
                    ))) | Out-Null
        }
    }

    return ($lines.ToArray() -join "`n")
}

function Invoke-OrchestraSpineRender {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][ValidateRange(1, [int]::MaxValue)][int]$IssueNumber,
        [Parameter(Mandatory)][AllowEmptyString()][string]$CommentsJson
    )

    $comments = @(ConvertFrom-OrchestraSpineCommentsJson -CommentsJson $CommentsJson)
    if ($comments.Count -eq 0) {
        throw "No plan-issue-$IssueNumber comment found for issue #$IssueNumber. $(Get-OrchestraSpineUsageText)"
    }

    $planComment = Select-OrchestraSpineLatestPlanComment -IssueNumber $IssueNumber -Comments $comments

    if ($null -eq $planComment) {
        throw "No plan-issue-$IssueNumber comment found for issue #$IssueNumber. $(Get-OrchestraSpineUsageText)"
    }

    # 872-D5/872-D7: goal-contract variant detection is hoisted above both
    # the plan-too-small escape and the legacy-plan-shape fall-through, so a
    # variant-declared plan always renders the variant-aware message instead
    # of either misleading no-spine message (identical precedence to
    # Invoke-FVPlanValidate in frame-validate-core.ps1).
    if (Test-GCVariantFrontmatter -CommentBody $planComment.Body) {
        return 'plan uses the goal-contract variant — no spine; see the plan comment for the contract'
    }

    if ($planComment.Body -match '(?m)^\s*spine-omitted\s*:\s*plan-too-small\s*$') {
        return 'plan has no spine — see comment for prose plan'
    }

    $spineBlock = Get-FSCSpineBlock -CommentBody $planComment.Body
    if ([string]::IsNullOrWhiteSpace($spineBlock)) {
        return "legacy-plan-shape: latest plan-issue-$IssueNumber comment has no frame-spine block; no spine is available, see the plan comment for prose plan"
    }

    $spine = ConvertFrom-FSCSpineYaml -SpineBlock $spineBlock
    if ($null -eq $spine) {
        throw "Latest plan-issue-$IssueNumber comment has an unreadable frame-spine block. $(Get-OrchestraSpineUsageText)"
    }

    return (ConvertTo-OrchestraSpineMarkdown -IssueNumber $IssueNumber -Spine $spine)
}

function Get-OrchestraSpineLiveCommentsJson {
    param([Parameter(Mandatory)][ValidateRange(1, [int]::MaxValue)][int]$IssueNumber)

    if ($null -eq (Get-Command gh -ErrorAction SilentlyContinue)) {
        throw "Unable to fetch issue #$IssueNumber comments because gh is not available. Install GitHub CLI or pass -CommentsJsonPath for offline rendering."
    }

    $repoName = & gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace([string]$repoName)) {
        throw "Unable to resolve the current GitHub repository with gh repo view. Confirm gh auth status and repository access, then retry."
    }

    $commentsPath = 'repos/{0}/issues/{1}/comments?per_page=100' -f ([string]$repoName).Trim(), $IssueNumber
    $commentsJson = & gh api $commentsPath --paginate --slurp 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace([string]$commentsJson)) {
        throw "Unable to fetch issue #$IssueNumber comments with gh api. Confirm the issue number and repository access, then retry."
    }

    return [string]$commentsJson
}

function Initialize-OrchestraSpineRenderWarmup {
    $warmupSpine = @(
        'spine_schema_version: 1' # v1 retained intentionally - see #555 step 1
        'generated_at: 2026-05-05T00:00:00Z'
        'coverage: complete'
        'ports:'
        '  implement-test: [s1]'
        'slices:'
        '  s1:'
        '    ac_refs: [AC10]'
        '    depends_on: []'
        '    cycle: 1'
    ) -join "`n"

    $warmupJson = @{
        comments = @(
            @{
                id        = 1
                updatedAt = '2026-05-05T00:00:01Z'
                body      = "<!-- plan-issue-1 -->`n`n<!-- frame-spine`n$warmupSpine`n-->"
            }
        )
    } | ConvertTo-Json -Depth 8

    try { $null = Invoke-OrchestraSpineRender -IssueNumber 1 -CommentsJson $warmupJson }
    catch { $script:OrchestraSpineWarmupError = $_.Exception.Message }
}

function Invoke-OrchestraSpineCli {
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [AllowNull()][string]$IssueArgument,
        [AllowNull()][string]$FixturePath
    )

    $issueNumber = 0
    if (-not (Test-OrchestraSpineIssueArgument -Value $IssueArgument -IssueNumber ([ref]$issueNumber))) {
        [Console]::Error.WriteLine((Get-OrchestraSpineUsageText))
        return 2
    }

    try {
        if ([string]::IsNullOrWhiteSpace($FixturePath)) {
            $commentsJson = Get-OrchestraSpineLiveCommentsJson -IssueNumber $issueNumber
        }
        else {
            $commentsJson = Get-Content -LiteralPath $FixturePath -Raw -ErrorAction Stop
        }

        $rendered = Invoke-OrchestraSpineRender -IssueNumber $issueNumber -CommentsJson $commentsJson
        [Console]::Out.WriteLine($rendered)
        return 0
    }
    catch {
        [Console]::Error.WriteLine((Format-OrchestraSpineSafeMessage -Message $_.Exception.Message))
        return 1
    }
}

$null = Get-OrchestraSpineCanonicalPortSet
Initialize-OrchestraSpineRenderWarmup

if ($MyInvocation.InvocationName -ne '.') {
    $resolvedArguments = Resolve-OrchestraSpineCliArgumentValues `
        -IssueParameter $Issue `
        -CommentsJsonPathParameter $CommentsJsonPath `
        -AdditionalArguments $RemainingArguments
    exit (Invoke-OrchestraSpineCli -IssueArgument $resolvedArguments.Issue -FixturePath $resolvedArguments.CommentsJsonPath)
}
