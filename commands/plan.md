---
description: Invoke Issue-Planner — produce an implementation plan with CE Gate coverage and the full adversarial review pipeline.
argument-hint: "[issue number]"
---

# /plan

> Auto-mode boundary: see [CLAUDE.md § Auto-mode boundary](/CLAUDE.md#auto-mode-boundary). Auto-mode does not suppress `AskUserQuestion`.

<!-- scope: claude-only -->

Run the Issue-Planner role inline in this conversation to produce an implementation plan for the provided issue.

**Pre-flight**:

1. Require an issue number (the plan is posted as a durable comment on that issue). If missing, use the `AskUserQuestion` tool.
2. Check the issue's comments/timeline for the `<!-- design-phase-complete-{ID} -->` marker (design completion lives on a comment, not in the issue body). If the marker is not present on the issue, use `AskUserQuestion` to ask whether to run `/design` first or to plan from whatever framing already exists.

## Pre-flight (session-startup)

Load `skills/session-startup/SKILL.md` and follow Steps 4, 6, 7b, and 9 (paired body for Step 9: `agents/Issue-Planner.agent.md`).

### Step 9 — Paired-body halt-on-fail

Resolve and read `agents/Issue-Planner.agent.md` before adopting the role. Use the D1 plugin-cache-first body resolution sequence: first read `~/.claude/plugins/installed_plugins.json` and use the `installPath` for `agent-orchestra@agent-orchestra` to load `agents/Issue-Planner.agent.md`; if that registry entry is missing or unusable, fall back to the newest SemVer-sorted match for `~/.claude/plugins/cache/agent-orchestra/agent-orchestra/*/agents/Issue-Planner.agent.md`; only after those plugin-cache paths fail, allow a source-repo CWD read of `agents/Issue-Planner.agent.md` when `.claude-plugin/plugin.json` exists in the current repo and declares `name: agent-orchestra`. If every candidate load fails, emit exactly: `⚠️ Shared-body load failed for agents/Issue-Planner.agent.md — {error}. This run cannot continue without the canonical methodology; surface this to the user and stop.` The remediation command is `claude plugin install agent-orchestra@agent-orchestra`.

<!-- D6 (issue #412): Copilot's .github/prompts/*.prompt.md files are thin one-line dispatchers without a parent-side prose surface. Inline-dispatch enforcement for /experience, /design, and /plan on Copilot is owned by the agent body and tracked in #414. -->

**Inline execution**:

Use the resolved `agents/Issue-Planner.agent.md` shared body and adopt that role for the rest of this conversation. Follow all methodology sections, load the relevant skills, run plan approval inline, and persist the approved plan via the platform-appropriate plan path.

## Inline adversarial-pipeline dispatch

Select the adapter from the draft plan's shape (#936 D5, landing sites per #936 DA4):

- A plan whose frontmatter declares `plan-variant: brief` — the chunk-plan shape — uses adapter `design-challenge`: three prosecution-only lenses, no defense, no judge. Run the `#### Brief conformance check` from `skills/plan-authoring/SKILL.md` › `### Brief plan variant` before dispatching, and require the reviewer to run it as the first act of the review. Do not edit `skills/adversarial-review/adapters/standard.md` to achieve this — that is the code-review adapter, and re-aiming plan review by changing its pass count would relax every code review over its size threshold.
- Every other plan shape uses adapter `standard`.

Read `skills/adversarial-review/platforms/claude.md` and follow its parent-side dispatcher checklist as a thin caller with the selected adapter. Pass the resolved issue number, issue body, Experience-Owner framing, Solution-Designer output, current draft plan, project guidance, and any prior plan-review context as the pre-dispatch context. The shared checklist owns handshake construction, prosecution, merge, defense, judge, partial-pass recovery, atomic marker emission, and review-state persistence.

ARGUMENTS: $ARGUMENTS
