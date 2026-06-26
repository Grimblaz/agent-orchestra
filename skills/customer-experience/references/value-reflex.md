<!-- markdownlint-disable-file MD041 MD003 -->

# Value Reflex — Outcome Meanings & Recording Contract

Extracted from `skills/customer-experience/SKILL.md` (`### Value Reflex (first beat)`). The compact reflex (three prompts, the `frame it` skip affordance, and the advisory-only framing) stays inline in the skill; this reference carries the outcome-meaning table and the recording contract.

## Advisory recommendation outcomes

Based on the Bet / Falsifier / Alternative answers, the agent recommends exactly one of:

| Outcome | Meaning |
| --- | --- |
| `Proceed-full` | Bet is clear, falsifier is narrow, no better alternative — proceed with full framing |
| `Proceed-lite` | Bet is plausible but lite framing is sufficient; consider abbreviating scope |
| `Shrink` | The scope is likely wider than the bet warrants; consider scoping down first |
| `Park` | The bet is unclear or the falsifier is too broad; worth revisiting later |
| `Decline` | A better alternative exists or the falsifier is nearly certain; recommend against building |

**Advisory only** — the owner decides and can proceed regardless of the recommendation. A recommendation to `Decline` is honest advice, not enforcement.

## Recording accepted outcomes

- An accepted `Park` or `Decline` is the only outcome recorded. The agent appends a `worth-it-{ISSUE_NUMBER}` entry to the `engagement-record-experience-{ISSUE_NUMBER}` burst and applies `status: parked` or `status: declined` to the issue. `same-decision-resume` suppresses re-prompting on re-entry.
- An accepted `Proceed-*` or `Shrink` is **not** recorded — the reflex re-runs on re-entry unless a prior Park/Decline exists.
- Re-scope invalidation: explicit owner re-open signals the earlier decision no longer applies. Auto-detection is out of scope.
