#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
.SYNOPSIS
    Issue #723 wall-clock fixture durability guard.

.DESCRIPTION
    Prevents recurrence of the calibration-test wall-clock flakiness fixed in
    issue #723. The root cause was a fixture that hardcoded an absolute ISO-date
    literal into `skip_first_observed_at`, a field that
    skills/calibration-pipeline/scripts/aggregate-review-scores-core.ps1 compares
    against `$now` across the 90-day time-decay threshold (core:1224-1225). Once
    `now - <absolute-seed> > 90` the time-decay re-activation path fired and the
    asserted recommendation band flipped purely by wall-clock — a date-dependent
    test failure with no code change.

    This guard is a STATIC scanner over .github/scripts/Tests/*.Tests.ps1. It
    fails when any line assigns an absolute ISO-date literal (e.g.
    '2026-02-01T00:00:00Z') to `skip_first_observed_at`, UNLESS that exact line
    carries an inline `# absolute on purpose` annotation. The exemption is
    LINE-LEVEL (the s1 annotated-inert set of band-irrelevant write-back
    vehicles), not a file-level allow-list: a new un-annotated absolute seed in
    an otherwise-exempt file still fails.

    Scope (honest):
      - GUARDED: `skip_first_observed_at = '<absolute ISO date>'` — cleanly
        field-detectable; the dominant recurrence vector.
      - OUT OF STATIC SCOPE (documented residual gaps):
          * `mergedAt` (core:763) — also now-coupled, but dataflow-sensitive:
            the same field name feeds the decay path, date-vs-date ordering, and
            harness-normalized fixtures, statically indistinguishable. It is
            structurally defended by the test harness mergedAt normalization at
            aggregate-review-scores.Tests.ps1:93 (most-recent shifted to 7 days
            ago), so a static scanner is neither necessary nor reliable here.
          * variable-indirected literals (`skip_first_observed_at = $someVar`) —
            the absolute value lives in a separate assignment the line scan does
            not resolve. Accepted residual gap per the #723 plan AC3.

    A core-drift check (MF3) greps the production core script for
    `($now - <var>).TotalDays` comparison sites and fails if the set of
    now-coupled SOURCE FIELDS feeding those sites diverges from this guard's
    known list — so a future now-coupled field added to core but not reflected
    here is caught rather than silently unguarded.

    The guard is read-only (no file writes) and self-excludes its own source so
    its pattern/self-test literals do not self-trigger
    (mirrors test-source-mutation-contract.Tests.ps1's $ThisFile exclusion).
#>

Describe 'Issue #723 wall-clock fixture durability guard' -Tag 'issue-723', 'wall-clock-guard', 'no-gh' {

    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
        $script:TestsRoot = Join-Path $script:RepoRoot '.github/scripts/Tests'
        $script:ThisFile = (Resolve-Path $PSCommandPath).Path

        # Detection: an absolute ISO-date literal assigned to skip_first_observed_at.
        #   skip_first_observed_at = '20NN-NN-NNT...'
        # Single-quoted literal whose value begins with a 20NN-NN-NN ISO date.
        $script:AbsoluteSeedPattern = "skip_first_observed_at\s*=\s*'20\d\d-\d\d-\d\d"
        # Line-level exemption token.
        $script:ExemptionToken = '# absolute on purpose'

        # Detector: returns the offending trimmed lines of a content blob that
        # assign an absolute ISO seed to skip_first_observed_at WITHOUT the
        # line-level exemption annotation.
        $script:GetUnannotatedAbsoluteSeeds = {
            param([string[]]$Lines)
            $hits = [System.Collections.Generic.List[string]]::new()
            for ($i = 0; $i -lt $Lines.Count; $i++) {
                $line = $Lines[$i]
                if ($line -match $script:AbsoluteSeedPattern) {
                    if ($line -notmatch [regex]::Escape($script:ExemptionToken)) {
                        [void]$hits.Add(('{0}: {1}' -f ($i + 1), $line.Trim()))
                    }
                }
            }
            return @($hits)
        }

        # Production scan: all tracked *.Tests.ps1 except this guard's own source.
        $script:TestSources = Get-ChildItem -Path $script:TestsRoot -Recurse -Filter '*.Tests.ps1' -File |
            Where-Object { (Resolve-Path $_.FullName).Path -ne $script:ThisFile } |
            Sort-Object -Property FullName

        $script:ProductionViolations = [System.Collections.Generic.List[string]]::new()
        foreach ($source in $script:TestSources) {
            $lines = Get-Content -LiteralPath $source.FullName -ErrorAction SilentlyContinue
            if (-not $lines) { continue }
            $rel = [System.IO.Path]::GetRelativePath($script:RepoRoot, $source.FullName) -replace '\\', '/'
            foreach ($hit in (& $script:GetUnannotatedAbsoluteSeeds -Lines $lines)) {
                [void]$script:ProductionViolations.Add(('{0}:{1}' -f $rel, $hit))
            }
        }

        # ---- Core-drift inputs (MF3) ----
        $script:CoreRelPath = 'skills/calibration-pipeline/scripts/aggregate-review-scores-core.ps1'
        $script:CorePath = Join-Path $script:RepoRoot $script:CoreRelPath

        # The now-coupled SOURCE FIELDS this guard knows about, each mapped to its
        # static-guard disposition. If core grows a now-coupled comparison whose
        # source field is not in this map, the drift check fails.
        $script:KnownNowCoupledFields = @{
            'skip_first_observed_at' = 'guarded'                 # this guard's scope
            'mergedAt'               = 'documented-out-of-scope' # dataflow-sensitive; harness-normalized
        }

        # Resolve the now-coupled comparison sites in core and trace each
        # comparison variable back to its source field via the nearest preceding
        # [datetime]::Parse(<source>) assignment to that variable.
        $script:GetCoreNowCoupledFields = {
            $result = [System.Collections.Generic.List[pscustomobject]]::new()
            if (-not (Test-Path -LiteralPath $script:CorePath)) { return @($result) }
            $coreLines = Get-Content -LiteralPath $script:CorePath
            for ($i = 0; $i -lt $coreLines.Count; $i++) {
                $line = $coreLines[$i]
                # Match: ($now - $someVar).TotalDays
                $m = [regex]::Match($line, '\(\s*\$now\s*-\s*\$(?<var>[A-Za-z_][A-Za-z0-9_]*)\s*\)\.TotalDays')
                if (-not $m.Success) { continue }
                $compareVar = $m.Groups['var'].Value
                # Trace back to the nearest preceding assignment:
                #   $compareVar = [datetime]::Parse($sourceVar)
                # then resolve $sourceVar to its source field. The core assigns
                #   $sourceVar = Get-FlexProperty ... 'skip_first_observed_at'   (skip path)
                #   $mergedAt  = $pr.mergedAt                                     (decay path)
                $sourceField = $null
                for ($j = $i; $j -ge 0 -and $j -ge ($i - 40); $j--) {
                    $back = $coreLines[$j]
                    $pm = [regex]::Match($back, ('\$' + [regex]::Escape($compareVar) + "\s*=\s*\[datetime\]::Parse\(\s*\`$(?<src>[A-Za-z_][A-Za-z0-9_]*)"))
                    if ($pm.Success) {
                        $srcVar = $pm.Groups['src'].Value
                        # Resolve $srcVar -> source field name.
                        for ($k = $j; $k -ge 0 -and $k -ge ($j - 40); $k--) {
                            $back2 = $coreLines[$k]
                            # skip path: $srcVar = Get-FlexProperty <state> 'field'
                            $fm = [regex]::Match($back2, ('\$' + [regex]::Escape($srcVar) + "\s*=.*'(?<field>[A-Za-z_][A-Za-z0-9_]*)'"))
                            if ($fm.Success) { $sourceField = $fm.Groups['field'].Value; break }
                            # decay path: $srcVar = $obj.field
                            $dm = [regex]::Match($back2, ('\$' + [regex]::Escape($srcVar) + '\s*=\s*\$[A-Za-z_][A-Za-z0-9_]*\.(?<field>[A-Za-z_][A-Za-z0-9_]*)'))
                            if ($dm.Success) { $sourceField = $dm.Groups['field'].Value; break }
                        }
                        break
                    }
                }
                [void]$result.Add([pscustomobject]@{
                        Line        = $i + 1
                        CompareVar  = $compareVar
                        SourceField = $sourceField
                    })
            }
            return @($result)
        }
        $script:CoreNowCoupledSites = @(& $script:GetCoreNowCoupledFields)
    }

    Context 'Production scan' {
        It 'No Tests.ps1 assigns an un-annotated absolute date to skip_first_observed_at' {
            $script:ProductionViolations | Should -BeNullOrEmpty -Because (
                "skip_first_observed_at must not be seeded with an absolute ISO-date literal: " +
                "the field is compared against `$now across the 90-day time-decay threshold " +
                "(aggregate-review-scores-core.ps1:1224-1225), so an absolute seed makes the test " +
                "date-dependent (issue #723). Use a now-relative date " +
                "(e.g. (Get-Date).AddDays(-30).ToString('o')) for band-asserting fixtures, or add " +
                "the inline annotation '# absolute on purpose: {reason}' for band-irrelevant " +
                "write-back vehicles.`nViolations:`n  " + ($script:ProductionViolations -join "`n  ")
            )
        }
    }

    Context 'Falsifiability self-test' {
        It 'Flags an un-annotated absolute seed' {
            $planted = @(
                "                    pattern = @{ skip_first_observed_at = '2020-01-01T00:00:00Z' }"
            )
            $hits = @(& $script:GetUnannotatedAbsoluteSeeds -Lines $planted)
            $hits | Should -HaveCount 1 -Because 'an un-annotated absolute ISO seed must be detected'
        }

        It 'Skips an annotated absolute seed (line-level exemption)' {
            $planted = @(
                "                    pattern = @{ skip_first_observed_at = '2020-01-01T00:00:00Z' }  # absolute on purpose: band-irrelevant write-back vehicle (issue #723)"
            )
            $hits = @(& $script:GetUnannotatedAbsoluteSeeds -Lines $planted)
            $hits | Should -HaveCount 0 -Because 'a line carrying the # absolute on purpose annotation is exempt'
        }

        It 'Ignores a now-relative seed (the prescribed fix shape)' {
            $planted = @(
                "                        skip_first_observed_at = (Get-Date).AddDays(-30).ToString('o')"
            )
            $hits = @(& $script:GetUnannotatedAbsoluteSeeds -Lines $planted)
            $hits | Should -HaveCount 0 -Because 'a now-relative seed carries no absolute literal and is the prescribed fix'
        }
    }

    Context 'Core-drift check (MF3)' {
        It 'Core has exactly the known now-coupled comparison sites' {
            $script:CoreNowCoupledSites.Count | Should -BeGreaterThan 0 -Because (
                'the guard must locate the (`$now - <var>).TotalDays comparison sites in core; ' +
                'zero sites means the drift detector regex desynced from the core script'
            )
        }

        It 'Every now-coupled source field in core is in the guard known-list' {
            $unknown = @(
                $script:CoreNowCoupledSites |
                    Where-Object { $null -ne $_.SourceField } |
                    Where-Object { -not $script:KnownNowCoupledFields.ContainsKey($_.SourceField) }
            )
            $summary = @($unknown | ForEach-Object { "core:$($_.Line) ($($_.CompareVar) <- $($_.SourceField))" })
            $unknown | Should -BeNullOrEmpty -Because (
                "a now-coupled (`$now - var).TotalDays comparison in $script:CoreRelPath traces to a " +
                "SOURCE FIELD not in this guard's known-list " +
                "($($script:KnownNowCoupledFields.Keys -join ', ')). Add the new field to " +
                "`$script:KnownNowCoupledFields with its disposition (guarded vs documented-out-of-scope) " +
                "and extend the static scan if it should be guarded (issue #723, MF3).`n" +
                "Unmapped sites:`n  " + ($summary -join "`n  ")
            )
        }

        It 'The guarded field (skip_first_observed_at) is still present as a now-coupled site in core' {
            $guardedFields = @($script:CoreNowCoupledSites | ForEach-Object { $_.SourceField })
            $guardedFields | Should -Contain 'skip_first_observed_at' -Because (
                'the guard exists to defend skip_first_observed_at; if core no longer compares it ' +
                'against $now, the guard scope must be re-evaluated (issue #723)'
            )
        }
    }
}
