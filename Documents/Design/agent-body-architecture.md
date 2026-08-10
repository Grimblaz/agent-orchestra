# Design: Agent Body Architecture

**Status**: Implemented

## Summary

Agent Orchestra keeps canonical role behavior in shared, tool-agnostic `.agent.md` bodies. Platform
shells and slash commands adapt those bodies to Copilot or Claude Code without forking the role
contract. Reusable methodology lives in named skills and reference files; agent bodies keep identity,
ownership boundaries, durable markers, and explicit load pointers.

Claude Code consumers get the shared bodies through the installed plugin cache. A consumer repository
does not need a local `agents/` directory for plugin-installed agents, skills, commands, or hooks to
load. Source-repo CWD loading exists only as a gated maintainer fallback when the current checkout is
the Agent Orchestra source repo.

`/orchestrate` loads `agents/Code-Conductor.agent.md` through the same body-resolution contract and
adopts Code-Conductor inline in the parent conversation. Code-Conductor then dispatches the shipped
Claude shells for upstream framing, planning, review, implementation, documentation, retrospective,
research, specification, and UI polish work.

---

## Current Architecture

### Shared Agent Bodies

Every `.agent.md` body follows two tiers:

1. **Identity sections** - kept in the shared body because moving them would dilute the role's
    behavioral contract:

    - YAML frontmatter (`tools`, `handoffs`, `user-invocable`)
    - Core principles
    - Role, overview, when-to-use, and pipeline descriptions
    - Completion markers and durable-artifact hard stops
    - Questioning policy rules
    - Boundaries and ownership rules
    - Agent-specific setup or handoff rules
    - Per-agent `## Platform-specific invocation` footer where the shared body needs one

2. **Skill pointers** - reusable methodology already owned by a named skill collapses to a load
    instruction, for example:

    ```text
    Load `skills/upstream-onboarding/SKILL.md` and follow the protocol.
    ```

    Skill names, file paths, and load directives are the only implementation detail the agent body
    carries for extracted methodology.

### Claude Shells

Each `agents/{name}.md` Claude shell provides Claude-specific startup, tool mapping, and persistence
differences for its paired shared body. The shell resolves and reads its paired `agents/{Name}.agent.md`
body before role work using this order:

1. `~/.claude/plugins/installed_plugins.json` entry for `agent-orchestra@agent-orchestra`
2. Newest SemVer-sorted plugin-cache match under `~/.claude/plugins/cache/agent-orchestra/agent-orchestra/*/agents/`
3. Source-repo CWD fallback only when `.claude-plugin/plugin.json` declares `name: agent-orchestra`

If no candidate body loads, the shell halts with the canonical remediation command
`claude plugin install agent-orchestra@agent-orchestra`.

Tree-dependent Claude shells also run `## Step 0: Environment Handshake Verification` before loading
their shared body. The handshake is per-dispatch and verifies HEAD, branch, CWD, and dirty-tree
fingerprint against the parent prompt so tree-grounded claims do not rely on stale injected context.

### Slash Commands

Claude slash commands are command wrappers, not alternate role definitions.

- `/experience`, `/design`, and `/plan` resolve issue context, load the paired shared body, and adopt
   the role inline so live engagement gates can reach the user.
- `/orchestrate` resolves smart-resume state, loads `agents/Code-Conductor.agent.md`, and adopts
   Code-Conductor inline. Missing plan markers do not block hub mode because Code-Conductor can call
   Issue-Planner when planning is still needed.
- `/orchestra:review*` commands dispatch Code-Critic and Code-Review-Response with the same strict
   shared-body load contract and the review pipeline's redundant-pass recovery rules.
- `/polish` is the direct slash-command entry point for UI-Iterator.

Terminal-oriented implementation specialists do not have direct slash-command surfaces. Parent-agent
dispatch is their supported Claude entry point.

### Specialist Dispatch Surface

Code-Conductor can dispatch every currently shipped Claude shell that participates in orchestration:
`experience-owner`, `solution-designer`, `issue-planner`, `code-critic`, `code-review-response`,
`code-smith`, `test-writer`, `refactor-specialist`, `doc-keeper`, `process-review`, `research-agent`,
`specification`, and `ui-iterator`.

Each specialist shell keeps the same structure:

- Claude-only startup or Step 0 handshake instructions when the role makes tree-grounded claims
- one explicit shared-body pointer and strict missing-body remediation
- an H2 enumeration of shared-body sections the shell follows
- a Claude tool-mapping table for Copilot-specific references
- persistence differences that keep durable marker ownership with the owning orchestrator or issue body

### Composite Skills And References

Large reusable methodology areas use a composite-skill pattern:

- `SKILL.md` stays a compact entryway that defines purpose, boundaries, and when to use the skill.
- Named `references/*.md` files carry extracted methodology that agents load directly.
- The entryway enumerates every reference file so the skill stays discoverable without regrowing the
   extracted prose inline.

Code-Conductor uses this pattern for areas such as Customer Experience Gate, pipeline metrics, review
reconciliation, error handling, and refactoring integration. The boundary is stable: Code-Conductor
owns sequencing, delegation, and PR-gate responsibility; skills and references own reusable method
text, schemas, routing contracts, and recovery rules.

### Platform-Specific Invocations

Copilot tool names (`vscode/memory`) and Claude tool names (`Agent`, `Bash`) live in YAML
frontmatter, command wrappers, shell tool-mapping tables, or the `## Platform-specific invocation`
footer. Since issue #1003 **no surface Claude loads** names a mechanism for surfacing a decision:
the capability grants stay in frontmatter, and the agent chooses the presentation per turn. The ten
`skills/*/platforms/copilot.md` files still name Copilot's own question tool — Copilot is frozen and
those files expire with it (see [copilot-deprecation.md](copilot-deprecation.md)), so the claim is scoped
to the Claude-loaded surfaces rather than to the whole tree. Shared methodology sections stay
platform-neutral whenever the behavior itself is not platform-specific.

---

## Key Decisions

| # | Decision | Current choice | Rationale |
|---|----------|----------------|-----------|
| D-577 | Code-Conductor solution-authoring touchpoint set | Narrowed to scope-classification | Restricts the orchestrator's load-bearing decisions to scope-classification, decoupling D9-checkpoint from solution-authoring to prevent cognitive-surrender UX overhead on routine touchpoints |
| D3 | Platform-specific wording location | Per-agent platform footer, Claude shell mapping table, or command wrapper | Keeps shared role sections tool-neutral while making platform bindings visible at the call site |
| D4 | BDD classification rubric in Issue-Planner | Keep inline and synchronized with `bdd-scenarios` | The table is consulted repeatedly during plan authoring, and a skill-load interruption would add latency without reducing synchronization work |
| D7 | Command dispatch strategy | Direct `/experience`, `/design`, `/plan`, and `/orchestrate` use inline role adoption on Claude; downstream specialist work uses `Agent` dispatch | Inline commands preserve live user-question pacing, while specialist dispatch keeps orchestration single-level and preserves the shared-body contract |
| D8 | Specialist shell model | Thin Claude shells over canonical shared bodies | Claude shells add only startup, body-resolution, handshake, tool-mapping, and persistence wrappers while shared skills absorb reusable methodology |
| D9 *(Claude Code only)* | Routing-policy declaration | Per-agent `model:` and `effort:` frontmatter in each Claude shell | Extends D8's thin-shell responsibility list with a `routing-policy-declaration` responsibility. Shells that justify a non-default tier declare `model:` + `effort:` explicitly (both-or-neither discipline); shells that inherit the dispatcher's model omit both fields and add a YAML comment explaining the inheritance. The canonical routing table and inheritance-order rules live in `Documents/Design/agent-body-architecture.md` "## Per-agent model + reasoning routing" section; this decision authorizes the shell-level declaration. *(Disambiguation: `Code-Conductor.agent.md` has its own separate D9 "Model-Switch Checkpoint" — that is an orchestration-phase checkpoint inside Code-Conductor's workflow, not a routing-policy declaration. This D9 is scoped to `agent-body-architecture.md`.)* |
| D10 *(Claude Code only)* | Subagent registration whitelist | Claude `subagent_type` registration is governed by an explicit `agents` array in `.claude-plugin/plugin.json`; shared bodies (`.agent.md`) are excluded from registration | Without an explicit whitelist, Claude's default directory scan registers both the lowercase shells (`agents/{name}.md`) and the shared bodies (`agents/{Name}.agent.md`). Bodies use Copilot-style tool names and do not persist edits to the parent worktree, so accidental dispatch causes silent failures. The explicit array in `.claude-plugin/plugin.json` replaces the default scan with an enumerated list of only the 14 lowercase shells; bodies are loaded by paired shells via `Read` and are intentionally absent from the whitelist. The `manifest-agents-array.Tests.ps1` Pester test locks the set-equality between the declared array and the discovered lowercase shells. |

---

## Maintenance Rule

When adding methodology sections to any `.agent.md` file, first check whether the content belongs in a
skill. If a skill can carry it, add it to the skill and insert a one-line load pointer in the agent
body. Only embed inline when the content is:

- **Agent-specific identity**: markers, checklist items, boundaries, pipeline description, or durable
   ownership rules.
- **Frequently referenced tabular material**: reference tables where a skill-load interruption degrades
   usability. Annotate these with the skill they must stay synchronized with.

Platform-specific invocation details belong in the per-agent footer, Claude shell, or command wrapper,
not in shared body sections.

For large shared bodies such as Code-Conductor, keep `SKILL.md` as the entryway, add or extend named
`references/*.md` files for extracted method text, and leave the agent body with explicit load
directives plus the orchestration decisions that only the agent can own. Future shell or command
wrappers should continue to load the shared body rather than fork it, so Copilot and Claude stay
aligned on one contract.

---

## Per-agent model + reasoning routing

**2026-07-25 (#905): Opus 5 alias resolution.** Opus 5 launched and the six shells that declare `model: opus` in this table (`code-critic`, `experience-owner`, `solution-designer`, `issue-planner`, `research-agent`, `specification`) now alias-resolve to `claude-opus-5` on the subagent-dispatch path (see the D6 inline-path limit below — the three inline-invoked shells' frontmatter has no effect on `/experience`, `/design`, `/plan`). This resolution is the shell's own default, not an unconditional guarantee for every dispatch of that shell: `code-critic`'s `standard` adversarial adapter explicitly overrides two of its five prosecution passes to `sonnet` and `fable` at Agent-tool call time (see the role→tier map in `skills/adversarial-review/platforms/claude.md`), so not every `code-critic` dispatch runs on Opus 5. No frontmatter change lands or is needed: `model: opus` is a tier alias, and alias-to-concrete-model resolution happens outside this repo, at the platform layer. There is no versioned model identifier to pin here, and none should be added.

Each Claude subagent shell in `agents/*.md` may declare `model:` and `effort:` in its YAML frontmatter to request a specific model tier for that role's dispatch. The convention is authorized by the D9 decision above: shells that justify a non-default tier declare both fields (both-or-neither discipline); shells that inherit the dispatcher's model omit both fields and document the reason with a YAML comment. The goal is to concentrate quality-justified upgrades at the roles that genuinely need them (adversarial review, deep synthesis) while keeping routine specialist work at the dispatcher's tier.

**Governing principle**: the burden of proof for a non-default tier declaration scales with the role's dispatch volume and observability. High-volume, low-observability roles (routine specialists dispatched many times per session, whose individual outputs are rarely inspected in isolation) default to `inherit` — a bad call on any one dispatch is cheap to catch and correct downstream. Low-volume, high-observability roles (adversarial judges, convergence synthesis, upstream framing shells whose single output anchors an entire phase) carry a higher bar because their output is dispatched once, trusted broadly, and expensive to unwind if wrong. This is why adversarial review and judge roles justify `opus`/`fable` upgrades on a thin per-dispatch cost, while executors stay `inherit` and rely on session-level escalation (re-running the whole session at a higher tier) as the correction lever rather than a per-shell pin.

Before changing any `effort:` declaration, read `Documents/Design/context-engineering-claude-5.md` (R3): on Claude 5, lower effort often beats `xhigh` on prior models, and high effort on routine roles produces over-deliberation. The portfolio-wide effort re-tune is sequenced behind #923 (it would confound that issue's before/after cost comparison — see the settlement on #933); individual declarations changed before then should note the interaction.

**"Effective model + effort" column legend**: this column is not a single kind of value — it carries five distinct meanings depending on the row, and reading every cell as "the declared tier" would misread most of them:

1. **Inherit rows showing a resolved dispatcher-default value** (`code-smith.md`, `test-writer.md`, `doc-keeper.md`, `ui-iterator.md`): the shell declares `inherit`/`inherit`, and the cell spells out what that resolves to today (`sonnet + high (default via dispatcher)`) because Code-Conductor happens to dispatch at that tier — the cell documents an observed default, not a pin on the shell.
2. **Inherit rows showing the bare `dispatcher` token** (`commands/spine-run.md`, `commands/orchestra-spine.md`, `agents/spine-runner.md`, `agents/senior-engineer.md`): the cell deliberately does *not* spell out a concrete tier — it names the mechanism ("whatever the dispatcher is running") because these are minimal frame-walking/inspection roles where the resolved value is not worth restating.
3. **D6 upstream-shell-floor rows** (`agents/research-agent.md`, `agents/specification.md`): the cell shows the floor the shell's own frontmatter guarantees (`opus + high`) — this is an override the shell enforces itself, not a dispatcher default, and it applies unconditionally because these two shells have no inline command entry point.
4. **Inline-path rows with two values** (`agents/experience-owner.md`, `agents/solution-designer.md`, `agents/issue-planner.md`): the cell shows a slash before two different values (`user-session (inline) / opus + high (subagent)`) because the same shell resolves differently depending on dispatch path — inline invocation via `/experience`/`/design`/`/plan` follows the user's session model, while subagent dispatch enforces the D6 floor. Collapsing this to one value would silently drop the inline-path behavior documented in the D6 inline-path limit note below.
5. **Plain declared-pin rows** (`commands/orchestrate.md`, `commands/code-conductor.md`, `commands/review-github.md`, `commands/goal-run.md`, `agents/code-conductor.md`, `agents/goal-run.md`, `agents/code-critic.md`, `agents/code-review-response.md`, `agents/refactor-specialist.md`, `agents/process-review.md`): the cell simply restates the row's own declared `model` + `effort` values verbatim, with no dispatcher-default resolution, no bare-token abstraction, no D6 floor framing, and no inline/subagent split — this is the majority shape, where the shell pins a concrete tier and the cell just names it.

| Agent shell | `model` | `effort` | Effective model + effort | Why |
|---|---|---|---|---|
| `commands/orchestrate.md` | `sonnet` | `high` | sonnet + high | D1: command front-end sets the primary dispatch tier |
| `commands/code-conductor.md` | `sonnet` | `high` | sonnet + high | D1: command front-end sets the primary dispatch tier |
| `commands/review-github.md` | `sonnet` | `high` | sonnet + high | D1: command front-end sets the primary dispatch tier |
| `commands/spine-run.md` | `inherit` | `inherit` | dispatcher | D7: minimal frame walker inherits dispatcher tier |
| `commands/orchestra-spine.md` | `inherit` | `inherit` | dispatcher | D4: routine inspection |
| `commands/goal-run.md` | `sonnet` | `high` | sonnet + high | D1: command front-end sets the primary dispatch tier (#874 plan step 4) |
| `agents/code-conductor.md` | `sonnet` | `high` | sonnet + high | D2: redundant declaration; ensures orchestrator tier even without command override |
| `agents/goal-run.md` | `sonnet` | `high` | sonnet + high | D2: redundant declaration, same rationale as `agents/code-conductor.md` — a single-issue orchestrator entry point also directly dispatchable as `subagent_type: goal-run` (#874 plan step 4) |
| `agents/spine-runner.md` | `inherit` | `inherit` | dispatcher | D7: minimal frame walker inherits dispatcher tier |
| `agents/senior-engineer.md` | `inherit` | `inherit` | dispatcher | D4: routine skill-as-adapter execution; inherits dispatcher |
| `agents/code-critic.md` | `opus` | `high` | opus + high | D5: adversarial review requires maximum reasoning depth |
| `agents/code-review-response.md` | `fable` | `xhigh` | fable + xhigh | D5: judge pass requires full synthesis depth; re-tiered to Fable (#785, DD4) — monotonic ladder: judge tier stays ≥ max finder tier; post-escalation equality with a specialist axis is acceptable because the judge only filters. The ordering source is the fallback-degradation list `fable → opus → sonnet → haiku` in `skills/adversarial-review/platforms/claude.md`. |
| `agents/refactor-specialist.md` | `sonnet` | `high` | sonnet + high | D5: code-quality analysis benefits from extended reasoning |
| `agents/process-review.md` | `sonnet` | `high` | sonnet + high | D5: workflow meta-analysis requires extended reasoning |
| `agents/code-smith.md` | `inherit` | `inherit` | sonnet + high (default via dispatcher) | D4/`f5-executor-inherit` (#785): routine implementation; Conductor-dispatched work already runs sonnet+high because Code-Conductor pins that tier — this row documents sonnet as the default *via the dispatcher*, not a hard pin on the shell; session-model upgrade remains the working per-slice escalation lever until `/plan` ships a per-slice mechanism (DD6) |
| `agents/test-writer.md` | `inherit` | `inherit` | sonnet + high (default via dispatcher) | D4/`f5-executor-inherit` (#785): routine test authoring; same dispatcher-default note as `code-smith.md` above |
| `agents/doc-keeper.md` | `inherit` | `inherit` | sonnet + high (default via dispatcher) | D4/`f5-executor-inherit` (#785): routine documentation; same dispatcher-default note as `code-smith.md` above |
| `agents/research-agent.md` | `opus` | `high` | opus + high | D6: upstream-shell floor (#785, `f13-upstream-shell-floor`); binds only the subagent-delegation path — see note below |
| `agents/specification.md` | `opus` | `high` | opus + high | D6: upstream-shell floor (#785, `f13-upstream-shell-floor`); binds only the subagent-delegation path — see note below |
| `agents/ui-iterator.md` | `inherit` | `inherit` | sonnet + high (default via dispatcher) | D4/`f5-executor-inherit` (#785): UI polish; same dispatcher-default note as `code-smith.md` above |
| `agents/experience-owner.md` | `opus` | `high` | user-session (inline) / opus + high (subagent) | D6: inline `/experience` uses user session; subagent dispatch declares an opus+high floor (#785, `f13-upstream-shell-floor`) — see note below |
| `agents/solution-designer.md` | `opus` | `high` | user-session (inline) / opus + high (subagent) | D6: inline `/design` uses user session; subagent dispatch declares an opus+high floor (#785, `f13-upstream-shell-floor`) — see note below |
| `agents/issue-planner.md` | `opus` | `high` | user-session (inline) / opus + high (subagent) | D6: inline `/plan` uses user session; subagent dispatch declares an opus+high floor (#785, `f13-upstream-shell-floor`) — see note below |

**D6 inline-path limit (plainly stated)**: declaring `model: opus`/`effort: high` frontmatter on the five upstream shells above (`experience-owner`, `solution-designer`, `issue-planner`, `research-agent`, `specification`) is **inert on the inline invocation path** — `/experience`, `/design`, and `/plan` run inline in the parent conversation and follow the user's active session model, not shell frontmatter (see the inheritance-order table below: shell frontmatter only governs subagent `Agent`-tool dispatch). The declaration is a floor that binds only when one of these shells is dispatched as a subagent (for example, from Code-Conductor or another orchestrator). Owners invoking `/experience`, `/design`, or `/plan` directly in a low-tier session do not get an automatic upgrade from this declaration; set the session model explicitly if a higher tier is wanted for inline upstream work. This "inert on the inline path" framing describes only the three shells with an inline command entry point (`experience-owner`, `solution-designer`, `issue-planner`, via `/experience`/`/design`/`/plan`); `research-agent` and `specification` have **no inline command entry point at all**, so the `opus + high` floor applies to them unconditionally — there is no inline path for it to be inert on.

**DD1 corrected-premise note (#785)**: this section's re-tier (the `fable` judge flip and the five upstream-shell `opus + high` floors) is motivated by the corrected premise recorded as `DD1` on issue #785 (`dc-part-c-premise-revision`): the standard/lite/design-challenge prosecution passes already run in isolated fresh-context dispatches, so the re-tier's benefit claim is lens precision, between-lens synthesis at the judge/convergence step, and a filter of record — not de-anchoring isolated passes from each other. The governing principle above (burden of proof scales with volume and observability) is the corrected rationale this table's routing decisions are evaluated against.

**Inheritance order** (highest priority first, per the [Claude Code sub-agents docs](https://code.claude.com/docs/en/sub-agents)):

1. `CLAUDE_CODE_SUBAGENT_MODEL` environment variable (process-level override)
2. Per-invocation `model:` parameter passed in the `Agent` tool call
3. Shell frontmatter `model:` / `effort:` declaration (this table)
4. Dispatcher's current model (user's active session model)

Note: the user-session default (`/model` setting) never propagates to subagents — it applies only to inline commands without `model:` frontmatter (`/experience`, `/design`, `/plan`, `/polish`). Downstream specialist `Agent` dispatches from those commands inherit the dispatcher's model, not the user-session default.

**Multi-turn `/orchestrate` boundary**: the `model: sonnet, effort: high` override declared in `commands/orchestrate.md` applies for the duration of the command's turn. `/code-conductor` and `/review-github` have their own `sonnet + high` command-front-end overrides that apply for their respective command turns. If a user interrupts a multi-turn `/orchestrate` session mid-flow, the override resets to the user's session model. Re-invoking `/orchestrate` re-applies the override for the new turn.

**Sonnet-default trade-off**: `commands/orchestrate.md` and `agents/code-conductor.md` default to `sonnet + high` because orchestration work (plan parsing, dispatch, coordination, review reconciliation) benefits from extended reasoning while staying on the cost-efficient Sonnet tier. Spine-Runner inherits the dispatcher tier because it is a minimal frame walker. Quality-critical roles (adversarial review) explicitly upgrade to `opus`; judge synthesis (`agents/code-review-response.md`) upgrades to `fable` per the monotonic-ladder rule (DD4, #785). This is an intentional cost-vs-depth trade-off per D3.

**Standard prosecution role→tier map**: the `standard` adversarial-review adapter dispatches a five-pass two-layer panel. The `agents/code-critic.md` shell declares `model: opus`, but the parent dispatcher overrides this at Agent-tool call time using the role→tier map defined in `skills/adversarial-review/platforms/claude.md`: generalist-A uses `model: sonnet`; generalist-B uses `model: fable` (DD4, #785); all three specialist passes use `model: opus`. The shell frontmatter governs only when no per-dispatch model override is set. Fallback order when a tier is unavailable: fable → opus → sonnet → haiku.

**Override-discipline rule**: every `agents/*.md` shell must declare both `model:` and `effort:`, or neither (both-or-neither). A shell with only one field is a test failure. The Pester test at `.github/scripts/Tests/per-agent-model-routing.Tests.ps1` enforces this, the enum membership set, the inherit-comment requirement, and the D5 oracle. Shell frontmatter is the authoritative source for model/effort values; the table above is a documentation-tier mirror verified only by an existence-only check (this file exists and contains the section heading).

**How to override the declared routing**:

- **Inline slash commands**: when a command file declares concrete `model:` frontmatter (currently `/orchestrate`, `/code-conductor`, and `/review-github`), that frontmatter governs the command's turn — running `/model <name>` first does *not* override it. `/spine-run` declares `inherit` routing for D7 parity and follows the dispatcher's active tier. The user-session `/model` setting only governs inline commands that omit `model:` frontmatter (`/experience`, `/design`, `/plan`, `/polish`).
- **Subagent dispatches** from any command follow the inheritance order above. For a process-wide override of every subagent, set the `CLAUDE_CODE_SUBAGENT_MODEL` environment variable. For a one-off override, pass `model:` on a specific `Agent` tool call. Shell frontmatter still wins over the dispatcher model, so quality-justified shells (code-critic, code-review-response, etc.) keep their declared tier even when the dispatcher's model differs.
- **Multi-turn `/orchestrate` interruption**: if you interrupt mid-flow and the next message is not `/orchestrate`, the model falls back to the user-session default until you re-invoke `/orchestrate`, which re-applies the command frontmatter.

---

## Senior Engineer + skill-as-adapter pattern

Moved here from the root guidance file (`CLAUDE.md`) by issue #998, which needed the space for the standing statement of what a finished run is true of. The root file keeps the headline and the two enum literals; the mechanics live here. Nothing about the pattern changed in the move.

Senior Engineer is a single executor agent for routine implementation slices. The methodology lives in the frame slice's `adapter:` path, not in separate persona shells or runtime persona parameters. Spine-Runner resolves the adapter file, derives the executor, and dispatches the paired `agents/senior-engineer.md` shell when the slice uses the default skill-as-adapter path.

Single-variant work adapters use `skills/{skill}/adapters/{port}-adapter.md`, for example `skills/implementation-discipline/adapters/implement-code-adapter.md`. Multi-variant ports keep selector-named adapter files such as `standard.md`, `lite.md`, or `proxy-github.md`, and choose among them with `applies-when:` predicates. Adapter frontmatter uses the enum literal `adapter-type: work | predicate`; work adapters execute a task, while predicate adapters decide not-applicable, skip, or variant-selection outcomes. Predicate adapters follow the unified suffix convention: `{port}-auto-na-adapter.md` for not-applicable and `{port}-explicit-skip-adapter.md` for manual skip, discovered by `Glob skills/*/adapters/*-adapter.md` and filtered by `adapter-type: predicate`.

Frame slices may include optional `executor:`. The legal executor enum literal is `agents/*.agent.md path | inline`: agent paths dispatch the paired shell, while `inline` runs the resolved adapter in the active conductor context. When `executor:` is absent, derive it from `adapter-type`: `work` defaults to `agents/Senior-Engineer.agent.md`; `predicate` defaults to `inline`. `executor: none` is intentionally deferred and rejected by current validation.

The three skill-loading types are: the planner-designated adapter path, auxiliary skills that adapter explicitly directs, and normal platform/bootstrap skills already required by the active shell. Senior Engineer does not scan the skill tree or infer methodology from nearby files.

The halt-return contract is the structured `halt_return` YAML described in `agents/Senior-Engineer.agent.md`; Senior Engineer uses it instead of claiming partial completion when work cannot proceed safely. The adversarial-independence guard is exact: "Halt when the slice's adapter path matches the adversarial-pattern regex and the executor is the default Senior Engineer; emit halt-return with reason: adversarial-independence-required". This prevents the default editor-capable executor from serving as the reviewer half of adversarial workflows.

Known follow-ups: #559 owns the rename sweep from older specialist language to the stable Senior Engineer + skill-as-adapter terminology where that sweep is outside #552's documentation slice. The current adversarial-pattern regex is intentionally brittle scaffolding; future work should replace it with a declarative adapter capability or independence flag when the adapter registry matures.

### Frame port declarations

Before adding or changing any adapter that fills a frame port, read the Adapter Model in [frame-architecture.md](frame-architecture.md). That design doc owns the declaration locations, provisional predicate DSL, and the distinction between port-filling adapters that declare `provides:` and supporting methodology skills that do not.

<!-- vocab-pointer -->
> **Unfamiliar with a code or term?** Shortcodes like `SMC-NN`, `D1/D2/D3`, and `CE Gate` are defined in the [plain-language vocabulary](../../HOW-IT-WORKS.md#vocab).
