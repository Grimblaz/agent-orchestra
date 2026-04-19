# ADR-0001: Cross-Tool Plugin Support (reverses `tool-support.md` D1)

**Date**: 2026-04-19
**Status**: Accepted — supersedes `Documents/Design/tool-support.md` D1
**Context**: Issue #367 — migrate agents and skills to repo root for cross-platform plugin readiness (VS Code Copilot + Claude Code).

## Context

`Documents/Design/tool-support.md` D1 (issue #175, declared 2025-Q4) chose "GitHub Copilot only (Claude Code support removed)" as the tool target. That decision removed a `CLAUDE.md` + `.claude/commands/*.md` *project-context duplication layer* that had no distribution model behind it — it was hand-maintained parallel documentation.

The landscape has since changed:

1. **Claude Code now ships a first-class plugin system** (`.claude-plugin/plugin.json` — see ADR-0002) that auto-discovers `agents/` and `skills/` at the plugin root. No documentation duplication is required — the same skill and agent content loads natively.
2. **Copilot-Orchestra is explicitly a hub** (confirmed 2026-04-19, user): this repo exists to be *consumed by other repos* as a plugin. Single-tool support makes the hub irrelevant to consumers who work in a different tool.
3. **Consumer-side evidence**: Issue #367 surfaced consumers who already run both tools in the same workspace. Forcing them to pick one leaks the engineering-internal decision into their product workflow.

D1's rationale was operational (dual-maintenance of parallel docs). That cost no longer exists under plugin distribution: both tools consume the same `skills/<name>/SKILL.md` and `agents/*.md` files, from the same paths, with different manifests pointing at the same content.

## Decision

**Copilot-Orchestra supports GitHub Copilot and Claude Code as first-class distribution targets via dual plugin manifests over shared content.**

Layout (Shape A):

- Content at repo root: `agents/` (14 agent files) + `skills/` (39 skill dirs).
- `.github/plugin.json` — Copilot manifest, paths resolved relative to `.github/` (so entries use `../agents/`, `../skills/...`).
- `.claude-plugin/plugin.json` — Claude Code manifest, metadata-only (auto-discovers `agents/` and `skills/` at plugin root; setting `agents`/`skills` arrays would disable auto-discovery per ADR-0002).

Content is platform-neutral. Six skills that require tool-specific invocation syntax (`session-startup`, `provenance-gate`, `step-commit`, `parallel-execution`, `design-exploration`, `customer-experience`) split platform-specific blocks into `platforms/copilot.md` and `platforms/claude.md` under each skill, with a canonical routing footer in SKILL.md. `session-startup` has a documented D3b soft exemption to retain methodology alongside the footer.

## Rationale

- **Single source of truth, two distribution channels**: Same content, two manifests. No parallel documentation.
- **Hub-native for both ecosystems**: Consumers install the orchestra as a plugin in whichever tool they use; the hub does not impose tool choice.
- **Cost structure inverted**: Under D1, supporting Claude Code meant maintaining a second set of context files. Under this ADR, supporting Claude Code is a metadata-only manifest plus a thin per-skill platforms/ split for 6 skills — a fraction of what D1 removed.
- **Plugin-system affordances**: Both tools handle install, version pinning, and cache invalidation automatically. Bump `version` once (dual-write via `bump-version.ps1`) and both consumer installs refresh.

## Consequences

### Positive

- Hub is usable from either tool with identical workflow semantics.
- Adding a new skill requires `.github/plugin.json` update only (Copilot); Claude Code auto-picks it up on next version bump.
- Contributor-experience parity: SKILL.md is platform-neutral; each platforms/ file documents its tool's specific invocations.

### Negative

- Two manifests must stay version-synchronized — handled by `bump-version.ps1` dual-write (non-optional per ADR-0002 for cache invalidation).
- Six skills split across SKILL.md + platforms/ files introduces a small maintenance surface (canonical footer parity enforced by sweep gate in Step 12).
- VS Code Copilot's behavior with `../` path escapes in `.github/plugin.json` (repo root from manifest-dir perspective) is the one open risk — Step 13 local install acts as the gate. If it fails, this plan HARD STOPS (per plan F1.6) rather than pivoting mid-flight.

### Reversibility

- Reversible: delete `.claude-plugin/`, revert `.github/plugin.json` paths to `./agents/` + `./skills/`, and move content back under `.github/`. `bump-version.ps1` reverts with the manifest.
- If reverted, ADR-0001 is marked "Superseded" and D1 restored.

## Supersession notice (to be placed on `tool-support.md` D1)

```
D1 — Superseded by ADR-0001 (2026-04-19, issue #367). The rationale for
single-tool focus (dual-maintenance of parallel context files) no longer
applies once both tools consume the same skills/ and agents/ content via
plugin distribution. The original decision text is preserved below for
historical context.
```

## References

- `Documents/Decisions/0002-claude-code-plugin-schema.md` — Claude Code manifest schema (Step 0 research spike)
- `Documents/Design/tool-support.md` — superseded D1
- Issue #367
- Issue #175 — the work that established D1

## Related ADRs

- ADR-0002 — Claude Code plugin manifest schema
