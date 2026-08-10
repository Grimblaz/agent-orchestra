---
name: agent-memory-compaction
description: "Compaction policy for an agent memory store's recall index, plus the sweep it runs on: the rules a compaction may not break, how an entry leaves and where that exit is recorded, the slate procedure and its dispositions, the size budget the index is held to, and a re-runnable check. Use when compacting, pruning, or repairing a memory index, when running or preparing a sweep of a store, or when relocating a line that carries several linked subjects. DO NOT USE FOR: individual memory entries; session-state or handoff markers (use session-memory-contract); repository docs (use documentation-finalization)."
---

<!-- markdownlint-disable-file MD038 MD041 -->
<!-- MD038 (no-space-in-code) fires on the `## ` code span inside the canonical policy region
     below. The space is the pinned rendering of the `^##\s` pattern the check actually matches
     (core:788) and is not a formatting slip; moving it outside the backticks would edit text
     every adopted store is compared against byte-for-byte (-ceq), so this is disabled at the
     file level rather than "fixed" in the region. -->

## When to Use

- A memory store's index is being compacted, pruned, merged, or rewritten — whether a person is doing it or the harness handed the job to an agent.
- An index's policy text is missing, partial, or has drifted from the text below and needs restoring.
- A store is being moved to the split shape — a compact stanza in the index, the full policy and the store's own values beside it.
- Someone wants to check an index against the policy without changing it.
- A **sweep** is being run, or prepared: the owner-present slate where entries are dispositioned, exits are recorded, deferrals expire, and the store's destinations are measured. See *The sweep, and the records it writes* below.

Not this skill: `session-memory-contract` owns durable session state and cross-session handoff markers. This skill owns one file — a memory store's recall index — what may be removed from it, and how big it is allowed to be.

## Composite References

- [references/store-records.md](references/store-records.md): the record shapes a store writes — slate rows, ledger rows, and their field contracts
- [references/sweep-procedure.md](references/sweep-procedure.md): the sweep's own procedure, its dispositions, and the order they are applied in
- [references/compaction-exhibits.md](references/compaction-exhibits.md): the incident detail behind § Compaction Lenses — the sweep each lens was extracted from and the checks that passed while it was wrong

## What this is for

An agent memory store keeps one index file whose lines point at entry files. Recall is triggered by what a pointer line *says*, not by what the entry body contains. So the cheapest way to make an index smaller — cutting a pointer down to a bare title — leaves the fact on disk and makes it unfindable. That is a silent, unreviewable loss: the store sits outside version control, so there is no diff, no history, and no review of what a compaction removed.

There is a second silent loss, and it is not a compaction defect at all. The index is loaded in full at the start of a session, and a load past the harness's limit is truncated without a word. An index over that limit has a tail that exists, conforms, and is never recalled. A policy that only governs *removal* cannot see that, which is why size is one of the things this policy governs and one of the things the check reports.

This skill does not build a trigger, a detector, a hook, or a second writer. The compaction already happens and the harness owns when. What ships here is the **policy the existing writer follows**, plus a check anyone can run against a result.

## Two surfaces, and which one governs

For the store an index belongs to, **that store's own policy text is authoritative**; the copy below is the versioned reference it is compared against. After delivery the two can drift — an edit here at a later version leaves an existing store behind, and the check reports divergence correctly and indefinitely.

**Divergence is not a repair ticket.** This version rewrote the policy: the never-retire ratchet is superseded (see the supersession clause in the canonical text below). A store whose text predates that diverges *because its retention regime is the old one*. Mechanically overwriting that text would swap the store's retention rules without its owner deciding to — the kind of unrecorded, destructive change the new policy exists to prevent. Three onward paths, all lawful, and the store's owner picks:

- **Adopt the split shape** — see *Adopting the split shape* below. That is the shape the current text is written for.
- **Keep checking against the text you adopted.** The pre-supersession policy ships at `skills/agent-memory-compaction/templates/policy-pre-supersession.md`. Pass it with `-PolicyReferencePath` and the store reports clean exactly as it did before.
- **Do nothing.** A diverged verdict is an honest report, not a failure. Nothing in this skill or its check obliges any store to migrate, and no release will start obliging it.

Where a store's text has drifted for an ordinary reason — a typo, a half-finished write — repairing it to match the reference it was adopted from is still ordinary work, and any session already writing that store may do it.

## Policy text (canonical)

This is the text a store adopts. Under the split shape it lives in the store's policy file beside the index; a store that has not split keeps it as the index's own header. It is sized for a file of its own: a store that keeps it in-index pays its full length against the same budget as the content, which is the cost the split exists to remove.

<!-- policy-canonical-begin -->
**COMPACTION POLICY FOR THIS STORE — read this before removing or shortening anything in the index.**

A memory store's recall index is a file whose lines point at entry files. Each pointer line names an entry and states what that entry teaches. Recall is triggered by what the pointer *says*, so cutting a pointer down to a bare title leaves the fact in its body and makes it unfindable. Preventing that loss is what this policy is for. It binds any agent or session that compacts, prunes, or rewrites the index, including a compaction the harness hands to an agent.

### This policy supersedes the never-retire ratchet

An earlier version of this text held a **ratchet bound**: no sequence of compactions could ever remove non-obsolete lesson content, standing entries were retained indefinitely regardless of age, and only settled entries had any removal path at all. That rule is **superseded — replaced, not relaxed**. It made the store an archive, and it made the store's own budget unreachable: the protected floor grew monotonically past the size the index can actually load, so the tail stopped being recalled while the check still reported everything clean.

Three rules replace it. They keep the store honest without keeping it forever:

1. **No silent exits.** Every departure from passive recall — promotion, demotion to a cold archive, or outright removal — is recorded with its reason and its destination. An unrecorded removal is unauthorized, because nothing afterwards can tell a lawful removal from an unlawful one.
2. **An exit is lawful only when its destination verifiably carries the lesson at landing time.** "Someone will write it up later" is not a destination. The destination is read and confirmed to carry the lesson at the moment of the exit, not assumed. Drift in that destination afterwards is accepted loss, not grounds for keeping the entry hot forever.
3. **Destructive acts execute only behind an owner-present slate.** Exits, demotions, structural rewrites and body deletions are *proposed* by any session and *executed* only in an interactive sweep with the store's owner present. An unattended session may add entries and record proposals; it may not remove anything.

The store is temporary working storage, not an archive. An entry is recent working state, in flight toward a permanent home, or overdue to leave.

### Rules a conforming compaction may never break

**R1 — every linked subject carries a recall hook.** The grain is the linked *subject*: every link on a pointer line, not merely every line. A recall hook is text attributable to that subject that states the entry's lesson or load-bearing fact — a clause sitting between that link and the next one (or the end of the line), or link text that itself states the lesson. A pointer whose words all already appear in its target's filename is a bare title, not a hook; neither is filler such as "see body", "details in body", or "more inside", wherever it sits.

**R2 — no shared note over several subjects.** Several subjects may share a line — that is ordinary and encouraged — but each one carries its own hook. A single note placed before or after a run of links, with the subjects themselves left bare, belongs to none of them and is not a hook for any of them. Any separator may join subjects on a line; the hook is what sits with each subject, not the punctuation between them.

**R3 — re-read immediately before writing.** This file is outside version control and many sessions write it, so a copy held in context can be hours stale — and a copy that arrived through a truncated load is missing its tail entirely. Re-read it from disk immediately before every write, and never compose a whole-file write from context. This rule reaches only a writer that reads first; a writer that never reads can still clobber the file, and nothing here prevents that.

### What may be retired, and what may not

Every entry is temporary; no kind has tenure. *Settlement* no longer decides whether an entry may leave — its exit does.

- **The critical class stays until its lesson has landed.** A lesson is critical when its loss would be expensive, or when its recurrence would be invisible without it. (A lesson that catches an otherwise-silent failure is the canonical example, not the definition.) A critical entry stays in the index until its lesson verifiably lives in a permanent home; demotion counts as leaving. Critical entries are dispositioned first at every sweep and are never deferred twice.
- **Ordinary lessons are self-healing.** An ordinary lesson removed without being promoted re-earns its place if its problem recurs. That bounded loss is accepted doctrine, not a defect: it is what keeps the index inside a budget a reader actually loads. This is the one thing the superseded ratchet forbade and this policy permits — and it is permitted only through a recorded exit, never through quiet trimming.
- **`project_` entries settle.** Once the work an entry tracks is closed or merged, its pointer may be **demoted** — moved to the settled section, its clause shortened to the durable lesson. The *settled section* is whichever section of the index collects finished work; if the index has none, create one and say what it holds.
- **`reference_`, `feedback_` and `user_` entries do not settle.** A lesson does not close, and age alone never authorizes retiring one — nor does length, nor a closed issue number in its text. But not-settling is not tenure: a standing entry leaves by **promotion** to a permanent home, or, where no home has been decided, by demotion booked honestly as accepted recall loss.

**Trimming is still never a size-reduction move.** Whatever a compaction is under pressure to do, it may not meet a size mandate by cutting hooks, merging subjects under one note, or shortening a pointer to a bare title. Those destroy the recall property the index exists for and leave no trace that they did.

### Exits

**Where the record goes.** The store keeps no history, so a justification stated only in a session transcript disappears. Every exit appends one line to a `## Retired` section at the end of the index, or to the store's own exit record where it keeps one: the entry name, the date, the disposition, the reason, and the destination. That record is lesson content and is itself governed by this policy.

**Dispositions.** An entry leaves by **promotion** (its lesson lands in a permanent home — a repository, a durable instruction file, a versioned document), by **demotion** (moved to a cold archive, booked as accepted recall loss, never called retention), or by **removal** (it no longer earns a place, and the store self-heals if its problem recurs). Promotion is the primary outflow; the other two are exception paths, each booked honestly for what it is.

**Deferral expires.** An entry held hot at a sweep is *deferred*, not tenured. A deferral comes back at the next sweep. Nothing can be parked as keep-hot forever, and a critical entry may not be deferred twice.

### The authorized size-reduction moves

1. **Promote and remove** — the lesson lands in a permanent home, the landing is confirmed by reading that home, the exit is recorded, and the pointer goes.
2. **Demote to the cold archive** — the pointer moves out of passive recall, recorded as accepted recall loss.
3. **Demote a settled `project_` entry** — move its pointer into the settled section and shorten the clause to its durable lesson, dropping status, PR and commit particulars.
4. **Merge settled `project_` pointers onto one line**, each subject keeping its own hook (R2).
5. **Deduplicate** — where two entries carry the same lesson, fold the distinct content into one, remove the other's pointer, and name the survivor.
6. **Remove an obsolete entry**, pointer and body together, stating the grounds.

Repairing a pointer that arrives without a hook — reading the entry and writing one — is always permitted and is not a size-reduction move. Beyond that repair, the list above is the whole authorization, and every move on it that removes a pointer is a destructive act: it needs its exit record and an owner-present slate. If a size mandate cannot be met by these moves at a slate, report the shortfall plainly and stop.

### The size budget

The index is loaded in full at the start of a session, and a load past the harness's limit is truncated silently. So the index is held to a budget, and the budget is a formula, never a hand-picked number:

```text
budget = fraction * the freshest recorded limit observation
```

Both inputs are recorded in this store's own values, with attribution: who observed the limit, by what method, and on what date. No phase substitutes an absolute for the formula. The limit is an external surface — observed, not documented, and free to change without notice — which is why the budget is pinned to a *dated* observation and why an observation that has gone stale is called out rather than trusted quietly. The default staleness bound is 30 days; a store may record its own.

**The counting rule.** Sizes are counted in **characters**: the file decoded as UTF-8, every CRLF and lone CR normalized to a single LF, then the length of the resulting text in UTF-16 code units. A character outside the Basic Multilingual Plane — most emoji — counts as two under that rule. The rule is stated so that a measurement reproduces from the file on disk; it is not a claim that the harness counts identically, and closing that gap is what re-observing the limit is for.

A stale observation is reported, not treated as a defect: the number may still be right, and guessing a fresher one would be worse than saying how old this one is.

### Where these rules live

This policy governs compaction, and it reaches a session only if that session reads it. So a store places the rules in three parts, and skipping one leaves a real gap rather than a tidier file:

1. **A stanza in the index**, above its first section heading, carrying R1–R3 in operative form plus a pointer to where this text lives. That is what a writer who never opens the policy file still reads.
2. **This policy text beside the index**, together with that store's own values — the budget fraction, the staleness bound, and the dated limit observations. Compaction, sweeps and exits are governed here.
3. **The admission rule, in whatever instruction file every session already loads** — for a Claude Code store, the user-global `CLAUDE.md`. That is where an entry is required to state its recall trigger and its exit plan at the moment it is written. Neither this text nor the check can reach that surface. A store that places the first two limbs and skips the third has a governed outflow and an ungoverned inflow, and will notice.

A store that keeps this text as the index's own header rather than splitting it out is putting limbs 1 and 2 in one file. That is still lawful and still supported; it simply pays this text's full length against the same budget as the content.

### Checking the index

```text
pwsh <agent-orchestra>/skills/agent-memory-compaction/scripts/Test-MemoryIndexPolicy.ps1 -IndexPath <the index>
```

`<agent-orchestra>` is a clone of the agent-orchestra repository, or its installed plugin copy under `~/.claude/plugins/cache/agent-orchestra/agent-orchestra/<version>/`. If this store's policy text was adapted from the shipped original, keep the adapted reference copy **outside** that cache — plugin updates install into a new per-version directory and leave an adapted copy behind — and pass it with `-PolicyReferencePath <your copy>`.

The check reports four axes: whether this store's policy text is where it should be and textually complete against the reference copy; the size of the index against its budget; the count of linked subjects carrying no recall hook; and the count of unattributed shared notes. Expected output on a conforming split store:

```text
RESULT: clean
policy: split - stanza and policy file both match the reference
size: 4,804 of 19,982 characters (budget = 0.80 of the 24,978-character limit observed 2026-08-06)
subjects_without_hook: 0
unattributed_shared_notes: 0
```

The size axis is **data-driven**: it is evaluated only for a store that records budget inputs, and it reports `not evaluated` for a store that records none. A store that records inputs the check cannot use — no observation, a malformed one, or one counted in some other unit — gets `could not verify` naming the cause, on that axis alone, with the other three still counted.

Exit 0 means clean. Exit 1 means defects, and each offending subject is printed on its own line. Exit 3 means the invocation itself was wrong, such as an index path that does not exist.

Exit 2 means the check refused — it reports no counts rather than return a plausible wrong verdict. It refuses when:

- the index's structure is not recognized (no section heading, or no pointer line at all);
- a link-like construct could not be parsed unambiguously, so some subject would be judged silently — including links nested inside one another, where which subject a clause belongs to has no answer;
- no linked entry matches any entry kind the policy names, and this store's own policy text was available to read;
- the index, the reference copy, or this store's policy file could not be read, or something that is not a file sits where the policy file should be;
- the reference copy is malformed — missing its markers, or carrying a `## ` heading inside a compared region;
- this store's policy file is malformed, missing the markers around its policy text;
- the stanza is malformed — opened and never closed above the first section heading, empty, naming no policy file, or naming a path that could not resolve to a file beside the index.

Both count axes are syntactic proxies for questions that are really about meaning, and each has known escapes: novel filler evades the hook axis, a pointer whose words are absent from the filename passes it while saying nothing, and the shared-note axis recognizes a note only when it leads or trails a run of subjects that carry no clauses of their own. The size axis is exact about the file and only as good as the limit observation behind it. It is a floor, not a judge.

**Any session that compacts, prunes, or repairs the index re-runs that check afterward and fixes what it reports.** The check has no trigger; it runs only when someone runs it.
<!-- policy-canonical-end -->

## Hot-index stanza (canonical)

Under the split shape the index itself carries this stanza — and only this stanza — above its first section heading. It is what a writer that never opens the policy file still reads, so it carries the three write rules in operative form plus a pointer to where the rest lives.

<!-- stanza-canonical-begin -->
**COMPACTION RULES FOR THIS INDEX — read before removing or shortening anything below.**

Each pointer line names an entry and states what that entry teaches. Recall fires on what the pointer *says*, so a pointer cut down to a bare title leaves its lesson on disk and unfindable.

- **R1 — every linked subject carries a recall hook.** Every link, not merely every line: a clause between that link and the next, or link text that itself states the lesson. Words that already appear in the target's filename are not a hook, and neither is filler ("see body", "more inside").
- **R2 — no shared note over several subjects.** Subjects may share a line, but each carries its own hook. One note placed before or after a run of bare links belongs to none of them.
- **R3 — re-read from disk immediately before every write.** This file sits outside version control, many sessions write it, and a loaded copy may have been silently truncated. Never compose a whole-file write from context.

The full policy — what may be retired, how an exit is recorded, and this store's own budget — lives in the policy file named on the marker line above this stanza. Read it before any compaction, sweep, or removal.
<!-- stanza-canonical-end -->

## Adopting the split shape

Splitting moves the policy text out of the index and leaves the budget to the content. It is three limbs, and a store needs all three.

### Limb 1 — the stanza, in the index

Copy the canonical stanza above into the top of the index — above its first section heading — wrapped in these two markers, with the policy file's path on the opening one:

```text
<!-- memory-policy-stanza-begin: POLICY.md -->
...the canonical stanza text...
<!-- memory-policy-stanza-end -->
```

**The opening marker must be the index's first non-blank line**, at column 0, with the closing marker above the index's first section heading. That is the whole rule for declaring the split shape, and its bluntness is the point: an index cannot *quote* something at its own first line without that line being its first line. So a store may reproduce these instructions anywhere in itself — as a note, inside a fence, verbatim — and the check still reads the shape the store actually has. Anything that is not the first non-blank line is quoted text, whatever it says.

A gentler rule was tried and does not work. Searching the header region, then requiring column 0, then tracking fenced-code state each left a way for quoted text to answer the question — and the fence tracker went wrong in both directions at once, since quoting a fenced block needs a longer outer fence whose inner delimiter looks like a close, and an unclosed fence hid a *real* stanza and silently switched the size axis off for a store that had done everything right. Position is decidable; "is this line quoted?" is not.

The path is relative to the index's own directory and must resolve to a file beside it. It is an instance value and sits on the marker line, outside the compared text, so naming a different file never reads as a divergence. Under the split shape the index carries the stanza and not the policy: a **run** of policy lines left behind anywhere in it is reported as migration residue. A sentence or two is not — an index quoting its own check command or citing a rule in a pointer clause is doing something ordinary, and a threshold that failed those would fail the very stores this exists to migrate.

### Limb 2 — the policy file, beside the index

Create the file the marker names. It carries the canonical policy text between `<!-- policy-canonical-begin -->` and `<!-- policy-canonical-end -->`, and this store's own values between `<!-- store-values-begin -->` and `<!-- store-values-end -->` — outside the canonical region, so per-store numbers never read as policy drift:

```text
<!-- store-values-begin -->
budget_fraction: 0.80
staleness_bound_days: 30
limit_observation: 2026-08-06 | 24978 | characters | truncation-boundary test (agent-orchestra#1015 review round 3)
<!-- store-values-end -->
```

`limit_observation` is `date | value | unit | method`, and it is the one key that repeats: re-observing the limit **appends** a row and the latest date governs, so nothing already recorded is rewritten. `budget_fraction` and `staleness_bound_days` are optional; the defaults are 0.80 and 30 days.

Add one more section to that file, **outside** both marked regions, so a session arriving for a sweep can find the machinery by following a path rather than inferring a directory:

```markdown
## Sweep machinery (not part of the compared text)

Sweeps of this store follow `skills/agent-memory-compaction/references/sweep-procedure.md` in the
agent-orchestra plugin. Its records live beside this file: `LEDGER.md` (exits and proposals),
`SLATE.md` (critical flags, deferrals, landings in flight), and `ARCHIVE.md` (demoted pointers,
created at the first demotion). Their shapes are defined in
`skills/agent-memory-compaction/references/store-records.md`.
```

Text outside the canonical and values regions is not compared, so this costs the store nothing on the policy axis. A store that split before this machinery shipped has no such section; its first sweep writes one, which is step 0 of the procedure.

**The whole values block is optional too, and that is a decision rather than an oversight.** A store may split for the policy hygiene alone — the text out of the index, one place to adapt it — and record no budget inputs at all. It then reads `size: not evaluated` and stays clean on the other three axes. The reason is not indulgence: the budget is a fraction of *an observed limit*, and that observation belongs to the installation, not to this skill. A store with no size problem has no reason to run a truncation-boundary test, and making the block mandatory would push it toward copying the number out of the example above — one installation's measurement wearing another's name, which is precisely the hand-picked absolute the formula rule exists to forbid. Record budget inputs when the budget is a problem you actually have.

**Keys this version does not know**, written with an `x-` prefix, are ignored and reported rather than refused — a store outlives the plugin version that wrote it, so a later release needs somewhere to record a sweep date or a ledger pointer without breaking an older checker reading the same file. Any *other* unrecognized key is still an error, because that is what a typo looks like, and a budget quietly computed from a record the checker only half understood is the failure this parser exists to prevent.

The record is checked as a record, not only line by line, because a file of individually valid lines can still say something false. Recording the values region twice, repeating a key that is not `limit_observation`, and dating an observation in the future are each reported rather than silently resolved — the last because the freshest date governs, so a mistyped year would outrank every honest observation appended after it, permanently, while the store went on reading clean.

### Limb 3 — the admission rule, where the writing sessions read

The stanza and the policy file govern *compaction*. What governs *admission* is whatever instruction file every session already loads — for a Claude Code store, the user-global `CLAUDE.md`. That is where an entry is required to state its recall trigger and its exit plan. Neither this skill nor its check can reach that file; a store that skips this limb has a governed outflow and an ungoverned inflow, and will notice.

### While you are mid-migration

Until the policy file exists the store is **half-migrated**: the check names that state specifically, as a defect rather than a refusal. It stays distinct from a policy file that exists and cannot be read, and from a stanza whose declared path could never name a file beside the index — that last is a malformed declaration, not a store waiting to create something. A half-migrated store is also not refused over its entry-kind vocabulary: its policy text lives in a file it has not written yet, which is not the same as never having adapted.

## Adapting this to your store (not part of the compared text)

The canonical text above is written for a store whose entry filenames carry the kind prefixes `reference_`, `feedback_`, `project_` and `user_`. That taxonomy is a local convention of the store this skill was written against, not a standard.

If your store names its entries differently, adapt before adopting:

- Map the four kinds onto whatever kinds your store actually has. The load-bearing distinction is not the prefix — it is **which kinds settle** (a task that can close) and which are **standing** (a lesson that cannot). Rewrite the bullets under *What may be retired, and what may not* to name your kinds, and keep the affirmative statement for the standing ones: silence about a kind is what authorizes a hostile-literal reader to retire it.
- **Write each kind as a backticked identifier ending in an underscore** — `` `task_` ``, not `task-` or plain `task`. That is not decoration: it is the declaration the check reads to learn your store's vocabulary, and a kind written any other way is invisible to it. A policy whose kinds are all written some other way names no kinds at all, and the check refuses rather than guessing.
- Keep R1–R3 and the three replacement rules verbatim. They do not depend on the taxonomy.
- **Keep your adapted copy outside the plugin cache.** The check defaults its reference to the `SKILL.md` beside it, which lives in a per-version install directory; the next plugin update creates a new directory with the pristine text and silently orphans your adaptation. Save the adapted copy somewhere durable and pass `-PolicyReferencePath` — and put that same invocation in your store's stanza or header, so whoever reads it runs the right comparison.
- **A reference copy carries both compared texts, not just the policy.** `-PolicyReferencePath` supplies the canonical policy *and* the canonical stanza, so an adapted copy needs a `<!-- stanza-canonical-begin -->` / `<!-- stanza-canonical-end -->` region as well — copy it verbatim from this file unless you adapted the stanza too. Copying only the policy region produces a file that checks a legacy store fine and refuses every split store. For the same reason a store's own policy file cannot double as its reference copy: it carries the policy region and never the stanza one.
- The check reads the entry-kind vocabulary from **your store's own policy text** — the policy file under the split shape, the index's header otherwise — and falls back to the reference copy when it finds none there. It refuses to report counts when no linked entry matches any kind the policy names. That refusal is the signal that this adaptation has not been done — it is not a bug, and the fix is to adapt the text, not to ignore the exit code.

This section is deliberately excluded from the policy comparison, so an adapted store and this copy can still match on the text that matters. The exclusion is by construction: the comparison spans only the region between the `policy-canonical-begin` and `policy-canonical-end` markers above, and this section sits outside it.

## Stores that have not split

A store still carrying the full policy as its index header keeps working, and keeps being supported. Checked against this version's reference it reports its policy text as **present but diverged**, because this version rewrote that text — the divergence is real, and the report states both readings of it, since the check deliberately cannot tell which text a store adopted.

The size axis reads `not evaluated` for such a store. The check reads budget inputs from a split store's policy file and from nowhere else, so an unsplit store's size is never measured against a budget — an axis that fired anyway would be migration pressure rather than a measurement. If you write a `store-values` block into an unsplit index it will be ignored; the axis says only that no inputs were read, which is why that sentence is worded the way it is.

To keep a clean verdict without changing anything, check against the preserved pre-supersession text:

```text
pwsh <agent-orchestra>/skills/agent-memory-compaction/scripts/Test-MemoryIndexPolicy.ps1 -IndexPath <the index> -PolicyReferencePath <agent-orchestra>/skills/agent-memory-compaction/templates/policy-pre-supersession.md
```

That file ships with the plugin and is the exact text this skill carried before the supersession, so a store that adopted it reports `RESULT: clean` unchanged. It is reference data, not a second supported policy: nothing in the check looks for it, and a new store should adopt the current text instead.

## The sweep, and the records it writes

The policy governs what a compaction may not break and how big the index is allowed to be. What it does *not* say, on its own, is how the store actually gets smaller: that happens at a **sweep** — the owner-present slate the third replacement rule requires before anything destructive executes. Two documents carry it:

- [`skills/agent-memory-compaction/references/sweep-procedure.md`](references/sweep-procedure.md) — when a sweep is due, what an unattended session may and may not do, and the eight steps, 0 through 7: write the store-side pointer, enumerate the corpus from disk, take the first things first, disposition, check staleness, measure the exit destinations, reconcile the partition, record the sweep.
- [`skills/agent-memory-compaction/references/store-records.md`](references/store-records.md) — the three files a sweep writes and reads. `LEDGER.md` holds every disposition a slate executed or a session proposed, plus the sweep's own records; `SLATE.md` holds critical flags, deferrals and landings in flight; `ARCHIVE.md` is the cold archive a demotion moves a pointer into. None of the three is loaded at session start, which is what keeps the record of what left from being charged against the budget of what stays.

Four read-only instruments sit beside the check and make the procedure's checks and gates produce artifacts rather than assertions:

```text
pwsh skills/agent-memory-compaction/scripts/Get-MemorySweepInventory.ps1 -IndexPath <index> -OutputPath <artifact>
pwsh skills/agent-memory-compaction/scripts/Test-MemorySweepDisposition.ps1 -Gate <deferral|exit|admission|reconcile> -IndexPath <index> ...
pwsh skills/agent-memory-compaction/scripts/Test-MemorySweepPartition.ps1 -InventoryPath <artifact> -IndexPath <index>
pwsh skills/agent-memory-compaction/scripts/Measure-MemorySurface.ps1 -Path <destination>
```

The procedural checks live in the procedure rather than in the check itself, deliberately: at the population sizes these stores actually reach, a person following a written step catches what a fourth axis would, and the check stays a thing with four axes and three parameters that anyone can reason about. `.github/scripts/Tests/memory-sweep-procedure.Tests.ps1` exercises the procedure against a committed fixture store, so its demonstrations are re-runnable rather than narrated once.

## Running the check

The check lives beside this file:

```text
pwsh skills/agent-memory-compaction/scripts/Test-MemoryIndexPolicy.ps1 -IndexPath <index>
```

`-PolicyReferencePath` defaults to this `SKILL.md`; pass it explicitly to compare against a different or adapted reference copy. It supplies both compared texts — the canonical policy and the canonical stanza. `-Json` emits the same report as a single JSON object on every terminal path, including refusals and usage errors. Those three parameters are the whole surface, unchanged by the split.

The check reads; it never writes. It has no trigger and no schedule — nothing invokes it but a person or a session that chooses to.

Its regression suite is `.github/scripts/Tests/memory-index-policy.Tests.ps1`, which exercises each axis against modified copies — the property that keeps the axes able to fail.

## Compaction Lenses

> **Authoritative source**: which lessons are promoted here, what anchor each one lives at, and the trigger text that has to reach a reader are recorded in `Documents/Planning/lesson-promotion-manifest.json`. `.github/scripts/Tests/lesson-promotion-manifest.Tests.ps1` is what stops this section and that manifest drifting apart, and it is the suite a red comes from. **Renaming a heading below is a migration, not a regression** — update that lesson's `anchor` in the manifest in the same commit as the rename. A red naming an anchor you just renamed is reporting a manifest row left behind, not a lost lens.

One way a sweep completes, checks clean on every aggregate it has, and leaves acts undone.

#### Relocating a line to preserve one subject silently preserves every other subject on it

When a bulk operation's unit of **decision** is the subject but its unit of **edit** is the line, the two disagree wherever a line is mixed — so re-homing a pointer line to keep one entry hot carries along every other entry that line names, including ones whose disposition authorised removal. The result is entries holding an executed ledger record, an archive line, **and** a live pointer at once. Every aggregate check passes: the index is under budget, the checker returns clean, hookless subjects and unattributed notes are zero, and the partition check reports nothing unaccounted — because the strays are lawful pointers with intact hooks, and the partition asks whether anything left *without* a record, never whether everything *with* a record actually left. **Write the check at the decision grain and assert set equality, not a count** — a count can match exactly while several acts have not happened. Run it in all three directions: removal-authorising dispositions still present in the index (want 0), keep-hot entries missing from the index (want 0), demoted subjects missing from the archive (want 0). The fix shape is to rebuild the line from its subject segments keeping only the survivors, each hook verbatim — and do not shorten a surviving hook while you are in there, because that is trimming and trimming is never a size-reduction move. Exhibit: [references/compaction-exhibits.md](references/compaction-exhibits.md) § Five entries with a ledger record and a live pointer.

## Gotchas

Landmines in this skill's own surfaces. Each has gone off at least once.

- **Any edit inside a compared region re-diverges every adopted store.** The comparison is whole-block and case-sensitive (`-ceq`), so a typo fix in the canonical policy or stanza text makes every store that adopted the previous wording report as diverged — correctly, and indefinitely. Edit compared text deliberately or not at all; text outside the two marked regions costs nothing.
- **A `## ` heading inside a compared region makes the check refuse — for every store.** New canonical prose uses `###` or deeper. There is no margin here: the refusal is global, not per-store.
- **A bare marker line inside compared text truncates the region of every store that copies it.** A line that *is* `<!-- policy-canonical-end -->` ends the block when the store's own file is read back. Describing a marker is fine; a line consisting only of one is not.
- **The stanza is recognized by position, not by content.** It must be the index's first non-blank line, at column 0. That bluntness is deliberate — "is this line quoted?" has no decidable answer, and every gentler rule tried let quoted text change the shape the check read.
- **A store's own policy file cannot double as its reference copy.** A reference copy supplies *both* compared texts; a policy file carries the canonical policy region and never the stanza one, so using it as the reference checks legacy stores fine and refuses every split store.
- **The values region is append-only, and rewriting it destroys state invisibly.** The check keeps no history, so a store measured for months reads `not evaluated` after one tidy regeneration and nothing reports that anything was lost. Re-observing appends a row; the freshest date governs.
- **A single `x-` key written into a values-less store flips it from clean to exit 1.** The region's presence is keyed on its markers, not on its contents, so a region holding only forward-compatibility keys records budget inputs the check cannot use — `could not verify`, a defect, on a store that had lawfully opted out of measurement. Write to the values region only when it already exists, or carry a `limit_observation` in the same write.
- **`templates/policy-pre-supersession.md` is not editable reference prose.** It is the exact pre-supersession text that backs the `-PolicyReferencePath` guarantee for never-adapted legacy stores. An edit there silently breaks a shipped promise no suite re-proves.
