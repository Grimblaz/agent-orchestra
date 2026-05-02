---
name: review-proxy-github
provides: review
suggested-next-step: /orchestra:review
applies-when: scope.isProxyGithub
integrity-contract:
  pass-blocks: []
  exempt: true
  exempt-reason: "external review intake; single proxy prosecution pass replaces the three-pass structure"
---

# Review Proxy GitHub

Runs the proxy GitHub review adapter when the scope is an external GitHub review intake rather than an in-repo pre-PR review.
