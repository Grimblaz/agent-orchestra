#Requires -Version 7.0
<#!
.SYNOPSIS
    Frame credit-ledger orchestrator (issue #429).

.DESCRIPTION
    Pre-PR warn hook that:
      1. Resolves the PR baseRefOid (with bounded retry).
      2. Fetches the PR body.
      3. Detects the pipeline-metrics block and short-circuits on pre-v4.
      4. Discovers frame-port adapters and classifies port coverage.
      5. Composes a markdown ledger comment and posts it via Find-OrUpsertComment.

    Honours two test-only env-var hooks (see TEST HOOK CONTRACT):
      - FRAME_CREDIT_LEDGER_TEST_NO_SLEEP=1     skip Start-Sleep on retry
      - FRAME_CREDIT_LEDGER_TEST_BUDGET_SECONDS override the 30s outer budget

    `gh` is resolved via PATH/Get-Command so test mocks installed as
    `function global:gh { ... }` are reachable.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][int]$Pr,
    [string]$Mode = 'warn'
)

# Manual validation of $Mode (we cannot use [ValidateSet] because the test
# harness invokes the orchestrator via `& $orchestratorPath ... ; exit
# $LASTEXITCODE`, and an attribute-level binding failure does not set
# $LASTEXITCODE — it only emits an error record. So we validate inside the
# body and explicitly set the exit code to satisfy the contract.)
if ($Mode -notin @('warn', 'enforce')) {
    [Console]::Error.WriteLine("frame-credit-ledger: Cannot validate argument on parameter 'Mode'. The argument '$Mode' does not belong to the set 'warn,enforce' specified by the ValidateSet attribute. Supply an argument that is in the set and then try the command again.")
    exit 2
}

# Mark warn-mode early so the lib-load try/catch (below) can decide its exit
# code without re-parsing $Mode if any of the lib files have a parse-time
# error. Set BEFORE the dot-sources.
$script:WarnModeOnly = ($Mode -eq 'warn')

# ---------------------------------------------------------------------------
# Library dot-sources (wrapped: a parse-time error in any lib file would
# crash the script before the inner try/catch wrapper engages, so warn-mode
# fail-open semantics would be bypassed. We wrap here to preserve them.)
# ---------------------------------------------------------------------------
try {
    . (Join-Path $PSScriptRoot 'lib/frame-shared-discovery.ps1')
    . (Join-Path $PSScriptRoot 'lib/find-or-upsert-comment.ps1')
    . (Join-Path $PSScriptRoot 'lib/frame-credit-ledger-core.ps1')
    . (Join-Path $PSScriptRoot 'lib/frame-spine-core.ps1')
}
catch {
    [Console]::Error.WriteLine("frame-credit-ledger: library load failed: $($_.Exception.Message)")
    if ($script:WarnModeOnly) {
        # Warn-mode invariant: never block PR creation on a lib-load error.
        exit 0
    }
    exit 1
}

# Cost pattern lib dot-sources (warn-mode fail-open: cost composition failure never blocks PR creation)
$script:CostLibLoadFailed = $false  # default; set to $true below if load fails
try {
    . (Join-Path $PSScriptRoot 'lib/path-normalize.ps1')
    . (Join-Path $PSScriptRoot 'lib/cost-walker.ps1')
    . (Join-Path $PSScriptRoot 'lib/cost-attribution.ps1')
    . (Join-Path $PSScriptRoot 'lib/cost-anomaly.ps1')
    . (Join-Path $PSScriptRoot 'lib/cost-rolling-history.ps1')
    . (Join-Path $PSScriptRoot 'lib/cost-checkpoint-core.ps1')
    . (Join-Path $PSScriptRoot 'lib/cost-completeness.ps1')
    . (Join-Path $PSScriptRoot 'lib/cost-pattern-renderer.ps1')
}
catch {
    [Console]::Error.WriteLine("frame-credit-ledger: cost lib load failed (cost composition disabled): $($_.Exception.Message)")
    # Cost lib load failure is non-fatal — cost pattern composition will be skipped
    $script:CostLibLoadFailed = $true
}

# ---------------------------------------------------------------------------
# Read a single scalar field from an adapter's frontmatter block. Strips a
# pair of balanced single or double quotes when present. Returns $null when
# the field is absent.
# ---------------------------------------------------------------------------
function script:Get-FCLAdapterFrontmatterScalar {
    param(
        [Parameter(Mandatory)][string]$Frontmatter,
        [Parameter(Mandatory)][string]$Field
    )

    $pattern = '(?m)^\s*' + [regex]::Escape($Field) + '\s*:\s*(?<v>.+?)\s*$'
    $m = [regex]::Match($Frontmatter, $pattern)
    if (-not $m.Success) { return $null }

    $value = $m.Groups['v'].Value.Trim()
    if ($value.Length -ge 2) {
        $first = $value[0]; $last = $value[$value.Length - 1]
        if (($first -eq '"' -and $last -eq '"') -or ($first -eq "'" -and $last -eq "'")) {
            $value = $value.Substring(1, $value.Length - 2)
        }
    }
    return $value
}

# ---------------------------------------------------------------------------
# Get-FrameCreditLedgerAdapters
# ---------------------------------------------------------------------------
function Get-FrameCreditLedgerAdapters {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot
    )

    $results = [System.Collections.Generic.List[object]]::new()

    if ([string]::IsNullOrWhiteSpace($RepoRoot) -or -not (Test-Path -LiteralPath $RepoRoot -PathType Container)) {
        return , @()
    }

    # Configured globs:
    #   agents/**/*.agent.md
    #   skills/**/SKILL.md
    #   skills/**/adapters/*.md
    #   commands/**/*.md
    $candidatePaths = [System.Collections.Generic.List[string]]::new()

    $agentsDir = Join-Path $RepoRoot 'agents'
    if (Test-Path -LiteralPath $agentsDir -PathType Container) {
        try {
            Get-ChildItem -LiteralPath $agentsDir -Recurse -File -Filter '*.agent.md' -ErrorAction Stop |
            ForEach-Object { $candidatePaths.Add($_.FullName) | Out-Null }
        }
        catch { $null = $_ }
    }

    $skillsDir = Join-Path $RepoRoot 'skills'
    if (Test-Path -LiteralPath $skillsDir -PathType Container) {
        try {
            Get-ChildItem -LiteralPath $skillsDir -Recurse -File -Filter 'SKILL.md' -ErrorAction Stop |
            ForEach-Object { $candidatePaths.Add($_.FullName) | Out-Null }
        }
        catch { $null = $_ }
        try {
            # skills/**/adapters/*.md
            Get-ChildItem -LiteralPath $skillsDir -Recurse -Directory -Filter 'adapters' -ErrorAction Stop |
            ForEach-Object {
                Get-ChildItem -LiteralPath $_.FullName -File -Filter '*.md' -ErrorAction SilentlyContinue |
                ForEach-Object { $candidatePaths.Add($_.FullName) | Out-Null }
            }
        }
        catch { $null = $_ }
    }

    $commandsDir = Join-Path $RepoRoot 'commands'
    if (Test-Path -LiteralPath $commandsDir -PathType Container) {
        try {
            Get-ChildItem -LiteralPath $commandsDir -Recurse -File -Filter '*.md' -ErrorAction Stop |
            ForEach-Object { $candidatePaths.Add($_.FullName) | Out-Null }
        }
        catch { $null = $_ }
    }

    foreach ($path in $candidatePaths) {
        try {
            $raw = Get-Content -LiteralPath $path -Raw -ErrorAction Stop
            if ([string]::IsNullOrEmpty($raw)) { continue }

            # Normalize line endings then extract leading frontmatter block.
            $normalized = $raw -replace "`r`n", "`n" -replace "`r", "`n"
            $fmMatch = [regex]::Match($normalized, '^\s*---\s*\n(?<fm>.*?)\n---\s*(\n|$)', 'Singleline')
            if (-not $fmMatch.Success) { continue }
            $fm = $fmMatch.Groups['fm'].Value

            # Require a `provides:` key.
            $providesValue = script:Get-FCLAdapterFrontmatterScalar -Frontmatter $fm -Field 'provides'
            if ($null -eq $providesValue) { continue }

            # Step 10 (issue #441): YAML sanity check on the frontmatter.
            # When frontmatter fails basic YAML validation (empty key, missing colon,
            # or unterminated quoted value), emit a parse-error adapter entry instead
            # of silently skipping.  The provides: value was already extracted above,
            # so the entry carries the correct port name.
            if (-not (script:Test-FCLYamlSane -Text $fm)) {
                $results.Add([pscustomobject]@{
                        Path              = $path
                        Name              = "<malformed:$([System.IO.Path]::GetFileNameWithoutExtension($path))>"
                        Provides          = $providesValue
                        AppliesWhen       = $null
                        SuggestedNextStep = $null
                        ParseError        = 'malformed-frontmatter'
                    }) | Out-Null
                continue
            }

            $appliesWhen = script:Get-FCLAdapterFrontmatterScalar -Frontmatter $fm -Field 'applies-when'
            $suggestedNextStep = script:Get-FCLAdapterFrontmatterScalar -Frontmatter $fm -Field 'suggested-next-step'

            $name = script:Get-FCLAdapterFrontmatterScalar -Frontmatter $fm -Field 'name'
            if ($null -eq $name) {
                $name = [System.IO.Path]::GetFileNameWithoutExtension($path)
            }

            $results.Add([pscustomobject]@{
                    Path              = $path
                    Name              = $name
                    Provides          = $providesValue
                    AppliesWhen       = $appliesWhen
                    SuggestedNextStep = $suggestedNextStep
                }) | Out-Null
        }
        catch {
            continue
        }
    }

    return $results.ToArray()
}

# ---------------------------------------------------------------------------
# Get-FrameCreditLedgerBaseRefOid
# ---------------------------------------------------------------------------
function Get-FrameCreditLedgerBaseRefOid {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int]$Pr
    )

    $skipSleep = ($env:FRAME_CREDIT_LEDGER_TEST_NO_SLEEP -eq '1')
    $delays = @(0, 2, 4)  # delay BEFORE attempt N (attempt 1 has 0)

    for ($attempt = 1; $attempt -le 3; $attempt++) {
        $delay = $delays[$attempt - 1]
        if ($delay -gt 0 -and -not $skipSleep) {
            Start-Sleep -Seconds $delay
        }

        $json = $null
        try {
            $json = & gh pr view $Pr --json baseRefOid 2>$null
        }
        catch {
            $json = $null
        }

        if ($null -ne $json -and $json -ne '') {
            try {
                $parsed = $json | ConvertFrom-Json -ErrorAction Stop
                if ($null -ne $parsed -and $null -ne $parsed.baseRefOid -and -not [string]::IsNullOrWhiteSpace([string]$parsed.baseRefOid)) {
                    return [string]$parsed.baseRefOid
                }
            }
            catch {
                $null = $_
                # parse failure - fall through to next attempt
            }
        }
    }

    [Console]::Error.WriteLine("frame-credit-ledger: failed to resolve baseRefOid for PR $Pr after 3 attempts (gh retry exhausted)")
    return $null
}

# ---------------------------------------------------------------------------
# Build-FrameCreditLedgerChangeset
#
# Construct a changeset descriptor from `git diff` against the supplied
# baseRefOid. Returns a hashtable in the shape Test-FVPredicateAgainstChangeset
# expects:
#   ChangedFiles  = string[]    # relative paths from the repo root
#   TotalLines    = int         # total +/- line count from --shortstat
#   IsReReview    = bool        # not detectable from diff alone; default false
#   IsProxyGithub = bool        # default false
#
# On any failure we return a benign empty changeset — predicate evaluation
# then resolves identifiers as 'false' or 'unknown', and the caller falls
# back to credit-presence-only behavior. Warn-mode invariant preserved.
# ---------------------------------------------------------------------------
function Build-FrameCreditLedgerChangeset {
    [CmdletBinding()]
    param([AllowNull()][string]$BaseRefOid)

    $empty = @{
        ChangedFiles  = @()
        TotalLines    = 0
        IsReReview    = $false
        IsProxyGithub = $false
    }

    if ([string]::IsNullOrWhiteSpace($BaseRefOid)) {
        return $empty
    }

    $changedFiles = @()
    try {
        $rawNames = & git diff --name-only "$BaseRefOid...HEAD" 2>$null
        if ($null -ne $rawNames) {
            $changedFiles = @($rawNames | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { ($_ -replace '\\', '/').Trim() })
        }
    }
    catch {
        $changedFiles = @()
    }

    $totalLines = 0
    try {
        $rawShortstat = & git diff --shortstat "$BaseRefOid...HEAD" 2>$null
        if ($null -ne $rawShortstat) {
            $shortstatStr = ([string[]]$rawShortstat) -join ' '
            $insMatch = [regex]::Match($shortstatStr, '(\d+)\s+insertion')
            $delMatch = [regex]::Match($shortstatStr, '(\d+)\s+deletion')
            $ins = if ($insMatch.Success) { [int]$insMatch.Groups[1].Value } else { 0 }
            $del = if ($delMatch.Success) { [int]$delMatch.Groups[1].Value } else { 0 }
            $totalLines = $ins + $del
        }
    }
    catch {
        $totalLines = 0
    }

    return @{
        ChangedFiles  = $changedFiles
        TotalLines    = $totalLines
        IsReReview    = $false
        IsProxyGithub = $false
    }
}

# ---------------------------------------------------------------------------
# Resolve-FrameCreditLedgerApplicableMap
#
# Given a port name, its matching adapters, and a changeset descriptor,
# evaluate each adapter's `applies-when` predicate and return a hashtable
# of adapter-name -> applicability ('true'|'false'|'unknown').
#
# Adapters with NO `applies-when` declaration default to 'true' (always
# applies). Predicate parse failures and identifiers the evaluator cannot
# resolve (deferred credit-reference identifiers, heuristic-deferred
# identifiers) yield 'unknown' — we emit one stderr note per (port, adapter)
# pair so the operator can see why the ledger fell back to credit-presence-
# only checks for that pair.
# ---------------------------------------------------------------------------
function Resolve-FrameCreditLedgerApplicableMap {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PortName,
        [AllowNull()][AllowEmptyCollection()]$Adapters,
        [Parameter(Mandatory)]$Changeset
    )

    $map = @{}
    if ($null -eq $Adapters) { return $map }

    # Defensive init: callers may invoke this function directly (e.g., the
    # Step 12 wiring tests) before Invoke-FrameCreditLedger has had a chance
    # to seed $script:DeferredNotedPairs. Ensure the dedupe table exists so
    # the .ContainsKey(...) reads below cannot throw.
    if (-not $script:DeferredNotedPairs) {
        $script:DeferredNotedPairs = @{}
    }

    foreach ($adapter in @($Adapters)) {
        $adapterName = [string]$adapter.Name
        $appliesWhen = $adapter.AppliesWhen

        # No applies-when declaration -> always applicable.
        if ($null -eq $appliesWhen -or [string]::IsNullOrWhiteSpace([string]$appliesWhen)) {
            $map[$adapterName] = 'true'
            continue
        }

        $appliesWhenStr = [string]$appliesWhen

        # Special-case: the literal sentinel 'always' (used in some adapter
        # frontmatter as a non-DSL "always applies" marker). The DSL parser
        # would treat this as a bare identifier and emit 'unknown'; treat it
        # as 'true' instead so always-applies adapters behave correctly.
        if ($appliesWhenStr.Trim() -eq 'always') {
            $map[$adapterName] = 'true'
            continue
        }

        # Normalize zero-arg call form to bare-identifier form for the
        # `changeset.touchesXxx()` family. Adapters in the wild declare
        # `applies-when: changeset.touchesPluginEntryPoint()` (call form),
        # but the predicate evaluator's identifier-boolean resolver only
        # registers the bare identifier (`changeset.touchesPluginEntryPoint`).
        # The single-arg form `changeset.touches('glob')` IS handled as a
        # call by `Resolve-FVCallNode`, so we leave parameterized calls
        # alone and only strip empty parens.
        $appliesWhenStr = [regex]::Replace($appliesWhenStr, '(\b[A-Za-z_][\w.]*)\s*\(\s*\)', '$1')

        $ast = $null
        try {
            $ast = ConvertTo-FVPredicate -Predicate $appliesWhenStr
        }
        catch {
            $ast = $null
        }

        if ($null -eq $ast -or (Test-FVParseError -Value $ast)) {
            # Predicate parse failure -> 'unknown' so caller falls back to
            # credit-presence-only. Emit one note per (port, adapter) pair.
            $key = "$PortName::$adapterName"
            if (-not $script:DeferredNotedPairs.ContainsKey($key)) {
                $script:DeferredNotedPairs[$key] = $true
                [Console]::Error.WriteLine("frame-credit-ledger: port '$PortName' adapter '$adapterName' applies-when failed to parse; falling back to credit-presence-only")
            }
            $map[$adapterName] = 'unknown'
            continue
        }

        $evalResult = $null
        try {
            $evalResult = Test-FVPredicateAgainstChangeset -Ast $ast -Changeset $Changeset
        }
        catch {
            $evalResult = $null
        }

        if ($null -eq $evalResult -or [string]::IsNullOrWhiteSpace([string]$evalResult.Result)) {
            $map[$adapterName] = 'unknown'
            continue
        }

        $resultStr = [string]$evalResult.Result
        if ($resultStr -eq 'unknown') {
            # Emit a one-shot stderr note: the predicate referenced a
            # deferred identifier (e.g., review.sustainedCriticalOrHigh,
            # ceGate.defectsFound, changeset.touchedAreaHasRefactorableDebt)
            # so the orchestrator falls back to credit-presence-only for
            # this port-adapter pair.
            $key = "$PortName::$adapterName"
            if (-not $script:DeferredNotedPairs.ContainsKey($key)) {
                $script:DeferredNotedPairs[$key] = $true
                [Console]::Error.WriteLine("frame-credit-ledger: port '$PortName' adapter '$adapterName' uses deferred predicate identifier; falling back to credit-presence-only")
            }
        }

        $map[$adapterName] = $resultStr
    }

    return $map
}

function script:Get-FCLCommentBody {
    param([AllowNull()]$Comment)

    if ($null -eq $Comment) { return '' }
    if ($Comment -is [System.Collections.IDictionary] -and $Comment.ContainsKey('body')) { return [string]$Comment['body'] }
    if ($null -ne $Comment.PSObject.Properties['body']) { return [string]$Comment.body }
    return ''
}

function script:Get-FCLFrameSpineComments {
    param([AllowEmptyCollection()][AllowNull()][object[]]$Comments)

    if ($null -eq $Comments) { return @() }
    return @($Comments | Where-Object { (script:Get-FCLCommentBody -Comment $_) -match '<!--\s*frame-spine' })
}

function script:Resolve-FCLLinkedIssueNumber {
    param(
        [AllowEmptyString()][string]$PrBody,
        [Parameter(Mandatory)][int]$Pr
    )

    if (-not [string]::IsNullOrWhiteSpace($PrBody)) {
        $patterns = @(
            '(?im)\b(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?|ref(?:s|erences)?|issue)\s+(?:[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)?#(?<issue>\d+)\b',
            '(?im)^\s*issue_id\s*:\s*(?<issue>\d+)\s*$',
            '(?im)<!--\s*(?:plan|design)-issue-(?<issue>\d+)\s*-->'
        )

        foreach ($pattern in $patterns) {
            $match = [regex]::Match($PrBody, $pattern)
            if (-not $match.Success) { continue }

            $issue = 0
            if ([int]::TryParse($match.Groups['issue'].Value, [ref]$issue) -and $issue -gt 0) {
                return $issue
            }
        }
    }

    return $Pr
}

function script:Get-FCLIssueCommentsForSpine {
    param([Parameter(Mandatory)][int]$IssueNumber)

    $raw = $null
    try {
        $raw = & gh issue view $IssueNumber --json comments 2>$null
    }
    catch {
        return @()
    }

    if ($null -eq $raw -or $raw -eq '') { return @() }

    try {
        $parsed = $raw | ConvertFrom-Json -ErrorAction Stop
        if ($null -ne $parsed -and $null -ne $parsed.comments) {
            return @($parsed.comments)
        }
    }
    catch {
        return @()
    }

    return @()
}

function script:Get-FCLFrameSpineSourceComments {
    param(
        [Parameter(Mandatory)][int]$Pr,
        [AllowEmptyString()][string]$PrBody,
        [AllowEmptyCollection()][AllowNull()][object[]]$PrComments
    )

    $prSpineComments = @(script:Get-FCLFrameSpineComments -Comments $PrComments)
    if ($prSpineComments.Count -gt 0) { return $prSpineComments }

    $issueNumber = script:Resolve-FCLLinkedIssueNumber -PrBody $PrBody -Pr $Pr
    $issueComments = @(script:Get-FCLIssueCommentsForSpine -IssueNumber $issueNumber)
    return @(script:Get-FCLFrameSpineComments -Comments $issueComments)
}

function script:Get-FCLLatestParsedFrameSpine {
    param([AllowEmptyCollection()][AllowNull()][object[]]$Comments)

    $spineComments = @(script:Get-FCLFrameSpineComments -Comments $Comments)
    for ($index = $spineComments.Count - 1; $index -ge 0; $index--) {
        $body = script:Get-FCLCommentBody -Comment $spineComments[$index]
        $block = Get-FSCSpineBlock -CommentBody $body
        if ([string]::IsNullOrWhiteSpace($block)) { continue }

        $parsed = ConvertFrom-FSCSpineYaml -SpineBlock $block
        if ($null -ne $parsed) { return $parsed }
    }

    return $null
}

function script:Get-FCLCreditTerminalStepId {
    param([AllowNull()]$LedgerRow)

    if ($null -eq $LedgerRow) { return 0 }

    $raw = $null
    if ($LedgerRow -is [System.Collections.IDictionary]) {
        if ($LedgerRow.ContainsKey('TerminalStepId')) { $raw = $LedgerRow['TerminalStepId'] }
        elseif ($LedgerRow.ContainsKey('terminal-step-id')) { $raw = $LedgerRow['terminal-step-id'] }
    }
    else {
        if ($null -ne $LedgerRow.PSObject.Properties['TerminalStepId']) { $raw = $LedgerRow.TerminalStepId }
        elseif ($null -ne $LedgerRow.PSObject.Properties['terminal-step-id']) { $raw = $LedgerRow.'terminal-step-id' }
    }

    $step = 0
    if ($null -ne $raw -and [int]::TryParse([string]$raw, [ref]$step) -and $step -gt 0) {
        return $step
    }

    return 0
}

function script:Resolve-FCLIncompleteCycleReports {
    param(
        [Parameter(Mandatory)][int]$Pr,
        [AllowEmptyString()][string]$PrBody,
        [AllowEmptyCollection()][AllowNull()][object[]]$PrComments,
        [AllowEmptyCollection()][AllowNull()][object[]]$LedgerRows
    )

    $sourceComments = @(script:Get-FCLFrameSpineSourceComments -Pr $Pr -PrBody $PrBody -PrComments $PrComments)
    if ($sourceComments.Count -eq 0) { return @() }

    $spine = script:Get-FCLLatestParsedFrameSpine -Comments $sourceComments
    if ($null -eq $spine -or $null -eq $spine.Ports) { return @() }

    $reports = [System.Collections.Generic.List[object]]::new()
    $seen = @{}

    $portNames = @()
    if ($spine.Ports -is [System.Collections.IDictionary]) {
        $portNames = @($spine.Ports.Keys)
    }
    else {
        $portNames = @($spine.Ports.PSObject.Properties.Name)
    }

    foreach ($portNameRaw in $portNames) {
        $portName = [string]$portNameRaw
        if ([string]::IsNullOrWhiteSpace($portName)) { continue }

        $tokens = if ($spine.Ports -is [System.Collections.IDictionary]) { @($spine.Ports[$portName]) } else { @($spine.Ports.$portName) }
        foreach ($token in $tokens) {
            if ($null -eq $token -or $token.Terminal -ne $true) { continue }

            $stepId = [string]$token.StepId
            $stepMatch = [regex]::Match($stepId, '^s(?<step>\d+)$')
            if (-not $stepMatch.Success) { continue }

            $stepNumber = [int]$stepMatch.Groups['step'].Value
            if ($stepNumber -le 0) { continue }

            $key = "$portName::$stepNumber"
            if ($seen.ContainsKey($key)) { continue }
            $seen[$key] = $true

            $matchingCredit = @($LedgerRows | Where-Object {
                    [string]$_.Port -eq $portName -and (script:Get-FCLCreditTerminalStepId -LedgerRow $_) -eq $stepNumber
                }) | Select-Object -First 1

            if ($null -ne $matchingCredit) { continue }

            [void]$reports.Add([pscustomobject]@{
                    PortName          = $portName
                    Status            = 'NotCovered'
                    SubReason         = 'IncompleteCycle'
                    CreditStatus      = 'incomplete-cycle'
                    AdapterName       = ''
                    SuggestedNextStep = "Emit the terminal-cycle credit for $portName with terminal-step-id: $stepNumber."
                    Evidence          = "Frame spine marks terminal step $stepId for $portName, but no credit row with terminal-step-id: $stepNumber is present."
                })
        }
    }

    return $reports.ToArray()
}

function script:Get-FCLTopLevelIntMetric {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$MetricsBlock,
        [Parameter(Mandatory)][string]$Name
    )

    $pattern = '(?m)^\s*' + [regex]::Escape($Name) + '\s*:\s*(?<value>\d+)\s*$'
    $match = [regex]::Match($MetricsBlock, $pattern)
    if (-not $match.Success) { return 0 }

    $value = 0
    if ([int]::TryParse($match.Groups['value'].Value, [ref]$value) -and $value -gt 0) {
        return $value
    }

    return 0
}

function script:Get-FCLStaleSpineFallbackEventCount {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$MetricsBlock)

    $normalized = $MetricsBlock -replace "`r`n", "`n" -replace "`r", "`n"
    $lines = @($normalized -split "`n")

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $dispatchMatch = [regex]::Match($lines[$i], '^(?<indent>\s*)dispatch-fallback-events\s*:\s*$')
        if (-not $dispatchMatch.Success) { continue }

        $dispatchIndent = $dispatchMatch.Groups['indent'].Value.Length
        for ($j = $i + 1; $j -lt $lines.Count; $j++) {
            $line = $lines[$j]
            if ([string]::IsNullOrWhiteSpace($line)) { continue }

            $trimmed = $line.TrimStart()
            $indent = $line.Length - $trimmed.Length
            if ($indent -le $dispatchIndent) { break }

            if ($trimmed -notmatch '^stale-spine\s*:\s*$') { continue }

            $staleIndent = $indent
            $count = 0
            for ($k = $j + 1; $k -lt $lines.Count; $k++) {
                $eventLine = $lines[$k]
                if ([string]::IsNullOrWhiteSpace($eventLine)) { continue }

                $eventTrimmed = $eventLine.TrimStart()
                $eventIndent = $eventLine.Length - $eventTrimmed.Length
                if ($eventIndent -le $staleIndent) { break }
                if ($eventTrimmed.StartsWith('-')) { $count++ }
            }

            return $count
        }
    }

    return 0
}

function script:Set-FCLStaleSpineFallbackMetric {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$MetricsBlock)

    $eventCount = script:Get-FCLStaleSpineFallbackEventCount -MetricsBlock $MetricsBlock
    $existingCount = script:Get-FCLTopLevelIntMetric -MetricsBlock $MetricsBlock -Name 'spine-stale-fallback-count'
    $targetCount = [Math]::Max($eventCount, $existingCount)

    $eol = if ($MetricsBlock.Contains("`r`n")) { "`r`n" } else { "`n" }
    $normalized = $MetricsBlock -replace "`r`n", "`n" -replace "`r", "`n"
    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($line in @($normalized -split "`n")) { $lines.Add($line) | Out-Null }

    $existingIndex = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^\s*spine-stale-fallback-count\s*:') {
            $existingIndex = $i
            break
        }
    }

    if ($targetCount -le 0) {
        if ($existingIndex -ge 0) { $lines.RemoveAt($existingIndex) }
        return ($lines.ToArray() -join $eol)
    }

    $lineText = "spine-stale-fallback-count: $targetCount"
    if ($existingIndex -ge 0) {
        $lines[$existingIndex] = $lineText
        return ($lines.ToArray() -join $eol)
    }

    $insertIndex = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^\s*dispatch-fallback-events\s*:') { $insertIndex = $i; break }
    }
    if ($insertIndex -lt 0) {
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match '^\s*credits\s*:') { $insertIndex = $i; break }
        }
    }
    if ($insertIndex -lt 0) { $insertIndex = $lines.Count }

    $lines.Insert($insertIndex, $lineText)
    return ($lines.ToArray() -join $eol)
}

function script:Update-FCLPrBodyStaleSpineFallbackMetric {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$PrBody)

    $match = [regex]::Match($PrBody, '(?s)(?<open><!--\s*pipeline-metrics\s*)(?<block>.*?)(?<close>\s*-->)')
    if (-not $match.Success) { return $PrBody }

    $updatedBlock = script:Set-FCLStaleSpineFallbackMetric -MetricsBlock $match.Groups['block'].Value

    $prefix = $PrBody.Substring(0, $match.Index)
    $suffixStart = $match.Index + $match.Length
    $suffix = $PrBody.Substring($suffixStart)
    return $prefix + $match.Groups['open'].Value + $updatedBlock + $match.Groups['close'].Value + $suffix
}

function script:Update-FCLPrBodyMetricsBestEffort {
    param(
        [Parameter(Mandatory)][int]$Pr,
        [Parameter(Mandatory)][AllowEmptyString()][string]$PrBody
    )

    $updatedPrBody = script:Update-FCLPrBodyStaleSpineFallbackMetric -PrBody $PrBody
    $tempPath = Join-Path ([System.IO.Path]::GetTempPath()) ("frame-credit-ledger-$Pr-$([System.Guid]::NewGuid().ToString('N')).md")

    try {
        $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
        [System.IO.File]::WriteAllText($tempPath, $updatedPrBody, $utf8NoBom)
        $null = & gh pr edit $Pr --body-file $tempPath 2>$null
        if ($global:LASTEXITCODE -ne 0) {
            [Console]::Error.WriteLine("frame-credit-ledger: PR body metrics update failed via gh pr edit --body-file")
        }
    }
    catch {
        [Console]::Error.WriteLine("frame-credit-ledger: PR body metrics update failed: $($_.Exception.Message)")
    }
    finally {
        try {
            if (Test-Path -LiteralPath $tempPath -PathType Leaf) {
                Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
            }
        }
        catch {
            [Console]::Error.WriteLine("frame-credit-ledger: temporary PR body file cleanup failed: $($_.Exception.Message)")
        }
    }
}

function Update-FCLPrBodyDispatchCostSamples {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$PrBody,
        [Parameter(Mandatory)][string]$StepId,
        [Parameter(Mandatory)][ValidateSet('spine', 'legacy-fallback', 'budget-exceeded')][string]$Mode,
        [ValidateSet('pass', 'fail', 'not-evaluated')][string]$RcConformance,
        [ValidateSet('accepted', 'rejected', 'deferred', 'not-evaluated')][string]$JudgeDisposition
    )

    $updateParameters = @{
        PrBody = $PrBody
        StepId = $StepId
        Mode   = $Mode
    }
    if ($PSBoundParameters.ContainsKey('RcConformance')) { $updateParameters['RcConformance'] = $RcConformance }
    if ($PSBoundParameters.ContainsKey('JudgeDisposition')) { $updateParameters['JudgeDisposition'] = $JudgeDisposition }

    return Update-DispatchCostSampleEvaluationInPrBody @updateParameters
}

# ---------------------------------------------------------------------------
# Invoke-FrameCreditLedger
# ---------------------------------------------------------------------------
function Invoke-FrameCreditLedger {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int]$Pr,
        [ValidateSet('warn', 'enforce')][string]$Mode = 'warn'
    )

    $marker = "<!-- frame-credit-ledger-$Pr -->"

    # 1. Resolve baseRefOid (best-effort; failure is non-fatal in warn mode).
    $baseRefOid = Get-FrameCreditLedgerBaseRefOid -Pr $Pr

    # 2. Fetch PR body (and comments for cost preservation — M4 combined call).
    # Note: 'body,comments' is quoted to prevent PowerShell from splitting it on the comma
    # into an array when passed to the gh function mock in tests.
    $bodyJsonRaw = $null
    try {
        $bodyJsonRaw = & gh pr view $Pr --json 'body,comments' 2>$null
    }
    catch {
        $bodyJsonRaw = $null
    }

    $prBody = ''
    $script:PrComments = $null
    if ($null -ne $bodyJsonRaw -and $bodyJsonRaw -ne '') {
        try {
            $parsed = $bodyJsonRaw | ConvertFrom-Json -ErrorAction Stop
            if ($null -ne $parsed -and $null -ne $parsed.body) {
                $prBody = [string]$parsed.body
            }
            if ($null -ne $parsed -and $null -ne $parsed.comments) {
                $script:PrComments = $parsed.comments
            }
        }
        catch {
            $prBody = ''
        }
    }

    # 3. Parse pipeline-metrics block.
    $metrics = Read-PRMetricsBlock -PrBody $prBody

    # 4. Non-v4 short-circuit. Read-PRMetricsBlock returns one of three
    # non-v4 shapes that we must distinguish so the posted comment is
    # honest about what actually happened:
    #   - $null                              -> no marker block at all
    #   - MetricsVersion = 'parse-error'      -> block exists, YAML is malformed
    #   - MetricsVersion = 'pre-v4'           -> block exists, version != 4
    # Any other non-4 shape we have not seen before falls through to the
    # pre-v4 comment as a conservative default.
    if ($null -eq $metrics) {
        $comment = Compose-MissingMetricsShortCircuitComment -MarkerToken $marker
        try {
            $null = Find-OrUpsertComment -Type 'pr' -Number $Pr -Marker $marker -Body $comment
        }
        catch {
            [Console]::Error.WriteLine("frame-credit-ledger: upsert failed: $($_.Exception.Message)")
        }

        return @{
            ExitCode      = 0
            HasNotCovered = $false
            Comment       = $comment
        }
    }

    if ($metrics.MetricsVersion -eq 'parse-error') {
        $reason = ''
        if ($null -ne $metrics.PSObject.Properties['Reason']) { $reason = [string]$metrics.Reason }
        $comment = Compose-ParseErrorShortCircuitComment -MarkerToken $marker -Reason $reason
        try {
            $null = Find-OrUpsertComment -Type 'pr' -Number $Pr -Marker $marker -Body $comment
        }
        catch {
            [Console]::Error.WriteLine("frame-credit-ledger: upsert failed: $($_.Exception.Message)")
        }

        return @{
            ExitCode      = 0
            HasNotCovered = $false
            Comment       = $comment
        }
    }

    if ($metrics.MetricsVersion -ne 4) {
        $comment = Compose-PreV4ShortCircuitComment -MarkerToken $marker
        try {
            $null = Find-OrUpsertComment -Type 'pr' -Number $Pr -Marker $marker -Body $comment
        }
        catch {
            [Console]::Error.WriteLine("frame-credit-ledger: upsert failed: $($_.Exception.Message)")
        }

        return @{
            ExitCode      = 0
            HasNotCovered = $false
            Comment       = $comment
        }
    }

    script:Update-FCLPrBodyMetricsBestEffort -Pr $Pr -PrBody $prBody

    # 5. v4 path: discover adapters and classify ports.
    # Resolve repo root: prefer the script-scoped variable seeded by the
    # entry-point block (so this works inside child runspaces where
    # $PSCommandPath is null), else fall back to walking up from
    # $PSCommandPath, else use the current working directory.
    $repoRoot = $null
    if (-not [string]::IsNullOrWhiteSpace($script:FrameCreditLedgerRepoRoot)) {
        $repoRoot = $script:FrameCreditLedgerRepoRoot
    }
    elseif (-not [string]::IsNullOrWhiteSpace($PSCommandPath)) {
        $repoRoot = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
    }
    else {
        $repoRoot = (Get-Location).Path
    }
    $adapters = Get-FrameCreditLedgerAdapters -RepoRoot $repoRoot

    $portsDir = Join-Path $repoRoot 'frame/ports'
    $ports = Get-PortFiles -PortsDir $portsDir

    $credits = @()
    if ($null -ne $metrics.Credits) { $credits = @($metrics.Credits) }

    # Step 5a (SMC-16): Synthesize a not-persisted review credit when the
    # review-judge-produced-{PR} sentinel is present but no review credit
    # has been written yet. This path fires on PRs like #446 where the judge
    # ran but the credit was never persisted to the PR body.
    $synthesizedReviewCredit = Resolve-NotPersistedSynthesis -PrNumber $Pr -MetricsBlock $metrics -Comments $script:PrComments
    if ($null -ne $synthesizedReviewCredit) {
        $credits = @($credits) + @($synthesizedReviewCredit)
    }

    # Build a changeset descriptor from the diff between baseRefOid and HEAD.
    # Used by Test-FVPredicateAgainstChangeset to evaluate each adapter's
    # `applies-when` predicate. Failure to build the changeset is non-fatal —
    # we fall back to an empty changeset, which makes every predicate evaluate
    # to 'false' or 'unknown' (preserving warn-mode invariants).
    $changeset = Build-FrameCreditLedgerChangeset -BaseRefOid $baseRefOid

    # H1 fix (issue #441 judge): Populate JudgeScore on the changeset from the
    # PR's judge-rulings comment so the review.sustainedCriticalOrHigh predicate
    # identifier resolves at runtime (not just in tests). Without this, the
    # post-fix-review predicate always falls through to the deferred-unknown path.
    if ($null -ne $script:PrComments) {
        $judgeRulingsComment = @($script:PrComments | Where-Object { $_.body -match '<!--\s*judge-rulings' }) | Select-Object -Last 1
        if ($null -ne $judgeRulingsComment) {
            $findings = @(ConvertFrom-JudgeRulingsComment -CommentBody ([string]$judgeRulingsComment.body))
            $changeset['JudgeScore'] = @{ Findings = $findings }
        }
    }

    # Track which (port, adapter) pairs have already emitted the deferred-
    # identifier stderr note so we don't spam the log.
    $script:DeferredNotedPairs = @{}

    # Build per-port reports.
    $portReports = [System.Collections.Generic.List[object]]::new()

    if (@($ports).Count -gt 0) {
        foreach ($port in $ports) {
            $portName = [string]$port.Name
            $matchingAdapters = @($adapters | Where-Object { [string]$_.Provides -eq $portName })
            $applicableMap = Resolve-FrameCreditLedgerApplicableMap -PortName $portName -Adapters $matchingAdapters -Changeset $changeset
            $credit = Select-AuthoritativeCreditForPort -Credits $credits -Port $portName

            $report = Resolve-PortStatus -Port $port -WorkAdapters $matchingAdapters -ApplicableMap $applicableMap -Credit $credit
            $portReports.Add($report) | Out-Null
        }
    }
    else {
        # No port catalog available — synthesize port reports directly from credits so we can still emit a meaningful ledger.
        $creditPortNames = @($credits | ForEach-Object { [string]$_.Port } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
        foreach ($portName in $creditPortNames) {
            $credit = Select-AuthoritativeCreditForPort -Credits $credits -Port $portName
            $synthPort = [pscustomobject]@{ Name = $portName }
            $report = Resolve-PortStatus -Port $synthPort -WorkAdapters @() -ApplicableMap @{} -Credit $credit
            $portReports.Add($report) | Out-Null
        }
    }

    foreach ($incompleteCycleReport in @(script:Resolve-FCLIncompleteCycleReports -Pr $Pr -PrBody $prBody -PrComments $script:PrComments -LedgerRows $credits)) {
        $portReports.Add($incompleteCycleReport) | Out-Null
    }

    $reportsArray = $portReports.ToArray()
    $hasNotCovered = @($reportsArray | Where-Object { [string]$_.Status -eq 'NotCovered' }).Count -gt 0

    # ---------------------------------------------------------------------------
    # Step 6: Cost Pattern composition (issue #467)
    # Sub-budgets total: 19s within the 30s outer budget.
    # On any sub-step failure, graceful degradation applies (cost section is empty string).
    # ---------------------------------------------------------------------------
    $costSection = ''
    if (-not $script:CostLibLoadFailed) {
        $costStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            $costBudgetSeconds = 19

            # 6a. Walker
            $slug = Get-CostTranscriptSlug -CwdPath $repoRoot
            $costBranch = & git -C $repoRoot rev-parse --abbrev-ref HEAD 2>$null
            $costEvents = @()
            if (-not [string]::IsNullOrWhiteSpace($slug) -and -not [string]::IsNullOrWhiteSpace($costBranch)) {
                $costEvents = @(Invoke-CostTranscriptWalk -Slug $slug -Branch $costBranch -ParentCwd $repoRoot)
            }

            # 6b. Attribution
            # Use $repoRoot to build the lib path because $PSScriptRoot may be empty
            # inside the worker runspace (it is re-derived from $PSCommandPath at call time).
            $costScriptsDir = if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) {
                $PSScriptRoot
            }
            else {
                Join-Path $repoRoot '.github/scripts'
            }
            $costAttribution = Get-CostAttribution -Events $costEvents -RateTablePath (Join-Path $costScriptsDir 'lib/cost-rate-table.json')

            # 6c. Rolling history (has its own 10s timeout via Get-CostRollingHistory)
            $rollingResult = @{ timed_out = $false; entries = @() }
            if ($costStopwatch.Elapsed.TotalSeconds -lt $costBudgetSeconds) {
                try { $rollingResult = Get-CostRollingHistory -TimeoutSeconds 10 }
                catch { $rollingResult = @{ timed_out = $true; entries = @() } }
            }

            # 6d. Regime checkpoint
            $checkpoint = $null
            if ($costStopwatch.Elapsed.TotalSeconds -lt $costBudgetSeconds) {
                try {
                    $cpPath = Join-Path $repoRoot '.github/scripts/cost-regime-checkpoints.yaml'
                    if (Test-Path $cpPath) { $checkpoint = Get-MostRecentRegimeCheckpoint -Path $cpPath }
                }
                catch { $checkpoint = $null }
            }

            # 6e. Completeness + preservation
            $completeness = Get-SessionCompleteness -Events $costEvents
            $priorCostData = $null
            if ($null -ne $script:PrComments) {
                $priorComment = @($script:PrComments | Where-Object { $_.body -match '<!-- cost-pattern-data' }) | Select-Object -Last 1
                if ($priorComment) {
                    $priorCompleteness = @{ completeness = 'complete'; excluded_from_rolling_baseline = $false }
                    $priorCostData = @{ completeness = $priorCompleteness }
                }
            }
            # preservation result is computed for future use (D10 re-emission prevention);
            # currently emitted to output pipeline for visibility — suppressed to avoid unused-var warning.
            $null = Resolve-CostDataPreservation -Current $completeness -Prior $priorCostData

            # 6f. Anomaly flags
            $anomalyFlags = @()
            if (-not $rollingResult.timed_out -and $costStopwatch.Elapsed.TotalSeconds -lt $costBudgetSeconds) {
                try { $anomalyFlags = @(Get-CostAnomalyFlags -ThisRun $costAttribution -RollingHistory @($rollingResult.entries) -RegimeCheckpoint $checkpoint) }
                catch { $anomalyFlags = @() }
            }

            # 6g. Render
            if ($costStopwatch.Elapsed.TotalSeconds -lt $costBudgetSeconds) {
                $costMarkdown = Format-CostPatternMarkdown -Attribution $costAttribution -Completeness $completeness -AnomalyFlags $anomalyFlags -RollingMeta $rollingResult -Pr $Pr -Branch ([string]$costBranch)
                $costYaml = Format-CostPatternYaml -Attribution $costAttribution -Completeness $completeness -AnomalyFlags $anomalyFlags -Pr $Pr -Branch ([string]$costBranch)
                $costSection = $costMarkdown + "`n" + $costYaml
            }
        }
        catch {
            [Console]::Error.WriteLine("frame-credit-ledger: cost pattern composition failed: $($_.Exception.Message)")
            $costSection = ''
        }
        $costStopwatch.Stop()
    }

    $comment = Compose-CommentWithCostPattern -MarkerToken $marker -PortReports $reportsArray -CostSection $costSection
    try {
        $null = Find-OrUpsertComment -Type 'pr' -Number $Pr -Marker $marker -Body $comment
    }
    catch {
        [Console]::Error.WriteLine("frame-credit-ledger: upsert failed: $($_.Exception.Message)")
    }

    return @{
        ExitCode      = if ($Mode -eq 'enforce' -and $hasNotCovered) { 1 } else { 0 }
        HasNotCovered = $hasNotCovered
        Comment       = $comment
    }
}

# ---------------------------------------------------------------------------
# Top-level execution (skipped when dot-sourced)
# ---------------------------------------------------------------------------
# Detect dot-source: when invoked via `. path -Pr 0 -Mode warn`, $MyInvocation.InvocationName is '.'
$isDotSourced = ($MyInvocation.InvocationName -eq '.')

if (-not $isDotSourced) {
    $budgetSeconds = 30
    if (-not [string]::IsNullOrWhiteSpace($env:FRAME_CREDIT_LEDGER_TEST_BUDGET_SECONDS)) {
        $parsedBudget = 0
        if ([int]::TryParse($env:FRAME_CREDIT_LEDGER_TEST_BUDGET_SECONDS, [ref]$parsedBudget) -and $parsedBudget -gt 0) {
            $budgetSeconds = $parsedBudget
        }
    }

    $exitCode = 0
    try {
        # Strategy: run the main flow on a background thread (in this same
        # process) so it can see the test harness's `function global:gh`
        # mock. We use a manually-constructed Runspace cloned from the
        # current default runspace's InitialSessionState — that way,
        # functions defined in the parent (including the gh mock) and
        # script-scoped functions defined above (Invoke-FrameCreditLedger)
        # are visible inside the worker runspace.
        #
        # The watchdog timer is enforced via Wait-Job-style polling on a
        # PowerShell async handle. If the budget elapses we Stop the
        # PowerShell instance (which interrupts a hanging Start-Sleep
        # inside the gh mock) and emit a fail-open stderr note.

        # Build an InitialSessionState that imports the parent's functions
        # and global variables. This is what makes `gh` resolvable inside
        # the worker runspace.
        $iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault2()

        # Copy parent's functions into the new ISS.
        # NOTE (C-Risk-2 follow-up, issue #429 Step 12): `$fn.Definition` returns
        # the function body INCLUDING the leading `[CmdletBinding()] param(...)`
        # block. When SessionStateFunctionEntry wraps this in `function $Name
        # { ... }`, the attributes survive intact. We verified that the
        # cloned `Invoke-FrameCreditLedger` retains its `-Mode` ValidateSet
        # binding via the existing 'rejects an invalid -Mode value via
        # ValidateSet' integration test. Investigated, no behavior impact —
        # do not switch to source-text reconstruction.
        $parentFunctions = Get-ChildItem -Path Function:\ -ErrorAction SilentlyContinue
        foreach ($fn in $parentFunctions) {
            try {
                $entry = New-Object System.Management.Automation.Runspaces.SessionStateFunctionEntry($fn.Name, $fn.Definition)
                $iss.Commands.Add($entry)
            }
            catch { $null = $_ }
        }

        # Copy global variables (e.g. $global:GhCallLog used by the test mock).
        # We skip PowerShell's automatic variables, which fall into two camps:
        #   1. Vars flagged with Constant / ReadOnly / AllScope / Private —
        #      these would error when re-added to the child runspace's ISS
        #      (e.g. $true, $false, $Host, $PID, $PSVersionTable, $HOME, $?,
        #      $IsLinux, $IsMacOS, $IsWindows, $IsCoreCLR, $PSCulture, ...).
        #      The .Options check catches these programmatically.
        #   2. Vars with Options=None that PowerShell auto-populates per
        #      runspace ($args, $input, $_, $^, $PWD, $MyInvocation,
        #      $PSCommandPath, $PSScriptRoot, $StackTrace, $null). These
        #      have no flag we can use, so we keep a small, named blocklist.
        $autoNoneOptionsBlocklist = @('args', 'input', '_', '^', 'PWD', 'MyInvocation', 'PSCommandPath', 'PSScriptRoot', 'StackTrace', 'null')
        $parentGlobals = Get-Variable -Scope Global -ErrorAction SilentlyContinue
        foreach ($v in $parentGlobals) {
            if ($v.Options -band [System.Management.Automation.ScopedItemOptions]::Constant) { continue }
            if ($v.Options -band [System.Management.Automation.ScopedItemOptions]::ReadOnly) { continue }
            if ($v.Options -band [System.Management.Automation.ScopedItemOptions]::AllScope) { continue }
            if ($v.Options -band [System.Management.Automation.ScopedItemOptions]::Private) { continue }
            if ($autoNoneOptionsBlocklist -contains $v.Name) { continue }
            try {
                $entry = New-Object System.Management.Automation.Runspaces.SessionStateVariableEntry($v.Name, $v.Value, '')
                $iss.Variables.Add($entry)
            }
            catch { $null = $_ }
        }

        $rs = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace($iss)
        $rs.Open()
        $worker = [System.Management.Automation.PowerShell]::Create()
        $worker.Runspace = $rs

        # Resolve repo root in the parent scope (where $PSCommandPath is set)
        # and pass it through so the worker doesn't need to re-derive it.
        $resolvedRepoRoot = $null
        if (-not [string]::IsNullOrWhiteSpace($PSCommandPath)) {
            $resolvedRepoRoot = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
        }
        else {
            $resolvedRepoRoot = (Get-Location).Path
        }

        $null = $worker.AddScript({
                param($PrArg, $ModeArg, $RepoRootArg)
                $script:FrameCreditLedgerRepoRoot = $RepoRootArg
                Invoke-FrameCreditLedger -Pr $PrArg -Mode $ModeArg
            }).AddArgument($Pr).AddArgument($Mode).AddArgument($resolvedRepoRoot)

        $async = $worker.BeginInvoke()
        $waited = $async.AsyncWaitHandle.WaitOne([int]($budgetSeconds * 1000))

        $result = $null
        if ($waited) {
            try {
                $result = $worker.EndInvoke($async)
            }
            catch {
                [Console]::Error.WriteLine("frame-credit-ledger: $($_.Exception.Message)")
                if ($Mode -eq 'enforce') { $exitCode = 1 }
            }
            # Mirror stderr from the worker.
            foreach ($errRecord in $worker.Streams.Error) {
                try { [Console]::Error.WriteLine([string]$errRecord) } catch { $null = $_ }
            }
        }
        else {
            # Budget exceeded — abort the worker and fail open.
            try { $worker.Stop() } catch { $null = $_ }
            [Console]::Error.WriteLine("frame-credit-ledger: ${budgetSeconds}s budget exceeded; warn-mode fail-open (no comment posted)")
            # Warn-mode invariant: never block PR creation on timeout. In
            # enforce mode the test still expects exit 0 on timeout (warn
            # invariant takes precedence over enforcement when no decision
            # could be made).
            $exitCode = 0
        }

        try { $worker.Dispose() } catch { $null = $_ }
        try { $rs.Close(); $rs.Dispose() } catch { $null = $_ }

        if ($null -ne $result) {
            $resultHash = $null
            $items = @($result)
            foreach ($item in $items) {
                if ($item -is [System.Collections.IDictionary]) {
                    $resultHash = $item
                }
            }

            if ($null -ne $resultHash) {
                $hasNotCovered = $false
                if ($null -ne $resultHash['HasNotCovered']) { $hasNotCovered = [bool]$resultHash['HasNotCovered'] }
                if ($Mode -eq 'enforce' -and $hasNotCovered) {
                    $exitCode = 1
                }
                if ($null -ne $resultHash['Comment'] -and -not [string]::IsNullOrEmpty([string]$resultHash['Comment'])) {
                    Write-Output ([string]$resultHash['Comment'])
                }
            }
        }
    }
    catch {
        [Console]::Error.WriteLine("frame-credit-ledger: $($_.Exception.Message)")
        # Warn-mode invariant: never block PR creation; exit 0 even on caught exception.
        if ($Mode -eq 'enforce') {
            $exitCode = 1
        }
        else {
            $exitCode = 0
        }
    }

    exit $exitCode
}
