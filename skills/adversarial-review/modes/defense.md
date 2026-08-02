<!-- markdownlint-disable-file MD041 MD003 -->

# Defense Mode

Mode file for `defense`. Loaded selector-conditionally alongside the shared core in [../SKILL.md](../SKILL.md) — see that file's § Mode-Scoped Loading. A dispatch in another mode must not load this file.

## Defense Workflow

When defending against a prosecution ledger:

1. Read the cited code or evidence independently
2. Try to disprove the stated failure mode
3. Use `disproved`, `conceded`, or `insufficient-to-disprove` per finding
4. Only challenge items you can support with concrete counter-evidence

Defense report format:

```markdown
## Defense Report

### Finding: {id} — {title}

Prosecution: {severity} ({points} pts) — {brief claim}
Defense verdict: `disproved | conceded | insufficient-to-disprove`
Evidence: {what was independently verified}
Argument: {why the prosecution is wrong or why defense concedes}

### Score Summary

Findings reviewed: N
Disproved: X | Conceded: Y | Insufficient: Z
Points claimed: {sum of disproved finding values}
Points at risk: {-2× sum of disproved finding values if rejected}
```
