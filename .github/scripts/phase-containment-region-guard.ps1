#Requires -Version 7.0
<#
.SYNOPSIS
    Unattended guard: reports phase-containment regions that no reader can
    match, at the moment they are posted (issue #944).
.DESCRIPTION
    Issue #944 asked what makes this failure class impossible to have silently
    again. The answer could not be another maintainer-invoked CLI: the class's
    own history is an advisory that fired correctly on PR #937 and went unread,
    and the two CLIs in this family are both run by hand. So this runs without
    anybody invoking it.

    IT WATCHES THE SURFACE WHERE THE DEFECT HAPPENS. Every one of the 63 lost
    entries was hand-authored directly into a GitHub comment. A repository-file
    check would not have seen a single one of them. So the trigger is the
    comment event itself, and the reply lands in the same thread the region was
    posted to, while the author is still there.

    WARN-ONLY, ALWAYS. A GitHub comment cannot be prevented — there is no
    chokepoint to gate — so this reports and never blocks. It exits 0 on a
    detection so the workflow step stays green; the SIGNAL is the posted reply
    and the job summary, not a red X on an unrelated pull request.

.PARAMETER Body
    Text to scan. Mutually exclusive with -BodyFile.
.PARAMETER BodyFile
    Path to a file holding the text to scan. Preferred in CI: a comment body
    passed as an argument is subject to shell quoting, and these bodies are
    untrusted attacker-influencable input.
.PARAMETER SourceLabel
    Human-readable description of where the body came from.
.PARAMETER PostTo
    Issue/PR number to reply on when a region is found. Omitted, the report is
    printed only.
.PARAMETER InReplyToCommentId
    The comment that carried the region, linked in the reply so the author can
    find it.
.PARAMETER Repo
    owner/name. Defaults to the ambient GITHUB_REPOSITORY.
.PARAMETER SummaryPath
    Appends the report to this file (GITHUB_STEP_SUMMARY in CI).
.EXAMPLE
    pwsh ./.github/scripts/phase-containment-region-guard.ps1 -BodyFile ./comment.md -SourceLabel 'issue #944 comment'
#>
[CmdletBinding(DefaultParameterSetName = 'File')]
param(
    [Parameter(ParameterSetName = 'Text', Mandatory)][AllowEmptyString()][string]$Body,
    [Parameter(ParameterSetName = 'File', Mandatory)][string]$BodyFile,
    [string]$SourceLabel = 'this comment',
    [int]$PostTo = 0,
    [string]$InReplyToCommentId = '',
    # M23: review-thread comments anchor differently from issue comments, and
    # only the caller knows which event fired.
    [switch]$SourceIsReviewComment,
    [string]$Repo = $env:GITHUB_REPOSITORY,
    [string]$SummaryPath = $env:GITHUB_STEP_SUMMARY
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Fail OPEN. This guard must never be the reason a comment event fails: it is
# an advisory, and an advisory that breaks the thread it watches gets turned
# off. Same posture as frame-credit-ledger.ps1's lib-load wrapper.
try {
    . (Join-Path $PSScriptRoot 'lib/phase-containment-region-guard-core.ps1')
}
catch {
    [Console]::Error.WriteLine("phase-containment-region-guard: library load failed: $($_.Exception.Message)")
    exit 0
}

try {
    $text = if ($PSCmdlet.ParameterSetName -eq 'File') {
        if (-not (Test-Path -LiteralPath $BodyFile)) {
            [Console]::Error.WriteLine("phase-containment-region-guard: body file not found: $BodyFile")
            exit 0
        }
        [System.IO.File]::ReadAllText((Resolve-Path -LiteralPath $BodyFile).Path, [System.Text.Encoding]::UTF8)
    }
    else { $Body }

    $findings = Find-MalformedPhaseContainmentRegion -Body $text

    if ($findings.Count -eq 0) {
        # Printed on every clean run, deliberately. A guard whose success
        # signal is silence is indistinguishable from a guard that failed to
        # run — which is the shape of this issue's own defect.
        Write-Host "phase-containment-region-guard: clean — no unreadable phase-containment region in $SourceLabel."
        exit 0
    }

    $report = Format-MalformedRegionReport -Findings $findings -SourceLabel $SourceLabel
    Write-Host $report

    if (-not [string]::IsNullOrWhiteSpace($SummaryPath)) {
        Add-Content -LiteralPath $SummaryPath -Value $report -Encoding utf8
    }

    if ($PostTo -gt 0 -and -not [string]::IsNullOrWhiteSpace($Repo)) {
        # IDEMPOTENCY (PR #1006 review, M15). Without a marker this posted on
        # every detection, so editing a triggering comment N times produced N
        # advisories — attacker-drivable comment flooding attributed to the
        # repository, on a workflow any GitHub user can trigger. Every other
        # durable-marker writer in this repo checks first; this one did not.
        $idempotencyMarker = "<!-- pc-region-guard-advised-$InReplyToCommentId -->"
        $existing = & gh api "repos/$Repo/issues/$PostTo/comments" --paginate --jq '.[].body' 2>$null
        if ($LASTEXITCODE -eq 0 -and $null -ne $existing -and (($existing -join "`n") -like "*$idempotencyMarker*")) {
            Write-Host "phase-containment-region-guard: an advisory for comment $InReplyToCommentId is already posted on #$PostTo; not posting again."
            exit 0
        }

        $commentBody = $idempotencyMarker + "`n" + $report
        if (-not [string]::IsNullOrWhiteSpace($InReplyToCommentId)) {
            # M23: a review-comment id anchors as #discussion_r, not
            # #issuecomment. The reviewed revision built the issue-comment
            # anchor for both event types, so the one link a maintainer would
            # click was dead for exactly the event whose region it described.
            $anchor = if ($SourceIsReviewComment) { "discussion_r$InReplyToCommentId" } else { "issuecomment-$InReplyToCommentId" }
            $commentBody += "`n`nSource: https://github.com/$Repo/issues/$PostTo#$anchor"
        }
        # Written through a file: the report carries backticks, angle brackets
        # and newlines, and passing it as an argument would hand a
        # user-authored comment body to the shell.
        $payloadPath = Join-Path ([System.IO.Path]::GetTempPath()) "pc-region-guard-$([System.Guid]::NewGuid().ToString('N')).json"
        try {
            $payload = @{ body = $commentBody } | ConvertTo-Json -Depth 3 -Compress
            [System.IO.File]::WriteAllText($payloadPath, $payload, [System.Text.UTF8Encoding]::new($false))
            & gh api -X POST "repos/$Repo/issues/$PostTo/comments" --input $payloadPath | Out-Null
            if ($LASTEXITCODE -ne 0) {
                [Console]::Error.WriteLine("phase-containment-region-guard: could not post the advisory to #$PostTo; the report above is still the signal.")
            }
        }
        finally {
            if (Test-Path -LiteralPath $payloadPath) { Remove-Item -LiteralPath $payloadPath -Force -ErrorAction SilentlyContinue }
        }
    }

    # Exit 0 on a detection: warn-only means the reply is the signal, not a
    # failed check on somebody else's work.
    exit 0
}
catch {
    [Console]::Error.WriteLine("phase-containment-region-guard: unexpected failure: $($_.Exception.Message)")
    exit 0
}
