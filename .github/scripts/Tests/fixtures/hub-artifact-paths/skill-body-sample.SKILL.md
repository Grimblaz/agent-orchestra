# Sample Skill Body

Fixture for hub-artifact-paths extraction grammar tests — skill body scope.

## Overview

This skill demonstrates backtick-fenced path references that must be extracted by
the audit grammar.

## Cross-skill dependencies

For BDD generation rules, load `skills/bdd-scenarios/SKILL.md`.
Session lifecycle management is covered by `skills/session-startup/SKILL.md`.

## Excluded patterns (must NOT be extracted)

Tool-name backtick: `Write`
Another tool: `Edit`
Marker template: <!-- design-phase-complete-{ID} -->
URL: https://github.com/Grimblaz/agent-orchestra/issues
CLI flag: --%
