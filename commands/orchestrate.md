---
description: "Invoke Code-Conductor — run the full orchestration pipeline for one or more GitHub issues: scope classification, smart resume, D9 checkpoint, implementation, review, PR."
argument-hint: "Single issue (e.g. issue #177) or multiple issues (e.g. issues #177 #178 #179)"
model: sonnet
effort: medium
---

# /orchestrate

<!-- scope: claude-only -->

Run the Code-Conductor role inline in this conversation to orchestrate one issue or a coordinated issue bundle.

In Claude Code, `/orchestrate` is also the resume entry point for paused Code-Conductor work. When the shared workflow text mentions resuming with `/implement`, use `/orchestrate` here instead.

**Pre-flight**:

1. Resolve the issue context from the arguments. Accept a single issue number, an issue URL, or a multi-issue bundle. If the arguments do not identify at least one issue, use the `AskUserQuestion` tool.
2. For each resolved issue, check the issue's comments/timeline for the smart-resume markers `<!-- plan-issue-{ID} -->`, `<!-- design-issue-{ID} -->`, `<!-- design-phase-complete-{ID} -->`, and `<!-- experience-owner-complete-{ID} -->`; SMC-08 governs these durable phase-completion markers.
3. If any resolved issue is missing its `<!-- plan-issue-{ID} -->` marker, do not block dispatch. Carry the resolved issue list and marker status into the inline orchestration context so Code-Conductor can either resume from the most advanced durable artifact available or continue fresh hub-mode execution and call Issue-Planner itself. SMC-01 governs the plan-marker resume path, and SMC-03 governs the design fallback chain: parent dispatch context when available, latest durable `<!-- design-issue-{ID} -->` issue comment, then issue body. Include whether a durable `<!-- design-issue-{ID} -->` handoff already exists for D9 suppression and full-pipeline resume.

## Pre-flight (session-startup + provenance-gate)

Load `skills/session-startup/SKILL.md` and follow Steps 4, 6, 7b, and 9 (paired body for Step 9: `agents/Code-Conductor.agent.md`).

Then load `skills/provenance-gate/SKILL.md` and follow its protocol for any GitHub-issue-referencing argument.

### Step 9 — Paired-body halt-on-fail

Resolve and read `agents/Code-Conductor.agent.md` before adopting the role. Use the D1 resolution order adapted for this command: first read `~/.claude/plugins/installed_plugins.json` and use the `installPath` for `agent-orchestra@agent-orchestra` to load `agents/Code-Conductor.agent.md`; if that registry entry is missing or unusable, fall back to the newest SemVer-sorted match for `~/.claude/plugins/cache/agent-orchestra/agent-orchestra/*/agents/Code-Conductor.agent.md`; only after those plugin-cache paths fail, allow a source-repo CWD read of `agents/Code-Conductor.agent.md` when `.claude-plugin/plugin.json` exists in the current repo and declares `name: agent-orchestra`. If every candidate load fails, emit exactly: `⚠️ Shared-body load failed for agents/Code-Conductor.agent.md — {error}. This run cannot continue without the canonical methodology; surface this to the user and stop.` The remediation command is `claude plugin install agent-orchestra@agent-orchestra`.

**Inline execution**:

Use the already resolved `agents/Code-Conductor.agent.md` shared body and adopt Code-Conductor inline for the rest of this conversation. Follow the loaded shared methodology, pass through the resolved issue or bundle context, preserve the smart-resume marker status, and carry `$ARGUMENTS` into the orchestration run.

## Downstream Agent handshakes

Before each downstream `Agent` dispatch, reconstruct a fresh `subagent-env-handshake` by capturing live HEAD, branch, CWD, and dirty fingerprint immediately before that dispatch. The working tree mutates during orchestration, so do not reuse or carry forward a command-entry-captured handshake, a single entry-time handshake, or any earlier per-dispatch block for later specialist calls.

Construct each downstream handshake from `skills/subagent-env-handshake/SKILL.md` using the schema and inline prose template there, and prepend it as the first content of the `prompt` parameter for tree-dependent specialist `Agent` calls. If the live capture fails, skip that handshake and let the target specialist's Step 0 missing-handshake branch handle the fallback.

ARGUMENTS: $ARGUMENTS
