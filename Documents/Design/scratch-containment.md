# Scratch Containment

Prevents agent scratch files from dirtying the tracked working tree. Implemented in #643.

## Problem

Agent Orchestra agents on Windows/POSIX sometimes wrote scratch to host-native absolute paths (`C:\Users\...\Temp\...`) from a git-bash shell context. git-bash treats `C:\...` as a relative filename, collapsing it to a repo-root literal (`UsersMicahAppDataLocalTempfoo.png`). Additionally, `.tmp/` scratch was unignored and had already been committed accidentally. Both symptoms made the developer's tracked tree contain agent junk.

## Solution

Three-layer defense in depth:

**Prevention** — canonical rule in `skills/terminal-hygiene/SKILL.md` § Scratch & Temp-File Hygiene: write scratch to relative `.tmp/`, never construct host-native absolute paths in a POSIX shell. Single source of truth; all other skills cross-reference.

**Structural containment** — `.gitignore` net: `.tmp/` plus a root-anchored mangle-literal set covering Windows default-temp, Downloads, macOS `/var/folders`, and CI `RUNNER_TEMP` shapes. Applied write-time; a slipped file lands ignored instantly. Honest scope: best-effort for exotic shapes; the grep guard (s5 of the plan) is the authoritative author-time prevention. An author-time Pester guard in `script-safety-contract.Tests.ps1` fails CI if a shipped script constructs a `[A-Za-z]:\\[A-Z]...` literal.

**Post-merge disk clearing** — `Remove-IssueTmpScratch` in `post-merge-cleanup.ps1`: deletes an issue's `.tmp/{N}-*` and `.tmp/issue-{N}*` files at merge time, ordered after orphan-branch cleanup by convention (log-readability, not a data dependency — the auto-resolve predicate reads git history only).

**Consumer zero-config** — `Ensure-ScratchGitignore.ps1` called from `session-cleanup-detector.ps1` at SessionStart: idempotently appends `.tmp/` and the mangle-literal net to the consumer repo's `.gitignore` if absent. Fail-open (always exits 0).

## Key decisions (from #643)

| Decision | Choice | Why |
|---|---|---|
| `scratch-location` | Repo-relative `.tmp/` (not system-temp) | Relative path can't mangle; system-temp absolute paths are the root cause |
| `containment-mechanism` | Write-time `.gitignore` net | Structural, write-time, no scanner; post-merge detector was rejected (mechanically blocked path guard + too late for mid-session junk) |
| `tmp-clearing` | Post-merge per-issue sweep | Matches issue lifecycle; bounded subdir (unlike repo-root scanner) |
| `consumer-enforcement-scope` | SessionStart hook (structural) | Deterministic enforcement surface; "agent ensures on first write" was unenforceable prose |

## Net coverage bounds

The gitignore net catches most shapes but is acknowledged best-effort. Documented miss: `CProgramData...`-prefixed collapsed paths. The grep guard (`script-safety-contract.Tests.ps1`) and the prevention rule together close the prevention gap for agent-authored paths.

## Files involved

- `skills/terminal-hygiene/SKILL.md` — canonical scratch-path rule (single source)
- `skills/safe-operations/SKILL.md`, `skills/browser-canvas-testing/SKILL.md`, `skills/ui-iteration/SKILL.md` — cross-references
- `.gitignore` — containment net
- `skills/session-startup/scripts/post-merge-cleanup.ps1` — `Remove-IssueTmpScratch`
- `skills/session-startup/scripts/Ensure-ScratchGitignore.ps1` — consumer zero-config hook
- `.github/scripts/Tests/post-merge-cleanup.Tests.ps1` — TDD coverage
- `.github/scripts/Tests/script-safety-contract.Tests.ps1` — grep guard
- `.github/scripts/Tests/Ensure-ScratchGitignore.Tests.ps1` — hook tests
