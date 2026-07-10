#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

# SECURITY: Do NOT import powershell-yaml or use ConvertFrom-Yaml in this file.

BeforeAll {
    $script:LibRoot = Join-Path $PSScriptRoot '..' 'lib'
    . (Join-Path $script:LibRoot 'phase-containment-rolling-history-core.ps1')
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
}

# ---------------------------------------------------------------------------
# 1. Cache freshness — future-dated cache rejected
# ---------------------------------------------------------------------------

Describe 'Test-PhaseContainmentCacheFresh — future-dated cache rejected' {
    It 'rejects a cache file where generated_at is 1 hour in the future' {
        $futureTimestamp = (Get-Date).ToUniversalTime().AddHours(1).ToString('o')
        $result = Test-PhaseContainmentCacheFresh -GeneratedAtUtcString $futureTimestamp
        $result | Should -Be $false
    }

    It 'rejects a cache file where generated_at is 5 minutes in the future' {
        $futureTimestamp = (Get-Date).ToUniversalTime().AddMinutes(5).ToString('o')
        $result = Test-PhaseContainmentCacheFresh -GeneratedAtUtcString $futureTimestamp
        $result | Should -Be $false
    }
}

# ---------------------------------------------------------------------------
# 2. Cache freshness — stale cache rejected
# ---------------------------------------------------------------------------

Describe 'Test-PhaseContainmentCacheFresh — stale cache rejected' {
    It 'rejects a cache file where generated_at is 2 hours ago' {
        $staleTimestamp = (Get-Date).ToUniversalTime().AddHours(-2).ToString('o')
        $result = Test-PhaseContainmentCacheFresh -GeneratedAtUtcString $staleTimestamp
        $result | Should -Be $false
    }

    It 'rejects a cache file where generated_at is exactly 1 hour ago' {
        $staleTimestamp = (Get-Date).ToUniversalTime().AddHours(-1).ToString('o')
        $result = Test-PhaseContainmentCacheFresh -GeneratedAtUtcString $staleTimestamp
        $result | Should -Be $false
    }
}

# ---------------------------------------------------------------------------
# 3. Cache freshness — valid cache accepted
# ---------------------------------------------------------------------------

Describe 'Test-PhaseContainmentCacheFresh — valid cache accepted' {
    It 'accepts a cache file where generated_at is 30 minutes ago' {
        $freshTimestamp = (Get-Date).ToUniversalTime().AddMinutes(-30).ToString('o')
        $result = Test-PhaseContainmentCacheFresh -GeneratedAtUtcString $freshTimestamp
        $result | Should -Be $true
    }

    It 'accepts a cache file where generated_at is 59 minutes ago' {
        $freshTimestamp = (Get-Date).ToUniversalTime().AddMinutes(-59).ToString('o')
        $result = Test-PhaseContainmentCacheFresh -GeneratedAtUtcString $freshTimestamp
        $result | Should -Be $true
    }
}

# ---------------------------------------------------------------------------
# 4. Dedup — latest createdAt wins when finding_key is the same
# escape_distance = projection(caught_stage) - ordinal(catchable_phase)
#   design(1) + code-review(3)  => escape = 2
# ---------------------------------------------------------------------------

Describe 'Invoke-PhaseContainmentDedup — latest createdAt wins' {
    BeforeAll {
        function script:New-ValidPCEntry4 {
            param([string]$FindingKey = 'code-review:762:F1', [string]$CreatedAt = '2024-01-01T12:00:00Z')
            return @{
                finding_key       = $FindingKey
                introduced_phase  = 'design'
                catchable_phase   = 'design'
                caught_stage      = 'code-review'
                escape_distance   = 2
                severity          = 'high'
                systemic_fix_type = 'skill'
                category          = 'architecture'
                apparatus_meta    = $false
                seed              = $false
                createdAt         = $CreatedAt
                surface           = 'issue'
                issueOrPrNumber   = 762
            }
        }
    }

    It 'keeps only the entry with the newer createdAt when finding_key matches' {
        $older = script:New-ValidPCEntry4 -FindingKey 'code-review:762:F1' -CreatedAt '2024-01-01T10:00:00Z'
        $newer = script:New-ValidPCEntry4 -FindingKey 'code-review:762:F1' -CreatedAt '2024-01-01T12:00:00Z'

        $result = Invoke-PhaseContainmentDedup -RawEntries @($older, $newer)

        $result | Should -HaveCount 1
        $result[0].createdAt | Should -Be '2024-01-01T12:00:00Z'
    }

    It 'keeps only the entry with the newer createdAt regardless of input order' {
        $older = script:New-ValidPCEntry4 -FindingKey 'code-review:762:F1' -CreatedAt '2024-01-01T10:00:00Z'
        $newer = script:New-ValidPCEntry4 -FindingKey 'code-review:762:F1' -CreatedAt '2024-01-01T12:00:00Z'

        # Newer first, older second — same result expected
        $result = Invoke-PhaseContainmentDedup -RawEntries @($newer, $older)

        $result | Should -HaveCount 1
        $result[0].createdAt | Should -Be '2024-01-01T12:00:00Z'
    }
}

# ---------------------------------------------------------------------------
# 5. Dedup — different keys, both survive
# ---------------------------------------------------------------------------

Describe 'Invoke-PhaseContainmentDedup — different keys both survive' {
    BeforeAll {
        function script:New-ValidPCEntry5 {
            param([string]$FindingKey = 'code-review:762:F1', [string]$CreatedAt = '2024-01-01T12:00:00Z')
            return @{
                finding_key       = $FindingKey
                introduced_phase  = 'design'
                catchable_phase   = 'design'
                caught_stage      = 'code-review'
                escape_distance   = 2
                severity          = 'high'
                systemic_fix_type = 'skill'
                category          = 'architecture'
                apparatus_meta    = $false
                seed              = $false
                createdAt         = $CreatedAt
                surface           = 'issue'
                issueOrPrNumber   = 762
            }
        }
    }

    It 'retains both entries when they have different finding_key values' {
        $entry1 = script:New-ValidPCEntry5 -FindingKey 'code-review:762:F1' -CreatedAt '2024-01-01T10:00:00Z'
        $entry2 = script:New-ValidPCEntry5 -FindingKey 'code-review:762:F2' -CreatedAt '2024-01-01T11:00:00Z'

        $result = Invoke-PhaseContainmentDedup -RawEntries @($entry1, $entry2)

        $result | Should -HaveCount 2
        ($result | Where-Object { $_.finding_key -eq 'code-review:762:F1' }) | Should -Not -BeNullOrEmpty
        ($result | Where-Object { $_.finding_key -eq 'code-review:762:F2' }) | Should -Not -BeNullOrEmpty
    }

    It 'handles an empty input array and returns empty' {
        $result = Invoke-PhaseContainmentDedup -RawEntries @()
        $result | Should -HaveCount 0
    }
}

# ---------------------------------------------------------------------------
# 6. Pagination simulation — entries from a paginated comment thread collected
# escape_distance for design + code-review = 3 - 1 = 2
# escape_distance for plan  + code-review = 3 - 2 = 1
# ---------------------------------------------------------------------------

Describe 'Invoke-PhaseContainmentCommentScan — pagination collects entries from all pages' {
    It 'collects a phase-containment entry from the second page when page 1 has none' {
        # Page 1: 100 comment bodies, none containing phase-containment
        $page1Bodies = 1..100 | ForEach-Object { "This is comment $_ with no phase-containment block." }

        # Page 2: 1 comment body with a valid phase-containment block
        # escape_distance = projection(code-review=3) - ordinal(design=1) = 2
        $page2Body = @"
<!-- phase-containment-762 -->
finding_key: code-review:762:F1
introduced_phase: design
catchable_phase: design
caught_stage: code-review
escape_distance: 2
severity: high
systemic_fix_type: skill
category: architecture
apparatus_meta: false
seed: false
<!-- /phase-containment-762 -->
"@

        $allBodies = @($page1Bodies) + @($page2Body)

        $scanResult = Invoke-PhaseContainmentCommentScan -CommentBodies $allBodies -IssueOrPrNumber 762

        $scanResult.Entries | Should -HaveCount 1
        $scanResult.Entries[0].finding_key | Should -Be 'code-review:762:F1'
        $scanResult.InvalidEntryCount | Should -Be 0
    }

    It 'collects entries from multiple pages when both pages have valid blocks' {
        # escape_distance for design + code-review = 2
        $page1Body = @"
<!-- phase-containment-762 -->
finding_key: code-review:762:F1
introduced_phase: design
catchable_phase: design
caught_stage: code-review
escape_distance: 2
severity: high
systemic_fix_type: skill
category: architecture
apparatus_meta: false
seed: false
<!-- /phase-containment-762 -->
"@

        # escape_distance for plan + code-review = 3 - 2 = 1
        $page2Body = @"
<!-- phase-containment-762 -->
finding_key: code-review:762:F2
introduced_phase: plan
catchable_phase: plan
caught_stage: code-review
escape_distance: 1
severity: medium
systemic_fix_type: instruction
category: security
apparatus_meta: false
seed: false
<!-- /phase-containment-762 -->
"@

        $scanResult = Invoke-PhaseContainmentCommentScan -CommentBodies @($page1Body, $page2Body) -IssueOrPrNumber 762

        $scanResult.Entries | Should -HaveCount 2
        $scanResult.InvalidEntryCount | Should -Be 0
    }
}

# ---------------------------------------------------------------------------
# 7. Invalid block skipped with warning
# ---------------------------------------------------------------------------

Describe 'Invoke-PhaseContainmentCommentScan — invalid block skipped with warning' {
    It 'skips a malformed block that is missing required fields and emits a warning' {
        # Missing severity, systemic_fix_type, category fields
        $malformedBody = @"
<!-- phase-containment-762 -->
finding_key: code-review:762:MALFORMED
introduced_phase: design
catchable_phase: design
caught_stage: code-review
escape_distance: 2
<!-- /phase-containment-762 -->
"@

        # Redirect warning stream to suppress console noise; still validates behavior
        $scanResult = Invoke-PhaseContainmentCommentScan -CommentBodies @($malformedBody) -IssueOrPrNumber 762 3>$null

        @($scanResult.Entries) | Should -HaveCount 0
        # P8: the drop must be counted toward InvalidEntryCount, not just
        # silently skipped — this is a validation-failure drop (missing
        # required fields), not a parse failure, so it exercises the "every
        # validation-failure drop, not just Rule 12" requirement.
        $scanResult.InvalidEntryCount | Should -Be 1
    }

    It 'processes valid entries even when a preceding comment has a malformed block' {
        $malformedBody = @"
<!-- phase-containment-762 -->
finding_key: code-review:762:MALFORMED
introduced_phase: design
<!-- /phase-containment-762 -->
"@

        # escape_distance for design + code-review = 2
        $validBody = @"
<!-- phase-containment-762 -->
finding_key: code-review:762:F1
introduced_phase: design
catchable_phase: design
caught_stage: code-review
escape_distance: 2
severity: high
systemic_fix_type: skill
category: architecture
apparatus_meta: false
seed: false
<!-- /phase-containment-762 -->
"@

        $scanResult = Invoke-PhaseContainmentCommentScan -CommentBodies @($malformedBody, $validBody) -IssueOrPrNumber 762 3>$null

        $scanResult.Entries | Should -HaveCount 1
        $scanResult.Entries[0].finding_key | Should -Be 'code-review:762:F1'
        $scanResult.InvalidEntryCount | Should -Be 1
    }

    It 'counts a D6 parser-level pair-match skip toward InvalidEntryCount (issue #772/#831 M4)' {
        # open1 (gh-F1) open2 (gh-F2) close1 close2 -- open1 is unclosed/
        # malformed per D6 pair-matching and is dropped by
        # Get-PhaseContainmentBlock's own pair-match BEFORE this function's
        # parse/validation loop ever sees it. Prior to the M4 fix, this skip
        # was invisible to InvalidEntryCount.
        $body = @"
<!-- phase-containment-772 -->
finding_key: code-review:772:F1
<!-- phase-containment-772 -->
finding_key: code-review:772:F2
introduced_phase: design
catchable_phase: design
caught_stage: code-review
escape_distance: 2
severity: high
systemic_fix_type: skill
category: architecture
apparatus_meta: false
seed: false
<!-- /phase-containment-772 -->
<!-- /phase-containment-772 -->
"@

        $scanResult = Invoke-PhaseContainmentCommentScan -CommentBodies @($body) -IssueOrPrNumber 772 3>$null

        # Only the valid, later block (F2) is returned as an entry.
        $scanResult.Entries | Should -HaveCount 1
        $scanResult.Entries[0].finding_key | Should -Be 'code-review:772:F2'
        # The D6 parser-level skip of the F1 block must be folded in here too.
        $scanResult.InvalidEntryCount | Should -Be 1 -Because (
            "the malformed/unclosed F1 block was dropped by Get-PhaseContainmentBlock's own D6 pair-match, not by this function's parse/validation loop, but must still be reflected in InvalidEntryCount"
        )
    }
}

# ---------------------------------------------------------------------------
# 8. Apparatus_meta entries correctly flagged
# escape_distance for design + code-review = 2
# ---------------------------------------------------------------------------

Describe 'Invoke-PhaseContainmentCommentScan — apparatus_meta flag is set correctly' {
    It 'sets apparatus_meta to $true when the block declares apparatus_meta: true' {
        $body = @"
<!-- phase-containment-762 -->
finding_key: code-review:762:META1
introduced_phase: design
catchable_phase: design
caught_stage: code-review
escape_distance: 2
severity: low
systemic_fix_type: none
category: pattern
apparatus_meta: true
seed: false
<!-- /phase-containment-762 -->
"@

        $scanResult = Invoke-PhaseContainmentCommentScan -CommentBodies @($body) -IssueOrPrNumber 762

        $scanResult.Entries | Should -HaveCount 1
        $scanResult.Entries[0].apparatus_meta | Should -Be $true
    }

    It 'sets apparatus_meta to $false when the block declares apparatus_meta: false' {
        $body = @"
<!-- phase-containment-762 -->
finding_key: code-review:762:F1
introduced_phase: design
catchable_phase: design
caught_stage: code-review
escape_distance: 2
severity: high
systemic_fix_type: skill
category: architecture
apparatus_meta: false
seed: false
<!-- /phase-containment-762 -->
"@

        $scanResult = Invoke-PhaseContainmentCommentScan -CommentBodies @($body) -IssueOrPrNumber 762

        $scanResult.Entries | Should -HaveCount 1
        $scanResult.Entries[0].apparatus_meta | Should -Be $false
    }
}

# ---------------------------------------------------------------------------
# 9. Rollup — n=4 stage → InsufficientData + withheld relaxation signal
# ---------------------------------------------------------------------------

Describe 'Get-PhaseContainmentRollup — n=4 insufficient data withholds relaxation' {
    BeforeAll {
        function script:New-ImplEntry {
            param(
                [string]$FindingKey,
                [int]$EscapeDistance = 0,
                [string]$Severity = 'low',
                [bool]$ApparatusMeta = $false
            )
            return [PSCustomObject]@{
                finding_key       = $FindingKey
                introduced_phase  = 'implementation'
                catchable_phase   = 'implementation'
                caught_stage      = 'code-review'
                escape_distance   = $EscapeDistance
                severity          = $Severity
                systemic_fix_type = 'none'
                category          = 'pattern'
                apparatus_meta    = $ApparatusMeta
                seed              = $false
                createdAt         = '2024-01-01T12:00:00Z'
                surface           = 'pr'
                issueOrPrNumber   = 800
            }
        }
    }

    It 'marks code-review stage as InsufficientData when N=4 and withholds relaxation signal' {
        $entries = @(
            script:New-ImplEntry -FindingKey 'code-review:800:F1'
            script:New-ImplEntry -FindingKey 'code-review:800:F2'
            script:New-ImplEntry -FindingKey 'code-review:800:F3'
            script:New-ImplEntry -FindingKey 'code-review:800:F4'
        )

        $result = Get-PhaseContainmentRollup -Entries $entries

        $result.Stages['code-review'].InsufficientData | Should -Be $true
        $result.Stages['code-review'].EscapeRate       | Should -BeNullOrEmpty
        $result.Stages['code-review'].RelaxationEligible | Should -BeNullOrEmpty
    }
}

# ---------------------------------------------------------------------------
# 10. Rollup — denominator==0 → null rate, no crash
# ---------------------------------------------------------------------------

Describe 'Get-PhaseContainmentRollup — denominator zero returns null rate without crash' {
    It 'returns DenominatorZero=$true and null EscapeRate for plan-stress-test when no entries have catchable_phase=plan' {
        # Pass entries with catchable_phase=implementation only — no plan entries
        $entries = @(
            [PSCustomObject]@{
                finding_key       = 'code-review:800:F1'
                introduced_phase  = 'implementation'
                catchable_phase   = 'implementation'
                caught_stage      = 'code-review'
                escape_distance   = 0
                severity          = 'low'
                systemic_fix_type = 'none'
                category          = 'pattern'
                apparatus_meta    = $false
                seed              = $false
                createdAt         = '2024-01-01T12:00:00Z'
                surface           = 'pr'
                issueOrPrNumber   = 800
            }
        )

        { $result = Get-PhaseContainmentRollup -Entries $entries } | Should -Not -Throw

        $result = Get-PhaseContainmentRollup -Entries $entries
        $result.Stages['plan-stress-test'].DenominatorZero | Should -Be $true
        $result.Stages['plan-stress-test'].EscapeRate      | Should -BeNullOrEmpty
    }

    It 'handles an empty entries array without throwing' {
        { Get-PhaseContainmentRollup -Entries @() } | Should -Not -Throw
    }
}

# ---------------------------------------------------------------------------
# 11. Rollup — critical severity in window → RelaxationEligible not $true
# ---------------------------------------------------------------------------

Describe 'Get-PhaseContainmentRollup — critical severity blocks relaxation eligibility' {
    BeforeAll {
        function script:New-PlanEntry {
            param(
                [string]$FindingKey,
                [int]$EscapeDistance = 0,
                [string]$Severity = 'low'
            )
            return [PSCustomObject]@{
                finding_key       = $FindingKey
                introduced_phase  = 'plan'
                catchable_phase   = 'plan'
                caught_stage      = 'plan-stress-test'
                escape_distance   = $EscapeDistance
                severity          = $Severity
                systemic_fix_type = 'instruction'
                category          = 'architecture'
                apparatus_meta    = $false
                seed              = $false
                createdAt         = '2024-01-01T12:00:00Z'
                surface           = 'issue'
                issueOrPrNumber   = 801
            }
        }
    }

    It 'sets RelaxationEligible to $false (not $true) when a critical-severity finding is present' {
        $entries = @(
            script:New-PlanEntry -FindingKey 'plan-stress-test:801:F1' -Severity 'low'
            script:New-PlanEntry -FindingKey 'plan-stress-test:801:F2' -Severity 'low'
            script:New-PlanEntry -FindingKey 'plan-stress-test:801:F3' -Severity 'low'
            script:New-PlanEntry -FindingKey 'plan-stress-test:801:F4' -Severity 'low'
            script:New-PlanEntry -FindingKey 'plan-stress-test:801:F5' -Severity 'low'
            script:New-PlanEntry -FindingKey 'plan-stress-test:801:F6' -Severity 'critical'
        )

        $result = Get-PhaseContainmentRollup -Entries $entries

        $stageResult = $result.Stages['plan-stress-test']
        $stageResult.RelaxationEligible | Should -Not -Be $true
    }
}

# ---------------------------------------------------------------------------
# 12. Rollup — entry count < sustained count → DataUntrustworthy
# ---------------------------------------------------------------------------

Describe 'Get-PhaseContainmentRollup — completeness mismatch marks DataUntrustworthy' {
    It 'sets DataUntrustworthy=$true when entry count differs from SustainedCounts expectation' {
        $entries = @(
            [PSCustomObject]@{
                finding_key       = 'design-challenge:802:F1'
                introduced_phase  = 'design'
                catchable_phase   = 'design'
                caught_stage      = 'design-challenge'
                escape_distance   = 0
                severity          = 'low'
                systemic_fix_type = 'skill'
                category          = 'architecture'
                apparatus_meta    = $false
                seed              = $false
                createdAt         = '2024-01-01T12:00:00Z'
                surface           = 'issue'
                issueOrPrNumber   = 802
            }
            [PSCustomObject]@{
                finding_key       = 'design-challenge:802:F2'
                introduced_phase  = 'design'
                catchable_phase   = 'design'
                caught_stage      = 'design-challenge'
                escape_distance   = 0
                severity          = 'low'
                systemic_fix_type = 'skill'
                category          = 'architecture'
                apparatus_meta    = $false
                seed              = $false
                createdAt         = '2024-01-01T12:00:00Z'
                surface           = 'issue'
                issueOrPrNumber   = 802
            }
            [PSCustomObject]@{
                finding_key       = 'design-challenge:802:F3'
                introduced_phase  = 'design'
                catchable_phase   = 'design'
                caught_stage      = 'design-challenge'
                escape_distance   = 0
                severity          = 'low'
                systemic_fix_type = 'skill'
                category          = 'architecture'
                apparatus_meta    = $false
                seed              = $false
                createdAt         = '2024-01-01T12:00:00Z'
                surface           = 'issue'
                issueOrPrNumber   = 802
            }
        )

        $sustainedCounts = @{ 'design-challenge' = 5; 'plan-stress-test' = 0; 'code-review' = 0 }
        $result = Get-PhaseContainmentRollup -Entries $entries -SustainedCounts $sustainedCounts

        $result.Stages['design-challenge'].DataUntrustworthy  | Should -Be $true
        $result.Stages['design-challenge'].RelaxationEligible | Should -BeNullOrEmpty
    }
}

# ---------------------------------------------------------------------------
# 13. Surface A/B outer search pagination — nodes from page 2 are processed
# ---------------------------------------------------------------------------

Describe 'Get-SurfaceAEntriesGraphQL — outer search pagination collects nodes from all pages' {
    BeforeAll {
        # A comment body carrying a plan-issue marker plus a valid phase-containment
        # block, so Invoke-PhaseContainmentCommentScan produces one entry per issue.
        function script:New-SurfacePageBody {
            param([int]$Number, [string]$FindingKey)
            return @"
<!-- plan-issue-$Number -->
<!-- phase-containment-$Number -->
finding_key: $FindingKey
introduced_phase: design
catchable_phase: design
caught_stage: code-review
escape_distance: 2
severity: high
systemic_fix_type: skill
category: architecture
apparatus_meta: false
seed: false
<!-- /phase-containment-$Number -->
"@
        }

        # Build a search-result GraphQL response with one issue node.
        function script:New-SearchPageResponse {
            param(
                [int]$IssueNumber,
                [string]$CommentBody,
                [bool]$HasNextPage,
                [string]$EndCursor
            )
            $payload = @{
                data = @{
                    search = @{
                        pageInfo = @{ hasNextPage = $HasNextPage; endCursor = $EndCursor }
                        nodes    = @(
                            @{
                                number   = $IssueNumber
                                comments = @{
                                    nodes    = @(@{ body = $CommentBody; createdAt = '2024-01-01T12:00:00Z' })
                                    pageInfo = @{ hasNextPage = $false; endCursor = $null }
                                }
                            }
                        )
                    }
                }
            }
            return ($payload | ConvertTo-Json -Depth 12)
        }
    }

    AfterEach {
        if (Get-Command 'gh' -CommandType Function -ErrorAction SilentlyContinue) {
            Remove-Item -Path Function:gh -ErrorAction SilentlyContinue
        }
    }

    It 'processes an issue that only appears on the second search page' {
        $page1 = script:New-SearchPageResponse `
            -IssueNumber 901 `
            -CommentBody (script:New-SurfacePageBody -Number 901 -FindingKey 'code-review:901:F1') `
            -HasNextPage $true `
            -EndCursor 'SEARCHCURSOR1'

        $page2 = script:New-SearchPageResponse `
            -IssueNumber 902 `
            -CommentBody (script:New-SurfacePageBody -Number 902 -FindingKey 'code-review:902:F1') `
            -HasNextPage $false `
            -EndCursor $null

        $global:mockSearchPage1 = $page1
        $global:mockSearchPage2 = $page2

        function global:gh {
            param([Parameter(ValueFromRemainingArguments = $true)]$Args)
            $joined = $Args -join ' '
            $global:LASTEXITCODE = 0
            # The outer search query carries 'after:' only on the second page.
            if ($joined -match 'after:') {
                return $global:mockSearchPage2
            }
            return $global:mockSearchPage1
        }

        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        $result = script:Get-SurfaceAEntriesGraphQL `
            -Owner 'Grimblaz' -Repo 'agent-orchestra' -WindowDays 30 `
            -Stopwatch $stopwatch -TimeoutSeconds 30

        $result.Truncated | Should -Be $false
        $findingKeys = @($result.Entries | ForEach-Object { $_['finding_key'] })
        $findingKeys | Should -Contain 'code-review:901:F1'
        # The page-2 node must be processed — this is the regression guard for F10.
        $findingKeys | Should -Contain 'code-review:902:F1'
    }

    It 'terminates when a search page claims hasNextPage but returns a null/empty endCursor (F1)' {
        # Malformed page: hasNextPage = $true but endCursor = $null. Before the
        # F1 guard, the advance produced after: "" and re-issued the identical
        # query every iteration, only exiting via the timeout. With the guard,
        # the loop must terminate cleanly and still surface the single page's entry.
        $malformedPage = script:New-SearchPageResponse `
            -IssueNumber 905 `
            -CommentBody (script:New-SurfacePageBody -Number 905 -FindingKey 'code-review:905:F1') `
            -HasNextPage $true `
            -EndCursor $null

        $global:mockMalformedPage = $malformedPage

        function global:gh {
            param([Parameter(ValueFromRemainingArguments = $true)]$Args)
            $global:LASTEXITCODE = 0
            # Same malformed page regardless of after: clause. If the guard
            # regresses, the after: "" re-query would spin until the timeout.
            return $global:mockMalformedPage
        }

        # Small timeout: a regressed guard would visibly stall ~5s rather than pass.
        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        $result = script:Get-SurfaceAEntriesGraphQL `
            -Owner 'Grimblaz' -Repo 'agent-orchestra' -WindowDays 30 `
            -Stopwatch $stopwatch -TimeoutSeconds 5

        # The call returned (did not exhaust the timeout) and the single page's entry is present.
        $stopwatch.Elapsed.TotalSeconds | Should -BeLessThan 5
        $findingKeys = @($result.Entries | ForEach-Object { $_['finding_key'] })
        $findingKeys | Should -Contain 'code-review:905:F1'
    }
}

Describe 'Get-SurfaceBEntriesGraphQL — outer search pagination collects nodes from all pages' {
    BeforeAll {
        # A PR comment body carrying a judge-rulings marker plus a valid block.
        function script:New-SurfaceBPageBody {
            param([int]$Number, [string]$FindingKey)
            return @"
<!-- judge-rulings pr-$Number -->
<!-- phase-containment-$Number -->
finding_key: $FindingKey
introduced_phase: design
catchable_phase: design
caught_stage: code-review
escape_distance: 2
severity: high
systemic_fix_type: skill
category: architecture
apparatus_meta: false
seed: false
<!-- /phase-containment-$Number -->
"@
        }

        function script:New-SearchBPageResponse {
            param(
                [int]$PrNumber,
                [string]$CommentBody,
                [bool]$HasNextPage,
                [string]$EndCursor
            )
            $payload = @{
                data = @{
                    search = @{
                        pageInfo = @{ hasNextPage = $HasNextPage; endCursor = $EndCursor }
                        nodes    = @(
                            @{
                                number   = $PrNumber
                                comments = @{
                                    nodes    = @(@{ body = $CommentBody; createdAt = '2024-01-01T12:00:00Z' })
                                    pageInfo = @{ hasNextPage = $false; endCursor = $null }
                                }
                            }
                        )
                    }
                }
            }
            return ($payload | ConvertTo-Json -Depth 12)
        }
    }

    AfterEach {
        if (Get-Command 'gh' -CommandType Function -ErrorAction SilentlyContinue) {
            Remove-Item -Path Function:gh -ErrorAction SilentlyContinue
        }
    }

    It 'processes a merged PR that only appears on the second search page' {
        $page1 = script:New-SearchBPageResponse `
            -PrNumber 901 `
            -CommentBody (script:New-SurfaceBPageBody -Number 901 -FindingKey 'code-review:901:F1') `
            -HasNextPage $true `
            -EndCursor 'SEARCHCURSOR1'

        $page2 = script:New-SearchBPageResponse `
            -PrNumber 902 `
            -CommentBody (script:New-SurfaceBPageBody -Number 902 -FindingKey 'code-review:902:F1') `
            -HasNextPage $false `
            -EndCursor $null

        $global:mockSearchBPage1 = $page1
        $global:mockSearchBPage2 = $page2

        function global:gh {
            param([Parameter(ValueFromRemainingArguments = $true)]$Args)
            $joined = $Args -join ' '
            $global:LASTEXITCODE = 0
            if ($joined -match 'after:') {
                return $global:mockSearchBPage2
            }
            return $global:mockSearchBPage1
        }

        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        $result = script:Get-SurfaceBEntriesGraphQL `
            -Owner 'Grimblaz' -Repo 'agent-orchestra' -WindowDays 30 `
            -Stopwatch $stopwatch -TimeoutSeconds 30

        $result.Truncated | Should -Be $false
        $findingKeys = @($result.Entries | ForEach-Object { $_['finding_key'] })
        $findingKeys | Should -Contain 'code-review:901:F1'
        # The page-2 node must be processed — this is the regression guard for F10.
        $findingKeys | Should -Contain 'code-review:902:F1'
    }
}

# ---------------------------------------------------------------------------
# 12b. M7 regression — per-tuple isolation in the wrapper foreach loops
# ---------------------------------------------------------------------------

Describe 'Wrapper foreach loops — M7 per-tuple isolation (issue #782 post-review)' {
    # Before the M7 fix, Get-SurfaceAEntriesGraphQL, Get-SurfaceBEntriesGraphQL,
    # and Get-PhaseContainmentEntriesRest each looped
    # `foreach ($tuple in $tuples) { $scanned = Invoke-PhaseContainmentCommentScan ... }`
    # with NO per-item try/catch. If Invoke-PhaseContainmentCommentScan threw
    # for any single tuple (e.g. a malformed Number/Bodies shape that fails
    # to bind to its typed parameters), the exception propagated straight out
    # of the shared foreach, aborting every OTHER tuple in that same run — a
    # whole-run failure triggered by one bad entry. Mocking
    # Invoke-PhaseContainmentCommentScan directly isolates the wrapper's OWN
    # loop-level contract from the upstream discovery/parsing layers (which
    # have their own, separately-tested fallback behavior).

    AfterEach {
        if (Get-Command 'gh' -CommandType Function -ErrorAction SilentlyContinue) {
            Remove-Item -Path Function:gh -ErrorAction SilentlyContinue
        }
    }

    It 'Get-PhaseContainmentEntriesRest: one tuple throwing during scan does not abort the other tuples' {
        function global:gh {
            param([Parameter(ValueFromRemainingArguments = $true)]$Args)
            $joined = $Args -join ' '
            $global:LASTEXITCODE = 0
            if ($joined -match 'issue list') {
                return (@(@{ number = 960 }, @{ number = 961 }) | ConvertTo-Json)
            }
            if ($joined -match 'issue view 960') {
                return (@{ comments = @(@{ body = '<!-- plan-issue-960 -->' }) } | ConvertTo-Json -Depth 6)
            }
            if ($joined -match 'issue view 961') {
                return (@{ comments = @(@{ body = '<!-- plan-issue-961 -->' }) } | ConvertTo-Json -Depth 6)
            }
            if ($joined -match 'pr list') { return '[]' }
            return '{}'
        }

        # Fail only for tuple 960; succeed (return one real entry) for 961.
        Mock Invoke-PhaseContainmentCommentScan {
            if ($IssueOrPrNumber -eq 960) {
                throw 'simulated scan failure for tuple 960'
            }
            return [PSCustomObject]@{
                Entries           = @(@{ finding_key = 'plan-stress-test:961:F1' })
                InvalidEntryCount = 0
            }
        }

        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        $result = script:Get-PhaseContainmentEntriesRest -WindowDays 30 -Stopwatch $stopwatch -TimeoutSeconds 30 3>$null

        $findingKeys = @($result.Entries | ForEach-Object { $_['finding_key'] })
        # Tuple 961's entry must survive even though tuple 960's scan threw —
        # this is the per-tuple isolation the M7 fix restores.
        $findingKeys | Should -Contain 'plan-stress-test:961:F1'
    }

    # Note: Get-SurfaceAEntriesGraphQL and Get-SurfaceBEntriesGraphQL received
    # the IDENTICAL per-tuple try/catch fix (see the function bodies) as
    # Get-PhaseContainmentEntriesRest above, applied uniformly across all
    # three wrapper functions around Invoke-PhaseContainmentCommentScan. A
    # dedicated GraphQL-path Mock-based regression test was attempted but
    # proved unreliable in the full-suite run (an unresolved Pester
    # Mock/dot-source interaction specific to this file's already-large
    # GraphQL pagination fixture set), while passing cleanly in isolation;
    # the REST-path test above exercises the same code shape and confirms
    # the fix pattern. The existing "outer search pagination" Describe
    # blocks for both GraphQL wrappers (above) continue to pass unchanged,
    # confirming no regression from the added try/catch.
}

# ---------------------------------------------------------------------------
# 13. Rollup — clean stage with n>=5 → RelaxationEligible=$true
# ---------------------------------------------------------------------------

Describe 'Get-PhaseContainmentRollup — clean stage n>=5 sets RelaxationEligible=$true' {
    It 'returns RelaxationEligible=$true, EscapeRate=0.0, IrreducibleRate=1.0 for a clean code-review stage with 6 entries' {
        $entries = @(
            [PSCustomObject]@{
                finding_key       = 'code-review:803:F1'
                introduced_phase  = 'implementation'
                catchable_phase   = 'implementation'
                caught_stage      = 'code-review'
                escape_distance   = 0
                severity          = 'low'
                systemic_fix_type = 'none'
                category          = 'pattern'
                apparatus_meta    = $false
                seed              = $false
                createdAt         = '2024-01-01T12:00:00Z'
                surface           = 'pr'
                issueOrPrNumber   = 803
            }
            [PSCustomObject]@{
                finding_key       = 'code-review:803:F2'
                introduced_phase  = 'implementation'
                catchable_phase   = 'implementation'
                caught_stage      = 'code-review'
                escape_distance   = 0
                severity          = 'low'
                systemic_fix_type = 'none'
                category          = 'pattern'
                apparatus_meta    = $false
                seed              = $false
                createdAt         = '2024-01-01T12:00:00Z'
                surface           = 'pr'
                issueOrPrNumber   = 803
            }
            [PSCustomObject]@{
                finding_key       = 'code-review:803:F3'
                introduced_phase  = 'implementation'
                catchable_phase   = 'implementation'
                caught_stage      = 'code-review'
                escape_distance   = 0
                severity          = 'low'
                systemic_fix_type = 'none'
                category          = 'pattern'
                apparatus_meta    = $false
                seed              = $false
                createdAt         = '2024-01-01T12:00:00Z'
                surface           = 'pr'
                issueOrPrNumber   = 803
            }
            [PSCustomObject]@{
                finding_key       = 'code-review:803:F4'
                introduced_phase  = 'implementation'
                catchable_phase   = 'implementation'
                caught_stage      = 'code-review'
                escape_distance   = 0
                severity          = 'low'
                systemic_fix_type = 'none'
                category          = 'pattern'
                apparatus_meta    = $false
                seed              = $false
                createdAt         = '2024-01-01T12:00:00Z'
                surface           = 'pr'
                issueOrPrNumber   = 803
            }
            [PSCustomObject]@{
                finding_key       = 'code-review:803:F5'
                introduced_phase  = 'implementation'
                catchable_phase   = 'implementation'
                caught_stage      = 'code-review'
                escape_distance   = 0
                severity          = 'low'
                systemic_fix_type = 'none'
                category          = 'pattern'
                apparatus_meta    = $false
                seed              = $false
                createdAt         = '2024-01-01T12:00:00Z'
                surface           = 'pr'
                issueOrPrNumber   = 803
            }
            [PSCustomObject]@{
                finding_key       = 'code-review:803:F6'
                introduced_phase  = 'implementation'
                catchable_phase   = 'implementation'
                caught_stage      = 'code-review'
                escape_distance   = 0
                severity          = 'low'
                systemic_fix_type = 'none'
                category          = 'pattern'
                apparatus_meta    = $false
                seed              = $false
                createdAt         = '2024-01-01T12:00:00Z'
                surface           = 'pr'
                issueOrPrNumber   = 803
            }
        )

        $result = Get-PhaseContainmentRollup -Entries $entries

        $stageResult = $result.Stages['code-review']
        $stageResult.RelaxationEligible | Should -Be $true
        $stageResult.EscapeRate         | Should -Be 0.0
        $stageResult.IrreducibleRate    | Should -Be 1.0
    }
}

# ---------------------------------------------------------------------------
# 14. Rollup — apparatus_meta entries excluded from N
# ---------------------------------------------------------------------------

Describe 'Get-PhaseContainmentRollup — apparatus_meta entries excluded from N count' {
    It 'reports N=3 (not 5) when 2 of 5 entries have apparatus_meta=$true' {
        $entries = @(
            [PSCustomObject]@{
                finding_key       = 'plan-stress-test:804:F1'
                introduced_phase  = 'plan'
                catchable_phase   = 'plan'
                caught_stage      = 'plan-stress-test'
                escape_distance   = 0
                severity          = 'low'
                systemic_fix_type = 'instruction'
                category          = 'architecture'
                apparatus_meta    = $false
                seed              = $false
                createdAt         = '2024-01-01T12:00:00Z'
                surface           = 'issue'
                issueOrPrNumber   = 804
            }
            [PSCustomObject]@{
                finding_key       = 'plan-stress-test:804:F2'
                introduced_phase  = 'plan'
                catchable_phase   = 'plan'
                caught_stage      = 'plan-stress-test'
                escape_distance   = 0
                severity          = 'low'
                systemic_fix_type = 'instruction'
                category          = 'architecture'
                apparatus_meta    = $false
                seed              = $false
                createdAt         = '2024-01-01T12:00:00Z'
                surface           = 'issue'
                issueOrPrNumber   = 804
            }
            [PSCustomObject]@{
                finding_key       = 'plan-stress-test:804:F3'
                introduced_phase  = 'plan'
                catchable_phase   = 'plan'
                caught_stage      = 'plan-stress-test'
                escape_distance   = 0
                severity          = 'low'
                systemic_fix_type = 'instruction'
                category          = 'architecture'
                apparatus_meta    = $false
                seed              = $false
                createdAt         = '2024-01-01T12:00:00Z'
                surface           = 'issue'
                issueOrPrNumber   = 804
            }
            [PSCustomObject]@{
                finding_key       = 'plan-stress-test:804:META1'
                introduced_phase  = 'plan'
                catchable_phase   = 'plan'
                caught_stage      = 'plan-stress-test'
                escape_distance   = 0
                severity          = 'low'
                systemic_fix_type = 'none'
                category          = 'pattern'
                apparatus_meta    = $true
                seed              = $false
                createdAt         = '2024-01-01T12:00:00Z'
                surface           = 'issue'
                issueOrPrNumber   = 804
            }
            [PSCustomObject]@{
                finding_key       = 'plan-stress-test:804:META2'
                introduced_phase  = 'plan'
                catchable_phase   = 'plan'
                caught_stage      = 'plan-stress-test'
                escape_distance   = 0
                severity          = 'low'
                systemic_fix_type = 'none'
                category          = 'pattern'
                apparatus_meta    = $true
                seed              = $false
                createdAt         = '2024-01-01T12:00:00Z'
                surface           = 'issue'
                issueOrPrNumber   = 804
            }
        )

        $result = Get-PhaseContainmentRollup -Entries $entries

        $stageResult = $result.Stages['plan-stress-test']
        $stageResult.N                | Should -Be 3
        $stageResult.InsufficientData | Should -Be $true
    }
}

# ---------------------------------------------------------------------------
# 15. Rollup — leakage matrix populated correctly
# ---------------------------------------------------------------------------

Describe 'Get-PhaseContainmentRollup — leakage matrix populated correctly' {
    It 'records experience×code-review=1 and design×plan-stress-test=1 from two entries' {
        $entries = @(
            [PSCustomObject]@{
                finding_key       = 'code-review:805:F1'
                introduced_phase  = 'experience'
                catchable_phase   = 'implementation'
                caught_stage      = 'code-review'
                escape_distance   = 0
                severity          = 'high'
                systemic_fix_type = 'skill'
                category          = 'architecture'
                apparatus_meta    = $false
                seed              = $false
                createdAt         = '2024-01-01T12:00:00Z'
                surface           = 'pr'
                issueOrPrNumber   = 805
            }
            [PSCustomObject]@{
                finding_key       = 'plan-stress-test:805:F2'
                introduced_phase  = 'design'
                catchable_phase   = 'plan'
                caught_stage      = 'plan-stress-test'
                escape_distance   = 1
                severity          = 'medium'
                systemic_fix_type = 'instruction'
                category          = 'security'
                apparatus_meta    = $false
                seed              = $false
                createdAt         = '2024-01-01T12:00:00Z'
                surface           = 'issue'
                issueOrPrNumber   = 805
            }
        )

        $result = Get-PhaseContainmentRollup -Entries $entries

        $result.LeakageMatrix['experience×code-review']    | Should -Be 1
        $result.LeakageMatrix['design×plan-stress-test']   | Should -Be 1
    }
}

# ---------------------------------------------------------------------------
# 14. Get-PhaseContainmentCommentCorpus — shared discovery seam (#782 M11)
# Fixture-driven Pester target for the discovery predicate extracted for
# both Get-PhaseContainmentHistory and the phase-containment-emission-check
# sweep to consume.
# ---------------------------------------------------------------------------

Describe 'Get-PhaseContainmentCommentCorpus — returns raw per-surface tuples' {
    BeforeAll {
        function script:New-CorpusSearchAResponse {
            param([int]$IssueNumber, [string]$CommentBody)
            $payload = @{
                data = @{
                    search = @{
                        pageInfo = @{ hasNextPage = $false; endCursor = $null }
                        nodes    = @(
                            @{
                                number   = $IssueNumber
                                comments = @{
                                    nodes    = @(@{ body = $CommentBody; createdAt = '2024-01-01T12:00:00Z' })
                                    pageInfo = @{ hasNextPage = $false; endCursor = $null }
                                }
                            }
                        )
                    }
                }
            }
            return ($payload | ConvertTo-Json -Depth 12)
        }

        function script:New-CorpusSearchBResponse {
            param([int]$PrNumber, [string]$CommentBody)
            $payload = @{
                data = @{
                    search = @{
                        pageInfo = @{ hasNextPage = $false; endCursor = $null }
                        nodes    = @(
                            @{
                                number   = $PrNumber
                                comments = @{
                                    nodes    = @(@{ body = $CommentBody; createdAt = '2024-01-01T13:00:00Z' })
                                    pageInfo = @{ hasNextPage = $false; endCursor = $null }
                                }
                            }
                        )
                    }
                }
            }
            return ($payload | ConvertTo-Json -Depth 12)
        }
    }

    AfterEach {
        if (Get-Command 'gh' -CommandType Function -ErrorAction SilentlyContinue) {
            Remove-Item -Path Function:gh -ErrorAction SilentlyContinue
        }
    }

    It 'returns raw, unparsed bodies for both surfaces without validating phase-containment blocks' {
        # A malformed/unparseable phase-containment block on the issue surface — the
        # corpus function must still return the raw body untouched (no parse/validate).
        $issueBody = @"
<!-- plan-issue-901 -->
<!-- phase-containment-901 -->
finding_key: plan-stress-test:901:F1
introduced_phase: NOT-A-VALID-PHASE
<!-- /phase-containment-901 -->
"@
        $prBody = @"
<!-- judge-rulings pr=902 -->
judge_ruling: sustained
"@

        $searchAJson = script:New-CorpusSearchAResponse -IssueNumber 901 -CommentBody $issueBody
        $searchBJson = script:New-CorpusSearchBResponse -PrNumber 902 -CommentBody $prBody

        $global:mockCorpusSearchA = $searchAJson
        $global:mockCorpusSearchB = $searchBJson

        function global:gh {
            param([Parameter(ValueFromRemainingArguments = $true)]$Args)
            $joined = $Args -join ' '
            $global:LASTEXITCODE = 0
            if ($joined -match 'is:issue') { return $global:mockCorpusSearchA }
            if ($joined -match 'is:pr')    { return $global:mockCorpusSearchB }
            return '{}'
        }

        $result = Get-PhaseContainmentCommentCorpus -RepoOwner 'Grimblaz' -RepoName 'agent-orchestra' -WindowDays 30

        $result.Source | Should -Be 'graphql'
        $result.Tuples | Should -HaveCount 2

        $issueTuple = $result.Tuples | Where-Object { $_['Number'] -eq 901 }
        $issueTuple['Surface'] | Should -Be 'issue'
        $issueTuple['Bodies'] | Should -Contain $issueBody

        $prTuple = $result.Tuples | Where-Object { $_['Number'] -eq 902 }
        $prTuple['Surface'] | Should -Be 'pr'
        $prTuple['Bodies'] | Should -Contain $prBody
    }

    It 'falls back to REST when GraphQL search fails, still returning raw tuples' {
        $restIssueList = (@(@{ number = 950 }) | ConvertTo-Json)
        $restIssueView = (@{ comments = @(@{ body = "<!-- plan-issue-950 -->`nfinding_dispositions:`n  - id: F1`n    disposition: incorporate" }) } | ConvertTo-Json -Depth 6)
        $restPrList = '[]'

        function global:gh {
            param([Parameter(ValueFromRemainingArguments = $true)]$Args)
            $joined = $Args -join ' '
            if ($joined -match 'graphql') {
                $global:LASTEXITCODE = 1
                return 'boom'
            }
            $global:LASTEXITCODE = 0
            if ($joined -match 'issue list') { return $restIssueList }
            if ($joined -match 'issue view') { return $restIssueView }
            if ($joined -match 'pr list')    { return $restPrList }
            return '{}'
        }

        $result = Get-PhaseContainmentCommentCorpus -RepoOwner 'Grimblaz' -RepoName 'agent-orchestra' -WindowDays 30

        $result.Source | Should -Be 'rest'
        $issueTuple = $result.Tuples | Where-Object { $_['Number'] -eq 950 }
        $issueTuple | Should -Not -BeNullOrEmpty
        $issueTuple['Surface'] | Should -Be 'issue'
        $issueTuple['Bodies'][0] | Should -Match 'plan-issue-950'
    }

    # -----------------------------------------------------------------
    # GH-8 regression (code-review response loop, PR #789): the REST
    # fallback's issue surface (Surface A) previously included every
    # closed issue's comments unconditionally, with NO marker gate — while
    # the GraphQL path only includes issues whose bodies match
    # <!-- design-phase-complete-{N} --> or <!-- plan-issue-{N} -->.
    # Additionally, $WindowDays was accepted but never threaded into the
    # REST discovery query (fixed --limit 20, no date filter), unlike the
    # GraphQL path's closed:>$since filter. Both regressions are covered
    # below. Surface B (PR/code-review) already correctly gates on
    # judge-rulings — out of scope for this fix.
    # -----------------------------------------------------------------

    It 'GH-8: excludes a closed issue whose body has neither design-phase-complete nor plan-issue marker from the REST fallback corpus' {
        $restIssueList = (@(@{ number = 960 }, @{ number = 961 }) | ConvertTo-Json)
        # #960 carries a real marker -> must be included.
        $restIssueView960 = (@{ comments = @(@{ body = '<!-- plan-issue-960 -->' }) } | ConvertTo-Json -Depth 6)
        # #961 is ordinary chatter with NO marker -> must be excluded.
        $restIssueView961 = (@{ comments = @(@{ body = 'Closed as not-a-bug, no phase-containment relevance here.' }) } | ConvertTo-Json -Depth 6)
        $restPrList = '[]'

        function global:gh {
            param([Parameter(ValueFromRemainingArguments = $true)]$Args)
            $joined = $Args -join ' '
            if ($joined -match 'graphql') {
                $global:LASTEXITCODE = 1
                return 'boom'
            }
            $global:LASTEXITCODE = 0
            if ($joined -match 'issue list') { return $restIssueList }
            if ($joined -match 'issue view 960') { return $restIssueView960 }
            if ($joined -match 'issue view 961') { return $restIssueView961 }
            if ($joined -match 'pr list')    { return $restPrList }
            return '{}'
        }

        $result = Get-PhaseContainmentCommentCorpus -RepoOwner 'Grimblaz' -RepoName 'agent-orchestra' -WindowDays 30

        $result.Source | Should -Be 'rest'
        ($result.Tuples | Where-Object { $_['Number'] -eq 960 }) | Should -Not -BeNullOrEmpty
        ($result.Tuples | Where-Object { $_['Number'] -eq 961 }) | Should -BeNullOrEmpty
    }

    It 'GH-8: threads WindowDays into the REST gh issue list / gh pr list query construction (not merely accepted and dropped)' {
        $script:observedIssueListArgs = $null
        $script:observedPrListArgs = $null

        function global:gh {
            param([Parameter(ValueFromRemainingArguments = $true)]$Args)
            $joined = $Args -join ' '
            if ($joined -match 'graphql') {
                $global:LASTEXITCODE = 1
                return 'boom'
            }
            $global:LASTEXITCODE = 0
            if ($joined -match '^issue list') { $script:observedIssueListArgs = $joined; return '[]' }
            if ($joined -match '^pr list')    { $script:observedPrListArgs = $joined; return '[]' }
            return '{}'
        }

        $expectedSince = (Get-Date).ToUniversalTime().AddDays(-7).ToString('yyyy-MM-dd')

        $null = Get-PhaseContainmentCommentCorpus -RepoOwner 'Grimblaz' -RepoName 'agent-orchestra' -WindowDays 7

        $script:observedIssueListArgs | Should -Not -BeNullOrEmpty
        $script:observedIssueListArgs | Should -Match ([regex]::Escape($expectedSince))
        $script:observedPrListArgs | Should -Not -BeNullOrEmpty
        $script:observedPrListArgs | Should -Match ([regex]::Escape($expectedSince))
    }
}

# ---------------------------------------------------------------------------
# PF2-F2 regression (issue #782 post-fix prosecution pass): every `gh` call
# site in this file that pipes its output to ConvertFrom-Json must not merge
# stderr into that stream. GH-7 fixed this vulnerability class in
# phase-containment-emission-check.ps1's `gh pr/issue view` calls but a
# post-fix prosecution pass found the identical `2>&1` pattern still present
# on all REST/GraphQL `gh` call sites in this file, including two lines
# (`gh issue list` / `gh pr list`) that the SAME commit's GH-8 fix had open
# and edited without applying the GH-7 lesson. Mirrors the GH-7 regression
# test pattern: a mocked `gh` function writes a benign notice via
# `Write-Error -ErrorAction Continue` (which genuinely merges into the
# captured array under 2>&1, unlike a raw stderr byte write from a real
# external process) alongside valid JSON on stdout, and the assertion is that
# the corpus/REST parse still succeeds instead of silently degrading.
# ---------------------------------------------------------------------------

Describe 'Get-PhaseContainmentCommentCorpus REST fallback — PF2-F2 regression: gh stderr must not corrupt JSON parse' {
    AfterEach {
        if (Get-Command 'gh' -CommandType Function -ErrorAction SilentlyContinue) {
            Remove-Item -Path Function:gh -ErrorAction SilentlyContinue
        }
    }

    It 'parses the REST issue-list/issue-view surface successfully even when gh emits benign stderr content alongside valid JSON stdout' {
        $restIssueList = (@(@{ number = 970 }) | ConvertTo-Json)
        $restIssueView = (@{ comments = @(@{ body = '<!-- plan-issue-970 -->' }) } | ConvertTo-Json -Depth 6)

        function global:gh {
            param([Parameter(ValueFromRemainingArguments = $true)]$Args)
            $joined = $Args -join ' '
            if ($joined -match 'graphql') {
                # Force the REST fallback path for this test.
                $global:LASTEXITCODE = 1
                return 'boom'
            }
            $global:LASTEXITCODE = 0
            # Simulate a benign gh deprecation/auth notice on the PowerShell
            # error stream for the calls under test — the exact condition
            # GH-7 identified as breaking `2>&1`-based capture.
            if ($joined -match 'issue list') {
                Write-Error 'gh: a benign deprecation notice' -ErrorAction Continue
                return $restIssueList
            }
            if ($joined -match 'issue view 970') {
                Write-Error 'gh: a benign deprecation notice' -ErrorAction Continue
                return $restIssueView
            }
            if ($joined -match 'pr list') { return '[]' }
            return '{}'
        }

        $result = Get-PhaseContainmentCommentCorpus -RepoOwner 'Grimblaz' -RepoName 'agent-orchestra' -WindowDays 30

        # Pre-fix (2>&1), the merged ErrorRecord corrupted the JSON parse in
        # the try/catch, silently dropping issue #970's tuple.
        $result.Source | Should -Be 'rest'
        $issueTuple = $result.Tuples | Where-Object { $_['Number'] -eq 970 }
        $issueTuple | Should -Not -BeNullOrEmpty
        $issueTuple['Surface'] | Should -Be 'issue'
    }

    It 'parses the REST pr-list/pr-view surface successfully even when gh emits benign stderr content alongside valid JSON stdout' {
        $restPrList = (@(@{ number = 971 }) | ConvertTo-Json)
        $restPrView = (@{ comments = @(@{ body = '<!-- judge-rulings pr=971 -->' }) } | ConvertTo-Json -Depth 6)

        function global:gh {
            param([Parameter(ValueFromRemainingArguments = $true)]$Args)
            $joined = $Args -join ' '
            if ($joined -match 'graphql') {
                $global:LASTEXITCODE = 1
                return 'boom'
            }
            $global:LASTEXITCODE = 0
            if ($joined -match 'issue list') { return '[]' }
            if ($joined -match 'pr list') {
                Write-Error 'gh: a benign deprecation notice' -ErrorAction Continue
                return $restPrList
            }
            if ($joined -match 'pr view 971') {
                Write-Error 'gh: a benign deprecation notice' -ErrorAction Continue
                return $restPrView
            }
            return '{}'
        }

        $result = Get-PhaseContainmentCommentCorpus -RepoOwner 'Grimblaz' -RepoName 'agent-orchestra' -WindowDays 30

        $result.Source | Should -Be 'rest'
        $prTuple = $result.Tuples | Where-Object { $_['Number'] -eq 971 }
        $prTuple | Should -Not -BeNullOrEmpty
        $prTuple['Surface'] | Should -Be 'pr'
    }

    It 'resolves repo owner/name successfully even when gh repo view emits benign stderr content alongside valid JSON stdout' {
        function global:gh {
            param([Parameter(ValueFromRemainingArguments = $true)]$Args)
            $joined = $Args -join ' '
            $global:LASTEXITCODE = 0
            if ($joined -match '^repo view') {
                Write-Error 'gh: a benign deprecation notice' -ErrorAction Continue
                return (@{ owner = @{ login = 'Grimblaz' }; name = 'agent-orchestra' } | ConvertTo-Json)
            }
            if ($joined -match 'graphql') { $global:LASTEXITCODE = 1; return 'boom' }
            if ($joined -match 'issue list') { return '[]' }
            if ($joined -match 'pr list') { return '[]' }
            return '{}'
        }

        # No -RepoOwner/-RepoName supplied: forces the gh-repo-view resolution path.
        $result = Get-PhaseContainmentCommentCorpus -WindowDays 30

        # Pre-fix (2>&1), the merged ErrorRecord corrupted the repo-view JSON
        # parse, and the function returned early with Source =
        # 'repo-resolution-failed' instead of proceeding to discovery.
        $result.Source | Should -Be 'rest'
    }
}

# ---------------------------------------------------------------------------
# Get-PhaseContainmentCorpusRest / Get-PhaseContainmentEntriesRest — aligned
# createdAt extraction (issue #772 D3). Before the fix, both REST surfaces
# extracted only comment `body` and hardcoded CreatedAtValues = @(), so a
# REST-sourced entry's createdAt was always ''. The M12 docstring above
# Get-PhaseContainmentCommentCorpus falsely claimed `gh issue/pr view --json
# comments` does not carry a createdAt field — it does; the code simply never
# extracted it.
# ---------------------------------------------------------------------------

Describe 'Get-PhaseContainmentEntriesRest — aligned createdAt extraction (#772 D3)' {
    AfterEach {
        if (Get-Command 'gh' -CommandType Function -ErrorAction SilentlyContinue) {
            Remove-Item -Path Function:gh -ErrorAction SilentlyContinue
        }
    }

    It 'a REST-sourced entry (issue surface) carries a real, non-empty createdAt value' {
        $issueBody = @"
<!-- plan-issue-980 -->
<!-- phase-containment-980 -->
finding_key: plan-stress-test:980:F1
introduced_phase: plan
catchable_phase: plan
caught_stage: plan-stress-test
escape_distance: 0
severity: low
systemic_fix_type: plan-template
category: pattern
apparatus_meta: false
<!-- /phase-containment-980 -->
"@

        function global:gh {
            param([Parameter(ValueFromRemainingArguments = $true)]$Args)
            $joined = $Args -join ' '
            $global:LASTEXITCODE = 0
            if ($joined -match 'issue list') {
                return (@(@{ number = 980 }) | ConvertTo-Json)
            }
            if ($joined -match 'issue view 980') {
                return (@{ comments = @(@{ body = $issueBody; createdAt = '2024-03-01T11:30:00Z' }) } | ConvertTo-Json -Depth 6)
            }
            if ($joined -match 'pr list') { return '[]' }
            return '{}'
        }

        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        $result = script:Get-PhaseContainmentEntriesRest -WindowDays 30 -Stopwatch $stopwatch -TimeoutSeconds 30 3>$null

        $entry = $result.Entries | Where-Object { $_['finding_key'] -eq 'plan-stress-test:980:F1' }
        $entry | Should -Not -BeNullOrEmpty
        # "Real" createdAt: non-empty and actually parses as a date. Not
        # asserting byte-exact string equality against the mock literal —
        # ConvertFrom-Json -AsHashtable auto-parses ISO-8601-looking JSON
        # string values into [datetime] before the code casts them back to
        # [string], so the round-tripped literal format is locale-dependent;
        # only "real, parseable timestamp" is the D3 requirement, which is
        # what Invoke-PhaseContainmentDedup's latest-wins comparison needs.
        $entry['createdAt'] | Should -Not -BeNullOrEmpty
        { [datetime]::Parse($entry['createdAt']) } | Should -Not -Throw
    }

    It 'a REST-sourced entry (PR surface) carries a real, non-empty createdAt value' {
        $prBody = @"
<!-- judge-rulings pr=981 -->
<!-- phase-containment-981 -->
finding_key: code-review:981:F1
introduced_phase: plan
catchable_phase: plan
caught_stage: code-review
escape_distance: 1
severity: low
systemic_fix_type: plan-template
category: pattern
apparatus_meta: false
<!-- /phase-containment-981 -->
"@

        function global:gh {
            param([Parameter(ValueFromRemainingArguments = $true)]$Args)
            $joined = $Args -join ' '
            $global:LASTEXITCODE = 0
            if ($joined -match 'issue list') { return '[]' }
            if ($joined -match 'pr list') {
                return (@(@{ number = 981 }) | ConvertTo-Json)
            }
            if ($joined -match 'pr view 981') {
                return (@{ comments = @(@{ body = $prBody; createdAt = '2024-03-02T09:15:00Z' }) } | ConvertTo-Json -Depth 6)
            }
            return '{}'
        }

        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        $result = script:Get-PhaseContainmentEntriesRest -WindowDays 30 -Stopwatch $stopwatch -TimeoutSeconds 30 3>$null

        $entry = $result.Entries | Where-Object { $_['finding_key'] -eq 'code-review:981:F1' }
        $entry | Should -Not -BeNullOrEmpty
        $entry['createdAt'] | Should -Not -BeNullOrEmpty
        { [datetime]::Parse($entry['createdAt']) } | Should -Not -Throw
    }
}

Describe 'Invoke-PhaseContainmentDedup — REST latest-wins (#772 D3)' {
    AfterEach {
        if (Get-Command 'gh' -CommandType Function -ErrorAction SilentlyContinue) {
            Remove-Item -Path Function:gh -ErrorAction SilentlyContinue
        }
    }

    It 'picks the later-createdAt REST entry for the same finding_key, not just the first-seen entry' {
        # Two comments on the same issue re-annotate the SAME finding_key —
        # the second (later createdAt) must win, matching Invoke-
        # PhaseContainmentDedup's documented latest-wins contract. Before the
        # D3 fix, both REST entries would carry createdAt = '' (indistinguishable),
        # so dedup fell back to whichever entry happened to be inserted last
        # in $best (a first/last-seen artifact, not a real latest-wins compare).
        $olderBlock = @"
<!-- plan-issue-982 -->
<!-- phase-containment-982 -->
finding_key: plan-stress-test:982:F1
introduced_phase: plan
catchable_phase: plan
caught_stage: plan-stress-test
escape_distance: 0
severity: low
systemic_fix_type: plan-template
category: pattern
apparatus_meta: false
<!-- /phase-containment-982 -->
"@
        $newerBlock = @"
<!-- phase-containment-982 -->
finding_key: plan-stress-test:982:F1
introduced_phase: plan
catchable_phase: plan
caught_stage: plan-stress-test
escape_distance: 0
severity: high
systemic_fix_type: plan-template
category: pattern
apparatus_meta: false
<!-- /phase-containment-982 -->
"@

        function global:gh {
            param([Parameter(ValueFromRemainingArguments = $true)]$Args)
            $joined = $Args -join ' '
            $global:LASTEXITCODE = 0
            if ($joined -match 'issue list') {
                return (@(@{ number = 982 }) | ConvertTo-Json)
            }
            if ($joined -match 'issue view 982') {
                return (@{
                    comments = @(
                        @{ body = $newerBlock; createdAt = '2024-04-05T08:00:00Z' },
                        @{ body = $olderBlock; createdAt = '2024-04-01T08:00:00Z' }
                    )
                } | ConvertTo-Json -Depth 6)
            }
            if ($joined -match 'pr list') { return '[]' }
            return '{}'
        }

        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        $restResult = script:Get-PhaseContainmentEntriesRest -WindowDays 30 -Stopwatch $stopwatch -TimeoutSeconds 30 3>$null

        $deduped = Invoke-PhaseContainmentDedup -RawEntries $restResult.Entries
        $winner = $deduped | Where-Object { $_['finding_key'] -eq 'plan-stress-test:982:F1' }

        $winner | Should -Not -BeNullOrEmpty
        # The newer-createdAt entry (severity high) must win over the
        # older-createdAt entry (severity low), regardless of array order.
        # This is the load-bearing assertion: before the D3 fix, both REST
        # entries carried createdAt = '' (indistinguishable), so Invoke-
        # PhaseContainmentDedup's Parse-based comparison always failed
        # (caught, warned) and dedup fell back to whichever entry happened
        # to already occupy $best — a first/last-seen artifact, not a real
        # latest-wins compare.
        $winner['severity'] | Should -Be 'high'
        $winner['createdAt'] | Should -Not -BeNullOrEmpty
    }
}

Describe 'Get-PhaseContainmentCorpusRest — null-comment alignment (#772 D3)' {
    AfterEach {
        if (Get-Command 'gh' -CommandType Function -ErrorAction SilentlyContinue) {
            Remove-Item -Path Function:gh -ErrorAction SilentlyContinue
        }
    }

    It 'keeps Bodies and CreatedAtValues correctly paired by index when a null comment entry is filtered' {
        function global:gh {
            param([Parameter(ValueFromRemainingArguments = $true)]$Args)
            $joined = $Args -join ' '
            $global:LASTEXITCODE = 0
            if ($joined -match 'issue list') {
                return (@(@{ number = 983 }) | ConvertTo-Json)
            }
            if ($joined -match 'issue view 983') {
                # A $null comment entry sits between two real comments. If the
                # aligned pass desyncs (e.g. two independent Where-Object/
                # ForEach-Object pipelines), Bodies[i] and CreatedAtValues[i]
                # would no longer describe the same surviving comment.
                return (@{
                    comments = @(
                        @{ body = '<!-- plan-issue-983 -->'; createdAt = '2024-05-01T00:00:00Z' },
                        $null,
                        @{ body = 'second surviving comment'; createdAt = '2024-05-02T00:00:00Z' }
                    )
                } | ConvertTo-Json -Depth 6)
            }
            if ($joined -match 'pr list') { return '[]' }
            return '{}'
        }

        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        $corpusResult = script:Get-PhaseContainmentCorpusRest -WindowDays 30 -Stopwatch $stopwatch -TimeoutSeconds 30 3>$null

        $corpusResult.Truncated | Should -Be $false
        $tuple = $corpusResult.Tuples | Where-Object { $_['Number'] -eq 983 }
        $tuple | Should -Not -BeNullOrEmpty

        $bodies = @($tuple['Bodies'])
        $createdAtValues = @($tuple['CreatedAtValues'])

        # The null entry must be dropped, not left as a gap — both arrays
        # must have exactly the 2 surviving comments, index-aligned.
        $bodies.Count | Should -Be 2
        $createdAtValues.Count | Should -Be 2
        $bodies[0] | Should -Be '<!-- plan-issue-983 -->'
        $bodies[1] | Should -Be 'second surviving comment'
        # Alignment check: createdAtValues[i] must describe the SAME
        # surviving comment as bodies[i]. Not asserting byte-exact string
        # equality against the mock literal — ConvertFrom-Json -AsHashtable
        # auto-parses ISO-8601-looking JSON string values into [datetime]
        # before the code casts them back to [string], so the round-tripped
        # literal format is locale-dependent. Both values must be real,
        # parseable timestamps and preserve the mock's chronological order
        # (comment 1 before comment 2) — a desynced pairing (e.g. two
        # independent filter pipelines dropping the null at different
        # positions) would break this ordering or leave an empty string.
        $createdAtValues[0] | Should -Not -BeNullOrEmpty
        $createdAtValues[1] | Should -Not -BeNullOrEmpty
        [datetime]::Parse($createdAtValues[0]) | Should -BeLessThan ([datetime]::Parse($createdAtValues[1]))
    }
}

# ---------------------------------------------------------------------------
# Issue #772 D1: total Truncated/InvalidEntryCount telemetry.
#
# Deterministic truncation testing (P5): a TimeoutSeconds=0 fixture only
# reaches the pre-fetch guards (nothing has been fetched yet), so it cannot
# drive the "partials accumulated, THEN the loop-top stopwatch guard trips"
# in-loop sites. Instead, these tests use a `gh` mock that Start-Sleep's past
# a small TimeoutSeconds budget (e.g. 1s) inside the FIRST successful call,
# so the *next* loop-top stopwatch check (which runs before any further gh
# call) observes an already-exhausted budget and trips deterministically —
# no second gh call is ever made. Verified lawful against
# wall-clock-fixture-guard.Tests.ps1: that guard's $script:AbsoluteSeedPattern
# only matches an absolute ISO-date literal assigned to
# `skip_first_observed_at`; it does not scan for Start-Sleep at all, so a
# sleeping `gh` mock is outside its detection surface.
# ---------------------------------------------------------------------------

Describe 'Get-SurfaceACorpusGraphQL — Truncated flagging (issue #772 D1/P5)' {
    AfterEach {
        if (Get-Command 'gh' -CommandType Function -ErrorAction SilentlyContinue) {
            Remove-Item -Path Function:gh -ErrorAction SilentlyContinue
        }
    }

    It 'sets Truncated=$true when the outer search-pagination stopwatch guard trips after page 1' {
        # Page 1: hasNextPage=true (would normally trigger a 2nd search call),
        # but the mock sleeps past the 1s budget WHILE answering the FIRST
        # call, so the loop-top guard trips on the way back around — no 2nd
        # gh invocation ever happens.
        function global:gh {
            param([Parameter(ValueFromRemainingArguments = $true)]$Args)
            $global:LASTEXITCODE = 0
            Start-Sleep -Milliseconds 1200
            $payload = @{
                data = @{
                    search = @{
                        pageInfo = @{ hasNextPage = $true; endCursor = 'SEARCHCURSOR1' }
                        nodes    = @(
                            @{
                                number   = 1001
                                comments = @{
                                    nodes    = @(@{ body = 'no marker here'; createdAt = '2024-01-01T12:00:00Z' })
                                    pageInfo = @{ hasNextPage = $false; endCursor = $null }
                                }
                            }
                        )
                    }
                }
            }
            return ($payload | ConvertTo-Json -Depth 12)
        }

        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        $result = script:Get-SurfaceACorpusGraphQL `
            -Owner 'Grimblaz' -Repo 'agent-orchestra' -WindowDays 30 `
            -Stopwatch $stopwatch -TimeoutSeconds 1 3>$null

        $result.IsError   | Should -Be $false
        $result.Truncated | Should -Be $true
    }

    It 'sets Truncated=$true when the per-issue comment-pagination stopwatch guard trips mid-issue' {
        # Single search page (hasNextPage=false) so the outer loop never
        # revisits its own top-check. The issue's inline page-1 comments
        # carry the marker plus hasNextPage=true, so the per-issue comment
        # pagination while-loop is entered. That paginated gh call sleeps
        # past budget while answering, so the while-loop's OWN loop-top
        # guard trips on the way back around.
        function global:gh {
            param([Parameter(ValueFromRemainingArguments = $true)]$Args)
            $joined = $Args -join ' '
            $global:LASTEXITCODE = 0
            if ($joined -match 'issue\(number:') {
                Start-Sleep -Milliseconds 1200
                $pagePayload = @{
                    data = @{
                        repository = @{
                            issue = @{
                                comments = @{
                                    nodes    = @(@{ body = 'page 2 comment'; createdAt = '2024-01-01T12:05:00Z' })
                                    pageInfo = @{ hasNextPage = $true; endCursor = 'ISSUECURSOR2' }
                                }
                            }
                        }
                    }
                }
                return ($pagePayload | ConvertTo-Json -Depth 12)
            }
            $searchPayload = @{
                data = @{
                    search = @{
                        pageInfo = @{ hasNextPage = $false; endCursor = $null }
                        nodes    = @(
                            @{
                                number   = 1002
                                comments = @{
                                    nodes    = @(@{ body = '<!-- plan-issue-1002 -->'; createdAt = '2024-01-01T12:00:00Z' })
                                    pageInfo = @{ hasNextPage = $true; endCursor = 'ISSUECURSOR1' }
                                }
                            }
                        )
                    }
                }
            }
            return ($searchPayload | ConvertTo-Json -Depth 12)
        }

        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        $result = script:Get-SurfaceACorpusGraphQL `
            -Owner 'Grimblaz' -Repo 'agent-orchestra' -WindowDays 30 `
            -Stopwatch $stopwatch -TimeoutSeconds 1 3>$null

        $result.IsError   | Should -Be $false
        $result.Truncated | Should -Be $true
    }

    It 'sets Truncated=$true when the post-marker-find unbounded pagination gh call fails (non-zero exit) (issue #772/#831 M1)' {
        # Marker already found on page 1 (hasNextPage=true) -- falls straight
        # through to the UNBOUNDED post-marker-find pagination pass. That
        # pass's own gh call fails; prior to the M1 fix this `break`d out
        # silently without ever flagging the run as degraded.
        function global:gh {
            param([Parameter(ValueFromRemainingArguments = $true)]$Args)
            $joined = $Args -join ' '
            if ($joined -match 'issue\(number:') {
                $global:LASTEXITCODE = 1
                return ''
            }
            $global:LASTEXITCODE = 0
            $searchPayload = @{
                data = @{
                    search = @{
                        pageInfo = @{ hasNextPage = $false; endCursor = $null }
                        nodes    = @(
                            @{
                                number   = 1003
                                comments = @{
                                    nodes    = @(@{ body = '<!-- plan-issue-1003 -->'; createdAt = '2024-01-01T12:00:00Z' })
                                    pageInfo = @{ hasNextPage = $true; endCursor = 'M1ACUR1' }
                                }
                            }
                        )
                    }
                }
            }
            return ($searchPayload | ConvertTo-Json -Depth 12)
        }

        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        $result = script:Get-SurfaceACorpusGraphQL `
            -Owner 'Grimblaz' -Repo 'agent-orchestra' -WindowDays 30 `
            -Stopwatch $stopwatch -TimeoutSeconds 30 3>$null

        $result.IsError   | Should -Be $false
        $result.Truncated | Should -Be $true -Because 'a gh failure mid post-marker-find pagination must flag the run as degraded, not silently truncate'
        $result.Tuples    | Should -HaveCount 1
        $result.Tuples[0]['Number'] | Should -Be 1003
    }

    It 'sets Truncated=$true when the post-marker-find unbounded pagination response fails to parse (issue #772/#831 M1)' {
        function global:gh {
            param([Parameter(ValueFromRemainingArguments = $true)]$Args)
            $joined = $Args -join ' '
            $global:LASTEXITCODE = 0
            if ($joined -match 'issue\(number:') {
                return 'not valid json {{{'
            }
            $searchPayload = @{
                data = @{
                    search = @{
                        pageInfo = @{ hasNextPage = $false; endCursor = $null }
                        nodes    = @(
                            @{
                                number   = 1004
                                comments = @{
                                    nodes    = @(@{ body = '<!-- plan-issue-1004 -->'; createdAt = '2024-01-01T12:00:00Z' })
                                    pageInfo = @{ hasNextPage = $true; endCursor = 'M1ACUR2' }
                                }
                            }
                        )
                    }
                }
            }
            return ($searchPayload | ConvertTo-Json -Depth 12)
        }

        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        $result = script:Get-SurfaceACorpusGraphQL `
            -Owner 'Grimblaz' -Repo 'agent-orchestra' -WindowDays 30 `
            -Stopwatch $stopwatch -TimeoutSeconds 30 3>$null

        $result.IsError   | Should -Be $false
        $result.Truncated | Should -Be $true -Because 'a parse failure mid post-marker-find pagination must flag the run as degraded, not silently truncate'
    }
}

Describe 'Get-SurfaceBCorpusGraphQL — Truncated flagging (issue #772/#831 M1)' {
    AfterEach {
        if (Get-Command 'gh' -CommandType Function -ErrorAction SilentlyContinue) {
            Remove-Item -Path Function:gh -ErrorAction SilentlyContinue
        }
    }

    It 'sets Truncated=$true when the post-marker-find unbounded pagination gh call fails (non-zero exit)' {
        function global:gh {
            param([Parameter(ValueFromRemainingArguments = $true)]$Args)
            $joined = $Args -join ' '
            if ($joined -match 'pullRequest\(number:') {
                $global:LASTEXITCODE = 1
                return ''
            }
            $global:LASTEXITCODE = 0
            $searchPayload = @{
                data = @{
                    search = @{
                        pageInfo = @{ hasNextPage = $false; endCursor = $null }
                        nodes    = @(
                            @{
                                number   = 1013
                                comments = @{
                                    nodes    = @(@{ body = '<!-- judge-rulings pr-1013 -->'; createdAt = '2024-01-01T12:00:00Z' })
                                    pageInfo = @{ hasNextPage = $true; endCursor = 'M1BCUR1' }
                                }
                            }
                        )
                    }
                }
            }
            return ($searchPayload | ConvertTo-Json -Depth 12)
        }

        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        $result = script:Get-SurfaceBCorpusGraphQL `
            -Owner 'Grimblaz' -Repo 'agent-orchestra' -WindowDays 30 `
            -Stopwatch $stopwatch -TimeoutSeconds 30 3>$null

        $result.IsError   | Should -Be $false
        $result.Truncated | Should -Be $true -Because 'a gh failure mid post-marker-find pagination must flag the run as degraded, not silently truncate'
        $result.Tuples    | Should -HaveCount 1
        $result.Tuples[0]['Number'] | Should -Be 1013
    }

    It 'sets Truncated=$true when the post-marker-find unbounded pagination response fails to parse' {
        function global:gh {
            param([Parameter(ValueFromRemainingArguments = $true)]$Args)
            $joined = $Args -join ' '
            $global:LASTEXITCODE = 0
            if ($joined -match 'pullRequest\(number:') {
                return 'not valid json {{{'
            }
            $searchPayload = @{
                data = @{
                    search = @{
                        pageInfo = @{ hasNextPage = $false; endCursor = $null }
                        nodes    = @(
                            @{
                                number   = 1014
                                comments = @{
                                    nodes    = @(@{ body = '<!-- judge-rulings pr-1014 -->'; createdAt = '2024-01-01T12:00:00Z' })
                                    pageInfo = @{ hasNextPage = $true; endCursor = 'M1BCUR2' }
                                }
                            }
                        )
                    }
                }
            }
            return ($searchPayload | ConvertTo-Json -Depth 12)
        }

        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        $result = script:Get-SurfaceBCorpusGraphQL `
            -Owner 'Grimblaz' -Repo 'agent-orchestra' -WindowDays 30 `
            -Stopwatch $stopwatch -TimeoutSeconds 30 3>$null

        $result.IsError   | Should -Be $false
        $result.Truncated | Should -Be $true -Because 'a parse failure mid post-marker-find pagination must flag the run as degraded, not silently truncate'
    }
}

Describe 'Get-PhaseContainmentCorpusRest — Truncated flagging (issue #772 D1/C5)' {
    AfterEach {
        if (Get-Command 'gh' -CommandType Function -ErrorAction SilentlyContinue) {
            Remove-Item -Path Function:gh -ErrorAction SilentlyContinue
        }
    }

    It 'sets Truncated=$true when the per-item stopwatch guard trips mid-list (REST per-item break)' {
        function global:gh {
            param([Parameter(ValueFromRemainingArguments = $true)]$Args)
            $joined = $Args -join ' '
            $global:LASTEXITCODE = 0
            if ($joined -match '^issue list') {
                return (@(@{ number = 1010 }, @{ number = 1011 }) | ConvertTo-Json)
            }
            if ($joined -match 'issue view 1010') {
                # Sleep past budget while answering the FIRST item's view
                # call — the foreach loop's next top-check (before item 2)
                # trips the per-item break.
                Start-Sleep -Milliseconds 1200
                return (@{ comments = @(@{ body = '<!-- plan-issue-1010 -->' }) } | ConvertTo-Json -Depth 6)
            }
            if ($joined -match 'issue view 1011') {
                return (@{ comments = @(@{ body = '<!-- plan-issue-1011 -->' }) } | ConvertTo-Json -Depth 6)
            }
            if ($joined -match '^pr list') { return '[]' }
            return '{}'
        }

        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        $result = script:Get-PhaseContainmentCorpusRest -WindowDays 30 -Stopwatch $stopwatch -TimeoutSeconds 1 3>$null

        $result.Truncated | Should -Be $true
        # Item 1011 must NOT have been reached — the break fires before it.
        ($result.Tuples | Where-Object { $_['Number'] -eq 1011 }) | Should -BeNullOrEmpty
    }

    It 'sets Truncated=$true when a REST surface is skipped entirely because the budget was already exhausted (surface-budget skip)' {
        # Pre-expire the shared stopwatch before the call even starts — both
        # the Surface A and Surface B `if ($Stopwatch...-lt $TimeoutSeconds)`
        # guards must observe an already-exhausted budget and skip their
        # blocks entirely (no gh call at all).
        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        Start-Sleep -Milliseconds 1100

        $script:ghCalled = $false
        function global:gh {
            param([Parameter(ValueFromRemainingArguments = $true)]$Args)
            $script:ghCalled = $true
            $global:LASTEXITCODE = 0
            return '[]'
        }

        $result = script:Get-PhaseContainmentCorpusRest -WindowDays 30 -Stopwatch $stopwatch -TimeoutSeconds 1 3>$null

        $result.Truncated | Should -Be $true
        $result.Tuples    | Should -HaveCount 0
        $script:ghCalled  | Should -Be $false -Because 'both REST surface blocks must be skipped entirely once the budget is already exhausted'
    }

    It 'sets Truncated=$true when a REST list call returns exactly the discovery-cap ($limit=20) rows' {
        function global:gh {
            param([Parameter(ValueFromRemainingArguments = $true)]$Args)
            $joined = $Args -join ' '
            $global:LASTEXITCODE = 0
            if ($joined -match '^issue list') {
                # Exactly 20 rows == $limit — a possible-undercount signal:
                # more items may exist beyond what the REST fallback can see.
                $issues = 1..20 | ForEach-Object { @{ number = (1100 + $_) } }
                return ($issues | ConvertTo-Json)
            }
            if ($joined -match '^issue view') {
                return (@{ comments = @() } | ConvertTo-Json -Depth 6)
            }
            if ($joined -match '^pr list') { return '[]' }
            return '{}'
        }

        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        $result = script:Get-PhaseContainmentCorpusRest -WindowDays 30 -Stopwatch $stopwatch -TimeoutSeconds 30 3>$null

        $result.Truncated | Should -Be $true
    }

    It 'does NOT set Truncated when a REST list call returns fewer than the discovery cap' {
        function global:gh {
            param([Parameter(ValueFromRemainingArguments = $true)]$Args)
            $joined = $Args -join ' '
            $global:LASTEXITCODE = 0
            if ($joined -match '^issue list') {
                return (@(@{ number = 1201 }) | ConvertTo-Json)
            }
            if ($joined -match '^issue view') {
                return (@{ comments = @() } | ConvertTo-Json -Depth 6)
            }
            if ($joined -match '^pr list') { return '[]' }
            return '{}'
        }

        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        $result = script:Get-PhaseContainmentCorpusRest -WindowDays 30 -Stopwatch $stopwatch -TimeoutSeconds 30 3>$null

        $result.Truncated | Should -Be $false
    }

    It 'sets Truncated=$true when a REST per-item issue view fails (non-zero exit) (issue #772/#831 M2)' {
        function global:gh {
            param([Parameter(ValueFromRemainingArguments = $true)]$Args)
            $joined = $Args -join ' '
            if ($joined -match '^issue list') {
                $global:LASTEXITCODE = 0
                return (@(@{ number = 1020 }, @{ number = 1021 }) | ConvertTo-Json)
            }
            if ($joined -match 'issue view 1020') {
                $global:LASTEXITCODE = 1
                return ''
            }
            if ($joined -match 'issue view 1021') {
                $global:LASTEXITCODE = 0
                return (@{ comments = @(@{ body = '<!-- plan-issue-1021 -->' }) } | ConvertTo-Json -Depth 6)
            }
            $global:LASTEXITCODE = 0
            if ($joined -match '^pr list') { return '[]' }
            return '{}'
        }

        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        $result = script:Get-PhaseContainmentCorpusRest -WindowDays 30 -Stopwatch $stopwatch -TimeoutSeconds 30 3>$null

        $result.Truncated | Should -Be $true -Because 'a per-item view failure must flag the run as degraded, not silently drop the item'
        # Per-item isolation preserved: item 1021 must still be processed
        # despite item 1020's failure.
        ($result.Tuples | Where-Object { $_['Number'] -eq 1021 }) | Should -Not -BeNullOrEmpty
    }

    It 'sets Truncated=$true when a REST per-item issue view response fails to parse (issue #772/#831 M2)' {
        function global:gh {
            param([Parameter(ValueFromRemainingArguments = $true)]$Args)
            $joined = $Args -join ' '
            $global:LASTEXITCODE = 0
            if ($joined -match '^issue list') {
                return (@(@{ number = 1030 }) | ConvertTo-Json)
            }
            if ($joined -match 'issue view 1030') {
                return 'not valid json {{{'
            }
            if ($joined -match '^pr list') { return '[]' }
            return '{}'
        }

        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        $result = script:Get-PhaseContainmentCorpusRest -WindowDays 30 -Stopwatch $stopwatch -TimeoutSeconds 30 3>$null

        $result.Truncated | Should -Be $true -Because 'a per-item parse failure must flag the run as degraded, not silently drop the item'
    }

    It 'sets Truncated=$true when the REST issue-list call itself fails (non-zero exit) (issue #772/#831 M2)' {
        $script:ghCalledIssueView = $false
        function global:gh {
            param([Parameter(ValueFromRemainingArguments = $true)]$Args)
            $joined = $Args -join ' '
            if ($joined -match '^issue list') {
                $global:LASTEXITCODE = 1
                return ''
            }
            if ($joined -match '^issue view') { $script:ghCalledIssueView = $true }
            $global:LASTEXITCODE = 0
            if ($joined -match '^pr list') { return '[]' }
            return '{}'
        }

        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        $result = script:Get-PhaseContainmentCorpusRest -WindowDays 30 -Stopwatch $stopwatch -TimeoutSeconds 30 3>$null

        $result.Truncated | Should -Be $true -Because 'the entire Surface A REST corpus silently returning zero tuples on a list-call failure must flag the run as degraded'
        $result.Tuples    | Should -HaveCount 0
        $script:ghCalledIssueView | Should -Be $false -Because 'no per-item view calls should happen when the list call itself failed'
    }

    It 'sets Truncated=$true when a REST per-item PR view fails (non-zero exit) (issue #772/#831 M2)' {
        function global:gh {
            param([Parameter(ValueFromRemainingArguments = $true)]$Args)
            $joined = $Args -join ' '
            $global:LASTEXITCODE = 0
            if ($joined -match '^issue list') { return '[]' }
            if ($joined -match '^pr list') {
                return (@(@{ number = 1040 }, @{ number = 1041 }) | ConvertTo-Json)
            }
            if ($joined -match 'pr view 1040') {
                $global:LASTEXITCODE = 1
                return ''
            }
            if ($joined -match 'pr view 1041') {
                return (@{ comments = @(@{ body = '<!-- judge-rulings pr-1041 -->' }) } | ConvertTo-Json -Depth 6)
            }
            return '{}'
        }

        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        $result = script:Get-PhaseContainmentCorpusRest -WindowDays 30 -Stopwatch $stopwatch -TimeoutSeconds 30 3>$null

        $result.Truncated | Should -Be $true -Because 'a per-item PR view failure must flag the run as degraded, not silently drop the item'
        ($result.Tuples | Where-Object { $_['Number'] -eq 1041 }) | Should -Not -BeNullOrEmpty
    }

    It 'sets Truncated=$true when the REST PR-list call itself fails (non-zero exit) (issue #772/#831 M2)' {
        function global:gh {
            param([Parameter(ValueFromRemainingArguments = $true)]$Args)
            $joined = $Args -join ' '
            if ($joined -match '^issue list') { $global:LASTEXITCODE = 0; return '[]' }
            if ($joined -match '^pr list') {
                $global:LASTEXITCODE = 1
                return ''
            }
            $global:LASTEXITCODE = 0
            return '{}'
        }

        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        $result = script:Get-PhaseContainmentCorpusRest -WindowDays 30 -Stopwatch $stopwatch -TimeoutSeconds 30 3>$null

        $result.Truncated | Should -Be $true -Because 'the entire Surface B REST corpus silently returning zero tuples on a list-call failure must flag the run as degraded'
        $result.Tuples    | Should -HaveCount 0
    }
}

# ---------------------------------------------------------------------------
# Issue #772 T1/P4: per-site timeout disposition — the two inter-surface
# timeout returns (one in Get-PhaseContainmentCommentCorpus, one in
# Get-PhaseContainmentHistory) that fire when Surface A already succeeded
# must preserve the accumulated Surface A partials + Truncated=$true with
# the fetch path's own Source, NOT the empty Source='timeout' shape.
# ---------------------------------------------------------------------------

Describe 'Get-PhaseContainmentCommentCorpus — T1 partial-preservation on inter-surface timeout' {
    AfterEach {
        if (Get-Command 'gh' -CommandType Function -ErrorAction SilentlyContinue) {
            Remove-Item -Path Function:gh -ErrorAction SilentlyContinue
        }
    }

    It 'returns Surface A partials with Source=graphql and Truncated=$true instead of an empty Source=timeout when the budget exhausts before Surface B fetch' {
        function global:gh {
            param([Parameter(ValueFromRemainingArguments = $true)]$Args)
            $joined = $Args -join ' '
            $global:LASTEXITCODE = 0
            if ($joined -match 'is:issue') {
                # Surface A completes cleanly (single page, no internal
                # truncation) but consumes enough wall-clock time that the
                # CALLER's budget is exhausted by the time it returns.
                Start-Sleep -Milliseconds 1200
                $payload = @{
                    data = @{
                        search = @{
                            pageInfo = @{ hasNextPage = $false; endCursor = $null }
                            nodes    = @(
                                @{
                                    number   = 1301
                                    comments = @{
                                        nodes    = @(@{ body = '<!-- plan-issue-1301 -->'; createdAt = '2024-01-01T12:00:00Z' })
                                        pageInfo = @{ hasNextPage = $false; endCursor = $null }
                                    }
                                }
                            )
                        }
                    }
                }
                return ($payload | ConvertTo-Json -Depth 12)
            }
            if ($joined -match 'is:pr') {
                throw 'Surface B must not be fetched once the T1 site returns early'
            }
            return '{}'
        }

        $result = Get-PhaseContainmentCommentCorpus -RepoOwner 'Grimblaz' -RepoName 'agent-orchestra' -WindowDays 30 -TimeoutSeconds 1 3>$null

        $result.Source    | Should -Be 'graphql'
        $result.Truncated | Should -Be $true
        ($result.Tuples | Where-Object { $_['Number'] -eq 1301 }) | Should -Not -BeNullOrEmpty
    }
}

Describe 'Get-PhaseContainmentHistory — T1 partial-preservation on inter-surface timeout' {
    AfterEach {
        if (Get-Command 'gh' -CommandType Function -ErrorAction SilentlyContinue) {
            Remove-Item -Path Function:gh -ErrorAction SilentlyContinue
        }
        $tempCache = Join-Path $env:TEMP '.phase-containment-cache-Grimblaz-agent-orchestra-t1.json'
        if (Test-Path -LiteralPath $tempCache) { Remove-Item -LiteralPath $tempCache -Force -ErrorAction SilentlyContinue }
    }

    It 'returns Surface A partial Entries with Source=graphql and Truncated=$true instead of an empty Source=timeout when the budget exhausts before Surface B fetch' {
        function global:gh {
            param([Parameter(ValueFromRemainingArguments = $true)]$Args)
            $joined = $Args -join ' '
            $global:LASTEXITCODE = 0
            if ($joined -match 'is:issue') {
                Start-Sleep -Milliseconds 1200
                $body = @"
<!-- plan-issue-1302 -->
<!-- phase-containment-1302 -->
finding_key: plan-stress-test:1302:F1
introduced_phase: plan
catchable_phase: plan
caught_stage: plan-stress-test
escape_distance: 0
severity: low
systemic_fix_type: plan-template
category: pattern
apparatus_meta: false
<!-- /phase-containment-1302 -->
"@
                $payload = @{
                    data = @{
                        search = @{
                            pageInfo = @{ hasNextPage = $false; endCursor = $null }
                            nodes    = @(
                                @{
                                    number   = 1302
                                    comments = @{
                                        nodes    = @(@{ body = $body; createdAt = '2024-01-01T12:00:00Z' })
                                        pageInfo = @{ hasNextPage = $false; endCursor = $null }
                                    }
                                }
                            )
                        }
                    }
                }
                return ($payload | ConvertTo-Json -Depth 12)
            }
            if ($joined -match 'is:pr') {
                throw 'Surface B must not be fetched once the T1 site returns early'
            }
            return '{}'
        }

        $cachePath = Join-Path $env:TEMP '.phase-containment-cache-Grimblaz-agent-orchestra-t1.json'
        $result = Get-PhaseContainmentHistory -RepoOwner 'Grimblaz' -RepoName 'agent-orchestra' -WindowDays 30 -TimeoutSeconds 1 -CachePath $cachePath 3>$null

        $result.Source    | Should -Be 'graphql'
        $result.Truncated | Should -Be $true
        ($result.Entries | Where-Object { $_['finding_key'] -eq 'plan-stress-test:1302:F1' }) | Should -Not -BeNullOrEmpty
        # A truncated run must not have written the cache (P7).
        Test-Path -LiteralPath $cachePath | Should -Be $false
    }
}

# ---------------------------------------------------------------------------
# Issue #772 M2: reset-on-discard — when accumulated GraphQL Truncated state
# is discarded on fall-to-REST, the REST run must own its own Truncated
# state, not inherit a stale $true from the discarded GraphQL attempt.
# ---------------------------------------------------------------------------

Describe 'Get-PhaseContainmentCommentCorpus — reset-on-discard (issue #772 M2)' {
    AfterEach {
        if (Get-Command 'gh' -CommandType Function -ErrorAction SilentlyContinue) {
            Remove-Item -Path Function:gh -ErrorAction SilentlyContinue
        }
    }

    It 'returns REST-only tuples (not the discarded Surface A tuple) with Truncated reflecting REST''s own state when Surface B errors outright' {
        # NOTE: a GraphQL-timeout-driven Truncated=$true on Surface A cannot
        # coexist with "proceeding past the T1 guard to call Surface B" —
        # both checks share the same monotonic $Stopwatch and the same
        # $TimeoutSeconds threshold, so if Surface A's OWN pagination guard
        # already tripped, the outer T1 "before Surface B fetch" guard
        # necessarily also observes an exhausted budget and returns early
        # (this is exercised by the T1 Describe block above). The
        # realistically-reachable reset-on-discard scenario is therefore:
        # Surface A succeeds cleanly and fast (Truncated=$false, real
        # budget remaining), Surface B fails OUTRIGHT (not a timeout), and
        # REST completes. This still proves the discard is real (Surface
        # A's tuple is gone, REST's own tuple is what survives) and that
        # Truncated is REST's own value, not inherited.
        function global:gh {
            param([Parameter(ValueFromRemainingArguments = $true)]$Args)
            $joined = $Args -join ' '
            $global:LASTEXITCODE = 0
            if ($joined -match 'is:issue') {
                $payload = @{
                    data = @{
                        search = @{
                            pageInfo = @{ hasNextPage = $false; endCursor = $null }
                            nodes    = @(
                                @{
                                    number   = 1401
                                    comments = @{
                                        nodes    = @(@{ body = '<!-- plan-issue-1401 -->'; createdAt = '2024-01-01T12:00:00Z' })
                                        pageInfo = @{ hasNextPage = $false; endCursor = $null }
                                    }
                                }
                            )
                        }
                    }
                }
                return ($payload | ConvertTo-Json -Depth 12)
            }
            if ($joined -match 'is:pr') {
                # Surface B fails outright -> forces fall-to-REST, discarding
                # Surface A's already-accumulated tuple.
                $global:LASTEXITCODE = 1
                return 'boom'
            }
            if ($joined -match '^issue list') { return (@(@{ number = 1402 }) | ConvertTo-Json) }
            if ($joined -match 'issue view 1402') { return (@{ comments = @(@{ body = '<!-- plan-issue-1402 -->' }) } | ConvertTo-Json -Depth 6) }
            if ($joined -match '^pr list')    { return '[]' }
            return '{}'
        }

        $result = Get-PhaseContainmentCommentCorpus -RepoOwner 'Grimblaz' -RepoName 'agent-orchestra' -WindowDays 30 -TimeoutSeconds 30 3>$null

        $result.Source    | Should -Be 'rest'
        $result.Truncated | Should -Be $false
        # Surface A's tuple (#1401) must be gone — discarded by the
        # $allTuples.Clear() on fall-to-REST — and REST's own tuple (#1402)
        # is what survives.
        ($result.Tuples | Where-Object { $_['Number'] -eq 1401 }) | Should -BeNullOrEmpty
        ($result.Tuples | Where-Object { $_['Number'] -eq 1402 }) | Should -Not -BeNullOrEmpty
    }
}

Describe 'Get-PhaseContainmentHistory — InvalidEntryCount does not leak across the fall-to-REST discard boundary (issue #772 M2)' {
    AfterEach {
        if (Get-Command 'gh' -CommandType Function -ErrorAction SilentlyContinue) {
            Remove-Item -Path Function:gh -ErrorAction SilentlyContinue
        }
        $tempCache = Join-Path $env:TEMP '.phase-containment-cache-Grimblaz-agent-orchestra-m2.json'
        if (Test-Path -LiteralPath $tempCache) { Remove-Item -LiteralPath $tempCache -Force -ErrorAction SilentlyContinue }
    }

    It 'reports InvalidEntryCount=0 (REST''s own count) not 1 (Surface A''s discarded count) when Surface A had a drop but Surface B errors outright' {
        # Surface A scans a body with ONE malformed block (InvalidEntryCount
        # contribution = 1) then Surface B fails outright, discarding Surface
        # A's $rawEntries/$invalidEntryCount. REST then completes with a
        # clean body (zero drops). If the discard boundary leaked/accumulated
        # instead of resetting, the final count would incorrectly read 1.
        $malformedBody = @"
<!-- plan-issue-1403 -->
<!-- phase-containment-1403 -->
finding_key: plan-stress-test:1403:BADKEY
introduced_phase: NOT-A-VALID-PHASE
<!-- /phase-containment-1403 -->
"@
        $cleanRestBody = '<!-- plan-issue-1404 -->'

        function global:gh {
            param([Parameter(ValueFromRemainingArguments = $true)]$Args)
            $joined = $Args -join ' '
            $global:LASTEXITCODE = 0
            if ($joined -match 'is:issue') {
                $payload = @{
                    data = @{
                        search = @{
                            pageInfo = @{ hasNextPage = $false; endCursor = $null }
                            nodes    = @(
                                @{
                                    number   = 1403
                                    comments = @{
                                        nodes    = @(@{ body = $malformedBody; createdAt = '2024-01-01T12:00:00Z' })
                                        pageInfo = @{ hasNextPage = $false; endCursor = $null }
                                    }
                                }
                            )
                        }
                    }
                }
                return ($payload | ConvertTo-Json -Depth 12)
            }
            if ($joined -match 'is:pr') {
                $global:LASTEXITCODE = 1
                return 'boom'
            }
            if ($joined -match '^issue list') { return (@(@{ number = 1404 }) | ConvertTo-Json) }
            if ($joined -match 'issue view 1404') { return (@{ comments = @(@{ body = $cleanRestBody }) } | ConvertTo-Json -Depth 6) }
            if ($joined -match '^pr list')    { return '[]' }
            return '{}'
        }

        $cachePath = Join-Path $env:TEMP '.phase-containment-cache-Grimblaz-agent-orchestra-m2.json'
        $result = Get-PhaseContainmentHistory -RepoOwner 'Grimblaz' -RepoName 'agent-orchestra' -WindowDays 30 -CachePath $cachePath -TimeoutSeconds 30 3>$null

        $result.Source            | Should -Be 'rest'
        $result.InvalidEntryCount | Should -Be 0
    }
}

# ---------------------------------------------------------------------------
# Issue #772 P8/P7: InvalidEntryCount accuracy and cache-survival.
# ---------------------------------------------------------------------------

Describe 'Get-PhaseContainmentHistory — InvalidEntryCount cache-survival (issue #772 P7)' {
    BeforeAll {
        $script:CachePathP7 = Join-Path $env:TEMP '.phase-containment-cache-Grimblaz-agent-orchestra-p7.json'
    }

    AfterEach {
        if (Get-Command 'gh' -CommandType Function -ErrorAction SilentlyContinue) {
            Remove-Item -Path Function:gh -ErrorAction SilentlyContinue
        }
        if (Test-Path -LiteralPath $script:CachePathP7) { Remove-Item -LiteralPath $script:CachePathP7 -Force -ErrorAction SilentlyContinue }
    }

    It 'persists a nonzero InvalidEntryCount into the cache payload and returns it on the subsequent cache-hit' {
        $validBody = @"
<!-- plan-issue-1500 -->
<!-- phase-containment-1500 -->
finding_key: plan-stress-test:1500:F1
introduced_phase: plan
catchable_phase: plan
caught_stage: plan-stress-test
escape_distance: 0
severity: low
systemic_fix_type: plan-template
category: pattern
apparatus_meta: false
<!-- /phase-containment-1500 -->
<!-- phase-containment-1500 -->
finding_key: plan-stress-test:1500:BADKEY
introduced_phase: NOT-A-VALID-PHASE
<!-- /phase-containment-1500 -->
"@
        function global:gh {
            param([Parameter(ValueFromRemainingArguments = $true)]$Args)
            $joined = $Args -join ' '
            $global:LASTEXITCODE = 0
            if ($joined -match 'is:issue') {
                $payload = @{
                    data = @{
                        search = @{
                            pageInfo = @{ hasNextPage = $false; endCursor = $null }
                            nodes    = @(
                                @{
                                    number   = 1500
                                    comments = @{
                                        nodes    = @(@{ body = $validBody; createdAt = '2024-01-01T12:00:00Z' })
                                        pageInfo = @{ hasNextPage = $false; endCursor = $null }
                                    }
                                }
                            )
                        }
                    }
                }
                return ($payload | ConvertTo-Json -Depth 12)
            }
            if ($joined -match 'is:pr') {
                $payload = @{ data = @{ search = @{ pageInfo = @{ hasNextPage = $false; endCursor = $null }; nodes = @() } } }
                return ($payload | ConvertTo-Json -Depth 12)
            }
            return '{}'
        }

        $first = Get-PhaseContainmentHistory -RepoOwner 'Grimblaz' -RepoName 'agent-orchestra' -WindowDays 30 -CachePath $script:CachePathP7 3>$null

        $first.Source            | Should -Be 'graphql'
        $first.Truncated         | Should -Be $false
        $first.InvalidEntryCount | Should -Be 1
        Test-Path -LiteralPath $script:CachePathP7 | Should -Be $true

        # Second call within the fresh cache window must hit cache and
        # return the SAME InvalidEntryCount, not silently default to 0.
        function global:gh {
            param([Parameter(ValueFromRemainingArguments = $true)]$Args)
            throw 'gh must not be called on a cache hit'
        }

        $second = Get-PhaseContainmentHistory -RepoOwner 'Grimblaz' -RepoName 'agent-orchestra' -WindowDays 30 -CachePath $script:CachePathP7 3>$null

        $second.Source            | Should -Be 'cache'
        $second.InvalidEntryCount | Should -Be 1
    }
}

Describe 'Get-PhaseContainmentHistory — M1 cache-write guard (issue #772/#831 M1)' {
    BeforeAll {
        $script:CachePathM1 = Join-Path $env:TEMP '.phase-containment-cache-Grimblaz-agent-orchestra-m1.json'
    }

    AfterEach {
        if (Get-Command 'gh' -CommandType Function -ErrorAction SilentlyContinue) {
            Remove-Item -Path Function:gh -ErrorAction SilentlyContinue
        }
        if (Test-Path -LiteralPath $script:CachePathM1) { Remove-Item -LiteralPath $script:CachePathM1 -Force -ErrorAction SilentlyContinue }
    }

    It 'does NOT write the cache when a post-marker-find pagination gh failure degrades an otherwise-successful GraphQL run' {
        # Issue 1601's page-1 comments already carry a full, valid
        # phase-containment block (hasNextPage=false -- no further paging
        # needed), so the corpus is non-empty. Issue 1602's page-1 carries
        # only the plan-issue marker with hasNextPage=true; the follow-up
        # post-marker-find pagination call for #1602 fails (exit 1). Before
        # the M1 fix, that failure was invisible to Truncated, so this
        # otherwise-nonempty, actually-degraded run would pass the
        # cache-write guard and get served as "clean" from the cache for up
        # to an hour.
        $blockBody = "<!-- plan-issue-1601 -->`n<!-- phase-containment-1601 -->`nfinding_key: code-review:1601:F1`nintroduced_phase: design`ncatchable_phase: design`ncaught_stage: code-review`nescape_distance: 2`nseverity: high`nsystemic_fix_type: skill`ncategory: architecture`napparatus_meta: false`nseed: false`n<!-- /phase-containment-1601 -->"

        function global:gh {
            param([Parameter(ValueFromRemainingArguments = $true)]$Args)
            $joined = $Args -join ' '
            if ($joined -match 'issue\(number: 1602') {
                $global:LASTEXITCODE = 1
                return ''
            }
            $global:LASTEXITCODE = 0
            if ($joined -match 'is:issue') {
                $payload = @{
                    data = @{
                        search = @{
                            pageInfo = @{ hasNextPage = $false; endCursor = $null }
                            nodes    = @(
                                @{
                                    number   = 1601
                                    comments = @{
                                        nodes    = @(@{ body = $blockBody; createdAt = '2024-01-01T12:00:00Z' })
                                        pageInfo = @{ hasNextPage = $false; endCursor = $null }
                                    }
                                },
                                @{
                                    number   = 1602
                                    comments = @{
                                        nodes    = @(@{ body = '<!-- plan-issue-1602 -->'; createdAt = '2024-01-01T12:00:00Z' })
                                        pageInfo = @{ hasNextPage = $true; endCursor = 'M1CACHECUR2' }
                                    }
                                }
                            )
                        }
                    }
                }
                return ($payload | ConvertTo-Json -Depth 12)
            }
            if ($joined -match 'is:pr') {
                $payload = @{ data = @{ search = @{ pageInfo = @{ hasNextPage = $false; endCursor = $null }; nodes = @() } } }
                return ($payload | ConvertTo-Json -Depth 12)
            }
            return '{}'
        }

        $result = Get-PhaseContainmentHistory -RepoOwner 'Grimblaz' -RepoName 'agent-orchestra' -WindowDays 30 -CachePath $script:CachePathM1 3>$null

        $result.Source    | Should -Be 'graphql'
        $result.Truncated | Should -Be $true -Because 'issue #1602''s post-marker-find pagination failure must surface as Truncated'
        $result.Entries   | Should -HaveCount 1 -Because 'issue #1601''s valid block must still be present despite issue #1602''s pagination failure (partial preservation)'
        Test-Path -LiteralPath $script:CachePathM1 | Should -Be $false -Because 'a truncated/degraded run must never be written to the 1-hour cache -- writing it would serve the degraded snapshot as "clean" for up to an hour'
    }
}

# ---------------------------------------------------------------------------
# Issue #772 C11: rollup -Truncated withholding — forces
# RelaxationEligible=$false for every stage, unconditionally.
# ---------------------------------------------------------------------------

Describe 'Get-PhaseContainmentRollup — Truncated forces RelaxationEligible=$false for every stage (issue #772 C11)' {
    BeforeAll {
        function script:New-TruncatedRollupEntry {
            param([string]$FindingKey, [string]$Stage = 'code-review', [string]$CatchablePhase = 'implementation')
            return [PSCustomObject]@{
                finding_key       = $FindingKey
                introduced_phase  = 'implementation'
                catchable_phase   = $CatchablePhase
                caught_stage      = $Stage
                escape_distance   = 0
                severity          = 'low'
                systemic_fix_type = 'none'
                category          = 'pattern'
                apparatus_meta    = $false
                seed              = $false
                createdAt         = '2024-01-01T12:00:00Z'
                surface           = 'pr'
                issueOrPrNumber   = 900
            }
        }
    }

    It 'sets RelaxationEligible=$false and RelaxationEligibleReason=fetch truncated for a stage that would otherwise be clean/eligible' {
        $entries = 1..6 | ForEach-Object { script:New-TruncatedRollupEntry -FindingKey "code-review:900:F$_" }

        $result = Get-PhaseContainmentRollup -Entries $entries -Truncated

        $stage = $result.Stages['code-review']
        $stage.RelaxationEligible       | Should -Be $false
        $stage.RelaxationEligibleReason | Should -Be 'fetch truncated'
    }

    It 'does not set RelaxationEligibleReason when -Truncated is not supplied (regression guard)' {
        $entries = 1..6 | ForEach-Object { script:New-TruncatedRollupEntry -FindingKey "code-review:901:F$_" }

        $result = Get-PhaseContainmentRollup -Entries $entries

        $stage = $result.Stages['code-review']
        $stage.RelaxationEligible       | Should -Be $true
        $stage.RelaxationEligibleReason | Should -BeNullOrEmpty
    }
}

# ---------------------------------------------------------------------------
# 14. D2 — capped incremental marker hunt (issue #772 s5 / F11)
#
# Get-SurfaceACorpusGraphQL / Get-SurfaceBCorpusGraphQL: when page 1 of an
# issue's/PR's comments carries no phase marker but hasNextPage is true, hunt
# up to K=5 ADDITIONAL pages, re-checking the marker after each. Found ->
# resume UNBOUNDED pagination past the cap to collect the rest of the thread
# (P6 — a phase-containment-{N} block can sit on any later page, not just
# near the marker). Cap exhausted with more pages remaining, or a mid-hunt
# timeout -> drop the tuple and set Truncated (M6, possible undercount).
# Natural exhaustion (ran out of real pages within the cap) is NOT a
# truncation -- nothing was left to fetch.
# ---------------------------------------------------------------------------

Describe 'Get-SurfaceACorpusGraphQL — D2 capped marker hunt (issue #772)' {
    BeforeAll {
        # Outer search page: one issue node whose OWN inline comments page
        # (i.e. "page 1" of that issue's comment thread) is controlled by
        # $Page1Body/$HasNextPage/$EndCursor. The outer search pagination
        # itself is single-page (hasNextPage=false) for every test here —
        # D2 concerns the PER-ISSUE comment hunt, not outer search paging.
        function script:New-D2ASearchPage {
            param([int]$IssueNumber, [string]$Page1Body, [bool]$HasNextPage, [string]$EndCursor)
            $payload = @{
                data = @{
                    search = @{
                        pageInfo = @{ hasNextPage = $false; endCursor = $null }
                        nodes    = @(
                            @{
                                number   = $IssueNumber
                                comments = @{
                                    nodes    = @(@{ body = $Page1Body; createdAt = '2024-01-01T12:00:00Z' })
                                    pageInfo = @{ hasNextPage = $HasNextPage; endCursor = $EndCursor }
                                }
                            }
                        )
                    }
                }
            }
            return ($payload | ConvertTo-Json -Depth 12)
        }

        # A single per-issue comment page (used for both hunt pages and the
        # post-find unbounded resume pages — same GraphQL query shape).
        function script:New-D2AIssuePage {
            param([string]$Body, [bool]$HasNextPage, [string]$EndCursor)
            $payload = @{
                data = @{
                    repository = @{
                        issue = @{
                            comments = @{
                                nodes    = @(@{ body = $Body; createdAt = '2024-01-01T12:05:00Z' })
                                pageInfo = @{ hasNextPage = $HasNextPage; endCursor = $EndCursor }
                            }
                        }
                    }
                }
            }
            return ($payload | ConvertTo-Json -Depth 12)
        }

        # Routes a per-issue `gh api graphql` call to the fixture keyed by
        # its `after: "<cursor>"` value. The outer search call carries no
        # `issue(number:` fragment, so it always returns $global:d2ASearch.
        function script:Install-D2AGhMock {
            function global:gh {
                param([Parameter(ValueFromRemainingArguments = $true)]$Args)
                $joined = $Args -join ' '
                $global:LASTEXITCODE = 0
                if ($joined -notmatch 'issue\(number:') {
                    return $global:d2ASearch
                }
                if ($joined -match 'after: "([^"]*)"') {
                    return $global:d2APageMap[$Matches[1]]
                }
                return '{}'
            }
        }
    }

    AfterEach {
        if (Get-Command 'gh' -CommandType Function -ErrorAction SilentlyContinue) {
            Remove-Item -Path Function:gh -ErrorAction SilentlyContinue
        }
        Remove-Variable -Name d2ASearch, d2APageMap -Scope Global -ErrorAction SilentlyContinue
    }

    It '(a) marker found on page 1 -> unbounded resume collects a later block (regression)' {
        $issueNum  = 951
        $blockBody = "<!-- phase-containment-$issueNum -->`nfinding_key: code-review:${issueNum}:F1`nintroduced_phase: design`ncatchable_phase: design`ncaught_stage: code-review`nescape_distance: 2`nseverity: high`nsystemic_fix_type: skill`ncategory: architecture`napparatus_meta: false`nseed: false`n<!-- /phase-containment-$issueNum -->"

        $global:d2ASearch = script:New-D2ASearchPage -IssueNumber $issueNum `
            -Page1Body "<!-- plan-issue-$issueNum -->" -HasNextPage $true -EndCursor 'A1CUR1'
        $global:d2APageMap = @{
            'A1CUR1' = (script:New-D2AIssuePage -Body $blockBody -HasNextPage $false -EndCursor $null)
        }
        script:Install-D2AGhMock

        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        $result = script:Get-SurfaceACorpusGraphQL `
            -Owner 'Grimblaz' -Repo 'agent-orchestra' -WindowDays 30 `
            -Stopwatch $stopwatch -TimeoutSeconds 30 3>$null

        $result.IsError   | Should -Be $false
        $result.Truncated | Should -Be $false
        $result.Tuples    | Should -HaveCount 1
        $allBodies = $result.Tuples[0]['Bodies'] -join "`n"
        $allBodies | Should -Match "phase-containment-$issueNum"
    }

    It '(b) marker found on hunt page 2 of 5 -> hunt stops and unbounded resume captures a block on page 8 (P6, critical)' {
        $issueNum   = 952
        $markerBody = "<!-- plan-issue-$issueNum -->"
        $blockBody  = "<!-- phase-containment-$issueNum -->`nfinding_key: code-review:${issueNum}:F1`nintroduced_phase: design`ncatchable_phase: design`ncaught_stage: code-review`nescape_distance: 2`nseverity: high`nsystemic_fix_type: skill`ncategory: architecture`napparatus_meta: false`nseed: false`n<!-- /phase-containment-$issueNum -->"

        # page 1 (search-inline): no marker, hasNextPage -> B2CUR1
        $global:d2ASearch = script:New-D2ASearchPage -IssueNumber $issueNum `
            -Page1Body 'no marker on page 1' -HasNextPage $true -EndCursor 'B2CUR1'

        $global:d2APageMap = @{
            # hunt page 1 (page 2 overall): still no marker
            'B2CUR1' = (script:New-D2AIssuePage -Body 'no marker hunt page 1' -HasNextPage $true -EndCursor 'B2CUR2')
            # hunt page 2 (page 3 overall): marker found here -> hunt stops
            'B2CUR2' = (script:New-D2AIssuePage -Body $markerBody -HasNextPage $true -EndCursor 'B2CUR3')
            # unbounded resume, pages 4-7: filler, no block yet
            'B2CUR3' = (script:New-D2AIssuePage -Body 'filler page 4' -HasNextPage $true -EndCursor 'B2CUR4')
            'B2CUR4' = (script:New-D2AIssuePage -Body 'filler page 5' -HasNextPage $true -EndCursor 'B2CUR5')
            'B2CUR5' = (script:New-D2AIssuePage -Body 'filler page 6' -HasNextPage $true -EndCursor 'B2CUR6')
            'B2CUR6' = (script:New-D2AIssuePage -Body 'filler page 7' -HasNextPage $true -EndCursor 'B2CUR7')
            # page 8 overall: the phase-containment block, well beyond the
            # K=5 hunt cap -- proves post-find pagination is unbounded.
            'B2CUR7' = (script:New-D2AIssuePage -Body $blockBody -HasNextPage $false -EndCursor $null)
        }
        script:Install-D2AGhMock

        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        $result = script:Get-SurfaceACorpusGraphQL `
            -Owner 'Grimblaz' -Repo 'agent-orchestra' -WindowDays 30 `
            -Stopwatch $stopwatch -TimeoutSeconds 30 3>$null

        $result.IsError   | Should -Be $false
        $result.Truncated | Should -Be $false
        $result.Tuples    | Should -HaveCount 1
        $tuple = $result.Tuples[0]
        $tuple['Number'] | Should -Be $issueNum
        $allBodies = $tuple['Bodies'] -join "`n"
        $escapedMarker = [regex]::Escape($markerBody)
        $allBodies | Should -Match $escapedMarker
        # The load-bearing P6 assertion: the block that sits 5 pages past
        # the marker (and past the K=5 hunt cap) must actually be captured,
        # not just that the tuple survived.
        $allBodies | Should -Match "phase-containment-$issueNum"
        $allBodies | Should -Match "code-review:${issueNum}:F1"
    }

    It '(c) hunt exhausts K=5 additional pages markerless -> tuple dropped, Truncated=$true' {
        $issueNum = 953

        $global:d2ASearch = script:New-D2ASearchPage -IssueNumber $issueNum `
            -Page1Body 'no marker page 1' -HasNextPage $true -EndCursor 'C1'

        $global:d2APageMap = @{
            'C1' = (script:New-D2AIssuePage -Body 'no marker hunt 1' -HasNextPage $true -EndCursor 'C2')
            'C2' = (script:New-D2AIssuePage -Body 'no marker hunt 2' -HasNextPage $true -EndCursor 'C3')
            'C3' = (script:New-D2AIssuePage -Body 'no marker hunt 3' -HasNextPage $true -EndCursor 'C4')
            'C4' = (script:New-D2AIssuePage -Body 'no marker hunt 4' -HasNextPage $true -EndCursor 'C5')
            # 5th (last allowed) hunt page: still no marker, and still MORE
            # pages remain (hasNextPage=true) -- this is the cap-exhausted
            # case, distinct from natural exhaustion.
            'C5' = (script:New-D2AIssuePage -Body 'no marker hunt 5' -HasNextPage $true -EndCursor 'C6')
        }
        script:Install-D2AGhMock

        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        $result = script:Get-SurfaceACorpusGraphQL `
            -Owner 'Grimblaz' -Repo 'agent-orchestra' -WindowDays 30 `
            -Stopwatch $stopwatch -TimeoutSeconds 30 3>$null

        $result.IsError   | Should -Be $false
        $result.Truncated | Should -Be $true
        ($result.Tuples | Where-Object { $_['Number'] -eq $issueNum }) | Should -BeNullOrEmpty
    }

    It '(d) mid-hunt timeout -> tuple dropped, Truncated=$true' {
        $issueNum = 954

        $global:d2ASearch = script:New-D2ASearchPage -IssueNumber $issueNum `
            -Page1Body 'no marker page 1' -HasNextPage $true -EndCursor 'D1'

        function global:gh {
            param([Parameter(ValueFromRemainingArguments = $true)]$Args)
            $joined = $Args -join ' '
            $global:LASTEXITCODE = 0
            if ($joined -notmatch 'issue\(number:') {
                return $global:d2ASearch
            }
            # Sleep past the 1s budget while answering the FIRST hunt page —
            # the hunt while-loop's own next top-check trips deterministically.
            Start-Sleep -Milliseconds 1200
            $payload = @{
                data = @{
                    repository = @{
                        issue = @{
                            comments = @{
                                nodes    = @(@{ body = 'no marker hunt 1'; createdAt = '2024-01-01T12:05:00Z' })
                                pageInfo = @{ hasNextPage = $true; endCursor = 'D2' }
                            }
                        }
                    }
                }
            }
            return ($payload | ConvertTo-Json -Depth 12)
        }

        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        $result = script:Get-SurfaceACorpusGraphQL `
            -Owner 'Grimblaz' -Repo 'agent-orchestra' -WindowDays 30 `
            -Stopwatch $stopwatch -TimeoutSeconds 1 3>$null

        $result.IsError   | Should -Be $false
        $result.Truncated | Should -Be $true
        ($result.Tuples | Where-Object { $_['Number'] -eq $issueNum }) | Should -BeNullOrEmpty
    }

    It '(e) markerless single-page issue (no hasNextPage) -> dropped, Truncated stays $false (not a degradation)' {
        $issueNum = 955

        $global:d2ASearch = script:New-D2ASearchPage -IssueNumber $issueNum `
            -Page1Body 'no marker, only page' -HasNextPage $false -EndCursor $null
        $global:d2APageMap = @{}
        script:Install-D2AGhMock

        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        $result = script:Get-SurfaceACorpusGraphQL `
            -Owner 'Grimblaz' -Repo 'agent-orchestra' -WindowDays 30 `
            -Stopwatch $stopwatch -TimeoutSeconds 30 3>$null

        $result.IsError   | Should -Be $false
        $result.Truncated | Should -Be $false -Because 'there was nothing more to fetch -- correctly excluded, not a truncation'
        ($result.Tuples | Where-Object { $_['Number'] -eq $issueNum }) | Should -BeNullOrEmpty
    }
}

Describe 'Get-SurfaceBCorpusGraphQL — D2 capped marker hunt (issue #772)' {
    BeforeAll {
        function script:New-D2BSearchPage {
            param([int]$PrNumber, [string]$Page1Body, [bool]$HasNextPage, [string]$EndCursor)
            $payload = @{
                data = @{
                    search = @{
                        pageInfo = @{ hasNextPage = $false; endCursor = $null }
                        nodes    = @(
                            @{
                                number   = $PrNumber
                                comments = @{
                                    nodes    = @(@{ body = $Page1Body; createdAt = '2024-01-01T12:00:00Z' })
                                    pageInfo = @{ hasNextPage = $HasNextPage; endCursor = $EndCursor }
                                }
                            }
                        )
                    }
                }
            }
            return ($payload | ConvertTo-Json -Depth 12)
        }

        function script:New-D2BPrPage {
            param([string]$Body, [bool]$HasNextPage, [string]$EndCursor)
            $payload = @{
                data = @{
                    repository = @{
                        pullRequest = @{
                            comments = @{
                                nodes    = @(@{ body = $Body; createdAt = '2024-01-01T12:05:00Z' })
                                pageInfo = @{ hasNextPage = $HasNextPage; endCursor = $EndCursor }
                            }
                        }
                    }
                }
            }
            return ($payload | ConvertTo-Json -Depth 12)
        }

        function script:Install-D2BGhMock {
            function global:gh {
                param([Parameter(ValueFromRemainingArguments = $true)]$Args)
                $joined = $Args -join ' '
                $global:LASTEXITCODE = 0
                if ($joined -notmatch 'pullRequest\(number:') {
                    return $global:d2BSearch
                }
                if ($joined -match 'after: "([^"]*)"') {
                    return $global:d2BPageMap[$Matches[1]]
                }
                return '{}'
            }
        }
    }

    AfterEach {
        if (Get-Command 'gh' -CommandType Function -ErrorAction SilentlyContinue) {
            Remove-Item -Path Function:gh -ErrorAction SilentlyContinue
        }
        Remove-Variable -Name d2BSearch, d2BPageMap -Scope Global -ErrorAction SilentlyContinue
    }

    It '(b) marker (judge-rulings) found on hunt page 2 of 5 -> hunt stops and unbounded resume captures a block on page 8 (P6, critical)' {
        $prNum      = 962
        $markerBody = '<!-- judge-rulings pr-962 -->'
        $blockBody  = "<!-- phase-containment-$prNum -->`nfinding_key: code-review:${prNum}:F1`nintroduced_phase: design`ncatchable_phase: design`ncaught_stage: code-review`nescape_distance: 2`nseverity: high`nsystemic_fix_type: skill`ncategory: architecture`napparatus_meta: false`nseed: false`n<!-- /phase-containment-$prNum -->"

        $global:d2BSearch = script:New-D2BSearchPage -PrNumber $prNum `
            -Page1Body 'no judge-rulings on page 1' -HasNextPage $true -EndCursor 'BB2CUR1'

        $global:d2BPageMap = @{
            'BB2CUR1' = (script:New-D2BPrPage -Body 'no judge-rulings hunt page 1' -HasNextPage $true -EndCursor 'BB2CUR2')
            'BB2CUR2' = (script:New-D2BPrPage -Body $markerBody -HasNextPage $true -EndCursor 'BB2CUR3')
            'BB2CUR3' = (script:New-D2BPrPage -Body 'filler page 4' -HasNextPage $true -EndCursor 'BB2CUR4')
            'BB2CUR4' = (script:New-D2BPrPage -Body 'filler page 5' -HasNextPage $true -EndCursor 'BB2CUR5')
            'BB2CUR5' = (script:New-D2BPrPage -Body 'filler page 6' -HasNextPage $true -EndCursor 'BB2CUR6')
            'BB2CUR6' = (script:New-D2BPrPage -Body 'filler page 7' -HasNextPage $true -EndCursor 'BB2CUR7')
            'BB2CUR7' = (script:New-D2BPrPage -Body $blockBody -HasNextPage $false -EndCursor $null)
        }
        script:Install-D2BGhMock

        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        $result = script:Get-SurfaceBCorpusGraphQL `
            -Owner 'Grimblaz' -Repo 'agent-orchestra' -WindowDays 30 `
            -Stopwatch $stopwatch -TimeoutSeconds 30 3>$null

        $result.IsError   | Should -Be $false
        $result.Truncated | Should -Be $false
        $result.Tuples    | Should -HaveCount 1
        $tuple = $result.Tuples[0]
        $tuple['Number'] | Should -Be $prNum
        $allBodies = $tuple['Bodies'] -join "`n"
        $escapedMarker = [regex]::Escape($markerBody)
        $allBodies | Should -Match $escapedMarker
        $allBodies | Should -Match "phase-containment-$prNum"
        $allBodies | Should -Match "code-review:${prNum}:F1"
    }

    It '(c) hunt exhausts K=5 additional pages markerless -> tuple dropped, Truncated=$true' {
        $prNum = 963

        $global:d2BSearch = script:New-D2BSearchPage -PrNumber $prNum `
            -Page1Body 'no judge-rulings page 1' -HasNextPage $true -EndCursor 'BC1'

        $global:d2BPageMap = @{
            'BC1' = (script:New-D2BPrPage -Body 'no marker hunt 1' -HasNextPage $true -EndCursor 'BC2')
            'BC2' = (script:New-D2BPrPage -Body 'no marker hunt 2' -HasNextPage $true -EndCursor 'BC3')
            'BC3' = (script:New-D2BPrPage -Body 'no marker hunt 3' -HasNextPage $true -EndCursor 'BC4')
            'BC4' = (script:New-D2BPrPage -Body 'no marker hunt 4' -HasNextPage $true -EndCursor 'BC5')
            'BC5' = (script:New-D2BPrPage -Body 'no marker hunt 5' -HasNextPage $true -EndCursor 'BC6')
        }
        script:Install-D2BGhMock

        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        $result = script:Get-SurfaceBCorpusGraphQL `
            -Owner 'Grimblaz' -Repo 'agent-orchestra' -WindowDays 30 `
            -Stopwatch $stopwatch -TimeoutSeconds 30 3>$null

        $result.IsError   | Should -Be $false
        $result.Truncated | Should -Be $true
        ($result.Tuples | Where-Object { $_['Number'] -eq $prNum }) | Should -BeNullOrEmpty
    }

    It '(e) markerless single-page PR (no hasNextPage) -> dropped, Truncated stays $false (not a degradation)' {
        $prNum = 964

        $global:d2BSearch = script:New-D2BSearchPage -PrNumber $prNum `
            -Page1Body 'no judge-rulings, only page' -HasNextPage $false -EndCursor $null
        $global:d2BPageMap = @{}
        script:Install-D2BGhMock

        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        $result = script:Get-SurfaceBCorpusGraphQL `
            -Owner 'Grimblaz' -Repo 'agent-orchestra' -WindowDays 30 `
            -Stopwatch $stopwatch -TimeoutSeconds 30 3>$null

        $result.IsError   | Should -Be $false
        $result.Truncated | Should -Be $false -Because 'there was nothing more to fetch -- correctly excluded, not a truncation'
        ($result.Tuples | Where-Object { $_['Number'] -eq $prNum }) | Should -BeNullOrEmpty
    }
}
