#Requires -Version 7.0
<#
.SYNOPSIS
    Library for frame adapter validation. Dot-source and call Invoke-FrameValidate.
#>

$script:FVLibDir = Split-Path -Parent $PSCommandPath
. (Join-Path -Path $script:FVLibDir -ChildPath 'frame-shared-discovery.ps1')
. (Join-Path -Path $script:FVLibDir -ChildPath 'frame-spine-core.ps1')

function New-FVCheckResult {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][bool]$Passed,
        [AllowNull()][string]$Detail
    )

    return [PSCustomObject]@{
        Name   = $Name
        Passed = $Passed
        Detail = if ($null -eq $Detail) { '' } else { $Detail }
    }
}

function New-FVAggregateResult {
    param([AllowNull()][object[]]$Results)

    $normalizedResults = if ($null -eq $Results) { @() } else { @($Results) }
    $passCount = @($normalizedResults | Where-Object { $_.Passed -eq $true }).Count
    $failCount = @($normalizedResults | Where-Object { $_.Passed -eq $false }).Count
    $totalCount = $normalizedResults.Count
    $exitCode = if ($failCount -gt 0) { 1 } else { 0 }

    return [PSCustomObject]@{
        Results    = [object[]]$normalizedResults
        PassCount  = [int]$passCount
        FailCount  = [int]$failCount
        TotalCount = [int]$totalCount
        ExitCode   = [int]$exitCode
    }
}

function Resolve-FVRootPath {
    param([AllowNull()][string]$RootPath)

    if ($RootPath) {
        return (Resolve-Path -LiteralPath $RootPath).Path
    }

    return (Resolve-Path -LiteralPath (Join-Path -Path $script:FVLibDir -ChildPath '../../..')).Path
}

function Get-FVRelativePath {
    param(
        [Parameter(Mandatory)][string]$RootPath,
        [Parameter(Mandatory)][string]$Path
    )

    return ([System.IO.Path]::GetRelativePath($RootPath, $Path) -replace '\\', '/')
}

function Get-FVPortCatalog {
    param([Parameter(Mandatory)][string]$RootPath)

    $portsPath = Join-Path -Path $RootPath -ChildPath 'frame' -AdditionalChildPath 'ports'
    if (-not (Test-Path -LiteralPath $portsPath)) {
        return [PSCustomObject]@{
            Exists = $false
            Path   = $portsPath
            Names  = [string[]]@()
        }
    }

    $names = @(
        Get-ChildItem -LiteralPath $portsPath -Filter '*.yaml' -File |
            ForEach-Object { $_.BaseName } |
            Sort-Object
    )

    return [PSCustomObject]@{
        Exists = $true
        Path   = $portsPath
        Names  = [string[]]$names
    }
}

function Get-FVAdapterFiles {
    param([Parameter(Mandatory)][string]$RootPath)

    return (Get-FrameAdapterFile -RootPath $RootPath)
}

function Get-FVAdapterFrontmatter {
    param([Parameter(Mandatory)][System.IO.FileInfo]$File)

    return (Get-FrameAdapterFrontmatter -File $File)
}

function Get-FVAdapterMetadata {
    param([Parameter(Mandatory)][string]$RootPath)

    return @(
        foreach ($file in @(Get-FrameAdapterFile -RootPath $RootPath)) {
            Get-FrameAdapterFrontmatter -File $file
        }
    )
}

function Test-FVAdapterSymmetry {
    [CmdletBinding()]
    param(
        [string]$RootPath,
        [AllowNull()][object[]]$AdapterMetadata
    )

    $resolvedRoot = Resolve-FVRootPath -RootPath $RootPath
    $catalog = Get-FVPortCatalog -RootPath $resolvedRoot

    if (-not $catalog.Exists) {
        $relativePortsPath = Get-FVRelativePath -RootPath $resolvedRoot -Path $catalog.Path
        return (New-FVCheckResult -Name 'AdapterSymmetry' -Passed $true -Detail "$relativePortsPath missing; adapter symmetry skipped.")
    }

    $validPorts = [string[]]$catalog.Names
    $validPortSet = [System.Collections.Generic.HashSet[string]]::new([string[]]$validPorts, [System.StringComparer]::Ordinal)
    $validPortDetail = if ($validPorts.Count -gt 0) { $validPorts -join ', ' } else { '(none)' }
    $violations = [System.Collections.Generic.List[string]]::new()
    $adapters = if ($PSBoundParameters.ContainsKey('AdapterMetadata')) { @($AdapterMetadata) } else { @(Get-FVAdapterMetadata -RootPath $resolvedRoot) }

    foreach ($adapter in $adapters) {
        $relativePath = Get-FVRelativePath -RootPath $resolvedRoot -Path $adapter.File.FullName
        foreach ($providedPort in @($adapter.Provides)) {
            if (-not $validPortSet.Contains($providedPort)) {
                $violations.Add("$relativePath provides '$providedPort'; valid ports: $validPortDetail")
            }
        }
    }

    if ($violations.Count -eq 0) {
        return (New-FVCheckResult -Name 'AdapterSymmetry' -Passed $true -Detail '')
    }

    return (New-FVCheckResult -Name 'AdapterSymmetry' -Passed $false -Detail "$($violations.Count) invalid provides declaration(s): $($violations -join '; ')")
}

function Test-FVPredicateParse {
    [CmdletBinding()]
    param(
        [string]$RootPath,
        [AllowNull()][object[]]$AdapterMetadata
    )

    $resolvedRoot = Resolve-FVRootPath -RootPath $RootPath
    $violations = [System.Collections.Generic.List[string]]::new()
    $adapters = if ($PSBoundParameters.ContainsKey('AdapterMetadata')) { @($AdapterMetadata) } else { @(Get-FVAdapterMetadata -RootPath $resolvedRoot) }

    foreach ($adapter in $adapters) {
        $relativePath = Get-FVRelativePath -RootPath $resolvedRoot -Path $adapter.File.FullName
        foreach ($predicate in @($adapter.AppliesWhen)) {
            try {
                $result = ConvertTo-FVPredicate -Predicate $predicate
                if (Test-FVParseError -Value $result) {
                    $violations.Add("$relativePath applies-when '$predicate'; parse error at position $($result.Position): $($result.Message)")
                }
            }
            catch {
                $violations.Add("$relativePath applies-when '$predicate'; parse error at position 0: $_")
            }
        }
    }

    if ($violations.Count -eq 0) {
        return (New-FVCheckResult -Name 'PredicateParse' -Passed $true -Detail '')
    }

    return (New-FVCheckResult -Name 'PredicateParse' -Passed $false -Detail "$($violations.Count) applies-when parse error(s): $($violations -join '; ')")
}

function ConvertTo-FVNormalizedText {
    param([AllowNull()][string]$Text)

    if ($null -eq $Text) { return '' }
    return $Text -replace "`r`n", "`n" -replace "`r", "`n"
}

function ConvertFrom-FVInlineList {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)

    $trimmed = $Value.Trim()
    if (-not ($trimmed.StartsWith('[') -and $trimmed.EndsWith(']'))) {
        return $null
    }

    $inner = $trimmed.Substring(1, $trimmed.Length - 2).Trim()
    if ($inner.Length -eq 0) { return , ([string[]]@()) }

    $items = [System.Collections.Generic.List[string]]::new()
    foreach ($item in $inner -split ',') {
        $clean = $item.Trim()
        if ($clean.Length -eq 0) { return $null }
        $items.Add($clean) | Out-Null
    }

    return , ([string[]]$items.ToArray())
}

function Get-FVPlanScalarField {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Block,
        [Parameter(Mandatory)][string[]]$Names
    )

    foreach ($name in $Names) {
        $pattern = '(?m)^\s*' + [regex]::Escape($name) + '\s*:\s*(?<value>.*?)\s*$'
        $match = [regex]::Match($Block, $pattern)
        if ($match.Success) { return $match.Groups['value'].Value.Trim() }
    }

    return $null
}

function Get-FVPlanSliceBlock {
    param([AllowNull()][string]$CommentBody)

    $normalized = ConvertTo-FVNormalizedText -Text $CommentBody
    if ([string]::IsNullOrEmpty($normalized)) { return @() }

    $regexMatches = [regex]::Matches($normalized, '<!--\s*frame-slice(?:\s*\n|\s+)(?<payload>.*?)\n?\s*-->', [System.Text.RegularExpressions.RegexOptions]::Singleline)
    $blocks = [System.Collections.Generic.List[string]]::new()

    foreach ($match in $regexMatches) {
        $payload = $match.Groups['payload'].Value
        if ($payload.StartsWith("`n")) { $payload = $payload.Substring(1) }
        if ($payload.EndsWith("`n")) { $payload = $payload.Substring(0, $payload.Length - 1) }
        $blocks.Add($payload) | Out-Null
    }

    return $blocks.ToArray()
}

function ConvertFrom-FVPlanSliceBlock {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Block)

    $stepId = Get-FVPlanScalarField -Block $Block -Names @('id', 'step_id')
    $providesRaw = Get-FVPlanScalarField -Block $Block -Names @('provides', 'ports')
    $acRefsRaw = Get-FVPlanScalarField -Block $Block -Names @('ac-refs', 'ac_refs')
    $coverage = Get-FVPlanScalarField -Block $Block -Names @('coverage')

    $provides = if ($null -eq $providesRaw) { [string[]]@() } else { ConvertFrom-FVInlineList -Value $providesRaw }
    if ($null -eq $provides) { $provides = [string[]]@() }

    $acRefs = if ($null -eq $acRefsRaw) { [string[]]@() } else { ConvertFrom-FVInlineList -Value $acRefsRaw }
    if ($null -eq $acRefs) { $acRefs = [string[]]@() }

    $isExploratory = $false
    $exploratoryReason = ''
    if ($coverage -match '^exploratory\s*-\s*(?<reason>.+)$') {
        $isExploratory = $true
        $exploratoryReason = $Matches['reason'].Trim()
    }

    return [PSCustomObject]@{
        StepId            = if ($stepId) { $stepId } else { '(missing-id)' }
        Provides          = [string[]]$provides
        AcRefs            = [string[]]$acRefs
        Coverage          = if ($null -eq $coverage) { '' } else { $coverage }
        IsExploratory     = [bool]$isExploratory
        ExploratoryReason = [string]$exploratoryReason
    }
}

function ConvertFrom-FVPlanSpineBlock {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$SpineBlock)

    $canonical = ConvertFrom-FSCSpineYaml -SpineBlock $SpineBlock
    if ($null -ne $canonical) {
        $ports = [ordered]@{}
        foreach ($portName in @($canonical.Ports.Keys)) {
            $ports[$portName] = [string[]]@($canonical.Ports[$portName] | ForEach-Object { $_.StepId })
        }

        return [PSCustomObject]@{ Ports = $ports }
    }

    $normalized = ConvertTo-FVNormalizedText -Text $SpineBlock
    $portsByName = [ordered]@{}
    $section = ''

    foreach ($line in @($normalized -split "`n")) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }

        if ($line -match '^ports:\s*$') {
            $section = 'ports'
            continue
        }

        if ($line -match '^slices:\s*$') {
            $section = 'slices'
            continue
        }

        if ($section -ne 'ports') { continue }

        $portMatch = [regex]::Match($line, '^  (?<port>[A-Za-z0-9_-]+):\s*(?<value>\[.*\])\s*$')
        if (-not $portMatch.Success) { continue }

        $tokens = ConvertFrom-FVInlineList -Value $portMatch.Groups['value'].Value
        if ($null -eq $tokens) { $tokens = [string[]]@() }

        $stepIds = [System.Collections.Generic.List[string]]::new()
        foreach ($token in @($tokens)) {
            $tokenMatch = [regex]::Match($token, '^(?<step>s\d+)(?:#cycle:\d+(?:#terminal)?)?$')
            if ($tokenMatch.Success) { $stepIds.Add($tokenMatch.Groups['step'].Value) | Out-Null }
        }

        $portsByName[$portMatch.Groups['port'].Value] = [string[]]$stepIds.ToArray()
    }

    return [PSCustomObject]@{ Ports = $portsByName }
}

function Get-FVPlanAcceptanceCriterionId {
    param([AllowNull()][string]$CommentBody)

    $normalized = ConvertTo-FVNormalizedText -Text $CommentBody
    $ids = [System.Collections.Generic.List[string]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    $inAcceptanceCriteria = $false

    foreach ($line in @($normalized -split "`n")) {
        if ($line -match '^##\s+Acceptance Criteria\s*$') {
            $inAcceptanceCriteria = $true
            continue
        }

        if ($inAcceptanceCriteria -and $line -match '^##\s+') { break }

        if (-not $inAcceptanceCriteria) { continue }

        $match = [regex]::Match($line, '^\s*-\s+\*\*(?<id>AC\d+)\*\*')
        if ($match.Success -and $seen.Add($match.Groups['id'].Value)) {
            $ids.Add($match.Groups['id'].Value) | Out-Null
        }
    }

    return $ids.ToArray()
}

function Resolve-FVCommentFilePath {
    param([Parameter(Mandatory)][string]$CommentFile)

    try {
        return (Resolve-Path -LiteralPath $CommentFile).Path
    }
    catch {
        if ($CommentFile -notmatch '^TestDrive:[\\/](?<leaf>[^\\/]+)$') { throw }

        $leafName = $Matches['leaf']
        $tempRoot = [System.IO.Path]::GetTempPath()
        $match = Get-ChildItem -LiteralPath $tempRoot -Filter $leafName -File -Recurse -Depth 4 -ErrorAction SilentlyContinue |
            Sort-Object -Property LastWriteTimeUtc -Descending |
            Select-Object -First 1

        if ($null -eq $match) { throw }
        return $match.FullName
    }
}

function Get-FVPlanCommentText {
    param(
        [AllowNull()][string]$CommentFile,
        [AllowNull()][string]$CommentText
    )

    if ($CommentFile) {
        $resolvedCommentFile = Resolve-FVCommentFilePath -CommentFile $CommentFile
        return [System.IO.File]::ReadAllText($resolvedCommentFile)
    }

    if ($null -ne $CommentText) { return $CommentText }
    return ''
}

function Invoke-FVPlanValidate {
    [CmdletBinding()]
    param(
        [AllowNull()][string]$CommentFile,
        [AllowNull()][string]$CommentText
    )

    $commentBody = Get-FVPlanCommentText -CommentFile $CommentFile -CommentText $CommentText
    $spineBlock = Get-FSCSpineBlock -CommentBody $commentBody
    if ($null -eq $spineBlock) {
        return (New-FVAggregateResult -Results @((New-FVCheckResult -Name 'PlanStructuralCoverage' -Passed $false -Detail 'Missing frame-spine block.')))
    }

    $spine = ConvertFrom-FVPlanSpineBlock -SpineBlock $spineBlock
    $slices = @(
        foreach ($block in @(Get-FVPlanSliceBlock -CommentBody $commentBody)) {
            ConvertFrom-FVPlanSliceBlock -Block $block
        }
    )

    $sliceByStepId = @{}
    foreach ($slice in $slices) {
        if (-not $sliceByStepId.ContainsKey($slice.StepId)) { $sliceByStepId[$slice.StepId] = $slice }
    }

    $structuralViolations = [System.Collections.Generic.List[string]]::new()
    $coverageGaps = [System.Collections.Generic.List[string]]::new()

    foreach ($slice in $slices) {
        if (@($slice.Provides).Count -gt 0) { continue }

        if ($slice.IsExploratory) {
            $coverageGaps.Add("coverage-gap: step $($slice.StepId) is exploratory - $($slice.ExploratoryReason)") | Out-Null
            continue
        }

        $structuralViolations.Add("step $($slice.StepId) has no provides: declaration; add provides: [port-name] or coverage: exploratory - <reason>.") | Out-Null
    }

    foreach ($portName in $spine.Ports.Keys) {
        foreach ($stepId in @($spine.Ports[$portName])) {
            if (-not $sliceByStepId.ContainsKey($stepId)) {
                $structuralViolations.Add("port $portName references step $stepId, but no frame-slice provides: anchor exists; add slice provides: [$portName].") | Out-Null
                continue
            }

            $slice = $sliceByStepId[$stepId]
            if (@($slice.Provides).Count -eq 0) {
                $structuralViolations.Add("port $portName references step $stepId, but that slice has no slice provides: [$portName] anchor.") | Out-Null
                continue
            }

            if ($slice.Provides -notcontains $portName) {
                $slicePorts = @($slice.Provides) -join ', '
                $structuralViolations.Add("step $stepId conflict: spine port $portName, slice port $slicePorts; update the spine or slice provides: anchor.") | Out-Null
            }
        }
    }

    $coveredAcIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($slice in $slices) {
        foreach ($acRef in @($slice.AcRefs)) { $coveredAcIds.Add($acRef) | Out-Null }
    }

    foreach ($acId in @(Get-FVPlanAcceptanceCriterionId -CommentBody $commentBody)) {
        if (-not $coveredAcIds.Contains($acId)) {
            $coverageGaps.Add("coverage-gap: acceptance criterion $acId has no slice ac-refs: coverage.") | Out-Null
        }
    }

    $results = [System.Collections.Generic.List[PSCustomObject]]::new()
    if ($structuralViolations.Count -eq 0) {
        $results.Add((New-FVCheckResult -Name 'PlanStructuralCoverage' -Passed $true -Detail '')) | Out-Null
    }
    else {
        $results.Add((New-FVCheckResult -Name 'PlanStructuralCoverage' -Passed $false -Detail "$($structuralViolations.Count) structural violation(s): $($structuralViolations -join '; ')")) | Out-Null
    }

    if ($coverageGaps.Count -eq 0) {
        $results.Add((New-FVCheckResult -Name 'PlanCoverageGap' -Passed $true -Detail '')) | Out-Null
    }
    else {
        $results.Add((New-FVCheckResult -Name 'PlanCoverageGap' -Passed $true -Detail "$($coverageGaps.Count) warn-only coverage gap(s): $($coverageGaps -join '; ')")) | Out-Null
    }

    return (New-FVAggregateResult -Results $results.ToArray())
}

function Invoke-FrameValidate {
    [CmdletBinding()]
    param(
        [string]$RootPath,
        [ValidateSet('default', 'plan')]
        [string]$Mode = 'default',
        [AllowNull()][string]$CommentFile,
        [AllowNull()][string]$CommentText
    )

    $ErrorActionPreference = 'Stop'
    Set-StrictMode -Version Latest

    try {
        if ($Mode -eq 'plan') {
            return (Invoke-FVPlanValidate -CommentFile $CommentFile -CommentText $CommentText)
        }

        $resolvedRoot = Resolve-FVRootPath -RootPath $RootPath
        $results = [System.Collections.Generic.List[PSCustomObject]]::new()
        $adapterMetadataCache = [PSCustomObject]@{
            Loaded = $false
            Value  = [object[]]@()
        }
        $getAdapterMetadata = {
            if (-not $adapterMetadataCache.Loaded) {
                $adapterMetadataCache.Value = [object[]]@(Get-FVAdapterMetadata -RootPath $resolvedRoot)
                $adapterMetadataCache.Loaded = $true
            }

            return $adapterMetadataCache.Value
        }

        foreach ($check in @(
                @{ Name = 'AdapterSymmetry'; Script = { Test-FVAdapterSymmetry -RootPath $resolvedRoot -AdapterMetadata (& $getAdapterMetadata) } },
                @{ Name = 'PredicateParse'; Script = { Test-FVPredicateParse -RootPath $resolvedRoot -AdapterMetadata (& $getAdapterMetadata) } }
            )) {
            try {
                $results.Add((& $check.Script))
            }
            catch {
                $results.Add((New-FVCheckResult -Name $check.Name -Passed $false -Detail "Error: $_"))
            }
        }

        return (New-FVAggregateResult -Results $results.ToArray())
    }
    catch {
        return (New-FVAggregateResult -Results @((New-FVCheckResult -Name 'FrameValidate' -Passed $false -Detail "Error: $_")))
    }
}
