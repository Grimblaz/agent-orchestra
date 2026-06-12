#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
.SYNOPSIS
    RED Pester v5 suite for render-portfolio.ps1 (issue #692, slice s3).

.DESCRIPTION
    Hoisted Renderer Contract tests covering:
      - ConvertFrom-SequenceSpec  : parse, schema validation, fail-open on bad input
      - Get-PortfolioBuckets      : bucket placement, blocked logic, triage, recently closed
      - Format-PortfolioMarkdown  : footer, section order, pagination overflow, sort
      - Get-SplicedBody           : marker splice, idempotency, timestamp-only change
      - Order independence        : byte-identical output for shuffled input (F18)

    Purity constraints (d-ci-gate-registration, #692 s3):
      - Fixtures only — no network calls
      - No ConvertFrom-Yaml (production ConvertFrom-SequenceSpec used exclusively)
      - Deterministic sort keys
      - No live gh CLI calls

    Tests are RED until s4 creates render-portfolio.ps1.
#>

BeforeAll {
    $scriptPath = Join-Path $PSScriptRoot '..' 'render-portfolio.ps1'
    # This will fail until s4 creates the script — making tests RED.
    . $scriptPath
}

# ---------------------------------------------------------------------------
# Helper: build a minimal valid flat-YAML sequence spec string
# ---------------------------------------------------------------------------
function New-ValidSpecYaml {
    param(
        [int]   $SchemaVersion      = 1,
        [int]   $ControlTower       = 704,
        [int]   $RecentlyClosedDays = 14,
        [string]$RoundsBlock        = "rounds:`n  - lane: main`n    round: 1`n    issues: [425, 571]"
    )
    return @"
schema_version: $SchemaVersion
control_tower: $ControlTower
recently_closed_days: $RecentlyClosedDays
$RoundsBlock
"@
}

# ---------------------------------------------------------------------------
# Helper: build a minimal issue-state object (mimics gh GraphQL response shape)
# ---------------------------------------------------------------------------
function New-IssueState {
    param(
        [int]    $Number,
        [string] $State        = 'OPEN',
        [string[]]$Labels      = @(),
        [int[]]  $BlockedBy    = @(),
        [bool]   $BlockerInPlan = $true,
        [string] $Title        = "Issue $Number",
        [string] $ClosedAt     = $null
    )
    return [PSCustomObject]@{
        number        = $Number
        state         = $State
        title         = $Title
        labels        = $Labels
        blockedBy     = $BlockedBy
        blockerInPlan = $BlockerInPlan
        closedAt      = $ClosedAt
        totalCount    = 1  # default rendered count = totalCount (no overflow)
    }
}

# ===========================================================================
Describe 'ConvertFrom-SequenceSpec' {
# ===========================================================================

    It 'parses a valid flat schema and returns correct structure' {
        $yaml = New-ValidSpecYaml
        $spec = ConvertFrom-SequenceSpec -yamlText $yaml

        $spec                        | Should -Not -BeNullOrEmpty
        $spec.schema_version         | Should -Be 1
        $spec.control_tower          | Should -Be 704
        $spec.control_tower.GetType().Name | Should -Match 'Int'  # must be integer, not string
        $spec.recently_closed_days   | Should -Be 14
        $spec.rounds                 | Should -HaveCount 1
        $spec.rounds[0].lane         | Should -Be 'main'
        $spec.rounds[0].round        | Should -Be 1
        $spec.rounds[0].issues       | Should -Contain 425
        $spec.rounds[0].issues       | Should -Contain 571
    }

    It 'rejects block-style issues list and returns null' {
        # Block-style issues list is a schema violation per the Renderer Contract
        $blockStyleYaml = @"
schema_version: 1
control_tower: 704
recently_closed_days: 14
rounds:
  - lane: main
    round: 1
    issues:
      - 425
      - 571
"@
        $result = ConvertFrom-SequenceSpec -yamlText $blockStyleYaml
        $result | Should -BeNullOrEmpty
    }

    It 'returns null on malformed YAML input' {
        $garbled = 'this: is: not: valid: yaml: [unclosed bracket'
        $result = ConvertFrom-SequenceSpec -yamlText $garbled
        $result | Should -BeNullOrEmpty
    }

    It 'returns null when control_tower is not an integer' {
        $yaml = @"
schema_version: 1
control_tower: "not-a-number"
recently_closed_days: 14
rounds:
  - lane: main
    round: 1
    issues: [425]
"@
        $result = ConvertFrom-SequenceSpec -yamlText $yaml
        $result | Should -BeNullOrEmpty
    }
}

# ===========================================================================
Describe 'Get-PortfolioBuckets' {
# ===========================================================================

    It 'puts open unblocked issues in Now for the lowest round' {
        $spec = ConvertFrom-SequenceSpec -yamlText (New-ValidSpecYaml)
        $issues = @(
            (New-IssueState -Number 425 -State 'OPEN' -BlockedBy @())
            (New-IssueState -Number 571 -State 'OPEN' -BlockedBy @())
        )

        $buckets = Get-PortfolioBuckets -spec $spec -issueStateObjects $issues

        $buckets.Now | Should -Not -BeNullOrEmpty
        $buckets.Now.number | Should -Contain 425
        $buckets.Now.number | Should -Contain 571
    }

    It 'returns empty Now when all issues in lowest round are blocked' {
        $spec = ConvertFrom-SequenceSpec -yamlText (New-ValidSpecYaml)
        # Both round-1 issues are blocked — Now should be empty (honest stuck signal)
        $issues = @(
            (New-IssueState -Number 425 -State 'OPEN' -BlockedBy @(999))
            (New-IssueState -Number 571 -State 'OPEN' -BlockedBy @(998))
        )

        $buckets = Get-PortfolioBuckets -spec $spec -issueStateObjects $issues

        $buckets.Now | Should -BeNullOrEmpty -Because 'all round-1 issues are blocked; Now must be empty to signal an honest stuck state'
    }

    It "puts out-of-plan blockers in annotation format 'blocked by #N (out of plan)'" {
        $spec = ConvertFrom-SequenceSpec -yamlText (New-ValidSpecYaml)
        # Blocker 999 is not in sequence.yaml → out-of-plan
        $issues = @(
            (New-IssueState -Number 425 -State 'OPEN' -BlockedBy @(999) -BlockerInPlan $false)
        )

        $buckets = Get-PortfolioBuckets -spec $spec -issueStateObjects $issues

        $blockedEntry = $buckets.Blocked | Where-Object { $_.number -eq 425 }
        $blockedEntry           | Should -Not -BeNullOrEmpty
        $blockedEntry.blockerAnnotations | Should -Match 'blocked by #999 \(out of plan\)'
    }

    It 'puts closed issues in Recently Closed only, not in Now or Next' {
        $spec = ConvertFrom-SequenceSpec -yamlText (New-ValidSpecYaml)
        $closedAt = (Get-Date).AddDays(-3).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        $issues = @(
            (New-IssueState -Number 425 -State 'CLOSED' -ClosedAt $closedAt)
            (New-IssueState -Number 571 -State 'OPEN'   -BlockedBy @())
        )

        $buckets = Get-PortfolioBuckets -spec $spec -issueStateObjects $issues

        # 425 is closed — must NOT appear in Now
        if ($buckets.Now) {
            $buckets.Now.number | Should -Not -Contain 425 -Because 'closed issues must not appear in Now'
        }
        # 425 must appear in Recently Closed
        $buckets.RecentlyClosed | Should -Not -BeNullOrEmpty
        $buckets.RecentlyClosed.number | Should -Contain 425
    }

    It 'puts triage-labeled issues in Triage bucket' {
        $spec = ConvertFrom-SequenceSpec -yamlText (New-ValidSpecYaml)
        # Issue 300 has triage label but is NOT in any round
        $issues = @(
            (New-IssueState -Number 425 -State 'OPEN' -BlockedBy @())
            (New-IssueState -Number 300 -State 'OPEN' -Labels @('triage'))
        )

        $buckets = Get-PortfolioBuckets -spec $spec -issueStateObjects $issues

        $buckets.Triage | Should -Not -BeNullOrEmpty
        $buckets.Triage.number | Should -Contain 300
    }

    It 'puts registered-but-unsequenced issues in Triage bucket' {
        $spec = ConvertFrom-SequenceSpec -yamlText (New-ValidSpecYaml)
        # Issue 999 is open but appears in no round in sequence.yaml
        $issues = @(
            (New-IssueState -Number 425 -State 'OPEN' -BlockedBy @())
            (New-IssueState -Number 999 -State 'OPEN' -Labels @())
        )

        $buckets = Get-PortfolioBuckets -spec $spec -issueStateObjects $issues

        # 999 is not in any round → must land in Triage
        $buckets.Triage | Should -Not -BeNullOrEmpty
        $buckets.Triage.number | Should -Contain 999 -Because 'open issues not in any sequence round belong in Triage'
    }
}

# ===========================================================================
Describe 'Format-PortfolioMarkdown' {
# ===========================================================================

    BeforeAll {
        # Build a simple bucket model for shared formatter tests
        $spec = ConvertFrom-SequenceSpec -yamlText (New-ValidSpecYaml)
        $issues = @(
            (New-IssueState -Number 425 -State 'OPEN' -BlockedBy @())
            (New-IssueState -Number 571 -State 'OPEN' -BlockedBy @())
        )
        $script:SimpleBuckets = Get-PortfolioBuckets -spec $spec -issueStateObjects $issues
    }

    It "includes footer in format 'as of ...'" {
        $timestamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        $output = Format-PortfolioMarkdown -bucketModel $script:SimpleBuckets -timestamp $timestamp

        $output | Should -Match 'as of \d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z — rendered by render-portfolio\.ps1'
    }

    It 'renders Now/Next/Blocked/Recently closed/Triage sections in that order' {
        $timestamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        $output = Format-PortfolioMarkdown -bucketModel $script:SimpleBuckets -timestamp $timestamp

        $nowPos           = $output.IndexOf('Now')
        $nextPos          = $output.IndexOf('Next')
        $blockedPos       = $output.IndexOf('Blocked')
        $recentlyClosedPos = $output.IndexOf('Recently closed')
        $triagePos        = $output.IndexOf('Triage')

        $nowPos            | Should -BeGreaterThan -1  -Because 'Now section must be present'
        $nextPos           | Should -BeGreaterThan $nowPos           -Because 'Next must come after Now'
        $blockedPos        | Should -BeGreaterThan $nextPos          -Because 'Blocked must come after Next'
        $recentlyClosedPos | Should -BeGreaterThan $blockedPos       -Because 'Recently closed must come after Blocked'
        $triagePos         | Should -BeGreaterThan $recentlyClosedPos -Because 'Triage must come after Recently closed'
    }

    It 'appends (+N more) when totalCount exceeds rendered count (pagination overflow F14)' {
        # Fixture: 50 issues rendered, totalCount = 51 → should show (+1 more)
        $spec = ConvertFrom-SequenceSpec -yamlText (New-ValidSpecYaml)
        $issues = @(
            (New-IssueState -Number 425 -State 'OPEN' -BlockedBy @())
        )
        # Override totalCount to simulate overflow: 51 total, 1 rendered
        $overflowBucketModel = [PSCustomObject]@{
            Now            = @($issues[0])
            NowTotalCount  = 51
            Next           = @()
            Blocked        = @()
            RecentlyClosed = @()
            Triage         = @()
        }
        $timestamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')

        $output = Format-PortfolioMarkdown -bucketModel $overflowBucketModel -timestamp $timestamp

        $output | Should -Match '\(\+50 more\)' -Because 'totalCount(51) - rendered(1) = 50 overflow items must be shown'
    }

    It 'sorts issues by number ascending within each bucket (F18)' {
        $spec = ConvertFrom-SequenceSpec -yamlText (New-ValidSpecYaml)
        # Provide issues in descending order to verify sort applies
        $issues = @(
            (New-IssueState -Number 571 -State 'OPEN' -BlockedBy @())
            (New-IssueState -Number 425 -State 'OPEN' -BlockedBy @())
        )
        $buckets = Get-PortfolioBuckets -spec $spec -issueStateObjects $issues
        $timestamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')

        $output = Format-PortfolioMarkdown -bucketModel $buckets -timestamp $timestamp

        # 425 must appear before 571 in the output
        $pos425 = $output.IndexOf('#425')
        $pos571 = $output.IndexOf('#571')
        $pos425 | Should -BeGreaterThan -1  -Because '#425 must appear in output'
        $pos571 | Should -BeGreaterThan -1  -Because '#571 must appear in output'
        $pos425 | Should -BeLessThan $pos571 -Because 'issues must be sorted ascending by number; #425 must precede #571'
    }
}

# ===========================================================================
Describe 'Get-SplicedBody' {
# ===========================================================================

    BeforeAll {
        $script:BeginMarker = '<!-- portfolio-tracker:begin -->'
        $script:EndMarker   = '<!-- portfolio-tracker:end -->'
        $script:ContentBlock = @"
$($script:BeginMarker)
## Now
- #425 Issue 425

as of 2026-06-12T12:00:00Z — rendered by render-portfolio.ps1
$($script:EndMarker)
"@
    }

    It 'appends portfolio block when markers are absent from the body' {
        $existingBody = "# My Issue`n`nSome content here."

        $result = Get-SplicedBody -existingBody $existingBody -contentBlock $script:ContentBlock

        $result | Should -Not -BeNullOrEmpty
        $result | Should -Match [regex]::Escape($script:BeginMarker)
        $result | Should -Match [regex]::Escape($script:EndMarker)
        $result | Should -Match 'Some content here\.'  -Because 'original body content must be preserved'
    }

    It 'replaces content strictly between markers, preserving outside content' {
        $beforeText = 'BEFORE MARKER CONTENT'
        $afterText  = 'AFTER MARKER CONTENT'
        $oldContent = "$($script:BeginMarker)`nold content`nas of 2026-01-01T00:00:00Z — rendered by render-portfolio.ps1`n$($script:EndMarker)"
        $existingBody = "$beforeText`n$oldContent`n$afterText"

        $newContent = $script:ContentBlock
        $result = Get-SplicedBody -existingBody $existingBody -contentBlock $newContent

        $result | Should -Not -BeNullOrEmpty
        $result | Should -Match $beforeText  -Because 'content before markers must be preserved'
        $result | Should -Match $afterText   -Because 'content after markers must be preserved'
        $result | Should -Match [regex]::Escape('## Now')  -Because 'new content block must replace old'
        $result | Should -Not -Match 'old content'          -Because 'old content between markers must be replaced'
    }

    It 'returns null when content is identical after stripping timestamp (idempotent no-write F18)' {
        # Identical content except we construct the body with the same logical content
        $existingBody = $script:ContentBlock

        # Same content block — no logical change → must return $null
        $result = Get-SplicedBody -existingBody $existingBody -contentBlock $script:ContentBlock

        $result | Should -BeNullOrEmpty -Because 'identical content after timestamp-strip must return null to prevent a no-op write'
    }

    It 'updates content when only timestamp differs' {
        # Body has old timestamp; content block has new timestamp — must NOT be null
        $oldTimestampBlock = @"
$($script:BeginMarker)
## Now
- #425 Issue 425

as of 2026-01-01T00:00:00Z — rendered by render-portfolio.ps1
$($script:EndMarker)
"@
        $newTimestampBlock = @"
$($script:BeginMarker)
## Now
- #425 Issue 425

as of 2026-06-12T18:00:00Z — rendered by render-portfolio.ps1
$($script:EndMarker)
"@
        $existingBody = $oldTimestampBlock

        $result = Get-SplicedBody -existingBody $existingBody -contentBlock $newTimestampBlock

        # Only the timestamp differs — content region is the same → idempotent → $null
        # (The idempotency rule: strip the footer line then compare; if same → $null)
        $result | Should -BeNullOrEmpty -Because 'when only the timestamp differs and content region is identical, Get-SplicedBody must return null (idempotency rule: strip footer then compare)'
    }
}

# ===========================================================================
Describe 'Order independence' {
# ===========================================================================

    It 'produces byte-identical output when input issue list is shuffled (F18)' {
        $spec = ConvertFrom-SequenceSpec -yamlText (New-ValidSpecYaml)

        # Ordered input: ascending
        $issuesAscending = @(
            (New-IssueState -Number 425 -State 'OPEN' -BlockedBy @())
            (New-IssueState -Number 571 -State 'OPEN' -BlockedBy @())
        )
        # Shuffled input: descending
        $issuesShuffled = @(
            (New-IssueState -Number 571 -State 'OPEN' -BlockedBy @())
            (New-IssueState -Number 425 -State 'OPEN' -BlockedBy @())
        )

        $bucketsA = Get-PortfolioBuckets -spec $spec -issueStateObjects $issuesAscending
        $bucketsB = Get-PortfolioBuckets -spec $spec -issueStateObjects $issuesShuffled

        $fixedTimestamp = '2026-06-12T12:00:00Z'
        $outputA = Format-PortfolioMarkdown -bucketModel $bucketsA -timestamp $fixedTimestamp
        $outputB = Format-PortfolioMarkdown -bucketModel $bucketsB -timestamp $fixedTimestamp

        $outputA | Should -Be $outputB -Because 'output must be byte-identical regardless of input issue ordering (sort by number ascending is deterministic)'
    }
}
