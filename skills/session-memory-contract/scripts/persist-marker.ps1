#Requires -Version 7.0

<#
.SYNOPSIS
    Thin CLI/production wrapper for Invoke-PersistMarkerWrite /
    Invoke-PersistMarkerBurstFromManifest (issue #893, plan slice s6).
.DESCRIPTION
    Owns the dot-source of the hub primitives persist-marker-core.ps1
    composes, mirroring persist-phase-ledger.ps1's wrapper/core split
    (skills/session-memory-contract/scripts/persist-phase-ledger.ps1) and
    its plugin-bundled fixed-relative-offset dot-source justification:
    .github/scripts/lib ships bundled alongside this very script at a FIXED
    relative offset inside our own checkout (whether that checkout is the
    Agent Orchestra hub repo itself or an installed plugin-cache copy) --
    $PSScriptRoot always resolves to skills/session-memory-contract/scripts,
    so $PSScriptRoot/../../../.github/scripts/lib always resolves to OUR
    OWN bundled libs at the SAME version as this wrapper -- the two can
    never drift out of lockstep with each other, because they are the same
    install. persist-marker-core.ps1 does NOT dot-source these itself -- it
    assumes them already in scope (mirrors persist-phase-ledger-core.ps1's
    identical convention), which lets Pester dot-source the core directly
    against the real primitives without ever loading this wrapper (see
    .github/scripts/Tests/persist-marker.Tests.ps1's BeforeEach, and its
    sibling .github/scripts/Tests/persist-marker-core.Tests.ps1).

    Explicit dot-source list (no globbing -- this repo's release-hygiene
    gate has previously flagged an implicit/globbed dot-source list as a
    defect):
      1. .github/scripts/lib/marker-transport-core.ps1 -- Find-AllCommentsByExactMarker,
         New-MarkerComment, Get-CommentIdFromUrl, Get-CommentBodyById,
         Set-CommentBodyDirect, Set-PointerLineAfterMarker.
      2. .github/scripts/lib/frame-engagement-record-core.ps1 --
         Read-EngagementRecords, for the engagement-record family's
         ValidatorAdapter.
      3. .github/scripts/lib/frame-spine-core.ps1 -- Get-FSCSpineBlock,
         script:Get-FSCScalarValue, for the s5 PostStep dispatch.
      4. skills/session-memory-contract/scripts/persist-marker-core.ps1 --
         Invoke-PersistMarkerWrite, Invoke-PersistMarkerBurst,
         Invoke-PersistMarkerBurstFromManifest, and this slice's
         scratch-root-bounding + size-cap helpers.
    persist-marker-core.ps1's own review-dispositions validator adapter
    invokes .github/scripts/lib/review-dispositions-validator-core.ps1
    itself, via a path resolved relative to ITS OWN $PSScriptRoot -- that
    script is not a caller-scope dot-source dependency and is deliberately
    absent from this list.

    Forward slashes in the Join-Path child-path argument, per
    .github/architecture-rules.md's Join-Path child-path separator rule.

    Both `pwsh -File` and in-process call-operator (`&`) invocation are
    legal entry points (s6 requirement contract) -- this file's own
    top-level param() block carries ONLY scalar and file-path parameters
    (string/int/switch), never an array or collection, so a `pwsh -File`
    invocation can never silently flatten a multi-element parameter (the
    recorded #866 flattening trap this repo has hit before, and the reason
    .github/scripts/lib/review-dispositions-validator-core.ps1 is invoked
    in-process via `&` rather than `pwsh -File` elsewhere in this feature).
    -BurstManifest is a FILE PATH to a JSON array, not an inline array
    parameter, for the same reason. Owner/Repo apply to every entry in a
    burst; a burst spanning multiple repos is out of scope.
.PARAMETER Owner
    Repository owner.
.PARAMETER Repo
    Repository name.
.PARAMETER Family
    (Single-write mode) Marker family -- see Get-MarkerFamilyRegistry.
.PARAMETER Number
    (Single-write mode) Issue or PR number.
.PARAMETER TargetSurface
    (Single-write mode) 'issue' or 'pull-request'.
.PARAMETER Marker
    (Single-write mode) The exact marker line the composed body carries.
.PARAMETER BodyFile
    (Single-write mode) Path to the file carrying the full marker-composed
    candidate body. Must resolve inside the repository's scratch root
    ('.tmp/') via real path-containment (Resolve-Path-based, not a
    string-prefix test) -- a path outside it is refused pre-write. This is
    what keeps the recommended `Bash(pwsh*persist-marker.ps1*)`-style
    allowlist entry safe rather than an arbitrary-file-read-to-public-
    comment primitive.
.PARAMETER NoPreserve
    (Single-write mode) See Invoke-PersistMarkerWrite's -NoPreserve.
.PARAMETER BurstManifest
    (Burst mode) Path to a JSON manifest file: an array of objects, each
    carrying family/number/targetSurface/marker/bodyFile (and optionally
    noPreserve). Every entry's bodyFile is scratch-root-bounded exactly
    like single-write mode's -BodyFile. WHOLE-MANIFEST validation preflight
    runs before the first network write; a manifest with ANY invalid entry
    writes nothing. After preflight passes, writes execute in manifest
    order, halting on the first execution failure.
.EXAMPLE
    pwsh ./skills/session-memory-contract/scripts/persist-marker.ps1 `
        -Owner Grimblaz -Repo agent-orchestra -Family credit-input `
        -Number 893 -TargetSurface issue -Marker '<!-- credit-input-plan-893 -->' `
        -BodyFile .tmp/issue-893/credit-body.md
.EXAMPLE
    pwsh ./skills/session-memory-contract/scripts/persist-marker.ps1 `
        -Owner Grimblaz -Repo agent-orchestra -BurstManifest .tmp/issue-893/burst.json
#>

[CmdletBinding(DefaultParameterSetName = 'Single')]
param(
    [Parameter(Mandatory)][string]$Owner,
    [Parameter(Mandatory)][string]$Repo,

    [Parameter(Mandatory, ParameterSetName = 'Single')][string]$Family,
    [Parameter(Mandatory, ParameterSetName = 'Single')][int]$Number,
    [Parameter(Mandatory, ParameterSetName = 'Single')][ValidateSet('issue', 'pull-request')][string]$TargetSurface,
    [Parameter(Mandatory, ParameterSetName = 'Single')][string]$Marker,
    [Parameter(Mandatory, ParameterSetName = 'Single')][string]$BodyFile,
    [Parameter(ParameterSetName = 'Single')][switch]$NoPreserve,

    [Parameter(Mandatory, ParameterSetName = 'Burst')][string]$BurstManifest
)

. (Join-Path $PSScriptRoot '../../../.github/scripts/lib/marker-transport-core.ps1')
. (Join-Path $PSScriptRoot '../../../.github/scripts/lib/frame-engagement-record-core.ps1')
. (Join-Path $PSScriptRoot '../../../.github/scripts/lib/frame-spine-core.ps1')
. (Join-Path $PSScriptRoot 'persist-marker-core.ps1')

function script:Format-PersistMarkerArtifacts {
    param($Artifacts)
    if ($null -eq $Artifacts -or $Artifacts.Count -eq 0) { return '(no artifact manifest)' }
    return ($Artifacts.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ', '
}

if ($PSCmdlet.ParameterSetName -eq 'Burst') {
    $result = Invoke-PersistMarkerBurstFromManifest -Owner $Owner -Repo $Repo -ManifestPath $BurstManifest

    if (-not $result.Success) {
        [Console]::Error.WriteLine("persist-marker (burst): FAILED -- $($result.Reason)")
        [Console]::Error.WriteLine("persist-marker (burst): artifacts -- $(script:Format-PersistMarkerArtifacts -Artifacts $result.Artifacts)")
        exit 1
    }

    Write-Output "persist-marker (burst): success"
    Write-Output "persist-marker (burst): artifacts -- $(script:Format-PersistMarkerArtifacts -Artifacts $result.Artifacts)"
    exit 0
}

# --- Single-write mode. ---
$scratchRoot = script:Get-MarkerScratchRoot
$bodyFileResult = Read-MarkerScratchBoundedBodyFile -BodyFile $BodyFile -ScratchRoot $scratchRoot
if (-not $bodyFileResult.Success) {
    [Console]::Error.WriteLine("persist-marker (family=$Family): FAILED -- $($bodyFileResult.Reason)")
    exit 1
}

$result = Invoke-PersistMarkerWrite -Family $Family -Owner $Owner -Repo $Repo -Number $Number `
    -TargetSurface $TargetSurface -Marker $Marker -Body $bodyFileResult.Body -NoPreserve:$NoPreserve

if (-not $result.Success) {
    [Console]::Error.WriteLine("persist-marker (family=$Family): FAILED -- $($result.Reason)")
    exit 1
}

Write-Output "persist-marker (family=$Family): $($result.Confirmation)"
exit 0
