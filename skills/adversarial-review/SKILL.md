---
name: adversarial-review
description: Reusable adversarial review methodology for prosecution, defense, design challenge, product-alignment, and proxy review passes. Use when reviewing code, plans, designs, or external review ledgers with evidence-first rigor. DO NOT USE FOR: final judgment ownership, GitHub intake routing, or fix execution decisions (use review-judgment or code-review-intake).
---

<!-- platform-assumptions: markdown skill guidance for VS Code custom agents in Copilot Orchestra; assumes the calling agent retains read-only boundaries, mode routing, and finding-schema ownership. -->
<!-- markdownlint-disable-file MD041 MD003 -->

# Adversarial Review

Reusable review methodology for prosecution and defense passes.

## When to Use

- When reviewing implementation changes with an adversarial, evidence-first stance
- When stress-testing a design or implementation plan before committing to it
- When validating and scoring externally supplied findings without widening review scope
- When preparing a defense pass that tries to disprove a prosecution ledger

## Purpose

Hunt for real defects without inventing them. The goal is to apply a repeatable adversarial method, gather concrete evidence, and emit findings or disproofs that another agent can judge.

## Core Method

### 1. Establish Review Scope

Determine which artifact is under review:

- Code or docs diff
- Design or implementation plan
- Customer-experience evidence
- External review ledger

Read the relevant plan, design cache, architecture rules, and nearby implementation evidence before forming findings.

### 2. Apply Evidence Standards

Every review item must include:

- A specific citation or referenced artifact
- A concrete failure mode or explicit uncertainty
- A severity and confidence level that match the evidence quality
- Enough context that a judge can independently verify the claim

If the failure mode cannot be stated clearly, downgrade the item or omit it.

### 3. Prefer Targeted Verification Over Broad Scanning

Use the smallest checks that can disconfirm or support a suspected defect:

- Read the owning implementation or design section
- Trace wiring for new data, components, or integrations
- Inspect browser state only when the change touches UI behavior
- Compare documented expectations against what the repo currently does

### 4. Emit a Usable Ledger

Write findings so a defense or judge pass can act on them without reconstructing your reasoning from scratch. Avoid vague summaries such as "looks risky" or "might break stuff."

## Code Prosecution Workflow

For standard code review, work through all six perspectives in sequence. For perspectives whose gate is not triggered, use the compact N/A pattern instead of expanding checklist items.

### 1. Architecture

Apply when runtime code, scripts, or runtime configuration changed.

Check:

- Architecture-rule compliance and layer direction
- Integration wiring for new components
- Data integration for newly introduced fields, constants, and maps
- Domain-alignment mismatches across validators, parsers, and converters — identify peers via field-name grep, plan consultation for aliases, and call-chain tracing

### 2. Security

Apply when the change touches source code, scripts, auth, or data handling.

Check:

- Secrets, credentials, and logging of sensitive data
- Input validation and authorization boundaries
- Full-record overwrite risks that can drop security-sensitive fields

### 3. Performance

Apply when runtime execution paths changed.

Check:

- Algorithmic complexity
- Re-render or repeated-computation costs
- Memory or bottleneck risks

### 4. Pattern

Apply when source files changed. For docs-only changes, keep the documentation pattern concerns only.

Check:

- Appropriate pattern use and anti-pattern avoidance
- DRY violations and contradictory guidance
- SOLID pressure points
- UI test querying patterns when test code is in scope

### 5. Implementation Clarity

Apply to all change types.

Check:

- Over-engineering
- Readability and self-documenting structure
- Unnecessary complexity
- Comments that explain why rather than what

### 6. Script And Automation

Apply when script files changed or markdown includes runnable shell guidance.

For script files, verify:

- Native command exit-code checks at boundaries
- Cross-references to authoritative enumerated values
- PowerShell and pipeline semantics that preserve intended types

For markdown-only command guidance, audit:

- Runnable commands from repo root
- Self-match hazards in grep-based validations
- Correct post-change counts and expectations
- Preference for built-in VS Code tools over terminal-first read-only guidance when an equivalent exists

### Browser-Based Review

When the change touches UI implementation:

- Navigate only the affected routes or adjacent impacted flows
- Capture screenshots to support visual findings
- State route, action, expected behavior, observed behavior, and evidence

### Compact N/A Rule

When a perspective gate is not triggered, replace the full section with:

```markdown
### ⏭️ [Perspective Name]: N/A — [reason]
```

### Standard Code Review Output

```markdown
## Review Findings

### ✅ Architecture: PASS/FAIL

{findings or compact N/A}

### ✅ Security: PASS/FAIL

{findings or compact N/A}

### ✅ Performance: PASS/FAIL

{findings or compact N/A}

### ✅ Patterns: PASS/FAIL

{findings or compact N/A}

### ✅ Implementation Clarity: PASS/FAIL

{findings or compact N/A}

### ✅ Script & Automation: PASS/FAIL

{findings or compact N/A}

## Summary

{overall verdict and key actions}
```

## Design And Plan Prosecution

Use when the caller requests design-review or product-alignment markers.

### Design Review

Review with these perspectives:

- Feasibility and Risk
- Scope and Completeness
- Integration and Impact

Each finding should cite the challenged decision, acceptance criterion, or scope element, and explain what breaks if the concern is real.

Output format:

```markdown
## Design Challenge Report

### §D1 — Feasibility & Risk

{findings or checked-no-issues summary}

### §D2 — Scope & Completeness

{findings or checked-no-issues summary}

### §D3 — Integration & Impact

{findings or checked-no-issues summary}

### Summary

{highest-risk items and overall confidence}
```

### Product-Alignment Review

Use this evidence order:

1. Draft design or plan content passed in the prompt
2. Issue body when present
3. `Documents/Design/` and `Documents/Decisions/`
4. Project guidance files such as `README.md`, `CUSTOMIZATION.md`, and `copilot-instructions.md`
5. Planned-work artifacts when present

Review with these perspectives:

- Product Direction Fit
- Customer Experience Coherence
- Planned-Work Alignment

Output format:

```markdown
## Product-Alignment Challenge Report

### §P1 — Product Direction Fit

{findings or checked-no-issues summary}

### §P2 — Customer Experience Coherence

{findings or checked-no-issues summary}

### §P3 — Planned-Work Alignment

{findings or checked-no-issues summary}

### Summary

{most important alignment risks and confidence}
```

## Defense Workflow

When defending against a prosecution ledger:

1. Read the cited code or evidence independently
2. Try to disprove the stated failure mode
3. Use `disproved`, `conceded`, or `insufficient-to-disprove` per finding
4. Only challenge items you can support with concrete counter-evidence

Defense report format:

```markdown
## Defense Report

### Finding: {id} — {title}

Prosecution: {severity} ({points} pts) — {brief claim}
Defense verdict: `disproved | conceded | insufficient-to-disprove`
Evidence: {what was independently verified}
Argument: {why the prosecution is wrong or why defense concedes}

### Score Summary

Findings reviewed: N
Disproved: X | Conceded: Y | Insufficient: Z
Points claimed: {sum of disproved finding values}
Points at risk: {-2× sum of disproved finding values if rejected}
```

## Proxy Prosecution Workflow

When representing an external review ledger:

- Treat the ingested reviewer comments as the authoritative scope
- Validate each claim rather than generating a fresh review
- Preserve the no-net-new rule unless an unavoidable critical blocker appears
- Attribute findings to the external reviewer rather than the current agent

## Related Guidance

- Load `software-architecture` when a finding depends on layer boundaries or dependency direction
- Load `verification-before-completion` when validating whether the reviewed change is ready to ship
- Load `code-review-intake` when the work begins from GitHub review threads rather than an internal ledger

## Gotchas

| Trigger                         | Gotcha                                                                | Fix                                                              |
| ------------------------------- | --------------------------------------------------------------------- | ---------------------------------------------------------------- |
| Review starts from "looks fine" | The pass turns into a summary instead of an adversarial investigation | Begin from likely failure modes and gather evidence against them |

| Trigger                               | Gotcha                                                       | Fix                                                                 |
| ------------------------------------- | ------------------------------------------------------------ | ------------------------------------------------------------------- |
| A finding has a citation but no break | The judge cannot tell whether it is a defect or a preference | State the concrete failure mode or downgrade the item before output |
