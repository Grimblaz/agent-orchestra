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

For commands with explicit `model:` frontmatter (`/orchestrate`, `/code-conductor`, `/review-github`), emit `Please run /X to continue` and stop; do not inline-emulate.

## Upstream pipeline

Three agents cover the journey from an issue on the board to an implementation-ready plan. They call each other through durable GitHub-issue markers so a session can span multiple conversations. *(Cross-tool handoff between Copilot and Claude Code was supported; Copilot is now frozen — see Documents/Design/copilot-deprecation.md.)*

1. **Experience-Owner** — frames the work in customer language. Optionally opens with the **worth-it check** (bet / falsifier / alternative — recommends Proceed-full, Proceed-lite, Shrink, Park, or Decline; advisory only, skippable with `frame it`). Writes the problem statement, user journeys, scenarios, and surface/readiness assessment into the issue body. Activated with `/experience` or via the subagent name.
2. **Solution-Designer** — runs technical design exploration and the 3-pass non-blocking design challenge. Updates the issue body with decisions, acceptance criteria, and rejected alternatives. Activated with `/design` or via the subagent name.
3. **Issue-Planner** — produces the implementation plan with CE Gate (Customer Experience Gate) coverage and the full adversarial review pipeline (prosecution × 3 → defense → judge). Persists the approved plan as a GitHub issue comment with a `<!-- plan-issue-{ID} -->` marker per `SMC-01` (Session Memory Contract marker). Activated with `/plan` or via the subagent name.

Each agent reads a shared tool-agnostic body from `agents/*.agent.md` and follows the named skills for methodology. Claude-specific tool bindings (structured questions, subagent dispatch, `gh` CLI for GitHub work) are documented in each skill's `platforms/claude.md`.

All three upstream agents share a common opening behavior — implemented in `skills/upstream-onboarding/SKILL.md`. When a user-invocable agent receives a request referencing an existing GitHub issue, it loads `upstream-onboarding` and renders a scaled context brief (summarizing the issue, scope tier, inherited decisions, and any blocking questions) and runs a standards check on work inherited from the prior phase. When the standards check finds a concern, the agent cites the violated standard by anchor (skill path + rule name), quotes the offending text, and presents a corrective approach as a structured question with a strong recommendation. The standard brief and standards check are skipped on same-agent resumes (when the most recent upstream marker already belongs to the active agent's own role), but a **resume-variant orientation snapshot** is rendered inline (reference issue #633). When no issue exists yet (greenfield invocation), each agent synthesizes a brief from the user's prompt with all fields marked `(proposed)` and prompts for issue creation per its GitHub Setup step; the standards check is skipped until a real issue is established.

## Orchestration

Code-Conductor orchestration is available in Claude Code.

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

Handshake disposition by command:

| Command | Handshake |
| --- | --- |
| `/orchestra:review` | Required |
| `/orchestra:review-lite` | Required |
| `/orchestra:review-prosecute` | Required |
| `/orchestra:review-defend` | Required |
| `/orchestra:review-judge` | Optional |

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

The `session-startup` skill also owns a Claude-only active-assist drift check. When the installed `agent-orchestra@agent-orchestra` version is behind the resolved marketplace version, the startup pass runs `claude plugin update`, waits for the install to complete (success or announced failure), and only then presents the restart-vs-continue structured question. The install-then-prompt ordering is enforced by the explicit 6-step procedure in Step 7b of the skill.

### For maintainers

Supported Claude plugin CLI surface:

```text
claude plugin list
claude plugin marketplace list
claude plugin marketplace update
claude plugin marketplace add <source>
claude plugin marketplace remove <name>
claude plugin update <plugin@marketplace>
claude plugin install <plugin@marketplace>
claude plugin uninstall <plugin@marketplace>
```

## Quality-first, shift-left

Quality is the first constraint — ahead of speed and token cost; when they conflict, the methodology checkpoint wins (hence engagement gates and adversarial review are non-overridable by pacing directives). We shift defects **left**: the earlier in the pipeline (experience → design → plan → implementation) a defect is caught, the cheaper it is to fix, so every phase and review stage exists to catch a class before it reaches the next. Run the full methodology now — do not pre-emptively skip a stage because it "probably won't find anything."

We remove later checks **only with evidence, never on a cost argument**: a stage earns relaxation only when its *irreducible-catch rate* (defects catchable **only** at that stage) trends to ~0 over a large-enough sample. The instrument is the **phase-containment ledger** — the per-finding record of where a defect was introduced, the earliest phase it was catchable, and where it was caught ([Documents/Design/phase-containment-ledger.md](Documents/Design/phase-containment-ledger.md)); governance lives in umbrella #761. So annotate every sustained finding, and retire later steps once they demonstrably catch nothing new.

## Engagement-gate non-overridability

<!-- engagement-gate-non-overridability:begin -->

User pacing directives — including but not limited to "work without stopping," "don't pause to ask," "make the reasonable call," and semantically equivalent phrasing — apply to **preference-clarifying questions**: questions the agent would otherwise ask to gather requirements, options, or non-load-bearing preferences. Pacing directives do **NOT** apply to **engagement-gate methodology checkpoints**:

- `solution-authoring` classification gates (including Code-Conductor's `scope-classification` touchpoint per the Code-Conductor body's `### Scope Classification Gate` section; pacing directives do not suppress orchestration touchpoints; same-decision-resume is the cross-session suppression mechanism for prior settled decisions)
- `upstream-onboarding` standards-check questions
- `plan-authoring` plan-approval prompts
- design-convergence decisions, and `safe-operations` Filing Approval Gate (§2e) batched proposal presentations

Methodology checkpoints fire unconditionally per D3. The user's only in-band lever to skip an engagement-gate question is the option built into that specific question:

- `solution-authoring`: the `Decline engagement — proceed without classification` option (or `decline:` free-text)
- `upstream-onboarding`: selecting an alternative option in the structured question
- `plan-authoring`: the documented `Reject` or equivalent plan-approval option; `safe-operations` §2e has no separate decline — the maintainer's per-item approve/modify/drop choice on each batched proposal is itself the override

**The gate vs. the question (#786):** for Code-Conductor's `scope-classification` touchpoint, the *gate* — rubric evaluation plus the L0 gate-decision token — fires unconditionally on every run. The *question* (the `AskUserQuestion` call) is conditional: it fires only when the scope-classification outcome is genuinely indeterminate (every evidenced criterion holds so far, and at least one criterion still lacks an evidence-backed verdict that could flip the tier). When the outcome is determined by evidence-backed criteria, the gate announces the tier — naming the deciding criteria and carrying a standing pre-dispatch override — and records a lawful `{outcome: gate-fails, classification: routine}` token instead of asking. A `gate-fails` token is a documented, non-silent skip of the *question*, not a skip of the *gate*: the evaluation and token emission still happened. Pacing directives still cannot suppress a live (indeterminate-outcome) question — non-overridability governs the question whenever it actually fires.

See: `skills/solution-authoring/SKILL.md` § Rule: Classification gate (the three-leg load-bearing test that defines an engagement-gate methodology checkpoint); `skills/solution-authoring/SKILL.md` § Rule: Non-overridability; `skills/upstream-onboarding/SKILL.md` § Rule: Non-overridability; `skills/plan-authoring/SKILL.md` § Rule: Non-overridability. Also see: #575 and #576 (engagement-record-{phase}-{ID} marker contract, active for experience/design/plan/orchestration phases) for the Segment-A maintainer-evidence path.

<!-- engagement-gate-non-overridability:end -->

## Auto-mode boundary

This section applies to Claude Code. Copilot uses a different permission model and is out of scope.

<!-- auto-mode-boundary:begin -->
**Auto-mode governs tool-permission prompts only — not structured questions.**

- **D1 — Routine ops auto-approve**: when auto-mode is on, read-only and low-impact tool calls (`git status`, file reads, `git log`, etc.) execute without a permission prompt. This is the intended behavior.
- **D3 — `AskUserQuestion` is unconditional**: `AskUserQuestion` fires regardless of auto-mode. Auto-mode does not suppress `AskUserQuestion`. Agents must still ask at all methodology checkpoints (upstream-onboarding standards checks, plan approval, design convergence decisions, etc.).
- **D2 — Outside-allowlist ops prompt**: tool calls outside the auto-approve allowlist produce a permission prompt for the user to approve or reject. Silent rejection occurs only when `permissions.deny` explicitly blocks the call.
<!-- auto-mode-boundary:end -->

**Known limitation (L2 — platform-side classifier behavior):** The live evidence in [issue #546](https://github.com/Grimblaz/agent-orchestra/issues/546) (comments [4414368049](https://github.com/Grimblaz/agent-orchestra/issues/546#issuecomment-4414368049) and [4414376114](https://github.com/Grimblaz/agent-orchestra/issues/546#issuecomment-4414376114)) shows that Claude Code's contextual risk classifier can silently deny a tool call even after explicit same-turn user authorization, bypassing D2. The workaround is the opt-in allowlist in [skills/session-startup/SKILL.md](skills/session-startup/SKILL.md) § Permission allowlist (recommended) — apply those entries before the deny fires by editing `.claude/settings.local.json` directly, not by asking the agent to make the edit in the same turn you authorize it. If the gap proves materially worse than this workaround, file an upstream Claude Code issue referencing this evidence.

## Where things live

- `agents/*.agent.md` — shared, tool-agnostic agent bodies used by both Copilot and Claude Code (capitalized filename, `.agent.md` extension)
- `agents/{name}.md` — Claude-native subagent shells that point at the shared bodies (lowercase filename, plain `.md`). Claude registers only the lowercase shells via the explicit `agents` array in `.claude-plugin/plugin.json`; bodies are loaded by paired shells via `Read` and are intentionally excluded from `subagent_type` registration.
- `commands/` — slash commands at plugin root (`/experience`, `/design`, `/plan`, `/orchestrate`, `/spine-run`, `/orchestra:spine`, `/code-conductor`, `/review-github`, `/setup-references`, `/polish`, `/raw`, `/orchestra:review`, `/orchestra:review-lite`, `/orchestra:review-prosecute`, `/orchestra:review-defend`, `/orchestra:review-judge`, `/audit-docs`)
- `skills/` — reusable methodology loaded by both platforms; each skill has `platforms/claude.md` for Claude-specific invocation details
- `platforms/` (at skill root) — platform-specific routing notes
- `skills/persist-changes/` — git-portable commit+push primitive: caller-parameterized, no Code-Conductor session flags, Pester-tested guard decision helper (`Resolve-PersistDecision.ps1`). Inherited by #678's spine-runner review loop after the #677 Code-Conductor body deletion. Also see `skills/naming-register-policy/SKILL.md` § Outsider-first authoring default — new human-facing prose expands insider terms on first use or uses self-describing names, enforced at authoring time by a warn-only newcomer-audit detector.

## Per-agent model + reasoning routing

The canonical routing table, inheritance order, override-discipline rule, and per-shell declarations live in [Documents/Design/agent-body-architecture.md § Per-agent model + reasoning routing](Documents/Design/agent-body-architecture.md).

## Senior Engineer + skill-as-adapter pattern

Senior Engineer is a single executor agent for routine implementation slices. The methodology lives in the frame slice's `adapter:` path, not in separate persona shells or runtime persona parameters. Spine-Runner resolves the adapter file, derives the executor, and dispatches the paired `agents/senior-engineer.md` shell when the slice uses the default skill-as-adapter path.

Single-variant work adapters use `skills/{skill}/adapters/{port}-adapter.md`, for example `skills/implementation-discipline/adapters/implement-code-adapter.md`. Multi-variant ports keep selector-named adapter files such as `standard.md`, `lite.md`, or `proxy-github.md`, and choose among them with `applies-when:` predicates. Adapter frontmatter uses the enum literal `adapter-type: work | predicate`; work adapters execute a task, while predicate adapters decide not-applicable, skip, or variant-selection outcomes. Predicate adapters follow the unified suffix convention: `{port}-auto-na-adapter.md` for not-applicable and `{port}-explicit-skip-adapter.md` for manual skip, discovered by `Glob skills/*/adapters/*-adapter.md` and filtered by `adapter-type: predicate`.

Frame slices may include optional `executor:`. The legal executor enum literal is `agents/*.agent.md path | inline`: agent paths dispatch the paired shell, while `inline` runs the resolved adapter in the active conductor context. When `executor:` is absent, derive it from `adapter-type`: `work` defaults to `agents/Senior-Engineer.agent.md`; `predicate` defaults to `inline`. `executor: none` is intentionally deferred and rejected by current validation.

The three skill-loading types are: the planner-designated adapter path, auxiliary skills that adapter explicitly directs, and normal platform/bootstrap skills already required by the active shell. Senior Engineer does not scan the skill tree or infer methodology from nearby files.

The halt-return contract is the structured `halt_return` YAML described in `agents/Senior-Engineer.agent.md`; Senior Engineer uses it instead of claiming partial completion when work cannot proceed safely. The adversarial-independence guard is exact: "Halt when the slice's adapter path matches the adversarial-pattern regex and the executor is the default Senior Engineer; emit halt-return with reason: adversarial-independence-required". This prevents the default editor-capable executor from serving as the reviewer half of adversarial workflows.

Known follow-ups: #559 owns the rename sweep from older specialist language to the stable Senior Engineer + skill-as-adapter terminology where that sweep is outside #552's documentation slice. The current adversarial-pattern regex is intentionally brittle scaffolding; future work should replace it with a declarative adapter capability or independence flag when the adapter registry matures.

## Frame Port Declarations

Before adding or changing any adapter that fills a frame port, read the Adapter Model in [Documents/Design/frame-architecture.md](Documents/Design/frame-architecture.md). That design doc owns the declaration locations, provisional predicate DSL, and the distinction between port-filling adapters that declare `provides:` and supporting methodology skills that do not.

## Issue #369 traces the full history

See [issue #369](https://github.com/Grimblaz/agent-orchestra/issues/369) for the full design discussion, customer framing, and plan that produced this Claude Code integration.

<!-- vocab-pointer -->
> **Unfamiliar with a code or term?** Shortcodes like `SMC-NN`, `D1/D2/D3`, and `CE Gate` are defined in the [plain-language vocabulary](HOW-IT-WORKS.md#vocab).
