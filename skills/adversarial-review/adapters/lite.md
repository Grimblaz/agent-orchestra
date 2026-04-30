---
name: review-lite
provides: review
suggested-next-step: /orchestra:review-lite
applies-when: changeset.totalLines < 200 and not scope.isReReview and not scope.isProxyGithub
---

# Review Lite

Runs the lite adversarial review adapter for changesets below the initial 200-line heuristic. [Documents/Design/frame-architecture.md](../../../Documents/Design/frame-architecture.md) is the source for that initial heuristic, and the threshold is tunable in later review-selector work.
