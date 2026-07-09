#Requires -Modules Pester
# Bounded living-surface guard for issue #750 (parent: #732 naming-register-policy).
# LIMITATIONS (not silent caps):
#   - Surface list is hardcoded (not auto-discovered). New surfaces must be added here manually.
#     Growth-enforcement for new surfaces is #751's scope, not this guard.
#   - "now-coupled / wall-clock dependent" term-absence assertions are FORWARD GUARDS:
#     zero current in-scope occurrences; the assertion prevents future regressions.
#   - Term-absence assertions use hardcoded string literals (static decision). The register
#     currently has exactly 2 rename-candidate terms, matching the assertions below.
#     If register.json grows new rename-candidate entries, revisit toward a data-driven loop.
#   - Pointer-presence uses exact depth-relative link resolution to detect depth-wrong paths.
#     Each surface's expected vocab link is computed from its directory depth below repo root.

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path

    # The enumerated in-scope surface list (hardcoded per design; #751 owns auto-discovery)
    $script:AllSurfaces = @(
        'CLAUDE.md'
        'skills/README.md'
        'HOW-IT-WORKS.md'
        'CUSTOMIZATION.md'
        'Documents/Design/agent-body-architecture.md'
        'Documents/Design/frame-architecture.md'
        'Documents/Design/session-memory-contract.md'
        'Documents/Design/hub-artifact-paths-audit.md'
        'Documents/Design/copilot-deprecation.md'
        'Documents/Design/experience-owner.md'
        '.github/ISSUE_TEMPLATE/bug_report.md'
        '.github/ISSUE_TEMPLATE/feature_request.md'
        '.github/PULL_REQUEST_TEMPLATE.md'
    )

    # Surfaces that receive the vocab-pointer check (HOW-IT-WORKS.md is the target, not a holder)
    $script:PointerSurfaces = $script:AllSurfaces | Where-Object { $_ -ne 'HOW-IT-WORKS.md' }

    # HOW-IT-WORKS.md path (used in multiple Describe blocks)
    $script:HowItWorksPath = Join-Path $script:RepoRoot 'HOW-IT-WORKS.md'

    # experience-owner.md is the definition home for "Value Reflex" — the step(s3) commit
    # (8a659c6) deliberately preserved that file's heading and D11 cell, per the commit message:
    # "Preserve vocab-seed block and experience-owner.md heading/D11 cell untouched."
    # It is excluded from the "Value Reflex" term-absence check to match the actual scope of s3.
    $script:ValueReflexDefinitionHome = 'Documents/Design/experience-owner.md'

    # Helper: return lines of a file that are OUTSIDE the vocab-seed fence
    function Get-LinesOutsideVocabSeed {
        param([string]$FilePath)
        $outsideFence = [System.Collections.Generic.List[string]]::new()
        $inFence = $false
        foreach ($line in (Get-Content $FilePath)) {
            if ($line -match '<!--\s*vocab-seed:begin\s*-->') { $inFence = $true; continue }
            if ($line -match '<!--\s*vocab-seed:end\s*-->') { $inFence = $false; continue }
            if (-not $inFence) { $outsideFence.Add($line) }
        }
        # Fence-integrity guard: a missing vocab-seed:end causes all remaining lines to be
        # excluded from the returned set, producing false-green term-absence assertions.
        if ($inFence) {
            throw "vocab-seed fence malformed in '$FilePath': vocab-seed:begin found but no matching vocab-seed:end"
        }
        return $outsideFence
    }

    # Helper: compute the correct depth-relative vocab link for a surface path.
    # Depth = number of directory levels below repo root (path segments minus 1).
    # E.g. 'CLAUDE.md' (0 levels) → 'HOW-IT-WORKS.md#vocab'
    #      'skills/README.md' (1 level) → '../HOW-IT-WORKS.md#vocab'
    #      '.github/PULL_REQUEST_TEMPLATE.md' (1 level) → '../HOW-IT-WORKS.md#vocab'
    #      'Documents/Design/experience-owner.md' (2 levels) → '../../HOW-IT-WORKS.md#vocab'
    function Get-ExpectedVocabLink {
        param([string]$RelativeSurfacePath)
        $depth = ($RelativeSurfacePath -split '[/\\]').Count - 1
        $prefix = '../' * $depth
        return "${prefix}HOW-IT-WORKS.md#vocab"
    }
}

Describe "File existence" {
    It "CLAUDE.md exists" {
        (Join-Path $script:RepoRoot 'CLAUDE.md') | Should -Exist
    }
    It "skills/README.md exists" {
        (Join-Path $script:RepoRoot 'skills/README.md') | Should -Exist
    }
    It "HOW-IT-WORKS.md exists" {
        (Join-Path $script:RepoRoot 'HOW-IT-WORKS.md') | Should -Exist
    }
    It "CUSTOMIZATION.md exists" {
        (Join-Path $script:RepoRoot 'CUSTOMIZATION.md') | Should -Exist
    }
    It "Documents/Design/agent-body-architecture.md exists" {
        (Join-Path $script:RepoRoot 'Documents/Design/agent-body-architecture.md') | Should -Exist
    }
    It "Documents/Design/frame-architecture.md exists" {
        (Join-Path $script:RepoRoot 'Documents/Design/frame-architecture.md') | Should -Exist
    }
    It "Documents/Design/session-memory-contract.md exists" {
        (Join-Path $script:RepoRoot 'Documents/Design/session-memory-contract.md') | Should -Exist
    }
    It "Documents/Design/hub-artifact-paths-audit.md exists" {
        (Join-Path $script:RepoRoot 'Documents/Design/hub-artifact-paths-audit.md') | Should -Exist
    }
    It "Documents/Design/copilot-deprecation.md exists" {
        (Join-Path $script:RepoRoot 'Documents/Design/copilot-deprecation.md') | Should -Exist
    }
    It "Documents/Design/experience-owner.md exists" {
        (Join-Path $script:RepoRoot 'Documents/Design/experience-owner.md') | Should -Exist
    }
    It ".github/ISSUE_TEMPLATE/bug_report.md exists" {
        (Join-Path $script:RepoRoot '.github/ISSUE_TEMPLATE/bug_report.md') | Should -Exist
    }
    It ".github/ISSUE_TEMPLATE/feature_request.md exists" {
        (Join-Path $script:RepoRoot '.github/ISSUE_TEMPLATE/feature_request.md') | Should -Exist
    }
    It ".github/PULL_REQUEST_TEMPLATE.md exists" {
        (Join-Path $script:RepoRoot '.github/PULL_REQUEST_TEMPLATE.md') | Should -Exist
    }
}

Describe "Vocab anchor" {
    It 'vocab anchor (anchor tag with id="vocab") appears exactly once in HOW-IT-WORKS.md' {
        $content = Get-Content $script:HowItWorksPath -Raw
        $anchorMatches = [regex]::Matches($content, '<a\s+id="vocab">')
        $anchorMatches.Count | Should -Be 1 -Because "exactly one vocab anchor is required for unambiguous fragment routing"
    }
}

Describe "Rename-candidate term absence" {
    # Term 1: "Value Reflex"
    # HOW-IT-WORKS.md — check only outside the vocab-seed fence (fence is the definition home)
    It "HOW-IT-WORKS.md (outside vocab-seed) does not contain 'Value Reflex'" {
        $lines = Get-LinesOutsideVocabSeed -FilePath (Join-Path $script:RepoRoot 'HOW-IT-WORKS.md')
        $hits = $lines | Where-Object { $_ -match [regex]::Escape('Value Reflex') }
        $hits | Should -BeNullOrEmpty -Because "'Value Reflex' is rename-candidate and must not appear outside the vocab-seed fence in HOW-IT-WORKS.md"
    }
    It "CLAUDE.md does not contain 'Value Reflex'" {
        $content = Get-Content (Join-Path $script:RepoRoot 'CLAUDE.md') -Raw
        $content | Should -Not -Match ([regex]::Escape('Value Reflex')) -Because "'Value Reflex' is a rename-candidate; use 'worth-it check' instead"
    }
    It "skills/README.md does not contain 'Value Reflex'" {
        $content = Get-Content (Join-Path $script:RepoRoot 'skills/README.md') -Raw
        $content | Should -Not -Match ([regex]::Escape('Value Reflex')) -Because "'Value Reflex' is a rename-candidate; use 'worth-it check' instead"
    }
    It "CUSTOMIZATION.md does not contain 'Value Reflex'" {
        $content = Get-Content (Join-Path $script:RepoRoot 'CUSTOMIZATION.md') -Raw
        $content | Should -Not -Match ([regex]::Escape('Value Reflex')) -Because "'Value Reflex' is a rename-candidate; use 'worth-it check' instead"
    }
    It "Documents/Design/agent-body-architecture.md does not contain 'Value Reflex'" {
        $content = Get-Content (Join-Path $script:RepoRoot 'Documents/Design/agent-body-architecture.md') -Raw
        $content | Should -Not -Match ([regex]::Escape('Value Reflex')) -Because "'Value Reflex' is a rename-candidate; use 'worth-it check' instead"
    }
    It "Documents/Design/frame-architecture.md does not contain 'Value Reflex'" {
        $content = Get-Content (Join-Path $script:RepoRoot 'Documents/Design/frame-architecture.md') -Raw
        $content | Should -Not -Match ([regex]::Escape('Value Reflex')) -Because "'Value Reflex' is a rename-candidate; use 'worth-it check' instead"
    }
    It "Documents/Design/session-memory-contract.md does not contain 'Value Reflex'" {
        $content = Get-Content (Join-Path $script:RepoRoot 'Documents/Design/session-memory-contract.md') -Raw
        $content | Should -Not -Match ([regex]::Escape('Value Reflex')) -Because "'Value Reflex' is a rename-candidate; use 'worth-it check' instead"
    }
    It "Documents/Design/hub-artifact-paths-audit.md does not contain 'Value Reflex'" {
        $content = Get-Content (Join-Path $script:RepoRoot 'Documents/Design/hub-artifact-paths-audit.md') -Raw
        $content | Should -Not -Match ([regex]::Escape('Value Reflex')) -Because "'Value Reflex' is a rename-candidate; use 'worth-it check' instead"
    }
    It "Documents/Design/copilot-deprecation.md does not contain 'Value Reflex'" {
        $content = Get-Content (Join-Path $script:RepoRoot 'Documents/Design/copilot-deprecation.md') -Raw
        $content | Should -Not -Match ([regex]::Escape('Value Reflex')) -Because "'Value Reflex' is a rename-candidate; use 'worth-it check' instead"
    }
    # experience-owner.md is the definition home for "Value Reflex" (heading + D11 cell were
    # intentionally preserved by step s3 commit 8a659c6). Excluded from this term check.
    It "Documents/Design/experience-owner.md: 'Value Reflex' check skipped (definition home preserved by s3)" {
        $true | Should -BeTrue
    }
    It ".github/ISSUE_TEMPLATE/bug_report.md does not contain 'Value Reflex'" {
        $content = Get-Content (Join-Path $script:RepoRoot '.github/ISSUE_TEMPLATE/bug_report.md') -Raw
        $content | Should -Not -Match ([regex]::Escape('Value Reflex')) -Because "'Value Reflex' is a rename-candidate; use 'worth-it check' instead"
    }
    It ".github/ISSUE_TEMPLATE/feature_request.md does not contain 'Value Reflex'" {
        $content = Get-Content (Join-Path $script:RepoRoot '.github/ISSUE_TEMPLATE/feature_request.md') -Raw
        $content | Should -Not -Match ([regex]::Escape('Value Reflex')) -Because "'Value Reflex' is a rename-candidate; use 'worth-it check' instead"
    }
    It ".github/PULL_REQUEST_TEMPLATE.md does not contain 'Value Reflex'" {
        $content = Get-Content (Join-Path $script:RepoRoot '.github/PULL_REQUEST_TEMPLATE.md') -Raw
        $content | Should -Not -Match ([regex]::Escape('Value Reflex')) -Because "'Value Reflex' is a rename-candidate; use 'worth-it check' instead"
    }

    # Term 2: "now-coupled / wall-clock dependent" (forward guard — zero current occurrences)
    It "HOW-IT-WORKS.md (outside vocab-seed) does not contain 'now-coupled / wall-clock dependent'" {
        $lines = Get-LinesOutsideVocabSeed -FilePath (Join-Path $script:RepoRoot 'HOW-IT-WORKS.md')
        $hits = $lines | Where-Object { $_ -match [regex]::Escape('now-coupled / wall-clock dependent') }
        $hits | Should -BeNullOrEmpty -Because "'now-coupled / wall-clock dependent' is rename-candidate and must not appear outside the vocab-seed fence in HOW-IT-WORKS.md"
    }
    It "CLAUDE.md does not contain 'now-coupled / wall-clock dependent'" {
        $content = Get-Content (Join-Path $script:RepoRoot 'CLAUDE.md') -Raw
        $content | Should -Not -Match ([regex]::Escape('now-coupled / wall-clock dependent')) -Because "'now-coupled / wall-clock dependent' is a rename-candidate; use 'time-sensitive test' instead"
    }
    It "skills/README.md does not contain 'now-coupled / wall-clock dependent'" {
        $content = Get-Content (Join-Path $script:RepoRoot 'skills/README.md') -Raw
        $content | Should -Not -Match ([regex]::Escape('now-coupled / wall-clock dependent')) -Because "'now-coupled / wall-clock dependent' is a rename-candidate; use 'time-sensitive test' instead"
    }
    It "CUSTOMIZATION.md does not contain 'now-coupled / wall-clock dependent'" {
        $content = Get-Content (Join-Path $script:RepoRoot 'CUSTOMIZATION.md') -Raw
        $content | Should -Not -Match ([regex]::Escape('now-coupled / wall-clock dependent')) -Because "'now-coupled / wall-clock dependent' is a rename-candidate; use 'time-sensitive test' instead"
    }
    It "Documents/Design/agent-body-architecture.md does not contain 'now-coupled / wall-clock dependent'" {
        $content = Get-Content (Join-Path $script:RepoRoot 'Documents/Design/agent-body-architecture.md') -Raw
        $content | Should -Not -Match ([regex]::Escape('now-coupled / wall-clock dependent')) -Because "'now-coupled / wall-clock dependent' is a rename-candidate; use 'time-sensitive test' instead"
    }
    It "Documents/Design/frame-architecture.md does not contain 'now-coupled / wall-clock dependent'" {
        $content = Get-Content (Join-Path $script:RepoRoot 'Documents/Design/frame-architecture.md') -Raw
        $content | Should -Not -Match ([regex]::Escape('now-coupled / wall-clock dependent')) -Because "'now-coupled / wall-clock dependent' is a rename-candidate; use 'time-sensitive test' instead"
    }
    It "Documents/Design/session-memory-contract.md does not contain 'now-coupled / wall-clock dependent'" {
        $content = Get-Content (Join-Path $script:RepoRoot 'Documents/Design/session-memory-contract.md') -Raw
        $content | Should -Not -Match ([regex]::Escape('now-coupled / wall-clock dependent')) -Because "'now-coupled / wall-clock dependent' is a rename-candidate; use 'time-sensitive test' instead"
    }
    It "Documents/Design/hub-artifact-paths-audit.md does not contain 'now-coupled / wall-clock dependent'" {
        $content = Get-Content (Join-Path $script:RepoRoot 'Documents/Design/hub-artifact-paths-audit.md') -Raw
        $content | Should -Not -Match ([regex]::Escape('now-coupled / wall-clock dependent')) -Because "'now-coupled / wall-clock dependent' is a rename-candidate; use 'time-sensitive test' instead"
    }
    It "Documents/Design/copilot-deprecation.md does not contain 'now-coupled / wall-clock dependent'" {
        $content = Get-Content (Join-Path $script:RepoRoot 'Documents/Design/copilot-deprecation.md') -Raw
        $content | Should -Not -Match ([regex]::Escape('now-coupled / wall-clock dependent')) -Because "'now-coupled / wall-clock dependent' is a rename-candidate; use 'time-sensitive test' instead"
    }
    It "Documents/Design/experience-owner.md does not contain 'now-coupled / wall-clock dependent'" {
        $content = Get-Content (Join-Path $script:RepoRoot 'Documents/Design/experience-owner.md') -Raw
        $content | Should -Not -Match ([regex]::Escape('now-coupled / wall-clock dependent')) -Because "'now-coupled / wall-clock dependent' is a rename-candidate; use 'time-sensitive test' instead"
    }
    It ".github/ISSUE_TEMPLATE/bug_report.md does not contain 'now-coupled / wall-clock dependent'" {
        $content = Get-Content (Join-Path $script:RepoRoot '.github/ISSUE_TEMPLATE/bug_report.md') -Raw
        $content | Should -Not -Match ([regex]::Escape('now-coupled / wall-clock dependent')) -Because "'now-coupled / wall-clock dependent' is a rename-candidate; use 'time-sensitive test' instead"
    }
    It ".github/ISSUE_TEMPLATE/feature_request.md does not contain 'now-coupled / wall-clock dependent'" {
        $content = Get-Content (Join-Path $script:RepoRoot '.github/ISSUE_TEMPLATE/feature_request.md') -Raw
        $content | Should -Not -Match ([regex]::Escape('now-coupled / wall-clock dependent')) -Because "'now-coupled / wall-clock dependent' is a rename-candidate; use 'time-sensitive test' instead"
    }
    It ".github/PULL_REQUEST_TEMPLATE.md does not contain 'now-coupled / wall-clock dependent'" {
        $content = Get-Content (Join-Path $script:RepoRoot '.github/PULL_REQUEST_TEMPLATE.md') -Raw
        $content | Should -Not -Match ([regex]::Escape('now-coupled / wall-clock dependent')) -Because "'now-coupled / wall-clock dependent' is a rename-candidate; use 'time-sensitive test' instead"
    }
}

Describe "Vocab-pointer presence" {
    # 12 surfaces (all except HOW-IT-WORKS.md which is the target, not a pointer holder)
    # Link assertions use Get-ExpectedVocabLink to compute the depth-relative path and match it
    # inside Markdown link parentheses — e.g. (../HOW-IT-WORKS.md#vocab) — which correctly
    # rejects depth-wrong bare paths like (HOW-IT-WORKS.md#vocab) in a .github/ nested file.
    It "CLAUDE.md contains the vocab-pointer sentinel" {
        $content = Get-Content (Join-Path $script:RepoRoot 'CLAUDE.md') -Raw
        $content | Should -Match '<!--\s*vocab-pointer\s*-->' -Because "every in-scope surface must carry the vocab-pointer sentinel"
    }
    It "CLAUDE.md contains the correct depth-relative link to HOW-IT-WORKS.md#vocab" {
        $content = Get-Content (Join-Path $script:RepoRoot 'CLAUDE.md') -Raw
        $expectedLink = Get-ExpectedVocabLink 'CLAUDE.md'
        $content | Should -Match ('\(' + [regex]::Escape($expectedLink) + '\)') -Because "vocab-pointer must use the correct depth-relative path (expected: '$expectedLink')"
    }
    It "skills/README.md contains the vocab-pointer sentinel" {
        $content = Get-Content (Join-Path $script:RepoRoot 'skills/README.md') -Raw
        $content | Should -Match '<!--\s*vocab-pointer\s*-->' -Because "every in-scope surface must carry the vocab-pointer sentinel"
    }
    It "skills/README.md contains the correct depth-relative link to HOW-IT-WORKS.md#vocab" {
        $content = Get-Content (Join-Path $script:RepoRoot 'skills/README.md') -Raw
        $expectedLink = Get-ExpectedVocabLink 'skills/README.md'
        $content | Should -Match ('\(' + [regex]::Escape($expectedLink) + '\)') -Because "vocab-pointer must use the correct depth-relative path (expected: '$expectedLink')"
    }
    It "CUSTOMIZATION.md contains the vocab-pointer sentinel" {
        $content = Get-Content (Join-Path $script:RepoRoot 'CUSTOMIZATION.md') -Raw
        $content | Should -Match '<!--\s*vocab-pointer\s*-->' -Because "every in-scope surface must carry the vocab-pointer sentinel"
    }
    It "CUSTOMIZATION.md contains the correct depth-relative link to HOW-IT-WORKS.md#vocab" {
        $content = Get-Content (Join-Path $script:RepoRoot 'CUSTOMIZATION.md') -Raw
        $expectedLink = Get-ExpectedVocabLink 'CUSTOMIZATION.md'
        $content | Should -Match ('\(' + [regex]::Escape($expectedLink) + '\)') -Because "vocab-pointer must use the correct depth-relative path (expected: '$expectedLink')"
    }
    It "Documents/Design/agent-body-architecture.md contains the vocab-pointer sentinel" {
        $content = Get-Content (Join-Path $script:RepoRoot 'Documents/Design/agent-body-architecture.md') -Raw
        $content | Should -Match '<!--\s*vocab-pointer\s*-->' -Because "every in-scope surface must carry the vocab-pointer sentinel"
    }
    It "Documents/Design/agent-body-architecture.md contains the correct depth-relative link to HOW-IT-WORKS.md#vocab" {
        $content = Get-Content (Join-Path $script:RepoRoot 'Documents/Design/agent-body-architecture.md') -Raw
        $expectedLink = Get-ExpectedVocabLink 'Documents/Design/agent-body-architecture.md'
        $content | Should -Match ('\(' + [regex]::Escape($expectedLink) + '\)') -Because "vocab-pointer must use the correct depth-relative path (expected: '$expectedLink')"
    }
    It "Documents/Design/frame-architecture.md contains the vocab-pointer sentinel" {
        $content = Get-Content (Join-Path $script:RepoRoot 'Documents/Design/frame-architecture.md') -Raw
        $content | Should -Match '<!--\s*vocab-pointer\s*-->' -Because "every in-scope surface must carry the vocab-pointer sentinel"
    }
    It "Documents/Design/frame-architecture.md contains the correct depth-relative link to HOW-IT-WORKS.md#vocab" {
        $content = Get-Content (Join-Path $script:RepoRoot 'Documents/Design/frame-architecture.md') -Raw
        $expectedLink = Get-ExpectedVocabLink 'Documents/Design/frame-architecture.md'
        $content | Should -Match ('\(' + [regex]::Escape($expectedLink) + '\)') -Because "vocab-pointer must use the correct depth-relative path (expected: '$expectedLink')"
    }
    It "Documents/Design/session-memory-contract.md contains the vocab-pointer sentinel" {
        $content = Get-Content (Join-Path $script:RepoRoot 'Documents/Design/session-memory-contract.md') -Raw
        $content | Should -Match '<!--\s*vocab-pointer\s*-->' -Because "every in-scope surface must carry the vocab-pointer sentinel"
    }
    It "Documents/Design/session-memory-contract.md contains the correct depth-relative link to HOW-IT-WORKS.md#vocab" {
        $content = Get-Content (Join-Path $script:RepoRoot 'Documents/Design/session-memory-contract.md') -Raw
        $expectedLink = Get-ExpectedVocabLink 'Documents/Design/session-memory-contract.md'
        $content | Should -Match ('\(' + [regex]::Escape($expectedLink) + '\)') -Because "vocab-pointer must use the correct depth-relative path (expected: '$expectedLink')"
    }
    It "Documents/Design/hub-artifact-paths-audit.md contains the vocab-pointer sentinel" {
        $content = Get-Content (Join-Path $script:RepoRoot 'Documents/Design/hub-artifact-paths-audit.md') -Raw
        $content | Should -Match '<!--\s*vocab-pointer\s*-->' -Because "every in-scope surface must carry the vocab-pointer sentinel"
    }
    It "Documents/Design/hub-artifact-paths-audit.md contains the correct depth-relative link to HOW-IT-WORKS.md#vocab" {
        $content = Get-Content (Join-Path $script:RepoRoot 'Documents/Design/hub-artifact-paths-audit.md') -Raw
        $expectedLink = Get-ExpectedVocabLink 'Documents/Design/hub-artifact-paths-audit.md'
        $content | Should -Match ('\(' + [regex]::Escape($expectedLink) + '\)') -Because "vocab-pointer must use the correct depth-relative path (expected: '$expectedLink')"
    }
    It "Documents/Design/copilot-deprecation.md contains the vocab-pointer sentinel" {
        $content = Get-Content (Join-Path $script:RepoRoot 'Documents/Design/copilot-deprecation.md') -Raw
        $content | Should -Match '<!--\s*vocab-pointer\s*-->' -Because "every in-scope surface must carry the vocab-pointer sentinel"
    }
    It "Documents/Design/copilot-deprecation.md contains the correct depth-relative link to HOW-IT-WORKS.md#vocab" {
        $content = Get-Content (Join-Path $script:RepoRoot 'Documents/Design/copilot-deprecation.md') -Raw
        $expectedLink = Get-ExpectedVocabLink 'Documents/Design/copilot-deprecation.md'
        $content | Should -Match ('\(' + [regex]::Escape($expectedLink) + '\)') -Because "vocab-pointer must use the correct depth-relative path (expected: '$expectedLink')"
    }
    It "Documents/Design/experience-owner.md contains the vocab-pointer sentinel" {
        $content = Get-Content (Join-Path $script:RepoRoot 'Documents/Design/experience-owner.md') -Raw
        $content | Should -Match '<!--\s*vocab-pointer\s*-->' -Because "every in-scope surface must carry the vocab-pointer sentinel"
    }
    It "Documents/Design/experience-owner.md contains the correct depth-relative link to HOW-IT-WORKS.md#vocab" {
        $content = Get-Content (Join-Path $script:RepoRoot 'Documents/Design/experience-owner.md') -Raw
        $expectedLink = Get-ExpectedVocabLink 'Documents/Design/experience-owner.md'
        $content | Should -Match ('\(' + [regex]::Escape($expectedLink) + '\)') -Because "vocab-pointer must use the correct depth-relative path (expected: '$expectedLink')"
    }
    It ".github/ISSUE_TEMPLATE/bug_report.md contains the vocab-pointer sentinel" {
        $content = Get-Content (Join-Path $script:RepoRoot '.github/ISSUE_TEMPLATE/bug_report.md') -Raw
        $content | Should -Match '<!--\s*vocab-pointer\s*-->' -Because "every in-scope surface must carry the vocab-pointer sentinel"
    }
    It ".github/ISSUE_TEMPLATE/bug_report.md contains the correct depth-relative link to HOW-IT-WORKS.md#vocab" {
        $content = Get-Content (Join-Path $script:RepoRoot '.github/ISSUE_TEMPLATE/bug_report.md') -Raw
        $expectedLink = Get-ExpectedVocabLink '.github/ISSUE_TEMPLATE/bug_report.md'
        $content | Should -Match ('\(' + [regex]::Escape($expectedLink) + '\)') -Because "vocab-pointer must use the correct depth-relative path (expected: '$expectedLink')"
    }
    It ".github/ISSUE_TEMPLATE/feature_request.md contains the vocab-pointer sentinel" {
        $content = Get-Content (Join-Path $script:RepoRoot '.github/ISSUE_TEMPLATE/feature_request.md') -Raw
        $content | Should -Match '<!--\s*vocab-pointer\s*-->' -Because "every in-scope surface must carry the vocab-pointer sentinel"
    }
    It ".github/ISSUE_TEMPLATE/feature_request.md contains the correct depth-relative link to HOW-IT-WORKS.md#vocab" {
        $content = Get-Content (Join-Path $script:RepoRoot '.github/ISSUE_TEMPLATE/feature_request.md') -Raw
        $expectedLink = Get-ExpectedVocabLink '.github/ISSUE_TEMPLATE/feature_request.md'
        $content | Should -Match ('\(' + [regex]::Escape($expectedLink) + '\)') -Because "vocab-pointer must use the correct depth-relative path (expected: '$expectedLink')"
    }
    It ".github/PULL_REQUEST_TEMPLATE.md contains the vocab-pointer sentinel" {
        $content = Get-Content (Join-Path $script:RepoRoot '.github/PULL_REQUEST_TEMPLATE.md') -Raw
        $content | Should -Match '<!--\s*vocab-pointer\s*-->' -Because "every in-scope surface must carry the vocab-pointer sentinel"
    }
    It ".github/PULL_REQUEST_TEMPLATE.md contains the correct depth-relative link to HOW-IT-WORKS.md#vocab" {
        $content = Get-Content (Join-Path $script:RepoRoot '.github/PULL_REQUEST_TEMPLATE.md') -Raw
        $expectedLink = Get-ExpectedVocabLink '.github/PULL_REQUEST_TEMPLATE.md'
        $content | Should -Match ('\(' + [regex]::Escape($expectedLink) + '\)') -Because "vocab-pointer must use the correct depth-relative path (expected: '$expectedLink')"
    }
}
