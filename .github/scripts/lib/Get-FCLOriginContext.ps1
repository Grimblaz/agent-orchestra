#Requires -Version 7.0
# ===========================================================================
# Get-FCLOriginContext.ps1 — CI-safe orchestrated-origin predicate
#
# Issue: #769 (cost-telemetry v4 emission reliability), slice s1
#
# Determines whether a PR is "orchestrated-origin" using CI-safe signals:
#   PRIMARY:  $env:GITHUB_HEAD_REF — populated by GitHub Actions on
#             pull_request events as the source branch name.
#             Matched against ^feature/issue-\d+.
#             NOTE: Do NOT use `git rev-parse --abbrev-ref HEAD` — in CI
#             detached-HEAD checkouts that yields the literal string "HEAD",
#             not the branch name (M3 bug in frame-credit-ledger.ps1:1311).
#   FALLBACK: PR body linked-issue signals — mirrors the body-fallback in
#             frame-credit-ledger.ps1:469-484 (Resolve-FCLLinkedIssueNumber
#             body leg), but exposed as a public function importable by
#             external scripts.
#             Patterns: issue_id: N, <!-- plan-issue-N --> (close/fix/resolve #N excluded — see B4a)
#
# Usage (dot-source and call):
#   . (Join-Path $PSScriptRoot 'Get-FCLOriginContext.ps1')
#   $ctx = Get-FCLOriginContext -HeadRef $env:GITHUB_HEAD_REF -PrBody $prBody
#   if ($ctx.IsOrchestratedOrigin) { ... }
# ===========================================================================

function Get-FCLOriginContext {
    <#
    .SYNOPSIS
        Classifies a PR as orchestrated-origin using CI-safe signals.

    .DESCRIPTION
        Returns a [pscustomobject] with three properties:
          IsOrchestratedOrigin [bool]   — true when the PR is feature/issue-* origin
          LinkedIssueNumber    [int?]   — the issue number if resolved; $null otherwise
          DetectionMethod      [string] — 'branch' | 'body' | 'none'

        Signal priority:
          1. HeadRef matching ^feature/issue-(\d+) → DetectionMethod='branch'
             The literal string 'HEAD' (detached-HEAD CI checkout) is treated as
             absent and falls through to the body fallback.
          2. PrBody containing linked-issue signals → DetectionMethod='body'
          3. Neither → IsOrchestratedOrigin=$false, DetectionMethod='none'

    .PARAMETER HeadRef
        The PR source branch name. Pass $env:GITHUB_HEAD_REF in CI, or the
        branch name directly. Omit or pass $null/$empty to skip branch matching.

    .PARAMETER PrBody
        The PR body text for fallback linked-issue parsing. Omit or pass
        $null/$empty to skip body parsing.

    .EXAMPLE
        # In a GitHub Actions step:
        $ctx = Get-FCLOriginContext -HeadRef $env:GITHUB_HEAD_REF -PrBody $prBody
        if (-not $ctx.IsOrchestratedOrigin) {
            Write-Host "not measured (non-orchestrated)"
            exit 0
        }
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowEmptyString()][AllowNull()][string]$HeadRef,
        [AllowEmptyString()][AllowNull()][string]$PrBody
    )

    # -----------------------------------------------------------------------
    # PRIMARY: branch-name match via GITHUB_HEAD_REF
    # Excludes the literal 'HEAD' string (detached-HEAD CI artifact).
    # Pattern: ^feature/issue-(\d+) — same convention as Resolve-FCLLinkedIssueNumber.
    # -----------------------------------------------------------------------
    $branchPattern = '^feature/issue-(?<issue>\d+)(?:-|$)'
    if (-not [string]::IsNullOrWhiteSpace($HeadRef) -and $HeadRef -ne 'HEAD') {
        $branchMatch = [regex]::Match($HeadRef, $branchPattern)
        if ($branchMatch.Success) {
            $issueNum = $null
            $parsed = 0
            if ([int]::TryParse($branchMatch.Groups['issue'].Value, [ref]$parsed) -and $parsed -gt 0) {
                $issueNum = $parsed
            }
            return [pscustomobject]@{
                IsOrchestratedOrigin = $true
                LinkedIssueNumber    = $issueNum
                DetectionMethod      = 'branch'
            }
        }
    }

    # -----------------------------------------------------------------------
    # FALLBACK: PR body orchestration-specific signals.
    # Only patterns that are unambiguous orchestration markers:
    #   1. issue_id: N — explicit machine-format field in PR body
    #   2. <!-- plan-issue-N --> or <!-- design-issue-N --> — orchestration comment markers
    # NOTE: close/fix/resolve/ref #N patterns are intentionally EXCLUDED — these are
    #   standard GitHub issue-linking prose that any contributor writes and do NOT
    #   indicate the PR was produced by Agent Orchestra orchestration.
    # -----------------------------------------------------------------------
    if (-not [string]::IsNullOrWhiteSpace($PrBody)) {
        $bodyPatterns = @(
            '(?im)^\s*issue_id\s*:\s*(?<issue>\d+)\s*$',
            '(?im)<!--\s*(?:plan|design)-issue-(?<issue>\d+)\s*-->'
        )

        foreach ($pattern in $bodyPatterns) {
            $match = [regex]::Match($PrBody, $pattern)
            if (-not $match.Success) { continue }

            $parsed = 0
            if ([int]::TryParse($match.Groups['issue'].Value, [ref]$parsed) -and $parsed -gt 0) {
                return [pscustomobject]@{
                    IsOrchestratedOrigin = $true
                    LinkedIssueNumber    = $parsed
                    DetectionMethod      = 'body'
                }
            }
        }
    }

    # -----------------------------------------------------------------------
    # Neither signal matched — non-orchestrated origin.
    # -----------------------------------------------------------------------
    return [pscustomobject]@{
        IsOrchestratedOrigin = $false
        LinkedIssueNumber    = $null
        DetectionMethod      = 'none'
    }
}
