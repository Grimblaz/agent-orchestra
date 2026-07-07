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
# ---------------------------------------------------------------------------

Describe 'Key-anchor pattern — all literal copies stay byte-identical (PF2-F1 drift guard)' {
    It 'finds exactly four literal copies of the key-anchor pattern, all byte-identical' {
        $srcPath = Join-Path $PSScriptRoot '..' 'lib' 'phase-containment-emission-check-core.ps1'
        $src = Get-Content -LiteralPath $srcPath -Raw
        $copies = [regex]::Matches($src, [regex]::Escape('(?:^\s*(?:-\s+)?|[{,]\s*)'))
        $copies.Count | Should -Be 4
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
