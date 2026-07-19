#Requires -Version 7.0
<#
.SYNOPSIS
    Library for frame adapter validation. Dot-source and call Invoke-FrameValidate.
#>

$script:FVLibDir = Split-Path -Parent $PSCommandPath
. (Join-Path -Path $script:FVLibDir -ChildPath 'frame-shared-discovery.ps1')
. (Join-Path -Path $script:FVLibDir -ChildPath 'frame-spine-core.ps1')
. (Join-Path -Path $script:FVLibDir -ChildPath 'goal-contract-core.ps1')

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

function New-FVStructuralCoverageResult {
    # Shared aggregation tail for both plan-validation paths (legacy frame-spine
    # and the goal-contract variant): turns accumulated structural-violation and
    # warn-only coverage-gap lists into the standard PlanStructuralCoverage /
    # PlanCoverageGap two-row result set. Extracted so the two callers don't
    # hand-roll the same pass/fail wording independently (872-D6's
    # no-hand-rolled-duplication intent, applied here to result assembly).
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][AllowNull()][object[]]$StructuralViolations,
        [Parameter(Mandatory)][AllowEmptyCollection()][AllowNull()][object[]]$CoverageGaps
    )

    # Plain assignment, not an if/else-used-as-expression: PowerShell flattens
    # a single-element array returned as a branch's captured output down to a
    # scalar, which then loses .Count under Set-StrictMode. Assigning inside
    # the if-statement body instead of assigning its result keeps @() intact.
    $violations = [object[]]@()
    if ($null -ne $StructuralViolations) { $violations = @($StructuralViolations) }
    $gaps = [object[]]@()
    if ($null -ne $CoverageGaps) { $gaps = @($CoverageGaps) }

    $results = [System.Collections.Generic.List[PSCustomObject]]::new()
    if ($violations.Count -eq 0) {
        $results.Add((New-FVCheckResult -Name 'PlanStructuralCoverage' -Passed $true -Detail '')) | Out-Null
    }
    else {
        $results.Add((New-FVCheckResult -Name 'PlanStructuralCoverage' -Passed $false -Detail "$($violations.Count) structural violation(s): $($violations -join '; ')")) | Out-Null
    }

    if ($gaps.Count -eq 0) {
        $results.Add((New-FVCheckResult -Name 'PlanCoverageGap' -Passed $true -Detail '')) | Out-Null
    }
    else {
        $results.Add((New-FVCheckResult -Name 'PlanCoverageGap' -Passed $true -Detail "$($gaps.Count) warn-only coverage gap(s): $($gaps -join '; ')")) | Out-Null
    }

    return (New-FVAggregateResult -Results $results.ToArray())
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

    # Issue #878 s6: sibling of frame-spine-core.ps1's Get-FSCCommentBlockPayloads
    # (same top-level-alternation shape, 'frame-slice' hard-coded here rather
    # than parameterized). Same fix: anchor every branch via grouping with
    # `(?m)^[ \t]*(?:A|B)`, not `(?m)^[ \t]*A|B`; `[ \t]*` (not `\s*`) so the
    # anchor cannot cross a newline and shift Match.Index onto a preceding
    # blank line.
    $pattern = '(?m)^[ \t]*(?:<!--\s*frame-slice\s*-->\s*\n(?<payload>.*?)\n\s*-->|<!--\s*frame-slice(?:\s*\n|\s+)(?<payload>.*?)\n?\s*-->)'
    $regexMatches = [regex]::Matches($normalized, $pattern, [System.Text.RegularExpressions.RegexOptions]::Singleline)
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
    $executor = Get-FVPlanScalarField -Block $Block -Names @('executor')
    $adapter = Get-FVPlanScalarField -Block $Block -Names @('adapter')
    $migrationScanRaw = Get-FVPlanScalarField -Block $Block -Names @('migration-scan')
    $migrationScan = ($migrationScanRaw -eq 'true')
    $commitIndexRaw = Get-FVPlanScalarField -Block $Block -Names @('commit-index', 'commit_index')
    $commitIndexParsed = 0
    $commitIndex = if ($null -ne $commitIndexRaw -and [int]::TryParse($commitIndexRaw, [ref]$commitIndexParsed)) { $commitIndexParsed } else { [int]::MaxValue }

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
        Executor          = if ($null -eq $executor) { '' } else { $executor }
        Adapter           = if ($null -eq $adapter) { '' } else { $adapter }
        IsExploratory     = [bool]$isExploratory
        ExploratoryReason = [string]$exploratoryReason
        MigrationScan     = [bool]$migrationScan
        CommitIndex       = [int]$commitIndex
    }
}

function Test-FVExecutorValue {
    param([AllowNull()][string]$Executor)

    if ([string]::IsNullOrWhiteSpace($Executor)) { return $true }

    $normalized = $Executor.Trim() -replace '\\', '/'
    if ($normalized -ceq 'inline') { return $true }

    # TODO(follow-up): define executor: none semantics before accepting `none` here.
    return ($normalized -cmatch '^agents/[^/]+\.agent\.md$')
}

function Test-FVExecutorAdapterCompatibility {
    param(
        [AllowNull()][string]$Executor,
        [AllowNull()][string]$Adapter
    )

    if ([string]::IsNullOrWhiteSpace($Adapter)) { return $true }

    $normalizedExecutor = if ([string]::IsNullOrWhiteSpace($Executor)) { 'agents/Senior-Engineer.agent.md' } else { $Executor.Trim() -replace '\\', '/' }
    $normalizedAdapter = $Adapter.Trim() -replace '\\', '/'

    if ($normalizedExecutor -cne 'agents/Senior-Engineer.agent.md') { return $true }

    return ($normalizedAdapter -cnotmatch '^skills/adversarial-review/adapters/[^/]+\.md$|^skills/[^/]+/adapters/(review|adversarial|critique|challenge)[^/]*-adapter\.md$')
}

function ConvertFrom-FVPlanSpineBlock {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$SpineBlock)

    $canonical = ConvertFrom-FSCSpineYaml -SpineBlock $SpineBlock
    if ($null -eq $canonical) { return $null }

    $ports = [ordered]@{}
    foreach ($portName in @($canonical.Ports.Keys)) {
        $ports[$portName] = [string[]]@($canonical.Ports[$portName] | ForEach-Object { $_.StepId })
    }

    return [PSCustomObject]@{ Ports = $ports }
}

function Test-FVPlanSpineOmittedPlanTooSmall {
    param([AllowNull()][string]$CommentBody)

    $normalized = ConvertTo-FVNormalizedText -Text $CommentBody
    return ($normalized -match '(?m)^\s*spine-omitted\s*:\s*plan-too-small\s*$')
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

function Test-FVMigrationTypePlan {
    param([AllowNull()][string]$PlanBody)
    if ([string]::IsNullOrWhiteSpace($PlanBody)) { return $false }
    # Classifies via literal signals: 'migration-type' (self-declared) or 'exhaustive repo scan'
    # (mandatory Step 1 prose per plan-authoring/SKILL.md § Migration-type issues).
    # NOTE: do NOT add 'migration-scan:' here — that is the enforcement target, not a classifier.
    #
    # This two-token anchor is the ENFORCED-CONTRACT classifier, deliberately narrower
    # than the human-facing signal-phrase trigger list in plan-authoring/SKILL.md
    # § Migration-type issues (which includes "migrate from A to B", "rename Z across
    # the codebase", "replace X with Y", "remove all references to W"). Those loose
    # signal phrases guide a human planner's classification; this validator matches only
    # the self-declared 'migration-type' token or the canonical 'exhaustive repo scan'
    # deliverable phrase, to avoid false-positive enforcement on plans that merely
    # mention migration concepts in prose (see migration-scan-enforcement.Tests.ps1
    # § "does not classify a plan as migration-type when its prose only mentions the
    # marker string").
    return ($PlanBody -imatch 'migration-type|exhaustive repo scan')
}

function Invoke-FVGoalContractPlanValidate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$CommentBody,
        [Parameter(Mandatory)][AllowEmptyString()][string]$ContractPayload,
        [Parameter(Mandatory)][string]$RepoRoot
    )

    if ([string]::IsNullOrWhiteSpace($ContractPayload)) {
        return (New-FVAggregateResult -Results @((New-FVCheckResult -Name 'PlanStructuralCoverage' -Passed $false -Detail 'The <!-- goal-contract --> block is empty; no payload was found between the marker and its terminator.')))
    }

    $converted = ConvertFrom-GCContractBlock -Payload $ContractPayload -RepoRoot $RepoRoot
    if (@($converted.Violations).Count -gt 0) {
        return (New-FVAggregateResult -Results @((New-FVCheckResult -Name 'PlanStructuralCoverage' -Passed $false -Detail "goal-contract schema violation(s): $($converted.Violations -join '; ')")))
    }

    $contract = $converted.Contract
    $structuralViolations = [System.Collections.Generic.List[string]]::new()
    $coverageGaps = [System.Collections.Generic.List[string]]::new()

    # Conditional issue: cross-check -- compared only when a plan-issue-{ID}
    # marker is present in the comment body; skipped otherwise (872-D5).
    $issueMarkerMatch = [regex]::Match($CommentBody, '<!--\s*plan-issue-(?<id>\d+)\s*-->')
    if ($issueMarkerMatch.Success) {
        $markerIssue = 0
        if ([int]::TryParse([string]$issueMarkerMatch.Groups['id'].Value, [ref]$markerIssue)) {
            $contractIssue = 0
            if ([int]::TryParse([string]$contract.issue, [ref]$contractIssue) -and $contractIssue -ne $markerIssue) {
                $structuralViolations.Add("contract issue: $contractIssue does not match the plan-issue-$markerIssue marker.") | Out-Null
            }
        }
    }

    # AC-coverage, forward direction: every target ac_ref must appear in the
    # plan ## Acceptance Criteria section. A missing section entirely
    # produces one clear failure rather than one violation per target.
    $acIds = @(Get-FVPlanAcceptanceCriterionId -CommentBody $CommentBody)
    $acIdSet = [System.Collections.Generic.HashSet[string]]::new([string[]]$acIds, [System.StringComparer]::Ordinal)
    $targetAcRefs = @($contract.targets | ForEach-Object { [string]$_.ac_ref })
    $hasAcSection = ($CommentBody -match '(?m)^##\s+Acceptance Criteria\s*$')

    if (-not $hasAcSection) {
        $structuralViolations.Add("Plan is missing a ## Acceptance Criteria section; cannot verify ac_ref membership for $($targetAcRefs.Count) target(s).") | Out-Null
    }
    else {
        foreach ($acRef in @($targetAcRefs | Select-Object -Unique)) {
            if (-not $acIdSet.Contains($acRef)) {
                $structuralViolations.Add("target ac_ref '$acRef' has no matching ## Acceptance Criteria entry.") | Out-Null
            }
        }
    }

    # AC-coverage, reverse direction: warn-only, mirrors the spine path.
    $targetAcRefSet = [System.Collections.Generic.HashSet[string]]::new([string[]]$targetAcRefs, [System.StringComparer]::Ordinal)
    foreach ($acId in $acIds) {
        if (-not $targetAcRefSet.Contains($acId)) {
            $coverageGaps.Add("coverage-gap: acceptance criterion $acId has no contract target ac_ref coverage.") | Out-Null
        }
    }

    return (New-FVStructuralCoverageResult -StructuralViolations $structuralViolations -CoverageGaps $coverageGaps)
}

function Invoke-FVPlanValidate {
    [CmdletBinding()]
    param(
        [AllowNull()][string]$CommentFile,
        [AllowNull()][string]$CommentText
    )

    $commentBody = Get-FVPlanCommentText -CommentFile $CommentFile -CommentText $CommentText

    # 872-D5: variant detection is hoisted ABOVE the frame-spine null-check
    # below (which otherwise short-circuits straight into spine validation
    # and can never see a both-blocks plan). Detection is frontmatter-
    # anchored (Test-GCVariantFrontmatter), never a body-wide line match, so
    # a plan that merely quotes the literal in prose is not misclassified.
    $isGoalContractVariant = Test-GCVariantFrontmatter -CommentBody $commentBody
    $spineBlock = Get-FSCSpineBlock -CommentBody $commentBody
    $contractPayload = Get-GCContractBlock -CommentBody $commentBody

    if ($isGoalContractVariant) {
        if ($null -ne $spineBlock) {
            return (New-FVAggregateResult -Results @((New-FVCheckResult -Name 'PlanStructuralCoverage' -Passed $false -Detail 'Ambiguous plan: declares plan-variant: goal-contract frontmatter and also carries a frame-spine block; a plan must use exactly one mechanism.')))
        }

        if ($null -eq $contractPayload) {
            return (New-FVAggregateResult -Results @((New-FVCheckResult -Name 'PlanStructuralCoverage' -Passed $false -Detail 'Plan declares plan-variant: goal-contract frontmatter but no <!-- goal-contract --> contract block was found (or more than one was found).')))
        }

        $repoRoot = Resolve-FVRootPath -RootPath $null
        return (Invoke-FVGoalContractPlanValidate -CommentBody $commentBody -ContractPayload $contractPayload -RepoRoot $repoRoot)
    }

    if ($null -eq $spineBlock) {
        if ($null -ne $contractPayload) {
            return (New-FVAggregateResult -Results @((New-FVCheckResult -Name 'PlanStructuralCoverage' -Passed $false -Detail 'Plan carries a <!-- goal-contract --> contract block but is missing plan-variant: goal-contract frontmatter.')))
        }

        if (Test-FVPlanSpineOmittedPlanTooSmall -CommentBody $commentBody) {
            $legacyResults = [System.Collections.Generic.List[PSCustomObject]]::new()
            $legacyResults.Add((New-FVCheckResult -Name 'PlanStructuralCoverage' -Passed $true -Detail 'spine-omitted: plan-too-small')) | Out-Null
            if (Test-FVMigrationTypePlan -PlanBody $commentBody) {
                $firstStepHasScan = ($commentBody -imatch '(?m)^\s*1\.\s+.*?(?:exhaustive\s+(?:repo\s+)?scan|authoritative\s+(?:file\s+)?list)')
                if (-not $firstStepHasScan) {
                    $legacyResults.Add((New-FVCheckResult -Name 'PlanCoverageGap' -Passed $true -Detail 'coverage-gap: migration-type legacy plan — Step 1 should be an exhaustive repo scan producing the authoritative file list.')) | Out-Null
                }
            }
            return (New-FVAggregateResult -Results $legacyResults.ToArray())
        }

        return (New-FVAggregateResult -Results @((New-FVCheckResult -Name 'PlanStructuralCoverage' -Passed $false -Detail 'Missing frame-spine block.')))
    }

    # 872-D5 row 4 carve-out (post-review finding M3): the six-row state
    # matrix's row 4 — (no variant frontmatter, spine block present, contract
    # block present) -> fail: "contract block without variant metadata" — is
    # intentionally NOT enforced on this branch (spine present). The check
    # above at line ~557-559 only fires when $spineBlock is $null; a stray
    # $contractPayload found alongside a present $spineBlock falls through
    # silently to ordinary spine validation below. This is deliberate, not an
    # oversight: Get-GCContractBlock is markdown-blind (cannot tell a real
    # contract block from one quoted inside a fenced documentation example),
    # so naively extending this check to the spine-present case would flag
    # any frame-spine plan whose prose includes a fenced goal-contract
    # authoring example as a structural failure. The regression this would
    # cause is pinned by the existing false-positive guard test at
    # .github/scripts/Tests/frame-validate-plan-mode.Tests.ps1:617 ("does not
    # trip the contract-block-without-variant-metadata row for a frame-spine
    # plan whose prose contains a fenced goal-contract example block"). See
    # skills/plan-authoring/SKILL.md's Goal-contract plan variant section for
    # the reconciliation note on this accepted carve-out.
    $spine = ConvertFrom-FVPlanSpineBlock -SpineBlock $spineBlock
    if ($null -eq $spine) {
        return (New-FVAggregateResult -Results @((New-FVCheckResult -Name 'PlanStructuralCoverage' -Passed $false -Detail 'Invalid canonical frame-spine block.')))
    }

    $slices = @(
        foreach ($block in @(Get-FVPlanSliceBlock -CommentBody $commentBody)) {
            ConvertFrom-FVPlanSliceBlock -Block $block
        }
    )
    $slices = @($slices | Sort-Object CommitIndex)

    $sliceByStepId = @{}
    foreach ($slice in $slices) {
        if (-not $sliceByStepId.ContainsKey($slice.StepId)) { $sliceByStepId[$slice.StepId] = $slice }
    }

    $structuralViolations = [System.Collections.Generic.List[string]]::new()
    $coverageGaps = [System.Collections.Generic.List[string]]::new()

    foreach ($slice in $slices) {
        if (-not (Test-FVExecutorValue -Executor $slice.Executor)) {
            $structuralViolations.Add("step $($slice.StepId) has invalid executor '$($slice.Executor)'; expected absent executor, agents/*.agent.md path, or inline. executor: none is deferred.") | Out-Null
        }

        if (-not (Test-FVExecutorAdapterCompatibility -Executor $slice.Executor -Adapter $slice.Adapter)) {
            $structuralViolations.Add("step $($slice.StepId) pairs adversarial-pattern adapter '$($slice.Adapter)' with default Senior Engineer executor; use an independent adversarial reviewer executor or inline review path.") | Out-Null
        }

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

    # Migration-scan enforcement: for plans that declare themselves migration-type, assert
    # the first implementation slice carries migration-scan: true and uses a real port.
    if ($slices.Count -gt 0 -and (Test-FVMigrationTypePlan -PlanBody $commentBody)) {
        $firstSlice = $slices[0]
        if (-not $firstSlice.MigrationScan) {
            $structuralViolations.Add("migration-type plan: slice $($firstSlice.StepId) (first implementation step) must carry migration-scan: true in its <!-- frame-slice --> comment block.") | Out-Null
        }
        elseif ($firstSlice.IsExploratory) {
            $structuralViolations.Add("migration-type plan: slice $($firstSlice.StepId) has migration-scan: true but uses coverage: exploratory; the exhaustive scan is a deterministic deliverable — use a real provides: port instead.") | Out-Null
        }
        for ($i = 1; $i -lt $slices.Count; $i++) {
            if ($slices[$i].MigrationScan) {
                $structuralViolations.Add("migration-type plan: migration-scan: true is only valid on the first implementation slice (step $($slices[0].StepId)); found on step $($slices[$i].StepId).") | Out-Null
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

    return (New-FVStructuralCoverageResult -StructuralViolations $structuralViolations -CoverageGaps $coverageGaps)
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
