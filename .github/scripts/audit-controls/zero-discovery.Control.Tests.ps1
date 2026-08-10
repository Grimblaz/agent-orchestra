#Requires -Version 7.0

# AUDIT CONTROL — exhibits `executed-no-tests` via the no-tests-discovered
# route. See README.md in this directory.
#
# Deliberately contains no Describe and no It. Pester runs the container,
# discovers nothing, and exits zero. This is the OTHER shape of the fourth
# terminal state, and it is not interchangeable with the all-skipped one: the
# repository's existing sharded runner gets these two wrong in OPPOSITE
# directions — it increments its failure total for a zero-discovery file, while
# an all-skipped file reads to it as a pass. A classifier is only demonstrated
# on this state once BOTH shapes have been run through it.

Write-Host 'ci-glob-audit control: zero-discovery container executed; no tests are defined in this file, by design.'
