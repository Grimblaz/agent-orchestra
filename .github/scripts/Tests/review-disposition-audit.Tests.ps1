#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
#Requires -Modules @{ ModuleName = 'powershell-yaml'; ModuleVersion = '0.4.0' }

BeforeAll {
    Import-Module powershell-yaml -MinimumVersion 0.4.0

    # Resolve repo root from the test file's location: Tests/ -> scripts/ -> .github/ -> repo root
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    # Verify expected layout; fall back to git if layout doesn't look right
    if (-not (Test-Path (Join-Path $script:RepoRoot '.github'))) {
        $gitRoot = (git rev-parse --show-toplevel 2>$null)
        if ($gitRoot) { $script:RepoRoot = $gitRoot.Trim().Replace('/', '\') }
    }

    $script:LibDir              = Join-Path $script:RepoRoot '.github/scripts/lib'
    $script:ValidatorScript     = Join-Path $script:LibDir 'review-dispositions-validator-core.ps1'
    $script:GateReconciliation  = Join-Path $script:LibDir 'gate-reconciliation-core.ps1'
    $script:EngagementRecord    = Join-Path $script:LibDir 'frame-engagement-record-core.ps1'
    $script:TokenSchema         = Join-Path $script:RepoRoot 'skills/solution-authoring/schemas/gate-decision-token.schema.json'
    $script:ReviewJudgeCmd      = Join-Path $script:RepoRoot 'commands/orchestra-review-judge.md'
    $script:ReviewCmd           = Join-Path $script:RepoRoot 'commands/orchestra-review.md'
    $script:ReviewJudgmentSkill = Join-Path $script:RepoRoot 'skills/review-judgment/SKILL.md'
    $script:DesignDispositionTestFile = Join-Path $PSScriptRoot 'design-disposition-audit.Tests.ps1'

    # ── Helper: invoke review-dispositions-validator-core.ps1 in-process ─────
    # The validator uses script-scope params, so it must be invoked via & (call operator).
    # This avoids subprocess overhead and quoting issues.
    function script:Run-Validator {
        param(
            [int]      $PR     = 42,
            [string[]] $Bodies = @()
        )
        return & $script:ValidatorScript -PullRequestNumber $PR -InMemoryMarkers $Bodies
    }

}

# ─────────────────────────────────────────────────────────────────────────────
# Group 1 — review-dispositions payload schema validation
# ─────────────────────────────────────────────────────────────────────────────
Describe 'Group 1 — review-dispositions payload schema validation' {

    BeforeAll {
        # Shared valid marker body with one routine + one load-bearing entry
        $script:ValidBody42 = @'
<!-- review-dispositions-42 -->

```yaml
schema_version: 1
passes_run: [1, 2]
entries:
  - stable_finding_key: "src/auth.ts:10:null-check-a1b2c3d4"
    finding_id: F1
    pass: 1
    disposition: incorporate
    classification: routine
    disposition_rationale: "Trivial null guard aligned with existing type contract."
  - stable_finding_key: "src/auth.ts:88:token-expiry-b7c1a2f3"
    finding_id: F2
    pass: 2
    disposition: dismiss
    classification: load-bearing
    disposition_rationale: "Engineer reviewed and confirmed expiry window is intentional per spec."
```
'@
    }

    It 'AC7 positive — valid complete payload passes validator with status clean and marker_count 1' {
        $result = script:Run-Validator -PR 42 -Bodies @($script:ValidBody42)

        $result.status       | Should -Be 'clean'
        $result.marker_count | Should -Be 1
    }

    It 'AC7 negative — missing schema_version emits warning mentioning schema_version' {
        $body = @'
<!-- review-dispositions-42 -->

```yaml
passes_run: [1, 2]
entries:
  - stable_finding_key: "src/auth.ts:10:null-check-a1b2c3d4"
    pass: 1
    disposition: incorporate
    classification: routine
    disposition_rationale: "Trivial null guard."
```
'@
        $result = script:Run-Validator -PR 42 -Bodies @($body)

        $result.status | Should -Be 'findings'
        $allMessages = (@($result.findings) | ForEach-Object { $_.message }) -join "`n"
        $allMessages | Should -Match 'schema_version'
    }

    It 'empty passes_run emits warning mentioning passes_run' {
        $body = @'
<!-- review-dispositions-42 -->

```yaml
schema_version: 1
passes_run: []
entries:
  - stable_finding_key: "src/auth.ts:10:null-check-a1b2c3d4"
    pass: 1
    disposition: incorporate
    classification: routine
    disposition_rationale: "Trivial null guard."
```
'@
        $result = script:Run-Validator -PR 42 -Bodies @($body)

        $result.status | Should -Be 'findings'
        $allMessages = (@($result.findings) | ForEach-Object { $_.message }) -join "`n"
        $allMessages | Should -Match 'passes_run'
    }

    It 'invalid passes_run value (6) emits warning mentioning invalid value: 6' {
        $body = @'
<!-- review-dispositions-42 -->

```yaml
schema_version: 1
passes_run: [1, 6]
entries:
  - stable_finding_key: "src/auth.ts:10:null-check-a1b2c3d4"
    pass: 1
    disposition: incorporate
    classification: routine
    disposition_rationale: "Trivial null guard."
```
'@
        $result = script:Run-Validator -PR 42 -Bodies @($body)

        $result.status | Should -Be 'findings'
        $allMessages = (@($result.findings) | ForEach-Object { $_.message }) -join "`n"
        $allMessages | Should -Match 'invalid value: 6'
    }

    It 'AC5 negative — missing stable_finding_key emits warning mentioning stable_finding_key' {
        # Entry F2 has no stable_finding_key
        $body = @'
<!-- review-dispositions-42 -->

```yaml
schema_version: 1
passes_run: [1, 2]
entries:
  - stable_finding_key: "src/auth.ts:10:null-check-a1b2c3d4"
    finding_id: F1
    pass: 1
    disposition: incorporate
    classification: routine
    disposition_rationale: "Trivial null guard."
  - finding_id: F2
    pass: 2
    disposition: dismiss
    classification: load-bearing
    disposition_rationale: "Engineer confirmed intentional."
```
'@
        $result = script:Run-Validator -PR 42 -Bodies @($body)

        $result.status | Should -Be 'findings'
        $allMessages = (@($result.findings) | ForEach-Object { $_.message }) -join "`n"
        $allMessages | Should -Match 'stable_finding_key'
    }

    It 'invalid disposition value emits warning mentioning incorporate|dismiss|escalate' {
        $body = @'
<!-- review-dispositions-42 -->

```yaml
schema_version: 1
passes_run: [1]
entries:
  - stable_finding_key: "src/auth.ts:10:null-check-a1b2c3d4"
    pass: 1
    disposition: ignore
    classification: routine
    disposition_rationale: "Ignoring this finding."
```
'@
        $result = script:Run-Validator -PR 42 -Bodies @($body)

        $result.status | Should -Be 'findings'
        $allMessages = (@($result.findings) | ForEach-Object { $_.message }) -join "`n"
        $allMessages | Should -Match 'incorporate\|dismiss\|escalate'
    }

    It 'invalid classification emits warning mentioning load-bearing|routine' {
        $body = @'
<!-- review-dispositions-42 -->

```yaml
schema_version: 1
passes_run: [1]
entries:
  - stable_finding_key: "src/auth.ts:10:null-check-a1b2c3d4"
    pass: 1
    disposition: incorporate
    classification: medium
    disposition_rationale: "Medium classification is not valid."
```
'@
        $result = script:Run-Validator -PR 42 -Bodies @($body)

        $result.status | Should -Be 'findings'
        $allMessages = (@($result.findings) | ForEach-Object { $_.message }) -join "`n"
        $allMessages | Should -Match 'load-bearing\|routine'
    }

    It 'missing disposition_rationale emits warning mentioning disposition_rationale' {
        $body = @'
<!-- review-dispositions-42 -->

```yaml
schema_version: 1
passes_run: [1]
entries:
  - stable_finding_key: "src/auth.ts:10:null-check-a1b2c3d4"
    pass: 1
    disposition: incorporate
    classification: routine
```
'@
        $result = script:Run-Validator -PR 42 -Bodies @($body)

        $result.status | Should -Be 'findings'
        $allMessages = (@($result.findings) | ForEach-Object { $_.message }) -join "`n"
        $allMessages | Should -Match 'disposition_rationale'
    }

    It 'v2 valid payload with ac_cross_check passes validator with status clean' {
        $body = @'
<!-- review-dispositions-42 -->

```yaml
schema_version: 2
passes_run: [1, 2, 3]
entries:
  - stable_finding_key: "src/auth.ts:10:null-check-a1b2c3d4"
    finding_id: F1
    pass: 1
    disposition: incorporate
    classification: routine
    severity: medium
    stage: code-review
    disposition_rationale: "Incorporated — ac cross-check ran."
    ac_cross_check:
      file_arm: false
      term_arm: true
      result: matched-high
      ac_ref: "- the renderer must fetch `triage`-labeled issues"
      source: issue
      routed: force-accept
```
'@
        $result = script:Run-Validator -PR 42 -Bodies @($body)

        $result.status       | Should -Be 'clean'
        $result.marker_count | Should -Be 1
    }

    It 'v2 dismiss entry missing ac_cross_check at severity medium emits warning' {
        $body = @'
<!-- review-dispositions-42 -->

```yaml
schema_version: 2
passes_run: [1]
entries:
  - stable_finding_key: "src/auth.ts:10:null-check-a1b2c3d4"
    pass: 1
    disposition: dismiss
    classification: routine
    severity: medium
    disposition_rationale: "Dismissed without running AC cross-check."
```
'@
        $result = script:Run-Validator -PR 42 -Bodies @($body)

        $result.status | Should -Be 'findings'
        $allMessages = (@($result.findings) | ForEach-Object { $_.message }) -join "`n"
        $allMessages | Should -Match 'ac_cross_check'
    }

    It 'v3 dismiss entry missing ac_cross_check at severity medium emits warning' {
        $body = @'
<!-- review-dispositions-42 -->

```yaml
schema_version: 3
passes_run: [1]
entries:
  - stable_finding_key: "src/auth.ts:10:null-check-a1b2c3d4"
    pass: 1
    disposition: dismiss
    classification: routine
    severity: medium
    disposition_rationale: "Dismissed without running AC cross-check."
```
'@
        $result = script:Run-Validator -PR 42 -Bodies @($body)

        $result.status | Should -Be 'findings'
        $allMessages = (@($result.findings) | ForEach-Object { $_.message }) -join "`n"
        $allMessages | Should -Match 'ac_cross_check'
    }

    It 'v1 entry without ac_cross_check passes validator (legacy exemption)' {
        # v1 marker should NOT warn about missing ac_cross_check even for dismiss entries
        $body = @'
<!-- review-dispositions-42 -->

```yaml
schema_version: 1
passes_run: [1]
entries:
  - stable_finding_key: "src/auth.ts:10:null-check-a1b2c3d4"
    pass: 1
    disposition: dismiss
    classification: routine
    disposition_rationale: "v1 legacy dismiss without ac_cross_check."
```
'@
        $result = script:Run-Validator -PR 42 -Bodies @($body)

        # v1 exemption: this should be clean (no ac_cross_check warning for v1)
        $result.status | Should -Be 'clean'
    }

    It 'v3 entry with reviewer_source validates (status clean)' {
        $body = @'
<!-- review-dispositions-42 -->

```yaml
schema_version: 3
passes_run: [1]
entries:
  - stable_finding_key: "src/auth.ts:10:null-check-a1b2c3d4"
    pass: 1
    disposition: incorporate
    classification: routine
    disposition_rationale: "v3 entry tagged with reviewer_source."
    reviewer_source: local
```
'@
        $result = script:Run-Validator -PR 42 -Bodies @($body)

        $result.status       | Should -Be 'clean'
        $result.marker_count | Should -Be 1
    }

    It 'v3 entry without reviewer_source validates (status clean, field is optional)' {
        $body = @'
<!-- review-dispositions-42 -->

```yaml
schema_version: 3
passes_run: [1]
entries:
  - stable_finding_key: "src/auth.ts:10:null-check-a1b2c3d4"
    pass: 1
    disposition: incorporate
    classification: routine
    disposition_rationale: "v3 entry with no reviewer_source supplied."
```
'@
        $result = script:Run-Validator -PR 42 -Bodies @($body)

        $result.status       | Should -Be 'clean'
        $result.marker_count | Should -Be 1
    }

    It 'schema_version 4 emits warning mentioning schema_version (out of range)' {
        $body = @'
<!-- review-dispositions-42 -->

```yaml
schema_version: 4
passes_run: [1]
entries:
  - stable_finding_key: "src/auth.ts:10:null-check-a1b2c3d4"
    pass: 1
    disposition: incorporate
    classification: routine
    disposition_rationale: "Future version."
```
'@
        $result = script:Run-Validator -PR 42 -Bodies @($body)

        $result.status | Should -Be 'findings'
        $allMessages = (@($result.findings) | ForEach-Object { $_.message }) -join "`n"
        $allMessages | Should -Match 'schema_version'
    }

    It 'schema_version 4 error text no longer claims "1 or 2" and instead spans 1, 2, or 3' {
        $body = @'
<!-- review-dispositions-42 -->

```yaml
schema_version: 4
passes_run: [1]
entries:
  - stable_finding_key: "src/auth.ts:10:null-check-a1b2c3d4"
    pass: 1
    disposition: incorporate
    classification: routine
    disposition_rationale: "Future version."
```
'@
        $result = script:Run-Validator -PR 42 -Bodies @($body)

        $allMessages = (@($result.findings) | ForEach-Object { $_.message }) -join "`n"
        $allMessages | Should -Match 'schema_version must be 1, 2, or 3, got: 4'
    }

    It 'validator header comment documents schema_version acceptance of 1, 2, or 3 (no stale "1 or 2" text)' {
        $validatorContent = Get-Content -Path $script:ValidatorScript -Raw

        $validatorContent | Should -Match 'schema_version must be 1, 2, or 3'
        $validatorContent | Should -Not -Match 'schema_version must be 1 or 2'
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# Group 2 — gate-decision-token schema: conditional issue_number (AC9)
# ─────────────────────────────────────────────────────────────────────────────
Describe 'Group 2 — gate-decision-token schema conditional issue_number (AC9)' {

    BeforeAll {
        $script:TokenSchemaContent = Get-Content -Path $script:TokenSchema -Raw | ConvertFrom-Json
    }

    It 'AC9 — issue_number absent from top-level required array' {
        $schema = $script:TokenSchemaContent
        $schema.required | Should -Not -Contain 'issue_number'
    }

    It 'if/then/else present for review-disposition window_position' {
        $schema = $script:TokenSchemaContent

        $schema.'if'.properties.window_position.const | Should -Be 'review-disposition'
        $schema.then.required                          | Should -Contain 'pull_request_number'
        $schema.else.required                          | Should -Contain 'issue_number'
    }

    It 'pull_request_number property exists with type integer and minimum 1' {
        $schema = $script:TokenSchemaContent

        $schema.properties.pull_request_number.type    | Should -Be 'integer'
        $schema.properties.pull_request_number.minimum | Should -Be 1
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# Group 3 — enum coverage (AC enums)
# ─────────────────────────────────────────────────────────────────────────────
Describe 'Group 3 — enum coverage in ValidateSet and schema enums' {

    BeforeAll {
        $script:GateRecContent    = Get-Content -Path $script:GateReconciliation -Raw
        $script:EngRecContent     = Get-Content -Path $script:EngagementRecord   -Raw
        $script:TokenSchemaParsed = Get-Content -Path $script:TokenSchema -Raw | ConvertFrom-Json
    }

    It 'review phase present in gate-reconciliation-core ValidateSet' {
        $script:GateRecContent | Should -Match "ValidateSet\([^)]*'review'[^)]*\)"
    }

    It 'review phase present in frame-engagement-record-core ValidateSet' {
        $script:EngRecContent | Should -Match "ValidateSet\([^)]*'review'[^)]*\)"
    }

    It 'review-disposition present in gate-decision-token window_position enum' {
        $schema = $script:TokenSchemaParsed
        $schema.properties.window_position.enum | Should -Contain 'review-disposition'
    }

    It 'review present in gate-decision-token phase enum' {
        $schema = $script:TokenSchemaParsed
        $schema.properties.phase.enum | Should -Contain 'review'
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# Group 4 — separation invariant (AC8): design validator still rejects review markers
# ─────────────────────────────────────────────────────────────────────────────
Describe 'Group 4 — SMC-19/SMC-23 separation invariant (AC8)' {

    It 'design-disposition-audit structurally rejects non-design-phase-complete markers (AC8 read-only test)' {
        $designTestContent = Get-Content -Path $script:DesignDispositionTestFile -Raw

        # The design validator requires the marker to match design-phase-complete-{N}.
        # This is the SMC-19 boundary: only design-phase-complete markers are processed.
        $designTestContent | Should -Match 'design-phase-complete'

        # The rejection branch: when the marker does NOT match, an error is added.
        # The -notmatch check in Test-DesignDispositionFixture enforces this boundary.
        $designTestContent | Should -Match 'notmatch.*design-phase-complete'
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# Group 5 — Read-FindingDispositionIds PR extension (production function)
# ─────────────────────────────────────────────────────────────────────────────
Describe 'Group 5 — Read-FindingDispositionIds PR extension (production function)' {

    BeforeAll {
        # Dot-source gate-reconciliation-core.ps1 to import its function definitions
        # (including Read-FindingDispositionIds) into the test scope.
        # IssueNumber defaults to 0 after fix 1a; the main body runs but is a no-op:
        # no event-log files are present, and InMemoryMarkers is empty.
        . $script:GateReconciliation -IssueNumber 0 -Repo 'owner/repo' -GhCliPath 'gh' -InMemoryMarkers @()

        $script:RdBody42 = @'
<!-- review-dispositions-42 -->

```yaml
schema_version: 1
passes_run: [1, 2]
entries:
  - stable_finding_key: "src/auth.ts:88:token-expiry-b7c1a2f3"
    pass: 1
    disposition: incorporate
    classification: load-bearing
    disposition_rationale: "Load-bearing fix incorporated."
```
'@
    }

    It '17: returns stable_finding_key from review-dispositions-42 (production function)' {
        $result = Read-FindingDispositionIds -Issue 1 -Repo 'owner/repo' -Gh 'gh' `
            -InMem @($script:RdBody42) -PullRequestNumber 42

        $result | Should -Contain 'src/auth.ts:88:token-expiry-b7c1a2f3'
    }

    It '18: skips review-dispositions when PullRequestNumber is 0 (production function)' {
        $result = Read-FindingDispositionIds -Issue 1 -Repo 'owner/repo' -Gh 'gh' `
            -InMem @($script:RdBody42)
        # PullRequestNumber defaults to 0 — review-dispositions branch is skipped
        $result | Should -Not -Contain 'src/auth.ts:88:token-expiry-b7c1a2f3'
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# Group 6 — structural wiring and ordering tests (AC2, AC10)
# ─────────────────────────────────────────────────────────────────────────────
Describe 'Group 6 — structural wiring and ordering tests' {

    BeforeAll {
        $script:ReviewJudgeCmdContent = Get-Content -Path $script:ReviewJudgeCmd -Raw
        $script:ReviewCmdContent      = Get-Content -Path $script:ReviewCmd      -Raw
        $script:SkillContent          = Get-Content -Path $script:ReviewJudgmentSkill -Raw
    }

    It 'AC10 negative — orchestra-review-judge.md contains review-judge-produced sentinel wiring' {
        $script:ReviewJudgeCmdContent | Should -Match 'review-judge-produced'
    }

    It 'AC10 negative — orchestra-review-judge.md contains Post-judgment disposition gate reference' {
        $script:ReviewJudgeCmdContent | Should -Match 'Post-judgment disposition gate'
    }

    It 'AC10 negative — orchestra-review.md contains Post-judgment disposition gate reference' {
        # orchestra-review.md wires into the disposition gate via its Post-judgment section
        $script:ReviewCmdContent | Should -Match 'Post-judgment disposition gate'
    }

    It 'AC10 negative — orchestra-review.md references review-dispositions-{PR} atomic persistence marker' {
        # orchestra-review.md explicitly names the atomic persistence marker
        $script:ReviewCmdContent | Should -Match 'review-dispositions-\{PR\}'
    }

    It 'AC2 ordering — review-dispositions-{PR} appears before engagement-record-review-{PR} in SKILL.md Persistence section' {
        $rdIndex = $script:SkillContent.IndexOf('review-dispositions-{PR}')
        $erIndex = $script:SkillContent.IndexOf('engagement-record-review-{PR}')

        $rdIndex | Should -BeGreaterThan -1
        $erIndex | Should -BeGreaterThan -1
        $rdIndex | Should -BeLessThan $erIndex
    }
}
