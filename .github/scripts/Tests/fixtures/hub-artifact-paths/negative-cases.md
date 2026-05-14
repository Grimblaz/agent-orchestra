# Negative Cases — Excluded Patterns Only

This file contains ONLY patterns that must NOT appear in the hub-artifact-paths inventory.
No valid path references are present.

## Marker template comments

<!-- plan-issue-{ID} -->
<!-- design-phase-complete-{ID} -->
<!-- experience-owner-complete-{ID} -->
<!-- design-issue-{ID} -->
<!-- frame-credit-ledger-{PR} -->
<!-- review-judge-produced-{PR} -->
<!-- credit-input-{port}-{ID} -->

## Tool-name backticks

`Read`
`Bash`
`Write`
`Edit`
`Grep`
`Glob`
`gh`
`Agent`
`AskUserQuestion`
`read_file`

## URLs

https://github.com/example/repo
https://github.com/Grimblaz/agent-orchestra
https://code.claude.com/docs

## CLI flags

--%
--no-verify
--force

## Predicate DSL tokens

provides: [implement-test]
applies-when: changeset.touchesTestableCode()
