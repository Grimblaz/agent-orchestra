# Agent Plugin Distribution

**Status**: Implemented (PR #56)  
**Context**: VS Code 1.110 experimental plugin feature

---

## Problem

Users cloning or forking the full repository get 13 agents, 14 skills, and slash commands auto-discovered by VS Code. However this requires a repo copy — plugin-only install was not possible.

VS Code 1.110 introduced an experimental agent plugin system (`chat.plugins.enabled` setting) that allows distributing agents, skills, and slash commands via a GitHub-hosted manifest without requiring a clone.

---

## Decision: Add Plugin Manifests to `.github/plugin/`

Two manifest files were added under `.github/plugin/`:

| File | Purpose |
|------|---------|
| `plugin.json` | Declares plugin content: `agents`, `skills`, `commands` arrays pointing to paths within the repo |
| `marketplace.json` | Declares the plugin registry entry for `chat.plugins.marketplaces` lookup |

The `.github/plugin/` directory was chosen (rather than root) to keep plugin infrastructure co-located with other VS Code configuration (`.github/agents/`, `.github/skills/`, etc.).

### `plugin.json` Design

```json
{
  "agents": ["./.github/agents"],
  "skills": [ /* 14 individual skill directory paths */ ],
  "commands": [
    "./.github/prompts/setup.prompt.md",
    "./.github/prompts/start-issue.prompt.md"
  ]
}
```

- `agents`: Points to the agents directory. VS Code is expected to discover all `*.agent.md` files within it (spec unconfirmed — experimental).
- `skills`: Individual skill directory paths, matching the pattern used by default VS Code skill discovery.
- `commands`: Individual `.prompt.md` files with `agent: agent` frontmatter for slash command registration.

### `marketplace.json` Design

```json
{
  "name": "workflow-template",
  "metadata": {
    "description": "...",
    "version": "X.Y.Z"
  },
  "plugins": [
    {
      "name": "workflow-template",
      "source": ".",
      "version": "X.Y.Z"
    }
  ]
}
```

> **Note**: `marketplace.json` contains **two** `version` fields — `metadata.version` (top-level registry entry) and `plugins[0].version` (the plugin itself). Both must be kept in sync. The `bump-version.ps1` script updates both automatically; do not remove the `metadata` block as it will cause the script to fail.

`source: "."` refers to the repo root, where VS Code will look for `plugin.json`. The file lives at `.github/plugin/marketplace.json` — VS Code is pointed here via `chat.plugins.marketplaces: ["Grimblaz/workflow-template"]` (lookup path is experimental/unconfirmed).

---

## Known Risks

### R1 — `agents` directory vs. individual files (unresolvable without VS Code 1.110 runtime)

The `agents` field uses a directory path `["./.github/agents"]`. If VS Code requires individual `.agent.md` file paths (matching the skills pattern), all 13 agents fail to load silently. **Mitigation**: Monitor first install test against VS Code 1.110 EA.

### R2 — `marketplace.json` lookup path (unresolvable without VS Code 1.110 runtime)

If VS Code resolves `chat.plugins.marketplaces: ["Grimblaz/workflow-template"]` to the repo root (GitHub convention), `marketplace.json` at `.github/plugin/` won't be found. **Mitigation**: If plugin install fails, move `marketplace.json` to the repo root and update `source` to point to `.github/plugin/`.

---

## Plugin vs. Clone/Fork Coverage Gap

| Feature | Plugin | Clone/Fork |
|---------|--------|------------|
| 13 agents | ✅ | ✅ |
| 14 skills | ✅ | ✅ |
| `/setup`, `/start-issue` slash commands | ✅ | ✅ |
| `.github/instructions/` (shared rules, incl. `session-startup`) | ❌ not distributed | ✅ auto-discovered |
| `.github/scripts/` (cleanup script) | ❌ not distributed | ✅ |

Plugin users relying on `post-pr-review` skill Step 1 (preferred cleanup script) must use the manual archive method — the `$env:WORKFLOW_TEMPLATE_ROOT` path is unavailable in plugin-only setups. The skill's Step 1 includes a disclaimer for this case.

---

## Version Policy

Plugin version tracks the project's semantic version from the README badge. Both `plugin.json` and `marketplace.json` `version` fields must be updated to match when publishing a release. See `CONTRIBUTING.md` for update procedure.
