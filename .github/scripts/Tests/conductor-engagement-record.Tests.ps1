#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

# Integration tests for Code-Conductor orchestration phase engagement records (issue #577).

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
    $script:HelperCoreLib = Join-Path $script:RepoRoot '.github/scripts/lib/frame-engagement-record-core.ps1'
    if (Test-Path $script:HelperCoreLib) { . $script:HelperCoreLib }

    $script:IssueId = 577

    # Golden Orchestration Fixture (v3)
    $script:V3GoldenFixture = '<!-- engagement-record-orchestration-577 -->
```yaml
schema_version: 3
phase: orchestration
capture_session: "normal-orchestration-v3"
load_bearing_decisions:
  - decision_id: conductor-scope-classification
    classification: load-bearing
    audit_rationale: "Audit rationale for scope-classification."
    engineer_choice: "abbreviated"
    teaching_paragraph_excerpt: "Teaching excerpt for scope classification."
    articulation_text: ""
    articulation_status: pending
```'

    # Malformed V2 Orchestration Fixture (phase orchestration requires schema_version >= 3)
    $script:V2OrchestrationFixture = '<!-- engagement-record-orchestration-577 -->
```yaml
schema_version: 2
phase: orchestration
capture_session: "normal-orchestration-v2"
load_bearing_decisions:
  - decision_id: conductor-scope-classification
    classification: load-bearing
    audit_rationale: "Audit rationale."
    engineer_choice: "abbreviated"
    teaching_paragraph_excerpt: "Excerpt."
    articulation_text: ""
    articulation_status: pending
```'

    # Multi-issue Bundle Fixtures
    $script:BundleFixtureIssueA = '<!-- engagement-record-orchestration-163 -->
```yaml
schema_version: 3
phase: orchestration
capture_session: "normal-orchestration-v3"
load_bearing_decisions:
  - decision_id: conductor-scope-classification
    classification: load-bearing
    audit_rationale: "Audit rationale."
    engineer_choice: "full"
    teaching_paragraph_excerpt: "Excerpt."
    articulation_text: ""
    articulation_status: pending
```'

    $script:BundleFixtureIssueB = '<!-- engagement-record-orchestration-164 -->
```yaml
schema_version: 3
phase: orchestration
capture_session: "normal-orchestration-v3"
load_bearing_decisions:
  - decision_id: conductor-scope-classification
    classification: load-bearing
    audit_rationale: "Audit rationale."
    engineer_choice: "full"
    teaching_paragraph_excerpt: "Excerpt."
    articulation_text: ""
    articulation_status: pending
```'

    # Markdown Comment Body Mirror Example (v3)
    $script:MarkdownMirrorCommentBody = '<!-- engagement-record-orchestration-577 -->
### Named Decisions

- **conductor-scope-classification**
  - **Classification**: load-bearing
  - **Engineer choice**: abbreviated
  - **Audit rationale**: "Audit rationale for scope-classification."
  - **Decision brief excerpt**: "Teaching excerpt for scope classification."
  - **Articulation text**: <!-- CE Gate articulation pending per #578 -->
  - **Articulation status**: pending

```yaml
schema_version: 3
phase: orchestration
capture_session: "normal-orchestration-v3"
load_bearing_decisions:
  - decision_id: conductor-scope-classification
    classification: load-bearing
    audit_rationale: "Audit rationale for scope-classification."
    engineer_choice: "abbreviated"
    teaching_paragraph_excerpt: "Teaching excerpt for scope classification."
    articulation_text: ""
    articulation_status: pending
```'
}

# ---------------------------------------------------------------------------
# (a) v3 golden fixture parse positive
# ---------------------------------------------------------------------------
Describe 'Read-EngagementRecords: v3 golden fixture' {
    It 'parses v3 orchestration golden fixture from in-memory markers' {
        if (-not (Get-Command Read-EngagementRecords -ErrorAction SilentlyContinue)) {
            Set-ItResult -Skipped -Because 'Read-EngagementRecords not available'
            return
        }

        $records = Read-EngagementRecords -IssueNumber $script:IssueId -InMemoryMarkers @($script:V3GoldenFixture) -Phase orchestration
        $records | Should -Not -BeNullOrEmpty
        $records.Count | Should -Be 1
        $records[0].decision_id | Should -Be 'conductor-scope-classification'
        $records[0].engineer_choice | Should -Be 'abbreviated'
        $records[0].phase | Should -Be 'orchestration'
        $records[0].schema_version | Should -Be 3

        # capture_session is validated at the marker level (line 185 of frame-engagement-record-core.ps1) but is
        # not propagated onto the returned decision object. Parse the YAML payload directly to lock the
        # orchestration literal per Code-Conductor body and D16. P3.F14 (review #577 v1.3).
        if (Get-Command ConvertFrom-Yaml -ErrorAction SilentlyContinue) {
            $null = $script:V3GoldenFixture -match '```yaml\s*([\s\S]*?)```'
            $parsed = ConvertFrom-Yaml -Yaml $Matches[1].Trim()
            $parsed.capture_session | Should -Be 'normal-orchestration-v3' -Because 'orchestration phase capture_session is locked to this literal per Code-Conductor body and D16'
        }
    }
}

# ---------------------------------------------------------------------------
# (b) v2-reader-rejects-orchestration negative
# ---------------------------------------------------------------------------
Describe 'Read-EngagementRecords: v2 orchestration rejection' {
    It 'throws InvalidOperationException when phase is orchestration but schema_version is 2' {
        if (-not (Get-Command Read-EngagementRecords -ErrorAction SilentlyContinue)) {
            Set-ItResult -Skipped -Because 'Read-EngagementRecords not available'
            return
        }

        # The core reader should skip or throw when parsed phase requires a higher version.
        # It throws because version 2 does not support orchestration phase.
        { Read-EngagementRecords -IssueNumber $script:IssueId -InMemoryMarkers @($script:V2OrchestrationFixture) -Phase orchestration -WarningAction Stop } |
            Should -Throw -ExpectedMessage '*orchestration phase requires schema_version >= 3*'
    }

    It 'rejects invalid recommendation_shift_trigger values' {
        if (-not (Get-Command Read-EngagementRecords -ErrorAction SilentlyContinue)) {
            Set-ItResult -Skipped -Because 'Read-EngagementRecords not available'
            return
        }

        # P2.F5 pair with Code-Smith Fix B (review #577 v1.3): the per-decision
        # recommendation_shift_trigger enum is now validated in frame-engagement-record-core.ps1.
        # Lock the enum-rejection behavior with a fixture that carries an out-of-enum value.
        # The throw fires inside the CF13b try/catch and is surfaced as Write-Warning; use
        # -WarningAction Stop to convert the warning to a terminating error, matching the v2-rejection pattern.
        $invalidFixture = '<!-- engagement-record-orchestration-577 -->
```yaml
schema_version: 3
phase: orchestration
capture_session: "normal-orchestration-v3"
load_bearing_decisions:
  - decision_id: conductor-scope-classification
    classification: load-bearing
    audit_rationale: "test"
    engineer_choice: "abbreviated"
    teaching_paragraph_excerpt: "test"
    articulation_text: ""
    articulation_status: pending
    recommendation_shift_trigger: invalid-value-that-is-not-in-enum
```'

        { Read-EngagementRecords -IssueNumber $script:IssueId -InMemoryMarkers @($invalidFixture) -Phase orchestration -WarningAction Stop } |
            Should -Throw -ExpectedMessage '*Invalid recommendation_shift_trigger value*'
    }
}

# ---------------------------------------------------------------------------
# (c) & (d) same-decision-resume happy & negative paths
# ---------------------------------------------------------------------------
Describe 'Read-EngagementRecords: same-decision-resume' {
    It 'happy path: returns captured choices for conductor-scope-classification' {
        if (-not (Get-Command Read-EngagementRecords -ErrorAction SilentlyContinue)) {
            Set-ItResult -Skipped -Because 'Read-EngagementRecords not available'
            return
        }

        $records = Read-EngagementRecords -IssueNumber $script:IssueId -InMemoryMarkers @($script:V3GoldenFixture) -Phase orchestration
        $target = $records | Where-Object { $_.decision_id -eq 'conductor-scope-classification' }
        $target | Should -Not -BeNullOrEmpty
        $target.engineer_choice | Should -Be 'abbreviated'
    }

    It 'negative path: does NOT return choices for absent decision_id' {
        if (-not (Get-Command Read-EngagementRecords -ErrorAction SilentlyContinue)) {
            Set-ItResult -Skipped -Because 'Read-EngagementRecords not available'
            return
        }

        $records = Read-EngagementRecords -IssueNumber $script:IssueId -InMemoryMarkers @($script:V3GoldenFixture) -Phase orchestration
        $target = $records | Where-Object { $_.decision_id -eq 'absent-decision-id' }
        $target | Should -BeNullOrEmpty
    }
}

# ---------------------------------------------------------------------------
# (e) round-trip emit->read->deep-equal
# ---------------------------------------------------------------------------
Describe 'Read-EngagementRecords: emit to read round-trip' {
    It 'round-trips custom orchestration-phase objects' {
        if (-not (Get-Command Read-EngagementRecords -ErrorAction SilentlyContinue) -or
            -not (Get-Command ConvertTo-Yaml -ErrorAction SilentlyContinue)) {
            Set-ItResult -Skipped -Because 'Read-EngagementRecords or ConvertTo-Yaml not available'
            return
        }

        $decision = [PSCustomObject]@{
            decision_id = 'conductor-scope-classification'
            classification = 'load-bearing'
            audit_rationale = 'round-trip validation'
            engineer_choice = 'full'
            teaching_paragraph_excerpt = 'round-trip excerpt'
            articulation_text = ''
            articulation_status = 'pending'
        }

        $obj = [PSCustomObject]@{
            schema_version = 3
            phase = 'orchestration'
            capture_session = 'normal-orchestration-v3'
            load_bearing_decisions = @($decision)
        }

        $yaml = ConvertTo-Yaml -Data $obj
        $markerText = "<!-- engagement-record-orchestration-$script:IssueId -->`n``````yaml`n$yaml`n``````"

        $records = Read-EngagementRecords -IssueNumber $script:IssueId -InMemoryMarkers @($markerText) -Phase orchestration
        $records.Count | Should -Be 1
        $records[0].decision_id | Should -Be 'conductor-scope-classification'
        $records[0].engineer_choice | Should -Be 'full'
        $records[0].phase | Should -Be 'orchestration'
        $records[0].schema_version | Should -Be 3
    }
}

# ---------------------------------------------------------------------------
# (f) bundle fan-out
# ---------------------------------------------------------------------------
Describe 'Read-EngagementRecords: bundle fan-out' {
    It 'retrieves per-issue markers independently when bundled issues are classified' {
        if (-not (Get-Command Read-EngagementRecords -ErrorAction SilentlyContinue)) {
            Set-ItResult -Skipped -Because 'Read-EngagementRecords not available'
            return
        }

        # Read for Issue 163
        $recordsA = Read-EngagementRecords -IssueNumber 163 -InMemoryMarkers @($script:BundleFixtureIssueA, $script:BundleFixtureIssueB) -Phase orchestration
        $recordsA.Count | Should -Be 1
        $recordsA[0].decision_id | Should -Be 'conductor-scope-classification'
        $recordsA[0].engineer_choice | Should -Be 'full'

        # Read for Issue 164
        $recordsB = Read-EngagementRecords -IssueNumber 164 -InMemoryMarkers @($script:BundleFixtureIssueA, $script:BundleFixtureIssueB) -Phase orchestration
        $recordsB.Count | Should -Be 1
        $recordsB[0].decision_id | Should -Be 'conductor-scope-classification'
        $recordsB[0].engineer_choice | Should -Be 'full'
    }
}

# ---------------------------------------------------------------------------
# (g) override full re-emit
# ---------------------------------------------------------------------------
Describe 'Read-EngagementRecords: override re-emit' {
    It 'produces fresh marker carrying both reused and revised decisions' {
        if (-not (Get-Command Read-EngagementRecords -ErrorAction SilentlyContinue)) {
            Set-ItResult -Skipped -Because 'Read-EngagementRecords not available'
            return
        }

        # Mimics the override re-emit scenario: the new marker contains both reused and revised decisions
        $reemitFixture = '<!-- engagement-record-orchestration-577 -->
```yaml
schema_version: 3
phase: orchestration
capture_session: "normal-orchestration-v3"
load_bearing_decisions:
  - decision_id: conductor-scope-classification
    classification: load-bearing
    audit_rationale: "Audit rationale for scope-classification revised."
    engineer_choice: "full"
    teaching_paragraph_excerpt: "Teaching excerpt for scope classification."
    articulation_text: ""
    articulation_status: pending
    recommendation_shift_trigger: engineer-pushback
  - decision_id: another-conductor-decision
    classification: routine
    audit_rationale: "Reused unchanged decision."
    engineer_choice: "continue"
    teaching_paragraph_excerpt: "Excerpt."
    articulation_text: ""
    articulation_status: pending
```'

        $records = Read-EngagementRecords -IssueNumber $script:IssueId -InMemoryMarkers @($reemitFixture) -Phase orchestration
        $records.Count | Should -Be 2

        $revised = $records | Where-Object { $_.decision_id -eq 'conductor-scope-classification' }
        $revised.engineer_choice | Should -Be 'full'
        $revised.recommendation_shift_trigger | Should -Be 'engineer-pushback'

        $reused = $records | Where-Object { $_.decision_id -eq 'another-conductor-decision' }
        $reused.engineer_choice | Should -Be 'continue'

        # P3.F13 (review #577 v1.3): full re-emit invariant — the override marker must carry BOTH
        # the revised decision (with recommendation_shift_trigger) AND any reused-unchanged decision in
        # the SAME payload. Lock the additive shape so that a partial-emit regression (dropping the
        # reused decision, or omitting recommendation_shift_trigger on the revised one) genuinely fails.
        $revised | Should -Not -BeNullOrEmpty -Because 'override re-emit must include the revised decision'
        $reused  | Should -Not -BeNullOrEmpty -Because 'override re-emit must include reused-unchanged decisions in the same payload'
        $revised.audit_rationale | Should -Match 'revised' -Because 'revised decision audit_rationale should reflect the override'
        $reused.classification | Should -Be 'routine' -Because 'reused decision retains its prior classification'
        # The reused decision must NOT carry a recommendation_shift_trigger — that field is reserved for
        # decisions whose recommendation actually shifted in this re-emit.
        $reused.PSObject.Properties['recommendation_shift_trigger'] |
            ForEach-Object { $_.Value } |
            Should -BeNullOrEmpty -Because 'reused-unchanged decision must not carry recommendation_shift_trigger'
    }
}

# ---------------------------------------------------------------------------
# (h) mirror integrity
# ---------------------------------------------------------------------------
Describe 'Read-EngagementRecords: mirror integrity' {
    It 'verifies the Markdown mirror co-located inside the comment contains the HTML pending comment' {
        $body = $script:MarkdownMirrorCommentBody
        
        # Test mirror matches YAML key list
        $body | Should -Match '\*\*Classification\*\*:\s*load-bearing'
        $body | Should -Match '\*\*Engineer choice\*\*:\s*abbreviated'
        $body | Should -Match '\*\*Audit rationale\*\*:\s*"Audit rationale for scope-classification."'
        $body | Should -Match '\*\*Decision brief excerpt\*\*:\s*"Teaching excerpt for scope classification."'
        $body | Should -Match '\*\*Articulation text\*\*:\s*<!-- CE Gate articulation pending per #578 -->'
        $body | Should -Match '\*\*Articulation status\*\*:\s*pending'
    }
}

# ---------------------------------------------------------------------------
# (i) byte-equivalence operational definition
# ---------------------------------------------------------------------------
Describe 'Read-EngagementRecords: byte-equivalence operational definition' {
    It 'parses both Markdown mirror and YAML payload independently and asserts field-equivalence except for the documented articulation_text divergence' {
        if (-not (Get-Command ConvertFrom-Yaml -ErrorAction SilentlyContinue)) {
            Set-ItResult -Skipped -Because 'ConvertFrom-Yaml not available'
            return
        }

        # P1.F6 / P3.F6 (review #577 v1.3): the prior test hardcoded mirror values as PowerShell string
        # literals — the Markdown mirror text was never actually parsed. This version parses each surface
        # independently and field-compares them so that a drift between mirror and YAML genuinely fails.
        $commentBody = $script:MarkdownMirrorCommentBody

        # 1. Parse YAML payload via ConvertFrom-Yaml (matches the production reader path).
        $null = $commentBody -match '```yaml\s*([\s\S]*?)```'
        $parsedYaml = ConvertFrom-Yaml -Yaml $Matches[1].Trim()
        $yamlDecision = $parsedYaml.load_bearing_decisions[0]

        # 2. Parse the Markdown mirror bullets independently. The mirror lives between the
        # '### Named Decisions' heading and the start of the YAML fence. Extract that slice and
        # tokenize each '- **Key**: Value' bullet.
        $mirrorSection = [regex]::Match(
            $commentBody,
            '(?s)### Named Decisions(.+?)```yaml'
        ).Groups[1].Value

        $mirrorBullets = @{}
        foreach ($match in [regex]::Matches($mirrorSection, '(?m)^\s*-\s*\*\*(?<key>[^*]+)\*\*:\s*(?<value>.+?)\s*$')) {
            $mirrorBullets[$match.Groups['key'].Value.Trim()] = $match.Groups['value'].Value.Trim().Trim('"')
        }

        $mirrorBullets.Keys.Count | Should -BeGreaterThan 0 -Because 'Markdown mirror parser must extract at least one bullet — if zero, the regex or fixture has drifted'

        # 3. Markdown bullet ↔ YAML key map (per engagement-record-emission/SKILL.md § Markdown Bullet ↔ YAML Key Map).
        $mirrorBullets['Classification']           | Should -Be $yamlDecision.classification
        $mirrorBullets['Engineer choice']          | Should -Be $yamlDecision.engineer_choice
        $mirrorBullets['Audit rationale']          | Should -Be $yamlDecision.audit_rationale
        $mirrorBullets['Decision brief excerpt']   | Should -Be $yamlDecision.teaching_paragraph_excerpt
        $mirrorBullets['Articulation status']      | Should -Be $yamlDecision.articulation_status

        # 4. Documented divergence: YAML carries '' (empty string); Markdown carries the HTML-comment placeholder.
        $yamlDecision.articulation_text         | Should -Be '' -Because 'YAML payload must carry empty articulation_text per D10'
        $mirrorBullets['Articulation text']     | Should -Match 'CE Gate articulation pending per #578' -Because 'Markdown mirror must carry the HTML-comment pending placeholder'
    }
}

# ---------------------------------------------------------------------------
# (j) Code-Conductor body content-match assertions
# ---------------------------------------------------------------------------
Describe 'Code-Conductor.agent.md structure checks' {
    It 'contains the orchestration contract and Named Decisions headings and core text' {
        $agentBody = Get-Content -Path (Join-Path $script:RepoRoot 'agents/Code-Conductor.agent.md') -Raw
        
        $agentBody | Should -Match '### Orchestration engagement-record contract'
        $agentBody | Should -Match '### Named Decisions write-discipline'
        $agentBody | Should -Match 'Content-authoring touchpoints where the solution-authoring classification gate applies'
        $agentBody | Should -Match 'scope-classification'
    }
}

# ---------------------------------------------------------------------------
# (k) upstream marker independence
# ---------------------------------------------------------------------------
Describe 'Read-EngagementRecords: upstream marker independence' {
    It 'does not mutate, overwrite, or double-emit existing upstream phase markers' {
        if (-not (Get-Command Read-EngagementRecords -ErrorAction SilentlyContinue)) {
            Set-ItResult -Skipped -Because 'Read-EngagementRecords not available'
            return
        }

        # Cohabitating experience, design, plan, and orchestration markers
        $experienceMarker = '<!-- engagement-record-experience-577 -->
```yaml
schema_version: 2
phase: experience
capture_session: "normal-experience-v2"
load_bearing_decisions:
  - decision_id: conductor-resume-surface
    classification: load-bearing
    audit_rationale: "Audit rationale experience."
    engineer_choice: "Full parity with upstream"
    teaching_paragraph_excerpt: "Excerpt."
    articulation_text: ""
    articulation_status: pending
```'

        $designMarker = '<!-- engagement-record-design-577 -->
```yaml
schema_version: 2
phase: design
capture_session: "normal-design-v2"
load_bearing_decisions:
  - decision_id: conductor-marker-variant
    classification: load-bearing
    audit_rationale: "Audit rationale design."
    engineer_choice: "orchestration"
    teaching_paragraph_excerpt: "Excerpt."
    articulation_text: ""
    articulation_status: pending
```'

        $orchestrationMarker = $script:V3GoldenFixture

        $allComments = @($experienceMarker, $designMarker, $orchestrationMarker)

        # 1. Read experience phase only
        $expRecords = Read-EngagementRecords -IssueNumber $script:IssueId -InMemoryMarkers $allComments -Phase experience
        $expRecords.Count | Should -Be 1
        $expRecords[0].decision_id | Should -Be 'conductor-resume-surface'
        $expRecords[0].phase | Should -Be 'experience'

        # 2. Read design phase only
        $designRecords = Read-EngagementRecords -IssueNumber $script:IssueId -InMemoryMarkers $allComments -Phase design
        $designRecords.Count | Should -Be 1
        $designRecords[0].decision_id | Should -Be 'conductor-marker-variant'
        $designRecords[0].phase | Should -Be 'design'

        # 3. Read orchestration phase only
        $orchRecords = Read-EngagementRecords -IssueNumber $script:IssueId -InMemoryMarkers $allComments -Phase orchestration
        $orchRecords.Count | Should -Be 1
        $orchRecords[0].decision_id | Should -Be 'conductor-scope-classification'
        $orchRecords[0].phase | Should -Be 'orchestration'
    }
}

# ---------------------------------------------------------------------------
# (l) orchestration burst-harvest invariants — P2.F5 (review #577 v1.3)
#
# The write side of the burst (engagement-record-orchestration + credit-input-orchestration
# co-emission) is LLM-driven via Code-Conductor's agent body and cannot be unit-tested
# directly. The READ/HARVEST side is script-driven via Invoke-CreditInputHarvest and
# can be exercised against synthetic markers.
#
# Invariants asserted:
#   (1) Both burst comments present  → harvester emits orchestration credit row.
#   (2) Only credit-input present    → harvester must NOT emit row (burst halt-on-failure).
# ---------------------------------------------------------------------------
Describe 'orchestration burst-harvest invariants' {
    BeforeAll {
        $script:LedgerCoreLib = Join-Path $script:RepoRoot '.github/scripts/lib/frame-credit-ledger-core.ps1'
        if (Test-Path $script:LedgerCoreLib) { . $script:LedgerCoreLib }

        # Temp dir for mock gh scripts used in this Describe block.
        $script:BurstTempDir = Join-Path ([System.IO.Path]::GetTempPath()) "pester-burst-invariants-$([Guid]::NewGuid().ToString('N'))"
        New-Item -ItemType Directory -Path $script:BurstTempDir -Force | Out-Null
    }

    AfterAll {
        if ($null -ne $script:BurstTempDir -and (Test-Path $script:BurstTempDir)) {
            Remove-Item -Recurse -Force $script:BurstTempDir -ErrorAction SilentlyContinue
        }
    }

    It 'harvests credit-input-orchestration marker into orchestration credit row when both burst comments are present' {
        if (-not (Get-Command Invoke-CreditInputHarvest -ErrorAction SilentlyContinue)) {
            Set-ItResult -Skipped -Because 'Invoke-CreditInputHarvest not available'
            return
        }

        $engagementRecord = '<!-- engagement-record-orchestration-999 -->
```yaml
schema_version: 3
phase: orchestration
capture_session: "normal-orchestration-v3"
load_bearing_decisions:
  - decision_id: conductor-scope-classification
    classification: load-bearing
    audit_rationale: "test rationale"
    engineer_choice: "abbreviated"
    teaching_paragraph_excerpt: "test brief"
    articulation_text: ""
    articulation_status: pending
```'

        $creditInput = '<!-- credit-input-orchestration-999 -->
```yaml
port: orchestration
adapter: scope-classification
evidence: "issue #999; scope-classification engagement-record emitted"
```'

        $result = Invoke-CreditInputHarvest -IssueNumber 999 -Repo 'test/test' -InMemoryMarkers @($engagementRecord, $creditInput)
        $orchestrationRow = $result | Where-Object { $_.port -eq 'orchestration' }

        $orchestrationRow | Should -Not -BeNullOrEmpty -Because 'harvester must emit orchestration row when both burst comments are present'
        $orchestrationRow.status | Should -Be 'passed' -Because 'both engagement-record + credit-input present means burst succeeded'
        $orchestrationRow.evidence | Should -Match 'engagement-record' -Because 'evidence string should describe the harvest outcome'
    }

    It 'does NOT emit orchestration credit row when only credit-input is present (engagement-record missing)' {
        if (-not (Get-Command Invoke-CreditInputHarvest -ErrorAction SilentlyContinue)) {
            Set-ItResult -Skipped -Because 'Invoke-CreditInputHarvest not available'
            return
        }

        $creditInput = '<!-- credit-input-orchestration-999 -->
```yaml
port: orchestration
adapter: scope-classification
evidence: "issue #999; scope-classification engagement-record emitted"
```'

        # Burst-halt invariant: when gh IS reachable but has no engagement-record-orchestration
        # comment, the harvester must suppress the credit row even when credit-input is in-memory.
        # This covers the cross-session case (F9): credit-input in-memory, completion only on gh,
        # but gh confirms no completion exists → no row emitted.
        #
        # A mock gh that returns a reachable JSON response with the credit-input comment only
        # (no completion marker) is required so the harvester can distinguish "gh reachable but
        # no completion" from "gh unreachable" (the fail-open path for purely in-session credits).
        $creditInputJson = $creditInput | ConvertTo-Json -Compress
        $mockGhPath = Join-Path $script:BurstTempDir 'gh-no-completion-orchestration.ps1'
        @"
param()
Write-Output '{"comments": [{"body": $creditInputJson}]}'
exit 0
"@ | Set-Content $mockGhPath -Encoding UTF8

        $result = Invoke-CreditInputHarvest `
            -IssueNumber     999 `
            -Repo            'test/test' `
            -GhCliPath       $mockGhPath `
            -InMemoryMarkers @($creditInput) `
            -MaxRetries      0
        $orchestrationRow = $result | Where-Object { $_.port -eq 'orchestration' }

        $orchestrationRow | Should -BeNullOrEmpty -Because 'harvester must NOT emit orchestration row when gh is reachable but engagement-record is missing (burst halt-on-failure invariant)'
    }
}
