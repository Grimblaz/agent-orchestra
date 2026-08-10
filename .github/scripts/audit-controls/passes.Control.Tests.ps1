#Requires -Version 7.0

# AUDIT CONTROL — exhibits `passed`. See README.md in this directory.
#
# A `passed` row must assert that at least one discovered test EXECUTED and
# passed, which is not what an exit code and a zero failure count establish: a
# suite that ran nothing produces exactly the same pair. This control is the
# positive side of that discrimination, run through the path the audit actually
# runs rather than asserted about a helper.

Describe 'audit control: a suite that passes' {
    It 'executes one test and passes it' {
        1 + 1 | Should -Be 2
    }
}
