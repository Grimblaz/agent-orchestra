#Requires -Version 7.0
<#
.SYNOPSIS
    Transcript-content barrier primitives for the goal-run harness (issue
    #874, plan step 1, AC2 item 3).
.DESCRIPTION
    Shared by goal-run-status-core.ps1 (the goal_status transcript reader)
    and goal-run-halt-core.ps1 (the halt-report emitter). Owns the two
    guardrails that stand between raw, untrusted session-transcript content
    and any durable artifact (a halt-report evidence[]/budget_snapshot
    field, a run-log entry, or any GitHub comment):

      Get-GoalRunTranscriptRoot
        Resolves the platform session-transcript root directory
        ($HOME/.claude/projects on POSIX, $env:USERPROFILE\.claude\projects
        on Windows) -- never a hardcoded `C:\...` literal.

      Select-GoalRunAllowedFields -Source <IDictionary> -AllowList <string[]>
        The allow-list extractor. Only keys named in -AllowList are copied
        from -Source to the result; every other key on -Source (an
        attacker- or model-controlled transcript event) is dropped and
        reported back via .RejectedKeys so a caller/test can assert nothing
        else leaked through. A value under an allow-listed key name is ALSO
        dropped (and reported in .RejectedKeys) when it is itself a nested
        dictionary or a non-string enumerable -- a poisoned transcript event
        cannot smuggle arbitrary structured content underneath a trusted key
        name. Returns [pscustomobject]@{ Fields; RejectedKeys }.

      Get-GoalRunRedactedText -Text <string>
        The secret-pattern redaction pass. Runs a fixed set of secret-shaped
        regexes (GitHub tokens, AWS access key IDs, Slack tokens, PEM
        private-key blocks, bearer tokens, and generic key=value secret
        assignments) over -Text and replaces each match with a
        `[REDACTED:<pattern-name>]` placeholder. Must run on every
        transcript-derived string (e.g. goal_status.condition/reason)
        before it reaches any durable artifact.

    Neither primitive alone is the full barrier: Select-GoalRunAllowedFields
    bounds WHICH fields can flow through by name and type; Get-GoalRunRedactedText
    bounds WHAT CONTENT those allowed free-text fields may carry. Both must
    run on any transcript-derived value before it is embedded in a durable
    comment.
#>

function Get-GoalRunTranscriptRoot {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    # Deliberately resolved via $env:USERPROFILE on Windows / $HOME on POSIX
    # rather than a single ambient $HOME lookup, per the #874 plan step 1
    # requirement contract -- never a hardcoded `C:\...` literal.
    $base = if ($IsWindows) { $env:USERPROFILE } else { $HOME }
    return (Join-Path $base '.claude' 'projects')
}

function Select-GoalRunAllowedFields {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Source,
        [Parameter(Mandatory)][string[]]$AllowList
    )

    $included = [ordered]@{}
    $rejectedKeys = [System.Collections.Generic.List[string]]::new()

    foreach ($key in $Source.Keys) {
        if ($AllowList -notcontains $key) {
            $rejectedKeys.Add($key) | Out-Null
            continue
        }

        $value = $Source[$key]

        # A nested dictionary, or a non-string enumerable, under an
        # allow-listed key name is refused too -- only scalar (typed or
        # numeric or plain string) values pass through by design (item 3 of
        # the requirement contract: "only typed/numeric fields ... are read
        # by explicit key name; no free-text transcript passthrough").
        $isNestedDictionary = $value -is [System.Collections.IDictionary]
        $isNonStringEnumerable = ($value -is [System.Collections.IEnumerable]) -and ($value -isnot [string])
        if ($isNestedDictionary -or $isNonStringEnumerable) {
            $rejectedKeys.Add($key) | Out-Null
            continue
        }

        $included[$key] = $value
    }

    return [pscustomobject]@{
        Fields       = [pscustomobject]$included
        RejectedKeys = $rejectedKeys.ToArray()
    }
}

# Named secret-shaped patterns. Each entry redacts to `[REDACTED:<Name>]` so
# a reviewer of a posted comment can see THAT something was redacted and
# WHAT KIND of pattern tripped, without the underlying secret ever reaching
# the durable artifact.
$script:GoalRunSecretPatterns = @(
    @{ Name = 'github-token'; Pattern = '\bgh[oprsu]_[A-Za-z0-9]{20,}\b' }
    @{ Name = 'github-fine-pat'; Pattern = '\bgithub_pat_[A-Za-z0-9_]{20,}\b' }
    @{ Name = 'aws-access-key-id'; Pattern = '\bAKIA[0-9A-Z]{16}\b' }
    @{ Name = 'slack-token'; Pattern = '\bxox[baprs]-[A-Za-z0-9-]{10,}\b' }
    @{ Name = 'private-key-block'; Pattern = '(?s)-----BEGIN [A-Z ]*PRIVATE KEY-----.*?-----END [A-Z ]*PRIVATE KEY-----' }
    @{ Name = 'bearer-token'; Pattern = '(?i)\bbearer\s+[A-Za-z0-9\-_.]{20,}' }
    @{ Name = 'kv-secret-assignment'; Pattern = '(?i)\b(api[_-]?key|secret|password|token)\b\s*[:=]\s*[''"]?[A-Za-z0-9\-_.]{12,}[''"]?' }
)

function Get-GoalRunRedactedText {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text
    )

    $redacted = $Text
    foreach ($p in $script:GoalRunSecretPatterns) {
        $redacted = [regex]::Replace($redacted, $p.Pattern, "[REDACTED:$($p.Name)]")
    }
    return $redacted
}
