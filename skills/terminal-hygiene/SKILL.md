---
name: terminal-hygiene
description: "Terminal and test execution guardrails for Agent Orchestra workflows. Use when choosing sync versus async terminal mode, scoping Pester runs, retrying background commands, detecting or recovering from multiline-prompt continuation stalls, wrapping subagent diagnostics to avoid non-zero-exit halts, or avoiding terminal and subagent batching mistakes. DO NOT USE FOR: application-level debugging root-cause analysis (use systematic-debugging) or post-merge archival workflow steps (use post-pr-review)."
---

# Terminal Hygiene

Terminal and validation rules that keep workflow execution predictable.

## When to Use

- When choosing targeted versus full-suite Pester runs
- When deciding between `mode: sync` and `mode: async` / `isBackground: true`
- When validating at step boundaries without overflowing terminal state
- When retrying background terminal commands safely

## Scope

These rules supplement, not replace, any agent-specific terminal guidance such as Code-Conductor's non-interactive guardrails.

## Pester Scope

When iterating on a specific test during red-green-refactor within an implementation step, use targeted Pester:

```powershell
Invoke-Pester 'path/to/specific.Tests.ps1' -Output Minimal
```

The full-suite runner is `.github/scripts/run-pester-sharded.ps1` (authored in issue #740 s4); invoke it at step boundaries as the standard validation gate. Do not run the full suite during inner-loop iteration. Note: CI's `pester.yml` runs an ~18-file Ubuntu allowlist; this divergence from the full local suite is intentional.

## `isBackground` Default

Use `isBackground: false` for Pester, PSScriptAnalyzer, `markdownlint-cli2`, structural checks, and any command expected to complete in under 60 seconds. Reserve `isBackground: true` for dev servers and watch-mode builds.

Exceptions:

- When diagnosing a terminal stall, the `process-troubleshooting` skill guidance to switch to `isBackground: true` for diagnostics takes precedence.
- Final-gate full suite in live-refresh mode (`PESTER_LIVE_GH=1`): treat as long-running, run with `isBackground: true`, and poll with `get_terminal_output`. In fixture mode, keep `isBackground: false`.

Pester 5 writes pass/fail output to the terminal buffer rather than redirected file streams, so `*>` only captures advisory output such as `Write-Warning`. Do not use `await_terminal` for the live-refresh full-suite case; the PowerShell prompt returning on the last line signals completion.

## No Terminal/Subagent Batching

Do not batch `run_in_terminal` and subagent dispatch calls in the same parallel tool-call set. Sequential use is fine. Parallel subagent dispatch remains allowed when no terminal command shares that batch.

## Terminal Cleanup

Code-Conductor manages background terminal lifecycle with its Terminal Lifecycle Protocol. At phase boundaries such as post-step, post-implementation, and post-PR, it sweeps tracked `isBackground: true` terminal IDs, kills confirmed-completed terminals, and preserves active or unknown-state ones. Cleanup is always non-fatal.

Root cause context:

- Agent Orchestra sessions generate high terminal command volume, especially around repeated structural checks.
- When the shared terminal buffer overflows at roughly 16 KB, commands appear to stall and later commands often shift to new background terminals.
- At roughly 30 or more idle terminals, shells can enter CPU-spin states.
- The consolidated `quick-validate.ps1` reduces per-pass command count and lowers overflow risk.

Logging contract:

```text
Terminal cleanup: killed N completed, preserved M active, K unknown/already-gone
```

Subagent gap: subagent-spawned background terminals are not tracked by Code-Conductor. Subagents should follow the `isBackground: false` preference unless a documented exception applies.

## Terminal Retry Hygiene

When retrying a failed command that ran in a background terminal (`isBackground: true` or `mode: async`), use this kill-before-retry protocol:

1. Record the terminal ID returned by `run_in_terminal`.
2. Kill that terminal via `kill_terminal` using the same terminal ID, loading the tool first with `tool_search_tool_regex` if needed.
3. If `kill_terminal` fails, log it and proceed. This is non-fatal.
4. For dev servers, run `pwsh -NoProfile -NonInteractive -File skills/terminal-hygiene/scripts/check-port.ps1 -Port {PORT}` before restart to verify the port was released. If the port is still in use, log the diagnostic and proceed.
5. Start the retry in a fresh terminal.

Scope notes:

- This protocol applies to within-step retries for terminals with trackable background IDs.
- Phase-boundary cleanup of accumulated terminals remains governed by Terminal Cleanup.
- Kill-before-retry and Terminal Cleanup are complementary, not substitutes. If both target the same terminal ID, the first successful kill wins and later attempts are harmless no-ops.
- Both `kill_terminal` failures and `check-port.ps1` errors are non-blocking. Degrade gracefully to retry-without-kill when necessary.

## Scratch & Temp-File Hygiene

**Single source of truth** for where agents write scratch/output files. All other skills cross-reference this section; do NOT duplicate the rule.

### Rule: use repo-relative `.tmp/` — never host-native absolute paths

When a Bash-tool shell command writes a scratch or output file:

- **DO**: write to a relative `.tmp/` path, e.g. `.tmp/issue-643-body.md`, `.tmp/643-comments.json`
- **DO NOT**: construct a Windows-style absolute path (`C:\Users\...\Temp\...`) or pass it to a POSIX/git-bash shell — the drive letter and backslashes do not translate and the path collapses to a repo-root filename

If a Windows-native tool requires an absolute path (e.g. a screenshot tool that cannot accept a relative save target):

- Use forward-slash git-bash form: `/c/Users/.../Temp/...`
- Or use the PowerShell tool with `$env:TEMP` — never `C:\...` inside a bash redirect

**Consumer snippet** — add these lines to your repo `.gitignore` to keep `.tmp/` and collapsed-mangle-literal shapes out of `git status`:

```gitignore
# Agent scratch — keep out of git status
.tmp/
/[A-Za-z][A-Za-z]sers*
/[A-Za-z]:*
# /*[Tt]emp* intentionally omitted: over-matched template.md, templates/, attempt.js.
# Primary mangle shapes are covered by /[A-Za-z]:* and /[A-Za-z][A-Za-z]sers* above.
/var*folders*
/[Rr][Uu][Nn][Nn][Ee][Rr]*[Tt][Ee][Mm][Pp]*
```

These patterns cover the Windows default-temp mangle (`UsersXAppDataLocalTempfoo.png`) and a root-anchored set of other shapes. They are best-effort — the author-time grep guard (see `skills/terminal-hygiene/SKILL.md` `## Scratch & Temp-File Hygiene`) is the authoritative prevention, not the gitignore net.

## Multiline Continuation-Prompt Hazard

PowerShell enters a continuation prompt (`>>`) and bash enters a `>` prompt when a command is syntactically incomplete: unclosed here-strings (`@'`/`@"`), parentheses, braces, or backtick line continuations in PowerShell; unclosed heredocs, quotes, or backslash continuations in bash.

**Symptom**: the terminal appears to hang — no output, no PS prompt. The buffer tail shows `>>` or `>` rather than a prompt.

**Agent-side detection**: if the prior command contained an unclosed multiline construct (a here-string, unclosed parenthesis, or continuation backslash) and the terminal returns no new output, presume a continuation prompt rather than a frozen process. When the terminal buffer is inspectable, a trailing `>>` or `>` line with no surrounding command output confirms this.

**Recovery**: do not attempt `^C` — from the agent side, sending literal `"^C"` adds more input to the here-string rather than interrupting the shell. Use `kill_terminal` on the stalled terminal ID, then open a fresh terminal. This extends the existing kill-before-retry pattern from `## Terminal Retry Hygiene`.

**Prevention**: prefer one-line commands. When a multiline construct is genuinely required, write it to a temporary `.ps1` or `.sh` file and invoke the file, rather than passing the block inline to the terminal. Those temporary `.ps1` and `.sh` files must themselves land under `.tmp/` per `## Scratch & Temp-File Hygiene` above.

## Non-Fatal Diagnostic Wrapper Pattern

When a subagent needs to run a diagnostic check (linting, structural validation, schema inspection) without risking an orchestration halt on a non-zero exit code, the wrapper script should emit a structured status line as its final stdout output and always exit 0.

**Shape**:

- Readable line: `VALIDATION_STATUS=pass` or `VALIDATION_STATUS=fail` as any line in stdout; emit it last for unambiguous parsing
- Optional preceding lines: evidence such as diff output, line counts, or error messages
- Exit code: always `exit 0` so the orchestrator continues regardless of findings

**Worked examples**:

PowerShell:

```powershell
if ($findings.Count -eq 0) {
    Write-Output 'VALIDATION_STATUS=pass'
} else {
    $findings | ForEach-Object { Write-Output $_ }
    Write-Output 'VALIDATION_STATUS=fail'
}
exit 0
```

Bash:

```bash
if [ "$finding_count" -eq 0 ]; then
  echo 'VALIDATION_STATUS=pass'
else
  echo "$error_details"
  echo 'VALIDATION_STATUS=fail'
fi
exit 0
```

**Scope**: this pattern applies to diagnostic wrappers only. Real validation gates (Pester, PSScriptAnalyzer, markdownlint) retain their non-zero exits — do not apply `exit 0` to gates that must halt on failure. Criterion: if the orchestrator should stop when this tool reports failure, it is a gate; if it should continue and log findings, it is a diagnostic.

**Residual non-zero sources**: existing third-party tools (e.g., `grep -q`) exit non-zero on no-match by design. Wrap calls to such tools explicitly if their exit codes would be misread as failures.

**Consumer**: the `VALIDATION_STATUS` token is readable by the operator in the terminal buffer and future-greppable as `^VALIDATION_STATUS=` in stdout. No automated consumer exists today — the value is operator-facing structured evidence at a glance.

## Gotchas

| Trigger                                               | Gotcha                                                                          | Fix                                                                            |
| ----------------------------------------------------- | ------------------------------------------------------------------------------- | ------------------------------------------------------------------------------ |
| Running full Pester repeatedly during inner-loop work | Large, repetitive output increases terminal buffer pressure and slows iteration | Use targeted Pester until the step boundary, then run the full validation gate |

| Trigger                                                         | Gotcha                                                             | Fix                                                                                                |
| --------------------------------------------------------------- | ------------------------------------------------------------------ | -------------------------------------------------------------------------------------------------- |
| Retrying a failed async server without killing the old terminal | The old shell or port can stay alive and make the retry look flaky | Kill the prior terminal ID first, check the port for dev servers, then restart in a fresh terminal |

| Trigger                                                          | Gotcha                                                                                        | Fix                                                                                                            |
| ---------------------------------------------------------------- | --------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------- |
| Terminal sits silently after a multiline command                | The shell entered a continuation prompt (`>>` or `>`); the terminal is not frozen             | Intervene immediately — the shell waits indefinitely; use `kill_terminal` and open a fresh terminal — do not send `^C` |

| Trigger                                                          | Gotcha                                                                                        | Fix                                                                                                            |
| ---------------------------------------------------------------- | --------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------- |
| Subagent diagnostic check causes orchestration to halt unexpectedly | The diagnostic script exited non-zero and the orchestrator treated it as a blocking failure | Wrap the diagnostic in the Non-Fatal Diagnostic Wrapper Pattern: emit `VALIDATION_STATUS=pass/fail`, exit 0    |
