<!-- markdownlint-disable-file MD041 MD003 -->

# AI-First Documentation Audit Rubric

Practice-by-practice testable rubric. Each practice carries a tier (1 = Anthropic official, 2 = major vendor, 3 = evidenced practitioner), a confidence level from adversarial verification, and a short test an auditor can apply. Full citations and verification dates are in [sources.md](./sources.md).

## Table of Contents

- [Section A — Always-loaded context (CLAUDE.md / AGENTS.md root)](#section-a--always-loaded-context-claudemd--agentsmd-root)
- [Section B — Skills](#section-b--skills)
- [Section C — Subagents](#section-c--subagents)
- [Section D — Writing style for agent-facing docs](#section-d--writing-style-for-agent-facing-docs)
- [Section E — Multi-agent and vendor interop](#section-e--multi-agent-and-vendor-interop)
- [Section F — Project documentation (thin verified set)](#section-f--project-documentation-thin-verified-set)
- [How to score](#how-to-score)

## Section A — Always-loaded context (CLAUDE.md / AGENTS.md root)

| ID | Practice and test | Tier | Confidence |
| --- | --- | --- | --- |
| A1 | **Deletion test.** Every line survives "Would removing this cause the agent to make mistakes?" Test: sample lines and ask whether removal changes agent behavior. | 1 | High |
| A2 | **Under 200 lines per file.** An adherence target, not a truncation limit — longer files reduce instruction adherence. Test: `wc -l` each always-loaded file. | 1 | High |
| A3 | **Include only broadly-applicable facts.** Non-guessable commands, non-default code style, testing instructions, repo etiquette, project-specific architecture decisions, environment quirks, gotchas, "always do X" rules. Test: each section applies to most sessions, not one area. | 1 | High |
| A4 | **Exclude derivable and volatile content.** No content the agent can read from code, no standard language conventions, no detailed API docs (link instead), no frequently-changing facts, no file-by-file codebase tours, no tutorials. Test: grep for directory listings, version pins, restated public docs. | 1 | High |
| A5 | **Commands are copy-paste executable** with explicit flags (e.g., `pytest -v`), not bare tool names. Test: paste each documented command into a shell. | 2 | High |
| A6 | **Six-area coverage**: commands, testing, project structure, code style, git workflow, boundaries (do-not-touch zones). Observational top-tier pattern from 2,500+ repos; one verifier dissent — treat as a checklist, not a mandate. Note the tension between a "project structure" section and A4; keep any structure notes to stable, non-derivable facts. | 2 | Medium |
| A7 | **Failure-driven growth.** Start minimal; add a rule only after observing repeated agent mistakes it would prevent. Test: rules trace to actual observed failures, not speculation. | 2 | High |
| A8 | **Use the hierarchy correctly.** Parent/root files load in full at launch (concatenated root-to-cwd, not overriding); child-directory CLAUDE.md files load on demand when files there are read; `@import`s (max depth 4) load at launch and save no context. Test: nothing was moved to an import "for context savings"; area-specific content lives in child files or skills. | 1 | High |
| A9 | **Rules files are path-scoped.** A rules file without a path scope loads every session. Test: every file in `.claude/rules/` carries a `paths:` (or equivalent glob) scope, or its unconditional load is intentional. | 1 | High |

## Section B — Skills

| ID | Practice and test | Tier | Confidence |
| --- | --- | --- | --- |
| B1 | **Progressive disclosure in three levels.** Only name+description preloads (~100 tokens); SKILL.md body reads on relevance; bundled files read on demand (zero cost until accessed). Test: no skill content is duplicated into always-loaded files; deep material sits in bundled files. | 1 | High |
| B2 | **SKILL.md body under 500 lines.** Split into referenced files when approaching the limit. Test: `wc -l` each SKILL.md. | 1 | High |
| B3 | **Frontmatter contract.** `name` ≤ 64 chars, lowercase/numbers/hyphens, no XML tags, no reserved words ("claude", "anthropic"); `description` non-empty, ≤ 1024 chars, no XML tags, third person, states what the skill does AND when to use it. Test: validate each skill's frontmatter against these limits. | 1 | High |
| B4 | **References one level deep.** Every reference file links directly from SKILL.md; no nested reference chains (partial reads miss content beyond one hop). Test: trace links from each SKILL.md. | 1 | High |
| B5 | **Table of contents in long references.** Reference files over 100 lines open with a ToC so partial reads reveal full scope. Test: check the head of each reference file. | 1 | High |
| B6 | **Manual trigger for side effects.** Workflows with side effects that should not auto-fire declare `disable-model-invocation: true`. Note: such skills do NOT get their descriptions preloaded. Test: review side-effectful skills' frontmatter. | 1 | High |
| B7 | **Separate rarely co-used contexts.** Mutually-exclusive or rarely co-used content lives in separate file paths to avoid loading both. Test: look for reference files bundling unrelated variants. | 1 | High |
| B8 | **Execute scripts, don't read them.** Deterministic utility logic ships as scripts run via shell — contents never enter context, only output does. Test: procedural logic that could be a script isn't transcribed as prose steps. | 1 | High |

## Section C — Subagents

| ID | Practice and test | Tier | Confidence |
| --- | --- | --- | --- |
| C1 | **Format contract.** Markdown with YAML frontmatter; only `name` and `description` required; the body becomes the system prompt. Test: validate each agent definition. | 1 | High |
| C2 | **One focused task each**, with detailed descriptions — delegation is driven by the description field ("use proactively" phrasing encourages proactive dispatch). Test: each agent's description states a single clear responsibility and dispatch trigger. | 1 | High |
| C3 | **Least-privilege tools; version controlled.** Restrict tool access to what the role needs; check project agents into git. Test: review `tools:` lists against each agent's actual needs. | 1 | High |
| C4 | **Plan for isolation semantics.** Subagents start with fresh context (no conversation history) but DO load the full CLAUDE.md hierarchy and a git-status snapshot — except built-in Explore and Plan, which skip both, non-configurably. Test: agent bodies don't assume conversation context; nothing relies on Explore/Plan seeing CLAUDE.md. | 1 | High |

## Section D — Writing style for agent-facing docs

| ID | Practice and test | Tier | Confidence |
| --- | --- | --- | --- |
| D1 | **Right altitude.** Neither hardcoded brittle if-else logic nor vague high-level platitudes; concrete heuristics the agent can apply with judgment. Test: sample instructions for both failure modes. | 1 | High |
| D2 | **Delimited sections.** Organize instruction files into distinct sections with Markdown headers or XML tags. Test: visual scan of structure. | 1 | High |
| D3 | **Canonical examples over edge-case lists.** A small set of diverse, representative examples beats exhaustive edge-case enumeration. Test: look for laundry-list rule dumps that could collapse into 2–3 worked examples. | 1 | High |

## Section E — Multi-agent and vendor interop

Apply only when the repo serves toolchains beyond Claude Code.

| ID | Practice and test | Tier | Confidence |
| --- | --- | --- | --- |
| E1 | **AGENTS.md is the cross-vendor standard** (~60k–95k repos, Linux Foundation stewardship), with an explicit split: README for humans, AGENTS.md for agent-relevant build/test/convention detail. Test: multi-agent repos carry an AGENTS.md; READMEs aren't duplicating agent instructions. | 2 | High |
| E2 | **Claude Code does not read AGENTS.md natively.** Official interop: a CLAUDE.md containing `@AGENTS.md` (import preferred over symlink on Windows). Test: repos standardizing on AGENTS.md have the shim. | 1 | High |
| E3 | **Copilot's cloud agent reads CLAUDE.md natively — but only a single flat root file.** Nested CLAUDE.md and `@`-imports are not honored; VS Code Chat and Copilot CLI read AGENTS.md only. Test: content Copilot must see lives in the flat root file or AGENTS.md. | 2 | High |
| E4 | **Copilot code review reads only the first 4,000 characters** of any instruction file (silently truncates; limit had a 2026 docs-churn episode — re-verify). Test: review-critical guidance sits within the first 4,000 chars. | 2 | High |
| E5 | **Cursor ignores plain `.md` in `.cursor/rules`.** Rules require `.mdc` with frontmatter (`description`, `globs`, `alwaysApply`); empty frontmatter degrades to manual-only. Cursor also natively supports root and nested AGENTS.md as the metadata-free alternative. Test: no orphaned `.md` files in `.cursor/rules/`. | 2 | High |
| E6 | **Codex concatenates AGENTS.md root-down**; the file closest to the working directory wins positionally; combined budget defaults to 32 KiB (`project_doc_max_bytes`); one file per directory. Test: nested AGENTS.md files don't restate parents; total size within budget. | 2 | High |
| E7 | **Copilot precedence when formats collide**: personal > repo path-specific > repo-wide copilot-instructions.md > agent files (AGENTS.md/CLAUDE.md) > organization — all applicable sets merge rather than filter. AGENTS.md-vs-CLAUDE.md precedence at the same level is undocumented. Test: don't place contradictory instructions across layers. | 2 | High |
| E8 | **CONFLICT (unresolved): GitHub vs. minimalism.** GitHub recommends embedding project overview, folder structure, coding standards, and dependency versions, and warns pointer references to other docs may be ineffective in large repos — opposing Tier 1 deletion-test minimalism and progressive disclosure. No measured evidence either way. Audit action: pick a side consciously per primary toolchain; default Anthropic-style for Claude-primary repos. | 2 | High (that the conflict exists) |

## Section F — Project documentation (thin verified set)

Verified practices are sparse here; see [sources.md](./sources.md) § Open gaps before treating anything beyond these rows as standard.

| ID | Practice and test | Tier | Confidence |
| --- | --- | --- | --- |
| F1 | **Organize for just-in-time retrieval, not pre-built indexes.** Agents navigate via glob/grep at runtime (8 of 13 surveyed open-source agents implement pure JIT search). Docs should be findable by predictable paths and grep-able headings rather than relying on a maintained index. Test: can an agent locate the right doc with one glob + one grep? | 1 (+3 corroboration) | High |
| F2 | **Split-and-reference.** Keep the root context file concise and reference task-specific markdown docs (planning, review, architecture) — a plain-markdown analog of progressive disclosure. Test: root file points to task docs instead of inlining them. | 2 | High |
| F3 | **Automate staleness detection.** Close the loop with review-time automation that flags when code changes suggest context/docs need updating — rationale: "a stale AGENTS.md can be worse than no file at all." Evidence: one org at ~3,900-repo scale (capability statement, no published precision/recall). Test: some mechanism (reviewer prompt, CI check, hook) ties doc updates to code change review. | 3 | Medium |
| F4 | **Machine-citable standards.** Give internal standards stable, citable identifiers (e.g., named rules/RFC numbers) so context files and reviews can reference them precisely. Evidence: same single-org source as F3. Test: conventions cited by anchor/name rather than restated. | 3 | Medium |

## How to score

- **Tier 1 + High** violation → defect; fix it.
- **Tier 2 + High** violation → conscious trade-off; record the decision and which toolchain it favors.
- **Tier 2 Medium / Tier 3** divergence → informational; note and move on.
- **Open-gap territory** (anything Section F doesn't cover) → house convention; label it as such, don't score it.
