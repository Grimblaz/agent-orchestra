# Design: Outsider-First Authoring + Newcomer-Audit Detector

## Summary

Issue #732's umbrella made agent-orchestra's human-facing prose readable to a newcomer: #749 and #750 swept the existing surface (`CLAUDE.md`, READMEs, templates) clean of unexplained insider codes. But a one-time cleanup regresses the moment the next issue or doc reintroduces the same opacity — nothing stopped an author from writing `prosecution_depth` or `SMC-20` with no definition. Issue #751 is the umbrella's last child and closes that gap with two coupled parts:

1. **Outsider-first authoring convention** — a documented default in `skills/naming-register-policy/SKILL.md`: new human-facing prose expands insider terms on first use, or uses a name that is already self-describing, and a newly coined term is introduced *with* its expansion ("grow on introduction").
2. **Newcomer-audit detector** — a minimal, deterministic PowerShell scanner (`newcomer-audit-core.ps1` + `newcomer-audit.ps1`) keyed off the existing `register.json` classification, run at two warn-only seams: before the three upstream agents post drafted prose, and during Code-Conductor's PR-creation gate over changed files.

The detector is deliberately narrow: no CI wiring, no PR annotation, no allowlist tooling — those are named as a pre-authorized spin-out trigger, not built here. This document is a durable record of what the two-register policy skill's new convention section and the shipped detector actually do, not a replay of the #751 plan or its adversarial review transcript.

## Implemented Surfaces

| Surface | Current Role |
| --- | --- |
| `skills/naming-register-policy/schemas/register.schema.json` | Adds the optional `instance_pattern` (regex for numbered/placeholder families) and `component_matchers` (suppresses a compound-row component's own finding while still recognizing it as known) fields to the existing closed (`additionalProperties: false`) schema |
| `skills/naming-register-policy/assets/register.json` | Five rows carry a hand-authored `instance_pattern`: `SMC-NN`, `plan-issue-{ID}`, `engagement-record-{phase}-{ID}`, `review-judge-produced-{PR}`, and `frame slice` (`step_id` / `sN`); the `D1 / D2 / D3` row carries `component_matchers: false` instead, with the exclusion rationale recorded in the schema field description (a bare `D\d+` pattern would collide with 500+ local design-doc decision IDs) |
| `skills/naming-register-policy/scripts/newcomer-audit-core.ps1` | Testable core: UTF-8 read + CRLF→LF normalization, machine-citation zone stripping, register-row-to-matcher derivation, known-term pass (split-by-surface escape hatch), unknown-token pass, structured findings |
| `skills/naming-register-policy/scripts/newcomer-audit.ps1` | CLI wrapper: `-Path` (whole-file, issue-body semantics) and `-Changed` (merge-base diff, repo-file semantics, added-lines emission grain) modes; human summary + JSON output; exit codes 0/1/2 |
| `.github/scripts/Tests/newcomer-audit.Tests.ps1` | Pester fixture matrix covering the known-term, unknown-token, escape-hatch, and diff-grain behaviors |
| `skills/naming-register-policy/SKILL.md` § Outsider-first authoring default | The convention: expand-on-first-use default, grow-on-introduction rule, v1 coverage-boundary table, detection-without-enforcement statement, spin-out promotion trigger |
| `CLAUDE.md` (`## Where things live` area) | One first-use-expanded pointer paragraph naming the convention and the detector |
| `skills/customer-experience/SKILL.md`, `skills/design-exploration/SKILL.md`, `skills/plan-authoring/SKILL.md`, `skills/safe-operations/SKILL.md` | One-line load references to the policy skill's convention section, landed at each skill's verified anchor |
| `agents/Experience-Owner.agent.md`, `agents/Solution-Designer.agent.md`, `agents/Issue-Planner.agent.md` | Draft-scan step at each agent's issue-body write site: draft prose to a `.tmp/` scratch file, run `newcomer-audit.ps1 -Path`, treat findings as advisory, post regardless |
| `skills/pre-commit-formatting/SKILL.md` | New warn-only lane during Code-Conductor's PR-creation gate: `newcomer-audit.ps1 -Changed`, emits findings, never commits, never blocks |

## Design Decisions

| Decision | Choice | Rationale |
| --- | --- | --- |
| Detector weight | Minimal, deterministic, on-demand/pre-commit CLI; CI integration explicitly deferred | The umbrella pre-authorized heavier tooling only if the detector grows into real usage; a lightweight check keyed off the existing register delivers the growth-enforcement scenario without new infrastructure cost |
| Invocation seams | Two v1 seams only: draft-scan before the three upstream agents post prose, plus a warn-only lane in the existing PR-creation formatting gate | No inherited artifact pinned the seams; these two reach the surface classes that matter (agent-authored issue bodies, gate-flowing commits) without a new hook or git-hook lane |
| Escape-hatch split by surface | Issue-body scans always require first-use expansion to suppress a stable code; repo-file scans additionally accept the `HOW-IT-WORKS.md#vocab` pointer link or a link to the term's owning reference skill | All 13 living repo surfaces are test-guaranteed to carry the vocab-pointer; a uniform per-file suppression rule would make the known-term pass inert everywhere readers actually land, so issue bodies (which never inherit that pointer) keep the stricter rule |
| Unknown-token shape | Flag only tokens carrying a digit, underscore, or trailing `[]`; bare ALL-CAPS acronym detection is dropped from v1 | Measured noise (20-65 spurious flags per flagship file from emphasis words and filename fragments) falsified broad shape detection; a narrower, deterministic shape keeps the false-positive rate low enough that authors trust the check |
| Diff scan grain | `-Changed` mode evaluates escape-hatch suppression against the full post-image file but emits findings only for tokens on added/modified lines, via `git diff --diff-filter=ACMR $(git merge-base main HEAD)..HEAD` | Whole-file scanning on a changed-files pass would dump a legacy file's entire backlog on whoever edits one unrelated line, contradicting the "stop new opacity" goal; merge-base (not two-dot `main..HEAD`) keeps the diff correct against an advanced `main` |
| Register growth default | Detector remediation leads with first-use expansion; adding a register row is documented as the deliberate heavier path (register + vocab-seed + binding-count tests) | Expansion is a one-line prose fix while a register row is a 3-4 file coordinated edit; presenting them as equal-cost options would starve the lighter, intended-default path |
| Register scope | Minimal/warn-only/no-CI: detection without enforcement in v1, no PR annotation, no allowlist tooling | Keeps the shipped surface small and named as a spin-out candidate rather than building ahead of observed need |

## Detector Algorithm

The core (`newcomer-audit-core.ps1`) runs two passes over UTF-8-normalized, machine-zone-stripped content (fenced code blocks, HTML comments, and leading YAML frontmatter are blanked out character-by-character so line numbers stay accurate; inline single-backtick prose tokens are left in scope):

1. **Known-term pass.** Each `register.json` row is converted into one or more matchers: rows with an `instance_pattern` use that regex; compound/slash `term` values (e.g. `"credits[] / pipeline-metrics block"`) are tokenized on ` / ` with trailing parentheticals stripped, so each component matches independently; everything else matches the literal `term` text. `stable-code` rows flag unless suppressed by the surface-specific escape hatch described above; `rename-candidate` rows always flag, suggesting the row's `replacement`; `self-describing` rows never flag.
2. **Unknown-token pass.** Any token shaped with a digit, underscore, or trailing `[]` that did not resolve as a known term is flagged as a new, unregistered coinage — unless it hits a small inline allowlist (`ISO-8601`, `UTF-8`, `draft-07`, bare version numbers).

Findings are structured as `{token, line, register_state, suggestion}`; the wrapper adds `file` and serializes to JSON plus a human summary.

**Correctness fixes the adversarial review pipeline caught and folded in post-design:**

- **`term` is a display label, not a matcher.** The pre-review design assumed literal-string matching against `term`; compound/slash and `{ID}`/`{PR}` placeholder rows never appear verbatim in prose, so the core derives its match set (tokenize, apply `instance_pattern`, else literal) instead of matching `term` text directly — otherwise a registered component like `credits[]` could misfire as an unknown coinage.
- **Case-sensitivity parity between the two known-token guards.** Both the known-term matcher and the unknown-token pass's known-token check run case-sensitive (`RegexOptions.None`), so a mis-cased token (e.g. `smc-05`) correctly surfaces as `unknown` in both passes instead of silently vanishing between them.
- **ReDoS timeout guard.** Every regex built from register-authored pattern text (`instance_pattern`, and the derived boundary patterns) runs with a 2-second `[regex]` match timeout; a timeout is treated as a no-match (fail open on that one row) with a loud `Write-Warning`, not a hang.
- **Fail-loud, not fail-silent-blind.** A malformed or empty `register.json`, or a row with an invalid `instance_pattern` regex, causes the wrapper to exit 2 with an explicit error — it no longer silently produces a false-clean (zero-findings) result.

## Current Status

Shipped in this PR: the schema/register foundation, the detector core and wrapper (TDD, Pester-covered), the convention section in `naming-register-policy/SKILL.md`, the `CLAUDE.md` pointer, four load-reference anchors, the draft-scan step in all three upstream agent bodies, and the warn-only `-Changed` lane in `pre-commit-formatting`. The detector's exit code is specified but not consumed by any gate — this is detection without enforcement by design.

Explicitly deferred to a possible spin-out (pre-authorized by the #732 umbrella, not open scope in this issue):

- CI integration (a workflow that runs the detector on every push/PR)
- PR-annotation tooling (inline review comments from findings)
- Allowlist tooling (a maintained, tunable allowlist beyond the current four-entry inline list)

**Spin-out promotion trigger**: the detector graduates when maintainers observe warn-only findings being repeatedly ignored on merged work, or when allowlist/pattern-maintenance churn grows past what inline edits can absorb.

## Known Limitations

The v1 coverage boundary is stated honestly rather than claimed as blanket coverage:

| Surface class | v1 coverage |
| --- | --- |
| Agent-authored issue bodies | Detector (draft-scan seam) + convention |
| Repo docs/READMEs/templates/`CLAUDE.md` committed through the PR-creation gate | Detector (added-lines grain) + convention |
| Same files edited and committed outside the gate | Convention only |
| Issues/docs authored directly on github.com by a human | Convention only — no executable seam exists for this path in v1 |
| Skill `description:` frontmatter | Convention only — stripped along with the rest of YAML frontmatter by the machine-zone stripper |

Other known limitations:

- New, genuinely self-describing coinages that happen to be digit/underscore-shaped still trip the unknown-token pass; the remediation message offers the self-describing-rename path alongside expansion.
- `instance_pattern` rows are hand-maintained — a new numbered family added later must remember to add its own pattern; there is no mechanical generator.
- The readability no-regression outcome (umbrella scenario S2) is not one-shot gateable; it is an ongoing, cross-issue design intent observed over time, not verified by a single CE Gate pass.
