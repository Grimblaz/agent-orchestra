---
description: "Set up Agent Orchestra project-reference sidecars and indexes with deterministic scripts."
argument-hint: "[help|init|generate|validate|undo|dismiss-nudge] [target repo root]"
---

# /setup-references

Load `skills/project-references/SKILL.md` before doing any setup work. Treat that skill as the authority for sidecar schema, `.agent-orchestra.yml`, citation format, content-trust rules, and hard caps.

ARGUMENTS: $ARGUMENTS

## Safe Default

If `$ARGUMENTS` is empty or the first argument is `help`, show the action list below and stop without writing files.

Resolve the target repository root from the remaining arguments when a path is supplied; otherwise use the current workspace root. Before running a mutating action, state the target root and the script path that will run.

Resolve the project-reference script directory from the loaded skill location. Use the `skills/project-references/scripts/` directory adjacent to the loaded skill, whether that skill came from an installed plugin, prompt-files setup, or source checkout. If the scripts cannot be found, ask for the Agent Orchestra root instead of guessing.

## Actions

- `init` or `initialize`: run `init-references.ps1` against the target root to create generated sidecars and the init manifest. This is an explicit mutating action.
- `generate` or `index`: run `generate-references-index.ps1` against the target root to refresh `.references/index.json` and `Documents/INDEX.md`. This is an explicit mutating action.
- `validate`: run `validate-references-index.ps1` against the target root and report stale targets, orphan sidecars, duplicate names, unknown schema versions, uncovered docs, citation checks, and budget status. This is read-only.
- `undo`: run `init-references.ps1 --undo` against the target root only when the init manifest exists or the user explicitly confirms undo. This removes files recorded by init and should not be used as a broad cleanup command.
- `dismiss-nudge`: run `init-references.ps1 --dismiss-nudge` against the target root to record `.copilot-tracking/references-state.yml` with `references_nudge_dismissed: true`. This is an explicit mutating action and does not create sidecars.
- `help`: explain these actions and do not run scripts.

## Script Commands

Use PowerShell 7+ and quote paths that contain spaces:

```powershell
pwsh -NoProfile -NonInteractive -File "<script-root>/init-references.ps1" -Root "<target-root>"
pwsh -NoProfile -NonInteractive -File "<script-root>/generate-references-index.ps1" -Root "<target-root>"
pwsh -NoProfile -NonInteractive -File "<script-root>/validate-references-index.ps1" -Root "<target-root>"
pwsh -NoProfile -NonInteractive -File "<script-root>/init-references.ps1" -Root "<target-root>" --undo
pwsh -NoProfile -NonInteractive -File "<script-root>/init-references.ps1" -Root "<target-root>" --dismiss-nudge
```

After `init` or `generate`, run `validate` unless the user asked to skip validation.
