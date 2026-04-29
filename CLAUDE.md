# Agent Orchestra — Claude Code Guide

Agent Orchestra is a multi-agent workflow system originally built for GitHub Copilot and now available to Claude Code through the same plugin.

## Quick start

Install the plugin from the marketplace if you have not already. Run this inside Claude Code (not a system shell):

```text
/plugin install agent-orchestra@agent-orchestra
```

The plugin exposes the upstream pipeline, the review surface, the `/orchestrate` entry point, and a library of shared skills. Claude Code discovers them automatically once the plugin is installed.

## Upstream pipeline

Three agents cover the journey from an issue on the board to an implementation-ready plan. They call each other through durable GitHub-issue markers so a session can span multiple conversations or switch between Copilot and Claude Code.

1. **Experience-Owner** — frames the work in customer language. Writes the problem statement, user journeys, scenarios, and surface/readiness assessment into the issue body. Activated with `/experience` or via the subagent name.
2. **Solution-Designer** — runs technical design exploration and the 3-pass non-blocking design challenge. Updates the issue body with decisions, acceptance criteria, and rejected alternatives. Activated with `/design` or via the subagent name.
3. **Issue-Planner** — produces the implementation plan with CE Gate coverage and the full adversarial review pipeline (prosecution × 3 → defense → judge). Persists the approved plan as a GitHub issue comment with a `<!-- plan-issue-{ID} -->` marker per `SMC-01`. Activated with `/plan` or via the subagent name.

Each agent reads a shared tool-agnostic body from `agents/*.agent.md` and follows the named skills for methodology. Claude-specific tool bindings (structured questions, subagent dispatch, `gh` CLI for GitHub work) are documented in each skill's `platforms/claude.md`.

## Orchestration

Phase 3 adds Code-Conductor to Claude Code.

- `/orchestrate` dispatches the `code-conductor` shell for the full pipeline from smart resume and plan handoff through implementation, validation, CE Gate, and PR readiness.

For paused Code-Conductor work, `/orchestrate` is also the Claude resume entry point. The shared workflow still uses `/implement` language in Copilot-specific paths, but Claude does not ship a `/implement` command in Phase 3.

The Claude `code-conductor` shell follows the thin-shell convention: it loads the shared `agents/Code-Conductor.agent.md` body and relies on composite skills for the extracted orchestration contracts, so Copilot and Claude stay aligned on one source of truth.

## Review pipeline

Phase 2 adds the `orchestra-review-*` command namespace for Claude-native adversarial review:

- `/orchestra:review` runs the canonical prosecution → defense → judge pipeline.
- `/orchestra:review-lite` runs the small-change variant with one compact prosecution pass before defense and judge.
- `/orchestra:review-prosecute`, `/orchestra:review-defend`, and `/orchestra:review-judge` let power users rerun individual stages.

Handshake disposition by command:

| Command | Handshake |
| --- | --- |
| `/orchestra:review` | Required |
| `/orchestra:review-lite` | Required |
| `/orchestra:review-prosecute` | Required |
| `/orchestra:review-defend` | Required |
| `/orchestra:review-judge` | Optional |

The judge result is designed for same-comment persistence: the completion marker `<!-- code-review-complete-{PR} -->` and the `<!-- judge-rulings ... -->` YAML block travel together in one PR comment so Copilot and Claude Code can consume the same durable artifact.

## Cross-tool handoffs

Handoffs between phases use durable GitHub issue comments rather than session-local state. Markers:

- `<!-- experience-owner-complete-{ID} -->` — upstream framing complete
- `<!-- design-phase-complete-{ID} -->` — technical design complete
- `<!-- design-issue-{ID} -->` — durable design snapshot handoff used for D9 pause/resume and full-pipeline smart resume
- `<!-- plan-issue-{ID} -->` — approved plan persisted
- `<!-- first-contact-assessed-{ID} -->` — provenance-gate marker token for a completed fast-path or cold-path assessment; the optional human-readable second line in that issue comment is decorative only and is not part of skip-check or parser logic

Because the markers live on the issue, you can start a feature in Copilot, pick it up in Claude Code, and vice versa without losing context.

The row-level survival and fallback semantics are governed by [skills/session-memory-contract/SKILL.md](skills/session-memory-contract/SKILL.md). [Documents/Design/session-memory-contract.md](Documents/Design/session-memory-contract.md) explains why Claude keeps durable GitHub markers instead of adding a Claude-only session-memory store.

## Session startup

When a session begins, the plugin's `SessionStart` hook runs the cleanup detector and injects any findings into the agent's first turn. The `session-startup` skill describes how the agent handles that injected context, preserves the run-once marker, and reports current branch, tracking file, sibling worktree, orphan branch, fail-open, and opt-in cleanup behavior. Current-worktree cleanup commands stay as inline manual guidance outside the fenced block; sibling and orphan cleanup commands are fenced and run only after confirmation. Manual detector runs remain available after the automatic check fires.

## Releases

Claude Code keys its plugin cache by the `version` declared in `.claude-plugin/plugin.json`. If an entry-point file changes without a version bump, same-version installs keep serving the older cached snapshot even though the repo changed.

To prevent that, agent-assisted maintainer flows now route entry-point edits through the `plugin-release-hygiene` skill. Claude uses the plugin-distributed `PostToolUse` hook and Copilot uses the root `hooks.json` hook; both follow the same shared release-hygiene guidance. Per `SMC-12`, the silence decision is `session_id`-scoped for Claude when available and branch-scoped for Copilot, so it is shared across tools only when both resolve the same state key.

The `session-startup` skill also owns a Claude-only active-assist drift check. When the installed `agent-orchestra@agent-orchestra` version is behind the resolved marketplace version, the startup pass runs `claude plugin update`, reports the old and new versions, and asks whether to restart now or continue the current session under the old code.

### For maintainers

Supported Claude plugin CLI surface:

```text
claude plugin list
claude plugin marketplace list
claude plugin marketplace update
claude plugin marketplace add <source>
claude plugin marketplace remove <name>
claude plugin update <plugin@marketplace>
claude plugin install <plugin@marketplace>
claude plugin uninstall <plugin@marketplace>
```

## Where things live

- `agents/*.agent.md` — shared, tool-agnostic agent bodies used by both Copilot and Claude Code (capitalized filename, `.agent.md` extension)
- `agents/{name}.md` — Claude-native subagent shells that point at the shared bodies (lowercase filename, plain `.md`)
- `commands/` — slash commands at plugin root (`/experience`, `/design`, `/plan`, `/orchestrate`, `/polish`, `/orchestra:review`, `/orchestra:review-lite`, `/orchestra:review-prosecute`, `/orchestra:review-defend`, `/orchestra:review-judge`)
- `skills/` — reusable methodology loaded by both platforms; each skill has `platforms/claude.md` for Claude-specific invocation details
- `platforms/` (at skill root) — platform-specific routing notes

## Issue #369 traces the full history

See [issue #369](https://github.com/Grimblaz/agent-orchestra/issues/369) for the full design discussion, customer framing, and plan that produced this Claude Code integration.
