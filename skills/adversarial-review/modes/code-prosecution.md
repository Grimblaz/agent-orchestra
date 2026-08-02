<!-- markdownlint-disable-file MD041 MD003 -->

# Code Prosecution Mode

Mode file for the `code_prosecution` family: standard five-pass panel passes, the lite compact pass, and the post-fix targeted pass. Loaded selector-conditionally alongside the shared core in [../SKILL.md](../SKILL.md) — see that file's § Mode-Scoped Loading. A dispatch in another mode must not load this file.

## Code Prosecution Workflow

For standard code review, work through all six perspectives in sequence. For perspectives whose gate is not triggered, use the compact N/A pattern instead of expanding checklist items.

### 1. Architecture

Apply when runtime code, scripts, or runtime configuration changed.

Check:

- Architecture-rule compliance and layer direction
- Integration wiring for new components
- Data integration for newly introduced fields, constants, and maps
- Domain-alignment mismatches across validators, parsers, and converters — identify peers via field-name grep, plan consultation for aliases, and call-chain tracing
- Trace the sibling write-path guarantee parity: both write paths to the persisted target — the branch body plus every downstream helper the branch routes through — must be verified by name to carry every guarantee the sibling's path has (write-time preflight, schema validation, existence checks, post-write verification); a guarantee living only in a sibling's downstream call chain still counts as that sibling's guarantee

### 2. Security

Apply when the change touches source code, scripts, auth, or data handling.

Check:

- Secrets, credentials, and logging of sensitive data
- Input validation and authorization boundaries
- Full-record overwrite risks that can drop security-sensitive fields (when the risk spans a sibling write path, cross-reference the sibling write-path guarantee parity check in § Code Prosecution Workflow → 1. Architecture)

### 3. Performance

Apply when runtime execution paths changed.

Check:

- Algorithmic complexity
- Re-render or repeated-computation costs
- Memory or bottleneck risks

### 4. Pattern

Apply when source files changed. For docs-only changes, keep the documentation pattern concerns only.

Check:

- Appropriate pattern use and anti-pattern avoidance
- DRY violations and contradictory guidance
- SOLID pressure points
- UI test querying patterns when test code is in scope

### 5. Implementation Clarity

Apply to all change types.

Check:

- Over-engineering
- Readability and self-documenting structure
- Unnecessary complexity
- Comments that explain why rather than what

### 6. Script And Automation

Apply when script files changed or markdown includes runnable shell guidance.

For script files, verify:

- Native command exit-code checks at boundaries
- Cross-references to authoritative enumerated values
- PowerShell and pipeline semantics that preserve intended types

For markdown-only command guidance, audit:

- Runnable commands from repo root
- Self-match hazards in grep-based validations
- Correct post-change counts and expectations
- Preference for built-in VS Code tools over terminal-first read-only guidance when an equivalent exists

### 7. Missed-gate detection

**7. Missed-gate detection** (gate-skip audit) — See `agents/Code-Critic.agent.md` for the full specification. This perspective audits whether load-bearing decisions in the artifact have corresponding L0 gate tokens; it fires as a detective pass alongside the standard six perspectives when the `solution-authoring` gate is in scope for the reviewed artifact.

### Browser-Based Review

When the change touches UI implementation:

- Navigate only the affected routes or adjacent impacted flows
- Capture screenshots to support visual findings
- State route, action, expected behavior, observed behavior, and evidence

### Compact N/A Rule

When a perspective gate is not triggered, replace the full section with:

```markdown
### ⏭️ [Perspective Name]: N/A — [reason]
```

### Standard Code Review Output

```markdown
## Review Findings

### ✅ Architecture: PASS/FAIL

{findings or compact N/A}

### ✅ Security: PASS/FAIL

{findings or compact N/A}

### ✅ Performance: PASS/FAIL

{findings or compact N/A}

### ✅ Patterns: PASS/FAIL

{findings or compact N/A}

### ✅ Implementation Clarity: PASS/FAIL

{findings or compact N/A}

### ✅ Script & Automation: PASS/FAIL

{findings or compact N/A}

## Summary

{overall verdict and key actions}
```
