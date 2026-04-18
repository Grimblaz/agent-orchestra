# Pre-Commit Formatting

## Purpose

Issue #219 closed a repo-tooling gap around PowerShell formatting. Agent-edited `.ps1` files bypass VS Code save-time formatting because tool-driven edits do not trigger an editor save, which led to follow-up style commits after otherwise-correct changes.

Issue #248 extends that same contributor workflow without replacing it. The repo now combines a root `.editorconfig` whitespace baseline with a third pre-commit lane for curated config/text files so contributors and reviewers see less low-value whitespace churn while the existing Markdown and `.ps1` semantic lanes keep their current ownership.

## Implemented Surface

| File | Role |
| --- | --- |
| `.githooks/pre-commit` | Shell hook with three lanes: Markdown formatting, `.ps1` formatting, and allowlisted whitespace normalization |
| `.editorconfig` | Repo-root whitespace baseline with a Markdown override and file-type indentation defaults |
| `.github/scripts/normalize-whitespace.ps1` | Encoding-preserving helper for the generic whitespace-only lane |
| `.vscode/settings.json` | Verify-only workspace alignment for Markdown and PowerShell save-time formatting; unchanged for issue #248 because no conflict with `.editorconfig` was found |
| `CONTRIBUTING.md` | Contributor setup guidance, lane ownership, warning behavior, and partial-staging caveat |
| `README.md` | Intentionally unchanged so contributor tooling guidance stays in `CONTRIBUTING.md` |

## Design Decisions

### D1 - Keep the shell hook and semantic ownership model

The repo continues to use `.githooks/pre-commit` as a POSIX shell hook. Issue #219 kept the existing Markdown lane and added a semantic PowerShell lane for staged `.ps1` files collected from the same cached diff snapshot. Issue #248 keeps both of those lanes intact and adds a third, narrower lane for allowlisted config/text files. Mixed `.md`, `.ps1`, and config/text commits therefore keep the existing semantic behavior for Markdown and PowerShell while broadening whitespace coverage elsewhere.

### D2 - Keep PowerShell formatting best-effort and non-blocking

The hook resolves PowerShell formatting capability through `pwsh` and `Invoke-Formatter`. If `pwsh` is missing, `PSScriptAnalyzer` cannot be imported, or formatting fails for a specific file, the hook prints a warning and continues. The script still exits successfully, so formatter availability is a quality improvement rather than a commit gate.

### D3 - Preserve encoding and BOM behavior on rewrite

Each staged `.ps1` file is read through `StreamReader`, formatted with `Invoke-Formatter -ScriptDefinition`, and only rewritten when content changes. The rewrite path inspects the original bytes for a UTF-8 BOM, carries forward the detected encoding, and explicitly preserves UTF-8 without BOM when the source file did not start with one. This avoids introducing encoding-only churn while still normalizing formatting.

### D4 - Add a repo-root `.editorconfig` whitespace baseline without widening policy scope

Issue #248 adds `.editorconfig` with `root = true`, baseline `trim_trailing_whitespace = true`, and `insert_final_newline = true`. Markdown gets an explicit `trim_trailing_whitespace = false` override so hard-break spaces remain valid. JSON/YAML-family files default to 2-space indentation, while PowerShell-family files default to 4-space indentation. The design intentionally does not add repo-wide `end_of_line` or `charset` policy in this issue.

### D5 - Add a third lane as a curated allowlist, not a catch-all formatter

Issue #248 adds a whitespace-only lane for staged `.json`, `.jsonc`, `.yml`, `.yaml`, `.psd1`, `.txt`, `.gitignore`, `.gitattributes`, and `.editorconfig` files. The lane is intentionally allowlisted instead of applying to every staged text file. That keeps ownership boundaries explicit, leaves Markdown with `markdownlint-cli2`, leaves semantic PowerShell formatting on `.ps1`, and avoids widening scope into `.psm1`, extensionless files, or broader repo-wide text normalization.

### D6 - Keep the generic lane intentionally narrow and encoding-safe

`.github/scripts/normalize-whitespace.ps1` trims only trailing horizontal whitespace, removes trailing blank lines at EOF, and ensures exactly one final newline. It preserves UTF-8 BOM and no-BOM state, skips unsupported or binary-like content, and does not rewrite indentation depth, key ordering, or any other semantic formatting.

### D7 - Keep warnings explicit and the hook non-blocking across all lanes

Issue #248 keeps the issue #219 philosophy: optional tooling should improve hygiene without becoming a commit gate. If `markdownlint-cli2`, `pwsh`, `Invoke-Formatter`, or the whitespace helper is unavailable, or if a per-file formatting pass fails, the hook prints an explicit warning and continues. The pre-commit script still exits `0`.

### D8 - Keep `.vscode/settings.json` verify-only unless a real conflict appears

`.vscode/settings.json` still enables `[markdown]` and `[powershell]` save-time formatting, and issue #248 leaves that file unchanged. `.editorconfig` now owns the portable whitespace baseline, so workspace settings remain minimal and should not be expanded to override the new baseline unless a concrete conflict is discovered.

### D9 - Keep contributor-facing setup and caveats in `CONTRIBUTING.md`

`CONTRIBUTING.md` remains the contributor-facing source for hook setup and formatter prerequisites. It now documents the third lane's allowlist, the explicit warning behavior, and the existing whole-file re-stage caveat for partially staged files. `README.md` remains high-level and does not duplicate this setup detail.

## Hook Behavior

1. Collect staged files once with `git diff --cached --name-only --diff-filter=ACM`.
2. Run the Markdown lane for staged `.md` files.
3. Discover staged `.ps1` files from the same staged-file snapshot.
4. Resolve PowerShell formatter availability once per commit by checking `pwsh`, then `Invoke-Formatter` or an import of `PSScriptAnalyzer`.
5. For each staged `.ps1` file, hash before, format through a literal-path-safe environment variable plus `Resolve-Path -LiteralPath`, hash after, and re-stage only if the file changed.
6. From the same staged-file snapshot, collect the allowlisted config/text files for the generic whitespace lane.
7. For each allowlisted file, run `.github/scripts/normalize-whitespace.ps1`, print any warning output, and re-stage only if content changed.
8. If either non-Markdown lane cannot run or one file-level pass fails, warn, leave that file unchanged, and continue.
9. Exit `0` so commits are never blocked by optional formatting tooling.

## `.editorconfig` Baseline

- `root = true`
- Global baseline: `trim_trailing_whitespace = true` and `insert_final_newline = true`
- Markdown override: `trim_trailing_whitespace = false`
- JSON and YAML family indentation defaults: 2 spaces
- PowerShell family indentation defaults: 4 spaces

This baseline is intentionally limited to whitespace and indentation defaults. The implementation does not add repo-wide `end_of_line` or `charset` policy, and it does not require a mass re-save of existing files.

## Scope Boundaries

### In Scope

- Commit-time formatting for staged `.md` and `.ps1` files in `.githooks/pre-commit`
- Commit-time whitespace normalization for the curated allowlist in `.githooks/pre-commit`
- Repo-root whitespace defaults in `.editorconfig`
- Contributor guidance for prerequisites, warning behavior, and caveats in `CONTRIBUTING.md`
- Verify-only confirmation that `.vscode/settings.json` remains compatible with the `.editorconfig` baseline

### Explicit Non-Goals

- Rewriting the hook in PowerShell
- Making `pwsh` or `PSScriptAnalyzer` a hard prerequisite
- Adding CI enforcement or repo-wide formatter policy changes beyond the scoped `.editorconfig` baseline
- Moving contributor setup guidance into `README.md`
- Expanding semantic PowerShell formatting to `.psd1` or `.psm1`
- Widening the generic lane into a catch-all formatter for every staged text file
- Changing `.vscode/settings.json` unless a real conflict with `.editorconfig` appears
- Solving index-only formatting for partially staged files

The last non-goal is deliberate. The repo keeps the existing working-tree/restage model: if any lane changes a staged file, the hook re-stages the full file with `git add`. Partially staged allowlisted config/text files therefore carry the same caveat as partially staged Markdown and `.ps1` files in the current hook design.

## Customer Experience Result

The combined result after issues #219 and #248 is a two-layer contributor workflow:

- Save-time alignment remains in place for Markdown and PowerShell through `.vscode/settings.json`.
- `.editorconfig` provides a portable whitespace baseline across supported editors.
- The pre-commit hook keeps semantic formatting on Markdown and `.ps1` files while adding a scoped whitespace-only safety net for allowlisted config/text files.
- Warning paths remain explicit and non-blocking, so contributors can still commit when optional tooling is missing.
- Partial-staging behavior is unchanged: any rewritten file is fully re-staged, and contributors need to review staged hunks accordingly.
- Code-Conductor's Step 4 formatting gate provides a final backstop pass on all branch-changed files before validation evidence capture, closing the gap between agent raw writes and VS Code's format-on-save expectations.

## Source Of Truth

This document records the repo state after issue #219 and its extension in issue #248. The implementation source of truth is the current content of `.githooks/pre-commit`, `.editorconfig`, `.github/scripts/normalize-whitespace.ps1`, `.vscode/settings.json`, and `CONTRIBUTING.md`.

Issue #299 introduced the formatting gate; its current protocol lives at `.github/skills/pre-commit-formatting/SKILL.md`, with the Step 4 sub-step reference in `.github/agents/Code-Conductor.agent.md`.

## Formatting Gate (Issue #299)

Issue #299 adds a formatting gate to Code-Conductor's Step 4 (Create PR) flow. This gate is a backstop that runs the same formatting tools (markdownlint-cli2 and normalize-whitespace.ps1) on all branch-changed files before validation evidence capture. It complements the pre-commit hook (commit-time, staged files) and the per-step advisory in copilot-instructions.md.

### Design Decisions

| ID | Decision | Rationale |
| --- | --- | --- |
| FG-D1 | Pre-commit passthrough — CC runs existing formatting pipeline on changed files before commit | Uses existing infrastructure (markdownlint-cli2, normalize-whitespace.ps1). No new tools. Content reaches the commit already in "final form." |
| FG-D2 | One-shot before git commit — single formatting pass on all branch-changed files, not per-step | Simpler implementation; single insertion point in CC's Step 4. Mid-session "Keep" may still show intermediate formatting, but commits and PRs are clean. |
| FG-D3 | CLI-only formatting, aligned with pre-commit hook — uses markdownlint-cli2 --fix and normalize-whitespace.ps1 | Deterministic; same tools as the pre-commit hook; avoids introducing new formatting tooling. |
| FG-D4 | Shared skill file — gate implemented as `.github/skills/pre-commit-formatting/SKILL.md` | Keeps CC's directive count stable (81/128). Reusable by other agents. Keeps formatting logic maintainable in one place. |
| FG-D5 | File scope: git diff --name-only --diff-filter=ACM main..HEAD — format all Added/Copied/Modified files on the branch | Ensures the entire PR is formatter-compliant. --diff-filter=ACM excludes deletions to avoid passing non-existent paths to formatters. |
| FG-D6 | Non-blocking gate — if tools unavailable, warn and proceed | Mirrors the pre-commit hook's non-blocking philosophy (D7). Formatting is hygiene, not a hard gate. |
| FG-D7 | PowerShell .ps1 formatting excluded from the backstop | Pre-commit hook handles .ps1 via Invoke-Formatter. PS files change infrequently. Explicit scope exclusion. |
| FG-D8 | Formatting gate runs before validation evidence capture in Step 4 | Ordering: end-to-end → scope → migration completeness (conditional) → design doc → formatting gate → validation evidence → git push → PR create. |
| FG-D9 | Layered formatting model — per-step advisory + Step 4 backstop | copilot-instructions.md advisory is first layer; CC's Step 4 one-shot is the backstop for anything that slipped through. |
| FG-D10 | Runs within CC's explicit Step 4 commit-and-push flow | Step 4 already owns git push and PR creation. Step commits (with `--no-verify`) handle validated-state commits during implementation steps; the formatting gate in Step 4 remains the backstop with hooks firing normally. |

### Rejected Alternatives

| Alternative | Why rejected |
| --- | --- |
| Instruction guidance only (agents try to produce formatter-compliant output) | LLMs can't reliably produce byte-perfect formatted output. Needs a backstop. |
| Disable VS Code format-on-save | Breaks real-time formatting for manual edits. |
| Per-step formatting pass | More complex; runs formatters many times per session. Can be added as a follow-up. |
| Inline in CC's agent definition | CC is at 81/128 directives. Shared instruction file keeps count stable. |
| Post-push formatting (original #299 proposal) | Only catches PR-bound drift, not the triage burden at "Keep" time. |
