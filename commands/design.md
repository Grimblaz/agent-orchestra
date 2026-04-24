---
description: Invoke Solution-Designer inline — technical design exploration with 3-pass adversarial challenge.
argument-hint: "[issue number]"
---

# /design

Run the Solution-Designer role inline in this conversation for the provided issue.

**Pre-flight**:

1. Require an issue number (the agent needs a durable record to update). If missing, use the `AskUserQuestion` tool.
2. Check the issue's comments/timeline for the `<!-- experience-owner-complete-{ID} -->` marker. If not present, use `AskUserQuestion` to ask whether to run `/experience` first or to proceed without upstream framing.

## Pre-flight (session-startup + provenance-gate)

### Step 4 — Run-once marker (D2 fail-open)

The automatic startup guard records `/memories/session/session-startup-check-complete.md` after the first automatic startup check. Claude Code inline currently lacks a session-memory write surface; the run-once marker is a no-op on this surface. The check still proceeds; the user-friction window is bounded to the first inline command of each new session because the SessionStart hook only injects `additionalContext` on session start.

### Step 6 — Cleanup confirmation

When the SessionStart hook injects `additionalContext`, present that context and ask via `AskUserQuestion` whether to continue with cleanup using these exact option labels:

1. `Yes — run cleanup`
2. `No — skip for now`

If `additionalContext` is absent, emit a single line saying `no stale state detected` and continue.

### Step 7b — Drift check

On Claude Code, run the plugin drift check after the cleanup path completes. If the installed plugin is behind the marketplace version, emit the update summary and ask via `AskUserQuestion` with these exact option labels:

1. `Stop — I'll restart now`
2. `Continue — run under old code`

If Claude is running headless and cannot ask a structured question, emit the update result inline and continue.

### Step 9 — Paired-body halt-on-fail

Read `agents/Solution-Designer.agent.md` before adopting the role. If that load fails, emit exactly: `⚠️ Shared-body load failed for agents/Solution-Designer.agent.md — {error}. This run cannot continue without the canonical methodology; surface this to the user and stop.`

### Provenance-gate

For existing GitHub issues, load `skills/provenance-gate/SKILL.md` and evaluate the cold-pickup trigger conditions exactly as written there. Warm handoffs are limited to the documented markers `<!-- experience-owner-complete-{ID} -->`, `<!-- design-phase-complete-{ID} -->`, `plan-issue-{ID}`, `design-issue-{ID}`, and `<!-- first-contact-assessed-{ID} -->`.

When the gate applies, run the three-question assessment, then present the developer gate via `AskUserQuestion` with these exact option labels:

1. `I wrote this / I'm fully briefed`
2. `Assessment looks right - proceed with caution`
3. `Needs rework - stop here`

After any response except `Needs rework - stop here`, record the marker `<!-- first-contact-assessed-{ID} -->` via `gh issue comment`.

<!-- D6 (issue #412): Copilot's .github/prompts/*.prompt.md files are thin one-line dispatchers without a parent-side prose surface. Inline-dispatch enforcement on Copilot is owned by the agent body and tracked in #414. -->

**Inline execution**:

Read `agents/Solution-Designer.agent.md` and adopt that role for the rest of this conversation. Follow all methodology sections, run the 3-pass non-blocking design challenge, and persist the design in the issue body with a `<!-- design-phase-complete-{ID} -->` comment marker.

ARGUMENTS: $ARGUMENTS
