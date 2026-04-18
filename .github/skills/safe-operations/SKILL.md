---
name: safe-operations
description: Safe file-operation and issue-creation protocol for Copilot Orchestra. Use when choosing workspace tools, avoiding unsafe file writes, or creating GitHub issues under the workflow rules. DO NOT USE FOR: application-level debugging or replacing agent judgment on whether work is in scope.
---

# Safe Operations Instructions

## Purpose

Establish safe, consistent rules for file operations and issue creation across all agents in this workflow. These rules prevent silent file corruption and ensure GitHub issues are always properly labeled.

---

## Section 1: File Operation Rules (CRITICAL)

These rules apply whenever any agent uses terminal commands or file tools to read, write, or move files. **PowerShell write commands silently corrupt files** through incorrect encoding, unwanted BOM markers, or inconsistent line endings. Always use the designated tool for each operation.

### Correct Tools by Operation

| Operation             | Correct Tool                                              |
| --------------------- | --------------------------------------------------------- |
| Create a new file     | `create_file`                                             |
| Edit an existing file | `replace_string_in_file` / `multi_replace_string_in_file` |
| Read a file           | `read_file`                                               |
| Delete a file         | `Remove-Item` (terminal)                                  |
| Archive/move a file   | `Move-Item` (terminal)                                    |

### Read-Only & Computable Operations

For operations that only inspect state or compute values, **always prefer dedicated VS Code tools over terminal commands**. Terminal commands trigger a "Run command?" confirmation dialog and return unstructured text — dedicated tools provide structured, typed outputs without interruption.

| Operation                      | Preferred Method                                                                  | Do NOT use terminal for                                                             |
| ------------------------------ | --------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------- |
| Inspect changed files / diffs  | `get_changed_files`                                                               | `git diff` (working-tree; cross-branch diff is permitted in terminal), `git status` |
| Read file content              | `read_file`                                                                       | `Get-Content`, `cat`                                                                |
| Search for text in files       | `grep_search`                                                                     | `Select-String`, `grep`, `git grep`                                                 |
| List directory contents        | `list_dir` or `file_search`                                                       | `Get-ChildItem`, `ls`                                                               |
| Check file/directory existence | `file_search` (glob-based; use exact-path pattern and check for non-empty result) | `Test-Path`                                                                         |
| Arithmetic / coordinate math   | Agent reasoning directly                                                          | `node -e`, `python -c`, `pwsh -c`                                                   |
| Semantic / concept search      | `semantic_search`                                                                 | —                                                                                   |

> **Exception**: The "Do NOT use" restrictions above apply to ad-hoc discovery. Project validation commands explicitly permitted in the Rule below (e.g., quick-validate checks in `.github/copilot-instructions.md`) may use `Get-ChildItem`, `Select-String`, and similar terminal commands.

**Rule**: By default, use dedicated VS Code tools for all inspection and read operations. Reserve `run_in_terminal` for: build commands, test runners, file move/delete operations, `gh` CLI calls, git workflow operations (commit, push, checkout, branch, merge), project validation commands (e.g., quick-validate checks in `.github/copilot-instructions.md`), targets outside the workspace, and operations with no built-in equivalent (e.g., file timestamps, git log history, complex path-exclusion filters).

---

### FORBIDDEN PowerShell Write Commands

Never use any of the following to write or modify file content:

- `Set-Content`
- `Out-File`
- `Add-Content`
- `New-Item` with `-Value`
- `echo something > file.txt` or `echo something >> file.txt`
- `.NET static IO methods: [System.IO.File]::WriteAllText(), ::AppendAllText(), ::WriteAllLines(), ::WriteAllBytes() — same silent encoding risks`

These PowerShell commands silently corrupt files through encoding issues (e.g., UTF-16 BOM), incorrect line endings (CRLF where LF is expected), or data truncation. Even when they appear to succeed, the resulting files may break parsers, linters, and downstream tooling.

---

## Section 2: Issue Creation Rules

### 2a. Improvement-First Decision Rule

When any agent discovers an out-of-scope or non-blocking improvement during its work:

- **< 1 day effort**: Address within the current task (or current PR if one is open) if the change is low-risk and does not expand scope significantly; otherwise defer.
- **> 1 day effort (significant)**: Create a follow-up GitHub issue **immediately** using `gh issue create`, then continue with in-scope work. Do not block the current PR on the deferred improvement.

**Output capture**: After `gh issue create` succeeds, capture the returned issue URL. Do not re-run the command if it already returned a URL. If terminal output is unclear or truncated, verify by listing recent open issues before retrying:

```powershell
gh issue list --limit 5 --state open --json number,title --jq '.[] | "\(.number): \(.title)"'
```

Scan the output for an exact title match. If a match is found, the issue was created — do not re-run. This uses the list API (not the search index) and is not subject to propagation delay. Output capture is the primary defense against rapid re-submission (e.g., terminal retry when output was swallowed); search-based deduplication (Section 2c) cannot prevent sub-second re-submissions due to GitHub's search index propagation delay.

### 2b. Priority Label Requirement

Every `gh issue create` command run by any agent **MUST** include a `--label` flag specifying a priority. Issues created without a priority label are non-compliant.

```powershell
# REQUIRED — always include a priority label:
gh issue create --title "..." --body "..." --label "priority: medium"

# WRONG — missing priority label:
gh issue create --title "..." --body "..."
```

> **Prerequisite — Priority labels must exist in the target repository.**
> If they do not yet exist, run these commands once per repository:
>
> ```powershell
> gh label create "priority: high"   --color "#D93F0B" --description "Critical — must fix this sprint"
> gh label create "priority: medium" --color "#FBCA04" --description "Strong improvement — schedule soon"
> gh label create "priority: low"    --color "#0075CA" --description "Nice-to-have — defer or batch"
> ```

#### Priority Labels

| Label              | Description                           | When to use                                                   |
| ------------------ | ------------------------------------- | ------------------------------------------------------------- |
| `priority: high`   | Critical — highest impact, must fix   | Correctness bugs, security issues, broken builds              |
| `priority: medium` | Strong improvement — depth and polish | Deferred improvements, notable refactors, non-urgent features |
| `priority: low`    | Nice-to-have — cosmetic or optional   | Cosmetic, optional, or speculative work                       |

**Default for automatically-created follow-up issues**: `priority: medium`

### 2c. Deduplication Check (Mandatory)

> **Rule-addition proposals**: Apply §2d (Prevention-Analysis Advisory, below) before this search — if §2d redirects to an existing issue, this dedup search is unnecessary.

Before every `gh issue create`, search for existing open issues with matching titles or key terms from the title:

```powershell
# REQUIRED — search before creating:
# Extract 2-4 distinctive words from the title, e.g. for "Add deduplication guard to issue creation protocol" use "deduplication guard issue creation"
gh issue list --search "{key phrase from title}" --state open --json number,title --jq '.[] | "\(.number): \(.title)"'
```

If a matching issue exists, do NOT create a duplicate. Instead, reference the existing issue number in the current work context (PR body, review notes, or tracking file).

> **Exception**: Skip when the title contains a high-entropy machine-generated unique identifier — specifically a full commit SHA (40 hex chars) or UUID v4 (128-bit random) — that guarantees no collision. Short tokens, sequential IDs, and timestamps do not qualify.
>
> **Note on search-index timing**: GitHub's search index has a propagation delay (typically seconds to minutes). The dedup search cannot prevent sub-second re-submissions — that failure mode is addressed by output capture (Section 2a). This search guards against independent code-path convergence (the same topic created by separate agents on different branches or sessions).

**Cross-repo gotcha dedup** (used by Process-Review §4.8 upstream lifecycle):

```powershell
# Cross-repo dedup — use --repo flag to target the upstream Copilot Orchestra repo:
# Read copilot-orchestra-repo from .github/copilot-instructions.md first
gh issue list --repo {copilot-orchestra-repo} --search "[Gotcha] {skill-name}" --state all --json number,title --jq '.[] | "\(.number): \(.title)"'
```

Key differences from the standard pattern:

- `--repo {copilot-orchestra-repo}` targets the upstream template repo (not the current repo)
- `--state all` includes closed issues (a resolved gotcha should not be re-submitted)
- Search key format is `[Gotcha] {skill-name}` — the `[Gotcha]` prefix groups all gotcha issues for that skill
- If `gh` cannot access the upstream repo, fall back to creating a local issue labeled `upstream-gotcha` and `priority: medium` for manual transfer

### 2d. Prevention-Analysis Advisory (Rule-Addition Proposals Only)

Before creating any issue that proposes **adding a new rule, directive, or guidance clause** to an agent file, instruction file, or skill, evaluate the following in order. Apply this check before the §2c dedup search — if §2d redirects to an existing issue, the §2c search is unnecessary:

**Step 1 — Principle-level consolidation check**: Does an open issue already cover the same underlying principle, even if it targets a different agent or file? If yes, comment on the existing issue instead of creating a new one. If multiple matching issues exist, comment on the most recently updated one.

**Principle-level consolidation examples**:

- "Add input validation to CLI handler" and "Add input schema enforcement to REST handler" → same principle (input validation), consolidate into one issue
- "Add error handling for null responses" and "Add timeout handling for slow responses" → different principles (null safety vs. resilience), separate issues are appropriate
- "Require docstrings on public functions" and "Require inline comments on complex logic" → same principle (documentation completeness), consolidate into one issue

**Step 2 — Prevention alternative check**: Could the problem be solved structurally instead of adding a rule? Structural alternatives include: contract test that enforces the behavior, upstream catch that prevents the failure, skill extraction that reduces rule density, or consolidation with an existing guideline. If yes, reframe the issue as a structural improvement rather than a rule addition.

**Step 3 — Create with justification**: If neither Step 1 nor Step 2 applies, create the issue and note briefly in the issue body why a new rule is warranted (e.g., 'no existing principle covers this; structural prevention is not feasible here').

**Scope**: This advisory applies **only to rule-addition proposals** (`systemic_fix_type: agent-prompt` or `instruction`). It does **not** apply to:

- Issues that reduce directive count (compression, extraction, consolidation) — these are exempt
- Structural prevention issues (new contract tests, upstream catches)
- Bug reports, configuration fixes, or documentation corrections

**Override**: This is advisory guidance — agent judgment determines the outcome. Users may always direct issue creation regardless of this advisory.

## Gotchas

| Trigger                                 | Gotcha                                                             | Fix                                                                                                   |
| --------------------------------------- | ------------------------------------------------------------------ | ----------------------------------------------------------------------------------------------------- |
| Editing workspace files from PowerShell | Silent encoding or line-ending corruption slips into tracked files | Use the designated file tools for content changes and keep terminal writes for move/delete cases only |
