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
