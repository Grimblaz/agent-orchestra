```instructions
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

### FORBIDDEN PowerShell Write Commands

Never use any of the following to write or modify file content:

- `Set-Content`
- `Out-File`
- `Add-Content`
- `New-Item` with `-Value`
- `echo something > file.txt` or `echo something >> file.txt`

These PowerShell commands silently corrupt files through encoding issues (e.g., UTF-16 BOM), incorrect line endings (CRLF where LF is expected), or data truncation. Even when they appear to succeed, the resulting files may break parsers, linters, and downstream tooling.

---

## Section 2: Issue Creation Rules

### 2a. Improvement-First Decision Rule

When any agent discovers an out-of-scope or non-blocking improvement during its work:

- **≤ 4 hours effort**: Fix in the current PR if the change is low-risk and does not expand scope significantly; otherwise defer.
- **> 4 hours effort (significant)**: Create a follow-up GitHub issue **immediately** using `gh issue create`, then continue with in-scope work. Do not block the current PR on the deferred improvement.

### 2b. Priority Label Requirement

Every `gh issue create` command run by any agent **MUST** include a `--label` flag specifying a priority. Issues created without a priority label are non-compliant.

```powershell
# REQUIRED — always include a priority label:
gh issue create --title "..." --body "..." --label "priority: medium"

# WRONG — missing priority label:
gh issue create --title "..." --body "..."
```

#### Priority Labels

| Label              | Description                                    | When to use                                                   |
| ------------------ | ---------------------------------------------- | ------------------------------------------------------------- |
| `priority: high`   | Critical — highest impact, must fix            | Correctness bugs, security issues, broken builds              |
| `priority: medium` | Strong improvement — depth and polish          | Deferred improvements, notable refactors, non-urgent features |
| `priority: low`    | Nice-to-have — cosmetic or optional            | Cosmetic, optional, or speculative work                       |

**Default for automatically-created follow-up issues**: `priority: medium`
```
