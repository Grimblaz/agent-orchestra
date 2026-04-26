---
name: session-startup
description: "Automatic startup cleanup guard for new conversations. Use when deciding whether to run the session cleanup detector before the first reply, handling stale-state prompts, or preserving run-once startup semantics. DO NOT USE FOR: post-merge archival workflows (use post-pr-review) or general workflow troubleshooting outside startup detection (use process-troubleshooting)."
---

# Session Startup

Run-once startup guard for the automatic session-cleanup detector.

## When to Use

- When the SessionStart hook injects `additionalContext` into the agent's first turn
- When deciding whether the automatic startup detector should run
- When interpreting stale-state detector output and optionally running cleanup
- When checking whether the installed Claude plugin version has drifted behind the marketplace
- When preserving manual detector access after the automatic startup path fires

## Purpose

The trigger mechanism is now a plugin-distributed `hooks/hooks.json` SessionStart hook rather than an LLM-interpreted per-agent directive. Apply a session-memory run-once guard after that hook fires so the detector runs at most once automatically per conversation while remaining available for explicit manual use. The same run-once pass also owns the Claude-only plugin drift backstop: when `agent-orchestra@agent-orchestra` is installed but behind the resolved marketplace version, surface the update result and a restart-vs-continue decision without blocking the session on failures.

## Session Startup Check

Follow these steps exactly.

> **Survival**: `SMC-07` owns the startup run-once marker. Hook-driven marker writes are `within-conversation:hooks`; the honest gaps are the inline run-once marker write, the inline-vs-subagent enforcement split, and the headless-Claude prompt skip. Do not add a second marker or new persistence mechanic.

### Canonical Automatic Startup Guard Contract

```json
{
  "sessionStartupMarkerPath": "/memories/session/session-startup-check-complete.md",
  "checkMarkerBeforeAutomaticDetectorRun": true,
  "recordMarkerAfterFirstAutomaticStartupCheck": true,
  "recordMarkerRegardlessOfCleanupChoice": true,
  "failOpenOnSessionMemoryAccessError": true,
  "manualDetectorRunsRemainAllowed": true,
  "confirmSharedBodyLoadForAgentShells": true
}
```

### Step 1 — Check prerequisites

For automatic startup runs, first use any hook-injected `additionalContext` if it is already present in the agent's first turn. Resolve the detector script path relative to this skill file for manual fallback: the wrapper at `scripts/session-cleanup-detector.ps1` (in this skill's directory) self-resolves its repo root via `$PSScriptRoot`, so no environment variables are required. If `pwsh` is unavailable or the script is missing, skip the entire check silently and continue with the user's request.

### Step 2 — Check the automatic run-once guard

Before any automatic startup detector run, check session memory for the marker at `/memories/session/session-startup-check-complete.md`. If that marker is present, skip the automatic detector run and continue silently with the user's request. If session-memory lookup, read, or other access fails, fail open and still run the detector rather than suppressing the check.

### Step 3 — Run the detector script

For automatic startup runs, the plugin-distributed SessionStart hook runs the detector before the agent sees the user's request and injects the resulting `additionalContext`. This step preserves the manual fallback command contract and any contributor-side direct invocation. The wrapper self-resolves its repo root via `$PSScriptRoot`, so no env vars are needed — but the terminal's working directory in a consumer repo is usually the consumer's workspace, **not** the orchestra plugin. Invoke the script by a path that resolves from wherever the `agent-orchestra` content actually lives.

**Repo clone** (contributors, CWD is the repo root — relative path works):

```powershell
pwsh -NoProfile -NonInteractive -File "skills/session-startup/scripts/session-cleanup-detector.ps1"
```

**Plugin-cache install** (Copilot or Claude Code consumers, CWD is the consumer workspace — pass the plugin's absolute path). Resolve the plugin directory from the installed plugin cache rather than any `chat.*Locations` setting (Copilot: the VS Code `agentPlugins/.../agent-orchestra` cache path under the active product profile; Claude Code: `<plugins-cache-root>/agent-orchestra/`), then:

```powershell
pwsh -NoProfile -NonInteractive -File "<plugin-root>/skills/session-startup/scripts/session-cleanup-detector.ps1"
```

If neither path resolves (the script is genuinely missing), skip the check silently per Step 1.

### Step 4 — Record the run-once marker

Record or write the session-memory marker at `/memories/session/session-startup-check-complete.md` after the first automatic startup check runs so later agent hops in the same conversation skip the automatic detector run. Record the marker regardless of whether cleanup is needed and regardless of whether the user later confirms, declines, or skips cleanup. If session-memory write or other access fails, fail open: continue with the detector result you already obtained, and allow later automatic checks rather than risking a missed cleanup warning.

### Step 5 — Parse the output

The detector returns one of two JSON shapes.

**No stale state found**: continue silently and do not mention the check to the user.

```json
{}
```

**Stale state found**: prompt the user.

````json
{
  "hookSpecificOutput": {
    "hookEventName": "SessionStart",
    "additionalContext": "**Post-merge cleanup detected** - stale tracking artifacts found:\n\n- `.copilot-tracking/issue-42-my-feature.yml`\n\nTo clean up, run:\n```powershell\n# Run in a PowerShell (pwsh) terminal:\npwsh '/path/to/agent-orchestra/skills/session-startup/scripts/post-merge-cleanup.ps1' -IssueNumber 42 -FeatureBranch 'feature/issue-42-my-feature'\n```\n"
  }
}
````

The `additionalContext` field is a Markdown-formatted description of what was found plus the command block to clean it up.

### Step 6 — Prompt the user

If the output contains `hookSpecificOutput`, present the `additionalContext` text to the user and ask for confirmation before running cleanup. Use `#tool:vscode/askQuestions` with two options: "Yes — run cleanup" and "No — skip for now".

### Step 7 — Run cleanup (only if confirmed)

If the user confirms, run all lines from the code block inside `additionalContext` in the terminal. Skip blank lines; `#`-prefixed comment lines are safe to include. Report what was cleaned up when complete.

### Step 7b — Run the Claude plugin drift check

After the cleanup path completes, run this Claude-only sub-step before continuing with the user's request. Copilot skips this sub-step silently because it has no version-cache analog.

1. Resolve the installed plugin state from `~/.claude/plugins/installed_plugins.json`.
2. Find the `agent-orchestra@agent-orchestra` entry and read its installed `version` plus `marketplace` field.
3. If the file is missing, the entry is absent, or the entry has no `marketplace` field, fail open: silent-skip or emit a one-line minimal error and continue.
4. Resolve the marketplace view of latest from `~/.claude/plugins/marketplaces/{marketplace}/.claude-plugin/plugin.json`.
5. If the installed version is current, continue silently.
6. If the installed version is behind, emit an inline status line before any command runs: `Drift detected — updating…`
7. Run `claude plugin update agent-orchestra@agent-orchestra --yes` with a 30-second timeout.
8. On success, emit the inline summary `Updated 'agent-orchestra@agent-orchestra' from {old} -> {new}. Current session runs under old code until restart.` and ask the user to choose one of these exact options: `Stop — I'll restart now` or `Continue — run under old code`.
9. After the choice, acknowledge the selected mode explicitly. If the user continues, say that the new code goes live next session and then continue with the original request.
10. If the update fails, retry once on transient errors. If it still fails, fail open with a minimal error plus the manual fallback command, then continue under the installed version.

When the marketplace registration points at a local path instead of a GitHub remote, classify it before running the update:

- Clean git repo behind `origin/main`: surface that the marketplace path is behind and include the remediation commands `claude plugin marketplace remove agent-orchestra` and `claude plugin marketplace add Grimblaz/agent-orchestra`
- Non-git local directory: surface that the registration is a non-git local directory
- Dirty tree or detached HEAD: surface that local marketplace remediation is skipped because the clone has local work
- Fetch failure: fail open and continue

Headless Claude runs skip the stop/continue prompt and emit the update result inline only. This sub-step shares the same run-once marker written in Step 4; do not create a second session-startup marker.

### Step 8 — Continue with the user's request

After the automatic startup path is complete, continue with the user's original request only after completing any other applicable startup steps below, including Step 7b and Step 9 when they apply. In hook-driven runs, this means consuming any injected `additionalContext`, recording the run-once marker, and then proceeding. This automatic run-once guard applies only to the cleanup-detector plus Claude drift-check path; explicit or manual detector runs still remain allowed after the automatic guard fires.

### Step 9 — Confirm paired shared-body load (agent shells with a paired body)

This step is not gated by the session-startup run-once marker and fires on every agent-role adoption in the conversation, including every subagent dispatch. Do not wrap this step in the Step 2 or Step 4 marker guard.

If you are operating as an agent shell at `agents/{name}.md` whose body contains a `## Shared methodology` section naming a paired `agents/{Name}.agent.md`, load that paired file via the platform's file-read tool before proceeding.

If that load fails, emit exactly: `⚠️ Shared-body load failed for agents/{Name}.agent.md — {error}. This run cannot continue without the canonical methodology; surface this to the user and stop.` After emitting that message, do not make any further tool calls, subagent dispatches, structured-question calls, or any other agent actions.

If the paired load succeeds, cite it with `Shared body loaded — proceeding as {AgentName}` and include the full-form H2 body names exactly as they appear in the shared body, excluding `Platform-specific invocation`.

If you are not in a paired-body context, skip this step silently.

If the same shared body is loaded more than once in a conversation, the load is idempotent — loading the same file a second time is harmless and does not require deduplication logic.

### Inline-Dispatch Option Labels

```yaml
canonical_option_labels:
  cleanup_yes: "Yes — run cleanup"
  cleanup_no: "No — skip for now"
  drift_stop: "Stop — I'll restart now"
  drift_continue: "Continue — run under old code"
```

Enforcement paths: subagent dispatch (`/plan` and Agent tool) is enforced by Step 9 — this step fires before the agent acts and halts on failure. Inline dispatch now has command-file contract enforcement for the paired-body read requirement and fail-closed error text on `/experience` and `/design`, plus startup option-label parity across all three Claude command files from issue #412. That path still does not have full Step 9 success-path citation parity, and `/plan` continues to defer paired-body halt-on-failure enforcement to the `issue-planner` subagent shell rather than duplicating it in the parent command file.

## Silent Skip Conditions

Skip the entire check silently in any of these cases:

- `pwsh` is not available on `PATH`
- The detector script does not exist at the expected path
- The detector script returns an error or non-JSON output

These are normal conditions in repos that have not installed the agent-orchestra plugin or in environments where PowerShell is unavailable.

## Gotchas

| Trigger                            | Gotcha                                                                                | Fix                                                                                         |
| ---------------------------------- | ------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------- |
| Session memory read or write fails | Suppressing the detector would hide cleanup warnings for the rest of the conversation | Fail open: still run or keep the existing detector result, and allow later automatic checks |

| Trigger                                     | Gotcha                                                                              | Fix                                                                                   |
| ------------------------------------------- | ----------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------- |
| Running the detector manually after startup | Treating the run-once guard as a global prohibition blocks legitimate manual checks | Keep manual detector runs available; the guard only limits the automatic startup path |

---

> **D3b soft exemption**: unlike the other five platform-split skills, this SKILL.md retains Copilot-specific invocation details (see §Trigger) because the session-startup trigger path is Copilot-native. The canonical routing footer below still applies and is byte-identical across all six split skills; the exemption is specific to this skill's Trigger section, not the footer.

## Platform-specific invocation

This skill's methodology is tool-agnostic. Platform-specific routing lives alongside:

- Copilot: [platforms/copilot.md](platforms/copilot.md)
- Claude Code: [platforms/claude.md](platforms/claude.md)
