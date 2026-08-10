#Requires -Version 7.0

# AUDIT CONTROL — this suite does not return. See README.md in this directory.
#
# It exists because the parent design requires the `did-not-complete` class be
# demonstrated non-empty by a suite that ACTUALLY fails to return, not by an
# injected row, a mocked result, or a fabricated state. The audit's bound is
# what ends it, and the row in the record therefore comes from a real hang.
#
# TWO INTERLOCKS, because a non-returning test file is a live hazard:
#   1. This directory is outside `.github/scripts/Tests/`, so no enumeration in
#      this repository reaches it — not the gate's selection, and not the
#      recursive, quarantine-blind `Invoke-Pester .github/scripts/Tests/` that
#      the contributor instructions and the pull-request template prescribe.
#   2. It refuses to block unless CI_GLOB_AUDIT_CONTROLS=1 is set in its own
#      process environment, which the audit sets on this child alone.
#
# Unarmed it skips, and the audit records it as `executed-no-tests`. That is a
# visible, honest state — not a silent pass.

$script:ControlArmed = ($env:CI_GLOB_AUDIT_CONTROLS -eq '1')

Describe 'audit control: a suite that never returns' {
    It 'blocks forever once armed' -Skip:(-not $script:ControlArmed) {
        Write-Host 'ci-glob-audit control: armed; entering a deliberate non-returning loop. The audit''s per-suite bound is what ends this process.'
        while ($true) {
            # Sleeping rather than spinning: the point is a process that never
            # returns, not one that burns a core while the bound runs down and
            # skews every other row's duration on this runner.
            Start-Sleep -Seconds 5
            Write-Host "ci-glob-audit control: still running at $([System.DateTimeOffset]::UtcNow.ToString('o'))"
        }
    }
}
