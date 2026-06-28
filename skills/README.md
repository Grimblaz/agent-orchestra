# Skills Directory

Skills are **knowledge modules** that extend agent capabilities with domain-specific expertise.

## What Are Skills?

- **Agents** = WHO does the work (behavior/persona)
- **Skills** = WHAT they know (domain knowledge)

Skills are loaded on-demand, not always in context. This improves context efficiency, modularity, and reuse.

## Progressive Disclosure (Router Pattern)

Each skill should use this flow:

1. `SKILL.md` is always loaded first
2. Router asks for intent (intake question)
3. Intent routes to targeted references/workflows
4. Only the needed files are loaded

This keeps prompts concise while preserving depth when needed.

## Available Skills (53)

| Skill | Purpose | Status |
| ----- | ------- | ------ |
| `adversarial-review` | Evidence-first prosecution and defense methodology for review workflows | ✅ Included |
| `ai-first-documentation` | Research-backed standards for documentation in AI-first codebases: context-file architecture (CLAUDE.md, skills, subagents, rules), multi-agent interop, and project-doc organization, with a tiered audit rubric. Use when authoring or auditing CLAUDE.md/AGENTS.md, deciding where guidance belongs, or running a documentation gap analysis. DO NOT USE FOR: post-implementation doc updates (use documentation-finalization) or reference sidecar setup (use project-references). | ✅ Included |
| `bdd-scenarios` | Structured Given/When/Then scenario authoring with ID traceability and CE Gate coverage gap detection | ✅ Included |
| `brainstorming` | Structured Socratic questioning for exploring ideas and solutions | ✅ Included |
| `browser-canvas-testing` | VS Code native browser tool behavior for canvas-based games | ✅ Included |
| `calibration-pipeline` | Calibration and review-pipeline tooling guidance | ✅ Included |
| `code-review-intake` | Deterministic GitHub review intake workflow with ledger-based judgment | ✅ Included |
| `copilot-cost-collection` | Copilot OTel cost collection setup and branch-correlated telemetry guidance | ✅ Included |
| `customer-experience` | Reusable customer framing and CE evidence methodology | ✅ Included |
| `design-exploration` | Technical design option comparison and decision-framing workflow | ✅ Included |
| `documentation-finalization` | Documentation cleanup and design-doc maintenance workflow | ✅ Included |
| `engagement-record-emission` | Marker contract for Segment-A maintainer-evidence and cross-session engagement-state preservation. Use when an agent exits its phase. DO NOT USE FOR: runtime code execution, test writing, or PR creation. | ✅ Included |
| `frame-credit-emission` | Frame credit row emission and deferred credit-input methodology | ✅ Included |
| `frame-credit-ledger` | Warn-only frame port-coverage ledger posted as a PR comment after `gh pr create` | ✅ Included |
| `frame-spine-lookup` | Frame spine lookup methodology for specialist plan-slice retrieval | ✅ Included |
| `frontend-design` | Guide for creating distinctive UI designs that avoid generic templates | ✅ Included |
| `guidance-measurement` | Guidance-complexity measurement tooling and deterministic analysis guidance | ✅ Included |
| `implementation-discipline` | Minimal implementation workflow for plan-driven coding | ✅ Included |
| `naming-register-policy` | Two-register naming policy for agent-orchestra: rules for when machine codes stay as-is vs get human names or first-use expansion. Use when authoring human-facing prose, sweeping rename-candidates, or resolving what a code like SMC-20 means. DO NOT USE FOR: deciding whether to create new vocabulary (use design-exploration), auditing docs for general readability (use ai-first-documentation for agent docs or #750/#751 for human docs). | ✅ Included |
| `parallel-execution` | Build-test orchestration protocol for parallel or serial implementation lanes | ✅ Included |
| `persist-changes` | Git-portable commit+push primitive for applied changes. Caller-parameterized; no Code-Conductor session flags. Use after a validated terminal step to commit staged fix files and push to the current branch's PR head remote. DO NOT USE FOR: new-PR creation (that is Code-Conductor Step 4 git push -u origin); force-push; or any scenario requiring git add -A. | ✅ Included |
| `plan-authoring` | Implementation-plan authoring methodology | ✅ Included |
| `plugin-release-hygiene` | Version-bump guardrail and Claude startup drift backstop guidance | ✅ Included |
| `post-pr-review` | Post-merge checklist for archiving, documentation, versioning, and release tagging | ✅ Included |
| `pre-commit-formatting` | Final markdown and whitespace formatting backstop before validation | ✅ Included |
| `process-analysis` | Retrospective and process-analysis methodology for workflow review | ✅ Included |
| `process-retrospective` | Deferred process-retrospective frame-port skeleton | ✅ Included |
| `process-troubleshooting` | Five-scenario guide for diagnosing common orchestration failure patterns | ✅ Included |
| `project-references` | Reference discoverability and loading methodology for Agent Orchestra. Use when project reference sidecars, index, or citation structure is relevant to the workflow or documentation. DO NOT USE FOR: general code navigation, symbol lookup, or when project reference structure is not relevant to the current task. | ✅ Included |
| `property-based-testing` | Incremental rollout policy for property-based testing | ✅ Included |
| `refactoring-methodology` | Proportionate refactoring workflow for touched files and nearby debt | ✅ Included |
| `research-methodology` | Evidence-driven technical research and recommendation workflow | ✅ Included |
| `review-judgment` | Single-shot review judgment and scoring methodology | ✅ Included |
| `routing-tables` | Deterministic routing data for specialist dispatch and gate criteria | ✅ Included |
| `safe-operations` | Safe file-operation and issue-creation protocol | ✅ Included |
| `session-memory-contract` | Canonical session-state survival and handoff contract | ✅ Included |
| `session-startup` | Automatic startup cleanup guard for new conversations | ✅ Included |
| `skill-creator` | Guide for creating new skills with proper frontmatter format | ✅ Included |
| `software-architecture` | Clean Architecture, SOLID principles, and architectural decision guidance | ✅ Included |
| `solution-authoring` | Reusable engagement-gate methodology for content-authoring structured questions in upstream phases. Use when classifying a decision as load-bearing or routine, authoring a decision brief, handling an override or decline, capturing articulation, or evaluating skip rules. DO NOT USE FOR: GitHub setup, completion-marker ownership, or adversarial review pipeline orchestration. | ✅ Included |
| `specification-authoring` | Structured authoring guidance for formal specifications | ✅ Included |
| `step-commit` | Discrete validated-step commit workflow for Code-Conductor | ✅ Included |
| `subagent-env-handshake` | Claude subagent environment-handshake contract for tree-grounded claims | ✅ Included |
| `systematic-debugging` | 4-phase debugging process (Observe, Hypothesize, Test, Fix) | ✅ Included |
| `terminal-hygiene` | Terminal and test execution guardrails for Agent Orchestra workflows | ✅ Included |
| `test-driven-development` | TDD workflow guidance, quality standards, and practical patterns | ✅ Included |
| `tracking-format` | Tracking-file frontmatter and local coordination format guidance | ✅ Included |
| `ui-iteration` | Screenshot-driven UI polish workflow | ✅ Included |
| `upstream-onboarding` | Scaled context brief and standards check for upstream agents at each phase boundary | ✅ Included |
| `ui-testing` | Resilient React component testing strategies focusing on user behavior | ✅ Included |
| `validation-methodology` | Staged validation and review methodology for implementation workflows | ✅ Included |
| `verification-before-completion` | Evidence-based verification checklist before marking work complete | ✅ Included |
| `webapp-testing` | Playwright end-to-end testing guidance for web apps | ✅ Included |

## How to Use a Skill

1. Read `skills/{skill-name}/SKILL.md`
2. Answer the intake prompt in that router
3. Load the routed reference/workflow file(s)
4. Execute the selected guidance

### Example: Using test-driven-development

```text
Agent: I need to write tests for a new feature
1. Read skills/test-driven-development/SKILL.md
2. Choose "write" in intake
3. Read skills/test-driven-development/workflows/write-tests-first.md
4. Follow RED-phase workflow
```

### VS Code 1.108+ Discovery

Skills with `name` + `description` in SKILL.md frontmatter are discoverable in VS Code 1.108+ when `chat.useAgentSkills` is enabled.

```yaml
---
name: my-skill
description: What this skill does. Use when {trigger conditions}. DO NOT USE FOR: {negative scenarios} (use {other-skill}).
---
```

## Skill Structure

```text
skill-name/
├── SKILL.md              # Router (always loaded)
├── workflows/            # Step-by-step procedures
├── references/           # Domain knowledge
├── templates/            # Reusable output structures
└── scripts/              # Optional executable helpers
```

## Creating New Skills

Use `skill-creator` for guided creation.

Quick reference:

1. Create `skills/{your-skill-name}/`
2. Add `SKILL.md` with `name` + `description`
3. Add references/workflows/templates as needed
4. Update this README

See `skill-creator/SKILL.md` for detailed guidance and `test-driven-development/` for a complete example.

## Customization

> Skills may include stack-specific examples. Keep conceptual guidance intact and adapt commands/selectors/URLs for your project.

<!-- vocab-pointer -->
> **Unfamiliar with a code or term?** Shortcodes like `SMC-NN`, `D1/D2/D3`, and `CE Gate` are defined in the [plain-language vocabulary](../HOW-IT-WORKS.md#vocab).
