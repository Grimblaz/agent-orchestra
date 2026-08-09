---
name: safe-operations
description: "Safe file-operation, issue-creation, and git/gh state-claim protocol for Agent Orchestra. Use when choosing workspace tools, avoiding unsafe file writes, creating GitHub issues under the workflow rules, reporting CI state, claiming a test failure is pre-existing, writing to a GitHub comment or PR body, acting on a cleanup detector's output, or bumping the plugin version. DO NOT USE FOR: application-level debugging or replacing agent judgment on whether work is in scope."
---

# Safe Operations Instructions

## Purpose

Establish safe, consistent rules for file operations, issue creation, and the git/`gh`/worktree operations agents use to inspect and change repository state. These rules prevent silent file corruption, ensure GitHub issues are always properly labeled, and keep state claims and destructive cleanup honest.

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

- **Approve** — file the issue as proposed, with `Add-FollowUpIssue -OriginatingPr {N} -FilingProvenance 'gate-approved'`, where `{N}` is the **bare number** of the surface the batch was presented against (not the `pr-{N}` spelling the ruling-record key uses). An anchor is required for this stamp — `-OriginatingPr`, or a `Parent: #N` line naming that surface; see "Anchor requirement" below.
- **Modify** — the maintainer edits the title, scope, or severity; the edited title re-runs dedup per "Modify-re-dedup" above, and (absent a dedup hit) files with `-OriginatingPr {N} -FilingProvenance 'gate-modified'` — the same anchor requirement.
- **Drop** — do not file; record the decision durably (see "Durable `followup-` entries" below) so the item is not re-proposed on a later ruling.

**Record-before-file ordering, with honest crash semantics.** The durable decision record for a batch is written before any filing side effect executes. This has one important asymmetry: an approved item that has not yet been filed has no durable "worklist" entry of its own — the filed issue itself is the record once it exists, so approvals are implicit *as worklist entries* rather than tracked. (The ruling that produced them is nonetheless recorded — see "Ruling record" below; that is what keeps this asymmetry from making an approve-only ruling traceless.) Read together with proposal assembly's dedup exclusion, this makes crash recovery honest rather than silent: if a run crashes after recording a batch but before filing every approved item, the un-filed approval is simply re-presented — and, per assembly-time dedup, re-filed exactly once — on the next ruling. It is neither lost nor double-filed.

**Ruling record — every ruling, approve-only batches included.** Every gate ruling owes exactly one durable, batch-scoped **ruling record**, written at decision time, before any filing side effect. It is a `followup-`-prefixed entry in the phase-matching engagement-record comment, keyed with `Get-FollowupRecordKey -RawKey "gate-ruling:{surface}:{decided_at}"` — `{surface}` is `pr-{N}` or `issue-{N}` for the surface the batch was presented against, and `{decided_at}` is a **UTC ISO-8601 instant carrying at least millisecond precision** (`2026-08-05T06:27:18.412Z`). Two rulings on one surface must never share a `{decided_at}`: if a writer's clock cannot separate them, it advances the value until it is strictly greater than the previous ruling's on that surface. Precision is a floor, not a format — never truncate, because a truncated value can also make a record appear to precede a filing it actually followed, which step 6's ordering clause reads as genuine.

> **Pin that precision.** At coarser precision (a bare date, minutes, or even whole seconds for two rulings inside one second) two rulings on one surface derive the *same* key — verified: `Get-FollowupRecordKey -RawKey 'gate-ruling:pr-1014:2026-08-05'` run twice yields one key, and merging a second record under it silently keeps only the newer content while emitting **no warning**. The unbroken-chain guard cannot catch this: it tests key *presence*, not content, so a same-key write is invisible to it.

The entry carries these fields. All four are **additive optional fields** under the engagement-record schema — readers ignore unknown optional fields, so no `schema_version` bump is owed:

| Field | Contents |
| --- | --- |
| `gate_ruling_counts` | `proposed: N, approved: K, modified: M, dropped: D` |
| `gate_ruling_surface` | the surface the batch was **presented against**, as `pr-{N}` or `issue-{N}` — written `owner/repo#N` whenever that is not the repo the record itself lives in |
| `gate_ruling_decided_at` | the decision timestamp: the same millisecond-or-finer UTC string hashed into the key, never truncated |
| `gate_ruling_items` | one entry per batch item, each with `title` — the canonical title **exactly as it will be filed**, i.e. the maintainer's text *after* `ConvertTo-CanonicalFollowupTitle`, not before — and `outcome` (`approved`, `modified`, or `dropped`) |

`gate_ruling_counts` is also what tells a reader a `followup-` entry is a ruling record rather than one of the per-item drop/modify entries below: both share the key prefix, only the ruling record carries counts. Recording `gate_ruling_decided_at` and `gate_ruling_surface` as fields is not redundancy with the key — the key is a truncated SHA-256, so neither value is recoverable from it, and the reconciliation procedure needs both.

This is deliberately batch-scoped rather than per-item. The per-item `followup-` entries below record drops and modifies so they are not re-proposed; the ruling record records what the ruling produced. An approved item still gets no worklist entry of its own — but the ruling that approved it is now locatable from the filed issue, which is what makes its provenance stamp checkable at all.

**Serialize every scalar field value with `ConvertTo-FollowupYamlString` — including non-free-text scalars such as `gate_ruling_counts`, and each `title` inside `gate_ruling_items`.** Do **not** pass `gate_ruling_items` itself through it: that field is a sequence, and the helper escapes a *scalar*, so it renders as the string `"System.Object[]"`, which parses cleanly and then matches nothing — a silent unreconcilable record, which is worse than the throw. Scope the helper to scalars, and emit the sequence as YAML. The clause is not scoped to free text either: the counts value `proposed: N, approved: K, …` is itself a colon-space mapping indicator, so a bare rendering of the field this contract mandates on *every* ruling record throws at parse. Verified by execution. Canonical titles open with `[` (a YAML flow-sequence indicator) and contain a colon-space pair (a mapping indicator). Rendering one unquoted — or quoting it naively around an embedded `"` — throws at parse, verified by execution. And the failure is not local: `Read-EngagementRecords` drops the **entire marker's** decisions on a YAML error, so one awkward title makes every ruling record in that comment unfindable and every stamp it backed read "unsupported". The helper that escapes correctly already exists in the gate's own library; use it.

**Write the record on the surface the reader will search.** The record must be written on the surface named in `gate_ruling_surface`, and that surface must be one the *filed issue* can derive — which is what the anchor requirement below guarantees. Nothing else ties the ruling's presentation locus to the reader's search set, and a record written where the reader cannot look is a record that does not exist for reconciliation.

**Anchor requirement for ruling-asserting filings.** A filing stamped `gate-approved`, `gate-modified`, or `queue-consumed` **must** carry `-OriginatingPr` naming the surface the batch was presented against (or, when the ruling was presented against an issue, a `Parent: #N` line naming that issue). Both fields are optional in the filing helper by design, and that is fine for the non-asserting values — but a ruling-asserting stamp with neither anchor gives the reconciliation procedure nothing to search, and the honest verdict for it is *not-reconcilable*, not "unsupported". Note what this anchor is and is not: it names a **surface to search**, not the record itself. A filer-authored pointer *at* the record would reconcile vacuously — the reader must still find a real batch-scoped record on that surface, written before the filing, listing this title.

**Why the ruling record must be `followup-`-prefixed.** Not because a non-`followup-` record would be *destroyed* — the engagement-record family is `post-new`, so a later write posts a new comment and never edits the earlier one, and the reconciliation procedure below reads every comment rather than the newest marker per phase. The real reason is narrower and still binding: the tooling read path (`Merge-FollowupRecords`) filters to `followup-`-prefixed keys and drops everything else, so a record under any other key is invisible to every mechanized reader even though its bytes survive. Its unbroken-chain guard also warns loudly rather than silently dropping a key it carried before. Compose with this family; do not invent a parallel record type.

> **The destruction vector that is real.** A hand-composed whole-body `gh api -X PATCH` rewrites a comment wholesale and destroys a `followup-`-keyed ruling record exactly as readily as any other — this happened to nine comments on 2026-08-05 and is the subject of #1011. Key prefix is no defense against it; disclosure before the write is (see `Get-CoLocatedMarkerFamily`).

**Carry the phase's other decisions forward.** The ruling-record write lands **mid-phase**, and the engagement-record family is read latest-comment-wins per phase: every non-`followup-` reader — `solution-authoring`'s same-decision-resume, the L2 gate reconciler — sees only the newest marker for that phase. `Merge-FollowupRecords` will not help, because it unions the `followup-` family and drops every non-`followup-` key. So a ruling-record write must re-emit the newest prior same-phase marker's full `load_bearing_decisions` set alongside the merged `followup-` entries. A write that does not orphans decisions it never touched — the same hazard `SMC-20` already documents for the open-for-work second writer, now reached on every ruling.

**When the ruling-record write fails.** If the ruling record cannot be written durably, **the filing does not proceed.** The approved items stay un-filed, and the write failure is reported to the maintainer rather than swallowed. Nothing is lost: per proposal assembly's dedup exclusion the batch is simply re-presented on the next ruling. This branch is stated rather than left silent on purpose — a filing that proceeded after a failed record write would produce a ruling-asserting stamp with no locatable record, which the reconciliation procedure below cannot distinguish from a bypass, converting an infrastructure failure into a false accusation against a lawful ruling. If the maintainer wants an item filed anyway while the write path is broken, that is a direct request and files with `-FilingProvenance 'direct-request'` — honestly out of the procedure's domain rather than falsely inside it.

**Provenance domain — which stamps assert that a ruling occurred.** The five-value provenance enum (authoritatively owned by the `-FilingProvenance` ValidateSet in `skills/safe-operations/scripts/Add-FollowUpIssue.ps1`) splits in two:

| Value | Asserts a gate ruling? | What the stamp claims |
| --- | --- | --- |
| `gate-approved` | **yes** | a maintainer approved this item in a presented batch |
| `gate-modified` | **yes** | a maintainer edited and then approved this item in a presented batch |
| `queue-consumed` | **yes** | a gate-capable session consumed a queued proposal and ruled on it |
| `direct-request` | no | the maintainer asked for this issue directly; the gate is bypassed by design (see "Direct-request exemption") |
| `pre-gate-legacy` | no | filed by a surface that has no callable gate orchestrator to hand off to. **Not** "cleared under an older gate" — and **not** purely historical either: `create-improvement-issue-core.ps1` stamps it today on an active headless surface (#837 R1), so this value marks an **ongoing exemption**, not a closed era. Its own docstring reads "filed without interactive gating", which is the accurate gloss. |

All three ruling-asserting values are in the reconciliation procedure's domain. Scoping the domain to `gate-approved` alone would leave the modify and queue-consume paths — which are rulings just as much as approvals are — permanently unchecked.

**Reconciliation procedure — for a reader holding the filed issue.** Every input is present in a conforming helper-filed issue body; no pointer at the record itself is needed, or wanted (see the anchor requirement above). The procedure has **five** outcomes, and the three negative ones are deliberately distinct — collapsing them is how a detection mechanism turns into a false-accusation generator.

1. Read the `filing-provenance` marker (an HTML comment carrying `filing-provenance: {value}`) from the issue body. If it is **absent**, the filing bypassed the filing helper entirely and is already non-compliant by shape; that case is outside this procedure and needs no verdict from it.
2. If the value is `direct-request` or `pre-gate-legacy`, the outcome is **out of domain**, and the procedure stops. These values assert no ruling, so no record is owed. Reporting them as "unsupported" is a false alarm — and a procedure that emits one across an entire exempt population trains the reader to ignore the signal on the day it is real.
3. If the value is not one of the five enum members — a typo, or a coinage like `gate-cleared` — the outcome is **not-reconcilable**: the filing is malformed by shape and asserts nothing this procedure can check. Do not treat an unrecognized value as ruling-asserting; that manufactures an accusation out of a spelling mistake.
4. Otherwise the stamp asserts a ruling. Derive the search surfaces from the filing: the `originating_pr` field of the `code-conductor-filed-followup` sentinel block, and the `Parent: #N` line. Resolve each against the repo the filing lives in unless the value is repo-qualified. For `queue-consumed`, the `proposed-followups` queue comment on those same surfaces is also in scope — but see step 6's queue note: the queue payload alone never satisfies `located`.
   - If **neither** anchor is present, the outcome is **not-reconcilable**: the filing violates the anchor requirement (or predates it), so there is nowhere to look. This is a compliance defect in the *filing*, not evidence about the ruling, and it must never be reported as "unsupported".
5. Read **every** comment on those surfaces — not the newest marker per phase — and collect every `followup-`-prefixed entry from every engagement-record marker found. Use the uncapped read (`Get-FollowupPriorMarkerBodies`); a `gh ... --json comments` fetch caps at 100 comments and can shadow the record on a busy thread.
   - **Check that the read succeeded.** That helper returns an empty set on five distinct failure paths — unresolvable repo, a `gh api` exception, a non-zero `gh` exit (an expired token or a rate limit lands here), empty output, and an unparseable response — and one of them emits no warning at all. An empty set that came from a *failed* read means the outcome is **could-not-verify**; stop there and say so. The helper cannot tell you which it was — it returns a bare empty set for all five failure paths *and* for a genuine success on a comment-free thread — so discriminate with one probe per derived surface: call `gh api repos/{owner}/{repo}/issues/{N}/comments --paginate` and read its **exit code**. Non-zero is a failed read; zero with an empty array is a real, empty thread. Reporting a transport failure as "unsupported" converts an infrastructure problem into an accusation, which is exactly what the failed-write branch above refuses to do on the write side. **But note the asymmetry the anchor introduces**: the anchor is filer-supplied, so a filing naming a surface that does not exist also lands here, and that is a compliance defect in the filing rather than a neutral outcome. When **every** derived surface fails to resolve, the outcome is *not-reconcilable*, not *could-not-verify*; when at least one resolves, continue with the ones that do — a single bad anchor beside a good one never blocks a `located`. Reader-side failures are **not** in this class: a permissions or rate-limit failure depends on who is reading, not on the filing, so it stays *could-not-verify* — otherwise two readers reach different verdicts on the same artifact and the one lacking access reports a filing defect that does not exist.
   - **The sixth way to get an empty result is your own call, and the exit-code probe cannot see it.** The five above are paths through the helper; this one sits outside it — the probe is a *separate* `gh` call, and it exits `0` and reports the surface readable while every filing still reads *unsupported*. Verified the hard way on this procedure's first execution (2026-08-08). The two mistakes fail in opposite ways, so one remedy cannot cover both:
     - **`-Number`, not `-IssueNumber`.** This fails at parameter binding and throws a `ParameterBindingException` before the helper runs at all — loud when the call stands bare, and silently swallowed the moment it sits in a `try`/`catch`. So do not wrap it in one: the wrapper is the silencer, not the throw. `-ErrorAction SilentlyContinue` and `2>$null` do not silence it either, because binding fails before the cmdlet's error stream exists.
     - **Objects carrying `.Body`, not bare strings.** This one never throws — wrapped or not, under any `ErrorActionPreference`, under `StrictMode` — and it returns no empty set to notice. The helper hands back its normal objects, each of which stringifies to `@{Body=…}` and therefore still *matches* a naive text probe while parsing to zero records. Measured on PR #1014: 11 comments and 3 text hits either way, but **3** parsed `followup-` entries read correctly against **0** read mis-shaped.

     Discriminate before you trust a single *unsupported* in the reconciliation batch: run one **positive control**. Point the reader at a surface known to carry a ruling record — today exactly one qualifies, PR #1014's ruling record (comment `5200490355`) — pass `-Repo` explicitly so a fork checkout cannot silently resolve you onto a different corpus, and require it back **non-empty at the grain this step actually consumes**: parsed `followup-`-prefixed entries, not comments and not raw text hits, since only that grain catches both mistakes. **If the control comes back empty, the outcome is `could-not-verify` for every filing in the run** — say so and stop, exactly as a failed transport read does above. Reporting *unsupported* off a failed control measures your own reader, not the corpus.
6. The outcome is **located** when some ruling record in that set has a `gate_ruling_items` entry whose `title` matches this issue's title with an `outcome` matching the stamp (`approved` for `gate-approved`; `modified` for `gate-modified`; either for `queue-consumed`), and whose `gate_ruling_decided_at` is at or before the issue's own `createdAt`. Otherwise the outcome is **unsupported**.
   - **Match semantics** are exact, ordinal, case-sensitive, after trimming leading and trailing whitespace on both sides and normalizing to UTF-8. State this because it is not free: PowerShell's `-eq`, `-match`, and `-contains` are case-*insensitive*, and `gh` output OEM-mangles non-ASCII characters on Windows — `§`, em-dashes, and emoji all appear in real canonical titles. A reader who cannot read both sides in the same encoding has a **could-not-verify**, not an "unsupported".
   - **Use `gate_ruling_decided_at`, not the comment's `createdAt`.** `Merge-FollowupRecords` re-emits prior entries into each new marker and keeps the newest copy per key, so a mechanized reader routinely receives a copy whose containing comment postdates the filing. Comparing against the comment would fail the ordering test on a genuine record.
   - **Queue note.** A `proposed-followups` queue payload carries titles, dispositions, and board positions but no counts and no per-item outcome, so nothing in it can satisfy `located`. It is in scope only as a pointer to where the consuming session's ruling record should be; the record itself is what the verdict rests on.

**What the verdicts mean.** **Located** and **out of domain** are clean. **Could-not-verify** and **not-reconcilable** are about the reader's inputs and the filing's shape, not about the ruling. Only **unsupported** is a defect signal — the trace is missing where the stamp claims one — and even then it is a signal, not proof of misconduct.

> **Filings that predate this contract.** Ruling records were first owed on 2026-08-05. A ruling-asserting filing created before this contract landed, **and carrying an anchor**, will read "unsupported", because no record was owed when it was filed — 29 such filings existed at the time of writing, out of 34 ruling-asserting filings total. Read "before" as *before this contract landed*, not as a midnight boundary: four of the 29 (#1004, #1009, #1011, #1012) were themselves created on 2026-08-05, ahead of the merge, and are covered. The other five (#858, #862, #864, #865, #992) carry no anchor and read *not-reconcilable* instead, per step 4; do not report those as "unsupported" either. That verdict is correct and must not be suppressed (#1011 is the exhibit the contract was written around, and a procedure under which it reconciles would be broken), but for a pre-contract filing "unsupported" carries no accusation: it distinguishes nothing. The signal is only actionable for filings created after the effective date.

**The trust bound, stated exactly.** Every artifact in this system is agent-written, and the honest claim is narrower than it is tempting to write: **a located record evidences that a conforming ruling record was written at or before filing time — not that the ruling ceremony ran, and not who ruled.** Nothing artifact-side can distinguish a presented batch from a session that assembled the batch, wrote the record, and filed, all in the same breath: every property step 6 checks is satisfiable that way, and "written at decision time" leaves no artifact. So the detected class is a session that omits **the record write** — the honest-omission case #1011 exemplifies — not one that omits the presentation. This contract delivers **detection** of a missing record, not prevention of a bypass, and no wording here should suggest otherwise.

> **And the detected class is narrower still: it is a session that omits the record write *while stamping a ruling-asserting value*.** Domain membership is decided at step 2 by the provenance stamp, and that stamp is self-attested — `-FilingProvenance` is a ValidateSet (defined in `skills/safe-operations/scripts/Add-FollowUpIssue.ps1`, which states this same bound in the comment above the parameter and must be amended together with this passage), so the filer picks its own value and nothing ties any value to what actually happened. A session that omits the record write and stamps `direct-request` is therefore not caught by a weaker verdict; it is **out of domain**, and the procedure stops before looking. Note what that means for #1011, the exhibit this contract was written around: the same session, changing one enum value, reads clean. So `direct-request` carries the identical structure #1012 was filed to close — a self-attested claim about a maintainer action that leaves no artifact — one value to the side of the mechanism that now checks it. This is a **known, unclosed** boundary, not a solved one; it is stated here so no reader mistakes an empty domain for a checked corpus. Live as of 2026-08-09: of 52 provenance-stamped filings, 15 are out of domain and 31 read *unsupported*. Two dates matter here. Through 2026-08-08 the procedure had **never returned `located` for any filing, ever** — every ruling-asserting filing predated this contract, and the sole ruling record in existence was an all-drop batch no filing could match, so step 6's match path had never once executed. It executed for the first time on 2026-08-09 and returned **`located`** (#1030, against ruling record `followup-cf84c15934336579` on PR #1027). Treat that as the mechanism's first end-to-end proof, not as a clean bill of health: the same run returned *unsupported* for two `gate-approved` filings created that day, which is this signal's first live, actionable firing and is a prompt to go look, never a finding of misconduct.

**Durable `followup-` entries.** Drops and modifies persist as `followup-`-prefixed entries in the phase-matching engagement-record comment, using `Get-FollowupRecordKey` to derive the entry's key and `Merge-FollowupRecords` to union each fresh write with every prior `followup-` entry already on record. This cumulative re-emission, plus its unbroken-chain guard (a fresh marker that would otherwise drop a previously-recorded key triggers a loud warning instead of a silent drop), is what keeps an old drop or modify decision from being shadowed by a later ruling's write.

**Counts line.** Each ruling's gate decision emits a `proposed: N, approved: K, modified: M, dropped: D` counts line, carried as the ruling record's `gate_ruling_counts` field in the same engagement-record comment as the per-item decisions. These counts are a snapshot of the batch outcome captured at decision time, not a value re-derived from durable entries afterward — because approved items have no worklist entry of their own (see "Record-before-file ordering" above), a post-hoc derivation would undercount approvals. The counts line alone does not satisfy the ruling record: reconciliation matches a *title* against the record's per-item lines, and a bare count matches nothing.

**Headless queue fallback.** When no interactive surface is available at all, the run posts exactly one `proposed-followups-{PR|ISSUE}` marker comment — built and written with `New-ProposedFollowupsComment` / `Write-ProposedFollowupsComment`, which itself reuses `find-or-upsert-comment.ps1` rather than opening a new `gh` call path — and files nothing. The comment's marker-head state advances through the authoritative values `'proposed'`, `'claimed'`, and `'consumed'` (see `Set-ProposedFollowupsCommentState` in `.github/scripts/lib/followup-gate-core.ps1`). A later gate-capable session claim-stamps and then consumes that comment before presenting its contents as a batch; when a consumed queue proposal is filed, the filing call uses `Add-FollowUpIssue -OriginatingPr {N} -FilingProvenance 'queue-consumed'` (the anchor requirement applies here too), distinguishing it from a same-session interactive approval (which uses `gate-approved`). A proposal that targets a different repository than the one the run is on — for example, an upstream-gotcha finding meant for a template repo — still queues on the *current* repo's tracking artifact; its payload simply carries an explicit `target_repo` field so the eventual consumer knows where to file it.

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

## Section 3: git, `gh`, worktree and repo-script traps

[`references/git-and-gh-traps.md`](references/git-and-gh-traps.md) collects the traps in the tools this repository uses to inspect state and to write to GitHub. Like the PowerShell traps, they produce a confident, wrong answer rather than an error: a green check table for a commit you have moved past, a "pre-existing failure" verdict structurally unable to detect the defect it was asked about, a successful `PATCH` that destroys content nobody notices is gone.

Read it before reporting CI state, before claiming a failure is pre-existing, before writing to a GitHub comment body, and before trusting a cleanup detector's silence. The write-path entries are directly in this skill's scope: a `PATCH` from a local file clobbers server-side appends, `-f body=@-` can post the literal string `@-`, and `--edit-last` targets the last comment posted rather than the one intended.

## Gotchas

| Trigger                                 | Gotcha                                                             | Fix                                                                                                   |
| --------------------------------------- | ------------------------------------------------------------------ | ----------------------------------------------------------------------------------------------------- |
| Editing workspace files from PowerShell | Silent encoding or line-ending corruption slips into tracked files | Use the designated file tools for content changes and keep terminal writes for move/delete cases only |
| Writing a GitHub body from a file       | `-f` is `--raw-field` and never expands `@`, so `-f body=@-` posts the literal `@-`; a local-file `PATCH` destroys server-side appends | Use `--field`/`-F`, feeding the file via a Bash stdin redirect (`--field body=@- < file`) or `-F body=@file` from any shell; re-read the live body before patching, and verify the result rather than the exit code |
