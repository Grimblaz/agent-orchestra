# How Agent Orchestra works

> **Last verified against v2.35.7 (2026-06-27).** If the README version badge shows a higher version, [`CLAUDE.md`](CLAUDE.md) is authoritative for the current pipeline.

Agent Orchestra is a multi-agent workflow system that guides software ideas through a structured pipeline — from customer framing to a merged pull request — using a coordinated set of AI agents, each with a defined role. It runs inside Claude Code as a plugin.[^copilot]

[^copilot]: GitHub Copilot / VS Code support was available but is frozen (no fixes) and retires after 2026-08-31. See [copilot-deprecation.md](Documents/Design/copilot-deprecation.md).

## 1. What Agent Orchestra is

Agent Orchestra is a multi-agent workflow system built for Claude Code that takes a software idea — captured as a GitHub issue — and carries it through customer framing, technical design, implementation planning, orchestrated coding, and adversarial review, ending with a merged pull request. Each stage is handled by a specialized AI agent with a defined role; no single agent tries to do everything. You can run the full journey or drop in at any stage, and every decision made along the way is recorded as a durable comment on the GitHub issue so work can resume across separate conversations without losing context.

## 2. The path a piece of work takes

Work moves through up to eight beats. Steps 2 and 3 (customer framing and technical design) are optional — the pipeline can start directly at planning for routine or clear-scope work. Step 6 (adversarial review) has two variants: full (three-pass panel) and lite (one compact prosecution pass).

1. **Idea becomes a GitHub issue.** Work starts as a software idea that is filed as a GitHub issue (an entry in the project's issue tracker). The issue number is the durable reference every later beat reads and writes.

   [Source: CLAUDE.md § Upstream pipeline — "frames the work" phrasing implies issue as the entry point]

2. **Customer framing (optional) — Experience-Owner.** Experience-Owner (the customer-journey framing agent) reads the issue and frames the feature as customer journeys (step-by-step descriptions of what a user is trying to accomplish), writes Given/When/Then scenarios (structured intent tests), and optionally runs the worth-it check (bet, falsifier, alternative) to recommend whether the feature should proceed, shrink, or be parked. The output is written back to the issue body.

   [Source: CLAUDE.md § Upstream pipeline, step 1]

3. **Technical design (optional) — Solution-Designer.** Solution-Designer (the architecture exploration agent) explores design options, runs a 3-pass design challenge (a stress-test by simulated critics) against the leading proposal, and documents the technical decisions made and the alternatives that were rejected — along with the reasoning for each choice. This output is also written to the issue body.

   [Source: CLAUDE.md § Upstream pipeline, step 2]

4. **Implementation plan — Issue-Planner.** Issue-Planner (the planning agent) produces a step-by-step implementation plan with CE Gate (Customer Experience Gate) coverage — mapping each plan step to the acceptance criteria and scenarios from earlier phases. The plan is stress-tested by an adversarial review pipeline (prosecution finds defects, defense rebuts or concedes, judge scores the verdict) and then persisted as a durable GitHub issue comment so it survives across sessions.

   [Source: CLAUDE.md § Upstream pipeline, step 3]

5. **Orchestrated build — Code-Conductor.** Code-Conductor (the orchestration agent) walks the approved plan slice by slice. For each slice it dispatches Senior Engineer (the default implementation executor) or a specialist agent (such as Code-Smith for minimal code changes, Test-Writer for behavior-focused tests, or Doc-Keeper for documentation). Once each slice is validated and committed, Code-Conductor advances to the next.

   [Source: CLAUDE.md § Orchestration]

6. **Adversarial review — prosecution, defense, judge.** A dedicated review pipeline runs over the changed code. Prosecution (the finding pass) identifies defects with evidence. Defense (the rebuttal pass) either concedes or rebuts each finding. Judge (the scoring pass) evaluates the ledger and emits a verdict. Two variants are available: `/orchestra:review` runs three prosecution passes then defense then judge; `/orchestra:review-lite` runs one compact prosecution pass before defense and judge.

   [Source: CLAUDE.md § Review pipeline]

7. **CE Gate — Customer Experience Gate.** Experience-Owner exercises the plan's acceptance criteria — and the customer scenarios from step 2, when framing ran — against the shipped feature to verify that what was built matches the original customer intent. A passing CE Gate is recorded as a credit row in the PR body.

   [Source: CLAUDE.md § Orchestration — "CE Gate" mentioned as a pipeline phase]

8. **Merged PR.** The validated, reviewed, CE-Gate-passed implementation lands on the main branch as a merged pull request.

## 3. How to read an issue or PR

GitHub renders certain structured elements that Agent Orchestra writes during each pipeline phase. This section explains what those elements mean in plain language.

### `## Scenarios` heading

When this heading appears in a GitHub issue body, it marks a list of Given/When/Then scenarios — structured intent tests that describe what a user should be able to do and what the system should do in response. Experience-Owner authors these scenarios during customer framing. Later, CE Gate uses this same list to verify that the shipped feature actually satisfies each scenario.

### `## Named Decisions` heading

When this heading appears in a GitHub issue body, it marks the formal record of design decisions made during framing or technical design. Each entry shows the choice made, the classification (whether it is load-bearing, meaning it materially changes the architecture or customer experience, or routine), the reasoning, and the alternatives that were considered and rejected. These entries help the team understand not just what was decided but why.

### Completion comments

When a pipeline phase finishes, the responsible agent posts a plain-text comment on the issue or PR. These comments follow a consistent pattern — for example: "Customer framing complete — ready for design" or "Implementation plan approved — ready for orchestration." Reading these comments tells you which phase was last completed and what the recommended next step is.

### Verdict language in PRs

PR comments from the review pipeline use a small set of terms that have specific meanings:

- `✅ Sustained` — the judge confirmed a prosecution finding; the defect was real and the defense did not successfully rebut it.
- `❌ Defense sustained` — the judge did not uphold a finding; the defense rebuttal was accepted.
- `CE Gate passed` — the Customer Experience Gate check confirmed that the shipped feature satisfies the customer scenarios.
- Adversarial review score lines — numeric summaries from the judge that indicate the overall verdict quality and whether the PR is ready to merge.

## 4. Want more detail?

The spine in sections 1–3 covers most of what you need to orient yourself. If you want to go deeper into a specific subsystem, expand one of the sections below.

<details>
<summary>Customer framing — Experience-Owner</summary>

Experience-Owner is the first agent in the upstream pipeline and the only agent with a customer lens. It reads a GitHub issue and frames the feature from the customer's perspective before any technical work begins.

**worth-it check (optional opening check).** Before framing, Experience-Owner can run a brief worth-it check. It evaluates three things: the bet (what outcome do we expect?), the falsifier (what would prove this wrong?), and the alternative (what else could we do?). The result is one of five recommendations: Proceed-full, Proceed-lite, Shrink, Park, or Decline. The worth-it check is advisory — it can be skipped with `frame it`.

**Customer journeys.** The main framing output is a set of customer journeys: step-by-step narratives that describe what a specific type of user is trying to accomplish and how the system supports them. Journeys anchor the feature in real user need rather than technical requirement.

**Scenarios.** Each journey is distilled into one or more Given/When/Then scenarios — structured intent tests that can later be used for CE Gate coverage. Scenarios appear under the `## Scenarios` heading in the issue body.

**Named decisions.** During framing, any significant choices the agent makes are recorded as named decisions under the `## Named Decisions` heading, with classification (load-bearing or routine), reasoning, and rejected alternatives.

**CE Gate (bookend role).** Experience-Owner also runs at the end of the pipeline as the CE Gate executor: it re-reads the scenarios it authored and exercises them against the shipped implementation to verify the feature was built correctly.

</details>

<details>
<summary>Technical design — Solution-Designer</summary>

Solution-Designer is the second upstream agent. It runs after customer framing (or directly from the issue if framing was skipped) and produces a technical design record before implementation planning begins.

**Design exploration.** The agent explores multiple design options, evaluates each against the requirements and constraints, and identifies a leading proposal. Exploration outputs are written to the issue body so the team can see what was considered.

**3-pass design challenge.** The leading proposal is stress-tested by a simulated adversarial panel across three passes. Each pass plays the role of a critical reviewer asking: what is wrong with this design? What edge cases does it miss? What would make this fail? The agent then resolves each challenge and refines the design.

**Technical decisions and acceptance criteria.** After the challenge, the agent writes the key technical decisions into the issue body (under `## Named Decisions`) and expands or refines the acceptance criteria so that Issue-Planner has a precise target to plan against.

**Rejected alternatives.** Every option that was explored but not chosen is documented with the reason it was rejected. This prevents the team from re-litigating the same options later and creates an audit trail of the design process.

</details>

<details>
<summary>Implementation planning — Issue-Planner</summary>

Issue-Planner reads the framed and designed issue and produces an implementation plan that Spine-Runner or Code-Conductor can execute slice by slice.

**Plan structure.** The plan is a YAML document (frame-spine format, `spine_schema_version: 2`) with an ordered list of slices. Each slice has a step ID, a commit index, an adapter path (the methodology file that governs that slice), a set of AC-refs (acceptance-criteria references), and a requirement contract (the precise deliverable for that slice).

**CE Gate coverage.** Every slice in the plan is mapped to one or more acceptance criteria from the issue. This mapping ensures that when all slices are complete, every acceptance criterion has been addressed by at least one committed change.

**Adversarial stress-test.** Before the plan is approved, Issue-Planner runs it through a 5-pass adversarial review: multiple prosecution rounds find planning defects, defense rebuts or concedes, and a judge scores the verdict. Only plans that survive this challenge are persisted.

**Durable persistence.** The approved plan is written as a GitHub issue comment with a `<!-- plan-issue-{ID} -->` marker. This marker is what Code-Conductor reads on resume — it is the contract that survives across sessions and tools.

</details>

<details>
<summary>Orchestration — Code-Conductor</summary>

Code-Conductor is the hub-mode orchestration agent that reads the persisted plan and walks it from first slice to merged PR.

**Smart resume.** When invoked, Code-Conductor first looks for the `<!-- plan-issue-{ID} -->` marker on the GitHub issue to find the approved plan. It then scans for engagement-record markers to determine which slices have already been completed, so it can resume in the right place without repeating work.

**Scope classification.** Before implementation begins, Code-Conductor runs a scope-classification gate to determine the engagement type (routine, exploratory, or structural). This gate cannot be suppressed by user pacing directives — it always fires.

**Slice dispatch.** For each slice in the plan, Code-Conductor resolves the adapter path, selects the appropriate executor (Senior Engineer by default, or a specialist agent when the plan specifies one), and dispatches the work. The executor runs, validates, and returns evidence; Code-Conductor then advances to the next slice.

**D9 model-switch checkpoint.** When a slice requires a capability beyond the current model's strengths, Code-Conductor may pause at the D9 checkpoint to confirm a model switch before proceeding.

**PR creation.** After all slices are complete and CE Gate passes, Code-Conductor creates or updates the pull request with the pipeline-metrics block (a machine-parseable summary of which frame ports were covered and by whom).

</details>

<details>
<summary>Adversarial review pipeline</summary>

The adversarial review pipeline runs after implementation to find defects before merge. It uses three roles — prosecution, defense, and judge — each played by a separate agent invocation to maintain independence.

**Prosecution.** The prosecution pass reads the changed code and writes a finding ledger: a list of defects, each with evidence, severity, and the specific code location. Prosecution does not propose fixes — it only documents what it found and why it matters.

**Defense.** The defense pass reads the prosecution ledger and responds to each finding. For each item, defense either concedes (the finding is valid) or rebuts (with a counter-argument and evidence). Defense may also raise mitigating context the prosecution missed.

**Judge.** The judge reads both the prosecution ledger and the defense responses, then scores each finding as `✅ Sustained` (prosecution wins) or `❌ Defense sustained` (defense wins). The judge also emits an overall verdict score and writes a `<!-- judge-rulings ... -->` YAML block into the PR comment so Code-Conductor can read the result as a machine-parseable credit row.

**Full vs. lite variants.**

- `/orchestra:review` — full variant: three prosecution passes (different critics with different focus areas), then defense, then judge. Used for significant or high-risk changes.
- `/orchestra:review-lite` — lite variant: one compact prosecution pass, then defense, then judge. Used for small changes or when speed matters more than exhaustive coverage.

**GitHub review intake.** `/review-github` is a separate entry point that ingests an existing GitHub PR review and runs proxy prosecution — treating the human reviewer's comments as the prosecution ledger and running them through Code-Conductor's response loop for fix dispatch.

</details>

<a id="vocab"></a>
## 5. Plain-language vocabulary

<!-- vocab-seed:begin -->

> **Column guide for #732 policy extraction**: "Term as you'll see it" maps to the code/identifier (column 1 → Term);
> "Plain meaning" is the human name or first-use expansion (column 2 → human name / first-use expansion);
> "Where it appears" is the canonical machine home, if one exists (column 3 → source file or skill path).

| Term as you'll see it | Plain meaning | Where it appears |
|---|---|---|
| **upstream pipeline** | The three-agent planning sequence (Experience-Owner → Solution-Designer → Issue-Planner) that turns a GitHub issue into an approved implementation plan before any code is written. | `CLAUDE.md § Upstream pipeline` |
| **Experience-Owner** | First upstream agent; frames the feature as customer journeys, writes problem statement and scenarios, and runs the Value Reflex worth-it check. Invoked with `/experience`. | `agents/Experience-Owner.agent.md` |
| **Solution-Designer** | Second upstream agent; runs design exploration, the 3-pass design challenge, and writes technical decisions and acceptance criteria into the issue. Invoked with `/design`. | `agents/Solution-Designer.agent.md` |
| **Issue-Planner** | Third upstream agent; produces the implementation plan with CE Gate coverage and the adversarial review pipeline, then persists it as a durable issue comment. Invoked with `/plan`. | `agents/Issue-Planner.agent.md` |
| **Code-Conductor** | Orchestration agent that walks the approved plan through implementation, validation, CE Gate, and PR creation. Invoked with `/orchestrate`. | `agents/Code-Conductor.agent.md` |
| **Senior Engineer (SE)** | Default executor agent for individual implementation slices dispatched by Spine-Runner. Runs the planner-designated adapter; does not choose its own methodology. | `agents/Senior-Engineer.agent.md` |
| **Spine-Runner** | Minimal frame-walking conductor that reads the frame-spine plan and dispatches one slice at a time to the appropriate executor. Invoked with `/spine-run`. | `agents/Spine-Runner.agent.md` |
| **CE Gate** | Customer Experience Gate — the validation step that checks whether the shipped implementation satisfies the customer journeys and acceptance criteria written by Experience-Owner. | `skills/customer-experience/SKILL.md` |
| **prosecution / defense / judge** | Three roles in the adversarial review pipeline: prosecution finds defects, defense rebuts or concedes, judge scores the ledger and emits a verdict. | `skills/adversarial-review/SKILL.md` |
| **adversarial review** | The `/orchestra:review` pipeline that runs prosecution → defense → judge on code or plans to surface defects with evidence-first rigor before merge. | `skills/adversarial-review/SKILL.md` |
| **design challenge** | A 3-pass non-blocking adversarial pass run by Solution-Designer to stress-test a proposed design before committing to it. | `skills/design-exploration/SKILL.md` |
| **frame / frame-spine** | The plan format used by Spine-Runner: a YAML document with `spine_schema_version: 2` that lists ordered slices, each with an adapter, AC-refs, and a requirement contract. | `skills/frame-spine-lookup/SKILL.md` |
| **frame slice (step_id: sN)** | A single unit of work within a frame-spine plan — one commit-index, one adapter, one set of AC-refs. Dispatched one at a time by Spine-Runner. | Frame-spine plan comment on the GitHub issue |
| **frame port** | A named capability slot in the frame architecture (e.g. `implement-code`, `review`, `ce-gate-cli`). Each port has a YAML declaration and a corresponding adapter file. | `Documents/Design/frame-architecture.md` |
| **adapter / skill-as-adapter** | A methodology file (`skills/{skill}/adapters/{port}-adapter.md`) that carries the task-specific contract for a frame slice; Senior Engineer loads it at dispatch time. | `CLAUDE.md § Senior Engineer + skill-as-adapter pattern` |
| **SMC-NN** | Session Memory Contract rule identifier (e.g. SMC-01 = plan persisted as issue comment; SMC-12 = silence-decision scoping). Governs what state is durable across sessions. | `skills/session-memory-contract/SKILL.md` |
| **plan-issue-{ID}** | HTML comment marker written into a GitHub issue comment to identify the durable plan artifact for a given issue. Parsed by Code-Conductor on resume. | `skills/session-memory-contract/references/handoff-markers.md` |
| **engagement-record-{phase}-{ID}** | Durable GitHub comment marker emitted when an upstream agent (experience/design/plan/orchestration) completes its phase, preserving engagement state across sessions. | `skills/engagement-record-emission/SKILL.md` |
| **named decision** | A formally documented design decision written into the issue body under `<!-- named-decisions:begin/end -->`, with a classification (load-bearing or routine) and an audit rationale. | `skills/solution-authoring/SKILL.md` |
| **load-bearing (decision)** | A classification for a named decision that materially changes the customer experience or architecture — requires a full structured question with options, recommendation, and audit rationale. | `skills/solution-authoring/SKILL.md` |
| **engagement gate** | A methodology checkpoint (classification question, standards-check, plan-approval) that fires unconditionally and cannot be suppressed by user pacing directives. | `CLAUDE.md § Engagement-gate non-overridability` |
| **Value Reflex** | Optional opening step in Experience-Owner that runs a quick worth-it check (bet / falsifier / alternative) and recommends Proceed-full, Proceed-lite, Shrink, Park, or Decline. | `agents/Experience-Owner.agent.md` |
| **upstream-onboarding** | Shared opening protocol run by all three upstream agents when an existing issue is referenced; renders a context brief and runs a standards check on inherited work. | `skills/upstream-onboarding/SKILL.md` |
| **scope classification** | The solution-authoring gate where Code-Conductor classifies the engagement type before implementation begins. Cannot be suppressed by pacing directives. | `skills/solution-authoring/SKILL.md` |
| **intent routing / nl_intent_routing** | Natural-language phrase matching that maps user messages to slash commands without the user typing a command. Anchored in the routing config. | `skills/routing-tables/assets/routing-config.json` |
| **routing-config.json** | The canonical JSON file that declares all intent-routing patterns, specialist dispatch tables, CE surface mappings, and gate criteria. | `skills/routing-tables/assets/routing-config.json` |
| **raw mode** | A within-conversation toggle (`/raw`, `just answer normally`) that disables intent routing so natural-language requests are answered directly without pipeline dispatch. | `CLAUDE.md § Intent Routing` |
| **credits[] / pipeline-metrics block** | The array of frame-credit rows written into the PR body, used by Code-Conductor to determine which pipeline ports have been covered. Machine-parsed by `frame-credit-ledger.ps1`. | `.github/scripts/frame-credit-ledger.ps1`; methodology: `skills/frame-credit-ledger/SKILL.md` |
| **credit provenance / witness type** | Each frame port declares a witness type (sentinel, issue-marker, diff, self-report) in its base-ref YAML; the verdict-time resolver checks that a `passed` credit has a corroborating independent signal. | `frame/ports/*.yaml` (base ref) |
| **enforce verdict / enforce check** | The GitHub check run that evaluates frame port coverage; marked advisory by default and requires credit provenance before it can be made a required merge gate. | `skills/frame-credit-ledger/SKILL.md` |
| **judge-rulings YAML block** | A machine-readable YAML block embedded in a PR comment by the review judge, containing scores and rulings that Code-Conductor reads via `credits[]`. | `skills/review-judgment/SKILL.md` |
| **review-judge-produced-{PR}** | A sentinel PR comment written before the judge-rulings comment, used as the provenance witness for the `review` credit row. | `skills/review-judgment/SKILL.md` |
| **BDD / behavioral scenario** | A Given/When/Then scenario authored under the `bdd-scenarios` skill, tagged `[auto]` or `[manual]`, and used for CE Gate coverage mapping. | `skills/bdd-scenarios/SKILL.md` |
| **prosecution depth** | The calibration metric that determines how deeply the adversarial prosecution pass examines a change — can transition between `skip`, `light`, and `full`. | `skills/calibration-pipeline/SKILL.md` |
| **calibration fixture / calibration pipeline** | Test data and scripts (`aggregate-review-scores-core.ps1`) that compute review quality metrics used to tune prosecution depth and sustain rates. | `skills/calibration-pipeline/SKILL.md` |
| **now-coupled / wall-clock dependent** | A test or fixture assertion whose pass/fail outcome depends on the actual current date (e.g. a hardcoded `skip_first_observed_at` that ages past a decay window). | Surfaces in issue tracker (e.g. #723) |
| **D1 / D2 / D3 (auto-mode rules)** | Named auto-mode boundary rules: D1 = routine ops auto-approve, D2 = outside-allowlist ops prompt, D3 = `AskUserQuestion` fires unconditionally. | `CLAUDE.md § Auto-mode boundary` |
| **session-startup** | The hook-driven opening protocol that runs the cleanup detector, checks for drift between installed and marketplace plugin versions, and preserves a run-once marker. | `skills/session-startup/SKILL.md` |
| **worktree / sibling worktree / orphan branch** | Git worktrees created for parallel implementation lanes; post-merge cleanup removes them. "Orphan" branches have no live worktree and no open PR. | `skills/session-startup/SKILL.md` |
| **tracking file** | A local YAML/Markdown file (`.claude/tracking/...`) that captures per-session workflow state, adapter decisions, and handoff notes. | `skills/tracking-format/SKILL.md` |
| **project references / sidecar** | Optional `.references/{file}.ref.json` files that give long-lived docs a load-on-demand hint; indexed in `.references/index.json`; cited as `[ref:{name}](path)`. | `skills/project-references/SKILL.md` |
| **plugin cache / plugin.json** | Claude Code caches the installed plugin by the `version` in `.claude-plugin/plugin.json`; a version bump is required to invalidate the cache after entry-point edits. | `skills/plugin-release-hygiene/SKILL.md` |
| **proxy prosecution** | A prosecution pass run by Code-Conductor on behalf of a GitHub code review comment received via `/review-github`, instead of running a live adversarial panel. | `skills/code-review-intake/SKILL.md` |
| **inline-dispatch** | Running an adapter or agent body in the active conversation context rather than dispatching a separate subagent (`executor: inline` in frame-slice frontmatter). | `CLAUDE.md § Senior Engineer + skill-as-adapter pattern` |
| **halt-return** | A structured YAML block Senior Engineer emits when work cannot proceed safely, with a `halt_reason` and evidence; prevents partial-completion claims. | `agents/Senior-Engineer.agent.md` |
| **subagent-env-handshake** | A `<!-- subagent-env-handshake v1 -->` block the parent embeds in a dispatch prompt; the subagent live-verifies its git state matches the parent before making tree-grounded claims. | `skills/subagent-env-handshake/SKILL.md` |
| **persist-changes** | The git-portable commit+push primitive (`skills/persist-changes/SKILL.md`) called as the terminal step after validated changes are staged. | `skills/persist-changes/SKILL.md` |
| **post-PR review / post-merge cleanup** | The checklist and automation run after a PR merges: archiving tracking files, removing worktrees, deleting orphan branches, and updating docs. | `skills/post-pr-review/SKILL.md` |

<!-- vocab-seed:end -->
