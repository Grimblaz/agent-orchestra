#Requires -Version 7.0
<#
.SYNOPSIS
    Evaluates whether a code review finding should be deferred to a follow-up issue
    based on six structural criteria instead of effort estimates.

.DESCRIPTION
    Implementation for D1 structural-criteria gate.

    M4: Predicate Test-Path calls run against an explicit $RepoRoot rather
    than $PWD. Get-StructuralVerdict resolves RepoRoot from git when not
    supplied and forwards it to each predicate.

    M5: S-new-abstraction regex now requires a verb anchor
    (introduce|create|add|propose|define) to avoid matching incidental
    prose like "new function call" or "new file path"; the noun "function"
    was dropped from the noun set for the same reason.

    M6: S-schema-or-contract file fallback restricts to schema/contract-like
    paths so that arbitrary .json/.yml asset fixtures no longer trip the
    predicate on extension alone.

    M7: Predicates that depend on $Finding.files now emit a structured
    "skipped: finding text empty; no files to evaluate" evidence string
    when neither the text criterion nor a file list is available, making
    no-op outcomes observable downstream.

    M8/M9: Cross-cutting module enumeration treats root-level files as a
    virtual `<root>` module and folds dotfile-prefixed top-level dirs
    (`.github`, `.claude`, `.tmp`, etc.) into a virtual `<infra>` module.

    M12: AC cross-check no longer short-circuits criterion evaluation;
    matched_criteria is always populated before the ac_precedence verdict
    override fires.
#>

function Test-SCriterionNewAbstraction {
    param(
        [hashtable]$Finding,
        [string[]]$PrFileSet,
        [string]$RepoRoot
    )
    $matched = $false
    $reason = ""

    # M5: verb anchor + tightened noun set; "function" dropped.
    $abstractionPattern = '(?i)\b(?:introduce|create|add|propose|define)\s+(?:a\s+|the\s+)?new\s+(file|agent|skill|module|abstraction|class|interface|component|api)\b'
    if ($Finding.text -match $abstractionPattern) {
        $matched = $true
        $reason = "S-new-abstraction: Finding text requests a new abstraction: '$($Matches[0])'"
    } elseif ($Finding.files) {
        foreach ($file in $Finding.files) {
            if ($file -match "(?i)^agents/.*\.md$" -or $file -match "(?i)^skills/.*\.md$" -or $file -match "(?i)^commands/.*\.md$") {
                # M4: resolve against repo root rather than $PWD.
                $resolved = $file
                if ($RepoRoot) {
                    $resolved = Join-Path $RepoRoot $file
                } else {
                    Write-Warning "RepoRoot not resolvable; new-abstraction Test-Path runs against `$PWD."
                }
                if (-not (Test-Path -LiteralPath $resolved)) {
                    $matched = $true
                    $reason = "S-new-abstraction: Finding references a potentially new agent or skill file: $file"
                    break
                }
            }
        }
    } else {
        # M7: text-only finding with no file list — observable no-op.
        $reason = "skipped: finding text empty; no files to evaluate"
    }

    return @{ matched = $matched; criterion_id = 'S-new-abstraction'; evidence = $reason }
}

function Test-SCriterionCrossCutting {
    param(
        [hashtable]$Finding,
        [string[]]$PrFileSet,
        [string]$RepoRoot
    )
    $matched = $false
    $reason = ""

    if (-not $Finding.files -or @($Finding.files).Count -eq 0) {
        # M7
        return @{ matched = $false; criterion_id = 'S-cross-cutting'; evidence = "skipped: finding text empty; no files to evaluate" }
    }

    # Filter out docs-only and test-only files
    $validFiles = @()
    foreach ($file in $Finding.files) {
        $isDoc = ($file -match "(?i)^Documents/") -or (($file -match "(?i)\.md$") -and ($file -notmatch "(?i)^(agents|skills|commands|hooks)/"))
        $isTest = ($file -match "(?i)/Tests/") -or ($file -match "(?i)\.Tests\.ps1$") -or ($file -match "(?i)\.test\.[tj]sx?$") -or ($file -match "(?i)\.spec\.[tj]sx?$")

        if (-not $isDoc -and -not $isTest) {
            $validFiles += $file
        }
    }

    # Module count check.
    # M8: root-level files become a virtual <root> module rather than being dropped.
    # M9: dotfile-prefixed top-level dirs collapse into a virtual <infra> module.
    $modules = @{}
    foreach ($file in $validFiles) {
        $normalized = $file.Replace('\', '/')
        $parts = $normalized.Split('/')
        $top = $null
        if ($parts.Count -le 1 -or $parts[0] -eq "") {
            $top = '<root>'
        } else {
            $top = $parts[0]
            if ($top -like '.*') { $top = '<infra>' }
        }
        $modules[$top] = $true
    }
    $moduleCount = $modules.Keys.Count

    if ($moduleCount -ge 4) {
        $matched = $true
        $reason = "S-cross-cutting: Touches files across $moduleCount modules: $($modules.Keys -join ', ')"
    } else {
        # Layer crossing check (agents, skills, commands)
        $layers = @{}
        foreach ($file in $validFiles) {
            $normalized = $file.Replace('\', '/')
            $parts = $normalized.Split('/')
            if ($parts.Count -gt 1) {
                $dir = $parts[0]
                if ($dir -eq "agents" -or $dir -eq "skills" -or $dir -eq "commands") {
                    $layers[$dir] = $true
                }
            }
        }
        if ($layers.Keys.Count -ge 2) {
            $matched = $true
            $reason = "S-cross-cutting: Crosses architecture layer boundaries: $($layers.Keys -join ' and ')"
        }
    }

    return @{ matched = $matched; criterion_id = 'S-cross-cutting'; evidence = $reason }
}

function Test-SCriterionDesignDecision {
    param(
        [hashtable]$Finding,
        [string[]]$PrFileSet,
        [string]$RepoRoot
    )
    $matched = $false
    $reason = ""

    if ($Finding.text -match "(?i)(design decision|trade-off|rejected alternative|load-bearing decision|named-decisions)") {
        $matched = $true
        $reason = "S-design-decision: Finding references a design decision or trade-off: '$($Matches[0])'"
    }

    return @{ matched = $matched; criterion_id = 'S-design-decision'; evidence = $reason }
}

function Test-SCriterionSchemaOrContract {
    param(
        [hashtable]$Finding,
        [string[]]$PrFileSet,
        [string]$RepoRoot
    )
    $matched = $false
    $reason = ""

    $textMatched = $false
    if ($Finding.text -match "(?i)(data model|schema|contract|persisted schema|interface contract|api contract)") {
        $textMatched = $true
        $matched = $true
        $reason = "S-schema-or-contract: Finding references schema or interface contract: '$($Matches[0])'"
    }

    if (-not $matched) {
        if (-not $Finding.files -or @($Finding.files).Count -eq 0) {
            # M7
            return @{ matched = $false; criterion_id = 'S-schema-or-contract'; evidence = "skipped: finding text empty; no files to evaluate" }
        }

        foreach ($file in $Finding.files) {
            if ($file -match "(?i)(/Tests/|\.Tests\.ps1$)") { continue }
            $normalized = $file.Replace('\', '/')

            # M6: always-trip extensions — .proto and .sql are inherently contracts.
            if ($normalized -match "(?i)\.(proto|sql)$") {
                $matched = $true
                $reason = "S-schema-or-contract: Finding touches an inherent contract file: $file"
                break
            }

            # M6: schema/contract directories.
            if ($normalized -match "(?i)(^|/)(data|schemas|contracts)/") {
                $matched = $true
                $reason = "S-schema-or-contract: Finding touches a schema/data/contract directory: $file"
                break
            }

            # M6: filename hints.
            $leaf = [System.IO.Path]::GetFileName($normalized)
            if ($leaf -match "(?i)(schema|contract|manifest|config|policy)" -and $normalized -match "(?i)\.(json|yaml|yml|xml)$") {
                $matched = $true
                $reason = "S-schema-or-contract: Finding touches a schema/contract-named file: $file"
                break
            }
            # Plain .json/.yaml/.yml/.xml outside data/schemas/contracts no longer trip on extension alone (M6).
        }
    }

    return @{ matched = $matched; criterion_id = 'S-schema-or-contract'; evidence = $reason }
}

function Test-SCriterionDifferentSurface {
    param(
        [hashtable]$Finding,
        [string[]]$PrFileSet,
        [string]$RepoRoot
    )
    $matched = $false
    $reason = ""

    $findingFiles = @()
    if ($Finding.files) {
        $findingFiles = @($Finding.files) | Where-Object { $_ -ne $null } | ForEach-Object { $_.Replace('\', '/').ToLower() }
    }

    $prFiles = @()
    if ($PrFileSet) {
        $prFiles = @($PrFileSet) | Where-Object { $_ -ne $null } | ForEach-Object { $_.Replace('\', '/').ToLower() }
    }

    if ($findingFiles.Count -gt 0) {
        $disjoint = $true
        foreach ($f in $findingFiles) {
            if ($prFiles -contains $f) {
                $disjoint = $false
                break
            }
        }
        if ($disjoint) {
            $matched = $true
            $reason = "S-different-surface: Finding files are entirely disjoint from PR files."
        }
    } else {
        # M7
        $reason = "skipped: finding text empty; no files to evaluate"
    }

    return @{ matched = $matched; criterion_id = 'S-different-surface'; evidence = $reason }
}

function Test-SCriterionMaintainerJudgment {
    param(
        [hashtable]$Finding,
        [string[]]$PrFileSet,
        [string]$RepoRoot
    )
    $matched = $false
    $reason = ""

    if ($Finding.text -match "(?i)(requires multi-session investigation|requires infra/CI change|explicit maintainer carve-out)") {
        $matched = $true
        $reason = "S-maintainer-judgment: Maintainer explicitly defers with reason: '$($Matches[0])'"
    }

    return @{ matched = $matched; criterion_id = 'S-maintainer-judgment'; evidence = $reason }
}

function Get-StructuralVerdict {
    param(
        [hashtable]$Finding,
        [string[]]$PrFileSet,
        [string[]]$AcRefs,
        [string]$RepoRoot,
        [PSCustomObject[]]$AcTerms = @()
    )

    # M4: resolve repo root once if not supplied; predicates forward it.
    if (-not $RepoRoot) {
        try {
            $RepoRoot = (git rev-parse --show-toplevel 2>$null)
        } catch {
            $RepoRoot = $null
        }
    }

    # M12: ALWAYS evaluate all six S-criteria first to collect matched_criteria,
    # so AC precedence becomes a verdict override that preserves criterion
    # information for D7 calibration.

    $matchedCriteria = @()
    $reasons = @()

    $resNew = Test-SCriterionNewAbstraction -Finding $Finding -PrFileSet $PrFileSet -RepoRoot $RepoRoot
    if ($resNew.matched) { $matchedCriteria += $resNew.criterion_id; $reasons += $resNew.evidence }

    $resCross = Test-SCriterionCrossCutting -Finding $Finding -PrFileSet $PrFileSet -RepoRoot $RepoRoot
    if ($resCross.matched) { $matchedCriteria += $resCross.criterion_id; $reasons += $resCross.evidence }

    $resDesign = Test-SCriterionDesignDecision -Finding $Finding -PrFileSet $PrFileSet -RepoRoot $RepoRoot
    if ($resDesign.matched) { $matchedCriteria += $resDesign.criterion_id; $reasons += $resDesign.evidence }

    $resSchema = Test-SCriterionSchemaOrContract -Finding $Finding -PrFileSet $PrFileSet -RepoRoot $RepoRoot
    if ($resSchema.matched) { $matchedCriteria += $resSchema.criterion_id; $reasons += $resSchema.evidence }

    $resDiff = Test-SCriterionDifferentSurface -Finding $Finding -PrFileSet $PrFileSet -RepoRoot $RepoRoot
    if ($resDiff.matched) { $matchedCriteria += $resDiff.criterion_id; $reasons += $resDiff.evidence }

    $resMaint = Test-SCriterionMaintainerJudgment -Finding $Finding -PrFileSet $PrFileSet -RepoRoot $RepoRoot
    if ($resMaint.matched) { $matchedCriteria += $resMaint.criterion_id; $reasons += $resMaint.evidence }

    # --- ARM 1: File-path intersection (M12, existing behavior preserved) ---
    $fileArmMatched = $false
    $fileArmAcRef = $null
    if ($AcRefs -and $Finding.files) {
        $findingFiles = @($Finding.files) | ForEach-Object { $_.Replace('\', '/').ToLower() }
        $normalizedAc = @($AcRefs) | ForEach-Object { $_.Replace('\', '/').ToLower() }
        $acIntersection = @($findingFiles | Where-Object { $normalizedAc -contains $_ })
        if ($acIntersection.Count -gt 0) {
            $fileArmMatched = $true
            $fileArmAcRef = ($AcRefs | Where-Object {
                $_.Replace('\', '/').ToLower() -in $findingFiles
            } | Select-Object -First 1)
        }
    }

    # --- ARM 2: Term-based matching (new, requires -AcTerms) ---
    $termArmMatched = $false
    $termArmHighConfidence = $false
    $termArmAcRef = $null
    $findingText = if ($Finding.text) { $Finding.text } else { '' }

    if ($AcTerms -and $AcTerms.Count -gt 0 -and $findingText) {
        foreach ($entry in $AcTerms) {
            if (-not $entry.term) { continue }
            # Case-insensitive word-boundary match of the term in the finding text
            if ($findingText -match "(?i)\b$([regex]::Escape($entry.term))\b") {
                $termArmMatched = $true
                if (-not $termArmAcRef) { $termArmAcRef = $entry.source_ac_line }
                if ($entry.is_behavioral) {
                    $termArmHighConfidence = $true
                    break  # High-confidence: stop at first behavioral hit
                }
                # Non-behavioral: keep scanning for a behavioral hit
            }
        }
    }

    # --- Determine result / routing ---
    # High-confidence: file-path intersection OR behavioral term match -> force-accept
    # Ambiguous: non-behavioral term match only -> disposition-gate (verdict unchanged)
    # No match: -> defer (verdict follows S-criteria normally)
    $acCheckResult = 'no-match'
    $acRouted = 'defer'
    if ($fileArmMatched -or $termArmHighConfidence) {
        $acCheckResult = 'matched-high'
        $acRouted = 'force-accept'
    } elseif ($termArmMatched) {
        $acCheckResult = 'matched-ambiguous'
        $acRouted = 'disposition-gate'
    }

    # Determine ac_ref and source
    $acRef = $null
    if ($fileArmMatched -and $fileArmAcRef) { $acRef = $fileArmAcRef }
    elseif ($termArmMatched -and $termArmAcRef) { $acRef = $termArmAcRef }

    $acSource = 'issue'
    if ((-not $AcRefs -or $AcRefs.Count -eq 0) -and (-not $AcTerms -or $AcTerms.Count -eq 0)) {
        $acSource = 'no-ac-section'
    }

    $acCrossCheck = @{
        file_arm = $fileArmMatched
        term_arm = $termArmMatched
        result   = $acCheckResult
        ac_ref   = $acRef
        source   = $acSource
        routed   = $acRouted
    }

    if ($acRouted -eq 'force-accept') {
        return @{
            verdict          = 'ACCEPT (fix inline)'
            matched_criteria = $matchedCriteria
            ac_precedence    = $true
            rationale        = "AC Cross-Check Precedence: Finding relates to an explicit acceptance criterion."
            evidence         = 'AC cross-check overrode structural verdict; matched_criteria preserved'
            ac_cross_check   = $acCrossCheck
        }
    }

    if ($matchedCriteria.Count -gt 0) {
        return @{
            verdict          = 'DEFERRED-SIGNIFICANT (structural)'
            matched_criteria = $matchedCriteria
            ac_precedence    = $false
            rationale        = $reasons -join "; "
            ac_cross_check   = $acCrossCheck
        }
    } else {
        return @{
            verdict          = 'ACCEPT (fix inline)'
            matched_criteria = @()
            ac_precedence    = $false
            rationale        = "No structural criteria matched."
            ac_cross_check   = $acCrossCheck
        }
    }
}
