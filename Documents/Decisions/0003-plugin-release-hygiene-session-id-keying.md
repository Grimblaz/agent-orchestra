# ADR-0003: Plugin Release Hygiene Session-ID Keying

**Date**: 2026-04-25
**Status**: Accepted
**Context**: Issue #422 — suppress repeated plugin release hygiene warning spam after the first relevant entry-point edit.

## Context

The release-hygiene hook is intended to emit one meaningful warning for the first relevant entry-point edit, then stay silent for later edits in the same session. In practice the hook keyed `.claude/.state/release-hygiene-{slug}.json` from branch state alone, so branch changes or detached-head fallback could produce a fresh "first warning" inside the same Claude conversation.

The shared skill guidance also promised silence once the working tree version was already ahead of `main`, but the hook had not implemented that short-circuit.

## Decision

Claude Code uses the PostToolUse payload's `session_id` as the primary source for the release-hygiene state-file slug. When `session_id` is absent, the hook falls back to the existing branch-derived slug. In detached HEAD, the hook falls back to the short HEAD SHA before using `session` as the last resort.

Each persisted release-hygiene state file records the active keying path in `keying_strategy` with one of these exact values:

- `session_id`
- `branch_slug`
- `session_fallback`

The hook also exits silently when the managed version-bearing files are internally lockstep and ahead of the resolved default branch. If the comparison fails because the baseline branch is missing, the version set is incomplete, or parsing fails, the hook fails open and preserves the previous first-warning behavior.

Copilot remains branch-keyed because the instruction surface does not expose a Claude-style stable conversation identifier.

## Rationale

- `session_id` is the smallest mechanism that matches the intended Claude conversation scope.
- Keeping the branch fallback preserves current behavior for manual invocation and payload drift.
- Recording `keying_strategy` makes the active path directly testable.
- The version-bump short-circuit restores behavior already documented by the skill.

## Consequences

### Positive

- Claude conversations coalesce repeated entry-point edits even across branch changes when the same `session_id` is present.
- Maintainers do not see an unnecessary first-warning banner once the required version bump already exists in the working tree.
- Tests and reviews can inspect the chosen keying path directly.

### Negative

- Platform behavior diverges intentionally: Claude is conversation-keyed when possible; Copilot is branch-keyed.
- Linked worktrees that share the same git common directory now reuse one `.claude/.state/` location for the same Claude conversation.

## Deferred Follow-Up

TTL pruning for stale `release-hygiene-*.json` files is deferred to a separate tracked issue. The existing session-startup cleanup detector already owns stale-branch and tracking-artifact cleanup; extending it for TTL-based release-hygiene pruning would widen issue #422 beyond the warning-spam regression.

## References

- Issue #422
- `skills/plugin-release-hygiene/SKILL.md`
- `skills/plugin-release-hygiene/platforms/claude.md`
- `skills/plugin-release-hygiene/platforms/copilot.md`
- `skills/plugin-release-hygiene/scripts/plugin-release-hygiene-hook.ps1`
- `.github/scripts/Tests/plugin-release-hygiene.Tests.ps1`
