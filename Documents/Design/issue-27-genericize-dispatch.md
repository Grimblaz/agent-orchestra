> **Superseded**: The dispatch workflow was removed in issue #31. This document is retained as historical context.

# Design: Genericize Dispatch Workflow and Remove Org References

**Issue**: #27
**Date**: 2026-02-23
**Status**: Finalized

## Summary

Rework the agent sync dispatch workflow to be a generic, consumer-agnostic notification mechanism. Remove all org-specific references from the template repo. Add dual-mode dispatch (streaming from `main` + stable from releases).

## Context

The template repo is a public product for any team. PR #26 introduced a dispatch workflow that hard-codes `Grimblaz-and-Friends/.github-private` as the target — coupling the library to a specific consumer. This design replaces it with a variable-driven, multi-consumer mechanism.

## Design Decisions

### 1. Variable-Driven Dispatch Targets

**Decision**: Use `vars.DOWNSTREAM_REPOS` (GitHub repo variable, JSON array) instead of hard-coded repo names.

**Rationale**: Any adopter can configure their own downstream repos without modifying the workflow file. Variables aren't publicly readable (require write access), so consumer repos remain private. Variables are editable in-place (unlike secrets which must be fully replaced).

**Format**: `["org1/repo-a", "org2/repo-b"]`

### 2. Dual-Mode Dispatch

**Decision**: Single workflow with two triggers — `push` (streaming) and `release` (stable).

| Trigger | Event Type Sent | When |
|---------|----------------|------|
| Push to `main` touching `.github/agents/**` | `agent-sync` | Every merge |
| Release published | `agent-release` | Manual release creation only |

**Rationale**: Consumers choose which event types to subscribe to. Streaming consumers get immediate updates from `main`. Stable consumers only receive formally tagged releases. One workflow file, minimal duplication.

### 3. Remove Canonical Repo Guard

**Decision**: Remove `github.repository == 'Grimblaz/workflow-template'` guard.

**Rationale**: Forks should be able to use this workflow without modification. The `vars.DOWNSTREAM_REPOS` check (`!= ''`) already provides a no-op default — if the variable isn't configured, nothing happens.

### 4. Matrix Strategy for Multi-Consumer

**Decision**: Use GitHub Actions `matrix` strategy to iterate over downstream repos.

**Rationale**: Naturally supports 1-N consumers. Each dispatch is independent — one consumer's failure doesn't block others. The matrix is populated from `vars.DOWNSTREAM_REPOS`.

### 5. Org Reference Cleanup

**Decision**: Remove or genericize all org-specific references in active code/docs.

| File | Action |
|------|--------|
| `.github/workflows/notify-agent-sync.yml` | Replace with generic version (this design) |
| `README.md` — "Related" section | Remove (org-specific links) |
| `README.md` — version badge | Update to `v1.3.2` |
| `Documents/Design/issue-17-sync-org-agents.md` | Archive to `.copilot-tracking-archive/` |

**Exclusions**: Historical closed issues (#17, #22) and merged PRs (#23, #26) are left as-is.

### 6. Sync Documentation

**Decision**: Add a "Downstream Sync" section to documentation explaining:

- How to configure `DOWNSTREAM_REPOS` and `AGENT_SYNC_PAT`
- Streaming vs stable event types
- Consumer-side workflow pattern

## Workflow Design

```yaml
name: Notify Agent Sync

on:
  push:
    branches: [main]
    paths: [.github/agents/**]
  release:
    types: [published]

permissions:
  contents: none

jobs:
  notify-downstream:
    if: vars.DOWNSTREAM_REPOS != '' && vars.DOWNSTREAM_REPOS != 'null'
    runs-on: ubuntu-latest
    strategy:
      fail-fast: false  # Allow other dispatches to continue if one target fails.
      matrix:
        repo: ${{ fromJSON(vars.DOWNSTREAM_REPOS) }}
    steps:
      - name: Dispatch agent-sync event
        env:
          AGENT_SYNC_PAT: ${{ secrets.AGENT_SYNC_PAT }}
          TARGET_REPO: ${{ matrix.repo }}
          SOURCE_REPO: ${{ github.repository }}
          SOURCE_SHA: ${{ github.sha }}
          EVENT_TYPE: ${{ github.event_name == 'release' && 'agent-release' || 'agent-sync' }}
        shell: bash
        run: |
          set -euo pipefail
          [ -n "${AGENT_SYNC_PAT:-}" ] || { echo "AGENT_SYNC_PAT not set" >&2; exit 1; }
          curl --fail --silent --show-error \
            -X POST \
            -H "Accept: application/vnd.github+json" \
            -H "Content-Type: application/json" \
            -H "Authorization: Bearer ${AGENT_SYNC_PAT}" \
            -H "X-GitHub-Api-Version: 2022-11-28" \
            "https://api.github.com/repos/${TARGET_REPO}/dispatches" \
            -d "{\"event_type\":\"${EVENT_TYPE}\",\"client_payload\":{\"source_repo\":\"${SOURCE_REPO}\",\"sha\":\"${SOURCE_SHA}\"}}"
```

## Consumer-Side Pattern

Consumers configure which events to subscribe to:

```yaml
# Streaming consumer (immediate updates from main):
on:
  repository_dispatch:
    types: [agent-sync]

# Stable consumer (only tagged releases):
on:
  repository_dispatch:
    types: [agent-release]

# Both (belt and suspenders):
on:
  repository_dispatch:
    types: [agent-sync, agent-release]
```
