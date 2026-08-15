# Release Lens Exhibits

The incident detail behind `skills/plugin-release-hygiene/SKILL.md` § Release Lenses. The rule lives in the lens; this file carries only what happened.

## Contents

- [Two branches at 3.12.0](#two-branches-at-3120)

## Two branches at 3.12.0

*Cited from § Two branches can bump to the same version, and each one is internally consistent.*

`bump-version.ps1` writes a version across seven occurrences in five files — `plugin.json`, `.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json`, `.github/plugin/marketplace.json` and `README.md` — plus the `CHANGELOG.md` entry when one is supplied. It does not check whether the version it is writing has already been taken on `main`.

On 2026-08-05, issue #998's branch bumped to `3.12.0`. `main` had already shipped `3.12.0` for #986. Neither branch could detect the other: each was internally consistent, so the release gate passed, CI passed, the changelog entry read correctly, and the developer's own plugin cache agreed with the branch it was built from. The collision surfaced only at the merge, as a simultaneous conflict across all five version-bearing files plus `CHANGELOG.md`. It was resolved by renumbering to `3.13.0`.

The record notes three prior collisions of the same shape, which is what produced issue [#864](https://github.com/Grimblaz/agent-orchestra/issues/864) — **still open**, and the owner of the structural fix.

Why this costs more than tidiness, in two parts. Claude Code keys its plugin cache by this version number, so two different code trees published under one version mean a same-version install keeps serving whichever snapshot it cached first — the exact staleness the version bump exists to prevent, failing silently rather than loudly. And #864 records the sharper harm: while the losing PR sits in `CONFLICTING`, GitHub cannot build a merge ref, so every `pull_request`-triggered workflow silently does not run and `gh pr checks` goes on reporting the previous commit's results. "No workflow ran" and "every workflow passed" are indistinguishable at a glance, which is why these collisions were noticed late rather than immediately.

What the shipped gate does and does not cover, since the first three incidents predate it: `.github/scripts/release-gate.ps1` landed 2026-06-21 under #703 and compares the head's version against a freshly fetched base with a strict `>`. That is #864's fix shape 2, and it means a same-number PR cannot merge green once its conflicts are resolved. It does not close the class — it passes for both branches while both are open, does not re-run when the base moves under an idle PR, and is itself suppressed while a PR is conflicted.

Issue #1050's own delivery hit **two adjacent failures in a single session, and they are not the same shape** — worth separating, because they need different triggers. First: its branch stood at `3.21.0` while `main` had already shipped `3.21.1` — a stale-lower number, caught by reading `main` before bumping. Second: after merging `main` and bumping to `3.22.0`, `main` moved again to `3.21.2` before the branch landed. That one produced a version-line conflict rather than a duplicate number, and reading `main` at bump time could not have prevented it — only a re-check immediately before landing would have. A remedy aimed only at the first shape leaves the second open.

A residue the remedy does not reach: re-running the script fixes the seven version occurrences and the changelog, and touches nothing else. On `main`, commit `d610bbe` still carries the subject `feat(#1049): promote 19 maintainer lessons behind a standing firing check (3.19.0) (#1055)` while its own `.claude-plugin/plugin.json` reads `3.21.0` — the branch had bumped to `3.19.0`, which #1052 had already shipped, and was renumbered before landing without the commit subject following. The changelog is correct; only the subject lies. `git log --oneline | grep 3.19.0` now returns two commits for one shipped version. This is a fourth instance of the class, produced by chunk 1 of the very umbrella that promoted this lens.

One rider from the same record. Changelog ordering is a separate resolution from the version number — `main` may carry an `[Unreleased]` section that must stay on top while the new version slots beneath it. Verify the encoding after any scripted changelog merge; a stray byte-order mark, `U+FFFD` replacement characters, and dropped em-dashes are the shapes worth checking for, though this record does not establish how often each recurs.
