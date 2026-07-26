# Design: Deterministic Marker-Write Primitive

**Domain**: Durable GitHub-Comment Transport for Handoff Markers
**Status**: Current
**Implemented in**: Issue #893

---

## Purpose

This document describes `persist-marker.ps1` — the registry-driven CLI that owns quoting, encoding, comment targeting, marker-literal emission, burst ordering, and read-back verification for eight durable GitHub-comment marker families. It records why the primitive exists, how it is built, the decisions (and owner-approved amendments) that shaped it, what CE Gate caught that the mocked test suite could not, and what remains hand-authored.

The operational marker catalog — which family writes through this primitive today — lives in [skills/session-memory-contract/references/handoff-markers.md](../../skills/session-memory-contract/references/handoff-markers.md). This document does not duplicate that catalog; it explains the transport machinery behind it.

## Problem

Every recorded write-failure incident happened **with the correct instructions loaded** — this was never a knowledge gap. For almost every marker family, the documented write path was "hand-compose a `gh issue comment` / `gh pr comment` call with the marker inline," which makes an LLM responsible for shell quoting, encoding, comment targeting, literal-marker emission, and format precision on every single write:

| Failure class | Recorded incident |
| --- | --- |
| Shell quoting/escaping | #862 apostrophe bug (hit three times on one PR); `body=@"$VAR/path"` sending the literal path string instead of file contents |
| Encoding | `gh view → gh edit --body-file` mojibake round-trip on Windows (em-dash/section-sign/ellipsis corruption) |
| Comment targeting | `--edit-last` clobbering burst siblings; `Find-OrUpsertComment`'s `-like` substring matcher selecting the wrong comment |
| Forgetting the literal | a plan persisted without the `plan-issue-{ID}` marker literal (frontmatter alone is not enough) |
| Format precision | `phase-containment-{ID}` paired-tag shape mistaken for yaml-inside-comment |

The one family that already had a real writer — `persist-phase-ledger.ps1` (plan-surface judge-rulings + phase-containment, GET → PATCH → read-back verify) — stopped producing write failures. `persist-marker.ps1` generalizes that pattern to the rest of the marker catalog.

**Transport-versus-content, not a reversal of prior policy.** `Documents/Design/engagement-record-write-discipline.md` rejected "outsource marker writing to a centralized helper script" (its Option B) for **content composition** — agents still need inline rules to govern what a decision *says*. This work narrows that rejection, it does not reverse it: the agent composes every byte of payload content exactly as before; `persist-marker.ps1` owns only **transport** (quoting, encoding, targeting, marker-literal emission, burst ordering, read-back verification). `persist-phase-ledger.ps1` already embodied this split for the plan-surface ledger; issue #893 generalizes it to the rest of the catalog. See `engagement-record-write-discipline.md`'s 893-D10 amendment for the exact wording change to that document's Option B row.

Adoption is by contract rewrite and friction advantage (a recommended `.claude/settings.json` allowlist entry), not by a platform enforcement hook — the #617 decision against a centralized prevention-at-persist hook stands. `persist-marker.ps1`'s pre-write refusals govern only its own writes; a hand-posted marker is still only detectable at review, never blocked.

## Architecture

### Wrapper / core split

`skills/session-memory-contract/scripts/persist-marker.ps1` is a thin CLI wrapper; `skills/session-memory-contract/scripts/persist-marker-core.ps1` carries the testable logic. This mirrors the proven `persist-phase-ledger.ps1` wrapper/core split, including its plugin-bundled fixed-relative-offset dot-source justification (`$PSScriptRoot/../../../.github/scripts/lib` always resolves to the SAME install's own bundled libraries, so the wrapper and its libraries can never drift out of lockstep). Both `pwsh -File` and in-process call-operator (`&`) invocation are legal entry points; every public parameter is a scalar or a file path — never an array or collection — which makes the recorded #866 parameter-flattening trap (an array silently newline-joined and bound to the wrong parameter under `pwsh -File`) structurally unrepresentable rather than merely documented around. Anything list-shaped travels as a `-BurstManifest` JSON file path instead.

### Promoted transport core

`.github/scripts/lib/marker-transport-core.ps1` hosts six transport primitives, promoted byte-identically from `persist-phase-ledger-core.ps1`'s private `script:`-scoped glue plus two net-new functions:

- `Get-CommentIdFromUrl`, `Get-CommentBodyById`, `Set-CommentBodyDirect` (PATCH + post-write verify GET with a gross-truncation guard), `Set-PointerLineAfterMarker` (CRLF-safe pointer insertion) — promoted, byte-identical behavior.
- `New-MarkerComment` — net-new create-only POST primitive (body transported via a temp file and `--body-file`, never inlined as a raw argv element, so an oversized payload cannot exceed Windows' command-line length limit).
- `Find-AllCommentsByExactMarker` — net-new paginated full-enumeration selector, used only by the new persist-marker path. It queries the unified `repos/{Owner}/{Repo}/issues/{Number}/comments` REST endpoint via `gh api --paginate` (surface-agnostic for issues and pull requests alike), follows every page with no early-exit and no page cap, and throws rather than returning a partial result on a mid-walk failure.

`persist-phase-ledger-core.ps1` keeps its PPL-prefixed function names as one-line delegators to the promoted, generically-named versions, so every existing internal call site and Pester reference stays valid — this is `persist-phase-ledger`'s zero-behavior-change evidence chain. The existing, un-paginated `Find-CommentIdByExactMarker` (single-page, earliest-id tie-break) is untouched and remains what every pre-existing caller uses; only the new `persist-marker.ps1` path uses the paginated selector.

`.github/architecture-rules.md` names this as a deliberate, general pattern — "a skill wrapper MAY dot-source `.github/scripts/lib/` directly" — rather than a one-off exception, now that `persist-phase-ledger.ps1` and `persist-marker.ps1` are two independent consumers under the same fixed-relative-offset, version-lockstep-bundling justification.

### Family registry and the two write shapes

`Get-MarkerFamilyRegistry` (`persist-marker-core.ps1`) returns one row per durable marker family: `Family`, `MarkerTemplate`, `TargetSurface` (`issue` | `pull-request`), `WriteShape` (`post-new` | `upsert`), `ValidatorAdapter`, and `PostStep`. Adding a family later is one registry row plus an optional validator adapter — the registry is what keeps N families from becoming N separate invocation contracts.

Registry v1 (eight families with a live writer, including `frame-slices`, whose write shape is `upsert`; see [Known v1 gaps](#known-v1-gaps--deferred-work) for what is not yet in the registry):

| Family | Write shape | Validator adapter | Post-step |
| --- | --- | --- | --- |
| `plan-issue` | upsert | — (payload-hygiene checks only) | `plan-issue-write-back-preserve` |
| `design-phase-complete` | post-new | `finding_dispositions` schema check (deferred, not v1) | — |
| `experience-owner-complete` | post-new | — (free-form prose) | — |
| `review-judge-produced` | post-new | `sentinel-empty` | — |
| `engagement-record` | post-new | `engagement-record` | — |
| `review-dispositions` | post-new | `review-dispositions` | — |
| `credit-input` | post-new | `credit-input` (in-core YAML shape) | — |
| `frame-slices` | upsert | — | `frame-slices-spine-splice` |

**`post-new`** (latest-comment-wins families): the script composes `{marker}\n\n{payload}` and POSTs a new comment. Before posting, it enumerates every existing marker-bearing comment via `Find-AllCommentsByExactMarker` and compares the candidate against the **latest** (highest REST id) match — deliberately not the earliest: post-new families accumulate marker comments by design and are read latest-wins, so comparing against the earliest match could no-op against a superseded record and silently fail the write intent. A normalized-identical latest match no-ops (`action: no-op`); anything else posts a new comment.

**`upsert`** (single-durable-artifact families: `plan-issue`, `frame-slices`): finds the canonical match (earliest / lowest REST id — the correct tie-break for a single durable artifact, unlike post-new), re-finds that same target immediately before PATCH (narrowing the check-then-write window under a single-writer-per-issue concurrency posture; the residual race between re-find and PATCH is an accepted risk with no shipped primitive to make the pair atomic against the REST API), and either PATCHes the existing comment or POSTs a new one when absent. Never `--edit-last`; always targeted by numeric REST comment id.

Every write runs a **surface preflight** before touching the network: the caller's declared `-TargetSurface` is compared against the registry row's declared `TargetSurface`. This is necessarily a declared-vs-declared comparison — the unified GitHub comments REST endpoint accepts either an issue or a pull-request number silently, so there is no live way to ask the endpoint which surface a number belongs to.

**One shared normalization.** `ConvertTo-MarkerNormalizedText` — LF line endings, per-line trailing-whitespace strip, outer trim, nothing else — is the single function used by both the write-shape idempotency comparison and the post-write read-back comparison, so the two checks can never silently drift apart on what counts as "unchanged."

**Read-back verification.** `Test-MarkerReadBack`'s primary gate is normalized equality between the just-written candidate and a fresh GET of the posted/patched comment — not the inherited ≥50%-length truncation guard alone. That guard cannot prove byte-faithfulness on its own because mojibake corruption *lengthens* text rather than shortening it; it is retained only as a secondary check for a more specific failure message when the mismatch is also a gross truncation. A failed read-back always throws, which both write-shape functions convert into `Success = $false` — a bad read-back is never reported as success.

### Validator adapters and diagnosable refusals

Every wired validator adapter (`sentinel-empty`, `engagement-record`, `review-dispositions`, `credit-input`) validates the **marker-composed candidate** — the exact bytes about to be written — never the raw payload, because both wired adapters key on the family marker that payload hygiene forbids the payload from carrying on its own. A validator infrastructure failure (missing module, non-zero exit, unparseable result) is fail-closed: refused with a diagnosable message, never treated as "no findings."

Every refusal takes the pinned shape `persist-marker: REFUSED ({family}, {target}): {detail}`, naming the offending field, value, or offset, with every echoed value length-bounded (80 chars for values this file echoes directly from raw content; a wider 400-char cap for a validator library's own already-reviewed diagnostic prose) so a refusal can never dump an oversized or sensitive field verbatim.

**Payload hygiene** (two rules, both refuse — see [893-D7 amendment](#893-d7-amendment--cross-family-marker-literals-refused-not-warned) below):

1. **Own-family**: the candidate must carry its own family's marker exactly once, at line 1 — refused when missing entirely, present at the wrong line, or duplicated.
2. **Cross-family**: the candidate must not carry any *other* registered family's live marker literal at line start (including two hygiene-only families, `frame-credit-ledger` and `phase-containment-ledger`, that carry no write-registry row of their own but are live today). Inert-rendered mentions — no literal `<!--`/`-->` bytes present, e.g. an HTML-entity-escaped example inside a code fence — never trigger either rule.

### Family post-steps

Two families carry a registry-declared post-step, both dot-sourcing `.github/scripts/lib/frame-spine-core.ps1`'s parser rather than reimplementing it:

- **`plan-issue-write-back-preserve`** (runs *before* hygiene/validator/write, mutating the candidate body): on a re-persist, carries forward every artifact class the incoming payload omits but the existing canonical plan comment carries — the `phase-containment-ledger-ref` pointer line, the frame-spine `slice_comment_id` scalar, and for legacy pre-#863 plans the judge-rulings head, phase-containment blocks, and the `**Plan Stress-Test**` heading. Each pointer/scalar is live-checked against its target's own identity marker before being preserved; a stale or forged pointer is dropped, not carried forward, falling through to `persist-phase-ledger-core.ps1`'s own self-heal. A `-NoPreserve` switch lets a maintainer deliberately clear a bad pointer. A candidate-*supplied* pointer or scalar (not an inherited one) is validated with the same live check and the whole write is refused if it fails — never written through unvalidated.
- **`frame-slices-spine-splice`** (runs *after* a successful write): writes the just-written sibling's comment id back into the plan comment's `frame-spine` block as `slice_comment_id`, via a targeted scalar splice (`script:Set-MarkerSpineScalarValue`) restricted by `-ValidateSet` to the four legal top-level spine keys — never a full-body recompose. Guarded by a marker-identity precondition (refuses when the plan comment does not carry the expected `plan-issue-{ID}` marker) and by `generated_at` equality between the plan's frame-spine block and the sibling's own `frame-slices-generated-at` stamp. A splice-back failure makes the overall write `Success = $false` even though the sibling write itself already landed — loud, never swallowed.

### Burst mode

`persist-marker.ps1 -BurstManifest <path.json>` runs an ordered write sequence from a JSON manifest (never an inline array parameter, for the same #866-flattening-trap reason as every other parameter). `script:Test-MarkerCandidatePreflight` extracts every network-free check `Invoke-PersistMarkerWrite` already runs (registry lookup, surface match, size cap, payload hygiene, validator adapter) into one shared helper, so `Invoke-PersistMarkerBurst`'s whole-manifest preflight runs the exact same validation on every entry before any network write — this is what makes "a manifest with any invalid entry writes nothing at all" true at invocation scope, not just per-write. After preflight passes, writes execute in manifest order, halting on the first execution failure. Re-run after a mid-burst halt converges without duplicates by relying entirely on each write shape's own idempotency — the burst mechanism adds no separate dedup bookkeeping.

### Scratch-root path bounding and size cap

Every `-BodyFile` (single-write mode) and every burst-manifest entry's `bodyFile` must resolve, via real `Resolve-Path` canonicalization (symlink- and traversal-aware, never a raw string-prefix test), inside the consumer repository's `.tmp/` scratch root — a path outside it is refused before any network call. This bound is what makes the recommended `Bash(pwsh*persist-marker.ps1*)` allowlist entry safe rather than an arbitrary-file-read-to-public-comment primitive (see [893-D8](#893-d8--allowlist-safety-rests-on-scratch-root-bounding) below). A composed body exceeding GitHub's 65,536-character comment cap is refused pre-write with a diagnosable message rather than surfacing as a transport error.

## Key Decisions

The design phase persisted decisions 893-D1 through 893-D11 (full text on the design-phase-complete comment thread for issue #893); the highlights not already covered above:

- **893-D1** — single registry-driven CLI plus a promoted shared transport core, rather than N per-family wrapper scripts (which would re-create the per-family drift this work exists to kill) or folding seven unrelated families into `persist-phase-ledger.ps1`'s own `-Mode` enum (which would muddy a proven, narrowly-scoped contract).
- **893-D5** — the pinned no-array-parameter invocation contract described above.
- **893-D6** — the diagnosable-refusal contract (`persist-marker: REFUSED (...)`) plus a retrofit of `Add-JudgeRulingsBlock`'s `could-not-verify` rejection path in `phase-containment-emission-check-core.ps1` to name the out-of-enum value or reported offset per branch (the two causes are mutually exclusive — the window/vocabulary gate short-circuits before the value scan ever runs, so a single combined message was never implementable), verdict-neutral.
- **893-D9** — issue #478 (the older, narrower judge-rulings-persistence seat) closed as superseded: its helper-migration intent is realized by this primitive's line-anchored transport direction, its remaining live surface is owned by issue #885 item 2, and its preserved-marker requirement referenced a marker retired in issue #441.
- **893-D11** — body transport is exclusively file-based end to end: the agent authors payloads with the Write tool (UTF-8, no BOM); the script sends bodies via `gh api` with `--input`/`--body-file` tempfiles, never string-interpolated arguments.

Four decisions were **amended during implementation**, each recorded as its own durable issue comment per this plan's own instruction (issue #893, plan slice s9):

### 893-D2 amendment — pagination scoped to the new consumer only

893-D2 originally specified GraphQL-cursor pagination for the promoted comment selector. The shipped implementation instead uses `gh api --paginate` REST full enumeration against the unified comments endpoint (`Find-AllCommentsByExactMarker`) — simpler to implement correctly against this repo's existing `gh api` transport conventions, and it satisfies the same load-bearing requirement (a >100-comment issue still resolves the target marker or fails loud) without introducing a second, GraphQL-specific transport path alongside the REST-based writers. Scope is narrow: only the new selector paginates; the existing, un-paginated `Find-CommentIdByExactMarker` and `persist-phase-ledger-core.ps1`'s own delegators are untouched, preserving the zero-behavior-change evidence chain.

### 893-D3 amendment — review-dispositions validator invoked in-process, not subprocess

893-D3 originally specified a subprocess `-InMemoryMarkers` adapter for the `review-dispositions` family. `review-dispositions-validator-core.ps1` declares `[string[]]$InMemoryMarkers` as a top-level array parameter, and a `pwsh -File` subprocess cannot bind an array parameter that way — the recorded #866 flattening trap. The shipped adapter instead invokes the validator script in-process via the call operator (`&`), wrapped in a mandatory `try`/`catch`: because the target script runs under its own `$ErrorActionPreference = 'Stop'`, an uncaught error inside it would otherwise crash the caller's runspace, so the containment is required, not defensive style. The validator's own standalone contract remains warn-only (SMC-23) for every other caller; this write path alone converts its findings into a hard pre-write refusal.

### 893-D7 amendment — cross-family marker literals refused, not warned

893-D7 originally specified warn-only for a payload carrying another family's live marker literal at line start. The shipped implementation refuses both hygiene rules. A warn-only cross-family check would let a decoy comment land that the earliest-id tie-break then selects and destroys on the next upsert — the exact recorded self-DoS class the rule exists to prevent, and warn-only findings are not surfaced to the agent with the same enforced weight as a refusal.

### 893-D8 — allowlist safety rests on scratch-root bounding

Not an amendment to a prior D-number — a new named decision recording the mechanism that makes 893-D8's original allowlist recommendation safe. The `Bash(pwsh*persist-marker.ps1*)` glob is broad; without `Resolve-MarkerScratchBoundedPath`'s real path-containment check, a wide allowlist entry would let any `-BodyFile` argument read an arbitrary file on disk and post its contents to a public GitHub comment. The scratch-root bound is what converts the low-friction glob into a safe one.

**Two additional owner-approved corrections** surfaced during the plan's own stress-test and landed in the shipped implementation:

- **Read-back strictness**: 893-D2 and 893-D11 read as contradictory on how strict read-back verification must be. The stress-test resolved this in favor of the strict reading: normalized equality is the primary gate, and the inherited ≥50%-length truncation guard is retained only as a secondary, more-specific failure message — because mojibake corruption lengthens rather than shortens text, the truncation guard alone cannot prove byte-faithfulness.
- **Cross-family marker literals**: see the 893-D7 amendment above — refused, not merely warned.

## What CE Gate Caught

CE Gate found a defect the fully-mocked Pester suite (385/385 green) could not: on the CE Gate host's default console codepage (IBM437 on Windows), every `gh api` stdout capture in `marker-transport-core.ps1` was decoded through `[Console]::OutputEncoding`, which defaults to the legacy OEM/DOS codepage rather than UTF-8. Any non-ASCII byte in a marker-family body — an emoji, an accented character, an em-dash — round-tripped corrupted. That corruption failed `Test-MarkerReadBack`'s normalized-equality gate outright (breaking AC1, verbatim persistence), and because the corrupted read-back never matched the write candidate either, it also defeated post-new/upsert idempotency: a re-run posted a duplicate comment instead of converging (breaking AC3, idempotent double-run). Live CE Gate scenarios S1 and S3(a) both failed against a real scratch issue even though every mocked unit test passed, because the mocks never exercised a real console codepage.

**The fix**: `[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)` pinned at the top of `marker-transport-core.ps1` — the shared library's own first top-level statement, so it fires at dot-source time for every caller (both `persist-marker.ps1` and the pre-existing `persist-phase-ledger.ps1`, which shared the same previously-unprotected call chain) regardless of which wrapper loads it. A second, redundant pin also lives in `persist-marker.ps1` itself as defense-in-depth, matching the same process-wide-static pinning convention already established at `.github/scripts/frame-credit-ledger.ps1` and `.github/scripts/orchestra-spine.ps1`. Setting the encoding twice in one process is a harmless idempotent no-op. Post-fix, S1 and S3(a) were re-verified live against a real GitHub issue (scratch issue #915, closed) alongside the full 385/385 Pester suite.

**The lesson for future maintainers**: a fully-mocked test suite proves the *logic* is correct against whatever bytes the mock hands it — it says nothing about whether the bytes reaching that logic on a real host are the bytes that were actually sent. Any primitive that captures external-process stdout as text (here, `gh api`) is exposed to the host's default console encoding regardless of how carefully its own string-handling logic is tested; only a live exercise against a real host and a real non-ASCII payload can catch this class of defect.

## Known v1 Gaps / Deferred Work

The registry covers eight of the marker catalog's live families with a v1 writer (including `frame-slices`, whose write shape is `upsert`). Two families stay hand-authored, and one is explicitly out of scope:

- **`engagement-record-review-{PR}`** — the `engagement-record` registry row declares `TargetSurface: issue` for every phase, but the `review` phase is PR-keyed; a `review`-phase write through `persist-marker.ps1` would be refused by the surface preflight. Per-phase surface selection is a known v1 registry gap, not solved in this slice. See `skills/session-memory-contract/references/handoff-markers.md` for the current hand-authored write path.
- **`design-issue-{ID}`** — a legacy Copilot session-memory concept with no active writer on the current Claude pipeline; not a live registry family.
- **`proposed-followups-{PR|ISSUE}`** (the follow-up-queue family) — explicitly excluded from registry v1: it already writes through `Find-OrUpsertComment` via `followup-gate-core.ps1` rather than a hand-composed `gh` call, so it was deliberately excluded rather than missed. Migrating it to `persist-marker.ps1` is a candidate follow-up, not a v1 seat.

Also explicitly out of registry v1 scope, staying on their existing deterministic writers rather than migrating: the plan-surface `judge-rulings` + `phase-containment` ledger (`persist-phase-ledger.ps1` — the internal transport-core promotion in this work is non-observable to that family per AC8) and pipeline-metrics credit rows (`frame-credit-ledger-core.ps1` builders). PR-review-surface judge-rulings/phase-containment routing remains owned by issue #885 item 2; the promoted transport core is built so that work can reuse it.

## Migration Status

Per plan slice s9, every prose surface documenting a migrated family's write path was rewritten to name `persist-marker.ps1` as the sole documented path, mirroring `persist-phase-ledger.ps1`'s established "never by hand-authoring" language:

- `agents/Code-Conductor.agent.md`, `agents/Code-Review-Response.agent.md`, `agents/Experience-Owner.agent.md`, `agents/Issue-Planner.agent.md`, `agents/Solution-Designer.agent.md`
- `skills/engagement-record-emission/SKILL.md` and `skills/engagement-record-emission/references/conductor-orchestration-record.md`
- `skills/frame-credit-emission/SKILL.md`, `skills/plan-authoring/SKILL.md`, `skills/review-judgment/SKILL.md`
- `skills/session-memory-contract/SKILL.md` and `skills/session-memory-contract/references/handoff-markers.md` (the operational per-family catalog, marking each migrated family `[persist-marker]` and each hand-authored family `[hand-authored]` with its gap reason)
- `.github/architecture-rules.md` (restated to name the skill-to-hub-library dependency as a general, deliberate pattern with two independent consumers, not a one-off bound to `persist-phase-ledger.ps1` alone)
- `skills/session-startup/SKILL.md` § Permission allowlist (recommended) — carries the `Bash(pwsh*persist-marker.ps1*)` entry alongside the scratch-root-bounding safety rationale (893-D8)

`Documents/Design/engagement-record-write-discipline.md` was amended (893-D10) to draw the transport-versus-content line explicitly on its Option B row, rather than reversing that row's rejection.
