---
description: Enter raw mode for this conversation and bypass natural-language intent routing.
argument-hint: "No arguments"
---

# /raw

Raw mode active for this conversation — natural-language requests will not be routed. Any explicit slash command you type clears raw mode.

Raw mode is in-conversation context only. Do not write files, create a persistence file, or store session-memory state for raw mode. New conversations start routing-active.

Natural-language requests also activate raw mode when the user says one of these signal patterns without typing `/raw`:

- `just answer normally`
- `don't run the pipeline`
- `raw mode`
- `skip routing`

Any explicit user-typed slash command after raw mode is active clears raw mode for the remainder of the conversation. After that clear, natural-language intent routing is active again.

ARGUMENTS: $ARGUMENTS
