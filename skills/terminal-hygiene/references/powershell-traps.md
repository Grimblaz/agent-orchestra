# PowerShell and Pester traps

Language-level and runner-level traps that have each cost this repository real time. **Most of them
do not throw** — they return a wrong shape, a wrong count, or a green verdict, and a trap that errors
teaches itself while these do not. A few throw loudly and are here anyway, because they fire
somewhere other than where you would look: on the caller a refactor never touched, or on a whole
batch rather than the one bad input. Each entry says which it is.

Read this before writing a verification script, a guard, or a test whose *purpose* is to detect
something. Most of what follows is a way for such a check to report success while checking nothing.

Scope: this file is about the PowerShell language, .NET interop from PowerShell, regex in
PowerShell, and the Pester runner. Git and `gh` CLI traps live in
[`skills/safe-operations/references/git-and-gh-traps.md`](../../safe-operations/references/git-and-gh-traps.md).

## Comparison and matching

### `-eq`, `-ne`, `-contains` and `-like` are case-insensitive

**Trap.** PowerShell string comparison ignores case by default. `@('Foo') -contains 'foo'` is
`$true`. The case-sensitive forms are `-ceq`, `-cne`, `-ccontains`, `-cnotcontains`, `-clike`.

**Why it's silent.** A criterion phrased "identical", "matching", "unchanged" or "verbatim",
implemented with `-eq`, does not test text. On #986 a memory-index check compared a policy header
against its shipped reference with `-eq` and reported `present, complete` for a header whose first
line had been lowercased.

Worse, it defeats its own control. The script that planted a case-only mutation to prove the guard
could fail wrote:

```powershell
if ($Content -eq $live) { throw "mutation did not change the file" }
```

and threw — because the mutated content compared equal to the original. The bug defeated the control
written to catch the bug.

**Fix.** Whenever the words *identical*, *matching*, *unchanged* or *verbatim* describe what the code
claims to check, use the `-c` form. Reserve `-eq` for comparisons where case genuinely does not
matter, and say so.

**Seen in:** #986. This repository has now shipped this defect twice — once here and once in its
Pester form, which is the next entry. Same root, different surface.

### `Should -Be` is case-insensitive too

**Trap.** Pester's `Should -Be` ignores case; `Should -BeExactly` does not.

**Why it's silent.** On #908 two tests literally named *"preserves case"* and *"preserves the drive
case"* passed against an implementation that lowercased the drive letter. On Windows the filesystem
is also case-insensitive, so the defect broke neither the test nor the local runtime lookup — it
only bites on a case-sensitive filesystem, or when the derived string is compared as a string rather
than used as a path.

**Fix.** Use `-BeExactly` for any assertion whose purpose is casing, or whose expected value names a
real path, identifier or slug. And run every new test against the *pre-fix* code: a test that stays
green before the fix is either testing unchanged behavior — name which — or it is vacuous.

**Seen in:** #908. Converting the string assertions to `-BeExactly` took the pre-fix red count from
7 of 14 to 11 of 14. Four tests had been asserting nothing they claimed to assert.

### `-like` is a wildcard operator, not a contains

**Trap.** `-like "*$anchor*"` treats several characters in the anchor as syntax:

| In the anchor | What `-like` does |
| --- | --- |
| `[Name]` | character class — one char from `{N,a,m,e}`, so `Verified by: [Name]` never matches itself |
| `(which tests?)` | `?` matches any single character, loosening the check |
| a backtick | escapes the next character, silently swallowing it |
| `*` | matches anything |

Two traps travel with it. `Has $x 'A1' + [char]0x2013 + 'A5'` does **not** concatenate — PowerShell
parses `+` as further arguments to the command, so the needle binds to just `A1`. And en dash
(`–`, U+2013), em dash (`—`, U+2014) and hyphen are three different characters; an anchor copied
out of prose fails against text using another one.

**Fix.** Use an ordinal `Contains`:

```powershell
function Has { param([string]$Hay, [string]$Needle) $Hay.Contains($Needle, [System.StringComparison]::Ordinal) }
```

Build concatenated needles into a variable first, or parenthesize. Match dashes with `[–—]`, or
build the exact character with `[char]0x2014`.

**Seen in:** #939 — four false reds and one silently loosened check in a single verification script.
The loosened one was an anti-deletion assertion, which is exactly where a false green matters.

## Collections and shapes

### `return ,$array` plus a caller's `@()` yields one element

**Trap.** `return ,$arr` wraps an array in an outer one-element array so the pipeline will not
unroll it. That is correct **only** when the caller assigns directly (`$x = Get-Thing`). `@()` does
not flatten the nesting, so a caller writing `@(Get-Thing ...)` ends up holding a single element that
*is* the array.

**Why it's silent.** Nothing throws; collections are simply the wrong shape and count. Three
instances in one session:

- `$surfaces -contains 'brief-review'` was always `$false`; `"$surfaces"` rendered as
  `System.Object[]`, which was the only tell.
- A ledger head was built with one `finding_id` line holding 29 space-joined ids. It parsed cleanly
  as **one** upheld finding against 29 blocks; `ParseStatus` was `ok` and only the count was wrong.
- `@(Get-PhaseContainmentBlock ... | Where-Object { $_ -is [string] })` emitted the inner array as
  one object, `$_ -is [string]` was false for it, and all 29 blocks were filtered away — a
  verification guard reporting success on a corpus it had never looked at.

**Fix.** Use the comma form only to preserve an empty array for a caller that assigns directly. If
callers write `@(...)`, drop the comma. Never pipe a comma-returning function through a
type-filtering `Where-Object`.

**Diagnostic.** Call the function on inputs of 1, 2, 5 and 29 items and print `.Count`. A constant
`1` across all four is the signature. When two callers of one function disagree, compare their
collection idiom before anything else.

**Seen in:** #951 / #963. A probe asserting `ParseStatus -eq 'ok'` would have passed twice; what
caught it was a probe asserting concrete counts.

### `[ordered]@{}` with integer keys: the indexer is positional, not a key lookup

**Trap.** `[ordered]@{}` produces an `OrderedDictionary`, whose `int` indexer selects **by position**,
not by key. With integer keys the two readings collide silently:

```powershell
$h = [ordered]@{
    1 = 1..22 | ForEach-Object { "M$_" }
    2 = 1..13 | ForEach-Object { "M$_" }
    3 = 1..15 | ForEach-Object { "M$_" }
}
```

Measured on pwsh 7.6.3:

```text
$h[1]           -> count=13     <- position 1, i.e. key 2's value
$h[2]           -> count=15     <- position 2, i.e. key 3's value
$h[3]           -> NULL         <- position 3 is out of range
$h[[object]1]   -> count=22     <- key lookup, correct
GetEnumerator() -> 1:22  2:13  3:15   <- correct
```

**Why it's silent.** Every key is present and every value is intact — `$h.Count` is 3 and iterating
`GetEnumerator()` gives 22/13/15. Only the indexed reads are wrong, off by one, with a `$null` at the
end instead of an error. A guard that iterates passes; a guard that indexes gets shifted data and a
null tail. A `Hashtable` from a plain `@{}` has a key-based indexer, so the identical code with the
cast removed behaves correctly — which makes the `[ordered]` cast, not the pipeline, load-bearing.

**Fix.** With integer keys, never index an `OrderedDictionary` with a bare `int`. Cast the key
(`$h[[object]$k]`), or iterate `GetEnumerator()`, or use string keys where the ambiguity cannot arise.
When a literal builds a collection of known size, assert the size immediately after construction.

**A correction worth carrying.** This entry previously claimed the pipeline on the right-hand side
mis-parsed and dropped key 3 entirely. It does not: the literal evaluates correctly. That reading —
and a later "off-by-one value shift" reading — were both artifacts of probing with the positional
indexer. Two independent review passes reproduced the wrong symptom before a third isolated the
indexer. If you are diagnosing a collection that looks short, check how you are *reading* it before
concluding it was built wrong.

### Joining two regex match sets on `.Index` desyncs

**Trap.** Splitting one combined regex into two `[regex]::Matches` passes and joining the results on
`.Index` fails when either pattern ends in a greedy `\s*$`: the longer pattern consumes into the
whitespace between items, so its scan resumes one character further along. The indices never collide
again after the first item.

**Why it's silent.** It is correct under the common case and wrong under the others:

```text
LF, 0-1 blank lines between entries   -> correct
LF, >=2 blank lines                   -> N1=sustained N2=NULL N3=NULL
CRLF, >=1 blank line                  -> N1=sustained N2=NULL N3=NULL
```

Index trace: the id-only match sat at `N2@85`, the coupled match at `N2@86` — a one-character
desync.

**Fix.** Use **one** regex with the optional half as a non-capturing group, then test
`Groups[N].Success`:

```powershell
'(?m)^\s*-\s+finding_id\s*:\s*(\S+)\s*$(?:\s*^\s*judge_ruling\s*:\s*(\S+)\s*$)?'
```

Do not try to correct the index arithmetic — any index join stays hostage to the trailing `\s*`.

**Meta-lesson.** The code comment asserting *"Both regexes start matching at the same position, so
their .Index values line up"* was false, and asserting it is what stops a reader checking it. When a
fix rests on an invariant, the test carries it, not the comment.

**Seen in:** #963, `Get-BRMJudgeRulingsFindingIds`.

## Null, absence, and StrictMode

### `??` does not guard an absent property under StrictMode

**Trap.** Under `Set-StrictMode -Version Latest`, reading an **absent** property throws
`PropertyNotFoundException` before `??` can coalesce. So `[long]($u.input_tokens ?? 0)` defends only
the present-but-null case while reading as if it handled both.

Writing `?? 0` is itself the tell that the field was expected to be optional — and the correct guard
for optionality is a presence check:

```powershell
if ($Usage.PSObject.Properties.Match($Name).Count -eq 0) { return 0L }
```

**Why it's silent.** It is not silent — it is total. With `$ErrorActionPreference = 'Stop'` at a
script entry point, the non-terminating error becomes terminating and produces `EXIT=1,
STDOUT_BYTES=0` across a whole directory: one nonconforming input destroys the report for every good
one. The silence is in the *review*, where `?? 0` reads as fully defended.

**Fix.** Test presence with `.PSObject.Properties.Match()`. Add a per-file `try`/`catch` around the
reader so one bad input cannot cost the whole batch.

**Review lens that caught it:** the function guarded every *other* optional property with
`.PSObject.Properties.Match()`, and these four accesses were the only unguarded ones. An
inconsistency in defensive style within one function is a finding, not a nit. A corpus survey of
1,837 transcripts and 106,272 usage rows found zero missing fields, and the judge still sustained at
HIGH: latency is not safety when the blast radius is the whole run.

**Seen in:** #975.

### `SetEnvironmentVariable($name, $null)` does not remove the variable

**Trap.** `$null` binds to the method's `[string]` parameter as `''`, so the variable survives,
defined and empty. Measured on PowerShell 7.6.3:

```text
after seed                : exists=True   value=[seed]
after $null               : exists=True   value=[]      <- still there
after [NullString]::Value : exists=False                <- actually removed
```

**Why it's silent.** The regression test had the same blind spot: it compared
`[string]$after | Should -Be ([string]$before)`, and `[string]$null` equals `[string]''`. The cast
added "for safety" is exactly what hid the bug. Five prosecution passes, defense and judge all read
the line and none saw it. It surfaced only when the same restore pattern was applied to `GIT_DIR`,
where an empty value fails loudly (`fatal: not a git repository: ''`) and took ten tests down at
once.

**Fix.** Use `[Environment]::SetEnvironmentVariable($name, [NullString]::Value)`, or
`Remove-Item Env:\NAME`.

**Generalizable rule.** When a test asserts state was *restored*, assert **existence separately from
value**. A cast, a `-join`, or a null-coalescing default in the comparison collapses "absent" and
"empty" into one.

**Seen in:** #958.

### An optional `[ref]` parameter may not carry a default

**Trap.** This throws `ParameterBindingArgumentTransformationException` on exactly the calls that
**omit** the argument — the ones the default exists to serve — because PowerShell evaluates the
default expression through the same type-transformation pipeline as an explicit argument, and `$null`
cannot transform to `[ref]`. Calls that supply the argument bind fine, which is why the break lands
on the pre-existing caller a refactor never touched:

```text
A()                        -> THROWS      (default evaluated)
A -Other 'y'               -> THROWS      (default evaluated)
A -R ([ref]$v)             -> ok
A -R ([ref]$v) -Other 'y'  -> ok
```

```powershell
param(
    [AllowNull()][ref]$ReasonCode = $null
)
```

**Fix.** Declare no default at all. Omitted arguments then bind to the CLR default directly:

```powershell
param(
    [ref]$ReasonCode
)
```

**Why it still belongs here.** It is loud — but it breaks the *pre-existing, unmodified* caller that
the refactor was supposed to leave untouched, which is not where anyone looks first.

**Seen in:** extracting `Test-CostContributionRateUnavailable` into
`.github/scripts/lib/cost-attribution.ps1`.

## Capturing native command output

### Three traps in one line

**Trap.** `$x = <native command> 2>$null` carries three distinct failure modes, all found together
on #977:

1. **`2>$null` does not catch a missing command.** It redirects the *process's* stderr. If the
   command cannot be resolved at all, PowerShell's command lookup throws `CommandNotFoundException`
   before any process starts — at the default `$ErrorActionPreference`, not only under `Stop` — and
   the redirection has nothing to catch. Use
   `try { $x = cmd ... 2>$null } catch { return @() }`.
2. **`[string]$captured` joins with a space.** Casting an array to string joins on `$OFS`, which
   defaults to a space, not a newline. Any later `(?m)^`-anchored regex silently stops matching.
   Join on a real newline instead, or pipe through `Out-String`:

   ```powershell
   $text = $captured -join "`n"
   ```

3. **`-join` over a captured array is lossy on a lone CR.** PowerShell's output splitter treats a
   bare CR as a line terminator, so the join re-emits it as a real newline — fabricating structure
   that was not in the source. On #977 this synthesized a bogus `## Acceptance Criteria` header.
   CRLF fabricates no structure, because the break was already there — but the CR byte does not
   survive the round trip either (it is consumed as part of the terminator), so a byte-comparison or
   a `\r\n`-seeking check after a capture will still be wrong.

**Why it's silent.** Both AC helpers documented *"returns empty on any failure (missing gh…)"* and
were wrong about exactly that word for months.

**Testing note.** A shim that exists and exits non-zero is a *failing* command, not an *unavailable*
one. To exercise unavailability, **replace** `$env:PATH` with an empty directory (do not prepend) and
assert `Get-Command <cmd>` is false — then **restore it in a `finally`**. `$env:PATH` is
process-scoped and the sharded runner gives each test file its own `pwsh`, so an unrestored
replacement silently breaks every later test in that container that shells out to `git`, `gh` or
`pwsh`. This is the same restore-bug class as the `SetEnvironmentVariable` entry below, and the same
rule applies: assert existence separately from value.

**Related: console encoding.** On Windows `[Console]::OutputEncoding` defaults to the OEM codepage,
so UTF-8 subprocess stdout is decoded with the wrong table. Measured on #968: 12 non-ASCII characters
became 36 and every em dash was lost, with no error. Pin the encoding and restore it in a `finally` —
`skills/naming-register-policy/scripts/newcomer-audit.ps1` has the correct shape.

**Seen in:** #977 / PR #982, #968.

**Fuller treatment.** [`skills/review-judgment/references/multiline-capture-audit.md`](../../review-judgment/references/multiline-capture-audit.md) is the audit of this class across the repository, from the same issue (#977). Read it before changing a capture site; this entry is the summary, that file is the survey.

## Escaping, parsing, and self-inflicted wounds

### A literal hash-anglebracket ends comment-based help early

**Trap.** PowerShell block comments do not nest. The two-character block-comment **close** sequence,
written literally anywhere inside a help block, closes it immediately — everything after is parsed as
code. This is hit by documenting the delimiter in the docstring that uses it.

**Why it's silent.** The parse check used to verify the file was itself broken:

```powershell
[Parser]::ParseFile($p, [ref]$null, [ref]$e); if ($e -and $e.Count) { ... } else { 'PARSE OK' }
```

`[ref]$e` on a non-existent variable **throws**, so `$e` was never populated and the `else` branch
ran unconditionally. The check printed `PARSE OK` for a file that does not parse, and the real
`[ref]` error was in the same output and got read past.

**Fix.** Spell the delimiters out in prose — "angle-bracket-hash to open, hash-angle-bracket to
close" — rather than writing them literally. And bind the error sink explicitly:

```powershell
$tokens = $null; $errors = $null
$null = [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path $Path).Path, [ref]$tokens, [ref]$errors)
if ($errors.Count) { $errors | ForEach-Object { "LINE $($_.Extent.StartLineNumber): $($_.Message)" } } else { "PARSE OK ($($tokens.Count) tokens)" }
```

**Seen in:** #969 / PR #988 — 807 tests went from passing to failing, and the downstream error
pointed 30 lines below the real cause (`The '<' operator is reserved for future use`).

### A literal dollar in a regex inside a double-quoted string needs two escapes

**Trap.** Matching a literal `$` from a double-quoted string needs **both** escapes, and applying
only one is easy:

- backtick-dollar escapes **PowerShell string interpolation**, producing a string containing `$Is`;
- backslash-dollar escapes the **regex metacharacter**, matching a literal `$`.

You need `\` then backtick then `$`, so the string ends up containing `\$Is`. With only the
interpolation escape, the regex sees `$` as an **end-of-line anchor**, and an alternation guarded by
it can never match.

**Why it's silent.** A negative lookahead built on the broken anchor always succeeds, so a platform
exemption stops exempting and the guard flags everything it should have skipped — no error, just
wrong results.

**Fix.** Never verify a regex from the form typed into a probe. Extract the pattern from the file and
expand it the way the runtime will:

```powershell
$line = (Get-Content $file | Select-String -SimpleMatch 'Select-String -Pattern').Line
$pat  = [regex]::Match($line, '"(.+)"').Groups[1].Value
$pat  = $ExecutionContext.InvokeCommand.ExpandString($pat)   # now test $pat
```

Then run it against the live tree and assert the expected flag/exempt split.

**Seen in:** #948 / PR #955. The standalone probe passed 11 of 11 because the probe string used both
escapes while the edit written into the test file used only one. Two checks in the same command
disagreed — one said all five platform gates were flagged, the other said exempt. A disagreement
between two checks is signal to chase, not a reason to trust the preferred one.

### `pwsh -File` exit 64 is an unresolvable script path, not an angle bracket

**Trap.** `pwsh -NoProfile -File <script> <args>` exits **64** with a full `pwsh` usage dump when it
cannot resolve the script path. The usage dump names nothing about paths, so the cause is easy to
misattribute to whatever looked unusual in the arguments.

The most common way to hit it on Windows is a POSIX-looking path: `pwsh` resolves `/tmp/x.ps1` to
`C:\tmp\x.ps1`, which is **not** where Git Bash's `/tmp` points — see
[§ `/tmp` is not the same directory in Bash and in pwsh on Windows](../../safe-operations/references/git-and-gh-traps.md)
in the git/gh reference, which is the same divergence from the other side.

Measured on pwsh 7.6.3:

```text
pwsh -NoProfile -File C:/real/probe.ps1 -Marker '<!-- x -->'   -> exit 0, marker bound
pwsh -NoProfile -File /tmp/probe.ps1    -Marker 'plain'        -> exit 64 + usage dump
pwsh -NoProfile -File C:/nope/gone.ps1  -Marker 'plain'        -> exit 64 + usage dump
```

The third line carries no angle bracket at all and still exits 64; the first carries one and
succeeds.

**A correction worth carrying.** This entry previously attributed exit 64 to `pwsh`'s argument parser
treating `<` as redirection, and prescribed the call operator to avoid the `-File` re-parse. Eleven
invocation shapes across both shells were re-run during review and **none** reproduced it; the
remedy worked only because calling in-session sidesteps path resolution too. The original incident
recorded a wrong script path and an exit 64 in the same breath, and the angle bracket got the blame.
When a failure and an unusual-looking input coincide, vary the input before naming it the cause.

**Fix.** Check the path resolves as `pwsh` will resolve it. Where you are already in a session,
calling directly is simplest and avoids the question:

```powershell
& ./path/script.ps1 -Marker '<!-- ... -->'
```

**Array arguments are a separate, real trap.** `pwsh -File script.ps1 -Items @('a','b')` lets the
calling shell expand the literal into separate argv entries, of which `-File` binds only the first —
the rest spill onto the next positional parameter. Full treatment, with the live case that bit,
is in [§ `post-merge-cleanup.ps1` must run from the primary checkout](../../safe-operations/references/git-and-gh-traps.md).

**Adjacent.** `Resolve-PersistDecision.ps1` is a function-definition file: dot-source it, then call
`Resolve-PersistDecision -Inputs $hash`. Invoking it with `&` silently returns `$null`, so the
decision struct reads as all-empty rather than erroring. (`skills/persist-changes/SKILL.md` §
Executor Contract says "call" it without naming the invocation form.)

## The sharded Pester runner

**Owner: [`Documents/Design/test-suite-baseline-948.md`](../../../Documents/Design/test-suite-baseline-948.md).**
That record already carries the runner's failure-count arithmetic (`fail=13` is 7 failing assertions
across 6 files plus 6 per-file phantoms), why the reconciliation is not applied blind, and why
`crash-worker.Tests.ps1` and `zero-tests.Tests.ps1` are fixtures rather than failures. Read it for
the counting trap; it is the fuller and more careful treatment, and
`skills/terminal-hygiene/SKILL.md` § Pester Scope already points there.

What follows is what that record does **not** cover.

### Read the right `TOTAL:` line — the runner is re-entrant

**Trap.** `run-pester-sharded.Tests.ps1` is
itself a suite file that drives `Invoke-PesterSharded` against temp fixtures — around thirty call
sites, of which `-DeterminismCheck` is one. A plain full-suite run therefore prints one `TOTAL`
block per nested fixture run plus one for the real run, and only the last is the run you started.
(Issue #1037 added a further batch of nested runs and put this suite on the sequential shard, so
the count moves; count call sites rather than trusting a number written down here.)

Anchor on the run attribution, not on position: the real run is the one whose line reads
`run=outer`. Nested fixture runs report `run=nested(depth=1)`. `Determinism check: PASSED` and the
min-count `WARNING` are emitted by those nested fixtures on every plain run, so grepping for either
as evidence is guaranteed-green.

A wait-loop keyed on the first `TOTAL` line to appear will fire on a nested fixture's, minutes
before the real run finishes — that has happened.

**And the totals changed shape in #1037.** There is no longer one `TOTAL:` line carrying
`pass=/fail=/files=N/N`. There are two, and they name their units: `TOTAL suites (unit: files)`
with a per-outcome tally, and `TOTAL tests (unit: test cases)`. A third line reports reconciliation
against the caller's selection. A parser keyed on the old shape matches nothing.

**And.** `ExitCode=1` with `TotalFailed=0` is now the NORMAL shape for most red runs, not a
four-case curiosity: since #1037 a crashed worker, a suite that discovered no tests, a suite whose
tests were all skipped, and a selected suite that produced no result at all each redden the run
while failing zero *tests*. The old list — path unresolved, zero discovered, the `MinTestCount`
floor, a `-DeterminismCheck` flip — still holds and is no longer exhaustive. Read `SuitesNotPassed`
and `SuiteOutcomes`, or `ExitCode`; never `TotalFailed` alone.

**Seen in:** #948.

### "Fails in the suite, passes alone" is not mock leakage here

**Trap.** The reflex diagnosis for a full-suite-only failure is cross-file state leakage. Under this
repository's runner that explanation is **structurally unavailable**: `pester-sharded-core.ps1` runs
each `.Tests.ps1` in a separate `pwsh` process (`ForEach-Object -Parallel -ThrottleLimit
$FanOutWidth`; a small real-git allowlist runs sequentially, after the parallel shard, but still
per-process). Mocks cannot leak between files.

**Why it's silent.** The mislabeled explanation reads as benign — an artifact, not a defect. In the
filing for #948, "mock leakage under full-suite ordering" survived into the issue *as evidence*.

**Fix.** Check what actually ran the suite. If it was `run-pester-sharded.ps1`, look for causes that
survive process isolation — and check the suspicious output is not *planted* before theorising about
the environment.

**The `gh: unexpected error connecting to api.github.com` cluster is fixture text, not the network.**
It is hard-coded via `New-P4GhStub -StderrText` at `marker-transport-core.Tests.ps1:220,364,375,385`,
`persist-marker-core.Tests.ps1:172`, `persist-marker-wrapper.Tests.ps1:318` and
`persist-marker.Tests.ps1:114`. It appears in runs that exit 0. An earlier revision of this entry
read that string as evidence of real network contention under `-ThrottleLimit 8` and prescribed
looking there; that diagnosis was corrected in #948 and the correction is the reason this paragraph
exists. Do not re-investigate it from scratch, and do not respond to it with a mechanism — lowering
throttle or adding retries would be aimed at a phantom.

Where you do form an environment-shaped hypothesis, tag it `sample-inferred` per doctrine amendment
A2 and do not let it set a mechanism.

**Cross-reference.** `Documents/Design/test-suite-baseline-948.md` § The previously reported
network-touching failure class records the same class from the other side: across two full runs the
live-network failures did not appear, and it is logged as **not reproduced** rather than absent —
because intermittency is exactly what two runs cannot exclude. Read the two together: that record
says the class did not fire; this entry says the string you are most likely to see is planted.

**Seen in:** #948, #818.
