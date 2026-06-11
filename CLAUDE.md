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

1. Plugin processes are the default chat experience. Natural-language requests matching the `nl_intent_routing` table route to the corresponding slash command with a visible confirmation; `/raw` opts out.
2. Recommended order: (1) VS Code dropdown for VS Code users; (2) slash commands for both platforms; (3) natural-language with auto-routing confirmation; (4) @-mention is NOT recommended (unreliable in every plugin surface tested).
3. Slash commands diverge between Claude (commands/*.md) and Copilot (.github/prompts/*.prompt.md); the nl_intent_routing table carries both column names so the canonical command name is platform-portable.
4. Source of truth: `skills/routing-tables/assets/routing-config.json` anchors natural-language routing in `nl_intent_routing`.
5. First match per command-family per conversation uses structured `AskUserQuestion` with options `Run /X for this (Recommended)`, `Continue as raw chat`, and `Don't ask again for this command-family this conversation`; Claude confirmation phrasing should use `Run /X?`. Subsequent same-family matches use inline confirmation: `Routing to /X — say /raw to opt out, otherwise proceed.`
6. Routing detection runs only on top-level user messages outside an active slash-command turn and outside subagent dispatches, and only after the session-startup run-once marker is recorded.
7. `/raw`, `just answer normally`, `don't run the pipeline`, `raw mode`, and `skip routing` activate within-conversation raw mode only: no persistence file, no SMC row, and new conversations start routing-active. Any user-typed slash command clears raw mode. Acknowledge with: `Raw mode active for this conversation — natural-language requests will not be routed. Any explicit slash command you type clears raw mode.`
8. For commands with explicit `model:` frontmatter (`/orchestrate`, `/code-conductor`, `/review-github`), emit `Please run /X to continue` and stop; do not inline-emulate.
9. When proposed command frontmatter differs from the user-session model, append a one-line tier hint, e.g. `Will run on sonnet + high per command frontmatter.`
10. No-match answers normally; first no-match per conversation appends `Tip: type /help for plugin slash commands, or /raw to suppress these hints.` Ambiguous-match uses a text-only disambiguation prompt, e.g. `Did you mean /orchestra:review (local code) or /review-github (GitHub PR)?`

## Upstream pipeline

Three agents cover the journey from an issue on the board to an implementation-ready plan. They call each other through durable GitHub-issue markers so a session can span multiple conversations. *(Cross-tool handoff between Copilot and Claude Code was supported; Copilot is now frozen — see Documents/Design/copilot-deprecation.md.)*

1. **Experience-Owner** — frames the work in customer language. Writes the problem statement, user journeys, scenarios, and surface/readiness assessment into the issue body. Activated with `/experience` or via the subagent name.
2. **Solution-Designer** — runs technical design exploration and the 3-pass non-blocking design challenge. Updates the issue body with decisions, acceptance criteria, and rejected alternatives. Activated with `/design` or via the subagent name.
3. **Issue-Planner** — produces the implementation plan with CE Gate coverage and the full adversarial review pipeline (prosecution × 3 → defense → judge). Persists the approved plan as a GitHub issue comment with a `<!-- plan-issue-{ID} -->` marker per `SMC-01`. Activated with `/plan` or via the subagent name.

Each agent reads a shared tool-agnostic body from `agents/*.agent.md` and follows the named skills for methodology. Claude-specific tool bindings (structured questions, subagent dispatch, `gh` CLI for GitHub work) are documented in each skill's `platforms/claude.md`.

All three upstream agents share a common opening behavior — implemented in `skills/upstream-onboarding/SKILL.md`. When a user-invocable agent receives a request referencing an existing GitHub issue, it loads `upstream-onboarding` and renders a scaled context brief (summarizing the issue, scope tier, inherited decisions, and any blocking questions) and runs a standards check on work inherited from the prior phase. When the standards check finds a concern, the agent cites the violated standard by anchor (skill path + rule name), quotes the offending text, and presents a corrective approach as a structured question with a strong recommendation. The standard brief and standards check are skipped on same-agent resumes (when the most recent upstream marker already belongs to the active agent's own role), but a **resume-variant orientation snapshot** is rendered inline (reference issue #633). When no issue exists yet (greenfield invocation), each agent synthesizes a brief from the user's prompt with all fields marked `(proposed)` and prompts for issue creation per its GitHub Setup step; the standards check is skipped until a real issue is established.

## Orchestration

Code-Conductor orchestration is available in Claude Code.

- `/orchestrate` runs Code-Conductor inline in the parent conversation for the full pipeline from smart resume and plan handoff through implementation, validation, CE Gate, and PR readiness.
- `/spine-run` runs Spine-Runner as the minimal frame-walking conductor once a v2 plan exists.

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

Handoffs between phases use durable GitHub issue comments rather than session-local state. Markers:

- `<!-- experience-owner-complete-{ID} -->` — upstream framing complete
- `<!-- design-phase-complete-{ID} -->` — technical design complete
- `<!-- engagement-record-experience-{ID} -->` — durable engagement audit for /experience phase: load-bearing decisions, audit rationale, articulation text persisted alongside the experience-owner-complete marker for cross-session decision memory (SMC-20)
- `<!-- engagement-record-design-{ID} -->` — durable engagement audit for /design phase: load-bearing decisions persisted alongside the design-phase-complete marker; consumed by solution-authoring's same-decision-resume rule on phase re-entry (SMC-20)
- `<!-- engagement-record-plan-{ID} -->` — durable engagement audit for /plan phase: load-bearing decisions persisted alongside the plan-issue marker; consumed by solution-authoring's same-decision-resume rule on phase re-entry (SMC-20)
- `<!-- engagement-record-orchestration-{ID} -->` — durable engagement audit for orchestration touchpoint (`scope-classification`): persisted as an issue comment when scope-classification resolves; payload Markdown mirror co-located in the comment; consumed by solution-authoring's same-decision-resume rule on Code-Conductor re-entry (SMC-20)
- `<!-- engagement-record-review-{PR} -->` — durable engagement audit for /orchestra:review and /orchestra:review-judge phases: load-bearing review-finding dispositions persisted as a PR comment after the post-judge disposition gate completes; consumed by same-decision-resume on re-review of the same PR (SMC-20, SMC-23, schema_version 4)
- `<!-- review-dispositions-{PR} -->` — per-finding disposition record for PR code-review verdicts; one entry per judge-sustained finding carrying stable_finding_key, pass, disposition (incorporate|dismiss|escalate), classification, and disposition_rationale (SMC-23)
- `<!-- design-issue-{ID} -->` — durable design snapshot handoff used for D9 pause/resume and full-pipeline smart resume
- `<!-- plan-issue-{ID} -->` — approved plan persisted
- `<!-- frame-credit-ledger-{PR} -->` — warn-only frame credit-ledger comment posted by the pre-PR hook (sub-issue #429 of frame umbrella #425); idempotently upserted on every PR after `gh pr create`
- `<!-- review-judge-produced-{PR} -->` — sentinel written by the judge (both Copilot and Claude) immediately after the ruling finalizes, before pipeline-metrics persistence; the warn-only hook detects this to synthesize a `not-persisted` review credit when the PR body carries no review credit yet (SMC-16)
- `<!-- credit-input-{port}-{ID} -->` — deferred-emission marker written by pipeline-entry agents (Experience-Owner, Solution-Designer, Issue-Planner) immediately after their completion marker; payload is a `yaml` fenced block carrying `{ port, adapter, evidence }`; harvested by Code-Conductor at PR-creation time to emit the corresponding credit row (SMC-17)

Because the markers live on the issue, you can resume work across sessions without losing context. *(Cross-tool Copilot↔Claude handoff was supported; Copilot is now frozen.)*

The row-level survival and fallback semantics are governed by [skills/session-memory-contract/SKILL.md](skills/session-memory-contract/SKILL.md). [Documents/Design/session-memory-contract.md](Documents/Design/session-memory-contract.md) explains why Claude keeps durable GitHub markers instead of adding a Claude-only session-memory store.

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

## Engagement-gate non-overridability

<!-- engagement-gate-non-overridability:begin -->

User pacing directives — including but not limited to "work without stopping," "don't pause to ask," "make the reasonable call," and semantically equivalent phrasing — apply to **preference-clarifying questions**: questions the agent would otherwise ask to gather requirements, options, or non-load-bearing preferences. Pacing directives do **NOT** apply to **engagement-gate methodology checkpoints**:

- `solution-authoring` classification gates (including Code-Conductor's `scope-classification` touchpoint per the Code-Conductor body's `### Scope Classification Gate` section; pacing directives do not suppress orchestration touchpoints; same-decision-resume is the cross-session suppression mechanism for prior settled decisions)
- `upstream-onboarding` standards-check questions
- `plan-authoring` plan-approval prompts
- design-convergence decisions

Methodology checkpoints fire unconditionally per D3. The user's only in-band lever to skip an engagement-gate question is the option built into that specific question:

- `solution-authoring`: the `Decline engagement — proceed without classification` option (or `decline:` free-text)
- `upstream-onboarding`: selecting an alternative option in the structured question
- `plan-authoring`: the documented `Reject` or equivalent plan-approval option

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

<!-- auto-mode-boundary-recipe:begin -->
### Manual verification recipe

Run these three checks in Claude Code to audit the auto-mode boundary in your session.

**1. Positive case (D1):** Run `git status` under auto-mode. It should execute immediately without a permission prompt. If it prompts, D1 has regressed — check your `permissions.allow` list.

**2. Risky case (D2):** Run `gh pr merge --admin` against a draft PR you own, then **abort at the Claude Code permission prompt** — do not complete the merge. Expected: a permission prompt appears before execution. If no prompt appears and the command is silently denied, you are observing the L2 contextual-classifier override pattern documented above. Fallback: (a) record the chat transcript verbatim, (b) confirm the [cleanup-script allowlist entry](skills/session-startup/SKILL.md) is applied (project-level for contributors, `~/.claude/settings.json` for plugin consumers — see that skill section for the correct path), (c) file an issue at the [agent-orchestra repo](https://github.com/Grimblaz/agent-orchestra/issues) with the transcript and settings excerpt.

**3. Axis B case (D3):** Run `/experience N` against an **existing issue** you own (use an issue that already carries an upstream marker — e.g., a `<!-- experience-owner-complete-{ID} -->` comment from a prior `/experience` run — so the upstream-onboarding standards check actually fires; a fresh unframed issue will skip the standards check per [skills/upstream-onboarding/SKILL.md § When to Skip](skills/upstream-onboarding/SKILL.md)). Verify the upstream-onboarding standards check fires `AskUserQuestion`. If the agent skips the question and assumes an answer, D3 has regressed — report it on [issue #546](https://github.com/Grimblaz/agent-orchestra/issues/546).
<!-- auto-mode-boundary-recipe:end -->

## Where things live

- `agents/*.agent.md` — shared, tool-agnostic agent bodies used by both Copilot and Claude Code (capitalized filename, `.agent.md` extension)
- `agents/{name}.md` — Claude-native subagent shells that point at the shared bodies (lowercase filename, plain `.md`). Claude registers only the lowercase shells via the explicit `agents` array in `.claude-plugin/plugin.json`; bodies are loaded by paired shells via `Read` and are intentionally excluded from `subagent_type` registration.
- `commands/` — slash commands at plugin root (`/experience`, `/design`, `/plan`, `/orchestrate`, `/spine-run`, `/orchestra:spine`, `/code-conductor`, `/review-github`, `/setup-references`, `/polish`, `/raw`, `/orchestra:review`, `/orchestra:review-lite`, `/orchestra:review-prosecute`, `/orchestra:review-defend`, `/orchestra:review-judge`)
- `skills/` — reusable methodology loaded by both platforms; each skill has `platforms/claude.md` for Claude-specific invocation details
- `platforms/` (at skill root) — platform-specific routing notes
- `skills/persist-changes/` — git-portable commit+push primitive: caller-parameterized, no Code-Conductor session flags, Pester-tested guard decision helper (`Resolve-PersistDecision.ps1`). Inherited by #678's spine-runner review loop after the #677 Code-Conductor body deletion.

## Per-agent model + reasoning routing

Each Claude subagent shell in `agents/*.md` may declare `model:` and `effort:` in its YAML frontmatter to request a specific model tier for that role's dispatch. The convention is governed by [D9 in `Documents/Design/agent-body-architecture.md`](Documents/Design/agent-body-architecture.md): shells that justify a non-default tier declare both fields (both-or-neither discipline); shells that inherit the dispatcher's model omit both fields and document the reason with a YAML comment. The goal is to concentrate quality-justified upgrades at the roles that genuinely need them (adversarial review, deep synthesis) while keeping routine specialist work at the dispatcher's tier.

| Agent shell | `model` | `effort` | Effective model + effort | Why |
|---|---|---|---|---|
| `commands/orchestrate.md` | `sonnet` | `high` | sonnet + high | D1: command front-end sets the primary dispatch tier |
| `commands/code-conductor.md` | `sonnet` | `high` | sonnet + high | D1: command front-end sets the primary dispatch tier |
| `commands/review-github.md` | `sonnet` | `high` | sonnet + high | D1: command front-end sets the primary dispatch tier |
| `commands/spine-run.md` | `inherit` | `inherit` | dispatcher | D7: minimal frame walker inherits dispatcher tier |
| `commands/orchestra-spine.md` | `inherit` | `inherit` | dispatcher | D4: routine inspection |
| `agents/code-conductor.md` | `sonnet` | `high` | sonnet + high | D2: redundant declaration; ensures orchestrator tier even without command override |
| `agents/spine-runner.md` | `inherit` | `inherit` | dispatcher | D7: minimal frame walker inherits dispatcher tier |
| `agents/senior-engineer.md` | `inherit` | `inherit` | dispatcher | D4: routine skill-as-adapter execution; inherits dispatcher |
| `agents/code-critic.md` | `opus` | `high` | opus + high | D5: adversarial review requires maximum reasoning depth |
| `agents/code-review-response.md` | `opus` | `xhigh` | opus + xhigh | D5: judge pass requires full synthesis depth |
| `agents/refactor-specialist.md` | `sonnet` | `high` | sonnet + high | D5: code-quality analysis benefits from extended reasoning |
| `agents/process-review.md` | `sonnet` | `high` | sonnet + high | D5: workflow meta-analysis requires extended reasoning |
| `agents/code-smith.md` | `inherit` | `inherit` | dispatcher | D4: routine implementation; inherits dispatcher |
| `agents/test-writer.md` | `inherit` | `inherit` | dispatcher | D4: routine test authoring; inherits dispatcher |
| `agents/doc-keeper.md` | `inherit` | `inherit` | dispatcher | D4: routine documentation; inherits dispatcher |
| `agents/research-agent.md` | `inherit` | `inherit` | dispatcher | D4: evidence gathering; inherits dispatcher |
| `agents/specification.md` | `inherit` | `inherit` | dispatcher | D4: specification authoring; inherits dispatcher |
| `agents/ui-iterator.md` | `inherit` | `inherit` | dispatcher | D4: UI polish; inherits dispatcher |
| `agents/experience-owner.md` | `inherit` | `inherit` | user-session (inline) / dispatcher (subagent) | D6: inline `/experience` uses user session; subagent dispatch inherits dispatcher |
| `agents/solution-designer.md` | `inherit` | `inherit` | user-session (inline) / dispatcher (subagent) | D6: inline `/design` uses user session; subagent dispatch inherits dispatcher |
| `agents/issue-planner.md` | `inherit` | `inherit` | user-session (inline) / dispatcher (subagent) | D6: inline `/plan` uses user session; subagent dispatch inherits dispatcher |

**Inheritance order** (highest priority first, per the [Claude Code sub-agents docs](https://code.claude.com/docs/en/sub-agents)):

1. `CLAUDE_CODE_SUBAGENT_MODEL` environment variable (process-level override)
2. Per-invocation `model:` parameter passed in the `Agent` tool call
3. Shell frontmatter `model:` / `effort:` declaration (this table)
4. Dispatcher's current model (user's active session model)

Note: the user-session default (`/model` setting) never propagates to subagents — it applies only to inline commands without `model:` frontmatter (`/experience`, `/design`, `/plan`, `/polish`). Downstream specialist `Agent` dispatches from those commands inherit the dispatcher's model, not the user-session default.

**Multi-turn `/orchestrate` boundary**: the `model: sonnet, effort: high` override declared in `commands/orchestrate.md` applies for the duration of the command's turn. `/code-conductor` and `/review-github` have their own `sonnet + high` command-front-end overrides that apply for their respective command turns. If a user interrupts a multi-turn `/orchestrate` session mid-flow, the override resets to the user's session model. Re-invoking `/orchestrate` re-applies the override for the new turn.

**Sonnet-default trade-off**: `commands/orchestrate.md` and `agents/code-conductor.md` default to `sonnet + high` because orchestration work (plan parsing, dispatch, coordination, review reconciliation) benefits from extended reasoning while staying on the cost-efficient Sonnet tier. Spine-Runner inherits the dispatcher tier because it is a minimal frame walker. Quality-critical roles (adversarial review, judge synthesis) explicitly upgrade to `opus`. This is an intentional cost-vs-depth trade-off per D3.

**Override-discipline rule**: every `agents/*.md` shell must declare both `model:` and `effort:`, or neither (both-or-neither). A shell with only one field is a test failure. The Pester test at `.github/scripts/Tests/per-agent-model-routing.Tests.ps1` enforces this, the enum membership set, the inherit-comment requirement, the D5 oracle, and CLAUDE.md routing-table parity.

**How to override the declared routing**:

- **Inline slash commands**: when a command file declares concrete `model:` frontmatter (currently `/orchestrate`, `/code-conductor`, and `/review-github`), that frontmatter governs the command's turn — running `/model <name>` first does *not* override it. `/spine-run` declares `inherit` routing for D7 parity and follows the dispatcher's active tier. The user-session `/model` setting only governs inline commands that omit `model:` frontmatter (`/experience`, `/design`, `/plan`, `/polish`).
- **Subagent dispatches** from any command follow the inheritance order above. For a process-wide override of every subagent, set the `CLAUDE_CODE_SUBAGENT_MODEL` environment variable. For a one-off override, pass `model:` on a specific `Agent` tool call. Shell frontmatter still wins over the dispatcher model, so quality-justified shells (code-critic, code-review-response, etc.) keep their declared tier even when the dispatcher's model differs.
- **Multi-turn `/orchestrate` interruption**: if you interrupt mid-flow and the next message is not `/orchestrate`, the model falls back to the user-session default until you re-invoke `/orchestrate`, which re-applies the command frontmatter.

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
