#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'powershell-yaml'; ModuleVersion = '0.4.0' }

<#
.SYNOPSIS
    Warn-only reconciliation validator for the solution-authoring classification gate (L2).

.DESCRIPTION
    Reconciles L0 gate tokens (written by agents at decision time) against recorded
    decisions (engagement-record decision_id and finding_dispositions finding_id).

    A load-bearing 'asked' token with no corresponding recorded decision raises a
    warn-only ledger finding. Lawful-skip tokens (gate-fails, declined,
    same-decision-resume, greenfield-defer) never raise findings. Routine-classified
    tokens never raise findings.

    Does NOT block persistence or return non-zero exit codes.

.PARAMETER IssueNumber
    The GitHub issue number to reconcile.

.PARAMETER Phase
    Optional. The pipeline phase to scope reconciliation to. If omitted, all phases.

.PARAMETER Repo
    Optional. GitHub repository in owner/name format.

.PARAMETER GhCliPath
    Optional. Path to the gh CLI.

.PARAMETER InMemoryMarkers
    Optional. Raw marker strings (for tests / in-session use without gh).

.PARAMETER EventLogPath
    Optional. Explicit path to the JSONL event log. If omitted, auto-discovered.

.OUTPUTS
    [hashtable] with keys:
      findings      - array of hashtable {decision_id, issue, token_outcome, recorded, severity: 'warn'}
      token_count   - total L0 tokens read
      recorded_count - total decisions recorded
      lawful_skips  - count of lawful-skip tokens (not flagged)
      status        - 'clean' | 'findings'
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [int]$IssueNumber,

    [ValidateSet('experience','design','plan','orchestration')]
    [string]$Phase,

    [string]$Repo = '',

    [string]$GhCliPath = 'gh',

    [string[]]$InMemoryMarkers = @(),

    [string]$EventLogPath = ''
)

$ErrorActionPreference = 'Stop'

# ─── Load dependencies ───────────────────────────────────────────────────────

$libDir = Join-Path $PSScriptRoot '..'
. (Join-Path $PSScriptRoot 'frame-engagement-record-core.ps1')

# ─── Helpers ─────────────────────────────────────────────────────────────────

function Read-GateTokens {
    param([string]$ExplicitPath)

    $paths = @()
    if ($ExplicitPath) {
        $paths += $ExplicitPath
    }
    else {
        # Auto-discover: scan memories/session/ for gate-events-*.jsonl
        $repoRoot = (git rev-parse --show-toplevel 2>$null)?.Trim()
        if ($repoRoot) {
            $memDir = Join-Path $repoRoot 'memories/session'
            if (Test-Path $memDir) {
                $paths += Get-ChildItem -Path $memDir -Filter 'gate-events-*.jsonl' |
                          Select-Object -ExpandProperty FullName
            }
            $ctDir = Join-Path $repoRoot '.copilot-tracking'
            if (Test-Path (Join-Path $ctDir 'gate-events.jsonl')) {
                $paths += Join-Path $ctDir 'gate-events.jsonl'
            }
        }
    }

    $tokens = @()
    foreach ($p in $paths) {
        if (-not (Test-Path $p)) { continue }
        Get-Content $p -Encoding UTF8 | Where-Object { $_ -match '\{' } | ForEach-Object {
            try { $tokens += $_ | ConvertFrom-Json -ErrorAction Stop } catch {}
        }
    }
    return $tokens
}

function Read-FindingDispositionIds {
    # Returns finding_id values from finding_dispositions: blocks on design-phase-complete markers
    param([int]$Issue, [string]$Repo, [string]$Gh, [string[]]$InMem)

    $recordedIds = @()

    try {
        $repoTarget = $Repo
        if (-not $repoTarget) {
            $remoteUrl = git remote get-url origin 2>$null
            $match = [regex]::Match($remoteUrl, 'github\.com[:/](.+?)(?:\.git)?$')
            if ($match.Success) { $repoTarget = $match.Groups[1].Value }
        }

        if ($InMem -and $InMem.Count -gt 0) {
            $allBodies = $InMem
        }
        elseif ($repoTarget) {
            $comments = & $Gh api "repos/$repoTarget/issues/$Issue/comments" 2>$null | ConvertFrom-Json
            $allBodies = $comments | ForEach-Object { $_.body }
        }
        else {
            $allBodies = @()
        }

        foreach ($body in $allBodies) {
            if ($body -notmatch '<!--\s*design-phase-complete') { continue }
            $yamlMatch = [regex]::Match($body, '```yaml\s*([\s\S]*?)```')
            if (-not $yamlMatch.Success) { continue }
            try {
                Import-Module powershell-yaml -ErrorAction Stop
                $parsed = $yamlMatch.Groups[1].Value | ConvertFrom-Yaml -ErrorAction Stop
                $disp = $parsed['finding_dispositions']
                if ($disp -and $disp['entries']) {
                    foreach ($entry in $disp['entries']) {
                        if ($entry['finding_id']) { $recordedIds += $entry['finding_id'] }
                    }
                }
            } catch {}
        }
    } catch {}

    return $recordedIds
}

# ─── Main reconciliation logic ────────────────────────────────────────────────

$LAWFUL_SKIP_OUTCOMES = @('gate-fails', 'declined', 'same-decision-resume', 'greenfield-defer')

# 1. Read L0 tokens
$tokens = Read-GateTokens -ExplicitPath $EventLogPath
if ($Phase) {
    $tokens = $tokens | Where-Object { $_.phase -eq $Phase }
}

# 2. Read recorded engagement-record decisions (decision_id coverage)
$erArgs = @{ IssueNumber = $IssueNumber; GhCliPath = $GhCliPath }
if ($Phase)           { $erArgs.Phase = $Phase }
if ($Repo)            { $erArgs.Repo = $Repo }
if ($InMemoryMarkers) { $erArgs.InMemoryMarkers = $InMemoryMarkers }

$engagementRecords = @()
try { $engagementRecords = Read-EngagementRecords @erArgs } catch {}

# Read-EngagementRecords returns a flat array of decision objects (each with
# .decision_id), not an array of record wrappers with .load_bearing_decisions.
$recordedDecisionIds = @()
$recordedDecisionIds += $engagementRecords | ForEach-Object { $_.decision_id } | Where-Object { $_ }

# 3. Read finding_dispositions finding_id coverage (disposition surface, #615; judge-merge, #605)
$recordedFindingIds = Read-FindingDispositionIds -Issue $IssueNumber -Repo $Repo -Gh $GhCliPath -InMem $InMemoryMarkers
$allRecordedIds = ($recordedDecisionIds + $recordedFindingIds) | Sort-Object -Unique

# 4. Reconcile
$findings    = @()
$lawfulCount = 0

foreach ($token in $tokens) {
    $id      = $token.decision_id
    $outcome = $token.outcome
    $class   = $token.classification

    # Lawful skips — never flag
    if ($outcome -in $LAWFUL_SKIP_OUTCOMES) {
        $lawfulCount++
        continue
    }

    # Routine classifications — never flag
    if ($class -eq 'routine' -or $class -eq 'not-applicable') {
        continue
    }

    # Load-bearing 'asked' token — check that a decision was recorded
    if ($outcome -eq 'asked' -and $class -eq 'load-bearing') {
        if ($id -notin $allRecordedIds) {
            $findings += [ordered]@{
                decision_id     = $id
                issue           = "load-bearing 'asked' token has no corresponding recorded decision"
                token_outcome   = $outcome
                window_position = $token.window_position
                recorded        = $false
                severity        = 'warn'
            }
        }
    }
}

return @{
    findings       = $findings
    token_count    = $tokens.Count
    recorded_count = $allRecordedIds.Count
    lawful_skips   = $lawfulCount
    status         = if ($findings.Count -gt 0) { 'findings' } else { 'clean' }
}
