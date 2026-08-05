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

### 2a. Improvement-First Decision Rule — one floor, three moments

**The six structural criteria — canonical statement.** A change is **structural** if it would do any of the following (identifiers implemented one-for-one in `skills/review-judgment/scripts/Test-DeferralCriteria.ps1`, the canonical taxonomy):

1. introduce a new abstraction, agent, skill, or public API (`S-new-abstraction`);
2. cross an architecture layer boundary, or span four or more modules (`S-cross-cutting` — the script checks the module count first);
3. require a separate design decision (`S-design-decision`);
4. change a schema or contract (`S-schema-or-contract`);
5. touch a different surface than the work at hand (`S-different-surface`) — at pickup, read this as: the fix would land somewhere other than the surface the filed issue is about; at review time the script's operand is disjointness from the PR's file set;
6. need a maintainer's judgment call (`S-maintainer-judgment`).

A change that trips **none** of the six is below the structural floor. **The same six criteria decide three distinct moments** (#957 D6, decision `d-one-floor-three-moments`). This section is the canonical prose statement; the predicates live in `skills/review-judgment/scripts/Test-DeferralCriteria.ps1`, and two consumption-contract surfaces carry moment-3's PR-scoped operand detail — `agents/Code-Review-Response.agent.md` § Structural Deferral Guidelines and `Documents/Design/code-review.md` § Structural Criteria Taxonomy. Those are consumers of the same six identifiers, not second floors; at moment 3 the script's predicates govern wherever prose and predicate differ. An earlier revision of this rule carried a five-property prose paraphrase of inline eligibility ("small, single-file or single-system, …") alongside the six identifiers; the two lists were not the same set, and the paraphrase is retired — the six identifiers are the statement.

**Moment 1 — the trivial floor at pickup (open-for-work).** Whether a filed issue is below the trivial floor is read from the **filed issue alone**, at the moment someone opens it for work: no pull request, no `$Finding` object, and no script invocation exists yet, so this is a reading of the six criteria by the person or agent picking the issue up, not a `Test-DeferralCriteria.ps1` run. **Risk guard (#957 D6)**: at this moment, a change touching **permission, authentication, or data-integrity behavior is never below the floor, regardless of size** — below the trivial floor there is no brief, no adversarial review, and no plan review, so pull-request review is the only review that will ever see the change, and the six structural criteria alone are not a safe proxy for risk on those three behaviors. **Unresolvable case**: §2f requires no proposed solution or scope at filing, so a filed issue routinely does not establish whether the eventual change avoids those three behaviors — that is the expected pickup state, not an edge case. When the filed issue does not establish that the change **avoids** permission, authentication, or data-integrity behavior, the guard fails closed: treat it as touching that behavior, and it is never below the floor. Verdict below the floor: **fix it directly** — no brief, no run ceremony (`Documents/Design/open-for-work.md` § The trivial floor).

**Moment 2 — mid-run follow-up disposition (this rule's original moment).** When any agent discovers an out-of-scope or non-blocking improvement during its work: if the change trips none of the six criteria, address it within the current task (or current PR if one is open). If it trips at least one, route the proposed follow-up through the **Filing Approval Gate** (§2e) — as a single-item batch when an interactive parent conversation is available, or via the headless queue when it is not — rather than filing it immediately, then continue with in-scope work. Do not block the current PR on the deferred improvement.

**Moment 3 — review deferral.** `Test-DeferralCriteria.ps1` applies the same six identifiers to review findings, yielding `ACCEPT (fix inline)` when none match and `DEFERRED-SIGNIFICANT (structural)` when at least one does — with one override: the **AC cross-check takes absolute precedence**, so a finding that maps to an explicit acceptance criterion is force-accepted inline even when structural criteria match (consumption contract in `agents/Code-Review-Response.agent.md` § Structural Deferral Guidelines).

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

**Batched presentation fields.** Each item in the batch is shown in two parts. The **computed fields** are the proposed title, a one-line rationale, the judge disposition that produced it (or `—` when the item was not adjudicated by a judge, e.g. a §2a discovery), its severity, its computed board position, and its dedup status from proposal assembly. The **argued cases** are the two decisions the maintainer actually rules on, and both are required per item. **A presentation carrying only the computed fields is nonconforming**: it reports decisions already taken instead of making the case for the ones being asked.

- **(i) The file-vs-do-now case.** Name the structural criterion the change trips (§2a moment 2) **and** state why handling it inline — in the current task, or folded into the open PR — is the wrong call *for this specific change*: what about it exceeds the current run's scope, blast radius, ownership, or decision authority. The `[Structural] {criterion_id}` title prefix is the criterion's *label*, not this case.
- **(ii) The placement case.** State the proposed placement **and** why it beats the alternatives actually available — this umbrella, versus standalone Triage, versus a new umbrella. Name the competing umbrella that was considered and say why it loses; for a standalone proposal, name the umbrella closest to the topic and say why the item does not belong under it. The computed board position is the *outcome* of the placement decision, not this case.

**Conformance test for both cases.** A case is conforming only if it carries content that no already-computed field carries: a comparison against a named alternative, or a reason grounded in this change's own properties. A sentence whose every substantive token is fillable from values proposal assembly already produced — the criterion id, the parent number, the severity — is a template, not an argument, and the presentation is nonconforming even though a "case" field is populated. If a batch's cases could all be generated by substituting computed values into one fixed sentence, nothing has been argued.

**Per-item outcomes.** The maintainer disposes of each item as one of three outcomes:

- **Approve** — file the issue as proposed, with `Add-FollowUpIssue -FilingProvenance 'gate-approved'`.
- **Modify** — the maintainer edits the title, scope, or severity; the edited title re-runs dedup per "Modify-re-dedup" above, and (absent a dedup hit) files with `-FilingProvenance 'gate-modified'`.
- **Drop** — do not file; record the decision durably (see "Durable `followup-` entries" below) so the item is not re-proposed on a later ruling.

**Record-before-file ordering, with honest crash semantics.** The durable decision record for a batch is written before any filing side effect executes. This has one important asymmetry: an approved item that has not yet been filed has no durable "worklist" entry of its own — the filed issue itself is the record once it exists, so approvals are implicit *as worklist entries* rather than tracked. (The ruling that produced them is nonetheless recorded — see "Ruling record" below; that is what keeps this asymmetry from making an approve-only ruling traceless.) Read together with proposal assembly's dedup exclusion, this makes crash recovery honest rather than silent: if a run crashes after recording a batch but before filing every approved item, the un-filed approval is simply re-presented — and, per assembly-time dedup, re-filed exactly once — on the next ruling. It is neither lost nor double-filed.

**Ruling record — every ruling, approve-only batches included.** Every gate ruling owes exactly one durable, batch-scoped **ruling record**, written at decision time, before any filing side effect. It is a `followup-`-prefixed entry in the phase-matching engagement-record comment, keyed with `Get-FollowupRecordKey -RawKey "gate-ruling:{surface}:{decision timestamp, ISO-8601}"` — where `{surface}` is the `pr-{N}` or `issue-{N}` the ruling was presented against — so two rulings on the same surface never collide on one key. It carries:

- the ruling's counts line (`proposed: N, approved: K, modified: M, dropped: D`); and
- one line per item in the batch: the item's **canonical title exactly as it will be filed** (for a modified item, the title as approved), and its outcome — `approved`, `modified`, or `dropped`.

The counts line is also what tells a reader a `followup-` entry is a ruling record rather than one of the per-item drop/modify entries below: both share the key prefix, only the ruling record carries counts.

This is deliberately batch-scoped rather than per-item. The per-item `followup-` entries below record drops and modifies so they are not re-proposed; the ruling record records that the ceremony *happened* and what it produced. An approved item still gets no worklist entry of its own — but the ruling that approved it is now locatable from the filed issue, which is what makes its provenance stamp checkable at all.

**Why the ruling record must be `followup-`-prefixed.** The engagement-record family is read latest-comment-wins **per phase**: a later marker for the same phase shadows an earlier one wholesale. `followup-`-prefixed entries are exempt from that hazard, because `Merge-FollowupRecords` unions across *every* prior marker — sourced from the uncapped `Get-FollowupPriorMarkerBodies` read and parsed marker-by-marker rather than as one latest-wins batch — and its unbroken-chain guard raises a loud warning rather than silently dropping a key. A ruling record filed under any non-`followup-` key, or written in a fresh marker that does not carry prior entries forward, is destroyed by the next same-phase write; every lawful stamp it backed then reads "unsupported" from that moment on. Compose with this family; do not invent a parallel record type.

**When the ruling-record write fails.** If the ruling record cannot be written durably, **the filing does not proceed.** The approved items stay un-filed, and the write failure is reported to the maintainer rather than swallowed. Nothing is lost: per proposal assembly's dedup exclusion the batch is simply re-presented on the next ruling. This branch is stated rather than left silent on purpose — a filing that proceeded after a failed record write would produce a ruling-asserting stamp with no locatable record, which the reconciliation procedure below cannot distinguish from a bypass, converting an infrastructure failure into a false accusation against a lawful ruling. If the maintainer wants an item filed anyway while the write path is broken, that is a direct request and files with `-FilingProvenance 'direct-request'` — honestly out of the procedure's domain rather than falsely inside it.

**Provenance domain — which stamps assert that a ruling occurred.** The five-value provenance enum (authoritatively owned by the `-FilingProvenance` ValidateSet in `skills/safe-operations/scripts/Add-FollowUpIssue.ps1`) splits in two:

| Value | Asserts a gate ruling? | What the stamp claims |
| --- | --- | --- |
| `gate-approved` | **yes** | a maintainer approved this item in a presented batch |
| `gate-modified` | **yes** | a maintainer edited and then approved this item in a presented batch |
| `queue-consumed` | **yes** | a gate-capable session consumed a queued proposal and ruled on it |
| `direct-request` | no | the maintainer asked for this issue directly; the gate is bypassed by design (see "Direct-request exemption") |
| `pre-gate-legacy` | no | filed by a surface with no callable gate orchestrator — "filed before any gate existed", **not** "cleared under an older gate" |

All three ruling-asserting values are in the reconciliation procedure's domain. Scoping the domain to `gate-approved` alone would leave the modify and queue-consume paths — which are rulings just as much as approvals are — permanently unchecked.

**Reconciliation procedure — executable by a reader holding only the filed issue.** No locator field is needed on the filing; every input below is already present in a helper-filed issue body.

1. Read the `<!-- filing-provenance: {value} -->` marker from the issue body. If it is **absent**, the filing bypassed the filing helper entirely and is already non-compliant by shape; that case is outside this procedure and needs no verdict from it.
2. If the value is `direct-request` or `pre-gate-legacy`, the outcome is **out of domain**, and the procedure stops. These values assert no ruling, so no record is owed. Reporting them as "unsupported" is a false alarm — and a procedure that emits one across the whole pre-gate corpus trains the reader to ignore the signal on the day it is real.
3. Otherwise the stamp asserts a ruling. Derive the search surfaces from the filing alone: the `originating_pr` field of the `<!-- code-conductor-filed-followup -->` sentinel block, and the `Parent: #N` line. For `queue-consumed`, the `<!-- proposed-followups-{PR|ISSUE} -->` comment on those same surfaces is also in scope.
4. Read **every** comment on those surfaces — not the newest marker per phase — and collect every `followup-`-prefixed entry from every engagement-record marker found. Use the uncapped read (`Get-FollowupPriorMarkerBodies`); a `gh ... --json comments` fetch caps at 100 comments and can shadow the record on a busy thread.
5. The outcome is **located** when some ruling record in that set lists this issue's title with an outcome matching the stamp (`approved` for `gate-approved`; `modified` for `gate-modified`; either for `queue-consumed`) and was created at or before the issue's own `createdAt`. Otherwise the outcome is **unsupported**.

**What the verdicts mean, and the trust bound.** An **unsupported** verdict on a ruling-asserting stamp is a defect signal — the ceremony's trace is missing where the stamp claims one exists — not proof of misconduct. And the bound is honest: **every artifact in this system is agent-written, so a located record evidences that the ruling ceremony ran and left a batch-scoped trace, never who ruled.** A session that fabricates a ruling record defeats any artifact-side check, and no wording here should suggest otherwise. What this contract delivers is **detection** of a missing trace — the honest-omission class, where a session skips the ceremony under load and stamps anyway — not prevention of a determined bypass.

**Durable `followup-` entries.** Drops and modifies persist as `followup-`-prefixed entries in the phase-matching engagement-record comment, using `Get-FollowupRecordKey` to derive the entry's key and `Merge-FollowupRecords` to union each fresh write with every prior `followup-` entry already on record. This cumulative re-emission, plus its unbroken-chain guard (a fresh marker that would otherwise drop a previously-recorded key triggers a loud warning instead of a silent drop), is what keeps an old drop or modify decision from being shadowed by a later ruling's write.

**Counts line.** Each ruling's gate decision emits a `proposed: N, approved: K, modified: M, dropped: D` counts line, carried by that ruling's ruling record in the same engagement-record comment as the per-item decisions. These counts are a snapshot of the batch outcome captured at decision time, not a value re-derived from durable entries afterward — because approved items have no worklist entry of their own (see "Record-before-file ordering" above), a post-hoc derivation would undercount approvals. The counts line alone does not satisfy the ruling record: reconciliation matches a *title* against the record's per-item lines, and a bare count matches nothing.

**Headless queue fallback.** When no interactive surface is available at all, the run posts exactly one `<!-- proposed-followups-{PR|ISSUE} -->` comment — built and written with `New-ProposedFollowupsComment` / `Write-ProposedFollowupsComment`, which itself reuses `find-or-upsert-comment.ps1` rather than opening a new `gh` call path — and files nothing. The comment's marker-head state advances through the authoritative values `'proposed'`, `'claimed'`, and `'consumed'` (see `Set-ProposedFollowupsCommentState` in `.github/scripts/lib/followup-gate-core.ps1`). A later gate-capable session claim-stamps and then consumes that comment before presenting its contents as a batch; when a consumed queue proposal is filed, the filing call uses `Add-FollowUpIssue -FilingProvenance 'queue-consumed'`, distinguishing it from a same-session interactive approval (which uses `gate-approved`). A proposal that targets a different repository than the one the run is on — for example, an upstream-gotcha finding meant for a template repo — still queues on the *current* repo's tracking artifact; its payload simply carries an explicit `target_repo` field so the eventual consumer knows where to file it.

> **Known gap — queued proposals carry neither argued case.** The queue payload schema predates the argued-case requirement above and carries only the computed fields. So on the path with the *least* live context attached, proposals reach the eventual gate-capable session with the *least* justification: that session must reconstruct both cases from the finding itself before it can present a conforming batch, and where it cannot, the honest outcome is to drop the item — never to present a computed-fields-only batch and call the gate satisfied. Extending the payload with the two case fields is **deliberately deferred, not overlooked**: `New-ProposedFollowupsComment` has no live call site, and no issue or PR carries a proposed-followups comment, so the path has never fired and a schema change would be building for an unexercised population. This gap closes when the queue gets a live producer.

**Non-overridability.** The gate is in the same non-overridable class as plan approval and the other engagement-gate methodology checkpoints: a pacing directive such as "work without stopping" or "don't pause to ask" does not suppress it. See `CLAUDE.md` § Engagement-gate non-overridability for the full contract.

**Direct-request exemption.** A maintainer's explicit request — "file an issue for X" — bypasses the gate entirely; the issue is filed immediately with `-FilingProvenance 'direct-request'`.

### 2f. Filing Content Standard (#957 `d-filing-shape`)

The other subsections here govern the mechanics and placement of filing — priority labels, umbrella attachment, dedup, the approval gate — and §2a governs the structural floor across its three moments. This one states what belongs **in** the issue body, and it is deliberately short. A filed issue carries three things:

1. **The problem** — what is wrong or missing, in plain language.
2. **The evidence it is real** — what was observed, where, and how someone else could see it too. A hunch is fine to file; say it is a hunch.
3. **What is known versus unknown** — which claims are established and which are open questions.

**That is the whole obligation.** Nothing else is required to file: no proposed solution, no design, no scope or routing decision, no scenarios, and no estimate. Those are produced later — by the open-for-work conversation (`Documents/Design/open-for-work.md`) or by an explicitly requested phase pipeline — *if* the issue is ever opened for work. A proposed solution may be included when the filer already has one in mind, but its absence never blocks or discounts a filing. The repository's issue templates (`.github/ISSUE_TEMPLATE/`) ask for exactly the three items above and say so.

The known-versus-unknown split is not decoration: it is the direct input to the open-for-work routing beat, which classifies each open unknown by whether it could change what is being built. A filing that is honest about what it does not know is worth more than one that papers over it with a confident solution sketch.

## Gotchas

| Trigger                                 | Gotcha                                                             | Fix                                                                                                   |
| --------------------------------------- | ------------------------------------------------------------------ | ----------------------------------------------------------------------------------------------------- |
| Editing workspace files from PowerShell | Silent encoding or line-ending corruption slips into tracked files | Use the designated file tools for content changes and keep terminal writes for move/delete cases only |
