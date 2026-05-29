---
name: design-challenge
integrity-contract:
  pipeline-stages: [prosecution]
  atomic: n/a
  prosecution-passes: [1, 2, 3]
  exempt: false
---

# Design Challenge

Runs the prosecution-only design challenge variant for Solution-Designer Stage 3. The sequence is three prosecution passes: two design-review passes and one product-alignment pass.

## Prosecution-only by design

Defense and judge stages are intentionally absent to preserve Solution-Designer Stage 3's non-blocking inform-but-don't-veto semantic. Adding either stage is a contract change requiring design review.
