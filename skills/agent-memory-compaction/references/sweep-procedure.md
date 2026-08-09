# The sweep procedure

The policy's third replacement rule says destructive acts execute only behind an owner-present slate.
This is what a slate does. The records it writes are defined in
[`skills/agent-memory-compaction/references/store-records.md`](store-records.md); read that first, or
alongside — this file assumes the record shapes and does not repeat them.

Its steps are written to be executed, not admired. Three of them carry a check, and each check has an
instrument beside this file so the result is an artifact somebody can read back rather than a claim
the sweep makes about itself:

```text
pwsh skills/agent-memory-compaction/scripts/Get-MemorySweepInventory.ps1 -IndexPath <index> -OutputPath <artifact>
pwsh skills/agent-memory-compaction/scripts/Test-MemorySweepDisposition.ps1 -Gate <gate> -IndexPath <index> ...
pwsh skills/agent-memory-compaction/scripts/Test-MemorySweepPartition.ps1 -InventoryPath <artifact> -IndexPath <index>
pwsh skills/agent-memory-compaction/scripts/Measure-MemorySurface.ps1 -Path <a destination>
```

None of them writes to the store. They read, and they report; the sweep writes.

`Test-MemorySweepDisposition.ps1` is the one to notice, because its absence was a real defect. Every
rule in step 3 — the second-deferral block, the landing verification, the grandfathering scope, the
reconciliation read — is applied by that script, by name, at the step that needs it. A rule that
exists only as prose is a rule each session re-derives by hand, and an earlier revision of this
machinery implemented all four in a library and exposed none of them: what the tests demonstrated was
that a function returned false, not that the procedure blocked anything.

## When a sweep is due

A sweep has no trigger and no schedule — the same as the check. It is due when one of these is true,
and all three are things a session can observe rather than feel:

1. `pwsh skills/agent-memory-compaction/scripts/Test-MemoryIndexPolicy.ps1 -IndexPath <index>` reports
   `size:` **over** budget. The index is past the size it can be relied on to load in full, which is
   the condition the whole retention regime exists to resolve.
2. The same run reports the limit observation **stale** against the store's staleness bound. The
   budget is a fraction of a dated observation of an external surface; past the bound, the store does
   not know what its own budget is.
3. The store's owner calls one. No condition is needed for this and none is implied by its absence.

A store that is within budget with a fresh observation and an owner who has not asked has nothing to
sweep, and sweeping it anyway is how a corpus gets churned for no lesson's benefit.

## Who may run which parts

The whole procedure may be *walked* by any session. What an unattended session may not do is execute
anything destructive — that is the policy rule, and it is narrower than "do nothing":

| Act | Unattended session | Owner-present slate |
| --- | --- | --- |
| Admit a new entry, append a `critical` row for it | yes | yes |
| Enumerate the corpus, run the three checks | yes | yes |
| Append a `proposed` ledger record | yes | yes |
| Append a `limit_observation` row after re-observing the limit | yes | yes |
| Execute any exit, demotion, body deletion, structural rewrite | **no** | yes |
| Compact `LEDGER.md` or `SLATE.md` | **no** | yes |

An unattended walk therefore ends with proposals and an unchanged index. That is a complete, useful
outcome — the slate that follows starts from a corpus somebody has already reasoned about — and it is
what "record proposals; remove nothing" means in practice.

## Step 0 — make the machinery findable from the store

A sweep's first act, once per store, is to make sure a later session at this store can find this
procedure by following a path stated in a file, rather than inferring a directory from a sibling.

Add a section to the store's `POLICY.md`, **outside** the `store-values` and `policy-canonical`
regions — text there is not part of the compared canonical policy, so it costs a store nothing on the
policy axis:

```markdown
## Sweep machinery (not part of the compared text)

Sweeps of this store follow `skills/agent-memory-compaction/references/sweep-procedure.md` in the
agent-orchestra plugin. Its records live beside this file: `LEDGER.md` (exits and proposals),
`SLATE.md` (critical flags, deferrals, landings in flight), and `ARCHIVE.md` (demoted pointers,
created at the first demotion). Their shapes are defined in
`skills/agent-memory-compaction/references/store-records.md`.
```

There are three store generations, and all three are reachable:

- **Adopting the split after this machinery shipped** — the section is written at adoption, as the
  third part of Limb 2.
- **Split under an earlier version** — no such section exists, and this step writes it. That is why
  it is a step and not a footnote in the adoption instructions: the machinery has to reach the stores
  that already exist, and their first sweep is the only moment it can.
- **Never split at all** — the store keeps the whole policy as its index header and has no `POLICY.md`
  to add a section to. This is a lawful, supported shape, and it is the shape the store this
  machinery was written for is in today. Such a store **adopts the split shape first**, following
  *Adopting the split shape* in the skill, and then this step writes the section into the policy file
  that adoption creates. Splitting is itself a structural rewrite of the index, so it is a
  destructive act and happens at the same owner-present slate as the sweep — not before it and not
  unattended.

## Step 1 — enumerate the corpus, from disk

```text
pwsh skills/agent-memory-compaction/scripts/Get-MemorySweepInventory.ps1 -IndexPath <index> -OutputPath <artifact>
```

**Read the index from disk, not from the session's loaded view.** A store large enough to be worth
sweeping is a store whose load may be truncated, and a truncated load is missing its tail without
saying so. Enumerating from context on the one store this machinery exists for produces a corpus that
is already missing the entries most likely to need dispositioning — and every later check that
reconciles against that enumeration then agrees with it perfectly, because both halves came from the
same short list. The instrument reads the file itself and records the index's character count and
digest in the artifact, so a reader can tell which bytes were enumerated.

The corpus is **two populations**, and the second is easy to forget:

- every linked subject on the index's pointer lines; and
- every entry file in the store directory that **no pointer points at** — an orphan body.

Orphan bodies are outside recall already and are invisible to the checker, whose whole subject is the
index. They still hold lessons, they can still be critical, and a partition check that walks only
pointers will report a clean, complete sweep of a store it never fully looked at.

Keep the artifact. Step 6 reads it back.

## Step 2 — read slate state, and take the first things first

The inventory folds `SLATE.md` into the enumeration and orders the corpus:

1. **Incomplete dispositions** — an exit in force whose act is not reflected in the store (the pointer
   is still there, or the archive line is not). Something was interrupted between the record and the
   act. Neither re-executing nor dropping it is safe to do silently, so it goes to the owner first,
   before anything new is decided.
2. **Critical entries**, every one of them, before any other disposition is taken. The policy says
   critical entries are dispositioned first at every sweep, and "first" is not a preference about
   ordering — it is what stops a slate from spending its owner's attention on the easy two-thirds and
   deferring the expensive third for the fourth time.
3. **Unassessed entries** — no `critical` row on either polarity. Nobody has looked, and no gate will
   disposition one, so this is the question to answer before any other question about it. It sits
   ahead of expired deferrals deliberately: labelling such an entry by its deferral state would tell
   a reader the one thing that is not the next thing to do about it.
4. **Expired deferrals** — a `deferral` row whose `until` date has passed.
5. Everything else.

A critical entry sitting in an orphan body, or last in file order, is still in group 2. The ordering
comes from the slate state and the two populations, never from where a line happens to sit.

An orphan body whose life carries an **exit in force** is not surfaced at all: it has already left,
and its body simply has not been deleted — body deletion being a separate owner-approved act. This is
read from the ledger, which is the only file that says an entry has left.

**Where the reconciliation read happens.** For any entry whose history is in doubt — an orphan body,
a name that appears in the ledger, an entry the owner is unsure about — ask the reconcile gate:

```text
pwsh skills/agent-memory-compaction/scripts/Test-MemorySweepDisposition.ps1 -Gate reconcile -IndexPath <index> -EntryPath <entry body>
```

It answers `exited`, `not-exited`, or **`undecidable`**. Undecidable is not a shrug and not a
half-answer: it means the entry records no admitted date, so which life it is cannot be established,
and the sweep cannot know whether an exit recorded under that name was about this entry or a previous
one. **An undecidable entry is dispositioned by the owner explicitly, or it is left hot.** It is never
dispositioned on the assumption that the record found under its name was about it — that inference is
the artifact-presence reasoning the whole life-key design exists to prevent. On a store whose
admission rule has not yet landed, *every* entry answers undecidable, which is why the first sweep of
such a store is an owner-present conversation rather than a mechanical pass.

## Step 3 — disposition

Every entry the sweep surfaces gets exactly one disposition. **Promotion is the primary outflow.**
Demotion and removal are exception paths and are booked as what they are: the store's job is to get
lessons into permanent homes, and a sweep whose output is mostly removals has found a store nobody is
promoting out of, which is a finding about the store rather than a successful sweep.

### The dispositions

Five come from the parent design. Three more complete the cover over the canonical policy's six
authorized size-reduction moves — see the mapping below for why five did not.

| Disposition | Exit? | What it means | Records written |
| --- | --- | --- | --- |
| `promote` | yes | the lesson lands in a permanent home outside the store | ledger `executed` |
| `demote` | yes | the pointer moves to `ARCHIVE.md`, booked as accepted recall loss | ledger `executed`; archive line |
| `keep-hot-with-expiry` | **no** | the entry stays, deferred with an expiry date | ledger `executed`; `deferral: N` with `until` |
| `remove-fails-admission` | yes | the entry fails the store's admission rule | ledger `executed` |
| `evaporate-on-close` | yes | a `project_` entry whose work has closed, residue generalized first | ledger `executed` |
| `settle-in-place` | **no** | a settled `project_` pointer moves to the settled section | ledger `executed` — an act, not an exit |
| `dedupe-into` | yes | the lesson is folded into a surviving entry, which becomes the destination | ledger `executed` |
| `remove-obsolete` | yes | the behavior, tooling or surface the entry describes no longer exists | ledger `executed` |
| `restore` | **no** | a demoted pointer comes back to the index; supersedes that life's exit | ledger `executed`; archive line removed |

Two further records the sweep writes about itself rather than about an entry, keyed on the reserved
identities `sweep@<date>` and `ledger@<date>`: `sweep-complete` (step 7) and `ledger-compaction`.
An entry may not use either reserved name.

The ledger therefore holds more than exits — it is the history of what the slate did, and only the
exit dispositions are read as departures. "Exit record" names its most important contents, not all of
them.

### The covering mapping

Every move the canonical policy authorizes reaches a disposition, or is named here as out of scope
with its reason. This mapping is the point of the table above; a disposition vocabulary that leaves an
authorized move unreachable quietly withdraws it from the sweep's repertoire.

| Authorized move (canonical policy) | Disposition | Exit recorded |
| --- | --- | --- |
| 1. Promote and remove | `promote` | yes |
| 2. Demote to the cold archive | `demote` | yes |
| 3. Demote a settled `project_` entry | `settle-in-place` | **no** |
| 4. Merge settled `project_` pointers onto one line | `settle-in-place` | **no** |
| 5. Deduplicate | `dedupe-into` | yes |
| 6. Remove an obsolete entry | `remove-obsolete` | yes |
| Repairing a hookless pointer | not a disposition | no — the policy says it is not a size-reduction move, and it is always permitted |

Moves 5 and 6 are why the parent's five were not enough. Deduplication removes a pointer while its
lesson survives *inside the store*, which is neither a promotion (there is no permanent home) nor a
demotion (nothing was lost); calling it either would put a false destination in the record.
Obsolescence is likewise not an admission failure — the entry may have been admitted perfectly well
and simply outlived its subject — and folding it under `remove-fails-admission` would drag every
obsolete entry through a grandfathering rule that has nothing to do with it.

### "Demote" is two moves, and only one of them is an exit

The canonical text uses the word twice with opposite obligations, and inheriting it un-split is the
single most expensive mistake available in this step.

- **`demote` (move 2)** sends a pointer to the cold archive. It leaves passive recall. It **is** an
  exit: an exit record is written, its destination field reads `ARCHIVE.md`, and landing verification
  applies if the entry is critical.
- **`settle-in-place` (moves 3 and 4)** moves a settled `project_` pointer into the index's settled
  section and shortens its clause to the durable lesson. The pointer is still in the index and still
  recalled. It is **not** an exit, it books **no** exit record, and requiring one would fill the
  ledger with records for entries that never went anywhere.

The record's **destination** field is what tells a later reader which happened. A record whose
destination is the archive is a departure; there is no record at all for a settle-in-place, which is
the honest representation of nothing having left.

### Entry tests

Each disposition applies only where its own test holds. For six of the eight the test is the middle
column of the table above, read as a condition rather than a description: `promote` needs a permanent
home that carries the lesson *now*; `demote` needs a decision that accepting the recall loss is the
right trade; `keep-hot-with-expiry` needs a reason the entry cannot be dispositioned yet and a date by
which it can; `settle-in-place` needs a `project_` entry whose tracked work has closed; `dedupe-into`
needs a surviving entry that demonstrably carries the same lesson; `remove-obsolete` needs the
entry's subject to be gone from the world, not merely out of fashion.

Two have sharp edges that the middle column cannot carry:

Both are applied by the gate script, not by eye:

```text
pwsh skills/agent-memory-compaction/scripts/Test-MemorySweepDisposition.ps1 -Gate admission -IndexPath <index> -Identity <life key> -AdmissionRuleLandedOn <yyyy-MM-dd>
```

**`remove-fails-admission` applies only to entries admitted under the admission rule.** That rule
lands in the instruction file every session loads (Limb 3), and every entry admitted before it landed
predates it by definition. An unscoped reading condemns the entire existing corpus at the first sweep,
with the owner's fatigue as the only thing standing between the store and a mass removal.
**Pre-rule entries are grandfathered**: an entry whose `metadata.admitted` date precedes the date the
admission rule landed for this store — or which has no admitted date at all — is not eligible for this
disposition. It is eligible for every other one, judged on its own merits.

**`evaporate-on-close` carries a residue step.** A `project_` entry whose work has closed usually
leaves something generalizable behind — the lesson that outlives the ticket. Before the pointer goes,
that residue is written as a `reference_` entry with its own hook, admitted with its own life key, and
the evaporating record's destination field names it. Skipping the residue step is how a store loses
its most durable lessons at exactly the moment they stop being attached to live work.

### The exit gate

```text
pwsh skills/agent-memory-compaction/scripts/Test-MemorySweepDisposition.ps1 -Gate exit -IndexPath <index>     -Identity <life key> -Disposition <disposition>     -DestinationPath <the destination> -LessonProbe '<a sentence the lesson must contain>' [-DestinationLanded]
```

**An exit is lawful only when its destination verifiably carries the lesson at landing time — every
exit, not only a critical entry's.** That is the canonical policy's second replacement rule, stated
without qualification, and the gate reads the destination file and decides for itself rather than
taking the sweep's word for it. An earlier revision enforced this for critical entries only, so the
shipped prose and the shipped gate said different things about every ordinary promotion.

For a **critical** entry the destination must additionally have **landed**, and that requirement
applies to **every** disposition that removes it from the index — promotion, demotion, deduplication,
obsolescence removal, admission removal alike. The policy is explicit that demotion counts as leaving,
and a critical lesson demoted to a cold archive nobody loads is exactly as gone as one deleted.

The gate also refuses to disposition an entry nobody has assessed for the critical class. "Nobody has
looked" is not "ordinary", and it is not a state an exit may be taken from.

**Landed, for a repository destination, means merged to the default branch** — or the named equivalent
for a destination that has no branches. Reading a feature branch and finding the lesson there is not a
landing: the pointer goes, the record says landed, the branch is abandoned, and the lesson is lost with
no trace that it ever existed. This is also the tempting way out of a critical entry's wait state, and
it is the wrong one.

A critical entry whose landing has been **initiated** toward a named vehicle takes the
landing-in-flight state instead: a `landing: in-flight` row naming the vehicle, surfaced at every
subsequent slate with that vehicle, and **not counted as a deferral**. It is the truthful answer while
the vehicle is open, and it is what keeps the never-deferred-twice rule from having nothing lawful to
offer a critical entry on the store's own owner-paced promotion route.

### Deferral, and the second-deferral block

```text
pwsh skills/agent-memory-compaction/scripts/Test-MemorySweepDisposition.ps1 -Gate deferral -IndexPath <index> -Identity <life key>
```

`keep-hot-with-expiry` appends a `deferral` row with a count one higher than the last and an `until`
date. There is no indefinite form. An expired deferral re-enters the slate in group 3 of step 2, so a
deferral is a delay and never a parking space.

**A critical entry may not be deferred a second time.** The gate blocks the attempt: no second
`deferral` row is written, and a `proposed` record carrying the refusal reason is appended in its
place so the attempt is visible rather than merely absent. **An unassessed entry may not be deferred
either** — the same rule the exit gate applies, for the same reason: an entry nobody has assessed
could be critical, and reading absence as "not critical" here alone would make the never-twice rule
escapable by simply never looking. The lawful moves for a once-deferred
critical entry are to land it, to initiate a landing and take the in-flight state, or to disposition it
now — the three the amendment exists to keep available.

## Step 4 — the staleness check

Read the store's staleness bound and its freshest limit observation. The store's size axis has three
states, and a step written for two of them will fall over on the third:

| State the check reports | What the sweep does |
| --- | --- |
| `not evaluated` — no values region at all | Nothing. This is a lawful opt-out: a store with no size problem has no reason to run a truncation-boundary test. **Do not create the region** — see the write bounds below. |
| a measurement, fresh or stale | If stale, re-observe the limit, or record a deferral of the re-observation. |
| `could not verify` — a values region with no usable observation | There is no freshest date to read, so staleness is not a question that has an answer here. Report the broken record to the owner and repair it before relying on any budget number. This state is reachable by a partial write and is a defect the checker already exits 1 on. |

**A stale observation is reported, not treated as a defect.** The canonical text is deliberate about
this: the number may still be right, and a guessed fresher one is worse than a dated honest one. So a
slate that cannot run a truncation-boundary test right now **defers the re-observation with a record**
— a `proposed` ledger line saying the observation is stale and why it was not refreshed — rather than
fabricating a number or blocking the sweep on it.

A re-observation's result is **appended** as a new `limit_observation` row. The prior rows stay
byte-identical. This is not tidiness: the record is append-only by construction and the freshest date
governs, so appending is the whole update mechanism. A sweep that regenerates the block instead —
reordering keys, rewriting rows, "cleaning it up" — destroys a measured store's history invisibly, and
the checker keeps no history of its own with which to notice. A store measured for months reads
`not evaluated` afterwards, as though it had never been measured at all. The procedure text is the
only guard against this; there is deliberately no checker code for it.

## Step 5 — measure the exit destinations

Every destination the store's taxonomy names as a governed, bounded surface is measured at the sweep.
For a Claude Code store that is the user-global `CLAUDE.md`, which carries the admission rule and is
loaded by every session — a promotion target that is itself under a load limit.

```text
pwsh skills/agent-memory-compaction/scripts/Measure-MemorySurface.ps1 -Path <destination>
```

The measurement is recorded with **value, unit, date, and surface**, in the store's own counting rule
— UTF-8 decoded, CRLF and lone CR normalized to LF, length in UTF-16 code units — so that it is
comparable with the index's own measurements and reproducible from the file on disk. The shipped
checker will not do this for you: it refuses a path that is not an index, by design.

A measurement missing any of the four fields is non-conforming and is not recorded. The step exists to
be able to say "this destination is filling up," and a number with no unit, no date, or no surface
cannot say it — nor can a hand count that nobody else can reproduce. The instrument validates a record
as well as producing one (`-Validate`), so a malformed one is caught where it is written.

**Where it is recorded.** In the store's own values region, beside the index measurement it is
comparable with, under the reserved growth prefix so an older checker ignores it and says it did:

```text
x-destination_observation: 2026-08-08 | 2534 | characters | ~/.claude/CLAUDE.md | Measure-MemorySurface.ps1 (...)
```

The key repeats, one row per observation, freshest governing — the same discipline `limit_observation`
carries, and the only one available given the write bounds below. The surface is written
home-relative, because a series keyed on one machine's home directory is incomparable the moment the
store is read anywhere else, and comparing a series is the whole point.

A store with **no values region** does not gain one for this — see the write bounds below. It records
the measurement's absence instead: a `proposed` ledger record saying the surface was measured and this
store has opted out of recording it.

## Step 6 — the partition check

```text
pwsh skills/agent-memory-compaction/scripts/Test-MemorySweepPartition.ps1 -InventoryPath <artifact> -IndexPath <index>
```

Every subject in step 1's recorded enumeration is accounted for in exactly one of three ways:

- **still hot** — its pointer is in the post-sweep index;
- **demoted** — its pointer is in `ARCHIVE.md`;
- **exited with a record** — an `executed` ledger record carries its life key.

Anything else is unaccounted, and unaccounted is the report's whole output. A pointer that is in none
of the three left recall without a record, which is the one thing the first replacement rule forbids
outright.

**The check reconciles the recorded enumeration against the post-sweep artifacts** — the index, the
archive, and the ledger, each read from disk after the sweep. It does not reconcile the sweep's own
notion of what it did against itself. A "nothing was lost" check built as a partition of the sweep's
own working list cannot come out negative: every branch of the partition is drawn from the same list,
so it agrees with itself by construction whatever actually happened to the store. The artifact from
step 1 is the input precisely because it was written before any disposition was taken.

Orphan bodies are in the enumeration and are accounted for the same way, with one difference: an
orphan body has no pointer to be still-hot, so it is accounted for as exited-with-record, as demoted,
or as **still an orphan** — which is a lawful outcome only if the sweep dispositioned it as such and
said so.

## Step 7 — record the sweep

Append the sweep's own closing record to `LEDGER.md`. It has a shape, and it is one the grammar
accepts — an earlier revision mandated this step while leaving every plausible encoding of it
malformed, which failed step 6's partition check for a sweep that had lost nothing:

```text
2026-08-08 | executed | sweep-complete | sweep@2026-08-08 | 41 subjects walked, 3 exits, 1 deferral | LEDGER.md
```

`sweep` is a reserved identity name, so this record can never collide with an entry's.

Then mark as `reconciled` the records this sweep read back and confirmed — by **appending** a row
with the same identity and disposition and status `reconciled`, never by editing the earlier row. A
record's effective status is the status of its latest row, which is what makes the retention bound
reachable at all: without that reading, an `executed` record stays executed forever and nothing is
ever eligible for compaction.

If — and only if — the store already has a `store-values` region, append the sweep's date to it:

```text
x-last-sweep: 2026-08-08
```

### The values-region write bounds

Two bounds, both carried from owner rulings on the format, and both invisible to the checker:

**The `x-` prefix is the growth path, and it is not optional.** A key this checker version does not
recognize is a hard error unless it is `x-`-prefixed; prefixed, it is ignored and reported. Stores
outlive plugin versions — a machine can hold a directory per installed version — so a bare
`last_sweep:` key written by a sweep turns a perfectly healthy store into `could not verify`, exit 1,
under any checker that predates it.

**There is no single-valued sweep state in the values region.** Nothing governs a repeated `x-` key:
the checker exempts `x-` keys from its duplicate-scalar check, precisely because this version cannot
know whether a later one means them to repeat. And the record is append-only, so rewriting the
previous `x-last-sweep` row to update it is forbidden. Both together mean `x-last-sweep` **repeats,
one row per sweep, and the freshest date governs** — the same discipline `limit_observation` already
carries. A reader wanting the last sweep date takes the newest row.

**A store with no values region does not acquire one by being swept.** The region's presence is keyed
on its markers, not on what is inside it, and a region holding only `x-` keys records budget inputs as
far as the checker is concerned while containing no observation it can use — which renders `size:
could not verify`, a defect, exit 1. Writing `x-last-sweep` alone into a store that had opted out of
measurement therefore flips it from clean to failing, and it does so through the one key the format
reserved for safe growth. So: **the sweep writes to the values region only when it already exists**,
and a write that creates the region carries a `limit_observation` in the same write. A store that
records no budget inputs records its sweep dates in `LEDGER.md` and nowhere else.

## What a completed sweep leaves behind

- An index whose every departure since the enumeration has a record.
- `LEDGER.md` carrying one `executed` record per disposition taken, the proposals a session raised,
  and this sweep's `sweep-complete` record.
- `SLATE.md` carrying the assessments, deferrals and landings this sweep decided.
- `ARCHIVE.md`, if anything was demoted — created at that moment if it did not exist.
- A partition report accounting for every subject the sweep started from.
- A destination measurement per governed surface, recorded in the values region or its absence
  recorded in the ledger; and either a fresh limit observation or a recorded deferral of one.

A sweep that cannot finish stops and says so. It does not leave the store half-dispositioned without a
record of where it stopped: the ledger's `executed`-record-before-act ordering means the interruption
is visible to the next sweep, which surfaces it first.
