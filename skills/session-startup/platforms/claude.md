# Platform — Claude Code

When `session-startup` needs user confirmation before running the post-merge cleanup script, Claude Code agents invoke the `AskUserQuestion` tool. Present the detector's `additionalContext` text and offer two options:

1. `Yes — run cleanup`
2. `No — skip for now`

For the Claude-only drift-check sub-step, use the same `AskUserQuestion` tool with these exact option labels:

1. `Stop — I'll restart now`
2. `Continue — run under old code`

If Claude is running headless and cannot ask a structured question, skip the prompt and emit the update result inline instead.

> **D3b exemption**: `session-startup/SKILL.md` intentionally retains this methodology verbatim (see `path-migration-sweep-gate.Tests.ps1` D3b whitelist). The platform file documents the Claude Code-specific tool invocation without duplicating the full protocol.
