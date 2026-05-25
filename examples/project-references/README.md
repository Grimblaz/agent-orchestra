# Project References Example

This example shows the smallest useful shape for Agent Orchestra project references. The full schema and trust rules live in [../../skills/project-references/SKILL.md](../../skills/project-references/SKILL.md); the automation lives in [../../skills/project-references/scripts](../../skills/project-references/scripts).

## Files

| File | Purpose |
| --- | --- |
| [.agent-orchestra.yml](.agent-orchestra.yml) | Repository-level reference settings and hard caps |
| [Documents/payment-domain.md](Documents/payment-domain.md) | A project document worth loading during relevant work |
| [payment-domain.md.ref.yml](payment-domain.md.ref.yml) | The sidecar that names and describes the document |
| [.references/index.json](.references/index.json) | Sample generated index output |

## Citation

When an agent uses this document in a decision or plan, cite it as [ref:payment-domain](Documents/payment-domain.md). The literal citation format is `[ref:{name}](target_path)`.

## Trust And Budget Notes

Project references are content-trust bounded: repository-authored reference content is treated as untrusted repository content. Loaded excerpts render in fenced `untrusted-content` blocks and cannot override user input, auto-mode boundaries, engagement gates, or workflow methodology.

Reference loading also has hard caps. The defaults are `max_critical_loaded: 10` and `max_total_loaded_bytes: 102400` (100KB); this sample keeps those explicit in [.agent-orchestra.yml](.agent-orchestra.yml) so maintainers can see the budget controls without reading the full skill spec.

## Commands

Use `/setup-references help` for the safe action list. The same scripts can be run directly from [../../skills/project-references/scripts](../../skills/project-references/scripts):

```powershell
pwsh -NoProfile -NonInteractive -File "skills/project-references/scripts/init-references.ps1" -Root "<target-root>"
pwsh -NoProfile -NonInteractive -File "skills/project-references/scripts/generate-references-index.ps1" -Root "<target-root>"
pwsh -NoProfile -NonInteractive -File "skills/project-references/scripts/validate-references-index.ps1" -Root "<target-root>"
pwsh -NoProfile -NonInteractive -File "skills/project-references/scripts/init-references.ps1" -Root "<target-root>" --undo
```

Adoption is optional and non-blocking. If a repository has useful long-lived design, domain, or operations docs, references make those docs easier for agents to discover; if it does not, workflows continue normally.
