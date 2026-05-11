#Requires -Version 7.0
[CmdletBinding(DefaultParameterSetName = 'ByPath')]
param(
    [ValidateSet('Lookup')]
    [string]$Op,
    [Parameter(ParameterSetName = 'ByPath')]
    [string]$CommentBodyPath,
    [Parameter(ParameterSetName = 'ByStdin')]
    [switch]$CommentBodyStdin,
    [ValidateSet('Text', 'Json')]
    [string]$Format = 'Text',
    [string]$GeneratedAt,
    [string]$StepId
)

<#
.SYNOPSIS
    Pure-logic parser for frame spine and slice comment blocks.
#>

$script:FSCSupportedSpineSchemaVersions = [string[]]@('1', '2')
$script:FSCPortTokenPattern = '^(?<step>s\d+)(?:#cycle:(?<cycle>\d+))?(?<terminal>#terminal)?$'

function script:ConvertTo-FSCNormalizedText {
    param([AllowNull()][string]$Text)

    if ($null -eq $Text) { return '' }
    return $Text -replace "`r`n", "`n" -replace "`r", "`n"
}

function script:Get-FSCCommentBlockPayloads {
    param(
        [AllowNull()][string]$CommentBody,
        [Parameter(Mandatory)][string]$BlockName
    )

    $normalized = script:ConvertTo-FSCNormalizedText -Text $CommentBody
    if ([string]::IsNullOrEmpty($normalized)) { return @() }

    $escapedBlockName = [regex]::Escape($BlockName)
    $pattern = '<!--\s*' + $escapedBlockName + '\s*-->\s*\n(?<payload>.*?)\n\s*-->|<!--\s*' + $escapedBlockName + '(?:\s*\n|\s+)(?<payload>.*?)\n?\s*-->'
    $regexMatches = [regex]::Matches($normalized, $pattern, [System.Text.RegularExpressions.RegexOptions]::Singleline)
    $payloads = [System.Collections.Generic.List[string]]::new()

    foreach ($match in $regexMatches) {
        $payload = $match.Groups['payload'].Value
        if ($payload.StartsWith("`n")) { $payload = $payload.Substring(1) }
        if ($payload.EndsWith("`n")) { $payload = $payload.Substring(0, $payload.Length - 1) }
        $payloads.Add($payload) | Out-Null
    }

    return $payloads.ToArray()
}

function script:Get-FSCScalarValue {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Block,
        [Parameter(Mandatory)][string]$Name
    )

    $pattern = '(?m)^' + [regex]::Escape($Name) + '\s*:\s*(?<value>.*?)\s*$'
    $match = [regex]::Match($Block, $pattern)
    if (-not $match.Success) { return $null }
    return $match.Groups['value'].Value.Trim()
}

function script:Split-FSCInlineList {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)

    $trimmed = $Value.Trim()
    if (-not ($trimmed.StartsWith('[') -and $trimmed.EndsWith(']'))) {
        return $null
    }

    $inner = $trimmed.Substring(1, $trimmed.Length - 2).Trim()
    if ($inner.Length -eq 0) { return , [string[]]@() }

    $items = [System.Collections.Generic.List[string]]::new()
    foreach ($item in $inner -split ',') {
        $clean = $item.Trim()
        if ($clean.Length -eq 0) { return $null }
        $items.Add($clean) | Out-Null
    }

    return , ([string[]]$items.ToArray())
}

function script:ConvertFrom-FSCGeneratedAt {
    param([Parameter(Mandatory)][string]$Value)

    if ($Value -notmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z$') {
        return $null
    }

    $formats = [string[]]@(
        "yyyy-MM-dd'T'HH:mm:ss'Z'",
        "yyyy-MM-dd'T'HH:mm:ss.FFFFFFF'Z'"
    )

    try {
        return [System.DateTimeOffset]::ParseExact(
            $Value,
            $formats,
            [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal
        )
    }
    catch {
        return $null
    }
}

function script:ConvertFrom-FSCPortToken {
    param(
        [Parameter(Mandatory)][string]$TokenText,
        [Parameter(Mandatory)][hashtable]$SliceByStepId
    )

    $match = [regex]::Match($TokenText, $script:FSCPortTokenPattern)
    if (-not $match.Success) { return $null }

    $stepId = $match.Groups['step'].Value
    $slice = if ($SliceByStepId.ContainsKey($stepId)) { $SliceByStepId[$stepId] } else { $null }
    $cycle = if ($null -ne $slice) { [int]$slice.Cycle } else { 0 }
    if ($match.Groups['cycle'].Success) {
        $cycle = [int]$match.Groups['cycle'].Value
    }

    $terminal = $false
    if ($match.Groups['terminal'].Success) {
        $terminal = $true
    }
    elseif ($null -ne $slice -and $slice.PSObject.Properties['Terminal'] -and $slice.Terminal -eq $true) {
        $terminal = $true
    }

    return [pscustomobject]@{
        StepId   = $stepId
        Cycle    = $cycle
        Terminal = $terminal
    }
}

function script:Test-FSCStringSequenceEqual {
    param(
        [Parameter(Mandatory)][string[]]$Left,
        [Parameter(Mandatory)][string[]]$Right
    )

    if ($Left.Count -ne $Right.Count) { return $false }
    for ($index = 0; $index -lt $Left.Count; $index++) {
        if ($Left[$index] -cne $Right[$index]) { return $false }
    }

    return $true
}

function script:ConvertFrom-FSCSpineYamlInternal {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$SpineBlock)

    try {
        $normalized = script:ConvertTo-FSCNormalizedText -Text $SpineBlock
        if ([string]::IsNullOrWhiteSpace($normalized)) { return $null }

        $schemaVersion = script:Get-FSCScalarValue -Block $normalized -Name 'spine_schema_version'
        if ($schemaVersion -notin $script:FSCSupportedSpineSchemaVersions) { return $null }

        $generatedAtValue = script:Get-FSCScalarValue -Block $normalized -Name 'generated_at'
        if ($null -eq $generatedAtValue) { return $null }

        $generatedAt = script:ConvertFrom-FSCGeneratedAt -Value $generatedAtValue
        if ($null -eq $generatedAt) { return $null }

        $lines = $normalized -split "`n"
        $section = ''
        $portRawValues = [ordered]@{}
        $sliceByStepId = @{}
        $sliceOrder = [System.Collections.Generic.List[string]]::new()
        $currentSliceId = $null

        foreach ($line in $lines) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }

            if ($line -match '^ports:\s*$') {
                $section = 'ports'
                $currentSliceId = $null
                continue
            }

            if ($line -match '^slices:\s*$') {
                $section = 'slices'
                $currentSliceId = $null
                continue
            }

            if ($line -match '^(spine_schema_version|generated_at|coverage):\s*') {
                continue
            }

            if ($section -eq 'ports') {
                $portMatch = [regex]::Match($line, '^  (?<port>[A-Za-z0-9_-]+):\s*(?<value>\[.*\])\s*$')
                if (-not $portMatch.Success) { return $null }

                $portName = $portMatch.Groups['port'].Value
                if ($portRawValues.Contains($portName)) { return $null }
                $portRawValues[$portName] = $portMatch.Groups['value'].Value.Trim()
                continue
            }

            if ($section -eq 'slices') {
                $sliceMatch = [regex]::Match($line, '^  (?<step>s\d+):\s*$')
                if ($sliceMatch.Success) {
                    $currentSliceId = $sliceMatch.Groups['step'].Value
                    if ($sliceByStepId.ContainsKey($currentSliceId)) { return $null }

                    $sliceByStepId[$currentSliceId] = [ordered]@{
                        StepId     = $currentSliceId
                        AdapterRaw = $null
                        AcRefsRaw  = $null
                        DependsRaw = $null
                        Cycle      = $null
                        Terminal   = $false
                    }
                    $sliceOrder.Add($currentSliceId) | Out-Null
                    continue
                }

                if ($null -eq $currentSliceId) { return $null }

                $propertyMatch = [regex]::Match($line, '^    (?<key>[A-Za-z0-9_]+):\s*(?<value>.*?)\s*$')
                if (-not $propertyMatch.Success) { return $null }

                $slice = $sliceByStepId[$currentSliceId]
                $key = $propertyMatch.Groups['key'].Value
                $value = $propertyMatch.Groups['value'].Value.Trim()

                switch ($key) {
                    'adapter' {
                        $slice.AdapterRaw = $value
                    }
                    'ac_refs' {
                        if ($null -eq (script:Split-FSCInlineList -Value $value)) { return $null }
                        $slice.AcRefsRaw = $value
                    }
                    'depends_on' {
                        if ($null -eq (script:Split-FSCInlineList -Value $value)) { return $null }
                        $slice.DependsRaw = $value
                    }
                    'cycle' {
                        if ($value -notmatch '^\d+$') { return $null }
                        $slice.Cycle = [int]$value
                    }
                    'terminal' {
                        if ($value -notin @('true', 'false')) { return $null }
                        $slice.Terminal = ($value -eq 'true')
                    }
                    default { }
                }

                continue
            }

            return $null
        }

        if ($portRawValues.Count -eq 0 -or $sliceByStepId.Count -eq 0) { return $null }

        foreach ($stepId in $sliceOrder.ToArray()) {
            $slice = $sliceByStepId[$stepId]
            if ($null -eq $slice.AcRefsRaw -or $null -eq $slice.DependsRaw -or $null -eq $slice.Cycle) {
                return $null
            }
        }

        $ports = [ordered]@{}
        foreach ($portName in $portRawValues.Keys) {
            $tokenTexts = script:Split-FSCInlineList -Value ([string]$portRawValues[$portName])
            if ($null -eq $tokenTexts) { return $null }

            $tokens = [System.Collections.Generic.List[object]]::new()
            foreach ($tokenText in $tokenTexts) {
                $token = script:ConvertFrom-FSCPortToken -TokenText $tokenText -SliceByStepId $sliceByStepId
                if ($null -eq $token) { return $null }
                $tokens.Add($token) | Out-Null
            }

            $ports[$portName] = [object[]]$tokens.ToArray()
        }

        $slices = [System.Collections.Generic.List[object]]::new()
        foreach ($stepId in $sliceOrder.ToArray()) {
            $slice = $sliceByStepId[$stepId]
            $slices.Add([pscustomobject]@{
                    StepId    = $slice.StepId
                    Adapter   = if ([string]::IsNullOrWhiteSpace([string]$slice.AdapterRaw)) { $null } else { [string]$slice.AdapterRaw }
                    AdapterRaw = $slice.AdapterRaw
                    Cycle     = [int]$slice.Cycle
                    Terminal  = [bool]$slice.Terminal
                    AcRefs    = [string[]](script:Split-FSCInlineList -Value $slice.AcRefsRaw)
                    DependsOn = [string[]](script:Split-FSCInlineList -Value $slice.DependsRaw)
                }) | Out-Null
        }

        return [pscustomobject]@{
            GeneratedAt   = $generatedAt
            CanonicalYaml = $SpineBlock
            Ports         = $ports
            Slices        = [object[]]$slices.ToArray()
            Metadata      = [pscustomobject]@{
                PortKeys      = [string[]]$portRawValues.Keys
                PortRawValues = $portRawValues
                SliceIds      = [string[]]$sliceOrder.ToArray()
                SliceByStepId = $sliceByStepId
            }
        }
    }
    catch {
        return $null
    }
}

function Get-FSCSpineBlock {
    param([AllowNull()][string]$CommentBody)

    $blocks = @(script:Get-FSCCommentBlockPayloads -CommentBody $CommentBody -BlockName 'frame-spine')
    if ($blocks.Count -eq 0) { return $null }
    return $blocks[0]
}

function Get-FSCSliceBlocksByStepId {
    param(
        [AllowNull()][string]$CommentBody,
        [Parameter(Mandatory)][string]$StepId
    )

    $matchingBlocks = [System.Collections.Generic.List[string]]::new()
    foreach ($block in @(script:Get-FSCCommentBlockPayloads -CommentBody $CommentBody -BlockName 'frame-slice')) {
        $value = script:Get-FSCScalarValue -Block $block -Name 'step_id'
        if ($null -eq $value) { $value = script:Get-FSCScalarValue -Block $block -Name 'id' }
        if ($value -eq $StepId) { $matchingBlocks.Add($block) | Out-Null }
    }

    return $matchingBlocks.ToArray()
}

function Get-FSCSliceBlocksByPort {
    param(
        [AllowNull()][string]$CommentBody,
        [Parameter(Mandatory)][string]$PortName
    )

    $matchingBlocks = [System.Collections.Generic.List[string]]::new()
    foreach ($block in @(script:Get-FSCCommentBlockPayloads -CommentBody $CommentBody -BlockName 'frame-slice')) {
        $portsValue = script:Get-FSCScalarValue -Block $block -Name 'ports'
        if ($null -eq $portsValue) { $portsValue = script:Get-FSCScalarValue -Block $block -Name 'provides' }
        if ($null -eq $portsValue) { continue }

        $ports = script:Split-FSCInlineList -Value $portsValue
        if ($null -eq $ports) { continue }
        if ($ports -contains $PortName) { $matchingBlocks.Add($block) | Out-Null }
    }

    return $matchingBlocks.ToArray()
}

function Test-FSCCanonicalForm {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$SpineBlock)

    $parsed = script:ConvertFrom-FSCSpineYamlInternal -SpineBlock $SpineBlock
    if ($null -eq $parsed) { return $false }

    $portKeys = [string[]]$parsed.Metadata.PortKeys
    $sortedPortKeys = [string[]]@($portKeys)
    [array]::Sort($sortedPortKeys, [System.StringComparer]::Ordinal)
    if (-not (script:Test-FSCStringSequenceEqual -Left $portKeys -Right $sortedPortKeys)) {
        return $false
    }

    foreach ($portName in $parsed.Metadata.PortRawValues.Keys) {
        if (-not ([string]$parsed.Metadata.PortRawValues[$portName]).StartsWith('[')) { return $false }
    }

    foreach ($stepId in $parsed.Metadata.SliceIds) {
        $slice = $parsed.Metadata.SliceByStepId[$stepId]
        if (-not ([string]$slice.AcRefsRaw).StartsWith('[')) { return $false }
        if (-not ([string]$slice.DependsRaw).StartsWith('[')) { return $false }
    }

    return $true
}

function ConvertFrom-FSCSpineYaml {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$SpineBlock)

    $parsed = script:ConvertFrom-FSCSpineYamlInternal -SpineBlock $SpineBlock
    if ($null -eq $parsed) { return $null }

    return [pscustomobject]@{
        GeneratedAt   = $parsed.GeneratedAt
        CanonicalYaml = $parsed.CanonicalYaml
        Ports         = $parsed.Ports
        Slices        = $parsed.Slices
    }
}

function Resolve-FSCCommentBodyPath {
    param([Parameter(Mandatory)][string]$CommentBodyPath)

    try {
        return (Resolve-Path -LiteralPath $CommentBodyPath -ErrorAction Stop).Path
    }
    catch {
        if ($CommentBodyPath -notmatch '^TestDrive:[\\/](?<leaf>[^\\/]+)$') { throw }

        $leafName = $Matches['leaf']
        $tempRoot = [System.IO.Path]::GetTempPath()
        $match = Get-ChildItem -LiteralPath $tempRoot -Filter $leafName -File -Recurse -Depth 4 -ErrorAction SilentlyContinue |
            Sort-Object -Property LastWriteTimeUtc -Descending |
            Select-Object -First 1

        if ($null -eq $match) { throw }
        return $match.FullName
    }
}

function script:ConvertTo-FSCSpineLookupJsonLines {
    param([Parameter(Mandatory)][hashtable]$Data)

    $json = $Data | ConvertTo-Json -Compress -Depth 5
    return [string[]]@($json)
}

function Invoke-FSCSpineLookupCli {
    param(
        [Parameter(ParameterSetName = 'ByPath', Mandatory)]
        [string]$CommentBodyPath,
        [Parameter(ParameterSetName = 'ByStdin', Mandatory)]
        [switch]$CommentBodyStdin,
        [ValidateSet('Text', 'Json')]
        [string]$Format = 'Text',
        [Parameter(Mandatory)][string]$GeneratedAt,
        [Parameter(Mandatory)][string]$StepId
    )

    $lines = [System.Collections.Generic.List[string]]::new()

    # Wrapper-level codes (gh-not-installed, gh-auth-expired, gh-rate-limited) are surfaced by
    # platforms/{tool}.md wrappers, not this script.
    if ($CommentBodyStdin) {
        [Console]::InputEncoding = [System.Text.Encoding]::UTF8
        $commentBody = [Console]::In.ReadToEnd()
    }
    else {
        $resolvedCommentBodyPath = Resolve-FSCCommentBodyPath -CommentBodyPath $CommentBodyPath
        if (-not [System.IO.File]::Exists($resolvedCommentBodyPath)) {
            $lines.Add("error: CommentBodyPath not found: $CommentBodyPath") | Out-Null
            return [pscustomobject]@{ ExitCode = 1; Lines = [string[]]$lines.ToArray() }
        }
        $commentBody = [System.IO.File]::ReadAllText($resolvedCommentBodyPath)
    }

    $spineBlock = Get-FSCSpineBlock -CommentBody $commentBody
    if ($null -eq $spineBlock) {
        if ($Format -eq 'Json') {
            return [pscustomobject]@{ ExitCode = 1; Lines = script:ConvertTo-FSCSpineLookupJsonLines -Data @{ status = 'missing-spine' } }
        }
        $lines.Add('status: missing-spine') | Out-Null
        return [pscustomobject]@{ ExitCode = 1; Lines = [string[]]$lines.ToArray() }
    }

    $parsedSpine = ConvertFrom-FSCSpineYaml -SpineBlock $spineBlock
    if ($null -eq $parsedSpine) {
        if ($Format -eq 'Json') {
            return [pscustomobject]@{ ExitCode = 1; Lines = script:ConvertTo-FSCSpineLookupJsonLines -Data @{ status = 'invalid-spine' } }
        }
        $lines.Add('status: invalid-spine') | Out-Null
        return [pscustomobject]@{ ExitCode = 1; Lines = [string[]]$lines.ToArray() }
    }

    $currentGeneratedAt = script:Get-FSCScalarValue -Block $spineBlock -Name 'generated_at'
    if ($currentGeneratedAt -ne $GeneratedAt) {
        if ($Format -eq 'Json') {
            return [pscustomobject]@{ ExitCode = 0; Lines = script:ConvertTo-FSCSpineLookupJsonLines -Data @{
                status                  = 'stale-spine'
                dispatched_generated_at = $GeneratedAt
                current_generated_at    = $currentGeneratedAt
            } }
        }
        $lines.Add('status: stale-spine') | Out-Null
        $lines.Add("dispatched_generated_at: $GeneratedAt") | Out-Null
        $lines.Add("current_generated_at: $currentGeneratedAt") | Out-Null
        return [pscustomobject]@{ ExitCode = 0; Lines = [string[]]$lines.ToArray() }
    }

    $sliceBlocks = @(Get-FSCSliceBlocksByStepId -CommentBody $commentBody -StepId $StepId)
    if ($sliceBlocks.Count -eq 0) {
        if ($Format -eq 'Json') {
            return [pscustomobject]@{ ExitCode = 1; Lines = script:ConvertTo-FSCSpineLookupJsonLines -Data @{
                status  = 'missing-slice'
                step_id = $StepId
            } }
        }
        $lines.Add('status: missing-slice') | Out-Null
        $lines.Add("step_id: $StepId") | Out-Null
        return [pscustomobject]@{ ExitCode = 1; Lines = [string[]]$lines.ToArray() }
    }

    if ($Format -eq 'Json') {
        $sliceContent = script:ConvertTo-FSCNormalizedText -Text $sliceBlocks[0]
        return [pscustomobject]@{ ExitCode = 0; Lines = script:ConvertTo-FSCSpineLookupJsonLines -Data @{
            status       = 'ok'
            step_id      = $StepId
            generated_at = $GeneratedAt
            slice        = $sliceContent
        } }
    }

    $lines.Add('status: ok') | Out-Null
    $lines.Add("step_id: $StepId") | Out-Null
    $lines.Add('slice: |') | Out-Null
    foreach ($line in @((script:ConvertTo-FSCNormalizedText -Text $sliceBlocks[0]) -split "`n")) {
        $lines.Add("  $line") | Out-Null
    }

    return [pscustomobject]@{ ExitCode = 0; Lines = [string[]]$lines.ToArray() }
}

function Invoke-FSCCommand {
    param(
        [ValidateSet('Lookup')]
        [string]$Op,
        [Parameter(ParameterSetName = 'ByPath')]
        [string]$CommentBodyPath,
        [Parameter(ParameterSetName = 'ByStdin')]
        [switch]$CommentBodyStdin,
        [ValidateSet('Text', 'Json')]
        [string]$Format = 'Text',
        [string]$GeneratedAt,
        [string]$StepId
    )

    switch ($Op) {
        'Lookup' {
            $splat = @{
                GeneratedAt = $GeneratedAt
                StepId      = $StepId
                Format      = $Format
            }
            if ($CommentBodyStdin) { $splat['CommentBodyStdin'] = $true }
            else { $splat['CommentBodyPath'] = $CommentBodyPath }
            return (Invoke-FSCSpineLookupCli @splat)
        }
        default {
            return [pscustomobject]@{
                ExitCode = 1
                Lines    = [string[]]@("error: Unsupported frame spine operation: $Op")
            }
        }
    }
}

if ($MyInvocation.InvocationName -ne '.' -and $PSBoundParameters.ContainsKey('Op')) {
    $result = Invoke-FSCCommand @PSBoundParameters
    foreach ($line in @($result.Lines)) { Write-Output $line }
    exit $result.ExitCode
}
