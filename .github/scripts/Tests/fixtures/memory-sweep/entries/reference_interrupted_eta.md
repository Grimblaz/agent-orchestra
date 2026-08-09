---
name: reference-interrupted-eta
description: "A PATCH built from a local file clobbers appends the server already accepted."
metadata:
  node_type: memory
  type: reference
  admitted: 2026-07-05
---

<!-- markdownlint-disable-file MD041 -->

A PATCH built from a local file clobbers appends the server already accepted.

Re-read the live body immediately before writing it back, every time.
