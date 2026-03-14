# Session Startup Instructions

## Purpose

Instruct agents to run the session-cleanup detector at the start of every conversation. This replaces the VS Code `SessionStart` hook, which was retired in issue #109 due to unreliable firing across different repos. The detector is implemented in `.github/scripts/session-cleanup-detector.ps1` and identifies stale tracking files left over from merged pull requests.

## When to Apply

When a user starts a new conversation with you, before responding to their first message, perform the session startup check described below.

## Session Startup Check

Follow these steps exactly:

### Step 1 — Check prerequisites

If `$env:WORKFLOW_TEMPLATE_ROOT` is not set, skip the check entirely and continue silently. Do not mention this to the user.

### Step 2 — Run the detector script

Run the following command in the terminal:

```
pwsh -NoProfile -NonInteractive -File "$env:WORKFLOW_TEMPLATE_ROOT/.github/scripts/session-cleanup-detector.ps1"
```

Use the absolute path via `$env:WORKFLOW_TEMPLATE_ROOT` — this ensures the script is found even when working in a downstream repository (not the workflow-template repo itself).

### Step 3 — Parse the output

The detector returns one of two JSON shapes:

**No stale state found** (continue silently, do not mention to user):
```json
{}
```

**Stale state found** (prompt the user):
```json
{
  "hookSpecificOutput": {
    "hookEventName": "SessionStart",
    "additionalContext": "**Post-merge cleanup detected** — stale tracking artifacts found:\n\n- `.copilot-tracking/issue-42-my-feature.yml`\n\nTo clean up, run:\n```powershell\n# Run in a PowerShell (pwsh) terminal:\npwsh '/path/to/workflow-template/.github/scripts/post-merge-cleanup.ps1' -IssueNumber 42 -FeatureBranch 'feature/issue-42-my-feature'\n```\n"
  }
}
```

The `additionalContext` field is a Markdown-formatted string describing what was found and the command(s) to clean it up.

### Step 4 — Prompt the user (only if stale state found)

If the output contains `hookSpecificOutput`, present the `additionalContext` description to the user and ask for confirmation before running cleanup:

> "Post-merge cleanup may be needed. [paste the description from `additionalContext`]. Would you like me to run the cleanup now?"

Use `#tool:vscode/askQuestions` with two options: "Yes — run cleanup" and "No — skip for now".

### Step 5 — Run cleanup (only if user confirms)

If the user confirms, extract the PowerShell command(s) from the code block inside `additionalContext` and run them in the terminal. Example:

```
pwsh '/path/to/workflow-template/.github/scripts/post-merge-cleanup.ps1' -IssueNumber 42 -FeatureBranch 'feature/issue-42-my-feature'
```

Report what was cleaned up when complete.

### Step 6 — Continue with the user's request

Regardless of whether cleanup was run, skipped, or declined, continue responding to the user's original first message as normal.

## Silent Skip Conditions

Skip the entire check silently (no mention to user) in any of these cases:

- `$env:WORKFLOW_TEMPLATE_ROOT` is not set
- `pwsh` is not available on PATH
- The detector script returns an error or non-JSON output
- The detector script does not exist at the expected path

These are normal conditions for users who haven't configured the workflow template or are in environments where PowerShell is unavailable.
