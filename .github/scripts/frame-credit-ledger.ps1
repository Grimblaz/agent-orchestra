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
      - FRAME_CREDIT_LEDGER_TEST_NO_SLEEP=1                 skip Start-Sleep on retry
      - FRAME_CREDIT_LEDGER_TEST_BUDGET_SECONDS             override the 30s outer budget
      - FRAME_CREDIT_LEDGER_TEST_SKIP_ACTIVATION_CUTOVER=1  bypass enforce-activation.yaml check

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
    exit 5
}

# Cost pattern lib dot-sources (warn-mode fail-open: cost composition failure never blocks PR creation)
$script:CostLibLoadFailed = $false  # default; set to $true below if load fails
try {
    . (Join-Path $PSScriptRoot 'lib/path-normalize.ps1')
    . (Join-Path $PSScriptRoot 'lib/cost-walker.ps1')
    . (Join-Path $PSScriptRoot 'lib/cost-walker-copilot.ps1')
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

# Origin predicate dot-source (CI-safe; fail-open: if absent, $_isOrchestrated defaults to $false)
$_originPredicatePath = Join-Path $PSScriptRoot 'lib/Get-FCLOriginContext.ps1'
if (Test-Path $_originPredicatePath) {
    . $_originPredicatePath
}

# Off-switch: suppress only FAILED-state posts by default.
# Set $env:FCL_SUPPRESS_FAILED_POSTS=1 to activate.
$_suppressFailedPosts = ($env:FCL_SUPPRESS_FAILED_POSTS -eq '1')

# ---------------------------------------------------------------------------
# Read a single scalar field from an adapter's frontmatter block.
# ---------------------------------------------------------------------------
function script:Get-FCLAdapterFrontmatterScalar {
    param(
        [Parameter(Mandatory)][string]$Frontmatter,
        [Parameter(Mandatory)][string]$Field
    )

    return script:Get-FCLScalar -Block $Frontmatter -Name $Field
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
            $integrityAtomic = script:Get-FCLAdapterFrontmatterScalar -Frontmatter $fm -Field 'atomic'

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
                    IntegrityAtomic   = $integrityAtomic
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
        [AllowEmptyString()][string]$Branch
    )

    if (-not [string]::IsNullOrWhiteSpace($Branch)) {
        $branchMatch = [regex]::Match($Branch, '^feature/issue-(?<issue>\d+)(?:-|$)')
        if ($branchMatch.Success) {
            $branchIssue = 0
            if ([int]::TryParse($branchMatch.Groups['issue'].Value, [ref]$branchIssue) -and $branchIssue -gt 0) {
                return $branchIssue
            }
        }
    }

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

    return $null
}

function script:Resolve-FCLRepoRoot {
    [CmdletBinding()]
    param([AllowEmptyString()][string]$ScriptPath = $PSCommandPath)

    if (-not [string]::IsNullOrWhiteSpace($script:FrameCreditLedgerRepoRoot)) {
        $seededRoot = [string]$script:FrameCreditLedgerRepoRoot
        try {
            if (Test-Path -LiteralPath $seededRoot -PathType Container) {
                return (Resolve-Path -LiteralPath $seededRoot -ErrorAction Stop).Path
            }
        }
        catch { $null = $_ }

        return $seededRoot
    }

    $startDir = $null
    if (-not [string]::IsNullOrWhiteSpace($ScriptPath)) {
        try {
            $scriptPathValue = [string]$ScriptPath
            if (Test-Path -LiteralPath $scriptPathValue -PathType Leaf) {
                $scriptPathValue = (Resolve-Path -LiteralPath $scriptPathValue -ErrorAction Stop).Path
            }
            $startDir = Split-Path -Parent $scriptPathValue
        }
        catch { $startDir = $null }
    }

    if (-not [string]::IsNullOrWhiteSpace($startDir)) {
        try {
            $topLevelRaw = @(& git -C $startDir rev-parse --show-toplevel 2>$null)
            $topLevel = @($topLevelRaw | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -First 1)
            if ($global:LASTEXITCODE -eq 0 -and $topLevel.Count -gt 0) {
                $topLevelPath = [string]$topLevel[0]
                if (Test-Path -LiteralPath $topLevelPath -PathType Container) {
                    return (Resolve-Path -LiteralPath $topLevelPath -ErrorAction Stop).Path
                }
                return $topLevelPath
            }
        }
        catch { $null = $_ }

        $walkDir = $startDir
        while (-not [string]::IsNullOrWhiteSpace($walkDir)) {
            $gitDir = Join-Path $walkDir '.git'
            $manifestPath = Join-Path $walkDir 'plugin.json'
            $ledgerPath = Join-Path $walkDir '.github/scripts/frame-credit-ledger.ps1'
            if ((Test-Path -LiteralPath $gitDir) -or
                ((Test-Path -LiteralPath $manifestPath -PathType Leaf) -and (Test-Path -LiteralPath $ledgerPath -PathType Leaf))) {
                try { return (Resolve-Path -LiteralPath $walkDir -ErrorAction Stop).Path }
                catch { return $walkDir }
            }

            $parent = Split-Path -Parent $walkDir
            if ([string]::IsNullOrWhiteSpace($parent) -or $parent -eq $walkDir) { break }
            $walkDir = $parent
        }
    }

    try { return (Get-Location).Path }
    catch { return '.' }
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

    $issueNumber = script:Resolve-FCLLinkedIssueNumber -PrBody $PrBody
    if ($null -eq $issueNumber -and $Pr -gt 0) { $issueNumber = $Pr }
    if ($null -eq $issueNumber) { return @() }

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
        [string]$Provider = $null,
        [string]$Model = $null,
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
    if ($PSBoundParameters.ContainsKey('Provider')) { $updateParameters['Provider'] = $Provider }
    if ($PSBoundParameters.ContainsKey('Model')) { $updateParameters['Model'] = $Model }

    return Update-DispatchCostSampleEvaluationInPrBody @updateParameters
}

function script:Get-FCLCostScriptState {
    $state = @{}
    foreach ($costStateName in @(
            'CostWalkerSilentTypes',
            'CostAttributionPortMap',
            'CostCompletenessPartialReasons',
            'CostRendererPortOrder',
            'CostRendererSkillDrivenPorts'
        )) {
        try {
            $state[$costStateName] = Get-Variable -Scope Script -Name $costStateName -ValueOnly -ErrorAction Stop
        }
        catch { $null = $_ }
    }

    return $state
}

function script:New-FCLInitialSessionStateClone {
    $iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault2()

    # Use function definitions directly so advanced-function metadata survives cloning.
    $parentFunctions = Get-ChildItem -Path Function:\ -ErrorAction SilentlyContinue
    foreach ($fn in $parentFunctions) {
        try {
            $entry = New-Object System.Management.Automation.Runspaces.SessionStateFunctionEntry($fn.Name, $fn.Definition)
            $iss.Commands.Add($entry)
        }
        catch { $null = $_ }
    }

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

    return $iss
}

function script:New-FCLCostWalkerResult {
    param(
        [AllowEmptyCollection()][object[]]$Events = @(),
        [bool]$TimedOut = $false,
        [bool]$Failed = $false,
        [AllowEmptyCollection()][string[]]$Warnings = @()
    )

    return [pscustomobject]@{
        Events   = @($Events)
        TimedOut = $TimedOut
        Failed   = $Failed
        Warnings = @($Warnings)
    }
}

function script:Invoke-FCLCostWalkerWithTimeout {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$WalkerName,
        [Parameter(Mandatory)][string]$CommandName,
        [Parameter(Mandatory)][hashtable]$Parameters,
        [Parameter(Mandatory)][int]$TimeoutSeconds
    )

    if ($TimeoutSeconds -le 0) {
        return (script:New-FCLCostWalkerResult -TimedOut $true)
    }

    if ($env:FRAME_CREDIT_LEDGER_TEST_WALKER_INLINE -eq '1') {
        try {
            $events = @(& $CommandName @Parameters)
            return (script:New-FCLCostWalkerResult -Events $events)
        }
        catch {
            [Console]::Error.WriteLine("frame-credit-ledger: cost $WalkerName walker failed: $($_.Exception.Message)")
            return (script:New-FCLCostWalkerResult -Failed $true)
        }
    }

    $runspace = $null
    $worker = $null
    try {
        $runspace = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace((script:New-FCLInitialSessionStateClone))
        $runspace.Open()
        $worker = [System.Management.Automation.PowerShell]::Create()
        $worker.Runspace = $runspace

        $costScriptState = script:Get-FCLCostScriptState
        $null = $worker.AddScript({
                param($CommandNameArg, $ParametersArg, $CostScriptStateArg)
                foreach ($costStateName in @($CostScriptStateArg.Keys)) {
                    Set-Variable -Scope Script -Name $costStateName -Value $CostScriptStateArg[$costStateName]
                }
                & $CommandNameArg @ParametersArg
            }).AddArgument($CommandName).AddArgument($Parameters).AddArgument($costScriptState)

        $async = $worker.BeginInvoke()
        $waited = $async.AsyncWaitHandle.WaitOne([int]($TimeoutSeconds * 1000))
        if (-not $waited) {
            try { $worker.Stop() } catch { $null = $_ }
            [Console]::Error.WriteLine("frame-credit-ledger: cost $WalkerName walker timed out after ${TimeoutSeconds}s; continuing with empty $WalkerName events")
            return (script:New-FCLCostWalkerResult -TimedOut $true)
        }

        $output = @()
        $failed = $false
        try { $output = @($worker.EndInvoke($async)) }
        catch {
            [Console]::Error.WriteLine("frame-credit-ledger: cost $WalkerName walker failed: $($_.Exception.Message)")
            $failed = $true
        }

        foreach ($errRecord in $worker.Streams.Error) {
            try { [Console]::Error.WriteLine([string]$errRecord) } catch { $null = $_ }
        }

        $warnings = @($worker.Streams.Warning | ForEach-Object { [string]$_ })
        return (script:New-FCLCostWalkerResult -Events $output -Failed $failed -Warnings $warnings)
    }
    catch {
        [Console]::Error.WriteLine("frame-credit-ledger: cost $WalkerName walker failed: $($_.Exception.Message)")
        return (script:New-FCLCostWalkerResult -Failed $true)
    }
    finally {
        if ($null -ne $worker) { $worker.Dispose() }
        if ($null -ne $runspace) { $runspace.Dispose() }
    }
}

function script:Resolve-FCLCostCopilotOtelJsonlPath {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$RepoRoot)

    if (-not [string]::IsNullOrWhiteSpace($env:FRAME_CREDIT_LEDGER_TEST_COPILOT_OTEL_JSONL)) {
        return [string]$env:FRAME_CREDIT_LEDGER_TEST_COPILOT_OTEL_JSONL
    }

    $settingsPath = Join-Path $RepoRoot '.vscode/settings.json'
    if (Test-Path -LiteralPath $settingsPath -PathType Leaf) {
        try {
            $settings = Get-Content -LiteralPath $settingsPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            $outfileProperty = $settings.PSObject.Properties['github.copilot.chat.otel.outfile']
            if ($null -ne $outfileProperty -and -not [string]::IsNullOrWhiteSpace([string]$outfileProperty.Value)) {
                $resolved = Resolve-CostCopilotOutfileTemplate -Template ([string]$outfileProperty.Value) -WorkspaceRoot $RepoRoot
                if ($null -ne $resolved -and -not [string]::IsNullOrWhiteSpace([string]$resolved.ResolvedPath)) {
                    return [string]$resolved.ResolvedPath
                }
            }
        }
        catch { $null = $_ }
    }

    $workspaceFolderBasename = Split-Path -Leaf $RepoRoot
    return (Join-Path ([Environment]::GetFolderPath('UserProfile')) ".copilot-otel/$workspaceFolderBasename/copilot.jsonl")
}

function script:Get-FCLCostWalkerTimeoutSeconds {
    param(
        [Parameter(Mandatory)][string]$EnvironmentVariableName,
        [Parameter(Mandatory)][int]$DefaultSeconds
    )

    $raw = [Environment]::GetEnvironmentVariable($EnvironmentVariableName, 'Process')
    $parsed = 0
    if (-not [string]::IsNullOrWhiteSpace($raw) -and [int]::TryParse($raw, [ref]$parsed) -and $parsed -gt 0) {
        return $parsed
    }

    return $DefaultSeconds
}

function script:Get-FCLCostEventProviderSet {
    param([AllowEmptyCollection()][object[]]$Events)

    $providers = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($evt in @($Events)) {
        if ($null -eq $evt) { continue }

        $provider = $null
        try { $provider = Get-EventProvider -Evt $evt }
        catch {
            if ($evt -is [System.Collections.IDictionary] -and $evt.ContainsKey('provider')) { $provider = $evt['provider'] }
            elseif ($null -ne $evt.PSObject.Properties['provider']) { $provider = $evt.provider }
        }

        if (-not [string]::IsNullOrWhiteSpace([string]$provider)) {
            $null = $providers.Add(([string]$provider).ToLowerInvariant())
        }
    }

    $ordered = [System.Collections.Generic.List[string]]::new()
    foreach ($candidate in @('claude', 'copilot')) {
        if ($providers.Contains($candidate)) { $ordered.Add($candidate) }
    }
    foreach ($provider in $providers) {
        if (-not $ordered.Contains($provider)) { $ordered.Add($provider) }
    }

    return [string[]]$ordered.ToArray()
}

function script:Get-FCLCostUnmappedSessionCount {
    param([AllowEmptyCollection()][string[]]$Warnings)

    $total = 0
    foreach ($warning in @($Warnings)) {
        $match = [regex]::Match([string]$warning, 'unmapped_session_count=(?<count>\d+)')
        if ($match.Success) { $total += [int]$match.Groups['count'].Value }
    }

    return $total
}

function script:Get-FCLCostMetadataValue {
    param(
        [AllowNull()][object]$Entry,
        [Parameter(Mandatory)][string]$Name
    )

    if ($null -eq $Entry) { return $null }
    if ($Entry -is [System.Collections.IDictionary]) { return $Entry[$Name] }
    $property = $Entry.PSObject.Properties[$Name]
    if ($null -ne $property) { return $property.Value }
    return $null
}

function script:Get-FCLEffectiveCostCoverageClass {
    param([AllowNull()][object]$Entry)

    $installStatus = script:Get-FCLCostMetadataValue -Entry $Entry -Name 'install_status'
    if ([string]$installStatus -eq 'missing-or-fallback') { return 'claude-only' }

    $coverage = script:Get-FCLCostMetadataValue -Entry $Entry -Name 'coverage'
    if (-not [string]::IsNullOrWhiteSpace([string]$coverage)) { return [string]$coverage }

    return 'claude-only'
}

function script:Set-FCLRollingMetaCoverageCount {
    param(
        [Parameter(Mandatory)][hashtable]$RollingResult,
        [Parameter(Mandatory)][hashtable]$Attribution
    )

    if ($RollingResult['timed_out'] -eq $true) { return }

    $currentCoverage = script:Get-FCLEffectiveCostCoverageClass -Entry $Attribution
    $matchingCount = 0
    foreach ($entry in @($RollingResult['entries'])) {
        if ((script:Get-FCLEffectiveCostCoverageClass -Entry $entry) -eq $currentCoverage) {
            $matchingCount++
        }
    }

    $RollingResult['matching_coverage_history_count'] = $matchingCount
}

function script:Set-FCLCostCoverageMetadata {
    param(
        [Parameter(Mandatory)][hashtable]$Attribution,
        [AllowEmptyCollection()][object[]]$Events,
        [AllowNull()]$ClaudeWalk,
        [AllowNull()]$CopilotWalk,
        [Parameter(Mandatory)][string]$CopilotOtelJsonlPath
    )

    [string[]]$providers = @(script:Get-FCLCostEventProviderSet -Events $Events)
    $hasClaude = $providers -contains 'claude'
    $hasCopilot = $providers -contains 'copilot'
    $copilotWarnings = if ($null -ne $CopilotWalk) { @($CopilotWalk.Warnings) } else { @() }
    $unmappedSessionCount = script:Get-FCLCostUnmappedSessionCount -Warnings $copilotWarnings
    $copilotTimedOut = ($null -ne $CopilotWalk -and $CopilotWalk.TimedOut -eq $true)
    $copilotFailed = ($null -ne $CopilotWalk -and $CopilotWalk.Failed -eq $true)

    $installStatus = 'ok'
    if ([string]::IsNullOrWhiteSpace($CopilotOtelJsonlPath) -or -not (Test-Path -LiteralPath $CopilotOtelJsonlPath -PathType Leaf)) {
        $installStatus = 'missing-or-fallback'
    }

    $coverage = 'claude-only'
    if ($hasClaude -and $hasCopilot) { $coverage = 'claude+copilot' }
    elseif ($hasCopilot) { $coverage = 'copilot-only' }
    elseif ($hasClaude -and ($copilotTimedOut -or $copilotFailed -or $unmappedSessionCount -gt 0 -or $installStatus -eq 'missing-or-fallback')) { $coverage = 'claude-only-with-copilot-fallback-warning' }

    if ($providers.Count -eq 0) { $providers = @('claude') }

    $Attribution['coverage'] = $coverage
    $Attribution['install_status'] = $installStatus
    $Attribution['unmapped_session_count'] = $unmappedSessionCount
    $Attribution['provider_support'] = [string[]]$providers
}

function script:Get-FCLRemainingCostBudgetSeconds {
    param(
        [Parameter(Mandatory)][System.Diagnostics.Stopwatch]$Stopwatch,
        [Parameter(Mandatory)][int]$BudgetSeconds
    )

    $remaining = $BudgetSeconds - [int][Math]::Ceiling($Stopwatch.Elapsed.TotalSeconds)
    if ($remaining -lt 0) { return 0 }
    return $remaining
}

# ---------------------------------------------------------------------------
# Invoke-FrameCreditLedger
# ---------------------------------------------------------------------------
function Invoke-FrameCreditLedger {
    [CmdletBinding()]
    [OutputType([hashtable])]
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

    # 3a. Compute orchestrated-origin context using the CI-safe predicate (s1).
    # PRIMARY: $env:GITHUB_HEAD_REF (populated on pull_request events; never 'HEAD').
    # FALLBACK: PR body linked-issue signals.
    # If Get-FCLOriginContext is unavailable (predicate not dot-sourced), default
    # to $false — safe: fails quiet, never produces false-FAILED posts.
    $_isOrchestrated = $false
    if (Get-Command 'Get-FCLOriginContext' -ErrorAction SilentlyContinue) {
        $_prHeadRef = $env:GITHUB_HEAD_REF
        $_originCtx = Get-FCLOriginContext -HeadRef $_prHeadRef -PrBody $prBody
        $_isOrchestrated = [bool]$_originCtx.IsOrchestratedOrigin
    }

    # 4. Non-v4 short-circuit. Read-PRMetricsBlock returns one of three
    # non-v4 shapes that we must distinguish so the posted comment is
    # honest about what actually happened:
    #   - $null                              -> no marker block at all
    #   - MetricsVersion = 'parse-error'      -> block exists, YAML is malformed
    #   - MetricsVersion = 'pre-v4'           -> block exists, version != 4
    # Any other non-4 shape we have not seen before falls through to the
    # pre-v4 comment as a conservative default.
    if ($null -eq $metrics) {
        # Taxonomy decision: FAILED only for orchestrated-origin; quiet for non-orchestrated.
        $comment = Compose-MissingMetricsShortCircuitComment -MarkerToken $marker -IsOrchestrated $_isOrchestrated
        # FAILED-state posts are gated by off-switch; non-orchestrated posts always fire.
        $postComment = $true
        if ($_isOrchestrated -and $_suppressFailedPosts) {
            $postComment = $false
        }
        if ($postComment) {
            try {
                $null = Find-OrUpsertComment -Type 'pr' -Number $Pr -Marker $marker -Body $comment
            }
            catch {
                [Console]::Error.WriteLine("frame-credit-ledger: upsert failed: $($_.Exception.Message)")
            }
        }

        return @{
            ExitCode        = 5
            HasBlock        = $true
            IsInternalError = $true
            Comment         = $comment
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
            ExitCode        = 5
            HasBlock        = $true
            IsInternalError = $true
            Comment         = $comment
        }
    }

    if ($metrics.MetricsVersion -ne 4) {
        $detectedVersion = $null
        if ($null -ne $metrics.PSObject.Properties['DetectedVersion']) { $detectedVersion = [string]$metrics.DetectedVersion }
        $comment = Compose-PreV4ShortCircuitComment -MarkerToken $marker -DetectedVersion $detectedVersion
        try {
            $null = Find-OrUpsertComment -Type 'pr' -Number $Pr -Marker $marker -Body $comment
        }
        catch {
            [Console]::Error.WriteLine("frame-credit-ledger: upsert failed: $($_.Exception.Message)")
        }

        return @{
            ExitCode        = 5
            HasBlock        = $true
            IsInternalError = $true
            Comment         = $comment
        }
    }

    script:Update-FCLPrBodyMetricsBestEffort -Pr $Pr -PrBody $prBody

    # 5. v4 path: discover adapters and classify ports.
    $repoRoot = script:Resolve-FCLRepoRoot -ScriptPath $PSCommandPath
    $adapters = Get-FrameCreditLedgerAdapters -RepoRoot $repoRoot
    # Atomic completion marker template: <!-- adversarial-pipeline-atomic-{ISSUE_ID} -->
    $atomicMarkerSearchText = $prBody
    if ($null -ne $script:PrComments) {
        $atomicMarkerSearchText += "`n" + ((@($script:PrComments) | ForEach-Object { script:Get-FCLCommentBody -Comment $_ }) -join "`n")
    }
    $currentBranch = ''
    try { $currentBranch = [string](& git -C $repoRoot rev-parse --abbrev-ref HEAD 2>$null) } catch { $currentBranch = '' }
    $atomicMarkerIssueId = script:Resolve-FCLLinkedIssueNumber -PrBody $prBody -Branch $currentBranch
    if ($null -ne $atomicMarkerIssueId) {
        $issueCommentsForAtomicMarker = @(script:Get-FCLIssueCommentsForSpine -IssueNumber ([int]$atomicMarkerIssueId))
        if ($issueCommentsForAtomicMarker.Count -gt 0) {
            $atomicMarkerSearchText += "`n" + (($issueCommentsForAtomicMarker | ForEach-Object { script:Get-FCLCommentBody -Comment $_ }) -join "`n")
        }
    }

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
    $hasApplicableAtomicAdapter = $false

    if (@($ports).Count -gt 0) {
        foreach ($port in $ports) {
            $portName = [string]$port.Name
            $matchingAdapters = @($adapters | Where-Object { [string]$_.Provides -eq $portName })
            $applicableMap = Resolve-FrameCreditLedgerApplicableMap -PortName $portName -Adapters $matchingAdapters -Changeset $changeset
            foreach ($adapter in $matchingAdapters) {
                if ([string]$adapter.IntegrityAtomic -ne 'true') { continue }
                $adapterName = [string]$adapter.Name
                if ($applicableMap.ContainsKey($adapterName) -and [string]$applicableMap[$adapterName] -eq 'true') {
                    $hasApplicableAtomicAdapter = $true
                    break
                }
            }
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

    $atomicMarkerStatus = Resolve-AdversarialPipelineAtomicMarkerPresence `
        -AdapterAtomicState $hasApplicableAtomicAdapter `
        -Text $atomicMarkerSearchText `
        -IssueId $(if ($null -eq $atomicMarkerIssueId) { '' } else { [string]$atomicMarkerIssueId })
    $atomicMarkerStatusValue = [string]$atomicMarkerStatus.adversarial_pipeline_atomic_marker_present
    if (-not [string]::IsNullOrWhiteSpace([string]$atomicMarkerStatus.warning)) {
        [Console]::Error.WriteLine("frame-credit-ledger: $($atomicMarkerStatus.warning)")
    }

    foreach ($incompleteCycleReport in @(script:Resolve-FCLIncompleteCycleReports -Pr $Pr -PrBody $prBody -PrComments $script:PrComments -LedgerRows $credits)) {
        $portReports.Add($incompleteCycleReport) | Out-Null
    }

    $reportsArray = $portReports.ToArray()

    # Apply authorized self-override: find and validate the frame-override-{PR} marker.
    # Override misconfiguration classes (AdapterParseError, AdapterDiscoveryFailed) are NOT
    # eligible — these indicate system configuration problems, not missing credits.
    $overriddenPorts = @(Resolve-FCLOverrideMarker -Pr $Pr -Comments $script:PrComments)
    if ($overriddenPorts.Count -gt 0) {
        $nonOverridableSubs = @('AdapterParseError', 'AdapterDiscoveryFailed')
        $reportsArray = @($reportsArray | ForEach-Object {
            $r = $_
            $portName = [string]$r.PortName
            if ($portName -in $overriddenPorts -and [string]$r.SubReason -notin $nonOverridableSubs) {
                [pscustomobject]@{
                    PortName          = $portName
                    Status            = 'Covered'
                    SubReason         = 'OverriddenCredit'
                    AdapterName       = $r.AdapterName
                    SuggestedNextStep = $null
                    Evidence          = "override: authorized self-override posted in PR $Pr comment"
                }
            } else {
                $r
            }
        })
    }

    # Build a port-descriptor lookup for fast access to BlockOnInconclusive and TriggerStatus.
    $portDescriptorMap = @{}
    foreach ($pd in $ports) {
        $portDescriptorMap[[string]$pd.Name] = $pd
    }

    # Determine which ports should block in enforce mode.
    # A port blocks when:
    #   1. Status = 'NotCovered' (port has a gap — always blocks)
    #   2. Status = 'Inconclusive' AND it is a misconfiguration sub-reason (AdapterParseError,
    #      AdapterDiscoveryFailed) — always blocks regardless of BlockOnInconclusive
    #   3. Status = 'Inconclusive' AND the port's BlockOnInconclusive = true (per-port flag)
    # Exception: ports with TriggerStatus = 'deferred' are NEVER included in the block set.
    $blockingReports = @($reportsArray | Where-Object {
        $r = $_
        $portName = [string]$r.PortName
        $status = [string]$r.Status
        $subReason = [string]$r.SubReason

        # Deferred ports: never block, render DEFERRED row separately.
        $pd = $portDescriptorMap[$portName]
        if ($null -ne $pd -and [string]$pd.TriggerStatus -eq 'deferred') {
            return $false
        }

        if ($status -eq 'NotCovered') {
            return $true
        }

        if ($status -eq 'Inconclusive') {
            # Misconfiguration classes always block.
            if ($subReason -in @('AdapterParseError', 'AdapterDiscoveryFailed')) {
                return $true
            }
            # Per-port flag.
            if ($null -ne $pd) {
                $boi = $pd.PSObject.Properties['BlockOnInconclusive']
                if ($null -ne $boi) { return [bool]$boi.Value }
            }
            return $true  # fail-safe default
        }

        return $false
    })
    $hasBlock = $blockingReports.Count -gt 0

    # Fill recovery commands for blocking reports that have no SuggestedNextStep.
    $reportsArray = @($reportsArray | ForEach-Object {
        $r = $_
        if ($null -eq $r.SuggestedNextStep -or [string]::IsNullOrWhiteSpace([string]$r.SuggestedNextStep)) {
            $status = [string]$r.Status
            $subReason = [string]$r.SubReason
            # Only fill for statuses that are presented as actionable in the report
            if ($status -in @('NotCovered', 'Inconclusive')) {
                $recovery = Resolve-FCLRecoveryCommand -PortName ([string]$r.PortName) -SubReason $subReason
                $r = [pscustomobject]@{
                    PortName          = $r.PortName
                    Status            = $r.Status
                    SubReason         = $r.SubReason
                    AdapterName       = $r.AdapterName
                    SuggestedNextStep = $recovery
                    Evidence          = $r.Evidence
                }
            }
        }
        $r
    })

    # Ensure deferred ports render a visible DEFERRED(#NNN): row.
    # These ports are excluded from the block check (above) but must appear in the render table.
    foreach ($pd in $ports) {
        if ([string]$pd.TriggerStatus -ne 'deferred') { continue }
        $portName = [string]$pd.Name
        $deferredTo = if ($null -ne $pd.TriggerDeferredTo) { [string]$pd.TriggerDeferredTo } else { 'unknown' }

        # Check if this port already has a report (it might have a credit with DEFERRED evidence)
        $existing = @($reportsArray | Where-Object { [string]$_.PortName -eq $portName })
        if ($existing.Count -eq 0) {
            # Add a synthetic DEFERRED row — status Covered/DeferredPort, never auto-filtered
            $deferredRow = [pscustomobject]@{
                PortName          = $portName
                Status            = 'Covered'
                SubReason         = 'DeferredPort'
                AdapterName       = ''
                SuggestedNextStep = "Deferred to issue $deferredTo"
                Evidence          = "DEFERRED($deferredTo): port excluded until producing issue lands"
            }
            $reportsArray = @($reportsArray) + $deferredRow
        }
    }

    # ---------------------------------------------------------------------------
    # Step 5b: 90-day deferred-port tripwire (issue #443, Step 11)
    #
    # Scan credits for DEFERRED(#NNN): evidence rows.  For each, read the
    # matching port YAML to extract trigger-deferred-since.  If the date is
    # older than 90 days, emit a non-blocking stderr warning.  This is
    # tripwire-only — it never gates a PR merge.
    # ---------------------------------------------------------------------------
    try {
        $tripwireDays = 90
        $today = [datetime]::UtcNow.Date
        foreach ($credit in $credits) {
            $evidenceProp = $credit.PSObject.Properties['evidence']
            if ($null -eq $evidenceProp) { continue }
            $evidence = [string]$evidenceProp.Value
            if ([string]::IsNullOrWhiteSpace($evidence)) { continue }
            if ($evidence -notmatch '^DEFERRED\(#(\d+)\):') { continue }

            $portProp = $credit.PSObject.Properties['port']
            if ($null -eq $portProp) { continue }
            $portName = [string]$portProp.Value
            if ([string]::IsNullOrWhiteSpace($portName)) { continue }

            # Read trigger-deferred-since from the port YAML file.
            $portYaml = Join-Path $portsDir "$portName.yaml"
            if (-not (Test-Path -LiteralPath $portYaml -PathType Leaf)) { continue }

            $portRaw = ''
            try { $portRaw = Get-Content -LiteralPath $portYaml -Raw -ErrorAction Stop } catch { continue }

            $sincePattern = '(?m)^\s*trigger-deferred-since\s*:\s*[''"]?(?<val>[0-9]{4}-[0-9]{2}-[0-9]{2})[''"]?\s*$'
            $sinceMatch = [regex]::Match($portRaw, $sincePattern)
            if (-not $sinceMatch.Success) { continue }

            $sinceDate = $null
            try {
                $sinceDate = [datetime]::ParseExact($sinceMatch.Groups['val'].Value, 'yyyy-MM-dd',
                    [System.Globalization.CultureInfo]::InvariantCulture)
            } catch { continue }

            $age = ($today - $sinceDate.Date).Days
            if ($age -gt $tripwireDays) {
                [Console]::Error.WriteLine("frame-credit-ledger: ⚠️ deferred-port tripwire: port '$portName' has been deferred for $age days (threshold: $tripwireDays). trigger-deferred-since: $($sinceMatch.Groups['val'].Value). Consider prioritizing the producing issue.")
            }
        }
    }
    catch {
        # Tripwire is warn-only; never block on failure.
        $null = $_
    }

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

            # 6a. Walkers
            $slug = Get-CostTranscriptSlug -CwdPath $repoRoot
            $costBranch = & git -C $repoRoot rev-parse --abbrev-ref HEAD 2>$null
            $costEvents = @()
            $claudeWalk = $null
            $copilotWalk = $null
            $copilotOtelJsonlPath = ''
            if (-not [string]::IsNullOrWhiteSpace($slug) -and -not [string]::IsNullOrWhiteSpace($costBranch)) {
                $resolvedIssueNumber = script:Resolve-FCLLinkedIssueNumber -PrBody $prBody -Branch ([string]$costBranch)
                $walkParameters = @{
                    Slug      = $slug
                    Branch    = $costBranch
                    ParentCwd = $repoRoot
                    RepoRoot  = $repoRoot  # D2: used by identity-based slug discovery
                }
                if ($null -ne $resolvedIssueNumber) {
                    $walkParameters['IssueNumber'] = [int]$resolvedIssueNumber
                }

                $claudeTimeoutSeconds = script:Get-FCLCostWalkerTimeoutSeconds -EnvironmentVariableName 'FRAME_CREDIT_LEDGER_TEST_CLAUDE_WALKER_TIMEOUT_SECONDS' -DefaultSeconds 10
                $copilotTimeoutSeconds = script:Get-FCLCostWalkerTimeoutSeconds -EnvironmentVariableName 'FRAME_CREDIT_LEDGER_TEST_COPILOT_WALKER_TIMEOUT_SECONDS' -DefaultSeconds 6

                $claudeWalk = script:Invoke-FCLCostWalkerWithTimeout `
                    -WalkerName 'claude' `
                    -CommandName 'Invoke-CostTranscriptWalk' `
                    -Parameters $walkParameters `
                    -TimeoutSeconds $claudeTimeoutSeconds

                $copilotOtelJsonlPath = script:Resolve-FCLCostCopilotOtelJsonlPath -RepoRoot $repoRoot
                $copilotWalkParameters = @{
                    Branch                  = [string]$costBranch
                    RepoRoot                = $repoRoot
                    OtelJsonlPath           = $copilotOtelJsonlPath
                    WorkspaceFolderBasename = (Split-Path -Leaf $repoRoot)
                }
                $copilotWalk = script:Invoke-FCLCostWalkerWithTimeout `
                    -WalkerName 'copilot' `
                    -CommandName 'Invoke-CostCopilotWalk' `
                    -Parameters $copilotWalkParameters `
                    -TimeoutSeconds $copilotTimeoutSeconds

                $costEvents = @($claudeWalk.Events) + @($copilotWalk.Events)
            }

            if ($null -ne $claudeWalk -and $claudeWalk.Failed -eq $true -and ($null -eq $copilotWalk -or @($copilotWalk.Events).Count -eq 0)) {
                throw 'Claude cost walker failed and no Copilot events were available for fallback attribution'
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
            script:Set-FCLCostCoverageMetadata -Attribution $costAttribution -Events $costEvents -ClaudeWalk $claudeWalk -CopilotWalk $copilotWalk -CopilotOtelJsonlPath $copilotOtelJsonlPath

            # 6c. Rolling history (has its own 10s timeout via Get-CostRollingHistory)
            $rollingResult = @{ timed_out = $false; entries = @() }
            $remainingCostBudgetSeconds = script:Get-FCLRemainingCostBudgetSeconds -Stopwatch $costStopwatch -BudgetSeconds $costBudgetSeconds
            if ($remainingCostBudgetSeconds -gt 0) {
                try { $rollingResult = Get-CostRollingHistory -TimeoutSeconds ([Math]::Min(10, $remainingCostBudgetSeconds)) }
                catch { $rollingResult = @{ timed_out = $true; entries = @() } }
            }
            script:Set-FCLRollingMetaCoverageCount -RollingResult $rollingResult -Attribution $costAttribution

            # 6d. Regime checkpoint
            $checkpoint = $null
            if ((script:Get-FCLRemainingCostBudgetSeconds -Stopwatch $costStopwatch -BudgetSeconds $costBudgetSeconds) -gt 0) {
                try {
                    $cpPath = Join-Path $repoRoot '.github/scripts/cost-regime-checkpoints.yaml'
                    if (Test-Path $cpPath) { $checkpoint = Get-MostRecentRegimeCheckpoint -Path $cpPath -Coverage ([string]$costAttribution['coverage']) }
                }
                catch { $checkpoint = $null }
            }

            # 6e. Completeness + preservation
            $completenessParameters = @{ Events = $costEvents }
            if (-not [string]::IsNullOrWhiteSpace($costBranch)) {
                $completenessParameters['Branch'] = [string]$costBranch
            }
            $completeness = Get-SessionCompleteness @completenessParameters
            $priorCostData = $null
            $priorComment = $null
            if ($null -ne $script:PrComments) {
                $priorComment = @($script:PrComments | Where-Object { $_.body -match '<!-- cost-pattern-data' }) | Select-Object -Last 1
                if ($priorComment) {
                    # Fix #760-D1-c: parse the actual prior comment body rather than using a
                    # hardcoded stub, and use a flat shape so Resolve-CostDataPreservation can
                    # read $Prior['completeness'] as a string (not a nested hashtable).
                    $priorYaml = script:Get-CostPatternDataFromComment -Body $priorComment.body
                    if ($null -ne $priorYaml) {
                        $priorCostData = script:ConvertFrom-CostPatternYaml -Yaml $priorYaml
                    }
                    # Fix #760-C3: a populated prior cost-pattern-data block must never be
                    # clobbered by an empty/partial current walk.  A block that predates the
                    # session_completeness field parses with a null 'completeness' (and a fully
                    # unextractable body yields $null priorCostData).  In both cases the marker's
                    # presence means a genuine render already exists — the old contract only wrote
                    # the block on a populated render — so default any prior block lacking an
                    # explicit completeness to 'complete'.  Resolve-CostDataPreservation then
                    # preserves it instead of overwriting with the empty/partial current.
                    if ($null -eq $priorCostData) {
                        $priorCostData = @{ completeness = 'complete' }
                    }
                    elseif ([string]::IsNullOrWhiteSpace([string]$priorCostData['completeness'])) {
                        $priorCostData['completeness'] = 'complete'
                    }
                }
            }

            # Fix #760-D1-b: wire the Resolve-CostDataPreservation result instead of discarding it.
            # This drives the skip-when-absent gate below (AC1 + AC2).
            $preservationResult = Resolve-CostDataPreservation -Current $completeness -Prior $priorCostData

            # Fix #760-D1-a: skip-when-absent gate — if preservation says to use_prior, reuse the
            # prior comment's cost section verbatim.  This fires when the projects root is absent
            # (CI enforce on ubuntu-latest) AND the prior comment had a complete render, preventing
            # an empty walk from overwriting a populated cost-pattern-data block.  Invariant: a
            # populated block is NEVER replaced by an empty one.
            $usePriorCostSection = $preservationResult['use_prior'] -eq $true
            if ($usePriorCostSection -and $null -ne $priorComment) {
                $priorYamlForSection = script:Get-CostPatternDataFromComment -Body $priorComment.body
                $preservationNotice = $preservationResult['notice']
                $noticeBlock = if ($null -ne $preservationNotice -and $preservationNotice -ne '') {
                    "> [!NOTE]`n> $preservationNotice`n`n"
                } else { '' }
                if ($null -ne $priorYamlForSection) {
                    # Fix #760-F3: preserve the full visible section (heading + rendered markdown
                    # table + YAML block) from the prior comment, not only the hidden YAML comment.
                    # Without this, the human-readable Cost Pattern table disappears when preservation
                    # fires, even though the underlying data (rolling-baseline YAML) survives.
                    $sectionMatch = [regex]::Match(
                        $priorComment.body,
                        '(?ms)(?<section>^##\s+Cost Pattern\b.*?<!--\s*cost-pattern-data[\s\S]*?-->)'
                    )
                    $priorSection = if ($sectionMatch.Success) {
                        $sectionMatch.Groups['section'].Value.TrimEnd()
                    } else {
                        # Fallback: visible heading unavailable — use YAML block only.
                        "<!-- cost-pattern-data`n$priorYamlForSection`n-->"
                    }
                    $costSection = $noticeBlock + $priorSection
                }
                else {
                    # Fix #760-F9: prior block exists (loose selector matched) but the strict
                    # extractor could not parse its body (malformed block — missing closing -->,
                    # no newline after marker, etc.).  C3 defaulted priorCostData to 'complete'
                    # above, which correctly triggers use_prior=true, but without this fallback
                    # the rebuild path left $costSection='' and erased the prior block — the
                    # exact opposite of the D1 invariant.  Carry the raw block verbatim instead.
                    $rawBlockMatch = [regex]::Match(
                        $priorComment.body,
                        '<!--\s*cost-pattern-data[\s\S]*?-->'
                    )
                    if ($rawBlockMatch.Success) {
                        $costSection = $noticeBlock + $rawBlockMatch.Value
                    }
                    # else: truly no cost block in the body despite the selector match — leave
                    # $costSection as-is (empty string). This path is not normally reachable.
                }
            }
            else {
                # 6f. Anomaly flags — only compute when not using prior (AC2: guard on use_prior)
                $anomalyFlags = @()
                if (-not $rollingResult.timed_out -and (script:Get-FCLRemainingCostBudgetSeconds -Stopwatch $costStopwatch -BudgetSeconds $costBudgetSeconds) -gt 0) {
                    try { $anomalyFlags = @(Get-CostAnomalyFlags -ThisRun $costAttribution -RollingHistory @($rollingResult.entries) -RegimeCheckpoint $checkpoint) }
                    catch { $anomalyFlags = @() }
                }

                # 6g. Render fresh cost section
                if ((script:Get-FCLRemainingCostBudgetSeconds -Stopwatch $costStopwatch -BudgetSeconds $costBudgetSeconds) -gt 0) {
                    $costMarkdown = Format-CostPatternMarkdown -Attribution $costAttribution -Completeness $completeness -AnomalyFlags $anomalyFlags -RollingMeta $rollingResult -Pr $Pr -Branch ([string]$costBranch)
                    $costYaml = Format-CostPatternYaml -Attribution $costAttribution -Completeness $completeness -AnomalyFlags $anomalyFlags -Pr $Pr -Branch ([string]$costBranch)
                    $costSection = $costMarkdown + "`n" + $costYaml
                }
            }
        }
        catch {
            [Console]::Error.WriteLine("frame-credit-ledger: cost pattern composition failed: $($_.Exception.Message)")
            $costSection = ''
        }
        $costStopwatch.Stop()
    }

    $comment = Compose-CommentWithCostPattern -MarkerToken $marker -PortReports $reportsArray -CostSection $costSection -Mode $Mode -HasBlock $hasBlock
    try {
        $null = Find-OrUpsertComment -Type 'pr' -Number $Pr -Marker $marker -Body $comment
    }
    catch {
        [Console]::Error.WriteLine("frame-credit-ledger: upsert failed: $($_.Exception.Message)")
    }

    return @{
        ExitCode      = if ($Mode -eq 'enforce' -and $hasBlock) { 3 } else { 0 }
        HasBlock      = $hasBlock
        Comment       = $comment
        adversarial_pipeline_atomic_marker_present = $atomicMarkerStatusValue
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

        # Kill switch: FRAME_ENFORCE=0 coerces warn mode regardless of -Mode parameter.
        if ($env:FRAME_ENFORCE -eq '0') {
            $Mode = 'warn'
        }

        # Activation cutover: only enforce for PRs created after the activation timestamp.
        # Reads enforce-activation.yaml from the repo (which is the base-ref checkout in CI).
        # If the file is absent, timestamp is unset, or PR_CREATED_AT is not passed,
        # fall back to warn mode (advisory ship behavior).
        # Test hook: FRAME_CREDIT_LEDGER_TEST_SKIP_ACTIVATION_CUTOVER=1 bypasses this check.
        if ($Mode -eq 'enforce' -and $env:FRAME_CREDIT_LEDGER_TEST_SKIP_ACTIVATION_CUTOVER -ne '1') {
            $activationFile = Join-Path (script:Resolve-FCLRepoRoot -ScriptPath $PSCommandPath) 'frame/enforce-activation.yaml'
            $activationTimestamp = $null
            if (Test-Path -LiteralPath $activationFile -PathType Leaf) {
                try {
                    $activationRaw = Get-Content -LiteralPath $activationFile -Raw -ErrorAction Stop
                    $activationTsStr = script:Get-FCLScalar -Block $activationRaw -Name 'activation_timestamp'
                    if (-not [string]::IsNullOrWhiteSpace($activationTsStr)) {
                        $activationTimestamp = [DateTimeOffset]::Parse($activationTsStr, $null, [System.Globalization.DateTimeStyles]::RoundtripKind)
                    }
                }
                catch {
                    [Console]::Error.WriteLine("frame-credit-ledger: failed to read activation timestamp — falling back to warn mode: $($_.Exception.Message)")
                    $Mode = 'warn'
                }
            } else {
                [Console]::Error.WriteLine("frame-credit-ledger: enforce-activation.yaml not found — falling back to warn mode (advisory ship)")
                $Mode = 'warn'
            }

            # Check PR created-at against the activation timestamp.
            if ($Mode -eq 'enforce' -and $null -ne $activationTimestamp) {
                $prCreatedAtStr = $env:PR_CREATED_AT
                if (-not [string]::IsNullOrWhiteSpace($prCreatedAtStr)) {
                    try {
                        $prCreatedAt = [DateTimeOffset]::Parse($prCreatedAtStr, $null, [System.Globalization.DateTimeStyles]::RoundtripKind)
                        if ($prCreatedAt -lt $activationTimestamp) {
                            [Console]::Error.WriteLine("frame-credit-ledger: PR created at $prCreatedAtStr is before activation timestamp $activationTsStr — falling back to warn mode")
                            $Mode = 'warn'
                        }
                    }
                    catch {
                        [Console]::Error.WriteLine("frame-credit-ledger: failed to parse PR_CREATED_AT '$prCreatedAtStr' — falling back to warn mode: $($_.Exception.Message)")
                        $Mode = 'warn'
                    }
                } else {
                    # PR_CREATED_AT not set (e.g., local invocation) — skip the cutover check; enforce as-is
                    [Console]::Error.WriteLine("frame-credit-ledger: PR_CREATED_AT not set — skipping activation cutover check")
                }
            }

            # Handle far-future activation timestamp (advisory ship default)
            if ($Mode -eq 'enforce' -and $null -ne $activationTimestamp) {
                $farFuture = [DateTimeOffset]::new(9999, 12, 31, 0, 0, 0, [TimeSpan]::Zero)
                if ($activationTimestamp -ge $farFuture) {
                    [Console]::Error.WriteLine("frame-credit-ledger: activation timestamp is far-future sentinel — falling back to warn mode (advisory ship)")
                    $Mode = 'warn'
                }
            }
        }

        $iss = script:New-FCLInitialSessionStateClone

        $rs = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace($iss)
        $rs.Open()
        $worker = [System.Management.Automation.PowerShell]::Create()
        $worker.Runspace = $rs

        # Resolve repo root in the parent scope (where $PSCommandPath is set)
        # and pass it through so the worker doesn't need to re-derive it.
        $resolvedRepoRoot = script:Resolve-FCLRepoRoot -ScriptPath $PSCommandPath

        $costScriptState = script:Get-FCLCostScriptState

        $null = $worker.AddScript({
                param($PrArg, $ModeArg, $RepoRootArg, $CostScriptStateArg)
                foreach ($costStateName in @($CostScriptStateArg.Keys)) {
                    Set-Variable -Scope Script -Name $costStateName -Value $CostScriptStateArg[$costStateName]
                }
                $script:FrameCreditLedgerRepoRoot = $RepoRootArg
                Invoke-FrameCreditLedger -Pr $PrArg -Mode $ModeArg
            }).AddArgument($Pr).AddArgument($Mode).AddArgument($resolvedRepoRoot).AddArgument($costScriptState)

        $async = $worker.BeginInvoke()
        $waited = $async.AsyncWaitHandle.WaitOne([int]($budgetSeconds * 1000))

        $result = $null
        if ($waited) {
            try {
                $result = $worker.EndInvoke($async)
            }
            catch {
                [Console]::Error.WriteLine("frame-credit-ledger: $($_.Exception.Message)")
                if ($Mode -eq 'enforce') { $exitCode = 5 }
            }
            # Mirror stderr from the worker.
            foreach ($errRecord in $worker.Streams.Error) {
                try { [Console]::Error.WriteLine([string]$errRecord) } catch { $null = $_ }
            }
        }
        else {
            # Budget exceeded: timeout-deferred conclusion in enforce mode.
            try { $worker.Stop() } catch { $null = $_ }
            [Console]::Error.WriteLine("frame-credit-ledger: ${budgetSeconds}s budget exceeded; timeout-deferred (exit 4 in enforce mode, exit 0 in warn mode)")
            if ($Mode -eq 'enforce') {
                $exitCode = 4
            } else {
                $exitCode = 0
            }
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
                $hasBlock = $false
                $isInternalError = $false
                if ($null -ne $resultHash['IsInternalError']) { $isInternalError = [bool]$resultHash['IsInternalError'] }
                if ($null -ne $resultHash['HasBlock']) { $hasBlock = [bool]$resultHash['HasBlock'] }
                # Also support legacy HasNotCovered key for backward compat
                elseif ($null -ne $resultHash['HasNotCovered']) { $hasBlock = [bool]$resultHash['HasNotCovered'] }
                if ($Mode -eq 'enforce') {
                    if ($isInternalError) { $exitCode = 5 }
                    elseif ($hasBlock) { $exitCode = 3 }
                }
                if ($null -ne $resultHash['Comment'] -and -not [string]::IsNullOrEmpty([string]$resultHash['Comment'])) {
                    Write-Output ([string]$resultHash['Comment'])
                }
            }
        }
    }
    catch {
        [Console]::Error.WriteLine("frame-credit-ledger: $($_.Exception.Message)")
        if ($Mode -eq 'enforce') {
            $exitCode = 5
        }
        else {
            $exitCode = 0
        }
    }

    exit $exitCode
}
