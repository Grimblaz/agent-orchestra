---
name: reference-ordinary-alpha
description: "A stale read wins the race and the retry cap silently drops the write."
metadata:
  node_type: memory
  type: reference
  admitted: 2026-06-14
---

<!-- markdownlint-disable-file MD041 -->

A stale read wins the race and the retry cap silently drops the write.

The tail of that batch never lands at all, and the only symptom is a count that does not add up.
