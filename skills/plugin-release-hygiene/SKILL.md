---
name: plugin-release-hygiene
description: "Maintainer-side version-bump guardrail and Claude startup drift backstop guidance for plugin entry-point edits. Use when entry-point files change, when choosing patch/minor/major overrides, or when documenting/running the Claude plugin update surface. DO NOT USE FOR: CI release automation, registry publishing, or purely manual non-agent edit flows."
---

<!-- platform-assumptions: markdown skill guidance for VS Code custom agents in Agent Orchestra; assumes the skill is loaded by the plugin-distributed PostToolUse hook or a Copilot applyTo instruction when entry-point files are edited. -->
<!-- markdownlint-disable-file MD041 MD003 -->

# Plugin Release Hygiene

Reusable guidance for preventing plugin entry-point changes from shipping without a version bump and for keeping the Claude-side update surface explicit. The maintainer-side trigger now lives in the plugin-distributed `PostToolUse` hook declared in `hooks/hooks.json` and runs `skills/plugin-release-hygiene/scripts/plugin-release-hygiene-hook.ps1`.

## When to Use

- When an agent conversation edits an entry-point file that ships through the plugin cache
- When a maintainer needs a default bump proposal plus an override path
- When the repo must coalesce multiple entry-point edits into one conversation-scoped decision
- When documentation or startup logic needs the supported `claude plugin` command surface

## Entry-Point Scope

Treat these paths as cache-keyed plugin entry points:

- `agents/**`
- `commands/**`
- `skills/**`
- `.claude-plugin/**`
- `plugin.json`
- `README.md`
- `.github/copilot-instructions.md`

Any edit touching one of those paths requires a release-hygiene check before the turn ends.

## Purpose

Make the shipping consequence of an entry-point edit visible at the moment it happens. The default behavior is deterministic: propose a patch bump, offer a structured override for minor or major user-visible changes, or allow an explicit no-bump skip for comment-only edits. Coalesce that decision once per conversation so repeated edits do not spam the maintainer.

## Maintainer Flow

### 1. Determine Whether To Speak Or Stay Silent

Before proposing a bump, check the conversation-scoped state file at `.claude/.state/release-hygiene-{slug}.json`.

- If the file is absent, create proposal state and surface the bump prompt.
- If the file exists and `chosen_level` is already set, append the touched path to `touched_files` and stay silent.
- If the working copy already reflects a version bump relative to `main`, stay silent.
- If `.github/scripts/bump-version.ps1` is not findable from the repo root, stay silent. Consumer plugin-cache installs must not try to rewrite versions.

### 2. Default Classification

Default to `patch` for every entry-point edit. This is deterministic from the diff target, not from content inspection.

- `patch` — default for any publishable entry-point change, including doc-only changes
- `minor` — maintainer override for a new user-visible surface such as a new command, tool binding, or frontmatter field
- `major` — maintainer override for a breaking surface change
- `skip` — maintainer override for no-bump cases such as non-shipping comments or false-positive context

Do not introduce a content-sensitive classifier. The baseline rule is always-patch.

### 3. Proposal Text

Use this shape for the first proposal in a conversation:

> This edit touches `{path}`, which is cache-keyed by version. Proposing bump `{current}` -> `{next}` (`patch`: entry-point change so cached installs pick it up). Override if you wanted a different increment level.

Keep the reason to one line and keep the option labels short enough for a structured-question surface.

### 4. Structured Override

Offer exactly four choices through the platform's structured-question tool:

- `Patch`
- `Minor`
- `Major`
- `Skip`

Persist the chosen level in `.claude/.state/release-hygiene-{slug}.json` with this minimum shape:

```json
{
  "proposed_level": "patch",
  "chosen_level": "patch",
  "touched_files": ["agents/Experience-Owner.agent.md"]
}
```

The slug should use the issue number when one is known; otherwise fall back to the current branch name.

### 5. Apply The Bump

Resolve the repo root with `git rev-parse --show-toplevel`, then locate `.github/scripts/bump-version.ps1`. Compute the next semver from the current `.claude-plugin/plugin.json` version and the chosen level, then invoke the bump script once.

Do not hand-edit version strings after the repo is back in lockstep. `bump-version.ps1` is the authority for writing all 7 occurrences.

## Claude Plugin CLI Surface

These commands are part of the supported surface and should be documented consistently anywhere this skill is referenced:

```text
claude plugin list
claude plugin marketplace list
claude plugin marketplace update
claude plugin marketplace add <source>
claude plugin marketplace remove <name>
claude plugin update <plugin@marketplace>
claude plugin install <plugin@marketplace>
claude plugin uninstall <plugin@marketplace>
```

When a drift-check or maintainer flow needs one of these commands, attempt the command and parse the actual failure before claiming the surface is unavailable.

## Related Guidance

- Pair this skill with `session-startup` for the Claude-side active-assist drift backstop
- Keep the Copilot and Claude trigger mechanics in the skill's `platforms/` files, not in this shared body

## Gotchas

| Trigger                                        | Gotcha                                       | Fix                                                                                    |
| ---------------------------------------------- | -------------------------------------------- | -------------------------------------------------------------------------------------- |
| Multiple entry-point edits in one conversation | Repeated prompts turn a guardrail into noise | Record the first proposal in `.claude/.state/` and silently append later touched files |

| Trigger                                        | Gotcha                                                             | Fix                                                                      |
| ---------------------------------------------- | ------------------------------------------------------------------ | ------------------------------------------------------------------------ |
| Repo version files are already out of lockstep | `bump-version.ps1` refuses to write and the guardrail looks broken | Restore lockstep first, then let the bump script own all version updates |

---

## Platform-specific invocation

This skill's methodology is tool-agnostic. Platform-specific routing lives alongside:

- Copilot: [platforms/copilot.md](platforms/copilot.md)
- Claude Code: [platforms/claude.md](platforms/claude.md)
