#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
The design's named gate-flow integration test (issue #837, plan step 3 / slice
s3). One ruling batch containing an approve, a modify (whose new title
collides with an existing open issue on re-dedup), and a drop -- exercised
with mocked `gh` -- asserts, in order:

  1. record-before-file ordering: the durable `followup-` record write
     happens before any Add-FollowUpIssue/filing call (verified via mock
     call-order).
  2. the approved item's filing call carries -FilingProvenance
     'gate-approved'.
  3. the modified item, after its title collides with the mocked existing
     issue, records a modify entry pointing at the existing issue rather
     than filing a duplicate.
  4. the dropped item produces a `followup-` drop record (via
     Get-FollowupRecordKey + the engagement-record shape) and no filing
     call.
  5. a counts line "proposed: 3, approved: 1, modified: 1, dropped: 1" is
     derivable from the batch outcome.

Safe-operations SKILL.md §2e (plan step 4) is prose/methodology, not a
callable production function yet -- there is no production "gate
orchestrator" to invoke. Per the Senior-Engineer halt-return guidance for
this slice, the gate decision-making itself is stubbed at the test boundary
(Invoke-StubbedGateRuling below, defined ONLY in this test file); the test
exercises the REAL production helpers around that boundary:
Get-FollowupRecordKey and Get-FollowupKeysFromRawText (s1,
followup-gate-core.ps1), Find-OrUpsertComment (the durable-record write
mechanism, existing lib), and Add-FollowUpIssue (s2, mandatory
-FilingProvenance). This test pins the intended record-before-file
contract against a reference stub (Invoke-StubbedGateRuling); a future
production §2e implementation must preserve this ordering, which this
test does not and cannot enforce against non-existent production code
(plan step 3 Requirement Contract).
#>

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
    $script:EngagementLib = Join-Path $script:RepoRoot '.github/scripts/lib/frame-engagement-record-core.ps1'
    $script:UpsertLib = Join-Path $script:RepoRoot '.github/scripts/lib/find-or-upsert-comment.ps1'
    $script:CoreLib = Join-Path $script:RepoRoot '.github/scripts/lib/followup-gate-core.ps1'
    $script:AddFollowUpScript = Join-Path $script:RepoRoot 'skills/safe-operations/scripts/Add-FollowUpIssue.ps1'

    . $script:EngagementLib
    . $script:UpsertLib
    . $script:CoreLib
    . $script:AddFollowUpScript

    # Shared ordered call log: both the mocked Find-OrUpsertComment (record
    # write) and the mocked global `gh` (Add-FollowUpIssue's filing call)
    # append to this so call ORDER can be asserted, not just call presence.
    $script:CallLog = [System.Collections.Generic.List[string]]::new()
    $script:CapturedCreateBodies = [System.Collections.Generic.List[string]]::new()

    # Mocked `gh` backing Add-FollowUpIssue's internal calls (issue create /
    # view / graphql / edit) -- same mocking convention as
    # Add-FollowUpIssue.Tests.ps1.
    function global:gh {
        param([Parameter(ValueFromRemainingArguments = $true)]$RemainingArgs)
        $joined = $RemainingArgs -join ' '

        if ($joined -match 'issue\s+create') {
            $idx = [array]::IndexOf($RemainingArgs, '--body')
            $capturedBody = if ($idx -ge 0 -and $idx + 1 -lt $RemainingArgs.Count) { $RemainingArgs[$idx + 1] } else { $null }
            $script:CapturedCreateBodies.Add($capturedBody)
            $script:CallLog.Add('file')
            $global:LASTEXITCODE = 0
            return 'https://github.com/Grimblaz/agent-orchestra/issues/9001'
        }
        if ($joined -match 'issue\s+edit') {
            $global:LASTEXITCODE = 0
            return ''
        }
        if ($joined -match 'issue\s+view\s+\d+\s+--json\s+id\s+--jq\s+\.id') {
            $global:LASTEXITCODE = 0
            return 'I_node_id'
        }
        if ($joined -match 'api\s+graphql') {
            $global:LASTEXITCODE = 0
            return '{"data":{"addSubIssue":{"issue":{"title":"Child"}}}}'
        }
        $global:LASTEXITCODE = 0
        return ''
    }

    # ------------------------------------------------------------------
    # Test-boundary stub for the gate ruling flow. NOT production code --
    # safe-operations SKILL.md §2e (plan step 4) is prose methodology, and
    # this function only exists to drive the real production helpers
    # (Get-FollowupRecordKey / Find-OrUpsertComment / Add-FollowUpIssue)
    # through the record-before-file contract the design specifies.
    # ------------------------------------------------------------------
    function script:Invoke-StubbedGateRuling {
        param(
            [Parameter(Mandatory = $true)]
            [object[]]$Proposals,

            [Parameter(Mandatory = $true)]
            [hashtable]$Rulings,

            [Parameter(Mandatory = $true)]
            [hashtable]$ExistingOpenIssuesByTitle,

            [Parameter(Mandatory = $true)]
            [int]$Id
        )

        $decisions = @()
        $counts = @{ proposed = $Proposals.Count; approved = 0; modified = 0; dropped = 0 }
        $toFile = @()

        foreach ($p in $Proposals) {
            $ruling = $Rulings[$p.canonical_title]
            switch ($ruling.disposition) {
                'drop' {
                    $counts.dropped++
                    $decisions += [PSCustomObject]@{
                        decision_id     = (Get-FollowupRecordKey -RawKey $p.canonical_title)
                        classification  = 'routine'
                        engineer_choice = 'drop'
                    }
                }
                'modify' {
                    $newTitle = $ruling.new_title
                    $existing = $ExistingOpenIssuesByTitle[$newTitle]
                    if ($existing) {
                        # DD3 modify-re-dedup: title collision -> record a
                        # modify-redirect entry, do NOT file a duplicate.
                        $counts.modified++
                        $decisions += [PSCustomObject]@{
                            decision_id     = (Get-FollowupRecordKey -RawKey $p.canonical_title)
                            classification  = 'routine'
                            engineer_choice = "modify-redirect:$existing"
                        }
                    } else {
                        $counts.modified++
                        $toFile += [PSCustomObject]@{ Proposal = $p; Title = $newTitle; Provenance = 'gate-modified' }
                    }
                }
                'approve' {
                    $counts.approved++
                    $toFile += [PSCustomObject]@{ Proposal = $p; Title = $p.canonical_title; Provenance = 'gate-approved' }
                }
            }
        }

        # Record-before-file: the durable batch record is written BEFORE any
        # filing call fires, regardless of how many items end up filed.
        $recordLines = @(
            "<!-- engagement-record-plan-$Id -->",
            '```yaml',
            'schema_version: 2',
            'phase: plan',
            'capture_session: "gate-ruling"',
            'load_bearing_decisions:'
        )
        foreach ($d in $decisions) {
            $recordLines += "  - decision_id: $($d.decision_id)"
            $recordLines += "    classification: $($d.classification)"
            $recordLines += "    engineer_choice: `"$($d.engineer_choice)`""
        }
        $recordLines += '```'
        $recordBody = $recordLines -join "`n"

        Find-OrUpsertComment -Type issue -Number $Id -Marker "<!-- engagement-record-plan-$Id -->" -Body $recordBody | Out-Null

        $filedUrls = @()
        foreach ($f in $toFile) {
            $filedUrls += Add-FollowUpIssue -ParentIssue $Id -Title $f.Title -Body $f.Proposal.rationale -Labels @('priority: medium') -FilingProvenance $f.Provenance
        }

        return [PSCustomObject]@{
            Decisions  = $decisions
            FiledUrls  = $filedUrls
            Counts     = $counts
            RecordBody = $recordBody
        }
    }
}

AfterAll {
    if (Get-Command gh -ErrorAction SilentlyContinue) {
        Remove-Item Function:\gh -ErrorAction SilentlyContinue
    }
}

Describe 'followup-gate-flow: approve + modify(re-dedup collision) + drop batch' {
    BeforeEach {
        $script:CallLog.Clear()
        $script:CapturedCreateBodies.Clear()
        $global:LASTEXITCODE = 0

        # Default stub for the durable-record write. Tests that need to assert
        # call order or content override this with their own `Mock` inside the
        # `It` block (a same-scope Mock replaces this default for that test).
        Mock Find-OrUpsertComment { return 'https://example.invalid/comment/1' }
    }

    BeforeAll {
        $script:Proposals = @(
            [PSCustomObject]@{
                canonical_title      = '[Structural] S-x: approve me'
                rationale            = 'approve rationale'
                disposition          = 'recommended-approve'
                severity             = 'medium'
                board_position       = 1
                followup_key         = (Get-FollowupRecordKey -RawKey '[Structural] S-x: approve me')
                originating_head_sha = 'abc1234'
                ruling_link          = 'https://github.com/Grimblaz/agent-orchestra/issues/837#issuecomment-1'
            },
            [PSCustomObject]@{
                canonical_title      = '[Structural] S-x: modify me'
                rationale            = 'modify rationale'
                disposition          = 'recommended-approve'
                severity             = 'medium'
                board_position       = 2
                followup_key         = (Get-FollowupRecordKey -RawKey '[Structural] S-x: modify me')
                originating_head_sha = 'abc1234'
                ruling_link          = 'https://github.com/Grimblaz/agent-orchestra/issues/837#issuecomment-1'
            },
            [PSCustomObject]@{
                canonical_title      = '[Structural] S-x: drop me'
                rationale            = 'drop rationale'
                disposition          = 'recommended-approve'
                severity             = 'low'
                board_position       = 3
                followup_key         = (Get-FollowupRecordKey -RawKey '[Structural] S-x: drop me')
                originating_head_sha = 'abc1234'
                ruling_link          = 'https://github.com/Grimblaz/agent-orchestra/issues/837#issuecomment-1'
            }
        )

        $script:Rulings = @{
            '[Structural] S-x: approve me' = @{ disposition = 'approve' }
            '[Structural] S-x: modify me'  = @{ disposition = 'modify'; new_title = '[Structural] S-x: already tracked elsewhere' }
            '[Structural] S-x: drop me'    = @{ disposition = 'drop' }
        }

        # The modified title collides with this mocked existing open issue.
        $script:ExistingOpenIssuesByTitle = @{
            '[Structural] S-x: already tracked elsewhere' = 555
        }
    }

    It 'writes the durable record before any filing call (record-before-file ordering)' {
        Mock Find-OrUpsertComment {
            $script:CallLog.Add('record')
            return 'https://example.invalid/comment/1'
        }

        $null = Invoke-StubbedGateRuling -Proposals $script:Proposals -Rulings $script:Rulings -ExistingOpenIssuesByTitle $script:ExistingOpenIssuesByTitle -Id 837

        Should -Invoke Find-OrUpsertComment -Times 1

        $order = @($script:CallLog)
        $order | Should -Contain 'record'
        $order | Should -Contain 'file'

        $recordIndex = [Array]::IndexOf($order, 'record')
        $fileIndex = [Array]::IndexOf($order, 'file')
        $recordIndex | Should -BeLessThan $fileIndex
    }

    It "stamps the approved item's filing call with -FilingProvenance 'gate-approved'" {
        $result = Invoke-StubbedGateRuling -Proposals $script:Proposals -Rulings $script:Rulings -ExistingOpenIssuesByTitle $script:ExistingOpenIssuesByTitle -Id 837

        # Exactly one item is actually filed in this batch: the approved one.
        $result.FiledUrls.Count | Should -Be 1
        $script:CapturedCreateBodies.Count | Should -Be 1
        $script:CapturedCreateBodies[0] | Should -Match '<!-- filing-provenance: gate-approved -->'
    }

    It 'records a modify-redirect entry pointing at the existing issue instead of filing a duplicate' {
        $result = Invoke-StubbedGateRuling -Proposals $script:Proposals -Rulings $script:Rulings -ExistingOpenIssuesByTitle $script:ExistingOpenIssuesByTitle -Id 837

        $modifyKey = Get-FollowupRecordKey -RawKey '[Structural] S-x: modify me'
        $modifyDecision = $result.Decisions | Where-Object { $_.decision_id -eq $modifyKey }

        $modifyDecision | Should -Not -BeNullOrEmpty
        $modifyDecision.engineer_choice | Should -Be 'modify-redirect:555'

        # No filing call ever names the collided (duplicate) title.
        $script:CapturedCreateBodies | Where-Object { $_ -match 'already tracked elsewhere' } | Should -BeNullOrEmpty
    }

    It 'produces a followup- drop record and no filing call for the dropped item' {
        $result = Invoke-StubbedGateRuling -Proposals $script:Proposals -Rulings $script:Rulings -ExistingOpenIssuesByTitle $script:ExistingOpenIssuesByTitle -Id 837

        $dropKey = Get-FollowupRecordKey -RawKey '[Structural] S-x: drop me'
        $dropDecision = $result.Decisions | Where-Object { $_.decision_id -eq $dropKey }

        $dropDecision | Should -Not -BeNullOrEmpty
        $dropDecision.engineer_choice | Should -Be 'drop'
        $dropKey | Should -Match '^followup-[0-9a-f]{16}$'

        # The durable record body itself carries the drop key (defense-in-depth
        # truth source shared with Merge-FollowupRecords' unbroken-chain guard).
        $rawKeysSeen = Get-FollowupKeysFromRawText -Text $result.RecordBody
        $rawKeysSeen | Should -Contain $dropKey

        # No filing call ever names the dropped item's title.
        $script:CapturedCreateBodies | Where-Object { $_ -match 'drop me' } | Should -BeNullOrEmpty
    }

    It 'derives a counts line of proposed: 3, approved: 1, modified: 1, dropped: 1 from the batch outcome' {
        $result = Invoke-StubbedGateRuling -Proposals $script:Proposals -Rulings $script:Rulings -ExistingOpenIssuesByTitle $script:ExistingOpenIssuesByTitle -Id 837

        $result.Counts.proposed | Should -Be 3
        $result.Counts.approved | Should -Be 1
        $result.Counts.modified | Should -Be 1
        $result.Counts.dropped | Should -Be 1

        $countsLine = "proposed: $($result.Counts.proposed), approved: $($result.Counts.approved), modified: $($result.Counts.modified), dropped: $($result.Counts.dropped)"
        $countsLine | Should -Be 'proposed: 3, approved: 1, modified: 1, dropped: 1'
    }
}
