# Session-Cleanup Persistent-File Exclusion Registry

> Issue: [#656](https://github.com/Grimblaz/agent-orchestra/issues/656)

## Problem

The session-cleanup detector and executor treated `.copilot-tracking/` root-level files with no `issue_id` frontmatter as stale untagged artifacts eligible for archival. Three files are permanently live at root depth and must never be archived:

| File | Writer |
|---|---|
| `gate-events.jsonl` | `skills/solution-authoring/scripts/gate-event-logger-hook.ps1:63` |
| `references-state.yml` | `skills/project-references/scripts/init-references.ps1:12` |
| `references-init.manifest` | `skills/project-references/scripts/init-references.ps1:11` |

## Design: Dual-Axis Exclusion Registry

A single accessor `Get-SCDPersistentTrackingExclusions` in `session-startup-git-helpers.ps1` returns two exclusion axes:

```powershell
@{
    Subtrees  = @('calibration')   # directory prefixes — entire subtree protected
    Filenames = @('gate-events.jsonl', 'references-state.yml', 'references-init.manifest')
}
```

Both the detector (`session-cleanup-detector-core.ps1`) and executor (`post-merge-cleanup.ps1`) dot-source the helpers file and consume the registry from this single function — no literals scattered across files.

### Axis semantics

- **Subtrees**: any file whose path relative to `.copilot-tracking/` starts with a subtree prefix is excluded. Used for the `calibration/` directory, which was protected before this issue.
- **Filenames**: a file at **root depth only** (no `/` in its relative path) that matches a registered basename is excluded. Registry-named files in subdirectories are NOT excluded (AC5).

### Fail-safe contracts

Both consumers must fail loudly toward preservation, never silently toward deletion:

1. **Accessor undefined**: if `Get-SCDPersistentTrackingExclusions` is not defined after the helpers file loads, abort immediately with a HALT diagnostic before any `Move-Item`. Exit code 1.
2. **Accessor returns null/missing key**: if the accessor is defined but returns `$null` or a hashtable without a `Filenames` key, also abort with a HALT diagnostic. Exit code 1.
3. **Executor scope**: the executor consumes only the `Filenames` axis (root-level files). The `Subtrees` axis is honored only by the detector, which excludes subtree-protected files before writing its `-UntaggedTrackingFiles` output.

### Writer-oracle parity (AC7)

A Pester test in `session-cleanup-detector.Tests.ps1` scans all non-test, non-cleanup `.ps1` files for `Join-Path` patterns that write to `.copilot-tracking/` root and asserts every discovered writer is enrolled in the registry. This catches new persistent writers at CI time.

## Extension guide

To protect a new root-level persistent file, add its basename to the `Filenames` array in `Get-SCDPersistentTrackingExclusions`. The writer-oracle AC7 test will fail CI until the entry is added, prompting the change.

To protect a new persistent subtree, add the directory name to the `Subtrees` array. Note: the executor does not currently enforce subtree protection (by design, because the detector already excludes subtree files before emitting untagged-file lists). If subtree protection at the executor level is ever needed, add a Subtrees guard to the two registry-guard blocks in `post-merge-cleanup.ps1` (search for `mf6-executor-failsafe`).
