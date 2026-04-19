# ADR-0002: Claude Code Plugin Manifest Schema

**Date**: 2026-04-19
**Status**: Accepted
**Context**: Issue #367 — cross-tool plugin support.

> **Note (v2.0.0 update)**: References to `.github/plugin.json` below describe the state at ADR authoring time. In v2.0.0 the Copilot manifest was relocated to repo-root `plugin.json` (D10 fallback pre-emptively applied so paths read as `./agents/` + `./skills/{name}/` with no `..` escapes). The schema decision for `.claude-plugin/plugin.json` is unaffected.

## Context

Implementing issue #367 (cross-tool plugin support) requires authoritative knowledge of the `.claude-plugin/plugin.json` schema so Agent-Orchestra ships a correct Claude Code manifest alongside its existing `.github/plugin.json`. The plan prosecution pass 2 flagged F2.1 — schema was invented without citation. This ADR resolves that gap.

## Findings

### Manifest location

`.claude-plugin/plugin.json` at the plugin/repo root. Only `plugin.json` lives inside `.claude-plugin/`; all component dirs (`skills/`, `agents/`, `hooks/`, etc.) must be at the plugin root, NOT inside `.claude-plugin/`. Manifest is itself optional — if omitted, components auto-discover from defaults and the plugin name comes from the directory name.

Source: <https://code.claude.com/docs/en/plugins-reference#plugin-manifest-schema>

### Required fields

If a manifest is present, **only `name` is required** (string, kebab-case, no spaces). It is used as the namespace prefix for skills/agents.

Source: <https://code.claude.com/docs/en/plugins-reference#required-fields>

### Optional fields

`version` (semver), `description`, `author` (object: `name`, `email`, `url`), `homepage`, `repository`, `license`, `keywords` (array), plus component-path fields: `skills`, `commands`, `agents`, `hooks`, `mcpServers`, `outputStyles`, `lspServers`, `monitors`, `userConfig`, `channels`, `dependencies`.

Source: <https://code.claude.com/docs/en/plugins-reference#metadata-fields>

### Agent/skill declaration — auto-discovered

**Auto-discovered by default.** `skills/<name>/SKILL.md` and `agents/*.md` at the plugin root load automatically — no manifest declaration needed. The `skills` and `agents` manifest fields exist for **custom paths only** and **replace** the defaults when set. Paths must be relative and start with `./`. To add extra paths while keeping defaults, include the default explicitly: `"skills": ["./skills/", "./extras/"]`.

This is a footgun: declaring `skills`/`agents` arrays in the Claude Code manifest would disable auto-discovery. We will omit them and rely on auto-discovery for the canonical `skills/` and `agents/` layout.

Source: <https://code.claude.com/docs/en/plugins-reference#component-path-fields>; <https://code.claude.com/docs/en/plugins-reference#path-behavior-rules>

### Install commands

- **Remote from marketplace**: `/plugin marketplace add Grimblaz/agent-orchestra` (one-time), then `/plugin install agent-orchestra@<marketplace-name>`.
- **Local/dev**: `claude --plugin-dir ./path-to-repo`.
- **Non-interactive CLI**: `claude plugin install <plugin> [--scope user|project|local]`.

Source: <https://code.claude.com/docs/en/discover-plugins#install-plugins>; <https://code.claude.com/docs/en/plugins-reference#plugin-install>

### Dual-manifest coexistence

Docs do not mention `.github/plugin.json` — it is a Copilot-specific path. Claude Code only reads `.claude-plugin/plugin.json`. We assume the two coexist safely based on non-overlapping paths.

### Version bumping

Semver `MAJOR.MINOR.PATCH` required. Claude Code uses the `version` field to decide whether to refresh cached plugin code — unbumped releases leave existing users on stale code.

Source: <https://code.claude.com/docs/en/plugins-reference#version-management>

## Decision

For #367 step 7(b), `.claude-plugin/plugin.json` ships as metadata-only:

```json
{
  "name": "agent-orchestra",
  "version": "1.14.0",
  "description": "Multi-agent workflow system. Pipeline-based agent orchestration: Issue -> Design -> Plan -> Implement -> Review -> PR.",
  "author": { "name": "Grimblaz" },
  "homepage": "https://github.com/Grimblaz/agent-orchestra",
  "repository": "https://github.com/Grimblaz/agent-orchestra",
  "license": "MIT",
  "keywords": ["workflow","agents","orchestration","code-review","planning","tdd","multi-agent","pipeline"]
}
```

- `skills` and `agents` fields omitted — Claude Code auto-discovers `./skills/<name>/SKILL.md` and `./agents/*.md` at the plugin root. Setting them explicitly would *replace* the defaults and is the documented footgun.
- `version` starts at `1.14.0` (current `.github/plugin.json` is `1.13.0`; #367 bumps both in lockstep per step 7(d)).
- `bump-version.ps1` must be updated (step 7(c)) to write both manifests so future releases stay in sync and Claude Code's cache invalidates correctly.

## Consequences

- Claude Code users install via `/plugin marketplace add Grimblaz/agent-orchestra` + `/plugin install agent-orchestra@<marketplace-name>` — README step 10(c) must document this two-step flow explicitly (step 13/CE Gate S2b verifies it).
- The Claude Code manifest does NOT mirror the 39-skill array from `.github/plugin.json`. This is asymmetric by design — Claude Code auto-discovers; Copilot requires explicit declaration.
- Adding a new skill requires updating `.github/plugin.json` only (Copilot), not `.claude-plugin/plugin.json` (Claude Code auto-picks it up on next version bump).
- Version-bump drift would silently break Claude Code cache invalidation — `bump-version.ps1` dual-write is non-optional.

## References

- <https://code.claude.com/docs/en/plugins>
- <https://code.claude.com/docs/en/plugins-reference>
- <https://code.claude.com/docs/en/discover-plugins>

## Related

- #367 — cross-tool plugin support
- ADR-0001 — cross-tool support decision (supersedes `Documents/Design/tool-support.md` D1)
- `.github/plugin.json` — existing Copilot manifest (metadata source)
