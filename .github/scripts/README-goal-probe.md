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
once, interactively, in a real TTY (it cannot run non-interactively — the
spike already confirmed this: "produced no output under a non-interactive
timeout"). This step has never completed in this repo's tooling before, so
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
   leg runs. The porcelain output must be joined into a single string
   before it is converted to bytes and hashed — piping a byte array through
   the pipeline auto-enumerates it element-by-element, which silently
   breaks `ComputeHash` (it ends up hashing one byte at a time instead of
   the whole buffer). This mirrors the working, tested convention in
   `skills/subagent-env-handshake/scripts/New-SubagentDispatchPrompt.ps1`
   (`Get-DirtyTreeFingerprint`):

   ```powershell
   $porcelainRaw = (git -C $productRoot status --porcelain 2>$null) | Out-String
   $porcelainNormalized = ($porcelainRaw -replace "`r`n", "`n") -replace "`r", "`n"
   $porcelainBytes = [System.Text.Encoding]::UTF8.GetBytes($porcelainNormalized)
   $sha256 = [System.Security.Cryptography.SHA256]::Create()
   $hashBytes = $sha256.ComputeHash($porcelainBytes)
   $preProbeFingerprint = (-join ($hashBytes | ForEach-Object { $_.ToString('x2') })).Substring(0, 12)
   $preProbeHead = (git -C $productRoot rev-parse HEAD).Trim()
   ```

   Record `$preProbeFingerprint` as `pre-probe fingerprint` (mirrors the
   spike's own `git status --porcelain` → SHA-256:12 convention — a clean
   tree hashes to the well-known empty-string prefix `e3b0c44298fc`) and
   `$preProbeHead` as `pre-probe HEAD`.

4. Run every leg's commands **with a working directory inside
   `$probeWorktree`**, never `$productRoot`.

5. After all legs conclude (including any halted/blocked leg), recompute
   both the fingerprint and `git -C $productRoot rev-parse HEAD` and
   compare each against its pre-probe value. **Any change to either is a
   tamper tripwire** — the porcelain fingerprint alone is blind to a
   committed mutation (HEAD advances while the working tree stays clean)
   or a write to a gitignored path, so both checks run together. The #871
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

### Leg (a) — headless launch

**Classification**: owner-executed at a keyboard.

**Command**: with the credential protocol above complete (or exhausted),
from `$probeWorktree`:

```powershell
claude -p "<trivial fixture goal, instructing the <goal-status> tag>" `
  --output-format stream-json --print > leg-a-print.jsonl 2> leg-a-print.stderr.log
"EXIT:$LASTEXITCODE"
```

If the CLI rejects this combination, add `--verbose` and re-run — some
headless builds require `--verbose` alongside `--output-format stream-json`.

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
- `documented`-blocked — both invocations fail (e.g. 401), matching the
  spike's own finding; record the raw redacted error and exit code. This is
  a legitimate leg-(a) outcome, not a probe defect, and it forces the
  leg-a cascade on legs (b)/(c).

### Leg (b) — terminal-outcome readability

**Classification**: scripted (`goal-probe-streamjson.ps1`), gated by leg
(a).

**Command**: if leg (a) produced a completing run, take the raw terminal
`result` line from `leg-a-print.jsonl` and:

```powershell
. .github/scripts/lib/goal-probe-streamjson.ps1
$resultLine = (Get-Content leg-a-print.jsonl | Select-String '"type":"result"' | Select-Object -Last 1).Line
Get-GoalProbeStreamJsonResult -Line $resultLine
```

(scanning backward for the last line matching `"type":"result"` rather than
blindly taking the file's last line — a trailing blank line or any output
that follows the terminal result event would otherwise make
`Select-Object -Last 1` pick the wrong line.)

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
claude -p "<fixture goal designed to exceed a tiny budget>" `
  --max-budget-usd 0.01 --output-format stream-json --print > leg-c.jsonl 2> leg-c.stderr.log
"EXIT:$LASTEXITCODE"
```

then parse the same way as leg (b) if a terminal `result` line exists.

**Bar**:

- `observed` — either (i) a terminal `result` event exists whose
  `subtype`/`is_error`/`result` text names the budget breach (report path),
  or (ii) the process exits non-zero with **no** `result` event at all
  (silent-kill path) — both are genuine, recordable outcomes; the question
  this leg answers is *which* of the two happens, not whether a breach
  occurs.
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
claude -p "<any trivial prompt>" --output-format stream-json --print |
  Select-String -Pattern '"type":"system"' | Select-Object -First 1
```

If the CLI rejects this combination, add `--verbose` and re-run.

Inspect the matched line's `slash_commands` array for `goal`.

**Bar**:

- `observed` — a `system.init` event (or the interactive `/` command
  surface) is captured directly showing `goal` registered.
- If the process fails before emitting any event at all (distinct from a
  budget/auth failure on a later turn), record as inconclusive with the
  raw failure captured — this is not the leg-a cascade, since leg (d)'s own
  question is answered or not answered before that gate is even reached.

### Leg (e) — supervisor-side force-halt

**Classification**: owner-executed at a keyboard for the live delivery;
`goal-probe-forcehalt-rig.ps1`'s `Test-GoalProbeForceHaltWin` is scripted
win/loss **detection** logic only (already Pester-tested in step 1) — it
does not deliver the halt itself.

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
   delivers an unconditional block decision. Verify it still matches your
   installed CLI's actual block-decision contract before relying on it
   (the stub's own header documents its best-effort, unverified-live
   confidence level and what to check). Register a worktree-local Stop
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
   hook fire its block decision.
4. Feed the observed session end into the rig:

   ```powershell
   . .github/scripts/lib/goal-probe-forcehalt-rig.ps1
   Test-GoalProbeForceHaltWin -ArmedProbeMarker $token -SessionEndDescription @{
     ProbeMarker                        = $token
     EndReason                          = 'stop-hook'
     StopHookDecision                   = 'block'
     GoalEvaluatorContinuationDecision  = '<continue|halt, as independently recorded in step 3>'
   }
   ```

**Bar**:

- `observed` (win) — `Outcome -eq 'stop-hook-win'`, **and** the evaluator's
  own `continue` decision at that turn was independently recorded (not
  reconstructed after the fact from the block alone).
- `observed` (loss / concurrent-halt-not-a-win) — also a genuine,
  recordable outcome; do not discard a non-win as a probe failure.
- `inferred` — if the evaluator's independent decision could not be
  directly observed at the same turn (only the hook's block was visible),
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

```powershell
. .github/scripts/lib/goal-probe-usage-reader.ps1
$transcriptPath = "<the running session's own JSONL transcript path under ~/.claude/projects/...>"
Get-GoalProbeLiveUsageReading -TranscriptPath $transcriptPath
```

Poll repeatedly (e.g. every few seconds) while the session is confirmed
not yet terminated, recording `State`, `ReadLatencyMs`, and
`PartialTailDetected` each time.

**Bar**:

- `observed` — at least one poll taken while the session is confirmed
  still running returns `usage-present-nonzero` (or a `usage-present-zero`
  independently corroborated by knowing the run had genuinely made no
  progress yet), with `ReadLatencyMs` captured.
- `usage-unavailable` while the session is confirmed running is also a
  genuine `observed` negative result — **unless** a poll taken immediately
  after the same session's termination then returns nonzero usage from the
  same transcript path, which would instead indicate the *reader*, not the
  observable, is broken; record that distinction explicitly if it occurs.
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
claude -p "/goal <verbatim leg (g) goal text>" --output-format stream-json --print `
  --verbose --model sonnet --max-budget-usd 0.50 > leg-h.jsonl 2> leg-h.stderr.log
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
