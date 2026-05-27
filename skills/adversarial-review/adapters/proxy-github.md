---
name: review-proxy-github
provides: review
suggested-next-step: /orchestra:review
applies-when: scope.isProxyGithub
integrity-contract:
  pipeline-stages: [proxy-prosecution]
  atomic: n/a
  prosecution-passes: []
  exempt: true
---

# Review Proxy GitHub

Runs the proxy GitHub review adapter when the scope is an external GitHub review intake rather than an in-repo pre-PR review.
