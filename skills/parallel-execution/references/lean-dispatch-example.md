# Lean Dispatch Example — Dispatch-Prompt Economy

Demonstrates the dispatch-prompt economy rule (introduced in issue #472,
documented in `agents/Code-Conductor.agent.md` Step 3 and
`Documents/Design/dispatch-prompt-economy.md`).

**Before** (~2 KB — contract restatement inlined in the dispatch prompt):

> "Call @Code-Smith for Step 2 (event-batch debouncer): implement the
> file-watch debounce. Requirements: the watcher batches events with a
> 500 ms window; overlapping events within the window collapse to one
> emit; the debounce is per-resource-id, not global; if a resource is
> deleted mid-window, emit the delete immediately and cancel the pending
> batch. Acceptance criteria: a 600 ms wait with two events yields one
> callback; a delete mid-window fires immediately and cancels the batch.
> Non-goals: no retry logic; no cross-process coordination. Edge case:
> high-frequency emission (>100 events/sec) must not accumulate unbounded
> pending batches — collapse into one."

**After** (~300 B — canonical-source reference + one novel constraint):

> "Call @Code-Smith for Step 2: Read `<!-- plan-issue-N --> step 2` for the
> full Requirement Contract. Novel constraint not in the plan: the debounce
> timer must survive GC pressure at >100 events/sec (avoid closure capture
> of large event payloads)."

The "after" form is shorter because the Requirement Contract already lives in
the plan comment; only the constraint that is NOT already documented there
travels inline.
