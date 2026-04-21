# Platform — Claude Code

This skill is `scope: claude-only`. The handshake contract exists specifically for the Claude Code `Agent` tool's dispatch model, where subagents share the parent's live working tree by default but receive a small `<env>` block (working dir, branch, status, recent commits) injected **once at dispatch time** and never refreshed. Tree-grounded claims that trust the injected `<env>` can silently diverge from the parent's actual tree.

## Parent-side invocation

Parents that dispatch tree-dependent subagents via the `Agent` tool construct the handshake block and prepend it as the first content of the `prompt` parameter. Two equivalent carriers:

1. **PowerShell helper** — dot-source `skills/subagent-env-handshake/scripts/New-SubagentDispatchPrompt.ps1` and call `New-SubagentDispatchPrompt` with live values from `git rev-parse HEAD`, `git rev-parse --abbrev-ref HEAD`, `pwd`, and `Get-DirtyTreeFingerprint`.
2. **Inline prose template** — when the dispatch site is markdown that cannot invoke PowerShell (e.g., `commands/plan.md`), copy the template verbatim from `SKILL.md` and substitute Bash-captured values.

Field names and order must match the schema block in `SKILL.md`. The schema-parity Pester test at `.github/scripts/Tests/subagent-env-handshake.Tests.ps1` locks drift.

## Subagent-side invocation

Subagent Claude shells (e.g., `agents/issue-planner.md`) add a `## Step 0: Environment Handshake Verification` H2 that runs before shared-body load. The section parses the handshake block, live-verifies via `Bash`-tool `git` commands, and branches per the match / mismatch / error contract in `SKILL.md`.

The `claude-shell-parity` bijection test enforces parity on backtick-enumerated tokens inside the `## Shared methodology` enumeration paragraph only, not on all shell H2s, so adding the Step 0 H2 does not break parity provided the ordering is: canonical session-startup stub → Step 0 → `## Shared methodology`.

## Copilot exemption

Copilot's subagent dispatch model shares the parent workspace with different tool bindings; tree-view divergence does not arise. No Copilot platform file exists for this skill.
