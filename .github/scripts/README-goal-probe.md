# Goal-Loop Capability Probe — Run-Book

Issue #874, plan step 2 (`<!-- plan-issue-874 -->`, comment 5029090105). This is
**not** the evidence document. It is the instruction set the owner follows to
*produce* the observations that plan step 4 turns into
`Documents/Design/goal-loop-capability-probe.md` and the
`<!-- goal-probe-findings-874 -->` decisions comment. Nothing here is itself a
finding.

Evidence labels (`observed | documented | static | inferred`) are inherited
verbatim from the #871 spike's convention — see
[`Documents/Design/goal-loop-platform-spike.md`](../../Documents/Design/goal-loop-platform-spike.md)
§ Evidence labelling. This run-book states, per leg, what makes a result earn
each label; it does not re-derive the taxonomy.

The three scripted instruments this run-book invokes were authored in plan
step 1 and are read-only with respect to what they measure — they parse or
detect, they do not launch anything:

- `lib/goal-probe-streamjson.ps1` — `Get-GoalProbeStreamJsonResult` (legs b, c)
- `lib/goal-probe-usage-reader.ps1` — `Get-GoalProbeLiveUsageReading` (leg f)
- `lib/goal-probe-forcehalt-rig.ps1` — `Test-GoalProbeForceHaltWin` +
  `Get-GoalProbeForceHaltSettingsFragment` (leg e, win/loss detection only)

## Non-goals

This run-book does **not** cover, and none of its steps should be read as
specifying:

- The harness's future *runtime* credential store (production arm-H
  credential lifecycle is #874 harness-plan scope, not this probe).
- Production containment for a live goal-run harness invocation. The
  containment protocol below is scoped to this disposable probe only.
- Building, launching, or supervising the harness itself. Nothing here
  drives a goal loop's continuation — legs (a)/(d)/(e)/(g) are watched by a
  human at a keyboard, and the scripted legs only parse artifacts a human
  produced.

## Leg dependency: the leg-a cascade

Legs (b) and (c) both feed a raw stream-json `result` line into
`Get-GoalProbeStreamJsonResult`. That line only exists if a headless run
under leg (a) *completes* far enough to emit a terminal `result` event. If
every leg (a) attempt is blocked (e.g., the spike's 401), there is no line
for (b)/(c) to parse.

**Rule**: if leg (a) is inconclusive (blocked, not completed), record legs
(b) and (c) as `blocked — leg-a cascade`, not as independent parse or
budget-detection failures. Do not attempt to synthesize a fake `result` line
to exercise the parser standalone and then report that as leg (b)/(c)
evidence — that would only re-confirm the parser's unit tests (already
covered in step 1), not answer the capability question legs (b)/(c) exist to
answer.

Leg (d) is **not** gated by this cascade: the spike observed `goal`
registration in the `system.init` event, which the CLI emits before any
budget- or auth-gated turn completes. A leg (a) auth failure does not by
itself block leg (d).

## Credential handling (leg a is the gating experiment)

Leg (a) is the named gating experiment for headless auth. This section is
the full protocol; leg (a)'s own entry below just points back here.

**Candidate acquisition strategy**: the owner runs `claude setup-token`
once, interactively, in a real interactive terminal (TTY) — it cannot run
non-interactively, as the spike already confirmed: "produced no output under
a non-interactive timeout". This step has never completed in this repo's
tooling before, so
capture its output faithfully — including the exact environment-variable
name it instructs you to export, if it prints one — because that detail is
itself `observed` evidence, not something this run-book can pin in advance.

1. In a TTY outside any scripted context, run `claude setup-token`.
2. Save the resulting token verbatim to an **out-of-repo** file:
   `$HOME/.goal-probe-credentials/claude-oauth-token.txt` (create the
   directory first; restrict its permissions if the OS supports it). This
   path is outside every git worktree — it is not reachable by `git status`
   in any checkout.
3. In the **same shell session** you will run probe commands from, load the
   token into an environment variable — do not write it to a file inside
   any worktree, and do not pass it as a CLI argument:

   ```powershell
   $env:CLAUDE_CODE_OAUTH_TOKEN = (Get-Content -Raw "$HOME/.goal-probe-credentials/claude-oauth-token.txt").Trim()
   ```

   (Adjust the variable name to whatever `claude setup-token` actually
   names in step 1's captured output if it differs — record which name was
   used as part of the leg (a) evidence.)
4. Every headless `claude -p` / `claude agents --json` invocation in this
   run-book inherits the token via that environment variable, never a file
   path argument or a committed file.
5. If `claude setup-token` itself fails, or every headless invocation still
   401s with the token exported, **stop retrying and record leg (a) as
   `documented`-blocked with the 401 evidence** (raw, redacted CLI
   output/exit code). This is an honest null, not a gap to paper over —
   it is exactly what the #871 spike already found once.

**Redaction barrier**: any script or manual step that copies raw
stdout/stderr/transcript content toward the evidence doc or the #874
decisions comment MUST scrub token-shaped strings first. Concretely: before
writing captured text anywhere that will be committed or posted, replace
any substring matching the token's own observed shape (fixed prefix +
high-entropy suffix, once leg (a) reveals what that shape actually is) with
a fixed redaction marker (e.g. `[REDACTED-TOKEN]`), plus a generic
long-high-entropy-token heuristic as a backstop for any token shape not yet
observed. This scrub runs **before** any capture is written to
`Documents/Design/goal-loop-capability-probe.md` or posted to #874 — never
after.

**Validating "no secret committed"**: three layers, not one:

1. **Out-of-repo store** (structural) — the token file never lives inside
   any git worktree, so it cannot appear in `git status` or a diff by
   construction.
2. **`.gitignore` backstop** — a defense-in-depth entry (added by this
   step) in the repo root `.gitignore` for `.goal-probe-credentials/` and
   `*-oauth-token.txt` (matching this section's own documented
   `claude-oauth-token.txt` filename), in case operator error ever places
   a copy inside a worktree.
3. **Known-token-shape scan** — after leg (a) reveals the token's actual
   shape, grep the probe worktree's diff and any file about to be committed
   or posted against that shape. This is deliberately **not** "`rg` for the
   absence of the literal token value" — a reviewer who does not already
   know the secret cannot search for its literal absence; that check would
   trivially "pass" whether or not the secret is present, because there is
   nothing to match against. A shape-based scan (prefix pattern /
   entropy heuristic) is the only check that can actually catch an
   accidental paste.

## Untrusted-capture discipline

Transcript and result text captured during any leg is model-produced and
may contain injected instructions carried over from issue/repo/web content
the executor read during the run. Before any such text is embedded in the
evidence document or the `<!-- goal-probe-findings-874 -->` decisions
comment:

- Fence it as data (a fenced code block), never as live prose the reader
  could mistake for the doc author's own claims.
- Before scanning for marker shapes, look for any substring shaped like
  `<!--` / `-->` (e.g. `Select-String -Pattern '<!--|-->' -AllMatches`) in
  the captured text — do not rely on unaided visual recognition when
  scanning model-produced output for injected marker-shaped strings.
- Inert-render **every** piece of captured transcript/result text before it
  reaches a posted comment or the evidence document — not only text that
  visually appears to contain a marker shape, since captured text is
  adversary-controlled and a nested/overlapping delimiter shape is not
  reliably human-detectable. Use the backtick-safe, fixed-point renderer
  `Format-GCInertRender`
  (`.github/scripts/lib/goal-contract-validate-core.ps1`, s6 section) —
  dot-source that file before use. This is the **unconditional default and
  only recommended renderer** for this run-book's untrusted-capture use
  case. (Its internal helper `Get-GCInertRenderResult` is `script:`-scoped
  and intended-private — do not call it directly; use the public wrapper.)
  `Format-GCInertRender` loops the strip pass to a fixed point (closing the R2
  reconstruction gap: a single non-looping pass can leave a nested
  `<!<!---- plan-issue-9 ---->>`-shaped input able to reassemble into a
  live marker) and escapes with a longest-backtick-run-plus-one fence
  instead of a single backtick pair. Do **not** use
  `Format-InertMarkerLabel` here — it is a private `script:`-scoped helper
  intended for phase-containment report labels, not for untrusted
  transcript capture, and it lacks the fixed-point/R2 hardening this use
  case requires. Do not hand-roll a third variant.

A captured transcript that carries an injected marker-shaped string must
never be posted un-inert-rendered; that is exactly the self-DoS channel a
marker-pinned reader (any future `/goal-run` consumer of this issue) is
vulnerable to.

## Containment

The disposable probe goal loop runs in an **isolated worktree outside the
product checkout** — never in the active `feature/issue-874-goal-run-harness`
checkout this plan itself lives in.

1. Resolve the product checkout root and its parent:

   ```powershell
   $productRoot = git rev-parse --show-toplevel
   $repoParent = Split-Path -Parent $productRoot
   ```

2. Create the probe worktree on a throwaway branch, named per the plan's
   convention (`{repo-parent}/goal-probe-{token}`):

   ```powershell
   $token = [guid]::NewGuid().ToString('N').Substring(0, 8)
   $probeWorktree = Join-Path $repoParent "goal-probe-$token"
   git -C $productRoot worktree add -b "goal-probe/$token" $probeWorktree
   ```

3. Capture the product checkout's fingerprint **and** HEAD **before** any
   leg runs. Define this as a **function once**, in the shell session you
   will run the probe from, and call it at both step 3 and step 5 — never
   retype the hashing block, because any divergence in CRLF normalization
   changes the hash and produces a false tamper alarm at step 5. The
   porcelain output must be joined into a single string before it is
   converted to bytes and hashed — piping a byte array through the pipeline
   auto-enumerates it element-by-element, which silently breaks
   `ComputeHash` (it ends up hashing one byte at a time instead of the whole
   buffer). This mirrors the working, tested convention in
   `skills/subagent-env-handshake/scripts/New-SubagentDispatchPrompt.ps1`
   (`Get-DirtyTreeFingerprint`):

   ```powershell
   function Get-GoalProbeProductState {
       param([Parameter(Mandatory)][string]$ProductRoot)
       $porcelainRaw = (git -C $ProductRoot status --porcelain 2>$null) | Out-String
       $porcelainNormalized = ($porcelainRaw -replace "`r`n", "`n") -replace "`r", "`n"
       $porcelainBytes = [System.Text.Encoding]::UTF8.GetBytes($porcelainNormalized)
       $sha256 = [System.Security.Cryptography.SHA256]::Create()
       try {
           $hashBytes = $sha256.ComputeHash($porcelainBytes)
       }
       finally {
           $sha256.Dispose()
       }
       [pscustomobject]@{
           Fingerprint = (-join ($hashBytes | ForEach-Object { $_.ToString('x2') })).Substring(0, 12)
           Head        = (git -C $ProductRoot rev-parse HEAD).Trim()
       }
   }

   $preProbeState = Get-GoalProbeProductState -ProductRoot $productRoot
   $preProbeState
   ```

   Record `$preProbeState.Fingerprint` as `pre-probe fingerprint` (mirrors
   the spike's own `git status --porcelain` → SHA-256:12 convention — a
   clean tree hashes to the well-known empty-string prefix `e3b0c44298fc`)
   and `$preProbeState.Head` as `pre-probe HEAD`. Keep `$preProbeState` and
   the function definition alive in the same shell session through step 5;
   if the session is lost, re-source this exact block rather than retyping
   a variant of it.

4. Run every leg's commands **with a working directory inside
   `$probeWorktree`**, never `$productRoot`.

5. After all legs conclude (including any halted/blocked leg), recompute
   both values by calling the **same step-3 function** — do not retype the
   hashing block, and do not substitute an ad-hoc `git status --porcelain |
   sha256` one-liner; a normalization difference alone would fire the
   tripwire below:

   ```powershell
   $postProbeState = Get-GoalProbeProductState -ProductRoot $productRoot
   if ($postProbeState.Fingerprint -ne $preProbeState.Fingerprint -or
       $postProbeState.Head -ne $preProbeState.Head) {
       "TRIPWIRE: pre=$($preProbeState.Fingerprint)@$($preProbeState.Head) " +
       "post=$($postProbeState.Fingerprint)@$($postProbeState.Head)"
   }
   else {
       "clean: $($postProbeState.Fingerprint)@$($postProbeState.Head)"
   }
   ```

   (If the shell session was lost between steps 3 and 5, re-source the
   step-3 function block verbatim before running this.) **Any change to
   either is a
   tamper tripwire** — the porcelain fingerprint alone is blind to a
   committed mutation (HEAD advances while the working tree stays clean),
   which is why both checks run together. Neither check detects a write to
   a gitignored path; that blindspot is not covered by this tripwire. The #871
   spike observed a scope-expanding executor treat a terse goal as
   "execute the whole issue" and start reading/mutating things well
   outside its intended scope; an unexpected fingerprint or HEAD delta
   here is the signal that happened again and must be investigated and
   recorded as a finding before proceeding to step 4, not silently
   ignored.

6. Tear down the probe worktree and branch once evidence is captured and
   redacted (`git worktree remove`, retrying/deferring on Windows file
   locks per the spike's own observation — this is a manual analog of
   874-D6's teardown rule, not that rule itself, since the harness doesn't
   exist yet).

**Reminder**: the entire probe worktree is disposable. Never `git add`
anything inside it. Leg-capture files (`leg-*.jsonl`, `leg-*.stderr.log`)
are covered by a root `.gitignore` backstop, but treat that as
defense-in-depth, not a reason to stage them.

## Per-leg protocol

Each entry: classification, exact command/observation, and the
`observed`-vs-else bar. Fixture goal text for legs (a)/(b)/(c)/(g) must
explicitly instruct the executor to close with the
`<goal-status>satisfied</goal-status>` / `<goal-status>impossible</goal-status>`
tag `goal-probe-streamjson.ps1` expects — this is a probe-stage convention
this run-book is asking for, not vendor-default behavior, per that
instrument's own header comment.

### Capture filenames: attempt-suffixed, and failed captures are kept

Every capturing leg below redirects stdout and stderr to files. **Never
redirect over a fixed filename.** Several bars in this run-book explicitly
tell the operator to "fix the invocation and re-run"; with a fixed name, each
retry destroys the previous attempt's capture — which is exactly what happened
in this probe's first pass (see
[`Documents/Design/goal-loop-capability-probe.md`](../../Documents/Design/goal-loop-capability-probe.md)
§ leg (a), "Artifact-retention caveat": three distinct failure modes were
observed but their captures were overwritten, so the resulting finding is
**not independently re-verifiable**).

Set an attempt suffix **before each invocation** and interpolate it into both
redirect targets:

```powershell
$attempt = Get-Date -Format 'yyyyMMdd-HHmmss'   # or a simple 1, 2, 3 counter
```

Then, per leg: `> leg-a-print-$attempt.jsonl 2> leg-a-print-$attempt.stderr.log`,
`> leg-c-$attempt.jsonl`, `> leg-d-$attempt.jsonl`, `> leg-h-$attempt.jsonl`,
and so on.

**Keep every failed capture.** A failed attempt is not waste — the failed
attempts *are* the evidence for the "three hard requirements" (`--verbose`
mandatory, `--model` pinned, credential exported) finding, and for
distinguishing "the invocation was rejected" from "the capability is blocked".
When recording a verdict, name the exact attempt file it came from.

### Matching serialized JSON: use a whitespace-tolerant pattern

Several checks below ask you to confirm a capture contains a particular event
type. Do **not** match the literal `'"type":"system"'`. The CLI emits
`{"type": "system", "subtype": "init", …}` with spaces on some builds, and a
literal match silently returns nothing — a false negative that routes an
otherwise-successful run into an "inconclusive" or "blocked" branch. Use the
tolerant pattern (or parse the line as JSON):

```powershell
$systemInitPattern = '"type"\s*:\s*"system"'
$resultEventPattern = '"type"\s*:\s*"result"'
```

This is the same rationale leg (b)'s parse-don't-string-match note gives.

### Leg (a) — headless launch

**Classification**: owner-executed at a keyboard.

**Command**: with the credential protocol above complete (or exhausted),
from `$probeWorktree`:

```powershell
$attempt = Get-Date -Format 'yyyyMMdd-HHmmss'
claude -p "<trivial fixture goal, instructing the <goal-status> tag>" `
  --output-format stream-json --print --verbose --model sonnet `
  > "leg-a-print-$attempt.jsonl" 2> "leg-a-print-$attempt.stderr.log"
"EXIT:$LASTEXITCODE"
$legACapture = "leg-a-print-$attempt.jsonl"
```

Both `--verbose` and `--model` are mandatory, not optional hedges: `--print`
combined with `--output-format stream-json` is rejected outright without
`--verbose`, and an unpinned run inherits the ambient session's model, which
can 404 for a headless credential (see leg (h) below, which pins both the
same way).

and, separately, attempt the untested candidate surface named in the design
(874-D9):

```powershell
claude agents --json <goal-carrying invocation per the CLI's own --help output>
```

(the exact invocation shape for `claude agents --json` was never tested by
the spike — resolve it live from `claude agents --help` at run time and
record the exact command used as evidence, since that shape is itself part
of what leg (a) answers).

**Bar**:

- `observed` — either invocation reaches a terminal `result` event (or
  documented equivalent for `claude agents --json`) with `is_error: false`,
  and the raw (redacted) output is retained as the backing artifact.
- `documented`-blocked — both invocations were **accepted by the CLI and
  reached the auth layer**, and both then failed *there* (e.g. 401), matching
  the spike's own finding; record the raw redacted error and exit code. This
  is a legitimate leg-(a) outcome, not a probe defect, and it forces the
  leg-a cascade on legs (b)/(c).

  **This bar requires positive evidence the invocation was accepted** — the
  same requirement leg (c)'s bar carries, and for a stronger reason: a
  `documented`-blocked verdict here cascades legs (b) *and* (c) as well, so a
  single mis-recorded leg (a) produces **three** false verdicts, one of them
  the finding arm-H enablement rests on. Positive evidence means at least one
  of:

  - `leg-a-print-$attempt.jsonl` is non-empty and contains a `system`/`init`
    event (match with `$systemInitPattern`, above — not a literal
    `'"type":"system"'`), **or**
  - `leg-a-print-$attempt.stderr.log` carries an *authentication* error — a
    401, an expired/rejected OAuth token, a credential-refused message — as
    opposed to a usage or argument error.

- **Not a leg-(a) outcome — fix and re-run.** A non-zero exit is *not*
  sufficient, because a flag rejection also exits non-zero. Specifically, do
  **not** record `documented`-blocked when any of these is what happened:

  - a **zero-byte capture**;
  - a stderr **usage/argument** error, e.g.
    `Error: When using --print, --output-format=stream-json requires --verbose`
    (this exact case occurred in this probe's real history —
    [`Documents/Design/goal-loop-capability-probe.md`](../../Documents/Design/goal-loop-capability-probe.md)
    § leg (a), discovery 1: exit 1, zero-byte capture);
  - a **model-resolution 404** from an unpinned or unavailable `--model`
    (discovery 2 in the same section).

  Each of these means the invocation never reached the auth layer. Fix the
  invocation, keep the failed capture as evidence, increment `$attempt`, and
  re-run. Only exhaust the leg — and only then cascade (b)/(c) — after an
  *accepted* invocation has failed at the auth layer.

### Leg (b) — terminal-outcome readability

**Classification**: scripted (`goal-probe-streamjson.ps1`), gated by leg
(a).

**Command**: if leg (a) produced a completing run, take the raw terminal
`result` line from **that attempt's** leg (a) capture (`$legACapture`, set by
leg (a)'s snippet — if you are in a new shell, set it to the specific
`leg-a-print-{attempt}.jsonl` file the completing run produced) and:

```powershell
. .github/scripts/lib/goal-probe-streamjson.ps1
$result = $null
$result = Get-Content $legACapture |
  ForEach-Object { Get-GoalProbeStreamJsonResult -Line $_ } |
  Where-Object { $null -ne $_ } |
  Select-Object -Last 1
$result
```

(parsing every line through `Get-GoalProbeStreamJsonResult` rather than
string-matching for `"type":"result"` first — a string match misses valid
JSON with different whitespace, e.g. `"type": "result"` with a space.
Non-matching lines parse to `$null`, and the `Where-Object { $null -ne $_ }`
filter drops them before the selection — `ForEach-Object` *emits* `$null`
into the pipeline rather than dropping it, so without that filter a capture
with anything after the terminal `result` event (a trailing blank line, any
stray post-result content) would hand `Select-Object -Last 1` a `$null` and
the assignment would silently fail, leaving `$result` holding a previous
leg's verdict. With the filter, the selection picks the last
successfully-parsed `result` event — the terminal one — regardless of what
trails it in the capture.)

**Bar**:

- `observed` — leg (a) completed, and the parsed object is non-`$null`
  with `TotalCostUsd` and `NumTurns` both populated (not `$null`) from a
  genuine live run's own emitted event — not a fixture line typed by hand.
- `blocked — leg-a cascade` — leg (a) never completed. Do not substitute a
  hand-crafted line; that would only re-exercise step 1's own Pester
  fixture, not answer this leg.

### Leg (c) — `--max-budget-usd` breach behavior

**Classification**: scripted (`goal-probe-streamjson.ps1` reused),
gated by leg (a) (needs the same completing-headless-run infrastructure).

**Command**:

```powershell
$attempt = Get-Date -Format 'yyyyMMdd-HHmmss'
claude -p "<fixture goal designed to exceed a tiny budget>" `
  --max-budget-usd 0.01 --output-format stream-json --print `
  --verbose --model sonnet `
  > "leg-c-$attempt.jsonl" 2> "leg-c-$attempt.stderr.log"
"EXIT:$LASTEXITCODE"
$legCCapture = "leg-c-$attempt.jsonl"
$legCStderr = "leg-c-$attempt.stderr.log"
```

`--verbose` and `--model` are mandatory here for the same reasons as legs (a)
and (h): without `--verbose`, `--print` + `--output-format stream-json` is
rejected outright, so the run never starts at all; and an unpinned model can
404 for a headless credential.

Then check leg (c)'s **own** capture — not leg (a)'s. Run the acceptance
checks the bar below requires, and parse for a terminal `result` event with
the same instrument leg (b) uses:

```powershell
. .github/scripts/lib/goal-probe-streamjson.ps1

# Acceptance evidence (bar path (ii) depends on these, not on the exit code).
(Get-Item $legCCapture).Length                                  # must be > 0
Get-Content $legCCapture | Select-String -Pattern $systemInitPattern | Select-Object -First 1
Get-Content $legCStderr                                         # must show no usage/argument error

# Terminal result event, if one exists (path (i)).
$legCResult = $null
$legCResult = Get-Content $legCCapture |
  ForEach-Object { Get-GoalProbeStreamJsonResult -Line $_ } |
  Where-Object { $null -ne $_ } |
  Select-Object -Last 1
$legCResult
```

The `$legCResult = $null` reset and the `Where-Object { $null -ne $_ }` filter
are both load-bearing for the same reason spelled out under leg (b): without
them a capture with no parsable `result` line leaves the variable holding an
earlier leg's verdict, and path (i) gets recorded from stale data.

**Bar**:

- `observed` — either (i) a terminal `result` event exists whose
  `subtype`/`is_error`/`result` text names the budget breach (report path),
  or (ii) the run demonstrably *started* and was then killed with no
  terminal `result` event (silent-kill path). Path (ii) requires **positive
  evidence that the invocation ran**, because a flag-rejection also exits
  non-zero with no `result` event and must never be recorded as an observed
  silent kill: `leg-c-{attempt}.jsonl` must be non-empty and contain session
  events (a `system`/`init` event matched with `$systemInitPattern`, and/or
  `assistant` events) with no terminal
  `result` event, **and** `leg-c-{attempt}.stderr.log` must show no CLI usage or
  argument error. A zero-byte capture, or a stderr usage error, means the
  invocation itself failed — fix the invocation, keep the failed capture,
  increment `$attempt`, and re-run; do not record it as a leg-(c) outcome. Both (i) and (ii) are genuine, recordable outcomes;
  the question this leg answers is *which* of the two happens, not whether a
  breach occurs.
- `blocked — leg-a cascade` — leg (a) never completed, so no headless
  invocation infrastructure exists to exercise the flag against.
- `documented` — if never exercised for any reason other than the cascade,
  fall back to the CLI's own `--max-budget-usd` help text ("Maximum dollar
  amount to spend on API calls") — already the spike's own grade for this
  claim.

### Leg (d) — goal registration in spawned sessions

**Classification**: owner-executed at a keyboard. Not gated by the leg-a
cascade (registration is visible in `system.init`, which the CLI emits
before any budget/auth-gated turn completes — the spike observed this
independent of full completion).

**Command**: from `$probeWorktree`, start a headless session and inspect
its first event, or start an interactive session and check the `/`
command list:

```powershell
$attempt = Get-Date -Format 'yyyyMMdd-HHmmss'
claude -p "<any trivial prompt>" --output-format stream-json --print --verbose `
  > "leg-d-$attempt.jsonl" 2> "leg-d-$attempt.stderr.log"
"EXIT:$LASTEXITCODE"
$legDCapture = "leg-d-$attempt.jsonl"

# Whitespace-tolerant match -- '"type":"system"' as a literal misses
# {"type": "system", ...} and would produce a false "no events at all".
$initLine = Get-Content $legDCapture |
  Select-String -Pattern $systemInitPattern |
  Select-Object -First 1
$initLine

# Inspect the matched init event's slash_commands array for 'goal'.
if ($null -ne $initLine) {
  $initEvent = $initLine.Line | ConvertFrom-Json
  $initEvent.slash_commands
  @($initEvent.slash_commands) -contains 'goal'
}
```

Writing the capture to a file (rather than piping straight to the console) is
required, not stylistic: it is what lets this leg satisfy the run-book's own
§ Platform version instruction to capture `claude_code_version` from the
`system/init` event **for every leg**, and it makes the verdict re-verifiable.

`--verbose` is mandatory here too: `--print` combined with `--output-format
stream-json` is rejected outright without it (see leg (a) above). `--model`
does not need to be pinned for this leg — goal registration is visible in
`system.init` even in an unpinned-model run.

**Bar** (the three branches below are exhaustive — every run lands in exactly
one):

- `observed` (registered) — a `system.init` event (or the interactive `/`
  command surface) is captured directly showing `goal` in `slash_commands`.
  Retain `leg-d-{attempt}.jsonl` as the backing artifact.
- `observed` (**not** registered) — the leg's own negative answer, and a
  genuine recordable outcome: a `system.init` event **was** captured and its
  `slash_commands` array is present and does **not** contain `goal`. Quote the
  array. This may never be recorded from a failed match alone — a missing
  match means "no init event was captured", which is the third branch, not
  this one. Re-check with `$systemInitPattern` before concluding absence.
- inconclusive — no `system.init` event in the capture at all: the process
  failed before emitting any event (distinct from a budget/auth failure on a
  later turn), or the capture is zero-byte. Record the raw failure and stderr.
  This is not the leg-a cascade, since leg (d)'s own question is answered or
  not answered before that gate is even reached.

### Leg (e) — supervisor-side force-halt

**Classification**: owner-executed at a keyboard for the live delivery;
`goal-probe-forcehalt-rig.ps1`'s `Test-GoalProbeForceHaltWin` is scripted
win/loss **detection** logic only (already Pester-tested in step 1) — it
does not deliver the halt itself.

**Polarity note — read before running (`documented`)**: on the `Stop` event,
`decision: "block"` **prevents Claude from stopping and continues the
conversation**, and exit code 2 does the same. Both are the *opposite* of a
force-halt. The only documented channel by which a hook can terminate is the
universal `continue` field: exit 0 with `{"continue": false, "stopReason":
"..."}` on stdout ("Claude stops processing entirely after the hook runs").
Under `/goal` the evaluator is itself a prompt-based Stop hook whose "keep
going" verdict becomes `decision: "block"` on the same event, so a supervisor
hook is racing a sibling blocker — and the vendor reference documents
cross-hook merge precedence for `PreToolUse` only, not for `Stop`. **Whether
`continue: false` beats the evaluator's concurrent block is exactly the
unanswered question this leg exists to ask.** All of this is `documented`
(vendor hooks reference), never `observed`; leg (e) has not been run.

**Containment note**: `Get-GoalProbeForceHaltSettingsFragment` does **not**
scope the hook via a `matcher` field — Claude Code's Stop event does not
support matchers at all (any value there is silently ignored). The only
real containment is that the fragment is registered in
`$probeWorktree/.claude/settings.json`: a hook registered there only ever
fires for sessions started inside that worktree. `Test-GoalProbeForceHaltWin`'s
own `ArmedProbeMarker`/`ProbeMarker` check is a separate, genuinely real
scope guard on the scripted-detector side (step 4 below).

**Command**:

1. Review and, if needed, customize
   `.github/scripts/goal-probe-forcehalt-hook.ps1` — a stub Stop hook that
   attempts an unconditional force-halt by exiting 0 and writing
   `{"continue":false,"stopReason":"..."}` to stdout. Verify it still matches
   your installed CLI's actual contract before relying on it (the stub's own
   header quotes the vendor wording it was built from and names the part the
   docs do not answer). Do not add anything else to the stub's stdout — the
   exit-0 + JSON channel requires stdout to contain only the JSON object.
   Register a worktree-local Stop
   hook in `$probeWorktree/.claude/settings.json` using the shape from
   `Get-GoalProbeForceHaltSettingsFragment -ArmedProbeMarker $token
   -StopHookCommand '<path to the stub or your customized copy>'`
   — never the plugin `hooks/hooks.json`.
2. Start an interactive goal loop in `$probeWorktree` against a condition
   that would keep continuing (a non-yet-satisfied predicate).
3. At a turn where the goal evaluator's own concurrent continuation
   decision is independently recorded (owner observes and notes it — e.g.
   from the visible turn/budget render or an explicit disambiguating
   prompt — at the same turn the Stop hook fires), let the registered Stop
   hook fire its `continue: false` force-halt attempt.
4. Feed the observed session end into the rig. **Every field below is a
   placeholder you fill from evidence — none of them may be typed in as a
   literal.** `Test-GoalProbeForceHaltWin` returns `stop-hook-win` only when
   `EndReason -eq 'stop-hook'` **and** `StopHookDecision -eq 'continue-false'`
   **and** `GoalEvaluatorContinuationDecision -eq 'continue'`. Pre-filling the
   first two would pre-answer two-thirds of the exact question this leg exists
   to ask, and the polarity note above records that the stub's contract is
   `documented` only — so "the loop ended some other way" and "the hook fired
   but the loop kept running anyway" are both live possibilities:

   ```powershell
   . .github/scripts/lib/goal-probe-forcehalt-rig.ps1
   Test-GoalProbeForceHaltWin -ArmedProbeMarker $token -SessionEndDescription @{
     ProbeMarker                        = $token
     EndReason                          = '<stop-hook|natural-completion|wall-clock-cutoff|budget-cutoff|external-kill, per the end evidence in step 4a>'
     StopHookDecision                   = '<continue-false|block|allow, per the hook-fired evidence in step 4a -- omit if EndReason is not stop-hook>'
     GoalEvaluatorContinuationDecision  = '<continue|halt, as independently recorded in step 3>'
   }
   ```

   `StopHookDecision` records **what channel the hook actually used**, not
   whether you wanted it to work:

   - `continue-false` — the hook exited 0 with `{"continue":false,…}` on
     stdout. The only channel that can terminate.
   - `block` — the hook emitted `decision:"block"` or exited 2. On `Stop` this
     *prevents* stopping, so it cannot have ended the loop; the rig returns
     `block-does-not-halt`, never a win. If you customized the stub back onto
     this channel, you have disarmed the leg.
   - `allow` — the hook fired but expressed no decision.

   **4a. Evidence required before filling `EndReason` and `StopHookDecision`.**
   Record at least one positive item for each, and cite it in the write-up:

   - *The hook actually fired*: the stub's own stdout/exit code
     (`{"continue":false,…}` on stdout, exit 0 — see
     `.github/scripts/goal-probe-forcehalt-hook.ps1`). Hook stdout is consumed
     by the CLI, so add a one-line **append-to-file** trace to **your
     customized copy** of the stub before step 2 — e.g. a timestamped line to
     `$probeWorktree/leg-e-hook-fired.log` — and treat the presence and
     timestamp of that line as the fired-evidence. Do not write the trace to
     stdout: the exit-0 + JSON channel requires stdout to contain only the
     JSON object. No trace line and no user-visible `stopReason` means you
     cannot assert `EndReason = 'stop-hook'`.
   - *The force-halt was honored*: the session actually **ended** at that turn
     with the stub's `stopReason` surfaced to the user, while the goal was
     still active and unsatisfied. If the turn ended and a *new* turn began,
     the halt was not honored — that is a `loss` (or, if you had emitted a
     block, `block-does-not-halt`), and a real result.
   - *How the session actually ended*: the session transcript's terminal
     record under `~/.claude/projects/{project-slug}/{session-id}.jsonl`. If it
     shows natural completion, a budget cutoff, or an external kill, set
     `EndReason` to that value — do not force `'stop-hook'` because the hook
     was registered.

   If the fired/honored evidence cannot be obtained at all, record the leg as
   inconclusive rather than typing in the literals; a `stop-hook-win` produced
   from typed-in inputs is not an observation of anything.

**Bar**:

- `observed` (win) — `Outcome -eq 'stop-hook-win'` **from evidence-filled
  inputs**: positive evidence the hook fired on the `continue-false` channel
  (step 4a), positive evidence the loop actually terminated at that turn
  (step 4a), **and** the evaluator's own `continue` decision at that turn
  independently recorded — none of the three reconstructed after the fact
  from the others.
- `observed` (loss / block-does-not-halt / concurrent-halt-not-a-win) — also
  genuine, recordable outcomes; do not discard a non-win as a probe failure.
  A well-evidenced `loss` here would be a **material finding**: it would
  settle the wall-clock-arm enforceability question in the negative for the
  interactive arm.
- `inferred` — if the evaluator's independent decision could not be
  directly observed at the same turn (only the termination was visible),
  downgrade to `inferred`: the rig's own inputs became an assumption, not
  an observation.
- If `GoalEvaluatorContinuationDecision` is left blank/omitted (the
  evaluator's decision genuinely was never observed), the rig reports
  `Outcome -eq 'evaluator-decision-indeterminate'` rather than fabricating
  a `concurrent-halt-not-a-win` verdict — record this distinctly from a
  genuine loss.

### Leg (f) — transcript usage-reader

**Classification**: scripted (`goal-probe-usage-reader.ps1`), but it
requires a session an owner keeps running concurrently — the reader itself
does not launch anything. Poll while an owner-started session (any arm,
interactive or headless) from leg (a)/(d)/(g) is confirmed still active,
before it terminates.

**Command**:

> ⚠ **"Confirmed still running" is the whole leg — it must be *measured*, not
> assumed.** A finished transcript satisfies a bare
> `Get-GoalProbeLiveUsageReading` call exactly as well as a live one, so
> pointing the reader at a path proves nothing about liveness. This leg
> already drifted this way once: what actually got measured were **completed
> stream-json output captures, not live mid-write session transcripts**, so
> leg (f)'s real question was recorded as **not answered** — see
> [`Documents/Design/goal-loop-capability-probe.md`](../../Documents/Design/goal-loop-capability-probe.md)
> § leg (f), "Partial gap". Every poll must carry its own recorded liveness
> evidence.

Run this loop **against a session an owner has just started and is watching**,
in a second shell:

```powershell
. .github/scripts/lib/goal-probe-usage-reader.ps1
$transcriptPath = "<the running session's own JSONL transcript path under ~/.claude/projects/...>"
$terminalEventPattern = '"type"\s*:\s*"result"'
$polls = [System.Collections.Generic.List[object]]::new()
$previousWrite = $null

for ($i = 1; $i -le 40; $i++) {
    $item = Get-Item -LiteralPath $transcriptPath -ErrorAction SilentlyContinue
    $lastWrite = if ($null -ne $item) { $item.LastWriteTimeUtc } else { $null }
    $claudeAlive = @(Get-Process -Name 'claude' -ErrorAction SilentlyContinue).Count -gt 0
    $hasTerminalEvent = $false
    if ($null -ne $item) {
        $hasTerminalEvent = [bool](
            Get-Content -LiteralPath $transcriptPath -ErrorAction SilentlyContinue |
            Select-String -Pattern $terminalEventPattern -Quiet
        )
    }
    $reading = Get-GoalProbeLiveUsageReading -TranscriptPath $transcriptPath

    $polls.Add([pscustomobject]@{
        Poll                = $i
        AtUtc               = [datetime]::UtcNow
        LastWriteUtc        = $lastWrite
        WriteAdvanced       = ($null -ne $previousWrite -and $null -ne $lastWrite -and $lastWrite -gt $previousWrite)
        ClaudeProcessAlive  = $claudeAlive
        TerminalEventSeen   = $hasTerminalEvent
        State               = $reading.State
        ReadLatencyMs       = $reading.ReadLatencyMs
        PartialTailDetected = $reading.PartialTailDetected
    })

    $previousWrite = $lastWrite
    if ($hasTerminalEvent -and -not $claudeAlive) { break }
    Start-Sleep -Seconds 3
}

$polls | Format-Table -AutoSize
```

Notes on the loop: `Get-Item`/`Get-Process`/`Get-Content` all use
`-ErrorAction SilentlyContinue` with an explicit `$null` check so a
transcript that does not exist yet leaves `$lastWrite` as `$null` instead of
throwing or leaking a stale value; `$previousWrite` is reassigned on **every**
iteration, so `WriteAdvanced` is always a comparison against the immediately
preceding poll; and `Get-Process` is wrapped in `@(...)` so a zero- or
one-match result both count correctly.

Record the whole `$polls` table. A single poll's `State`/`ReadLatencyMs`
without its liveness columns is not usable evidence.

**Bar**:

- A poll counts as **taken while the session was live** only if that poll's
  own row shows at least one of: `WriteAdvanced -eq $true` (the transcript's
  `LastWriteTime` advanced since the previous poll), `TerminalEventSeen -eq
  $false` (no terminal event in the transcript at poll time), or
  `ClaudeProcessAlive -eq $true`. Prefer `WriteAdvanced` — it is the only one
  of the three that positively demonstrates the file was still being written.
  State in the write-up **which** column established liveness for the poll you
  cite.
- `observed` — at least one such live-qualified poll returns
  `usage-present-nonzero` (or a `usage-present-zero`
  independently corroborated by knowing the run had genuinely made no
  progress yet), with `ReadLatencyMs` captured.
- `usage-unavailable` on a live-qualified poll is also a
  genuine `observed` negative result — **unless** a poll taken immediately
  after the same session's termination then returns nonzero usage from the
  same transcript path, which would instead indicate the *reader*, not the
  observable, is broken; record that distinction explicitly if it occurs.
- **Not `observed`** — every poll ran with `WriteAdvanced -eq $false` and
  `TerminalEventSeen -eq $true`, or the path pointed at a completed capture.
  That measures post-hoc file reads, not live polling; record it as such and
  fall back to the `documented` grade below rather than reporting it as a
  live-poll result.
- `documented` — if no session could be kept running long enough to poll
  at all, fall back to the stream-json schema's documented `usage` field
  shape (the spike's own grade for this claim).

### Leg (g) — clean release

**Classification**: owner-executed at a keyboard.

**Command**: start an interactive goal loop against a fixture predicate
that is **genuinely, truthfully satisfiable** (not the spike's falsifier —
a real script that actually exits 0 once a real condition is met). Perform
the action that makes the condition true, and directly watch what happens
next, recording:

- the turn count at which the sentinel/condition actually flipped true,
- the turn count at which the loop visibly terminated (or the turn after
  which no further continuation occurred),
- whether the session surfaces any visible status line at
  termination, or the input placeholder simply reverts with no completion
  render (the spike's own "not determined" finding on exactly this point).

**Bar**:

- `observed` — the owner directly watches the turn-by-turn transition and
  captures all three records above from a live run, not reconstructed
  after the fact.
- Explicit gap — if the loop does not cleanly release within a reasonable
  bound, or the three records cannot be captured live, record this as an
  explicit gap (per the #871 "probes not completed" discipline) rather
  than omitting it or guessing at what would have happened.

### Leg (h) — headless goal-loop start

**Added after the original seven.** Reviewing legs (a)–(g) exposed an unexamined
assumption: every headless leg used a **plain prompt**, so nothing had ever
tested whether a *goal loop* can start headlessly. Without this leg, "arm-H
enabling" silently over-claims.

**Classification**: scripted, but owner-executed (it invokes the CLI).

**Command** — reuse leg (g)'s **exact goal text** so the surfaces are directly
comparable, and run from a throwaway directory outside the product checkout:

```powershell
$attempt = Get-Date -Format 'yyyyMMdd-HHmmss'
claude -p "/goal <verbatim leg (g) goal text>" --output-format stream-json --print `
  --verbose --model sonnet --max-budget-usd 0.50 `
  > "leg-h-$attempt.jsonl" 2> "leg-h-$attempt.stderr.log"
"EXIT:$LASTEXITCODE"
```

**The `--max-budget-usd` belt is mandatory on this leg, not optional.** An agent
that cannot satisfy its goal will iterate until something stops it; without a cap
that "something" may be the account's weekly ceiling. Set it well above one
turn's cost (see the overshoot characterisation) but low enough that a total loss
is acceptable.

**Detection — read this before recording anything**:

> ⚠ **`goal_status` is transcript-only. It is NEVER mirrored to the
> `--output-format stream-json` stdout stream, on either surface.** Its absence
> from a stdout capture is therefore *evidence of nothing*. This is not
> hypothetical: the first pass at this leg searched only the stdout capture,
> concluded `/goal` does not work headlessly, and was wrong — an error that
> propagated into roughly a dozen downstream conclusions before an independent
> audit caught it.

Search the session transcript under
`~/.claude/projects/{project-slug}/{session-id}.jsonl` for `goal_status`,
`<command-name>`, and `Goal set:`. Search the stdout capture too, but only to
confirm the (expected) absence.

**Bar**:

- `observed` (loop started) — one or more `goal_status` events in the **session
  transcript**, and/or `<command-name>/goal</command-name>` plus a
  `Goal set: …` local-command-stdout entry.
- `observed` (loop did **not** start) — recordable **only** on positive
  transcript evidence: the transcript exists, was searched, and contains no
  `goal_status` and no `/goal` command parse. A negative may never be recorded
  from a stdout capture alone.
- If the session transcript cannot be located, record **inconclusive**, not a
  negative.
- Record `permission_denials`, `num_turns`, `total_cost_usd`, and
  `terminal_reason` regardless of outcome — a headless run's permission posture
  and burn rate are load-bearing evidence in their own right.

## Platform version

At the start of **each** run, record `claude --version`. Do **not** capture it
once and attribute every leg to that build: this probe's legs ran on three
different builds (CLI 2.1.150, desktop app 2.1.215, CLI 2.1.216), the app and CLI
version independently, and an earlier draft of the evidence document had to be
corrected for attributing all findings to a single build.

**Prefer in-artifact build capture for every leg**, not just interactive ones:

- App / interactive legs: `version` on every session-transcript event.
- Headless CLI legs: `claude_code_version` inside the `system/init` event of the
  stdout capture (`2.1.150` in legs a/c, `2.1.216` in leg h).

Both cannot drift from the run they describe, unlike a separately-typed
`claude --version` that may be recorded before or after the run.

Real drift was observed across this probe's own run window (`terminal_reason`
population, `--model sonnet` resolution, `usage` truthfulness on the breach path,
and a new event type), so per-run build capture is a correctness requirement, not
bookkeeping.
