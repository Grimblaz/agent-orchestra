---
name: process-retrospective
description: "Formalized skeleton for the process-retrospective frame port — trigger predicate deferred to issue #348. DO NOT USE directly: this port's applies-when condition is 'never' until #348 ships the live producer. See trigger-deferred-to and trigger-deferred-since below."
provides: process-retrospective
applies-when: never
trigger-status: deferred
trigger-deferred-to: '#348'
trigger-deferred-since: '2026-05-03'
---

<!-- platform-assumptions: markdown skill guidance for VS Code custom agents in Agent Orchestra; this skeleton is formalized but its trigger predicate is deferred — the port resolves to not-applicable on every PR until issue #348 ships the live producer. -->
<!-- markdownlint-disable-file MD041 MD003 -->

# Process Retrospective (Deferred Skeleton)

Formalized skeleton for the `process-retrospective` frame port. The port is declared and its credit row emitted as `DEFERRED(#348): ...` on every PR until issue #348 ships the live producer and trigger predicate.

## Deferral Status

| Field | Value |
|---|---|
| `trigger-status` | `deferred` |
| `trigger-deferred-to` | `#348` ("Thin Harness E — Close the learning loop") |
| `trigger-deferred-since` | `2026-05-03` |
| `applies-when` | `never` (deterministic false — deferred port) |

**What this means**: on every PR, the frame predicate evaluator resolves `never` to `false`, the port is excluded from the umbrella's 95% coverage denominator, and Code-Conductor emits a `DEFERRED(#348):` credit row via `Build-DeferredPortCreditRow`.

## When #348 Ships

Issue #348 ("Thin Harness E — Close the learning loop") will:

1. Replace `applies-when: never` with the real trigger predicate
2. Flip `trigger-status: deferred` → `trigger-status: live`
3. Remove `trigger-deferred-to` and `trigger-deferred-since` fields
4. Implement the retrospective content methodology in this SKILL.md body
5. Add the explicit-skip adapter per the port's skip contract

Until then, **this skeleton must not be invoked** — the `applies-when: never` frontmatter guarantees the port never triggers.

## #443 ↔ #348 Split Contract

Artifacts that are **stable** (must be preserved when #348 ships):

- `frame/ports/process-retrospective.yaml` port YAML (fields change, file persists)
- `skills/process-retrospective/SKILL.md` (this file; body replaces, frontmatter evolves)
- `skills/process-retrospective/adapters/explicit-skip-process-retrospective.md` (name persists)
- `DEFERRED(#348):` prefix as migration-detection contract (regex `^DEFERRED\(#\d+\):`)

Artifacts that are **scaffolding** (will be replaced by #348):

- The `applies-when: never` frontmatter line
- The `trigger-status: deferred` + `trigger-deferred-to` + `trigger-deferred-since` metadata
- The deferred skeleton body text in this file

## Frame Ports Filled By This Skill

| Port | Work adapter | Explicit-skip adapter |
|---|---|---|
| `process-retrospective` | This `SKILL.md` (skeleton — deferred, never triggers) | [adapters/explicit-skip-process-retrospective.md](adapters/explicit-skip-process-retrospective.md) |
