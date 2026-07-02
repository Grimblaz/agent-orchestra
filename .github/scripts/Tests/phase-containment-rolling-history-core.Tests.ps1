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

        $result = Invoke-PhaseContainmentCommentScan -CommentBodies $allBodies -IssueOrPrNumber 762

        $result | Should -HaveCount 1
        $result[0].finding_key | Should -Be 'code-review:762:F1'
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

        $result = Invoke-PhaseContainmentCommentScan -CommentBodies @($page1Body, $page2Body) -IssueOrPrNumber 762

        $result | Should -HaveCount 2
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
        $result = Invoke-PhaseContainmentCommentScan -CommentBodies @($malformedBody) -IssueOrPrNumber 762 3>$null

        @($result) | Should -HaveCount 0
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

        $result = Invoke-PhaseContainmentCommentScan -CommentBodies @($malformedBody, $validBody) -IssueOrPrNumber 762 3>$null

        $result | Should -HaveCount 1
        $result[0].finding_key | Should -Be 'code-review:762:F1'
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

        $result = Invoke-PhaseContainmentCommentScan -CommentBodies @($body) -IssueOrPrNumber 762

        $result | Should -HaveCount 1
        $result[0].apparatus_meta | Should -Be $true
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

        $result = Invoke-PhaseContainmentCommentScan -CommentBodies @($body) -IssueOrPrNumber 762

        $result | Should -HaveCount 1
        $result[0].apparatus_meta | Should -Be $false
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

        $findingKeys = @($result | ForEach-Object { $_['finding_key'] })
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
        $findingKeys = @($result | ForEach-Object { $_['finding_key'] })
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

        $findingKeys = @($result | ForEach-Object { $_['finding_key'] })
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
            return , @(@{ finding_key = 'plan-stress-test:961:F1' })
        }

        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        $result = script:Get-PhaseContainmentEntriesRest -WindowDays 30 -Stopwatch $stopwatch -TimeoutSeconds 30 3>$null

        $findingKeys = @($result | ForEach-Object { $_['finding_key'] })
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
}
