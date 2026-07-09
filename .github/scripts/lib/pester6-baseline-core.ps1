#Requires -Version 7.0
<#!
.SYNOPSIS
    Pure-logic library for the version-pinned, per-test-identity Pester baseline
    capture tool (issue #818 / s2).

.DESCRIPTION
    Fixes the gap the plan's adversarial review proved in `run-pester-sharded.ps1`
    (see .github/scripts/lib/pester-sharded-core.ps1): each shard spawns a fresh pwsh process with
    no Pester version selector (auto-resolves whatever is newest-installed), and it
    emits only per-file {File,Passed,Failed,TotalCount} aggregates — no test
    identity, no failure reason. That is too coarse for AC1's delta-neutral gate,
    which must tell a genuine 6.x regression apart from a pre-existing (#566) or
    same-test reason-changed failure.

    This library captures, per test, across the WHOLE suite in one Invoke-Pester
    pass: the fully-qualified Describe > Context > It identity (prefixed with the
    path of the file relative to TestsPath, since identity is not guaranteed
    globally unique across files), pass/fail/skip/not-run status, and the failure message
    when failed. A discovery-time throw in one file (a `throw` at file scope, a
    parse error, etc.) is recorded as a distinct `discovery-error` record rather
    than silently collapsing or crashing the run — Pester already isolates
    discovery failures per-container, so one broken file does not prevent the
    rest of the suite from running; this library surfaces that isolation as an
    identifiable record instead of leaving it implicit.

    The Pester version is never auto-resolved. -RequiredVersion is mandatory and
    is honored via `Import-Module Pester -RequiredVersion <version> -Force` inside
    an isolated child pwsh process (the current session may already have a
    different Pester version imported), so the captured baseline is reproducible
    and labeled with the exact version that produced it.

    Exposes:
      - Get-Pester6BaselineLauncherScript : build the child-process launcher script content
      - Invoke-Pester6BaselineCapture     : orchestrate the isolated run and return the parsed result
#>

# ---------------------------------------------------------------------------
# Internal: build the child-process launcher script content.
# The launcher is written to a temp .ps1 file so paths do not require complex
# inline string escaping when passed to pwsh (same pattern as the
# Get-ShardLauncherScript function in .github/scripts/lib/pester-sharded-core.ps1).
# ---------------------------------------------------------------------------
function Get-Pester6BaselineLauncherScript {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$TestsPath,

        [Parameter(Mandatory)]
        [string]$RequiredVersion,

        [Parameter(Mandatory)]
        [string]$ResultFilePath
    )

    # Single-quote literals in a PowerShell here-string are safe; the caller's
    # paths/version are embedded via @"..."@ substitution below.
    return @"
#Requires -Version 7.0
`$ErrorActionPreference = 'Stop'
try {
    Import-Module Pester -RequiredVersion '$RequiredVersion' -Force -ErrorAction Stop

    `$importedVersion = (Get-Module -Name Pester | Select-Object -First 1).Version.ToString()

    `$cfg = New-PesterConfiguration
    `$cfg.Run.Path = @('$($TestsPath -replace "'", "''")')
    `$cfg.Run.PassThru = `$true
    `$cfg.Run.Exit = `$false
    `$cfg.Output.Verbosity = 'None'

    `$r = Invoke-Pester -Configuration `$cfg

    `$testsPathFull = (Resolve-Path -LiteralPath '$($TestsPath -replace "'", "''")').Path

    `$records = [System.Collections.Generic.List[object]]::new()

    # `$t.Path is UNEXPANDED: data-driven -ForEach instances of one templated
    # Describe/Context/It name (e.g. 'handles case <n>') all share the same
    # literal '<n>' token, collapsing distinct instances onto one identity.
    # `$t.ExpandedPath is Pester's own per-instance-expanded dot-joined path
    # string (confirmed via live probe against Pester 6.0.0 and 5.7.1 test
    # result objects: it expands BOTH group-level and leaf-level -ForEach
    # templating, e.g. 'Group ForEach probe.group alpha.checks value'), so
    # each -ForEach instance USUALLY gets a distinct identity string this way.
    #
    # But `.ExpandedPath` alone is still an insufficient identity key on its
    # own: it only disambiguates when the -ForEach/-TestCases templated name
    # string actually references the varying data. When a test author writes
    # a fixed literal It name and relies on -ForEach purely for data variation
    # (a legitimate, common Pester pattern -- e.g. an It named 'keeps
    # same-tip duplicate branches blocked for rename and cleanup' with
    # -ForEach @(@{RequestedAction='rename'}, @{RequestedAction='cleanup'})
    # and no <RequestedAction> token anywhere in the name), every instance
    # expands to the IDENTICAL name/path and collapses onto one base
    # identity. The two passes below detect genuine collisions and append a
    # synthetic ordinal disambiguator ONLY to colliding groups, leaving every
    # already-unique identity unchanged so most of the suite's identities
    # stay stable.
    `$testEntries = [System.Collections.Generic.List[object]]::new()
    foreach (`$t in @(`$r.Tests)) {
        `$fileFull = [string]`$t.ScriptBlock.File
        `$relFile = if (`$fileFull -and `$fileFull.StartsWith(`$testsPathFull)) {
            `$fileFull.Substring(`$testsPathFull.Length).TrimStart('\', '/')
        } else {
            Split-Path -Leaf `$fileFull
        }
        `$expandedPath = [string]`$t.ExpandedPath
        `$baseIdentity = "`$relFile :: `$expandedPath"

        `$reason = ''
        if (@(`$t.ErrorRecord).Count -gt 0) {
            `$reason = ((@(`$t.ErrorRecord) | ForEach-Object { `$_.Exception.Message }) -join ' | ')
        }

        `$testEntries.Add([ordered]@{
            baseIdentity = `$baseIdentity
            file         = `$relFile
            status       = [string]`$t.Result
            reason       = `$reason
        }) | Out-Null
    }

    `$identityCounts = @{}
    foreach (`$entry in `$testEntries) {
        `$key = `$entry.baseIdentity
        if (`$identityCounts.ContainsKey(`$key)) { `$identityCounts[`$key]++ } else { `$identityCounts[`$key] = 1 }
    }

    `$identitySeen = @{}
    foreach (`$entry in `$testEntries) {
        `$key = `$entry.baseIdentity
        `$total = `$identityCounts[`$key]
        if (`$total -gt 1) {
            if (`$identitySeen.ContainsKey(`$key)) { `$identitySeen[`$key]++ } else { `$identitySeen[`$key] = 1 }
            `$ordinal = `$identitySeen[`$key]
            `$identity = "`$key [instance `$ordinal of `$total]"
        } else {
            `$identity = `$key
        }

        `$records.Add([ordered]@{
            kind     = 'test'
            identity = `$identity
            file     = `$entry.file
            status   = `$entry.status
            reason   = `$entry.reason
        }) | Out-Null
    }

    `$discoveryErrorCount = 0
    foreach (`$c in @(`$r.Containers)) {
        `$errs = @(`$c.ErrorRecord)
        if (`$errs.Count -gt 0) {
            `$discoveryErrorCount++
            `$fileFull = [string]`$c.Item
            `$relFile = if (`$fileFull -and `$fileFull.StartsWith(`$testsPathFull)) {
                `$fileFull.Substring(`$testsPathFull.Length).TrimStart('\', '/')
            } else {
                Split-Path -Leaf `$fileFull
            }
            `$reason = ((`$errs | ForEach-Object { `$_.Exception.Message }) -join ' | ')
            `$records.Add([ordered]@{
                kind     = 'discovery-error'
                identity = "`$relFile :: <discovery>"
                file     = `$relFile
                status   = 'DiscoveryError'
                reason   = `$reason
            }) | Out-Null
        }
    }

    `$summary = [ordered]@{
        totalTests      = [int]`$r.TotalCount
        passed          = [int]`$r.PassedCount
        failed          = [int]`$r.FailedCount
        skipped         = [int]`$r.SkippedCount
        notRun          = [int]`$r.NotRunCount
        discoveryErrors = `$discoveryErrorCount
    }

    `$obj = [ordered]@{
        requiredVersion = '$RequiredVersion'
        importedVersion = `$importedVersion
        testsPath       = `$testsPathFull
        capturedAt      = (Get-Date).ToUniversalTime().ToString('o')
        summary         = `$summary
        records         = `$records
    }

    `$obj | ConvertTo-Json -Depth 6 -Compress | Set-Content -LiteralPath '$($ResultFilePath -replace "'", "''")' -Encoding UTF8
    exit 0
}
catch {
    `$failObj = [ordered]@{
        requiredVersion = '$RequiredVersion'
        error           = `$_.Exception.Message
        capturedAt      = (Get-Date).ToUniversalTime().ToString('o')
    }
    `$failObj | ConvertTo-Json -Compress | Set-Content -LiteralPath '$($ResultFilePath -replace "'", "''")' -Encoding UTF8
    Write-Error `$_
    exit 2
}
"@
}

# ---------------------------------------------------------------------------
# Invoke-Pester6BaselineCapture
# ---------------------------------------------------------------------------
function Invoke-Pester6BaselineCapture {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$TestsPath,

        # Mandatory and never defaulted: this tool exists specifically because
        # `run-pester-sharded.ps1` auto-resolves "newest installed" Pester with
        # no version selector. A default here would reintroduce that gap.
        [Parameter(Mandatory)]
        [string]$RequiredVersion,

        [string]$OutputPath
    )

    # Function-scoped override only — does not leak to the caller. Every early
    # exit below pairs a Write-Error with a graceful `return [pscustomobject]
    # @{ ExitCode = 1; ... }`, but Write-Error is only non-terminating when
    # $ErrorActionPreference is 'Continue'. When this function is invoked from
    # inside an OUTER Invoke-Pester run whose ambient $ErrorActionPreference is
    # 'Stop' (Pester test scriptblocks commonly run with EAP=Stop), each
    # Write-Error below would otherwise become a terminating error that skips
    # the following `return` entirely, propagating an uncaught exception
    # instead of the intended graceful ExitCode=1 result. Pinning EAP locally
    # makes the graceful-return contract hold regardless of nesting context.
    $ErrorActionPreference = 'Continue'

    $resolvedTestsPath = $TestsPath
    if (-not [System.IO.Path]::IsPathRooted($resolvedTestsPath)) {
        $resolved = Resolve-Path $resolvedTestsPath -ErrorAction SilentlyContinue
        if ($null -ne $resolved) { $resolvedTestsPath = $resolved.Path }
    }

    if (-not (Test-Path -LiteralPath $resolvedTestsPath -PathType Container)) {
        Write-Error "TestsPath not found: $resolvedTestsPath"
        return [pscustomobject]@{ ExitCode = 1; Result = $null }
    }

    # Fail loudly (not silently) if the exact requested version is not installed,
    # rather than letting Import-Module -RequiredVersion fail deep inside the
    # child process with a less actionable message.
    $available = @(Get-Module -Name Pester -ListAvailable | Where-Object { $_.Version.ToString() -eq $RequiredVersion })
    if ($available.Count -eq 0) {
        Write-Error "Pester $RequiredVersion is not installed (Get-Module Pester -ListAvailable found no exact match). Install it before capturing this baseline."
        return [pscustomobject]@{ ExitCode = 1; Result = $null }
    }

    $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) "pester6-baseline-$([System.Guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

    $resultFile = Join-Path $tempDir 'result.json'
    $launchFile = Join-Path $tempDir 'launcher.ps1'

    try {
        $launchContent = Get-Pester6BaselineLauncherScript -TestsPath $resolvedTestsPath -RequiredVersion $RequiredVersion -ResultFilePath $resultFile
        [System.IO.File]::WriteAllText($launchFile, $launchContent, [System.Text.UTF8Encoding]::new($false))

        $proc = $null
        try {
            # Explicitly quote the -File value: Start-Process builds the child
            # process command line by concatenating -ArgumentList elements with
            # spaces rather than re-quoting each element, so an unquoted temp
            # path containing a space (e.g. a scratch dir under a "Program
            # Files"-style or user-provided spaced location) truncates at the
            # first space and pwsh receives a broken path token (confirmed via
            # empirical repro: pwsh exits 64 with a truncated path).
            $proc = Start-Process pwsh -ArgumentList @('-NoProfile', '-NonInteractive', '-File', "`"$launchFile`"") -NoNewWindow -Wait -PassThru
        }
        catch {
            $proc = $null
        }

        $exitCode = if ($null -ne $proc) { $proc.ExitCode } else { 99 }

        if (-not (Test-Path -LiteralPath $resultFile)) {
            Write-Error "Baseline capture produced no result file (child process exit code: $exitCode). Presumed crash."
            return [pscustomobject]@{ ExitCode = 1; Result = $null }
        }

        $parsed = Get-Content -LiteralPath $resultFile -Raw -ErrorAction Stop | ConvertFrom-Json

        if ($exitCode -ne 0 -or $null -ne $parsed.error) {
            $msg = if ($null -ne $parsed.error) { $parsed.error } else { "child process exit code $exitCode" }
            Write-Error "Baseline capture failed: $msg"
            return [pscustomobject]@{ ExitCode = 1; Result = $parsed }
        }

        if ($OutputPath) {
            $outDir = Split-Path -Parent $OutputPath
            if ($outDir -and -not (Test-Path -LiteralPath $outDir)) {
                New-Item -ItemType Directory -Path $outDir -Force | Out-Null
            }
            ($parsed | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $OutputPath -Encoding UTF8 -ErrorAction Stop
        }

        return [pscustomobject]@{ ExitCode = 0; Result = $parsed }
    }
    catch {
        Write-Error "Failed to read, parse, or write the baseline result: $($_.Exception.Message)"
        return [pscustomobject]@{ ExitCode = 1; Result = $null }
    }
    finally {
        if (Test-Path -LiteralPath $tempDir) {
            Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
