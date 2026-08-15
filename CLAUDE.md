# Agent Orchestra — Claude Code Guide

> ⚠️ **GitHub Copilot / VS Code support is frozen (no fixes) and retiring after 2026-08-31.**
> Claude Code is the supported platform. See [Documents/Design/copilot-deprecation.md](Documents/Design/copilot-deprecation.md).

Agent Orchestra is a multi-agent workflow system built for Claude Code.

## Quick start

Install the plugin from the marketplace if you have not already. Run this inside Claude Code (not a system shell):

```text
/plugin install agent-orchestra@agent-orchestra
```

The plugin exposes the upstream pipeline, the review surface, the `/orchestrate` entry point, and a library of shared skills. Claude Code discovers them automatically once the plugin is installed.

### Project references

`/setup-references` helps maintainers initialize, generate, validate, and undo Agent Orchestra project-reference sidecars and indexes. Project references are optional, non-blocking discoverability aids for long-lived project docs: sidecars name when a document should load, `.references/index.json` records the generated lookup surface, and citations use `[ref:{name}](target_path)`. The authoritative schema, content-trust rules, and hard caps live in [skills/project-references/SKILL.md](skills/project-references/SKILL.md); compact examples live in [examples/project-references](examples/project-references).

### Path resolution for downstream consumers

Consumer repositories are zero-config after install: Claude Code loads the agent bodies and skills from the installed plugin cache, so the working repository does not need a local `agents/` directory.

See [`Documents/Design/hub-artifact-paths-audit.md`](Documents/Design/hub-artifact-paths-audit.md) for the full hub artifact path catalog.

Related: see the [Releases](#releases) section for cache invalidation behavior and the audit doc's [How to Detect Staleness](Documents/Design/hub-artifact-paths-audit.md#how-to-detect-staleness) section for drift detection.

See also: [CUSTOMIZATION.md > Script portability for plugin users](CUSTOMIZATION.md#script-portability-for-plugin-users).

## Intent Routing

Source of truth: `skills/routing-tables/assets/routing-config.json` anchors natural-language routing in `nl_intent_routing`. Routing detection runs only on top-level user messages outside an active slash-command turn and outside subagent dispatches, and only after the session-startup run-once marker is recorded. Activation order, confirmation phrasing, disambiguation, and no-match handling: [skills/routing-tables/SKILL.md](skills/routing-tables/SKILL.md).

`/raw`, `just answer normally`, `don't run the pipeline`, `raw mode`, and `skip routing` activate within-conversation raw mode only: no persistence file, no SMC row, and new conversations start routing-active. Any user-typed slash command clears raw mode. Acknowledge with: `Raw mode active for this conversation — natural-language requests will not be routed. Any explicit slash command you type clears raw mode.`

For commands with explicit `model:` frontmatter (`/orchestrate`, `/code-conductor`, `/review-github`, `/goal-run`), emit `Please run /X to continue` and stop; do not inline-emulate.

## Upstream pipeline

**For standalone work, the expected route is the open-for-work entrance, not this pipeline** (#957, owner decision 2026-07-28): one conversation takes a filed issue to a lawful brief (routine arm) or continues into design (novel arm) — doctrine in [Documents/Design/open-for-work.md](Documents/Design/open-for-work.md). The three-phase pipeline below is reached by **explicitly requesting it** (`/experience` or `/design`) and remains fully lawful. The entrance is the explicit command **`/open {issue}`**, which runs the flow inline from the methodology in [skills/open-for-work/SKILL.md](skills/open-for-work/SKILL.md); there is deliberately no natural-language routing intent for it. Three agents cover the pipeline's journey from an issue on the board to an implementation-ready plan. They call each other through durable GitHub-issue markers so a session can span multiple conversations. *(Cross-tool handoff between Copilot and Claude Code was supported; Copilot is now frozen — see Documents/Design/copilot-deprecation.md.)*

1. **Experience-Owner** — frames the work in customer language. Optionally opens with the **worth-it check** (bet / falsifier / alternative — recommends Proceed-full, Proceed-lite, Shrink, Park, or Decline; advisory only, skippable with `frame it`). Writes the problem statement, user journeys, scenarios, and surface/readiness assessment into the issue body. Activated with `/experience` or via the subagent name.
2. **Solution-Designer** — runs technical design exploration and the 3-pass non-blocking design challenge. Updates the issue body with decisions, acceptance criteria, and rejected alternatives. Activated with `/design` or via the subagent name.
3. **Issue-Planner** — produces the implementation plan with CE Gate (Customer Experience Gate) coverage and the full adversarial review pipeline (prosecution × 3 → defense → judge). Persists the approved plan as a GitHub issue comment with a `<!-- plan-issue-{ID} -->` marker per `SMC-01` (Session Memory Contract marker). Activated with `/plan` or via the subagent name.

Each agent reads a shared tool-agnostic body from `agents/*.agent.md` and follows the named skills for methodology. Claude-specific tool bindings (subagent dispatch, `gh` CLI for GitHub work) are documented in each skill's `platforms/claude.md`.

All three upstream agents share a common opening behavior — implemented in `skills/upstream-onboarding/SKILL.md`. When a user-invocable agent receives a request referencing an existing GitHub issue, it loads `upstream-onboarding` and renders a scaled context brief (summarizing the issue, scope tier, inherited decisions, and any blocking questions) and runs a standards check on work inherited from the prior phase. When the standards check finds a concern, the agent cites the violated standard by anchor (skill path + rule name), quotes the offending text, and presents a corrective approach with a strong recommendation. The standard brief and standards check are skipped on same-agent resumes (when the most recent upstream marker already belongs to the active agent's own role), but a **resume-variant orientation snapshot** is rendered inline (reference issue #633). When no issue exists yet (greenfield invocation), each agent synthesizes a brief from the user's prompt with all fields marked `(proposed)` and prompts for issue creation per its GitHub Setup step; the standards check is skipped until a real issue is established.

## Orchestration

- `/orchestrate` runs Code-Conductor inline in the parent conversation for the full pipeline from smart resume and plan handoff through implementation, validation, CE Gate, and PR readiness.
- `/spine-run` runs Spine-Runner as the minimal frame-walking conductor once a v2 plan exists.
- `/goal-run {issue}` launches or resumes the unattended vendor-goal-loop harness (Arm I) for a single issue carrying an approved goal-contract plan — one command is both launcher and resumer, and any non-happy path produces a typed halt report instead of an in-conversation question. See [HOW-IT-WORKS.md § Goal-run: the unattended pipeline](HOW-IT-WORKS.md#3-goal-run-the-unattended-pipeline) and [skills/goal-run/SKILL.md](skills/goal-run/SKILL.md).

For paused Code-Conductor work, `/orchestrate` is also the Claude resume entry point. The shared workflow still uses `/implement` language in Copilot-specific paths, but Claude does not ship a `/implement` command.

The Claude `code-conductor` shell follows the thin-shell convention: it loads the shared `agents/Code-Conductor.agent.md` body and relies on composite skills for the extracted orchestration contracts, so Copilot and Claude stay aligned on one source of truth.

## Review pipeline

The `orchestra-review-*` command namespace provides Claude-native adversarial review:

- `/orchestra:review` runs the canonical prosecution → defense → judge pipeline.
- `/orchestra:review-lite` runs the small-change variant with one compact prosecution pass before defense and judge.
- `/orchestra:review-prosecute`, `/orchestra:review-defend`, and `/orchestra:review-judge` let power users rerun individual stages.

The environment handshake is required for every `orchestra-review-*` command except `/orchestra:review-judge`, where it is optional; the per-command table is in [skills/routing-tables/SKILL.md](skills/routing-tables/SKILL.md) § Handshake disposition by command.

The judge result is designed for same-comment persistence: the Markdown score summary and the `<!-- judge-rulings ... -->` YAML block travel together in one PR comment so Copilot and Claude Code can consume the same durable artifact. The `<!-- review-judge-produced-{PR} -->` sentinel is written as a separate PR comment before the judge-rulings comment. The legacy `<!-- code-review-complete-{PR} -->` marker was retired in issue #441 Step 11; Code-Conductor reads `credits[]` from the PR-body pipeline-metrics block instead.

**Review-pipeline equivalence**: `/review-github` provides a deterministic entry point for GitHub review intake and proxy prosecution. It resolves the target PR (from arguments or via `gh pr view`), then routes through Code-Conductor's GitHub intake path and proxy prosecution flow, equivalent to prose triggers like `github review`, `review github`, or `cr review`. This command ensures explicit GitHub-review mode without requiring prose-based classification.

**When to use which**: `/orchestra:review` and `/orchestra:review-lite` run adversarial prosecution → defense → judge on local code changes and return verdicts — no fix dispatch. `/review-github` ingests an existing GitHub PR review and runs proxy prosecution through Code-Conductor, which then dispatches fixes. Use `/orchestra:review*` for code quality verdict; use `/review-github` when you have a GitHub review to reconcile and want Conductor to handle the response.

**Response loop**: `/review-github` completes the full response loop — it applies accepted fixes, commits them, and pushes to the existing PR branch (or surfaces a loud not-pushed reason). The terminal step fires `skills/persist-changes/SKILL.md`. See `skills/code-review-intake/SKILL.md § Response Loop Completion` for the step sequence and `skills/persist-changes/SKILL.md` for the executor contract.

## Cross-tool handoffs

Handoffs between phases use durable GitHub issue comments rather than session-local state; markers live on the issue so work resumes across sessions without losing context. *(Cross-tool Copilot↔Claude handoff was supported; Copilot is now frozen.)* Full catalog: [skills/session-memory-contract/references/handoff-markers.md](skills/session-memory-contract/references/handoff-markers.md). Row-level survival semantics: [skills/session-memory-contract/SKILL.md](skills/session-memory-contract/SKILL.md). Persistence rationale: [Documents/Design/session-memory-contract.md](Documents/Design/session-memory-contract.md).

## Session startup

When a session begins, the plugin's `SessionStart` hook runs the cleanup detector and injects any findings into the agent's first turn. The `session-startup` skill describes how the agent handles that injected context, preserves the run-once marker, and reports current branch, tracking file, sibling worktree, orphan branch, fail-open, and opt-in cleanup behavior. Current-worktree cleanup commands stay as inline manual guidance outside the fenced block; sibling and orphan cleanup — including worktree removal and branch deletion — is passed as parameters to a single composite `pwsh ... post-merge-cleanup.ps1 -SiblingWorktrees @(...) -OrphanBranches @(...)` invocation, so confirming cleanup triggers exactly one permission prompt rather than one per branch. Manual detector runs remain available after the automatic check fires. See the `### Permission allowlist (recommended)` subsection in the session-startup skill for the opt-in `.claude/settings.json` allowlist entries that suppress that prompt entirely.

## Releases

Claude Code keys its plugin cache by the `version` declared in `.claude-plugin/plugin.json`. If an entry-point file changes without a version bump, same-version installs keep serving the older cached snapshot even though the repo changed.

To prevent that, agent-assisted maintainer flows now route entry-point edits through the `plugin-release-hygiene` skill. Claude uses the plugin-distributed `PostToolUse` hook and Copilot uses the root `hooks.json` hook; both follow the same shared release-hygiene guidance. Per `SMC-12`, the silence decision is `session_id`-scoped for Claude when available and branch-scoped for Copilot, so it is shared across tools only when both resolve the same state key.

The `session-startup` skill also owns a Claude-only active-assist drift check. When the installed `agent-orchestra@agent-orchestra` version is behind the resolved marketplace version, the startup pass runs `claude plugin update`, waits for the install to complete (success or announced failure), and only then presents the restart-vs-continue choice. The install-then-prompt ordering is enforced by the explicit 6-step procedure in Step 7b of the skill.

### For maintainers

The supported Claude plugin CLI surface is `claude plugin list`, `claude plugin install <plugin@marketplace>`, `claude plugin uninstall <plugin@marketplace>`, `claude plugin update <plugin@marketplace>`, `claude plugin marketplace list`, `claude plugin marketplace add <source>`, `claude plugin marketplace remove <name>`, and `claude plugin marketplace update` — cataloged with usage notes in [README.md § For maintainers](README.md#for-maintainers) and [skills/plugin-release-hygiene/SKILL.md](skills/plugin-release-hygiene/SKILL.md).

## Quality-first, shift-left

Quality is the first constraint — ahead of speed and token cost; when they conflict, the methodology checkpoint wins (hence engagement gates and adversarial review are non-overridable by pacing directives). We shift defects **left**: the earlier in the pipeline (experience → design → plan → implementation) a defect is caught, the cheaper it is to fix, so every phase and review stage exists to catch a class before it reaches the next. Run the full methodology now — do not pre-emptively skip a stage because it "probably won't find anything."

We remove later checks **only with evidence, never on a cost argument**: a stage earns relaxation only when its *irreducible-catch rate* (defects catchable **only** at that stage) trends to ~0 over a large-enough sample. The instrument is the **phase-containment ledger** — the per-finding record of where a defect was introduced, the earliest phase it was catchable, and where it was caught ([Documents/Design/phase-containment-ledger.md](Documents/Design/phase-containment-ledger.md)); governance lives in umbrella #761. So annotate every sustained finding, and retire later steps once they demonstrably catch nothing new.

## What a finding turns into — filing is the exception

A review that finds things is working as intended. Coverage-first stands, and nothing here relaxes it: **this section governs a finding's destination, never whether to look for it.** What is not working is the default destination. Measured 2026-08-15: **324 open issues against 395 ever closed**, every month since March opening roughly 1.7–2× what it closed, and **40% of the open set untouched for 90 days or more**. Those were filed and then nothing happened — the filing cost its write-up, a slice of attention at every triage since, and returned nothing.

**The default is fix it, or drop it with a one-line reason. Filing is the exception and has to earn itself.**

**Eligibility to defer is not a decision to file.** `skills/safe-operations/SKILL.md` § Moment 2 / Moment 3 and `Test-DeferralCriteria.ps1` decide whether a finding is *eligible* for deferral, and the AC cross-check still force-accepts anything mapping to an acceptance criterion. Eligibility is necessary, not sufficient. Every eligible finding must then pass:

- **The pickup test.** If an afternoon opened up tomorrow, would this actually get picked up? When the honest answer is no, it is not a backlog item — it is something already decided against. Drop it, say so in one line, and move on. An issue nobody will pick up is worse than no issue, because it must also be re-read at every triage from now on.

A finding that is true but fails the pickup test has two lawful homes, and the tracker is neither:

1. **Fix it in the PR that found it.** The bar for "now" is lower than it feels: when fixing costs less than writing the issue would, filing was always the more expensive option. A run that absorbs its own residue leaves an acceptable resting state; one that sheds issues has moved the cost rather than paid it.
2. **Turn it into a guard.** If it genuinely must not be lost, encode it where it fires at the moment it becomes relevant — a test, a standing check, an `in_file_pins` row, a lens with its exhibit, a comment at the site. This is the half with the leverage: **a guard fires when the condition recurs; an issue fires never.** Prefer it especially for "remember that X is true" findings, which are most of what gets filed and none of what a tracker is good at. This repository already carries that machinery; route residue into it rather than alongside it.

**An agent proposing a follow-up states, per item, why *both* other homes were rejected** — why it cannot be fixed now, and why no guard can hold it. A proposal answering neither has not finished its analysis, and the Filing Approval Gate (`safe-operations` § 2e) should return it rather than present it.

Two failure modes this is aimed at, both of which read as diligence: filing rather than fixing, because filing feels like the responsible middle between scope creep and sweeping it away; and filing rather than dropping, because dropping feels like losing information. Deferral dressed as diligence is still deferral, and it is the mechanism by which one unit of work becomes two or three.

## What a finished run is true of

Five properties, scoped to the **act** of a run declaring itself done — not to a lane, and not to every run. How a run makes each one true stays its own choice; that its completion account exists, outlives the session, and carries a review assertion that would read false had no review run, does not. Depth, the account's own shape, and the evidence obligations: [skills/verification-before-completion/SKILL.md](skills/verification-before-completion/SKILL.md).

1. **The review is accounted for.** Every finding the adversarial review produced traces to an outcome that survived the judge — a fix commit, or a dismissal with its reason.
2. **A review that ran and found nothing says so, in words that would be false if it had not run.** Silence is never readable as examined-and-clean. This is what stops property 1 being vacuously true over an empty finding set: a run that dispatched no review produces no findings, so it satisfies property 1 by doing nothing.
3. **The suite's state is stated differentially** — what this change added, against a named baseline commit **that predates the change** — **and, separately, pre-existing failures are named and routed** rather than blocking the work or vanishing from the account. Two obligations, not one, so a run that added a failure cannot read a single clause as broadly satisfied. The baseline may never be the run's own post-change commit; that reading satisfies every clause while checking nothing.
4. **A fix that closes a finding is itself re-validated before the account closes.** A fix cycle is never itself the completion signal.
5. **A stopped run reads as stopped** — in the lane's typed halt-report shape, never free prose that a reader could mistake for completion.

Boundary: this file is repository-local, so in a consumer repository these properties reach a run only through the skill.

## Chunked delivery: design to the seams, plan to the contract

Full doctrine and rationale: [Documents/Design/chunked-delivery.md](Documents/Design/chunked-delivery.md). That document also carries **amendments A1–A5**, binding on every brief whichever of its two authority sources it carries (#957 D4 — the scope restatement, and its deliberately recorded artifact-axis narrowing, live in that document): **A1** a target may not encode a guess about a fact only the world can tell you — state the evidence standard for establishing it plus the behavior once established; **A2** tag every grounding claim source-read or sample-inferred, and an inferred claim may not set a tolerance or mandate a mechanism; **A3** falsifiers reach the executor as prose the plan carries, never as a check the run is graded on; **A4** targets pin observable behavior, never a file path, test name, or count, and any absolute suite floor is checked satisfiable before launch; **A5** evidence must be discriminating (could have come out negative), attributed (says where the number came from), and per-criterion — three properties whose standing home is [skills/verification-before-completion/SKILL.md](skills/verification-before-completion/SKILL.md). Two load-bearing detail bounds — enforcing only one recreates the waterfall failure mode one level down:

1. **The parent design stops at the seams**: the design decides chunk boundaries — interfaces, data shapes, spanning invariants, chunk sequence — and never a chunk's internals.
2. **The chunk plan is a contract, not a recipe**: each chunk's **brief** states the problem and its evidence, a provenance-marked epistemic map, acceptance criteria carrying their own proof standards, falsifiers, context, and evidence obligations — then stops. The brief is a declared plan shape (`plan-variant: brief`); its six-section contract is in [skills/plan-authoring/SKILL.md](skills/plan-authoring/SKILL.md) § Brief plan variant. The planner must not pre-solve unknowns inside the chunk — plan-phase discovery is read-only grounding for checkable targets; an unknown that could void a target or boundary escalates as a parent design gap instead.

Operating rules: chunks are **plan-only sub-issues** of a designed parent (no worth-it check, experience, design, or standards re-litigation — they inherit, and inheritance is **loaded, not assumed**: the child links its parent and the planner's first act is reading the parent design and amendments; one chunk = one sub-issue = one brief = one run = one PR, never PR-level splits since harness plumbing is issue-scoped); design gaps route up as single parent amendments, not sideways into child design phases; walking skeleton first; every chunk lands in an acceptable resting state — lawful, honest, and operable if all remaining chunks are deferred indefinitely, and two chunks that cannot satisfy that separately are one chunk (#957); a brief takes design review's charter — the brief conformance check (including the vacuity reading over the criteria taken together, #957 D2), the routing-call review target (not-applicable *only* for a chunk of a designed parent, which carries no verdict of its own; on a standalone brief a map-inconsistent verdict is a finding and an absent or novel one is a review failure, never an n/a), and the prosecution-only `design-challenge` shape, whose convergence cold read carries a required vacuity question on a brief target — and any further relaxation of review depth is earned by phase-containment-ledger evidence, never a cost argument. A brief has a second lawful authority source outside chunked delivery: a standalone issue carrying an **affirmed open-for-work framing record** (#957 D4). Doctrine: [Documents/Design/open-for-work.md](Documents/Design/open-for-work.md). The chunk rules above are unchanged by it.

## Engagement-gate non-overridability

<!-- engagement-gate-non-overridability:begin -->

User pacing directives — including but not limited to "work without stopping," "don't pause to ask," "make the reasonable call," and semantically equivalent phrasing — apply to **preference-clarifying questions**: questions the agent would otherwise ask to gather requirements, options, or non-load-bearing preferences. Pacing directives do **NOT** apply to **engagement-gate methodology checkpoints**:

- `solution-authoring` classification gates (including Code-Conductor's `scope-classification` touchpoint per the Code-Conductor body's `### Scope Classification Gate` section; pacing directives do not suppress orchestration touchpoints; same-decision-resume is the cross-session suppression mechanism for prior settled decisions)
- `upstream-onboarding` standards-check questions
- `plan-authoring` plan-approval prompts
- `open-for-work` affirmation gate (beat 1's what-statement affirmation, which beat 2 may not begin without)
- design-convergence decisions, and `safe-operations` Filing Approval Gate (§2e) batched proposal presentations

Methodology checkpoints fire unconditionally per D3. The user's only in-band lever to skip an engagement-gate question is the option built into that specific question:

- `solution-authoring`: the `Decline engagement — proceed without classification` option (or `decline:` free-text)
- `upstream-onboarding`: selecting an alternative option the standards check offers
- `plan-authoring`: the documented `Reject` or equivalent plan-approval option; `safe-operations` §2e has no separate decline — the maintainer's per-item approve/modify/drop choice on each batched proposal is itself the override
- `open-for-work`: no separate decline either — declining to affirm the what-statement is the gate's own negative outcome, which returns the conversation to beat 1 rather than bypassing the gate, so the choice the gate presents is itself the override

**The gate vs. the question (#786):** for Code-Conductor's `scope-classification` touchpoint, the *gate* — rubric evaluation plus the L0 gate-decision token — fires unconditionally on every run. The *question* is conditional: it fires only when the scope-classification outcome is genuinely indeterminate (every evidenced criterion holds so far, and at least one criterion still lacks an evidence-backed verdict that could flip the tier). When the outcome is determined by evidence-backed criteria, the gate announces the tier — naming the deciding criteria and carrying a standing pre-dispatch override — and records a lawful `{outcome: gate-fails, classification: routine}` token instead of asking. A `gate-fails` token is a documented, non-silent skip of the *question*, not a skip of the *gate*: the evaluation and token emission still happened. Pacing directives still cannot suppress a live (indeterminate-outcome) question — non-overridability governs the question whenever it actually fires.

See: `skills/solution-authoring/SKILL.md` § Rule: Classification gate (the three-leg load-bearing test that defines an engagement-gate methodology checkpoint); `skills/solution-authoring/SKILL.md` § Rule: Non-overridability; `skills/upstream-onboarding/SKILL.md` § Rule: Non-overridability; `skills/plan-authoring/SKILL.md` § Rule: Non-overridability; `skills/open-for-work/SKILL.md` § Rule: Non-overridability. Also see: #575 and #576 (engagement-record-{phase}-{ID} marker contract, active for experience/design/plan/orchestration phases) for the Segment-A maintainer-evidence path.

<!-- engagement-gate-non-overridability:end -->

## Auto-mode boundary

This section applies to Claude Code. Copilot uses a different permission model and is out of scope.

<!-- auto-mode-boundary:begin -->
**Auto-mode governs tool-permission prompts only — not engagement gates.**

- **D1 — Routine ops auto-approve**: when auto-mode is on, read-only and low-impact tool calls (`git status`, file reads, `git log`, etc.) execute without a permission prompt. This is the intended behavior.
- **D3 — the engagement gate is unconditional**: an engagement gate fires regardless of auto-mode. Auto-mode does not suppress engagement gates. Agents must still ask at all methodology checkpoints (upstream-onboarding standards checks, plan approval, design convergence decisions, etc.). How the agent presents the question is its own call, per turn; nothing here requires or forbids any particular presentation.
- **D2 — Outside-allowlist ops prompt**: tool calls outside the auto-approve allowlist produce a permission prompt for the user to approve or reject. Silent rejection occurs only when `permissions.deny` explicitly blocks the call.
<!-- auto-mode-boundary:end -->

**Known limitation (L2 — platform-side classifier behavior):** The live evidence in [issue #546](https://github.com/Grimblaz/agent-orchestra/issues/546) (comments [4414368049](https://github.com/Grimblaz/agent-orchestra/issues/546#issuecomment-4414368049) and [4414376114](https://github.com/Grimblaz/agent-orchestra/issues/546#issuecomment-4414376114)) shows that Claude Code's contextual risk classifier can silently deny a tool call even after explicit same-turn user authorization, bypassing D2. The workaround is the opt-in allowlist in [skills/session-startup/SKILL.md](skills/session-startup/SKILL.md) § Permission allowlist (recommended) — apply those entries before the deny fires by editing `.claude/settings.local.json` directly, not by asking the agent to make the edit in the same turn you authorize it. If the gap proves materially worse than this workaround, file an upstream Claude Code issue referencing this evidence.

## Where things live

- `agents/*.agent.md` — shared, tool-agnostic agent bodies used by both Copilot and Claude Code (capitalized filename, `.agent.md` extension)
- `agents/{name}.md` — Claude-native subagent shells that point at the shared bodies (lowercase filename, plain `.md`). Claude registers only the lowercase shells via the explicit `agents` array in `.claude-plugin/plugin.json`; bodies are loaded by paired shells via `Read` and are intentionally excluded from `subagent_type` registration.
- `commands/` — slash commands at plugin root (`/open`, `/experience`, `/design`, `/plan`, `/goal-run`, `/orchestrate`, `/spine-run`, `/orchestra:spine`, `/code-conductor`, `/review-github`, `/setup-references`, `/polish`, `/raw`, `/orchestra:review`, `/orchestra:review-lite`, `/orchestra:review-prosecute`, `/orchestra:review-defend`, `/orchestra:review-judge`, `/audit-docs`)
- `skills/` — reusable methodology loaded by both platforms; each skill has `platforms/claude.md` for Claude-specific invocation details
- `platforms/` (at skill root) — platform-specific routing notes
- `skills/persist-changes/` — git-portable commit+push primitive: caller-parameterized, no Code-Conductor session flags, Pester-tested guard decision helper (`Resolve-PersistDecision.ps1`). Inherited by #678's spine-runner review loop after the #677 Code-Conductor body deletion. Also see `skills/naming-register-policy/SKILL.md` § Outsider-first authoring default — new human-facing prose expands insider terms on first use or uses self-describing names, enforced at authoring time by a warn-only newcomer-audit detector.

## Per-agent model + reasoning routing

The canonical routing table, inheritance order, override-discipline rule, and per-shell declarations live in [Documents/Design/agent-body-architecture.md § Per-agent model + reasoning routing](Documents/Design/agent-body-architecture.md).

## Senior Engineer + skill-as-adapter pattern

Senior Engineer is the single executor agent for routine implementation slices; the methodology lives in the frame slice's `adapter:` path, not in separate persona shells. Adapter frontmatter uses the enum literal `adapter-type: work | predicate`, and a slice's optional `executor:` takes the enum literal `agents/*.agent.md path | inline` — when absent it derives from `adapter-type` (`work` → `agents/Senior-Engineer.agent.md`, `predicate` → `inline`). Adapter file conventions, the three skill-loading types, the `halt_return` contract, the adversarial-independence guard, and the frame-port declaration rule live in [Documents/Design/agent-body-architecture.md § Senior Engineer + skill-as-adapter pattern](Documents/Design/agent-body-architecture.md#senior-engineer--skill-as-adapter-pattern).

## Issue #369 traces the full history

See [issue #369](https://github.com/Grimblaz/agent-orchestra/issues/369) for the full design discussion, customer framing, and plan that produced this Claude Code integration.

<!-- vocab-pointer -->
> **Unfamiliar with a code or term?** Shortcodes like `SMC-NN`, `D1/D2/D3`, and `CE Gate` are defined in the [plain-language vocabulary](HOW-IT-WORKS.md#vocab).
