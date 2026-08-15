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

# The legal class set. `unclassified` was a member until issue #1036 and is
# deliberately NOT one now: every entry that carried it has been measured on
# Linux, and re-admitting the class would re-admit "nobody looked" as a reason.
# An entry still carrying it is refused by name, whatever its reason says.
$script:CIQuarantineClasses = @('linux-red', 'never-ci', 'no-signal')

# Classes whose exclusion is expected to END, and which therefore may not sit in
# the registry without something tracking that ending. `never-ci` is absent by
# design: it is permanent, so a ticket it will never close would be noise.
$script:CIQuarantineIssueRequiredClasses = @('linux-red', 'no-signal')

# The class the registry used to allow, kept ONLY so the refusal can name it and
# say what happened to it rather than reporting an anonymous unknown class.
$script:CIQuarantineRetiredClasses = @('unclassified')

function Test-CIQuarantineIssueNumber {
    <#
    .SYNOPSIS
        True when a quarantine entry's `issue` field names a ticket that could
        actually exist: a positive integer.
    .DESCRIPTION
        THE POINT. The classes in $script:CIQuarantineIssueRequiredClasses are
        exclusions expected to END, so the ticket is the whole mechanism that
        ends them. A non-blank check is not that: `issue: "TODO"`, `issue: 0`
        and `issue: -17` are all non-blank and all name nothing anyone can
        close, so each would admit an entry, drop that suite from the gate and
        report no drift — the "drop wearing a quarantine's badge" this file's
        class docs say the requirement prevents.

        This is a FUNCTION rather than a rule restated at each call site so the
        registration suite can consume it. The suite previously carried its own
        copy of the non-blank test, which is exactly why the suite could not
        catch the library being too weak: both halves agreed, and both were
        wrong.

        Accepts an integer or a numeric string (JSON gives either). Rejects
        null, empty, whitespace, non-numeric text, zero and negatives.
    .PARAMETER Issue
        The raw `issue` value off the entry, of any type, possibly $null.
    .OUTPUTS
        [bool]
    #>
    param($Issue)

    if ($null -eq $Issue) { return $false }
    $text = ([string]$Issue).Trim()
    if ([string]::IsNullOrWhiteSpace($text)) { return $false }

    # Parsed as an integer specifically: `12.5` and `1e3` are not issue
    # numbers, and an invariant-culture parse keeps a thousands separator or a
    # localised sign from sneaking one through.
    [int]$parsed = 0
    if (-not [int]::TryParse($text, [System.Globalization.NumberStyles]::AllowLeadingSign, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$parsed)) {
        return $false
    }
    return ($parsed -ge 1)
}

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

        QUARANTINE CLASSES. Every one of them is a DECISION about a suite that
        was actually measured. There is deliberately no class meaning "not
        looked at yet":

          linux-red    — measured failing on the CI platform. Temporary by
                         construction, so an issue number is REQUIRED; an entry
                         with no ticket is a drop wearing a quarantine's badge.
                         The class says where the failure was OBSERVED, not
                         that the cause is platform-specific — several entries
                         reproduce on Windows, and their reasons say so, because
                         this instrument runs only Linux and cannot tell the
                         difference on its own.
          never-ci     — structurally cannot run in CI, permanently, for a
                         reason nothing in this repository's power removes: a
                         live network or remote-state dependency, an
                         interactive terminal. NOT for an obstacle the gate
                         chooses and could unchoose — a checkout depth, an
                         absent token — which is a decision, not a structure.
          no-signal    — the suite executes and yields no verdict at all (every
                         test skipped, or nothing discovered). Promoting it
                         would redden the gate, because a suite that executes
                         zero tests is not a passing suite. The condition
                         producing it is expected to end, so like `linux-red`
                         it REQUIRES an issue.

        RETIRED: `unclassified`, which meant "never registered under the old
        allowlist, and whether it is CI-viable has never been measured". 188
        entries carried it. Issue #1035 measured every one of them on Linux and
        issue #1036 spent that measurement, so the class no longer describes
        anything true and is refused rather than merely discouraged — a class
        that only shrinks by good intentions does not shrink.

        Collapsing `never-ci` into `linux-red`, or widening `never-ci` to
        absorb a backlog, is what turns a quarantine into a graveyard: after a
        few months most entries are permanent, no entry is actionable, and
        nobody reads the file — which is exactly how the allowlist this
        replaces stopped being read.
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

        UnclassifiedCount counts entries still carrying the RETIRED
        `unclassified` class. It is structurally zero in a healthy tree now,
        because such an entry is also an invalid entry and so is drift; it is
        still reported separately so the audit and the gate's job summary can
        say "the backlog is gone" rather than having to infer it from silence.
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
            # A retired class gets its own message. "not one of ..." is true but
            # unhelpful for the one class that used to be legal and is the
            # single most likely thing a stale entry or a copied template still
            # carries; naming the retirement tells the author what to do next.
            if ($script:CIQuarantineRetiredClasses -contains $class) {
                $invalid.Add("${file}: class '$class' was RETIRED by issue #1036. It meant the suite's CI-viability had never been measured; #1035 measured the whole corpus on Linux, so no entry may still rest on nobody having looked. Re-classify as one of $($script:CIQuarantineClasses -join ', ') from what the suite actually does, or remove the entry and let the gate run it.")
            }
            else {
                $invalid.Add("${file}: class '$class' is not one of $($script:CIQuarantineClasses -join ', ')")
            }
        }
        if ([string]::IsNullOrWhiteSpace($reason)) {
            $invalid.Add("${file}: empty reason. An exclusion nobody has to justify is the allowlist again.")
        }
        # Only the classes whose exclusion is expected to END are ticket-bound.
        # 'never-ci' is permanent by design, so demanding an issue for it would
        # manufacture a ticket nobody can ever close.
        if ($script:CIQuarantineIssueRequiredClasses -contains $class -and -not (Test-CIQuarantineIssueNumber $issue)) {
            # The value is echoed when there IS one, because "no issue number"
            # reads as an absent field and the widened check also refuses a
            # present-but-unusable one ('TODO', 0, -17).
            $got = if ($null -eq $issue -or [string]::IsNullOrWhiteSpace([string]$issue)) { '' } else { " (got '$issue')" }
            $invalid.Add("${file}: class '$class' with no issue number$got. An exclusion that is expected to end, with no ticket, is a permanent one that has not admitted it. The ticket must be a POSITIVE INTEGER; a placeholder, a zero or a negative names nothing anyone can close.")
        }
        if ($script:CIQuarantineRetiredClasses -contains $class) { $unclassified++ }
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
