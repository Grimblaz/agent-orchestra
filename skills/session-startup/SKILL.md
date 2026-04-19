---
name: session-startup
description: "Automatic startup cleanup guard for new conversations. Use when deciding whether to run the session cleanup detector before the first reply, handling stale-state prompts, or preserving run-once startup semantics. DO NOT USE FOR: post-merge archival workflows (use post-pr-review) or general workflow troubleshooting outside startup detection (use process-troubleshooting)."
---

# Session Startup

Run-once startup guard for the automatic session-cleanup detector.

## When to Use

- At the start of a new conversation before responding to the first user message
- When deciding whether the automatic startup detector should run
- When interpreting stale-state detector output and optionally running cleanup
- When preserving manual detector access after the automatic startup path fires

## Purpose

Apply a session-memory run-once guard before any automatic startup detector invocation so the detector runs at most once automatically per conversation while remaining available for explicit manual use. This replaced the retired VS Code `SessionStart` hook and uses `skills/session-startup/scripts/session-cleanup-detector.ps1` to find stale tracking artifacts from merged pull requests.

## Session Startup Check

Follow these steps exactly.

### Canonical Automatic Startup Guard Contract

```json
{
  "sessionStartupMarkerPath": "/memories/session/session-startup-check-complete.md",
  "checkMarkerBeforeAutomaticDetectorRun": true,
  "recordMarkerAfterFirstAutomaticStartupCheck": true,
  "recordMarkerRegardlessOfCleanupChoice": true,
  "failOpenOnSessionMemoryAccessError": true,
  "manualDetectorRunsRemainAllowed": true
}
```

### Step 1 — Check prerequisites

Resolve the detector script path relative to this skill file: the wrapper at `scripts/session-cleanup-detector.ps1` (in this skill's directory) self-resolves its repo root via `$PSScriptRoot`, so no environment variables are required. If `pwsh` is unavailable or the script is missing, skip the entire check silently and continue with the user's request.

### Step 2 — Check the automatic run-once guard

Before any automatic startup detector run, check session memory for the marker at `/memories/session/session-startup-check-complete.md`. If that marker is present, skip the automatic detector run and continue silently with the user's request. If session-memory lookup, read, or other access fails, fail open and still run the detector rather than suppressing the check.

### Step 3 — Run the detector script

Run the detector wrapper in the terminal. The wrapper self-resolves its repo root via `$PSScriptRoot`, so no env vars are needed — but the terminal's working directory in a consumer repo is usually the consumer's workspace, **not** the orchestra plugin. Invoke the script by a path that resolves from wherever the `agent-orchestra` content actually lives.

**Repo clone** (contributors, CWD is the repo root — relative path works):

```powershell
pwsh -NoProfile -NonInteractive -File "skills/session-startup/scripts/session-cleanup-detector.ps1"
```

**Plugin-cache install** (Copilot or Claude Code consumers, CWD is the consumer workspace — pass the plugin's absolute path). Resolve the plugin directory from the chat/IDE context (Copilot: the `chat.agentFilesLocations` entry; Claude Code: `<plugins-cache-root>/agent-orchestra/`), then:

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

### Step 8 — Continue with the user's request

Continue with the user's original request regardless of whether cleanup was run, skipped, or declined. This automatic run-once guard applies only to the startup path; explicit or manual detector runs still remain allowed after the automatic guard fires.

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
