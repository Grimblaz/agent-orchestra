---
name: safe-operations
description: "Safe file-operation and issue-creation protocol for Agent Orchestra. Use when choosing workspace tools, avoiding unsafe file writes, or creating GitHub issues under the workflow rules. DO NOT USE FOR: application-level debugging or replacing agent judgment on whether work is in scope."
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

**Scratch files**: write all agent scratch to `.tmp/` per `skills/terminal-hygiene/SKILL.md` `## Scratch & Temp-File Hygiene` — never construct host-native absolute paths in a POSIX/git-bash shell.

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

When authoring new issues under these rules, apply the outsider-first authoring convention in `skills/naming-register-policy/SKILL.md` § Outsider-first authoring default.

### 2a. Improvement-First Decision Rule

When any agent discovers an out-of-scope or non-blocking improvement during its work, classify it against the structural-criteria gate (canonical taxonomy in `skills/review-judgment/scripts/Test-DeferralCriteria.ps1`):

- **Inline (fix-in-PR) eligibility**: the change is small, single-file or single-system, doesn't introduce a new abstraction, doesn't cross architecture layer boundaries, and doesn't require a separate design decision. Address within the current task (or current PR if one is open).
- **Follow-up issue creation**: the change matches at least one structural criterion (`S-new-abstraction`, `S-cross-cutting`, `S-design-decision`, `S-schema-or-contract`, `S-different-surface`, `S-maintainer-judgment`). Route the proposed follow-up through the **Filing Approval Gate** (§2e) — as a single-item batch when an interactive parent conversation is available, or via the headless queue when it is not — rather than filing it immediately, then continue with in-scope work. Do not block the current PR on the deferred improvement.

> Supplementary rationale: as a quick sanity check, deferred (structural) issues typically represent more than a day of work, but structural-criteria match — not the effort estimate — is the load-bearing deferral criterion.

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

### 2b-bis. Umbrella or Triage at Creation (Additive to §2b)

Every new issue created by any agent **MUST** be placed under a tracked umbrella **or** left as an ungrouped open issue that the portfolio renderer auto-derives into Triage — this rule is additive to the §2b priority mandate and does not replace it. The intent is unchanged: **a new issue must not silently disappear from the control-tower tracker.** Under Control Tower v2 the mechanism changed (see [Documents/Design/control-tower-v2.md](../../Documents/Design/control-tower-v2.md)).

- **Parent umbrella (child issue)** — if the work is scoped to a tracked initiative, attach the new issue as a native sub-issue of an existing sequenced umbrella. Either create-and-attach in one step with `Add-FollowUpIssue` (canonical create-and-attach helper), or run `gh issue create` first and then attach the already-created issue with `Set-IssueParent` (canonical attach-existing helper).
- **New umbrella → insert at rank** — if you are creating a *new umbrella* (an issue that will own sub-issues), you **MUST** also insert its number into `Documents/Planning/sequence.yaml`'s `umbrellas:` inline list at the correct priority rank. `sequence.yaml` is the **canonical home** for umbrella ranking — do **not** add a routing-tables JSON entry. Then attach the umbrella's own children as native sub-issues with `Set-IssueParent`, exactly as for any other umbrella.
- **Triage (ungrouped open issue)** — if no umbrella applies, just create the issue. Under v2 the renderer **derives** Triage from parent-edge data (open ∧ no parent ∧ no sub-issues ∧ not listed in `umbrellas:`), so an ungrouped open issue is always a Triage **candidate** under the v2 derivation rules — it is never silently excluded from the board count, though it may fall below the cap-5 rendering fold (see Caveat below). The `--label triage` flag is now **optional/advisory** (a human-readable hint only); it is **no longer load-bearing** for Triage placement, because v2 removed the triage-label query entirely. **Caveat**: Triage is capped at 5 issues and sorted priority-first (`Get-PriorityKey` order). An unlabeled issue resolves to `Get-PriorityKey = 3` (lowest rank tier) and may fall below the fold if the Triage bucket is already full. See [Documents/Design/control-tower-v2.md](../../Documents/Design/control-tower-v2.md) for cap and ranking mechanics.

```powershell
# CORRECT — umbrella child (create the issue, then attach it as an existing child with Set-IssueParent):
$url = gh issue create --title "..." --body "..." --label "priority: medium"
# Extract number and attach the already-created issue to the umbrella with Set-IssueParent:
$issueNum = $url -replace '.*/', ''
pwsh skills/safe-operations/scripts/Set-IssueParent.ps1 -ParentIssueNumber 425 -ChildIssueNumber $issueNum

# CORRECT — new umbrella: create it, insert its number into sequence.yaml umbrellas: at
# the right rank, then attach its children as sub-issues. The sequence.yaml edit is
# canonical and mandatory — do NOT add a routing-tables JSON entry.

# CORRECT — ungrouped open issue: v2 auto-derives this into Triage (no label required):
gh issue create --title "..." --body "..." --label "priority: medium"
```

> **Why**: under Control Tower v2 the renderer surfaces every umbrella listed in `sequence.yaml` plus every ungrouped open issue (auto-derived into Triage). A new umbrella that is never inserted into `umbrellas:` is invisible to the board; an ungrouped open issue is surfaced automatically, so no `triage` label is needed to keep it visible. Issues still must not silently disappear from the tracker — the v2 mechanism is parent-edge derivation, not a label scan.

### 2b-ter. Creation-Time Board Positioning (Additive to §2b and §2b-bis)

Before every `gh issue create` or `Add-FollowUpIssue` call, the agent **must** make a conscious positioning decision covering two questions:

**(a) What priority label to apply** — the label controls `Get-PriorityKey` rank within Triage and umbrella children. A deliberate choice of `priority: low` (or no label, which resolves to the lowest rank tier) is a valid and acceptable outcome when the issue genuinely represents low-urgency work.

**(b) Parent-or-standalone** — attach to an active umbrella via `Set-IssueParent`, or leave as a standalone issue that auto-derives into Triage. A deliberate "low priority / standalone / may not stay on board" decision is a valid and acceptable outcome.

**Lever mapping — what the filer controls and its board effect**:

| Lever | Mechanism | Board effect |
| --- | --- | --- |
| **Priority label** (`--label priority:h/m/l`) | Sets `Get-PriorityKey` = 0 (high), 1 (medium), or 2 (low) | Affects rank/sort order within Triage or umbrella children; no label → `Get-PriorityKey = 3` (lowest tier, may fall below Triage fold if bucket is full) |
| **Parent edge** (`Set-IssueParent -ParentIssueNumber N`) | Attaches issue as ActiveChildren of a tracked umbrella | Places issue in the umbrella's children section; requires a spec-listed active umbrella |
| **Standalone** (bare `gh issue create`) | No parent edge set | Auto-derives into Triage under v2 derivation rules |

> **Render-derived buckets (NOT filer-controllable)**: RecentlyClosed, DriftWarnings, and IntegrityWarnings are computed by the renderer from issue state and relationship data — the filer cannot directly place an issue in these zones. See [Documents/Design/control-tower-v2.md](../../Documents/Design/control-tower-v2.md) for cap-5 and priority-ranking mechanics; do not copy those numbers or formulas here.

**Positioning residue** — at creation time, record a single positioning note in the issue body using this format:

```text
Board positioning: priority=<h|m|l>; placement=standalone|parent #N; rationale=<one line>
```

- Record positioning-decision content only — do NOT paste finding detail (issue bodies are world-readable).
- No enforcement script is required; this is an honor-system record for auditability.

**Automated-path carve-out**: on the `Add-FollowUpIssue` automated path, the canonical `[Structural] {criterion_id}` title prefix and the injected `Parent: #N` body field already serve as the positioning record. This satisfies the *placement* portion of the residue — priority is carried by the issue's `--label` flag, and no free-text rationale is required on the automated path. No additional `gh issue edit` step is needed.

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
# Cross-repo dedup — use --repo flag to target the upstream Agent Orchestra repo:
# Read agent-orchestra-repo from .github/copilot-instructions.md first
gh issue list --repo {agent-orchestra-repo} --search "[Gotcha] {skill-name}" --state all --json number,title --jq '.[] | "\(.number): \(.title)"'
```

Key differences from the standard pattern:

- `--repo {agent-orchestra-repo}` targets the upstream template repo (not the current repo)
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

### 2e. Filing Approval Gate (Additive to §2a–§2d)

Some follow-up issues need a maintainer's approve/modify/drop decision before they are filed, batched per review round rather than asked about one at a time. This section is the authoritative methodology for that gate; §2a routes its "follow-up issue creation" outcome through it.

**Gate ownership — parent-conversation-only.** The gate is an interactive checkpoint, so only the parent (dispatching) conversation — the agent that owns the structured-question surface — ever presents it. A subagent (a judge, a prosecution pass, Process-Review, or any dispatched specialist) never fires the gate directly; it returns proposed follow-ups as structured output for the parent to batch and present. When no interactive parent exists at all (a headless run), the queue fallback below applies instead.

**Proposal assembly, before presentation.** Before any batch is shown, each candidate item is computed, not asked about live: its canonical title (via `ConvertTo-CanonicalFollowupTitle`), its §2c deduplication-check result, and its §2b-ter board position (priority label plus parent-or-standalone placement). Two kinds of items are excluded from the batch entirely rather than re-presented: an item whose canonical title dedup-matches an already-open issue, and an item whose `followup-` key (see `Get-FollowupRecordKey` below) already carries a prior drop or modify record. This exclusion is also what keeps an approval "implicit" across later rounds — an approved-and-filed item is found by the same assembly-time dedup check on every subsequent ruling, so it is never re-asked about.

**Modify-re-dedup.** When a maintainer modifies a proposal's title as part of the "Modify" outcome below, that new title is not filed blindly — it re-runs the §2c dedup search. If the modified title now matches an existing issue, the gate records a modify-entry that points at that existing issue instead of filing a duplicate.

**Batched presentation fields.** Each item in the batch is shown with: the proposed title, a one-line rationale, the judge disposition that produced it (or `—` when the item was not adjudicated by a judge, e.g. a §2a discovery), its severity, its computed board position, and its dedup status from proposal assembly.

**Per-item outcomes.** The maintainer disposes of each item as one of three outcomes:

- **Approve** — file the issue as proposed, with `Add-FollowUpIssue -FilingProvenance 'gate-approved'`.
- **Modify** — the maintainer edits the title, scope, or severity; the edited title re-runs dedup per "Modify-re-dedup" above, and (absent a dedup hit) files with `-FilingProvenance 'gate-modified'`.
- **Drop** — do not file; record the decision durably (see "Durable `followup-` entries" below) so the item is not re-proposed on a later ruling.

**Record-before-file ordering, with honest crash semantics.** The durable decision record for a batch is written before any filing side effect executes. This has one important asymmetry: an approved item that has not yet been filed has no durable "worklist" entry of its own — the filed issue itself is the record once it exists, so approvals are implicit rather than tracked. Read together with proposal assembly's dedup exclusion, this makes crash recovery honest rather than silent: if a run crashes after recording a batch but before filing every approved item, the un-filed approval is simply re-presented — and, per assembly-time dedup, re-filed exactly once — on the next ruling. It is neither lost nor double-filed.

**Durable `followup-` entries.** Drops and modifies persist as `followup-`-prefixed entries in the phase-matching engagement-record comment, using `Get-FollowupRecordKey` to derive the entry's key and `Merge-FollowupRecords` to union each fresh write with every prior `followup-` entry already on record. The authoritative marker-head state values are `'proposed'`, `'claimed'`, and `'consumed'` (see `.github/scripts/lib/followup-gate-core.ps1`). This cumulative re-emission, plus its unbroken-chain guard (a fresh marker that would otherwise drop a previously-recorded key triggers a loud warning instead of a silent drop), is what keeps an old drop or modify decision from being shadowed by a later ruling's write.

**Counts line.** Each ruling's gate decision emits a `proposed: N, approved: K, modified: M, dropped: D` counts line in the same engagement-record comment as the per-item decisions. These counts are a snapshot of the batch outcome captured at decision time, not a value re-derived from durable entries afterward — because approved items have no durable entry of their own (see "Record-before-file ordering" above), a post-hoc derivation would undercount approvals.

**Headless queue fallback.** When no interactive surface is available at all, the run posts exactly one `<!-- proposed-followups-{PR|ISSUE} -->` comment — built and written with `New-ProposedFollowupsComment` / `Write-ProposedFollowupsComment`, which itself reuses `find-or-upsert-comment.ps1` rather than opening a new `gh` call path — and files nothing. A later gate-capable session claim-stamps and then consumes that comment before presenting its contents as a batch. A proposal that targets a different repository than the one the run is on — for example, an upstream-gotcha finding meant for a template repo — still queues on the *current* repo's tracking artifact; its payload simply carries an explicit `target_repo` field so the eventual consumer knows where to file it.

**Non-overridability.** The gate is in the same non-overridable class as plan approval and the other engagement-gate methodology checkpoints: a pacing directive such as "work without stopping" or "don't pause to ask" does not suppress it. See `CLAUDE.md` § Engagement-gate non-overridability for the full contract.

**Direct-request exemption.** A maintainer's explicit request — "file an issue for X" — bypasses the gate entirely; the issue is filed immediately with `-FilingProvenance 'direct-request'`.

## Gotchas

| Trigger                                 | Gotcha                                                             | Fix                                                                                                   |
| --------------------------------------- | ------------------------------------------------------------------ | ----------------------------------------------------------------------------------------------------- |
| Editing workspace files from PowerShell | Silent encoding or line-ending corruption slips into tracked files | Use the designated file tools for content changes and keep terminal writes for move/delete cases only |
