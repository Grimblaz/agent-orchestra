# AGENTS.md

## What this repository is

Agent Orchestra is a multi-agent workflow system built for Claude Code, combining a tool-agnostic markdown methodology with PowerShell 7 automation scripts. This file orients any agent landing here with no prior context — especially a zero-context Codex session or its automated GitHub pull-request review — and every claim below is meant to be verified against the current tree, not taken on faith.

## Agent surfaces: what works where

Slash commands, plugin install/marketplace, subagent dispatch, and the plugin-distributed hooks at `hooks/hooks.json` (its path is keyed on the environment variable the Claude Code plugin runtime sets to its own install root) are Claude Code-only surfaces.

A frozen GitHub Copilot surface also ships today and remains until 2026-08-31 (sunset decision: [Documents/Design/copilot-deprecation.md](Documents/Design/copilot-deprecation.md)): `.github/prompts/*.prompt.md` (Copilot slash-command prompts) and the **separate** root `hooks.json` — the Copilot/VS Code hook config. Do not conflate the two `hooks.json` files; they serve two different platforms.

None of these surfaces — Claude's or Copilot's — are available to a Codex session. Any agent, including Codex, can read the methodology, review code, and verify claims against the tree.

## How changes are verified

Pester tests live in `.github/scripts/Tests/*.Tests.ps1` and run under PowerShell 7 (`pwsh`). Markdown is held to `.markdownlint.json` and `.editorconfig`. Entry-point changes (the plugin-shipped file set defined in [skills/plugin-release-hygiene/SKILL.md](skills/plugin-release-hygiene/SKILL.md)) that ship require a version bump performed via `.github/scripts/bump-version.ps1` — version strings are never hand-edited. Reviewers should also expect script changes to carry test coverage and human-facing documentation to expand insider terms on first use.

## Where decisions live

Durable HTML-comment markers on GitHub issues and pull requests are the cross-session source of truth. Markers are mixed form: some are single tags (for example the plan marker `<!-- plan-issue-{ID} -->`), others are paired begin/end blocks (for example `<!-- named-decisions:begin -->` … `<!-- named-decisions:end -->`). Issue bodies carry the current design contract; pull-request bodies carry pipeline-metrics blocks.

## Repo map

`agents/*.agent.md` are shared, tool-agnostic agent bodies; `agents/{name}.md` (lowercase) are the Claude Code dispatch shells that load them. `skills/` holds the shared methodology, with per-skill `platforms/` notes for tool-specific detail. `Documents/Design/` holds design records. Shorthand like `SMC-NN`, `D1`/`D2`/`D3`, and `CE Gate (Customer Experience Gate)` is decoded at [`HOW-IT-WORKS.md#vocab`](HOW-IT-WORKS.md#vocab).

## Maintenance rule

This file describes shipped behavior only and grows only as future work ships new behavior — no speculative content. Size caps are revisited at each future stage boundary as an explicit decision: evict derivable or restatable content first if new content must be added. The cap itself only rises by explicit deliberate decision, never silently.
