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
        'PSReviewUnusedParameter'
    )
}
