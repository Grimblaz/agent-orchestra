---
description: "GitHub review intake through Code-Conductor, including proxy prosecution for PR review reconciliation."
argument-hint: "[optional PR number; defaults to active PR for current branch]"
model: sonnet
effort: medium
---

# /review-github

<!-- scope: claude-only -->

Run the Code-Conductor role inline in this conversation for GitHub review intake and proxy prosecution against a resolved pull request.

**Pre-flight**:

1. Resolve the pull request context from the arguments. If `$ARGUMENTS` contains a PR number, use it as `$PR_NUMBER`.
2. If no PR number was supplied, run `gh pr view --json number --jq '.number'` to resolve the active PR for the current branch and use the returned value as `$PR_NUMBER`.
3. If `gh pr view` exits non-zero because there is no PR for the current branch, the worktree is in detached HEAD, or a fork branch has no upstream PR, use the `AskUserQuestion` tool to ask the user for a PR number. Do not silently fall through to local code review.

## Pre-flight (session-startup)

Load `skills/session-startup/SKILL.md` and follow Steps 4, 6, 7b, and 9 (paired body for Step 9: `agents/Code-Conductor.agent.md`).

### Step 9 — Paired-body halt-on-fail

Resolve and read `agents/Code-Conductor.agent.md` before adopting the role. Use the D1 resolution order adapted for this command: first read `~/.claude/plugins/installed_plugins.json` and use the `installPath` for `agent-orchestra@agent-orchestra` to load `agents/Code-Conductor.agent.md`; if that registry entry is missing or unusable, fall back to the newest SemVer-sorted match for `~/.claude/plugins/cache/agent-orchestra/agent-orchestra/*/agents/Code-Conductor.agent.md`; only after those plugin-cache paths fail, allow a source-repo CWD read of `agents/Code-Conductor.agent.md` when `.claude-plugin/plugin.json` exists in the current repo and declares `name: agent-orchestra`. If every candidate load fails, emit exactly: `⚠️ Shared-body load failed for agents/Code-Conductor.agent.md — {error}. This run cannot continue without the canonical methodology; surface this to the user and stop.` The remediation command is `claude plugin install agent-orchestra@agent-orchestra`.

**Inline execution**:

Adopt the resolved Code-Conductor body inline. Process this invocation as `review github`: enter the GitHub intake path described in `agents/Code-Conductor.agent.md ## Review Reconciliation Loop (Mandatory)` and `skills/code-review-intake/SKILL.md`. Use the active-PR resolution result from pre-flight as `$PR_NUMBER`.

## Downstream Agent handshakes

Before each downstream `Agent` dispatch, reconstruct a fresh `subagent-env-handshake` by capturing live HEAD, branch, CWD, and dirty fingerprint immediately before that dispatch. The working tree mutates during orchestration, so do not reuse or carry forward a command-entry-captured handshake, a single entry-time handshake, or any earlier per-dispatch block for later specialist calls.

Construct each downstream handshake from `skills/subagent-env-handshake/SKILL.md` using the schema and inline prose template there, and prepend it as the first content of the `prompt` parameter for tree-dependent specialist `Agent` calls. If the live capture fails, skip that handshake and let the target specialist's Step 0 missing-handshake branch handle the fallback.

ARGUMENTS: $ARGUMENTS
