#Requires -Version 7.0
<#
.SYNOPSIS
    JSONL transcript walker for cost-telemetry per-event cwd+gitBranch filter (issue #467, D1).
.DESCRIPTION
    Discovers all Claude session JSONL files matching the given slug (and worktree slugs),
    applies a per-event cwd+gitBranch filter, traverses subagent transcripts for included
    tool_use Agent dispatches, and returns an aggregated array of included event objects.

    Dependencies:
      - path-normalize.ps1 must be dot-sourced before calling Invoke-CostTranscriptWalk
        (it exports Get-NormalizedPath used for cwd comparison).
#>

# Silent-skip event types — no warning emitted
$script:CostWalkerSilentTypes = [System.Collections.Generic.HashSet[string]]@(
    'user', 'attachment', 'system', 'last-prompt',
    'queue-operation', 'pr-link', 'command_permissions', 'auto_mode',
    'tool_use', 'tool_result'
)
$script:CostWalkerCopilotOtelCwdPrefix = 'copilot-otel://'

function script:Get-CostWalkerPhaseMarker {
    param(
        [AllowNull()][object]$TranscriptEvent
    )

    if ($null -eq $TranscriptEvent -or $TranscriptEvent['type'] -ne 'user') { return $null }

    $content = $TranscriptEvent['message']?['content']
    if ($content -isnot [string]) { return $null }

    $markerPattern = '\A\s*<command-name>/(?<command>(?:agent-orchestra:)?(?:experience|design|plan|orchestrate|code-conductor))</command-name>\s*<command-args>(?<args>[^<]*)</command-args>\s*\z'
    $markerMatch = [regex]::Match($content, $markerPattern, [System.Text.RegularExpressions.RegexOptions]::Singleline)
    if (-not $markerMatch.Success) { return $null }

    $portHint = $markerMatch.Groups['command'].Value
    if ($portHint.StartsWith('agent-orchestra:', [System.StringComparison]::Ordinal)) {
        $portHint = $portHint.Substring('agent-orchestra:'.Length)
    }

    $argumentText = $markerMatch.Groups['args'].Value.Trim()
    $issueText = $null

    if ([regex]::IsMatch($argumentText, '^\d+$')) {
        $issueText = $argumentText
    }
    else {
        $hashMatch = [regex]::Match($argumentText, '^#(?<issue>\d+)$')
        if ($hashMatch.Success) {
            $issueText = $hashMatch.Groups['issue'].Value
        }
        else {
            $issueMatch = [regex]::Match($argumentText, '^issue\s+(?<issue>\d+)$')
            if ($issueMatch.Success) {
                $issueText = $issueMatch.Groups['issue'].Value
            }
        }
    }

    if ([string]::IsNullOrWhiteSpace($issueText)) { return $null }

    $issueNumber = 0
    if ([int]::TryParse($issueText, [ref]$issueNumber)) {
        return @{
            IssueId  = $issueNumber
            PortHint = $portHint
        }
    }

    return $null
}

function script:Test-CostWalkerEventCwdMatchesParent {
    param(
        [Parameter(Mandatory)]$TranscriptEvent,
        [Parameter(Mandatory)][string]$NormalizedParentCwd
    )

    $eventCwd = $TranscriptEvent['cwd']
    if ($null -eq $eventCwd) { return $false }

    # C3 (issue #825 post-review fix): guard against an unmarshaled (null-coerced-to-'')
    # $script:CostWalkerCopilotOtelCwdPrefix — ''.StartsWith(anything) is $true in .NET,
    # so an unguarded call here would misclassify every real cwd as the sentinel. A
    # null/empty prefix must mean "no sentinel matches", not "everything matches".
    if (-not [string]::IsNullOrEmpty($script:CostWalkerCopilotOtelCwdPrefix) -and
        ([string]$eventCwd).StartsWith($script:CostWalkerCopilotOtelCwdPrefix, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }

    $normalizedEventCwd = Get-NormalizedPath -Path ([string]$eventCwd)
    return $normalizedEventCwd -eq $NormalizedParentCwd
}

function script:Test-CostWalkerPhaseMarkerBranchAllowed {
    param(
        [AllowNull()][object]$Branch
    )

    return $null -eq $Branch -or [string]::IsNullOrEmpty([string]$Branch) -or [string]$Branch -eq 'main'
}

function script:Test-CostWalkerAssistantMatchesStrictFilter {
    param(
        [Parameter(Mandatory)]$TranscriptEvent,
        [Parameter(Mandatory)][string]$NormalizedParentCwd,  # keep param for signature compat
        [Parameter(Mandatory)][string]$Branch
    )

    $eventBranch = $TranscriptEvent['gitBranch']
    if ($null -eq $eventBranch) { return $false }
    # D2: identity check is done at slug-dir level; per-event filter uses branch only.
    return [string]$eventBranch -eq $Branch
}

function script:Add-CostWalkerAssistantEventAndSubagents {
    <#
    .SYNOPSIS
        Adds an admitted assistant event (and its subagent transcript events) to
        the walk's result list, applying the composite dedup key.
    .DESCRIPTION
        M7 (issue #825 s1): events are attributed once across ALL admitted slug
        dirs using a composite `session_id` + event `uuid` key (never `session_id`
        alone, which would under-count a legitimately split spanning session that
        reuses the same file BaseName but has distinct event uuids). SessionId is
        the originating JSONL file's own BaseName (the session id convention
        documented on Get-CostWalkerCurrentSessionId). An event with no uuid is
        never deduped (always added) — this preserves pre-#825 behavior for
        synthetic/test events that omit it.

        L12 (issue #825 post-review fix): a duplicate PARENT event only skips its
        own insertion into $Included — the subagent traversal below always runs,
        even for a dedup no-op parent. A duplicate copy of the same session
        directory can hold a `subagents/` file the first-processed copy's
        directory lacks (or vice versa); returning early on the parent dedup hit
        used to skip that copy's entire subagent traversal, silently losing those
        subagent cost events.
    #>
    param(
        [Parameter(Mandatory)]$Included,
        [Parameter(Mandatory)]$TranscriptEvent,
        [Parameter(Mandatory)][string]$SlugDir,
        [Parameter(Mandatory)][string]$SessionId,
        [Parameter(Mandatory)]$SeenKeys
    )

    $eventUuid = [string]$TranscriptEvent['uuid']
    # An event with no uuid is never deduped — always treated as a fresh parent.
    $addParent = $true
    if (-not [string]::IsNullOrEmpty($eventUuid)) {
        $dedupKey = "$SessionId|$eventUuid"
        # HashSet.Add() returns $false when the key was already present, $true when
        # newly added — a single atomic membership-test-and-insert, replacing the
        # prior Contains()-then-separate-Add() pair whose early `return` on a
        # duplicate skipped the subagent traversal below along with the parent.
        $addParent = $SeenKeys.Add($dedupKey)
    }

    if ($addParent) {
        $Included.Add($TranscriptEvent)
    }

    # Traverse subagent transcripts for included Agent tool_use dispatches — runs
    # unconditionally so a duplicate parent's own subagent directory is still
    # walked (see L12 note above).
    $messageContent = $TranscriptEvent['message']?['content']
    if ($null -eq $messageContent) { return }

    foreach ($contentItem in $messageContent) {
        if ($null -eq $contentItem) { continue }
        $itemType = $contentItem['type']
        $itemName = $contentItem['name']
        if ($itemType -eq 'tool_use' -and $itemName -eq 'Agent') {
            $toolUseId = $contentItem['id']
            if ($null -ne $toolUseId) {
                $subagPath = Join-Path $SlugDir 'subagents' "agent-$toolUseId.jsonl"
                if (Test-Path -LiteralPath $subagPath) {
                    $subLines = @(Get-Content -LiteralPath $subagPath -Encoding utf8 -ErrorAction SilentlyContinue)
                    foreach ($subLine in $subLines) {
                        $subTrimmed = $subLine.Trim()
                        if ([string]::IsNullOrEmpty($subTrimmed)) { continue }
                        try {
                            $subagEvent = $subTrimmed | ConvertFrom-Json -AsHashtable -ErrorAction Stop
                            $subUuid = [string]$subagEvent['uuid']
                            if (-not [string]::IsNullOrEmpty($subUuid)) {
                                $subKey = "$SessionId|$subUuid"
                                if ($SeenKeys.Contains($subKey)) { continue }
                                [void]$SeenKeys.Add($subKey)
                            }
                            $Included.Add($subagEvent)
                        }
                        catch {
                            $subagPathForMsg = $subagPath
                            Write-Warning "cost-walker: failed to parse subagent JSON line in ${subagPathForMsg}: $_"
                        }
                    }
                }
                # Absent subagent transcript is silently tolerated.
            }
        }
    }
}

function script:Get-CostWalkerSlugHashSuffix {
    <#
    .SYNOPSIS
        Reproduces Claude Code's disambiguating hash suffix for over-long slugs.
    .DESCRIPTION
        Vendor rule (issue #908 evidence pass), expressed in its original form:
            hash(s):  t = 0; for each char c: t = (t << 5) - t + c.charCodeAt() | 0
            suffix:   Math.abs(hash(s)).toString(36)
        That is the classic 31-multiplier string hash, wrapped to a signed 32-bit
        integer after every character, rendered in lowercase base-36.

        `(t << 5) - t` is exactly `t * 31` modulo 2^32, so wrapping once per
        character after `t * 31 + c` reproduces the vendor's shift-then-subtract
        order without needing to model the intermediate shift.
    .OUTPUTS
        [string] lowercase base-36 magnitude, '0' when the hash is zero.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Value
    )

    $hash = 0L
    foreach ($ch in $Value.ToCharArray()) {
        $hash = ($hash * 31L + [long][int]$ch) -band 0xFFFFFFFFL
        if ($hash -ge 2147483648L) { $hash -= 4294967296L }
    }

    # JavaScript numbers are doubles, so Math.abs(-2^31) is 2^31 rather than an
    # overflow. Widen to [long] before taking the magnitude -- [Math]::Abs on
    # [int]::MinValue throws in .NET.
    $magnitude = [Math]::Abs($hash)
    if ($magnitude -eq 0L) {
        return '0'
    }

    $digits = '0123456789abcdefghijklmnopqrstuvwxyz'
    $encoded = [System.Text.StringBuilder]::new()
    while ($magnitude -gt 0L) {
        $remainder = $magnitude % 36L
        [void]$encoded.Insert(0, $digits[[int]$remainder])
        $magnitude = [long](($magnitude - $remainder) / 36L)
    }

    return $encoded.ToString()
}

function Get-CostTranscriptSlug {
    <#
    .SYNOPSIS
        Derives the Claude Code projects-directory slug from a CWD path string.
    .DESCRIPTION
        Mirrors Claude Code's own slug builder, which is the sole authority for
        these directory names. Issue #908 replaced the segment-join approximation
        introduced by issue #467 D1 after an evidence pass over the real
        ~/.claude/projects/* names; the vendor rule is a single character-class
        substitution over the whole path, not a per-segment join:

            slug = cwd.replace(/[^a-zA-Z0-9]/g, '-')
            if (slug.length > 200) {
                slug = slug.slice(0, 200) + '-' + base36(abs(hash(cwd)))
            }

        Provenance: extracted from the installed Claude Code CLI binary and
        confirmed independently against versions 2.1.216 and 2.1.219 (issue #908,
        cross-checked in issue #932). The binary carries a second, similarly
        shaped builder that DOES lowercase -- it resolves *team* directories, not
        projects, so anyone re-deriving this rule by grepping for the regex alone
        must confirm they matched the projects-dir resolver. This is a
        reverse-engineered vendor rule with no version guard: if derived slugs
        stop matching real directories after a CLI upgrade, re-extract before
        assuming a defect here.

        Three consequences the segment-join rule got wrong:
          * EVERY non-alphanumeric character maps to '-' -- dots, underscores and
            the drive colon included, not just spaces and separators.
          * Runs are NOT collapsed. A dotted segment contributes its own leading
            '-' on top of the separator's, which is exactly what produces the
            '--claude-worktrees-' form Claude Code writes for '.claude/worktrees'.
            The old rule emitted '-.claude-worktrees-', which matched nothing and
            left the primary-slug lookup permanently dead for worktree checkouts.
          * Case is preserved everywhere, drive letter included: 'C:\...' derives
            'C--...', not 'c--...'.

        Examples:
          C:\Users\Micah\Code 2\copilot-orchestra
            -> C--Users-Micah-Code-2-copilot-orchestra
          C:\Users\Micah\Code\Copilot-Orchestra\.claude\worktrees\issue-908-99513b
            -> C--Users-Micah-Code-Copilot-Orchestra--claude-worktrees-issue-908-99513b
          C:\repo\src\my.app_v2
            -> C--repo-src-my-app-v2
          /c/Users/Micah/Code 2/copilot-orchestra   (on Windows)
            -> c--Users-Micah-Code-2-copilot-orchestra
          /home/runner/work/repo                    (on Linux)
            -> -home-runner-work-repo

        Three pre-normalizations run before the vendor rule, because callers can
        hold a path in a shape Claude Code itself never sees. All three exist to
        reconstruct the exact string the vendor's own process.cwd() reported --
        which matters twice over, because above the 200-char cap that string is
        also the hash preimage, and a preimage difference is unrecoverable by any
        case-insensitive lookup (issue #932, M1/M3):
          1. Windows only: a git-bash MSYS drive path ('/c/repo') is rewritten to
             its Windows form ('c:/repo'). Feeding the raw MSYS form to the vendor
             rule would yield a leading '-' and a single-dash drive ('-c-repo'),
             matching nothing. Gated on $IsWindows because on a POSIX host
             '/c/repo' is a genuine directory whose vendor slug IS '-c-repo';
             rewriting it there would corrupt a correct derivation.
          2. Separators are canonicalized to backslash whenever a drive letter is
             present, because that is the shape process.cwd() reports on Windows.
             Without this, the same physical path spelled 'C:/...' (as
             `git rev-parse --show-toplevel` emits) derives a different over-cap
             hash suffix than 'C:\...'.
          3. Trailing separators are dropped, since process.cwd() never reports
             one and 'C:\repo\' must not derive a trailing '-'. A bare drive root
             ('C:\') is left alone -- there the separator is part of the path.
             Trailing WHITESPACE is deliberately not stripped: it is not a
             separator, no real cwd carries one, and silently trimming it would
             hide a malformed caller argument rather than surface it. Which
             characters count as separators depends on the path's own shape,
             not the host OS: a drive-letter path (already canonicalized to
             backslash by normalization 2) treats both '\' and '/' as
             separators; a path with no drive letter is POSIX-shaped and only
             '/' is a separator there -- '\' is an ordinary filename
             character, and trimming it would corrupt a real trailing-backslash
             directory name (PR #937 review). Gating this on $IsWindows rather
             than on drive-letter shape would have regressed the drive-letter
             case whenever the function runs on a POSIX host, which is exactly
             what the test suite's existing pins exercise on Linux CI.

        Residual known gap, deliberately not guessed at: an MSYS-form path
        longer than the cap derives its suffix from a lowercase drive
        ('c:\...'). Node preserves whatever drive case it is handed -- measured,
        process.chdir('c:\') leaves process.cwd() reporting 'c:\' -- so drive
        case is genuinely derivable from any path that carries one, which is why
        this function preserves it rather than folding it. An MSYS path is the
        one input shape that carries none: '/c/...' spells the drive lowercase
        by convention whatever Windows reported. Below the cap the
        case-insensitive lookup absorbs the difference; above it the drive
        character is part of the hash preimage and the suffix diverges. No live
        caller supplies an MSYS path -- every one passes a repo root from git
        plus Resolve-Path -- so the gap is pinned by test rather than papered
        over with an unevidenced uppercase guess.

        (This is the narrow residue of plan amendment A1, which claimed drive
        case is not derivable at all. Measured against the vendor, that is false
        in general and true only for MSYS input.)
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$CwdPath
    )

    $p = $CwdPath

    # Input guard (not part of the vendor rule, and a deliberate departure from
    # it): a path with no ASCII alphanumeric character returns empty here even
    # though the vendor rule would derive a non-empty all-dash slug for it (a
    # Unicode-only POSIX path such as '/日本' is a valid, real cwd -- PR #937
    # review). The real cost of that departure is NOT "narrower discovery" --
    # measured across the actual call sites, it is call-site-dependent and
    # sometimes total: the dominant path (frame-credit-ledger.ps1 ->
    # cost-session-render.ps1) gates the ENTIRE walk, identity matching
    # included, on a non-empty slug, so a Unicode-only cwd captures zero cost
    # events and, on an orchestrated PR, a false "no-transcript-found"
    # degraded comment gets posted for a walk that never ran -- the same
    # misleading-diagnostic failure class issue #908 itself exists to close.
    # Only one call site (Test-CostWalkerSessionTranscriptExists) actually
    # falls back to identity matching the way an earlier revision of this
    # comment claimed all of them do. Tracked as issue #938 rather than fixed
    # here: the guard is not the only option between "ASCII-only" and "match
    # the vendor rule exactly" (a Unicode-letter-aware guard would admit the
    # broken class while still rejecting every separator-only input this
    # guard was added to reject), and #938's first step is measuring whether
    # a Unicode-only repo-root cwd is reachable in practice at all before
    # choosing a shape -- the same evidence-first discipline this file's own
    # derivation rule was built on.
    if ($p -notmatch '[a-zA-Z0-9]') {
        return ''
    }

    # Pre-normalization 1: git-bash MSYS drive form -> Windows drive form.
    # Windows only -- on POSIX, '/c/repo' is a real directory, not a drive.
    if ($IsWindows -and $p -match '^/([A-Za-z])/(.*)$') {
        $p = "$($Matches[1]):/$($Matches[2])"
    }

    # Pre-normalization 2: canonicalize separators to the shape process.cwd()
    # reports for a drive-letter path, so the over-cap hash preimage matches.
    #
    # $isDriveLetterPath is computed once, here, and reused by normalization 3
    # below (PR #937 post-fix review, M7): the two conditions used to be two
    # separately-written copies of the same regex, and nothing enforced that
    # they stayed in sync -- a mutation test proved a change to only the
    # second copy produced zero test failures despite changing real behavior.
    # Computed after normalization 1 (which can CREATE a drive letter from an
    # MSYS path on Windows) and before the Replace call, so it reflects the
    # path's drive-letter shape at the point normalization 2 acts on it, and
    # stays valid afterward because Replace('/', '\') cannot alter the first
    # two characters a drive-letter path is detected from.
    $isDriveLetterPath = $p -match '^[A-Za-z]:'
    if ($isDriveLetterPath) {
        $p = $p.Replace('/', '\')
    }

    # Pre-normalization 3: drop trailing separators, except on a bare drive
    # root. Which characters count as a separator is decided by path SHAPE
    # (drive-letter-absolute, or Windows-rooted with no drive letter), not by
    # $IsWindows and not by "absence of a drive letter" alone (PR #937 review,
    # M2/M7):
    #   - A drive-letter path was already canonicalized to backslash above, so
    #     both '\' and '/' are separators for it, regardless of host OS --
    #     gating this on $IsWindows instead would silently stop trimming a
    #     drive-letter path's trailing backslash whenever this runs on a
    #     POSIX host, which is exactly the input shape the suite pins on the
    #     Linux CI runner.
    #   - A path rooted at a bare '\' (UNC '\\server\share\...', long-UNC
    #     '\\?\C:\...', or drive-relative '\dir\...') is unambiguously
    #     Windows-shaped even without a drive letter, and '\' is a separator
    #     for it too -- an earlier revision of this fix treated "no drive
    #     letter" as sufficient evidence of "POSIX-shaped" and stripped a
    #     legitimate trailing backslash from every one of these forms.
    #   - Anything else -- a genuine POSIX absolute path, or a bare relative
    #     path with no leading separator at all -- has only '/' as a
    #     separator; '\' is an ordinary filename character there. A bare
    #     relative path carrying a literal trailing backslash (e.g.
    #     'dir\sub\') is a deliberate, documented residual: its platform is
    #     not determinable from the string alone, and no live caller supplies
    #     a relative cwd, so this function treats it as POSIX-shaped rather
    #     than guessing Windows -- narrower than HEAD's accidental trim of
    #     this class, but the alternative (an unevidenced third disjunct
    #     covering bare-relative-with-backslash) was measured to restore that
    #     one unreachable class only by misclassifying a different reachable
    #     one (a POSIX relative name containing a backslash and no slash).
    if ($isDriveLetterPath -or $p.StartsWith('\')) {
        if ($p -match '^(.*[^\\/])[\\/]+$' -and $Matches[1] -notmatch '^[A-Za-z]:$') {
            $p = $Matches[1]
        }
    }
    elseif ($p -match '^(.*[^/])/+$') {
        $p = $Matches[1]
    }

    # Vendor rule: every non-alphanumeric character becomes '-'; nothing is
    # collapsed, trimmed, or case-folded.
    $slug = [regex]::Replace($p, '[^a-zA-Z0-9]', '-')

    # Vendor overflow rule. $maxSlugLength is a single-use function-local by
    # design: promoting it to a $script: constant would enlist it in the
    # worker-runspace marshal registry (Get-FCLCostScriptState in
    # cost-fcl-helpers.ps1, which already carries this file's two genuine
    # $script: constants) for no benefit, and that registry is the contract a
    # future maintainer should extend -- not route around.
    $maxSlugLength = 200
    if ($slug.Length -le $maxSlugLength) {
        return $slug
    }

    return $slug.Substring(0, $maxSlugLength) + '-' + (script:Get-CostWalkerSlugHashSuffix -Value $p)
}

function script:Resolve-CostWalkerPrimarySlugDir {
    param(
        [Parameter(Mandatory)][string]$ProjectsRoot,
        [Parameter(Mandatory)][string]$Slug
    )

    $primaryDir = Join-Path $ProjectsRoot $Slug
    if (Test-Path -LiteralPath $primaryDir) {
        return $primaryDir
    }

    $matchingDir = Get-ChildItem -Path $ProjectsRoot -Directory -ErrorAction SilentlyContinue |
        Where-Object { [string]::Equals($_.Name, $Slug, [System.StringComparison]::OrdinalIgnoreCase) } |
        Select-Object -First 1

    if ($null -ne $matchingDir) {
        return $matchingDir.FullName
    }

    Write-Warning "cost-walker: slug directory not found: $primaryDir"
    return $null
}

function script:Resolve-CostWalkerRepoIdentity {
    <#
    .SYNOPSIS
        Normalize a git remote URL to a transport-agnostic host/path identity.
    .DESCRIPTION
        Fix #760-E1: collapse SSH, HTTPS, and credential-embedded URL forms to a
        single comparable 'host/path' string so a session cloned over SSH matches
        a ledger repo root configured over HTTPS (and vice versa).  Without this,
        the same repo reached via different transports produces different raw URLs
        and a session is silently excluded from attribution.

        Handles:
          - scp-like SSH:        git@github.com:owner/repo(.git)
          - ssh:// scheme:       ssh://git@github.com/owner/repo(.git)
          - credentialed HTTPS:  https://x-access-token:TOKEN@github.com/owner/repo
          - plain HTTPS:         https://github.com/owner/repo(.git)
        Returns $null for empty/whitespace input.
    .OUTPUTS
        [string] normalized 'host/path', or $null.
    #>
    param([string]$RawUrl)

    if ([string]::IsNullOrWhiteSpace($RawUrl)) { return $null }

    $u = $RawUrl.Trim()

    # scp-like SSH form (no scheme, ':' separates host and path): git@host:owner/repo
    if ($u -match '^[^/@]+@([^:/]+):(.+)$') {
        $u = "$($Matches[1])/$($Matches[2])"
    }
    else {
        # Strip URL scheme (https://, ssh://, git://, http://, ...)
        $u = $u -replace '^[a-zA-Z][a-zA-Z0-9+.\-]*://', ''
        # Strip userinfo (user@ or user:password@ / x-access-token:TOKEN@) before the host
        $u = $u -replace '^[^/@]+@', ''
    }

    $u = $u.ToLowerInvariant().TrimEnd('/')
    if ($u.EndsWith('.git')) { $u = $u.Substring(0, $u.Length - 4) }

    if ([string]::IsNullOrWhiteSpace($u)) { return $null }
    return $u
}

function script:Get-CostWalkerTargetIdentity {
    <#
    .SYNOPSIS
        Resolves the target (ledger) repo's identity from its git remote (issue #825
        s1 extraction — shared by Get-IdentityMatchedSlugDirs and the Tier-2
        corroborated-fallback resolver so both agree on what "matches" means).
    .OUTPUTS
        [string] normalized 'host/path' identity, or $null when unresolvable.
    #>
    param([Parameter(Mandatory)][string]$RepoRoot)

    try {
        $rawUrl = @(& git -C $RepoRoot remote get-url origin 2>$null) | Select-Object -First 1
        if ($global:LASTEXITCODE -eq 0) {
            return script:Resolve-CostWalkerRepoIdentity -RawUrl ([string]$rawUrl)
        }
    } catch { }
    return $null
}

function script:ConvertFrom-CostWalkerJsonLine {
    <#
    .SYNOPSIS
        Trims a raw JSONL line and parses it to a hashtable, or returns $null for
        a blank line or a parse failure (issue #825 s1 extraction — shared by the
        three Tier-2 corroborated-fallback probe helpers below, which previously
        each duplicated this same trim/skip-blank/parse-or-skip shape inline).
    .DESCRIPTION
        Deliberately silent on parse failure (no Write-Warning) — these probe
        helpers scan candidate transcripts speculatively and a malformed line is
        just not-a-match, unlike Invoke-CostTranscriptWalk's own main walk loop
        (and its Tier-2 file walk), which warns because it is the authoritative
        pass over admitted events.
    .OUTPUTS
        [hashtable] the parsed event, or $null.
    #>
    param([AllowNull()][string]$Line)

    if ([string]::IsNullOrEmpty($Line)) { return $null }
    $trimmed = $Line.Trim()
    if ([string]::IsNullOrEmpty($trimmed)) { return $null }

    try { return $trimmed | ConvertFrom-Json -AsHashtable -ErrorAction Stop }
    catch { return $null }
}

function script:Get-CostWalkerFirstEventCwd {
    <#
    .SYNOPSIS
        Finds the first non-empty, non-sentinel cwd recorded by any event in a slug
        directory's JSONL files (issue #825 s1 extraction — shared by
        Get-IdentityMatchedSlugDirs and the Tier-2 corroborated-fallback resolver).
    .OUTPUTS
        [string] the first usable cwd, or $null when no JSONL file in the directory
        records one.
    #>
    param([Parameter(Mandatory)][string]$SlugDirPath)

    $firstCwd = $null
    $jsonls = @(Get-ChildItem -LiteralPath $SlugDirPath -Filter '*.jsonl' -File -ErrorAction SilentlyContinue | Select-Object -First 5)
    foreach ($jf in $jsonls) {
        if ($null -ne $firstCwd) { break }
        $lines = @(Get-Content -LiteralPath $jf.FullName -Encoding utf8 -ErrorAction SilentlyContinue | Select-Object -First 20)
        foreach ($ln in $lines) {
            $ev = script:ConvertFrom-CostWalkerJsonLine -Line $ln
            if ($null -eq $ev) { continue }
            if (-not [string]::IsNullOrEmpty([string]$ev['cwd'])) {
                $cwd = [string]$ev['cwd']
                # C3 (issue #825 post-review fix): same null/empty-prefix guard as
                # Test-CostWalkerEventCwdMatchesParent above — an unguarded StartsWith('')
                # would misclassify every real cwd as the sentinel and this function would
                # return $null for every candidate.
                $isSentinelCwd = -not [string]::IsNullOrEmpty($script:CostWalkerCopilotOtelCwdPrefix) -and
                    $cwd.StartsWith($script:CostWalkerCopilotOtelCwdPrefix, [System.StringComparison]::OrdinalIgnoreCase)
                if (-not $isSentinelCwd) {
                    $firstCwd = $cwd
                    break
                }
            }
        }
    }
    return $firstCwd
}

function script:Get-IdentityMatchedSlugDirs {
    param(
        [Parameter(Mandatory)][string]$ProjectsRoot,
        [Parameter(Mandatory)][string]$RepoRoot
    )

    # Resolve target repo identity once from the ledger's repo root.
    $targetIdentity = script:Get-CostWalkerTargetIdentity -RepoRoot $RepoRoot

    if ($null -eq $targetIdentity) {
        # Can't resolve target identity — fail-closed: return empty list, no slug dirs admitted.
        return [System.Collections.Generic.List[string]]::new()
    }

    $matched = [System.Collections.Generic.List[string]]::new()

    $allDirs = @(Get-ChildItem -Path $ProjectsRoot -Directory -ErrorAction SilentlyContinue)
    foreach ($dir in $allDirs) {
        # Find the first event with a cwd field in any JSONL file in this slug dir.
        $firstCwd = script:Get-CostWalkerFirstEventCwd -SlugDirPath $dir.FullName

        if ($null -eq $firstCwd) { continue }  # fail-closed: no usable cwd found

        # Resolve this slug dir's identity from the first-event cwd.
        $candidateIdentity = $null
        try {
            $rawUrl = @(& git -C $firstCwd remote get-url origin 2>$null) | Select-Object -First 1
            if ($global:LASTEXITCODE -eq 0) {
                $candidateIdentity = script:Resolve-CostWalkerRepoIdentity -RawUrl ([string]$rawUrl)
            }
        } catch { }

        if ($null -eq $candidateIdentity) { continue }  # fail-closed: can't verify identity

        if ($candidateIdentity -eq $targetIdentity) {
            $matched.Add($dir.FullName)
        }
        # else: same-leaf different-repo → rejected (identity mismatch)
    }

    return $matched
}

function script:Test-CostWalkerDirHasBranchMatchFile {
    <#
    .SYNOPSIS
        Lists JSONL files within a slug directory that contain at least one
        'assistant' event whose gitBranch equals the target branch (issue #825 s1,
        Tier-2 corroborated-fallback trust ladder — signal (i)).
    .OUTPUTS
        [System.Collections.Generic.List[string]] full paths of matching files.
    #>
    param(
        [Parameter(Mandatory)][string]$SlugDirPath,
        [Parameter(Mandatory)][string]$Branch
    )

    $matchedFiles = [System.Collections.Generic.List[string]]::new()
    $jsonlFiles = @(Get-ChildItem -LiteralPath $SlugDirPath -Filter '*.jsonl' -File -ErrorAction SilentlyContinue)
    foreach ($file in $jsonlFiles) {
        $lines = @(Get-Content -LiteralPath $file.FullName -Encoding utf8 -ErrorAction SilentlyContinue)
        foreach ($line in $lines) {
            $ev = script:ConvertFrom-CostWalkerJsonLine -Line $line
            if ($null -eq $ev) { continue }
            if ($ev['type'] -eq 'assistant' -and $null -ne $ev['gitBranch'] -and [string]$ev['gitBranch'] -eq $Branch) {
                $matchedFiles.Add($file.FullName)
                break
            }
        }
    }
    return $matchedFiles
}

function script:Test-CostWalkerFileHasIssueMarker {
    <#
    .SYNOPSIS
        Reports whether a JSONL file contains a phase marker (<command-args>) naming
        the given issue number (issue #825 s1, Tier-2 corroborated-fallback trust
        ladder — signal (ii)).
    #>
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][int]$IssueNumber
    )

    $lines = @(Get-Content -LiteralPath $FilePath -Encoding utf8 -ErrorAction SilentlyContinue)
    foreach ($line in $lines) {
        $ev = script:ConvertFrom-CostWalkerJsonLine -Line $line
        if ($null -eq $ev -or $ev['type'] -ne 'user') { continue }
        $marker = script:Get-CostWalkerPhaseMarker -TranscriptEvent $ev
        if ($null -ne $marker -and $marker.IssueId -eq $IssueNumber) { return $true }
    }
    return $false
}

function script:Test-CostWalkerFileEvidenceIdentityMismatch {
    <#
    .SYNOPSIS
        Scans a Tier-2 candidate file's own recorded event cwd values for a
        positive, verifiable repo-identity mismatch against $TargetIdentity
        (issue #825 post-review fix, L14).
    .DESCRIPTION
        The Tier-2 M9 trigger only requires the directory's FIRST recorded cwd
        to be absent from disk — it says nothing about every OTHER event in the
        same file. This scans every distinct, non-sentinel cwd recorded in the
        file and, for any that still exists on disk, resolves its git remote
        identity. If any resolves and differs from $TargetIdentity, the file's
        own evidence proves it does not belong to the target repository, and the
        primary (own-marker) corroboration path must not admit it on that
        evidence alone — closing the gap where a deleted-cwd candidate sharing
        the same branch name and issue-marker number, but originating from a
        DIFFERENT repository, could otherwise be admitted and cross-attributed.

        "Where determinable" (the finding's framing): most Tier-2 candidates
        have no OTHER existing cwd anywhere in the file (the typical case — the
        whole worktree/session was deleted), so this returns $false (no proven
        mismatch, not "no evidence of a match") and the existing own-marker
        corroboration path is unaffected. This is intentionally NOT a
        directory-name/slug check — Tier-2 admits arbitrarily-named directories
        by design (ladder case 6); this only fires on a POSITIVE, git-resolved
        contradiction.
    .OUTPUTS
        [bool] $true only when at least one recorded cwd in the file exists on
        disk AND resolves to a git identity different from $TargetIdentity.
    #>
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string]$TargetIdentity
    )

    $lines = @(Get-Content -LiteralPath $FilePath -Encoding utf8 -ErrorAction SilentlyContinue)
    $checkedCwds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($line in $lines) {
        $ev = script:ConvertFrom-CostWalkerJsonLine -Line $line
        if ($null -eq $ev) { continue }

        $cwd = [string]$ev['cwd']
        if ([string]::IsNullOrEmpty($cwd) -or -not $checkedCwds.Add($cwd)) { continue }

        if (-not [string]::IsNullOrEmpty($script:CostWalkerCopilotOtelCwdPrefix) -and
            $cwd.StartsWith($script:CostWalkerCopilotOtelCwdPrefix, [System.StringComparison]::OrdinalIgnoreCase)) { continue }

        if (-not (Test-Path -LiteralPath $cwd -ErrorAction SilentlyContinue)) { continue }

        $candidateIdentity = $null
        try {
            $rawUrl = @(& git -C $cwd remote get-url origin 2>$null) | Select-Object -First 1
            if ($global:LASTEXITCODE -eq 0) {
                $candidateIdentity = script:Resolve-CostWalkerRepoIdentity -RawUrl ([string]$rawUrl)
            }
        } catch { }

        if ($null -ne $candidateIdentity -and $candidateIdentity -ne $TargetIdentity) {
            return $true
        }
    }

    return $false
}

function script:Get-CostWalkerCorroboratedFallbackAdmission {
    <#
    .SYNOPSIS
        Resolves the Tier-2 corroborated-fallback admission set (issue #825 s1,
        plan-issue-825 Step 1). Opt-in behind -AdmitCorroboratedFallback on
        Invoke-CostTranscriptWalk; Tier 1 (script:Get-IdentityMatchedSlugDirs) is
        never touched or reconsidered by this function.
    .DESCRIPTION
        Strict cwd-absent trigger (M9): a candidate slug directory is only eligible
        for Tier-2 admission when its recorded first-event cwd does NOT exist on
        disk. A directory whose cwd exists but resolves to a mismatched or
        unresolvable identity was already excluded (terminally, or fail-closed) by
        Tier 1 and is never reconsidered here — that is the "positively-mismatched
        identity -> terminal reject, probe-miss -> fail-closed" split from the plan.

        For each cwd-absent candidate directory, files with at least one
        branch-matched assistant event (signal (i)) are corroboration candidates. A
        candidate file is admitted only when it also satisfies signal (ii): its own
        phase markers name the target issue, OR (M14 cross-file corroboration) a
        sibling file with the SAME BaseName (the same session id) inside an
        already-admitted Tier-1 directory names the target issue. Same-file/
        same-session scoping (M11) means an unrelated co-located session's phase
        marker in the same directory never corroborates a different session's
        branch-matched file.

        A directory contributes to the returned rejected-dir count (M6) only when
        it had at least one branch-matched file and NONE of those files achieved
        corroboration — a directory that admits at least one file is not counted as
        rejected even if it also has non-corroborated siblings.

        L14 (issue #825 post-review fix): the primary (own-marker) signal above has
        no repo-identity tie by itself — see
        script:Test-CostWalkerFileEvidenceIdentityMismatch, consulted before trusting
        own-marker corroboration, for the guard that rejects a file whose own
        evidence positively proves a different repository identity.
    .OUTPUTS
        [hashtable] @{ AdmittedFiles = [List[string]]; RejectedDirCount = [int] }
    #>
    param(
        [Parameter(Mandatory)][string]$ProjectsRoot,
        [AllowNull()][string]$TargetIdentity,
        [Parameter(Mandatory)]$Tier1AdmittedDirs,
        [Parameter(Mandatory)][string]$Branch,
        [Nullable[int]]$IssueNumber
    )

    $admittedFiles = [System.Collections.Generic.List[string]]::new()
    $rejectedDirCount = 0

    if ([string]::IsNullOrEmpty($TargetIdentity) -or $null -eq $IssueNumber -or [int]$IssueNumber -le 0) {
        # No resolvable target identity or no issue to corroborate against: Tier 2 admits
        # nothing (fail-closed) rather than guessing.
        return @{ AdmittedFiles = $admittedFiles; RejectedDirCount = $rejectedDirCount }
    }

    $resolvedIssueNumber = [int]$IssueNumber
    $allDirs = @(Get-ChildItem -Path $ProjectsRoot -Directory -ErrorAction SilentlyContinue)

    foreach ($dir in $allDirs) {
        if ($Tier1AdmittedDirs.Contains($dir.FullName)) { continue }

        $firstCwd = script:Get-CostWalkerFirstEventCwd -SlugDirPath $dir.FullName
        if ($null -eq $firstCwd) { continue }  # no usable cwd recorded at all; skip silently

        if (Test-Path -LiteralPath $firstCwd -ErrorAction SilentlyContinue) {
            # M9: cwd present — not the strict Tier-2 trigger. Tier 1 already made the
            # terminal (mismatched identity) or fail-closed (unresolvable identity) call
            # for this directory; Tier 2 never reconsiders it.
            continue
        }

        $branchMatchedFiles = script:Test-CostWalkerDirHasBranchMatchFile -SlugDirPath $dir.FullName -Branch $Branch
        if ($branchMatchedFiles.Count -eq 0) { continue }  # never branch-matched; not a rejection candidate

        $dirAdmittedAny = $false
        foreach ($filePath in $branchMatchedFiles) {
            $sessionId = [System.IO.Path]::GetFileNameWithoutExtension($filePath)

            $corroborated = script:Test-CostWalkerFileHasIssueMarker -FilePath $filePath -IssueNumber $resolvedIssueNumber

            # L14 (issue #825 post-review fix): the primary (own-marker) corroboration
            # signal above has no repo-identity tie of its own — branch name and issue
            # marker are both coincidentally reproducible from a different repository.
            # When this file's OWN evidence (a non-first, still-extant recorded cwd)
            # positively proves a different repo identity, the primary path must not
            # admit on marker-only evidence; fall through to the M14 sibling check below
            # exactly as if the marker had never corroborated at all.
            if ($corroborated -and (script:Test-CostWalkerFileEvidenceIdentityMismatch -FilePath $filePath -TargetIdentity $TargetIdentity)) {
                $corroborated = $false
            }

            if (-not $corroborated) {
                # M14: cross-file corroboration via a sibling identity-matched (Tier-1)
                # transcript of the SAME session (same file BaseName / session id).
                foreach ($tier1Dir in $Tier1AdmittedDirs) {
                    $siblingPath = Join-Path $tier1Dir "$sessionId.jsonl"
                    if ((Test-Path -LiteralPath $siblingPath -PathType Leaf -ErrorAction SilentlyContinue) -and
                        (script:Test-CostWalkerFileHasIssueMarker -FilePath $siblingPath -IssueNumber $resolvedIssueNumber)) {
                        $corroborated = $true
                        break
                    }
                }
            }

            if ($corroborated) {
                $admittedFiles.Add($filePath)
                $dirAdmittedAny = $true
            }
        }

        if (-not $dirAdmittedAny) {
            $rejectedDirCount++
        }
    }

    return @{ AdmittedFiles = $admittedFiles; RejectedDirCount = $rejectedDirCount }
}

function script:Get-CostWalkerCandidateSlugDirs {
    <#
    .SYNOPSIS
        Resolves the candidate slug-directory list shared by Invoke-CostTranscriptWalk
        and Get-CostWalkerCurrentSessionId (issue #824 refactor pass).
    .DESCRIPTION
        Combines D2 identity-matched dirs (script:Get-IdentityMatchedSlugDirs), the
        worktree-slug glob, and the primary-slug backward-compat fallback into one
        list, so the two callers can never independently re-derive (and silently
        diverge on) this resolution.

        RepoRoot falls back to ParentCwd when blank — this preserves
        Get-CostWalkerCurrentSessionId's pre-refactor behavior for callers that omit
        RepoRoot, while letting a caller that HAS a distinct RepoRoot (e.g. a
        worktree checkout) get the same identity resolution
        Invoke-CostTranscriptWalk itself always used.

        M23 (issue #825 s1 plan note): the worktree-slug glob branch below admits a
        directory purely because its NAME matches "$Slug--claude-worktrees-*" — a
        weaker, name-derived gate than the identity check above — and it stays
        as-is because it is backward-compat scaffolding for worktree slugs whose
        first-event cwd may not point at the main repo root; the opt-in Tier-2
        corroborated-fallback ladder (script:Get-CostWalkerCorroboratedFallbackAdmission)
        is the actual hardened path for admitting a slug dir whose identity can no
        longer be verified.
    .OUTPUTS
        [System.Collections.Generic.List[string]]
    #>
    param(
        [Parameter(Mandatory)][string]$ProjectsRoot,
        [AllowEmptyString()][string]$RepoRoot = '',
        [Parameter(Mandatory)][string]$ParentCwd,
        [AllowEmptyString()][string]$Slug = ''
    )

    $resolvedRepoRoot = if (-not [string]::IsNullOrWhiteSpace($RepoRoot)) { $RepoRoot } else { $ParentCwd }

    $slugDirs = [System.Collections.Generic.List[string]]::new()

    # D2: discover all slug dirs in ProjectsRoot that belong to the same git repo (identity match).
    $identityDirs = script:Get-IdentityMatchedSlugDirs -ProjectsRoot $ProjectsRoot -RepoRoot $resolvedRepoRoot
    foreach ($d in $identityDirs) {
        $slugDirs.Add($d)
    }

    if (-not [string]::IsNullOrWhiteSpace($Slug)) {
        # Also include worktree directories for the primary slug (backward compat / graceful
        # fallback for worktree slugs that may not have first-event cwd pointing to the main
        # repo root).
        $worktreeDirs = @(Get-ChildItem -Path $ProjectsRoot -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like "$Slug--claude-worktrees-*" } |
            Where-Object { $slugDirs -notcontains $_.FullName })
        foreach ($wtd in $worktreeDirs) {
            $slugDirs.Add($wtd.FullName)
        }

        # Backward compat: include explicit slug dir when identity resolution is unavailable
        # (e.g., tests without a real git repo). In production, identity matching already
        # finds this dir; dedup guard prevents double-counting.
        $primarySlugDir = script:Resolve-CostWalkerPrimarySlugDir -ProjectsRoot $ProjectsRoot -Slug $Slug
        if ($null -ne $primarySlugDir -and $slugDirs -notcontains $primarySlugDir) {
            $slugDirs.Add($primarySlugDir)
        }
    }

    return $slugDirs
}

function Invoke-CostTranscriptWalk {
    <#
    .SYNOPSIS
        Walks Claude JSONL session transcripts and returns per-event-filtered results.
    .DESCRIPTION
        Discovers *.jsonl files under:
          {ProjectsRoot}/{Slug}/
          {ProjectsRoot}/{Slug}--claude-worktrees-*/
        For each discovered JSONL file, applies a per-event filter:
          Include if: type -eq 'assistant' AND cwd matches ParentCwd AND gitBranch matches Branch
        For each included assistant event that contains a tool_use with name -eq 'Agent',
        loads {sessionDir}/subagents/agent-{toolUseId}.jsonl and includes all its events.
        Returns a List[object] of included event hashtables (cast to array by caller via @(...)).
    .PARAMETER Slug
        Pre-computed slug string for the project directory.
    .PARAMETER Branch
        Git branch name to filter events by.
    .PARAMETER ParentCwd
        Working directory path; normalized before comparison.
    .PARAMETER ProjectsRoot
        Root directory containing project slug directories. Defaults to ~/.claude/projects.
    .PARAMETER IssueNumber
        Optional GitHub issue number. When supplied, enables upstream phase-marker windowing
        and admits only assistant events inside matching issue windows on main/empty branches.
    .PARAMETER AdmitCorroboratedFallback
        Issue #825 s1. Opt-in switch (default off — the live PR-create path keeps its
        pre-#825 fail-closed behavior, M10). When set, enables the Tier-2
        corroborated-fallback trust ladder: a slug dir whose recorded first-event cwd no
        longer exists on disk (e.g. a deleted sibling worktree) is admitted anyway when
        BOTH its gitBranch events match -Branch and its (or a same-session sibling's)
        phase markers name -IssueNumber. See
        script:Get-CostWalkerCorroboratedFallbackAdmission for the full ladder contract.
    .PARAMETER CorroborationWindowStart
    .PARAMETER CorroborationWindowEnd
        Issue #825 s1, M8. Optional bounds on Tier-2-admitted events only (Tier 1 is
        unbounded, unchanged): an admitted Tier-2 event whose timestamp falls outside
        [CorroborationWindowStart, CorroborationWindowEnd] is excluded, defeating
        same-repo reused-branch collisions outside the PR's actual
        first-branch-appearance -> merge lifetime. A $null bound is not enforced.
    .PARAMETER RejectedDirCountVar
        Issue #825 s1, M6. Optional [ref] output — when supplied, its .Value is set to
        the count of Tier-2 branch-matched candidate directories that were rejected for
        failing corroboration. Always 0 when -AdmitCorroboratedFallback is not set. This
        is an additive, backward-compatible extension of the return contract: the
        function's own output stream (the events themselves) is unchanged.
    .PARAMETER Tier2IssueNumber
        Issue #825 post-review fix (C2). Optional override for the issue number fed
        specifically into the Tier-2 corroboration gate
        (script:Get-CostWalkerCorroboratedFallbackAdmission), kept independent from
        -IssueNumber's phase-marker windowing use. -IssueNumber is resolved with a
        PR-body fallback upstream (author-controllable free text), which is acceptable
        for windowing but must never drive the trust-ladder's corroboration signal.
        When omitted, falls back to -IssueNumber (preserves pre-fix behavior for callers
        that do not supply this).
    #>
    [CmdletBinding()]
    param(
        [AllowEmptyString()][string]$Slug = '',
        [Parameter(Mandatory)][string]$Branch,
        [Parameter(Mandatory)][string]$ParentCwd,
        [string]$ProjectsRoot = '',
        [Nullable[int]]$IssueNumber = $null,
        [string]$RepoRoot = '',
        [switch]$AdmitCorroboratedFallback,
        [Nullable[datetime]]$CorroborationWindowStart = $null,
        [Nullable[datetime]]$CorroborationWindowEnd = $null,
        [ref]$RejectedDirCountVar,
        [Nullable[int]]$Tier2IssueNumber = $null
    )

    if (-not $ProjectsRoot) {
        # C8 (issue #825 post-review fix): honor the same test-only override
        # cost-fcl-helpers.ps1's script:Test-FCLClaudeProjectsRootAbsent already
        # respects, so a caller (e.g. Invoke-CostAttributionRepair via
        # Invoke-CostSessionRender) can point an end-to-end test at a temp
        # projects root instead of the real user profile.
        $testProjectsRootOverride = [Environment]::GetEnvironmentVariable('FRAME_CREDIT_LEDGER_TEST_CLAUDE_PROJECTS_ROOT', 'Process')
        $ProjectsRoot = if (-not [string]::IsNullOrWhiteSpace($testProjectsRootOverride)) {
            $testProjectsRootOverride
        }
        else {
            Join-Path ([System.Environment]::GetFolderPath('UserProfile')) '.claude' 'projects'
        }
    }

    # Normalize the caller's CWD once for all comparisons
    $normalizedParentCwd = Get-NormalizedPath -Path $ParentCwd
    $phaseMarkerMode = $null -ne $IssueNumber -and [int]$IssueNumber -gt 0
    $targetIssueNumber = if ($phaseMarkerMode) { [int]$IssueNumber } else { $null }

    $included = [System.Collections.Generic.List[object]]::new()
    # M7: composite session_id+uuid dedup guard, shared across every admitted dir/tier.
    $seenDedupKeys = [System.Collections.Generic.HashSet[string]]::new()

    # Collect all slug directories to search (D2 identity match + worktree glob + primary-slug
    # backward-compat fallback — shared with Get-CostWalkerCurrentSessionId via
    # script:Get-CostWalkerCandidateSlugDirs so the two callers can never diverge).
    $slugDirs = script:Get-CostWalkerCandidateSlugDirs -ProjectsRoot $ProjectsRoot -RepoRoot $RepoRoot -ParentCwd $ParentCwd -Slug $Slug

    # Issue #825 s1: resolve the opt-in Tier-2 corroborated-fallback admission set BEFORE the
    # main Tier-1 walk loop below (which is otherwise completely unmodified — Tier 1 stays
    # unchanged per the plan's non-goal). Tier-2-admitted files are walked in their own block
    # after Tier 1, using the corroboration + merge-window predicate instead of Tier 1's.
    $rejectedDirCount = 0
    $tier2AdmittedFiles = [System.Collections.Generic.List[string]]::new()
    if ($AdmitCorroboratedFallback) {
        $resolvedRepoRootForIdentity = if (-not [string]::IsNullOrWhiteSpace($RepoRoot)) { $RepoRoot } else { $ParentCwd }
        $tier2TargetIdentity = script:Get-CostWalkerTargetIdentity -RepoRoot $resolvedRepoRootForIdentity
        $tier1AdmittedSet = [System.Collections.Generic.HashSet[string]]::new([string[]]@($slugDirs), [System.StringComparer]::OrdinalIgnoreCase)
        # C2 (issue #825 post-review fix): the Tier-2 corroboration gate uses
        # Tier2IssueNumber (branch-prefix-only, never PR-body-derived) whenever the
        # caller explicitly supplies it — including an explicit $null, which means
        # "I resolved this branch-only and got nothing; do NOT fall back to the
        # (possibly PR-body-derived) -IssueNumber". Falling back to -IssueNumber only
        # happens for callers that predate this parameter entirely (never mention it),
        # via ContainsKey rather than a null check — a null-check-only fallback would
        # silently re-admit the exact PR-body-derived value this fix exists to reject
        # whenever a caller resolves Tier2IssueNumber to $null (branch didn't match)
        # and still threads that resolved $null through explicitly.
        $tier2EffectiveIssueNumber = if ($PSBoundParameters.ContainsKey('Tier2IssueNumber')) { $Tier2IssueNumber } else { $IssueNumber }
        $tier2Admission = script:Get-CostWalkerCorroboratedFallbackAdmission -ProjectsRoot $ProjectsRoot -TargetIdentity $tier2TargetIdentity -Tier1AdmittedDirs $tier1AdmittedSet -Branch $Branch -IssueNumber $tier2EffectiveIssueNumber
        $tier2AdmittedFiles = $tier2Admission.AdmittedFiles
        $rejectedDirCount = $tier2Admission.RejectedDirCount
    }
    if ($null -ne $RejectedDirCountVar) { $RejectedDirCountVar.Value = $rejectedDirCount }

    if ($slugDirs.Count -eq 0 -and $tier2AdmittedFiles.Count -eq 0) {
        return $included
    }

    foreach ($slugDir in $slugDirs) {
        # Only top-level JSONL files in the slug directory (not in subdirectories)
        $jsonlFiles = @(Get-ChildItem -Path $slugDir -Filter '*.jsonl' -File -ErrorAction SilentlyContinue)

        foreach ($file in $jsonlFiles) {
            $lines = @(Get-Content -Path $file.FullName -Encoding utf8 -ErrorAction SilentlyContinue)
            $sessionId = $file.BaseName
            $currentWindowIssue = $null
            $currentWindowPortHint = $null
            foreach ($line in $lines) {
                $trimmed = $line.Trim()
                if ([string]::IsNullOrEmpty($trimmed)) { continue }

                $parsedEvent = $null
                try {
                    $parsedEvent = $trimmed | ConvertFrom-Json -AsHashtable -ErrorAction Stop
                }
                catch {
                    Write-Warning "cost-walker: failed to parse JSON line in $($file.FullName): $_"
                    continue
                }

                $eventType = $parsedEvent['type']

                if ($phaseMarkerMode) {
                    $eventBranch = $parsedEvent['gitBranch']
                    if (-not (script:Test-CostWalkerPhaseMarkerBranchAllowed -Branch $eventBranch)) {
                        $currentWindowIssue = $null
                        $currentWindowPortHint = $null
                    }

                    $phaseMarker = script:Get-CostWalkerPhaseMarker -TranscriptEvent $parsedEvent
                    if ($null -ne $phaseMarker) {
                        $currentWindowIssue = $phaseMarker.IssueId
                        $currentWindowPortHint = $phaseMarker.PortHint
                    }

                    if ($eventType -eq 'assistant') {
                        if (script:Test-CostWalkerAssistantMatchesStrictFilter -TranscriptEvent $parsedEvent -NormalizedParentCwd $normalizedParentCwd -Branch $Branch) {
                            script:Add-CostWalkerAssistantEventAndSubagents -Included $included -TranscriptEvent $parsedEvent -SlugDir $slugDir -SessionId $sessionId -SeenKeys $seenDedupKeys
                            continue
                        }

                        if ($currentWindowIssue -ne $targetIssueNumber) { continue }
                        # D2: identity check is done at slug-dir level; cwd guard removed.
                        if (-not (script:Test-CostWalkerPhaseMarkerBranchAllowed -Branch $parsedEvent['gitBranch'])) { continue }

                        $parsedEvent['_phase_marker_port'] = $currentWindowPortHint
                        script:Add-CostWalkerAssistantEventAndSubagents -Included $included -TranscriptEvent $parsedEvent -SlugDir $slugDir -SessionId $sessionId -SeenKeys $seenDedupKeys
                    }
                    elseif ($null -eq $eventType) {
                        Write-Warning "cost-walker: event with null type in $($file.FullName) — skipping"
                    }
                    elseif ($script:CostWalkerSilentTypes.Contains($eventType)) {
                        continue
                    }
                    else {
                        Write-Warning "cost-walker: unknown event type '$eventType' in $($file.FullName) — skipping"
                    }

                    continue
                }

                if ($eventType -eq 'assistant') {
                    if (-not (script:Test-CostWalkerAssistantMatchesStrictFilter -TranscriptEvent $parsedEvent -NormalizedParentCwd $normalizedParentCwd -Branch $Branch)) { continue }

                    # Event passes filter — include it and traverse Agent subagents.
                    script:Add-CostWalkerAssistantEventAndSubagents -Included $included -TranscriptEvent $parsedEvent -SlugDir $slugDir -SessionId $sessionId -SeenKeys $seenDedupKeys
                }
                elseif ($null -eq $eventType) {
                    Write-Warning "cost-walker: event with null type in $($file.FullName) — skipping"
                }
                elseif ($script:CostWalkerSilentTypes.Contains($eventType)) {
                    # Known skip types — no warning
                    continue
                }
                else {
                    Write-Warning "cost-walker: unknown event type '$eventType' in $($file.FullName) — skipping"
                }
            }
        }
    }

    # Issue #825 s1: walk the Tier-2 corroborated-fallback admitted files (opt-in, empty unless
    # -AdmitCorroboratedFallback was set). Extracted to script:Invoke-CostWalkerTier2Walk (issue
    # #825 refactor pass) to keep this function's own per-PR growth from the trust ladder
    # proportionate — see that helper's docstring for the predicate/bound details.
    script:Invoke-CostWalkerTier2Walk -Included $included -Tier2AdmittedFiles $tier2AdmittedFiles `
        -NormalizedParentCwd $normalizedParentCwd -Branch $Branch -SeenDedupKeys $seenDedupKeys `
        -CorroborationWindowStart $CorroborationWindowStart -CorroborationWindowEnd $CorroborationWindowEnd

    return $included
}

function script:Invoke-CostWalkerTier2Walk {
    <#
    .SYNOPSIS
        Walks the Tier-2 corroborated-fallback admitted files and appends
        admitted events to $Included (issue #825 s1; extracted from
        Invoke-CostTranscriptWalk by the issue #825 refactor pass — this loop
        is self-contained with its own predicate and merge-window bound, so it
        does not need to share Invoke-CostTranscriptWalk's local scope).
    .DESCRIPTION
        Uses the same branch-only per-event predicate as Tier 1
        (script:Test-CostWalkerAssistantMatchesStrictFilter) plus the M8
        merge-window bound, which never applies to Tier 1. Reuses the same
        composite-dedup-key event admission (script:Add-CostWalkerAssistantEventAndSubagents)
        Tier 1 uses, via the caller-supplied $Included list and $SeenDedupKeys set,
        so an event admitted by both tiers is still only counted once.
    .PARAMETER Tier2AdmittedFiles
        The file list returned by script:Get-CostWalkerCorroboratedFallbackAdmission
        (empty when -AdmitCorroboratedFallback was not set on the caller).
    .PARAMETER CorroborationWindowStart
    .PARAMETER CorroborationWindowEnd
        Issue #825 s1, M8. Bounds Tier-2-admitted events only. A $null bound is
        not enforced, matching Invoke-CostTranscriptWalk's own contract.
    .OUTPUTS
        None — admitted events are appended directly to $Included.
    #>
    param(
        [Parameter(Mandatory)]$Included,
        [Parameter(Mandatory)]$Tier2AdmittedFiles,
        [Parameter(Mandatory)][string]$NormalizedParentCwd,
        [Parameter(Mandatory)][string]$Branch,
        [Parameter(Mandatory)]$SeenDedupKeys,
        [Nullable[datetime]]$CorroborationWindowStart = $null,
        [Nullable[datetime]]$CorroborationWindowEnd = $null
    )

    foreach ($filePath in $Tier2AdmittedFiles) {
        $tier2SessionId = [System.IO.Path]::GetFileNameWithoutExtension($filePath)
        $tier2SlugDir = Split-Path -Parent $filePath
        $tier2Lines = @(Get-Content -LiteralPath $filePath -Encoding utf8 -ErrorAction SilentlyContinue)

        foreach ($line in $tier2Lines) {
            $trimmed = $line.Trim()
            if ([string]::IsNullOrEmpty($trimmed)) { continue }

            $parsedEvent = $null
            try {
                $parsedEvent = $trimmed | ConvertFrom-Json -AsHashtable -ErrorAction Stop
            }
            catch {
                Write-Warning "cost-walker: failed to parse JSON line in ${filePath}: $_"
                continue
            }

            if ($parsedEvent['type'] -ne 'assistant') { continue }
            if (-not (script:Test-CostWalkerAssistantMatchesStrictFilter -TranscriptEvent $parsedEvent -NormalizedParentCwd $NormalizedParentCwd -Branch $Branch)) { continue }

            if ($null -ne $CorroborationWindowStart -or $null -ne $CorroborationWindowEnd) {
                $eventTimestamp = $null
                try { $eventTimestamp = [datetime]$parsedEvent['timestamp'] } catch { }
                if ($null -eq $eventTimestamp) { continue }  # M8: unparseable timestamp inside a bounded walk is excluded, not assumed in-window
                if ($null -ne $CorroborationWindowStart -and $eventTimestamp -lt $CorroborationWindowStart) { continue }
                if ($null -ne $CorroborationWindowEnd -and $eventTimestamp -gt $CorroborationWindowEnd) { continue }
            }

            script:Add-CostWalkerAssistantEventAndSubagents -Included $Included -TranscriptEvent $parsedEvent -SlugDir $tier2SlugDir -SessionId $tier2SessionId -SeenKeys $SeenDedupKeys
        }
    }
}

function Get-CostWalkerCurrentSessionId {
    <#
    .SYNOPSIS
        Derives the current capture's session identity from transcript file names
        (issue #824 s3).
    .DESCRIPTION
        Real Claude Code transcript JSONL lines carry no embedded session-identity
        field (Invoke-CostTranscriptWalk's own events are plain hashtables filtered
        purely by type/cwd/gitBranch — see its docstring). The session identity is
        instead the JSONL file's own name on disk: per the
        Documents/Design/peer-to-peer-dispatch-research.md design doc's
        {slugDir}/{sessionId}/... path convention, a transcript file's BaseName
        (filename without the .jsonl extension) IS the session's UUID.

        Resolves the same candidate slug directories Invoke-CostTranscriptWalk
        searches — script:Get-CostWalkerCandidateSlugDirs, the shared helper that
        unions D2 identity-matched dirs, the worktree-slug glob, and the
        primary-slug backward-compat fallback (mirrors Invoke-CostTranscriptWalk's
        own directory-resolution logic so this returns an identity consistent with
        what the walk itself would admit) — then, among the *.jsonl files directly
        under those directories, finds the ones containing at least one event
        matching the walk's own CURRENT admission predicate: type -eq 'assistant'
        AND gitBranch matches Branch. (issue #824 post-review fix M14: the walk's
        per-event filter dropped its cwd check once identity was enforced at the
        slug-dir level — script:Test-CostWalkerAssistantMatchesStrictFilter is
        branch-only today, so this resolver no longer applies an additional
        per-event cwd check on top of it; doing so was stricter than the walk it
        claims to mirror and could return '' for a session the walk fully admits.
        Reuses script:Test-CostWalkerAssistantMatchesStrictFilter directly — no
        predicate logic is reimplemented here.)

        M7 (issue #824 post-review fix, low severity): candidate files across all
        resolved slug dirs are sorted by LastWriteTime descending before the scan,
        so the loop returns as soon as it finds the first (most recent) matching
        file instead of always scanning every candidate file to find the max.

        Returns the BaseName of the matching file with the most recent
        LastWriteTime, or '' when no file matches (e.g. synthetic/test fixtures
        that never touch disk, or no session has produced a matching event yet).
    .PARAMETER Slug
        Pre-computed slug string for the project directory.
    .PARAMETER Branch
        Git branch name to filter events by.
    .PARAMETER ParentCwd
        Working directory path; normalized before comparison.
    .PARAMETER ProjectsRoot
        Root directory containing project slug directories. Defaults to ~/.claude/projects.
    .PARAMETER RepoRoot
        Repo root used for D2 identity resolution (script:Get-IdentityMatchedSlugDirs).
        Falls back to ParentCwd when omitted, matching this function's pre-refactor
        behavior — pass this explicitly when the caller's repo root differs from its
        parent cwd (e.g. a worktree checkout) so identity resolution agrees with
        Invoke-CostTranscriptWalk's own -RepoRoot-based resolution for the same session.
    .OUTPUTS
        [string] the matching transcript file's BaseName (session UUID), or ''.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowEmptyString()][string]$Slug = '',
        [Parameter(Mandatory)][string]$Branch,
        [Parameter(Mandatory)][string]$ParentCwd,
        [string]$ProjectsRoot = '',
        [AllowEmptyString()][string]$RepoRoot = ''
    )

    if (-not $ProjectsRoot) {
        $ProjectsRoot = Join-Path ([System.Environment]::GetFolderPath('UserProfile')) '.claude' 'projects'
    }

    $normalizedParentCwd = Get-NormalizedPath -Path $ParentCwd

    # Shared with Invoke-CostTranscriptWalk via script:Get-CostWalkerCandidateSlugDirs
    # (issue #824 refactor pass) — see that helper's docstring for the RepoRoot
    # fallback-to-ParentCwd rule.
    $slugDirs = script:Get-CostWalkerCandidateSlugDirs -ProjectsRoot $ProjectsRoot -RepoRoot $RepoRoot -ParentCwd $ParentCwd -Slug $Slug

    if ($slugDirs.Count -eq 0) {
        return ''
    }

    # M7: gather every candidate file across all resolved slug dirs, then sort
    # descending by LastWriteTime so the scan below can return on the first
    # match (the most recent one) instead of unconditionally checking every
    # file to find the max.
    $allFiles = [System.Collections.Generic.List[System.IO.FileInfo]]::new()
    foreach ($slugDir in $slugDirs) {
        $jsonlFiles = @(Get-ChildItem -Path $slugDir -Filter '*.jsonl' -File -ErrorAction SilentlyContinue)
        foreach ($file in $jsonlFiles) {
            $allFiles.Add($file)
        }
    }

    $sortedFiles = @($allFiles | Sort-Object -Property LastWriteTime -Descending)

    foreach ($file in $sortedFiles) {
        $lines = @(Get-Content -Path $file.FullName -Encoding utf8 -ErrorAction SilentlyContinue)

        foreach ($line in $lines) {
            $trimmed = $line.Trim()
            if ([string]::IsNullOrEmpty($trimmed)) { continue }

            $parsedEvent = $null
            try {
                $parsedEvent = $trimmed | ConvertFrom-Json -AsHashtable -ErrorAction Stop
            }
            catch { continue }

            if ($parsedEvent['type'] -ne 'assistant') { continue }
            # M14: branch-only predicate — matches Test-CostWalkerAssistantMatchesStrictFilter,
            # which is what Invoke-CostTranscriptWalk itself actually applies today (the
            # per-event cwd check was dropped once identity moved to the slug-dir level).
            if (-not (script:Test-CostWalkerAssistantMatchesStrictFilter -TranscriptEvent $parsedEvent -NormalizedParentCwd $normalizedParentCwd -Branch $Branch)) { continue }

            return $file.BaseName
        }
    }

    return ''
}

function Test-CostWalkerSessionTranscriptExists {
    <#
    .SYNOPSIS
        Checks whether a persisted session id's transcript file exists on THIS
        machine (issue #824 s4 verify-then-select gate).
    .DESCRIPTION
        The startup harvest reads a candidate PR's `session_id` from a (editable)
        GitHub comment before deciding whether to spend its one-per-startup
        expensive re-walk on it. This function is the "verify" half of
        verify-then-select: it answers a pure local-filesystem question — does
        any candidate slug directory contain a "{SessionId}.jsonl" file. A
        session id that resolves to no local file on this machine is
        structurally a foreign/cross-machine capture that this harvest must
        never act on.

        Issue #824 post-review fix M3: this function previously called
        script:Get-IdentityMatchedSlugDirs directly and had no -Slug parameter,
        so — unlike Get-CostWalkerCurrentSessionId (the session-id writer, which
        already resolves candidates via the shared
        script:Get-CostWalkerCandidateSlugDirs helper) — it structurally could
        not reach the worktree-slug glob ("$Slug--claude-worktrees-*") or the
        primary-slug backward-compat fallback, even when a caller supplied one.
        Since post-merge cleanup routinely removes sibling worktrees, and
        Get-IdentityMatchedSlugDirs fail-closes when it can no longer
        `git remote get-url` from a now-deleted worktree cwd, a worktree-origin
        session's transcript could sit on disk under
        ~/.claude/projects/{slug}--claude-worktrees-*/ while this gate still
        reported "not found" — permanently blocking that PR from ever being
        harvested. This function now calls the same shared
        script:Get-CostWalkerCandidateSlugDirs helper Get-CostWalkerCurrentSessionId
        and Invoke-CostTranscriptWalk already use, so the three callers can never
        independently (and silently) diverge on slug-dir resolution again.
        Passing -Slug is what actually unlocks the worktree-glob and
        primary-slug-fallback branches; omitting it degrades to the old
        identity-matched-dirs-only behavior for backward compatibility.

        This is a filename existence check only — it does not open or validate
        the file's contents. The original capturing session already verified
        content-side admission when it wrote the transcript.
    .PARAMETER SessionId
        The persisted session identity to look for (a transcript file's BaseName).
        Validated against the canonical GUID shape (M9) before use in a
        filesystem path; a non-matching value is rejected (returns $false)
        without ever reaching Join-Path.
    .PARAMETER Branch
        Accepted for signature parity with Get-CostWalkerCurrentSessionId (mirrors
        its resolution shape). Not used to filter here — SessionId already
        uniquely names the candidate transcript file.
    .PARAMETER ParentCwd
        Kept for signature parity with the sibling walker functions and passed
        through to script:Get-CostWalkerCandidateSlugDirs (used only as that
        helper's RepoRoot fallback when RepoRoot is blank — RepoRoot is
        Mandatory here, so ParentCwd's value does not change resolution today).
    .PARAMETER RepoRoot
        Absolute path to the repository root; used to resolve this machine's git
        remote identity for D2 identity matching.
    .PARAMETER Slug
        Optional pre-computed slug string for the project directory. Threading
        this through from callers (e.g. cost-baseline-harvest.ps1, which already
        has $Slug in scope) is what lets slug-dir resolution reach the
        worktree-slug glob and primary-slug fallback — see M3 above. Omitted by
        default for backward compatibility with existing callers.
    .PARAMETER ProjectsRoot
        Root directory containing project slug directories. Defaults to
        ~/.claude/projects.
    .PARAMETER PreResolvedSlugDirs
        Optional pre-resolved slug-directory list (M10-enabling). When supplied,
        this function skips its own internal script:Get-CostWalkerCandidateSlugDirs
        resolution and searches these directories instead — lets a future
        per-candidate-loop caller (e.g. cost-baseline-harvest.ps1) hoist the
        loop-invariant slug-dir resolution once outside its loop rather than
        re-resolving it on every candidate. Not wired to any caller yet.
    .OUTPUTS
        [bool] $true when a matching "{SessionId}.jsonl" file exists under any
        candidate slug directory; otherwise $false.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$SessionId,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Branch,
        [Parameter(Mandatory)][string]$ParentCwd,
        [Parameter(Mandatory)][string]$RepoRoot,
        [AllowEmptyString()][string]$Slug = '',
        [string]$ProjectsRoot = '',
        [System.Collections.Generic.List[string]]$PreResolvedSlugDirs = $null
    )

    if ([string]::IsNullOrWhiteSpace($SessionId)) { return $false }

    # M9: SessionId is read from an untrusted, publicly editable PR comment.
    # Reject any shape that isn't a canonical GUID (the actual shape of a real
    # Claude Code transcript file BaseName — see Get-CostWalkerCurrentSessionId's
    # docstring) before it is ever used to construct a filesystem path.
    if ($SessionId -notmatch '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') {
        return $false
    }

    if (-not $ProjectsRoot) {
        $ProjectsRoot = Join-Path ([System.Environment]::GetFolderPath('UserProfile')) '.claude' 'projects'
    }

    $slugDirs = if ($null -ne $PreResolvedSlugDirs) {
        $PreResolvedSlugDirs
    }
    else {
        script:Get-CostWalkerCandidateSlugDirs -ProjectsRoot $ProjectsRoot -RepoRoot $RepoRoot -ParentCwd $ParentCwd -Slug $Slug
    }

    foreach ($slugDir in $slugDirs) {
        $candidatePath = Join-Path $slugDir "$SessionId.jsonl"
        if (Test-Path -LiteralPath $candidatePath -PathType Leaf) {
            return $true
        }
    }

    return $false
}
