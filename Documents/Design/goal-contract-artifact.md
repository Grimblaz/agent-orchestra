# Design: Goal-Contract Artifact

**Domain**: Plan-seat variant for autonomous, budget-capped `/goal` runs
**Status**: Current
**Implemented in**: Issue #872 (child 2 of 5 under umbrella #848, branch `feature/issue-872-goal-contract-artifact`)

---

## Purpose

This document records why the goal-contract plan-seat variant has the shape it
does, what actually shipped for it, and which trade-offs were accepted rather
than solved. It is a reference for maintainers touching
`goal-contract-core.ps1`, the schema, `frame-validate-core.ps1`'s variant
branch, or the plan-authoring variant guidance — not a session transcript of
issue #872's history. For the operational parser contract itself, read the
`.NOTES` block in `.github/scripts/lib/goal-contract-core.ps1`; for authoring
guidance, read `skills/plan-authoring/SKILL.md` § Goal-contract plan variant.
This document is the rationale layer above both.

## What This Is

When an owner wants to hand a well-planned issue to an autonomous,
budget-capped implementation run (the `/goal` loop umbrella #848 is building),
the planning phase needs a different plan-seat artifact than the frame spine —
the slice-by-slice execution outline built for supervised, one-slice-at-a-time
orchestration. The **goal contract** is that artifact: a machine-checkable,
JSON-Schema-validated YAML block that replaces the frame spine entirely for
goal-run issues, carrying five parts — verification targets, invariants,
evidence obligations, a general experience standard, and halt conditions with a
budget. It is approvable in one prose read, and it is validated by the same
`frame-validate-core.ps1` machinery that already guards spine-based plans.

Issue #872 shipped the schema, the parser library, the `frame-validate`
structural branch, the plan-authoring variant documentation, and marker
registration. It did not ship run-time hash verification, `check` command
execution, or the goal-run harness itself — see § What's Deliberately Deferred.

## Design Decisions

The following decisions (872-D1 through 872-D9) came out of a 3-pass
adversarial design challenge plus convergence review on issue #872, then a
plan-phase grounding pass and a 5-pass plan stress test. Citations below use
the `872-Dn` numbering from the issue body's Technical Design section.

**872-D1 — Schema file: JSON Schema, single authority.**
`skills/plan-authoring/schemas/goal-contract.schema.json` is JSON Schema
draft-07, closed (`additionalProperties: false` at every level), and is the
**single authority** for every enum and required-field set — no consumer
re-encodes `targets[].category`, `halt_conditions`, or any other schema enum.
The design phase originally specified draft 2020-12 with `Test-Json
-SchemaFile` and a `#Requires -Version 7.4` floor; the plan-phase grounding
pass found the live tree contradicted all three (every one of the repo's four
existing schemas declares draft-07, and `-SchemaFile` has zero repo-wide
precedent), so the plan corrected to draft-07 with `Test-Json -Json ... -Schema
...`, which validates under the existing `#Requires -Version 7.0` floor with
no version bump needed.

**872-D2 — Block form and fields.**
The contract is an inert HTML-comment block (head `<!-- goal-contract`) inside
the `<!-- plan-issue-{ID} -->` comment, carrying fields directly with no root
key — matching the existing frame-spine block convention. Plan frontmatter
adds `plan-variant: goal-contract`. The plan comment must also carry a prose
rendering of the five contract parts **above** the block, regenerated from the
YAML on every amendment, and a literal banner stating the prose is a rendering
and the YAML governs. A mandatory `## Acceptance Criteria` H2 section with
`- **ACn**` bullets gives the AC cross-check in 872-D5 a real corpus to check
against — the existing helper (`Get-FVPlanAcceptanceCriterionId`) collects IDs
only under that literal heading.

**872-D3 — `contract_hash`: definition, producer, and byte-source contract.**
SHA-256 (64-hex lowercase) over the block body, with the `contract_hash:` line
elided, CRLF/CR normalized to LF, per-line trailing whitespace stripped, a
single final LF, UTF-8 without BOM. Prose is not hashed. The producer —
`Get-GCContractHash` — ships in this issue; #873 reuses it for run-time
verification. The byte-source rule names the canonical read path as the GitHub
API JSON `body` field, never console-rendered output, because this repo has
documented OEM-mangling history (issue #862).

*Corrected framing (escalated plan-stress-test finding, owner decision):* an
earlier framing of this scenario (Customer Experience Gate scenario S1)
described the hash as **tamper-evident**. It is not: the digest's only copy
lives inside the same comment it digests, so anyone able to edit the comment
can also recompute the hash. What the mechanism reliably provides is
**edit-coherence** — the contract approved is the contract that runs, unless
someone deliberately re-hashes it. An out-of-band digest anchor would deliver
true tamper-evidence and was rejected for this child as outside the #872
partition. All prose describing this mechanism, including CE Gate scenario S1,
must use edit-coherence framing.

**872-D4 — `falsifier` field: optional in schema, conditional-must in
authoring.**
`falsifier` is an optional prose field per target in the schema (the settled
upstream naming decision — chosen over the alternative `vacuous_forms` because
the owner's own prose, the experience scenarios, and #873's issue text all say
"falsifier," and the field holds one prose passage, not a list). Plan-authoring
guidance makes it conditionally mandatory: any target flagged by a
letter-vs-intent finding during the plan stress test MUST carry a `falsifier`
capturing that vacuity analysis. This keeps the schema permissive while making
the vacuous-pass knowledge survive to the end-of-run reviewer instead of dying
in a stress-test ledger.

**872-D5 — `frame-validate` structural branch.**
In `Invoke-FVPlanValidate`, variant detection is hoisted **above** the existing
frame-spine branch and anchored to the real frontmatter region (the YAML
between the plan's opening `---` fences), never a body-wide line regex — a
body-wide match would false-fire on plans and docs that merely quote the
literal in prose, the same false-positive class `Test-FVMigrationTypePlan`
already defends against. The full state matrix over {variant metadata, spine
block, contract block} is in § What Actually Shipped below. The structural
branch hard-gates `schema_version: 1` (unknown version fails loud, mirroring
the spine parser's own version gate), parses via 872-D6, validates against the
schema file via `Test-Json`, then checks both AC-coverage directions: every
target's `ac_ref` must appear in the plan's `## Acceptance Criteria` section
(hard failure), and every AC in that section should have at least one target
(warn-only coverage gap, mirroring the spine path).

**872-D6 — `goal-contract-core.ps1`: the one parser.**
A single new library, `.github/scripts/lib/goal-contract-core.ps1`, owns block
extraction and parsing for every consumer — `frame-validate-core.ps1`,
`orchestra-spine.ps1`, and #873's future harness — so no reader hand-rolls its
own regex or re-encodes the schema's enums. It imports `powershell-yaml` at
runtime with a loud module-missing throw, copying the shape of two in-repo
twins (`followup-gate-core.ps1` and `frame-engagement-record-core.ps1`); a
design-time review found two other cited precedents did not actually match
this throw shape (one uses a `#Requires -Modules` pin, one is deliberately
warn-only), and the design was corrected to cite only the two that do. The lib
also applies a pre-parse size cap (65,536 UTF-8 bytes) and a pre-parse
anchor/alias guard — the guard, not the size cap, is what bounds YAML
alias-expansion on untrusted comment bodies. This was net-new: no in-repo
precedent caps parser input on comment payloads today. Parsed YAML converts to
JSON and validates via `Test-Json` against the schema file — one parser, one
schema, no dual encoding.

**872-D7 — Spine-reader handling.**
Four production readers were enumerated and handled: `orchestra-spine.ps1`
renders a variant-aware message instead of a misleading legacy-plan-shape
fall-through; `frame-spine-lookup` needed no code change (goal-contract plans
are never slice-dispatched, so its missing-spine exit-1 status is already the
correct fail-loud backstop); `frame-credit-ledger.ps1` already degrades to
`$null` gracefully with no spine; and `frame-validate-core.ps1` is the branch
described in 872-D5. Spine-Runner's ineligibility for goal-contract plans (no
spine to walk) is documented, not coded — there is nothing for it to dispatch.

**872-D8 — No frame-slices sibling.**
Goal-contract plans emit no `<!-- frame-slices-{ID} -->` sibling comment and
no `slice_comment_id` — the contract block replaces both the spine and the
slices. The plan stress test (prosecution, defense, judge) and the
phase-containment-ledger sibling machinery apply to goal-contract plans
unchanged.

**872-D9 — Marker registration.**
Two new marker heads register in the handoff-markers catalog (see § What
Actually Shipped), plus a placeholder name (`goal-run-class`) referenced in the
sample payload but reserved for a future writer. All prose mentions of any of
the three use the inert-render convention (`Format-InertMarkerLabel`), which
strips the `<!--`/`-->` delimiters so a documentation mention of the marker
literal cannot be miscounted as a real block by a raw-text-scanning reader —
see `skills/session-memory-contract/references/handoff-markers.md` § Writing
about markers safely for the general hazard this convention defends against.

## What Actually Shipped

**The 5-function library surface** (`.github/scripts/lib/goal-contract-core.ps1`):

- `Get-GCContractBlock -CommentBody <string>` — extracts the block payload
  between the `<!-- goal-contract` head and the column-0 `-->` terminator, or
  `$null` when no single unambiguous block is present. CRLF/CR-normalizes
  before extraction. Multi-block arity (two or more head markers anywhere in
  the body, including inside a fenced documentation example — extraction is
  markdown-blind) fails rather than first-winning, so a documentation example
  can never silently shadow the real contract.
- `ConvertFrom-GCContractBlock -Payload <string> -RepoRoot <string>` — returns
  `[pscustomobject]@{ Contract; Violations }` and never throws on a schema
  failure (the module-missing case still throws loud). Pipeline order:
  anchor/alias guard → column-0 YAML document-separator guard → size cap →
  `Import-Module powershell-yaml` → `ConvertFrom-Yaml` → empty-parsed-document
  guard → `ConvertTo-Json -Depth 20` → `Test-Json` against the schema file.
- `Get-GCContractHash -Payload <string>` — the 872-D3 canonicalization and
  digest, in one function.
- `Test-GCContractHash -Payload <string> -Expected <string>` — equality check
  against a recomputed digest.
- `Test-GCVariantFrontmatter -CommentBody <string>` — the frontmatter-anchored
  variant-detection rule 872-D5 requires, shared by `frame-validate` and
  `orchestra-spine` so neither hand-rolls its own.

**The `frame-validate` six-row state matrix**, over {variant metadata present,
frame-spine block present, contract block present}:

| variant metadata | spine block | contract block | Result |
| --- | --- | --- | --- |
| yes | no | yes | goal-contract structural branch runs |
| yes | yes | any | fail: ambiguous — two mechanisms declared |
| yes | no | no | fail: variant declared but no contract block |
| no | no | yes | fail: contract block without variant metadata |
| no | yes | no | existing spine path, unchanged |
| no | no | no | existing fail / `plan-too-small` escape, unchanged |

`Invoke-FVPlanValidate` (`.github/scripts/lib/frame-validate-core.ps1`)
implements this by hoisting `Test-GCVariantFrontmatter` above the pre-existing
`$null -eq $spineBlock` check, so a both-blocks plan is now reachable and
correctly classified as ambiguous rather than silently falling into spine
validation. `Invoke-FVGoalContractPlanValidate` is the goal-contract branch
itself: it cross-checks the contract's `issue` field against any
`<!-- plan-issue-{ID} -->` marker in the same comment, then runs both
AC-coverage directions described in 872-D5.

**The two new marker heads** (registered in
`skills/session-memory-contract/references/handoff-markers.md`):

- `goal-contract` — the block head itself, inside the `plan-issue-{ID}`
  comment. Writer: Issue-Planner, at plan persist. Reader:
  `goal-contract-core.ps1` on behalf of `frame-validate-core.ps1` and the
  future #873 harness. Survival: durable, part of the SMC-01 plan-comment
  family.
- `goal-halt-report` — a durable issue-comment head reserved for a future
  run's halt report. Neither writer nor reader exists yet; this row registers
  the head and its inert-render discipline only. #872 does not define or emit
  this marker's payload — that belongs to the goal-run harness child (#874+).

A third name, `goal-run-class`, appears in the 872-D2 sample `<!--
goal-contract -->` payload's `required_markers` list but is not yet backed by
any writer or reader; it is registered now so a reader of the sample payload
is not left wondering what an unregistered entry means.

## Known Limitations / Accepted Carve-Outs

These are documented, accepted trade-offs surfaced by the design challenge,
the plan stress test, and the implementation's own code-review fix cycle —
not omissions.

**The spine-present half of the ambiguity check is intentionally
unenforced.** The 872-D5 state matrix's row for "contract block present, no
variant frontmatter" is fully enforced only when no spine block is present.
When a spine block **is** present alongside a stray contract block and no
variant frontmatter, `Invoke-FVPlanValidate` falls through silently to
ordinary spine validation instead of flagging it. This is deliberate:
`Get-GCContractBlock` is markdown-blind and cannot distinguish a real contract
block from one quoted inside a fenced documentation example in spine-bearing
plan prose. Extending the check to the spine-present case would break an
existing, pinned false-positive guard
(`.github/scripts/Tests/frame-validate-plan-mode.Tests.ps1:617`) that requires
a frame-spine plan whose prose includes a fenced goal-contract authoring
example to still validate as an ordinary spine plan. See the comment
immediately above the spine-parsing branch in `frame-validate-core.ps1` and
`skills/plan-authoring/SKILL.md` § Goal-contract plan variant for the
reconciliation note.

**Migration-type issues are out of scope for the goal-contract variant, for
now.** Migration-type plans require Step 1 to be an exhaustive repo scan,
gated by an operational `migration-scan:` marker that lives inside a
`<!-- frame-slice -->` block. A goal-contract plan never emits a frame-slice
sibling, so that marker has nowhere to live and the requirement is currently
unenforceable for this variant. Disposition: author migration-type work as a
standard frame-spine plan until this gap is resolved. A candidate future path
— carrying the migration-scan intent as an additional `invariants` literal
(the array is already open beyond its two schema-required entries) paired
with a `structure-presence` target — is noted but not implemented; it needs a
validator that actually enforces the new literal, which is out of scope for
this documentation-only pass.

**Schema validity confers no execution trust.** Every field
`goal-contract-core.ps1` parses comes from an untrusted, externally-writable
GitHub comment. `targets[].check` is a shell-command string a future harness
(#873/#874) will execute; `falsifier` and `general_experience_standard` are
free prose that will flow into future agent prompts. Passing
`ConvertFrom-GCContractBlock`'s schema validation means only that the block is
well-formed YAML matching the schema's shape — it confers no safety guarantee
over `check`'s command content or the prose fields' instruction content. Any
future consumer that executes `check`, or feeds `falsifier` or
`general_experience_standard` into an agent prompt, must treat that content as
data, not as pre-vetted commands or trusted instructions, and must not infer
safety from schema validity alone. This note is recorded in both the library's
`.NOTES` block and the matching prose in `skills/plan-authoring/SKILL.md`,
specifically for #873/#874 to read before wiring execution.

**Defect classes found and fixed during the implementation's own review
cycle** (grounding for the parser's current shape, not exhaustive): a CRLF-only
comment body silently failed to extract because the head-marker and
canonicalization regexes assumed bare LF, fixed by normalizing line endings
before every parse-adjacent operation; the anchor/alias guard's character
class initially missed dot-prefixed anchors (`&.a`/`*.a`), which
`powershell-yaml` accepts and expands — a real alias-expansion-DoS bypass of
the guard's own intent — and was widened, then separately had to be narrowed
on the whitespace-prefix side after it was found to false-fire on ordinary
markdown emphasis (`*clear*`) and glob-style CLI tokens (`-Filter *contract*`)
inside mandated verbatim prose such as `general_experience_standard`; a
comment-only payload that parses to a genuinely empty YAML document was found
to make `ConvertFrom-Yaml` emit nothing at all onto the pipeline (not even an
explicit `$null`), which would otherwise reach `Test-Json` with a `$null`
argument and throw, breaching the function's own never-throws-on-schema-error
contract — closed with an explicit `@(...).Count -eq 0` guard, deliberately
distinguished from a bare `---` document-separator payload (which parses to
one explicit `$null` document and is rejected as an ordinary schema violation
instead); and a column-0 YAML document separator (`---`) inside the payload
was found to let `ConvertFrom-Yaml`'s first-document-only behavior validate a
real contract while smuggling an unvalidated second document along for the
ride into whatever the hash function canonicalizes, closed with a pre-parse
guard rejecting any column-0 `---` line outright. Each of these is documented
inline at its fix site in `goal-contract-core.ps1`.

## What's Deliberately Deferred

- **#873** owns run-time `contract_hash` verification (recomputing the digest
  at harness invocation and halting on mismatch) and executing the contract's
  `targets[].check` commands. It reuses `Get-GCContractHash` and
  `Get-GCContractBlock` rather than re-deriving either. Shipped — see
  [goal-contract-validator.md](goal-contract-validator.md) for that
  component's own design decisions, shipped shape, and known limitations.
- **#874+** owns the goal-run harness itself: launching a goal run, reading
  `halt_conditions` and `budget` to bound it, invoking #873's validator to
  judge a completion claim, and writing the `goal-halt-report` marker this
  issue only registered the head for.

## Related Sources

- [skills/plan-authoring/SKILL.md](../../skills/plan-authoring/SKILL.md) §
  Goal-contract plan variant — the operational authoring contract
- [skills/plan-authoring/schemas/goal-contract.schema.json](../../skills/plan-authoring/schemas/goal-contract.schema.json)
  — the single schema authority
- [.github/scripts/lib/goal-contract-core.ps1](../../.github/scripts/lib/goal-contract-core.ps1)
  — the parser library, with the full canonicalization and trust-boundary
  notes in its `.NOTES` block
- [skills/session-memory-contract/references/handoff-markers.md](../../skills/session-memory-contract/references/handoff-markers.md)
  — marker registration for `goal-contract`, `goal-halt-report`, and
  `goal-run-class`
- [Documents/Design/goal-loop-platform-spike.md](goal-loop-platform-spike.md)
  — issue #871's platform-capability spike; a distinct, narrower topic than
  this document (probes the `/goal` platform, not the plan-seat artifact)
- [Documents/Design/goal-contract-validator.md](goal-contract-validator.md)
  — issue #873's run-time validator, the consuming component that verifies a
  goal run's completion claim against this artifact's contract
- [Documents/Design/session-memory-contract.md](session-memory-contract.md)
  — the marker-survival vocabulary this document's markers are registered
  against

<!-- vocab-pointer -->
> **Unfamiliar with a code or term?** Shortcodes like `SMC-NN`, `D1/D2/D3`, and `CE Gate` are defined in the [plain-language vocabulary](../../HOW-IT-WORKS.md#vocab).
