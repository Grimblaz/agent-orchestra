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
| `LEDGER.md` | exit records and proposals — the history of what left and why | append-only, by any session for a proposal, by a slate for an execution | at reconciliation, and by a reader asking what happened to an entry |
| `SLATE.md` | slate state for entries still in the index — critical flags, deferrals, landings in flight | append-only, latest row per entry-and-track governs | as the slate's first act, in one read |
| `ARCHIVE.md` | demoted pointers — the cold archive, booked as accepted recall loss | by a slate, on demotion | on demand, by a reader who went looking |

`SLATE.md` is separate from `LEDGER.md` deliberately. The slate's first act has to enumerate every
critical entry and every deferral before it takes any disposition, and a first act that must fold the
whole exit history to answer "is this entry critical?" is unexecutable at any population worth
sweeping. The split is also clean on authority: the ledger is history and is authoritative for what
has **left**; the slate file is current state and carries claims only about entries that are **still
hot**. There is no fact both can assert, so they cannot contradict each other.

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

`<entry-name>` is the entry's filename without its extension. `<admitted-date>` is the date the entry
was admitted to the store, in `yyyy-MM-dd`, recorded in the entry's own frontmatter under
`metadata.admitted`. Two lives of one name are two life keys, and an exit record for the first says
nothing about the second.

**The living side carries the binding, or the read is undecidable.** An entry admitted before this
convention has no `metadata.admitted`, and its life key is `<entry-name>@unknown`. A reconciliation
that meets one reports **undecidable** and surfaces the entry at the slate. It does not report
`exited`, and it does not report `not-exited`. Collapsing "I could not establish which life this is"
into either verdict is how a live entry gets removed as already-handled, and it is the failure this
whole field exists to prevent. Undecidable is a state a person resolves, not a state the read guesses
its way out of.

## `LEDGER.md` — the exit record

One record per line, pipe-separated, inside a marked region so a reader can find the records without
parsing the prose around them. The field order is fixed and positional, matching the store's existing
`limit_observation` convention:

```text
<!-- memory-ledger-begin -->
2026-08-08 | executed | promote | reference_pwsh_like_anchors@2026-03-02 | the lesson now lives in the repo's own guidance | agent-orchestra skills/terminal-hygiene/SKILL.md (merged to main at a1b2c3d)
2026-08-08 | proposed | remove-obsolete | reference_copilot_sunset_flow@2026-05-11 | the surface it describes no longer exists | none (accepted recall loss)
<!-- memory-ledger-end -->
```

| Field | Values | Notes |
| --- | --- | --- |
| date | `yyyy-MM-dd` | when this record was written, not when the entry was admitted |
| status | `proposed`, `executed`, `reconciled` | required; see below |
| disposition | one of the named dispositions in the sweep procedure | `ledger-compaction` also appears here, keyed on the ledger itself |
| identity | `<name>@<admitted-date>` | the life key |
| reason | prose | may not contain `\|` |
| destination | prose, or `none (accepted recall loss)` | for a promotion, specific enough to be read back |

**Status is required, and a record without one is malformed, never executed.** The policy makes any
session free to *propose* a destructive act and only an owner-present slate free to execute one, so
proposals are the record's high-frequency traffic — most lines in a busy store's ledger will be
proposals that no slate has ruled on yet. A reader that defaults a missing status to anything at all
would sooner or later read a proposal as a completed exit and conclude an entry had already left.
A malformed record is surfaced at the next slate for a person to fix; it is not repaired by guessing.

`proposed` — an act a session thinks should happen. Nothing has been removed.
`executed` — the act happened, at a slate, with the owner present.
`reconciled` — a later sweep has read this record back, confirmed the store's state matches it, and
has nothing further to do with it. This is the status the retention bound keys on.

**The record is written before the act it authorizes.** A sweep appends the `executed` record, then
removes the pointer — never the other way round. Under act-then-record, a sweep interrupted between
the two produces precisely the unrecorded removal the first replacement rule forbids, and nothing
afterwards can tell that removal from an unlawful one. Under record-then-act the interruption
produces a record whose act never completed, which is a recoverable state and a visible one: **the
next sweep, finding an `executed` record whose disposition is not reflected in the store, reports it
as an incomplete disposition and puts it in front of the owner as the first thing it asks about** —
alongside the critical entries, before any new disposition is taken. It is not silently re-executed
and not silently dropped; either could be right, and the record cannot tell which.

**Writing is append-only.** The store sits outside version control and has no lock, and several
sessions may write it in the same minute. An append survives a concurrent writer with at worst an
interleaving a reader can see; a read-modify-write silently discards whatever landed between the read
and the write. Nothing in this file is ever edited in place, and the one act that removes records —
ledger compaction — is a destructive act like any other.

### Retention

The parent design rejected an eternal forensic ledger by name, so unbounded growth is not the default
here. A record's job is to make reconciliation possible, and it ends when reconciliation is done with
it:

- A record becomes **eligible** for compaction when its status is `reconciled` **and** at least one
  further sweep has completed since that reconciliation. The extra sweep of daylight is what stops a
  record being folded away in the same breath that marked it reconciled, when a mistake in that
  reconciliation is still the most likely thing to be wrong.
- Compacting the ledger is itself a **destructive act**: it happens at an owner-present slate, and it
  appends one `ledger-compaction` record naming how many records were folded and the date range they
  spanned. The ledger may forget the particulars; it never forgets that there were particulars.
- Nothing else expires. A record that is `proposed` or `executed` stays until a sweep reconciles it,
  however long that takes.

Folding a reconciled record away does not endanger the name-reuse read: a new life has a different
life key, so it finds no record and reads `not-exited`, which is the true answer.

## `SLATE.md` — slate state

The state the slate consults before it does anything else. One row per state change, append-only,
**latest row per (identity, track) governs** — the same discipline as `limit_observation`, for the
same reason.

```text
<!-- memory-slate-begin -->
2026-08-08 | reference_marker_head_self_closed@2026-07-02 | critical | yes | catches an otherwise-silent marker defect
2026-08-08 | project_1015_memory_store@2026-06-30 | deferral | 1 | until 2026-09-07 — chunk 3 lands the drain
2026-08-08 | reference_marker_head_self_closed@2026-07-02 | landing | in-flight | agent-orchestra PR #1031
<!-- memory-slate-end -->
```

| Track | Value | Detail |
| --- | --- | --- |
| `critical` | `yes` or `no` | why the two-part test holds (or no longer does) |
| `deferral` | the running count, an integer | `until <yyyy-MM-dd> — <reason>`; the date is required |
| `landing` | `none`, `in-flight`, or `landed` | the named vehicle, required for `in-flight` |
| `presence` | `hot` or `exited` | written when an entry leaves, so a gone entry stops being surfaced |

Four independent tracks rather than one state column, because the states are genuinely orthogonal: an
entry can be critical *and* deferred *and* have a landing in flight, and a single latest-row-wins
column would silently drop two of those three the moment the third was written.

**The deferral count is carried in the row, not derived by counting rows.** A count that is derived
from the rows present is wrong the moment the slate file is compacted, and the second-deferral rule
is exactly the thing that must not quietly become false.

### The critical flag — where it lives and who sets it

The flag lives here and nowhere else. It does not live in the entry body, because the slate's first
act would then have to open every body in the store to find out which entries it must handle first,
and it does not live in the pointer line, because the pointer line's whole text is recall surface
governed by R1 and R2 and a flag sitting in it competes with the hook for the reader's attention.

It is set at two moments, by the session that is already writing:

1. **At admission.** A session writing a new entry applies the shipped two-part test — a lesson is
   critical when its loss would be expensive, or when its recurrence would be invisible without it —
   and appends a `critical` row if it holds. This is the ordinary case, and it is why the flag is a
   one-line append rather than anything a writing session would be tempted to skip.
2. **At a slate.** The sweep asks the test of every entry it surfaces that carries no `critical` row
   yet, and appends the answer — `yes` or `no`. An explicit `no` is worth writing: it is the
   difference between "this was considered and is ordinary" and "nobody has looked."

An entry with no `critical` row on either track has not been assessed. The sweep treats it as
unassessed rather than as ordinary, and assesses it before dispositioning it.

### Deferral, expiry, and landing in flight

A `keep-hot-with-expiry` disposition appends a `deferral` row whose count is one higher than the last
and whose detail carries an `until` date. The sweep surfaces a deferral whose `until` date has passed
as expired, and an expired deferral re-enters the slate. Nothing is parkable: there is no row shape
that means "hold indefinitely," and the absence is deliberate.

A **critical** entry may not be deferred twice. The second attempt is blocked at the sweep, and the
block is visible in the artifacts: no second `deferral` row is written, and a `proposed` ledger record
carrying the refusal reason is appended in its place, so a later reader can see what was attempted.

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
it is **loaded on demand only**. A demotion is booked as accepted recall loss, and that booking is
honest precisely because nothing loads this file.

```markdown
# Cold archive

Demoted pointers. This file is **not loaded at session start** — nothing here is recalled
automatically, and that is what "accepted recall loss" means. Every line here has an exit record in
`LEDGER.md` naming when it was demoted and why. Restoring one is ordinary work: move the pointer back
and append a record saying so.

## Demoted 2026-08-08

- [some lesson](reference_some_lesson.md) — the hook it carried in the index, unchanged
```

The pointer's hook comes across **unchanged**. Shortening it on the way out would be trimming, and
trimming is never a size-reduction move — least of all on the copy that is now the only copy.

**First demotion creates the file.** The archive does not exist in a store that has never demoted
anything, and creating an empty one at adoption would be a file that says nothing. The sweep creates
it with the header above at the moment of the first demotion, in the same slate that writes the
demotion's exit record. A store that never demotes never grows one.

## Which policy rules reach these records

The canonical text says of the exit record that it "is lesson content and is itself governed by this
policy." That sentence was written when the only record home was a section of the index, where every
index rule reached it by construction. For a record that lives in its own never-loaded file, it needs
reading out:

- **R1 and R2 do not reach them.** Both rules are about recall hooks on pointer lines, and both exist
  because recall fires on what a pointer *says*. Nothing in these three files is a recall surface —
  `ARCHIVE.md` least of all, since being outside recall is the entire content of a demotion. Applying
  a hook rule to a ledger line would be enforcing a property nobody consumes.
- **R3 reaches all three.** Re-read from disk immediately before every write. Append-only writing
  already implies it, and the rule is the reason append-only is safe rather than merely tidy.
- **The no-tenure doctrine reaches them.** No record has tenure either, which is what the retention
  bound above is; and compaction of any of these files is a destructive act behind the slate gate.
- **The size budget does not reach them.** The budget governs the index because the index is loaded
  in full and truncated silently. These files are never loaded, so they spend nothing, and holding
  them to a budget would recreate the pressure that made history displace recall in the first place.
  They are bounded by their retention rules instead.

## Interfaces the next chunk consumes

Chunk 3 of the parent design — the migration and the live store's first drain — executes the sweep
procedure and writes these records. Each shape below is an interface it may cite by name; changing one
after this chunk lands is an edit to the parent's chunk boundary, not a local decision.

1. **The ledger record** — `LEDGER.md`, marked region, `date | status | disposition | identity |
   reason | destination`; status vocabulary `proposed` / `executed` / `reconciled`; record written
   before the act; append-only; retention keyed on `reconciled` plus one further sweep, compaction
   slate-gated and itself recorded.
2. **The proposal record** — the same file and the same line shape, distinguished by `status:
   proposed`. Any session may append one; no session may execute one.
3. **Entry identity** — `<entry-name>@<admitted-date>`, bound on the living side by
   `metadata.admitted` in the entry's frontmatter, `@unknown` for a pre-convention entry, and a
   reconciliation that meets `@unknown` reports **undecidable**.
4. **The critical flag** — `SLATE.md`, `critical` track, values `yes` / `no`, set at admission or at a
   slate, absent meaning unassessed rather than ordinary.
5. **Keep-hot expiry** — `SLATE.md`, `deferral` track, count carried in the row, `until <date>`
   required in the detail, no indefinite form.
6. **Landing in flight** — `SLATE.md`, `landing` track, `in-flight` with a named vehicle, not counted
   as a deferral (A-C37).
7. **The cold archive** — `ARCHIVE.md`, index pointer format unchanged, loaded on demand, created at
   the first demotion (A-C36).
