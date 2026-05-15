# Issue #567 CE Gate Evidence - Claude Directive Surface

Date: 2026-05-14
Surface: CLI / chat-command directive surface, Claude Code guidance
Evidence type: Phase 1 directive/config evidence plus transcript-simulated checks

## Runtime Capture Boundary

Live Claude transcript capture is INCONCLUSIVE. Issue #567 Phase 1 ships prose/config/test enforcement only; no Claude `UserPromptSubmit` runtime hook is shipped in this phase. The checks below therefore validate the directive surface, command shells, resolver behavior, and transcript-simulated expected customer experience without claiming live runtime routing.

## Directive Evidence

- `CLAUDE.md` has an `## Intent Routing` section stating that plugin processes are the default chat experience and natural-language requests matching `nl_intent_routing` route to slash commands with visible confirmation.
- The same section says the recommended order is VS Code dropdown, slash commands, natural-language confirmation, and that `@-mention` is NOT recommended.
- Confirmation wording names slash commands: first match uses `Run /X?`; later same-family matches use `Routing to /X -- say /raw to opt out, otherwise proceed.`
- D3 scope is explicit: routing detection runs only for top-level user messages outside active slash-command turns and outside subagent dispatches.
- `/raw`, `just answer normally`, `don't run the pipeline`, `raw mode`, and `skip routing` activate raw mode for the conversation only; any explicit slash command clears raw mode.
- For explicit model-frontmatter commands (`/orchestrate`, `/code-conductor`, `/review-github`), the directive says to emit `Please run /X to continue` and stop.
- `/orchestrate` declares `model: sonnet` and `effort: medium` in `commands/orchestrate.md`; the directive says to append `Will run on sonnet + medium per command frontmatter.` when the proposed command frontmatter differs from the user-session model.
- No-match handling is documented as a normal answer plus the first-turn tip: `Tip: type /help for plugin slash commands, or /raw to suppress these hints.`
- Ambiguous-match handling is documented as a text-only disambiguation prompt naming slash-command candidates, for example `/orchestra:review` and `/review-github`.

## Transcript-Simulated Checks

### S1 Functional - Slash Command Confirmation

Prompt: `review my PR`
Expected route row: `review-pr-github`
Expected Claude confirmation names `/review-github` verbatim.
Result: PASS for Phase 1 directive/resolver evidence; live transcript INCONCLUSIVE.

### S2 Functional - Raw Mode

Prompt: `/raw`
Expected acknowledgement: `Raw mode active for this conversation — natural-language requests will not be routed. Any explicit slash command you type clears raw mode.`
Follow-up prompt: `review my PR`
Expected behavior while raw: no routing confirmation.
Prompt: `/plan 567`
Expected behavior: explicit slash command clears raw mode.
Prompt: `just answer normally`
Expected resolver result: no route and raw mode directive applies.
Result: PASS for Phase 1 directive/resolver evidence; live transcript INCONCLUSIVE.

### S4 Intent - Slash Commands, Not Mentions

Expected transcript language names `/review-github`, `/orchestrate`, `/plan`, `/design`, and other slash commands. It does not recommend `@-mention` as the routing surface.
Result: PASS for directive evidence.

### D3 Scope - Active Slash-Command Turn

Context: inside active `/orchestrate` or `/plan` turn.
Prompt: `review my PR`
Expected behavior: no top-level natural-language routing fire because the utterance is inside an active slash-command turn.
Result: PASS for directive evidence; live transcript INCONCLUSIVE.

### D6 Tier Hint - `/orchestrate`

Prompt: `orchestrate issue 567`
Expected confirmation names `/orchestrate` and includes `Will run on sonnet + medium per command frontmatter.`
Result: PASS for directive/config evidence; live transcript INCONCLUSIVE.

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

Prompt: `review this PR or local changes`
Expected response: text-only disambiguation naming slash-command candidates such as `/orchestra:review` and `/review-github`.
Result: PASS for directive evidence; live transcript INCONCLUSIVE.

## Named-Decision Verification

- D1 two-phase rollout: VERIFIED for Phase 1 directive/config evidence; Phase 2 runtime hook remains deferred.
- D3 scoped routing: VERIFIED in Claude guidance.
- D5 instruct-and-wait: VERIFIED in Claude guidance.
- D6 tier hint: VERIFIED in Claude guidance and `/orchestrate` frontmatter.
- D7 raw mode: VERIFIED in Claude guidance and `commands/raw.md`.
- D8 no-match/ambiguous-match: VERIFIED in Claude guidance.
- D10 source of truth: VERIFIED by resolver replay against `skills/routing-tables/assets/routing-config.json`.

## Exploratory Observation

The directive surface is internally consistent for Claude, but the customer-facing live behavior remains dependent on agent adherence until Phase 2 adds a runtime hook.
