#Requires -Version 7.0

# AUDIT CONTROL — exhibits `failed`, WITH a classifying message. See README.md.
#
# The record's whole reason for existing is that a downstream reader can decide
# `linux-red` versus `never-ci` from the row rather than by opening the suite,
# and a count cannot do that. This control fails with a distinctive message, so
# every audit run demonstrates that the shipped path carries failure TEXT into
# the durable record — not just that some row somewhere says `failed`.

Describe 'audit control: a suite that fails' {
    It 'fails with a message a reader can classify from' {
        # Both strings are short on purpose: an assertion message long enough to
        # be elided by the test framework's own diff rendering would leave the
        # distinctive token out of the very text this control exists to prove
        # travels into the record.
        $observed = 'ci-glob-audit-control-observed'
        $observed | Should -Be 'ci-glob-audit-control-expected'
    }
}
