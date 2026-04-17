---
name: routing-tables
description: Concise reference for deterministic specialist dispatch, review mode routing, CE surface mapping, enum values, and gate criteria extracted from current orchestration agents. Use when an agent or script needs the canonical current routing data without re-deriving it from duplicated prompt prose. DO NOT USE FOR: taking orchestration decisions away from the calling agent, replacing judgment on uncovered cases, or storing mutable runtime state.
---

# Routing Tables

This skill is the human-readable companion to the routing data in `assets/routing-config.json` and `assets/gate-criteria.json`. It centralizes current routing tables and enum values from Code-Conductor and Code-Critic so agents can load concise prompt context while future deterministic consumers read the same data from JSON.

## When to Use

- When an agent needs the canonical current specialist-dispatch, review-mode, CE-surface, enum, or gate data
- When a deterministic consumer should read the shared routing assets instead of copying inline tables from an agent prompt
- When reviewing or updating routing metadata and you need one human-readable summary aligned with the JSON assets

## Schema Overview

`assets/routing-config.json` contains five top-level sections:

- `specialist_dispatch`: file and task routing entries from Code-Conductor's Agent Selection table; deterministic `FilePattern` consumers should use the optional `file_patterns` arrays rather than parsing `file_type_or_task`
- `review_mode_routing`: prompt-marker to review-mode mapping from Code-Critic, including conflict resolution
- `surface_identification`: CE Gate surface to tool mapping from Code-Conductor; `No customer surface` carries the exact status marker template in `status_result_template`
- `skill_mapping`: delegation guidance from Code-Conductor's Skill Mapping table; this is a reference list, not a strict deterministic router
- `enums`: canonical current enum values used by review and routing outputs

`assets/gate-criteria.json` contains three top-level sections:

- `scope_classification`: abbreviated-vs-full pipeline gate criteria and tier table
- `express_lane`: low-risk fix gate criteria for routing findings directly to a specialist
- `post_fix_trigger`: conditions that require post-fix targeted prosecution after accepted review fixes

## Specialist Dispatch

Specialist dispatch stays file- and task-oriented. Test files and fixtures route to Test-Writer. New behavior in `src/**/*.ts` and `src/**/*.tsx` routes to Code-Smith, while restructuring those same source files routes to Refactor-Specialist. PowerShell production scripts (`*.ps1`) also route to Code-Smith. Visual polish work on UI source files routes to UI-Iterator, and documentation files route to Doc-Keeper.

For deterministic lookups keyed by `FilePattern`, use the structured `file_patterns` arrays in the asset. The prose-bearing `file_type_or_task` field remains the human-readable summary and should not be parsed by consumers.

Planning artifacts and plan markers route to Issue-Planner. CE Gate evidence capture, customer framing, journeys, and scenarios route to Experience-Owner. Read-only quality review goes to Code-Critic, scored judgment goes to Code-Review-Response, and systemic gap analysis goes to Process-Review.

## Review Mode Routing

Review mode routing is driven by prompt markers. No marker means normal code prosecution with three parallel passes. Design review perspectives switch to design or plan prosecution with two parallel passes. Product-alignment, defense, CE prosecution, and GitHub proxy prosecution each run as single-pass modes.

When multiple markers appear, the conflict rule applies in strict priority order: defense, then CE, then proxy, then product-alignment, then design, then code. One explicit override exists: `Use code review perspectives` beats `Use design review perspectives` and forces normal code prosecution.

## Surface Identification

CE Gate surface identification maps the customer surface to the expected validation tool. Web UI uses native browser tools first, with Playwright MCP as fallback. REST or GraphQL uses terminal HTTP calls. CLI and SDK surfaces use representative terminal invocations. Batch and pipeline surfaces use representative test data. No customer surface returns the documented status marker `⏭️ CE Gate not applicable — {reason}` from structured data so consumers do not need a separate hardcoded case.

## Skill Mapping

The skill mapping table is guidance for delegation prompts rather than a pure lookup table. It links each reusable skill to the kind of work where Code-Conductor should explicitly instruct a specialist to load it. The mappings cover review, customer experience, design exploration, documentation, frontend design, implementation discipline, parallel execution, planning, property-based testing, refactoring, research, review judgment, skill creation, software architecture, debugging, TDD, UI iteration, UI testing, and web app testing.

Consumers should treat this section as a reference list that explains when a skill is relevant, not as a hard decision engine that replaces agent judgment.

## Enums

The enum section captures the canonical current values used by the review pipeline:

- `severity`: `critical`, `high`, `medium`, `low`
- `points`: `critical` and `high` map to `10`; `medium` maps to `5`; `low` maps to `1`
- `confidence`: `high`, `medium`, `low`
- `category`: `architecture`, `security`, `performance`, `pattern`, `implementation-clarity`, `script-automation`, `documentation-audit`
- `blast_radius`: `localized`, `module`, `cross-module`, `system-wide`
- `authority_needed`: `yes`, `no`
- `systemic_fix_type`: `instruction`, `skill`, `agent-prompt`, `plan-template`, `none`

The category list is canonical-only. Legacy `simplicity` is intentionally excluded.

## Gate Criteria

Scope classification is an AND gate: all five abbreviated-tier criteria must hold, otherwise the issue stays on the full pipeline. The stored tier table captures which phases run in full and abbreviated execution.

Express lane is also an AND gate. A finding must be low severity, strictly mechanical, non-logic-changing, test-neutral, backward-compatible with respect to stored IDs and schema, and limited to one file. It only applies to main review and post-fix review routing, and Tier 1 re-validation is still required after the fix lands.

Post-fix targeted prosecution uses OR semantics for its trigger conditions: one accepted critical or high finding is enough, and any accepted fix that modifies control flow is also enough. If no findings were accepted and applied, the post-fix review is skipped.

## Interpretation Rules

Use exact current values from the JSON assets when a mode, enum, or routing value needs to be preserved across prompts or scripts. Match review markers literally. For specialist dispatch file routing, use explicit `file_patterns` keys instead of parsing prose. Treat `skill_mapping` as explanatory metadata, not a replacement for human judgment. Treat `scope_classification` and `express_lane` as all-criteria gates, while `post_fix_trigger` activates when any trigger condition is met.

When an entry includes prose qualifiers, preserve them rather than compressing them away. The goal of these files is stable extraction of current rules, not reinterpretation of the orchestration policy.

## Fallback Guidance

Future deterministic consumers should prefer the JSON assets first. If a later script is unavailable, agents can still read the JSON directly. If a case is not covered by the structured data or a prompt needs human-readable context, fall back to this skill summary.

Routing authority remains with the calling agent. This skill provides shared data and summaries; it does not own orchestration decisions.

## Gotchas

| Trigger                                               | Gotcha                                                                                                                  | Fix                                                                                         |
| ----------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------- |
| Treating a routing table entry as binding policy      | The skill centralizes canonical data, but the calling agent still owns the final routing decision and fallback behavior | Use the skill for shared data, then keep decision authority and override logic in the agent |
| Editing only the prose summary or only the JSON asset | Human-readable guidance and deterministic consumers drift apart                                                         | Update the JSON assets and the corresponding SKILL.md summary together in the same change   |
