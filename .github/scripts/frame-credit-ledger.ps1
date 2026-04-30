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

# ---------------------------------------------------------------------------
# Library dot-sources
# ---------------------------------------------------------------------------
. (Join-Path $PSScriptRoot 'lib/frame-predicate-core.ps1')
. (Join-Path $PSScriptRoot 'lib/find-or-upsert-comment.ps1')
. (Join-Path $PSScriptRoot 'lib/frame-credit-ledger-core.ps1')

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
        catch { }
    }

    $skillsDir = Join-Path $RepoRoot 'skills'
    if (Test-Path -LiteralPath $skillsDir -PathType Container) {
        try {
            Get-ChildItem -LiteralPath $skillsDir -Recurse -File -Filter 'SKILL.md' -ErrorAction Stop |
                ForEach-Object { $candidatePaths.Add($_.FullName) | Out-Null }
        }
        catch { }
        try {
            # skills/**/adapters/*.md
            Get-ChildItem -LiteralPath $skillsDir -Recurse -Directory -Filter 'adapters' -ErrorAction Stop |
                ForEach-Object {
                    Get-ChildItem -LiteralPath $_.FullName -File -Filter '*.md' -ErrorAction SilentlyContinue |
                        ForEach-Object { $candidatePaths.Add($_.FullName) | Out-Null }
                    }
        }
        catch { }
    }

    $commandsDir = Join-Path $RepoRoot 'commands'
    if (Test-Path -LiteralPath $commandsDir -PathType Container) {
        try {
            Get-ChildItem -LiteralPath $commandsDir -Recurse -File -Filter '*.md' -ErrorAction Stop |
                ForEach-Object { $candidatePaths.Add($_.FullName) | Out-Null }
        }
        catch { }
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
            $providesMatch = [regex]::Match($fm, '(?m)^\s*provides\s*:\s*(?<v>.+?)\s*$')
            if (-not $providesMatch.Success) { continue }
            $providesValue = $providesMatch.Groups['v'].Value.Trim()
            # Strip wrapping quotes.
            if ($providesValue.Length -ge 2) {
                $first = $providesValue[0]; $last = $providesValue[$providesValue.Length - 1]
                if (($first -eq '"' -and $last -eq '"') -or ($first -eq "'" -and $last -eq "'")) {
                    $providesValue = $providesValue.Substring(1, $providesValue.Length - 2)
                }
            }

            $appliesWhenMatch = [regex]::Match($fm, '(?m)^\s*applies-when\s*:\s*(?<v>.+?)\s*$')
            $appliesWhen = if ($appliesWhenMatch.Success) { $appliesWhenMatch.Groups['v'].Value.Trim() } else { $null }
            if ($appliesWhen -and $appliesWhen.Length -ge 2) {
                $first = $appliesWhen[0]; $last = $appliesWhen[$appliesWhen.Length - 1]
                if (($first -eq '"' -and $last -eq '"') -or ($first -eq "'" -and $last -eq "'")) {
                    $appliesWhen = $appliesWhen.Substring(1, $appliesWhen.Length - 2)
                }
            }

            $nextStepMatch = [regex]::Match($fm, '(?m)^\s*suggested-next-step\s*:\s*(?<v>.+?)\s*$')
            $suggestedNextStep = if ($nextStepMatch.Success) { $nextStepMatch.Groups['v'].Value.Trim() } else { $null }
            if ($suggestedNextStep -and $suggestedNextStep.Length -ge 2) {
                $first = $suggestedNextStep[0]; $last = $suggestedNextStep[$suggestedNextStep.Length - 1]
                if (($first -eq '"' -and $last -eq '"') -or ($first -eq "'" -and $last -eq "'")) {
                    $suggestedNextStep = $suggestedNextStep.Substring(1, $suggestedNextStep.Length - 2)
                }
            }

            $nameMatch = [regex]::Match($fm, '(?m)^\s*name\s*:\s*(?<v>.+?)\s*$')
            $name = if ($nameMatch.Success) { $nameMatch.Groups['v'].Value.Trim() } else { [System.IO.Path]::GetFileNameWithoutExtension($path) }
            if ($name.Length -ge 2) {
                $first = $name[0]; $last = $name[$name.Length - 1]
                if (($first -eq '"' -and $last -eq '"') -or ($first -eq "'" -and $last -eq "'")) {
                    $name = $name.Substring(1, $name.Length - 2)
                }
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
                # parse failure - fall through to next attempt
            }
        }
    }

    [Console]::Error.WriteLine("frame-credit-ledger: failed to resolve baseRefOid for PR $Pr after 3 attempts (gh retry exhausted)")
    return $null
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

    # 2. Fetch PR body.
    $bodyJsonRaw = $null
    try {
        $bodyJsonRaw = & gh pr view $Pr --json body 2>$null
    }
    catch {
        $bodyJsonRaw = $null
    }

    $prBody = ''
    if ($null -ne $bodyJsonRaw -and $bodyJsonRaw -ne '') {
        try {
            $parsed = $bodyJsonRaw | ConvertFrom-Json -ErrorAction Stop
            if ($null -ne $parsed -and $null -ne $parsed.body) {
                $prBody = [string]$parsed.body
            }
        }
        catch {
            $prBody = ''
        }
    }

    # 3. Parse pipeline-metrics block.
    $metrics = Read-PRMetricsBlock -PrBody $prBody

    # 4. Pre-v4 short-circuit.
    if ($null -eq $metrics -or $metrics.MetricsVersion -ne 4) {
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

    # Build per-port reports.
    $portReports = [System.Collections.Generic.List[object]]::new()

    if (@($ports).Count -gt 0) {
        foreach ($port in $ports) {
            $portName = [string]$port.Name
            $matchingAdapters = @($adapters | Where-Object { [string]$_.Provides -eq $portName })
            $applicableMap = @{}
            foreach ($a in $matchingAdapters) {
                $applicableMap[[string]$a.Name] = 'unknown'
            }
            $credit = $credits | Where-Object { [string]$_.Port -eq $portName } | Select-Object -First 1

            $report = Resolve-PortStatus -Port $port -WorkAdapters $matchingAdapters -ApplicableMap $applicableMap -Credit $credit
            $portReports.Add($report) | Out-Null
        }
    }
    else {
        # No port catalog available — synthesize port reports directly from credits so we can still emit a meaningful ledger.
        foreach ($credit in $credits) {
            $portName = [string]$credit.Port
            $synthPort = [pscustomobject]@{ Name = $portName }
            $report = Resolve-PortStatus -Port $synthPort -WorkAdapters @() -ApplicableMap @{} -Credit $credit
            $portReports.Add($report) | Out-Null
        }
    }

    $reportsArray = $portReports.ToArray()
    $hasNotCovered = @($reportsArray | Where-Object { [string]$_.Status -eq 'NotCovered' }).Count -gt 0

    $comment = Compose-Comment -MarkerToken $marker -PortReports $reportsArray
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
        $parentFunctions = Get-ChildItem -Path Function:\ -ErrorAction SilentlyContinue
        foreach ($fn in $parentFunctions) {
            try {
                $entry = New-Object System.Management.Automation.Runspaces.SessionStateFunctionEntry($fn.Name, $fn.Definition)
                $iss.Commands.Add($entry)
            }
            catch { }
        }

        # Copy global variables (e.g. $global:GhCallLog used by the test mock).
        $parentGlobals = Get-Variable -Scope Global -ErrorAction SilentlyContinue
        foreach ($v in $parentGlobals) {
            # Skip automatic variables that would conflict.
            if ($v.Name -in @('null', 'true', 'false', 'PID', 'PSVersionTable', 'PSHOME', 'Host', 'ExecutionContext', 'MyInvocation', 'PSCulture', 'PSUICulture', 'ShellId', 'HOME', 'PWD', 'Error', 'PSCommandPath', 'PSScriptRoot', 'StackTrace', 'IsLinux', 'IsMacOS', 'IsWindows', 'IsCoreCLR', '?', '^', '$', 'args', 'input', '_')) { continue }
            try {
                $entry = New-Object System.Management.Automation.Runspaces.SessionStateVariableEntry($v.Name, $v.Value, '')
                $iss.Variables.Add($entry)
            }
            catch { }
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
                try { [Console]::Error.WriteLine([string]$errRecord) } catch { }
            }
        }
        else {
            # Budget exceeded — abort the worker and fail open.
            try { $worker.Stop() } catch { }
            [Console]::Error.WriteLine("frame-credit-ledger: ${budgetSeconds}s budget exceeded; warn-mode fail-open (no comment posted)")
            # Warn-mode invariant: never block PR creation on timeout. In
            # enforce mode the test still expects exit 0 on timeout (warn
            # invariant takes precedence over enforcement when no decision
            # could be made).
            $exitCode = 0
        }

        try { $worker.Dispose() } catch { }
        try { $rs.Close(); $rs.Dispose() } catch { }

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
