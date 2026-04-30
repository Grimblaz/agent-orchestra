---
name: post-fix-review
provides: post-fix-review
suggested-next-step: /orchestra:review
applies-when: review.sustainedCriticalOrHigh == true
---

# Post-Fix Review

Runs the post-fix review adapter when the review credit sustained a Critical or High finding. The `review.sustainedCriticalOrHigh` boolean is populated by the runtime selector.
