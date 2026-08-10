# Criteria Lens Exhibits

Incident detail for the lenses in `skills/plan-authoring/SKILL.md` § Criteria Lenses. Each section below is the record of one occurrence — what was written, what a compliant reading of it permitted, what the review found, and which artifacts, issues and measurements were involved. The actionable rules live in the lens sections that cite these exhibits; nothing here restates them.

## Contents

- [Five criteria that a gate script satisfied](#five-criteria-that-a-gate-script-satisfied)
- [One noun, two commits, eight days apart](#one-noun-two-commits-eight-days-apart)
- [Two blockers the executor controlled](#two-blockers-the-executor-controlled)
- [Four polarities over an unexercised population](#four-polarities-over-an-unexercised-population)
- [A premise encoded into a comparison operator](#a-premise-encoded-into-a-comparison-operator)
- [Six scope failures under one tag](#six-scope-failures-under-one-tag)
- [A home chosen for a lane the failures never used](#a-home-chosen-for-a-lane-the-failures-never-used)

## Five criteria that a gate script satisfied

*Cited from § Criteria can pin the reader-facing surface completely and miss every programmatic consumer.*

On #958 — chunk 1 of #949 — the first-draft brief carried five acceptance criteria, all of them pinning what a maintainer reads from the suite runner's output. Every one of the five was satisfiable by placing the whole feature inside the 44-line gate script. Neither of the runner's two real callers executes that script: both dot-source the logic library directly. The tests would still have passed, because they never touch the gate script, so no check in the brief or the suite would have caught the narrow implementation.

The clause written into the criteria as protection did not protect. It read *"no extra argument, no wrapper script, no opt-in flag"*, and it was believed to block exactly this reading. It does not: it constrains **how the invoker invokes**, not **where the code lives**, and the gate script is itself the sanctioned entry point — `skills/terminal-hygiene/SKILL.md:30` names it as the standard validation gate. So the clause excluded the only invocation that would have satisfied it while leaving the narrow-work reading untouched.

The real defence at draft time lived in two places that carry no grading weight: the context inventory and the falsifier list. Chunked-delivery amendment A3 makes falsifiers prose the run is explicitly *not* graded on, so the protection was structurally unable to fail the run.

Two of three review lenses found this independently, and one rated it high. Note the relationship to the vacuity exhibit on #948: the vacuity question catches *no-work* readings, and this was a *narrow-work* reading, which passes that question.

## One noun, two commits, eight days apart

*Cited from § One noun naming two things lets a compliant run satisfy every criterion and do nothing.*

In the #948 brief the word **"baseline"** named two different commits, eight days apart. The `Decisions` bullet said *"anchor **the baseline** on the last recorded-green commit"*. AC1 said the run *"measures the suite twice **at that commit**"*. Read literally by an unattended executor, AC1 pins at the green commit, the failing set recorded there is **empty**, and AC1, AC3 and AC5 are all satisfied vacuously — while AC2 still goes green after unrelated fixes. Every criterion met; the enumeration the plan existed to force never performed.

The two meanings had been distinct in the design that fed the brief. One was the `attribution anchor` — the far endpoint that attribution measures back to. The other was the `launch baseline` — what the run measures at its own commit. The two collapsed into a single noun during the design-to-brief rewrite. The prose read fine to its author, who held both referents in mind while writing; the executor holds only the text.

Two prosecution lenses and the convergence cold read all flagged it independently, and it was the highest-ranked finding of that review.

The same review surfaced two sibling authoring traps in the same brief: a criterion that mandated the one method structurally unable to observe part of its own domain, and an "attempted and did not resolve" escape hatch that set no floor on what counts as an attempt.

## Two blockers the executor controlled

*Cited from § A vacuity answer can name the right verdict and cite blockers the executor can escape.*

On #944 the brief conformance check's property-5 answer constructed a candidate no-work reading and named two clauses as blocking it. Review showed both cited clauses had executor-controlled escapes.

The first was AC1's population clause, *"every issue carrying marker text"*. It was undercut by AC1's **own proof standard**, which said *"run the reader across the swept corpus"* — and the sweep was executor-controlled. The criterion was general; the proof standard that discharged it was population-relative, so the executor chose the population the general clause was checked over.

The second was AC5's veto flip, and the calendar undercut it. The report's window comes from `(Get-Date)` at invocation with no anchor parameter. A run executed after the affected issues age out therefore passes AC5 **on an empty antecedent** — the veto never has anything to fire against.

The recorded verdict — "no surviving reading" — was still correct. It survived on a clause that had never been cited in the answer at all. So the justification written into the vacuity record was materially weaker than it claimed to be, on exactly the surface a later reader trusts when deciding whether the criteria set was checked.

Two independent lenses plus a convergence cold read each constructed a *different* vacuity reading than the one recorded, and that divergence was itself the signal that the criteria were ambiguous.

## Four polarities over an unexercised population

*Cited from § A proof standard can name every polarity and still miss the population none of its exhibits exercises.*

On #1012 the brief's AC2 named four polarities: compliant, #1011 failing, out-of-domain, and durability. All four passed on the first run. The 5-pass panel then found the defect anyway, unanimously.

Every one of those four exhibits used a filing that carried **both surface anchors**, and the procedure derived its search set from exactly two body fields that the filing helper declares *optional*. Five currently-open `gate-approved` filings — #858, #862, #864, #865 and #992 — carry neither field. They derive an empty set and fall through to the failing verdict: a false accusation produced by construction, in the very class the contract itself called "worse than useless".

The gap sat one level below where the falsifiers were aimed. The brief's falsifiers all guarded the procedure's *conclusions* — don't accept a self-echo record, don't let #1011 reconcile, don't overclaim. Nothing guarded its *inputs*. Both facts needed to see it were one grep away the whole time: `Add-FollowUpIssue.ps1` says in its own docstring that "missing originating_pr [is] legal", and a blank parent is an explicitly documented by-design case.

Two corollaries came out of the same review. Negative outcomes had been collapsed — "couldn't read it", "nothing to search" and "no record exists" were one verdict, while the mandated read helper returns an empty set on *five* failure paths, one of them silently, so a rate limit read as an accusation; the fix was five outcomes rather than two: `located` / `unsupported` / `out of domain` / `could-not-verify` / `not-reconcilable`. And the contract had no cutover clause, so all 34 pre-contract ruling-asserting filings read as defects on day one.

## A premise encoded into a comparison operator

*Cited from § Specify at the knowledge level you actually have.*

The #908 goal-contract carried a sample-inferred premise — "drive case is not derivable", recorded as A1 — and encoded it directly into its targets' comparison operator: `-ieq` on the drive letter. That made the contract structurally blind to the exact premise that turned out to be false, and it mandated a mechanism, a case-variant union, that the evidence later dissolved.

The measured consequence: the contract scored the **wrong** implementation 8/8 and the source-verified one 3/8. Both are recorded as findings 2 and 6 on #932.

A second measurement from the same episode concerns where falsifier knowledge was placed. The #908 stress-test hardened its falsifier knowledge into check commands, and that hardening prevented neither run's vacuous tests. The same knowledge delivered as prose executor guidance did prevent them, in the place where it was actually read.

The canonical records are #936, which carries doctrine amendments A1–A4; #932, which carries the evidence; and #920, `chunked-delivery.md`, the doctrine being amended.

## Six scope failures under one tag

*Cited from § A source-read tag certifies that you looked, not that you looked where the answer lives.*

Six occurrences across three briefs, all under a `source-read` tag.

On **#995** the tagged claim was *"#957's body carries `## Amendments at open-for-work` … 11 is the highest."* It was false: Amendment 12 had existed since 2026-08-02. The instrument was `grep -rhoE 'Amendment [0-9]+' Documents/ skills/ commands/`, a search over repository files, while the amendment register lives in #957's issue body on GitHub — content that search could not reach under any outcome. Two of three prosecution lenses caught it independently and it was the review's only high finding. The register also advanced by a full increment *while #995 was being authored*. The false claim then propagated into a known-unknown naming "a new numbered Amendment 12" as a live option, which would have shipped a duplicate heading, and the criterion guarding it — a cold read reaching "an entry after Amendment 11" — would not have caught the collision.

On **#998** (2026-08-04), two more. Term-selection: "the standing completion skill has no adversarial-review vocabulary" was proved with four hand-picked terms — `adversarial`, `prosecut`, `code-critic`, `review ran` — that all returned zero, while the unqualified `review` returns **8**, including `- [ ] [Required review process]`. Case: `grep "deferred-significant"` returned 3 hits, but case-insensitively it appears in 17 files, including `skills/review-judgment/scripts/Test-DeferralCriteria.ps1:397`, which emits `DEFERRED-SIGNIFICANT (structural)`.

On **#1035** (2026-08-09), three more. String-presence versus behavior: no `.yml` contains `$GITHUB_STEP_SUMMARY`, but `phase-containment-region-guard.yml` invokes a script without `-SummaryPath`, and that script defaults the parameter to `$env:GITHUB_STEP_SUMMARY` and `Add-Content`s to it every run. A retention-bounded instrument: `gh run list --event schedule` returning zero rows was cited for the repo's whole life; the claim that establishes it is `git log -S "cron:" --all -- .github/workflows/`, exactly one commit. Right object, wrong key: `Selected` holds absolute paths, `Quarantined[].file` bare filenames, and the bare-name key is `SelectedNames` — the union reconciles at count grain, 60 + 191 = 251, and fails on every name comparison.

## A home chosen for a lane the failures never used

*Cited from § Establish which executor lane actually failed before moving an instruction to reach it.*

On #1013 the close-out obligation was moved next to Code-Conductor's `Closes #{issue}` mandate, because that is where the filing pointed. The design challenge's cold read asked whether the failing runs had ever read that file. They had not.

The test that established it used fields the lane mandates in its own output. `agents/Code-Conductor.agent.md:354` requires the PR body to carry a CE Gate result, an adversarial review score table, and a prosecution depth summary. Across all five PRs that closed an open-for-work issue, the occurrence count of each was **zero** — one command, over artifacts already on GitHub, no instrumentation and no waiting.

The question had been mis-tagged before that. "Did those runs read Step 4?" was tagged `sample-inferred` and pushed into the falsifier list, while it was answerable that minute.

There were at least two in-tree PR-creation paths — `agents/Goal-Run.agent.md` Stage 5 via `persist-changes`, plus Code-Conductor — and the failures used neither. With no agent body reaching the population, the home became an artifact the run itself carries: the brief's `## 6. Evidence obligations`. `skills/persist-changes/SKILL.md` looks lane-agnostic but disclaims new-PR creation, so it could not hold a pre-PR obligation.

Two further defects rode along with the wrong home, and both went moot the moment the home changed: the chosen anchor was not sequentially before the call it had to precede (`gh pr create` sits at `:352`, the `Closes` mandate it "precedes" at `:354`), and the target file was at 498 lines against a 500-line CI cap.
