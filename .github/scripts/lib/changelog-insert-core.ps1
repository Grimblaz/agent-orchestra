#Requires -Version 7.0
<#
.SYNOPSIS
    Side-effect-free library for CHANGELOG insertion. Dot-source this file.
    All logic is in functions; no top-level executable statements.

.DESCRIPTION
    Provides Invoke-ChangelogInsertion for atomic CHANGELOG section insertion,
    used by bump-version.ps1 (issue #739, slice s5 / AC7).
#>

# Dot-source release-gate-core for Test-ChangelogSectionPresent.
# The caller (bump-version.ps1) may have already dot-sourced it; dot-sourcing twice is harmless.
$_coreLib = Join-Path $PSScriptRoot 'release-gate-core.ps1'
if (Test-Path $_coreLib) { . $_coreLib }

$_nlCoreLib = Join-Path $PSScriptRoot 'normalize-whitespace-core.ps1'
if (Test-Path $_nlCoreLib) { . $_nlCoreLib }

function Invoke-ChangelogInsertion {
    <#
    .SYNOPSIS
        Inserts a new ## [Version] — Date section into CHANGELOG content.

    .DESCRIPTION
        Given the current CHANGELOG content string, the new version, the entry body, and
        the subsection name, returns a hashtable with:
          - Updated    : [bool]  true if the content was modified
          - Content    : [string] the (possibly updated) CHANGELOG content
          - Skipped    : [bool]  true when the version heading already existed
          - VerifyPass : [bool]  true when the read-back verification succeeded
          - Message    : [string] human-readable outcome message

        Does NOT read or write any files — callers handle I/O.

    .PARAMETER ChangelogContent
        Current content of CHANGELOG.md as a string.

    .PARAMETER Version
        The new version string, e.g. '2.36.0'.

    .PARAMETER ChangelogEntry
        Multi-line body of the changelog entry. Must NOT contain a ## [X.Y.Z] release header.

    .PARAMETER ChangelogSection
        Subsection name (default: 'Changed'). E.g. 'Fixed', 'Added', 'Changed'.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$ChangelogContent,
        [Parameter(Mandatory)][string]$Version,
        [Parameter(Mandatory)][string]$ChangelogEntry,
        [string]$ChangelogSection = 'Changed'
    )

    # Idempotency check: skip if the new version section already exists
    $alreadyPresent = $false
    if (Get-Command -Name 'Test-ChangelogSectionPresent' -ErrorAction SilentlyContinue) {
        $alreadyPresent = Test-ChangelogSectionPresent -ChangelogContent $ChangelogContent -Version $Version
    } else {
        $escapedVersion = [regex]::Escape($Version)
        $alreadyPresent = [bool]([regex]::IsMatch($ChangelogContent, "(?m)^##\s+\[$escapedVersion\]"))
    }

    if ($alreadyPresent) {
        return @{
            Updated    = $false
            Content    = $ChangelogContent
            Skipped    = $true
            VerifyPass = $true
            Message    = "CHANGELOG already has section ## [$Version] — skipping insert"
        }
    }

    $today = Get-Date -Format 'yyyy-MM-dd'
    $nl = if (Get-Command -Name 'Get-NWNewlineSequence' -ErrorAction SilentlyContinue) {
        Get-NWNewlineSequence -Content $ChangelogContent
    } else {
        if ($ChangelogContent -match "`r`n") { "`r`n" } else { "`n" }
    }
    $newSection = "## [$Version] — $today$nl$nl### $ChangelogSection$nl$nl$($ChangelogEntry.TrimEnd())$nl"

    # Count existing ## [X.Y.Z] headings before insertion (for read-back verify)
    $anchorPattern = '(?m)^## \[\d+\.\d+\.\d+\]'
    $previousCount = ([regex]::Matches($ChangelogContent, $anchorPattern)).Count

    # Find insertion point: first existing ## [X.Y.Z] heading (separator-agnostic)
    $anchorMatch = [regex]::Match($ChangelogContent, $anchorPattern)
    if ($anchorMatch.Success) {
        # Insert above the first existing version heading
        $insertIdx     = $anchorMatch.Index
        $updatedContent = $ChangelogContent.Substring(0, $insertIdx) + $newSection + $nl + $ChangelogContent.Substring($insertIdx)
    } else {
        # No-prior-heading fallback: insert after first '# <title>' line (or at top)
        $preambleMatch = [regex]::Match($ChangelogContent, '(?m)^# .+\r?\n')
        if ($preambleMatch.Success) {
            $insertIdx      = $preambleMatch.Index + $preambleMatch.Length
            $updatedContent = $ChangelogContent.Substring(0, $insertIdx) + $nl + $newSection + $ChangelogContent.Substring($insertIdx)
        } else {
            $updatedContent = $newSection + $nl + $ChangelogContent
        }
    }

    # Read-back verification (in-memory)
    $headerPresent = $false
    if (Get-Command -Name 'Test-ChangelogSectionPresent' -ErrorAction SilentlyContinue) {
        $headerPresent = Test-ChangelogSectionPresent -ChangelogContent $updatedContent -Version $Version
    } else {
        $escapedVersion = [regex]::Escape($Version)
        $headerPresent  = [bool]([regex]::IsMatch($updatedContent, "(?m)^##\s+\[$escapedVersion\]"))
    }
    $afterCount  = ([regex]::Matches($updatedContent, $anchorPattern)).Count
    $verifyPass  = $headerPresent -and ($afterCount -eq $previousCount + 1)

    return @{
        Updated    = $true
        Content    = $updatedContent
        Skipped    = $false
        VerifyPass = $verifyPass
        Message    = "Inserted ## [$Version] — $today (### $ChangelogSection)"
    }
}
