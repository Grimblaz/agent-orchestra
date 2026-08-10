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
    Directory holding the out-of-population control suites. Prepare.

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

function script:Get-CommentBodyByMarker {
    param([Parameter(Mandatory)][int]$IssueNumber, [Parameter(Mandatory)][string]$Marker)
    $json = & gh issue view $IssueNumber --json comments 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $json) { return '' }
    try { $parsed = $json | ConvertFrom-Json } catch { return '' }
    foreach ($c in @($parsed.comments)) {
        if (Test-CommentBodyMarkerLine1 -Body ([string]$c.body) -Marker $Marker) { return [string]$c.body }
    }
    return ''
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

        Write-Host "Population derived: $($population.Names.Count) in-population suite(s) (selected $($population.SelectedCount), quarantined $($population.QuarantinedCount), unclassified $($population.UnclassifiedCount)), plus $($script:ControlExpectations.Count) out-of-population control(s), across $ShardCount shard(s)."
        Write-Host "HasDrift: $($population.HasDrift)"

        if ($env:GITHUB_OUTPUT) {
            $shards = (0..($ShardCount - 1)) | ConvertTo-Json -Compress
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
        ([ordered]@{
            shardIndex     = $ShardIndex
            shardCount     = $doc.shardCount
            timeoutSeconds = $TimeoutSeconds
            facts          = $facts
            rows           = @($rows)
        }) | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $target -Encoding utf8

        Write-Host "Shard $ShardIndex complete: $($rows.Count) row(s) written to $target."
        # Deliberately exit 0 even when suites failed. A shard that reddens here
        # loses its partial, and a missing partial is a hole in the record — the
        # audit is red BY CONSTRUCTION and the redness belongs at the end, after
        # the record is safely persisted.
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

        $rows = @($partials | ForEach-Object { $_.rows } | Where-Object { $_ })
        foreach ($r in $rows) {
            $item = @($doc.items | Where-Object { $_.name -eq $r.Name }) | Select-Object -First 1
            if ($item) {
                Add-Member -InputObject $r -NotePropertyName 'Path' -NotePropertyValue ([string]$item.path) -Force
            }
        }

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
        # did not run most of the suites.
        $factKeys = @('ProcessModel', 'Concurrency', 'TokenAvailability', 'CheckoutDepth', 'CredentialPersistence',
            'GitIdentity', 'RunnerImage', 'PowerShellVersion', 'PesterVersion', 'YamlModuleVersion')
        $facts = @{}
        if ($partials.Count -gt 0) {
            foreach ($k in $factKeys) {
                $values = @($partials | ForEach-Object { [string]$_.facts.$k } | Sort-Object -Unique)
                if ($values.Count -gt 1) { $problems.Add("shards disagree on '$k': $($values -join ' | ')") }
                $facts[$k] = $values[0]
            }
            foreach ($k in @('HasToken', 'IsShallow', 'CredentialsPersisted', 'HasGitIdentity')) {
                $facts[$k] = [bool]$partials[0].facts.$k
            }
            $facts['WorkingDirectory'] = [string]$partials[0].facts.WorkingDirectory
        }

        $bounds = @($partials | ForEach-Object { [int]$_.timeoutSeconds } | Sort-Object -Unique)
        if ($bounds.Count -gt 1) { $problems.Add("shards ran at different bounds: $($bounds -join ', ')") }
        $bound = if ($bounds.Count -ge 1) { $bounds[0] } else { $TimeoutSeconds }

        $environment = Get-CIGlobAuditEnvironmentStatement -Facts $facts
        $basis = Get-CIGlobAuditInstrumentBasis -EnvironmentStatement $environment -BoundSeconds $bound
        $agreement = Get-CIGlobAuditGateAgreement -Rows $rows -SelectedNames @($doc.population.selectedNames)
        $reachability = Get-CIGlobAuditReachability -Rows $rows -SelectedNames @($doc.population.selectedNames) -TestsRoot $doc.testsRoot
        $controlCheck = Test-CIGlobAuditControlExpectation -Rows $rows -Expectations ([hashtable]$script:ControlExpectations)

        # ---- the run's own identity, from the run, not from this file ----
        $defaultBranch = (& gh repo view --json defaultBranchRef --jq '.defaultBranchRef.name' 2>$null)
        if (-not $defaultBranch) { $defaultBranch = 'main' }
        $commit = (& git rev-parse HEAD 2>$null | Out-String).Trim()
        $tip = (& git rev-parse "origin/$defaultBranch" 2>$null | Out-String).Trim()
        $ancestry = 'not evaluated'
        $contentDifferences = 'not evaluated'
        if ($commit -and $tip) {
            if ($commit -eq $tip) {
                $ancestry = "measured ref IS the $defaultBranch tip"
                $contentDifferences = 'none — same commit'
            }
            else {
                & git merge-base --is-ancestor $tip $commit 2>$null | Out-Null
                $isAncestor = ($LASTEXITCODE -eq 0)
                $ancestry = if ($isAncestor) { "$defaultBranch tip ``$tip`` IS an ancestor of the measured ref" }
                else { "**$defaultBranch tip ``$tip`` is NOT an ancestor of the measured ref** — this measurement is not evidence about the default branch's suites" }
                $diff = @((& git diff --name-only "$tip" "$commit" -- $doc.testsRoot 2>$null) | Where-Object { $_ })
                $contentDifferences = if ($diff.Count -eq 0) { 'none — no suite differs in content from the default-branch tip' }
                else { "**$($diff.Count) suite file(s) differ from the $defaultBranch tip**: $($diff -join ', ') — no row for these is evidence about that suite" }
                if (-not $isAncestor -or $diff.Count -gt 0) { $problems.Add('the measured ref is not content-equivalent to the default branch tip; see the record''s commit anchor') }
            }
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

        $documents = New-CIGlobAuditRecordDocuments -RunContext $runContext -Rows $rows `
            -EnvironmentStatement $environment -Population $populationView `
            -GateAgreement $agreement -Reachability $reachability -ControlCheck $controlCheck

        $owner = ''; $repo = ''
        if ($env:GITHUB_REPOSITORY -and $env:GITHUB_REPOSITORY.Contains('/')) {
            $owner, $repo = $env:GITHUB_REPOSITORY.Split('/', 2)
        }

        foreach ($d in $documents) {
            if ($DryRun) {
                $renderDir = script:Resolve-OutFile -Candidate '' -Fallback (Join-Path $PartialsDir 'dry-run-rendered/placeholder')
                $rendered = Join-Path (Split-Path -Parent $renderDir) "$($d.Kind)-$($d.Index).md"
                Set-Content -LiteralPath $rendered -Value $d.Body -Encoding utf8
                Write-Host "[dry run] would persist $($d.Kind) document $($d.Marker) — $(Measure-CIGlobAuditBody -Body $d.Body) codepoints; rendered to $rendered"
                continue
            }
            $upsertArgs = @{ Type = 'issue'; Number = $Issue; Marker = $d.Marker; Body = $d.Body }
            if ($owner -and $repo) { $upsertArgs['Owner'] = $owner; $upsertArgs['Repo'] = $repo }
            $result = Find-OrUpsertComment @upsertArgs
            if ($null -eq $result) { $problems.Add("failed to persist document '$($d.Marker)' to issue #$Issue") }
            else { Write-Host "Persisted $($d.Kind) document: $($d.Marker)" }
        }

        $existingHistory = if ($DryRun) { '' } else { script:Get-CommentBodyByMarker -IssueNumber $Issue -Marker $script:HistoryMarker }
        $history = Update-CIGlobAuditHistory -ExistingBody $existingHistory -Rows $rows `
            -InstrumentBasis $basis -RunId $runId -Marker $script:HistoryMarker -Commit $commit
        if ($DryRun) {
            Write-Host "[dry run] would persist the observation history — $($history.Entries.Count) suite rows, $(Measure-CIGlobAuditBody -Body $history.Body) codepoints"
        }
        else {
            $historyArgs = @{ Type = 'issue'; Number = $Issue; Marker = $script:HistoryMarker; Body = $history.Body }
            if ($owner -and $repo) { $historyArgs['Owner'] = $owner; $historyArgs['Repo'] = $repo }
            if ($null -eq (Find-OrUpsertComment @historyArgs)) { $problems.Add('failed to persist the observation history') }
            else { Write-Host "Persisted observation history ($($history.Entries.Count) suite rows)." }
        }

        # ---- verdict ----
        $failedControls = @($controlCheck | Where-Object { -not $_.Ok })
        if ($failedControls.Count) { $problems.Add("control(s) did not produce their expected terminal state: $(($failedControls | ForEach-Object { $_.Name }) -join ', ')") }
        if (-not $reachability.Clean) { $problems.Add('a `did-not-complete` suite is reachable by a documented way of running this repository''s tests — escalate to #993') }

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
            $(if ($DryRun) { "- **dry run — nothing was written to GitHub.** $(@($documents).Count) record comment(s) plus the observation history were composed and checked." }
                else { "- record persisted to issue #$Issue as $(@($documents).Count) comment(s) plus the observation history" }),
            ''
        )
        if ($problems.Count) {
            $summaryLines += @('### Integrity problems', '') + @($problems | ForEach-Object { "- $_" }) + @('')
        }
        if ($env:GITHUB_STEP_SUMMARY) { Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Value ($summaryLines -join "`n") }
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
