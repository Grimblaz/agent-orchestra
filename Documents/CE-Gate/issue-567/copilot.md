# Issue #567 CE Gate Evidence - Copilot Directive Surface

Date: 2026-05-14
Surface: CLI / chat-command directive surface, Copilot guidance
Evidence type: Phase 1 directive/config evidence plus transcript-simulated checks

## Runtime Capture Boundary

Live Copilot transcript capture is INCONCLUSIVE. Issue #567 Phase 1 ships prose/config/test enforcement only; no Copilot custom default chat mode or runtime intent hook is shipped in this phase. The checks below therefore validate the directive surface, prompt files, resolver behavior, and transcript-simulated expected customer experience without claiming live runtime routing.

## Directive Evidence

- `.github/copilot-instructions.md` has an `## Intent Routing` section stating that plugin processes are the default chat experience and natural-language requests matching `nl_intent_routing` route to slash commands with visible confirmation.
- The section says the recommended order is VS Code dropdown, slash commands, natural-language confirmation, and that `@-mention` is NOT recommended.
- Confirmation wording names slash commands: first match uses structured `AskUserQuestion` options such as `Run /X for this (Recommended)`; later same-family matches use `Routing to /X -- say /raw to opt out, otherwise proceed.`
- D3 scope is explicit: routing detection runs only for top-level user messages outside active slash-command turns and outside subagent dispatches.
- `/raw`, `just answer normally`, `don't run the pipeline`, `raw mode`, and `skip routing` activate raw mode for the conversation only; any explicit slash command clears raw mode.
- For matched entries with a non-null `copilot_command` that require explicit handoff, the directive says to emit `Please run /X to continue` using the Copilot command from `nl_intent_routing` and stop.
- The tier-hint directive says to append `Will run on sonnet + medium per command frontmatter.` when proposed command frontmatter differs from the user-session model.
- No-match handling is documented as a normal answer plus the first-turn tip: `Tip: type /help for plugin slash commands, or /raw to suppress these hints.`
- Ambiguous-match handling is documented as a text-only disambiguation prompt naming Copilot-valid slash-command candidates, for example `/design` and `/plan`.
- `.github/prompts/raw.prompt.md` carries the same conversation-only raw-mode acknowledgement and signal list as the Claude command shell.

## Transcript-Simulated Checks

### S1 Functional - Slash Command Confirmation

Prompt: `review my PR`
Expected route row: `review-pr-github`
Expected Copilot confirmation names `/review` verbatim because the row maps GitHub review intake to the Copilot command surface.
Result: PASS for Phase 1 directive/resolver evidence; live transcript INCONCLUSIVE.

### S2 Functional - Raw Mode

Prompt: `/raw`
Expected acknowledgement: `Raw mode active for this conversation — natural-language requests will not be routed. Any explicit slash command you type clears raw mode.`
Follow-up prompt: `review my PR`
Expected behavior while raw: no routing confirmation.
Prompt: `/plan 567`
Expected behavior: explicit slash command clears raw mode.
Prompt: `don't run the pipeline`
Expected resolver result: no route and raw mode directive applies.
Result: PASS for Phase 1 directive/resolver evidence; live transcript INCONCLUSIVE.

### S4 Intent - Slash Commands, Not Mentions

Expected transcript language names `/review`, `/orchestrate`, `/plan`, `/design`, and other slash commands. It does not recommend `@-mention` as the routing surface.
Result: PASS for directive evidence.

### D3 Scope - Active Slash-Command Turn

Context: inside active `/orchestrate` or `/plan` turn.
Prompt: `review my PR`
Expected behavior: no top-level natural-language routing fire because the utterance is inside an active slash-command turn.
Result: PASS for directive evidence; live transcript INCONCLUSIVE.

### D6 Tier Hint - `/orchestrate`

Prompt: `orchestrate issue 567`
Expected confirmation names `/orchestrate` and includes `Will run on sonnet + medium per command frontmatter.` when applicable.
Result: PASS for directive evidence; live transcript INCONCLUSIVE.

### D5 Instruct And Wait - `/orchestrate`

Prompt: `orchestrate issue 567`
Expected after accepting confirmation: `Please run /orchestrate to continue`, then stop rather than inline-emulating the command.
Result: PASS for directive evidence; live transcript INCONCLUSIVE.

### D8 No Match

Prompt: `explain what this code does`
Resolver result: no route.
Expected response: answer normally and, on the first no-match of the conversation, append `Tip: type /help for plugin slash commands, or /raw to suppress these hints.`
Result: PASS for directive/resolver evidence; live transcript INCONCLUSIVE.

### D8 Ambiguous Match

Prompt: `please help plan and design this issue`
Expected response: text-only disambiguation naming Copilot-valid slash-command candidates such as `/design` and `/plan`.
Result: PASS for directive evidence; live transcript INCONCLUSIVE.

## Named-Decision Verification

- D1 two-phase rollout: VERIFIED for Phase 1 directive/config evidence; Phase 2 custom default chat mode remains deferred.
- D3 scoped routing: VERIFIED in Copilot guidance.
- D5 instruct-and-wait: VERIFIED in Copilot guidance.
- D6 tier hint: VERIFIED in Copilot guidance.
- D7 raw mode: VERIFIED in Copilot guidance and `.github/prompts/raw.prompt.md`.
- D8 no-match/ambiguous-match: VERIFIED in Copilot guidance.
- D10 source of truth: VERIFIED by resolver replay against `skills/routing-tables/assets/routing-config.json`.

## Exploratory Observation

The Copilot directive is aligned with the Claude directive, while allowing Copilot-specific command availability such as `/review` and null `copilot_command` rows. Live default routing still waits for the Phase 2 Copilot custom chat mode work.
