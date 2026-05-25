#Requires -Version 7.0
<#
.SYNOPSIS
    Evaluates whether a code review finding should be deferred to a follow-up issue
    based on six structural criteria instead of effort estimates.

.DESCRIPTION
    Implementation for D1 structural-criteria gate.
#>

function Test-SCriterionNewAbstraction {
    param(
        [hashtable]$Finding,
        [string[]]$PrFileSet
    )
    $matched = $false
    $reason = ""

    if ($Finding.text -match "(?i)new\s+(file|agent|skill|module|abstraction|class|interface|component|function|api)") {
        $matched = $true
        $reason = "S-new-abstraction: Finding text requests a new abstraction: '$($Matches[0])'"
    } else {
        foreach ($file in $Finding.files) {
            if ($file -match "(?i)^agents/.*\.md$" -or $file -match "(?i)^skills/.*\.md$") {
                # It is a new abstraction if the file path is under agents/ or skills/ but does not exist locally.
                if (-not (Test-Path -LiteralPath $file)) {
                    $matched = $true
                    $reason = "S-new-abstraction: Finding references a potentially new agent or skill file: $file"
                    break
                }
            }
        }
    }

    return @{ matched = $matched; criterion_id = 'S-new-abstraction'; evidence = $reason }
}

function Test-SCriterionCrossCutting {
    param(
        [hashtable]$Finding,
        [string[]]$PrFileSet
    )
    $matched = $false
    $reason = ""

    # Filter out docs-only and test-only files
    $validFiles = @()
    foreach ($file in $Finding.files) {
        # docs-only = starts with Documents/, or ends with .md and is NOT in source directories (agents, skills, commands, hooks)
        $isDoc = ($file -match "(?i)^Documents/") -or (($file -match "(?i)\.md$") -and ($file -notmatch "(?i)^(agents|skills|commands|hooks)/"))
        
        # test-only = matches /Tests/, or ends with .Tests.ps1, .test.js, .spec.ts, etc.
        $isTest = ($file -match "(?i)/Tests/") -or ($file -match "(?i)\.Tests\.ps1$") -or ($file -match "(?i)\.test\.[tj]sx?$") -or ($file -match "(?i)\.spec\.[tj]sx?$")
        
        if (-not $isDoc -and -not $isTest) {
            $validFiles += $file
        }
    }

    # Module count check (unique top-level directories under root)
    $modules = @{}
    foreach ($file in $validFiles) {
        $normalized = $file.Replace('\', '/')
        $parts = $normalized.Split('/')
        if ($parts.Count -gt 1 -and $parts[0] -ne "") {
            $modules[$parts[0]] = $true
        }
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
        [string[]]$PrFileSet
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
        [string[]]$PrFileSet
    )
    $matched = $false
    $reason = ""

    if ($Finding.text -match "(?i)(data model|schema|contract|persisted schema|interface contract|api contract)") {
        $matched = $true
        $reason = "S-schema-or-contract: Finding references schema or interface contract: '$($Matches[0])'"
    } else {
        foreach ($file in $Finding.files) {
            if ($file -match "\.(json|yaml|yml|xml|sql)$" -and $file -notmatch "(?i)(/Tests/|\.Tests\.ps1$)") {
                $matched = $true
                $reason = "S-schema-or-contract: Finding touches a schema/data/contract file: $file"
                break
            }
        }
    }

    return @{ matched = $matched; criterion_id = 'S-schema-or-contract'; evidence = $reason }
}

function Test-SCriterionDifferentSurface {
    param(
        [hashtable]$Finding,
        [string[]]$PrFileSet
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
    }

    return @{ matched = $matched; criterion_id = 'S-different-surface'; evidence = $reason }
}

function Test-SCriterionMaintainerJudgment {
    param(
        [hashtable]$Finding,
        [string[]]$PrFileSet
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
        [string[]]$AcRefs
    )

    # AC2: AC cross-check takes precedence. 
    # If the finding refers to any file matching an AC reference, force ACCEPT (fix inline).
    if ($AcRefs -and $Finding.files) {
        $findingFiles = @($Finding.files) | ForEach-Object { $_.Replace('\', '/').ToLower() }
        $normalizedAc = @($AcRefs) | ForEach-Object { $_.Replace('\', '/').ToLower() }
        $acIntersection = $findingFiles | Where-Object { $normalizedAc -contains $_ }
        if ($acIntersection.Count -gt 0) {
            return @{
                verdict = 'ACCEPT (fix inline)'
                matched_criteria = @()
                rationale = "AC Cross-Check Precedence: Finding relates to an explicit acceptance criterion."
            }
        }
    }

    $matchedCriteria = @()
    $reasons = @()

    $resNew = Test-SCriterionNewAbstraction -Finding $Finding -PrFileSet $PrFileSet
    if ($resNew.matched) { $matchedCriteria += $resNew.criterion_id; $reasons += $resNew.evidence }

    $resCross = Test-SCriterionCrossCutting -Finding $Finding -PrFileSet $PrFileSet
    if ($resCross.matched) { $matchedCriteria += $resCross.criterion_id; $reasons += $resCross.evidence }

    $resDesign = Test-SCriterionDesignDecision -Finding $Finding -PrFileSet $PrFileSet
    if ($resDesign.matched) { $matchedCriteria += $resDesign.criterion_id; $reasons += $resDesign.evidence }

    $resSchema = Test-SCriterionSchemaOrContract -Finding $Finding -PrFileSet $PrFileSet
    if ($resSchema.matched) { $matchedCriteria += $resSchema.criterion_id; $reasons += $resSchema.evidence }

    $resDiff = Test-SCriterionDifferentSurface -Finding $Finding -PrFileSet $PrFileSet
    if ($resDiff.matched) { $matchedCriteria += $resDiff.criterion_id; $reasons += $resDiff.evidence }

    $resMaint = Test-SCriterionMaintainerJudgment -Finding $Finding -PrFileSet $PrFileSet
    if ($resMaint.matched) { $matchedCriteria += $resMaint.criterion_id; $reasons += $resMaint.evidence }

    if ($matchedCriteria.Count -gt 0) {
        return @{
            verdict = 'DEFERRED-SIGNIFICANT (structural)'
            matched_criteria = $matchedCriteria
            rationale = $reasons -join "; "
        }
    } else {
        return @{
            verdict = 'ACCEPT (fix inline)'
            matched_criteria = @()
            rationale = "No structural criteria matched."
        }
    }
}
