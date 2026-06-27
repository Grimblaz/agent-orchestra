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
# Get-PortfolioBuckets v1 tests RETIRED (s2 of #753)
# These tests referenced v1 model properties (.Now, .Next, .Blocked,
# .CoverageGaps, isFloat, blockerAnnotations, KnownChildSet) which no
# longer exist in the v2 implementation. Replaced by 'Get-PortfolioBuckets v2'
# Describe block below.
# ===========================================================================

# ===========================================================================
Describe 'Get-PortfolioBuckets v2' {
# ===========================================================================

    It 'ActiveUmbrella is first OPEN umbrella in list order (AC3)' {
        $spec = ConvertFrom-SequenceSpec -yamlText (New-ValidSpecYaml -Umbrellas @(476, 571))
        $umbrella476 = New-IssueState -Number 476 -State 'OPEN' `
            -SubIssues @{ totalCount = 0; nodes = @() }
        $umbrella571 = New-IssueState -Number 571 -State 'OPEN' `
            -SubIssues @{ totalCount = 0; nodes = @() }

        $buckets = Get-PortfolioBuckets -spec $spec -issueStateObjects @($umbrella476, $umbrella571)

        $buckets.ActiveUmbrella | Should -Not -BeNullOrEmpty -Because 'first OPEN umbrella must be the ActiveUmbrella'
        $buckets.ActiveUmbrella.number | Should -Be 476 -Because '#476 is first in spec list and OPEN → ActiveUmbrella'
    }

    It 'skips CLOSED listed umbrella for ActiveUmbrella and emits DriftWarning (AC3)' {
        $spec = ConvertFrom-SequenceSpec -yamlText (New-ValidSpecYaml -Umbrellas @(476, 571))
        $umbrella476 = New-IssueState -Number 476 -State 'CLOSED' `
            -SubIssues @{ totalCount = 0; nodes = @() }
        $umbrella571 = New-IssueState -Number 571 -State 'OPEN' `
            -SubIssues @{ totalCount = 0; nodes = @() }

        $buckets = Get-PortfolioBuckets -spec $spec -issueStateObjects @($umbrella476, $umbrella571)

        $buckets.ActiveUmbrella.number | Should -Be 571 -Because '#476 is CLOSED → skip; #571 is OPEN → ActiveUmbrella'
        $buckets.DriftWarnings | Should -Contain '⚠️ listed umbrella #476 is closed' `
            -Because 'a CLOSED listed umbrella must emit a DriftWarning (AC3)'
    }

    It 'ActiveUmbrella is null when all listed umbrellas are closed (AC3)' {
        $spec = ConvertFrom-SequenceSpec -yamlText (New-ValidSpecYaml -Umbrellas @(476, 571))
        $umbrella476 = New-IssueState -Number 476 -State 'CLOSED' `
            -SubIssues @{ totalCount = 0; nodes = @() }
        $umbrella571 = New-IssueState -Number 571 -State 'CLOSED' `
            -SubIssues @{ totalCount = 0; nodes = @() }

        $buckets = Get-PortfolioBuckets -spec $spec -issueStateObjects @($umbrella476, $umbrella571)

        $buckets.ActiveUmbrella | Should -BeNullOrEmpty -Because 'no OPEN listed umbrella → ActiveUmbrella must be null'
    }

    It 'ActiveChildren are open direct children of active umbrella in priority→recency→number order (AC4)' {
        $spec = ConvertFrom-SequenceSpec -yamlText (New-ValidSpecYaml -Umbrellas @(476, 571))
        $child900 = New-IssueState -Number 900 -State 'OPEN' -CreatedAt '2025-06-01T00:00:00Z' `
            -Parent @{ number = 476 } -SubIssues @{ totalCount = 0; nodes = @() }
        $child901 = New-IssueState -Number 901 -State 'OPEN' -CreatedAt '2025-01-01T00:00:00Z' `
            -Parent @{ number = 476 } -SubIssues @{ totalCount = 0; nodes = @() }
        $umbrella476 = New-IssueState -Number 476 -State 'OPEN' `
            -SubIssues @{
                totalCount = 2
                nodes = @(
                    @{ number = 900; state = 'OPEN' },
                    @{ number = 901; state = 'OPEN' }
                )
            }

        $buckets = Get-PortfolioBuckets -spec $spec -issueStateObjects @($umbrella476, $child900, $child901)

        $buckets.ActiveChildren | Should -Not -BeNullOrEmpty
        $buckets.ActiveChildren.Count | Should -Be 2 -Because 'both open children must appear'
        # 900 has newer createdAt → must appear before 901
        $idx900 = [array]::IndexOf([object[]]$buckets.ActiveChildren, ($buckets.ActiveChildren | Where-Object { $_.number -eq 900 }))
        $idx901 = [array]::IndexOf([object[]]$buckets.ActiveChildren, ($buckets.ActiveChildren | Where-Object { $_.number -eq 901 }))
        $idx900 | Should -BeLessThan $idx901 -Because '#900 (newer createdAt) must rank before #901 (AC4 priority→recency→number)'
    }

    It 'ActiveChildren have BlockedAnnotation when blockedBy non-empty (AC4)' {
        $spec = ConvertFrom-SequenceSpec -yamlText (New-ValidSpecYaml -Umbrellas @(476, 571))
        $child900 = New-IssueState -Number 900 -State 'OPEN' -BlockedBy @(800, 801) `
            -Parent @{ number = 476 } -SubIssues @{ totalCount = 0; nodes = @() }
        $umbrella476 = New-IssueState -Number 476 -State 'OPEN' `
            -SubIssues @{
                totalCount = 1
                nodes = @( @{ number = 900; state = 'OPEN' } )
            }

        $buckets = Get-PortfolioBuckets -spec $spec -issueStateObjects @($umbrella476, $child900)

        $childEntry = $buckets.ActiveChildren | Where-Object { $_.number -eq 900 }
        $childEntry | Should -Not -BeNullOrEmpty
        $childEntry.BlockedAnnotation | Should -Match '⛔ blocked by' -Because 'AC4: blocked child must have BlockedAnnotation'
        $childEntry.BlockedAnnotation | Should -Match '#800' -Because 'blocker #800 must appear in annotation'
        $childEntry.BlockedAnnotation | Should -Match '#801' -Because 'blocker #801 must appear in annotation'
    }

    It 'ActiveChildren number-asc tiebreak is deterministic for byte-identical renders (AC4)' {
        $spec = ConvertFrom-SequenceSpec -yamlText (New-ValidSpecYaml -Umbrellas @(476, 571))
        $sameDate = '2025-06-01T00:00:00Z'
        $child900 = New-IssueState -Number 900 -State 'OPEN' -CreatedAt $sameDate `
            -Parent @{ number = 476 } -SubIssues @{ totalCount = 0; nodes = @() }
        $child901 = New-IssueState -Number 901 -State 'OPEN' -CreatedAt $sameDate `
            -Parent @{ number = 476 } -SubIssues @{ totalCount = 0; nodes = @() }
        $umbrella476 = New-IssueState -Number 476 -State 'OPEN' `
            -SubIssues @{
                totalCount = 2
                nodes = @(
                    @{ number = 901; state = 'OPEN' },
                    @{ number = 900; state = 'OPEN' }
                )
            }

        $buckets = Get-PortfolioBuckets -spec $spec -issueStateObjects @($umbrella476, $child900, $child901)

        $idx900 = [array]::IndexOf([object[]]$buckets.ActiveChildren, ($buckets.ActiveChildren | Where-Object { $_.number -eq 900 }))
        $idx901 = [array]::IndexOf([object[]]$buckets.ActiveChildren, ($buckets.ActiveChildren | Where-Object { $_.number -eq 901 }))
        $idx900 | Should -BeLessThan $idx901 -Because 'number-asc tiebreak: #900 before #901 when priority and createdAt are equal (AC4)'
    }

    It 'RankedUmbrellas contains all listed umbrellas in spec order (AC5)' {
        $spec = ConvertFrom-SequenceSpec -yamlText (New-ValidSpecYaml -Umbrellas @(476, 571))
        $umbrella476 = New-IssueState -Number 476 -State 'OPEN' `
            -SubIssues @{ totalCount = 0; nodes = @() }
        $umbrella571 = New-IssueState -Number 571 -State 'OPEN' `
            -SubIssues @{ totalCount = 0; nodes = @() }

        $buckets = Get-PortfolioBuckets -spec $spec -issueStateObjects @($umbrella476, $umbrella571)

        $buckets.RankedUmbrellas | Should -HaveCount 2
        $buckets.RankedUmbrellas[0].Number | Should -Be 476 -Because 'first ranked umbrella must match first in spec list'
        $buckets.RankedUmbrellas[1].Number | Should -Be 571 -Because 'second ranked umbrella must match second in spec list'
    }

    It 'RankedUmbrellas Done/Total counts direct children only (AC5)' {
        $spec = ConvertFrom-SequenceSpec -yamlText (New-ValidSpecYaml -Umbrellas @(476, 571))
        $umbrella476 = New-IssueState -Number 476 -State 'OPEN' `
            -SubIssues @{
                totalCount = 2
                nodes = @(
                    @{ number = 900; state = 'OPEN'   },
                    @{ number = 901; state = 'CLOSED' }
                )
            }

        $buckets = Get-PortfolioBuckets -spec $spec -issueStateObjects @($umbrella476)

        $ranked476 = $buckets.RankedUmbrellas | Where-Object { $_.Number -eq 476 }
        $ranked476 | Should -Not -BeNullOrEmpty
        $ranked476.Total | Should -Be 2 -Because 'Total = count of direct child nodes (AC5)'
        $ranked476.Done  | Should -Be 1 -Because 'Done = count of CLOSED direct child nodes (AC5)'
        $ranked476.DoneTotalLabel | Should -Be '1/2' -Because 'DoneTotalLabel must be Done/Total'
    }

    It 'closed child counts as Done in RankedUmbrellas regardless of its own children (AC5)' {
        $spec = ConvertFrom-SequenceSpec -yamlText (New-ValidSpecYaml -Umbrellas @(476, 571))
        # Node 900 is a closed child-umbrella; its own sub-issues are irrelevant for Done count
        $umbrella476 = New-IssueState -Number 476 -State 'OPEN' `
            -SubIssues @{
                totalCount = 2
                nodes = @(
                    @{ number = 900; state = 'CLOSED' },   # closed child-umbrella → counts as Done
                    @{ number = 901; state = 'OPEN'   }
                )
            }

        $buckets = Get-PortfolioBuckets -spec $spec -issueStateObjects @($umbrella476)

        $ranked476 = $buckets.RankedUmbrellas | Where-Object { $_.Number -eq 476 }
        $ranked476.Done | Should -Be 1 -Because 'CLOSED child-umbrella counts as Done; grandchildren are irrelevant (AC5)'
    }

    It 'zero-children umbrella shows "0/0 (no children linked)" in RankedUmbrellas (AC5)' {
        $spec = ConvertFrom-SequenceSpec -yamlText (New-ValidSpecYaml -Umbrellas @(476, 571))
        $umbrella476 = New-IssueState -Number 476 -State 'OPEN' `
            -SubIssues @{ totalCount = 0; nodes = @() }

        $buckets = Get-PortfolioBuckets -spec $spec -issueStateObjects @($umbrella476)

        $ranked476 = $buckets.RankedUmbrellas | Where-Object { $_.Number -eq 476 }
        $ranked476.DoneTotalLabel | Should -Be '0/0 (no children linked)' `
            -Because 'zero-children umbrella must show the no-children-linked label (AC5)'
    }

    It 'Triage contains open∧parent-null∧totalCount-0∧not-in-list issues (AC6)' {
        $spec = ConvertFrom-SequenceSpec -yamlText (New-ValidSpecYaml -Umbrellas @(476, 571))
        $umbrella476 = New-IssueState -Number 476 -State 'OPEN' `
            -SubIssues @{ totalCount = 0; nodes = @() }
        # Classic triage candidate: open, parent null, totalCount 0, not in umbrella list
        $triageIssue = New-IssueState -Number 999 -State 'OPEN' -Parent $null `
            -SubIssues @{ totalCount = 0; nodes = @() }

        $buckets = Get-PortfolioBuckets -spec $spec -issueStateObjects @($umbrella476, $triageIssue)

        $buckets.Triage | Should -Not -BeNullOrEmpty
        ($buckets.Triage | ForEach-Object { $_.number }) | Should -Contain 999 `
            -Because 'open∧parent-null∧totalCount-0∧not-in-list → Triage (AC6)'
    }

    It 'Triage cap is 5 with TriageResidualCount for overflow (AC6)' {
        $spec = ConvertFrom-SequenceSpec -yamlText (New-ValidSpecYaml -Umbrellas @(476, 571))
        $triageIssues = 1..8 | ForEach-Object {
            New-IssueState -Number (1000 + $_) -State 'OPEN' -Parent $null `
                -SubIssues @{ totalCount = 0; nodes = @() }
        }

        $buckets = Get-PortfolioBuckets -spec $spec -issueStateObjects $triageIssues

        $buckets.Triage.Count | Should -Be 5 -Because 'Triage capped at 5 items (AC6)'
        $buckets.TriageResidualCount | Should -Be 3 -Because '8 candidates - 5 cap = 3 residual (AC6)'
    }

    It 'Triage excludes issues with non-null parent even when not in umbrella list (AC6 / M4 — NO inversion fallback)' {
        $spec = ConvertFrom-SequenceSpec -yamlText (New-ValidSpecYaml -Umbrellas @(476, 571))
        # Issue 900 has a parent → must NOT appear in Triage (parent-null is required)
        $childIssue = New-IssueState -Number 900 -State 'OPEN' -Parent @{ number = 476 } `
            -SubIssues @{ totalCount = 0; nodes = @() }

        $buckets = Get-PortfolioBuckets -spec $spec -issueStateObjects @($childIssue)

        $triageNums = @($buckets.Triage | ForEach-Object { $_.number })
        $triageNums | Should -Not -Contain 900 `
            -Because 'non-null parent disqualifies from Triage regardless of umbrella membership (AC6 / M4 — no inversion fallback)'
    }

    It 'Triage excludes issues with subIssues.totalCount > 0 (AC6)' {
        $spec = ConvertFrom-SequenceSpec -yamlText (New-ValidSpecYaml -Umbrellas @(476, 571))
        # Issue 800 is open, parent-null, but has subIssues → NOT a triage candidate
        $parentIssue = New-IssueState -Number 800 -State 'OPEN' -Parent $null `
            -SubIssues @{ totalCount = 2; nodes = @(@{ number = 900; state = 'OPEN' }) }

        $buckets = Get-PortfolioBuckets -spec $spec -issueStateObjects @($parentIssue)

        $triageNums = @($buckets.Triage | ForEach-Object { $_.number })
        $triageNums | Should -Not -Contain 800 `
            -Because 'issues with subIssues.totalCount > 0 are not leaf issues and must be excluded from Triage (AC6)'
    }

    It 'DriftWarnings flags open issue with totalCount>0 not in list (AC7)' {
        $spec = ConvertFrom-SequenceSpec -yamlText (New-ValidSpecYaml -Umbrellas @(476, 571))
        # Issue 800 is open and has sub-issues but NOT in the umbrellas list → DriftWarning
        $unlisted = New-IssueState -Number 800 -State 'OPEN' `
            -SubIssues @{ totalCount = 3; nodes = @(@{ number = 900; state = 'OPEN' }) }

        $buckets = Get-PortfolioBuckets -spec $spec -issueStateObjects @($unlisted)

        $buckets.DriftWarnings | Should -Contain '⚠️ open umbrella #800 not in ranked list' `
            -Because 'open issue with subIssues.totalCount>0 not in umbrella list must emit DriftWarning (AC7)'
    }

    It 'DriftWarnings flags closed listed umbrella (AC7)' {
        $spec = ConvertFrom-SequenceSpec -yamlText (New-ValidSpecYaml -Umbrellas @(476, 571))
        $umbrella476 = New-IssueState -Number 476 -State 'CLOSED' `
            -SubIssues @{ totalCount = 0; nodes = @() }
        $umbrella571 = New-IssueState -Number 571 -State 'OPEN' `
            -SubIssues @{ totalCount = 0; nodes = @() }

        $buckets = Get-PortfolioBuckets -spec $spec -issueStateObjects @($umbrella476, $umbrella571)

        $buckets.DriftWarnings | Should -Contain '⚠️ listed umbrella #476 is closed' `
            -Because 'CLOSED listed umbrella must emit DriftWarning (AC7)'
    }

    It 'IntegrityWarnings fires when totalCount does not match returned nodes count (AC8)' {
        $spec = ConvertFrom-SequenceSpec -yamlText (New-ValidSpecYaml -Umbrellas @(476, 571))
        # totalCount says 5 but only 1 node returned → truncation warning
        $umbrella476 = New-IssueState -Number 476 -State 'OPEN' `
            -SubIssues @{
                totalCount = 5
                nodes = @( @{ number = 900; state = 'OPEN' } )
            }

        $buckets = Get-PortfolioBuckets -spec $spec -issueStateObjects @($umbrella476)

        $buckets.IntegrityWarnings | Should -HaveCount 1
        $buckets.IntegrityWarnings[0] | Should -Match 'umbrella #476.*totalCount=5.*only 1 nodes returned' `
            -Because 'mismatch between totalCount and returned nodes must emit IntegrityWarning (AC8)'
    }

    It 'IntegrityWarnings does not block rendering (AC8 warn-and-render)' {
        $spec = ConvertFrom-SequenceSpec -yamlText (New-ValidSpecYaml -Umbrellas @(476, 571))
        $umbrella476 = New-IssueState -Number 476 -State 'OPEN' `
            -SubIssues @{
                totalCount = 5
                nodes = @( @{ number = 900; state = 'OPEN' } )
            }
        $umbrella571 = New-IssueState -Number 571 -State 'OPEN' `
            -SubIssues @{ totalCount = 0; nodes = @() }

        # Must not throw; must return a model with RankedUmbrellas even when warnings fire
        $buckets = Get-PortfolioBuckets -spec $spec -issueStateObjects @($umbrella476, $umbrella571)

        $buckets | Should -Not -BeNullOrEmpty -Because 'integrity warnings must warn-and-render, not abort (AC8)'
        $buckets.RankedUmbrellas | Should -Not -BeNullOrEmpty -Because 'RankedUmbrellas must still be populated when IntegrityWarnings fire'
    }

    It 'RecentlyClosed includes issues closed within the window' {
        $spec = ConvertFrom-SequenceSpec -yamlText (New-ValidSpecYaml -Umbrellas @(476, 571))
        $recentClosedAt = (Get-Date).AddDays(-3).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        $oldClosedAt    = (Get-Date).AddDays(-30).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        $recent = New-IssueState -Number 700 -State 'CLOSED' -ClosedAt $recentClosedAt
        $old    = New-IssueState -Number 701 -State 'CLOSED' -ClosedAt $oldClosedAt

        $buckets = Get-PortfolioBuckets -spec $spec -issueStateObjects @($recent, $old)

        $rcNums = @($buckets.RecentlyClosed | ForEach-Object { $_.number })
        $rcNums | Should -Contain 700 -Because '#700 closed within 14-day window must appear in RecentlyClosed'
        $rcNums | Should -Not -Contain 701 -Because '#701 closed 30 days ago is outside the window'
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
        #
        # Stub behavior (from BeforeEach):
        #   - `gh api graphql` → exit 1  (Step-0 probe fails; pipeline halts before scan)
        #   - `gh issue list`  → exit 1  (simulates scan failure; never reached due to probe halt)
        #   - `gh issue view`  → returns minimal JSON (control tower body fetch succeeds)
        #   - `gh issue edit`  → records call, returns 0 (would be the write step)
        #
        # With the Step-0 probe guard: pipeline exits before step 8 (write) → edit count = 0.

        $tempSpec = [System.IO.Path]::GetTempFileName() -replace '\.tmp$', '.yaml'
        @'
schema_version: 2
control_tower: 704
recently_closed_days: 14
umbrellas: [425, 571]
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

    It 'v2-full-pipeline: active umbrella expanded, triage by parent-edge, gh issue edit called once' {
        # Success-path v2 integration test.
        # Stubs all gh calls to return v2-model data; exercises the full
        # Invoke-PortfolioRender pipeline:
        #   Step-0 probe (#704) → success
        #   open-scan  → #900 (child of #425), #800 (triage candidate), #425, #571
        #   closed-scan → #801 recently-closed leaf (within window)
        #   GraphQL #425 → OPEN, parent: null, subIssues: [{#900, OPEN}]
        #   GraphQL #571 → OPEN, parent: null, subIssues: []
        #   GraphQL #900 (leaf) → parent: {number:425}, subIssues: {totalCount:0}
        #   GraphQL #800 (leaf) → parent: null, subIssues: {totalCount:0}  → Triage candidate
        #   view #704   → body with no portfolio block yet
        #   edit #704   → captured to $script:GhEditBody
        #
        # Expected board state after s3 fix:
        #   Triage:         #800 (open, parent=null, totalCount=0, not in umbrella list)
        #   RecentlyClosed: #801 (closed within window)
        #   gh issue edit called exactly once

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
                # open scan: #900 (child of 425), #800 (triage), #425 umbrella, #571 umbrella
                # No --label triage branch in v2
                $global:LASTEXITCODE = 0
                return '[{"number":900,"title":"Spine leaf 900","labels":[],"createdAt":"2026-01-02T00:00:00Z"},{"number":800,"title":"Triage candidate 800","labels":[],"createdAt":"2026-01-01T00:00:00Z"},{"number":425,"title":"Umbrella 425","labels":[],"createdAt":"2025-06-01T00:00:00Z"},{"number":571,"title":"Umbrella 571","labels":[],"createdAt":"2025-05-01T00:00:00Z"}]'
            }

            if ($ghArgs -contains 'api') {
                # Dispatch by issue number in the query string
                $queryStr = $ghArgs | Where-Object { $_ -like 'query=*' } | Select-Object -Last 1
                $issueNum = 0
                if ($queryStr -match 'issue\(number:\s*(\d+)') { $issueNum = [int]$Matches[1] }

                if ($issueNum -eq 704) {
                    # Step-0 probe: parent + subIssues fields available on control tower
                    $global:LASTEXITCODE = 0
                    return '{"data":{"repository":{"issue":{"parent":null,"subIssues":{"totalCount":0}}}}}'
                }
                if ($issueNum -eq 425) {
                    # Umbrella with one child (#900)
                    $global:LASTEXITCODE = 0
                    return '{"data":{"repository":{"issue":{"number":425,"title":"Umbrella 425","state":"OPEN","closedAt":null,"createdAt":"2025-06-01T00:00:00Z","labels":{"totalCount":0,"nodes":[]},"blockedBy":{"totalCount":0,"nodes":[]},"parent":null,"subIssues":{"totalCount":1,"nodes":[{"number":900,"state":"OPEN"}]}}}}}'
                }
                if ($issueNum -eq 571) {
                    # Umbrella with no children
                    $global:LASTEXITCODE = 0
                    return '{"data":{"repository":{"issue":{"number":571,"title":"Umbrella 571","state":"OPEN","closedAt":null,"createdAt":"2025-05-01T00:00:00Z","labels":{"totalCount":0,"nodes":[]},"blockedBy":{"totalCount":0,"nodes":[]},"parent":null,"subIssues":{"totalCount":0,"nodes":[]}}}}}'
                }
                if ($issueNum -eq 900) {
                    # Leaf child of #425: parent set, no sub-issues
                    $global:LASTEXITCODE = 0
                    return '{"data":{"repository":{"issue":{"number":900,"title":"Spine leaf 900","state":"OPEN","closedAt":null,"createdAt":"2026-01-02T00:00:00Z","labels":{"totalCount":0,"nodes":[]},"blockedBy":{"totalCount":0,"nodes":[]},"parent":{"number":425},"subIssues":{"totalCount":0}}}}}'
                }
                if ($issueNum -eq 800) {
                    # Triage candidate: parent null, no sub-issues
                    $global:LASTEXITCODE = 0
                    return '{"data":{"repository":{"issue":{"number":800,"title":"Triage candidate 800","state":"OPEN","closedAt":null,"createdAt":"2026-01-01T00:00:00Z","labels":{"totalCount":0,"nodes":[]},"blockedBy":{"totalCount":0,"nodes":[]},"parent":null,"subIssues":{"totalCount":0}}}}}'
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
schema_version: 2
control_tower: 704
recently_closed_days: 14
umbrellas: [425, 571]
'@ | Set-Content -Path $tempSpec2 -Encoding UTF8

        try {
            Invoke-PortfolioRender -specPath $tempSpec2

            $script:GhEditCallCount | Should -Be 1 `
                -Because 'pipeline should write the board exactly once when body changes'

            $script:GhEditBody | Should -Match '#800' `
                -Because '#800 is a triage candidate (parent=null, totalCount=0) and must appear in the Triage section'

            $script:GhEditBody | Should -Match '#801' `
                -Because 'repo-wide closed leaf #801 must appear in RecentlyClosed (AC9 wiring verified)'
        }
        finally {
            if (Test-Path $tempSpec2) { Remove-Item $tempSpec2 -Force -ErrorAction SilentlyContinue }
        }
    }

    It 'open-ceiling-throws: open scan at limit fires fail-loud guard before gh issue edit is reached' {
        # GREEN (after s2/s3): Step-0 probe succeeds (returns valid JSON for tower #704),
        # open scan stub sets ScanReached=$true at exactly the limit, ceiling guard fires
        # Write-Error -ErrorAction Stop, edit never reached, both assertions pass.

        $script:ScanReached    = $false
        $script:GhEditCallCount = 0

        function global:gh {
            param([Parameter(ValueFromRemainingArguments)][string[]]$ghArgs)

            if ($ghArgs -contains 'edit') {
                $script:GhEditCallCount++
                $global:LASTEXITCODE = 0
                return
            }

            if ($ghArgs -contains 'api') {
                # Step-0 probe for tower #704 — return success so probe passes
                $queryStr = $ghArgs | Where-Object { $_ -like 'query=*' } | Select-Object -Last 1
                $issueNum = 0
                if ($queryStr -match 'issue\(number:\s*(\d+)') { $issueNum = [int]$Matches[1] }
                if ($issueNum -eq 704) {
                    $global:LASTEXITCODE = 0
                    return '{"data":{"repository":{"issue":{"parent":null,"subIssues":{"totalCount":0}}}}}'
                }
                $global:LASTEXITCODE = 1
                return
            }

            if ($ghArgs -contains 'list') {
                if ($ghArgs -contains 'closed') {
                    # 1 item — below limit, closed guard won't fire
                    $global:LASTEXITCODE = 0
                    return '[{"number":10,"title":"c1","closedAt":"2026-01-01T00:00:00Z","labels":[]}]'
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
schema_version: 2
control_tower: 704
recently_closed_days: 14
umbrellas: [425, 571]
'@ | Set-Content -Path $tempSpecCeil1 -Encoding UTF8

        try {
            { Invoke-PortfolioRender -specPath $tempSpecCeil1 -issueScanLimit 3 } |
                Should -Throw -ExpectedMessage '*refusing to render*' `
                -Because 'ceiling guard must throw with the truncated-board message before gh issue edit is reached'

            $script:ScanReached | Should -BeTrue `
                -Because 'gh stub must have been called before the ceiling guard fired — if false, function failed before reaching the open scan'

            $script:GhEditCallCount | Should -Be 0 `
                -Because 'gh issue edit must never be reached when the open ceiling guard fires'
        }
        finally {
            if (Test-Path $tempSpecCeil1) { Remove-Item $tempSpecCeil1 -Force -ErrorAction SilentlyContinue }
        }
    }

    It 'closed-ceiling-throws: closed scan at limit fires fail-loud guard before gh issue edit is reached' {
        # GREEN (after s2/s3): Step-0 probe succeeds, open scan (2 items) passes,
        # closed scan stub sets ScanReached=$true at exactly the limit, closed ceiling
        # guard fires Write-Error -ErrorAction Stop, edit never reached.

        $script:ScanReached    = $false
        $script:GhEditCallCount = 0

        function global:gh {
            param([Parameter(ValueFromRemainingArguments)][string[]]$ghArgs)

            if ($ghArgs -contains 'edit') {
                $script:GhEditCallCount++
                $global:LASTEXITCODE = 0
                return
            }

            if ($ghArgs -contains 'api') {
                # Step-0 probe for tower #704 — return success so probe passes
                $queryStr = $ghArgs | Where-Object { $_ -like 'query=*' } | Select-Object -Last 1
                $issueNum = 0
                if ($queryStr -match 'issue\(number:\s*(\d+)') { $issueNum = [int]$Matches[1] }
                if ($issueNum -eq 704) {
                    $global:LASTEXITCODE = 0
                    return '{"data":{"repository":{"issue":{"parent":null,"subIssues":{"totalCount":0}}}}}'
                }
                $global:LASTEXITCODE = 1
                return
            }

            if ($ghArgs -contains 'list') {
                if ($ghArgs -contains 'closed') {
                    # 3 items — exactly at limit, closed ceiling guard fires; mark reached
                    $script:ScanReached = $true
                    $global:LASTEXITCODE = 0
                    return '[{"number":10,"title":"c1","closedAt":"2026-01-01T00:00:00Z","labels":[]},{"number":11,"title":"c2","closedAt":"2026-01-01T00:00:00Z","labels":[]},{"number":12,"title":"c3","closedAt":"2026-01-01T00:00:00Z","labels":[]}]'
                }
                # open scan fallthrough — 2 items, below limit, open guard won't fire
                $global:LASTEXITCODE = 0
                return '[{"number":1,"title":"t1","labels":[],"createdAt":"2026-01-01T00:00:00Z"},{"number":2,"title":"t2","labels":[],"createdAt":"2026-01-01T00:00:00Z"}]'
            }

            $global:LASTEXITCODE = 0
        }

        $tempSpecCeil2 = [System.IO.Path]::GetTempFileName() -replace '\.tmp$', '.yaml'
        @'
schema_version: 2
control_tower: 704
recently_closed_days: 14
umbrellas: [425, 571]
'@ | Set-Content -Path $tempSpecCeil2 -Encoding UTF8

        try {
            { Invoke-PortfolioRender -specPath $tempSpecCeil2 -issueScanLimit 3 } |
                Should -Throw -ExpectedMessage '*truncated RecentlyClosed*' `
                -Because 'ceiling guard must throw with the truncated-RecentlyClosed message before gh issue edit is reached'

            $script:ScanReached | Should -BeTrue `
                -Because 'gh stub must have been called before the ceiling guard fired — if false, function failed before reaching the closed scan'

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
            if ($ghArgs -contains 'api') {
                # Step-0 probe for tower #704 — return success so probe passes
                $queryStr = $ghArgs | Where-Object { $_ -like 'query=*' } | Select-Object -Last 1
                $issueNum = 0
                if ($queryStr -match 'issue\(number:\s*(\d+)') { $issueNum = [int]$Matches[1] }
                if ($issueNum -eq 704) {
                    $global:LASTEXITCODE = 0
                    return '{"data":{"repository":{"issue":{"parent":null,"subIssues":{"totalCount":0}}}}}'
                }
                $global:LASTEXITCODE = 1
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
                # open scan fallthrough — return 1 item, well below issueScanLimit 1500
                $global:LASTEXITCODE = 0
                return '[{"number":1,"title":"t1","labels":[],"createdAt":"2026-01-01T00:00:00Z"}]'
            }
            $global:LASTEXITCODE = 0
        }

        $tempSpecCeil4 = [System.IO.Path]::GetTempFileName() -replace '\.tmp$', '.yaml'
        @'
schema_version: 2
control_tower: 704
recently_closed_days: 14
umbrellas: [425, 571]
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

    It 'no-triage-label-query: Invoke-PortfolioRender never calls gh with --label triage in v2 model' {
        # v2 triage detection is derived from parent-edge data, not a label query.
        # Assert that no gh call in the full pipeline uses --label triage.

        $script:GhCallLog = [System.Collections.Generic.List[object]]::new()
        $closedAt801 = (Get-Date).AddDays(-5).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')

        function global:gh {
            param([Parameter(ValueFromRemainingArguments)][string[]]$ghArgs)
            $script:GhCallLog.Add([array]$ghArgs)

            if ($ghArgs -contains 'edit') {
                $global:LASTEXITCODE = 0
                return
            }

            if ($ghArgs -contains 'view') {
                $global:LASTEXITCODE = 0
                return '{"body":"# Control Tower\n\nNo portfolio block yet."}'
            }

            if ($ghArgs -contains 'api') {
                $queryStr = $ghArgs | Where-Object { $_ -like 'query=*' } | Select-Object -Last 1
                $issueNum = 0
                if ($queryStr -match 'issue\(number:\s*(\d+)') { $issueNum = [int]$Matches[1] }
                if ($issueNum -eq 704) {
                    $global:LASTEXITCODE = 0
                    return '{"data":{"repository":{"issue":{"parent":null,"subIssues":{"totalCount":0}}}}}'
                }
                if ($issueNum -eq 425) {
                    $global:LASTEXITCODE = 0
                    return '{"data":{"repository":{"issue":{"number":425,"title":"Umbrella 425","state":"OPEN","closedAt":null,"createdAt":"2025-06-01T00:00:00Z","labels":{"totalCount":0,"nodes":[]},"blockedBy":{"totalCount":0,"nodes":[]},"parent":null,"subIssues":{"totalCount":0,"nodes":[]}}}}}'
                }
                # Any other leaf query
                $global:LASTEXITCODE = 0
                return "{`"data`":{`"repository`":{`"issue`":{`"number`":$issueNum,`"title`":`"t$issueNum`",`"state`":`"OPEN`",`"closedAt`":null,`"createdAt`":`"2026-01-01T00:00:00Z`",`"labels`":{`"totalCount`":0,`"nodes`":[]},`"blockedBy`":{`"totalCount`":0,`"nodes`":[]},`"parent`":null,`"subIssues`":{`"totalCount`":0}}}}}"
            }

            if ($ghArgs -contains 'list') {
                if ($ghArgs -contains 'closed') {
                    $global:LASTEXITCODE = 0
                    return "[{`"number`":801,`"title`":`"Closed 801`",`"closedAt`":`"$closedAt801`",`"labels`":[]}]"
                }
                # open scan
                $global:LASTEXITCODE = 0
                return '[{"number":425,"title":"Umbrella 425","labels":[],"createdAt":"2025-06-01T00:00:00Z"}]'
            }

            $global:LASTEXITCODE = 0
        }

        $tempSpecNoTriage = [System.IO.Path]::GetTempFileName() -replace '\.tmp$', '.yaml'
        @'
schema_version: 2
control_tower: 704
recently_closed_days: 14
umbrellas: [425]
'@ | Set-Content -Path $tempSpecNoTriage -Encoding UTF8

        try {
            try { Invoke-PortfolioRender -specPath $tempSpecNoTriage } catch { }

            $labelTriageCalls = @($script:GhCallLog | Where-Object {
                $call = $_
                ($call -contains '--label' -and $call -contains 'triage') -or
                ($call -contains '-label' -and $call -contains 'triage')
            })
            $labelTriageCalls.Count | Should -Be 0 `
                -Because 'v2 model derives triage from parent-edge data; gh must never be called with --label triage'
        }
        finally {
            if (Test-Path $tempSpecNoTriage) { Remove-Item $tempSpecNoTriage -Force -ErrorAction SilentlyContinue }
        }
    }

    It 'step0-probe-fail-loud: Invoke-PortfolioRender exits before write when GraphQL parent field is unavailable' {
        # v2 triage/drift model requires parent + subIssues GraphQL fields.
        # If the Step-0 probe returns a GraphQL error for these fields, the pipeline must
        # halt with a loud error before gh issue edit is ever called.

        $script:GhEditCallCount = 0

        function global:gh {
            param([Parameter(ValueFromRemainingArguments)][string[]]$ghArgs)

            if ($ghArgs -contains 'edit') {
                $script:GhEditCallCount++
                $global:LASTEXITCODE = 0
                return
            }

            if ($ghArgs -contains 'api') {
                # GraphQL field error: parent field doesn't exist on Issue type
                $global:LASTEXITCODE = 0
                return '{"errors":[{"message":"Field parent doesn t exist on type Issue"}]}'
            }

            if ($ghArgs -contains 'list') {
                $global:LASTEXITCODE = 0
                return '[]'
            }

            $global:LASTEXITCODE = 0
        }

        $tempSpecProbe = [System.IO.Path]::GetTempFileName() -replace '\.tmp$', '.yaml'
        @'
schema_version: 2
control_tower: 704
recently_closed_days: 14
umbrellas: [425, 571]
'@ | Set-Content -Path $tempSpecProbe -Encoding UTF8

        try {
            try {
                Invoke-PortfolioRender -specPath $tempSpecProbe
            }
            catch {
                # Expected: probe fires Write-Error -ErrorAction Stop; swallow here.
            }

            $script:GhEditCallCount | Should -Be 0 `
                -Because 'Step-0 probe must halt before gh issue edit when GraphQL parent/subIssues fields are unavailable'
        }
        finally {
            if (Test-Path $tempSpecProbe) { Remove-Item $tempSpecProbe -Force -ErrorAction SilentlyContinue }
        }
    }
}
