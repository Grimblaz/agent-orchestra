#Requires -Version 7.0
<#!
.SYNOPSIS
    Pure-logic library for file-granular parallel sharded Pester runner (issue #740).

    Exposes these functions:
      - Get-RealGitFiles       : return the real-git allowlist (files that do real git init/commit)
      - Get-PesterFanOutWidth  : derive a fan-out width from a measured duration distribution
      - Invoke-PesterSharded   : run a SUPPLIED suite list (or, absent one, discover .Tests.ps1
                                 files) in parallel/sequential shards, aggregate results,
                                 enforce no-false-GREEN contract

    TWO CHANNELS, NOT ONE (issue #1037). A run's failure signal and its test-count
    total are separate. They used to share `$totalFailed`: a zero-test file and a
    crashed worker each incremented it, which is what made the run red -- so
    making the totals honest by deleting those increments would have turned a
    crashed worker GREEN. Every per-suite row now carries an `Outcome`, one
    function decides it (`Resolve-PesterSuiteOutcome`), and BOTH the reported
    figures and the red/green decision are computed from those same rows. No
    reported number is a failure signal in disguise, and no failure signal is a
    number that had to be invented.
#>

# ---------------------------------------------------------------------------
# The sequential shard, and the THREE reasons a suite lands on it
#
# The sequential shard runs AFTER the parallel one, one file at a time, so
# membership buys two things: an isolated git environment, and a machine with
# nothing else of ours running on it. Those are different reasons and they are
# kept in different lists -- a suite added for the wrong reason is a suite
# nobody can later remove for the right one.
#
#   Get-RealGitFiles          mutates git environment state (real `git init` +
#                             `git commit` fixtures). Keyed on fixture
#                             behaviour, not on a string grep of 'git '.
#   Get-IsolationRequiredFiles asserts something that ANOTHER suite running
#                             beside it can falsify -- a tree-state snapshot,
#                             or a wall-clock bound.
#
# The second list is issue #1037's. Fanning the gate out created two ways for a
# neighbour to make a suite lie, and the gate's own first run found the second
# one the hard way: `ci-glob-audit-core.Tests.ps1` asserts that a child suite
# completes inside a 6-second bound calibrated at ~1.07s WITH THE MACHINE TO
# ITSELF, and ten workers on a four-vCPU runner starved it past six. That test
# is not wrong -- its bound is deliberately mutation-proven -- so the fix is to
# give it back the conditions it was calibrated under rather than to loosen it.
#
# Membership for the whole corpus was re-derived when #1036 landed, which is
# what an earlier revision of this comment deferred. #1036 promoted 176 suites,
# scanned all of them for the three hazards these lists name, took six
# candidates to a contention experiment, and moved the two below that failed it.
# The scan is static and cannot see a hazard reached through a helper it does
# not recognise, so a clean result there is not proof of absence. Ongoing
# re-derivation as the corpus changes belongs to #1047's standing audit.
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

function Get-IsolationRequiredFiles {
    <#
        Suites whose assertions a concurrent neighbour can falsify. Each entry
        names WHICH of the two hazards it is exposed to, because the remedy for
        one is not the remedy for the other.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param()

    return @(
        # Wall-clock bound: asserts a child suite completes inside a limit
        # calibrated on an idle machine. Starved past it under fan-out on the
        # gate's own first run (#1037).
        'ci-glob-audit-core.Tests.ps1',
        # Tree-state snapshot: takes `git status`, then asserts the runner
        # reports the same cleanliness. ONE concurrent suite writing a
        # non-gitignored path into the checkout between the two flips it. Also
        # does real git init/commit in its own fixtures, so it would qualify
        # for the list above too -- it is here because isolation is the reason
        # that would survive if the git fixtures went away.
        'run-pester-sharded.Tests.ps1',
        # Wall-clock bound, and the tightest one in the corpus: 50 MILLISECONDS
        # (orchestra-spine-command.Tests.ps1, the no-spine fallback timing
        # assertion). Added by #1036 when it promoted this suite, on measurement
        # rather than on suspicion -- run alone it is 15 of 15, and run while the
        # box is saturated it fails 2 of 15. A bound with that little headroom
        # cannot survive a ten-wide fan-out on a four-vCPU runner, and the
        # failure would arrive on a stranger's pull request looking like a defect
        # in whatever they touched.
        'orchestra-spine-command.Tests.ps1',
        # Wall-clock bounds over REAL git work, two of them: a five-residual-
        # commit run inside 3s (:266) and a fifty-commit run inside 5s (:293),
        # plus a sub-linearity ratio between them (:295). The ratio is
        # scale-invariant and would survive contention; the two absolute bounds
        # are what a neighbour can starve, and the tighter of them is the 3s one
        # over five commits rather than the 5s one over fifty.
        # Measured by #1036 alongside the promotion: 16 of 16 alone, 14 of 16
        # with the box saturated. It supplies its own git identity per command,
        # so it does NOT belong on the real-git list -- isolation is the reason,
        # and the two lists are kept apart precisely so a suite added for the
        # wrong one can still be removed for the right one.
        'test-orphan-branch-commits-absorbed.Tests.ps1'
    )
}

function Get-SequentialShardFiles {
    <#
        The union the runner actually partitions on. Sorted and de-duplicated
        so a name appearing on both lists is one shard member, not two.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param()

    return @(@(Get-RealGitFiles) + @(Get-IsolationRequiredFiles) | Sort-Object -Unique)
}

# ---------------------------------------------------------------------------
# Fan-out width, derived (issue #1037, parent AC8)
#
# The width is NOT a number someone picked. It is read off a measured duration
# distribution, and the arithmetic is the runner's own partition: the sequential
# set runs in series AFTER the parallel set, so
#
#     makespan(W) = sum(sequential) + max( max(parallel), ceil(sum(parallel)/W) )
#
# Past the point where a worker's share of the parallel set drops below the
# LARGEST single parallel suite, more width buys nothing -- that suite is on
# the critical path whatever else is running. So the derived width is the
# smallest W at which that happens:
#
#     W = ceil( sum(parallel) / max(parallel) )
#
# This discriminates: a flat distribution returns (near) the suite count, and
# one dominated by a single long suite returns a small number. A derivation
# that returned the same width for any input would be a citation, not a
# derivation.
#
# What it does NOT model, stated so a reader does not over-read it: CPU
# contention. The distribution it is fed was measured one suite at a time per
# runner; the gate runs W at once on one runner. The width is an upper bound on
# useful concurrency, not a prediction of wall clock.
# ---------------------------------------------------------------------------
function Get-PesterFanOutWidth {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        # suite file name -> measured duration in milliseconds
        [Parameter(Mandatory)][hashtable]$DurationMs,
        # names that run in the sequential shard (default: this runner's own union)
        [string[]]$SequentialName,
        [ValidateRange(1, 256)][int]$MaxWidth = 64
    )

    Set-StrictMode -Version Latest

    if ($null -eq $SequentialName) { $SequentialName = @(Get-SequentialShardFiles) }

    $sequential = @($DurationMs.Keys | Where-Object { $SequentialName -contains $_ })
    $parallel = @($DurationMs.Keys | Where-Object { $SequentialName -notcontains $_ })

    # A cell that is not a number names the suite it came from. The input is
    # meant to be a parsed measurement record, and a bare cast error tells the
    # reader nothing about which row to go and look at.
    function script:Read-DurationCell {
        param([hashtable]$Table, [string]$Name)
        $raw = $Table[$Name]
        $parsed = 0
        if (-not [int]::TryParse([string]$raw, [ref]$parsed)) {
            throw "Get-PesterFanOutWidth: duration for '$Name' is '$raw', which is not a whole number of milliseconds."
        }
        return $parsed
    }

    $sequentialTotal = 0
    foreach ($n in $sequential) { $sequentialTotal += (script:Read-DurationCell -Table $DurationMs -Name $n) }

    $parallelTotal = 0
    $parallelMax = 0
    foreach ($n in $parallel) {
        $v = script:Read-DurationCell -Table $DurationMs -Name $n
        $parallelTotal += $v
        if ($v -gt $parallelMax) { $parallelMax = $v }
    }

    # A distribution with no parallel work, or whose longest parallel suite
    # measured zero, has no knee to find. Width 1 is the honest answer: there is
    # nothing here to size from.
    $width = 1
    if ($parallel.Count -gt 0 -and $parallelMax -gt 0) {
        $width = [int][math]::Ceiling($parallelTotal / [double]$parallelMax)
    }
    # Ceilings BEFORE the floor, so the floor is the last word. The other order
    # let a MaxWidth of 0 return a width of 0 -- which this function documents
    # as impossible and the runner's own [ValidateRange(1,256)] then rejects.
    if ($parallel.Count -gt 0 -and $width -gt $parallel.Count) { $width = $parallel.Count }
    if ($width -gt $MaxWidth) { $width = $MaxWidth }
    if ($width -lt 1) { $width = 1 }

    $perWorker = if ($width -gt 0) { [int][math]::Ceiling($parallelTotal / [double]$width) } else { $parallelTotal }

    return [pscustomobject]@{
        Width             = $width
        ParallelCount     = $parallel.Count
        ParallelTotalMs   = $parallelTotal
        ParallelMaxMs     = $parallelMax
        SequentialCount   = $sequential.Count
        SequentialTotalMs = $sequentialTotal
        # W -> infinity: the sequential set plus the longest parallel suite.
        MakespanFloorMs   = $sequentialTotal + $parallelMax
        MakespanAtWidthMs = $sequentialTotal + [math]::Max($parallelMax, $perWorker)
        Derivation        = "W = ceil(parallel total $parallelTotal ms / longest parallel suite $parallelMax ms) = $width; makespan floor = sequential $sequentialTotal ms + $parallelMax ms"
    }
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

function script:Format-RunDepthEnvValue {
    param([int]$Depth)

    return "v1:$Depth"
}

function script:Get-InheritedRunDepth {
    <#
        The depth of the run that started us, or 0 when we are the run the
        operator started.

        The published value carries a format tag, and a value without it is
        treated as absent rather than trusted. That matters in both directions:
        an ambient bare '3' would otherwise make the operator's own run label
        itself nested and leave no 'run=outer' line anywhere in the output, and
        an ambient non-numeric value would otherwise make a genuinely nested run
        claim to be the outer one. The digit bound is what keeps the parse
        total -- there is no unbounded cast here to overflow, which is what
        previously let an oversized value kill the run before any test ran.
    #>
    $inherited = [Environment]::GetEnvironmentVariable((script:Get-RunDepthEnvName))
    if ($inherited -match '^v1:(\d{1,9})$') { return [int]$Matches[1] + 1 }
    return 0
}

function script:Get-AttributionReason {
    param([string]$Text)

    $collapsed = ($Text -replace '\s+', ' ').Trim()
    if ($collapsed.Length -gt 140) {
        $collapsed = $collapsed.Substring(0, 137)
        # Substring cuts by UTF-16 code unit, so a non-BMP character -- which
        # git's messages carry whenever a path is non-ASCII -- can be split in
        # half, leaving an unpaired surrogate that does not survive re-encoding.
        if ($collapsed.Length -gt 0 -and [char]::IsHighSurrogate($collapsed[$collapsed.Length - 1])) {
            $collapsed = $collapsed.Substring(0, $collapsed.Length - 1)
        }
        $collapsed += '...'
    }
    return $collapsed
}

function script:Set-AttributionEnvVar {
    <#
        Sets a process environment variable, or REMOVES it when the value is
        absent.

        `[Environment]::SetEnvironmentVariable($name, $null)` does not remove the
        variable when called from PowerShell: $null binds to the [string]
        parameter as an empty string, so the variable survives as ''. That is not
        a restore. An empty GIT_DIR makes every later git call in the process
        fail with "not a git repository: ''", and an empty depth variable is a
        value this runner never wrote.
    #>
    param([string]$Name, [string]$Value)

    if ([string]::IsNullOrEmpty($Value)) {
        [Environment]::SetEnvironmentVariable($Name, [NullString]::Value)
    }
    else {
        [Environment]::SetEnvironmentVariable($Name, $Value)
    }
}

function script:Format-AttributionValue {
    <#
        Quotes a value that can contain spaces -- a filesystem path, or git's own
        message -- so a reader can still recover the field, and neutralises the
        record prefix inside it so a crafted path cannot forge a second
        attribution record on the same line.
    #>
    param([string]$Text)

    $safe = ($Text -replace 'RUN ATTRIBUTION', 'RUN_ATTRIBUTION') -replace '"', "'"
    return '"' + $safe + '"'
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

    # Function-local. When a caller has set 'Stop' and the host has
    # $PSNativeCommandUseErrorActionPreference on, a non-zero git exit raises
    # NativeCommandExitException rather than simply setting $LASTEXITCODE.
    # Measured both ways under that caller: the run survives either way -- the
    # catch below is what protects that -- and the reported reason keeps git's
    # own message ("ambiguous argument 'HEAD'..."), which under 'Stop' arrives
    # with the engine's generic "ended with non-zero exit code: 128" text
    # APPENDED to it rather than replacing it. Kept for the diagnostic, not for
    # survival.
    $ErrorActionPreference = 'Continue'

    # An ambient GIT_DIR or GIT_WORK_TREE overrides git's repository discovery
    # outright, which makes `-C <tests path>` decorative: a foreign repository's
    # commit and cleanliness would be reported as this tree's, with no note to
    # betray it. The anchor is the tests path, so discovery has to start there
    # and nowhere else.
    $discoveryVars = @('GIT_DIR', 'GIT_WORK_TREE', 'GIT_COMMON_DIR', 'GIT_OBJECT_DIRECTORY', 'GIT_INDEX_FILE')
    $savedDiscovery = @{}
    foreach ($discoveryVar in $discoveryVars) {
        $savedDiscovery[$discoveryVar] = [Environment]::GetEnvironmentVariable($discoveryVar)
        if ($null -ne $savedDiscovery[$discoveryVar]) { script:Set-AttributionEnvVar -Name $discoveryVar -Value $null }
    }

    # A failed lookup is normal here, so $LASTEXITCODE is left exactly as it was
    # found -- including still UNDEFINED, when no native command had run yet.
    # Assigning $null unconditionally would materialise the variable and flip a
    # caller's `Test-Path Variable:LASTEXITCODE`, which is not "unchanged".
    $lastExitCodeExisted = Test-Path -LiteralPath 'Variable:\global:LASTEXITCODE'
    $savedLastExitCode = if ($lastExitCodeExisted) { $global:LASTEXITCODE } else { $null }

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
        foreach ($discoveryVar in $discoveryVars) {
            script:Set-AttributionEnvVar -Name $discoveryVar -Value $savedDiscovery[$discoveryVar]
        }

        if ($lastExitCodeExisted) {
            $global:LASTEXITCODE = $savedLastExitCode
        }
        elseif (Test-Path -LiteralPath 'Variable:\global:LASTEXITCODE') {
            Remove-Variable -Name 'LASTEXITCODE' -Scope Global -Force -ErrorAction SilentlyContinue
        }
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

    $depth = script:Get-InheritedRunDepth

    # Resolved ONCE and reused for every git call and for the returned/printed
    # value. Resolving separately for git (raw $TestsPath) and for display
    # (a lexically-resolved GetFullPath) let the two diverge -- GetFullPath
    # normalizes '..' lexically while `git -C` chdir's physically, so a rooted
    # path crossing a symlink or junction could print a location git never
    # actually measured, in a field whose sole purpose is attribution.
    $canonicalPath = $TestsPath
    try { $canonicalPath = [System.IO.Path]::GetFullPath($TestsPath) } catch { }
    $displayPath = $canonicalPath
    $commit = $null
    $treeState = 'unknown'
    $notes = [System.Collections.Generic.List[string]]::new()

    try {
        $head = script:Invoke-AttributionGit -Path $canonicalPath -GitArgs @('rev-parse', 'HEAD')
        if ($head.Ok) {
            $candidate = (@($head.Lines) -join '').Trim()
            # 40 hex in a sha1 repository, 64 in a sha256 one. "git gave us
            # nothing" and "git gave us something this runner does not
            # recognise" are different facts, and reporting the second as the
            # first is a falsehood in the very surface that exists to degrade
            # honestly.
            if ($candidate -match '^[0-9a-f]{40}$' -or $candidate -match '^[0-9a-f]{64}$') {
                $commit = $candidate
            }
            elseif ([string]::IsNullOrWhiteSpace($candidate)) {
                $notes.Add('commit: git returned no commit id') | Out-Null
            }
            else {
                $notes.Add('commit: git returned a commit id this runner does not recognise') | Out-Null
            }
        }
        else {
            $notes.Add("commit: $($head.Reason)") | Out-Null
        }

        # --untracked-files=all, stated explicitly rather than left to the
        # caller's configuration: `git status` otherwise honours
        # status.showUntrackedFiles, so an operator who has set that to 'no'
        # -- a documented large-repository workaround -- would be told a tree
        # whose test files are not committed at all is clean. That is the exact
        # false attribution this runner exists to stop producing, it is silent,
        # and git configuration is sticky in a way an environment variable is not.
        $status = script:Invoke-AttributionGit -Path $canonicalPath -GitArgs @('status', '--porcelain', '--untracked-files=all')
        if ($status.Ok) {
            $changed = @($status.Lines | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
            if ($changed.Count -eq 0) {
                $treeState = 'clean'
            }
            else {
                $untracked = @($changed | Where-Object { $_.StartsWith('??') }).Count
                $tracked = $changed.Count - $untracked
                # 'changes' for the tracked half because one porcelain entry can
                # cover two paths (a rename); with --untracked-files=all the
                # untracked half really is one entry per file. No spaces in the
                # value, so every field of the record stays recoverable.
                $treeState = "dirty(tracked-changes=$tracked,untracked-files=$untracked)"
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

    # Every leading field is space-free, and the two that carry arbitrary text --
    # a filesystem path and git's own message -- are quoted and come last, so a
    # reader can recover each field. An unquoted path was enough to truncate
    # `tests=` for any checkout living under a directory with a space in its name.
    $line = "  RUN ATTRIBUTION  run=$run  commit=$commit  worktree=$($Attribution.TreeState)" +
        "  observed=before-any-tests-ran  tests=$(script:Format-AttributionValue $Attribution.TestsPath)"
    if (@($Attribution.Notes).Count -gt 0) {
        $line += "  note=$(script:Format-AttributionValue (@($Attribution.Notes) -join '; '))"
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
        [ValidateSet('None', 'Minimal', 'Normal', 'Detailed', 'Diagnostic')]
        [string]$OutputVerbosity,
        # When true the worker is told NOT to emit CI-format error commands.
        # A nested run's children are FIXTURES -- this suite's own contract
        # tests deliberately crash workers -- and their `##[error]` lines are
        # promoted by GitHub into red failure annotations on the pull-request
        # checks surface. On a fully green pull request that surface would
        # still carry an annotation claiming a discovery failed, which is
        # exactly the legibility the gate's disclosure exists to provide.
        # Scoped to nested runs on purpose: the OUTER run's genuinely failing
        # suites should keep their annotations.
        [bool]$SuppressCIAnnotations
    )

    $ciFormat = if ($SuppressCIAnnotations) { 'None' } else { 'Auto' }

    # Single-quote literals in PowerShell here-string are safe.
    # The paths are embedded in the script via @"..."@ substitution.
    return @"
#Requires -Version 7.0
try {
    `$cfg = New-PesterConfiguration
    `$cfg.Run.Path = @('$($TestFilePath -replace "'", "''")')
    `$cfg.Output.Verbosity = '$OutputVerbosity'
    `$cfg.Output.CIFormat = '$ciFormat'
    `$cfg.Run.Exit = `$false
    `$cfg.Run.PassThru = `$true
    `$r = Invoke-Pester -Configuration `$cfg

    `$passed = 0
    `$failed = 0
    `$skipped = 0
    `$notRun = 0
    `$containerFailures = 0
    if (`$null -ne `$r) {
        `$passed = [int]`$r.PassedCount
        `$failed = [int]`$r.FailedCount
        `$skipped = [int]`$r.SkippedCount
        `$notRun = [int]`$r.NotRunCount
        # A container whose Result is 'Failed' is a DISCOVERY error -- a throw at
        # the top of the test file. It is reported on its own channel and is
        # NOT folded into the test-failure count: doing that mixed two units
        # (one file counted as one 'test') and, worse, inflated this file's
        # discovered-test total from 0 to 1, which then hid the zero-test
        # detection downstream for exactly the most-broken files.
        foreach (`$c in @(`$r.Containers)) {
            if ([string]`$c.Result -eq 'Failed') {
                `$containerFailures++
            }
        }
    }
    `$discovered = `$passed + `$failed + `$skipped + `$notRun

    `$obj = [ordered]@{
        File              = '$(($TestFilePath | Split-Path -Leaf) -replace "'", "''")'
        Passed            = `$passed
        Failed            = `$failed
        Skipped           = `$skipped
        NotRun            = `$notRun
        ContainerFailures = `$containerFailures
        TotalCount        = `$discovered
    }
    `$obj | ConvertTo-Json -Compress | Set-Content -LiteralPath '$($ResultFilePath -replace "'", "''")' -Encoding UTF8

    if (`$failed -gt 0 -or `$containerFailures -gt 0) { exit 1 } else { exit 0 }
}
catch {
    Write-Error `$_
    exit 2
}
"@
}

# ---------------------------------------------------------------------------
# The ONE predicate that decides whether a suite passed (issue #1037)
#
# Every consumer calls this: the per-suite summary lines, the run's red/green
# decision, the failed-file list, and the determinism comparison. Before this
# existed the same judgement was written out five times, and one of the five --
# inside Compare-RunResults -- silently disagreed with the others, which made
# `-DeterminismCheck` blind to exactly the classes it was added to catch.
#
# Four outcomes redden. They are distinct because they fail differently and a
# reader needs to know which one happened, not merely that something did:
#
#   failed-tests  the suite ran and tests failed (or a container failed to
#                 discover while others ran)
#   no-result     a worker produced no usable result file -- crashed, was
#                 killed, or wrote something unparseable
#   no-tests      the suite produced a result and executed nothing: nothing was
#                 discovered, discovery threw, or every discovered test was
#                 skipped
#   missing       the suite was in the run's manifest and produced no row at
#                 all (decided by reconciliation, not here)
# ---------------------------------------------------------------------------
function script:Read-RowField {
    param([object]$Object, [string]$Name, [object]$Default)
    if ($null -ne $Object -and $Object.PSObject.Properties.Match($Name).Count -gt 0 -and $null -ne $Object.$Name) {
        return $Object.$Name
    }
    return $Default
}

function Resolve-PesterSuiteOutcome {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][object]$Row)

    $hasResult = [bool](script:Read-RowField $Row 'HasResult' $false)
    $failed = [int](script:Read-RowField $Row 'Failed' 0)
    $passed = [int](script:Read-RowField $Row 'Passed' 0)
    $skipped = [int](script:Read-RowField $Row 'Skipped' 0)
    $notRun = [int](script:Read-RowField $Row 'NotRun' 0)
    $containerFailures = [int](script:Read-RowField $Row 'ContainerFailures' 0)
    $executed = $passed + $failed

    if (-not $hasResult) {
        return [pscustomobject]@{ Outcome = 'no-result'; Passed = $false; Reason = 'no usable result file — worker crashed or wrote something unparseable' }
    }
    if ($failed -gt 0) {
        return [pscustomobject]@{ Outcome = 'failed-tests'; Passed = $false; Reason = "$failed failing test(s)" }
    }
    if ($containerFailures -gt 0 -and $executed -gt 0) {
        return [pscustomobject]@{ Outcome = 'failed-tests'; Passed = $false; Reason = "$containerFailures container(s) failed to discover" }
    }
    # `-le`, not `-eq`. A total predicate must not have an exit that only a
    # non-negative input can reach: a row carrying a negative count resolved to
    # 'passed' under `-eq 0`, which is a false GREEN one character wide in the
    # single function that decides redness.
    if ($executed -le 0) {
        $why = if ($containerFailures -gt 0) { 'discovery threw' }
               elseif (($skipped + $notRun) -gt 0) { "every discovered test was skipped or not run ($($skipped + $notRun))" }
               else { 'no tests discovered' }
        return [pscustomobject]@{ Outcome = 'no-tests'; Passed = $false; Reason = "executed no tests — $why" }
    }

    return [pscustomobject]@{ Outcome = 'passed'; Passed = $true; Reason = "$passed test(s) passed" }
}

# ---------------------------------------------------------------------------
# The ONE shape a run that never reached a shard returns
#
# There used to be two result contracts: the full one, and a four-property stub
# emitted by every early error. A caller reading `Reconciliation` or
# `SuiteOutcomes` found them missing precisely on the runs where something had
# gone wrong, and the gate's own error annotation rendered "of  selected
# suite(s) did not pass" with two blanks in it. Every field the full return
# carries is present here, at the value a run that executed nothing honestly
# has.
# ---------------------------------------------------------------------------
function script:New-DegenerateShardResult {
    return [pscustomobject]@{
        ExitCode        = 1
        TotalPassed     = 0
        TotalFailed     = 0
        TestsSkipped    = 0
        TestsNotRun     = 0
        TestsExecuted   = 0
        SuitesSelected  = 0
        SuitesReported  = 0
        SuitesNotPassed = 0
        SuiteOutcomes   = @()
        Reconciliation  = [pscustomobject]@{
            Ok         = $false
            Selected   = 0
            Reported   = 0
            Missing    = @()
            Unexpected = @()
            Duplicate  = @()
        }
        FanOutWidth     = 0
        WallClockMs     = 0
        Results         = @()
        MissingFiles    = @()
        FailedFiles     = @()
    }
}

# ---------------------------------------------------------------------------
# Invoke-PesterSharded
# ---------------------------------------------------------------------------
function Invoke-PesterSharded {
    [CmdletBinding()]
    param(
        [string]$TestsPath = (Join-Path $PSScriptRoot '../../../.github/scripts/Tests'),
        # Issue #1037: the suite list the CALLER selected. When supplied, this
        # runner never globs -- the per-PR gate's selection is a glob MINUS a
        # quarantine, and a runner that re-globs would run the quarantined
        # suites the gate deliberately excluded. Supplying an EMPTY list is an
        # error, never a run over nothing.
        [AllowEmptyCollection()][string[]]$SuitePath,
        [switch]$DeterminismCheck,
        [int]$MinTestCount = 200,
        [ValidateSet('None', 'Minimal', 'Normal', 'Detailed', 'Diagnostic')]
        [string]$Output = 'Minimal',
        # How many suite processes run concurrently. Derived, not chosen --
        # see Get-PesterFanOutWidth.
        [ValidateRange(1, 256)][int]$FanOutWidth = 8
    )

    $selectionDriven = $PSBoundParameters.ContainsKey('SuitePath')

    if ($selectionDriven) {
        if (@($SuitePath).Count -eq 0) {
            Write-Error 'SuitePath was supplied but empty. A run over no suites is a failure, not a pass: the caller selected nothing, and reporting green for that is the false-GREEN shape this runner exists to refuse.'
            return (script:New-DegenerateShardResult)
        }

        $allFiles = @()
        $unreadable = @()
        foreach ($p in $SuitePath) {
            $item = Get-Item -LiteralPath $p -ErrorAction SilentlyContinue
            if ($null -eq $item -or $item.PSIsContainer) { $unreadable += $p; continue }
            $allFiles += $item
        }
        if ($unreadable.Count -gt 0) {
            Write-Error "SuitePath names $($unreadable.Count) entr(y/ies) that is not a readable file: $($unreadable -join ', '). Dropping a selected suite silently is exactly the reconciliation failure this runner reports on."
            return (script:New-DegenerateShardResult)
        }

        # EVERY identity in this runner -- the per-suite result file, the
        # generated launcher, the row key, the reconciliation key -- is the
        # LEAF NAME. A directory glob made that safe for free; an explicit list
        # does not. Two entries sharing a leaf overwrite each other's launcher,
        # so one suite runs twice, the other never runs at all, and its row
        # still reads `passed` with its tests counted into the honest total.
        # Reconciliation does redden that run, on `duplicate` -- but the
        # diagnostic names the symptom and the totals are already wrong by then.
        # Refuse up front instead, and say what to do about it.
        $collisions = @($allFiles | Group-Object Name | Where-Object { $_.Count -gt 1 })
        if ($collisions.Count -gt 0) {
            $detail = ($collisions | ForEach-Object { "$($_.Name) <- " + (($_.Group | ForEach-Object { $_.FullName }) -join ' , ') }) -join '; '
            Write-Error "SuitePath contains $($collisions.Count) leaf name(s) shared by more than one file: $detail. This runner keys every per-suite artifact on the leaf name, so a collision silently runs one suite twice and never runs the other. Rename one, or select them in separate runs."
            return (script:New-DegenerateShardResult)
        }
        $allFiles = @($allFiles | Sort-Object Name)

        # Attribution anchors on the tests tree, and with a supplied list there
        # is no TestsPath to anchor on. The first selected suite's directory is
        # the tree those suites actually live in.
        $resolvedTestsPath = $allFiles[0].DirectoryName
    }
    else {
        # Resolve tests path
        $resolvedTestsPath = $TestsPath
        if (-not [System.IO.Path]::IsPathRooted($resolvedTestsPath)) {
            $resolved = Resolve-Path $resolvedTestsPath -ErrorAction SilentlyContinue
            if ($null -ne $resolved) { $resolvedTestsPath = $resolved.Path }
        }

        if (-not (Test-Path -LiteralPath $resolvedTestsPath -PathType Container)) {
            Write-Error "TestsPath not found: $resolvedTestsPath"
            return (script:New-DegenerateShardResult)
        }

        # Discover all .Tests.ps1 files — the expected-file manifest
        $allFiles = @(Get-ChildItem -LiteralPath $resolvedTestsPath -Filter '*.Tests.ps1' -File |
            Sort-Object Name)

        if ($allFiles.Count -eq 0) {
            Write-Error "No .Tests.ps1 files found in: $resolvedTestsPath"
            return (script:New-DegenerateShardResult)
        }
    }

    $sequentialNames = @(Get-SequentialShardFiles)

    # Split into parallel and sequential shards
    $parallelFiles = @($allFiles | Where-Object { $sequentialNames -notcontains $_.Name })
    $sequentialFiles = @($allFiles | Where-Object { $sequentialNames -contains $_.Name })

    # Issue #958: read the attribution before anything runs, and publish this
    # run's depth so that any run nested inside it -- this suite's own contract
    # tests run this runner -- reports itself as nested rather than as the run
    # the operator started.
    $attribution = script:Get-RunAttribution -TestsPath $resolvedTestsPath
    $depthEnvName = script:Get-RunDepthEnvName
    $savedDepth = [Environment]::GetEnvironmentVariable($depthEnvName)
    script:Set-AttributionEnvVar -Name $depthEnvName -Value (script:Format-RunDepthEnvValue $attribution.Depth)

    try {
        if ($DeterminismCheck) {
            # Run twice and compare
            Write-Host "=== Determinism check: run 1 ===" -ForegroundColor Cyan
            $run1 = script:Invoke-ShardedRun -ParallelFiles $parallelFiles -SequentialFiles $sequentialFiles -Output $Output -AllFileManifest $allFiles -MinTestCount $MinTestCount -FanOutWidth $FanOutWidth -SuppressCIAnnotations:($attribution.Depth -gt 0)
            Write-Host "=== Determinism check: run 2 ===" -ForegroundColor Cyan
            $run2 = script:Invoke-ShardedRun -ParallelFiles $parallelFiles -SequentialFiles $sequentialFiles -Output $Output -AllFileManifest $allFiles -MinTestCount $MinTestCount -FanOutWidth $FanOutWidth -SuppressCIAnnotations:($attribution.Depth -gt 0)

            $diffFiles = script:Compare-RunResults -Run1 $run1.Results -Run2 $run2.Results
            if ($diffFiles.Count -gt 0) {
                Write-Host "`n=== DETERMINISM MISMATCH: the following files flipped between runs ===" -ForegroundColor Red
                foreach ($d in $diffFiles) {
                    Write-Host "  $($d.File): run1=$($d.Run1Outcome) run2=$($d.Run2Outcome)" -ForegroundColor Red
                }
                # Run 1's whole record, with the verdict overridden — not a
                # hand-built subset. A caller reading Reconciliation or
                # SuiteOutcomes must not find them missing precisely on the
                # runs where something went wrong.
                #
                # `PSObject.Copy()` is SHALLOW: Reconciliation, SuiteOutcomes
                # and Results below are the same object references run 1 holds.
                # Safe here because only the value-typed ExitCode is reassigned
                # and run 1 is discarded on this path — stated so a later edit
                # that mutates a nested member knows what it is doing.
                $flipped = $run1.PSObject.Copy()
                $flipped.ExitCode = 1
                $flipped | Add-Member -NotePropertyName 'DeterminismDiff' -NotePropertyValue $diffFiles -Force
                return $flipped
            }
            else {
                Write-Host "`nDeterminism check: PASSED (no flips between runs)" -ForegroundColor Green
            }

            # Run 2's verdict is not discardable. `-DeterminismCheck` used to
            # return run 1 outright, so a run 2 that reddened for a reason the
            # flip comparison cannot express -- a reconciliation failure, the
            # minimum-count floor -- was thrown away, and the mode that exists
            # to catch flakiness reported the green half of a flaky pair.
            if ($run2.ExitCode -ne 0 -and $run1.ExitCode -eq 0) {
                Write-Host "`n  Determinism: run 2 was red for a reason no outcome flipped on (reconciliation or the minimum-count floor). Returning run 2." -ForegroundColor Red
                return $run2
            }

            return $run1
        }

        return script:Invoke-ShardedRun -ParallelFiles $parallelFiles -SequentialFiles $sequentialFiles -Output $Output -AllFileManifest $allFiles -MinTestCount $MinTestCount -FanOutWidth $FanOutWidth -SuppressCIAnnotations:($attribution.Depth -gt 0)
    }
    finally {
        script:Set-AttributionEnvVar -Name $depthEnvName -Value $savedDepth
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
        [int]$MinTestCount = 200,
        [int]$FanOutWidth = 8,
        # Set for a NESTED run: its workers are fixtures, and their CI-format
        # error lines would otherwise land as failure annotations on the
        # pull-request checks surface. See Get-ShardLauncherScript.
        [switch]$SuppressCIAnnotations
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
                $content    = script:Get-ShardLauncherScript -TestFilePath $_.FullName -ResultFilePath $resultFile -OutputVerbosity $Output -SuppressCIAnnotations ([bool]$SuppressCIAnnotations)
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
                            File              = $fileName
                            Passed            = [int]$data.Passed
                            Failed            = [int]$data.Failed
                            Skipped           = [int]$data.Skipped
                            NotRun            = [int]$data.NotRun
                            ContainerFailures = [int]$data.ContainerFailures
                            TotalCount        = [int]$data.TotalCount
                            WallClockMs       = $sw.ElapsedMilliseconds
                            ExitCode          = $exitCode
                            HasResult         = $true
                        }) | Out-Null
                    }
                    catch {
                        # Result file malformed — no usable result. Every count is
                        # ZERO, deliberately: a fabricated `Failed = 1` here was
                        # what reddened the run, and it did so by lying about how
                        # many tests failed. HasResult = $false is the signal;
                        # Resolve-PesterSuiteOutcome reads it and returns
                        # 'no-result', which reddens on its own channel.
                        $bag.Add([pscustomobject]@{
                            File              = $fileName
                            Passed            = 0
                            Failed            = 0
                            Skipped           = 0
                            NotRun            = 0
                            ContainerFailures = 0
                            TotalCount        = 0
                            WallClockMs       = $sw.ElapsedMilliseconds
                            ExitCode          = $exitCode
                            HasResult         = $false
                        }) | Out-Null
                    }
                }
                else {
                    # No result file = worker crashed = hard failure (no-false-GREEN M7),
                    # carried by HasResult rather than by an invented test count.
                    $bag.Add([pscustomobject]@{
                        File              = $fileName
                        Passed            = 0
                        Failed            = 0
                        Skipped           = 0
                        NotRun            = 0
                        ContainerFailures = 0
                        TotalCount        = 0
                        WallClockMs       = $sw.ElapsedMilliseconds
                        ExitCode          = $exitCode
                        HasResult         = $false
                    }) | Out-Null
                }
            } -ThrottleLimit $FanOutWidth
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

                    $launchContent = script:Get-ShardLauncherScript -TestFilePath $file.FullName -ResultFilePath $resultFile -OutputVerbosity $Output -SuppressCIAnnotations ([bool]$SuppressCIAnnotations)
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
                                File              = $file.Name
                                Passed            = [int]$data.Passed
                                Failed            = [int]$data.Failed
                                Skipped           = [int]$data.Skipped
                                NotRun            = [int]$data.NotRun
                                ContainerFailures = [int]$data.ContainerFailures
                                TotalCount        = [int]$data.TotalCount
                                WallClockMs       = $sw.ElapsedMilliseconds
                                ExitCode          = $exitCode
                                HasResult         = $true
                            }) | Out-Null
                        }
                        catch {
                            # See the parallel shard's equivalent branch: no
                            # fabricated counts, HasResult carries the signal.
                            $allResults.Add([pscustomobject]@{
                                File              = $file.Name
                                Passed            = 0
                                Failed            = 0
                                Skipped           = 0
                                NotRun            = 0
                                ContainerFailures = 0
                                TotalCount        = 0
                                WallClockMs       = $sw.ElapsedMilliseconds
                                ExitCode          = $exitCode
                                HasResult         = $false
                            }) | Out-Null
                        }
                    }
                    else {
                        $allResults.Add([pscustomobject]@{
                            File              = $file.Name
                            Passed            = 0
                            Failed            = 0
                            Skipped           = 0
                            NotRun            = 0
                            ContainerFailures = 0
                            TotalCount        = 0
                            WallClockMs       = $sw.ElapsedMilliseconds
                            ExitCode          = $exitCode
                            HasResult         = $false
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

    # ---- Reconciliation against the manifest this run was ASKED to run ------
    #
    # "Selected" is the caller's word and it is kept. A mechanism that drops a
    # selected suite before running it reconciles perfectly against what it ran
    # and still failed to run what it was given -- so the comparison is against
    # the manifest, in both directions, and duplicates count too.
    $manifestNames = @($AllFileManifest | ForEach-Object { $_.Name })
    $reportedNames = @($resultsArray | ForEach-Object { $_.File })

    $missingFiles = @($manifestNames | Where-Object { $reportedNames -notcontains $_ })
    $unexpectedFiles = @($reportedNames | Sort-Object -Unique | Where-Object { $manifestNames -notcontains $_ })
    $duplicateFiles = @($reportedNames | Group-Object | Where-Object { $_.Count -gt 1 } | ForEach-Object { $_.Name })
    $reconciles = ($manifestNames.Count -gt 0) -and
                  ($missingFiles.Count -eq 0) -and
                  ($unexpectedFiles.Count -eq 0) -and
                  ($duplicateFiles.Count -eq 0)

    # ---- Per-suite outcomes: ONE record, read by both channels --------------
    $outcomeRows = [System.Collections.Generic.List[object]]::new()
    $failedFiles = @()

    $sortedResults = @($resultsArray | Sort-Object File)
    foreach ($r in $sortedResults) {
        $verdict = Resolve-PesterSuiteOutcome -Row $r
        $wallSec = [math]::Round($r.WallClockMs / 1000.0, 1)
        $status = if ($verdict.Passed) { 'PASS' } else { 'FAIL' }
        $note = if ($verdict.Passed) { '' } else { "  [$($verdict.Outcome.ToUpperInvariant()) — $($verdict.Reason)]" }
        Write-Host ("  [{0,-4}] {1,-60} pass={2,4}  fail={3,4}  skip={4,4}  wall={5,6}s{6}" -f
            $status, $r.File, $r.Passed, $r.Failed, ($r.Skipped + $r.NotRun), $wallSec, $note)

        $outcomeRows.Add([pscustomobject]@{
            File    = $r.File
            Outcome = $verdict.Outcome
            Reason  = $verdict.Reason
        }) | Out-Null
        if (-not $verdict.Passed) { $failedFiles += $r.File }
    }

    foreach ($mf in $missingFiles) {
        Write-Host ("  [FAIL] {0,-60}  [MISSING — selected, produced no result at all]" -f $mf) -ForegroundColor Red
        $outcomeRows.Add([pscustomobject]@{
            File    = $mf
            Outcome = 'missing'
            Reason  = 'selected for this run and produced no result row at all'
        }) | Out-Null
        $failedFiles += $mf
    }
    foreach ($uf in $unexpectedFiles) {
        Write-Host ("  [FAIL] {0,-60}  [UNEXPECTED — reported but not selected]" -f $uf) -ForegroundColor Red
    }
    foreach ($df in $duplicateFiles) {
        Write-Host ("  [FAIL] {0,-60}  [DUPLICATE — reported more than once]" -f $df) -ForegroundColor Red
    }

    # ---- Two totals, each saying which unit it counts -----------------------
    #
    # They are never summed together. `tests` counts test cases and is the sum
    # of what the suites reported, with nothing added to carry a failure
    # signal; `suites` counts files and comes from the same outcome rows the
    # redness decision below reads.
    $testsPassed = 0; $testsFailed = 0; $testsSkipped = 0; $testsNotRun = 0
    foreach ($r in $resultsArray) {
        $testsPassed += $r.Passed
        $testsFailed += $r.Failed
        $testsSkipped += $r.Skipped
        $testsNotRun += $r.NotRun
    }
    $testsExecuted = $testsPassed + $testsFailed

    $suitesNotPassed = @($outcomeRows | Where-Object { $_.Outcome -ne 'passed' })

    $overallWallSec = [math]::Round($overallStart.ElapsedMilliseconds / 1000.0, 1)
    Write-Host ''
    Write-Host ("  TOTAL suites (unit: files): {0} selected, {1} reported — {2}" -f
        $manifestNames.Count, $resultsArray.Count, (script:Format-OutcomeTally -Rows $outcomeRows))
    Write-Host ("  TOTAL tests   (unit: test cases): {0} executed = {1} passed + {2} failed; {3} skipped, {4} not run" -f
        $testsExecuted, $testsPassed, $testsFailed, $testsSkipped, $testsNotRun)
    Write-Host ("  Reconciliation against the selection: {0}  (missing {1}, unexpected {2}, duplicate {3})  wall={4}s" -f
        $(if ($reconciles) { 'OK' } else { 'FAILED' }), $missingFiles.Count, $unexpectedFiles.Count, $duplicateFiles.Count, $overallWallSec)

    # ---- Redness: read off the outcome rows, never off a total -------------
    $exitCode = 0
    if ($suitesNotPassed.Count -gt 0) {
        $exitCode = 1
        Write-Host "`n  FAILED SUITES:" -ForegroundColor Red
        foreach ($row in $suitesNotPassed) {
            Write-Host "    $($row.File) — $($row.Outcome): $($row.Reason)" -ForegroundColor Red
        }
    }
    if (-not $reconciles) {
        $exitCode = 1
        Write-Host "`n  RECONCILIATION FAILED: the run did not account for its selection exactly once." -ForegroundColor Red
    }

    # Minimum test count baseline (no-false-GREEN contract M7 point 3). It reads
    # the EXECUTED test count, which no longer carries per-file increments -- so
    # the floor now measures what its name says.
    if ($manifestNames.Count -gt 0 -and $MinTestCount -gt 0 -and $testsExecuted -lt $MinTestCount) {
        Write-Host "`n  WARNING: executed test count $testsExecuted is below minimum $MinTestCount — possible suite misconfiguration" -ForegroundColor Yellow
        $exitCode = 1
    }

    return [pscustomobject]@{
        ExitCode        = $exitCode
        # Kept, and still test-case counts -- but now HONEST ones. Every
        # programmatic consumer of these two fields is enumerated in
        # goal-contract-validate-core.ps1's Test-GCSuiteGatePass and in the CLI
        # wrapper; both were exercised against this change.
        TotalPassed     = $testsPassed
        TotalFailed     = $testsFailed
        TestsSkipped    = $testsSkipped
        TestsNotRun     = $testsNotRun
        TestsExecuted   = $testsExecuted
        SuitesSelected  = $manifestNames.Count
        SuitesReported  = $resultsArray.Count
        SuitesNotPassed = $suitesNotPassed.Count
        SuiteOutcomes   = $outcomeRows.ToArray()
        Reconciliation  = [pscustomobject]@{
            Ok         = $reconciles
            Selected   = $manifestNames.Count
            Reported   = $resultsArray.Count
            Missing    = $missingFiles
            Unexpected = $unexpectedFiles
            Duplicate  = $duplicateFiles
        }
        FanOutWidth     = $FanOutWidth
        WallClockMs     = $overallStart.ElapsedMilliseconds
        Results         = $resultsArray
        MissingFiles    = $missingFiles
        FailedFiles     = $failedFiles
    }
}

function script:Format-OutcomeTally {
    <#
        The buckets come from the ROWS, unioned with the known states so a
        zero still prints. A hard-coded state list would count a future sixth
        outcome in the redness decision (`Outcome -ne 'passed'`) and omit it
        from the printed tally — the two readers of one record disagreeing,
        which is the defect class this whole mechanism exists to remove.
    #>
    param([object]$Rows)

    $known = @('passed', 'failed-tests', 'no-result', 'no-tests', 'missing')
    $present = @($Rows | ForEach-Object { $_.Outcome } | Sort-Object -Unique)
    $states = @($known) + @($present | Where-Object { $known -notcontains $_ })

    $parts = foreach ($state in $states) {
        "$state=$(@($Rows | Where-Object { $_.Outcome -eq $state }).Count)"
    }
    return ($parts -join '  ')
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
    $run2Map = @{}
    foreach ($r in $Run2) { $run2Map[$r.File] = $r }

    # The UNION, not run 2's keys. This walked run 2 alone and `continue`d on
    # any file run 1 did not have -- so a suite that PRODUCED NO ROW in one of
    # the two runs was invisible in both directions, which is exactly the
    # flakiness `-DeterminismCheck` exists to catch. A row that appears in one
    # run and not the other is the most determinism-relevant thing there is.
    $allFiles = @(@($run1Map.Keys) + @($run2Map.Keys) | Sort-Object -Unique)

    foreach ($file in $allFiles) {
        $r1 = $run1Map[$file]
        $r2 = $run2Map[$file]

        if ($null -eq $r1 -or $null -eq $r2) {
            $diffs.Add([pscustomobject]@{
                File        = $file
                Run1Outcome = if ($null -eq $r1) { 'absent' } else { (Resolve-PesterSuiteOutcome -Row $r1).Outcome }
                Run2Outcome = if ($null -eq $r2) { 'absent' } else { (Resolve-PesterSuiteOutcome -Row $r2).Outcome }
            }) | Out-Null
            continue
        }

        # Through the SAME predicate the summary and the exit code use. This
        # site used to recompute the judgement from the three legacy fields,
        # which is how it went on reading a corrected mechanism by the old
        # rules and reported "no flips" across two runs that differed.
        #
        # And it compares the OUTCOME, not merely pass/fail: a suite that
        # crashed on one run and failed its tests on the other flipped, and
        # collapsing both to 'fail' is the same blindness one level up.
        $outcome1 = (Resolve-PesterSuiteOutcome -Row $r1).Outcome
        $outcome2 = (Resolve-PesterSuiteOutcome -Row $r2).Outcome

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
