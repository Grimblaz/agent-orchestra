# scope: claude-only
#Requires -Version 7.0

<#
.SYNOPSIS
    Test-time stub of the subagent-side handshake verifier decision tree.

.DESCRIPTION
    A pure, deterministic implementation of the match / mismatch / error /
    missing-handshake decision branching documented in
    skills/subagent-env-handshake/SKILL.md and quoted prose-side in
    agents/issue-planner.md ## Step 0: Environment Handshake Verification.

    The stub exists exclusively for the Pester harness. Its purpose is to
    anchor the decision-tree contract in code so the step-3 scenario (g)
    parity test can enforce lockstep ordering and branching with the LLM
    prose in the Claude shell. If drift appears between this stub's
    decision-tree block and the shell's anchor block, the test fails and
    the drift is surfaced pre-merge.

    This stub is NOT invoked by the real subagent at runtime. The real
    subagent-side verifier is the LLM executing the Step 0 prose.

    Scope: claude-only.
#>

# --- subagent-env-handshake v1 decision tree ---
# 1. match             -> proceed (silent)
# 2. mismatch          -> halt + emit ND-2 environment-divergence finding
# 3. error             -> proceed + tag tree-grounded findings environment-unverified
# 4. missing-handshake -> proceed + tag tree-grounded findings environment-unverified
# --- end subagent-env-handshake v1 decision tree ---

function Read-SubagentEnvHandshakeBlock {
    <#
    .SYNOPSIS
        Parse a handshake v1 block from dispatch prompt text.

    .OUTPUTS
        Hashtable with keys parent_head, parent_branch, parent_cwd,
        parent_dirty_fingerprint, workspace_mode, handshake_issued_at —
        or $null if no well-formed block is present.
    #>
    [OutputType([hashtable])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$PromptText
    )

    $blockPattern = '(?ms)<!-- subagent-env-handshake v1 -->\s*\r?\n(?<body>.*?)\r?\n\s*<!-- /subagent-env-handshake -->'
    $blockMatch = [regex]::Match($PromptText, $blockPattern)
    if (-not $blockMatch.Success) {
        return $null
    }

    $parsed = @{}
    $fieldPattern = '^(?<key>[a-z_]+):\s*(?<value>.+?)\s*$'
    foreach ($line in ($blockMatch.Groups['body'].Value -split "`r?`n")) {
        $fieldMatch = [regex]::Match($line, $fieldPattern)
        if ($fieldMatch.Success) {
            $parsed[$fieldMatch.Groups['key'].Value] = $fieldMatch.Groups['value'].Value
        }
    }

    $requiredFields = @('parent_head', 'parent_branch', 'parent_cwd', 'parent_dirty_fingerprint', 'workspace_mode', 'handshake_issued_at')
    foreach ($f in $requiredFields) {
        if (-not $parsed.ContainsKey($f)) {
            return $null
        }
    }

    return $parsed
}

function Invoke-SubagentEnvHandshakeVerifier {
    <#
    .SYNOPSIS
        Decision-tree stub for the subagent-side handshake verifier.

    .PARAMETER PromptText
        The dispatch prompt as received by the subagent. May or may not contain a handshake block.

    .PARAMETER Observed
        Hashtable of live-verified observed values (parent_head, parent_branch,
        parent_cwd, parent_dirty_fingerprint).

    .PARAMETER GitFailed
        Switch signalling that one or more of the subagent's live `git` invocations
        returned non-zero. Routes to error path regardless of handshake contents.

    .OUTPUTS
        Hashtable with keys:
          - outcome      — one of 'match', 'mismatch', 'error', 'missing-handshake'
          - diverged_fields — array of field names that diverged (only for mismatch)
          - finding_heading — for mismatch: '## Finding: environment-divergence (halting)'
          - tag          — for error / missing-handshake: 'environment-unverified'
    #>
    [OutputType([hashtable])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$PromptText,

        [Parameter(Mandatory = $false)]
        [hashtable]$Observed,

        [Parameter(Mandatory = $false)]
        [switch]$GitFailed
    )

    $handshake = Read-SubagentEnvHandshakeBlock -PromptText $PromptText

    if ($null -eq $handshake) {
        return @{
            outcome = 'missing-handshake'
            tag     = 'environment-unverified'
        }
    }

    if ($GitFailed.IsPresent) {
        return @{
            outcome = 'error'
            tag     = 'environment-unverified'
        }
    }

    if ($handshake['workspace_mode'] -eq 'worktree') {
        # Reserved value in v1 — treated uniformly as error path.
        return @{
            outcome = 'error'
            tag     = 'environment-unverified'
        }
    }

    if ($null -eq $Observed) {
        return @{
            outcome = 'error'
            tag     = 'environment-unverified'
        }
    }

    $diverged = @()
    # Compares the four live-verifiable fields only (ND-4 scope).
    # workspace_mode: handled above via reserved-value check.
    # handshake_issued_at: excluded — no live counterpart; timestamp cannot be re-derived by subagent.
    foreach ($field in @('parent_head', 'parent_branch', 'parent_cwd', 'parent_dirty_fingerprint')) {
        if ($handshake[$field] -ne $Observed[$field]) {
            $diverged += $field
        }
    }

    if ($diverged.Count -eq 0) {
        return @{
            outcome = 'match'
        }
    }

    return @{
        outcome         = 'mismatch'
        diverged_fields = $diverged
        finding_heading = '## Finding: environment-divergence (halting)'
    }
}
