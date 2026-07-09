#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

function script:Get-FrameAuditReportVersionFixtures {
    # Single source of truth for the metrics-version fixture window, called
    # from BOTH the discovery-time declaration below and BeforeAll (Run
    # phase). Pester 6 isolates the Describe body's own top-level statements
    # and BeforeDiscovery blocks to the DISCOVERY pass only — neither
    # persists into Run phase (confirmed empirically: a script-scope
    # variable set outside BeforeAll reads back as $null once Run-phase It
    # bodies execute, and `@($null).Count` deceptively equals 1 rather than
    # 0 or throwing, which is what originally masked this). -ForEach (below)
    # needs the data at discovery time; the "replays the judged historical
    # fixture window" test needs the same data again at Run time via
    # $script:VersionFixtures, so it must be (re-)assigned in BeforeAll too.
    return @(
        @{ MetricsVersion = '1'; PrNumber = 286; FixtureFile = 'frame-pr-286-v1.json' }
        @{ MetricsVersion = '2'; PrNumber = 338; FixtureFile = 'frame-pr-338-v2.json' }
        @{ MetricsVersion = '3'; PrNumber = 415; FixtureFile = 'frame-pr-415-v3.json' }
        @{ MetricsVersion = '4'; PrNumber = 411; FixtureFile = 'frame-pr-411-v4.json' }
    )
}

Describe 'Invoke-FrameAuditReport' {

    # Discovery-time population so -ForEach (below) never sees a null/empty
    # collection under Pester 6. See Get-FrameAuditReportVersionFixtures for
    # why this must be re-populated again inside BeforeAll.
    $script:VersionFixtures = Get-FrameAuditReportVersionFixtures

    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
        $script:LibFile = Join-Path $script:RepoRoot '.github/scripts/lib/frame-audit-report-core.ps1'
        $script:FixtureDir = Join-Path $PSScriptRoot 'fixtures'
        $script:AuditFixtureDir = Join-Path $script:RepoRoot 'frame/audit-fixtures'
        $script:PortsDir = Join-Path $script:RepoRoot 'frame/ports'

        if (Test-Path $script:LibFile) {
            . $script:LibFile
        }

        # Run-phase re-population — see Get-FrameAuditReportVersionFixtures.
        $script:VersionFixtures = Get-FrameAuditReportVersionFixtures

        $script:TempRoot = Join-Path ([System.IO.Path]::GetTempPath()) "pester-frame-audit-report-$([System.Guid]::NewGuid().ToString('N'))"
        New-Item -ItemType Directory -Path $script:TempRoot -Force | Out-Null

        $script:NewWorkDir = {
            $dir = Join-Path $script:TempRoot ([System.Guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            return $dir
        }

        $script:WriteMockGh = {
            param(
                [string]$WorkDir,
                [string[]]$FixturePaths
            )

            $prListFile = Join-Path $WorkDir 'frame-pr-list.json'

            $fixtures = foreach ($fixturePath in $FixturePaths) {
                $fixture = Get-Content -Raw -Path $fixturePath | ConvertFrom-Json
                [ordered]@{
                    number   = [int]$fixture.number
                    mergedAt = [string]$fixture.mergedAt
                }
            }

            @($fixtures) | ConvertTo-Json -Depth 10 | Set-Content -Path $prListFile -Encoding UTF8

            $viewDispatch = @(
                foreach ($fixturePath in $FixturePaths) {
                    $fixture = Get-Content -Raw -Path $fixturePath | ConvertFrom-Json
                    "if (`$prNumber -eq {0}) {{ Get-Content -Raw -Path '{1}'; exit 0 }}" -f [int]$fixture.number, ($fixturePath -replace "'", "''")
                }
            ) -join [Environment]::NewLine

            $mockPath = Join-Path $WorkDir 'gh.ps1'
            @"
param()
if (`$args.Count -ge 2 -and `$args[0] -eq 'repo' -and `$args[1] -eq 'view') {
    Write-Output '{"nameWithOwner":"Grimblaz/agent-orchestra"}'
    exit 0
}
if (`$args.Count -ge 2 -and `$args[0] -eq 'pr' -and `$args[1] -eq 'list') {
    Get-Content -Raw -Path '$($prListFile -replace "'", "''")'
    exit 0
}
if (`$args.Count -ge 3 -and `$args[0] -eq 'pr' -and `$args[1] -eq 'view') {
    `$prNumber = [int]`$args[2]
$viewDispatch
}
Write-Error "Mock gh: unsupported command `$($args -join ' ')"
exit 99
"@ | Set-Content -Path $mockPath -Encoding UTF8

            return $mockPath
        }

        $script:RequireImplementation = {
            if (-not (Test-Path $script:LibFile)) {
                Set-ItResult -Skipped -Because 'frame-audit-report core library not implemented yet'
                return $false
            }

            if (-not (Get-Command Invoke-FrameAuditReport -ErrorAction SilentlyContinue)) {
                throw 'Missing implementation: Invoke-FrameAuditReport was not exported from frame-audit-report-core.ps1'
            }

            return $true
        }

        $script:Invoke = {
            param([hashtable]$Params)

            if (-not (& $script:RequireImplementation)) {
                return $null
            }

            return Invoke-FrameAuditReport @Params
        }

        $script:GetExpectedLedgerPath = {
            param([int]$PrNumber)

            return (Join-Path $script:AuditFixtureDir ("pr-{0}.expected.yaml" -f $PrNumber))
        }

        $script:ParseExpectedAuditFixture = {
            param([string]$Path)

            $fixture = [ordered]@{
                frame_version    = $null
                credits          = @()
                integrity_checks = @()
            }

            $section = ''
            $item = $null
            foreach ($rawLine in (Get-Content -Path $Path)) {
                $line = $rawLine.TrimEnd()

                if ($line -match '^frame_version:\s*(?<value>\d+)$') {
                    $fixture.frame_version = [int]$matches['value']
                    continue
                }

                if ($line -match '^(?<section>credits|integrity_checks):\s*$') {
                    if ($null -ne $item -and -not [string]::IsNullOrWhiteSpace($section)) {
                        $fixture[$section] = @($fixture[$section]) + , $item
                        $item = $null
                    }

                    $section = $matches['section']
                    continue
                }

                if ($line -match '^  - (?<key>port|name):\s*(?<value>.+)$') {
                    if ($null -ne $item -and -not [string]::IsNullOrWhiteSpace($section)) {
                        $fixture[$section] = @($fixture[$section]) + , $item
                    }

                    $item = [ordered]@{}
                    $item[$matches['key']] = $matches['value']
                    continue
                }

                if ($line -match '^    (?<key>status|evidence):\s*(?<value>.+)$') {
                    $value = $matches['value']
                    if ($value.Length -ge 2 -and $value.StartsWith('"') -and $value.EndsWith('"')) {
                        $value = $value.Substring(1, $value.Length - 2)
                        $value = $value -replace '\\\\', '\'
                        $value = $value -replace '\\"', '"'
                    }

                    $item[$matches['key']] = $value
                }
            }

            if ($null -ne $item -and -not [string]::IsNullOrWhiteSpace($section)) {
                $fixture[$section] = @($fixture[$section]) + , $item
            }

            return $fixture
        }

        $script:GetExpectedAudits = {
            param([object[]]$Fixtures)

            return @(
                foreach ($fixture in $Fixtures) {
                    $expectedLedgerPath = & $script:GetExpectedLedgerPath -PrNumber ([int]$fixture.PrNumber)
                    [ordered]@{
                        PrNumber = [int]$fixture.PrNumber
                        Audit    = (& $script:ParseExpectedAuditFixture -Path $expectedLedgerPath)
                    }
                }
            )
        }

        $script:GetExpectedBucketForStatus = {
            param([string]$Status)

            switch ($Status) {
                'passed' { return 'passed' }
                'failed' { return 'failed' }
                'not-applicable' { return 'N/A' }
                'skipped' { return 'skipped' }
                'inconclusive' { return 'inconclusive' }
                default { throw "Unsupported expected credit status '$Status'." }
            }
        }

        $script:AssertReportMatchesExpected = {
            param(
                $Report,
                [object[]]$ExpectedAudits,
                [int]$EraSplitPivotPr = 356
            )

            $ports = Get-FBDPortOrder -PortsDir $script:PortsDir
            $portMetadata = Get-FARPortMetadata -PortsDir $script:PortsDir -Ports $ports
            $expectedByEra = [ordered]@{
                'pre-pivot'  = [ordered]@{ PrNumbers = @(); PortStates = [ordered]@{} }
                'post-pivot' = [ordered]@{ PrNumbers = @(); PortStates = [ordered]@{} }
            }

            foreach ($eraKey in @('pre-pivot', 'post-pivot')) {
                foreach ($port in $ports) {
                    $expectedByEra[$eraKey].PortStates[$port] = [ordered]@{
                        applies     = [string]$portMetadata[$port].applies
                        port_status = [string]$portMetadata[$port].status
                        total       = 0
                        buckets     = [ordered]@{
                            passed       = 0
                            failed       = 0
                            'N/A'        = 0
                            skipped      = 0
                            inconclusive = 0
                            missing      = 0
                        }
                    }
                }
            }

            foreach ($entry in $ExpectedAudits) {
                $eraKey = if ([int]$entry.PrNumber -lt $EraSplitPivotPr) { 'pre-pivot' } else { 'post-pivot' }
                $expectedByEra[$eraKey].PrNumbers += [int]$entry.PrNumber

                foreach ($port in $ports) {
                    $portState = $expectedByEra[$eraKey].PortStates[$port]
                    $portState.total = [int]$portState.total + 1

                    $credit = @($entry.Audit.credits | Where-Object { $_.port -eq $port })[0]
                    if ($null -eq $credit) {
                        $portState.buckets['missing'] = [int]$portState.buckets['missing'] + 1
                        continue
                    }

                    $bucket = & $script:GetExpectedBucketForStatus -Status ([string]$credit.status)
                    $portState.buckets[$bucket] = [int]$portState.buckets[$bucket] + 1
                }
            }

            foreach ($eraKey in @('pre-pivot', 'post-pivot')) {
                $actualEra = @($Report['eras'] | Where-Object { $_['key'] -eq $eraKey })[0]
                $actualEra | Should -Not -BeNullOrEmpty
                $actualEra['pr_count'] | Should -Be $expectedByEra[$eraKey].PrNumbers.Count
                (($actualEra['pr_numbers']) -join ',') | Should -Be (($expectedByEra[$eraKey].PrNumbers) -join ',')

                foreach ($port in $ports) {
                    $actualPort = @($actualEra['ports'] | Where-Object { $_['port'] -eq $port })[0]
                    $actualPort | Should -Not -BeNullOrEmpty

                    $expectedPort = $expectedByEra[$eraKey].PortStates[$port]
                    $actualPort['applies'] | Should -Be $expectedPort.applies
                    $actualPort['port_status'] | Should -Be $expectedPort.port_status
                    $actualPort['total'] | Should -Be $expectedPort.total

                    foreach ($bucket in @('passed', 'failed', 'N/A', 'skipped', 'inconclusive', 'missing')) {
                        $actualPort['buckets'][$bucket] | Should -Be $expectedPort.buckets[$bucket]
                    }
                }
            }
        }

        $script:GetExpectedReportFromAudits = {
            param(
                [object[]]$ExpectedAudits,
                [int[]]$PrNumbers,
                [int]$EraSplitPivotPr = 356
            )

            $ports = Get-FBDPortOrder -PortsDir $script:PortsDir
            $portMetadata = Get-FARPortMetadata -PortsDir $script:PortsDir -Ports $ports
            $expectedByEra = [ordered]@{
                'pre-pivot'  = [ordered]@{ key = 'pre-pivot'; label = ('PRs < {0}' -f $EraSplitPivotPr); PrNumbers = @(); PortStates = [ordered]@{} }
                'post-pivot' = [ordered]@{ key = 'post-pivot'; label = ('PRs >= {0}' -f $EraSplitPivotPr); PrNumbers = @(); PortStates = [ordered]@{} }
            }

            foreach ($eraKey in @('pre-pivot', 'post-pivot')) {
                foreach ($port in $ports) {
                    $expectedByEra[$eraKey].PortStates[$port] = [ordered]@{
                        port        = $port
                        applies     = [string]$portMetadata[$port].applies
                        port_status = [string]$portMetadata[$port].status
                        total       = 0
                        buckets     = [ordered]@{
                            passed       = 0
                            failed       = 0
                            'N/A'        = 0
                            skipped      = 0
                            inconclusive = 0
                            missing      = 0
                        }
                    }
                }
            }

            foreach ($entry in $ExpectedAudits) {
                $eraKey = if ([int]$entry.PrNumber -lt $EraSplitPivotPr) { 'pre-pivot' } else { 'post-pivot' }
                $expectedByEra[$eraKey].PrNumbers += [int]$entry.PrNumber

                foreach ($port in $ports) {
                    $portState = $expectedByEra[$eraKey].PortStates[$port]
                    $portState.total = [int]$portState.total + 1

                    $credit = @($entry.Audit.credits | Where-Object { $_.port -eq $port })[0]
                    if ($null -eq $credit) {
                        $portState.buckets['missing'] = [int]$portState.buckets['missing'] + 1
                        continue
                    }

                    $bucket = & $script:GetExpectedBucketForStatus -Status ([string]$credit.status)
                    $portState.buckets[$bucket] = [int]$portState.buckets[$bucket] + 1
                }
            }

            $postPivotRecommendations = @(
                foreach ($port in $ports) {
                    $state = $expectedByEra['post-pivot'].PortStates[$port]
                    $missing = [int]$state.buckets['missing']
                    $inconclusive = [int]$state.buckets['inconclusive']
                    $skipped = [int]$state.buckets['skipped']

                    if ($state.port_status -ne 'stable') {
                        continue
                    }

                    if ($port -like 'ce-gate-*' -and $inconclusive -gt 0) {
                        continue
                    }

                    $score = (100 * $missing) + (10 * $inconclusive) + $skipped
                    if ($score -le 0) {
                        continue
                    }

                    [ordered]@{
                        port         = $port
                        score        = $score
                        missing      = $missing
                        inconclusive = $inconclusive
                        skipped      = $skipped
                        rationale    = ('post-pivot gaps for {0}: missing={1}, inconclusive={2}, skipped={3}.' -f $port, $missing, $inconclusive, $skipped)
                    }
                }
            ) | Sort-Object -Property @(
                @{ Expression = { [int]$_['score'] }; Descending = $true },
                @{ Expression = { [int]$_['missing'] }; Descending = $true },
                @{ Expression = { [int]$_['inconclusive'] }; Descending = $true },
                @{ Expression = { [int]$_['skipped'] }; Descending = $true },
                @{ Expression = { [string]$_['port'] }; Descending = $false }
            ) | Select-Object -First 3

            $tbdPorts = @(
                foreach ($port in $ports) {
                    $postState = $expectedByEra['post-pivot'].PortStates[$port]
                    if ($postState.port_status -eq 'stable') {
                        continue
                    }

                    $preState = $expectedByEra['pre-pivot'].PortStates[$port]
                    [ordered]@{
                        port             = $port
                        port_status      = $postState.port_status
                        applies          = $postState.applies
                        excluded_reason  = 'Excluded from recommendation ranking until the port status is decided.'
                        pre_pivot_total  = [int]$preState.total
                        post_pivot_total = [int]$postState.total
                    }
                }
            )

            $eras = @(
                foreach ($eraKey in @('pre-pivot', 'post-pivot')) {
                    [ordered]@{
                        key        = $expectedByEra[$eraKey].key
                        label      = $expectedByEra[$eraKey].label
                        pr_count   = $expectedByEra[$eraKey].PrNumbers.Count
                        pr_numbers = @($expectedByEra[$eraKey].PrNumbers)
                        ports      = @(
                            foreach ($port in $ports) {
                                $state = $expectedByEra[$eraKey].PortStates[$port]
                                [ordered]@{
                                    port        = $state.port
                                    applies     = $state.applies
                                    port_status = $state.port_status
                                    total       = [int]$state.total
                                    buckets     = [ordered]@{
                                        passed       = [int]$state.buckets['passed']
                                        failed       = [int]$state.buckets['failed']
                                        'N/A'        = [int]$state.buckets['N/A']
                                        skipped      = [int]$state.buckets['skipped']
                                        inconclusive = [int]$state.buckets['inconclusive']
                                        missing      = [int]$state.buckets['missing']
                                    }
                                }
                            }
                        )
                    }
                }
            )

            return [ordered]@{
                frame_audit_report_version = 1
                repo                       = 'Grimblaz/agent-orchestra'
                selection                  = [ordered]@{
                    pr_count           = @($PrNumbers).Count
                    pr_numbers         = @($PrNumbers)
                    since              = ''
                    era_split_pivot_pr = $EraSplitPivotPr
                }
                eras                       = $eras
                recommendations            = @($postPivotRecommendations)
                tbd_ports                  = @($tbdPorts)
            }
        }
    }

    AfterAll {
        if (Test-Path $script:TempRoot) {
            Remove-Item -Recurse -Force -Path $script:TempRoot -ErrorAction SilentlyContinue
        }
    }

    It 'ships the in-process frame-audit-report core library' {
        $script:LibFile | Should -Exist
    }

    It 'requests only PR selection fields and tolerates successful gh list stderr warnings' {
        if (-not (& $script:RequireImplementation)) {
            return
        }

        $workDir = & $script:NewWorkDir
        $argsFile = Join-Path $workDir 'pr-list-args.txt'
        $mockPath = Join-Path $workDir 'gh-list-warning.ps1'
        @"
param()
if (`$args.Count -ge 2 -and `$args[0] -eq 'pr' -and `$args[1] -eq 'list') {
    (`$args -join [Environment]::NewLine) | Set-Content -Path '$($argsFile -replace "'", "''")' -Encoding UTF8
    `$jsonIndex = [array]::IndexOf(`$args, '--json')
    if (`$jsonIndex -lt 0) {
        Write-Error 'Missing --json argument.'
        exit 87
    }

    if (`$args[`$jsonIndex + 1] -ne 'number,mergedAt') {
        Write-Error "Unexpected --json fields: `$(`$args[`$jsonIndex + 1])"
        exit 88
    }

    `$ErrorActionPreference = 'Continue'
    Write-Error 'gh warning on stderr'
    Write-Output '[{"number":451,"mergedAt":"2026-04-25T00:00:00Z"},{"number":449,"mergedAt":"2026-04-24T00:00:00Z"}]'
    exit 0
}
Write-Error "Mock gh: unsupported command `$(`$args -join ' ')"
exit 99
"@ | Set-Content -Path $mockPath -Encoding UTF8

        $selected = Get-FARSelectedPrNumbers -PrCount 2 -PrList ([int[]]@()) -Repo 'Grimblaz/agent-orchestra' -GhCliPath $mockPath

        ($selected -join ',') | Should -Be '451,449'
        $argsText = Get-Content -Raw -Path $argsFile
        $argsText | Should -Match '(?m)^number,mergedAt\r?$'
        $argsText | Should -Not -Match '(?m)^title\r?$'
        $argsText | Should -Not -Match '(?m)^body\r?$'
    }

    It 'aggregates a fixture window containing metrics_version <MetricsVersion>' -ForEach $script:VersionFixtures {
        param($MetricsVersion, $PrNumber, $FixtureFile)

        $workDir = & $script:NewWorkDir
        $fixturePath = Join-Path $script:FixtureDir $FixtureFile
        $ghPath = & $script:WriteMockGh -WorkDir $workDir -FixturePaths @($fixturePath)

        $result = & $script:Invoke @{
            Repo         = 'Grimblaz/agent-orchestra'
            PrList       = @($PrNumber)
            OutputFormat = 'json'
            GhCliPath    = $ghPath
            PortsDir     = $script:PortsDir
            CacheDir     = (Join-Path $workDir 'cache')
        }

        if ($null -eq $result) {
            return
        }

        $result.ExitCode | Should -Be 0 -Because "audit reporting should stay compatible with metrics_version $MetricsVersion"
        $report = $result.Output | ConvertFrom-Json -AsHashtable
        $report['selection']['pr_count'] | Should -Be 1
        (($report['selection']['pr_numbers']) -join ',') | Should -Be ([string]$PrNumber)
        & $script:AssertReportMatchesExpected -Report $report -ExpectedAudits (& $script:GetExpectedAudits -Fixtures @([ordered]@{ PrNumber = $PrNumber }))
    }

    It 'replays the judged historical fixture window into stable era buckets and deterministic renders' {
        if (-not (& $script:RequireImplementation)) {
            return
        }

        $prList = @($script:VersionFixtures | ForEach-Object { [int]$_.PrNumber })
        $report = & $script:GetExpectedReportFromAudits -ExpectedAudits (& $script:GetExpectedAudits -Fixtures $script:VersionFixtures) -PrNumbers $prList
        $report['selection']['pr_count'] | Should -Be 4
        (($report['selection']['pr_numbers']) -join ',') | Should -Be '286,338,415,411'

        (($report['recommendations'] | ForEach-Object { $_['port'] }) -join ',') | Should -Be 'design,plan,review'
        (($report['recommendations'] | ForEach-Object { [string]$_['score'] }) -join ',') | Should -Be '20,20,20'
        $report['tbd_ports'].Count | Should -Be 1
        $report['tbd_ports'][0]['port'] | Should -Be 'process-retrospective'
        $report['tbd_ports'][0]['port_status'] | Should -Be 'formalized-skeleton-deferred-to-348'
        $report['tbd_ports'][0]['pre_pivot_total'] | Should -Be 2
        $report['tbd_ports'][0]['post_pivot_total'] | Should -Be 2

        $textOutput = ConvertTo-FARText -Report $report
        $textOutput | Should -Match '(?m)^Frame audit report \(audit-only\)\r?$'
        $textOutput | Should -Match '(?m)^PRs < 356 \(2 PRs\)\r?$'
        $textOutput | Should -Match '(?m)^design \| 0 \| 0 \| 0 \| 0 \| 2 \| 0\r?$'
        $textOutput | Should -Match '(?m)^review \| 2 \| 0 \| 0 \| 0 \| 0 \| 0\r?$'
        $textOutput | Should -Match '(?m)^- process-retrospective \(formalized-skeleton-deferred-to-348\)\r?$'
        $textOutput | Should -Match '(?m)^- design: score=20; missing=0; inconclusive=2; skipped=0\r?$'
        $textOutput | Should -Match '(?m)^- plan: score=20; missing=0; inconclusive=2; skipped=0\r?$'
        $textOutput | Should -Match '(?m)^- review: score=20; missing=0; inconclusive=2; skipped=0\r?$'

        $markdownOutput = ConvertTo-FARMarkdown -Report $report
        $markdownOutput | Should -Match '(?m)^# Frame Audit Report\r?$'
        $markdownOutput | Should -Match '(?m)^## PRs >= 356 \(2 PRs\)\r?$'
        $markdownOutput | Should -Match '(?m)^\| design \| 0 \| 0 \| 0 \| 0 \| 2 \| 0 \|\r?$'
        $markdownOutput | Should -Match '(?m)^- process-retrospective \(formalized-skeleton-deferred-to-348\)\r?$'
        $markdownOutput | Should -Match '(?m)^- design: score=20; missing=0; inconclusive=2; skipped=0\r?$'
    }

    It 'keeps CE surface ambiguity historical without ranking it as actionable noise' {
        if (-not (& $script:RequireImplementation)) {
            return
        }

        $ports = Get-FBDPortOrder -PortsDir $script:PortsDir
        $portMetadata = Get-FARPortMetadata -PortsDir $script:PortsDir -Ports $ports
        $postPivot = New-FAREraState -Key 'post-pivot' -Label 'PRs >= 356' -Ports $ports -PortMetadata $portMetadata

        foreach ($port in @('ce-gate-cli', 'ce-gate-browser', 'ce-gate-canvas', 'ce-gate-api', 'design', 'implement-code', 'post-pr')) {
            $postPivot.ports[$port].total = 1
            $postPivot.ports[$port].buckets['inconclusive'] = 1
        }

        $recommendationPorts = @(Get-FARRecommendations -EraState $postPivot -Ports $ports | ForEach-Object { $_.port })

        foreach ($port in @('ce-gate-cli', 'ce-gate-browser', 'ce-gate-canvas', 'ce-gate-api')) {
            $postPivot.ports[$port].buckets['inconclusive'] | Should -Be 1
        }
        (@($recommendationPorts | Where-Object { $_ -like 'ce-gate-*' })).Count | Should -Be 0
        $recommendationPorts | Should -Contain 'design'
    }

    It 'keeps mixed CE surface ambiguity out of the top recommendations' {
        if (-not (& $script:RequireImplementation)) {
            return
        }

        $ports = Get-FBDPortOrder -PortsDir $script:PortsDir
        $portMetadata = Get-FARPortMetadata -PortsDir $script:PortsDir -Ports $ports
        $postPivot = New-FAREraState -Key 'post-pivot' -Label 'PRs >= 356' -Ports $ports -PortMetadata $portMetadata

        foreach ($port in @('ce-gate-cli', 'ce-gate-browser', 'ce-gate-canvas', 'ce-gate-api')) {
            $postPivot.ports[$port].total = 3
            $postPivot.ports[$port].buckets['missing'] = 1
            $postPivot.ports[$port].buckets['inconclusive'] = 2
        }

        foreach ($port in @('design', 'implement-code', 'implement-docs')) {
            $postPivot.ports[$port].total = 3
            $postPivot.ports[$port].buckets['inconclusive'] = 2
        }

        $recommendationPorts = @(Get-FARRecommendations -EraState $postPivot -Ports $ports | ForEach-Object { $_.port })

        $recommendationPorts | Should -Be @('design', 'implement-code', 'implement-docs')
    }

    It 'maps failed credits into a distinct report bucket instead of missing' {
        Get-FARBucketForCreditStatus -Status 'failed' | Should -Be 'failed'

        $ports = Get-FBDPortOrder -PortsDir $script:PortsDir
        $portMetadata = Get-FARPortMetadata -PortsDir $script:PortsDir -Ports $ports
        $era = New-FAREraState -Key 'post-pivot' -Label 'PRs >= 356' -Ports $ports -PortMetadata $portMetadata

        Add-FARCreditToEra -EraState $era -Ports $ports -AuditSurface ([ordered]@{
                credits = @(
                    [ordered]@{
                        port     = 'design'
                        status   = 'failed'
                        evidence = 'Synthetic smoke credit.'
                    }
                )
            })

        $output = ConvertTo-FAREraOutput -EraState $era -Ports $ports
        $design = @($output.ports | Where-Object { $_.port -eq 'design' })[0]

        $design.buckets.failed | Should -Be 1
        $design.buckets.missing | Should -Be 0
    }

    It 'warns and skips unrecognized live credit statuses instead of crashing the audit' {
        # Live PR data can carry non-conformant statuses (e.g. 'harvested-from-issue'
        # on PR #627) that no builder in this repo emits. The audit must never crash
        # on such a row; it warns and buckets the status as 'inconclusive'.
        { Get-FARBucketForCreditStatus -Status 'harvested-from-issue' -WarningAction SilentlyContinue } |
            Should -Not -Throw
        { Get-FARBucketForCreditStatus -Status 'made-up-status' -WarningAction SilentlyContinue } |
            Should -Not -Throw
        { Get-FARBucketForCreditStatus -Status '' -WarningAction SilentlyContinue } |
            Should -Not -Throw

        (Get-FARBucketForCreditStatus -Status 'harvested-from-issue' -WarningAction SilentlyContinue) |
            Should -Be 'inconclusive'
        (Get-FARBucketForCreditStatus -Status 'made-up-status' -Port 'design' -WarningAction SilentlyContinue) |
            Should -Be 'inconclusive'

        # Known statuses keep their existing buckets.
        Get-FARBucketForCreditStatus -Status 'passed' | Should -Be 'passed'
        Get-FARBucketForCreditStatus -Status 'not-applicable' | Should -Be 'N/A'
        Get-FARBucketForCreditStatus -Status 'skipped' | Should -Be 'skipped'
        Get-FARBucketForCreditStatus -Status 'inconclusive' | Should -Be 'inconclusive'
    }

    It 'supports a live audit window shape for later CE evidence capture' -Tag 'requires-gh' {
        if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
            Set-ItResult -Skipped -Because 'gh CLI not found'
            return
        }

        if (-not (& $script:RequireImplementation)) {
            return
        }

        $workDir = & $script:NewWorkDir
        $result = & $script:Invoke @{
            Repo         = 'Grimblaz/agent-orchestra'
            PrCount      = 30
            OutputFormat = 'json'
            GhCliPath    = 'gh'
            PortsDir     = $script:PortsDir
            CacheDir     = (Join-Path $workDir 'cache')
            NoCache      = $true
        }

        $result.ExitCode | Should -Be 0 -Because "live audit window should succeed. Error: $($result.Error)"

        $defaultRender = & $script:Invoke @{
            Repo      = 'Grimblaz/agent-orchestra'
            PrCount   = 30
            GhCliPath = 'gh'
            PortsDir  = $script:PortsDir
            CacheDir  = (Join-Path $workDir 'cache-default-text')
            NoCache   = $true
        }

        $defaultRender.ExitCode | Should -Be 0 -Because "live audit window default render should succeed. Error: $($defaultRender.Error)"
        $defaultRender.Output | Should -Match '(?m)^Frame audit report \(audit-only\)\r?$'
        $defaultRender.Output | Should -Match '(?m)^Top post-pivot recommendations\r?$'
        $defaultRender.Output | Should -Not -Match '^\s*\{'
    }
}
