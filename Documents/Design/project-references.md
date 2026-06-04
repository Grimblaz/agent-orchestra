# Design: Project References

**Status**: Implemented - see [skills/project-references/SKILL.md](../../skills/project-references/SKILL.md)  
**Issue**: [#618](https://github.com/Grimblaz/agent-orchestra/issues/618)  
**Date**: 2026-05-25

## Purpose

Agent Orchestra agents often make framing, design, and planning decisions from issue
history plus general repo instructions. That misses authoritative project-local docs
such as domain rules, architecture notes, operations guides, and long-lived product
constraints when those docs are not already loaded into context.

Project references provide a bounded discoverability layer for those docs. They do
not replace issue bodies, engagement gates, architecture rules, or explicit user
input; they help upstream agents find and cite relevant project documentation before
authoring decisions.

## Shipped Mechanism

The implementation has five cooperating surfaces:

- **Reference sidecars**: `.ref.yml` files describe one target document with
  `schema_version`, `target_path`, `name`, `description`, `load-when`,
  `load-priority`, optional `triggers`, and generator metadata. Per-document
  sidecars are the default; directory-level sidecars are allowed by the skill
  convention, with per-document metadata taking precedence.
- **Generated index**: `.references/index.json` records generated lookup entries
  from sidecars. `generate-references-index.ps1` also refreshes `Documents/INDEX.md`
  as a human-readable summary.
- **Repository config**: `.agent-orchestra.yml` stores reference roots and budgets
  under `references`: `declared_roots`, `doc_count_threshold`,
  `max_critical_loaded`, and `max_total_loaded_bytes`.
- **Setup command**: `/setup-references` exposes `help`, `init`, `generate`,
  `validate`, `undo`, and `dismiss-nudge` for Claude and Copilot command surfaces.
  The empty or `help` action is read-only; mutating actions are explicit.
- **Upstream onboarding integration**: [skills/upstream-onboarding/SKILL.md](../../skills/upstream-onboarding/SKILL.md)
  discovers project-reference configuration during the opening phase, loads only
  matching references for the current issue or scope, and surfaces loaded names,
  under-match notes, stale-reference markers, or the non-blocking adoption nudge in
  the context brief.

The schema and trust contract live in [skills/project-references/SKILL.md](../../skills/project-references/SKILL.md).
The deterministic implementation lives under
[skills/project-references/scripts](../../skills/project-references/scripts).

## Safety And Trust

Project references are designed as repository content, not instructions with elevated
authority.

- `target_path` values are resolved through a root-contained path resolver. Entries
  that point outside the repository, omit a target, or point at a missing file are
  treated as stale or orphaned validation evidence rather than silently loaded.
- Loaded document bodies render as fenced `untrusted-content` blocks. Reference text
  may inform an agent's recommended option, rationale, constraints, or brief, but it
  cannot suppress engagement gates, standards checks, auto-mode boundaries, or
  user-confirmation requirements.
- Initialization records generated files in
  `.copilot-tracking/references-init.manifest`. Undo removes only manifest-listed,
  root-contained generated files; it is not a broad cleanup command.
- Nudge and setup state live in `.copilot-tracking/references-state.yml` using
  `references_setup_complete` and `references_nudge_dismissed`.
- Loading is capped by `.agent-orchestra.yml`, defaulting to
  `max_critical_loaded: 10` and `max_total_loaded_bytes: 102400`. The adoption nudge
  is gated by `doc_count_threshold`, defaulting to `5`, and remains non-blocking.
- Validation reports stale targets, orphan sidecars, duplicate names, unknown schema
  versions, uncovered docs, citation checks, and projected budget overruns.

## Pre-flight Determinism (Issue #647)

On Claude, project-reference loading is deterministic via the `UserPromptSubmit` hook. Before each issue-referencing upstream-phase turn, `reference-preflight-hook.ps1` (registered in `hooks/hooks.json` under `UserPromptSubmit`) runs the loader automatically:

1. Extracts the issue number from the incoming prompt text.
2. Fetches the issue via `gh issue view`.
3. Calls `invoke-reference-loader.ps1` to match `critical` references against the issue's labels, keywords, and title/body tokens.
4. On match, assembles `additionalContext` containing a trust-framing preamble, the rendered reference bodies (already fenced as `untrusted-content`), and the canonical sentinel `<!-- refs-injected-{issue} -->` (defined in `skills/project-references/SKILL.md §Sentinel`).

`upstream-onboarding/SKILL.md §Project Reference Loading` detects the sentinel and defers its own loading step when the hook has already injected references, preventing double-loading.

**USE obligation**: when references are injected, agents ground their framing, design, or planning reasoning in them or explicitly note why they do not apply. This is a soft obligation — advisory, not a hard block.

**Run-once suppression (SMC-22)**: a two-phase marker keyed by `session_id` + issue number + issue-body hash prevents re-injection within the same conversation. If the issue body changes (e.g., a phase writes new content), the hash changes and re-injection fires once more.

**Fail-open**: every error path exits 0 so the hook never blocks the user's turn. Error breadcrumbs distinguish `no-match` (triggers did not match — no refs injected) from `could-not-check` (gh fetch, payload build, or loader failure).

### Known Limitations

- **Glob-only `critical` references will not match**: at pre-flight time `changed_paths` is empty — no branch diff exists. Matching runs only on label, keyword, and title/body triggers. A `critical` reference keyed solely by a `globs:` trigger is silently skipped. Add at least one non-path trigger to any `critical` reference intended for pre-flight loading.
- **Trust boundary**: issue-title, issue-body, and label content drives matching. Anyone with issue-create access can author matching text. Label-gated triggers (where only maintainers can apply labels) are the more conservative option for sensitive references. Full hardening is deferred.
- **Claude-only**: `UserPromptSubmit` has no Copilot analog. Copilot falls back to the prose-instructed loading path in `upstream-onboarding/SKILL.md §Project Reference Loading`.
- **Advisory posture**: the USE obligation is soft; hard blocking is deferred.

## Validation And Deferred Items

The shipped validation surface is [validate-references-index.ps1](../../skills/project-references/scripts/validate-references-index.ps1),
with loader behavior covered by [invoke-reference-loader.ps1](../../skills/project-references/scripts/invoke-reference-loader.ps1)
and the project-reference Pester fixtures under `.github/scripts/Tests/fixtures/project-references/`.

Known deferred items:

- Multi-trigger sidecar parsing is tracked as follow-up
  [#626](https://github.com/Grimblaz/agent-orchestra/issues/626).
- Citation enforcement remains design-deferred and best-effort. The shipped skills
  define the citation format and tell agents not to invent citations, while the
  validator provides citation checks rather than a hard workflow gate.

## Related Implementation Surfaces

- [skills/project-references/SKILL.md](../../skills/project-references/SKILL.md) - schema, citation format, content-trust rules, and caps
- [skills/project-references/scripts](../../skills/project-references/scripts) - init, generate, validate, loader, and shared core scripts
- [commands/setup-references.md](../../commands/setup-references.md) - Claude `/setup-references` command
- [.github/prompts/setup-references.prompt.md](../../.github/prompts/setup-references.prompt.md) - Copilot `/setup-references` prompt
- [skills/upstream-onboarding/SKILL.md](../../skills/upstream-onboarding/SKILL.md) - opening-phase loader integration, brief behavior, and soft USE obligation
- [skills/project-references/scripts/reference-preflight-hook.ps1](../../skills/project-references/scripts/reference-preflight-hook.ps1) - UserPromptSubmit hook for deterministic pre-flight loading (Claude only)
- [hooks/hooks.json](../../hooks/hooks.json) - hook registration (UserPromptSubmit entry)
- [examples/project-references](../../examples/project-references) - compact sample repository shape
