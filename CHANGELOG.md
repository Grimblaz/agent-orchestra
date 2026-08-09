# Changelog

All notable changes to agent-orchestra will be documented in this file.

## [Unreleased]

## [3.15.0] — 2026-08-08

### Added

Memory-store sweep machinery (#1018): the ledger, slate-state and cold-archive record shapes, and the executable sweep procedure with its five-plus-three disposition vocabulary, critical-first ordering, deferral expiry and three procedural checks. Three read-only instruments ship beside the policy check; the checker itself is unchanged at four axes and three parameters.

## [3.14.1] — 2026-08-08

### Changed

- #1024: **read what the reviewers actually posted, before declaring done.** External code-review bots answer on their own schedule — measured on PR #1023, eight findings were available seven minutes after the PR opened, the run pushed its next commit 91 minutes later without reading them, and closed them a full extra round after that. All eight were sustained 8/8 through proxy prosecution, defense and judge, and were disjoint from the 27 findings that run's own 5-pass panel, defense, and two post-fix passes had already produced — including a `high` whose defect class the internal panel had fixed at one call site while never sweeping for the other two. `skills/verification-before-completion/SKILL.md` now rejects an account whose pull request carries unread external findings (property 1 is quantified over the findings *a review* produced, not the ones this run's own panel produced), and carries the trigger with it rather than stating the obligation once and hoping — the same file already records a stated-once terminal obligation emitting **zero** across three consecutive reviews. The trigger reads all **three** distinct collections, paginated: inline threads, submitted-review bodies, and top-level comments. It distinguishes three states, because collapsing them is how an unread review becomes an examined-and-clean claim: findings present, reviewer finished with none, and reviewer not finished — the last being a lawful close that must say so. Warn-only and reader-side; `/review-github` remains the ingestion path and no CI gate is added.

## [3.14.0] — 2026-08-08

### Changed

- #1017 (chunk 1 of 3 for #1015): **the never-retire ratchet is superseded, the store may split, and the check can finally see size.** The shipped `agent-memory-compaction` policy made its own budget arithmetically unreachable — standing entries never retired, so the protected floor grew monotonically past the size the index can actually load — and the checker was blind to exactly that, reporting `RESULT: clean` on a store whose tail the harness was silently truncating. The canonical policy text now states the supersession explicitly and names the three rules that replace the ratchet: no silent exits; an exit is lawful only when its destination verifiably carries the lesson at landing time; destructive acts execute only behind an owner-present slate.
- **A store may now split**: a compact stanza in the index carrying the three write rules in operative form and a pointer to where the rest lives, with the full policy text and that store's own values in a policy file beside it. The stanza's opening marker carries the policy file's path as an instance value, deliberately outside every compared region, so naming a different file can never read as policy drift. `Test-MemoryIndexPolicy.ps1` reports **four axes** instead of three: the policy axis now judges whichever shape the store actually declares, and a new **size axis** measures the index in characters against `fraction × the freshest recorded limit observation`. The budget never renders as a bare number — the formula and the dated observation travel with it on the same line.
- The size axis is **data-driven and honest about what it does not know.** It is evaluated only for a store that records budget inputs; a store that records none reads `not evaluated`, because the legacy shape has nowhere to record them and an axis that fired anyway would be migration pressure rather than a measurement. A store recording inputs the check cannot use — no observation, a malformed one, or one counted in some other unit, which is rejected rather than converted — reads `could not verify` on that axis alone, with the other three still counted. A stale observation renders a signal against a shipped 30-day default bound and is reported, never treated as a defect. The counting rule is pinned in the shipped text (UTF-8 decoded, CRLF and lone CR normalized to LF, length in UTF-16 code units) because a measurement in one unit against a budget recorded in the other passes or fails by accident.
- **No store is obliged to migrate, and that is demonstrated rather than asserted.** A legacy full-header store checked against the new reference reports its policy text as present-but-diverged — never as absent, never as a refusal — with an explanation naming the supersession and three onward paths, obliging none of them. The pre-supersession canonical text ships as a documented, consumer-reachable artifact at `skills/agent-memory-compaction/templates/policy-pre-supersession.md`; passing it with `-PolicyReferencePath` returns the same `RESULT: clean` such a store got before. The reference's canonical stanza is therefore demanded only where a split store is actually being judged — requiring it everywhere broke exactly that route until a test caught it. Presence is now decided by overlap with the reference, scoped to the index's header region, rather than by fixed opening lines, so a future rewrite of the policy cannot silently turn every legacy store's divergence into "absent".
- The **half-migrated** state — stanza written, policy file not yet — is named as such and reported as a defect, deliberately distinct from a policy file that exists and cannot be read (which refuses), and from a stanza whose declared path could never name a file beside the index (a malformed declaration, which also refuses). The entry point's parameter surface is unchanged (`-IndexPath`, `-PolicyReferencePath`, `-Json`), so `-Policy` and `-Index` still bind unambiguously, and `-Json` carries the store shape and the whole size axis alongside the text rendering.
- **The adversarial review found the same defect class in two places and it was fixed in both.** The policy-presence probe had been deliberately scoped to the index's header region; the sibling *shape* probe had not, so an index that merely **quoted** the shipped adoption snippet — in a note to self, inside a code fence — was read as a split store, and the preserved-text route then refused while blaming the shipped template for the index's own content. Stanza detection is now scoped to the header region and to column 0, the shipped snippet is copy-pasteable at column 0, and a standing test asserts the skill's own `SKILL.md` does not parse as a split-store declaration while confirming the marker text is still there — so the guard cannot pass vacuously. The declared policy path is normalized and must resolve beside the index; an adapted store is no longer refused over its vocabulary while half-migrated, since its policy text is in a file it has not written yet; and policy prose left in the header region beside the stanza is reported as the migration residue it is.
- **The store's values are validated as a record, not line by line**, because a file of individually valid lines could still say something false: a second `store-values` region (a documentation example left above the real one) silently governed the budget; a repeated `budget_fraction` silently replaced the first, moving the budget eightfold without a word; and a mistyped year outranked every honest observation *permanently*, since the freshest date governs and the format is append-only — a store reading `clean` while its index truncated, which is the one outcome the axis exists to prevent. A non-finite fraction (`NaN` survives `TryParse`, and every comparison against it is false) reached an `[int]` cast and threw, exiting **1** — the "defects found" code — with no report and an empty `-Json` payload. Each is now a named `could not verify`. The unit comparison is case-sensitive, matching the rest of the file and the claim that the unit is pinned.
- Also repaired while the file was open, and **pre-existing at 3.13.2 rather than introduced here**: a markdown link nested inside another link's text produced a negative substring length and threw, again exiting 1 with an empty `-Json`. Links are now returned in starting order and an overlapping pair routes to the existing exit-2 refusal, which is what the shipped description already claimed happened.
- **It took three rounds to close the marker defect, and each round's fix was caught by the next review pass.** Scoping stanza detection to the index's header region left a store that pasted the migration recipe into its own header still read as split — and moving the shipped snippet to column 0 so it could be copied made that paste land at column 0 by construction. Adding fenced-code tracking failed in both directions at once: quoting a fenced block needs a longer outer fence whose inner delimiter reads as a close, and an unclosed fence in the header hid a *real* stanza, silently switching the size axis off for a store that had done everything right. Each attempt was a heuristic for "is this line quoted?", which markdown does not let you answer cheaply. **The rule is now positional: the opening marker must be the index's first non-blank line.** An index cannot quote something at its own first line without that line being its first line, so there is no spoofing surface, no fence parser to get wrong, and one sentence to document.
- The same passes found five more fixes that closed their exhibit but not the class one step sideways — residue was checked only above the first heading; duplicate-region detection counted only the opening marker, then still missed markers present but out of order; path containment compared case-insensitively (right on Windows, wrong on the Linux runner CI uses); and a trailing separator was reported as an unreadable file that "exists". Two guards could not fail: one fixture omitted the `limit_observation` row, so the axis short-circuited before reaching the cast that threw; and a **one-line residue threshold failed four lawful stores**, including one carrying the shipped check command — which the live index carries today and chunk 3 has to migrate. Residue now takes a run of policy lines, not a line: a store quoting its policy is not a store that still contains it. Regression suite: 32 tests to 106, each fix round's guards verified red against the tree that preceded them.

## [3.13.2] — 2026-08-08

### Added

- Landed Documents/Design/context-engineering-claude-5.md (the #933 assessment) as an in-repo record carrying the settled sequencing, and added discoverability pointers to it from skills/skill-creator (prescription budget at authoring time), skills/ai-first-documentation (guardrail-density audits), and Documents/Design/agent-body-architecture.md (effort re-tune guidance).

## [3.13.1] — 2026-08-05

### Changed

- **Filing Approval Gate presentations must argue, and every ruling must leave a record (#1012).** §2e's batched presentation now carries two argued cases per item — file-vs-do-now (the tripped structural criterion *and* why inline handling is wrong for this change) and placement (against the named alternatives) — and a computed-fields-only presentation is nonconforming on its face, with a stated conformance test that rejects "arguments" mechanically fillable from already-computed values. Every ruling, approve-only batches included, now owes one durable batch-scoped **ruling record** carrying the batch counts, presentation surface, decision timestamp, and each item's as-filed title and outcome; a failed record write blocks the filing rather than producing a stamp with nothing behind it. §2e states a reconciliation procedure with five deliberately distinct outcomes — *located*, *unsupported*, *out of domain*, *could-not-verify*, *not-reconcilable* — because collapsing them is how a detection mechanism becomes a false-accusation generator, and ruling-asserting filings now owe a surface anchor (`-OriginatingPr`) for the reader to search from. The trust bound is stated exactly at both the contract and the enum's defining surface: a located record evidences that a conforming record was written at or before filing time, not that the ceremony ran and not who ruled — detection of a missing record, not prevention of a bypass. The headless-queue payload gap is named rather than papered over and stays deferred until that path has a live producer.

## [3.13.0] — 2026-08-05

### Added

- #998 (chunk 2 of #949, terminal — closes it): **the finish line, stated where every run reads it.** A run that proved every criterion in its brief was, by every standing rule it read, finished — with the mandatory review unrun and the suite in an unknown state. The executor did not skip a rule; there was no rule. `CLAUDE.md` § What a finished run is true of now states **five properties**, scoped to the *act* of declaring done rather than to a lane, with their content present rather than delegated — the pointer-only shape is what #949's design lists as a rejected alternative and calls the established cause of the gap. The space was paid for by extraction, not by raising the ceiling: the Senior Engineer adapter mechanics moved to `Documents/Design/agent-body-architecture.md` and the per-command handshake table to `skills/routing-tables/SKILL.md`, taking the file from 198 to 188 lines — under both the mechanically-enforced 200 and the stricter non-enforced 190 it had been over. Both destinations carry diet-guard sentinels drawn from the moved body, and the two enum literals a suite pins *inside* `CLAUDE.md` stayed behind.
- The **`completion-account` marker family**: the durable, issue-keyed record a run leaves when it declares itself done, registered in the marker-write primitive as `upsert` on the issue surface and documented in the handoff-marker catalog. Issue-keyed is the point rather than a default — every review-pipeline artifact carrying finding-level content is keyed on a pull request, and a conductorless run reviews *before* one exists. Its `ValidatorAdapter` is `$null` deliberately: an adapter is a hard pre-write refusal, which would make a nonconforming account *unwritable* rather than flagged, leaving the run with no durable account at all. `Get-CompletionAccountFromComments` selects the account by its family marker and carries the comment author through, because a record recognised by shape alone does not authenticate itself (#957 Amendments 11/13, shipped by #995).
- Two **warn-only mechanisms**, neither of which fails a run: a required `adversarial_review_ran` assertion with two lexical polarities — **absence reads as *not run*, never as clean** — read by `Read-CompletionAccount`, a reader that is not the account's author; and an **absence backstop on the code-review surface**, so a shipped unit whose adversarial review never ran is enumerable there instead of rendering the reassuring `clean -- sustained=0 blocks=0`. The backstop is id-scoped, honours `review-dispositions` and `review-judge-produced` artifacts (the routes whose adapters declare no judge stage), and carries its counts so it cannot suppress 811-D1's loud negative-gap line. Its live reach is the single-target `-Pr N` path; the corpus sweep drops review-less pull requests upstream, which is stated at the call site and filed as #1009 rather than papered over.
- **An unattended guard for the malformed-region class (#944).** `.github/workflows/phase-containment-region-guard.yml` fires on the **comment event itself** — every one of the 63 lost entries was hand-authored straight into a GitHub comment, and a repository-file check would have caught none of them — and replies in the thread while the author is still there. Warn-only by construction: a GitHub comment cannot be gated, so it reports and exits 0. Its three rules are semantic rather than syntactic — a numeric id only, at least one recognizable entry, and outside a YAML block scalar — which bounds the false-positive direction without the fence-based exemption that would have recreated PR #810's blind spot. The bound is tested against this repository's own prose about the shape across every tracked text file, with corpus-transcribed fixtures as the positive control that the scan reaches real shapes at all. (#944)

### Changed

- **The absolute test-pass rule is replaced by a differential one** in `skills/verification-before-completion/SKILL.md`, as two replacement strings because the checklist item and the stop condition are different speech acts. Against a red baseline the absolute rule could not be obeyed by anyone, so it was being ignored rather than followed. The named baseline **must be an ancestor** of the work — the branch point or merge base, never the run's own post-change commit, a reading under which every clause passes while nothing is checked. Pre-existing failures are **named and routed** rather than blocking, on the headless path (a queued §2e proposal discharges it) as well as the interactive one. The verification-log suite-health block gains baseline slots, so an absolute-only filling is now incomplete. A five-phrasing sweep carried the same rule to `skills/post-pr-review`, `skills/test-driven-development` (quality gates and three workflows), and `.github/templates/implementation-plan.md`; owner decision 873-D4 and GREEN-phase test-writing language were found by that sweep and dispositioned **in place** as deliberately unchanged rather than dropped from the searched population.
- `skills/review-judgment/SKILL.md` now states that **`DEFERRED-SIGNIFICANT (structural)` and `disposition: defer` name one outcome**, not two — the label its own script emits had zero occurrences in the skill's prose, so a reader following it into the owning skill dead-ended. The label is not renamed; the seam was that the skill never said which of its own outputs it referred to.
- **817-D3 is amended as 817-D3a**: code-review may carry one bespoke could-not-verify line, design-challenge stays byte-for-byte frozen, and the bar a surface must clear is stated — the generic "partial, do not trust" wording would send the maintainer to a defect that does not exist.

### Fixed

- **The completion-account reader's own defects, found by review rather than by its green suite.** Two adversarial rounds (an internal 5-pass panel, then GitHub-review intake over CodeRabbit/Sourcery/Qodo/Codex, then a post-fix pass over the fix itself) sustained 37 findings against this chunk. The pattern worth recording: nearly every high-severity one made the mechanism **report an honest run as unreviewed, or a dishonest one as examined** — the exact property it exists to provide. The reader could not parse the assertion example its own documentation prints; it read CRLF bodies (this platform's own write-path output) as *no review ran*; fenced examples, YAML block scalars and HTML comments invisible in GitHub's render all read as *ran*, handing the verdict back to the account's author; and the marker selector matched an unanchored substring, so a quote-reply or a later prose mention could shadow the real account. Marker selection is now first-line-exact — LF-normalized, `TrimEnd` only (leading whitespace is significant and disqualifies), compared ordinally, since PowerShell's default `-eq` is culture-aware and treats a leading BOM or ZWSP as ignorable. Polarity canonicalization decides the verdict; the **raw written token** is what gets reported, so an account writing `yes` is no longer quoted back as `true` and a `yes`/`no` conflict is no longer told its assertions are "(false, true)". Two unrecognized values now read as `value-unrecognized` rather than as a disagreement between two unreadable tokens, and candidate selection sorts by comment id instead of trusting the caller's fetch order.
- **The differential rule's own baseline was unconstrained**, which made property 3 vacuously satisfiable: a run that broke the suite could name its own post-change commit, disposition every failure as pre-existing, and truthfully report "failures added: 0". Since the suite runner emits the run's own commit, that was the *natural* filling, not a strained one. The named baseline must now be an **ancestor** of the work.
- **A phase-containment region that no reader could match produced no signal at all (#944).** A region hand-authored as an open tag on its own line, entries, then a bare `-->` is a syntactically valid multi-line HTML comment. `Get-PhaseContainmentBlock` matches only the self-closed `<!-- phase-containment-{ID} -->` by exact ordinal `IndexOf`, and its malformed-block warnings are reachable only *after* an open tag has matched — so such a region was not parsed, not counted, and not warned about. **31 regions carrying 63 ledger entries** were invisible across nine comments on seven issues/PRs (#471, #784, #810, #853, #880, #884, #937), five of them with total loss. **13 of the 63 carry critical or high severity**, absent from the relaxation veto's severity arm on all four review stages at once. This is the third distinct failure of the same instrument after #782 (emission never happened) and #811 (the check could not parse a surface); unlike both, it was silent rather than wrong.
  - **The distinction now lives at the shared reader layer** both advisory surfaces call, not in either one's rendering. A `$null` return with `SkippedCount` 0 means genuinely absent; with `SkippedCount > 0` it means present and unreadable — two states that were previously the same observation. New optional `-UnreadableEntryCount` and `-MalformedRegionCount` counters report the loss at entry grain beside region grain, because one region carrying seven entries is what made the live advisory on PR #937 report `missing=3` where seven were lost, under a summary line reading `Sustained counted: 3 | Blocks matched: 3` that scanned as balanced.
  - **Markdown code spans are deliberately not gated, and PR #810 is why.** Its two lost regions sit inside ` ```yaml ` fences and are the judge's real emission. The pairing loop matches by ordinal `IndexOf` and has never cared about fences, so a *well-formed* tag inside a fence is read as structure today; gating only the malformed half would count a fenced block while staying silent about a fenced region it lost. An earlier revision of this fix did exclude code spans and went silent on exactly those two. The block-scalar gate (#863 M6) still applies.
  - `Get-EmissionGap` promotes an unreadable region to `could-not-verify` under a new **shared** reason `block-unreadable`, ranked above `head-corrupt` because the two send a maintainer to different files. `Invoke-PhaseContainmentCommentScan` folds the region into `InvalidEntryCount`, so the escape-rate report renders `INVALID-EMPTY` instead of `WITHHELD (denominator=0) — … none carried a phase-containment block`, a sentence that was affirmatively false over bodies carrying sixty-three of them. That render's own wording — "every parsed block failed validation" — is corrected to cover both drop kinds, since nothing parsed an unreadable region.
  - **The corpus is repaired**: all 63 entries readable, total entries processed 2164 → 2227. Every sequence-shaped region was **split, one paired block per entry** — the parser builds one flat mapping per block with no YAML-sequence handling, so a bare terminator repair would have collapsed #937's seven and #784's thirteen and fifteen into single last-wins entries with null keys, trading a silent truncation for a silent invalid-entry drop that makes the advisory look satisfied. PR #937's seven carried `finding_id`, not a schema field; keys were re-derived from that PR's own disposition table (842-D5) and checked against 2,478 enumerated corpus keys, since dedup keys strictly on `finding_key` and overwrites silently.

## [3.12.0] — 2026-08-04

### Added

- New `agent-memory-compaction` skill: the lossless-compaction policy for an agent memory store's recall index. Ships the canonical policy text (the rules a compaction may never break, what may and may not be retired, the ratchet bound, and the authorized size-reduction moves), a consumer adapt-note, and `scripts/Test-MemoryIndexPolicy.ps1` — a read-only, invocation-only check reporting header presence and completeness, linked subjects carrying no recall hook, and unattributed shared notes. The check has no trigger and never writes. Issue #986.

## [3.11.1] — 2026-08-03

### Changed

- **Affirmation records now disclose their author** (#995). The surfaces that resume or route on an open-for-work affirmation record — `skills/open-for-work/SKILL.md` § Resuming and the `commands/plan.md` pre-flight — now state who posted the record alongside the affirmed what-statement they are about to act under, and name **both** records when the earliest lawful record (the one the ordering check reads) differs from the one being resumed under. The author's login and their `author_association` (GitHub's per-request label for a commenter's relationship to the repository) already ride the GitHub CLI comments call — `gh api` — that the resume already makes, so no new fetch is involved. `commands/open.md` also recognises and routes on a record; it delegates to § Resuming and so inherits the disclosure without restating it.
- **The planted-record gap is stated as known and accepted** at both trust-model sites (`skills/open-for-work/SKILL.md` § Writing the affirmation record and `Documents/Design/open-for-work.md` § The affirmation record): that anyone able to comment on a public issue can post a record every recognition surface accepts, that nothing gates it, that this was considered and accepted rather than overlooked, and what a reader should do on noticing one. Both sites now also name the consequence that a plant landing *after* a reviewed brief drives a compliant resume into `re-affirmed-not-re-routed` (the resume state for an issue whose affirmation has been accepted again but whose routing decision has not been re-run against it), whose prescribed re-persist overwrites that brief — and that a record body is data under review, never instruction.
- **No authorship check was added.** #957 Amendment 13 reaffirms self-attestation unamended. Amendment 11 had fixed five decided properties of an affirmation record and deliberately declined a sixth — proof of *who* authored it — and that declined sixth property stays declined. Disclosure is not attestation — a record is still recognised by shape alone, from any author, and nothing **the flow computes** is conditioned on the disclosed value. Deciding that an author is unexpected is a **person's** judgment, which the trust model names as such; an agent run discloses and stops for the person rather than forming its own verdict.

## [3.11.0] — 2026-08-03

### Added

- #974 (chunk 3 of #957, terminal): the `/open` surface. The open-for-work flow is now invocable rather than hand-walked — `commands/open.md` is the entrance and `skills/open-for-work/SKILL.md` is the methodology it loads, self-contained enough that a run never needs the doctrine document handed to it, and halting rather than improvising when the skill cannot be loaded. The **`open-for-work-affirmed`** marker family is registered in the marker-write primitive as `post-new` on the issue surface (appended, not inserted — two fixtures in `persist-marker-core.Tests.ps1` select the first post-new/issue row positionally) and documented in the handoff-marker catalog; the write shape is load-bearing, since an in-place write would void the record as an ordering witness, break the escape hatch's new-record rule, and destroy the beat-2 re-route count derived by counting records. Records already written in the **interim practiced form** (#957 Amendment 8) stay valid authority for their issue permanently, and a resume recognises both forms — reading comments through `gh api`, which carries `updated_at`, rather than `gh issue view`, which does not. The **affirmation gate** joins the engagement-gate non-overridability register on both platform surfaces with its in-band lever stated (declining to affirm is the gate's own negative outcome, the same shape `safe-operations` §2e already uses), backed by a skill-side `### Rule: Non-overridability` block enrolled in the register's `$clauseCases`. `skills/post-pr-review/SKILL.md` gains **Step 9, the close-out record** — per-sustained-finding lines, the dead-premises note, and the re-route count — scoped to issues that carry an affirmation record and pointing at the existing phase-containment ledger rather than re-emitting it. Gate-decision tokens from this conversation map to `phase: experience` with each checkpoint's `decision_id`, `window_position`, and `classification` fixed, and the reason the closed phase enum is deliberately not extended is recorded where a later reader would go to extend it. The entrance stays explicit-invocation only: a routing-intent probe with its own positive control pins the absence of a bare-pickup natural-language intent. Retires the `#957` pending-machinery record in `chunked-delivery.md` and every co-located caveat across `CLAUDE.md`, `.github/copilot-instructions.md`, `README.md`, `HOW-IT-WORKS.md`, `commands/plan.md`, `skills/plan-authoring/SKILL.md`, and `Documents/Design/open-for-work.md` — except the one clause that is a true, standing statement about frozen Copilot support. (#974)

## [3.10.0] — 2026-08-02

### Added

- #973 (chunk 2 of #957): brief-review teeth. The `#### Brief conformance check` gains the **vacuity reading-property** — "Is there a reading of the criteria under which every one passes and no work happens?" — whose answer is an act of *construction*: name the candidate all-pass-no-work reading and the criterion that blocks it, or fail the brief; a bare "no" does not discharge it. A **brief-target** convergence cold read must now ask the same question and emit its answer in both polarities — a surviving reading as a cold-read finding, a clean result as the stated sentence "asked, no surviving reading" — carried by the persisted `**Plan Stress-Test**` summary, so a record's silence is no longer ambiguous between examined-and-clean and never-examined. The requirement has an instructed producer (`agents/code-review-response.md`), not only an asker; a **design-target** cold read is behaviourally unchanged. The **routing call** — beat 2's routine-versus-novel classification — becomes a named review target the charter aims at, with every source-(b) arm defined — including a recorded **novel** verdict, which authorizes no brief at all and is the same lawfulness failure as an absent one (verdict absent is a review *failure* under #957 Amendment 10, not a gap to note) — and a source-(a) not-applicable arm whose stated basis is "carries no routing verdict of its own", never the family-false "no beat 2 ran". What a review failure requires is stated, along with the honest limit that nothing mechanical enforces it. Retires both chunk-2 pending caveats in `Documents/Design/open-for-work.md` and strikes the chunk-2 row from the #957 pending-machinery record. `chunked-delivery.md`'s enforcement paragraph moves its reach-claim: the check now performs the catch A3 names, and what it still does not reach is A1 and A3's own delivery-form rule. (#973)

## [3.9.1] — 2026-08-02

### Fixed

- **AC cross-check helpers read the acceptance-criteria section again (#977).** `Get-AcRefsFromIssue` and `Get-AcTermsFromIssue` captured the issue body with `gh issue view N --json body --jq '.body'`, which emits raw multi-line text. PowerShell captures multi-line external-process stdout as `[System.Object[]]` — one element per line — and `-split` over an array is vectorized, so the section was never isolated: `$parts.Count` was the line count, the `Count -lt 2` guard never fired, and both helpers parsed **the body's second line**. Both now join the captured lines before splitting.
  - The failure was a **wrong input**, not the silent-empty behaviour originally filed. Empty was merely the usual result, because line 2 of a conventionally formatted issue is blank. Against a body whose second line carried a backticked identifier, the helpers returned that identifier as an acceptance-criteria reference — a fabricated match that routes `force-accept`, which *overrides* a structural deferral verdict. The gate could fail open in both directions.
  - Consequences now reversed: `ac_cross_check.source` is no longer pinned to `no-ac-section` on every call, and the `force-accept` and `disposition-gate` arms are reachable for the first time. Confirmed live — issue #968, the original reproduction that returned `@()`, now returns its real acceptance-criteria identifiers.
  - The absent-section warning in `Get-AcTermsFromIssue` sat behind the same dead guard and had never been emitted for any real issue. It fires again. `Get-AcRefsFromIssue` has never carried a warning and deliberately still does not.
  - New regression suite `.github/scripts/Tests/ac-helper-capture-path.Tests.ps1` (23 tests, registered in CI) drives both helpers through a **real external process** via a PATH shim. This is the only coverage that can see this defect class: every pre-existing test substitutes `gh` in-process, which yields a single string and passes against the broken code — measured, alongside the repository's own injected-path stand-in pattern, which fails the same way. The suite was demonstrated red against the unfixed helpers (12 failures) before the fix.
  - **An unresolvable `gh` no longer throws.** `2>$null` redirects the *native process* stderr; it cannot suppress the `CommandNotFoundException` PowerShell raises from its own command lookup before any process starts. Both helpers documented "empty on any failure (missing gh…)" and no caller wraps them in `try`/`catch`, so a machine without `gh` took out the caller's next statement. Both now catch it and return empty. The regression case that claimed to cover this exercised a `gh` that *exists and exits 1* — a different mechanism — and is renamed accordingly, with real unavailable-`gh` coverage added alongside.
  - **Return shape is now documented exactly, and tested.** A single result unrolls to a bare scalar, not a one-element array; an empty result assigns as `$null`, not `@()`. Both are harmless at every call site (`Get-StructuralVerdict` declares `[string[]]`/`[PSCustomObject[]]` and coerces) but both contradicted the previous docstrings. The single-result shape was unreachable before this fix and is now the common case, so it is covered through the consumer.
  - `skills/review-judgment/references/multiline-capture-audit.md` records the sibling-call-site audit: **no second live instance exists**, established from three independently phrased searches — now all three published in full and executable from the record — and verified against **two** planted positives. Adversarial review of this PR found the first revision of that file materially wrong (a malformed `grep`, an incomplete site table, and a control that exercised only the shape the searches were built around); the corrections and what they were are recorded in the file itself rather than quietly fixed.
  - `skills/review-judgment/SKILL.md`'s historical-integrity note now distrusts **every** pre-`3.9.1` machine-computed `ac_cross_check`, not just `source: no-ac-section`. Scoping it to that one value excluded precisely the records that carried override authority: a fabricated line-2 match produced `source: issue`, and `force-accept` — which overrides a structural deferral — was reachable, not unreachable, before the fix. The boundary is anchored on the release rather than on a date, because several pull requests merged earlier the same day carry pre-fix cross-checks.
  - `Documents/Design/script-library.md` now carries the exception to its own `-GhCliPath` mock-injection convention: that pattern cannot prove a multi-line capture, because a `.ps1` stand-in returning one string is captured as `[String]` while a real process is captured as `[System.Object[]]`. Following the repository's documented convention was the second way to reproduce this defect.

## [3.9.0] — 2026-08-02

### Changed

- Cut fixed per-dispatch overhead in the standard adversarial review pipeline: same-model panel prompts share a cached prefix via a shared handshake timestamp, one raw provenance-labeled evidence packet replaces per-pass re-fetching, and a Code-Critic dispatch boots only its selector's review mode instead of the whole six-mode catalog. No change to stages, passes, tiers, selectors, or verdicts. Adds a per-dispatch token-attribution instrument. Measured on one before/after pair over the same target at the same SHA: same-model prompts shared 314 bytes before and 64,740 after, tool calls fell from 92 to 38 in aggregate across the three-pass batch, and a code-prosecution dispatch boots 18,661 B of methodology instead of 19,052 B (a defense dispatch, 15,319 B). Token totals and the two confounds that qualify them are recorded in [Documents/Design/review-dispatch-overhead-measurement.md](Documents/Design/review-dispatch-overhead-measurement.md). (#975)

## [3.8.0] — 2026-08-01

### Added

- #972 (chunk 1 of #957): open-for-work doctrine — new Documents/Design/open-for-work.md (the flow's single account: entrance, worth-it doors, two beats + affirmation gate, routing rule, both outputs, escape hatch, trivial floor, close-out habit, and the affirmation record contract including the interim practiced form per #957 Amendment 8); brief authority restated as two lawful sources (#957 D4) across authoring- and reviewer-path surfaces; A1-A5 binding scope restated to "every brief, whichever authority source it carries" with the artifact-axis narrowing recorded at the site; the six-criteria floor unified across its three moments with the pickup-time risk guard (#957 D6) in safe-operations 2a; new 2f filing content standard and issue templates asking for problem / evidence / known-vs-unknown; the acceptable-resting-state chunking rule (#957 D7); default posture inverted for standalone work; #957-owned pending-machinery record in chunked-delivery.md.

## [3.7.0] — 2026-08-01

### Added

- **Phase-containment ledger: a lawful judge-free emission path for chunk-brief reviews (#951, chunk #956).** The ledger's plan surface could only authorize row emission with a judge ruling, so when #936 D5 re-aimed chunk-plan review to a prosecution-only shape with no judge stage, two runs emitted 56 rows under `judge_ruling: sustained` for reviews no judge adjudicated — and the emission check reported `clean` on both, because it verified that blocks were present, paired and counted against an authorizing record, never that the record's claims happened.
  - New `caught_stage: brief-review` at stage projection 2, authorized by a distinct `brief_dispositions:` head. The token is deliberately not `finding_dispositions:` — what the design surface proves is the judge-free counting *rule*, not the literal, and reuse would have collided with an ungated detector and manufactured a permanent false design-challenge gap on every brief.
  - The head must carry a machine-readable `convergence_filter_ran` assertion, checked over its full value domain: absent and `false` both render could-not-verify, only `true` (with a `filtered_count`) can reach clean.
  - Surface routing is per issue, on either the plan comment's `plan-variant: brief` declaration or the ledger sibling's own brief head; `plan-stress-test` is suppressed on a brief-routed issue so the mandated `**Plan Stress-Test**` literal no longer forces a permanent false gap.
  - A brief-declared issue whose ledger sibling carries a judge-rulings head renders could-not-verify naming the contradiction (scoped to the sibling, so a co-located code-review judge head does not trip it).
  - The escape-rate rollup reports each arm partitioned by adjudication standard, with the sufficiency guard re-derived per sub-arm; a failed or empty sub-arm renders WITHHELD, never a legitimate zero.
  - `persist-phase-ledger.ps1` gains `-Mode brief`; its dispatch is restructured from `if design … else assume-plan` into an explicit per-mode branch that refuses an unhandled mode instead of falling through into plan logic.
  - The caught_stage drift guard rises from three-way to four-way, adding the assertion nothing made before: that the `finding_key` alternation names the same set as `caught_stage`. Without it, updating three of five sites left both prior guards green while every new block was silently discarded.
  - `.github/scripts/migrate-brief-review-corpus.ps1` corrects the contaminated corpus: idempotent, bounded to #939 and #941, and self-verifying at verdict grain (it re-reads, re-parses and re-renders the emission verdict, since a count-grain recount passes on rows that are present, parseable and invisible to every reader). Running it is a precondition of closing #951, not of merging this change.

## [3.6.1] — 2026-07-28

### Fixed

- **Full local test suite restored to green (#948)**: seven contract assertions across six files were failing on `main`, so a suite run could not tell a maintainer whether their own change broke anything. Five of the seven trace to one event — PR #903 added the goal-run agent (manifest entry, shell, shared body, extracted reference) and tripped four separate contract tests that CI's allowlist never runs.
- `agents/goal-run.md` now enumerates all eight `Goal-Run.agent.md` sections; the shell had been under-enumerating two, silently dropping them from the methodology the agent is told to follow.
- `agents/goal-run.md` is now registered in the Claude body-resolution contract, bringing it under the D1 byte-alignment assertions it had been escaping.
- `skills/customer-experience/SKILL.md` indexes its `goal-run-surface-classes.md` reference; `CLAUDE.md` again names the eight supported plugin CLI commands.
- The agent-count assertions derive their expected value from the plugin manifest instead of a hard-coded literal, which also detects a declared agent that fails to resolve — a case the literal form passed wrongly.
- The Copilot-sunset `-Skip` guard no longer flags platform-conditional skips as de-obligations, and `phase-containment-report.Tests.ps1` no longer races sibling workers over the shared temp directory.
- New: `Documents/Design/test-suite-baseline-948.md` records the launch baseline, the runner's counting and false-green traps, and the disposition of every test that was red.

## [3.6.0] — 2026-07-28

### Fixed

- Squash-merged Claude Code worktrees are now surfaced by the session-startup cleanup check. The candidate gate no longer renders a merged verdict of its own — a squash merge writes a new commit, so the ancestry test it used discarded the ordinary case before any evidence was gathered. The eligibility gate is now the sole authority, on all three candidate paths.
- The merged verdict rests on content evidence. Patch-history equivalence (`git cherry`) establishes neither a merged nor an unmerged verdict; a clean merge-tree whose result still differs from the remote default establishes the negative. Merged evidence names the signal that established it.
- Local evidence is gathered for every candidate before any candidate spends the GitHub API budget, so a worktree that needs no network call is never refused because other candidates used the budget up. The local pass carries its own time bound.
- Manual-review reasons name the cause that actually applied: running out of time is reported differently from having too many candidates, and "could not verify" is no longer reported as "unmerged commits".
- The cleanup command block is printed only when there is a command in it; otherwise the check says there is nothing to run and why.
- An eligible worktree past the ten-line display cap still appears in the offered cleanup command.
- **Deliberate silence, new in this release:** a worktree or branch the check concludes is carrying live, unmerged work — content evidence says so, and no merged pull request matches its current tip — is now reported not at all, rather than as a manual-review line. This is the one thing the check deliberately stays quiet about; it exists so an in-flight worktree does not produce a line at every session start. Everything else it declines to offer is still reported with the reason.

## [3.5.0] — 2026-07-28

### Added

- **Brief is a first-class plan shape (#941, chunk 3 of #936).** `plan-variant: brief` joins spine-bearing and goal-contract as a lawful plan shape. `skills/plan-authoring/SKILL.md` gains the authoring contract (frontmatter key, six required sections, and the `#### Brief conformance check` over the four mechanical properties #936 D5 named); `Invoke-FVPlanValidate` accepts a conforming brief, rejects a document declaring itself a brief while carrying none of the required sections, and rejects a brief carrying a frame-spine or goal-contract block as ambiguous. Two briefs had already shipped by riding the `spine-omitted: plan-too-small` size carve-out, which was never a statement about shape.
- **Chunk-plan review charter re-aimed by adapter selection (#941, #936 D5 as corrected by DA4).** A brief-shaped chunk plan is dispatched to the prosecution-only `design-challenge` adapter at every point that actually selects one (`commands/plan.md`, `skills/plan-authoring/SKILL.md`'s stress-test step, and the `agents/Issue-Planner.agent.md` charter). `skills/adversarial-review/adapters/standard.md` is untouched: it is the code-review adapter, so a pass-count edit there would have relaxed every code review over its size threshold.
- **Consuming surfaces taught the brief (#941).** The planner's spine-append escape, Spine-Runner's no-spine message, `orchestra-spine.ps1`'s render precedence, `frame-spine-lookup`'s scope note, and Code-Conductor's dispatch fall-through each handle a brief explicitly; Code-Conductor's goal-contract halt is preserved. New shared reader `Get-FSCPlanVariant` (`frame-spine-core.ps1`) so the validator and the spine renderer read the declaration one way.
- **Doctrine migrated (#941).** `CLAUDE.md` and `Documents/Design/chunked-delivery.md` now name the brief in Bound 2, the operating rules, and the panel-depth clause; A3 names the brief's fourth section as the container for falsifiers. Per #936 DA5 the interim operating-rule wording names no command — `/goal-run` halts on any plan lacking a goal-contract block, so it cannot run a brief — and the `## Deferred follow-up` row is routed to #924 rather than guessed.

### Fixed

- **Brief validation hardened by the #947 adversarial review** (25 of 31 merged findings sustained). The section-presence check now strips fenced regions and HTML comments before scanning — a document quoting the six headings in a fenced example previously validated clean, which made the "recognising the token is not validating the shape" claim false. `\s+` became `[ \t]+` (`\s` crosses newlines, so a bare `##` line paired with an unrelated next line satisfied a heading that did not exist). A frontmatter declaring `plan-variant` twice is now rejected on arity rather than classified by line order. Real `<!-- goal-contract -->` heads are counted outside fenced regions instead of reading `Get-GCContractBlock`'s zero-or-more-than-one conflated `$null`, which failed open on two real blocks and closed on a brief quoting one. Also: line-ending normalization, comment-closure tracking in the frontmatter skip loop, a named error for an unrecognized variant, per-section arity, and rejection of orphaned frame-slice blocks.
- **The `design-challenge` shape now carries its convergence filter at every brief dispatch site.** #936 D5 specified it and the first implementation omitted it, leaving `solution-authoring`'s non-overridable classification gate with no defined input for a brief. `skills/adversarial-review/adapters/design-challenge.md` and the platform adapter table now declare both consumers instead of asserting Solution-Designer exclusivity.

### Known gap

- **A brief's plan review has no phase-containment ledger emission path** (#936 DA6). The ledger's plan-surface writer is judge-gated end to end, and the re-aimed charter removes the judge stage, so a brief renders `plan-stress-test: COULD NOT VERIFY` until #936 defines the brief's emission surface. Stated in `skills/plan-authoring/SKILL.md § Brief plan variant` and in the doctrine's panel-depth bullet rather than worked around — suppressing the fallback's trigger literal would produce the silent zero that fallback exists to prevent.

## [3.4.15] — 2026-07-28

### Changed

- **Chunked-delivery doctrine gains amendments A1-A5** (#939, chunk 1 of #936). `Documents/Design/chunked-delivery.md` now carries five rules governing the knowledge level a chunk plan may specify at: discovery-neutral targets (A1), provenance-marked grounding (A2), falsifiers as executor guidance rather than check hardening (A3), behavior pins plus a pre-launch floor check (A4), and evidence obligations with fixed properties and free format (A5). Each states what it forbids and what it requires instead.
- **`skills/verification-before-completion/SKILL.md` amended to reject non-discriminating evidence.** A5's three properties — discriminating, attributed, per-criterion — are defined once under a new Evidence Obligations section and carried in place by all twelve regions of the file that prescribe or accept proof: the requirements and testing checklists, the verification-command block, the before-pull-request checklist, both Acceptable and Insufficient Evidence lists, the verification log template, the almost-done and rationalization tables, the red flags, the definition-of-done template, and the gotchas table. Sections that check something other than proof are unchanged. Previously the file blessed proof (a passing-test screenshot, a green CI link) that would read identically against the pre-change tree while its insufficient-evidence list objected only to vagueness and staleness.
- **`CLAUDE.md` gains a compact pointer** stating what each of A1-A5 binds and where the full doctrine and A5's standing home live, sized to keep the file within its 200-line diet guard.
- **Migration note added** to the doctrine document naming every doctrine sentence that later chunks of #936 replace and which single chunk replaces it, with the in-between wording fixed for the passages that change twice. Marked as a deliberate historical reference between machine-readable sentinels so the migration completeness check stays meaningful. Issue #943 retires it.
- **Vocabulary and naming-register entries added** for `A1`-`A5`, `DA{N}`, `Bound 1 / Bound 2`, and the three evidence properties, so the new numbered families decode without leaving the surface that names them.
- **"Discriminating" is defined by whether the check could have failed, not by whether its result changed.** A criterion claiming something *new* is true needs a result that differs from the pre-change tree; a criterion claiming something is *preserved* — a refactor, a backward-compatibility guarantee, "no breaking changes to dependents" — is evidenced by a parity run, provided you say what that run would have caught. Without this split the guidance would reject the correct evidence for every preservation criterion.

## [3.4.14] — 2026-07-27

### Fixed

- `Get-CostTranscriptSlug` now mirrors Claude Code's actual projects-directory naming rule — every non-alphanumeric character maps to `-`, nothing is collapsed or case-folded, and slugs over 200 characters are truncated with a base-36 hash suffix. The previous per-segment join lowercased the drive and only substituted spaces, so it derived a directory that never existed for any `.claude/worktrees/*` checkout, leaving the primary-slug lookup permanently dead. No cost data was ever lost or misattributed by this — an independent identity-matching path already admitted worktree directories — so the customer-visible symptom was a misleading `slug directory not found` warning on every cost walk from a worktree, which trains a reader to ignore a diagnostic that will one day be real (#908).
- The over-cap hash preimage is now the canonical `process.cwd()` path shape, so the same physical path spelled with forward slashes (as `git rev-parse --show-toplevel` emits) and with backslashes derives one slug. Previously they diverged above 200 characters into an unrecoverable content difference (#908, found in #932 review).
- The git-bash MSYS drive rewrite is gated on Windows. On a POSIX host `/c/repo` is a genuine directory whose correct slug is `-c-repo`; rewriting it there corrupted a correct derivation (#908, found in #932 review).
- A path carrying no alphanumeric character derives an empty slug again, restoring the pre-#908 degradation. Downstream callers guard on emptiness rather than validity, so an all-dash slug would have passed those guards and started a walk on garbage (#908, found in #932 review).
- Registered `cost-walker-slug.Tests.ps1` as a CI gate, split out of the never-registered `cost-walker.Tests.ps1`. The split file is Linux-clean by construction; the parent suite stays unregistered because this repo has no way to measure whether it is Linux-clean, not because it is known red (#908).

## [3.4.13] — 2026-07-26

### Fixed

- goal-run: ignore `goal-run-active.json` and `goal-run-log.jsonl` so a freshly provisioned goal-run worktree reports a clean tree. The harness writes both at the worktree root by design (874-D6) and the contract validator refuses a dirty `-RepoRoot` before anything else, so every run's first predicate call previously halted with `refused: uncommitted-changes` (#929).
- `Ensure-ScratchGitignore.ps1` now writes the same two patterns to each consumer clone's `.git/info/exclude` at SessionStart, so a goal-run worktree reports clean there too. The exclude file is deliberately **not** the hub's committed `.gitignore` approach: it is per-clone and untracked, so it cannot itself dirty a tracked file — appending to a consumer's tracked `.gitignore` would have left the launch repo modified and re-triggered the same `refused: uncommitted-changes` halt (#929). Caveat: the same script's *separate*, pre-existing scratch-containment step (#643) still appends its patterns to the consumer's tracked `.gitignore`, which is deliberate for scratch containment but can leave a consumer's launch repo dirty on first run until they commit that file — so a first `/goal-run` may still hit `refused: uncommitted-changes` from that unrelated path. That mechanism is unchanged here and tracked separately.
- Correct five stale "not yet threaded" claims in `goal-contract-validate-core.ps1`'s own doc comments: the suite green floor, target checks, and diff-integrity phases have all been wired since s6. The stale text caused a plan to describe the absolute zero-failure suite gate as baseline-relative (#929).

## [3.4.12] — 2026-07-26

### Fixed

- **`/goal-run` is resumable after an interruption (#912).** An interrupted run previously could not be resumed at all: the resume path needed the dead session's transcript, and the run-in-progress marker was never cleared on any ending, so the issue locked permanently after the first interruption — or after a successful completion. Resume now re-derives where a run actually got to from committed worktree state via re-validation, never a transcript.
- **Marker adoption replaces resolve-and-proceed.** A resume adopts the run-in-progress marker rather than resolving it, so a still-live run keeps its mutex. Admission is session-identity-aware, so the owning session can safely re-enter its own adopted run.
- **Two operator levers: `/goal-run {issue} adopt` and `/goal-run {issue} restart`.** `adopt` force-adopts past a fresh heartbeat; `restart` captures the worktree path and branch into a durable report before clearing anything, refuses outright against a live run, and clears both the stage marker and the active-state file.
- **Tree-state validator refusals route to relaunch.** `refused: uncommitted-changes` and `refused: no-run-diff` — the modal states for an interrupted run — no longer collapse into a permanent halt loop.
- **The loop predicate reports its halt truthfully**, including when the report itself cannot be filed. No in-predicate condition can stop the vendor loop; that gap is tracked separately in #927.

## [3.4.11] — 2026-07-26

### Added

- Deterministic marker-write primitive (issue #893): new persist-marker.ps1 CLI + persist-marker-core.ps1 registry-driven transport replaces hand-composed gh comment calls for eight durable marker families. Promoted transport core in marker-transport-core.ps1, per-family validator adapters, burst-manifest mode, and a UTF-8 console-encoding fix for non-ASCII payload fidelity (found live by CE Gate). Agent bodies, skill docs, and the marker catalog now name the script as the sole documented write path.

## [3.4.10] — 2026-07-25

### Fixed

- Added the missing `claude-opus-5` row to `cost-rate-table.json` (issue #905) — Claude Code sessions now default to Opus 5, and every orchestrated PR since its launch had been silently losing USD cost attribution for those events.
- Fixed `cost-attribution.ps1`'s totals rollup: an event whose model has no rate-table row previously contributed nothing to `totals.cost_estimate_usd` with no signal that anything was wrong, so the reported PR cost silently understated real spend instead of going visibly unavailable. The total now one-way-latches to `null` on the first unresolvable model (never un-latches on a later priced event), while the pre-existing per-port `rate_unavailable` behavior for known-but-unpriced rows (e.g. Copilot, by design) is deliberately unchanged. Registered the cost test suites in CI (`pester.yml`) for the first time — no cost suite had ever run in any workflow, so this correction was previously unenforceable by any automated gate.
- Refreshed the per-agent model + reasoning routing documentation (`Documents/Design/agent-body-architecture.md`) to reflect Opus 5's launch and correct a stale routing-table legend and citation drift in `cost-rate-table.md`.

## [3.4.9] — 2026-07-23

### Fixed

- Wired the goal-run harness's budget arm, heartbeat, and run-log primitives into the live orchestration path (issue #874 review-gate fix cycle A2): the wall-clock budget arm and heartbeat updates now fire at real chain-stage-boundary call sites instead of having zero live callers; fixed a Kind-unaware datetime subtraction that skewed dead-run detection by the machine's UTC offset; gave the run log a real file location, schema-validating writer, and checkpoint reader; recorded the run's worktree path on the inflight marker so resume no longer depends on an undefined filesystem glob; fixed the mutex yield path to always resolve its own inflight marker; reconciled the stage-marker write/read vocabulary.

## [3.4.8] — 2026-07-23

### Added

- Added the CE Gate goal-run surface-class delegation doc (skills/customer-experience/references/goal-run-surface-classes.md, 874-D8), classifying read-safe vs mutating goal-run harness surfaces for CE Gate exercise (issue #874 plan step 9).

## [3.4.7] — 2026-07-23

### Added

Goal-run harness methodology skill (issue #874, plan step 8): skills/goal-run/SKILL.md documents the stage-machine contract, the five-value halt-precedence model, the Arm I launch sequence (with brief Arm H/Arm M forward-pointers), the worktree provision/state-file/teardown lifecycle, the goal_run_class label-to-ledger join key for escape-rate segmentation, and the untrusted-content discipline (contract-hash pin, transcript allow-list plus secret-redaction, executor-evidence inert-rendering).

## [3.4.6] — 2026-07-22

### Added

Goal-run harness stage machine (issue #874, plan step 4): the `/goal-run {issue}` command, the shared `agents/Goal-Run.agent.md` body, and the Claude Code `goal-run` subagent shell — a minimal top-level stage vocabulary (pre-loop | loop-launched | loop-released | chain-dispatched) that resumes at the first incomplete stage from durable artifacts only, a marker-first-then-provision mutex with reconcile tiebreak, crash-atomicity detection for dead in-flight runs, and a bounded-retry control-return-then-read sequence for the vendor goal-loop verdict. Arm I only; the post-loop chain body and terminal-emissions verification are explicit seams for a later step.

## [3.4.5] — 2026-07-21

### Added

- Goal-run capability probe (#874 AC5): three reusable, Pester-tested instruments under `.github/scripts/lib/` — a stream-json terminal-result parser, a live transcript usage reader with absent-vs-zero discrimination, and a force-halt win/loss detection rig — plus an execution, credential, and containment run-book at `.github/scripts/README-goal-probe.md`.
- Labeled evidence document `Documents/Design/goal-loop-capability-probe.md` recording an eight-leg probe outcome with per-leg build attribution (CLI 2.1.150 / desktop app 2.1.215 / CLI 2.1.216): five legs observed, two partial, one explicit gap.
- Key findings: headless launch requires `--verbose` and an explicitly pinned `--model`; `--max-budget-usd` reports breaches through a structured `error_max_budget_usd` terminal event, overshooting by roughly one turn's cost; `/goal` does **not** start a goal loop under `claude -p` (it is consumed as literal prompt text), and headless default permissions deny every write with no reachable approver, burning the full budget; and goal release, while rendering no status line, emits a typed `goal_status` transcript event carrying the evaluator's own verdict, reason, iterations, duration, and token count.
- Registered the `goal-probe-findings-{ID}` handoff-marker head as the deferred goal-run harness plan's deterministic lookup surface.

## [3.4.4] — 2026-07-21

### Fixed

- Replaces the sibling/orphan worktree-branch removal reachable-from-origin/main heuristic with an evidence-gated eligibility primitive (issue #889): zero-unique-commit branches now require positive evidence (an OID-checked merged PR, then a closed parent issue) instead of trusting trivially-true git tree-equivalence alone.
- Fixes the false skipping message that let session-start cleanup silently destroy a mid-task worktree, replacing it with an honest 6-state removal-outcome enum.
- Adds a shared primary-worktree guard called identically by the detector and executor, closing the gap where the primary checkout could be offered for deletion.
- Absorbs issue #522: locked worktrees are never force-removed unless Test-Path-confirmed absent (real git never sets the porcelain prunable flag on a locked worktree).

## [3.4.3] — 2026-07-20

### Fixed

Grounding Evidence block now persists to the design body's durable text (issue #866): the /design Grounding Discipline previously wrote its evidence table only to the ephemeral session, so the downstream Issue-Planner standards check could never find it (measured 1 of 7 designs persisted it). Adds a canonical sentinel-plus-heading shape, an escalation-note rule for could-not-ground-escalate rows, a body-size compact gate, persist-time re-grounding, and a Completion Gate checklist item. Also ships a corpus-check diagnostic script (AC7) for on-demand persistence measurement.

## [3.4.2] — 2026-07-20

### Added

Goal-contract validator (`goal-contract-validate.ps1`): independent, non-transcript re-validation of an autonomous goal-run's completion claim — contract intake gates, detached-worktree execution, absolute green-floor suite gate, test-diff integrity flags, and an emit-only machine verdict (#873).

## [3.4.1] — 2026-07-19

### Changed

- Sibling write-path guarantee-parity check in the adversarial-review Architecture checklist, cross-referenced from Security. Post-fix verification scope widened across prosecution and judge to cover every branch a fix commit modifies. Consolidated the append/replace phase-containment preflight into one shared helper. (#886)

## [3.4.0] — 2026-07-19

### Added

- Goal-contract artifact: schema, parser library, and frame-validate structural branch for the goal-contract plan-authoring variant (#872). Adds `skills/plan-authoring/schemas/goal-contract.schema.json`, `.github/scripts/lib/goal-contract-core.ps1`, and a `plan-variant: goal-contract` branch in `frame-validate-core.ps1`/`orchestra-spine.ps1` that accepts the new variant while still rejecting bare spine-less plans. Registers the `goal-contract` and `goal-halt-report` marker heads in the handoff-markers catalog.

## [3.3.22] — 2026-07-18

### Fixed

- Fix phase-containment block doc examples in plan-authoring, design-exploration, and review-judgment SKILL.md to the paired-tag shape the parser accepts, closing the doc/parser shape mismatch that silently starved the phase-containment escape-rate ledger (#878).

## [3.3.21] — 2026-07-18

### Fixed

- Single-owner Post-Judge Disposition Gate emission site + review-dispositions landing-gap governance metric for issue #869 (#880).

## [3.3.20] — 2026-07-17

### Added

- Add Two-Layer Research Delegation convention to research-methodology (#691): routes upstream-phase fan-out repo reads to a native Explore subagent dispatch with a file:line citation contract; wires pointers into design-exploration, plan-authoring, customer-experience, multi-issue-bundling.md, and subagent-env-handshake.

## [3.3.19] — 2026-07-17

### Added

Cost summary v5 (issue #489): USD-per-PR headline plus rolling-cost baseline in orchestrated PR bodies as an additive `metrics_version: 4` field, zero-activity port row suppression in the cost-breakdown table, and a harvest reconcile path that keeps the PR-body headline synchronized with the end-of-session cost pattern. Includes the Step 7d harvest dot-source chain extension (adds `frame-credit-ledger-core.ps1`) that requires this version bump to reach cache-served installs (PR #870 external-review F1).

## [3.3.18] — 2026-07-16

### Fixed

- Plan comments no longer hit GitHub's 65,536-codepoint comment cap. `frame-slice` blocks move to a `frame-slices-{ID}` sibling comment and `phase-containment`/`judge-rulings` blocks co-move to a `phase-containment-ledger-{ID}` sibling, both pointed to from the plan comment (#863). Fixes the #854 incident where an authoring agent spent 5-10 rounds compressing load-bearing plan content to fit under the cap.

### Added

- `frame-spine-lookup`'s Dispatch Inputs gain a second, optional sibling-comment id; the shim fetches and concatenates both bodies when present, with an identity check guarding against a stale or mismatched pointer.
- Block-level `appended_at` provenance on phase-containment ledger entries, written by `Add-CommentBlocks` at actual write time (and by hand-authored code-review emission), so dedup resolves correctly once blocks span multiple comments.

## [3.3.17] — 2026-07-16

### Added

- Added session-cost discipline rules (parent-side diagnostics, targeted edits, batching, extract-do-not-dump) to `skills/terminal-hygiene/SKILL.md`, with pointer references in Code-Conductor and the three upstream agent bodies, and a CI-registered contract test (#474).

## [3.3.16] — 2026-07-16

### Added

- Rate-table refresh (issue #487): 6 new rate-table keys for models not previously in `cost-rate-table.json`, a new unknown-model Cost Pattern Note giving a per-reason breakdown (`unknown_key` / `rate_unavailable` / `rate_unavailable_malformed` / `empty_model`) instead of a single opaque count, and two new additive `cost-pattern-data` YAML fields (`unknown_models`, `null_cost_events_by_reason`) so the breakdown round-trips through the rolling baseline.

### Fixed

- Corrected the `claude-opus-4-7` rate-table entry, which was priced at roughly 3x the correct rate (issue #487).
- Fixed the frame-spine template in `skills/plan-authoring/SKILL.md` (`### Plan-markdown template`): the example `<!-- frame-spine ... -->` block was authored at 3-space/6-space indentation, but `frame-spine-core.ps1`'s parser requires exactly 2-space/4-space and returns `$null` silently on any mismatch. Every plan authored from the prior template carried a dead spine.
- The Cost Pattern Note no longer reports Claude Code's `<synthetic>` message marker as an addable unknown model (issue #487). `<synthetic>` is what Claude Code puts in `message.model` for assistant messages it injects itself (API-error notices, status lines); it is not a model and can never resolve against the rate table, so the Note was instructing maintainers to add a rate row that would never match. Zero-usage `<synthetic>` events are now excluded from `unknown_models` and from `null_cost_events` entirely — their true cost is exactly `0.00`, and counting them rewrote a genuinely-`0.00` bucket cost to `null`, the same misleading-null class issue #487 exists to eliminate.
- Fixed silent loss of the Cost Pattern section during re-emission preservation (issue #487). `$script:FCLCostPatternSectionRegex` was missing from `Get-FCLCostScriptState`'s marshal list, so it resolved to `$null` inside the worker runspace clone. `[regex]::Match(body, $null)` does not throw — it returns `Success=True` with an empty match, so the preservation branch accepted an empty section, never reached its YAML-only fallback, and posted the "prior populated render was kept" notice with the cost data destroyed. The regex is now marshaled, and the acceptance guard additionally requires a non-empty captured section so any future empty-match cause degrades into the fallback instead of silent data loss. Third instance of the worker-runspace `$script:`-constant drop first fixed for issue #825 (C3) and issue #496 (C-1).

## [3.3.15] — 2026-07-16

### Added

- Phase-containment ledger closes the code-review terminal-stage blind spot (#854): a new `post-review-observer` caught-stage (projection 4) turns external-reviewer catches the pipeline missed into real ledger escapes, and the maintainer report renders a two-arm code-review verdict (catch-side veto + escape-side miss estimate) instead of a structurally-artifactual `0.00`/`ELIGIBLE`.
- `skills/review-judgment/SKILL.md` documents the observer emission variant: the `post-review-observer:{stable_finding_key}` prefix, novel-gated trinary dispatch, and exact-equality `local`-sentinel matching that a judge must follow when emitting phase-containment blocks in production.
- `Documents/Design/phase-containment-ledger.md` records the two-arm certification model, the fail-closed coverage/NaN/reconciliation guards, and the two owner-approved doctrine revisions (`value-block-cost-dependency-854`, `coverage-authorship-854`) this issue made explicit.

## [3.3.14] — 2026-07-15

### Fixed

- **Cost telemetry: raised the walker budget chain so a real profile can finish (#496).** The Claude cost walker was given a 10s timeout, but a measured real profile (`~/.claude/projects` = 696 MB / 1770 jsonl files) needs **69.1 seconds** to walk. This was not flaky: it failed deterministically on any machine with a grown profile, so cost telemetry was silently lost and the `Cost Pattern Presence Check` continuous integration (CI) job failed. Because the corpus grows ~22 MB/day, the new defaults carry real headroom rather than a token bump: Claude walker 10s to 180s (~2.6x the measured worst case), Copilot walker 6s to 60s, cost sub-budget 19s to 270s, and outer ledger budget 30s to 300s. Raising a timeout is nearly free: it only binds in the slow case, and in CI there are no transcripts, so the walk returns instantly and the higher ceiling never engages.
- **Centralized the cost-telemetry budget constants (#496).** The four coupled knobs were hardcoded literals scattered across two files, and they nest: both walkers must fit inside the cost sub-budget, which must fit inside the outer budget. The outer budget is a hard wall (`WaitOne` then `Stop()`), so raising an inner knob alone silently accomplished nothing. All four now live in `.github/scripts/lib/cost-telemetry-budgets.ps1`, which is loaded (via PowerShell dot-sourcing, the mechanism that imports a script's variables and functions directly into the caller) by `frame-credit-ledger.ps1` and `lib/cost-session-render.ps1`. Each consumer still lets an environment variable override the constant when one is set, exactly as before. The rolling-history fetch budget and cache TTL move there too, with their values deliberately unchanged. A new Pester contract test (`.github/scripts/Tests/cost-telemetry-budgets.Tests.ps1`) asserts the nesting relationship, so a future edit to one knob can no longer silently break the chain.

## [3.3.13] — 2026-07-15

### Added

- Add a checklist item to implementation-discipline requiring authors to audit multi-cause explanatory text (Notes/warnings) for cause-conflation and missing companion-doc cross-references, per issue #487's CE Gate Track 2 finding.

## [3.3.12] — 2026-07-13

### Added

- Reviewer attribution wired end-to-end: GitHub-review findings carry a durable `reviewer_source` from intake ledger through judge disposition, so per-reviewer accept-rate evidence can be compiled for external AI reviewers (#834).
- Consumer-facing guidance for enabling external AI reviewers (e.g. OpenAI Codex) added to CUSTOMIZATION.md.

## [3.3.11] — 2026-07-12

### Added

- Add a maintainer-approval gate (`safe-operations` §2e Filing Approval Gate) before pipeline-initiated follow-up issues are auto-filed, across eight filing surfaces (#837).

## [3.3.10] — 2026-07-11

### Added

- Add per-stage review-cost term (dismiss-rate, defense-kill rate, per-reviewer-source table) to the phase-containment ledger; schema v3 adds optional reviewer_source (#768).

## [3.3.9] — 2026-07-10

### Added

- Rolling-baseline eligibility for the cost-pattern startup harvest (issue 824): a strict whitelist predicate promotes eligible partial-session and complete-session cost patterns to end-of-session baselines, with capture-point tracking, session-id round-tripping, and a visible startup signal for both successful and expected-but-failed upgrade attempts.

## [3.3.8] — 2026-07-10

### Fixed

- `phase-containment.schema.json` `finding_key` now enforces a `{surface}:...` format pattern; `Test-PhaseContainmentEntry` gained Rule 12 (case-sensitive match) to reject malformed keys before they reach the escape-rate ledger.
- The escape-rate report and emission-check now flag every silent-truncation path (GraphQL/REST pagination breaks, REST per-item and list-level fetch failures, the REST discovery cap) via a total `Truncated`/`InvalidEntryCount` telemetry contract present on every return shape; a degraded run is no longer cached as clean.
- The phase marker hunt now paginates up to 5 additional comment pages before giving up on a markerless issue/PR (was: dropped after page 1), and resumes unbounded collection after a marker is found so a ledger block on a later page is never missed.
- REST-sourced ledger entries now carry real `createdAt` timestamps (was: hardcoded empty), restoring latest-annotation-wins dedup under the REST fallback path.
- `Get-PhaseContainmentBlock` now pair-matches open/close marker tags so an unclosed block no longer silently corrupts the following block's fields; skipped blocks are counted and warned.
- The report renderer was extracted to a production `Format-PhaseContainmentReport` function and gated by a new Pester spec exercising the same acceptance literals the retired `Invoke-CEGate762.ps1` harness checked (deleted — it had drifted from production on the data-untrustworthy branch).

Closes #772.

## [3.3.7] — 2026-07-09

### Fixed

- `Set-IssueParent.ps1` (new): attach-existing sub-issue primitive with loud (non-zero exit) failure and a detectable `Parent: #N` + `text-fallback` body-marker splice, extracted from `Add-FollowUpIssue.ps1`'s embedded GraphQL linking, so the documented umbrella-attach command is no longer a silent no-op (#800).
- `render-portfolio.ps1`: added a warn-only `OrphanClaimWarnings` bucket (tracker body + CI `::warning::`) flagging open issues that claim a parent with no real sub-issue link, using per-producer regex anchoring so the mid-line `placement=parent #N` residue format is caught (#800).
- `safe-operations/SKILL.md`: corrected five 2b-bis/2b-ter drift sites that referenced a nonexistent `Add-FollowUpIssue` attach-existing capability, pointing them at `Set-IssueParent.ps1` (#800).
- `Set-IssueParent.ps1`: fixed PowerShell stderr capture — `2>$variable` does not capture stderr (it is a file-redirect operator); replaced with `2>&1` stream separation by ErrorRecord type so failure diagnostics are surfaced without corrupting JSON/GraphQL parsing on successful gh calls (#800, PR review).

## [3.3.6] — 2026-07-08

### Added

Add the outsider-first authoring convention plus a minimal, deterministic newcomer-audit detector (skills/naming-register-policy/scripts/newcomer-audit.ps1 + newcomer-audit-core.ps1) that flags undefined insider terms in new human-facing prose before it lands, closing umbrella #732's S1. Wired into Experience-Owner, Solution-Designer, and Issue-Planner draft-scan steps plus a warn-only lane in the PR-creation formatting gate. Detection without enforcement in v1 (no CI, no allowlist tooling) per settled scope.

## [3.3.5] — 2026-07-07

### Added

Add a Quality-first, shift-left governing-principle section to CLAUDE.md: quality ahead of speed/cost, catch defects as early in the pipeline as possible, and relax later review stages only on phase-containment escape-rate data (never a cost argument). Links the phase-containment ledger instrument and umbrella #761.

## [3.3.4] — 2026-07-07

### Fixed

- Fix plan-stress-test surface silently reporting sustained=0 blocks=0 (false-clean) by adding a machine-readable judge-rulings block emission contract to the plan-authoring writer and an honest could-not-verify fallback to the emission-check reader (#811).

## [3.3.3] — 2026-07-06

### Changed

- Retired the `product_alignment_prosecution` review mode; the design-challenge adapter's new `pass-lenses` key is now the sole source of pass identity, with no-fork Pester pins guarding the pairing (issue #797).

## [3.3.2] — 2026-07-05

### Fixed

- Fixed the invalid `gh issue view --paginate` flag (switched to `gh api --paginate --slurp` with array-flattening) plus a fetch-once refactor in the credit-input harvester (issue #794 Bug 1).
- Added automatic credit-input marker harvest inside the pipeline-metrics emit core, so `/orchestrate` PRs get complete cost credits with zero manual steps (issue #794).
- Fixed orchestrated-origin detection to resolve the PR head ref via `gh pr view` when `$env:GITHUB_HEAD_REF` is empty (issue #794 sub-observation 2).
- Added a typed degraded-telemetry reason and an auto-posted honest `cost-pattern-data` comment when cost walker telemetry is genuinely unavailable (issue #794 sub-observation 4 / AC6).
- Fixed nested-field YAML corruption in review credit rows by emitting scalar-safe fields only (issue #794 Bug 2).
- Corrected frame-credit-ledger SKILL.md gotcha to describe all three cost-pattern-presence-check.yml trigger arms instead of only the cost-reduction label (issue #794).
- Reconciled conductor-credit-emission.md to describe SMC-17 pipeline-entry credit harvest as running automatically inside the emit core rather than as a separate Code-Conductor-orchestrated step (issue #794).

## [3.3.1] — 2026-07-04

### Changed

- D9 Model-Switch Checkpoint cosmetic dewording: removed obsolete model-switch prompt wording from Code-Conductor's hub-mode checkpoint (model routing is automatic since #477); D9's name, pause, durable-handoff, and bundle-fan-out roles are unchanged (#483).

## [3.3.0] — 2026-07-04

### Added

- CE Gate evidence-type labeling: every delegated customer scenario is now labeled live-interaction, code-audit, or automated-runner so a maintainer is never misled about evidence strength (#791).
- Browser MCP tool grants (mcp__Claude_Preview__*, mcp__claude-in-chrome__*) added to Experience-Owner, UI-Iterator, and Code-Critic (read-only) Claude shells (#791).

## [3.2.0] — 2026-07-03

### Added

- Scope Classification Gate announces the pipeline tier (with a pre-dispatch standing override) when the rubric outcome is determined by evidence-backed criteria, and asks only when the outcome is genuinely indeterminate (#786). D9 Model-Switch Checkpoint cosmetic dewording (prompt wording only, not removal) is tracked separately in #483.

## [3.1.0] — 2026-07-03

### Added

- Re-tier the adversarial-review pipeline to the Claude 5 family: judge and generalist-B move to Fable, specialists stay Opus (#785).
- Add the design-challenge convergence-filter methodology to Solution-Designer Stage 3, replacing generic design-review lenses with three specialist lenses (#785).
- Add model/effort frontmatter to Experience-Owner, Solution-Designer, Issue-Planner, Research-Agent, and Specification shells (previously inherit) (#785).
- Extend the design-disposition schema to a fourth pass value for convergence-origin findings (#785).

## [3.0.1] — 2026-07-02

### Added

- Add phase-containment emission-check nudge to design-exploration, plan-authoring, and review-judgment skills; catalog the sweep script in calibration-pipeline (#782)

## [3.0.0] — 2026-07-02

### Changed

- **BREAKING: Coverage-first adversarial review prosecution** (#784): prosecution now reports every finding with a statable failure mode — including low-confidence/low-severity findings previously silently dropped — tagged with explicit confidence + severity. Importance/confidence filtering is relocated to the judge stage, which is now the filter of record; the judge's scoring bar is unchanged. `skills/adversarial-review/SKILL.md` §2/§4 and `agents/Code-Critic.agent.md` carry the rewritten methodology.
- **BREAKING: `lite` adversarial-review adapter gains defense + judge** (#784): `/orchestra:review-lite` now runs the full prosecution → defense → judge pipeline (atomic), a change from its previous prosecution-only contract that returned the raw prosecution ledger unchanged. Consumers relying on the old unfiltered-ledger return shape will see a judge verdict + score summary instead. `skills/adversarial-review/adapters/lite.md`, `skills/adversarial-review/platforms/claude.md`, and `commands/orchestra-review-lite.md` updated accordingly; `skills/solution-authoring/SKILL.md` removes `lite` from its prosecution-only adapter classification.
- Calibration `skills/calibration-pipeline/SKILL.md` documents a coverage-first epoch note: `sustain_rate` readings before/after this change are non-comparable; metric segmentation deferred to #761.

## [2.35.16] — 2026-06-30

### Fixed

- Widen BDD detection to scan AGENTS.md, CLAUDE.md, and copilot-instructions.md in priority order (first file with a column-0 `## BDD Framework` heading wins); previously detection was hardcoded to copilot-instructions.md (#776).

## [2.35.15] — 2026-06-30

### Added

- **Deliberate board positioning at issue creation** (#774): `safe-operations` §2b-ter adds a creation-time board-positioning decision (priority label + parent-or-standalone) with a lever-mapping table and positioning-residue format. §2b-bis gains a Triage cap-5 caveat; the lever table pins the correct `Get-PriorityKey` values (high=0, medium=1, low=2; unlabeled=3) matching `render-portfolio.ps1`.
  - Board-positioning directives wired into Code-Conductor filing sequences and CE Gate Track 2, Process-Review §4.8/§4.9, code-review-intake structural deferrals, and the Experience-Owner issue-creation step.
  - New contract test `safe-operations-2b-bis-contract.Tests.ps1` locks the §2b-bis/§2b-ter invariants including the numeric `Get-PriorityKey` mapping.
  - D5 compression: `## Pipeline Metrics` body extracted to `skills/calibration-pipeline/references/conductor-metrics-protocol.md`, bringing `Code-Conductor.agent.md` to 497 lines (<=500 cap).

## [2.35.14] — 2026-06-29

### Added

- **Reporting-economy directive across specialist bodies** (#471): canonical reporting-economy bullet added as the terminal `## Core Principles` bullet in all 11 dispatched specialist agent bodies (Code-Critic, Code-Review-Response, Code-Smith, Doc-Keeper, Process-Review, Refactor-Specialist, Research-Agent, Senior-Engineer, Specification, Test-Writer, UI-Iterator). Bans tool-call transcript echo (load-bearing for frozen Copilot path); caps free narration at ~150 words, subordinate to any role-mandated structured artifact, with a carve-out for fixed-form output (Step 0 / ND-2 / parity-locked literals). Parent override preserved.
  - **`reporting-economy.Tests.ps1`**: discovery-based Pester test (glob `agents/*.agent.md` minus 5 pinned exclusions = 11 in-scope); count guard (==11 in-scope, ==5 excluded); terminal-bullet anchor; `BeforeDiscovery` parameterization; reuses parity helpers `GetSectionBody` / `NormalizeContent`.
  - **`reporting-economy-spotcheck.ps1`**: behavioral spot-check analyzer; reads `attributionAgent` from each subagent's final-report assistant event at `{SlugDir}/subagents/agent-{id}.jsonl`; emits per-dispatch word count, echo-detected, and override-flag; explicit baseline-unavailable signal when no transcripts found.
  - **`reporting-economy-spotcheck.Tests.ps1`**: 19 Pester unit tests for the production parser (attributionAgent parsing, last-event selection, out-of-scope exclusion, word count across single and multi-block content, echo detection, override flag with false-positive guard, missing attributionAgent, ToolUseId derivation, baseline-unavailable, nested session-dir record collection). Tests dot-source the production `Get-SpotcheckRecord` / `Invoke-ReportingEconomySpotcheck` functions via `-ImportMode` and use the real subagent JSONL schema — in-process invocation per the #257 script-safety contract (no child-pwsh spawn).

## [2.35.13] — 2026-06-29

### Fixed

- **Cost telemetry v4 emission reliability** (#769): deterministic fail-loud v4 emission path wired end-to-end into Code-Conductor.
  - **`lib/Get-FCLOriginContext.ps1`**: new CI-safe orchestrated-origin predicate using `$env:GITHUB_HEAD_REF` (primary) and PR body linked-issue signals (fallback). Excludes detached-HEAD `HEAD` literal (M3 bug fix). Returns `IsOrchestratedOrigin`, `LinkedIssueNumber`, `DetectionMethod`.
  - **`emit-pipeline-metrics-v4.ps1`**: deterministic 3-case fail-loud emitter — builder-throw → `<!-- cost-capture-failed -->` sentinel; empty credits → sentinel; success → v4 block. Called before `gh pr create` in Code-Conductor's fresh-PR path; push-only path explicitly exempted. Non-zero exit on failure.
  - **`lib/Add-FCLCreditRow.ps1` / `lib/Get-FCLAccumulatedCredits.ps1`**: file-based credit accumulator at `.tmp/issue-{N}/fclcredits.jsonl`; harvest hook in emit script ensures credits are non-empty on orchestrated runs. Conductor body gains `Add-FCLCreditRow` call after each `Build-*CreditRow` step.
  - **`frame-credit-ledger.ps1`**: origin-gated 3-state taxonomy (`🛑 FAILED` / `not measured (non-orchestrated)` / `pre-v4`) at each short-circuit site; off-switch via `FCL_SUPPRESS_FAILED_POSTS` env var.
  - **`.github/workflows/cost-pattern-presence-check.yml`**: widened `if:` to include `startsWith(github.head_ref, 'feature/issue-')` head refs; step now checks PR body for `<!-- pipeline-metrics` instead of PR comments for `<!-- cost-pattern-data`.

## [2.35.12] — 2026-06-29

### Added

- **Phase-containment escape-rate ledger** (#762, review-efficacy sub-1): instrumentation that measures how far review-pipeline defects escape from the phase where they were catchable.
  - New schema `skills/calibration-pipeline/schemas/phase-containment.schema.json` — 10-field JSON Schema (draft-07) for `<!-- phase-containment-{ID} -->` YAML blocks.
  - New `.github/scripts/lib/phase-containment-core.ps1` — hand-rolled (powershell-yaml-free) parser/validator: `Get-PhaseContainmentBlock` (multi-block), `ConvertFrom-PhaseContainmentYaml`, `Test-PhaseContainmentEntry`, `Get-PhaseContainmentFindingKey`, `Get-PhaseContainmentEnumDriftStatus`.
  - New `.github/scripts/lib/phase-containment-rolling-history-core.ps1` — two-surface walk (issue + merged-PR comments), 1-hour two-sided cache, GraphQL→REST fallback, dedup-by-finding_key, and `Get-PhaseContainmentRollup` (InsufficientData / DenominatorZero / DataUntrustworthy guards, RelaxationEligible signal, leakage matrix).
  - New CLI `.github/scripts/phase-containment-report.ps1` — per-stage CE Gate report with INSUFFICIENT DATA / DATA UNTRUSTWORTHY / NOT ELIGIBLE / ELIGIBLE labels.
  - Wired phase-containment emission into `skills/design-exploration`, `skills/plan-authoring`, and `skills/review-judgment` with setter rules and detective-sample audit.
  - CE Gate verification `.github/scripts/Tests/Invoke-CEGate762.ps1` (AC3/AC4/AC8/AC12) plus Pester coverage in `phase-containment-core.Tests.ps1` (25) and `phase-containment-rolling-history-core.Tests.ps1` (24).

## [2.35.11] — 2026-06-28

### Added

- **Dispatch-prompt economy** (#472): added a dispatch-prompt economy rule to Code-Conductor Step 3 ("Execute Each Step") directing the conductor to reference the canonical plan source (`Read <!-- plan-issue-N --> step M for contract`) instead of re-inlining contract detail in specialist dispatch prompts; novel constraints not already in the plan/design always stay inline.
  - New design doc `Documents/Design/dispatch-prompt-economy.md` — rule placement, scope (C2.a delivered; C2.b prepared-payload and M1 telemetry-proof deferred), and a before/after lean dispatch example.
  - New `skills/parallel-execution/references/lean-dispatch-example.md` — canonical lean before/after dispatch example, indexed in the skill's Composite References.

## [2.35.10] — 2026-06-28

### Added

Add ## Grounding Discipline section to skills/design-exploration/SKILL.md — four-quadrant pre-challenge artifact trace gate (Q1 output->consumer, Q2 input->exec-env, Q3 current-behavior, Q4 premise-citation) with timing split, disposition enum, **Grounding Evidence** block, and 60 KB guard. Wire **grounding gate** forcing-function into agents/Solution-Designer.agent.md between Stage 2 and Stage 3. Add 5th Issue-Planner-lens backstop row to skills/upstream-onboarding/SKILL.md. Add Pester structural test design-grounding-discipline.Tests.ps1 (14 tests). Closes #763.

## [2.35.9] — 2026-06-28

### Added

- **De-opaque living reader surfaces** (#750): applied #732 two-register naming policy to always-on entry points.
  - Replaced "Value Reflex" with "worth-it check" at 3 prose locations (CLAUDE.md, HOW-IT-WORKS.md §2/§4); vocab-seed block and `## Value Reflex (First Beat)` heading in experience-owner.md preserved.
  - Added stable `<a id="vocab"></a>` anchor in HOW-IT-WORKS.md §5 (renumber-safe; survives #696 ToC sweep). Added `<!-- vocab-pointer -->` escape-hatch footer on 9 living surfaces: CLAUDE.md, skills/README.md, CUSTOMIZATION.md, 6 Documents/Design orientation docs.
  - Added first-use inline expansions in CLAUDE.md: SMC-01 → "SMC-01 (Session Memory Contract marker)"; CE Gate → "CE Gate (Customer Experience Gate)".
  - Created minimal `.github/ISSUE_TEMPLATE/bug_report.md`, `.github/ISSUE_TEMPLATE/feature_request.md`, and `.github/PULL_REQUEST_TEMPLATE.md` — bare-structure templates each carrying the vocab-pointer footer.
  - Fixed `skills/README.md`: count 47 → 53; added 6 missing rows (ai-first-documentation, engagement-record-emission, naming-register-policy, persist-changes, project-references, solution-authoring) using existing `description:` frontmatter verbatim.
  - New bounded Pester guard `.github/scripts/Tests/NamingRegisterLivingSurface.Tests.ps1`: term-absence (with vocab-seed block exclusion), pointer-presence, anchor-uniqueness, file-existence assertions over the enumerated in-scope surface set.

## [2.35.8] — 2026-06-27

### Changed

- **Control Tower v2 documentation + intake rule** (#753, s7): documented the ranked-umbrella portfolio board that shipped in #756. The board's zones changed from the v1 "Now / Next / Blocked / Recently closed / Triage" lane model to **🎯 Active** (first open umbrella, expanded) / **Umbrellas (ranked)** / **🔥 Triage** (derived) / **Recently closed**.
  - New design doc `Documents/Design/control-tower-v2.md` — schema_version 2 spec, three-zone derivation, drift/integrity warn tiers, idempotent splice, and the #746 connection-cap dependency.
  - `skills/safe-operations/SKILL.md` §2b-bis rewritten for v2: new umbrellas must be inserted into `Documents/Planning/sequence.yaml`'s `umbrellas:` list at the correct rank (canonical home, no routing-tables entry); Triage is now **auto-derived** from parent-edge data, so `--label triage` is optional/advisory rather than load-bearing.
  - `skills/post-pr-review/SKILL.md` cross-reference to the new design doc.

## [2.35.7] — 2026-06-27

### Added

Add skills/naming-register-policy/ — two-register naming policy skill, 48-entry vocab-seed register, Pester test suite with CI wiring (issue #732)

## [2.35.6] — 2026-06-26

### Added

- **HOW-IT-WORKS.md orientation doc** (#749): new plain-language orientation document at the repo root. Five sections: what Agent Orchestra is, the work pipeline (board to merged PR), how to read an issue/PR, optional depth (`<details>` blocks), and a 48-row vocabulary table (seeds the #732 naming/register policy via the `<!-- vocab-seed:begin/end -->` anchor). README pointer added after deprecation banner. `.markdownlint.json` now allows `<details>` and `<summary>` HTML elements (MD033).

## [2.35.5] — 2026-06-26

### Fixed

- **BDD enablement detection now requires a `^## BDD Framework` line-start heading (column 0)** (#733): replaced substring/presence phrasing across 13 agent-and-skill detection sites in `agents/Experience-Owner.agent.md`, `agents/Issue-Planner.agent.md`, `agents/Test-Writer.agent.md`, `skills/bdd-scenarios/SKILL.md`, and `skills/customer-experience/references/orchestration-protocol.md`; anchored 12 detection references in `Documents/Design/bdd-framework.md`. Added **Discriminator** note with `grep -nE '^## BDD Framework'` oracle. The hub's own `copilot-instructions.md:33` backtick mention no longer produces a false positive under anchored detection.

## [2.35.4] — 2026-06-26

### Fixed

- **Canonical pipeline-metrics v4 emission from Code-Conductor inline PR creation** (#739): fixes the integration seam where `Build-*CreditRow` outputs (`[pscustomobject]`) were rejected by `New-PipelineMetricsV4Block` (declared `[hashtable[]]`), breaking the entire v4 emission path and short-circuiting the frame credit ledger to the pre-v4 path. Additional fixes: `Escape-FCLScalar` now uses YAML `""` escaping (not `\"`), both `Get-FCLScalar` and `ConvertFrom-FCLListSection` unescape `""` → `"` on read-back (round-trip losslessness AC1), `Test-PipelineMetricsV4Block` stripped of repair-loop logic (pure warn-only per #429), v3-base `-->` injection escaping, guard regex anchored.
- **Atomic CHANGELOG insertion in `bump-version.ps1`** (#739 s5): extracted `Invoke-ChangelogInsertion` into `changelog-insert-core.ps1` (idempotency check, separator-agnostic anchor, read-back verify, no file I/O); `bump-version.ps1` now wires `-ChangelogEntry`/`-ChangelogSection` parameters with verify-before-write guard.

## [2.35.3] — 2026-06-26

### Added

- **File-granular parallel sharded Pester runner** (#740): new `.github/scripts/run-pester-sharded.ps1` thin wrapper + `.github/scripts/lib/pester-sharded-core.ps1` logic library (per the #257 lib+thin-wrapper convention). Discovers all `.Tests.ps1` files, splits a parallel shard (`ForEach-Object -Parallel -ThrottleLimit 8`) from a sequential real-git shard (`plugin-release-hygiene`, `session-cleanup-detector` — keyed on actual `git init`/`git commit` fixture behavior, not string grep), and enforces a no-false-GREEN contract: a missing result file (crashed worker) **or** a file that discovers zero tests is a hard failure with non-zero exit. Includes a `-DeterminismCheck` mode that runs the suite twice and fails on any per-file pass/fail flip. The real-git shard pins a temp `GIT_CONFIG_GLOBAL` (user identity + `commit.gpgsign=false` + `init.defaultBranch=main`) without pre-setting `GIT_TERMINAL_PROMPT`/`GCM_INTERACTIVE`/`GIT_ASKPASS` (those stay owned by the scripts under test).
- **Pester suite performance audit** (`Documents/Design/pester-suite-performance-audit.md`): per-It timing profile of the top-3 slowest files, full spawn-form inventory with CONVERTIBLE/IRREDUCIBLE verdicts, and the CE Gate result with theoretical-floor analysis.

### Changed

- **Per-test `pwsh` spawns converted to in-process dot-source** (#740): 20 content `It` blocks in `frame-credit-ledger-orchestrator.Tests.ps1` (321s → 70s) and 8 in `cost-integration.Tests.ps1` (98.6s → 7.7s) now dot-source the orchestrator and stub `git`/`gh` in-process instead of spawning a child process per test. Exit-code-contract and timing-contract Its are preserved as a real-spawn smoke layer. Full suite wall-clock: ~836s → 238s (3.5× speedup); the ≤120s target remains gated by an irreducible ~124s floor (see audit doc).
- **Spawn guard upgraded to AST scan** (`script-safety-contract.Tests.ps1`): replaced the `& pwsh` string-grep with a `[Parser]::ParseFile()` + `CommandAst` scan that detects both `& pwsh`/`& powershell` and `Start-Process -FilePath 'pwsh'` forms without false-positives on string literals; added two falsifiability Its and expanded the IRREDUCIBLE allowlist (same-commit atomic with the scan change).

### Fixed

- **Pre-existing `composite-skill-structure` red** (#740): trimmed `skills/code-review-intake/SKILL.md` from 88 to 79 lines to satisfy the ≤80-line composite-skill contract, with no information loss (covered by retained body sections).

## [2.35.2] — 2026-06-26

### Changed

- **CLAUDE.md diet — extracted four blocks to their owning sources** (#694): trimmed `CLAUDE.md` from ~270 to 189 lines (below the <190 target and the <200 A2 audit budget) by moving four duplicated content blocks to their canonical homes without information loss — the cross-tool handoff marker catalog → new `skills/session-memory-contract/references/handoff-markers.md` (13 active + 1 retired families); the deferrable Intent Routing mechanics (rules 1,2,3,5,9,10) → `skills/routing-tables/SKILL.md § Intent Routing Mechanics`; the auto-mode boundary verification recipe → `skills/session-startup/SKILL.md` (sentinel-wrapped); and the full per-agent model + reasoning routing table → `Documents/Design/agent-body-architecture.md`. The four CLAUDE.md keep-set routing rules (4, 6, 7, 8) and all four section stubs with resolving pointers remain.

### Fixed

- **Per-agent routing parity claim and moved-recipe link drift** (#694 adversarial review CR1/CR2/CR4): struck the now-false "routing-table parity" enforcement claim from `agent-body-architecture.md` and added the authoritative-source-is-frontmatter note; repaired two dead relative links in the relocated auto-mode recipe (`skills/session-startup/SKILL.md`) and hardened `auto-mode-boundary.Tests.ps1` test 7 to resolve recipe links against the recipe file's own directory instead of the repo root; updated a stale `.DESCRIPTION` docstring in `per-agent-model-routing.Tests.ps1`.
- **Gemini Code Assist review** (#694 PR #738): case-insensitive `-replace` for repo-root stripping in `per-agent-model-routing.Tests.ps1`, `@(Get-Content)` array-wrap for the diet line count, and a `#when-to-skip` anchor on the upstream-onboarding recipe link.

### Tests

- New `claudemd-diet.Tests.ps1` (5 tests): the <200-line diet guard plus pointer-resolution sentinels for all four extraction destinations. `per-agent-model-routing.Tests.ps1`, `auto-mode-boundary.Tests.ps1`, and `orchestra-spine-command.Tests.ps1` pivoted to read the relocated content from its new homes; `audit-docs-mechanical.Tests.ps1` AC9 flipped to assert the hub `CLAUDE.md` now passes the A2 budget check. Added a `.github/prompts/*.prompt.md` entry to `Documents/Design/hub-artifact-paths-classification.yml` — the Intent Routing extraction surfaced that Copilot-prompt path family into a scanned scope (`skills/*/SKILL.md`), which the hub-artifact-paths coverage gate requires classified.

## [2.35.1] — 2026-06-26

### Added

- **Ledger-vs-Validation Boundary guardrail** (`skills/code-review-intake/SKILL.md`, `Documents/Design/code-review.md`): a normative `### Ledger-vs-Validation Boundary` section plus a Gotchas row establishing that GitHub review ingestion and ledger-building (steps 1–2) are strictly mechanical — the conductor records each ingested finding verbatim and maps it to its comment/review ID, and MUST NOT accept, reject, or form any per-finding correctness verdict before proxy prosecution runs. Per-finding validation is the proxy prosecution pass's responsibility (step 3); the sole pre-prosecution conductor-side correctness call permitted is `NEW-CRITICAL` for a newly discovered blocker, not an ingested finding. Protects adversarial independence: the conductor also owns the ledger build, accepted-fix dispatch (R4), and judge dispatch, so a correctness opinion formed during ingestion would bias those downstream steps (#735).

## [2.35.0] — 2026-06-24

### Fixed

- **Full Pester suite restored to clean green** (#723; absorbs #566 local-Windows triage): 26 pre-existing failures across ~17 subsystems root-caused and fixed. Highlights: a real regression in `skills/session-startup/scripts/post-merge-cleanup.ps1` (#727 hoisted `Resolve-Path` out of a loop, crashing `-IssueNumber` runs from any tree lacking `.copilot-tracking/`) is guarded; `frame-audit-report-core.ps1` `Get-FARBucketForCreditStatus` now warn-skips unknown live credit statuses (→ `inconclusive`) instead of throwing on `harvested-from-issue`; the `aggregate-review-scores` skip→full test no longer depends on wall-clock time (relative within-window date + `re_activated: false` assertion proving the sustain-rate path + non-vacuous clear assertion). Stale contract/parity/wording tests reconciled to match intentionally-shipped features (#439/#500/#574/#591/#620/#625/#632/#663/#706/#627) — fixed test-side only, bodies never reverted.
- **Restored S4 framing sentence lost in #632's DRY consolidation** (`skills/adversarial-review/platforms/claude.md`): the working-tree-mutation ND-2 recovery framing was dropped from the command sites without being carried into the consolidated checklist.
- **PR #731 review findings** (proxy prosecution → defense → judge): fixed a vacuous `else`-branch assertion in the `aggregate-review-scores` leave-skip writeback test (production takes the key-removal path, so the old assertion re-asserted the branch condition — now a raw-JSON check on the written calibration file, AC4); hyphenated the `Code-Conductor` handoff prose in `agents/Code-Conductor.agent.md` + `skills/session-memory-contract/references/conductor-session-handoff.md` to kill source/extract drift (SCR2); and fixed an `exercise/N-A` → `exercise/N/A` typo (SCR1).

### Added

- **Wall-clock fixture guard** (`.github/scripts/Tests/wall-clock-fixture-guard.Tests.ps1`, registered in `.github/workflows/pester.yml`): a static guard that fails when a band-asserting fixture assigns an absolute ISO-date literal to the now-coupled `skip_first_observed_at` field (line-level `# absolute on purpose` exemption), with a falsifiability self-test and a core-drift check. Makes wall-clock independence a checked CI invariant (#723). The detection regex covers both single- and double-quoted ISO literals (PR #731 GCR3, AC3).

### Changed

- **Size-lint splits via composite-skill extraction** (not threshold bumps): `agents/Code-Conductor.agent.md` 588→499 lines (verbose sub-content extracted under 21 preserved H2 headings into 5 reference files; all shell-parity + contract-asserted text preserved), `skills/customer-experience/SKILL.md` rebalanced to ≤80 lines after the #729 Value Reflex merge by extracting the Value Reflex outcome contract and the Hub/Consumer Classification Gate into new reference files, `skills/code-review-intake/SKILL.md` 93→78 (#723).

## [2.34.0] — 2026-06-24

### Added

- **Advisory Value Reflex — worth-it check as the first beat of `/experience`** (`skills/customer-experience/SKILL.md`, `agents/Experience-Owner.agent.md`, `CLAUDE.md`): an optional, skippable check that runs once per issue before framing begins. Three prompts (Bet / Falsifier / Alternative) with no numeric score produce an advisory recommendation from five outcomes — `Proceed-full`, `Proceed-lite`, `Shrink`, `Park`, `Decline`. Advisory only: the owner decides and may proceed regardless. An accepted `Park` or `Decline` is recorded as a `worth-it-{ISSUE}` entry in the `engagement-record-experience-{ISSUE}` burst and applies a `status: parked` or `status: declined` label; `same-decision-resume` suppresses re-prompting on re-entry. `Proceed-*`/`Shrink` outcomes are not recorded. Say `frame it` to skip (#729).

### Tests

- 12 Pester structural and constant-validation `It` blocks (`.github/scripts/Tests/value-reflex.Tests.ps1`) locking the invariants: exactly three numbered prompts, the `frame it` skip affordance, the no-numeric-score guard, first-beat ordering (item 0 before item 1), the five-outcome enum, the `worth-it-{ISSUE}` recording reference, the `status: parked`/`status: declined` label-apply plus halt wiring, the `Test-EngagementRecordSlug` slug-regex contract, and the `experience` phase-enum membership (#729).

### Fixed

- **Version drift across version-bearing files** (`plugin.json`, `.claude-plugin/marketplace.json`, `.github/plugin/marketplace.json`, `README.md`): a prior release advanced only `.claude-plugin/plugin.json` to 2.33.1 while the other manifests and the README badge lagged at 2.33.0/2.32.0. This bump reconciles all seven occurrences across five files to 2.34.0 (#729).

## [2.33.1] — 2026-06-23

### Fixed

- **Session-cleanup false-positive on live persistent tracking files** (`skills/session-startup/scripts/session-startup-git-helpers.ps1`, `skills/session-startup/scripts/session-cleanup-detector-core.ps1`, `skills/session-startup/scripts/post-merge-cleanup.ps1`): root-level `.copilot-tracking/` artifacts with no `issue_id` frontmatter — `gate-events.jsonl`, `references-state.yml`, `references-init.manifest` — were flagged as stale untagged tracking files and archived by the cleanup executor. A new dual-axis exclusion registry (`Get-SCDPersistentTrackingExclusions` returning `Subtrees` + `Filenames`) is the single source of truth consumed by both detector and executor. The detector excludes registered filenames matched root-anchored at depth 0 (a registry-named file at depth ≥ 1 is still flagged); both executor archival routes skip registered files with a warning. Both consumers fail loudly (HALT + exit 1) before any `Move-Item` when the accessor is undefined or returns `$null`/missing `Filenames` — never fail-open toward deletion (#656).

### Tests

- 11 new Pester `It` blocks across two harnesses covering AC1–AC7: per-seed-file exclusion, positive companion (non-registry untagged file still flagged), over-exclusion depth guard, undefined-accessor hard-halt for both detector and executor, writer-oracle parity, and both executor-route skips (#656).

## [2.33.0] — 2026-06-22

### Added

- **Deferral discipline — ARM 2 behavioral-term AC cross-check** (`skills/review-judgment/scripts/Get-AcTermsFromIssue.ps1`, `skills/review-judgment/scripts/Test-DeferralCriteria.ps1`): a second AC cross-check arm that extracts behavioral-term identifiers from the issue's `## Acceptance Criteria` section and matches them against finding text. Behavioral terms (containing must/shall/gate/guard/etc.) route to `force-accept`; non-behavioral terms route to `disposition-gate`; no-match routes to `defer`. Confidence-tiered routing populates an `ac_cross_check` OUT object on every verdict path. Backward-compatible: `-AcTerms = @()` default leaves all existing callers unchanged (#709).

- **Blocking pre-condition and loud guard** (`skills/review-judgment/SKILL.md`): no `dismiss`/`defer` entry at severity ≥ medium may be committed without a populated `ac_cross_check`. When `routed: defer` is the result, the loud guard mandates an inline note + a sub-issue created via `Add-FollowUpIssue -AcCrossCheck` carrying AC provenance YAML (#709).

- **`schema_version: 2` per-entry fields** (`skills/solution-authoring/schemas/review-dispositions.schema.json`): adds `severity`, `stage`, and `ac_cross_check` per entry. v1 legacy entries are exempt from the `ac_cross_check` presence check. CE Gate deferrals use `stage: ce` (#709).

- **`Add-FollowUpIssue -AcCrossCheck` parameter** (`skills/safe-operations/scripts/Add-FollowUpIssue.ps1`): optional M16 guard that appends AC provenance as a YAML block to the sub-issue body. String scalars are double-quoted so colon-bearing `ac_ref` values produce valid YAML (#709).

- **ARM 2 integration in agent bodies** (`agents/Code-Conductor.agent.md`, `agents/Code-Review-Response.agent.md`, `skills/code-review-intake/SKILL.md`): `Get-AcTermsFromIssue` is called alongside `Get-AcRefsFromIssue` at the AC pre-population step; `-AcTerms` is passed to `Get-StructuralVerdict` (#709).

### Fixed

- `disposition: defer` was absent from the `review-dispositions` schema enum and validator accept-list despite being written by SKILL.md's loud-guard path (#709/F1).
- Phantom `minor` severity tier removed from schema and validator threshold; all prose updated from "≥ minor" to "≥ medium" to match the canonical producer enum in `routing-config.json` (#709/F2).

### Tests

- 27-test suite for `Get-AcTermsFromIssue` covering constants, extraction, behavioral detection, stop-list, H2 boundary, dedup, and failure paths.
- 18-test suite for `Test-DeferralCriteria` covering ARM 1+2 routing, backward compat, and `ac_cross_check` population.
- 25-test integration suite for the full deferral path including F5 YAML-quoting regression and F7 integrated `routed: defer` → mandatory sub-issue call (#709).

## [2.32.0] — 2026-06-21

### Changed

- **Five-pass two-layer prosecution panel for the `standard` adversarial-review adapter** (`skills/adversarial-review/platforms/claude.md`, `skills/adversarial-review/adapters/standard.md`, `skills/adversarial-review/SKILL.md`, `agents/Code-Critic.agent.md`): replaces the homogeneous 3× Opus prosecution with a diverse panel — `generalist-A` (Sonnet), `generalist-B` (Opus), and three Opus specialists (`spec-correctness`, `spec-security`, `spec-architecture`). Cross-layer dedup merges on failure-mode + code-location and prefers the deepest-tier finding (Opus over Sonnet); the panel survives iff ≥1 generalist **and** ≥1 specialist clear quorum after per-pass retries. PR-phase prosecution-pass enums widen `[1,2,3]` → `[1,2,3,4,5]` across the schema, validator, routing-config, metrics schemas, and supporting prose; the design-phase `design-disposition-audit` `[1,2,3]` invariant is unchanged. Adds an optional `model:` field to `dispatch-cost-samples[]`, wired end-to-end (parser positional contract, RC back-fill preservation, merge dedup key, round-trip tests). Also folds in the inline doc corrections that AC4's surface sweep promised (`Documents/Design/frame-architecture.md`, `skills/review-judgment/SKILL.md`, `skills/calibration-pipeline/references/metrics-schema.md`) and a quorum "well-formed ledger" definition clarification (#706, with inline fixes for #714/#716/#717/#718).

## [2.31.0] — 2026-06-21

### Added

- **CI release gate** (`.github/scripts/lib/release-gate-core.ps1`, `.github/scripts/release-gate.ps1`, `.github/workflows/release-gate.yml`): A required PR check that fails any PR touching plugin entry points (`agents/**`, `commands/**`, `skills/**`, `hooks/**`, `.claude-plugin/**`, `plugin.json`, `README.md`, `.github/copilot-instructions.md`) without a monotonic version bump **and** a matching `## [version]` CHANGELOG section. Leg-scoped `Skip-Release-Check:` commit-trailer waiver: `changelog-only` waives only the CHANGELOG leg; `all <reason>` waives both. Fail-closed on any base-ref/diff error (AC5). Entry-point membership delegated to `Get-FVPluginEntryPointPatterns`; parity enforced by `.github/scripts/Tests/entry-point-scope-parity.Tests.ps1` (#703).

## [2.30.0] — 2026-06-12

### Added

- **Derived portfolio tracker** (`Documents/Planning/sequence.yaml`, `.github/scripts/render-portfolio.ps1`, `.github/scripts/Tests/render-portfolio.Tests.ps1`, `.github/workflows/render-portfolio.yml`): a merge-triggered control-tower renderer that derives a five-bucket portfolio (Now / Next / Blocked / Recently closed / Triage) from a truly-flat sequence spec and the live GitHub issue graph (`blockedBy` dependencies), then idempotently splices it into the control-tower issue body. Includes the `render-portfolio.yml` push/`workflow_dispatch` workflow (SHA-pinned checkout, `persist-credentials: false`, `gh`-only auth), a 20-test Pester suite registered in the CI gate, and three skill touchpoints — `safe-operations` §2b-bis umbrella/triage intake, `post-pr-review` §7 auto-render note, and `session-startup` Step 7c portfolio snapshot (#692).

### Changed

- Version bumped to 2.30.0 (2.29.0 was concurrently claimed by #708's ai-first-documentation consumer-mode release; this entry resolves the collision).

## [2.29.0] — 2026-06-12

### Added

- **`/audit-docs` command and mechanical-check script** (`commands/audit-docs.md`, `skills/ai-first-documentation/scripts/audit-docs-mechanical.ps1`, `skills/ai-first-documentation/templates/CLAUDE.md-starter.md`): Consumer-mode enablement for the `ai-first-documentation` skill. The `/audit-docs` command runs deterministic mechanical checks (A2, B2, B3, B5, A9) against any consumer repository with explicit `-Root`, emits JSON results, and supports a waiver convention via `.claude/documentation-decisions.md`. An `init` action bootstraps a minimal CLAUDE.md starter template. Includes a routing row (`intent_key: audit-docs`, audit-anchored patterns) and collision fixtures. SKILL.md updated with `## Consumer-Mode Audits` and `## Recording Documentation Decisions` sections including the H3-per-record decision-record format and CI acquisition guidance (#699).

## [2.28.0] — 2026-06-12

### Added

- **Plan-authoring Grounding Pass** (`skills/plan-authoring/SKILL.md`): a new `### 4. Grounding Pass` discipline in the Discovery Workflow that establishes the invariant "no plan step may name an ungrounded artifact." Before drafting, the planner verifies that every artifact a plan step names (file names, paths, exported symbols, shapes, counts) actually exists in the tree and corrects or updates the issue when it does not. Adds a `#591` migration-scan carve-out, a `#467` per-port observation note, a Research Subagent contradiction-reporting directive, a factual-correction exemption in the Alignment Workflow (factual corrections are not "material scope changes" that trigger loop-back), and a reciprocal cross-reference with the post-draft Tree-State Verification Discipline. Locked by the RED assertion-existence contract `.github/scripts/Tests/plan-authoring-grounding-pass.Tests.ps1` (#473).
- **Issue drift scan on pickup** (`skills/upstream-onboarding/scripts/get-issue-drift-core.ps1`, `skills/upstream-onboarding/scripts/get-issue-drift.ps1`): deterministic PowerShell library + wrapper that scans merged PRs since an issue was created and returns path-matched candidates as JSON. Age-gated at 7 days (bypassed with `-Force`); DI-injectable via `-IssueJsonOverride`/`-PrListJsonOverride` for Pester testing without live `gh` calls. Three output shapes: `{skipped:"below-threshold"}`, `{error:"..."}`, and full result with ranked `candidates[]`. Handles `.files[].path` object arrays, per-PR `files_truncated`, 200-row truncation detection, `ExcludePaths` filtering, cap + `more_count`, and intersection-none fallback (#683).
- **Pester coverage for drift scan** (`.github/scripts/Tests/get-issue-drift.Tests.ps1`): 20 tests covering age-gate boundary, date boundary, offset robustness, 200-row truncation, `#591`-shaped token extraction, `ExcludePaths` override and default, cap + `more_count`, all three output shapes, intersection:none, `files_truncated`, guarded numeric parsing, and case-insensitive path matching (#683).

### Changed

- **`upstream-onboarding` drift section** (`skills/upstream-onboarding/SKILL.md`): new `### Changed since this issue was filed` conditional section surfaces the drift script output as a ranked candidate list (format: `#N — title (touches: paths)`) with count-only fallback when intersection is none, truncation note, and ephemerality rule. On-Demand Expand extended with "what changed"/"what's changed"/"what happened since" trigger phrases and error surfacing. Resume Variant narrow exception documents that the drift section may appear on same-agent resume. Third affordance-hint predicate added for drift threshold (#683).
- **Claude Code platform notes** (`skills/upstream-onboarding/platforms/claude.md`): `## Drift scan — script path resolution` section documents the D1 plugin-cache-priority path-resolution sequence (repo clone first, then plugin-cache `installPath` lookup, then emit `couldn't check: script not found`) (#683).
- **Copilot platform notes** (`skills/upstream-onboarding/platforms/copilot.md`): equivalent drift scan path-resolution section for VS Code plugin-cache (#683).

## [2.27.0] — 2026-06-11

### Added

- **`ai-first-documentation` skill** (`skills/ai-first-documentation/`): research-backed documentation standards skill for authoring docs optimized for AI-agent consumption (#686).

## [2.26.0] — 2026-06-10

### Added

- **Git-portable `persist-changes` skill** (`skills/persist-changes/SKILL.md`, `skills/persist-changes/scripts/Resolve-PersistDecision.ps1`): caller-parameterized commit+push primitive with a side-effect-free decision helper (`Resolve-PersistDecision`) and Pester coverage. Stages only caller-supplied fix files (never `git add -A`), runs format-before-commit, commits, and conditionally pushes with guards for detached HEAD, dynamic default-branch resolution, commit-policy opt-out, fork/no-write, and non-fast-forward. Returns commit/push outcomes with explicit not-pushed reasons (#679).
- **`/review-github` response-loop completion** (`skills/code-review-intake/SKILL.md`, `commands/review-github.md`): a bare `/review-github` now closes the full loop — after judgment and routing, accepted fixes are implemented, post-fix prosecution and CE Gate run, then `persist-changes` fires as the terminal step to commit and push to the existing PR branch (or surface a loud not-pushed reason). The Response Summary commit/push/reporting contract is single-sourced in `skills/validation-methodology/references/review-reconciliation.md § Response Commit & Push` (#679).

## [2.25.2] — 2026-06-09

### Changed

- **Fat-skills consolidation for the `implement-code` port** (`skills/implementation-discipline/SKILL.md`, `skills/implementation-discipline/adapters/implement-code-adapter.md`): migrated three adapter-only behaviors (scope-discipline standard, `scope-violation` halt trigger, `simplicity-violation` halt trigger) from the adapter into the skill, then slimmed `implement-code-adapter.md` from 123 to 52 lines into a thin port-binding that names the skill as execution authority. The Halt-Return shape and reason enum stay single-sourced in `agents/Senior-Engineer.agent.md § Halt-Return Contract`. Code-Smith reads only the skill (design D0), so the port-specific triggers must live there. Code-Smith `## Core Principles` annotated as intentional persona voice pending shell retirement (#669, capstone #671, umbrella #662).

## [2.25.0] — 2026-06-07

### Added

- **Work adapters for `implement-test` and `implement-docs` frame ports** (`skills/test-driven-development/adapters/implement-test-adapter.md`, `skills/documentation-finalization/adapters/implement-docs-adapter.md`): thin Senior-Engineer work adapters enabling `/spine-run` to execute test-authoring and documentation slices end-to-end without requiring specialist-agent dispatch (#612).
- **Fat-skills extraction for documentation maintenance** (`skills/documentation-finalization/SKILL.md`): Documentation Maintenance Responsibilities methodology (CHANGELOG/NEXT-STEPS/QUICK-START/ROADMAP/Documents/Decisions with before-merge timing semantics) moved from `agents/Doc-Keeper.agent.md` body into the skill as the single source of truth (#612). Agent body now holds a heading-preserving pointer; bijection contract preserved.

## [2.24.0] — 2026-06-06

### Changed

- GitHub Copilot / VS Code support frozen as of this release — present but unmaintained, retiring after 2026-08-31. Claude Code is the only actively supported platform.
- Added internal deprecation banners to README.md, CLAUDE.md, and `.github/copilot-instructions.md`.
- Added `Documents/Design/copilot-deprecation.md` with the full freeze policy, reach-out channel (GitHub Discussions), and reversibility notes.
- De-obligated cross-platform Pester test assertions so new Claude-only work no longer requires Copilot counterparts.
- Bumped the orchestration tier from `sonnet + medium` to `sonnet + high` for `/orchestrate`, `/code-conductor`, `/review-github`, and `agents/code-conductor.md` — orchestration and review-reconciliation benefit from extended reasoning on the cost-efficient Sonnet tier. The adversarial review pass is unchanged (Code-Critic/Code-Review-Response remain on opus).

## [2.21.1] — 2026-05-31

### Changed

- **CE Gate read-gate re-point** (`skills/customer-experience/SKILL.md`): the orchestration-phase engagement-record dual-surface read gate now references `#571` instead of `#578` (`gated on #571. Until #571 merges`), aligning the skill with the umbrella that owns CE Gate dual-surface read enablement (#578).

### Added

- **Cognitive-surrender-prevention exercise procedure** (`Documents/Design/cognitive-surrender-prevention-exercise.md`): new maintainer verification procedure proving the cognitive-surrender prevention machinery (S2/S4/S5/S6) holds across sessions using falsifiable, durable evidence (#578).

### Note

- Patch bump invalidates the Claude Code plugin cache so consumers on 2.21.0 pick up the `customer-experience` skill edit (entry-point file change per release-hygiene).

## [2.21.0] — 2026-05-29

### Added

- **Resume-variant orientation snapshot** (`skills/upstream-onboarding/SKILL.md` `### Resume Variant`): a terse ~4-6 line inline snapshot renders on same-agent resume instead of the standards check (the full brief already skips on same-agent resume), assembled from already-loaded context (durable phase markers + engagement-record decisions). Cuts the flow-break of opening GitHub at pickup/resume (#633).
- **Code-Conductor smart-resume render** (`agents/Code-Conductor.agent.md` `### Hub Mode & Smart Resume`): the conductor independently authors and renders the resume-variant snapshot on marker detection before continuing (experience-complete / design-complete / plan-found paths), without delegating to the skipped upstream agent.
- **On-demand expand (D4)**: typing "expand" or "full picture" triggers a richer in-turn context summary; not registered in `nl_intent_routing`; not suppressed by `/raw`.
- **Affordance-hint predicate (D5)**: a one-line expand hint appears only when ≥1 prior engagement-record decision exists on the issue.
- **Missing-record fallback**: when no engagement-record exists on a real issue, the last-decision field renders exactly `last decision: not recorded` (never blank or fabricated).
- **Structural Pester guard** (`.github/scripts/Tests/upstream-onboarding-resume-variant.Tests.ps1`): locks the resume-variant contract at both render sites (SKILL.md and Code-Conductor.agent.md) including the standards-check-not-re-fired regression guard.

## [2.20.0] — 2026-05-27

### Added

- **cognitive-surrender-prevention v1.3** ([#577](https://github.com/Grimblaz/Copilot-Orchestra/issues/577)) — Code-Conductor's `scope-classification` decision now preserves across sessions via a new `phase: orchestration` engagement-record marker class.
  - **Schema bump**: `engagement-record-emission` `schema_version` 2 → 3; `phase` enum extends with `orchestration`. Readers built against v2 throw on unknown `schema_version` (out-of-try hard reject), and v3 markers carrying `phase: orchestration` require `schema_version >= 3` (in-try guard, warn-and-skip per CF13b cross-phase isolation).
  - **Touchpoint narrowing**: `D9-checkpoint` is dropped from Code-Conductor's solution-authoring touchpoint set after classification re-audit (P3.F2 in /design); the touchpoint set is now `scope-classification` only.
  - **Marker mirror policy**: the Markdown mirror is co-located inside the `<!-- engagement-record-orchestration-{ID} -->` comment (NOT in the issue body). CE Gate evaluator scope is widened to read both surfaces — issue-body `## Named Decisions` for upstream phases, comment-mirror for orchestration. Evaluator-side widening is staged behavior (becomes live with #578).
  - **Cross-file constants extended**: `frame-credit-ledger-core.ps1` (`$script:PipelineEntryPorts` / `$script:CompletionMarkerByPort` / `$script:BuilderByPort`), `cost-attribution.ps1` (two literals), `cost-pattern-renderer.ps1`, and `session-memory-contract` SMC-17 / SMC-20 rows all updated to include the new `orchestration` port.
  - **Plugin version bump**: 2.19.0 → 2.20.0 via `bump-version.ps1`, in lockstep with the schema cut to invalidate cached v2-era readers downstream.

> **Audit note (v2.20.0 release-hygiene)**: The Copilot-side files (`plugin.json` at repo root, `.github/plugin/marketplace.json`) jumped 2.18.0 → 2.20.0 in this release, skipping the 2.19.0 entry. The prior 2.19.0 release (#576/#627) bumped only Claude-side files (`.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json`, README badge). The v2.20.0 `bump-version.ps1` invocation reconciles all 7 occurrences across all 5 files. Consumers reading Copilot manifests between releases 2.18.0 and 2.20.0 saw a stale 2.18.0 version. Future bumps should verify all 5 files agree via `bump-version.ps1 -CheckOnly` per ADR-0002 dual-write doctrine. Tracked as review P1.F4 / P2.F17.

## [2.19.0] — 2026-05-25

### Added

- **Project-reference discoverability** (#627) — new `skills/project-references` with sidecar/index schema, content-trust rules, setup/loader scripts, and platform notes. New `/setup-references` command surfaces for Claude Code and Copilot, plus examples and customization docs. Reference loading and citation-discipline guidance integrated into upstream onboarding and customer/design/plan skills so upstream agents can surface authoritative repo docs before authoring decisions.
- **Structural-criteria deferral gate** (#610) — verdict-decision text is now driven by structural criteria rather than effort estimates. New `skills/review-judgment/scripts/Test-DeferralCriteria.ps1` exposes the canonical criterion taxonomy (`S-new-abstraction`, `S-cross-cutting`, `S-design-decision`, `S-schema-or-contract`, `S-different-surface`, `S-maintainer-judgment`).
- **`Add-FollowUpIssue` helper** (#610) — `skills/safe-operations/scripts/Add-FollowUpIssue.ps1` ships `Add-FollowUpIssue`, `ConvertTo-CanonicalFollowupTitle`, and `New-FollowupSentinelBlock` for follow-up issue filing with GraphQL parenting and the `<!-- code-conductor-filed-followup -->` sentinel contract (AC8).
- **`Get-StructuralVerdict` / `Get-AcRefsFromIssue` helpers** (#610) — additional public review-judgment surface used by Code-Conductor and code-review-intake to share a single deferral-decision implementation across both filing paths.

### Changed

- **Verdict category labels** (#610) — `ACCEPT (<1 day)` renamed to `ACCEPT (fix inline)`; `DEFERRED-SIGNIFICANT (>1 day, non-blocking)` renamed to `DEFERRED-SIGNIFICANT (structural)`. Effort-language remnants removed from primary verdict-decision text in `skills/safe-operations/SKILL.md`, `Documents/Design/safe-operations.md`, `Documents/Design/setup-wizard.md`, and `skills/validation-methodology/references/review-reconciliation.md`.
- **`skills/code-review-intake/SKILL.md`** (#610) — cross-references the shared structural-criteria gate so GitHub-intake judgments stay aligned with non-GitHub review verdicts.

## [2.17.0] — 2026-05-20

### Added

- **Squash-merge orphan auto-resolve** (#548 / PR #595) — session-startup cleanup now auto-deletes `feature/issue-N-*` branches that have been squash-merged into main. Adds a three-layer verification chain in `skills/session-startup/scripts/session-startup-git-helpers.ps1`: ancestor reachability → patch-equivalent (`git cherry`) → spike-only / tree-at-HEAD per-residual-commit classification. Authorization requires the parent issue to be CLOSED **and** a merged PR with `headRefOid == git rev-parse $Branch` (the local branch tip SHA), so the auto-delete path only fires for branches whose exact tip was the merged head. New Pester suites: `test-orphan-branch-commits-absorbed.Tests.ps1`, `test-orphan-branch-auto-resolve-eligible.Tests.ps1`, `test-orphan-branch-github-signals.Tests.ps1`, `script-wording-contract.Tests.ps1`.
- **Composite sibling + orphan cleanup invocation** (#548) — the session-startup skill now passes sibling worktree paths and orphan branch names as parameters to a single `post-merge-cleanup.ps1 -SiblingWorktrees @(...) -OrphanBranches @(...)` invocation, so confirming the full cleanup batch triggers one permission prompt instead of one per branch.

### Changed

- **`skills/session-startup/scripts/session-startup-git-helpers.ps1`** (#598) — `Test-OrphanBranchCommitsAbsorbed` switched from `git log --first-parent` to `git rev-list ... --no-merges` + `git log --no-merges --name-status`. Closes a recall gap where sub-feature-merge topologies (feature branches that absorbed a sub-feature via `git merge --no-ff`) hit the empty-path guard and conservatively declined auto-resolve. Second-parent ancestors now appear in both `$residualSHAs` and `$commitPaths` with their actual file paths. Added a `# SAFETY ASSUMPTION (workflow-dependent):` inline comment documenting the squash-merge + headRefOid coupling and the escalation path (issue #599) if the project's merge convention ever broadens.
- **`skills/session-startup/SKILL.md`** (#596) — race-condition wording updated from `'became unmerged between re-check and force-delete'` to `'branch not reachable from default (merged-state re-check returned false)'` for accuracy.

### Fixed

- **Polish nits from PR #595 adversarial review** (#596) — minor wording fixes (M10/M11/M16/M17), shim call-log assertion for `--base master` in the master-default-branch test, and Pester `-Because` text alignment with the new race-condition wording.

## [2.16.0] — 2026-05-19

### Added

- **`skills/solution-authoring/SKILL.md`** — new cognitive-surrender-prevention v0 engagement skill. Codifies the D-classification-test (3-leg gate with artifact-citation falsifier), decision brief structure, override semantics, skip rules (including engineer-declined-engagement and same-decision-resume stub for #575), thin-articulation criterion with forward-compatible YAML schema, and 5 template sections each with a canonical exemplar from the #571 R1+R2 transcript. Declares no `provides:` field — supporting methodology, not a frame port adapter.
- **`skills/solution-authoring/platforms/claude.md`** and **`skills/solution-authoring/platforms/copilot.md`** — platform-specific AskUserQuestion / vscode/askQuestions invocation notes.
- **`Documents/Design/frame-architecture.md`** — stacking-precedent paragraph in the Adapter Model / Declaration asymmetry section documenting that `solution-authoring` and `upstream-onboarding` can stack as `provides:`-less supporting methodologies with load-order declared in the agent body dispatcher.
- **`.github/scripts/Tests/solution-authoring.Tests.ps1`** — structural Pester contract covering AC11.a–AC11.g: body shape (5 rule + 5 template sections), platforms parity, 4-body directive (new present, old absent, line-index ordering, CC touchpoint enumeration), upstream-onboarding sweep (no "first" in 3 anchors + allowlist gate), recommendation-shift token, v0 gate comment, terminology drift guard.

### Changed

- **`agents/Experience-Owner.agent.md`**, **`agents/Solution-Designer.agent.md`**, **`agents/Issue-Planner.agent.md`**, **`agents/Code-Conductor.agent.md`** — `## Process` section standalone upstream-onboarding load line replaced with two-sentence solution-authoring-first directive plus cross-session disclaimer (tracked in #575). Code-Conductor additionally enumerates `scope-classification` and `D9-checkpoint` as content-authoring touchpoints.
- **`skills/upstream-onboarding/SKILL.md`** — removed "first" load-order claim at three section-anchors (frontmatter description, ## When to Use opener, ### Sequencing bullet). Added `<!-- d-load-order-resolution-anchor -->` near ## When to Use. The skill no longer asserts it must be loaded first; that ordering is declared in each agent body dispatcher.

## [2.15.1] — 2026-05-18

### Added

- **Plan tree-state verification discipline** (#582 / issue #579) — Issue-Planner now runs a tree-state verification before adversarial stress-test invocation and populates a `**Verification Evidence**` block in the plan. Includes new `.github/scripts/plan-tree-state-verification.ps1` and Pester contract tests under `.github/scripts/Tests/`.
