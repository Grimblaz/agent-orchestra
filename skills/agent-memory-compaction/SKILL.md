---
name: agent-memory-compaction
description: "Lossless-compaction policy for an agent memory store's recall index: the rules a compaction may not break, what may and may not be retired, and a re-runnable check. Use when compacting, pruning, or repairing a memory index, including a compaction the harness hands to an agent. DO NOT USE FOR: writing or recalling individual memory entries; durable session-state and handoff markers (use session-memory-contract); repository documentation cleanup (use documentation-finalization)."
---

<!-- markdownlint-disable-file MD041 -->

## When to Use

- A memory store's index is being compacted, pruned, merged, or rewritten — whether a person is doing it or the harness handed the job to an agent.
- An index's policy header is missing, partial, or has drifted from the text below and needs restoring.
- Someone wants to check an index against the policy without changing it.

Not this skill: `session-memory-contract` owns durable session state and cross-session handoff markers. This skill owns one file — a memory store's recall index — and what may be removed from it.

## What this is for

An agent memory store keeps one index file whose lines point at entry files. Recall is triggered by what a pointer line *says*, not by what the entry body contains. So the cheapest way to make an index smaller — cutting a pointer down to a bare title — leaves the fact on disk and makes it unfindable. That is a silent, unreviewable loss: the store sits outside version control, so there is no diff, no history, and no review of what a compaction removed.

This skill does not build a trigger, a detector, a hook, or a second writer. The compaction already happens and the harness owns when. What ships here is the **policy the existing writer follows**, plus a check anyone can run against a result.

**Two surfaces, and which one governs.** The policy's primary surface is a header inside the index file itself, because it travels with the file being compacted. The copy below is the versioned reference text, delivered to consumers with the plugin. For the store an index belongs to, **the header is authoritative**; this copy is the text it is compared against. After delivery the two can drift — an edit here at a later version leaves an existing header behind, and the check will report divergence correctly but indefinitely. The repair is ordinary: any session already writing that store may edit the header to match the current text below. Until someone does, "diverged" is the honest state, not a false alarm.

## Policy text (canonical)

<!-- policy-canonical-begin -->
**COMPACTION POLICY FOR THIS INDEX — read this before removing or shortening anything below.**

This file is a memory store's recall index: each pointer line names an entry and states what that entry teaches. Recall is triggered by what the pointer *says*, so cutting a pointer down to a bare title leaves the fact in its body and makes it unfindable. Preventing that loss is what this policy is for. It binds any agent or session that compacts, prunes, or rewrites this file, including a compaction the harness hands to an agent.

### Rules a conforming compaction may never break

**R1 — every linked subject carries a recall hook.** The grain is the linked *subject*: every link on a pointer line, not merely every line. A recall hook is text attributable to that subject that states the entry's lesson or load-bearing fact — a clause sitting between that link and the next one (or the end of the line), or link text that itself states the lesson. A pointer whose words all already appear in its target's filename is a bare title, not a hook; neither is filler such as "see body", "details in body", or "more inside", wherever it sits.

**R2 — no shared note over several subjects.** Several subjects may share a line — that is ordinary and encouraged — but each one carries its own hook. A single note placed before or after a run of links, with the subjects themselves left bare, belongs to none of them and is not a hook for any of them. Any separator may join subjects on a line; the hook is what sits with each subject, not the punctuation between them.

**R3 — re-read immediately before writing.** This file is outside version control and many sessions write it, so a copy held in context can be hours stale. Re-read it from disk immediately before every write, and never compose a whole-file write from context. This rule reaches only a writer that reads first; a writer that never reads can still clobber this header, and nothing here prevents that.

### What may be retired, and what may not

*Settlement* is a property of one entry kind, not of the store:

- **`project_` entries settle.** Once the work an entry tracks is closed or merged, its pointer may be **demoted** — moved to the settled section, its clause shortened to the durable lesson — but never deleted together with that lesson. The *settled section* is whichever section of this index collects finished work; if the index has none, create one and say what it holds.
- **`reference_`, `feedback_` and `user_` entries have no settlement notion and are governed as standing.** They are retained indefinitely at full hook quality, regardless of age and regardless of whether an issue they happen to mention is closed. Their subject is a lesson, not a task, and a lesson does not close. Nothing here authorizes retiring one for being old, for being long, or for carrying a closed issue number in its text.

**The ratchet bound: no sequence of applications of this policy removes non-obsolete lesson content from the index.** Removing a pointer is authorized only when either (a) its lesson survives elsewhere in the index and the removal names where, or (b) that lesson is *obsolete* — it describes behavior, tooling, or a surface that no longer exists — and the removal states those grounds. Demote before deleting. Repeated application therefore reaches a fixed point that still carries every non-obsolete lesson, so the index cannot be driven toward only-unfinished-work.

**Where the grounds go.** The store keeps no history, so a justification stated only in a session transcript disappears. Any removal under (a) or (b) appends one line to a `## Retired` section at the end of this index: the entry name, the date, and either where its lesson survives or why it is obsolete. Without that line the removal is unauthorized, because nothing afterwards can tell a lawful removal from an unlawful one. That record is lesson content and is itself subject to the ratchet bound.

### The authorized size-reduction moves

1. **Demote a settled `project_` entry** — move its pointer into the settled section and shorten the clause to its durable lesson, dropping status, PR and commit particulars.
2. **Merge settled `project_` pointers onto one line**, each subject keeping its own hook (R2).
3. **Deduplicate** — where two entries carry the same lesson, fold the distinct content into one, remove the other's pointer, and name the survivor.
4. **Remove an obsolete entry**, pointer and body together, stating the grounds.

Repairing a pointer that arrives without a hook — reading the entry and writing one — is always permitted and is not a size-reduction move. Beyond that repair, the list above is the whole authorization: if a size mandate cannot be met by those four moves, report the shortfall plainly and stop. Do not meet it by breaking R1, R2, or the ratchet bound.

### Checking this file

```text
pwsh <agent-orchestra>/skills/agent-memory-compaction/scripts/Test-MemoryIndexPolicy.ps1 -IndexPath <this file>
```

`<agent-orchestra>` is a clone of the agent-orchestra repository, or its installed plugin copy under `~/.claude/plugins/cache/agent-orchestra/agent-orchestra/<version>/`. If this store's policy text was adapted from the shipped original, keep the adapted reference copy **outside** that cache — plugin updates install into a new per-version directory and leave an adapted copy behind — and pass it with `-PolicyReferencePath <your copy>`.

The check reports three axes: whether this header is present and textually complete against the reference copy; the count of linked subjects carrying no recall hook; and the count of unattributed shared notes. Expected output on a conforming index:

```text
RESULT: clean
header: present, complete
subjects_without_hook: 0
unattributed_shared_notes: 0
```

Exit 0 means clean. Exit 1 means defects, and each offending subject is printed on its own line. Exit 2 means the check refused: it did not recognize this file's structure, could not parse every link it found, found no entry matching the entry-kind vocabulary, or could not read the reference copy — in each case it reports no counts rather than return a plausible wrong verdict. Exit 3 means the invocation itself was wrong, such as an index path that does not exist.

Both count axes are syntactic proxies for questions that are really about meaning, and each has known escapes: novel filler evades the hook axis, a pointer whose words are absent from the filename passes it while saying nothing, and the shared-note axis recognizes a note only when it leads or trails a run of subjects that carry no clauses of their own. It is a floor, not a judge.

**Any session that compacts, prunes, or repairs this index re-runs that check afterward and fixes what it reports.** The check has no trigger; it runs only when someone runs it.
<!-- policy-canonical-end -->

## Adapting this to your store (not part of the compared text)

The canonical text above is written for a store whose entry filenames carry the kind prefixes `reference_`, `feedback_`, `project_` and `user_`. That taxonomy is a local convention of the store this skill was written against, not a standard.

If your store names its entries differently, adapt before adopting:

- Map the four kinds onto whatever kinds your store actually has. The load-bearing distinction is not the prefix — it is **which kinds have a settlement notion** (a task that can close) and which are **standing** (a lesson that cannot). Rewrite the two bullets under *What may be retired, and what may not* to name your kinds, and keep the affirmative statement for the standing ones: silence about a kind is what authorizes a hostile-literal reader to retire it.
- Keep the ratchet bound and R1–R3 verbatim. They do not depend on the taxonomy.
- **Keep your adapted copy outside the plugin cache.** The check defaults its reference to the `SKILL.md` beside it, which lives in a per-version install directory; the next plugin update creates a new directory with the pristine text and silently orphans your adaptation. Save the adapted copy somewhere durable and pass `-PolicyReferencePath` — and put that same invocation in your store's header, so whoever reads the header runs the right comparison.
- The check reads the entry-kind vocabulary from your index's own header when it can find one there, and falls back to the reference copy otherwise. It refuses to report counts when no linked entry matches any kind the policy names. That refusal is the signal that this adaptation has not been done — it is not a bug, and the fix is to adapt the text, not to ignore the exit code.

This section is deliberately excluded from the header-completeness comparison, so an adapted store and this copy can still match on the text that matters. The exclusion is by construction: the comparison spans only the region between the `policy-canonical-begin` and `policy-canonical-end` markers above, and this section sits outside it.

## Running the check

The check lives beside this file:

```text
pwsh skills/agent-memory-compaction/scripts/Test-MemoryIndexPolicy.ps1 -IndexPath <index>
```

`-PolicyReferencePath` defaults to this `SKILL.md`; pass it explicitly to compare a header against a different or adapted reference copy. `-Json` emits the same report as a single JSON object on every terminal path, including refusals and usage errors.

The check reads; it never writes. It has no trigger and no schedule — nothing invokes it but a person or a session that chooses to.

Its regression suite is `.github/scripts/Tests/memory-index-policy.Tests.ps1`, which exercises each axis against modified copies — the property that keeps the axes able to fail.
