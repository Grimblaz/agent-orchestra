# Session Startup Instructions

> **Reference only**: The operational session startup check is inline in `.github/copilot-instructions.md` (Section: "Session Startup Check"). This file documents detailed edge cases and rationale. Agents should follow the inline check; use this file for deeper context.

## Purpose

Instruct agents to apply a session-memory run-once guard before any automatic startup detector invocation, so the session-cleanup detector runs at most once automatically per conversation while remaining available for explicit manual use. This replaces the VS Code `SessionStart` hook, which was retired in issue #109 due to unreliable firing across different repos. The detector is implemented in `.github/scripts/session-cleanup-detector.ps1` and identifies stale tracking files left over from merged pull requests.

## When to Apply

When a user starts a new conversation with you, before responding to their first message, perform the session startup check described below.

## Session Startup Check

Follow these steps exactly:

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

Resolve the root path: use `$env:COPILOT_ORCHESTRA_ROOT` if set; otherwise fall back to `$env:WORKFLOW_TEMPLATE_ROOT`. If neither is set, skip the check entirely and continue silently. Do not mention this to the user.

### Step 2 — Check the automatic run-once guard

Before any automatic startup detector run, check session memory for the marker at `/memories/session/session-startup-check-complete.md`. If that marker is present, skip the automatic detector run and continue silently with the user's request. If session-memory lookup, read, or other access fails, fail open and still run the detector rather than suppressing the check.

### Step 3 — Run the detector script

Run the following command in the terminal, using the root path resolved in Step 1:

```powershell
$copilotRoot = if ($env:COPILOT_ORCHESTRA_ROOT) { $env:COPILOT_ORCHESTRA_ROOT } else { $env:WORKFLOW_TEMPLATE_ROOT }
pwsh -NoProfile -NonInteractive -File "$copilotRoot/.github/scripts/session-cleanup-detector.ps1"
```

This ensures the script is found even when working in a downstream repository (not the copilot-orchestra repo itself).

### Step 4 — Record the run-once marker

Record or write the session-memory marker at `/memories/session/session-startup-check-complete.md` after the first automatic startup check runs so later agent hops in the same conversation skip the automatic detector run. Record the marker regardless of whether cleanup is needed and regardless of whether the user later confirms, declines, or skips cleanup. If session-memory write or other access fails, fail open: continue with the detector result you already obtained, and allow later automatic checks rather than risking a missed cleanup warning.

### Step 5 — Parse the output

The detector returns one of two JSON shapes:

**No stale state found** (continue silently, do not mention to user):

```json
{}
```

**Stale state found** (prompt the user):

````json
{
  "hookSpecificOutput": {
    "hookEventName": "SessionStart",
    "additionalContext": "**Post-merge cleanup detected** — stale tracking artifacts found:\n\n- `.copilot-tracking/issue-42-my-feature.yml`\n\nTo clean up, run:\n```powershell\n# Run in a PowerShell (pwsh) terminal:\npwsh '/path/to/copilot-orchestra/.github/scripts/post-merge-cleanup.ps1' -IssueNumber 42 -FeatureBranch 'feature/issue-42-my-feature'\n```\n"
  }
}
````

The `additionalContext` field is a Markdown-formatted string describing what was found and the command(s) to clean it up.

### Step 6 — Prompt the user (only if stale state found)

If the output contains `hookSpecificOutput`, present the `additionalContext` description to the user and ask for confirmation before running cleanup:

> "[Paste the full content of `additionalContext` here.] Would you like me to run the cleanup now?"

Use `#tool:vscode/askQuestions` with two options: "Yes — run cleanup" and "No — skip for now".

### Step 7 — Run cleanup (only if user confirms)

If the user confirms, run all lines from the code block inside `additionalContext` in the terminal. Skip blank lines; `#`-prefixed comment lines are safe to include (they are no-ops in PowerShell). Example:

```powershell
pwsh '/path/to/copilot-orchestra/.github/scripts/post-merge-cleanup.ps1' -IssueNumber 42 -FeatureBranch 'feature/issue-42-my-feature'
```

Report what was cleaned up when complete.

### Step 8 — Continue with the user's request

Regardless of whether cleanup was run, skipped, or declined, continue responding to the user's original first message as normal. This automatic run-once guard applies only to the startup path; explicit or manual detector runs still remain allowed after the automatic guard fires.

## Silent Skip Conditions

Skip the entire check silently (no mention to user) in any of these cases:

- Neither `$env:COPILOT_ORCHESTRA_ROOT` nor `$env:WORKFLOW_TEMPLATE_ROOT` is set
- `pwsh` is not available on PATH
- The detector script returns an error or non-JSON output
- The detector script does not exist at the expected path

These are normal conditions for users who haven't configured copilot-orchestra or are in environments where PowerShell is unavailable.
