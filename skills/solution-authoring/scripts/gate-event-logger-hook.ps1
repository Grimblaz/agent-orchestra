#Requires -Version 7.0

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

# ──────────────────────────────────────────────────────────────────────────────
# Shared key-resolution helper (AC12)
# Both this hook (writer) and gate-reconciliation-core.ps1 (reader) call
# Resolve-GateSessionKey. The key is written into each log entry so the
# validator can read it directly from the log rather than re-deriving it.
# ──────────────────────────────────────────────────────────────────────────────

function Resolve-GateSessionKey {
    param([object]$Payload)

    # Prefer session_id from the hook payload (stable within a session)
    if ($Payload -and $Payload.session_id) {
        return ("s-" + ($Payload.session_id -replace '[^A-Za-z0-9._-]+', '-').TrimStart('-').TrimEnd('-'))
    }

    # Fallback 1: branch slug
    $branch = (git rev-parse --abbrev-ref HEAD 2>$null)
    if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($branch)) {
        $slug = ($branch -replace '[^A-Za-z0-9._-]+', '-').TrimStart('-').TrimEnd('-')
        if (-not [string]::IsNullOrWhiteSpace($slug)) {
            return "b-$slug"
        }
    }

    # Fallback 2: short HEAD sha
    $sha = (git rev-parse --short HEAD 2>$null)
    if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($sha)) {
        return "sha-$($sha.Trim())"
    }

    return 'session'
}

function Get-GateEventLogPath {
    param([string]$SessionKey)

    # Prefer session memory path
    $memoryRoot = $null
    $repoRoot = (git rev-parse --show-toplevel 2>$null)
    if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($repoRoot)) {
        $repoRoot = $repoRoot.Trim()
        # .memories/session lives under the repo root when the session-memory
        # convention is in use; the canonical path is memories/session/
        $memPath = Join-Path $repoRoot "memories/session"
        if (Test-Path $memPath) {
            $memoryRoot = $memPath
        }
    }

    if ($memoryRoot) {
        return Join-Path $memoryRoot "gate-events-${SessionKey}.jsonl"
    }

    # Fallback: .copilot-tracking/
    if ($repoRoot -and (Test-Path (Join-Path $repoRoot '.copilot-tracking'))) {
        return Join-Path $repoRoot '.copilot-tracking' "gate-events.jsonl"
    }

    return $null
}

function Get-GateEventPayload {
    try {
        $raw = [Console]::In.ReadToEnd()
        if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
        return $raw | ConvertFrom-Json -ErrorAction Stop
    }
    catch { return $null }
}

# ──────────────────────────────────────────────────────────────────────────────
# Main entrypoint
# ──────────────────────────────────────────────────────────────────────────────

$payload = Get-GateEventPayload
if (-not $payload) { exit 0 }

$sessionKey = Resolve-GateSessionKey -Payload $payload
$logPath    = Get-GateEventLogPath -SessionKey $sessionKey

if (-not $logPath) { exit 0 }

# Build the event log entry
$toolName   = $payload.tool_name ?? $payload.tool ?? 'unknown'
$toolInput  = $payload.tool_input

# Compute a stable digest from the first question's text (if present)
$questionDigest = ''
if ($toolInput -and $toolInput.questions) {
    $firstQ = if ($toolInput.questions -is [array]) { $toolInput.questions[0] } else { $toolInput.questions }
    $text   = if ($firstQ.question) { $firstQ.question } else { "$firstQ" }
    $bytes  = [System.Text.Encoding]::UTF8.GetBytes($text.Trim())
    $hash   = [System.Security.Cryptography.SHA256]::Create().ComputeHash($bytes)
    $questionDigest = ([System.BitConverter]::ToString($hash) -replace '-','').Substring(0, 16).ToLower()
}

$entry = [ordered]@{
    event_type      = 'structured-question-fired'
    tool_name       = $toolName
    session_key     = $sessionKey
    question_digest = $questionDigest
    timestamp       = (Get-Date -AsUTC -Format 'yyyy-MM-ddTHH:mm:ssZ')
    question_count  = if ($toolInput -and $toolInput.questions) {
                          if ($toolInput.questions -is [array]) { $toolInput.questions.Count } else { 1 }
                      } else { 0 }
}

try {
    # Ensure parent directory exists
    $parent = Split-Path $logPath -Parent
    if (-not (Test-Path $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    $line = ($entry | ConvertTo-Json -Compress -Depth 5)
    Add-Content -Path $logPath -Value $line -Encoding UTF8
}
catch {
    # Fail-open: log write failures must not surface to the agent
    exit 0
}

exit 0
