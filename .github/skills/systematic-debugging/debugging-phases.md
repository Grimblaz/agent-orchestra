# Debugging Phases - Detailed Reference

Extended guidance for each phase of systematic debugging.

## Phase 1: OBSERVE - Deep Dive

### Log Analysis Techniques

**Finding the needle**:
```bash
# Search for errors around a timestamp
grep -B 5 -A 10 "ERROR" app.log | grep -A 15 "2024-01-15T14:3"

# Find correlated events
grep -E "(request-id-123|user-456)" *.log

# Watch logs in real-time with filter
tail -f app.log | grep --line-buffered "PaymentService"
```

**What to look for**:
- First error in the chain (not the cascade)
- Timestamps and sequence of events
- Request/correlation IDs to trace flow
- Resource metrics (memory, CPU, connections)
- What's different from successful requests

### Reproduction Strategies

**For intermittent bugs**:
1. Identify patterns (time of day, load level, specific users)
2. Increase logging verbosity temporarily
3. Create stress test that amplifies the conditions
4. Use record/replay tools if available

**For environment-specific bugs**:
1. Document exact differences between environments
2. Check environment variables and configuration
3. Compare dependency versions
4. Verify data differences

### Bisection Technique

When bug appeared "sometime":
```bash
# Git bisect to find breaking commit
git bisect start
git bisect bad HEAD
git bisect good v1.2.0
# Run test, mark good/bad, repeat
```

## Phase 2: HYPOTHESIZE - Deep Dive

### Hypothesis Categories

**Code-level hypotheses**:
- Logic error in specific function
- Edge case not handled
- Type coercion issue
- Off-by-one error
- Null/undefined reference

**Integration hypotheses**:
- API contract changed
- Database schema mismatch
- Message format incompatibility
- Timeout too short

**Environment hypotheses**:
- Configuration difference
- Missing environment variable
- Permission/access issue
- Resource exhaustion

**Data hypotheses**:
- Corrupt/invalid data
- Missing required data
- Data migration issue
- Encoding problem

### Reasoning Techniques

**Rubber duck debugging**:
Explain the code flow out loud. Often reveals assumptions.

**Working backwards**:
Start from the error, trace backwards through the code path.

**Elimination**:
Rule out entire subsystems to narrow scope.

**Comparison**:
What's different between working and broken cases?

## Phase 3: TEST - Deep Dive

### Isolation Techniques

**Minimal reproduction**:
```javascript
// Instead of debugging full app, isolate the function
const result = suspectFunction(knownBadInput)
console.log('Result:', result)
console.log('Expected:', expectedOutput)
```

**Mock external dependencies**:
```javascript
// Replace real service with controlled stub
const mockService = {
  getData: () => Promise.resolve(testData)
}
// Now test with known data
```

**Binary search in code**:
```javascript
// Add logging at midpoint of suspect code
console.log('CHECKPOINT 1:', intermediateState)
// Narrow down based on where state diverges
```

### Debugging Tools Reference

**Browser DevTools**:
- Network tab: Request/response inspection
- Console: Runtime errors, logging
- Sources: Breakpoints, call stack
- Performance: Timing analysis
- Application: Storage inspection

**Node.js Debugging**:
```bash
# Start with inspector
node --inspect app.js

# Break on first line
node --inspect-brk app.js

# Use Chrome DevTools at chrome://inspect
```

**Database debugging**:
```sql
-- Enable query logging
SET log_statement = 'all';

-- Explain query plan
EXPLAIN ANALYZE SELECT ...;

-- Check for locks
SELECT * FROM pg_locks;
```

## Phase 4: FIX - Deep Dive

### Fix Quality Checklist

**Correctness**:
- [ ] Fix addresses root cause (not symptoms)
- [ ] All edge cases handled
- [ ] Error messages are helpful
- [ ] No new errors introduced

**Completeness**:
- [ ] Similar code elsewhere updated
- [ ] Documentation updated if needed
- [ ] Configuration changes documented
- [ ] Migration scripts if needed

**Testability**:
- [ ] Unit test for the specific fix
- [ ] Integration test if applicable
- [ ] Test covers the original failure case
- [ ] Test is not flaky

### Regression Test Template

```javascript
describe('Bug #123: [Brief description]', () => {
  it('should [expected behavior] when [condition]', () => {
    // Arrange: Set up the exact conditions that caused the bug
    const input = { /* data that triggered bug */ }
    
    // Act: Execute the code path
    const result = functionUnderTest(input)
    
    // Assert: Verify correct behavior
    expect(result).toEqual(expectedOutput)
  })
})
```

### Post-Mortem Template

For significant bugs, document learnings:

```markdown
## Bug Post-Mortem: [Title]

### Summary
[One paragraph description]

### Timeline
- [When reported]
- [When diagnosed]
- [When fixed]
- [When deployed]

### Root Cause
[Technical explanation]

### Resolution
[What was changed]

### Lessons Learned
- [What we'll do differently]

### Action Items
- [ ] [Preventive measure 1]
- [ ] [Preventive measure 2]
```

## Debugging Mindset

### Productive Attitudes
- **Curiosity over frustration**: The bug is a puzzle to solve
- **Humility**: Your code has bugs; accept it
- **Patience**: Rushing leads to more bugs
- **Methodical**: Follow the process even when tempted to guess

### When to Take a Break
- You've been stuck for >1 hour
- You're making random changes
- You're frustrated or tired
- You keep looking at the same code

### When to Ask for Help
- Fresh eyes often spot issues quickly
- After documenting what you've tried
- When you need domain expertise
- When the cost of delay exceeds pride
