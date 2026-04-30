#Requires -Version 7.0
<#
.SYNOPSIS
    Positive-test fixture for AC-IMPL-1 predicate-evaluator uniqueness scan.

.DESCRIPTION
    This file is intentionally seeded with a function whose name matches the
    forbidden pattern guarded by frame-predicate-evaluator-uniqueness.Tests.ps1
    (`^function\s+(Test-FV|ConvertTo-FV|Get-FV|New-FV|Read-FV|Test-FramePredicate|Evaluate-Predicate|Invoke-Predicate)`).

    The test allowlists this exact path so the production scan still passes,
    but the positive-test then asserts that scanning JUST this fixture's
    folder (without the allowlist) produces a violation. That proves the
    scan logic actually catches duplicates in real-world `.github/scripts/`
    paths — not just temp directories the production scan never walks.

    DO NOT REMOVE. DO NOT REFACTOR THE FUNCTION NAME.

    If you need to add a real predicate evaluator, add it to
    `lib/frame-predicate-core.ps1` (the canonical evaluator) — never here.
#>

# Positive-test fixture: deliberately seeded duplicate. Allowlisted in
# frame-predicate-evaluator-uniqueness.Tests.ps1.
function Test-FVDuplicateAgainstChangeset {
    param($Ast, $Changeset)
    'this is a deliberately seeded duplicate that must trigger the structural test'
}
