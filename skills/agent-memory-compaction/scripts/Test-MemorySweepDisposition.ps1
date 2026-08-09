#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Applies the sweep procedure's disposition gates to one entry, and reports whether the move is
    lawful and why.

.DESCRIPTION
    Steps 3 of skills/agent-memory-compaction/references/sweep-procedure.md. Read-only.

    This exists because a rule that is only prose is a rule every session re-derives by hand. An
    earlier revision implemented these gates in the shared library and exposed none of them: the
    second-deferral block, the landing verification and the grandfathering scope were reachable
    only from the regression suite, so what the suite demonstrated was that a function returned
    false - not that the procedure blocked anything.

    Four gates, selected by -Gate:

      deferral    - may this entry take keep-hot-with-expiry now? Refuses a second deferral of a
                    critical entry, and refuses any deferral of an entry nobody has assessed.
      exit        - may this entry take an exiting disposition now? Every exit needs its
                    destination read and confirmed to carry the lesson; a critical entry's
                    destination must additionally have landed.
      admission   - may remove-fails-admission be applied to this entry at all? Entries admitted
                    before the store's admission rule landed are grandfathered.
      reconcile   - has this entry's life already exited? Three answers, kept apart: exited,
                    not-exited, and undecidable for a life this store cannot establish.

    Every gate refuses when the slate carries rows this parser cannot read. A deferral history that
    might say anything is not one the never-deferred-twice rule may be applied to.

.PARAMETER Gate
    Which gate to apply: deferral, exit, admission, or reconcile.

.PARAMETER IndexPath
    Path to the store's index file. The record files are located beside it unless overridden.

.PARAMETER Identity
    The entry's life key, '<entry-name>@<yyyy-MM-dd>' or '<entry-name>@unknown'. Required by the
    deferral, exit and admission gates.

.PARAMETER EntryPath
    Path to the entry body. Required by the reconcile gate, which reads the life key off the living
    entry rather than being told it.

.PARAMETER Disposition
    The disposition being considered. Required by the exit gate.

.PARAMETER DestinationPath
    The destination to read for the exit gate. With -LessonProbe, the gate reads this file and
    decides for itself whether the lesson is there.

.PARAMETER LessonProbe
    Text that must appear in the destination for it to count as carrying the lesson.

.PARAMETER DestinationLanded
    Assert that the destination has landed — for a repository destination, merged to the default
    branch. This is the sweep's assertion, not something the gate can read; it is a separate
    parameter from the probe precisely because reading a lesson off an unmerged branch satisfies
    "carries it" and loses the lesson when the branch is abandoned.

.PARAMETER AdmissionRuleLandedOn
    The date this store's admission rule landed. Required by the admission gate.

.PARAMETER SlatePath
.PARAMETER LedgerPath
    Override the record-file locations. Both default to the file of that name beside the index.

.PARAMETER AsOf
    The date the gate reasons from. Defaults to today; passed explicitly by tests.

.PARAMETER Json
    Emit the verdict as a single JSON object.

.OUTPUTS
    Exit 0 - the move is allowed (or, for reconcile, the verdict is not-exited).
    Exit 1 - the move is refused (or, for reconcile, the verdict is exited or undecidable).
    Exit 3 - usage error.

.EXAMPLE
    pwsh Test-MemorySweepDisposition.ps1 -Gate deferral -IndexPath ~/store/MEMORY.md -Identity 'reference_x@2026-07-10'

.EXAMPLE
    pwsh Test-MemorySweepDisposition.ps1 -Gate exit -IndexPath ~/store/MEMORY.md -Identity 'reference_x@2026-07-10' -Disposition promote -DestinationPath ../repo/GUIDE.md -LessonProbe 'a marker head that is not self-closed' -DestinationLanded
#>

[CmdletBinding()]
param(
    # Not Mandatory - see Get-MemorySweepInventory.ps1: a mandatory parameter prompts, and an
    # unattended sweep blocks on the prompt instead of reporting.
    [Parameter()]
    [ValidateSet('deferral', 'exit', 'admission', 'reconcile')]
    [string]$Gate,

    [Parameter()]
    [string]$IndexPath,

    [Parameter()]
    [string]$Identity,

    [Parameter()]
    [string]$EntryPath,

    [Parameter()]
    [string]$Disposition,

    [Parameter()]
    [string]$DestinationPath,

    [Parameter()]
    [string]$LessonProbe,

    [Parameter()]
    [switch]$DestinationLanded,

    [Parameter()]
    [datetime]$AdmissionRuleLandedOn,

    [Parameter()]
    [string]$SlatePath,

    [Parameter()]
    [string]$LedgerPath,

    [Parameter()]
    [datetime]$AsOf = [datetime]::Today,

    [Parameter()]
    [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'lib' 'memory-sweep-core.ps1')

function script:Fail-Usage {
    param([string]$Reason)
    if ($Json) { Write-Output ([pscustomobject]@{ result = 'usage-error'; reason = $Reason } | ConvertTo-Json -Depth 3) }
    else { Write-Output "RESULT: usage-error`nreason: $Reason" }
    exit 3
}

if ([string]::IsNullOrWhiteSpace($Gate)) { script:Fail-Usage 'supply -Gate: deferral, exit, admission, or reconcile' }
if ([string]::IsNullOrWhiteSpace($IndexPath)) { script:Fail-Usage "-IndexPath is required; it names the store's index file" }
if (-not (Test-Path -LiteralPath $IndexPath -PathType Leaf)) { script:Fail-Usage "no index file at '$IndexPath'" }
$resolvedIndex = (Resolve-Path -LiteralPath $IndexPath).Path
$dir = Split-Path -Parent $resolvedIndex
if ([string]::IsNullOrWhiteSpace($SlatePath)) { $SlatePath = Join-Path $dir 'SLATE.md' }
if ([string]::IsNullOrWhiteSpace($LedgerPath)) { $LedgerPath = Join-Path $dir 'LEDGER.md' }

if ($Gate -ne 'reconcile' -and [string]::IsNullOrWhiteSpace($Identity)) {
    script:Fail-Usage "the $Gate gate needs -Identity, the entry's life key"
}
if ($Gate -eq 'reconcile' -and -not (Test-Path -LiteralPath $EntryPath -PathType Leaf)) {
    script:Fail-Usage 'the reconcile gate needs -EntryPath, the living entry body it reads the life key from'
}
if ($Gate -eq 'exit' -and [string]::IsNullOrWhiteSpace($Disposition)) {
    script:Fail-Usage 'the exit gate needs -Disposition'
}
if ($Gate -eq 'admission' -and -not $PSBoundParameters.ContainsKey('AdmissionRuleLandedOn')) {
    script:Fail-Usage 'the admission gate needs -AdmissionRuleLandedOn, the date this store''s admission rule landed'
}

$verdict = switch ($Gate) {
    'deferral' {
        $slate = Get-MSSlateState -Path $SlatePath -AsOf $AsOf
        $r = Test-MSDeferralAllowed -SlateState $slate -Identity $Identity
        [pscustomobject]@{ gate = 'deferral'; identity = $Identity; allowed = $r.Allowed; next_count = $r.NextCount; why = $r.Why }
    }
    'exit' {
        $slate = Get-MSSlateState -Path $SlatePath -AsOf $AsOf
        $carries = $false
        $carriesWhy = 'no destination was read; -DestinationPath and -LessonProbe are how the gate confirms the lesson is there'
        if (-not [string]::IsNullOrWhiteSpace($DestinationPath) -and -not [string]::IsNullOrWhiteSpace($LessonProbe)) {
            $read = Test-MSDestinationCarriesLesson -Path $DestinationPath -Probe $LessonProbe
            $carries = $read.Carries
            $carriesWhy = $read.Why
        }
        $r = Test-MSExitAllowed -SlateState $slate -Identity $Identity -Disposition $Disposition `
            -DestinationCarriesLesson $carries -DestinationLanded ([bool]$DestinationLanded)
        [pscustomobject]@{
            gate = 'exit'; identity = $Identity; disposition = $Disposition
            destination_carries_lesson = $carries; destination_read_note = $carriesWhy
            destination_landed = [bool]$DestinationLanded
            allowed = $r.Allowed; why = $r.Why
        }
    }
    'admission' {
        $r = Test-MSAdmissionRemovalEligible -Identity $Identity -AdmissionRuleLandedOn $AdmissionRuleLandedOn
        [pscustomobject]@{ gate = 'admission'; identity = $Identity; allowed = $r.Eligible; why = $r.Why }
    }
    'reconcile' {
        $ledger = Get-MSLedger -Path $LedgerPath -AsOf $AsOf
        $r = Get-MSReconciliation -EntryPath $EntryPath -Ledger $ledger
        [pscustomobject]@{ gate = 'reconcile'; identity = $r.Identity; verdict = $r.Verdict; allowed = ($r.Verdict -ceq 'not-exited'); why = $r.Why }
    }
}

if ($Json) {
    Write-Output ($verdict | ConvertTo-Json -Depth 4)
}
else {
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("RESULT: $(if ($verdict.allowed) { 'allowed' } else { 'refused' })")
    $lines.Add("gate: $($verdict.gate)")
    $lines.Add("identity: $($verdict.identity)")
    if ($verdict.PSObject.Properties.Name -contains 'verdict') { $lines.Add("verdict: $($verdict.verdict)") }
    if (-not [string]::IsNullOrWhiteSpace($verdict.why)) { $lines.Add("why: $($verdict.why)") }
    Write-Output ($lines -join "`n")
}

exit $(if ($verdict.allowed) { 0 } else { 1 })
