# Audit controls — the full-glob audit's instrument self-test

Five Pester suites that exist to exhibit, on purpose, each terminal state the
full-glob CI audit is supposed to be able to tell apart. They are **not**
measurements of this repository's test corpus, and the audit's record names
every one of them as an out-of-population row so no consumer can mistake them
for one.

## Why they are here and not under `.github/scripts/Tests/`

`never-returns.Control.Tests.ps1` deliberately does not return. Reasoning about
where that is safe from the *gate's* selection is the wrong reasoning — the
gate's enumeration is non-recursive and quarantine-aware, but
`.github/copilot-instructions.md` and `.github/PULL_REQUEST_TEMPLATE.md` both
tell every contributor to run `Invoke-Pester .github/scripts/Tests/`, which is
**recursive** and never reads `ci-quarantine.json`. A non-returning suite
anywhere beneath the tests root — including in a subdirectory, and including
with a quarantine entry — hangs that command on a contributor's machine, where
no job ceiling exists to stop it.

So: outside the tests root entirely. Nothing in this repository enumerates this
directory for execution. The audit reaches these files because it is handed
their paths explicitly.

## The second interlock

`never-returns.Control.Tests.ps1` additionally refuses to block unless
`CI_GLOB_AUDIT_CONTROLS=1` is set in its own process environment. The audit sets
that variable on that one child process — not job-wide, because an extra
variable in the shared environment would be an environment divergence from the
per-PR gate, and the audit's parity criterion treats avoidable divergences as
failures.

Unarmed, the suite skips and reads as `executed-no-tests`. Armed, it genuinely
never returns and the audit's bound is what ends it: the row in the record comes
from a real hang, not from an injected or hand-written result.

## The five

| file | arms | expected terminal state |
| --- | --- | --- |
| `passes.Control.Tests.ps1` | always | `passed` |
| `fails.Control.Tests.ps1` | always | `failed` |
| `zero-discovery.Control.Tests.ps1` | always | `executed-no-tests` (`no-tests-discovered`) |
| `all-skipped.Control.Tests.ps1` | always | `executed-no-tests` (`all-skipped`) |
| `never-returns.Control.Tests.ps1` | `CI_GLOB_AUDIT_CONTROLS=1` | `did-not-complete` |

Every audit run checks each control against its expected state and fails the run
when one does not match. A control that stops producing its state means the
classifier is wrong — which is the failure the four-state distinction exists to
prevent, arriving through the back door.

Do not run these by hand. If you must, run one file at a time and never
`never-returns.Control.Tests.ps1` with `CI_GLOB_AUDIT_CONTROLS` set.
