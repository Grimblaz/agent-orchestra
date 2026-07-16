---
name: copilot-cost-collection
description: "Copilot OTel cost collection setup and interpretation guidance. Use when enabling local Copilot Chat OTel file export, installing the workspace sentinel, or explaining branch-correlated Copilot cost telemetry. DO NOT USE FOR: Claude-native cost capture, durable session memory handoff, review-pipeline scoring logic, or session-cost discipline behavior rules (see skills/terminal-hygiene/SKILL.md § Session-Cost Discipline)."
---

# Copilot Cost Collection

This skill documents the machine-local setup needed for Copilot-side cost telemetry in Agent Orchestra. It pairs the Copilot Chat OTel file exporter with the cost walker that attributes sessions to the active branch by joining OTel session timestamps to the git reflog.

## Methodology

1. Enable Copilot Chat OTel export to a local file.
2. Write a literal workspace-specific `github.copilot.chat.otel.outfile` path. Do not rely on VS Code variable templates for this setting; issue #488 OQ1 showed the exporter did not expand them in this environment.
3. Keep setup state machine-local: user settings, workspace `.vscode/settings.json`, the OTel JSONL directory, and `.copilot-cost-collection-installed` are local operating state, not durable plan or session memory.
4. Let the cost walker correlate sessions to branches from the git reflog. Branch switches, detached checkouts, and reflog pruning can reduce attribution confidence.

## Install Contract

Run the installer from the repo root or pass `-WorkspacePath` explicitly:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File skills/copilot-cost-collection/scripts/Initialize-CopilotCostCollection.ps1 -WorkspacePath . -Yes -NonInteractive
```

The installer is additive and idempotent:

- VS Code user settings: sets `github.copilot.chat.otel.enabled=true`, `github.copilot.chat.otel.exporterType="file"`, and `github.copilot.chat.otel.captureContent=false` while preserving other keys.
- Workspace settings: sets `github.copilot.chat.otel.outfile` to a literal path shaped like `<UserHome>/.copilot-otel/<workspaceFolderBasename>/copilot.jsonl`.
- Workspace root: writes `.copilot-cost-collection-installed` with provenance fields and keeps it ignored by git.
- OTel directory: creates the parent directory for the JSONL file but does not create the JSONL file.

Use `-UserSettingsPath` for VS Code profiles, Insiders, portable installs, or any alternate user-data directory. The default targets stable VS Code user settings for the current OS.

## Branch Correlation Rules

Copilot OTel records do not carry a repository branch. The walker groups token-bearing records by `session.id`, uses the earliest session timestamp, and joins that timestamp to the git reflog window for the target branch.

Known limitations:

- Multi-worktree or cross-checkout sessions can be ambiguous when the same OTel file receives events from more than one workspace.
- Reflog pruning, manual reflog expiry, or missing checkout entries can make old sessions unattributable.
- A long Copilot session that spans a branch switch is attributed by session start time, not by every later token event.

## Machine-Local State

Survival: `within-worktree`; contract: SMC-08 style local setup note, not a durable phase-completion marker.

The sentinel and settings prove local install provenance only. Do not treat them as plan state, review state, CE evidence, or cross-tool durable handoff. Durable workflow state still belongs in GitHub issue comments, PR bodies, committed docs, or the session-memory mechanisms named by `skills/session-memory-contract/SKILL.md`.

## Platform-specific invocation

This skill's methodology is tool-agnostic. Platform-specific setup notes live alongside:

- Copilot: [platforms/copilot.md](platforms/copilot.md)
- Claude Code: [platforms/claude.md](platforms/claude.md)

## Related

- [scripts/Initialize-CopilotCostCollection.ps1](scripts/Initialize-CopilotCostCollection.ps1)
- `.github/scripts/lib/cost-walker-copilot.ps1`
- [Documents/Design/copilot-otel-capability.md](../../Documents/Design/copilot-otel-capability.md)

## Gotchas

| Trigger                                                                                       | Gotcha                                                                                                | Fix                                                                         |
| --------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------- |
| Writing `${userHome}` or `${workspaceFolderBasename}` into `github.copilot.chat.otel.outfile` | Copilot Chat file export may treat the template as a literal and never create the expected JSONL file | Run the installer so the workspace setting receives a literal resolved path |
| Opening the repo in VS Code Insiders, a profile, or a portable user-data dir                  | The default user settings path may update stable VS Code instead of the active profile                | Re-run with `-UserSettingsPath` pointing at the active `settings.json`      |
| Treating `.copilot-cost-collection-installed` as workflow memory                              | The sentinel is local and uncommitted, so other machines and agents cannot rely on it                 | Use SMC durable markers or PR-body metrics for cross-session handoff        |

## Frame Ports Filled By This Skill

**None**. This is setup methodology only. The Step 9 implementation slice provides `implement-code` through Code-Smith; this skill declares no `provides:` field.
