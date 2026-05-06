---
description: "Render the latest plan comment frame spine for a GitHub issue without mutating the plan comment."
argument-hint: "<positive integer issue number>"
---

# /orchestra:spine

<!-- scope: claude-only -->

Inspect the latest `<!-- plan-issue-{ID} -->` comment for a persisted frame spine.

The argument must be exactly one positive integer issue number, for example `/orchestra:spine 512`. If the argument is missing, non-numeric, zero, or negative, stop and show the usage hint `Usage: /orchestra:spine <issue-number>`.

Invoke the read-only script from the repository root:

```powershell
pwsh -NoProfile -NonInteractive -File .github/scripts/orchestra-spine.ps1 -Issue <issue-number>
```

The script renders only the `<!-- frame-spine -->` inspection table from the latest matching plan comment. It must not edit, append, or replace any issue comment.

ARGUMENTS: $ARGUMENTS
