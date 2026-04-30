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
    Load `skills/provenance-gate/SKILL.md` and follow the protocol.
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
   the role inline so live `AskUserQuestion` prompts remain available.
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

Copilot tool names (`#tool:vscode/askQuestions`, `vscode/memory`) and Claude tool names
(`AskUserQuestion`, `Agent`, `Bash`) live in YAML frontmatter, command wrappers, shell tool-mapping
tables, or the `## Platform-specific invocation` footer. Shared methodology sections stay
platform-neutral whenever the behavior itself is not platform-specific.

---

## Key Decisions

| # | Decision | Current choice | Rationale |
|---|----------|----------------|-----------|
| D3 | Platform-specific wording location | Per-agent platform footer, Claude shell mapping table, or command wrapper | Keeps shared role sections tool-neutral while making platform bindings visible at the call site |
| D4 | BDD classification rubric in Issue-Planner | Keep inline and synchronized with `bdd-scenarios` | The table is consulted repeatedly during plan authoring, and a skill-load interruption would add latency without reducing synchronization work |
| D7 | Command dispatch strategy | Direct `/experience`, `/design`, `/plan`, and `/orchestrate` use inline role adoption on Claude; downstream specialist work uses `Agent` dispatch | Inline commands preserve live user-question pacing, while specialist dispatch keeps orchestration single-level and preserves the shared-body contract |
| D8 | Specialist shell model | Thin Claude shells over canonical shared bodies | Claude shells add only startup, body-resolution, handshake, tool-mapping, and persistence wrappers while shared skills absorb reusable methodology |

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
