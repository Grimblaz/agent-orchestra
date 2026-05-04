# scope: claude-only
#Requires -Version 7.0

<#
.SYNOPSIS
    Construct a subagent-env-handshake v1 block for Claude Code Agent-tool dispatch.

.DESCRIPTION
    Implements the parent-side carrier for the handshake contract documented at
    skills/subagent-env-handshake/SKILL.md. The produced block is intended to
    be prepended to the Agent tool's `prompt` parameter so the dispatched
    subagent can parse and live-verify its working-tree view against the
    parent's before emitting tree-grounded claims.

    Field names and order must match the schema block in SKILL.md. The
    schema-parity Pester test at .github/scripts/Tests/subagent-env-handshake.Tests.ps1
    locks drift across this helper, the SKILL.md schema, and the verifier.

    Scope: claude-only. Copilot subagent dispatch does not exhibit the
    tree-view divergence this handshake exists to catch.
#>

function Get-DirtyTreeFingerprint {
    <#
    .SYNOPSIS
        SHA-256 (first 12 hex chars) of `git status --porcelain` output with line endings normalized to LF.

    .PARAMETER PorcelainOutput
        Optional string; when supplied, used instead of invoking git. Intended for
        unit testing with mocked input.

    .OUTPUTS
        String — 12 lowercase hex characters.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [string]$PorcelainOutput
    )

    if ($PSBoundParameters.ContainsKey('PorcelainOutput')) {
        $raw = $PorcelainOutput
    }
    else {
        $raw = & git status --porcelain 2>$null | Out-String
        if ($LASTEXITCODE -ne 0) {
            throw "git status --porcelain returned non-zero exit code $LASTEXITCODE"
        }
    }

    # Normalize line endings to LF so fingerprint is stable across OS.
    $normalized = ($raw -replace "`r`n", "`n") -replace "`r", "`n"
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($normalized)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hashBytes = $sha.ComputeHash($bytes)
    }
    finally {
        $sha.Dispose()
    }

    $hex = -join ($hashBytes | ForEach-Object { $_.ToString('x2') })
    return $hex.Substring(0, 12)
}

function New-SubagentDispatchPrompt {
    <#
    .SYNOPSIS
        Construct the subagent-env-handshake v1 block.

    .PARAMETER HeadSha
        Parent's live `git rev-parse HEAD` — 40 hex characters.

    .PARAMETER Branch
        Parent's live `git rev-parse --abbrev-ref HEAD`.

    .PARAMETER Cwd
        Parent's live working directory (absolute path).

    .PARAMETER DirtyFingerprint
        SHA-256(LF-normalized `git status --porcelain`):12 — typically from Get-DirtyTreeFingerprint.

    .PARAMETER WorkspaceMode
        'shared' (default) or 'worktree' (reserved — subagent v1 verifiers treat as error path).

    .PARAMETER IssuedAt
        ISO-8601 UTC timestamp. Default: current UTC time from Get-Date.

    .OUTPUTS
        String — the full handshake block including the opening `<!-- subagent-env-handshake v1 -->`
        comment, the six `key: value` lines in the canonical order, and the closing
        `<!-- /subagent-env-handshake -->` comment. No trailing newline.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidatePattern('^[0-9a-f]{40}$')]
        [string]$HeadSha,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Branch,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Cwd,

        [Parameter(Mandatory = $true)]
        [ValidatePattern('^[0-9a-f]{12}$')]
        [string]$DirtyFingerprint,

        [Parameter(Mandatory = $false)]
        [ValidateSet('shared', 'worktree')]
        [string]$WorkspaceMode = 'shared',

        [Parameter(Mandatory = $false)]
        [string]$IssuedAt
    )

    if (-not $PSBoundParameters.ContainsKey('IssuedAt') -or [string]::IsNullOrWhiteSpace($IssuedAt)) {
        $IssuedAt = (Get-Date).ToUniversalTime().ToString('o')
    }

    $lines = @(
        '<!-- subagent-env-handshake v1 -->',
        "parent_head: $HeadSha",
        "parent_branch: $Branch",
        "parent_cwd: $Cwd",
        "parent_dirty_fingerprint: $DirtyFingerprint",
        "workspace_mode: $WorkspaceMode",
        "handshake_issued_at: $IssuedAt",
        '<!-- /subagent-env-handshake -->'
    )

    return ($lines -join "`n")
}

function Get-FreshHandshake {
    <#
    .SYNOPSIS
        Live-capture all four handshake fields and return a ready-to-prepend handshake block.

    .DESCRIPTION
        Captures parent_head, parent_branch, parent_cwd, and parent_dirty_fingerprint from the
        live working tree, then delegates to New-SubagentDispatchPrompt to produce the block.

        parent_cwd is captured by invoking bash -c "pwd" so the path uses the Unix-style format
        (/c/Users/...) produced by the Bash tool — not the Windows-style C:\Users\... produced by
        (Get-Location).Path, which the SKILL.md CWD-format-mismatch gotcha explicitly forbids.

        All git calls run inside Push-Location / Pop-Location against RepoRoot so the function
        is safe to call from any PowerShell working directory.

    .PARAMETER HeadShaOverride
        When supplied, used instead of invoking git rev-parse HEAD. Intended for unit testing.

    .PARAMETER BranchOverride
        When supplied, used instead of invoking git rev-parse --abbrev-ref HEAD. Intended for
        unit testing.

    .PARAMETER CwdOverride
        When supplied, used instead of invoking bash -c "pwd". Intended for unit testing.

    .PARAMETER PorcelainOutput
        When supplied, passed through to Get-DirtyTreeFingerprint instead of invoking git.
        Intended for unit testing — same injection pattern as Get-DirtyTreeFingerprint.

    .PARAMETER RepoRoot
        Absolute path to the repository root. Defaults to the PowerShell provider path for
        the current location. All git calls run from this directory.

    .OUTPUTS
        String — the full handshake block produced by New-SubagentDispatchPrompt.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [string]$HeadShaOverride,

        [Parameter(Mandatory = $false)]
        [string]$BranchOverride,

        [Parameter(Mandatory = $false)]
        [string]$CwdOverride,

        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [string]$PorcelainOutput,

        [Parameter(Mandatory = $false)]
        [string]$RepoRoot = $PWD.ProviderPath
    )

    Push-Location $RepoRoot
    try {
        if ($PSBoundParameters.ContainsKey('HeadShaOverride') -and -not [string]::IsNullOrWhiteSpace($HeadShaOverride)) {
            $head = $HeadShaOverride
        }
        else {
            $head = & git rev-parse HEAD 2>$null
            if ($LASTEXITCODE -ne 0) {
                throw "git rev-parse HEAD returned non-zero exit code $LASTEXITCODE"
            }
            $head = $head.Trim()
        }

        if ($PSBoundParameters.ContainsKey('BranchOverride') -and -not [string]::IsNullOrWhiteSpace($BranchOverride)) {
            $branch = $BranchOverride
        }
        else {
            $branch = & git rev-parse --abbrev-ref HEAD 2>$null
            if ($LASTEXITCODE -ne 0) {
                throw "git rev-parse --abbrev-ref HEAD returned non-zero exit code $LASTEXITCODE"
            }
            $branch = $branch.Trim()
        }

        if ($PSBoundParameters.ContainsKey('CwdOverride') -and -not [string]::IsNullOrWhiteSpace($CwdOverride)) {
            $cwd = $CwdOverride
        }
        else {
            $cwd = & bash -c 'pwd' 2>$null
            if ($LASTEXITCODE -ne 0) {
                throw "bash -c 'pwd' returned non-zero exit code $LASTEXITCODE"
            }
            $cwd = $cwd.Trim()
        }

        if ($PSBoundParameters.ContainsKey('PorcelainOutput')) {
            $fingerprint = Get-DirtyTreeFingerprint -PorcelainOutput $PorcelainOutput
        }
        else {
            $fingerprint = Get-DirtyTreeFingerprint
        }
    }
    finally {
        Pop-Location
    }

    return New-SubagentDispatchPrompt -HeadSha $head -Branch $branch -Cwd $cwd -DirtyFingerprint $fingerprint
}
