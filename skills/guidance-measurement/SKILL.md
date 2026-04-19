---
name: guidance-measurement
description: Guidance-complexity measurement tooling and usage notes. Use when running or maintaining the guidance measurement script and related deterministic analysis assets for issue #360. DO NOT USE FOR: changing D10 ceiling rules or prompt-facing guidance policy, which remain in agent prompts.
---

# Guidance Measurement

This skill owns deterministic tooling for measuring guidance complexity without moving the D10 ceiling rules themselves out of agent prompts.

## Purpose

- Describe the measurement domain for issue #360
- Provide the stable home for measurement scripts under `scripts/`
- Keep tooling separate from prompt-owned guidance rules

## Contents

- `scripts/` contains the guidance measurement CLI wrapper and core implementation
- Future supporting assets should stay next to this skill only if they are measurement-specific

## Boundary

- The D10 ceiling and prompt guidance rules stay in agent prompts and are not migrated here
- This skill is only for measurement and deterministic analysis support

## Gotchas

| Trigger                 | Gotcha                                                                  | Fix                                                                            |
| ----------------------- | ----------------------------------------------------------------------- | ------------------------------------------------------------------------------ |
| Moving guidance tooling | The measurement script gets confused with the prompt-owned D10 rule set | Keep measurement code here and leave the actual ceiling rules in agent prompts |
