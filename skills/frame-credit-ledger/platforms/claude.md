# Platform — Claude Code

`frame-credit-ledger` is consumed by the Claude Code `code-conductor` shell (lowercase) loaded via `/orchestrate`. The shared Code-Conductor agent body at [../../../agents/Code-Conductor.agent.md](../../../agents/Code-Conductor.agent.md) references this skill from its Step 4 post-`gh pr create` flow; the one-line wiring of that reference lands in Step 8 of issue [#429](https://github.com/Grimblaz/agent-orchestra/issues/429).

Claude bindings:

- Use the `Bash` tool to invoke the orchestrator: `pwsh .github/scripts/frame-credit-ledger.ps1 -Pr <N>` where `<N>` is the PR number returned by the preceding `gh pr create` step.
- Treat the call as fire-and-observe. The conductor must not branch on the orchestrator's exit code: per the warn-only contract the script fails open and never blocks PR handoff.
- Use `Bash` with the `gh` CLI for any subsequent observation of the posted ledger comment if the conductor needs to confirm the upsert succeeded; do not re-run the orchestrator just to inspect its output.
- Do not use `AskUserQuestion` from this path — the ledger is silent observation and never asks the operator to make a choice.

Keep methodology in `SKILL.md`; this platform note is only the Claude tool-binding shim.
