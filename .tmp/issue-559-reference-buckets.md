# Issue #559 Reference Buckets

Produced by s1 exhaustive scan (2026-05-17).
Consumed by s4 two-tier completeness gate via `.tmp/issue-559-reference-buckets-paths.txt`.

Scope-clean evidence (judge M19):
- `.github/prompts/` (5 Copilot prompt files): zero matches at scan time
- `.github/copilot-instructions.md`: zero matches at scan time

---

## update

Files modified during this sweep. After s1–s4 these paths contain new-convention
`{port}-auto-na-adapter.md` / `{port}-explicit-skip-adapter.md` references; they are
excluded from the tier-1 completeness gate to prevent false-positives on the new names.

### s1 — adapter file renames (28 files; old paths replaced by git mv)

| Old path | New path |
|---|---|
| `skills/customer-experience/adapters/auto-na-experience.md` | `skills/customer-experience/adapters/experience-auto-na-adapter.md` |
| `skills/design-exploration/adapters/auto-na-design.md` | `skills/design-exploration/adapters/design-auto-na-adapter.md` |
| `skills/plan-authoring/adapters/auto-na-plan.md` | `skills/plan-authoring/adapters/plan-auto-na-adapter.md` |
| `skills/implementation-discipline/adapters/auto-na-implement-code.md` | `skills/implementation-discipline/adapters/implement-code-auto-na-adapter.md` |
| `skills/test-driven-development/adapters/auto-na-implement-test.md` | `skills/test-driven-development/adapters/implement-test-auto-na-adapter.md` |
| `skills/refactoring-methodology/adapters/auto-na-implement-refactor.md` | `skills/refactoring-methodology/adapters/implement-refactor-auto-na-adapter.md` |
| `skills/documentation-finalization/adapters/auto-na-implement-docs.md` | `skills/documentation-finalization/adapters/implement-docs-auto-na-adapter.md` |
| `skills/customer-experience/adapters/auto-na-ce-gate-api.md` | `skills/customer-experience/adapters/ce-gate-api-auto-na-adapter.md` |
| `skills/customer-experience/adapters/auto-na-ce-gate-browser.md` | `skills/customer-experience/adapters/ce-gate-browser-auto-na-adapter.md` |
| `skills/customer-experience/adapters/auto-na-ce-gate-canvas.md` | `skills/customer-experience/adapters/ce-gate-canvas-auto-na-adapter.md` |
| `skills/customer-experience/adapters/auto-na-ce-gate-cli.md` | `skills/customer-experience/adapters/ce-gate-cli-auto-na-adapter.md` |
| `skills/customer-experience/adapters/explicit-skip-experience.md` | `skills/customer-experience/adapters/experience-explicit-skip-adapter.md` |
| `skills/design-exploration/adapters/explicit-skip-design.md` | `skills/design-exploration/adapters/design-explicit-skip-adapter.md` |
| `skills/plan-authoring/adapters/explicit-skip-plan.md` | `skills/plan-authoring/adapters/plan-explicit-skip-adapter.md` |
| `skills/implementation-discipline/adapters/explicit-skip-implement-code.md` | `skills/implementation-discipline/adapters/implement-code-explicit-skip-adapter.md` |
| `skills/test-driven-development/adapters/explicit-skip-implement-test.md` | `skills/test-driven-development/adapters/implement-test-explicit-skip-adapter.md` |
| `skills/refactoring-methodology/adapters/explicit-skip-implement-refactor.md` | `skills/refactoring-methodology/adapters/implement-refactor-explicit-skip-adapter.md` |
| `skills/documentation-finalization/adapters/explicit-skip-implement-docs.md` | `skills/documentation-finalization/adapters/implement-docs-explicit-skip-adapter.md` |
| `skills/customer-experience/adapters/explicit-skip-ce-gate-api.md` | `skills/customer-experience/adapters/ce-gate-api-explicit-skip-adapter.md` |
| `skills/customer-experience/adapters/explicit-skip-ce-gate-browser.md` | `skills/customer-experience/adapters/ce-gate-browser-explicit-skip-adapter.md` |
| `skills/customer-experience/adapters/explicit-skip-ce-gate-canvas.md` | `skills/customer-experience/adapters/ce-gate-canvas-explicit-skip-adapter.md` |
| `skills/customer-experience/adapters/explicit-skip-ce-gate-cli.md` | `skills/customer-experience/adapters/ce-gate-cli-explicit-skip-adapter.md` |
| `skills/adversarial-review/adapters/explicit-skip-review.md` | `skills/adversarial-review/adapters/review-explicit-skip-adapter.md` |
| `skills/adversarial-review/adapters/explicit-skip-post-fix-review.md` | `skills/adversarial-review/adapters/post-fix-review-explicit-skip-adapter.md` |
| `skills/plugin-release-hygiene/adapters/explicit-skip-release-hygiene.md` | `skills/plugin-release-hygiene/adapters/release-hygiene-explicit-skip-adapter.md` |
| `skills/post-pr-review/adapters/explicit-skip-post-pr.md` | `skills/post-pr-review/adapters/post-pr-explicit-skip-adapter.md` |
| `skills/process-analysis/adapters/explicit-skip-process-review.md` | `skills/process-analysis/adapters/process-review-explicit-skip-adapter.md` |
| `skills/process-retrospective/adapters/explicit-skip-process-retrospective.md` | `skills/process-retrospective/adapters/process-retrospective-explicit-skip-adapter.md` |

### s2 — Spine-Runner + plan-authoring runtime contracts

- `agents/Spine-Runner.agent.md` — line 58 predicate-detection rule (prefix→suffix); line 101 is PRESERVE-AS-SEMANTIC
- `skills/plan-authoring/SKILL.md` — planner glob workflow

### s3 — Pester test files

- `.github/scripts/Tests/frame-validate.Tests.ps1` — path hashtables, role-derivation function, glob filter, fixture paths; new count-parity assertion
- `.github/scripts/Tests/credit-row-schema-conformance.Tests.ps1` — glob filter and regex pattern
- `.github/scripts/Tests/spine-runner.Tests.ps1` — fixture path (line 504), contract-mentions regex (line 516); line 525 is PRESERVE-AS-SEMANTIC

### s4 — Reference documentation

- `Documents/Design/frame-architecture.md` — Where-to-declare table, per-port adapter table, Three-adapter-types prose; plus lines 217, 261, 311, 408, 450, 698
- `Documents/Design/hub-artifact-paths-audit.md` — adapter catalog (lines 391–394)
- `Documents/Design/hub-artifact-paths-classification.yml` — examples + notes string (lines 123–128)
- `frame/ports/process-retrospective.yaml` — inline notes text (line 8)
- `CLAUDE.md` — Senior Engineer + skill-as-adapter section (add unified predicate naming convention mention)
- `skills/adversarial-review/SKILL.md` — Frame Ports Filled By This Skill table
- `skills/customer-experience/SKILL.md` — Frame Ports Filled By This Skill table
- `skills/design-exploration/SKILL.md` — Frame Ports Filled By This Skill table
- `skills/documentation-finalization/SKILL.md` — Frame Ports Filled By This Skill table
- `skills/frame-credit-emission/SKILL.md` — line 104 ("adapter file-name prefixes" → new convention description)
- `skills/implementation-discipline/SKILL.md` — Frame Ports Filled By This Skill table
- `skills/plan-authoring/SKILL.md` — Frame Ports Filled By This Skill table + glob workflow (also s2)
- `skills/plugin-release-hygiene/SKILL.md` — Frame Ports Filled By This Skill table
- `skills/post-pr-review/SKILL.md` — Frame Ports Filled By This Skill table
- `skills/process-analysis/SKILL.md` — Frame Ports Filled By This Skill table
- `skills/process-retrospective/SKILL.md` — Frame Ports Filled By This Skill table
- `skills/refactoring-methodology/SKILL.md` — Frame Ports Filled By This Skill table
- `skills/test-driven-development/SKILL.md` — Frame Ports Filled By This Skill table

---

## preserve-as-historical

Archival files that retain old naming references for historical record.
Do not edit; exclude from both completeness gate tiers.

- `.tmp/plan-comment-559.md` — persisted plan-issue-559 GitHub comment (durable artifact)
- `.tmp/plan-559-final.md` — working plan draft (issue #559 working-tree file)
- `.tmp/plan-559-draft.md` — earlier plan draft
- `.tmp/ledger-559-prosecution.md` — prosecution ledger from adversarial pipeline
- `.tmp/ledger-559-defense.md` — defense ledger from adversarial pipeline
- `.tmp/design-complete-559.md` — design-complete artifact
- `.tmp/issue-559-body.md` — issue body snapshot
- `Documents/Decisions/0004-process-retrospective-deferred-skeleton.md` — archival decision record referencing "explicit-skip adapter" as a description, not a filename

---

## preserve-as-semantic

Files where bare-word `'auto-na'` / `'explicit-skip'` are credit-row adapter-name
identifiers (not filenames). Do not rename; exclude from tier-2 bare-word gate.

- `.github/scripts/lib/frame-credit-ledger-core.ps1` — lines 1833, 1842, 1947, 2132, 2142: `'auto-na'`/`'explicit-skip'` as credit-status identifiers and default AdapterName values
- `.github/scripts/Tests/build-deferred-port-credit-row.Tests.ps1` — `'explicit-skip'` as default AdapterName test assertion
- `.github/scripts/Tests/pipeline-entry-credit-emission.Tests.ps1` — `'-AdapterName explicit-skip'` as adapter-name semantic
- `.github/scripts/Tests/implement-credit-emission.Tests.ps1` — `'auto-na'`/`'explicit-skip'` as adapter-name semantics
- `skills/frame-credit-emission/SKILL.md` — line 125 (legacy builder adapter name `'auto-na'`), line 153 (`adapter: explicit-skip` in YAML credit-row example)
- `agents/Spine-Runner.agent.md` — line 101 credit-status prose (`auto-na` / `explicit-skip` as outcome words); line 58 is UPDATE
- `.github/scripts/Tests/spine-runner.Tests.ps1` — line 525 credit-status word match (not filename); lines 504, 516 are UPDATE

---

## pre-existing-stale

References to `auto-na-process-retrospective.md` which is intentionally non-existent
(process-retrospective has no auto-N/A adapter until #348). Path strings rewritten to
new convention (`process-retrospective-auto-na-adapter.md`) for consistency; the target
file still will not exist until #348 ships.

- `Documents/Design/hub-artifact-paths-audit.md` line 392 — `auto-na-process-retrospective.md` reference
- `Documents/Design/hub-artifact-paths-classification.yml` line 124 — `auto-na-process-retrospective.md` reference

Note: both files are already in the `update` bucket (s4); the pre-existing-stale label
identifies these specific lines within those already-updated files.
