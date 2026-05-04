---
name: explicit-skip-process-retrospective
provides: process-retrospective
applies-when: never
suggested-next-step: Document the skip rationale; update when #348 ships the live producer.
reason-required: true
---

# Explicit Skip Process Retrospective

Represents a skipped credit for `process-retrospective`. During the deferral period
(until issue #348 ships), this adapter is selected automatically by
`Build-DeferredPortCreditRow` — no manual invocation needed.

The emitted evidence string always begins with `DEFERRED(#348):` so migration
scripts can detect and convert deferred rows when #348 ships its live producer.
