---
name: shuffled-integrity-contract
integrity-contract:
  exempt: false
  prosecution-passes: [1, 2, 3]
  atomic: true
  pipeline-stages: [prosecution, defense, judge]
---

# Shuffled Integrity Contract Fixture

This fixture proves the test parser reads the unified contract by key name instead of key order.
