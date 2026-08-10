#Requires -Version 7.0

<#
    ci-glob-audit-wrapper.Tests.ps1

    WHY THIS FILE EXISTS. `ci-glob-audit-core.ps1` carries 119 tests; the CLI
    that decides what actually happens carried zero, and the CLI is where the
    majority of the first review round's fixes landed. `grep -rln
    "ci-glob-audit.ps1" .github/scripts/Tests/` returned nothing. That is this
    repository's own recorded "a green library nothing calls" inversion, one
    level up: every decision this wrapper makes — which of four states a
    comment read came back in, whether the observation history may be
    rewritten, whether a fact was observed at all, what the record says about a
    run that measured nothing — was defended by reading it.

    HOW IT IS DRIVEN. `ci-glob-audit.ps1` is a `param()` script, not a library:
    its three modes, its exit codes and every guard above are in the top-level
    body, which dot-sourcing skips. So it is invoked the way this repository
    invokes its other top-level executables — through the call operator, with
    `$LASTEXITCODE` asserted — against fixture trees under `TestDrive`, which
    is outside the repository. `& $wrapper` runs the top-level body in-process:
    an `exit N` inside it terminates that script and sets `$LASTEXITCODE`
    without touching the Pester host.

    ON THE SPAWN GUARD. `script-safety-contract.Tests.ps1` AST-scans
    Tests-root files for `& pwsh` / `Start-Process pwsh` and would flag either
    shape. Neither is used here and no allowlist entry is needed: the call
    operator on a `.ps1` path is not a `pwsh`/`powershell` CommandAst, which is
    the same reasoning that suite's own `persist-marker-wrapper.Tests.ps1`
    entry records for its in-process arm. The one place a real child process
    appears is the Shard-mode test, and it is created by the LIBRARY (via a
    runtime-resolved `(Get-Process -Id $PID).Path`), not by a literal command
    name in this file — the exclusion the guard documents for
    `goal-contract-validate-core.Tests.ps1`.

    ON THE `gh` SEAM. A real external `gh` shim on `$env:PATH` (`gh.ps1` plus,
    off Windows, an executable `gh` that execs it) rather than a Pester mock,
    because the wrapper's reads and `Find-OrUpsertComment`'s writes each
    dispatch `gh` afresh and the four-state read contract is precisely about
    what a FAILING external call does. The shim records every call and every
    body it was asked to write, so "the history was not rewritten" is asserted
    against what reached the write boundary, not against a log line.

    SCOPE. This file covers `ci-glob-audit.ps1` and nothing else. Where a
    behaviour is composed jointly with `lib/ci-glob-audit-core.ps1`, the
    assertion is made on the value THIS file produces (the withheld
    reachability verdict, the ISO-8601 timestamp, the redacted body) rather
    than on the library's surrounding prose, so a library revision does not
    silently turn one of these tests green for the wrong reason.
#>

Describe 'ci-glob-audit.ps1 — the CLI seam (issue #1035)' {

    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
        $script:Wrapper = Join-Path $script:RepoRoot '.github/scripts/ci-glob-audit.ps1'
        $script:ControlNames = @(
            'passes.Control.Tests.ps1'
            'fails.Control.Tests.ps1'
            'zero-discovery.Control.Tests.ps1'
            'all-skipped.Control.Tests.ps1'
            'never-returns.Control.Tests.ps1'
        )
        # THE list, read from the library rather than restated here. A second
        # copy in a test file is how a cross-shard agreement check comes to be
        # asserted over fourteen of fifteen dimensions.
        . (Join-Path $script:RepoRoot '.github/scripts/lib/ci-glob-audit-core.ps1')
        # Two-step, for the same reason the wrapper's own agreement check is:
        # the exported list returns `,@(...)` so the array survives the
        # pipeline, and `@(Get-CIGlobAuditFactKeys)` written inline therefore
        # yields a ONE-element array holding the list rather than the list —
        # which would silently narrow every loop below to a single iteration
        # over a joined string. (Written inline first here, and it did exactly
        # that.)
        $script:FactKeys = Get-CIGlobAuditFactKeys
        $script:FactKeys = @($script:FactKeys)

        # ------------------------------------------------------------------
        # Invocation
        # ------------------------------------------------------------------
        function script:Invoke-Audit {
            <#
                One wrapper run. Every GITHUB_* variable is neutralised first:
                this suite runs inside the gate, where GITHUB_OUTPUT and
                GITHUB_STEP_SUMMARY are real files the wrapper appends to, and
                a test that let Prepare write `shards=` into the live step
                output would corrupt the job that is running it.
            #>
            param(
                [Parameter(Mandatory)][hashtable]$Arguments,
                [string]$WorkingDirectory = '',
                [string]$StubDir = '',
                [hashtable]$EnvOverrides = @{}
            )

            $managed = @(
                'GITHUB_OUTPUT', 'GITHUB_STEP_SUMMARY', 'GITHUB_RUN_ID', 'GITHUB_RUN_ATTEMPT',
                'GITHUB_REPOSITORY', 'GITHUB_SERVER_URL', 'GITHUB_REF', 'GITHUB_EVENT_NAME',
                'GH_TOKEN', 'GITHUB_TOKEN', 'GH_ENTERPRISE_TOKEN', 'ImageOS', 'ImageVersion'
            )
            $saved = @{}
            foreach ($k in $managed) { $saved[$k] = [System.Environment]::GetEnvironmentVariable($k) }
            $savedPath = $env:PATH
            $savedPathExt = $env:PATHEXT
            $pushed = $false

            try {
                foreach ($k in $managed) { [System.Environment]::SetEnvironmentVariable($k, $null) }
                foreach ($k in $EnvOverrides.Keys) { [System.Environment]::SetEnvironmentVariable($k, [string]$EnvOverrides[$k]) }
                if ($StubDir) {
                    $env:PATH = "$StubDir$([System.IO.Path]::PathSeparator)$savedPath"
                    # PATHEXT is a Windows concept and its separator is always
                    # ';' there; setting it off Windows is inert.
                    $env:PATHEXT = ".PS1;$savedPathExt"
                }
                if ($WorkingDirectory) { Push-Location -LiteralPath $WorkingDirectory; $pushed = $true }

                $global:LASTEXITCODE = 0
                $threw = ''
                $text = ''
                try {
                    $captured = & $script:Wrapper @Arguments *>&1
                    $text = ($captured | Out-String)
                }
                catch {
                    $threw = [string]$_.Exception.Message
                    $text = ($_ | Out-String)
                }
                return [PSCustomObject]@{
                    Output   = $text
                    ExitCode = $LASTEXITCODE
                    Threw    = $threw
                }
            }
            finally {
                if ($pushed) { Pop-Location }
                $env:PATH = $savedPath
                $env:PATHEXT = $savedPathExt
                foreach ($k in $managed) { [System.Environment]::SetEnvironmentVariable($k, $saved[$k]) }
            }
        }

        # ------------------------------------------------------------------
        # The gh shim
        # ------------------------------------------------------------------
        function script:New-GhStub {
            param(
                [Parameter(Mandatory)][string]$Dir,
                [hashtable]$Config = @{}
            )
            New-Item -ItemType Directory -Force -Path $Dir | Out-Null
            New-Item -ItemType Directory -Force -Path (Join-Path $Dir 'bodies') | Out-Null

            $settings = @{
                defaultBranch = 'main'
                failRunList   = $false
                runList       = @()
                failComments  = $false
                comments      = @()
            }
            foreach ($k in $Config.Keys) { $settings[$k] = $Config[$k] }
            ConvertTo-Json -InputObject $settings -Depth 10 |
                Set-Content -LiteralPath (Join-Path $Dir 'config.json') -Encoding utf8

            $shim = @'
param()
$here = $PSScriptRoot
$cfg = Get-Content -LiteralPath (Join-Path $here 'config.json') -Raw | ConvertFrom-Json
$a = @($args)
($a -join ' ') | Add-Content -LiteralPath (Join-Path $here 'calls.log') -Encoding utf8

function Save-Body([string]$text) {
    $dir = Join-Path $here 'bodies'
    $n = @(Get-ChildItem -LiteralPath $dir -File).Count + 1
    Set-Content -LiteralPath (Join-Path $dir "body-$n.md") -Value $text -Encoding utf8
}

if ($a.Count -ge 2 -and $a[0] -eq 'run' -and $a[1] -eq 'list') {
    if ($cfg.failRunList) { [Console]::Error.WriteLine('gh-stub: run list failed'); exit 1 }
    # -InputObject and NOT -AsArray: -AsArray wraps the INPUT, and the input
    # is already the array, so the two together emit [[...]] and every reader
    # downstream sees one element that is an array. (Written with -AsArray
    # first here, and it did exactly that — the same trap the wrapper's own
    # matrix-expression comment records.)
    Write-Output (ConvertTo-Json -InputObject @($cfg.runList) -Depth 10)
    exit 0
}

if ($a.Count -ge 2 -and $a[0] -eq 'repo' -and $a[1] -eq 'view') {
    if (-not $cfg.defaultBranch) { [Console]::Error.WriteLine('gh-stub: repo view failed'); exit 1 }
    Write-Output ([string]$cfg.defaultBranch)
    exit 0
}

if ($a.Count -ge 2 -and $a[0] -eq 'api' -and ([string]$a[1]) -match '/issues/\d+/comments') {
    if ($cfg.failComments) { [Console]::Error.WriteLine('gh-stub: comments read failed'); exit 1 }
    # `[?&]` is load-bearing: the query string is
    # `?per_page=100&page=N`, and a bare `page=(\d+)` matches the `page=100`
    # inside `per_page=100` first, so every read looked like page 100 and came
    # back empty.
    $page = 1
    if (([string]$a[1]) -match '[?&]page=(\d+)') { $page = [int]$Matches[1] }
    $items = if ($page -eq 1) { @($cfg.comments) } else { @() }
    Write-Output (ConvertTo-Json -InputObject @($items) -Depth 10)
    exit 0
}

if ($a.Count -ge 1 -and $a[0] -eq 'api' -and ($a -contains '-X') -and ($a -contains 'PATCH')) {
    $i = [Array]::IndexOf([string[]]$a, '--input')
    if ($i -ge 0) {
        $payload = Get-Content -LiteralPath ([string]$a[$i + 1]) -Raw | ConvertFrom-Json
        Save-Body ([string]$payload.body)
    }
    Write-Output (@{ html_url = 'https://github.com/fixture/fixture/issues/1#issuecomment-1' } | ConvertTo-Json)
    exit 0
}

if ($a.Count -ge 3 -and $a[0] -eq 'issue' -and $a[1] -eq 'view') {
    if ($cfg.failComments) { [Console]::Error.WriteLine('gh-stub: issue view failed'); exit 1 }
    Write-Output (@{ comments = @($cfg.comments) } | ConvertTo-Json -Depth 10)
    exit 0
}

if ($a.Count -ge 3 -and $a[0] -eq 'issue' -and $a[1] -eq 'comment') {
    $i = [Array]::IndexOf([string[]]$a, '--body-file')
    if ($i -ge 0) { Save-Body (Get-Content -LiteralPath ([string]$a[$i + 1]) -Raw) }
    Write-Output 'https://github.com/fixture/fixture/issues/1#issuecomment-2'
    exit 0
}

if ($a.Count -ge 1 -and $a[0] -eq 'api') { Write-Output 'fixture/fixture'; exit 0 }

exit 0
'@
            Set-Content -LiteralPath (Join-Path $Dir 'gh.ps1') -Value $shim -Encoding utf8

            if (-not $IsWindows) {
                # PATHEXT resolution of a bare `gh` to `gh.ps1` is a Windows
                # behaviour. Off Windows the shim needs a real executable of
                # that exact name or the wrapper reaches the machine's actual
                # `gh` — which on a runner is present, unauthenticated, and
                # slow, so the tests would pass or fail for reasons that have
                # nothing to do with this file.
                $launcher = "#!/bin/sh`nexec `"`$(command -v pwsh)`" -NoProfile -NonInteractive -File `"`$(dirname `"`$0`")/gh.ps1`" `"`$@`"`n"
                Set-Content -LiteralPath (Join-Path $Dir 'gh') -Value $launcher -Encoding utf8 -NoNewline
                & chmod +x (Join-Path $Dir 'gh')
                $global:LASTEXITCODE = 0
            }
        }

        function script:Get-StubBodies {
            param([Parameter(Mandatory)][string]$Dir)
            $bodies = Join-Path $Dir 'bodies'
            if (-not (Test-Path -LiteralPath $bodies)) { return @() }
            return @(Get-ChildItem -LiteralPath $bodies -File | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw })
        }

        # ------------------------------------------------------------------
        # Fixture trees
        # ------------------------------------------------------------------
        function script:New-PrepareFixture {
            <#
                A tests root, a lint-clean quarantine registry naming one of
                its files, and the five controls OUTSIDE that root — the shape
                Prepare's own precondition is written against.
            #>
            param(
                [Parameter(Mandatory)][string]$Root,
                [int]$SuiteCount = 4,
                [string[]]$OmitControls = @()
            )
            $tests = Join-Path $Root 'Tests'
            New-Item -ItemType Directory -Force -Path $tests | Out-Null
            $names = @()
            for ($i = 1; $i -le $SuiteCount; $i++) {
                $n = "fixture-$i.Tests.ps1"
                Set-Content -LiteralPath (Join-Path $tests $n) `
                    -Value "Describe 'fixture $i' { It 'passes' { 1 | Should -Be 1 } }" -Encoding utf8
                $names += $n
            }
            $quarantine = @(
                @{ file = $names[0]; class = 'never-ci'; reason = 'fixture: quarantined so the population is not identical to the selection' }
            )
            $quarantinePath = Join-Path $Root 'ci-quarantine.json'
            ConvertTo-Json -InputObject @{ quarantine = $quarantine } -Depth 8 |
                Set-Content -LiteralPath $quarantinePath -Encoding utf8

            $controls = Join-Path $Root 'controls'
            New-Item -ItemType Directory -Force -Path $controls | Out-Null
            foreach ($c in $script:ControlNames) {
                if ($OmitControls -contains $c) { continue }
                Set-Content -LiteralPath (Join-Path $controls $c) `
                    -Value "Describe 'control $c' { It 'passes' { 1 | Should -Be 1 } }" -Encoding utf8
            }

            return [PSCustomObject]@{
                Root           = $Root
                TestsRoot      = $tests
                QuarantinePath = $quarantinePath
                ControlsDir    = $controls
                Names          = $names
                SelectedNames  = @($names | Select-Object -Skip 1)
            }
        }

        function script:New-FactSet {
            param([hashtable]$Override = @{}, [string[]]$Omit = @())
            $facts = [ordered]@{
                ProcessModel          = 'one child pwsh process per suite, started fresh, bounded, stdin closed'
                Concurrency           = 'one suite process at a time within this job; 1 job(s) in parallel on separate runners'
                TokenAvailability     = 'observed: no token in the environment of the suite-executing process'
                CheckoutDepth         = 'observed: shallow, 1 commit(s) reachable => fetch-depth 1'
                CredentialPersistence = 'observed: true — an auth extraheader is present in the checkout''s git config'
                GitIdentity           = 'observed: none configured'
                WorkingDirectory      = 'observed: /home/runner/work/fixture/fixture'
                RunnerImage           = 'Ubuntu / 22.04'
                PowerShellVersion     = '7.4.6'
                PesterVersion         = '6.0.0'
                YamlModuleVersion     = '0.4.7'
                HasToken              = $false
                IsShallow             = $true
                CredentialsPersisted  = $true
                HasGitIdentity        = $false
            }
            foreach ($k in $Override.Keys) { $facts[$k] = $Override[$k] }
            foreach ($k in $Omit) { $facts.Remove($k) }
            return $facts
        }

        function script:New-Row {
            param(
                [Parameter(Mandatory)][string]$Name,
                [string]$State = 'passed',
                [bool]$InPopulation = $true,
                [string]$Path = '',
                [string]$ControlRole = '',
                $QuarantineClass = $null,
                [string]$Detail = '',
                [string]$Reason = 'tests-executed-and-passed'
            )
            return [ordered]@{
                Name                 = $Name
                Path                 = $(if ($Path) { $Path } else { "Tests/$Name" })
                InPopulation         = $InPopulation
                ControlRole          = $ControlRole
                QuarantineClass      = $QuarantineClass
                ContentDigest        = 'a1b2c3d4e5f6'
                ContentDigestAfter   = 'a1b2c3d4e5f6'
                SelfModified         = $false
                State                = $State
                Reason               = $Reason
                ElapsedMs            = 1234
                BoundSeconds         = 300
                Completed            = $true
                ExitCode             = 0
                Passed               = 1
                Failed               = 0
                Skipped              = 0
                NotRun               = 0
                Discovered           = 1
                Executed             = 1
                ContainerFailed      = 0
                KillEscalated        = $false
                ProcessSurvivedKill  = $false
                DescendantHeldOutput = $false
                Detail               = $Detail
                DetailSource         = 'structured'
                DetailTruncateFrom   = 'Head'
            }
        }

        function script:New-PopulationDoc {
            param(
                [Parameter(Mandatory)][string]$Path,
                [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Names,
                [AllowEmptyCollection()][string[]]$SelectedNames = @(),
                [int]$ShardCount = 1,
                [string]$TestsRoot = 'Tests'
            )
            $doc = [ordered]@{
                shardCount = $ShardCount
                testsRoot  = $TestsRoot
                population = [ordered]@{
                    names             = @($Names)
                    selectedNames     = @($SelectedNames)
                    selectedCount     = @($SelectedNames).Count
                    quarantinedCount  = @($Names).Count - @($SelectedNames).Count
                    staleQuarantine   = @()
                    unclassifiedCount = 0
                    hasDrift          = $false
                    derivationCommand = 'fixture'
                }
                items      = @()
            }
            $parent = Split-Path -Parent $Path
            if ($parent -and -not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
            ConvertTo-Json -InputObject $doc -Depth 10 | Set-Content -LiteralPath $Path -Encoding utf8
            return $Path
        }

        function script:New-Partial {
            param(
                [Parameter(Mandatory)][string]$Dir,
                [Parameter(Mandatory)][int]$ShardIndex,
                [int]$ShardCount = 1,
                [int]$TimeoutSeconds = 300,
                $Facts = $null,
                [object[]]$Rows = @(),
                [switch]$NoFacts
            )
            if (-not (Test-Path -LiteralPath $Dir)) { New-Item -ItemType Directory -Force -Path $Dir | Out-Null }
            $doc = [ordered]@{
                shardIndex     = $ShardIndex
                shardCount     = $ShardCount
                timeoutSeconds = $TimeoutSeconds
            }
            if (-not $NoFacts) {
                $doc['facts'] = $(if ($null -ne $Facts) { $Facts } else { script:New-FactSet })
            }
            $doc['rows'] = @($Rows)
            $target = Join-Path $Dir "ci-glob-audit-partial-$ShardIndex.json"
            ConvertTo-Json -InputObject $doc -Depth 12 | Set-Content -LiteralPath $target -Encoding utf8
            return $target
        }

        function script:New-GitRepoFixture {
            param([Parameter(Mandatory)][string]$Root, [switch]$WithOriginTip)
            New-Item -ItemType Directory -Force -Path $Root | Out-Null
            & git -C $Root init -q --initial-branch=main *>&1 | Out-Null
            & git -C $Root config user.email 'fixture@example.invalid' *>&1 | Out-Null
            & git -C $Root config user.name 'Fixture' *>&1 | Out-Null
            & git -C $Root config commit.gpgsign false *>&1 | Out-Null
            # An origin remote, because BOTH the wrapper's comment reader and
            # `Find-OrUpsertComment` resolve owner/repo the same way — explicit
            # parameters, else `git config --get remote.origin.url` — and a
            # fixture repo with no remote makes every GitHub path fail for a
            # reason that has nothing to do with the behaviour under test.
            & git -C $Root remote add origin 'https://github.com/fixture/fixture.git' *>&1 | Out-Null
            Set-Content -LiteralPath (Join-Path $Root 'README.md') -Value 'fixture' -Encoding utf8
            & git -C $Root add -A *>&1 | Out-Null
            & git -C $Root commit -q -m 'fixture commit' *>&1 | Out-Null
            if ($WithOriginTip) { & git -C $Root update-ref refs/remotes/origin/main HEAD *>&1 | Out-Null }
            $global:LASTEXITCODE = 0
            return $Root
        }

        function script:Get-RenderedRecord {
            <#
                The dry-run rendering of one document kind, read back from
                disk. The wrapper writes these itself, so what is asserted is
                what it published, not what it logged about publishing.
            #>
            param([Parameter(Mandatory)][string]$PartialsDir, [string]$Kind = 'summary')
            $dir = Join-Path $PartialsDir 'dry-run-rendered'
            if (-not (Test-Path -LiteralPath $dir)) { return '' }
            return (@(Get-ChildItem -LiteralPath $dir -File -Filter "$Kind-*.md" | Sort-Object Name |
                        ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw }) -join "`n")
        }

        # A composable "everything is in order" compose fixture. It is the
        # discriminating baseline for every exit-2 assertion below: without a
        # case this wrapper can take to exit 0, "it exited 2" says nothing
        # about the guard the test claims to exercise.
        function script:New-CleanComposeFixture {
            param([Parameter(Mandatory)][string]$Root)
            $repo = script:New-GitRepoFixture -Root (Join-Path $Root 'repo') -WithOriginTip
            $popFile = Join-Path $Root 'population.json'
            $names = @('fixture-a.Tests.ps1', 'fixture-b.Tests.ps1')
            script:New-PopulationDoc -Path $popFile -Names $names -SelectedNames $names | Out-Null

            $rows = @(
                (script:New-Row -Name 'fixture-a.Tests.ps1')
                (script:New-Row -Name 'fixture-b.Tests.ps1')
                (script:New-Row -Name 'passes.Control.Tests.ps1' -State 'passed' -InPopulation $false -Path 'audit-controls/passes.Control.Tests.ps1' -ControlRole 'expects passed')
                (script:New-Row -Name 'fails.Control.Tests.ps1' -State 'failed' -Reason 'test-failures' -InPopulation $false -Path 'audit-controls/fails.Control.Tests.ps1' -ControlRole 'expects failed' -Detail 'fixture failure message')
                (script:New-Row -Name 'zero-discovery.Control.Tests.ps1' -State 'executed-no-tests' -Reason 'no-tests-discovered' -InPopulation $false -Path 'audit-controls/zero-discovery.Control.Tests.ps1' -ControlRole 'expects executed-no-tests' -Detail 'nothing discovered')
                (script:New-Row -Name 'all-skipped.Control.Tests.ps1' -State 'executed-no-tests' -Reason 'all-skipped' -InPopulation $false -Path 'audit-controls/all-skipped.Control.Tests.ps1' -ControlRole 'expects executed-no-tests' -Detail 'everything skipped')
                # OUTSIDE the tests root on purpose: this is the row that makes
                # the reachability check compute something rather than filter an
                # empty set, and its path is what keeps the verdict clean.
                (script:New-Row -Name 'never-returns.Control.Tests.ps1' -State 'did-not-complete' -Reason 'bound-exceeded' -InPopulation $false -Path 'audit-controls/never-returns.Control.Tests.ps1' -ControlRole 'expects did-not-complete' -Detail 'console output (did-not-complete / bound-exceeded): still going')
            )
            $partials = Join-Path $Root 'partials'
            script:New-Partial -Dir $partials -ShardIndex 0 -ShardCount 1 -Rows $rows | Out-Null

            $stub = Join-Path $Root 'ghstub'
            script:New-GhStub -Dir $stub -Config @{
                defaultBranch = 'main'
                runList       = @(
                    @{ databaseId = 111; conclusion = 'success'; status = 'completed'; event = 'pull_request'; createdAt = '2026-08-10T04:30:04Z' }
                )
            }

            return [PSCustomObject]@{
                Repo           = $repo
                PopulationFile = $popFile
                PartialsDir    = $partials
                StubDir        = $stub
                Names          = $names
            }
        }
    }

    # ==================================================================
    Context 'Prepare — the population and the matrix expression (M23)' {

        It 'writes an assignment naming every population suite plus the five controls, each flagged out-of-population' {
            $fx = script:New-PrepareFixture -Root (Join-Path $TestDrive 'prep-shape')
            $out = Join-Path $TestDrive 'prep-shape/population.json'

            $r = script:Invoke-Audit -WorkingDirectory $fx.Root -Arguments @{
                Mode = 'Prepare'; TestsRoot = $fx.TestsRoot; QuarantinePath = $fx.QuarantinePath
                ControlsDir = $fx.ControlsDir; ShardCount = 2; OutFile = $out
            }

            $r.Threw | Should -BeNullOrEmpty -Because 'a lint-clean fixture registry with all five controls present is exactly the state Prepare is written for'
            Test-Path -LiteralPath $out | Should -BeTrue -Because 'the assignment file is the only thing the other two jobs receive'

            $doc = Get-Content -LiteralPath $out -Raw | ConvertFrom-Json
            @($doc.population.names).Count | Should -Be 4 -Because 'the population is the gate enumeration BEFORE the quarantine is subtracted: three selected plus one quarantined'
            @($doc.population.selectedNames).Count | Should -Be 3 -Because 'one of the four fixture suites is quarantined'
            @($doc.items).Count | Should -Be 9 -Because 'four population items plus the five controls'

            $controls = @($doc.items | Where-Object { -not $_.inPopulation })
            @($controls).Count | Should -Be 5 -Because 'a control read as a measurement of the corpus is the confusion the flag exists to prevent'
            @($controls | Where-Object { $_.controlRole }).Count | Should -Be 5 -Because 'each control states the terminal state it exists to exhibit'
            @($controls | Where-Object { $_.name -eq 'never-returns.Control.Tests.ps1' })[0].environmentOverrides.CI_GLOB_AUDIT_CONTROLS |
                Should -Be '1' -Because 'the non-returning control is armed per-child, never through the shared job environment'
        }

        It 'emits a FLAT array of shard indices to GITHUB_OUTPUT' {
            $fx = script:New-PrepareFixture -Root (Join-Path $TestDrive 'prep-matrix')
            $ghOut = Join-Path $TestDrive 'prep-matrix/github-output.txt'
            Set-Content -LiteralPath $ghOut -Value '' -Encoding utf8

            $r = script:Invoke-Audit -WorkingDirectory $fx.Root -EnvOverrides @{ GITHUB_OUTPUT = $ghOut } -Arguments @{
                Mode = 'Prepare'; TestsRoot = $fx.TestsRoot; QuarantinePath = $fx.QuarantinePath
                ControlsDir = $fx.ControlsDir; ShardCount = 3
                OutFile = (Join-Path $TestDrive 'prep-matrix/population.json')
            }

            $r.Threw | Should -BeNullOrEmpty -Because 'a three-shard dispatch is lawful and the shape guard must pass it'
            $written = Get-Content -LiteralPath $ghOut -Raw
            $written.Contains('shards=[0,1,2]') | Should -BeTrue -Because "strategy.matrix.shard consumes fromJSON of this string, so it must be a flat array of indices; got: $written"
            $written.Contains('population_count=4') | Should -BeTrue -Because 'the population count is the other output the workflow declares'
        }

        It 'emits [0] — not the scalar 0, and not a nested array — for the single-shard dispatch' {
            # `shard_count: 1` is a lawful dispatch value (the assignment
            # helper accepts 1..64), so this is the real case in which the
            # pipeline form of ConvertTo-Json unwraps to a scalar and
            # fromJSON('0') fails at job-graph expansion — AFTER the prepare
            # job has already reported success.
            $fx = script:New-PrepareFixture -Root (Join-Path $TestDrive 'prep-one')
            $ghOut = Join-Path $TestDrive 'prep-one/github-output.txt'
            Set-Content -LiteralPath $ghOut -Value '' -Encoding utf8

            $r = script:Invoke-Audit -WorkingDirectory $fx.Root -EnvOverrides @{ GITHUB_OUTPUT = $ghOut } -Arguments @{
                Mode = 'Prepare'; TestsRoot = $fx.TestsRoot; QuarantinePath = $fx.QuarantinePath
                ControlsDir = $fx.ControlsDir; ShardCount = 1
                OutFile = (Join-Path $TestDrive 'prep-one/population.json')
            }

            $r.Threw | Should -BeNullOrEmpty -Because 'the shape guard must not refuse a lawful one-shard dispatch'
            $line = @(Get-Content -LiteralPath $ghOut | Where-Object { $_ -like 'shards=*' })[0]
            $line | Should -Be 'shards=[0]' -Because 'the scalar 0 and the nested [[0]] are both unusable as a matrix expression, and both are what the two obvious spellings of this line produce'
        }

        It 'refuses to start when a control is missing, naming it' {
            $fx = script:New-PrepareFixture -Root (Join-Path $TestDrive 'prep-nocontrol') -OmitControls @('never-returns.Control.Tests.ps1')

            $r = script:Invoke-Audit -WorkingDirectory $fx.Root -Arguments @{
                Mode = 'Prepare'; TestsRoot = $fx.TestsRoot; QuarantinePath = $fx.QuarantinePath
                ControlsDir = $fx.ControlsDir; ShardCount = 2
                OutFile = (Join-Path $TestDrive 'prep-nocontrol/population.json')
            }

            $r.Threw | Should -Not -BeNullOrEmpty -Because 'a missing control silently removes the only demonstration of the state it exists for, so the refusal is the instrument protecting its own self-test'
            $r.Threw.Contains('never-returns.Control.Tests.ps1') | Should -BeTrue -Because "the refusal has to name which control is missing; got: $($r.Threw)"
        }
    }

    # ==================================================================
    Context 'Shard — the partial artifact and its write boundary (M8)' {

        It 'requires -PopulationFile rather than deriving a population of its own' {
            $r = script:Invoke-Audit -Arguments @{ Mode = 'Shard'; ShardIndex = 0 }
            $r.Threw | Should -Not -BeNullOrEmpty -Because 'deriving the population per job would work today and drift the first time two jobs saw different trees'
            $r.Threw.Contains('-PopulationFile is required') | Should -BeTrue -Because "the refusal must say which input is missing; got: $($r.Threw)"
        }

        It 'writes a partial carrying the bound, the shard identity, every observed fact key, and a row per assigned suite' {
            $root = Join-Path $TestDrive 'shard-run'
            $tests = Join-Path $root 'Tests'
            New-Item -ItemType Directory -Force -Path $tests | Out-Null
            $suite = Join-Path $tests 'shard-fixture.Tests.ps1'
            Set-Content -LiteralPath $suite -Value "Describe 'shard fixture' { It 'passes' { 1 | Should -Be 1 } }" -Encoding utf8

            # Hand-built rather than produced by Prepare: the `controlRole`
            # string is the probe for the write boundary in the test below and
            # it must reach the partial without passing through any capture-
            # time scrubbing.
            $popFile = Join-Path $root 'population.json'
            $doc = [ordered]@{
                shardCount = 1
                testsRoot  = $tests
                population = [ordered]@{ names = @('shard-fixture.Tests.ps1'); selectedNames = @('shard-fixture.Tests.ps1'); selectedCount = 1; quarantinedCount = 0; staleQuarantine = @(); unclassifiedCount = 0; hasDrift = $false; derivationCommand = 'fixture' }
                items      = @(
                    [ordered]@{ name = 'shard-fixture.Tests.ps1'; path = $suite; inPopulation = $true; controlRole = ''; quarantineClass = $null; environmentOverrides = @{}; shard = 0 }
                )
            }
            ConvertTo-Json -InputObject $doc -Depth 10 | Set-Content -LiteralPath $popFile -Encoding utf8

            $partial = Join-Path $root 'partial-0.json'
            $r = script:Invoke-Audit -WorkingDirectory $root -Arguments @{
                Mode = 'Shard'; PopulationFile = $popFile; ShardIndex = 0; TimeoutSeconds = 120
                WorkDir = (Join-Path $root 'work'); OutFile = $partial
            }

            $r.Threw | Should -BeNullOrEmpty -Because 'a shard that cannot write its partial costs the whole run: a missing partial is read downstream as a hole in the population'
            $r.ExitCode | Should -Be 0 -Because 'a shard exits 0 even when suites failed — reddening here would lose the partial, and the redness belongs after the record is persisted'
            Test-Path -LiteralPath $partial | Should -BeTrue -Because 'the partial is the shard job''s entire output'

            $written = Get-Content -LiteralPath $partial -Raw | ConvertFrom-Json
            [int]$written.shardIndex | Should -Be 0 -Because 'compose reconciles partials by shard index, not by file name'
            [int]$written.shardCount | Should -Be 1 -Because 'the shard count travels with the partial so compose can tell a missing shard from a small dispatch'
            [int]$written.timeoutSeconds | Should -Be 120 -Because 'the bound is half the comparability basis'
            @($written.rows).Count | Should -Be 1 -Because 'one suite was assigned to this shard'

            $observed = @($written.facts.PSObject.Properties.Name)
            foreach ($k in $script:FactKeys) {
                $observed | Should -Contain $k -Because "facts are observed in the process that executes the suites, and a key missing here is a dimension compose can only carry as unobserved: '$k'"
            }
        }

        It 'scrubs credential-shaped material at the partial''s write boundary' {
            $root = Join-Path $TestDrive 'shard-redact'
            $tests = Join-Path $root 'Tests'
            New-Item -ItemType Directory -Force -Path $tests | Out-Null
            $suite = Join-Path $tests 'redact-fixture.Tests.ps1'
            Set-Content -LiteralPath $suite -Value "Describe 'redact fixture' { It 'passes' { 1 | Should -Be 1 } }" -Encoding utf8

            # A token shape carried by an assignment FIELD, not by captured
            # output: capture-time scrubbing in the library never sees it, so
            # only the wrapper's own write-boundary pass can remove it. That is
            # exactly the route the backstop exists for.
            $token = 'ghp_' + ('A' * 30)
            $popFile = Join-Path $root 'population.json'
            $doc = [ordered]@{
                shardCount = 1
                testsRoot  = $tests
                population = [ordered]@{ names = @('redact-fixture.Tests.ps1'); selectedNames = @('redact-fixture.Tests.ps1'); selectedCount = 1; quarantinedCount = 0; staleQuarantine = @(); unclassifiedCount = 0; hasDrift = $false; derivationCommand = 'fixture' }
                items      = @(
                    [ordered]@{ name = 'redact-fixture.Tests.ps1'; path = $suite; inPopulation = $true; controlRole = "expects passed $token"; quarantineClass = $null; environmentOverrides = @{}; shard = 0 }
                )
            }
            ConvertTo-Json -InputObject $doc -Depth 10 | Set-Content -LiteralPath $popFile -Encoding utf8

            $partial = Join-Path $root 'partial-0.json'
            $r = script:Invoke-Audit -WorkingDirectory $root -Arguments @{
                Mode = 'Shard'; PopulationFile = $popFile; ShardIndex = 0; TimeoutSeconds = 120
                WorkDir = (Join-Path $root 'work'); OutFile = $partial
            }
            $r.Threw | Should -BeNullOrEmpty -Because 'the redaction pass must not be able to take the shard down'

            $raw = Get-Content -LiteralPath $partial -Raw
            $raw.Contains($token) | Should -BeFalse -Because 'the partial is an uploaded artifact produced in a job that checks out WITH credential persistence, so anything credential-shaped in it is published'
            $raw.Contains('[REDACTED:github-token]') | Should -BeTrue -Because 'the replacement is visible on purpose: a reader must be able to tell a scrubbed row from a row that printed nothing'
        }
    }

    # ==================================================================
    Context 'Compose — cross-shard agreement over every fact key (M13)' {

        It 'checks all fifteen fact keys, not the one a per-consumer list happened to name' {
            $root = Join-Path $TestDrive 'agree-all'
            $repo = script:New-GitRepoFixture -Root (Join-Path $root 'repo') -WithOriginTip
            $partials = Join-Path $root 'partials'
            $popFile = script:New-PopulationDoc -Path (Join-Path $root 'population.json') -Names @() -SelectedNames @() -ShardCount 2

            # Every key differs between the two shards. Under a narrowed check
            # — the shape the two-step assignment exists to prevent — at most
            # one of these is reported.
            $divergent = @{}
            foreach ($k in $script:FactKeys) { $divergent[$k] = "shard-one-value-for-$k" }
            script:New-Partial -Dir $partials -ShardIndex 0 -ShardCount 2 -Facts (script:New-FactSet) | Out-Null
            script:New-Partial -Dir $partials -ShardIndex 1 -ShardCount 2 -Facts (script:New-FactSet -Override $divergent) | Out-Null

            $stub = Join-Path $root 'ghstub'
            script:New-GhStub -Dir $stub
            $r = script:Invoke-Audit -WorkingDirectory $repo -StubDir $stub -Arguments @{
                Mode = 'Compose'; PopulationFile = $popFile; PartialsDir = $partials; DryRun = $true
            }

            $r.Threw | Should -BeNullOrEmpty -Because 'the agreement check runs before persistence; a throw here costs the record'
            foreach ($k in $script:FactKeys) {
                $r.Output.Contains("shards disagree on '$k'") | Should -BeTrue -Because "every key in THE exported list is checked, or the record's single environment statement describes a machine that did not run most of the suites — '$k' was not reported"
            }
            $r.ExitCode | Should -Be 2 -Because 'a disagreement is an integrity problem, and integrity problems are the exit-2 class'
        }

        It 'names the shard that observed no value for a key it could still describe' {
            $root = Join-Path $TestDrive 'agree-partial'
            $repo = script:New-GitRepoFixture -Root (Join-Path $root 'repo') -WithOriginTip
            $partials = Join-Path $root 'partials'
            $popFile = script:New-PopulationDoc -Path (Join-Path $root 'population.json') -Names @() -SelectedNames @() -ShardCount 2

            script:New-Partial -Dir $partials -ShardIndex 0 -ShardCount 2 -Facts (script:New-FactSet) | Out-Null
            script:New-Partial -Dir $partials -ShardIndex 1 -ShardCount 2 -Facts (script:New-FactSet -Omit @('YamlModuleVersion')) | Out-Null

            $stub = Join-Path $root 'ghstub'
            script:New-GhStub -Dir $stub
            $r = script:Invoke-Audit -WorkingDirectory $repo -StubDir $stub -Arguments @{
                Mode = 'Compose'; PopulationFile = $popFile; PartialsDir = $partials; DryRun = $true
            }

            $r.Output.Contains("shard(s) 1 observed no 'YamlModuleVersion' fact") | Should -BeTrue -Because 'the statement''s value for that dimension describes only the shards that reported it, and the record has to say which those were'
            $r.ExitCode | Should -Be 2 -Because 'a dimension only some shards observed is an integrity problem'
        }

        It 'takes the reference value from the LOWEST shard index, not the first file name' {
            # `partial-10.json` sorts before `partial-2.json`, so file order
            # stops being shard order the moment a dispatch asks for more than
            # ten shards.
            $root = Join-Path $TestDrive 'agree-order'
            $repo = script:New-GitRepoFixture -Root (Join-Path $root 'repo') -WithOriginTip
            $partials = Join-Path $root 'partials'
            $popFile = script:New-PopulationDoc -Path (Join-Path $root 'population.json') -Names @() -SelectedNames @() -ShardCount 11

            script:New-Partial -Dir $partials -ShardIndex 2 -ShardCount 11 -Facts (script:New-FactSet -Override @{ RunnerImage = 'REFERENCE-shard-two-image' }) | Out-Null
            script:New-Partial -Dir $partials -ShardIndex 10 -ShardCount 11 -Facts (script:New-FactSet -Override @{ RunnerImage = 'WRONG-shard-ten-image' }) | Out-Null

            $stub = Join-Path $root 'ghstub'
            script:New-GhStub -Dir $stub
            $r = script:Invoke-Audit -WorkingDirectory $repo -StubDir $stub -Arguments @{
                Mode = 'Compose'; PopulationFile = $popFile; PartialsDir = $partials; DryRun = $true
            }

            $record = script:Get-RenderedRecord -PartialsDir $partials -Kind 'summary'
            $record.Contains('REFERENCE-shard-two-image') | Should -BeTrue -Because 'the reference shard is the lowest index; with eleven shards the alphabetically first FILE is shard 10'
            $record.Contains('WRONG-shard-ten-image') | Should -BeFalse -Because 'shard 10''s value must not become the record''s value merely because its file name sorts first'
        }
    }

    # ==================================================================
    Context 'Compose — a fact no shard observed is unobserved, never a value (F1)' {

        It 'carries a wholly unobserved key as UNOBSERVED and says so, instead of filling it in' {
            $root = Join-Path $TestDrive 'fact-none'
            $repo = script:New-GitRepoFixture -Root (Join-Path $root 'repo') -WithOriginTip
            $partials = Join-Path $root 'partials'
            $popFile = script:New-PopulationDoc -Path (Join-Path $root 'population.json') -Names @() -SelectedNames @() -ShardCount 2

            $omitted = @('YamlModuleVersion', 'HasToken')
            script:New-Partial -Dir $partials -ShardIndex 0 -ShardCount 2 -Facts (script:New-FactSet -Omit $omitted) | Out-Null
            script:New-Partial -Dir $partials -ShardIndex 1 -ShardCount 2 -Facts (script:New-FactSet -Omit $omitted) | Out-Null

            $stub = Join-Path $root 'ghstub'
            script:New-GhStub -Dir $stub
            $r = script:Invoke-Audit -WorkingDirectory $repo -StubDir $stub -Arguments @{
                Mode = 'Compose'; PopulationFile = $popFile; PartialsDir = $partials; DryRun = $true
            }

            $r.Threw | Should -BeNullOrEmpty -Because 'an unobserved dimension must degrade the record, never destroy it'
            $r.Output.Contains("no shard observed the fact(s) 'YamlModuleVersion', 'HasToken' at all") |
                Should -BeTrue -Because "a dimension nobody measured must be named as such: a durable record that asserts parity on it — certified `checked by: computed` — is the defect this problem line exists to surface. Got: $($r.Output)"
            $r.Output.Contains("shard(s) 0, 1 observed no 'YamlModuleVersion' fact") |
                Should -BeFalse -Because '"the statement''s value for it describes only the shards that did" is false when no shard did; there is no value, and telling a reader one exists but is narrow is a different untruth'
            $r.ExitCode | Should -Be 2 -Because 'a dimension the run cannot speak to is an integrity problem, not a clean run'
        }

        It 'never assigns an invented value to a fact key (AST, because the behavioural difference is not this file''s to render)' {
            # STRUCTURAL, and labelled as such. Substituting a stand-in string
            # for the $null — `$facts[$k] = '(not observed)'` — changes nothing
            # this wrapper itself prints: the only observable difference is the
            # parity table's audit cell and the verdict computed from it, both
            # of which are rendered by ci-glob-audit-core.ps1, whose handling of
            # a $null fact is being rewritten in parallel. An assertion there
            # would pin either the old rendering or the new one and be wrong
            # about the other. So the property is asserted where it actually
            # lives: this file may copy an observed value or record its absence,
            # and may never author one.
            #
            # The sibling half — that a $null fact renders as genuinely unknown
            # rather than coerced to a polarity — belongs to the library's own
            # suite, and this test deliberately does not duplicate it.
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:Wrapper, [ref]$null, [ref]$null)
            $assignments = @($ast.FindAll({
                        param($n)
                        $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                        $n.Left -is [System.Management.Automation.Language.IndexExpressionAst] -and
                        $n.Left.Target -is [System.Management.Automation.Language.VariableExpressionAst] -and
                        $n.Left.Target.VariablePath.UserPath -eq 'facts'
                    }, $true))

            @($assignments).Count | Should -BeGreaterThan 0 -Because 'the compose path must still be populating the fact map; zero matches would make every assertion below vacuous'

            $invented = [System.Collections.Generic.List[string]]::new()
            foreach ($a in $assignments) {
                $rhs = $a.Right
                if ($rhs -is [System.Management.Automation.Language.CommandExpressionAst]) { $rhs = $rhs.Expression }
                if ($rhs -is [System.Management.Automation.Language.ConstantExpressionAst] -or
                    $rhs -is [System.Management.Automation.Language.StringConstantExpressionAst] -or
                    $rhs -is [System.Management.Automation.Language.ExpandableStringExpressionAst]) {
                    $invented.Add($a.Extent.Text)
                }
            }
            $invented -join ' | ' | Should -BeNullOrEmpty -Because 'a dimension nobody observed has no value; a literal here is a stand-in the record then certifies as a measurement, and $null (a VariableExpressionAst, not a constant) is the structural signal for "genuinely unknown"'
        }

        It 'does not take the compose job down when a partial carries no facts object at all' {
            $root = Join-Path $TestDrive 'fact-nofacts'
            $repo = script:New-GitRepoFixture -Root (Join-Path $root 'repo') -WithOriginTip
            $partials = Join-Path $root 'partials'
            $popFile = script:New-PopulationDoc -Path (Join-Path $root 'population.json') -Names @() -SelectedNames @() -ShardCount 1

            script:New-Partial -Dir $partials -ShardIndex 0 -ShardCount 1 -NoFacts | Out-Null

            $stub = Join-Path $root 'ghstub'
            script:New-GhStub -Dir $stub
            $r = script:Invoke-Audit -WorkingDirectory $repo -StubDir $stub -Arguments @{
                Mode = 'Compose'; PopulationFile = $popFile; PartialsDir = $partials; DryRun = $true
            }

            $r.Threw | Should -BeNullOrEmpty -Because 'this runs before any persistence, and property access on a missing member is terminating under Set-StrictMode -Version Latest: a truncated or older-shaped partial must degrade the record, not cost it'
            $r.Output.Contains('no shard observed the fact(s)') | Should -BeTrue -Because 'absence of the container is absence of every key in it, and that is a fact about the run the record has to carry'
            $r.ExitCode | Should -Be 2 -Because 'a run whose only partial describes no environment is not a clean run'
        }
    }

    # ==================================================================
    Context 'Compose — the zero-partial branch says what it measured (M10, F2)' {

        BeforeAll {
            $script:ZeroRoot = Join-Path $TestDrive 'zero-partial'
            $script:ZeroRepo = script:New-GitRepoFixture -Root (Join-Path $script:ZeroRoot 'repo') -WithOriginTip
            $script:ZeroPartials = Join-Path $script:ZeroRoot 'partials'
            New-Item -ItemType Directory -Force -Path $script:ZeroPartials | Out-Null
            $script:ZeroPop = script:New-PopulationDoc -Path (Join-Path $script:ZeroRoot 'population.json') `
                -Names @('absent-a.Tests.ps1', 'absent-b.Tests.ps1') -SelectedNames @('absent-a.Tests.ps1', 'absent-b.Tests.ps1') -ShardCount 2
            $script:ZeroStub = Join-Path $script:ZeroRoot 'ghstub'
            script:New-GhStub -Dir $script:ZeroStub
            $script:ZeroRun = script:Invoke-Audit -WorkingDirectory $script:ZeroRepo -StubDir $script:ZeroStub -Arguments @{
                Mode = 'Compose'; PopulationFile = $script:ZeroPop; PartialsDir = $script:ZeroPartials; DryRun = $true
            }
            $script:ZeroRecord = script:Get-RenderedRecord -PartialsDir $script:ZeroPartials -Kind 'summary'
        }

        It 'still composes and renders a record rather than leaving none at all' {
            $script:ZeroRun.Threw | Should -BeNullOrEmpty -Because 'a record that is simply absent teaches nobody which shard is missing'
            $script:ZeroRecord | Should -Not -BeNullOrEmpty -Because 'the compose job''s job is to produce the durable artifact even on the failure path'
            $script:ZeroRun.Output.Contains('no shard partial reached this run, so NO environment was observed') |
                Should -BeTrue -Because 'the record must say outright that no environment was observed rather than describing a machine'
        }

        It 'withholds the R4 cleanliness verdict instead of reporting it true on a run that measured nothing' {
            # Both reachability arms are FILTERS over the row set. Over an
            # empty row set both return empty and the verdict is vacuously
            # clean — while the job exits 2, the durable comment (the artifact
            # #993 and #1036 read) said the property held.
            $script:ZeroRecord.Contains('clean: **True**') | Should -BeFalse -Because 'an empty row set satisfies both arms vacuously; that is not the same fact as no reachable did-not-complete suite existing'
            $script:ZeroRecord.Contains('not established') | Should -BeTrue -Because 'the withheld verdict is what the record must carry in place of a computed one'
            $script:ZeroRun.Output.Contains('R4 reachability is NOT established by this run') |
                Should -BeTrue -Because "withholding the verdict has to reach the integrity problems too, or the only reader who learns of it is one reading the table. Got: $($script:ZeroRun.Output)"
        }

        It 'does not rest the record''s non-contention sentence on a placeholder' {
            $script:ZeroRecord.Contains('(concurrency not stated)') |
                Should -BeFalse -Because 'the timing section reads its ground out of the concurrency dimension; with no such row it printed a literal placeholder as the basis of a claim it made anyway'
            $script:ZeroRecord.Contains('no concurrency was observed') |
                Should -BeTrue -Because 'the ground the sentence cites must state what this run actually knows, which is nothing'
        }

        It 'withholds the observation history rather than keying every suite to a basis derived from nothing' {
            $script:ZeroRun.Output.Contains('observation history not updated') |
                Should -BeTrue -Because 'writing one would reset every suite''s observation count — the number the triage chunk promotes on — to a basis computed from no measurement'
        }

        It 'exits 2' {
            $script:ZeroRun.ExitCode | Should -Be 2 -Because 'missing partials, unmatched controls and an unestablished reachability verdict are all integrity problems'
        }
    }

    # ==================================================================
    Context 'Compose — the commit anchor is settled or it is UNSETTLED (M11)' {

        It 'reports UNSETTLED, naming both refs, when neither resolves' {
            $root = Join-Path $TestDrive 'anchor-none'
            $notARepo = Join-Path $root 'not-a-repo'
            New-Item -ItemType Directory -Force -Path $notARepo | Out-Null
            $partials = Join-Path $root 'partials'
            $popFile = script:New-PopulationDoc -Path (Join-Path $root 'population.json') -Names @() -SelectedNames @() -ShardCount 1
            script:New-Partial -Dir $partials -ShardIndex 0 -ShardCount 1 | Out-Null
            $stub = Join-Path $root 'ghstub'
            script:New-GhStub -Dir $stub -Config @{ defaultBranch = '' }

            $r = script:Invoke-Audit -WorkingDirectory $notARepo -StubDir $stub -Arguments @{
                Mode = 'Compose'; PopulationFile = $popFile; PartialsDir = $partials; DryRun = $true
            }

            $r.Threw | Should -BeNullOrEmpty -Because 'git failing is a degrade, not an exception: under $ErrorActionPreference = ''Stop'' an unchecked failure here costs the whole record'
            $r.Output.Contains("the record's commit anchor is UNSETTLED") |
                Should -BeTrue -Because "a run that exits 0 having said nothing about which ref it measured is the unanchored-record class the anchor exists to close. Got: $($r.Output)"
            $r.Output.Contains('the measured ref (`git rev-parse HEAD`)') | Should -BeTrue -Because 'the problem must name which resolution failed'
            $r.Output.Contains('git rev-parse origin/main') | Should -BeTrue -Because 'both exit codes are checked, so both failures are named'
            $r.ExitCode | Should -Be 2 -Because 'an unanchored record is an integrity problem'
        }

        It 'reports UNSETTLED naming only the tip when HEAD resolves and the default-branch tip does not' {
            $root = Join-Path $TestDrive 'anchor-tip'
            $repo = script:New-GitRepoFixture -Root (Join-Path $root 'repo')   # no origin/main ref
            $partials = Join-Path $root 'partials'
            $popFile = script:New-PopulationDoc -Path (Join-Path $root 'population.json') -Names @() -SelectedNames @() -ShardCount 1
            script:New-Partial -Dir $partials -ShardIndex 0 -ShardCount 1 | Out-Null
            $stub = Join-Path $root 'ghstub'
            script:New-GhStub -Dir $stub

            $r = script:Invoke-Audit -WorkingDirectory $repo -StubDir $stub -Arguments @{
                Mode = 'Compose'; PopulationFile = $popFile; PartialsDir = $partials; DryRun = $true
            }

            $r.Output.Contains("the record's commit anchor is UNSETTLED") | Should -BeTrue -Because 'a resolution failure on either side leaves the anchor unsettled'
            $r.Output.Contains('the measured ref (`git rev-parse HEAD`)') |
                Should -BeFalse -Because 'HEAD resolved here; naming it as unresolved would misstate the very thing the anchor settles'
            $r.Output.Contains('git rev-parse origin/main') | Should -BeTrue -Because 'the tip is the ref that did not resolve'
        }

        It 'settles the anchor when the measured ref IS the default-branch tip' {
            $root = Join-Path $TestDrive 'anchor-settled'
            $fx = script:New-CleanComposeFixture -Root $root

            $r = script:Invoke-Audit -WorkingDirectory $fx.Repo -StubDir $fx.StubDir -Arguments @{
                Mode = 'Compose'; PopulationFile = $fx.PopulationFile; PartialsDir = $fx.PartialsDir; DryRun = $true
            }

            $r.Output.Contains('commit anchor is UNSETTLED') | Should -BeFalse -Because 'both refs resolve and are equal, so there is nothing unsettled to report'
            $record = script:Get-RenderedRecord -PartialsDir $fx.PartialsDir -Kind 'summary'
            $record.Contains('measured ref IS the main tip') | Should -BeTrue -Because 'the record states the ancestry it established, not merely that it tried'
            $record.Contains('none — same commit') | Should -BeTrue -Because 'a per-suite content comparison against an identical commit is settled without running a diff'
        }
    }

    # ==================================================================
    Context 'Compose — the gate expectation is READ, not asserted (M28, F15)' {

        It 'reads the gate''s own recent runs and renders the timestamp as ISO-8601' {
            $root = Join-Path $TestDrive 'gate-green'
            $fx = script:New-CleanComposeFixture -Root $root
            script:New-GhStub -Dir $fx.StubDir -Config @{
                defaultBranch = 'main'
                runList       = @(
                    @{ databaseId = 777001; conclusion = 'success'; status = 'completed'; event = 'push'; createdAt = '2026-08-10T04:30:04Z' }
                    @{ databaseId = 777000; conclusion = 'success'; status = 'completed'; event = 'push'; createdAt = '2026-08-09T22:15:00Z' }
                )
            }

            $r = script:Invoke-Audit -WorkingDirectory $fx.Repo -StubDir $fx.StubDir -Arguments @{
                Mode = 'Compose'; PopulationFile = $fx.PopulationFile; PartialsDir = $fx.PartialsDir; DryRun = $true
            }
            $record = script:Get-RenderedRecord -PartialsDir $fx.PartialsDir -Kind 'summary'

            $record.Contains('Basis, read at compose time') | Should -BeTrue -Because 'R8(b)''s proof standard names the gate''s own recent runs, so the expectation is read from them rather than asserted over them'
            $record.Contains('run ids 777001, 777000') | Should -BeTrue -Because 'the record names the runs it read, so a later reader can check the attribution'
            $record.Contains('most recent 2026-08-10T04:30:04Z') |
                Should -BeTrue -Because "ConvertFrom-Json deserialises the ISO string to [datetime] and interpolation renders it in the runner's culture — `08/10/2026` is a different date to most of this artifact's readers than to some. Got: $record"
            $record.Contains('08/10/2026') | Should -BeFalse -Because 'a locale-formatted timestamp is ambiguous in a cross-reader artifact whose whole point is durability'
        }

        It 'says the gate itself is not uniformly green when one of its recent runs failed' {
            $root = Join-Path $TestDrive 'gate-red'
            $fx = script:New-CleanComposeFixture -Root $root
            script:New-GhStub -Dir $fx.StubDir -Config @{
                defaultBranch = 'main'
                runList       = @(
                    @{ databaseId = 888001; conclusion = 'failure'; status = 'completed'; event = 'push'; createdAt = '2026-08-10T04:30:04Z' }
                    @{ databaseId = 888000; conclusion = 'success'; status = 'completed'; event = 'push'; createdAt = '2026-08-09T22:15:00Z' }
                )
            }

            $r = script:Invoke-Audit -WorkingDirectory $fx.Repo -StubDir $fx.StubDir -Arguments @{
                Mode = 'Compose'; PopulationFile = $fx.PopulationFile; PartialsDir = $fx.PartialsDir; DryRun = $true
            }
            $record = script:Get-RenderedRecord -PartialsDir $fx.PartialsDir -Kind 'summary'

            $record.Contains('the gate itself is not uniformly green') |
                Should -BeTrue -Because 'if main''s gate is red at dispatch time, every matching audit failure would otherwise be misattributed to audit divergence'
            $record.Contains('888001 (failure)') | Should -BeTrue -Because 'the disagreeing runs are named so the attribution can be checked against them'
        }

        It 'marks the expectation UNVERIFIED when the run list cannot be read' {
            $root = Join-Path $TestDrive 'gate-unreadable'
            $fx = script:New-CleanComposeFixture -Root $root
            script:New-GhStub -Dir $fx.StubDir -Config @{ defaultBranch = 'main'; failRunList = $true }

            $r = script:Invoke-Audit -WorkingDirectory $fx.Repo -StubDir $fx.StubDir -Arguments @{
                Mode = 'Compose'; PopulationFile = $fx.PopulationFile; PartialsDir = $fx.PartialsDir; DryRun = $true
            }
            $record = script:Get-RenderedRecord -PartialsDir $fx.PartialsDir -Kind 'summary'

            $r.Threw | Should -BeNullOrEmpty -Because 'a degrade that throws is not a degrade, and this runs before persistence'
            $record.Contains('UNVERIFIED at compose time') |
                Should -BeTrue -Because 'an unreadable run list must degrade honestly rather than quietly reverting to the assertion the read exists to replace'
            $record.Contains('exited 1') | Should -BeTrue -Because 'the record says why the read failed, so the comparison can be supplied manually'
        }

        It 'marks the expectation UNVERIFIED rather than throwing when a run object omits a field' {
            $root = Join-Path $TestDrive 'gate-shape'
            $fx = script:New-CleanComposeFixture -Root $root
            script:New-GhStub -Dir $fx.StubDir -Config @{
                defaultBranch = 'main'
                # `status` present so the completed filter selects it, then no
                # `conclusion` — a terminating error under Set-StrictMode
                # -Version Latest, on a read that happens before persistence.
                runList       = @(@{ status = 'completed' })
            }

            $r = script:Invoke-Audit -WorkingDirectory $fx.Repo -StubDir $fx.StubDir -Arguments @{
                Mode = 'Compose'; PopulationFile = $fx.PopulationFile; PartialsDir = $fx.PartialsDir; DryRun = $true
            }
            $record = script:Get-RenderedRecord -PartialsDir $fx.PartialsDir -Kind 'summary'

            $r.Threw | Should -BeNullOrEmpty -Because 'the whole projection belongs inside the degrade, not just the invocation: a run list that parses but omits a field must not cost the record'
            $record.Contains('UNVERIFIED at compose time') | Should -BeTrue -Because 'a result this reader cannot project is an unread result'
        }
    }

    # ==================================================================
    Context 'Compose — the write boundary scrubs what capture time did not (M8)' {

        It 'redacts a credential shape that reached a document body by a route capture-time scrubbing never saw' {
            $root = Join-Path $TestDrive 'compose-redact'
            $repo = script:New-GitRepoFixture -Root (Join-Path $root 'repo') -WithOriginTip
            $partials = Join-Path $root 'partials'
            $token = 'ghp_' + ('B' * 30)
            $names = @('leaky.Tests.ps1')
            $popFile = script:New-PopulationDoc -Path (Join-Path $root 'population.json') -Names $names -SelectedNames $names

            # Written straight into the partial, exactly as an artifact that
            # bypassed capture-time scrubbing would arrive.
            $rows = @(
                (script:New-Row -Name 'leaky.Tests.ps1' -State 'failed' -Reason 'test-failures' -Detail "assertion failed with AUTHORIZATION: bearer $token")
            )
            script:New-Partial -Dir $partials -ShardIndex 0 -ShardCount 1 -Rows $rows | Out-Null
            $stub = Join-Path $root 'ghstub'
            script:New-GhStub -Dir $stub

            $r = script:Invoke-Audit -WorkingDirectory $repo -StubDir $stub -Arguments @{
                Mode = 'Compose'; PopulationFile = $popFile; PartialsDir = $partials; DryRun = $true
            }
            $r.Threw | Should -BeNullOrEmpty -Because 'the write-boundary pass must not be able to take compose down'

            $rendered = @(script:Get-RenderedRecord -PartialsDir $partials -Kind 'summary'
                script:Get-RenderedRecord -PartialsDir $partials -Kind 'detail'
                script:Get-RenderedRecord -PartialsDir $partials -Kind 'index') -join "`n"
            $rendered | Should -Not -BeNullOrEmpty -Because 'the dry run renders every document it would have published'
            $rendered.Contains($token) | Should -BeFalse -Because 'Actions'' secret masking protects the job log stream, not a body composed in-process and POSTed through gh into a permanent public comment'
            $rendered.Contains('[REDACTED:bearer-token]') | Should -BeTrue -Because 'the replacement is visible so a reader can tell a scrubbed row from a row that printed nothing'
        }
    }

    # ==================================================================
    Context 'Compose — the four-state comment read, and refuse-don''t-reset (M2, M29)' {

        It 'REFUSES to rewrite the observation history when its prior content could not be read' {
            $root = Join-Path $TestDrive 'history-readfail'
            $fx = script:New-CleanComposeFixture -Root $root
            script:New-GhStub -Dir $fx.StubDir -Config @{ defaultBranch = 'main'; failComments = $true }

            $r = script:Invoke-Audit -WorkingDirectory $fx.Repo -StubDir $fx.StubDir -Arguments @{
                Mode = 'Compose'; PopulationFile = $fx.PopulationFile; PartialsDir = $fx.PartialsDir; Issue = 1035
            }

            $r.Output.Contains('the existing observation history could not be read') |
                Should -BeTrue -Because "collapsing a failed read to '' makes the composer rebuild a fresh history and PATCH the real one with it, silently restarting every suite's observation count. Got: $($r.Output)"
            $r.Output.Contains('could not read the existing index comment') |
                Should -BeTrue -Because 'the stable pointer is the one surface a consumer can address without enumerating comments; merging into an empty index drops every prior run from it'

            $bodies = @(script:Get-StubBodies -Dir $fx.StubDir)
            @($bodies | Where-Object { $_ -and $_.Contains('<!-- ci-glob-audit-history -->') }).Count |
                Should -Be 0 -Because 'refuse, do not reset: no body carrying the history marker may reach the write boundary on a run whose read failed'
            $r.ExitCode | Should -Be 2 -Because 'a run that could not read what it must merge into is not a clean run'
        }

        It 'writes the history when the read succeeded and no history comment exists yet' {
            $root = Join-Path $TestDrive 'history-absent'
            $fx = script:New-CleanComposeFixture -Root $root
            script:New-GhStub -Dir $fx.StubDir -Config @{ defaultBranch = 'main'; comments = @() }

            $r = script:Invoke-Audit -WorkingDirectory $fx.Repo -StubDir $fx.StubDir -Arguments @{
                Mode = 'Compose'; PopulationFile = $fx.PopulationFile; PartialsDir = $fx.PartialsDir; Issue = 1035
            }

            $r.Output.Contains('the existing observation history could not be read') |
                Should -BeFalse -Because '"the read succeeded and there is no such comment" is a different fact from "the read failed", and only one of them is a reason to refuse'
            $r.Output.Contains('Persisted observation history') |
                Should -BeTrue -Because "an absent history is the ordinary first-run state and must be created. Got: $($r.Output)"

            $bodies = @(script:Get-StubBodies -Dir $fx.StubDir)
            @($bodies | Where-Object { $_ -and $_.Contains('<!-- ci-glob-audit-history -->') }).Count |
                Should -BeGreaterThan 0 -Because 'the history body must actually reach the write boundary on this path'
        }

        It 'MERGES into an existing history rather than restarting its counts' {
            $root = Join-Path $TestDrive 'history-found'
            $fx = script:New-CleanComposeFixture -Root $root

            # A prior history whose basis matches what this run will compute
            # for the same row: content digest + instrument basis. The digest
            # is fixed by the row fixture; the basis is whatever this run
            # derives, so the row is seeded with a deliberately NON-matching
            # basis and the assertion is about the count NOT silently
            # restarting from a body that was read.
            $priorRun = 'run-before'
            $historyBody = @(
                '<!-- ci-glob-audit-history -->'
                ''
                '# Full-glob CI audit — observation history'
                ''
                '| suite | in-population | basis | observations | last state | last run | last commit | previous basis |'
                '| --- | --- | --- | --- | --- | --- | --- | --- |'
                "| ``fixture-a.Tests.ps1`` | in | a1b2c3d4e5f6+earlier-basis | 7 | passed | $priorRun | deadbeef | - |"
                '| `long-gone.Tests.ps1` | in | zzz+earlier-basis | 3 | failed | run-older | cafe1234 | - |'
            ) -join "`n"
            script:New-GhStub -Dir $fx.StubDir -Config @{
                defaultBranch = 'main'
                comments      = @(
                    @{ id = 'IC_1'; url = 'https://github.com/fixture/fixture/issues/1035#issuecomment-500001'; body = $historyBody }
                )
            }

            $r = script:Invoke-Audit -WorkingDirectory $fx.Repo -StubDir $fx.StubDir -Arguments @{
                Mode = 'Compose'; PopulationFile = $fx.PopulationFile; PartialsDir = $fx.PartialsDir; Issue = 1035
            }

            $r.Output.Contains('Persisted observation history') | Should -BeTrue -Because 'a history that was read successfully is updated in place'
            $written = @(script:Get-StubBodies -Dir $fx.StubDir | Where-Object { $_ -and $_.Contains('<!-- ci-glob-audit-history -->') })
            @($written).Count | Should -BeGreaterThan 0 -Because 'the merged history must reach the write boundary'
            $merged = $written[-1]
            $merged.Contains('long-gone.Tests.ps1') |
                Should -BeTrue -Because "a suite absent from this run keeps its row: the history outlives the runs that produced it, and a read that was merged into cannot have been discarded. Got: $merged"
            $merged.Contains('earlier-basis') |
                Should -BeTrue -Because 'the previous basis is retained on the row so a basis change stays visible after the run that caused it'
        }

        It 'treats a dry run as SKIPPED, not as a read failure' {
            $root = Join-Path $TestDrive 'history-dryrun'
            $fx = script:New-CleanComposeFixture -Root $root

            $r = script:Invoke-Audit -WorkingDirectory $fx.Repo -StubDir $fx.StubDir -Arguments @{
                Mode = 'Compose'; PopulationFile = $fx.PopulationFile; PartialsDir = $fx.PartialsDir; DryRun = $true
            }

            $r.Output.Contains('[dry run] would persist the observation history') |
                Should -BeTrue -Because "a dry run writes nothing, so there is nothing to protect and no integrity problem to raise. Got: $($r.Output)"
            $r.Output.Contains('the existing observation history could not be read') |
                Should -BeFalse -Because 'folding skipped into read-failed would make every dry run report a false refusal'
            @(script:Get-StubBodies -Dir $fx.StubDir).Count | Should -Be 0 -Because 'a dry run neither reads nor writes GitHub'
        }
    }

    # ==================================================================
    Context 'Compose — orphaned paginated parts are superseded in place (M43)' {

        It 'supersedes a part this attempt no longer produces, in BOTH paginated families' {
            $root = Join-Path $TestDrive 'orphans'
            $fx = script:New-CleanComposeFixture -Root $root
            $runId = 'orphan-run-1'

            script:New-GhStub -Dir $fx.StubDir -Config @{
                defaultBranch = 'main'
                comments      = @(
                    @{ id = 'IC_9'; url = 'https://github.com/fixture/fixture/issues/1035#issuecomment-900009'; body = "<!-- ci-glob-audit-detail-$runId-9 -->`n`nsurplus detail from an earlier attempt" }
                    @{ id = 'IC_8'; url = 'https://github.com/fixture/fixture/issues/1035#issuecomment-900008'; body = "<!-- ci-glob-audit-rows-$runId-9 -->`n`nsurplus per-suite table from an earlier attempt" }
                    @{ id = 'IC_1'; url = 'https://github.com/fixture/fixture/issues/1035#issuecomment-900001'; body = "<!-- ci-glob-audit-detail-$runId-1 -->`n`nthe part this attempt still produces" }
                )
            }

            $r = script:Invoke-Audit -WorkingDirectory $fx.Repo -StubDir $fx.StubDir `
                -EnvOverrides @{ GITHUB_RUN_ID = $runId } -Arguments @{
                Mode = 'Compose'; PopulationFile = $fx.PopulationFile; PartialsDir = $fx.PartialsDir; Issue = 1035
            }

            $r.Output.Contains("Superseded orphaned detail document: <!-- ci-glob-audit-detail-$runId-9 -->") |
                Should -BeTrue -Because "a re-attempt that composes fewer parts leaves the surplus on the issue, unreferenced by the summary and indistinguishable from a current part. Got: $($r.Output)"
            $r.Output.Contains("Superseded orphaned rows document: <!-- ci-glob-audit-rows-$runId-9 -->") |
                Should -BeTrue -Because 'the per-suite table paginates the same way and orphans the same way; reconciling only the detail family leaves half the surface stale'

            $tombstones = @(script:Get-StubBodies -Dir $fx.StubDir | Where-Object { $_ -and $_.Contains('Nothing in this comment is part of the record') })
            @($tombstones).Count | Should -Be 2 -Because 'superseding in place keeps the surface honest without a delete, and both families need one'
        }

        It 'does NOT supersede a part this attempt still produces' {
            $root = Join-Path $TestDrive 'orphans-live'
            $fx = script:New-CleanComposeFixture -Root $root
            $runId = 'orphan-run-2'

            script:New-GhStub -Dir $fx.StubDir -Config @{
                defaultBranch = 'main'
                comments      = @(
                    @{ id = 'IC_1'; url = 'https://github.com/fixture/fixture/issues/1035#issuecomment-910001'; body = "<!-- ci-glob-audit-detail-$runId-1 -->`n`nthe part this attempt still produces" }
                )
            }

            $r = script:Invoke-Audit -WorkingDirectory $fx.Repo -StubDir $fx.StubDir `
                -EnvOverrides @{ GITHUB_RUN_ID = $runId } -Arguments @{
                Mode = 'Compose'; PopulationFile = $fx.PopulationFile; PartialsDir = $fx.PartialsDir; Issue = 1035
            }

            $r.Output.Contains('Superseded orphaned') |
                Should -BeFalse -Because "the reconciliation is bounded by the number of parts this attempt composed; tombstoning a live part would destroy the record it is part of. Got: $($r.Output)"
            @(script:Get-StubBodies -Dir $fx.StubDir | Where-Object { $_ -and $_.Contains('Nothing in this comment is part of the record') }).Count |
                Should -Be 0 -Because 'no body carrying a tombstone may reach the write boundary when nothing is orphaned'
        }
    }

    # ==================================================================
    Context 'The workflow grants the compose job what its reads need (F8)' {

        It 'declares actions: read on the compose job, because naming any scope sets the rest to none' {
            Import-Module powershell-yaml -ErrorAction Stop
            $wf = ConvertFrom-Yaml -Yaml (Get-Content -LiteralPath (Join-Path $script:RepoRoot '.github/workflows/ci-full-glob-audit.yml') -Raw)
            $compose = $wf['jobs']['compose']

            $compose['permissions']['actions'] | Should -Be 'read' -Because 'the compose step runs `gh run list --workflow=pester.yml`, which hits GET /repos/{o}/{r}/actions/runs; a permissions block that names contents and issues sets every other scope to none, and the resulting failure degrades R8(b)''s expectation to UNVERIFIED silently and permanently while local verification with a maintainer PAT keeps passing'
            $compose['permissions']['issues'] | Should -Be 'write' -Because 'the record''s durable home is an issue comment, and widening one scope must not have dropped another'
            $compose['permissions']['contents'] | Should -Be 'read' -Because 'the compose job checks out the repository at full depth to settle the commit anchor'
        }

        It 'does NOT grant the suite-executing jobs anything beyond contents: read' {
            Import-Module powershell-yaml -ErrorAction Stop
            $wf = ConvertFrom-Yaml -Yaml (Get-Content -LiteralPath (Join-Path $script:RepoRoot '.github/workflows/ci-full-glob-audit.yml') -Raw)
            $measure = $wf['jobs']['measure']

            @($measure['permissions'].Keys) | Should -Be @('contents') -Because 'a suite that shells out to `gh` must meet the same nothing under the audit that it meets in the gate; the token is step-scoped to compose on purpose'
            $measure['permissions']['contents'] | Should -Be 'read' -Because 'the measure jobs read the tree and nothing else'
        }
    }

    # ==================================================================
    Context 'Compose — the exit-code contract' {

        It 'exits 0 on a record with no integrity problem and no non-passed in-population row' {
            # The discriminating baseline. Every exit-2 assertion above is only
            # evidence about the guard it names because this case exists and
            # comes out differently.
            $root = Join-Path $TestDrive 'exit-clean'
            $fx = script:New-CleanComposeFixture -Root $root

            $r = script:Invoke-Audit -WorkingDirectory $fx.Repo -StubDir $fx.StubDir -Arguments @{
                Mode = 'Compose'; PopulationFile = $fx.PopulationFile; PartialsDir = $fx.PartialsDir; DryRun = $true
            }

            $r.Threw | Should -BeNullOrEmpty -Because 'the clean path must compose without error'
            $r.Output.Contains('### Integrity problems') |
                Should -BeFalse -Because "a fixture designed to be clean must actually be clean, or every exit-2 test above is passing for an unknown reason. Got: $($r.Output)"
            $r.ExitCode | Should -Be 0 -Because 'no integrity problem and no non-passed in-population row is the one state that exits 0'

            $record = script:Get-RenderedRecord -PartialsDir $fx.PartialsDir -Kind 'summary'
            $record.Contains('clean: **True**') |
                Should -BeTrue -Because 'the withheld-verdict path must not have swallowed the computed one: a run that DID measure rows and found no reachable stalled suite still reports the property it established'
        }

        It 'exits 1, after persisting, when an in-population suite did not pass' {
            $root = Join-Path $TestDrive 'exit-red'
            $fx = script:New-CleanComposeFixture -Root $root
            # Same fixture, one in-population row failing.
            $rows = @(
                (script:New-Row -Name 'fixture-a.Tests.ps1' -State 'failed' -Reason 'test-failures' -Detail 'expected 1 to be 2')
                (script:New-Row -Name 'fixture-b.Tests.ps1')
                (script:New-Row -Name 'passes.Control.Tests.ps1' -State 'passed' -InPopulation $false -Path 'audit-controls/passes.Control.Tests.ps1' -ControlRole 'expects passed')
                (script:New-Row -Name 'fails.Control.Tests.ps1' -State 'failed' -Reason 'test-failures' -InPopulation $false -Path 'audit-controls/fails.Control.Tests.ps1' -ControlRole 'expects failed' -Detail 'fixture failure')
                (script:New-Row -Name 'zero-discovery.Control.Tests.ps1' -State 'executed-no-tests' -Reason 'no-tests-discovered' -InPopulation $false -Path 'audit-controls/zero-discovery.Control.Tests.ps1' -ControlRole 'expects executed-no-tests' -Detail 'none discovered')
                (script:New-Row -Name 'all-skipped.Control.Tests.ps1' -State 'executed-no-tests' -Reason 'all-skipped' -InPopulation $false -Path 'audit-controls/all-skipped.Control.Tests.ps1' -ControlRole 'expects executed-no-tests' -Detail 'all skipped')
                (script:New-Row -Name 'never-returns.Control.Tests.ps1' -State 'did-not-complete' -Reason 'bound-exceeded' -InPopulation $false -Path 'audit-controls/never-returns.Control.Tests.ps1' -ControlRole 'expects did-not-complete' -Detail 'still going')
            )
            Remove-Item -LiteralPath (Join-Path $fx.PartialsDir 'ci-glob-audit-partial-0.json') -Force
            script:New-Partial -Dir $fx.PartialsDir -ShardIndex 0 -ShardCount 1 -Rows $rows | Out-Null

            $r = script:Invoke-Audit -WorkingDirectory $fx.Repo -StubDir $fx.StubDir -Arguments @{
                Mode = 'Compose'; PopulationFile = $fx.PopulationFile; PartialsDir = $fx.PartialsDir; DryRun = $true
            }

            $r.ExitCode | Should -Be 1 -Because 'this audit ignores the quarantine, so it is red by construction whenever any suite fails — and that redness is a different fact from an integrity problem'
            $r.Output.Contains('did not pass. This is expected while the quarantine is unapplied') |
                Should -BeTrue -Because 'the warning has to say the record was still produced; a red job is never a reason a record is absent'
        }

        It 'requires -Issue outside a dry run, because the record has no durable home without it' {
            $root = Join-Path $TestDrive 'exit-noissue'
            $fx = script:New-CleanComposeFixture -Root $root

            $r = script:Invoke-Audit -WorkingDirectory $fx.Repo -StubDir $fx.StubDir -Arguments @{
                Mode = 'Compose'; PopulationFile = $fx.PopulationFile; PartialsDir = $fx.PartialsDir
            }

            $r.Threw | Should -Not -BeNullOrEmpty -Because 'composing a record with nowhere to put it wastes the whole run'
            $r.Threw.Contains('-Issue is required') | Should -BeTrue -Because "the refusal must name the missing input; got: $($r.Threw)"
        }
    }
}
