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
    "./.github/prompts/start-issue.prompt.md",
    "./.github/prompts/design.prompt.md",
    "./.github/prompts/plan.prompt.md",
    "./.github/prompts/implement.prompt.md",
    "./.github/prompts/review.prompt.md",
    "./.github/prompts/polish.prompt.md"
  ]
}
```

- `agents`: Points to the agents directory. VS Code is expected to discover all `*.agent.md` files within it (spec unconfirmed — experimental).
- `skills`: Individual skill directory paths, matching the pattern used by default VS Code skill discovery.
- `commands`: Individual `.prompt.md` files for slash command registration. Legacy commands (`/setup`, `/start-issue`) use `agent: agent` frontmatter; the 5 new commands (`/design`, `/plan`, `/implement`, `/review`, `/polish`) use `agent: {mode-name}` frontmatter to route directly to a named agent mode. See R4 below — named-agent routing is unconfirmed in the experimental plugin system.

### `marketplace.json` Design

```json
{
  "name": "copilot-orchestra",
  "metadata": {
    "description": "...",
    "version": "X.Y.Z"
  },
  "plugins": [
    {
      "name": "copilot-orchestra",
      "source": ".",
      "version": "X.Y.Z"
    }
  ]
}
```

> **Note**: `marketplace.json` contains **two** `version` fields — `metadata.version` (top-level registry entry) and `plugins[0].version` (the plugin itself). Both must be kept in sync. The `bump-version.ps1` script updates both automatically; do not remove the `metadata` block as it will cause the script to fail.

`source: "."` refers to the repo root, where VS Code will look for `plugin.json`. The file lives at `.github/plugin/marketplace.json` — VS Code is pointed here via `chat.plugins.marketplaces: ["Grimblaz/copilot-orchestra"]` (lookup path is experimental/unconfirmed).

---

## Known Risks

### R1 — `agents` directory vs. individual files (unresolvable without VS Code 1.110 runtime)

The `agents` field uses a directory path `["./.github/agents"]`. If VS Code requires individual `.agent.md` file paths (matching the skills pattern), all 13 agents fail to load silently. **Mitigation**: Monitor first install test against VS Code 1.110 EA.

### R2 — `marketplace.json` lookup path (unresolvable without VS Code 1.110 runtime)

If VS Code resolves `chat.plugins.marketplaces: ["Grimblaz/copilot-orchestra"]` to the repo root (GitHub convention), `marketplace.json` at `.github/plugin/` won't be found. **Mitigation**: If plugin install fails, move `marketplace.json` to the repo root and update `source` to point to `.github/plugin/`.

### R3 — Agent file duplication when multiple configuration sources overlap (confirmed VS Code behavior)

VS Code loads agent files **additively** from all configured sources — there is no name-based deduplication. If a user configures multiple sources that each distribute the same agents, every agent will appear multiple times in the chat picker. Skills and prompt files are handled by priority instead and do not duplicate.

**Observed trigger conditions** (any combination causes duplicates):

| Scenario | Affected settings | Duplicate items |
|----------|-------------------|------------------|
| Plugin installed + clone has `.github/agents/` (any workspace) | `chat.plugins.marketplaces` + workspace auto-discovery | All 13 agents |
| Plugin installed + `chat.agentFilesLocations` pointing to clone | `chat.plugins.marketplaces` + `chat.agentFilesLocations` | All 13 agents |
| Global `chat.agentFilesLocations` + workspace `.github/agents/` | `chat.agentFilesLocations` + workspace auto-discovery | All 13 agents |
| Global `chat.agentFilesLocations` + per-project `chat.agentFilesLocations` | Both `chat.agentFilesLocations` entries combined | All 13 agents |

**Not affected** (plugin does not distribute these):

- `chat.agentSkillsLocations` — safe to keep alongside the plugin; skills are handled by priority, no duplication
- `chat.instructionsFilesLocations` — safe to keep alongside the plugin; the plugin does not distribute `.github/instructions/` files

### R4 — Named-agent routing in slash commands (unresolvable without VS Code 1.110 runtime)

The 5 new slash commands (`/design`, `/plan`, `/implement`, `/review`, `/polish`) use `agent: {mode-name}` frontmatter (e.g., `agent: Issue-Designer`) to route directly to a named agent mode. The 2 legacy commands (`/setup`, `/start-issue`) use `agent: agent`. VS Code 1.110's plugin `commands` mechanism's behavior with named-agent values is unverified. **Failure mode**: if VS Code requires `agent: agent` for slash command registration, the 5 new commands may fail to appear in the chat picker or may route incorrectly. **Mitigation**: If routing fails during testing, fall back to `agent: agent` with explicit agent-mode instructions in each prompt body — update `plugin.json` unchanged (file paths remain valid), only the frontmatter values require correction.

- `chat.promptFilesLocations` — likely safe to keep alongside the plugin; the plugin distributes prompt files as slash `commands` (not via `promptFilesLocations`), and VS Code 1.110 is expected to deduplicate slash commands by ID, though this is unconfirmed for the experimental plugin system

**Mitigation**: Use only one distribution source for agents — either the plugin OR a clone/global path, not both. See CUSTOMIZATION.md for guidance on choosing a distribution model.

---

## Plugin vs. Clone/Fork Coverage Gap

| Feature | Plugin | Clone/Fork |
|---------|--------|------------|
| 13 agents | ✅ | ✅ |
| 14 skills | ✅ | ✅ |
| `/setup`, `/start-issue`, `/design`, `/plan`, `/implement`, `/review`, `/polish` slash commands | ✅ | ✅ |
| `/release` slash command | ❌ not in plugin.json | ✅ auto-discovered |
| `.github/instructions/` (shared rules; `session-startup` operational content inlined into `.github/copilot-instructions.md`) | ❌ not distributed | ✅ auto-discovered |
| `.github/scripts/` (cleanup script) | ❌ not distributed | ✅ |

Plugin users relying on `post-pr-review` skill Step 1 (preferred cleanup script) must use the manual archive method — the `$env:COPILOT_ORCHESTRA_ROOT` (or `WORKFLOW_TEMPLATE_ROOT`) path is unavailable in plugin-only setups. The skill's Step 1 includes a disclaimer for this case.

### Workarounds for Plugin-Only Users

| Gap | Workaround |
|-----|------------|
| Missing `.github/instructions/` | Clone the repo first (if you haven't already), then add `chat.instructionsFilesLocations` pointing to the clone — this is safe to combine with the plugin since the plugin does not distribute instruction files |
| Missing `.github/scripts/` (cleanup script) | Use the manual archive method documented in the `post-pr-review` skill |
| Choosing between plugin and clone | See [CUSTOMIZATION.md — Distribution Options](../../CUSTOMIZATION.md#distribution-options) for a decision guide |

---

## Version Policy

Plugin version tracks the project's semantic version from the README badge. Both `plugin.json` and `marketplace.json` `version` fields must be updated to match when publishing a release. See `CONTRIBUTING.md` for update procedure.
