---
name: adversarial-review
description: "Reusable adversarial review methodology for prosecution, defense, design challenge, and proxy review passes. Use when reviewing code, plans, designs, or external review ledgers with evidence-first rigor; also when prosecuting a remedy for the defect class it closes, when a change demotes or removes a signal, and when judging whether a proposed guard or a substring pin actually holds. DO NOT USE FOR: final judgment ownership, GitHub intake routing, or fix execution decisions (use review-judgment or code-review-intake)."
---

<!-- platform-assumptions: markdown skill guidance for VS Code custom agents in Agent Orchestra; assumes the calling agent retains read-only boundaries, mode routing, and finding-schema ownership. -->
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

## Mode-Scoped Loading

This file is the shared core: evidence standards, pipeline shapes, atomic discipline, and ledger output discipline. The per-mode workflow checklists live in mode files under [modes/](modes/), loaded selector-conditionally so a dispatch boots only the methodology its selector names (#975). Load this core plus exactly the one mode file for the active review mode selector, and no other mode file:

| Review mode selector | Mode file |
| --- | --- |
| `Use code review perspectives`, `Use lite code review perspectives`, `Use post-fix code review perspectives`, or no selector line (default) | [modes/code-prosecution.md](modes/code-prosecution.md) |
| `Use design review perspectives` | [modes/design-review.md](modes/design-review.md) |
| `Use defense review perspectives` | [modes/defense.md](modes/defense.md) |
| `Score and represent GitHub review` | [modes/proxy-prosecution.md](modes/proxy-prosecution.md) |
| `Use CE review perspectives` | No mode file — the CE contract is inline in `agents/Code-Critic.agent.md`; this core still applies |

## Pipeline Flow

Adversarial review adapters run one of these stage shapes:

- `prosecution` - Code-Critic gathers evidence and emits a prosecution ledger.
- `prosecution -> defense` - Code-Critic prosecutes, then Code-Critic defense attempts to disprove the ledger.
- `prosecution -> defense -> judge` - Code-Critic prosecutes, Code-Critic defense attempts to disprove the ledger, and Code-Review-Response issues the terminal ruling.
- `proxy-prosecution` - external review findings are represented as the prosecution input for GitHub review intake.
- `judge` - Code-Review-Response rules on already-collected prosecution and defense evidence.

The named adversarial review adapters are:

| Adapter            | Adapter class                    | Port-filling           | Pipeline stages                   | Prosecution passes | Exempt | Notes                                                               |
| ------------------ | -------------------------------- | ---------------------- | --------------------------------- | ------------------ | ------ | ------------------------------------------------------------------- |
| `standard`         | multi-variant work adapter       | Yes, `review`          | `prosecution`, `defense`, `judge` | `1`, `2`, `3`, `4`, `5` | No | Full local adversarial review (five-pass two-layer panel)           |
| `lite`             | multi-variant work adapter       | Yes, `review`          | `prosecution`, `defense`, `judge` | `1`                | No     | Compact local prosecution pass feeding the full defense-judge pipeline |
| `judge-only`       | multi-variant work adapter       | Yes, `review`          | `judge`                           | none               | Yes    | Terminal ruling over already-collected evidence                     |
| `proxy-github`     | multi-variant work adapter       | Yes, `review`          | `proxy-prosecution`               | none               | Yes    | GitHub review intake represented as proxy prosecution               |
| `post-fix`         | multi-variant work adapter       | Yes, `post-fix-review` | `prosecution`, `defense`          | `1`                | No     | Post-fix targeted prosecution and defense                           |
| `design-challenge` | methodology-variant work adapter | No                     | `prosecution`                     | `1`, `2`, `3`      | No     | Non-blocking design challenge methodology reused by design surfaces |

Port-filling adapters declare `provides:` and fill frame ports such as `review` or `post-fix-review`. Methodology-variant adapters do not declare `provides:`; they package a reusable adversarial method for a caller-owned port or phase.

Prosecution findings may include `requires_pipeline_pause: { reason: artifact-missing | runtime-output-required | user-input-required-by-decision-class }`. Prosecutors set this field only when the finding cannot be responsibly evaluated inside the current atomic window without missing artifacts, runtime output, or a decision-class user input requirement.

## Atomic Pipeline Discipline

When an adapter's `integrity-contract.atomic` value is `true`, the caller must run prosecution through the terminal stage as one uninterrupted pipeline. Between prosecution and the terminal stage, do not surface interim findings for action, do not edit files or mutate the working tree, and do not ask the user anything, in any form — no engagement prompts of any kind.

The retry exception is limited to re-running the same failed stage when a tool, model, or transport failure prevents the stage artifact from being produced. The retry must not change scope, dispatch edits, or ask the user for a decision.

The prosecutor-set interrupt exception applies only when a prosecution finding includes `requires_pipeline_pause` with one of the closed reasons. In that case, the caller pauses the pipeline after the current prosecution artifact is safely captured, reports the pause reason, obtains the missing artifact/output/input through the owning workflow, and resumes the same pipeline without treating interim findings as judged work.

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
- Enough context that a judge can independently verify the claim
- A tagged confidence and severity level: every finding is tagged with an explicit confidence + severity pair, using the canonical enums in `skills/routing-tables/assets/routing-config.json`, so the ledger stays machine-readable regardless of how weak the finding is

Coverage is first: report every finding that has a concrete failure mode, even when it is low-severity or uncertain — a weak finding is not a reason to omit it. Omission is scoped narrowly to items with no statable failure mode at all — pure noise with nothing a judge could evaluate. A finding with any statable failure mode, however marginal, gets tagged and reported, not dropped.

### 3. Prefer Targeted Verification Over Broad Scanning

Use the smallest checks that can disconfirm or support a suspected defect:

- Read the owning implementation or design section
- Trace wiring for new data, components, or integrations
- Inspect browser state only when the change touches UI behavior
- Compare documented expectations against what the repo currently does

### 4. Emit a Usable Ledger

Write findings so a defense or judge pass can act on them without reconstructing your reasoning from scratch. Avoid vague summaries such as "looks risky" or "might break stuff."

Coverage and economy are orthogonal axes, not a single dial: coverage governs whether a finding is reported at all — maximize it, reporting every finding with a statable failure mode regardless of severity or confidence — while economy governs how tersely a reported finding is written. Economy never justifies dropping a real finding; it only controls how much prose surrounds it.

## Review Lenses

> **Authoritative source**: which lessons are promoted here, what anchor each one lives at, and the trigger text that has to reach a reader are recorded in `Documents/Planning/lesson-promotion-manifest.json`. `.github/scripts/Tests/lesson-promotion-manifest.Tests.ps1` is what stops this section and that manifest drifting apart, and it is the suite a red comes from. **Renaming a heading below is a migration, not a regression** — update that lesson's `anchor` in the manifest in the same commit as the rename. A red naming an anchor you just renamed is reporting a manifest row left behind, not a lost lens.

Five failure modes a lens-based sweep reads past, each drawn from a pass where it did.

### When a remedy, a guard, a signal change, or a pin is the thing under review

#### A remedy for a silent defect reproduces that defect inside itself

When the thing being fixed is *silence*, the dominant failure mode is the fix re-enacting it. On PR #1006 a five-pass panel sustained **six** findings that were exactly that. Run this checklist against your own remedy: does its own output contain the shape it detects — read your output back through your own detector, and use a placeholder rather than a live literal. Can your safety check fail at all. Does a guard's predicate match the comment beside it (a *count* where the comment says *membership*). Does a diagnosis assert a cause its trigger does not establish. Does a counter double-count or shadow. Is the bound on the right half — two implementations answering the same question must share their load-bearing rules, and if they diverge, write down which is which at the divergence. Sequencing, not vigilance, is the lesson: running the acceptance criteria tests the contract's claims, and only a pass aimed at the **fix diff itself** asks whether a fix introduced a new defect or failed to close what it claims. Those are different questions. And whenever a fix adds a new outcome or branch, ask who controls the inputs that route to it.

#### A "nothing was lost" check assembled from a partition of its own input cannot fail

A preflight that records the input as prose-segments interleaved with replaced-spans, then asserts their concatenation equals the original, is true by construction — both lists are slices of the input. It never touches the output being written, and it stays green while the written body loses the prose. The reasoning that makes it *feel* rigorous is the trap: "comparing the two outputs would be circular, since anything silently dropped would be absent from both" is right about the wrong direction. **Name the artifact your check reads and confirm it is the one that ships.** If every value in the assertion derives from the input, the check cannot observe the transform at all. Both halves are needed and catch different things: input equals partition-of-input catches a misjudged region extent; every segment appearing in order **in the output that gets written** catches dropped content.

#### A proposed guard has two cheap falsifiers nobody runs

Before agreeing that "we should add a guard for X", run both. **Is the motivating instance even inside the guard's population?** A guard scoped to tracked files cannot see a claim made in an issue comment, a PR description, or a brief's epistemic map — on #1000 the entire filing rested on one failure that occurred during authoring in a comment, and a tree-scoped grep confirmed no tracked file made a claim of that shape at all. **Has the covered population ever actually drifted?** `git log -S "<the exact referenced string>"` answers it in one command; on #1000 it returned two commits, both *adding* references, zero corrections ever. Both checks require searching a different scope than the one that feels natural — grep for the claim *shape* rather than the referenced token, and search history rather than `HEAD`. A `HEAD`-scoped grep counts the surface and never the events, which makes the exposure look large. Corollary: if the register the references point at is append-only, the reference-breaking mutation cannot occur without a policy change.

#### Demoting a signal orphans whatever it was the sole producer of

An amendment that weakens, demotes, or removes a signal reasons carefully about the direction it is fixing and never asks what else that signal was the only source of. On #922 an amendment demoted one check to inconclusive in both directions; the consequence was that no git-only signal could produce a conclusive negative at all, one decision had no constructible input, and the acceptance criterion that same amendment added was unsatisfiable. Three prosecution lenses missed it — only the convergence cold read caught it, because a lens reads the amendment against the design and the tree while nobody enumerates the *return values* of the function being changed. **Mechanically: grep every `return` in the changed function and ask, per distinct output value, is this the only path that produces it?** If yes, that value's downstream consumers are orphaned and the amendment must say what replaces them. Related: treat an amendment's own "does not regress" claim as a finder-worthy hypothesis, never as grounding.

#### A test asserting that a name appears in a script pins nothing

Reading a script as text and asserting its function names appear is not a pin. On #1018 the remediation for "every gate is reachable only from the test suite" was pinned exactly that way — `Get-Content -Raw` plus five `Should -Match` on names. A post-fix pass replaced the gate call with a hard-coded allow and left the name in a trailing comment: the shipped gate returned allowed, exit 0, for a move it exists to refuse, and all 86 tests stayed green. That is the original finding reproduced one level down inside its own fix. **Invoke the entry point and assert on the exit code.** In PowerShell `& .\s.ps1 -Args` runs the script in a child *scope*, not a child process, so its `exit N` sets `$LASTEXITCODE` and the caller continues — end-to-end coverage of parameter binding, the gate call and the exit code costs nothing and spawns no child shell.

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
| A finding has a citation but no break | The judge cannot tell whether it is a defect or a preference | State the concrete failure mode; if severity is uncertain, re-type and downgrade the item before output (e.g. Issue → Concern/Nit) rather than dropping it |

## Frame Ports Filled By This Skill

| Port              | Work adapter                                                                                                                                                                                                                                                                   | Explicit-skip adapter                                                                                  |
| ----------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------ |
| `review`          | [agents/Code-Review-Response.agent.md](../../agents/Code-Review-Response.agent.md); [adapters/standard.md](adapters/standard.md); [adapters/lite.md](adapters/lite.md); [adapters/judge-only.md](adapters/judge-only.md); [adapters/proxy-github.md](adapters/proxy-github.md) | [adapters/review-explicit-skip-adapter.md](adapters/review-explicit-skip-adapter.md)                   |
| `post-fix-review` | [adapters/post-fix.md](adapters/post-fix.md)                                                                                                                                                                                                                                   | [adapters/post-fix-review-explicit-skip-adapter.md](adapters/post-fix-review-explicit-skip-adapter.md) |

## Integrity Contract (Decision 6 - per-adapter exemptions)

Each adversarial review adapter declares its expected pipeline shape in YAML frontmatter under the `integrity-contract:` key. The frame credit ledger and dispatcher checks use this declaration to verify that the produced artifacts match what the adapter promises.

Required keys:

- `pipeline-stages:` ordered stage names such as `prosecution`, `proxy-prosecution`, `defense`, and `judge`
- `atomic:` `true` when the declared stages must run as one uninterrupted pipeline, or `n/a` for single-stage and exempt adapters
- `prosecution-passes:` ordered prosecution pass IDs expected for that adapter, or an empty list when the adapter is exempt from numbered prosecution output
- `exempt:` boolean indicating whether missing numbered prosecution output is expected for that adapter

| Adapter            | Pipeline stages                   | Atomic | Prosecution passes | Exempt | Reason                                                                   |
| ------------------ | --------------------------------- | ------ | ------------------ | ------ | ------------------------------------------------------------------------ |
| `standard`         | `prosecution`, `defense`, `judge` | `true` | `[1, 2, 3, 4, 5]`  | No     | Runs five-pass two-layer prosecution (2 generalist + 3 specialist) before defense and judge |
| `lite`             | `prosecution`, `defense`, `judge` | `true` | `[1]`              | No     | Runs one compact prosecution pass, then defense, then judge as one atomic pipeline |
| `judge-only`       | `judge`                           | `n/a`  | `[]`               | Yes    | Re-review scope; prior prosecution and defense evidence already exists   |
| `proxy-github`     | `proxy-prosecution`               | `n/a`  | `[]`               | Yes    | External review intake; proxy prosecution replaces numbered local passes |
| `post-fix`         | `prosecution`, `defense`          | `true` | `[1]`              | No     | Runs one targeted prosecution pass and defense after fixes               |
| `design-challenge` | `prosecution`                     | `n/a`  | `[1, 2, 3]`        | No     | Methodology-variant design challenge; no frame port ownership            |

For the `design-challenge` methodology variant, pass identity is declared in the design-challenge adapter's `pass-lenses` key, not in this mapping. All three passes emit `"Use design review perspectives"`.
