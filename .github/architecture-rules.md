# Architecture Rules

These rules define the structural constraints for Copilot Orchestra. All agents and contributors must follow them.

## Directory Structure

| Directory                | Purpose                                              | Allowed Contents                                               |
| ------------------------ | ---------------------------------------------------- | -------------------------------------------------------------- |
| `.github/agents/`        | Agent definitions                                    | `*.agent.md` files with YAML frontmatter                      |
| `.github/skills/{name}/` | Domain-specific knowledge                            | `SKILL.md` with frontmatter, plus optional `assets/` and `scripts/` subdirectories for supporting files |
| `.github/instructions/`  | Shared rules loaded by agents                        | `*.instructions.md` files                                     |
| `.github/prompts/`       | Prompt files and workflow templates                  | `*.prompt.md` with frontmatter; supporting `*.md` templates   |
| `.github/scripts/`       | Automation scripts invoked by agents or instructions | `*.ps1` PowerShell scripts                                    |
| `.github/scripts/lib/`   | Library modules dot-sourced by CLI wrappers and tests | `{name}-core.ps1` files exposing `Invoke-*` functions; the corresponding CLI script in `.github/scripts/` is a thin wrapper that dot-sources the library and relays results |
| `.github/config/`        | Committed configuration files consumed by automation scripts | JSON config files                                      |
| `.github/plugin/`        | VS Code agent plugin manifests                       | `plugin.json`, `marketplace.json`                             |
| `Documents/Design/`      | Design documents (committed with implementation PRs) | `{domain-slug}.md`                                            |
| `Documents/Decisions/`   | Standalone decision records                          | Markdown files                                                 |
| `examples/`              | Example configurations for different tech stacks     | Subdirectories per stack                                       |

## Layer Model

| Layer | Purpose | In Copilot Orchestra |
|-------|---------|---------------------|
| **Top (fat)** | Skills — judgment, methodology, process, documentation, and supporting data loaded on demand | `.github/skills/` |
| **Middle (thin)** | Harness — routing, context management, safety, and decision authority | Agent files (`.github/agents/`) |
| **Bottom** | Application — deterministic same-input/same-output evaluation, concrete tools, consumer codebase | `.github/scripts/`, `.github/skills/{name}/scripts/`, VS Code tools, GitHub API |
| **Resolvers** | Structured routing/context lookup data that helps load the right skill or content | `.github/skills/{name}/assets/` (JSON/YAML), `.github/instructions/` |

## Dependency Rules

### Allowed

- Agents MAY reference other agents via `handoffs` frontmatter
- Agents MAY load skills from `.github/skills/` on demand
- Agents MAY load instructions from `.github/instructions/`
- User-facing agents MAY delegate to internal agents as subagents
- Skills MAY reference other skills or instructions by file path
- Skills MAY contain static data files (JSON, YAML) in `assets/` and deterministic evaluation scripts in `scripts/` that agents invoke for routing decisions
- Skills MAY contain reusable methodology and protocol content, including ordered workflows, checklists, decision heuristics, and evidence requirements that agents load on demand

### Forbidden

- Internal agents (`user-invocable: false`) must NOT be directly user-invocable; they MAY appear in agent `handoffs` lists as subagents
- Agents must NOT reference deleted agents (e.g., Plan-Architect, Issue-Designer) — validate with `grep`
- Skills must NOT own orchestration boundaries such as user-turn routing, agent handoffs, commit authority, issue-state transitions, or Code-Conductor's step execution loop
- Concrete boundary examples: Code-Conductor's validation ladder may live in a skill, but CE Gate orchestration and subagent routing stay in the agent; test-driven-development may hold Test-Writer methodology, but conditional delegation and execution flow stay in Test-Writer; session-startup, provenance-gate, and terminal-hygiene remain portable skills while the trigger points that invoke them stay in agents
- The `guidance-complexity` D10 ceiling and prompt-facing guidance rules remain agent-only; issue #360 may move the measurement script and related tooling into the `guidance-measurement` skill without moving the rule set itself
- Only Code-Conductor may auto-commit, and only after validation ladder and RC conformance gate pass; specialist agents must NOT commit; consumers may opt out via `## Commit Policy` section
- `.github/copilot-instructions.md` must NOT contain TODO markers — it holds real project context

## File Format Rules

### Agent Files (`.agent.md`)

Required frontmatter fields: `name`, `description`, `tools`
Optional frontmatter: `handoffs`, `user-invocable` (defaults to `true` if omitted)

- User-facing agents (7): Must have `user-invocable: true` or omit the field
- Internal agents (7): Must have `user-invocable: false`

### Skill Files (`SKILL.md`)

Required frontmatter: `name`, `description`
Must live in `.github/skills/{skill-name}/SKILL.md`
Supporting files MAY live under optional `.github/skills/{skill-name}/assets/` and `.github/skills/{skill-name}/scripts/` subdirectories

### Instruction Files (`.instructions.md`)

May use `applyTo` frontmatter to scope where they apply; if omitted, applies generally.
Must live in `.github/instructions/`

## Naming Conventions

- Agent files: `{Agent-Name}.agent.md` (PascalCase with hyphens)
- Skill directories: `{skill-name}/` (lowercase with hyphens)
- Skill core libraries: `{name}-core.ps1` (mirrors `.github/scripts/lib/` — dot-sourced by CLI wrappers)
- Skill CLI wrappers & standalone scripts: lowercase-with-hyphens, descriptive (e.g., `post-merge-cleanup.ps1`)
- Skill helper modules: `{descriptive-name}-helpers.ps1` (non-Invoke-* utility functions)
- Skill asset files: lowercase-with-hyphens, descriptive (e.g., `routing-config.json`, `gate-criteria.json`)
- Instruction files: `{topic}.instructions.md` (lowercase with hyphens)
- Design documents: `{domain-slug}.md` (lowercase with hyphens)

- Prompt files: `{name}.prompt.md` (lowercase with hyphens)

## Validation

Run before every PR:

```powershell
pwsh -NoProfile -NonInteractive -File .github/scripts/quick-validate.ps1
```

This consolidates all structural checks (deleted-agent references, skill frontmatter, guidance complexity, PSScriptAnalyzer, and more).
