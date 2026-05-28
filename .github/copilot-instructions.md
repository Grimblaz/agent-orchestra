---
applyTo: "**"
---

# Project: Agent Orchestra

## Overview

Multi-agent workflow system for GitHub Copilot. Provides specialized agents, skills, and prompt templates that orchestrate AI-assisted software development.

## Intent Routing

1. Plugin processes are the default chat experience. Natural-language requests matching the `nl_intent_routing` table route to the corresponding slash command with a visible confirmation; `/raw` opts out.
2. Recommended order: (1) VS Code dropdown for VS Code users; (2) slash commands for both platforms; (3) natural-language with auto-routing confirmation; (4) @-mention is NOT recommended (unreliable in every plugin surface tested).
3. Slash commands diverge between Claude (commands/_.md) and Copilot (.github/prompts/_.prompt.md); the nl_intent_routing table carries both column names so the canonical command name is platform-portable.
4. Source of truth: `skills/routing-tables/assets/routing-config.json` anchors natural-language routing in `nl_intent_routing`.
5. First match per command-family per conversation uses `#tool:vscode/askQuestions` with options `Run /X for this (Recommended)`, `Continue as raw chat`, and `Don't ask again for this command-family this conversation`; use Copilot-native visible confirmation wording, with final phrasing locked during CE Gate capture. Subsequent same-family matches use inline confirmation: `Routing to /X — say /raw to opt out, otherwise proceed.`
6. Routing detection runs only on top-level user messages outside an active slash-command turn and outside subagent dispatches, and only after the session-startup run-once marker is recorded.
7. `/raw`, `just answer normally`, `don't run the pipeline`, `raw mode`, and `skip routing` activate within-conversation raw mode only: no persistence file, no SMC row, and new conversations start routing-active. Any user-typed slash command clears raw mode. Acknowledge with: `Raw mode active for this conversation — natural-language requests will not be routed. Any explicit slash command you type clears raw mode.`
8. For matched entries with a non-null `copilot_command` that require an explicit slash-command handoff, emit `Please run /X to continue` using the Copilot command from `nl_intent_routing` and stop; do not inline-emulate. If the matched entry has `copilot_command: null`, do not synthesize a command for Copilot users.
9. When proposed command frontmatter differs from the user-session model, append a one-line tier hint, e.g. `Will run on sonnet + medium per command frontmatter.`
10. No-match answers normally; first no-match per conversation appends `Tip: type /help for plugin slash commands, or /raw to suppress these hints.` Ambiguous-match uses a text-only disambiguation prompt with Copilot-valid commands, e.g. `Did you mean /design (technical design) or /plan (implementation plan)?`

## Technology Stack

- **Language**: Markdown (agent definitions, skills, instructions, documentation)
- **Framework**: VS Code Custom Agents (`.agent.md` format with YAML frontmatter)
- **Build Tool**: None (no compiled code)
- **Testing**: Pester (`.github/scripts/Tests/`), plus manual verification and grep-based structural checks
- **BDD Framework (opt-in)**: Structured G/W/T scenarios with scenario ID traceability and CE Gate coverage gap detection. Consumer repos enable by adding a `## BDD Framework` section to their `copilot-instructions.md`. Template ships BDD-disabled; see `skills/bdd-scenarios/SKILL.md` for authoring patterns. **Phase 2 (runner dispatch)**: add `bdd: {framework}` under the heading (recognized values: `cucumber.js`, `behave`, `jest-cucumber`, `cucumber`) to enable Gherkin file generation by Test-Writer and automated runner dispatch at CE Gate time by Code-Conductor.

## Architecture

Pipeline-based agent orchestration:

```text
@Experience-Owner → @Solution-Designer → @Issue-Planner → @Code-Conductor → PR
                                                ↓
                              Code-Smith, Test-Writer, Refactor-Specialist,
                              Doc-Keeper, Research-Agent, Process-Review,
                              Specification, Spine-Runner, Senior-Engineer
(CE Gate: @Code-Conductor delegates evidence capture to @Experience-Owner)
```

- **User-facing agents** (7): Experience-Owner, Solution-Designer, Issue-Planner, Code-Conductor, Code-Critic, Code-Review-Response, UI-Iterator
- **Internal agents and runners** (9): Code-Smith, Test-Writer, Refactor-Specialist, Doc-Keeper, Research-Agent, Process-Review, Specification, Spine-Runner, Senior-Engineer (`user-invocable: false`)
- **Skills** (42): Loaded on demand by agents from `skills/` (repo root)
- **Instruction files**: Repo-local instruction files remain under `.github/instructions/`, while shared workflow rules load from skills

## Frame Port Declarations

Before adding or changing any adapter that fills a frame port, read the Adapter Model in [Documents/Design/frame-architecture.md](../Documents/Design/frame-architecture.md). That design doc owns the declaration locations, provisional predicate DSL, and the distinction between port-filling adapters that declare `provides:` and supporting methodology skills that do not.

## Key Conventions

- Agent files use `.agent.md` extension with YAML frontmatter (`name`, `description`, `tools`, `handoffs`, `user-invocable`)
- Skills use `SKILL.md` with `name` and `description` frontmatter in `skills/{skill-name}/` at the repo root
- Instruction files use `.instructions.md` extension in `.github/instructions/`; shared workflow guidance is migrating to skill-owned `SKILL.md` files
- Design documents go in `Documents/Design/`, decision records in `Documents/Decisions/`
- Code-Conductor auto-commits after each validated step by default (see `## Commit Policy` opt-out in consumer `copilot-instructions.md`); specialist agents do not commit independently
- Session-state survival and handoff semantics are governed by [skills/session-memory-contract/SKILL.md](../skills/session-memory-contract/SKILL.md); design rationale lives in [Documents/Design/session-memory-contract.md](../Documents/Design/session-memory-contract.md)
- Plans are saved to session memory (`/memories/session/plan-issue-{ID}.md`), which is the same-session source of truth for implementation handoff
- Design context is cached in session memory (`/memories/session/design-issue-{ID}.md`), reused by Issue-Planner when the current snapshot is still valid and refreshed from the issue body when missing or after current-pass issue/design updates; Solution-Designer still persists design details to the issue body unconditionally during design
- VS Code auto-compacts conversation when context fills; session memory (`/memories/session/`) survives compaction within the same conversation. At D9, if the user explicitly chooses Stop / Pause / resume later, Code-Conductor persists durable GitHub handoff comments with `<!-- plan-issue-{ID} -->` / `<!-- design-issue-{ID} -->`; Continue uses session memory only
- Design content goes in the GitHub issue body (Solution-Designer outputs there)
- `Documents/Design/` files use domain-based naming (`{domain-slug}.md`) and are committed with the implementation PR by Code-Conductor (delegated to Doc-Keeper)
- CE Gate uses `ce_gate: true` plan metadata and a `[CE GATE]` step for customer-experience and design-intent verification

## Code-Critic Adversarial Review Protocol

This repo uses the Code-Critic / Code-Review-Response scored prosecution → defense → judge review protocol.

Load the relevant agent guidance and follow that protocol for code review, design review, CE review, GitHub review, and post-fix review.

## Engagement-gate non-overridability

<!-- engagement-gate-non-overridability:begin -->

User pacing directives — including but not limited to "work without stopping," "don't pause to ask," "make the reasonable call," and semantically equivalent phrasing — apply to **preference-clarifying questions**: questions the agent would otherwise ask to gather requirements, options, or non-load-bearing preferences. Pacing directives do **NOT** apply to **engagement-gate methodology checkpoints**:

- `solution-authoring` classification gates
- `upstream-onboarding` standards-check questions
- `plan-authoring` plan-approval prompts
- design-convergence decisions

Methodology checkpoints fire unconditionally. The user's only in-band lever to skip an engagement-gate question is the option built into that specific question (e.g., `solution-authoring`'s `Decline engagement — proceed without classification`, `upstream-onboarding`'s alternative-option selection, `plan-authoring`'s `Reject` plan-approval path).

See: `skills/solution-authoring/SKILL.md` § Rule: Classification gate; `skills/solution-authoring/SKILL.md` § Rule: Non-overridability; `skills/upstream-onboarding/SKILL.md` § Rule: Non-overridability; `skills/plan-authoring/SKILL.md` § Rule: Non-overridability. Also see: #575 and SMC-20 + `skills/engagement-record-emission/SKILL.md` (engagement-record-{phase}-{ID} marker contract; #576 v1.2) for the Segment-A maintainer-evidence path.

<!-- engagement-gate-non-overridability:end -->

## Build & Run

No build step. This is a configuration/documentation template.

### Commands

```powershell
# Run PowerShell script test suite (Pester)
pwsh -NoProfile -NonInteractive -Command "Invoke-Pester .github/scripts/Tests/ -Output Minimal"
# Final-gate full suite: see Terminal & Test Hygiene > `isBackground` Default exception (final-gate full suite). In fixture mode (default), isBackground: false is fine. For live-refresh runs (PESTER_LIVE_GH=1), use isBackground: true + poll with `get_terminal_output` to read results (Pester 5 sends pass/fail output to the terminal buffer, not to file streams — `*>` redirection only captures advisory output such as `Write-Warning`).

# Validate structural checks (broken references, skill frontmatter, complexity, lint)
pwsh -NoProfile -NonInteractive -File .github/scripts/quick-validate.ps1

# Check agent count
(Get-ChildItem agents/*.agent.md).Count  # should be 16
```

### Script Library Convention

Production automation lives either under `.github/scripts/` or under the owning skill's `scripts/` directory, with thin CLI wrappers dot-sourcing companion `*-core.ps1` libraries where applicable. Tests dot-source the core libraries directly and call the function in-process, avoiding per-test `pwsh` child process spawning. Private helpers inside a library embed a short uppercase prefix in the noun segment (`NW`, `WCE`, `SCD`) to avoid name collisions across dot-sourced files (e.g., `Test-NWAllowlistedPath`, `Test-WCEHasProperty`, `Get-SCDDefaultBranch`).

```powershell
# Example: call aggregate-review-scores logic in-process
. skills/calibration-pipeline/scripts/aggregate-review-scores-core.ps1
Invoke-AggregateReviewScores -Repo owner/name
# Example: with mock gh CLI for tests (no live API calls)
# Invoke-AggregateReviewScores -Repo owner/name -GhCliPath $mockGhScript
```

## Safe Operations

When choosing workspace tools, reading or mutating files, or creating follow-up GitHub issues, load the `safe-operations` skill and follow its protocol.

## Quick-validate (used by agents before every PR)

After editing any `.md` files, run the Markdown auto-formatter before committing:

```powershell
markdownlint-cli2 --fix "**/*.md"
```

Then run the structural checks:

```powershell
pwsh -NoProfile -NonInteractive -File .github/scripts/quick-validate.ps1
```

## Terminal & Test Hygiene

> These rules supplement (do not replace) any agent-specific terminal guidance.

During implementation and validation work, load the `terminal-hygiene` skill and follow its protocol.

Use `isBackground: false` / `mode: sync` for commands expected to complete in under 60 seconds.
