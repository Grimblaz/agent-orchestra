# Implementation Plan

**Issue**: #[ISSUE_NUMBER]
**Title**: [ISSUE_TITLE]
**Branch**: `feature/issue-[ISSUE_NUMBER]-[DESCRIPTIVE_NAME]`

---

## User Story

**As a** [ROLE]
**I want** [FEATURE/CHANGE]
**So that** [BUSINESS_VALUE]

### Acceptance Criteria

- [ ] [Criterion 1]
- [ ] [Criterion 2]
- [ ] [Criterion 3]

---

## Complexity Assessment

**Level**: [MINIMAL | MORE | A LOT]

### Reasoning

[Explain the complexity level choice based on:]

- Scope of changes (number of files, lines of code)
- Technical difficulty (new patterns, unfamiliar APIs)
- Risk level (breaking changes, core functionality)
- Dependencies (external systems, other issues)

---

## Impact Analysis

### Files to Create

- `[path/to/new/file.ext]` - [Purpose]

### Files to Modify

- `[path/to/existing/file.ext]` - [Changes needed]

### Dependencies

- [List related issues, external services, or blocking work]

### Risk Assessment

- **High Risk**: [Areas requiring careful attention]
- **Medium Risk**: [Areas requiring standard testing]
- **Low Risk**: [Routine changes]

---

## Implementation Phases

### Phase 1: Research & Planning

**Agent**: Research-Agent

**Description**: Gather context and validate approach before implementation.

**Tasks**:

- [ ] Review related code and patterns
- [ ] Identify dependencies and constraints
- [ ] Research best practices for [TECHNOLOGY/PATTERN]
- [ ] Document findings in research notes

**Files to Review**:

- `[CUSTOMIZE: List relevant files to understand]`

**Acceptance Criteria**:

- [ ] Research notes document approach
- [ ] Edge cases identified
- [ ] Technical decisions documented

---

### Phase 2: Write Tests First (TDD)

**Agent**: Test-Writer

**Description**: Define expected behavior through tests before implementation.

**Tasks**:

- [ ] Create test files with failing tests
- [ ] Cover happy path scenarios
- [ ] Cover edge cases and error conditions
- [ ] Ensure tests fail for right reasons

**Files to Create/Modify**:

- `[CUSTOMIZE: Test file paths]`

**Acceptance Criteria**:

- [ ] All test cases written and failing
- [ ] Test coverage plan documented
- [ ] Edge cases covered

---

### Phase 3: Implementation

**Agent**: Code-Smith

**Description**: Implement the feature/fix to make tests pass.

**Tasks**:

- [ ] Implement core functionality
- [ ] Make tests pass one by one
- [ ] Handle edge cases
- [ ] Add inline documentation

**Files to Modify**:

- `[CUSTOMIZE: Implementation file paths]`

**Acceptance Criteria**:

- [ ] No test failure this change introduced, measured against a named baseline commit; pre-existing failures named and routed
- [ ] Code follows project patterns
- [ ] No regression in existing functionality

---

### Phase 4: Validation

**Agent**: [CUSTOMIZE: Test-Writer or project-specific validation agent]

**Description**: Verify implementation meets all requirements.

**Tasks**:

- [ ] Run full test suite
- [ ] Verify acceptance criteria met
- [ ] Check code coverage thresholds
- [ ] Run linting and formatting checks

**Commands to Run**:

```bash
[CUSTOMIZE: Add project-specific validation commands]
# Example:
# npm test
# npm run lint
# npm run coverage
```

**Acceptance Criteria**:

- [ ] No test failure this change introduced, measured against a named baseline commit; pre-existing failures named and routed
- [ ] Coverage >= [CUSTOMIZE: threshold]%
- [ ] No linting errors
- [ ] All acceptance criteria satisfied

---

### Phase 5: Refactor (If Needed)

**Agent**: Refactor-Specialist

**Description**: Improve code quality without changing behavior.

**Tasks**:

- [ ] Identify code smells or duplication
- [ ] Extract reusable components
- [ ] Improve naming and clarity
- [ ] Verify tests still pass after each refactor

**Refactor Targets**:

- [List areas that might need refactoring]

**Acceptance Criteria**:

- [ ] Code is DRY (Don't Repeat Yourself)
- [ ] Functions are single-purpose
- [ ] No test failure this refactor introduced, against the pre-refactor commit
- [ ] Code readability improved

---

### Phase 6: Code Review Prep

**Agent**: Code-Conductor

**Description**: Prepare code for human review.

**Tasks**:

- [ ] Self-review all changes
- [ ] Verify commit messages are clear
- [ ] Update PR description
- [ ] Add screenshots/examples if applicable

**Review Checklist**:

- [ ] Changes align with issue requirements
- [ ] No debugging code or commented-out lines
- [ ] Error handling is appropriate
- [ ] Code follows team conventions

**Acceptance Criteria**:

- [ ] PR ready for human review
- [ ] All changes documented
- [ ] No obvious issues remain

---

### Phase 7: Documentation

**Agent**: Doc-Keeper

**Description**: Update documentation to reflect changes.

**Tasks**:

- [ ] Update inline code comments
- [ ] Update README if needed
- [ ] Update API documentation
- [ ] Add migration notes if breaking changes

**Files to Update**:

- `README.md` - [If user-facing changes]
- `[CUSTOMIZE: Other doc files]`

**Acceptance Criteria**:

- [ ] All user-facing changes documented
- [ ] API changes documented
- [ ] Examples updated

---

### Phase 8: Final Cleanup

**Agent**: Code-Conductor

**Description**: Final checks before marking PR ready for review.

**Tasks**:

- [ ] Squash/clean commit history if needed
- [ ] Update issue status
- [ ] Mark PR as ready for review
- [ ] Notify reviewers

**Acceptance Criteria**:

- [ ] Clean commit history
- [ ] Issue updated
- [ ] PR ready for human review

---

## Notes

### Project-Specific Considerations

[CUSTOMIZE: Add any project-specific notes, patterns, or conventions to follow]

### Technical Decisions

[Document any important technical decisions made during planning]

### Open Questions

- [ ] [Question 1]
- [ ] [Question 2]

---

## Success Metrics

- [ ] All acceptance criteria met
- [ ] No test failure this change introduced, measured against a named baseline commit; pre-existing failures named and routed
- [ ] Code coverage maintained/improved
- [ ] No regressions introduced
- [ ] Documentation updated
- [ ] Ready for human review

---

**Plan Created**: [DATE]
**Last Updated**: [DATE]
**Status**: [Draft | In Progress | Complete]
