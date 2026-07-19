# Marker-Reader Inventory (issue #878, s1)

Exhaustive scan of raw-text HTML-comment-marker scanning sites across
`.github/scripts/**` and `skills/**/scripts/**`, produced for [issue #878](https://github.com/Grimblaz/agent-orchestra/issues/878) Part C
(per-pattern regex anchoring). This file is the s1 deliverable; s6 consumes
it to apply anchoring per family. **Non-goals of this document: no source
edits, no review-judgment PR-surface emission work.**

## Classification legend

- **block-selector** — extracts the content span between a marker's open and
  (optional) close token, or a single fenced/dot-all payload.
- **presence-gate** — boolean "does this marker/vocabulary exist" check
  (`-match`, `[regex]::IsMatch`, `.Contains`) that routes control flow.
- **count-validator** — counts occurrences (of a head, an entry, or a value)
  and compares against an expected count or threshold.
- **splice-writer** — reads, then writes back a modified body (concatenate,
  replace-in-place, or insert-before-cursor).
- **comment-selector** — selects a whole GitHub comment out of a set by
  wildcard/substring containment (`-like`, `Find-OrUpsertComment`'s matcher),
  as opposed to matching a byte position inside one already-fetched body.

**Polarity rule (load-bearing):** never narrow a presence-gate whose `$true`
branch is the fail-loud path (the path that keeps the check honest/loud,
e.g. "marker present, do not silently treat as ordinary chatter" or "marker
present, must now parse cleanly or could-not-verify"). Narrowing such a gate
makes it match less, which flips real cases to `$false`, which is the quiet
branch — a false clean. Conversion difficulty must never drive
classification; a bare `IsMatch` is the easiest site to anchor and the most
dangerous one to anchor wrong.

## Excluded from anchoring (polarity)

### `phase-containment-emission-check-core.ps1:800` — the worked example

```powershell
$hasPlanIssueMarker = [regex]::IsMatch($Body, '<!--\s*plan-issue-')
$hasPlanStressTestHeading = [regex]::IsMatch($Body, '(?m)^\*\*Plan Stress-Test\*\*')
if ($hasPlanIssueMarker -and $hasPlanStressTestHeading) { return $true }
```

Inside `Test-EmissionMarkerPresent`'s plan-stress-test-only fallback. Its
docstring at `:679-682` states the reason directly: a plan persisted before
the 811 writer change carries a prose-only "Plan Stress-Test" section with
no machine-readable judge-rulings block at all. Treating that as "no marker
at all" renders a false `clean -- sustained=0 blocks=0`. The `$true` branch
here is the fail-loud path (it forces the caller into "marker present, must
parse or could-not-verify" instead of "ordinary chatter, contributes 0").
Narrowing `'<!--\s*plan-issue-'` (e.g. adding a line-start anchor) would
make legitimate historical placements fail the gate and silently manufacture
the exact false clean this fallback exists to prevent. **Excluded from
anchoring.**

### `phase-containment-cost-core.ps1:93-94` — duplicate of the :800 site

```powershell
$hasPlanIssueMarker = [regex]::IsMatch($Body, '<!--\s*plan-issue-')
$hasPlanStressTestHeading = [regex]::IsMatch($Body, '(?m)^\*\*Plan Stress-Test\*\*')
if ($hasPlanIssueMarker -and $hasPlanStressTestHeading) { return $true }
```

Inside `Test-JudgeRulingsRealHeadPresent`'s `-Surface 'plan-stress-test'`
branch. The docstring at `:64-77` explicitly says it "mirrors
Test-EmissionMarkerPresent's 811-D1 prose-body fallback." Byte-identical
literals, byte-identical polarity, byte-identical rationale — **same
exclusion, second file**. s6 must not anchor this copy while leaving :800
alone, or vice versa; they must be treated as one logical site with two
physical locations.

## Structurally unanchorable

### `phase-containment-core.ps1` `Get-PhaseContainmentBlock` (`:225-226,233,242,257`)

```powershell
$openTag  = "<!-- phase-containment-$Id -->"
$closeTag = "<!-- /phase-containment-$Id -->"
...
$startIdx = $Text.IndexOf($openTag, $searchFrom, [System.StringComparison]::Ordinal)   # :233
$endIdx   = $Text.IndexOf($closeTag, $contentStart, [System.StringComparison]::Ordinal) # :242
$nextOpenIdx = $Text.IndexOf($openTag, $contentStart, [System.StringComparison]::Ordinal) # :257
```

Uses `[string]::IndexOf` (ordinal substring search), not `[regex]`. There is
no regex to anchor — the open/close tags are already full literal strings
with `$Id` interpolated, so this is already maximally precise on its own
terms. What it lacks is *position*-anchoring (line-start), which regex
anchoring cannot add to an `IndexOf` call without rewriting the whole scan
as a regex loop — a structural change, not a pattern tightening. Recorded
disposition: **`structurally-unanchorable, degrades to warn`**, citing the
pair-match recovery at `:257-262` (an unclosed open tag is detected and
skipped via the next-open-tag lookahead, converting a would-be silent
absorption bug into a `Write-Warning` + `-SkippedCount` increment — the
existing warn-only backstop for this class).

## Already-anchored precedents (comparison baseline)

| Site | Pattern | Notes |
| --- | --- | --- |
| `frame-engagement-record-core.ps1:180` | `'(?m)^\s*<!--\s*engagement-record-([a-zA-Z0-9_-]+)-(\d+)\s*-->'` | Multiline `^` line-start anchor. The plan's cited anchored-precedent example. |
| `review-dispositions-validator-core.ps1:92` | `'(?m)^\s*<!--\s*review-dispositions-(\d+)\s*-->'` | Same anchoring idiom, different file. |
| `followup-gate-core.ps1:102` | `'(?m)^\s*<!--\s*proposed-followups-(\d+)\s*-->'` | Same idiom, third family. |

These three establish the target shape for s6: `(?m)^\s*<!--\s*{family}-...\s*-->`.

## Site inventory by marker family

Columns: **Site** (`path:line`), **Class**, **Pattern text** (literal or
abbreviated), **Alternation**, **End-anchor**, **Polarity verdict**
(presence-gates only), **Notes**.

### judge-rulings (bare `<!-- judge-rulings` / attributed `pr=N` / `finding_dispositions:`)

| Site | Class | Pattern | Alternation | End-anchor | Polarity | Notes |
| --- | --- | --- | --- | --- | --- | --- |
| `phase-containment-emission-check-core.ps1:36` | block-selector (head) | `'<!--\s*judge-rulings(?:\s\|-->\|$)'` | grouped, non-capturing (`\s`\|`-->`\|`$`) | one branch ends `$` | n/a | Single source of truth; matched at `:351`. Consumed transitively by 5 call sites documented in the function's own docstring: `:478` (`Get-JudgeRulingsDuplicateDiagnosis`), `:778` (`Test-EmissionMarkerPresent`), `:1974` (`Get-JudgeRulingsIsolatedRegion`'s M1 duplicate-head guard), `:2558` (cross-body sibling-has-real-head check), `:2599` (design-challenge branch's sibling `hasRealHead`, itself a *separate* raw `[regex]::IsMatch` at that same line, not the shared pattern — see below). Also transitively reached by `Add-JudgeRulingsBlock`'s preflight (`~:3305`, via `Get-DispositionTally -Surface 'plan-stress-test'` → `Get-JudgeRulingsSustainedCountInternal` → `Get-JudgeRulingsIsolatedRegion` → `Get-RealJudgeRulingsHeadMatches` → `:351`) — the coupling M21 flagged, confirmed live even though the literal call is not textually at `:3306` in the current file (line-number drift since the plan was authored; the dependency itself is real and s6 must re-run `persist-phase-ledger.Tests.ps1` per the plan's own instruction). |
| `phase-containment-emission-check-core.ps1:747` | block-selector (head) | `'(?m)^finding_dispositions\s*:\s*$'` | none | `$` (multiline) | n/a | design-challenge branch of `Test-EmissionMarkerPresent`. Already line-anchored. |
| `phase-containment-emission-check-core.ps1:751` | presence-gate (vocab) | `'(?m)^\s*(disposition\|finding_id\|schema_version)\s*:'` | grouped (3-way) | none | **true→fail-loud** (marker present → must parse or could-not-verify) | Vocab-gate window check, design-challenge branch. Anchor-eligible (not the :800/:93-94 fallback shape). |
| `phase-containment-emission-check-core.ps1:2005` | presence-gate | `'\G<!--\s*judge-rulings\s+pr=\d+\s*-->'` | none | none (`\G` start-anchor only) | n/a (selection, not gate) | Attributed-form re-test at each vocab-gated candidate's own index via `\G`. **Do not swap `\s` for `^` here** — `\G` anchors to the candidate's own `.Index` inside `Body.Substring(...)`, and a line-start anchor would be redundant/wrong since the substring already starts mid-body. |
| `phase-containment-emission-check-core.ps1:2231` | block-selector (head) | `'(?m)^finding_dispositions\s*:\s*$'` | none | `$` | n/a | `Get-DesignChallengeSustainedCountInternal`; byte-identical to `:747` — the meta-test's "four copies of `$keyAnchor`" precedent (see below) but this pair is the head pattern, not `$keyAnchor`. |
| `phase-containment-emission-check-core.ps1:2599-2601` | presence-gate | `'(?m)^finding_dispositions\s*:\s*$'` (via `[regex]::IsMatch`) | none | `$` | n/a | Third occurrence of the identical design-challenge head literal, this time as a boolean `hasRealHead` check inside `Get-EmissionGap`'s per-body loop. |
| `frame-credit-ledger-core.ps1:1178` | block-selector | `'(?ms)<!--\s*judge-rulings\s*\r?\n(?<body>.*?)\r?\n-->'` | none | requires `\r?\n-->` (structural close) | n/a | `ConvertFrom-JudgeRulingsComment` — the **PR-surface** reader (`- id:`/`points_awarded` shape), distinct from the plan-surface reader above. **No vocab gate** — unlike `Get-RealJudgeRulingsHeadMatches`, this is a bare first-match `[regex]::Match` with no defense against a prose mention of the marker convention preceding a real block. Flagged as a gap for s6 to weigh (anchoring alone does not add vocab-gating). |
| `frame-credit-ledger-core.ps1:1201` | presence-gate / selector | `-match '<!--\s*judge-rulings'` | none | none | n/a (selection filter, `Select-Object -Last 1`) | Filters `$script:PrComments` down to the comment(s) carrying a judge-rulings head before feeding `ConvertFrom-JudgeRulingsComment`. Unanchored. |
| `frame-back-derive-core.ps1:136-138` | presence-gate (AND-combined) | 3× `[regex]::IsMatch($MetricsBlock, '(?m)^\s*{findings\|defense_verdict\|judge_ruling}\s*:')` | none each | none | n/a | Already `(?m)^\s*` anchored per-field; not part of the unanchored cluster. |

### phase-containment-{ID} (block open/close pair, and the `-ledger-` sentinel)

| Site | Class | Pattern | Alternation | End-anchor | Polarity | Notes |
| --- | --- | --- | --- | --- | --- | --- |
| `phase-containment-core.ps1:225-226,233,242,257` | block-selector | literal `IndexOf`, not regex | n/a | n/a | n/a | See **Structurally unanchorable** above. |
| `phase-containment-emission-check-core.ps1:2863` | count-validator input | `'<!--\s*phase-containment-(?!ledger-)([A-Za-z0-9_-]+)\s*-->'` | none | none | n/a | `Add-AppendedAtStampToPhaseContainmentBlocks` open-tag scan; negative lookahead already excludes the `-ledger-` sentinel (F5 fix). Anchor-eligible. |
| `phase-containment-emission-check-core.ps1:2998` | count-validator (no-op guard) | same pattern as `:2863` | none | none | n/a | `Add-CommentBlocks` preflight; refuses zero-block `NewContent` before any network call. |
| `phase-containment-emission-check-core.ps1:3129` | count-validator (post-write) | `'<!--\s*phase-containment-([A-Za-z0-9_-]+)\s*-->'` | none | none | n/a | Same family, **no** `(?!ledger-)` exclusion here — this one is fine because it drives an id-set fed back into `Get-PhaseContainmentBlock`, which already ignores the ledger sentinel structurally (no matching close tag → 0 blocks). |
| `phase-containment-emission-check-core.ps1:2555,2557` | presence-gate | `"<!-- phase-containment-ledger-$Id -->"` via `.Contains(...)` | n/a (literal) | n/a | **false→fail-loud** (opposite polarity from :800!) | `$anySiblingHasRealHead` computation. `$true` here *suppresses* a could-not-verify (863-s3 legitimate-sibling-move suppression); `$false` falls through to the branch that sets `$anyCouldNotVerify = $true`. Narrowing this (already a full literal `.Contains`, nothing to narrow) is safe; recorded for contrast with :800's polarity, not as an anchoring target. |
| `phase-containment-emission-check-core.ps1:2978,3118,3336,3392` | presence-gate | `.Contains($ExpectedMarker)` (caller-supplied substring, e.g. `'<!-- plan-issue-811'` or `'<!-- judge-rulings'`) | n/a | n/a | **false→fail-loud** | `Add-CommentBlocks`/`Add-JudgeRulingsBlock` pre- and post-write "original content survived" guard. `.Contains` is a literal substring test, not a regex — no anchoring surface. |

### review-dispositions-{N}

| Site | Class | Pattern | Alternation | End-anchor | Polarity | Notes |
| --- | --- | --- | --- | --- | --- | --- |
| `phase-containment-emission-check-core.ps1:1191` | block-selector (head) | `'<!--\s*review-dispositions-(\d+)\s*-->'` | none | none | n/a | `Get-RealReviewDispositionsHeadMatches`; vocab-gated (unlike the FCL-core PR-surface judge-rulings reader). Unanchored. |
| `review-dispositions-validator-core.ps1:92` | block-selector (head) | `'(?m)^\s*<!--\s*review-dispositions-(\d+)\s*-->'` | none | none | n/a | **Already anchored** — see precedent table. |
| `gate-reconciliation-core.ps1:209` | presence-gate / selector | `"<!--\s*review-dispositions-$PullRequestNumber\s*-->"` (interpolated) | none | none | n/a | `-match` filter selecting the latest-`CreatedAt` marker comment for the PR. Unanchored; PR number is already narrow (interpolated), but no line-start anchor. |
| `phase-containment-cost-core.ps1` (dot-sources emission-check-core, no separate copy) | — | — | — | — | — | `Test-ReviewDispositionsHeadPresent` was relocated (issue #854 s3) to `phase-containment-emission-check-core.ps1`; this file now only consumes it, no duplicate pattern. |

### pipeline-metrics (the largest unanchored cluster — 8+ independent copies)

| Site | Class | Pattern | Alternation | End-anchor | Polarity | Notes |
| --- | --- | --- | --- | --- | --- | --- |
| `frame-credit-ledger-core.ps1:709` | splice-writer | `'(?s)(?<open><!--\s*pipeline-metrics\s*)(?<block>.*?)(?<close>\s*-->)'` | none | none | n/a | `Set-FCLDispatchCostSamplesInPrBody`. Preserves consumed leading whitespace in the `open` capture group and re-emits it verbatim — anchoring must preserve this capture-and-replay shape, not just add `^`. |
| `frame-credit-ledger-core.ps1:750` | block-selector | `'(?s)<!--\s*pipeline-metrics\s*(?<block>.*?)\s*-->'` | none | none | n/a | `Read-PRMetricsBlock`. First-match-wins; the plan's cited exemplar. |
| `frame-credit-ledger-core.ps1:834` (top-level `frame-credit-ledger.ps1`) | splice-writer | `'(?s)(?<open><!--\s*pipeline-metrics\s*)(?<block>.*?)(?<close>\s*-->)'` | none | none | n/a | Wrapper-script duplicate of the `:709` pattern (same literal). |
| `frame-credit-ledger-core.ps1:942` | block-selector | `'(?s)<!--\s*pipeline-metrics(?![\w-])\s*(?<block>.*?)\s*-->'` | none | none | n/a | Note the negative lookahead `(?![\w-])` — a narrower variant already present in this file, guarding against `pipeline-metrics-foo` superstrings (same class of fix `phase-containment-emission-check-core.ps1`'s M9 applied to `judge-rulings`). The `:750`/`:709`/`:834` copies **lack** this lookahead — an inconsistency s6 should reconcile, not just anchor independently. |
| `frame-back-derive-core.ps1:62` | block-selector | `'(?s)<!--\s*pipeline-metrics\s*(<block>.*?)-->'` | none | none | n/a | Yet another independent copy, no negative lookahead, no line-start anchor. |
| `emit-pipeline-metrics-v4-core.ps1:235` | splice-writer | `'(?s)\s*<!--\s*pipeline-metrics.*?-->\s*'` | none | none | n/a | `[regex]::Replace` — strips an existing block before writing a new one. Greedy-safe (dot-all, lazy `.*?`) but unanchored. |
| `emit-pipeline-metrics-v4-core.ps1:244` | presence-gate | `-notmatch '<!--\s*pipeline-metrics'` | none | none | **true→fail-loud** (throws "already contains a pipeline-metrics opener" when match found, i.e. the *positive* match is the loud path here) | Guards `New-PipelineMetricsV4Block` against double-wrapping. Same shape as `frame-credit-ledger-core.ps1:2999-3000` (see below) — narrowing risks silently accepting an already-wrapped payload. |
| `frame-credit-ledger-core.ps1:2999-3000` | presence-gate (guard) | `-match '<!--\s*pipeline-metrics'` inside `New-PipelineMetricsV4Block` | none | none | **true→fail-loud** (throws) | Same "not-an-updater" guard as `emit-pipeline-metrics-v4-core.ps1:244`; two independent copies of the same guard idiom. |
| `backfill-calibration-core.ps1:61` | block-selector | `'(?s)<!--\s*pipeline-metrics\s*(.*?)-->'` | none | none | n/a | `skills/calibration-pipeline/scripts/`. Design-time-omitted site, confirmed by M11/M20; the plan's own citation ("carries the same unanchored first-match-wins pipeline-metrics pattern"). |
| `aggregate-review-scores-core.ps1:788` | block-selector | `'(?s)<!--\s*pipeline-metrics\s*(.*?)-->'` | none | none | n/a | Byte-identical to `backfill-calibration-core.ps1:61`. Design-time-omitted site, second half of the same M11 finding. |

**Observation for s6:** the pipeline-metrics family has *two* competing
shapes already live — plain `<!--\s*pipeline-metrics\s*...` (6 sites) and
lookahead-guarded `<!--\s*pipeline-metrics(?![\w-])\s*...` (2 sites,
`frame-credit-ledger-core.ps1:942` and, informally, the intent behind
`phase-containment-emission-check-core.ps1`'s M9 fix for `judge-rulings`).
Per-pattern anchoring in s6 should standardize on the lookahead-guarded
shape plus a line-start anchor, not just bolt `^` onto the weaker variant.

### plan-issue-{ID} / design-issue-{ID} / design-phase-complete-{ID} (combined "orchestration completion marker" alternation)

| Site | Class | Pattern | Alternation | End-anchor | Polarity | Notes |
| --- | --- | --- | --- | --- | --- | --- |
| `cost-fcl-helpers.ps1:95` | block-selector | `'(?im)<!--\s*(?:plan\|design)-issue-(?<issue>\d+)\s*-->'` | grouped, non-capturing | none | n/a | Case-insensitive multiline flag present but **no `^`** — `(?im)` alone doesn't anchor to line start without an explicit `^`. |
| `Get-FCLOriginContext.ps1:101` | block-selector | identical literal to `cost-fcl-helpers.ps1:95` | grouped | none | n/a | Second copy. |
| `gate-reconciliation-core.ps1:95` | block-selector | identical literal (same three files carry the exact same pattern — a drift-risk trio) | grouped | none | n/a | Third copy. No shared constant; three independent literals that must all be edited together in s6 or a drift-catching meta-test (matching the file's own `$keyAnchor` precedent, below) should be added. |
| `orchestra-spine.ps1:217` | block-selector | `'<!--\s*plan-issue-' + [regex]::Escape([string]$IssueNumber) + '\s*-->'` | none | none | n/a | Single-family (`plan-issue` only), issue-number pre-interpolated (already narrow on identity, not on position). |
| `gate-reconciliation-core.ps1:158` | presence-gate | `-notmatch '<!--\s*design-phase-complete'` | none | none | **false→fail-loud** (i.e. `-notmatch` true → `continue`/skip; a real marker missed by over-narrowing silently drops recorded findings) | Loop-skip guard before parsing `finding_dispositions:` YAML out of a design-phase-complete comment. |
| `phase-containment-rolling-history-core.ps1:711-712,781-782,1387-1388` | presence-gate (OR-combined) | `-match "<!--\s*design-phase-complete-$issueNum\s*-->"` **-or** `-match "<!--\s*plan-issue-$issueNum\s*-->"` (two separate `-match` calls, not one regex alternation) | code-level `-or`, not regex `\|` | none each | **true→fail-loud** (marks the tuple as having a real completion marker, driving further validation) | Three call sites, identical shape, interpolated issue number. Not a single "top-level alternation" pattern in the regex-engine sense (each `-match` is a separate anchor-eligible pattern), but the s6 fix must touch both halves at all three call sites — 6 individual regex literals. |
| `frame-credit-ledger-core.ps1:2675-2678` | (construction only) | `"<!-- experience-owner-complete-$IssueNumber -->"`, `"<!-- design-phase-complete-$IssueNumber -->"`, `"<!-- plan-issue-$IssueNumber -->"`, `"<!-- engagement-record-orchestration-$IssueNumber -->"` | n/a | n/a | n/a | Builds `$script:CompletionMarkerByPort`; consumed as literal-substring `-like` comment-selectors below, not as its own regex scan. |
| `frame-credit-ledger-core.ps1:2757,2828` | comment-selector | `-like "*$completionPrefix*"` / `-like "*$completionMarker*"` | n/a | n/a | n/a | Wildcard-wrapped exact-literal substring matches (the marker text itself already has `$IssueNumber` interpolated) — comment-selector class, not block-selector; no regex to anchor. |

#### s6 batch 2 disposition (issue #878)

`cost-fcl-helpers.ps1:95` and `Get-FCLOriginContext.ps1:101` are anchored to
`(?im)^\s*<!--\s*(?:plan|design)-issue-(?<issue>\d+)\s*-->`.
`gate-reconciliation-core.ps1:95` (the third copy of the drift-risk trio) is
explicitly out of s6 batch 2's scope, tracked for the step 7 follow-up issue.

**`gate-reconciliation-core.ps1:158` — investigated, ANCHORED (not excluded).**
Despite the surface resemblance to `:800`'s danger shape (a presence-gate
whose `$true` branch drives further verification), tracing the *actual*
consumer at `:271-306` (`Read-FindingDispositionIds`'s caller) shows the
opposite polarity. Narrowing this gate can only ever cause an
**under-approximation** of `$recordedIds` (a real marker, if ever posted
off-line-start, gets skipped, never a spurious match — narrowing never
creates new matches). An under-populated `$recordedIds` causes
`$id -notin $allRecordedIds` (`:296`) to flip **true** for an id that really
was recorded, which emits an extra `severity: 'warn'` finding
("no corresponding recorded decision"). That is a **loud, visible,
investigable false-positive** — never a silent false-clean. This is the
same `false→loud, safe-to-narrow` class already documented for the
`adversarial-pipeline-atomic-{ID}:1280` fallback below, the **opposite** of
`:800`'s `false→quiet/false-clean` danger. Empirically verified besides:
every real `design-phase-complete-{ID}` marker harvested from this repo
(issues #489 and #878's own comments) is posted at true column 0, line 1 of
its own comment — see the harvested fixtures under
`.github/scripts/Tests/fixtures/marker-reader-anchoring/`. Anchored to
`(?m)^\s*<!--\s*design-phase-complete`; rationale duplicated as an inline
code comment at the anchoring site itself.

`phase-containment-rolling-history-core.ps1:711-712,781-782,1387-1388`
(the design-phase-complete/plan-issue OR-gate) and its Surface B sibling
`:1053,1123,1475` (the bare judge-rulings gate) were polarity-checked using
the same method: tracing the `$false` branch shows a `continue`/exclusion
that is silent ONLY on natural pagination exhaustion (the code's own comment
at `:786-792` already treats that as "a correct exclusion, not a
degradation"), otherwise a `Write-Warning` "possible undercount" fires. Given
no documented historical-placement risk was found for these two families
(unlike the pre-811-writer `plan-issue`+heading combination `:800` guards
against) and the same empirical column-0 verification above, all six sites
are anchored to `(?m)^\s*<!--\s*design-phase-complete-$N\s*-->` /
`(?m)^\s*<!--\s*plan-issue-$N\s*-->` / `(?m)^\s*<!--\s*judge-rulings`.

Also anchored in s6 batch 2: `frame-credit-ledger-core.ps1:1195`
(`ConvertFrom-JudgeRulingsComment`, the judge-rulings PR-surface reader) to
`(?ms)^[ \t]*<!--\s*judge-rulings\s*\r?\n(?<body>.*?)\r?\n-->`;
`frame-credit-ledger-core.ps1`'s `Test-PipelineMetricsV4Block` non-fenced
count-scan (drifted to `:3194` from the plan's cited `:3176-3178`) to the
same lookahead-guarded shape as `:709`/`:750`
(`(?m)^[ \t]*<!--\s*pipeline-metrics(?![\w-])`); `frame-credit-ledger.ps1`
(wrapper, not `-core`) `:513` (`Get-FCLFrameSpineComments`) and `:1208`
(drifted from `:1201`, the judge-rulings `Select-Object -Last 1` selector);
`cost-rolling-history.ps1:33,36,726,785` and `cost-session-render.ps1:391,519`
(cost-pattern-data family — `:519`'s raw-block fallback anchored with
`[ \t]*` rather than `\s*` since it is a splice-adjacent site whose `.Value`
is used wholesale for body reconstruction). Per-family Pester fixture tests
(prose-mention-rejection, count/parse-result assertion, harvested historical
placement) live in `.github/scripts/Tests/marker-reader-anchoring.Tests.ps1`,
extending the batch-1 suite; fixtures harvested from real posted comments on
issues #489, #878, and #879/#691 under
`.github/scripts/Tests/fixtures/marker-reader-anchoring/`. The one exception
is the `plan-issue`/`design-issue` combined family's historical-placement
fixture: no real PR body carrying that literal marker was found in this
repo (PR bodies link issues via branch name/`issue_id` field in practice;
this is a last-resort fallback), so the fixture reuses issue #878's own real
`<!-- plan-issue-878 -->` line — the marker family's line-start placement
convention is identical regardless of which surface (issue comment vs. PR
body) it is posted on.

### frame-spine / frame-slice(s)

| Site | Class | Pattern | Alternation | End-anchor | Polarity | Notes |
| --- | --- | --- | --- | --- | --- | --- |
| `frame-spine-core.ps1:57` | block-selector | `'<!--\s*' + $escapedBlockName + '\s*-->\s*\n(?<payload>.*?)\n\s*-->\|<!--\s*' + $escapedBlockName + '(?:\s*\n\|\s+)(?<payload>.*?)\n?\s*-->'` | **top-level, ungrouped** (`\|` joins two full alternative sub-patterns at the outermost level) | none | n/a | `Get-FSCCommentBlockPayloads($BlockName)`, generic — instantiated for both `frame-spine` and `frame-slices`. **The plan's cited top-level-alternation exemplar.** Anchoring must wrap `(?:branch1\|branch2)` before adding `^`, per the "anchor every branch via grouping" rule — a bare `^` prefix on only the first branch would leave the second branch (the no-blank-line-after-marker shape) unanchored. |
| `frame-spine-core.ps1:497` | block-selector | `'<!--\s*frame-slices-generated-at\s*:\s*(?<value>.*?)\s*-->'` | none | none | n/a | Single-line variant, separate from the block-payload extractor above. |
| `frame-validate-core.ps1:228` | block-selector | `'<!--\s*frame-slice\s*-->\s*\n(?<payload>.*?)\n\s*-->\|<!--\s*frame-slice(?:\s*\n\|\s+)(?<payload>.*?)\n?\s*-->'` | **top-level, ungrouped** | none | n/a | Sibling of `frame-spine-core.ps1:57` — same template, `frame-slice` (singular) block name hard-coded rather than parameterized. A second, independent top-level-alternation site the design missed; not itself named in the plan's citations but structurally identical to the named exemplar. |
| `frame-credit-ledger-core.ps1:513` | presence-gate / selector | `-match '<!--\s*frame-spine'` | none | none | n/a | Filters PR comments down to the one carrying a frame-spine block. |
| `frame-credit-ledger-core.ps1:3338-3339` | block-selector/splice target | `"(?ms)^\s*<!--\s*frame-override-$Pr\s*\n\s*ports:\s*(?<ports>[^\n]+)\n\s*reason:\s*(?<reason>[^\n]+?)\s*\n\s*-->"` | none | implicit (requires literal `-->` after `reason:` line) | n/a | **Already** `^`-anchored (multiline). A fourth already-anchored precedent, for the `frame-override` family — not previously catalogued as such. |

### credit-input-{port}-{ID}

| Site | Class | Pattern | Alternation | End-anchor | Polarity | Notes |
| --- | --- | --- | --- | --- | --- | --- |
| `frame-credit-ledger-core.ps1:2801` | (construction) | `"<!-- credit-input-$port-$IssueNumber"` (prefix only, no close) | n/a | n/a | n/a | Deliberately a prefix-only literal (the writer's marker carries a trailing UUID/timestamp not reproduced here). |
| `frame-credit-ledger-core.ps1:2837` | comment-selector | `-like "*$creditMarkerPrefix*"` | n/a | n/a | n/a | Selects the credit-input comment for a port. Prefix-based by design (not a full marker), so regex anchoring does not apply — this is inherently a comment-selector, not block-selector. |
| `frame-credit-ledger-core.ps1:2692` | block-selector (fence) | `` '```yaml\s*([\s\S]*?)```' `` | none | none | n/a | `ConvertFrom-SingleCreditInputMarker`; extracts YAML fenced payload from the already-selected comment body. Generic fence pattern, not marker-specific — shared shape with several other fenced-YAML readers in this inventory (`gate-reconciliation-core.ps1:159`, `review-dispositions-validator-core.ps1:103`, `Get-FCLOriginContext.ps1:216`). |

### frame-credit-ledger-{PR} (composite sentinel)

| Site | Class | Pattern | Alternation | End-anchor | Polarity | Notes |
| --- | --- | --- | --- | --- | --- | --- |
| `Get-FCLOriginContext.ps1:314` | (construction) | `"<!-- frame-credit-ledger-$Pr -->"` | n/a | n/a | n/a | |
| `Get-FCLOriginContext.ps1:329` | comment-selector | `-like "*$marker*"` | n/a | n/a | n/a | |
| `frame-credit-ledger-core.ps1:983` | (construction) | `"<!-- frame-credit-ledger-$Pr -->"` | n/a | n/a | n/a | Duplicate construction site, top-level wrapper script. |

### review-judge-produced-{PR} (sentinel)

| Site | Class | Pattern | Alternation | End-anchor | Polarity | Notes |
| --- | --- | --- | --- | --- | --- | --- |
| `frame-credit-ledger-core.ps1:940,945` | comment-selector | `$token = "<!-- review-judge-produced-$PrNumber -->"`; `-like "*$token*"` | n/a | n/a | n/a | `Test-ReviewSentinelPresent`. |
| `frame-credit-ledger-core.ps1:983,987` | comment-selector | same token, second read site | n/a | n/a | n/a | `Resolve-NotPersistedSynthesis` — re-derives `$token` independently rather than calling `Test-ReviewSentinelPresent` a second time; both copies must stay in sync if the marker shape ever changes. |

### adversarial-pipeline-atomic-{ID}

| Site | Class | Pattern | Alternation | End-anchor | Polarity | Notes |
| --- | --- | --- | --- | --- | --- | --- |
| `frame-credit-ledger-core.ps1:1277` | presence-gate | `$Text.Contains($marker)` (full literal, `$ISSUE_ID` substituted) | n/a | n/a | **true→quiet** (found → `'true'` status, no warning) | Primary check. |
| `frame-credit-ledger-core.ps1:1280` | presence-gate (fallback) | `-match '<!--\s*adversarial-pipeline-atomic-\d+\s*-->'` | none | none | **false→loud** (opposite polarity from :800 — narrowing this makes MORE `false-warn-only` warnings fire, never fewer; safe to anchor) | Only reached when `$IssueId` is blank. Contrast case for the polarity write-up: this gate's `$true` branch is the *quiet* path, so over-narrowing it is safe (it can only cause more warnings, not a false clean). |

### cost-pattern-data / cost-summary:begin-end / cost-pattern-data-degraded

| Site | Class | Pattern | Alternation | End-anchor | Polarity | Notes |
| --- | --- | --- | --- | --- | --- | --- |
| `cost-rolling-history.ps1:33` | presence-gate | `-notmatch '<!--\s*cost-pattern-data'` | none | none | **false→fail-loud path continues; true(notmatch)→early-return-null** i.e. **true(match)→proceeds to parse** | `Get-CostPatternYaml`'s entry gate. |
| `cost-rolling-history.ps1:36` | block-selector | `'<!--\s*cost-pattern-data\s*\r?\n([\s\S]*?)\r?\n?-->'` | none | requires `\r?\n?-->` | n/a | Extracts the YAML payload once the gate above passes. |
| `cost-fcl-helpers.ps1:191,510` | (construction) | `"<!-- cost-pattern-data-degraded-$Pr -->"` | n/a | n/a | n/a | |
| `cost-fcl-helpers.ps1:391` | presence-gate / selector | `-match '<!-- cost-pattern-data'` (no `\s*` between `<!--` and the word, literal space) | none | none | n/a | Selects `$PriorComments` carrying any cost-pattern-data marker; note this copy is NOT `\s*`-tolerant like the others — a minor shape drift within the same family. |
| `cost-fcl-helpers.ps1:470` | comment-selector | `-like "*$degradedMarker*"` | n/a | n/a | n/a | |
| `cost-fcl-helpers.ps1:488-491,517-520` | block-selector (two-tier) | `$script:FCLCostPatternSectionRegex` (see `cost-session-render.ps1:73`, shared) then fallback `'<!--\s*cost-pattern-data[\s\S]*?-->'` | none (fallback) | none | n/a | Fallback raw-block extraction at **`cost-session-render.ps1:519`** — the plan's explicitly design-time-omitted site (confirmed). Primary extractor `$script:FCLCostPatternSectionRegex` (defined `cost-session-render.ps1:73`) is `(?ms)(?<section>^##\s+Cost Pattern\b.*?<!--\s*cost-pattern-data[\s\S]*?-->)` — **already `^`-anchored** on the heading, though the embedded `<!--\s*cost-pattern-data` sub-match inside it is not independently anchored. |
| `cost-fcl-helpers.ps1:652,942` | block-selector | `'(?s)(?<open><!--\s*pipeline-metrics(?![\w-])\s*)(?<block>.*?)(?<close>\s*-->)'` | none | none | n/a | Cross-referenced under pipeline-metrics above; the lookahead-guarded shape. |
| `cost-fcl-helpers.ps1:961-962` | block-selector (sentinel pair) | `'^\s*<!--\s*cost-summary:begin\s*-->\s*$'` / `'^\s*<!--\s*cost-summary:end\s*-->\s*$'` | none each | `$` each | n/a | Already `^...$` anchored per-line. Fourth already-anchored family (not previously listed) — `cost-summary:begin/end`. |
| `cost-fcl-helpers.ps1:1030` | block-selector | uses caller-supplied `$MarkerPattern` (parameterized, not a literal defined here) | n/a | n/a | n/a | Generic helper; the concrete pattern lives at whichever call site supplies `-MarkerPattern`. |
| `render-portfolio.ps1:321,330` | presence-gate | `.Contains($textFallbackMarker)` where `$textFallbackMarker = '<!-- parent-link-mode: text-fallback -->'` | n/a | n/a | n/a | Literal substring, cross-referenced with `Set-IssueParent.ps1:58`'s writer-side definition of the same token. |
| `render-portfolio.ps1:626-627,645-646,663` | splice-writer (sentinel pair) | `'<!-- portfolio-tracker:begin -->'` / `'<!-- portfolio-tracker:end -->'` via `$betweenPattern` (built from the two literals) | n/a | n/a | n/a | Fifth sentinel-pair family; not independently listed in the plan. |

### proposed-followups-{ID}

| Site | Class | Pattern | Alternation | End-anchor | Polarity | Notes |
| --- | --- | --- | --- | --- | --- | --- |
| `followup-gate-core.ps1:102` | block-selector (head) | `'(?m)^\s*<!--\s*proposed-followups-(\d+)\s*-->'` | none | none | n/a | **Already anchored** — third precedent (see table above). |
| `followup-gate-core.ps1:411` | count-validator | `[regex]::Matches($Text, $pattern)` (pattern parameterized, presumed the `:102` constant) | none | none | n/a | |
| `followup-gate-core.ps1:640` | presence-gate | `-not $body.Contains('engagement-record-')` | n/a | n/a | **false(no match)→skip; true→continue processing** | Broad substring, not the full marker — deliberately loose (matches any `engagement-record-*` phase variant), out of scope for per-family anchoring since it is intentionally family-spanning. |

### complexity-override (newly identified family — not in the design's or plan's citations)

| Site | Class | Pattern | Alternation | End-anchor | Polarity | Notes |
| --- | --- | --- | --- | --- | --- | --- |
| `skills/guidance-measurement/scripts/measure-guidance-complexity-core.ps1:17` | presence-gate (prefix) | `$Script:OverridePattern = '<!--\s*complexity-override:'` | none | none | not yet determined — caller not traced in this pass | Genuinely new family this scan surfaces beyond the plan's own enumeration; flagged for s6 triage rather than given a full polarity verdict (out of the plan's named-site budget; recorded here per the RC's "exhaustive" mandate rather than silently dropped). |

### Generic / out-of-family utilities (not per-family anchoring candidates)

| Site | Class | Pattern | Notes |
| --- | --- | --- | --- |
| `skills/naming-register-policy/scripts/newcomer-audit-core.ps1:142` | splice/strip | `[regex]::Replace($result, '(?s)<!--.*?-->', $blankEvaluator)` | Blanks **every** HTML comment generically before prose-scanning for naming violations; intentionally family-agnostic. Not an anchoring target — narrowing it would defeat its purpose. |
| `.github/scripts/audit-hub-artifact-paths.ps1:121` | presence-gate (meta) | `[regex]'<!--\s*[a-z][a-z0-9-]*-\{[A-Z_a-z]+\}\s*-->'` | Scans skill/agent **documentation prose** for marker-template literals (e.g. `<!-- foo-{ID} -->`), not live GitHub comment bodies. Different corpus (repo `.md` files) and different purpose (doc-audit tooling) than every other row in this inventory. Recorded for completeness since the RC's scope was "every raw-text marker scan," but this is not a Part-C candidate — there is no live comment body for it to misfire against. |
| `.github/scripts/audit-hub-artifact-paths.ps1:915` | block-selector (self) | `[regex]'(s)<!-- audit-meta.*?-->'` | Reads this tool's own generated `<!-- audit-meta -->` header back out of its own prior output. Self-referential, single-caller, not a shared family. |
| `.github/scripts/plan-tree-state-verification.ps1:77` | block-selector (position) | `$Content.IndexOf('<!-- verification-evidence -->', ...)` | Ordinal `IndexOf` on the plan-comment body (not a GitHub comment scan across bodies — operates on one already-fetched plan body). No regex to anchor; same shape-class as `phase-containment-core.ps1`'s `IndexOf` usage but single-purpose. |
| `.github/scripts/lib/frame-credit-ledger-core.ps1:2910` | splice (escaping) | `-replace '<!--\s*pipeline-metrics', '<!-- pipeline&#8208;metrics'` | Defensive HTML-comment-injection escaping for a *value being written into* a metrics block, not a reader. Writer-side, out of scope. |
| `.github/scripts/lib/frame-credit-ledger-core.ps1:3176-3177` | count-validator | `[regex]::Replace($Body, '(?s)```.*?```', '')` then `[regex]::Matches($strippedBody, '<!--\s*pipeline-metrics')` | Counts pipeline-metrics occurrences **after** stripping fenced code blocks — a decoy-suppression step distinct from the block-selector reads above. Its own site for anchoring (the `<!--\s*pipeline-metrics` sub-pattern is unanchored, same family concern as the rest of the cluster). |

## Comment-selector class (Find-OrUpsertComment and the `-like` cluster)

Part C's regex anchoring structurally cannot reach this class — a wildcard
substring match on a whole comment body is a different mechanism than
anchoring a regex inside an already-selected body. Sites:

| Site | Pattern | Notes |
| --- | --- | --- |
| `.github/scripts/lib/find-or-upsert-comment.ps1:130` | `$_.body -like "*$Marker*"` | The mechanism named in the plan (M7): author-blind, matches a marker mentioned anywhere in ordinary prose, including a comment posted *before* the real target (earliest-REST-id tie-break at `:153-156` actively prefers the wrong comment in that case). This is the site s5's find-only, line-anchored selector (net-new glue, not a Part-C regex fix) is scoped to replace for the persistence-burst helper's own targeting — out of s1/s6 scope, in scope for s5. |
| `frame-credit-ledger-core.ps1:945,987,2757,2828,2837` | `-like "*$token*"` (various tokens) | See per-family tables above; all wildcard-wrapped full-literal or prefix-literal matches. |
| `Get-FCLOriginContext.ps1:329` | `-like "*$marker*"` | See frame-credit-ledger-{PR} table. |
| `cost-fcl-helpers.ps1:470` | `-like "*$degradedMarker*"` | See cost-pattern-data table. |

## `$keyAnchor` — an internal-field anchor idiom, not a marker family (context only)

`phase-containment-emission-check-core.ps1` defines the fragment
`$keyAnchor = '(?:^\s*(?:-\s+)?|[{,]\s*)'` independently at four sites
(`:2146`, `:2253`, and duplicated inline in `phase-containment-cost-core.ps1:149`
and `frame-credit-ledger-core.ps1`'s per-entry extractors) to recognize a
real YAML key position (line-start, dash-list-item, or flow-mapping
`{`/`,`) versus a prose mention. This is **not** itself a marker-family
open/close pattern — it anchors *fields inside* an already-isolated region
(`disposition:`, `judge_ruling:`, etc.), so it is out of this inventory's
per-family marker-scan scope. Recorded here only because
`phase-containment-emission-check-core.ps1`'s own comment at `:2141-2145`
already asserts a drift-catching meta-test keeps its four copies
byte-identical — the same discipline s6 should apply to the `plan-issue`/
`design-issue` three-copy cluster and the `pipeline-metrics` cluster, which
currently have **no** such drift guard.

## Counts by classification class

| Class | Site count (this inventory) |
| --- | --- |
| block-selector | 26 |
| presence-gate | 19 |
| count-validator | 6 |
| splice-writer | 8 |
| comment-selector | 9 |

Counts are per distinct `path:line` row above (construction-only rows and
the generic/out-of-family utilities table are excluded from these totals;
the `$keyAnchor` context section is excluded as internal-field, not
marker-family). Some rows span multiple physically-adjacent lines and are
counted once. This is a **lower bound** consistent with the plan's own
framing (d3/M11): the scan prioritized every site named in the plan, every
site the design's own citations named as omitted, and every additional site
surfaced by systematic grep across both required globs, but a handful of
call sites inside heavily-templated test-fixture generators were not
individually enumerated (see Coverage notes).

## Coverage notes

- Both required globs were scanned: `.github/scripts/**` (296 `.ps1` files)
  and `skills/**/scripts/**` (9 `.ps1` files). `.github/scripts/Tests/**`
  files were excluded from per-site inventory (they assert against the
  patterns above rather than defining new production marker scans), except
  where a fixture script (`Tests/fixtures/subagent-env-handshake-verifier.ps1`)
  was checked and confirmed to carry no independent marker-family pattern of
  its own.
- `skills/subagent-env-handshake/scripts/New-SubagentDispatchPrompt.ps1` and
  `skills/safe-operations/scripts/{Add-FollowUpIssue,Set-IssueParent}.ps1`
  construct marker literals (writer-side) but were not found to scan for
  them within their own files; their tokens are read elsewhere (e.g.
  `Set-IssueParent.ps1`'s `parent-link-mode: text-fallback` token is read by
  `render-portfolio.ps1:330`, cross-referenced above).
  `reference-preflight-hook.ps1`'s `<!-- refs-injected-{ID} -->` token
  (`:484`) is writer-only in this pass; no reader was located under either
  glob.
- Every site explicitly named in the plan's own text (frame-credit-ledger-core.ps1
  `:750`/`:709`/`:1178`; frame-spine-core.ps1 `:56-58`;
  phase-containment-emission-check-core.ps1 `:36`/`:800`/`:679-682`/
  `:2005,2009`/`:2670-2698`/`:2964`/`:3037-3040`/`:3068`/`:3223-3224`/`:3306`;
  phase-containment-core.ps1 `:225-226,233,242,257`; cost-session-render.ps1
  `:519`; the two calibration-pipeline `:61`/`:788` readers; frame-engagement-record-core.ps1
  `:180`) was located, read in context, and classified above.
