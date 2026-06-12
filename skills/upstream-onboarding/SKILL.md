---
name: upstream-onboarding
description: "Shared opening-phase protocol for upstream agents (Experience-Owner, Solution-Designer, Issue-Planner) and Code-Conductor when invoked on an existing GitHub issue. Renders a scaled context brief and runs a standards check on inherited work at each phase boundary. Use when a user-invocable agent receives a request referencing an existing GitHub issue and must load solution-authoring and upstream-onboarding at the opening phase. DO NOT USE FOR: subagent dispatches (which already operate within an assessed session context); post-merge review (use post-pr-review); research or non-tree subagents."
---

<!-- markdownlint-disable-file MD041 MD003 -->

# Upstream Onboarding

Shared opening-phase protocol for the three upstream agents in the Agent Orchestra pipeline (Experience-Owner, Solution-Designer, Issue-Planner) and Code-Conductor when invoked on an existing GitHub issue. Two responsibilities: render a scaled context brief so the agent and developer share a common starting point, and run a standards check on any work inherited from the prior phase so concerns are surfaced and resolved before execution continues.

## When to Use

<!-- d-load-order-resolution-anchor -->
Load this skill as an opening-phase action when a user-invocable upstream agent (Experience-Owner, Solution-Designer, Issue-Planner) or Code-Conductor receives a request referencing an existing GitHub issue, or when the developer is describing a brand-new idea (Greenfield Mode below). Structured-question contracts are platform-mode-independent — see your platform guide for any auto-mode boundary.

## When to Skip

- **Same-agent resume**: the most recent upstream completion marker on the issue belongs to the active agent's own role (e.g., Solution-Designer re-entering when `<!-- design-phase-complete-{ID} -->` is the latest marker). In this case the brief and standards check are skipped (the agent proceeds directly to its next phase action), but the **resume-variant orientation snapshot** now renders. Distinguish: the brief and the non-overridable standards check still skip on same-agent resume, but the resume-variant orientation snapshot now renders.
- **No issue ID and not a Greenfield start**: if no issue ID can be determined and the developer is not describing a brand-new idea (i.e., the request is unrelated to issue work), skip silently.
- **Greenfield Mode is the exception**: when the developer is describing a brand-new idea in plain language with no issue yet, the brief and issue-creation prompt **do** run — see Greenfield Mode below. Greenfield Mode takes precedence over the "No issue ID" skip rule above.

When an issue ID is present but no upstream completion markers exist yet (a fresh, unframed issue), still render the brief — synthesized from the issue body — and skip the standards check (nothing to inherit). Surface any blocking questions before the agent begins phase-specific work.

## Trigger Rules

### Marker-Boundary Trigger

The standards check fires only when the active agent is picking up work completed by a **different** agent. Detection rule:

1. Read the GitHub issue comments for upstream completion markers: `<!-- experience-owner-complete-{ID} -->`, `<!-- design-phase-complete-{ID} -->`.
2. Identify the most recent marker.
3. If the most recent marker belongs to the **current agent's own role**, skip the brief and standards check (same-agent resume), but render the **resume-variant orientation snapshot**.
4. If the most recent marker belongs to a **different upstream role**, proceed to the standard brief and standards check.

| Most recent marker | Agent now active | Result |
| --- | --- | --- |
| `experience-owner-complete` | Solution-Designer | ✅ Fire brief & standards check |
| `experience-owner-complete` | Issue-Planner | ✅ Fire brief & standards check |
| `design-phase-complete` | Issue-Planner | ✅ Fire brief & standards check |
| `design-phase-complete` | Solution-Designer | ⏭️ Skip brief & standards check; render resume snapshot (same-agent resume) |
| `experience-owner-complete` | Experience-Owner | ⏭️ Skip brief & standards check; render resume snapshot (same-agent resume) |

### Sequencing

- Runs at the opening phase when a user-invocable agent picks up an issue-referencing request (after the session-startup hook + drift check, which are platform-level concerns).
- Runs **before** the agent loads its role-specific skills (design-exploration, plan-authoring, etc.) or takes any phase action.
- During this opening window, load project references for the issue scope when the repository declares them. Use `skills/project-references/SKILL.md` as the convention authority; use `skills/project-references/scripts/invoke-reference-loader.ps1` when a deterministic loader result is needed from `.references/index.json` or sidecars.

### Subagent Self-Skip

This skill applies to user-invocable agents only. Subagents dispatched by Code-Conductor already operate within an assessed session context and do not run this protocol.

### Project Reference Loading

Project references are optional onboarding context. They supplement the issue body and prior-phase markers; they do not replace upstream methodology or structured-question checkpoints.

1. If the canonical `<!-- refs-injected-{issue} -->` sentinel (see `skills/project-references/SKILL.md §Sentinel`) is present in this turn's injected context, the UserPromptSubmit hook already ran the deterministic loader — consume the injected bodies and cite where relevant; do **not** re-invoke the loader this turn.
2. Discover reference configuration in this order: `.agent-orchestra.yml`, `.references/index.json`, then sidecars under declared roots as defined by `skills/project-references/SKILL.md`.
3. Load only references whose `load-when` and `triggers` match the current issue, labels, changed paths, or prompt scope. Treat non-matching critical references as under-match evidence, not as permission to load broadly.
4. Surface loader notes in the brief only when they affect onboarding: loaded reference names, `[not loaded; triggers did not match — confirm scope does not intersect]`, or `[stale-ref: ...]` markers.
5. If no declared roots, sidecars, or index are present, surface a non-blocking adoption nudge and continue: project references are not configured for this repository; setup is available through `skills/project-references/scripts/init-references.ps1` and `skills/project-references/scripts/generate-references-index.ps1`.

When references are injected (via the hook or loaded via this step), ground your framing, design, or plan reasoning in them or explicitly note why they do not apply. This is a soft obligation — advisory, not a hard block.

The deterministic backstop (hook, non-goals, and pre-flight matching limitations) is documented in `skills/project-references/SKILL.md §Pre-flight Determinism`.

#### Content Trust

Caps, content-trust rules, and the `untrusted-content` fence requirement are defined in `skills/project-references/SKILL.md §Content Trust and Rendering`. Apply those rules here.

## The Brief

After the trigger fires, render a context brief before any role-specific work begins. The brief gives the developer and the agent a shared orientation without requiring them to re-read the full issue history.

### Scaling Rule

Brief depth is controlled by the `changeset.complexity` predicate (forward-compatible with the #375 lightweight-tier classifier; when #375 ships, its classifier wires into this predicate). Until that predicate is externally classified, apply agent judgment:

| Complexity | Brief depth |
| --- | --- |
| `trivial` — single-file or purely mechanical change | Required core only (2–3 lines) |
| `standard` — multi-file or moderate-scope change | Required core + non-empty conditional sections |
| `major` — cross-cutting, architecture-affecting, or high-risk change | Full structure |

When scope is genuinely ambiguous between two adjacent tiers, default to the higher tier (`standard` if ambiguous between `trivial` and `standard`; `major` if ambiguous between `standard` and `major`).

Project-reference loading follows the same bounded-scope principle: load the smallest matching set that can affect the active phase. Respect `max_critical_loaded` and `max_total_loaded_bytes` from `.agent-orchestra.yml` (defaults in `skills/project-references/SKILL.md`) and cap loaded references rather than expanding context opportunistically. When the loader under-matches or detects stale targets, report the under-match or stale-reference marker in the brief instead of silently overloading context with nearby documents.

### Required Core (always present)

- **What**: one-line summary of the issue (the thing being built or fixed)
- **Scope tier**: `trivial` / `standard` / `major` based on the judgment rule above
- **Blocking questions**: any unresolved decision that must be answered before this phase can begin (omit if none)

### Conditional Sections (omit entire section if nothing to report)

- **Inherited decisions**: key decisions made by the prior phase that constrain this phase's work. Omit if none.
- **Standards concerns**: findings from the standards check (see below). Omit if check raises no concerns.
- **Constraints**: known technical constraints, architecture rules, or non-goals relevant to this phase. Omit if none.
- **Project references**: If the `<!-- refs-injected-{issue} -->` sentinel is present, the hook loaded refs deterministically — surface their names. Otherwise, report loaded reference names, under-match notes, stale-reference markers, or the non-blocking adoption nudge. Omit if references are configured and no project-reference note affects onboarding.
- **Changed since this issue was filed**: age-gated diff scan — see `### Changed since this issue was filed` below. Omit if the issue is below the age threshold (Empty-Section Omission Rule applies).

### Empty-Section Omission Rule

Do not render empty section headers or `(none)` placeholders. If a conditional section has nothing to report, omit the heading entirely. A trivial change may produce a brief of two lines (What + Scope tier) with no conditional sections at all.

### Changed since this issue was filed

When the issue is **strictly older than 7 days** (configurable via `-ThresholdDays N`), run the drift scan and render this section in the brief. The scan detects which merged PRs have touched paths that appear as backtick-quoted tokens in the issue body, giving the pickup agent a fresh picture of what the codebase looks like compared to when the issue was filed.

**Script invocation**:

```powershell
# Repo clone (contributor — relative path from repo root):
pwsh -NoProfile -NonInteractive -File "skills/upstream-onboarding/scripts/get-issue-drift.ps1" -IssueNumber {ID}

# Plugin-cache install (consumer — resolve from installed plugin path):
pwsh -NoProfile -NonInteractive -File "<plugin-root>/skills/upstream-onboarding/scripts/get-issue-drift.ps1" -IssueNumber {ID}
```

Resolve `<plugin-root>` using the same D1 plugin-cache-priority lookup described in `skills/session-startup/SKILL.md` Step 3.

**Entry format**: `#N — title (touches: path1, path2, ...)`. Entries are ranked by overlap count descending, then by merge date descending. Cap at 10 entries by default.

**Example rendering**:

```text
**Changed since this issue was filed** (3 PRs touched tracked paths)
- #686 — feat: add drift scan (touches: skills/upstream-onboarding/SKILL.md)
- #685 — feat: persist-changes skill (touches: skills/persist-changes/SKILL.md)
+1 more PR touched tracked paths.
```

**When nothing matches** (scan ran but no PRs path-matched the issue body's tokens): render a single count-only line — `N PRs merged since filing — type "what changed" to review.` Never dump an unmatched PR list.

**Truncation note**: when the script result carries `truncated: true` OR any rendered candidate carries `files_truncated: true`, append: `results may be incomplete — type "what changed" for a full scan.`

**Age-threshold omission**: when the issue is below the 7-day threshold, omit this section entirely including the heading (Empty-Section Omission Rule applies).

**Scaling Rule clarification**: this section is a conditional section. Trivial-tier briefs stay required-core-only and omit it even when the age threshold is met.

**Ephemerality**: the drift output is rendered ephemerally — never written to any durable marker, engagement record, or issue/PR comment.

### Resume Variant

When performing a **same-agent resume** (re-entering paused work on an issue the active agent already owns), a terse ~4-6 line inline orientation snapshot surfaces **instead of** the standards check. On cross-role issue pickup (e.g., Issue-Planner picking up a Solution-Designer's work), the full scaled brief and standards check fire (rule 4 in the Marker-Boundary Trigger table) — the brief already surfaces What / Scope tier / inherited decisions / next phase, satisfying the AC1 pickup-orientation goal. The resume snapshot is the **additive same-agent-resume case**.

This snapshot is assembled ONLY from already-loaded context to avoid extra reads or expensive model summarization passes.

**Drift exception (narrow, additive)**: The age-gated deterministic drift call (`get-issue-drift.ps1`) may append a "Changed since this issue was filed" section to the resume snapshot when the issue exceeds the age threshold. This is the only narrow exception to the assembled-from-already-loaded-context constraint above — the call is a cheap, stateless, age-gated script that does not load or summarize prior analysis context. Render it under the same `### Changed since this issue was filed` rules. All other snapshot fields remain assembled from already-loaded context only.

The snapshot fields map directly to durable artifacts (D3):

- **current phase**: derived from the latest phase marker (e.g., `<!-- experience-owner-complete-{ID} -->` → Experience phase; `<!-- design-phase-complete-{ID} -->` → Design phase; `<!-- plan-issue-{ID} -->` → Plan / Implementation phase).
- **last decision**: derived from the most recent `engagement-record-{phase}-{ID}` comment's `load_bearing_decisions[]` or the YAML audit payload.
- **next step**: derived from the next incomplete step in the active pipeline position.

Surfacing this snapshot orients the developer and active agent immediately without re-firing the Standards Check Protocol. This snapshot fires at user-invocable resume entries only, and is skipped for subagent dispatches.

#### Missing-Record Fallback

When a real issue does not yet carry any durable `engagement-record` markers (e.g., due to pre-#576 historical issues or a failed/halted emission), the **last decision** field gracefully degrades to reflect the latest completion marker or phase state, rendering exactly: `last decision: not recorded`. It must never be left blank or fabricated.

#### On-Demand Expand (D4)

If a richer context or the full issue details are needed, an on-demand summary is available via natural language (e.g., typing "expand" or "full picture"). This is handled in-turn as a context-local follow-up, is NOT registered in `nl_intent_routing`, and is never suppressed by `/raw`.

**Drift follow-up phrases**: the phrases "what changed", "what's changed", and "what happened since" (and close variants) trigger the drift follow-up — run `get-issue-drift.ps1 -IssueNumber {ID} -Force` and narrate the results using the same entry-format and rendering rules as the "Changed since this issue was filed" section. If the script returns `{error: "..."}`, surface the error as: `couldn't check: {error}`. Never silence errors.

#### Affordance-Hint Predicate (D5)

A single-line affordance hint (e.g. "Type 'expand' for richer details") appears below the snapshot only when a cheap check resolves to true:

1. At least one prior `engagement-record` decision exists on the issue, OR
2. The issue body's rendered length exceeds the snapshot's rendered length by more than 1 000 characters.
3. The issue age exceeds the drift threshold (i.e., the drift scan ran or would run) — show the hint: `Type "what changed" to see what's been merged since this issue was filed.` This predicate fires independently of the D5 hint above; both may appear on the same snapshot.

#### Example snapshot (same-agent resume)

```text
**Resume snapshot — Issue #633**
Current phase: Plan / Implementation
Last decision: summary-strategy — bounded reuse-only default + on-demand expand
Next step: Step 2 — Code-Conductor smart-resume render (s2, in progress)

Type "expand" for full issue context.
```

*(Fields are derived from already-loaded markers and engagement-records. The affordance hint appears when the predicate fires. Greenfield resumes render `(proposed)`-suffixed fields via the Greenfield Mode brief — see Greenfield Mode below.)*

### Greenfield Mode

When no issue exists yet (the developer is describing a new idea in plain language):

- Synthesize the brief from the user's prompt words.
- Mark **every field** (required core and conditional alike) with a `(proposed)` suffix to signal that the content is not yet anchored to a real issue. The whole brief is unanchored when no issue exists, so the suffix applies uniformly to `What`, `Scope tier`, and any conditional content.
- Include a prompt for issue creation: use the platform's structured-question tool to ask 'No issue exists yet — create a GitHub issue for this work?' with 'Create issue now (Recommended)' and 'Continue without issue (exploratory session)' as options. The active agent's GitHub Setup step then handles the actual creation.
- Omit the standards check — there is no inherited work to check against.

Example greenfield brief:

```text
**What**: Add dark-mode support to the settings panel (proposed)
**Scope tier**: standard (proposed)
**Issue creation**: no issue exists yet — this agent will create one per its GitHub Setup step.
```

## Standards Check Protocol

After rendering the brief (and only when the marker-boundary trigger fired), run a standards check on the inherited work: read the prior agent's output in the issue body and evaluate it against the active agent's anchor standards (see Per-Agent Lenses below).

### cite-anchor-and-quote Authority

When a concern is found, the agent **must**:

1. **Cite the anchor** — name the skill or file path that establishes the standard being violated (e.g., "`skills/customer-experience/SKILL.md` — Customer Language rule").
2. **Quote the offending text** — reproduce the exact passage from the inherited content that violates the standard. For tabular or structured content (table rows, YAML blocks, list items), copy the cell or block content verbatim; omit surrounding pipe delimiters or indentation markers.

   When the required section is entirely absent from the inherited content (not present at all), treat the absence itself as the concern: cite the anchor, note that the required section is missing, and describe what it should contain — omitting the quote step since there is no offending text to quote.

3. **Present the better approach** — describe what the corrected version should look like.
4. **Ask via structured question** — present the concern and the better approach as a structured-question call (see `platforms/claude.md` and `platforms/copilot.md` for tool invocation). Mark the corrective approach as recommended.

The user decides. A well-written but standards-violating prior phase does not proceed unchallenged.

<!-- upstream-onboarding-non-overridability:begin -->

### Rule: Non-overridability

Standards-check structured questions are unconditional with respect to user pacing or auto-mode directives. Pacing directives apply to preference-clarifying pauses, not to methodology checkpoints. The user's lever to override a concern is to select an alternative option in the structured question, not to issue a pacing directive that suppresses it.

Note: upstream-onboarding does NOT introduce a labeled `Decline engagement` option (unlike `solution-authoring/SKILL.md`); the asymmetry is intentional — the user's lever for standards checks is selecting from the structured-question options surfaced by the cite-anchor-and-quote Authority procedure.

<!-- upstream-onboarding-non-overridability:end -->

### When No Concern Fires

Emit: `Standards check: none flagged` (or equivalent concise phrasing). Do not omit this signal — its absence would be ambiguous.

### Judgment Principle — Certainty × Risk

Raise a concern when the product of certainty (how confident the agent is that a violation exists) and risk (how much the violation could harm the outcome if uncorrected) is high enough to warrant interruption. There is **no numeric cap** on concerns per activation. An activation with three genuine high-certainty, high-risk concerns must raise all three. An activation with no concerns above the threshold raises none.

Corollary: a persuasively written prior phase does not lower the bar. Clean prose can still hide a symptom-only diagnosis, a single-option prescription, or a missing AC slice.

## Per-Agent Lenses

Each agent applies the standards check through its own lens, using the anchors below.

### Experience-Owner Lens

**Anchors**:

- `skills/customer-experience/SKILL.md` — Customer Language rule, Intent Scenario requirement
- `skills/bdd-scenarios/SKILL.md` — scenario classification and ID traceability (when BDD is enabled)

**Concern triggers** (raise a structured question when observed):

| Observation | Standard violated | Anchor |
| --- | --- | --- |
| Scenario describes a system behavior without a customer who has a goal | Customer Language rule | `skills/customer-experience/SKILL.md` |
| Issue body describes a desired solution rather than a customer need | Solution-shaped problem statement | `skills/customer-experience/SKILL.md` |
| No scenario maps to the stated design intent (the "so that" goal) | Missing intent scenario | `skills/customer-experience/SKILL.md` |
| Surface or CE Gate readiness is absent or unlabeled | Unclassified surface | `skills/customer-experience/SKILL.md` |

**Customer-language requirement**: all scenarios authored or reviewed by Experience-Owner must use language a customer would understand. Technical jargon and implementation details are not permitted in scenario clauses.

### Solution-Designer Lens

**Anchors**:

- `skills/design-exploration/SKILL.md` — Options-with-trade-offs rule, Rejected Alternatives requirement
- `skills/software-architecture/SKILL.md` — Layer boundary and dependency-direction rules
- Consumer `architecture-rules.md` (if present) — project-specific architectural constraints

**Concern triggers**:

| Observation | Standard violated | Anchor |
| --- | --- | --- |
| Issue body documents a single approach without alternatives | Single prescription | `skills/design-exploration/SKILL.md` |
| Proposed mechanism crosses layer boundaries or inverts dependency direction | Layer violation | `skills/software-architecture/SKILL.md` |
| No rejected alternatives section, or alternatives present but lack rationale | Missing rejected alternatives | `skills/design-exploration/SKILL.md` |
| Acceptance criteria cannot be traced to a concrete design decision | Untraceable AC | `skills/design-exploration/SKILL.md` |

### Issue-Planner Lens

**Anchors**:

- `skills/plan-authoring/SKILL.md` — Requirement Contract, AC-slice requirement, CE Gate coverage, Alignment Workflow (`## Alignment Workflow` heading)
- `skills/tracking-format/SKILL.md` — tracking-file frontmatter format

**Concern triggers**:

| Observation | Standard violated | Anchor |
| --- | --- | --- |
| A plan step cannot be traced to an acceptance-criteria slice | Step without AC slice | `skills/plan-authoring/SKILL.md` |
| CE Gate is listed as false but the change has a customer-facing surface | CE Gate gap | `skills/plan-authoring/SKILL.md` |
| Requirement Contract is missing from one or more implementation steps | Missing Requirement Contract | `skills/plan-authoring/SKILL.md` |
| Plan scope covers files or systems not mentioned in the AC | Scope mismatch | `skills/plan-authoring/SKILL.md` |

## Platform-specific invocation

This skill's methodology is tool-agnostic. Platform-specific routing for structured questions lives alongside:

- Claude Code: [platforms/claude.md](platforms/claude.md)
- Copilot: [platforms/copilot.md](platforms/copilot.md)

---

## Frame Ports Filled By This Skill

This skill is **supporting methodology** — it does not fill a frame port and declares no `provides:` field. Classification per `Documents/Design/frame-architecture.md` Adapter Model: the credit-author test confirms this skill adds no frame credit row because it provides no customer-experience, design, or plan output.

## Gotchas

| Trigger | Gotcha | Fix |
| --- | --- | --- |
| Re-entering the same upstream phase | Running the brief and standards check again can make a same-agent resume look like inherited work | Check the latest upstream completion marker first; skip the standard brief & standards check when it belongs to the active role, but render the **resume-variant orientation snapshot** |
| Starting from a brand-new idea with no issue ID | Treating the missing issue as a silent skip loses the greenfield brief and issue-creation prompt | Apply Greenfield Mode when the developer is describing new issue work |
| Project-reference sidecars or indexes are absent | Treating optional reference metadata as required setup blocks the upstream pipeline | Surface the adoption nudge once, point to `skills/project-references/scripts/init-references.ps1`, and continue onboarding |

## Related

- `skills/customer-experience/SKILL.md` — Experience-Owner lens anchor.
- `skills/design-exploration/SKILL.md` — Solution-Designer lens anchor.
- `skills/plan-authoring/SKILL.md` — Issue-Planner lens anchor.
- `skills/project-references/SKILL.md` — reference sidecar schema, content-trust rules, citation format, and hard caps.
- `skills/project-references/scripts/invoke-reference-loader.ps1` — deterministic loader for matching references, under-match notes, stale-reference markers, and `untrusted-content` rendering.
- `skills/project-references/scripts/validate-references-index.ps1` — validation surface for stale index entries and citation checks.
- Issue #375 — lightweight scope tier; `changeset.complexity` predicate is a forward-compatible hook for that classifier.
