# Safe Operations Design

## Purpose

The `safe-operations` skill (`skills/safe-operations/SKILL.md`) establishes two categories of safety guardrails that apply to all agents in this workflow:

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
- The improvement-first decision rule gives agents a deterministic fork against the structural-criteria gate (canonical taxonomy in `skills/review-judgment/scripts/Test-DeferralCriteria.ps1`): changes that do not match any structural criterion are eligible for inline fix-in-PR (verdict label `✅ ACCEPT (fix inline)`) and may be folded into the current PR; changes that match at least one structural criterion must immediately become tracked follow-up issues (verdict label `📋 DEFERRED-SIGNIFICANT (structural)`), filed via the `Add-FollowUpIssue` helper, rather than being silently deferred or scope-creeping the ongoing PR.
- The default priority for automatically-created follow-up issues is `priority: medium`, preventing agents from defaulting to high-severity labels for speculative improvements.
- Three priority label definitions (`priority: high`, `priority: medium`, `priority: low`) are included with recommended colors and descriptions so any new repository can bootstrap the label set with a single copy-paste block.

### Filing Approval Gate (Section 2e)

Before issue #837, every pipeline surface that decided a finding belonged in a follow-up issue (Section 2a's "follow-up issue creation" fork) filed that issue immediately and autonomously — the maintainer only ever saw the result after the fact. Eight such surfaces existed across the pipeline: Code-Conductor's Auto-Tracking sequence and its pre-edit ownership gate, Process-Review's §4.8 upstream-gotcha and §4.9 calibration paths, review-judgment's Loud Guard, code-review-intake, and defect-response's Track 1 and Track 2. Autonomous filing at that scale meant a maintainer could not review, correct, or veto a proposed issue before it existed on the board — wrong titles, wrong priority, or a proposal the maintainer simply disagreed with all shipped as real GitHub issues rather than as a decision point.

The Filing Approval Gate closes that gap by interposing a single maintainer decision between "this should become a follow-up" and the `gh issue create` call that makes it real. All eight surfaces now route their proposed follow-ups through the gate (`skills/safe-operations/SKILL.md` § 2e) instead of filing directly.

**Mechanism.** The gate batches proposals per review round rather than asking about them one at a time: each candidate is pre-computed (canonical title, deduplication result, board position) before presentation, so the maintainer reviews a ready-to-decide list, not raw findings. For each item the maintainer chooses one of three outcomes — **approve** (file as proposed), **modify** (edit title/scope/severity, then re-run the deduplication check before filing), or **drop** (do not file). Every filed issue is stamped with a `-FilingProvenance` value (`gate-approved`, `gate-modified`, `queue-consumed`, `direct-request`, or `pre-gate-legacy`) recording which path put it on the board, so provenance is auditable after the fact rather than inferred. Only the parent (dispatching) conversation ever presents the gate; subagents return proposed follow-ups as structured output for the parent to batch, since the gate is an interactive checkpoint tied to the structured-question surface.

**Argued cases, not computed fields (#1012).** Pre-computing the candidates made the batch *decidable*, but it also made the presentation a report: title, rationale, disposition, severity, board position, dedup status are all values the assembly step already produced. The two things the maintainer is actually being asked to rule on — should this be filed at all rather than done now, and where does it belong — arrived as labels rather than arguments (a `[Structural] {criterion_id}` title prefix, where `criterion_id` is one of the six structural identifiers such as `S-cross-cutting` that route a change to a follow-up issue instead of an inline fix; and a computed parent-or-standalone placement), so the gate could fire, be answered, and still never have put a case to the maintainer. Section 2e now requires both cases per item and declares a computed-fields-only presentation nonconforming, with a stated conformance test — prose the presenting agent applies, not an automated check — that rejects "arguments" mechanically fillable from already-computed values.

**Reconcilable ruling trace (#1012).** The provenance stamp was self-attested with nothing behind it: the filing helper stamps whatever ValidateSet value the caller passes, and the record-before-file asymmetry made an approve-only ruling traceless *by design* (drops and modifies persist; approvals were implicit). From artifacts alone, a filing stamped `gate-approved` that never reached a maintainer was indistinguishable from a lawful one — the bypass was invisible, not merely possible. Section 2e now requires every ruling, approve-only batches included, to write one durable batch-scoped **ruling record** carrying the batch counts, the presentation surface, the decision timestamp, and each item's as-filed title and outcome.

Against that record it states a reconciliation procedure a reader holding the filed issue can execute. The procedure deliberately has **five** outcomes rather than two, because collapsing them is how a detection mechanism becomes a false-accusation generator: the three ruling-asserting values resolve to *located* or *unsupported*; the two non-asserting values resolve to *out of domain*; a failed read resolves to *could-not-verify*; and a filing carrying no surface anchor to search from resolves to *not-reconcilable*. Only *unsupported* is a defect signal. Ruling-asserting filings therefore owe an anchor (`-OriginatingPr`, or a parent issue that is the presentation surface) — a surface to search, never a pointer at the record itself, which would reconcile vacuously.

The record rides the `followup-`-prefixed entry family because the tooling read path filters to that prefix and drops everything else — not because a record elsewhere would be *destroyed*, which it would not be: the family is `post-new`, so later writes add comments rather than editing earlier ones. The trust bound is stated exactly rather than flatteringly: every artifact here is agent-written, so a located record evidences that **a conforming record was written at or before filing time** — not that the ruling ceremony ran, and not who ruled. Nothing artifact-side separates a presented batch from a session that assembled, recorded, and filed in one breath. The deliverable is **detection of a missing record**, not prevention of a bypass.

**Durable-record substrate.** Drop and modify decisions must survive across review rounds so a dropped proposal is not silently re-asked about later. The gate reuses the existing engagement-record comment as its durable substrate rather than inventing a new marker type: each decision is written as a `followup-`-prefixed entry, keyed by a collision-safe hash (`Get-FollowupRecordKey`) derived from the finding's stable identity or the proposal's canonical title. Because engagement-record writes are re-emitted per ruling round, a later round's write could otherwise shadow an earlier round's recorded decision for latest-wins readers — it does not destroy it, since the family is `post-new` and later writes add comments rather than editing earlier ones — the merge step (`Merge-FollowupRecords`) unions the current batch with every prior `followup-` entry and enforces a chain guard that raises a loud warning rather than silently losing a previously-recorded drop or modify.

**Headless fallback.** When no interactive parent conversation exists to present the gate (a fully headless run), proposals are not silently filed and not silently discarded — they are queued. Exactly one `<!-- proposed-followups-{PR|ISSUE} -->` comment is written per PR or issue, carrying the batch as a fenced payload and advancing through the states `proposed` → `claimed` → `consumed` as a later, gate-capable session picks it up and adjudicates it. That payload carries only computed fields, so a consuming session must reconstruct both argued cases before it can present a conforming batch — a gap §2e now names explicitly. Extending the payload schema is deferred rather than overlooked: the queue writers have no live call site and no PR or issue carries a queue comment, so the path has never fired and a schema change would build for an unexercised population.

The full operational mechanics — proposal assembly, per-item outcome handling, the argued-case conformance test, ruling-record shape and its failed-write branch, record-before-file ordering and crash semantics, the reconciliation procedure, and the headless queue's state machine — live in `skills/safe-operations/SKILL.md` § 2e, the source of truth for this feature. The per-value provenance semantics are documented at the enum's own defining surface, the `-FilingProvenance` ValidateSet in `skills/safe-operations/scripts/Add-FollowUpIssue.ps1`. This section documents why the gate exists and what it durably records, not how each step executes.

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

- Issue #67: [feat: add read-only tool preference guardrail](https://github.com/Grimblaz/agent-orchestra/issues/67)
- Issue #127: [feat: add deduplication guard to issue creation protocol](https://github.com/Grimblaz/agent-orchestra/issues/127)
- Issue #132: [feat: built-in-tool-first enforcement](https://github.com/Grimblaz/agent-orchestra/issues/132)
- Issue #837: [Add a maintainer-approval gate before follow-up issues are auto-filed](https://github.com/Grimblaz/agent-orchestra/issues/837)
