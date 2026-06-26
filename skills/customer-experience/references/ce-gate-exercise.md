<!-- markdownlint-disable-file MD041 MD003 -->

# CE Gate Exercise Procedure

Extracted downstream evidence-capture procedure and the per-surface terminal-step contract for the `customer-experience` composite skill. Load this reference when exercising delegated CE scenarios, verifying named decisions, or emitting per-surface CE Gate credit rows.

## Downstream Evidence Capture At A Glance

1. Load the delegated scenarios, named decisions or design-intent statements, surface notes, and environment prerequisites.
2. Exercise each delegated scenario with the right surface tool and record `PASS`, `FAIL`, or `INCONCLUSIVE` with evidence. Keep scenario IDs when BDD is enabled.
3. Verify named decisions as `VERIFIED`, `NOT VERIFIED`, or `VIOLATED`. For orchestration-phase decisions, evaluators read the Markdown mirror inside the `engagement-record-orchestration-{ID}` comment payload (staged behavior: the `orchestration` phase emitter shipped in #577. CE Gate dual-surface reads of orchestration-phase engagement records are gated on #571. Until #571 merges, CE Gate evaluators see orchestration markers in the issue comment thread but do not actively widen their reads to consume them). For experience, design, and plan phases, continue reading the issue-body `## Named Decisions` section.
4. Do exploratory validation after scripted checks and treat it as discovery, not prosecution.
5. Return an evidence-only summary with scenario results, named-decision verification, exploratory observations, and evidence references.

## Per-Surface Terminal-Step Contract (D10 category 4, AC5)

Each CE Gate surface is evaluated independently. For each surface (`cli`, `browser`, `canvas`, `api`):

1. **Predicate evaluation**: evaluate the surface-touch predicate (`changeset.touches{Surface}Surface()`).
2. **Surface exercise or N/A**: if the predicate is true, exercise the surface and capture evidence per the Downstream Evidence Capture steps above; if false, the status is `not-applicable`.
3. **Credit emission**: call `Build-CeGateCreditRow -Surface {name}` with the evidence list and upsert the credit row into the PR-body `<!-- pipeline-metrics -->` block.

**Orchestration-failure handling** *(planned — wrapper not yet implemented)*: when the orchestration wrapper is available, a CE Gate orchestration crash after completing some surfaces but before all four will cause the wrapper to emit the remaining surfaces as `status: inconclusive` with `block_kind: orchestration` and `evidence: "orchestration crashed before surface evaluated"`, ensuring no surface is silently absent. Until the wrapper ships, surfaces not reached before a crash must be emitted manually.

Load `skills/frame-credit-emission/SKILL.md` for the full terminal-step emission contract and `Build-CeGateCreditRow` builder reference.
