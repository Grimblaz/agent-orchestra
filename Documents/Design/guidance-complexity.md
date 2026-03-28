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

---

## Implementation Phases

### Phase 1 — Data-Independent (Ships With This PR)

- **D1**: `measure-guidance-complexity.ps1` + `.github/config/guidance-complexity.json` + quick-validate integration
- **D2**: Compression trigger wiring in Process-Review §4.9 (ceiling flag, advisory guidance)
- **D6**: Extraction criteria documented; Process-Review §4.8 trigger widened to calibration-inclusive mode; invocation monitoring added

### Phase 2 — Data-Dependent (Ships After Calibration Matures)

- **D3**: Compound-signal retirement (requires `prosecution_depth_state` to exist in calibration data)
- **D4**: Structural Prevention Gate in §4.9 (requires stabilized Sub C pipeline)
- **D5**: Consolidation event tracking + regression monitoring (requires consolidation events to exist)

**Rationale for phasing**: Phase 1 mechanisms work purely from file analysis and structural rules — no calibration data needed. Phase 2 mechanisms depend on sufficient calibration history (~20+ effective findings per category for depth transitions to activate). Shipping Phase 1 first allows the system to start capping complexity immediately while calibration data accumulates.

---

## Phase 2 Readiness Criteria

Phase 2 implementation is not yet warranted. The trigger for beginning Phase 2 implementation is:

1. `prosecution_depth_state` exists in `.copilot-tracking/calibration/review-data.json` (currently absent — only 4 calibration entries exist, ~20 effective count per category needed for depth transitions)
2. At least one category has `recommendation: skip` or `recommendation: light` (compound-signal confirmation of a sustained low-defect-rate pattern)
3. At least one `consolidation event` candidate can be identified from calibration data

These conditions are tracked via the follow-up issue created alongside this PR. Implementation should not begin until all three criteria are met.

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
| `.github/scripts/aggregate-review-scores.ps1` | Modified — `prevention_level:`, `retirement_candidates:`, `consolidation_events[]` | 2 |
| `Documents/Archive/retired-rules/` | New convention — archive for retired rules with restoration metadata | 2 |

**Net-new artifacts capped**: 1 script + 1 config (Phase 1). Phase 2 modifies existing files only (plus archive convention).

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
- Phase 2 readiness criteria documented and tracked via follow-up issue

**Phase 2 (future PR, requires calibration maturity):**

- Compound-signal retirement (D3) — requires `prosecution_depth_state` in calibration data
- Structural Prevention Gate in §4.9 (D4) — requires stabilized Sub C pipeline
- Consolidation event tracking + regression monitoring (D5) — requires consolidation events to exist
