# HOW-IT-WORKS

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
| **frame slice (step\_id: sN)** | A single unit of work within a frame-spine plan — one commit-index, one adapter, one set of AC-refs. Dispatched one at a time by Spine-Runner. | Frame-spine plan comment on the GitHub issue |
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
| **intent routing / nl\_intent\_routing** | Natural-language phrase matching that maps user messages to slash commands without the user typing a command. Anchored in the routing config. | `skills/routing-tables/assets/routing-config.json` |
| **routing-config.json** | The canonical JSON file that declares all intent-routing patterns, specialist dispatch tables, CE surface mappings, and gate criteria. | `skills/routing-tables/assets/routing-config.json` |
| **raw mode** | A within-conversation toggle (`/raw`, `just answer normally`) that disables intent routing so natural-language requests are answered directly without pipeline dispatch. | `CLAUDE.md § Intent Routing` |
| **credits\[\] / pipeline-metrics block** | The array of frame-credit rows written into the PR body, used by Code-Conductor to determine which pipeline ports have been covered. Machine-parsed by `frame-credit-ledger.ps1`. | `skills/frame-credit-ledger/SKILL.md` |
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
