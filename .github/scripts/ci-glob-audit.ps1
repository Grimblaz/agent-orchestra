#Requires -Version 7.0
<#!
.SYNOPSIS
    Thin wrapper for the full-glob CI audit (issue #1035). Three modes, one per
    job in `.github/workflows/ci-full-glob-audit.yml`.

.DESCRIPTION
    All logic lives in lib/ci-glob-audit-core.ps1; this file is the CLI seam and
    the I/O between the workflow's jobs.

      Prepare  — derive the population ONCE, from the gate's own selection
                 procedure, and hand every job the same assignment. Deriving it
                 per job would work today and drift the first time two jobs
                 checked out different commits.
      Shard    — attempt this shard's assigned suites, one process at a time,
                 and record what happened plus the environment it happened in.
      Compose  — reassemble, check the record against every property the
                 downstream chunks depend on, and persist it durably.

.PARAMETER Mode
    Prepare | Shard | Compose.

.PARAMETER TestsRoot
    The gate's tests root. Prepare and Compose.

.PARAMETER QuarantinePath
    The gate's quarantine registry. Prepare and Compose.

.PARAMETER ControlsDir
    Directory holding the out-of-population control suites — the five deliberately
    misbehaving Pester files this audit runs to prove it can tell its four terminal
    states apart, for example ".github/scripts/audit-controls/passes.Control.Tests.ps1".
    They sit OUTSIDE the tests root on purpose: one of them never returns, and the
    documented pre-PR command runs the tests root recursively and quarantine-blind.
    Prepare refuses to start if any of the five is missing, because a missing control
    silently removes the only demonstration of the state it exists for.

.PARAMETER ShardCount
    How many parallel jobs the audit fans out across. Prepare.

.PARAMETER PopulationFile
    Path to the assignment JSON that Prepare writes. Shard and Compose.

.PARAMETER ShardIndex
    Zero-based index of this shard. Shard.

.PARAMETER TimeoutSeconds
    Per-suite bound. A suite that has not returned by then is killed and
    recorded `did-not-complete`.

.PARAMETER WorkDir
    Scratch directory for launchers, result files and captured console output.

.PARAMETER OutFile
    Where this mode writes its JSON output.

.PARAMETER PartialsDir
    Directory holding every shard's output JSON. Compose.

.PARAMETER Issue
    Issue number the record and history comments are persisted on. Compose.

.PARAMETER DryRun
    Compose everything and run every integrity check, but write nothing to
    GitHub. For local verification of the compose path — including its size
    arithmetic against a real record — without a scratch issue to clean up.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Prepare', 'Shard', 'Compose')][string]$Mode,
    [string]$TestsRoot = '.github/scripts/Tests',
    [string]$QuarantinePath = '.github/scripts/Tests/ci-quarantine.json',
    [string]$ControlsDir = '.github/scripts/audit-controls',
    [int]$ShardCount = 8,
    [string]$PopulationFile = '',
    [int]$ShardIndex = 0,
    [int]$TimeoutSeconds = 300,
    [string]$WorkDir = '',
    [string]$OutFile = '',
    [string]$PartialsDir = '',
    [int]$Issue = 0,
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. "$PSScriptRoot/lib/ci-glob-audit-core.ps1"
. "$PSScriptRoot/lib/find-or-upsert-comment.ps1"

$script:HistoryMarker = '<!-- ci-glob-audit-history -->'
# The stable pointer. Every other record marker embeds the run id, so a consumer
# that wants "the current record" would otherwise have to enumerate an issue's
# comments and regex run ids out of HTML comments. This one never moves.
$script:IndexMarker = '<!-- ci-glob-audit-index -->'
# Must equal the library's $script:CIGlobAuditRecordFormatVersion. Bumped to 2
# with the drain/suite column split; moving one without the other makes the
# summary and the history state different shapes for the same run.
$script:RecordFormatVersion = 2

# The five controls and the terminal state each exists to exhibit. This map is
# the instrument's self-test: a run where a control did not produce its state is
# a broken classifier reporting confidently, and the audit fails on it.
$script:ControlExpectations = [ordered]@{
    'passes.Control.Tests.ps1'         = 'passed'
    'fails.Control.Tests.ps1'          = 'failed'
    'zero-discovery.Control.Tests.ps1' = 'executed-no-tests'
    'all-skipped.Control.Tests.ps1'    = 'executed-no-tests'
    'never-returns.Control.Tests.ps1'  = 'did-not-complete'
}

function script:Resolve-OutFile {
    param([string]$Candidate, [string]$Fallback)
    $path = if ($Candidate) { $Candidate } else { $Fallback }
    # A shard that ran every one of its suites and then lost the write because
    # a directory did not exist would cost the whole run — the compose job reads
    # a missing partial as a hole in the population and refuses.
    $parent = Split-Path -Parent $path
    if ($parent -and -not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
    return $path
}

function script:Protect-Body {
    <#
        Write-boundary backstop for the redaction primitive. The library scrubs
        every captured stream AT CAPTURE TIME, which is what makes the partial
        JSON artifacts safe; this re-applies it to whatever this file is about
        to hand to a permanent public surface, so a stream that reaches a body
        by some route capture-time scrubbing did not cover is still scrubbed
        before it is published. Deliberately positional: the primitive lives in
        the core library and this file does not own its parameter name.
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    return [string](Protect-CIGlobAuditSecret $Text)
}

function script:Resolve-RepoCoordinates {
    <#
        The SAME resolution the writer uses. `Find-OrUpsertComment` targets
        `-R "$Owner/$Repo"` when the caller supplies both and otherwise derives
        them from `git config --get remote.origin.url`; a reader that instead
        relied on `gh`'s ambient cwd resolution could read one repository's
        history and write another's.
    #>
    param([string]$Owner, [string]$Repo)
    if ($Owner -and $Repo) { return [PSCustomObject]@{ Owner = $Owner; Repo = $Repo } }
    $remoteUrl = $null
    try { $remoteUrl = (& git config --get remote.origin.url) 2>$null } catch { $remoteUrl = $null }
    if ($remoteUrl -and ($remoteUrl -match '[:/]([^/:]+)/([^/]+?)(?:\.git)?\s*$')) {
        return [PSCustomObject]@{ Owner = $Matches[1]; Repo = $Matches[2] }
    }
    return $null
}

function script:Get-IssueCommentsPaged {
    <#
        Every comment on the issue, one explicit page at a time.

        WHY PAGINATED. `gh issue view --json comments` returns a single capped
        window. The record issue accretes a summary plus N detail comments per
        run and is inherited by a standing audit, so the window is reached in
        the ordinary course — and the comment that falls out of it first is the
        oldest, which is the upserted history. An invisible history is not an
        absent one, and the two must never be confused (see the Status contract
        below).

        WHY AN EXPLICIT PAGE LOOP rather than `--paginate`: each page is then a
        self-contained JSON array this function parses and counts, so a short
        page is the termination condition and a non-zero exit on ANY page is a
        read failure rather than a silently short result.

        Status is 'ok' | 'read-failed' — never a bare empty list, because "the
        issue has no comments" and "the read failed" are different facts and
        the caller's next move differs between them.
    #>
    param([Parameter(Mandatory)][int]$IssueNumber, [string]$Owner, [string]$Repo)

    $coords = script:Resolve-RepoCoordinates -Owner $Owner -Repo $Repo
    if (-not $coords) {
        return [PSCustomObject]@{ Status = 'read-failed'; Comments = @(); Detail = 'could not resolve owner/repo from -Owner/-Repo or `git config --get remote.origin.url`' }
    }

    $all = [System.Collections.Generic.List[object]]::new()
    $page = 1
    while ($true) {
        # try/catch as well as the exit code: `$ErrorActionPreference = 'Stop'`
        # turns an absent or unrunnable `gh` into a terminating error, and a
        # throw here would take the whole compose job down BEFORE the record is
        # persisted. Every failure of this read is a 'read-failed' result the
        # caller can act on, never an exception.
        $json = $null
        try { $json = & gh api "repos/$($coords.Owner)/$($coords.Repo)/issues/$IssueNumber/comments?per_page=100&page=$page" 2>$null }
        catch {
            return [PSCustomObject]@{ Status = 'read-failed'; Comments = @(); Detail = "gh api issues/$IssueNumber/comments page $page could not be invoked: $($_.Exception.Message -replace '\s+', ' ')" }
        }
        if ($LASTEXITCODE -ne 0) {
            return [PSCustomObject]@{ Status = 'read-failed'; Comments = @(); Detail = "gh api issues/$IssueNumber/comments page $page failed (exit $LASTEXITCODE)" }
        }
        if (-not $json) {
            return [PSCustomObject]@{ Status = 'read-failed'; Comments = @(); Detail = "gh api issues/$IssueNumber/comments page $page returned no output" }
        }
        try { $parsed = @($json | ConvertFrom-Json) }
        catch {
            return [PSCustomObject]@{ Status = 'read-failed'; Comments = @(); Detail = "gh api issues/$IssueNumber/comments page $page returned unparseable JSON: $($_.Exception.Message -replace '\s+', ' ')" }
        }
        foreach ($c in $parsed) { $all.Add($c) }
        if ($parsed.Count -lt 100) { break }
        $page++
        if ($page -gt 200) {
            return [PSCustomObject]@{ Status = 'read-failed'; Comments = @(); Detail = "issue #$IssueNumber has more than 20,000 comments; refusing to keep paging" }
        }
    }
    return [PSCustomObject]@{ Status = 'ok'; Comments = @($all); Detail = '' }
}

function script:Get-CommentBodyByMarker {
    <#
        FOUR outcomes, deliberately distinguishable: 'found', 'absent' (the
        read succeeded and no comment carries the marker), 'read-failed', and
        'skipped' (a dry run, which never reads GitHub at all).

        Collapsing these to `''` is how a transient API failure destroys an
        observation history: the composer reads '' as "no history yet",
        rebuilds a fresh one, and the upsert PATCHes the real comment with it,
        resetting every suite's observation count with nothing said about it.
        The count is what the triage chunk promotes on. A caller that gets
        'read-failed' must REFUSE to rewrite, never reset.

        'skipped' is separated from 'read-failed' for the same reason the
        other three are separated from each other: a dry run writes nothing, so
        there is nothing to protect and no integrity problem to raise. Folding
        it into 'read-failed' would make every dry run report a false refusal.
    #>
    param([Parameter(Mandatory)][object]$Read, [Parameter(Mandatory)][string]$Marker)
    if ($Read.Status -eq 'skipped') {
        return [PSCustomObject]@{ Status = 'skipped'; Body = ''; Detail = [string]$Read.Detail }
    }
    if ($Read.Status -ne 'ok') {
        return [PSCustomObject]@{ Status = 'read-failed'; Body = ''; Detail = [string]$Read.Detail }
    }
    foreach ($c in $Read.Comments) {
        if (Test-CommentBodyMarkerLine1 -Body ([string]$c.body) -Marker $Marker) {
            return [PSCustomObject]@{ Status = 'found'; Body = [string]$c.body; Detail = '' }
        }
    }
    return [PSCustomObject]@{ Status = 'absent'; Body = ''; Detail = '' }
}

function script:Format-Iso8601 {
    <#
        ISO-8601 UTC, always, whatever shape the value arrived in.

        `gh` returns `createdAt` as an ISO-8601 string, but `ConvertFrom-Json`
        deserialises it to a [datetime] and string interpolation then renders
        that in the RUNNER'S CULTURE — `08/10/2026 04:30:04` reached the
        durable record, which is a different date to a reader in most of the
        world than it is to a reader in the United States. A cross-reader
        artifact whose whole point is durability cannot carry an ambiguous
        timestamp.

        A value that is neither a date nor parseable as one is returned
        VERBATIM rather than coerced: printing a wrong instant is worse than
        printing the string the API actually sent.
    #>
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) { return '' }
    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    $fmt = 'yyyy-MM-ddTHH:mm:ssZ'
    if ($Value -is [datetime]) { return ([datetime]$Value).ToUniversalTime().ToString($fmt, $inv) }
    if ($Value -is [System.DateTimeOffset]) { return ([System.DateTimeOffset]$Value).ToUniversalTime().ToString($fmt, $inv) }
    $text = [string]$Value
    if ([string]::IsNullOrWhiteSpace($text)) { return '' }
    $parsed = [datetime]::MinValue
    if ([datetime]::TryParse($text, $inv, [System.Globalization.DateTimeStyles]::RoundtripKind, [ref]$parsed)) {
        return $parsed.ToUniversalTime().ToString($fmt, $inv)
    }
    return $text
}

function script:Get-GateExpectation {
    <#
        R8(b)'s proof standard names "the gate's own recent runs", so read them
        rather than asserting a sentence about them. If `main`'s gate is red at
        dispatch time, every matching audit failure would otherwise be
        misattributed to audit divergence.

        Degrades honestly: an unreadable run list yields an expectation marked
        UNVERIFIED and says so in the record, rather than quietly reverting to
        the assertion this exists to replace.
    #>
    param([int]$Limit = 10)

    $assertion = 'every gate-selected suite passes'
    $failed = ''
    $json = $null
    # A degrade that throws is not a degrade. This runs before any persistence,
    # so an unrunnable `gh` under $ErrorActionPreference = 'Stop' would cost the
    # whole record to save a sentence.
    try { $json = & gh run list --workflow=pester.yml --limit $Limit --json databaseId,conclusion,status,event,createdAt 2>$null }
    catch { $failed = "gh run list --workflow=pester.yml could not be invoked: $($_.Exception.Message -replace '\s+', ' ')" }
    if (-not $failed -and $LASTEXITCODE -ne 0) { $failed = "gh run list --workflow=pester.yml exited $LASTEXITCODE" }
    if (-not $failed -and -not $json) { $failed = 'gh run list --workflow=pester.yml returned no output' }
    if (-not $failed) {
        try { $runs = @($json | ConvertFrom-Json) } catch { $failed = "gh run list returned unparseable JSON: $($_.Exception.Message -replace '\s+', ' ')" }
    }
    if ($failed) {
        return "$assertion — **UNVERIFIED at compose time** ($failed), so this expectation is asserted rather than read from the gate's own recent runs. R8(b)'s standard names those runs; the comparison has to be supplied manually in the run account."
    }

    # The whole projection is inside the degrade, not just the call. Every field
    # below is read off a JSON object under `Set-StrictMode -Version Latest`, so
    # a run list that parses but omits one of them throws — and this still runs
    # BEFORE any persistence, where a throw costs the record rather than the
    # sentence. Same rule as the invocation above, applied to the reading of the
    # result as well as to the getting of it.
    try {
        $completed = @($runs | Where-Object { $_.PSObject.Properties.Match('status').Count -gt 0 -and $_.status -eq 'completed' })
        if ($completed.Count -eq 0) {
            return "$assertion — **UNVERIFIED at compose time**: ``gh run list --workflow=pester.yml --limit $Limit`` returned no completed run. The gate's recent state is unknown, so a disagreement below may be the gate's own."
        }
        $green = @($completed | Where-Object { $_.conclusion -eq 'success' })
        $ids = ($completed | ForEach-Object { [string]$_.databaseId }) -join ', '
        if ($green.Count -eq $completed.Count) {
            $mostRecent = script:Format-Iso8601 -Value $completed[0].createdAt
            return "$assertion. Basis, read at compose time: the gate's own last $($completed.Count) completed ``pester.yml`` run(s) are all ``success`` (run ids $ids), most recent $mostRecent."
        }
        $bad = @($completed | Where-Object { $_.conclusion -ne 'success' })
        $badList = ($bad | ForEach-Object { "$($_.databaseId) ($($_.conclusion))" }) -join ', '
        return "**the gate itself is not uniformly green**, so ``$assertion`` is NOT the expectation this run may hold the audit to. Basis, read at compose time: of the gate's last $($completed.Count) completed ``pester.yml`` run(s), $($green.Count) are ``success`` and $($bad.Count) are not — $badList. A disagreement below that also fails under the gate is the gate's own state, not audit divergence, and must be checked against those runs before it is attributed to this instrument."
    }
    catch {
        return "$assertion — **UNVERIFIED at compose time** (``gh run list --workflow=pester.yml`` returned run objects this reader could not project: $($_.Exception.Message -replace '\s+', ' ')), so this expectation is asserted rather than read from the gate's own recent runs. R8(b)'s standard names those runs; the comparison has to be supplied manually in the run account."
    }
}

switch ($Mode) {

    'Prepare' {
        $population = Get-CIGlobAuditPopulation -TestsRoot $TestsRoot -QuarantinePath $QuarantinePath

        $items = [System.Collections.Generic.List[object]]::new()
        for ($i = 0; $i -lt $population.Names.Count; $i++) {
            $name = $population.Names[$i]
            $items.Add([ordered]@{
                    name                 = $name
                    path                 = $population.Files[$i]
                    inPopulation         = $true
                    controlRole          = ''
                    quarantineClass      = $population.ClassByName[$name]
                    environmentOverrides = @{}
                })
        }

        # Controls are appended AFTER the population and flagged, so the
        # one-to-one check downstream compares like with like and no consumer
        # can read a control as a measurement of the corpus.
        foreach ($controlName in $script:ControlExpectations.Keys) {
            $controlPath = Join-Path -Path $ControlsDir -ChildPath $controlName
            if (-not (Test-Path -LiteralPath $controlPath)) {
                throw "ci-glob-audit: control '$controlName' is missing from '$ControlsDir'. The controls are the instrument's self-test; running without one silently removes the only demonstration of a terminal state."
            }
            $overrides = @{}
            if ($controlName -eq 'never-returns.Control.Tests.ps1') { $overrides['CI_GLOB_AUDIT_CONTROLS'] = '1' }
            $items.Add([ordered]@{
                    name                 = $controlName
                    path                 = $controlPath
                    inPopulation         = $false
                    controlRole          = "expects $($script:ControlExpectations[$controlName])"
                    quarantineClass      = $null
                    environmentOverrides = $overrides
                })
        }

        $assignment = Get-CIGlobAuditShardAssignment -Names @($items | ForEach-Object { $_.name }) -ShardCount $ShardCount
        for ($i = 0; $i -lt $items.Count; $i++) { $items[$i]['shard'] = $assignment[$i] }

        $doc = [ordered]@{
            shardCount = $ShardCount
            testsRoot  = $TestsRoot
            population = [ordered]@{
                names             = $population.Names
                selectedNames     = $population.SelectedNames
                selectedCount     = $population.SelectedCount
                quarantinedCount  = $population.QuarantinedCount
                staleQuarantine   = $population.StaleQuarantine
                unclassifiedCount = $population.UnclassifiedCount
                hasDrift          = $population.HasDrift
                derivationCommand = $population.DerivationCommand
            }
            items      = @($items)
        }

        $target = script:Resolve-OutFile -Candidate $OutFile -Fallback 'ci-glob-audit-population.json'
        $doc | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $target -Encoding utf8

        Write-Host "Population derived: $($population.Names.Count) in-population suite(s) (selected $($population.SelectedCount), quarantined $($population.QuarantinedCount), on the RETIRED unclassified class $($population.UnclassifiedCount)), plus $($script:ControlExpectations.Count) out-of-population control(s), across $ShardCount shard(s)."
        Write-Host "HasDrift: $($population.HasDrift)"

        if ($env:GITHUB_OUTPUT) {
            # -InputObject, never the pipeline form: `(0..0) | ConvertTo-Json`
            # unwraps to the scalar `0`, `fromJSON('0')` is not an array, and
            # `strategy.matrix.shard` then fails at job-graph expansion — after
            # this job has already succeeded. `shard_count: 1` is a lawful
            # dispatch value (Get-CIGlobAuditShardAssignment accepts 1..64), so
            # that is a real dispatch, not a hypothetical one.
            #
            # Not -AsArray either: that wraps the INPUT, and the input is
            # already the array, so it emits `[[0,1]]` — a fix that swaps one
            # unusable matrix expression for another. The shape is asserted
            # below rather than assumed, because the cost of getting it wrong
            # is paid in a later job by a reader who did not write this line.
            $shards = ConvertTo-Json -InputObject @(0..($ShardCount - 1)) -Compress
            if ($shards -notmatch '^\[\s*\d+(\s*,\s*\d+)*\s*\]$') {
                throw "ci-glob-audit: refusing to emit a matrix expression that is not a flat array of shard indices; got '$shards' for ShardCount $ShardCount."
            }
            Add-Content -LiteralPath $env:GITHUB_OUTPUT -Value "shards=$shards"
            Add-Content -LiteralPath $env:GITHUB_OUTPUT -Value "population_count=$($population.Names.Count)"
        }
    }

    'Shard' {
        if (-not $PopulationFile) { throw 'ci-glob-audit: -PopulationFile is required in Shard mode.' }
        $doc = Get-Content -LiteralPath $PopulationFile -Raw | ConvertFrom-Json
        $mine = @($doc.items | Where-Object { [int]$_.shard -eq $ShardIndex })

        $work = script:Resolve-OutFile -Candidate $WorkDir -Fallback (Join-Path ([System.IO.Path]::GetTempPath()) "ci-glob-audit-$ShardIndex")
        New-Item -ItemType Directory -Force -Path $work | Out-Null

        # Facts are observed HERE, in the process that executes the suites. The
        # compose job's environment is not the suites' environment, and a parity
        # table populated from it would describe the wrong machine.
        $facts = Get-CIGlobAuditRuntimeFacts `
            -ProcessModel 'one child pwsh process per suite, started fresh, bounded, stdin closed' `
            -Concurrency "one suite process at a time within this job; $($doc.shardCount) job(s) in parallel on separate runners, so no two measured suites share a machine"

        Write-Host "Shard $ShardIndex of $($doc.shardCount): $($mine.Count) suite(s), bound ${TimeoutSeconds}s."
        $rows = Invoke-CIGlobAuditShard -Assignments $mine -TimeoutSeconds $TimeoutSeconds -WorkDir $work

        $target = script:Resolve-OutFile -Candidate $OutFile -Fallback "ci-glob-audit-partial-$ShardIndex.json"
        $partialJson = ([ordered]@{
                shardIndex     = $ShardIndex
                shardCount     = $doc.shardCount
                timeoutSeconds = $TimeoutSeconds
                facts          = $facts
                rows           = @($rows)
            }) | ConvertTo-Json -Depth 8
        # This artifact carries every row's captured detail, from suites that
        # have never been vetted, produced in a job that checks out WITH
        # credential persistence for gate parity. Scrubbed at capture time in
        # the library; re-applied here because this is the write boundary.
        Set-Content -LiteralPath $target -Value (script:Protect-Body -Text $partialJson) -Encoding utf8

        Write-Host "Shard $ShardIndex complete: $($rows.Count) row(s) written to $target."
        # Deliberately exit 0 even when suites failed. A shard that reddens here
        # loses its partial, and a missing partial is a hole in the record — the
        # audit is red BY CONSTRUCTION and the redness belongs at the end, after
        # the record is safely persisted.
        #
        # STATED AS CODE, NOT ONLY AS A COMMENT. Until the wrapper's own test
        # suite existed, this block asserted that contract in prose and left the
        # process to inherit whatever $LASTEXITCODE the last native call had set
        # — and this mode makes several, including a `git config --get-regexp`
        # that exits 1 when it simply matches nothing. So a shard whose suites
        # all passed still exited 1 wherever that lookup came up empty, which
        # `if: always()` on the upload hides right up until the compose job
        # reads the run as failed. Caught on Linux by the first run of the very
        # suite added because this file had no tests.
        exit 0
    }

    'Compose' {
        if (-not $PopulationFile) { throw 'ci-glob-audit: -PopulationFile is required in Compose mode.' }
        if (-not $PartialsDir) { throw 'ci-glob-audit: -PartialsDir is required in Compose mode.' }
        if ($Issue -le 0 -and -not $DryRun) { throw 'ci-glob-audit: -Issue is required in Compose mode; the record has no durable home without it.' }

        $doc = Get-Content -LiteralPath $PopulationFile -Raw | ConvertFrom-Json
        $partialFiles = @(Get-ChildItem -Path $PartialsDir -Filter '*.json' -Recurse -File | Sort-Object FullName)
        $partials = @($partialFiles | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json })

        $problems = [System.Collections.Generic.List[string]]::new()

        $seenShards = @($partials | ForEach-Object { [int]$_.shardIndex } | Sort-Object -Unique)
        $expectedShards = @(0..([int]$doc.shardCount - 1))
        $missingShards = @($expectedShards | Where-Object { $seenShards -notcontains $_ })
        if ($missingShards.Count -gt 0) {
            $problems.Add("shard partial(s) missing: $($missingShards -join ', '). A record assembled from a subset is not a record of the population.")
        }

        # Rows arrive carrying their own `Path`: `Invoke-CIGlobAuditShard`
        # stamps it from the assignment in the job that executed the suite, and
        # it survives the partial JSON round-trip. Nothing re-stamps it here —
        # a second assignment from the same source established nothing and read
        # as the place the path comes from, which is the last thing the
        # reachability check's path comparison needs a reader to believe.
        $rows = @($partials | ForEach-Object { $_.rows } | Where-Object { $_ })

        $names = @($doc.population.names)
        $inPop = @($rows | Where-Object { $_.InPopulation })
        $missingRows = @($names | Where-Object { $n = $_; -not ($inPop | Where-Object { $_.Name -eq $n }) })
        $extraRows = @($inPop | Where-Object { $names -notcontains $_.Name } | ForEach-Object { $_.Name })
        $duplicates = @($inPop | Group-Object Name | Where-Object { $_.Count -gt 1 } | ForEach-Object { $_.Name })
        if ($missingRows.Count) { $problems.Add("no row for $($missingRows.Count) in-population suite(s): $($missingRows -join ', ')") }
        if ($extraRows.Count) { $problems.Add("row(s) for suites outside the derived population: $($extraRows -join ', ')") }
        if ($duplicates.Count) { $problems.Add("duplicate row(s): $($duplicates -join ', ')") }

        # Every shard must have executed under the same conditions, or the
        # record's single environment statement is a claim about a machine that
        # did not run most of the suites — so EVERY key is checked, from the one
        # exported list the producer fills and the statement builder requires.
        # A per-consumer key list is how the booleans that decide four parity
        # verdicts, and the working directory, came to be read off one shard
        # with no agreement check at all.
        #
        # The reference shard is the lowest shardIndex, not the first FILE:
        # `partial-10.json` sorts before `partial-2.json`, so file order stops
        # being shard order the moment the dispatch asks for more than ten.
        # Two-step, deliberately: the exported list returns `,@(...)` so the
        # array survives the pipeline intact, and `@(Get-CIGlobAuditFactKeys)`
        # written inline therefore yields a ONE-element array holding the list
        # rather than the list. That silently narrows this whole agreement
        # check to a single dimension, which is the defect the single exported
        # list exists to remove. Assign first, wrap second, then assert.
        $factKeys = Get-CIGlobAuditFactKeys
        $factKeys = @($factKeys)
        if ($factKeys.Count -lt 1 -or @($factKeys | Where-Object { $_ -isnot [string] -or -not $_ }).Count -gt 0) {
            throw "ci-glob-audit: Get-CIGlobAuditFactKeys did not return a flat list of fact-key names (got $($factKeys.Count) item(s) of type $(($factKeys | ForEach-Object { $_.GetType().Name } | Sort-Object -Unique) -join ', ')). Refusing to run a cross-shard agreement check over a list this file cannot read."
        }
        $ordered = @($partials | Sort-Object { [int]$_.shardIndex })
        $facts = @{}
        $noEnvironment = ($partials.Count -eq 0)
        # A partial that carries no `facts` object at all — an older shape, a
        # truncated write — must not take the compose job down: this runs before
        # any persistence, and `$_.facts` on an object without that property is
        # a terminating error under `Set-StrictMode -Version Latest`. Absence of
        # the container is read as absence of every key in it, which is what it
        # is.
        $hasFactKey = {
            param($Partial, $Key)
            ($Partial.PSObject.Properties.Match('facts').Count -gt 0) -and
            ($null -ne $Partial.facts) -and
            ($Partial.facts.PSObject.Properties.Match($Key).Count -gt 0)
        }
        $unobservedKeys = [System.Collections.Generic.List[string]]::new()
        if (-not $noEnvironment) {
            foreach ($k in $factKeys) {
                $present = @($ordered | Where-Object { & $hasFactKey $_ $k })
                # THE ZERO CASE IS NOT THE PARTIAL CASE, and saying so matters.
                # "the environment statement's value for it describes only the
                # shards that did" is false when NO shard did: there is no
                # value, and the sentence would tell a reader one exists and is
                # merely narrow.
                if ($present.Count -eq 0) {
                    # $null, NOT a stand-in. A dimension nobody observed has no
                    # value, and inventing one — a placeholder string, a
                    # defaulted boolean — is what let the record assert parity
                    # on cells that visibly contradicted each other, certified
                    # `computed` by the `checked by` column. The null is the
                    # structural signal that the statement builder reads as
                    # genuinely unknown; the problem below is what stops it
                    # passing in silence.
                    $unobservedKeys.Add($k)
                    $facts[$k] = $null
                    continue
                }
                if ($present.Count -ne $ordered.Count) {
                    $absent = @($ordered | Where-Object { -not (& $hasFactKey $_ $k) } | ForEach-Object { [int]$_.shardIndex })
                    $problems.Add("shard(s) $($absent -join ', ') observed no '$k' fact; the environment statement's value for it describes only the shards that did.")
                }
                $distinct = @($present | ForEach-Object { [string]$_.facts.$k } | Sort-Object -Unique)
                if ($distinct.Count -gt 1) { $problems.Add("shards disagree on '$k': $($distinct -join ' | ')") }
                # Value taken RAW from the reference shard, not as a string: a
                # JSON `false` stringified to 'False' and cast back with [bool]
                # is `$true`, which would silently invert four parity verdicts.
                # Comparison above is on the string projection; storage is not.
                $facts[$k] = $present[0].facts.$k
            }
        }
        if ($unobservedKeys.Count -gt 0) {
            # Loud, and separately from the per-shard message above, because
            # this is the case where the record has nothing at all to say about
            # a dimension. It is carried forward as unobserved rather than
            # filled in; no parity verdict on a dimension fed by one of these
            # keys may be read as a measurement, whichever way it renders.
            $problems.Add("no shard observed the fact(s) $(($unobservedKeys | ForEach-Object { "'$_'" }) -join ', ') at all. They are carried into the environment statement as UNOBSERVED rather than given a value, so any dimension they feed carries no parity verdict this run may claim.")
        }

        $bounds = @($partials | ForEach-Object { [int]$_.timeoutSeconds } | Sort-Object -Unique)
        if ($bounds.Count -gt 1) { $problems.Add("shards ran at different bounds: $($bounds -join ', ')") }
        $bound = if ($bounds.Count -ge 1) { $bounds[0] } else { $TimeoutSeconds }

        if ($noEnvironment) {
            # NOT placeholder facts. A parity table filled with stand-ins
            # describes no machine, and feeding those stand-ins to the
            # instrument basis would produce a basis value that resets every
            # suite's observation count on a run that measured nothing. The
            # record still gets composed and persisted — the missing shards are
            # already in $problems and a record that is simply absent teaches
            # nobody anything — but it says outright that no environment was
            # observed, and the history is not written at all.
            $problems.Add('no shard partial reached this run, so NO environment was observed. The record below states that rather than describing a machine; the parity table, the instrument basis and the observation history are all withheld, not filled with stand-ins.')
            $environment = @(
                [PSCustomObject]@{
                    Dimension = 'all dimensions'
                    Gate      = "pester.yml's stated constraints"
                    Audit     = '**not observed** — no shard partial reached the compose job'
                    # $null, not $false: the parity verdict is three-valued and
                    # `no` would assert a DISAGREEMENT this run cannot have
                    # found. Nothing was observed, so nothing agrees or
                    # disagrees, and `unknown` is the only true cell.
                    Agrees    = $null
                    Basis     = 'not checkable from this run: no environment was observed at all'
                    Note      = 'This run executed no suites it can account for, so it makes no parity claim on any dimension. R8(a) is not discharged by this record; the dimensions are unobserved, not equal.'
                },
                # `concurrency` is named EXPLICITLY, and it is not decoration.
                # The record's timing-integrity section states non-contention
                # "on the observed concurrency statement", and reads that
                # statement out of the dimension called `concurrency`. With no
                # such row it printed the literal `(concurrency not stated)` as
                # the basis of a claim it was making anyway — a sentence whose
                # own cited ground says nothing. The claim is still the
                # composer's to withhold on an empty row set; this row at least
                # stops the ground it cites from being a placeholder.
                [PSCustomObject]@{
                    Dimension = 'concurrency'
                    Gate      = 'one job, one process, no parallelism'
                    Audit     = '**no concurrency was observed** — no shard partial reached the compose job, so this run measured no suite, offers no duration, and supports no non-contention claim'
                    Agrees    = $null
                    Basis     = 'not checkable from this run: no shard reported the concurrency it ran under'
                    Note      = 'R7 rests on knowing what else was running while a duration was taken. This run knows nothing about that, and an empty row set is not a quiet runner.'
                }
            )
            $basis = 'not established — no environment was observed, so no two observations may be pooled with this run'
        }
        else {
            $environment = Get-CIGlobAuditEnvironmentStatement -Facts $facts
            $basis = Get-CIGlobAuditInstrumentBasis -EnvironmentStatement $environment -BoundSeconds $bound
        }

        $agreement = Get-CIGlobAuditGateAgreement -Rows $rows -SelectedNames @($doc.population.selectedNames)
        # R8(b)'s standard is the gate's OWN recent runs, so the expectation the
        # record states is read from them rather than asserted over them.
        Add-Member -InputObject $agreement -NotePropertyName 'GateExpectation' `
            -NotePropertyValue (script:Get-GateExpectation) -Force
        # ---- R4, and the difference between clean and unchecked ----
        # BOTH reachability arms are filters over the row set: the gate arm
        # selects `did-not-complete` rows whose name the gate selects, the
        # tests-root arm selects them by path. Over an EMPTY row set both
        # return empty, `Clean` is $true, and the durable record — the artifact
        # #993 and #1036 read — prints `clean: True` for a run that measured
        # nothing. That is the vacuity the parent's own review sustained twice,
        # reopened on the path the zero-partial branch created: the job exits 2,
        # but the comment that outlives the job says the property holds.
        #
        # So the verdict is WITHHELD rather than computed, and the withholding
        # is the value the record renders. `Clean` stays truthy deliberately —
        # the composer's escalate-to-#993 clause fires on a FALSE `Clean`, and
        # "nothing was checked" must not masquerade as "a stalled suite is
        # reachable" any more than it may masquerade as clean.
        $observedNoRows = (@($rows).Count -eq 0)
        if ($observedNoRows) {
            $reachability = [PSCustomObject]@{
                Clean              = 'not established — this run recorded no suite row at all, so both arms ran over an empty set and neither could have found anything'
                GateReachable      = @()
                TestsRootReachable = @()
                StalledCount       = 'not established (no suite row reached this run)'
            }
            $problems.Add("R4 reachability is NOT established by this run: no suite row reached the compose job, so the gate-selection arm and the tests-root arm both filtered an empty set. The record withholds `clean` instead of reporting it true — an empty row set satisfies both arms vacuously, which is not the same fact as no reachable `did-not-complete` suite existing.")
        }
        else {
            $reachability = Get-CIGlobAuditReachability -Rows $rows -SelectedNames @($doc.population.selectedNames) -TestsRoot $doc.testsRoot
        }
        $controlCheck = Test-CIGlobAuditControlExpectation -Rows $rows -Expectations ([hashtable]$script:ControlExpectations)

        # ---- the run's own identity, from the run, not from this file ----
        # Every external call in this block is caught, not merely exit-code
        # checked. All of it runs BEFORE the record is persisted, and an
        # absent or unrunnable `gh`/`git` under $ErrorActionPreference = 'Stop'
        # would turn a degraded anchor into no record at all — the inversion
        # the zero-partial path above exists to prevent, arriving one block
        # later.
        $defaultBranch = ''
        try { $defaultBranch = (& gh repo view --json defaultBranchRef --jq '.defaultBranchRef.name' 2>$null) } catch { $defaultBranch = '' }
        if (-not $defaultBranch) { $defaultBranch = 'main' }
        # Both exit codes are checked. An unsettled anchor that silently stays
        # 'not evaluated' lets a run exit 0 having said nothing about which ref
        # it measured — the unanchored-record class the commit anchor exists to
        # close, arriving through a resolution failure instead of a bad
        # comparison.
        $commit = ''; $commitOk = $false
        try {
            $commit = (& git rev-parse HEAD 2>$null | Out-String).Trim()
            $commitOk = ($LASTEXITCODE -eq 0) -and [bool]$commit
        }
        catch { $commit = ''; $commitOk = $false }
        $tip = ''; $tipOk = $false
        try {
            $tip = (& git rev-parse "origin/$defaultBranch" 2>$null | Out-String).Trim()
            $tipOk = ($LASTEXITCODE -eq 0) -and [bool]$tip
        }
        catch { $tip = ''; $tipOk = $false }

        $ancestry = 'not evaluated'
        $contentDifferences = 'not evaluated'
        if (-not $commitOk -or -not $tipOk) {
            $unsettled = @()
            if (-not $commitOk) { $unsettled += 'the measured ref (`git rev-parse HEAD`)' }
            if (-not $tipOk) { $unsettled += "the $defaultBranch tip (``git rev-parse origin/$defaultBranch``)" }
            $ancestry = '**UNSETTLED** — ' + ($unsettled -join ' and ') + ' could not be resolved, so no ancestry check ran'
            $contentDifferences = '**UNSETTLED** — no per-suite content comparison ran, because the anchor it compares against could not be resolved'
            $problems.Add("the record's commit anchor is UNSETTLED: $($unsettled -join ' and ') could not be resolved, so neither the ancestry check nor the per-suite content comparison ran. This record is not evidence about the default branch's suites.")
        }
        elseif ($commit -eq $tip) {
            $ancestry = "measured ref IS the $defaultBranch tip"
            $contentDifferences = 'none — same commit'
        }
        else {
            $isAncestor = $false
            try {
                & git merge-base --is-ancestor $tip $commit 2>$null | Out-Null
                $isAncestor = ($LASTEXITCODE -eq 0)
            }
            catch { $isAncestor = $false }
            $ancestry = if ($isAncestor) { "$defaultBranch tip ``$tip`` IS an ancestor of the measured ref" }
            else { "**$defaultBranch tip ``$tip`` is NOT an ancestor of the measured ref** — this measurement is not evidence about the default branch's suites" }

            $changed = @(); $diffOk = $false
            try {
                $changed = @((& git diff --name-only "$tip" "$commit" -- $doc.testsRoot 2>$null) | Where-Object { $_ })
                $diffOk = ($LASTEXITCODE -eq 0)
            }
            catch { $changed = @(); $diffOk = $false }
            # SUITE files, not "any file under the tests root". The quarantine
            # registry lives under that root and is not a suite: counting it
            # renders "1 suite file(s) differ" for a registry-only change and
            # pushes the run to exit 2 where no suite differs at all. Naming a
            # non-suite is a misstatement in the very anchor this settles.
            $diff = @($changed | Where-Object { $_ -like '*.Tests.ps1' })
            $nonSuite = @($changed | Where-Object { $_ -notlike '*.Tests.ps1' })
            $nonSuiteClause = if ($nonSuite.Count) { " ($($nonSuite.Count) non-suite file(s) under that root also differ — $($nonSuite -join ', ') — which the gate's population does not include)" } else { '' }

            if (-not $diffOk) {
                $contentDifferences = '**UNSETTLED** — `git diff` against the ' + $defaultBranch + ' tip failed, so no per-suite content comparison ran'
                $problems.Add("the per-suite content comparison against the $defaultBranch tip failed to run (git diff exited non-zero), so the record's commit anchor is settled by ancestry alone.")
            }
            elseif ($diff.Count -eq 0) {
                $contentDifferences = "none — no suite file (``*.Tests.ps1``) under the tests root differs in content from the $defaultBranch tip$nonSuiteClause"
            }
            else {
                $contentDifferences = "**$($diff.Count) suite file(s) differ from the $defaultBranch tip**: $($diff -join ', ') — no row for these is evidence about that suite$nonSuiteClause"
            }
            if (-not $isAncestor -or $diff.Count -gt 0) { $problems.Add('the measured ref is not content-equivalent to the default branch tip; see the record''s commit anchor') }
        }

        $runId = if ($env:GITHUB_RUN_ID) { $env:GITHUB_RUN_ID } else { 'local' }
        $server = if ($env:GITHUB_SERVER_URL) { $env:GITHUB_SERVER_URL } else { 'https://github.com' }
        $runContext = @{
            RunId              = $runId
            RunUrl             = if ($env:GITHUB_REPOSITORY) { "$server/$env:GITHUB_REPOSITORY/actions/runs/$runId" } else { '(local)' }
            RunAttempt         = if ($env:GITHUB_RUN_ATTEMPT) { $env:GITHUB_RUN_ATTEMPT } else { '1' }
            TriggerEvent       = if ($env:GITHUB_EVENT_NAME) { $env:GITHUB_EVENT_NAME } else { '(local)' }
            Commit             = $commit
            Ref                = if ($env:GITHUB_REF) { $env:GITHUB_REF } else { '(local)' }
            DefaultBranch      = $defaultBranch
            DefaultBranchTip   = $tip
            AncestryCheck      = $ancestry
            ContentDifferences = $contentDifferences
            BoundSeconds       = $bound
            ShardCount         = $doc.shardCount
            InstrumentBasis    = $basis
            StartedAt          = [System.DateTimeOffset]::UtcNow.ToString('o')
            # Column order is not a contract. A consumer reading this record
            # two chunks downstream needs to know which shape it is reading
            # before it decides how to read it.
            RecordFormatVersion = $script:RecordFormatVersion
        }

        $populationView = [PSCustomObject]@{
            Names             = $names
            SelectedCount     = $doc.population.selectedCount
            QuarantinedCount  = $doc.population.quarantinedCount
            UnclassifiedCount = $doc.population.unclassifiedCount
            StaleQuarantine   = @($doc.population.staleQuarantine)
            HasDrift          = $doc.population.hasDrift
            DerivationCommand = $doc.population.derivationCommand
        }

        $owner = ''; $repo = ''
        if ($env:GITHUB_REPOSITORY -and $env:GITHUB_REPOSITORY.Contains('/')) {
            $owner, $repo = $env:GITHUB_REPOSITORY.Split('/', 2)
        }

        # ---- one read of the issue's comments, before anything is written ----
        # The index and the history are both UPSERTS that merge into what is
        # already there, and the orphan reconciliation below needs the same
        # listing. Read once, before the persist loop, so all three see the same
        # pre-run state.
        $commentRead = if ($DryRun) {
            [PSCustomObject]@{ Status = 'skipped'; Comments = @(); Detail = 'dry run — GitHub was neither read nor written' }
        }
        else {
            script:Get-IssueCommentsPaged -IssueNumber $Issue -Owner $owner -Repo $repo
        }

        $indexRead = script:Get-CommentBodyByMarker -Read $commentRead -Marker $script:IndexMarker
        $indexReadFailed = ($indexRead.Status -eq 'read-failed')
        if ($indexReadFailed) {
            $problems.Add("could not read the existing index comment ($($indexRead.Detail)); the stable pointer is NOT being rewritten this run. Merging into an empty index would drop every prior run from the one surface a consumer can address without enumerating comments.")
        }

        $documents = New-CIGlobAuditRecordDocuments -RunContext $runContext -Rows $rows `
            -EnvironmentStatement $environment -Population $populationView `
            -GateAgreement $agreement -Reachability $reachability -ControlCheck $controlCheck `
            -ExistingIndexBody $indexRead.Body

        foreach ($d in $documents) {
            # Refuse rather than reset, same rule as the history: an index
            # composed from a body that could not be read is a shorter index,
            # and it would overwrite the real one.
            if ($indexReadFailed -and $d.Kind -eq 'index') {
                Write-Host "Skipped the index document ($($d.Marker)): its prior content could not be read."
                continue
            }
            $body = script:Protect-Body -Text ([string]$d.Body)
            if ($DryRun) {
                $renderDir = script:Resolve-OutFile -Candidate '' -Fallback (Join-Path $PartialsDir 'dry-run-rendered/placeholder')
                $rendered = Join-Path (Split-Path -Parent $renderDir) "$($d.Kind)-$($d.Index).md"
                Set-Content -LiteralPath $rendered -Value $body -Encoding utf8
                Write-Host "[dry run] would persist $($d.Kind) document $($d.Marker) — $(Measure-CIGlobAuditBody -Body $body) codepoints; rendered to $rendered"
                continue
            }
            $upsertArgs = @{ Type = 'issue'; Number = $Issue; Marker = $d.Marker; Body = $body }
            if ($owner -and $repo) { $upsertArgs['Owner'] = $owner; $upsertArgs['Repo'] = $repo }
            $result = Find-OrUpsertComment @upsertArgs
            if ($null -eq $result) { $problems.Add("failed to persist document '$($d.Marker)' to issue #$Issue") }
            else { Write-Host "Persisted $($d.Kind) document: $($d.Marker)" }
        }

        # ---- reconcile paginated parts a re-attempt no longer produces ----
        # Both paginated families are per-index and upserted, so a re-run of the
        # same run id that composes two parts where the previous attempt
        # composed three leaves part 3 on the issue: unreferenced by the
        # summary, and indistinguishable to a reader from a part that is still
        # current. Superseding it in place keeps the surface honest without a
        # delete. Both families, not just detail — the per-suite table paginates
        # the same way and orphans the same way.
        if ($commentRead.Status -eq 'ok') {
            foreach ($family in @('detail', 'rows')) {
                $liveCount = @($documents | Where-Object { $_.Kind -eq $family }).Count
                $orphanPattern = '^<!--\s*ci-glob-audit-' + $family + '-' + [regex]::Escape($runId) + '-(\d+)\s*-->\s*$'
                $orphans = [System.Collections.Generic.List[int]]::new()
                foreach ($c in $commentRead.Comments) {
                    $line1 = (([string]$c.body) -split "`r?`n", 2)[0]
                    if ($line1 -match $orphanPattern -and [int]$Matches[1] -gt $liveCount) { $orphans.Add([int]$Matches[1]) }
                }
                foreach ($i in ($orphans | Sort-Object -Unique)) {
                    $marker = "<!-- ci-glob-audit-$family-$runId-$i -->"
                    $advertised = if ($liveCount -gt 0) { "parts 1..$liveCount" } else { "no $family parts at all" }
                    $tombstone = @(
                        $marker,
                        '',
                        "## Full-glob CI audit — superseded $family part $i",
                        '',
                        "Run ``$runId`` re-composed its record into $liveCount ``$family`` part(s), so part $i no longer exists. **Nothing in this comment is part of the record.** The current record for this run is the summary ``<!-- ci-glob-audit-record-$runId -->`` and $advertised; the stable pointer is ``$($script:IndexMarker)``."
                    ) -join "`n"
                    $tombArgs = @{ Type = 'issue'; Number = $Issue; Marker = $marker; Body = $tombstone }
                    if ($owner -and $repo) { $tombArgs['Owner'] = $owner; $tombArgs['Repo'] = $repo }
                    if ($null -eq (Find-OrUpsertComment @tombArgs)) { $problems.Add("failed to supersede orphaned $family document '$marker' on issue #$Issue") }
                    else { Write-Host "Superseded orphaned $family document: $marker" }
                }
            }
        }

        # ---- the observation history ----
        $historyRead = script:Get-CommentBodyByMarker -Read $commentRead -Marker $script:HistoryMarker
        $skipHistory = ''
        if ($noEnvironment) {
            $skipHistory = 'this run observed no environment and executed no suites it can account for, so it has no comparable observation to record. Writing one would key every suite to a basis derived from nothing.'
        }
        elseif ($historyRead.Status -eq 'read-failed') {
            # REFUSE, do not reset. Rebuilding from an unread history and
            # upserting it PATCHes the real comment with a fresh one, silently
            # restarting every suite's observation count — the number the
            # triage chunk promotes on.
            $skipHistory = "the existing observation history could not be read ($($historyRead.Detail)). Rewriting it from an assumed-empty history would reset every suite's observation count in place, so this run refuses to touch it."
        }
        if ($skipHistory) {
            $problems.Add("the observation history was NOT updated: $skipHistory")
            Write-Host "::warning::ci-glob-audit: observation history not updated — $skipHistory"
        }
        else {
            $inPopByName = @{}
            foreach ($r in $rows) { $inPopByName[[string]$r.Name] = [bool]$r.InPopulation }
            $history = Update-CIGlobAuditHistory -ExistingBody $historyRead.Body -Rows $rows `
                -InstrumentBasis $basis -RunId $runId -Marker $script:HistoryMarker -Commit $commit `
                -InPopulationByName $inPopByName
            $historyBody = script:Protect-Body -Text ([string]$history.Body)
            if ($DryRun) {
                Write-Host "[dry run] would persist the observation history — $($history.Entries.Count) suite rows, $(Measure-CIGlobAuditBody -Body $historyBody) codepoints"
            }
            else {
                $historyArgs = @{ Type = 'issue'; Number = $Issue; Marker = $script:HistoryMarker; Body = $historyBody }
                if ($owner -and $repo) { $historyArgs['Owner'] = $owner; $historyArgs['Repo'] = $repo }
                if ($null -eq (Find-OrUpsertComment @historyArgs)) { $problems.Add('failed to persist the observation history') }
                else { Write-Host "Persisted observation history ($($history.Entries.Count) suite rows)." }
            }
        }

        # ---- verdict ----
        $failedControls = @($controlCheck | Where-Object { -not $_.Ok })
        if ($failedControls.Count) { $problems.Add("control(s) did not produce their expected terminal state: $(($failedControls | ForEach-Object { $_.Name }) -join ', ')") }
        # `-is [bool]` deliberately: on the withheld path above `Clean` carries
        # the sentence that says why no verdict was reached, and a truthiness
        # test over a string would read a withheld verdict as a clean one the
        # moment somebody made that sentence empty. Only an actual computed
        # $false escalates.
        if ($reachability.Clean -is [bool] -and -not $reachability.Clean) { $problems.Add('a `did-not-complete` suite is reachable by a documented way of running this repository''s tests — escalate to #993') }

        $nonPassedInPop = @($inPop | Where-Object { $_.State -ne 'passed' })

        $summaryLines = @(
            '## Full-glob CI audit',
            '',
            "Run ``$runId`` at commit ``$commit``, bound ${bound}s, $($doc.shardCount) shard(s).",
            '',
            "- in-population rows: $($inPop.Count) of $($names.Count) expected",
            "- non-passed in-population rows: $($nonPassedInPop.Count)",
            "- ``did-not-complete``: $($reachability.StalledCount) (reachability clean: $($reachability.Clean))",
            "- controls matching their expected state: $(@($controlCheck | Where-Object { $_.Ok }).Count) of $(@($controlCheck).Count)",
            $(
                $historyClause = if ($skipHistory) { 'the observation history was NOT updated (see integrity problems)' } else { 'plus the observation history' }
                $persistedCount = @($documents | Where-Object { -not ($indexReadFailed -and $_.Kind -eq 'index') }).Count
                if ($DryRun) { "- **dry run — nothing was written to GitHub.** $persistedCount record comment(s) were composed and checked; $historyClause." }
                else { "- record persisted to issue #$Issue as $persistedCount comment(s); $historyClause" }
            ),
            ''
        )
        if ($problems.Count) {
            $summaryLines += @('### Integrity problems', '') + @($problems | ForEach-Object { "- $_" }) + @('')
        }
        $summaryText = script:Protect-Body -Text ($summaryLines -join "`n")
        $summaryLines = $summaryText -split "`n"
        if ($env:GITHUB_STEP_SUMMARY) { Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Value $summaryText }
        $summaryLines | ForEach-Object { Write-Host $_ }

        if ($problems.Count -gt 0) {
            foreach ($p in $problems) { Write-Host "::error::ci-glob-audit: $p" }
            exit 2
        }
        if ($nonPassedInPop.Count -gt 0) {
            # Red by construction: this audit ignores the quarantine, so it fails
            # whenever any suite fails, and that is the expected state from day
            # one. The record is already persisted above — a red job is never a
            # reason a record is absent.
            $where = if ($DryRun) { 'nothing was persisted (dry run)' } else { "the record is persisted on issue #$Issue" }
            Write-Host "::warning::ci-glob-audit: $($nonPassedInPop.Count) in-population suite(s) did not pass. This is expected while the quarantine is unapplied; $where."
            exit 1
        }
        exit 0
    }
}
