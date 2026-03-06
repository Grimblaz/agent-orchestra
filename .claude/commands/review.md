# Code Review

Perform an adversarial self-review of the current branch changes.

## Usage

`/project:review`

## Scope

Review all changes on the current branch relative to main:

```bash
git diff main...HEAD
```

## Stance

Presume defect. Assume every change introduces bugs until personally verified. Hunt for flaws — do not scan passively. "Tests pass" is a starting point, not a conclusion.

## Required Reading Before Review

- `.github/architecture-rules.md` (if it exists)
- `.github/copilot-instructions.md` or `CLAUDE.md` for project conventions
- `Documents/Development/TestingStrategy.md` (if it exists)

## 7 Review Perspectives (All Required)

Read `.github/agents/Code-Critic.agent.md` for the full review framework. Apply each perspective in sequence:

### 1. Architecture
- Project rules compliance, layer direction, interface usage, layer boundaries
- **Integration wiring**: For new components — is it imported, instantiated, and called in production code? (Not just tests!)
- **Data integration**: For new data fields — are they used by consumers? Check design intent.

### 2. Security
- No hardcoded secrets, input validation present, no sensitive data logging, auth checks in place

### 3. Performance
- Algorithm complexity, unnecessary re-renders, memory leaks, bottlenecks

### 4. Patterns
- Design patterns, anti-patterns, DRY, SOLID compliance

### 5. Simplicity
- No over-engineering, readable code, no unnecessary complexity

### 6. Script & Automation Files
For `.ps1`, `.sh`, `.py`, `.yml`/`.yaml` files:
- Exit-code checks for native executables
- No dynamic values to `Invoke-Expression`/`eval`
- Sanitization for output sinks

### 7. Documentation Script Audit
For `.md` files with shell code blocks:
- Commands must be runnable and produce documented results
- Expected counts must reflect post-change state

## Output Format

For each perspective, report PASS or FAIL with specific findings.

### Finding Categories

- **Issue**: Concrete failure scenario — state the failure mode. Include severity (critical/high/medium/low).
- **Concern**: Plausible risk with uncertain proof — state what is uncertain.
- **Nit**: Style preference. Non-blocking.

## After Review

Address accepted findings, then re-run validation commands to confirm fixes.
