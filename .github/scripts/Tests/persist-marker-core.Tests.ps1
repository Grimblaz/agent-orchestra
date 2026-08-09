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
        # M20 (issue #893 s11): FlakyReadBackIds models a corruption that
        # clears itself after N GETs -- e.g. eventual-consistency/caching --
        # as opposed to CorruptReadBackIds' PERMANENT corruption. Value =
        # remaining corrupted-read count for that id, decremented on each GET.
        $script:FlakyReadBackIds = [System.Collections.Generic.Dictionary[long, int]]::new()

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
                # M19 (issue #893 s11): a TRANSIENT failure (network blip,
                # rate limit) is distinguishable, by message text, from a
                # confirmed HTTP 404 absence -- real `gh api` always includes
                # the literal HTTP status in its error text. simulateGetFailure
                # models the transient case (no "HTTP 404" in the message);
                # a genuinely-missing mock comment models the confirmed-404
                # case.
                if ($script:simulateGetFailure -contains $id) {
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
                    # Same-length homoglyph substitution: proves normalized
                    # equality is doing real rejection work that the old
                    # >=50%-length truncation guard alone would have missed
                    # (mojibake corruption LENGTHENS/holds length, never
                    # shortens it).
                    $returnedBody = $returnedBody -replace 'e', "ë"
                }
                if ($script:FlakyReadBackIds.ContainsKey($id) -and $script:FlakyReadBackIds[$id] -gt 0) {
                    $returnedBody = $returnedBody -replace 'e', "ë"
                    $script:FlakyReadBackIds[$id] = $script:FlakyReadBackIds[$id] - 1
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

        It 'M20: attempts a same-call repair-PATCH after a read-back failure, converging to Success=$true and posting only ONE comment (never accreting a duplicate) when the corruption clears' {
            $marker = $script:PostNewFamily.MarkerTemplate -replace '\{ID\}', "$script:IssueNumber"
            $body = "$marker`n`nA sentence with several letter e characters in it."

            # The just-created comment's FIRST read-back GET is corrupted
            # (models an eventual-consistency blip), then clears -- the
            # underlying stored body was always correct.
            $script:FlakyReadBackIds[$script:NextCommentId] = 1

            $result = Invoke-PersistMarkerWrite -Family $script:PostNewFamily.Family -Owner $script:Owner -Repo $script:Repo -Number $script:IssueNumber -TargetSurface 'issue' -Marker $marker -Body $body

            $result.Success | Should -Be $true
            $result.Confirmation | Should -Match '(?i)repair-PATCH'
            # Exactly one comment posted -- the repair converges WITHIN this
            # call rather than requiring an external retry that would have
            # posted a second, accreting duplicate comment.
            $script:PostLog.Count | Should -Be 1
        }

        It 'M20: on a PERSISTENT read-back mismatch, the repair-PATCH attempt also fails and the call still reports failure (never a false Success)' {
            $marker = $script:PostNewFamily.MarkerTemplate -replace '\{ID\}', "$script:IssueNumber"
            $body = "$marker`n`nA sentence with several letter e characters in it."
            $script:CorruptReadBackIds.Add($script:NextCommentId) | Out-Null

            $result = Invoke-PersistMarkerWrite -Family $script:PostNewFamily.Family -Owner $script:Owner -Repo $script:Repo -Number $script:IssueNumber -TargetSurface 'issue' -Marker $marker -Body $body

            $result.Success | Should -Be $false
            $result.Reason | Should -Match '(?i)repair-PATCH attempt also failed'
        }

        It 'P11 (issue #893 s11 post-fix): when the repair-PATCH itself fails (distinctly from the original read-back failure), the Reason names the repair''s OWN failure detail, not just the generic "also failed" with no why' {
            # Regression coverage: the repair-PATCH catch block discarded
            # the real repair-attempt failure detail (Set-CommentBodyDirect's
            # .Reason on a non-throwing failure, or the nested
            # Test-MarkerReadBack throw's own message), reporting only the
            # generic "repair-PATCH attempt also failed" -- violating the
            # 893-D6 diagnosability standard the rest of this file follows
            # (every OTHER refusal in this file names a specific reason).
            # This fixture deliberately makes the REPAIR PATCH itself fail
            # for a DIFFERENT, distinguishable reason ("PATCH failed (exit
            # 1)") than the original read-back mismatch, so an assertion
            # that only echoes the ORIGINAL failure's own message (already
            # present even before this fix) cannot pass by coincidence.
            $marker = $script:PostNewFamily.MarkerTemplate -replace '\{ID\}', "$script:IssueNumber"
            $body = "$marker`n`nA sentence with several letter e characters in it."
            $script:CorruptReadBackIds.Add($script:NextCommentId) | Out-Null
            $script:simulatePatchFailure = @($script:NextCommentId)

            $result = Invoke-PersistMarkerWrite -Family $script:PostNewFamily.Family -Owner $script:Owner -Repo $script:Repo -Number $script:IssueNumber -TargetSurface 'issue' -Marker $marker -Body $body

            $result.Success | Should -Be $false
            $result.Reason | Should -Match '(?i)repair-PATCH attempt also failed'
            # The repair PATCH's OWN distinct failure detail must be
            # present too, not just the generic wrapper text.
            $result.Reason | Should -Match '(?i)PATCH failed \(exit 1\)'
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

        It 'P1 (issue #893 s11 post-fix): the own-family hygiene anchor stays byte-symmetric with the REAL transport finder -- whatever hygiene admits at line 1 must be locatable by Find-AllCommentsByExactMarker (real transport, only gh mocked), and whatever a downstream reader cannot find must never be silently admitted as present' {
            # Regression coverage for the intra-batch fix negation defense
            # found live (issue #893 s11 postfix P1): M15 widened this
            # own-family anchor to admit `\p{Cf}` (Unicode "format" category
            # -- zero-width space U+200B, BOM/ZWNBSP U+FEFF) without
            # mirroring the widening onto Get-MarkerWholeLinePattern
            # (.github/scripts/lib/marker-transport-core.ps1:84, the real
            # finder every write/read path uses). That let a ZWSP-prefixed
            # marker pass hygiene as "present" while remaining unfindable by
            # the finder -- unbounded duplicate accretion on every
            # subsequent write. This test proves the round trip with the
            # REAL Find-AllCommentsByExactMarker primitive (dot-sourced from
            # marker-transport-core.ps1 in this file's BeforeEach), not a
            # synthetic mock of the finder, so this defect class can't hide
            # behind mock fidelity again.
            $marker = $script:PostNewFamily.MarkerTemplate -replace '\{ID\}', "$script:IssueNumber"
            $zwsp = [char]0x200B
            $zwnbsp = [char]0xFEFF
            $nbsp = [char]0x00A0

            # Case 1: a plain leading space is `\s`-matched by BOTH the
            # hygiene anchor and the real finder -- hygiene must admit it,
            # and the posted comment must be locatable afterward.
            $spaceBody = " $marker`n`nLine 1 has an ordinary leading space."
            $spaceResult = Invoke-PersistMarkerWrite -Family $script:PostNewFamily.Family -Owner $script:Owner -Repo $script:Repo -Number $script:IssueNumber -TargetSurface 'issue' -Marker $marker -Body $spaceBody
            $spaceResult.Success | Should -Be $true
            $spaceFound = @(Find-AllCommentsByExactMarker -Owner $script:Owner -Repo $script:Repo -IssueNumber $script:IssueNumber -Marker $marker)
            $spaceFound.Count | Should -Be 1
            $spaceFound[0].Id | Should -Be $spaceResult.CommentId

            # Case 2: NBSP (U+00A0) is Unicode whitespace category Zs, which
            # .NET's `\s` also matches -- hygiene must admit it, and the
            # posted comment must be locatable afterward. Uses a distinct
            # issue number so its posted comment does not collide with
            # case 1's.
            $script:mockComments.Clear()
            $nbspBody = "$nbsp$marker`n`nLine 1 starts with a non-breaking space."
            $nbspResult = Invoke-PersistMarkerWrite -Family $script:PostNewFamily.Family -Owner $script:Owner -Repo $script:Repo -Number $script:IssueNumber -TargetSurface 'issue' -Marker $marker -Body $nbspBody
            $nbspResult.Success | Should -Be $true
            $nbspFound = @(Find-AllCommentsByExactMarker -Owner $script:Owner -Repo $script:Repo -IssueNumber $script:IssueNumber -Marker $marker)
            $nbspFound.Count | Should -Be 1
            $nbspFound[0].Id | Should -Be $nbspResult.CommentId

            # Case 3/4: ZWSP (U+200B) and BOM/ZWNBSP (U+FEFF) are `\p{Cf}`
            # (Unicode "format" category), which `\s` does NOT match --
            # hygiene must REFUSE (never silently admit a body the real
            # finder could not locate), and no comment may be posted.
            foreach ($case in @(
                    @{ Name = 'ZWSP (U+200B)'; Char = $zwsp }
                    @{ Name = 'BOM/ZWNBSP (U+FEFF)'; Char = $zwnbsp }
                )) {
                $script:mockComments.Clear()
                $script:PostLog.Clear()
                $body = "$($case.Char)$marker`n`nLine 1 starts with an invisible $($case.Name) character."

                $result = Invoke-PersistMarkerWrite -Family $script:PostNewFamily.Family -Owner $script:Owner -Repo $script:Repo -Number $script:IssueNumber -TargetSurface 'issue' -Marker $marker -Body $body

                $result.Success | Should -Be $false -Because "$($case.Name) is invisible to the real transport finder, so hygiene must not treat it as a present marker"
                $result.Reason | Should -Match '(?i)missing'
                $script:PostLog.Count | Should -Be 0
            }
        }

        It 'M15: still refuses a decoy cross-family marker whose leading whitespace is a zero-width space (U+200B), never a silent hygiene bypass' {
            $marker = $script:PostNewFamily.MarkerTemplate -replace '\{ID\}', "$script:IssueNumber"
            $otherMarker = $script:UpsertFamily.MarkerTemplate -replace '\{ID\}', '42'
            $zwsp = [char]0x200B
            # `\s` does not match `\p{Cf}` (Unicode "format" category, e.g.
            # zero-width space) -- the old `^\s*` anchor would have let this
            # decoy slip past the cross-family scan even though downstream
            # readers still find it, recreating the exact self-DoS class this
            # hygiene rule exists to close. NOTE (#1031): this comment used to
            # name find-or-upsert-comment.ps1's `-like` matcher as that
            # downstream reader. It no longer is one — that selector is now
            # line-1-exact and the decoy here sits on line 4, so it would not
            # be selected. The hygiene rule this test pins is unchanged and
            # still right; the still-substring readers it protects are the
            # `.Contains`-over-body scans elsewhere in the catalog.
            $body = "$marker`n`nSome content.`n$zwsp$otherMarker`n`nA decoy live marker prefixed by an invisible zero-width space."

            $result = Invoke-PersistMarkerWrite -Family $script:PostNewFamily.Family -Owner $script:Owner -Repo $script:Repo -Number $script:IssueNumber -TargetSurface 'issue' -Marker $marker -Body $body

            $result.Success | Should -Be $false
            $result.Reason | Should -Match '(?i)another registered family'
            $escapedOtherFamily = [regex]::Escape($script:UpsertFamily.Family)
            $result.Reason | Should -Match $escapedOtherFamily
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

        It 'M22: echoes the library validator''s own warning at the WIDER 400-char library-message cap, not the narrow 80-char field-value cap' {
            $marker = $script:EngagementRecordFamily.MarkerTemplate -replace '\{phase\}', 'plan' -replace '\{ID\}', "$script:IssueNumber"
            # An intentionally huge decision_id -- well over 80 chars but
            # under 400 -- so the resulting library warning text (which
            # echoes decision_id verbatim inside a fixed template) exceeds
            # the narrow $script:MarkerRefusalEchoCap (80) but should still
            # come through UNTRUNCATED under the wider library-message cap
            # (400).
            $longSlug = 'x' * 200
            $yamlFence = @'
```yaml
schema_version: 2
phase: plan
capture_session: "test-session"
load_bearing_decisions:
  - decision_id: {SLUG}
    classification: load-bearing
    articulation_status: complete
```
'@ -replace '\{SLUG\}', $longSlug
            $body = "$marker`n`n$yamlFence"

            $result = Invoke-PersistMarkerWrite -Family $script:EngagementRecordFamily.Family -Owner $script:Owner -Repo $script:Repo -Number $script:IssueNumber -TargetSurface 'issue' -Marker $marker -Body $body

            $result.Success | Should -Be $false
            # The full 200-char slug must appear VERBATIM and INTACT -- the
            # narrow 80-char field-value cap would have truncated the
            # message before even finishing the fixed "...decision_id
            # slug: '" prefix (already ~88 chars), showing NONE of the
            # slug's characters. Under the wider 400-char library-message
            # cap, the whole slug survives; only the trailing (less
            # load-bearing) regex-description text gets cut off, still
            # producing a truncation marker since the FULL message (prefix +
            # 200-char slug + regex description) exceeds 400 chars overall.
            $result.Reason | Should -Match $longSlug
            $result.Reason | Should -Match '\.\.\.\(\+\d+ more chars, truncated\)'
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

        It 'M24: ignores a MID-LINE decoy ```yaml occurrence (not anchored at line start) and correctly parses the REAL, later, line-anchored fenced block' {
            $marker = $script:CreditInputFamily.MarkerTemplate -replace '\{port\}', 'plan' -replace '\{ID\}', "$script:IssueNumber"
            # The decoy sits mid-sentence (not at column 0) -- the OLD
            # unanchored regex would have matched THIS occurrence first
            # (first-match-wins, scanning the whole body regardless of line
            # position), extracting garbage ("decoy: not-real-yaml") instead
            # of the real, later, properly fenced block.
            $decoyProse = 'Note: a payload example looks like ```yaml decoy: not-real-yaml``` embedded in a sentence.'
            $body = "$marker`n`n$decoyProse`n`n$script:CreditInputValidYaml"

            $result = Invoke-PersistMarkerWrite -Family $script:CreditInputFamily.Family -Owner $script:Owner -Repo $script:Repo -Number $script:IssueNumber -TargetSurface 'issue' -Marker $marker -Body $body

            $result.Success | Should -Be $true
            $result.Action | Should -Be 'posted'
        }

        It 'M24: refuses (never silently picks one) when the candidate carries TWO genuine, line-anchored fenced ```yaml blocks' {
            $marker = $script:CreditInputFamily.MarkerTemplate -replace '\{port\}', 'plan' -replace '\{ID\}', "$script:IssueNumber"
            $body = "$marker`n`n$script:CreditInputValidYaml`n`n$script:CreditInputInvalidPortYaml"

            $result = Invoke-PersistMarkerWrite -Family $script:CreditInputFamily.Family -Owner $script:Owner -Repo $script:Repo -Number $script:IssueNumber -TargetSurface 'issue' -Marker $marker -Body $body

            $result.Success | Should -Be $false
            $result.Reason | Should -Match '(?i)more than one'
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

        It 'M19: ABORTS the whole write (never silently drops the pointer) when the sibling GET fails with a TRANSIENT error, not a confirmed 404' {
            $script:simulateGetFailure = @(9998)
            $existingBody = "$script:PlanMarker`n<!-- phase-containment-ledger-ref: 9998 -->`n`nOld plan prose."
            Add-MockComment -Id 100 -Body $existingBody
            $candidateBody = "$script:PlanMarker`n`nFresh plan prose, no pointer."

            $result = Invoke-PersistMarkerWrite -Family $script:UpsertFamily.Family -Owner $script:Owner -Repo $script:Repo -Number $script:IssueNumber -TargetSurface 'issue' -Marker $script:PlanMarker -Body $candidateBody

            # A transient failure must ABORT (refuse) the write, not silently
            # drop the pointer and proceed as if it were confirmed stale.
            $result.Success | Should -Be $false
            $result.Reason | Should -Match '(?i)transport failure'
            $script:PatchLog.Count | Should -Be 0
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

        It 'P3 (issue #893 s11 post-fix): STILL carries forward the **Plan Stress-Test** section when the existing comment carries a ledger pointer (modern, non-legacy plan) -- plan-authoring/SKILL.md rule 8 keeps the heading on the plan comment post-split regardless of pointer generation' {
            # Regression coverage: M10 originally gated this preserve
            # entirely inside the legacy (no-ledger-pointer) branch,
            # contradicting plan-authoring/SKILL.md:277 ("Post-split, the
            # heading and its prose bullets stay on the plan comment" for
            # modern plans too) and the live reader at
            # phase-containment-emission-check-core.ps1's plan-stress-test
            # honest fallback, which depends on the heading being present.
            # Dropping it on a modern re-persist collapsed the
            # emission-check gate to a false-clean.
            $ledgerMarker = "<!-- phase-containment-ledger-$script:IssueNumber -->"
            Add-MockComment -Id 500 -Body "$ledgerMarker`n`nSibling content."
            $existingBody = @"
$script:PlanMarker
<!-- phase-containment-ledger-ref: 500 -->

Old plan prose.

**Plan Stress-Test**

- Challenge: something - Prosecution: pass - Post-judge ruling: sustained - Maintainer disposition: incorporate
"@
            Add-MockComment -Id 100 -Body $existingBody
            $candidateBody = "$script:PlanMarker`n<!-- phase-containment-ledger-ref: 500 -->`n`nFresh plan prose, revised."

            $result = Invoke-PersistMarkerWrite -Family $script:UpsertFamily.Family -Owner $script:Owner -Repo $script:Repo -Number $script:IssueNumber -TargetSurface 'issue' -Marker $script:PlanMarker -Body $candidateBody

            $result.Success | Should -Be $true
            $script:PatchLog[0].Body | Should -Match '\*\*Plan Stress-Test\*\*'
            $result.Confirmation | Should -Match '\*\*Plan Stress-Test\*\* heading/section'
        }

        It 'M10: bounds the stress-test capture at a following `## ` heading, never duplicating it, even on a legacy (no-pointer) plan' {
            $existingBody = @"
$script:PlanMarker

Old plan prose.

**Plan Stress-Test**

- Challenge: something - Prosecution: pass - Post-judge ruling: sustained - Maintainer disposition: incorporate

## Named Decisions

<!-- named-decisions:begin -->
### D1 - Something load-bearing
<!-- named-decisions:end -->
"@
            Add-MockComment -Id 100 -Body $existingBody
            # Candidate already carries a FRESH `## Named Decisions` section of
            # its own -- an unbounded stress-test capture (running to
            # end-of-body because no further `**Bold**` heading follows) would
            # append the OLD named-decisions text after this fresh one,
            # duplicating the heading (the exact live #893 production repro
            # from the prosecution ledger).
            $candidateBody = @"
$script:PlanMarker

Fresh plan prose, revised, stress-test summary omitted by mistake.

## Named Decisions

<!-- named-decisions:begin -->
### D1 - Something load-bearing (revised)
<!-- named-decisions:end -->
"@

            $result = Invoke-PersistMarkerWrite -Family $script:UpsertFamily.Family -Owner $script:Owner -Repo $script:Repo -Number $script:IssueNumber -TargetSurface 'issue' -Marker $script:PlanMarker -Body $candidateBody

            $result.Success | Should -Be $true
            $script:PatchLog[0].Body | Should -Match '\*\*Plan Stress-Test\*\*'
            # The preserved slice must not swallow the existing trailing
            # ## Named Decisions section -- the heading must appear exactly
            # once (the candidate's own fresh copy), never duplicated.
            ([regex]::Matches($script:PatchLog[0].Body, '## Named Decisions')).Count | Should -Be 1
        }

        It 'M14: REFUSES a candidate-SUPPLIED phase-containment-ledger-ref pointer that fails its own live sibling-identity check (forged/stale)' {
            # Note: no sibling comment 777 is registered at all -- the
            # candidate's own pointer targets a comment that doesn't carry
            # the expected identity marker.
            $existingBody = "$script:PlanMarker`n`nOld plan prose (no pointer)."
            Add-MockComment -Id 100 -Body $existingBody
            $candidateBody = "$script:PlanMarker`n<!-- phase-containment-ledger-ref: 777 -->`n`nFresh plan prose with a forged pointer."

            $result = Invoke-PersistMarkerWrite -Family $script:UpsertFamily.Family -Owner $script:Owner -Repo $script:Repo -Number $script:IssueNumber -TargetSurface 'issue' -Marker $script:PlanMarker -Body $candidateBody

            $result.Success | Should -Be $false
            $result.Reason | Should -Match '(?i)candidate-supplied'
            $result.Reason | Should -Match '777'
            $script:PatchLog.Count | Should -Be 0
        }

        It 'M14: accepts a candidate-SUPPLIED phase-containment-ledger-ref pointer whose target genuinely carries the expected identity marker' {
            $ledgerMarker = "<!-- phase-containment-ledger-$script:IssueNumber -->"
            Add-MockComment -Id 500 -Body "$ledgerMarker`n`nReal sibling content."
            $existingBody = "$script:PlanMarker`n`nOld plan prose (no pointer)."
            Add-MockComment -Id 100 -Body $existingBody
            $candidateBody = "$script:PlanMarker`n<!-- phase-containment-ledger-ref: 500 -->`n`nFresh plan prose with a genuine pointer."

            $result = Invoke-PersistMarkerWrite -Family $script:UpsertFamily.Family -Owner $script:Owner -Repo $script:Repo -Number $script:IssueNumber -TargetSurface 'issue' -Marker $script:PlanMarker -Body $candidateBody

            $result.Success | Should -Be $true
            $script:PatchLog[0].Body | Should -Match ([regex]::Escape('phase-containment-ledger-ref: 500'))
        }

        It 'M14: REFUSES a candidate-SUPPLIED slice_comment_id that fails its own live sibling-identity check (forged/stale)' {
            $existingBody = @"
$script:PlanMarker

Old plan prose.
"@
            Add-MockComment -Id 100 -Body $existingBody
            # No sibling comment 888 exists at all.
            $candidateBody = @"
$script:PlanMarker

<!-- frame-spine
spine_schema_version: 2
generated_at: 2026-07-02T00:00:00Z
coverage: complete
slice_comment_id: 888
ports:
  implement-code: [s1]
slices:
  s1:
    ac_refs: [AC1]
    depends_on: []
    cycle: 1
-->

Fresh plan prose with a forged slice_comment_id.
"@

            $result = Invoke-PersistMarkerWrite -Family $script:UpsertFamily.Family -Owner $script:Owner -Repo $script:Repo -Number $script:IssueNumber -TargetSurface 'issue' -Marker $script:PlanMarker -Body $candidateBody

            $result.Success | Should -Be $false
            $result.Reason | Should -Match '(?i)candidate-supplied'
            $result.Reason | Should -Match '888'
            $script:PatchLog.Count | Should -Be 0
        }

        It 'P7 (issue #893 s11 post-fix): REFUSES a candidate-SUPPLIED phase-containment-ledger-ref pointer that fails its own live sibling-identity check on the VERY FIRST plan-issue write, when no existing comment is present yet' {
            # Regression coverage: M14's candidate-supplied-pointer
            # validation sat AFTER the `$existing.Count -eq 0` early-return
            # for a first-ever plan-issue write, so a forged/stale
            # candidate-supplied pointer wrote through completely
            # unvalidated on first write -- only a re-persist (where an
            # existing comment already exists) was actually protected.
            # Deliberately no Add-MockComment call here: the issue carries
            # NO plan-issue-{ID} comment at all yet.
            $candidateBody = "$script:PlanMarker`n<!-- phase-containment-ledger-ref: 777 -->`n`nFresh plan prose with a forged pointer, first-ever write."

            $result = Invoke-PersistMarkerWrite -Family $script:UpsertFamily.Family -Owner $script:Owner -Repo $script:Repo -Number $script:IssueNumber -TargetSurface 'issue' -Marker $script:PlanMarker -Body $candidateBody

            $result.Success | Should -Be $false
            $result.Reason | Should -Match '(?i)candidate-supplied'
            $result.Reason | Should -Match '777'
            $script:PostLog.Count | Should -Be 0
            $script:PatchLog.Count | Should -Be 0
        }

        It 'P7 (issue #893 s11 post-fix): REFUSES a candidate-SUPPLIED slice_comment_id that fails its own live sibling-identity check on the VERY FIRST plan-issue write, when no existing comment is present yet' {
            # Deliberately no Add-MockComment call here: the issue carries
            # NO plan-issue-{ID} comment at all yet, and no sibling comment
            # 888 exists either.
            $candidateBody = @"
$script:PlanMarker

<!-- frame-spine
spine_schema_version: 2
generated_at: 2026-07-02T00:00:00Z
coverage: complete
slice_comment_id: 888
ports:
  implement-code: [s1]
slices:
  s1:
    ac_refs: [AC1]
    depends_on: []
    cycle: 1
-->

Fresh plan prose with a forged slice_comment_id, first-ever write.
"@

            $result = Invoke-PersistMarkerWrite -Family $script:UpsertFamily.Family -Owner $script:Owner -Repo $script:Repo -Number $script:IssueNumber -TargetSurface 'issue' -Marker $script:PlanMarker -Body $candidateBody

            $result.Success | Should -Be $false
            $result.Reason | Should -Match '(?i)candidate-supplied'
            $result.Reason | Should -Match '888'
            $script:PostLog.Count | Should -Be 0
            $script:PatchLog.Count | Should -Be 0
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

        It 'P5 (issue #893 s11 post-fix): splices the REAL frame-spine block, never a mid-line PROSE MENTION of it, when a decoy mention precedes the real block' {
            # Regression coverage: the splice regex was missing the
            # canonical parser's `(?m)^[ \t]*` line-start anchor, so a prose
            # sentence mentioning the block syntax (a legitimate, common
            # authoring pattern -- e.g. explaining what follows) matched as
            # a decoy self-closing form with an EMPTY payload capture,
            # ahead of the real block further down. Defense proved this
            # live: the unanchored mirror regex matched at the decoy's
            # index instead of the real block on an identical body where
            # the canonical parser (and the pre-fix regex) correctly found
            # the real block.
            $planBody = @"
$script:PlanMarkerForSplice

See the ``<!-- frame-spine -->`` block below for the port routing index.

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

Plan prose that must survive.
"@
            Add-MockComment -Id 100 -Body $planBody
            $sliceBody = "$script:SliceMarker`n<!-- frame-slices-generated-at: 2026-07-16T18:00:00Z -->`n`n<!-- frame-slice`nid: s1`n-->"

            $result = Invoke-PersistMarkerWrite -Family $script:FrameSlicesFamily.Family -Owner $script:Owner -Repo $script:Repo -Number $script:IssueNumber -TargetSurface 'issue' -Marker $script:SliceMarker -Body $sliceBody

            $result.Success | Should -Be $true
            $newSiblingId = $result.CommentId
            $planPatch = @($script:PatchLog | Where-Object { $_.CommentId -eq 100 })
            $planPatch.Count | Should -Be 1
            # The real block's slice_comment_id must be set -- a decoy
            # match would leave this absent (the splice would have no-oped
            # against the decoy's empty payload instead).
            $planPatch[0].Body | Should -Match "(?m)^slice_comment_id:\s*$newSiblingId\s*$"
            # The decoy prose mention itself must survive verbatim, never
            # corrupted by a wrongly-targeted splice.
            $planPatch[0].Body | Should -Match 'See the `<!-- frame-spine -->` block below'
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

    Context 'Set-MarkerSpineScalarValue: post-condition safety net on the early-return path (P6, issue #893 s11 post-fix)' {
        It 'throws loud instead of silently no-oping when the canonical parser sees a frame-spine block that this helper''s own splice regex did not match' {
            # Regression coverage: the M6 post-condition safety net (re-read
            # -Name back through the canonical parser -- Get-FSCSpineBlock
            # -- after a successful splice, throw if it disagrees) only ran
            # on the SUCCESSFUL-match path. The early `if (-not
            # $blockMatch.Success) { return $Body }` fired first and
            # returned a false "nothing to splice" success for any body
            # shape this helper's own regex could not match, even one the
            # canonical parser DOES recognize as carrying a frame-spine
            # block -- the exact "third, currently-unknown block shape"
            # class the post-condition's own docstring already names as
            # its reason for existing, just unreachable from this
            # direction. After the P5 fix the two parsers are kept
            # byte-identical in production, so a real divergent body is not
            # constructible without forcing one -- this test mocks
            # Get-FSCSpineBlock to force the exact divergence and proves
            # the early-return path now throws loud instead of silently
            # no-oping.
            Mock -CommandName Get-FSCSpineBlock -MockWith { return 'slice_comment_id: 999' }

            { Set-MarkerSpineScalarValue -Body 'plain body with no frame-spine literal at all' -Name 'slice_comment_id' -Value '123' } | Should -Throw '*post-condition failed*'
        }

        It 'returns the body unchanged, with no throw, when BOTH the canonical parser and this helper''s own splice regex agree no frame-spine block is present' {
            $body = 'plain body with no frame-spine literal at all'

            $result = Set-MarkerSpineScalarValue -Body $body -Name 'slice_comment_id' -Value '123'

            $result | Should -Be $body
        }
    }
}
