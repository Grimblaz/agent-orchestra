---
name: verification-before-completion
description: Evidence-based verification checklist before marking work complete. Use before PRs, releases, marking tickets done, or any "I'm finished" declaration.
---

# Verification Before Completion

Systematic verification process to ensure work is truly complete.

## When to Use

- Before creating a pull request
- Before marking a ticket/issue as done
- Before declaring a feature complete
- Before releases or deployments
- Anytime you think "I'm done"

## Core Principle

> **Iron Law**: Claims do not count as completion—only evidence does.

> "Done" means verified, not just implemented.

The gap between "I wrote the code" and "it works correctly" is where bugs hide.

If evidence is missing, the work is not complete yet.

## Universal Verification Checklist

### 1. Requirements Verification

- [ ] Re-read the original requirements/ticket
- [ ] All acceptance criteria explicitly met
- [ ] Edge cases identified and handled
- [ ] No scope creep (didn't add unrequested features)
- [ ] No scope miss (didn't forget requested features)

### 2. Code Quality Verification

- [ ] Code compiles/runs without errors
- [ ] No new warnings introduced
- [ ] Linter passes with no new issues
- [ ] Follows project code style
- [ ] No debug code left (console.log, TODO hacks)

### 3. Testing Verification

- [ ] All existing tests pass
- [ ] New tests written for new code
- [ ] Tests cover happy path
- [ ] Tests cover error/edge cases
- [ ] Manual testing performed in realistic environment

### 4. Integration Verification

- [ ] Works with rest of system (not just in isolation)
- [ ] Database migrations work (up AND down)
- [ ] API contracts honored
- [ ] No breaking changes to dependents
- [ ] Feature flags configured if needed

### 5. Documentation Verification

- [ ] Code comments for complex logic
- [ ] README updated if needed
- [ ] API documentation updated
- [ ] Changelog entry added
- [ ] Migration/upgrade notes if needed

## Quick Verification Commands

```bash
[CUSTOMIZE] Add your project's verification commands:

# Run all checks
[your-verify-command]

# Individual checks
[your-lint-command]   # Static analysis
[your-test-command]   # Unit tests
[your-integration-command] # Integration tests
[your-build-command]  # Ensure it builds
```

## Context-Specific Checklists

### Before Pull Request

- [ ] Branch is up to date with target
- [ ] Commit messages are clear
- [ ] PR description explains the change
- [ ] Screenshots/videos if UI change
- [ ] Reviewers assigned
- [ ] Labels/tags applied

### Before Release

- [ ] All PRs merged and verified
- [ ] Release notes complete
- [ ] Version numbers updated
- [ ] Rollback plan documented
- [ ] Stakeholders notified
- [ ] Monitoring alerts configured

### Before Demo

- [ ] Feature works end-to-end
- [ ] Test data is realistic
- [ ] Environment is stable
- [ ] Backup demo path ready
- [ ] Talking points prepared

## Evidence Collection

Don't just check boxes—collect evidence:

### Acceptable Evidence

- ✅ Screenshot of passing tests
- ✅ Link to successful CI/CD run
- ✅ Screen recording of feature working
- ✅ Query results showing correct data
- ✅ Logs showing expected behavior

### Insufficient Evidence

- ❌ "I tested it locally" (no proof)
- ❌ "It worked yesterday" (not now)
- ❌ "The tests pass" (which tests?)
- ❌ "I didn't change that" (verify anyway)

## Verification Log Template

```markdown
## Verification: [Ticket/Feature ID]

### Requirements Review

- [x] Requirement 1: [How verified]
- [x] Requirement 2: [How verified]

### Tests

- Unit tests: [Link to CI run]
- Integration: [Link or screenshot]
- Manual: [Description of what tested]

### Evidence

- [Screenshot/link 1]
- [Screenshot/link 2]

### Notes

- [Any caveats or known limitations]

Verified by: [Name]
Date: [Date]
```

## Common "Almost Done" Traps

| Trap                  | Reality Check                  |
| --------------------- | ------------------------------ |
| "Works on my machine" | Did you test in CI/staging?    |
| "Just needs review"   | Did YOU review it first?       |
| "Tests pass"          | Do tests cover the change?     |
| "Same as before"      | Did you verify it still works? |
| "Simple change"       | Simple changes cause outages   |
| "Just a refactor"     | Refactors can change behavior  |

## Rationalization Prevention

Use this table when you catch yourself justifying instead of verifying.

| Rationalization                  | Replace With                           |
| -------------------------------- | -------------------------------------- |
| "It probably works"              | "Show the exact test run or result"    |
| "I already checked that"         | "Re-run and capture current evidence"  |
| "This part is unrelated"         | "Verify integration impact explicitly" |
| "No one will hit this edge case" | "Add or run an edge-case test"         |
| "Review will catch it"           | "Self-verify before requesting review" |

## When NOT Done

Stop and address if:

- Any test is failing (even "unrelated" ones)
- Any warning you don't understand
- Any TODO/FIXME you added
- Any hardcoded value that should be config
- Any "I'll fix it later" thought

## Red Flags — STOP

Do not mark complete while any of these are true:

- You cannot point to evidence for each acceptance criterion
- You are relying on memory instead of a current verification run
- You are skipping a check because "it's probably fine"
- You are deferring known validation to "after merge" or "later"

## Project-Specific Requirements

[CUSTOMIZE] Add your project's completion criteria:

```markdown
## Definition of Done

### Code

- [ ] [Project-specific coding standard]
- [ ] [Required review process]

### Testing

- [ ] [Minimum coverage requirement]
- [ ] [Required test types]

### Documentation

- [ ] [Required documentation updates]

### Process

- [ ] [Required approvals]
- [ ] [Required notifications]
```
