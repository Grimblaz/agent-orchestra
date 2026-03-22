# Architecture Rules

These rules define the structural constraints for Copilot Orchestra. All agents and contributors must follow them.

## Directory Structure

| Directory                | Purpose                                              | Allowed Contents                                               |
| ------------------------ | ---------------------------------------------------- | -------------------------------------------------------------- |
| `.github/agents/`        | Agent definitions                                    | `*.agent.md` files with YAML frontmatter                      |
| `.github/skills/{name}/` | Domain-specific knowledge                            | `SKILL.md` with frontmatter, supporting files                 |
| `.github/instructions/`  | Shared rules loaded by agents                        | `*.instructions.md` files                                     |
| `.github/prompts/`       | Prompt files and workflow templates                  | `*.prompt.md` with frontmatter; supporting `*.md` templates   |
| `.github/scripts/`       | Automation scripts invoked by agents or instructions | `*.ps1` PowerShell scripts                                    |
| `.github/plugin/`        | VS Code agent plugin manifests                       | `plugin.json`, `marketplace.json`                             |
| `Documents/Design/`      | Design documents (committed with implementation PRs) | `{domain-slug}.md`                                            |
| `Documents/Decisions/`   | Standalone decision records                          | Markdown files                                                 |
| `examples/`              | Example configurations for different tech stacks     | Subdirectories per stack                                       |

## Dependency Rules

### Allowed

- Agents MAY reference other agents via `handoffs` frontmatter
- Agents MAY load skills from `.github/skills/` on demand
- Agents MAY load instructions from `.github/instructions/`
- User-facing agents MAY delegate to internal agents as subagents
- Skills MAY reference other skills or instructions by file path

### Forbidden

- Internal agents (`user-invocable: false`) must NOT be directly user-invocable; they MAY appear in agent `handoffs` lists as subagents
- Agents must NOT reference deleted agents (e.g., Plan-Architect, Issue-Designer) — validate with `grep`
- Skills must NOT contain agent logic — they provide knowledge, not orchestration
- No agent may auto-commit — all commits are manual by the user
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

### Instruction Files (`.instructions.md`)

May use `applyTo` frontmatter to scope where they apply; if omitted, applies generally.
Must live in `.github/instructions/`

## Naming Conventions

- Agent files: `{Agent-Name}.agent.md` (PascalCase with hyphens)
- Skill directories: `{skill-name}/` (lowercase with hyphens)
- Instruction files: `{topic}.instructions.md` (lowercase with hyphens)
- Design documents: `{domain-slug}.md` (lowercase with hyphens)

- Prompt files: `{name}.prompt.md` (lowercase with hyphens)

## Validation

Run before every PR:

```powershell
# No references to deleted agents
(Get-ChildItem -Path .github -Recurse -Filter "*.md" | Where-Object { $_.Name -notmatch "architecture-rules|copilot-instructions" } | Select-String "Plan-Architect").Count  # must be 0
(Get-ChildItem -Path .github -Recurse -Filter "*.md" | Where-Object { $_.Name -notmatch "architecture-rules|copilot-instructions" } | Select-String "Janitor").Count  # must be 0
(Get-ChildItem -Path .github -Recurse -Filter "*.md" | Where-Object { $_.Name -notmatch "architecture-rules|copilot-instructions" } | Select-String "Issue-Designer").Count  # must be 0

# Correct agent count
(Get-ChildItem .github/agents/*.agent.md).Count  # must be 14
```
