#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

# Unit tests for followup-gate-core.ps1 (issue #837, plan step 1 / slice s1).
#
# Get-FollowupRecordKey:
#   (a) lowercase-only validated against the real (case-sensitive) Test-EngagementRecordSlug
#   (b) throws ArgumentException on null / empty / whitespace-after-trim
#   (c) deterministic
#   (d) fixed 25-char length
#   (e) distinct inputs -> distinct outputs
#
# Proposed-followups queue comment:
#   (f) round-trip recovers a real canonical-title-shaped fixture exactly
#   (g) target_repo omitted when absent
#   (h) proposed -> claimed -> consumed transitions; backward transition throws
#   (i) Write-ProposedFollowupsComment delegates to Find-OrUpsertComment (wiring)
#
# Merge-FollowupRecords:
#   (j) idempotency
#   (k) unbroken-chain guard fires a warning when a prior key would be dropped
#   (l) precedence rule (current-batch wins over prior)
#   (m) nested ac_cross_check payload survives merge -> re-emit unchanged

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
    $script:CoreLib = Join-Path $script:RepoRoot '.github/scripts/lib/followup-gate-core.ps1'
    $script:EngagementLib = Join-Path $script:RepoRoot '.github/scripts/lib/frame-engagement-record-core.ps1'

    . $script:EngagementLib
    . $script:CoreLib

    $script:HasYaml = [bool](Get-Module -ListAvailable powershell-yaml)
}

# ---------------------------------------------------------------------------
# Get-FollowupRecordKey
# ---------------------------------------------------------------------------

Describe 'Get-FollowupRecordKey' {
    It 'produces a key that passes the real case-sensitive Test-EngagementRecordSlug validator' {
        $key = Get-FollowupRecordKey -RawKey 'some raw finding identity'
        Test-EngagementRecordSlug -DecisionId $key | Should -BeTrue
    }

    It 'produces a strictly lowercase key (uppercase would fail the case-sensitive slug check)' {
        $key = Get-FollowupRecordKey -RawKey 'ABC-Some-Mixed-Case-Input'
        $key | Should -Be $key.ToLowerInvariant()
        $key | Should -Match '^[a-z0-9-]+$'
    }

    It 'is fixed at 25 characters (followup- = 9 + 16 hex chars)' {
        $key = Get-FollowupRecordKey -RawKey 'length-check'
        $key.Length | Should -Be 25
        $key.Substring(0, 9) | Should -Be 'followup-'
    }

    It 'throws ArgumentException on a null RawKey' {
        { Get-FollowupRecordKey -RawKey $null } | Should -Throw -ExceptionType ([System.ArgumentException])
    }

    It 'throws ArgumentException on an empty-string RawKey' {
        { Get-FollowupRecordKey -RawKey '' } | Should -Throw -ExceptionType ([System.ArgumentException])
    }

    It 'throws ArgumentException on a whitespace-only RawKey' {
        { Get-FollowupRecordKey -RawKey "   `t  " } | Should -Throw -ExceptionType ([System.ArgumentException])
    }

    It 'is deterministic for the same input' {
        $a = Get-FollowupRecordKey -RawKey 'stable-finding-key-42'
        $b = Get-FollowupRecordKey -RawKey 'stable-finding-key-42'
        $a | Should -Be $b
    }

    It 'produces distinct keys for distinct inputs' {
        $a = Get-FollowupRecordKey -RawKey 'input-alpha'
        $b = Get-FollowupRecordKey -RawKey 'input-beta'
        $a | Should -Not -Be $b
    }
}

# ---------------------------------------------------------------------------
# Proposed-followups queue comment round-trip
# ---------------------------------------------------------------------------

Describe 'New-ProposedFollowupsComment / Read-ProposedFollowupsComment: round-trip' {
    BeforeAll {
        if (-not $script:HasYaml) { return }

        $script:CanonicalTitleFixture = '[Structural] S-cross-cutting: title with a colon: and brackets [here]'
        $script:Proposal = [PSCustomObject]@{
            canonical_title       = $script:CanonicalTitleFixture
            rationale             = 'Because reasons: with an embedded colon, a "quoted" word, and a backslash \ character.'
            disposition           = 'recommended-approve'
            severity              = 'medium'
            board_position        = 3
            followup_key          = (Get-FollowupRecordKey -RawKey $script:CanonicalTitleFixture)
            originating_head_sha  = '8e1bba94c57d4f14fba57fbca32171782b01e652'
            ruling_link           = 'https://github.com/Grimblaz/agent-orchestra/pull/837#issuecomment-123'
            target_repo           = 'Grimblaz/other-repo'
        }
        $script:CommentBody = New-ProposedFollowupsComment -Id 837 -Proposals @($script:Proposal) -State proposed
    }

    It 'recovers the canonical-title-shaped fixture exactly' {
        if (-not $script:HasYaml) { Set-ItResult -Skipped -Because 'powershell-yaml module not installed'; return }

        $parsed = Read-ProposedFollowupsComment -CommentBody $script:CommentBody
        $parsed.Id | Should -Be 837
        $parsed.State | Should -Be 'proposed'
        $parsed.Proposals.Count | Should -Be 1

        $p = $parsed.Proposals[0]
        $p.canonical_title | Should -Be $script:Proposal.canonical_title
        $p.rationale | Should -Be $script:Proposal.rationale
        $p.disposition | Should -Be $script:Proposal.disposition
        $p.severity | Should -Be $script:Proposal.severity
        $p.board_position | Should -Be $script:Proposal.board_position
        $p.followup_key | Should -Be $script:Proposal.followup_key
        $p.originating_head_sha | Should -Be $script:Proposal.originating_head_sha
        $p.ruling_link | Should -Be $script:Proposal.ruling_link
        $p.target_repo | Should -Be $script:Proposal.target_repo
    }

    It 'omits target_repo from the payload when not supplied, and reads back as null' {
        if (-not $script:HasYaml) { Set-ItResult -Skipped -Because 'powershell-yaml module not installed'; return }

        $noRepoProposal = [PSCustomObject]@{
            canonical_title       = '[Structural] S-x: no cross-repo target'
            rationale             = 'plain rationale'
            disposition           = 'recommended-approve'
            severity              = 'low'
            board_position        = 1
            followup_key          = 'followup-7777777777777777'
            originating_head_sha  = '8e1bba94c57d4f14fba57fbca32171782b01e652'
            ruling_link           = 'https://github.com/Grimblaz/agent-orchestra/pull/1#issuecomment-1'
        }
        $body = New-ProposedFollowupsComment -Id 1 -Proposals @($noRepoProposal) -State proposed
        $body | Should -Not -Match 'target_repo'

        $parsed = Read-ProposedFollowupsComment -CommentBody $body
        $parsed.Proposals[0].target_repo | Should -BeNullOrEmpty
    }

    It 'round-trips an empty proposals array' {
        if (-not $script:HasYaml) { Set-ItResult -Skipped -Because 'powershell-yaml module not installed'; return }

        $body = New-ProposedFollowupsComment -Id 42 -Proposals @() -State proposed
        $parsed = Read-ProposedFollowupsComment -CommentBody $body
        $parsed.Id | Should -Be 42
        $parsed.Proposals.Count | Should -Be 0
    }

    It 'throws on a comment body with no proposed-followups marker' {
        { Read-ProposedFollowupsComment -CommentBody 'not a marker at all' } | Should -Throw -ExceptionType ([System.ArgumentException])
    }

    It 'round-trips a rationale field containing an embedded code fence without truncating the YAML block (R4)' {
        if (-not $script:HasYaml) { Set-ItResult -Skipped -Because 'powershell-yaml module not installed'; return }

        $fenceProposal = [PSCustomObject]@{
            canonical_title       = '[Structural] S-fence: embedded code fence test'
            rationale             = 'Example: ```js console.log("hi"); ``` embedded inline.'
            disposition           = 'recommended-approve'
            severity              = 'medium'
            board_position        = 2
            followup_key          = 'followup-6666666666666666'
            originating_head_sha  = '8e1bba94c57d4f14fba57fbca32171782b01e652'
            ruling_link           = 'https://github.com/Grimblaz/agent-orchestra/pull/2#issuecomment-2'
        }
        $body = New-ProposedFollowupsComment -Id 2 -Proposals @($fenceProposal) -State proposed

        $parsed = Read-ProposedFollowupsComment -CommentBody $body
        $parsed.Proposals.Count | Should -Be 1
        $parsed.Proposals[0].rationale | Should -Be $fenceProposal.rationale
        $parsed.Proposals[0].followup_key | Should -Be $fenceProposal.followup_key
    }

    It 'round-trips a rationale field containing an embedded newline (R11)' {
        if (-not $script:HasYaml) { Set-ItResult -Skipped -Because 'powershell-yaml module not installed'; return }

        $newlineProposal = [PSCustomObject]@{
            canonical_title       = '[Structural] S-newline: embedded newline test'
            rationale             = "First line of rationale.`nSecond line of rationale."
            disposition           = 'recommended-approve'
            severity              = 'low'
            board_position        = 1
            followup_key          = 'followup-1234567890abcdef'
            originating_head_sha  = '8e1bba94c57d4f14fba57fbca32171782b01e652'
            ruling_link           = 'https://github.com/Grimblaz/agent-orchestra/pull/3#issuecomment-3'
        }
        $body = New-ProposedFollowupsComment -Id 3 -Proposals @($newlineProposal) -State proposed

        $parsed = Read-ProposedFollowupsComment -CommentBody $body
        $parsed.Proposals[0].rationale | Should -Be $newlineProposal.rationale
    }

    It 'round-trips a colon-bearing board_position value without YAML corruption (R5)' {
        if (-not $script:HasYaml) { Set-ItResult -Skipped -Because 'powershell-yaml module not installed'; return }

        $colonProposal = [PSCustomObject]@{
            canonical_title       = '[Structural] S-colon: board_position colon test'
            rationale             = 'plain rationale'
            disposition           = 'recommended-approve'
            severity              = 'low'
            board_position        = 'priority: medium, standalone'
            followup_key          = 'followup-aaaaaaaaaaaaaaaa'
            originating_head_sha  = '8e1bba94c57d4f14fba57fbca32171782b01e652'
            ruling_link           = 'https://github.com/Grimblaz/agent-orchestra/pull/4#issuecomment-4'
        }
        $body = New-ProposedFollowupsComment -Id 4 -Proposals @($colonProposal) -State proposed

        $parsed = Read-ProposedFollowupsComment -CommentBody $body
        $parsed.Proposals.Count | Should -Be 1
        $parsed.Proposals[0].board_position | Should -Be $colonProposal.board_position
        $parsed.Proposals[0].followup_key | Should -Be $colonProposal.followup_key
    }

    It 'round-trips a newline-bearing board_position value without YAML corruption (R5)' {
        if (-not $script:HasYaml) { Set-ItResult -Skipped -Because 'powershell-yaml module not installed'; return }

        $newlineBpProposal = [PSCustomObject]@{
            canonical_title       = '[Structural] S-newline-bp: board_position newline test'
            rationale             = 'plain rationale'
            disposition           = 'recommended-approve'
            severity              = 'low'
            board_position        = "line-one`nline-two"
            followup_key          = 'followup-bbbbbbbbbbbbbbbb'
            originating_head_sha  = '8e1bba94c57d4f14fba57fbca32171782b01e652'
            ruling_link           = 'https://github.com/Grimblaz/agent-orchestra/pull/5#issuecomment-5'
        }
        $body = New-ProposedFollowupsComment -Id 5 -Proposals @($newlineBpProposal) -State proposed

        $parsed = Read-ProposedFollowupsComment -CommentBody $body
        $parsed.Proposals.Count | Should -Be 1
        $parsed.Proposals[0].board_position | Should -Be $newlineBpProposal.board_position
        $parsed.Proposals[0].followup_key | Should -Be $newlineBpProposal.followup_key
    }
}

Describe 'Set-ProposedFollowupsCommentState: proposed -> claimed -> consumed' {
    BeforeAll {
        if (-not $script:HasYaml) { return }
        $script:BaseBody = New-ProposedFollowupsComment -Id 900 -Proposals @() -State proposed
    }

    It 'transitions proposed -> claimed' {
        if (-not $script:HasYaml) { Set-ItResult -Skipped -Because 'powershell-yaml module not installed'; return }

        $claimed = Set-ProposedFollowupsCommentState -CommentBody $script:BaseBody -NewState claimed
        (Read-ProposedFollowupsComment -CommentBody $claimed).State | Should -Be 'claimed'
    }

    It 'transitions claimed -> consumed' {
        if (-not $script:HasYaml) { Set-ItResult -Skipped -Because 'powershell-yaml module not installed'; return }

        $claimed = Set-ProposedFollowupsCommentState -CommentBody $script:BaseBody -NewState claimed
        $consumed = Set-ProposedFollowupsCommentState -CommentBody $claimed -NewState consumed
        (Read-ProposedFollowupsComment -CommentBody $consumed).State | Should -Be 'consumed'
    }

    It 'rejects a backward transition (consumed -> proposed)' {
        if (-not $script:HasYaml) { Set-ItResult -Skipped -Because 'powershell-yaml module not installed'; return }

        $claimed = Set-ProposedFollowupsCommentState -CommentBody $script:BaseBody -NewState claimed
        $consumed = Set-ProposedFollowupsCommentState -CommentBody $claimed -NewState consumed
        { Set-ProposedFollowupsCommentState -CommentBody $consumed -NewState proposed } | Should -Throw -ExceptionType ([System.ArgumentException])
    }

    It 'rejects a same-state no-op transition' {
        { Set-ProposedFollowupsCommentState -CommentBody $script:BaseBody -NewState proposed } | Should -Throw -ExceptionType ([System.ArgumentException])
    }

    It 'rejects a state-skipping transition (proposed -> consumed) that bypasses the claimed step (G2)' {
        if (-not $script:HasYaml) { Set-ItResult -Skipped -Because 'powershell-yaml module not installed'; return }

        { Set-ProposedFollowupsCommentState -CommentBody $script:BaseBody -NewState consumed } | Should -Throw -ExceptionType ([System.ArgumentException])
    }
}

Describe 'Write-ProposedFollowupsComment: delegates to Find-OrUpsertComment (no new gh call path)' {
    It 'calls Find-OrUpsertComment with the proposed-followups marker and forwards Type/Number/Body' {
        Mock Find-OrUpsertComment { return 'https://example.invalid/comment/1' }

        $result = Write-ProposedFollowupsComment -Type issue -Id 837 -Body 'test body'

        $result | Should -Be 'https://example.invalid/comment/1'
        Should -Invoke Find-OrUpsertComment -Times 1 -ParameterFilter {
            $Marker -eq '<!-- proposed-followups-837 -->' -and $Number -eq 837 -and $Type -eq 'issue' -and $Body -eq 'test body'
        }
    }
}

# ---------------------------------------------------------------------------
# Merge-FollowupRecords
# ---------------------------------------------------------------------------

Describe 'Merge-FollowupRecords' {
    BeforeAll {
        function script:New-FollowupMarkerFixture {
            param(
                [int]$IssueNumber,
                [string]$Phase,
                [int]$SchemaVersion,
                [string]$DecisionId,
                [string]$EngineerChoice,
                [string]$ExtraYamlIndentedLines = ''
            )
            $fence = '```'
            @"
<!-- engagement-record-$Phase-$IssueNumber -->
$fence yaml
schema_version: $SchemaVersion
phase: $Phase
capture_session: "test-session"
load_bearing_decisions:
  - decision_id: $DecisionId
    classification: routine
    engineer_choice: "$EngineerChoice"$ExtraYamlIndentedLines
$fence
"@ -replace '``` yaml', '```yaml'
        }
    }

    It 'is idempotent: merging an already-merged batch produces the same result' {
        if (-not $script:HasYaml) { Set-ItResult -Skipped -Because 'powershell-yaml module not installed'; return }

        $marker = script:New-FollowupMarkerFixture -IssueNumber 999 -Phase 'plan' -SchemaVersion 2 -DecisionId 'followup-1111111111111111' -EngineerChoice 'old-choice'
        $prior = @([PSCustomObject]@{ Body = $marker; CreatedAt = [DateTime]::Parse('2026-01-01T00:00:00Z').ToUniversalTime() })

        $result1 = Merge-FollowupRecords -Number 999 -Type issue -PriorMarkerBodies $prior -WarningAction SilentlyContinue
        $result2 = Merge-FollowupRecords -Number 999 -Type issue -PriorMarkerBodies $prior -CurrentBatch $result1 -WarningAction SilentlyContinue

        $result2.Count | Should -Be $result1.Count
        ($result2 | Sort-Object decision_id).decision_id | Should -Be ($result1 | Sort-Object decision_id).decision_id
        ($result2 | Where-Object decision_id -eq 'followup-1111111111111111').engineer_choice | Should -Be 'old-choice'
    }

    It 'the unbroken-chain guard fires a loud warning when a prior key would be dropped' {
        if (-not $script:HasYaml) { Set-ItResult -Skipped -Because 'powershell-yaml module not installed'; return }

        # schema_version 99 is unsupported and makes Read-EngagementRecords throw for
        # this marker, so the structured decision is lost -- but the raw-text regex
        # scan (the guard's independent truth source) still finds the followup- key.
        $badMarker = script:New-FollowupMarkerFixture -IssueNumber 999 -Phase 'design' -SchemaVersion 99 -DecisionId 'followup-2222222222222222' -EngineerChoice 'drop'
        $prior = @([PSCustomObject]@{ Body = $badMarker; CreatedAt = [DateTime]::Parse('2026-02-01T00:00:00Z').ToUniversalTime() })

        $warnings = $null
        $result = Merge-FollowupRecords -Number 999 -Type issue -PriorMarkerBodies $prior -WarningVariable warnings -WarningAction SilentlyContinue

        ($result | Where-Object decision_id -eq 'followup-2222222222222222') | Should -BeNullOrEmpty
        ($warnings -join ' | ') | Should -Match 'unbroken-chain guard tripped'
        ($warnings -join ' | ') | Should -Match 'followup-2222222222222222'
    }

    It 'precedence: the current batch wins over a prior marker for the same key' {
        if (-not $script:HasYaml) { Set-ItResult -Skipped -Because 'powershell-yaml module not installed'; return }

        $marker = script:New-FollowupMarkerFixture -IssueNumber 999 -Phase 'plan' -SchemaVersion 2 -DecisionId 'followup-3333333333333333' -EngineerChoice 'old-choice'
        $prior = @([PSCustomObject]@{ Body = $marker; CreatedAt = [DateTime]::Parse('2026-03-01T00:00:00Z').ToUniversalTime() })

        $currentBatch = @([PSCustomObject]@{ decision_id = 'followup-3333333333333333'; engineer_choice = 'new-choice' })

        $result = Merge-FollowupRecords -Number 999 -Type issue -PriorMarkerBodies $prior -CurrentBatch $currentBatch -WarningAction SilentlyContinue

        $entry = $result | Where-Object decision_id -eq 'followup-3333333333333333'
        $entry.engineer_choice | Should -Be 'new-choice'
    }

    It 'a nested ac_cross_check payload survives merge and re-emit unchanged' {
        if (-not $script:HasYaml) { Set-ItResult -Skipped -Because 'powershell-yaml module not installed'; return }

        $nestedYaml = @"

    ac_cross_check:
      ac_id: "AC3"
      covered: true
      note: "nested fidelity check"
"@
        $marker = script:New-FollowupMarkerFixture -IssueNumber 999 -Phase 'design' -SchemaVersion 2 -DecisionId 'followup-5555555555555555' -EngineerChoice 'drop' -ExtraYamlIndentedLines $nestedYaml
        $prior = @([PSCustomObject]@{ Body = $marker; CreatedAt = [DateTime]::Parse('2026-04-01T00:00:00Z').ToUniversalTime() })

        $result = Merge-FollowupRecords -Number 999 -Type issue -PriorMarkerBodies $prior -WarningAction SilentlyContinue
        $entry = $result | Where-Object decision_id -eq 'followup-5555555555555555'
        $entry | Should -Not -BeNullOrEmpty
        $entry.ac_cross_check.ac_id | Should -Be 'AC3'
        $entry.ac_cross_check.covered | Should -BeTrue
        $entry.ac_cross_check.note | Should -Be 'nested fidelity check'

        # Re-emit (simulate the writer-side cumulative re-emission per DD4) and
        # re-parse: the nested sub-object must still be intact.
        $reemitted = ConvertTo-Yaml -Data $entry
        $reparsed = ConvertFrom-Yaml -Yaml $reemitted
        $reparsed.ac_cross_check.ac_id | Should -Be 'AC3'
        $reparsed.ac_cross_check.covered | Should -BeTrue
        $reparsed.ac_cross_check.note | Should -Be 'nested fidelity check'
    }

    It 'never drops a prior entry that is not overridden by the current batch' {
        if (-not $script:HasYaml) { Set-ItResult -Skipped -Because 'powershell-yaml module not installed'; return }

        $marker = script:New-FollowupMarkerFixture -IssueNumber 999 -Phase 'plan' -SchemaVersion 2 -DecisionId 'followup-8888888888888888' -EngineerChoice 'keep-me'
        $prior = @([PSCustomObject]@{ Body = $marker; CreatedAt = [DateTime]::Parse('2026-05-01T00:00:00Z').ToUniversalTime() })

        $currentBatch = @([PSCustomObject]@{ decision_id = 'followup-9999999999999999'; engineer_choice = 'unrelated' })

        $result = Merge-FollowupRecords -Number 999 -Type issue -PriorMarkerBodies $prior -CurrentBatch $currentBatch -WarningAction SilentlyContinue

        ($result | Where-Object decision_id -eq 'followup-8888888888888888').engineer_choice | Should -Be 'keep-me'
        ($result | Where-Object decision_id -eq 'followup-9999999999999999').engineer_choice | Should -Be 'unrelated'
    }

    It 'exercises the -Type pr path end-to-end (R7)' {
        if (-not $script:HasYaml) { Set-ItResult -Skipped -Because 'powershell-yaml module not installed'; return }

        # review phase requires schema_version >= 4 (frame-engagement-record-core.ps1).
        $marker = script:New-FollowupMarkerFixture -IssueNumber 555 -Phase 'review' -SchemaVersion 4 -DecisionId 'followup-4444444444444444' -EngineerChoice 'pr-choice'
        $prior = @([PSCustomObject]@{ Body = $marker; CreatedAt = [DateTime]::Parse('2026-06-01T00:00:00Z').ToUniversalTime() })

        $result = Merge-FollowupRecords -Number 555 -Type pr -PriorMarkerBodies $prior -WarningAction SilentlyContinue

        ($result | Where-Object decision_id -eq 'followup-4444444444444444').engineer_choice | Should -Be 'pr-choice'
    }

    It 'throws a clear error when -PriorMarkerBodies is supplied without an explicit -Number (R9)' {
        $prior = @([PSCustomObject]@{ Body = 'irrelevant'; CreatedAt = [DateTime]::UtcNow })
        { Merge-FollowupRecords -Type issue -PriorMarkerBodies $prior -WarningAction SilentlyContinue } |
            Should -Throw -ExceptionType ([System.Management.Automation.PSArgumentException])
    }

    It 'throws a clear error when -PriorMarkerBodies is supplied with an explicit -Number 0 (G5)' {
        $prior = @([PSCustomObject]@{ Body = 'irrelevant'; CreatedAt = [DateTime]::UtcNow })
        { Merge-FollowupRecords -Type issue -Number 0 -PriorMarkerBodies $prior -WarningAction SilentlyContinue } |
            Should -Throw -ExceptionType ([System.Management.Automation.PSArgumentException])
    }

    It 'breaks a CreatedAt tie deterministically by preferring the higher comment Id (R17)' {
        if (-not $script:HasYaml) { Set-ItResult -Skipped -Because 'powershell-yaml module not installed'; return }

        $tiedCreatedAt = [DateTime]::Parse('2026-07-01T00:00:00Z').ToUniversalTime()
        $markerLow = script:New-FollowupMarkerFixture -IssueNumber 999 -Phase 'plan' -SchemaVersion 2 -DecisionId 'followup-cccccccccccccccc' -EngineerChoice 'lower-id-choice'
        $markerHigh = script:New-FollowupMarkerFixture -IssueNumber 999 -Phase 'design' -SchemaVersion 2 -DecisionId 'followup-cccccccccccccccc' -EngineerChoice 'higher-id-choice'
        $prior = @(
            [PSCustomObject]@{ Body = $markerLow; CreatedAt = $tiedCreatedAt; Id = 100 }
            [PSCustomObject]@{ Body = $markerHigh; CreatedAt = $tiedCreatedAt; Id = 200 }
        )

        $result = Merge-FollowupRecords -Number 999 -Type issue -PriorMarkerBodies $prior -WarningAction SilentlyContinue

        ($result | Where-Object decision_id -eq 'followup-cccccccccccccccc').engineer_choice | Should -Be 'higher-id-choice'
    }

    It 'skips ordinary discussion comments without the engagement-record- substring (R18 pre-filter)' {
        if (-not $script:HasYaml) { Set-ItResult -Skipped -Because 'powershell-yaml module not installed'; return }

        $marker = script:New-FollowupMarkerFixture -IssueNumber 999 -Phase 'plan' -SchemaVersion 2 -DecisionId 'followup-dddddddddddddddd' -EngineerChoice 'kept-choice'
        $chatter = 'Just a regular discussion comment with no markers at all.'
        $prior = @(
            [PSCustomObject]@{ Body = $chatter; CreatedAt = [DateTime]::Parse('2026-07-05T00:00:00Z').ToUniversalTime() }
            [PSCustomObject]@{ Body = $marker; CreatedAt = [DateTime]::Parse('2026-07-06T00:00:00Z').ToUniversalTime() }
        )

        $result = Merge-FollowupRecords -Number 999 -Type issue -PriorMarkerBodies $prior -WarningAction SilentlyContinue

        ($result | Where-Object decision_id -eq 'followup-dddddddddddddddd').engineer_choice | Should -Be 'kept-choice'
    }
}

# ---------------------------------------------------------------------------
# Get-FollowupPriorMarkerBodies (R13)
# ---------------------------------------------------------------------------

Describe 'Get-FollowupPriorMarkerBodies' {
    It 'fetches multiple comment bodies from a successful gh api --paginate call' {
        $mockGhPath = Join-Path $TestDrive 'gh-multi-body.ps1'
        @'
param()
Write-Output '[{"body":"first marker","created_at":"2026-01-01T00:00:00Z","id":11},{"body":"second marker","created_at":"2026-02-02T00:00:00Z","id":22}]'
exit 0
'@ | Set-Content $mockGhPath -Encoding UTF8

        $result = Get-FollowupPriorMarkerBodies -Type issue -Number 42 -Repo 'example-owner/example-repo' -GhCliPath $mockGhPath

        $result.Count | Should -Be 2
        $result[0].Body | Should -Be 'first marker'
        $result[0].Id | Should -Be 11
        $result[1].Body | Should -Be 'second marker'
        $result[1].Id | Should -Be 22
    }

    It 'warns and returns no prior markers when gh api fails (non-zero exit)' {
        $mockGhPath = Join-Path $TestDrive 'gh-failure.ps1'
        @'
param()
exit 1
'@ | Set-Content $mockGhPath -Encoding UTF8

        $warnings = $null
        $result = Get-FollowupPriorMarkerBodies -Type issue -Number 42 -Repo 'example-owner/example-repo' -GhCliPath $mockGhPath -WarningVariable warnings -WarningAction SilentlyContinue

        $result.Count | Should -Be 0
        ($warnings -join ' | ') | Should -Match 'gh api .* failed'
    }

    It 'warns and returns no prior markers when the gh binary is missing (throws, not just non-zero exit) (G4)' {
        $missingGhPath = Join-Path $TestDrive 'gh-does-not-exist.ps1'

        $warnings = $null
        $result = Get-FollowupPriorMarkerBodies -Type issue -Number 42 -Repo 'example-owner/example-repo' -GhCliPath $missingGhPath -WarningVariable warnings -WarningAction SilentlyContinue

        $result.Count | Should -Be 0
        ($warnings -join ' | ') | Should -Match 'threw an exception'
    }

    It 'resolves owner/repo from the git remote via regex when -Repo is not supplied' {
        $mockGhPath = Join-Path $TestDrive 'gh-repo-resolution.ps1'
        $argsCapturePath = Join-Path $TestDrive 'gh-args-capture.txt'
        @"
param()
`$args -join ' ' | Set-Content -Path '$argsCapturePath' -Encoding UTF8
Write-Output '[{"body":"marker body","created_at":"2026-01-01T00:00:00Z","id":1}]'
exit 0
"@ | Set-Content $mockGhPath -Encoding UTF8

        $result = Get-FollowupPriorMarkerBodies -Type issue -Number 42 -GhCliPath $mockGhPath

        $capturedArgs = Get-Content $argsCapturePath -Raw
        $capturedArgs | Should -Match 'repos/[^/\s]+/[^/\s]+/issues/42/comments'
        $result.Count | Should -Be 1
        $result[0].Body | Should -Be 'marker body'
    }
}
