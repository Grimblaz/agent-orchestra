# Agent Audit for Issue #369 — Claude Phase 1 Upstream Agents

Audit of `Experience-Owner`, `Solution-Designer`, and `Issue-Planner` agent bodies to classify every section as one of:

- **identity** — keep verbatim in the agent body (personality, role, pipeline, boundaries)
- **methodology→{skill}** — already covered by a skill; collapse to a one-line skill pointer
- **platform-specific** — Copilot-only wording (e.g., `#tool:vscode/askQuestions`, `vscode/memory`); move to `platforms/copilot.md` and mirror Claude-native invocation in `platforms/claude.md`
- **orphan→{skill}** — methodology NOT currently in any skill; extend the named skill to absorb it, then collapse to a pointer
- **dead** — rot or duplicated-by-another-clause; delete

The audit covers 100% of lines in all three agent files.

---

## Coverage verification (grep pass)

Claims made by this audit about skill coverage were verified by reading the named skill files:

- `skills/customer-experience/SKILL.md` — upstream framing, scenario drafting, CE evidence capture ✓
- `skills/design-exploration/SKILL.md` — options, trade-offs, testing scope, design payload ✓
- `skills/plan-authoring/SKILL.md` — discovery, draft, stress-test preparation, context compaction ✓
- `skills/provenance-gate/SKILL.md` — three-question cold-pickup gate + marker recording ✓
- `skills/safe-operations/SKILL.md` — issue creation (§2), priority labels, dedup ✓
- `skills/bdd-scenarios/SKILL.md` — G/W/T, S-IDs, `[auto]`/`[manual]` classification ✓
- `skills/adversarial-review/SKILL.md` — prosecution, defense, design-challenge, product-alignment ✓

---

## Experience-Owner.agent.md (190 lines)

| Lines   | Section                             | Classification                  | Notes                                                                                          |
| ------- | ----------------------------------- | ------------------------------- | ---------------------------------------------------------------------------------------------- |
| 1–43    | Frontmatter (tools, handoffs)       | platform-specific               | Copilot-only: `vscode/askQuestions`, `browser/*`, handoffs schema. Claude shell omits.         |
| 45      | Identity hook                       | identity                        | Keep.                                                                                          |
| 47      | Session-startup trigger             | identity (required first line)  | Keep verbatim — D12 session-trigger contract.                                                  |
| 49–55   | Core Principles                     | identity                        | Keep.                                                                                          |
| 57–75   | Overview, When to use, Pipeline     | identity                        | Keep.                                                                                          |
| 77–83   | Process (provenance-gate loading)   | methodology→`provenance-gate`   | Replace 7 lines with a one-line pointer.                                                       |
| 85–93   | Questioning Policy (Mandatory)      | platform-specific               | `#tool:vscode/askQuestions` is Copilot wording; Claude uses `AskUserQuestion`. Move to platforms. |
| 95–101  | GitHub Setup (branch creation)      | methodology (trivial, inline)   | 3 lines, duplicated across all 3 agents. Keep minimal inline — not worth a skill.              |
| 103–110 | Safe-Operations Compliance          | methodology→`safe-operations`   | `safe-operations` §2 covers dedup, priority labels, creation flow. Collapse to pointer.        |
| 112–118 | Upstream Phase: Customer Framing    | methodology→`customer-experience` + `bdd-scenarios` | Already loaded via skill pointer; keep the 2-line load statement, drop the in-body expansion. |
| 120–128 | Hub/Consumer Classification Gate    | **orphan→`customer-experience`** | Duplicated with Solution-Designer. Extend `customer-experience` with a short "Hub/Consumer Gate" section. |
| 130–148 | Update Issue + completion marker    | identity (agent-specific contract) | Marker name is agent-unique. Keep.                                                             |
| 150–161 | Upstream Completion Gate            | identity (agent-specific checklist) | Keep. Agent-scoped durable-artifact hard stop.                                                 |
| 163–173 | Downstream Phase: CE Evidence       | methodology→`customer-experience` | Already loaded via skill pointer; keep 2-line load statement.                                 |
| 175–180 | Graceful Degradation                | identity                        | Agent-specific failure mode (`⚠️ CE Gate blocked`). Keep.                                     |
| 182–186 | Boundaries                          | identity                        | Keep.                                                                                          |
| 188–190 | Activation footer                   | platform-specific               | `@experience-owner` is Copilot syntax. Claude uses `/experience` slash command or agent name.  |

**Projected post-refactor line count**: ~70 lines (down from 190).

---

## Solution-Designer.agent.md (188 lines)

| Lines   | Section                             | Classification                 | Notes                                                                                          |
| ------- | ----------------------------------- | ------------------------------ | ---------------------------------------------------------------------------------------------- |
| 1–38    | Frontmatter (tools, handoffs)       | platform-specific              | Copilot tool list + handoffs. Claude shell omits.                                              |
| 40      | Identity hook                       | identity                       | Keep.                                                                                          |
| 42      | Session-startup trigger             | identity (required first line) | Keep verbatim.                                                                                 |
| 44–50   | Core Principles                     | identity                       | Keep.                                                                                          |
| 52–62   | Overview, When to use, Pipeline     | identity                       | Keep.                                                                                          |
| 64–70   | Process (provenance-gate)           | methodology→`provenance-gate`  | Collapse to pointer.                                                                           |
| 72–80   | Questioning Policy (Mandatory)      | platform-specific              | Same as EO. Move to platforms.                                                                 |
| 82–88   | Stage 1: GitHub Setup               | methodology (trivial, inline)  | Duplicated. Keep minimal.                                                                      |
| 90–94   | Stage 2: Design Exploration         | methodology→`design-exploration` | Already a pointer-only section. Keep.                                                          |
| 96–104  | Hub/Consumer Classification Gate    | **orphan→`customer-experience`** | Same gate as EO. Extend `customer-experience` once; both agents point to it.                  |
| 106–135 | **Adversarial Design Challenge**    | **orphan→`design-exploration`** | 3-pass prosecution-only (no defense/judge), non-blocking. `adversarial-review` has design-challenge pass shapes but not the 3-pass orchestration. Extend `design-exploration` with a "Design Challenge (3-pass, non-blocking)" section. |
| 137–154 | Stage 3: Update Issue + marker      | identity (agent-specific)      | Marker name + durable-record contract. Keep.                                                   |
| 156–170 | Completion Gate                     | identity (agent-specific)      | Keep.                                                                                          |
| 172–176 | Boundaries                          | identity                       | Keep.                                                                                          |
| 180–184 | Documentation Maintenance           | identity (agent boundary)      | 3-line pointer to Doc-Keeper. Keep.                                                            |
| 186–188 | Activation footer                   | platform-specific              | Move to platforms.                                                                             |

**Projected post-refactor line count**: ~70 lines (down from 188).

---

## Issue-Planner.agent.md (274 lines)

| Lines   | Section                             | Classification                  | Notes                                                                                          |
| ------- | ----------------------------------- | ------------------------------- | ---------------------------------------------------------------------------------------------- |
| 1–23    | Frontmatter                         | platform-specific               | Copilot tool list + PR extension refs. Claude shell omits.                                     |
| 25      | Identity hook                       | identity                        | Keep.                                                                                          |
| 27      | Session-startup trigger             | identity (required first line)  | Keep verbatim.                                                                                 |
| 29–35   | Core Principles                     | identity                        | Keep.                                                                                          |
| 37–42   | `<rules>` block                     | identity / platform-specific    | Rule 2 references `#tool:vscode/askQuestions`. Generalize wording in body; move tool-name to platforms. |
| 44–50   | Process (provenance-gate)           | methodology→`provenance-gate`   | Collapse to pointer.                                                                           |
| 52–54   | `<workflow>` opening                | dead (redundant wrapper)        | The `<workflow>` XML tag adds nothing. Remove tag; keep section headings.                      |
| 55–65   | 1. GitHub Setup                     | methodology (trivial, inline)   | Duplicated. Keep minimal.                                                                      |
| 67–75   | 2. Discovery                        | methodology→`plan-authoring`    | Already a pointer section. Keep as-is but drop Copilot-specific `#tool:agent/runSubagent`.     |
| 77–84   | 3. Alignment                        | methodology→`plan-authoring`    | Collapse — plan-authoring covers alignment workflow.                                           |
| 86–111  | 4. Design (plan content rules)      | **orphan→`plan-authoring`**     | Many rules not in skill: deferral handling, retrospective, migration rule trigger, per-step validation commands, CE Gate rules. Extend `plan-authoring` draft section. |
| 112–139 | BDD Scenario Classification (inline) | methodology→`bdd-scenarios`    | The `bdd-scenarios` skill explicitly accepts this duplication ("if you update one, update the other"). Keep the short rubric in-body as deliberate duplication. |
| 141–148 | Stress-test orchestration           | methodology→`plan-authoring`    | Already in skill. Collapse to pointer.                                                         |
| 150–155 | Defense + judge + post-judge reconciliation | **orphan→`plan-authoring`** | `plan-authoring` mentions "defense and judge passes" but not the post-judge reconciliation protocol. Extend skill. |
| 157–173 | **Plan Approval Prompt Format** (decision card) | **orphan→`plan-authoring`** | `Change`/`No change`/`Trade-off`/`Areas` decision card is not in any skill. Extend `plan-authoring`. |
| 175–191 | 5. Refinement                       | methodology→`plan-authoring`    | Already covered. Collapse to pointer.                                                          |
| 193–216 | 6. Persist Plan                     | platform-specific               | `vscode/memory` + `/memories/session/plan-issue-{id}.md` is Copilot-specific. Claude uses conversation state (no equivalent durable session-memory tool). Move to platforms; Claude version persists only via GitHub issue comment marker. |
| 217     | `</workflow>` close                 | dead                            | Remove wrapper.                                                                                |
| 219–229 | Context Management                  | methodology→`plan-authoring`    | Already in skill. Collapse to pointer.                                                         |
| 231–274 | `<plan_style_guide>`                | **orphan→`plan-authoring`**     | The plan-markdown template header + the long rule list (agent file insertion strategies, migration-type, removal steps, cross-file constants, multi-tier statistical output, new-section ordering, security-sensitive carve-out) is NOT in `plan-authoring`. Extend skill with a "Plan Style Guide" section. Keep a short pointer in-body. |

**Projected post-refactor line count**: ~100 lines (down from 274). Larger than EO/SD because BDD rubric duplication is deliberate and Plan Approval Prompt Format is invoked often.

---

## Cross-agent patterns

**Duplicated and consolidatable:**

- Session-startup trigger line — already identical across all 3. ✓
- Provenance-gate Process block — identical across all 3. Skill pointer suffices everywhere.
- GitHub Setup (branch creation) — 3-line trivial duplicate. Keep inline; no skill worth creating.
- Questioning Policy — same wording across all 3. Move to `platforms/copilot.md` once; the policy IS the platform (what tool to call).
- Hub/Consumer Classification Gate — present in EO and SD. Extend `customer-experience` once.

**Claude-native platform notes** (for `platforms/claude.md` of each skill / agent shell):

- `#tool:vscode/askQuestions` → `AskUserQuestion` tool
- `#tool:agent/runSubagent` → `Agent` tool with appropriate `subagent_type`
- `github/*` MCP → `gh` CLI (D7 decision)
- `vscode/memory` → Claude has no equivalent persistent session-memory tool; persistence falls back to GitHub issue comment markers, which Issue-Planner already supports via `<!-- plan-issue-{ID} -->`

---

## Required skill extensions (Phase 0.2 backlog)

1. **`customer-experience`** — add "Hub/Consumer Classification Gate" section covering language-agnostic hub rule and redirect paths to `examples/{stack}/architecture-rules.md`, `examples/{stack}/copilot-instructions.md`, `skills/{skill-name}/`.

2. **`design-exploration`** — add "Design Challenge (3-pass, non-blocking)" section covering the 3 prosecution calls (2 design-review passes + 1 product-alignment pass), merge/dedup rule, disposition (incorporate / dismiss / escalate), and the non-gatekeeping property distinguishing it from Issue-Planner's full pipeline.

3. **`plan-authoring`** — extend with:
   - Draft rules previously in `<plan_style_guide>`: agent-file insertion strategies, migration-type exhaustive-scan trigger, removal-step completeness grep, cross-file constants, multi-tier statistical output gating, new-section ordering, security-sensitive field carve-out.
   - Plan Approval Prompt Format decision card (`Change` / `No change` / `Trade-off` / `Areas`, conditional `Execution`).
   - Post-judge reconciliation protocol (cross-check incorporated findings against judge rulings; revert or flag `judge-rejected / user-confirmed`).
   - Plan-markdown template (the `## Plan: {Title}` / Steps / Verification / Decisions / Plan Stress-Test block).

4. **No new skills required.** GitHub Setup is too small; Adversarial Design Challenge is a design-exploration extension; decision-card is a plan-authoring extension.

---

## Projected outcomes

| Agent             | Before | After projected | Reduction |
| ----------------- | ------ | --------------- | --------- |
| Experience-Owner  | 190    | ~70             | –63%      |
| Solution-Designer | 188    | ~70             | –63%      |
| Issue-Planner     | 274    | ~100            | –64%      |

After Phase 0.3, both Copilot `.agent.md` files AND the forthcoming Claude shells read the same skill bodies. Only the frontmatter + platform-specific invocation wording differ — the user's requested "consistency across both systems" is achieved by design.
