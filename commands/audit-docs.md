---
description: "Audit or bootstrap ai-first-documentation standards for the current repository. Actions: audit, init, help."
argument-hint: "[help|audit|init] [--root <path>]"
---

# /audit-docs

Load `skills/ai-first-documentation/SKILL.md` before any action. Treat that skill as the authority for inventory rules, check semantics, and the decision-record convention.

## Target-root resolution

All actions resolve a target root before executing:
- With `--root <path>`: use the provided path as the consumer repository root.
- Without `--root`: use the current working directory.

State the resolved root before any action or mutation.

## Actions

### help (default when no argument or `help`)

List the available actions and their purposes. Do not run any audit or write any file. Stop after listing.

Actions:
- `audit` — run the mechanical-check script against the target root and apply rubric judgment passes on top
- `init` — bootstrap a minimal CLAUDE.md at the target root (only when no CLAUDE.md and no AGENTS.md exist at root)
- `help` — show this list

### audit

1. Resolve the target root.
2. Run the mechanical-check script with explicit `-Root`:
   ```powershell
   pwsh skills/ai-first-documentation/scripts/audit-docs-mechanical.ps1 -Root <resolved-root>
   ```
   The script path is resolved relative to the Agent Orchestra plugin/skill tree (same directory as this skill). When running interactively inside Claude Code, the script resolves from the installed plugin path.
3. Parse the JSON output and apply rubric judgment passes (A6, A7 confidence labeling; B4 link graph walk; deletion-test advisory) on top of the mechanical findings.
4. Report findings restricted to the `scope.inventoried[]` set from the script output — never report on files outside that set.
5. Do not write any file during `audit`.

### init

1. Resolve the target root.
2. Check the greenfield predicate: **no root `CLAUDE.md` AND no root `AGENTS.md`** at the resolved root.
3. If the predicate fails (either file exists): decline with a message explaining which file exists. Do not write anything.
4. If the predicate passes: present the starter template path (`skills/ai-first-documentation/templates/CLAUDE.md-starter.md`) and ask for confirmation before writing. The default answer is **decline** — write only on explicit acceptance.
5. On accepted confirmation: copy the starter template to `<resolved-root>/CLAUDE.md`. State that the file was written.
6. Do not write any other files during `init`.

## Invariants

- **Read-only default**: `audit` and `help` never write to the working tree.
- `init` is the only action that writes a file, and only after explicit confirmation.
- All findings from `audit` are restricted to the `scope.inventoried[]` set from the script.

ARGUMENTS: $ARGUMENTS
