---
name: review-judge-only
provides: review
suggested-next-step: /orchestra:review-judge
applies-when: scope.isReReview
integrity-contract:
  pass-blocks: []
  exempt: true
  exempt-reason: "re-review scope; prior prosecution and defense evidence already exists — no new prosecution phase runs"
---

# Review Judge Only

Runs the judge-only review adapter for re-review scopes where prior prosecution and defense evidence already exists.
