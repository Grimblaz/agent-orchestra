#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

# Integration tests for Read-EngagementRecords (issue #575, Step 1).
#
# (a) parser-capability: roundtrip block scalars and nested mappings
# (b) marker-parse (v1 golden fixture): synthetic golden marker parses to expected shape
# (c) schema-conformance: throws on unknown schema_version or invalid enums
# (d) resume happy path: returns correct choice for loaded decision
# (e) resume negative path: does not return choice for non-existent decision
# (f) round-trip: custom object roundtrip through conversion and extraction
# (g) multi-marker resolution: uses createdAt timestamp to select latest comment
# (h) legacy-loose-parse: accepts #571 marker with -AcceptLegacy

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
    $script:HelperCoreLib = Join-Path $script:RepoRoot '.github/scripts/lib/frame-engagement-record-core.ps1'
    if (Test-Path $script:HelperCoreLib) { . $script:HelperCoreLib }

    $script:TempDir = Join-Path ([System.IO.Path]::GetTempPath()) "pester-engagement-roundtrip-$([Guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Path $script:TempDir -Force | Out-Null

    # Helper: write a mock gh script that returns a JSON comments payload with body and createdAt.
    function script:Write-MockGh {
        param(
            [string]$ScriptPath,
            [hashtable[]]$Comments
        )

        $commentsJson = ($Comments | ForEach-Object {
            $escapedBody = $_.Body | ConvertTo-Json -Compress
            $escapedCreatedAt = $_.CreatedAt | ConvertTo-Json -Compress
            '{"body": ' + $escapedBody + ', "createdAt": ' + $escapedCreatedAt + '}'
        }) -join ','

        $mockBody = 'param()
# Guard: fail immediately if any unsupported flag is present (e.g. --paginate is gh api only, not gh issue view)
if ($args -contains ''--paginate'') { Write-Error ''unknown flag: --paginate''; exit 1 }
Write-Output ''{"comments": [' + $commentsJson + ']}''
exit 0
'
        $mockBody | Set-Content $ScriptPath -Encoding UTF8
    }

    $script:IssueId = '575'
    $script:Repo    = 'Grimblaz/agent-orchestra'

    # Synthetic v1 Golden Fixture
    $script:V1GoldenFixture = '<!-- engagement-record-design-575 -->
```yaml
schema_version: 1
phase: design
capture_session: "normal-design-v1"
load_bearing_decisions:
  - decision_id: schema-location
    classification: load-bearing
    audit_rationale: "Rationale sentence goes here."
    engineer_choice: "New skills/engagement-record-emission/SKILL.md"
    teaching_paragraph_excerpt: "The skill file path is where the canonical marker schema lives."
    articulation_text: "I chose this path because it keeps things clean."
    articulation_status: pending
  - decision_id: another-decision
    classification: routine
    audit_rationale: "Routine rationale."
    engineer_choice: "Routine choice"
    teaching_paragraph_excerpt: "A simple teaching sentence."
    articulation_text: ""
    articulation_status: incomplete
```'

    # Legacy #571 Fixture
    $script:LegacyFixture = '<!-- engagement-record-design-571 -->
load_bearing_decisions:
  - decision_id: D-load-directive
    classification: load-bearing
    audit_rationale: "No prior phase named..."
    engineer_choice: "solution-authoring first"
    teaching_paragraph_excerpt: "The Process section of each agent body..."
    articulation_text: "I chose solution-authoring first because..."
    articulation_status: pending'
}

AfterAll {
    if (Test-Path $script:TempDir) {
        Remove-Item -Recurse -Force $script:TempDir -ErrorAction SilentlyContinue
    }
}

# ---------------------------------------------------------------------------
# (a) parser-capability round-trip
# ---------------------------------------------------------------------------
Describe 'Read-EngagementRecords: parser capability' {
    It 'correctly round-trips yaml with block scalars and nested mappings via powershell-yaml' {
        if (-not (Get-Module -ListAvailable powershell-yaml)) {
            Set-ItResult -Skipped -Because 'powershell-yaml module not installed'
            return
        }

        # Verify powershell-yaml can represent block scalar and nested structure
        $fixture = 'schema_version: 1
phase: design
capture_session: "normal-design-v1"
load_bearing_decisions:
  - decision_id: test-id
    classification: load-bearing
    audit_rationale: |
      First line.
      Second line.
    engineer_choice: "choice"'
        $parsed = ConvertFrom-Yaml -Yaml $fixture
        $parsed.schema_version | Should -Be 1
        $parsed.load_bearing_decisions[0].decision_id | Should -Be 'test-id'
        $parsed.load_bearing_decisions[0].audit_rationale.Trim() | Should -Be "First line.`nSecond line." -Because 'powershell-yaml should parse block scalars correctly'
    }
}

# ---------------------------------------------------------------------------
# (b) marker-parse (v1 golden fixture)
# ---------------------------------------------------------------------------
Describe 'Read-EngagementRecords: marker-parse v1' {
    It 'parses v1 golden fixture from in-memory markers' {
        if (-not (Get-Command Read-EngagementRecords -ErrorAction SilentlyContinue)) {
            Set-ItResult -Skipped -Because 'Read-EngagementRecords not available'
            return
        }

        $records = Read-EngagementRecords -IssueNumber $script:IssueId -InMemoryMarkers @($script:V1GoldenFixture) -Phase design
        $records | Should -Not -BeNullOrEmpty
        $records.Count | Should -Be 2
        $records[0].decision_id | Should -Be 'schema-location'
        $records[1].decision_id | Should -Be 'another-decision'
    }
}

# ---------------------------------------------------------------------------
# (c) schema-conformance
# ---------------------------------------------------------------------------
Describe 'Read-EngagementRecords: schema conformance and version validation' {
    It 'throws on unknown schema_version' {
        if (-not (Get-Command Read-EngagementRecords -ErrorAction SilentlyContinue)) {
            Set-ItResult -Skipped -Because 'Read-EngagementRecords not available'
            return
        }

        # Use schema_version: 5 (the boundary case — next-unknown after v4) rather than a distant value like 99.
        # v4 shipped in #655 (review phase); this fixture was bumped 4→5 in lockstep with the throw-set in
        # frame-engagement-record-core.ps1 (now @(1, 2, 3, 4)). When v5 ships, bump this fixture again. Tracking #577 review P3.F8.
        $invalidVersionFixture = '<!-- engagement-record-design-575 -->
```yaml
schema_version: 5
phase: design
capture_session: "normal-design-v1"
load_bearing_decisions: []
```'
        # F-CO1: unknown schema_version is now thrown OUTSIDE the CF13b per-marker try/catch,
        # so it propagates as a hard error. The call must throw.
        { Read-EngagementRecords -IssueNumber $script:IssueId -InMemoryMarkers @($invalidVersionFixture) -Phase design } |
            Should -Throw
    }
}

# ---------------------------------------------------------------------------
# (d) resume happy path
# ---------------------------------------------------------------------------
Describe 'Read-EngagementRecords: resume happy path' {
    It 'returns decision and choice details when target decision exists' {
        if (-not (Get-Command Read-EngagementRecords -ErrorAction SilentlyContinue)) {
            Set-ItResult -Skipped -Because 'Read-EngagementRecords not available'
            return
        }

        $records = Read-EngagementRecords -IssueNumber $script:IssueId -InMemoryMarkers @($script:V1GoldenFixture) -Phase design
        $target = $records | Where-Object { $_.decision_id -eq 'schema-location' }
        $target | Should -Not -BeNullOrEmpty
        $target.engineer_choice | Should -Be "New skills/engagement-record-emission/SKILL.md"
        $target.classification | Should -Be 'load-bearing'
    }
}

# ---------------------------------------------------------------------------
# (e) resume negative path
# ---------------------------------------------------------------------------
Describe 'Read-EngagementRecords: resume negative path' {
    It 'does NOT return a decision_id that is absent from the marker' {
        if (-not (Get-Command Read-EngagementRecords -ErrorAction SilentlyContinue)) {
            Set-ItResult -Skipped -Because 'Read-EngagementRecords not available'
            return
        }

        $records = Read-EngagementRecords -IssueNumber $script:IssueId -InMemoryMarkers @($script:V1GoldenFixture) -Phase design
        $target = $records | Where-Object { $_.decision_id -eq 'non-existent-id' }
        $target | Should -BeNullOrEmpty
    }
}

# ---------------------------------------------------------------------------
# (f) round-trip PSCustomObject
# ---------------------------------------------------------------------------
Describe 'Read-EngagementRecords: custom object round-trip' {
    It 'successfully converts to YAML and extracts back' {
        if (-not (Get-Command Read-EngagementRecords -ErrorAction SilentlyContinue) -or
            -not (Get-Command ConvertTo-Yaml -ErrorAction SilentlyContinue)) {
            Set-ItResult -Skipped -Because 'harvester functions or ConvertTo-Yaml not available'
            return
        }

        $obj = [PSCustomObject]@{
            schema_version = 1
            phase = 'design'
            capture_session = 'normal-design-v1'
            load_bearing_decisions = @(
                [PSCustomObject]@{
                    decision_id = 'round-trip-test'
                    classification = 'load-bearing'
                    audit_rationale = 'round-trip audit'
                    engineer_choice = 'verified'
                    teaching_paragraph_excerpt = 'round-trip teaching'
                    articulation_text = 'articulated'
                    articulation_status = 'complete'
                }
            )
        }

        $yaml = ConvertTo-Yaml -Data $obj
        $markerText = "<!-- engagement-record-design-$script:IssueId -->`n``````yaml`n$yaml`n``````"
        $records = Read-EngagementRecords -IssueNumber $script:IssueId -InMemoryMarkers @($markerText) -Phase design
        $records.Count | Should -Be 1
        $records[0].decision_id | Should -Be 'round-trip-test'
        $records[0].engineer_choice | Should -Be 'verified'
    }
}

# ---------------------------------------------------------------------------
# (g) multi-marker resolution with timestamp
# ---------------------------------------------------------------------------
Describe 'Read-EngagementRecords: multi-marker latest-wins resolution' {
    It 'returns decisions only from the newest marker based on createdAt timestamp' {
        if (-not (Get-Command Read-EngagementRecords -ErrorAction SilentlyContinue)) {
            Set-ItResult -Skipped -Because 'Read-EngagementRecords not available'
            return
        }

        $oldMarker = '<!-- engagement-record-design-575 -->
```yaml
schema_version: 1
phase: design
capture_session: "normal-design-v1"
load_bearing_decisions:
  - decision_id: multi-test-id
    classification: load-bearing
    engineer_choice: "old choice"
```'

        $newMarker = '<!-- engagement-record-design-575 -->
```yaml
schema_version: 1
phase: design
capture_session: "normal-design-v1"
load_bearing_decisions:
  - decision_id: multi-test-id
    classification: load-bearing
    engineer_choice: "new choice"
```'

        $comments = @(
            @{ Body = $oldMarker; CreatedAt = '2026-05-01T00:00:00Z' },
            @{ Body = $newMarker; CreatedAt = '2026-05-23T00:00:00Z' }
        )

        $mockPath = Join-Path $script:TempDir 'gh-multi-marker.ps1'
        script:Write-MockGh -ScriptPath $mockPath -Comments $comments

        $records = Read-EngagementRecords -IssueNumber $script:IssueId -Repo $script:Repo -GhCliPath $mockPath -Phase design
        $records.Count | Should -Be 1
        $records[0].engineer_choice | Should -Be 'new choice' -Because 'latest-timestamp comment should overwrite older ones'
    }
}

# ---------------------------------------------------------------------------
# (h) legacy-loose-parse for #571
# ---------------------------------------------------------------------------
Describe 'Read-EngagementRecords: legacy loose parse' {
    It 'parses #571 legacy marker when -AcceptLegacy switch is provided' {
        if (-not (Get-Command Read-EngagementRecords -ErrorAction SilentlyContinue)) {
            Set-ItResult -Skipped -Because 'Read-EngagementRecords not available'
            return
        }

        # Legacy fixture is for issue 571; call with matching IssueNumber (MF2: issue-number check is always enforced)
        $records = Read-EngagementRecords -IssueNumber 571 -InMemoryMarkers @($script:LegacyFixture) -Phase design -AcceptLegacy
        $records | Should -Not -BeNullOrEmpty
        $records.Count | Should -Be 1
        $records[0].decision_id | Should -Be 'D-load-directive'
        $records[0].engineer_choice | Should -Be 'solution-authoring first'
        $records[0]._legacy | Should -BeTrue -Because 'AcceptLegacy should mark result with _legacy: true'
    }
}

# ---------------------------------------------------------------------------
# (i) multi-marker: old decisions absent when newer marker wins
# ---------------------------------------------------------------------------
Describe 'Read-EngagementRecords: old marker decisions not surfaced when newer wins' {
    It 'does NOT return decision_ids from the older marker when a newer one exists' {
        if (-not (Get-Command Read-EngagementRecords -ErrorAction SilentlyContinue)) {
            Set-ItResult -Skipped -Because 'Read-EngagementRecords not available'
            return
        }

        $oldMarker = '<!-- engagement-record-design-575 -->
```yaml
schema_version: 1
phase: design
capture_session: "normal-design-v1"
load_bearing_decisions:
  - decision_id: old-only-id
    classification: load-bearing
    engineer_choice: "old-only choice"
```'

        $newMarker = '<!-- engagement-record-design-575 -->
```yaml
schema_version: 1
phase: design
capture_session: "normal-design-v1"
load_bearing_decisions:
  - decision_id: new-only-id
    classification: load-bearing
    engineer_choice: "new-only choice"
```'

        $comments = @(
            @{ Body = $oldMarker; CreatedAt = '2026-05-01T00:00:00Z' },
            @{ Body = $newMarker; CreatedAt = '2026-05-23T00:00:00Z' }
        )

        $mockPath = Join-Path $script:TempDir 'gh-old-absent.ps1'
        script:Write-MockGh -ScriptPath $mockPath -Comments $comments

        $records = Read-EngagementRecords -IssueNumber $script:IssueId -Repo $script:Repo -GhCliPath $mockPath -Phase design
        $oldDecision = $records | Where-Object { $_.decision_id -eq 'old-only-id' }
        $newDecision = $records | Where-Object { $_.decision_id -eq 'new-only-id' }
        $oldDecision | Should -BeNullOrEmpty -Because 'old marker decisions must not appear when a newer marker exists'
        $newDecision | Should -Not -BeNullOrEmpty -Because 'new marker decisions should be returned'
    }
}

# ---------------------------------------------------------------------------
# (j) InMemoryMarkers tiebreak: last element in array wins
# ---------------------------------------------------------------------------
Describe 'Read-EngagementRecords: InMemoryMarkers last-element tiebreak' {
    It 'returns decisions from the last in-memory marker when multiple share the same phase' {
        if (-not (Get-Command Read-EngagementRecords -ErrorAction SilentlyContinue)) {
            Set-ItResult -Skipped -Because 'Read-EngagementRecords not available'
            return
        }

        $firstMarker = '<!-- engagement-record-design-575 -->
```yaml
schema_version: 1
phase: design
capture_session: "normal-design-v1"
load_bearing_decisions:
  - decision_id: tiebreak-id
    classification: load-bearing
    engineer_choice: "first choice"
```'

        $lastMarker = '<!-- engagement-record-design-575 -->
```yaml
schema_version: 1
phase: design
capture_session: "normal-design-v1"
load_bearing_decisions:
  - decision_id: tiebreak-id
    classification: load-bearing
    engineer_choice: "last choice"
```'

        $records = Read-EngagementRecords -IssueNumber $script:IssueId -InMemoryMarkers @($firstMarker, $lastMarker) -Phase design
        $records.Count | Should -Be 1
        $records[0].engineer_choice | Should -Be 'last choice' -Because 'last InMemoryMarkers element wins when timestamps are synthetic-ascending'
    }
}

# ---------------------------------------------------------------------------
# (k) unknown optional field: additive-field policy — no throw
# ---------------------------------------------------------------------------
Describe 'Read-EngagementRecords: unknown optional field does not throw' {
    It 'silently ignores unknown optional fields in the YAML payload' {
        if (-not (Get-Command Read-EngagementRecords -ErrorAction SilentlyContinue)) {
            Set-ItResult -Skipped -Because 'Read-EngagementRecords not available'
            return
        }

        $unknownFieldFixture = '<!-- engagement-record-design-575 -->
```yaml
schema_version: 1
phase: design
capture_session: "normal-design-v1"
extra_future_field: "should be ignored"
load_bearing_decisions:
  - decision_id: unknown-field-test
    classification: routine
    engineer_choice: "choice"
    extra_decision_field: "also ignored"
```'

        {
            $records = Read-EngagementRecords -IssueNumber $script:IssueId -InMemoryMarkers @($unknownFieldFixture) -Phase design
            $records | Should -Not -BeNullOrEmpty
            $records[0].decision_id | Should -Be 'unknown-field-test'
        } | Should -Not -Throw -Because 'additive-field policy: readers must ignore unknown optional fields'
    }
}

# ---------------------------------------------------------------------------
# (l) phase plan validation: accepts phase: plan + schema_version: 2 round-trip
# ---------------------------------------------------------------------------
Describe 'Read-EngagementRecords: phase plan validation' {
    It 'accepts phase: plan and schema_version: 2 round-trip' {
        if (-not (Get-Command Read-EngagementRecords -ErrorAction SilentlyContinue)) {
            Set-ItResult -Skipped -Because 'Read-EngagementRecords not available'
            return
        }

        $planFixture = '<!-- engagement-record-plan-576 -->
```yaml
schema_version: 2
phase: plan
capture_session: "normal-plan-v2"
load_bearing_decisions:
  - decision_id: plan-write-target
    classification: load-bearing
    audit_rationale: "We locked the write target."
    engineer_choice: "Plan comment"
    teaching_paragraph_excerpt: "Colocate plan and decisions."
    articulation_text: ""
    articulation_status: pending
```'

        $records = Read-EngagementRecords -IssueNumber 576 -InMemoryMarkers @($planFixture) -Phase plan
        $records | Should -Not -BeNullOrEmpty
        $records.Count | Should -Be 1
        $records[0].decision_id | Should -Be 'plan-write-target'
        $records[0].phase | Should -Be 'plan'
        $records[0].schema_version | Should -Be 2
    }

    It 'skips marker with unknown fourth phase and emits warning (CF13b)' {
        if (-not (Get-Command Read-EngagementRecords -ErrorAction SilentlyContinue)) {
            Set-ItResult -Skipped -Because 'Read-EngagementRecords not available'
            return
        }

        $badPhaseFixture = '<!-- engagement-record-unknown-576 -->
```yaml
schema_version: 2
phase: unknown
capture_session: "normal-plan-v2"
load_bearing_decisions: []
```'

        # CF13b: per-marker validation failures now warn-and-skip; the call must not throw.
        $records = $null
        { $records = Read-EngagementRecords -IssueNumber 576 -InMemoryMarkers @($badPhaseFixture) -Phase plan -WarningAction SilentlyContinue } |
            Should -Not -Throw
        $records.Count | Should -Be 0
    }
}

