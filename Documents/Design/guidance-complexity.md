# Design: Guidance Complexity Management

## Summary

Guardrail additions accumulate asymmetrically — new rules are proposed with no symmetric simplification mechanism to counterbalance growth. This design introduces directive density detection, a compression trigger, and an extraction framework to create symmetric pressure: when an agent exceeds its complexity ceiling, guardrail proposals targeting it are flagged for compression first. Delivery is phased: Phase 1 ships data-independent mechanisms (detection script, ceiling config, compression trigger); Phase 2 ships data-dependent mechanisms (compound-signal retirement, structural gate, consolidation tracking) after calibration data matures.

---

## Design Decisions

| # | Decision | Choice | Rationale |
|---|----------|--------|-----------|
| D1 | How to detect complexity | **Regex script with calibration override** — `measure-guidance-complexity.ps1` counts directive density per agent (MUST/NEVER/ALWAYS/REQUIRED/MANDATORY keywords + checklist items `- [ ]`/`- [x]`), excluding fenced code block content; soft ceilings in `.github/config/guidance-complexity.json` (committed, not gitignored); override comments (`<!-- complexity-override: {reason} -->`) for false positives; section count + nesting depth as supplemental signals. Script always exits 0 (advisory). | Automated, Pester-testable, integrates with quick-validate; soft ceilings avoid blocking deployment |
| D2 | How to trigger compression | **Complexity ceiling trigger** — when an agent exceeds its soft ceiling, guardrail proposals targeting that agent in Process-Review §4.9 are tagged `compression_required: true` with advisory guidance (does NOT block the proposal). Scoped to `agent-prompt` proposals only (instruction/skill/plan-template proposals have no per-agent ceilings). | Creates symmetric pressure: simplify before adding; advisory ensures proposals aren't silently dropped |
| D3 | What retirement means | **Consolidation + archival** — compress to general principles + examples, move specifics to `Documents/Archive/retired-rules/` with metadata (source agent, section, version range, restoration instructions). | Knowledge preserved; context reduced; rollback easy; compound-signal guard prevents premature retirement |
| D4 | How to distinguish structural vs. rule-level | **Hybrid** — script defaults `prevention_level: unknown`; Process-Review §4.9 evaluates against upstream catch hierarchy and reclassifies to `structural` or `rule-level`. | Deterministic default where possible; flexible reasoning for novel patterns |
| D5 | How to measure quality after consolidation | **Consolidation event tracking + regression threshold** — record events in calibration data; sustain rate monitoring with +10pp regression threshold; human review (not auto-rollback). | Uses existing infrastructure; regression detection is meaningful and non-destructive |
| D6 | How to extract agent sections to skills | **Skill reference stubs** — 2-3 line stub in agent ("what and when"), full procedure in skill ("how"); 4 extraction criteria defined (see [Agent-to-Skill Extraction Criteria](#agent-to-skill-extraction-criteria)); **framework only — no immediate extractions**; §4.8 gets widened trigger + monitoring to collect evidence for future extraction/retirement decision. | Framework-first; candidates emerge from monitoring data; §4.8 needs fair chance before extraction |
| D7 | Persistent over-ceiling detection | **`complexity_over_ceiling_history` write-back** — `aggregate-review-scores.ps1` gains `-ComplexityJsonPath` parameter and tracks per-agent over-ceiling history in calibration JSON; `persistent_threshold` in `guidance-complexity.json` controls extraction advisory trigger. | Enables compound-signal retirement and regression detection; requires calibration data maturity (Phase 2) |
| D8 | Tiered advisory | **Extraction replaces compression** — when an agent's `consecutive_count ≥ persistent_threshold`, §4.9 emits `extraction_recommended: true` instead of compression advisory; D8 fires exclusively (D2 suppressed when D8 fires). | Avoids repeated compression of already-compressed sections; extraction is higher-leverage when compression has been sustained |
| D9 | Agent creation complexity budget | **Convention + quick-validate gate** — new agents must not exceed 80% of `default_ceiling.max_directives` at creation time; enforced at PR time via the existing `agents_over_ceiling.Count  # should be 0` quick-validate check. | Prevents ceiling violations at agent-creation time without additional infrastructure |
| D10 | Implementation capacity gate | **CC autonomous decision rule** — when Code-Conductor begins implementing a rule-addition issue (`systemic_fix_type: agent-prompt`), it checks whether the target agent exceeds its soft ceiling (`measure-guidance-complexity.ps1`). If over ceiling, CC autonomously creates a compression prerequisite issue and blocks the rule-addition until the compression issue is closed AND the agent ≤ ceiling. Exempt: issues reducing directive count (compression, extraction, consolidation). Complements the D2/D8 advisory system with implementation-time enforcement. | Preserves D2/D8 advisory semantics; same autonomy pattern as improvement-first (§2a); no infrastructure gate required — CC is self-enforcing |

---

## Implementation Phases

### Phase 1 — Data-Independent (Ships With This PR)

- **D1**: `measure-guidance-complexity.ps1` + `.github/config/guidance-complexity.json` + quick-validate integration
- **D2**: Compression trigger wiring in Process-Review §4.9 (ceiling flag, advisory guidance)
- **D6**: Extraction criteria documented; Process-Review §4.8 trigger widened to calibration-inclusive mode; invocation monitoring added

### Phase 2 — Consolidation Monitoring & Tiered Advisory (Ships With This PR)

- **D7**: Persistent over-ceiling detection — `-ComplexityJsonPath` parameter, `complexity_over_ceiling_history` write-back, `consolidation_events[]` (`aggregate-review-scores.ps1`)
- **D8**: Tiered advisory in Process-Review §4.9 — extraction advisory replaces compression advisory when `consecutive_count >= persistent_threshold`
- **D9**: Agent Creation Complexity Budget — convention documented, enforced by existing quick-validate gate

### Phase 3 — Data-Dependent (Requires Calibration Maturity)

- **D3**: Compound-signal retirement (requires `prosecution_depth_state` to exist in calibration data)
- **D4**: Structural Prevention Gate in §4.9 (requires stabilized Sub C pipeline)
- **D5**: Consolidation event tracking + regression monitoring (requires consolidation events to exist)

**Rationale for phasing**: Phase 1 mechanisms work purely from file analysis and structural rules — no calibration data needed. Phase 2 activates consolidation monitoring and tiered advisory once Phase 1 infrastructure is deployed. Phase 3 mechanisms depend on sufficient calibration history (~20+ effective findings per category for depth transitions to activate). Shipping Phase 1 first allows the system to start capping complexity immediately while calibration data accumulates.

---

## Phase 2 Readiness Criteria

Phase 2 implementation is **complete** (issue #213, see Phase 2 section below). The original readiness criteria that triggered Phase 2 work were:

1. `prosecution_depth_state` exists in `.copilot-tracking/calibration/review-data.json` (was absent at Phase 2 inception — only 4 calibration entries existed; ~20 effective per category needed for depth transitions)
2. At least one category has `recommendation: skip` or `recommendation: light` (compound-signal confirmation of a sustained low-defect-rate pattern)
3. At least one `consolidation event` candidate can be identified from calibration data

These conditions were met and tracked via issue #213, which implements Phase 2. See the Phase 2 section below for implementation details.

---

## Agent-to-Skill Extraction Criteria

Per D6, a procedural agent section is a candidate for extraction to a skill when ALL four criteria are met:

1. **Explicit skip conditions** — the section already has "skip in subagent mode X" guards (demonstrates it's not needed in all contexts)
2. **Self-contained workflow** — the section can be moved without breaking general agent behavior or other sections
3. **No general-behavior influence** — the section does not need to influence the agent's default reasoning (it's purely a bounded procedure)
4. **Low invocation frequency** — monitoring data shows the section is triggered infrequently relative to the number of Process-Review invocations

**Current status**: No sections meet all four criteria yet. Process-Review §4.8 satisfies criteria 1–3 but lacks monitoring data (#4). Widened trigger + monitoring will provide the data needed for a future extraction/retirement decision.

---

## Rule Compression Approach

When an agent exceeds its directive ceiling, consolidate related rules into general principles with worked examples rather than continuing to accumulate specific checks.

**Steps**:

1. **Identify the shared principle** — what do the N specific rules have in common? Name the underlying principle broadly enough to apply to novel cases the specific rules never anticipated.
2. **Write the principle** — state it as a single clear sentence or short paragraph.
3. **Add one worked example** — show the canonical application in a brief inline example block.
4. **Remove the specific rules** — replace them with the principle + example. Verify `Pester` suite and quick-validate still pass.

**Quality check**: After compression, monitor the sustain rate in affected categories (per D5, Phase 2) to confirm quality is maintained. Regression beyond the +10pp threshold triggers human review.

---

## Complexity Ceiling Configuration

Config file at `.github/config/guidance-complexity.json`. Schema:

```json
{
  "version": 1,
  "ceilings": {
    "{agent-filename}.agent.md": { "max_directives": N }
  },
  "default_ceiling": { "max_directives": N }
}
```

**Initial ceiling values** are set above current agent directive counts so no agents trigger on day one (advisory, zero false triggers at deployment). Ceilings are tunable as the system is used.

### Ceiling Management

**Rationale for the initial buffer**: The initial ceiling includes a ~50-unit buffer above current agent directive counts. This ensures zero false triggers at deployment while establishing a measurement baseline for what "normal" directive density looks like across agents.

**Tightening criteria**: Once the system has been operating for several Process-Review cycles, consider reducing the ceiling when:

- 3 or more Process-Review cycles have completed with no agent exceeding 80% of the ceiling
- Calibration data shows sustain rates are stable (no regression after recent changes)
- At least one category has reached `recommendation: skip` or `recommendation: light` depth

When those conditions are met, reduce the ceiling by 10 directives and reassess after the next 3 cycles. Reassess annually with accumulated calibration data to keep ceilings meaningful.

**Responsibility**: Ceiling management is the operator's responsibility, guided by Phase 2 monitoring data (issue #213). The script is advisory-only and will not automatically tighten ceilings.

**Override mechanism**: Lines containing `<!-- complexity-override: {reason} -->` are excluded from directive counting. Use when a section legitimately needs many directives and compression is not appropriate.

---

## System Touchpoints

| Artifact | Change | Phase |
|---|---|---|
| `.github/scripts/measure-guidance-complexity.ps1` | New — directive density counting script | 1 |
| `.github/config/guidance-complexity.json` | New — soft ceilings config per agent (committed) | 1 |
| `copilot-instructions.md` (Quick-validate) | Modified — add D1 script to pre-merge check list | 1 |
| `Process-Review.agent.md` §4.7 | Modified — invoke `measure-guidance-complexity.ps1` in run-scripts phase | 1 |
| `Process-Review.agent.md` §4.8 | Modified — widen trigger to calibration-inclusive mode + monitoring note | 1 |
| `Process-Review.agent.md` §4.9 | Modified — `compression_required` flag when ceiling exceeded | 1 |
| `.github/scripts/aggregate-review-scores.ps1` | Modified — `-ComplexityJsonPath` parameter, `complexity_over_ceiling_history` write-back, `extraction_agents:` output, `consolidation_events[]` | 2 |
| `Documents/Archive/retired-rules/` | New convention — archive for retired rules with restoration metadata | 2 |

**Net-new artifacts capped**: 1 script + 1 config (Phase 1). Phase 2 modifies existing files only (plus archive convention).

---

---

## Phase 2 — Consolidation Monitoring & Tiered Advisory

Implements the data-dependent mechanisms from D7–D9 that require calibration history. Phase 2 activation is issue #213.

### D7 — Persistent Over-Ceiling Detection

`aggregate-review-scores.ps1` gains a `-ComplexityJsonPath` parameter (type `[string]`, optional) that receives the path to the JSON output from `measure-guidance-complexity.ps1`. When provided, the script tracks per-agent over-ceiling history in the calibration JSON under `complexity_over_ceiling_history`.

**History entry schema** (per agent filename):

```json
{
  "AgentName.agent.md": {
    "consecutive_count": 3,
    "first_observed_at": "2026-03-01T00:00:00Z",
    "last_observed_at": "2026-04-01T00:00:00Z",
    "last_pr_number": 210
  }
}
```

**Idempotency**: The `last_pr_number` field prevents re-incrementing `consecutive_count` when the aggregate script is run multiple times with the same calibration state (e.g., on model switch resume). Increment is skipped when `last_pr_number == $maxMergedPrNumber`.

**`persistent_threshold`** (authoritative source: `.github/config/guidance-complexity.json`): The consecutive-run count at which the extraction advisory fires. Default value: `3`. Read by `aggregate-review-scores.ps1` directly from the config file (not from the complexity JSON temp file) to keep the config as the single source of truth.

**`extraction_agents:` YAML output**: After processing, the aggregate script emits an `extraction_agents:` block listing every agent whose `consecutive_count >= persistent_threshold`:

```yaml
extraction_agents:
  - file: AgentName.agent.md
    consecutive_over_ceiling: 3
    persistent_threshold: 3
```

This block is consumed by §4.9 Step 1b during the same Process-Review calibration session.

### D8 — Tiered Advisory

§4.9 Step 1b now implements a two-tier advisory for `agent-prompt` proposals:

| Tier | Condition | Advisory | Proposal fields |
|------|-----------|----------|-----------------|
| **D8 — Extraction** | Agent appears in `extraction_agents:` block (consecutive_count ≥ persistent_threshold) | Extraction advisory — skill extraction recommended via `skill-creator` skill, referencing D6 criteria | `extraction_recommended: true`, `compression_required: true` |
| **D2 — Compression** | Agent in `agents_over_ceiling` but NOT in `extraction_agents:` | Compression advisory — consolidate existing rules before adding new ones | `compression_required: true`, `extraction_recommended: false` |
| None | Agent not over ceiling | No advisory | `compression_required: false`, `extraction_recommended: false` |

**Replacement rule**: The D8 extraction advisory replaces (not stacks with) D2. A single advisory fires per agent per review cycle. When D8 fires, D2 is suppressed for that agent.

**Data source for D8**: §4.9 reads the `extraction_agents:` YAML block from the §4.7 aggregate script output (printed to terminal). It does NOT read the calibration JSON or the complexity config independently during §4.9 execution.

### D9 — Agent Creation Complexity Budget

New agents should be designed to fit within the soft ceiling from the outset. This is a convention, not an automated check; the quick-validate gate (`agents_over_ceiling.Count  # should be 0`) enforces it at PR time.

**Convention**: When creating a new agent, its initial directive density should not exceed 80% of the `default_ceiling.max_directives` value in `guidance-complexity.json` (currently **102 directives** with the default ceiling of 128). This leaves headroom for guardrail additions over the agent's lifecycle before compression becomes necessary.

**Verification workflow**: After any agent addition or modification, run:

```powershell
(pwsh -NoProfile -NonInteractive -File .github/scripts/measure-guidance-complexity.ps1 | ConvertFrom-Json).agents_over_ceiling.Count  # should be 0
```

This is already part of the Quick-validate suite in `.github/copilot-instructions.md`.

### D10 — Implementation Capacity Gate

**Trigger**: When Code-Conductor begins implementing a rule-addition issue targeting an agent file (`systemic_fix_type: agent-prompt`), it checks whether the target agent currently exceeds its soft ceiling.

**Mechanism**: CC runs `measure-guidance-complexity.ps1` and inspects `agents_over_ceiling`. If the target agent appears:

1. CC uses `#tool:vscode/askQuestions` to present options — (a) "Wait — compression prerequisite for {agent} is needed" (recommended) or (b) "Override and proceed now". Do not proceed silently.
2. If waiting: CC autonomously creates a compression prerequisite issue (label: `priority: medium`)
3. Implementation of the rule-addition is blocked until the compression issue is closed **and** the script confirms the agent is ≤ ceiling

**Exemption**: Issues that reduce directive count (compression, extraction, consolidation) are exempt — no circular dependency.

**Completion signal**: Compression issue closed + script output shows target agent absent from `agents_over_ceiling`. If still over ceiling after one compression round, the pattern repeats (new compression prerequisite created).

**Override**: User override is respected — gate is CC-enforced, not infrastructure. CC notes the override in the PR body.

**Relationship to D2/D8**:

- D2 (compression advisory in §4.9) fires at retrospective time — advisory only, does not block proposals
- D8 (extraction advisory replacing D2) fires at retrospective time — advisory only
- D10 fires at implementation time — enforces capacity headroom before rule-additions land
- D10 is an enforcement mechanism complementing the D2/D8 advisory system, not a replacement. All three may fire for the same agent across different workflow stages.

**Scope**: `agent-prompt` proposals only. Instruction file targets have no per-file ceiling; §2d advisory still applies to them, but D10 does not fire.

### Consolidation Event Tracking

When an agent drops from the `complexity_over_ceiling_history` (appears below ceiling after being tracked), `aggregate-review-scores.ps1` logs a consolidation event in the calibration JSON:

```json
{
  "consolidation_events": [
    {
      "agent": "AgentName.agent.md",
      "consolidated_at": "2026-04-01T00:00:00Z",
      "at_pr_number": 215,
      "previous_consecutive": 4
    }
  ]
}
```

Consolidation events provide evidence for D5 monitoring (quality regression threshold after consolidation). They accumulate indefinitely and are not pruned by the aggregate script.

### Integration Contract

The data flow for D7/D8 in a Process-Review calibration run (§4.7):

```text
measure-guidance-complexity.ps1
   → $complexityOutput (in-memory PSCustomObject)
   → $complexityTempFile (temp JSON in $env:TEMP)
aggregate-review-scores.ps1 -ComplexityJsonPath $complexityTempFile
   → reads agents_over_ceiling from temp file
   → updates complexity_over_ceiling_history in calibration JSON (atomic write-back)
   → emits extraction_agents: block in YAML output
§4.9 Step 1b reads extraction_agents: from aggregate YAML output
   → emits D8 extraction advisory (or falls back to D2 compression advisory)
Temp file cleanup: Remove-Item $complexityTempFile
```

**Error handling**: If `measure-guidance-complexity.ps1` fails or produces non-JSON output, `$complexityTempFile = $null` and the aggregate script runs without `-ComplexityJsonPath` (backward compatible — no complexity history tracking for that run).

**`persistent_threshold` authority**: The value lives in `.github/config/guidance-complexity.json` (key: `persistent_threshold`). The aggregate script reads it via `$PSScriptRoot/../config/guidance-complexity.json`. §4.9 reads the value from the `extraction_agents:` YAML block produced by the aggregate script — §4.9 never reads the config file directly.

### Archive Convention

When a rule section is retired as part of D3 (compound-signal retirement), move its content to `Documents/Archive/retired-rules/` with restoration metadata. The directory is created on first use (no pre-creation required).

**Archived file format** (one file per retired section, filename: `{agent-slug}-{section-slug}.md`):

````markdown
# {Rule Section Name} — Archived

**Source**: `.github/agents/{AgentName}.agent.md`, section "{Section heading}"
**Archived at**: PR #{N} (merged {date})
**Version range**: Committed at PR #{first-pr} — retired at PR #{N}
**Replacement**: Compressed into `{principle name}` in `.github/agents/{AgentName}.agent.md`
**Restoration**: Revert to git tag `{tag}` or cherry-pick from commit `{sha}` to restore the original section

## Original Content

{verbatim copy of the retired section}

## Retirement Rationale

{why this section was retired: calibration data, consolidation event, compound-signal evidence}
````

**Responsibility**: Archive creation is manual (part of the consolidation workflow) and is not automated by any script.

---

## Rejected Alternatives

| Alternative | Why Rejected |
|---|---|
| Config in `.copilot-tracking/` (gitignored) | Gitignored files don't survive fresh clones; config must be committed and tracked |
| Manual compression trigger | No systematic pressure; relies on someone noticing density; doesn't create symmetric counterweight |
| Full deletion for retirement (D3) | Institutional knowledge lost; if defect recurs, re-proposed rules may be worse than originals; archival preserves knowledge with restoration path |
| §4.8 immediate extraction | New feature needs fair chance; hasn't had adequate usage data; widened trigger + monitoring provides evidence for future disposition |
| Pure time-based rule expiry | "Skip depth for 90 days" ≠ defect is gone; compound-signal model requires multiple independent confirmations |
| Complex weighted scoring for density | Over-engineered; simple directive + checklist counting with section depth supplementals provides sufficient signal |
| Blocking proposal when ceiling exceeded | Proposals might be important and urgent; advisory approach preserves human judgment; `compression_required` flag is sufficient signal |
| Compression check on non-agent targets | instruction/skill/plan-template proposals don't have per-agent ceilings; scoping to `agent-prompt` only avoids false positives |

---

## Acceptance Criteria

**Phase 1 (this PR):**

- `measure-guidance-complexity.ps1` exists and counts directive density per agent, excluding fenced code block content, with Pester test coverage
- `.github/config/guidance-complexity.json` defines soft ceilings per agent file (committed to repo, not gitignored)
- Quick-validate includes complexity check using `(..).agents_over_ceiling.Count  # should be 0` pattern
- Process-Review §4.9 references complexity ceiling and flags `compression_required: true` when ceiling exceeded (advisory only, scoped to `agent-prompt` proposals)
- Process-Review §4.8 trigger widened to run in calibration-only mode, with invocation monitoring note
- Process-Review §4.7 invokes `measure-guidance-complexity.ps1` in run-scripts phase
- Extraction criteria for agent→skill moves documented (D6 framework)
- Phase 2 readiness criteria met (issue #213); Phase 2 implemented

**Phase 2 (this PR):**

- `-ComplexityJsonPath` parameter in `aggregate-review-scores.ps1`; per-agent `complexity_over_ceiling_history` write-back to calibration JSON (D7)
- Tiered advisory in Process-Review §4.9 — extraction advisory replaces compression advisory at `persistent_threshold` (D8)
- Agent Creation Complexity Budget convention documented; quick-validate gate enforces it (D9)
- `consolidation_events[]` logged when an agent drops from over-ceiling tracking

**Phase 3 (future PR, requires calibration maturity):**

- Compound-signal retirement (D3) — requires `prosecution_depth_state` in calibration data
- Structural Prevention Gate in §4.9 (D4) — requires stabilized Sub C pipeline
- Consolidation event tracking + regression monitoring (D5) — requires consolidation events to exist

---

## Issue #212 — Remediation Results

Issue #212 applies this framework to reduce existing instruction bloat. All workstreams complete as of March 2026.

### W1a — Code-Critic §6+§7 Merge

**Directives**: 55 → 41 (25.5% reduction). **Perspectives**: 7 → 6 — §6 Documentation Script Audit and §7 merged into a unified "Script & Automation" perspective with a branching gate (`.ps1`/`.sh`/`.py`/`.yml` → script principles; `.md` with code blocks → doc-audit sub-routing). Category taxonomy preserved at 7 values.

### W1b — Code-Review-Response Restructuring

**Lines**: 476 → 383 (19.5% reduction; target ≥15%). Added `## Enforcement Gates` reference section consolidating AC enforcement, categorization, and effort estimation from 3+ scattered definitions each to single authoritative definitions with inline triggers.

### W2 — Process-Review Skill Extraction

Extracted "Common Scenarios" section (5 workflows) from `Process-Review.agent.md` to `.github/skills/process-troubleshooting/SKILL.md`. Process-Review retains an ~11-line stub with symptom-keyword triggers. Skill count: 14 → 15.

### W3 — Structural Prevention

| Workstream | Artifact | Outcome |
|---|---|---|
| W3a | `.github/config/PSScriptAnalyzerSettings.psd1` | 6 rules suppressed with documented rationale; 9 scripts remediated; 0 violations remain |
| W3b | `.github/scripts/Tests/script-safety-contract.Tests.ps1` | 3 contract tests: `.Clone()` prohibition, Invoke-Expression/iex prohibition, `$knownCategories` dual-definition |
| W3c | `copilot-instructions.md` quick-validate | PSScriptAnalyzer conditional check added |

### W4 — Backlog Triage

All 18 backlog issues received triage comments with classification (ship-as-is, wait-for-compression, structural candidate, or cross-linked batch) and rationale.
