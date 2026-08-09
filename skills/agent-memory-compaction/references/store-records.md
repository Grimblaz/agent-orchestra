# The store's records — ledger, slate state, cold archive

The compaction policy binds every exit to a record and every destructive act to an owner-present
slate. This file defines the records that obligation runs on: what they are, what shape they carry,
how long they live, and which policy rules reach them. The procedure that writes them is
[`skills/agent-memory-compaction/references/sweep-procedure.md`](sweep-procedure.md).

Three files sit beside the index, and **none of them is loaded at session start**. That is the point
of them. History displacing recall is the disease the size budget exists to treat, so the record of
what left the index may not be charged against the budget of what stays in it. The canonical policy
text already leaves the door open — an exit "appends one line to a `## Retired` section at the end of
the index, **or to the store's own exit record where it keeps one**" — and these files are that
second branch. A split store takes it; the in-index `## Retired` section remains lawful for a store
that keeps none of this, and remains the worse option for the same reason it always was: it spends
hot budget, and it sits at the tail of the index where a truncated load eats first.

| File | Holds | Written | Read |
| --- | --- | --- | --- |
| `LEDGER.md` | every disposition a slate executed or a session proposed, and the sweep's own records — the history of what the slate did | appended, by any session for a proposal, by a slate for an execution | at reconciliation, and by a reader asking what happened to an entry |
| `SLATE.md` | slate state for entries still in the index — critical flags, deferrals, landings in flight | appended, latest row per entry-and-track governs | as the slate's first act, in one read |
| `ARCHIVE.md` | demoted pointers — the cold archive, booked as accepted recall loss | by a slate, on demotion | on demand, by a reader who went looking |

`SLATE.md` is separate from `LEDGER.md` deliberately. The slate's first act has to enumerate every
critical entry and every deferral before it takes any disposition, and a first act that must fold the
whole exit history to answer "is this entry critical?" is unexecutable at any population worth
sweeping.

**Neither file asserts a fact the other asserts.** The ledger is authoritative for what a slate
*did*; the slate file carries the current assessment state of entries that are *still in the index*.
An earlier revision broke this by giving the slate a `presence` track that also claimed an entry had
left — two stores asserting one fact, with no cross-check, which is how they come to disagree. That
track is gone. When the corpus walk needs to know whether an orphan body has already exited, it reads
the ledger, which is the only file that says so.

## The region shape: one marker, and everything after it

Each record file carries an **opening marker and no closing one**. Records run from the marker to the
end of the file:

```text
<!-- memory-ledger-begin -->
...one record per line, to the end of the file...
```

That is not a shortcut. It is what makes the append-only discipline *true* rather than merely stated.
A region bounded at both ends cannot be appended to: an `Add-Content` write lands after the closing
marker, outside the region, where no reader ever looks — so every writer would have to read the whole
file, insert before the end marker, and write it back, which is exactly the read-modify-write that
silently discards whatever a concurrent session landed in between. Bounded at one end, an append is
an append.

Two consequences worth stating, because both were defects in an earlier revision:

- **A second opening marker is a refusal, not a preference.** Which region governs has no answer, so
  no record in that file is read and the state is reported. The sibling policy checker already ships
  this guard for its own regions; a reader that silently took the first region could have the whole
  history of a store replaced by a copy-pasted example.
- **Blank lines are skipped and nothing else is.** A line the parser cannot read becomes a *malformed
  record* the next slate sees. An earlier revision skipped `#`-prefixed lines, which meant one typed
  character in front of an exit record erased it while the machinery still reported clean — an
  in-place unrecord, in the file whose whole purpose is that nothing leaves without a trace.

## Entry identity — the life key

An ordinary lesson removed re-earns its place if its problem recurs. That is doctrine, not a defect —
and it guarantees name reuse, because the natural slug for a problem is the same slug the second time
the problem shows up. A record keyed on name alone therefore makes the second life inherit the first
life's exit record, and a reconciliation that reasons "this name has an exit record, so it was
handled" reaches exactly the wrong answer about an entry that is sitting in the index right now.

So an entry's identity in these records is its **life key**:

```text
<entry-name>@<admitted-date>
```

`<entry-name>` is the entry's filename without its extension, and it may not contain `@` — the key is
decoded on the last `@`, and a name carrying one would decode two ways. `<admitted-date>` is the date
the entry was admitted to the store, in `yyyy-MM-dd`, recorded in the entry's own frontmatter under
`metadata.admitted`.

**The living side carries the binding, or the read is undecidable.** An entry with no
`metadata.admitted` has the life key `<entry-name>@unknown`. A reconciliation that meets one reports
**undecidable** and surfaces the entry at the slate. It does not report `exited`, and it does not
report `not-exited`. Collapsing "I could not establish which life this is" into either verdict is how
a live entry gets removed as already-handled.

**Today `@unknown` is not the exception — it is every entry.** No surface writes `metadata.admitted`
yet. Writing it is the job of the admission rule, which lives in the instruction file every session
loads (Limb 3 of the split shape) and lands in the migration chunk, not this one. So on a real store
today every identity is `@unknown`, every reconciliation answers `undecidable`, and the life-key
discipline protects nothing until that producer exists. That is stated here rather than left for a
later reader to discover, and it is carried into the interface list below as an obligation the next
chunk owes, not an implementation detail it may notice or not.

## `LEDGER.md` — what the slate did

One record per line, pipe-separated, in the append-only region. The field order is fixed and
positional, matching the store's existing `limit_observation` convention:

```text
<!-- memory-ledger-begin -->
2026-08-08 | executed | promote | reference_pwsh_like_anchors@2026-03-02 | the lesson now lives in the repo's own guidance | agent-orchestra skills/terminal-hygiene/SKILL.md (merged to main at a1b2c3d)
2026-08-08 | proposed | remove-obsolete | reference_copilot_sunset_flow@2026-05-11 | the surface it describes no longer exists | none (accepted recall loss)
2026-08-08 | executed | sweep-complete | sweep@2026-08-08 | 41 subjects walked, 3 exits, 1 deferral | LEDGER.md
```

| Field | Values | Notes |
| --- | --- | --- |
| date | `yyyy-MM-dd` | when this record was written, not when the entry was admitted; a future date is refused |
| status | `proposed`, `executed`, `reconciled` | required; see below |
| disposition | one of the dispositions the sweep procedure names, listed below | |
| identity | `<name>@<admitted-date>` | the life key; `sweep@<date>` or `ledger@<date>` for the sweep's own records |
| reason | prose | |
| destination | prose, or `none (accepted recall loss)` | for a promotion, specific enough to be read back |

**Exactly six fields, and no field may contain a pipe.** An earlier revision rejoined field 6 onward
into the destination, so a pipe in a prose reason silently shifted one fragment into the field that
says whether an entry left recall or merely moved section — the one field a later reader depends on
to tell those apart. A record with the wrong field count is malformed and visible, not quietly wrong.

### The dispositions

| Disposition | Kind | Meaning |
| --- | --- | --- |
| `promote` | exit | the lesson lands in a permanent home outside the store |
| `demote` | exit | the pointer moves to `ARCHIVE.md`, booked as accepted recall loss |
| `remove-fails-admission` | exit | the entry fails the store's admission rule |
| `evaporate-on-close` | exit | a `project_` entry whose work has closed, residue generalized first |
| `dedupe-into` | exit | the lesson is folded into a surviving entry, which becomes the destination |
| `remove-obsolete` | exit | the behavior, tooling or surface the entry describes no longer exists |
| `keep-hot-with-expiry` | entry, not an exit | the entry stays, deferred with an expiry date |
| `settle-in-place` | entry, not an exit | a settled `project_` pointer moves to the settled section |
| `restore` | entry, not an exit | a demoted pointer comes back to the index; **supersedes** the exit recorded for that life |
| `sweep-complete` | the sweep's own | a sweep finished; identity `sweep@<date>` |
| `ledger-compaction` | the sweep's own | reconciled records were folded away; identity `ledger@<date>` |

`sweep` and `ledger` are **reserved names**: no entry may use them, and a self-record may use no
other. Without that, a sweep's own record and an entry's record can collide on one key.

Note that the ledger holds more than exits. It is the history of what the slate *did*, which includes
the deferrals and settled-section moves that removed nothing — so "exit record" names its most
important contents, not all of them. Only the exit dispositions are read as departures.

### Status, and the two folds that make it work

**Status is required, and a record without one is malformed, never executed.** The policy makes any
session free to *propose* a destructive act and only an owner-present slate free to execute one, so
proposals are the record's high-frequency traffic. A reader that defaulted a missing status would
sooner or later read a proposal as a completed exit and conclude an entry had already left.

`proposed` — an act a session thinks should happen. Nothing has been removed.
`executed` — the act happened, at a slate, with the owner present.
`reconciled` — a later sweep read this record back, confirmed the store's state matches it, and has
nothing further to do with it.

Nothing in this file is ever edited in place, so a status **changes by appending a later row** with
the same identity and disposition. Two folds follow from that, and both are load-bearing:

- **Effective status.** A disposition's status is the status of its *latest* row. Without this fold,
  "eligible for compaction when its status is `reconciled`" can never fire for any executed record —
  the executed row is still executed forever — and the retention bound below is inert.
- **Supersession.** A `restore` record for an identity undoes the exits recorded for it, because the
  pointer is back in the index. Without this fold a lawfully restored entry is reported as an
  interrupted disposition at every sweep for the life of the store.

An exit is **in force** when its latest row is `executed` or `reconciled` and no later `restore`
undoes it. That is the set every reader wants, and it is what "has this entry left?" means.

**The record is written before the act it authorizes.** A sweep appends the `executed` record, then
removes the pointer — never the other way round. Under act-then-record, a sweep interrupted between
the two produces precisely the unrecorded removal the first replacement rule forbids. Under
record-then-act the interruption is recoverable and visible: the next sweep, finding an exit in force
whose disposition is not reflected in the store, reports it as an incomplete disposition and puts it
in front of the owner first. It is not silently re-executed and not silently dropped; either could be
right, and the record cannot tell which.

### Retention

The parent design rejected an eternal forensic ledger by name, so unbounded growth is not the default
here. A record's job is to make reconciliation possible, and it ends when reconciliation is done with
it:

- A record becomes **eligible** for compaction when its effective status is `reconciled` **and** at
  least one further sweep has completed since that reconciliation — which the `sweep-complete` records
  make readable. The extra sweep of daylight is what stops a record being folded away in the same
  breath that marked it reconciled, when a mistake in that reconciliation is still the most likely
  thing to be wrong.
- Compacting the ledger is itself a **destructive act**: it happens at an owner-present slate, and it
  appends one `ledger-compaction` record naming how many records were folded and the date range they
  spanned. The ledger may forget the particulars; it never forgets that there were particulars.
- Nothing else expires. A record that is `proposed` or `executed` stays until a sweep reconciles it.

Folding a reconciled record away does not endanger the name-reuse read: a new life has a different
life key, so it finds no record and reads `not-exited`, which is the true answer.

## `SLATE.md` — slate state

The state the slate consults before it does anything else. One row per state change, appended,
**latest row per (identity, track) governs** — the same discipline as `limit_observation`, for the
same reason.

```text
<!-- memory-slate-begin -->
2026-08-08 | reference_marker_head_self_closed@2026-07-02 | critical | yes | catches an otherwise-silent marker defect
2026-08-08 | project_1015_memory_store@2026-06-30 | deferral | 1 | until 2026-09-07 — chunk 3 lands the drain
2026-08-08 | reference_marker_head_self_closed@2026-07-02 | landing | in-flight | agent-orchestra PR #1031
```

| Track | Value | Detail |
| --- | --- | --- |
| `critical` | `yes` or `no`, lower case exactly | why the two-part test does or does not hold; required |
| `deferral` | the running count, a positive integer | `until <yyyy-MM-dd> — <reason>`; the date is required |
| `landing` | `none`, `in-flight`, or `landed` | the named vehicle, required for `in-flight` |

**Exactly five fields, and every value is checked against its own vocabulary.** An earlier revision
validated the track name and took the value raw, so a row reading `critical | Yes` parsed clean,
counted as an assessment, and let the entry exit with no landing verification at all — one
capitalized letter past the gate that exists to keep a critical lesson from leaving unlanded.

**A slate carrying any row this parser cannot read makes every gate refuse.** A row can fail before
its identity parses, so an unreadable row cannot always be attributed to an entry — and a deferral
history that might say anything is not one the never-deferred-twice rule may be applied to. Repair
the slate, then disposition.

Three independent tracks rather than one state column, because the states are genuinely orthogonal:
an entry can be critical *and* deferred *and* have a landing in flight, and a single
latest-row-wins column would silently drop two of those three the moment the third was written.

**The deferral count is carried in the row, not derived by counting rows.** A count derived from the
rows present is wrong the moment the slate file is compacted, and the second-deferral rule is exactly
the thing that must not quietly become false.

### The critical flag — where it lives and who sets it

The flag lives here and nowhere else. It does not live in the entry body, because the slate's first
act would then have to open every body in the store to find out which entries it must handle first,
and it does not live in the pointer line, because the pointer line's whole text is recall surface
governed by R1 and R2.

It is set at two moments, by the session that is already writing:

1. **At admission.** A session writing a new entry applies the shipped two-part test — a lesson is
   critical when its loss would be expensive, or when its recurrence would be invisible without it —
   and appends a `critical` row saying `yes` or `no`. Both polarities are worth writing: an explicit
   `no` is the difference between "this was considered and is ordinary" and "nobody has looked."
2. **At a slate.** The sweep asks the test of every entry it surfaces that carries no `critical` row
   yet, and appends the answer.

An entry with no `critical` row has not been assessed. The sweep treats it as unassessed rather than
as ordinary, surfaces it in its own group, and **no gate will disposition it** — not an exit, and not
a deferral either. An earlier revision let the deferral gate alone read absence as "not critical",
which made the never-deferred-twice rule escapable by simply never assessing the entry.

### Deferral, expiry, and landing in flight

A `keep-hot-with-expiry` disposition appends a `deferral` row whose count is one higher than the last
and whose detail carries an `until` date. The sweep surfaces a deferral whose `until` date has passed
as expired, and an expired deferral re-enters the slate. Nothing is parkable: there is no row shape
that means "hold indefinitely," and the absence is deliberate.

A **critical** entry may not be deferred twice. The second attempt is blocked at the sweep, and the
block is visible in the artifacts: no second `deferral` row is written, and a `proposed` ledger record
carrying the refusal reason is appended in its place.

A critical entry whose promotion has been **initiated toward a named vehicle** — an open pull request,
a queued documentation change — is not deferred. It carries a `landing` row with value `in-flight` and
the vehicle named, it is surfaced at every subsequent slate with that vehicle, and it does not
increment the deferral count. This is parent amendment A-C37, and it exists because the conjunction of
"critical entries are never deferred twice" and "a critical entry stays until its lesson has landed"
otherwise leaves a once-deferred critical entry with no lawful move at all on the store's own
owner-paced promotion route. In-flight is a truthful state; the tempting alternative — calling an
unmerged branch a landing — is a false one, and it loses the lesson when the branch is abandoned.

## `ARCHIVE.md` — the cold archive

Parent amendment A-C36. The archive is a waiting room, not a second index: a demoted pointer keeps the
same pointer format it had in the index, so it can be read back or restored without translation, and
it is **loaded on demand only**.

```markdown
# Cold archive

Demoted pointers. This file is **not loaded at session start** — nothing here is recalled
automatically, and that is what "accepted recall loss" means. Every line here has a record in
`LEDGER.md` naming when it was demoted and why. Restoring one is ordinary work: move the pointer back
and append a `restore` record, which supersedes the demotion.

## Demoted 2026-08-08

- [some lesson](reference_some_lesson.md) — the hook it carried in the index, unchanged
```

The pointer's hook comes across **unchanged**. Shortening it on the way out would be trimming, and
trimming is never a size-reduction move — least of all on the copy that is now the only copy.

The archive carries no life key, and it does not need to: **a demotion is accounted from its ledger
record**, which does carry one, and the archive line is what corroborates that the record's act
completed. A missing archive line for a recorded demotion is an incomplete disposition. An earlier
revision had this the other way round and accounted a demotion from the archive line alone, keyed on
the bare name — so a line left by a previous life of a reused name made a wholly unrecorded removal
of the current life read as accounted.

**First demotion creates the file.** The archive does not exist in a store that has never demoted
anything, and creating an empty one at adoption would be a file that says nothing.

## Destination measurements

Step 5 measures each governed exit destination — for a Claude Code store, the user-global `CLAUDE.md`
— and the measurement is recorded in **the store's own values region**, beside the index measurement
it is comparable with:

```text
x-destination_observation: 2026-08-08 | 2534 | characters | ~/.claude/CLAUDE.md | Measure-MemorySurface.ps1 (UTF-8 decoded, CRLF and lone CR normalized to LF, length in UTF-16 code units)
```

The `x-` prefix is the reserved growth path: an older checker ignores the key and reports that it did,
rather than refusing a store it does not fully understand. The key **repeats**, one row per
observation, freshest governs — the same discipline `limit_observation` already carries, and the only
one available given that nothing governs a repeated `x-` key and the append bound forbids rewriting
one.

The surface is written **home-relative** (`~/...`), not as an absolute path: a series of measurements
keyed on one machine's home directory is incomparable the moment the store is read anywhere else, and
being able to compare a series is the only thing the step exists for.

A store that records no budget inputs at all has no values region, and a sweep **must not create one**
— a region holding only `x-` keys reads as "records budget inputs" to the checker while containing no
observation it can use, which turns a lawfully opted-out store from clean into a defect. Such a store
records the measurement's absence instead: a `proposed` ledger record saying the surface was measured
and the store has opted out of recording it.

## Which policy rules reach these records

The canonical text says of the exit record that it "is lesson content and is itself governed by this
policy." That sentence was written when the only record home was a section of the index, where every
index rule reached it by construction. For records that live in their own never-loaded files, it needs
reading out:

- **R1 and R2 do not reach them.** Both rules are about recall hooks on pointer lines, and both exist
  because recall fires on what a pointer *says*. Nothing in these three files is a recall surface —
  `ARCHIVE.md` least of all, since being outside recall is the entire content of a demotion.
- **R3 reaches all three.** Re-read from disk immediately before every write. Append-only writing
  already implies it, and the rule is the reason append-only is safe rather than merely tidy.
- **The no-tenure doctrine reaches them.** No record has tenure either, which is what the retention
  bound above is; and compaction of any of these files is a destructive act behind the slate gate.
- **The size budget does not reach them.** The budget governs the index because the index is loaded
  in full and truncated silently. These files are never loaded, so they spend nothing, and holding
  them to a budget would recreate the pressure that made history displace recall in the first place.

## Interfaces the next chunk consumes

Chunk 3 of the parent design — the migration and the live store's first drain — executes the sweep
procedure and writes these records. Each shape below is an interface it may cite by name; changing one
after this chunk lands is an edit to the parent's chunk boundary, not a local decision.

1. **The ledger record** — `LEDGER.md`, opening marker with records to end of file, exactly six
   fields `date | status | disposition | identity | reason | destination`, no field containing a pipe;
   status vocabulary `proposed` / `executed` / `reconciled`; record written before the act; appended,
   never edited; effective status is the latest row per (identity, disposition); an exit is in force
   when its latest row is executed-or-reconciled and no later `restore` undoes it.
2. **The disposition vocabulary** — the eleven names in the table above, in three kinds (exit, entry,
   the sweep's own), with `sweep` and `ledger` reserved as identity names. The parser hard-rejects
   anything outside it, so this is the field most likely to break a later writer, and it is named here
   for the same reason the status vocabulary is.
3. **The proposal record** — the same file and the same line shape, distinguished by `status:
   proposed`. Any session may append one; no session may execute one.
4. **Entry identity** — `<entry-name>@<admitted-date>`, no `@` in the name, bound on the living side
   by `metadata.admitted` in the entry's frontmatter, `@unknown` where that is absent, and a
   reconciliation that meets `@unknown` reports **undecidable**. **Chunk 3 owes the producer**: the
   admission rule it lands in the user-global instruction file must require `metadata.admitted` on
   every entry it admits, and must decide what to do about the entries that predate it — because until
   it does, every identity in a real store is `@unknown` and the life-key discipline protects nothing.
5. **The critical flag** — `SLATE.md`, `critical` track, values `yes` / `no` lower case, set at
   admission or at a slate, absent meaning unassessed rather than ordinary, and no gate dispositions
   an unassessed entry.
6. **Keep-hot expiry** — `SLATE.md`, `deferral` track, count carried in the row, `until <date>`
   required in the detail, no indefinite form.
7. **Landing in flight** — `SLATE.md`, `landing` track, `in-flight` with a named vehicle, not counted
   as a deferral (A-C37).
8. **The cold archive** — `ARCHIVE.md`, index pointer format unchanged, loaded on demand, created at
   the first demotion (A-C36), corroborating a demotion whose ledger record is what accounts for it.
9. **The destination measurement** — `x-destination_observation` in the store's values region,
   `date | value | unit | surface | method`, surface written home-relative, repeating with the freshest
   governing, and never written into a store that has no values region.
