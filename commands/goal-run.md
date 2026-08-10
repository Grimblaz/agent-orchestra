---
description: "Launch or resume the vendor-goal-loop harness (Arm I) for a single GitHub issue carrying an approved goal-contract"
argument-hint: "Single issue number (e.g. issue #874), optionally followed by the operator lever `adopt` or `restart`"
model: sonnet
effort: high
---

# /goal-run

<!-- scope: claude-only -->

Run the Goal-Run role inline in this conversation to launch or resume a single issue's approved goal-contract run.

`/goal-run {issue}` is BOTH launcher and resumer: it inspects only durable artifacts (never conversation memory) and enters at the first incomplete stage. This harness runs against exactly one issue's approved goal-contract, not a bundle — accept a single issue number only.

`/goal-run {issue} adopt` and `/goal-run {issue} restart` are the two explicit operator levers (#912 D2/D6): `adopt` force-adopts past a fresh (not-yet-stale) heartbeat that would otherwise refuse a resume — and, honestly, past a completed run too: `adopt` outranks both the liveness check and the completion check in `Resolve-GoalRunInvocationAction`'s precedence, so invoking it on an issue that already shipped a PR (or already has a halt report) relaunches the chain rather than reporting completion. Check for an existing PR or halt report on the issue before using `adopt`. `restart` clears a wedged run's durable markers so a fresh launch is possible again. Both are honored only when the operator typed the literal word — never inferred from any halt or harness state.

**Pre-flight**:

1. Resolve the issue number from `$ARGUMENTS`. If no single issue number is present, ask for one.
2. Resolve an optional second token from `$ARGUMENTS`: `adopt` or `restart`. Any other second token, or more than one extra token, is invalid — report the exact unrecognized text and stop rather than guessing intent. Absent, this is a plain launch/resume invocation with no lever.

## Pre-flight (session-startup)

Load `skills/session-startup/SKILL.md` and follow Steps 4, 6, 7b, and 9 (paired body for Step 9: `agents/Goal-Run.agent.md`).

### Step 9 — Paired-body halt-on-fail

Resolve and read `agents/Goal-Run.agent.md` before adopting the role. Use the D1 resolution order adapted for this command: first read `~/.claude/plugins/installed_plugins.json` and use the `installPath` for `agent-orchestra@agent-orchestra` to load `agents/Goal-Run.agent.md`; if that registry entry is missing or unusable, fall back to the newest SemVer-sorted match for `~/.claude/plugins/cache/agent-orchestra/agent-orchestra/*/agents/Goal-Run.agent.md`; only after those plugin-cache paths fail, allow a source-repo CWD read of `agents/Goal-Run.agent.md` when `.claude-plugin/plugin.json` exists in the current repo and declares `name: agent-orchestra`. If every candidate load fails, emit exactly: `⚠️ Shared-body load failed for agents/Goal-Run.agent.md — {error}. This run cannot continue without the canonical methodology; surface this to the user and stop.` The remediation command is `claude plugin install agent-orchestra@agent-orchestra`.

**Inline execution**:

Use the already resolved `agents/Goal-Run.agent.md` shared body and adopt Goal-Run inline for the rest of this conversation. Follow the loaded shared methodology and pass through the resolved single issue number and the resolved operator-lever token (`adopt` | `restart` | none).

ARGUMENTS: $ARGUMENTS
