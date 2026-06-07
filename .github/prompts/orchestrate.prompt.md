---
agent: Code-Conductor
description: "Run the full orchestration pipeline for one or more GitHub issues — full pipeline: scope classification, smart resume, D9 checkpoint, implementation, review, PR"
argument-hint: "Single issue (e.g. issue #177) or multiple issues (e.g. issues #177 #178 #179)"
---

<!-- FROZEN: Copilot surface frozen per #651, retiring after 2026-08-31. See Documents/Design/copilot-deprecation.md. Do not add new Copilot parity work. -->

# /orchestrate

Start the Code-Conductor hub mode orchestration workflow for: {{input}}

For Code-Conductor CE Gate orchestration, treat `skills/customer-experience/references/orchestration-protocol.md` as the canonical reference file and report one of these result markers:

- `✅ CE Gate passed — intent match: strong`
- `✅ CE Gate passed — intent match: partial`
- `✅ CE Gate passed — intent match: weak`
- `✅ CE Gate passed after fix — intent match: {strong|partial|weak}`
- `⚠️ CE Gate skipped — {reason}`
- `❌ CE Gate aborted — {reason}`
- `⏭️ CE Gate not applicable — {reason}`
