#Requires -Version 7.0

# ci-glob-audit-core.ps1
# The full-glob CI audit: run EVERY suite the per-PR gate enumerates on disk,
# on Linux, with the quarantine deliberately NOT applied, and record what
# happened to each one durably enough for three later chunks to read.
#
# WHY THIS EXISTS (issue #1035, chunk 1 of 4 under #993). The gate selects a
# glob minus a quarantine. When this shipped, 191 of 252 suites were
# quarantined and 189 of those carried class `unclassified`, which is not a
# decision — they were omitted by an allowlist that no longer exists and their
# CI-viability had never been measured anywhere but a maintainer's Windows
# machine. #1036 must split those into "promote it" and "it structurally
# cannot run here", and its charter says that split happens WITH A FAILURE
# MESSAGE IN HAND rather than by reading source and guessing. #1037 had to size
# the gate's fan-out from a measured per-suite duration distribution over the
# whole population. Neither input existed. (The live figures move as chunks
# land; #1037 promoted one entry, so the counts above are this file's own
# starting point, not a claim about today's tree. Derive the current ones from
# `Get-CISuiteSelection`, which is what this audit itself does.)
#
# WHY IT COULD NOT JUST REUSE THE SHARDED RUNNER. `pester-sharded-core.ps1`
# emits counts and never a message, so a row saying `fail=3` cannot tell #1036
# whether a suite has a Linux path bug or needs a live `gh`. It also imposes no
# PER-SUITE bound: `Start-Process -Wait` takes none, and while #1037 has since
# bounded the gate's JOB, a job-level limit ends the whole check rather than
# attributing the stall to a suite and carrying on. A suite that never returns
# is still neither a pass, a failure, nor a reported skip there. This audit
# attempts, by design, exactly the population most likely to contain one.
#
# FOUR TERMINAL STATES, NOT THREE. passed / failed / did-not-complete /
# executed-no-tests. The fourth is load-bearing: a `Describe` behind a platform
# guard completed, did not fail, and must never read as passed. The sharded
# runner got this wrong in BOTH directions when this audit was written — it
# folded a zero-discovery suite into the run's TEST-failure total, while an
# all-skipped suite reached exit 0 and read as green. #1037 corrected both; the
# state vocabulary here is unchanged, and the two now agree that a suite which
# executed no tests is not a pass.
#
# NO FILE-SCOPE Set-StrictMode HERE. Same reason ci-suite-selection-core.ps1
# gives: this file is dot-sourced into sessions that then run other people's
# code, and a leaked strict mode turns unrelated suites red. Each function sets
# it in its own scope.

$script:CIGlobAuditLibDir = Split-Path -Parent $PSCommandPath
. (Join-Path -Path $script:CIGlobAuditLibDir -ChildPath 'ci-suite-selection-core.ps1')

# GitHub caps an issue/comment body at 65,536 codepoints and refuses the write
# above it. Discovering that mid-run is the failure mode this constant exists
# to prevent; the record composer paginates against it rather than truncating
# detail to fit.
$script:CIGlobAuditBodyCap = 65536

# The four terminal states, in the order they are reported. `did-not-complete`
# is not "failed with a timeout" and `executed-no-tests` is not "passed with
# zero tests" — the whole point of the record is that a reader can tell the
# four apart without opening the suite.
$script:CIGlobAuditStates = @('passed', 'failed', 'did-not-complete', 'executed-no-tests')

# The record format's own version. A consumer that finds this key can tell a
# shape it understands from one it does not; a consumer reading a record that
# carries no version at all has to guess, and column order is not a contract.
# Bump this when a column moves, a field's meaning changes, or a document kind
# is added or removed.
# Version 2 (this change): the per-suite table gained `drain ms` and `suite ms`,
# splitting a row's total elapsed from the portion spent draining a pipe a
# descendant held open. A consumer that averaged v1's single elapsed column
# would silently mix the two, so this is a column move by the rule above.
$script:CIGlobAuditRecordFormatVersion = 2

# The stable pointer. Every other marker embeds the run id, which means a
# consumer cannot ask for "the current record" without enumerating every
# comment on an issue and regexing run ids out of HTML comments. This one is
# fixed, upserted, and lists every run newest-first.
$script:CIGlobAuditIndexMarker = '<!-- ci-glob-audit-index -->'

# The observation history's suite-table header, written by the composer and
# matched by the parser — ONE literal, because the parser locates the table by
# it. Two copies would let the writer move a column while the reader silently
# stopped finding any rows at all and restarted every count at 1.
$script:CIGlobAuditHistoryTableHeader = '| suite | in-population | basis | observations | last state | last run | last commit | previous basis |'

# THE fact-key list. One list, not three: the producer fills it, the compose step checks every key
# in it for cross-shard agreement, and the statement builder requires every key in it. Adding a
# dimension is one edit, and a dimension nobody measured can no longer slip past the agreement check.
$script:CIGlobAuditFactKeys = @(
    'ProcessModel', 'Concurrency', 'TokenAvailability', 'CheckoutDepth', 'CredentialPersistence',
    'GitIdentity', 'WorkingDirectory', 'RunnerImage', 'PowerShellVersion', 'PesterVersion',
    'YamlModuleVersion', 'HasToken', 'IsShallow', 'CredentialsPersisted', 'HasGitIdentity'
)

function Get-CIGlobAuditFactKeys { return , @($script:CIGlobAuditFactKeys) }

# ONE detail budget, reconciled end to end, because three different numbers on
# the same pipeline means two of them are dead work. The launcher collects at
# most MaxFailures messages of at most MaxMessageChars each; the console-tail
# fallback keeps at most DetailCharCap; and the composer's per-row cap is that
# same number. Before this was reconciled the launcher spent up to 25 x 1200
# characters collecting failure text the composer discarded at 1500, so a suite
# with many distinct failures surfaced roughly one message and the other
# twenty-four were computed, serialised, uploaded and thrown away.
$script:CIGlobAuditDetailCharCap = 3000
$script:CIGlobAuditMaxFailures = 5
$script:CIGlobAuditMaxSkips = 5
$script:CIGlobAuditMaxMessageChars = 500

# How much of a chatty suite's console output is retained in memory while it
# runs. Tail-preserving: the head is dropped as the buffer fills, because for a
# suite that never returned the last thing it printed is where it stopped.
$script:CIGlobAuditConsoleBufferChars = 262144

#region text hygiene — everything captured from an unaudited suite passes through here

function Protect-CIGlobAuditSecret {
    <#
    .SYNOPSIS
        Scrub credential-shaped material out of anything captured from an
        unaudited suite before it reaches a permanent public surface.
    .DESCRIPTION
        189 of the suites this audit runs have never been vetted; the measure
        job checks out with credential persistence ON, deliberately, for gate
        parity; and any suite that prints its git config on failure would
        otherwise publish a bearer token verbatim into a durable public issue
        comment. Actions' secret masking protects the job log stream — not a
        body composed in-process and POSTed through `gh`, and not an artifact.

        Replaced with a VISIBLE `[REDACTED:<what>]` rather than removed, so a
        reader of the record can tell "this row's detail was scrubbed" from
        "this row printed nothing", which is a distinction R5 rests on.
    .OUTPUTS
        [string] the same text with credential-shaped material replaced.
    #>
    param([AllowEmptyString()][AllowNull()][string]$Text)

    if ([string]::IsNullOrEmpty($Text)) { return '' }

    $t = $Text
    # `git config --get-regexp http.*.extraheader` and anything echoing a
    # .git/config line: the value is the credential, the key is not.
    $t = [regex]::Replace($t, '(?im)(^|\s)(http\.[^\s=]*\.extraheader)(\s*=\s*|\s+)\S.*$', '$1$2$3[REDACTED:git-extraheader]')
    # Authorization headers in either scheme, however they were printed.
    $t = [regex]::Replace($t, '(?i)\bAUTHORIZATION:\s*basic\s+\S+', 'AUTHORIZATION: basic [REDACTED:basic-credential]')
    $t = [regex]::Replace($t, '(?i)\bAUTHORIZATION:\s*bearer\s+\S+', 'AUTHORIZATION: bearer [REDACTED:bearer-token]')
    # GitHub token shapes, which travel outside a header just as easily.
    $t = [regex]::Replace($t, 'gh[pousr]_[A-Za-z0-9]{20,}', '[REDACTED:github-token]')
    $t = [regex]::Replace($t, 'github_pat_[A-Za-z0-9_]{20,}', '[REDACTED:github-pat]')
    return $t
}

function Remove-CIGlobAuditAnsi {
    <#
    .SYNOPSIS
        Strip terminal control sequences from captured console output.
    .DESCRIPTION
        Pester colours its output, so every `did-not-complete` row's detail —
        which is pure console tail — arrives full of `ESC[95m` runs. They are
        invisible to a reader, they consume the per-row detail budget that R5's
        classifying text needs, and they count against the body cap.

        Stripped at CAPTURE rather than suppressed at source: setting NO_COLOR
        or PSStyle in the suite's own process would be an environment
        divergence from the gate, and R8 treats an avoidable divergence as a
        failure rather than a tidiness win.
    #>
    param([AllowEmptyString()][AllowNull()][string]$Text)

    if ([string]::IsNullOrEmpty($Text)) { return '' }
    # CSI (colour, cursor) and OSC (title, hyperlink) forms.
    $t = [regex]::Replace($Text, "`e\[[0-9;:?]*[ -/]*[@-~]", '')
    $t = [regex]::Replace($t, "`e\][^`a`e]*(`a|`e\\)", '')
    $t = [regex]::Replace($t, "`e[@-Z\\-_]", '')
    return $t
}

function script:Get-CIGlobAuditSafeCut {
    <#
    .SYNOPSIS
        Cut a string to a length without splitting a surrogate pair.
    .DESCRIPTION
        A .Substring at a UTF-16 index can leave a lone surrogate, which
        becomes U+FFFD the moment the body is round-tripped through UTF-8 — a
        silent corruption in a durable record, in a file that is otherwise
        careful about astral characters.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory)][int]$MaxChars,
        [ValidateSet('Head', 'Tail')][string]$Keep = 'Head'
    )

    if ($MaxChars -le 0) { return '' }
    if ($Text.Length -le $MaxChars) { return $Text }

    if ($Keep -eq 'Head') {
        $end = $MaxChars
        if ([char]::IsHighSurrogate($Text[$end - 1])) { $end-- }
        return $Text.Substring(0, $end)
    }

    $start = $Text.Length - $MaxChars
    if ([char]::IsLowSurrogate($Text[$start])) { $start++ }
    return $Text.Substring($start)
}

function script:Get-CIGlobAuditFence {
    <#
    .SYNOPSIS
        A code fence long enough that the text inside cannot end it early.
    .DESCRIPTION
        Captured suite output routinely contains fenced code — this corpus
        asserts heavily on Markdown documents, and Pester embeds expected and
        actual text in its messages. A fixed three-backtick fence lets that
        text close the block and then render its own `###` heading at column
        zero, which is indistinguishable from a genuine record row. Widening
        the fence past the longest backtick run inside is what makes the block
        opaque.
    #>
    param([AllowEmptyString()][string]$Text)

    $longest = 0
    foreach ($m in [regex]::Matches([string]$Text, '`+')) {
        if ($m.Length -gt $longest) { $longest = $m.Length }
    }
    return ('`' * [Math]::Max(3, $longest + 1))
}

#endregion

#region population

function Get-CIGlobAuditPopulation {
    <#
    .SYNOPSIS
        The set of suites this audit must attempt: the gate's own on-disk
        enumeration BEFORE the quarantine is subtracted.
    .DESCRIPTION
        Derived from the gate's own selection procedure rather than re-globbed,
        so the audit tracks corpus drift instead of encoding today's count, and
        so it cannot quietly measure a different population than the gate does.

        `Get-CISuiteSelection` does not return the on-disk collection — it
        computes it internally and surfaces only `Selected` (files) and
        `Quarantined` (REGISTRY ENTRIES, which is not the same thing). The
        sound derivation is therefore

            Selected  UNION  (Quarantined.file  MINUS  StaleQuarantine)

        THIS FUNCTION THROWS ON DRIFT, deliberately, and offers no override.
        Be precise about WHY, because the obvious justification is not the true
        one: the set identity above holds UNCONDITIONALLY by construction —
        the stale subtraction already handles the one drift cause that touches
        it. What drift actually signals is that the registry this measurement
        is read against is not lint-clean, and a measurement taken from a
        registry nobody has reconciled is a measurement whose class column
        (R6's join, the whole reason #1036 can identify its own population)
        is unreliable. So the refusal is about the registry's fitness as a
        source, not about the arithmetic.

        A fail-closed predicate whose caller carries on regardless is a
        fail-open writer; the only way to make the precondition load-bearing is
        for the derivation to be unavailable without it.
    .PARAMETER TestsRoot
        Directory holding the `*.Tests.ps1` files — the gate's tests root.
    .PARAMETER QuarantinePath
        Path to the gate's quarantine registry.
    .OUTPUTS
        [PSCustomObject] with Names [string[]] (sorted), Files [string[]]
        (full paths, index-aligned with Names), ClassByName [hashtable]
        (suite name -> quarantine class, or $null for a selected suite),
        SelectedNames [string[]], SelectedCount, QuarantinedCount,
        StaleQuarantine [string[]], UnclassifiedCount, HasDrift ($false — a
        true value throws before returning), DerivationCommand [string].
    #>
    param(
        [Parameter(Mandatory)][string]$TestsRoot,
        [Parameter(Mandatory)][string]$QuarantinePath
    )

    Set-StrictMode -Version Latest

    $selection = Get-CISuiteSelection -TestsRoot $TestsRoot -QuarantinePath $QuarantinePath

    if ($selection.HasDrift) {
        throw ("ci-glob-audit: refusing to derive a population from a drifted registry. " +
            "The population identity `Selected + (Quarantined - Stale)` holds unconditionally, so this " +
            "is not a refusal about the arithmetic: the registry must be lint-clean BEFORE a measurement " +
            "is taken from it, because every row's quarantine class is read from it and a class read from " +
            "an unreconciled registry is not evidence about that suite. Reconcile the registry, then " +
            "re-dispatch. Drift: " + ($selection.DriftDetails -join ' | '))
    }

    $classByName = @{}
    $quarantinedNames = [System.Collections.Generic.List[string]]::new()
    foreach ($entry in @($selection.Quarantined)) {
        $file = [string]$entry.file
        if ([string]::IsNullOrWhiteSpace($file)) { continue }
        if ($selection.StaleQuarantine -contains $file) { continue }
        $quarantinedNames.Add($file)
        $classByName[$file] = [string]$entry.class
    }
    foreach ($name in @($selection.SelectedNames)) { $classByName[$name] = $null }

    $names = @(@($selection.SelectedNames) + @($quarantinedNames) | Sort-Object -Unique)
    $files = @($names | ForEach-Object { Join-Path -Path $TestsRoot -ChildPath $_ })

    return [PSCustomObject]@{
        Names             = $names
        Files             = $files
        ClassByName       = $classByName
        SelectedNames     = @($selection.SelectedNames)
        SelectedCount     = @($selection.Selected).Count
        QuarantinedCount  = @($selection.Quarantined).Count
        StaleQuarantine   = @($selection.StaleQuarantine)
        UnclassifiedCount = $selection.UnclassifiedCount
        HasDrift          = $false
        DerivationCommand = "Get-CISuiteSelection -TestsRoot '$TestsRoot' -QuarantinePath '$QuarantinePath'; Selected UNION (Quarantined.file MINUS StaleQuarantine)"
    }
}

function Get-CIGlobAuditContentDigest {
    <#
    .SYNOPSIS
        A suite's content fingerprint — the axis on which two observations are
        observations of the SAME suite.
    .DESCRIPTION
        A history keyed on file name alone reports "two observations" for a
        suite that was rewritten between them. Hashed over raw bytes so a line
        ending change is visible rather than normalised away; a suite whose
        bytes changed is a different subject even if its tests did not.
    #>
    param([Parameter(Mandatory)][string]$Path)

    Set-StrictMode -Version Latest

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return 'missing' }
    $hash = Get-FileHash -LiteralPath $Path -Algorithm SHA256
    return $hash.Hash.Substring(0, 12).ToLowerInvariant()
}

function Get-CIGlobAuditShardAssignment {
    <#
    .SYNOPSIS
        Which shard runs which suite. Deterministic, and stated rather than
        implied, because every job derives the same assignment independently.
    .DESCRIPTION
        Round-robin over the sorted name list. Round-robin rather than
        contiguous blocks because nothing here knows a suite's duration yet —
        that distribution is what this audit exists to produce — so the only
        defensible spreading rule is one that does not assume alphabetical
        neighbours are alike. It also spreads any cluster of non-returning
        suites across jobs instead of concentrating them in one.
    .OUTPUTS
        [int[]] shard index per input item, index-aligned with -Names.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Names,
        [Parameter(Mandatory)][ValidateRange(1, 64)][int]$ShardCount
    )

    Set-StrictMode -Version Latest

    $assignment = @()
    for ($i = 0; $i -lt $Names.Count; $i++) { $assignment += ($i % $ShardCount) }
    return , $assignment
}

#endregion

#region classification

function ConvertTo-CIGlobAuditState {
    <#
    .SYNOPSIS
        The classifier: one suite's raw execution outcome -> one of the four
        terminal states, plus the reason that made it that state.
    .DESCRIPTION
        Pure, so it can be driven to every state including the ones a live run
        may not exhibit. The ORDER of these rules is the contract:

          1. The child did not return within the bound  -> did-not-complete.
             Checked first: a suite that never returned has no trustworthy
             counts, and reading counts off a killed process is how a hang
             becomes a green row.
          2. No parsable result file                    -> failed.
             The launcher writes its result BEFORE it exits, so a completed
             child with no result crashed, threw during discovery, or was
             killed by the OS. "Nothing to read" is never "nothing wrong".
          3. Exit code inconsistent with the counts     -> failed.
             The launcher's exit code is a pure function of its own failure
             count. A disagreement means something exited around it.
          4. Any failed test or failed container        -> failed.
             Container failures cover discovery-time throws, which produce no
             failed TEST and would otherwise read as executed-no-tests.
          5. At least one test EXECUTED and passed      -> passed.
             Executed, not discovered: exit 0 with Failed = 0 is also what a
             suite that ran nothing produces, and separating those two is the
             entire reason this classifier exists.
          6. Otherwise                                  -> executed-no-tests,
             sub-classified `no-tests-discovered` vs `all-skipped`. Both
             completed, neither failed, neither ran anything.
    .OUTPUTS
        [PSCustomObject] State, Reason, Executed, Discovered.
    #>
    param(
        [Parameter(Mandatory)][bool]$Completed,
        [int]$ExitCode = 0,
        [Parameter(Mandatory)][bool]$HasResult,
        [int]$Passed = 0,
        [int]$Failed = 0,
        [int]$Skipped = 0,
        [int]$NotRun = 0,
        [int]$ContainerFailed = 0
    )

    Set-StrictMode -Version Latest

    if (-not $Completed) {
        return [PSCustomObject]@{
            State = 'did-not-complete'; Reason = 'bound-exceeded'
            Executed = 0; Discovered = 0
        }
    }

    $discovered = $Passed + $Failed + $Skipped + $NotRun
    $executed = $Passed + $Failed
    $failures = $Failed + $ContainerFailed

    if (-not $HasResult) {
        return [PSCustomObject]@{
            State = 'failed'; Reason = 'no-result-file'
            Executed = 0; Discovered = 0
        }
    }

    $expectedExit = if ($failures -gt 0) { 1 } else { 0 }
    if ($ExitCode -ne $expectedExit) {
        return [PSCustomObject]@{
            State = 'failed'; Reason = "exit-code-inconsistent (exit $ExitCode, expected $expectedExit for $failures failure(s))"
            Executed = $executed; Discovered = $discovered
        }
    }

    if ($failures -gt 0) {
        $reason = if ($Failed -gt 0) { 'test-failures' } else { 'container-failure' }
        return [PSCustomObject]@{
            State = 'failed'; Reason = $reason
            Executed = $executed; Discovered = $discovered
        }
    }

    if ($executed -gt 0) {
        return [PSCustomObject]@{
            State = 'passed'; Reason = 'tests-executed-and-passed'
            Executed = $executed; Discovered = $discovered
        }
    }

    $reason = if ($discovered -eq 0) { 'no-tests-discovered' } else { 'all-skipped' }
    return [PSCustomObject]@{
        State = 'executed-no-tests'; Reason = $reason
        Executed = 0; Discovered = $discovered
    }
}

function Get-CIGlobAuditDetail {
    <#
    .SYNOPSIS
        The classifying detail a non-passed row carries — what #1036 reads
        instead of opening the suite's source.
    .DESCRIPTION
        A count is not detail. "fail=3" cannot distinguish a Linux path bug
        from a suite that needs a live `gh`, and that distinction is the whole
        job of the chunk downstream of this one.

        Structured failure messages first, because they are what actually
        classifies; captured console output only as the fallback, and TAIL
        rather than head — for a suite that never returned, the last thing it
        printed is where it stopped, and an auth prompt is also at the tail.

        An empty return is honest, not a gap to paper over: a suite that
        blocked before emitting anything leaves nothing to capture. The record
        renders such a row explicitly as nothing-emitted and names it as a row
        #1036 cannot classify, rather than manufacturing text.

        THE RETURN CARRIES ITS PROVENANCE, and that is load-bearing rather than
        decorative. The two kinds of detail must be truncated from OPPOSITE
        ENDS: structured messages are joined head-first and the FIRST one is
        what classifies `linux-red` against `never-ci`, while a console tail's
        whole value is its last line. A composer that cannot tell them apart
        has to pick one end and be wrong about the other population — which is
        precisely the defect that shipped here, keeping the head of a
        deliberately tail-selected capture.
    .OUTPUTS
        [PSCustomObject] Text [string], Source ('structured' | 'console-tail' |
        'none'), TruncateFrom ('Head' | 'Tail').
    #>
    param(
        [Parameter(Mandatory)][string]$State,
        [string]$Reason = '',
        [object[]]$Failures = @(),
        [object[]]$Skips = @(),
        [string[]]$ContainerErrors = @(),
        [string]$StdOut = '',
        [string]$StdErr = '',
        [int]$TailChars = 0
    )

    Set-StrictMode -Version Latest

    if ($TailChars -le 0) { $TailChars = $script:CIGlobAuditDetailCharCap }

    $parts = [System.Collections.Generic.List[string]]::new()

    foreach ($f in @($Failures)) {
        $name = if ($f.PSObject.Properties.Match('name').Count -gt 0) { [string]$f.name } else { '' }
        $msg = if ($f.PSObject.Properties.Match('message').Count -gt 0) { [string]$f.message } else { '' }
        $line = (($name, $msg) | Where-Object { $_ } ) -join ' -- '
        if ($line) { $parts.Add($line) }
    }
    foreach ($e in @($ContainerErrors)) { if ($e) { $parts.Add("container: $e") } }

    if ($State -eq 'executed-no-tests') {
        foreach ($s in @($Skips)) {
            $name = if ($s.PSObject.Properties.Match('name').Count -gt 0) { [string]$s.name } else { '' }
            $msg = if ($s.PSObject.Properties.Match('message').Count -gt 0) { [string]$s.message } else { '' }
            $line = (($name, $msg) | Where-Object { $_ }) -join ' -- '
            if ($line) { $parts.Add("skipped: $line") }
        }
    }

    $source = 'structured'
    if ($parts.Count -eq 0) {
        $source = 'console-tail'
        # The reason is not decoration here: it is the only thing that can tell
        # a reader whether the console tail below is the end of a suite that
        # never returned, or everything a crashed suite managed to print. Both
        # arrive as an untitled block of console text otherwise.
        $tail = script:Get-CIGlobAuditTail -Text (@($StdErr, $StdOut) -join "`n") -TailChars $TailChars
        if ($tail) {
            $lead = if ($Reason) { "console output ($State / $Reason):" } else { "console output ($State):" }
            $parts.Add($lead)
            $parts.Add($tail)
        }
    }

    # Ordinal-unique, preserving order. `Select-Object -Unique` is
    # case-INSENSITIVE, so two genuinely distinct failure lines differing only
    # in case collapse to one — a silent loss inside the field R5 governs.
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    $unique = [System.Collections.Generic.List[string]]::new()
    foreach ($p in $parts) { if ($seen.Add($p)) { $unique.Add($p) } }

    $text = ($unique -join "`n").Trim()
    if (-not $text) { $source = 'none' }

    return [PSCustomObject]@{
        Text         = $text
        Source       = $source
        # Structured detail is joined head-first and the first message
        # classifies; a console tail's stopping point is its last line.
        TruncateFrom = if ($source -eq 'console-tail') { 'Tail' } else { 'Head' }
    }
}

function script:Get-CIGlobAuditTail {
    param([string]$Text, [int]$TailChars)
    if ([string]::IsNullOrWhiteSpace($Text)) { return '' }
    $t = $Text.Trim()
    if ($t.Length -le $TailChars) { return $t }
    return '...(head elided)... ' + (script:Get-CIGlobAuditSafeCut -Text $t -MaxChars $TailChars -Keep 'Tail')
}

#endregion

#region execution

function Get-CIGlobAuditLauncherScript {
    <#
    .SYNOPSIS
        The script one child process runs to execute one suite.
    .DESCRIPTION
        Writes its result file BEFORE exiting and captures failure MESSAGES,
        not just counts — the two properties `pester-sharded-core.ps1` lacks
        that make this audit's record usable by #1036.

        Container results are counted separately: a throw during discovery
        produces a failed CONTAINER and no failed test, which without this
        would arrive as "completed, nothing ran".

        THE BUDGET IS RECONCILED WITH THE COMPOSER'S. The defaults multiply out
        to the composer's per-row detail cap rather than to several times it:
        collecting twenty-five messages the record then discards is work the
        run pays for at every stage — serialised into the partial JSON,
        uploaded as an artifact, downloaded, parsed — and then thrown away.

        `$OutputVerbosity` is interpolated into the generated script, so it is
        constrained by ValidateSet rather than escaped. The paths are escaped
        (verified against every shape a Linux filesystem allows); an
        unconstrained verbosity string would be one caller away from arbitrary
        code in the child, and the same pattern already exists unconstrained at
        `pester-sharded-core.ps1:347`.
    #>
    param(
        [Parameter(Mandatory)][string]$SuiteFile,
        [Parameter(Mandatory)][string]$ResultFile,
        [ValidateSet('None', 'Minimal', 'Normal', 'Detailed', 'Diagnostic')][string]$OutputVerbosity = 'Detailed',
        [ValidateRange(1, 100)][int]$MaxFailures = 0,
        [ValidateRange(1, 100)][int]$MaxSkips = 0,
        [ValidateRange(1, 100000)][int]$MaxMessageChars = 0
    )

    if ($MaxFailures -le 0) { $MaxFailures = $script:CIGlobAuditMaxFailures }
    if ($MaxSkips -le 0) { $MaxSkips = $script:CIGlobAuditMaxSkips }
    if ($MaxMessageChars -le 0) { $MaxMessageChars = $script:CIGlobAuditMaxMessageChars }

    $suite = $SuiteFile -replace "'", "''"
    $result = $ResultFile -replace "'", "''"

    return @"
#Requires -Version 7.0
# Generated by ci-glob-audit-core.ps1. One suite, one process, one result file.
`$ErrorActionPreference = 'Continue'
function Limit-Text([string]`$s) {
    if (-not `$s) { return '' }
    if (`$s.Length -le $MaxMessageChars) { return `$s }
    # Cut on a rune boundary. A .Substring at a UTF-16 index can leave a lone
    # surrogate, which becomes U+FFFD once the record is round-tripped through
    # UTF-8 — silent corruption in a durable artifact.
    `$end = $MaxMessageChars
    if ([char]::IsHighSurrogate(`$s[`$end - 1])) { `$end-- }
    return `$s.Substring(0, `$end) + '...(truncated)'
}
try {
    `$cfg = New-PesterConfiguration
    `$cfg.Run.Path = @('$suite')
    `$cfg.Run.Exit = `$false
    `$cfg.Run.PassThru = `$true
    `$cfg.Output.Verbosity = '$OutputVerbosity'
    `$r = Invoke-Pester -Configuration `$cfg

    `$passed = 0; `$failed = 0; `$skipped = 0; `$notRun = 0; `$containerFailed = 0
    `$failures = @(); `$skips = @(); `$containerErrors = @()

    if (`$null -ne `$r) {
        `$passed  = [int]`$r.PassedCount
        `$failed  = [int]`$r.FailedCount
        `$skipped = [int]`$r.SkippedCount
        `$notRun  = [int]`$r.NotRunCount

        foreach (`$c in @(`$r.Containers)) {
            if ([string]`$c.Result -eq 'Failed') {
                `$containerFailed++
                foreach (`$e in @(`$c.ErrorRecord)) {
                    if (`$null -ne `$e) { `$containerErrors += (Limit-Text ([string]`$e.Exception.Message)) }
                }
            }
        }
        foreach (`$t in @(`$r.Failed)) {
            if (`$failures.Count -ge $MaxFailures) { break }
            `$msg = ''
            foreach (`$e in @(`$t.ErrorRecord)) { if (`$null -ne `$e -and -not `$msg) { `$msg = [string]`$e.Exception.Message } }
            `$failures += [ordered]@{ name = [string]`$t.ExpandedPath; message = (Limit-Text `$msg) }
        }
        foreach (`$t in @(`$r.Skipped)) {
            if (`$skips.Count -ge $MaxSkips) { break }
            `$msg = ''
            foreach (`$e in @(`$t.ErrorRecord)) { if (`$null -ne `$e -and -not `$msg) { `$msg = [string]`$e.Exception.Message } }
            `$skips += [ordered]@{ name = [string]`$t.ExpandedPath; message = (Limit-Text `$msg) }
        }
    }

    `$payload = [ordered]@{
        passed = `$passed; failed = `$failed; skipped = `$skipped; notRun = `$notRun
        containerFailed = `$containerFailed
        failures = `$failures; skips = `$skips; containerErrors = `$containerErrors
    }
    `$payload | ConvertTo-Json -Depth 6 -Compress | Set-Content -LiteralPath '$result' -Encoding utf8
    if ((`$failed + `$containerFailed) -gt 0) { exit 1 } else { exit 0 }
}
catch {
    # No result file on this path, deliberately: the classifier reads its
    # absence as `failed / no-result-file` rather than guessing counts.
    [Console]::Error.WriteLine("ci-glob-audit launcher: `$(`$_.Exception.Message)")
    [Console]::Error.WriteLine([string]`$_.ScriptStackTrace)
    exit 2
}
"@
}

function Get-CIGlobAuditSurvivalVerdict {
    <#
    .SYNOPSIS
        "The bound fired" and "the slot is free" are two facts. Given what the
        harness observed, which of them hold?
    .DESCRIPTION
        Extracted from the execution path deliberately, because a decision rule
        buried inside a process-management loop can only be exercised by
        producing the very condition it exists to detect — and a surviving
        orphan is expensive and flaky to manufacture on purpose. Named and pure,
        it can be driven to every combination directly, which is the difference
        between a rule that is defended and one that merely looks right.

        THE SECOND SIGNAL IS THE POINT. `-not HasExited` sees only the direct
        child: Kill($true) walks the tree it can see, so a grandchild spawned
        after enumeration, or one that double-forks, survives while the direct
        child's HasExited is true. But such a descendant INHERITED the
        redirected pipe, so the pipe still being open after the child is gone
        is evidence of it. Reporting zero survivors on that path is exactly the
        conflation this audit's docstring claims to have fixed.

        A held pipe WITHOUT a kill is reported separately rather than folded in:
        nothing survived a kill there, but something the suite started is still
        running on the runner and will contaminate later rows' durations.
    .OUTPUTS
        [PSCustomObject] SurvivedKill, DescendantHeldOutput, Evidence [string].
    #>
    param(
        [Parameter(Mandatory)][bool]$ChildExited,
        [Parameter(Mandatory)][bool]$KillEscalated,
        [Parameter(Mandatory)][bool]$OutputPipeHeld
    )

    $survived = (-not $ChildExited) -or ($KillEscalated -and $OutputPipeHeld)
    $evidence = if (-not $ChildExited) { 'the direct child was still alive after the kill grace' }
    elseif ($KillEscalated -and $OutputPipeHeld) { 'the child was gone but a descendant still held the redirected output pipe' }
    elseif ($OutputPipeHeld) { 'no kill was needed, but a descendant still held the redirected output pipe after the child exited' }
    else { 'the child exited and its output pipe closed' }

    return [PSCustomObject]@{
        SurvivedKill         = $survived
        DescendantHeldOutput = $OutputPipeHeld
        Evidence             = $evidence
    }
}

function script:Limit-CIGlobAuditBuffer {
    <#
    .SYNOPSIS
        Trim a live capture buffer down to its tail cap without splitting a
        surrogate pair.
    .DESCRIPTION
        The cut is at the HEAD, because for a suite that never returned it is
        the END of the output that classifies. A head cut at a UTF-16 index can
        leave a lone LOW surrogate at position zero, and that becomes U+FFFD the
        moment the buffer is written to the `.log` artifact as UTF-8 — silent
        corruption in a durable file. Every other cut site in this file is
        rune-safe; this one was the exception.

        Extracted for the same reason the survival verdict is: a rule buried in
        a process poll loop can only be exercised by producing a suite that
        prints a quarter of a megabyte, and a rule that cannot be invoked cannot
        be defended.
    .OUTPUTS
        [int] how many characters were removed from the head (0 if none).
    #>
    param(
        [Parameter(Mandatory)][System.Text.StringBuilder]$Buffer,
        [Parameter(Mandatory)][int]$MaxChars
    )

    if ($MaxChars -le 0) { return 0 }
    if ($Buffer.Length -le $MaxChars) { return 0 }

    $cut = $Buffer.Length - $MaxChars
    # The KEPT side must not begin with the low half of a pair whose high half
    # is about to be removed. Dropping one more character keeps the buffer
    # inside the cap as well as intact.
    if ([char]::IsLowSurrogate($Buffer[$cut])) { $cut++ }
    [void]$Buffer.Remove(0, $cut)
    return $cut
}

function Get-CIGlobAuditDurationAccount {
    <#
    .SYNOPSIS
        Split a row's wall clock into the suite's own cost and the bounded drain
        that followed it.
    .DESCRIPTION
        The harness keeps reading for up to the kill grace AFTER the child has
        exited, because a descendant that inherited the pipe may still be
        emitting output the record needs. That drain is wall clock the stopwatch
        keeps counting, so a suite that exited in one second and left a
        pipe-holding descendant behind lands in the record at eleven — and
        #1037 derived the gate's fan-out width from exactly these durations.

        FLAGGING THE ROW AS CONTAMINATING LATER ROWS IS A DIFFERENT STATEMENT.
        The record already says a held pipe contaminates the rows that follow it
        on the same job; it said nothing about that row's OWN duration being
        inflated by the wait. So both figures are recorded and named rather than
        one being silently adjusted: `ElapsedMs` stays the total the harness held
        the slot, `DrainMs` is how much of that total was drain, and `SuiteMs`
        is what remains — the figure a shard-sizing consumer wants.
    .OUTPUTS
        [PSCustomObject] ElapsedMs, DrainMs, SuiteMs.
    #>
    param(
        [Parameter(Mandatory)][long]$TotalMs,
        [AllowNull()][object]$DrainStartedAtMs = $null
    )

    $total = [long][Math]::Max(0L, $TotalMs)
    $drain = 0L
    if ($null -ne $DrainStartedAtMs) {
        $start = [long]$DrainStartedAtMs
        if ($start -lt 0) { $start = 0 }
        if ($start -lt $total) { $drain = $total - $start }
    }

    return [PSCustomObject]@{
        ElapsedMs = [int]$total
        DrainMs   = [int]$drain
        SuiteMs   = [int]($total - $drain)
    }
}

function script:Save-CIGlobAuditCapture {
    <#
    .SYNOPSIS
        Read the result file and write the two `.log` artifacts, in the order
        that keeps them telling the same story.
    .DESCRIPTION
        THE PARSE HAPPENS FIRST, AND THAT ORDER IS THE POINT. A malformed result
        file is diagnosed by a note appended to captured stderr, and on that one
        path the note IS the diagnosis. Writing the artifacts before appending it
        left `.err.log` and the record disagreeing about what the harness
        observed — on precisely the path a reader opens the artifact for.

        Owning both halves in one function is what makes the ordering testable:
        the property is "the artifact and the record agree", which no assertion
        against either one alone can establish.
    .OUTPUTS
        [PSCustomObject] StdOut, StdErr, HasResult, Passed, Failed, Skipped,
        NotRun, ContainerFailed, Failures, Skips, ContainerErrors.
    #>
    param(
        [Parameter(Mandatory)][string]$OutPath,
        [Parameter(Mandatory)][string]$ErrPath,
        [Parameter(Mandatory)][AllowEmptyString()][string]$StdOut,
        [Parameter(Mandatory)][AllowEmptyString()][string]$StdErr,
        [Parameter(Mandatory)][string]$ResultPath,
        [Parameter(Mandatory)][bool]$Completed
    )

    $outText = $StdOut
    $errText = $StdErr

    $hasResult = $false
    $passed = 0; $failed = 0; $skipped = 0; $notRun = 0; $containerFailed = 0
    $failures = @(); $skips = @(); $containerErrors = @()

    if ($Completed -and (Test-Path -LiteralPath $ResultPath)) {
        try {
            $data = Get-Content -LiteralPath $ResultPath -Raw | ConvertFrom-Json
            $passed = [int]$data.passed; $failed = [int]$data.failed
            $skipped = [int]$data.skipped; $notRun = [int]$data.notRun
            $containerFailed = [int]$data.containerFailed
            # Structured text from the suite reaches the durable record too, so
            # it is scrubbed on the same terms as the console capture.
            $failures = @($data.failures | ForEach-Object {
                    [PSCustomObject]@{
                        name    = Protect-CIGlobAuditSecret -Text ([string]$_.name)
                        message = Protect-CIGlobAuditSecret -Text (Remove-CIGlobAuditAnsi -Text ([string]$_.message))
                    }
                })
            $skips = @($data.skips | ForEach-Object {
                    [PSCustomObject]@{
                        name    = Protect-CIGlobAuditSecret -Text ([string]$_.name)
                        message = Protect-CIGlobAuditSecret -Text (Remove-CIGlobAuditAnsi -Text ([string]$_.message))
                    }
                })
            $containerErrors = @($data.containerErrors | ForEach-Object {
                    Protect-CIGlobAuditSecret -Text (Remove-CIGlobAuditAnsi -Text ([string]$_))
                })
            $hasResult = $true
        }
        catch {
            # A malformed result file is not a result. Left $hasResult false so
            # the classifier reaches `failed / no-result-file` rather than
            # reading zeros as a clean run. Appended BEFORE the artifact is
            # written, so the artifact carries the diagnosis too.
            $errText = ($errText + "`nci-glob-audit host: result file did not parse: $($_.Exception.Message)").Trim()
        }
    }

    [System.IO.File]::WriteAllText($OutPath, $outText, [System.Text.UTF8Encoding]::new($false))
    [System.IO.File]::WriteAllText($ErrPath, $errText, [System.Text.UTF8Encoding]::new($false))

    return [PSCustomObject]@{
        StdOut          = $outText
        StdErr          = $errText
        HasResult       = $hasResult
        Passed          = $passed
        Failed          = $failed
        Skipped         = $skipped
        NotRun          = $notRun
        ContainerFailed = $containerFailed
        Failures        = $failures
        Skips           = $skips
        ContainerErrors = $containerErrors
    }
}

function Invoke-CIGlobAuditSuite {
    <#
    .SYNOPSIS
        Attempt one suite, bounded, capturing everything needed to classify it.
    .DESCRIPTION
        THE BOUND IS THE POINT. Nothing under `.github/` bounds a test that
        never returns, and this audit runs the population most likely to
        contain one.

        "The bound fired" and "the slot is free" are TWO FACTS, and the
        repository's existing killable-process helper conflates them:
        `Invoke-GCTreeKillableProcess` at
        `.github/scripts/lib/goal-contract-validate-core.ps1:1249` reports
        TimedOut = $true even when Kill($true) threw, and its taskkill fallback
        at :1295-1304 is $IsWindows-gated, leaving Linux with none. (That is
        the SECOND independent diagnosis of the same two defects; a pointer
        back from the helper itself is owed and is tracked as such.) An
        orphaned child keeps consuming the runner and contaminates every later
        row's duration while each row individually looks well-formed. So this
        function kills the tree, WAITS for the corpse, and reports
        ProcessSurvivedKill per row — a run in which one survived is not
        offered as a timing measurement.

        `-not $proc.HasExited` IS NOT ENOUGH ON ITS OWN, and the second signal
        is free. Kill($true) walks the tree it can see; a grandchild spawned
        after enumeration, or one that double-forks, survives while the direct
        child's HasExited is true. But a surviving descendant INHERITED THE
        REDIRECTED PIPE, so the pipe staying open after the child is gone is
        direct evidence of one. That is why capture here is incremental rather
        than a ReadToEnd: a ReadToEnd on a pipe an orphan holds never completes
        and its result is discarded, so on exactly the path the docstring
        anticipates, everything the suite already printed was thrown away and
        the row fell through to the nothing-emitted text while it had in fact
        emitted plenty.
    .OUTPUTS
        [PSCustomObject] one record row (pre-classification fields plus State).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SuiteFile,
        [Parameter(Mandatory)][ValidateRange(1, 21600)][int]$TimeoutSeconds,
        [Parameter(Mandatory)][string]$WorkDir,
        [ValidateSet('None', 'Minimal', 'Normal', 'Detailed', 'Diagnostic')][string]$OutputVerbosity = 'Detailed',
        [int]$KillGraceMs = 10000,
        [int]$DetailTailChars = 0,
        [int]$PollMs = 100,
        [hashtable]$EnvironmentOverrides = @{}
    )

    Set-StrictMode -Version Latest

    if ($DetailTailChars -le 0) { $DetailTailChars = $script:CIGlobAuditDetailCharCap }

    if (-not (Test-Path -LiteralPath $WorkDir)) {
        New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null
    }

    $stem = [System.IO.Path]::GetFileNameWithoutExtension($SuiteFile) + '-' + [System.Guid]::NewGuid().ToString('N').Substring(0, 8)
    $launcherPath = Join-Path $WorkDir "$stem.launcher.ps1"
    $resultPath = Join-Path $WorkDir "$stem.result.json"
    $outPath = Join-Path $WorkDir "$stem.out.log"
    $errPath = Join-Path $WorkDir "$stem.err.log"

    $launcher = Get-CIGlobAuditLauncherScript -SuiteFile $SuiteFile -ResultFile $resultPath -OutputVerbosity $OutputVerbosity
    [System.IO.File]::WriteAllText($launcherPath, $launcher, [System.Text.UTF8Encoding]::new($false))

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = (Get-Process -Id $PID).Path
    foreach ($a in @('-NoProfile', '-NonInteractive', '-NoLogo', '-File', $launcherPath)) { $psi.ArgumentList.Add($a) | Out-Null }
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    # Redirect stdin from a closed stream too: a suite that blocks on a prompt
    # must fail or hang on its own account, never because this harness left a
    # live console attached that a human could accidentally satisfy.
    $psi.RedirectStandardInput = $true
    $psi.UseShellExecute = $false
    $psi.WorkingDirectory = (Get-Location).Path
    # Per-suite environment additions exist for ONE purpose: arming the
    # non-returning control. Applied to that child alone rather than to the
    # job, so every real suite meets exactly the environment the gate gives it
    # — an extra variable in the shared environment would be an avoidable
    # divergence, and the parity criterion treats those as failures.
    foreach ($k in $EnvironmentOverrides.Keys) { $psi.Environment[[string]$k] = [string]$EnvironmentOverrides[$k] }

    $proc = [System.Diagnostics.Process]::new()
    $proc.StartInfo = $psi

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $completed = $false
    $killEscalated = $false
    $survivedKill = $false
    $descendantHeldOutput = $false
    # Declared out here so an exception inside the loop still leaves the
    # duration account computable rather than tripping StrictMode.
    $drainStartedAtMs = $null
    $exitCode = $null
    $stdOut = ''
    $stdErr = ''

    $outBuf = [System.Text.StringBuilder]::new()
    $errBuf = [System.Text.StringBuilder]::new()

    try {
        $null = $proc.Start()
        $proc.StandardInput.Close()

        # Incremental, main-thread, bounded. Both streams are pumped from the
        # start: a child that fills a redirected pipe buffer blocks forever on
        # write, which would turn every chatty suite into a fake
        # did-not-complete row. Reading incrementally rather than with a single
        # ReadToEnd is what keeps the output of a suite whose pipe an orphan
        # still holds.
        $outChunk = [char[]]::new(8192)
        $errChunk = [char[]]::new(8192)
        $outTask = $null
        $errTask = $null
        $outOpen = $true
        $errOpen = $true
        $boundMs = [long]$TimeoutSeconds * 1000L
        $drainDeadlineMs = $null

        while ($true) {
            if ($outOpen -and $null -eq $outTask) { $outTask = $proc.StandardOutput.ReadAsync($outChunk, 0, $outChunk.Length) }
            if ($errOpen -and $null -eq $errTask) { $errTask = $proc.StandardError.ReadAsync($errChunk, 0, $errChunk.Length) }

            $pending = [System.Collections.Generic.List[System.Threading.Tasks.Task]]::new()
            if ($null -ne $outTask) { $pending.Add($outTask) }
            if ($null -ne $errTask) { $pending.Add($errTask) }
            if ($pending.Count -gt 0) {
                try { $null = [System.Threading.Tasks.Task]::WaitAny($pending.ToArray(), $PollMs) } catch { }
            }
            else { Start-Sleep -Milliseconds $PollMs }

            if ($null -ne $outTask -and $outTask.IsCompleted) {
                $n = 0
                try { $n = [int]$outTask.Result } catch { $n = 0 }
                if ($n -gt 0) { [void]$outBuf.Append($outChunk, 0, $n) } else { $outOpen = $false }
                $outTask = $null
            }
            if ($null -ne $errTask -and $errTask.IsCompleted) {
                $n = 0
                try { $n = [int]$errTask.Result } catch { $n = 0 }
                if ($n -gt 0) { [void]$errBuf.Append($errChunk, 0, $n) } else { $errOpen = $false }
                $errTask = $null
            }

            # Tail-preserving trim. A suite printing megabytes must not be able
            # to exhaust the runner's memory, and for a suite that never
            # returned it is the END of the output that classifies. Rune-safe,
            # because this buffer is written verbatim to a UTF-8 artifact.
            foreach ($buf in @($outBuf, $errBuf)) {
                [void](script:Limit-CIGlobAuditBuffer -Buffer $buf -MaxChars $script:CIGlobAuditConsoleBufferChars)
            }

            if ((-not $outOpen) -and (-not $errOpen) -and $proc.HasExited) { break }

            if ($null -eq $drainDeadlineMs) {
                if ($proc.HasExited) {
                    # Exited, but a stream is still open — a descendant
                    # inherited the pipe. Bounded drain, then move on. The
                    # START is remembered, not just the deadline: everything
                    # after it is drain, not the suite's own cost.
                    $drainStartedAtMs = $sw.ElapsedMilliseconds
                    $drainDeadlineMs = $drainStartedAtMs + $KillGraceMs
                }
                elseif ($sw.ElapsedMilliseconds -ge $boundMs) {
                    $killEscalated = $true
                    try { $proc.Kill($true) } catch { }
                    $drainStartedAtMs = $sw.ElapsedMilliseconds
                    $drainDeadlineMs = $drainStartedAtMs + $KillGraceMs
                }
            }
            elseif ($sw.ElapsedMilliseconds -ge $drainDeadlineMs) { break }
        }

        $survival = Get-CIGlobAuditSurvivalVerdict -ChildExited $proc.HasExited `
            -KillEscalated $killEscalated -OutputPipeHeld ($outOpen -or $errOpen)
        $descendantHeldOutput = $survival.DescendantHeldOutput
        $survivedKill = $survival.SurvivedKill
        $completed = $proc.HasExited -and (-not $killEscalated)
        if ($completed) {
            try { $exitCode = $proc.ExitCode } catch { $exitCode = $null }
        }
    }
    catch {
        [void]$errBuf.AppendLine("ci-glob-audit host: $($_.Exception.Message)")
    }
    finally {
        $sw.Stop()
        try { $proc.Dispose() } catch { }
    }

    # SCRUB AT CAPTURE, not at compose. The partial JSON artifacts carry these
    # same strings, and the measure job holds a live bearer credential in its
    # checkout's git config for gate parity — so a suite that prints its git
    # config on failure would publish it into an artifact even if the record
    # itself were clean. ANSI is stripped here too, so the escapes never
    # consume the per-row detail budget downstream.
    $stdOut = Protect-CIGlobAuditSecret -Text (Remove-CIGlobAuditAnsi -Text $outBuf.ToString())
    $stdErr = Protect-CIGlobAuditSecret -Text (Remove-CIGlobAuditAnsi -Text $errBuf.ToString())

    # Parse THEN write, in one place, so the artifact and the record cannot
    # disagree about what the harness observed.
    $capture = script:Save-CIGlobAuditCapture -OutPath $outPath -ErrPath $errPath `
        -StdOut $stdOut -StdErr $stdErr -ResultPath $resultPath -Completed $completed
    $stdOut = $capture.StdOut
    $stdErr = $capture.StdErr
    $hasResult = $capture.HasResult
    $passed = $capture.Passed; $failed = $capture.Failed
    $skipped = $capture.Skipped; $notRun = $capture.NotRun
    $containerFailed = $capture.ContainerFailed
    $failures = @($capture.Failures); $skips = @($capture.Skips); $containerErrors = @($capture.ContainerErrors)

    $duration = Get-CIGlobAuditDurationAccount -TotalMs $sw.ElapsedMilliseconds -DrainStartedAtMs $drainStartedAtMs

    $classification = ConvertTo-CIGlobAuditState -Completed $completed -ExitCode ([int]($exitCode ?? -1)) `
        -HasResult $hasResult -Passed $passed -Failed $failed -Skipped $skipped -NotRun $notRun `
        -ContainerFailed $containerFailed

    $detail = Get-CIGlobAuditDetail -State $classification.State -Reason $classification.Reason `
        -Failures $failures -Skips $skips -ContainerErrors $containerErrors `
        -StdOut $stdOut -StdErr $stdErr -TailChars $DetailTailChars

    return [PSCustomObject]@{
        Name                 = Split-Path -Leaf $SuiteFile
        State                = $classification.State
        Reason               = $classification.Reason
        ElapsedMs            = $duration.ElapsedMs
        # Named separately because the record must be able to say which is
        # which: a row whose descendant held the pipe absorbs up to the kill
        # grace of drain into its total, and #1037 derived the gate's fan-out
        # width from these.
        DrainMs              = $duration.DrainMs
        SuiteMs              = $duration.SuiteMs
        BoundSeconds         = $TimeoutSeconds
        Completed            = $completed
        ExitCode             = $exitCode
        Passed               = $passed
        Failed               = $failed
        Skipped              = $skipped
        NotRun               = $notRun
        Discovered           = $classification.Discovered
        Executed             = $classification.Executed
        ContainerFailed      = $containerFailed
        KillEscalated        = $killEscalated
        ProcessSurvivedKill  = $survivedKill
        DescendantHeldOutput = $descendantHeldOutput
        Detail               = $detail.Text
        DetailSource         = $detail.Source
        DetailTruncateFrom   = $detail.TruncateFrom
        StdOutPath           = $outPath
        StdErrPath           = $errPath
    }
}

function Invoke-CIGlobAuditShard {
    <#
    .SYNOPSIS
        Attempt every suite assigned to this shard, one at a time, and return
        the enriched rows.
    .DESCRIPTION
        ONE SUITE PROCESS AT A TIME, deliberately. Fanning out inside a job
        would make each per-suite wall clock a contended measurement, and the
        chunk downstream of this one sizes shards from that distribution: an
        8-way fan-out on a 2-core hosted runner inflates every duration by a
        factor nobody can back out of a single contended sample. Parallelism
        here is across JOBS, on separate runners, so no two measured suites
        ever share a machine.

        Every assigned suite is attempted. There is no elapsed-budget escape
        that would let the shard stop early and leave rows unattempted — a
        record in which a suite can appear without having been attempted is
        exactly the shape this whole audit exists to replace.

        THE DIGEST IS TAKEN BEFORE THE SUITE RUNS. Suites execute with write
        access to the workspace, so a suite that rewrites its own file — or a
        later shard-mate's — would otherwise be recorded against the content it
        left behind rather than the content that was executed, and R9's whole
        comparability axis keys on that digest.
    .OUTPUTS
        [PSCustomObject[]] one row per assigned suite.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Assignments,
        [Parameter(Mandatory)][ValidateRange(1, 21600)][int]$TimeoutSeconds,
        [Parameter(Mandatory)][string]$WorkDir,
        [ValidateSet('None', 'Minimal', 'Normal', 'Detailed', 'Diagnostic')][string]$OutputVerbosity = 'Detailed'
    )

    Set-StrictMode -Version Latest

    $rows = [System.Collections.Generic.List[object]]::new()
    $ordinal = 0
    foreach ($item in $Assignments) {
        $ordinal++
        Write-Host "[$ordinal/$($Assignments.Count)] $($item.Name) (bound ${TimeoutSeconds}s)"
        $overrides = @{}
        if ($item.PSObject.Properties.Match('EnvironmentOverrides').Count -gt 0 -and $item.EnvironmentOverrides) {
            foreach ($p in $item.EnvironmentOverrides.PSObject.Properties) { $overrides[$p.Name] = [string]$p.Value }
        }
        # BEFORE, not after: the suite is about to run with write access to this
        # workspace, and a digest sampled afterwards describes whatever the
        # suite left behind rather than what was executed.
        $digestBefore = Get-CIGlobAuditContentDigest -Path $item.Path
        $row = Invoke-CIGlobAuditSuite -SuiteFile $item.Path -TimeoutSeconds $TimeoutSeconds `
            -WorkDir $WorkDir -OutputVerbosity $OutputVerbosity -EnvironmentOverrides $overrides
        $digestAfter = Get-CIGlobAuditContentDigest -Path $item.Path
        $enriched = [PSCustomObject]@{
            Name                 = $item.Name
            Path                 = $item.Path
            InPopulation         = [bool]$item.InPopulation
            ControlRole          = [string]$item.ControlRole
            QuarantineClass      = $item.QuarantineClass
            ContentDigest        = $digestBefore
            # A suite that rewrote its own file between these two samples is a
            # fact about the workspace a later reader needs, not one to discard.
            ContentDigestAfter   = $digestAfter
            SelfModified         = ($digestBefore -ne $digestAfter)
            State                = $row.State
            Reason               = $row.Reason
            ElapsedMs            = $row.ElapsedMs
            DrainMs              = $row.DrainMs
            SuiteMs              = $row.SuiteMs
            BoundSeconds         = $row.BoundSeconds
            Completed            = $row.Completed
            ExitCode             = $row.ExitCode
            Passed               = $row.Passed
            Failed               = $row.Failed
            Skipped              = $row.Skipped
            NotRun               = $row.NotRun
            Discovered           = $row.Discovered
            Executed             = $row.Executed
            ContainerFailed      = $row.ContainerFailed
            KillEscalated        = $row.KillEscalated
            ProcessSurvivedKill  = $row.ProcessSurvivedKill
            DescendantHeldOutput = $row.DescendantHeldOutput
            Detail               = $row.Detail
            DetailSource         = $row.DetailSource
            DetailTruncateFrom   = $row.DetailTruncateFrom
        }
        Write-Host "    -> $($enriched.State) ($($enriched.Reason)) in $($enriched.ElapsedMs) ms"
        $rows.Add($enriched)
    }
    return , @($rows)
}

#endregion

#region environment, parity, reachability

function script:Invoke-CIGlobAuditGit {
    # Declared at file scope, once. Declaring it inside Get-CIGlobAuditRuntimeFacts
    # redefined a script-scoped function on every call and leaked it into the
    # dot-sourcing session, which for a library that gets dot-sourced into
    # sessions that then run other people's code is a real hazard, not a style
    # point.
    param([string]$Dir, [string[]]$GitArgs)
    try { return (& git -C $Dir @GitArgs 2>$null | Out-String).Trim() } catch { return '' }
}

function Get-CIGlobAuditRuntimeFacts {
    <#
    .SYNOPSIS
        Observe — never declare — what the suite-execution environment actually
        is on this runner.
    .DESCRIPTION
        The parity table's audit side must come from the RUN, not from the
        workflow file. A table populated from YAML is a transcript of intent:
        it says what the author meant to configure, and stays green when the
        configuration did something else. So every value here is read from the
        live process, the live git checkout, or the live module list, and each
        carries the observation that produced it.

        Two of these are only observable from inside the runner loop —
        `processModel` and `concurrency` — because they are properties of the
        program doing the observing. They are stated by the runner itself
        rather than by the workflow for the same reason: the runner is the only
        thing that knows how many suite processes it has in flight.
    .OUTPUTS
        [hashtable] of parity-table-ready strings plus an Observations map.
    #>
    param(
        [Parameter(Mandatory)][string]$ProcessModel,
        [Parameter(Mandatory)][string]$Concurrency,
        [string]$RepoRoot = ''
    )

    Set-StrictMode -Version Latest

    $tokenNames = @('GH_TOKEN', 'GITHUB_TOKEN', 'GH_ENTERPRISE_TOKEN')
    $tokensPresent = @($tokenNames | Where-Object { -not [string]::IsNullOrWhiteSpace([System.Environment]::GetEnvironmentVariable($_)) })
    $tokenAvailability = if ($tokensPresent.Count -eq 0) { 'observed: no token in the environment of the suite-executing process' }
    else { "observed: token(s) PRESENT ($($tokensPresent -join ', '))" }

    $gitDir = if ($RepoRoot) { $RepoRoot } else { (Get-Location).Path }

    $isShallow = script:Invoke-CIGlobAuditGit -Dir $gitDir -GitArgs @('rev-parse', '--is-shallow-repository')
    $commitCount = script:Invoke-CIGlobAuditGit -Dir $gitDir -GitArgs @('rev-list', '--count', 'HEAD')
    $checkoutDepth = if ($isShallow -eq 'true') { "observed: shallow, $commitCount commit(s) reachable => fetch-depth 1" }
    elseif ($isShallow -eq 'false') { "observed: full clone, $commitCount commit(s) reachable" }
    else { 'observed: not a git checkout' }

    $extraHeader = script:Invoke-CIGlobAuditGit -Dir $gitDir -GitArgs @('config', '--get-regexp', '^http\..*\.extraheader')
    $credentialPersistence = if ($extraHeader) { 'observed: true — an auth extraheader is present in the checkout''s git config' }
    else { 'observed: false — no auth extraheader in the checkout''s git config' }

    $userName = script:Invoke-CIGlobAuditGit -Dir $gitDir -GitArgs @('config', '--get', 'user.name')
    $userEmail = script:Invoke-CIGlobAuditGit -Dir $gitDir -GitArgs @('config', '--get', 'user.email')
    $gitIdentity = if ($userName -or $userEmail) { "observed: configured ($userName <$userEmail>)" } else { 'observed: none configured' }

    $pesterModule = Get-Module -ListAvailable -Name Pester | Sort-Object Version -Descending | Select-Object -First 1
    $yamlModule = Get-Module -ListAvailable -Name 'powershell-yaml' | Sort-Object Version -Descending | Select-Object -First 1
    $image = @($env:ImageOS, $env:ImageVersion) | Where-Object { $_ }

    return @{
        ProcessModel          = $ProcessModel
        Concurrency           = $Concurrency
        TokenAvailability     = $tokenAvailability
        CheckoutDepth         = $checkoutDepth
        CredentialPersistence = $credentialPersistence
        GitIdentity           = $gitIdentity
        WorkingDirectory      = "observed: $((Get-Location).Path)"
        RunnerImage           = if ($image) { ($image -join ' / ') } else { [string][System.Runtime.InteropServices.RuntimeInformation]::OSDescription }
        PowerShellVersion     = [string]$PSVersionTable.PSVersion
        PesterVersion         = if ($pesterModule) { [string]$pesterModule.Version } else { '(not installed)' }
        YamlModuleVersion     = if ($yamlModule) { [string]$yamlModule.Version } else { '(not installed)' }
        # Structured mirrors of the four dimensions whose agreement with the
        # gate is a yes/no rather than a judgement. The prose strings above are
        # for the reader; agreement is computed from THESE, because deciding
        # "does it agree" by pattern-matching the prose is how a table starts
        # reporting agreement it never checked.
        HasToken              = ($tokensPresent.Count -gt 0)
        IsShallow             = ($isShallow -eq 'true')
        CredentialsPersisted  = [bool]$extraHeader
        HasGitIdentity        = [bool]($userName -or $userEmail)
    }
}

function script:Resolve-CIGlobAuditFactVerdict {
    <#
    .SYNOPSIS
        Turn ONE observed boolean fact into a three-valued agreement plus the
        basis that verdict rests on.
    .DESCRIPTION
        A `$null` fact is an UNOBSERVED fact, and `-not $null` is `$true` while
        `[bool]$null` is `$false` — so reading a missing observation through
        either coercion invents a polarity out of nothing, in the one column a
        reader trusts. That is the defect the three-valued `Agrees` and
        `Format-CIGlobAuditAgreement` exist to prevent, bypassed at the four
        sites that fed them. It reproduced end to end: a `git identity` row
        asserting `yes` while its own cells contradicted each other, certified
        by a Basis reading "computed: from the observed HasGitIdentity fact" —
        a fact that did not exist.

        THE BASIS IS PART OF THE FIX, not decoration. Correcting the verdict to
        `unknown` while leaving a Basis that claims a computation happened just
        moves the false statement one column right.

        A VALUE THAT IS NOT A BOOLEAN IS NOT A POLARITY EITHER. `[bool]'false'`
        is `$true` in PowerShell, so a mirror that arrived as a string would be
        coerced to the wrong answer with no way for a reader to tell. Anything
        that is not a boolean, a number, or a string PowerShell's own boolean
        parser accepts is reported unobserved and NAMED, on the same terms as a
        missing one. This side is correct whatever the caller passes.
    .OUTPUTS
        [PSCustomObject] Agrees ($true/$false/$null), Basis [string].
    #>
    param(
        [Parameter(Mandatory)][string]$FactName,
        [AllowNull()][object]$Value = $null,
        [switch]$AgreesWhenTrue
    )

    $observed = $null
    if ($Value -is [bool]) { $observed = [bool]$Value }
    elseif ($Value -is [int] -or $Value -is [long] -or $Value -is [double] -or $Value -is [decimal]) { $observed = ($Value -ne 0) }
    elseif ($Value -is [string]) {
        $parsed = $false
        if ([bool]::TryParse([string]$Value, [ref]$parsed)) { $observed = $parsed }
    }

    if ($null -eq $observed) {
        $why = if ($null -eq $Value) { 'it was NOT OBSERVED' } else { "the value supplied for it ('$Value') is not a boolean observation" }
        return [PSCustomObject]@{
            Agrees = $null
            Basis  = "not checkable from this run: the $FactName fact is unavailable because $why. Nothing was measured on this dimension, so it neither agrees nor disagrees — reading a missing observation as a polarity is what this column exists to prevent."
        }
    }

    $agrees = if ($AgreesWhenTrue) { $observed } else { -not $observed }
    return [PSCustomObject]@{
        Agrees = $agrees
        Basis  = "computed: from the observed $FactName fact (= $observed), not from the prose above it"
    }
}

function Get-CIGlobAuditEnvironmentStatement {
    <#
    .SYNOPSIS
        Per-dimension: what the gate's value is, what THIS run's value is, and
        whether they agree.
    .DESCRIPTION
        Parity is per-dimension or it is nothing. A single "parity holds"
        sentence is false on its face — the parent establishes the process
        model as structurally divergent, so a blanket claim is a lie about the
        one dimension everybody already knows differs.

        Where the gate states a CONSTRAINT rather than a value — a version
        window, a runner label, a checkout convention — the gate's side is that
        constraint. Fabricating an exact gate-side value would make the table
        read cleaner and say something untrue.

        Audit-side values come from the RUN, not from this repository's YAML:
        the runner's actual PowerShell and module versions appear in no
        workflow file, and a table that reads them off the workflow is a
        transcript of intent rather than a measurement.

        AGREEMENT IS THREE-VALUED, and that is the point of this revision.
        `$true`, `$false`, and `$null` for "the gate states no value this run
        can compare against". An earlier shape hard-coded `$true` on five of
        eleven dimensions, so an out-of-window Pester and an entirely ABSENT
        powershell-yaml both rendered `agrees: yes` — a claim of parity on a
        dimension nothing checked, which R8(a) calls a failure. Two of those
        five turned out to be genuinely checkable (the Pester window is stated
        in the gate's own YAML; the yaml module's installation is a yes/no),
        and the other three are honestly unknown rather than quietly agreed.
        Every row therefore carries the BASIS on which its verdict was reached,
        so a reader can tell a computed yes from an assumed one.
    .OUTPUTS
        [PSCustomObject[]] Dimension, Gate, Audit, Agrees ($true/$false/$null),
        Basis, Note.
    #>
    param(
        [Parameter(Mandatory)][hashtable]$Facts
    )

    Set-StrictMode -Version Latest

    # Validated against THE fact-key list, not a fourth hand-maintained copy of
    # it. Adding a dimension is one edit at the top of this file.
    foreach ($required in (Get-CIGlobAuditFactKeys)) {
        if (-not $Facts.ContainsKey($required)) {
            throw "ci-glob-audit: environment statement is missing observed fact '$required'. A dimension nobody measured is a dimension the parity claim silently skips."
        }
    }

    $ProcessModel = [string]$Facts['ProcessModel']
    $Concurrency = [string]$Facts['Concurrency']
    $TokenAvailability = [string]$Facts['TokenAvailability']
    $CheckoutDepth = [string]$Facts['CheckoutDepth']
    $CredentialPersistence = [string]$Facts['CredentialPersistence']
    $GitIdentity = [string]$Facts['GitIdentity']
    $WorkingDirectory = [string]$Facts['WorkingDirectory']
    $RunnerImage = [string]$Facts['RunnerImage']
    $PowerShellVersion = [string]$Facts['PowerShellVersion']
    $PesterVersion = [string]$Facts['PesterVersion']
    $YamlModuleVersion = [string]$Facts['YamlModuleVersion']

    # The gate's Pester constraint is a stated WINDOW, which makes this the one
    # module dimension that is genuinely checkable rather than assumed.
    $pesterFloor = [version]'6.0.0'
    $pesterCeiling = [version]'6.999.999'
    $pesterParsed = $null
    $pesterInWindow = $null
    if ([version]::TryParse($PesterVersion, [ref]$pesterParsed)) {
        $pesterInWindow = ($pesterParsed -ge $pesterFloor -and $pesterParsed -le $pesterCeiling)
    }
    elseif ($PesterVersion) {
        # "(not installed)", or anything else that is not a version, is a
        # resolved value OUTSIDE the gate's window — a divergence, not an
        # unknown, because the gate's own step installs one.
        $pesterInWindow = $false
    }
    $pesterBasis = if ($null -eq $pesterInWindow) { 'not checked: no audit-side value was resolved' }
    elseif ($pesterInWindow) { "computed: $PesterVersion falls inside the gate's stated window" }
    else { "computed: $PesterVersion is NOT inside the gate's stated window >= 6.0.0, <= 6.999.999" }

    $yamlInstalled = -not ([string]::IsNullOrWhiteSpace($YamlModuleVersion) -or $YamlModuleVersion -eq '(not installed)')
    $psResolved = -not [string]::IsNullOrWhiteSpace($PowerShellVersion)

    # THREE-VALUED AT THE SOURCE. These four dimensions are the ones with a
    # structured mirror, and each verdict is resolved through the one helper
    # that refuses to turn an unobserved fact into a polarity. Inlining
    # `(-not $Facts[...])` here is what bypassed `Agrees`/`Format-...Agreement`
    # after they were introduced to stop exactly that.
    $tokenVerdict = script:Resolve-CIGlobAuditFactVerdict -FactName 'HasToken' -Value $Facts['HasToken']
    $shallowVerdict = script:Resolve-CIGlobAuditFactVerdict -FactName 'IsShallow' -Value $Facts['IsShallow'] -AgreesWhenTrue
    $credentialVerdict = script:Resolve-CIGlobAuditFactVerdict -FactName 'CredentialsPersisted' -Value $Facts['CredentialsPersisted'] -AgreesWhenTrue
    $identityVerdict = script:Resolve-CIGlobAuditFactVerdict -FactName 'HasGitIdentity' -Value $Facts['HasGitIdentity']

    $rows = @(
        [PSCustomObject]@{
            Dimension = 'runner OS image'
            Gate      = 'constraint: `runs-on: ubuntu-latest` (a label, not an image version)'
            Audit     = "resolved: $RunnerImage"
            Agrees    = $null
            Basis     = 'not checkable from this run: the gate pins only a floating label, and the image IT resolved at its own run time is not observable here. R9 pools on this axis, which is why the resolved value is recorded rather than a verdict asserted.'
            Note      = 'The audit-side value is observed from the runner''s own environment. The gate''s side is deliberately not filled in from this repository''s YAML — a value read off the workflow is a transcript of intent, which R8''s proof standard excludes.'
        },
        [PSCustomObject]@{
            Dimension = 'process model'
            Gate      = 'one child pwsh process per selected suite, via the sharded runner; the SUITE is unbounded, the job is bounded (#1037)'
            Audit     = $ProcessModel
            Agrees    = $false
            Basis     = 'computed: same granularity since #1037, still divergent on the bound — the audit bounds and kills each suite, the gate bounds only the whole job'
            Note      = 'Until #1037 this was divergent on GRANULARITY: the gate ran one shared Invoke-Pester, so a per-suite bound could not be applied at all. The gate now runs one process per suite as this audit does, and what survives is the bound — this audit kills a suite at its own limit and records it; the gate lets a suite run until the job''s limit expires and takes the whole job with it. A duration measured here still does not predict the same suite under the gate, but the reason is now CONTENTION (see the concurrency row), not the process model.'
        },
        [PSCustomObject]@{
            Dimension = 'concurrency'
            Gate      = 'one job, N suite processes at a time on one runner (#1037; N derived from this audit''s own distribution)'
            Audit     = $Concurrency
            Agrees    = $false
            Basis     = 'computed: both fan out, and differently — the audit spreads suites across runners one at a time each, the gate runs several at once on one runner'
            Note      = 'Divergent, and stated because R7 depends on it: per-suite wall clock is only a usable distribution if nothing else ran on that runner at the same time. That holds for THIS side and does not hold for the gate''s, which is why a duration measured here sizes the gate''s fan-out but does not predict its wall clock. Before #1037 the gate had no parallelism at all; the divergence has changed shape, not disappeared.'
        },
        [PSCustomObject]@{
            Dimension = 'PowerShell version'
            Gate      = 'constraint: unstated in the workflow; whatever the runner image ships'
            Audit     = $PowerShellVersion
            Agrees    = $psResolved
            Basis     = if ($psResolved) { 'computed: the gate imposes NO constraint on this dimension, so any resolved value satisfies it; a value was resolved' } else { 'computed: no audit-side value resolved, so nothing satisfies even an empty constraint' }
            Note      = 'Both take the image default; neither pins. The verdict here is that an unconstrained dimension cannot be violated — not that the two runners were observed to match, which this run cannot establish.'
        },
        [PSCustomObject]@{
            Dimension = 'Pester version'
            Gate      = 'constraint: window >= 6.0.0, <= 6.999.999 (pester.yml)'
            Audit     = $PesterVersion
            Agrees    = $pesterInWindow
            Basis     = $pesterBasis
            Note      = 'The gate states an explicit window, so this dimension is checked against it rather than assumed. Within-window drift is still a dimension R9 pools on.'
        },
        [PSCustomObject]@{
            Dimension = 'powershell-yaml version'
            Gate      = 'constraint: unpinned latest, INSTALLED by the gate''s own step (pester.yml)'
            Audit     = $YamlModuleVersion
            Agrees    = $yamlInstalled
            Basis     = if ($yamlInstalled) { "computed: resolved to $YamlModuleVersion, satisfying the gate's install-it constraint" } else { 'computed: the module is ABSENT, and the gate installs it — an avoidable divergence' }
            Note      = 'Omitting it would be an avoidable divergence that reddens every suite importing it, which R8(b) treats as a failure rather than an account. The version itself is unpinned on both sides, so only presence is checkable.'
        },
        [PSCustomObject]@{
            Dimension = 'credential and token availability'
            Gate      = 'no permissions:, no env:, no token in the suite-running step'
            Audit     = $TokenAvailability
            Agrees    = $tokenVerdict.Agrees
            Basis     = $tokenVerdict.Basis
            # The structured mirror, carried so the instrument basis can hash
            # THIS rather than the prose beside it.
            Structured = $Facts['HasToken']
            Note      = 'Any token this run needs to persist its record is step-scoped away from suite execution. A suite that shells out to `gh` must meet the same nothing the gate gives it. Scope: this covers a token in the ENVIRONMENT; the credential reachable through the checkout is the next row.'
        },
        [PSCustomObject]@{
            Dimension = 'checkout depth'
            Gate      = 'constraint: bare actions/checkout => fetch-depth 1'
            Audit     = $CheckoutDepth
            Agrees    = $shallowVerdict.Agrees
            Basis     = $shallowVerdict.Basis
            # The prose on this row embeds a COMMIT COUNT, so hashing it would
            # reset every observation count on a run where one commit landed.
            Structured = $Facts['IsShallow']
            Note      = 'Matters for any suite that reads history.'
        },
        [PSCustomObject]@{
            Dimension = 'credential persistence'
            Gate      = 'constraint: bare actions/checkout => persist-credentials true'
            Audit     = $CredentialPersistence
            Agrees    = $credentialVerdict.Agrees
            Basis     = $credentialVerdict.Basis
            Structured = $Facts['CredentialsPersisted']
            Note      = 'Matters for any suite that runs git against the origin remote. Read this row as parity WITH an exposure, not as reassurance: agreeing with the gate here means both give every suite a usable bearer credential. Everything captured from a suite is scrubbed before it reaches a durable surface for exactly that reason.'
        },
        [PSCustomObject]@{
            Dimension = 'git identity'
            Gate      = 'none supplied by the workflow itself; the sharded runner it now invokes supplies one AROUND ITS SEQUENTIAL SHARD (#1037)'
            Audit     = $GitIdentity
            Agrees    = $identityVerdict.Agrees
            Basis     = $identityVerdict.Basis
            Structured = $Facts['HasGitIdentity']
            Note      = 'The verdict above is about the JOB environment, which is what this audit can observe on its own side, and there the two still match. An enumerated divergence sits underneath it: the sharded runner writes a temp global gitconfig around its sequential shard, so since #1037 the suites on that shard DO get an identity under the gate and get none here. That the runner needs one at all is this repository''s own evidence that a class of suites requires it — and this audit gives that class nothing, which is a real difference in what the two runs measure, not a formality.'
        },
        [PSCustomObject]@{
            Dimension = 'working directory'
            Gate      = 'constraint: actions/checkout convention ($GITHUB_WORKSPACE)'
            Audit     = $WorkingDirectory
            Agrees    = $null
            Basis     = 'not checkable from this run: the gate states a convention rather than a path, and this run has no access to the gate''s own $GITHUB_WORKSPACE. Fabricating the gate''s value to make the row comparable is what R8(a) calls a failure.'
            Note      = 'Recorded because a suite that resolves paths relative to the working directory behaves differently if it moves; the value is observed even though the comparison is not available.'
        }
    )

    return , $rows
}

function Format-CIGlobAuditAgreement {
    <#
    .SYNOPSIS
        Render a three-valued agreement verdict without collapsing `unknown`
        into either polarity.
    .DESCRIPTION
        `$null` rendered through a plain truthiness test reads as `no`, which
        turns "nothing checked this" into "these differ" — a different false
        statement, not a fix. Both directions matter: `unknown` counted as
        agreement is the defect this replaces.
    #>
    param([AllowNull()][object]$Agrees)
    if ($null -eq $Agrees) { return '**unknown**' }
    if ([bool]$Agrees) { return 'yes' }
    return '**no**'
}

function Get-CIGlobAuditGateAgreement {
    <#
    .SYNOPSIS
        Where the audit and the gate overlap, do they agree?
    .DESCRIPTION
        The audit runs the full population, so it already ran the gate's
        selected suites, and those are green under the gate today. The
        comparison is therefore a filter over a record the run already has —
        and it is the only check that can catch an AVOIDABLE divergence, which
        passes an honest per-dimension statement while making every outcome
        garbage. Enumeration reaches only the divergences somebody thought of.
    .OUTPUTS
        [PSCustomObject] OverlapCount, AgreeCount, Disagreements [rows].
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Rows,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$SelectedNames
    )

    Set-StrictMode -Version Latest

    $overlap = @($Rows | Where-Object { $SelectedNames -contains $_.Name })
    $disagree = @($overlap | Where-Object { $_.State -ne 'passed' })

    return [PSCustomObject]@{
        OverlapCount   = $overlap.Count
        AgreeCount     = $overlap.Count - $disagree.Count
        Disagreements  = $disagree
        GateExpectation = 'every gate-selected suite passes (the gate is green on the default branch)'
    }
}

function Get-CIGlobAuditReachability {
    <#
    .SYNOPSIS
        R4's standing property: is any suite this run recorded as
        `did-not-complete` reachable by a documented way of running this
        repository's tests?
    .DESCRIPTION
        Two documented paths, with DIFFERENT populations, and checking only the
        first is how a previous design came to recommend putting a
        deliberately non-returning suite in a subdirectory of the tests root —
        safe from the gate, and directly in the path of
        `Invoke-Pester .github/scripts/Tests/`, which the contributor
        instructions and the pull-request template both prescribe and which is
        recursive and never reads the quarantine.

        Reasoning about blast radius from what SELECTS a suite instead of what
        EXECUTES it is the error; the tests-root arm is the one that catches it.

        BOTH SIDES ARE NORMALISED TO A RELATIVE FORM, and neither is resolved
        against the filesystem. Two separate reasons, and dropping either one
        reopens a hole:

          * The shipped pipeline's row `Path` is RELATIVE — Prepare builds it
            as `Join-Path '.github/scripts/Tests' $name` and Compose re-stamps
            the same relative string — while an earlier version of this
            function resolved the root to an ABSOLUTE path and then tested
            `StartsWith`. That comparison is false for every row the pipeline
            can produce, forever. It worked in exactly one circumstance: when
            `Resolve-Path` threw because the root did not exist. All 253
            in-population suites sit directly under the tests root and the 191
            quarantined ones are not in `SelectedNames`, so for the population
            this audit exists to attempt, BOTH arms were dead at once and the
            record affirmatively printed `clean: True`.
          * `Resolve-Path` on a row's own `Path` must never be called. This
            function runs BEFORE any persistence, with no try/catch above it,
            so a suite deleted between Prepare and Compose would convert a
            silent false-clean into total record loss — a strictly worse
            failure than the one being fixed.
    .OUTPUTS
        [PSCustomObject] Clean, GateReachable [string[]], TestsRootReachable [string[]].
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Rows,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$SelectedNames,
        [Parameter(Mandatory)][string]$TestsRoot
    )

    Set-StrictMode -Version Latest

    $normRoot = script:ConvertTo-CIGlobAuditComparablePath -Path $TestsRoot

    $stalled = @($Rows | Where-Object { $_.State -eq 'did-not-complete' })
    $gateReachable = @($stalled | Where-Object { $SelectedNames -contains $_.Name } | ForEach-Object { $_.Name })
    $rootReachable = @($stalled | Where-Object {
            $p = script:ConvertTo-CIGlobAuditComparablePath -Path ([string]$_.Path)
            $p -and $normRoot -and (
                $p.Equals($normRoot, [System.StringComparison]::OrdinalIgnoreCase) -or
                $p.StartsWith($normRoot + '/', [System.StringComparison]::OrdinalIgnoreCase)
            )
        } | ForEach-Object { $_.Name })

    return [PSCustomObject]@{
        Clean              = (($gateReachable.Count -eq 0) -and ($rootReachable.Count -eq 0))
        GateReachable      = $gateReachable
        TestsRootReachable = $rootReachable
        StalledCount       = $stalled.Count
    }
}

function script:ConvertTo-CIGlobAuditComparablePath {
    <#
    .SYNOPSIS
        Put a path into the one form both sides of the reachability comparison
        can be expressed in, without touching the filesystem.
    .DESCRIPTION
        Separator-normalised, leading `./` stripped, trailing separator
        trimmed, and — only when the value is already rooted — made relative to
        the current location so an absolute root and a relative row can be
        compared at all. `Resolve-Path` is deliberately absent: this runs
        before any persistence and a throw here costs the whole record.
    #>
    param([AllowEmptyString()][AllowNull()][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }

    $p = $Path.Replace('\', '/')
    if ([System.IO.Path]::IsPathRooted($Path)) {
        $cwd = (Get-Location).Path.Replace('\', '/').TrimEnd('/')
        if ($cwd -and $p.StartsWith($cwd + '/', [System.StringComparison]::OrdinalIgnoreCase)) {
            $p = $p.Substring($cwd.Length + 1)
        }
    }
    while ($p.StartsWith('./')) { $p = $p.Substring(2) }
    return $p.TrimEnd('/')
}

#endregion

#region comparability basis and history

function Get-CIGlobAuditInstrumentBasis {
    <#
    .SYNOPSIS
        The instrument half of "two observations of the same thing".
    .DESCRIPTION
        B3 as widened: two observations count as observations of the same thing
        only if the suite's CONTENT and the run parameters that can change a
        terminal state were the same. Those parameters are not a fixed short
        list — they are the bound, the execution model, and every dimension the
        environment statement records as verdict-changing. A history blind to
        the instrument reports two comparable observations for a suite recorded
        `did-not-complete` at bound B and `passed` at 4B, and nothing anywhere
        calibrates the bound.

        Hashed over the DIMENSION VALUES rather than a version string, so a new
        dimension added to the statement automatically enters the basis instead
        of silently pooling across it.

        ONE DIMENSION IS EXCLUDED, and the exclusion is narrow on purpose.
        R9's standard is "parameters that CAN CHANGE A TERMINAL STATE".
        Concurrency cannot: the audit's shard count varies how many separate
        RUNNERS are in flight, and each suite still runs alone in its own
        bounded process on its own machine, so dispatching at 4 shards instead
        of 8 cannot alter any suite's outcome. Including it reset the
        observation count to 1 for every suite on a dispatch that changed
        nothing a suite can see — and that count is what #1036 promotes on.

        NOTHING ELSE IS PRUNED, and specifically not the runner image or the
        module versions, even though those churn far more often. R9 names a
        drifting `ubuntu-latest` image as a dimension the basis MUST cover; a
        basis blind to it pools across exactly the drift the criterion was
        widened to catch. The frequent-reset cost there is the criterion
        working, not the criterion misfiring.

        THE STRUCTURED MIRROR WINS OVER THE PROSE WHEREVER ONE EXISTS. The
        `Audit` cell is written for a reader, and the checkout-depth cell
        embeds a COMMIT COUNT: hashing it made 4321 -> 4322 a basis change,
        resetting every suite's observation count on a run where a single
        commit landed and nothing about the instrument moved. That is M14's
        exact harm, arriving through the reader-facing column. It is not live
        while the measure job checks out at depth 1 (the count is always 1),
        and it goes live the moment that job gains `fetch-depth: 0` — which is
        one workflow edit away and would look like a stability regression.
        Rows carrying a `Structured` mirror are hashed on that mirror; rows
        without one are hashed on their prose, which for those dimensions IS
        the value.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$EnvironmentStatement,
        [Parameter(Mandatory)][int]$BoundSeconds
    )

    Set-StrictMode -Version Latest

    $excluded = @('concurrency')

    $parts = [System.Collections.Generic.List[string]]::new()
    $parts.Add("bound=$BoundSeconds")
    foreach ($row in ($EnvironmentStatement | Sort-Object Dimension)) {
        if ($excluded -contains [string]$row.Dimension) { continue }
        if ($row.PSObject.Properties.Match('Structured').Count -gt 0) {
            # `unobserved` is its own value, distinct from both polarities: a run
            # that could not see this axis is not comparable with one that could.
            $v = $row.Structured
            $rendered = if ($null -eq $v) { 'unobserved' } else { [string]$v }
            $parts.Add("$($row.Dimension)=structured:$rendered")
        }
        else {
            $parts.Add("$($row.Dimension)=$($row.Audit)")
        }
    }
    $text = $parts -join '|'
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($text)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $hash = $sha.ComputeHash($bytes) } finally { $sha.Dispose() }
    return (-join ($hash[0..5] | ForEach-Object { $_.ToString('x2') }))
}

function script:ConvertTo-CIGlobAuditCell {
    <#
    .SYNOPSIS
        Encode one value so a pipe table can carry it back out intact.
    .DESCRIPTION
        A filename is not a token: Linux permits `|`, a backtick, a backslash
        and even a newline in one, and every one of those either splits a cell,
        breaks the code span around it or ends the row. The previous shape
        answered that by NARROWING what it would read back, which turned a
        lawful name into a permanent reset of that suite's observation count —
        keyed on nothing but the shape of the name.

        So the cell is escaped rather than the name being restricted. Backslash
        first (or the escapes it introduces would be re-escaped), then the three
        characters a table row cannot survive.
    #>
    param([AllowNull()][object]$Value)

    $s = [string]$Value
    $s = $s -replace '\\', '\\'
    $s = $s -replace '\|', '\|'
    $s = $s -replace "`r", '\r'
    $s = $s -replace "`n", '\n'
    return $s
}

function script:ConvertFrom-CIGlobAuditCell {
    <#
    .SYNOPSIS
        Reverse `ConvertTo-CIGlobAuditCell`, leaving anything it did not write
        alone.
    .DESCRIPTION
        An UNRECOGNISED escape is not an escape. A history written before this
        encoding existed, or a name that genuinely contains a backslash, keeps
        both characters rather than losing one — the reader must never be a
        second, quieter way to corrupt a name.
    #>
    param([AllowNull()][string]$Text)

    $s = [string]$Text
    if ($s.IndexOf('\') -lt 0) { return $s }

    $sb = [System.Text.StringBuilder]::new()
    for ($i = 0; $i -lt $s.Length; $i++) {
        $c = $s[$i]
        if ($c -ne '\' -or $i -eq ($s.Length - 1)) { [void]$sb.Append($c); continue }
        $n = $s[$i + 1]
        switch ([string]$n) {
            '\' { [void]$sb.Append('\'); $i++ }
            '|' { [void]$sb.Append('|'); $i++ }
            'r' { [void]$sb.Append("`r"); $i++ }
            'n' { [void]$sb.Append("`n"); $i++ }
            default { [void]$sb.Append($c) }
        }
    }
    return $sb.ToString()
}

function script:Format-CIGlobAuditNameCell {
    <#
    .SYNOPSIS
        Render a suite name as an inline code span that its own backticks cannot
        close.
    .DESCRIPTION
        Same reasoning as the detail block's fence, one column narrower: a name
        containing a backtick ends a single-backtick span early and the rest of
        the row renders as prose. The fence is one longer than the longest run
        inside, and padded with a space when the content itself starts or ends
        with a backtick, which is what the inline-code rule requires.
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Encoded)

    $longest = 0
    foreach ($m in [regex]::Matches($Encoded, '`+')) { if ($m.Length -gt $longest) { $longest = $m.Length } }
    $fence = '`' * [Math]::Max(1, $longest + 1)
    $pad = if ($Encoded.StartsWith('`') -or $Encoded.EndsWith('`')) { ' ' } else { '' }
    return "$fence$pad$Encoded$pad$fence"
}

function script:Split-CIGlobAuditHistoryRow {
    <#
    .SYNOPSIS
        Split one history row into its decoded cells, honouring the escaping the
        writer applied.
    .DESCRIPTION
        A regex split on `(?<!\\)\|` gets this wrong for a cell ending in an
        escaped backslash — `a\\` followed by the real separator looks escaped
        to a lookbehind. Scanning consumes each escape pair whole instead, so
        the separator is never confused with an escaped one.
    .OUTPUTS
        [string[]] decoded, trimmed cells; the name cell also unfenced.
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Line)

    $t = $Line.Trim()
    if ($t.StartsWith('|')) { $t = $t.Substring(1) }

    $cells = [System.Collections.Generic.List[string]]::new()
    $cur = [System.Text.StringBuilder]::new()
    for ($i = 0; $i -lt $t.Length; $i++) {
        $c = $t[$i]
        if ($c -eq '\' -and $i -lt ($t.Length - 1)) {
            [void]$cur.Append($c)
            $i++
            [void]$cur.Append($t[$i])
            continue
        }
        if ($c -eq '|') { $cells.Add($cur.ToString()); $cur = [System.Text.StringBuilder]::new(); continue }
        [void]$cur.Append($c)
    }
    $cells.Add($cur.ToString())
    # The trailing separator every written row carries leaves one empty cell.
    if ($cells.Count -gt 0 -and [string]::IsNullOrWhiteSpace($cells[$cells.Count - 1])) { $cells.RemoveAt($cells.Count - 1) }

    $out = foreach ($cell in $cells) {
        $v = $cell.Trim()
        $m = [regex]::Match($v, '^(`+) ?(.*?) ?\1$')
        if ($m.Success) { $v = $m.Groups[2].Value }
        script:ConvertFrom-CIGlobAuditCell -Text $v
    }
    # NOT comma-wrapped. Every caller collects with `@(...)`, and the wrapper
    # would hand them a one-element array holding the cells rather than the
    # cells — which reads as "this row has one cell" and counts every row
    # malformed.
    return @($out)
}

function Update-CIGlobAuditHistory {
    <#
    .SYNOPSIS
        The observation history: how many comparable observations a suite's
        outcome goes back, in a place whose lifetime is not Actions retention.
    .DESCRIPTION
        Keyed on (suite content digest + instrument basis), NOT on file name.
        A name key reports "two observations" for a suite rewritten between
        them; an instrument-blind key pools a `did-not-complete` at one bound
        with a `passed` at four times that bound. Both are the pooling error
        that would let #1036 promote on a stability never observed and #1047
        read an instrument change as a regression.

        A changed basis RESETS the count to 1 rather than incrementing, because
        the count answers "how many COMPARABLE observations", and the previous
        basis is retained on the row so the change itself is visible — and it
        is retained ACROSS SUBSEQUENT RUNS, not just the one immediately after
        the change. Resetting it to `-` the moment the basis stops changing
        made R9's attribution recoverable for exactly one run and then erased
        it, which is worse than never recording it because the row still looks
        complete.

        THIS IS THE ONE STABLE-MARKERED SURFACE, so it carries what a consumer
        needs to join on rather than the minimum the count needs: the
        in-population flag (R2 permits an out-of-population row only where the
        record NAMES it as such, and #1036/#1047 read observation counts from
        here) and a PER-ROW commit (R6 requires the run AND the commit the
        observation was taken at — a single header commit is the latest run's,
        so it is wrong for every retained row).

        Format is a pipe table parsed back by this same function — a record
        that cannot be read back is not a history. Three halves of that are
        checked here.

        FIRST, THE SHAPE IS LOSSLESS FOR ANY LAWFUL NAME. Cells are escaped on
        write and decoded on read, and the name is fenced past its own
        backticks, so `|`, a backtick, a backslash and a newline all survive the
        round trip. The previous shape instead narrowed what it would read back,
        which reset a lawful suite's count to 1 on every run, permanently, while
        reporting `MalformedRows = 0` and disclosing nothing — a silent reset
        keyed on nothing but the shape of a name.

        SECOND, A ROW THAT STILL WILL NOT PARSE IS SKIPPED **AND COUNTED** AND
        DISCLOSED, rather than thrown on (this runs after the record comments
        are already persisted, so a hand-edited row must not take the process
        down). Rows are located by the suite table's own header rather than by a
        name pattern, which is what makes counting them possible without also
        counting the prose and the outcome-differences table around them.

        THIRD, the composed body is cap-checked before it is handed to a caller
        that would otherwise discover the limit at the API.
    .OUTPUTS
        [PSCustomObject] Body [string], Entries [object[]], MalformedRows [int],
        TableUnreadable [bool], OutcomeDifferences [object[]].
    #>
    param(
        [AllowEmptyString()][string]$ExistingBody = '',
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Rows,
        [Parameter(Mandatory)][string]$InstrumentBasis,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$Marker,
        [Parameter(Mandatory)][hashtable]$InPopulationByName,
        [string]$Commit = '',
        [int]$BodyCap = 0
    )

    Set-StrictMode -Version Latest
    if ($BodyCap -le 0) { $BodyCap = $script:CIGlobAuditBodyCap }

    $prior = @{}
    $malformed = 0
    # LOCATED BY THE TABLE, NOT BY THE SHAPE OF A NAME. Matching rows on a name
    # pattern meant a lawful filename the pattern could not express was WRITTEN
    # and never read back — its count restarting at 1 forever, silently, and the
    # `did not parse` disclosure never firing because a non-matching line was
    # skipped by `continue` without being counted. It also swept in the outcome-
    # differences table above, whose six-cell rows then counted as malformed.
    #
    # So the parser finds the suite table's own header and reads what follows it
    # until the table ends. Inside that region every row is a row: one that will
    # not parse is skipped AND counted AND disclosed, which is what the contract
    # below says happens.
    $inTable = $false
    $sawHeader = $false
    $sawAnyTableLine = $false
    foreach ($line in ($ExistingBody -split "`r?`n")) {
        $t = $line.Trim()
        if ($t.StartsWith('|')) { $sawAnyTableLine = $true }
        if (-not $inTable) {
            if ($t -eq $script:CIGlobAuditHistoryTableHeader) { $inTable = $true; $sawHeader = $true }
            continue
        }
        if (-not $t.StartsWith('|')) { break }
        if ($t -match '^\|[\s\-:|]+\|$') { continue }
        $cells = @(script:Split-CIGlobAuditHistoryRow -Line $t)
        if ($cells.Count -lt 8) { $malformed++; continue }
        if ([string]::IsNullOrWhiteSpace($cells[0])) { $malformed++; continue }
        $observations = 0
        if (-not [int]::TryParse($cells[3], [ref]$observations)) { $malformed++; continue }
        $prior[$cells[0]] = [PSCustomObject]@{
            Name         = $cells[0]
            InPopulation = ($cells[1] -eq 'in')
            Basis        = $cells[2]
            Observations = $observations
            LastState    = $cells[4]
            LastRun      = $cells[5]
            LastCommit   = $cells[6]
            PriorBasis   = $cells[7]
        }
    }
    # A body that carried table rows but no header this parser could find is not
    # an empty history — it is one that could not be read back, and every count
    # in it is about to restart at 1. That is disclosed rather than inferred by
    # a reader from counts that look suspiciously fresh.
    $tableUnreadable = ($sawAnyTableLine -and -not $sawHeader)

    $entries = [System.Collections.Generic.List[object]]::new()
    $differences = [System.Collections.Generic.List[object]]::new()
    foreach ($row in ($Rows | Sort-Object Name)) {
        $basis = "$($row.ContentDigest)+$InstrumentBasis"
        $count = 1
        $priorBasis = '-'
        if ($prior.ContainsKey($row.Name)) {
            $p = $prior[$row.Name]
            if ($p.Basis -eq $basis) {
                $count = $p.Observations + 1
                # Carry it forward. The change this column records happened at
                # some earlier run; the fact that the basis has been stable
                # since is not a reason to forget what it changed FROM.
                $priorBasis = $p.PriorBasis
            }
            else { $priorBasis = $p.Basis }

            # Claim 23's "behaviour once established" needs a surface, and this
            # is the only durable one: a suite whose outcome differs from its
            # last recorded observation is named, with both runs, so a reader
            # can see order- and instrument-sensitivity instead of inferring it
            # from two run-scoped comments by hand.
            if ([string]$p.LastState -ne [string]$row.State) {
                $differences.Add([PSCustomObject]@{
                        Name          = $row.Name
                        PreviousState = [string]$p.LastState
                        CurrentState  = [string]$row.State
                        PreviousRun   = [string]$p.LastRun
                        CurrentRun    = $RunId
                        Comparable    = ($p.Basis -eq $basis)
                    })
            }
        }
        $inPop = if ($InPopulationByName.ContainsKey([string]$row.Name)) { [bool]$InPopulationByName[[string]$row.Name] } else { [bool]$row.InPopulation }
        $entries.Add([PSCustomObject]@{
                Name         = $row.Name
                InPopulation = $inPop
                Basis        = $basis
                Observations = $count
                LastState    = $row.State
                LastRun      = $RunId
                LastCommit   = if ($Commit) { $Commit } else { '-' }
                PriorBasis   = $priorBasis
            })
    }

    # Suites absent from this run keep their rows: the history outlives the runs
    # that produced it, and a suite deleted from disk still has an observation
    # history a later reader may need. Their commit stays THEIR run's commit.
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($e in $entries) { [void]$seen.Add([string]$e.Name) }
    foreach ($name in ($prior.Keys | Sort-Object)) {
        if (-not $seen.Contains([string]$name)) { $entries.Add($prior[$name]) }
    }

    $sorted = @($entries | Sort-Object Name)

    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine($Marker)
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('# Full-glob CI audit — observation history')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine("``record_format_version: $script:CIGlobAuditRecordFormatVersion``. Column order is not a contract; this version is. The stable index of every run's record lives at ``$script:CIGlobAuditIndexMarker`` on this same issue.")
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine("Durable home for the observation count each suite's outcome goes back. Updated in place by every audit run; retention is the issue comment's, not the Actions run's.")
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine("**Comparability basis** = suite content digest + instrument basis. The instrument basis (``$InstrumentBasis``) hashes the bound and every dimension of the run's environment statement EXCEPT concurrency, which cannot change a suite's terminal state. A run at a different bound, execution model, image, or module version does NOT pool with an earlier one. A changed basis resets the count to 1 and the previous basis is kept in the last column until it is superseded.")
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('**`in-population`** distinguishes a suite the gate enumerates from an out-of-population control. A control accretes observations here like any other row and must never be read as a measurement of the corpus.')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('**`last commit`** is the commit of the run that produced THAT row''s last observation — not the latest run''s. A row retained from an earlier run keeps its own.')
    [void]$sb.AppendLine('')
    $commitClause = if ($Commit) { ' at commit `' + $Commit + '`' } else { '' }
    [void]$sb.AppendLine("Last updated by run ``$RunId``$commitClause.")
    [void]$sb.AppendLine('')
    if ($malformed -gt 0) {
        [void]$sb.AppendLine("> **$malformed prior row(s) did not parse and were dropped.** Their observation counts restart at 1. A row that cannot be read back is not history, and silently rebuilding around it would hide that.")
        [void]$sb.AppendLine('')
    }
    if ($tableUnreadable) {
        [void]$sb.AppendLine('> **The prior history body carried table rows but no readable suite-table header**, so no prior row was read back and every observation count below restarts at 1. This is a stated loss, not a fresh history.')
        [void]$sb.AppendLine('')
    }
    if ($differences.Count -gt 0) {
        [void]$sb.AppendLine('## Outcome differences from the previous observation')
        [void]$sb.AppendLine('')
        [void]$sb.AppendLine('Suites whose terminal state is not what this history last recorded. Where the basis is unchanged (`comparable: yes`), the two observations are of the same suite under the same instrument, so the difference is the suite''s own — order-dependence and flakiness both land here, and such a suite''s outcome is not offered as a settled measurement.')
        [void]$sb.AppendLine('')
        [void]$sb.AppendLine('| suite | previous state | previous run | current state | current run | comparable |')
        [void]$sb.AppendLine('| --- | --- | --- | --- | --- | --- |')
        foreach ($d in ($differences | Sort-Object Name)) {
            $dName = script:Format-CIGlobAuditNameCell -Encoded (script:ConvertTo-CIGlobAuditCell -Value $d.Name)
            [void]$sb.AppendLine("| $dName | $($d.PreviousState) | $($d.PreviousRun) | $($d.CurrentState) | $($d.CurrentRun) | $(if ($d.Comparable) { 'yes' } else { 'no — the instrument or the suite''s content changed' }) |")
        }
        [void]$sb.AppendLine('')
    }
    [void]$sb.AppendLine($script:CIGlobAuditHistoryTableHeader)
    [void]$sb.AppendLine('| --- | --- | --- | --- | --- | --- | --- | --- |')
    foreach ($e in $sorted) {
        $pop = if ($e.InPopulation) { 'in' } else { 'ctl' }
        # Every cell is escaped, not just the name: the reader decodes them all
        # symmetrically, and a basis or a run id is only as safe as the least
        # constrained thing a caller can put in it.
        $cells = @(
            (script:Format-CIGlobAuditNameCell -Encoded (script:ConvertTo-CIGlobAuditCell -Value $e.Name))
            $pop
            (script:ConvertTo-CIGlobAuditCell -Value $e.Basis)
            (script:ConvertTo-CIGlobAuditCell -Value $e.Observations)
            (script:ConvertTo-CIGlobAuditCell -Value $e.LastState)
            (script:ConvertTo-CIGlobAuditCell -Value $e.LastRun)
            (script:ConvertTo-CIGlobAuditCell -Value $e.LastCommit)
            (script:ConvertTo-CIGlobAuditCell -Value $e.PriorBasis)
        )
        [void]$sb.AppendLine('| ' + ($cells -join ' | ') + ' |')
    }

    $body = $sb.ToString().TrimEnd() + "`n"
    if (-not (Test-CIGlobAuditBodyFits -Body $body -Cap $BodyCap)) {
        # The history only grows — rows for deleted suites are retained
        # forever — so this is the same "discovering the cap mid-run" the
        # record composer refuses, arriving on the one surface that had no
        # check at all.
        throw ("ci-glob-audit: the observation history is $(Measure-CIGlobAuditBody -Body $body) codepoints, over the $BodyCap cap, at $(@($sorted).Count) suite row(s). " +
            'The history grows monotonically because rows for deleted suites are retained; it needs splitting or pruning before another run can persist it.')
    }

    return [PSCustomObject]@{
        Body               = $body
        Entries            = $sorted
        MalformedRows      = $malformed
        TableUnreadable    = $tableUnreadable
        OutcomeDifferences = @($differences | Sort-Object Name)
    }
}

#endregion

#region record composition

function Measure-CIGlobAuditBody {
    <#
    .SYNOPSIS
        Codepoints, not UTF-16 code units — the unit GitHub's cap is stated in.
    .DESCRIPTION
        [string]::Length counts UTF-16 code units, so a body full of astral
        characters measures nearly double its real size and a size guard built
        on it refuses lawful bodies. Emoji in a captured failure message are
        exactly the population that would hit this.

        RUNES, NOT TEXT ELEMENTS. `StringInfo::GetTextElementEnumerator` yields
        GRAPHEME CLUSTERS, and a grapheme is often several codepoints: a
        combining sequence measures 1 instead of 2, a ZWJ emoji 1 instead of 3.
        That under-measures in the fail-OPEN direction — an 80,000-codepoint
        body reported 40,000 and passed a 65,536 cap — so the pagination loop
        kept appending while measuring small and the write was rejected
        mid-run, which is precisely the failure the composer states it exists
        to make impossible. The previous test passed only because its exhibit
        was a lone astral character, the one input where grapheme, codepoint
        and "not a code unit" all agree.
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Body)
    if ([string]::IsNullOrEmpty($Body)) { return 0 }
    $count = 0
    foreach ($rune in $Body.EnumerateRunes()) { $count++ }
    return $count
}

function Test-CIGlobAuditBodyFits {
    <#
    .SYNOPSIS
        Does this body fit the cap, without paying for a codepoint walk on every
        candidate?
    .DESCRIPTION
        A string's codepoint count is never greater than its UTF-16 code-unit
        count, so a body whose `.Length` already fits the cap fits it in
        codepoints too, and the exact walk is only needed for the bodies that
        look too big. Without this, composing a record is quadratic in its own
        size — measured at nine seconds for one paginated record, which is the
        kind of cost that quietly gets a check deleted later.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Body,
        [Parameter(Mandatory)][int]$Cap
    )
    if ($Body.Length -le $Cap) { return $true }
    return ((Measure-CIGlobAuditBody -Body $Body) -le $Cap)
}

function New-CIGlobAuditRecordDocuments {
    <#
    .SYNOPSIS
        Compose the durable record: one summary document plus as many detail
        documents as the classifying detail actually needs.
    .DESCRIPTION
        WHY PAGINATION RATHER THAN TRUNCATION. The measured skeleton for 252
        suites is roughly 21,400 codepoints and the cap is 65,536, which leaves
        about 41,000 for detail. At sixty non-passed rows that is comfortable;
        at a hundred and ninety it is about 215 codepoints each, and nothing
        here is allowed to assume the failing population is small. Truncating
        detail to fit would satisfy the cap by breaking the criterion the
        detail exists for — so detail spills into further comments instead, and
        the summary says how many and where.

        The summary never depends on a retention-bounded surface. Full console
        output goes to an artifact as a convenience, and no criterion rests on
        it.

        WHY THERE IS AN INDEX DOCUMENT. Every other marker embeds the run id,
        so a consumer had no way to ask for "the current record": it had to
        enumerate every comment on an issue whose number is a workflow_dispatch
        input, regex run ids out of HTML comments, and order them. The index
        has a FIXED marker, is upserted, and carries one row per run — the
        addressable entry point the parent's 1->3 seam needs. It is also the
        only place that can see across runs, which is where R3(d)'s cross-bound
        comparison and the reconciliation of a re-attempt's surplus detail
        documents both live.
    .OUTPUTS
        [PSCustomObject[]] Marker, Body, Kind ('summary' | 'rows' | 'detail' |
        'index'), Index.
    #>
    param(
        [Parameter(Mandatory)][hashtable]$RunContext,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Rows,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$EnvironmentStatement,
        [Parameter(Mandatory)][object]$Population,
        [Parameter(Mandatory)][object]$GateAgreement,
        [Parameter(Mandatory)][object]$Reachability,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$ControlCheck,
        [AllowEmptyString()][string]$ExistingIndexBody = '',
        [int]$DetailCharCap = 0,
        [int]$BodyCap = 0
    )

    Set-StrictMode -Version Latest
    if ($BodyCap -le 0) { $BodyCap = $script:CIGlobAuditBodyCap }
    if ($DetailCharCap -le 0) { $DetailCharCap = $script:CIGlobAuditDetailCharCap }

    if (-not $RunContext.ContainsKey('RecordFormatVersion')) {
        throw ('ci-glob-audit: RunContext is missing RecordFormatVersion. Column order is not a contract, and a consumer ' +
            'that cannot tell a shape it understands from one it does not has to guess — which is the seam defect this key closes.')
    }
    $formatVersion = [string]$RunContext['RecordFormatVersion']

    $runId = [string]$RunContext['RunId']
    $summaryMarker = "<!-- ci-glob-audit-record-$runId -->"
    $detailMarkerFor = { param($i) "<!-- ci-glob-audit-detail-$runId-$i -->" }
    $rowsMarkerFor = { param($i) "<!-- ci-glob-audit-rows-$runId-$i -->" }

    $inPop = @($Rows | Where-Object { $_.InPopulation })
    $outPop = @($Rows | Where-Object { -not $_.InPopulation })
    $nonPassed = @($Rows | Where-Object { $_.State -ne 'passed' })

    # ---- detail documents first: the summary must state how many exist ----
    $detailDocs = [System.Collections.Generic.List[object]]::new()
    if ($nonPassed.Count -gt 0) {
        $pending = [System.Collections.Generic.List[string]]::new()
        foreach ($row in ($nonPassed | Sort-Object @{ E = { $_.InPopulation }; Descending = $true }, Name)) {
            $detail = [string]$row.Detail
            $emitted = $true
            $truncationNote = ''
            if ([string]::IsNullOrWhiteSpace($detail)) {
                # STATE-CONDITIONAL, because the previous single sentence
                # asserted a kill and a bound for every non-passed state. A
                # `failed / no-result-file` row is a child that COMPLETED and
                # was never bounded or killed; telling a reader it was killed
                # at a bound is two false statements in a durable record, and
                # it launders a crash into a hang narrative #1036 then reads.
                $emitted = $false
                $detail = if ([string]$row.State -eq 'did-not-complete') {
                    "**Nothing was emitted before the kill.** This suite produced no output and no result before the bound of $($row.BoundSeconds)s fired. This is an honest empty, not a discharge: #1036 cannot classify this row from the record."
                }
                else {
                    "**Nothing was captured for this row.** The suite's process COMPLETED — state ``$($row.State)``, reason ``$($row.Reason)``; it was neither bounded nor killed — and produced no structured failure message and no console output. This is an honest empty, not a discharge: #1036 cannot classify this row from the record."
                }
            }
            elseif ($detail.Length -gt $DetailCharCap) {
                # WHICH END IS KEPT DEPENDS ON WHAT THE DETAIL IS, and getting
                # this wrong in either direction breaks R5 on a different
                # population. Structured failure messages are joined head-first
                # and the FIRST one classifies `linux-red` against `never-ci`,
                # so a blanket tail-keep would degrade the 191-suite population
                # R5 exists for. A console tail was deliberately selected as a
                # TAIL because for a suite that never returned the last thing
                # it printed is where it stopped — and keeping its head, which
                # is what shipped, systematically discards exactly the stopping
                # point the tail selection existed to preserve.
                $keepEnd = script:Get-CIGlobAuditTruncationEnd -Row $row
                $detail = script:Get-CIGlobAuditSafeCut -Text $detail -MaxChars $DetailCharCap -Keep $keepEnd
                $truncationNote = if ($keepEnd -eq 'Tail') {
                    "`n...(the LAST $DetailCharCap characters of the captured console output are kept: for a suite that did not return, the stopping point is what classifies. Full output is in this run's artifact, which no criterion rests on.)"
                }
                else {
                    "`n...(the FIRST $DetailCharCap characters of the structured failure messages are kept: they are joined in order and the first is what classifies. Full output is in this run's artifact, which no criterion rests on.)"
                }
            }
            # Widen the fence past anything inside it. Captured suite output
            # routinely contains fenced code — this corpus asserts heavily on
            # Markdown documents and Pester embeds expected/actual text in its
            # messages — and a fixed three-backtick fence lets that text close
            # the block and render its own `###` heading at column zero,
            # indistinguishable from a genuine record row. Computed AFTER
            # truncation, because a cut can change the longest backtick run.
            $fence = script:Get-CIGlobAuditFence -Text $detail
            $scope = if ($row.InPopulation) { 'in-population' } else { "out-of-population control ($($row.ControlRole))" }
            $block = @(
                "### ``$($row.Name)`` — $($row.State) ($($row.Reason))",
                '',
                "$scope | elapsed $($row.ElapsedMs) ms | bound $($row.BoundSeconds)s | quarantine class $(script:Format-CIGlobAuditClass -Class $row.QuarantineClass -InPopulation $row.InPopulation) | content ``$($row.ContentDigest)``$(if (-not $emitted) { ' | **no output captured**' })",
                '',
                # Parenthesised deliberately: inside an array literal PowerShell
                # binds `,` TIGHTER than `+`, so `$fence + 'text', $detail` parses
                # as `$fence + ('text', $detail)` and silently emits the fence and
                # the language tag as two separate lines.
                ($fence + 'text'),
                ($detail + $truncationNote),
                $fence,
                '',
                ''
            ) -join "`n"
            $pending.Add($block)
        }

        $header = {
            param($i)
            @(
                (& $detailMarkerFor $i),
                '',
                "## Full-glob CI audit — classifying detail (part $i)",
                '',
                "``record_format_version: $formatVersion``. Run ``$runId``, commit ``$($RunContext['Commit'])``. Detail for every row whose state is not ``passed``, so a reader can decide ``linux-red`` versus ``never-ci`` without opening the suite. Part of the record whose summary is ``$summaryMarker``; the stable index of all runs is ``$script:CIGlobAuditIndexMarker``.",
                '',
                ''
            ) -join "`n"
        }

        $detailDocs = script:Split-CIGlobAuditDocument -Blocks $pending -Header $header `
            -MarkerFor $detailMarkerFor -Kind 'detail' -BodyCap $BodyCap
    }

    # ---- summary ----
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine($summaryMarker)
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('## Full-glob CI audit — record')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine("Every suite the per-PR gate enumerates on disk, run on Linux with the quarantine **not** applied. Produced by run ``$runId``; nothing here was hand-written.")
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine("The stable entry point for every run's record is ``$script:CIGlobAuditIndexMarker`` on this issue — a consumer should resolve that marker rather than enumerating run-keyed comments.")
    [void]$sb.AppendLine('')

    [void]$sb.AppendLine('### Run')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('| field | value |')
    [void]$sb.AppendLine('| --- | --- |')
    [void]$sb.AppendLine("| record_format_version | $formatVersion |")
    foreach ($k in @('RunId', 'RunUrl', 'RunAttempt', 'TriggerEvent', 'Commit', 'Ref', 'DefaultBranch', 'DefaultBranchTip', 'AncestryCheck', 'ContentDifferences', 'BoundSeconds', 'ShardCount', 'InstrumentBasis', 'StartedAt')) {
        if ($RunContext.ContainsKey($k)) { [void]$sb.AppendLine("| $k | $($RunContext[$k]) |") }
    }
    [void]$sb.AppendLine('')

    [void]$sb.AppendLine('### Population — the gate''s own enumeration, before the quarantine is subtracted')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine("- Derivation: ``$($Population.DerivationCommand)``")
    # Say what was actually asserted. `HasDrift` here is an ENFORCED
    # PRECONDITION, not an independent check: the run refuses to derive a
    # population at all from a drifted registry, so this value could not have
    # come out any other way and rendering it as evidence overstates it.
    [void]$sb.AppendLine("- Registry lint: this record exists only because the gate's own selection procedure reported **no drift** when the population was derived; the run refuses outright otherwise. The ``HasDrift`` value below is that enforced precondition restated, not a second, independent check — it could not read anything else here.")
    [void]$sb.AppendLine("- ``HasDrift`` (as enforced at derivation): **$($Population.HasDrift)**")
    [void]$sb.AppendLine("- Selected $($Population.SelectedCount); quarantine entries $($Population.QuarantinedCount) (unclassified $($Population.UnclassifiedCount)); stale $(@($Population.StaleQuarantine).Count).")
    [void]$sb.AppendLine("- Derived population **$(@($Population.Names).Count)**; in-population rows in this record **$($inPop.Count)**; out-of-population rows **$($outPop.Count)** (named below).")
    $missing = @($Population.Names | Where-Object { $n = $_; -not ($inPop | Where-Object { $_.Name -eq $n }) })
    $extra = @($inPop | Where-Object { $Population.Names -notcontains $_.Name } | ForEach-Object { $_.Name })
    [void]$sb.AppendLine("- One-to-one: missing $($missing.Count), unexpected $($extra.Count).$(if ($missing.Count) { ' MISSING: ' + ($missing -join ', ') })$(if ($extra.Count) { ' UNEXPECTED: ' + ($extra -join ', ') })")
    [void]$sb.AppendLine('')

    [void]$sb.AppendLine('### Terminal states')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('| state | in-population | out-of-population |')
    [void]$sb.AppendLine('| --- | --- | --- |')
    foreach ($state in $script:CIGlobAuditStates) {
        $a = @($inPop | Where-Object { $_.State -eq $state }).Count
        $b = @($outPop | Where-Object { $_.State -eq $state }).Count
        [void]$sb.AppendLine("| $state | $a | $b |")
    }
    [void]$sb.AppendLine('')

    [void]$sb.AppendLine('### Instrument self-check — the controls')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('Out-of-population suites that exist to exhibit each terminal state through the path the workflow actually runs. A control that did not produce its expected state means the classifier is wrong, not that the corpus changed.')
    [void]$sb.AppendLine('')
    if (@($ControlCheck).Count -eq 0) {
        [void]$sb.AppendLine('> **No controls were checked in this run.** The instrument therefore has no self-test behind it, and every terminal state below rests on the classifier being right rather than on having been demonstrated. Treat this record as unvalidated.')
    }
    else {
        [void]$sb.AppendLine('| control | expected | observed | ok |')
        [void]$sb.AppendLine('| --- | --- | --- | --- |')
        foreach ($c in $ControlCheck) {
            [void]$sb.AppendLine("| ``$($c.Name)`` | $($c.Expected) | $($c.Observed) | $(if ($c.Ok) { 'yes' } else { '**NO**' }) |")
        }
    }
    [void]$sb.AppendLine('')

    [void]$sb.AppendLine('### Reachability of every `did-not-complete` suite')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine("A suite that never returns is only safe while no documented way of running this repository's tests reaches it. Two such ways exist and their populations differ: the gate's selection, and a directory-level ``Invoke-Pester`` over the tests root, which the contributor instructions and the pull-request template prescribe and which is recursive and quarantine-blind.")
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine("- ``did-not-complete`` rows: $($Reachability.StalledCount)")
    [void]$sb.AppendLine("- reachable by the gate's selection: $(@($Reachability.GateReachable).Count)$(if (@($Reachability.GateReachable).Count) { ' — ' + ($Reachability.GateReachable -join ', ') })")
    [void]$sb.AppendLine("- located beneath the tests root: $(@($Reachability.TestsRootReachable).Count)$(if (@($Reachability.TestsRootReachable).Count) { ' — ' + ($Reachability.TestsRootReachable -join ', ') })")
    [void]$sb.AppendLine("- clean: **$($Reachability.Clean)**$(if (-not $Reachability.Clean) { ' — this is a defect to escalate to #993, not a case to excuse. This chunk has no lawful remedy of its own: reclassifying a suite is #1036''s. The gate''s job is bounded as of #1037, so a suite that never returns now ends the check rather than holding it to the platform ceiling — but a bound is containment, not a fix: the suite still fails, and the reachability defect below is still the thing to escalate.' })")
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('Both arms compare NORMALISED RELATIVE paths. The tests-root arm previously resolved the root to an absolute path and prefix-tested a relative row path, which is false for every row this pipeline can produce — so for the quarantined population, where the gate arm is also silent, both arms were dead at once and this line printed `clean: True` regardless.')
    [void]$sb.AppendLine('')

    # R3(d) needs BOTH sets, not both counts, and each run names its own in
    # full so two run-scoped records can be compared without re-running
    # anything. The index document below carries the per-run bound that makes
    # the comparison meaningful.
    $stalledRows = @($Rows | Where-Object { $_.State -eq 'did-not-complete' } | Sort-Object Name)
    [void]$sb.AppendLine("- the full ``did-not-complete`` set at bound $($RunContext['BoundSeconds'])s: $(if ($stalledRows.Count) { (($stalledRows | ForEach-Object { '`' + $_.Name + '`' }) -join ', ') } else { '(empty)' })")
    [void]$sb.AppendLine('')

    [void]$sb.AppendLine('### Environment — per dimension, this run against the gate')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('Audit-side values are read from this run, not from the workflow file. Where the gate states a constraint rather than a value, the constraint is what appears — a fabricated exact gate value would read cleaner and be untrue. This statement belongs to this run; it is not inherited.')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('`agrees` is three-valued. **unknown** means the gate states no value this run can compare against — it is not a soft yes, and it is not a disagreement. The `checked by` column says how each verdict was reached, so an assumed agreement cannot hide among computed ones.')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('| dimension | gate | this audit run | agrees | checked by |')
    [void]$sb.AppendLine('| --- | --- | --- | --- | --- |')
    foreach ($d in $EnvironmentStatement) {
        $basis = if ($d.PSObject.Properties.Match('Basis').Count -gt 0) { [string]$d.Basis } else { '(not stated)' }
        [void]$sb.AppendLine("| $($d.Dimension) | $($d.Gate) | $($d.Audit) | $(Format-CIGlobAuditAgreement -Agrees $d.Agrees) | $basis |")
    }
    [void]$sb.AppendLine('')
    $unknownDims = @($EnvironmentStatement | Where-Object { $null -eq $_.Agrees } | ForEach-Object { $_.Dimension })
    if ($unknownDims.Count -gt 0) {
        [void]$sb.AppendLine("**$($unknownDims.Count) dimension(s) carry no parity verdict**: $($unknownDims -join ', '). No parity is claimed on these and none may be read into them.")
        [void]$sb.AppendLine('')
    }
    foreach ($d in ($EnvironmentStatement | Where-Object { $_.Note })) {
        [void]$sb.AppendLine("- **$($d.Dimension)**: $($d.Note)")
    }
    [void]$sb.AppendLine('')

    [void]$sb.AppendLine('### Agreement with the gate where the two overlap')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine("Expectation: $($GateAgreement.GateExpectation). Overlap $($GateAgreement.OverlapCount) suites; agreed $($GateAgreement.AgreeCount); disagreed $(@($GateAgreement.Disagreements).Count).")
    [void]$sb.AppendLine('')
    if (@($GateAgreement.Disagreements).Count -gt 0) {
        [void]$sb.AppendLine('Each disagreement must be attributed to a divergence recorded above that this audit could **not** have avoided. A disagreement attributed to a divergence the audit could have matched and did not is a failure, not an account.')
        [void]$sb.AppendLine('')
        [void]$sb.AppendLine('| suite | audit state | reason |')
        [void]$sb.AppendLine('| --- | --- | --- |')
        foreach ($d in $GateAgreement.Disagreements) {
            [void]$sb.AppendLine("| ``$($d.Name)`` | $($d.State) | $($d.Reason) |")
        }
        [void]$sb.AppendLine('')
    }

    if ($outPop.Count -gt 0) {
        [void]$sb.AppendLine('### Out-of-population rows')
        [void]$sb.AppendLine('')
        [void]$sb.AppendLine('Named as such per the record contract: these are not suites the gate enumerates, and no consumer may read them as measurements of the corpus.')
        [void]$sb.AppendLine('')
        foreach ($r in ($outPop | Sort-Object Name)) {
            [void]$sb.AppendLine("- ``$($r.Name)`` ($($r.ControlRole)) — $($r.State), $($r.ElapsedMs) ms, at ``$($r.Path)``")
        }
        [void]$sb.AppendLine('')
    }

    $survivors = @($Rows | Where-Object { $_.ProcessSurvivedKill })
    $pipeHolders = @($Rows | Where-Object {
            $_.PSObject.Properties.Match('DescendantHeldOutput').Count -gt 0 -and $_.DescendantHeldOutput -and -not $_.ProcessSurvivedKill
        })
    $selfModified = @($Rows | Where-Object {
            $_.PSObject.Properties.Match('SelfModified').Count -gt 0 -and $_.SelfModified
        })
    [void]$sb.AppendLine('### Timing integrity')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('"The bound fired" and "the slot is free" are two facts. A killed suite whose process survived keeps consuming the runner and contaminates every later row''s duration while each row individually looks well-formed.')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('Survival is decided on two signals, because the direct child''s `HasExited` alone cannot see a grandchild that outlived the tree kill: the child still being alive, and — the one that catches an orphan — the redirected output pipe still being held open after the child is gone.')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine("- bounded suites whose process survived the kill: **$($survivors.Count)**$(if ($survivors.Count) { ' — ' + (($survivors | ForEach-Object { $_.Name }) -join ', ') + '. The durations in this record are NOT offered as a timing measurement.' })")
    [void]$sb.AppendLine("- suites that exited while a descendant still held their output pipe: **$($pipeHolders.Count)**$(if ($pipeHolders.Count) { ' — ' + (($pipeHolders | ForEach-Object { $_.Name }) -join ', ') + '. Something these suites started is still running on that runner; later rows'' durations on the same job are contaminated, AND each such row''s OWN total absorbs up to the kill grace of drain waiting on that pipe. Those two are different statements and both hold: see the `drain ms` and `suite ms` columns for how much of each total is which.' })")
    [void]$sb.AppendLine('- every row''s `ms` includes the drain the harness spends reading after the child exited or was killed, so the per-suite table carries `drain ms` and `suite ms` alongside it. On an ordinary row the drain is one poll interval; on a row whose descendant held the pipe it is bounded only by the kill grace. A consumer sizing shards wants `suite ms`.')
    [void]$sb.AppendLine("- suites whose own file changed while they ran: **$($selfModified.Count)**$(if ($selfModified.Count) { ' — ' + (($selfModified | ForEach-Object { $_.Name }) -join ', ') + '. The digest recorded is the content that was EXECUTED, sampled before the run.' })")
    [void]$sb.AppendLine('')
    # CONDITIONAL, because this used to be printed unconditionally as fixed
    # prose computed from nothing — while the same document, five lines
    # earlier, could say the durations were not offered as a timing
    # measurement. Two contradictory statements in one body, and R7's
    # interpretability clause discharged by a declaration.
    # THE ROW COUNT IS PART OF THE GUARD, not a detail of it. Both counts above
    # are filters over $Rows, so an empty row set satisfies "nothing survived its
    # kill" and "nothing held a pipe" VACUOUSLY — and the zero-partial path,
    # which exists so a run that measured nothing still produces a record, is
    # exactly the path that reaches here with no rows. Without this clause that
    # record asserts non-contention about measurements it never took, which is
    # the same declaration-instead-of-observation defect this block was written
    # to remove, re-entering through the door the fix for it opened.
    if (@($Rows).Count -gt 0 -and $survivors.Count -eq 0 -and $pipeHolders.Count -eq 0) {
        $concurrencyRow = @($EnvironmentStatement | Where-Object { $_.Dimension -eq 'concurrency' }) | Select-Object -First 1
        $concurrencyValue = if ($concurrencyRow) { [string]$concurrencyRow.Audit } else { '(concurrency not stated)' }
        [void]$sb.AppendLine("- Non-contention rests on the observed concurrency statement and on nothing surviving its kill, both of which hold for this run: $concurrencyValue")
    }
    elseif (@($Rows).Count -eq 0) {
        [void]$sb.AppendLine('- **No non-contention claim is made for this run, because this run measured nothing.** No suite produced a row, so there is no duration here to be contended or uncontended. This is not a clean result; it is an absent one.')
    }
    else {
        [void]$sb.AppendLine('- **No non-contention claim is made for this run.** Something outlived its bound or its parent, so an unknown amount of work overlapped the measurements. A consumer sizing the gate''s fan-out must not treat this run''s durations as a distribution.')
    }
    [void]$sb.AppendLine('')

    # ---- R3(d): the cross-bound comparison, from the stable index ----
    $priorIndexRows = script:Read-CIGlobAuditIndexRows -Body $ExistingIndexBody
    $otherBoundRows = @($priorIndexRows | Where-Object { [string]$_.Run -ne $runId -and [string]$_.Bound -ne [string]$RunContext['BoundSeconds'] })
    [void]$sb.AppendLine('### Cross-bound comparison — is the bound doing the classifying?')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('A bound low enough to sweep slow suites into `did-not-complete` hands the downstream chunk a distribution consisting mostly of the bound value. The check is whether that class materially shrinks at a materially larger bound; if it does, the bound was classifying.')
    [void]$sb.AppendLine('')
    if ($otherBoundRows.Count -eq 0) {
        [void]$sb.AppendLine("- No earlier run at a different bound is recorded in the index yet, so **this comparison is not yet available**. This run's own set is named above; the comparison becomes available once a second run at a materially different bound has posted. Not a discharge — an outstanding obligation.")
    }
    else {
        [void]$sb.AppendLine('| run | bound | `did-not-complete` | this run | delta |')
        [void]$sb.AppendLine('| --- | ---: | ---: | ---: | ---: |')
        foreach ($p in $otherBoundRows) {
            $priorStalled = 0
            [void][int]::TryParse([string]$p.DidNotComplete, [ref]$priorStalled)
            [void]$sb.AppendLine("| ``$($p.Run)`` | $($p.Bound) | $priorStalled | $($stalledRows.Count) | $($stalledRows.Count - $priorStalled) |")
        }
        [void]$sb.AppendLine('')
        [void]$sb.AppendLine('Each run''s record names its own `did-not-complete` set in full, so both sets are recoverable from the two comments the index points at.')
    }
    [void]$sb.AppendLine('')

    [void]$sb.AppendLine('### Per-suite rows')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine("``ms`` is total wall clock the harness held the slot for this suite, and it INCLUDES the bounded drain the harness spends reading after the child has already exited or been killed. ``drain ms`` is how much of the total that drain was, and ``suite ms`` is the remainder — the suite's own cost, and the figure to size the gate's fan-out from, and the one #1037's width was derived over. A row that exited in a second while a descendant held its output pipe reads ~11,000 ms total and ~1,000 ms suite; reading the total as the suite's cost is an order-of-magnitude error on exactly the rows the timing-integrity statement names. A ``-`` in either column means the row came from a shard partial that did not carry the figure — not that it measured zero. Read all of it against the timing-integrity statement above rather than as an unconditional measurement.")
    [void]$sb.AppendLine('')
    if ($detailDocs.Count -gt 0) {
        $lastDetailMarker = if ($detailDocs.Count -gt 1) { ' .. `' + (& $detailMarkerFor $detailDocs.Count) + '`' } else { '' }
        [void]$sb.AppendLine("Classifying detail for every non-``passed`` row is in $($detailDocs.Count) companion comment(s) on this issue, markers ``$(& $detailMarkerFor 1)``$lastDetailMarker.")
        [void]$sb.AppendLine('')
    }

    # ---- the per-suite table paginates, exactly as detail does ----
    # It did not, and the summary measured 41,111 codepoints of a 65,536 cap at
    # today's 253 suites — 1.7x the planning estimate, overflowing at roughly
    # 400. The throw on overflow precedes every persist call with no try/catch
    # above it, so a corpus-growth threshold turned a red-by-construction audit
    # into a NO-RECORD audit: not the summary, not the detail documents, not
    # the observation history. Fixing the codepoint measure (which had been
    # under-counting) makes every body measure larger, so this had to land in
    # the same change or the first near-cap record would hit that throw.
    $tableHeader = @(
        '| suite | state | reason | ms | drain ms | suite ms | bound | class | skipped | executed | digest | pop |',
        '| --- | --- | --- | ---: | ---: | ---: | ---: | --- | ---: | ---: | --- | --- |'
    ) -join "`n"
    $tableRows = [System.Collections.Generic.List[string]]::new()
    foreach ($r in ($Rows | Sort-Object Name)) {
        $pop = if ($r.InPopulation) { 'in' } else { 'ctl' }
        $rowDrain = script:Get-CIGlobAuditRowDrainMs -Row $r
        $drainCell = if ($null -eq $rowDrain) { '-' } else { [string]$rowDrain }
        $suiteCell = if ($null -eq $rowDrain) { '-' } else { [string]([int]$r.ElapsedMs - $rowDrain) }
        $tableRows.Add("| ``$($r.Name)`` | $($r.State) | $($r.Reason) | $($r.ElapsedMs) | $drainCell | $suiteCell | $($r.BoundSeconds) | $(script:Format-CIGlobAuditClass -Class $r.QuarantineClass -InPopulation $r.InPopulation) | $($r.Skipped) | $($r.Executed) | $($r.ContentDigest) | $pop |")
    }

    $summaryHead = $sb.ToString()
    $inlineTable = $tableHeader + "`n" + (($tableRows -join "`n")) + "`n"
    $inlineCandidate = ($summaryHead + $inlineTable).TrimEnd() + "`n"

    $rowsDocs = [System.Collections.Generic.List[object]]::new()
    $summary = $inlineCandidate
    if (-not (Test-CIGlobAuditBodyFits -Body $inlineCandidate -Cap $BodyCap)) {
        $rowsHeaderFor = {
            param($i)
            @(
                (& $rowsMarkerFor $i),
                '',
                "## Full-glob CI audit — per-suite rows (part $i)",
                '',
                "``record_format_version: $formatVersion``. Run ``$runId``, commit ``$($RunContext['Commit'])``. The per-suite table for the record whose summary is ``$summaryMarker``; split out because it no longer fits alongside the summary. The stable index of all runs is ``$script:CIGlobAuditIndexMarker``.",
                '',
                $tableHeader,
                ''
            ) -join "`n"
        }
        $rowsDocs = script:Split-CIGlobAuditDocument -Blocks @($tableRows | ForEach-Object { $_ + "`n" }) `
            -Header $rowsHeaderFor -MarkerFor $rowsMarkerFor -Kind 'rows' -BodyCap $BodyCap

        $lastRowsMarker = if ($rowsDocs.Count -gt 1) { ' .. `' + (& $rowsMarkerFor $rowsDocs.Count) + '`' } else { '' }
        $pointer = @(
            "The per-suite table did not fit alongside this summary and is in $($rowsDocs.Count) companion comment(s) on this issue, markers ``$(& $rowsMarkerFor 1)``$lastRowsMarker. Every row of the population is there; none was dropped to make the summary fit.",
            ''
        ) -join "`n"
        $summary = ($summaryHead + $pointer).TrimEnd() + "`n"
    }

    if (-not (Test-CIGlobAuditBodyFits -Body $summary -Cap $BodyCap)) {
        $summarySize = Measure-CIGlobAuditBody -Body $summary
        # Only now. The per-suite table has already been paginated out, so this
        # is the genuinely irreducible case — the summary's own prose no longer
        # fits — and refusing is right: a partial record read as whole is worse
        # than a loud stop, and this cannot be reached by corpus growth alone.
        throw ("ci-glob-audit: composed summary is $summarySize codepoints, over the $BodyCap cap, WITH the per-suite table already " +
            'paginated into separate documents. What no longer fits is the summary''s own narrative sections; the record shape needs splitting before this run can persist.')
    }

    $docs = [System.Collections.Generic.List[object]]::new()
    $docs.Add([PSCustomObject]@{ Marker = $summaryMarker; Body = $summary; Kind = 'summary'; Index = 0 })
    foreach ($d in $rowsDocs) { $docs.Add($d) }
    foreach ($d in $detailDocs) { $docs.Add($d) }

    $indexDoc = script:New-CIGlobAuditIndexDocument -ExistingBody $ExistingIndexBody -RunContext $RunContext `
        -Rows $Rows -SummaryMarker $summaryMarker `
        -RowsMarkers @($rowsDocs | ForEach-Object { $_.Marker }) `
        -DetailMarkers @($detailDocs | ForEach-Object { $_.Marker }) `
        -FormatVersion $formatVersion -BodyCap $BodyCap
    $docs.Add($indexDoc)

    foreach ($d in $docs) {
        if (-not (Test-CIGlobAuditBodyFits -Body $d.Body -Cap $BodyCap)) {
            throw "ci-glob-audit: composed document '$($d.Marker)' is $(Measure-CIGlobAuditBody -Body $d.Body) codepoints, over the $BodyCap cap."
        }
    }
    return , @($docs)
}

function script:Get-CIGlobAuditRowDrainMs {
    <#
    .SYNOPSIS
        How much of this row's elapsed time was post-exit drain, or `$null` if
        the row does not carry the figure.
    .DESCRIPTION
        Three-valued on purpose, exactly as the parity table is: a row from a
        shard partial written before this field existed did not measure zero
        drain, it measured nothing, and rendering that as `0` is a number the
        record never observed.
    #>
    param([Parameter(Mandatory)][object]$Row)

    if ($Row.PSObject.Properties.Match('DrainMs').Count -eq 0) { return $null }
    $v = $Row.DrainMs
    if ($null -eq $v) { return $null }
    return [int]$v
}

function script:Get-CIGlobAuditTruncationEnd {
    <#
    .SYNOPSIS
        Which end of this row's detail must survive truncation.
    .DESCRIPTION
        Three tiers, most authoritative first, because a row can reach the
        composer from the shipped path (which stamps its provenance), from a
        partial JSON written by an older shard, or hand-built. Never infer from
        state alone where provenance exists: a `failed / no-result-file` row's
        detail IS a console tail, so a state-only rule gets that population
        backwards.
    #>
    param([Parameter(Mandatory)][object]$Row)

    if ($Row.PSObject.Properties.Match('DetailTruncateFrom').Count -gt 0 -and $Row.DetailTruncateFrom) {
        $v = [string]$Row.DetailTruncateFrom
        if ($v -eq 'Head' -or $v -eq 'Tail') { return $v }
    }
    if ($Row.PSObject.Properties.Match('DetailSource').Count -gt 0 -and [string]$Row.DetailSource -eq 'console-tail') { return 'Tail' }
    if ([string]$Row.State -eq 'did-not-complete') { return 'Tail' }
    return 'Head'
}

function script:Split-CIGlobAuditDocument {
    <#
    .SYNOPSIS
        Paginate a list of blocks into as many capped documents as they need.
    .DESCRIPTION
        Shared by the detail documents and the per-suite table, so the two
        cannot drift apart in their handling of the cap.

        THE RESEEDED DOCUMENT IS RE-TESTED. The previous loop appended a block
        unconditionally after flushing and re-seeding, so a single block larger
        than the cap was written into an empty document and caught only by the
        final per-document check — which throws, losing the whole record. That
        was unreachable at the shipped detail cap, but the cap is a parameter,
        which made the invariant both undocumented and one argument away.

        AND SO IS THE FIRST DOCUMENT. The re-test above was reached only after a
        flush, so it could not fire for the FIRST block — the very case its own
        text describes, since a lone oversized block is oversized whether or not
        anything preceded it. At `BodyCap 20000 / DetailCharCap 30000` one row
        fell through to the generic per-document throw while the named guard
        reported nothing; two rows fired it. A test written at three rows cannot
        tell those apart, so the n=1 case is pinned.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Blocks,
        [Parameter(Mandatory)][scriptblock]$Header,
        [Parameter(Mandatory)][scriptblock]$MarkerFor,
        [Parameter(Mandatory)][string]$Kind,
        [Parameter(Mandatory)][int]$BodyCap
    )

    $docs = [System.Collections.Generic.List[object]]::new()
    $index = 1
    $seed = (& $Header $index)
    $current = [System.Text.StringBuilder]::new()
    [void]$current.Append($seed)

    foreach ($block in $Blocks) {
        $candidate = $current.ToString() + $block
        if (-not (Test-CIGlobAuditBodyFits -Body $candidate -Cap $BodyCap)) {
            # Flush only if there is something to flush. An empty (seed-only)
            # document has nothing to page out, and paging it would emit a
            # header carrying no blocks.
            if ($current.ToString() -ne $seed) {
                $docs.Add([PSCustomObject]@{ Marker = (& $MarkerFor $index); Body = $current.ToString().TrimEnd() + "`n"; Kind = $Kind; Index = $index })
                $index++
                $seed = (& $Header $index)
                $current = [System.Text.StringBuilder]::new()
                [void]$current.Append($seed)
            }
            # Re-test against a FRESH document — whether this is the first block
            # or one that just forced a flush. If one block cannot fit on its
            # own, no amount of further pagination will help and the caller must
            # hear about it here, named, rather than through a generic over-cap
            # throw after everything else has been composed.
            if (-not (Test-CIGlobAuditBodyFits -Body ($seed + $block) -Cap $BodyCap)) {
                throw ("ci-glob-audit: a fresh $Kind document does not fit the $BodyCap-codepoint cap even carrying a single block — " +
                    "header $(Measure-CIGlobAuditBody -Body $seed) codepoints plus block $(Measure-CIGlobAuditBody -Body $block) codepoints. " +
                    'Pagination cannot resolve this; the per-block budget is too large for the cap.')
            }
        }
        [void]$current.Append($block)
    }
    $docs.Add([PSCustomObject]@{ Marker = (& $MarkerFor $index); Body = $current.ToString().TrimEnd() + "`n"; Kind = $Kind; Index = $index })
    return , @($docs)
}

function script:Read-CIGlobAuditIndexRows {
    <#
    .SYNOPSIS
        Parse an existing index body back into its rows.
    .DESCRIPTION
        The index is upserted, so the composer must be able to read its own
        prior output. Tolerant: a row it cannot parse is skipped rather than
        thrown on, because this runs before persistence and losing the whole
        record to one hand-edited line is the worse failure.
    #>
    param([AllowEmptyString()][AllowNull()][string]$Body)

    $rows = [System.Collections.Generic.List[object]]::new()
    if ([string]::IsNullOrWhiteSpace($Body)) { return , @($rows) }

    foreach ($line in ($Body -split "`r?`n")) {
        if ($line -notmatch '^\|\s*`([^`|]+)`\s*\|') { continue }
        $cells = @($line.Trim() -replace '^\|', '' -replace '\|$', '' -split '\|' | ForEach-Object { $_.Trim() })
        if ($cells.Count -lt 12) { continue }
        $run = $cells[0].Trim('`').Trim()
        if ($run -eq 'run' -or $run -match '^-+$') { continue }
        $rows.Add([PSCustomObject]@{
                Run             = $run
                RunUrl          = $cells[1]
                Commit          = $cells[2].Trim('`').Trim()
                Bound           = $cells[3]
                Shards          = $cells[4]
                Passed          = $cells[5]
                Failed          = $cells[6]
                DidNotComplete  = $cells[7]
                ExecutedNoTests = $cells[8]
                RecordMarker    = $cells[9]
                RowsMarkers     = $cells[10]
                DetailMarkers   = $cells[11]
                Notes           = if ($cells.Count -ge 13) { $cells[12] } else { '-' }
            })
    }
    return , @($rows)
}

function script:New-CIGlobAuditIndexDocument {
    <#
    .SYNOPSIS
        The stable pointer: one row per run, newest first, under a marker that
        carries no run id.
    .DESCRIPTION
        Upserted rather than posted, and merged with whatever the caller read
        back, so a consumer resolves ONE marker to reach any run's record
        instead of enumerating an issue's comments and regexing run ids out of
        HTML comments.

        It also reconciles a re-attempt. Detail markers are indexed per part,
        so a re-run of the same run id that produces two parts where the first
        produced three leaves `...-3` on the issue, unreferenced, while the
        summary advertises parts 1..2. Nothing here can delete a comment — that
        is the caller's — but the surplus markers are NAMED in this run's row,
        so an orphan is visible rather than silently authoritative-looking.

        The index only grows, so it is trimmed from the OLDEST end when it
        approaches the cap rather than throwing. Losing the ability to address
        the newest record because the oldest runs are still listed would invert
        the whole point of the document.
    #>
    param(
        [AllowEmptyString()][string]$ExistingBody = '',
        [Parameter(Mandatory)][hashtable]$RunContext,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Rows,
        [Parameter(Mandatory)][string]$SummaryMarker,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$RowsMarkers,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$DetailMarkers,
        [Parameter(Mandatory)][string]$FormatVersion,
        [Parameter(Mandatory)][int]$BodyCap
    )

    $runId = [string]$RunContext['RunId']
    # No @() wrapper: the helper already comma-wraps, so re-wrapping an empty
    # result yields a one-element array holding an empty array — which then
    # flows into a property access as a non-row object.
    $prior = script:Read-CIGlobAuditIndexRows -Body $ExistingBody

    $counts = @{}
    foreach ($state in $script:CIGlobAuditStates) {
        $counts[$state] = @($Rows | Where-Object { $_.State -eq $state }).Count
    }

    $detailCell = if ($DetailMarkers.Count) { ($DetailMarkers -join ', ') } else { '(none)' }
    $rowsCell = if ($RowsMarkers.Count) { ($RowsMarkers -join ', ') } else { '(inline in the summary)' }

    $notes = '-'
    $selfRow = @($prior | Where-Object { [string]$_.Run -eq $runId }) | Select-Object -First 1
    if ($selfRow) {
        $priorDetail = @([string]$selfRow.DetailMarkers -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -and $_ -ne '(none)' })
        $priorRows = @([string]$selfRow.RowsMarkers -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -and $_ -notmatch '^\(' })
        $orphans = @(@($priorDetail + $priorRows) | Where-Object { $DetailMarkers -notcontains $_ -and $RowsMarkers -notcontains $_ })
        if ($orphans.Count -gt 0) {
            $notes = "re-attempt of this run id produced fewer documents; **$($orphans.Count) superseded comment(s) are orphaned on this issue and must be ignored or deleted**: $($orphans -join ', ')"
        }
    }

    $newRow = [PSCustomObject]@{
        Run             = $runId
        RunUrl          = [string]$RunContext['RunUrl']
        Commit          = [string]$RunContext['Commit']
        Bound           = [string]$RunContext['BoundSeconds']
        Shards          = [string]$RunContext['ShardCount']
        Passed          = [string]$counts['passed']
        Failed          = [string]$counts['failed']
        DidNotComplete  = [string]$counts['did-not-complete']
        ExecutedNoTests = [string]$counts['executed-no-tests']
        RecordMarker    = $SummaryMarker
        RowsMarkers     = $rowsCell
        DetailMarkers   = $detailCell
        Notes           = $notes
    }

    $merged = [System.Collections.Generic.List[object]]::new()
    $merged.Add($newRow)
    foreach ($p in $prior) { if ([string]$p.Run -ne $runId) { $merged.Add($p) } }

    $render = {
        param($rowsToRender, $trimmed)
        $b = [System.Text.StringBuilder]::new()
        [void]$b.AppendLine($script:CIGlobAuditIndexMarker)
        [void]$b.AppendLine('')
        [void]$b.AppendLine('# Full-glob CI audit — index of runs')
        [void]$b.AppendLine('')
        [void]$b.AppendLine("``record_format_version: $FormatVersion``. **This marker is stable and carries no run id.** Resolve it to find any run's record; every other marker in this family embeds a run id and cannot be addressed without enumerating the issue's comments.")
        [void]$b.AppendLine('')
        [void]$b.AppendLine('Newest first. `bound` is what makes the cross-bound comparison possible: two runs at materially different bounds are what tells a reader whether the bound was classifying rather than the suites.')
        [void]$b.AppendLine('')
        [void]$b.AppendLine("The observation history lives at ``<!-- ci-glob-audit-history -->`` on this same issue and is keyed per suite rather than per run.")
        [void]$b.AppendLine('')
        if ($trimmed -gt 0) {
            [void]$b.AppendLine("> **$trimmed oldest run row(s) were dropped** to keep this document inside the $BodyCap-codepoint cap. Their record comments still exist on this issue; only their index entry is gone.")
            [void]$b.AppendLine('')
        }
        [void]$b.AppendLine('| run | run url | commit | bound | shards | passed | failed | did-not-complete | executed-no-tests | record | rows | detail | notes |')
        [void]$b.AppendLine('| --- | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | --- | --- | --- | --- |')
        foreach ($r in $rowsToRender) {
            [void]$b.AppendLine("| ``$($r.Run)`` | $($r.RunUrl) | ``$($r.Commit)`` | $($r.Bound) | $($r.Shards) | $($r.Passed) | $($r.Failed) | $($r.DidNotComplete) | $($r.ExecutedNoTests) | $($r.RecordMarker) | $($r.RowsMarkers) | $($r.DetailMarkers) | $($r.Notes) |")
        }
        return $b.ToString().TrimEnd() + "`n"
    }

    $trimmed = 0
    $body = & $render $merged $trimmed
    while (-not (Test-CIGlobAuditBodyFits -Body $body -Cap $BodyCap) -and $merged.Count -gt 1) {
        $merged.RemoveAt($merged.Count - 1)
        $trimmed++
        $body = & $render $merged $trimmed
    }

    return [PSCustomObject]@{ Marker = $script:CIGlobAuditIndexMarker; Body = $body; Kind = 'index'; Index = 0 }
}

function script:Format-CIGlobAuditClass {
    param($Class, [bool]$InPopulation = $true)
    # An out-of-population control has no quarantine class because it is not in
    # the registry's world at all. Rendering that as "none — selected" would
    # tell a reader the gate selects it, which is the opposite of true.
    if (-not $InPopulation) { return 'n/a (not in the registry)' }
    if ($null -eq $Class -or [string]::IsNullOrWhiteSpace([string]$Class)) { return '(none — selected)' }
    return [string]$Class
}

function Test-CIGlobAuditControlExpectation {
    <#
    .SYNOPSIS
        Did each control produce the terminal state it exists to exhibit?
    .DESCRIPTION
        The controls are the instrument's self-test. A run where the
        never-returning control did not land in `did-not-complete`, or the
        all-skipped control read as `passed`, is a broken classifier reporting
        confidently — which is the failure mode the four-state distinction
        exists to prevent, arriving through the back door.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Rows,
        [Parameter(Mandatory)][hashtable]$Expectations
    )

    Set-StrictMode -Version Latest

    $out = [System.Collections.Generic.List[object]]::new()
    foreach ($name in ($Expectations.Keys | Sort-Object)) {
        $row = @($Rows | Where-Object { $_.Name -eq $name }) | Select-Object -First 1
        $observed = if ($row) { "$($row.State) ($($row.Reason))" } else { '(no row)' }
        $ok = ($null -ne $row) -and ($row.State -eq $Expectations[$name])
        $out.Add([PSCustomObject]@{ Name = $name; Expected = $Expectations[$name]; Observed = $observed; Ok = $ok })
    }
    return , @($out)
}

#endregion
