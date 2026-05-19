# Changelog

All notable changes to agent-orchestra will be documented in this file.

## [2.16.0] — 2026-05-19

### Added

- **`skills/solution-authoring/SKILL.md`** — new cognitive-surrender-prevention v0 engagement skill. Codifies the D-classification-test (3-leg gate with artifact-citation falsifier), decision brief structure, override semantics, skip rules (including engineer-declined-engagement and same-decision-resume stub for #575), thin-articulation criterion with forward-compatible YAML schema, and 5 template sections each with a canonical exemplar from the #571 R1+R2 transcript. Declares no `provides:` field — supporting methodology, not a frame port adapter.
- **`skills/solution-authoring/platforms/claude.md`** and **`skills/solution-authoring/platforms/copilot.md`** — platform-specific AskUserQuestion / vscode/askQuestions invocation notes.
- **`Documents/Design/frame-architecture.md`** — stacking-precedent paragraph in the Adapter Model / Declaration asymmetry section documenting that `solution-authoring` and `upstream-onboarding` can stack as `provides:`-less supporting methodologies with load-order declared in the agent body dispatcher.
- **`.github/scripts/Tests/solution-authoring.Tests.ps1`** — structural Pester contract covering AC11.a–AC11.g: body shape (5 rule + 5 template sections), platforms parity, 4-body directive (new present, old absent, line-index ordering, CC touchpoint enumeration), upstream-onboarding sweep (no "first" in 3 anchors + allowlist gate), recommendation-shift token, v0 gate comment, terminology drift guard.

### Changed

- **`agents/Experience-Owner.agent.md`**, **`agents/Solution-Designer.agent.md`**, **`agents/Issue-Planner.agent.md`**, **`agents/Code-Conductor.agent.md`** — `## Process` section standalone upstream-onboarding load line replaced with two-sentence solution-authoring-first directive plus cross-session disclaimer (tracked in #575). Code-Conductor additionally enumerates `scope-classification` and `D9-checkpoint` as content-authoring touchpoints.
- **`skills/upstream-onboarding/SKILL.md`** — removed "first" load-order claim at three section-anchors (frontmatter description, ## When to Use opener, ### Sequencing bullet). Added `<!-- d-load-order-resolution-anchor -->` near ## When to Use. The skill no longer asserts it must be loaded first; that ordering is declared in each agent body dispatcher.
