#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
.SYNOPSIS
    RED Pester v5 suite for render-portfolio.ps1 (issue #692, slice s3; extended for #720, slice s1).

.DESCRIPTION
    Hoisted Renderer Contract tests covering:
      - ConvertFrom-SequenceSpec  : parse, schema validation, fail-open on bad input
      - Get-PortfolioBuckets      : bucket placement, blocked logic, triage, recently closed,
                                    float detection (sub-issue-set inversion), createdAt ordering,
                                    dedup (spine wins), CoverageGaps
      - Format-PortfolioMarkdown  : footer (new label), section order, pagination overflow,
                                    single ranked Now list, (unsequenced)/(in progress) tags,
                                    cap-floor N=15 (+M more), recently-closed repo-wide section
      - Get-SplicedBody           : marker splice, idempotency, migration fixture (old→new label)
      - Order independence        : createdAt-desc ordering with priority-label tiebreak (AC3)
      - Invoke-PortfolioRender    : hard-exit guard — gh issue edit NOT called on scan failure (AC8)

    Purity constraints (d-ci-gate-registration, #692 s3 / #720 s1):
      - Fixtures only — no network calls
      - No ConvertFrom-Yaml (production ConvertFrom-SequenceSpec used exclusively)
      - Deterministic sort keys
      - No live gh CLI calls
      - No Sort-Object number in fixture ordering assertions (AC3: producer owns order)

    Tests added in #720 s1 are RED until s2/s3/s4 implement production behavior.
#>

BeforeAll {
    $scriptPath = Join-Path $PSScriptRoot '..' 'render-portfolio.ps1'
    # This will fail until s4 creates the script — making tests RED.
    . $scriptPath
}

# ---------------------------------------------------------------------------
# Helper: build a minimal valid flat-YAML sequence spec string
# v2 default: schema_version 2 with umbrellas inline list.
# Legacy path: when $LegacyRoundsBlock is provided, emit schema_version 1 +
# rounds block so surviving v1-format tests can still exercise old structure.
# ---------------------------------------------------------------------------
function New-ValidSpecYaml {
    param(
        [int]    $SchemaVersion      = 2,
        [int]    $ControlTower       = 704,
        [int]    $RecentlyClosedDays = 14,
        [int[]]  $Umbrellas          = @(476, 571),
        [string] $LegacyRoundsBlock  = $null
    )
    if (-not [string]::IsNullOrEmpty($LegacyRoundsBlock)) {
        return @"
schema_version: 1
control_tower: $ControlTower
recently_closed_days: $RecentlyClosedDays
$LegacyRoundsBlock
"@
    }
    $umbrellaList = $Umbrellas -join ', '
    return @"
schema_version: $SchemaVersion
control_tower: $ControlTower
recently_closed_days: $RecentlyClosedDays
umbrellas: [$umbrellaList]
"@
}

# ---------------------------------------------------------------------------
# Helper: build a minimal issue-state object (mimics gh GraphQL response shape)
# Extended in #720 s1: added CreatedAt (for AC3 createdAt-desc ordering) and
# Labels extended to support 'in progress' simulation (AC3/AC10 inProgress tag).
# Extended in #753 s1: added Parent and SubIssues for s2/s3 downstream tests.
# ---------------------------------------------------------------------------
function New-IssueState {
    param(
        [int]       $Number,
        [string]    $State        = 'OPEN',
        [string[]]  $Labels       = @(),
        [int[]]     $BlockedBy    = @(),
        [bool]      $BlockerInPlan = $true,
        [string]    $Title        = "Issue $Number",
        [string]    $ClosedAt     = $null,
        [string]    $CreatedAt    = '2025-01-01T00:00:00Z',
        [hashtable] $Parent       = $null,
        [hashtable] $SubIssues    = $null
    )
    return [PSCustomObject]@{
        number        = $Number
        state         = $State
        title         = $Title
        labels        = $Labels
        blockedBy     = $BlockedBy
        blockerInPlan = $BlockerInPlan
        closedAt      = $ClosedAt
        createdAt     = $CreatedAt
        totalCount    = 1  # default rendered count = totalCount (no overflow)
        parent        = $Parent
        subIssues     = $SubIssues
    }
}

# ===========================================================================
Describe 'ConvertFrom-SequenceSpec' {
# ===========================================================================

    It 'parses v2 schema with umbrellas: inline list' {
        $yaml = New-ValidSpecYaml
        $spec = ConvertFrom-SequenceSpec -yamlText $yaml

        $spec                        | Should -Not -BeNullOrEmpty
        $spec.schema_version         | Should -Be 2
        $spec.control_tower          | Should -Be 704
        $spec.control_tower.GetType().Name | Should -Match 'Int'  # must be integer, not string
        $spec.recently_closed_days   | Should -Be 14
        $spec.umbrellas              | Should -Not -BeNullOrEmpty
        $spec.umbrellas              | Should -Contain 476
        $spec.umbrellas              | Should -Contain 571
    }

    It 'returns umbrellas as ordered int array matching YAML order' {
        $yaml = New-ValidSpecYaml -Umbrellas @(476, 571, 674, 662, 343, 693, 732)
        $spec = ConvertFrom-SequenceSpec -yamlText $yaml

        $spec.umbrellas              | Should -HaveCount 7
        $spec.umbrellas[0]           | Should -Be 476
        $spec.umbrellas[1]           | Should -Be 571
        $spec.umbrellas[2]           | Should -Be 674
        $spec.umbrellas[3]           | Should -Be 662
        $spec.umbrellas[4]           | Should -Be 343
        $spec.umbrellas[5]           | Should -Be 693
        $spec.umbrellas[6]           | Should -Be 732
    }

    It 'rejects schema_version 1 with descriptive error' {
        $yaml = @"
schema_version: 1
control_tower: 704
recently_closed_days: 14
rounds:
  - lane: main
    round: 1
    issues: [425, 571]
"@
        $result = ConvertFrom-SequenceSpec -yamlText $yaml 2>&1 | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] }
        # The function writes an error and returns $null
        $result = ConvertFrom-SequenceSpec -yamlText $yaml -ErrorAction SilentlyContinue
        $result | Should -BeNullOrEmpty -Because 'schema_version 1 is no longer supported'
    }

    It 'rejects block-style umbrellas list' {
        $blockStyleYaml = @"
schema_version: 2
control_tower: 704
recently_closed_days: 14
umbrellas:
  - 476
  - 571
"@
        $result = ConvertFrom-SequenceSpec -yamlText $blockStyleYaml -ErrorAction SilentlyContinue
        $result | Should -BeNullOrEmpty -Because 'block-style umbrellas list is a schema violation'
    }

    It 'rejects quoted numbers in umbrellas list' {
        $quotedYaml = @"
schema_version: 2
control_tower: 704
recently_closed_days: 14
umbrellas: ["476", 571]
"@
        $result = ConvertFrom-SequenceSpec -yamlText $quotedYaml -ErrorAction SilentlyContinue
        $result | Should -BeNullOrEmpty -Because 'quoted numbers in umbrellas list are not permitted'
    }

    It 'rejects empty umbrellas list' {
        $emptyYaml = @"
schema_version: 2
control_tower: 704
recently_closed_days: 14
umbrellas: []
"@
        $result = ConvertFrom-SequenceSpec -yamlText $emptyYaml -ErrorAction SilentlyContinue
        $result | Should -BeNullOrEmpty -Because 'empty umbrellas list must be rejected'
    }

    It 'rejects duplicate umbrella entries' {
        $dupYaml = @"
schema_version: 2
control_tower: 704
recently_closed_days: 14
umbrellas: [476, 571, 476]
"@
        $result = ConvertFrom-SequenceSpec -yamlText $dupYaml -ErrorAction SilentlyContinue
        $result | Should -BeNullOrEmpty -Because 'duplicate entries in umbrellas list must be rejected'
    }

    It 'rejects stray rounds: key in a v2 doc' {
        $strayYaml = @"
schema_version: 2
control_tower: 704
recently_closed_days: 14
umbrellas: [476, 571]
rounds:
  - lane: main
    round: 1
    issues: [476]
"@
        $result = ConvertFrom-SequenceSpec -yamlText $strayYaml -ErrorAction SilentlyContinue
        $result | Should -BeNullOrEmpty -Because "stray 'rounds:' key in a v2 doc must be rejected"
    }

    It 'rejects missing umbrellas: key' {
        $noUmbrellasYaml = @"
schema_version: 2
control_tower: 704
recently_closed_days: 14
"@
        $result = ConvertFrom-SequenceSpec -yamlText $noUmbrellasYaml -ErrorAction SilentlyContinue
        $result | Should -BeNullOrEmpty -Because "missing 'umbrellas:' key must be rejected"
    }

    It 'returns null when control_tower is quoted' {
        $yaml = @"
schema_version: 2
control_tower: "704"
recently_closed_days: 14
umbrellas: [476, 571]
"@
        $result = ConvertFrom-SequenceSpec -yamlText $yaml -ErrorAction SilentlyContinue
        $result | Should -BeNullOrEmpty -Because 'quoted control_tower must be rejected'
    }

    It 'returns null when control_tower is absent' {
        $yaml = @"
schema_version: 2
recently_closed_days: 14
umbrellas: [476, 571]
"@
        $result = ConvertFrom-SequenceSpec -yamlText $yaml -ErrorAction SilentlyContinue
        $result | Should -BeNullOrEmpty -Because 'absent control_tower must be rejected'
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

    It 'puts spine leaf children of active-round umbrellas in Now; umbrellas are excluded (AC1/CR-2)' {
        $spec = ConvertFrom-SequenceSpec -yamlText (New-ValidSpecYaml)
        $issues = @(
            (New-IssueState -Number 425 -State 'OPEN' -BlockedBy @())   # active-round umbrella
            (New-IssueState -Number 571 -State 'OPEN' -BlockedBy @())   # active-round umbrella
            (New-IssueState -Number 900 -State 'OPEN' -BlockedBy @())   # spine leaf (child of #425)
        )
        $knownChildSet = @([PSCustomObject]@{ number = 900; RoundIndex = 0; UmbrellaNumber = 425 })

        $buckets = Get-PortfolioBuckets -spec $spec -issueStateObjects $issues -KnownChildSet $knownChildSet

        $buckets.Now | Should -Not -BeNullOrEmpty
        $buckets.Now.number | Should -Contain 900 -Because 'spine leaf child of active-round umbrella must appear in Now'
        $buckets.Now.number | Should -Not -Contain 425 -Because 'umbrellas must not appear as work items in Now (AC1)'
        $buckets.Now.number | Should -Not -Contain 571 -Because 'umbrellas must not appear as work items in Now (AC1)'
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

    It 'holds empty Now when lowest round is all-blocked; round-2 umbrella excluded from Next (AC1/CR-2)' {
        # Two-round spec: round 1 all-blocked, round 2 unblocked.
        # CR-2: umbrellas are containers only — they do not appear as work items in Now or Next.
        # #100 is a round-1 umbrella (blocked) → Now is empty; #100 lands in Blocked.
        # #200 is a round-2 umbrella (unblocked) → excluded from Next because umbrellas are not work items.
        # Spine leaf children of #200 would appear in Next, but none are provided here.
        $twoRoundSpec = ConvertFrom-SequenceSpec (New-ValidSpecYaml -LegacyRoundsBlock @'
rounds:
  - lane: main
    round: 1
    issues: [100]
  - lane: main
    round: 2
    issues: [200]
'@)
        $issues = @(
            (New-IssueState -Number 100 -BlockedBy @(999)),   # round 1 umbrella, blocked
            (New-IssueState -Number 200)                       # round 2 umbrella, unblocked — but excluded from Next (AC1)
        )
        $result = Get-PortfolioBuckets -spec $twoRoundSpec -issueStateObjects $issues
        $result.Now   | Should -BeNullOrEmpty -Because 'round 1 is all-blocked; Now must be empty (honest stuck signal)'
        $result.Blocked | Select-Object -ExpandProperty number | Should -Contain 100
        $result.Next  | Should -BeNullOrEmpty -Because 'round-2 umbrella is a container only — not a work item in Next (AC1/CR-2)'
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

    It 'annotates each blocker independently when an issue mixes in-plan and out-of-plan blockers (CR7)' {
        $spec = ConvertFrom-SequenceSpec -yamlText (New-ValidSpecYaml)
        # 425 is blocked by 571 (in sequence.yaml → in plan) AND 999 (not in
        # sequence.yaml → out of plan). Each blocker must be labeled on its own
        # merits, not collapsed to one issue-level verdict.
        $issues = @(
            (New-IssueState -Number 425 -State 'OPEN' -BlockedBy @(571, 999))
        )

        $buckets = Get-PortfolioBuckets -spec $spec -issueStateObjects $issues

        $blockedEntry = $buckets.Blocked | Where-Object { $_.number -eq 425 }
        $blockedEntry | Should -Not -BeNullOrEmpty
        $blockedEntry.blockerAnnotations | Should -Match 'blocked by #571(?!\s*\(out of plan\))' -Because 'an in-plan blocker must not be tagged out of plan'
        $blockedEntry.blockerAnnotations | Should -Match 'blocked by #999 \(out of plan\)' -Because 'an out-of-plan blocker must be tagged'
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

    # -----------------------------------------------------------------------
    # NEW fixtures for #720 s1 (AC4 float detection, AC2 Next placement,
    # AC5 dedup, AC6 blocked float, AC3 createdAt ordering, AC7 CoverageGaps)
    # All RED until s2/s3 implement float-detection and createdAt ordering.
    # -----------------------------------------------------------------------

    It 'open non-umbrella issue NOT in known-child-set → float (AC4)' {
        # Spec has umbrellas 425 and 571 as sequenced issues.
        # Issue 800 is open but NOT in any round → it is a float.
        # Float detection: open non-umbrella NOT in any sequenced umbrella child-set.
        # RED: Get-PortfolioBuckets does not yet implement float sub-issue-set inversion.
        $spec = ConvertFrom-SequenceSpec -yamlText (New-ValidSpecYaml)
        $issues = @(
            (New-IssueState -Number 425  -State 'OPEN' -BlockedBy @())
            (New-IssueState -Number 571  -State 'OPEN' -BlockedBy @())
            (New-IssueState -Number 800  -State 'OPEN' -BlockedBy @())   # not in any round → float
        )
        # Provide empty known-child-set (no subIssue children fetched)
        $knownChildSet = @()

        $buckets = Get-PortfolioBuckets -spec $spec -issueStateObjects $issues -KnownChildSet $knownChildSet

        $floatEntry = $buckets.Now | Where-Object { $_.number -eq 800 -and $_.isFloat -eq $true }
        $floatEntry | Should -Not -BeNullOrEmpty -Because 'open issue not in any sequenced umbrella child-set must appear in Now as a float (isFloat=$true)'
    }

    It 'issue IN the known-child-set → not a float (AC4)' {
        # Issue 800 appears in a sequenced umbrella child-set → not a float.
        # RED: same as above.
        $spec = ConvertFrom-SequenceSpec -yamlText (New-ValidSpecYaml)
        $issues = @(
            (New-IssueState -Number 425  -State 'OPEN' -BlockedBy @())
            (New-IssueState -Number 571  -State 'OPEN' -BlockedBy @())
            (New-IssueState -Number 800  -State 'OPEN' -BlockedBy @())
        )
        $knownChildSet = @(800)   # 800 is a child of a sequenced umbrella

        $buckets = Get-PortfolioBuckets -spec $spec -issueStateObjects $issues -KnownChildSet $knownChildSet

        $entry = $buckets.Now | Where-Object { $_.number -eq 800 }
        if ($entry) {
            $entry.isFloat | Should -Not -Be $true -Because 'issue in the known-child-set must NOT be marked as a float'
        }
        # It should land in Now/Next as a spine child, not in the float path
    }

    It 'issues #711/#712 whose parent #692 is CLOSED → appear as floats (AC4)' {
        # #692 is unsequenced/closed — its children #711 and #712 are not in any
        # sequenced umbrella child-set → they appear as floats (isFloat=$true).
        # RED: float detection not yet implemented.
        $spec = ConvertFrom-SequenceSpec -yamlText (New-ValidSpecYaml)
        $issues = @(
            (New-IssueState -Number 425  -State 'OPEN'   -BlockedBy @())
            (New-IssueState -Number 571  -State 'OPEN'   -BlockedBy @())
            (New-IssueState -Number 711  -State 'OPEN'   -BlockedBy @())
            (New-IssueState -Number 712  -State 'OPEN'   -BlockedBy @())
        )
        # #692 is closed/unsequenced → 711 and 712 are NOT in the known-child-set
        $knownChildSet = @()

        $buckets = Get-PortfolioBuckets -spec $spec -issueStateObjects $issues -KnownChildSet $knownChildSet

        $float711 = $buckets.Now | Where-Object { $_.number -eq 711 -and $_.isFloat -eq $true }
        $float712 = $buckets.Now | Where-Object { $_.number -eq 712 -and $_.isFloat -eq $true }
        $float711 | Should -Not -BeNullOrEmpty -Because 'issue whose parent is closed/unsequenced must appear as a float (isFloat=$true)'
        $float712 | Should -Not -BeNullOrEmpty -Because 'issue whose parent is closed/unsequenced must appear as a float (isFloat=$true)'
    }

    It 'non-active sequenced umbrella child → Next, not float (M9 / AC2)' {
        # Umbrella #476 is in round 2 (non-active: round 1 [425,571] is active).
        # Child issue 900 is in the known-child-set of #476 → appears in Next, not Now, not float.
        # RED: child-set Next placement not yet implemented.
        $threeRoundSpec = ConvertFrom-SequenceSpec (New-ValidSpecYaml -LegacyRoundsBlock @'
rounds:
  - lane: main
    round: 1
    issues: [425, 571]
  - lane: main
    round: 2
    issues: [476, 662]
'@)
        $issues = @(
            (New-IssueState -Number 425  -State 'OPEN' -BlockedBy @())
            (New-IssueState -Number 571  -State 'OPEN' -BlockedBy @())
            (New-IssueState -Number 476  -State 'OPEN' -BlockedBy @())
            (New-IssueState -Number 662  -State 'OPEN' -BlockedBy @())
            (New-IssueState -Number 900  -State 'OPEN' -BlockedBy @())   # child of #476 (round 2)
        )
        $knownChildSet = @(900)   # 900 is a sub-issue of #476

        $buckets = Get-PortfolioBuckets -spec $threeRoundSpec -issueStateObjects $issues -KnownChildSet $knownChildSet

        $inNow  = $buckets.Now  | Where-Object { $_.number -eq 900 }
        $inNext = $buckets.Next | Where-Object { $_.number -eq 900 }
        $inNow  | Should -BeNullOrEmpty -Because 'child of non-active round umbrella must NOT appear in Now'
        $inNext | Should -Not -BeNullOrEmpty -Because 'child of non-active round umbrella must appear in Next'
        if ($inNext) {
            $inNext.isFloat | Should -Not -Be $true -Because 'spine child in Next must not be flagged as float'
        }
    }

    It 'spine wins dedup — issue in both child-set and open scan appears once (AC5)' {
        # Issue 800 appears in knownChildSet AND in the open issue list.
        # It must appear exactly once in the output (spine wins).
        # RED: dedup logic not yet implemented.
        $spec = ConvertFrom-SequenceSpec -yamlText (New-ValidSpecYaml)
        $issues = @(
            (New-IssueState -Number 425  -State 'OPEN' -BlockedBy @())
            (New-IssueState -Number 571  -State 'OPEN' -BlockedBy @())
            (New-IssueState -Number 800  -State 'OPEN' -BlockedBy @())
        )
        $knownChildSet = @(800)

        $buckets = Get-PortfolioBuckets -spec $spec -issueStateObjects $issues -KnownChildSet $knownChildSet

        $allOutputNums = @(
            @($buckets.Now)  + @($buckets.Next) + @($buckets.Blocked) +
            @($buckets.Triage) + @($buckets.RecentlyClosed)
        ) | ForEach-Object { $_.number }
        $count800 = ($allOutputNums | Where-Object { $_ -eq 800 }).Count
        $count800 | Should -Be 1 -Because 'issue in both the spine child-set and open scan must appear exactly once (spine wins dedup, AC5)'
    }

    It 'float with open blockedBy → Blocked bucket with blocker annotation (AC6)' {
        # Float (open, not in any child-set) that is also blocked → goes to Blocked,
        # not to Now, with a blockerAnnotations field.
        # RED: float detection not yet implemented; blocked floats may fall in wrong bucket.
        $spec = ConvertFrom-SequenceSpec -yamlText (New-ValidSpecYaml)
        $issues = @(
            (New-IssueState -Number 425  -State 'OPEN' -BlockedBy @())
            (New-IssueState -Number 571  -State 'OPEN' -BlockedBy @())
            (New-IssueState -Number 800  -State 'OPEN' -BlockedBy @(999))   # float + blocked
        )
        $knownChildSet = @()

        $buckets = Get-PortfolioBuckets -spec $spec -issueStateObjects $issues -KnownChildSet $knownChildSet

        $inNow     = $buckets.Now     | Where-Object { $_.number -eq 800 }
        $inBlocked = $buckets.Blocked | Where-Object { $_.number -eq 800 }
        $inNow | Should -BeNullOrEmpty -Because 'blocked float must NOT appear in Now'
        $inBlocked | Should -Not -BeNullOrEmpty -Because 'float with open blockedBy must appear in Blocked (AC6)'
        if ($inBlocked) {
            $inBlocked.blockerAnnotations | Should -Not -BeNullOrEmpty -Because 'blocked float must carry blocker annotation'
        }
    }

    It 'createdAt-desc ordering: newer floats rank above older floats within Now (AC3)' {
        # Fixture: float #801 created 2025-06-01 (newer), float #800 created 2025-01-01 (older).
        # Issue numbers are reverse of creation date order to prove Sort-by-number is NOT used.
        # AC3: order is createdAt desc (newest first) among floats.
        # RED: createdAt-desc ordering not yet implemented.
        $spec = ConvertFrom-SequenceSpec -yamlText (New-ValidSpecYaml)
        $issues = @(
            (New-IssueState -Number 425  -State 'OPEN' -BlockedBy @() -CreatedAt '2024-01-01T00:00:00Z')
            (New-IssueState -Number 571  -State 'OPEN' -BlockedBy @() -CreatedAt '2024-01-01T00:00:00Z')
            # Float 801 (higher number) is older; float 800 (lower number) is newer
            (New-IssueState -Number 801  -State 'OPEN' -BlockedBy @() -CreatedAt '2025-01-01T00:00:00Z')
            (New-IssueState -Number 800  -State 'OPEN' -BlockedBy @() -CreatedAt '2025-06-01T00:00:00Z')
        )
        $knownChildSet = @()

        $buckets = Get-PortfolioBuckets -spec $spec -issueStateObjects $issues -KnownChildSet $knownChildSet

        $floats = @($buckets.Now | Where-Object { $_.isFloat -eq $true })
        $floats.Count | Should -BeGreaterOrEqual 2 -Because 'both floats must appear in Now'
        $pos800 = [array]::IndexOf($floats, ($floats | Where-Object { $_.number -eq 800 }))
        $pos801 = [array]::IndexOf($floats, ($floats | Where-Object { $_.number -eq 801 }))
        $pos800 | Should -BeLessThan $pos801 -Because 'float #800 (newer, created 2025-06-01) must rank before #801 (older, created 2025-01-01) — createdAt desc; NOT sorted by number'
    }

    It 'priority-label tiebreak: priority:high float before unlabeled float at same createdAt (AC3)' {
        # Two floats with identical createdAt — priority-label tiebreak applies.
        # priority:high before priority:medium before priority:low before unlabeled.
        # RED: priority-label tiebreak not yet implemented.
        $spec = ConvertFrom-SequenceSpec -yamlText (New-ValidSpecYaml)
        $issues = @(
            (New-IssueState -Number 425  -State 'OPEN' -BlockedBy @() -CreatedAt '2024-01-01T00:00:00Z')
            (New-IssueState -Number 571  -State 'OPEN' -BlockedBy @() -CreatedAt '2024-01-01T00:00:00Z')
            # Both floats with same createdAt; #900 has priority:high label, #901 is unlabeled
            (New-IssueState -Number 901  -State 'OPEN' -BlockedBy @() -CreatedAt '2025-03-01T00:00:00Z' -Labels @())
            (New-IssueState -Number 900  -State 'OPEN' -BlockedBy @() -CreatedAt '2025-03-01T00:00:00Z' -Labels @('priority: high'))
        )
        $knownChildSet = @()

        $buckets = Get-PortfolioBuckets -spec $spec -issueStateObjects $issues -KnownChildSet $knownChildSet

        $floats = @($buckets.Now | Where-Object { $_.isFloat -eq $true })
        $idx900 = [array]::IndexOf($floats, ($floats | Where-Object { $_.number -eq 900 }))
        $idx901 = [array]::IndexOf($floats, ($floats | Where-Object { $_.number -eq 901 }))
        $idx900 | Should -BeLessThan $idx901 -Because 'priority:high float must rank above unlabeled float when createdAt is equal (AC3 priority-label tiebreak)'
    }

    It 'active-round umbrella with zero open sub-issues → CoverageGaps entry (AC7)' {
        # Umbrella #425 is in round 1 (active) but has no open sub-issues in knownChildSet.
        # → CoverageGaps must list umbrella #425.
        # RED: CoverageGaps derivation not yet implemented.
        $spec = ConvertFrom-SequenceSpec -yamlText (New-ValidSpecYaml)
        $issues = @(
            (New-IssueState -Number 425  -State 'OPEN' -BlockedBy @())
            (New-IssueState -Number 571  -State 'OPEN' -BlockedBy @())
        )
        # No children in child-set for either active-round umbrella
        $knownChildSet = @()

        $buckets = Get-PortfolioBuckets -spec $spec -issueStateObjects $issues -KnownChildSet $knownChildSet

        $buckets.CoverageGaps | Should -Not -BeNullOrEmpty -Because 'active-round umbrella with zero open sub-issues must produce a CoverageGaps entry (AC7)'
        $gapNums = @($buckets.CoverageGaps | ForEach-Object { $_.umbrella })
        $gapNums | Should -Contain 425 -Because '#425 is an active-round umbrella with no known open sub-issues'
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

    It "includes footer with new label 'portfolio content unchanged since ...'" {
        # AC: footer label updated from 'as of' to 'portfolio content unchanged since' (#720 s1)
        # RED until s2/s3 update Format-PortfolioMarkdown to write the new footer label.
        $timestamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        $output = Format-PortfolioMarkdown -bucketModel $script:SimpleBuckets -timestamp $timestamp

        $output | Should -Match 'portfolio content unchanged since \d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z — rendered by render-portfolio\.ps1'
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

    It 'Now ordering tiebreaker: lower-numbered float precedes higher-numbered float (AC3/F18)' {
        # Two floats with no createdAt and no priority labels — the number-asc tiebreaker
        # (last key in the Sort-Object in Get-PortfolioBuckets) must put #800 before #801.
        # Uses floats rather than umbrellas: AC1 forbids umbrellas from appearing in Now.
        $spec = ConvertFrom-SequenceSpec -yamlText (New-ValidSpecYaml)
        $issues = @(
            (New-IssueState -Number 425  -State 'OPEN' -BlockedBy @())  # active-round umbrella (excluded by AC1)
            (New-IssueState -Number 571  -State 'OPEN' -BlockedBy @())  # active-round umbrella (excluded by AC1)
            (New-IssueState -Number 801  -State 'OPEN' -BlockedBy @())  # float (no KnownChildSet entry)
            (New-IssueState -Number 800  -State 'OPEN' -BlockedBy @())  # float (lower number — must sort first)
        )
        $buckets = Get-PortfolioBuckets -spec $spec -issueStateObjects $issues -KnownChildSet @()
        $timestamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')

        $output = Format-PortfolioMarkdown -bucketModel $buckets -timestamp $timestamp

        $pos800 = $output.IndexOf('#800')
        $pos801 = $output.IndexOf('#801')
        $pos800 | Should -BeGreaterThan -1  -Because '#800 float must appear in output'
        $pos801 | Should -BeGreaterThan -1  -Because '#801 float must appear in output'
        $pos800 | Should -BeLessThan $pos801 -Because 'lower-numbered float (#800) must precede higher-numbered float (#801) as number-asc tiebreaker (AC3)'
    }

    # -----------------------------------------------------------------------
    # NEW fixtures for #720 s1 (AC3, AC9, AC10)
    # All RED until s2/s3 implement single ranked list, tags, and cap-floor.
    # -----------------------------------------------------------------------

    It 'Now list is a single ranked list — no umbrella section headers (AC3)' {
        # The new Now list must NOT re-sort by number or add umbrella sub-headers.
        # Formatter must preserve the producer ordering from the bucket model.
        # RED until Format-PortfolioMarkdown is updated.
        $bucketModel = [PSCustomObject]@{
            Now            = @(
                [PSCustomObject]@{ number = 571; title = 'Issue 571'; isFloat = $false; inProgress = $false }
                [PSCustomObject]@{ number = 425; title = 'Issue 425'; isFloat = $false; inProgress = $false }
            )
            NowTotalCount  = 2
            Next           = @()
            NextTotalCount = 0
            Blocked        = @()
            BlockedTotalCount = 0
            RecentlyClosed = @()
            RecentlyClosedTotalCount = 0
            Triage         = @()
            TriageTotalCount = 0
            CoverageGaps   = @()
        }
        $timestamp = '2026-06-25T00:00:00Z'

        $output = Format-PortfolioMarkdown -bucketModel $bucketModel -timestamp $timestamp

        # 571 must appear BEFORE 425 (bucket model order preserved, no re-sort by number)
        $pos571 = $output.IndexOf('#571')
        $pos425 = $output.IndexOf('#425')
        $pos571 | Should -BeGreaterThan -1  -Because '#571 must appear in output'
        $pos425 | Should -BeGreaterThan -1  -Because '#425 must appear in output'
        $pos571 | Should -BeLessThan $pos425 -Because 'formatter must NOT re-sort by number; bucket model order is authoritative (AC3)'
        # No umbrella sub-headers: the Now section body must not contain "### " headers.
        $nowMatch = [regex]::Match($output, '(?s)## Now(?<body>.*?)## Next')
        $nowMatch.Success | Should -Be $true -Because 'Now section must appear before Next in the output'
        $nowMatch.Groups['body'].Value | Should -Not -Match '(?m)^###\s' -Because 'single ranked Now list must not contain umbrella sub-headers (AC3)'
    }

    It 'float items in Now list are tagged with (unsequenced) (AC3/AC4)' {
        # Float issues in Now must be rendered with "(unsequenced)" tag in the list item.
        # RED until Format-PortfolioMarkdown adds (unsequenced) tag for isFloat items.
        $bucketModel = [PSCustomObject]@{
            Now            = @(
                [PSCustomObject]@{ number = 800; title = 'Float Issue'; isFloat = $true; inProgress = $false }
                [PSCustomObject]@{ number = 425; title = 'Issue 425';   isFloat = $false; inProgress = $false }
            )
            NowTotalCount  = 2
            Next           = @()
            NextTotalCount = 0
            Blocked        = @()
            BlockedTotalCount = 0
            RecentlyClosed = @()
            RecentlyClosedTotalCount = 0
            Triage         = @()
            TriageTotalCount = 0
            CoverageGaps   = @()
        }
        $timestamp = '2026-06-25T00:00:00Z'

        $output = Format-PortfolioMarkdown -bucketModel $bucketModel -timestamp $timestamp

        $output | Should -Match '#800.*\(unsequenced\)' -Because 'float items in Now list must be tagged with (unsequenced) (AC3/AC4)'
        $output | Should -Not -Match '#425.*\(unsequenced\)' -Because 'non-float items must NOT be tagged with (unsequenced)'
    }

    It 'in-progress items in Now list are tagged with (in progress) (AC3)' {
        # Items with inProgress=$true (derived from "in progress" label) must be
        # tagged with "(in progress)" in the list rendering.
        # RED until Format-PortfolioMarkdown adds (in progress) tag.
        $bucketModel = [PSCustomObject]@{
            Now            = @(
                [PSCustomObject]@{ number = 425; title = 'Issue 425'; isFloat = $false; inProgress = $true }
                [PSCustomObject]@{ number = 571; title = 'Issue 571'; isFloat = $false; inProgress = $false }
            )
            NowTotalCount  = 2
            Next           = @()
            NextTotalCount = 0
            Blocked        = @()
            BlockedTotalCount = 0
            RecentlyClosed = @()
            RecentlyClosedTotalCount = 0
            Triage         = @()
            TriageTotalCount = 0
            CoverageGaps   = @()
        }
        $timestamp = '2026-06-25T00:00:00Z'

        $output = Format-PortfolioMarkdown -bucketModel $bucketModel -timestamp $timestamp

        $output | Should -Match '#425.*\(in progress\)' -Because 'issues with inProgress=$true must be tagged (in progress) (AC3)'
        $output | Should -Not -Match '#571.*\(in progress\)' -Because 'issues without inProgress flag must not be tagged'
    }

    It 'cap-floor N=15: top 15 float items rendered, (+M more) for the rest (AC10)' {
        # When more than 15 floats exist, the formatter renders top 15 and shows "(+M more)".
        # RED until Format-PortfolioMarkdown implements cap-floor.
        $floats = 1..20 | ForEach-Object {
            [PSCustomObject]@{
                number     = 900 + $_
                title      = "Float $_"
                isFloat    = $true
                inProgress = $false
            }
        }
        $bucketModel = [PSCustomObject]@{
            Now               = $floats    # 20 floats; only 15 should render
            NowTotalCount     = 20
            NowFloatCount     = 20
            Next              = @()
            NextTotalCount    = 0
            Blocked           = @()
            BlockedTotalCount = 0
            RecentlyClosed    = @()
            RecentlyClosedTotalCount = 0
            Triage            = @()
            TriageTotalCount  = 0
            CoverageGaps      = @()
        }
        $timestamp = '2026-06-25T00:00:00Z'

        $output = Format-PortfolioMarkdown -bucketModel $bucketModel -timestamp $timestamp

        # Should show (+5 more) because 20 total - 15 cap = 5 overflow
        $output | Should -Match '\(\+5 more\)' -Because 'cap-floor: 20 floats - N=15 cap = 5 overflow, must show (+5 more) (AC10)'
        # Must NOT render items beyond the cap
        $output | Should -Not -Match '#920' -Because 'items beyond cap floor must not be rendered individually'
    }

    It 'empty Now bucket shows appropriate empty label' {
        # When Now bucket is empty (no current-round work), formatter shows a label.
        # This is consistent with the existing blocked/no-work distinction.
        $bucketModel = [PSCustomObject]@{
            Now               = @()
            NowTotalCount     = 0
            Next              = @()
            NextTotalCount    = 0
            Blocked           = @()
            BlockedTotalCount = 0
            RecentlyClosed    = @()
            RecentlyClosedTotalCount = 0
            Triage            = @()
            TriageTotalCount  = 0
            CoverageGaps      = @()
        }
        $timestamp = '2026-06-25T00:00:00Z'

        $output = Format-PortfolioMarkdown -bucketModel $bucketModel -timestamp $timestamp

        # Existing behavior: shows "*(no current-round work)*" or similar
        $output | Should -Match '\*\(no' -Because 'empty Now bucket must show a labeled empty state message'
    }

    It 'repo-wide recently-closed section shows all leaf closures in window (AC9)' {
        # AC9: RecentlyClosed shows repo-wide leaf closures within recently_closed_days window.
        # This test verifies the formatter renders the RecentlyClosed section from the model.
        # RED until Format-PortfolioMarkdown is updated to render repo-wide closures (not
        # just sequence-filtered closures).
        $recentlyClosed = @(
            [PSCustomObject]@{ number = 700; title = 'Closed Issue 700'; isFloat = $false; inProgress = $false }
            [PSCustomObject]@{ number = 701; title = 'Closed Issue 701'; isFloat = $false; inProgress = $false }
        )
        $bucketModel = [PSCustomObject]@{
            Now                      = @()
            NowTotalCount            = 0
            Next                     = @()
            NextTotalCount           = 0
            Blocked                  = @()
            BlockedTotalCount        = 0
            RecentlyClosed           = $recentlyClosed
            RecentlyClosedTotalCount = 2
            Triage                   = @()
            TriageTotalCount         = 0
            CoverageGaps             = @()
        }
        $timestamp = '2026-06-25T00:00:00Z'

        $output = Format-PortfolioMarkdown -bucketModel $bucketModel -timestamp $timestamp

        $output | Should -Match '#700' -Because 'recently closed issue #700 must appear in RecentlyClosed section (AC9)'
        $output | Should -Match '#701' -Because 'recently closed issue #701 must appear in RecentlyClosed section (AC9)'
    }
}

# ===========================================================================
Describe 'Get-SplicedBody' {
# ===========================================================================

    BeforeAll {
        $script:BeginMarker = '<!-- portfolio-tracker:begin -->'
        $script:EndMarker   = '<!-- portfolio-tracker:end -->'
        # Updated to new footer label in #720 s1 (RED until s2/s3 update Format-PortfolioMarkdown).
        $script:ContentBlock = @"
$($script:BeginMarker)
## Now
- #425 Issue 425

portfolio content unchanged since 2026-06-12T12:00:00Z — rendered by render-portfolio.ps1
$($script:EndMarker)
"@
    }

    It 'appends portfolio block when markers are absent from the body' {
        $existingBody = "# My Issue`n`nSome content here."

        $result = Get-SplicedBody -existingBody $existingBody -contentBlock $script:ContentBlock

        $result | Should -Not -BeNullOrEmpty
        $result.Contains($script:BeginMarker) | Should -Be $true -Because 'begin marker must be present'
        $result.Contains($script:EndMarker)   | Should -Be $true -Because 'end marker must be present'
        $result | Should -Match 'Some content here\.'  -Because 'original body content must be preserved'
    }

    It 'replaces content strictly between markers, preserving outside content' {
        $beforeText = 'BEFORE MARKER CONTENT'
        $afterText  = 'AFTER MARKER CONTENT'
        # Updated to new footer label in #720 s1.
        $oldContent = "$($script:BeginMarker)`nold content`nportfolio content unchanged since 2026-01-01T00:00:00Z — rendered by render-portfolio.ps1`n$($script:EndMarker)"
        $existingBody = "$beforeText`n$oldContent`n$afterText"

        $newContent = $script:ContentBlock
        $result = Get-SplicedBody -existingBody $existingBody -contentBlock $newContent

        $result | Should -Not -BeNullOrEmpty
        $result | Should -Match $beforeText  -Because 'content before markers must be preserved'
        $result | Should -Match $afterText   -Because 'content after markers must be preserved'
        $result.Contains('## Now') | Should -Be $true -Because 'new content block must replace old'
        $result | Should -Not -Match 'old content'    -Because 'old content between markers must be replaced'
    }

    It 'returns null when content is identical after stripping timestamp (idempotent no-write F18)' {
        # Identical content except we construct the body with the same logical content
        $existingBody = $script:ContentBlock

        # Same content block — no logical change → must return $null
        $result = Get-SplicedBody -existingBody $existingBody -contentBlock $script:ContentBlock

        $result | Should -BeNullOrEmpty -Because 'identical content after timestamp-strip must return null to prevent a no-op write'
    }

    It 'returns null when only timestamp differs — idempotent (new footer label)' {
        # Updated to new footer label in #720 s1.
        # RED until s2/s3 update Get-SplicedBody footer strip pattern to match new label.
        # The idempotency strip rule must recognize 'portfolio content unchanged since {ts}'
        # just as it currently recognizes 'as of {ts}'.
        $oldTimestampBlock = @"
$($script:BeginMarker)
## Now
- #425 Issue 425

portfolio content unchanged since 2026-01-01T00:00:00Z — rendered by render-portfolio.ps1
$($script:EndMarker)
"@
        $newTimestampBlock = @"
$($script:BeginMarker)
## Now
- #425 Issue 425

portfolio content unchanged since 2026-06-12T18:00:00Z — rendered by render-portfolio.ps1
$($script:EndMarker)
"@
        $existingBody = $oldTimestampBlock

        $result = Get-SplicedBody -existingBody $existingBody -contentBlock $newTimestampBlock

        # Only the timestamp differs — content region is the same → idempotent → $null
        # (The idempotency rule: strip the footer line then compare; if same → $null)
        $result | Should -BeNullOrEmpty -Because 'when only the timestamp differs and content region is identical, Get-SplicedBody must return null (idempotency rule: strip footer then compare)'
    }

    It 'triggers write when existing body uses old footer label and new content uses new label (migration)' {
        # Migration fixture: existing board was rendered with old 'as of' label;
        # new render uses 'portfolio content unchanged since' label.
        # The label change is a semantic content change → Get-SplicedBody must return
        # a non-null body (trigger exactly one write), not null (idempotent skip).
        # RED until s2/s3 update Get-SplicedBody to detect label-change as content change.
        $oldLabelBlock = @"
$($script:BeginMarker)
## Now
- #425 Issue 425

as of 2026-06-12T12:00:00Z — rendered by render-portfolio.ps1
$($script:EndMarker)
"@
        $newLabelBlock = @"
$($script:BeginMarker)
## Now
- #425 Issue 425

portfolio content unchanged since 2026-06-12T12:00:00Z — rendered by render-portfolio.ps1
$($script:EndMarker)
"@
        $existingBody = $oldLabelBlock

        $result = Get-SplicedBody -existingBody $existingBody -contentBlock $newLabelBlock

        $result | Should -Not -BeNullOrEmpty -Because 'label change from old to new footer format is a content change; must trigger exactly one write'
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

    It 'createdAt-desc ordering: creation order != number order → ranked by createdAt desc with priority tiebreak (AC3)' {
        # Fixture where createdAt order DIFFERS from issue number order.
        # AC3 full order key: current-round-spine-first → createdAt desc → priority-label → number.
        # Floats mixed with labeled and unlabeled items.
        # RED until Get-PortfolioBuckets implements createdAt-desc ordering for floats.
        $spec = ConvertFrom-SequenceSpec -yamlText (New-ValidSpecYaml)

        # Round 1 spine issues (425, 571) — should appear first regardless of createdAt
        # Float #802 (newer, unlabeled), float #800 (older, priority:high), float #801 (middle, unlabeled)
        # Expected order after spine: 802 (newest) → 800 (older, priority:high beats #801 at same createdAt)
        # Wait: all have different createdAt so priority-label tiebreak doesn't apply across them.
        # Let's use 800/801 same date, 800 has priority:high.
        # Order: 802 (newest) → 800 (same date as 801, priority:high wins) → 801 (same date, unlabeled)
        $issuesAscending = @(
            (New-IssueState -Number 425  -State 'OPEN' -BlockedBy @() -CreatedAt '2024-01-01T00:00:00Z')
            (New-IssueState -Number 571  -State 'OPEN' -BlockedBy @() -CreatedAt '2024-01-01T00:00:00Z')
            (New-IssueState -Number 800  -State 'OPEN' -BlockedBy @() -CreatedAt '2025-02-01T00:00:00Z' -Labels @('priority: high'))
            (New-IssueState -Number 801  -State 'OPEN' -BlockedBy @() -CreatedAt '2025-02-01T00:00:00Z' -Labels @())
            (New-IssueState -Number 802  -State 'OPEN' -BlockedBy @() -CreatedAt '2025-06-01T00:00:00Z' -Labels @())
        )
        $issuesShuffled = @(
            (New-IssueState -Number 802  -State 'OPEN' -BlockedBy @() -CreatedAt '2025-06-01T00:00:00Z' -Labels @())
            (New-IssueState -Number 571  -State 'OPEN' -BlockedBy @() -CreatedAt '2024-01-01T00:00:00Z')
            (New-IssueState -Number 801  -State 'OPEN' -BlockedBy @() -CreatedAt '2025-02-01T00:00:00Z' -Labels @())
            (New-IssueState -Number 425  -State 'OPEN' -BlockedBy @() -CreatedAt '2024-01-01T00:00:00Z')
            (New-IssueState -Number 800  -State 'OPEN' -BlockedBy @() -CreatedAt '2025-02-01T00:00:00Z' -Labels @('priority: high'))
        )
        $knownChildSet = @()

        $bucketsA = Get-PortfolioBuckets -spec $spec -issueStateObjects $issuesAscending -KnownChildSet $knownChildSet
        $bucketsB = Get-PortfolioBuckets -spec $spec -issueStateObjects $issuesShuffled  -KnownChildSet $knownChildSet

        $fixedTimestamp = '2026-06-12T12:00:00Z'
        $outputA = Format-PortfolioMarkdown -bucketModel $bucketsA -timestamp $fixedTimestamp
        $outputB = Format-PortfolioMarkdown -bucketModel $bucketsB -timestamp $fixedTimestamp

        # Output must be byte-identical regardless of input order (deterministic sort)
        $outputA | Should -Be $outputB -Because 'createdAt-desc ordering must be deterministic regardless of input order (AC3)'

        # Verify ordering: in Now section, #802 (newest float) must appear before #800 and #801
        $pos802 = $outputA.IndexOf('#802')
        $pos800 = $outputA.IndexOf('#800')
        $pos801 = $outputA.IndexOf('#801')
        $pos802 | Should -BeLessThan $pos800 -Because '#802 (created 2025-06-01) must appear before #800 (created 2025-02-01) — createdAt desc'
        $pos802 | Should -BeLessThan $pos801 -Because '#802 (created 2025-06-01) must appear before #801 (created 2025-02-01) — createdAt desc'
        # Priority tiebreak: #800 (priority:high) before #801 (unlabeled) at same createdAt
        $pos800 | Should -BeLessThan $pos801 -Because '#800 (priority:high) must rank before #801 (unlabeled) at same createdAt — priority-label tiebreak (AC3)'
    }
}

# ===========================================================================
Describe 'Invoke-PortfolioRender' {
# ===========================================================================
# Net-new Describe block for #720 s1 (AC8).
# All tests in this block are RED until s2/s3 implement Invoke-PortfolioRender
# with the hard-exit-before-write guard on scan failure.
#
# Stub strategy: define a PowerShell function named `gh` that shadows the
# external `gh` executable within this test's scope chain.  PowerShell
# resolves functions before external commands, so calling `gh <args>` from
# within Invoke-PortfolioRender (which runs in the same session) finds the
# stub first.  The stub records calls to a script-scoped tracking variable
# so the test can assert `gh issue edit` was never reached.

    BeforeEach {
        $script:GhEditCallCount = 0
        $script:GhEditArgs      = @()

        function global:gh {
            param([Parameter(ValueFromRemainingArguments)][string[]]$ghArgs)

            if ($ghArgs -contains 'edit') {
                $script:GhEditCallCount++
                $script:GhEditArgs += ,@($ghArgs)
                # Return success so pipeline continues (proves guard must be BEFORE edit, not reliant on edit failing)
                $global:LASTEXITCODE = 0
                return
            }

            if ($ghArgs -contains 'list') {
                # Simulate sub-issue/float scan failure (non-zero exit, AC8 trigger)
                $global:LASTEXITCODE = 1
                Write-Warning 'stub: gh issue list simulated failure (AC8 test)'
                return
            }

            if ($ghArgs -contains 'api') {
                # Simulate GraphQL scan failure for individual issue fetch
                $global:LASTEXITCODE = 1
                return
            }

            if ($ghArgs -contains 'view') {
                # Return minimal control-tower body so pipeline can continue past step 4
                $global:LASTEXITCODE = 0
                return '{"body":"# Control Tower\n\nNo portfolio block yet."}'
            }

            $global:LASTEXITCODE = 0
        }
    }

    AfterEach {
        Remove-Item function:global:gh -ErrorAction SilentlyContinue
        $script:GhEditCallCount = 0
        $script:GhEditArgs      = @()
    }

    It 'gh issue edit is NOT called (0 times) when subIssues/float scan fails (AC8)' {
        # AC8: when the subIssues/float scan exits non-zero, Invoke-PortfolioRender
        # must hard-exit BEFORE writing — gh issue edit must be invoked 0 times.
        # The board must never be written in a partial/failed scan state.
        # RED until s2/s3 add the AC8 hard-exit guard to Invoke-PortfolioRender.
        #
        # Stub behavior (from BeforeEach):
        #   - `gh issue list`  → exit 1  (simulates scan failure)
        #   - `gh api graphql` → exit 1  (simulates per-issue fetch failure)
        #   - `gh issue view`  → returns minimal JSON (control tower body fetch succeeds)
        #   - `gh issue edit`  → records call, returns 0 (would be the write step)
        #
        # With the AC8 guard: pipeline exits before step 8 (write) → edit count = 0.
        # Without the guard (current state): pipeline continues to step 8 → edit count > 0.

        $tempSpec = [System.IO.Path]::GetTempFileName() -replace '\.tmp$', '.yaml'
        @'
schema_version: 1
control_tower: 704
recently_closed_days: 14
rounds:
  - lane: main
    round: 1
    issues: [425, 571]
'@ | Set-Content -Path $tempSpec -Encoding UTF8

        try {
            try {
                Invoke-PortfolioRender -specPath $tempSpec
            }
            catch {
                # A throw/exit from Invoke-PortfolioRender is acceptable; what matters
                # is that gh issue edit was never reached before that exit.
            }

            $script:GhEditCallCount | Should -Be 0 `
                -Because 'gh issue edit must be called 0 times when the subIssues/float scan fails (AC8)'
        }
        finally {
            if (Test-Path $tempSpec) { Remove-Item $tempSpec -Force -ErrorAction SilentlyContinue }
        }
    }

    It 'full pipeline: float appears in Now, repo-wide closed leaf in RecentlyClosed, and gh issue edit is called once (F1/F2/F3 wiring)' {
        # Success-path integration test (F7 / review finding).
        # Stubs all gh calls to return realistic data; exercises the full
        # Invoke-PortfolioRender pipeline:
        #   open-scan  → #800 float + umbrellas #425/#571
        #   closed-scan → #801 recently-closed leaf (within window)
        #   GraphQL #425 → OPEN, subIssues: [#900]
        #   GraphQL #571 → OPEN, subIssues: []
        #   view #704   → body with no portfolio block yet
        #   edit #704   → captured to $script:GhEditBody
        #
        # Expected board state after fix:
        #   Now:            #425 (spine), #571 (spine), #800 (unsequenced float)
        #   CoverageGaps:   (#571: no leaves modeled yet)   — #425 has child #900
        #   RecentlyClosed: #801 (from ClosedLeafItems, not issueStateObjects)

        $script:GhEditCallCount = 0
        $script:GhEditBody      = ''
        $script:SuccessGhCalls  = @()

        $closedAt801 = (Get-Date).AddDays(-5).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')

        function global:gh {
            param([Parameter(ValueFromRemainingArguments)][string[]]$ghArgs)
            $script:SuccessGhCalls += ,@($ghArgs)

            if ($ghArgs -contains 'edit') {
                $script:GhEditCallCount++
                $bodyIdx = [Array]::IndexOf([string[]]$ghArgs, '--body')
                if ($bodyIdx -ge 0 -and ($bodyIdx + 1) -lt $ghArgs.Count) {
                    $script:GhEditBody = $ghArgs[$bodyIdx + 1]
                }
                $global:LASTEXITCODE = 0
                return
            }

            if ($ghArgs -contains 'list') {
                if ($ghArgs -contains 'closed') {
                    $global:LASTEXITCODE = 0
                    return "[{`"number`":801,`"title`":`"Recently closed leaf`",`"closedAt`":`"$closedAt801`",`"labels`":[]}]"
                }
                if ($ghArgs -contains 'triage') {
                    $global:LASTEXITCODE = 0
                    return '[]'
                }
                # open scan: spine leaf #900, float #800, umbrellas #425 and #571
                $global:LASTEXITCODE = 0
                return '[{"number":900,"title":"Spine leaf 900","labels":[],"createdAt":"2026-01-02T00:00:00Z"},{"number":800,"title":"Float issue 800","labels":[],"createdAt":"2026-01-01T00:00:00Z"},{"number":425,"title":"Umbrella 425","labels":[],"createdAt":"2025-06-01T00:00:00Z"},{"number":571,"title":"Umbrella 571","labels":[],"createdAt":"2025-05-01T00:00:00Z"}]'
            }

            if ($ghArgs -contains 'api') {
                # Dispatch by issue number in the query string (last element of args)
                $queryStr = $ghArgs | Where-Object { $_ -like 'query=*' } | Select-Object -Last 1
                $issueNum = 0
                if ($queryStr -match 'issue\(number:\s*(\d+)') { $issueNum = [int]$Matches[1] }

                if ($issueNum -eq 425) {
                    $global:LASTEXITCODE = 0
                    return '{"data":{"repository":{"issue":{"number":425,"title":"Umbrella 425","state":"OPEN","closedAt":null,"createdAt":"2025-06-01T00:00:00Z","labels":{"totalCount":0,"nodes":[]},"blockedBy":{"totalCount":0,"nodes":[]},"subIssues":{"nodes":[{"number":900}]}}}}}'
                }
                if ($issueNum -eq 571) {
                    $global:LASTEXITCODE = 0
                    return '{"data":{"repository":{"issue":{"number":571,"title":"Umbrella 571","state":"OPEN","closedAt":null,"createdAt":"2025-05-01T00:00:00Z","labels":{"totalCount":0,"nodes":[]},"blockedBy":{"totalCount":0,"nodes":[]},"subIssues":{"nodes":[]}}}}}'
                }
                if ($issueNum -eq 900) {
                    # Spine leaf — known child of umbrella #425; queried in step 3b after CR-5 fix
                    $global:LASTEXITCODE = 0
                    return '{"data":{"repository":{"issue":{"number":900,"title":"Spine leaf 900","state":"OPEN","closedAt":null,"createdAt":"2026-01-02T00:00:00Z","labels":{"totalCount":0,"nodes":[]},"blockedBy":{"totalCount":0,"nodes":[]}}}}}'
                }
                if ($issueNum -eq 800) {
                    # Float candidate — queried in step 3b, no subIssues field
                    $global:LASTEXITCODE = 0
                    return '{"data":{"repository":{"issue":{"number":800,"title":"Float issue 800","state":"OPEN","closedAt":null,"createdAt":"2026-01-01T00:00:00Z","labels":{"totalCount":0,"nodes":[]},"blockedBy":{"totalCount":0,"nodes":[]}}}}}'
                }
                $global:LASTEXITCODE = 0
                return '{"data":{"repository":{"issue":null}}}'
            }

            if ($ghArgs -contains 'view') {
                $global:LASTEXITCODE = 0
                return '{"body":"# Control Tower\n\nNo portfolio block yet."}'
            }

            $global:LASTEXITCODE = 0
        }

        $tempSpec2 = [System.IO.Path]::GetTempFileName() -replace '\.tmp$', '.yaml'
        @'
schema_version: 1
control_tower: 704
recently_closed_days: 14
rounds:
  - lane: main
    round: 1
    issues: [425, 571]
'@ | Set-Content -Path $tempSpec2 -Encoding UTF8

        try {
            Invoke-PortfolioRender -specPath $tempSpec2

            $script:GhEditCallCount | Should -Be 1 `
                -Because 'pipeline should write the board once when body changes'

            $script:GhEditBody | Should -Match '#800' `
                -Because 'float issue #800 must appear in the rendered board (AC4/AC1 wiring verified)'

            $script:GhEditBody | Should -Match '#801' `
                -Because 'repo-wide closed leaf #801 must appear in RecentlyClosed (AC9 wiring verified)'

            $script:GhEditBody | Should -Match '#900' `
                -Because '#900 is a spine leaf (known child of umbrella #425) and must appear in the rendered board (CR-5 fix verified)'

            $script:GhEditBody | Should -Match 'unsequenced' `
                -Because '#800 is a float and must be tagged (unsequenced) in Now'

            $script:GhEditBody | Should -Match '571.*no leaves modeled yet' `
                -Because '#571 has no sub-issues in KnownChildSet so CoverageGaps must emit a note for it (AC7)'
        }
        finally {
            if (Test-Path $tempSpec2) { Remove-Item $tempSpec2 -Force -ErrorAction SilentlyContinue }
        }
    }

    It 'open-ceiling-throws: open scan at limit fires fail-loud guard before gh issue edit is reached' {
        # RED driver for s2 fix: -issueScanLimit param does not exist yet, so
        # calling it throws ParameterBindingException.  $script:ScanReached stays
        # $false and the ScanReached assertion fails — correct RED failure.
        #
        # GREEN (after s2): open scan stub sets ScanReached=$true, ceiling guard
        # fires Write-Error -ErrorAction Stop, edit never reached, both assertions pass.

        $script:ScanReached    = $false
        $script:GhEditCallCount = 0

        function global:gh {
            param([Parameter(ValueFromRemainingArguments)][string[]]$ghArgs)

            if ($ghArgs -contains 'edit') {
                $script:GhEditCallCount++
                $global:LASTEXITCODE = 0
                return
            }

            if ($ghArgs -contains 'list') {
                if ($ghArgs -contains 'closed') {
                    # 1 item — below limit, closed guard won't fire
                    $global:LASTEXITCODE = 0
                    return '[{"number":10,"title":"c1","closedAt":"2026-01-01T00:00:00Z","labels":[]}]'
                }
                if ($ghArgs -contains 'triage') {
                    $global:LASTEXITCODE = 0
                    return '[]'
                }
                # open scan fallthrough — return exactly 3 items (= limit) and mark reached
                $script:ScanReached = $true
                $global:LASTEXITCODE = 0
                return '[{"number":1,"title":"t1","labels":[],"createdAt":"2026-01-01T00:00:00Z"},{"number":2,"title":"t2","labels":[],"createdAt":"2026-01-01T00:00:00Z"},{"number":3,"title":"t3","labels":[],"createdAt":"2026-01-01T00:00:00Z"}]'
            }

            $global:LASTEXITCODE = 0
        }

        $tempSpecCeil1 = [System.IO.Path]::GetTempFileName() -replace '\.tmp$', '.yaml'
        @'
schema_version: 1
control_tower: 704
recently_closed_days: 14
rounds:
  - lane: main
    round: 1
    issues: [425, 571]
'@ | Set-Content -Path $tempSpecCeil1 -Encoding UTF8

        try {
            { Invoke-PortfolioRender -specPath $tempSpecCeil1 -issueScanLimit 3 } |
                Should -Throw -ExpectedMessage '*refusing to render*' `
                -Because 'ceiling guard must throw with the truncated-board message before gh issue edit is reached'

            $script:ScanReached | Should -BeTrue `
                -Because 'gh stub must have been called before the ceiling guard fired — if false, function failed with ParameterBindingException instead'

            $script:GhEditCallCount | Should -Be 0 `
                -Because 'gh issue edit must never be reached when the open ceiling guard fires'
        }
        finally {
            if (Test-Path $tempSpecCeil1) { Remove-Item $tempSpecCeil1 -Force -ErrorAction SilentlyContinue }
        }
    }

    It 'closed-ceiling-throws: closed scan at limit fires fail-loud guard before gh issue edit is reached' {
        # RED driver for s2 fix: -issueScanLimit param does not exist yet, so
        # calling it throws ParameterBindingException.  $script:ScanReached stays
        # $false and the ScanReached assertion fails — correct RED failure.
        #
        # GREEN (after s2): open scan (2 items) passes, closed scan stub sets
        # ScanReached=$true, closed ceiling guard fires Write-Error -ErrorAction Stop,
        # edit never reached, both assertions pass.

        $script:ScanReached    = $false
        $script:GhEditCallCount = 0

        function global:gh {
            param([Parameter(ValueFromRemainingArguments)][string[]]$ghArgs)

            if ($ghArgs -contains 'edit') {
                $script:GhEditCallCount++
                $global:LASTEXITCODE = 0
                return
            }

            if ($ghArgs -contains 'list') {
                if ($ghArgs -contains 'closed') {
                    # 3 items — exactly at limit, closed ceiling guard fires; mark reached
                    $script:ScanReached = $true
                    $global:LASTEXITCODE = 0
                    return '[{"number":10,"title":"c1","closedAt":"2026-01-01T00:00:00Z","labels":[]},{"number":11,"title":"c2","closedAt":"2026-01-01T00:00:00Z","labels":[]},{"number":12,"title":"c3","closedAt":"2026-01-01T00:00:00Z","labels":[]}]'
                }
                if ($ghArgs -contains 'triage') {
                    $global:LASTEXITCODE = 0
                    return '[]'
                }
                # open scan fallthrough — 2 items, below limit, open guard won't fire
                $global:LASTEXITCODE = 0
                return '[{"number":1,"title":"t1","labels":[],"createdAt":"2026-01-01T00:00:00Z"},{"number":2,"title":"t2","labels":[],"createdAt":"2026-01-01T00:00:00Z"}]'
            }

            $global:LASTEXITCODE = 0
        }

        $tempSpecCeil2 = [System.IO.Path]::GetTempFileName() -replace '\.tmp$', '.yaml'
        @'
schema_version: 1
control_tower: 704
recently_closed_days: 14
rounds:
  - lane: main
    round: 1
    issues: [425, 571]
'@ | Set-Content -Path $tempSpecCeil2 -Encoding UTF8

        try {
            { Invoke-PortfolioRender -specPath $tempSpecCeil2 -issueScanLimit 3 } |
                Should -Throw -ExpectedMessage '*truncated RecentlyClosed*' `
                -Because 'ceiling guard must throw with the truncated-RecentlyClosed message before gh issue edit is reached'

            $script:ScanReached | Should -BeTrue `
                -Because 'gh stub must have been called before the ceiling guard fired — if false, function failed with ParameterBindingException instead'

            $script:GhEditCallCount | Should -Be 0 `
                -Because 'gh issue edit must never be reached when the closed ceiling guard fires'
        }
        finally {
            if (Test-Path $tempSpecCeil2) { Remove-Item $tempSpecCeil2 -Force -ErrorAction SilentlyContinue }
        }
    }

    It 'closed-ceiling-throws-at-api-cap: closed guard fires at min(issueScanLimit,1000) when issueScanLimit exceeds Search API hard cap' {
        # AC4 clamp-path coverage: with -issueScanLimit 1500 the effective closed ceiling is
        # [Math]::Min(1500, 1000) = 1000. The closed stub returns exactly 1000 items so
        # closedLeaves.Count (1000) >= closedCeiling (1000) -> guard fires. A regression
        # replacing [Math]::Min($issueScanLimit,1000) with plain $issueScanLimit would make
        # closedCeiling = 1500, the stub's 1000 results would no longer trigger the guard, and
        # the test would fail — exactly the mutation that the existing closed-ceiling-throws
        # test (with issueScanLimit 3) cannot catch.

        $script:ScanReached    = $false
        $script:GhEditCallCount = 0

        function global:gh {
            param([Parameter(ValueFromRemainingArguments)][string[]]$ghArgs)
            if ($ghArgs -contains 'edit') {
                $script:GhEditCallCount++
                $global:LASTEXITCODE = 0
                return
            }
            if ($ghArgs -contains 'list') {
                if ($ghArgs -contains 'closed') {
                    $script:ScanReached = $true
                    $global:LASTEXITCODE = 0
                    # Return exactly 1000 items — hits [Math]::Min(1500, 1000) = 1000
                    $rows = (1..1000 | ForEach-Object { "{`"number`":$_,`"title`":`"c$_`",`"closedAt`":`"2026-01-01T00:00:00Z`",`"labels`":[]}" }) -join ','
                    return "[$rows]"
                }
                if ($ghArgs -contains 'triage') {
                    $global:LASTEXITCODE = 0
                    return '[]'
                }
                # open scan fallthrough — return 1 item, well below issueScanLimit 1500
                $global:LASTEXITCODE = 0
                return '[{"number":1,"title":"t1","labels":[],"createdAt":"2026-01-01T00:00:00Z"}]'
            }
            $global:LASTEXITCODE = 0
        }

        $tempSpecCeil4 = [System.IO.Path]::GetTempFileName() -replace '\.tmp$', '.yaml'
        @'
schema_version: 1
control_tower: 704
recently_closed_days: 14
rounds:
  - lane: main
    round: 1
    issues: [425, 571]
'@ | Set-Content -Path $tempSpecCeil4 -Encoding UTF8

        try {
            try {
                Invoke-PortfolioRender -specPath $tempSpecCeil4 -issueScanLimit 1500
            }
            catch {
                # Expected: closed ceiling guard throws at [Math]::Min(1500,1000)=1000; swallow.
            }

            $script:ScanReached | Should -BeTrue `
                -Because 'closed scan stub must run before the guard — if false, the call never reached the closed scan'

            $script:GhEditCallCount | Should -Be 0 `
                -Because 'gh issue edit must not be reached when the closed ceiling fires at [Math]::Min(1500,1000)=1000'

            { Invoke-PortfolioRender -specPath $tempSpecCeil4 -issueScanLimit 1500 } |
                Should -Throw -ExpectedMessage '*GitHub Search API hard cap*' `
                -Because 'api-cap path must throw the GitHub Search API hard cap message specifically'
        }
        finally {
            if (Test-Path $tempSpecCeil4) { Remove-Item $tempSpecCeil4 -Force -ErrorAction SilentlyContinue }
        }
    }

    It 'triage-ceiling-warns: triage scan at limit emits Write-Warning and render completes (warn-and-continue)' {
        # RED driver for s2 fix: -issueScanLimit param does not exist yet, so
        # calling it throws ParameterBindingException (unhandled, no try/catch) —
        # Pester marks the test FAILED with ParameterBindingException.  Correct RED.
        #
        # GREEN (after s2): open/closed scans below limit, triage scan at limit fires
        # Write-Warning (warn-and-continue, never throw), render completes, gh issue edit
        # is called exactly once, and the captured warning stream contains at least one
        # WarningRecord for the triage ceiling.

        $script:GhEditCallCount = 0

        function global:gh {
            param([Parameter(ValueFromRemainingArguments)][string[]]$ghArgs)

            if ($ghArgs -contains 'edit') {
                $script:GhEditCallCount++
                $global:LASTEXITCODE = 0
                return
            }

            if ($ghArgs -contains 'view') {
                $global:LASTEXITCODE = 0
                return '{"body":"# Control Tower\n\nNo portfolio block yet."}'
            }

            if ($ghArgs -contains 'list') {
                if ($ghArgs -contains 'closed') {
                    # 1 item — below limit, closed guard won't fire
                    $global:LASTEXITCODE = 0
                    return '[{"number":10,"title":"c1","closedAt":"2026-01-01T00:00:00Z","labels":[]}]'
                }
                if ($ghArgs -contains 'triage') {
                    # 3 items — exactly at limit, triage ceiling fires Write-Warning
                    $global:LASTEXITCODE = 0
                    return '[{"number":1},{"number":2},{"number":3}]'
                }
                # open scan fallthrough — 1 item, below limit, open guard won't fire
                $global:LASTEXITCODE = 0
                return '[{"number":425,"title":"Umbrella 425","labels":[],"createdAt":"2025-06-01T00:00:00Z"}]'
            }

            if ($ghArgs -contains 'api') {
                $queryStr = $ghArgs | Where-Object { $_ -like 'query=*' } | Select-Object -Last 1
                $issueNum = 0
                if ($queryStr -match 'issue\(number:\s*(\d+)') { $issueNum = [int]$Matches[1] }
                $global:LASTEXITCODE = 0
                return "{`"data`":{`"repository`":{`"issue`":{`"number`":$issueNum,`"title`":`"t$issueNum`",`"state`":`"OPEN`",`"closedAt`":null,`"createdAt`":`"2026-01-01T00:00:00Z`",`"labels`":{`"totalCount`":0,`"nodes`":[]},`"blockedBy`":{`"totalCount`":0,`"nodes`":[]},`"subIssues`":{`"nodes`":[]}}}}}"
            }

            $global:LASTEXITCODE = 0
        }

        $tempSpecCeil3 = [System.IO.Path]::GetTempFileName() -replace '\.tmp$', '.yaml'
        @'
schema_version: 1
control_tower: 704
recently_closed_days: 14
rounds:
  - lane: main
    round: 1
    issues: [425, 571]
'@ | Set-Content -Path $tempSpecCeil3 -Encoding UTF8

        try {
            # NO try/catch: in RED state ParameterBindingException is unhandled
            # and Pester marks the test FAILED — correct RED failure mode.
            # In GREEN state the function completes (warn-and-continue) and
            # warnings are captured via the 3>&1 stream redirect.
            $captured = Invoke-PortfolioRender -specPath $tempSpecCeil3 -issueScanLimit 3 3>&1

            $warnings = @($captured | Where-Object { $_ -is [System.Management.Automation.WarningRecord] })
            $warnings.Count | Should -BeGreaterThan 0 `
                -Because 'triage ceiling must emit Write-Warning when triage scan returns count >= issueScanLimit'

            $warnings[0].Message | Should -Match 'returned 3 results' `
                -Because 'the captured warning must be the triage ceiling warning (count/limit included), not a parse or exit-code warning'

            $script:GhEditCallCount | Should -Be 1 `
                -Because 'render must complete with exactly one control-tower write (warn-and-continue, not abort)'
        }
        finally {
            if (Test-Path $tempSpecCeil3) { Remove-Item $tempSpecCeil3 -Force -ErrorAction SilentlyContinue }
        }
    }
}
