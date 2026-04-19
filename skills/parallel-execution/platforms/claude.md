# Platform — Claude Code

When `parallel-execution` escalates (budget exceeded, unresolved RC conformance, or unresolved correction cycles), Claude Code agents invoke the `AskUserQuestion` tool with the root-cause summary, a recommended option, and alternatives. The methodology specifies when each escalation path fires — this platform file only documents the invocation.
