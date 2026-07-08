---
name: pre-commit-formatting
description: "Backstop formatting workflow used during PR creation. Use when applying the final markdown and whitespace formatting gate before validation evidence capture. DO NOT USE FOR: per-step implementation formatting advice or PowerShell formatting rules outside this gate."
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

## Newcomer-Audit Lane (Warn-Only, Findings-Only)

During the same Code-Conductor PR-creation step, run the newcomer-audit detector over the branch's changed files:

```powershell
pwsh skills/naming-register-policy/scripts/newcomer-audit.ps1 -Changed
```

This lane is not a formatting lane and does not behave like the two lanes above:

- It never stages or commits anything — unlike Step 2 and Step 3, there is no `git add` / `git commit` step for this lane.
- It emits findings only; findings are surfaced as a warning in the PR body / conversation, never as a blocking condition.
- PR creation proceeds regardless of the lane's exit code (0 = clean, 1 = findings, 2 = usage/operational error).
- **Exit code 2 is an operational failure, not a clean pass — surface it distinctly.** Exit 1 (findings) and exit 2 (the audit failed to run) must never look the same to the operator. On exit 2, post a distinctly-worded warning in the PR body / conversation — for example: "⚠️ newcomer-audit lane FAILED TO RUN — findings unknown, treat as unaudited." The lane stays fail-open either way (exit 2 never blocks PR creation), but silence on exit 2 would make a broken audit indistinguishable from a genuinely clean one.

**This lane does not inherit FG-D6.** FG-D6 (`## Non-Blocking Behavior` above) covers a narrower case — the formatting tools (`markdownlint-cli2`, `pwsh`) being unavailable in PATH. This lane's non-blocking behavior is a separate, explicit rule: the tool runs successfully and returns real findings, and those findings still never block PR creation. Do not describe this lane as "inheriting" or "covered by" FG-D6 — its warn-only semantics are stated here explicitly.

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
