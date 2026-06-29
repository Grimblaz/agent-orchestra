#Requires -Version 7.0
<#
.SYNOPSIS
    CE Gate verification script for issue #762 — phase-containment escape-rate ledger.
.DESCRIPTION
    Exercises the rollup + display logic with controlled fixture entries to verify
    AC3, AC4, AC8, and AC12 without a live GitHub API call.

    Fixture scenarios:
      code-review      : 4 entries (n=4 < 5)    → INSUFFICIENT DATA        (AC8)
      plan-stress-test : 6 clean entries (n=6)   → EscapeRate=0, ELIGIBLE   (AC3/AC4)
      design-challenge : 7 entries, 2 escaped    → EscapeRate≈0.286, NOT ELIGIBLE (AC4/AC12)
      experience-catchable : 1 entry             → leakage matrix only, no stage bucket

    The four code-review entries mirror the provenance of the s5 seed entries
    posted to issue #760 for PR #765.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot  = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
$libDir    = Join-Path $repoRoot '.github' 'scripts' 'lib'

. (Join-Path $libDir 'phase-containment-core.ps1')
. (Join-Path $libDir 'phase-containment-rolling-history-core.ps1')

# ── Fixture entries ──────────────────────────────────────────────────────────────────────────

$entries = [System.Collections.Generic.List[hashtable]]::new()

# code-review bucket (catchable_phase=implementation, n=4 → InsufficientData)
foreach ($pair in @(
    @{ key='code-review:4832813258'; intro='design';         sev='high';   fix='instruction'; cat='pattern'               },
    @{ key='code-review:4832813940'; intro='implementation'; sev='medium'; fix='instruction'; cat='implementation-clarity' },
    @{ key='code-review:4832814488'; intro='plan';           sev='medium'; fix='skill';       cat='documentation-audit'   },
    @{ key='code-review:4832815057'; intro='design';         sev='medium'; fix='instruction'; cat='documentation-audit'   }
)) {
    $entries.Add(@{
        finding_key       = $pair.key
        introduced_phase  = $pair.intro
        catchable_phase   = 'implementation'
        caught_stage      = 'code-review'
        escape_distance   = 0
        severity          = $pair.sev
        systemic_fix_type = $pair.fix
        category          = $pair.cat
        apparatus_meta    = $false
        seed              = $true
    })
}

# plan-stress-test bucket (catchable_phase=plan, n=6, all escape_distance=0 → RelaxationEligible)
for ($i = 1; $i -le 6; $i++) {
    $entries.Add(@{
        finding_key       = "plan-stress-test:762:plan-issue-762:P$i"
        introduced_phase  = 'design'
        catchable_phase   = 'plan'
        caught_stage      = 'plan-stress-test'
        escape_distance   = 0
        severity          = 'low'
        systemic_fix_type = 'skill'
        category          = 'architecture'
        apparatus_meta    = $false
        seed              = $false
    })
}

# design-challenge bucket (catchable_phase=design, n=7, 2 escaped → EscapeRate≈0.286)
# 5 caught at design-challenge (escape_distance=0)
for ($i = 1; $i -le 5; $i++) {
    $entries.Add(@{
        finding_key       = "design-challenge:762:design-phase-complete-762:F$i"
        introduced_phase  = 'design'
        catchable_phase   = 'design'
        caught_stage      = 'design-challenge'
        escape_distance   = 0
        severity          = 'low'
        systemic_fix_type = 'none'
        category          = 'pattern'
        apparatus_meta    = $false
        seed              = $false
    })
}
# 2 escaped design-challenge, caught at code-review (escape_distance = projection(code-review=3) - ordinal(design=1) = 2)
for ($i = 1; $i -le 2; $i++) {
    $entries.Add(@{
        finding_key       = "code-review:762:escaped-design-$i"
        introduced_phase  = 'design'
        catchable_phase   = 'design'
        caught_stage      = 'code-review'
        escape_distance   = 2
        severity          = 'high'
        systemic_fix_type = 'skill'
        category          = 'architecture'
        apparatus_meta    = $false
        seed              = $false
    })
}

# experience-catchable (leakage matrix only, no stage bucket)
$entries.Add(@{
    finding_key       = 'code-review:762:experience-catchable-1'
    introduced_phase  = 'experience'
    catchable_phase   = 'experience'
    caught_stage      = 'code-review'
    escape_distance   = 3
    severity          = 'low'
    systemic_fix_type = 'skill'
    category          = 'pattern'
    apparatus_meta    = $false
    seed              = $false
})

# ── Compute rollup ───────────────────────────────────────────────────────────────────────────

$rollup = Get-PhaseContainmentRollup -Entries $entries.ToArray() -WindowLabel '90d'

# ── Render report (same display logic as phase-containment-report.ps1) ───────────────────────

$lines = [System.Collections.Generic.List[string]]::new()
$lines.Add('')
$lines.Add('Phase-Containment Escape-Rate Ledger')
$lines.Add("Window: 90d | Source: fixture | Entries: $($entries.Count)")
$lines.Add("Total entries processed: $($rollup.WindowEntryCount) | Apparatus-meta entries: $($rollup.ApparatusMetaCount)")
$lines.Add('')

$stageOrder = @('design-challenge', 'plan-stress-test', 'code-review')
foreach ($stageName in $stageOrder) {
    $stage = $rollup.Stages[$stageName]
    $catchableLabel = switch ($stageName) {
        'design-challenge' { 'catchable=design' }
        'plan-stress-test' { 'catchable=plan' }
        'code-review'      { 'catchable=implementation' }
    }
    $lines.Add("Stage: $stageName")
    $lines.Add("  Denominator ($catchableLabel): $($stage.Denominator)")

    if ($stage.DataUntrustworthy) {
        $lines.Add("  DATA UNTRUSTWORTHY -- relaxation signal withheld (entry count mismatch)")
    }

    if ($stage.DenominatorZero) {
        $lines.Add("  Escape rate:        N/A (denominator=0)")
        $lines.Add("  Irreducible rate:   N/A")
        $lines.Add("  Relaxation signal:  WITHHELD (denominator=0)")
    }
    elseif ($stage.InsufficientData) {
        $lines.Add("  Escape rate:        INSUFFICIENT DATA (n=$($stage.N) < 5)")
        $lines.Add("  Irreducible rate:   INSUFFICIENT DATA")
        $lines.Add("  Relaxation signal:  WITHHELD (n<5)")
    }
    elseif ($stage.DataUntrustworthy) {
        $lines.Add("  Escape rate:        N/A (data untrustworthy)")
        $lines.Add("  Irreducible rate:   N/A")
        $lines.Add("  Relaxation signal:  WITHHELD (data untrustworthy)")
    }
    else {
        $escapeCount      = [int][Math]::Round($stage.EscapeRate      * $stage.Denominator)
        $irreducibleCount = [int][Math]::Round($stage.IrreducibleRate * $stage.Denominator)
        $escapeDisplay      = '{0:F2} ({1} of {2} escaped)' -f $stage.EscapeRate, $escapeCount, $stage.Denominator
        $irreducibleDisplay = '{0:F2} ({1} of {2} irreducible)' -f $stage.IrreducibleRate, $irreducibleCount, $stage.Denominator
        $lines.Add("  Escape rate:        $escapeDisplay")
        $lines.Add("  Irreducible rate:   $irreducibleDisplay")
        if ($null -eq $stage.RelaxationEligible) {
            $lines.Add("  Relaxation signal:  WITHHELD")
        }
        elseif ($stage.RelaxationEligible -eq $true) {
            $lines.Add("  Relaxation signal:  ELIGIBLE (escape_rate ~0, no critical findings)")
        }
        else {
            if ($stage.EscapeRate -ge 0.05) {
                $lines.Add("  Relaxation signal:  NOT ELIGIBLE (escape_rate > 0)")
            }
            else {
                $lines.Add("  Relaxation signal:  NOT ELIGIBLE (critical severity finding in window)")
            }
        }
    }
    $lines.Add('')
}

# Leakage matrix
$leakageMatrix = $rollup.LeakageMatrix
if ($leakageMatrix.Count -gt 0) {
    $lines.Add('Leakage matrix (introduced x caught combinations):')
    $sorted = $leakageMatrix.GetEnumerator() | Sort-Object { -$_.Value }, { $_.Key }
    foreach ($pair in $sorted) {
        $lines.Add(('  {0,-45} {1} findings' -f "$($pair.Key -replace [char]0x00D7, ' -> '):", $pair.Value))
    }
}
else {
    $lines.Add('Leakage matrix: (no entries in window)')
}
$lines.Add('')

$reportText = $lines -join "`n"
$lines | ForEach-Object { Write-Output $_ }

# ── Assertions ───────────────────────────────────────────────────────────────────────────────

Write-Output '════════════════════════════════════════════════════════'
Write-Output 'CE Gate Assertions'
Write-Output '════════════════════════════════════════════════════════'

$pass = $true
function Assert-Contains {
    param([string]$Label, [string]$Literal)
    if ($script:reportText.Contains($Literal)) {
        Write-Output "  PASS  $Label"
    }
    else {
        Write-Output "  FAIL  $Label"
        Write-Output "        Expected: $Literal"
        $script:pass = $false
    }
}

# AC8 — n<5 withholds signal (code-review stage, n=4)
Assert-Contains 'AC8  code-review: INSUFFICIENT DATA label'  'INSUFFICIENT DATA (n=4 < 5)'
Assert-Contains 'AC8  code-review: relaxation WITHHELD'      'WITHHELD (n<5)'

# AC4 — escape rate computed correctly (plan-stress-test: 0 of 6 escaped)
Assert-Contains 'AC4  plan-stress-test: EscapeRate=0.00'     'Escape rate:        0.00 (0 of 6 escaped)'

# AC3 — relaxation ELIGIBLE (plan-stress-test: clean, n=6, no critical)
Assert-Contains 'AC3  plan-stress-test: ELIGIBLE signal'     'ELIGIBLE (escape_rate ~0, no critical findings)'

# AC4 — escape rate computed correctly (design-challenge: 2 of 7 escaped, ≈0.29)
Assert-Contains 'AC4  design-challenge: EscapeRate≈0.29'     'Escape rate:        0.29 (2 of 7 escaped)'

# AC12 — NOT ELIGIBLE label (design-challenge has escape_rate > 0.05)
Assert-Contains 'AC12 design-challenge: NOT ELIGIBLE label'  'NOT ELIGIBLE (escape_rate > 0)'

# AC12 — leakage matrix rendered
Assert-Contains 'AC12 leakage matrix header rendered'        'Leakage matrix (introduced x caught combinations):'

# AC12 — denominator per stage in output
Assert-Contains 'AC12 code-review denominator shown'         'Denominator (catchable=implementation): 4'
Assert-Contains 'AC12 plan-stress-test denominator shown'    'Denominator (catchable=plan): 6'
Assert-Contains 'AC12 design-challenge denominator shown'    'Denominator (catchable=design): 7'

Write-Output ''
if ($pass) {
    Write-Output 'CE Gate result: PASS — all AC3/AC4/AC8/AC12 assertions satisfied'
    exit 0
}
else {
    Write-Output 'CE Gate result: FAIL — one or more assertions failed (see above)'
    exit 1
}
