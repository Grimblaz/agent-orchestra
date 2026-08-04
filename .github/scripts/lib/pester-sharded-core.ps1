#Requires -Version 7.0
<#!
.SYNOPSIS
    Pure-logic library for file-granular parallel sharded Pester runner (issue #740).

    Exposes these functions:
      - Get-RealGitFiles      : return the real-git allowlist (files that do real git init/commit)
      - Invoke-PesterSharded  : discover .Tests.ps1 files, run in parallel/sequential shards,
                                aggregate results, enforce no-false-GREEN contract
#>

# ---------------------------------------------------------------------------
# Real-git allowlist
# These files execute actual `git init` + `git commit` fixtures and must run
# sequentially (not in parallel) because they mutate git environment state.
# The list is keyed on fixture behavior, not on string grep of 'git '.
# ---------------------------------------------------------------------------
function Get-RealGitFiles {
    [CmdletBinding()]
    [OutputType([string[]])]
    param()

    return @(
        'plugin-release-hygiene.Tests.ps1',
        'session-cleanup-detector.Tests.ps1'
    )
}

# ---------------------------------------------------------------------------
# Run attribution (issue #958)
#
# A run of this suite says which tree its tests ran against and whether that
# tree was clean, so its result can be read as evidence without the operator
# separately remembering to record those two facts.
#
# Anchored on the TESTS PATH, never on the process that launched the run. Both
# of this library's programmatic callers drive it against a tree that is not
# the caller's own -- the runner's own contract tests use temporary fixture
# directories, and the goal-contract validator runs a detached worktree's tests
# from a child process sitting in a different checkout. A process-anchored
# lookup would print a plausible commit that is the wrong commit, which reads
# as attribution and is not.
#
# Every lookup is best-effort. A run whose commit cannot be established says so
# and carries on: the attribution must never claim a commit it cannot know, and
# must never turn an otherwise-passing run red.
# ---------------------------------------------------------------------------

function script:Get-RunDepthEnvName {
    # Carries run depth to child processes. This suite contains tests that run
    # this suite, so one run's output holds several attributions; depth is what
    # lets a reader tell which one describes the run they started.
    return 'PESTER_SHARDED_RUN_DEPTH'
}

function script:Get-AttributionReason {
    param([string]$Text)

    $collapsed = ($Text -replace '\s+', ' ').Trim()
    if ($collapsed.Length -gt 140) { $collapsed = $collapsed.Substring(0, 137) + '...' }
    return $collapsed
}

function script:Invoke-AttributionGit {
    <#
        Best-effort `git -C <Path> <GitArgs>`. Never throws and never writes to
        an error stream. A missing git, a path outside any repository, and a
        path git declines to read all come back the same way: Ok = $false with
        a reason the caller can print.
    #>
    param(
        [string]$Path,
        [string[]]$GitArgs
    )

    # Function-local, so a caller running under $ErrorActionPreference = 'Stop'
    # is not aborted by git writing to stderr.
    $ErrorActionPreference = 'Continue'

    # A failed lookup is normal here, so $LASTEXITCODE is restored on the way
    # out: the attribution reports on the run, it does not alter what the
    # caller observes afterwards.
    $savedLastExitCode = if (Test-Path -LiteralPath 'Variable:\global:LASTEXITCODE') { $global:LASTEXITCODE } else { $null }

    try {
        $raw = & git '-C' $Path @GitArgs 2>&1
        $exit = $LASTEXITCODE

        $records = @($raw)
        $stdout = @($records |
            Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] } |
            ForEach-Object { [string]$_ })

        if ($exit -ne 0) {
            $stderr = @($records |
                Where-Object { $_ -is [System.Management.Automation.ErrorRecord] } |
                ForEach-Object { [string]$_ })
            $why = (@($stderr) + @($stdout) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join ' '
            if ([string]::IsNullOrWhiteSpace($why)) { $why = "git exited with code $exit" }
            return [pscustomobject]@{ Ok = $false; Lines = @(); Reason = (script:Get-AttributionReason $why) }
        }

        return [pscustomobject]@{ Ok = $true; Lines = $stdout; Reason = '' }
    }
    catch {
        # Thrown rather than exited: git is not on PATH at all.
        return [pscustomobject]@{ Ok = $false; Lines = @(); Reason = (script:Get-AttributionReason "git could not be run: $($_.Exception.Message)") }
    }
    finally {
        $global:LASTEXITCODE = $savedLastExitCode
    }
}

function script:Get-RunAttribution {
    <#
        Reads the facts once per run, BEFORE any test runs. Two consequences are
        deliberate: the tree state reported is the tree the tests started
        against (this suite takes minutes, and a run can begin clean and end
        dirty), and no git call happens inside the sequential shard's
        GIT_CONFIG_GLOBAL/GIT_CONFIG_SYSTEM swap window.
    #>
    param([string]$TestsPath)

    $inherited = [Environment]::GetEnvironmentVariable((script:Get-RunDepthEnvName))
    $depth = 0
    if ($inherited -match '^\d+$') { $depth = [int]$inherited + 1 }

    $displayPath = $TestsPath
    $commit = $null
    $treeState = 'unknown'
    $notes = [System.Collections.Generic.List[string]]::new()

    try {
        try { $displayPath = [System.IO.Path]::GetFullPath($TestsPath) } catch { }

        $head = script:Invoke-AttributionGit -Path $TestsPath -GitArgs @('rev-parse', 'HEAD')
        if ($head.Ok) {
            $candidate = (@($head.Lines) -join '').Trim()
            if ($candidate -match '^[0-9a-f]{40}$') { $commit = $candidate }
            else { $notes.Add('commit: git returned no commit id') | Out-Null }
        }
        else {
            $notes.Add("commit: $($head.Reason)") | Out-Null
        }

        $status = script:Invoke-AttributionGit -Path $TestsPath -GitArgs @('status', '--porcelain')
        if ($status.Ok) {
            $changed = @($status.Lines | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
            if ($changed.Count -eq 0) {
                $treeState = 'clean'
            }
            else {
                $untracked = @($changed | Where-Object { $_.StartsWith('??') }).Count
                $tracked = $changed.Count - $untracked
                $treeState = "dirty($tracked tracked, $untracked untracked)"
            }
        }
        else {
            $notes.Add("worktree: $($status.Reason)") | Out-Null
        }
    }
    catch {
        # Reporting on a run must never be the reason the run ends. Anything
        # unanticipated here degrades to 'we could not tell you', which is the
        # honest answer, and the run proceeds.
        $notes.Add((script:Get-AttributionReason "attribution could not be read: $($_.Exception.Message)")) | Out-Null
    }

    return [pscustomobject]@{
        Depth     = $depth
        Commit    = $commit
        TreeState = $treeState
        TestsPath = $displayPath
        Notes     = $notes.ToArray()
    }
}

function script:Write-RunAttribution {
    <#
        One line, deliberately. A full-suite run interleaves the console output
        of up to eight shard processes plus any suite run nested inside them, so
        a multi-line block would be torn apart by that interleaving.
    #>
    param([object]$Attribution)

    $run = if ($Attribution.Depth -eq 0) { 'outer' } else { "nested(depth=$($Attribution.Depth))" }
    $commit = if ($null -ne $Attribution.Commit) { $Attribution.Commit } else { 'none' }

    $line = "  RUN ATTRIBUTION  run=$run  commit=$commit  worktree=$($Attribution.TreeState)" +
        "  observed=before any tests ran  tests=$($Attribution.TestsPath)"
    if (@($Attribution.Notes).Count -gt 0) {
        $line += "  note=$(@($Attribution.Notes) -join '; ')"
    }

    Write-Host $line
}

# ---------------------------------------------------------------------------
# Internal: build the per-shard launcher script content
# The launcher is written to a temp .ps1 file so that file path and result
# path do not require complex inline string escaping when passed to pwsh.
# ---------------------------------------------------------------------------
function script:Get-ShardLauncherScript {
    param(
        [string]$TestFilePath,
        [string]$ResultFilePath,
        [string]$OutputVerbosity
    )

    # Single-quote literals in PowerShell here-string are safe.
    # The paths are embedded in the script via @"..."@ substitution.
    return @"
#Requires -Version 7.0
try {
    `$cfg = New-PesterConfiguration
    `$cfg.Run.Path = @('$($TestFilePath -replace "'", "''")')
    `$cfg.Output.Verbosity = '$OutputVerbosity'
    `$cfg.Run.Exit = `$false
    `$cfg.Run.PassThru = `$true
    `$r = Invoke-Pester -Configuration `$cfg

    `$passed = 0
    `$failed = 0
    `$totalCount = 0
    if (`$null -ne `$r) {
        `$passed = [int]`$r.PassedCount
        `$failed = [int]`$r.FailedCount
        # Count containers with Failed result as hard failures
        # (covers discovery errors: throw in test file = Container.Result = 'Failed')
        foreach (`$c in @(`$r.Containers)) {
            if ([string]`$c.Result -eq 'Failed') {
                `$failed++
            }
        }
        `$totalCount = `$passed + `$failed + [int]`$r.SkippedCount + [int]`$r.NotRunCount
    }

    `$obj = [ordered]@{ File = '$($TestFilePath | Split-Path -Leaf)'; Passed = `$passed; Failed = `$failed; TotalCount = `$totalCount }
    `$obj | ConvertTo-Json -Compress | Set-Content -LiteralPath '$($ResultFilePath -replace "'", "''")' -Encoding UTF8

    if (`$failed -gt 0) { exit 1 } else { exit 0 }
}
catch {
    Write-Error `$_
    exit 2
}
"@
}

# ---------------------------------------------------------------------------
# Invoke-PesterSharded
# ---------------------------------------------------------------------------
function Invoke-PesterSharded {
    [CmdletBinding()]
    param(
        [string]$TestsPath = (Join-Path $PSScriptRoot '../../../.github/scripts/Tests'),
        [switch]$DeterminismCheck,
        [int]$MinTestCount = 200,
        [string]$Output = 'Minimal'
    )

    # Resolve tests path
    $resolvedTestsPath = $TestsPath
    if (-not [System.IO.Path]::IsPathRooted($resolvedTestsPath)) {
        $resolved = Resolve-Path $resolvedTestsPath -ErrorAction SilentlyContinue
        if ($null -ne $resolved) { $resolvedTestsPath = $resolved.Path }
    }

    if (-not (Test-Path -LiteralPath $resolvedTestsPath -PathType Container)) {
        Write-Error "TestsPath not found: $resolvedTestsPath"
        return [pscustomobject]@{ ExitCode = 1; TotalPassed = 0; TotalFailed = 0; Results = @() }
    }

    # Discover all .Tests.ps1 files — the expected-file manifest
    $allFiles = @(Get-ChildItem -LiteralPath $resolvedTestsPath -Filter '*.Tests.ps1' -File |
        Sort-Object Name)

    if ($allFiles.Count -eq 0) {
        Write-Error "No .Tests.ps1 files found in: $resolvedTestsPath"
        return [pscustomobject]@{ ExitCode = 1; TotalPassed = 0; TotalFailed = 0; Results = @() }
    }

    $realGitNames = @(Get-RealGitFiles)

    # Split into parallel and sequential shards
    $parallelFiles = @($allFiles | Where-Object { $realGitNames -notcontains $_.Name })
    $sequentialFiles = @($allFiles | Where-Object { $realGitNames -contains $_.Name })

    # Issue #958: read the attribution before anything runs, and publish this
    # run's depth so that any run nested inside it -- this suite's own contract
    # tests run this runner -- reports itself as nested rather than as the run
    # the operator started.
    $attribution = script:Get-RunAttribution -TestsPath $resolvedTestsPath
    $depthEnvName = script:Get-RunDepthEnvName
    $savedDepth = [Environment]::GetEnvironmentVariable($depthEnvName)
    [Environment]::SetEnvironmentVariable($depthEnvName, [string]$attribution.Depth)

    try {
        if ($DeterminismCheck) {
            # Run twice and compare
            Write-Host "=== Determinism check: run 1 ===" -ForegroundColor Cyan
            $run1 = script:Invoke-ShardedRun -ParallelFiles $parallelFiles -SequentialFiles $sequentialFiles -Output $Output -AllFileManifest $allFiles -MinTestCount $MinTestCount
            Write-Host "=== Determinism check: run 2 ===" -ForegroundColor Cyan
            $run2 = script:Invoke-ShardedRun -ParallelFiles $parallelFiles -SequentialFiles $sequentialFiles -Output $Output -AllFileManifest $allFiles -MinTestCount $MinTestCount

            $diffFiles = script:Compare-RunResults -Run1 $run1.Results -Run2 $run2.Results
            if ($diffFiles.Count -gt 0) {
                Write-Host "`n=== DETERMINISM MISMATCH: the following files flipped between runs ===" -ForegroundColor Red
                foreach ($d in $diffFiles) {
                    Write-Host "  $($d.File): run1=$($d.Run1Outcome) run2=$($d.Run2Outcome)" -ForegroundColor Red
                }
                return [pscustomobject]@{
                    ExitCode        = 1
                    TotalPassed     = $run1.TotalPassed
                    TotalFailed     = $run1.TotalFailed
                    Results         = $run1.Results
                    DeterminismDiff = $diffFiles
                }
            }
            else {
                Write-Host "`nDeterminism check: PASSED (no flips between runs)" -ForegroundColor Green
            }

            return $run1
        }

        return script:Invoke-ShardedRun -ParallelFiles $parallelFiles -SequentialFiles $sequentialFiles -Output $Output -AllFileManifest $allFiles -MinTestCount $MinTestCount
    }
    finally {
        [Environment]::SetEnvironmentVariable($depthEnvName, $savedDepth)
        script:Write-RunAttribution -Attribution $attribution
    }
}

# ---------------------------------------------------------------------------
# Internal: run one complete sharded pass
# ---------------------------------------------------------------------------
function script:Invoke-ShardedRun {
    param(
        [object[]]$ParallelFiles,
        [object[]]$SequentialFiles,
        [string]$Output,
        [object[]]$AllFileManifest = @(),
        [int]$MinTestCount = 200
    )

    $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) "pester-sharded-$([System.Guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

    $allResults = [System.Collections.Concurrent.ConcurrentBag[object]]::new()
    $overallStart = [System.Diagnostics.Stopwatch]::StartNew()

    try {
        # ---- Parallel shard ----
        if ($parallelFiles.Count -gt 0) {
            # Pre-generate all launcher scripts before entering the parallel block.
            # script: scoped functions are not available inside ForEach-Object -Parallel
            # runspaces, so we resolve content here and pass file paths via $using:.
            $parallelLaunchers = @($parallelFiles | ForEach-Object {
                $baseName   = [System.IO.Path]::GetFileNameWithoutExtension($_.Name)
                $resultFile = Join-Path $tempDir "$baseName.json"
                $launchFile = Join-Path $tempDir "$baseName.launcher.ps1"
                $content    = script:Get-ShardLauncherScript -TestFilePath $_.FullName -ResultFilePath $resultFile -OutputVerbosity $Output
                [System.IO.File]::WriteAllText($launchFile, $content, [System.Text.UTF8Encoding]::new($false))
                [pscustomobject]@{
                    Name        = $_.Name
                    LaunchFile  = $launchFile
                    ResultFile  = $resultFile
                }
            })

            $parallelLaunchers | ForEach-Object -Parallel {
                $launcher = $_
                $bag      = $using:allResults

                $launchFile = $launcher.LaunchFile
                $resultFile = $launcher.ResultFile
                $fileName   = $launcher.Name

                $sw = [System.Diagnostics.Stopwatch]::StartNew()

                $proc = $null
                try {
                    $proc = Start-Process pwsh -ArgumentList @('-NoProfile', '-NonInteractive', '-File', $launchFile) -NoNewWindow -Wait -PassThru
                }
                catch {
                    $proc = $null
                }

                $sw.Stop()
                $exitCode = if ($null -ne $proc) { $proc.ExitCode } else { 99 }

                if (Test-Path -LiteralPath $resultFile) {
                    try {
                        $data = Get-Content -LiteralPath $resultFile -Raw | ConvertFrom-Json
                        $bag.Add([pscustomobject]@{
                            File        = $fileName
                            Passed      = [int]$data.Passed
                            Failed      = [int]$data.Failed
                            TotalCount  = [int]$data.TotalCount
                            WallClockMs = $sw.ElapsedMilliseconds
                            ExitCode    = $exitCode
                            HasResult   = $true
                        }) | Out-Null
                    }
                    catch {
                        # Result file malformed — treat as crash
                        $bag.Add([pscustomobject]@{
                            File        = $fileName
                            Passed      = 0
                            Failed      = 1
                            WallClockMs = $sw.ElapsedMilliseconds
                            ExitCode    = $exitCode
                            HasResult   = $false
                        }) | Out-Null
                    }
                }
                else {
                    # No result file = worker crashed = hard failure (no-false-GREEN M7)
                    $bag.Add([pscustomobject]@{
                        File        = $fileName
                        Passed      = 0
                        Failed      = 1
                        WallClockMs = $sw.ElapsedMilliseconds
                        ExitCode    = $exitCode
                        HasResult   = $false
                    }) | Out-Null
                }
            } -ThrottleLimit 8
        }

        # ---- Sequential shard (real-git files) ----
        if ($sequentialFiles.Count -gt 0) {
            $gitConfigPath = Join-Path ([System.IO.Path]::GetTempPath()) "pester-git-config-$([System.Guid]::NewGuid().ToString('N')).ini"
            $savedGitConfigGlobal = $env:GIT_CONFIG_GLOBAL
            $savedGitConfigSystem = $env:GIT_CONFIG_SYSTEM
            try {
                $gitConfigContent = @"
[user]
    email = pester-runner@example.com
    name = Pester Runner
[commit]
    gpgsign = false
[init]
    defaultBranch = main
"@
                [System.IO.File]::WriteAllText($gitConfigPath, $gitConfigContent, [System.Text.UTF8Encoding]::new($false))

                $env:GIT_CONFIG_GLOBAL = $gitConfigPath
                $env:GIT_CONFIG_SYSTEM = [string]::Empty

                foreach ($file in $sequentialFiles) {
                    $baseName    = [System.IO.Path]::GetFileNameWithoutExtension($file.Name)
                    $resultFile  = Join-Path $tempDir "$baseName.json"
                    $launchFile  = Join-Path $tempDir "$baseName.launcher.ps1"

                    $launchContent = script:Get-ShardLauncherScript -TestFilePath $file.FullName -ResultFilePath $resultFile -OutputVerbosity $Output
                    [System.IO.File]::WriteAllText($launchFile, $launchContent, [System.Text.UTF8Encoding]::new($false))

                    $sw = [System.Diagnostics.Stopwatch]::StartNew()

                    $proc = $null
                    try {
                        $proc = Start-Process pwsh -ArgumentList @('-NoProfile', '-NonInteractive', '-File', $launchFile) -NoNewWindow -Wait -PassThru
                    }
                    catch {
                        $proc = $null
                    }

                    $sw.Stop()
                    $exitCode = if ($null -ne $proc) { $proc.ExitCode } else { 99 }

                    if (Test-Path -LiteralPath $resultFile) {
                        try {
                            $data = Get-Content -LiteralPath $resultFile -Raw | ConvertFrom-Json
                            $allResults.Add([pscustomobject]@{
                                File        = $file.Name
                                Passed      = [int]$data.Passed
                                Failed      = [int]$data.Failed
                                TotalCount  = [int]$data.TotalCount
                                WallClockMs = $sw.ElapsedMilliseconds
                                ExitCode    = $exitCode
                                HasResult   = $true
                            }) | Out-Null
                        }
                        catch {
                            $allResults.Add([pscustomobject]@{
                                File        = $file.Name
                                Passed      = 0
                                Failed      = 1
                                WallClockMs = $sw.ElapsedMilliseconds
                                ExitCode    = $exitCode
                                HasResult   = $false
                            }) | Out-Null
                        }
                    }
                    else {
                        $allResults.Add([pscustomobject]@{
                            File        = $file.Name
                            Passed      = 0
                            Failed      = 1
                            WallClockMs = $sw.ElapsedMilliseconds
                            ExitCode    = $exitCode
                            HasResult   = $false
                        }) | Out-Null
                    }
                }
            }
            finally {
                $env:GIT_CONFIG_GLOBAL = $savedGitConfigGlobal
                $env:GIT_CONFIG_SYSTEM = $savedGitConfigSystem
                if (Test-Path -LiteralPath $gitConfigPath) {
                    Remove-Item -LiteralPath $gitConfigPath -Force -ErrorAction SilentlyContinue
                }
            }
        }
    }
    finally {
        $overallStart.Stop()
        # Clean temp dir
        if (Test-Path -LiteralPath $tempDir) {
            Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    $resultsArray = @($allResults)

    # No-false-GREEN: expected-file manifest check
    # Every discovered file must have a result; missing = crash = failure
    $missingFiles = @()
    if ($AllFileManifest.Count -gt 0) {
        foreach ($expectedFile in $AllFileManifest) {
            $found = $resultsArray | Where-Object { $_.File -eq $expectedFile.Name }
            if ($null -eq $found) {
                $missingFiles += $expectedFile.Name
            }
        }
    }

    # Print per-file summary
    $totalPassed = 0
    $totalFailed = 0
    $failedFiles = @()

    $sortedResults = @($resultsArray | Sort-Object File)
    foreach ($r in $sortedResults) {
        $totalPassed += $r.Passed
        $totalFailed += $r.Failed
        $wallSec = [math]::Round($r.WallClockMs / 1000.0, 1)
        $zeroTests = $r.HasResult -and $r.TotalCount -eq 0
        if ($zeroTests) { $totalFailed++ }
        $status = if ($r.Failed -gt 0 -or -not $r.HasResult -or $zeroTests) { 'FAIL' } else { 'PASS' }
        $noResult = if (-not $r.HasResult) { ' [NO RESULT - WORKER CRASHED]' }
                    elseif ($zeroTests) { ' [ZERO TESTS DISCOVERED]' }
                    else { '' }
        Write-Host ("  [{0,-4}] {1,-60} pass={2,4}  fail={3,4}  wall={4,6}s{5}" -f $status, $r.File, $r.Passed, $r.Failed, $wallSec, $noResult)
        if ($r.Failed -gt 0 -or -not $r.HasResult -or $zeroTests) {
            $failedFiles += $r.File
        }
    }

    foreach ($mf in $missingFiles) {
        Write-Host ("  [FAIL] {0,-60} [MISSING RESULT - PRESUMED CRASH]" -f $mf) -ForegroundColor Red
        $totalFailed++
        $failedFiles += $mf
    }

    $overallWallSec = [math]::Round($overallStart.ElapsedMilliseconds / 1000.0, 1)
    Write-Host "`n  TOTAL: pass=$totalPassed  fail=$totalFailed  wall=${overallWallSec}s  files=$($resultsArray.Count)/$($AllFileManifest.Count)"

    # Minimum test count baseline (no-false-GREEN contract M7 point 3)
    $exitCode = 0
    if ($totalFailed -gt 0 -or $missingFiles.Count -gt 0) {
        $exitCode = 1
        Write-Host "`n  FAILED FILES:" -ForegroundColor Red
        foreach ($ff in $failedFiles) {
            Write-Host "    $ff" -ForegroundColor Red
        }
    }

    if ($AllFileManifest.Count -gt 0 -and $MinTestCount -gt 0 -and ($totalPassed + $totalFailed) -lt $MinTestCount) {
        Write-Host "`n  WARNING: total test count $($totalPassed + $totalFailed) is below minimum $MinTestCount — possible suite misconfiguration" -ForegroundColor Yellow
        $exitCode = 1
    }

    return [pscustomobject]@{
        ExitCode     = $exitCode
        TotalPassed  = $totalPassed
        TotalFailed  = $totalFailed
        WallClockMs  = $overallStart.ElapsedMilliseconds
        Results      = $resultsArray
        MissingFiles = $missingFiles
        FailedFiles  = $failedFiles
    }
}

# ---------------------------------------------------------------------------
# Internal: compare two run result sets; return files that flipped outcome
# ---------------------------------------------------------------------------
function script:Compare-RunResults {
    param(
        [object[]]$Run1,
        [object[]]$Run2
    )

    $diffs = [System.Collections.Generic.List[object]]::new()

    $run1Map = @{}
    foreach ($r in $Run1) { $run1Map[$r.File] = $r }

    foreach ($r2 in $Run2) {
        $r1 = $run1Map[$r2.File]
        if ($null -eq $r1) { continue }

        $outcome1 = if ($r1.Failed -gt 0 -or -not $r1.HasResult -or ($r1.HasResult -and $r1.TotalCount -eq 0)) { 'fail' } else { 'pass' }
        $outcome2 = if ($r2.Failed -gt 0 -or -not $r2.HasResult -or ($r2.HasResult -and $r2.TotalCount -eq 0)) { 'fail' } else { 'pass' }

        if ($outcome1 -ne $outcome2) {
            $diffs.Add([pscustomobject]@{
                File        = $r2.File
                Run1Outcome = $outcome1
                Run2Outcome = $outcome2
            }) | Out-Null
        }
    }

    return $diffs.ToArray()
}
