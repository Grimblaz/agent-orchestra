#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

# Pester tests for phase-containment-emission-check-core.ps1 (issue #782, TDD red-green).
#
# File under test: .github/scripts/lib/phase-containment-emission-check-core.ps1
#
# Fixtures below pin the REAL messy live comment bodies verbatim (not
# idealized shapes) from PRs #775, #778, #781, and issue #782's own design
# and plan surfaces, per the frame-slice contract's fixture requirement.

# NOTE: fixture bodies are assigned inside this single BeforeAll block (rather
# than as bare top-level $script: statements) because Pester 5 evaluates
# top-level statements during the discovery phase, in a scope that does not
# carry into the later Run phase's It blocks. BeforeAll runs in the Run phase.
BeforeAll {
    $script:LibRoot = Join-Path $PSScriptRoot '..' 'lib'
    . (Join-Path $script:LibRoot 'phase-containment-emission-check-core.ps1')

#region Test helper: New-ValidPhaseContainmentBlockText (Fix A / M2 M5 support)

# Builds a schema-valid <!-- phase-containment-{Id} --> block with a
# surface-prefixed finding_key, for tests exercising Fix A's
# marker-co-location + finding_key-prefix + Test-PhaseContainmentEntry gating.
# escape_distance is computed correctly by default (projection(caught_stage)
# - ordinal(catchable_phase)) so the block passes schema validation unless a
# test deliberately overrides a field to make it invalid.
function script:New-ValidPhaseContainmentBlockText {
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$Surface,
        [Parameter(Mandatory)][string]$FindingSuffix,
        [string]$CatchablePhase = 'implementation',
        [string]$CaughtStage = 'code-review',
        [int]$EscapeDistance = 0
    )
    $findingKey = "${Surface}:${Id}:${FindingSuffix}"
    $lines = @(
        "<!-- phase-containment-$Id -->"
        "finding_key: $findingKey"
        "introduced_phase: $CatchablePhase"
        "catchable_phase: $CatchablePhase"
        "caught_stage: $CaughtStage"
        "escape_distance: $EscapeDistance"
        'severity: low'
        'systemic_fix_type: none'
        'category: pattern'
        'apparatus_meta: false'
        'seed: false'
        "<!-- /phase-containment-$Id -->"
    )
    return ($lines -join "`n")
}

#endregion

#region Live fixture: PR #775 — GitHub-intake proxy-prosecution variant

# Verbatim from PR #775's judge-rulings comment (gh pr view 775 --json comments).
# GF-1 accept, GF-2 accept, GF-3 reject -> 2 sustained. Contains the
# required_fixes: decoy list (must NOT be counted).
$script:Pr775Body = @'
## 🧑‍⚖️ GitHub Review Intake — Judge Rulings

**Pipeline**: proxy prosecution (Code-Critic) → defense (Code-Critic) → judge (Code-Review-Response). 3 GitHub bot reviews ingested (Gemini Code Assist, CodeRabbit inline, Sourcery/Qodo no-findings). **Verdict: mixed · total score 6.**

| ID | Finding | Severity | Disposition | Score |
|----|---------|----------|-------------|-------|
| GF-1 | Empty project slug collapses scan to all `~/.claude/projects/` (cross-project baseline) | low | ✅ ACCEPT (fixed) | 1 |
| GF-2 | `?[]` null-conditional operator violates declared `#Requires -Version 7.0` floor | medium | ✅ ACCEPT (fixed) | 5 |
| GF-3 | `exit 0` in main block vs spawn-guard test policy | low | ❌ REJECT (optional nit) | 0 |

### Dispositions
- **GF-1 — ACCEPT** (Gemini): mechanics reproduced live.
- **GF-2 — ACCEPT** (Gemini + CodeRabbit): the `#Requires` floor was a false contract.
- **GF-3 — REJECT** (Gemini): no change.

<!-- judge-rulings
pr: 775
verdict: mixed
total_score: 6
review_mode: github-intake-proxy-prosecution
findings:
  - id: GF-1
    disposition: accept
    severity: low
    score: 1
  - id: GF-2
    disposition: accept
    severity: medium
    score: 5
  - id: GF-3
    disposition: reject
    severity: low
    score: 0
required_fixes:
  - id: GF-1
    file: .github/scripts/reporting-economy-spotcheck.ps1
    change: "Empty-slug guard in Invoke-ReportingEconomySpotcheck non-override branch — return baseline-unavailable before building slugDir."
  - id: GF-2
    file: .github/scripts/reporting-economy-spotcheck.ps1
    change: "Bump #Requires -Version 7.0 -> 7.1 (matches ?[] operator floor); same bump applied to Tests file."
applied_in_commit: a639a2c
-->
'@

#endregion

#region Live fixture: PR #778 — attributed head + four-value disposition variant

# Verbatim from PR #778's judge-rulings comment. Attributed head
# `judge-rulings pr=778`. dismissed_items: [U3, U9] -> 12 - 2 = 10 sustained
# (U5, U11 are Defer and count as sustained per the not-Dismiss rule).
$script:Pr778Body = @'
## Adversarial Review Score — PR #778 (Issue #774)

| Finding | Severity | Disposition | Action |
|---------|----------|-------------|--------|
| U1: Lever table off-by-one + unlabeled collision | HIGH | Sustained | Fixed inline |
| U2: §4.9 directive trigger can never fire | HIGH | Sustained | Fixed inline |
| U3: awk /^coverage:/ on indented YAML | HIGH (claimed) | Defense sustained | Dismissed |
| U4: §4.8 board-effect cross-repo | MEDIUM | Sustained (narrowed) | Fixed inline |
| U5: Upstream greenfield paths not covered | MEDIUM | Sustained (deferred) | Follow-up |
| U6: "will not go missing" vs cap-5 | MEDIUM | Sustained | Fixed inline |
| U7: Contract test doesn't pin numeric values | MEDIUM | Sustained | Fixed inline |
| U8: Unrelated CI step scope drift | MEDIUM | Sustained (narrowed) | PR note added |
| U9: D5 extraction Add-FCLCreditRow timing gap | MEDIUM (claimed) | Defense sustained | Dismissed |
| U10: Carve-out overstates residue satisfaction | MEDIUM | Sustained | Fixed inline |
| U11: Lost Pipeline Metrics sentence | LOW | Deferred | Follow-up |
| U12: Dead ound variable / retry arm | LOW | Sustained (narrowed) | Fixed inline |

**Score**: Prosecutor 47pts / Defense 15pts | 3 prosecution passes × 1 defense × 1 judge | 12 findings resolved

```yaml
<!-- judge-rulings pr=778 -->
U1: {disposition: Fix-now, priority: blocking, summary: "Lever table corrected to 0/1/2; unlabeled stays 3"}
U2: {disposition: Fix-now, priority: blocking, summary: "§4.9 directive rebound to create-improvement-issue.ps1 -Labels parameter"}
U3: {disposition: Dismiss, priority: non-blocking, summary: "Defense sustained. coverage: at column 0 by renderer; awk anchor correct"}
U4: {disposition: Fix-in-PR, priority: non-blocking, summary: "§4.8 annotated: board-placement levers act on upstream repo board, not local CT"}
U5: {disposition: Defer, priority: non-blocking, summary: "Rule binds universally via safe-operations; upstream-agent greenfield reminders filed as follow-up"}
U6: {disposition: Fix-now, priority: blocking, summary: "§2b-bis softened from absolute guarantee to cap-aware candidate phrasing"}
U7: {disposition: Fix-now, priority: blocking, summary: "Numeric-pinning assertion added to contract test (0=high, 1=medium, 2=low)"}
U8: {disposition: Fix-in-PR, priority: non-blocking, summary: "cost-pattern step noted as #769/#771 lineage; PR body note added"}
U9: {disposition: Dismiss, priority: non-blocking, summary: "File-based accumulator; load-on-demand creates no timing gap"}
U10: {disposition: Fix-now, priority: blocking, summary: "Carve-out narrowed to placement-only; priority via label, no rationale required"}
U11: {disposition: Defer, priority: non-blocking, summary: "System contract survives in responsibility-map spine-runner-keeps row"}
U12: {disposition: Fix-in-PR, priority: non-blocking, summary: "Dead 'found' variable removed; *) arm retry NOT added (malformed coverage is non-transient)"}
blocking_items: [U1, U2, U6, U7, U10]
dismissed_items: [U3, U9]
follow_up_items: [U5, U11]
verdict: APPROVE_WITH_FIXES
```
'@

#endregion

#region Live fixture: PR #781 — bare head, canonical judge_ruling variant

# Verbatim from PR #781's judge-rulings comment. Bare head `<!-- judge-rulings`.
# 4x judge_ruling: sustained (GR-01, GR-03, GR-04, GR-05), 1x defense-sustained (GR-02).
$script:Pr781Body = @'
## GitHub Review Judgment — PR #781 (issue #776, BDD detection widening)

Proxy prosecution → defense → judge over 5 GitHub-review findings (CodeRabbit ×3, Gemini ×2; Sourcery rate-limited, no findings).

### Adversarial Review Score Summary

| Finding | Source | Prosecution | Defense | Ruling | Points |
| --- | --- | --- | --- | --- | --- |
| GR-01: Version manifest drift (release-blocked) | CodeRabbit | medium (5) | challenge → high | ✅ Sustained — **high** | P+10 |
| GR-02: Regex `.*` newline span | CodeRabbit | reject (0) | disproved | ❌ Defense sustained | D+0 |
| GR-03: AC2 same-file `bdd:` test too loose | CodeRabbit | low (1) | sustained | ✅ Sustained | P+1 |
| GR-04: CLAUDE.md guard tautology | Gemini | low (1) | sustained | ✅ Sustained | P+1 |
| GR-05: EOF boundary clarification | Gemini | low (1) | sustained | ✅ Sustained | P+1 |

**Totals** — Prosecutor: 13 pts · Defense: 0 pts · 5 findings ruled, 0 pending user scoring.

### Dispositions

| ID | Disposition | Fix |
| --- | --- | --- |
| GR-01 | ✅ ACCEPT | Restore version lockstep to 2.35.15 across all 7 occurrences via `bump-version.ps1` (not hand-edit). |
| GR-02 | ❌ REJECT | No change — all three filenames sit on one physical line. |
| GR-03 | ✅ ACCEPT | Tighten the AC2 assertion to a section-scoped proximity match. |
| GR-04 | ✅ ACCEPT | Replace tautological `0 | Should -Be 0` with `Set-ItResult -Skipped`. |
| GR-05 | ✅ ACCEPT | Add "or end-of-file" clause to the boundary clauses. |

No structural (S-*) findings — all touch the existing PR file-set; nothing deferred.

```yaml
<!-- judge-rulings
- id: GR-01
  judge_ruling: sustained
  judge_confidence: high
  points_awarded: P+10
- id: GR-02
  judge_ruling: defense-sustained
  judge_confidence: high
  points_awarded: D+0
- id: GR-03
  judge_ruling: sustained
  judge_confidence: high
  points_awarded: P+1
- id: GR-04
  judge_ruling: sustained
  judge_confidence: high
  points_awarded: P+1
- id: GR-05
  judge_ruling: sustained
  judge_confidence: medium
  points_awarded: P+1
-->
```

Fixes applied inline and pushed to this branch in the response loop that follows.
'@

#endregion

#region Live fixture: issue #782 design-phase-complete block (design-challenge surface)

# Verbatim excerpt from issue #782's design-phase-complete-782 comment
# (finding_dispositions block). All 6 entries are incorporate -> 6 sustained.
$script:Design782Body = @'
<!-- design-phase-complete-782 -->

Technical design complete — decisions documented, acceptance criteria defined, adversarial design challenge complete. Ready for planning with @Issue-Planner.

Phase summary: 6 finding(s) classified, 4 load-bearing, 0 dismissed. Decisions taken: DD1-DD5.

```yaml
finding_dispositions:
  schema_version: 1
  passes_run: [1, 2, 3]
  entries:
    - finding_id: F1
      pass: 1
      disposition: incorporate
      classification: load-bearing
      disposition_rationale: "Per-surface sustained-count extractor is fragile across 3 differently-encoded surfaces; resolved by DD3 (all-3-surface Pester-tested extractor)."
    - finding_id: F2
      pass: 1
      disposition: incorporate
      classification: load-bearing
      disposition_rationale: "Judge IDs do not map 1:1 to phase-containment finding_keys; resolved as count-based warnings now, identity-precise correlation deferred (DD3)."
    - finding_id: F3
      pass: 2
      disposition: incorporate
      classification: load-bearing
      disposition_rationale: "On extractor error the sweep must fail loud, never silent; folded into DD3 as a non-negotiable invariant protecting scenario S2."
    - finding_id: F4
      pass: 2
      disposition: incorporate
      classification: routine
      disposition_rationale: "Emission-site nudge shares the forget-the-step failure mode; framed as explicitly secondary in DD1, never advertised as coverage."
    - finding_id: F5
      pass: 3
      disposition: incorporate
      classification: load-bearing
      disposition_rationale: "Sweep must reuse the #772-hardened walker, not fork it; resolved by DD5 with the #772 dependency documented, proceeding now."
    - finding_id: F6
      pass: 3
      disposition: incorporate
      classification: routine
      disposition_rationale: "One-time 13-entry backfill should not be over-tooled; DD4 makes the backfill render a thin view of the sweep gap output."
```
'@

#endregion

#region Synthetic fixture: design-challenge with a dismiss entry (enum coverage)

# The live #782 design block has no `dismiss` entries (design decisions in it
# were all incorporated). This synthetic fixture exercises the dismiss ->
# not-sustained branch, constructed by-analogy to the live shape per the
# frame-slice's fixture requirements (zero-sustained / enum-coverage cases).
$script:DesignDismissBody = @'
```yaml
finding_dispositions:
  schema_version: 1
  passes_run: [1]
  entries:
    - finding_id: F1
      pass: 1
      disposition: incorporate
      classification: load-bearing
      disposition_rationale: "Kept."
    - finding_id: F2
      pass: 1
      disposition: escalate
      classification: load-bearing
      disposition_rationale: "Escalated to maintainer."
    - finding_id: F3
      pass: 1
      disposition: dismiss
      classification: routine
      disposition_rationale: "Not applicable to current architecture."
```
'@

#endregion

#region Synthetic fixture: GH-5 regression — free-text disposition_rationale substring mimics a disposition line (design-challenge)

# GH-5 (code-review response loop, PR #789): the design-challenge disposition
# scanner used a bare `(?m)disposition\s*:\s*(incorporate|escalate|dismiss)\b`
# regex with no key-position anchor, unlike the code-review surface's
# $keyAnchor-anchored detectors. This body has exactly ONE real finding
# (disposition: dismiss) plus a disposition_rationale free-text string that
# quotes the substring "disposition: incorporate" describing a DIFFERENT,
# unrelated finding's history in prose. Pre-fix, the unanchored regex matched
# BOTH the real "disposition: dismiss" key and the prose substring
# "disposition: incorporate", yielding SustainedCount=1 (only the prose
# "incorporate" survives the != 'dismiss' filter) despite the real finding
# being dismissed and zero real findings being sustained. Post-fix, the
# $keyAnchor-equivalent anchor excludes the mid-line prose match, and the
# correct SustainedCount=0 is returned.
$script:GH5DesignChallengeProseSubstringBody = @'
```yaml
finding_dispositions:
  schema_version: 1
  passes_run: [1]
  entries:
    - finding_id: F1
      pass: 1
      disposition: dismiss
      classification: routine
      disposition_rationale: "Not applicable; an earlier related finding had disposition: incorporate but was superseded by this analysis."
```
'@

#endregion

#region Synthetic fixture: plan-issue-782's own plan-stress-test judge-rulings

# Issue #782's own plan-issue-782 comment does not yet contain a
# plan-stress-test judge-rulings YAML block for itself (the phase-containment-782
# blocks present are the OUTPUT of the plan stress-test, not a judge-rulings
# input block). Per the frame-slice's fixture note ("by-analogy until posted"),
# this fixture constructs the plan-surface shape using the same judge-rulings
# template as code-review/PR #781, scaled to this plan's real judge summary:
# 18 sustained (M1-M4, M6-M19 = 17... actually issue text states 18 sustained,
# 1 defense-sustained (M5 struck)). Modeled at 3 entries for a focused unit test.
$script:PlanStressTestBody = @'
**Plan Stress-Test** (summary of Code-Critic review via `skills/adversarial-review/platforms/claude.md` `standard` adapter)

Judge: 18 sustained (1 critical, 2 high, 9 medium, 6 low), 1 defense-sustained (M5 struck).

```yaml
<!-- judge-rulings
- id: M1
  judge_ruling: sustained
  judge_confidence: high
  points_awarded: P+5
- id: M5
  judge_ruling: defense-sustained
  judge_confidence: high
  points_awarded: D+0
- id: M4
  judge_ruling: sustained
  judge_confidence: high
  points_awarded: P+10
-->
```
'@

#endregion

#region Synthetic fixtures: zero-sustained, malformed, unknown-vocabulary

$script:ZeroSustainedBody = @'
```yaml
<!-- judge-rulings pr=999 -->
- id: X1
  judge_ruling: defense-sustained
  judge_confidence: high
  points_awarded: D+0
-->
```
'@

$script:MalformedBody = @'
Some prose that mentions ✅ ACCEPT and Sustained in a table but has no
judge-rulings marker or finding_dispositions key anywhere in this body.
'@

$script:UnknownVocabularyBody = @'
<!-- judge-rulings
- id: Z1
  judge_ruling: maybe-sustained-ish
  judge_confidence: high
-->
'@

#endregion

#region Synthetic fixture: M3 regression — free-text prose substring mimics a disposition line

# The judge's exact required regression case. This is the intake-mode variant
# (review_mode: github-intake-proxy-prosecution) with 2 REAL sustained
# findings (disposition: accept). Finding M2's free-text `summary:` prose
# contains the literal substring "disposition: Dismiss" describing an
# UNRELATED finding's history in prose, not a real structured disposition
# line. Pre-fix, the unanchored regex `(?m)disposition\s*:\s*Dismiss\b`
# matched this prose substring anywhere in the region (mid-line, not at true
# YAML line-start) and set $hasDismiss = $true. Because the four-value
# detectors ($hasDismiss/$hasFixNow) are checked BEFORE the intake-mode
# detector in the priority-order chain, this silently hijacked routing away
# from the correct intake-mode branch and into the four-value branch, where
# "accept" is not a recognized four-value token — leaving only the phantom
# prose "Dismiss" match, which yields SustainedCount=0 despite 2 real
# sustained findings. This is exactly the DD3 fail-loud violation the judge
# required a regression test for: a silent 0 instead of could-not-verify (or,
# with the fix, the correct real count).
$script:M3DismissSubstringInProseBody = @'
<!-- judge-rulings pr=901 -->
findings:
  - id: M1
    disposition: accept
  - id: M2
    disposition: accept
    summary: "Old prosecution notes said disposition: Dismiss for a different finding, later reversed on appeal."
review_mode: github-intake-proxy-prosecution
-->
'@

#endregion

#region 811-D1: plan-stress-test honest fallback fixtures

# Prose-only historic plan shape (every plan persisted before the 811 writer
# change): a `<!-- plan-issue-{N} -->` marker and a line-start
# `**Plan Stress-Test**` heading with narrative bullets, but NO machine-
# readable judge-rulings block at all.
$script:ProseOnlyPlanStressTestBody = @'
<!-- plan-issue-700 -->

## Plan: Some historic plan (#700)

**Plan Stress-Test** (3-pass `standard` adapter: 2 generalist + 1 specialist -> defense -> judge)

- Challenge M1 (some finding) - Prosecution: GA high - Post-judge ruling: **sustained** - Disposition: **incorporate**.
- Challenge M2 (another finding) - Prosecution: SS med - Post-judge: **defense-sustained** - Disposition: **dismiss**.
'@

# Chatter that merely discusses the "Plan Stress-Test" heading in prose
# (e.g. explaining the convention) with NO `<!-- plan-issue-` marker at all.
# Must NOT trigger the fallback (both conditions are required together).
$script:ChatterMentioningHeadingNoMarkerBody = @'
Just a note: our plans use a **Plan Stress-Test** section to record the
adversarial pipeline results before persisting. This comment is not itself
a plan and carries no plan-issue marker.
'@

# Duplicate judge-rulings heads in one body (e.g. a double-run backfill).
# Both heads parse individually as valid canonical judge-rulings shapes, but
# the reader must fail loud rather than pick one (latest-wins dropped, M1).
$script:DuplicateJudgeRulingsHeadsBody = @'
<!-- plan-issue-701 -->

**Plan Stress-Test** (5-pass `standard` adapter)

```yaml
<!-- judge-rulings
- id: M1
  judge_ruling: sustained
  judge_confidence: high
  points_awarded: P+5
-->
```

```yaml
<!-- judge-rulings
- id: M1
  judge_ruling: sustained
  judge_confidence: high
  points_awarded: P+5
-->
```
'@

# M1 fix regression fixture (issue #811 post-fix adversarial pass): a prose
# sentence merely MENTIONING the judge-rulings marker convention (no real
# field vocabulary following it within the lookahead window) co-occurring
# with exactly ONE genuinely real judge-rulings block. Before the M1 fix,
# the duplicate-head count treated the raw head-pattern match count (2) as
# "2+ duplicate heads" and returned could-not-verify — a false positive,
# since the prose mention is not a real head. After the fix, only the real
# head should count, so this must parse ok with SustainedCount=1.
#
# The real block comes FIRST and the prose mention is separated from it by
# more than the 400-char lookahead window (padding filler text below), so
# the prose head's own vocab-gate window cannot accidentally spill into the
# real block's vocabulary and produce a false vocab-gate pass for the prose
# mention itself — this fixture must genuinely exercise "prose head has NO
# real vocabulary in its own window," not merely rely on window overlap.
# The prose mention deliberately uses the BARE head form (not the
# `pr=N`-attributed form): Get-JudgeRulingsSustainedCountInternal's
# subsequent region-isolation step independently prefers ANY attributed-form
# match found anywhere in the body when selecting the authoritative region,
# which is a separate, pre-existing (main-branch) behavior outside this M1
# fix's scope — using the bare form here isolates this fixture to the
# duplicate-head vocab-gate behavior this test targets.
$script:ProseMentionPlusOneRealHeadBody = @'
<!-- plan-issue-703 -->

**Plan Stress-Test** (5-pass `standard` adapter)

<!-- judge-rulings
- finding_id: M1
  judge_ruling: sustained
-->

Padding prose to push the next mention well past the 400-character
lookahead window, so the two head matches cannot see into each other's
vocabulary windows. This paragraph exists purely as filler text with no
judge-rulings vocabulary of its own, repeated a few times to guarantee
sufficient distance between the real head above and the prose-only
mention below. Padding prose to push the next mention well past the
400-character lookahead window, so the two head matches cannot see into
each other's vocabulary windows. This paragraph exists purely as filler
text with no judge-rulings vocabulary of its own, repeated a few times to
guarantee sufficient distance between the real head above and the
prose-only mention below. Padding prose to push the next mention well
past the 400-character lookahead window so the two heads cannot overlap.

This PR uses the standard <!-- judge-rulings --> marker convention for
tracking review history, mentioned here only as ordinary narrative text
with nothing field-shaped following it before the paragraph ends.
'@

# A malformed/foreign judge-rulings head (fails the vocab gate) co-located
# with the plan-issue marker and heading. The fallback must still fire here
# (a present-but-broken head must not suppress the honest fallback) and
# Get-SustainedFindingCount must independently fail loud on this body too.
$script:CorruptHeadWithPlanIssueMarkerBody = @'
<!-- plan-issue-702 -->

**Plan Stress-Test** (2-pass `lite` adapter)

<!-- judge-rulings-report -->
Some unrelated report content, not real judge-rulings vocabulary.
-->
'@

#endregion

#region GH-3 (PR #815 review): decoy-before-real-block fixtures

# GH-3 scenario 1 (plan-stress-test surface): a BARE decoy head (fails the
# vocab gate — no real field vocabulary in its lookahead window) appears
# textually BEFORE a real, vocab-gate-passing bare block with a KNOWN
# sustained count (2). Pre-fix, region-isolation's standalone first-match
# scan picked the decoy's position, isolated an empty/prose-only region
# there, and returned could-not-verify — even though the real block,
# unexamined, would have parsed to SustainedCount=2. Both heads use the
# BARE form deliberately (the reachable shape per the review: this bug only
# fires on the bare head, not the attributed form).
$script:DecoyBeforeRealPlanStressTestBody = @'
<!-- plan-issue-704 -->

**Plan Stress-Test** (5-pass `standard` adapter)

This PR uses the standard <!-- judge-rulings --> marker convention for
tracking review history, mentioned here only as ordinary narrative text
with nothing field-shaped following it before the paragraph ends.

Padding prose to push the real head well past the 400-character lookahead
window, so the decoy's own vocab-gate window cannot accidentally see into
the real block's vocabulary below. This paragraph exists purely as filler
text with no judge-rulings vocabulary of its own, repeated a few times to
guarantee sufficient distance between the decoy above and the real block
below. Padding prose to push the real head well past the 400-character
lookahead window, so the two head matches cannot see into each other's
vocabulary windows. Padding prose to push the real head well past the
400-character lookahead window so the two heads cannot overlap at all.

<!-- judge-rulings
- finding_id: M1
  judge_ruling: sustained
- finding_id: M2
  judge_ruling: sustained
-->
'@

# GH-3 scenario 2 (code-review surface — the more serious silent
# false-clean): the SAME decoy-before-real-block shape, but exercised
# against Test-EmissionMarkerPresent directly on the code-review surface
# (which has no plan-stress-test fallback to mask the bug). Pre-fix,
# Test-EmissionMarkerPresent's own standalone first-match scan evaluated
# only the decoy, failed its vocab gate, and returned $false — marker not
# present — without ever checking for the later real head. Get-EmissionGap
# would then treat the whole body as ordinary chatter and silently
# contribute SustainedCount=0.
$script:DecoyBeforeRealCodeReviewBody = @'
This PR uses the standard <!-- judge-rulings --> marker convention for
tracking review dispositions, mentioned here only as ordinary narrative
text with nothing field-shaped following it before the paragraph ends.

Padding prose to push the real head well past the 400-character lookahead
window, so the decoy's own vocab-gate window cannot accidentally see into
the real block's vocabulary below. This paragraph exists purely as filler
text with no judge-rulings vocabulary of its own, repeated a few times to
guarantee sufficient distance between the decoy above and the real block
below. Padding prose to push the real head well past the 400-character
lookahead window, so the two head matches cannot see into each other's
vocabulary windows. Padding prose to push the real head well past the
400-character lookahead window so the two heads cannot overlap at all.

<!-- judge-rulings
- finding_id: M1
  judge_ruling: sustained
- finding_id: M2
  judge_ruling: sustained
-->
'@

# GH-3 M1-must-not-regress fixture: BOTH the decoy and the "real" block are
# vocab-gate-passing (i.e. genuinely 2+ real heads), so the M1 duplicate-head
# guard must still fail loud. This is NOT the GH-3 bug shape (the first head
# here is real, not a decoy) — it proves the GH-3 fix (scan-all-and-select-
# first-real) did not accidentally weaken M1's scan-all-and-count logic.
$script:TwoRealHeadsBothVocabGatePassingBody = @'
<!-- plan-issue-705 -->

**Plan Stress-Test** (5-pass `standard` adapter)

<!-- judge-rulings
- finding_id: A1
  judge_ruling: sustained
-->

Padding prose to push the next real head well past the 400-character
lookahead window, so the two real heads' vocab-gate windows cannot overlap
each other. This paragraph exists purely as filler text with no
judge-rulings vocabulary of its own, repeated a few times to guarantee
sufficient distance between the two real heads. Padding prose to push the
next real head well past the 400-character lookahead window so the two
heads cannot overlap at all, guaranteeing this is a genuine two-real-head
duplicate rather than a vocab-window collision artifact.

<!-- judge-rulings
- finding_id: B1
  judge_ruling: sustained
-->
'@

#endregion

#region Issue #817 (PF-F1): near-decoy window-bleed fixtures (decoy-ambiguous, RED at s1)

# All fixtures in this region assume LF-normalized bodies (`.gitattributes
# eol=lf`), consistent with every other fixture in this file — window
# semantics (the 400-char $script:JudgeRulingsLookaheadWindow) are defined
# over LF text; no CRLF variant is authored here (lite scope, M4).
#
# Background: Get-RealJudgeRulingsHeadMatches's vocab-gate window is a FIXED
# 400-char forward lookahead from each candidate head. When a harmless prose
# mention of the marker convention sits <400 chars BEFORE a real,
# vocab-gate-passing block, the mention's own window "bleeds" into the real
# block's vocabulary and passes the gate too — both mention and real block
# then count as "real" heads, tripping the M1 duplicate-head guard in
# Get-JudgeRulingsIsolatedRegion (>= 2 real heads -> could-not-verify) and
# producing Get-EmissionGap's misleading Reason 'head-corrupt' (implying
# content corruption, when the real cause is a harmless nearby mention).
# s2/s3 (a separate, later dispatch) will add a private helper,
# Get-JudgeRulingsDuplicateDiagnosis, that re-runs the vocab gate per
# candidate with the window TRUNCATED at the next real candidate's start
# (the last candidate keeps its full, untruncated window and therefore
# always survives — 0 survivors is unreachable by construction). Exactly 1
# surviving candidate means the "duplicate" was actually one real block plus
# a decoy whose own vocab-gate pass was borrowed via window bleed
# ('window-bleed' diagnosis -> Reason 'decoy-ambiguous'); 2+ survivors means
# every candidate had its OWN vocabulary independent of the others
# ('genuine-duplicate' diagnosis -> Reason stays 'head-corrupt', unchanged).
# THIS STEP (s1) ONLY AUTHORS FIXTURES AND RED TESTS — the helper does not
# exist yet, so every `Reason -eq 'decoy-ambiguous'` assertion below is
# expected to FAIL today (actual value is 'head-corrupt', per the M1 guard's
# current undifferentiated behavior); see the per-Describe-block RED/GREEN
# notes for exactly which assertions are current-behavior pins instead.

# T1: bare-prose decoy mention (`<!-- judge-rulings -->`, self-closed, no
# field vocabulary of its own) sitting well under 400 chars before a real,
# well-formed judge-rulings block on the plan-stress-test surface. Unlike
# $script:DecoyBeforeRealPlanStressTestBody (GH-3, ~L559 above), this
# fixture deliberately OMITS the padding filler paragraphs — the whole
# point here is that the decoy's window DOES reach the real block's
# vocabulary (confirmed: Get-RealJudgeRulingsHeadMatches returns exactly 2
# matches for this body — both the decoy and the real head pass the vocab
# gate, proving the bleed is real and not a fixture-authoring mistake).
$script:NearDecoyPlanStressTestBody = @'
<!-- plan-issue-706 -->

**Plan Stress-Test** (5-pass `standard` adapter)

This PR uses the standard <!-- judge-rulings --> marker convention for tracking review history, mentioned here only as ordinary narrative text.

<!-- judge-rulings
- finding_id: M1
  judge_ruling: sustained
- finding_id: M2
  judge_ruling: sustained
-->
'@

# T2: the same near-decoy shape as T1, but on the code-review surface (no
# plan-issue marker / Plan Stress-Test heading needed — code-review has no
# fallback path to mask or interact with this bug). Confirmed: exactly 2
# real head matches (decoy + real block both pass the vocab gate).
$script:NearDecoyCodeReviewBody = @'
This PR uses the standard <!-- judge-rulings --> marker convention for tracking review dispositions, mentioned here only as ordinary narrative text.

<!-- judge-rulings
- finding_id: M1
  judge_ruling: sustained
- finding_id: M2
  judge_ruling: sustained
-->
'@

# T5a: a decoy `<!-- judge-rulings -->` mention embedded INSIDE a
# `disposition_rationale: |` block-scalar's CONTENT, where the block
# scalar's own interior ALSO happens to contain real gate vocabulary (a
# planted `judge_ruling: sustained` line). The embedded decoy occurrence
# itself is already excluded from HEAD CANDIDACY today by the existing
# CM4 fix (Get-BlockScalarSpans / Test-IndexInBlockScalarSpan, core L253-258)
# — confirmed below: Get-RealJudgeRulingsHeadMatches returns exactly 2
# matches (the M1 head and the far-away M2 head), never counting the
# embedded mention as a third candidate. The M1 head itself, however, has
# NO genuine field vocabulary of its own anywhere in its own content — it
# is deemed "real" today ONLY because its 400-char forward window bleeds
# into the planted fake `judge_ruling:` line living INSIDE the block
# scalar. This is the specific gap the s2 helper's per-candidate vocab
# MATCH must additionally close (M8): the truncated-window re-check must
# ALSO exclude block-scalar-interior vocab tokens, not just block-scalar-
# interior HEAD positions, so a planted decoy vocabulary token cannot
# inflate the survivor count.
$script:EmbeddedBlockScalarFakeVocabBody = @'
<!-- plan-issue-708 -->

**Plan Stress-Test** (5-pass `standard` adapter)

<!-- judge-rulings
  disposition_rationale: |
    This note mentions a decoy <!-- judge-rulings --> pattern and a fake
    judge_ruling: sustained line, purely as prose content inside a block
    scalar, testing whether interior vocabulary wrongly counts as real.
-->

Padding prose to push the next real head well past the 400-character
lookahead window, so the two real heads' vocab-gate windows cannot overlap
each other. This paragraph exists purely as filler text with no
judge-rulings vocabulary of its own, repeated a few times to guarantee
sufficient distance between the two real heads. Padding prose to push the
next real head well past the 400-character lookahead window so the two
heads cannot overlap at all, guaranteeing this is a genuine two-real-head
duplicate rather than a vocab-window collision artifact.

<!-- judge-rulings
- finding_id: M2
  judge_ruling: sustained
-->
'@

# T5b: TWO bare-prose decoy mentions (not one) before a single real block,
# all three within bleed range of one another. Confirmed: exactly 3 real
# head matches (both decoys plus the real head all pass the vocab gate).
$script:TwoDecoysBeforeOneRealBody = @'
<!-- plan-issue-709 -->

**Plan Stress-Test** (5-pass `standard` adapter)

This PR uses the standard <!-- judge-rulings --> marker convention for tracking review history, mentioned here in a first prose sentence.

Another sentence also mentions the standard <!-- judge-rulings --> marker convention, purely descriptive narrative text with nothing field-shaped following it.

<!-- judge-rulings
- finding_id: M1
  judge_ruling: sustained
-->
'@

# T6 (documented D4 residual — close-heads genuine-duplicate): TWO
# structurally genuine judge-rulings head-OPENs (`<!-- judge-rulings` with
# no self-close), placed back-to-back with ZERO characters between them, so
# the FIRST head's own gate-vocabulary token (belonging to its own
# `finding_id: M1` entry) sits textually PAST the second head's start. This
# is NOT the same shape as the existing close-separated
# $script:DuplicateJudgeRulingsHeadsBody (~L458 above, pinned 'head-corrupt'
# at ~L1374) — that fixture's own vocabulary comes BEFORE the next head
# (each duplicate block is a complete, self-contained unit); here the first
# head has no content of its own before the second head begins. Confirmed:
# exactly 2 real head matches (both pass the vocab gate today, exactly as
# $script:DuplicateJudgeRulingsHeadsBody does), so Get-EmissionGap already
# reports 'head-corrupt' for this body today. Once the s2 helper lands, the
# truncated-window re-check will find the FIRST candidate has no vocabulary
# of its own before the second candidate starts (0 survivors from that
# candidate), while the SECOND (last) candidate keeps its full window and
# survives — exactly 1 survivor, which the 'window-bleed' rule maps to
# 'decoy-ambiguous'. This is a genuine, ACCEPTED mislabel of what is
# actually a real (if pathologically placed) duplicate — a documented D4
# residual, not a bug the lite scope of issue #817 attempts to fix further.
$script:CloseHeadsGenuineDuplicateResidualBody = @'
<!-- plan-issue-710 -->

**Plan Stress-Test** (5-pass `standard` adapter)

<!-- judge-rulings
<!-- judge-rulings
- finding_id: M2
  judge_ruling: sustained
- finding_id: M1
  judge_ruling: sustained
-->
'@

# T7 (confirmed-correct edge case — mirror ordering, NOT a residual; see M9
# correction below): a bare self-closed decoy mention embedded MID-SENTENCE,
# positioned AFTER a genuine judge-rulings head-OPEN but BEFORE that same
# head's own trailing `finding_id:`/`judge_ruling:` vocabulary. Confirmed:
# exactly 2 real head matches today (the outer head bleeds forward through
# the embedded decoy into its own trailing vocabulary; the embedded decoy
# independently bleeds forward into the same trailing vocabulary), so
# Get-EmissionGap already reports 'head-corrupt' for this body today (M1
# duplicate-head guard, unchanged).
#
# RESOLVED POST-s2 VALUE: this fixture was originally documented (D4) as a
# residual that "keeps head-corrupt" under the forward-only truncation the
# lite scope permits. Tracing the truncated-window re-check as described in
# the plan (each non-last candidate's window truncates at the NEXT
# candidate's start; the last candidate keeps its full window and always
# survives) against THIS specific placement produces exactly 1 survivor
# (the embedded decoy, which is the last candidate here and therefore
# always keeps its untruncated window reaching the trailing vocabulary; the
# outer head's truncated window ends exactly at the decoy's start and
# contains no vocabulary of its own) — the stated rule labels this
# 'window-bleed'/'decoy-ambiguous', not 'head-corrupt'. Code-Conductor
# independently re-traced this fixture, confirmed the mechanical result
# above, and corrected the durable design record (issue #817 body, D4
# section) to match: the "keeps head-corrupt" characterization was wrong
# for this specific placement. No scope, AC, or implementation-algorithm
# change follows from the correction — it is purely a corrected
# characterization of what the already-approved truncated-window algorithm
# actually produces for this fixture. This test now asserts the corrected
# value (Reason -eq 'decoy-ambiguous'), RED today because the
# 'decoy-ambiguous' Reason value does not exist yet (s2 not implemented).
#
# M9 correction (this file, post-#833 review pass): the design record's D4
# section was itself corrected during the plan's Doc-Keeper pass to
# recharacterize this placement as a CONFIRMED-CORRECT edge case, not a
# residual — the truncated-window algorithm produces the intended,
# considered-correct 'decoy-ambiguous' outcome for this shape by design.
# T6 (the close-heads genuine-duplicate placement, above) remains the one
# and only accepted D4 residual; T7 is not a second residual alongside it.
$script:MirrorOrderingConfirmedCorrectBody = @'
<!-- plan-issue-711 -->

**Plan Stress-Test** (5-pass `standard` adapter)

<!-- judge-rulings
This PR uses the standard <!-- judge-rulings --> marker convention for tracking review history, mentioned only in prose here with nothing field-shaped following it before the real fields below.
- finding_id: M1
  judge_ruling: sustained
-->
'@

# Window-edge pin: the decoy's own vocab-gate window reaches the real
# block's vocabulary at exactly 1 char inside the 400-char boundary (bleeds)
# — the filler length below (296 chars) was found by empirical bisection
# against the live $script:JudgeRulingsLookaheadWindow=400 constant: 296
# bleeds (2 real head matches), 297 does not (1 real head match). No
# matching "just outside the window" counterpart is needed here — the
# existing >400-padded GH-3 fixtures already in this file (e.g.
# $script:DecoyBeforeRealPlanStressTestBody) already cover that side.
$script:WindowEdgeFillerLength = 296
$script:WindowEdgeBleedBody = (
    "<!-- plan-issue-712 -->`n`n" +
    "**Plan Stress-Test** (5-pass ``standard`` adapter)`n`n" +
    "This PR uses the standard <!-- judge-rulings --> marker convention for tracking review history.`n" +
    ('x' * $script:WindowEdgeFillerLength) + "`n`n" +
    "<!-- judge-rulings`n" +
    "- finding_id: M1`n" +
    "  judge_ruling: sustained`n" +
    "-->`n"
)

# Before+after arrangement: a bare decoy mention BEFORE a real block, and a
# second bare decoy mention AFTER the real block closes. Confirmed:
# Get-RealJudgeRulingsHeadMatches returns exactly 2 real matches today (the
# before-decoy bleeds forward into the real block and passes; the
# after-decoy has no vocabulary anywhere forward of its own position — the
# real block's vocabulary is now BEHIND it, out of forward-lookahead reach
# — so it does NOT independently pass the vocab gate and is excluded
# entirely, never becoming a third candidate). With only the 2 real
# candidates [before-decoy, real-block], the s2 helper's truncated re-check
# would find: before-decoy's truncated window (ending at the real block's
# start) has no vocabulary of its own -> fails; the real block, being the
# LAST of the 2 candidates, keeps its full window and survives. Exactly 1
# survivor -> 'window-bleed' -> 'decoy-ambiguous'.
$script:DecoyBeforeAndAfterRealBody = @'
<!-- plan-issue-713 -->

**Plan Stress-Test** (5-pass `standard` adapter)

This PR uses the standard <!-- judge-rulings --> marker convention for tracking review history, mentioned here only in prose.

<!-- judge-rulings
- finding_id: M1
  judge_ruling: sustained
-->

Another prose mention of the standard <!-- judge-rulings --> marker convention, appearing after the real block, with nothing field-shaped following it.
'@

#endregion

#region PR #833 judge-sustained follow-up: Get-JudgeRulingsDuplicateDiagnosis fixtures (M2/M4/M10)

$script:M2M4M10PaddingProse = @'
Padding prose to push the next real head well past the 400-character
lookahead window, so the two real heads' vocab-gate windows cannot overlap
each other. This paragraph exists purely as filler text with no
judge-rulings vocabulary of its own, repeated a few times to guarantee
sufficient distance between the two real heads. Padding prose to push the
next real head well past the 400-character lookahead window so the two
heads cannot overlap at all, guaranteeing this is a genuine two-real-head
duplicate rather than a vocab-window collision artifact.
'@

# M2 regression fixture: two GENUINE, well-separated judge-rulings heads,
# where the SECOND head's own real vocabulary sits immediately after a
# `disposition_rationale: |` block scalar's trailing BLANK line. Confirmed
# by direct instrumentation against the live core: Get-RealJudgeRulingsHeadMatches
# returns exactly 2 real candidates (both heads pass the ungated raw vocab
# check the same way $script:TwoRealHeadsBothVocabGatePassingBody's do).
#
# The bug: Get-JudgeRulingsDuplicateDiagnosis's per-candidate survivor check
# (core ~L390-396) tests `$candidate.Index + $vocabMatch.Index` — the
# OVERALL vocab-pattern match's start offset. Because the vocab pattern's
# prefix alternative is `^\s*` and .NET's `\s` class matches newlines, the
# leftmost successful match for the second head's own `judge_ruling:` line
# actually STARTS at the block scalar's trailing blank line (the engine
# backtracks `\s*` across the blank line's newline and the next line's
# leading indentation to reach the "judge_ruling" capture). That blank line
# is itself part of Get-BlockScalarSpans' computed span (a block scalar's
# span includes trailing blank lines), so the match's overall Index falls
# INSIDE the span even though the "judge_ruling" keyword text itself
# (`$vocabMatch.Groups[1].Index`) sits just past the span's end. The second
# head's only real vocabulary is therefore wrongly excluded, survivor count
# drops from 2 to 1, and the diagnosis becomes 'window-bleed' instead of
# 'genuine-duplicate' — Get-EmissionGap then renders Reason 'decoy-ambiguous'
# for what is actually a genuine, well-separated duplicate (violating
# design-final AC3, which requires genuine >=2-real-head duplicates to keep
# 'head-corrupt'). This test is RED until the fix reads the keyword capture
# group's own position instead of the overall match's start.
$script:BlockScalarTrailingBlankLineGenuineDuplicateBody = @'
<!-- plan-issue-715 -->

**Plan Stress-Test** (5-pass `standard` adapter)

<!-- judge-rulings
- finding_id: M1
  judge_ruling: sustained
-->

'@ + $script:M2M4M10PaddingProse + @'

<!-- judge-rulings
- finding_id: M2
  disposition_rationale: |
    This is the rationale filler content that occupies indented
    block-scalar lines explaining the disposition in detail.

  judge_ruling: sustained
-->
'@

# M10 fixture: two real judge-rulings heads whose ENTIRE own field
# vocabulary lives inside a `disposition_rationale: |` block scalar (same
# shape as $script:EmbeddedBlockScalarFakeVocabBody's M1 head, above, but
# applied to BOTH heads instead of just one). Get-RealJudgeRulingsHeadMatches
# still counts both as real candidates (its raw window check does not apply
# the block-scalar exclusion), but Get-JudgeRulingsDuplicateDiagnosis's
# per-candidate block-scalar-aware check correctly excludes both candidates'
# only vocabulary match, leaving 0 survivors for the whole body. This directly
# pins the function's defensive "0 survivors reaches the else branch, returns
# the conservative 'genuine-duplicate' fallback, never throws" behavior
# (previously reachable only indirectly via Get-EmissionGap, never exercised
# by a direct unit test). Expected GREEN today — the fallback is already safe.
$script:BothHeadsBlockScalarOnlyVocabBody = @'
<!-- plan-issue-716 -->

**Plan Stress-Test** (5-pass `standard` adapter)

<!-- judge-rulings
  disposition_rationale: |
    This note mentions a decoy fake vocabulary line below, purely as prose
    content inside a block scalar, testing whether interior vocabulary
    wrongly counts as real.
    judge_ruling: sustained
-->

'@ + $script:M2M4M10PaddingProse + @'

<!-- judge-rulings
  disposition_rationale: |
    This note also mentions a decoy fake vocabulary line below, purely as
    prose content inside a block scalar, testing whether interior
    vocabulary wrongly counts as real.
    judge_ruling: sustained
-->
'@

#endregion

#region GH-2 (PR #853 review, judge-sustained): near-decoy window-bleed onto an independently-corrupt real head

# GH-2 fixture: the SAME near-decoy shape as $script:NearDecoyPlanStressTestBody
# (T1, ~L691 above) — a bare-prose decoy mention of the `<!-- judge-rulings -->`
# convention sitting well under the 400-char lookahead window before a real
# judge-rulings block — but the REAL block's own `judge_ruling:` field value
# is itself invalid (`maybe-sustained-ish`, not the closed 2-value enum
# `sustained`/`defense-sustained` per skills/review-judgment/SKILL.md:156).
#
# The bug: Get-JudgeRulingsDuplicateDiagnosis's per-candidate survivor check
# (core ~L404) only re-runs $script:JudgeRulingsVocabGatePattern, which tests
# for the KEY token's presence (`judge_ruling\s*:`) and never validates the
# captured VALUE. The real block's own truncated/untruncated window still
# contains a `judge_ruling:` key match regardless of the malformed value, so
# it "survives" the truncated re-check exactly as a well-formed real block
# would. Survivor count is 1 (the decoy's truncated window has no vocabulary
# of its own) -> 'window-bleed' -> Get-EmissionGap reports Reason
# 'decoy-ambiguous'. That is the wrong diagnosis: removing the decoy would
# NOT fix this body — the surviving block is independently corrupt
# (Get-SustainedFindingCount's own `$hasJudgeRuling` branch, core ~L1307-1314,
# already treats an unrecognized `judge_ruling:` value as could-not-verify on
# its own). The correct Reason is 'head-corrupt', not 'decoy-ambiguous'.
#
# Confirmed: Get-RealJudgeRulingsHeadMatches returns exactly 2 candidates for
# this body (the decoy and the malformed real head both pass the KEY-only
# vocab gate), the same bleed-confirmation shape as T1/T2 above.
$script:NearDecoyMalformedRealHeadBody = @'
<!-- plan-issue-819 -->

**Plan Stress-Test** (5-pass `standard` adapter)

This PR uses the standard <!-- judge-rulings --> marker convention for tracking review history, mentioned here only as ordinary narrative text.

<!-- judge-rulings
- finding_id: M1
  judge_ruling: maybe-sustained-ish
-->
'@

# GH-2 companion baseline: the SAME independently-corrupt real block, with NO
# decoy mention preceding it (1 real head only). Get-RealJudgeRulingsHeadMatches
# returns exactly 1 candidate, so the 2+-real-heads duplicate-head guard never
# fires and Get-JudgeRulingsDuplicateDiagnosis is never invoked for this body
# — Get-EmissionGap's could-not-verify/hasRealHead-but-not->=2-heads branch
# (core ~L1540-1547) directly attributes 'head-corrupt'. This is the
# existing, already-correct baseline the GH-2 RED test above contrasts
# against.
$script:MalformedRealHeadNoDecoyBody = @'
<!-- plan-issue-819 -->

**Plan Stress-Test** (5-pass `standard` adapter)

<!-- judge-rulings
- finding_id: M1
  judge_ruling: maybe-sustained-ish
-->
'@

#endregion

#region 811-D1 s4: writer-contract round-trip fixtures (skills/plan-authoring/SKILL.md)

# Round-trip fixture: exercises the SKILL's "one entry per merged finding_id"
# writer rule directly — an aggregate prose bullet "M10-M13, M16 - sustained"
# must expand into 5 separate judge_ruling: sustained entries, plus one
# defense-sustained entry (M17) covering "everything else" per the binary
# projection rule. Proves the writer contract's expansion + projection is
# actually parseable by the live reader, not merely asserted in prose.
$script:WriterContractExpandedBody = @'
<!-- plan-issue-9101 -->

## Plan: Writer-contract round-trip fixture (#9101)

**Plan Stress-Test** (5-pass `standard` adapter: 2 generalist + 3 specialist -> defense -> judge)

- Challenge M10-M13, M16 (aggregate prose bullet) - Post-judge ruling: **sustained** - Maintainer disposition: **incorporate**.
- Challenge M17 (defense-sustained) - Post-judge ruling: **defense-sustained** - Maintainer disposition: **dismiss**.
- Overall confidence: **medium** - fixture only.

<!-- judge-rulings
- finding_id: M10
  judge_ruling: sustained
- finding_id: M11
  judge_ruling: sustained
- finding_id: M12
  judge_ruling: sustained
- finding_id: M13
  judge_ruling: sustained
- finding_id: M16
  judge_ruling: sustained
- finding_id: M17
  judge_ruling: defense-sustained
-->
'@

# Zero-findings placeholder fixture: the exact pinned two-line shape from the
# SKILL's writer rule 7. Must parse to SustainedCount=0, ParseStatus=ok (a
# true clean result), never could-not-verify.
$script:WriterContractZeroFindingsBody = @'
<!-- plan-issue-9102 -->

## Plan: Writer-contract zero-findings fixture (#9102)

**Plan Stress-Test** (5-pass `standard` adapter)

- Overall confidence: **high** - no findings survived prosecution.

<!-- judge-rulings
- finding_id: none
  judge_ruling: defense-sustained
-->
'@

# Prose-mention fixture: a plan-authoring-shaped body whose narrative mentions
# the judge-rulings marker convention using the SKILL's inert-rendering
# guidance (rule 5 — inside a code span, not a live, parser-visible head).
# The real block (with its own short, vocab-free in-block comment, rule 6)
# must still parse correctly; the prose mention must not hijack the region
# isolation or get miscounted as a second head.
$script:WriterContractProseMentionBody = @'
<!-- plan-issue-9103 -->

## Plan: Writer-contract prose-mention fixture (#9103)

**Plan Stress-Test** (5-pass `standard` adapter)

- Note: this plan persists its rulings using the `<!-- judge-rulings` marker convention (mentioned here only as inert text inside a code span).
- Challenge A1 (fixture finding) - Post-judge ruling: **sustained** - Maintainer disposition: **incorporate**.
- Overall confidence: **high** - fixture only.

<!-- judge-rulings
- finding_id: A1
  judge_ruling: sustained
-->
'@

#endregion

#region Fixtures: Get-DispositionTally — review-dispositions marker (issue #768 s3)

# Basic joint-projection fixture: 3 entries spanning v1 (no severity/stage/
# reviewer_source), v2 (severity+stage, no reviewer_source), and v3
# (severity+stage+reviewer_source) shapes in one body — proves mixed
# v1/v2/v3 payloads parse together and the v1 entry's absent stage defaults
# to 'code-review'.
$script:ReviewDispositionsBasicBody = @'
Some PR chatter above the marker.

<!-- review-dispositions-900 -->

```yaml
schema_version: 3
passes_run: [1, 2]
entries:
  - stable_finding_key: "file.ps1:10:abc123"
    pass: 1
    disposition: incorporate
    classification: routine
    severity: medium
    stage: code-review
    reviewer_source: local
    disposition_rationale: "Fixed inline."
  - stable_finding_key: "file.ps1:22:def456"
    pass: 2
    disposition: dismiss
    classification: routine
    severity: low
    stage: code-review
    reviewer_source: gemini
    disposition_rationale: "Not applicable."
  - stable_finding_key: "file.ps1:33:ghi789"
    pass: 1
    disposition: defer
    classification: routine
    disposition_rationale: "Partial AC match, deferred (v1 shape: no severity/stage/reviewer_source)."
```
'@

# stage: ce exclusion fixture: one code-review entry, one ce entry. Only the
# code-review entry should survive Get-DispositionTally's stage filter.
$script:ReviewDispositionsStageCeExclusionBody = @'
<!-- review-dispositions-901 -->

```yaml
schema_version: 2
passes_run: [1]
entries:
  - stable_finding_key: "a.ps1:1:aaa"
    pass: 1
    disposition: incorporate
    classification: routine
    severity: medium
    stage: code-review
    disposition_rationale: "Real code-review entry."
  - stable_finding_key: "a.ps1:2:bbb"
    pass: 1
    disposition: dismiss
    classification: routine
    severity: low
    stage: ce
    disposition_rationale: "CE Gate defect deferral entry, must be excluded from the code-review surface."
```
'@

# Decoy 1 (M3/collision guard): a v2 entry carrying a nested
# ac_cross_check.source field. Must NOT be misread as reviewer_source — it is
# a different key entirely, not merely a position collision. This entry has
# no reviewer_source field of its own, so ReviewerSource must come back null.
$script:ReviewDispositionsAcCrossCheckSourceDecoyBody = @'
<!-- review-dispositions-902 -->

```yaml
schema_version: 2
passes_run: [1]
entries:
  - stable_finding_key: "b.ps1:5:ccc"
    pass: 1
    disposition: dismiss
    classification: routine
    severity: medium
    stage: code-review
    disposition_rationale: "No AC match found."
    ac_cross_check:
      file_arm: false
      term_arm: true
      result: no-match
      source: issue
      routed: defer
```
'@

# Decoy 2 (M3/decoy hardening): disposition_rationale is a block scalar whose
# text quotes the literal substring "disposition: dismiss" describing a
# DIFFERENT, unrelated finding's history in prose. The real disposition
# (incorporate) is written first per field order, so the first-key-anchored-
# match rule must return incorporate, never let the rationale's embedded text
# inflate/flip the count.
$script:ReviewDispositionsRationaleBlockScalarDecoyBody = @'
<!-- review-dispositions-903 -->

```yaml
schema_version: 3
passes_run: [1]
entries:
  - stable_finding_key: "c.ps1:8:ddd"
    pass: 1
    disposition: incorporate
    classification: routine
    severity: medium
    stage: code-review
    reviewer_source: local
    disposition_rationale: |
      Distinct from the earlier finding on this same file where
      disposition: dismiss was chosen; this one was kept and fixed inline.
```
'@

# Decoy 3 (M3/decoy hardening): reviewer_source's value carries an injected
# raw newline followed by a fake "disposition: dismiss" fragment. Must not be
# split into a phantom second entry (entry boundaries are anchored to
# `- stable_finding_key:` / `- finding_id:` only), and must not corrupt the
# real disposition already matched earlier in the same entry.
$script:ReviewDispositionsInjectedNewlineDecoyBody = @'
<!-- review-dispositions-904 -->

```yaml
schema_version: 3
passes_run: [1]
entries:
  - stable_finding_key: "d.ps1:12:eee"
    pass: 1
    disposition: incorporate
    classification: routine
    severity: low
    stage: code-review
    reviewer_source: "x
  disposition: dismiss"
    disposition_rationale: "Fixed inline."
```
'@

# Decoy 4 (M3/decoy hardening): a prose mention of the marker convention with
# no real block anywhere in the body. Must return could-not-verify, never be
# miscounted as a real entry.
$script:ReviewDispositionsProseMentionOnlyBody = @'
This PR uses the standard `<!-- review-dispositions-905 -->` marker
convention for tracking review dispositions, same as every other PR in this
repo. No YAML payload is attached to this particular chatter comment.
'@

# Fail-loud: ordinary PR chatter with no review-dispositions mention at all.
$script:ReviewDispositionsNoMarkerBody = @'
LGTM, thanks for the fix!
'@

# Fail-loud: a real, vocab-gate-passing head with a fenced YAML block that
# carries zero segmentable entries (e.g. an `entries: []` payload). Zero
# entries means zero data to isolate, not a confident empty result.
$script:ReviewDispositionsZeroEntriesBody = @'
<!-- review-dispositions-906 -->

```yaml
schema_version: 3
passes_run: [1]
entries: []
```
'@

# CM1 regression (judge-sustained PR #833 review): the entry-boundary
# pattern (`- stable_finding_key:` / `- finding_id:`) previously matched
# those literal boundary keys even when they appeared INSIDE a
# `disposition_rationale: |` block-scalar's indented content, fabricating a
# phantom SECOND entry with attacker-controlled disposition/reviewer_source
# values. This 1-entry marker's single entry's disposition_rationale is a
# block scalar containing an embedded `- finding_id: PHANTOM1` line; it must
# parse as exactly 1 entry, never 2.
$script:ReviewDispositionsBlockScalarPhantomEntryBody = @'
<!-- review-dispositions-910 -->

```yaml
schema_version: 3
passes_run: [1]
entries:
  - stable_finding_key: "e.ps1:1:fff"
    pass: 1
    disposition: incorporate
    classification: routine
    severity: medium
    stage: code-review
    reviewer_source: local
    disposition_rationale: |
      Related discussion referenced another finding inline:
      - finding_id: PHANTOM1
        disposition: escalate
        reviewer_source: attacker
```
'@

# CM12 defensive fail-loud (judge-sustained PR #833 review): a legitimate
# (non-phantom) entry using the `- finding_id:` boundary key with no
# `stable_finding_key:` field at all must route to could-not-verify on the
# code-review surface rather than silently participating with an empty
# StableFindingKey.
$script:ReviewDispositionsFindingIdOnlyNoStableKeyBody = @'
<!-- review-dispositions-911 -->

```yaml
schema_version: 3
passes_run: [1]
entries:
  - finding_id: "legacy-id-without-stable-key"
    pass: 1
    disposition: incorporate
    classification: routine
    severity: medium
    stage: code-review
    reviewer_source: local
    disposition_rationale: "Legacy shape lacking stable_finding_key."
```
'@

# CM7 regression (judge-sustained PR #833 review): a double-quoted YAML
# stage value ("code-review") must still pass the code-review stage filter
# instead of being silently dropped (indistinguishable from an intentional
# `stage: ce` exclusion).
$script:ReviewDispositionsQuotedStageBody = @'
<!-- review-dispositions-920 -->

```yaml
schema_version: 3
passes_run: [1]
entries:
  - stable_finding_key: "i.ps1:1:iii"
    pass: 1
    disposition: incorporate
    classification: routine
    severity: medium
    stage: "code-review"
    reviewer_source: local
    disposition_rationale: "Quoted stage value must still pass the stage filter."
```
'@

# CM7 regression (judge-sustained PR #833 review): a single-quoted
# reviewer_source value must dequote to the SAME group as its bare
# equivalent, not form a phantom distinct per-source row.
$script:ReviewDispositionsQuotedReviewerSourceBody = @'
<!-- review-dispositions-921 -->

```yaml
schema_version: 3
passes_run: [1]
entries:
  - stable_finding_key: "j.ps1:1:jjj"
    pass: 1
    disposition: incorporate
    classification: routine
    severity: medium
    stage: code-review
    reviewer_source: 'copilot'
    disposition_rationale: "Single-quoted reviewer_source must dequote to the bare value."
  - stable_finding_key: "j.ps1:2:jjj2"
    pass: 1
    disposition: dismiss
    classification: routine
    severity: low
    stage: code-review
    reviewer_source: copilot
    disposition_rationale: "Bare reviewer_source, same logical source as the quoted entry above."
```
'@

# Near-decoy window-bleed regression (issue #817 sibling bug, folded into
# this PR): the FIRST entry's disposition_rationale is a `|` block scalar
# immediately followed by a BLANK LINE, and the SECOND entry's real
# `- stable_finding_key:` dash-item starts right after that blank line.
# Get-BlockScalarSpans extends the first entry's block-scalar span through
# the trailing blank line; the entry-boundary regex's `^\s*` prefix can
# match starting from that blank line (a valid multiline `^` position) and
# consume the newline plus the second entry's own leading indentation before
# reaching its `-`, so the overall match's `.Index` lands inside the
# extended span even though the actual `- stable_finding_key:` keyword
# itself sits just outside it. This is the same match-start-vs-keyword-
# position bug issue #817's M2 fix corrected in
# Get-JudgeRulingsDuplicateDiagnosis, now found in the sibling
# Get-ReviewDispositionsTallyInternal entry-boundary detector. Both entries
# are genuine and must be returned; the second must never be silently
# dropped.
$script:ReviewDispositionsNearDecoyWindowBleedBody = @'
<!-- review-dispositions-930 -->

```yaml
schema_version: 3
passes_run: [1]
entries:
  - stable_finding_key: "k.ps1:1:kkk"
    pass: 1
    disposition: incorporate
    classification: routine
    severity: medium
    stage: code-review
    reviewer_source: local
    disposition_rationale: |
      Fixed inline after discussion.

  - stable_finding_key: "k.ps1:2:lll"
    pass: 1
    disposition: dismiss
    classification: routine
    severity: low
    stage: code-review
    reviewer_source: local
    disposition_rationale: "Not applicable."
```
'@

#endregion

}

Describe 'Get-SustainedFindingCount - code-review surface (live fixtures)' {
    It 'counts 2 sustained for PR #775 (intake-mode, accept/accept/reject, required_fixes decoy excluded)' {
        $result = Get-SustainedFindingCount -Surface 'code-review' -Body $script:Pr775Body
        $result.ParseStatus | Should -Be 'ok'
        $result.SustainedCount | Should -Be 2
    }

    It 'counts 10 sustained for PR #778 (attributed head, four-value not-Dismiss rule, Defer counts as sustained)' {
        $result = Get-SustainedFindingCount -Surface 'code-review' -Body $script:Pr778Body
        $result.ParseStatus | Should -Be 'ok'
        $result.SustainedCount | Should -Be 10
    }

    It 'counts 4 sustained for PR #781 (bare head, judge_ruling: sustained x4, defense-sustained x1 excluded)' {
        $result = Get-SustainedFindingCount -Surface 'code-review' -Body $script:Pr781Body
        $result.ParseStatus | Should -Be 'ok'
        $result.SustainedCount | Should -Be 4
    }
}

Describe 'Get-SustainedFindingCount - design-challenge surface (live fixture)' {
    It 'counts 6 sustained for the live #782 design block (all entries incorporate)' {
        $result = Get-SustainedFindingCount -Surface 'design-challenge' -Body $script:Design782Body
        $result.ParseStatus | Should -Be 'ok'
        $result.SustainedCount | Should -Be 6
    }

    It 'counts 2 sustained when disposition is incorporate/escalate/dismiss (dismiss excluded)' {
        $result = Get-SustainedFindingCount -Surface 'design-challenge' -Body $script:DesignDismissBody
        $result.ParseStatus | Should -Be 'ok'
        $result.SustainedCount | Should -Be 2
    }
}

Describe 'Get-SustainedFindingCount - GH-5 regression: key-position anchoring on design-challenge disposition detector' {
    It 'does not mis-count a free-text disposition_rationale substring as a real finding (judge-required regression test)' {
        # Pre-fix, the unanchored regex matched the prose substring
        # "disposition: incorporate" inside disposition_rationale in addition
        # to the one real "disposition: dismiss" finding, yielding
        # SustainedCount=1 instead of the correct 0.
        $result = Get-SustainedFindingCount -Surface 'design-challenge' -Body $script:GH5DesignChallengeProseSubstringBody
        $result.ParseStatus | Should -Be 'ok'
        $result.SustainedCount | Should -Be 0
    }
}

Describe 'Get-SustainedFindingCount - plan-stress-test surface (by-analogy fixture)' {
    It 'counts 2 sustained (judge_ruling: sustained x2, defense-sustained x1 excluded)' {
        $result = Get-SustainedFindingCount -Surface 'plan-stress-test' -Body $script:PlanStressTestBody
        $result.ParseStatus | Should -Be 'ok'
        $result.SustainedCount | Should -Be 2
    }
}

Describe 'Get-SustainedFindingCount - zero-sustained (silent per S2)' {
    It 'returns SustainedCount 0 and ParseStatus ok when marker present but all findings are defense-sustained' {
        $result = Get-SustainedFindingCount -Surface 'code-review' -Body $script:ZeroSustainedBody
        $result.ParseStatus | Should -Be 'ok'
        $result.SustainedCount | Should -Be 0
    }
}

Describe 'Get-SustainedFindingCount - fail-loud paths (DD3)' {
    It 'returns could-not-verify when no judge-rulings or finding_dispositions marker exists' {
        $result = Get-SustainedFindingCount -Surface 'code-review' -Body $script:MalformedBody
        $result.ParseStatus | Should -Be 'could-not-verify'
    }

    It 'returns could-not-verify when the marker head is present but disposition vocabulary is unrecognized' {
        $result = Get-SustainedFindingCount -Surface 'code-review' -Body $script:UnknownVocabularyBody
        $result.ParseStatus | Should -Be 'could-not-verify'
    }

    It 'returns could-not-verify for an empty body' {
        $result = Get-SustainedFindingCount -Surface 'code-review' -Body ''
        $result.ParseStatus | Should -Be 'could-not-verify'
    }

    It 'never treats could-not-verify as zero: SustainedCount is not asserted meaningful, only ParseStatus gates gap treatment' {
        $result = Get-SustainedFindingCount -Surface 'design-challenge' -Body $script:MalformedBody
        $result.ParseStatus | Should -Be 'could-not-verify'
    }
}

Describe 'Get-SustainedFindingCount - M3 regression: line-start anchoring on disposition detectors' {
    It 'does not mis-trigger or under-count when free-text prose contains the substring "disposition: Dismiss" (judge-required regression test)' {
        # Pre-fix, unanchored `(?m)disposition\s*:\s*Dismiss\b` etc. could match
        # inside indented prose (a summary: string), not just at true YAML
        # line-start. This body has 2 REAL structured Fix-now dispositions and
        # a prose mention of the "disposition: Dismiss" substring buried in a
        # summary string. The real sustained count (2) must survive: no silent
        # Sustained=0, no ParseStatus regression.
        $result = Get-SustainedFindingCount -Surface 'code-review' -Body $script:M3DismissSubstringInProseBody
        $result.ParseStatus | Should -Be 'ok'
        $result.SustainedCount | Should -Be 2
    }
}

Describe 'Test-EmissionMarkerPresent / Get-EmissionGap - PF-F2 regression: dash-space YAML block-sequence key position' {
    It 'Test-EmissionMarkerPresent returns true for a body whose only vocabulary tokens are dash-space "- disposition:" list items (no plain line-start field, no flow-mapping)' {
        # Pre-fix, $keyAnchor-equivalent '(?:^\s*|[{,]\s*)' did not recognize
        # a YAML block-sequence item's key as being in key position when the
        # only thing preceding it on the line was a `- ` dash-space list
        # marker (not whitespace alone, not `{`/`,`). A body whose only
        # field tokens are dash-space `- disposition:` items therefore
        # failed this vocab gate entirely, so Get-EmissionGap treated the
        # whole body as ordinary chatter and silently skipped it.
        $body = @'
<!-- judge-rulings
findings:
  - disposition: Fix-now
  - disposition: Dismiss
-->
'@
        Test-EmissionMarkerPresent -Surface 'code-review' -Body $body | Should -Be $true
    }

    It 'Get-EmissionGap counts the real Fix-now finding (not a silent Gap=0/ok false-clean) for a dash-space-only judge-rulings body' {
        # THE required PF-F2 regression test. Before the fix this body
        # produced Gap=0/ParseStatus=ok (a silent false-clean, DD3
        # violation) because Test-EmissionMarkerPresent's vocab gate never
        # recognized the dash-space "- disposition:" tokens, so
        # Get-EmissionGap skipped the body as ordinary chatter and never
        # even called Get-SustainedFindingCount on it. After the fix, the
        # body is recognized as a real judge-rulings surface and the one
        # real Fix-now finding is counted; Dismiss is correctly excluded.
        $body = @'
<!-- judge-rulings
findings:
  - disposition: Fix-now
  - disposition: Dismiss
-->
'@
        $result = Get-EmissionGap -Bodies @($body) -Id 1 -Surface 'code-review'
        $result.ParseStatus | Should -Be 'ok'
        $result.SustainedCount | Should -Be 1
        $result.BlockCount | Should -Be 0
        $result.Gap | Should -Be 1
    }
}

Describe 'Get-SustainedFindingCount - decoy resistance (M3)' {
    It 'does not count prose ACCEPT badges or table Sustained columns outside the marker region' {
        # PR #775's table has 2 uppercase "✅ ACCEPT" badges and PR #778's table
        # has 8 "Sustained" table-cell strings — neither equals the YAML-region count.
        $result775 = Get-SustainedFindingCount -Surface 'code-review' -Body $script:Pr775Body
        $result775.SustainedCount | Should -Be 2

        $result778 = Get-SustainedFindingCount -Surface 'code-review' -Body $script:Pr778Body
        $result778.SustainedCount | Should -Not -Be 8
        $result778.SustainedCount | Should -Be 10
    }

    It 'excludes required_fixes: parallel list entries from the sustained count' {
        # PR #775's required_fixes: list has 2 `id:` entries (GF-1, GF-2) that
        # must not double-count against the findings: list's 2 accepts.
        $result = Get-SustainedFindingCount -Surface 'code-review' -Body $script:Pr775Body
        $result.SustainedCount | Should -Be 2
    }
}

Describe 'Test-EmissionMarkerPresent - marker head detection' {
    It 'returns true for a code-review body with a bare judge-rulings head' {
        Test-EmissionMarkerPresent -Surface 'code-review' -Body $script:Pr781Body | Should -Be $true
    }

    It 'returns true for a code-review body with an attributed judge-rulings head' {
        Test-EmissionMarkerPresent -Surface 'code-review' -Body $script:Pr778Body | Should -Be $true
    }

    It 'returns false for ordinary PR chatter with no marker head' {
        Test-EmissionMarkerPresent -Surface 'code-review' -Body $script:MalformedBody | Should -Be $false
    }

    It 'returns true when the marker head is present even if the content ultimately fails to parse (head presence only, not content validity)' {
        Test-EmissionMarkerPresent -Surface 'code-review' -Body $script:UnknownVocabularyBody | Should -Be $true
    }

    It 'returns true for a design-challenge body with a finding_dispositions key' {
        Test-EmissionMarkerPresent -Surface 'design-challenge' -Body $script:Design782Body | Should -Be $true
    }

    It 'returns false for an empty body' {
        Test-EmissionMarkerPresent -Surface 'code-review' -Body '' | Should -Be $false
    }
}

Describe 'Test-EmissionMarkerPresent - M6 regression: bare prose mention does not force could-not-verify' {
    It 'returns false for a docs-style prose sentence that mentions the judge-rulings marker syntax but anchors no parseable region' {
        # A maintainer describing the marker convention in ordinary prose
        # (e.g. a comment explaining "this PR uses the standard
        # <!-- judge-rulings pr=N --> marker") is not a real judge-rulings
        # surface. Pre-fix, the bare head-substring match alone returned
        # true, which forced Get-SustainedFindingCount to be called and fail
        # to parse -> could-not-verify, poisoning an otherwise-clean PR's
        # whole aggregate even though the real judge comment elsewhere on
        # the same PR parses fine.
        $body = 'This PR uses the standard <!-- judge-rulings pr=N --> marker convention for tracking review dispositions. See the skill docs for details.'
        Test-EmissionMarkerPresent -Surface 'code-review' -Body $body | Should -Be $false
    }

    It 'still returns true for a real head immediately followed by recognizable disposition/verdict vocabulary (no regression on live shapes)' {
        # All 3 live PR fixtures (#775, #778, #781) and the design/plan
        # fixtures must keep returning true — covered by the pre-existing
        # tests in this Describe block. This test locks in the bare
        # self-closing-head-with-immediate-YAML-follow shape specifically.
        $body = "<!-- judge-rulings pr=50 -->`njudge_ruling: sustained`n-->"
        Test-EmissionMarkerPresent -Surface 'code-review' -Body $body | Should -Be $true
    }

    It 'returns false for a design-challenge body where finding_dispositions: appears in an unrelated code snippet with no entries following' {
        $body = @'
Here is an example schema key name for reference: `finding_dispositions:` is
used by the design-challenge surface. This comment does not itself contain
any real disposition entries.
'@
        Test-EmissionMarkerPresent -Surface 'design-challenge' -Body $body | Should -Be $false
    }
}

Describe 'Test-EmissionMarkerPresent / Get-SustainedFindingCount - M9 regression: superstring marker names do not false-match' {
    It 'Test-EmissionMarkerPresent returns false for a body carrying only a differently-named judge-rulings-report marker, even with real-looking vocabulary following it' {
        # \b is a non-word boundary; a hyphen immediately after 'judge-rulings'
        # is ALSO a non-word character, so the bare \b-anchored regex matched
        # a completely different, unrelated marker name
        # ('<!-- judge-rulings-report -->') as if it were the real
        # judge-rulings head. This is not fully defeated by the M6
        # vocabulary-lookahead fix alone: when the unrelated marker's body
        # legitimately contains a judge_ruling: line on its own (e.g. a
        # differently-scoped report that happens to embed review vocabulary),
        # M6's lookahead check is satisfied and the false head-match still
        # goes through. Tightened separately: the head must be followed by
        # whitespace, the attributed 'pr=' token, or the closing '-->' —
        # never an unrelated identifier character run like '-report'.
        $body = @'
<!-- judge-rulings-report -->
judge_ruling: sustained
-->
'@
        Test-EmissionMarkerPresent -Surface 'code-review' -Body $body | Should -Be $false
    }

    It 'Get-SustainedFindingCount still returns could-not-verify (not a false head-match) for a judge-rulings-report-only body' {
        $body = @'
<!-- judge-rulings-report -->
judge_ruling: sustained
-->
'@
        $result = Get-SustainedFindingCount -Surface 'code-review' -Body $body
        $result.ParseStatus | Should -Be 'could-not-verify'
    }

    It 'still matches the real bare head shape (no regression on live fixtures)' {
        Test-EmissionMarkerPresent -Surface 'code-review' -Body $script:Pr781Body | Should -Be $true
        Test-EmissionMarkerPresent -Surface 'code-review' -Body $script:Pr778Body | Should -Be $true
    }
}

Describe '811-D1: Test-EmissionMarkerPresent plan-stress-test honest fallback' {
    It 'returns true for a prose-only plan-issue comment (marker + heading, no judge-rulings head at all)' {
        Test-EmissionMarkerPresent -Surface 'plan-stress-test' -Body $script:ProseOnlyPlanStressTestBody | Should -Be $true
    }

    It 'returns false for chatter mentioning the heading in prose with no plan-issue marker (both conditions required together)' {
        Test-EmissionMarkerPresent -Surface 'plan-stress-test' -Body $script:ChatterMentioningHeadingNoMarkerBody | Should -Be $false
    }

    It 'does not fire the fallback for the code-review surface even with the same prose-only shape (surface-scoped only)' {
        Test-EmissionMarkerPresent -Surface 'code-review' -Body $script:ProseOnlyPlanStressTestBody | Should -Be $false
    }

    It 'still returns true for the real machine judge-rulings shape (vocab gate satisfied directly, fallback not needed)' {
        Test-EmissionMarkerPresent -Surface 'plan-stress-test' -Body $script:PlanStressTestBody | Should -Be $true
    }

    It 'returns true when a present-but-malformed head co-occurs with the plan-issue marker and heading (fallback keys off the vocab gate, not a raw head re-test)' {
        Test-EmissionMarkerPresent -Surface 'plan-stress-test' -Body $script:CorruptHeadWithPlanIssueMarkerBody | Should -Be $true
    }

    # GH-4 (PR #815 review): this fixture's own in-code comment promises
    # "Get-SustainedFindingCount must independently fail loud on this body
    # too," but only the Test-EmissionMarkerPresent assertion above ever
    # existed. Adding the missing assertion here, directly alongside it.
    It 'Get-SustainedFindingCount independently fails loud (could-not-verify) on the same present-but-malformed-head body' {
        $result = Get-SustainedFindingCount -Surface 'plan-stress-test' -Body $script:CorruptHeadWithPlanIssueMarkerBody
        $result.ParseStatus | Should -Be 'could-not-verify'
    }
}

Describe '811-D1: Get-SustainedFindingCount fail-loud on duplicate judge-rulings heads (M1)' {
    It 'returns could-not-verify (not a count) when two judge-rulings heads exist in one body' {
        $result = Get-SustainedFindingCount -Surface 'plan-stress-test' -Body $script:DuplicateJudgeRulingsHeadsBody
        $result.ParseStatus | Should -Be 'could-not-verify'
    }

    It 'still returns ok for a single-head body (no false-positive duplicate detection)' {
        $result = Get-SustainedFindingCount -Surface 'plan-stress-test' -Body $script:PlanStressTestBody
        $result.ParseStatus | Should -Be 'ok'
    }

    It 'returns could-not-verify for a prose-only plan-issue body (no real head at all)' {
        $result = Get-SustainedFindingCount -Surface 'plan-stress-test' -Body $script:ProseOnlyPlanStressTestBody
        $result.ParseStatus | Should -Be 'could-not-verify'
    }

    It 'M1 fix regression: a bare prose mention of the marker convention co-occurring with one real head still parses ok, not could-not-verify' {
        $result = Get-SustainedFindingCount -Surface 'plan-stress-test' -Body $script:ProseMentionPlusOneRealHeadBody
        $result.ParseStatus | Should -Be 'ok'
        $result.SustainedCount | Should -Be 1
    }

    It 'M1 still fails loud when BOTH heads are vocab-gate-passing (genuine 2+ real heads, no regression from the GH-3 fix)' {
        $result = Get-SustainedFindingCount -Surface 'plan-stress-test' -Body $script:TwoRealHeadsBothVocabGatePassingBody
        $result.ParseStatus | Should -Be 'could-not-verify'
    }
}

Describe 'GH-3 (PR #815 review): decoy-before-real-block no longer suppresses the real block' {
    It 'plan-stress-test: a vocab-gate-failing decoy head before a real bare block now parses to the TRUE sustained count, not could-not-verify' {
        $result = Get-SustainedFindingCount -Surface 'plan-stress-test' -Body $script:DecoyBeforeRealPlanStressTestBody
        $result.ParseStatus | Should -Be 'ok'
        $result.SustainedCount | Should -Be 2
    }

    It 'code-review: Test-EmissionMarkerPresent returns true for the same decoy-before-real-block shape (no longer a silent skip-as-chatter)' {
        Test-EmissionMarkerPresent -Surface 'code-review' -Body $script:DecoyBeforeRealCodeReviewBody | Should -Be $true
    }

    It 'code-review: the resulting sustained count is the TRUE count, not a silent 0' {
        $result = Get-SustainedFindingCount -Surface 'code-review' -Body $script:DecoyBeforeRealCodeReviewBody
        $result.ParseStatus | Should -Be 'ok'
        $result.SustainedCount | Should -Be 2
    }

    It 'code-review: Get-EmissionGap no longer silently reports Gap=0/ok for a body carrying a real sustained block behind a decoy head' {
        $result = Get-EmissionGap -Bodies @($script:DecoyBeforeRealCodeReviewBody) -Id 815 -Surface 'code-review'
        $result.ParseStatus | Should -Be 'ok'
        $result.SustainedCount | Should -Be 2
    }

    It 'existing attributed-vs-bare preference is preserved when an attributed real head is present (no decoy interaction, regression check)' {
        $result = Get-SustainedFindingCount -Surface 'code-review' -Body $script:Pr778Body
        $result.ParseStatus | Should -Be 'ok'
        Test-EmissionMarkerPresent -Surface 'code-review' -Body $script:Pr778Body | Should -Be $true
    }
}

Describe 'GH-1 (PR #815 review, rider on GH-3): hasRealHead no longer misclassifies a decoy as a real head' {
    It 'reports Reason head-missing (not head-corrupt) for a plan-stress-test body whose ONLY head is a vocab-gate-failing decoy (honest fallback fired, no real head at all)' {
        $result = Get-EmissionGap -Bodies @($script:CorruptHeadWithPlanIssueMarkerBody) -Id 702 -Surface 'plan-stress-test'
        $result.ParseStatus | Should -Be 'could-not-verify'
        $result.Reason | Should -Be 'head-missing'
    }
}

Describe '811-D1: Get-EmissionGap Reason field (head-missing vs head-corrupt vs ok)' {
    It 'reports Reason head-missing for a prose-only plan-issue comment (fallback fired, no real head)' {
        $result = Get-EmissionGap -Bodies @($script:ProseOnlyPlanStressTestBody) -Id 700 -Surface 'plan-stress-test'
        $result.ParseStatus | Should -Be 'could-not-verify'
        $result.Reason | Should -Be 'head-missing'
    }

    It 'reports Reason head-corrupt for a body with a real judge-rulings head that fails to parse' {
        $result = Get-EmissionGap -Bodies @($script:UnknownVocabularyBody) -Id 999 -Surface 'plan-stress-test'
        $result.ParseStatus | Should -Be 'could-not-verify'
        $result.Reason | Should -Be 'head-corrupt'
    }

    It 'reports Reason head-corrupt for duplicate judge-rulings heads (a real head is present, just ambiguous)' {
        $result = Get-EmissionGap -Bodies @($script:DuplicateJudgeRulingsHeadsBody) -Id 701 -Surface 'plan-stress-test'
        $result.ParseStatus | Should -Be 'could-not-verify'
        $result.Reason | Should -Be 'head-corrupt'
    }

    It 'reports Reason ok when the aggregate parses cleanly' {
        $result = Get-EmissionGap -Bodies @($script:PlanStressTestBody) -Id 811 -Surface 'plan-stress-test'
        $result.ParseStatus | Should -Be 'ok'
        $result.Reason | Should -Be 'ok'
    }

    It 'reports Reason ok for the code-review surface aggregation (Reason field is additive, existing surfaces unaffected)' {
        $result = Get-EmissionGap -Bodies @($script:Pr775Body) -Id 775 -Surface 'code-review'
        $result.ParseStatus | Should -Be 'ok'
        $result.Reason | Should -Be 'ok'
    }
}

Describe 'Issue #817 (PF-F1) T1/T2: near-decoy window-bleed produces a false head-corrupt today' {
    It 'T1 (plan-stress-test) diagnostic: the decoy and the real head both pass the vocab gate (bleed confirmed, GREEN today)' {
        $realHeads = Get-RealJudgeRulingsHeadMatches -Body $script:NearDecoyPlanStressTestBody
        $realHeads.Count | Should -Be 2
    }

    It 'T1 (plan-stress-test): Get-EmissionGap should report the honest decoy-ambiguous reason, not head-corrupt (RED — decoy-ambiguous does not exist yet)' {
        $result = Get-EmissionGap -Bodies @($script:NearDecoyPlanStressTestBody) -Id 706 -Surface 'plan-stress-test'
        $result.ParseStatus | Should -Be 'could-not-verify'
        $result.Reason | Should -Be 'decoy-ambiguous'
    }

    It 'T2 (code-review) diagnostic: the decoy and the real head both pass the vocab gate (bleed confirmed, GREEN today)' {
        $realHeads = Get-RealJudgeRulingsHeadMatches -Body $script:NearDecoyCodeReviewBody
        $realHeads.Count | Should -Be 2
    }

    It 'T2 (code-review): Get-EmissionGap should report the honest decoy-ambiguous reason, not head-corrupt (RED — decoy-ambiguous does not exist yet)' {
        $result = Get-EmissionGap -Bodies @($script:NearDecoyCodeReviewBody) -Id 816 -Surface 'code-review'
        $result.ParseStatus | Should -Be 'could-not-verify'
        $result.Reason | Should -Be 'decoy-ambiguous'
    }
}

Describe 'Issue #817 T3: the well-separated genuine duplicate stays head-corrupt (no regression from the new helper)' {
    It 'GREEN today and must stay GREEN after s2: TwoRealHeadsBothVocabGatePassingBody resolves to head-corrupt, never decoy-ambiguous' {
        $result = Get-EmissionGap -Bodies @($script:TwoRealHeadsBothVocabGatePassingBody) -Id 705 -Surface 'plan-stress-test'
        $result.ParseStatus | Should -Be 'could-not-verify'
        $result.Reason | Should -Be 'head-corrupt'
    }
}

Describe 'Issue #817 no-flip regression: the close-separated genuine duplicate (L458 DuplicateJudgeRulingsHeadsBody) must not flip to decoy-ambiguous' {
    It 'GREEN today and must stay GREEN after s2 lands (each duplicate block has its own complete vocabulary before the next head, unlike T6)' {
        $result = Get-EmissionGap -Bodies @($script:DuplicateJudgeRulingsHeadsBody) -Id 701 -Surface 'plan-stress-test'
        $result.ParseStatus | Should -Be 'could-not-verify'
        $result.Reason | Should -Be 'head-corrupt'
        # Explicit no-flip pin (belt-and-suspenders alongside the -Be assertion
        # above): this fixture is the well-established close-separated
        # GENUINE duplicate (existing pin at ~L1374 of this file before this
        # insertion) and must never be relabeled decoy-ambiguous by the s2
        # helper — both duplicate blocks carry their own complete vocabulary
        # before the next head begins, which is exactly what should make the
        # new truncated-window re-check count 2 survivors (genuine-duplicate),
        # not 1.
        $result.Reason | Should -Not -Be 'decoy-ambiguous'
    }
}

Describe 'Issue #817 T4: cross-body reason priority' {
    It 'pair 1 (a near-decoy body + a genuine-duplicate body): aggregate Reason is head-corrupt (matches current behavior; decoy-ambiguous does not exist yet to test the priority against)' {
        $result = Get-EmissionGap -Bodies @($script:NearDecoyPlanStressTestBody, $script:TwoRealHeadsBothVocabGatePassingBody) -Id 1 -Surface 'plan-stress-test'
        $result.ParseStatus | Should -Be 'could-not-verify'
        $result.Reason | Should -Be 'head-corrupt'
    }

    It 'pair 2 (a near-decoy body + a head-missing fallback-only body): aggregate Reason should be decoy-ambiguous (RED — today this resolves to head-corrupt, since the ladder has no decoy-ambiguous flag yet and head-corrupt currently outranks head-missing)' {
        $result = Get-EmissionGap -Bodies @($script:NearDecoyPlanStressTestBody, $script:ProseOnlyPlanStressTestBody) -Id 1 -Surface 'plan-stress-test'
        $result.ParseStatus | Should -Be 'could-not-verify'
        $result.Reason | Should -Be 'decoy-ambiguous'
    }
}

Describe 'Issue #817 T5: block-scalar-embedded decoy vocabulary and multiple-decoys-before-one-block' {
    It 'T5a diagnostic: the embedded decoy mention is already excluded from head candidacy today (GREEN — only 2 real matches, the embedded mention is never a third candidate)' {
        $realHeads = Get-RealJudgeRulingsHeadMatches -Body $script:EmbeddedBlockScalarFakeVocabBody
        $realHeads.Count | Should -Be 2
    }

    It 'T5a: Get-EmissionGap should report decoy-ambiguous once the new helper excludes block-scalar-interior vocab tokens from the truncated re-check (RED today)' {
        $result = Get-EmissionGap -Bodies @($script:EmbeddedBlockScalarFakeVocabBody) -Id 708 -Surface 'plan-stress-test'
        $result.ParseStatus | Should -Be 'could-not-verify'
        $result.Reason | Should -Be 'decoy-ambiguous'
    }

    It 'T5b diagnostic: two prose decoys plus one real block all pass the vocab gate today (GREEN — 3 real matches)' {
        $realHeads = Get-RealJudgeRulingsHeadMatches -Body $script:TwoDecoysBeforeOneRealBody
        $realHeads.Count | Should -Be 3
    }

    It 'T5b: Get-EmissionGap should report decoy-ambiguous for the two-decoys-before-one-real shape (RED today)' {
        $result = Get-EmissionGap -Bodies @($script:TwoDecoysBeforeOneRealBody) -Id 709 -Surface 'plan-stress-test'
        $result.ParseStatus | Should -Be 'could-not-verify'
        $result.Reason | Should -Be 'decoy-ambiguous'
    }
}

Describe 'Issue #817 T6/T7: one accepted residual (T6) and one confirmed-correct edge case (T7)' {
    It 'T6 diagnostic: both back-to-back heads pass the vocab gate today (GREEN — 2 real matches, same as the existing close-separated pin)' {
        $realHeads = Get-RealJudgeRulingsHeadMatches -Body $script:CloseHeadsGenuineDuplicateResidualBody
        $realHeads.Count | Should -Be 2
    }

    It 'T6: a genuine close-heads duplicate is documented to mislabel as decoy-ambiguous once the new helper lands (RED today; ACCEPTED D4 residual, not a bug)' {
        $result = Get-EmissionGap -Bodies @($script:CloseHeadsGenuineDuplicateResidualBody) -Id 710 -Surface 'plan-stress-test'
        $result.ParseStatus | Should -Be 'could-not-verify'
        $result.Reason | Should -Be 'decoy-ambiguous'
    }

    It 'T7 diagnostic: the outer head and the embedded mid-sentence decoy both pass the vocab gate today (GREEN — 2 real matches)' {
        $realHeads = Get-RealJudgeRulingsHeadMatches -Body $script:MirrorOrderingConfirmedCorrectBody
        $realHeads.Count | Should -Be 2
    }

    It 'T7: the mirror-ordering placement resolves to decoy-ambiguous per the corrected D4 characterization — a confirmed-correct edge case, not a residual (RED — confirms this author''s trace)' {
        $result = Get-EmissionGap -Bodies @($script:MirrorOrderingConfirmedCorrectBody) -Id 711 -Surface 'plan-stress-test'
        $result.ParseStatus | Should -Be 'could-not-verify'
        $result.Reason | Should -Be 'decoy-ambiguous'
    }
}

Describe 'Issue #817: window-edge boundary and before+after placement fixtures' {
    It 'window-edge diagnostic: the decoy bleeds at 296 chars of filler (1 char inside the 400-char window), GREEN today — 2 real matches' {
        $realHeads = Get-RealJudgeRulingsHeadMatches -Body $script:WindowEdgeBleedBody
        $realHeads.Count | Should -Be 2
    }

    It 'window-edge: Get-EmissionGap should report decoy-ambiguous at the window boundary (RED today)' {
        $result = Get-EmissionGap -Bodies @($script:WindowEdgeBleedBody) -Id 712 -Surface 'plan-stress-test'
        $result.ParseStatus | Should -Be 'could-not-verify'
        $result.Reason | Should -Be 'decoy-ambiguous'
    }

    It 'before+after diagnostic: only 2 candidates pass the vocab gate today, not 3 — the after-decoy has no vocabulary forward of itself so it never becomes a candidate at all (GREEN, describes current raw vocab-gate behavior)' {
        $realHeads = Get-RealJudgeRulingsHeadMatches -Body $script:DecoyBeforeAndAfterRealBody
        $realHeads.Count | Should -Be 2
    }

    It 'before+after: Get-EmissionGap should report decoy-ambiguous once the new helper lands (RED today; only the real block survives truncation since the after-decoy never registers as a candidate)' {
        $result = Get-EmissionGap -Bodies @($script:DecoyBeforeAndAfterRealBody) -Id 713 -Surface 'plan-stress-test'
        $result.ParseStatus | Should -Be 'could-not-verify'
        $result.Reason | Should -Be 'decoy-ambiguous'
    }
}

Describe 'PR #833 judge-sustained M2 regression: block-scalar trailing-blank-line exclusion must use the keyword capture position, not the overall match start' {
    It 'diagnostic: both heads pass the raw vocab gate today (GREEN — 2 real matches, same shape as the T3 well-separated genuine duplicate)' {
        $realHeads = Get-RealJudgeRulingsHeadMatches -Body $script:BlockScalarTrailingBlankLineGenuineDuplicateBody
        $realHeads.Count | Should -Be 2
    }

    It 'AC3: a genuine well-separated 2-real-head duplicate keeps head-corrupt even when the second head''s own vocabulary immediately follows a block scalar''s trailing blank line (RED today — the M2 bug currently misreads the second head''s vocab-match start as inside the block-scalar span, dropping the survivor count to 1 and misreporting decoy-ambiguous)' {
        $result = Get-EmissionGap -Bodies @($script:BlockScalarTrailingBlankLineGenuineDuplicateBody) -Id 715 -Surface 'plan-stress-test'
        $result.ParseStatus | Should -Be 'could-not-verify'
        $result.Reason | Should -Be 'head-corrupt'
        $result.Reason | Should -Not -Be 'decoy-ambiguous'
    }
}

Describe 'PR #833 judge-sustained M4 regression: Get-JudgeRulingsDuplicateDiagnosis must not mislabel a lone real head' {
    It 'called directly with exactly 1 real head, returns the conservative genuine-duplicate label instead of window-bleed (RED today — no <2-heads guard exists yet, so the sole candidate''s own survival is misread as the window-bleed 1-survivor case)' {
        $realHeads = Get-RealJudgeRulingsHeadMatches -Body $script:PlanStressTestBody
        $realHeads.Count | Should -Be 1

        $diagnosis = Get-JudgeRulingsDuplicateDiagnosis -Body $script:PlanStressTestBody
        $diagnosis | Should -Be 'genuine-duplicate'
    }
}

Describe 'PR #833 judge-sustained M10 direct-isolation regression: Get-JudgeRulingsDuplicateDiagnosis in isolation' {
    It 'called directly with 2 candidates whose only vocabulary lives inside block scalars, returns genuine-duplicate (the conservative 0-survivor fallback) without throwing (GREEN today — the fallback behavior is already safe, just previously untested via a direct call)' {
        $realHeads = Get-RealJudgeRulingsHeadMatches -Body $script:BothHeadsBlockScalarOnlyVocabBody
        $realHeads.Count | Should -Be 2

        { $script:m10Diagnosis = Get-JudgeRulingsDuplicateDiagnosis -Body $script:BothHeadsBlockScalarOnlyVocabBody } | Should -Not -Throw
        $script:m10Diagnosis | Should -Be 'genuine-duplicate'
    }
}

Describe 'GH-2 (PR #853 review, judge-sustained): near-decoy window-bleed must not soften an independently-corrupt real head to decoy-ambiguous' {
    It 'diagnostic: the decoy and the malformed real head both pass the vocab gate (bleed confirmed, key-only gate does not validate the value)' {
        $realHeads = Get-RealJudgeRulingsHeadMatches -Body $script:NearDecoyMalformedRealHeadBody
        $realHeads.Count | Should -Be 2
    }

    It 'reports Reason head-corrupt, not decoy-ambiguous, when the surviving real head is independently corrupt (RED today — currently reports decoy-ambiguous)' {
        $result = Get-EmissionGap -Bodies @($script:NearDecoyMalformedRealHeadBody) -Id 819 -Surface 'plan-stress-test'
        $result.ParseStatus | Should -Be 'could-not-verify'
        $result.Reason | Should -Be 'head-corrupt'
        $result.Reason | Should -Not -Be 'decoy-ambiguous'
    }

    It 'companion baseline (no decoy): the same malformed real head alone already reports head-corrupt today (GREEN, contrast case for the RED test above)' {
        $realHeads = Get-RealJudgeRulingsHeadMatches -Body $script:MalformedRealHeadNoDecoyBody
        $realHeads.Count | Should -Be 1

        $result = Get-EmissionGap -Bodies @($script:MalformedRealHeadNoDecoyBody) -Id 819 -Surface 'plan-stress-test'
        $result.ParseStatus | Should -Be 'could-not-verify'
        $result.Reason | Should -Be 'head-corrupt'
    }
}

Describe 'Get-EmissionGap - aggregation across multiple bodies' {
    It 'sums SustainedCount and BlockCount across bodies and computes Gap for PR #775 pre-backfill (2 sustained, 0 blocks)' {
        $result = Get-EmissionGap -Bodies @($script:Pr775Body) -Id 775 -Surface 'code-review'
        $result.SustainedCount | Should -Be 2
        $result.BlockCount | Should -Be 0
        $result.Gap | Should -Be 2
        $result.ParseStatus | Should -Be 'ok'
    }

    It 'computes Gap 0 when a matching, schema-valid, correctly-prefixed phase-containment block is present for every sustained finding' {
        # Fix A (M4): the block only counts because its body ALSO carries the
        # surface's own authoritative marker head (ZeroSustainedBody carries
        # <!-- judge-rulings pr=999 -->, the code-review marker).
        $validBlock = script:New-ValidPhaseContainmentBlockText -Id '999' -Surface 'code-review' -FindingSuffix 'F1'
        $bodyWithBlock = $script:ZeroSustainedBody + "`n$validBlock"
        $result = Get-EmissionGap -Bodies @($bodyWithBlock) -Id 999 -Surface 'code-review'
        $result.SustainedCount | Should -Be 0
        $result.BlockCount | Should -Be 1
        $result.Gap | Should -Be -1
        $result.ParseStatus | Should -Be 'ok'
    }

    It 'aggregates across multiple comment bodies for the same Id (2-body loop-level coverage)' {
        # Scope note (M17): one judge-rulings comment per PR is assumed. This
        # test uses two bodies that each independently carry a marker head
        # and parse ok, to exercise loop-level summation across genuine
        # judge-rulings surfaces (marker-less-skip behavior is covered
        # separately below).
        $bodyOne = $script:Pr781Body
        $blockA = script:New-ValidPhaseContainmentBlockText -Id '781' -Surface 'code-review' -FindingSuffix 'a'
        $blockB = script:New-ValidPhaseContainmentBlockText -Id '781' -Surface 'code-review' -FindingSuffix 'b'
        $bodyTwo = $script:ZeroSustainedBody + "`n$blockA`n$blockB"
        $result = Get-EmissionGap -Bodies @($bodyOne, $bodyTwo) -Id 781 -Surface 'code-review'
        $result.SustainedCount | Should -Be 4
        $result.BlockCount | Should -Be 2
        $result.Gap | Should -Be 2
        $result.ParseStatus | Should -Be 'ok'
    }

    It 'skips a marker-less comment body entirely — ordinary PR chatter does not poison the aggregate (issue #782 live-validation correction)' {
        # OLD (incorrect) expectation: a body with no judge-rulings marker head
        # at all (e.g. a phase-containment ledger comment, a bot notice, "LGTM")
        # forced the whole-PR aggregate to could-not-verify. That conflated
        # "not a judge-rulings surface" with "unparseable judge-rulings
        # surface" and made every real multi-comment PR permanently
        # unverifiable (live PRs #775/#778/#781 all reported COULD NOT VERIFY
        # despite their judge-rulings comment parsing fine). Corrected
        # contract: a marker-less body contributes 0 sustained and is skipped
        # for SustainedCount. Fix A (M4) tightens block counting further: a
        # marker-less body's blocks ALSO do not count toward BlockCount now
        # (co-location gate), since a bare block with no accompanying
        # authoritative marker on the same body is exactly the
        # pure-chatter-with-injected-blocks vector M4 closes.
        $bodyOne = $script:Pr781Body
        $blockOnly = script:New-ValidPhaseContainmentBlockText -Id '781' -Surface 'code-review' -FindingSuffix 'a'
        $bodyTwo = $blockOnly
        $result = Get-EmissionGap -Bodies @($bodyOne, $bodyTwo) -Id 781 -Surface 'code-review'
        $result.ParseStatus | Should -Be 'ok'
        $result.SustainedCount | Should -Be 4
        $result.BlockCount | Should -Be 0
        $result.Gap | Should -Be 4
    }

    It 'propagates could-not-verify when a body carries a marker head but its content is malformed (DD3 fail-loud still applies)' {
        # Distinguishes "marker present but unparseable" (still could-not-verify
        # per DD3) from "no marker at all" (skipped, prior test). Uses
        # UnknownVocabularyBody, which has a real `<!-- judge-rulings` head
        # but an unrecognized disposition value. The second body's block does
        # not count (no marker head co-located, per Fix A M4), but that is
        # incidental here — the point of this test is the could-not-verify
        # propagation from the first body.
        $cleanBlockOnly = script:New-ValidPhaseContainmentBlockText -Id '1' -Surface 'code-review' -FindingSuffix 'a'
        $result = Get-EmissionGap -Bodies @($script:UnknownVocabularyBody, $cleanBlockOnly) -Id 1 -Surface 'code-review'
        $result.ParseStatus | Should -Be 'could-not-verify'
    }

    It 'a marker-less body alone (no judge-rulings surface anywhere) yields a clean ok result, not could-not-verify' {
        $result = Get-EmissionGap -Bodies @($script:MalformedBody) -Id 1 -Surface 'code-review'
        $result.ParseStatus | Should -Be 'ok'
        $result.SustainedCount | Should -Be 0
        $result.BlockCount | Should -Be 0
        $result.Gap | Should -Be 0
    }

    It 'returns Gap 0 for an empty Bodies array' {
        $result = Get-EmissionGap -Bodies @() -Id 1 -Surface 'code-review'
        $result.SustainedCount | Should -Be 0
        $result.BlockCount | Should -Be 0
        $result.Gap | Should -Be 0
        $result.ParseStatus | Should -Be 'ok'
    }
}

Describe 'Get-EmissionGap - Fix A (M1) cross-surface block isolation — THE required M1 regression test' {
    It 'does not count a design-challenge-prefixed block toward a plan-stress-test surface check on the same issue, and vice versa' {
        # A single issue body can legitimately carry BOTH a design-challenge
        # AND a plan-stress-test marker head in the same comment (e.g. a
        # design-phase-complete comment that also discusses plan status).
        # finding_key prefix — not just body-level marker co-location — must
        # discriminate which blocks count toward which surface.
        $designMarker = "finding_dispositions:`n  schema_version: 1"
        $planMarker = "<!-- judge-rulings pr=900 -->`njudge_ruling: sustained`n-->"
        $designBlock = script:New-ValidPhaseContainmentBlockText -Id '900' -Surface 'design-challenge' -FindingSuffix 'F1' -CatchablePhase 'design' -CaughtStage 'design-challenge' -EscapeDistance 0
        $planBlock = script:New-ValidPhaseContainmentBlockText -Id '900' -Surface 'plan-stress-test' -FindingSuffix 'F1' -CatchablePhase 'plan' -CaughtStage 'plan-stress-test' -EscapeDistance 0
        $coOccurringBody = "$designMarker`n`n$planMarker`n`n$designBlock`n`n$planBlock"

        $designResult = Get-EmissionGap -Bodies @($coOccurringBody) -Id 900 -Surface 'design-challenge'
        $planResult = Get-EmissionGap -Bodies @($coOccurringBody) -Id 900 -Surface 'plan-stress-test'

        # Each surface's BlockCount reflects ONLY its own finding_key-prefixed
        # block, never the other surface's co-located block.
        $designResult.BlockCount | Should -Be 1
        $planResult.BlockCount | Should -Be 1
    }

    It 'a code-review-prefixed block does not count toward a design-challenge surface check even when both marker heads co-occur' {
        $designMarker = "finding_dispositions:`n  schema_version: 1"
        $codeReviewBlock = script:New-ValidPhaseContainmentBlockText -Id '901' -Surface 'code-review' -FindingSuffix 'F1'
        $body = "$designMarker`n`n$codeReviewBlock"

        $designResult = Get-EmissionGap -Bodies @($body) -Id 901 -Surface 'design-challenge'
        $designResult.BlockCount | Should -Be 0
    }
}

Describe 'Get-EmissionGap - Fix A (M5) schema-invalid blocks do not count' {
    It 'a block with escape_distance: -1 (TODO-human scaffold shape) does not count toward BlockCount' {
        $marker = "<!-- judge-rulings pr=902 -->`njudge_ruling: sustained`n-->"
        $scaffoldBlock = @(
            '<!-- phase-containment-902 -->'
            'finding_key: code-review:902:TODO-human-1'
            'introduced_phase: TODO-human'
            'catchable_phase: TODO-human'
            'caught_stage: code-review'
            'escape_distance: -1'
            'severity: TODO-human'
            'systemic_fix_type: TODO-human'
            'category: TODO-human'
            'apparatus_meta: false'
            'seed: false'
            '<!-- /phase-containment-902 -->'
        ) -join "`n"
        $body = "$marker`n`n$scaffoldBlock"

        $result = Get-EmissionGap -Bodies @($body) -Id 902 -Surface 'code-review'
        $result.BlockCount | Should -Be 0
    }

    It 'a block with an invalid enum value does not count toward BlockCount' {
        $marker = "<!-- judge-rulings pr=903 -->`njudge_ruling: sustained`n-->"
        $invalidBlock = script:New-ValidPhaseContainmentBlockText -Id '903' -Surface 'code-review' -FindingSuffix 'F1'
        $invalidBlock = $invalidBlock -replace 'severity: low', 'severity: not-a-real-severity'
        $body = "$marker`n`n$invalidBlock"

        $result = Get-EmissionGap -Bodies @($body) -Id 903 -Surface 'code-review'
        $result.BlockCount | Should -Be 0
    }

    It 'a valid block still counts alongside an invalid one in the same body (per-block gating, not whole-body rejection)' {
        $marker = "<!-- judge-rulings pr=904 -->`njudge_ruling: sustained`n-->"
        $validBlock = script:New-ValidPhaseContainmentBlockText -Id '904' -Surface 'code-review' -FindingSuffix 'F1'
        $invalidBlock = (script:New-ValidPhaseContainmentBlockText -Id '904' -Surface 'code-review' -FindingSuffix 'F2') -replace 'escape_distance: 0', 'escape_distance: -1'
        $body = "$marker`n`n$validBlock`n`n$invalidBlock"

        $result = Get-EmissionGap -Bodies @($body) -Id 904 -Surface 'code-review'
        $result.BlockCount | Should -Be 1
    }
}

Describe 'Get-EmissionGap - Fix A (M2) posted scaffold-report re-sweep does not close a real gap' {
    It 'a scaffold-report body (rendered by -ScaffoldBackfill, using inert marker labels) contributes zero blocks when re-swept' {
        # Simulates the -ScaffoldBackfill report renderer's OWN output (after
        # the M2 defense-in-depth fix applies Format-InertMarkerLabel to the
        # scaffold too): the report never emits a live phase-containment
        # marker literal, so re-sweeping the posted report comment can never
        # be misread as satisfying the gap it just reported.
        $marker = "<!-- judge-rulings pr=905 -->`njudge_ruling: sustained`njudge_ruling: sustained`n-->"
        $scaffoldReportBody = @'
## Phase-Containment Emission Check

Backfill scaffold for code-review:
```yaml
`phase-containment-905`
finding_key: code-review:905:TODO-human-1
introduced_phase: TODO-human
catchable_phase: TODO-human
caught_stage: code-review
escape_distance: -1
severity: TODO-human
systemic_fix_type: TODO-human
category: TODO-human
apparatus_meta: false
seed: false
`/phase-containment-905`
```
'@
        $body = "$marker`n`n$scaffoldReportBody"

        $result = Get-EmissionGap -Bodies @($body) -Id 905 -Surface 'code-review'
        $result.BlockCount | Should -Be 0
        $result.SustainedCount | Should -Be 2
        $result.Gap | Should -Be 2
    }
}

Describe 'Get-SustainedFindingCount - M8 regression: ambiguous region-end detection fails loud' {
    It 'returns could-not-verify (not a silent under-count) when a stray closer in prose precedes real disposition lines that would otherwise be truncated away' {
        # Region-end detection historically picked the FIRST '-->' or code
        # fence found after the head, with no ambiguity check. A stray '-->'
        # sequence inside ordinary prose BEFORE the real YAML content (e.g. a
        # sentence describing the phase-flow arrow notation
        # "introduced --> catchable --> caught") truncated the region early,
        # silently dropping real judge_ruling: sustained lines that appear
        # AFTER that stray closer — SustainedCount=1 with ParseStatus='ok'
        # when the real count is 3. M8 requires detecting this ambiguity
        # (multiple candidate closers before any real finding pattern is
        # reached) and failing loud instead.
        $body = @'
<!-- judge-rulings pr=801 -->
judge_ruling: sustained
Note: the flow is introduced --> catchable --> caught for phase projection.
judge_ruling: sustained
judge_ruling: sustained
-->
'@
        $result = Get-SustainedFindingCount -Surface 'code-review' -Body $body
        $result.ParseStatus | Should -Be 'could-not-verify'
    }

    It 'still returns ok for the live PR #775/#778/#781 fixtures (no regression on real, unambiguous shapes)' {
        # Real live fixtures have no stray closer-like sequences between the
        # head and the true closing marker, so region-end detection must
        # remain unambiguous and keep returning ok with the correct counts.
        $result775 = Get-SustainedFindingCount -Surface 'code-review' -Body $script:Pr775Body
        $result775.ParseStatus | Should -Be 'ok'
        $result775.SustainedCount | Should -Be 2

        $result778 = Get-SustainedFindingCount -Surface 'code-review' -Body $script:Pr778Body
        $result778.ParseStatus | Should -Be 'ok'
        $result778.SustainedCount | Should -Be 10

        $result781 = Get-SustainedFindingCount -Surface 'code-review' -Body $script:Pr781Body
        $result781.ParseStatus | Should -Be 'ok'
        $result781.SustainedCount | Should -Be 4
    }
}

Describe 'Add-CommentBlocks - read-modify-write append primitive' {
    BeforeEach {
        $script:lastGetPath = $null
        $script:lastPatchArgs = $null
        $script:getCallCount = 0
        # 'get' | 'patch' | 'verify-truncated' |
        # 'verify-marker-missing' | 'verify-blocks-missing' | ''
        $script:simulateFailure = ''
        # Sized well above the NewContent block below so a body that echoes
        # only the original content (verify-blocks-missing) does not also
        # trip the gross-truncation guard — that scenario is specifically
        # testing the missing-new-block check, not the truncation check.
        $script:mockOriginalBody = "## Judge Rulings`n`nSome long-form prose summary of the review outcome that mirrors a real judge-rulings comment body in size.`n`n<!-- judge-rulings`n- id: F1`n  judge_ruling: sustained`n-->"
        # Real caller shape: NewContent carries a phase-containment block, not
        # arbitrary text, so post-write verify has a block to positively prove.
        $script:mockNewContent = "`n<!-- phase-containment-775 -->`nfinding_id: GF-1`nverdict: sustained`n<!-- /phase-containment-775 -->"

        function global:gh {
            param([Parameter(ValueFromRemainingArguments = $true)]$Args)
            $joined = $Args -join ' '

            if ($joined -match '^api repos/[^/]+/[^/]+/issues/comments/(\d+)$') {
                $script:getCallCount++
                $script:lastGetPath = $joined
                if ($script:simulateFailure -eq 'get') {
                    $global:LASTEXITCODE = 1
                    return ''
                }
                $global:LASTEXITCODE = 0

                if ($script:getCallCount -ge 2) {
                    # Post-write verify GET (2nd call onward).
                    switch ($script:simulateFailure) {
                        'verify-truncated' {
                            # Simulates genuine data loss: only a sliver of the
                            # combined body comes back.
                            return (@{ body = $script:mockOriginalBody.Substring(0, 5) } | ConvertTo-Json)
                        }
                        'verify-marker-missing' {
                            # New block present and body length is comparable
                            # to what was written, but the original
                            # judge-rulings marker itself is gone — genuine
                            # corruption distinct from truncation.
                            $corrupted = "## Judge Rulings (marker stripped)`n`nSome long-form prose summary of the review outcome that mirrors a real judge-rulings comment body in size, but without the marker.$($script:mockNewContent)"
                            return (@{ body = $corrupted } | ConvertTo-Json)
                        }
                        'verify-blocks-missing' {
                            # Original marker survived, but the new
                            # phase-containment block did not land.
                            return (@{ body = $script:mockOriginalBody } | ConvertTo-Json)
                        }
                        default {
                            # Happy path: simulate GitHub's benign whitespace
                            # normalization (trailing-space and blank-line-run
                            # collapsing) rather than an exact byte-identical
                            # echo — this is the shape that broke the old
                            # ordinal StartsWith prefix check.
                            $normalized = ($script:mockOriginalBody + $script:mockNewContent) `
                                -replace '[ \t]+\r?\n', "`n" `
                                -replace '\n{3,}', "`n`n"
                            return (@{ body = $normalized } | ConvertTo-Json)
                        }
                    }
                }
                return (@{ body = $script:mockOriginalBody } | ConvertTo-Json)
            }

            if ($joined -match '^api -X PATCH repos/[^/]+/[^/]+/issues/comments/(\d+) --input') {
                $script:lastPatchArgs = $Args
                if ($script:simulateFailure -eq 'patch') {
                    $global:LASTEXITCODE = 1
                    return ''
                }
                $global:LASTEXITCODE = 0
                return (@{ id = 999 } | ConvertTo-Json)
            }

            $global:LASTEXITCODE = 0
            return ''
        }
    }

    AfterEach {
        Remove-Item Function:gh -ErrorAction SilentlyContinue
    }

    It 'succeeds when the marker is present, PATCH succeeds, and post-write verify tolerates benign whitespace normalization' {
        $result = Add-CommentBlocks -Owner 'Grimblaz' -Repo 'agent-orchestra' -CommentId 999 -ExpectedMarker '<!-- judge-rulings' -NewContent $script:mockNewContent
        $result.Success | Should -Be $true
        $result.Reason | Should -BeNullOrEmpty
        $script:lastPatchArgs | Should -Not -BeNullOrEmpty
    }

    It 'fails without patching when the expected marker is not found in the fetched body' {
        $result = Add-CommentBlocks -Owner 'Grimblaz' -Repo 'agent-orchestra' -CommentId 999 -ExpectedMarker '<!-- finding_dispositions' -NewContent $script:mockNewContent
        $result.Success | Should -Be $false
        $result.Reason | Should -Match 'not found'
        $script:lastPatchArgs | Should -BeNullOrEmpty
    }

    It 'fails when the GET call fails' {
        $script:simulateFailure = 'get'
        $result = Add-CommentBlocks -Owner 'Grimblaz' -Repo 'agent-orchestra' -CommentId 999 -ExpectedMarker '<!-- judge-rulings' -NewContent $script:mockNewContent
        $result.Success | Should -Be $false
        $result.Reason | Should -Match 'GET failed'
    }

    It 'fails when the PATCH call fails' {
        $script:simulateFailure = 'patch'
        $result = Add-CommentBlocks -Owner 'Grimblaz' -Repo 'agent-orchestra' -CommentId 999 -ExpectedMarker '<!-- judge-rulings' -NewContent $script:mockNewContent
        $result.Success | Should -Be $false
        $result.Reason | Should -Match 'PATCH failed'
    }

    It 'fails loud when the post-write verify body is dramatically shorter than what was written (truncation/data-loss)' {
        $script:simulateFailure = 'verify-truncated'
        $result = Add-CommentBlocks -Owner 'Grimblaz' -Repo 'agent-orchestra' -CommentId 999 -ExpectedMarker '<!-- judge-rulings' -NewContent $script:mockNewContent
        $result.Success | Should -Be $false
        $result.Reason | Should -Match 'shorter than expected'
    }

    It 'fails loud when the original marker is missing from the post-write verify body (genuine corruption)' {
        $script:simulateFailure = 'verify-marker-missing'
        $result = Add-CommentBlocks -Owner 'Grimblaz' -Repo 'agent-orchestra' -CommentId 999 -ExpectedMarker '<!-- judge-rulings' -NewContent $script:mockNewContent
        $result.Success | Should -Be $false
        $result.Reason | Should -Match 'missing from verify body'
    }

    It 'fails loud when the new phase-containment block does not appear in the post-write verify body' {
        $script:simulateFailure = 'verify-blocks-missing'
        $result = Add-CommentBlocks -Owner 'Grimblaz' -Repo 'agent-orchestra' -CommentId 999 -ExpectedMarker '<!-- judge-rulings' -NewContent $script:mockNewContent
        $result.Success | Should -Be $false
        $result.Reason | Should -Match 'phase-containment-775'
    }

    It 'M10 fix: returns Success=$false with a no-op reason when NewContent carries zero phase-containment blocks, without writing' {
        # Before the M10 fix, NewContent with no phase-containment blocks at
        # all still proceeded through GET -> PATCH -> verify and reported
        # Success=$true — a "positive-proof" loop that vacuously passed
        # because there was nothing to prove. This silently masked a caller
        # bug (e.g. a backfill scaffold that failed to render any blocks)
        # as a successful append. The append primitive now refuses the
        # no-op case up front and never issues the PATCH.
        $result = Add-CommentBlocks -Owner 'Grimblaz' -Repo 'agent-orchestra' -CommentId 999 -ExpectedMarker '<!-- judge-rulings' -NewContent "`nplain text with no block markers"
        $result.Success | Should -Be $false
        $result.Reason | Should -Match 'no-op'
        # Confirms no write was attempted: lastPatchArgs stays unset.
        $script:lastPatchArgs | Should -BeNullOrEmpty
    }

    It 'still succeeds when NewContent carries at least one real phase-containment block' {
        $result = Add-CommentBlocks -Owner 'Grimblaz' -Repo 'agent-orchestra' -CommentId 999 -ExpectedMarker '<!-- judge-rulings' -NewContent $script:mockNewContent
        $result.Success | Should -Be $true
    }
}

Describe 'Add-JudgeRulingsBlock - sibling append primitive with entry-level positive-proof (811-D1 s3, M17)' {
    BeforeEach {
        $script:lastGetPath = $null
        $script:lastPatchArgs = $null
        $script:getCallCount = 0
        # 'get' | 'patch' | 'verify-truncated' | 'verify-marker-missing' |
        # 'verify-truncated-entries' | ''
        $script:simulateFailure = ''

        $script:mockOriginalBody = "<!-- plan-issue-811 -->`n`nSome long-form prose summary of the plan mirroring a real plan-issue comment body in size."

        # Full 11-entry judge-rulings append (mirrors the #794 backfill shape
        # described in the 811 plan's s6 step, trimmed to a representative
        # subset of field names — id/judge_ruling/judge_confidence).
        $script:mockFullNewContent = @"
`n<!-- judge-rulings
- finding_id: M1
  judge_ruling: sustained
- finding_id: M2
  judge_ruling: sustained
- finding_id: M3
  judge_ruling: sustained
- finding_id: M4
  judge_ruling: defense-sustained
- finding_id: M5
  judge_ruling: sustained
- finding_id: M6
  judge_ruling: defense-sustained
- finding_id: M7
  judge_ruling: sustained
- finding_id: M8
  judge_ruling: defense-sustained
- finding_id: M9
  judge_ruling: defense-sustained
- finding_id: M10
  judge_ruling: sustained
- finding_id: M11
  judge_ruling: sustained
-->
"@

        # M3 fix regression fixture: an original body that ALREADY carries a
        # judge-rulings block identical to $script:mockFullNewContent's
        # entries (e.g. left over from a prior partial/failed run), used only
        # by the 'verify-baseline-blind-noop' simulateFailure mode below.
        $script:mockOriginalBodyWithPriorBlock = $script:mockOriginalBody + $script:mockFullNewContent

        function global:gh {
            param([Parameter(ValueFromRemainingArguments = $true)]$Args)
            $joined = $Args -join ' '

            if ($joined -match '^api repos/[^/]+/[^/]+/issues/comments/(\d+)$') {
                $script:getCallCount++
                $script:lastGetPath = $joined
                if ($script:simulateFailure -eq 'get') {
                    $global:LASTEXITCODE = 1
                    return ''
                }
                $global:LASTEXITCODE = 0

                if ($script:getCallCount -ge 2) {
                    # Post-write verify GET (2nd call onward).
                    switch ($script:simulateFailure) {
                        'verify-truncated' {
                            # Gross truncation: only a sliver of the combined
                            # body comes back.
                            return (@{ body = $script:mockOriginalBody.Substring(0, 5) } | ConvertTo-Json)
                        }
                        'verify-marker-missing' {
                            # New entries present, body length comparable,
                            # but the original plan-issue marker is gone.
                            $corrupted = "## Plan (marker stripped)`n`nSome long-form prose summary of the plan mirroring a real plan-issue comment body in size, but without the marker.$($script:mockFullNewContent)"
                            return (@{ body = $corrupted } | ConvertTo-Json)
                        }
                        'verify-truncated-entries' {
                            # Simulates a partial/truncated append: head plus
                            # only 3 of the 11 entries actually landed. This
                            # must be detected by entry-level positive-proof,
                            # not just by the head substring '<!-- judge-rulings'
                            # reappearing (which it does, here). Padded with
                            # harmless filler prose so the overall body length
                            # stays comparable to what was written — isolating
                            # the entry-level check from the separate
                            # gross-truncation-guard check (5a), which is
                            # covered by its own dedicated test above.
                            $truncatedNewContent = @"
`n<!-- judge-rulings
- finding_id: M1
  judge_ruling: sustained
- finding_id: M2
  judge_ruling: sustained
- finding_id: M3
  judge_ruling: sustained
-->
"@
                            $filler = 'x' * ($script:mockFullNewContent.Length - $truncatedNewContent.Length)
                            return (@{ body = ($script:mockOriginalBody + $truncatedNewContent + "`n<!-- filler -->`n$filler") } | ConvertTo-Json)
                        }
                        'verify-baseline-blind-noop' {
                            # M3 fix regression fixture: the PATCH silently
                            # no-ops (e.g. a transient GitHub write failure
                            # that still returns success) and the re-fetched
                            # verify body is IDENTICAL to the original body —
                            # the new append never actually landed. The
                            # original body here (set per-test below via
                            # $script:mockOriginalBodyWithPriorBlock) already
                            # carries an identical judge-rulings block from a
                            # prior partial/failed run, so a baseline-blind
                            # count comparison would find "enough" occurrences
                            # of each value already present and falsely report
                            # success.
                            return (@{ body = $script:mockOriginalBodyWithPriorBlock } | ConvertTo-Json)
                        }
                        default {
                            # Happy path: simulate GitHub's benign whitespace
                            # normalization rather than an exact byte-identical
                            # echo.
                            $normalized = ($script:mockOriginalBody + $script:mockFullNewContent) `
                                -replace '[ \t]+\r?\n', "`n" `
                                -replace '\n{3,}', "`n`n"
                            return (@{ body = $normalized } | ConvertTo-Json)
                        }
                    }
                }
                if ($script:simulateFailure -eq 'verify-baseline-blind-noop') {
                    return (@{ body = $script:mockOriginalBodyWithPriorBlock } | ConvertTo-Json)
                }
                return (@{ body = $script:mockOriginalBody } | ConvertTo-Json)
            }

            if ($joined -match '^api -X PATCH repos/[^/]+/[^/]+/issues/comments/(\d+) --input') {
                $script:lastPatchArgs = $Args
                if ($script:simulateFailure -eq 'patch') {
                    $global:LASTEXITCODE = 1
                    return ''
                }
                $global:LASTEXITCODE = 0
                return (@{ id = 999 } | ConvertTo-Json)
            }

            $global:LASTEXITCODE = 0
            return ''
        }
    }

    AfterEach {
        Remove-Item Function:gh -ErrorAction SilentlyContinue
    }

    It 'succeeds on a full 11-entry append and verifies every entry landed' {
        $result = Add-JudgeRulingsBlock -Owner 'Grimblaz' -Repo 'agent-orchestra' -CommentId 794 -ExpectedMarker '<!-- plan-issue-811' -NewContent $script:mockFullNewContent
        $result.Success | Should -Be $true
        $result.Reason | Should -BeNullOrEmpty
        $script:lastPatchArgs | Should -Not -BeNullOrEmpty
    }

    It 'fails without patching when the expected marker is not found in the fetched body' {
        $result = Add-JudgeRulingsBlock -Owner 'Grimblaz' -Repo 'agent-orchestra' -CommentId 794 -ExpectedMarker '<!-- plan-issue-999' -NewContent $script:mockFullNewContent
        $result.Success | Should -Be $false
        $result.Reason | Should -Match 'not found'
        $script:lastPatchArgs | Should -BeNullOrEmpty
    }

    It 'fails when the GET call fails' {
        $script:simulateFailure = 'get'
        $result = Add-JudgeRulingsBlock -Owner 'Grimblaz' -Repo 'agent-orchestra' -CommentId 794 -ExpectedMarker '<!-- plan-issue-811' -NewContent $script:mockFullNewContent
        $result.Success | Should -Be $false
        $result.Reason | Should -Match 'GET failed'
    }

    It 'fails when the PATCH call fails' {
        $script:simulateFailure = 'patch'
        $result = Add-JudgeRulingsBlock -Owner 'Grimblaz' -Repo 'agent-orchestra' -CommentId 794 -ExpectedMarker '<!-- plan-issue-811' -NewContent $script:mockFullNewContent
        $result.Success | Should -Be $false
        $result.Reason | Should -Match 'PATCH failed'
    }

    It 'fails loud when the post-write verify body is dramatically shorter than what was written (truncation/data-loss)' {
        $script:simulateFailure = 'verify-truncated'
        $result = Add-JudgeRulingsBlock -Owner 'Grimblaz' -Repo 'agent-orchestra' -CommentId 794 -ExpectedMarker '<!-- plan-issue-811' -NewContent $script:mockFullNewContent
        $result.Success | Should -Be $false
        $result.Reason | Should -Match 'shorter than expected'
    }

    It 'fails loud when the original marker is missing from the post-write verify body (genuine corruption)' {
        $script:simulateFailure = 'verify-marker-missing'
        $result = Add-JudgeRulingsBlock -Owner 'Grimblaz' -Repo 'agent-orchestra' -CommentId 794 -ExpectedMarker '<!-- plan-issue-811' -NewContent $script:mockFullNewContent
        $result.Success | Should -Be $false
        $result.Reason | Should -Match 'missing from verify body'
    }

    It 'detects a truncated append (head + 3 of 11 entries landed) as a failure, not a silent success' {
        $script:simulateFailure = 'verify-truncated-entries'
        $result = Add-JudgeRulingsBlock -Owner 'Grimblaz' -Repo 'agent-orchestra' -CommentId 794 -ExpectedMarker '<!-- plan-issue-811' -NewContent $script:mockFullNewContent
        $result.Success | Should -Be $false
        $result.Reason | Should -Match 'judge_ruling'
    }

    It 'M3 fix regression: a baseline-blind false-pass (PATCH silently no-ops, verify body unchanged from an original that already carries an identical block) is now caught as a failure' {
        $script:simulateFailure = 'verify-baseline-blind-noop'
        $result = Add-JudgeRulingsBlock -Owner 'Grimblaz' -Repo 'agent-orchestra' -CommentId 794 -ExpectedMarker '<!-- plan-issue-811' -NewContent $script:mockFullNewContent
        $result.Success | Should -Be $false
        $result.Reason | Should -Match 'judge_ruling'
    }

    It 'rejects a zero-entry judge-rulings head payload as a no-op, without writing' {
        $result = Add-JudgeRulingsBlock -Owner 'Grimblaz' -Repo 'agent-orchestra' -CommentId 794 -ExpectedMarker '<!-- plan-issue-811' -NewContent "`n<!-- judge-rulings`n-->`n"
        $result.Success | Should -Be $false
        $result.Reason | Should -Match 'no-op'
        $script:lastPatchArgs | Should -BeNullOrEmpty
        $script:getCallCount | Should -Be 0
    }

    It 'does not call Add-CommentBlocks (independent sibling function, prose mentions of the name are fine)' {
        $srcPath = Join-Path $PSScriptRoot '..' 'lib' 'phase-containment-emission-check-core.ps1'
        $src = Get-Content -LiteralPath $srcPath -Raw
        $funcStart = $src.IndexOf('function Add-JudgeRulingsBlock')
        $funcStart | Should -BeGreaterThan -1
        $funcBody = $src.Substring($funcStart)
        # A CALL to Add-CommentBlocks (bare invocation syntax) would be the
        # real independence violation; the docstring legitimately mentions
        # the sibling's name in prose explaining the design relationship.
        $funcBody | Should -Not -Match '(?<!\.SYNOPSIS[\s\S]{0,2000})\bAdd-CommentBlocks\s+-Owner'
        $funcBody | Should -Not -Match '\(\s*Add-CommentBlocks\b'
    }

    It 'does not call ConvertFrom-Yaml or import powershell-yaml (hand-rolled regex only; the SECURITY note is prose, not code)' {
        $srcPath = Join-Path $PSScriptRoot '..' 'lib' 'phase-containment-emission-check-core.ps1'
        $src = Get-Content -LiteralPath $srcPath -Raw
        $funcStart = $src.IndexOf('function Add-JudgeRulingsBlock')
        $funcBody = $src.Substring($funcStart)

        # Strip the <# ... #> comment-based help block and line comments
        # first, so prose mentions of these forbidden names (e.g. the
        # .DESCRIPTION explaining what NOT to use) don't false-positive this
        # executable-usage check.
        $codeOnly = [regex]::Replace($funcBody, '(?s)<#.*?#>', '')
        $codeOnly = ($codeOnly -split "`n" | ForEach-Object { [regex]::Replace($_, '#.*$', '') }) -join "`n"

        $codeOnly | Should -Not -Match 'ConvertFrom-Yaml'
        $codeOnly | Should -Not -Match 'powershell-yaml'
    }
}

# ---------------------------------------------------------------------------
# PF2-F1 (issue #782 post-fix prosecution pass): drift-catching meta-test.
# The GH-5 fix added a fourth literal copy of the key-anchor regex
# '(?:^\s*(?:-\s+)?|[{,]\s*)' (Get-DesignChallengeSustainedCountInternal) on
# top of the three pre-existing copies (Test-EmissionMarkerPresent's vocab
# window, the ambiguity-walk detector, and
# Get-JudgeRulingsSustainedCountInternal's $keyAnchor). A stale comment
# claimed only three copies existed and must be kept in sync; this test is
# the tripwire so a future edit to one copy that is not propagated to the
# others fails CI instead of silently drifting.
#
# 811 M1 fix (post-fix adversarial pass) added a fifth literal copy: the
# duplicate-head vocab gate in Get-JudgeRulingsSustainedCountInternal now
# vocab-gates each candidate head match before counting it toward the 2+
# duplicate threshold, using this same byte-identical anchor, so a bare
# prose mention of the marker convention no longer counts as a real head.
#
# GH-3 fix (PR #815 review, post-#811 review pass): the count intentionally
# drops from five to four literal copies. Test-EmissionMarkerPresent's
# standalone vocab-window check and Get-JudgeRulingsSustainedCountInternal's
# duplicate-head vocab-gate check (the two copies added by the M6 and 811 M1
# fixes referenced above) were both first-match-only scans, which let a
# vocab-gate-failing decoy head positioned before a real head suppress
# detection of the real one (false could-not-verify on plan-stress-test,
# silent false-clean on code-review). Both call sites now delegate to the
# single shared helper Get-RealJudgeRulingsHeadMatches, which scans ALL
# head candidates and applies the vocab gate via one shared constant,
# $script:JudgeRulingsVocabGatePattern — collapsing those two standalone
# copies into one. The remaining four copies (the shared constant itself,
# the ambiguity-walk detector, and the two $keyAnchor counting-side copies
# in Get-JudgeRulingsSustainedCountInternal / Get-DesignChallengeSustainedCountInternal)
# are unaffected by this consolidation and must still stay byte-identical.
#
# issue #768 s3: the count intentionally rises from four to five literal
# copies. Get-ReviewDispositionsTallyInternal (new, backs Get-DispositionTally's
# code-review branch) needs the SAME real-YAML-key-position anchor to read
# `disposition:`/`reviewer_source:` only at a genuine key position within
# each per-entry span, so it declares its own local $keyAnchor copy rather
# than reaching across functions for one of the existing four. This is a
# tracked, expected addition (the same kind of evolution the GH-5 and 811 M1
# fixes above went through), not untracked drift.
# ---------------------------------------------------------------------------

Describe 'Key-anchor pattern — all literal copies stay byte-identical (PF2-F1 drift guard)' {
    It 'finds exactly five literal copies of the key-anchor pattern, all byte-identical' {
        $srcPath = Join-Path $PSScriptRoot '..' 'lib' 'phase-containment-emission-check-core.ps1'
        $src = Get-Content -LiteralPath $srcPath -Raw
        $copies = [regex]::Matches($src, [regex]::Escape('(?:^\s*(?:-\s+)?|[{,]\s*)'))
        $copies.Count | Should -Be 5
        @($copies.Value | Select-Object -Unique).Count | Should -Be 1
    }
}

# ---------------------------------------------------------------------------
# 811-D1 s4: writer-contract verification (skills/plan-authoring/SKILL.md).
#
# These tests prove the writer contract just documented in
# skills/plan-authoring/SKILL.md § Judge-rulings machine block (811-D1) is
# actually parseable by the live reader in this file, not merely asserted in
# prose. They do not modify Test-EmissionMarkerPresent, Get-EmissionGap,
# Get-SustainedFindingCount, Add-CommentBlocks, or Add-JudgeRulingsBlock.
# ---------------------------------------------------------------------------

Describe '811-D1 s4: heading literal-parity (SKILL template vs s1 fallback regex)' {
    It 'the plan-markdown template heading in the SKILL matches the exact line-start literal Test-EmissionMarkerPresent''s fallback matches on' {
        $skillPath = Join-Path $PSScriptRoot '..' '..' '..' 'skills' 'plan-authoring' 'SKILL.md'
        $skillText = Get-Content -LiteralPath $skillPath -Raw
        # Same literal the fallback in Test-EmissionMarkerPresent tests against.
        $fallbackHeadingRegex = '(?m)^\*\*Plan Stress-Test\*\*'
        $skillText | Should -Match $fallbackHeadingRegex

        # Directly prove the pinned regex literal, read live from source
        # rather than retyped here, actually appears verbatim (as PowerShell
        # source text) in the core library — so this test fails loud if the
        # reader's own literal ever drifts, not just if the SKILL's copy
        # drifts. This is a literal substring check (Contains), not a regex
        # match: the source text itself already contains the regex
        # metacharacters we are looking for.
        $corePath = Join-Path $PSScriptRoot '..' 'lib' 'phase-containment-emission-check-core.ps1'
        $coreText = Get-Content -LiteralPath $corePath -Raw
        $coreText.Contains('(?m)^\*\*Plan Stress-Test\*\*') | Should -Be $true
    }
}

Describe '811-D1 s4: writer/reader round-trip — block-shape literal-parity (M7)' {
    It 'an aggregate prose bullet (M10-M13, M16) expanded per-finding_id parses to 5 sustained, plus 1 defense-sustained (M17) excluded' {
        $result = Get-SustainedFindingCount -Surface 'plan-stress-test' -Body $script:WriterContractExpandedBody
        $result.ParseStatus | Should -Be 'ok'
        $result.SustainedCount | Should -Be 5
    }

    It 'the same fixture is reachable end-to-end through Get-EmissionGap (marker detected, no blocks posted yet -> Gap = SustainedCount)' {
        $result = Get-EmissionGap -Bodies @($script:WriterContractExpandedBody) -Id 9101 -Surface 'plan-stress-test'
        $result.ParseStatus | Should -Be 'ok'
        $result.SustainedCount | Should -Be 5
        $result.BlockCount | Should -Be 0
        $result.Gap | Should -Be 5
        $result.Reason | Should -Be 'ok'
    }

    It 'M4 fix: the pinned zero-findings placeholder literal actually extracted from skills/plan-authoring/SKILL.md''s live source text matches the hand-authored $script:WriterContractZeroFindingsBody fixture''s two-line shape, so a silent SKILL.md drift breaks this test rather than passing unnoticed' {
        # Genuine cross-file check (issue #811 post-fix adversarial pass, M4):
        # unlike the other tests in this Describe block, which only round-trip
        # hand-authored fixture strings through the reader, this test reads
        # SKILL.md's actual text and extracts writer rule 7's pinned
        # zero-findings placeholder block directly from the live file, rather
        # than re-typing it. If SKILL.md's pinned literal (field order,
        # indentation, or the exact `- finding_id: none` /
        # `  judge_ruling: defense-sustained` two-line shape) ever drifts
        # without a matching fixture update, this test fails loud instead of
        # the suite passing against a stale copy.
        $skillPath = Join-Path $PSScriptRoot '..' '..' '..' 'skills' 'plan-authoring' 'SKILL.md'
        $skillText = Get-Content -LiteralPath $skillPath -Raw

        # Extract the fenced ```markdown ... ``` code block that immediately
        # follows writer rule 7's "Zero-findings placeholder" heading text.
        $ruleMatch = [regex]::Match(
            $skillText,
            '(?s)Zero-findings placeholder.*?```markdown\r?\n(.*?)```'
        )
        $ruleMatch.Success | Should -Be $true

        $fencedBlock = $ruleMatch.Groups[1].Value

        # The fenced block is indented (nested under a numbered list item);
        # strip the common leading whitespace per line before comparing, so
        # this test is robust to Markdown list-nesting indentation without
        # being robust to an actual content/shape drift.
        $dedentedLines = ($fencedBlock -split "`r?`n") | ForEach-Object { $_ -replace '^\s{0,3}', '' }
        $dedented = ($dedentedLines -join "`n").Trim()

        $expectedLiveShape = @"
<!-- judge-rulings
- finding_id: none
  judge_ruling: defense-sustained
-->
"@
        $dedented | Should -Be $expectedLiveShape

        # Now prove the hand-authored fixture used throughout this suite
        # carries the SAME two-line entry shape (the part the reader
        # actually parses), byte-for-byte.
        $fixtureEntryMatch = [regex]::Match(
            $script:WriterContractZeroFindingsBody,
            '(?s)- finding_id: none\r?\n\s*judge_ruling: defense-sustained'
        )
        $fixtureEntryMatch.Success | Should -Be $true

        $liveEntryMatch = [regex]::Match($dedented, '(?s)- finding_id: none\r?\n\s*judge_ruling: defense-sustained')
        $liveEntryMatch.Success | Should -Be $true
        $fixtureEntryMatch.Value | Should -Be $liveEntryMatch.Value
    }
}

Describe '811-D1 s4: writer/reader round-trip — zero-findings placeholder (M11/SC-F6)' {
    It 'the pinned "- finding_id: none / judge_ruling: defense-sustained" placeholder parses to SustainedCount=0, ParseStatus=ok (true clean, not could-not-verify)' {
        $result = Get-SustainedFindingCount -Surface 'plan-stress-test' -Body $script:WriterContractZeroFindingsBody
        $result.ParseStatus | Should -Be 'ok'
        $result.SustainedCount | Should -Be 0
    }

    It 'Get-EmissionGap reports a clean Reason (ok) for the placeholder body, never head-missing or head-corrupt' {
        $result = Get-EmissionGap -Bodies @($script:WriterContractZeroFindingsBody) -Id 9102 -Surface 'plan-stress-test'
        $result.ParseStatus | Should -Be 'ok'
        $result.Reason | Should -Be 'ok'
        $result.Gap | Should -Be 0
    }
}

Describe '811-D1 s4: writer/reader round-trip — prose-marker-mention fixture (M10)' {
    It 'a plan body narrating the judge-rulings marker convention inertly (inside a code span) still parses the real block correctly' {
        $result = Get-SustainedFindingCount -Surface 'plan-stress-test' -Body $script:WriterContractProseMentionBody
        $result.ParseStatus | Should -Be 'ok'
        $result.SustainedCount | Should -Be 1
    }

    It 'the prose mention does not create a second detected head (no duplicate-head could-not-verify false-positive)' {
        $result = Get-EmissionGap -Bodies @($script:WriterContractProseMentionBody) -Id 9103 -Surface 'plan-stress-test'
        $result.ParseStatus | Should -Be 'ok'
        $result.Reason | Should -Be 'ok'
        $result.SustainedCount | Should -Be 1
    }
}

# ---------------------------------------------------------------------------
# issue #768 s3: Get-DispositionTally — per-entry segmented tally across all
# three surfaces, plus the AC8 byte-identical regression for
# Get-SustainedFindingCount.
# ---------------------------------------------------------------------------

Describe 'Get-DispositionTally - code-review surface (review-dispositions marker, joint per-entry projection)' {
    It 'segments a mixed v1/v2/v3 body into 3 per-entry tuples with the correct joint fields' {
        $result = Get-DispositionTally -Surface 'code-review' -Body $script:ReviewDispositionsBasicBody
        $result.ParseStatus | Should -Be 'ok'
        $result.Entries.Count | Should -Be 3

        $result.Entries[0].StableFindingKey | Should -Be 'file.ps1:10:abc123'
        $result.Entries[0].Disposition | Should -Be 'incorporate'
        $result.Entries[0].Stage | Should -Be 'code-review'
        $result.Entries[0].ReviewerSource | Should -Be 'local'

        $result.Entries[1].StableFindingKey | Should -Be 'file.ps1:22:def456'
        $result.Entries[1].Disposition | Should -Be 'dismiss'
        $result.Entries[1].ReviewerSource | Should -Be 'gemini'

        # v1-shaped entry: no severity/stage/reviewer_source fields at all.
        # stage must default to 'code-review'; reviewer_source must be null,
        # not miscounted or defaulted to a guessed value.
        $result.Entries[2].StableFindingKey | Should -Be 'file.ps1:33:ghi789'
        $result.Entries[2].Disposition | Should -Be 'defer'
        $result.Entries[2].Stage | Should -Be 'code-review'
        $result.Entries[2].ReviewerSource | Should -BeNullOrEmpty
    }

    It 'can build the AC1 marginal (dismiss/defer counts) from the same Entries data' {
        $result = Get-DispositionTally -Surface 'code-review' -Body $script:ReviewDispositionsBasicBody
        $dismissCount = @($result.Entries | Where-Object { $_.Disposition -eq 'dismiss' }).Count
        $deferCount = @($result.Entries | Where-Object { $_.Disposition -eq 'defer' }).Count
        $dismissCount | Should -Be 1
        $deferCount | Should -Be 1
    }

    It 'can build the AC2 per-source x disposition joint table from the same Entries data' {
        $result = Get-DispositionTally -Surface 'code-review' -Body $script:ReviewDispositionsBasicBody
        $byGemini = @($result.Entries | Where-Object { $_.ReviewerSource -eq 'gemini' })
        $byGemini.Count | Should -Be 1
        $byGemini[0].Disposition | Should -Be 'dismiss'
    }

    It 'excludes a stage: ce entry, keeping only the stage: code-review entry' {
        $result = Get-DispositionTally -Surface 'code-review' -Body $script:ReviewDispositionsStageCeExclusionBody
        $result.ParseStatus | Should -Be 'ok'
        $result.Entries.Count | Should -Be 1
        $result.Entries[0].StableFindingKey | Should -Be 'a.ps1:1:aaa'
        $result.Entries[0].Stage | Should -Be 'code-review'
    }
}

Describe 'Get-DispositionTally - code-review surface decoy hardening (M3, judge-sustained)' {
    It 'does not misread a nested ac_cross_check.source field as reviewer_source (collision guard)' {
        $result = Get-DispositionTally -Surface 'code-review' -Body $script:ReviewDispositionsAcCrossCheckSourceDecoyBody
        $result.ParseStatus | Should -Be 'ok'
        $result.Entries.Count | Should -Be 1
        $result.Entries[0].ReviewerSource | Should -BeNullOrEmpty
        $result.Entries[0].Disposition | Should -Be 'dismiss'
    }

    It 'does not let a disposition_rationale block scalar quoting "disposition: dismiss" inflate or flip the real disposition' {
        $result = Get-DispositionTally -Surface 'code-review' -Body $script:ReviewDispositionsRationaleBlockScalarDecoyBody
        $result.ParseStatus | Should -Be 'ok'
        $result.Entries.Count | Should -Be 1
        $result.Entries[0].Disposition | Should -Be 'incorporate'
    }

    It 'does not split an injected-newline reviewer_source value into a phantom second entry' {
        $result = Get-DispositionTally -Surface 'code-review' -Body $script:ReviewDispositionsInjectedNewlineDecoyBody
        $result.ParseStatus | Should -Be 'ok'
        $result.Entries.Count | Should -Be 1
        $result.Entries[0].Disposition | Should -Be 'incorporate'
    }

    It 'returns could-not-verify (never miscounted as a real entry) for a bare prose mention of the marker convention' {
        $result = Get-DispositionTally -Surface 'code-review' -Body $script:ReviewDispositionsProseMentionOnlyBody
        $result.ParseStatus | Should -Be 'could-not-verify'
        $result.Entries.Count | Should -Be 0
    }
}

Describe 'Get-DispositionTally - code-review surface CM1/CM12 regression (judge-sustained, PR #833 review)' {
    It 'does not treat a "- finding_id:" entry-boundary key embedded inside a disposition_rationale block scalar as a real second entry' {
        $result = Get-DispositionTally -Surface 'code-review' -Body $script:ReviewDispositionsBlockScalarPhantomEntryBody
        $result.ParseStatus | Should -Be 'ok'
        $result.Entries.Count | Should -Be 1
        $result.Entries[0].StableFindingKey | Should -Be 'e.ps1:1:fff'
        $result.Entries[0].Disposition | Should -Be 'incorporate'
    }

    It 'routes an entry with an empty/missing stable_finding_key on the code-review surface to could-not-verify, never silent key="" participation' {
        $result = Get-DispositionTally -Surface 'code-review' -Body $script:ReviewDispositionsFindingIdOnlyNoStableKeyBody
        $result.ParseStatus | Should -Be 'could-not-verify'
    }
}

Describe 'Get-DispositionTally - code-review surface CM7 regression: quoted YAML scalars (judge-sustained, PR #833 review)' {
    It 'keeps an entry whose stage value is double-quoted YAML ("code-review") instead of silently dropping it' {
        $result = Get-DispositionTally -Surface 'code-review' -Body $script:ReviewDispositionsQuotedStageBody
        $result.ParseStatus | Should -Be 'ok'
        $result.Entries.Count | Should -Be 1
        $result.Entries[0].Stage | Should -Be 'code-review'
    }

    It 'dequotes a single-quoted reviewer_source value so it groups with the bare equivalent, not a phantom distinct source' {
        $result = Get-DispositionTally -Surface 'code-review' -Body $script:ReviewDispositionsQuotedReviewerSourceBody
        $result.ParseStatus | Should -Be 'ok'
        $result.Entries.Count | Should -Be 2
        $distinctSources = @($result.Entries.ReviewerSource | Select-Object -Unique)
        $distinctSources.Count | Should -Be 1
        $distinctSources[0] | Should -Be 'copilot'
    }
}

Describe 'Get-DispositionTally - code-review surface near-decoy window-bleed regression (issue #817 sibling bug)' {
    It 'returns BOTH entries when the second entry''s boundary immediately follows the first entry''s block-scalar trailing blank line' {
        $result = Get-DispositionTally -Surface 'code-review' -Body $script:ReviewDispositionsNearDecoyWindowBleedBody
        $result.ParseStatus | Should -Be 'ok'
        $result.Entries.Count | Should -Be 2
        $result.Entries[0].StableFindingKey | Should -Be 'k.ps1:1:kkk'
        $result.Entries[0].Disposition | Should -Be 'incorporate'
        $result.Entries[1].StableFindingKey | Should -Be 'k.ps1:2:lll'
        $result.Entries[1].Disposition | Should -Be 'dismiss'
    }
}

Describe 'Get-DispositionTally - code-review surface fail-loud paths (DD3)' {
    It 'returns could-not-verify for a body with no review-dispositions marker at all' {
        $result = Get-DispositionTally -Surface 'code-review' -Body $script:ReviewDispositionsNoMarkerBody
        $result.ParseStatus | Should -Be 'could-not-verify'
    }

    It 'returns could-not-verify for a real head with zero segmentable entries, never a confident zero' {
        $result = Get-DispositionTally -Surface 'code-review' -Body $script:ReviewDispositionsZeroEntriesBody
        $result.ParseStatus | Should -Be 'could-not-verify'
    }

    It 'returns could-not-verify for an empty body' {
        $result = Get-DispositionTally -Surface 'code-review' -Body ''
        $result.ParseStatus | Should -Be 'could-not-verify'
    }
}

Describe 'Get-DispositionTally - design-challenge surface (sustained, defense-sustained pair)' {
    It 'returns SustainedCount=6, DefenseSustainedCount=0 for the live #782 design block (no defense-sustained concept in this marker shape)' {
        $result = Get-DispositionTally -Surface 'design-challenge' -Body $script:Design782Body
        $result.ParseStatus | Should -Be 'ok'
        $result.SustainedCount | Should -Be 6
        $result.DefenseSustainedCount | Should -Be 0
    }

    It 'returns SustainedCount=2, DefenseSustainedCount=0 for the incorporate/escalate/dismiss fixture' {
        $result = Get-DispositionTally -Surface 'design-challenge' -Body $script:DesignDismissBody
        $result.ParseStatus | Should -Be 'ok'
        $result.SustainedCount | Should -Be 2
        $result.DefenseSustainedCount | Should -Be 0
    }
}

Describe 'Get-DispositionTally - plan-stress-test surface (sustained, defense-sustained pair)' {
    It 'returns SustainedCount=2, DefenseSustainedCount=1 for the by-analogy judge-rulings fixture' {
        $result = Get-DispositionTally -Surface 'plan-stress-test' -Body $script:PlanStressTestBody
        $result.ParseStatus | Should -Be 'ok'
        $result.SustainedCount | Should -Be 2
        $result.DefenseSustainedCount | Should -Be 1
    }

    It 'returns could-not-verify for an unrecognized/malformed body, never a confident zero' {
        $result = Get-DispositionTally -Surface 'plan-stress-test' -Body $script:MalformedBody
        $result.ParseStatus | Should -Be 'could-not-verify'
    }
}

Describe 'Get-DispositionTally - AC8 regression: Get-SustainedFindingCount public output stays byte-identical' {
    It 'still returns exactly {SustainedCount; ParseStatus} (no new properties leaked) across a fixed corpus' {
        $fixedCorpus = @(
            @{ Surface = 'code-review'; Body = $script:Pr775Body; ExpectedCount = 2 }
            @{ Surface = 'code-review'; Body = $script:Pr778Body; ExpectedCount = 10 }
            @{ Surface = 'code-review'; Body = $script:Pr781Body; ExpectedCount = 4 }
            @{ Surface = 'design-challenge'; Body = $script:Design782Body; ExpectedCount = 6 }
            @{ Surface = 'design-challenge'; Body = $script:DesignDismissBody; ExpectedCount = 2 }
            @{ Surface = 'plan-stress-test'; Body = $script:PlanStressTestBody; ExpectedCount = 2 }
        )

        foreach ($case in $fixedCorpus) {
            $result = Get-SustainedFindingCount -Surface $case.Surface -Body $case.Body
            $result.ParseStatus | Should -Be 'ok'
            $result.SustainedCount | Should -Be $case.ExpectedCount

            # Byte-identical shape assertion (AC8): exactly two properties,
            # SustainedCount and ParseStatus — DefenseSustainedCount must
            # never leak into this function's public output.
            $propertyNames = @($result.PSObject.Properties.Name | Sort-Object)
            $propertyNames | Should -Be @('ParseStatus', 'SustainedCount')
        }
    }
}

Describe 'Get-BlockScalarSpans - EXT-F1 regression: CRLF-terminated key line is detected' {
    # PR #843 external review (EXT-F1, low, defense-in-depth): the key-line
    # pattern ended `[ \t]*$`, which in .NET multiline mode does not match
    # before `\r\n` (only before a bare `\n`), so a CRLF-terminated
    # `key: |`/`key: >` header was silently missed and its content lines
    # were never excluded as block-scalar spans. Not currently exploitable
    # in production (GitHub normalizes comment bodies to LF) but hardened
    # here since this function's whole purpose is defending against
    # untrusted input.

    It 'detects a block-scalar span for a CRLF-terminated `key: |` header' {
        $text = "disposition_rationale: |`r`n  line one`r`n  line two`r`n"
        $spans = Get-BlockScalarSpans -Text $text

        $spans.Count | Should -Be 1
    }

    It 'detects a block-scalar span for a CRLF-terminated `key: >` header' {
        $text = "disposition_rationale: >`r`n  line one`r`n  line two`r`n"
        $spans = Get-BlockScalarSpans -Text $text

        $spans.Count | Should -Be 1
    }
}
