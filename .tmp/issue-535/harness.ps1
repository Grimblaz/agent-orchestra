#Requires -Version 7.0
# Spike scaffolding — not wired into CI. Validate manually before reuse.
<#
.SYNOPSIS
    Measurement-orchestration harness for peer-to-peer agent dispatch research spike (issue #535).
.DESCRIPTION
    This harness is a measurement-orchestration WRAPPER. It does NOT invoke agent sessions
    directly (the Agent tool is in-session-only and cannot be called from PowerShell).

    Instead it:
      1. Prints a session-script the operator copies into an active Claude Code or Copilot Chat
         terminal to run the prototype rounds manually.
      2. After the operator's session completes, invokes the appropriate cost walker to
         post-process resulting transcripts/OTel files and emit per-round token deltas.

    This file lives under .tmp/issue-535/ and is intentionally NOT merged to main.

    # Cache-warmup criterion: discard rounds where cache_creation_input_tokens > 0.
    # Those rounds are building the prompt cache — their input token cost is inflated.
    # Steady-state rounds (cache_creation_input_tokens == 0) reflect cached inference cost.
    # Use --warmup-rounds to control how many initial rounds to exclude from the avg.

    CLI accepts GNU-style long flags (double-dash + hyphens) or PowerShell-style flags.
    Examples:
      pwsh harness.ps1 --mode self-validate --platform claude --non-interactive
      pwsh harness.ps1 --mode run-prototype --platform claude --rounds 10 --warmup-rounds 2
      pwsh harness.ps1 --mode run-prototype --platform copilot --output-json results.json
#>

$ErrorActionPreference = 'Stop'

# ── Argument parsing ──────────────────────────────────────────────────────────
#
# PowerShell param() does not support hyphens in parameter names, so we parse
# the raw $args array manually to accept GNU-style long flags.
#
# Supported flags:
#   --mode <self-validate|run-prototype>   (required)
#   --platform <claude|copilot>            (required)
#   --rounds <int>                         (default 10)
#   --warmup-rounds <int>                  (default 2)
#   --issue-number <int>                   (default 535)
#   --non-interactive                      (switch)
#   --output-json <path>                   (optional)

function script:Resolve-Args {
    param([string[]]$RawArgs)

    $result = [pscustomobject]@{
        Mode           = $null
        Platform       = $null
        Rounds         = 10
        WarmupRounds   = 2
        IssueNumber    = 535
        NonInteractive = $false
        OutputJson     = ''
    }

    $i = 0
    while ($i -lt $RawArgs.Count) {
        $arg = $RawArgs[$i]

        # Normalize: strip leading dashes and lowercase
        $key = $arg.TrimStart('-').ToLowerInvariant()

        switch ($key) {
            'mode' {
                $i++
                $result.Mode = $RawArgs[$i]
            }
            'platform' {
                $i++
                $result.Platform = $RawArgs[$i]
            }
            'rounds' {
                $i++
                $result.Rounds = [int]$RawArgs[$i]
            }
            'warmup-rounds' {
                $i++
                $result.WarmupRounds = [int]$RawArgs[$i]
            }
            'issue-number' {
                $i++
                $result.IssueNumber = [int]$RawArgs[$i]
            }
            'non-interactive' {
                $result.NonInteractive = $true
            }
            'noninteractive' {
                $result.NonInteractive = $true
            }
            'output-json' {
                $i++
                $result.OutputJson = $RawArgs[$i]
            }
            default {
                Write-Warning "Unknown argument: $arg (ignored)"
            }
        }
        $i++
    }

    # Validate required params
    $valid = @('self-validate', 'run-prototype')
    if ($null -eq $result.Mode -or $result.Mode -notin $valid) {
        throw "Parameter -Mode is required and must be one of: $($valid -join ', '). Got: '$($result.Mode)'"
    }
    $validPlatforms = @('claude', 'copilot')
    if ($null -eq $result.Platform -or $result.Platform -notin $validPlatforms) {
        throw "Parameter -Platform is required and must be one of: $($validPlatforms -join ', '). Got: '$($result.Platform)'"
    }

    return $result
}

$Cfg = Resolve-Args -RawArgs $args

$Mode           = $Cfg.Mode
$Platform       = $Cfg.Platform
$Rounds         = $Cfg.Rounds
$WarmupRounds   = $Cfg.WarmupRounds
$IssueNumber    = $Cfg.IssueNumber
$NonInteractive = $Cfg.NonInteractive
$OutputJson     = $Cfg.OutputJson

# ── Constants ──────────────────────────────────────────────────────────────────

$SpikeBranch     = 'feature/issue-535-peer-to-peer-research'
$Repo            = 'Grimblaz/agent-orchestra'
$ScriptDir       = $PSScriptRoot
$RepoRoot        = (Resolve-Path (Join-Path $ScriptDir '../..')).Path
$WalkerClaude    = Join-Path $RepoRoot '.github/scripts/lib/cost-walker.ps1'
$WalkerCopilot   = Join-Path $RepoRoot '.github/scripts/lib/cost-walker-copilot.ps1'
$CopilotSentinel = Join-Path $RepoRoot '.copilot-cost-collection-installed'

# Cache-warmup criterion: discard rounds where cache_creation_input_tokens > 0.
# Those rounds are building the prompt cache — their input token cost is inflated.
# Steady-state rounds (cache_creation_input_tokens == 0) reflect cached inference cost.
# Use --warmup-rounds to control how many initial rounds to exclude from the avg.

# ── Helpers ────────────────────────────────────────────────────────────────────

function Write-Separator {
    param([string]$Title = '')
    $line = '=' * 72
    if ($Title) {
        Write-Host ''
        Write-Host $line
        Write-Host "  $Title"
        Write-Host $line
    } else {
        Write-Host $line
    }
}

function Write-StepLine {
    param([int]$Number, [string]$Text)
    Write-Host "  Step $Number. $Text"
}

function Wait-ForEnter {
    param([string]$Prompt)
    Write-Host ''
    Write-Host $Prompt
    if (-not $NonInteractive) {
        $null = Read-Host
    } else {
        Write-Host '  [non-interactive: skipping Enter wait]'
    }
}

function Build-PeerDispatchPrompt {
    param([int]$RoundNumber, [string]$Label = '')
    $tag = if ($Label) { " [$Label]" } else { " [Round $RoundNumber]" }
    return "Hello, agent. Please respond with exactly: 'Peer dispatch acknowledged.'$tag"
}

# ── Session-script builders ────────────────────────────────────────────────────

function Write-SelfValidateScript {
    Write-Separator 'SESSION SCRIPT — self-validate (1 round)'
    Write-Host ''
    Write-Host '  This is a one-round peer-to-peer dispatch simulation.'
    Write-Host '  Copy these instructions into an active Claude Code terminal or Copilot Chat.'
    Write-Host ''
    Write-Separator 'PRE-CONDITIONS'
    Write-Host ''
    Write-StepLine 1 "Confirm you are on branch: $SpikeBranch"
    Write-Host "       Run: git rev-parse --abbrev-ref HEAD"
    Write-Host "       Expected: $SpikeBranch"
    Write-Host ''
    Write-Separator 'ROUND 1 — Agent A dispatch'
    Write-Host ''
    Write-StepLine 2 'Open a new Claude Code session (or Copilot Chat pane) on the spike branch.'
    Write-Host ''
    Write-StepLine 3 'Type the following prompt EXACTLY as shown (one line, no edits):'
    Write-Host ''
    $promptA = Build-PeerDispatchPrompt -RoundNumber 1 -Label 'Agent-A'
    Write-Host "    +------------------------------------------------------------------+"
    Write-Host "    |  $promptA"
    Write-Host "    +------------------------------------------------------------------+"
    Write-Host ''
    Write-StepLine 4 "Wait for the agent response. Confirm the reply contains:"
    Write-Host "       'Peer dispatch acknowledged.'"
    Write-Host ''
    Write-Separator 'ROUND 1 — Agent B dispatch (peer)'
    Write-Host ''
    Write-StepLine 5 'In the SAME session (do NOT open a new session), type the following prompt:'
    Write-Host ''
    $promptB = Build-PeerDispatchPrompt -RoundNumber 1 -Label 'Agent-B'
    Write-Host "    +------------------------------------------------------------------+"
    Write-Host "    |  $promptB"
    Write-Host "    +------------------------------------------------------------------+"
    Write-Host ''
    Write-StepLine 6 "Wait for the response. Confirm the reply contains:"
    Write-Host "       'Peer dispatch acknowledged.'"
    Write-Host ''
    Write-Separator 'STOP CONDITION'
    Write-Host ''
    Write-Host '  STOP after both Agent-A and Agent-B respond in Round 1.'
    Write-Host '  Do NOT send additional prompts — the session boundary matters for'
    Write-Host '  accurate token-delta measurement.'
    Write-Host ''
    Write-Separator 'AFTER SESSION'
    Write-Host ''
    Write-Host '  Return to this terminal window and press Enter to invoke the cost walker.'
    Write-Separator
    Write-Host ''
}

function Write-RunPrototypeScript {
    param([int]$Rounds, [int]$WarmupRounds)

    $totalRounds = $Rounds + $WarmupRounds
    $steadyStart = $WarmupRounds + 1
    $steadyEnd   = $totalRounds

    Write-Separator "SESSION SCRIPT — run-prototype ($totalRounds rounds: $WarmupRounds warmup + $Rounds steady-state)"
    Write-Host ''
    Write-Host "  Total rounds   : $totalRounds"
    Write-Host "  Warmup (excl)  : rounds 1-$WarmupRounds"
    Write-Host "  Steady-state   : rounds $steadyStart-$steadyEnd"
    Write-Host ''
    Write-Host "  Cache-warmup note:"
    Write-Host "    Discard rounds 1-$WarmupRounds (cache_creation_input_tokens > 0 in those rounds)."
    Write-Host "    Rounds $steadyStart-$steadyEnd are steady-state measurements."
    Write-Host ''
    Write-Separator 'PRE-CONDITIONS'
    Write-Host ''
    Write-StepLine 1 "Confirm you are on branch: $SpikeBranch"
    Write-Host "       Run: git rev-parse --abbrev-ref HEAD"
    Write-Host "       Expected: $SpikeBranch"
    Write-Host ''
    Write-StepLine 2 'Open a SINGLE Claude Code session (or Copilot Chat pane) for ALL rounds.'
    Write-Host '       Do NOT close and reopen between rounds — session continuity is required'
    Write-Host '       for accurate per-round token delta measurement.'
    Write-Host ''
    Write-Separator 'ROUND INSTRUCTIONS'
    Write-Host ''

    for ($r = 1; $r -le $totalRounds; $r++) {
        $isWarmup = ($r -le $WarmupRounds)
        if ($isWarmup) {
            $roundLabel = "WARMUP Round $r of $WarmupRounds"
        } else {
            $steadyIdx = $r - $WarmupRounds
            $roundLabel = "Steady-state Round $steadyIdx of $Rounds (overall round $r)"
        }

        Write-Host "  ── $roundLabel ──"
        Write-Host ''

        $promptA = Build-PeerDispatchPrompt -RoundNumber $r -Label 'Agent-A'
        Write-Host '    Agent-A prompt (type EXACTLY):'
        Write-Host "    +----------------------------------------------------------+"
        Write-Host "    |  $promptA"
        Write-Host "    +----------------------------------------------------------+"
        Write-Host "    Wait for response containing 'Peer dispatch acknowledged.'"
        Write-Host ''

        $promptB = Build-PeerDispatchPrompt -RoundNumber $r -Label 'Agent-B'
        Write-Host '    Agent-B prompt (type EXACTLY):'
        Write-Host "    +----------------------------------------------------------+"
        Write-Host "    |  $promptB"
        Write-Host "    +----------------------------------------------------------+"
        Write-Host "    Wait for response containing 'Peer dispatch acknowledged.'"
        Write-Host ''

        if ($isWarmup) {
            Write-Host '    NOTE: This is a warmup round. cache_creation_input_tokens will be'
            Write-Host '          elevated. It will be EXCLUDED from the steady-state average.'
            Write-Host ''
        }
    }

    Write-Separator 'STOP CONDITION'
    Write-Host ''
    Write-Host "  STOP after Round $totalRounds (both Agent-A and Agent-B responses)."
    Write-Host '  Do NOT send additional prompts — the session boundary matters for'
    Write-Host '  accurate token-delta measurement.'
    Write-Host ''
    Write-Separator 'AFTER SESSION'
    Write-Host ''
    Write-Host '  Return to this terminal window and press Enter to invoke the cost walker.'
    Write-Host "  Warmup rounds (1-$WarmupRounds) will be labeled 'WARMUP -- excluded from steady-state avg'."
    Write-Separator
    Write-Host ''
}

# ── Walker invocation ─────────────────────────────────────────────────────────

function Invoke-Walker {
    param([string]$Platform, [int]$IssueNumber, [string]$Repo, [string]$Branch)

    Write-Host '-- Invoking cost walker --'

    $walkerPath = if ($Platform -eq 'claude') { $WalkerClaude } else { $WalkerCopilot }
    Write-Host "  Walker : $walkerPath"
    Write-Host "  Issue  : $IssueNumber  Repo: $Repo  Branch: $Branch"
    Write-Host ''

    if ($Platform -eq 'copilot' -and -not (Test-Path $CopilotSentinel)) {
        Write-Warning 'Copilot OTel collection not installed. Run Initialize-CopilotCostCollection.ps1 first (issue #538 has a known multi-git fix pending).'
    }

    $output   = ''
    $exitCode = 0
    try {
        $output = & $walkerPath `
            -IssueNumber $IssueNumber `
            -Repo $Repo `
            -Branch $Branch 2>&1 | Out-String
        # $LASTEXITCODE may be $null or empty-string for function-library scripts
        # that do not call exit explicitly — treat null/empty as success (0).
        $rawExit  = $LASTEXITCODE
        $exitCode = if ($null -ne $rawExit -and "$rawExit" -ne '') { [int]$rawExit } else { 0 }
    } catch {
        Write-Warning "Walker threw an exception: $_"
        $exitCode = 1
    }

    if ($exitCode -ne 0) {
        Write-Warning "Walker exited $exitCode -- check walker output above. SDK usage fallback: record token counts manually from session output."
    }

    return [pscustomobject]@{ Output = $output; ExitCode = $exitCode }
}

# ── Delta table display ───────────────────────────────────────────────────────

function Show-DeltaTable {
    param([string]$WalkerOutput, [int]$WarmupRounds, [string]$Mode)

    Write-Separator 'PER-ROUND TOKEN DELTA TABLE'
    Write-Host ''

    if ([string]::IsNullOrWhiteSpace($WalkerOutput)) {
        Write-Host '  (Walker produced no output -- 0 sessions matched the spike branch.)'
        Write-Host '  This is expected on a fresh run before any sessions are recorded.'
    } else {
        Write-Host $WalkerOutput
    }

    if ($Mode -eq 'run-prototype' -and $WarmupRounds -gt 0) {
        Write-Host ''
        Write-Host "  Warmup rounds (1-$WarmupRounds): WARMUP -- excluded from steady-state avg"
    }

    Write-Host ''
}

# ── Main ──────────────────────────────────────────────────────────────────────

Write-Host ''
Write-Host "Measurement-Orchestration Harness -- Issue #$IssueNumber"
Write-Host "Platform : $Platform  |  Mode: $Mode"
if ($Mode -eq 'run-prototype') {
    Write-Host "Rounds   : $Rounds steady-state + $WarmupRounds warmup = $($Rounds + $WarmupRounds) total"
}
Write-Host ''

switch ($Mode) {

    'self-validate' {
        Write-SelfValidateScript

        Wait-ForEnter 'After completing the session, press Enter to run cost walker...'

        $walkerResult = Invoke-Walker -Platform $Platform `
            -IssueNumber $IssueNumber `
            -Repo $Repo `
            -Branch $SpikeBranch

        Show-DeltaTable -WalkerOutput $walkerResult.Output `
            -WarmupRounds 0 `
            -Mode 'self-validate'

        if ($OutputJson) {
            [pscustomobject]@{
                mode           = $Mode
                platform       = $Platform
                issueNumber    = $IssueNumber
                branch         = $SpikeBranch
                walkerExitCode = $walkerResult.ExitCode
                walkerOutput   = $walkerResult.Output
            } | ConvertTo-Json -Depth 5 | Set-Content -Path $OutputJson -Encoding utf8
            Write-Host "Results written to: $OutputJson"
        }
    }

    'run-prototype' {
        Write-RunPrototypeScript -Rounds $Rounds -WarmupRounds $WarmupRounds

        Wait-ForEnter 'After completing all rounds, press Enter to run cost walker...'

        $walkerResult = Invoke-Walker -Platform $Platform `
            -IssueNumber $IssueNumber `
            -Repo $Repo `
            -Branch $SpikeBranch

        Show-DeltaTable -WalkerOutput $walkerResult.Output `
            -WarmupRounds $WarmupRounds `
            -Mode 'run-prototype'

        if ($OutputJson) {
            [pscustomobject]@{
                mode           = $Mode
                platform       = $Platform
                issueNumber    = $IssueNumber
                branch         = $SpikeBranch
                rounds         = $Rounds
                warmupRounds   = $WarmupRounds
                walkerExitCode = $walkerResult.ExitCode
                walkerOutput   = $walkerResult.Output
            } | ConvertTo-Json -Depth 5 | Set-Content -Path $OutputJson -Encoding utf8
            Write-Host "Results written to: $OutputJson"
        }
    }
}

Write-Host ''
Write-Host 'Harness complete.'
