---
name: ai-first-documentation
description: "Research-backed standards for documentation in AI-first codebases: context-file architecture (CLAUDE.md, skills, subagents, rules), multi-agent interop, and project-doc organization, with a tiered audit rubric. Use when authoring or auditing CLAUDE.md/AGENTS.md, deciding where guidance belongs, or running a documentation gap analysis. DO NOT USE FOR: post-implementation doc updates (use documentation-finalization) or reference sidecar setup (use project-references)."
---

<!-- platform-assumptions: markdown skill guidance for Claude Code and compatible agents; rubric evidence verified against live vendor docs on 2026-06-10/11 — re-verify concrete numbers before hard enforcement. -->
<!-- markdownlint-disable-file MD041 MD003 -->

# AI-First Documentation Standards

Standards for structuring a repository's documentation when coding agents are primary readers and operators. Every practice here is backed by two adversarially-verified research passes (June 2026) across Anthropic official guidance (Tier 1), major vendor guidance (Tier 2), and evidenced practitioner sources (Tier 3). The testable rubric lives in [rubric.md](./rubric.md); citations, verification dates, refuted claims, and open gaps live in [sources.md](./sources.md).

- [When to Use](#when-to-use)
- [Core Principle](#core-principle)
- [The Placement Model](#the-placement-model)
- [Audit Workflow](#audit-workflow)
- [Consumer-Mode Audits](#consumer-mode-audits)
- [Recording Documentation Decisions](#recording-documentation-decisions)
- [Multi-Agent Repositories](#multi-agent-repositories)
- [Known Industry Open Gaps](#known-industry-open-gaps)
- [Quick Reference — Verified Numbers](#quick-reference--verified-numbers)
- [See Also](#see-also)
- [Gotchas](#gotchas)

## When to Use

- Authoring or auditing a CLAUDE.md, AGENTS.md, or other always-loaded context file
- Deciding where a piece of guidance belongs (always-loaded vs. path-scoped vs. skill vs. plain doc)
- Designing or reviewing skills, subagent definitions, or rules files
- Running a documentation gap analysis of a repository against industry best practice
- Configuring a repo that must serve multiple agent toolchains (Claude Code, Copilot, Cursor, Codex)

## Core Principle

The context window is the scarce resource. Performance degrades as it fills, so always-loaded files must be ruthlessly minimal — every line survives the deletion test ("Would removing this cause the agent to make mistakes?") — while everything else moves to on-demand mechanisms: skills with progressive disclosure, path-scoped rules, child-directory context files, and just-in-time retrieval via glob/grep rather than pre-built indexes. (Tier 1; corroborated by all surveyed vendors and an academic taxonomy of 13 open-source agents.)

Minimal does not mean short for its own sake: the criterion is signal density plus behavioral sufficiency, not raw line count.

## The Placement Model

Route each piece of guidance to its cheapest sufficient home:

| Content kind | Home | Loading cost |
| --- | --- | --- |
| Broadly-applicable facts: non-guessable commands, non-default conventions, testing instructions, repo etiquette, gotchas, "always do X" rules | Root CLAUDE.md / AGENTS.md | Every session |
| Area-specific instructions tied to file paths | Path-scoped rules (`paths:`/glob frontmatter) or child-directory CLAUDE.md | Only when matching files are touched |
| Multi-step procedures, domain workflows, methodology | Skill (SKILL.md) | Metadata always (~100 tokens); body on demand |
| Deep reference material, schemas, long examples | Skill reference files or plain docs, pointed to one level deep | Zero until accessed |
| Side-effectful workflows that must not auto-trigger | Skill with `disable-model-invocation: true` | Manual invocation only |
| High-volume exploration or review output | Subagent with isolated context | Never enters main context |
| Anything derivable by reading the code, standard language conventions, frequently-changing facts, file-by-file codebase tours | Nowhere — delete it | — |

Two traps in this model: `@import`s in CLAUDE.md load at launch and save **no** context (only child-directory files and skills defer cost), and rules files **without** a path scope load unconditionally every session.

## Audit Workflow

To run a gap analysis of a repository:

1. **Inventory** the documentation surface: root and nested context files (`CLAUDE.md`, `AGENTS.md`, `CLAUDE.local.md`), `.claude/rules/`, `skills/*/SKILL.md`, agent definitions, and the plain-doc tree (design docs, ADRs, runbooks, plans).
2. **Classify** each artifact against the Placement Model: is anything always-loaded that could be on-demand? Is anything on-demand that the agent needs every session?
3. **Test** each applicable practice in [rubric.md](./rubric.md), section by section (A: always-loaded context, B: skills, C: subagents, D: writing style, E: multi-agent interop, F: project docs).
4. **Weight findings by tier and confidence** from the rubric: a Tier 1 high-confidence violation is a defect; a Tier 2 conflict is a trade-off to decide consciously; a Tier 3 divergence is informational.
5. **Label house conventions in open-gap areas.** Where the rubric marks a topic as a confirmed industry open gap (Section F), a repo's own conventions are not violations — record them as house practice filling a documented gap, and consider them candidates for promotion if external standards later emerge.

The mechanical checks (A2, B2, B3, B5, A9) are deterministic and can be run headlessly via [scripts/audit-docs-mechanical.ps1](./scripts/audit-docs-mechanical.ps1) with an explicit `-Root` parameter. For the interactive audit experience (applying judgment, browsing findings, running init), use `/audit-docs` — it runs the script and applies rubric judgment passes on top.

## Consumer-Mode Audits

The mechanical-check script (`scripts/audit-docs-mechanical.ps1`) is designed to run against any consumer repository root, not just the hub. When run from a consumer's CI or shell:

- **Own-surface scoping rule (D3)**: the script inventories only files in the consumer tree — root `CLAUDE.md`, `AGENTS.md`, `CLAUDE.local.md`, `.claude/rules/`, local `skills/`, `.claude/agents/`, and the project doc tree. Plugin-cache paths (`.claude/plugins/`) are never inventoried.
- **Entry-point precedence (D7)**: for interactive audits, `/audit-docs` is the deterministic entry point — it runs the script and applies rubric judgment. For headless/CI use, invoke the script directly:
  ```powershell
  pwsh skills/ai-first-documentation/scripts/audit-docs-mechanical.ps1 -Root . -FailOn fail
  ```
  Acquire the script via vendor-copy or pinned raw fetch; do not depend on a git submodule or npm package.
- **CI snippet** (acquire + run):
  ```powershell
  # After vendoring the script to your repo (e.g., scripts/audit-docs-mechanical.ps1):
  pwsh scripts/audit-docs-mechanical.ps1 -Root $env:GITHUB_WORKSPACE -FailOn fail
  ```
  Always pass a non-empty `-Root` — an empty string produces a PowerShell parameter-binding error rather than JSON output, since the binding check runs before the script body. The command layer's root-resolution step (CWD fallback) prevents this in interactive use.

## Recording Documentation Decisions

When a check fires and the deviation is intentional (e.g., CLAUDE.md is temporarily over 200 lines during a migration), record the decision in `.claude/documentation-decisions.md` at the consumer's root. The script reads this file and emits `status: waived` instead of `fail` for matched entries, so the decision is not re-litigated on re-runs or in CI.

**Format (named decision `d-decision-record-format`)** — H3-per-record markdown:

```markdown
### {check-id}: {relative-path}
- rationale: [CUSTOMIZE: why this deviation is intentional and temporary]
- date: YYYY-MM-DD
```

**Example**:

```markdown
### A2: CLAUDE.md
- rationale: CLAUDE.md is intentionally long during the Q3 migration; pruning tracked in issue #42.
- date: 2026-06-12
```

The match key is (check_id, normalized relative path from root). The `waiver_ref` in the JSON output is the raw heading text (`A2: CLAUDE.md`). Keep the H3 heading to the two-token `{check-id}: {relative-path}` form — any trailing annotation (e.g., `### A2: CLAUDE.md — migration note`) will appear verbatim in `waiver_ref`. Matching is case-insensitive: `### a2: claude.md` matches the same entry as `### A2: CLAUDE.md`.

**Relocation**: the default location is `.claude/documentation-decisions.md`. Override with `-DecisionRecordPath <absolute-or-repo-relative-path>` when your repo layout differs.

## Multi-Agent Repositories

When one repo serves several agent toolchains, consult rubric Section E before restructuring. Key verified facts: AGENTS.md is the cross-vendor de facto standard, but Claude Code does not read it natively (use a CLAUDE.md containing `@AGENTS.md`); Copilot's cloud agent reads CLAUDE.md natively but only as a single flat root file; Copilot code review reads only the first 4,000 characters of any instruction file; Cursor silently ignores plain `.md` files in `.cursor/rules` (frontmatter `.mdc` or AGENTS.md only); Codex concatenates AGENTS.md files root-down with the closest file winning positionally.

One genuine unresolved conflict exists: GitHub recommends embedding repo structure and dependency versions and warns that pointer references to other docs may be ineffective in large repos — the opposite of Anthropic's deletion-test minimalism and progressive disclosure. Neither side has measured evidence. Default to the Anthropic model for Claude-primary repos; consciously revisit if Copilot adherence problems appear.

## Known Industry Open Gaps

No credible verified guidance exists (as of June 2026) for: authoring ADRs/design docs differently for AI readers; whether llms.txt-style index files help or hurt vs. pure just-in-time search; wrapping general project docs as skills; doc-to-code linking that breaks loudly on drift; or doc-tree naming conventions optimized for agent navigation. The only verified adjacent practices are staleness automation (review-time flagging of doc drift — "a stale context file can be worse than no file at all") and the split-and-reference pattern (concise root file pointing to task-specific docs). Treat conventions in these areas as labeled house judgment, not settled standards. Details in [sources.md](./sources.md).

## Quick Reference — Verified Numbers

| Number | What it bounds | Tier |
| --- | --- | --- |
| < 200 lines | CLAUDE.md adherence target (not a truncation limit) | 1 |
| < 500 lines | SKILL.md body; also Cursor's per-rule-file ceiling | 1 / 2 |
| 64 / 1024 chars | Skill frontmatter `name` / `description` hard limits | 1 |
| 1 level | Skill reference-file depth from SKILL.md (never nested chains) | 1 |
| > 100 lines | Reference file size that requires a leading table of contents | 1 |
| Depth 4 | Maximum recursive `@import` depth in CLAUDE.md | 1 |
| 4,000 chars | Copilot code review reads only this much of any instruction file | 2 |
| 32 KiB | Codex default combined instruction-file budget (`project_doc_max_bytes`) | 2 |

All numbers live-verified 2026-06-10/11; vendor docs churn, so re-verify before hard enforcement (see [sources.md](./sources.md)).

## See Also

- [rubric.md](./rubric.md) — the practice-by-practice testable audit rubric
- [sources.md](./sources.md) — citations, verification dates, refuted claims, open questions
- [scripts/audit-docs-mechanical.ps1](./scripts/audit-docs-mechanical.ps1) — mechanical-check script for A2, B2, B3, B5, A9; headless/CI mode
- [templates/CLAUDE.md-starter.md](./templates/CLAUDE.md-starter.md) — minimal CLAUDE.md seed template
- `documentation-finalization` — updating implementation-facing docs after code changes
- `project-references` — Agent Orchestra reference sidecars and index conventions (a house convention in open-gap territory)
- `skill-creator` — repo-specific skill frontmatter and structure conventions

## Gotchas

| Trigger | Gotcha | Fix |
| --- | --- | --- |
| Moving CLAUDE.md overflow into `@import` files "to save context" | Imports load in full at launch — zero context savings, same adherence cost | Move content to a skill or child-directory CLAUDE.md, which load on demand |
| Adding a rules file without a path scope | It loads every session, silently becoming always-loaded context | Add a `paths:`/glob scope, or move the content to a skill |
| Writing a skill description in first person or omitting "when to use" | Description is the sole selection signal injected into the system prompt; the skill is never picked | Third person, state what it does AND when to use it, within 1024 chars |
| Chaining reference files (SKILL.md → ref-a.md → ref-b.md) | Agents may partially read nested references (e.g., head-100 previews) and miss content | Link every reference file directly from SKILL.md, one level deep |
| Assuming Copilot honors nested CLAUDE.md or `@`-imports | Copilot's cloud agent reads only a single flat root CLAUDE.md | Keep the root file self-sufficient for Copilot, or maintain AGENTS.md |
| Padding CLAUDE.md with folder structure and dependency versions | JIT-discoverable, staleness-prone content that fails the deletion test (GitHub recommends it; Anthropic canon excludes it — known conflict) | Default to omitting; the agent can glob/grep it fresh |
