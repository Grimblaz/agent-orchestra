# Architecture Rules

These rules define the structural constraints for Copilot Orchestra. All agents and contributors must follow them.

## Directory Structure

| Directory                | Purpose                                              | Allowed Contents                                               |
| ------------------------ | ---------------------------------------------------- | -------------------------------------------------------------- |
| `agents/`                | Agent definitions (repo root — enables Claude Code auto-discovery) | `*.agent.md` files with YAML frontmatter                      |
| `skills/{name}/`         | Domain-specific knowledge (repo root — enables Claude Code auto-discovery) | `SKILL.md` with frontmatter, plus optional `assets/`, `scripts/`, and `platforms/` subdirectories for supporting files |
| `skills/{name}/platforms/` | Platform-specific invocation snippets for a skill  | `copilot.md`, `claude.md` — loaded by the owning SKILL.md's canonical routing footer |
| `.github/instructions/`  | Shared rules loaded by agents                        | `*.instructions.md` files                                     |
| `.github/prompts/`       | Prompt files and workflow templates                  | `*.prompt.md` with frontmatter; supporting `*.md` templates   |
| `.github/scripts/`       | Automation scripts invoked by agents or instructions | `*.ps1` PowerShell scripts                                    |
| `.github/scripts/lib/`   | Library modules dot-sourced by CLI wrappers and tests | `{name}-core.ps1` files exposing `Invoke-*` functions; the corresponding CLI script in `.github/scripts/` is a thin wrapper that dot-sources the library and relays results |
| `.github/config/`        | Committed configuration files consumed by automation scripts | JSON config files                                      |
| `.github/plugin.json`    | Copilot/VS Code plugin manifest (paths relative to `.github/`, so `../agents/` + `../skills/...`) | `plugin.json` |
| `.claude-plugin/plugin.json` | Claude Code plugin manifest (metadata only; Claude Code auto-discovers repo-root `agents/` + `skills/`) | `plugin.json` |
| `.github/plugin/`        | Marketplace manifest for the Copilot plugin          | `marketplace.json`                                             |
| `Documents/Design/`      | Design documents (committed with implementation PRs) | `{domain-slug}.md`                                            |
| `Documents/Decisions/`   | Standalone decision records                          | Markdown files                                                 |
| `examples/`              | Example configurations for different tech stacks     | Subdirectories per stack                                       |

## Layer Model

| Layer | Purpose | In Copilot Orchestra |
|-------|---------|---------------------|
| **Top (fat)** | Skills — judgment, methodology, process, documentation, and supporting data loaded on demand | `skills/` (repo root) |
| **Middle (thin)** | Harness — routing, context management, safety, and decision authority | Agent files (`agents/` at repo root) |
| **Bottom** | Application — deterministic same-input/same-output evaluation, concrete tools, consumer codebase | `.github/scripts/`, `skills/{name}/scripts/`, VS Code tools, GitHub API |
| **Resolvers** | Structured routing/context lookup data that helps load the right skill or content | `skills/{name}/assets/` (JSON/YAML), `.github/instructions/` |

## platforms/ Convention

Some skills depend on platform-specific tool invocations that differ between Copilot (VS Code) and Claude Code. Those skills keep their methodology tool-agnostic inside `SKILL.md` and split platform-specific invocation guidance into sibling files:

- `skills/{name}/platforms/copilot.md` — VS Code / Copilot invocation (e.g., `#tool:vscode/askQuestions`)
- `skills/{name}/platforms/claude.md` — Claude Code invocation (e.g., `AskUserQuestion`)

Each such skill ends with a byte-identical canonical routing footer listing both platform files. The footer keeps skill methodology portable across tools while letting each platform layer in its own tool bindings. D3b exemption: `session-startup` retains inline Copilot-specific methodology because its trigger path is Copilot-native.

## Dependency Rules

### Allowed

- Agents MAY reference other agents via `handoffs` frontmatter
- Agents MAY load skills from `skills/` (repo root) on demand
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
Must live in `skills/{skill-name}/SKILL.md` at the repo root
Supporting files MAY live under optional `skills/{skill-name}/assets/`, `skills/{skill-name}/scripts/`, and `skills/{skill-name}/platforms/` subdirectories

### Instruction Files (`.instructions.md`)

May use `applyTo` frontmatter to scope where they apply; if omitted, applies generally.
Must live in `.github/instructions/`

## Naming Conventions

- Agent files: `{Agent-Name}.agent.md` (PascalCase with hyphens)
- Skill directories: `{skill-name}/` (lowercase with hyphens)
- Skill core libraries: `{name}-core.ps1` (mirrors `.github/scripts/lib/` — dot-sourced by CLI wrappers)
- Skill platform files: `platforms/{platform}.md` where `{platform}` is `copilot` or `claude`
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
