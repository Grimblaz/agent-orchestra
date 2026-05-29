---
name: review-judge-only
provides: review
suggested-next-step: /orchestra:review-judge
applies-when: scope.isReReview
integrity-contract:
  pipeline-stages: [judge]
  atomic: n/a
  prosecution-passes: []
  exempt: true
---

# Review Judge Only

Runs the judge-only review adapter for re-review scopes where prior prosecution and defense evidence already exists.
