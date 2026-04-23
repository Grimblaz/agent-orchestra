# Platform — Claude Code

When `parallel-execution` escalates (budget exceeded, unresolved RC conformance, or unresolved correction cycles), Claude Code agents invoke the `AskUserQuestion` tool with the root-cause summary, a recommended option, and alternatives. The methodology specifies when each escalation path fires — this platform file only documents the invocation.

For shared references that describe terminal execution generically, Claude Code maps them to the available host terminal surface. Use `Bash` for non-interactive command execution. If the host session also exposes terminal-output inspection or terminal-termination controls, use those for lifecycle checks and cleanup; otherwise preserve terminal state, prefer short one-shot commands, and do not reintroduce Copilot-specific tool names into Claude-facing guidance.
