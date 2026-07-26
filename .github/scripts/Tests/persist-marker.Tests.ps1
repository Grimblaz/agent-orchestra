#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
    RED-phase Pester suite for the s6 additions to persist-marker-core.ps1
    (issue #893, plan slice s6): scratch-root path bounding, the GitHub
    65,536-char comment-cap size refusal, and ordered multi-write burst
    support (Invoke-PersistMarkerBurst / Invoke-PersistMarkerBurstFromManifest).

.DESCRIPTION
    Named after the thin wrapper this slice creates
    (skills/session-memory-contract/scripts/persist-marker.ps1), mirroring
    persist-phase-ledger.Tests.ps1's own naming/testing convention: that
    file is also named after its wrapper but dot-sources and exercises the
    CORE file directly (the wrapper itself is too thin -- dot-source, one
    call, output formatting -- to warrant its own tests; `pwsh -File` /
    call-operator invocation-shape coverage for the wrapper is s7's job per
    the plan's step-s7 requirement contract, not this slice's).

    Dot-sources the REAL, already-shipped primitives
    (.github/scripts/lib/marker-transport-core.ps1,
    .github/scripts/lib/frame-engagement-record-core.ps1,
    .github/scripts/lib/frame-spine-core.ps1) and the persist-marker-core.ps1
    core file, mocking only the true external seam (`gh`) -- matching the
    convention already established by persist-marker-core.Tests.ps1. Per
    that same convention: when the s6 additions do not exist yet, a
    CommandNotFoundException at the Act line is itself the sanctioned RED
    signal.

    Covers the slice s6 Requirement Contract (ac-refs AC4, AC12): burst
    ordering, whole-manifest preflight blocking ALL writes on any single
    invalid entry, halt-on-first-failure during execution, re-run
    convergence after a mid-burst halt (no duplicate posts), scratch-root
    path bounding for both single -BodyFile and manifest bodyFile entries
    (via real path-containment, not string-prefix matching), and the
    GitHub comment size-cap refusal.
#>

BeforeDiscovery {
    $script:CoreLibPath = Join-Path $PSScriptRoot '../../../skills/session-memory-contract/scripts/persist-marker-core.ps1'
}

Describe 'persist-marker burst + scratch-root bounding (s6)' {
    BeforeAll {
        $script:CoreLibPath = Join-Path $PSScriptRoot '../../../skills/session-memory-contract/scripts/persist-marker-core.ps1'
        $script:MarkerTransportLibPath = Join-Path $PSScriptRoot '../lib/marker-transport-core.ps1'
        $script:EngagementRecordLibPath = Join-Path $PSScriptRoot '../lib/frame-engagement-record-core.ps1'
        $script:FrameSpineLibPath = Join-Path $PSScriptRoot '../lib/frame-spine-core.ps1'
        $script:Owner = 'Grimblaz'
        $script:Repo = 'agent-orchestra'
        $script:IssueNumber = 893

        $script:CreditInputValidYaml = @'
```yaml
port: plan
adapter: skills/plan-authoring/adapters/plan-adapter.md
evidence: issue-893-plan-marker-posted
```
'@
        $script:CreditInputInvalidPortYaml = @'
```yaml
port: bogus-port
adapter: skills/plan-authoring/adapters/plan-adapter.md
evidence: issue-893-plan-marker-posted
```
'@
    }

    BeforeEach {
        # --- Simulated GitHub comment store (mutable across gh calls), same
        # shape as persist-marker-core.Tests.ps1's own mock. ---
        $script:mockComments = [System.Collections.Generic.List[object]]::new()
        $script:NextCommentId = 90000
        $script:ghCallLog = [System.Collections.Generic.List[string]]::new()
        $script:PatchLog = [System.Collections.Generic.List[object]]::new()
        $script:PostLog = [System.Collections.Generic.List[object]]::new()
        $script:CorruptReadBackIds = [System.Collections.Generic.HashSet[long]]::new()

        function script:Add-MockComment {
            param([Parameter(Mandatory)][long]$Id, [Parameter(Mandatory)][string]$Body)
            $url = "https://github.com/$script:Owner/$script:Repo/issues/$script:IssueNumber#issuecomment-$Id"
            $script:mockComments.Add([PSCustomObject]@{ Id = $Id; body = $Body; url = $url })
        }

        function global:gh {
            param([Parameter(ValueFromRemainingArguments = $true)]$Args)
            $joined = $Args -join ' '
            $script:ghCallLog.Add($joined)

            if ($joined -match '^api --paginate repos/[^/]+/[^/]+/issues/\d+/comments$') {
                $payload = @($script:mockComments | ForEach-Object {
                        @{ id = $_.Id; body = $_.body; url = $_.url }
                    }) | ConvertTo-Json -Depth 8
                $global:LASTEXITCODE = 0
                return $payload
            }

            if ($Args.Count -ge 2 -and $Args[0] -eq 'api' -and $Args[1] -match '^repos/[^/]+/[^/]+/issues/comments/(\d+)$' -and ($Args -notcontains '-X')) {
                $id = [long]$Matches[1]
                $c = $script:mockComments | Where-Object { $_.Id -eq $id }
                if (-not $c) { $global:LASTEXITCODE = 1; return '' }
                $global:LASTEXITCODE = 0
                $returnedBody = $c.body
                if ($script:CorruptReadBackIds.Contains($id)) {
                    $returnedBody = $returnedBody -replace 'e', "ë"
                }
                return (@{ id = $c.Id; body = $returnedBody; url = $c.url } | ConvertTo-Json -Depth 8)
            }

            if ($joined -match '^api -X PATCH repos/[^/]+/[^/]+/issues/comments/(\d+) --input') {
                $id = [long]$Matches[1]
                $inputIdx = [Array]::IndexOf($Args, '--input')
                $filePath = $Args[$inputIdx + 1]
                $payloadObj = Get-Content -LiteralPath $filePath -Raw | ConvertFrom-Json
                $newBody = [string]$payloadObj.body
                $existing = $script:mockComments | Where-Object { $_.Id -eq $id }
                if ($existing) { $existing.body = $newBody } else { Add-MockComment -Id $id -Body $newBody }
                $script:PatchLog.Add([PSCustomObject]@{ CommentId = $id; Body = $newBody })
                $global:LASTEXITCODE = 0
                return (@{ html_url = "https://github.com/$script:Owner/$script:Repo/issues/$script:IssueNumber#issuecomment-$id" } | ConvertTo-Json)
            }

            if ($joined -match '^(issue|pr) comment \d+ --body') {
                $newId = $script:NextCommentId
                $script:NextCommentId++
                $bodyIdx = [Array]::IndexOf($Args, '--body')
                $bodyText = $Args[$bodyIdx + 1]
                Add-MockComment -Id $newId -Body $bodyText
                $script:PostLog.Add([PSCustomObject]@{ Body = $bodyText })
                $global:LASTEXITCODE = 0
                return "https://github.com/$script:Owner/$script:Repo/issues/$script:IssueNumber#issuecomment-$newId"
            }

            $global:LASTEXITCODE = 0
            return ''
        }

        if (Test-Path $script:MarkerTransportLibPath) { . $script:MarkerTransportLibPath }
        if (Test-Path $script:EngagementRecordLibPath) { . $script:EngagementRecordLibPath }
        if (Test-Path $script:FrameSpineLibPath) { . $script:FrameSpineLibPath }
        if (Test-Path $script:CoreLibPath) { . $script:CoreLibPath }

        if (Test-Path $script:CoreLibPath) {
            $script:GoodFamilyA = @(Get-MarkerFamilyRegistry | Where-Object { $_.Family -eq 'experience-owner-complete' })[0]
            $script:CreditInputFamily = @(Get-MarkerFamilyRegistry | Where-Object { $_.Family -eq 'credit-input' })[0]
        }

        # --- Isolated scratch root under Pester's per-test TestDrive. ---
        $script:ScratchRoot = Join-Path $TestDrive '.tmp'
        New-Item -ItemType Directory -Path $script:ScratchRoot -Force | Out-Null

        function script:New-ScratchBodyFile {
            param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Content)
            $path = Join-Path $script:ScratchRoot $Name
            [System.IO.File]::WriteAllText($path, $Content)
            return $path
        }

        function script:New-ManifestFile {
            param([Parameter(Mandatory)][object[]]$Entries, [string]$Name = 'burst.json')
            $path = Join-Path $script:ScratchRoot $Name
            (ConvertTo-Json -InputObject $Entries -Depth 10 -AsArray) | Set-Content -LiteralPath $path
            return $path
        }
    }

    AfterEach {
        Remove-Item Function:gh -ErrorAction SilentlyContinue
    }

    Context 'Resolve-MarkerScratchBoundedPath / Read-MarkerScratchBoundedBodyFile: real path containment' {
        It 'accepts a bodyFile that resolves inside the scratch root' {
            $inside = script:New-ScratchBodyFile -Name 'ok.md' -Content 'hello'

            $result = Read-MarkerScratchBoundedBodyFile -BodyFile $inside -ScratchRoot $script:ScratchRoot

            $result.Success | Should -Be $true
            $result.Body | Should -Be 'hello'
        }

        It 'refuses a bodyFile outside the scratch root, naming the resolved path' {
            $outside = Join-Path $TestDrive 'outside.md'
            [System.IO.File]::WriteAllText($outside, 'evil')

            $result = Read-MarkerScratchBoundedBodyFile -BodyFile $outside -ScratchRoot $script:ScratchRoot

            $result.Success | Should -Be $false
            $result.Reason | Should -Match '(?i)scratch root'
            $result.Reason | Should -Match ([regex]::Escape('outside.md'))
        }

        It 'refuses a bodyFile whose raw string carries a same-prefix sibling directory, not real containment (spoof guard)' {
            # '.tmp-not-really' shares the '.tmp' STRING prefix with the real
            # scratch root but is a different, sibling directory -- a naive
            # string-prefix test would wrongly admit it.
            $spoofRoot = "$script:ScratchRoot-not-really"
            New-Item -ItemType Directory -Path $spoofRoot -Force | Out-Null
            $spoofFile = Join-Path $spoofRoot 'spoof.md'
            [System.IO.File]::WriteAllText($spoofFile, 'spoofed')

            $result = Read-MarkerScratchBoundedBodyFile -BodyFile $spoofFile -ScratchRoot $script:ScratchRoot

            $result.Success | Should -Be $false
            $result.Reason | Should -Match '(?i)scratch root'
        }

        It 'refuses a bodyFile path that does not exist' {
            $missing = Join-Path $script:ScratchRoot 'does-not-exist.md'

            $result = Read-MarkerScratchBoundedBodyFile -BodyFile $missing -ScratchRoot $script:ScratchRoot

            $result.Success | Should -Be $false
            $result.Reason | Should -Match '(?i)does not exist'
        }
    }

    Context 'Invoke-PersistMarkerWrite: size cap' {
        It 'refuses a composed body exceeding the 65536-char GitHub comment cap, with a diagnosable message, before any network write' {
            $marker = $script:GoodFamilyA.MarkerTemplate -replace '\{ID\}', "$script:IssueNumber"
            $oversized = $marker + "`n`n" + ('a' * 70000)

            $result = Invoke-PersistMarkerWrite -Family $script:GoodFamilyA.Family -Owner $script:Owner -Repo $script:Repo -Number $script:IssueNumber -TargetSurface 'issue' -Marker $marker -Body $oversized

            $result.Success | Should -Be $false
            $result.Reason | Should -Match '65,?536'
            $script:PostLog.Count | Should -Be 0
            $script:PatchLog.Count | Should -Be 0
        }
    }

    Context 'Invoke-PersistMarkerBurst: whole-manifest preflight' {
        It 'writes ZERO comments when one entry among several valid ones fails preflight' {
            $markerA = $script:GoodFamilyA.MarkerTemplate -replace '\{ID\}', "$script:IssueNumber"
            $markerCredit = $script:CreditInputFamily.MarkerTemplate -replace '\{port\}', 'plan' -replace '\{ID\}', "$script:IssueNumber"

            $entries = @(
                [PSCustomObject]@{ Family = $script:GoodFamilyA.Family; Number = $script:IssueNumber; TargetSurface = 'issue'; Marker = $markerA; Body = "$markerA`n`nGood entry one."; NoPreserve = $false }
                [PSCustomObject]@{ Family = $script:CreditInputFamily.Family; Number = $script:IssueNumber; TargetSurface = 'issue'; Marker = $markerCredit; Body = "$markerCredit`n`n$script:CreditInputInvalidPortYaml"; NoPreserve = $false }
                [PSCustomObject]@{ Family = $script:GoodFamilyA.Family; Number = $script:IssueNumber; TargetSurface = 'issue'; Marker = $markerA; Body = "$markerA`n`nGood entry three."; NoPreserve = $false }
            )

            $result = Invoke-PersistMarkerBurst -Owner $script:Owner -Repo $script:Repo -Entries $entries

            $result.Success | Should -Be $false
            $script:PostLog.Count | Should -Be 0
            $script:PatchLog.Count | Should -Be 0
            $result.Artifacts['entry-1'] | Should -Be 'not-attempted'
            $result.Artifacts['entry-2'] | Should -Be 'not-attempted'
            $result.Artifacts['entry-3'] | Should -Be 'not-attempted'
        }
    }

    Context 'Invoke-PersistMarkerBurst: ordering + halt-on-first-failure' {
        It 'writes entries in manifest order' {
            $markerA = $script:GoodFamilyA.MarkerTemplate -replace '\{ID\}', "$script:IssueNumber"
            $entries = @(
                [PSCustomObject]@{ Family = $script:GoodFamilyA.Family; Number = $script:IssueNumber; TargetSurface = 'issue'; Marker = $markerA; Body = "$markerA`n`nFirst body marker-A-1."; NoPreserve = $false }
                [PSCustomObject]@{ Family = $script:GoodFamilyA.Family; Number = $script:IssueNumber; TargetSurface = 'issue'; Marker = $markerA; Body = "$markerA`n`nSecond body marker-A-2."; NoPreserve = $false }
                [PSCustomObject]@{ Family = $script:GoodFamilyA.Family; Number = $script:IssueNumber; TargetSurface = 'issue'; Marker = $markerA; Body = "$markerA`n`nThird body marker-A-3."; NoPreserve = $false }
            )

            $result = Invoke-PersistMarkerBurst -Owner $script:Owner -Repo $script:Repo -Entries $entries

            $result.Success | Should -Be $true
            $script:PostLog.Count | Should -Be 3
            $script:PostLog[0].Body | Should -Match 'marker-A-1'
            $script:PostLog[1].Body | Should -Match 'marker-A-2'
            $script:PostLog[2].Body | Should -Match 'marker-A-3'
        }

        It 'halts at the first execution failure and never attempts a later entry' {
            $markerA = $script:GoodFamilyA.MarkerTemplate -replace '\{ID\}', "$script:IssueNumber"
            # entry 2's freshly-assigned comment id (NextCommentId starts at
            # 90000; entry 1 consumes 90000, entry 2 consumes 90001) is
            # corrupted at read-back time -- an EXECUTION-time failure, not a
            # preflight one (the payload itself is clean).
            $script:CorruptReadBackIds.Add(90001) | Out-Null

            $entries = @(
                [PSCustomObject]@{ Family = $script:GoodFamilyA.Family; Number = $script:IssueNumber; TargetSurface = 'issue'; Marker = $markerA; Body = "$markerA`n`nEntry one, several e characters."; NoPreserve = $false }
                [PSCustomObject]@{ Family = $script:GoodFamilyA.Family; Number = $script:IssueNumber; TargetSurface = 'issue'; Marker = $markerA; Body = "$markerA`n`nEntry two, several e characters."; NoPreserve = $false }
                [PSCustomObject]@{ Family = $script:GoodFamilyA.Family; Number = $script:IssueNumber; TargetSurface = 'issue'; Marker = $markerA; Body = "$markerA`n`nEntry three, never attempted."; NoPreserve = $false }
            )

            $result = Invoke-PersistMarkerBurst -Owner $script:Owner -Repo $script:Repo -Entries $entries

            $result.Success | Should -Be $false
            $result.Artifacts['entry-1'] | Should -Be 'landed'
            $result.Artifacts['entry-2'] | Should -Be 'failed'
            $result.Artifacts['entry-3'] | Should -Be 'not-attempted'
            $script:PostLog.Count | Should -Be 2
            ($script:PostLog | Where-Object { $_.Body -match 'Entry three' }).Count | Should -Be 0
        }
    }

    Context 'Invoke-PersistMarkerBurst: re-run convergence after a mid-burst halt' {
        It 'a re-run of the same manifest converges without duplicate posts' {
            # Distinct markers per entry (varying {ID}) -- a realistic burst
            # manifest targets one marker per entry; post-new's idempotency
            # comparison is scoped to a SINGLE marker's own latest match, so
            # reusing one marker across multiple entries would defeat that
            # comparison entirely (each entry would always differ from
            # whatever the PRIOR entry just posted under the same marker).
            $markerOne = $script:GoodFamilyA.MarkerTemplate -replace '\{ID\}', "$script:IssueNumber"
            $markerTwo = $script:GoodFamilyA.MarkerTemplate -replace '\{ID\}', "$($script:IssueNumber + 1)"
            $markerThree = $script:GoodFamilyA.MarkerTemplate -replace '\{ID\}', "$($script:IssueNumber + 2)"
            $script:CorruptReadBackIds.Add(90001) | Out-Null

            $entries = @(
                [PSCustomObject]@{ Family = $script:GoodFamilyA.Family; Number = $script:IssueNumber; TargetSurface = 'issue'; Marker = $markerOne; Body = "$markerOne`n`nConverge entry one."; NoPreserve = $false }
                [PSCustomObject]@{ Family = $script:GoodFamilyA.Family; Number = ($script:IssueNumber + 1); TargetSurface = 'issue'; Marker = $markerTwo; Body = "$markerTwo`n`nConverge entry two."; NoPreserve = $false }
                [PSCustomObject]@{ Family = $script:GoodFamilyA.Family; Number = ($script:IssueNumber + 2); TargetSurface = 'issue'; Marker = $markerThree; Body = "$markerThree`n`nConverge entry three."; NoPreserve = $false }
            )

            $firstRun = Invoke-PersistMarkerBurst -Owner $script:Owner -Repo $script:Repo -Entries $entries
            $firstRun.Success | Should -Be $false
            $script:PostLog.Count | Should -Be 2

            # Second run: entry 1's and entry 2's marker+body already exist
            # verbatim in the mock store (post-new compares against each
            # marker's own LATEST match) -- entry 2's real POST landed in
            # the store even though the first run reported it as failed
            # (only the read-back verification failed, not the POST
            # itself), so this is a genuine convergence check, not a
            # re-corrupted retry.
            $secondRun = Invoke-PersistMarkerBurst -Owner $script:Owner -Repo $script:Repo -Entries $entries

            $secondRun.Success | Should -Be $true
            $secondRun.Artifacts['entry-1'] | Should -Be 'landed'
            $secondRun.Artifacts['entry-2'] | Should -Be 'landed'
            $secondRun.Artifacts['entry-3'] | Should -Be 'landed'
            # No duplicate posts across BOTH runs: entry 1 + entry 2 posted
            # once each during the first run; entry 3 posted once during the
            # second run. Total = 3, never 5 or 6.
            $script:PostLog.Count | Should -Be 3
        }
    }

    Context 'Invoke-PersistMarkerBurstFromManifest: manifest parsing + malformed refusal' {
        It 'refuses a manifest file that is not parseable JSON, naming the manifest path' {
            $manifestPath = Join-Path $script:ScratchRoot 'bad.json'
            [System.IO.File]::WriteAllText($manifestPath, '{ not valid json ][')

            $result = Invoke-PersistMarkerBurstFromManifest -Owner $script:Owner -Repo $script:Repo -ManifestPath $manifestPath -ScratchRoot $script:ScratchRoot

            $result.Success | Should -Be $false
            $result.Reason | Should -Match '(?i)malformed manifest'
            $result.Reason | Should -Match ([regex]::Escape($manifestPath))
        }

        It 'refuses a manifest entry missing a required field, naming the entry index and field' {
            $markerA = $script:GoodFamilyA.MarkerTemplate -replace '\{ID\}', "$script:IssueNumber"
            $bodyPath = script:New-ScratchBodyFile -Name 'body1.md' -Content "$markerA`n`nBody."
            $entries = @(
                @{ family = $script:GoodFamilyA.Family; number = $script:IssueNumber; targetSurface = 'issue'; marker = $markerA; bodyFile = $bodyPath }
                @{ family = $script:GoodFamilyA.Family; number = $script:IssueNumber; targetSurface = 'issue'; bodyFile = $bodyPath }
            )
            $manifestPath = script:New-ManifestFile -Entries $entries

            $result = Invoke-PersistMarkerBurstFromManifest -Owner $script:Owner -Repo $script:Repo -ManifestPath $manifestPath -ScratchRoot $script:ScratchRoot

            $result.Success | Should -Be $false
            $result.Reason | Should -Match '(?i)entry 2'
            $result.Reason | Should -Match '(?i)marker'
            $script:PostLog.Count | Should -Be 0
        }

        It 'refuses a manifest whose bodyFile resolves outside the scratch root' {
            $markerA = $script:GoodFamilyA.MarkerTemplate -replace '\{ID\}', "$script:IssueNumber"
            $outsideBody = Join-Path $TestDrive 'outside-body.md'
            [System.IO.File]::WriteAllText($outsideBody, "$markerA`n`nBody.")
            $entries = @(
                @{ family = $script:GoodFamilyA.Family; number = $script:IssueNumber; targetSurface = 'issue'; marker = $markerA; bodyFile = $outsideBody }
            )
            $manifestPath = script:New-ManifestFile -Entries $entries

            $result = Invoke-PersistMarkerBurstFromManifest -Owner $script:Owner -Repo $script:Repo -ManifestPath $manifestPath -ScratchRoot $script:ScratchRoot

            $result.Success | Should -Be $false
            $result.Reason | Should -Match '(?i)scratch root'
            $script:PostLog.Count | Should -Be 0
        }

        It 'resolves entries and executes an end-to-end burst for a valid manifest' {
            $markerA = $script:GoodFamilyA.MarkerTemplate -replace '\{ID\}', "$script:IssueNumber"
            $bodyPath = script:New-ScratchBodyFile -Name 'valid-body.md' -Content "$markerA`n`nEnd-to-end burst body."
            $entries = @(
                @{ family = $script:GoodFamilyA.Family; number = $script:IssueNumber; targetSurface = 'issue'; marker = $markerA; bodyFile = $bodyPath }
            )
            $manifestPath = script:New-ManifestFile -Entries $entries

            $result = Invoke-PersistMarkerBurstFromManifest -Owner $script:Owner -Repo $script:Repo -ManifestPath $manifestPath -ScratchRoot $script:ScratchRoot

            $result.Success | Should -Be $true
            $script:PostLog.Count | Should -Be 1
            $result.Artifacts['entry-1'] | Should -Be 'landed'
        }
    }
}
