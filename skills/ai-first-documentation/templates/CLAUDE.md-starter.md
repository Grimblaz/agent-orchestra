<!-- CLAUDE.md starter — minimal seed. Prune ruthlessly: each line must pass the deletion test.
     A6 is a checklist; include only sections that are non-obvious from the code. -->

# [CUSTOMIZE: Project Name]

<!-- deletion test: remove if the purpose is obvious from repo name or README -->
[CUSTOMIZE: One sentence — what this repo does and who uses it.]

## Build & Test
<!-- deletion test: keep only non-guessable commands; omit `npm test` if that is the obvious default -->
[CUSTOMIZE: e.g., `pwsh ./scripts/run-tests.ps1`, `make build`]

## Key Conventions
<!-- deletion test: omit anything a reader would infer from the code or standard toolchain -->
[CUSTOMIZE: e.g., "All PRs require a linked test; no `any` casts in TypeScript."]

## Architecture Notes
<!-- deletion test: omit standard patterns; include only non-obvious seams or load-bearing constraints -->
[CUSTOMIZE: e.g., "The event bus in src/bus/ is the only allowed cross-module communication path."]

## Agent Guidance
<!-- deletion test: include only if agents commonly make the wrong call here without this hint -->
[CUSTOMIZE: e.g., "Never modify files under /src/generated/ — they are auto-regenerated on build."]

## Gotchas
<!-- deletion test: production incidents and non-obvious environment traps only -->
[CUSTOMIZE: e.g., "Env vars must be in .env.local; .env is gitignored and never read at runtime."]
