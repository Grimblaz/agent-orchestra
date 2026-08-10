#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#!
.SYNOPSIS
    Contract tests for the full-glob CI audit (issue #1035).

.DESCRIPTION
    The audit's whole value is that a downstream reader can trust the four
    terminal states apart from one another, trust that every suite in the
    population was actually attempted, and trust that two observations pooled
    together were observations of the same thing. Each of those is a property
    something can get quietly wrong, so each is driven here to BOTH polarities.

    Two kinds of test live in this file and they are not interchangeable:

      * Pure-function tests over the classifier, the composer and the history,
        which can reach states a live run may never exhibit.
      * End-to-end tests that put the SHIPPED controls through the SHIPPED
        execution path in a real child process. A green library nothing calls
        is the failure mode those exist to prevent — the repository has been
        bitten by it before — and the bound in particular cannot be
        demonstrated by any in-process assertion.
#>

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..')).Path
    . (Join-Path $script:RepoRoot '.github/scripts/lib/ci-glob-audit-core.ps1')

    $script:ControlsDir = Join-Path $script:RepoRoot '.github/scripts/audit-controls'
    $script:Scratch = Join-Path ([System.IO.Path]::GetTempPath()) ("ci-glob-audit-" + [System.Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $script:Scratch | Out-Null

    function script:New-FixtureTree {
        param([string[]]$Files, [object[]]$Quarantine)
        $dir = Join-Path $script:Scratch ([System.Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        foreach ($f in $Files) { Set-Content -LiteralPath (Join-Path $dir $f) -Value "# fixture $f" -Encoding utf8 }
        $qp = Join-Path $dir 'ci-quarantine.json'
        Set-Content -LiteralPath $qp -Value (([ordered]@{ quarantine = @($Quarantine) }) | ConvertTo-Json -Depth 6) -Encoding utf8
        return [PSCustomObject]@{ Dir = $dir; QuarantinePath = $qp }
    }

    function script:New-FactSet {
        param([hashtable]$Override = @{})
        $facts = @{
            ProcessModel          = 'one child pwsh process per suite'
            Concurrency           = 'one suite process at a time within this job'
            TokenAvailability     = 'observed: no token in the environment of the suite-executing process'
            CheckoutDepth         = 'observed: shallow, 1 commit(s) reachable => fetch-depth 1'
            CredentialPersistence = 'observed: true — an auth extraheader is present'
            GitIdentity           = 'observed: none configured'
            WorkingDirectory      = 'observed: /home/runner/work/repo/repo'
            RunnerImage           = 'Linux / 20260801.1'
            PowerShellVersion     = '7.4.6'
            PesterVersion         = '6.0.1'
            YamlModuleVersion     = '0.4.12'
            HasToken              = $false
            IsShallow             = $true
            CredentialsPersisted  = $true
            HasGitIdentity        = $false
        }
        foreach ($k in $Override.Keys) { $facts[$k] = $Override[$k] }
        return $facts
    }

    function script:New-Row {
        param(
            [string]$Name, [string]$State = 'passed', [string]$Reason = 'tests-executed-and-passed',
            [bool]$InPopulation = $true, [string]$Detail = 'detail', [string]$Digest = 'aaaaaaaaaaaa',
            [string]$Path = '', [int]$ElapsedMs = 100, [object]$Class = $null, [string]$ControlRole = '',
            [bool]$SurvivedKill = $false, [int]$Skipped = 0, [int]$Executed = 1
        )
        return [PSCustomObject]@{
            Name = $Name; State = $State; Reason = $Reason; InPopulation = $InPopulation
            Detail = $Detail; ContentDigest = $Digest; Path = $Path; ElapsedMs = $ElapsedMs
            BoundSeconds = 300; QuarantineClass = $Class; ControlRole = $ControlRole
            ProcessSurvivedKill = $SurvivedKill; Skipped = $Skipped; Executed = $Executed
        }
    }

    function script:New-RunContext {
        return @{
            RunId = '12345'; RunUrl = 'https://example/runs/12345'; RunAttempt = '1'
            TriggerEvent = 'workflow_dispatch'; Commit = 'abcdef1'; Ref = 'refs/heads/main'
            DefaultBranch = 'main'; DefaultBranchTip = 'abcdef1'; AncestryCheck = 'same commit'
            ContentDifferences = 'none'; BoundSeconds = 300; ShardCount = 8
            InstrumentBasis = 'abc123'; StartedAt = '2026-01-01T00:00:00Z'
        }
    }

    function script:New-PopulationView {
        param([string[]]$Names)
        return [PSCustomObject]@{
            Names = $Names; SelectedCount = 1; QuarantinedCount = 1; UnclassifiedCount = 1
            StaleQuarantine = @(); HasDrift = $false; DerivationCommand = 'fixture'
        }
    }

    # Every end-to-end test targets one of the SHIPPED controls, so the path
    # under test is the path the workflow runs — not a fixture written to agree
    # with the implementation.
    function script:Invoke-Control {
        param([string]$FileName, [int]$Bound = 60, [hashtable]$Env = @{})
        return Invoke-CIGlobAuditSuite `
            -SuiteFile (Join-Path $script:ControlsDir $FileName) `
            -TimeoutSeconds $Bound `
            -WorkDir (Join-Path $script:Scratch 'e2e') `
            -OutputVerbosity 'Normal' `
            -EnvironmentOverrides $Env
    }
}

AfterAll {
    if ($script:Scratch -and (Test-Path -LiteralPath $script:Scratch)) {
        Remove-Item -LiteralPath $script:Scratch -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Population: the gate''s own enumeration, before the quarantine is subtracted' {

    It 'is the union of selected and non-stale quarantined suites, not just the selected set' {
        $t = script:New-FixtureTree -Files @('a.Tests.ps1', 'b.Tests.ps1', 'c.Tests.ps1') -Quarantine @(
            [ordered]@{ file = 'b.Tests.ps1'; class = 'unclassified'; reason = 'never registered'; issue = $null }
            [ordered]@{ file = 'c.Tests.ps1'; class = 'linux-red'; reason = 'fails on linux'; issue = 904 }
        )
        $pop = Get-CIGlobAuditPopulation -TestsRoot $t.Dir -QuarantinePath $t.QuarantinePath
        $pop.Names | Should -Be @('a.Tests.ps1', 'b.Tests.ps1', 'c.Tests.ps1')
        # The discriminating half: a population equal to the SELECTED set would
        # be the whole defect, and would pass any check that only counts rows.
        $pop.Names | Should -Contain 'b.Tests.ps1' -Because 'a quarantined suite is exactly what this audit exists to measure'
        $pop.SelectedCount | Should -Be 1
    }

    It 'carries each suite''s quarantine class, and an explicit absence for a selected one' {
        $t = script:New-FixtureTree -Files @('a.Tests.ps1', 'b.Tests.ps1') -Quarantine @(
            [ordered]@{ file = 'b.Tests.ps1'; class = 'never-ci'; reason = 'needs a live gh'; issue = $null }
        )
        $pop = Get-CIGlobAuditPopulation -TestsRoot $t.Dir -QuarantinePath $t.QuarantinePath
        $pop.ClassByName['b.Tests.ps1'] | Should -Be 'never-ci'
        $pop.ClassByName['a.Tests.ps1'] | Should -BeNullOrEmpty
        $pop.ClassByName.ContainsKey('a.Tests.ps1') | Should -BeTrue -Because 'absence of a class must be recorded, not inferred from a missing key'
    }

    It 'REFUSES to derive a population from a drifted registry, with no override' {
        $t = script:New-FixtureTree -Files @('a.Tests.ps1') -Quarantine @(
            [ordered]@{ file = 'gone.Tests.ps1'; class = 'unclassified'; reason = 'deleted long ago'; issue = $null }
        )
        # The derivation is exact only while HasDrift is false. A fail-closed
        # predicate whose caller could carry on regardless would be a fail-open
        # writer, so there is deliberately no -AllowDrift switch to test.
        { Get-CIGlobAuditPopulation -TestsRoot $t.Dir -QuarantinePath $t.QuarantinePath } |
            Should -Throw -ExpectedMessage '*drifted registry*'
    }

    It 'refuses when the registry is missing entirely, rather than treating it as an empty quarantine' {
        $dir = Join-Path $script:Scratch ([System.Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        Set-Content -LiteralPath (Join-Path $dir 'a.Tests.ps1') -Value '# fixture' -Encoding utf8
        { Get-CIGlobAuditPopulation -TestsRoot $dir -QuarantinePath (Join-Path $dir 'nope.json') } | Should -Throw
    }

    It 'digests suite content, and two suites differing by one byte digest differently' {
        $dir = Join-Path $script:Scratch ([System.Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        $one = Join-Path $dir 'one.Tests.ps1'; $two = Join-Path $dir 'two.Tests.ps1'
        Set-Content -LiteralPath $one -Value 'Describe "x" { It "y" { $true } }' -Encoding utf8 -NoNewline
        Set-Content -LiteralPath $two -Value 'Describe "x" { It "z" { $true } }' -Encoding utf8 -NoNewline
        (Get-CIGlobAuditContentDigest -Path $one) | Should -Not -Be (Get-CIGlobAuditContentDigest -Path $two)
        (Get-CIGlobAuditContentDigest -Path $one) | Should -Be (Get-CIGlobAuditContentDigest -Path $one)
        (Get-CIGlobAuditContentDigest -Path (Join-Path $dir 'absent.Tests.ps1')) | Should -Be 'missing'
    }
}

Describe 'Shard assignment' {

    It 'covers every suite exactly once and is stable across calls' {
        $names = 1..17 | ForEach-Object { "s$_.Tests.ps1" }
        $a = Get-CIGlobAuditShardAssignment -Names $names -ShardCount 5
        $b = Get-CIGlobAuditShardAssignment -Names $names -ShardCount 5
        $a.Count | Should -Be 17
        $a | Should -Be $b
        (0..4 | ForEach-Object { $s = $_; @($a | Where-Object { $_ -eq $s }).Count } | Measure-Object -Sum).Sum | Should -Be 17
    }

    It 'spreads neighbours across shards rather than giving one shard a contiguous block' {
        $names = 1..8 | ForEach-Object { "s$_.Tests.ps1" }
        $a = Get-CIGlobAuditShardAssignment -Names $names -ShardCount 4
        $a[0] | Should -Not -Be $a[1] -Because 'a cluster of non-returning suites must not land in one job'
        $a[0] | Should -Be $a[4]
    }

    It 'handles an empty population without throwing' {
        (Get-CIGlobAuditShardAssignment -Names @() -ShardCount 3).Count | Should -Be 0
    }
}

Describe 'Classifier: four terminal states, driven to each' {

    It 'reports did-not-complete when the child did not return, EVEN IF the counts would read as a pass' {
        # The discriminating case. A killed process can leave a stale result file
        # from an earlier attempt, or counts that look clean; reading them is how
        # a hang becomes a green row.
        $r = ConvertTo-CIGlobAuditState -Completed $false -HasResult $true -Passed 40 -Failed 0
        $r.State | Should -Be 'did-not-complete'
        $r.Reason | Should -Be 'bound-exceeded'
    }

    It 'reports failed when the child completed but wrote no result — "nothing to read" is never "nothing wrong"' {
        $r = ConvertTo-CIGlobAuditState -Completed $true -ExitCode 2 -HasResult $false
        $r.State | Should -Be 'failed'
        $r.Reason | Should -Be 'no-result-file'
    }

    It 'reports failed when the exit code disagrees with the counts' {
        $r = ConvertTo-CIGlobAuditState -Completed $true -ExitCode 3 -HasResult $true -Passed 5 -Failed 0
        $r.State | Should -Be 'failed'
        $r.Reason | Should -Match 'exit-code-inconsistent'
    }

    It 'reports failed for a discovery-time throw, which produces a failed container and no failed test' {
        $r = ConvertTo-CIGlobAuditState -Completed $true -ExitCode 1 -HasResult $true -ContainerFailed 1
        $r.State | Should -Be 'failed'
        $r.Reason | Should -Be 'container-failure'
    }

    It 'reports passed only when a test actually EXECUTED' {
        (ConvertTo-CIGlobAuditState -Completed $true -ExitCode 0 -HasResult $true -Passed 1).State | Should -Be 'passed'
        # Same exit code, same zero failure count — the pair a naive runner reads
        # as green — but nothing ran.
        (ConvertTo-CIGlobAuditState -Completed $true -ExitCode 0 -HasResult $true -Passed 0).State | Should -Not -Be 'passed'
    }

    It 'keeps a partly-skipped run a pass, while retaining the discovered count that makes the skipping visible' {
        $r = ConvertTo-CIGlobAuditState -Completed $true -ExitCode 0 -HasResult $true -Passed 1 -Skipped 9
        $r.State | Should -Be 'passed'
        $r.Executed | Should -Be 1
        $r.Discovered | Should -Be 10 -Because 'a suite that passed one test and skipped nine must not read as clean green'
    }

    It 'separates the two shapes of executed-no-tests, which the existing sharded runner gets wrong in opposite directions' {
        (ConvertTo-CIGlobAuditState -Completed $true -ExitCode 0 -HasResult $true).Reason | Should -Be 'no-tests-discovered'
        $allSkipped = ConvertTo-CIGlobAuditState -Completed $true -ExitCode 0 -HasResult $true -Skipped 4
        $allSkipped.State | Should -Be 'executed-no-tests'
        $allSkipped.Reason | Should -Be 'all-skipped'
    }

    It 'never reports executed-no-tests for a run that also failed' {
        (ConvertTo-CIGlobAuditState -Completed $true -ExitCode 1 -HasResult $true -Failed 1 -Skipped 3).State | Should -Be 'failed'
    }
}

Describe 'Detail: what a non-passed row carries instead of a count' {

    It 'prefers structured failure messages over captured output' {
        $d = Get-CIGlobAuditDetail -State 'failed' -Failures @(
            [PSCustomObject]@{ name = 'Describe.It'; message = 'Expected 2, but got 3' }
        ) -StdOut 'lots of noise'
        $d | Should -Match 'Expected 2, but got 3'
        $d | Should -Not -Match 'lots of noise'
    }

    It 'falls back to the TAIL of captured output, because the last thing a hung suite printed is where it stopped' {
        $text = (1..500 | ForEach-Object { "line $_" }) -join "`n"
        $d = Get-CIGlobAuditDetail -State 'did-not-complete' -StdOut $text -TailChars 60
        $d | Should -Match 'line 500'
        $d | Should -Not -Match 'line 1\b'
    }

    It 'returns an honest empty when there is genuinely nothing to capture' {
        Get-CIGlobAuditDetail -State 'did-not-complete' -StdOut '' -StdErr '' | Should -BeExactly ''
    }

    It 'carries skip reasons on an executed-no-tests row, which is what tells a reader it is platform-guarded' {
        $d = Get-CIGlobAuditDetail -State 'executed-no-tests' -Skips @(
            [PSCustomObject]@{ name = 'Describe.It'; message = 'skipped on non-Windows' }
        )
        $d | Should -Match 'skipped on non-Windows'
    }

    It 'does not put skip noise on a failed row, where the failure is what classifies' {
        $d = Get-CIGlobAuditDetail -State 'failed' -Failures @([PSCustomObject]@{ name = 'a'; message = 'boom' }) `
            -Skips @([PSCustomObject]@{ name = 'b'; message = 'skipped' })
        $d | Should -Not -Match 'skipped'
    }
}

Describe 'Reachability: is a non-returning suite reachable by a documented way of running these tests?' {

    BeforeAll {
        $script:Root = Join-Path $script:Scratch 'reach-root'
        New-Item -ItemType Directory -Force -Path (Join-Path $script:Root 'sub') | Out-Null
    }

    It 'is clean when the only stalled suite lives outside the tests root' {
        $rows = @(script:New-Row -Name 'ctl.Tests.ps1' -State 'did-not-complete' -InPopulation $false `
                -Path (Join-Path $script:Scratch 'elsewhere/ctl.Tests.ps1'))
        (Get-CIGlobAuditReachability -Rows $rows -SelectedNames @('x.Tests.ps1') -TestsRoot $script:Root).Clean | Should -BeTrue
    }

    It 'is NOT clean when a stalled suite sits in a SUBDIRECTORY of the tests root, even though the gate never selects it' {
        # The load-bearing case. The gate's enumeration is non-recursive, so this
        # reads safe from the gate — and the contributor instructions and the
        # pull-request template both prescribe a recursive, quarantine-blind
        # `Invoke-Pester` over that root.
        $rows = @(script:New-Row -Name 'hangs.Tests.ps1' -State 'did-not-complete' `
                -Path (Join-Path $script:Root 'sub/hangs.Tests.ps1'))
        $r = Get-CIGlobAuditReachability -Rows $rows -SelectedNames @('other.Tests.ps1') -TestsRoot $script:Root
        $r.Clean | Should -BeFalse
        $r.TestsRootReachable | Should -Contain 'hangs.Tests.ps1'
        $r.GateReachable | Should -BeNullOrEmpty -Because 'the gate arm alone would have called this safe'
    }

    It 'is NOT clean when a stalled suite is in the gate''s selection' {
        $rows = @(script:New-Row -Name 'sel.Tests.ps1' -State 'did-not-complete' -Path (Join-Path $script:Root 'sel.Tests.ps1'))
        (Get-CIGlobAuditReachability -Rows $rows -SelectedNames @('sel.Tests.ps1') -TestsRoot $script:Root).GateReachable |
            Should -Contain 'sel.Tests.ps1'
    }

    It 'ignores rows that are not did-not-complete' {
        $rows = @(script:New-Row -Name 'red.Tests.ps1' -State 'failed' -Path (Join-Path $script:Root 'red.Tests.ps1'))
        (Get-CIGlobAuditReachability -Rows $rows -SelectedNames @('red.Tests.ps1') -TestsRoot $script:Root).Clean | Should -BeTrue
    }
}

Describe 'Gate agreement' {

    It 'compares only the overlap, and calls a non-passed gate-selected suite a disagreement' {
        $rows = @(
            script:New-Row -Name 'sel1.Tests.ps1' -State 'passed'
            script:New-Row -Name 'sel2.Tests.ps1' -State 'failed'
            script:New-Row -Name 'quar.Tests.ps1' -State 'failed'
        )
        $a = Get-CIGlobAuditGateAgreement -Rows $rows -SelectedNames @('sel1.Tests.ps1', 'sel2.Tests.ps1')
        $a.OverlapCount | Should -Be 2
        $a.AgreeCount | Should -Be 1
        @($a.Disagreements).Name | Should -Be @('sel2.Tests.ps1')
        @($a.Disagreements).Name | Should -Not -Contain 'quar.Tests.ps1' -Because 'a quarantined suite failing is the expected finding, not a parity disagreement'
    }
}

Describe 'Environment statement and instrument basis' {

    It 'refuses to render a statement with an unobserved dimension' {
        $facts = script:New-FactSet
        $facts.Remove('PesterVersion')
        { Get-CIGlobAuditEnvironmentStatement -Facts $facts } | Should -Throw -ExpectedMessage '*PesterVersion*'
    }

    It 'never claims parity on the process model or concurrency, which are structurally divergent' {
        $rows = Get-CIGlobAuditEnvironmentStatement -Facts (script:New-FactSet)
        ($rows | Where-Object { $_.Dimension -eq 'process model' }).Agrees | Should -BeFalse
        ($rows | Where-Object { $_.Dimension -eq 'concurrency' }).Agrees | Should -BeFalse
    }

    It 'computes token agreement from the observed fact, not from the prose that describes it' {
        # The prose could say anything; a table that decides agreement by
        # pattern-matching it is a table reporting agreement it never checked.
        $lying = script:New-FactSet @{ HasToken = $true; TokenAvailability = 'observed: no token at all, honest' }
        ((Get-CIGlobAuditEnvironmentStatement -Facts $lying) | Where-Object { $_.Dimension -match 'token' }).Agrees |
            Should -BeFalse
    }

    It 'flags a divergence when the audit''s checkout is not shallow like the gate''s' {
        $deep = script:New-FactSet @{ IsShallow = $false; CheckoutDepth = 'observed: full clone, 4000 commit(s) reachable' }
        ((Get-CIGlobAuditEnvironmentStatement -Facts $deep) | Where-Object { $_.Dimension -eq 'checkout depth' }).Agrees |
            Should -BeFalse
    }

    It 'changes the instrument basis when the bound changes' {
        $env1 = Get-CIGlobAuditEnvironmentStatement -Facts (script:New-FactSet)
        (Get-CIGlobAuditInstrumentBasis -EnvironmentStatement $env1 -BoundSeconds 300) |
            Should -Not -Be (Get-CIGlobAuditInstrumentBasis -EnvironmentStatement $env1 -BoundSeconds 1200)
    }

    It 'changes the instrument basis when a module version drifts inside the gate''s own window' {
        $a = Get-CIGlobAuditEnvironmentStatement -Facts (script:New-FactSet)
        $b = Get-CIGlobAuditEnvironmentStatement -Facts (script:New-FactSet @{ PesterVersion = '6.0.2' })
        (Get-CIGlobAuditInstrumentBasis -EnvironmentStatement $a -BoundSeconds 300) |
            Should -Not -Be (Get-CIGlobAuditInstrumentBasis -EnvironmentStatement $b -BoundSeconds 300)
    }

    It 'is stable when nothing changed' {
        $a = Get-CIGlobAuditEnvironmentStatement -Facts (script:New-FactSet)
        $b = Get-CIGlobAuditEnvironmentStatement -Facts (script:New-FactSet)
        (Get-CIGlobAuditInstrumentBasis -EnvironmentStatement $a -BoundSeconds 300) |
            Should -Be (Get-CIGlobAuditInstrumentBasis -EnvironmentStatement $b -BoundSeconds 300)
    }
}

Describe 'Observation history: what "two observations of the same thing" means' {

    BeforeAll { $script:Marker = '<!-- ci-glob-audit-history -->' }

    It 'starts a suite at one observation and increments it on an identical rerun' {
        $rows = @(script:New-Row -Name 'a.Tests.ps1' -Digest 'd1')
        $first = Update-CIGlobAuditHistory -Rows $rows -InstrumentBasis 'i1' -RunId 'r1' -Marker $script:Marker
        $first.Entries[0].Observations | Should -Be 1
        $second = Update-CIGlobAuditHistory -ExistingBody $first.Body -Rows $rows -InstrumentBasis 'i1' -RunId 'r2' -Marker $script:Marker
        $second.Entries[0].Observations | Should -Be 2
        $second.Entries[0].LastRun | Should -Be 'r2'
    }

    It 'RESETS the count when the suite''s content changed — a name key would have said two' {
        $first = Update-CIGlobAuditHistory -Rows @(script:New-Row -Name 'a.Tests.ps1' -Digest 'd1') `
            -InstrumentBasis 'i1' -RunId 'r1' -Marker $script:Marker
        $second = Update-CIGlobAuditHistory -ExistingBody $first.Body -Rows @(script:New-Row -Name 'a.Tests.ps1' -Digest 'd2') `
            -InstrumentBasis 'i1' -RunId 'r2' -Marker $script:Marker
        $second.Entries[0].Observations | Should -Be 1
        $second.Entries[0].PriorBasis | Should -Be 'd1+i1'
    }

    It 'RESETS the count when the INSTRUMENT changed, which is the axis B3 originally did not name' {
        $first = Update-CIGlobAuditHistory -Rows @(script:New-Row -Name 'a.Tests.ps1' -Digest 'd1') `
            -InstrumentBasis 'bound-300' -RunId 'r1' -Marker $script:Marker
        $second = Update-CIGlobAuditHistory -ExistingBody $first.Body -Rows @(script:New-Row -Name 'a.Tests.ps1' -Digest 'd1') `
            -InstrumentBasis 'bound-1200' -RunId 'r2' -Marker $script:Marker
        $second.Entries[0].Observations | Should -Be 1 -Because 'a did-not-complete at one bound and a pass at four times it are not two observations of one thing'
    }

    It 'keeps the row for a suite this run did not see, so the history outlives the runs' {
        $first = Update-CIGlobAuditHistory -Rows @(script:New-Row -Name 'gone.Tests.ps1' -Digest 'd1') `
            -InstrumentBasis 'i1' -RunId 'r1' -Marker $script:Marker
        $second = Update-CIGlobAuditHistory -ExistingBody $first.Body -Rows @(script:New-Row -Name 'new.Tests.ps1' -Digest 'd2') `
            -InstrumentBasis 'i1' -RunId 'r2' -Marker $script:Marker
        @($second.Entries).Name | Should -Contain 'gone.Tests.ps1'
        ($second.Entries | Where-Object { $_.Name -eq 'gone.Tests.ps1' }).LastRun | Should -Be 'r1'
    }

    It 'writes a body it can read back — a record that cannot be reparsed is not a history' {
        $rows = @(script:New-Row -Name 'a.Tests.ps1' -Digest 'd1'; script:New-Row -Name 'b.Tests.ps1' -Digest 'd2' -State 'failed')
        $first = Update-CIGlobAuditHistory -Rows $rows -InstrumentBasis 'i1' -RunId 'r1' -Marker $script:Marker
        $second = Update-CIGlobAuditHistory -ExistingBody $first.Body -Rows $rows -InstrumentBasis 'i1' -RunId 'r2' -Marker $script:Marker
        @($second.Entries).Count | Should -Be 2
        ($second.Entries | Where-Object { $_.Name -eq 'b.Tests.ps1' }).Observations | Should -Be 2
        ($second.Entries | Where-Object { $_.Name -eq 'b.Tests.ps1' }).LastState | Should -Be 'failed'
    }

    It 'puts the marker on line one, so the upsert selector can reach it' {
        $h = Update-CIGlobAuditHistory -Rows @(script:New-Row -Name 'a.Tests.ps1') -InstrumentBasis 'i1' -RunId 'r1' -Marker $script:Marker
        ($h.Body -split "`r?`n")[0] | Should -BeExactly $script:Marker
    }
}

Describe 'Record composition' {

    BeforeAll {
        $script:Env = Get-CIGlobAuditEnvironmentStatement -Facts (script:New-FactSet)
        $script:Reach = [PSCustomObject]@{ Clean = $true; GateReachable = @(); TestsRootReachable = @(); StalledCount = 0 }
        $script:Agree = [PSCustomObject]@{ OverlapCount = 1; AgreeCount = 1; Disagreements = @(); GateExpectation = 'all pass' }
        $script:Controls = @([PSCustomObject]@{ Name = 'passes.Control.Tests.ps1'; Expected = 'passed'; Observed = 'passed'; Ok = $true })
    }

    It 'puts the marker on line one of the summary' {
        $docs = New-CIGlobAuditRecordDocuments -RunContext (script:New-RunContext) `
            -Rows @(script:New-Row -Name 'a.Tests.ps1') -EnvironmentStatement $script:Env `
            -Population (script:New-PopulationView -Names @('a.Tests.ps1')) `
            -GateAgreement $script:Agree -Reachability $script:Reach -ControlCheck $script:Controls
        ($docs[0].Body -split "`r?`n")[0] | Should -BeExactly '<!-- ci-glob-audit-record-12345 -->'
    }

    It 'reports a one-to-one mismatch rather than letting a missing row pass silently' {
        $docs = New-CIGlobAuditRecordDocuments -RunContext (script:New-RunContext) `
            -Rows @(script:New-Row -Name 'a.Tests.ps1') -EnvironmentStatement $script:Env `
            -Population (script:New-PopulationView -Names @('a.Tests.ps1', 'b.Tests.ps1')) `
            -GateAgreement $script:Agree -Reachability $script:Reach -ControlCheck $script:Controls
        $docs[0].Body | Should -Match 'missing 1'
        $docs[0].Body | Should -Match 'MISSING: b\.Tests\.ps1'
    }

    It 'names out-of-population rows as such, so no consumer reads a control as a measurement' {
        $rows = @(
            script:New-Row -Name 'a.Tests.ps1'
            script:New-Row -Name 'ctl.Tests.ps1' -InPopulation $false -ControlRole 'expects passed' -Path '/x/ctl.Tests.ps1'
        )
        $docs = New-CIGlobAuditRecordDocuments -RunContext (script:New-RunContext) -Rows $rows `
            -EnvironmentStatement $script:Env -Population (script:New-PopulationView -Names @('a.Tests.ps1')) `
            -GateAgreement $script:Agree -Reachability $script:Reach -ControlCheck $script:Controls
        $docs[0].Body | Should -Match 'Out-of-population rows'
        $docs[0].Body | Should -Match 'ctl\.Tests\.ps1.*expects passed'
    }

    It 'spills detail into further documents rather than truncating it, and every document stays under the cap' {
        # 60 failing rows each carrying 1,200 characters of message: about 72,000
        # codepoints of detail, comfortably past a single comment.
        $rows = 1..60 | ForEach-Object {
            script:New-Row -Name "f$_.Tests.ps1" -State 'failed' -Reason 'test-failures' -Detail ('x' * 1200)
        }
        $docs = New-CIGlobAuditRecordDocuments -RunContext (script:New-RunContext) -Rows @($rows) `
            -EnvironmentStatement $script:Env -Population (script:New-PopulationView -Names @($rows.Name)) `
            -GateAgreement $script:Agree -Reachability $script:Reach -ControlCheck $script:Controls
        @($docs | Where-Object { $_.Kind -eq 'detail' }).Count | Should -BeGreaterThan 1
        foreach ($d in $docs) { (Measure-CIGlobAuditBody -Body $d.Body) | Should -BeLessOrEqual 65536 }
        # And the detail is not silently gone: every failing suite appears.
        $allDetail = ($docs | Where-Object { $_.Kind -eq 'detail' } | ForEach-Object { $_.Body }) -join "`n"
        foreach ($n in @('f1.Tests.ps1', 'f30.Tests.ps1', 'f60.Tests.ps1')) { $allDetail | Should -Match ([regex]::Escape($n)) }
    }

    It 'renders an empty-detail row as an explicit nothing-emitted statement, not as a blank' {
        $rows = @(script:New-Row -Name 'silent.Tests.ps1' -State 'did-not-complete' -Reason 'bound-exceeded' -Detail '')
        $docs = New-CIGlobAuditRecordDocuments -RunContext (script:New-RunContext) -Rows $rows `
            -EnvironmentStatement $script:Env -Population (script:New-PopulationView -Names @('silent.Tests.ps1')) `
            -GateAgreement $script:Agree -Reachability $script:Reach -ControlCheck $script:Controls
        (($docs | Where-Object { $_.Kind -eq 'detail' }).Body) | Should -Match 'Nothing was emitted before the kill'
        (($docs | Where-Object { $_.Kind -eq 'detail' }).Body) | Should -Match 'cannot classify'
    }

    It 'refuses loudly when even the summary table cannot fit, rather than writing a body GitHub will reject' {
        $rows = 1..3 | ForEach-Object { script:New-Row -Name "s$_.Tests.ps1" }
        {
            New-CIGlobAuditRecordDocuments -RunContext (script:New-RunContext) -Rows @($rows) `
                -EnvironmentStatement $script:Env -Population (script:New-PopulationView -Names @($rows.Name)) `
                -GateAgreement $script:Agree -Reachability $script:Reach -ControlCheck $script:Controls `
                -BodyCap 200
        } | Should -Throw -ExpectedMessage '*over the 200 cap*'
    }

    It 'says so in the record when a bounded suite''s process survived its kill' {
        $rows = @(script:New-Row -Name 'zombie.Tests.ps1' -State 'did-not-complete' -SurvivedKill $true -Detail 'tail')
        $docs = New-CIGlobAuditRecordDocuments -RunContext (script:New-RunContext) -Rows $rows `
            -EnvironmentStatement $script:Env -Population (script:New-PopulationView -Names @('zombie.Tests.ps1')) `
            -GateAgreement $script:Agree -Reachability $script:Reach -ControlCheck $script:Controls
        $docs[0].Body | Should -Match 'survived the kill: \*\*1\*\*'
        $docs[0].Body | Should -Match 'NOT offered as a timing measurement'
    }

    It 'counts codepoints, not UTF-16 code units, so an emoji in a failure message cannot fake an overflow' {
        $astral = [string]::new([char[]]@(0xD83D, 0xDE00))  # one emoji, two code units
        $astral.Length | Should -Be 2
        Measure-CIGlobAuditBody -Body $astral | Should -Be 1
    }
}

Describe 'Control expectations: the instrument''s self-test' {

    It 'flags a control that produced the wrong terminal state' {
        $check = Test-CIGlobAuditControlExpectation -Rows @(script:New-Row -Name 'c.Tests.ps1' -State 'passed') `
            -Expectations @{ 'c.Tests.ps1' = 'did-not-complete' }
        $check[0].Ok | Should -BeFalse
    }

    It 'flags a control with no row at all, rather than reading absence as agreement' {
        $check = Test-CIGlobAuditControlExpectation -Rows @() -Expectations @{ 'c.Tests.ps1' = 'passed' }
        $check[0].Ok | Should -BeFalse
        $check[0].Observed | Should -Be '(no row)'
    }

    It 'passes a control that matched' {
        $check = Test-CIGlobAuditControlExpectation -Rows @(script:New-Row -Name 'c.Tests.ps1' -State 'passed') `
            -Expectations @{ 'c.Tests.ps1' = 'passed' }
        $check[0].Ok | Should -BeTrue
    }
}

Describe 'End to end: the shipped controls through the shipped execution path' {

    It 'classifies the passing control as passed, with a real executed test behind it' {
        $row = script:Invoke-Control -FileName 'passes.Control.Tests.ps1'
        $row.State | Should -Be 'passed'
        $row.Executed | Should -BeGreaterThan 0
        $row.Completed | Should -BeTrue
    }

    It 'classifies the failing control as failed AND carries its message into the detail' {
        $row = script:Invoke-Control -FileName 'fails.Control.Tests.ps1'
        $row.State | Should -Be 'failed'
        $row.Detail | Should -Not -BeNullOrEmpty
        $row.Detail | Should -Match 'ci-glob-audit-control-expected' -Because 'a row carrying only counts is the defect this audit exists to fix'
        $row.Detail | Should -Match 'ci-glob-audit-control-observed'
    }

    It 'classifies a file with no tests as executed-no-tests, not as a pass' {
        $row = script:Invoke-Control -FileName 'zero-discovery.Control.Tests.ps1'
        $row.State | Should -Be 'executed-no-tests'
        $row.Reason | Should -Be 'no-tests-discovered'
    }

    It 'classifies an all-skipped suite as executed-no-tests, not as a pass' {
        $row = script:Invoke-Control -FileName 'all-skipped.Control.Tests.ps1'
        $row.State | Should -Be 'executed-no-tests'
        $row.Reason | Should -Be 'all-skipped'
        $row.Skipped | Should -BeGreaterThan 0
    }

    It 'bounds a suite that never returns, and records it as did-not-complete rather than hanging the run' {
        # The one property no in-process assertion can establish. Armed through
        # the same per-suite environment override the audit uses.
        $row = script:Invoke-Control -FileName 'never-returns.Control.Tests.ps1' -Bound 5 -Env @{ CI_GLOB_AUDIT_CONTROLS = '1' }
        $row.State | Should -Be 'did-not-complete'
        $row.Completed | Should -BeFalse
        $row.ElapsedMs | Should -BeGreaterOrEqual 5000
        $row.KillEscalated | Should -BeTrue
        $row.ProcessSurvivedKill | Should -BeFalse -Because 'a surviving orphan contaminates every later row''s duration on the same runner'
    }

    It 'leaves the non-returning control harmless when it is not armed' {
        # The second interlock. Unarmed it skips, which is a visible state — not
        # a silent pass, and not a hang on a contributor's machine.
        $row = script:Invoke-Control -FileName 'never-returns.Control.Tests.ps1' -Bound 60
        $row.State | Should -Be 'executed-no-tests'
        $row.Completed | Should -BeTrue
    }
}
