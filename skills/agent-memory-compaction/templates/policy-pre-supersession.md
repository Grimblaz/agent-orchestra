<!-- markdownlint-disable-file MD041 -->

# Pre-supersession compaction policy (agent-orchestra 3.13.2 and earlier)

This is the exact canonical policy text the `agent-memory-compaction` skill shipped
before the never-retire ratchet was superseded. It is preserved verbatim so a store
that adopted that text keeps a reachable reference copy after the plugin updates.

It is reference and fixture data, not a second policy: nothing in the checker looks
for it, and adopting it is not a supported path for a new store.

Use it to keep checking a store that has not migrated:

```text
pwsh <agent-orchestra>/skills/agent-memory-compaction/scripts/Test-MemoryIndexPolicy.ps1 \
  -IndexPath <your index> \
  -PolicyReferencePath <agent-orchestra>/skills/agent-memory-compaction/templates/policy-pre-supersession.md
```

A store checked this way reports `RESULT: clean` exactly as it did before the
supersession. See `skills/agent-memory-compaction/SKILL.md` for the current policy
and for what migrating to the split shape involves.

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
