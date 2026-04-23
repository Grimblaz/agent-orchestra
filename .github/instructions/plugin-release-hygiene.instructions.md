---
applyTo: "agents/**,commands/**,skills/**,.claude-plugin/**,plugin.json,README.md,.github/copilot-instructions.md"
---

# Plugin Release Hygiene

When the current conversation edits any file matched by `applyTo`, load the `plugin-release-hygiene` skill before the turn ends.

Follow the skill for:

- the always-patch default proposal
- the `Patch` / `Minor` / `Major` / `Skip` override choices
- conversation-scoped coalescing via `.claude/.state/release-hygiene-{slug}.json`
- the `bump-version.ps1` findability gate and version-bump procedure

If a release-hygiene state file already exists for the current conversation and the chosen level still applies, reuse it silently instead of re-prompting.
