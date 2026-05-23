# Code-Conductor Responsibility Map

This map records Code-Conductor responsibilities as structured evidence for deciding the future `/orchestrate` -> `/spine-run` switch. Read the map in Code-Conductor document order: each responsibility row will name the source section, describe the work, assign its disposition, and point maintainers to the evidence or action needed for switch readiness.

Retirement clause: this artifact is archived to `Documents/Decisions/` and its Pester gates removed when >=90% of `planner-should-absorb` rows have shipped their absorption work AND the `/orchestrate` -> `/spine-run` switch has landed.

Planner absorption umbrella: [#588](https://github.com/Grimblaz/agent-orchestra/issues/588)

## Responsibilities

```yaml
- source: "Code Conductor Agent"
  responsibility: "Own the end-to-end implementation outcome and customer experience, while specialists perform hands-on work."
  disposition: spine-runner-keeps
  action: "Preserve as the conductor-level outcome contract for any /orchestrate -> /spine-run switch."
  verification_status: verified
  verified-against-sha: "50ee151ab33d45cceb7107923c2ae2e6101aa95e"
  verified-via-pr-sha: ""
- source: "ownership-principles / Ownership Principles"
  responsibility: "Treat feature behavior working end-to-end as success, not mere completion of process steps."
  disposition: spine-runner-keeps
  action: "Keep as a runtime quality gate before PR creation and completion reporting."
  verification_status: verified
  verified-against-sha: "50ee151ab33d45cceb7107923c2ae2e6101aa95e"
  verified-via-pr-sha: ""
- source: "Ownership Principles"
  responsibility: "Exercise judgment when specialist output passes tests but misses the goal."
  disposition: spine-runner-keeps
  action: "Keep goal-check authority in the conductor that dispatches and evaluates specialists."
  verification_status: verified
  verified-against-sha: "50ee151ab33d45cceb7107923c2ae2e6101aa95e"
  verified-via-pr-sha: ""
- source: "Ownership Principles"
  responsibility: "Verify prerequisites and adapt when plan assumptions no longer match the repository."
  disposition: spine-runner-keeps
  action: "Keep pre-dispatch reality checks in the frame walker before each executable slice."
  verification_status: verified
  verified-against-sha: "50ee151ab33d45cceb7107923c2ae2e6101aa95e"
  verified-via-pr-sha: ""
- source: "Ownership Principles"
  responsibility: "Diagnose failures before retrying specialist work."
  disposition: adapter-handles
  action: "Use skills/parallel-execution/references/error-handling.md for retry classification and recovery routing."
  verification_status: verified
  verified-against-sha: "50ee151ab33d45cceb7107923c2ae2e6101aa95e"
  verified-via-pr-sha: ""
- source: "Ownership Principles"
  responsibility: "Escalate with concrete options and a recommendation when user authority is required."
  disposition: spine-runner-keeps
  action: "Keep structured decision prompts as a conductor invariant for authority-boundary pauses."
  verification_status: verified
  verified-against-sha: "50ee151ab33d45cceb7107923c2ae2e6101aa95e"
  verified-via-pr-sha: ""
- source: "Ownership Principles"
  responsibility: "Route every user-facing question or approval request through vscode/askQuestions."
  disposition: spine-runner-keeps
  action: "Keep question-channel enforcement in the runtime shell for all conductor pauses."
  verification_status: verified
  verified-against-sha: "50ee151ab33d45cceb7107923c2ae2e6101aa95e"
  verified-via-pr-sha: ""
- source: "Ownership Principles"
  responsibility: "Continue autonomously toward merge-ready unless true user decision authority is required."
  disposition: spine-runner-keeps
  action: "Keep default-continuation behavior as the outer orchestration policy."
  verification_status: verified
  verified-against-sha: "50ee151ab33d45cceb7107923c2ae2e6101aa95e"
  verified-via-pr-sha: ""
- source: "D-rules D1-D14 / Questioning & Pause Policy (Mandatory)"
  responsibility: "Enforce zero-tolerance structured-question and no plain-text pause rules."
  disposition: spine-runner-keeps
  action: "Preserve as runtime guardrails around all D-rule checkpoints and branch decisions."
  verification_status: verified
  verified-against-sha: "50ee151ab33d45cceb7107923c2ae2e6101aa95e"
  verified-via-pr-sha: ""
- source: "Model-Switch Checkpoint (Authorized Hub-Mode Pause)"
  responsibility: "Fire the authorized hub-mode D9 pause after plan approval when an upstream phase ran in-session."
  disposition: spine-runner-keeps
  action: "Keep the D9 checkpoint in hub-mode orchestration; later verification should compare against Spine-Runner pause behavior."
  verification_status: verified
  verified-against-sha: "50ee151ab33d45cceb7107923c2ae2e6101aa95e"
  verified-via-pr-sha: ""
- source: "Review Workflow Interruption Budget (Balanced Policy)"
  responsibility: "Limit review workflows to a single late-stage decision prompt when authority is required."
  disposition: spine-runner-keeps
  action: "Keep interruption-budget accounting in review-loop orchestration."
  verification_status: verified
  verified-against-sha: "50ee151ab33d45cceb7107923c2ae2e6101aa95e"
  verified-via-pr-sha: ""
- source: "Continuation Contract (Mandatory)"
  responsibility: "Prevent silent session stops before PR creation or a structured askQuestions pause."
  disposition: spine-runner-keeps
  action: "Keep continuation enforcement as a top-level conductor invariant."
  verification_status: verified
  verified-against-sha: "50ee151ab33d45cceb7107923c2ae2e6101aa95e"
  verified-via-pr-sha: ""
- source: "Overview"
  responsibility: "Delegate specialized work to expert agents and announce each specialist before dispatch."
  disposition: spine-runner-keeps
  action: "Keep dispatch announcement and specialist delegation in the frame-walking runtime."
  verification_status: verified
  verified-against-sha: "50ee151ab33d45cceb7107923c2ae2e6101aa95e"
  verified-via-pr-sha: ""
- source: "Overview"
  responsibility: "Keep Code-Conductor out of direct file editing and reserve it for read/search plus validation commands."
  disposition: spine-runner-keeps
  action: "Preserve no-direct-editing as a conductor-shell capability boundary."
  verification_status: verified
  verified-against-sha: "50ee151ab33d45cceb7107923c2ae2e6101aa95e"
  verified-via-pr-sha: ""
- source: "Overview"
  responsibility: "Declare serial or parallel execution mode per implementation step with identical requirement contracts and convergence gates."
  disposition: planner-should-absorb
  action: "Track absorption in https://github.com/Grimblaz/agent-orchestra/issues/589; move execution-mode declaration defaults into skills/plan-authoring/SKILL.md execution-step responsibilities while runtime still honors slice metadata."
  verification_status: unverified
  verified-against-sha: ""
  verified-via-pr-sha: ""
- source: "Overview"
  responsibility: "Choose parallel for stable isolated work and serial for exploratory or high-risk work."
  disposition: planner-should-absorb
  action: "Track absorption in https://github.com/Grimblaz/agent-orchestra/issues/589; encode mode-selection heuristics in skills/plan-authoring/SKILL.md and generated frame-slice metadata."
  verification_status: unverified
  verified-against-sha: ""
  verified-via-pr-sha: ""
- source: "Usage Examples"
  responsibility: "Describe example flows for full implementation and research-first work."
  disposition: not-applicable
  action: "No absorption action required; examples are illustrative prompt guidance, not a discrete runtime responsibility."
  rationale: "The section documents usage examples rather than behavior that a planner, runner, or adapter must execute."
  verification_status: unverified
  verified-against-sha: ""
  verified-via-pr-sha: ""
- source: "Plan Creation Strategy"
  responsibility: "Route well-defined and exploratory scopes through Issue-Planner for plan creation."
  disposition: planner-should-absorb
  action: "Track absorption in https://github.com/Grimblaz/agent-orchestra/issues/590; keep plan-creation strategy owned by Issue-Planner and skills/plan-authoring/SKILL.md so the conductor only requests or consumes plans."
  verification_status: unverified
  verified-against-sha: ""
  verified-via-pr-sha: ""
- source: "Plan Creation Strategy"
  responsibility: "Adapt steps when plan assumptions drift from code reality and record the rationale."
  disposition: spine-runner-keeps
  action: "Keep runtime plan-reality reconciliation before slice dispatch."
  verification_status: verified
  verified-against-sha: "50ee151ab33d45cceb7107923c2ae2e6101aa95e"
  verified-via-pr-sha: ""
- source: "Plan Creation Strategy"
  responsibility: "Never create plans directly, regardless of scope, tier, or bundling."
  disposition: spine-runner-keeps
  action: "Preserve a hard no-plan-authoring boundary in the runner; plan content remains Issue-Planner-owned."
  verification_status: verified
  verified-against-sha: "50ee151ab33d45cceb7107923c2ae2e6101aa95e"
  verified-via-pr-sha: ""
- source: "Process"
  responsibility: "Load solution-authoring before any subsequent skill fires a structured question."
  disposition: adapter-handles
  action: "Use skills/solution-authoring/SKILL.md for engagement-gate classification before structured questions."
  verification_status: verified
  verified-against-sha: "50ee151ab33d45cceb7107923c2ae2e6101aa95e"
  verified-via-pr-sha: ""
- source: "Process"
  responsibility: "Load upstream-onboarding and run its opening protocol after solution-authoring."
  disposition: adapter-handles
  action: "Use skills/upstream-onboarding/SKILL.md for context brief and inherited-work standards checks."
  verification_status: verified
  verified-against-sha: "50ee151ab33d45cceb7107923c2ae2e6101aa95e"
  verified-via-pr-sha: ""
- source: "Process"
  responsibility: "Track the cross-session engagement-state limitation that may re-fire settled structured questions."
  disposition: adapter-handles
  action: "Use the SMC-20 engagement-record-{phase}-{ID} marker payload contract and the same-decision-resume skip rule to preserve engagement state across sessions."
  revisit-trigger: "issue:#575"
  verification_status: verified
  verified-against-sha: "36b7ee2289f5a49ebdf416b4d1aea1b086b501d4"
  verified-via-pr-sha: ""
- source: "Process"
  responsibility: "Load terminal-hygiene for validation execution, continuation-prompt hazards, and non-fatal diagnostics."
  disposition: adapter-handles
  action: "Use skills/terminal-hygiene/SKILL.md for terminal and diagnostic guardrails."
  verification_status: verified
  verified-against-sha: "50ee151ab33d45cceb7107923c2ae2e6101aa95e"
  verified-via-pr-sha: ""
- source: "Step protocols Step 0-5 / Core Workflow / Hub Execution Workflow"
  responsibility: "Keep Issue Transition as Step 0 after any pre-response trigger handling."
  disposition: spine-runner-keeps
  action: "Preserve Step 0 ordering in any frame-walker entry path."
  verification_status: verified
  verified-against-sha: "50ee151ab33d45cceb7107923c2ae2e6101aa95e"
  verified-via-pr-sha: ""
- source: "Core Workflow / Step protocols Step 0-5 / Issue Transition Step 0"
  responsibility: "Use session-startup cleanup guidance for stale tracking artifacts from merged branches."
  disposition: adapter-handles
  action: "Use skills/session-startup/SKILL.md and skills/session-startup/scripts/post-merge-cleanup.ps1 for cleanup recovery."
  verification_status: verified
  verified-against-sha: "50ee151ab33d45cceb7107923c2ae2e6101aa95e"
  verified-via-pr-sha: ""
- source: "Core Workflow / Step protocols Step 0-5 / Issue Transition Step 0"
  responsibility: "Call Issue-Planner when scope or acceptance criteria have changed or are ambiguous before execution."
  disposition: planner-should-absorb
  action: "Track absorption in https://github.com/Grimblaz/agent-orchestra/issues/590; make plan-amendment criteria explicit in skills/plan-authoring/SKILL.md and Issue-Planner handoff wording."
  verification_status: unverified
  verified-against-sha: ""
  verified-via-pr-sha: ""
- source: "Hub Mode & Smart Resume"
  responsibility: "Treat non-specific Code-Conductor invocation and /orchestrate as hub mode from framing through PR creation."
  disposition: spine-runner-keeps
  action: "Keep hub-mode detection and /orchestrate equivalence in the entry shell that launches Spine-Runner."
  verification_status: verified
  verified-against-sha: "50ee151ab33d45cceb7107923c2ae2e6101aa95e"
  verified-via-pr-sha: ""
- source: "Hub Mode & Smart Resume"
  responsibility: "Read issue comments for upstream completion markers and skip completed phases."
  disposition: spine-runner-keeps
  action: "Keep marker-based smart resume in orchestration; verify against session-memory-contract and issue comment lookup behavior later."
  verification_status: verified
  verified-against-sha: "50ee151ab33d45cceb7107923c2ae2e6101aa95e"
  verified-via-pr-sha: ""
- source: "Hub Mode & Smart Resume / Non-hub-mode invocation"
  responsibility: "Route direct slash-command prose by leading-token trigger phrases before generic specialist dispatch."
  disposition: adapter-handles
  action: "Use skills/routing-tables/SKILL.md and skills/routing-tables/assets/routing-config.json for prose-trigger and specialist-dispatch lookup."
  verification_status: verified
  verified-against-sha: "50ee151ab33d45cceb7107923c2ae2e6101aa95e"
  verified-via-pr-sha: ""
- source: "Hub Mode & Smart Resume / Non-hub-mode invocation"
  responsibility: "Keep direct /code-conductor prose task support in legacy no-spine mode until prose-plan spine support lands."
  disposition: defer
  action: "Revisit direct prose-plan spine handling when https://github.com/Grimblaz/agent-orchestra/issues/516 lands."
  revisit-trigger: "issue:#516"
  verification_status: unverified
  verified-against-sha: ""
  verified-via-pr-sha: ""
- source: "Scope Classification Gate"
  responsibility: "Classify issue scope before upstream calls and present full vs abbreviated tiers through askQuestions."
  disposition: spine-runner-keeps
  action: "Keep the authority-bound tier choice in hub orchestration before upstream dispatch."
  verification_status: verified
  verified-against-sha: "50ee151ab33d45cceb7107923c2ae2e6101aa95e"
  verified-via-pr-sha: ""
- source: "Scope Classification Gate"
  responsibility: "Evaluate abbreviated-tier criteria and phase matrix through routing-tables gate criteria."
  disposition: adapter-handles
  action: "Use skills/routing-tables/SKILL.md and skills/routing-tables/assets/gate-criteria.json for Test-GateCriteria scope_classification."
  verification_status: verified
  verified-against-sha: "50ee151ab33d45cceb7107923c2ae2e6101aa95e"
  verified-via-pr-sha: ""
- source: "Scope Classification Gate"
  responsibility: "Honor user override of the recommended pipeline tier."
  disposition: spine-runner-keeps
  action: "Keep tier override capture in the hub-mode decision prompt and downstream phase matrix."
  verification_status: verified
  verified-against-sha: "50ee151ab33d45cceb7107923c2ae2e6101aa95e"
  verified-via-pr-sha: ""
- source: "Scope Classification Gate"
  responsibility: "Handle Issue-Planner escalation_recommended frontmatter and offer full-pipeline re-entry before D9."
  disposition: spine-runner-keeps
  action: "Keep post-plan escalation handling in hub orchestration; planner owns producing escalation metadata."
  verification_status: verified
  verified-against-sha: "50ee151ab33d45cceb7107923c2ae2e6101aa95e"
  verified-via-pr-sha: ""
- source: "Scope Classification Gate"
  responsibility: "Call Experience-Owner, Solution-Designer, Issue-Planner, D9, and implementation in tier-defined order."
  disposition: spine-runner-keeps
  action: "Keep hub execution-order selection in the orchestration runtime."
  verification_status: verified
  verified-against-sha: "50ee151ab33d45cceb7107923c2ae2e6101aa95e"
  verified-via-pr-sha: ""
- source: "Downstream Ownership Boundary"
  responsibility: "Classify pre-edit work as downstream-owned, shared read-only guidance, or upstream shared-workflow mutation."
  disposition: spine-runner-keeps
  action: "Keep pre-edit ownership classification as a fail-closed runtime gate before mutation."
  verification_status: verified
  verified-against-sha: "50ee151ab33d45cceb7107923c2ae2e6101aa95e"
  verified-via-pr-sha: ""
- source: "Downstream Ownership Boundary"
  responsibility: "Stop with requires upstream issue for upstream shared-workflow mutation and use safe issue-creation rules when needed."
  disposition: adapter-handles
  action: "Use skills/safe-operations/SKILL.md for deduplication, priority labels, prevention analysis, and issue output capture."
  verification_status: verified
  verified-against-sha: "50ee151ab33d45cceb7107923c2ae2e6101aa95e"
  verified-via-pr-sha: ""
- source: "Downstream Ownership Boundary"
  responsibility: "Fail closed mid-run when newly discovered scope requires upstream shared-workflow mutation."
  disposition: spine-runner-keeps
  action: "Keep mid-run ownership reclassification in the runner before any new mutation delegation."
  verification_status: verified
  verified-against-sha: "50ee151ab33d45cceb7107923c2ae2e6101aa95e"
  verified-via-pr-sha: ""
- source: "Downstream Ownership Boundary"
  responsibility: "Apply repository-aware bypass, external-context, and local-clone rules to shared workflow edits."
  disposition: spine-runner-keeps
  action: "Keep repository-awareness in the downstream ownership gate."
  verification_status: verified
  verified-against-sha: "50ee151ab33d45cceb7107923c2ae2e6101aa95e"
  verified-via-pr-sha: ""
- source: "Downstream Ownership Boundary"
  responsibility: "Preserve D9 as the only durable execution-handoff writer."
  disposition: spine-runner-keeps
  action: "Keep durable handoff writes constrained to D9 pause handling."
  verification_status: verified
  verified-against-sha: "50ee151ab33d45cceb7107923c2ae2e6101aa95e"
  verified-via-pr-sha: ""
- source: "D9 Model-Switch Checkpoint (Hub Mode Only)"
  responsibility: "Present exactly the Continue implementation and Pause here options after plan approval when D9 applies."
  disposition: spine-runner-keeps
  action: "Keep exact D9 option labels and timing in hub-mode runtime."
  verification_status: verified
  verified-against-sha: "50ee151ab33d45cceb7107923c2ae2e6101aa95e"
  verified-via-pr-sha: ""
- source: "D9 Model-Switch Checkpoint (Hub Mode Only)"
  responsibility: "On pause, compare current plan/design snapshots against latest durable comments and append only changed or missing handoffs."
  disposition: spine-runner-keeps
  action: "Keep normalized durable-handoff comparison in D9 orchestration; verify against SMC behavior in a later step."
  verification_status: verified
  verified-against-sha: "50ee151ab33d45cceb7107923c2ae2e6101aa95e"
  verified-via-pr-sha: ""
- source: "D9 Model-Switch Checkpoint (Hub Mode Only)"
  responsibility: "Suppress D9 only for direct implement, all prior-session required artifacts, or already-answered checkpoint."
  disposition: spine-runner-keeps
  action: "Keep D9 suppression checks in hub-mode smart resume."
  verification_status: verified
  verified-against-sha: "50ee151ab33d45cceb7107923c2ae2e6101aa95e"
  verified-via-pr-sha: ""
- source: "Branch Authority Gate"
  responsibility: "Use live git proof before branch create, checkout, rename, or cleanup."
  disposition: spine-runner-keeps
  action: "Keep branch authority proof collection in the runtime before branch mutation commands."
  verification_status: verified
  verified-against-sha: "50ee151ab33d45cceb7107923c2ae2e6101aa95e"
  verified-via-pr-sha: ""
- source: "Branch Authority Gate"
  responsibility: "Fail safely on branch-context mismatch or ambiguous plausible branches before mutation."
  disposition: spine-runner-keeps
  action: "Keep mismatch reconciliation as a blocking branch-mutation gate."
  verification_status: verified
  verified-against-sha: "50ee151ab33d45cceb7107923c2ae2e6101aa95e"
  verified-via-pr-sha: ""
- source: "Branch Authority Gate"
  responsibility: "Treat same-tip duplicate branches as non-destructive and block rename or cleanup unless already in the intended state."
  disposition: spine-runner-keeps
  action: "Keep same-tip duplicate handling in branch-mutation safety checks."
  verification_status: verified
  verified-against-sha: "50ee151ab33d45cceb7107923c2ae2e6101aa95e"
  verified-via-pr-sha: ""
- source: "Multi-Issue Bundling"
  responsibility: "Check markers and classify scope per issue when hub mode receives multiple issues."
  disposition: spine-runner-keeps
  action: "Keep per-issue smart resume and scope classification in bundled hub orchestration."
  verification_status: verified
  verified-against-sha: "50ee151ab33d45cceb7107923c2ae2e6101aa95e"
  verified-via-pr-sha: ""
- source: "Multi-Issue Bundling"
  responsibility: "Adopt highest-scope-wins bundle tier and present all classifications in one askQuestions prompt."
  disposition: spine-runner-keeps
  action: "Keep single-prompt bundle tier confirmation in hub-mode orchestration."
  verification_status: verified
  verified-against-sha: "50ee151ab33d45cceb7107923c2ae2e6101aa95e"
  verified-via-pr-sha: ""
- source: "Multi-Issue Bundling"
  responsibility: "Run shared upstream phases once for the bundle, name bundle plans, and track completion markers per issue."
  disposition: spine-runner-keeps
  action: "Keep bundle orchestration and plan-memory naming in the runtime; planner owns bundled plan content."
  verification_status: verified
  verified-against-sha: "50ee151ab33d45cceb7107923c2ae2e6101aa95e"
  verified-via-pr-sha: ""
- source: "Multi-Issue Bundling"
  responsibility: "Defer bundle-specific frame-spine semantics beyond #512 v1 single-issue spine behavior."
  disposition: defer
  action: "Revisit bundled frame-spine behavior when https://github.com/Grimblaz/agent-orchestra/issues/515 ships."
  revisit-trigger: "issue:#515"
  verification_status: unverified
  verified-against-sha: ""
  verified-via-pr-sha: ""
- source: "Hub Execution Workflow / Locate Plan & Context"
  responsibility: "Locate plans through session memory, GitHub issue comments, or structured escalation."
  disposition: spine-runner-keeps
  action: "Keep plan lookup and latest-comment selection in the runner entry sequence."
  verification_status: verified
  verified-against-sha: "50ee151ab33d45cceb7107923c2ae2e6101aa95e"
  verified-via-pr-sha: ""
- source: "Hub Execution Workflow / Locate Plan & Context"
  responsibility: "Locate or recreate design context from session memory, GitHub comments, or issue body fallback."
  disposition: spine-runner-keeps
  action: "Keep design-context lookup and fallback cache creation in session recovery handling."
  verification_status: verified
  verified-against-sha: "50ee151ab33d45cceb7107923c2ae2e6101aa95e"
  verified-via-pr-sha: ""
- source: "Hub Execution Workflow / Locate Plan & Context"
  responsibility: "Read supporting design, decision, research, and skill context when present."
  disposition: spine-runner-keeps
  action: "Keep read-only supporting-context discovery in the runtime before dispatch."
  verification_status: verified
  verified-against-sha: "50ee151ab33d45cceb7107923c2ae2e6101aa95e"
  verified-via-pr-sha: ""
- source: "Hub Execution Workflow / Locate Plan & Context"
  responsibility: "When no plan exists, create one through hub upstream execution or escalate outside hub mode."
  disposition: spine-runner-keeps
  action: "Keep no-plan branching in the runner; plan generation remains Issue-Planner-owned."
  verification_status: verified
  verified-against-sha: "50ee151ab33d45cceb7107923c2ae2e6101aa95e"
  verified-via-pr-sha: ""
- source: "Hub Execution Workflow / Locate Plan & Context / D12 Commit policy detection"
  responsibility: "Detect auto-commit policy once from consumer copilot-instructions and persist the flag for the session."
  disposition: spine-runner-keeps
  action: "Keep D12 commit-policy detection in plan-load initialization."
  verification_status: verified
  verified-against-sha: "50ee151ab33d45cceb7107923c2ae2e6101aa95e"
  verified-via-pr-sha: ""
- source: "Hub Execution Workflow / Determine Resume Point & Validate Plan"
  responsibility: "Resume from the first incomplete plan step based on session-memory annotations or branch-state inference."
  disposition: spine-runner-keeps
  action: "Keep step-resume scanning in the frame walker before dispatch."
  verification_status: verified
  verified-against-sha: "50ee151ab33d45cceb7107923c2ae2e6101aa95e"
  verified-via-pr-sha: ""
- source: "Hub Execution Workflow / Determine Resume Point & Validate Plan / D13 Step commit reconciliation"
  responsibility: "Reconcile auto-commit step history with session-memory DONE and DONE (uncommitted) annotations."
  disposition: spine-runner-keeps
  action: "Keep D13 session-memory/git reconciliation in resume handling; step commit execution itself delegates to skills/step-commit/SKILL.md."
  verification_status: verified
  verified-against-sha: "50ee151ab33d45cceb7107923c2ae2e6101aa95e"
  verified-via-pr-sha: ""
- source: "Hub Execution Workflow / Determine Resume Point & Validate Plan"
  responsibility: "Reality-check plan assumptions against current code before resuming."
  disposition: spine-runner-keeps
  action: "Keep plan-reality verification in the runtime before step execution."
  verification_status: verified
  verified-against-sha: "50ee151ab33d45cceb7107923c2ae2e6101aa95e"
  verified-via-pr-sha: ""
- source: "Hub Execution Workflow / Determine Resume Point & Validate Plan"
  responsibility: "Ensure migration-type plans start with an exhaustive repo scan."
  disposition: planner-should-absorb
  action: "Track absorption in https://github.com/Grimblaz/agent-orchestra/issues/591; move migration scan-step requirements into skills/plan-authoring/SKILL.md plan-style enforcement."
  verification_status: unverified
  verified-against-sha: ""
  verified-via-pr-sha: ""
- source: "Hub Execution Workflow / Determine Resume Point & Validate Plan / D10 Capacity check"
  responsibility: "Measure guidance complexity and block or override agent-prompt rule additions when targets exceed the soft ceiling."
  disposition: adapter-handles
  action: "Use skills/guidance-measurement/SKILL.md and skills/guidance-measurement/scripts/measure-guidance-complexity.ps1 for D10 capacity evidence."
  verification_status: verified
  verified-against-sha: "50ee151ab33d45cceb7107923c2ae2e6101aa95e"
  verified-via-pr-sha: ""
- source: "Hub Execution Workflow / Execute Each Step"
  responsibility: "Identify specialist agents and applicable skills for each step."
  disposition: adapter-handles
  action: "Use skills/routing-tables/SKILL.md and skills/routing-tables/assets/routing-config.json for specialist and skill mapping."
  verification_status: verified
  verified-against-sha: "50ee151ab33d45cceb7107923c2ae2e6101aa95e"
  verified-via-pr-sha: ""
- source: "Hub Execution Workflow / Execute Each Step"
  responsibility: "Build focused dispatch context from frame-spine, active slice, and depth-1 dependencies."
  disposition: spine-runner-keeps
  action: "Keep frame-slice lookup and context-budget assembly in Spine-Runner dispatch."
  verification_status: verified
  verified-against-sha: "50ee151ab33d45cceb7107923c2ae2e6101aa95e"
  verified-via-pr-sha: ""
- source: "Hub Execution Workflow / Execute Each Step"
  responsibility: "Accumulate dispatch-cost placeholder samples before PR creation and back-fill them after conformance or judgment."
  disposition: spine-runner-keeps
  action: "Keep dispatch-cost accumulator lifecycle with pipeline metrics runtime state."
  verification_status: verified
  verified-against-sha: "50ee151ab33d45cceb7107923c2ae2e6101aa95e"
  verified-via-pr-sha: ""
- source: "Hub Execution Workflow / Execute Each Step"
  responsibility: "Handle stale spine evidence, legacy plan shape, and focused-context budget fallbacks with visible metrics events."
  disposition: spine-runner-keeps
  action: "Keep spine fallback prompts and dispatch-fallback-events emission in the frame walker."
  verification_status: verified
  verified-against-sha: "50ee151ab33d45cceb7107923c2ae2e6101aa95e"
  verified-via-pr-sha: ""
- source: "Hub Execution Workflow / Execute Each Step"
  responsibility: "Prompt once for Copilot cost collection when the sentinel is absent and suppression is unset."
  disposition: spine-runner-keeps
  action: "Keep the prompt-once and suppression decision in conductor runtime; use skills/copilot-cost-collection/SKILL.md only for setup semantics after the runtime offers collection."
  verification_status: verified
  verified-against-sha: "50ee151ab33d45cceb7107923c2ae2e6101aa95e"
  verified-via-pr-sha: ""
- source: "Hub Execution Workflow / Execute Each Step"
  responsibility: "Announce the selected agent, call the specialist with focused instructions, and avoid sending the entire plan."
  disposition: spine-runner-keeps
  action: "Keep dispatch announcement and focused-prompt construction in the runner."
  verification_status: verified
  verified-against-sha: "50ee151ab33d45cceb7107923c2ae2e6101aa95e"
  verified-via-pr-sha: ""
- source: "Hub Execution Workflow / Execute Each Step"
  responsibility: "Spot-check specialist changes, perform goal checks, and re-delegate if output misses intent."
  disposition: spine-runner-keeps
  action: "Keep post-dispatch inspection and corrective re-delegation in orchestration."
  verification_status: verified
  verified-against-sha: "50ee151ab33d45cceb7107923c2ae2e6101aa95e"
  verified-via-pr-sha: ""
- source: "Hub Execution Workflow / Execute Each Step"
  responsibility: "Re-read design context at major phase boundaries and correct design drift before continuing."
  disposition: spine-runner-keeps
  action: "Keep design-alignment checkpoints in the runner before refactor, review, and CE Gate phases."
  verification_status: verified
  verified-against-sha: "50ee151ab33d45cceb7107923c2ae2e6101aa95e"
  verified-via-pr-sha: ""
- source: "Hub Execution Workflow / Execute Each Step"
  responsibility: "Perform per-step refactor cleanup after GREEN before the dedicated refactor phase."
  disposition: adapter-handles
  action: "Use skills/refactoring-methodology/SKILL.md for cleanup guardrails when per-step refactor work exceeds trivial edits."
  verification_status: verified
  verified-against-sha: "50ee151ab33d45cceb7107923c2ae2e6101aa95e"
  verified-via-pr-sha: ""
- source: "Hub Execution Workflow / Execute Each Step"
  responsibility: "Run incremental validation commands and project tests after each step."
  disposition: adapter-handles
  action: "Use skills/validation-methodology/SKILL.md and skills/terminal-hygiene/SKILL.md for staged validation and execution hygiene."
  verification_status: verified
  verified-against-sha: "50ee151ab33d45cceb7107923c2ae2e6101aa95e"
  verified-via-pr-sha: ""
- source: "Hub Execution Workflow / Execute Each Step"
  responsibility: "Enforce RC conformance after convergence gates and run one dedicated correction cycle when AC items diverge."
  disposition: spine-runner-keeps
  action: "Keep RC conformance evaluation and correction-cycle routing in the conductor runtime until an adapter exists."
  verification_status: verified
  verified-against-sha: "50ee151ab33d45cceb7107923c2ae2e6101aa95e"
  verified-via-pr-sha: ""
- source: "Hub Execution Workflow / Execute Each Step"
  responsibility: "Run the step commit protocol when auto_commit_enabled is true and annotate uncommitted success on failure."
  disposition: adapter-handles
  action: "Use skills/step-commit/SKILL.md for validated-step commit behavior."
  verification_status: verified
  verified-against-sha: "50ee151ab33d45cceb7107923c2ae2e6101aa95e"
  verified-via-pr-sha: ""
- source: "Hub Execution Workflow / Execute Each Step"
  responsibility: "Update session-memory plan progress checkpoints after quality checks pass."
  disposition: spine-runner-keeps
  action: "Keep SMC progress annotation in runtime state management after each validated step."
  verification_status: verified
  verified-against-sha: "50ee151ab33d45cceb7107923c2ae2e6101aa95e"
  verified-via-pr-sha: ""
- source: "Hub Execution Workflow / Create PR Step 4"
  responsibility: "Before PR creation, verify the full diff resolves the issue rather than merely executing all steps."
  disposition: spine-runner-keeps
  action: "Keep end-to-end issue-resolution review as the PR readiness gate."
  verification_status: verified
  verified-against-sha: "50ee151ab33d45cceb7107923c2ae2e6101aa95e"
  verified-via-pr-sha: ""
- source: "Hub Execution Workflow / Create PR Step 4"
  responsibility: "Enforce the Review Completion Gate before push or PR creation and re-enter missing review stages when needed."
  disposition: adapter-handles
  action: "Use skills/validation-methodology/references/review-reconciliation.md, skills/validation-methodology/references/review-state-persistence.md, and skills/validation-methodology/references/post-judgment-routing.md for review completion state."
  verification_status: verified
  verified-against-sha: "50ee151ab33d45cceb7107923c2ae2e6101aa95e"
  verified-via-pr-sha: ""
- source: "Hub Execution Workflow / Create PR Step 4"
  responsibility: "Run planned-scope and migration-completeness checks before proceeding."
  disposition: spine-runner-keeps
  action: "Keep PR-scope and migration scan evidence gathering in the final readiness gate."
  verification_status: verified
  verified-against-sha: "50ee151ab33d45cceb7107923c2ae2e6101aa95e"
  verified-via-pr-sha: ""
- source: "Hub Execution Workflow / Create PR Step 4"
  responsibility: "Delegate domain-based design-document creation or update to Doc-Keeper before pushing."
  disposition: adapter-handles
  action: "Use skills/documentation-finalization/SKILL.md for domain design doc selection, update, and stale-doc cleanup."
  verification_status: verified
  verified-against-sha: "50ee151ab33d45cceb7107923c2ae2e6101aa95e"
  verified-via-pr-sha: ""
- source: "Hub Execution Workflow / Create PR Step 4"
  responsibility: "Run the formatting gate on branch-changed files and note any formatting commit."
  disposition: adapter-handles
  action: "Use skills/pre-commit-formatting/SKILL.md for final markdown and whitespace formatting."
  verification_status: verified
  verified-against-sha: "50ee151ab33d45cceb7107923c2ae2e6101aa95e"
  verified-via-pr-sha: ""
- source: "Hub Execution Workflow / Create PR Step 4"
  responsibility: "Capture validation evidence, push the branch, create the PR, and include required PR body sections."
  disposition: spine-runner-keeps
  action: "Keep PR creation and required PR-body assembly in the conductor runtime."
  verification_status: verified
  verified-against-sha: "50ee151ab33d45cceb7107923c2ae2e6101aa95e"
  verified-via-pr-sha: ""
- source: "Hub Execution Workflow / Create PR Step 4"
  responsibility: "Run the warn-only frame credit ledger after PR creation."
  disposition: adapter-handles
  action: "Use skills/frame-credit-ledger/SKILL.md for post-PR credit-ledger observation."
  verification_status: verified
  verified-against-sha: "50ee151ab33d45cceb7107923c2ae2e6101aa95e"
  verified-via-pr-sha: ""
- source: "Hub Execution Workflow / Report Completion Step 5"
  responsibility: "Report work done, link the PR URL, and hand off to the user for review."
  disposition: spine-runner-keeps
  action: "Keep completion reporting coupled to a created PR URL or structured stop condition."
  verification_status: verified
  verified-against-sha: "50ee151ab33d45cceb7107923c2ae2e6101aa95e"
  verified-via-pr-sha: ""
- source: "Build-Test Orchestration"
  responsibility: "Follow the build-test protocol for execution mode, requirement contracts, convergence gates, triage routing, and post-issue checkpoints."
  disposition: adapter-handles
  action: "Use skills/parallel-execution/SKILL.md for build-test orchestration."
  verification_status: verified
  verified-against-sha: "50ee151ab33d45cceb7107923c2ae2e6101aa95e"
  verified-via-pr-sha: ""
- source: "Property-Based Testing (PBT) Rollout Policy"
  responsibility: "Use the PBT rollout policy when randomized invariant testing is relevant."
  disposition: adapter-handles
  action: "Use skills/property-based-testing/SKILL.md for property-based testing rollout guidance."
  verification_status: verified
  verified-against-sha: "50ee151ab33d45cceb7107923c2ae2e6101aa95e"
  verified-via-pr-sha: ""
- source: "Agent Selection table"
  responsibility: "Resolve specialist dispatch through routing-tables lookup and task-intent rules."
  disposition: adapter-handles
  action: "Use skills/routing-tables/SKILL.md and skills/routing-tables/assets/routing-config.json for specialist_dispatch."
  verification_status: verified
  verified-against-sha: "50ee151ab33d45cceb7107923c2ae2e6101aa95e"
  verified-via-pr-sha: ""
- source: "Agent Selection table"
  responsibility: "Choose native Explore for lightweight discovery and Research-Agent for deep persisted research."
  disposition: spine-runner-keeps
  action: "Keep Explore vs Research-Agent selection as a dispatch policy until routing-tables owns an equivalent selector."
  verification_status: verified
  verified-against-sha: "50ee151ab33d45cceb7107923c2ae2e6101aa95e"
  verified-via-pr-sha: ""
- source: "Agent Selection table"
  responsibility: "Require Doc-Keeper batch prompts to include per-file self-check instructions."
  disposition: spine-runner-keeps
  action: "Keep documentation batch self-check requirements in dispatch prompt construction."
  verification_status: verified
  verified-against-sha: "50ee151ab33d45cceb7107923c2ae2e6101aa95e"
  verified-via-pr-sha: ""
- source: "Agent Selection table"
  responsibility: "Invoke Senior Engineer from frame-slice executor metadata rather than ad hoc prose routing."
  disposition: spine-runner-keeps
  action: "Keep executor resolution from frame-slice metadata in Spine-Runner."
  verification_status: verified
  verified-against-sha: "50ee151ab33d45cceb7107923c2ae2e6101aa95e"
  verified-via-pr-sha: "79381bc7e413fd1e658834fbe4fd6d4430836162"
  replay-pr: "https://github.com/Grimblaz/agent-orchestra/pull/558"
  replay-evidence:
    - "https://github.com/Grimblaz/agent-orchestra/pull/558#issuecomment-4425506916"
    - "https://github.com/Grimblaz/agent-orchestra/pull/558#issuecomment-4426278362"
  replay-note: "Issue #555 required minimal Spine-Runner frame walking, planner-named adapter resolution, one resolved adapter per slice, and port-locus evidence. PR #558 includes Spine-Runner, v2 frame-spine adapter paths, /spine-run, terminal-step credits, CE Gate evidence, and frame ledger output; review status is evidenced through PR body plus GitHub review intake/fix comments because no standalone judge-rulings issue comment was found."
- source: "Review Reconciliation Loop (Mandatory)"
  responsibility: "Load review reconciliation, review-state persistence, post-judgment routing, and express-lane references."
  disposition: adapter-handles
  action: "Use skills/validation-methodology/references/review-reconciliation.md, skills/validation-methodology/references/review-state-persistence.md, skills/validation-methodology/references/post-judgment-routing.md, and skills/code-review-intake/references/express-lane.md."
  verification_status: verified
  verified-against-sha: "50ee151ab33d45cceb7107923c2ae2e6101aa95e"
  verified-via-pr-sha: ""
- source: "Review Reconciliation Loop (Mandatory)"
  responsibility: "Own review-mode entry, express-lane boundaries, post-judgment routing, calibration side effects, and CE Gate sequencing."
  disposition: spine-runner-keeps
  action: "Keep review-loop orchestration and GitHub-trigger routing in the runtime shell."
  verification_status: verified
  verified-against-sha: "50ee151ab33d45cceb7107923c2ae2e6101aa95e"
  verified-via-pr-sha: ""
- source: "Skill Mapping"
  responsibility: "Use routing-tables skill_mapping entries when naming reusable skills in specialist prompts."
  disposition: adapter-handles
  action: "Use skills/routing-tables/SKILL.md and skills/routing-tables/assets/routing-config.json for skill_mapping."
  verification_status: verified
  verified-against-sha: "50ee151ab33d45cceb7107923c2ae2e6101aa95e"
  verified-via-pr-sha: ""
- source: "Skill Mapping"
  responsibility: "Name skill-specific instructions for implementation, review, planning, documentation, refactoring, debugging, testing, and UI work."
  disposition: adapter-handles
  action: "Use the relevant skill paths named by the body, including skills/implementation-discipline/SKILL.md, skills/software-architecture/SKILL.md, skills/adversarial-review/SKILL.md, skills/review-judgment/SKILL.md, skills/plan-authoring/SKILL.md, skills/design-exploration/SKILL.md, skills/customer-experience/SKILL.md, skills/documentation-finalization/SKILL.md, skills/refactoring-methodology/SKILL.md, skills/systematic-debugging/SKILL.md, skills/test-driven-development/SKILL.md, skills/ui-testing/SKILL.md, and skills/frontend-design/SKILL.md."
  verification_status: verified
  verified-against-sha: "50ee151ab33d45cceb7107923c2ae2e6101aa95e"
  verified-via-pr-sha: ""
- source: "Validation Ladder (Mandatory) / Validation Ladder tiers"
  responsibility: "Use the graduated four-tier validation ladder and Failure Triage Rule."
  disposition: adapter-handles
  action: "Use skills/validation-methodology/SKILL.md for validation ladder tiers and failure triage."
  verification_status: verified
  verified-against-sha: "50ee151ab33d45cceb7107923c2ae2e6101aa95e"
  verified-via-pr-sha: ""
- source: "Validation Ladder (Mandatory) / Validation Ladder tiers"
  responsibility: "Keep incremental validation timing, post-fix review entry, CE Gate sequencing, and PR-gate ownership around the ladder."
  disposition: spine-runner-keeps
  action: "Keep validation orchestration around adapter-provided tier methodology in the frame runner."
  verification_status: verified
  verified-against-sha: "50ee151ab33d45cceb7107923c2ae2e6101aa95e"
  verified-via-pr-sha: ""
- source: "CE Gate orchestration / Customer Experience Gate (CE Gate)"
  responsibility: "Run CE Gate after post-fix targeted prosecution or review judgment and before PR creation."
  disposition: spine-runner-keeps
  action: "Keep CE Gate placement in Tier 4 orchestration."
  verification_status: verified
  verified-against-sha: "50ee151ab33d45cceb7107923c2ae2e6101aa95e"
  verified-via-pr-sha: ""
- source: "CE Gate orchestration / Customer Experience Gate (CE Gate)"
  responsibility: "Load CE orchestration and defect-response references."
  disposition: adapter-handles
  action: "Use skills/customer-experience/references/orchestration-protocol.md and skills/customer-experience/references/defect-response.md for CE Gate protocol."
  verification_status: verified
  verified-against-sha: "50ee151ab33d45cceb7107923c2ae2e6101aa95e"
  verified-via-pr-sha: ""
- source: "BDD pre-flight / Customer Experience Gate (CE Gate)"
  responsibility: "Extract active scenario IDs from the issue body and run the BDD pre-flight missing-coverage recovery policy."
  disposition: spine-runner-keeps
  action: "Keep BDD pre-flight extraction and recovery option labels in CE Gate orchestration; future adapter verification may cite skills/bdd-scenarios/SKILL.md if ownership moves."
  verification_status: verified
  verified-against-sha: "50ee151ab33d45cceb7107923c2ae2e6101aa95e"
  verified-via-pr-sha: ""
- source: "CE Gate orchestration / Customer Experience Gate (CE Gate)"
  responsibility: "Dispatch recognized Phase 2 BDD runners, delegate manual scenarios to Experience-Owner, and fall back to Phase 1 on runner pre-check failure."
  disposition: spine-runner-keeps
  action: "Keep runner-dispatch branching in CE Gate orchestration until a dedicated CE adapter owns it."
  verification_status: verified
  verified-against-sha: "50ee151ab33d45cceb7107923c2ae2e6101aa95e"
  verified-via-pr-sha: ""
- source: "CE Gate orchestration / Customer Experience Gate (CE Gate)"
  responsibility: "Emit the PR-body per-scenario coverage table and CE Gate result marker."
  disposition: spine-runner-keeps
  action: "Keep CE Gate evidence formatting and result marker emission in PR-body assembly."
  verification_status: verified
  verified-against-sha: "50ee151ab33d45cceb7107923c2ae2e6101aa95e"
  verified-via-pr-sha: ""
- source: "CE Gate orchestration / Customer Experience Gate (CE Gate)"
  responsibility: "Apply prevention-analysis before creating systemic follow-up issues from CE Gate Track 2."
  disposition: adapter-handles
  action: "Use skills/safe-operations/SKILL.md prevention-analysis advisory before CE systemic issue creation."
  verification_status: verified
  verified-against-sha: "50ee151ab33d45cceb7107923c2ae2e6101aa95e"
  verified-via-pr-sha: ""
- source: "PR Body Pipeline Metrics"
  responsibility: "Require PR bodies to include a Pipeline Metrics section containing the pipeline-metrics block."
  disposition: spine-runner-keeps
  action: "Keep metrics-block presence as a PR body assembly invariant."
  verification_status: verified
  verified-against-sha: "50ee151ab33d45cceb7107923c2ae2e6101aa95e"
  verified-via-pr-sha: ""
- source: "Pipeline metrics emission / Pipeline Metrics"
  responsibility: "Emit Pipeline Metrics at PR creation using canonical metrics schema, verdict mapping, and findings construction references."
  disposition: adapter-handles
  action: "Use skills/calibration-pipeline/references/metrics-schema.md, skills/calibration-pipeline/references/verdict-mapping.md, and skills/calibration-pipeline/references/findings-construction.md."
  verification_status: verified
  verified-against-sha: "50ee151ab33d45cceb7107923c2ae2e6101aa95e"
  verified-via-pr-sha: ""
- source: "Pipeline metrics emission / Pipeline Metrics"
  responsibility: "Construct release-hygiene and CE Gate S2 synthetic-PR credit rows from the release-hygiene reference."
  disposition: adapter-handles
  action: "Use skills/calibration-pipeline/references/release-hygiene-credit-emission.md for v4 release-hygiene credit row construction."
  verification_status: verified
  verified-against-sha: "50ee151ab33d45cceb7107923c2ae2e6101aa95e"
  verified-via-pr-sha: ""
- source: "Pipeline metrics emission / Pipeline Metrics"
  responsibility: "Remove legacy v3 pipeline-metrics fallback at v2.9.0 after pre-v4 back-catalog backfill."
  disposition: defer
  action: "Issue #441 completed the pre-v4 back-catalog backfill evidence; remove the legacy v3 fallback as the remaining cleanup tracked by https://github.com/Grimblaz/agent-orchestra/issues/593."
  revisit-trigger: "issue:#593"
  verification_status: unverified
  verified-against-sha: ""
  verified-via-pr-sha: ""
- source: "Pipeline metrics emission / Pipeline Metrics"
  responsibility: "Construct review credit rows from judge-rulings blocks and review-credit rules."
  disposition: adapter-handles
  action: "Use skills/calibration-pipeline/references/review-credit-emission.md for v4 review credit row construction."
  verification_status: verified
  verified-against-sha: "50ee151ab33d45cceb7107923c2ae2e6101aa95e"
  verified-via-pr-sha: "cb13f420e27a54e30a06cf202a2c2905ebadca92"
  replay-pr: "https://github.com/Grimblaz/agent-orchestra/pull/504"
  replay-evidence:
    - "https://github.com/Grimblaz/agent-orchestra/pull/504#issuecomment-4364628241"
  replay-note: "Issue #441 required Code-Conductor to construct v4 review credit rows from judge-rulings comments. PR #504's body includes v4 pipeline metrics with a passed review credit row pointing to the judge ruling, the review-judge-produced-504 sentinel is present, and post-review fixes resolved all required findings."
- source: "Pipeline metrics emission / Pipeline Metrics"
  responsibility: "Flush dispatch-cost samples into initial PR-body metrics and later update live PR-body targeted samples."
  disposition: spine-runner-keeps
  action: "Keep dispatch-cost sample flush and targeted back-fill in metrics emission orchestration."
  verification_status: verified
  verified-against-sha: "50ee151ab33d45cceb7107923c2ae2e6101aa95e"
  verified-via-pr-sha: ""
- source: "Pipeline-Entry Credit Harvest (SMC-17)"
  responsibility: "Harvest deferred pipeline-entry credit markers from the linked issue before emitting credits."
  disposition: adapter-handles
  action: "Use skills/frame-credit-emission/SKILL.md with .github/scripts/lib/frame-credit-ledger-core.ps1 Invoke-CreditInputHarvest for SMC-17 credit harvest."
  verification_status: verified
  verified-against-sha: "50ee151ab33d45cceb7107923c2ae2e6101aa95e"
  verified-via-pr-sha: ""
- source: "Pipeline-Entry Credit Harvest (SMC-17)"
  responsibility: "Merge harvested credit rows into credits[] with per-port additive deduplication."
  disposition: adapter-handles
  action: "Use skills/frame-credit-emission/SKILL.md for credit-row merge semantics and additive-merge rules."
  verification_status: verified
  verified-against-sha: "50ee151ab33d45cceb7107923c2ae2e6101aa95e"
  verified-via-pr-sha: ""
- source: "Deferred Port Credit Rows"
  responsibility: "Emit deferred credit rows for ports whose frame/ports YAML declares trigger-status: deferred."
  disposition: adapter-handles
  action: "Use skills/frame-credit-emission/SKILL.md and .github/scripts/lib/frame-credit-ledger-core.ps1 Build-DeferredPortCreditRow."
  verification_status: verified
  verified-against-sha: "50ee151ab33d45cceb7107923c2ae2e6101aa95e"
  verified-via-pr-sha: ""
- source: "Deferred Port Credit Rows"
  responsibility: "Emit process-review trigger-absent credit when CE Gate found no defects, or skipped credit when CE data is unavailable."
  disposition: adapter-handles
  action: "Use skills/frame-credit-emission/SKILL.md and .github/scripts/lib/frame-credit-ledger-core.ps1 Build-ProcessReviewCreditRow."
  verification_status: verified
  verified-against-sha: "50ee151ab33d45cceb7107923c2ae2e6101aa95e"
  verified-via-pr-sha: ""
- source: "Post-PR Credit Row (D10 category 3)"
  responsibility: "After post-merge cleanup completes, emit the post-pr credit row from structured checklist outcomes."
  disposition: adapter-handles
  action: "Use skills/post-pr-review/SKILL.md and skills/frame-credit-emission/SKILL.md for post-pr outcome and credit-row emission."
  verification_status: verified
  verified-against-sha: "50ee151ab33d45cceb7107923c2ae2e6101aa95e"
  verified-via-pr-sha: ""
- source: "Refactoring Phase mandate / Refactoring Phase is MANDATORY"
  responsibility: "Always call Refactor-Specialist after Code-Smith completes."
  disposition: adapter-handles
  action: "Use skills/refactoring-methodology/SKILL.md Conductor Integration for mandatory refactor handoff and scope guardrails."
  verification_status: verified
  verified-against-sha: "50ee151ab33d45cceb7107923c2ae2e6101aa95e"
  verified-via-pr-sha: ""
- source: "Tactical Adaptation"
  responsibility: "Adapt without asking for renamed files, redundant steps, efficient step reordering, or minor missing subtasks."
  disposition: spine-runner-keeps
  action: "Keep bounded tactical adaptation in the runner so execution follows reality while preserving scope."
  verification_status: verified
  verified-against-sha: "50ee151ab33d45cceb7107923c2ae2e6101aa95e"
  verified-via-pr-sha: ""
- source: "Tactical Adaptation"
  responsibility: "Escalate invalid premises, wrong scope, or significant unaddressed design questions via askQuestions."
  disposition: spine-runner-keeps
  action: "Keep authority-bound tactical escalation in orchestration with recommended options."
  verification_status: verified
  verified-against-sha: "50ee151ab33d45cceb7107923c2ae2e6101aa95e"
  verified-via-pr-sha: ""
- source: "Subagent Call Resilience (R5)"
  responsibility: "Classify subagent-call failures, apply retry/backoff, and route defer-vs-skip outcomes."
  disposition: adapter-handles
  action: "Use skills/parallel-execution/references/error-handling.md for R5 subagent-call failure handling."
  verification_status: verified
  verified-against-sha: "50ee151ab33d45cceb7107923c2ae2e6101aa95e"
  verified-via-pr-sha: ""
- source: "Error Handling"
  responsibility: "Apply failure triage, escalation thresholds, and recovery routing for non-rate-limit workflow failures after diagnosis."
  disposition: adapter-handles
  action: "Use skills/parallel-execution/references/error-handling.md for general workflow failure handling."
  verification_status: verified
  verified-against-sha: "50ee151ab33d45cceb7107923c2ae2e6101aa95e"
  verified-via-pr-sha: ""
- source: "Context Management for Long Sessions"
  responsibility: "Proactively compact at phase boundaries and rely on session memory or issue comments after compaction."
  disposition: spine-runner-keeps
  action: "Keep compaction timing and state-survival assumptions in long-session orchestration."
  verification_status: verified
  verified-against-sha: "50ee151ab33d45cceb7107923c2ae2e6101aa95e"
  verified-via-pr-sha: ""
- source: "Context Management for Long Sessions"
  responsibility: "Generate /compact instructions with real issue, step, branch, design intent, and open-item values."
  disposition: spine-runner-keeps
  action: "Keep concrete compaction-summary construction in the runtime shell."
  verification_status: verified
  verified-against-sha: "50ee151ab33d45cceb7107923c2ae2e6101aa95e"
  verified-via-pr-sha: ""
- source: "Handoff to User"
  responsibility: "Operate autonomously toward merge-ready and pause only through askQuestions when user judgment is required."
  disposition: spine-runner-keeps
  action: "Keep user-handoff policy coupled to PR creation and structured authority-bound pauses."
  verification_status: verified
  verified-against-sha: "50ee151ab33d45cceb7107923c2ae2e6101aa95e"
  verified-via-pr-sha: ""
- source: "Handoff to User"
  responsibility: "Use explicit escalation patterns for design decisions, PR readiness, clarification, and workflow completion."
  disposition: spine-runner-keeps
  action: "Keep escalation prompt construction in the conductor runtime."
  verification_status: verified
  verified-against-sha: "50ee151ab33d45cceb7107923c2ae2e6101aa95e"
  verified-via-pr-sha: ""
- source: "Best Practices"
  responsibility: "Never present Code-Critic feedback without Code-Review-Response judgment."
  disposition: spine-runner-keeps
  action: "Keep review-output sequencing in review-loop orchestration."
  verification_status: verified
  verified-against-sha: "50ee151ab33d45cceb7107923c2ae2e6101aa95e"
  verified-via-pr-sha: ""
- source: "Best Practices"
  responsibility: "Avoid sending entire plans or design docs to subagents, and always announce the agent before dispatch."
  disposition: spine-runner-keeps
  action: "Keep prompt-size discipline and dispatch announcement in the frame runner."
  verification_status: verified
  verified-against-sha: "50ee151ab33d45cceb7107923c2ae2e6101aa95e"
  verified-via-pr-sha: ""
```

## Real-run risk-selection rationale

### Chosen rows

The selected `adapter-handles` row covers review-credit construction because mistakes there would make durable review evidence appear present while pointing at the wrong judge-rulings source, credit rule, or verdict state. PR #504 / issue #441 is a real merged run with v4 pipeline metrics, a passed `review` credit row tied to the judge ruling, the `<!-- review-judge-produced-504 -->` sentinel, and completed post-review fixes.

The selected `spine-runner-keeps` row covers Senior Engineer dispatch from frame-slice executor metadata because it is the clearest proof point that Spine-Runner remains a frame walker instead of falling back to generic prose routing. PR #558 / issue #555 exercised v2 frame-spine adapter paths, `/spine-run`, terminal-step credits, CE Gate evidence, and frame ledger output for the minimal runner path.

### Alternatives considered

Other `adapter-handles` candidates included release-hygiene credit rows, frame credit harvest, deferred port credit rows, validation ladder guidance, and frame credit ledger emission. They were useful but less risky for this slice because their failure modes are either narrower or already pinned to explicit helper scripts and references.

Other `spine-runner-keeps` candidates included focused dispatch context, continuation policy, PR-body metrics-block presence, CE Gate placement, and dispatch announcement. They remain important switch-readiness evidence, but they do not stress the migration boundary as directly as executor-metadata dispatch.

### Migration-risk heuristic

Choose rows where ownership mistakes would hide durable workflow evidence or collapse Spine-Runner frame-walking into generic adapter handling.
