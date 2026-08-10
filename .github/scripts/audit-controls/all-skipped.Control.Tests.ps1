#Requires -Version 7.0

# AUDIT CONTROL — exhibits `executed-no-tests` via the all-skipped route.
# See README.md in this directory.
#
# This is the shape the parent design names as the obvious route to the fourth
# terminal state: a `Describe` behind a platform guard, on a corpus written on
# Windows and now being run on Linux. Such a suite COMPLETED, did not FAIL, and
# ran nothing — and the repository's existing sharded runner reads it as a
# clean green, because it reaches exit 0 with a zero failure count.
#
# Skipped unconditionally rather than behind $IsWindows, so the control exhibits
# its state on every platform the audit might ever run on.

Describe 'audit control: a suite whose every test is skipped' {
    It 'is skipped, so nothing executes' -Skip {
        throw 'unreachable: this control exists to be skipped'
    }

    It 'is also skipped, so the suite has a non-zero discovered count and a zero executed count' -Skip {
        throw 'unreachable: this control exists to be skipped'
    }
}
