#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
.SYNOPSIS
    Pester mock fall-through guard (issue #818, step s6).

.DESCRIPTION
    Locks the d-dead-filter-tripwire-v2 contract from the #818 Pester 5->6 migration
    plan (issue-818 plan comment, frame slice s6):

      Clause 1 (fall-through shape): every filtered `Mock <cmd> -ParameterFilter`
      registration must have a same-file default (unfiltered) `Mock <cmd>`
      registration, unless the (File, Command) site is explicitly allowlisted.
      Pester 6 throws on an unmatched Mock call instead of silently falling through
      to the real command; a filtered-only Mock with no default is a latent 6.x
      break if any call misses the filter.

      Clause 2 (sound invoke-pairing): every filtered `Mock <cmd> -ParameterFilter
      {F}` must pair, in the SAME FILE, with a `Should -Invoke <cmd> -Times N
      (N>=1) -ParameterFilter {F'}` where F' is textually equivalent (whitespace-
      normalized) to F, or with a justified allowlist entry. `Should -Invoke`
      evaluates its OWN filter, so a bare pairing (any Should -Invoke on the same
      command, any filter) is unsound: a dead Mock filter can coexist with a
      passing, differently-filtered assertion. Identical-filter + Times>=1 is what
      makes a dead filter fail loudly (see plan Challenge M3 / d-dead-filter-
      tripwire-v2).

      Clause 3 (version-window, fail-loud): pester.yml's Install-Module line is
      the single source of truth for the validated Pester major (its
      -MinimumVersion floor). Both the Install-Module and Import-Module lines
      must carry a -MaximumVersion whose major equals that floor's major, and the
      floor major must be >= 6. If the pin cannot be located or parsed, the guard
      fails loudly (a named test failure), never silently passes.

    Modeled on script-safety-contract.Tests.ps1's precedent: AST-based scan (not
    text grep/regex over source), a centralized $allowlist array with per-entry
    inline justification, explicit self-exclusion, and documented residual-gap
    comments.

    Design note on the allowlist's scope: the task's per-mock-site allowlist is
    described as clause 2's escape hatch, but in practice a single reviewed site
    (cost-walker.Tests.ps1 / Get-NormalizedPath, see BeforeAll below) is a
    deliberate negative-assertion trap that also has no default Mock. Rather than
    invent a second, undocumented exemption mechanism for clause 1, this guard
    treats a justified allowlist entry as exempting its (File, Command) site from
    BOTH clause 1's missing-default check and clause 2's identical-filter pairing
    check -- one reviewed, justified escape hatch, not two.

    Design note on global:<cmd> functions (class e2/e3 in the #818 s1 inventory):
    this guard's clause-1/clause-2 scanners only ever look at `Mock` cmdlet
    CommandAst nodes. A file that implements a command exclusively via
    `function global:<cmd> { ... }` (bare, or nested inside a helper such as
    Install-GhMock) never produces a `Mock <cmd>` registration at all, so it can
    never enter the "has a filtered Mock in this group" precondition that clause 1
    checks. No special-casing of `global:` function definitions is implemented --
    intentionally so, per the s6 RC's explicit warning that "is there a global
    function with this name" is orthogonal to "does a Mock <cmd> -ParameterFilter
    site have a default Mock <cmd>". The falsifiability fixture in the "novel
    helper-wrapped global: variant" context proves this generalizes beyond the
    one known Install-GhMock example.
#>

# ---------------------------------------------------------------------------
# Module-scope helpers (AST-based; no text/regex scanning of Mock call bodies)
# ---------------------------------------------------------------------------

function script:Get-NormalizedScriptblockText {
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return $Text }
    return (($Text -replace '\s+', ' ').Trim())
}

function script:Resolve-KnownParamName {
    param(
        [string]$RawName,
        [string[]]$KnownNames
    )
    foreach ($known in $KnownNames) {
        if ($known -ieq $RawName) { return $known }
    }
    # PowerShell allows unambiguous parameter-name prefixes (e.g. -Param for
    # -ParameterFilter); resolve those to the canonical name too.
    foreach ($known in $KnownNames) {
        if ($known -like "$RawName*") { return $known }
    }
    return $RawName
}

function script:Get-AstLiteralStringValue {
    param($Node)
    if ($null -eq $Node) { return $null }
    if ($Node -is [System.Management.Automation.Language.StringConstantExpressionAst]) { return $Node.Value }
    if ($Node -is [System.Management.Automation.Language.ExpandableStringExpressionAst]) { return $Node.Value }
    return $Node.Extent.Text.Trim("'`"")
}

# Extracts structured info from a single `Mock ...` CommandAst: the mocked
# command name (positional or -CommandName), whether -ParameterFilter is
# present, and its normalized filter text. Handles both `Mock <cmd> { } ` and
# `Mock -CommandName <cmd> -MockWith { }` forms, and (because this walks the
# already-parsed AST) multi-line/backtick-continued calls transparently.
function script:Get-MockRegistrationInfo {
    param([System.Management.Automation.Language.CommandAst]$Cmd)

    $knownParams = @('CommandName', 'MockWith', 'ParameterFilter', 'Verifiable', 'ModuleName', 'RemoveParameterType', 'RemoveParameterValidation')
    $switchParams = @('Verifiable')

    $elems = $Cmd.CommandElements
    $positional = [System.Collections.Generic.List[object]]::new()
    $named = @{}

    $i = 1
    while ($i -lt $elems.Count) {
        $el = $elems[$i]
        if ($el -is [System.Management.Automation.Language.CommandParameterAst]) {
            $resolved = Resolve-KnownParamName -RawName $el.ParameterName -KnownNames $knownParams
            if ($el.Argument) {
                $named[$resolved] = $el.Argument
                $i++
                continue
            }
            if ($switchParams -contains $resolved) {
                $i++
                continue
            }
            if (($i + 1) -lt $elems.Count) {
                $named[$resolved] = $elems[$i + 1]
                $i += 2
                continue
            }
            $i++
            continue
        }
        else {
            $positional.Add($el)
            $i++
        }
    }

    $cmdName = $null
    if ($named.ContainsKey('CommandName')) {
        $cmdName = Get-AstLiteralStringValue -Node $named['CommandName']
    }
    elseif ($positional.Count -ge 1) {
        $cmdName = Get-AstLiteralStringValue -Node $positional[0]
    }

    $hasFilter = $named.ContainsKey('ParameterFilter')
    $filterText = $null
    if ($hasFilter) {
        $filterText = Get-NormalizedScriptblockText -Text $named['ParameterFilter'].Extent.Text
    }

    [PSCustomObject]@{
        CommandName = $cmdName
        HasFilter   = $hasFilter
        FilterText  = $filterText
        Line        = $Cmd.Extent.StartLineNumber
    }
}

# Extracts structured info from a `Should -Invoke ...` CommandAst. Returns
# $null for any other `Should` assertion (e.g. `Should -Be`, `Should
# -InvokeVerifiable`) so callers only see genuine -Invoke assertions.
function script:Get-ShouldInvokeInfo {
    param([System.Management.Automation.Language.CommandAst]$Cmd)

    $knownParams = @('Invoke', 'Times', 'Exactly', 'ParameterFilter', 'Scope', 'ModuleName', 'CommandName')
    $switchParams = @('Invoke', 'Exactly')

    $elems = $Cmd.CommandElements
    $positional = [System.Collections.Generic.List[object]]::new()
    $named = @{}
    $isInvoke = $false

    $i = 1
    while ($i -lt $elems.Count) {
        $el = $elems[$i]
        if ($el -is [System.Management.Automation.Language.CommandParameterAst]) {
            $resolved = Resolve-KnownParamName -RawName $el.ParameterName -KnownNames $knownParams
            if ($resolved -eq 'Invoke') { $isInvoke = $true }
            if ($el.Argument) {
                $named[$resolved] = $el.Argument
                $i++
                continue
            }
            if ($switchParams -contains $resolved) {
                $i++
                continue
            }
            if (($i + 1) -lt $elems.Count) {
                $named[$resolved] = $elems[$i + 1]
                $i += 2
                continue
            }
            $i++
            continue
        }
        else {
            $positional.Add($el)
            $i++
        }
    }

    if (-not $isInvoke) { return $null }

    $invokedCmd = $null
    if ($named.ContainsKey('CommandName')) {
        $invokedCmd = Get-AstLiteralStringValue -Node $named['CommandName']
    }
    elseif ($positional.Count -ge 1) {
        $invokedCmd = Get-AstLiteralStringValue -Node $positional[0]
    }

    $hasFilter = $named.ContainsKey('ParameterFilter')
    $filterText = $null
    if ($hasFilter) {
        $filterText = Get-NormalizedScriptblockText -Text $named['ParameterFilter'].Extent.Text
    }

    $timesValue = $null
    if ($named.ContainsKey('Times')) {
        $timesText = $named['Times'].Extent.Text.Trim()
        $parsed = 0
        if ([int]::TryParse($timesText, [ref]$parsed)) { $timesValue = $parsed }
    }

    [PSCustomObject]@{
        InvokedCommand = $invokedCmd
        HasFilter      = $hasFilter
        FilterText     = $filterText
        Times          = $timesValue
        Line           = $Cmd.Extent.StartLineNumber
    }
}

# Parses one file and returns @{ MockSites = ...; InvokeSites = ... }. Only
# `Mock` CommandAst nodes feed MockSites, and only `Should -Invoke` CommandAst
# nodes feed InvokeSites -- this is the AST-level distinction between a Mock
# registration and a Should -Invoke assertion the guard is required to make.
function script:Get-MockFallthroughFileScan {
    param([string]$Path)

    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)

    if ($errors -and $errors.Count -gt 0) {
        return [PSCustomObject]@{
            ParseError  = ($errors | ForEach-Object { $_.Message }) -join '; '
            MockSites   = @()
            InvokeSites = @()
        }
    }

    $allCmds = $ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.CommandAst]
        }, $true)

    $mockSites = [System.Collections.Generic.List[object]]::new()
    $invokeSites = [System.Collections.Generic.List[object]]::new()

    foreach ($cmd in $allCmds) {
        $cmdName = $cmd.GetCommandName()
        if ($cmdName -ieq 'Mock') {
            $mockSites.Add((Get-MockRegistrationInfo -Cmd $cmd))
        }
        elseif ($cmdName -ieq 'Should') {
            $info = Get-ShouldInvokeInfo -Cmd $cmd
            if ($null -ne $info) { $invokeSites.Add($info) }
        }
    }

    [PSCustomObject]@{
        ParseError  = $null
        MockSites   = $mockSites
        InvokeSites = $invokeSites
    }
}

# Clause 1: for each mocked command with >=1 filtered registration, a same-file
# unfiltered (default) registration must also exist, unless allowlisted.
function script:Get-Clause1Violations {
    param(
        [string]$FileName,
        [PSCustomObject]$Scan,
        [object[]]$Allowlist
    )

    $violations = [System.Collections.Generic.List[object]]::new()
    if ($Scan.ParseError) {
        $violations.Add("PARSE ERROR in ${FileName}: $($Scan.ParseError)")
        return $violations
    }

    $byCommand = $Scan.MockSites | Where-Object { $null -ne $_.CommandName } | Group-Object -Property CommandName
    foreach ($group in $byCommand) {
        $hasFiltered = $group.Group | Where-Object { $_.HasFilter }
        if (-not $hasFiltered) { continue }

        $hasDefault = $group.Group | Where-Object { -not $_.HasFilter }
        if ($hasDefault) { continue }

        $allowed = $Allowlist | Where-Object { $_.File -eq $FileName -and $_.Command -eq $group.Name }
        if ($allowed) { continue }

        $lines = ($hasFiltered | ForEach-Object { $_.Line }) -join ', '
        $violations.Add("${FileName}: '$($group.Name)' has a filtered Mock -ParameterFilter (line(s) $lines) with no same-file default Mock and no allowlist entry")
    }

    return $violations
}

# Clause 2: for each distinct (command, normalized filter text) filtered
# registration, a same-file identical-filter Should -Invoke -Times>=1 must
# exist, unless allowlisted at (File, Command) granularity.
function script:Get-Clause2Violations {
    param(
        [string]$FileName,
        [PSCustomObject]$Scan,
        [object[]]$Allowlist
    )

    $violations = [System.Collections.Generic.List[object]]::new()
    if ($Scan.ParseError) {
        $violations.Add("PARSE ERROR in ${FileName}: $($Scan.ParseError)")
        return $violations
    }

    $filteredMocks = $Scan.MockSites | Where-Object { $_.HasFilter -and $null -ne $_.CommandName }
    $filteredGroups = $filteredMocks | Group-Object -Property CommandName, FilterText

    foreach ($group in $filteredGroups) {
        $sample = $group.Group[0]
        $cmdName = $sample.CommandName
        $filterText = $sample.FilterText

        $soundPairingExists = $Scan.InvokeSites | Where-Object {
            $_.HasFilter -and
            $_.InvokedCommand -ieq $cmdName -and
            $_.FilterText -eq $filterText -and
            $null -ne $_.Times -and $_.Times -ge 1
        }
        if ($soundPairingExists) { continue }

        $allowed = $Allowlist | Where-Object { $_.File -eq $FileName -and $_.Command -eq $cmdName }
        if ($allowed) { continue }

        $lines = ($group.Group | ForEach-Object { $_.Line }) -join ', '
        $violations.Add("${FileName}: '$cmdName' filtered Mock (line(s) $lines, filter: $filterText) has no same-file identical-filter Should -Invoke -Times>=1 pairing and no allowlist entry")
    }

    return $violations
}

# Clause 3: derive the validated major from pester.yml's Install-Module
# -MinimumVersion floor, then assert both the Install-Module and Import-Module
# lines carry a matching-major -MaximumVersion cap, floor >= 6. Fails loudly
# (throws with a specific message) if the pin cannot be located/parsed instead
# of silently returning a pass-shaped result.
function script:Get-PesterVersionWindow {
    param([string]$PesterYmlPath)

    if (-not (Test-Path $PesterYmlPath)) {
        throw "clause 3: pester.yml not found at '$PesterYmlPath'"
    }
    $lines = Get-Content -Path $PesterYmlPath

    $installLine = $lines | Where-Object { $_ -match '(?i)Install-Module\s+.*-Name\s+Pester\b' } | Select-Object -First 1
    if (-not $installLine) {
        throw "clause 3: could not locate an 'Install-Module ... -Name Pester' line in pester.yml"
    }
    $importLine = $lines | Where-Object { $_ -match '(?i)Import-Module\s+Pester\b' } | Select-Object -First 1
    if (-not $importLine) {
        throw "clause 3: could not locate an 'Import-Module Pester' line in pester.yml"
    }

    $installFloorMatch = [regex]::Match($installLine, '(?i)-MinimumVersion\s+(?<v>\d+\.\d+\.\d+)')
    $installCapMatch = [regex]::Match($installLine, '(?i)-MaximumVersion\s+(?<v>\d+\.\d+\.\d+)')
    $importFloorMatch = [regex]::Match($importLine, '(?i)-MinimumVersion\s+(?<v>\d+\.\d+\.\d+)')
    $importCapMatch = [regex]::Match($importLine, '(?i)-MaximumVersion\s+(?<v>\d+\.\d+\.\d+)')

    if (-not $installFloorMatch.Success) {
        throw "clause 3: Install-Module line has no parseable -MinimumVersion floor: '$installLine'"
    }
    if (-not $installCapMatch.Success) {
        throw "clause 3: Install-Module line has no parseable -MaximumVersion cap: '$installLine'"
    }
    if (-not $importFloorMatch.Success) {
        throw "clause 3: Import-Module line has no parseable -MinimumVersion floor: '$importLine'"
    }
    if (-not $importCapMatch.Success) {
        throw "clause 3: Import-Module line has no parseable -MaximumVersion cap: '$importLine'"
    }

    [PSCustomObject]@{
        InstallFloor = [version]$installFloorMatch.Groups['v'].Value
        InstallCap   = [version]$installCapMatch.Groups['v'].Value
        ImportFloor  = [version]$importFloorMatch.Groups['v'].Value
        ImportCap    = [version]$importCapMatch.Groups['v'].Value
    }
}

Describe 'Pester mock fall-through guard (issue #818 s6)' {

    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
        $script:TestsRoot = Join-Path $script:RepoRoot '.github/scripts/Tests'
        $script:PesterYmlPath = Join-Path $script:RepoRoot '.github/workflows/pester.yml'

        # self-excluded: this file's own falsifiability fixtures below write
        # temp-file corpora containing example Mock/-ParameterFilter/global:
        # text; scanning this file itself would trip clause 1/clause 2 against
        # its own docstrings and helper-function source (same rationale as
        # script-safety-contract.Tests.ps1's self-exclusion).
        $script:SelfFileName = 'pester-mock-fallthrough-guard.Tests.ps1'

        # Centralized allowlist -- per-mock-site (File + Command) granularity,
        # matching script-safety-contract's shape. Exempts the (File, Command)
        # pair from BOTH clause 1 (missing default) and clause 2 (identical-
        # filter -Times>=1 pairing); see the file header design note above for
        # why one allowlist covers both clauses instead of two mechanisms.
        $script:Allowlist = @(
            [PSCustomObject]@{
                File          = 'cost-walker.Tests.ps1'
                Command       = 'Get-NormalizedPath'
                Justification = 'Deliberate negative-assertion trap, not a functional stub: cost-walker.ps1:83 (Test-CostWalkerEventCwdMatchesParent) short-circuits on the Copilot OTel sentinel-cwd prefix before ever calling Get-NormalizedPath, so this filtered Mock (cost-walker.Tests.ps1:425) intentionally has no default and its paired assertion (line 432) is "Should -Invoke -Exactly -Times 0" -- proving the call NEVER happens, the opposite of the automatic Times>=1 sound-pairing mechanism. See .tmp/issue-818/migration-scan-inventory.md class (a), cost-walker.Tests.ps1 Get-NormalizedPath row.'
            }
        )

        foreach ($entry in $script:Allowlist) {
            if ([string]::IsNullOrWhiteSpace($entry.Justification)) {
                throw "Allowlist entry for '$($entry.File)' / '$($entry.Command)' has no justification -- every allowlist entry must carry a non-empty reason."
            }
        }

        $script:AllTestFiles = Get-ChildItem -Path $script:TestsRoot -Filter '*.Tests.ps1' -File |
            Where-Object { $_.Name -ne $script:SelfFileName }
    }

    Context 'Clause 1: fall-through shape (missing default Mock)' {
        It 'no filtered Mock command lacks a same-file default Mock for that same command, across the full Tests suite' {
            $allViolations = [System.Collections.Generic.List[object]]::new()
            foreach ($file in $script:AllTestFiles) {
                $scan = Get-MockFallthroughFileScan -Path $file.FullName
                $fileViolations = Get-Clause1Violations -FileName $file.Name -Scan $scan -Allowlist $script:Allowlist
                foreach ($v in $fileViolations) { $allViolations.Add($v) }
            }

            $allViolations | Should -BeNullOrEmpty -Because (
                "every filtered Mock <cmd> -ParameterFilter must have a same-file default (unfiltered) Mock <cmd>, or a justified allowlist entry, because Pester 6 throws on an unmatched Mock call instead of falling through:`n" +
                ($allViolations -join "`n")
            )
        }
    }

    Context 'Clause 2: sound invoke-pairing' {
        It 'every filtered Mock command -ParameterFilter pairs with an identical-filter Should -Invoke -Times>=1, or a justified allowlist entry, across the full Tests suite' {
            $allViolations = [System.Collections.Generic.List[object]]::new()
            foreach ($file in $script:AllTestFiles) {
                $scan = Get-MockFallthroughFileScan -Path $file.FullName
                $fileViolations = Get-Clause2Violations -FileName $file.Name -Scan $scan -Allowlist $script:Allowlist
                foreach ($v in $fileViolations) { $allViolations.Add($v) }
            }

            $allViolations | Should -BeNullOrEmpty -Because (
                "every filtered Mock <cmd> -ParameterFilter {F} must pair, in the same file, with an identical-filter Should -Invoke <cmd> -Times N (N>=1) -ParameterFilter {F'}, or a justified allowlist entry, per d-dead-filter-tripwire-v2 (a bare/mismatched pairing lets a dead filter pass silently):`n" +
                ($allViolations -join "`n")
            )
        }

        It 'every allowlist entry carries a non-empty justification (self-check)' {
            foreach ($entry in $script:Allowlist) {
                $entry.Justification | Should -Not -BeNullOrEmpty -Because "allowlist entry '$($entry.File)' / '$($entry.Command)' must document why it is exempt"
            }
        }
    }

    Context 'Clause 3: version-window, fail-loud' {
        It 'derives a parseable floor/cap version window from pester.yml' {
            { Get-PesterVersionWindow -PesterYmlPath $script:PesterYmlPath } | Should -Not -Throw -Because 'the guard must fail loudly, not silently, if the pin cannot be located/parsed -- but the real pester.yml must always parse cleanly'
        }

        It 'both Install-Module and Import-Module lines carry a -MaximumVersion whose major equals the -MinimumVersion floor major, and the floor major is >= 6' {
            $window = Get-PesterVersionWindow -PesterYmlPath $script:PesterYmlPath

            $window.InstallFloor.Major | Should -Be $window.InstallCap.Major -Because 'the Install-Module line''s floor and cap must share a major version window'
            $window.ImportFloor.Major | Should -Be $window.ImportCap.Major -Because 'the Import-Module line''s floor and cap must share a major version window'
            $window.InstallFloor.Major | Should -Be $window.ImportFloor.Major -Because 'Install-Module and Import-Module must validate the same major'
            $window.InstallFloor.Major | Should -BeGreaterOrEqual 6 -Because 'issue #818 established Pester 6.0.0 as the validated floor'
        }
    }

    Context 'Falsifiability: clause 1 fires on a genuine fall-through violation and stays silent on compliant input' {
        BeforeAll {
            $script:FixtureDir = Join-Path ([System.IO.Path]::GetTempPath()) "pmfg-clause1-$([System.Guid]::NewGuid().ToString('N'))"
            $null = New-Item -ItemType Directory -Path $script:FixtureDir -Force
        }
        AfterAll {
            if (Test-Path $script:FixtureDir) { Remove-Item -Recurse -Force $script:FixtureDir }
        }

        It 'flags a filtered Mock with no same-file default' {
            $path = Join-Path $script:FixtureDir 'violation.Tests.ps1'
            Set-Content -Path $path -Value @'
Describe 'x' {
    It 'y' {
        Mock Get-Something { 1 } -ParameterFilter { $Id -eq 1 }
        Should -Invoke Get-Something -Times 1 -ParameterFilter { $Id -eq 1 }
    }
}
'@
            $scan = Get-MockFallthroughFileScan -Path $path
            $violations = Get-Clause1Violations -FileName 'violation.Tests.ps1' -Scan $scan -Allowlist @()
            $violations | Should -Not -BeNullOrEmpty -Because 'a filtered Mock with no default and no allowlist entry must be flagged'
        }

        It 'stays silent on a compliant file (default + filtered pair)' {
            $path = Join-Path $script:FixtureDir 'compliant.Tests.ps1'
            Set-Content -Path $path -Value @'
Describe 'x' {
    It 'y' {
        Mock Get-Something { 0 }
        Mock Get-Something { 1 } -ParameterFilter { $Id -eq 1 }
        Should -Invoke Get-Something -Times 1 -ParameterFilter { $Id -eq 1 }
    }
}
'@
            $scan = Get-MockFallthroughFileScan -Path $path
            $violations = Get-Clause1Violations -FileName 'compliant.Tests.ps1' -Scan $scan -Allowlist @()
            $violations | Should -BeNullOrEmpty -Because 'a filtered Mock with a same-file default must not be flagged'
        }
    }

    Context 'Falsifiability: clause 2 fires on unsound pairing and stays silent when properly paired' {
        BeforeAll {
            $script:FixtureDir = Join-Path ([System.IO.Path]::GetTempPath()) "pmfg-clause2-$([System.Guid]::NewGuid().ToString('N'))"
            $null = New-Item -ItemType Directory -Path $script:FixtureDir -Force
        }
        AfterAll {
            if (Test-Path $script:FixtureDir) { Remove-Item -Recurse -Force $script:FixtureDir }
        }

        It 'flags a filtered Mock with no paired identical-filter Should -Invoke and no allowlist entry' {
            $path = Join-Path $script:FixtureDir 'unsound.Tests.ps1'
            Set-Content -Path $path -Value @'
Describe 'x' {
    It 'y' {
        Mock Get-Something { 0 }
        Mock Get-Something { 1 } -ParameterFilter { $Id -eq 1 }
        # unsound: the pairing assertion below uses a DIFFERENT filter than the
        # Mock's -ParameterFilter, so a dead $Id -eq 1 filter would pass silently.
        Should -Invoke Get-Something -Times 1 -ParameterFilter { $Id -eq 2 }
    }
}
'@
            $scan = Get-MockFallthroughFileScan -Path $path
            $violations = Get-Clause2Violations -FileName 'unsound.Tests.ps1' -Scan $scan -Allowlist @()
            $violations | Should -Not -BeNullOrEmpty -Because 'a filtered Mock without an identical-filter Times>=1 pairing must be flagged even when an unrelated-filter assertion exists'
        }

        It 'stays silent when properly paired (identical filter, Times>=1)' {
            $path = Join-Path $script:FixtureDir 'sound.Tests.ps1'
            Set-Content -Path $path -Value @'
Describe 'x' {
    It 'y' {
        Mock Get-Something { 0 }
        Mock Get-Something { 1 } -ParameterFilter { $Id -eq 1 }
        Should -Invoke Get-Something -Times 1 -ParameterFilter { $Id -eq 1 }
    }
}
'@
            $scan = Get-MockFallthroughFileScan -Path $path
            $violations = Get-Clause2Violations -FileName 'sound.Tests.ps1' -Scan $scan -Allowlist @()
            $violations | Should -BeNullOrEmpty -Because 'an identical-filter, Times>=1 pairing is sound and must not be flagged'
        }
    }

    Context 'Falsifiability: clause 2 allowlist escape hatch' {
        BeforeAll {
            $script:FixtureDir = Join-Path ([System.IO.Path]::GetTempPath()) "pmfg-clause2-allowlist-$([System.Guid]::NewGuid().ToString('N'))"
            $null = New-Item -ItemType Directory -Path $script:FixtureDir -Force
        }
        AfterAll {
            if (Test-Path $script:FixtureDir) { Remove-Item -Recurse -Force $script:FixtureDir }
        }

        It 'a justified allowlist entry exempts an otherwise-unsound pairing' {
            $path = Join-Path $script:FixtureDir 'allowlisted.Tests.ps1'
            Set-Content -Path $path -Value @'
Describe 'x' {
    It 'y' {
        Mock Get-Something { 1 } -ParameterFilter { $Id -eq 1 }
    }
}
'@
            $scan = Get-MockFallthroughFileScan -Path $path
            $noAllowlist = Get-Clause2Violations -FileName 'allowlisted.Tests.ps1' -Scan $scan -Allowlist @()
            $noAllowlist | Should -Not -BeNullOrEmpty -Because 'without an allowlist entry, an unpaired filtered Mock must be flagged'

            $withAllowlist = @([PSCustomObject]@{ File = 'allowlisted.Tests.ps1'; Command = 'Get-Something'; Justification = 'fixture proof' })
            $violations = Get-Clause2Violations -FileName 'allowlisted.Tests.ps1' -Scan $scan -Allowlist $withAllowlist
            $violations | Should -BeNullOrEmpty -Because 'a justified allowlist entry at (File, Command) granularity must exempt the site'
        }
    }

    Context 'Falsifiability: clause 3 fires on version-window violations and fails loudly on an unparseable pin' {
        BeforeAll {
            $script:FixtureDir = Join-Path ([System.IO.Path]::GetTempPath()) "pmfg-clause3-$([System.Guid]::NewGuid().ToString('N'))"
            $null = New-Item -ItemType Directory -Path $script:FixtureDir -Force
        }
        AfterAll {
            if (Test-Path $script:FixtureDir) { Remove-Item -Recurse -Force $script:FixtureDir }
        }

        It 'flags a floor/cap major mismatch (runaway ceiling)' {
            $path = Join-Path $script:FixtureDir 'mismatch-pester.yml'
            Set-Content -Path $path -Value @'
name: fixture
jobs:
  pester:
    steps:
      - run: |
          Install-Module -Name Pester -Force -SkipPublisherCheck -MinimumVersion 6.0.0 -MaximumVersion 7.999.999
          Import-Module Pester -MinimumVersion 6.0.0 -MaximumVersion 7.999.999
'@
            $window = Get-PesterVersionWindow -PesterYmlPath $path
            $window.InstallFloor.Major | Should -Not -Be $window.InstallCap.Major -Because 'this fixture deliberately has a runaway-ceiling mismatch (floor major 6, cap major 7)'
        }

        It 'flags a missing/absent -MaximumVersion cap' {
            $path = Join-Path $script:FixtureDir 'missing-cap-pester.yml'
            Set-Content -Path $path -Value @'
name: fixture
jobs:
  pester:
    steps:
      - run: |
          Install-Module -Name Pester -Force -SkipPublisherCheck -MinimumVersion 6.0.0
          Import-Module Pester -MinimumVersion 6.0.0
'@
            { Get-PesterVersionWindow -PesterYmlPath $path } | Should -Throw -Because 'a missing -MaximumVersion cap is the exact runaway-ceiling scenario the guard must fail loudly on, not silently pass'
        }

        It 'fails loudly (not silently) when the pin line cannot be found at all' {
            $path = Join-Path $script:FixtureDir 'no-pin-pester.yml'
            Set-Content -Path $path -Value @'
name: fixture
jobs:
  pester:
    steps:
      - run: echo "no Pester install here"
'@
            { Get-PesterVersionWindow -PesterYmlPath $path } | Should -Throw -Because 'the guard must never silently pass when it cannot locate the version pin at all'
        }
    }

    Context 'Falsifiability: clause 1 generalizes to a novel helper-wrapped global: variant' {
        BeforeAll {
            $script:FixtureDir = Join-Path ([System.IO.Path]::GetTempPath()) "pmfg-global-novel-$([System.Guid]::NewGuid().ToString('N'))"
            $null = New-Item -ItemType Directory -Path $script:FixtureDir -Force
        }
        AfterAll {
            if (Test-Path $script:FixtureDir) { Remove-Item -Recurse -Force $script:FixtureDir }
        }

        It 'does not flag a novel helper-wrapped global-scope command pattern not copied from Install-GhMock' {
            # A different helper name/shape than cost-rolling-history.Tests.ps1's
            # Install-GhMock, proving clause 1 generalizes rather than special-
            # casing the one known example. This helper wraps global:curl instead
            # of global:gh, and is invoked from a BeforeEach rather than an It.
            $path = Join-Path $script:FixtureDir 'novel-global.Tests.ps1'
            Set-Content -Path $path -Value @'
Describe 'x' {
    function global:Install-CurlDouble {
        param([string]$Body = 'ok')
        function global:curl {
            param([Parameter(ValueFromRemainingArguments = $true)]$RemainingArgs)
            return $Body
        }
    }

    BeforeEach {
        Install-CurlDouble -Body 'stub-response'
    }

    It 'y' {
        $result = curl 'https://example.invalid'
        $result | Should -Be 'stub-response'
    }
}
'@
            $scan = Get-MockFallthroughFileScan -Path $path
            $violations = Get-Clause1Violations -FileName 'novel-global.Tests.ps1' -Scan $scan -Allowlist @()
            $violations | Should -BeNullOrEmpty -Because 'a command implemented exclusively via a helper-wrapped global:<cmd> function (no Mock cmdlet calls at all) never enters clause 1''s filtered-Mock-without-default precondition, regardless of the helper''s name or shape'
        }
    }
}
