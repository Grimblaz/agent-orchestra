# Platform — Copilot (VS Code)

`frame-credit-ledger` is consumed by the Copilot Code-Conductor flow, which inherits the same shared Code-Conductor agent body at [../../../agents/Code-Conductor.agent.md](../../../agents/Code-Conductor.agent.md) that Claude Code uses. Once Step 8 of issue [#429](https://github.com/Grimblaz/agent-orchestra/issues/429) wires the one-line reference into the shared body, both platforms invoke this skill automatically after `gh pr create` succeeds — no Copilot-side wiring is required beyond reusing the shared agent body.

Copilot bindings:

- Use `runInTerminal` to invoke the orchestrator: `pwsh .github/scripts/frame-credit-ledger.ps1 -Pr <N>` where `<N>` is the PR number returned by the preceding `gh pr create` step.
- Treat the call as fire-and-observe. The conductor must not branch on the orchestrator's exit code: per the warn-only contract the script fails open and never blocks PR handoff.
- Use `runInTerminal` with the `gh` CLI for any subsequent observation of the posted ledger comment if the conductor needs to confirm the upsert succeeded; do not re-run the orchestrator just to inspect its output.
- Do not invoke `vscode/askQuestions` from this path — the ledger is silent observation and never asks the operator to make a choice.

Keep methodology in `SKILL.md`; this platform note is only the Copilot tool-binding shim.
