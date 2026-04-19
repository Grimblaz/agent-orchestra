# Contributing to Agent Orchestra

Thank you for your interest in contributing! This template aims to help teams work effectively with AI coding agents.

## Setup

For the best experience with Agent Orchestra:

### Required

- **VS Code 1.107+** (November 2025 release or later) — required for custom agents
- GitHub Copilot extension
- [markdownlint-cli2](https://github.com/DavidAnson/markdownlint-cli2) — Markdown auto-formatter (used in the pre-commit hook and by agents): `npm install -g markdownlint-cli2`

### Recommended Tooling

- PowerShell 7+ (`pwsh`) — recommended so the pre-commit hook can run the allowlisted whitespace-normalization lane for config/text files
- `PSScriptAnalyzer` — recommended if you want automatic semantic formatting for staged `.ps1` files in VS Code and the pre-commit hook: `pwsh -NoProfile -Command "Install-Module PSScriptAnalyzer -Scope CurrentUser"`

### Recommended Settings

Enable the pre-commit hook to run three independent lanes before every commit (covers agents and manual edits): semantic Markdown formatting for staged `.md`, semantic PowerShell formatting for staged `.ps1`, and whitespace-only normalization for staged allowlisted config/text files:

```sh
git config core.hooksPath .githooks
```

The hook runs `markdownlint-cli2 --fix` on staged `.md` files (including `.agent.md` agent definitions) and re-stages any Markdown changes. When `pwsh` and `PSScriptAnalyzer` are available, it also runs `Invoke-Formatter` on staged `.ps1` files and re-stages any PowerShell changes.

Separately, when `pwsh` and `.github/scripts/normalize-whitespace.ps1` are available, the hook runs a whitespace-only lane for staged `.json`, `.jsonc`, `.yml`, `.yaml`, `.psd1`, `.txt`, `.gitignore`, `.gitattributes`, and `.editorconfig` files. That lane trims trailing horizontal whitespace, removes trailing blank lines at EOF, and ensures a single final newline. It does not do semantic reformatting, and it does not take ownership away from the existing Markdown or `.ps1` lanes.

All three lanes are intentionally non-blocking. If `markdownlint-cli2`, `pwsh`, `PSScriptAnalyzer`, or the whitespace helper is unavailable, or if a file-level formatting pass fails, the hook prints an explicit warning and continues so the commit still succeeds.

The hook keeps the existing whole-file re-stage model: if any lane rewrites a staged file, it re-stages the full file with `git add`. If you use partial staging, review the staged diff after the hook runs because non-staged hunks from that file can be pulled into the commit.

For long agent sessions, disable persistent terminal sessions:

```json
{
  "terminal.integrated.enablePersistentSessions": false
}
```

This prevents VS Code from restoring terminal sessions after a window restart or reload, avoiding a fresh accumulation of sessions from prior agent runs.

Enable the built-in GitHub MCP server for seamless issue and PR workflows:

```json
{
  "github.copilot.chat.githubMcpServer.enabled": true
}
```

To make agents available globally across all VS Code workspaces (not just repos with an `agents/` directory at the repo root), add:

```json
{
  "chat.agentFilesLocations": [
    "/absolute/path/to/your/agent-orchestra/agents"
  ]
}
```

Replace the path with the absolute path to where you cloned this repository. This makes all agents available globally — 7 user-facing agents in the chat picker, plus 7 internal subagents used automatically by Code-Conductor.

<!-- legacy-path -->
> **Upgrading from v1.13 or earlier?** Agents lived at `.github/agents/` before v1.14. Replace any `.github/agents` path in your `chat.agentFilesLocations` with `agents` (repo root). See [CUSTOMIZATION.md — Migrating from pre-1.14 layouts](CUSTOMIZATION.md#migrating-from-pre-114-layouts-issue-367).
<!-- /legacy-path -->

To enable automatic skill discovery from `skills/` at the repo root (VS Code 1.108+):

```json
{
  "chat.useAgentSkills": true
}
```

This enables agents to interact directly with GitHub issues and PRs without external MCP server configuration.

> **Note**: If you also use the agent-orchestra plugin (via `chat.plugins.marketplaces`), do not add `chat.agentFilesLocations` — this creates duplicate agents in the chat picker. See [CUSTOMIZATION.md — Troubleshooting](CUSTOMIZATION.md#troubleshooting) for fix steps.

### Validated Step Commits

Code-Conductor auto-commits after each validated plan step by default. Each step commit captures a proven-good state (Tier 1 validation + RC conformance gate passed) with a structured commit message:

```text
step(N): {step-title}

Plan: issue-{ID}, Step N of M
Agents: Code-Smith, Test-Writer
Validation: Tier 1 ✅
```

This means feature branches will have multiple small commits per plan. Squash-on-merge is recommended to keep the main branch clean. The per-step commits remain valuable during review for understanding logical boundaries.

To disable per-step auto-commits, see the [Commit Policy](CUSTOMIZATION.md#commit-policy) section in the Customization Guide.

### Session Startup Check

This template includes a session startup check (triggered from `.github/copilot-instructions.md` and delivered by the `session-startup` skill) that uses the session-memory marker `/memories/session/session-startup-check-complete.md` as a run-once guard before any automatic detector run. The first automatic check in a conversation looks for post-merge cleanup work, records that marker after the automatic check runs, and avoids repeated prompts from later agent hops even if cleanup is declined. The automatic check targets stale branches and issue-scoped tracking artifacts, not persistent calibration data. Requires PowerShell 7+ (`pwsh`); the detector script self-resolves its repo root via `$PSScriptRoot`, so no environment variables are needed. If `pwsh` is unavailable or the detector returns non-JSON output, the automatic check skips silently as documented in `skills/session-startup/SKILL.md`. If session-memory access fails, the workflow fails open and still runs the detector. Manual detector runs remain available.

## Ways to Contribute

### Report Issues

Found a problem with an agent definition or instruction?

1. Check [existing issues](../../issues) first
2. Open a new issue with:
   - Clear description of the problem
   - Steps to reproduce
   - Expected vs actual behavior
   - Your environment details

### Suggest Improvements

Have ideas for better prompts or workflows?

1. Open a [discussion](../../discussions) to gather feedback
2. If there's consensus, create an issue
3. Reference the discussion in your PR

### Submit Pull Requests

Ready to contribute code or documentation?

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/improvement-name`)
3. Make your changes
4. Test thoroughly
5. Submit a PR

## Guidelines

### Agent Definitions

When modifying or adding agents:

- Keep responsibilities focused and clear
- Define interaction patterns with other agents
- Include examples where helpful
- Test with real scenarios

### Skills

When adding skills:

- Make them domain-agnostic when possible
- Include clear README documentation
- Provide practical examples
- Structure for easy customization

### Plugin Distribution

This repo is distributed as a VS Code agent plugin (VS Code 1.110+). When you add or change **agents**, those changes are automatically distributed to plugin users when they update (agents use a directory glob in `plugin.json`). **Skills require a manual `plugin.json` update** — see the array below. Slash commands, instruction files, and repository templates are **not** distributed via the plugin (the VS Code plugin manifest schema has no `commands` field).

When contributing new skills, update the repo-root `plugin.json` to add the new skill path to the `"skills"` array. To surface a new chat command, author it as a skill (directory with `SKILL.md`) rather than as a prompt file — `.prompt.md` files are not a first-class plugin manifest entry. To bump the version across all files consistently when publishing a new release, run: `pwsh .github/scripts/bump-version.ps1 -Version X.Y.Z` (replacing `X.Y.Z` with the new version).

### Documentation

When updating docs:

- Use clear, concise language
- Include practical examples
- Keep formatting consistent
- Update related docs if needed

### Commits

- Write clear commit messages
- Reference issues when applicable
- Keep commits focused and atomic

Example:

```text
Add validation for agent prompt format

- Add schema validation for agent definitions
- Include helpful error messages
- Update documentation with format requirements

Fixes #42
```

## Pull Request Process

1. **Describe your changes** - What and why
2. **Reference issues** - Link related issues
3. **Show testing** - How did you verify it works?
4. **Update docs** - Include any needed documentation

### PR Template

```markdown
## Description
Brief description of changes.

## Related Issues
Fixes #XX

## Testing
How was this tested?

## Checklist
- [ ] Documentation updated
- [ ] Tested with example project
- [ ] No breaking changes (or documented)
```

## Code of Conduct

Be respectful and constructive. We're all here to make better tools.

- Be welcoming to newcomers
- Accept constructive criticism gracefully
- Focus on what's best for the community
- Show empathy towards others

## Questions?

- Open a [discussion](../../discussions)
- Check existing issues and discussions
- Review the documentation

Thank you for helping improve this template!
