#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
.SYNOPSIS
    Pester v5 suite for render-portfolio.ps1 (v2 schema; issue #692 s3, #720 s1, #753 s1-s4).

.DESCRIPTION
    Hoisted Renderer Contract tests covering:
      - ConvertFrom-SequenceSpec  : parse, schema validation, fail-open on bad input
      - Get-PortfolioBuckets      : v2 bucket placement (ActiveUmbrella, ActiveChildren,
                                    RankedUmbrellas, Triage, RecentlyClosed, DriftWarnings,
                                    IntegrityWarnings), createdAt ordering, priority-label sort
      - Format-PortfolioMarkdown  : v2 three-zone layout (Active / Umbrellas ranked / Triage /
                                    Recently closed), footer label, pagination overflow, warnings
      - Get-SplicedBody           : marker splice, idempotency, migration fixture (old→new label)
      - Order independence        : createdAt-desc ordering with priority-label tiebreak (AC3)
      - Invoke-PortfolioRender    : hard-exit guard — gh issue edit NOT called on scan failure (AC8)

    Purity constraints (d-ci-gate-registration, #692 s3 / #720 s1):
      - Fixtures only — no network calls
      - No ConvertFrom-Yaml (production ConvertFrom-SequenceSpec used exclusively)
      - Deterministic sort keys
      - No live gh CLI calls
      - No Sort-Object number in fixture ordering assertions (AC3: producer owns order)
#>

BeforeAll {
    $scriptPath = Join-Path $PSScriptRoot '..' 'render-portfolio.ps1'
    # This will fail until s4 creates the script — making tests RED.
    . $scriptPath

    # New-TempSpecPath: returns a unique temp-file path for a YAML spec without creating a
    # file on disk. Avoids the GetTempFileName() + -replace pattern which leaks the .tmp file.
    function global:New-TempSpecPath {
        return Join-Path ([System.IO.Path]::GetTempPath()) "$([System.Guid]::NewGuid().ToString()).yaml"
    }
}

# ---------------------------------------------------------------------------
# Helper: build a minimal valid flat-YAML sequence spec string
# v2 default: schema_version 2 with umbrellas inline list.
# Legacy path: when $LegacyRoundsBlock is provided, emit schema_version 1 +
# rounds block so the v1-rejection tests can exercise the invalid-schema path.
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
# Extended in #720 s1: added CreatedAt (for AC3 createdAt-desc ordering).
# Extended in #753 s1: added Parent and SubIssues for v2 bucket classification.
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

    It "includes footer with label 'portfolio content unchanged since ...'" {
        # AC: footer label is 'portfolio content unchanged since' (updated from 'as of' in #720 s1)
        $timestamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        $output = Format-PortfolioMarkdown -bucketModel $script:SimpleBuckets -timestamp $timestamp

        $output | Should -Match 'portfolio content unchanged since \d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z — rendered by render-portfolio\.ps1'
    }

    It 'v2-renders-Active/Umbrellas/Triage/RecentlyClosed sections in that order' {
        # v2 layout: Active → Umbrellas (ranked) → Triage → Recently closed
        $timestamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        $output = Format-PortfolioMarkdown -bucketModel $script:SimpleBuckets -timestamp $timestamp

        $activePos         = $output.IndexOf('Active')
        $umbrellasPos      = $output.IndexOf('Umbrellas')
        $triagePos         = $output.IndexOf('Triage')
        $recentlyClosedPos = $output.IndexOf('Recently closed')

        $activePos         | Should -BeGreaterThan -1            -Because 'Active section must be present (v2)'
        $umbrellasPos      | Should -BeGreaterThan $activePos    -Because 'Umbrellas (ranked) must come after Active (v2)'
        $triagePos         | Should -BeGreaterThan $umbrellasPos -Because 'Triage must come after Umbrellas (v2)'
        $recentlyClosedPos | Should -BeGreaterThan $triagePos    -Because 'Recently closed must come after Triage (v2)'
    }

    It 'v2-triage-residual-overflow: (+N more) appears in Triage when TriageResidualCount > 0 (F14)' {
        # v2: overflow in Triage section is controlled by TriageResidualCount from Get-PortfolioBuckets.
        # When TriageResidualCount=50 and 1 item is rendered, (+50 more) must appear.
        $overflowBucketModel = [PSCustomObject]@{
            ActiveUmbrella      = $null
            ActiveChildren      = @()
            RankedUmbrellas     = @()
            Triage              = @( [PSCustomObject]@{ number = 425; title = 'Issue 425' } )
            TriageResidualCount = 50
            DriftWarnings       = @()
            IntegrityWarnings   = @()
            RecentlyClosed      = @()
        }
        $timestamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')

        $output = Format-PortfolioMarkdown -bucketModel $overflowBucketModel -timestamp $timestamp

        $output | Should -Match '\(\+50 more\)' -Because 'TriageResidualCount=50 must appear as (+50 more) in Triage section (v2 pagination)'
    }

    It 'Triage ordering tiebreaker: lower-numbered issue precedes higher-numbered when priority and createdAt are equal (AC6/F18)' {
        # Two triage candidates with no createdAt and no priority labels — the number-asc
        # tiebreaker (last key in Sort-Object in Get-PortfolioBuckets) must put #800 before #801.
        # #425 and #571 are listed umbrellas (excluded from Triage by the umbrella-set filter).
        $spec = ConvertFrom-SequenceSpec -yamlText (New-ValidSpecYaml)
        $issues = @(
            (New-IssueState -Number 425  -State 'OPEN' -BlockedBy @())  # listed umbrella — excluded from Triage
            (New-IssueState -Number 571  -State 'OPEN' -BlockedBy @())  # listed umbrella — excluded from Triage
            (New-IssueState -Number 801  -State 'OPEN' -BlockedBy @())  # triage candidate (higher number)
            (New-IssueState -Number 800  -State 'OPEN' -BlockedBy @())  # triage candidate (lower number — must sort first)
        )
        $buckets = Get-PortfolioBuckets -spec $spec -issueStateObjects $issues
        $timestamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')

        $output = Format-PortfolioMarkdown -bucketModel $buckets -timestamp $timestamp

        $pos800 = $output.IndexOf('#800')
        $pos801 = $output.IndexOf('#801')
        $pos800 | Should -BeGreaterThan -1  -Because '#800 must appear in Triage output'
        $pos801 | Should -BeGreaterThan -1  -Because '#801 must appear in Triage output'
        $pos800 | Should -BeLessThan $pos801 -Because 'lower-numbered issue (#800) must precede higher-numbered issue (#801) as number-asc tiebreaker (AC6)'
    }

    It 'v2-umbrellas-spec-order-preserved: Umbrellas section preserves spec list order — no re-sort by number (AC5)' {
        # v2: Umbrellas (ranked) section must preserve spec list order verbatim.
        # Formatter must NOT re-sort by number.
        # Spec has umbrellas [571, 425] → 571 must appear before 425 in output.
        $spec = ConvertFrom-SequenceSpec -yamlText (New-ValidSpecYaml -Umbrellas @(571, 425))
        $umbrella571 = New-IssueState -Number 571 -State 'OPEN' -SubIssues @{ totalCount = 0; nodes = @() }
        $umbrella425 = New-IssueState -Number 425 -State 'OPEN' -SubIssues @{ totalCount = 0; nodes = @() }

        $buckets = Get-PortfolioBuckets -spec $spec -issueStateObjects @($umbrella571, $umbrella425)
        $output  = Format-PortfolioMarkdown -bucketModel $buckets -timestamp '2026-06-25T00:00:00Z'

        # Find positions in the Umbrellas section: 571 before 425
        $umbrellasSectionMatch = [regex]::Match($output, '(?s)## Umbrellas \(ranked\)(?<body>.*?)## 🔥 Triage')
        $umbrellasSectionMatch.Success | Should -Be $true -Because 'Umbrellas (ranked) section must appear before Triage'
        $body = $umbrellasSectionMatch.Groups['body'].Value
        $pos571 = $body.IndexOf('#571')
        $pos425 = $body.IndexOf('#425')
        $pos571 | Should -BeGreaterThan -1 -Because '#571 must appear in Umbrellas section'
        $pos425 | Should -BeGreaterThan -1 -Because '#425 must appear in Umbrellas section'
        $pos571 | Should -BeLessThan $pos425 -Because 'formatter must preserve spec order; #571 (listed first) must precede #425 (listed second) (AC5)'
    }

    It 'v2-active-children-blocked-annotation: blocked children show ⛔ annotation, non-blocked children do not (AC4)' {
        # v2: in the Active section, blocked children must have ⛔ annotation; non-blocked must not.
        $spec = ConvertFrom-SequenceSpec -yamlText (New-ValidSpecYaml -Umbrellas @(100))
        $blockedChild = New-IssueState -Number 800 -Title 'Blocked child' -State 'OPEN' -BlockedBy @(999) `
            -Parent @{ number = 100 } -SubIssues @{ totalCount = 0; nodes = @() }
        $normalChild  = New-IssueState -Number 425 -Title 'Normal child' -State 'OPEN' -BlockedBy @() `
            -Parent @{ number = 100 } -SubIssues @{ totalCount = 0; nodes = @() }
        $umbrella100  = New-IssueState -Number 100 -State 'OPEN' `
            -SubIssues @{
                totalCount = 2
                nodes = @( @{ number = 800; state = 'OPEN' }, @{ number = 425; state = 'OPEN' } )
            }

        $buckets = Get-PortfolioBuckets -spec $spec -issueStateObjects @($umbrella100, $blockedChild, $normalChild)
        $output  = Format-PortfolioMarkdown -bucketModel $buckets -timestamp '2026-06-25T00:00:00Z'

        $output | Should -Match '#800.*⛔' -Because 'blocked child must have ⛔ blocked annotation (AC4)'
        $output | Should -Not -Match '#425.*⛔' -Because 'non-blocked child must NOT have ⛔ annotation (AC4)'
    }

    It 'v2-active-children-priority-ordering: children sorted priority-then-recency, not by number (AC4)' {
        # v2: Active section children must be sorted by priority-label then createdAt desc.
        # This verifies the formatter preserves Get-PortfolioBuckets output order.
        $spec = ConvertFrom-SequenceSpec -yamlText (New-ValidSpecYaml -Umbrellas @(100))
        # #571 has lower number but no priority; #425 has priority:high → must appear first
        $child571 = New-IssueState -Number 571 -State 'OPEN' -CreatedAt '2025-01-01T00:00:00Z' -Labels @() `
            -Parent @{ number = 100 } -SubIssues @{ totalCount = 0; nodes = @() }
        $child425 = New-IssueState -Number 425 -State 'OPEN' -CreatedAt '2025-01-01T00:00:00Z' -Labels @('priority: high') `
            -Parent @{ number = 100 } -SubIssues @{ totalCount = 0; nodes = @() }
        $umbrella100 = New-IssueState -Number 100 -State 'OPEN' `
            -SubIssues @{
                totalCount = 2
                nodes = @( @{ number = 571; state = 'OPEN' }, @{ number = 425; state = 'OPEN' } )
            }

        $buckets = Get-PortfolioBuckets -spec $spec -issueStateObjects @($umbrella100, $child571, $child425)
        $output  = Format-PortfolioMarkdown -bucketModel $buckets -timestamp '2026-06-25T00:00:00Z'

        # #425 has priority:high → key=0 → appears before #571 (unlabeled, key=3) despite larger number
        $pos425 = $output.IndexOf('#425')
        $pos571 = $output.IndexOf('#571')
        $pos425 | Should -BeGreaterThan -1 -Because '#425 must appear in Active section'
        $pos571 | Should -BeGreaterThan -1 -Because '#571 must appear in Active section'
        $pos425 | Should -BeLessThan $pos571 `
            -Because '#425 (priority:high) must appear before #571 (unlabeled) in Active section — formatter must not re-sort by number (AC4)'
    }

    It 'v2-triage-cap-floor: Get-PortfolioBuckets caps Triage at 5; TriageResidualCount carries overflow (AC6)' {
        # v2: Triage is capped at 5 items by Get-PortfolioBuckets. The formatter renders all items
        # it receives in Triage (no formatter-level cap), and appends (+N more) from TriageResidualCount.
        $spec = ConvertFrom-SequenceSpec -yamlText (New-ValidSpecYaml)
        # 8 triage candidates (none are umbrellas [476,571]) → cap at 5, residual = 3
        $triageIssues = 1..8 | ForEach-Object {
            New-IssueState -Number (900 + $_) -State 'OPEN' -SubIssues @{ totalCount = 0; nodes = @() }
        }
        $buckets = Get-PortfolioBuckets -spec $spec -issueStateObjects $triageIssues
        $output  = Format-PortfolioMarkdown -bucketModel $buckets -timestamp '2026-06-25T00:00:00Z'

        # Residual = 3 → (+3 more) must appear
        $output | Should -Match '\(\+3 more\)' -Because 'TriageResidualCount=3 must appear as (+3 more) after capped triage list (AC6)'
        # Items beyond cap (#909) must not be rendered
        $output | Should -Not -Match '#909' -Because 'item #909 (beyond triage cap of 5) must not be rendered individually (AC6)'
    }

    It 'v2-no-active-umbrella: empty state shown when ActiveUmbrella is null' {
        # v2: when ActiveUmbrella is null (all closed or none in list), Active section
        # shows an empty-state label matching '*(no' pattern (e.g. '*(none)*' or '*(no active umbrella)*').
        $bucketModel = [PSCustomObject]@{
            ActiveUmbrella      = $null
            ActiveChildren      = @()
            RankedUmbrellas     = @()
            Triage              = @()
            TriageResidualCount = 0
            DriftWarnings       = @()
            IntegrityWarnings   = @()
            RecentlyClosed      = @()
        }
        $timestamp = '2026-06-25T00:00:00Z'

        $output = Format-PortfolioMarkdown -bucketModel $bucketModel -timestamp $timestamp

        # Active section shows an empty-state label
        $output | Should -Match '\*\(no' -Because 'null ActiveUmbrella must show a labeled empty state in Active section'
    }

    It 'repo-wide recently-closed section shows all closures in window (AC9)' {
        # AC9: RecentlyClosed shows repo-wide closures within recently_closed_days window.
        # Verifies the formatter renders the RecentlyClosed section from the v2 bucket model.
        $recentlyClosed = @(
            [PSCustomObject]@{ number = 700; title = 'Closed Issue 700' }
            [PSCustomObject]@{ number = 701; title = 'Closed Issue 701' }
        )
        $bucketModel = [PSCustomObject]@{
            ActiveUmbrella      = $null
            ActiveChildren      = @()
            RankedUmbrellas     = @()
            Triage              = @()
            TriageResidualCount = 0
            DriftWarnings       = @()
            IntegrityWarnings   = @()
            RecentlyClosed      = $recentlyClosed
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
        # Footer label updated in #720 s1: 'portfolio content unchanged since ...'
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

    It 'returns null when only timestamp differs — idempotent (footer label)' {
        # The idempotency strip rule recognizes 'portfolio content unchanged since {ts}'
        # and returns null when only the timestamp differs.
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

    It 'v2-triage-ordering: priority then recency then number in Triage section (AC6)' {
        # v2: #425, #800, #801, #802 are triage candidates (open, parent=null, totalCount=0, not in umbrella list).
        # #571 IS an umbrella (in default spec umbrellas:[476,571]) → excluded from triage.
        # Triage sort: priority-label key (asc) → Get-CreatedAtSortTicks (asc = newest first) → number asc.
        # #800 (key=0/priority:high, 2025-02-01) → first
        # #802 (key=3, 2025-06-01, newest among unlabeled) → second
        # #801 (key=3, 2025-02-01, number 801) → third
        # #425 (key=3, 2024-01-01, oldest) → fourth
        $spec = ConvertFrom-SequenceSpec -yamlText (New-ValidSpecYaml)

        $si0 = @{ totalCount = 0; nodes = @() }
        $issuesAscending = @(
            (New-IssueState -Number 425 -State 'OPEN' -BlockedBy @() -CreatedAt '2024-01-01T00:00:00Z' -SubIssues $si0)
            (New-IssueState -Number 571 -State 'OPEN' -BlockedBy @() -CreatedAt '2024-01-01T00:00:00Z' -SubIssues $si0)
            (New-IssueState -Number 800 -State 'OPEN' -BlockedBy @() -CreatedAt '2025-02-01T00:00:00Z' -Labels @('priority: high') -SubIssues $si0)
            (New-IssueState -Number 801 -State 'OPEN' -BlockedBy @() -CreatedAt '2025-02-01T00:00:00Z' -Labels @() -SubIssues $si0)
            (New-IssueState -Number 802 -State 'OPEN' -BlockedBy @() -CreatedAt '2025-06-01T00:00:00Z' -Labels @() -SubIssues $si0)
        )
        $issuesShuffled = @(
            (New-IssueState -Number 802 -State 'OPEN' -BlockedBy @() -CreatedAt '2025-06-01T00:00:00Z' -Labels @() -SubIssues $si0)
            (New-IssueState -Number 571 -State 'OPEN' -BlockedBy @() -CreatedAt '2024-01-01T00:00:00Z' -SubIssues $si0)
            (New-IssueState -Number 801 -State 'OPEN' -BlockedBy @() -CreatedAt '2025-02-01T00:00:00Z' -Labels @() -SubIssues $si0)
            (New-IssueState -Number 425 -State 'OPEN' -BlockedBy @() -CreatedAt '2024-01-01T00:00:00Z' -SubIssues $si0)
            (New-IssueState -Number 800 -State 'OPEN' -BlockedBy @() -CreatedAt '2025-02-01T00:00:00Z' -Labels @('priority: high') -SubIssues $si0)
        )

        $bucketsA = Get-PortfolioBuckets -spec $spec -issueStateObjects $issuesAscending
        $bucketsB = Get-PortfolioBuckets -spec $spec -issueStateObjects $issuesShuffled

        $fixedTimestamp = '2026-06-12T12:00:00Z'
        $outputA = Format-PortfolioMarkdown -bucketModel $bucketsA -timestamp $fixedTimestamp
        $outputB = Format-PortfolioMarkdown -bucketModel $bucketsB -timestamp $fixedTimestamp

        # Output must be byte-identical regardless of input order (deterministic sort)
        $outputA | Should -Be $outputB -Because 'v2 triage ordering must be deterministic regardless of input order (AC6)'

        # Verify ordering in the combined output:
        # #800 (priority:high) must come before #802 (createdAt-desc secondary)
        $pos800 = $outputA.IndexOf('#800')
        $pos801 = $outputA.IndexOf('#801')
        $pos802 = $outputA.IndexOf('#802')
        $pos425 = $outputA.IndexOf('#425')

        $pos800 | Should -BeLessThan $pos802 `
            -Because '#800 (priority:high) must appear before #802 (createdAt-desc secondary) — priority-label tiebreak (AC6)'
        $pos802 | Should -BeLessThan $pos801 `
            -Because '#802 (2025-06-01) must appear before #801 (2025-02-01) — createdAt desc within same priority group (AC6)'
        $pos801 | Should -BeLessThan $pos425 `
            -Because '#801 (2025-02-01) must appear before #425 (2024-01-01) — createdAt desc (AC6)'
    }
}

# ===========================================================================
Describe 'Format-PortfolioMarkdown v2' {
# ===========================================================================

    It 'v2-three-zone-layout: output contains Active, Umbrellas ranked, and Triage headers' {
        # Minimal v2 bucket model with an active umbrella, one ranked umbrella, one triage issue
        $buckets = [PSCustomObject]@{
            ActiveUmbrella      = [PSCustomObject]@{ number = 100; title = 'Test Umbrella' }
            ActiveChildren      = @()
            RankedUmbrellas     = @(
                [PSCustomObject]@{ Number = 100; Title = 'Test Umbrella'; State = 'OPEN'; Done = 0; Total = 0; DoneTotalLabel = '0/0 (no children linked)'; IsActive = $true }
            )
            Triage              = @(
                [PSCustomObject]@{ number = 200; title = 'Triage Issue' }
            )
            TriageResidualCount = 0
            DriftWarnings       = @()
            IntegrityWarnings   = @()
            RecentlyClosed      = @()
        }

        $output = Format-PortfolioMarkdown -bucketModel $buckets -timestamp '2026-01-01T00:00:00Z'

        $output | Should -Match '## 🎯 Active' -Because 'v2 Active section header must appear (AC3)'
        $output | Should -Match '## Umbrellas \(ranked\)' -Because 'v2 Umbrellas (ranked) section header must appear (AC5)'
        $output | Should -Match '## 🔥 Triage' -Because 'v2 Triage section header must appear (AC6)'
        $output | Should -Match '## Recently closed' -Because 'v2 Recently closed section must appear (AC9)'
    }

    It 'v2-active-section: active umbrella children listed with done/total footer' {
        $spec = ConvertFrom-SequenceSpec -yamlText (New-ValidSpecYaml -Umbrellas @(100))
        $child200 = New-IssueState -Number 200 -State 'OPEN' `
            -Parent @{ number = 100 } -SubIssues @{ totalCount = 0; nodes = @() }
        $child201 = New-IssueState -Number 201 -State 'CLOSED' `
            -Parent @{ number = 100 } -SubIssues @{ totalCount = 0; nodes = @() } -ClosedAt '2026-01-01T00:00:00Z'
        $umbrella100 = New-IssueState -Number 100 -State 'OPEN' `
            -SubIssues @{
                totalCount = 2
                nodes = @(
                    @{ number = 200; state = 'OPEN' },
                    @{ number = 201; state = 'CLOSED' }
                )
            }

        $buckets = Get-PortfolioBuckets -spec $spec -issueStateObjects @($umbrella100, $child200, $child201)
        $output  = Format-PortfolioMarkdown -bucketModel $buckets -timestamp '2026-01-01T00:00:00Z'

        $output | Should -Match '#200' -Because 'open active child #200 must appear in Active section'
        $output | Should -Match '1/2'  -Because 'done/total (1 closed of 2 children) must appear in active section footer'
    }

    It 'v2-active-blocked-child: blocked child shows ⛔ in active section' {
        $spec = ConvertFrom-SequenceSpec -yamlText (New-ValidSpecYaml -Umbrellas @(100))
        $child200 = New-IssueState -Number 200 -State 'OPEN' -BlockedBy @(999) `
            -Parent @{ number = 100 } -SubIssues @{ totalCount = 0; nodes = @() }
        $umbrella100 = New-IssueState -Number 100 -State 'OPEN' `
            -SubIssues @{
                totalCount = 1
                nodes = @( @{ number = 200; state = 'OPEN' } )
            }

        $buckets = Get-PortfolioBuckets -spec $spec -issueStateObjects @($umbrella100, $child200)
        $output  = Format-PortfolioMarkdown -bucketModel $buckets -timestamp '2026-01-01T00:00:00Z'

        $output | Should -Match '⛔' -Because 'blocked child must show ⛔ annotation in Active section (AC4)'
    }

    It 'v2-umbrellas-ranked-with-active-marker: active umbrella gets ◀ active marker' {
        $spec = ConvertFrom-SequenceSpec -yamlText (New-ValidSpecYaml -Umbrellas @(100, 200))
        $umbrella100 = New-IssueState -Number 100 -State 'OPEN' `
            -SubIssues @{ totalCount = 0; nodes = @() }
        $umbrella200 = New-IssueState -Number 200 -State 'OPEN' `
            -SubIssues @{ totalCount = 0; nodes = @() }

        $buckets = Get-PortfolioBuckets -spec $spec -issueStateObjects @($umbrella100, $umbrella200)
        $output  = Format-PortfolioMarkdown -bucketModel $buckets -timestamp '2026-01-01T00:00:00Z'

        $output | Should -Match '◀ active' -Because 'active umbrella must have ◀ active marker in Umbrellas section (AC5)'
        # spec order preserved: #100 before #200 in Umbrellas section
        $pos100 = $output.IndexOf('#100')
        $pos200 = $output.IndexOf('#200')
        $pos100 | Should -BeLessThan $pos200 -Because 'spec order must be preserved in Umbrellas (ranked) section (AC5)'
    }

    It 'v2-triage-residual-count: (+N more) appears when TriageResidualCount > 0' {
        $buckets = [PSCustomObject]@{
            ActiveUmbrella      = $null
            ActiveChildren      = @()
            RankedUmbrellas     = @()
            Triage              = @(
                [PSCustomObject]@{ number = 1; title = 'T1' }
            )
            TriageResidualCount = 3
            DriftWarnings       = @()
            IntegrityWarnings   = @()
            RecentlyClosed      = @()
        }

        $output = Format-PortfolioMarkdown -bucketModel $buckets -timestamp '2026-01-01T00:00:00Z'

        $output | Should -Match '\(\+3 more\)' -Because 'TriageResidualCount=3 must appear as (+3 more) after triage list (AC6)'
    }

    It 'v2-drift-integrity-warnings: ⚠️ DriftWarnings and IntegrityWarnings appear after zones' {
        $buckets = [PSCustomObject]@{
            ActiveUmbrella      = $null
            ActiveChildren      = @()
            RankedUmbrellas     = @()
            Triage              = @()
            TriageResidualCount = 0
            DriftWarnings       = @('⚠️ open umbrella #999 not in ranked list')
            IntegrityWarnings   = @('⚠️ umbrella #100: subIssues.totalCount=5 but only 3 nodes returned')
            RecentlyClosed      = @()
        }

        $output = Format-PortfolioMarkdown -bucketModel $buckets -timestamp '2026-01-01T00:00:00Z'

        $output | Should -Match 'open umbrella #999' -Because 'DriftWarnings must appear in output (AC7)'
        $output | Should -Match 'subIssues\.totalCount=5' -Because 'IntegrityWarnings must appear in output (AC8)'

        # Warnings must appear after zone content (before footer)
        $footerPos   = $output.IndexOf('portfolio content unchanged since')
        $driftPos    = $output.IndexOf('open umbrella #999')
        $driftPos | Should -BeLessThan $footerPos -Because 'warnings must appear before footer'
    }

    It 'v2-idempotency: Format-PortfolioMarkdown + Get-SplicedBody returns $null on second call with same data' {
        $MARKER_BEGIN = '<!-- portfolio-tracker:begin -->'
        $MARKER_END   = '<!-- portfolio-tracker:end -->'

        $buckets = [PSCustomObject]@{
            ActiveUmbrella      = $null
            ActiveChildren      = @()
            RankedUmbrellas     = @()
            Triage              = @( [PSCustomObject]@{ number = 99; title = 'T99' } )
            TriageResidualCount = 0
            DriftWarnings       = @()
            IntegrityWarnings   = @()
            RecentlyClosed      = @()
        }

        $fixedTimestamp = '2026-01-01T00:00:00Z'
        $inner1  = Format-PortfolioMarkdown -bucketModel $buckets -timestamp $fixedTimestamp
        $block1  = "$MARKER_BEGIN`n$inner1$MARKER_END"

        # Splice into empty body
        $body1 = Get-SplicedBody -existingBody '' -contentBlock $block1

        # Format again with different timestamp (same data)
        $inner2 = Format-PortfolioMarkdown -bucketModel $buckets -timestamp '2026-06-01T00:00:00Z'
        $block2 = "$MARKER_BEGIN`n$inner2$MARKER_END"

        # Splice into already-spliced body
        $result = Get-SplicedBody -existingBody $body1 -contentBlock $block2

        $result | Should -BeNullOrEmpty -Because 'identical content with only timestamp change must return null (idempotency — no write needed)'
    }

    It 'v2-outside-marker-prose-preserved: text before portfolio marker is kept in spliced body' {
        $MARKER_BEGIN = '<!-- portfolio-tracker:begin -->'
        $MARKER_END   = '<!-- portfolio-tracker:end -->'

        $existingBody = "Some prose before marker`n$MARKER_BEGIN`nold content`nportfolio content unchanged since 2026-01-01T00:00:00Z — rendered by render-portfolio.ps1`n$MARKER_END"

        $buckets = [PSCustomObject]@{
            ActiveUmbrella      = $null
            ActiveChildren      = @()
            RankedUmbrellas     = @()
            Triage              = @()
            TriageResidualCount = 0
            DriftWarnings       = @()
            IntegrityWarnings   = @()
            RecentlyClosed      = @()
        }
        $inner   = Format-PortfolioMarkdown -bucketModel $buckets -timestamp '2026-06-01T00:00:00Z'
        $block   = "$MARKER_BEGIN`n$inner$MARKER_END"
        $result  = Get-SplicedBody -existingBody $existingBody -contentBlock $block

        $result | Should -Match 'Some prose before marker' -Because 'text before portfolio marker must be preserved after splice'
    }
}

# ===========================================================================
Describe 'Invoke-PortfolioRender' {
# ===========================================================================
# Tests for Invoke-PortfolioRender (added in #720 s1 / #753 s1-s4).
# Covers: Step-0 probe, hard-exit guard, v2 full pipeline, ceiling guards.
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

        $tempSpec = New-TempSpecPath
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

        $tempSpec2 = New-TempSpecPath
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

        $tempSpecCeil1 = New-TempSpecPath
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

        $tempSpecCeil2 = New-TempSpecPath
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

        $tempSpecCeil4 = New-TempSpecPath
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

        $tempSpecNoTriage = New-TempSpecPath
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

        $tempSpecProbe = New-TempSpecPath
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

    # ===========================================================================
    # Connection overflow guards (issue #746)
    # RED until Step 2 production code adds Test-ConnectionOverflow and
    # the per-connection overflow checks in Invoke-PortfolioRender.
    # ===========================================================================
    Describe 'connection overflow guards' {

        # ------------------------------------------------------------------
        # Build the shared overflow JSON in BeforeAll so it is available
        # when BeforeEach runs.
        # All three connections (labels, blockedBy, subIssues) have
        # totalCount=51 but only 50 nodes — overflow on all three.
        # blockedBy nodes are all OPEN so without overflow the issue would be
        # "Blocked"; with overflow it must become unresolved (AC2).
        # ------------------------------------------------------------------
        BeforeAll {
            $labelNodes101    = (1..50 | ForEach-Object { '{"name":"label-' + $_ + '"}' }) -join ','
            $blockerNodes101  = (1..50 | ForEach-Object { '{"number":' + $_ + ',"title":"Blocker ' + $_ + '","state":"OPEN"}' }) -join ','
            $subIssueNodes101 = (1..50 | ForEach-Object { '{"number":' + (1000 + $_) + '}' }) -join ','
            $script:OverflowJsonShared = '{"data":{"repository":{"issue":{"number":101,"title":"Test truncation guard issue","state":"OPEN","closedAt":null,"createdAt":"2026-01-01T00:00:00Z","labels":{"totalCount":51,"nodes":[' + $labelNodes101 + ']},"blockedBy":{"totalCount":51,"nodes":[' + $blockerNodes101 + ']},"subIssues":{"totalCount":51,"nodes":[' + $subIssueNodes101 + ']}}}}}'
        }

        BeforeEach {
            $script:GhViewBody  = '{"body":"# Control Tower\n\nNo portfolio block yet."}'
            $script:GhEditCallCount = 0
            $script:GhEditArgs      = @()
            $script:GhEditBody      = ''

            $script:OverflowJson = $script:OverflowJsonShared

            function global:gh {
                param([Parameter(ValueFromRemainingArguments)][string[]]$ghArgs)

                if ($ghArgs -contains 'edit') {
                    $script:GhEditCallCount++
                    $bodyIdx = [Array]::IndexOf([string[]]$ghArgs, '--body')
                    if ($bodyIdx -ge 0 -and ($bodyIdx + 1) -lt $ghArgs.Count) {
                        $script:GhEditBody = $ghArgs[$bodyIdx + 1]
                        # Persist the written body so the view stub returns it on the next render.
                        # Encode as JSON so Invoke-PortfolioRender can parse it via ConvertFrom-Json.
                        $script:GhViewBody = @{ body = $script:GhEditBody } | ConvertTo-Json -Compress
                    }
                    $global:LASTEXITCODE = 0
                    return
                }

                if ($ghArgs -contains 'list') {
                    if ($ghArgs -contains 'closed') { $global:LASTEXITCODE = 0; return '[]' }
                    if ($ghArgs -contains 'triage') { $global:LASTEXITCODE = 0; return '[]' }
                    # open scan: umbrella #101 (has subIssues → is umbrella)
                    $global:LASTEXITCODE = 0
                    return '[{"number":101,"title":"Test truncation guard issue","labels":["subIssues"],"createdAt":"2026-01-01T00:00:00Z"}]'
                }

                if ($ghArgs -contains 'api') {
                    $global:LASTEXITCODE = 0
                    return $script:OverflowJson
                }

                if ($ghArgs -contains 'view') {
                    $global:LASTEXITCODE = 0
                    return $script:GhViewBody
                }

                $global:LASTEXITCODE = 0
            }
        }

        AfterEach {
            Remove-Item function:global:gh -ErrorAction SilentlyContinue
            $script:GhEditCallCount = 0
            $script:GhEditArgs      = @()
            $script:GhEditBody      = ''
            $script:GhViewBody      = $null
            $script:OverflowJson    = $null
        }

        It 'labels overflow emits Write-Warning mentioning labels and issue number (AC5)' {
            # RED until Step 2 adds overflow check that calls Write-Warning when
            # labels.totalCount > labels.nodes.Count.
            $tempSpecOvf = New-TempSpecPath
            @'
schema_version: 2
control_tower: 704
recently_closed_days: 14
umbrellas: [101]
'@ | Set-Content -Path $tempSpecOvf -Encoding UTF8

            try {
                $captured = Invoke-PortfolioRender -specPath $tempSpecOvf 3>&1

                $warnings = @($captured | Where-Object { $_ -is [System.Management.Automation.WarningRecord] })
                # Match-over-collection: NOT positional — any warning matching both criteria suffices.
                $matchingWarnings = @($warnings | Where-Object { $_.Message -match 'labels' -and $_.Message -match '101' })
                $matchingWarnings.Count | Should -BeGreaterThan 0 `
                    -Because 'a Write-Warning mentioning "labels" and issue #101 must fire when labels overflow is detected (AC5)'
            }
            finally {
                if (Test-Path $tempSpecOvf) { Remove-Item $tempSpecOvf -Force -ErrorAction SilentlyContinue }
            }
        }

        It 'blockedBy overflow routes issue to unresolved section even when all visible blockers are closed (AC2)' {
            # RED until Step 2 adds overflow check.
            # Setup: all 50 visible blockers are CLOSED (so without overflow detection the issue
            # would appear startable in Now/Next because no open blockers are visible).
            # But totalCount=51 > 50 nodes → one blocker is hidden. The hidden blocker might be
            # OPEN, so the issue MUST be routed to unresolved/overflow rather than startable.
            # Without the Step 2 overflow check, the issue goes to Now/Next (startable) → RED.
            # With the Step 2 check, the issue is routed to unresolved/overflow → GREEN.

            $closedBlockerNodes = (1..50 | ForEach-Object { '{"number":' + $_ + ',"title":"Blocker ' + $_ + '","state":"CLOSED"}' }) -join ','
            # Overflow ONLY on blockedBy (labels=0, subIssues=0) so this test binds the blockedBy
            # routing guard exclusively — a disabled blockedBy guard must leave the body without
            # any 'overflow' marker (otherwise a subIssues overflow would confound the assertion).
            $closedBlockerOverflowJson = '{"data":{"repository":{"issue":{"number":101,"title":"Test truncated-blocker issue","state":"OPEN","closedAt":null,"createdAt":"2026-01-01T00:00:00Z","labels":{"totalCount":0,"nodes":[]},"blockedBy":{"totalCount":51,"nodes":[' + $closedBlockerNodes + ']},"parent":null,"subIssues":{"totalCount":0,"nodes":[]}}}}}'

            function global:gh {
                param([Parameter(ValueFromRemainingArguments)][string[]]$ghArgs)
                if ($ghArgs -contains 'edit') {
                    $script:GhEditCallCount++
                    $bodyIdx = [Array]::IndexOf([string[]]$ghArgs, '--body')
                    if ($bodyIdx -ge 0 -and ($bodyIdx + 1) -lt $ghArgs.Count) {
                        $script:GhEditBody = $ghArgs[$bodyIdx + 1]
                    }
                    $global:LASTEXITCODE = 0; return
                }
                if ($ghArgs -contains 'list') {
                    if ($ghArgs -contains 'closed') { $global:LASTEXITCODE = 0; return '[]' }
                    if ($ghArgs -contains 'triage') { $global:LASTEXITCODE = 0; return '[]' }
                    $global:LASTEXITCODE = 0
                    return '[{"number":101,"title":"Test truncated-blocker issue","labels":[],"createdAt":"2026-01-01T00:00:00Z"}]'
                }
                if ($ghArgs -contains 'api') { $global:LASTEXITCODE = 0; return $closedBlockerOverflowJson }
                if ($ghArgs -contains 'view') { $global:LASTEXITCODE = 0; return '{"body":"# Control Tower\n\nNo portfolio block yet."}' }
                $global:LASTEXITCODE = 0
            }

            $tempSpecOvf = New-TempSpecPath
            @'
schema_version: 2
control_tower: 704
recently_closed_days: 14
umbrellas: [101]
'@ | Set-Content -Path $tempSpecOvf -Encoding UTF8

            try {
                Invoke-PortfolioRender -specPath $tempSpecOvf

                $script:GhEditBody | Should -Match '101' `
                    -Because 'issue #101 must appear in the rendered board'
                # With Step 2 overflow detection: issue routes to unresolved/overflow.
                # Without overflow detection (current): all visible blockers are CLOSED so
                # openBlockers=[] → issue goes to Now/Next (startable) — body won't match
                # 'overflow' pattern → test FAILS RED as required.
                # Match the specific footer text (not bare 'overflow') so a clean issue title
                # cannot satisfy the assertion — this binds the blockedBy routing guard exactly.
                $script:GhEditBody | Should -Match 'blockedBy overflow' `
                    -Because 'blockedBy overflow must route #101 to the overflow section: visible blockers are all closed but totalCount=51 means a hidden blocker exists (AC2)'
                $script:GhEditBody | Should -Not -Match 'not found in GitHub' `
                    -Because 'a blockedBy-overflow issue exists in GitHub and must not render the false "not found — remove from sequence.yaml" footer line (P-M1 regression guard)'

                # AC3 assertion: #101 must be specifically annotated in the v2 overflow footer.
                # The v2 board uses ⚠️ Issue #N: blockedBy overflow — excluded from startable routing
                # (not Now/Next/Blocked sections, which are retired v1 headings).
                $script:GhEditBody | Should -Match '⚠️ Issue #101.*blockedBy overflow' `
                    -Because 'issue #101 must appear in the overflow footer annotation — excluded from startable routing (AC3)'
                # AC3 negative: #101 must not appear as a Triage (startable) item.
                $triageSection = [regex]::Match($script:GhEditBody, '(?s)##[^\r\n]*Triage[\r\n]+(?<triage>.*?)##').Groups['triage'].Value
                $triageSection | Should -Not -Match '(?m)#101\b' `
                    -Because 'blockedBy overflow must exclude #101 from the Triage (startable) section (AC3)'
            }
            finally {
                if (Test-Path $tempSpecOvf) { Remove-Item $tempSpecOvf -Force -ErrorAction SilentlyContinue }
            }
        }

        It 'subIssues overflow emits Write-Warning mentioning subIssues and issue number (AC5)' {
            # RED until Step 2 adds overflow check for subIssues.totalCount > subIssues.nodes.Count.
            $tempSpecOvf = New-TempSpecPath
            @'
schema_version: 2
control_tower: 704
recently_closed_days: 14
umbrellas: [101]
'@ | Set-Content -Path $tempSpecOvf -Encoding UTF8

            try {
                $captured = Invoke-PortfolioRender -specPath $tempSpecOvf 3>&1

                $warnings = @($captured | Where-Object { $_ -is [System.Management.Automation.WarningRecord] })
                # Match-over-collection: any warning matching both criteria suffices.
                $matchingWarnings = @($warnings | Where-Object { $_.Message -match 'subIssues' -and $_.Message -match '101' })
                $matchingWarnings.Count | Should -BeGreaterThan 0 `
                    -Because 'a Write-Warning mentioning "subIssues" and issue #101 must fire when subIssues overflow is detected (AC5)'
            }
            finally {
                if (Test-Path $tempSpecOvf) { Remove-Item $tempSpecOvf -Force -ErrorAction SilentlyContinue }
            }
        }

        It 'render still completes with gh issue edit called AND overflow warning emitted (AC6 warn-and-continue)' {
            # RED until Step 2: overflow guards must fire a Write-Warning AND still let render complete.
            # This test requires BOTH conditions simultaneously:
            #   1. at least one overflow warning was emitted (RED without Step 2 — no overflow code yet)
            #   2. render completes (gh issue edit called >= 1)
            # Condition 1 is the RED driver — current code emits no overflow warnings.
            $tempSpecOvf = New-TempSpecPath
            @'
schema_version: 2
control_tower: 704
recently_closed_days: 14
umbrellas: [101]
'@ | Set-Content -Path $tempSpecOvf -Encoding UTF8

            try {
                $captured = Invoke-PortfolioRender -specPath $tempSpecOvf 3>&1

                # Condition 1 (RED driver): at least one overflow warning must have been emitted.
                $overflowWarnings = @($captured | Where-Object {
                    $_ -is [System.Management.Automation.WarningRecord] -and
                    ($_.Message -match 'overflow' -or $_.Message -match 'totalCount' -or $_.Message -match 'labels' -or $_.Message -match 'blockedBy' -or $_.Message -match 'subIssues')
                })
                $overflowWarnings.Count | Should -BeGreaterThan 0 `
                    -Because 'at least one overflow warning must be emitted before we can verify warn-and-continue (AC6 RED driver)'

                # Condition 2 (non-regression): render must complete despite the warning.
                $script:GhEditCallCount | Should -BeGreaterThan 0 `
                    -Because 'render must complete and call gh issue edit at least once even when overflow is detected (AC6 warn-and-continue)'
            }
            finally {
                if (Test-Path $tempSpecOvf) { Remove-Item $tempSpecOvf -Force -ErrorAction SilentlyContinue }
            }
        }

        It 'idempotency: two renders of overflow issue produce identical body containing overflow marker (AC7)' {
            # Two parts:
            #   1. The rendered body must contain an overflow marker (Part 1 RED driver — no
            #      overflow code yet, so the body won't have 'overflow' in it → fails RED)
            #   2. Second render must be a no-op: Get-SplicedBody detects the portfolio block is
            #      already present (identical) and returns $null, skipping gh issue edit (AC7 true idempotency)
            $tempSpecOvf = New-TempSpecPath
            @'
schema_version: 2
control_tower: 704
recently_closed_days: 14
umbrellas: [101]
'@ | Set-Content -Path $tempSpecOvf -Encoding UTF8

            try {
                Invoke-PortfolioRender -specPath $tempSpecOvf
                $firstBody = $script:GhEditBody

                # Part 1 (RED driver): body must contain overflow marker.
                # Without Step 2, no overflow indicator appears → fails RED.
                $firstBody | Should -Match 'overflow' `
                    -Because 'overflow must be reflected in the rendered board body for idempotency to be meaningful (AC7 RED driver)'

                # Reset call tracking for second render
                $script:GhEditCallCount = 0
                $script:GhEditBody      = ''

                Invoke-PortfolioRender -specPath $tempSpecOvf

                # Part 2 (true idempotency): second render must be a no-op — Get-SplicedBody detects
                # the portfolio block is already present and returns $null, skipping gh issue edit.
                $script:GhEditCallCount | Should -Be 0 `
                    -Because 'second render of an already-written board must be a no-op (AC7 no-op detection — Get-SplicedBody returns $null when content is identical)'
                $script:GhViewBody | Should -Match 'overflow' `
                    -Because 'persisted board body must still contain the overflow marker after the idempotent second render'
            }
            finally {
                if (Test-Path $tempSpecOvf) { Remove-Item $tempSpecOvf -Force -ErrorAction SilentlyContinue }
            }
        }

        It 'GITHUB_ACTIONS annotation emits ::warning:: to information stream when env var set (M6/AC3)' {
            # RED until Step 2 adds GITHUB_ACTIONS annotation emission via Write-Host
            # (information stream 6, NOT warning stream 3) when overflow is detected in CI.
            $previousGithubActions = $env:GITHUB_ACTIONS
            $tempSpecOvf = New-TempSpecPath
            @'
schema_version: 2
control_tower: 704
recently_closed_days: 14
umbrellas: [101]
'@ | Set-Content -Path $tempSpecOvf -Encoding UTF8

            try {
                $env:GITHUB_ACTIONS = 'true'
                # Capture information stream (6) — Write-Host output goes here.
                $output = Invoke-PortfolioRender -specPath $tempSpecOvf 6>&1
                $annotations = @($output | Where-Object { $_ -match '::warning::' })
                $annotations.Count | Should -BeGreaterThan 0 `
                    -Because 'at least one ::warning:: annotation must be emitted to the information stream when GITHUB_ACTIONS is set and overflow is detected (M6/AC3)'
            }
            finally {
                if ($null -eq $previousGithubActions) {
                    Remove-Item env:GITHUB_ACTIONS -ErrorAction SilentlyContinue
                } else {
                    $env:GITHUB_ACTIONS = $previousGithubActions
                }
                if (Test-Path $tempSpecOvf) { Remove-Item $tempSpecOvf -Force -ErrorAction SilentlyContinue }
            }
        }

        It 'warning message does not inject workflow commands from issue title (M9 log-injection guard)' {
            # RED until Step 2 ensures warning messages interpolate only safe integer issue#
            # and literal connection name — never the issue title or label names.
            # A malicious issue title containing "::error::" must not appear in any warning
            # or annotation, preventing CI log injection.

            $previousGithubActions = $env:GITHUB_ACTIONS
            $injectLabelNodes   = (1..50 | ForEach-Object { '{"name":"lbl-' + $_ + '"}' }) -join ','
            $injectSubIssueNodes = (1..50 | ForEach-Object { '{"number":' + (1000 + $_) + '}' }) -join ','
            $script:InjectJson = '{"data":{"repository":{"issue":{"number":102,"title":"::error:: injected","state":"OPEN","closedAt":null,"createdAt":"2026-01-01T00:00:00Z","labels":{"totalCount":51,"nodes":[' + $injectLabelNodes + ']},"blockedBy":{"totalCount":0,"nodes":[]},"subIssues":{"totalCount":51,"nodes":[' + $injectSubIssueNodes + ']}}}}}'

            function global:gh {
                param([Parameter(ValueFromRemainingArguments)][string[]]$ghArgs)
                if ($ghArgs -contains 'edit') { $script:GhEditCallCount++; $global:LASTEXITCODE = 0; return }
                if ($ghArgs -contains 'list') {
                    if ($ghArgs -contains 'closed') { $global:LASTEXITCODE = 0; return '[]' }
                    if ($ghArgs -contains 'triage') { $global:LASTEXITCODE = 0; return '[]' }
                    $global:LASTEXITCODE = 0
                    return '[{"number":102,"title":"::error:: injected","labels":["subIssues"],"createdAt":"2026-01-01T00:00:00Z"}]'
                }
                if ($ghArgs -contains 'api') { $global:LASTEXITCODE = 0; return $script:InjectJson }
                if ($ghArgs -contains 'view') { $global:LASTEXITCODE = 0; return '{"body":"# Control Tower\n\nNo portfolio block yet."}' }
                $global:LASTEXITCODE = 0
            }

            $tempSpecInject = New-TempSpecPath
            @'
schema_version: 2
control_tower: 704
recently_closed_days: 14
umbrellas: [102]
'@ | Set-Content -Path $tempSpecInject -Encoding UTF8

            try {
                $env:GITHUB_ACTIONS = 'true'
                # Capture warning stream (3) to check for title injection
                $captured3 = Invoke-PortfolioRender -specPath $tempSpecInject 3>&1
                $warnings = @($captured3 | Where-Object { $_ -is [System.Management.Automation.WarningRecord] })

                # RED driver: overflow must have produced at least one warning — otherwise the
                # injection-absence check is vacuously satisfied. Without Step 2, no overflow
                # warnings are emitted, so this assertion fails → test is RED.
                $overflowWarnings = @($warnings | Where-Object {
                    $_.Message -match 'overflow' -or $_.Message -match 'totalCount' -or
                    $_.Message -match 'labels' -or $_.Message -match 'subIssues'
                })
                $overflowWarnings.Count | Should -BeGreaterThan 0 `
                    -Because 'overflow must produce at least one warning before injection-absence can be verified (M9 RED driver)'

                # Warning messages must NOT contain ::error:: (injected from title)
                $injectedWarnings = @($warnings | Where-Object { $_.Message -match '::error::' })
                $injectedWarnings.Count | Should -Be 0 `
                    -Because 'overflow warning messages must not embed the issue title — no ::error:: from title injection (M9)'

                # Capture information stream (6) to check annotation for newline injection
                $captured6 = Invoke-PortfolioRender -specPath $tempSpecInject 6>&1
                $annotations = @($captured6 | Where-Object { $_ -match '::warning::' })

                $annotations.Count | Should -BeGreaterThan 0 `
                    -Because 'GITHUB_ACTIONS overflow handling must emit at least one ::warning:: annotation before injection safety can be verified (M9 count guard)'

                # ::warning:: annotations must not contain a newline (would inject a second command)
                foreach ($ann in $annotations) {
                    $ann.ToString() | Should -Not -Match "`n" `
                        -Because '::warning:: annotation must not contain a newline (prevents multi-command log injection, M9)'
                }
            }
            finally {
                if ($null -eq $previousGithubActions) {
                    Remove-Item env:GITHUB_ACTIONS -ErrorAction SilentlyContinue
                } else {
                    $env:GITHUB_ACTIONS = $previousGithubActions
                }
                if (Test-Path $tempSpecInject) { Remove-Item $tempSpecInject -Force -ErrorAction SilentlyContinue }
                $script:InjectJson = $null
            }
        }

        It 'leaf-loop (float/non-umbrella) blockedBy overflow routes issue to overflow section, not startable (AC2 leaf path)' {
            # Guards leaf-loop guard at render-portfolio.ps1:1058-1065 (the blockedBy overflow
            # check inside foreach ($num in $openLeafCandidateNums)).
            # Fixture: spec has umbrella #101; gh issue list open returns #101 AND #102.
            # #102 is a non-umbrella float (no subIssues label, not in spec rounds).
            # #102's blockedBy has totalCount=51 with 50 CLOSED nodes — without the leaf
            # guard, #102's openBlockers=[] → classified startable (Now/Next). With the guard,
            # it routes to the overflow section.
            $closedLeafBlockers = (1..50 | ForEach-Object { '{"number":' + $_ + ',"title":"Blocker ' + $_ + '","state":"CLOSED"}' }) -join ','
            # v2 leaf query selects subIssues(first:1){totalCount} (no nodes) — totalCount:0 keeps #102 a pure leaf.
            $leafOverflowJson = '{"data":{"repository":{"issue":{"number":102,"title":"Leaf truncated-blocker issue","state":"OPEN","closedAt":null,"createdAt":"2026-01-01T00:00:00Z","labels":{"totalCount":0,"nodes":[]},"blockedBy":{"totalCount":51,"nodes":[' + $closedLeafBlockers + ']},"parent":null,"subIssues":{"totalCount":0}}}}}'
            # Childless umbrella #101 (no overflow) so only #102 exercises the leaf guard.
            $umbrellaMinimalJson = '{"data":{"repository":{"issue":{"number":101,"title":"Umbrella issue","state":"OPEN","closedAt":null,"createdAt":"2026-01-01T00:00:00Z","labels":{"totalCount":0,"nodes":[]},"blockedBy":{"totalCount":0,"nodes":[]},"parent":null,"subIssues":{"totalCount":0,"nodes":[]}}}}}'
            $probeJson = '{"data":{"repository":{"issue":{"parent":null,"subIssues":{"totalCount":0}}}}}'

            function global:gh {
                param([Parameter(ValueFromRemainingArguments)][string[]]$ghArgs)
                if ($ghArgs -contains 'edit') {
                    $script:GhEditCallCount++
                    $bodyIdx = [Array]::IndexOf([string[]]$ghArgs, '--body')
                    if ($bodyIdx -ge 0 -and ($bodyIdx + 1) -lt $ghArgs.Count) {
                        $script:GhEditBody = $ghArgs[$bodyIdx + 1]
                    }
                    $global:LASTEXITCODE = 0; return
                }
                if ($ghArgs -contains 'list') {
                    if ($ghArgs -contains 'closed') { $global:LASTEXITCODE = 0; return '[]' }
                    if ($ghArgs -contains 'triage') { $global:LASTEXITCODE = 0; return '[]' }
                    # open scan: umbrella #101 + leaf float #102
                    $global:LASTEXITCODE = 0
                    return '[{"number":101,"title":"Umbrella issue","labels":[],"createdAt":"2026-01-01T00:00:00Z"},{"number":102,"title":"Leaf truncated-blocker issue","labels":[],"createdAt":"2026-01-01T00:00:00Z"}]'
                }
                if ($ghArgs -contains 'api') {
                    # v2 dispatch-by-number: Step-0 probe queries the control tower (#704),
                    # then the umbrella loop queries #101, then the leaf loop queries #102.
                    $queryStr = $ghArgs | Where-Object { $_ -like 'query=*' } | Select-Object -Last 1
                    $issueNum = 0
                    if ($queryStr -match 'issue\(number:\s*(\d+)') { $issueNum = [int]$Matches[1] }
                    $global:LASTEXITCODE = 0
                    if ($issueNum -eq 704) { return $probeJson }
                    if ($issueNum -eq 101) { return $umbrellaMinimalJson }
                    return $leafOverflowJson
                }
                if ($ghArgs -contains 'view') {
                    $global:LASTEXITCODE = 0
                    return '{"body":"# Control Tower\n\nNo portfolio block yet."}'
                }
                $global:LASTEXITCODE = 0
            }

            $tempSpecLeaf = New-TempSpecPath
            @'
schema_version: 2
control_tower: 704
recently_closed_days: 14
umbrellas: [101]
'@ | Set-Content -Path $tempSpecLeaf -Encoding UTF8

            try {
                $captured = Invoke-PortfolioRender -specPath $tempSpecLeaf 3>&1

                # Leaf blockedBy overflow must emit a Write-Warning
                $warnings = @($captured | Where-Object { $_ -is [System.Management.Automation.WarningRecord] })
                $leafWarnings = @($warnings | Where-Object { $_.Message -match 'blockedBy' -and $_.Message -match '102' })
                $leafWarnings.Count | Should -BeGreaterThan 0 `
                    -Because 'leaf-loop blockedBy overflow must emit a Write-Warning naming issue #102 and connection blockedBy (AC5 leaf path)'

                # Leaf blockedBy overflow must route #102 to the overflow section, not Now/Next.
                # Match the specific footer text so a clean issue title cannot satisfy it.
                $script:GhEditBody | Should -Match 'blockedBy overflow' `
                    -Because 'leaf-loop blockedBy overflow must render #102 in the overflow section (AC2 leaf path)'
                $script:GhEditBody | Should -Not -Match 'not found in GitHub' `
                    -Because 'a leaf blockedBy-overflow issue must not render the false "not found" footer line (P-M1 regression guard, leaf path)'

                # AC3 assertion: #102 must be specifically annotated in the v2 overflow footer.
                # The v2 board uses ⚠️ Issue #N: blockedBy overflow — excluded from startable routing
                # (not Now/Next/Blocked sections, which are retired v1 headings).
                $script:GhEditBody | Should -Match '⚠️ Issue #102.*blockedBy overflow' `
                    -Because 'issue #102 must appear in the overflow footer annotation — excluded from startable routing (AC3 leaf path)'
                # AC3 negative: #102 must not appear as a Triage (startable) item.
                $triageSection = [regex]::Match($script:GhEditBody, '(?s)##[^\r\n]*Triage[\r\n]+(?<triage>.*?)##').Groups['triage'].Value
                $triageSection | Should -Not -Match '(?m)#102\b' `
                    -Because 'blockedBy overflow must exclude #102 from the Triage (startable) section (AC3 leaf path)'
            }
            finally {
                Remove-Item function:global:gh -ErrorAction SilentlyContinue
                if (Test-Path $tempSpecLeaf) { Remove-Item $tempSpecLeaf -Force -ErrorAction SilentlyContinue }
            }
        }

        It 'leaf-loop labels overflow emits Write-Warning mentioning labels and issue number (AC5 leaf path)' {
            # Guards leaf-loop labels guard at render-portfolio.ps1:1051-1056.
            $leafLabelsNodes  = (1..50 | ForEach-Object { '{"name":"lbl-' + $_ + '"}' }) -join ','
            # v2 leaf query selects subIssues(first:1){totalCount} (no nodes).
            $leafLabelsJson   = '{"data":{"repository":{"issue":{"number":102,"title":"Leaf labels overflow","state":"OPEN","closedAt":null,"createdAt":"2026-01-01T00:00:00Z","labels":{"totalCount":51,"nodes":[' + $leafLabelsNodes + ']},"blockedBy":{"totalCount":0,"nodes":[]},"parent":null,"subIssues":{"totalCount":0}}}}}'
            $umbrellaMinimalJson2 = '{"data":{"repository":{"issue":{"number":101,"title":"Umbrella issue","state":"OPEN","closedAt":null,"createdAt":"2026-01-01T00:00:00Z","labels":{"totalCount":0,"nodes":[]},"blockedBy":{"totalCount":0,"nodes":[]},"parent":null,"subIssues":{"totalCount":0,"nodes":[]}}}}}'
            $probeJson2 = '{"data":{"repository":{"issue":{"parent":null,"subIssues":{"totalCount":0}}}}}'

            function global:gh {
                param([Parameter(ValueFromRemainingArguments)][string[]]$ghArgs)
                if ($ghArgs -contains 'edit') {
                    $script:GhEditCallCount++
                    $bodyIdx = [Array]::IndexOf([string[]]$ghArgs, '--body')
                    if ($bodyIdx -ge 0 -and ($bodyIdx + 1) -lt $ghArgs.Count) {
                        $script:GhEditBody = $ghArgs[$bodyIdx + 1]
                    }
                    $global:LASTEXITCODE = 0; return
                }
                if ($ghArgs -contains 'list') {
                    if ($ghArgs -contains 'closed') { $global:LASTEXITCODE = 0; return '[]' }
                    if ($ghArgs -contains 'triage') { $global:LASTEXITCODE = 0; return '[]' }
                    $global:LASTEXITCODE = 0
                    return '[{"number":101,"title":"Umbrella issue","labels":[],"createdAt":"2026-01-01T00:00:00Z"},{"number":102,"title":"Leaf labels overflow","labels":[],"createdAt":"2026-01-01T00:00:00Z"}]'
                }
                if ($ghArgs -contains 'api') {
                    # v2 dispatch-by-number: #704 probe, #101 umbrella, #102 leaf.
                    $queryStr = $ghArgs | Where-Object { $_ -like 'query=*' } | Select-Object -Last 1
                    $issueNum = 0
                    if ($queryStr -match 'issue\(number:\s*(\d+)') { $issueNum = [int]$Matches[1] }
                    $global:LASTEXITCODE = 0
                    if ($issueNum -eq 704) { return $probeJson2 }
                    if ($issueNum -eq 101) { return $umbrellaMinimalJson2 }
                    return $leafLabelsJson
                }
                if ($ghArgs -contains 'view') {
                    $global:LASTEXITCODE = 0
                    return '{"body":"# Control Tower\n\nNo portfolio block yet."}'
                }
                $global:LASTEXITCODE = 0
            }

            $tempSpecLeaf2 = New-TempSpecPath
            @'
schema_version: 2
control_tower: 704
recently_closed_days: 14
umbrellas: [101]
'@ | Set-Content -Path $tempSpecLeaf2 -Encoding UTF8

            try {
                $captured = Invoke-PortfolioRender -specPath $tempSpecLeaf2 3>&1

                $warnings = @($captured | Where-Object { $_ -is [System.Management.Automation.WarningRecord] })
                $leafLabelWarnings = @($warnings | Where-Object { $_.Message -match 'labels' -and $_.Message -match '102' })
                $leafLabelWarnings.Count | Should -BeGreaterThan 0 `
                    -Because 'leaf-loop labels overflow must emit a Write-Warning naming issue #102 and connection labels (AC5 leaf path)'
            }
            finally {
                Remove-Item function:global:gh -ErrorAction SilentlyContinue
                if (Test-Path $tempSpecLeaf2) { Remove-Item $tempSpecLeaf2 -Force -ErrorAction SilentlyContinue }
            }
        }
    }
}

# ===========================================================================
# Test-ConnectionOverflow pure predicate (no I/O, no gh stub needed)
# ===========================================================================
# RED until Step 2 adds Test-ConnectionOverflow to render-portfolio.ps1.
# This Describe block is OUTSIDE Invoke-PortfolioRender so it needs no stub.
Describe 'Test-ConnectionOverflow' {

    It 'returns $true when totalCount (51) exceeds node count (50) — overflow case' {
        # Canonical overflow: API returned 50 nodes but totalCount is 51.
        $nodes = @(1..50 | ForEach-Object { [PSCustomObject]@{ number = $_ } })
        Test-ConnectionOverflow -TotalCount 51 -Nodes $nodes | Should -BeTrue `
            -Because 'totalCount (51) > node count (50) is a truncation overflow'
    }

    It 'returns $false when totalCount equals node count (50/50) — boundary no-overflow' {
        # Exact match: no pages were dropped.
        $nodes = @(1..50 | ForEach-Object { [PSCustomObject]@{ number = $_ } })
        Test-ConnectionOverflow -TotalCount 50 -Nodes $nodes | Should -BeFalse `
            -Because 'totalCount (50) == node count (50) is the boundary non-overflow case'
    }

    It 'returns $true when totalCount (51) exceeds a smaller node count (40) — semantics check' {
        # Confirms the predicate compares against actual returned count, not a fixed page size.
        $nodes = @(1..40 | ForEach-Object { [PSCustomObject]@{ number = $_ } })
        Test-ConnectionOverflow -TotalCount 51 -Nodes $nodes | Should -BeTrue `
            -Because 'totalCount (51) > node count (40): overflow regardless of page sparsity'
    }

    It 'returns $false for single-element connection (1/1) — no scalar-unwrap throw' {
        # PowerShell auto-unwraps single-element arrays; the helper must handle this
        # without throwing a comparison error.
        $nodes = @([PSCustomObject]@{ number = 99 })
        Test-ConnectionOverflow -TotalCount 1 -Nodes $nodes | Should -BeFalse `
            -Because 'single-element connection is not overflow; scalar-unwrap must not cause a throw'
    }

    It 'returns $false for empty connection (0/0)' {
        # Zero totalCount, zero nodes — vacuously not truncated.
        $nodes = @()
        Test-ConnectionOverflow -TotalCount 0 -Nodes $nodes | Should -BeFalse `
            -Because 'empty connection (0 totalCount, 0 nodes) is not overflow'
    }

    It 'returns $false when nodes is $null and totalCount=5 (M3: no-data-is-not-overflow)' {
        # M3 no-data-is-not-overflow: a null nodes collection means the field was absent
        # from the response (e.g. non-umbrella issue has no subIssues field).
        # Absence of data is not evidence of truncation — must return $false, not throw.
        Test-ConnectionOverflow -TotalCount 5 -Nodes $null | Should -BeFalse `
            -Because 'null nodes means the connection field was absent — absence is not overflow (M3)'
    }

    It 'returns $false when totalCount=50 and 50 raw nodes include closed items (M3 closed-blocker analog)' {
        # M3 closed-blocker analog: the predicate operates on the RAW fetched node set,
        # NOT on a downstream-filtered subset (e.g. only OPEN blockers).
        # totalCount=50, 50 raw nodes fetched → no overflow, even if 10 are CLOSED.
        # A regression passing filtered nodes would incorrectly report overflow.
        $rawNodes = @(
            1..10  | ForEach-Object { [PSCustomObject]@{ number = $_;    state = 'CLOSED' } }
            11..50 | ForEach-Object { [PSCustomObject]@{ number = $_;    state = 'OPEN'   } }
        )
        Test-ConnectionOverflow -TotalCount 50 -Nodes $rawNodes | Should -BeFalse `
            -Because 'totalCount=50 with 50 raw nodes is not overflow even when some are closed (M3: use raw count)'
    }
}

# ===========================================================================
# Query-string assertion (M1: totalCount field must be in subIssues umbrella query)
# ===========================================================================
Describe 'render-portfolio query strings' {

    It 'subIssues umbrella query selects totalCount (M1 regression guard)' {
        # M1: the subIssues connection in the umbrella GraphQL query must request
        # totalCount so that Test-ConnectionOverflow can detect truncation.
        # Reading the script source and asserting the field is present.
        # If a future edit drops totalCount from the subIssues block, this test turns RED.
        $scriptContent = Get-Content -Path $scriptPath -Raw
        $scriptContent | Should -Match 'subIssues\(first:\s*\d+\)\s*\{[^}]*totalCount' `
            -Because 'the subIssues connection block in the umbrella GraphQL query must include totalCount for overflow detection (M1)'
    }
}
