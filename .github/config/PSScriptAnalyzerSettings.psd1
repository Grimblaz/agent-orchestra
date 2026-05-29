@{
    # Excludes rules that produce false positives or are inapplicable to automation scripts
    # (suppression only; affirmative formatting rules may be added as IncludeRules in a future issue)
    ExcludeRules = @(
        # Intentional for automation script output — agents need terminal output without Write-Error overhead
        'PSAvoidUsingWriteHost',
        # Cross-platform compatibility — no BOM required for UTF-8 scripts consumed by pwsh on Linux/macOS/Windows
        'PSUseBOMForUnicodeEncodedFile',
        # Naming preference — automation helper functions use domain-appropriate plural forms
        'PSUseSingularNouns',
        # No interactive user in automation — ShouldProcess is not applicable
        'PSUseShouldProcessForStateChangingFunctions',
        # False positive on Write-Output -NoEnumerate pattern in PSScriptAnalyzer 1.24 — this is valid PowerShell
        'PSUseCmdletCorrectly',
        # Conditional-use patterns not statically traceable (e.g., [string]$Repo via computed repoArgs; [string]$ComplexityJsonPath via downstream temp-file bridge)
        'PSReviewUnusedParameter',
        # Informational OutputType hints produce broad noise across script-style helpers that intentionally return mixed pipeline shapes
        'PSUseOutputTypeCorrectly',
        # Pester fixtures and automation scripts use script/global state to share expensive setup and mock process state
        'PSAvoidGlobalVars',
        # Fixture variables are sometimes assigned for side-effect setup or diagnostic capture inspected by Pester assertions
        'PSUseDeclaredVarsMoreThanAssignments',
        # Automation helper verbs use domain language where approved PowerShell verbs would obscure intent
        'PSUseApprovedVerbs',
        # Runspace tests deliberately assert current closure behavior rather than production runspace style
        'PSUseUsingScopeModifierInNewRunspaces',
        # Audit scripts assign captured regex groups and loop values in ways that trigger this rule without automatic-variable mutation risk
        'PSAvoidAssignmentToAutomaticVariable',
        # CLI wrappers intentionally fail open in a few cleanup paths where the validated behavior is no-op continuation
        'PSAvoidUsingEmptyCatchBlock',
        # Ledger and credit terminology is not credential material in this repository
        'PSAvoidUsingPlainTextForPassword',
        # Existing scripts use positional calls for concise built-in invocation where named parameters add noise
        'PSAvoidUsingPositionalParameters'
    )
}
