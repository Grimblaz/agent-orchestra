# Contributing to Workflow Template

Thank you for your interest in contributing! This template aims to help teams work effectively with AI coding agents.

## Setup

For the best experience with this workflow template:

### Required

- **VS Code 1.107+** (November 2025 release or later) — required for custom agents
- **VS Code 1.109.3+** — required for the `SessionStart` hook (Preview feature). On earlier versions, agents work normally but the automated cleanup hook will not fire.
- GitHub Copilot extension

### Recommended Settings

Enable the built-in GitHub MCP server for seamless issue and PR workflows:

```json
{
  "github.copilot.chat.githubMcpServer.enabled": true
}
```

To make agents available globally across all VS Code workspaces (not just repos with `.github/agents/`), add:

```json
{
  "chat.agentFilesLocations": [
    "/absolute/path/to/your/workflow-template/.github/agents"
  ]
}
```

Replace the path with the absolute path to where you cloned this repository. This makes all agents available globally — 5 user-facing agents in the chat picker, plus 8 internal subagents used automatically by Code-Conductor.

To enable automatic skill discovery from `.github/skills/` (VS Code 1.108+):

```json
{
  "chat.useAgentSkills": true
}
```

This enables agents to interact directly with GitHub issues and PRs without external MCP server configuration.

### Session Cleanup Hook

This template includes a VS Code `SessionStart` hook (`.github/hooks/session-cleanup.json`) that automatically detects post-merge cleanup work at the start of each session. When merged feature branches have stale tracking files in `.copilot-tracking/`, the hook injects a prompt and the active agent asks you to confirm cleanup. Requires VS Code 1.109.3+ (Preview).

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

This repo is distributed as a VS Code agent plugin (VS Code 1.110+). When you add or change agents, skills, or commands (prompt files), those changes are automatically distributed to plugin users when they update. Instruction files, hooks, and repository templates are **not** distributed via the plugin.

When contributing new skills, the skill will appear in the plugin `plugin.json` — update `.github/plugin/plugin.json` to add the new skill path to the `"skills"` array. To bump the version across all files consistently when publishing a new release, run: `pwsh .github/scripts/bump-version.ps1 -Version X.Y.Z` (replacing `X.Y.Z` with the new version).

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
