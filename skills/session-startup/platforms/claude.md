# Platform — Claude Code

Claude Code receives `session-startup` through the plugin-distributed `SessionStart` hook declared in `hooks/hooks.json`. That hook runs the detector script from the plugin cache and injects any resulting `additionalContext` into the agent's first turn.

When `session-startup` needs user confirmation before running the detector's fenced cleanup commands, Claude Code agents invoke the `AskUserQuestion` tool. Present the detector's `additionalContext` text and offer two options:

1. `Yes — run cleanup`
2. `No — skip for now`

For the Claude-only drift-check sub-step, use the same `AskUserQuestion` tool with these exact option labels:

1. `Stop — I'll restart now`
2. `Continue — run under old code`

Before the drift-check reads the marketplace view, run `claude plugin marketplace update` with a 5-second timeout. On timeout, non-zero exit, or unavailable `claude` CLI, fail open by emitting `marketplace freshness check failed — using cached view` and continue using the cached marketplace view. Do not retry transient marketplace freshness failures within the 5-second budget; the existing later `claude plugin update agent-orchestra@agent-orchestra --yes` retry/timeout path remains independent. This freshness step shares the existing Step 4 run-once marker; do not add a second marker or persistence mechanism.

Silent skip remains for setup/environment failures such as `pwsh` missing; `claude` execution failures emit the fail-open notice above. For marketplace registrations in the local-path branch (non-git local directory or dirty/detached HEAD), suppress the freshness emit because the existing classification surfaces remediation. The verified-current silence guarantee applies only on the freshness-success branch; freshness failure uses cached comparison as a documented accepted limitation. Headless Claude runs perform the same freshness attempt and same fail-open emission; only the post-drift stop/continue prompt is suppressed in headless mode.

If Claude is running headless and cannot ask a structured question, skip the prompt and emit the update result inline instead.

> **D3b exemption**: `session-startup/SKILL.md` intentionally retains this methodology verbatim (see `path-migration-sweep-gate.Tests.ps1` D3b whitelist). The platform file documents the Claude Code-specific tool invocation without duplicating the full protocol.
