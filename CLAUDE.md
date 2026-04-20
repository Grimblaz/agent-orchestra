# Agent Orchestra — Claude Code Guide

Agent Orchestra is a multi-agent workflow system originally built for GitHub Copilot and now available to Claude Code through the same plugin.

## Quick start

Install the plugin from the marketplace if you have not already. Run this inside Claude Code (not a system shell):

```text
/plugin install agent-orchestra@agent-orchestra
```

The plugin exposes three upstream agents — the full set a feature needs from intake through planning — plus a library of shared skills. Claude Code discovers them automatically once the plugin is installed.

## Upstream pipeline

Three agents cover the journey from an issue on the board to an implementation-ready plan. They call each other through durable GitHub-issue markers so a session can span multiple conversations or switch between Copilot and Claude Code.

1. **Experience-Owner** — frames the work in customer language. Writes the problem statement, user journeys, scenarios, and surface/readiness assessment into the issue body. Activated with `/experience` or via the subagent name.
2. **Solution-Designer** — runs technical design exploration and the 3-pass non-blocking design challenge. Updates the issue body with decisions, acceptance criteria, and rejected alternatives. Activated with `/design` or via the subagent name.
3. **Issue-Planner** — produces the implementation plan with CE Gate coverage and the full adversarial review pipeline (prosecution × 3 → defense → judge). Persists the approved plan as a GitHub issue comment with a `<!-- plan-issue-{ID} -->` marker. Activated with `/plan` or via the subagent name.

Each agent reads a shared tool-agnostic body from `agents/*.agent.md` and follows the named skills for methodology. Claude-specific tool bindings (structured questions, subagent dispatch, `gh` CLI for GitHub work) are documented in each skill's `platforms/claude.md`.

## Cross-tool handoffs

Handoffs between phases use durable GitHub issue comments rather than session-local state. Markers:

- `<!-- experience-owner-complete-{ID} -->` — upstream framing complete
- `<!-- design-phase-complete-{ID} -->` — technical design complete
- `<!-- plan-issue-{ID} -->` — approved plan persisted
- `<!-- first-contact-assessed-{ID} -->` — provenance gate completed for a cold pickup

Because the markers live on the issue, you can start a feature in Copilot, pick it up in Claude Code, and vice versa without losing context.

## Session startup

When a session begins, the agent loads the `session-startup` skill. The skill checks for stale tracking artifacts from merged pull requests and offers to run the post-merge cleanup script when anything is found. The detector is run-once per conversation; manual detector runs remain available after the automatic check fires.

## Where things live

- `agents/*.agent.md` — shared, tool-agnostic agent bodies used by both Copilot and Claude Code (capitalized filename, `.agent.md` extension)
- `agents/{name}.md` — Claude-native subagent shells that point at the shared bodies (lowercase filename, plain `.md`)
- `commands/` — slash commands at plugin root (`/experience`, `/design`, `/plan`)
- `skills/` — reusable methodology loaded by both platforms; each skill has `platforms/claude.md` for Claude-specific invocation details
- `platforms/` (at skill root) — platform-specific routing notes

## Not yet ported

Phase 1 covers only the upstream agents. The implementation and review side — **Code-Conductor**, **Code-Smith**, **Code-Critic**, **Test-Writer**, **Doc-Keeper**, **Refactor-Specialist**, **Review-Response**, and **Process-Review** — is tracked in Phase 2 ([issue #379](https://github.com/Grimblaz/agent-orchestra/issues/379)) and later phases. Until they ship, use Claude Code directly or fall back to Copilot once the plan has been approved.

## Issue #369 traces the full history

See [issue #369](https://github.com/Grimblaz/agent-orchestra/issues/369) for the full design discussion, customer framing, and plan that produced this Claude Code integration.
