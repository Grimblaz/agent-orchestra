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
        $script:PaginateFailureNumbers = [System.Collections.Generic.HashSet[int]]::new()
        $script:simulateTransientGetFailure = @()

        function script:Add-MockComment {
            param([Parameter(Mandatory)][long]$Id, [Parameter(Mandatory)][string]$Body)
            $url = "https://github.com/$script:Owner/$script:Repo/issues/$script:IssueNumber#issuecomment-$Id"
            $script:mockComments.Add([PSCustomObject]@{ Id = $Id; body = $Body; url = $url })
        }

        function global:gh {
            param([Parameter(ValueFromRemainingArguments = $true)]$Args)
            $joined = $Args -join ' '
            $script:ghCallLog.Add($joined)

            if ($joined -match '^api --paginate repos/[^/]+/[^/]+/issues/(\d+)/comments$') {
                if ($script:PaginateFailureNumbers -and $script:PaginateFailureNumbers.Contains([int]$Matches[1])) {
                    $global:LASTEXITCODE = 1
                    return ''
                }
                $payload = @($script:mockComments | ForEach-Object {
                        @{ id = $_.Id; body = $_.body; url = $_.url }
                    }) | ConvertTo-Json -Depth 8
                $global:LASTEXITCODE = 0
                return $payload
            }

            if ($Args.Count -ge 2 -and $Args[0] -eq 'api' -and $Args[1] -match '^repos/[^/]+/[^/]+/issues/comments/(\d+)$' -and ($Args -notcontains '-X')) {
                $id = [long]$Matches[1]
                # M19 (issue #893 s11): a TRANSIENT failure (network blip) is
                # distinguishable from a confirmed HTTP 404 absence by
                # message text, mirroring real `gh api` behavior.
                # simulateTransientGetFailure models the transient case (no
                # "HTTP 404" in the message); a genuinely-missing mock
                # comment models the confirmed-404 case.
                if ($script:simulateTransientGetFailure -contains $id) {
                    Write-Error "gh: unexpected error connecting to api.github.com"
                    $global:LASTEXITCODE = 1
                    return ''
                }
                $c = $script:mockComments | Where-Object { $_.Id -eq $id }
                if (-not $c) {
                    Write-Error "gh: Not Found (HTTP 404)"
                    $global:LASTEXITCODE = 1
                    return ''
                }
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

            if ($joined -match '^(issue|pr) comment \d+ --body-file') {
                $newId = $script:NextCommentId
                $script:NextCommentId++
                $bodyFileIdx = [Array]::IndexOf($Args, '--body-file')
                $bodyFilePath = $Args[$bodyFileIdx + 1]
                $bodyText = Get-Content -LiteralPath $bodyFilePath -Raw
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
            $script:PlanIssueFamily = @(Get-MarkerFamilyRegistry | Where-Object { $_.Family -eq 'plan-issue' })[0]
            $script:FrameSlicesFamily = @(Get-MarkerFamilyRegistry | Where-Object { $_.Family -eq 'frame-slices' })[0]
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

        It 'M21: refuses (never throws) a bodyFile path that resolves inside the scratch root but is a DIRECTORY, not readable content' {
            $dirPath = Join-Path $script:ScratchRoot 'a-directory'
            New-Item -ItemType Directory -Path $dirPath -Force | Out-Null

            { $script:result = Read-MarkerScratchBoundedBodyFile -BodyFile $dirPath -ScratchRoot $script:ScratchRoot } | Should -Not -Throw

            $script:result.Success | Should -Be $false
            $script:result.Body | Should -Be $null
            $script:result.Reason | Should -Match '(?i)could not be read|REFUSED'
        }

        It 'refuses a bodyFile path that does not exist' {
            $missing = Join-Path $script:ScratchRoot 'does-not-exist.md'

            $result = Read-MarkerScratchBoundedBodyFile -BodyFile $missing -ScratchRoot $script:ScratchRoot

            $result.Success | Should -Be $false
            $result.Reason | Should -Match '(?i)does not exist'
        }

        It 'refuses a bodyFile reached through a junction inside the scratch root whose target is OUTSIDE it (M1, issue #893 s11)' {
            # Real reparse-point spoof: the junction itself lives inside the
            # scratch root (so Resolve-Path's traversed-path string passes
            # the string-prefix containment check unchanged), but its target
            # is outside -- Resolve-Path does not dereference reparse points,
            # so the un-walked containment check alone would wrongly admit
            # this read. No elevation required: junctions (unlike symlinks)
            # do not require Administrator on Windows.
            $secretDir = Join-Path $TestDrive 'outside-secret'
            New-Item -ItemType Directory -Path $secretDir -Force | Out-Null
            $secretFile = Join-Path $secretDir 'secret.md'
            [System.IO.File]::WriteAllText($secretFile, 'top secret contents')

            $junctionPath = Join-Path $script:ScratchRoot 'link-out'
            New-Item -ItemType Junction -Path $junctionPath -Target $secretDir | Out-Null
            $viaJunction = Join-Path $junctionPath 'secret.md'

            $result = Read-MarkerScratchBoundedBodyFile -BodyFile $viaJunction -ScratchRoot $script:ScratchRoot

            $result.Success | Should -Be $false
            $result.Reason | Should -Match '(?i)junction|symlink|reparse'
            $result.Body | Should -Be $null
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

        It 'M23: ACCEPTS an astral-plane (surrogate-pair) emoji-heavy body whose UTF-16 .Length exceeds the cap but whose real Unicode CODEPOINT count does not' {
            $marker = $script:GoodFamilyA.MarkerTemplate -replace '\{ID\}', "$script:IssueNumber"
            # U+1F600 (grinning face) is outside the Basic Multilingual
            # Plane -- each occurrence is a 2-UTF-16-code-unit surrogate
            # pair but exactly ONE Unicode codepoint. 40,000 repeats: raw
            # [string]::Length = 80,000 (would have been wrongly refused by
            # the old UTF-16-code-unit count, well over the 65,536 cap) but
            # the real codepoint count is only 40,000 -- comfortably under
            # the cap.
            $emoji = [char]::ConvertFromUtf32(0x1F600)
            $emojiBody = $marker + "`n`n" + ($emoji * 40000)
            $emojiBody.Length | Should -BeGreaterThan 65536 -Because 'the raw UTF-16 .Length must exceed the cap for this test to be meaningful'

            $result = Invoke-PersistMarkerWrite -Family $script:GoodFamilyA.Family -Owner $script:Owner -Repo $script:Repo -Number $script:IssueNumber -TargetSurface 'issue' -Marker $marker -Body $emojiBody

            $result.Success | Should -Be $true
            $script:PostLog.Count | Should -Be 1
        }

        It 'M23: still refuses when the real Unicode CODEPOINT count (not just raw .Length) exceeds the cap' {
            $marker = $script:GoodFamilyA.MarkerTemplate -replace '\{ID\}', "$script:IssueNumber"
            $emoji = [char]::ConvertFromUtf32(0x1F600)
            # 70,000 codepoints -- genuinely over the cap by codepoint count,
            # not merely by raw UTF-16 unit count.
            $emojiBody = $marker + "`n`n" + ($emoji * 70000)

            $result = Invoke-PersistMarkerWrite -Family $script:GoodFamilyA.Family -Owner $script:Owner -Repo $script:Repo -Number $script:IssueNumber -TargetSurface 'issue' -Marker $marker -Body $emojiBody

            $result.Success | Should -Be $false
            $result.Reason | Should -Match '65,?536'
            $script:PostLog.Count | Should -Be 0
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

    Context 'Invoke-PersistMarkerBurst: preview-merges plan-issue write-back-preserve during preflight (M11, issue #893 s11)' {
        It 'refuses the WHOLE burst with zero writes when a plan-issue entry''s preserve merge would push it over the size cap -- even though its RAW candidate body is tiny and an earlier entry would otherwise have already landed' {
            $markerA = $script:GoodFamilyA.MarkerTemplate -replace '\{ID\}', "$script:IssueNumber"
            $planMarker = $script:PlanIssueFamily.MarkerTemplate -replace '\{ID\}', "$script:IssueNumber"

            # Existing (legacy, no ledger pointer) plan-issue comment carries a
            # huge **Plan Stress-Test** section that write-back-preserve would
            # carry forward onto any candidate that omits it.
            $giantStressSection = "**Plan Stress-Test**`n`n" + ('x' * 70000)
            Add-MockComment -Id 100 -Body "$planMarker`n`nOld plan prose.`n`n$giantStressSection"

            $entries = @(
                [PSCustomObject]@{ Family = $script:GoodFamilyA.Family; Number = $script:IssueNumber; TargetSurface = 'issue'; Marker = $markerA; Body = "$markerA`n`nEntry one, would otherwise land first."; NoPreserve = $false }
                [PSCustomObject]@{ Family = $script:PlanIssueFamily.Family; Number = $script:IssueNumber; TargetSurface = 'issue'; Marker = $planMarker; Body = "$planMarker`n`nFresh, tiny plan prose -- omits the stress-test section by mistake."; NoPreserve = $false }
            )

            $result = Invoke-PersistMarkerBurst -Owner $script:Owner -Repo $script:Repo -Entries $entries

            $result.Success | Should -Be $false
            $result.Reason | Should -Match '65,?536'
            # M11's whole point: this must be a PREFLIGHT refusal (entry 1
            # never attempted, zero writes) rather than entry 1 landing before
            # the entry-2 preserve-triggered violation surfaces at execution.
            $script:PostLog.Count | Should -Be 0
            $script:PatchLog.Count | Should -Be 0
            $result.Artifacts['entry-1'] | Should -Be 'not-attempted'
            $result.Artifacts['entry-2'] | Should -Be 'not-attempted'
        }

        It 'still lets a plan-issue entry through preflight when -NoPreserve would skip the merge that WOULD have overflowed the size cap' {
            $planMarker = $script:PlanIssueFamily.MarkerTemplate -replace '\{ID\}', "$script:IssueNumber"
            $giantStressSection = "**Plan Stress-Test**`n`n" + ('x' * 70000)
            Add-MockComment -Id 100 -Body "$planMarker`n`nOld plan prose.`n`n$giantStressSection"

            $entries = @(
                [PSCustomObject]@{ Family = $script:PlanIssueFamily.Family; Number = $script:IssueNumber; TargetSurface = 'issue'; Marker = $planMarker; Body = "$planMarker`n`nFresh, tiny plan prose, deliberately not preserving."; NoPreserve = $true }
            )

            $result = Invoke-PersistMarkerBurst -Owner $script:Owner -Repo $script:Repo -Entries $entries

            $result.Success | Should -Be $true
            $result.Artifacts['entry-1'] | Should -Be 'landed'
        }
    }

    Context 'Invoke-PersistMarkerBurst: transient transport failure during preview never produces a false preflight REFUSAL of the WHOLE burst (P10, issue #893 s11 post-fix)' {
        It 'lets an EARLIER unrelated entry land through preflight and execution even though a LATER plan-issue entry''s preview hits a transient GET failure on its inherited ledger-ref sibling check' {
            # Regression coverage: M11's docstring claimed the preflight
            # preview "can never produce a false REFUSAL of an
            # otherwise-valid burst". Defense proved that false:
            # script:Test-MarkerSiblingIdentity (M19) THROWS on a TRANSIENT
            # transport failure (not a confirmed-absent $false), and before
            # this fix the burst preflight loop's try/catch turned that
            # throw into a hard REFUSAL for the WHOLE burst -- at PREFLIGHT
            # time, before ANY entry (including ones with no relationship
            # at all to the plan-issue preview) had a chance to land.
            # Before M11 introduced this preview, the preflight issued no
            # GETs at all, so this failure mode was impossible.
            $markerA = $script:GoodFamilyA.MarkerTemplate -replace '\{ID\}', "$script:IssueNumber"
            $planMarker = $script:PlanIssueFamily.MarkerTemplate -replace '\{ID\}', "$script:IssueNumber"
            Add-MockComment -Id 100 -Body "$planMarker`n<!-- phase-containment-ledger-ref: 500 -->`n`nOld plan prose."
            # Sibling comment 500 is never actually reachable -- every GET
            # for it fails TRANSIENTLY (not a confirmed 404).
            $script:simulateTransientGetFailure = @(500)

            $entries = @(
                [PSCustomObject]@{ Family = $script:GoodFamilyA.Family; Number = $script:IssueNumber; TargetSurface = 'issue'; Marker = $markerA; Body = "$markerA`n`nUnrelated entry, must land regardless."; NoPreserve = $false }
                [PSCustomObject]@{ Family = $script:PlanIssueFamily.Family; Number = $script:IssueNumber; TargetSurface = 'issue'; Marker = $planMarker; Body = "$planMarker`n`nFresh plan prose, no candidate-supplied pointer of its own."; NoPreserve = $false }
            )

            $result = Invoke-PersistMarkerBurst -Owner $script:Owner -Repo $script:Repo -Entries $entries

            # The unrelated FIRST entry must have actually landed -- proving
            # the transient preview failure did not block the whole burst
            # at PREFLIGHT time (the old behavior: Artifacts['entry-1']
            # would read 'not-attempted' and PostLog.Count would be 0).
            $script:PostLog.Count | Should -Be 1
            $result.Artifacts['entry-1'] | Should -Be 'landed'
            # The plan-issue entry itself still legitimately fails, but
            # only at EXECUTION time, once Invoke-PersistMarkerWrite's own
            # M19 transport-failure handling re-checks for real (the
            # transient failure never clears in this fixture) -- this is
            # the CORRECT, unchanged fail-closed behavior for that specific
            # entry, not a regression.
            $result.Success | Should -Be $false
            $result.Artifacts['entry-2'] | Should -Be 'failed'
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

    Context 'Invoke-PersistMarkerBurst: stale-value fail-open on a parameter-binding failure (M4/N1, issue #893 s11)' {
        It 'refuses the whole manifest with zero writes when entry 2''s manifest JSON carries an invalid targetSurface value (M4 common-case, explicit up-front enum validation)' {
            $markerA = $script:GoodFamilyA.MarkerTemplate -replace '\{ID\}', "$script:IssueNumber"
            $body1 = script:New-ScratchBodyFile -Name 'entry1.md' -Content "$markerA`n`nEntry one, valid."
            $body2 = script:New-ScratchBodyFile -Name 'entry2.md' -Content "$markerA`n`nEntry two, bad targetSurface."
            $entries = @(
                @{ family = $script:GoodFamilyA.Family; number = $script:IssueNumber; targetSurface = 'issue'; marker = $markerA; bodyFile = $body1 }
                @{ family = $script:GoodFamilyA.Family; number = $script:IssueNumber; targetSurface = 'pr'; marker = $markerA; bodyFile = $body2 }
            )
            $manifestPath = script:New-ManifestFile -Entries $entries

            $result = Invoke-PersistMarkerBurstFromManifest -Owner $script:Owner -Repo $script:Repo -ManifestPath $manifestPath -ScratchRoot $script:ScratchRoot

            $result.Success | Should -Be $false
            $result.Reason | Should -Match '(?i)entry 2'
            $result.Reason | Should -Match '(?i)targetSurface'
            $result.Reason | Should -Match "'pr'"
            $script:PostLog.Count | Should -Be 0
            $script:PatchLog.Count | Should -Be 0
        }

        It 'never reports a false "landed" status for an entry whose write call itself throws (N1: this is STRICTLY WORSE than a null-result -- the executor loop must not read a PRIOR iteration''s stale $writeResult)' {
            # Entry 1 is completely valid and genuinely lands. Entry 2
            # targets a DIFFERENT issue number whose paginated
            # Find-AllCommentsByExactMarker lookup is made to throw (a real,
            # already-documented failure mode of that function -- see
            # marker-transport-core.ps1's own "throws rather than returning
            # an empty/partial result" contract) -- both entries pass the
            # network-free preflight cleanly (this is NOT a ValidateSet
            # binding failure, which the preflight loop's own fix now
            # catches upstream of the executor loop entirely), so this
            # isolates the EXECUTOR loop's own stale-$writeResult bug: if
            # $writeResult is not reset before entry 2's call, and the throw
            # is not caught, entry 2 would either crash the whole burst
            # uncaught or (in a narrower non-terminating variant) silently
            # inherit entry 1's successful result object.
            $markerA = $script:GoodFamilyA.MarkerTemplate -replace '\{ID\}', "$script:IssueNumber"
            $markerB = $script:GoodFamilyA.MarkerTemplate -replace '\{ID\}', "$($script:IssueNumber + 1)"
            $script:PaginateFailureNumbers.Add($script:IssueNumber + 1) | Out-Null

            $entries = @(
                [PSCustomObject]@{ Family = $script:GoodFamilyA.Family; Number = $script:IssueNumber; TargetSurface = 'issue'; Marker = $markerA; Body = "$markerA`n`nEntry one, genuinely lands."; NoPreserve = $false }
                [PSCustomObject]@{ Family = $script:GoodFamilyA.Family; Number = ($script:IssueNumber + 1); TargetSurface = 'issue'; Marker = $markerB; Body = "$markerB`n`nEntry two, write call throws, must never be reported landed."; NoPreserve = $false }
            )

            $result = Invoke-PersistMarkerBurst -Owner $script:Owner -Repo $script:Repo -Entries $entries

            # Entry 1 genuinely posted -- exactly once.
            $script:PostLog.Count | Should -Be 1
            $result.Artifacts['entry-1'] | Should -Be 'landed'

            # N1's exact failure mode: entry 2 must NEVER be reported
            # 'landed' by inheriting entry 1's stale successful $writeResult.
            $result.Artifacts['entry-2'] | Should -Not -Be 'landed'
            $result.Artifacts['entry-2'] | Should -Be 'failed'
            $result.Success | Should -Be $false
            $result.Reason | Should -Match '(?i)entry 2'
        }
    }

    Context 'Invoke-PersistMarkerBurst: distinct landed-postfix-failed artifact status (M18, issue #893 s11)' {
        It 'records ''landed-postfix-failed'', not ''failed'', for a frame-slices entry whose comment write landed but whose spine-splice PostStep failed' {
            $sliceMarker = $script:FrameSlicesFamily.MarkerTemplate -replace '\{ID\}', "$script:IssueNumber"
            # Deliberately NO plan-issue comment exists on this issue --
            # Invoke-FrameSlicesSpineSplice's marker-identity precondition
            # refuses (it can never find a `<!-- plan-issue-{Number} -->`
            # comment to splice into), but New-MarkerComment's POST for the
            # frame-slices sibling itself still succeeds first.
            $entries = @(
                [PSCustomObject]@{ Family = $script:FrameSlicesFamily.Family; Number = $script:IssueNumber; TargetSurface = 'issue'; Marker = $sliceMarker; Body = "$sliceMarker`n<!-- frame-slices-generated-at: 2026-07-01T00:00:00Z -->`n`nSlices."; NoPreserve = $false }
            )

            $result = Invoke-PersistMarkerBurst -Owner $script:Owner -Repo $script:Repo -Entries $entries

            $result.Success | Should -Be $false
            $result.Artifacts['entry-1'] | Should -Be 'landed-postfix-failed'
            $result.Artifacts['entry-1'] | Should -Not -Be 'failed'
            # The underlying comment write itself DID land.
            $script:PostLog.Count | Should -Be 1
        }

        It 'still records plain ''failed'' (never ''landed-postfix-failed'') for a genuine execution-time failure where nothing usable landed' {
            $markerA = $script:GoodFamilyA.MarkerTemplate -replace '\{ID\}', "$script:IssueNumber"
            # entry's freshly-assigned comment id (90000) is corrupted at
            # read-back time -- the write itself never gets confirmed as
            # landed (Action stays $null on this failure path).
            $script:CorruptReadBackIds.Add(90000) | Out-Null
            $entries = @(
                [PSCustomObject]@{ Family = $script:GoodFamilyA.Family; Number = $script:IssueNumber; TargetSurface = 'issue'; Marker = $markerA; Body = "$markerA`n`nEntry with several e characters, corrupted at read-back."; NoPreserve = $false }
            )

            $result = Invoke-PersistMarkerBurst -Owner $script:Owner -Repo $script:Repo -Entries $entries

            $result.Success | Should -Be $false
            $result.Artifacts['entry-1'] | Should -Be 'failed'
            $result.Artifacts['entry-1'] | Should -Not -Be 'landed-postfix-failed'
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

    Context 'Invoke-PersistMarkerBurstFromManifest: -BurstManifest path scratch-root bounding (M13, issue #893 s11)' {
        It 'refuses a -BurstManifest path that resolves OUTSIDE the scratch root, before ever opening it' {
            $markerA = $script:GoodFamilyA.MarkerTemplate -replace '\{ID\}', "$script:IssueNumber"
            $bodyPath = script:New-ScratchBodyFile -Name 'body-outside-manifest.md' -Content "$markerA`n`nBody."
            $entries = @(
                @{ family = $script:GoodFamilyA.Family; number = $script:IssueNumber; targetSurface = 'issue'; marker = $markerA; bodyFile = $bodyPath }
            )
            $outsideManifestPath = Join-Path $TestDrive 'outside-burst.json'
            (ConvertTo-Json -InputObject $entries -Depth 10 -AsArray) | Set-Content -LiteralPath $outsideManifestPath

            $result = Invoke-PersistMarkerBurstFromManifest -Owner $script:Owner -Repo $script:Repo -ManifestPath $outsideManifestPath -ScratchRoot $script:ScratchRoot

            $result.Success | Should -Be $false
            $result.Reason | Should -Match '(?i)scratch root|out of bounds'
            $script:PostLog.Count | Should -Be 0
        }

        It 'accepts a -BurstManifest path that resolves inside the scratch root (regression)' {
            $markerA = $script:GoodFamilyA.MarkerTemplate -replace '\{ID\}', "$script:IssueNumber"
            $bodyPath = script:New-ScratchBodyFile -Name 'body-inside-manifest.md' -Content "$markerA`n`nBody."
            $entries = @(
                @{ family = $script:GoodFamilyA.Family; number = $script:IssueNumber; targetSurface = 'issue'; marker = $markerA; bodyFile = $bodyPath }
            )
            $manifestPath = script:New-ManifestFile -Entries $entries

            $result = Invoke-PersistMarkerBurstFromManifest -Owner $script:Owner -Repo $script:Repo -ManifestPath $manifestPath -ScratchRoot $script:ScratchRoot

            $result.Success | Should -Be $true
            $script:PostLog.Count | Should -Be 1
        }
    }

    Context 'Invoke-PersistMarkerBurstFromManifest: manifest parsing + malformed refusal' {
        It 'M22: length-bounds an echoed $ManifestPath in a refusal message, never dumping it unbounded' {
            # A deeply-nested scratch-root subdirectory whose resolved path
            # comfortably exceeds the 80-char field-value cap.
            $deepDir = $script:ScratchRoot
            1..15 | ForEach-Object { $deepDir = Join-Path $deepDir "segment-$_-with-some-extra-length-padding" }
            New-Item -ItemType Directory -Path $deepDir -Force | Out-Null
            $manifestPath = Join-Path $deepDir 'bad.json'
            [System.IO.File]::WriteAllText($manifestPath, '{ not valid json ][')

            $result = Invoke-PersistMarkerBurstFromManifest -Owner $script:Owner -Repo $script:Repo -ManifestPath $manifestPath -ScratchRoot $script:ScratchRoot

            $result.Success | Should -Be $false
            $manifestPath.Length | Should -BeGreaterThan 80
            $result.Reason | Should -Match '\.\.\.\(\+\d+ more chars, truncated\)'
            $result.Reason | Should -Not -Match ([regex]::Escape($manifestPath))
        }

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

        It 'M12: a JSON-quoted noPreserve string "false" is treated as $false (preserve still runs), never silently coerced to $true' {
            $planMarker = $script:PlanIssueFamily.MarkerTemplate -replace '\{ID\}', "$script:IssueNumber"
            $ledgerMarker = "<!-- phase-containment-ledger-$script:IssueNumber -->"
            Add-MockComment -Id 500 -Body "$ledgerMarker`n`nSibling content."
            Add-MockComment -Id 100 -Body "$planMarker`n<!-- phase-containment-ledger-ref: 500 -->`n`nOld plan prose."
            $bodyPath = script:New-ScratchBodyFile -Name 'plan-body.md' -Content "$planMarker`n`nFresh plan prose, no pointer."
            # Hand-authoring slip: the manifest JSON-quotes the boolean as a
            # string rather than emitting a bare JSON `false` literal. The
            # OLD `[bool]$rawEntry.noPreserve` cast coerced ANY non-empty
            # string (including "false") to $true, silently disabling all
            # write-back preservation.
            $entries = @(
                @{ family = $script:PlanIssueFamily.Family; number = $script:IssueNumber; targetSurface = 'issue'; marker = $planMarker; bodyFile = $bodyPath; noPreserve = 'false' }
            )
            $manifestPath = script:New-ManifestFile -Entries $entries

            $result = Invoke-PersistMarkerBurstFromManifest -Owner $script:Owner -Repo $script:Repo -ManifestPath $manifestPath -ScratchRoot $script:ScratchRoot

            $result.Success | Should -Be $true
            $script:PatchLog[0].Body | Should -Match ([regex]::Escape('<!-- phase-containment-ledger-ref: 500 -->'))
        }

        It 'M12: an uppercase-mixed noPreserve string "TRUE" is recognized case-insensitively and skips preservation' {
            $planMarker = $script:PlanIssueFamily.MarkerTemplate -replace '\{ID\}', "$script:IssueNumber"
            $ledgerMarker = "<!-- phase-containment-ledger-$script:IssueNumber -->"
            Add-MockComment -Id 500 -Body "$ledgerMarker`n`nSibling content."
            Add-MockComment -Id 100 -Body "$planMarker`n<!-- phase-containment-ledger-ref: 500 -->`n`nOld plan prose."
            $bodyPath = script:New-ScratchBodyFile -Name 'plan-body2.md' -Content "$planMarker`n`nFresh plan prose, no pointer."
            $entries = @(
                @{ family = $script:PlanIssueFamily.Family; number = $script:IssueNumber; targetSurface = 'issue'; marker = $planMarker; bodyFile = $bodyPath; noPreserve = 'TRUE' }
            )
            $manifestPath = script:New-ManifestFile -Entries $entries

            $result = Invoke-PersistMarkerBurstFromManifest -Owner $script:Owner -Repo $script:Repo -ManifestPath $manifestPath -ScratchRoot $script:ScratchRoot

            $result.Success | Should -Be $true
            $script:PatchLog[0].Body | Should -Not -Match 'phase-containment-ledger-ref'
        }

        It 'M12: refuses a manifest entry whose noPreserve is a non-boolean JSON value (a number), naming the entry index and offending value' {
            $markerA = $script:GoodFamilyA.MarkerTemplate -replace '\{ID\}', "$script:IssueNumber"
            $bodyPath = script:New-ScratchBodyFile -Name 'body-noPreserve-numeric.md' -Content "$markerA`n`nBody."
            $entries = @(
                @{ family = $script:GoodFamilyA.Family; number = $script:IssueNumber; targetSurface = 'issue'; marker = $markerA; bodyFile = $bodyPath; noPreserve = 1 }
            )
            $manifestPath = script:New-ManifestFile -Entries $entries

            $result = Invoke-PersistMarkerBurstFromManifest -Owner $script:Owner -Repo $script:Repo -ManifestPath $manifestPath -ScratchRoot $script:ScratchRoot

            $result.Success | Should -Be $false
            $result.Reason | Should -Match '(?i)entry 1'
            $result.Reason | Should -Match '(?i)noPreserve'
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
