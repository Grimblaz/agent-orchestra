#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
    RED-phase Pester suite for the not-yet-implemented persist-marker-core
    helper (issue #893, plan slice s3). Implementation lands at
    skills/session-memory-contract/scripts/persist-marker-core.ps1,
    exporting Invoke-PersistMarkerWrite, Get-MarkerFamilyRegistry, and
    ConvertTo-MarkerNormalizedText.

.DESCRIPTION
    Dot-sources the REAL, already-shipped s2 transport primitives
    (.github/scripts/lib/marker-transport-core.ps1) and mocks only the true
    external seam (`gh`), matching the convention already established by
    marker-transport-core.Tests.ps1 and persist-phase-ledger.Tests.ps1. Per
    that same convention: when the core file does not exist yet, a
    CommandNotFoundException at the Act line is itself the sanctioned RED
    signal.

    Covers the slice s3 Requirement Contract (ac-refs AC1, AC3, AC11):
    both write shapes end-to-end, normalization convergence (CRLF vs LF),
    latest-vs-earliest selection under multiple matches, normalized-equality
    read-back rejecting a corrupted round-trip (a same-length mojibake
    substitution that the old >=50%-length-only guard would have accepted),
    and surface-mismatch refusal.

    s5 addition (ac-refs AC5): covers the two now-populated PostStep
    dispatches -- 'plan-issue-write-back-preserve' (Context
    'plan-issue write-back-preserve post-step') and
    'frame-slices-spine-splice' (Context 'frame-slices spine-splice
    post-step') -- plus the new frame-slices registry row. Dot-sources the
    REAL frame-spine-core.ps1 (Get-FSCSpineBlock / Get-FSCScalarValue),
    mirroring this file's existing marker-transport-core.ps1 /
    frame-engagement-record-core.ps1 dot-source-before-core convention.
#>

BeforeDiscovery {
    $script:CoreLibPath = Join-Path $PSScriptRoot '../../../skills/session-memory-contract/scripts/persist-marker-core.ps1'
}

Describe 'persist-marker-core' {
    BeforeAll {
        $script:CoreLibPath = Join-Path $PSScriptRoot '../../../skills/session-memory-contract/scripts/persist-marker-core.ps1'
        $script:MarkerTransportLibPath = Join-Path $PSScriptRoot '../lib/marker-transport-core.ps1'
        $script:EngagementRecordLibPath = Join-Path $PSScriptRoot '../lib/frame-engagement-record-core.ps1'
        $script:FrameSpineLibPath = Join-Path $PSScriptRoot '../lib/frame-spine-core.ps1'
        $script:Owner = 'Grimblaz'
        $script:Repo = 'agent-orchestra'
        $script:IssueNumber = 893
        $script:PrNumber = 5000

        # --- Static YAML fixtures for the s4 validator-adapter contexts. ---
        $script:EngagementRecordValidYaml = @'
```yaml
schema_version: 2
phase: plan
capture_session: "test-session"
load_bearing_decisions:
  - decision_id: sample-decision
    classification: load-bearing
    articulation_status: complete
```
'@
        $script:EngagementRecordInvalidYaml = @'
```yaml
schema_version: 2
phase: plan
capture_session: "test-session"
load_bearing_decisions:
  - decision_id: Not_A_Valid_Slug
    classification: load-bearing
    articulation_status: complete
```
'@
        $script:ReviewDispositionsValidYaml = @'
```yaml
schema_version: 1
passes_run: [1]
entries:
  - stable_finding_key: "src/example.ts:10:sample-finding"
    pass: 1
    disposition: dismiss
    classification: routine
    disposition_rationale: "Not applicable in this context."
```
'@
        $script:ReviewDispositionsInvalidYaml = @'
```yaml
schema_version: 1
passes_run: [1]
entries:
  - stable_finding_key: "src/example.ts:10:sample-finding"
    pass: 1
    disposition: dismiss
    classification: routine
```
'@
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
        $script:CreditInputNestedEvidenceYaml = @'
```yaml
port: plan
adapter: skills/plan-authoring/adapters/plan-adapter.md
evidence:
  summary: nested mapping not allowed
```
'@
    }

    BeforeEach {
        # --- Simulated GitHub comment store (mutable across gh calls). ---
        $script:mockComments = [System.Collections.Generic.List[object]]::new()
        $script:NextCommentId = 90000
        $script:ghCallLog = [System.Collections.Generic.List[string]]::new()
        $script:PatchLog = [System.Collections.Generic.List[object]]::new()
        $script:PostLog = [System.Collections.Generic.List[object]]::new()
        $script:simulatePaginateFailure = $false
        $script:simulatePatchFailure = @()
        $script:simulateGetFailure = @()
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

            # Paginated full-list: gh api --paginate repos/<o>/<r>/issues/<n>/comments
            if ($joined -match '^api --paginate repos/[^/]+/[^/]+/issues/\d+/comments$') {
                if ($script:simulatePaginateFailure) { $global:LASTEXITCODE = 1; return '' }
                $payload = @($script:mockComments | ForEach-Object {
                        @{ id = $_.Id; body = $_.body; url = $_.url }
                    }) | ConvertTo-Json -Depth 8
                $global:LASTEXITCODE = 0
                return $payload
            }

            # GET by numeric id (no -X): gh api repos/<o>/<r>/issues/comments/<id>
            if ($Args.Count -ge 2 -and $Args[0] -eq 'api' -and $Args[1] -match '^repos/[^/]+/[^/]+/issues/comments/(\d+)$' -and ($Args -notcontains '-X')) {
                $id = [long]$Matches[1]
                if ($script:simulateGetFailure -contains $id) { $global:LASTEXITCODE = 1; return '' }
                $c = $script:mockComments | Where-Object { $_.Id -eq $id }
                if (-not $c) { $global:LASTEXITCODE = 1; return '' }
                $global:LASTEXITCODE = 0
                $returnedBody = $c.body
                if ($script:CorruptReadBackIds.Contains($id)) {
                    # Same-length homoglyph substitution: proves normalized
                    # equality is doing real rejection work that the old
                    # >=50%-length truncation guard alone would have missed
                    # (mojibake corruption LENGTHENS/holds length, never
                    # shortens it).
                    $returnedBody = $returnedBody -replace 'e', "ë"
                }
                return (@{ id = $c.Id; body = $returnedBody; url = $c.url } | ConvertTo-Json -Depth 8)
            }

            # PATCH: gh api -X PATCH repos/<o>/<r>/issues/comments/<id> --input <file>
            if ($joined -match '^api -X PATCH repos/[^/]+/[^/]+/issues/comments/(\d+) --input') {
                $id = [long]$Matches[1]
                if ($script:simulatePatchFailure -contains $id) { $global:LASTEXITCODE = 1; return '' }
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

            # POST: gh issue comment <N> --body <text>  (or gh pr comment)
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

        # Real s2 primitives first (so persist-marker-core's unqualified
        # calls to Find-AllCommentsByExactMarker / New-MarkerComment /
        # Get-CommentIdFromUrl / Get-CommentBodyById / Set-CommentBodyDirect
        # resolve to the genuine, already-shipped implementations), then the
        # real engagement-record function library (so
        # Invoke-EngagementRecordValidatorAdapter's unqualified
        # Read-EngagementRecords call resolves -- mirrors this file's own
        # existing dot-source-before-core convention), then the core itself.
        if (Test-Path $script:MarkerTransportLibPath) { . $script:MarkerTransportLibPath }
        if (Test-Path $script:EngagementRecordLibPath) { . $script:EngagementRecordLibPath }
        if (Test-Path $script:FrameSpineLibPath) { . $script:FrameSpineLibPath }
        if (Test-Path $script:CoreLibPath) { . $script:CoreLibPath }

        # Computed here (per-test, after dot-sourcing above) rather than in
        # a Context-level BeforeAll: Pester runs every container's BeforeAll
        # blocks before any BeforeEach, so a Context-level BeforeAll calling
        # Get-MarkerFamilyRegistry would fire before this BeforeEach has
        # dot-sourced the core file that defines it.
        if (Test-Path $script:CoreLibPath) {
            $script:PostNewFamily = @(Get-MarkerFamilyRegistry | Where-Object { $_.WriteShape -eq 'post-new' -and $_.TargetSurface -eq 'issue' })[0]
            $script:UpsertFamily = @(Get-MarkerFamilyRegistry | Where-Object { $_.WriteShape -eq 'upsert' -and $_.TargetSurface -eq 'issue' -and $_.Family -eq 'plan-issue' })[0]
            $script:EngagementRecordFamily = @(Get-MarkerFamilyRegistry | Where-Object { $_.Family -eq 'engagement-record' })[0]
            $script:ReviewDispositionsFamily = @(Get-MarkerFamilyRegistry | Where-Object { $_.Family -eq 'review-dispositions' })[0]
            $script:CreditInputFamily = @(Get-MarkerFamilyRegistry | Where-Object { $_.Family -eq 'credit-input' })[0]
            $script:SentinelFamily = @(Get-MarkerFamilyRegistry | Where-Object { $_.Family -eq 'review-judge-produced' })[0]
            $script:FrameSlicesFamily = @(Get-MarkerFamilyRegistry | Where-Object { $_.Family -eq 'frame-slices' })[0]
        }
    }

    AfterEach {
        Remove-Item Function:gh -ErrorAction SilentlyContinue
    }

    Context 'Get-MarkerFamilyRegistry: declarative schema' {
        It 'returns rows carrying Family, MarkerTemplate, TargetSurface, WriteShape, ValidatorAdapter, and PostStep fields' {
            $rows = Get-MarkerFamilyRegistry

            $rows.Count | Should -BeGreaterThan 0
            foreach ($row in $rows) {
                $row.PSObject.Properties.Name | Should -Contain 'Family'
                $row.PSObject.Properties.Name | Should -Contain 'MarkerTemplate'
                $row.PSObject.Properties.Name | Should -Contain 'TargetSurface'
                $row.PSObject.Properties.Name | Should -Contain 'WriteShape'
                $row.PSObject.Properties.Name | Should -Contain 'ValidatorAdapter'
                $row.PSObject.Properties.Name | Should -Contain 'PostStep'
                @('issue', 'pull-request') | Should -Contain $row.TargetSurface
                @('post-new', 'upsert') | Should -Contain $row.WriteShape
            }
        }

        It 'includes at least one post-new family and one upsert family' {
            $rows = Get-MarkerFamilyRegistry

            @($rows | Where-Object { $_.WriteShape -eq 'post-new' }).Count | Should -BeGreaterThan 0
            @($rows | Where-Object { $_.WriteShape -eq 'upsert' }).Count | Should -BeGreaterThan 0
        }

        It 'design-phase-complete is post-new (append-only history), matching handoff-markers.md''s documented catalog entry, not upsert-in-place (M9, issue #893 s11)' {
            # skills/session-memory-contract/references/handoff-markers.md:15
            # documents this family as post-new -- the registry previously
            # declared upsert, real behavioral drift (upsert PATCHes in
            # place; post-new appends, preserving history) confirmed live
            # by the suite's own printed 'comment ... updated' output before
            # this fix.
            $row = @(Get-MarkerFamilyRegistry | Where-Object { $_.Family -eq 'design-phase-complete' })[0]

            $row | Should -Not -BeNullOrEmpty
            $row.WriteShape | Should -Be 'post-new'
        }
    }

    Context 'ConvertTo-MarkerNormalizedText: the one shared normalization function' {
        It 'converges CRLF and LF variants of the same content to an identical normalized string' {
            $crlf = "<!-- marker -->`r`nLine one.`r`nLine two.`r`n"
            $lf = "<!-- marker -->`nLine one.`nLine two.`n"

            (ConvertTo-MarkerNormalizedText -Text $crlf) | Should -Be (ConvertTo-MarkerNormalizedText -Text $lf)
        }

        It 'strips per-line trailing whitespace and outer whitespace only, leaving interior content untouched' {
            $raw = "  `n<!-- marker -->  `nBody line.   `n  "

            (ConvertTo-MarkerNormalizedText -Text $raw) | Should -Be "<!-- marker -->`nBody line."
        }
    }

    Context 'post-new write shape: end-to-end' {
        It 'posts a brand-new comment when no prior match exists, and the read-back confirms it verbatim' {
            $marker = $script:PostNewFamily.MarkerTemplate -replace '\{ID\}', "$script:IssueNumber"
            $body = "$marker`n`nFresh payload with non-ASCII: café."

            $result = Invoke-PersistMarkerWrite -Family $script:PostNewFamily.Family -Owner $script:Owner -Repo $script:Repo -Number $script:IssueNumber -TargetSurface 'issue' -Marker $marker -Body $body

            $result.Success | Should -Be $true
            $result.Action | Should -Be 'posted'
            $script:PostLog.Count | Should -Be 1
            $result.CommentId | Should -Not -BeNullOrEmpty
            $escapedFamily = [regex]::Escape($script:PostNewFamily.Family)
            $result.Confirmation | Should -Match $escapedFamily
            $result.Confirmation | Should -Match "$($result.CommentId)"
        }

        It 'is a no-op when the payload already matches the LATEST marker match, comparing against latest only' {
            $marker = $script:PostNewFamily.MarkerTemplate -replace '\{ID\}', "$script:IssueNumber"
            $supersededBody = "$marker`n`nSuperseded payload."
            $latestBody = "$marker`n`nCurrent payload."
            Add-MockComment -Id 100 -Body $supersededBody
            Add-MockComment -Id 200 -Body $latestBody

            $result = Invoke-PersistMarkerWrite -Family $script:PostNewFamily.Family -Owner $script:Owner -Repo $script:Repo -Number $script:IssueNumber -TargetSurface 'issue' -Marker $marker -Body $latestBody

            $result.Success | Should -Be $true
            $result.Action | Should -Be 'no-op'
            $result.CommentId | Should -Be 200
            $script:PostLog.Count | Should -Be 0
        }

        It 'still posts when the payload matches a SUPERSEDED earlier comment but differs from the latest' {
            $marker = $script:PostNewFamily.MarkerTemplate -replace '\{ID\}', "$script:IssueNumber"
            $supersededBody = "$marker`n`nSuperseded payload, matches the new candidate."
            $latestBody = "$marker`n`nSomething else entirely, the current latest."
            Add-MockComment -Id 100 -Body $supersededBody
            Add-MockComment -Id 200 -Body $latestBody

            # Candidate matches the SUPERSEDED (id 100) comment, not the
            # latest (id 200) — must still post, never treated as a no-op.
            $result = Invoke-PersistMarkerWrite -Family $script:PostNewFamily.Family -Owner $script:Owner -Repo $script:Repo -Number $script:IssueNumber -TargetSurface 'issue' -Marker $marker -Body $supersededBody

            $result.Success | Should -Be $true
            $result.Action | Should -Be 'posted'
            $script:PostLog.Count | Should -Be 1
        }

        It 'converges CRLF-bodied stored comment vs LF payload to a no-op' {
            $marker = $script:PostNewFamily.MarkerTemplate -replace '\{ID\}', "$script:IssueNumber"
            $crlfStored = "$marker`r`n`r`nSame content.`r`n"
            $lfPayload = "$marker`n`nSame content."
            Add-MockComment -Id 100 -Body $crlfStored

            $result = Invoke-PersistMarkerWrite -Family $script:PostNewFamily.Family -Owner $script:Owner -Repo $script:Repo -Number $script:IssueNumber -TargetSurface 'issue' -Marker $marker -Body $lfPayload

            $result.Success | Should -Be $true
            $result.Action | Should -Be 'no-op'
            $script:PostLog.Count | Should -Be 0
        }

        It 'reports failure (never Success=$true) when the read-back is corrupted by a same-length substitution the old length-guard would have missed' {
            $marker = $script:PostNewFamily.MarkerTemplate -replace '\{ID\}', "$script:IssueNumber"
            $body = "$marker`n`nA sentence with several letter e characters in it."

            # New-MarkerComment's mock POST assigns $script:NextCommentId (90000
            # on first use in this test) — corrupt exactly that id's GET response.
            $script:CorruptReadBackIds.Add($script:NextCommentId) | Out-Null

            $result = Invoke-PersistMarkerWrite -Family $script:PostNewFamily.Family -Owner $script:Owner -Repo $script:Repo -Number $script:IssueNumber -TargetSurface 'issue' -Marker $marker -Body $body

            $result.Success | Should -Be $false
            $result.Reason | Should -Match '(?i)read-back|normalized'
        }
    }

    Context 'upsert write shape: end-to-end' {
        It 'creates a new comment on first write when no prior match exists' {
            $marker = $script:UpsertFamily.MarkerTemplate -replace '\{ID\}', "$script:IssueNumber"
            $body = "$marker`n`nFirst-ever body."

            $result = Invoke-PersistMarkerWrite -Family $script:UpsertFamily.Family -Owner $script:Owner -Repo $script:Repo -Number $script:IssueNumber -TargetSurface 'issue' -Marker $marker -Body $body

            $result.Success | Should -Be $true
            $result.Action | Should -Be 'created'
            $script:PostLog.Count | Should -Be 1
        }

        It 'PATCHes the EARLIEST (canonical) match, never the latest, when multiple matches exist' {
            $marker = $script:UpsertFamily.MarkerTemplate -replace '\{ID\}', "$script:IssueNumber"
            Add-MockComment -Id 100 -Body "$marker`n`nOld canonical body."
            Add-MockComment -Id 200 -Body "$marker`n`nA later decoy/duplicate."
            $newBody = "$marker`n`nUpdated body."

            $result = Invoke-PersistMarkerWrite -Family $script:UpsertFamily.Family -Owner $script:Owner -Repo $script:Repo -Number $script:IssueNumber -TargetSurface 'issue' -Marker $marker -Body $newBody

            $result.Success | Should -Be $true
            $result.Action | Should -Be 'updated'
            $result.CommentId | Should -Be 100
            $script:PatchLog.Count | Should -Be 1
            $script:PatchLog[0].CommentId | Should -Be 100
        }

        It 'never invokes --edit-last and always targets a numeric REST comment id' {
            $marker = $script:UpsertFamily.MarkerTemplate -replace '\{ID\}', "$script:IssueNumber"
            Add-MockComment -Id 100 -Body "$marker`n`nOld body."
            $newBody = "$marker`n`nUpdated body."

            $null = Invoke-PersistMarkerWrite -Family $script:UpsertFamily.Family -Owner $script:Owner -Repo $script:Repo -Number $script:IssueNumber -TargetSurface 'issue' -Marker $marker -Body $newBody

            @($script:ghCallLog | Where-Object { $_ -match '--edit-last' }) | Should -BeNullOrEmpty
            $script:PatchLog[0].CommentId | Should -BeOfType [long]
        }

        It 'is a no-op when the payload already matches the canonical (earliest) comment' {
            $marker = $script:UpsertFamily.MarkerTemplate -replace '\{ID\}', "$script:IssueNumber"
            $body = "$marker`n`nUnchanged body."
            Add-MockComment -Id 100 -Body $body

            $result = Invoke-PersistMarkerWrite -Family $script:UpsertFamily.Family -Owner $script:Owner -Repo $script:Repo -Number $script:IssueNumber -TargetSurface 'issue' -Marker $marker -Body $body

            $result.Success | Should -Be $true
            $result.Action | Should -Be 'no-op'
            $script:PatchLog.Count | Should -Be 0
        }

        It 'converges CRLF-bodied stored comment vs LF payload to a no-op' {
            $marker = $script:UpsertFamily.MarkerTemplate -replace '\{ID\}', "$script:IssueNumber"
            $crlfStored = "$marker`r`n`r`nSame content.`r`n"
            $lfPayload = "$marker`n`nSame content."
            Add-MockComment -Id 100 -Body $crlfStored

            $result = Invoke-PersistMarkerWrite -Family $script:UpsertFamily.Family -Owner $script:Owner -Repo $script:Repo -Number $script:IssueNumber -TargetSurface 'issue' -Marker $marker -Body $lfPayload

            $result.Success | Should -Be $true
            $result.Action | Should -Be 'no-op'
            $script:PatchLog.Count | Should -Be 0
        }

        It 'reports failure (never Success=$true) when the post-PATCH read-back is corrupted by a same-length substitution' {
            $marker = $script:UpsertFamily.MarkerTemplate -replace '\{ID\}', "$script:IssueNumber"
            Add-MockComment -Id 100 -Body "$marker`n`nOld body with several letter e characters."
            $newBody = "$marker`n`nUpdated body with several letter e characters."
            $script:CorruptReadBackIds.Add(100) | Out-Null

            $result = Invoke-PersistMarkerWrite -Family $script:UpsertFamily.Family -Owner $script:Owner -Repo $script:Repo -Number $script:IssueNumber -TargetSurface 'issue' -Marker $marker -Body $newBody

            $result.Success | Should -Be $false
            $result.Reason | Should -Match '(?i)read-back|normalized'
        }
    }

    Context 'surface-mismatch refusal' {
        It 'refuses pre-write, naming the mismatch, when the declared TargetSurface does not match the registry row, without issuing any gh calls' {
            $issueOnlyFamily = @(Get-MarkerFamilyRegistry | Where-Object { $_.TargetSurface -eq 'issue' })[0]
            $marker = $issueOnlyFamily.MarkerTemplate -replace '\{ID\}', '999'
            $body = "$marker`n`nBody."

            $result = Invoke-PersistMarkerWrite -Family $issueOnlyFamily.Family -Owner $script:Owner -Repo $script:Repo -Number 999 -TargetSurface 'pull-request' -Marker $marker -Body $body

            $result.Success | Should -Be $false
            $result.Reason | Should -Match '(?i)surface'
            $escapedFamily = [regex]::Escape($issueOnlyFamily.Family)
            $result.Reason | Should -Match $escapedFamily
            $script:ghCallLog.Count | Should -Be 0
        }

        It 'refuses an unknown marker family before issuing any gh calls' {
            $result = Invoke-PersistMarkerWrite -Family 'not-a-real-family' -Owner $script:Owner -Repo $script:Repo -Number 999 -TargetSurface 'issue' -Marker '<!-- not-a-real-family-999 -->' -Body 'x'

            $result.Success | Should -Be $false
            $result.Reason | Should -Match '(?i)unknown|registry'
            $script:ghCallLog.Count | Should -Be 0
        }
    }

    Context 'Refusal message shape (893-D6)' {
        It 'formats every refusal as "persist-marker: REFUSED ({family}, {target}): {detail}"' {
            $result = Invoke-PersistMarkerWrite -Family 'not-a-real-family' -Owner $script:Owner -Repo $script:Repo -Number 999 -TargetSurface 'issue' -Marker '<!-- not-a-real-family-999 -->' -Body 'x'

            $result.Success | Should -Be $false
            $result.Reason | Should -Match '^persist-marker: REFUSED \(not-a-real-family, issue/999\): '
        }

        It 'length-bounds an echoed oversized field value in a refusal detail rather than dumping it verbatim' {
            $marker = $script:CreditInputFamily.MarkerTemplate -replace '\{port\}', 'plan' -replace '\{ID\}', "$script:IssueNumber"
            $oversizedPort = 'x' * 200
            $body = "$marker`n`n``````yaml`nport: $oversizedPort`nadapter: skills/plan-authoring/adapters/plan-adapter.md`nevidence: issue-893-plan-marker-posted`n``````"

            $result = Invoke-PersistMarkerWrite -Family $script:CreditInputFamily.Family -Owner $script:Owner -Repo $script:Repo -Number $script:IssueNumber -TargetSurface 'issue' -Marker $marker -Body $body

            $result.Success | Should -Be $false
            $result.Reason | Should -Not -Match ([regex]::Escape($oversizedPort))
            $result.Reason | Should -Match '\.\.\.\(\+\d+ more chars, truncated\)'
            $script:ghCallLog.Count | Should -Be 0
        }
    }

    Context 'Payload hygiene: 893-D7 (s9 amendment -- both rules refuse, never warn)' {
        It 'refuses when the candidate carries its own family marker more than once (also at line 1), naming the NUMERIC line offset of the extra occurrence (M3/M7, issue #893 s11)' {
            $marker = $script:PostNewFamily.MarkerTemplate -replace '\{ID\}', "$script:IssueNumber"
            $body = "$marker`n`nSome content.`n$marker`n`nMore content, marker repeated below line 1."

            $result = Invoke-PersistMarkerWrite -Family $script:PostNewFamily.Family -Owner $script:Owner -Repo $script:Repo -Number $script:IssueNumber -TargetSurface 'issue' -Marker $marker -Body $body

            $result.Success | Should -Be $false
            $result.Reason | Should -Match '(?i)more than once'
            $result.Reason | Should -Match '(?i)double-marker'
            # M7: the offset must be a real, correctly-computed line NUMBER
            # (line 4, 0-based index 3) -- not a stringified array like
            # "0 3" produced by the old pipe-through-Where-Object bug.
            $result.Reason | Should -Match '(?<!\d)line 4(?!\d)'
            $result.Reason | Should -Match '^persist-marker: REFUSED \('
            $script:ghCallLog.Count | Should -Be 0
        }

        It 'refuses when the candidate is missing its own family marker entirely (M3, issue #893 s11)' {
            $marker = $script:PostNewFamily.MarkerTemplate -replace '\{ID\}', "$script:IssueNumber"
            # Candidate body carries no occurrence of $marker at all -- a
            # marker-less body would post/patch unfindably, silently
            # breaking idempotency on every later run.
            $body = "Some content with no marker at all.`n`nMore content."

            $result = Invoke-PersistMarkerWrite -Family $script:PostNewFamily.Family -Owner $script:Owner -Repo $script:Repo -Number $script:IssueNumber -TargetSurface 'issue' -Marker $marker -Body $body

            $result.Success | Should -Be $false
            $result.Reason | Should -Match '(?i)missing.*marker|marker.*missing'
            $result.Reason | Should -Match '^persist-marker: REFUSED \('
            $script:ghCallLog.Count | Should -Be 0
        }

        It 'refuses when the candidate carries its own family marker exactly once but NOT at line 1, naming the numeric line it actually landed on (M3/M7, issue #893 s11)' {
            $marker = $script:PostNewFamily.MarkerTemplate -replace '\{ID\}', "$script:IssueNumber"
            $body = "Some preamble content.`n`n$marker`n`nBody content after the marker."

            $result = Invoke-PersistMarkerWrite -Family $script:PostNewFamily.Family -Owner $script:Owner -Repo $script:Repo -Number $script:IssueNumber -TargetSurface 'issue' -Marker $marker -Body $body

            $result.Success | Should -Be $false
            $result.Reason | Should -Match '(?i)missing from line 1'
            # Single occurrence, wrong position -- must NOT be misdiagnosed as
            # a double-marker-emission case.
            $result.Reason | Should -Not -Match '(?i)double-marker|more than once'
            # $marker is on line 3 (0-based index 2).
            $result.Reason | Should -Match '(?<!\d)line 3(?!\d)'
            $script:ghCallLog.Count | Should -Be 0
        }

        It 'refuses when the candidate carries another registered family''s live marker literal at line start, without issuing any gh calls' {
            $marker = $script:PostNewFamily.MarkerTemplate -replace '\{ID\}', "$script:IssueNumber"
            $otherMarker = $script:UpsertFamily.MarkerTemplate -replace '\{ID\}', '42'
            $body = "$marker`n`nSome content.`n$otherMarker`n`nA decoy live marker from a different family."

            $result = Invoke-PersistMarkerWrite -Family $script:PostNewFamily.Family -Owner $script:Owner -Repo $script:Repo -Number $script:IssueNumber -TargetSurface 'issue' -Marker $marker -Body $body

            $result.Success | Should -Be $false
            $result.Reason | Should -Match '(?i)another registered family'
            $escapedOtherFamily = [regex]::Escape($script:UpsertFamily.Family)
            $result.Reason | Should -Match $escapedOtherFamily
            $script:ghCallLog.Count | Should -Be 0
        }

        It 'does NOT refuse an inert-rendered (HTML-entity-escaped) mention of another family''s marker at line start (false-positive guard)' {
            $marker = $script:PostNewFamily.MarkerTemplate -replace '\{ID\}', "$script:IssueNumber"
            $inertMention = ($script:UpsertFamily.MarkerTemplate -replace '\{ID\}', '42') -replace '<!--', '&lt;!--' -replace '-->', '--&gt;'
            $body = "$marker`n`nExample of the marker syntax:`n$inertMention`n`nRest of the body."

            $result = Invoke-PersistMarkerWrite -Family $script:PostNewFamily.Family -Owner $script:Owner -Repo $script:Repo -Number $script:IssueNumber -TargetSurface 'issue' -Marker $marker -Body $body

            $result.Success | Should -Be $true
            $result.Action | Should -Be 'posted'
        }

        It 'refuses when the candidate carries a LIVE but unregistered family''s marker literal at line start -- frame-credit-ledger (M8, issue #893 s11)' {
            $marker = $script:PostNewFamily.MarkerTemplate -replace '\{ID\}', "$script:IssueNumber"
            $body = "$marker`n`nSome content.`n<!-- frame-credit-ledger-42 -->`n`nA decoy live marker from a family with no write-registry row."

            $result = Invoke-PersistMarkerWrite -Family $script:PostNewFamily.Family -Owner $script:Owner -Repo $script:Repo -Number $script:IssueNumber -TargetSurface 'issue' -Marker $marker -Body $body

            $result.Success | Should -Be $false
            $result.Reason | Should -Match '(?i)another registered family'
            $result.Reason | Should -Match 'frame-credit-ledger'
            $script:ghCallLog.Count | Should -Be 0
        }

        It 'refuses when the candidate carries a LIVE but unregistered family''s marker literal at line start -- phase-containment-ledger (M8, issue #893 s11)' {
            $marker = $script:PostNewFamily.MarkerTemplate -replace '\{ID\}', "$script:IssueNumber"
            $body = "$marker`n`nSome content.`n<!-- phase-containment-ledger-42 -->`n`nA decoy live marker from a family with no write-registry row."

            $result = Invoke-PersistMarkerWrite -Family $script:PostNewFamily.Family -Owner $script:Owner -Repo $script:Repo -Number $script:IssueNumber -TargetSurface 'issue' -Marker $marker -Body $body

            $result.Success | Should -Be $false
            $result.Reason | Should -Match '(?i)another registered family'
            $result.Reason | Should -Match 'phase-containment-ledger'
            $script:ghCallLog.Count | Should -Be 0
        }
    }

    Context 'engagement-record validator adapter' {
        It 'passes a well-formed candidate through to the write' {
            $marker = $script:EngagementRecordFamily.MarkerTemplate -replace '\{phase\}', 'plan' -replace '\{ID\}', "$script:IssueNumber"
            $body = "$marker`n`n$script:EngagementRecordValidYaml"

            $result = Invoke-PersistMarkerWrite -Family $script:EngagementRecordFamily.Family -Owner $script:Owner -Repo $script:Repo -Number $script:IssueNumber -TargetSurface 'issue' -Marker $marker -Body $body

            $result.Success | Should -Be $true
            $result.Action | Should -Be 'posted'
        }

        It 'refuses a malformed candidate (invalid decision_id slug), naming it, without issuing any gh calls' {
            $marker = $script:EngagementRecordFamily.MarkerTemplate -replace '\{phase\}', 'plan' -replace '\{ID\}', "$script:IssueNumber"
            $body = "$marker`n`n$script:EngagementRecordInvalidYaml"

            $result = Invoke-PersistMarkerWrite -Family $script:EngagementRecordFamily.Family -Owner $script:Owner -Repo $script:Repo -Number $script:IssueNumber -TargetSurface 'issue' -Marker $marker -Body $body

            $result.Success | Should -Be $false
            $result.Reason | Should -Match 'Not_A_Valid_Slug'
            $script:ghCallLog.Count | Should -Be 0
        }

        It 'fails closed (refuses) when Read-EngagementRecords is not in scope (adapter infrastructure failure)' {
            Remove-Item Function:Read-EngagementRecords -ErrorAction SilentlyContinue

            $marker = $script:EngagementRecordFamily.MarkerTemplate -replace '\{phase\}', 'plan' -replace '\{ID\}', "$script:IssueNumber"
            $body = "$marker`n`n$script:EngagementRecordValidYaml"

            $result = Invoke-PersistMarkerWrite -Family $script:EngagementRecordFamily.Family -Owner $script:Owner -Repo $script:Repo -Number $script:IssueNumber -TargetSurface 'issue' -Marker $marker -Body $body

            $result.Success | Should -Be $false
            $result.Reason | Should -Match '(?i)infrastructure failure'
            $script:ghCallLog.Count | Should -Be 0
        }
    }

    Context 'review-dispositions validator adapter' {
        It 'passes a well-formed candidate through to the write' {
            $marker = $script:ReviewDispositionsFamily.MarkerTemplate -replace '\{PR\}', "$script:PrNumber"
            $body = "$marker`n`n$script:ReviewDispositionsValidYaml"

            $result = Invoke-PersistMarkerWrite -Family $script:ReviewDispositionsFamily.Family -Owner $script:Owner -Repo $script:Repo -Number $script:PrNumber -TargetSurface 'pull-request' -Marker $marker -Body $body

            $result.Success | Should -Be $true
            $result.Action | Should -Be 'posted'
        }

        It 'refuses a malformed candidate (missing disposition_rationale), naming it, without issuing any gh calls' {
            $marker = $script:ReviewDispositionsFamily.MarkerTemplate -replace '\{PR\}', "$script:PrNumber"
            $body = "$marker`n`n$script:ReviewDispositionsInvalidYaml"

            $result = Invoke-PersistMarkerWrite -Family $script:ReviewDispositionsFamily.Family -Owner $script:Owner -Repo $script:Repo -Number $script:PrNumber -TargetSurface 'pull-request' -Marker $marker -Body $body

            $result.Success | Should -Be $false
            $result.Reason | Should -Match '(?i)disposition_rationale'
            $script:ghCallLog.Count | Should -Be 0
        }

        It 'fails closed (refuses) when the validator script cannot be found (adapter infrastructure failure)' {
            $originalPath = $script:ReviewDispositionsValidatorScriptPath
            $script:ReviewDispositionsValidatorScriptPath = Join-Path $PSScriptRoot 'does-not-exist-review-dispositions-validator-core.ps1'
            try {
                $marker = $script:ReviewDispositionsFamily.MarkerTemplate -replace '\{PR\}', "$script:PrNumber"
                $body = "$marker`n`n$script:ReviewDispositionsValidYaml"

                $result = Invoke-PersistMarkerWrite -Family $script:ReviewDispositionsFamily.Family -Owner $script:Owner -Repo $script:Repo -Number $script:PrNumber -TargetSurface 'pull-request' -Marker $marker -Body $body

                $result.Success | Should -Be $false
                $result.Reason | Should -Match '(?i)infrastructure failure'
                $script:ghCallLog.Count | Should -Be 0
            }
            finally {
                $script:ReviewDispositionsValidatorScriptPath = $originalPath
            }
        }
    }

    Context 'credit-input validator adapter (in-core)' {
        It 'passes a well-formed candidate through to the write' {
            $marker = $script:CreditInputFamily.MarkerTemplate -replace '\{port\}', 'plan' -replace '\{ID\}', "$script:IssueNumber"
            $body = "$marker`n`n$script:CreditInputValidYaml"

            $result = Invoke-PersistMarkerWrite -Family $script:CreditInputFamily.Family -Owner $script:Owner -Repo $script:Repo -Number $script:IssueNumber -TargetSurface 'issue' -Marker $marker -Body $body

            $result.Success | Should -Be $true
            $result.Action | Should -Be 'posted'
        }

        It 'refuses a candidate with an invalid port, without issuing any gh calls' {
            $marker = $script:CreditInputFamily.MarkerTemplate -replace '\{port\}', 'plan' -replace '\{ID\}', "$script:IssueNumber"
            $body = "$marker`n`n$script:CreditInputInvalidPortYaml"

            $result = Invoke-PersistMarkerWrite -Family $script:CreditInputFamily.Family -Owner $script:Owner -Repo $script:Repo -Number $script:IssueNumber -TargetSurface 'issue' -Marker $marker -Body $body

            $result.Success | Should -Be $false
            $result.Reason | Should -Match '(?i)invalid port'
            $script:ghCallLog.Count | Should -Be 0
        }

        It 'refuses a candidate whose evidence field is a nested mapping, without issuing any gh calls' {
            $marker = $script:CreditInputFamily.MarkerTemplate -replace '\{port\}', 'plan' -replace '\{ID\}', "$script:IssueNumber"
            $body = "$marker`n`n$script:CreditInputNestedEvidenceYaml"

            $result = Invoke-PersistMarkerWrite -Family $script:CreditInputFamily.Family -Owner $script:Owner -Repo $script:Repo -Number $script:IssueNumber -TargetSurface 'issue' -Marker $marker -Body $body

            $result.Success | Should -Be $false
            $result.Reason | Should -Match '(?i)nested mapping'
            $script:ghCallLog.Count | Should -Be 0
        }
    }

    Context 'sentinel-empty validator adapter' {
        It 'passes a marker-only candidate through to the write' {
            $marker = $script:SentinelFamily.MarkerTemplate -replace '\{PR\}', "$script:PrNumber"

            $result = Invoke-PersistMarkerWrite -Family $script:SentinelFamily.Family -Owner $script:Owner -Repo $script:Repo -Number $script:PrNumber -TargetSurface 'pull-request' -Marker $marker -Body $marker

            $result.Success | Should -Be $true
            $result.Action | Should -Be 'posted'
        }

        It 'refuses a candidate carrying extra content beyond the marker, without issuing any gh calls' {
            $marker = $script:SentinelFamily.MarkerTemplate -replace '\{PR\}', "$script:PrNumber"
            $body = "$marker`n`nUnexpected extra content."

            $result = Invoke-PersistMarkerWrite -Family $script:SentinelFamily.Family -Owner $script:Owner -Repo $script:Repo -Number $script:PrNumber -TargetSurface 'pull-request' -Marker $marker -Body $body

            $result.Success | Should -Be $false
            $result.Reason | Should -Match '(?i)empty.*marker-only|marker-only.*payload'
            $script:ghCallLog.Count | Should -Be 0
        }
    }

    Context 'frame-slices registry row (s5)' {
        It 'is present as an upsert family with the frame-slices-spine-splice PostStep' {
            $script:FrameSlicesFamily.Family | Should -Be 'frame-slices'
            $script:FrameSlicesFamily.WriteShape | Should -Be 'upsert'
            $script:FrameSlicesFamily.TargetSurface | Should -Be 'issue'
            $script:FrameSlicesFamily.PostStep | Should -Be 'frame-slices-spine-splice'
        }

        It 'declares plan-issue''s PostStep as plan-issue-write-back-preserve' {
            $script:UpsertFamily.Family | Should -Be 'plan-issue'
            $script:UpsertFamily.PostStep | Should -Be 'plan-issue-write-back-preserve'
        }
    }

    Context 'plan-issue write-back-preserve post-step (s5)' {
        BeforeEach {
            $script:PlanMarker = $script:UpsertFamily.MarkerTemplate -replace '\{ID\}', "$script:IssueNumber"
        }

        It 'preserves a valid phase-containment-ledger-ref pointer the candidate omits, live-checking the sibling first' {
            $ledgerMarker = "<!-- phase-containment-ledger-$script:IssueNumber -->"
            Add-MockComment -Id 500 -Body "$ledgerMarker`n`nSibling content."
            $existingBody = "$script:PlanMarker`n<!-- phase-containment-ledger-ref: 500 -->`n`nOld plan prose."
            Add-MockComment -Id 100 -Body $existingBody
            $candidateBody = "$script:PlanMarker`n`nFresh plan prose, no pointer."

            $result = Invoke-PersistMarkerWrite -Family $script:UpsertFamily.Family -Owner $script:Owner -Repo $script:Repo -Number $script:IssueNumber -TargetSurface 'issue' -Marker $script:PlanMarker -Body $candidateBody

            $result.Success | Should -Be $true
            $script:PatchLog.Count | Should -Be 1
            $script:PatchLog[0].Body | Should -Match ([regex]::Escape('<!-- phase-containment-ledger-ref: 500 -->'))
            $result.Confirmation | Should -Match 'phase-containment-ledger-ref pointer'
        }

        It 'DROPS a stale/forged pointer (target sibling missing its own identity marker) rather than preserving it' {
            Add-MockComment -Id 501 -Body 'Not a real ledger sibling -- no identity marker.'
            $existingBody = "$script:PlanMarker`n<!-- phase-containment-ledger-ref: 501 -->`n`nOld plan prose."
            Add-MockComment -Id 100 -Body $existingBody
            $candidateBody = "$script:PlanMarker`n`nFresh plan prose, no pointer."

            $result = Invoke-PersistMarkerWrite -Family $script:UpsertFamily.Family -Owner $script:Owner -Repo $script:Repo -Number $script:IssueNumber -TargetSurface 'issue' -Marker $script:PlanMarker -Body $candidateBody

            $result.Success | Should -Be $true
            $script:PatchLog[0].Body | Should -Not -Match ([regex]::Escape('phase-containment-ledger-ref: 501'))
            $result.Confirmation | Should -Not -Match 'phase-containment-ledger-ref pointer'
        }

        It 'DROPS a pointer whose target comment no longer exists (GET fails), falling through to self-heal' {
            $existingBody = "$script:PlanMarker`n<!-- phase-containment-ledger-ref: 9999 -->`n`nOld plan prose."
            Add-MockComment -Id 100 -Body $existingBody
            $candidateBody = "$script:PlanMarker`n`nFresh plan prose, no pointer."

            $result = Invoke-PersistMarkerWrite -Family $script:UpsertFamily.Family -Owner $script:Owner -Repo $script:Repo -Number $script:IssueNumber -TargetSurface 'issue' -Marker $script:PlanMarker -Body $candidateBody

            $result.Success | Should -Be $true
            $script:PatchLog[0].Body | Should -Not -Match ([regex]::Escape('phase-containment-ledger-ref: 9999'))
        }

        It 'preserves slice_comment_id in the frame-spine block when the candidate omits it and the sibling identity marker is valid' {
            $sliceMarker = "<!-- frame-slices-$script:IssueNumber -->"
            Add-MockComment -Id 600 -Body "$sliceMarker`n<!-- frame-slices-generated-at: 2026-07-01T00:00:00Z -->`n`nSlices."
            $existingBody = @"
$script:PlanMarker

<!-- frame-spine
spine_schema_version: 2
generated_at: 2026-07-01T00:00:00Z
coverage: complete
slice_comment_id: 600
ports:
  implement-code: [s1]
slices:
  s1:
    ac_refs: [AC1]
    depends_on: []
    cycle: 1
-->

Old plan prose.
"@
            Add-MockComment -Id 100 -Body $existingBody
            $candidateBody = @"
$script:PlanMarker

<!-- frame-spine
spine_schema_version: 2
generated_at: 2026-07-02T00:00:00Z
coverage: complete
ports:
  implement-code: [s1]
slices:
  s1:
    ac_refs: [AC1]
    depends_on: []
    cycle: 1
-->

Fresh plan prose.
"@

            $result = Invoke-PersistMarkerWrite -Family $script:UpsertFamily.Family -Owner $script:Owner -Repo $script:Repo -Number $script:IssueNumber -TargetSurface 'issue' -Marker $script:PlanMarker -Body $candidateBody

            $result.Success | Should -Be $true
            $script:PatchLog[0].Body | Should -Match '(?m)^slice_comment_id:\s*600\s*$'
            $result.Confirmation | Should -Match 'slice_comment_id \(frame-spine\)'
        }

        It 'does NOT fabricate a slice_comment_id when the existing (legacy) plan genuinely has none' {
            $existingBody = @"
$script:PlanMarker

<!-- frame-spine
spine_schema_version: 2
generated_at: 2026-07-01T00:00:00Z
coverage: complete
ports:
  implement-code: [s1]
slices:
  s1:
    ac_refs: [AC1]
    depends_on: []
    cycle: 1
-->

Old plan prose.
"@
            Add-MockComment -Id 100 -Body $existingBody
            $candidateBody = @"
$script:PlanMarker

<!-- frame-spine
spine_schema_version: 2
generated_at: 2026-07-02T00:00:00Z
coverage: complete
ports:
  implement-code: [s1]
slices:
  s1:
    ac_refs: [AC1]
    depends_on: []
    cycle: 1
-->

Fresh plan prose.
"@

            $result = Invoke-PersistMarkerWrite -Family $script:UpsertFamily.Family -Owner $script:Owner -Repo $script:Repo -Number $script:IssueNumber -TargetSurface 'issue' -Marker $script:PlanMarker -Body $candidateBody

            $result.Success | Should -Be $true
            $script:PatchLog[0].Body | Should -Not -Match 'slice_comment_id'
        }

        It 'preserves legacy judge-rulings head and phase-containment blocks living directly on the plan comment (no ledger pointer)' {
            $existingBody = @"
$script:PlanMarker

Old plan prose.

**Plan Stress-Test**

- Challenge: something - Prosecution: pass - Post-judge ruling: sustained - Maintainer disposition: incorporate

<!-- phase-containment-legacy1 -->
finding_key: plan-stress-test:$($script:IssueNumber):legacy:M1
introduced_phase: design
catchable_phase: plan
caught_stage: plan-stress-test
escape_distance: 0
severity: medium
systemic_fix_type: instruction
category: pattern
apparatus_meta: false
appended_at: 2026-07-01T00:00:00Z
<!-- /phase-containment-legacy1 -->

<!-- judge-rulings
- finding_id: M1
  judge_ruling: sustained
-->
"@
            Add-MockComment -Id 100 -Body $existingBody
            $candidateBody = "$script:PlanMarker`n`nFresh plan prose, revised."

            $result = Invoke-PersistMarkerWrite -Family $script:UpsertFamily.Family -Owner $script:Owner -Repo $script:Repo -Number $script:IssueNumber -TargetSurface 'issue' -Marker $script:PlanMarker -Body $candidateBody

            $result.Success | Should -Be $true
            $script:PatchLog[0].Body | Should -Match '<!--\s*judge-rulings'
            $script:PatchLog[0].Body | Should -Match '<!--\s*phase-containment-legacy1\s*-->'
            $result.Confirmation | Should -Match 'legacy judge-rulings head'
            $result.Confirmation | Should -Match 'legacy phase-containment blocks'
        }

        It 'preserves the **Plan Stress-Test** heading/section when the candidate omits it entirely' {
            $existingBody = @"
$script:PlanMarker

Old plan prose.

**Plan Stress-Test**

- Challenge: something - Prosecution: pass - Post-judge ruling: sustained - Maintainer disposition: incorporate
- Overall confidence: high - clean pass.
"@
            Add-MockComment -Id 100 -Body $existingBody
            $candidateBody = "$script:PlanMarker`n`nFresh plan prose, revised, stress-test summary omitted by mistake."

            $result = Invoke-PersistMarkerWrite -Family $script:UpsertFamily.Family -Owner $script:Owner -Repo $script:Repo -Number $script:IssueNumber -TargetSurface 'issue' -Marker $script:PlanMarker -Body $candidateBody

            $result.Success | Should -Be $true
            $script:PatchLog[0].Body | Should -Match '\*\*Plan Stress-Test\*\*'
            $result.Confirmation | Should -Match '\*\*Plan Stress-Test\*\* heading/section'
        }

        It 'skips ALL preservation when -NoPreserve is set, even for an otherwise-valid pointer' {
            $ledgerMarker = "<!-- phase-containment-ledger-$script:IssueNumber -->"
            Add-MockComment -Id 500 -Body "$ledgerMarker`n`nSibling content."
            $existingBody = "$script:PlanMarker`n<!-- phase-containment-ledger-ref: 500 -->`n`nOld plan prose."
            Add-MockComment -Id 100 -Body $existingBody
            $candidateBody = "$script:PlanMarker`n`nFresh plan prose, deliberately clearing the pointer."

            $result = Invoke-PersistMarkerWrite -Family $script:UpsertFamily.Family -Owner $script:Owner -Repo $script:Repo -Number $script:IssueNumber -TargetSurface 'issue' -Marker $script:PlanMarker -Body $candidateBody -NoPreserve

            $result.Success | Should -Be $true
            $script:PatchLog[0].Body | Should -Not -Match 'phase-containment-ledger-ref'
        }
    }

    Context 'frame-slices spine-splice post-step (s5)' {
        BeforeEach {
            $script:SliceMarker = $script:FrameSlicesFamily.MarkerTemplate -replace '\{ID\}', "$script:IssueNumber"
            $script:PlanMarkerForSplice = "<!-- plan-issue-$script:IssueNumber -->"
        }

        It 'splices the fresh sibling id into the plan comment''s frame-spine when generated_at matches' {
            $planBody = @"
$script:PlanMarkerForSplice

<!-- frame-spine
spine_schema_version: 2
generated_at: 2026-07-16T18:00:00Z
coverage: complete
ports:
  implement-code: [s1]
slices:
  s1:
    ac_refs: [AC1]
    depends_on: []
    cycle: 1
-->

Plan prose.
"@
            Add-MockComment -Id 100 -Body $planBody
            $sliceBody = "$script:SliceMarker`n<!-- frame-slices-generated-at: 2026-07-16T18:00:00Z -->`n`n<!-- frame-slice`nid: s1`n-->"

            $result = Invoke-PersistMarkerWrite -Family $script:FrameSlicesFamily.Family -Owner $script:Owner -Repo $script:Repo -Number $script:IssueNumber -TargetSurface 'issue' -Marker $script:SliceMarker -Body $sliceBody

            $result.Success | Should -Be $true
            $result.Action | Should -Be 'created'
            $newSiblingId = $result.CommentId
            # Two PATCHes never happen for the plan comment on first create -- the
            # splice targets the plan comment (id 100), a distinct id from the
            # freshly-created sibling.
            $planPatch = @($script:PatchLog | Where-Object { $_.CommentId -eq 100 })
            $planPatch.Count | Should -Be 1
            $planPatch[0].Body | Should -Match "(?m)^slice_comment_id:\s*$newSiblingId\s*$"
        }

        It 'REFUSES (Success=$false) when the PATCHed plan comment''s read-back is subtly corrupted, even though the PATCH itself exit-0''d and the inherited >=50%-length truncation guard alone would miss it (M5, issue #893 s11)' {
            # Mojibake-style corruption LENGTHENS text rather than shortening
            # it -- Set-CommentBodyDirect's own inherited truncation guard
            # only refuses on GROSS shortening, so it stays green here. Only
            # a SEPARATE, dedicated Test-MarkerReadBack call (normalized
            # EQUALITY, not a length heuristic) can catch this class -- the
            # exact fix M5 adds, mirroring both write shapes' own read-back
            # discipline.
            $planBody = @"
$script:PlanMarkerForSplice

<!-- frame-spine
spine_schema_version: 2
generated_at: 2026-07-16T18:00:00Z
coverage: complete
ports:
  implement-code: [s1]
slices:
  s1:
    ac_refs: [AC1]
    depends_on: []
    cycle: 1
-->

Plan prose.
"@
            Add-MockComment -Id 100 -Body $planBody
            $script:CorruptReadBackIds.Add(100) | Out-Null
            $sliceBody = "$script:SliceMarker`n<!-- frame-slices-generated-at: 2026-07-16T18:00:00Z -->`n`n<!-- frame-slice`nid: s1`n-->"

            $result = Invoke-PersistMarkerWrite -Family $script:FrameSlicesFamily.Family -Owner $script:Owner -Repo $script:Repo -Number $script:IssueNumber -TargetSurface 'issue' -Marker $script:SliceMarker -Body $sliceBody

            # The sibling write itself still landed -- the refusal is about
            # the splice-back read-back, not the sibling creation.
            $script:PostLog.Count | Should -Be 1
            $result.Success | Should -Be $false
            $result.Reason | Should -Match '(?i)read-back'
        }

        It 'splices into a frame-spine block using the canonical parser''s OTHER legal form -- a self-closing HTML-comment open tag followed by the payload as plain text (M6, issue #893 s11)' {
            # frame-spine-core.ps1's own Get-FSCCommentBlockPayloads accepts
            # TWO legal block forms (its regex has two alternation
            # branches). Set-MarkerSpineScalarValue's narrower regex
            # previously matched only the "open-tag-then-newline" form
            # (`<!-- frame-spine\n...-->`), so this SECOND form -- a
            # self-closing open tag `<!-- frame-spine -->` followed by the
            # payload as plain text up to a trailing `-->` -- would silently
            # fail to match, returning the body UNCHANGED while the caller
            # still reported the splice as a success.
            $planBody = @"
$script:PlanMarkerForSplice

<!-- frame-spine -->
spine_schema_version: 2
generated_at: 2026-07-16T18:00:00Z
coverage: complete
ports:
  implement-code: [s1]
slices:
  s1:
    ac_refs: [AC1]
    depends_on: []
    cycle: 1
-->

Plan prose that must survive.
"@
            Add-MockComment -Id 100 -Body $planBody
            $sliceBody = "$script:SliceMarker`n<!-- frame-slices-generated-at: 2026-07-16T18:00:00Z -->`n`n<!-- frame-slice`nid: s1`n-->"

            $result = Invoke-PersistMarkerWrite -Family $script:FrameSlicesFamily.Family -Owner $script:Owner -Repo $script:Repo -Number $script:IssueNumber -TargetSurface 'issue' -Marker $script:SliceMarker -Body $sliceBody

            $result.Success | Should -Be $true
            $newSiblingId = $result.CommentId
            $planPatch = @($script:PatchLog | Where-Object { $_.CommentId -eq 100 })
            # The splice must have ACTUALLY happened -- a silent no-op would
            # report Action='spliced'/Success=$true while never PATCHing the
            # plan comment at all (Set-MarkerSpineScalarValue returning the
            # body unchanged short-circuits the "already carries the correct
            # slice_comment_id" no-op branch upstream, since the value never
            # changes from absent to present).
            $planPatch.Count | Should -Be 1
            $planPatch[0].Body | Should -Match "(?m)^slice_comment_id:\s*$newSiblingId\s*$"
            $planPatch[0].Body | Should -Match 'Plan prose that must survive\.'
        }

        It 'REFUSES (Success=$false) when the issue carries no plan-issue-{ID} marker at all' {
            $sliceBody = "$script:SliceMarker`n<!-- frame-slices-generated-at: 2026-07-16T18:00:00Z -->`n`n<!-- frame-slice`nid: s1`n-->"

            $result = Invoke-PersistMarkerWrite -Family $script:FrameSlicesFamily.Family -Owner $script:Owner -Repo $script:Repo -Number $script:IssueNumber -TargetSurface 'issue' -Marker $script:SliceMarker -Body $sliceBody

            $result.Success | Should -Be $false
            $result.Reason | Should -Match '(?i)plan-issue.*not found|no comment carrying marker'
            # The sibling write itself still landed -- the refusal is about the
            # splice-back, not the sibling creation.
            $script:PostLog.Count | Should -Be 1
        }

        It 'REFUSES (Success=$false) when the sibling''s frame-slices-generated-at does not equal the plan spine''s generated_at (stale sibling)' {
            $planBody = @"
$script:PlanMarkerForSplice

<!-- frame-spine
spine_schema_version: 2
generated_at: 2026-07-16T18:00:00Z
coverage: complete
ports:
  implement-code: [s1]
slices:
  s1:
    ac_refs: [AC1]
    depends_on: []
    cycle: 1
-->

Plan prose.
"@
            Add-MockComment -Id 100 -Body $planBody
            $sliceBody = "$script:SliceMarker`n<!-- frame-slices-generated-at: 2020-01-01T00:00:00Z -->`n`n<!-- frame-slice`nid: s1`n-->"

            $result = Invoke-PersistMarkerWrite -Family $script:FrameSlicesFamily.Family -Owner $script:Owner -Repo $script:Repo -Number $script:IssueNumber -TargetSurface 'issue' -Marker $script:SliceMarker -Body $sliceBody

            $result.Success | Should -Be $false
            $result.Reason | Should -Match '(?i)generated_at mismatch'
            $planPatch = @($script:PatchLog | Where-Object { $_.CommentId -eq 100 })
            $planPatch.Count | Should -Be 0
        }

        It 'is a no-op (never PATCHes the plan comment) when the plan already carries the correct slice_comment_id' {
            $planBody = @"
$script:PlanMarkerForSplice

<!-- frame-spine
spine_schema_version: 2
generated_at: 2026-07-16T18:00:00Z
coverage: complete
slice_comment_id: 700
ports:
  implement-code: [s1]
slices:
  s1:
    ac_refs: [AC1]
    depends_on: []
    cycle: 1
-->

Plan prose.
"@
            Add-MockComment -Id 100 -Body $planBody
            Add-MockComment -Id 700 -Body "$script:SliceMarker`n<!-- frame-slices-generated-at: 2026-07-16T18:00:00Z -->`n`n<!-- frame-slice`nid: s1`n-->"
            $sliceBody = "$script:SliceMarker`n<!-- frame-slices-generated-at: 2026-07-16T18:00:00Z -->`n`n<!-- frame-slice`nid: s1`nupdated: true`n-->"

            $result = Invoke-PersistMarkerWrite -Family $script:FrameSlicesFamily.Family -Owner $script:Owner -Repo $script:Repo -Number $script:IssueNumber -TargetSurface 'issue' -Marker $script:SliceMarker -Body $sliceBody

            $result.Success | Should -Be $true
            $planPatch = @($script:PatchLog | Where-Object { $_.CommentId -eq 100 })
            $planPatch.Count | Should -Be 0
        }

        It 'performs a bounded scalar splice -- every other byte of the plan comment is unchanged' {
            $planBody = @"
$script:PlanMarkerForSplice

<!-- frame-spine
spine_schema_version: 2
generated_at: 2026-07-16T18:00:00Z
coverage: complete
ports:
  implement-code: [s1]
slices:
  s1:
    ac_refs: [AC1]
    depends_on: []
    cycle: 1
-->

Plan prose that must survive byte-for-byte.
"@
            Add-MockComment -Id 100 -Body $planBody
            $sliceBody = "$script:SliceMarker`n<!-- frame-slices-generated-at: 2026-07-16T18:00:00Z -->`n`n<!-- frame-slice`nid: s1`n-->"

            $result = Invoke-PersistMarkerWrite -Family $script:FrameSlicesFamily.Family -Owner $script:Owner -Repo $script:Repo -Number $script:IssueNumber -TargetSurface 'issue' -Marker $script:SliceMarker -Body $sliceBody

            $result.Success | Should -Be $true
            $planPatch = @($script:PatchLog | Where-Object { $_.CommentId -eq 100 })[0]
            $newSiblingId = $result.CommentId
            # Set-MarkerSpineScalarValue inserts an absent scalar immediately
            # after the generated_at: line -- assert the splice lands exactly
            # there and every other line, including field order elsewhere in
            # the block and all prose, is untouched.
            $expectedBody = $planBody -replace '(?m)^generated_at: 2026-07-16T18:00:00Z\s*$', "generated_at: 2026-07-16T18:00:00Z`nslice_comment_id: $newSiblingId"
            $planPatch.Body | Should -Be $expectedBody
            $planPatch.Body | Should -Match 'Plan prose that must survive byte-for-byte\.'
        }
    }
}
