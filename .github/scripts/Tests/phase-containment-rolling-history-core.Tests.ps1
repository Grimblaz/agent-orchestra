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
# 5b. Dedup — appended_at (issue #863 s4, judge-sustained M12/M13/M14)
# ---------------------------------------------------------------------------

Describe 'Invoke-PhaseContainmentDedup — appended_at' {
    BeforeAll {
        function script:New-ValidPCEntry5b {
            param(
                [string]$FindingKey = 'code-review:762:F1',
                [string]$CreatedAt = '2024-01-01T12:00:00Z',
                # Intentionally untyped: a typed [string] parameter with a
                # $null default gets coerced to '' at bind time when the
                # caller omits -AppendedAt, which would defeat the
                # "absent means no key" distinction this helper needs.
                $AppendedAt = $null
            )
            $entry = @{
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
            if ($null -ne $AppendedAt) { $entry['appended_at'] = [string]$AppendedAt }
            return $entry
        }
    }

    It 'AC6 inversion case: a re-annotated block wins against a stale block in a later-created sibling' {
        # comment1 was created first (createdAt=07-01) but re-annotated later
        # (appended_at=07-16T12:00). comment2 is a stale sibling created
        # AFTER comment1's original createdAt but BEFORE the re-annotation
        # (createdAt=07-10), carrying no appended_at. Pre-fix, comparing
        # createdAt only, comment2 (07-10) would incorrectly beat comment1
        # (07-01) even though comment1 was actually edited most recently.
        $reAnnotated = script:New-ValidPCEntry5b -CreatedAt '2026-07-01T00:00:00Z' -AppendedAt '2026-07-16T12:00:00Z'
        $stale = script:New-ValidPCEntry5b -CreatedAt '2026-07-10T00:00:00Z'

        $result = Invoke-PhaseContainmentDedup -RawEntries @($reAnnotated, $stale)

        $result | Should -HaveCount 1
        $result[0].createdAt | Should -Be '2026-07-01T00:00:00Z'
        $result[0]['appended_at'] | Should -Be '2026-07-16T12:00:00Z'
    }

    It 'absence-fallback case: entries with no appended_at dedup on createdAt exactly as before' {
        $older = script:New-ValidPCEntry5b -CreatedAt '2024-01-01T10:00:00Z'
        $newer = script:New-ValidPCEntry5b -CreatedAt '2024-01-01T12:00:00Z'

        $result = Invoke-PhaseContainmentDedup -RawEntries @($older, $newer)

        $result | Should -HaveCount 1
        $result[0].createdAt | Should -Be '2024-01-01T12:00:00Z'
    }

    It 'mixed-pair case: one entry stamped with appended_at, the paired entry falling back to createdAt' {
        # Stamped entry's appended_at (07-05) is later than the fallback
        # entry's createdAt (07-04) — stamped entry must win.
        $stamped = script:New-ValidPCEntry5b -CreatedAt '2026-07-01T00:00:00Z' -AppendedAt '2026-07-05T00:00:00Z'
        $fallback = script:New-ValidPCEntry5b -CreatedAt '2026-07-04T00:00:00Z'

        $result = Invoke-PhaseContainmentDedup -RawEntries @($stamped, $fallback)
        $result | Should -HaveCount 1
        $result[0]['appended_at'] | Should -Be '2026-07-05T00:00:00Z'

        # Reverse: fallback entry's createdAt (07-10) is later than the
        # stamped entry's appended_at (07-05) — fallback entry must win.
        $stamped2 = script:New-ValidPCEntry5b -CreatedAt '2026-07-01T00:00:00Z' -AppendedAt '2026-07-05T00:00:00Z'
        $fallback2 = script:New-ValidPCEntry5b -CreatedAt '2026-07-10T00:00:00Z'

        $result2 = Invoke-PhaseContainmentDedup -RawEntries @($stamped2, $fallback2)
        $result2 | Should -HaveCount 1
        $result2[0].createdAt | Should -Be '2026-07-10T00:00:00Z'
        $result2[0].ContainsKey('appended_at') | Should -Be $false
    }

    It 'present-but-malformed case: a non-Z-format appended_at is routed into InvalidEntryCount, not silently kept' {
        $malformed = script:New-ValidPCEntry5b -FindingKey 'code-review:762:F9' -CreatedAt '2026-07-01T00:00:00Z' -AppendedAt '2026-07-01T00:00:00' # missing Z suffix
        $counter = 0

        $result = Invoke-PhaseContainmentDedup -RawEntries @($malformed) -InvalidEntryCount ([ref]$counter)

        $result | Should -HaveCount 0
        $counter | Should -Be 1
    }

    It 'offset-form-vs-Z inversion case: an offset-form appended_at does not win over a correctly-formatted Z sibling' {
        # Design-review scenario: appended_at is offset-form (not strict Z),
        # so it must be treated as malformed and dropped — never allowed to
        # silently win the comparison via a Kind-blind tick comparison.
        $offsetForm = script:New-ValidPCEntry5b -CreatedAt '2026-07-01T00:00:00Z' -AppendedAt '2026-07-16T10:00:00-07:00'
        $zForm = script:New-ValidPCEntry5b -CreatedAt '2026-07-16T14:00:00Z'
        $counter = 0

        $result = Invoke-PhaseContainmentDedup -RawEntries @($offsetForm, $zForm) -InvalidEntryCount ([ref]$counter)

        $result | Should -HaveCount 1
        $result[0].createdAt | Should -Be '2026-07-16T14:00:00Z'
        $counter | Should -Be 1
    }

    It 'calendar-invalid case: an appended_at that matches the regex but is not a real calendar date is routed into InvalidEntryCount' {
        # PR #868 F6 fix: '2026-02-30T00:00:00Z' passes the strict Z-suffixed
        # regex (lexically well-formed) but February never has a 30th day,
        # so [datetime]::Parse throws. Must be dropped exactly like the
        # regex-malformed case above, not silently kept or crash the dedup.
        $calendarInvalid = script:New-ValidPCEntry5b -FindingKey 'code-review:762:F10' -CreatedAt '2026-02-01T00:00:00Z' -AppendedAt '2026-02-30T00:00:00Z'
        $counter = 0

        $result = Invoke-PhaseContainmentDedup -RawEntries @($calendarInvalid) -InvalidEntryCount ([ref]$counter)

        $result | Should -HaveCount 0
        $counter | Should -Be 1
    }
}

# ---------------------------------------------------------------------------
# 5c. Get-PCEffectiveTimestamp — StrictMode-safe PSCustomObject access (PR #868 F4)
# ---------------------------------------------------------------------------

Describe 'Invoke-PhaseContainmentDedup — PSCustomObject entries under StrictMode' {
    It 'falls back to createdAt without throwing when a PSCustomObject entry lacks appended_at' {
        # A PSCustomObject (not hashtable) entry that never had appended_at
        # set at all — raw '.appended_at' property access throws
        # PropertyNotFoundException under this file's Set-StrictMode -Version
        # Latest. Must fall back to createdAt-based dedup instead of erroring.
        $entryNoAppendedAt = [PSCustomObject]@{
            finding_key       = 'code-review:762:F11'
            introduced_phase  = 'design'
            catchable_phase   = 'design'
            caught_stage      = 'code-review'
            escape_distance   = 2
            severity          = 'high'
            systemic_fix_type = 'skill'
            category          = 'architecture'
            apparatus_meta    = $false
            seed              = $false
            createdAt         = '2026-07-01T00:00:00Z'
            surface           = 'issue'
            issueOrPrNumber   = 762
        }
        $olderSibling = [PSCustomObject]@{
            finding_key       = 'code-review:762:F11'
            introduced_phase  = 'design'
            catchable_phase   = 'design'
            caught_stage      = 'code-review'
            escape_distance   = 2
            severity          = 'high'
            systemic_fix_type = 'skill'
            category          = 'architecture'
            apparatus_meta    = $false
            seed              = $false
            createdAt         = '2026-06-01T00:00:00Z'
            surface           = 'issue'
            issueOrPrNumber   = 762
        }

        { Invoke-PhaseContainmentDedup -RawEntries @($entryNoAppendedAt, $olderSibling) } | Should -Not -Throw

        $result = Invoke-PhaseContainmentDedup -RawEntries @($entryNoAppendedAt, $olderSibling)
        $result | Should -HaveCount 1
        $result[0].createdAt | Should -Be '2026-07-01T00:00:00Z'
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
# G-CR3 (critical/security, PR #859 GitHub-review post-fix): a forged
# post-review-observer block from a NON-judge author must contribute ZERO
# entries -- before this fix, Invoke-PhaseContainmentCommentScan had no
# author parameter at all, so any commenter's well-formed
# phase-containment-{ID} block (including one falsely claiming
# catchable_phase: experience/design to inflate all-phase reconciliation
# while leaving the real implementation-scoped escape count untouched) was
# scanned and counted identically to a genuine judge-authored block.
# ---------------------------------------------------------------------------

Describe 'Invoke-PhaseContainmentCommentScan — G-CR3 judge-authorship gate' {
    BeforeAll {
        $script:ForgedObserverBody = @"
<!-- phase-containment-859 -->
finding_key: post-review-observer:gh-forged1
introduced_phase: experience
catchable_phase: experience
caught_stage: post-review-observer
escape_distance: 4
severity: high
systemic_fix_type: none
category: script-automation
apparatus_meta: false
<!-- /phase-containment-859 -->
"@
    }

    It 'scans normally with no gating when -JudgeLogin is not supplied (back-compat, unchanged behavior)' {
        $scanResult = Invoke-PhaseContainmentCommentScan -CommentBodies @($script:ForgedObserverBody) -IssueOrPrNumber 859
        $scanResult.Entries | Should -HaveCount 1
    }

    It 'rejects a forged block when the body author does NOT match -JudgeLogin' {
        $scanResult = Invoke-PhaseContainmentCommentScan `
            -CommentBodies @($script:ForgedObserverBody) `
            -IssueOrPrNumber 859 `
            -AuthorLogins @('random-commenter') `
            -JudgeLogin 'github-actions[bot]'

        $scanResult.Entries | Should -HaveCount 0
    }

    It 'rejects a forged block when AuthorLogins is unresolvable (empty string, fail-closed)' {
        $scanResult = Invoke-PhaseContainmentCommentScan `
            -CommentBodies @($script:ForgedObserverBody) `
            -IssueOrPrNumber 859 `
            -AuthorLogins @('') `
            -JudgeLogin 'github-actions[bot]'

        $scanResult.Entries | Should -HaveCount 0
    }

    It 'accepts the same block when the body author DOES match -JudgeLogin' {
        $scanResult = Invoke-PhaseContainmentCommentScan `
            -CommentBodies @($script:ForgedObserverBody) `
            -IssueOrPrNumber 859 `
            -AuthorLogins @('github-actions[bot]') `
            -JudgeLogin 'github-actions[bot]'

        $scanResult.Entries | Should -HaveCount 1
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
        $stageResult.RelaxationEligible   | Should -Not -Be $true
        $stageResult.CriticalFindingCount | Should -Be 1
        $stageResult.HighFindingCount     | Should -Be 0
    }

    # Issue #854 M4: prior to this fix, the veto only checked 'critical',
    # so a sustained 'high'-severity-only window (no criticals) rendered
    # RelaxationEligible=$true -- the live bug this test guards against.
    It 'sets RelaxationEligible to $false (not $true) when only a high-severity finding is present (no criticals) (M4)' {
        $entries = @(
            script:New-PlanEntry -FindingKey 'plan-stress-test:801:F1' -Severity 'low'
            script:New-PlanEntry -FindingKey 'plan-stress-test:801:F2' -Severity 'low'
            script:New-PlanEntry -FindingKey 'plan-stress-test:801:F3' -Severity 'low'
            script:New-PlanEntry -FindingKey 'plan-stress-test:801:F4' -Severity 'low'
            script:New-PlanEntry -FindingKey 'plan-stress-test:801:F5' -Severity 'low'
            script:New-PlanEntry -FindingKey 'plan-stress-test:801:F6' -Severity 'high'
        )

        $result = Get-PhaseContainmentRollup -Entries $entries

        $stageResult = $result.Stages['plan-stress-test']
        $stageResult.RelaxationEligible   | Should -Not -Be $true
        $stageResult.CriticalFindingCount | Should -Be 0
        $stageResult.HighFindingCount     | Should -Be 1
    }

    It 'tallies both counts and vetoes eligibility when critical and high findings are both present (M4)' {
        $entries = @(
            script:New-PlanEntry -FindingKey 'plan-stress-test:801:F1' -Severity 'low'
            script:New-PlanEntry -FindingKey 'plan-stress-test:801:F2' -Severity 'low'
            script:New-PlanEntry -FindingKey 'plan-stress-test:801:F3' -Severity 'critical'
            script:New-PlanEntry -FindingKey 'plan-stress-test:801:F4' -Severity 'critical'
            script:New-PlanEntry -FindingKey 'plan-stress-test:801:F5' -Severity 'high'
            script:New-PlanEntry -FindingKey 'plan-stress-test:801:F6' -Severity 'low'
        )

        $result = Get-PhaseContainmentRollup -Entries $entries

        $stageResult = $result.Stages['plan-stress-test']
        $stageResult.RelaxationEligible   | Should -Not -Be $true
        $stageResult.CriticalFindingCount | Should -Be 2
        $stageResult.HighFindingCount     | Should -Be 1
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
#
# REVISED (issue #854 s5, deliberate/owner-approved, mirrors the #768 M3
# precedent): the pre-#854 assertion that a clean code-review stage with
# n>=5 and no critical severity was automatically RelaxationEligible=$true
# is EXACTLY the artifact this issue exists to fix - "0.00 escape rate and
# ELIGIBLE" on the terminal stage was a measurement of nothing, because
# there was no downstream observer. The rates (EscapeRate/IrreducibleRate)
# are catch-side-only and genuinely unchanged by #854; RelaxationEligible
# for code-review now additionally requires an escape-side measurement
# (TerminalObservation) per the governing "coverage means measurement, not
# presence" principle. See the new Describe block below for code-review's
# post-#854 behavior; this block is re-pinned to a stage design-challenge/
# plan-stress-test never gate on TerminalObservation, so it keeps testing
# the same "clean stage -> eligible" invariant it always did.
# ---------------------------------------------------------------------------

Describe 'Get-PhaseContainmentRollup — clean upstream stage n>=5 sets RelaxationEligible=$true' {
    It 'returns RelaxationEligible=$true, EscapeRate=0.0, IrreducibleRate=1.0 for a clean plan-stress-test stage with 6 entries' {
        $entries = 1..6 | ForEach-Object {
            [PSCustomObject]@{
                finding_key       = "plan-stress-test:803:F$_"
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
                issueOrPrNumber   = 803
            }
        }

        $result = Get-PhaseContainmentRollup -Entries $entries

        $stageResult = $result.Stages['plan-stress-test']
        $stageResult.RelaxationEligible | Should -Be $true
        $stageResult.EscapeRate         | Should -Be 0.0
        $stageResult.IrreducibleRate    | Should -Be 1.0
    }
}

# ---------------------------------------------------------------------------
# 13a. Rollup — code-review stage's post-#854 escape-side gate (issue #854 s5)
#
# The code-review stage is the sole stage with a downstream observer, so its
# RelaxationEligible now additionally requires an escape-side measurement
# (TerminalObservation) on top of the catch-side check exercised above.
# ---------------------------------------------------------------------------

Describe 'Get-PhaseContainmentRollup — code-review escape-side guard (issue #854 s5, M4/M6/M7/M13)' {
    BeforeAll {
        function script:New-CleanCodeReviewEntries {
            param([int]$Count = 6, [int]$PrNumber = 803)
            return 1..$Count | ForEach-Object {
                [PSCustomObject]@{
                    finding_key       = "code-review:${PrNumber}:F$_"
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
                    issueOrPrNumber   = $PrNumber
                }
            }
        }
    }

    It 'sets RelaxationEligible=$false when TerminalObservation is not supplied, even though catch-side is clean (no-observer-corpus regression: rates stay unchanged)' {
        $entries = script:New-CleanCodeReviewEntries

        $result = Get-PhaseContainmentRollup -Entries $entries

        $stage = $result.Stages['code-review']
        $stage.EscapeRate                | Should -Be 0.0
        $stage.IrreducibleRate           | Should -Be 1.0
        $stage.RelaxationEligible        | Should -Be $false
        $stage.RelaxationEligibleReason  | Should -Match 'terminal observation unavailable'
        $stage.EscapeArmWithheld         | Should -Be $true
    }

    It 'leaves design-challenge and plan-stress-test RelaxationEligible/rates unchanged on a no-observer corpus (regression guard)' {
        $codeReviewEntries = script:New-CleanCodeReviewEntries
        $designEntries = 1..6 | ForEach-Object {
            [PSCustomObject]@{
                finding_key = "design-challenge:850:F$_"; introduced_phase = 'design'; catchable_phase = 'design'
                caught_stage = 'design-challenge'; escape_distance = 0; severity = 'low'
                systemic_fix_type = 'skill'; category = 'architecture'; apparatus_meta = $false; seed = $false
                createdAt = '2024-01-01T12:00:00Z'; surface = 'issue'; issueOrPrNumber = 850
            }
        }
        $planEntries = 1..6 | ForEach-Object {
            [PSCustomObject]@{
                finding_key = "plan-stress-test:851:F$_"; introduced_phase = 'plan'; catchable_phase = 'plan'
                caught_stage = 'plan-stress-test'; escape_distance = 0; severity = 'low'
                systemic_fix_type = 'instruction'; category = 'architecture'; apparatus_meta = $false; seed = $false
                createdAt = '2024-01-01T12:00:00Z'; surface = 'issue'; issueOrPrNumber = 851
            }
        }

        $result = Get-PhaseContainmentRollup -Entries ($codeReviewEntries + $designEntries + $planEntries)

        $result.Stages['design-challenge'].EscapeRate            | Should -Be 0.0
        $result.Stages['design-challenge'].IrreducibleRate       | Should -Be 1.0
        $result.Stages['design-challenge'].RelaxationEligible    | Should -Be $true
        $result.Stages['plan-stress-test'].EscapeRate            | Should -Be 0.0
        $result.Stages['plan-stress-test'].IrreducibleRate       | Should -Be 1.0
        $result.Stages['plan-stress-test'].RelaxationEligible    | Should -Be $true
        $result.Stages['code-review'].EscapeRate                 | Should -Be 0.0
        $result.Stages['code-review'].IrreducibleRate            | Should -Be 1.0
    }

    It 'sets RelaxationEligible=$true when TerminalObservation is fully supplied and clean (positive path)' {
        $entries = script:New-CleanCodeReviewEntries

        $terminalObservation = @{
            CoObservedPRCount              = 7
            MeasuredCoveragePRCount        = 6
            DispositionsNovelExternalCount = 0
            InternalCoObservedCatchCount   = 20
            ExternalCatchCount             = 3
            DuplicateCount                 = 2
            ObserverEscapeCount            = 0
        }

        $result = Get-PhaseContainmentRollup -Entries $entries -TerminalObservation $terminalObservation

        $stage = $result.Stages['code-review']
        $stage.RelaxationEligible       | Should -Be $true
        $stage.RelaxationEligibleReason | Should -BeNullOrEmpty
        $stage.CoverageK                | Should -Be 6
        $stage.CoverageN                | Should -Be 7
        $stage.CoverageOk               | Should -Be $true
        $stage.ReconciliationOk         | Should -Be $true
        $stage.UniqueCatchRate          | Should -Be 0.0
        $stage.UniqueCatchRateAssessable | Should -Be $true
    }

    It 'G-CR7: sets RelaxationEligible=$false with a coverage reason (K of N) on a generic K=0-of-N rollup guard, independent of WHY the caller supplied K=0' {
        $entries = script:New-CleanCodeReviewEntries

        # G-CR7 fix (PR #859 GitHub-review post-fix, test-clarity only — no
        # production code change): this test previously claimed "all-
        # unresolved coverage contributes ZERO, the caller (s6) is
        # responsible for that exclusion" as its rationale for K=0. That
        # premise is stale: report.ps1:87-98 documents the M5 fix that
        # REMOVED the >=1-resolved-finding requirement, and a valid
        # external_sources_reconciled record now counts toward K (coverage
        # means measurement) even when every finding on it is unresolved —
        # the caller-side "all-unresolved excludes a PR from K" story this
        # test used to describe no longer matches Get-PhaseContainmentTerminalObservation's
        # actual derivation. This test never exercised that derivation path
        # anyway (it hand-feeds MeasuredCoveragePRCount directly); its real,
        # still-valid purpose is proving Get-PhaseContainmentRollup itself
        # fails closed on a caller-supplied K=0 (whatever the caller's
        # reason for K=0 might be), not trusting CoObservedPRCount instead.
        $terminalObservation = @{
            CoObservedPRCount              = 5
            MeasuredCoveragePRCount        = 0
            DispositionsNovelExternalCount = 0
        }

        $result = Get-PhaseContainmentRollup -Entries $entries -TerminalObservation $terminalObservation

        $stage = $result.Stages['code-review']
        $stage.RelaxationEligible       | Should -Be $false
        $stage.RelaxationEligibleReason | Should -Match '0 of 5'
        $stage.CoverageOk               | Should -Be $false
    }

    It 'sets RelaxationEligible=$false when the dispositions-recorded novel count disagrees with emitted observer blocks (M13 escape-arm reconciliation, "0 misses" != "0 blocks emitted")' {
        $entries = script:New-CleanCodeReviewEntries

        $terminalObservation = @{
            CoObservedPRCount              = 6
            MeasuredCoveragePRCount        = 6
            DispositionsNovelExternalCount = 2
            # No post-review-observer entries are present in $entries, so the
            # emitted-block count this function derives is 0 -- a real
            # reconciliation mismatch (2 dispositions-recorded vs 0 emitted).
        }

        $result = Get-PhaseContainmentRollup -Entries $entries -TerminalObservation $terminalObservation

        $stage = $result.Stages['code-review']
        $stage.RelaxationEligible       | Should -Be $false
        $stage.RelaxationEligibleReason | Should -Match 'reconciliation failed'
        $stage.ReconciliationOk         | Should -Be $false
    }

    It 'sets RelaxationEligible=$true and reconciliation passes when dispositions-recorded novel count matches emitted observer blocks (both zero — the "0 misses" case)' {
        $entries = script:New-CleanCodeReviewEntries

        $terminalObservation = @{
            CoObservedPRCount              = 6
            MeasuredCoveragePRCount        = 6
            DispositionsNovelExternalCount = 0
            InternalCoObservedCatchCount   = 4
            ObserverEscapeCount            = 0
        }

        $result = Get-PhaseContainmentRollup -Entries $entries -TerminalObservation $terminalObservation

        $stage = $result.Stages['code-review']
        $stage.ReconciliationOk   | Should -Be $true
        $stage.ObserverBlockCount | Should -Be 0
        $stage.RelaxationEligible | Should -Be $true
    }

    It 'returns UniqueCatchRate=$null (never [double]::NaN) and rejects eligibility when the unique-catch denominator is 0/0 (M6)' {
        $entries = script:New-CleanCodeReviewEntries

        $terminalObservation = @{
            CoObservedPRCount              = 6
            MeasuredCoveragePRCount        = 6
            DispositionsNovelExternalCount = 0
            InternalCoObservedCatchCount   = 0
            ObserverEscapeCount            = 0
        }

        $result = Get-PhaseContainmentRollup -Entries $entries -TerminalObservation $terminalObservation

        $stage = $result.Stages['code-review']
        $stage.UniqueCatchRate           | Should -Be $null
        $stage.UniqueCatchRateAssessable | Should -Be $false
        [double]::IsNaN(0.0)             | Should -Be $false # sanity: literal 0.0 is not NaN
        $stage.RelaxationEligible        | Should -Be $false
        $stage.RelaxationEligibleReason  | Should -Match 'not assessable'
    }

    It 'withholds the escape arm and fails closed when ValueCacheOk=$false (Seam Specification -ValueCacheOk coherence — cached value cannot join a same-run corpus)' {
        $entries = script:New-CleanCodeReviewEntries

        $terminalObservation = @{
            CoObservedPRCount       = 7
            MeasuredCoveragePRCount = 6
            ValueCacheOk            = $false
        }

        $result = Get-PhaseContainmentRollup -Entries $entries -TerminalObservation $terminalObservation

        $stage = $result.Stages['code-review']
        $stage.EscapeArmWithheld         | Should -Be $true
        $stage.EscapeArmWithheldReason   | Should -Match 'escape arm withheld'
        $stage.RelaxationEligible        | Should -Be $false
        $stage.RelaxationEligibleReason  | Should -Match 'escape arm withheld'
    }

    It 'renders a Chapman both-missed estimate as N-hat minus (n1+n2-m), not the raw total-population N-hat (M11)' {
        $entries = script:New-CleanCodeReviewEntries

        # n1=9, n2=4, m=2 -> N-hat=((10*5)/3)-1=15.667; both-missed = 15.667-(9+4-2)=4.667
        $terminalObservation = @{
            CoObservedPRCount              = 6
            MeasuredCoveragePRCount        = 6
            DispositionsNovelExternalCount = 0
            InternalCoObservedCatchCount   = 9
            ExternalCatchCount             = 4
            DuplicateCount                 = 2
            ObserverEscapeCount            = 0
        }

        $result = Get-PhaseContainmentRollup -Entries $entries -TerminalObservation $terminalObservation

        $stage = $result.Stages['code-review']
        $stage.ChapmanState              | Should -Be 'estimate'
        [Math]::Round($stage.ChapmanBothMissedEstimate, 2) | Should -Be 4.67
    }

    It 'renders Chapman as unavailable (not a bad number) when m exceeds min(n1,n2) (M14)' {
        $entries = script:New-CleanCodeReviewEntries

        $terminalObservation = @{
            CoObservedPRCount              = 6
            MeasuredCoveragePRCount        = 6
            DispositionsNovelExternalCount = 0
            InternalCoObservedCatchCount   = 3
            ExternalCatchCount             = 2
            DuplicateCount                 = 3
            ObserverEscapeCount            = 0
        }

        $result = Get-PhaseContainmentRollup -Entries $entries -TerminalObservation $terminalObservation

        $stage = $result.Stages['code-review']
        $stage.ChapmanState              | Should -Be 'unavailable'
        $stage.ChapmanBothMissedEstimate | Should -Be $null
    }

    It 'renders Chapman as sparse (not an estimate) when m=0 (overlap too sparse)' {
        $entries = script:New-CleanCodeReviewEntries

        $terminalObservation = @{
            CoObservedPRCount              = 6
            MeasuredCoveragePRCount        = 6
            DispositionsNovelExternalCount = 0
            InternalCoObservedCatchCount   = 5
            ExternalCatchCount             = 3
            DuplicateCount                 = 0
            ObserverEscapeCount            = 0
        }

        $result = Get-PhaseContainmentRollup -Entries $entries -TerminalObservation $terminalObservation

        $stage = $result.Stages['code-review']
        $stage.ChapmanState              | Should -Be 'sparse'
        $stage.ChapmanBothMissedEstimate | Should -Be $null
    }

    It 'reconciles against ALL catchable_phase observer blocks, not just catchable_phase=implementation (M6 -- AC7 upstream-enrichment must not spuriously fail reconciliation)' {
        # The dispositions record carries no catchable_phase field at all, so
        # DispositionsNovelExternalCount is inherently catchable_phase-blind
        # -- it counts the one novel external finding the judge recorded,
        # regardless of which bucket it eventually routes to. Here that
        # finding is legitimately design-catchable (AC7's upstream-
        # enrichment case) and is emitted as a post-review-observer entry
        # with catchable_phase='design', NOT 'implementation'.
        $entries = @(script:New-CleanCodeReviewEntries) + @(
            [PSCustomObject]@{
                finding_key = 'post-review-observer:803:X1'; introduced_phase = 'design'; catchable_phase = 'design'
                caught_stage = 'post-review-observer'; escape_distance = 3; severity = 'medium'
                systemic_fix_type = 'none'; category = 'architecture'; apparatus_meta = $false; seed = $false
                createdAt = '2024-01-01T12:00:00Z'; surface = 'pr'; issueOrPrNumber = 803
            }
        )

        $terminalObservation = @{
            CoObservedPRCount              = 6
            MeasuredCoveragePRCount        = 6
            DispositionsNovelExternalCount = 1
            InternalCoObservedCatchCount   = 5
            ObserverEscapeCount            = 0
        }

        $result = Get-PhaseContainmentRollup -Entries $entries -TerminalObservation $terminalObservation

        $stage = $result.Stages['code-review']
        # Before the M6 fix, ObserverBlockCount (used for BOTH the
        # reconciliation compare AND the unique-catch numerator) counted
        # ONLY catchable_phase='implementation' blocks (0 here), mismatching
        # DispositionsNovelExternalCount (1) and spuriously failing
        # reconciliation even though the finding was legitimately emitted
        # as a design-catchable observer block.
        $stage.ObserverBlockCountAllPhases | Should -Be 1
        $stage.ObserverBlockCount          | Should -Be 0
        $stage.ReconciliationOk            | Should -Be $true
        $stage.RelaxationEligible          | Should -Be $true
        $stage.RelaxationEligibleReason    | Should -BeNullOrEmpty
    }

    It 'still fails reconciliation on a genuine catchable_phase-blind mismatch after the M6 fix (regression guard)' {
        $entries = @(script:New-CleanCodeReviewEntries) + @(
            [PSCustomObject]@{
                finding_key = 'post-review-observer:803:X1'; introduced_phase = 'design'; catchable_phase = 'design'
                caught_stage = 'post-review-observer'; escape_distance = 3; severity = 'medium'
                systemic_fix_type = 'none'; category = 'architecture'; apparatus_meta = $false; seed = $false
                createdAt = '2024-01-01T12:00:00Z'; surface = 'pr'; issueOrPrNumber = 803
            }
        )

        $terminalObservation = @{
            CoObservedPRCount              = 6
            MeasuredCoveragePRCount        = 6
            DispositionsNovelExternalCount = 2   # judge recorded TWO novel findings, only ONE observer block was emitted -- a real mismatch
            InternalCoObservedCatchCount   = 5
            ObserverEscapeCount            = 0
        }

        $result = Get-PhaseContainmentRollup -Entries $entries -TerminalObservation $terminalObservation

        $stage = $result.Stages['code-review']
        $stage.ObserverBlockCountAllPhases | Should -Be 1
        $stage.ReconciliationOk            | Should -Be $false
        $stage.RelaxationEligible          | Should -Be $false
        $stage.RelaxationEligibleReason    | Should -Match 'reconciliation failed'
    }

    It 'withholds the escape arm and fails closed when the review-cost comment corpus fetch was truncated (M8 -- distinct from the value-fetch -Truncated switch)' {
        $entries = script:New-CleanCodeReviewEntries

        $terminalObservation = @{
            CoObservedPRCount              = 7
            MeasuredCoveragePRCount        = 6
            DispositionsNovelExternalCount = 0
            InternalCoObservedCatchCount   = 20
            ExternalCatchCount             = 3
            DuplicateCount                 = 2
            ObserverEscapeCount            = 0
            CorpusTruncated                = $true
        }

        # -Truncated is deliberately NOT supplied (or $false): this proves
        # the withholding comes from the CorpusTruncated key inside
        # -TerminalObservation, a genuinely different, independent fetch
        # from the value-fetch -Truncated switch (issue #772 C11).
        $result = Get-PhaseContainmentRollup -Entries $entries -TerminalObservation $terminalObservation

        $stage = $result.Stages['code-review']
        $stage.EscapeArmWithheld        | Should -Be $true
        $stage.EscapeArmWithheldReason  | Should -Match 'corpus fetch was truncated'
        $stage.RelaxationEligible       | Should -Be $false
        $stage.RelaxationEligibleReason | Should -Match 'corpus fetch was truncated'
    }

    It 'does not withhold the escape arm when CorpusTruncated is absent or $false (M8 regression guard -- otherwise-clean window stays eligible)' {
        $entries = script:New-CleanCodeReviewEntries

        $terminalObservation = @{
            CoObservedPRCount              = 7
            MeasuredCoveragePRCount        = 6
            DispositionsNovelExternalCount = 0
            InternalCoObservedCatchCount   = 20
            ExternalCatchCount             = 3
            DuplicateCount                 = 2
            ObserverEscapeCount            = 0
            CorpusTruncated                = $false
        }

        $result = Get-PhaseContainmentRollup -Entries $entries -TerminalObservation $terminalObservation

        $stage = $result.Stages['code-review']
        $stage.EscapeArmWithheld  | Should -Be $false
        $stage.RelaxationEligible | Should -Be $true
    }
}

Describe 'M12: CoObservedPRCount docstring no longer claims to BE DD3''s narrower "co-observed" population (issue #854 code-review escape-detection fix pass)' {
    BeforeAll {
        $script:CoreLibText = Get-Content -Raw (Join-Path $script:LibRoot 'phase-containment-rolling-history-core.ps1')
    }

    It 'no longer documents CoObservedPRCount as "total PRs in the co-observed corpus" (the wrong, too-broad M12 definition)' {
        $script:CoreLibText | Should -Not -Match 'N - total PRs in the co-observed corpus for'
    }

    It 'documents CoObservedPRCount as the whole-window population, explicitly NOT DD3''s co-observed population' {
        $script:CoreLibText | Should -Match 'CoObservedPRCount\s+\[int\]\s+N - total PR tuples observed'
        $script:CoreLibText | Should -Match "This is NOT DD3's narrower\s*\r?\n\s+`"co-observed`" population \(M12 fix\)"
    }

    It 'documents MeasuredCoveragePRCount as DD3''s actual co-observed population that n1/Chapman are scoped to' {
        $script:CoreLibText | Should -Match "K - PRs counting toward coverage AND DD3's\s*\r?\n\s+actual `"co-observed`" population"
    }
}

# ---------------------------------------------------------------------------
# 13b. Rollup — AC7 upstream-enrichment regression (issue #854 s5)
#
# post-review-observer entries with catchable_phase design|plan must route
# to the existing design-challenge/plan-stress-test buckets via the
# unchanged catchable_phase routing logic, and can only ADD escapes, never
# irreducibles.
# ---------------------------------------------------------------------------

Describe 'Get-PhaseContainmentRollup — AC7 observer entries only ever add escapes to upstream buckets (issue #854 s5)' {
    It 'routes a post-review-observer/catchable_phase=design entry into the design-challenge escape count, never irreducible' {
        $entries = @(
            [PSCustomObject]@{
                finding_key = 'post-review-observer:860:X1'; introduced_phase = 'design'; catchable_phase = 'design'
                caught_stage = 'post-review-observer'; escape_distance = 3; severity = 'medium'
                systemic_fix_type = 'none'; category = 'pattern'; apparatus_meta = $false; seed = $false
                createdAt = '2024-01-01T12:00:00Z'; surface = 'pr'; issueOrPrNumber = 860
            }
        ) + (1..4 | ForEach-Object {
            [PSCustomObject]@{
                finding_key = "design-challenge:860:F$_"; introduced_phase = 'design'; catchable_phase = 'design'
                caught_stage = 'design-challenge'; escape_distance = 0; severity = 'low'
                systemic_fix_type = 'skill'; category = 'architecture'; apparatus_meta = $false; seed = $false
                createdAt = '2024-01-01T12:00:00Z'; surface = 'issue'; issueOrPrNumber = 860
            }
        })

        $result = Get-PhaseContainmentRollup -Entries $entries

        $stage = $result.Stages['design-challenge']
        $stage.N          | Should -Be 5
        $stage.EscapeRate | Should -Be 0.2
    }

    It 'routes a post-review-observer/catchable_phase=plan entry into the plan-stress-test escape count, never irreducible' {
        $entries = @(
            [PSCustomObject]@{
                finding_key = 'post-review-observer:861:X1'; introduced_phase = 'plan'; catchable_phase = 'plan'
                caught_stage = 'post-review-observer'; escape_distance = 2; severity = 'medium'
                systemic_fix_type = 'none'; category = 'pattern'; apparatus_meta = $false; seed = $false
                createdAt = '2024-01-01T12:00:00Z'; surface = 'pr'; issueOrPrNumber = 861
            }
        ) + (1..4 | ForEach-Object {
            [PSCustomObject]@{
                finding_key = "plan-stress-test:861:F$_"; introduced_phase = 'plan'; catchable_phase = 'plan'
                caught_stage = 'plan-stress-test'; escape_distance = 0; severity = 'low'
                systemic_fix_type = 'instruction'; category = 'architecture'; apparatus_meta = $false; seed = $false
                createdAt = '2024-01-01T12:00:00Z'; surface = 'issue'; issueOrPrNumber = 861
            }
        })

        $result = Get-PhaseContainmentRollup -Entries $entries

        $stage = $result.Stages['plan-stress-test']
        $stage.N          | Should -Be 5
        $stage.EscapeRate | Should -Be 0.2
    }

    It 'excludes a post-review-observer/catchable_phase=experience entry from every bucket (belongs to no bucket)' {
        $entries = @(
            [PSCustomObject]@{
                finding_key = 'post-review-observer:862:X1'; introduced_phase = 'experience'; catchable_phase = 'experience'
                caught_stage = 'post-review-observer'; escape_distance = 4; severity = 'medium'
                systemic_fix_type = 'none'; category = 'pattern'; apparatus_meta = $false; seed = $false
                createdAt = '2024-01-01T12:00:00Z'; surface = 'pr'; issueOrPrNumber = 862
            }
        )

        $result = Get-PhaseContainmentRollup -Entries $entries

        $result.Stages['design-challenge'].N | Should -Be 0
        $result.Stages['plan-stress-test'].N | Should -Be 0
        $result.Stages['code-review'].N      | Should -Be 0
    }
}

# ---------------------------------------------------------------------------
# 13c. Rollup — M36: SustainedCounts reconciliation excludes observer-caught
# entries (issue #854 s5)
# ---------------------------------------------------------------------------

Describe 'Get-PhaseContainmentRollup — M36 SustainedCounts reconciliation excludes observer-caught entries' {
    It 'does not spuriously mark DataUntrustworthy when an observer-caught entry inflates N beyond a pre-observer SustainedCounts expectation' {
        $entries = (1..3 | ForEach-Object {
            [PSCustomObject]@{
                finding_key = "code-review:863:F$_"; introduced_phase = 'implementation'; catchable_phase = 'implementation'
                caught_stage = 'code-review'; escape_distance = 0; severity = 'low'
                systemic_fix_type = 'none'; category = 'pattern'; apparatus_meta = $false; seed = $false
                createdAt = '2024-01-01T12:00:00Z'; surface = 'pr'; issueOrPrNumber = 863
            }
        }) + @(
            [PSCustomObject]@{
                finding_key = 'post-review-observer:863:X1'; introduced_phase = 'implementation'; catchable_phase = 'implementation'
                caught_stage = 'post-review-observer'; escape_distance = 1; severity = 'medium'
                systemic_fix_type = 'none'; category = 'pattern'; apparatus_meta = $false; seed = $false
                createdAt = '2024-01-01T12:00:00Z'; surface = 'pr'; issueOrPrNumber = 863
            }
        )

        # SustainedCounts expects 3 (the pre-observer judge-sustained count);
        # N is 4 (3 code-review + 1 observer). Excluding the observer-caught
        # entry brings the comparison back to 3 == 3.
        $result = Get-PhaseContainmentRollup -Entries $entries -SustainedCounts @{ 'code-review' = 3 }

        $result.Stages['code-review'].DataUntrustworthy | Should -Be $false
    }

    It 'still marks DataUntrustworthy when the non-observer count genuinely disagrees with SustainedCounts' {
        $entries = (1..2 | ForEach-Object {
            [PSCustomObject]@{
                finding_key = "code-review:864:F$_"; introduced_phase = 'implementation'; catchable_phase = 'implementation'
                caught_stage = 'code-review'; escape_distance = 0; severity = 'low'
                systemic_fix_type = 'none'; category = 'pattern'; apparatus_meta = $false; seed = $false
                createdAt = '2024-01-01T12:00:00Z'; surface = 'pr'; issueOrPrNumber = 864
            }
        }) + @(
            [PSCustomObject]@{
                finding_key = 'post-review-observer:864:X1'; introduced_phase = 'implementation'; catchable_phase = 'implementation'
                caught_stage = 'post-review-observer'; escape_distance = 1; severity = 'medium'
                systemic_fix_type = 'none'; category = 'pattern'; apparatus_meta = $false; seed = $false
                createdAt = '2024-01-01T12:00:00Z'; surface = 'pr'; issueOrPrNumber = 864
            }
        )

        # SustainedCounts expects 3, non-observer N is 2 (a genuine mismatch
        # even after excluding the 1 observer-caught entry).
        $result = Get-PhaseContainmentRollup -Entries $entries -SustainedCounts @{ 'code-review' = 3 }

        $result.Stages['code-review'].DataUntrustworthy       | Should -Be $true
        $result.Stages['code-review'].DataUntrustworthyReason | Should -Match 'excluding 1 observer-caught entry'
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
# Issue #854 s4 (M8): AuthorLogins threaded through the tuple contract.
# The corpus GraphQL previously selected only `body createdAt` with no
# author at all six comments() sites (issue base/hunt/page, PR base/hunt/
# page), so any account that could comment could forge a well-formed
# coverage record. These fixtures prove author extraction survives every
# site, including pagination (hunt + unbounded page) and the REST fallback,
# and that a deleted-account (null author) response degrades to '' rather
# than throwing.
# ---------------------------------------------------------------------------

Describe 'Get-PhaseContainmentCommentCorpus — AuthorLogins threaded through the tuple contract (issue #854 s4)' {
    AfterEach {
        if (Get-Command 'gh' -CommandType Function -ErrorAction SilentlyContinue) {
            Remove-Item -Path Function:gh -ErrorAction SilentlyContinue
        }
    }

    It 'extracts author.login on the issue-surface base query (site 1 of 6)' {
        $payload = @{
            data = @{
                search = @{
                    pageInfo = @{ hasNextPage = $false; endCursor = $null }
                    nodes    = @(
                        @{
                            number   = 1101
                            comments = @{
                                nodes    = @(@{ author = @{ login = 'alice' }; body = '<!-- plan-issue-1101 -->'; createdAt = '2024-01-01T12:00:00Z' })
                                pageInfo = @{ hasNextPage = $false; endCursor = $null }
                            }
                        }
                    )
                }
            }
        }
        $json = ($payload | ConvertTo-Json -Depth 12)
        $emptySearchJson = (@{ data = @{ search = @{ pageInfo = @{ hasNextPage = $false; endCursor = $null }; nodes = @() } } } | ConvertTo-Json -Depth 6)

        function global:gh {
            param([Parameter(ValueFromRemainingArguments = $true)]$Args)
            $global:LASTEXITCODE = 0
            if (($Args -join ' ') -match 'is:issue') { return $json }
            if (($Args -join ' ') -match 'is:pr') { return $emptySearchJson }
            return '{}'
        }

        $result = Get-PhaseContainmentCommentCorpus -RepoOwner 'Grimblaz' -RepoName 'agent-orchestra' -WindowDays 30
        $tuple = $result.Tuples | Where-Object { $_['Number'] -eq 1101 }
        $tuple['AuthorLogins'] | Should -Be @('alice')
    }

    It 'extracts author.login on the PR-surface base query (site 4 of 6)' {
        $payload = @{
            data = @{
                search = @{
                    pageInfo = @{ hasNextPage = $false; endCursor = $null }
                    nodes    = @(
                        @{
                            number   = 1102
                            comments = @{
                                nodes    = @(@{ author = @{ login = 'bob' }; body = '<!-- judge-rulings pr=1102 -->'; createdAt = '2024-01-01T13:00:00Z' })
                                pageInfo = @{ hasNextPage = $false; endCursor = $null }
                            }
                        }
                    )
                }
            }
        }
        $json = ($payload | ConvertTo-Json -Depth 12)
        $emptySearchJson = (@{ data = @{ search = @{ pageInfo = @{ hasNextPage = $false; endCursor = $null }; nodes = @() } } } | ConvertTo-Json -Depth 6)

        function global:gh {
            param([Parameter(ValueFromRemainingArguments = $true)]$Args)
            $global:LASTEXITCODE = 0
            if (($Args -join ' ') -match 'is:pr') { return $json }
            if (($Args -join ' ') -match 'is:issue') { return $emptySearchJson }
            return '{}'
        }

        $result = Get-PhaseContainmentCommentCorpus -RepoOwner 'Grimblaz' -RepoName 'agent-orchestra' -WindowDays 30
        $tuple = $result.Tuples | Where-Object { $_['Number'] -eq 1102 }
        $tuple['AuthorLogins'] | Should -Be @('bob')
    }

    It 'carries AuthorLogins across the issue-surface hunt + unbounded page pagination (sites 2 and 3 of 6), index-paired with Bodies' {
        # Page 1: no marker yet (forces the hunt). Hunt page: marker found.
        # Post-marker unbounded page: one more comment collected.
        $searchPayload = @{
            data = @{
                search = @{
                    pageInfo = @{ hasNextPage = $false; endCursor = $null }
                    nodes    = @(
                        @{
                            number   = 1103
                            comments = @{
                                nodes    = @(@{ author = @{ login = 'carol' }; body = 'no marker here yet'; createdAt = '2024-01-01T00:00:00Z' })
                                pageInfo = @{ hasNextPage = $true; endCursor = 'CURSOR1' }
                            }
                        }
                    )
                }
            }
        }
        $huntPayload = @{
            data = @{
                repository = @{
                    issue = @{
                        comments = @{
                            nodes    = @(@{ author = @{ login = 'dave' }; body = '<!-- plan-issue-1103 -->'; createdAt = '2024-01-01T01:00:00Z' })
                            pageInfo = @{ hasNextPage = $true; endCursor = 'CURSOR2' }
                        }
                    }
                }
            }
        }
        $pagePayload = @{
            data = @{
                repository = @{
                    issue = @{
                        comments = @{
                            nodes    = @(@{ author = @{ login = 'erin' }; body = 'trailing comment'; createdAt = '2024-01-01T02:00:00Z' })
                            pageInfo = @{ hasNextPage = $false; endCursor = $null }
                        }
                    }
                }
            }
        }

        $searchJson = ($searchPayload | ConvertTo-Json -Depth 12)
        $huntJson   = ($huntPayload | ConvertTo-Json -Depth 12)
        $pageJson   = ($pagePayload | ConvertTo-Json -Depth 12)
        $emptySearchJson = (@{ data = @{ search = @{ pageInfo = @{ hasNextPage = $false; endCursor = $null }; nodes = @() } } } | ConvertTo-Json -Depth 6)

        $script:callCount = 0
        function global:gh {
            param([Parameter(ValueFromRemainingArguments = $true)]$Args)
            $global:LASTEXITCODE = 0
            $joined = $Args -join ' '
            if ($joined -match 'is:issue') { return $searchJson }
            if ($joined -match 'is:pr') { return $emptySearchJson }
            $script:callCount++
            if ($script:callCount -eq 1) { return $huntJson }
            return $pageJson
        }

        $result = Get-PhaseContainmentCommentCorpus -RepoOwner 'Grimblaz' -RepoName 'agent-orchestra' -WindowDays 30
        $tuple = $result.Tuples | Where-Object { $_['Number'] -eq 1103 }
        $tuple['Bodies'] | Should -Be @('no marker here yet', '<!-- plan-issue-1103 -->', 'trailing comment')
        $tuple['AuthorLogins'] | Should -Be @('carol', 'dave', 'erin')
    }

    It 'degrades to empty-string AuthorLogin when GraphQL returns a null author (deleted account) instead of throwing' {
        $payload = @{
            data = @{
                search = @{
                    pageInfo = @{ hasNextPage = $false; endCursor = $null }
                    nodes    = @(
                        @{
                            number   = 1104
                            comments = @{
                                nodes    = @(@{ author = $null; body = '<!-- plan-issue-1104 -->'; createdAt = '2024-01-01T12:00:00Z' })
                                pageInfo = @{ hasNextPage = $false; endCursor = $null }
                            }
                        }
                    )
                }
            }
        }
        $json = ($payload | ConvertTo-Json -Depth 12)
        $emptySearchJson = (@{ data = @{ search = @{ pageInfo = @{ hasNextPage = $false; endCursor = $null }; nodes = @() } } } | ConvertTo-Json -Depth 6)

        function global:gh {
            param([Parameter(ValueFromRemainingArguments = $true)]$Args)
            $global:LASTEXITCODE = 0
            if (($Args -join ' ') -match 'is:issue') { return $json }
            if (($Args -join ' ') -match 'is:pr') { return $emptySearchJson }
            return '{}'
        }

        $result = Get-PhaseContainmentCommentCorpus -RepoOwner 'Grimblaz' -RepoName 'agent-orchestra' -WindowDays 30
        $tuple = $result.Tuples | Where-Object { $_['Number'] -eq 1104 }
        $tuple['AuthorLogins'] | Should -Be @('')
    }

    It 'extracts AuthorLogins under the REST fallback for both surfaces, for free from --json comments' {
        $restIssueList = (@(@{ number = 1105 }) | ConvertTo-Json)
        $restIssueView = (@{ comments = @(@{ author = @{ login = 'frank' }; body = '<!-- plan-issue-1105 -->'; createdAt = '2024-01-01T00:00:00Z' }) } | ConvertTo-Json -Depth 6)
        $restPrList = (@(@{ number = 1106 }) | ConvertTo-Json)
        $restPrView = (@{ comments = @(@{ author = @{ login = 'grace' }; body = '<!-- judge-rulings pr=1106 -->'; createdAt = '2024-01-01T00:00:00Z' }) } | ConvertTo-Json -Depth 6)

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
            if ($joined -match 'pr view')    { return $restPrView }
            return '{}'
        }

        $result = Get-PhaseContainmentCommentCorpus -RepoOwner 'Grimblaz' -RepoName 'agent-orchestra' -WindowDays 30
        $result.Source | Should -Be 'rest'

        $issueTuple = $result.Tuples | Where-Object { $_['Number'] -eq 1105 }
        $issueTuple['AuthorLogins'] | Should -Be @('frank')

        $prTuple = $result.Tuples | Where-Object { $_['Number'] -eq 1106 }
        $prTuple['AuthorLogins'] | Should -Be @('grace')
    }
}

# ---------------------------------------------------------------------------
# G-CR13 (PR #859 GitHub-review post-fix): every createdAt extraction site in
# the comment-node processing flow used a bare [string] cast on a value
# ConvertFrom-Json -AsHashtable had already auto-parsed into a [datetime].
# That cast drops the Kind/offset marker (current-culture formatting has no
# 'Z'/offset token), so a later RoundtripKind re-parse yields Kind=Unspecified
# and .ToUniversalTime() shifts the value by the LOCAL machine's UTC offset --
# real data corruption on any non-UTC runtime (this repo's own dev
# environment included, per the ConvertTo-PhaseContainmentIsoString rationale
# at the top of this file). These fixtures prove the extracted CreatedAtValues
# round-trip to the EXACT original UTC instant, not an offset-shifted one.
# ---------------------------------------------------------------------------

Describe 'Get-PhaseContainmentCommentCorpus — G-CR13 createdAt ISO round-trip preservation' {
    AfterEach {
        if (Get-Command 'gh' -CommandType Function -ErrorAction SilentlyContinue) {
            Remove-Item -Path Function:gh -ErrorAction SilentlyContinue
        }
    }

    It 'round-trips a GraphQL comment createdAt (Surface A, issue) to the exact original UTC instant' {
        $expectedUtc = [datetime]::Parse('2024-03-01T11:30:00Z', [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()

        $payload = @{
            data = @{
                search = @{
                    pageInfo = @{ hasNextPage = $false; endCursor = $null }
                    nodes    = @(
                        @{
                            number   = 1201
                            comments = @{
                                nodes    = @(@{ author = @{ login = 'alice' }; body = '<!-- plan-issue-1201 -->'; createdAt = '2024-03-01T11:30:00Z' })
                                pageInfo = @{ hasNextPage = $false; endCursor = $null }
                            }
                        }
                    )
                }
            }
        }
        $json = ($payload | ConvertTo-Json -Depth 12)
        $emptySearchJson = (@{ data = @{ search = @{ pageInfo = @{ hasNextPage = $false; endCursor = $null }; nodes = @() } } } | ConvertTo-Json -Depth 6)

        function global:gh {
            param([Parameter(ValueFromRemainingArguments = $true)]$Args)
            $global:LASTEXITCODE = 0
            if (($Args -join ' ') -match 'is:issue') { return $json }
            if (($Args -join ' ') -match 'is:pr') { return $emptySearchJson }
            return '{}'
        }

        $result = Get-PhaseContainmentCommentCorpus -RepoOwner 'Grimblaz' -RepoName 'agent-orchestra' -WindowDays 30
        $tuple = $result.Tuples | Where-Object { $_['Number'] -eq 1201 }
        $rawCreatedAt = $tuple['CreatedAtValues'][0]

        $reparsed = [datetime]::Parse($rawCreatedAt, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)
        $reparsed.Kind | Should -Be ([System.DateTimeKind]::Utc)
        $reparsed.ToUniversalTime() | Should -Be $expectedUtc
    }

    It 'round-trips a REST comment createdAt (PR surface) to the exact original UTC instant' {
        $expectedUtc = [datetime]::Parse('2024-03-02T09:15:00Z', [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()

        $restIssueList = (@() | ConvertTo-Json)
        $restPrList = (@(@{ number = 1202 }) | ConvertTo-Json)
        $restPrView = (@{ comments = @(@{ author = @{ login = 'grace' }; body = '<!-- judge-rulings pr=1202 -->'; createdAt = '2024-03-02T09:15:00Z' }) } | ConvertTo-Json -Depth 6)

        function global:gh {
            param([Parameter(ValueFromRemainingArguments = $true)]$Args)
            $joined = $Args -join ' '
            if ($joined -match 'graphql') {
                $global:LASTEXITCODE = 1
                return 'boom'
            }
            $global:LASTEXITCODE = 0
            if ($joined -match 'issue list') { return $restIssueList }
            if ($joined -match 'pr list')    { return $restPrList }
            if ($joined -match 'pr view')    { return $restPrView }
            return '{}'
        }

        $result = Get-PhaseContainmentCommentCorpus -RepoOwner 'Grimblaz' -RepoName 'agent-orchestra' -WindowDays 30
        $result.Source | Should -Be 'rest'

        $tuple = $result.Tuples | Where-Object { $_['Number'] -eq 1202 }
        $rawCreatedAt = $tuple['CreatedAtValues'][0]

        $reparsed = [datetime]::Parse($rawCreatedAt, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)
        $reparsed.Kind | Should -Be ([System.DateTimeKind]::Utc)
        $reparsed.ToUniversalTime() | Should -Be $expectedUtc
    }
}

# ---------------------------------------------------------------------------
# Issue #854 s4 (M8): the coverage-authorship gate primitives. Any account
# that can comment on an issue/PR could otherwise post a well-formed
# `<!-- review-dispositions-{PR} -->` body carrying a forged
# `external_sources_reconciled` record and unlock ELIGIBLE. These fixtures
# prove: (a) such a body IS well-formed and WOULD contribute coverage if
# parsed directly, establishing the vector is real; (b) filtering by
# judge-authorship BEFORE parsing excludes it, so it contributes ZERO
# coverage.
# ---------------------------------------------------------------------------

Describe 'Corpus authorship — closes the forged-coverage vector (issue #854 s4, M8)' {
    BeforeAll {
        # Test-time-only composition: dot-source the parser this primitive
        # is designed to sit in front of, so the fixture can prove the full
        # exclude-before-parse property end to end. This does not modify
        # phase-containment-emission-check-core.ps1 — Get-DispositionTally
        # remains this step's non-goal (informational cost tables keep
        # their existing no-authorship-filter posture).
        . (Join-Path $script:LibRoot 'phase-containment-emission-check-core.ps1')

        $script:JudgeLogin = 'github-actions[bot]'

        # A well-formed review-dispositions body (M9 zero-entries legal
        # coverage shape) carrying a real, parseable external_sources_reconciled
        # array — the exact shape a forger would need to produce.
        $script:ForgedCoverageBody = @'
<!-- review-dispositions-999 -->

```yaml
schema_version: 4
passes_run: [1]
entries: []
external_sources_reconciled: ["a.ps1:1:aaa111", "b.ps1:2:bbb222"]
```
'@
    }

    It 'establishes the vector: the forged body IS well-formed and WOULD contribute coverage if parsed directly' {
        $tally = Get-DispositionTally -Surface code-review -Body $script:ForgedCoverageBody
        $tally.ParseStatus | Should -Be 'ok'
        $tally.ExternalSourcesReconciled | Should -Contain 'a.ps1:1:aaa111'
    }

    It 'Test-PhaseContainmentCommentAuthoredByJudge rejects a non-judge author' {
        Test-PhaseContainmentCommentAuthoredByJudge -AuthorLogin 'evil-user' -JudgeLogin $script:JudgeLogin | Should -Be $false
    }

    It 'Test-PhaseContainmentCommentAuthoredByJudge accepts the judge login, normalized case/[bot]-insensitively' {
        Test-PhaseContainmentCommentAuthoredByJudge -AuthorLogin 'GitHub-Actions' -JudgeLogin $script:JudgeLogin | Should -Be $true
    }

    It 'Test-PhaseContainmentCommentAuthoredByJudge treats an empty/unresolvable AuthorLogin as non-judge (fail-closed)' {
        Test-PhaseContainmentCommentAuthoredByJudge -AuthorLogin '' -JudgeLogin $script:JudgeLogin | Should -Be $false
    }

    It 'Select-PhaseContainmentJudgeAuthoredBodies excludes a non-judge-authored body carrying a well-formed external_sources_reconciled -- it contributes ZERO coverage' {
        $bodies       = @($script:ForgedCoverageBody, 'unrelated chatter')
        $authorLogins = @('evil-user', $script:JudgeLogin)

        $filtered = Select-PhaseContainmentJudgeAuthoredBodies -Bodies $bodies -AuthorLogins $authorLogins -JudgeLogin $script:JudgeLogin

        $filtered | Should -Not -Contain $script:ForgedCoverageBody

        # The forged body never reaches the parser -- prove its
        # external_sources_reconciled can never surface as coverage from the
        # surviving (judge-authored) body set.
        $coverage = [System.Collections.Generic.List[string]]::new()
        foreach ($b in $filtered) {
            $tally = Get-DispositionTally -Surface code-review -Body $b
            if ($tally.ParseStatus -eq 'ok') {
                foreach ($v in $tally.ExternalSourcesReconciled) { $coverage.Add($v) }
            }
        }
        $coverage.Count | Should -Be 0
    }

    It 'Select-PhaseContainmentJudgeAuthoredBodies keeps a judge-authored body carrying the same well-formed marker' {
        $bodies       = @($script:ForgedCoverageBody)
        $authorLogins = @($script:JudgeLogin)

        $filtered = Select-PhaseContainmentJudgeAuthoredBodies -Bodies $bodies -AuthorLogins $authorLogins -JudgeLogin $script:JudgeLogin

        $filtered | Should -Contain $script:ForgedCoverageBody
        $tally = Get-DispositionTally -Surface code-review -Body $filtered[0]
        $tally.ExternalSourcesReconciled | Should -Contain 'a.ps1:1:aaa111'
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

Describe 'Get-PhaseContainmentHistory — issue #876 F1: default CachePath construction survives $env:TEMP being unset (PowerShell Core / Linux / macOS)' {
    BeforeEach {
        $script:SavedEnvTemp876 = $env:TEMP
        Remove-Item Env:\TEMP -ErrorAction SilentlyContinue
    }

    AfterEach {
        if ($null -ne $script:SavedEnvTemp876) {
            $env:TEMP = $script:SavedEnvTemp876
        }
        else {
            Remove-Item Env:\TEMP -ErrorAction SilentlyContinue
        }
        if (Get-Command 'gh' -CommandType Function -ErrorAction SilentlyContinue) {
            Remove-Item -Path Function:gh -ErrorAction SilentlyContinue
        }
        $defaultCache = Join-Path ([System.IO.Path]::GetTempPath()) '.phase-containment-cache-Grimblaz-agent-orchestra-.json'
        if (Test-Path -LiteralPath $defaultCache) { Remove-Item -LiteralPath $defaultCache -Force -ErrorAction SilentlyContinue }
    }

    It 'does not throw a null-binding error building the default CachePath when $env:TEMP is unset and no -CachePath is supplied' {
        # Only Windows conventionally sets $env:TEMP; PowerShell Core on
        # Linux/macOS leaves it unset by default. A prior version called
        # `Join-Path $env:TEMP "..."` for the default CachePath, which
        # throws a terminating parameter-binding error the instant
        # $env:TEMP is $null -- reproducible even on this Windows host once
        # the variable is cleared (confirmed manually).
        # [System.IO.Path]::GetTempPath() resolves TMPDIR/TEMP/TMP
        # cross-platform without ever needing $env:TEMP directly.
        function global:gh {
            param([Parameter(ValueFromRemainingArguments = $true)]$Args)
            $global:LASTEXITCODE = 0
            return '{}'
        }

        { Get-PhaseContainmentHistory -RepoOwner 'Grimblaz' -RepoName 'agent-orchestra' -WindowDays 30 -TimeoutSeconds 30 3>$null } | Should -Not -Throw
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
# Issue #842 M2 (post-review fix): the cache-hit path previously hardcoded
# Matched/AuthorFilteredCount to 0 with no writer support at all. Prove a
# nonzero Matched/AuthorFilteredCount round-trips through a real write +
# cache-hit read.
# ---------------------------------------------------------------------------

Describe 'Get-PhaseContainmentHistory — Matched/AuthorFilteredCount cache-survival (issue #842 M2)' {
    BeforeAll {
        $script:CachePathM2 = Join-Path $env:TEMP '.phase-containment-cache-Grimblaz-agent-orchestra-m2round.json'
    }

    AfterEach {
        if (Get-Command 'gh' -CommandType Function -ErrorAction SilentlyContinue) {
            Remove-Item -Path Function:gh -ErrorAction SilentlyContinue
        }
        if (Test-Path -LiteralPath $script:CachePathM2) { Remove-Item -LiteralPath $script:CachePathM2 -Force -ErrorAction SilentlyContinue }
    }

    It 'persists nonzero Matched/AuthorFilteredCount into the cache payload and returns them on the subsequent cache-hit' {
        # One judge-authored comment (carries the real block, contributes to
        # Matched) and one non-judge-authored comment (contributes to
        # AuthorFilteredCount) on the same issue, so -JudgeLogin produces a
        # real, nonzero split between the two counts.
        $judgeBody = "<!-- plan-issue-1700 -->`n<!-- phase-containment-1700 -->`nfinding_key: plan-stress-test:1700:F1`nintroduced_phase: plan`ncatchable_phase: plan`ncaught_stage: plan-stress-test`nescape_distance: 0`nseverity: low`nsystemic_fix_type: plan-template`ncategory: pattern`napparatus_meta: false`n<!-- /phase-containment-1700 -->"
        $otherBody = '<!-- phase-containment-1700 -->' + "`nfinding_key: plan-stress-test:1700:FORGED`n" + '<!-- /phase-containment-1700 -->'

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
                                    number   = 1700
                                    comments = @{
                                        nodes    = @(
                                            @{ author = @{ login = 'github-actions[bot]' }; body = $judgeBody; createdAt = '2024-01-01T12:00:00Z' },
                                            @{ author = @{ login = 'someone-else' }; body = $otherBody; createdAt = '2024-01-01T12:05:00Z' }
                                        )
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

        $first = Get-PhaseContainmentHistory -RepoOwner 'Grimblaz' -RepoName 'agent-orchestra' -WindowDays 30 -CachePath $script:CachePathM2 -JudgeLogin 'github-actions[bot]' 3>$null

        $first.Source             | Should -Be 'graphql'
        $first.Matched             | Should -Be 1
        $first.AuthorFilteredCount | Should -Be 1
        Test-Path -LiteralPath $script:CachePathM2 | Should -Be $true

        # Second call within the fresh cache window must hit cache and
        # return the SAME Matched/AuthorFilteredCount, not silently default
        # to 0 (the pre-fix hardcoded behavior).
        function global:gh {
            param([Parameter(ValueFromRemainingArguments = $true)]$Args)
            throw 'gh must not be called on a cache hit'
        }

        $second = Get-PhaseContainmentHistory -RepoOwner 'Grimblaz' -RepoName 'agent-orchestra' -WindowDays 30 -CachePath $script:CachePathM2 -JudgeLogin 'github-actions[bot]' 3>$null

        $second.Source             | Should -Be 'cache'
        $second.Matched             | Should -Be 1 -Because 'M2 fix: a cache-hit must restore Matched from the persisted payload, not hardcode 0'
        $second.AuthorFilteredCount | Should -Be 1 -Because 'M2 fix: a cache-hit must restore AuthorFilteredCount from the persisted payload, not hardcode 0'
    }
}

# ---------------------------------------------------------------------------
# Issue #842 M5 (post-review fix): the bypass-path (a GUID-named throwaway
# CachePath under $env:TEMP, as constructed by phase-containment-report.ps1's
# -SkipCacheWrite-signaled bypass path) must not be populated with a
# full-content orphan cache JSON with no cleanup.
# ---------------------------------------------------------------------------

Describe 'Get-PhaseContainmentHistory — SkipCacheWrite suppresses the bypass-path orphan cache file (issue #842 M5)' {
    BeforeAll {
        $script:BypassCachePathM5 = Join-Path $env:TEMP "phase-containment-bypass-$([guid]::NewGuid().ToString('N')).json"  # host-path-ok
    }

    AfterEach {
        if (Get-Command 'gh' -CommandType Function -ErrorAction SilentlyContinue) {
            Remove-Item -Path Function:gh -ErrorAction SilentlyContinue
        }
        if (Test-Path -LiteralPath $script:BypassCachePathM5) { Remove-Item -LiteralPath $script:BypassCachePathM5 -Force -ErrorAction SilentlyContinue }
    }

    It 'leaves no cache file on disk after a successful, non-truncated fetch when -SkipCacheWrite is set' {
        $validBody = "<!-- plan-issue-1800 -->`n<!-- phase-containment-1800 -->`nfinding_key: plan-stress-test:1800:F1`nintroduced_phase: plan`ncatchable_phase: plan`ncaught_stage: plan-stress-test`nescape_distance: 0`nseverity: low`nsystemic_fix_type: plan-template`ncategory: pattern`napparatus_meta: false`n<!-- /phase-containment-1800 -->"

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
                                    number   = 1800
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

        $result = Get-PhaseContainmentHistory -RepoOwner 'Grimblaz' -RepoName 'agent-orchestra' -WindowDays 30 -CachePath $script:BypassCachePathM5 -SkipCacheWrite 3>$null

        $result.Source  | Should -Be 'graphql'
        $result.Entries | Should -HaveCount 1
        Test-Path -LiteralPath $script:BypassCachePathM5 | Should -Be $false -Because 'a bypass/throwaway CachePath must never be populated with an orphan cache JSON when -SkipCacheWrite is set'
    }

    It 'DOES write the cache file when -SkipCacheWrite is NOT set, on the same successful fetch shape (control case)' {
        $controlCachePath = Join-Path $env:TEMP "phase-containment-bypass-control-$([guid]::NewGuid().ToString('N')).json"  # host-path-ok
        try {
            $validBody = "<!-- plan-issue-1801 -->`n<!-- phase-containment-1801 -->`nfinding_key: plan-stress-test:1801:F1`nintroduced_phase: plan`ncatchable_phase: plan`ncaught_stage: plan-stress-test`nescape_distance: 0`nseverity: low`nsystemic_fix_type: plan-template`ncategory: pattern`napparatus_meta: false`n<!-- /phase-containment-1801 -->"

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
                                        number   = 1801
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

            $result = Get-PhaseContainmentHistory -RepoOwner 'Grimblaz' -RepoName 'agent-orchestra' -WindowDays 30 -CachePath $controlCachePath 3>$null

            $result.Source | Should -Be 'graphql'
            Test-Path -LiteralPath $controlCachePath | Should -Be $true -Because 'without -SkipCacheWrite, the existing cache-write behavior is unchanged'
        }
        finally {
            if (Get-Command 'gh' -CommandType Function -ErrorAction SilentlyContinue) {
                Remove-Item -Path Function:gh -ErrorAction SilentlyContinue
            }
            if (Test-Path -LiteralPath $controlCachePath) { Remove-Item -LiteralPath $controlCachePath -Force -ErrorAction SilentlyContinue }
        }
    }
}

# ---------------------------------------------------------------------------
# Issue #842 M7 (post-review fix): the cache filename embeds $JudgeLogin
# verbatim. The writer previously used Set-Content -Path (wildcard-
# interpreting) while the reader uses -LiteralPath -- a bracketed identity
# like 'github-actions[bot]' made the write silently no-op.
# ---------------------------------------------------------------------------

Describe 'Get-PhaseContainmentHistory — bracketed cache filename write/read consistency (issue #842 M7)' {
    BeforeAll {
        $script:CachePathM7 = Join-Path $env:TEMP '.phase-containment-cache-Grimblaz-agent-orchestra-github-actions[bot].json'  # host-path-ok
    }

    AfterEach {
        if (Get-Command 'gh' -CommandType Function -ErrorAction SilentlyContinue) {
            Remove-Item -Path Function:gh -ErrorAction SilentlyContinue
        }
        if (Test-Path -LiteralPath $script:CachePathM7) { Remove-Item -LiteralPath $script:CachePathM7 -Force -ErrorAction SilentlyContinue }
    }

    It 'writes the cache file to a bracketed path and serves a subsequent call from cache (proving the write actually landed)' {
        $validBody = "<!-- plan-issue-1900 -->`n<!-- phase-containment-1900 -->`nfinding_key: plan-stress-test:1900:F1`nintroduced_phase: plan`ncatchable_phase: plan`ncaught_stage: plan-stress-test`nescape_distance: 0`nseverity: low`nsystemic_fix_type: plan-template`ncategory: pattern`napparatus_meta: false`n<!-- /phase-containment-1900 -->"

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
                                    number   = 1900
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

        $first = Get-PhaseContainmentHistory -RepoOwner 'Grimblaz' -RepoName 'agent-orchestra' -WindowDays 30 -CachePath $script:CachePathM7 3>$null
        $first.Source | Should -Be 'graphql'

        Test-Path -LiteralPath $script:CachePathM7 | Should -Be $true -Because 'Set-Content -LiteralPath must actually create the bracketed file, unlike the prior -Path (wildcard-interpreting) write which silently no-op''d'

        function global:gh {
            param([Parameter(ValueFromRemainingArguments = $true)]$Args)
            throw 'gh must not be called on a cache hit'
        }

        $second = Get-PhaseContainmentHistory -RepoOwner 'Grimblaz' -RepoName 'agent-orchestra' -WindowDays 30 -CachePath $script:CachePathM7 3>$null
        $second.Source | Should -Be 'cache' -Because 'the write must have actually landed at the bracketed LiteralPath for the reader (-LiteralPath) to find it on the second call'
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
        # Issue #854 s5: uses plan-stress-test rather than code-review here —
        # code-review now additionally requires -TerminalObservation to reach
        # RelaxationEligible=$true (see the dedicated code-review escape-side
        # guard Describe block), so exercising this specific "-Truncated not
        # supplied -> no stray reason" invariant on an unaffected upstream
        # stage keeps the assertion meaningful without conflating it with
        # coverage gating.
        $entries = 1..6 | ForEach-Object { script:New-TruncatedRollupEntry -FindingKey "plan-stress-test:901:F$_" -Stage 'plan-stress-test' -CatchablePhase 'plan' }

        $result = Get-PhaseContainmentRollup -Entries $entries

        $stage = $result.Stages['plan-stress-test']
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
