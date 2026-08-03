#Requires -Version 7.0

# ci-suite-selection-core.ps1
# Selects which Pester suites CI runs, from a GLOB minus an explicit quarantine.
#
# WHY THIS EXISTS. CI previously carried a hand-maintained allowlist of test
# files. An allowlist makes exclusion the DEFAULT and makes it SILENT: a new
# suite is unprotected the moment it is written, and nothing anywhere notices.
# Measured when this shipped: 52 files registered, 191 not — 4,136 of 5,475
# test blocks never ran in CI, including suites written that same week.
#
# The list was not really an allowlist either. Reading its own comments, most
# exclusions were quarantines ("20 pre-existing Linux-CI failures … tracked in
# issue #904"), written in a form that could not express the difference between
# "temporarily broken" and "never registered".
#
# So the model is inverted: run everything, and require an explicit, classified,
# reasoned entry to opt a file OUT. A file that is neither selected nor
# quarantined fails the guard — the drift can no longer happen quietly.

# NO FILE-SCOPE Set-StrictMode HERE, deliberately.
#
# The workflow dot-sources this file into the SAME session that then calls
# Invoke-Pester. A file-scope Set-StrictMode leaks into that session and into
# every suite the run executes: measured, it turned a 1432/1433 green run into
# 1214/1433 with 218 failures, in suites this change does not touch. The
# repository's other libraries that need strictness set it INSIDE the function
# (see bootstrap-antigravity-core.ps1 and frame-audit-report-core.ps1); the
# ones that set it at file scope are only ever dot-sourced inside a Pester
# BeforeAll, where the blast radius is one file's scope rather than the runner's.
#
# Get-CISuiteSelection sets it in its own scope instead.

#region Get-CISuiteSelection

$script:CIQuarantineClasses = @('unclassified', 'linux-red', 'never-ci')

function Get-CISuiteSelection {
    <#
    .SYNOPSIS
        Partitions the Pester suites on disk into the set CI runs and the set
        it deliberately skips, and reports every way the two can disagree.
    .DESCRIPTION
        THE PROPERTY THIS EXISTS FOR: every `*.Tests.ps1` on disk is either
        SELECTED or QUARANTINED, and a quarantine entry names a file that
        exists. Both halves matter. Without the first, a new suite is silently
        unprotected — the defect this replaces. Without the second, the
        quarantine accumulates entries for deleted files and stops meaning
        anything, which is the same defect wearing the other hat.

        QUARANTINE CLASSES, and why there are three rather than two:

          unclassified — never registered under the old allowlist; whether it
                         is CI-viable has never been measured. This is a
                         BACKLOG, not a decision, and it should shrink to zero.
          linux-red    — measured failing on the CI platform. Temporary by
                         construction, so an issue number is REQUIRED; an entry
                         with no ticket is a drop wearing a quarantine's badge.
          never-ci     — structurally cannot run in CI (needs a live `gh`, a
                         network, an interactive terminal, a real clock). This
                         is permanent and legitimate.

        Collapsing `never-ci` into `linux-red` is what turns a quarantine into
        a graveyard: after a few months most entries are permanent, no entry is
        actionable, and nobody reads the file — which is exactly how the
        allowlist this replaces stopped being read.
    .PARAMETER TestsRoot
        Directory holding the `*.Tests.ps1` files.
    .PARAMETER QuarantinePath
        Path to the quarantine JSON. Its absence is an error, never an empty
        quarantine: silently selecting everything because a config file went
        missing is the fail-open shape this guard exists to prevent.
    .OUTPUTS
        [PSCustomObject] with Selected [string[]] (full paths, sorted),
        SelectedNames [string[]], Quarantined [object[]], Unaccounted
        [string[]] (on disk, neither selected nor quarantined — always empty in
        a healthy tree, since anything not quarantined is selected),
        StaleQuarantine [string[]] (quarantined names with no file on disk),
        InvalidEntries [string[]], UnclassifiedCount [int], HasDrift [bool],
        DriftDetails [string[]].
    #>
    param(
        [Parameter(Mandatory)][string]$TestsRoot,
        [Parameter(Mandatory)][string]$QuarantinePath
    )

    # Function-scoped, not file-scoped — see the note at the top of this file.
    Set-StrictMode -Version Latest

    $driftDetails = [System.Collections.Generic.List[string]]::new()
    $invalid = [System.Collections.Generic.List[string]]::new()

    if (-not (Test-Path -LiteralPath $QuarantinePath)) {
        return [PSCustomObject]@{
            Selected = @(); SelectedNames = @(); Quarantined = @(); Unaccounted = @()
            StaleQuarantine = @(); InvalidEntries = @(); UnclassifiedCount = 0
            HasDrift        = $true
            DriftDetails    = @("ci-suite-selection: quarantine registry '$QuarantinePath' not found. A missing registry is drift, never an empty quarantine — selecting every suite because a config file vanished is the fail-open shape this guard exists to prevent.")
        }
    }

    $raw = Get-Content -Raw -LiteralPath $QuarantinePath
    $parsed = $null
    try { $parsed = $raw | ConvertFrom-Json }
    catch {
        return [PSCustomObject]@{
            Selected = @(); SelectedNames = @(); Quarantined = @(); Unaccounted = @()
            StaleQuarantine = @(); InvalidEntries = @(); UnclassifiedCount = 0
            HasDrift        = $true
            DriftDetails    = @("ci-suite-selection: quarantine registry did not parse as JSON: $($_.Exception.Message)")
        }
    }

    $entries = @()
    if ($null -ne $parsed -and $parsed.PSObject.Properties.Match('quarantine').Count -gt 0) {
        $entries = @($parsed.quarantine)
    }
    else {
        $driftDetails.Add("ci-suite-selection: quarantine registry has no 'quarantine' array.")
    }

    $quarantinedNames = [System.Collections.Generic.List[string]]::new()
    $unclassified = 0
    foreach ($e in $entries) {
        $file = if ($e.PSObject.Properties.Match('file').Count -gt 0) { [string]$e.file } else { '' }
        $class = if ($e.PSObject.Properties.Match('class').Count -gt 0) { [string]$e.class } else { '' }
        $reason = if ($e.PSObject.Properties.Match('reason').Count -gt 0) { [string]$e.reason } else { '' }
        $issue = if ($e.PSObject.Properties.Match('issue').Count -gt 0) { $e.issue } else { $null }

        if ([string]::IsNullOrWhiteSpace($file)) {
            $invalid.Add("(entry with no 'file')"); continue
        }
        $quarantinedNames.Add($file)
        if ($script:CIQuarantineClasses -notcontains $class) {
            $invalid.Add("${file}: class '$class' is not one of $($script:CIQuarantineClasses -join ', ')")
        }
        if ([string]::IsNullOrWhiteSpace($reason)) {
            $invalid.Add("${file}: empty reason. An exclusion nobody has to justify is the allowlist again.")
        }
        # Only the TEMPORARY class is ticket-bound. 'never-ci' is permanent by
        # design and 'unclassified' is covered by one umbrella ticket, so
        # demanding a per-file issue for either would just manufacture noise.
        if ($class -eq 'linux-red' -and ($null -eq $issue -or [string]::IsNullOrWhiteSpace([string]$issue))) {
            $invalid.Add("${file}: class 'linux-red' with no issue number. A temporary exclusion with no ticket is a permanent one that has not admitted it.")
        }
        if ($class -eq 'unclassified') { $unclassified++ }
    }

    $onDisk = @(Get-ChildItem -LiteralPath $TestsRoot -Filter '*.Tests.ps1' -File | Sort-Object Name)
    $onDiskNames = @($onDisk | ForEach-Object { $_.Name })

    $selected = @($onDisk | Where-Object { $quarantinedNames -notcontains $_.Name })
    $stale = @($quarantinedNames | Where-Object { $onDiskNames -notcontains $_ })

    # Empty by construction while selection is "everything not quarantined" —
    # asserted anyway, because the day the selection rule grows a second
    # condition is the day a file can fall between the two sets in silence.
    $unaccounted = @($onDiskNames | Where-Object {
            $quarantinedNames -notcontains $_ -and @($selected | ForEach-Object { $_.Name }) -notcontains $_
        })

    if ($stale.Count -gt 0) {
        $driftDetails.Add("ci-suite-selection: quarantine names $($stale.Count) file(s) that do not exist: $($stale -join ', '). A stale entry hides the fact that coverage was deleted, not skipped.")
    }
    if ($unaccounted.Count -gt 0) {
        $driftDetails.Add("ci-suite-selection: $($unaccounted.Count) suite(s) are neither selected nor quarantined: $($unaccounted -join ', ').")
    }
    foreach ($i in $invalid) { $driftDetails.Add("ci-suite-selection: $i") }
    if ($selected.Count -eq 0 -and $onDisk.Count -gt 0) {
        $driftDetails.Add('ci-suite-selection: every suite on disk is quarantined. A run that selects nothing reports green for the same reason an empty test run does.')
    }

    return [PSCustomObject]@{
        Selected          = @($selected | ForEach-Object { $_.FullName })
        SelectedNames     = @($selected | ForEach-Object { $_.Name })
        Quarantined       = @($entries)
        Unaccounted       = @($unaccounted)
        StaleQuarantine   = @($stale)
        InvalidEntries    = @($invalid)
        UnclassifiedCount = $unclassified
        HasDrift          = ($driftDetails.Count -gt 0)
        DriftDetails      = $driftDetails.ToArray()
    }
}

#endregion
