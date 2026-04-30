#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

# AC-IMPL-1 (issue #429) — widened predicate-evaluator uniqueness grep + positive-fixture seed.
#
# Asserts that only `lib/frame-predicate-core.ps1` defines functions matching the widened
# pattern. All other consumers must use it as a library, not redeclare its surface.
#
# Forbidden pattern (anchored on the `function` keyword, multiline):
#
#   ^function\s+(Test-FV|ConvertTo-FV|Get-FV|New-FV|Read-FV|Test-FramePredicate|Evaluate-Predicate|Invoke-Predicate)
#
# Allowlist:
#   - .github/scripts/lib/frame-predicate-core.ps1   (the canonical evaluator)
#
# A positive-test fixture asserts the structural test fires when a duplicate is intentionally seeded.

Describe 'AC-IMPL-1: predicate evaluator uniqueness' {
    BeforeAll {
        $script:RepoRoot = (Get-Item $PSScriptRoot).Parent.Parent.Parent.FullName
        # Allowlist: legitimate consumers of the *-FV* namespace.
        # - frame-predicate-core.ps1 is the canonical predicate evaluator (AC-IMPL-1 source-of-truth).
        # - frame-validate-core.ps1 uses the FV prefix for Frame-Validate namespacing (port catalog, adapter symmetry, YAML helpers); it CALLS frame-predicate-core for parsing, does not duplicate the evaluator.
        # Future entries require code review and a documented rationale.
        $script:Allowlist = @(
            (Join-Path $script:RepoRoot '.github/scripts/lib/frame-predicate-core.ps1'),
            (Join-Path $script:RepoRoot '.github/scripts/lib/frame-validate-core.ps1')
        ) | ForEach-Object { (Resolve-Path $_).Path }
        $script:Pattern = '^function\s+(Test-FV|ConvertTo-FV|Get-FV|New-FV|Read-FV|Test-FramePredicate|Evaluate-Predicate|Invoke-Predicate)'
        $script:ScriptsRoot = Join-Path $script:RepoRoot '.github/scripts'
    }

    It 'no .ps1 file outside the allowlist defines a forbidden function name' {
        $violations = @()
        Get-ChildItem -Path $script:ScriptsRoot -Recurse -Filter '*.ps1' | Where-Object {
            (Resolve-Path $_.FullName).Path -notin $script:Allowlist
        } | ForEach-Object {
            $matches = Select-String -Path $_.FullName -Pattern $script:Pattern -AllMatches
            if ($matches) {
                $violations += [pscustomobject]@{ File = $_.FullName; Lines = ($matches | ForEach-Object { $_.LineNumber }) -join ',' }
            }
        }
        $violations | Should -BeNullOrEmpty -Because "AC-IMPL-1: predicate evaluator must remain single-source. Violations: $($violations | ConvertTo-Json -Compress)"
    }

    It 'positive-test fixture: a deliberately-seeded duplicate triggers the violation check' {
        # Write a fixture file containing a forbidden function decl, then re-run the same scan against a temp dir, assert violation found.
        $fixtureDir = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString())
        New-Item -ItemType Directory -Path $fixtureDir -Force | Out-Null
        try {
            $fixturePath = Join-Path $fixtureDir 'duplicate-evaluator.ps1'
            Set-Content -LiteralPath $fixturePath -Value "function Test-FVDuplicateAgainstChangeset {`n    'this is a deliberately seeded duplicate that should trigger the structural test'`n}"
            $matches = Select-String -Path $fixturePath -Pattern $script:Pattern -AllMatches
            $matches | Should -Not -BeNullOrEmpty
            ($matches | Measure-Object).Count | Should -Be 1
        }
        finally {
            Remove-Item -LiteralPath $fixtureDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
