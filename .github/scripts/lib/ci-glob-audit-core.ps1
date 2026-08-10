#Requires -Version 7.0

# ci-glob-audit-core.ps1
# The full-glob CI audit: run EVERY suite the per-PR gate enumerates on disk,
# on Linux, with the quarantine deliberately NOT applied, and record what
# happened to each one durably enough for three later chunks to read.
#
# WHY THIS EXISTS (issue #1035, chunk 1 of 4 under #993). The gate selects a
# glob minus a quarantine. 191 of 252 suites are quarantined; 189 of those
# carry class `unclassified`, which is not a decision — they were omitted by an
# allowlist that no longer exists and their CI-viability has never been
# measured anywhere but a maintainer's Windows machine. #1036 must split those
# into "promote it" and "it structurally cannot run here", and its charter says
# that split happens WITH A FAILURE MESSAGE IN HAND rather than by reading
# source and guessing. #1037 must size shards from a measured per-suite
# duration distribution over the whole population. Neither input exists.
#
# WHY IT COULD NOT JUST REUSE THE SHARDED RUNNER. `pester-sharded-core.ps1`
# emits counts and never a message, so a row saying `fail=3` cannot tell #1036
# whether a suite has a Linux path bug or needs a live `gh`. It also imposes no
# bound: `Start-Process -Wait` takes none and no workflow here sets
# `timeout-minutes`, so a suite that never returns occupies its slot to
# GitHub's 360-minute ceiling and is neither a pass, a failure, nor a reported
# skip. This audit attempts, by design, exactly the population most likely to
# contain one.
#
# FOUR TERMINAL STATES, NOT THREE. passed / failed / did-not-complete /
# executed-no-tests. The fourth is load-bearing: a `Describe` behind a platform
# guard completed, did not fail, and must never read as passed — and the
# sharded runner gets it wrong in BOTH directions (it increments $totalFailed
# for a zero-discovery suite at :681, while an all-skipped suite reaches exit 0
# with Failed = 0 and reads as green).
#
# NO FILE-SCOPE Set-StrictMode HERE. Same reason ci-suite-selection-core.ps1
# gives: this file is dot-sourced into sessions that then run other people's
# code, and a leaked strict mode turns unrelated suites red. Each function sets
# it in its own scope.

$script:CIGlobAuditLibDir = Split-Path -Parent $PSCommandPath
. (Join-Path -Path $script:CIGlobAuditLibDir -ChildPath 'ci-suite-selection-core.ps1')

# GitHub caps an issue/comment body at 65,536 codepoints and refuses the write
# above it. Discovering that mid-run is the failure mode this constant exists
# to prevent; the record composer paginates against it rather than truncating
# detail to fit.
$script:CIGlobAuditBodyCap = 65536

# The four terminal states, in the order they are reported. `did-not-complete`
# is not "failed with a timeout" and `executed-no-tests` is not "passed with
# zero tests" — the whole point of the record is that a reader can tell the
# four apart without opening the suite.
$script:CIGlobAuditStates = @('passed', 'failed', 'did-not-complete', 'executed-no-tests')

#region population

function Get-CIGlobAuditPopulation {
    <#
    .SYNOPSIS
        The set of suites this audit must attempt: the gate's own on-disk
        enumeration BEFORE the quarantine is subtracted.
    .DESCRIPTION
        Derived from the gate's own selection procedure rather than re-globbed,
        so the audit tracks corpus drift instead of encoding today's count, and
        so it cannot quietly measure a different population than the gate does.

        `Get-CISuiteSelection` does not return the on-disk collection — it
        computes it internally and surfaces only `Selected` (files) and
        `Quarantined` (REGISTRY ENTRIES, which is not the same thing). The
        sound derivation is therefore

            Selected  UNION  (Quarantined.file  MINUS  StaleQuarantine)

        and it equals the on-disk set ONLY while HasDrift is false: a stale
        entry naming a file that no longer exists still inflates `Quarantined`,
        and an unaccounted file is on disk in neither set.

        THIS FUNCTION THROWS ON DRIFT, deliberately, and offers no override.
        A fail-closed predicate whose caller carries on regardless is a
        fail-open writer; the only way to make the precondition load-bearing is
        for the derivation to be unavailable without it.
    .PARAMETER TestsRoot
        Directory holding the `*.Tests.ps1` files — the gate's tests root.
    .PARAMETER QuarantinePath
        Path to the gate's quarantine registry.
    .OUTPUTS
        [PSCustomObject] with Names [string[]] (sorted), Files [string[]]
        (full paths, index-aligned with Names), ClassByName [hashtable]
        (suite name -> quarantine class, or $null for a selected suite),
        SelectedNames [string[]], SelectedCount, QuarantinedCount,
        StaleQuarantine [string[]], UnclassifiedCount, HasDrift ($false — a
        true value throws before returning), DerivationCommand [string].
    #>
    param(
        [Parameter(Mandatory)][string]$TestsRoot,
        [Parameter(Mandatory)][string]$QuarantinePath
    )

    Set-StrictMode -Version Latest

    $selection = Get-CISuiteSelection -TestsRoot $TestsRoot -QuarantinePath $QuarantinePath

    if ($selection.HasDrift) {
        throw ("ci-glob-audit: refusing to derive a population from a drifted registry. " +
            "The derivation `Selected + (Quarantined - Stale)` equals the on-disk set only while " +
            "HasDrift is false, so a drifted tree would yield a population that silently omits or " +
            "invents suites. Drift: " + ($selection.DriftDetails -join ' | '))
    }

    $classByName = @{}
    $quarantinedNames = [System.Collections.Generic.List[string]]::new()
    foreach ($entry in @($selection.Quarantined)) {
        $file = [string]$entry.file
        if ([string]::IsNullOrWhiteSpace($file)) { continue }
        if ($selection.StaleQuarantine -contains $file) { continue }
        $quarantinedNames.Add($file)
        $classByName[$file] = [string]$entry.class
    }
    foreach ($name in @($selection.SelectedNames)) { $classByName[$name] = $null }

    $names = @(@($selection.SelectedNames) + @($quarantinedNames) | Sort-Object -Unique)
    $files = @($names | ForEach-Object { Join-Path -Path $TestsRoot -ChildPath $_ })

    return [PSCustomObject]@{
        Names             = $names
        Files             = $files
        ClassByName       = $classByName
        SelectedNames     = @($selection.SelectedNames)
        SelectedCount     = @($selection.Selected).Count
        QuarantinedCount  = @($selection.Quarantined).Count
        StaleQuarantine   = @($selection.StaleQuarantine)
        UnclassifiedCount = $selection.UnclassifiedCount
        HasDrift          = $false
        DerivationCommand = "Get-CISuiteSelection -TestsRoot '$TestsRoot' -QuarantinePath '$QuarantinePath'; Selected UNION (Quarantined.file MINUS StaleQuarantine)"
    }
}

function Get-CIGlobAuditContentDigest {
    <#
    .SYNOPSIS
        A suite's content fingerprint — the axis on which two observations are
        observations of the SAME suite.
    .DESCRIPTION
        A history keyed on file name alone reports "two observations" for a
        suite that was rewritten between them. Hashed over raw bytes so a line
        ending change is visible rather than normalised away; a suite whose
        bytes changed is a different subject even if its tests did not.
    #>
    param([Parameter(Mandatory)][string]$Path)

    Set-StrictMode -Version Latest

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return 'missing' }
    $hash = Get-FileHash -LiteralPath $Path -Algorithm SHA256
    return $hash.Hash.Substring(0, 12).ToLowerInvariant()
}

function Get-CIGlobAuditShardAssignment {
    <#
    .SYNOPSIS
        Which shard runs which suite. Deterministic, and stated rather than
        implied, because every job derives the same assignment independently.
    .DESCRIPTION
        Round-robin over the sorted name list. Round-robin rather than
        contiguous blocks because nothing here knows a suite's duration yet —
        that distribution is what this audit exists to produce — so the only
        defensible spreading rule is one that does not assume alphabetical
        neighbours are alike. It also spreads any cluster of non-returning
        suites across jobs instead of concentrating them in one.
    .OUTPUTS
        [int[]] shard index per input item, index-aligned with -Names.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Names,
        [Parameter(Mandatory)][ValidateRange(1, 64)][int]$ShardCount
    )

    Set-StrictMode -Version Latest

    $assignment = @()
    for ($i = 0; $i -lt $Names.Count; $i++) { $assignment += ($i % $ShardCount) }
    return , $assignment
}

#endregion

#region classification

function ConvertTo-CIGlobAuditState {
    <#
    .SYNOPSIS
        The classifier: one suite's raw execution outcome -> one of the four
        terminal states, plus the reason that made it that state.
    .DESCRIPTION
        Pure, so it can be driven to every state including the ones a live run
        may not exhibit. The ORDER of these rules is the contract:

          1. The child did not return within the bound  -> did-not-complete.
             Checked first: a suite that never returned has no trustworthy
             counts, and reading counts off a killed process is how a hang
             becomes a green row.
          2. No parsable result file                    -> failed.
             The launcher writes its result BEFORE it exits, so a completed
             child with no result crashed, threw during discovery, or was
             killed by the OS. "Nothing to read" is never "nothing wrong".
          3. Exit code inconsistent with the counts     -> failed.
             The launcher's exit code is a pure function of its own failure
             count. A disagreement means something exited around it.
          4. Any failed test or failed container        -> failed.
             Container failures cover discovery-time throws, which produce no
             failed TEST and would otherwise read as executed-no-tests.
          5. At least one test EXECUTED and passed      -> passed.
             Executed, not discovered: exit 0 with Failed = 0 is also what a
             suite that ran nothing produces, and separating those two is the
             entire reason this classifier exists.
          6. Otherwise                                  -> executed-no-tests,
             sub-classified `no-tests-discovered` vs `all-skipped`. Both
             completed, neither failed, neither ran anything.
    .OUTPUTS
        [PSCustomObject] State, Reason, Executed, Discovered.
    #>
    param(
        [Parameter(Mandatory)][bool]$Completed,
        [int]$ExitCode = 0,
        [Parameter(Mandatory)][bool]$HasResult,
        [int]$Passed = 0,
        [int]$Failed = 0,
        [int]$Skipped = 0,
        [int]$NotRun = 0,
        [int]$ContainerFailed = 0
    )

    Set-StrictMode -Version Latest

    if (-not $Completed) {
        return [PSCustomObject]@{
            State = 'did-not-complete'; Reason = 'bound-exceeded'
            Executed = 0; Discovered = 0
        }
    }

    $discovered = $Passed + $Failed + $Skipped + $NotRun
    $executed = $Passed + $Failed
    $failures = $Failed + $ContainerFailed

    if (-not $HasResult) {
        return [PSCustomObject]@{
            State = 'failed'; Reason = 'no-result-file'
            Executed = 0; Discovered = 0
        }
    }

    $expectedExit = if ($failures -gt 0) { 1 } else { 0 }
    if ($ExitCode -ne $expectedExit) {
        return [PSCustomObject]@{
            State = 'failed'; Reason = "exit-code-inconsistent (exit $ExitCode, expected $expectedExit for $failures failure(s))"
            Executed = $executed; Discovered = $discovered
        }
    }

    if ($failures -gt 0) {
        $reason = if ($Failed -gt 0) { 'test-failures' } else { 'container-failure' }
        return [PSCustomObject]@{
            State = 'failed'; Reason = $reason
            Executed = $executed; Discovered = $discovered
        }
    }

    if ($executed -gt 0) {
        return [PSCustomObject]@{
            State = 'passed'; Reason = 'tests-executed-and-passed'
            Executed = $executed; Discovered = $discovered
        }
    }

    $reason = if ($discovered -eq 0) { 'no-tests-discovered' } else { 'all-skipped' }
    return [PSCustomObject]@{
        State = 'executed-no-tests'; Reason = $reason
        Executed = 0; Discovered = $discovered
    }
}

function Get-CIGlobAuditDetail {
    <#
    .SYNOPSIS
        The classifying detail a non-passed row carries — what #1036 reads
        instead of opening the suite's source.
    .DESCRIPTION
        A count is not detail. "fail=3" cannot distinguish a Linux path bug
        from a suite that needs a live `gh`, and that distinction is the whole
        job of the chunk downstream of this one.

        Structured failure messages first, because they are what actually
        classifies; captured console output only as the fallback, and TAIL
        rather than head — for a suite that never returned, the last thing it
        printed is where it stopped, and an auth prompt is also at the tail.

        An empty return is honest, not a gap to paper over: a suite that
        blocked before emitting anything leaves nothing to capture. The record
        renders such a row explicitly as nothing-emitted and names it as a row
        #1036 cannot classify, rather than manufacturing text.
    #>
    param(
        [Parameter(Mandatory)][string]$State,
        [string]$Reason = '',
        [object[]]$Failures = @(),
        [object[]]$Skips = @(),
        [string[]]$ContainerErrors = @(),
        [string]$StdOut = '',
        [string]$StdErr = '',
        [int]$TailChars = 4000
    )

    Set-StrictMode -Version Latest

    $parts = [System.Collections.Generic.List[string]]::new()

    foreach ($f in @($Failures)) {
        $name = if ($f.PSObject.Properties.Match('name').Count -gt 0) { [string]$f.name } else { '' }
        $msg = if ($f.PSObject.Properties.Match('message').Count -gt 0) { [string]$f.message } else { '' }
        $line = (($name, $msg) | Where-Object { $_ } ) -join ' -- '
        if ($line) { $parts.Add($line) }
    }
    foreach ($e in @($ContainerErrors)) { if ($e) { $parts.Add("container: $e") } }

    if ($State -eq 'executed-no-tests') {
        foreach ($s in @($Skips)) {
            $name = if ($s.PSObject.Properties.Match('name').Count -gt 0) { [string]$s.name } else { '' }
            $msg = if ($s.PSObject.Properties.Match('message').Count -gt 0) { [string]$s.message } else { '' }
            $line = (($name, $msg) | Where-Object { $_ }) -join ' -- '
            if ($line) { $parts.Add("skipped: $line") }
        }
    }

    if ($parts.Count -eq 0) {
        $tail = script:Get-CIGlobAuditTail -Text (@($StdErr, $StdOut) -join "`n") -TailChars $TailChars
        if ($tail) { $parts.Add($tail) }
    }

    return (($parts | Select-Object -Unique) -join "`n").Trim()
}

function script:Get-CIGlobAuditTail {
    param([string]$Text, [int]$TailChars)
    if ([string]::IsNullOrWhiteSpace($Text)) { return '' }
    $t = $Text.Trim()
    if ($t.Length -le $TailChars) { return $t }
    return '...(head elided)... ' + $t.Substring($t.Length - $TailChars)
}

#endregion

#region execution

function Get-CIGlobAuditLauncherScript {
    <#
    .SYNOPSIS
        The script one child process runs to execute one suite.
    .DESCRIPTION
        Writes its result file BEFORE exiting and captures failure MESSAGES,
        not just counts — the two properties `pester-sharded-core.ps1` lacks
        that make this audit's record usable by #1036.

        Container results are counted separately: a throw during discovery
        produces a failed CONTAINER and no failed test, which without this
        would arrive as "completed, nothing ran".
    #>
    param(
        [Parameter(Mandatory)][string]$SuiteFile,
        [Parameter(Mandatory)][string]$ResultFile,
        [string]$OutputVerbosity = 'Detailed',
        [int]$MaxFailures = 25,
        [int]$MaxSkips = 10,
        [int]$MaxMessageChars = 1200
    )

    $suite = $SuiteFile -replace "'", "''"
    $result = $ResultFile -replace "'", "''"

    return @"
#Requires -Version 7.0
# Generated by ci-glob-audit-core.ps1. One suite, one process, one result file.
`$ErrorActionPreference = 'Continue'
function Limit-Text([string]`$s) {
    if (-not `$s) { return '' }
    if (`$s.Length -le $MaxMessageChars) { return `$s }
    return `$s.Substring(0, $MaxMessageChars) + '...(truncated)'
}
try {
    `$cfg = New-PesterConfiguration
    `$cfg.Run.Path = @('$suite')
    `$cfg.Run.Exit = `$false
    `$cfg.Run.PassThru = `$true
    `$cfg.Output.Verbosity = '$OutputVerbosity'
    `$r = Invoke-Pester -Configuration `$cfg

    `$passed = 0; `$failed = 0; `$skipped = 0; `$notRun = 0; `$containerFailed = 0
    `$failures = @(); `$skips = @(); `$containerErrors = @()

    if (`$null -ne `$r) {
        `$passed  = [int]`$r.PassedCount
        `$failed  = [int]`$r.FailedCount
        `$skipped = [int]`$r.SkippedCount
        `$notRun  = [int]`$r.NotRunCount

        foreach (`$c in @(`$r.Containers)) {
            if ([string]`$c.Result -eq 'Failed') {
                `$containerFailed++
                foreach (`$e in @(`$c.ErrorRecord)) {
                    if (`$null -ne `$e) { `$containerErrors += (Limit-Text ([string]`$e.Exception.Message)) }
                }
            }
        }
        foreach (`$t in @(`$r.Failed)) {
            if (`$failures.Count -ge $MaxFailures) { break }
            `$msg = ''
            foreach (`$e in @(`$t.ErrorRecord)) { if (`$null -ne `$e -and -not `$msg) { `$msg = [string]`$e.Exception.Message } }
            `$failures += [ordered]@{ name = [string]`$t.ExpandedPath; message = (Limit-Text `$msg) }
        }
        foreach (`$t in @(`$r.Skipped)) {
            if (`$skips.Count -ge $MaxSkips) { break }
            `$msg = ''
            foreach (`$e in @(`$t.ErrorRecord)) { if (`$null -ne `$e -and -not `$msg) { `$msg = [string]`$e.Exception.Message } }
            `$skips += [ordered]@{ name = [string]`$t.ExpandedPath; message = (Limit-Text `$msg) }
        }
    }

    `$payload = [ordered]@{
        passed = `$passed; failed = `$failed; skipped = `$skipped; notRun = `$notRun
        containerFailed = `$containerFailed
        failures = `$failures; skips = `$skips; containerErrors = `$containerErrors
    }
    `$payload | ConvertTo-Json -Depth 6 -Compress | Set-Content -LiteralPath '$result' -Encoding utf8
    if ((`$failed + `$containerFailed) -gt 0) { exit 1 } else { exit 0 }
}
catch {
    # No result file on this path, deliberately: the classifier reads its
    # absence as `failed / no-result-file` rather than guessing counts.
    [Console]::Error.WriteLine("ci-glob-audit launcher: `$(`$_.Exception.Message)")
    [Console]::Error.WriteLine([string]`$_.ScriptStackTrace)
    exit 2
}
"@
}

function Invoke-CIGlobAuditSuite {
    <#
    .SYNOPSIS
        Attempt one suite, bounded, capturing everything needed to classify it.
    .DESCRIPTION
        THE BOUND IS THE POINT. Nothing under `.github/` bounds a test that
        never returns, and this audit runs the population most likely to
        contain one.

        "The bound fired" and "the slot is free" are TWO FACTS, and the
        repository's existing killable-process helper conflates them: it
        reports TimedOut = $true even when the kill threw, and its taskkill
        fallback is Windows-gated, leaving Linux with none. An orphaned child
        keeps consuming the runner and contaminates every later row's duration
        while each row individually looks well-formed. So this function kills
        the tree, WAITS for the corpse, and reports ProcessSurvivedKill per row
        — a run in which one survived is not offered as a timing measurement.
    .OUTPUTS
        [PSCustomObject] one record row (pre-classification fields plus State).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SuiteFile,
        [Parameter(Mandatory)][ValidateRange(1, 21600)][int]$TimeoutSeconds,
        [Parameter(Mandatory)][string]$WorkDir,
        [string]$OutputVerbosity = 'Detailed',
        [int]$KillGraceMs = 10000,
        [int]$DetailTailChars = 4000,
        [hashtable]$EnvironmentOverrides = @{}
    )

    Set-StrictMode -Version Latest

    if (-not (Test-Path -LiteralPath $WorkDir)) {
        New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null
    }

    $stem = [System.IO.Path]::GetFileNameWithoutExtension($SuiteFile) + '-' + [System.Guid]::NewGuid().ToString('N').Substring(0, 8)
    $launcherPath = Join-Path $WorkDir "$stem.launcher.ps1"
    $resultPath = Join-Path $WorkDir "$stem.result.json"
    $outPath = Join-Path $WorkDir "$stem.out.log"
    $errPath = Join-Path $WorkDir "$stem.err.log"

    $launcher = Get-CIGlobAuditLauncherScript -SuiteFile $SuiteFile -ResultFile $resultPath -OutputVerbosity $OutputVerbosity
    [System.IO.File]::WriteAllText($launcherPath, $launcher, [System.Text.UTF8Encoding]::new($false))

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = (Get-Process -Id $PID).Path
    foreach ($a in @('-NoProfile', '-NonInteractive', '-NoLogo', '-File', $launcherPath)) { $psi.ArgumentList.Add($a) | Out-Null }
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    # Redirect stdin from a closed stream too: a suite that blocks on a prompt
    # must fail or hang on its own account, never because this harness left a
    # live console attached that a human could accidentally satisfy.
    $psi.RedirectStandardInput = $true
    $psi.UseShellExecute = $false
    $psi.WorkingDirectory = (Get-Location).Path
    # Per-suite environment additions exist for ONE purpose: arming the
    # non-returning control. Applied to that child alone rather than to the
    # job, so every real suite meets exactly the environment the gate gives it
    # — an extra variable in the shared environment would be an avoidable
    # divergence, and the parity criterion treats those as failures.
    foreach ($k in $EnvironmentOverrides.Keys) { $psi.Environment[[string]$k] = [string]$EnvironmentOverrides[$k] }

    $proc = [System.Diagnostics.Process]::new()
    $proc.StartInfo = $psi

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $completed = $false
    $killEscalated = $false
    $survivedKill = $false
    $exitCode = $null
    $stdOut = ''
    $stdErr = ''

    try {
        $null = $proc.Start()
        $proc.StandardInput.Close()
        # Read both streams asynchronously BEFORE waiting: a child that fills
        # a redirected pipe buffer blocks forever on write, which would turn
        # every chatty suite into a fake did-not-complete row.
        $outTask = $proc.StandardOutput.ReadToEndAsync()
        $errTask = $proc.StandardError.ReadToEndAsync()

        $completed = $proc.WaitForExit($TimeoutSeconds * 1000)

        if (-not $completed) {
            $killEscalated = $true
            try { $proc.Kill($true) } catch { }
            try { $null = $proc.WaitForExit($KillGraceMs) } catch { }
            $survivedKill = -not $proc.HasExited
        }

        # Give the stream readers a bounded chance to drain. Bounded, because a
        # surviving orphan can hold the pipe open indefinitely and this must not
        # become the hang it exists to bound.
        foreach ($t in @($outTask, $errTask)) {
            try { $null = $t.Wait($KillGraceMs) } catch { }
        }
        if ($outTask.IsCompletedSuccessfully) { $stdOut = [string]$outTask.Result }
        if ($errTask.IsCompletedSuccessfully) { $stdErr = [string]$errTask.Result }

        if ($completed) { $exitCode = $proc.ExitCode }
    }
    catch {
        $stdErr = ($stdErr + "`n" + "ci-glob-audit host: $($_.Exception.Message)").Trim()
    }
    finally {
        $sw.Stop()
        try { $proc.Dispose() } catch { }
    }

    [System.IO.File]::WriteAllText($outPath, $stdOut, [System.Text.UTF8Encoding]::new($false))
    [System.IO.File]::WriteAllText($errPath, $stdErr, [System.Text.UTF8Encoding]::new($false))

    $hasResult = $false
    $passed = 0; $failed = 0; $skipped = 0; $notRun = 0; $containerFailed = 0
    $failures = @(); $skips = @(); $containerErrors = @()
    if ($completed -and (Test-Path -LiteralPath $resultPath)) {
        try {
            $data = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json
            $passed = [int]$data.passed; $failed = [int]$data.failed
            $skipped = [int]$data.skipped; $notRun = [int]$data.notRun
            $containerFailed = [int]$data.containerFailed
            $failures = @($data.failures); $skips = @($data.skips)
            $containerErrors = @($data.containerErrors | ForEach-Object { [string]$_ })
            $hasResult = $true
        }
        catch {
            # A malformed result file is not a result. Left $hasResult false so
            # the classifier reaches `failed / no-result-file` rather than
            # reading zeros as a clean run.
            $stdErr = ($stdErr + "`nci-glob-audit host: result file did not parse: $($_.Exception.Message)").Trim()
        }
    }

    $classification = ConvertTo-CIGlobAuditState -Completed $completed -ExitCode ([int]($exitCode ?? -1)) `
        -HasResult $hasResult -Passed $passed -Failed $failed -Skipped $skipped -NotRun $notRun `
        -ContainerFailed $containerFailed

    $detail = Get-CIGlobAuditDetail -State $classification.State -Reason $classification.Reason `
        -Failures $failures -Skips $skips -ContainerErrors $containerErrors `
        -StdOut $stdOut -StdErr $stdErr -TailChars $DetailTailChars

    return [PSCustomObject]@{
        Name               = Split-Path -Leaf $SuiteFile
        State              = $classification.State
        Reason             = $classification.Reason
        ElapsedMs          = [int]$sw.ElapsedMilliseconds
        BoundSeconds       = $TimeoutSeconds
        Completed          = $completed
        ExitCode           = $exitCode
        Passed             = $passed
        Failed             = $failed
        Skipped            = $skipped
        NotRun             = $notRun
        Discovered         = $classification.Discovered
        Executed           = $classification.Executed
        ContainerFailed    = $containerFailed
        KillEscalated      = $killEscalated
        ProcessSurvivedKill = $survivedKill
        Detail             = $detail
        StdOutPath         = $outPath
        StdErrPath         = $errPath
    }
}

function Invoke-CIGlobAuditShard {
    <#
    .SYNOPSIS
        Attempt every suite assigned to this shard, one at a time, and return
        the enriched rows.
    .DESCRIPTION
        ONE SUITE PROCESS AT A TIME, deliberately. Fanning out inside a job
        would make each per-suite wall clock a contended measurement, and the
        chunk downstream of this one sizes shards from that distribution: an
        8-way fan-out on a 2-core hosted runner inflates every duration by a
        factor nobody can back out of a single contended sample. Parallelism
        here is across JOBS, on separate runners, so no two measured suites
        ever share a machine.

        Every assigned suite is attempted. There is no elapsed-budget escape
        that would let the shard stop early and leave rows unattempted — a
        record in which a suite can appear without having been attempted is
        exactly the shape this whole audit exists to replace.
    .OUTPUTS
        [PSCustomObject[]] one row per assigned suite.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Assignments,
        [Parameter(Mandatory)][ValidateRange(1, 21600)][int]$TimeoutSeconds,
        [Parameter(Mandatory)][string]$WorkDir,
        [string]$OutputVerbosity = 'Detailed'
    )

    Set-StrictMode -Version Latest

    $rows = [System.Collections.Generic.List[object]]::new()
    $ordinal = 0
    foreach ($item in $Assignments) {
        $ordinal++
        Write-Host "[$ordinal/$($Assignments.Count)] $($item.Name) (bound ${TimeoutSeconds}s)"
        $overrides = @{}
        if ($item.PSObject.Properties.Match('EnvironmentOverrides').Count -gt 0 -and $item.EnvironmentOverrides) {
            foreach ($p in $item.EnvironmentOverrides.PSObject.Properties) { $overrides[$p.Name] = [string]$p.Value }
        }
        $row = Invoke-CIGlobAuditSuite -SuiteFile $item.Path -TimeoutSeconds $TimeoutSeconds `
            -WorkDir $WorkDir -OutputVerbosity $OutputVerbosity -EnvironmentOverrides $overrides
        $enriched = [PSCustomObject]@{
            Name                = $item.Name
            Path                = $item.Path
            InPopulation        = [bool]$item.InPopulation
            ControlRole         = [string]$item.ControlRole
            QuarantineClass     = $item.QuarantineClass
            ContentDigest       = Get-CIGlobAuditContentDigest -Path $item.Path
            State               = $row.State
            Reason              = $row.Reason
            ElapsedMs           = $row.ElapsedMs
            BoundSeconds        = $row.BoundSeconds
            Completed           = $row.Completed
            ExitCode            = $row.ExitCode
            Passed              = $row.Passed
            Failed              = $row.Failed
            Skipped             = $row.Skipped
            NotRun              = $row.NotRun
            Discovered          = $row.Discovered
            Executed            = $row.Executed
            ContainerFailed     = $row.ContainerFailed
            KillEscalated       = $row.KillEscalated
            ProcessSurvivedKill = $row.ProcessSurvivedKill
            Detail              = $row.Detail
        }
        Write-Host "    -> $($enriched.State) ($($enriched.Reason)) in $($enriched.ElapsedMs) ms"
        $rows.Add($enriched)
    }
    return , @($rows)
}

#endregion

#region environment, parity, reachability

function Get-CIGlobAuditRuntimeFacts {
    <#
    .SYNOPSIS
        Observe — never declare — what the suite-execution environment actually
        is on this runner.
    .DESCRIPTION
        The parity table's audit side must come from the RUN, not from the
        workflow file. A table populated from YAML is a transcript of intent:
        it says what the author meant to configure, and stays green when the
        configuration did something else. So every value here is read from the
        live process, the live git checkout, or the live module list, and each
        carries the observation that produced it.

        Two of these are only observable from inside the runner loop —
        `processModel` and `concurrency` — because they are properties of the
        program doing the observing. They are stated by the runner itself
        rather than by the workflow for the same reason: the runner is the only
        thing that knows how many suite processes it has in flight.
    .OUTPUTS
        [hashtable] of parity-table-ready strings plus an Observations map.
    #>
    param(
        [Parameter(Mandatory)][string]$ProcessModel,
        [Parameter(Mandatory)][string]$Concurrency,
        [string]$RepoRoot = ''
    )

    Set-StrictMode -Version Latest

    $tokenNames = @('GH_TOKEN', 'GITHUB_TOKEN', 'GH_ENTERPRISE_TOKEN')
    $tokensPresent = @($tokenNames | Where-Object { -not [string]::IsNullOrWhiteSpace([System.Environment]::GetEnvironmentVariable($_)) })
    $tokenAvailability = if ($tokensPresent.Count -eq 0) { 'observed: no token in the environment of the suite-executing process' }
    else { "observed: token(s) PRESENT ($($tokensPresent -join ', '))" }

    $gitDir = if ($RepoRoot) { $RepoRoot } else { (Get-Location).Path }
    function script:Invoke-CIGlobAuditGit {
        param([string]$Dir, [string[]]$GitArgs)
        try { return (& git -C $Dir @GitArgs 2>$null | Out-String).Trim() } catch { return '' }
    }

    $isShallow = script:Invoke-CIGlobAuditGit -Dir $gitDir -GitArgs @('rev-parse', '--is-shallow-repository')
    $commitCount = script:Invoke-CIGlobAuditGit -Dir $gitDir -GitArgs @('rev-list', '--count', 'HEAD')
    $checkoutDepth = if ($isShallow -eq 'true') { "observed: shallow, $commitCount commit(s) reachable => fetch-depth 1" }
    elseif ($isShallow -eq 'false') { "observed: full clone, $commitCount commit(s) reachable" }
    else { 'observed: not a git checkout' }

    $extraHeader = script:Invoke-CIGlobAuditGit -Dir $gitDir -GitArgs @('config', '--get-regexp', '^http\..*\.extraheader')
    $credentialPersistence = if ($extraHeader) { 'observed: true — an auth extraheader is present in the checkout''s git config' }
    else { 'observed: false — no auth extraheader in the checkout''s git config' }

    $userName = script:Invoke-CIGlobAuditGit -Dir $gitDir -GitArgs @('config', '--get', 'user.name')
    $userEmail = script:Invoke-CIGlobAuditGit -Dir $gitDir -GitArgs @('config', '--get', 'user.email')
    $gitIdentity = if ($userName -or $userEmail) { "observed: configured ($userName <$userEmail>)" } else { 'observed: none configured' }

    $pesterModule = Get-Module -ListAvailable -Name Pester | Sort-Object Version -Descending | Select-Object -First 1
    $yamlModule = Get-Module -ListAvailable -Name 'powershell-yaml' | Sort-Object Version -Descending | Select-Object -First 1
    $image = @($env:ImageOS, $env:ImageVersion) | Where-Object { $_ }

    return @{
        ProcessModel          = $ProcessModel
        Concurrency           = $Concurrency
        TokenAvailability     = $tokenAvailability
        CheckoutDepth         = $checkoutDepth
        CredentialPersistence = $credentialPersistence
        GitIdentity           = $gitIdentity
        WorkingDirectory      = "observed: $((Get-Location).Path)"
        RunnerImage           = if ($image) { ($image -join ' / ') } else { [string][System.Runtime.InteropServices.RuntimeInformation]::OSDescription }
        PowerShellVersion     = [string]$PSVersionTable.PSVersion
        PesterVersion         = if ($pesterModule) { [string]$pesterModule.Version } else { '(not installed)' }
        YamlModuleVersion     = if ($yamlModule) { [string]$yamlModule.Version } else { '(not installed)' }
        # Structured mirrors of the four dimensions whose agreement with the
        # gate is a yes/no rather than a judgement. The prose strings above are
        # for the reader; agreement is computed from THESE, because deciding
        # "does it agree" by pattern-matching the prose is how a table starts
        # reporting agreement it never checked.
        HasToken              = ($tokensPresent.Count -gt 0)
        IsShallow             = ($isShallow -eq 'true')
        CredentialsPersisted  = [bool]$extraHeader
        HasGitIdentity        = [bool]($userName -or $userEmail)
    }
}

function Get-CIGlobAuditEnvironmentStatement {
    <#
    .SYNOPSIS
        Per-dimension: what the gate's value is, what THIS run's value is, and
        whether they agree.
    .DESCRIPTION
        Parity is per-dimension or it is nothing. A single "parity holds"
        sentence is false on its face — the parent establishes the process
        model as structurally divergent, so a blanket claim is a lie about the
        one dimension everybody already knows differs.

        Where the gate states a CONSTRAINT rather than a value — a version
        window, a runner label, a checkout convention — the gate's side is that
        constraint. Fabricating an exact gate-side value would make the table
        read cleaner and say something untrue.

        Audit-side values come from the RUN, not from this repository's YAML:
        the runner's actual PowerShell and module versions appear in no
        workflow file, and a table that reads them off the workflow is a
        transcript of intent rather than a measurement.
    .OUTPUTS
        [PSCustomObject[]] Dimension, Gate, Audit, Agrees, Note.
    #>
    param(
        [Parameter(Mandatory)][hashtable]$Facts
    )

    Set-StrictMode -Version Latest

    foreach ($required in @('ProcessModel', 'Concurrency', 'TokenAvailability', 'CheckoutDepth', 'CredentialPersistence',
            'GitIdentity', 'WorkingDirectory', 'RunnerImage', 'PowerShellVersion', 'PesterVersion', 'YamlModuleVersion',
            'HasToken', 'IsShallow', 'CredentialsPersisted', 'HasGitIdentity')) {
        if (-not $Facts.ContainsKey($required)) {
            throw "ci-glob-audit: environment statement is missing observed fact '$required'. A dimension nobody measured is a dimension the parity claim silently skips."
        }
    }

    $ProcessModel = [string]$Facts['ProcessModel']
    $Concurrency = [string]$Facts['Concurrency']
    $TokenAvailability = [string]$Facts['TokenAvailability']
    $CheckoutDepth = [string]$Facts['CheckoutDepth']
    $CredentialPersistence = [string]$Facts['CredentialPersistence']
    $GitIdentity = [string]$Facts['GitIdentity']
    $WorkingDirectory = [string]$Facts['WorkingDirectory']
    $RunnerImage = [string]$Facts['RunnerImage']
    $PowerShellVersion = [string]$Facts['PowerShellVersion']
    $PesterVersion = [string]$Facts['PesterVersion']
    $YamlModuleVersion = [string]$Facts['YamlModuleVersion']

    $rows = @(
        [PSCustomObject]@{
            Dimension = 'runner OS image'
            Gate      = 'constraint: `runs-on: ubuntu-latest` (a label, not an image version)'
            Audit     = "resolved: $RunnerImage (runs-on: ubuntu-latest)"
            Agrees    = $true
            Note      = 'Same label, so the same floating image. The label is the only thing the gate pins; a drifting image is a dimension R9 pools on.'
        },
        [PSCustomObject]@{
            Dimension = 'process model'
            Gate      = 'one Invoke-Pester over all selected suites in a single pwsh process'
            Audit     = $ProcessModel
            Agrees    = $false
            Note      = 'Structurally divergent by the parent design (B1): a bound cannot be applied per suite inside one shared process. A duration measured one way does not predict the same suite measured the other.'
        },
        [PSCustomObject]@{
            Dimension = 'concurrency'
            Gate      = 'one job, one process, no parallelism'
            Audit     = $Concurrency
            Agrees    = $false
            Note      = 'Divergent, and stated because R7 depends on it: per-suite wall clock is only a usable distribution if nothing else ran on that runner at the same time.'
        },
        [PSCustomObject]@{
            Dimension = 'PowerShell version'
            Gate      = 'constraint: unstated in the workflow; whatever the runner image ships'
            Audit     = $PowerShellVersion
            Agrees    = $true
            Note      = 'Both take the image default; neither pins.'
        },
        [PSCustomObject]@{
            Dimension = 'Pester version'
            Gate      = 'constraint: window >= 6.0.0, <= 6.999.999 (pester.yml)'
            Audit     = $PesterVersion
            Agrees    = $true
            Note      = 'Installed through the same window, so the same floating patch. Within-window drift is a dimension R9 pools on.'
        },
        [PSCustomObject]@{
            Dimension = 'powershell-yaml version'
            Gate      = 'constraint: unpinned latest (pester.yml)'
            Audit     = $YamlModuleVersion
            Agrees    = $true
            Note      = 'Installed the same unpinned way. Omitting it would be an avoidable divergence that reddens every suite importing it.'
        },
        [PSCustomObject]@{
            Dimension = 'credential and token availability'
            Gate      = 'no permissions:, no env:, no token in the suite-running step'
            Audit     = $TokenAvailability
            Agrees    = (-not $Facts['HasToken'])
            Note      = 'Any token this run needs to persist its record is step-scoped away from suite execution. A suite that shells out to `gh` must meet the same nothing the gate gives it.'
        },
        [PSCustomObject]@{
            Dimension = 'checkout depth'
            Gate      = 'constraint: bare actions/checkout => fetch-depth 1'
            Audit     = $CheckoutDepth
            Agrees    = [bool]$Facts['IsShallow']
            Note      = 'Matters for any suite that reads history.'
        },
        [PSCustomObject]@{
            Dimension = 'credential persistence'
            Gate      = 'constraint: bare actions/checkout => persist-credentials true'
            Audit     = $CredentialPersistence
            Agrees    = [bool]$Facts['CredentialsPersisted']
            Note      = 'Matters for any suite that runs git against the origin remote.'
        },
        [PSCustomObject]@{
            Dimension = 'git identity'
            Gate      = 'none supplied by the workflow'
            Audit     = $GitIdentity
            Agrees    = (-not $Facts['HasGitIdentity'])
            Note      = 'The sharded runner writes a temp global gitconfig for its real-git shard, which is this repository''s own evidence that a class of suites needs one. Neither the gate nor this audit supplies it.'
        },
        [PSCustomObject]@{
            Dimension = 'working directory'
            Gate      = 'constraint: actions/checkout convention ($GITHUB_WORKSPACE)'
            Audit     = $WorkingDirectory
            Agrees    = $true
            Note      = ''
        }
    )

    return , $rows
}

function Get-CIGlobAuditGateAgreement {
    <#
    .SYNOPSIS
        Where the audit and the gate overlap, do they agree?
    .DESCRIPTION
        The audit runs the full population, so it already ran the gate's
        selected suites, and those are green under the gate today. The
        comparison is therefore a filter over a record the run already has —
        and it is the only check that can catch an AVOIDABLE divergence, which
        passes an honest per-dimension statement while making every outcome
        garbage. Enumeration reaches only the divergences somebody thought of.
    .OUTPUTS
        [PSCustomObject] OverlapCount, AgreeCount, Disagreements [rows].
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Rows,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$SelectedNames
    )

    Set-StrictMode -Version Latest

    $overlap = @($Rows | Where-Object { $SelectedNames -contains $_.Name })
    $disagree = @($overlap | Where-Object { $_.State -ne 'passed' })

    return [PSCustomObject]@{
        OverlapCount   = $overlap.Count
        AgreeCount     = $overlap.Count - $disagree.Count
        Disagreements  = $disagree
        GateExpectation = 'every gate-selected suite passes (the gate is green on the default branch)'
    }
}

function Get-CIGlobAuditReachability {
    <#
    .SYNOPSIS
        R4's standing property: is any suite this run recorded as
        `did-not-complete` reachable by a documented way of running this
        repository's tests?
    .DESCRIPTION
        Two documented paths, with DIFFERENT populations, and checking only the
        first is how a previous design came to recommend putting a
        deliberately non-returning suite in a subdirectory of the tests root —
        safe from the gate, and directly in the path of
        `Invoke-Pester .github/scripts/Tests/`, which the contributor
        instructions and the pull-request template both prescribe and which is
        recursive and never reads the quarantine.

        Reasoning about blast radius from what SELECTS a suite instead of what
        EXECUTES it is the error; the tests-root arm is the one that catches it.
    .OUTPUTS
        [PSCustomObject] Clean, GateReachable [string[]], TestsRootReachable [string[]].
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Rows,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$SelectedNames,
        [Parameter(Mandatory)][string]$TestsRoot
    )

    Set-StrictMode -Version Latest

    $rootFull = try { (Resolve-Path -LiteralPath $TestsRoot).Path } catch { $TestsRoot }
    $rootFull = $rootFull.TrimEnd('/', '\') + [System.IO.Path]::DirectorySeparatorChar

    $stalled = @($Rows | Where-Object { $_.State -eq 'did-not-complete' })
    $gateReachable = @($stalled | Where-Object { $SelectedNames -contains $_.Name } | ForEach-Object { $_.Name })
    $rootReachable = @($stalled | Where-Object {
            $p = [string]$_.Path
            $p -and $p.StartsWith($rootFull, [System.StringComparison]::OrdinalIgnoreCase)
        } | ForEach-Object { $_.Name })

    return [PSCustomObject]@{
        Clean              = (($gateReachable.Count -eq 0) -and ($rootReachable.Count -eq 0))
        GateReachable      = $gateReachable
        TestsRootReachable = $rootReachable
        StalledCount       = $stalled.Count
    }
}

#endregion

#region comparability basis and history

function Get-CIGlobAuditInstrumentBasis {
    <#
    .SYNOPSIS
        The instrument half of "two observations of the same thing".
    .DESCRIPTION
        B3 as widened: two observations count as observations of the same thing
        only if the suite's CONTENT and the run parameters that can change a
        terminal state were the same. Those parameters are not a fixed short
        list — they are the bound, the execution model, and every dimension the
        environment statement records as verdict-changing. A history blind to
        the instrument reports two comparable observations for a suite recorded
        `did-not-complete` at bound B and `passed` at 4B, and nothing anywhere
        calibrates the bound.

        Hashed over the DIMENSION VALUES rather than a version string, so a new
        dimension added to the statement automatically enters the basis instead
        of silently pooling across it.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$EnvironmentStatement,
        [Parameter(Mandatory)][int]$BoundSeconds
    )

    Set-StrictMode -Version Latest

    $parts = [System.Collections.Generic.List[string]]::new()
    $parts.Add("bound=$BoundSeconds")
    foreach ($row in ($EnvironmentStatement | Sort-Object Dimension)) {
        $parts.Add("$($row.Dimension)=$($row.Audit)")
    }
    $text = $parts -join '|'
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($text)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $hash = $sha.ComputeHash($bytes) } finally { $sha.Dispose() }
    return (-join ($hash[0..5] | ForEach-Object { $_.ToString('x2') }))
}

function Update-CIGlobAuditHistory {
    <#
    .SYNOPSIS
        The observation history: how many comparable observations a suite's
        outcome goes back, in a place whose lifetime is not Actions retention.
    .DESCRIPTION
        Keyed on (suite content digest + instrument basis), NOT on file name.
        A name key reports "two observations" for a suite rewritten between
        them; an instrument-blind key pools a `did-not-complete` at one bound
        with a `passed` at four times that bound. Both are the pooling error
        that would let #1036 promote on a stability never observed and #1047
        read an instrument change as a regression.

        A changed basis RESETS the count to 1 rather than incrementing, because
        the count answers "how many COMPARABLE observations", and the previous
        basis is retained on the row so the change itself is visible.

        Format is a fixed-width pipe table parsed back by this same function —
        a record that cannot be read back is not a history.
    .OUTPUTS
        [PSCustomObject] Body [string], Entries [object[]].
    #>
    param(
        [AllowEmptyString()][string]$ExistingBody = '',
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Rows,
        [Parameter(Mandatory)][string]$InstrumentBasis,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$Marker,
        [string]$Commit = ''
    )

    Set-StrictMode -Version Latest

    $prior = @{}
    foreach ($line in ($ExistingBody -split "`r?`n")) {
        if ($line -notmatch '^\|\s*`?([A-Za-z0-9._-]+\.Tests\.ps1)`?\s*\|') { continue }
        $cells = @($line.Trim('|') -split '\|' | ForEach-Object { $_.Trim().Trim('`') })
        if ($cells.Count -lt 6) { continue }
        $prior[$cells[0]] = [PSCustomObject]@{
            Name = $cells[0]; Basis = $cells[1]; Observations = [int]$cells[2]
            LastState = $cells[3]; LastRun = $cells[4]; PriorBasis = $cells[5]
        }
    }

    $entries = [System.Collections.Generic.List[object]]::new()
    foreach ($row in ($Rows | Sort-Object Name)) {
        $basis = "$($row.ContentDigest)+$InstrumentBasis"
        $count = 1
        $priorBasis = '-'
        if ($prior.ContainsKey($row.Name)) {
            $p = $prior[$row.Name]
            if ($p.Basis -eq $basis) { $count = $p.Observations + 1 }
            else { $priorBasis = $p.Basis }
        }
        $entries.Add([PSCustomObject]@{
                Name = $row.Name; Basis = $basis; Observations = $count
                LastState = $row.State; LastRun = $RunId; PriorBasis = $priorBasis
            })
    }

    # Suites absent from this run keep their rows: the history outlives the runs
    # that produced it, and a suite deleted from disk still has an observation
    # history a later reader may need.
    foreach ($name in ($prior.Keys | Sort-Object)) {
        if (-not ($entries | Where-Object { $_.Name -eq $name })) { $entries.Add($prior[$name]) }
    }

    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine($Marker)
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('# Full-glob CI audit — observation history')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine("Durable home for the observation count each suite's outcome goes back. Updated in place by every audit run; retention is the issue comment's, not the Actions run's.")
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine("**Comparability basis** = suite content digest + instrument basis. The instrument basis (``$InstrumentBasis``) hashes the bound and every dimension of the run's environment statement, so a run at a different bound, execution model, image, or module version does NOT pool with an earlier one. A changed basis resets the count to 1 and the previous basis is kept in the last column.")
    [void]$sb.AppendLine('')
    $commitClause = if ($Commit) { ' at commit `' + $Commit + '`' } else { '' }
    [void]$sb.AppendLine("Last updated by run ``$RunId``$commitClause.")
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('| suite | basis | observations | last state | last run | previous basis |')
    [void]$sb.AppendLine('| --- | --- | --- | --- | --- | --- |')
    foreach ($e in ($entries | Sort-Object Name)) {
        [void]$sb.AppendLine("| ``$($e.Name)`` | $($e.Basis) | $($e.Observations) | $($e.LastState) | $($e.LastRun) | $($e.PriorBasis) |")
    }

    return [PSCustomObject]@{
        Body    = $sb.ToString().TrimEnd() + "`n"
        Entries = @($entries | Sort-Object Name)
    }
}

#endregion

#region record composition

function Measure-CIGlobAuditBody {
    <#
    .SYNOPSIS
        Codepoints, not UTF-16 code units — the unit GitHub's cap is stated in.
    .DESCRIPTION
        [string]::Length counts UTF-16 code units, so a body full of astral
        characters measures nearly double its real size and a size guard built
        on it refuses lawful bodies. Emoji in a captured failure message are
        exactly the population that would hit this.
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Body)
    if ([string]::IsNullOrEmpty($Body)) { return 0 }
    # Codepoints: enumerate text elements rather than trusting .Length, which
    # counts UTF-16 code units and therefore reports nearly double for astral
    # characters. A guard built on .Length refuses lawful bodies, and a captured
    # failure message containing an emoji is exactly the population that hits it.
    $enumerator = [System.Globalization.StringInfo]::GetTextElementEnumerator($Body)
    $count = 0
    while ($enumerator.MoveNext()) { $count++ }
    return $count
}

function Test-CIGlobAuditBodyFits {
    <#
    .SYNOPSIS
        Does this body fit the cap, without paying for a codepoint walk on every
        candidate?
    .DESCRIPTION
        A string's codepoint count is never greater than its UTF-16 code-unit
        count, so a body whose `.Length` already fits the cap fits it in
        codepoints too, and the exact walk is only needed for the bodies that
        look too big. Without this, composing a record is quadratic in its own
        size — measured at nine seconds for one paginated record, which is the
        kind of cost that quietly gets a check deleted later.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Body,
        [Parameter(Mandatory)][int]$Cap
    )
    if ($Body.Length -le $Cap) { return $true }
    return ((Measure-CIGlobAuditBody -Body $Body) -le $Cap)
}

function New-CIGlobAuditRecordDocuments {
    <#
    .SYNOPSIS
        Compose the durable record: one summary document plus as many detail
        documents as the classifying detail actually needs.
    .DESCRIPTION
        WHY PAGINATION RATHER THAN TRUNCATION. The measured skeleton for 252
        suites is roughly 21,400 codepoints and the cap is 65,536, which leaves
        about 41,000 for detail. At sixty non-passed rows that is comfortable;
        at a hundred and ninety it is about 215 codepoints each, and nothing
        here is allowed to assume the failing population is small. Truncating
        detail to fit would satisfy the cap by breaking the criterion the
        detail exists for — so detail spills into further comments instead, and
        the summary says how many and where.

        The summary never depends on a retention-bounded surface. Full console
        output goes to an artifact as a convenience, and no criterion rests on
        it.
    .OUTPUTS
        [PSCustomObject[]] Marker, Body, Kind ('summary' | 'detail'), Index.
    #>
    param(
        [Parameter(Mandatory)][hashtable]$RunContext,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Rows,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$EnvironmentStatement,
        [Parameter(Mandatory)][object]$Population,
        [Parameter(Mandatory)][object]$GateAgreement,
        [Parameter(Mandatory)][object]$Reachability,
        [Parameter(Mandatory)][object[]]$ControlCheck,
        [int]$DetailCharCap = 1500,
        [int]$BodyCap = 0
    )

    Set-StrictMode -Version Latest
    if ($BodyCap -le 0) { $BodyCap = $script:CIGlobAuditBodyCap }

    $runId = [string]$RunContext['RunId']
    $summaryMarker = "<!-- ci-glob-audit-record-$runId -->"
    $detailMarkerFor = { param($i) "<!-- ci-glob-audit-detail-$runId-$i -->" }

    $inPop = @($Rows | Where-Object { $_.InPopulation })
    $outPop = @($Rows | Where-Object { -not $_.InPopulation })
    $nonPassed = @($Rows | Where-Object { $_.State -ne 'passed' })

    # ---- detail documents first: the summary must state how many exist ----
    $detailDocs = [System.Collections.Generic.List[object]]::new()
    if ($nonPassed.Count -gt 0) {
        $pending = [System.Collections.Generic.List[string]]::new()
        foreach ($row in ($nonPassed | Sort-Object @{ E = { $_.InPopulation }; Descending = $true }, Name)) {
            $detail = [string]$row.Detail
            $emitted = $true
            if ([string]::IsNullOrWhiteSpace($detail)) {
                $detail = "**Nothing was emitted before the kill.** This suite produced no output and no result at bound $($row.BoundSeconds)s. This is an honest empty, not a discharge: #1036 cannot classify this row from the record."
                $emitted = $false
            }
            elseif ($detail.Length -gt $DetailCharCap) {
                $detail = $detail.Substring(0, $DetailCharCap) + "`n...(detail truncated at $DetailCharCap chars; full console output is in this run's artifact, which no criterion rests on)"
            }
            $scope = if ($row.InPopulation) { 'in-population' } else { "out-of-population control ($($row.ControlRole))" }
            $block = @(
                "### ``$($row.Name)`` — $($row.State) ($($row.Reason))",
                '',
                "$scope | elapsed $($row.ElapsedMs) ms | bound $($row.BoundSeconds)s | quarantine class $(script:Format-CIGlobAuditClass -Class $row.QuarantineClass -InPopulation $row.InPopulation) | content ``$($row.ContentDigest)``$(if (-not $emitted) { ' | **no output captured**' })",
                '',
                '```text',
                $detail,
                '```',
                '',
                ''
            ) -join "`n"
            $pending.Add($block)
        }

        $header = {
            param($i)
            @(
                (& $detailMarkerFor $i),
                '',
                "## Full-glob CI audit — classifying detail (part $i)",
                '',
                "Run ``$runId``, commit ``$($RunContext['Commit'])``. Detail for every row whose state is not ``passed``, so a reader can decide ``linux-red`` versus ``never-ci`` without opening the suite. Part of the record whose summary is ``$summaryMarker``.",
                '',
                ''
            ) -join "`n"
        }

        $index = 1
        $current = [System.Text.StringBuilder]::new()
        [void]$current.Append((& $header $index))
        foreach ($block in $pending) {
            $candidate = $current.ToString() + $block
            if (-not (Test-CIGlobAuditBodyFits -Body $candidate -Cap $BodyCap) -and $current.ToString() -ne (& $header $index)) {
                $detailDocs.Add([PSCustomObject]@{ Marker = (& $detailMarkerFor $index); Body = $current.ToString().TrimEnd() + "`n"; Kind = 'detail'; Index = $index })
                $index++
                $current = [System.Text.StringBuilder]::new()
                [void]$current.Append((& $header $index))
            }
            [void]$current.Append($block)
        }
        $detailDocs.Add([PSCustomObject]@{ Marker = (& $detailMarkerFor $index); Body = $current.ToString().TrimEnd() + "`n"; Kind = 'detail'; Index = $index })
    }

    # ---- summary ----
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine($summaryMarker)
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('## Full-glob CI audit — record')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine("Every suite the per-PR gate enumerates on disk, run on Linux with the quarantine **not** applied. Produced by run ``$runId``; nothing here was hand-written.")
    [void]$sb.AppendLine('')

    [void]$sb.AppendLine('### Run')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('| field | value |')
    [void]$sb.AppendLine('| --- | --- |')
    foreach ($k in @('RunId', 'RunUrl', 'RunAttempt', 'TriggerEvent', 'Commit', 'Ref', 'DefaultBranch', 'DefaultBranchTip', 'AncestryCheck', 'ContentDifferences', 'BoundSeconds', 'ShardCount', 'InstrumentBasis', 'StartedAt')) {
        if ($RunContext.ContainsKey($k)) { [void]$sb.AppendLine("| $k | $($RunContext[$k]) |") }
    }
    [void]$sb.AppendLine('')

    [void]$sb.AppendLine('### Population — the gate''s own enumeration, before the quarantine is subtracted')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine("- Derivation: ``$($Population.DerivationCommand)``")
    [void]$sb.AppendLine("- ``HasDrift``: **$($Population.HasDrift)** — the derivation is exact only under this precondition, and the run refuses to proceed without it.")
    [void]$sb.AppendLine("- Selected $($Population.SelectedCount); quarantine entries $($Population.QuarantinedCount) (unclassified $($Population.UnclassifiedCount)); stale $(@($Population.StaleQuarantine).Count).")
    [void]$sb.AppendLine("- Derived population **$(@($Population.Names).Count)**; in-population rows in this record **$($inPop.Count)**; out-of-population rows **$($outPop.Count)** (named below).")
    $missing = @($Population.Names | Where-Object { $n = $_; -not ($inPop | Where-Object { $_.Name -eq $n }) })
    $extra = @($inPop | Where-Object { $Population.Names -notcontains $_.Name } | ForEach-Object { $_.Name })
    [void]$sb.AppendLine("- One-to-one: missing $($missing.Count), unexpected $($extra.Count).$(if ($missing.Count) { ' MISSING: ' + ($missing -join ', ') })$(if ($extra.Count) { ' UNEXPECTED: ' + ($extra -join ', ') })")
    [void]$sb.AppendLine('')

    [void]$sb.AppendLine('### Terminal states')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('| state | in-population | out-of-population |')
    [void]$sb.AppendLine('| --- | --- | --- |')
    foreach ($state in $script:CIGlobAuditStates) {
        $a = @($inPop | Where-Object { $_.State -eq $state }).Count
        $b = @($outPop | Where-Object { $_.State -eq $state }).Count
        [void]$sb.AppendLine("| $state | $a | $b |")
    }
    [void]$sb.AppendLine('')

    [void]$sb.AppendLine('### Instrument self-check — the controls')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('Out-of-population suites that exist to exhibit each terminal state through the path the workflow actually runs. A control that did not produce its expected state means the classifier is wrong, not that the corpus changed.')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('| control | expected | observed | ok |')
    [void]$sb.AppendLine('| --- | --- | --- | --- |')
    foreach ($c in $ControlCheck) {
        [void]$sb.AppendLine("| ``$($c.Name)`` | $($c.Expected) | $($c.Observed) | $(if ($c.Ok) { 'yes' } else { '**NO**' }) |")
    }
    [void]$sb.AppendLine('')

    [void]$sb.AppendLine('### Reachability of every `did-not-complete` suite')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine("A suite that never returns is only safe while no documented way of running this repository's tests reaches it. Two such ways exist and their populations differ: the gate's selection, and a directory-level ``Invoke-Pester`` over the tests root, which the contributor instructions and the pull-request template prescribe and which is recursive and quarantine-blind.")
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine("- ``did-not-complete`` rows: $($Reachability.StalledCount)")
    [void]$sb.AppendLine("- reachable by the gate's selection: $(@($Reachability.GateReachable).Count)$(if (@($Reachability.GateReachable).Count) { ' — ' + ($Reachability.GateReachable -join ', ') })")
    [void]$sb.AppendLine("- located beneath the tests root: $(@($Reachability.TestsRootReachable).Count)$(if (@($Reachability.TestsRootReachable).Count) { ' — ' + ($Reachability.TestsRootReachable -join ', ') })")
    [void]$sb.AppendLine("- clean: **$($Reachability.Clean)**$(if (-not $Reachability.Clean) { ' — this is a defect to escalate to #993, not a case to excuse. This chunk has no lawful remedy of its own: reclassifying a suite is #1036''s and adding `timeout-minutes` to the gate is #1037''s.' })")
    [void]$sb.AppendLine('')

    [void]$sb.AppendLine('### Environment — per dimension, this run against the gate')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('Audit-side values are read from this run, not from the workflow file. Where the gate states a constraint rather than a value, the constraint is what appears — a fabricated exact gate value would read cleaner and be untrue. This statement belongs to this run; it is not inherited.')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('| dimension | gate | this audit run | agrees |')
    [void]$sb.AppendLine('| --- | --- | --- | --- |')
    foreach ($d in $EnvironmentStatement) {
        [void]$sb.AppendLine("| $($d.Dimension) | $($d.Gate) | $($d.Audit) | $(if ($d.Agrees) { 'yes' } else { '**no**' }) |")
    }
    [void]$sb.AppendLine('')
    foreach ($d in ($EnvironmentStatement | Where-Object { $_.Note })) {
        [void]$sb.AppendLine("- **$($d.Dimension)**: $($d.Note)")
    }
    [void]$sb.AppendLine('')

    [void]$sb.AppendLine('### Agreement with the gate where the two overlap')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine("Expectation: $($GateAgreement.GateExpectation). Overlap $($GateAgreement.OverlapCount) suites; agreed $($GateAgreement.AgreeCount); disagreed $(@($GateAgreement.Disagreements).Count).")
    [void]$sb.AppendLine('')
    if (@($GateAgreement.Disagreements).Count -gt 0) {
        [void]$sb.AppendLine('Each disagreement must be attributed to a divergence recorded above that this audit could **not** have avoided. A disagreement attributed to a divergence the audit could have matched and did not is a failure, not an account.')
        [void]$sb.AppendLine('')
        [void]$sb.AppendLine('| suite | audit state | reason |')
        [void]$sb.AppendLine('| --- | --- | --- |')
        foreach ($d in $GateAgreement.Disagreements) {
            [void]$sb.AppendLine("| ``$($d.Name)`` | $($d.State) | $($d.Reason) |")
        }
        [void]$sb.AppendLine('')
    }

    if ($outPop.Count -gt 0) {
        [void]$sb.AppendLine('### Out-of-population rows')
        [void]$sb.AppendLine('')
        [void]$sb.AppendLine('Named as such per the record contract: these are not suites the gate enumerates, and no consumer may read them as measurements of the corpus.')
        [void]$sb.AppendLine('')
        foreach ($r in ($outPop | Sort-Object Name)) {
            [void]$sb.AppendLine("- ``$($r.Name)`` ($($r.ControlRole)) — $($r.State), $($r.ElapsedMs) ms, at ``$($r.Path)``")
        }
        [void]$sb.AppendLine('')
    }

    $survivors = @($Rows | Where-Object { $_.ProcessSurvivedKill })
    [void]$sb.AppendLine('### Timing integrity')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('"The bound fired" and "the slot is free" are two facts. A killed suite whose process survived keeps consuming the runner and contaminates every later row''s duration while each row individually looks well-formed.')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine("- bounded suites whose process survived the kill: **$($survivors.Count)**$(if ($survivors.Count) { ' — ' + (($survivors | ForEach-Object { $_.Name }) -join ', ') + '. The durations in this record are NOT offered as a timing measurement.' })")
    [void]$sb.AppendLine('')

    [void]$sb.AppendLine('### Per-suite rows')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine("Elapsed is wall clock for the suite's own process. Nothing else ran on that runner at the same time (see the concurrency dimension above), so these are non-contended measurements.")
    [void]$sb.AppendLine('')
    if ($detailDocs.Count -gt 0) {
        $lastDetailMarker = if ($detailDocs.Count -gt 1) { ' .. `' + (& $detailMarkerFor $detailDocs.Count) + '`' } else { '' }
        [void]$sb.AppendLine("Classifying detail for every non-``passed`` row is in $($detailDocs.Count) companion comment(s) on this issue, markers ``$(& $detailMarkerFor 1)``$lastDetailMarker.")
        [void]$sb.AppendLine('')
    }
    [void]$sb.AppendLine('| suite | state | reason | ms | bound | class | skipped | executed | digest | pop |')
    [void]$sb.AppendLine('| --- | --- | --- | ---: | ---: | --- | ---: | ---: | --- | --- |')
    foreach ($r in ($Rows | Sort-Object Name)) {
        $pop = if ($r.InPopulation) { 'in' } else { 'ctl' }
        [void]$sb.AppendLine("| ``$($r.Name)`` | $($r.State) | $($r.Reason) | $($r.ElapsedMs) | $($r.BoundSeconds) | $(script:Format-CIGlobAuditClass -Class $r.QuarantineClass -InPopulation $r.InPopulation) | $($r.Skipped) | $($r.Executed) | $($r.ContentDigest) | $pop |")
    }
    [void]$sb.AppendLine('')

    $summary = $sb.ToString().TrimEnd() + "`n"
    if (-not (Test-CIGlobAuditBodyFits -Body $summary -Cap $BodyCap)) {
        $summarySize = Measure-CIGlobAuditBody -Body $summary
        # Refuse rather than write a body GitHub will reject or a silently
        # truncated one. Discovering the cap mid-run is exactly the failure this
        # composer exists to make impossible, and a partial record read as whole
        # is worse than a loud stop.
        throw "ci-glob-audit: composed summary is $summarySize codepoints, over the $BodyCap cap. The per-suite table itself no longer fits; the record shape needs splitting before this run can persist."
    }

    $docs = @([PSCustomObject]@{ Marker = $summaryMarker; Body = $summary; Kind = 'summary'; Index = 0 }) + @($detailDocs)
    foreach ($d in $docs) {
        if (-not (Test-CIGlobAuditBodyFits -Body $d.Body -Cap $BodyCap)) {
            throw "ci-glob-audit: composed document '$($d.Marker)' is $(Measure-CIGlobAuditBody -Body $d.Body) codepoints, over the $BodyCap cap."
        }
    }
    return , @($docs)
}

function script:Format-CIGlobAuditClass {
    param($Class, [bool]$InPopulation = $true)
    # An out-of-population control has no quarantine class because it is not in
    # the registry's world at all. Rendering that as "none — selected" would
    # tell a reader the gate selects it, which is the opposite of true.
    if (-not $InPopulation) { return 'n/a (not in the registry)' }
    if ($null -eq $Class -or [string]::IsNullOrWhiteSpace([string]$Class)) { return '(none — selected)' }
    return [string]$Class
}

function Test-CIGlobAuditControlExpectation {
    <#
    .SYNOPSIS
        Did each control produce the terminal state it exists to exhibit?
    .DESCRIPTION
        The controls are the instrument's self-test. A run where the
        never-returning control did not land in `did-not-complete`, or the
        all-skipped control read as `passed`, is a broken classifier reporting
        confidently — which is the failure mode the four-state distinction
        exists to prevent, arriving through the back door.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Rows,
        [Parameter(Mandatory)][hashtable]$Expectations
    )

    Set-StrictMode -Version Latest

    $out = [System.Collections.Generic.List[object]]::new()
    foreach ($name in ($Expectations.Keys | Sort-Object)) {
        $row = @($Rows | Where-Object { $_.Name -eq $name }) | Select-Object -First 1
        $observed = if ($row) { "$($row.State) ($($row.Reason))" } else { '(no row)' }
        $ok = ($null -ne $row) -and ($row.State -eq $Expectations[$name])
        $out.Add([PSCustomObject]@{ Name = $name; Expected = $Expectations[$name]; Observed = $observed; Ok = $ok })
    }
    return , @($out)
}

#endregion
