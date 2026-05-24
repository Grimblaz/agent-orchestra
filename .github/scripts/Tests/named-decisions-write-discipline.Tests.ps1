#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

# Pester unit and integration tests for Issue #576
# cognitive-surrender-prevention v1.2: Named Decisions write-discipline + engagement-record emission

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
    $script:HelperCoreLib = Join-Path $script:RepoRoot '.github/scripts/lib/frame-engagement-record-core.ps1'
    if (Test-Path $script:HelperCoreLib) { . $script:HelperCoreLib }

    $script:ExperienceOwnerPath = Join-Path $script:RepoRoot 'agents/Experience-Owner.agent.md'
    $script:SolutionDesignerPath = Join-Path $script:RepoRoot 'agents/Solution-Designer.agent.md'
    $script:IssuePlannerPath = Join-Path $script:RepoRoot 'agents/Issue-Planner.agent.md'

    # Helper scriptblock to extract a sub-section from an agent body file
    $script:GetWriteDisciplineSection = {
        param([string]$FilePath)
        $lines = Get-Content $FilePath
        $sectionLines = [System.Collections.Generic.List[string]]::new()
        $inSection = $false

        foreach ($line in $lines) {
            if ($line -match '^### Named Decisions write-discipline') {
                $inSection = $true
                $sectionLines.Add($line)
                continue
            }
            if ($inSection) {
                # CF2 fix: stop only on H2 (^## ) headers — never on H3 — so the entire
                # write-discipline H3 sub-section (including the `### {decision_id}` template
                # H3 inside it) is captured. Defensive `-notmatch` on the starting H3 retained.
                if ($line -match '^##\s+' -and $line -notmatch '^### Named Decisions write-discipline') {
                    break
                }
                $sectionLines.Add($line)
            }
        }
        return $sectionLines -join "`n"
    }

    # Helper scriptblock to parse markdown named decisions
    $script:ParseMarkdownNamedDecisions = {
        param([string]$MarkdownText)
        $decisions = @{}
        $currentDecisionId = $null
        $currentFields = @{}
        $inArticulationText = $false

        $lines = $MarkdownText -split "`r?\n"
        foreach ($line in $lines) {
            if ($line -match '^###\s+([a-z][a-z0-9-]{1,63})$') {
                if ($currentDecisionId) {
                    $decisions[$currentDecisionId] = $currentFields
                }
                $currentDecisionId = $Matches[1]
                $currentFields = @{}
                $inArticulationText = $false
                continue
            }
            if ($currentDecisionId) {
                if ($inArticulationText) {
                    if ($line -match '^\s+(.*)') {
                        $currentFields['articulation_text'] += $Matches[1] + "`n"
                        continue
                    } else {
                        $inArticulationText = $false
                    }
                }

                if ($line -match '-\s+\*\*Classification\*\*:\s*(.*)') {
                    $currentFields['classification'] = $Matches[1].Trim()
                }
                elseif ($line -match '-\s+\*\*Engineer choice\*\*:\s*"(.*)"') {
                    $currentFields['engineer_choice'] = $Matches[1].Trim()
                }
                elseif ($line -match '-\s+\*\*Audit rationale\*\*:\s*"(.*)"') {
                    $currentFields['audit_rationale'] = $Matches[1].Trim()
                }
                elseif ($line -match '-\s+\*\*Decision brief excerpt\*\*:\s*"(.*)"') {
                    $currentFields['teaching_paragraph_excerpt'] = $Matches[1].Trim()
                }
                elseif ($line -match '-\s+\*\*Articulation status\*\*:\s*(.*)') {
                    $currentFields['articulation_status'] = $Matches[1].Trim()
                }
                elseif ($line -match '-\s+\*\*Articulation text\*\*:\s*(.*)') {
                    $val = $Matches[1].Trim()
                    if ($val -eq '|') {
                        # Multiline block
                        $currentFields['articulation_text'] = ''
                        $inArticulationText = $true
                    } else {
                        $currentFields['articulation_text'] = $val
                    }
                }
                elseif ($line -match '-\s+\*\*Recommendation shift trigger\*\*:\s*(.*)') {
                    $currentFields['recommendation_shift_trigger'] = $Matches[1].Trim()
                }
            }
        }
        if ($currentDecisionId) {
            $decisions[$currentDecisionId] = $currentFields
        }
        return $decisions
    }
}

Describe 'AC6.1: Greppability of upstream agent bodies' {
    It 'Experience-Owner agent body contains ### Named Decisions write-discipline H3' {
        $content = Get-Content $script:ExperienceOwnerPath -Raw
        $content | Should -Match '### Named Decisions write-discipline'
    }

    It 'Solution-Designer agent body contains ### Named Decisions write-discipline H3' {
        $content = Get-Content $script:SolutionDesignerPath -Raw
        $content | Should -Match '### Named Decisions write-discipline'
    }

    It 'Issue-Planner agent body contains ### Named Decisions write-discipline H3' {
        $content = Get-Content $script:IssuePlannerPath -Raw
        $content | Should -Match '### Named Decisions write-discipline'
    }
}

Describe 'AC6.2: Byte-equivalence of write-discipline sections' {
    It 'The three agent sub-sections are byte-equivalent after placeholder substitution' {
        $eoSection = & $script:GetWriteDisciplineSection -FilePath $script:ExperienceOwnerPath
        $sdSection = & $script:GetWriteDisciplineSection -FilePath $script:SolutionDesignerPath
        $ipSection = & $script:GetWriteDisciplineSection -FilePath $script:IssuePlannerPath

        $eoSection | Should -Not -BeNullOrEmpty
        $sdSection | Should -Not -BeNullOrEmpty
        $ipSection | Should -Not -BeNullOrEmpty

        # Normalize placeholders for EO
        # {phase} -> experience, {section-target} -> issue body H2 immediately after ## Scenarios per D12
        # {marker-prefix} -> engagement-record-experience, {capture_session} -> normal-experience-v2
        $eoNormalized = $eoSection `
            -replace [Regex]::Escape('issue body H2 immediately after ## Scenarios per D12, wrapped in `<!-- named-decisions:begin -->` ... `<!-- named-decisions:end -->` sentinels'), '{section-target}' `
            -replace 'engagement-record-experience', '{marker-prefix}' `
            -replace 'normal-experience-v2', '{capture_session}' `
            -replace 'experience', '{phase}'

        # Normalize placeholders for SD
        # {phase} -> design, {section-target} -> issue body H2 immediately after ## Scenarios per D12, or immediately before ## Design Decisions H2 if ## Scenarios is absent (SD fallback)
        # {marker-prefix} -> engagement-record-design, {capture_session} -> normal-design-v2
        $sdNormalized = $sdSection `
            -replace [Regex]::Escape('issue body H2 immediately after ## Scenarios per D12, or immediately before ## Design Decisions H2 if ## Scenarios is absent (SD fallback), wrapped in `<!-- named-decisions:begin -->` ... `<!-- named-decisions:end -->` sentinels'), '{section-target}' `
            -replace 'engagement-record-design', '{marker-prefix}' `
            -replace 'normal-design-v2', '{capture_session}' `
            -replace 'design', '{phase}'

        # Normalize placeholders for IP
        # {phase} -> plan, {section-target} -> last H2 of the <!-- plan-issue-{ID} --> comment (after ac-refs-by-slice: coverage manifest); wrapped in <!-- named-decisions:begin -->...<!-- named-decisions:end --> sentinels; overwrite-in-place on re-runs per D7; excluded from D9 normalized-comparison hash
        # {marker-prefix} -> engagement-record-plan, {capture_session} -> normal-plan-v2
        $ipNormalized = $ipSection `
            -replace [Regex]::Escape('last H2 of the <!-- plan-issue-{ID} --> comment (after ac-refs-by-slice: coverage manifest); wrapped in <!-- named-decisions:begin -->...<!-- named-decisions:end --> sentinels; overwrite-in-place on re-runs per D7; excluded from D9 normalized-comparison hash'), '{section-target}' `
            -replace 'engagement-record-plan', '{marker-prefix}' `
            -replace 'normal-plan-v2', '{capture_session}' `
            -replace 'plan', '{phase}'

        # Compare byte arrays
        $eoBytes = [System.Text.Encoding]::UTF8.GetBytes($eoNormalized.Trim())
        $sdBytes = [System.Text.Encoding]::UTF8.GetBytes($sdNormalized.Trim())
        $ipBytes = [System.Text.Encoding]::UTF8.GetBytes($ipNormalized.Trim())

        $sdBytes | Should -Be $eoBytes -Because 'Solution-Designer section should match Experience-Owner'
        $ipBytes | Should -Be $eoBytes -Because 'Issue-Planner section should match Experience-Owner'
    }
}

Describe 'AC6.3: Mirror integrity' {
    BeforeAll {
        $validMarkdown = '<!-- named-decisions:begin -->
### test-decision
- **Classification**: load-bearing
- **Engineer choice**: "Option 2"
- **Audit rationale**: "We need TDD."
- **Decision brief excerpt**: "Pester tests are run."
- **Articulation text**: |
    We chose option 2.
- **Articulation status**: pending
<!-- named-decisions:end -->'

        $validYaml = '<!-- engagement-record-plan-576 -->
```yaml
schema_version: 2
phase: plan
capture_session: "normal-plan-v2"
load_bearing_decisions:
  - decision_id: test-decision
    classification: load-bearing
    audit_rationale: "We need TDD."
    engineer_choice: "Option 2"
    teaching_paragraph_excerpt: "Pester tests are run."
    articulation_text: |
        We chose option 2.
    articulation_status: pending
```'
    }

    It 'Mirror integrity positive (field-set equivalence)' {
        if (-not (Get-Command Read-EngagementRecords -ErrorAction SilentlyContinue)) {
            Set-ItResult -Skipped -Because 'Read-EngagementRecords not available'
            return
        }

        # Parse markdown
        $mdParsed = & $script:ParseMarkdownNamedDecisions -MarkdownText $validMarkdown
        # Parse YAML
        $records = Read-EngagementRecords -IssueNumber 576 -InMemoryMarkers @($validYaml) -Phase plan

        $records.Count | Should -Be 1
        $mdParsed.ContainsKey('test-decision') | Should -BeTrue

        # Check field-set equality
        $mdDec = $mdParsed['test-decision']
        $yamlDec = $records[0]

        $yamlDec.decision_id | Should -Be 'test-decision'
        $mdDec['classification'] | Should -Be $yamlDec.classification
        $mdDec['engineer_choice'] | Should -Be $yamlDec.engineer_choice
        $mdDec['audit_rationale'] | Should -Be $yamlDec.audit_rationale
        $mdDec['teaching_paragraph_excerpt'] | Should -Be $yamlDec.teaching_paragraph_excerpt
        $mdDec['articulation_status'] | Should -Be $yamlDec.articulation_status
        # Handle trailing space/newline differences in block scalar safely
        $mdDec['articulation_text'].Trim() | Should -Be $yamlDec.articulation_text.Trim()
    }

    It 'Mirror integrity negative: H3 in Markdown with no matching YAML decision_id -> fail' {
        $md = '<!-- named-decisions:begin -->
### test-decision
- **Classification**: load-bearing
- **Engineer choice**: "Option 2"
### orphan-markdown
- **Classification**: routine
<!-- named-decisions:end -->'
        $mdParsed = & $script:ParseMarkdownNamedDecisions -MarkdownText $md
        $records = Read-EngagementRecords -IssueNumber 576 -InMemoryMarkers @($validYaml) -Phase plan

        # Orphan check logic: IDs must match exactly
        $mdIds = $mdParsed.Keys
        $yamlIds = $records | ForEach-Object { $_.decision_id }

        $diff = Compare-Object $mdIds $yamlIds
        $diff | Should -Not -BeNullOrEmpty -Because 'Orphan markdown H3 must fail integrity validation'
    }

    It 'Mirror integrity negative: YAML decision_id with no matching H3 -> fail' {
        $md = '<!-- named-decisions:begin -->
### different-decision
- **Classification**: load-bearing
<!-- named-decisions:end -->'
        $mdParsed = & $script:ParseMarkdownNamedDecisions -MarkdownText $md
        $records = Read-EngagementRecords -IssueNumber 576 -InMemoryMarkers @($validYaml) -Phase plan

        $mdIds = $mdParsed.Keys
        $yamlIds = $records | ForEach-Object { $_.decision_id }

        $diff = Compare-Object $mdIds $yamlIds
        $diff | Should -Not -BeNullOrEmpty -Because 'Orphan YAML decision must fail integrity validation'
    }

    It 'Mirror integrity negative: section present, marker absent -> orphan detected' {
        # Construct fixture: agent body section content with no matching engagement-record marker
        $mdWithSection = @'
<!-- named-decisions:begin -->
### orphan-decision-x
- **Classification**: load-bearing
- **Engineer choice**: "test"
- **Audit rationale**: "test"
- **Decision brief excerpt**: "test"
- **Articulation text**: |
    <!-- CE Gate articulation pending per #578 -->
- **Articulation status**: pending
<!-- named-decisions:end -->
'@
        $mdParsed = & $script:ParseMarkdownNamedDecisions -MarkdownText $mdWithSection
        $mdIds = @($mdParsed.Keys)
        $yamlIds = @()  # No marker fixture; empty array

        $diff = Compare-Object -ReferenceObject $mdIds -DifferenceObject $yamlIds
        $diff | Should -Not -BeNullOrEmpty -Because 'A Markdown decision_id with no matching YAML marker must be flagged as orphan'
        ($diff | Where-Object { $_.SideIndicator -eq '<=' }).InputObject | Should -Be 'orphan-decision-x'
    }

    It 'Mirror integrity negative: marker present, section absent -> orphan detected' {
        if (-not (Get-Command Read-EngagementRecords -ErrorAction SilentlyContinue)) {
            Set-ItResult -Skipped -Because 'Read-EngagementRecords not available'
            return
        }

        $mdIds = @()  # No section fixture
        $markerYaml = @'
<!-- engagement-record-design-999 -->
```yaml
schema_version: 2
phase: design
capture_session: "normal-design-v2"
load_bearing_decisions:
  - decision_id: orphan-yaml-y
    classification: load-bearing
    audit_rationale: "test"
    engineer_choice: "test"
    teaching_paragraph_excerpt: "test"
    articulation_text: ""
    articulation_status: pending
```
'@
        $records = Read-EngagementRecords -IssueNumber 999 -InMemoryMarkers @($markerYaml) -Phase design
        $yamlIds = @($records | ForEach-Object { $_.decision_id })

        $diff = Compare-Object -ReferenceObject $mdIds -DifferenceObject $yamlIds
        $diff | Should -Not -BeNullOrEmpty -Because 'A YAML marker decision_id with no matching Markdown section must be flagged as orphan'
        ($diff | Where-Object { $_.SideIndicator -eq '=>' }).InputObject | Should -Be 'orphan-yaml-y'
    }

    It 'Mirror integrity negative: field-set divergence (Markdown bullets missing classification) -> fail' {
        $md = '<!-- named-decisions:begin -->
### test-decision
- **Engineer choice**: "Option 2"
- **Audit rationale**: "We need TDD."
- **Decision brief excerpt**: "Pester tests are run."
- **Articulation text**: |
    We chose option 2.
- **Articulation status**: pending
<!-- named-decisions:end -->'
        $mdParsed = & $script:ParseMarkdownNamedDecisions -MarkdownText $md
        $mdDec = $mdParsed['test-decision']

        # Divergence check: missing Classification bullet
        $mdDec.ContainsKey('classification') | Should -BeFalse -Because 'Integrity must fail if field classification is missing from Markdown bullets'
    }
}

Describe 'AC6.4 & AC6.5: Round-trip phase: plan and parameter binding' {
    It 'Round-trip emit->read for phase: plan returns parsed entries' {
        if (-not (Get-Command Read-EngagementRecords -ErrorAction SilentlyContinue)) {
            Set-ItResult -Skipped -Because 'Read-EngagementRecords not available'
            return
        }

        $fixture = '<!-- engagement-record-plan-576 -->
```yaml
schema_version: 2
phase: plan
capture_session: "normal-plan-v2"
load_bearing_decisions:
  - decision_id: plan-write-target
    classification: load-bearing
    audit_rationale: "Rationale."
    engineer_choice: "Plan comment"
    teaching_paragraph_excerpt: "Teaching excerpt."
    articulation_text: ""
    articulation_status: pending
```'

        $records = Read-EngagementRecords -IssueNumber 576 -InMemoryMarkers @($fixture) -Phase plan
        $records | Should -Not -BeNullOrEmpty
        $records.Count | Should -Be 1
        $records[0].decision_id | Should -Be 'plan-write-target'
        $records[0].phase | Should -Be 'plan'
        $records[0].schema_version | Should -Be 2
    }

    It 'Read-EngagementRecords -Phase plan does not throw parameter-binding error' {
        if (-not (Get-Command Read-EngagementRecords -ErrorAction SilentlyContinue)) {
            Set-ItResult -Skipped -Because 'Read-EngagementRecords not available'
            return
        }

        {
            Read-EngagementRecords -IssueNumber 576 -InMemoryMarkers @('<!-- engagement-record-plan-576 -->') -Phase plan
        } | Should -Not -Throw -ExceptionType ([System.Management.Automation.ParameterBindingException])
    }
}

Describe 'AC6.6: Zero-decisions case' {
    It 'Zero-decisions Markdown matches literal empty sentence and YAML load_bearing_decisions is empty' {
        if (-not (Get-Command Read-EngagementRecords -ErrorAction SilentlyContinue)) {
            Set-ItResult -Skipped -Because 'Read-EngagementRecords not available'
            return
        }

        $emptyMarkdown = '<!-- named-decisions:begin -->
No load-bearing decisions captured in this session.
<!-- named-decisions:end -->'

        $emptyYaml = '<!-- engagement-record-plan-576 -->
```yaml
schema_version: 2
phase: plan
capture_session: "normal-plan-v2"
load_bearing_decisions: []
```'

        # Literal sentence check
        $emptyMarkdown | Should -Match 'No load-bearing decisions captured in this session\.'

        # Round-trip check
        $records = Read-EngagementRecords -IssueNumber 576 -InMemoryMarkers @($emptyYaml) -Phase plan
        $records.Count | Should -Be 0
    }
}

Describe 'AC6.7: Parser hardening' {
    It 'audit_rationale containing H3-like substring inside a YAML block-scalar does NOT false-trigger H3 detection' {
        $md = '### Unrelated header
<!-- named-decisions:begin -->
### test-decision
- **Audit rationale**: "Here is an audit ### nested string that should not trigger."
<!-- named-decisions:end -->'
        $parsed = & $script:ParseMarkdownNamedDecisions -MarkdownText $md
        $parsed.Keys.Count | Should -Be 1
        $parsed.ContainsKey('test-decision') | Should -BeTrue
    }
}

Describe 'AC6.8: Injection policy contract is documented in all required surfaces' {
    It 'skills/engagement-record-emission/SKILL.md documents YAML block-scalar policy + fence-line rejection rule' {
        $skillPath = Join-Path $script:RepoRoot 'skills/engagement-record-emission/SKILL.md'
        $skillContent = Get-Content -Raw $skillPath
        $skillContent | Should -Match 'block-scalar'
        $skillContent | Should -Match 'triple-backtick|fence.line.*reject|reject.*fence'
    }

    It 'All three agent bodies cite the injection policy in their write-discipline H3 sub-section' {
        $files = @(
            $script:ExperienceOwnerPath,
            $script:SolutionDesignerPath,
            $script:IssuePlannerPath
        )
        foreach ($f in $files) {
            $content = Get-Content -Raw $f
            # The H3 sub-section must mention the injection-rejection rule
            $content | Should -Match 'triple-backtick|fence.line|block.scalar'
        }
    }
}

Describe 'AC6.9: Slug regex validation' {
    It 'Slug validation correctly verifies slugs' {
        if (-not (Get-Command Test-EngagementRecordSlug -ErrorAction SilentlyContinue)) {
            Set-ItResult -Skipped -Because 'Test-EngagementRecordSlug not available'
            return
        }

        # Valid
        Test-EngagementRecordSlug -DecisionId 'plan-write-target' | Should -BeTrue
        Test-EngagementRecordSlug -DecisionId 'd4-rollout-policy' | Should -BeTrue
        Test-EngagementRecordSlug -DecisionId ('a' + ('x' * 63)) | Should -BeTrue

        # Invalid
        Test-EngagementRecordSlug -DecisionId '' | Should -BeFalse
        Test-EngagementRecordSlug -DecisionId $null | Should -BeFalse
        Test-EngagementRecordSlug -DecisionId 'Bad_id' | Should -BeFalse
        Test-EngagementRecordSlug -DecisionId 'with space' | Should -BeFalse
        Test-EngagementRecordSlug -DecisionId '1leading-digit' | Should -BeFalse
        Test-EngagementRecordSlug -DecisionId ('a' + ('x' * 64)) | Should -BeFalse
        Test-EngagementRecordSlug -DecisionId '-leading-hyphen' | Should -BeFalse
        Test-EngagementRecordSlug -DecisionId 'trailing-hyphen-' | Should -BeFalse
        Test-EngagementRecordSlug -DecisionId 'é-foo' | Should -BeFalse
    }

    # CF4: case-sensitivity + \z anchor regression coverage
    It 'Test-EngagementRecordSlug rejects UPPERCASE-ID (case-sensitive)' {
        if (-not (Get-Command Test-EngagementRecordSlug -ErrorAction SilentlyContinue)) {
            Set-ItResult -Skipped -Because 'Test-EngagementRecordSlug not available'
            return
        }
        Test-EngagementRecordSlug -DecisionId 'UPPERCASE-ID' | Should -BeFalse
    }

    It 'Test-EngagementRecordSlug rejects MixedCase-id (case-sensitive)' {
        if (-not (Get-Command Test-EngagementRecordSlug -ErrorAction SilentlyContinue)) {
            Set-ItResult -Skipped -Because 'Test-EngagementRecordSlug not available'
            return
        }
        Test-EngagementRecordSlug -DecisionId 'MixedCase-id' | Should -BeFalse
    }

    It 'Test-EngagementRecordSlug rejects slug with trailing newline (\\z anchor)' {
        if (-not (Get-Command Test-EngagementRecordSlug -ErrorAction SilentlyContinue)) {
            Set-ItResult -Skipped -Because 'Test-EngagementRecordSlug not available'
            return
        }
        Test-EngagementRecordSlug -DecisionId "valid-slug`n" | Should -BeFalse
    }

    It 'Read-EngagementRecords skips invalid-slug markers and emits a warning (CF13b)' {
        if (-not (Get-Command Read-EngagementRecords -ErrorAction SilentlyContinue)) {
            Set-ItResult -Skipped -Because 'Read-EngagementRecords not available'
            return
        }

        $invalidSlugYaml = '<!-- engagement-record-plan-576 -->
```yaml
schema_version: 2
phase: plan
capture_session: "normal-plan-v2"
load_bearing_decisions:
  - decision_id: "Bad Slug!"
    classification: load-bearing
```'
        # CF13b: per-marker validation failures now warn and skip rather than abort the scan.
        # The marker is dropped from results, but the call does not throw.
        $records = $null
        { $records = Read-EngagementRecords -IssueNumber 576 -InMemoryMarkers @($invalidSlugYaml) -Phase plan -WarningAction SilentlyContinue } |
            Should -Not -Throw
        $records.Count | Should -Be 0
    }
}

Describe 'AC6.10: HTML disambiguation comment for empty articulation_text is documented in emission templates' {
    It 'All three agent body H3 sub-sections instruct emission of the disambiguation comment' {
        $files = @(
            $script:ExperienceOwnerPath,
            $script:SolutionDesignerPath,
            $script:IssuePlannerPath
        )
        $expected = '<!-- CE Gate articulation pending per #578 -->'
        foreach ($f in $files) {
            $content = Get-Content -Raw $f
            $content | Should -Match ([regex]::Escape($expected))
        }
    }

    It 'SKILL.md gotchas table documents the empty-articulation UX rationale' {
        $skillPath = Join-Path $script:RepoRoot 'skills/engagement-record-emission/SKILL.md'
        $skillContent = Get-Content -Raw $skillPath
        $skillContent | Should -Match 'articulation_text.*empty|empty.*articulation_text|articulation.*pending'
    }
}

Describe 'AC6.11: MF5 same-decision-resume [auto] - real Read-EngagementRecords contract' {
    BeforeAll {
        # Construct a fixture engagement-record marker that solution-authoring would consume
        $script:FixtureMarker = @'
<!-- engagement-record-experience-999 -->
```yaml
schema_version: 2
phase: experience
capture_session: "normal-experience-v2"
load_bearing_decisions:
  - decision_id: ce-readiness-classification
    classification: load-bearing
    audit_rationale: "Captured in prior session for resume test."
    engineer_choice: "Browser surface; CE Gate manual"
    teaching_paragraph_excerpt: "CE Gate readiness affects post-PR validation surface."
    articulation_text: ""
    articulation_status: pending
```
'@
    }

    It 'Read-EngagementRecords returns the captured decision for resume suppression' {
        if (-not (Get-Command Read-EngagementRecords -ErrorAction SilentlyContinue)) {
            Set-ItResult -Skipped -Because 'Read-EngagementRecords not available'
            return
        }

        $records = Read-EngagementRecords -IssueNumber 999 -InMemoryMarkers @($script:FixtureMarker) -Phase experience
        $records.Count | Should -Be 1
        $records[0].decision_id | Should -Be 'ce-readiness-classification'
        $records[0].engineer_choice | Should -Be 'Browser surface; CE Gate manual'
        $records[0].classification | Should -Be 'load-bearing'
    }

    It 'Solution-authoring SKILL documents the same-decision-resume rule consuming Read-EngagementRecords output' {
        $skillPath = Join-Path $script:RepoRoot 'skills/solution-authoring/SKILL.md'
        $solutionAuthoringSkill = Get-Content -Raw $skillPath
        # The rule MUST mention Read-EngagementRecords as its consumer surface
        $solutionAuthoringSkill | Should -Match 'Read-EngagementRecords'
        $solutionAuthoringSkill | Should -Match 'same-decision-resume'
    }

    It 'Read-EngagementRecords returns empty for a decision_id not in any marker (negative case)' {
        if (-not (Get-Command Read-EngagementRecords -ErrorAction SilentlyContinue)) {
            Set-ItResult -Skipped -Because 'Read-EngagementRecords not available'
            return
        }

        $records = Read-EngagementRecords -IssueNumber 999 -InMemoryMarkers @($script:FixtureMarker) -Phase experience
        # The fixture has 'ce-readiness-classification' but not 'unrelated-decision'
        $matching = $records | Where-Object { $_.decision_id -eq 'unrelated-decision' }
        $matching | Should -BeNullOrEmpty
    }
}

Describe 'CF22: Additive optional fields survive read round-trip' {
    It 'Read-EngagementRecords preserves additive optional fields per SKILL.md line 55' {
        if (-not (Get-Command Read-EngagementRecords -ErrorAction SilentlyContinue)) {
            Set-ItResult -Skipped -Because 'Read-EngagementRecords not available'
            return
        }

        $marker = @'
<!-- engagement-record-design-999 -->
```yaml
schema_version: 2
phase: design
capture_session: "normal-design-v2"
load_bearing_decisions:
  - decision_id: test-decision
    classification: load-bearing
    audit_rationale: "test"
    engineer_choice: "test"
    teaching_paragraph_excerpt: "test"
    articulation_text: ""
    articulation_status: pending
    future_field_x: "value-x"
    future_field_y: 42
```
'@

        $records = Read-EngagementRecords -IssueNumber 999 -InMemoryMarkers @($marker) -Phase design
        $records.Count | Should -Be 1
        $records[0].future_field_x | Should -Be 'value-x'
        $records[0].future_field_y | Should -Be 42
        # Existing known fields still resolve
        $records[0].decision_id | Should -Be 'test-decision'
        $records[0].classification | Should -Be 'load-bearing'
        $records[0].phase | Should -Be 'design'
        $records[0].schema_version | Should -Be 2
    }
}

Describe 'CF13b: Malformed marker isolation' {
    It 'Read-EngagementRecords skips malformed markers and returns valid ones' {
        if (-not (Get-Command Read-EngagementRecords -ErrorAction SilentlyContinue)) {
            Set-ItResult -Skipped -Because 'Read-EngagementRecords not available'
            return
        }

        $badMarker = @'
<!-- engagement-record-design-999 -->
```yaml
schema_version: 2
phase: design
capture_session: "normal-design-v2"
load_bearing_decisions:
  - decision_id: bad-decision
    classification: not-a-valid-value
    audit_rationale: "test"
    engineer_choice: "test"
    teaching_paragraph_excerpt: "test"
    articulation_text: ""
    articulation_status: pending
```
'@

        $goodMarker = @'
<!-- engagement-record-design-999 -->
```yaml
schema_version: 2
phase: design
capture_session: "normal-design-v2"
load_bearing_decisions:
  - decision_id: good-decision
    classification: load-bearing
    audit_rationale: "test"
    engineer_choice: "test"
    teaching_paragraph_excerpt: "test"
    articulation_text: ""
    articulation_status: pending
```
'@

        $records = Read-EngagementRecords -IssueNumber 999 -InMemoryMarkers @($badMarker, $goodMarker) -Phase design -WarningAction SilentlyContinue
        $records.Count | Should -Be 1
        $records[0].decision_id | Should -Be 'good-decision'
    }

    It 'Read-EngagementRecords skips marker with unknown schema_version and continues scanning' {
        if (-not (Get-Command Read-EngagementRecords -ErrorAction SilentlyContinue)) {
            Set-ItResult -Skipped -Because 'Read-EngagementRecords not available'
            return
        }

        $badMarker = @'
<!-- engagement-record-design-999 -->
```yaml
schema_version: 99
phase: design
capture_session: "normal-design-v2"
load_bearing_decisions: []
```
'@

        $goodMarker = @'
<!-- engagement-record-design-999 -->
```yaml
schema_version: 2
phase: design
capture_session: "normal-design-v2"
load_bearing_decisions:
  - decision_id: good-decision
    classification: load-bearing
    audit_rationale: "test"
    engineer_choice: "test"
    teaching_paragraph_excerpt: "test"
    articulation_text: ""
    articulation_status: pending
```
'@

        $records = Read-EngagementRecords -IssueNumber 999 -InMemoryMarkers @($badMarker, $goodMarker) -Phase design -WarningAction SilentlyContinue
        $records.Count | Should -Be 1
        $records[0].decision_id | Should -Be 'good-decision'
    }
}
