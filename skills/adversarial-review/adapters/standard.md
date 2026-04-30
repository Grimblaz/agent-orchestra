---
name: review-standard
provides: review
suggested-next-step: /orchestra:review
applies-when: changeset.totalLines >= 200 and not scope.isReReview and not scope.isProxyGithub
---

# Review Standard

Runs the standard adversarial review adapter for changesets at or above the initial 200-line heuristic. [Documents/Design/frame-architecture.md](../../../Documents/Design/frame-architecture.md) is the source for that initial heuristic, and the threshold is tunable in later review-selector work.
