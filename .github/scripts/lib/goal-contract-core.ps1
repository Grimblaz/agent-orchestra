#Requires -Version 7.0

<#
.SYNOPSIS
    Core parser library for the goal-contract plan-seat variant (issue #872,
    frame-slice s2; design decisions 872-D2/872-D3/872-D6).

.DESCRIPTION
    The one shared block-extraction and parsing library for every goal-contract
    consumer (frame-validate-core.ps1, orchestra-spine.ps1, and #873's
    verification harness) so no reader hand-rolls its own regex or re-encodes
    the schema's enums.

      Get-GCContractBlock -CommentBody <string>
        Extracts the goal-contract block payload (the text between the
        `<!-- goal-contract` head marker and the terminator), or $null when
        no single unambiguous block is present. Multi-block arity (two or
        more `<!-- goal-contract` occurrences anywhere in the body, including
        one inside a fenced documentation example -- extraction is
        markdown-blind) FAILS rather than first-winning: a first-win rule
        would silently prefer a documentation example over the real contract.
        The terminator is column-0-anchored (a line whose first characters
        are `-->`), so an indented `-->` inside a block scalar (e.g. inside
        `general_experience_standard: |`) cannot truncate the payload.

      ConvertFrom-GCContractBlock -Payload <string> -RepoRoot <string>
        Returns [pscustomobject]@{ Contract; Violations }. Never throws on
        schema failure -- the caller builds a check-result row from
        Violations. Pipeline, in order: pre-parse anchor/alias guard -> size
        cap -> Import-Module powershell-yaml (loud rethrow when the module is
        missing) -> ConvertFrom-Yaml -> ConvertTo-Json -Depth 20 (the depth is
        load-bearing: the default of 2 renders nested arrays such as
        experience_obligations[] as the literal string
        System.Collections.Hashtable) -> Test-Json against the schema file.
        -RepoRoot is mandatory, matching the phase-containment-core.ps1:577-584
        precedent for reading a skills/**/schemas/*.json file.

      Get-GCContractHash -Payload <string>
        Returns a 64-hex sha256 digest over the canonicalized payload body
        (872-D3): the `contract_hash:` line elided in full when it starts at
        column 0 (an indented occurrence inside a block scalar is prose
        content and is NOT elided), CRLF/CR line endings normalized to LF,
        per-line trailing whitespace stripped, the trailing newline run
        collapsed to exactly one, encoded UTF-8 without BOM. The caller is
        responsible for sourcing the comment body from the GitHub API JSON
        `body` field, never console-rendered output (872-D3 byte-source
        rule; #862 OEM-mangling history).

      Test-GCContractHash -Payload <string> -Expected <string>
        Returns $true when Get-GCContractHash's digest of Payload equals
        Expected.

      Test-GCVariantFrontmatter -CommentBody <string>
        Returns $true when the plan comment's frontmatter region (the first
        `---`-fenced block after any leading HTML-comment marker lines --
        never a body-wide line match, which false-fires on plans that merely
        quote the literal in prose) declares `plan-variant: goal-contract`.
        Exposed here so frame-validate and orchestra-spine share one rule
        (872-D5/C6) instead of hand-rolling two.

.NOTES
    The pre-parse anchor/alias guard, not the size cap, is what bounds YAML
    alias-expansion on untrusted comment bodies (design-challenge finding M1):
    a handful of anchors aliased repeatedly can expand to tens of thousands of
    nodes if handed to ConvertFrom-Yaml. The size cap's job is bounding raw
    payload size only.
#>

# Pre-parse guard pattern: rejects a YAML anchor (`&name`) or alias (`*name`)
# token wherever it appears in a value position (preceded by line-start,
# whitespace, `:`, `[`, `,`, or `-`). The goal-contract shape needs neither
# construct (872-D6).
$script:GCAnchorAliasPattern = '(?m)(^|[\s:\[,-])[&*][A-Za-z0-9_-]+'

# Size cap: named constant, expressed in UTF-8 bytes (not UTF-16 chars --
# non-ASCII fixtures sit on that seam). Bounds raw-size denial-of-service
# only; a real prose-sized goal contract is nowhere near this size.
$script:GCContractSizeCapBytes = 65536

function Get-GCContractBlock {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$CommentBody
    )

    $headPattern = [regex]::Escape('<!-- goal-contract') + "`n"
    $headMatches = [regex]::Matches($CommentBody, $headPattern)

    if ($headMatches.Count -ne 1) {
        # Zero matches: no block present. Two or more: ambiguous arity --
        # fail rather than silently prefer the first (documentation-example)
        # match over the real contract.
        return $null
    }

    $headMatch = $headMatches[0]
    $remainder = $CommentBody.Substring($headMatch.Index + $headMatch.Length)

    $terminatorMatch = [regex]::Match($remainder, '(?m)^-->')
    if (-not $terminatorMatch.Success) {
        return $null
    }

    $payload = $remainder.Substring(0, $terminatorMatch.Index)
    if ($payload.EndsWith("`n")) {
        $payload = $payload.Substring(0, $payload.Length - 1)
    }

    return $payload
}

function ConvertFrom-GCContractBlock {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Payload,
        [Parameter(Mandatory)][string]$RepoRoot
    )

    $violations = [System.Collections.Generic.List[string]]::new()

    # 1. Pre-parse guard -- must precede parsing entirely, not merely fail
    #    slowly after ConvertFrom-Yaml has already expanded the payload.
    if ($Payload -match $script:GCAnchorAliasPattern) {
        $violations.Add('Contract payload contains YAML anchor (&) or alias (*) syntax, which is rejected before parsing; the goal-contract shape requires neither construct.') | Out-Null
        return [pscustomobject]@{ Contract = $null; Violations = $violations.ToArray() }
    }

    # 2. Size cap -- must precede parsing so an oversized-and-malformed
    #    payload fails with the cap reason, not a downstream parse error.
    $payloadByteCount = [System.Text.Encoding]::UTF8.GetByteCount($Payload)
    if ($payloadByteCount -gt $script:GCContractSizeCapBytes) {
        $violations.Add("Contract payload is $payloadByteCount bytes, exceeding the $script:GCContractSizeCapBytes-byte size cap.") | Out-Null
        return [pscustomobject]@{ Contract = $null; Violations = $violations.ToArray() }
    }

    # 3. Loud module-missing throw -- copies the shape of
    #    followup-gate-core.ps1:266-270 / frame-engagement-record-core.ps1:85-90.
    #    Frame-validate plan mode is manual-only, so a missing local module
    #    must fail actionably, never silently.
    try {
        Import-Module powershell-yaml -ErrorAction Stop
    } catch {
        throw [System.InvalidOperationException]::new("powershell-yaml module is required but could not be loaded: $_")
    }

    # 4. Parse. A YAML syntax error is a schema-pipeline violation, not a
    #    thrown exception, per this function's never-throws-on-schema-failure
    #    contract.
    try {
        $parsed = ConvertFrom-Yaml -Yaml $Payload -ErrorAction Stop
    } catch {
        $violations.Add("YAML parse error: $($_.Exception.Message)") | Out-Null
        return [pscustomobject]@{ Contract = $null; Violations = $violations.ToArray() }
    }

    # 5. Explicit depth is load-bearing: the ConvertTo-Json default of 2
    #    silently renders experience_obligations[] as the literal string
    #    "System.Collections.Hashtable", which both fails valid contracts and
    #    lets a deep object satisfy a type: string slot.
    $json = $parsed | ConvertTo-Json -Depth 20

    $schemaPath = Join-Path $RepoRoot 'skills/plan-authoring/schemas/goal-contract.schema.json'
    if (-not (Test-Path -LiteralPath $schemaPath)) {
        $violations.Add("Schema file not found at $schemaPath") | Out-Null
        return [pscustomobject]@{ Contract = $null; Violations = $violations.ToArray() }
    }
    $schemaRaw = Get-Content -LiteralPath $schemaPath -Raw

    $testJsonError = $null
    $isValid = Test-Json -Json $json -Schema $schemaRaw -ErrorVariable testJsonError -ErrorAction SilentlyContinue

    if (-not $isValid) {
        $detail = if ($testJsonError -and $testJsonError.Count -gt 0) {
            (($testJsonError | ForEach-Object { $_.Exception.Message }) -join '; ')
        } else {
            'Contract failed schema validation.'
        }
        $violations.Add($detail) | Out-Null
        return [pscustomobject]@{ Contract = $null; Violations = $violations.ToArray() }
    }

    return [pscustomobject]@{ Contract = $parsed; Violations = @() }
}

function script:ConvertTo-GCCanonicalPayload {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Payload
    )

    $text = $Payload
    if ($text.Length -gt 0 -and $text[0] -eq [char]0xFEFF) {
        $text = $text.Substring(1)
    }

    # Normalize line endings to LF (CRLF first, then any remaining bare CR).
    $text = $text -replace "`r`n", "`n"
    $text = $text -replace "`r", "`n"

    $lines = $text -split "`n"

    # Elide any column-0-anchored `contract_hash:` line in full (the field's
    # own line, including its newline) so the digest is stable whether the
    # field is absent, present, or holds a stale value (elision invariant).
    # A `contract_hash:` line indented inside a block scalar is prose
    # content, not the field, and must NOT be elided.
    $keptLines = [System.Collections.Generic.List[string]]::new()
    foreach ($line in $lines) {
        if ($line -notmatch '^contract_hash:') {
            $keptLines.Add($line) | Out-Null
        }
    }

    # Strip per-line trailing whitespace.
    $trimmedLines = [System.Collections.Generic.List[string]]::new()
    foreach ($line in $keptLines) {
        $trimmedLines.Add(($line -replace '[ \t]+$', '')) | Out-Null
    }

    # Collapse final-newline arity: drop all trailing empty "lines" (each
    # represents one trailing `\n`), then append exactly one.
    while ($trimmedLines.Count -gt 0 -and $trimmedLines[$trimmedLines.Count - 1] -eq '') {
        $trimmedLines.RemoveAt($trimmedLines.Count - 1)
    }

    return (($trimmedLines -join "`n") + "`n")
}

function Get-GCContractHash {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Payload
    )

    $canonical = script:ConvertTo-GCCanonicalPayload -Payload $Payload
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($canonical)

    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hashBytes = $sha256.ComputeHash($bytes)
    } finally {
        $sha256.Dispose()
    }

    return ([System.BitConverter]::ToString($hashBytes) -replace '-', '').ToLowerInvariant()
}

function Test-GCContractHash {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Payload,
        [Parameter(Mandatory)][string]$Expected
    )

    return ((Get-GCContractHash -Payload $Payload) -eq $Expected.ToLowerInvariant())
}

function Test-GCVariantFrontmatter {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$CommentBody
    )

    if ([string]::IsNullOrWhiteSpace($CommentBody)) { return $false }

    $normalized = $CommentBody -replace "`r`n", "`n" -replace "`r", "`n"
    $lines = $normalized -split "`n"

    # Skip leading HTML-comment marker lines and blank lines -- a real
    # persisted plan comment carries `<!-- plan-issue-{ID} -->` and
    # `<!-- phase-containment-ledger-ref: ... -->` above the frontmatter
    # (Issue-Planner.agent.md:132, plan-authoring/SKILL.md:373), so the `---`
    # fence is never line 1.
    $index = 0
    while ($index -lt $lines.Count -and (($lines[$index].Trim() -eq '') -or $lines[$index].Trim().StartsWith('<!--'))) {
        $index++
    }

    if ($index -ge $lines.Count -or $lines[$index].Trim() -ne '---') {
        return $false
    }

    $frontmatterLines = [System.Collections.Generic.List[string]]::new()
    $closed = $false
    for ($i = $index + 1; $i -lt $lines.Count; $i++) {
        if ($lines[$i].Trim() -eq '---') { $closed = $true; break }
        $frontmatterLines.Add($lines[$i]) | Out-Null
    }

    if (-not $closed) { return $false }

    foreach ($line in $frontmatterLines) {
        if ($line -match '^plan-variant:\s*goal-contract\s*$') { return $true }
    }

    return $false
}
