---
description: Invoke Experience-Owner inline — customer framing upstream or CE Gate evidence capture downstream.
argument-hint: "[issue number or short description of what needs customer framing]"
---

# /experience

Run the Experience-Owner role inline in this conversation for the provided issue (upstream framing or CE Gate evidence capture).

**Pre-flight**:

1. If the arguments reference an existing GitHub issue (e.g., `#369` or a URL), include that context.
2. If there are no arguments, use the `AskUserQuestion` tool to ask whether this is upstream framing (issue to frame) or downstream CE Gate (issue with a branch ready to exercise).

## Pre-flight (session-startup + provenance-gate)

Load `skills/session-startup/SKILL.md` and follow Steps 4, 6, 7b, and 9 (paired body for Step 9: `agents/Experience-Owner.agent.md`).

Then load `skills/provenance-gate/SKILL.md` and follow its protocol for any GitHub-issue-referencing argument.

### Step 9 — Paired-body halt-on-fail

Resolve and read `agents/Experience-Owner.agent.md` before adopting the role. Use the D1 plugin-cache-first body resolution sequence: first read `~/.claude/plugins/installed_plugins.json` and use the `installPath` for `agent-orchestra@agent-orchestra` to load `agents/Experience-Owner.agent.md`; if that registry entry is missing or unusable, fall back to the newest SemVer-sorted match for `~/.claude/plugins/cache/agent-orchestra/agent-orchestra/*/agents/Experience-Owner.agent.md`; only after those plugin-cache paths fail, allow a source-repo CWD read of `agents/Experience-Owner.agent.md` when `.claude-plugin/plugin.json` exists in the current repo and declares `name: agent-orchestra`. If every candidate load fails, emit exactly: `⚠️ Shared-body load failed for agents/Experience-Owner.agent.md — {error}. This run cannot continue without the canonical methodology; surface this to the user and stop.` The remediation command is `claude plugin install agent-orchestra@agent-orchestra`.

<!-- D6 (issue #412): Copilot's .github/prompts/*.prompt.md files are thin one-line dispatchers without a parent-side prose surface. Inline-dispatch enforcement on Copilot is owned by the agent body and tracked in #414. -->

**Inline execution**:

Use the resolved `agents/Experience-Owner.agent.md` shared body and adopt that role for the rest of this conversation. Follow all methodology sections, load the relevant skills, and persist results via GitHub issue comments.

ARGUMENTS: $ARGUMENTS
