# Safe Operations Design

## Purpose

The `safe-operations` skill (`.github/skills/safe-operations/SKILL.md`) establishes two categories of safety guardrails that apply to all agents in this workflow:

1. **File operation safety** — Prevents silent file corruption by banning PowerShell write commands and directing agents to dedicated VS Code tools, including a read-only tool preference sub-rule that eliminates unnecessary terminal dialogs.
2. **Issue creation rules** — Ensures every automatically-created GitHub issue carries a priority label and that non-blocking improvements are triaged consistently rather than silently dropped or scope-creeping the current PR.

## Scope

These instructions are global — they apply to every agent in the pipeline whenever it reads, writes, or moves files, or when it creates GitHub issues via `gh issue create`. Individual agents (Code-Critic, Research-Agent, Process-Review) layer stricter read-only constraints on top of this baseline; these instructions set the floor.

---

## Design Decisions

### File Write Safety (Section 1)

- PowerShell write commands (`Set-Content`, `Out-File`, `Add-Content`, `New-Item -Value`, redirect operators, and .NET static IO methods) silently corrupt files through encoding issues (e.g., UTF-16 BOM), CRLF line endings, or data truncation — even when they appear to succeed.
- Silent corruption breaks parsers, linters, and downstream tooling in ways that are hard to detect and painful to debug.
- The correct tools are designated per-operation: `create_file` for new files, `replace_string_in_file` / `multi_replace_string_in_file` for edits, `read_file` for reads, and `Remove-Item` / `Move-Item` (terminal) for delete and archive operations where no dedicated tool exists.

### Read-Only & Computable Operations (Section 1, added in issue #67)

- Using `run_in_terminal` for read-only operations (file discovery, text search, existence checks, arithmetic) triggers a "Run command?" confirmation dialog that interrupts automated workflows without adding any safety value.
- Terminal commands also return unstructured text, while dedicated VS Code tools return structured, typed outputs that agents can reason over directly without parsing.
- A preferred-method table maps seven common inspection operations to their correct VS Code tools, with explicit "Do NOT use terminal for" columns to make the anti-pattern concrete.
- Arithmetic and coordinate math are explicitly included as computable operations: agents should use their own reasoning rather than spawning a shell subprocess for trivial calculations.
- The sub-rule covers the same spirit as the write-safety rule — use the right tool for the job — but for the read and inspect side of the operation spectrum.

### Issue Creation Rules (Section 2)

- Issues created without a priority label are invisible in triage and cannot be scheduled; the label requirement ensures every follow-up issue is actionable from creation.
- The improvement-first decision rule gives agents a deterministic fork: small changes (< 1 day) may be folded into the current PR if low-risk and in-scope; larger changes (> 1 day) must immediately become tracked issues rather than being silently deferred or scope-creeping the ongoing PR.
- The default priority for automatically-created follow-up issues is `priority: medium`, preventing agents from defaulting to high-severity labels for speculative improvements.
- Three priority label definitions (`priority: high`, `priority: medium`, `priority: low`) are included with recommended colors and descriptions so any new repository can bootstrap the label set with a single copy-paste block.

### Deduplication Check (Section 2c)

Two confirmed duplicate-issue failure modes motivated a mandatory pre-creation search guard:

- **Terminal double-submission** (#122/#123): an agent ran `gh issue create` twice in rapid succession (e.g., terminal output was truncated on the first call, so the agent re-issued the command). The second call created a duplicate before the first was visible in search results.
- **Dual code-path convergence** (#100/#101): two independent sessions (separate agents on different branches) each identified the same improvement and created matching issues without knowledge of each other.

The design uses two complementary defenses rather than one, because neither alone is sufficient:

1. **Output capture (primary defense)**: after `gh issue create` returns a URL, the agent records it and does not re-run the command. This is the only reliable guard against sub-second re-submission — GitHub's search index has a propagation delay measured in seconds to minutes, so search-based deduplication cannot distinguish a missing issue from an issue that has not yet been indexed.
2. **Pre-creation search (secondary defense)**: before every `gh issue create`, agents run `gh issue list --search` to catch cross-session convergence where two separate sessions independently decide to report the same problem.

`--state open` is used (not `--state all`) to avoid false positives from completed issues: a closed issue with the same title represents resolved prior work, not a collision. Matching against a closed issue would incorrectly suppress a legitimately new follow-up.

The search-index delay is acknowledged as a known limitation of the secondary defense. Section 2a documents output capture as the primary agent-side guard; Section 2c search is the backstop for the harder cross-session convergence case where output capture does not apply.

---

## Exception Rationale

The Rule paragraph in the Read-Only & Computable Operations subsection ends with an explicit allow-list for `run_in_terminal`. Two of those categories need particular explanation:

**`git workflow operations` (commit, push, checkout, branch, merge)**
These are inherently stateful operations that modify repository state; no dedicated VS Code tool exposes them. Excluding them from the guardrail is necessary because the alternative — blocking all terminal git use — would prevent agents from completing any PR workflow step.

**`project validation commands` (e.g., quick-validate checks in `.github/copilot-instructions.md`)**
The quick-validate commands in `copilot-instructions.md` use `Get-ChildItem` + `Select-String` pipelines to verify that retired agent names have been fully purged from the repo. These are pre-defined, deterministic, and already documented as a mandatory pre-PR step. Without this carve-out, the guardrail would conflict with both copilot-instructions.md (which specifies these commands) and Code-Conductor's existing policy (`"Only use read/search tools for investigation and run_in_terminal for validation commands."`). The exemption preserves those two documents as the authority on project-level validation scripts; the guardrail only restricts ad-hoc terminal discovery that has a direct tool equivalent.

---

## Exception Taxonomy

The following categories of terminal command usage remain allowed even when a VS Code built-in tool could theoretically accomplish part of the task. Each exception must be documented inline with a rationale comment.

| Category | Rationale | Examples |
| --- | --- | --- |
| `project-validation` | Defined in `.github/copilot-instructions.md` quick-validate block; mandatory pre-PR gates that require PowerShell count expressions | `(Get-ChildItem ... \| Select-String ...).Count` checks in quick-validate |
| `cross-branch-diff` | Git diff with explicit ref specs (`main..HEAD`, `main...HEAD`) — `get_changed_files` only reports working-tree state, not cross-branch deltas | `git diff --name-only main..HEAD`, `git diff main...HEAD --stat` |
| `git-state-ops` | State-changing git operations — commit, push, checkout, branch, merge — are not readable via built-in tools | e.g. `git commit`, `git push`, `git checkout`, `git branch`, `git merge` |
| `gh-cli` | GitHub API operations via `gh` CLI (issue create, PR create, label, comment) — no built-in tool equivalent | `gh issue create`, `gh pr create`, `gh issue list` |
| `build-test-script` | Build and test execution, script invocation, and output filtering on script pipelines | `npm test`, `pwsh script.ps1`, `Invoke-Pester`, `Select-String` filtering build script output |
| `outside-workspace` | Target is outside the workspace (e.g., VS Code user `settings.json` in `$env:APPDATA`) — workspace-scoped tools cannot reach it | `Select-String -Path "$env:APPDATA\Code\User\settings.json"` |
| `no-equivalent` | No built-in tool equivalent exists for the operation | File timestamps (`LastWriteTime`), untracked file detection (`git status`), git log history (`git log`) |

---

## Rejected Alternatives

The following approaches were considered and rejected during the design of this enforcement policy (issue #132):

- **Docs-only cleanup**: Lower effort, but likely to regress. The repo already had a safe-operations policy and still drifted — enforcement must be structural (Code-Critic check) not just documentation.
- **Ban all terminal usage**: Too blunt. Numerous legitimate exceptions exist (cross-branch diff, git state ops, build/test execution, gh CLI, outside-workspace targets). A blanket ban would break the workflow.
- **Full lint/automation for every shell snippet**: Stronger, but carries higher effort and higher false-positive risk for an initial rollout. Code-Critic's judgment-based review is a better first step.

---

## Source

- Issue #67: [feat: add read-only tool preference guardrail](https://github.com/Grimblaz/copilot-orchestra/issues/67)
- Issue #127: [feat: add deduplication guard to issue creation protocol](https://github.com/Grimblaz/copilot-orchestra/issues/127)
- Issue #132: [feat: built-in-tool-first enforcement](https://github.com/Grimblaz/copilot-orchestra/issues/132)
