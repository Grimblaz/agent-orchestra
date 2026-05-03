# Agent Orchestra — Claude Code Guide

Agent Orchestra is a multi-agent workflow system originally built for GitHub Copilot and now available to Claude Code through the same plugin.

## Quick start

Install the plugin from the marketplace if you have not already. Run this inside Claude Code (not a system shell):

```text
/plugin install agent-orchestra@agent-orchestra
```

The plugin exposes the upstream pipeline, the review surface, the `/orchestrate` entry point, and a library of shared skills. Claude Code discovers them automatically once the plugin is installed.

Consumer repositories are zero-config after install: Claude Code loads the agent bodies and skills from the installed plugin cache, so the working repository does not need a local `agents/` directory.

## Upstream pipeline

Three agents cover the journey from an issue on the board to an implementation-ready plan. They call each other through durable GitHub-issue markers so a session can span multiple conversations or switch between Copilot and Claude Code.

1. **Experience-Owner** — frames the work in customer language. Writes the problem statement, user journeys, scenarios, and surface/readiness assessment into the issue body. Activated with `/experience` or via the subagent name.
2. **Solution-Designer** — runs technical design exploration and the 3-pass non-blocking design challenge. Updates the issue body with decisions, acceptance criteria, and rejected alternatives. Activated with `/design` or via the subagent name.
3. **Issue-Planner** — produces the implementation plan with CE Gate coverage and the full adversarial review pipeline (prosecution × 3 → defense → judge). Persists the approved plan as a GitHub issue comment with a `<!-- plan-issue-{ID} -->` marker per `SMC-01`. Activated with `/plan` or via the subagent name.

Each agent reads a shared tool-agnostic body from `agents/*.agent.md` and follows the named skills for methodology. Claude-specific tool bindings (structured questions, subagent dispatch, `gh` CLI for GitHub work) are documented in each skill's `platforms/claude.md`.

All three upstream agents share a common opening behavior — implemented in `skills/upstream-onboarding/SKILL.md`. When a user-invocable agent receives a request referencing an existing GitHub issue, it loads `upstream-onboarding` and renders a scaled context brief (summarizing the issue, scope tier, inherited decisions, and any blocking questions) and runs a standards check on work inherited from the prior phase. When the standards check finds a concern, the agent cites the violated standard by anchor (skill path + rule name), quotes the offending text, and presents a corrective approach as a structured question with a strong recommendation. The brief and standards check are skipped on same-agent resumes (when the most recent upstream marker already belongs to the active agent's own role). When no issue exists yet (greenfield invocation), each agent synthesizes a brief from the user's prompt with all fields marked `(proposed)` and prompts for issue creation per its GitHub Setup step; the standards check is skipped until a real issue is established.

## Orchestration

Code-Conductor orchestration is available in Claude Code.

- `/orchestrate` runs Code-Conductor inline in the parent conversation for the full pipeline from smart resume and plan handoff through implementation, validation, CE Gate, and PR readiness.

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

The judge result is designed for same-comment persistence: the completion marker `<!-- code-review-complete-{PR} -->` and the `<!-- judge-rulings ... -->` YAML block travel together in one PR comment so Copilot and Claude Code can consume the same durable artifact.

**Review-pipeline equivalence**: `/review-github` provides a deterministic entry point for GitHub review intake and proxy prosecution. It resolves the target PR (from arguments or via `gh pr view`), then routes through Code-Conductor's GitHub intake path and proxy prosecution flow, equivalent to prose triggers like `github review`, `review github`, or `cr review`. This command ensures explicit GitHub-review mode without requiring prose-based classification.

## Cross-tool handoffs

Handoffs between phases use durable GitHub issue comments rather than session-local state. Markers:

- `<!-- experience-owner-complete-{ID} -->` — upstream framing complete
- `<!-- design-phase-complete-{ID} -->` — technical design complete
- `<!-- design-issue-{ID} -->` — durable design snapshot handoff used for D9 pause/resume and full-pipeline smart resume
- `<!-- plan-issue-{ID} -->` — approved plan persisted
- `<!-- frame-credit-ledger-{PR} -->` — warn-only frame credit-ledger comment posted by the pre-PR hook (sub-issue #429 of frame umbrella #425); idempotently upserted on every PR after `gh pr create`

Because the markers live on the issue, you can start a feature in Copilot, pick it up in Claude Code, and vice versa without losing context.

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

## Where things live

- `agents/*.agent.md` — shared, tool-agnostic agent bodies used by both Copilot and Claude Code (capitalized filename, `.agent.md` extension)
- `agents/{name}.md` — Claude-native subagent shells that point at the shared bodies (lowercase filename, plain `.md`)
- `commands/` — slash commands at plugin root (`/experience`, `/design`, `/plan`, `/orchestrate`, `/code-conductor`, `/review-github`, `/polish`, `/orchestra:review`, `/orchestra:review-lite`, `/orchestra:review-prosecute`, `/orchestra:review-defend`, `/orchestra:review-judge`)
- `skills/` — reusable methodology loaded by both platforms; each skill has `platforms/claude.md` for Claude-specific invocation details
- `platforms/` (at skill root) — platform-specific routing notes

## Per-agent model + reasoning routing

Each Claude subagent shell in `agents/*.md` may declare `model:` and `effort:` in its YAML frontmatter to request a specific model tier for that role's dispatch. The convention is governed by [D9 in `Documents/Design/agent-body-architecture.md`](Documents/Design/agent-body-architecture.md): shells that justify a non-default tier declare both fields (both-or-neither discipline); shells that inherit the dispatcher's model omit both fields and document the reason with a YAML comment. The goal is to concentrate quality-justified upgrades at the roles that genuinely need them (adversarial review, deep synthesis) while keeping routine specialist work at the dispatcher's tier.

| Agent shell | `model` | `effort` | Effective model + effort | Why |
|---|---|---|---|---|
| `commands/orchestrate.md` | `sonnet` | `medium` | sonnet + medium | D1: command front-end sets the primary dispatch tier |
| `commands/code-conductor.md` | `sonnet` | `medium` | sonnet + medium | D1: command front-end sets the primary dispatch tier |
| `commands/review-github.md` | `sonnet` | `medium` | sonnet + medium | D1: command front-end sets the primary dispatch tier |
| `agents/code-conductor.md` | `sonnet` | `medium` | sonnet + medium | D2: redundant declaration; ensures orchestrator tier even without command override |
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

Note: the user-session default (`/model` setting) never propagates to subagents — it applies only to inline commands (`/experience`, `/design`, `/plan`, `/orchestrate`). Downstream specialist `Agent` dispatches from those commands inherit the dispatcher's model, not the user-session default.

**Multi-turn `/orchestrate` boundary**: the `model: sonnet, effort: medium` override declared in `commands/orchestrate.md` applies for the duration of the command's turn. `/code-conductor` and `/review-github` have their own `sonnet + medium` command-front-end overrides that apply for their respective command turns. If a user interrupts a multi-turn `/orchestrate` session mid-flow, the override resets to the user's session model. Re-invoking `/orchestrate` re-applies the override for the new turn.

**Sonnet-default trade-off**: `commands/orchestrate.md` and `agents/code-conductor.md` default to `sonnet + medium` because the majority of orchestration work (plan parsing, dispatch, coordination) does not need full reasoning depth. Quality-critical roles (adversarial review, judge synthesis) explicitly upgrade to `opus`. This is an intentional cost-vs-depth trade-off per D3.

**Override-discipline rule**: every `agents/*.md` shell must declare both `model:` and `effort:`, or neither (both-or-neither). A shell with only one field is a test failure. The Pester test at `.github/scripts/Tests/per-agent-model-routing.Tests.ps1` enforces this, the enum membership set, the inherit-comment requirement, the D5 oracle, and CLAUDE.md routing-table parity.

**How to override the declared routing**:

- **Inline slash commands**: when a command file declares `model:` frontmatter (currently only `/orchestrate`), that frontmatter governs the command's turn — running `/model <name>` first does *not* override it. To run `/orchestrate` at a different tier, edit `commands/orchestrate.md` frontmatter directly. The user-session `/model` setting only governs inline commands that omit `model:` frontmatter (`/experience`, `/design`, `/plan`, `/polish`).
- **Subagent dispatches** from any command follow the inheritance order above. For a process-wide override of every subagent, set the `CLAUDE_CODE_SUBAGENT_MODEL` environment variable. For a one-off override, pass `model:` on a specific `Agent` tool call. Shell frontmatter still wins over the dispatcher model, so quality-justified shells (code-critic, code-review-response, etc.) keep their declared tier even when the dispatcher's model differs.
- **Multi-turn `/orchestrate` interruption**: if you interrupt mid-flow and the next message is not `/orchestrate`, the model falls back to the user-session default until you re-invoke `/orchestrate`, which re-applies the command frontmatter.

## Frame Port Declarations

Before adding or changing any adapter that fills a frame port, read the Adapter Model in [Documents/Design/frame-architecture.md](Documents/Design/frame-architecture.md). That design doc owns the declaration locations, provisional predicate DSL, and the distinction between port-filling adapters that declare `provides:` and supporting methodology skills that do not.

## Issue #369 traces the full history

See [issue #369](https://github.com/Grimblaz/agent-orchestra/issues/369) for the full design discussion, customer framing, and plan that produced this Claude Code integration.
