---
name: auto-na-ce-gate-api
provides: ce-gate-api
adapter-type: predicate
suggested-next-step: none
applies-when: not changeset.touchesApiSurface()
---

# Auto N/A CE Gate API

Writes or represents a not-applicable credit for `ce-gate-api` when the predicate matches.
