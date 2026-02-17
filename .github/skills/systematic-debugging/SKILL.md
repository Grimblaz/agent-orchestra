---
name: systematic-debugging
description: 4-phase debugging process (Observe, Hypothesize, Test, Fix) for complex issues. Use when debugging fails, investigating flaky tests, tracking root causes, or facing mysterious bugs.
---

# Systematic Debugging

Evidence-based debugging methodology using a structured 4-phase approach.

## When to Use

- Initial debugging attempts failed
- Bug is intermittent or hard to reproduce
- Multiple potential root causes
- High-stakes fix (production, security)
- Teaching debugging skills

## The 4-Phase Process

```
┌─────────────┐    ┌──────────────┐    ┌─────────────┐    ┌─────────────┐
│  1. OBSERVE │ -> │ 2. HYPOTHESIZE│ -> │   3. TEST   │ -> │   4. FIX    │
│             │    │              │    │             │    │             │
│ Gather data │    │ Form theories│    │ Validate    │    │ Implement & │
│ Don't assume│    │ Rank by      │    │ One at a    │    │ Verify      │
│             │    │ likelihood   │    │ time        │    │             │
└─────────────┘    └──────────────┘    └─────────────┘    └─────────────┘
       ↑                                      │
       └──────────────────────────────────────┘
                (if hypothesis fails)
```

## Phase 1: OBSERVE

**Goal**: Gather facts without assumptions.

### Actions
- [ ] Document exact symptoms (error messages, behavior)
- [ ] Identify when it started (commit, deployment, date)
- [ ] Determine reproduction steps (or note if intermittent)
- [ ] Check logs, metrics, and monitoring
- [ ] Note what IS working (bounds the problem)

### Questions to Answer
- What exactly is happening vs. expected?
- When did this start? What changed?
- Who/what is affected? (all users, some, specific conditions)
- Can I reproduce it? How reliably?
- What have I already tried?

### Observation Log Template
```markdown
## Bug: [Brief description]

### Symptoms
- [Exact error message or behavior]

### Timeline
- First reported: [date/time]
- Last known working: [date/time]
- Related changes: [commits, deploys]

### Reproduction
- Steps: [1, 2, 3...]
- Reliability: [always/sometimes/rarely]
- Environment: [local/staging/prod]

### What Works
- [Related functionality that IS working]
```

## Phase 2: HYPOTHESIZE

**Goal**: Generate ranked theories based on evidence.

### Generate Hypotheses
Based on observations, list possible causes:

1. **Most likely** (evidence strongly supports)
2. **Possible** (evidence partially supports)  
3. **Unlikely but testable** (low probability, easy to rule out)

### Ranking Criteria
- **Evidence fit**: Does it explain ALL symptoms?
- **Recency**: Recent changes more likely than old code
- **Complexity**: Simpler explanations first (Occam's Razor)
- **Testability**: Can we prove/disprove it quickly?

### Hypothesis Template
```markdown
### Hypothesis: [Theory]

Evidence for:
- [Supporting observation]

Evidence against:
- [Contradicting observation]

How to test:
- [Specific test that proves/disproves]

Likelihood: [High/Medium/Low]
```

See [debugging-phases.md](./debugging-phases.md) for detailed phase guidance.

## Phase 3: TEST

**Goal**: Validate one hypothesis at a time with evidence.

### Testing Rules
1. **One variable at a time**: Change only what tests the hypothesis
2. **Record everything**: Document what you tried and results
3. **Preserve ability to undo**: Don't make permanent changes while testing
4. **Set time limits**: Timebox each hypothesis test

### Test Log Template
```markdown
### Testing: [Hypothesis]

Test approach:
- [What I'm changing/checking]

Result:
- [What happened]

Conclusion:
- [ ] Confirmed (proceed to Fix)
- [ ] Disproved (next hypothesis)
- [ ] Inconclusive (need different test)
```

## Phase 4: FIX

**Goal**: Implement verified fix with confidence.

### Fix Checklist
- [ ] Fix addresses confirmed root cause (not just symptoms)
- [ ] Fix is minimal (no unrelated changes)
- [ ] Added test that would catch regression
- [ ] Verified fix in same environment where bug occurred
- [ ] Documented what the bug was and how it was fixed

### Post-Fix Verification
- [ ] Original reproduction steps no longer fail
- [ ] Related functionality still works
- [ ] No new errors in logs
- [ ] Performance not degraded

## Quick Debugging Toolkit

### Information Gathering
```
[CUSTOMIZE] Add your project's debugging commands:
- Log tailing: [command]
- Database queries: [tool/access]
- Metrics dashboard: [URL]
- Error tracking: [tool/URL]
```

### Common Root Causes Checklist
- [ ] Recent deployment? Check release notes
- [ ] Environment difference? Compare configs
- [ ] Data issue? Check for bad/missing data
- [ ] Dependency update? Check lock files
- [ ] Race condition? Check async code
- [ ] Resource exhaustion? Check memory/connections
- [ ] Permission change? Check access controls

## Anti-Patterns to Avoid

| Anti-Pattern | Problem | Instead |
|--------------|---------|---------|
| Shotgun debugging | Random changes obscure root cause | One change at a time |
| Fix and forget | Bug may recur | Add regression test |
| Assuming the cause | Wastes time on wrong path | Gather evidence first |
| Debugging in production | Risk of more damage | Reproduce locally first |
| Not documenting | Knowledge lost | Keep observation log |
