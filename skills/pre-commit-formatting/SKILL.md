---
name: pre-commit-formatting
description: Backstop formatting workflow used during PR creation. Use when applying the final markdown and whitespace formatting gate before validation evidence capture. DO NOT USE FOR: per-step implementation formatting advice or PowerShell formatting rules outside this gate.
---

# Pre-Commit Formatting Gate

## Purpose

This is a backstop formatting pass executed during Code-Conductor's Step 4 (Create PR). It complements two other formatting layers:

1. The per-step advisory from `.github/copilot-instructions.md` ("After editing any `.md` files, run `markdownlint-cli2 --fix`")
2. The `.githooks/pre-commit` hook that runs on staged files at commit time

This gate exists because per-step formatting may be skipped or incomplete — it catches any remaining drift before validation evidence capture (design decision FG-D9: layered model). Double-runs are safe because all formatters are idempotent.

---

## Protocol

### Step 1 — Identify changed files

Run:

```powershell
git diff --name-only --diff-filter=ACM main..HEAD
```

This lists all Added, Copied, and Modified files on the branch (excluding deletions). The `--diff-filter=ACM` flag is critical to avoid passing deleted file paths to formatters.

### Step 2 — Markdown lane

Filter the changed file list for `.md` files. Run `markdownlint-cli2 --fix` on them:

```powershell
markdownlint-cli2 --fix file1.md file2.md ...
```

Pass all `.md` files as arguments in a single invocation, or iterate one at a time — both are acceptable.

### Step 3 — Whitespace normalization lane

Filter the remaining file list to exclude `.md` and `.ps1` files, then pass them to the whitespace normalizer:

```powershell
pwsh -NoProfile -NonInteractive -File .github/scripts/normalize-whitespace.ps1 -Path <file>
```

Run one file at a time, or loop over the list.

**Important**: `normalize-whitespace.ps1` has an internal allowlist — it processes only: `.json`, `.jsonc`, `.yml`, `.yaml`, `.psd1`, `.txt`, `.gitignore`, `.gitattributes`, `.editorconfig`. Files with other extensions are skipped with a warning (exit code 0, warning on the PowerShell warning stream). This is expected behavior, not an error.

### Step 4 — Check for changes and commit

Run:

```powershell
git status --porcelain
```

If the output is non-empty (formatting produced changes), stage only the files identified in Step 1 and commit:

```powershell
git add <file1> <file2> ...
git commit -m "chore: formatting gate"
```

Use the file list from Step 1's `git diff --name-only` output — do **not** use `git add -A`, which would sweep unrelated working-tree changes into the formatting commit.

### Step 5 — Proceed

Continue with Step 4's next sub-step (validation evidence capture).

---

## Exclusions

`.ps1` files are NOT processed by this gate — PowerShell formatting is handled by the pre-commit hook's `Invoke-Formatter` lane (design decision FG-D7).

---

## Non-Blocking Behavior

If `markdownlint-cli2` is not available in PATH, or if `pwsh` is not available: warn in the conversation and proceed. Do not block PR creation for tool unavailability (design decision FG-D6). The pre-commit hook provides a separate formatting safety net.

---

## Portability Assumptions

This gate assumes:

- `markdownlint-cli2` is installed and in PATH
- `normalize-whitespace.ps1` is at `.github/scripts/normalize-whitespace.ps1`
- The default branch is named `main` (used in the `git diff` base ref)

Consumer repos cloned from this template should adjust the branch name if their default branch differs.

## Gotchas

| Trigger                     | Gotcha                                                                        | Fix                                                                |
| --------------------------- | ----------------------------------------------------------------------------- | ------------------------------------------------------------------ |
| Running the formatting gate | `git add -A` sweeps unrelated working-tree changes into the formatting commit | Stage only the files collected from the explicit changed-file list |
