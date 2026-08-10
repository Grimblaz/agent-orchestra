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

    A THIRD RULE, learned the expensive way on this file. A fixture built from
    the same understanding as the code agrees with the code for the same wrong
    reason. Two tests here previously passed for exactly that: the reachability
    test built BOTH sides of a path comparison from an absolute scratch path, a
    shape the pipeline never produces, while every real row is relative; and
    the codepoint test used a lone astral character, the one input where a
    grapheme cluster and a codepoint agree. Fixtures below use the shape the
    SHIPPED path produces, and where a measure has several plausible units the
    exhibit is chosen to separate them.
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
            Concurrency           = 'one suite process at a time within this job; 8 job(s) in parallel'
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

    # The row shape the SHIPPED path produces, defaults included: a RELATIVE
    # path built the way Prepare builds it, and the detail-provenance fields
    # `Invoke-CIGlobAuditSuite` stamps. A fixture missing either is what let
    # two defects here read green.
    function script:New-Row {
        param(
            [string]$Name, [string]$State = 'passed', [string]$Reason = 'tests-executed-and-passed',
            [bool]$InPopulation = $true, [string]$Detail = 'detail', [string]$Digest = 'aaaaaaaaaaaa',
            [string]$Path = '', [int]$ElapsedMs = 100, [object]$Class = $null, [string]$ControlRole = '',
            [bool]$SurvivedKill = $false, [int]$Skipped = 0, [int]$Executed = 1,
            [string]$DetailSource = 'structured', [bool]$DescendantHeldOutput = $false,
            [bool]$SelfModified = $false, [int]$DrainMs = 0
        )
        if (-not $Path) { $Path = '.github/scripts/Tests/' + $Name }
        return [PSCustomObject]@{
            Name = $Name; State = $State; Reason = $Reason; InPopulation = $InPopulation
            Detail = $Detail; ContentDigest = $Digest; Path = $Path; ElapsedMs = $ElapsedMs
            DrainMs = $DrainMs; SuiteMs = ($ElapsedMs - $DrainMs)
            BoundSeconds = 300; QuarantineClass = $Class; ControlRole = $ControlRole
            ProcessSurvivedKill = $SurvivedKill; Skipped = $Skipped; Executed = $Executed
            DetailSource = $DetailSource
            DetailTruncateFrom = $(if ($DetailSource -eq 'console-tail') { 'Tail' } else { 'Head' })
            DescendantHeldOutput = $DescendantHeldOutput
            SelfModified = $SelfModified
        }
    }

    function script:New-RunContext {
        param([hashtable]$Override = @{})
        $ctx = @{
            RunId = '12345'; RunUrl = 'https://example/runs/12345'; RunAttempt = '1'
            TriggerEvent = 'workflow_dispatch'; Commit = 'abcdef1'; Ref = 'refs/heads/main'
            DefaultBranch = 'main'; DefaultBranchTip = 'abcdef1'; AncestryCheck = 'same commit'
            ContentDifferences = 'none'; BoundSeconds = 300; ShardCount = 8
            InstrumentBasis = 'abc123'; StartedAt = '2026-01-01T00:00:00Z'
            RecordFormatVersion = 2
        }
        foreach ($k in $Override.Keys) { $ctx[$k] = $Override[$k] }
        return $ctx
    }

    function script:New-PopulationView {
        param([string[]]$Names)
        return [PSCustomObject]@{
            Names = $Names; SelectedCount = 1; QuarantinedCount = 1; UnclassifiedCount = 1
            StaleQuarantine = @(); HasDrift = $false; DerivationCommand = 'fixture'
        }
    }

    function script:New-InPopulationMap {
        param([object[]]$Rows)
        $m = @{}
        foreach ($r in $Rows) { $m[[string]$r.Name] = [bool]$r.InPopulation }
        return $m
    }

    function script:Invoke-Compose {
        param([object[]]$Rows, [string[]]$Names, [hashtable]$Extra = @{})
        $splat = @{
            RunContext           = (script:New-RunContext)
            Rows                 = @($Rows)
            EnvironmentStatement = $script:Env
            Population           = (script:New-PopulationView -Names $Names)
            GateAgreement        = $script:Agree
            Reachability         = $script:Reach
            ControlCheck         = $script:Controls
        }
        foreach ($k in $Extra.Keys) { $splat[$k] = $Extra[$k] }
        # Emitted one document at a time. The composer comma-wraps its return
        # so an assignment gets the array intact; re-emitting that wrapper from
        # here would hand a PIPELINE a single array object, and
        # `$_.Kind -eq 'detail'` against an array of kinds is truthy — a test
        # that then asserts against every document at once.
        $documents = New-CIGlobAuditRecordDocuments @splat
        return @($documents)
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

    # The bounded row, produced ON DEMAND and at most once per container.
    #
    # Two tests need a row from a suite that never returns, and that row costs
    # the bound in wall clock. Having the second read a variable the first
    # happened to leave behind made it depend on the first having run — which
    # `-Filter`, a re-ordering, or a parallel container all break, and a test
    # that cannot be run alone is not a test of anything on its own. Memoising
    # here makes each caller self-sufficient without buying a second hang: the
    # first to run pays, either can run alone, and neither can silently read a
    # row the other did not produce.
    $script:StalledRowCache = $null
    function script:Get-StalledRow {
        param([int]$Bound = 6)
        if ($null -eq $script:StalledRowCache) {
            $script:StalledRowCache = script:Invoke-Control -FileName 'never-returns.Control.Tests.ps1' `
                -Bound $Bound -Env @{ CI_GLOB_AUDIT_CONTROLS = '1' }
        }
        return $script:StalledRowCache
    }

    # How many UTF-16 surrogates in this text are not half of a pair. Any
    # non-zero answer is a cut that landed inside a character, which becomes
    # U+FFFD the moment the text is written to a UTF-8 artifact.
    function script:Get-LoneSurrogateCount {
        param([AllowEmptyString()][string]$Text)
        $lone = 0
        for ($i = 0; $i -lt $Text.Length; $i++) {
            $c = $Text[$i]
            if ([char]::IsHighSurrogate($c)) {
                if ($i -eq ($Text.Length - 1) -or -not [char]::IsLowSurrogate($Text[$i + 1])) { $lone++ }
                else { $i++ }
            }
            elseif ([char]::IsLowSurrogate($c)) { $lone++ }
        }
        return $lone
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
        # A fail-closed predicate whose caller could carry on regardless would
        # be a fail-open writer, so there is deliberately no -AllowDrift switch.
        { Get-CIGlobAuditPopulation -TestsRoot $t.Dir -QuarantinePath $t.QuarantinePath } |
            Should -Throw -ExpectedMessage '*drifted registry*'
    }

    It 'justifies the refusal by the registry''s fitness, NOT by a false claim about the arithmetic' {
        # The set identity `Selected + (Quarantined - Stale)` holds
        # unconditionally by construction — the stale subtraction handles the
        # one drift cause that touches it. A message claiming the derivation is
        # only exact under no-drift says something untrue about why the run is
        # refusing, on the one surface a maintainer reads when it fires.
        $t = script:New-FixtureTree -Files @('a.Tests.ps1') -Quarantine @(
            [ordered]@{ file = 'gone.Tests.ps1'; class = 'unclassified'; reason = 'deleted'; issue = $null }
        )
        $message = ''
        try { Get-CIGlobAuditPopulation -TestsRoot $t.Dir -QuarantinePath $t.QuarantinePath }
        catch { $message = [string]$_.Exception.Message }
        $message | Should -Match 'holds unconditionally'
        $message | Should -Match 'lint-clean'
        $message | Should -Not -Match 'equals the on-disk set only while'
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
        $d.Text | Should -Match 'Expected 2, but got 3'
        $d.Text | Should -Not -Match 'lots of noise'
        $d.Source | Should -Be 'structured'
    }

    It 'falls back to the TAIL of captured output, because the last thing a hung suite printed is where it stopped' {
        $text = (1..500 | ForEach-Object { "line $_" }) -join "`n"
        $d = Get-CIGlobAuditDetail -State 'did-not-complete' -StdOut $text -TailChars 60
        $d.Text | Should -Match 'line 500'
        $d.Text | Should -Not -Match 'line 1\b'
        $d.Source | Should -Be 'console-tail'
    }

    It 'declares which END of the detail must survive truncation, per row' {
        # The composer cannot pick one end for everything: a structured join
        # classifies from its FIRST message, and a console tail from its LAST
        # line. Both populations are real and they want opposite answers.
        (Get-CIGlobAuditDetail -State 'failed' -Failures @([PSCustomObject]@{ name = 'a'; message = 'boom' })).TruncateFrom |
            Should -Be 'Head'
        (Get-CIGlobAuditDetail -State 'failed' -Reason 'no-result-file' -StdOut 'crash output').TruncateFrom |
            Should -Be 'Tail' -Because 'a `failed / no-result-file` row''s detail is a console tail, so a state-only rule gets it backwards'
    }

    It 'names the state and reason above a console tail, so an untitled block of text is not all a reader gets' {
        $d = Get-CIGlobAuditDetail -State 'did-not-complete' -Reason 'bound-exceeded' -StdOut 'still going'
        $d.Text | Should -Match 'bound-exceeded' -Because 'the reason parameter was declared and never used, which invited a caller to believe it influenced the detail'
    }

    It 'returns an honest empty when there is genuinely nothing to capture' {
        $d = Get-CIGlobAuditDetail -State 'did-not-complete' -StdOut '' -StdErr ''
        $d.Text | Should -BeExactly ''
        $d.Source | Should -Be 'none'
    }

    It 'keeps two failure lines that differ only in case, which a case-insensitive unique collapses' {
        # `Select-Object -Unique` was case-INSENSITIVE by default before
        # PowerShell 7.4 and is case-sensitive after, so the shipped behaviour
        # depended on the runner's patch version — which is not a property to
        # leave to the image. The comparer here is stated outright.
        $d = Get-CIGlobAuditDetail -State 'failed' -Failures @(
            [PSCustomObject]@{ name = 'a'; message = 'Cannot find PATH' }
            [PSCustomObject]@{ name = 'a'; message = 'cannot find path' }
        )
        @($d.Text -split "`n").Count | Should -Be 2 -Because 'silent loss inside the one field R5 governs'
    }

    It 'carries skip reasons on an executed-no-tests row, which is what tells a reader it is platform-guarded' {
        $d = Get-CIGlobAuditDetail -State 'executed-no-tests' -Skips @(
            [PSCustomObject]@{ name = 'Describe.It'; message = 'skipped on non-Windows' }
        )
        $d.Text | Should -Match 'skipped on non-Windows'
    }

    It 'does not put skip noise on a failed row, where the failure is what classifies' {
        $d = Get-CIGlobAuditDetail -State 'failed' -Failures @([PSCustomObject]@{ name = 'a'; message = 'boom' }) `
            -Skips @([PSCustomObject]@{ name = 'b'; message = 'skipped' })
        $d.Text | Should -Not -Match 'skipped'
    }

    It 'never cuts a console tail through the middle of a surrogate pair' {
        $emoji = [string]::new([char[]]@(0xD83D, 0xDE00))
        $text = ('a' * 200) + ($emoji * 50)
        $d = Get-CIGlobAuditDetail -State 'did-not-complete' -StdOut $text -TailChars 61
        # Every surrogate must be half of a PAIR. The loop that used to stand
        # here had an empty body and asserted nothing at all — scaffolding left
        # in a file whose own docstring is about fixtures that agree with the
        # code.
        script:Get-LoneSurrogateCount -Text $d.Text |
            Should -Be 0 -Because 'a lone surrogate is the corruption this cut exists to avoid'
        $d.Text | Should -Not -Match "$([char]0xFFFD)"
        # The real discriminator: round-trip through UTF-8, which is what a
        # lone surrogate cannot survive.
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($d.Text)
        [System.Text.Encoding]::UTF8.GetString($bytes) | Should -BeExactly $d.Text
    }
}

Describe 'Text hygiene: what leaves an unaudited suite and reaches a permanent public surface' {

    It 'redacts every credential shape a suite could print, visibly rather than silently' {
        $text = @(
            'http.https://github.com/.extraheader=AUTHORIZATION: basic eHh4OmdocF9BQkNERUZH'
            'AUTHORIZATION: bearer ghs_0123456789abcdefghijABCDEFGHIJ'
            'token ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ012345 leaked'
            'pat github_pat_11ABCDEFG0abcdefghijkl_ABCDEFGHIJKLMNOPQRSTUVWXYZ'
        ) -join "`n"
        $safe = Protect-CIGlobAuditSecret -Text $text
        $safe | Should -Not -Match 'ghp_ABCDEFG'
        $safe | Should -Not -Match 'ghs_0123456'
        $safe | Should -Not -Match 'github_pat_11ABCDEFG'
        $safe | Should -Not -Match 'eHh4OmdocF9BQkNERUZH'
        $safe | Should -Match '\[REDACTED:' -Because 'a silent removal cannot be told from a suite that printed nothing'
    }

    It 'leaves ordinary failure text untouched, so redaction cannot quietly eat the classifying detail' {
        $text = 'Expected 2, but got 3 at /home/runner/work/repo/repo/x.Tests.ps1:14'
        Protect-CIGlobAuditSecret -Text $text | Should -BeExactly $text
    }

    It 'strips ANSI colour runs, which otherwise consume the per-row detail budget invisibly' {
        $coloured = "$([char]27)[95mDescribing x$([char]27)[0m ok"
        $plain = Remove-CIGlobAuditAnsi -Text $coloured
        $plain | Should -BeExactly 'Describing x ok'
        $plain | Should -Not -Match "$([char]27)"
    }

    It 'trims the live capture buffer without splitting a surrogate pair' {
        # The buffer is written verbatim to the `.log` artifact, and the trim is
        # at the HEAD — so a cut landing between the halves of a pair leaves a
        # lone LOW surrogate at position zero, which becomes U+FFFD as soon as
        # the artifact is encoded. This was the one cut site in the change that
        # was not made rune-safe while three siblings beside it were.
        $emoji = [string]::new([char[]]@(0xD83D, 0xDE00))
        # Every pair straddles an odd offset, so a cut at an odd count is
        # guaranteed to land inside one.
        $buf = [System.Text.StringBuilder]::new(($emoji * 40))
        [void](script:Limit-CIGlobAuditBuffer -Buffer $buf -MaxChars 41)

        $kept = $buf.ToString()
        $kept.Length | Should -BeLessOrEqual 41 -Because 'the cap is a memory bound and must still hold'
        script:Get-LoneSurrogateCount -Text $kept | Should -Be 0
        $kept | Should -Not -Match "$([char]0xFFFD)"
        # The discriminator a length check cannot give: a lone surrogate is
        # exactly what a UTF-8 round trip cannot survive.
        [System.Text.Encoding]::UTF8.GetString([System.Text.Encoding]::UTF8.GetBytes($kept)) | Should -BeExactly $kept
    }

    It 'keeps the TAIL when it trims, and leaves a buffer inside the cap alone' {
        # The negative half, twice: a trim that kept the head would discard the
        # stopping point that classifies a hung suite, and one that fired below
        # the cap would throw away output nothing asked it to.
        $buf = [System.Text.StringBuilder]::new('HEADSTART' + ('x' * 20) + 'TAILEND')
        [void](script:Limit-CIGlobAuditBuffer -Buffer $buf -MaxChars 10)
        $buf.ToString() | Should -BeExactly 'xxxTAILEND'

        $small = [System.Text.StringBuilder]::new('short')
        (script:Limit-CIGlobAuditBuffer -Buffer $small -MaxChars 100) | Should -Be 0
        $small.ToString() | Should -BeExactly 'short'
    }
}

Describe 'Capture artifacts: the `.log` files and the record must tell the same story' {

    It 'writes the result-parse-failure note into the artifact, not only into the record' {
        # That note IS the diagnosis on the one path where it fires, and it was
        # appended to `$stdErr` AFTER both `.log` files had been written — so a
        # reader who opened the artifact to find out what the harness observed
        # got a file that did not mention the only thing it observed.
        $dir = Join-Path $script:Scratch ('capture-' + [System.Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        $outPath = Join-Path $dir 'x.out.log'
        $errPath = Join-Path $dir 'x.err.log'
        $resultPath = Join-Path $dir 'x.result.json'
        Set-Content -LiteralPath $resultPath -Value '{ this is not json' -Encoding utf8

        $capture = script:Save-CIGlobAuditCapture -OutPath $outPath -ErrPath $errPath `
            -StdOut 'some output' -StdErr 'some error' -ResultPath $resultPath -Completed $true

        $capture.HasResult | Should -BeFalse -Because 'a malformed result file is not a result'
        $capture.StdErr | Should -Match 'result file did not parse'
        (Get-Content -LiteralPath $errPath -Raw) |
            Should -Match 'result file did not parse' -Because 'the artifact and the record must agree about what was observed'
        # Byte-for-byte, not merely both-mention-it.
        (Get-Content -LiteralPath $errPath -Raw) | Should -BeExactly $capture.StdErr
        (Get-Content -LiteralPath $outPath -Raw) | Should -BeExactly $capture.StdOut
    }

    It 'writes exactly what it returns on the ordinary path too, and adds no note there' {
        # The negative half: a note appended unconditionally would be a false
        # diagnosis on every well-formed run.
        $dir = Join-Path $script:Scratch ('capture-ok-' + [System.Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        $outPath = Join-Path $dir 'x.out.log'
        $errPath = Join-Path $dir 'x.err.log'
        $resultPath = Join-Path $dir 'x.result.json'
        Set-Content -LiteralPath $resultPath -Encoding utf8 -Value (
            [ordered]@{ passed = 2; failed = 0; skipped = 0; notRun = 0; containerFailed = 0
                failures = @(); skips = @(); containerErrors = @()
            } | ConvertTo-Json -Depth 6)

        $capture = script:Save-CIGlobAuditCapture -OutPath $outPath -ErrPath $errPath `
            -StdOut 'clean' -StdErr '' -ResultPath $resultPath -Completed $true

        $capture.HasResult | Should -BeTrue
        $capture.Passed | Should -Be 2
        $capture.StdErr | Should -BeExactly ''
        (Get-Content -LiteralPath $errPath -Raw -ErrorAction SilentlyContinue) | Should -BeNullOrEmpty
        (Get-Content -LiteralPath $outPath -Raw) | Should -BeExactly 'clean'
    }
}

Describe 'Survival: "the bound fired" and "the slot is free" are two facts' {

    # Driven directly rather than by manufacturing a real orphan. Producing a
    # grandchild that outlives a tree kill while holding an inherited pipe is
    # both flaky and process-leaking, and a rule that can only be exercised by
    # producing the condition it detects is a rule nothing defends. The
    # end-to-end tests below establish that the harness OBSERVES these inputs
    # correctly on the clean path; this establishes what it concludes from them.

    It 'reports a survivor when the direct child outlived the kill grace' {
        (Get-CIGlobAuditSurvivalVerdict -ChildExited $false -KillEscalated $true -OutputPipeHeld $false).SurvivedKill |
            Should -BeTrue
    }

    It 'reports a survivor when the child is gone but a descendant still holds the pipe' {
        # The case `-not HasExited` cannot see: Kill($true) walks the tree it
        # can see, and a grandchild spawned after enumeration is not in it.
        $v = Get-CIGlobAuditSurvivalVerdict -ChildExited $true -KillEscalated $true -OutputPipeHeld $true
        $v.SurvivedKill | Should -BeTrue -Because 'reporting zero survivors here is the conflation the four-state record exists to prevent'
        $v.Evidence | Should -Match 'descendant'
    }

    It 'does NOT call it a survived kill when no kill happened, but still flags the held pipe' {
        $v = Get-CIGlobAuditSurvivalVerdict -ChildExited $true -KillEscalated $false -OutputPipeHeld $true
        $v.SurvivedKill | Should -BeFalse
        $v.DescendantHeldOutput | Should -BeTrue -Because 'something the suite started is still consuming the runner even though nothing survived a kill'
    }

    It 'reports a clean slot when the child exited and its pipe closed' {
        $v = Get-CIGlobAuditSurvivalVerdict -ChildExited $true -KillEscalated $false -OutputPipeHeld $false
        $v.SurvivedKill | Should -BeFalse
        $v.DescendantHeldOutput | Should -BeFalse
    }
}

Describe 'Duration accounting: how much of a row''s wall clock was the suite?' {

    # Extracted and driven directly for the same reason the survival verdict is:
    # the condition is a descendant that outlives its parent while holding an
    # inherited pipe, which is expensive and flaky to manufacture on purpose.

    It 'excludes the post-exit drain from the suite''s own cost, and keeps BOTH figures' {
        # The reproduced case: the child exited at one second, a descendant held
        # the pipe, and the drain deadline extended from a stopwatch that keeps
        # running — so the row recorded ~11,000 ms for a suite that cost ~1,000.
        $a = Get-CIGlobAuditDurationAccount -TotalMs 11000 -DrainStartedAtMs 1000
        $a.ElapsedMs | Should -Be 11000 -Because 'the harness really did hold the slot that long; that fact is not edited away'
        $a.DrainMs | Should -Be 10000
        $a.SuiteMs | Should -Be 1000 -Because 'this is the figure #1037 sizes shards from'
    }

    It 'reports no drain at all when the child and its pipe finished together' {
        # The negative half. A fix that always subtracted something would make
        # every ordinary row understate its cost.
        $a = Get-CIGlobAuditDurationAccount -TotalMs 1500 -DrainStartedAtMs $null
        $a.DrainMs | Should -Be 0
        $a.SuiteMs | Should -Be 1500
        $a.SuiteMs | Should -Be $a.ElapsedMs
    }

    It 'never reports a negative drain when the clock stopped before the deadline was set' {
        $a = Get-CIGlobAuditDurationAccount -TotalMs 900 -DrainStartedAtMs 1000
        $a.DrainMs | Should -Be 0
        $a.SuiteMs | Should -Be 900
    }

    It 'attributes the whole of a killed row''s overrun to the drain, not to the suite' {
        # A bounded suite killed at its bound and drained for the grace period:
        # the suite cost the bound, the extra is the harness waiting for a corpse.
        $a = Get-CIGlobAuditDurationAccount -TotalMs 16000 -DrainStartedAtMs 6000
        $a.SuiteMs | Should -Be 6000
        $a.DrainMs | Should -Be 10000
    }
}

Describe 'Reachability: is a non-returning suite reachable by a documented way of running these tests?' {

    BeforeAll {
        # The shape the SHIPPED pipeline produces. Prepare builds every row path
        # as `Join-Path '.github/scripts/Tests' $name` and Compose re-stamps the
        # same relative string, so a fixture that builds BOTH sides from an
        # absolute scratch path tests a comparison the pipeline never performs —
        # which is exactly why the tests-root arm shipped inert.
        $script:Root = '.github/scripts/Tests'
    }

    It 'is clean when the only stalled suite lives outside the tests root' {
        $rows = @(script:New-Row -Name 'ctl.Tests.ps1' -State 'did-not-complete' -InPopulation $false `
                -Path '.github/scripts/audit-controls/ctl.Tests.ps1')
        (Get-CIGlobAuditReachability -Rows $rows -SelectedNames @('x.Tests.ps1') -TestsRoot $script:Root).Clean | Should -BeTrue
    }

    It 'catches a stalled suite sitting DIRECTLY under the tests root, in the relative form every real row carries' {
        # The population this audit exists to attempt: all in-population suites
        # sit directly under the tests root, and the 191 quarantined ones are
        # not in SelectedNames — so if this arm is inert, BOTH arms are silent
        # at once and the record affirmatively prints `clean: True`.
        $rows = @(script:New-Row -Name 'hangs.Tests.ps1' -State 'did-not-complete' `
                -Path '.github/scripts/Tests/hangs.Tests.ps1')
        $r = Get-CIGlobAuditReachability -Rows $rows -SelectedNames @('other.Tests.ps1') -TestsRoot $script:Root
        $r.TestsRootReachable | Should -Contain 'hangs.Tests.ps1'
        $r.GateReachable | Should -BeNullOrEmpty -Because 'the gate arm alone would have called this safe'
        $r.Clean | Should -BeFalse
    }

    It 'is NOT clean when a stalled suite sits in a SUBDIRECTORY of the tests root, even though the gate never selects it' {
        $rows = @(script:New-Row -Name 'hangs.Tests.ps1' -State 'did-not-complete' `
                -Path '.github/scripts/Tests/sub/hangs.Tests.ps1')
        $r = Get-CIGlobAuditReachability -Rows $rows -SelectedNames @('other.Tests.ps1') -TestsRoot $script:Root
        $r.Clean | Should -BeFalse
        $r.TestsRootReachable | Should -Contain 'hangs.Tests.ps1'
    }

    It 'matches across separator style and a leading ./, because neither side''s spelling is guaranteed' {
        $rows = @(script:New-Row -Name 'hangs.Tests.ps1' -State 'did-not-complete' `
                -Path '.\.github\scripts\Tests\hangs.Tests.ps1')
        (Get-CIGlobAuditReachability -Rows $rows -SelectedNames @() -TestsRoot './.github/scripts/Tests/').Clean |
            Should -BeFalse
    }

    It 'compares an ABSOLUTE tests root against the relative rows the pipeline produces' {
        # Compose may be handed either spelling. Resolving one side to an
        # absolute path and prefix-testing the other is the defect; normalising
        # both to a relative form is the fix, and this is the pairing that
        # discriminates between them.
        $rows = @(script:New-Row -Name 'hangs.Tests.ps1' -State 'did-not-complete' `
                -Path '.github/scripts/Tests/hangs.Tests.ps1')
        $absoluteRoot = Join-Path $script:RepoRoot '.github/scripts/Tests'
        Push-Location $script:RepoRoot
        try {
            (Get-CIGlobAuditReachability -Rows $rows -SelectedNames @() -TestsRoot $absoluteRoot).Clean |
                Should -BeFalse
        }
        finally { Pop-Location }
    }

    It 'does not throw when a row''s suite no longer exists on disk' {
        # This runs BEFORE any persistence with no try/catch above it, so a
        # resolve-the-row-path fix would convert a silent false-clean into total
        # record loss for a suite deleted between Prepare and Compose.
        $rows = @(script:New-Row -Name 'deleted.Tests.ps1' -State 'did-not-complete' `
                -Path '.github/scripts/Tests/deleted-between-prepare-and-compose.Tests.ps1')
        { Get-CIGlobAuditReachability -Rows $rows -SelectedNames @() -TestsRoot $script:Root } | Should -Not -Throw
    }

    It 'is NOT clean when a stalled suite is in the gate''s selection' {
        $rows = @(script:New-Row -Name 'sel.Tests.ps1' -State 'did-not-complete')
        (Get-CIGlobAuditReachability -Rows $rows -SelectedNames @('sel.Tests.ps1') -TestsRoot $script:Root).GateReachable |
            Should -Contain 'sel.Tests.ps1'
    }

    It 'ignores rows that are not did-not-complete' {
        $rows = @(script:New-Row -Name 'red.Tests.ps1' -State 'failed')
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

Describe 'The fact contract: one list, not three' {

    It 'publishes the fact keys the producer, the agreement check and the consumer all share' {
        $keys = Get-CIGlobAuditFactKeys
        @($keys).Count | Should -Be 15
        foreach ($k in @('WorkingDirectory', 'HasToken', 'IsShallow', 'CredentialsPersisted', 'HasGitIdentity')) {
            $keys | Should -Contain $k -Because 'these five escaped the cross-shard agreement check while the other ten did not'
        }
    }

    It 'validates the environment statement against THAT list, not a hand-copied one' {
        foreach ($k in (Get-CIGlobAuditFactKeys)) {
            $facts = script:New-FactSet
            $facts.Remove($k)
            { Get-CIGlobAuditEnvironmentStatement -Facts $facts } |
                Should -Throw -ExpectedMessage "*$k*" -Because "a dimension nobody measured must not slip past the check, and '$k' is in the published list"
        }
    }

    It 'observes the runtime facts through a git helper declared once, at file scope' {
        # Declaring it inside Get-CIGlobAuditRuntimeFacts redefined a
        # script-scoped function on every call and leaked it into the
        # dot-sourcing session — for a library dot-sourced into sessions that
        # then run other people's code, that is a hazard rather than a style
        # point. It must exist before that function has ever been called.
        (Test-Path -LiteralPath 'Function:\Invoke-CIGlobAuditGit') | Should -BeTrue
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

    It 'CHECKS the Pester version against the gate''s stated window instead of asserting agreement' {
        # The gate installs through an explicit window, so this dimension is
        # checkable — and an out-of-window version rendering `agrees: yes` is a
        # claim of parity on a dimension where the two demonstrably differ.
        $inWindow = Get-CIGlobAuditEnvironmentStatement -Facts (script:New-FactSet @{ PesterVersion = '6.4.0' })
        ($inWindow | Where-Object { $_.Dimension -eq 'Pester version' }).Agrees | Should -BeTrue

        $outOfWindow = Get-CIGlobAuditEnvironmentStatement -Facts (script:New-FactSet @{ PesterVersion = '5.7.1' })
        ($outOfWindow | Where-Object { $_.Dimension -eq 'Pester version' }).Agrees | Should -BeFalse

        $absent = Get-CIGlobAuditEnvironmentStatement -Facts (script:New-FactSet @{ PesterVersion = '(not installed)' })
        ($absent | Where-Object { $_.Dimension -eq 'Pester version' }).Agrees | Should -BeFalse
    }

    It 'calls an ABSENT powershell-yaml a divergence, which is the plan''s own vacuity reading' {
        $absent = Get-CIGlobAuditEnvironmentStatement -Facts (script:New-FactSet @{ YamlModuleVersion = '(not installed)' })
        ($absent | Where-Object { $_.Dimension -match 'powershell-yaml' }).Agrees |
            Should -BeFalse -Because 'omitting a module the gate installs is an avoidable divergence that reddens every suite importing it'
        $present = Get-CIGlobAuditEnvironmentStatement -Facts (script:New-FactSet)
        ($present | Where-Object { $_.Dimension -match 'powershell-yaml' }).Agrees | Should -BeTrue
    }

    It 'reports UNKNOWN rather than agreement where the gate states no comparable value' {
        $rows = Get-CIGlobAuditEnvironmentStatement -Facts (script:New-FactSet)
        foreach ($dim in @('runner OS image', 'working directory')) {
            ($rows | Where-Object { $_.Dimension -eq $dim }).Agrees |
                Should -BeNullOrEmpty -Because "the gate pins only a label or a convention, so '$dim' cannot be compared from this run"
        }
        # And unknown must not be readable as either polarity.
        Format-CIGlobAuditAgreement -Agrees $null | Should -Be '**unknown**'
        Format-CIGlobAuditAgreement -Agrees $true | Should -Be 'yes'
        Format-CIGlobAuditAgreement -Agrees $false | Should -Be '**no**'
    }

    It 'does not read the audit-side runner image off this repository''s own YAML' {
        $rows = Get-CIGlobAuditEnvironmentStatement -Facts (script:New-FactSet)
        ($rows | Where-Object { $_.Dimension -eq 'runner OS image' }).Audit |
            Should -Not -Match 'runs-on' -Because 'R8 excludes an audit-side value read from the audit''s own workflow file'
    }

    It 'states, per dimension, HOW the verdict was reached' {
        foreach ($row in (Get-CIGlobAuditEnvironmentStatement -Facts (script:New-FactSet))) {
            $row.Basis | Should -Not -BeNullOrEmpty -Because 'an assumed agreement must not be able to hide among computed ones'
        }
    }

    It 'computes token agreement from the observed fact, not from the prose that describes it' {
        $lying = script:New-FactSet @{ HasToken = $true; TokenAvailability = 'observed: no token at all, honest' }
        ((Get-CIGlobAuditEnvironmentStatement -Facts $lying) | Where-Object { $_.Dimension -match 'token' }).Agrees |
            Should -BeFalse
    }

    It 'flags a divergence when the audit''s checkout is not shallow like the gate''s' {
        $deep = script:New-FactSet @{ IsShallow = $false; CheckoutDepth = 'observed: full clone, 4000 commit(s) reachable' }
        ((Get-CIGlobAuditEnvironmentStatement -Facts $deep) | Where-Object { $_.Dimension -eq 'checkout depth' }).Agrees |
            Should -BeFalse
    }

    It 'reports UNKNOWN for a dimension whose observed fact is $null, instead of coercing it to a polarity' {
        # `-not $null` is $true and `[bool]$null` is $false, so an UNOBSERVED
        # fact read through either coercion invents a verdict — bypassing the
        # three-valued `Agrees` introduced to stop exactly that. Reproduced end
        # to end: a `git identity` row asserting `yes` while its own cells
        # contradicted each other, certified by a Basis that named a fact which
        # did not exist. Both directions are covered here: the two dimensions
        # that agreed on absence and the two that agreed on presence.
        $cases = @(
            @{ Key = 'HasToken'; Dimension = 'credential and token availability' }
            @{ Key = 'IsShallow'; Dimension = 'checkout depth' }
            @{ Key = 'CredentialsPersisted'; Dimension = 'credential persistence' }
            @{ Key = 'HasGitIdentity'; Dimension = 'git identity' }
        )
        foreach ($case in $cases) {
            $override = @{}
            $override[$case.Key] = $null
            $row = (Get-CIGlobAuditEnvironmentStatement -Facts (script:New-FactSet $override)) |
                Where-Object { $_.Dimension -eq $case.Dimension }

            $null -eq $row.Agrees |
                Should -BeTrue -Because "nothing observed '$($case.Key)', so that dimension neither agrees nor disagrees"
            # The reader-facing discriminator: `yes` and `**no**` are both wrong
            # here, and only one rendering is right.
            Format-CIGlobAuditAgreement -Agrees $row.Agrees | Should -Be '**unknown**'
            # And the Basis must not certify a computation that never happened —
            # correcting the verdict while leaving "computed: from the observed
            # X fact" just moves the false statement one column right.
            $row.Basis | Should -Match 'NOT OBSERVED'
            $row.Basis | Should -Not -Match '^computed:'
        }
    }

    It 'still computes a verdict for every one of those dimensions when the fact IS observed' {
        # The negative half. A fix that reported `unknown` unconditionally would
        # satisfy the test above and destroy the four verdicts the parity claim
        # actually rests on.
        $present = script:New-FactSet @{ HasToken = $false; IsShallow = $true; CredentialsPersisted = $true; HasGitIdentity = $false }
        $rows = Get-CIGlobAuditEnvironmentStatement -Facts $present
        foreach ($dim in @('credential and token availability', 'checkout depth', 'credential persistence', 'git identity')) {
            $row = $rows | Where-Object { $_.Dimension -eq $dim }
            $row.Agrees | Should -BeTrue -Because "'$dim' was observed and agrees, which is a computed verdict, not an unknown"
            $row.Basis | Should -Match '^computed:'
        }
        $flipped = Get-CIGlobAuditEnvironmentStatement -Facts (script:New-FactSet @{ HasGitIdentity = $true })
        ($flipped | Where-Object { $_.Dimension -eq 'git identity' }).Agrees |
            Should -BeFalse -Because 'an identity the gate does not supply is a real divergence, not an unknown'
    }

    It 'does not read a non-boolean mirror as a polarity either, which `[bool]''false''` would get backwards' {
        # `[bool]'false'` is $true in PowerShell. A mirror that arrived as a
        # string would be coerced to the opposite of what it says, with nothing
        # in the row telling a reader that happened.
        $row = (Get-CIGlobAuditEnvironmentStatement -Facts (script:New-FactSet @{ HasGitIdentity = 'nonsense' })) |
            Where-Object { $_.Dimension -eq 'git identity' }
        $null -eq $row.Agrees | Should -BeTrue
        $row.Basis | Should -Match 'not a boolean observation'
    }

    It 'does NOT change the instrument basis when only the commit count in the checkout-depth PROSE moves' {
        # The `Audit` cell is written for a reader and embeds a commit count, so
        # hashing it made 4321 -> 4322 an instrument change: every suite's
        # observation count reset on a run where one commit landed and nothing
        # about the instrument moved. M14's exact harm, arriving through the
        # reader-facing column. Not live at depth 1; live the moment the measure
        # job gains `fetch-depth: 0`.
        $a = Get-CIGlobAuditEnvironmentStatement -Facts (script:New-FactSet @{ CheckoutDepth = 'observed: full clone, 4321 commit(s) reachable' })
        $b = Get-CIGlobAuditEnvironmentStatement -Facts (script:New-FactSet @{ CheckoutDepth = 'observed: full clone, 4322 commit(s) reachable' })
        (Get-CIGlobAuditInstrumentBasis -EnvironmentStatement $a -BoundSeconds 300) |
            Should -Be (Get-CIGlobAuditInstrumentBasis -EnvironmentStatement $b -BoundSeconds 300) -Because 'one more commit is not a different instrument'
    }

    It 'STILL changes the basis when the axis that prose describes actually flips' {
        # The negative half, and the reason the fix is "hash the structured
        # mirror" rather than "drop the dimension": a shallow checkout and a
        # full one are genuinely different instruments for any suite that reads
        # history, and the same applies to the other three mirrors.
        $baseline = Get-CIGlobAuditEnvironmentStatement -Facts (script:New-FactSet)
        $baselineBasis = Get-CIGlobAuditInstrumentBasis -EnvironmentStatement $baseline -BoundSeconds 300
        foreach ($override in @(
                @{ IsShallow = $false }, @{ HasToken = $true }, @{ CredentialsPersisted = $false }, @{ HasGitIdentity = $true }
            )) {
            $changed = Get-CIGlobAuditEnvironmentStatement -Facts (script:New-FactSet $override)
            (Get-CIGlobAuditInstrumentBasis -EnvironmentStatement $changed -BoundSeconds 300) |
                Should -Not -Be $baselineBasis -Because "flipping $($override.Keys -join ',') is an instrument change these observations cannot be pooled across"
        }
    }

    It 'distinguishes an UNOBSERVED axis from both of its polarities in the basis' {
        # A run that could not see an axis is not comparable with one that could,
        # in either direction, so `unobserved` must hash as its own value rather
        # than collapsing onto whichever polarity the coercion used to produce.
        $unobserved = Get-CIGlobAuditEnvironmentStatement -Facts (script:New-FactSet @{ HasGitIdentity = $null })
        $bases = @(
            (Get-CIGlobAuditInstrumentBasis -EnvironmentStatement $unobserved -BoundSeconds 300)
            (Get-CIGlobAuditInstrumentBasis -EnvironmentStatement (Get-CIGlobAuditEnvironmentStatement -Facts (script:New-FactSet @{ HasGitIdentity = $false })) -BoundSeconds 300)
            (Get-CIGlobAuditInstrumentBasis -EnvironmentStatement (Get-CIGlobAuditEnvironmentStatement -Facts (script:New-FactSet @{ HasGitIdentity = $true })) -BoundSeconds 300)
        )
        @($bases | Select-Object -Unique).Count | Should -Be 3
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

    It 'does NOT change the basis when only the shard count changed, which cannot change a terminal state' {
        # R9's standard is "parameters that can change a terminal state". Each
        # suite still runs alone in its own bounded process on its own runner,
        # so dispatching at 4 shards instead of 8 reset every observation count
        # for a dispatch no suite could see.
        $a = Get-CIGlobAuditEnvironmentStatement -Facts (script:New-FactSet @{ Concurrency = 'one at a time; 8 job(s) in parallel' })
        $b = Get-CIGlobAuditEnvironmentStatement -Facts (script:New-FactSet @{ Concurrency = 'one at a time; 4 job(s) in parallel' })
        (Get-CIGlobAuditInstrumentBasis -EnvironmentStatement $a -BoundSeconds 300) |
            Should -Be (Get-CIGlobAuditInstrumentBasis -EnvironmentStatement $b -BoundSeconds 300)
    }

    It 'still changes the basis when the runner image drifts, which R9 names explicitly' {
        # The narrow exclusion above must not be widened into "prune whatever
        # churns": R9 names a drifting `ubuntu-latest` image as a dimension the
        # basis MUST cover, and a basis blind to it pools across exactly the
        # drift the criterion was widened to catch.
        $a = Get-CIGlobAuditEnvironmentStatement -Facts (script:New-FactSet)
        $b = Get-CIGlobAuditEnvironmentStatement -Facts (script:New-FactSet @{ RunnerImage = 'Linux / 20260815.2' })
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
        $map = script:New-InPopulationMap -Rows $rows
        $first = Update-CIGlobAuditHistory -Rows $rows -InstrumentBasis 'i1' -RunId 'r1' -Marker $script:Marker -InPopulationByName $map
        $first.Entries[0].Observations | Should -Be 1
        $second = Update-CIGlobAuditHistory -ExistingBody $first.Body -Rows $rows -InstrumentBasis 'i1' -RunId 'r2' -Marker $script:Marker -InPopulationByName $map
        $second.Entries[0].Observations | Should -Be 2
        $second.Entries[0].LastRun | Should -Be 'r2'
    }

    It 'RESETS the count when the suite''s content changed — a name key would have said two' {
        $map = @{ 'a.Tests.ps1' = $true }
        $first = Update-CIGlobAuditHistory -Rows @(script:New-Row -Name 'a.Tests.ps1' -Digest 'd1') `
            -InstrumentBasis 'i1' -RunId 'r1' -Marker $script:Marker -InPopulationByName $map
        $second = Update-CIGlobAuditHistory -ExistingBody $first.Body -Rows @(script:New-Row -Name 'a.Tests.ps1' -Digest 'd2') `
            -InstrumentBasis 'i1' -RunId 'r2' -Marker $script:Marker -InPopulationByName $map
        $second.Entries[0].Observations | Should -Be 1
        $second.Entries[0].PriorBasis | Should -Be 'd1+i1'
    }

    It 'RESETS the count when the INSTRUMENT changed, which is the axis B3 originally did not name' {
        $map = @{ 'a.Tests.ps1' = $true }
        $first = Update-CIGlobAuditHistory -Rows @(script:New-Row -Name 'a.Tests.ps1' -Digest 'd1') `
            -InstrumentBasis 'bound-300' -RunId 'r1' -Marker $script:Marker -InPopulationByName $map
        $second = Update-CIGlobAuditHistory -ExistingBody $first.Body -Rows @(script:New-Row -Name 'a.Tests.ps1' -Digest 'd1') `
            -InstrumentBasis 'bound-1200' -RunId 'r2' -Marker $script:Marker -InPopulationByName $map
        $second.Entries[0].Observations | Should -Be 1 -Because 'a did-not-complete at one bound and a pass at four times it are not two observations of one thing'
    }

    It 'RETAINS the previous basis past the run after the change, not for exactly one run' {
        # The column exists so R9's attribution is recoverable. Resetting it to
        # `-` the moment the basis stops changing erases that after one run,
        # while the row still looks complete.
        $map = @{ 'a.Tests.ps1' = $true }
        $r1 = Update-CIGlobAuditHistory -Rows @(script:New-Row -Name 'a.Tests.ps1' -Digest 'd1') `
            -InstrumentBasis 'i1' -RunId 'r1' -Marker $script:Marker -InPopulationByName $map
        $r2 = Update-CIGlobAuditHistory -ExistingBody $r1.Body -Rows @(script:New-Row -Name 'a.Tests.ps1' -Digest 'd1') `
            -InstrumentBasis 'i2' -RunId 'r2' -Marker $script:Marker -InPopulationByName $map
        $r2.Entries[0].PriorBasis | Should -Be 'd1+i1'
        $r3 = Update-CIGlobAuditHistory -ExistingBody $r2.Body -Rows @(script:New-Row -Name 'a.Tests.ps1' -Digest 'd1') `
            -InstrumentBasis 'i2' -RunId 'r3' -Marker $script:Marker -InPopulationByName $map
        $r3.Entries[0].Observations | Should -Be 2
        $r3.Entries[0].PriorBasis | Should -Be 'd1+i1' -Because 'the basis change happened; a later stable run is not a reason to forget what it changed from'
    }

    It 'keeps the row for a suite this run did not see, and keeps THAT row''s own commit' {
        # R6 requires the run AND the commit each observation was taken at. A
        # single header commit is the LATEST run's, so resolving a retained
        # row's commit from it gives the wrong tree.
        $first = Update-CIGlobAuditHistory -Rows @(script:New-Row -Name 'gone.Tests.ps1' -Digest 'd1') `
            -InstrumentBasis 'i1' -RunId 'r1' -Marker $script:Marker -Commit 'c1111111' -InPopulationByName @{ 'gone.Tests.ps1' = $true }
        $second = Update-CIGlobAuditHistory -ExistingBody $first.Body -Rows @(script:New-Row -Name 'new.Tests.ps1' -Digest 'd2') `
            -InstrumentBasis 'i1' -RunId 'r2' -Marker $script:Marker -Commit 'c2222222' -InPopulationByName @{ 'new.Tests.ps1' = $true }
        @($second.Entries).Name | Should -Contain 'gone.Tests.ps1'
        $retained = $second.Entries | Where-Object { $_.Name -eq 'gone.Tests.ps1' }
        $retained.LastRun | Should -Be 'r1'
        $retained.LastCommit | Should -Be 'c1111111'
        ($second.Entries | Where-Object { $_.Name -eq 'new.Tests.ps1' }).LastCommit | Should -Be 'c2222222'
    }

    It 'marks an out-of-population control as such, so its observations are not read as corpus measurements' {
        $rows = @(
            script:New-Row -Name 'a.Tests.ps1' -Digest 'd1'
            script:New-Row -Name 'fails.Control.Tests.ps1' -Digest 'd2' -State 'failed' -InPopulation $false
        )
        $h = Update-CIGlobAuditHistory -Rows $rows -InstrumentBasis 'i1' -RunId 'r1' -Marker $script:Marker `
            -InPopulationByName (script:New-InPopulationMap -Rows $rows)
        ($h.Entries | Where-Object { $_.Name -eq 'fails.Control.Tests.ps1' }).InPopulation |
            Should -BeFalse -Because 'the history is the surface #1036 and #1047 read observation counts from'
        $h.Body | Should -Match '\|\s*ctl\s*\|'
        # And it survives the round trip, which is what makes the flag durable.
        $second = Update-CIGlobAuditHistory -ExistingBody $h.Body -Rows @(script:New-Row -Name 'a.Tests.ps1' -Digest 'd1') `
            -InstrumentBasis 'i1' -RunId 'r2' -Marker $script:Marker -InPopulationByName @{ 'a.Tests.ps1' = $true }
        ($second.Entries | Where-Object { $_.Name -eq 'fails.Control.Tests.ps1' }).InPopulation | Should -BeFalse
    }

    It 'writes a body it can read back — a record that cannot be reparsed is not a history' {
        $rows = @(script:New-Row -Name 'a.Tests.ps1' -Digest 'd1'; script:New-Row -Name 'b.Tests.ps1' -Digest 'd2' -State 'failed')
        $map = script:New-InPopulationMap -Rows $rows
        $first = Update-CIGlobAuditHistory -Rows $rows -InstrumentBasis 'i1' -RunId 'r1' -Marker $script:Marker -InPopulationByName $map
        $second = Update-CIGlobAuditHistory -ExistingBody $first.Body -Rows $rows -InstrumentBasis 'i1' -RunId 'r2' -Marker $script:Marker -InPopulationByName $map
        @($second.Entries).Count | Should -Be 2
        ($second.Entries | Where-Object { $_.Name -eq 'b.Tests.ps1' }).Observations | Should -Be 2
        ($second.Entries | Where-Object { $_.Name -eq 'b.Tests.ps1' }).LastState | Should -Be 'failed'
    }

    It 'reads back a lawful suite name the filesystem allows but a narrow pattern cannot express' {
        # Such a row was WRITTEN and never read back, so its count restarted at
        # 1 forever — a silent permanent reset keyed on nothing but the shape of
        # a name. Latent today at 253 matching names; not latent for the next one.
        foreach ($name in @('my suite.Tests.ps1', 'copy (2).Tests.ps1', 'a+b.Tests.ps1', 'back`tick.Tests.ps1', 'pipe|name.Tests.ps1', 'back\slash.Tests.ps1')) {
            $rows = @(script:New-Row -Name $name -Digest 'd1')
            $map = script:New-InPopulationMap -Rows $rows
            $first = Update-CIGlobAuditHistory -Rows $rows -InstrumentBasis 'i1' -RunId 'r1' -Marker $script:Marker -InPopulationByName $map
            $second = Update-CIGlobAuditHistory -ExistingBody $first.Body -Rows $rows -InstrumentBasis 'i1' -RunId 'r2' -Marker $script:Marker -InPopulationByName $map
            @($second.Entries | Where-Object { $_.Name -eq $name }).Observations |
                Should -Be 2 -Because "'$name' is a lawful filename and its history must round-trip"
            # The silent half. The previous shape reset such a row to 1 while
            # reporting nothing wrong, so a reader could not tell a suite whose
            # content had genuinely changed from one whose NAME the parser could
            # not express.
            $second.MalformedRows |
                Should -Be 0 -Because "'$name' parsed, so nothing may be reported as unreadable"
            $second.Body | Should -Not -Match 'did not parse'
        }
    }

    It 'COUNTS and DISCLOSES a row it drops, for every mode of dropping one' {
        # The docstring promises a skipped row is "SKIPPED and counted". For the
        # row-shape mode it was neither: `if ($line -notmatch $rowPattern) {
        # continue }` dropped the row with no `$malformed++` and no disclosure,
        # which is what let the reset above be silent. A row inside the table is
        # a row: it parses, or it is counted and named.
        $rows = @(script:New-Row -Name 'a.Tests.ps1' -Digest 'd1')
        $map = script:New-InPopulationMap -Rows $rows
        $first = Update-CIGlobAuditHistory -Rows $rows -InstrumentBasis 'i1' -RunId 'r1' -Marker $script:Marker -InPopulationByName $map

        # Three ways for a hand-edited row to be unreadable: too few cells, an
        # unparseable observation count, and an empty name.
        $mutations = @(
            @{ Why = 'too few cells'; Body = ($first.Body -replace '(?m)^\| `a\.Tests\.ps1` \| in \|.*$', '| `a.Tests.ps1` | in | d1+i1 |') }
            @{ Why = 'non-numeric observations'; Body = ($first.Body -replace '(?m)^(\| `a\.Tests\.ps1` \| in \| [^|]+ \| )1( \|)', '${1}one${2}') }
            @{ Why = 'no name at all'; Body = ($first.Body -replace '(?m)^\| `a\.Tests\.ps1` \|', '|  |') }
        )
        foreach ($m in $mutations) {
            $m.Body | Should -Not -Be $first.Body -Because "the '$($m.Why)' fixture must actually change the body"
            $second = Update-CIGlobAuditHistory -ExistingBody $m.Body -Rows $rows -InstrumentBasis 'i1' `
                -RunId 'r2' -Marker $script:Marker -InPopulationByName $map
            $second.MalformedRows | Should -Be 1 -Because "a row dropped for '$($m.Why)' is still a dropped row"
            $second.Body | Should -Match 'did not parse'
        }
    }

    It 'does not count the outcome-differences table''s own rows as malformed history rows' {
        # Those rows carry six cells and a suite name, so a parser that finds
        # rows by name shape swept them in and reported prior rows unreadable
        # that were never history rows at all — inflating the one number a
        # reader uses to decide whether to trust the counts.
        $map = @{ 'a.Tests.ps1' = $true }
        $r1 = Update-CIGlobAuditHistory -Rows @(script:New-Row -Name 'a.Tests.ps1' -Digest 'd1' -State 'passed') `
            -InstrumentBasis 'i1' -RunId 'r1' -Marker $script:Marker -InPopulationByName $map
        $r2 = Update-CIGlobAuditHistory -ExistingBody $r1.Body `
            -Rows @(script:New-Row -Name 'a.Tests.ps1' -Digest 'd1' -State 'failed') `
            -InstrumentBasis 'i1' -RunId 'r2' -Marker $script:Marker -InPopulationByName $map
        @($r2.OutcomeDifferences).Count | Should -Be 1 -Because 'the fixture must actually produce a differences table'
        $r2.Body | Should -Match '## Outcome differences'

        $r3 = Update-CIGlobAuditHistory -ExistingBody $r2.Body `
            -Rows @(script:New-Row -Name 'a.Tests.ps1' -Digest 'd1' -State 'failed') `
            -InstrumentBasis 'i1' -RunId 'r3' -Marker $script:Marker -InPopulationByName $map
        $r3.MalformedRows | Should -Be 0 -Because 'the only real history row in that body parsed'
        $r3.Body | Should -Not -Match 'did not parse'
        $r3.Entries[0].Observations | Should -Be 3
    }

    It 'says so when a prior body had rows but no header this parser could find' {
        # Locating the table by its header is what makes counting possible; the
        # cost is that a body whose header was mangled yields no rows at all.
        # That is a stated loss rather than a history that merely looks fresh.
        $rows = @(script:New-Row -Name 'a.Tests.ps1' -Digest 'd1')
        $map = script:New-InPopulationMap -Rows $rows
        $first = Update-CIGlobAuditHistory -Rows $rows -InstrumentBasis 'i1' -RunId 'r1' -Marker $script:Marker -InPopulationByName $map
        $headerless = $first.Body -replace '(?m)^\| suite \| in-population \|.*$', '| suite | WHO KNOWS | basis |'
        $headerless | Should -Not -Be $first.Body

        $second = Update-CIGlobAuditHistory -ExistingBody $headerless -Rows $rows -InstrumentBasis 'i1' `
            -RunId 'r2' -Marker $script:Marker -InPopulationByName $map
        $second.TableUnreadable | Should -BeTrue
        $second.Body | Should -Match 'no readable suite-table header'
        $second.Entries[0].Observations | Should -Be 1

        # And the negative half: an ordinary round trip must not raise it.
        (Update-CIGlobAuditHistory -ExistingBody $first.Body -Rows $rows -InstrumentBasis 'i1' `
                -RunId 'r2' -Marker $script:Marker -InPopulationByName $map).TableUnreadable | Should -BeFalse
    }

    It 'SKIPS a corrupted prior row and reports how many, rather than throwing after the record was persisted' {
        $rows = @(script:New-Row -Name 'a.Tests.ps1' -Digest 'd1')
        $map = script:New-InPopulationMap -Rows $rows
        $first = Update-CIGlobAuditHistory -Rows $rows -InstrumentBasis 'i1' -RunId 'r1' -Marker $script:Marker -InPopulationByName $map
        $corrupted = $first.Body -replace '(?m)^(\| `a\.Tests\.ps1` \| in \| [^|]+ \| )1( \|)', '${1}one${2}'
        $corrupted | Should -Not -Be $first.Body -Because 'the fixture must actually corrupt something'
        $second = $null
        $thrown = $null
        try {
            $second = Update-CIGlobAuditHistory -ExistingBody $corrupted -Rows $rows -InstrumentBasis 'i1' `
                -RunId 'r2' -Marker $script:Marker -InPopulationByName $map
        }
        catch { $thrown = $_ }
        $thrown | Should -BeNullOrEmpty -Because 'this runs after the record comments are already persisted'
        $second.MalformedRows | Should -Be 1
        $second.Body | Should -Match 'did not parse'
    }

    It 'names every suite whose outcome differs from its last observation, which claim 23 has no other surface for' {
        $map = @{ 'a.Tests.ps1' = $true }
        $first = Update-CIGlobAuditHistory -Rows @(script:New-Row -Name 'a.Tests.ps1' -Digest 'd1' -State 'passed') `
            -InstrumentBasis 'i1' -RunId 'r1' -Marker $script:Marker -InPopulationByName $map
        $second = Update-CIGlobAuditHistory -ExistingBody $first.Body `
            -Rows @(script:New-Row -Name 'a.Tests.ps1' -Digest 'd1' -State 'failed') `
            -InstrumentBasis 'i1' -RunId 'r2' -Marker $script:Marker -InPopulationByName $map
        @($second.OutcomeDifferences).Count | Should -Be 1
        $second.OutcomeDifferences[0].PreviousState | Should -Be 'passed'
        $second.OutcomeDifferences[0].CurrentState | Should -Be 'failed'
        $second.OutcomeDifferences[0].Comparable | Should -BeTrue -Because 'same content, same instrument — so the difference is the suite''s own'
        $second.Body | Should -Match 'Outcome differences'
    }

    It 'reports no differences when nothing changed, so the section is not decoration' {
        $map = @{ 'a.Tests.ps1' = $true }
        $rows = @(script:New-Row -Name 'a.Tests.ps1' -Digest 'd1' -State 'passed')
        $first = Update-CIGlobAuditHistory -Rows $rows -InstrumentBasis 'i1' -RunId 'r1' -Marker $script:Marker -InPopulationByName $map
        $second = Update-CIGlobAuditHistory -ExistingBody $first.Body -Rows $rows -InstrumentBasis 'i1' -RunId 'r2' -Marker $script:Marker -InPopulationByName $map
        @($second.OutcomeDifferences).Count | Should -Be 0
        $second.Body | Should -Not -Match 'Outcome differences'
    }

    It 'REFUSES a history that would exceed the body cap, rather than discovering it at the API' {
        # The history only grows: rows for deleted suites are retained forever.
        # It had no cap check at all, which is the same "discovering the cap
        # mid-run" the record composer refuses.
        $rows = 1..40 | ForEach-Object { script:New-Row -Name "s$_.Tests.ps1" -Digest 'd1' }
        { Update-CIGlobAuditHistory -Rows @($rows) -InstrumentBasis 'i1' -RunId 'r1' -Marker $script:Marker `
                -InPopulationByName (script:New-InPopulationMap -Rows $rows) -BodyCap 800 } |
            Should -Throw -ExpectedMessage '*over the 800 cap*'
    }

    It 'puts the marker on line one, so the upsert selector can reach it' {
        $h = Update-CIGlobAuditHistory -Rows @(script:New-Row -Name 'a.Tests.ps1') -InstrumentBasis 'i1' -RunId 'r1' `
            -Marker $script:Marker -InPopulationByName @{ 'a.Tests.ps1' = $true }
        ($h.Body -split "`r?`n")[0] | Should -BeExactly $script:Marker
    }

    It 'carries the record format version, because column order is not a contract' {
        $h = Update-CIGlobAuditHistory -Rows @(script:New-Row -Name 'a.Tests.ps1') -InstrumentBasis 'i1' -RunId 'r1' `
            -Marker $script:Marker -InPopulationByName @{ 'a.Tests.ps1' = $true }
        $h.Body | Should -Match 'record_format_version: 2'
    }
}

Describe 'Body measurement: the unit GitHub''s cap is stated in' {

    It 'counts CODEPOINTS, which a grapheme walk under-counts in the fail-open direction' {
        # The old exhibit was a lone astral character — the one input where a
        # grapheme cluster and a codepoint agree — so the test passed while the
        # measure was wrong for every input that separates them.
        $combining = "e$([char]0x0301)"                                       # 2 codepoints, 1 grapheme
        Measure-CIGlobAuditBody -Body $combining | Should -Be 2

        $zwj = [string]::new([char[]]@(0xD83D, 0xDC69, 0x200D, 0xD83D, 0xDCBB)) # 3 codepoints, 1 grapheme
        Measure-CIGlobAuditBody -Body $zwj | Should -Be 3

        $astral = [string]::new([char[]]@(0xD83D, 0xDE00))                     # 1 codepoint, 2 code units
        $astral.Length | Should -Be 2
        Measure-CIGlobAuditBody -Body $astral | Should -Be 1
    }

    It 'does not let a grapheme-dense body pass a cap it actually exceeds' {
        # 40,000 combining sequences: 80,000 codepoints, 40,000 graphemes. A
        # grapheme measure reports it fits a 65,536 cap; the write is then
        # rejected mid-run, which is the failure the composer says it exists to
        # make impossible.
        $body = "e$([char]0x0301)" * 40000
        Measure-CIGlobAuditBody -Body $body | Should -Be 80000
        Test-CIGlobAuditBodyFits -Body $body -Cap 65536 | Should -BeFalse
    }

    It 'keeps the fast path sound: a body inside the cap in code units is inside it in codepoints' {
        Test-CIGlobAuditBodyFits -Body ('x' * 100) -Cap 65536 | Should -BeTrue
    }
}

Describe 'Detail budget: the launcher''s and the composer''s are the same budget' {

    It 'does not collect more failure text than the record can carry' {
        # The launcher collected up to 25 x 1200 characters and the composer
        # kept 1500, so a suite with many distinct failures surfaced roughly one
        # message and the rest were computed, serialised, uploaded and discarded.
        $collected = $script:CIGlobAuditMaxFailures * $script:CIGlobAuditMaxMessageChars
        $collected | Should -BeLessOrEqual ($script:CIGlobAuditDetailCharCap * 2) -Because 'the launcher''s budget must be in the same order as the cap that survives'
        $script:CIGlobAuditMaxFailures | Should -BeGreaterThan 1 -Because 'one message cannot show a pattern across failures'
    }

    It 'rejects an output verbosity it would otherwise splice into the generated launcher' {
        { Get-CIGlobAuditLauncherScript -SuiteFile '/x/a.Tests.ps1' -ResultFile '/x/r.json' `
                -OutputVerbosity "Normal'; Write-Host 'pwned'; '" } | Should -Throw
        { Get-CIGlobAuditLauncherScript -SuiteFile '/x/a.Tests.ps1' -ResultFile '/x/r.json' -OutputVerbosity 'Normal' } |
            Should -Not -Throw
    }

    It 'still escapes a hostile path, which ValidateSet cannot cover' {
        $script = Get-CIGlobAuditLauncherScript -SuiteFile "/x/it's a suite.Tests.ps1" -ResultFile '/x/r.json'
        $script | Should -Match "it''s a suite"
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
        $docs = script:Invoke-Compose -Rows @(script:New-Row -Name 'a.Tests.ps1') -Names @('a.Tests.ps1')
        ($docs[0].Body -split "`r?`n")[0] | Should -BeExactly '<!-- ci-glob-audit-record-12345 -->'
    }

    It 'refuses to compose without a record format version' {
        $ctx = script:New-RunContext
        $ctx.Remove('RecordFormatVersion')
        {
            New-CIGlobAuditRecordDocuments -RunContext $ctx -Rows @(script:New-Row -Name 'a.Tests.ps1') `
                -EnvironmentStatement $script:Env -Population (script:New-PopulationView -Names @('a.Tests.ps1')) `
                -GateAgreement $script:Agree -Reachability $script:Reach -ControlCheck $script:Controls
        } | Should -Throw -ExpectedMessage '*RecordFormatVersion*'
    }

    It 'emits a STABLE index document alongside the run-keyed ones' {
        # Every other marker embeds the run id, so a consumer had to enumerate
        # an issue's comments and regex run ids out of HTML comments to find
        # "the current record".
        $docs = script:Invoke-Compose -Rows @(script:New-Row -Name 'a.Tests.ps1') -Names @('a.Tests.ps1')
        $index = @($docs | Where-Object { $_.Kind -eq 'index' })
        @($index).Count | Should -Be 1
        $index[0].Marker | Should -BeExactly '<!-- ci-glob-audit-index -->'
        $index[0].Marker | Should -Not -Match '12345'
        ($index[0].Body -split "`r?`n")[0] | Should -BeExactly '<!-- ci-glob-audit-index -->'
        $index[0].Body | Should -Match '<!-- ci-glob-audit-record-12345 -->'
        $index[0].Body | Should -Match 'record_format_version: 2'
    }

    It 'merges a new run into the index it was given, newest first, rather than replacing it' {
        $firstDocs = script:Invoke-Compose -Rows @(script:New-Row -Name 'a.Tests.ps1') -Names @('a.Tests.ps1')
        $firstIndex = (@($firstDocs | Where-Object { $_.Kind -eq 'index' })[0]).Body

        $secondDocs = New-CIGlobAuditRecordDocuments -RunContext (script:New-RunContext @{ RunId = '99999' }) `
            -Rows @(script:New-Row -Name 'a.Tests.ps1') -EnvironmentStatement $script:Env `
            -Population (script:New-PopulationView -Names @('a.Tests.ps1')) `
            -GateAgreement $script:Agree -Reachability $script:Reach -ControlCheck $script:Controls `
            -ExistingIndexBody $firstIndex
        $secondIndex = (@($secondDocs | Where-Object { $_.Kind -eq 'index' })[0]).Body
        $secondIndex | Should -Match '`99999`'
        $secondIndex | Should -Match '`12345`' -Because 'the index is the pointer to EVERY run, not the latest one'
        $lines = @($secondIndex -split "`r?`n" | Where-Object { $_ -match '^\| `\d+`' })
        $lines[0] | Should -Match '99999' -Because 'newest first'
    }

    It 'NAMES the comments a shrinking re-attempt orphans, instead of leaving them to look authoritative' {
        $manyRows = 1..40 | ForEach-Object { script:New-Row -Name "f$_.Tests.ps1" -State 'failed' -Reason 'test-failures' -Detail ('x' * 2500) }
        $big = script:Invoke-Compose -Rows @($manyRows) -Names @($manyRows.Name)
        @($big | Where-Object { $_.Kind -eq 'detail' }).Count | Should -BeGreaterThan 1
        $bigIndex = (@($big | Where-Object { $_.Kind -eq 'index' })[0]).Body

        # Same run id, fewer detail documents: the surplus is still on the issue.
        $small = script:Invoke-Compose -Rows @(script:New-Row -Name 'f1.Tests.ps1' -State 'failed' -Detail 'short') `
            -Names @('f1.Tests.ps1') -Extra @{ ExistingIndexBody = $bigIndex }
        $smallIndex = (@($small | Where-Object { $_.Kind -eq 'index' })[0]).Body
        $smallIndex | Should -Match 'orphaned'
        $smallIndex | Should -Match 'ci-glob-audit-detail-12345-2'
    }

    It 'reports a one-to-one mismatch rather than letting a missing row pass silently' {
        $docs = script:Invoke-Compose -Rows @(script:New-Row -Name 'a.Tests.ps1') -Names @('a.Tests.ps1', 'b.Tests.ps1')
        $docs[0].Body | Should -Match 'missing 1'
        $docs[0].Body | Should -Match 'MISSING: b\.Tests\.ps1'
    }

    It 'names out-of-population rows as such, so no consumer reads a control as a measurement' {
        $rows = @(
            script:New-Row -Name 'a.Tests.ps1'
            script:New-Row -Name 'ctl.Tests.ps1' -InPopulation $false -ControlRole 'expects passed' -Path '.github/scripts/audit-controls/ctl.Tests.ps1'
        )
        $docs = script:Invoke-Compose -Rows $rows -Names @('a.Tests.ps1')
        $docs[0].Body | Should -Match 'Out-of-population rows'
        $docs[0].Body | Should -Match 'ctl\.Tests\.ps1.*expects passed'
    }

    It 'spills detail into further documents rather than truncating it, and every document stays under the cap' {
        $rows = 1..60 | ForEach-Object {
            script:New-Row -Name "f$_.Tests.ps1" -State 'failed' -Reason 'test-failures' -Detail ('x' * 2500)
        }
        $docs = script:Invoke-Compose -Rows @($rows) -Names @($rows.Name)
        @($docs | Where-Object { $_.Kind -eq 'detail' }).Count | Should -BeGreaterThan 1
        foreach ($d in $docs) { (Measure-CIGlobAuditBody -Body $d.Body) | Should -BeLessOrEqual 65536 }
        $allDetail = ($docs | Where-Object { $_.Kind -eq 'detail' } | ForEach-Object { $_.Body }) -join "`n"
        foreach ($n in @('f1.Tests.ps1', 'f30.Tests.ps1', 'f60.Tests.ps1')) { $allDetail | Should -Match ([regex]::Escape($n)) }
    }

    It 'PAGINATES the per-suite table too, instead of throwing away the whole record when it no longer fits' {
        # The summary measured 41,111 codepoints of a 65,536 cap at today's 253
        # suites and overflowed at roughly 400 — and the throw preceded every
        # persist call, so a corpus-growth threshold turned a red-by-
        # construction audit into a NO-RECORD audit.
        $rows = 1..900 | ForEach-Object { script:New-Row -Name "suite-with-a-fairly-long-name-$_.Tests.ps1" }
        $docs = $null
        $thrown = $null
        try { $docs = script:Invoke-Compose -Rows @($rows) -Names @($rows.Name) } catch { $thrown = $_ }
        $thrown | Should -BeNullOrEmpty -Because 'corpus growth must not turn a red-by-construction audit into a no-record audit'
        $rowsDocs = @($docs | Where-Object { $_.Kind -eq 'rows' })
        $rowsDocs.Count | Should -BeGreaterThan 1
        foreach ($d in $docs) { (Measure-CIGlobAuditBody -Body $d.Body) | Should -BeLessOrEqual 65536 }
        # Nothing was dropped to make it fit, and the summary says where it went.
        $allRows = ($rowsDocs | ForEach-Object { $_.Body }) -join "`n"
        foreach ($n in @('suite-with-a-fairly-long-name-1.Tests.ps1', 'suite-with-a-fairly-long-name-900.Tests.ps1')) {
            $allRows | Should -Match ([regex]::Escape($n))
        }
        $docs[0].Body | Should -Match 'ci-glob-audit-rows-12345-1'
    }

    It 'keeps the table inline while it still fits, so a small run is one comment' {
        $docs = script:Invoke-Compose -Rows @(script:New-Row -Name 'a.Tests.ps1') -Names @('a.Tests.ps1')
        @($docs | Where-Object { $_.Kind -eq 'rows' }).Count | Should -Be 0
        $docs[0].Body | Should -Match '\| `a\.Tests\.ps1` \| passed \|'
    }

    It 'renders an empty-detail row as an explicit nothing-emitted statement, not as a blank' {
        $rows = @(script:New-Row -Name 'silent.Tests.ps1' -State 'did-not-complete' -Reason 'bound-exceeded' -Detail '')
        $docs = script:Invoke-Compose -Rows $rows -Names @('silent.Tests.ps1')
        $detail = (($docs | Where-Object { $_.Kind -eq 'detail' }).Body)
        $detail | Should -Match 'Nothing was emitted before the kill'
        $detail | Should -Match 'cannot classify'
    }

    It 'does NOT assert a kill and a bound for a row that completed and was never bounded' {
        # Two false statements per row, in a durable record, laundering a crash
        # into a hang narrative the triage chunk then reads.
        $rows = @(script:New-Row -Name 'crashed.Tests.ps1' -State 'failed' -Reason 'no-result-file' -Detail '')
        $detail = ((script:Invoke-Compose -Rows $rows -Names @('crashed.Tests.ps1') | Where-Object { $_.Kind -eq 'detail' }).Body)
        $detail | Should -Not -Match 'before the kill'
        $detail | Should -Match 'COMPLETED'
        $detail | Should -Match 'no-result-file'
        $detail | Should -Match 'cannot classify' -Because 'it is still an honest empty that must be named as unclassifiable'
    }

    It 'keeps the STOPPING POINT of a console tail, which is the whole reason the tail was selected' {
        $tail = (1..2000 | ForEach-Object { "console line $_" }) -join "`n"
        $rows = @(script:New-Row -Name 'hung.Tests.ps1' -State 'did-not-complete' -Reason 'bound-exceeded' `
                -Detail $tail -DetailSource 'console-tail')
        $detail = ((script:Invoke-Compose -Rows $rows -Names @('hung.Tests.ps1') | Where-Object { $_.Kind -eq 'detail' }).Body)
        $detail | Should -Match 'console line 2000' -Because 'the last thing a suite printed is where it stopped'
        $detail | Should -Not -Match 'console line 1\b'
    }

    It 'keeps the FIRST structured failure message, which is what classifies linux-red against never-ci' {
        # The opposite end from the row above, and this is the trap: a blanket
        # tail-keep would fix the hung row and break the 191-suite population R5
        # exists for, because the messages are joined in order.
        $messages = 1..200 | ForEach-Object { "failure message number $_ with padding text to make it long enough to matter" }
        $rows = @(script:New-Row -Name 'red.Tests.ps1' -State 'failed' -Reason 'test-failures' `
                -Detail ($messages -join "`n") -DetailSource 'structured')
        $detail = ((script:Invoke-Compose -Rows $rows -Names @('red.Tests.ps1') | Where-Object { $_.Kind -eq 'detail' }).Body)
        $detail | Should -Match 'failure message number 1 ' -Because 'the first message is what classifies'
        $detail | Should -Not -Match 'failure message number 200 '
    }

    It 'never truncates a detail through the middle of a surrogate pair' {
        $emoji = [string]::new([char[]]@(0xD83D, 0xDE00))
        # The single leading character is load-bearing: without it the cut index
        # is even, lands on a pair boundary by luck, and the fixture agrees with
        # a guard that is not there. With it, the cut index is a HIGH surrogate
        # and the guard is the only thing preventing a lone one.
        $rows = @(script:New-Row -Name 'astral.Tests.ps1' -State 'failed' -Detail ('a' + ($emoji * 4000)))
        $detail = ((script:Invoke-Compose -Rows $rows -Names @('astral.Tests.ps1') | Where-Object { $_.Kind -eq 'detail' }).Body)
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($detail)
        [System.Text.Encoding]::UTF8.GetString($bytes) | Should -BeExactly $detail
        $detail | Should -Not -Match "$([char]0xFFFD)"
    }

    It 'does not let captured output break out of its fence and forge a record row' {
        # Not only adversarial: this corpus asserts heavily on Markdown
        # documents containing fenced code, and Pester embeds expected/actual
        # text in its messages, so accidental triggering is near-certain.
        $hostile = @(
            'Expected the document to contain:'
            '```text'
            'some embedded fenced content'
            '```'
            ''
            '### `evil.Tests.ps1` — passed (tests-executed-and-passed)'
            ''
            'in-population | elapsed 5 ms | bound 300s'
        ) -join "`n"
        $rows = @(script:New-Row -Name 'fencer.Tests.ps1' -State 'failed' -Detail $hostile)
        $body = ((script:Invoke-Compose -Rows $rows -Names @('fencer.Tests.ps1') | Where-Object { $_.Kind -eq 'detail' }).Body)

        # The block's own delimiters must be strictly longer than the longest
        # backtick run inside it, and there must be exactly two of them: the
        # three-backtick lines the suite printed stay INSIDE, inert.
        $allFenceish = @($body -split "`r?`n" | Where-Object { $_ -match '^`{3,}' })
        $allFenceish.Count | Should -Be 4 -Because 'the captured text''s own two fence lines are still present as content'
        $delimiters = @($body -split "`r?`n" | Where-Object { $_ -match '^`{4,}' })
        $delimiters.Count | Should -Be 2 -Because 'anything else means the captured text closed the block early'
        $delimiters[0] | Should -Match '^`{4,}text'
        $delimiters[1] | Should -Match '^`{4,}$'
        # The forged heading is still in the text — that is fine and expected.
        # What matters is its POSITION: inside the block it is literal, outside
        # it is a row indistinguishable from a genuine one. Counting headings
        # cannot tell those apart, so this checks where each one sits.
        $lines = @($body -split "`r?`n")
        $open = [array]::IndexOf($lines, $delimiters[0])
        $close = [array]::LastIndexOf($lines, $delimiters[1])
        $open | Should -BeGreaterThan -1
        $close | Should -BeGreaterThan $open
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -notmatch '^### ') { continue }
            if ($i -gt $open -and $i -lt $close) { continue }
            $lines[$i] | Should -Match 'fencer\.Tests\.ps1' -Because 'a heading outside the fence is a record row, and only the genuine one may be there'
        }
        @($lines[($open + 1)..($close - 1)] | Where-Object { $_ -match '^### ' }).Count |
            Should -Be 1 -Because 'the forged heading must be inside the block, rendered as literal text'
    }

    It 'refuses loudly when even a paginated summary cannot fit, rather than writing a body GitHub will reject' {
        $rows = 1..3 | ForEach-Object { script:New-Row -Name "s$_.Tests.ps1" }
        {
            script:Invoke-Compose -Rows @($rows) -Names @($rows.Name) -Extra @{ BodyCap = 6000 }
        } | Should -Throw -ExpectedMessage '*over the 6000 cap*'
    }

    It 'says WHY it refused: that the table was already paginated out and the prose is what no longer fits' {
        $rows = 1..3 | ForEach-Object { script:New-Row -Name "s$_.Tests.ps1" }
        $message = ''
        try { script:Invoke-Compose -Rows @($rows) -Names @($rows.Name) -Extra @{ BodyCap = 6000 } }
        catch { $message = [string]$_.Exception.Message }
        $message | Should -Match 'already'
    }

    It 'names the block when one is too large to fit a fresh document even alone' {
        # Unreachable at the shipped per-row cap, and the cap is a parameter —
        # which made the invariant both undocumented and one argument away. The
        # previous loop appended after re-seeding without re-testing, so this
        # surfaced only as a generic over-cap throw once everything else had
        # been composed.
        $rows = 1..3 | ForEach-Object { script:New-Row -Name "f$_.Tests.ps1" -State 'failed' -Detail ('y' * 5000) }
        $message = ''
        try { script:Invoke-Compose -Rows @($rows) -Names @($rows.Name) -Extra @{ BodyCap = 3000; DetailCharCap = 4000 } }
        catch { $message = [string]$_.Exception.Message }
        $message | Should -Match 'does not fit'
        $message | Should -Match 'Pagination cannot resolve this'
        $message | Should -Match 'header \d+ codepoints plus block \d+ codepoints' -Because 'a maintainer needs to know which of the two is oversized'
    }

    It 'names that block even when it is the FIRST one, which is the case the guard was written for' {
        # The guard was reached only after a flush, so `$current -ne $seed` made
        # it unable to fire for the first block — precisely the "a single block
        # larger than the cap" case its own docstring describes. Reproduced at
        # `BodyCap 20000 / DetailCharCap 30000`: one row threw the generic
        # per-document error and the named guard reported False; two rows fired
        # it. The three-row test above therefore could not tell the two apart,
        # so n=1 is pinned separately.
        $rows = @(script:New-Row -Name 'only.Tests.ps1' -State 'failed' -Detail ('y' * 25000))
        $message = ''
        try { script:Invoke-Compose -Rows $rows -Names @($rows.Name) -Extra @{ BodyCap = 20000; DetailCharCap = 30000 } }
        catch { $message = [string]$_.Exception.Message }
        $message | Should -Match 'Pagination cannot resolve this' -Because 'one oversized block is oversized whether or not anything preceded it'
        $message | Should -Match 'header \d+ codepoints plus block \d+ codepoints'
        $message | Should -Not -Match 'over the 20000 cap' -Because 'the generic per-document throw is the unnamed failure this guard replaced'
    }

    It 'still paginates a first block that DOES fit, rather than refusing everything' {
        # The negative half: a guard that threw on every first block would
        # satisfy the test above and make the composer useless.
        $rows = 1..40 | ForEach-Object { script:New-Row -Name "f$_.Tests.ps1" -State 'failed' -Detail ('x' * 2500) }
        $docs = script:Invoke-Compose -Rows @($rows) -Names @($rows.Name)
        @($docs | Where-Object { $_.Kind -eq 'detail' }).Count | Should -BeGreaterThan 1
    }

    It 'separates a row''s own cost from the drain the harness spent after it exited' {
        # `ElapsedMs` absorbs up to the kill grace for a row whose child exited
        # while a descendant held the pipe: a suite that finished in a second
        # records ~11,000 ms. The record flagged such a row as contaminating
        # LATER rows and never said its own duration was inflated — and #1037
        # sizes shards from these numbers.
        $rows = @(script:New-Row -Name 'holder.Tests.ps1' -ElapsedMs 11000 -DrainMs 10000 -DescendantHeldOutput $true)
        $body = (script:Invoke-Compose -Rows $rows -Names @('holder.Tests.ps1'))[0].Body
        $body | Should -Match '\| 11000 \| 10000 \| 1000 \|' -Because 'both figures must be in the durable record, not one adjusted number'
        $body | Should -Match 'drain ms'
        $body | Should -Match 'suite ms'
        # And the record must SAY which is which, not merely print three numbers.
        $body | Should -Match "absorbs up to the kill grace of drain"
    }

    It 'renders a row that never carried the drain figure as unknown, not as zero' {
        # A shard partial written before the field existed did not measure zero
        # drain; it measured nothing. Printing `0` there is a number the record
        # never observed — the same defect as a coerced parity verdict.
        $legacy = script:New-Row -Name 'legacy.Tests.ps1' -ElapsedMs 4200 |
            Select-Object -ExcludeProperty DrainMs, SuiteMs
        $legacy.PSObject.Properties.Match('DrainMs').Count | Should -Be 0 -Because 'the fixture must actually lack the field'
        $body = (script:Invoke-Compose -Rows @($legacy) -Names @('legacy.Tests.ps1'))[0].Body
        $body | Should -Match '\| 4200 \| - \| - \|'
    }

    It 'composes a record that says so when no control ran, rather than failing to bind' {
        $docs = $null
        $thrown = $null
        try { $docs = script:Invoke-Compose -Rows @(script:New-Row -Name 'a.Tests.ps1') -Names @('a.Tests.ps1') -Extra @{ ControlCheck = @() } }
        catch { $thrown = $_ }
        $thrown | Should -BeNullOrEmpty -Because 'composing a record that says no controls ran beats refusing to bind'
        $docs[0].Body | Should -Match 'No controls were checked'
    }

    It 'says so in the record when a bounded suite''s process survived its kill' {
        $rows = @(script:New-Row -Name 'zombie.Tests.ps1' -State 'did-not-complete' -SurvivedKill $true -Detail 'tail' -DetailSource 'console-tail')
        $docs = script:Invoke-Compose -Rows $rows -Names @('zombie.Tests.ps1')
        $docs[0].Body | Should -Match 'survived the kill: \*\*1\*\*'
        $docs[0].Body | Should -Match 'NOT offered as a timing measurement'
    }

    It 'WITHDRAWS the non-contention claim on a run where something survived, instead of asserting both' {
        # The claim used to be fixed prose computed from nothing, five lines
        # from a sentence saying the durations were not offered as a timing
        # measurement — two contradictory statements in one body, and R7's
        # interpretability clause discharged by a declaration.
        $clean = script:Invoke-Compose -Rows @(script:New-Row -Name 'a.Tests.ps1') -Names @('a.Tests.ps1')
        $clean[0].Body | Should -Match 'Non-contention rests on'

        $dirty = script:Invoke-Compose -Rows @(script:New-Row -Name 'z.Tests.ps1' -State 'did-not-complete' -SurvivedKill $true) `
            -Names @('z.Tests.ps1')
        $dirty[0].Body | Should -Match 'No non-contention claim is made'
        $dirty[0].Body | Should -Not -Match 'Non-contention rests on'
    }

    It 'makes NO non-contention claim on a run that measured nothing, where both its guards hold vacuously' {
        # The zero-row case, which is the zero-partial path's own output — the
        # path that exists so a run which measured nothing still produces a
        # record. Both halves of the guard above ("nothing survived its kill",
        # "nothing held a pipe") are filters over the row set, so an empty row
        # set satisfies them for free and the record would otherwise assert
        # non-contention about measurements it never took. That is the same
        # declaration-instead-of-observation defect the claim was rewritten to
        # remove, re-entering through the door its own fix opened.
        $body = (script:Invoke-Compose -Rows @() -Names @())[0].Body
        $body | Should -Not -Match 'Non-contention rests on'
        $body | Should -Match 'because this run measured nothing'
        $body | Should -Match 'not a clean result; it is an absent one'

        # The negative half: a run that DID measure, with nothing surviving,
        # must still get its claim. Otherwise "withhold everything" would pass.
        $measured = (script:Invoke-Compose -Rows @(script:New-Row -Name 'a.Tests.ps1') -Names @('a.Tests.ps1'))[0].Body
        $measured | Should -Match 'Non-contention rests on'
        $measured | Should -Not -Match 'because this run measured nothing'
    }

    It 'reports a suite whose descendant kept the output pipe after it exited' {
        $rows = @(script:New-Row -Name 'orphan.Tests.ps1' -State 'failed' -DescendantHeldOutput $true)
        $body = (script:Invoke-Compose -Rows $rows -Names @('orphan.Tests.ps1'))[0].Body
        $body | Should -Match 'descendant still held their output pipe: \*\*1\*\*'
        $body | Should -Match 'No non-contention claim is made'
    }

    It 'names this run''s whole did-not-complete set, so two runs'' sets can be compared without re-running' {
        $rows = @(
            script:New-Row -Name 'h1.Tests.ps1' -State 'did-not-complete'
            script:New-Row -Name 'h2.Tests.ps1' -State 'did-not-complete'
            script:New-Row -Name 'ok.Tests.ps1'
        )
        $body = (script:Invoke-Compose -Rows $rows -Names @('h1.Tests.ps1', 'h2.Tests.ps1', 'ok.Tests.ps1'))[0].Body
        $body | Should -Match 'the full `did-not-complete` set at bound 300s: `h1\.Tests\.ps1`, `h2\.Tests\.ps1`'
    }

    It 'renders the cross-bound comparison once the index holds a run at a different bound' {
        $first = New-CIGlobAuditRecordDocuments -RunContext (script:New-RunContext @{ RunId = '111'; BoundSeconds = 60 }) `
            -Rows @(script:New-Row -Name 'h.Tests.ps1' -State 'did-not-complete') -EnvironmentStatement $script:Env `
            -Population (script:New-PopulationView -Names @('h.Tests.ps1')) `
            -GateAgreement $script:Agree -Reachability $script:Reach -ControlCheck $script:Controls
        $firstIndex = (@($first | Where-Object { $_.Kind -eq 'index' })[0]).Body

        # Before: no comparison is available, and the record says so rather than
        # implying the check passed.
        (@($first | Where-Object { $_.Kind -eq 'summary' })[0]).Body |
            Should -Match 'not yet available'

        $second = New-CIGlobAuditRecordDocuments -RunContext (script:New-RunContext @{ RunId = '222'; BoundSeconds = 600 }) `
            -Rows @(script:New-Row -Name 'h.Tests.ps1' -State 'passed') -EnvironmentStatement $script:Env `
            -Population (script:New-PopulationView -Names @('h.Tests.ps1')) `
            -GateAgreement $script:Agree -Reachability $script:Reach -ControlCheck $script:Controls `
            -ExistingIndexBody $firstIndex
        $body = (@($second | Where-Object { $_.Kind -eq 'summary' })[0]).Body
        $body | Should -Not -Match 'not yet available'
        $body | Should -Match '\| `111` \| 60 \| 1 \| 0 \| -1 \|' -Because 'the class shrank at the larger bound, which is exactly what R3(d) asks a reader to see'
    }

    It 'presents `HasDrift` as the precondition the run enforced, not as an independent check' {
        $body = (script:Invoke-Compose -Rows @(script:New-Row -Name 'a.Tests.ps1') -Names @('a.Tests.ps1'))[0].Body
        $body | Should -Match 'enforced precondition restated'
        $body | Should -Not -Match 'the derivation is exact only under this precondition'
    }

    It 'renders an unchecked parity dimension as unknown in the table, not as agreement' {
        $body = (script:Invoke-Compose -Rows @(script:New-Row -Name 'a.Tests.ps1') -Names @('a.Tests.ps1'))[0].Body
        $body | Should -Match '\| runner OS image \|.*\| \*\*unknown\*\* \|'
        $body | Should -Match 'dimension\(s\) carry no parity verdict'
    }

    It 'carries the record format version in the summary' {
        $body = (script:Invoke-Compose -Rows @(script:New-Row -Name 'a.Tests.ps1') -Names @('a.Tests.ps1'))[0].Body
        $body | Should -Match '\| record_format_version \| 2 \|'
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
        $row.DescendantHeldOutput | Should -BeFalse -Because 'a clean run leaves nothing holding the pipe'
    }

    It 'classifies the failing control as failed AND carries its message into the detail' {
        $row = script:Invoke-Control -FileName 'fails.Control.Tests.ps1'
        $row.State | Should -Be 'failed'
        $row.Detail | Should -Not -BeNullOrEmpty
        $row.Detail | Should -Match 'ci-glob-audit-control-expected' -Because 'a row carrying only counts is the defect this audit exists to fix'
        $row.Detail | Should -Match 'ci-glob-audit-control-observed'
        $row.DetailSource | Should -Be 'structured'
    }

    It 'scrubs a credential out of captured output at CAPTURE, so the partial artifact carries it scrubbed too' {
        # 189 of the suites this audit runs have never been vetted, and the
        # measure job holds a live bearer credential in the checkout's git
        # config for gate parity. Actions' secret masking covers the job log
        # stream, not a body composed in-process nor an artifact's contents.
        $dir = Join-Path $script:Scratch 'secret-suite'
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        $suite = Join-Path $dir 'leaks.Tests.ps1'
        @(
            'Describe "leaks a credential" {'
            '    It "prints its git config" {'
            '        Write-Host "http.https://github.com/.extraheader=AUTHORIZATION: basic eHh4OmdocF9MRUFLRURTRUNSRVQ="'
            '        Write-Host "also ghp_LEAKEDSECRET0123456789ABCDEF"'
            '        $true | Should -BeFalse'
            '    }'
            '}'
        ) | Set-Content -LiteralPath $suite -Encoding utf8

        $row = Invoke-CIGlobAuditSuite -SuiteFile $suite -TimeoutSeconds 60 `
            -WorkDir (Join-Path $script:Scratch 'e2e') -OutputVerbosity 'Normal'

        $captured = Get-Content -LiteralPath $row.StdOutPath -Raw
        $captured | Should -Match 'REDACTED'
        $captured | Should -Not -Match 'ghp_LEAKEDSECRET'
        $captured | Should -Not -Match 'eHh4OmdocF9MRUFLRURTRUNSRVQ='
        $row.Detail | Should -Not -Match 'ghp_LEAKEDSECRET'
    }

    It 'digests the content that was EXECUTED, not what the suite left behind' {
        # Suites run with write access to the workspace, and R9's whole
        # comparability axis keys on this digest.
        $dir = Join-Path $script:Scratch 'self-modifying'
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        $suite = Join-Path $dir 'rewrites.Tests.ps1'
        $body = @(
            'Describe "rewrites its own file" {'
            '    It "appends to itself" {'
            '        Add-Content -LiteralPath $PSCommandPath -Value "# appended by the suite itself"'
            '        $true | Should -BeTrue'
            '    }'
            '}'
        )
        $body | Set-Content -LiteralPath $suite -Encoding utf8
        $before = Get-CIGlobAuditContentDigest -Path $suite

        $rows = Invoke-CIGlobAuditShard -TimeoutSeconds 60 -WorkDir (Join-Path $script:Scratch 'e2e') -OutputVerbosity 'Normal' `
            -Assignments @([PSCustomObject]@{
                Name = 'rewrites.Tests.ps1'; Path = $suite; InPopulation = $true; ControlRole = ''; QuarantineClass = $null
            })

        (Get-CIGlobAuditContentDigest -Path $suite) | Should -Not -Be $before -Because 'the fixture must actually rewrite itself'
        $rows[0].ContentDigest | Should -Be $before
        $rows[0].SelfModified | Should -BeTrue
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

    It 'bounds a suite that never returns while leaving a suite that returns alone, at the SAME bound' {
        # The one property no in-process assertion can establish, and the only
        # shape of it that actually discriminates.
        #
        # WHY BOTH HALVES, AND WHY ONE BOUND. An earlier revision ran the
        # non-returning control alone at a 2-second bound and leaned on
        # `KillEscalated` to keep it honest. That is weak: most controls cost more
        # than two seconds of child time (measured: the passing control ~6.4s, the
        # all-skipped control ~6.6s), so at a 2-second bound `KillEscalated` is
        # true for suites that would have finished, and the assertion cannot tell
        # "this suite never returns" from "the bound is below what a suite costs".
        # That is the fixture-agrees-with-the-code defect this review sustained
        # twice elsewhere, one level down.
        #
        # So the bound is set above what the returning control actually costs, and
        # the returning control is measured at THAT SAME BOUND. The pair is what
        # carries the meaning: one killed, one not, one bound.
        #
        # Measured on this machine to pick the numbers rather than assume them:
        # the returning control's CHILD process takes ~1.07s over three samples
        # (1093/1087/1066 ms) — the ~2s an observer sees in a test report is
        # harness overhead outside the bound. Six seconds is therefore ~5.5x the
        # returning control's real cost, which leaves room for a slower runner
        # while keeping the hang half's cost to six seconds.
        #
        # Proven discriminating rather than assumed: mutating this bound to 1 —
        # below any suite's floor — turns the negative half red. Mutating it to 2
        # does NOT, which is exactly why the negative half exists and why the
        # single-suite version of this test was not enough.
        $bound = 6

        $stalled = script:Get-StalledRow -Bound $bound
        $stalled.State | Should -Be 'did-not-complete'
        $stalled.Completed | Should -BeFalse
        $stalled.ElapsedMs | Should -BeGreaterOrEqual ($bound * 1000)
        $stalled.KillEscalated | Should -BeTrue
        $stalled.ProcessSurvivedKill | Should -BeFalse -Because 'a surviving orphan contaminates every later row''s duration on the same runner'

        $returned = script:Invoke-Control -FileName 'zero-discovery.Control.Tests.ps1' -Bound $bound
        $returned.Completed | Should -BeTrue -Because 'the negative half: at this same bound a suite that returns must not be killed'
        $returned.KillEscalated | Should -BeFalse
        $returned.State | Should -Not -Be 'did-not-complete'
        $returned.ElapsedMs | Should -BeLessThan ($bound * 1000)

        # The duration account reaches the SHIPPED row, not just its own unit
        # test — a green library nothing calls is the failure mode this file
        # exists to prevent. The killed row's overrun past the bound is drain,
        # and the returning row's cost is its own.
        foreach ($field in @('DrainMs', 'SuiteMs')) {
            $stalled.PSObject.Properties.Match($field).Count | Should -Be 1 -Because "the shipped row must carry $field"
        }
        $stalled.ElapsedMs | Should -Be ($stalled.SuiteMs + $stalled.DrainMs)
        $stalled.SuiteMs | Should -BeGreaterOrEqual ($bound * 1000) -Because 'the suite really did run to the bound; the drain is what came after'
        $returned.SuiteMs | Should -BeLessThan ($bound * 1000)
    }

    It 'carries no terminal escape sequences into the durable classifying detail' {
        # Every did-not-complete row's detail is console tail, and Pester colours
        # its output — invisible to a reader, and consuming the per-row budget
        # R5's classifying text needs. Shares the bounded row with the test above
        # through a memoised producer rather than reading a variable that test
        # happened to leave behind: this one runs alone under `-Filter` too, and
        # the pair still costs one hang, not two.
        $row = script:Get-StalledRow
        $row | Should -Not -BeNullOrEmpty -Because 'without a bounded row there is nothing under test'
        $row.State | Should -Be 'did-not-complete'
        $row.Detail | Should -Not -Match "$([char]27)"
        (Get-Content -LiteralPath $row.StdOutPath -Raw) | Should -Not -Match "$([char]27)"
    }

    It 'leaves the non-returning control harmless when it is not armed' {
        # The second interlock. Unarmed it skips, which is a visible state — not
        # a silent pass, and not a hang on a contributor's machine.
        $row = script:Invoke-Control -FileName 'never-returns.Control.Tests.ps1' -Bound 60
        $row.State | Should -Be 'executed-no-tests'
        $row.Completed | Should -BeTrue
    }
}
