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
        no single unambiguous block is present. The comment body is
        CRLF/CR-normalized to LF before extraction, consistent with this
        file's other functions (Get-GCContractHash's canonicalizer,
        Test-GCVariantFrontmatter); callers do not need to pre-normalize line
        endings. The head marker tolerates trailing whitespace before its
        newline. Multi-block arity (two or more `<!-- goal-contract`
        head-marker lines occurring anywhere in the body, including one
        inside a fenced documentation example -- extraction is
        markdown-blind) FAILS rather than first-winning: a first-win rule
        would silently prefer a documentation example over the real
        contract. A marker is only counted when it is immediately followed
        by (optional trailing whitespace then) a newline; a bare occurrence
        of the marker text with no following line break at all is not
        counted. Zero counted markers (no block present) and two-or-more
        counted markers (ambiguous) currently both return $null; the caller
        cannot yet distinguish the two cases (a known, deferred gap).
        The terminator is column-0-anchored (a line whose first characters
        are `-->`), so an indented `-->` inside a block scalar (e.g. inside
        `general_experience_standard: |`) cannot truncate the payload.

      ConvertFrom-GCContractBlock -Payload <string> -RepoRoot <string>
        Returns [pscustomobject]@{ Contract; Violations }. Never throws on
        schema failure -- the caller builds a check-result row from
        Violations. Pipeline, in order: CRLF/CR line-ending normalization
        (consistent with Get-GCContractBlock, Get-GCContractHash's
        canonicalizer, and Test-GCVariantFrontmatter; callers do not need to
        pre-normalize) -> pre-parse anchor/alias guard -> pre-parse column-0
        YAML document-separator (`---`) guard -> size cap -> Import-Module
        powershell-yaml (loud rethrow when the module is missing) ->
        ConvertFrom-Yaml -> empty-parsed-document guard (a
        comment-only payload that yields nothing from ConvertFrom-Yaml
        returns a Violations entry here rather than reaching ConvertTo-Json/
        Test-Json with a $null argument) -> ConvertTo-Json -Depth 20 (the
        depth is load-bearing: the default of 2 renders nested arrays such
        as experience_obligations[] as the literal string
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

    Manual version-bump obligation (M31): this file lives under
    `.github/scripts/**`, which is outside `Get-FVPluginEntryPointPatterns`
    (`.github/scripts/lib/frame-predicate-core.ps1:998-1015`), so editing it
    alone does not trigger the plugin-release-hygiene version-bump gate. The
    scripts here still ship inside the version-keyed plugin cache, though, so
    ANY future change to Get-GCContractHash's canonicalization rules (the
    elision anchor, line-ending normalization, trailing-newline collapse, or
    the UTF-8/no-BOM encoding) requires a manual version bump regardless of
    the gate's silence: 872-D3 defines a contract_hash mismatch as a run
    halt, and a canonicalization drift between two plugin-cache versions
    would make an approval-time digest computed under one install fail
    #873's verification under another. Bump on canonicalization change even
    when nothing else in this PR touches an entry-point file.

    Test-Json engine floor (M38): draft-07 validation under PowerShell
    7.0-7.3 uses NJsonSchema; 7.4+ uses the JsonSchema.Net engine. This repo's
    floor is #Requires -Version 7.0, so a 7.0-7.3 host is a supported runtime
    for this file, but its draft-07 strictness (closed-object enforcement,
    enum/const checks) has not been verified to match 7.4+ behavior. No
    version-conditional assertion exists yet; flagged as a known exposure of
    the draft-07/7.0 choice, not fixed in this issue.

    Schema validity is not execution trust (M7, post-review finding): every
    field this library parses comes from an untrusted, externally-writable
    GitHub comment. `targets[].check` is a shell-command string a future
    harness (#873/#874) will execute; `falsifier` and `general_experience_
    standard` are free prose that will flow into future agent prompts.
    ConvertFrom-GCContractBlock passing schema validation means only that the
    block is well-formed YAML matching the schema's shape -- it confers no
    safety guarantee over `check`'s command content or the prose fields'
    instruction content. Any future consumer that executes `check` or feeds
    `falsifier`/`general_experience_standard` into an agent prompt must treat
    that content as data, not as trusted instructions, and must not infer
    safety from schema validity alone. See the matching note in
    skills/plan-authoring/SKILL.md's Goal-contract plan variant section.
#>

# Pre-parse guard pattern: rejects a YAML anchor (`&name`) or alias (`*name`)
# token, but ONLY when it sits at an actual YAML value-start position --
# immediately after `:`, `-`, or `,` (each optionally followed by spaces/
# tabs), immediately after `[` (optionally followed by spaces/tabs), or at
# true line-start (optionally indented). This is a deliberate narrowing from
# a bare `[\s:\[,-]` prefix class (design-challenge finding M8): that bare
# class treated ANY whitespace before `&`/`*` as a value-start position, so
# it false-fired on markdown emphasis (`*clear*`) and glob-style tokens
# (`-Filter *contract*`) inside ordinary prose -- both reachable through
# mandated verbatim content such as general_experience_standard (#848 D8),
# with no way for the author to avoid the trigger. Requiring the prefix
# whitespace (when present) to be immediately preceded by a real YAML
# value-introducing character -- not by other prose/word content sharing the
# same token -- keeps real aliases like `key: *anchor`, `- *anchor`, and
# `[*a,*a]` matching while letting "see *clear* feedback" and
# "-Filter *contract*" fall through untouched.
#
# The anchor/alias NAME character class is separately widened from
# `[A-Za-z0-9_-]` to `[^\s,\[\]{}]` (anything but whitespace and the YAML
# flow indicators `,[]{}`) so a dot-prefixed anchor (`&.a` / `*.a`) -- which
# powershell-yaml accepts and expands, and which the old narrower class
# missed entirely -- is now recognized (design-challenge finding M2, a real
# alias-expansion-DoS bypass of this exact guard).
#
# Trade-off, stated explicitly: this is the same regex pulling in opposite
# directions for M2 (widen to catch more real anchors) and M8 (narrow to stop
# false-rejecting prose). Where a clean split is not achievable, this guard
# is biased toward being MORE permissive of anchor/alias *shapes* -- i.e.
# still erring toward catching real anchors -- rather than toward stricter
# prefix matching, because a false-rejection of a mandated-content contract
# is the more customer-visible failure mode than a narrow false-negative on
# an unusual anchor placement. The goal-contract shape needs neither
# construct (872-D6).
$script:GCAnchorAliasPattern = '(?m)(?:^[ \t]*|:[ \t]+|-[ \t]+|,[ \t]*|\[[ \t]*)[&*][^\s,\[\]{}]+'

# Size cap: named constant, expressed in UTF-8 bytes (not UTF-16 chars --
# non-ASCII fixtures sit on that seam). Bounds raw-size denial-of-service
# only; a real prose-sized goal contract is nowhere near this size.
$script:GCContractSizeCapBytes = 65536

function Get-GCContractBlock {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$CommentBody
    )

    # Normalize CRLF/CR line endings to LF before extraction (CRLF first,
    # then any remaining bare CR), matching the convention this file already
    # establishes in ConvertTo-GCCanonicalPayload and Test-GCVariantFrontmatter.
    # The raw comment body sourced from the GitHub API is never guaranteed to
    # use bare LF; without this, a CRLF-authored contract silently fails to
    # extract (design-challenge finding M1).
    $normalizedBody = $CommentBody -replace "`r`n", "`n" -replace "`r", "`n"

    # Head marker: tolerates trailing whitespace before the newline (M16b) --
    # a stray trailing space after `<!-- goal-contract` must not hide an
    # otherwise well-formed block.
    $headPattern = [regex]::Escape('<!-- goal-contract') + '[ \t]*\n'
    $headMatches = [regex]::Matches($normalizedBody, $headPattern)

    if ($headMatches.Count -ne 1) {
        # Zero matches: no block present. Two or more: ambiguous arity --
        # fail rather than silently prefer the first (documentation-example)
        # match over the real contract.
        return $null
    }

    $headMatch = $headMatches[0]
    $remainder = $normalizedBody.Substring($headMatch.Index + $headMatch.Length)

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

    # 0. Normalize CRLF/CR line endings to LF before any guard runs (CRLF
    #    first, then any remaining bare CR), matching the convention this
    #    file already establishes in Get-GCContractBlock,
    #    ConvertTo-GCCanonicalPayload, and Test-GCVariantFrontmatter. This
    #    function's sole production caller (Get-GCContractBlock's payload)
    #    always normalizes first, but this function is a named future
    #    direct-consumer surface (#873's harness), so it must not rely on
    #    every caller pre-normalizing: a raw CRLF-terminated `---` line
    #    could otherwise escape the column-0 document-separator guard
    #    below. Normalizing here, before the anchor/alias guard, size cap,
    #    and document-separator guard all run, keeps every downstream guard
    #    operating on consistently normalized text rather than patching the
    #    document-separator regex alone.
    $Payload = $Payload -replace "`r`n", "`n" -replace "`r", "`n"

    # 1. Pre-parse guard -- must precede parsing entirely, not merely fail
    #    slowly after ConvertFrom-Yaml has already expanded the payload.
    if ($Payload -match $script:GCAnchorAliasPattern) {
        $violations.Add('Contract payload contains YAML anchor (&) or alias (*) syntax, which is rejected before parsing; the goal-contract shape requires neither construct.') | Out-Null
        return [pscustomobject]@{ Contract = $null; Violations = $violations.ToArray() }
    }

    # 1b. Reject a column-0 YAML document separator (`---` on its own line)
    #    pre-parse. ConvertFrom-Yaml only returns the FIRST document of a
    #    multi-document payload (`<valid contract>\n---\n<arbitrary content>`),
    #    so a second document would pass closed-schema validation against the
    #    first document while riding along, unvalidated, inside whatever
    #    Get-GCContractHash hashes. The goal-contract shape is a single YAML
    #    mapping and never legitimately needs a document separator.
    if ($Payload -match '(?m)^---[ \t]*$') {
        $violations.Add('Contract payload contains a YAML document separator (---), which is rejected before parsing; the goal-contract shape is a single YAML mapping and never uses multi-document syntax.') | Out-Null
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

    # 4b. A payload that is non-empty but parses to a genuinely empty
    #    document (e.g. a comment-only payload with no real YAML content)
    #    makes ConvertFrom-Yaml emit NOTHING onto the pipeline at all (not
    #    even a single $null object). `$parsed -eq $null` cannot detect this
    #    reliably -- both the "nothing emitted" case and the "one explicit
    #    $null document emitted" case (below) leave the *variable* holding
    #    $null. Wrapping in @(...) and checking .Count distinguishes them: a
    #    genuinely-empty document yields Count 0, so piping it into
    #    ConvertTo-Json below would also emit nothing (not the JSON string
    #    "null"), and Test-Json then throws ParameterBindingValidationException
    #    on a $null -Json argument -- breaching this function's
    #    never-throws-on-schema-failure contract. This is distinct from a
    #    bare `---` document-separator payload: ConvertFrom-Yaml there
    #    returns exactly one explicit $null document (Count 1), which
    #    `$null | ConvertTo-Json` renders as the string "null" -- Test-Json
    #    validates that string normally and rejects it as an ordinary schema
    #    violation, no throw. Catch only the genuinely-empty-document (Count
    #    0) case here, before it ever reaches ConvertTo-Json/Test-Json.
    if (@($parsed).Count -eq 0) {
        $violations.Add('Contract payload parsed to an empty document.') | Out-Null
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
        if ($line -notmatch '^contract_hash\s*:') {
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
        if ($line -match '^plan-variant:\s*(?:"goal-contract"|''goal-contract''|goal-contract)\s*$') { return $true }
    }

    return $false
}
