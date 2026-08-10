# Release Lens Exhibits

The incident detail behind `skills/plugin-release-hygiene/SKILL.md` § Release Lenses. The rule lives in the lens; this file carries only what happened.

## Contents

- [Two branches at 3.12.0](#two-branches-at-3120)

## Two branches at 3.12.0

*Cited from § Two branches can bump to the same version, and each one is internally consistent.*

`bump-version.ps1` writes a version across seven occurrences in five files — `plugin.json`, `.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json`, `.github/plugin/marketplace.json` and `README.md` — plus the `CHANGELOG.md` entry when one is supplied. It does not check whether the version it is writing has already been taken on `main`.

On 2026-08-05, issue #998's branch bumped to `3.12.0`. `main` had already shipped `3.12.0` for #986. Neither branch could detect the other: each was internally consistent, so the release gate passed, CI passed, the changelog entry read correctly, and the developer's own plugin cache agreed with the branch it was built from. The collision surfaced only at the merge, as a simultaneous conflict across all five version-bearing files plus `CHANGELOG.md`. It was resolved by renumbering to `3.13.0`.

The record notes three prior collisions of the same shape, which is what produced issue #864.

Why this costs more than tidiness: Claude Code keys its plugin cache by this version number. Two different code trees published under one version mean a same-version install keeps serving whichever snapshot it cached first — the exact staleness the version bump exists to prevent, failing silently rather than loudly.

Issue #1050's own delivery hit the same class twice in a single session. Its branch stood at `3.21.0` while `main` had shipped `3.21.1`; after merging `main` and bumping to `3.22.0`, `main` moved again to `3.21.2` before the branch landed, producing a second conflict across the same five files plus the changelog. Both times the resolution was the same: read `main` first, then re-bump.

Two riders from the same record. Changelog ordering is a separate resolution from the version number — `main` may carry an `[Unreleased]` section that must stay on top while the new version slots beneath it. And after any scripted changelog merge, verify the encoding: a stray byte-order mark, `U+FFFD` replacement characters, and lost em-dashes are the three that recur.
