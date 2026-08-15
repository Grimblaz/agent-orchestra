---
name: plugin-release-hygiene
description: "Maintainer-side version-bump guardrail and Claude startup drift backstop guidance for plugin entry-point edits. Use when entry-point files change, when choosing patch/minor/major overrides, when documenting/running the Claude plugin update surface, or when bumping a version another branch may already have taken. DO NOT USE FOR: CI release automation, registry publishing, or purely manual non-agent edit flows."
provides: release-hygiene
suggested-next-step: pwsh ./skills/plugin-release-hygiene/scripts/plugin-release-hygiene-hook.ps1
applies-when: changeset.touchesPluginEntryPoint()
---

<!-- platform-assumptions: markdown skill guidance for VS Code custom agents in Agent Orchestra; assumes the skill is loaded by the plugin-distributed PostToolUse hook or a Copilot applyTo instruction when entry-point files are edited. -->
<!-- markdownlint-disable-file MD041 MD003 -->

# Plugin Release Hygiene

Reusable guidance for preventing plugin entry-point changes from shipping without a version bump and for keeping the Claude-side update surface explicit. The maintainer-side trigger now lives in the plugin-distributed `PostToolUse` hooks declared in `hooks/hooks.json` for Claude and `hooks.json` for Copilot, both of which run `skills/plugin-release-hygiene/scripts/plugin-release-hygiene-hook.ps1`.

> **Survival**: `SMC-12` governs `.claude/.state/release-hygiene-{slug}.json`. State is `within-conversation:session_id` when the hook payload supplies `session_id`; otherwise it is `within-worktree:hooks` keyed by branch slug, then short HEAD SHA, then `session` fallback. Cross-tool silence is partial: Claude may key by `session_id` while Copilot keys by branch slug, so both surfaces share a decision only when they resolve the same state file. The SHA and final fallback paths record `keying_strategy: session_fallback`.

## When to Use

- When an agent conversation edits an entry-point file that ships through the plugin cache
- When a maintainer needs a default bump proposal plus an override path
- When the repo must coalesce multiple entry-point edits into one scoped decision
- When documentation or startup logic needs the supported `claude plugin` command surface

## Entry-Point Scope

Treat these paths as cache-keyed plugin entry points:

- `agents/**`
- `commands/**`
- `skills/**`
- `hooks/**`
- `.claude-plugin/**`
- `plugin.json`
- `README.md`
- `.github/copilot-instructions.md`

> **Authoritative source**: The canonical entry-point set is defined by `Get-FVPluginEntryPointPatterns` in `.github/scripts/lib/frame-predicate-core.ps1`. The list above mirrors it; `.github/scripts/Tests/entry-point-scope-parity.Tests.ps1` permanently prevents drift between this prose and the function.

Any edit touching one of those paths requires a release-hygiene check before the turn ends.

## Purpose

Make the shipping consequence of an entry-point edit visible at the moment it happens. The default behavior is deterministic: propose a patch bump, offer a structured override for minor or major user-visible changes, or allow an explicit no-bump skip for comment-only edits. Coalesce that decision once per active state key so repeated edits do not spam the maintainer.

## Composite References

- [references/release-exhibits.md](references/release-exhibits.md): the incident detail behind § Release Lenses — the collision this repository actually hit, the files it conflicted across, and how it was resolved

## Maintainer Flow

### 1. Determine Whether To Speak Or Stay Silent

Before proposing a bump, check the active scoped state file at `.claude/.state/release-hygiene-{slug}.json`.

- If the file is absent, create proposal state and surface the bump prompt.
- If the file exists and `chosen_level` is already set, append the touched path to `touched_files` and stay silent.
- If the working copy already reflects a version bump relative to `main`, stay silent.
- If `.github/scripts/bump-version.ps1` is not findable from the repo root, stay silent. Consumer plugin-cache installs must not try to rewrite versions.

For Claude Code, prefer the hook payload's `session_id` as the slug source so branch switches inside one conversation reuse the same state file. Fall back to the existing branch-derived slug when `session_id` is absent. If branch resolution also fails, use the short HEAD SHA when available; use `session` only as the final fallback.

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

Keep the reason to one line and keep each option label to a few words, so the four choices stay scannable side by side.

### 4. Structured Override

Offer exactly four choices:

- `Patch`
- `Minor`
- `Major`
- `Skip`

Persist the chosen level in `.claude/.state/release-hygiene-{slug}.json` with this minimum shape:

```json
{
  "proposed_level": "patch",
  "chosen_level": "patch",
  "keying_strategy": "session_id",
  "touched_files": ["agents/Experience-Owner.agent.md"]
}
```

Allowed `keying_strategy` values are `session_id`, `branch_slug`, and `session_fallback`.

### 5. Apply The Bump

Resolve the repo root with `git rev-parse --show-toplevel`, then locate `.github/scripts/bump-version.ps1`. **Compute the next semver from the default branch's version, not your branch's**, and read it *fresh* — `git show` performs no network update, so an unfetched `origin/main` is whatever your last fetch left behind:

```powershell
git fetch origin main --quiet
git show origin/main:.claude-plugin/plugin.json
```

Run that in `pwsh`. Under Git Bash on Windows, MSYS argument conversion rewrites the ref-and-path argument into `origin\main;.claude-plugin\plugin.json` and `git show` exits 128 with `fatal: ambiguous argument`; prefix `MSYS_NO_PATHCONV=1` if you must run it there. If the ref cannot be resolved at all — a fork whose default branch is not `main`, or a checkout with no such remote-tracking ref — resolve the default branch the way this skill's own hook does (`Get-PRHDefaultBranch` in `scripts/plugin-release-hygiene-hook.ps1`, which walks a six-rung ladder rather than assuming the name). If it still cannot be read, say so and stop. Do not fall back to the branch-local value: that fallback is the whole defect this step exists to remove.

*(Corrected under issue #1051, parent #1045 amendment A5.2: this step read "from the current `.claude-plugin/plugin.json` version", which is the branch-local increment that produces two internally-consistent branches on one number.)*

**What reading the default branch does and does not prevent.** It tells you what has *landed*, not what an open PR has already *claimed*. Two branches cut from the same base both read the same version and both derive the same next one — the collision in the lens below, and the one this repository was sitting in when this step was written. To check what is claimed rather than what has landed, read the open PR heads:

```powershell
gh pr list --state open --json number,headRefName
```

`.github/scripts/release-gate.ps1` is a **landing backstop, not a prevention**: it compares the head's version against a freshly fetched base with a strict `>`, so a same-number PR cannot merge green once its conflicts are resolved — but it passes for *both* branches while both are open, it does not re-run when the base moves underneath an idle PR, and a `CONFLICTING` PR suppresses `pull_request` workflows entirely, so what you actually see is a stale green rather than a red. The structural fix is tracked in [#864](https://github.com/Grimblaz/agent-orchestra/issues/864).

**Re-check before landing, not only after a merge.** A bump that was valid when made can collide later, and the two ways it happens need different triggers: `main` advancing *underneath* an idle branch is not a merge your branch performs, so "re-check after merging" never fires for it. Re-check after any merge of `main` into your branch **and again immediately before you land**. Re-run the script with the next free number rather than hand-editing — see the occurrence-count note below. If the delay pushed the release past the date already written into the changelog, re-run so the date matches the release rather than the bump. Issue #1050's own run hit this twice in one session: the branch stood at `3.21.0` while `main` had shipped `3.21.1`, and after merging, `main` moved again to `3.21.2` before the branch landed at `3.22.0`.

Before invoking the script, construct a categorized CHANGELOG entry body. Group changes into the appropriate subsection(s) — `Fixed`, `Added`, or `Changed` — as a markdown bullet list. Pass the body as `-ChangelogEntry` and the primary category as `-ChangelogSection`. The script uses today's date internally (`Get-Date -Format 'yyyy-MM-dd'`); the caller only supplies the body.

Example invocation:

```powershell
$body = @"
- Brief description of what changed (#issue).
"@
pwsh .github/scripts/bump-version.ps1 -Version <nextVersion> -ChangelogEntry $body -ChangelogSection 'Fixed'
```

Use `'Added'` when the primary change introduces a new user-visible surface, `'Fixed'` for bug fixes, and `'Changed'` for other modifications. When a release spans multiple categories, pass the dominant category as `-ChangelogSection` and include all bullets in `-ChangelogEntry` — the entry body may contain multiple `### SubSection` headings if needed, but must not contain a `## [X.Y.Z]` release header (the script synthesizes that).

The script inserts the CHANGELOG section above the most-recent existing `## [X.Y.Z]` heading (em-dash, en-dash, or hyphen separator are all recognized). If the section for the new version already exists, the script skips insertion silently (idempotent).

Do not hand-edit version strings after the repo is back in lockstep. `bump-version.ps1` is the authority for writing all 7 occurrences and the CHANGELOG entry.

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

## Release Lenses

> **Authoritative source**: which lessons are promoted here, what anchor each one lives at, and the trigger text that has to reach a reader are recorded in `Documents/Planning/lesson-promotion-manifest.json`. `.github/scripts/Tests/lesson-promotion-manifest.Tests.ps1` is what stops this section and that manifest drifting apart, and it is the suite a red comes from. **Renaming a heading below is a migration, not a regression** — update that lesson's `anchor` in the manifest in the same commit as the rename. A red naming an anchor you just renamed is reporting a manifest row left behind, not a lost lens.

One way a bump that is correct when you make it is wrong by the time it lands.

### When you are choosing a version number, or landing after a merge

#### Two branches can bump to the same version, and each one is internally consistent

`bump-version.ps1` writes a version across several occurrences in several files and does **not** check whether that number is already taken — not on `main`, and not on another open PR. So two branches cut from the same base both read the same current version, both derive the same next one, and each stays internally consistent: the changelog entry looks right and the developer's own plugin cache agrees. It surfaces at the merge, as a simultaneous conflict across every version-bearing file plus the changelog. **Read `main`'s current version before bumping** rather than incrementing from your own branch's value — § 5 above carries the command, the fetch it depends on, and the shell it actually runs in — and **re-check immediately before you land**, not only after a merge: `main` advancing underneath an idle branch is not a merge your branch performs, so a re-check keyed to merging never fires for it. Re-run the script rather than hand-editing; the occurrence count across files is more than you will remember to fix by hand.

Be precise about what catches this and what does not, because the difference decides what you are entitled to trust. `.github/scripts/release-gate.ps1` compares the head's version against a freshly fetched base with a strict `>`, so a same-number PR cannot *merge* green once its conflicts are resolved — that much is guarded, and it is issue #864's fix shape 2, already shipped. But it is a landing backstop and nothing earlier: it passes for **both** branches while both are open, and it does not re-run when the base moves under an idle PR. The window between the two bumps is unguarded. Worse, the moment the first branch merges, the loser goes `CONFLICTING`, GitHub cannot build a merge ref, and every `pull_request` workflow silently does not run while `gh pr checks` keeps reporting the previous commit's results — **"no workflow ran" and "every workflow passed" look identical at a glance.** The signal you would use to notice the collision is the one the collision switches off. Structural work is open at [#864](https://github.com/Grimblaz/agent-orchestra/issues/864); until it lands, checking the open PR heads is the only way to see a number that is claimed but not landed.

Why it matters past tidiness: Claude Code keys its plugin cache by this version, so two different trees published under one number means a same-version install keeps serving whichever snapshot it cached first — the exact staleness the bump exists to prevent, failing silently. Changelog ordering is a separate resolution from the number. Exhibit: [references/release-exhibits.md](references/release-exhibits.md) § Two branches at 3.12.0.

## Related Guidance

- Pair this skill with `session-startup` for the Claude-side active-assist drift backstop
- Keep the Copilot and Claude trigger mechanics in the skill's `platforms/` files, not in this shared body

## Gotchas

| Trigger                                        | Gotcha                                       | Fix                                                                                    |
| ---------------------------------------------- | -------------------------------------------- | -------------------------------------------------------------------------------------- |
| Multiple entry-point edits in one conversation | Repeated prompts turn a guardrail into noise | Record the first proposal in `.claude/.state/` and silently append later touched files |

| Trigger                                         | Gotcha                                                                | Fix                                                                                                |
| ----------------------------------------------- | --------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------- |
| `session_id` is missing or payload shape drifts | A branch-scoped fallback can look like a silent regression in reviews | Persist `keying_strategy` so tests and future reviews can observe which keying path actually fired |

| Trigger                                        | Gotcha                                                             | Fix                                                                      |
| ---------------------------------------------- | ------------------------------------------------------------------ | ------------------------------------------------------------------------ |
| Repo version files are already out of lockstep | `bump-version.ps1` refuses to write and the guardrail looks broken | Restore lockstep first, then let the bump script own all version updates |

---

## Frame Ports Filled By This Skill

| Port | Work adapter | Explicit-skip adapter |
| --- | --- | --- |
| `release-hygiene` | This `SKILL.md` frontmatter declares `provides: release-hygiene` and `applies-when: changeset.touchesPluginEntryPoint()` | [adapters/release-hygiene-explicit-skip-adapter.md](adapters/release-hygiene-explicit-skip-adapter.md) |

## Platform-specific invocation

This skill's methodology is tool-agnostic. Platform-specific routing lives alongside:

- Copilot: [platforms/copilot.md](platforms/copilot.md)
- Claude Code: [platforms/claude.md](platforms/claude.md)
