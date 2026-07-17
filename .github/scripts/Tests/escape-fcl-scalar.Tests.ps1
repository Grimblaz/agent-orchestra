#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
#Requires -Modules @{ ModuleName = 'powershell-yaml'; ModuleVersion = '0.4.0' }

# Tests for the private script:Escape-FCLScalar helper's YAML scalar-escaping
# correctness (issue #812), exercised indirectly through the public
# New-PipelineMetricsV4Block builder.
#
# issue #489 s2: script:Escape-FCLScalar was hoisted from a function nested
# inside New-PipelineMetricsV4Block to file scope, specifically so it is
# reachable as a standalone script-scope function immediately after
# dot-sourcing this file alone — the shape the cost-baseline-harvest dot-source
# chain actually uses. The 'resolves standalone' test below is the regression
# guard for that reachability contract.
#
# Library under test: .github/scripts/lib/frame-credit-ledger-core.ps1
#
# Bug context: the double-quote-wrapping branch previously doubled embedded `"`
# characters (the single-quoted-scalar escaping convention) instead of using
# backslash-escaping, which is what YAML double-quoted scalars require. It also
# never escaped a literal backslash. Both defects produced invalid YAML for any
# value containing a `'` alongside a `"` and/or a `\`. These tests prove the
# fixed escaping round-trips through a real YAML parser (powershell-yaml),
# independent of the repo's own first-':'-split reader (Get-FCLScalar), which
# could share the same blind spot.

BeforeAll {
    Import-Module powershell-yaml -MinimumVersion 0.4.0

    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
    $script:LibPath = Join-Path $script:RepoRoot '.github/scripts/lib/frame-credit-ledger-core.ps1'

    if (Test-Path $script:LibPath) {
        . $script:LibPath
    }

    # Builds a v4 pipeline-metrics block containing a single credit whose
    # `evidence` field is the caller-supplied raw value, extracts the raw YAML
    # payload from between the HTML-comment markers, parses it with
    # ConvertFrom-Yaml, and returns the parsed evidence string so callers can
    # assert exact equality with the original unescaped value.
    function script:Get-RoundTrippedEvidence {
        param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)

        $credit = @{ port = 'review'; adapter = 'standard'; evidence = $Value }
        $block = New-PipelineMetricsV4Block -V3BaseYaml 'pr_number: 1' -Credits @($credit)

        $match = [regex]::Match($block, '(?ms)<!--\s*pipeline-metrics\s*\r?\n(?<yaml>.*?)\r?\n-->')
        $match.Success | Should -BeTrue -Because 'the rendered block must contain a pipeline-metrics YAML payload'

        $parsed = ConvertFrom-Yaml -Yaml $match.Groups['yaml'].Value
        $reviewCredit = @($parsed['credits']) | Where-Object { $_['port'] -eq 'review' }
        return $reviewCredit['evidence']
    }
}

Describe 'Escape-FCLScalar standalone reachability (issue #489 s2)' {

    It 'resolves as script:Escape-FCLScalar immediately after dot-sourcing frame-credit-ledger-core.ps1 alone, with no other call into the file first' {
        # This is the actual shape the cost-baseline-harvest dot-source chain
        # uses: dot-source the core lib and call the escaper directly, never
        # having called New-PipelineMetricsV4Block first. This Describe block
        # is deliberately placed ahead of the round-trip Describe below (whose
        # Its call New-PipelineMetricsV4Block) so this assertion cannot pass
        # merely because an earlier test's side effect already defined the
        # function — Pester runs Describe blocks in file order, and if
        # Escape-FCLScalar were ever re-nested inside New-PipelineMetricsV4Block,
        # this test (running first) would fail rather than incidentally
        # passing due to test order.
        #
        # Get-Command with -CommandType Function proves the function is a
        # first-class, file-scope definition rather than something that only
        # exists as a side effect of another function's invocation. Get-Command
        # does not resolve scope-qualified names (e.g. 'script:Foo' returns
        # nothing even when the function exists) — query the bare name; the
        # call below still uses the 'script:' prefix to match the codebase's
        # own call-site convention.
        $resolved = Get-Command -Name 'Escape-FCLScalar' -CommandType Function -ErrorAction SilentlyContinue
        $resolved | Should -Not -BeNullOrEmpty -Because 'Escape-FCLScalar must be a file-scope function, not nested inside New-PipelineMetricsV4Block'

        script:Escape-FCLScalar -Value 'plain: value with a colon' | Should -Be "'plain: value with a colon'"
    }
}

Describe 'Escape-FCLScalar (via New-PipelineMetricsV4Block, issue #812)' {

    It 'round-trips a value containing both a single quote and a double quote' {
        # Note: this fixture also carries a ':' (issue #813 finding N3) so it
        # actually triggers $needsQuoting and is routed through the
        # double-quote-wrap branch (any embedded ' always selects that
        # branch) — without a quoting trigger the value would pass through
        # Escape-FCLScalar completely unmodified and this test would not
        # exercise the escaping logic its name claims to cover.
        $original = 'it''s a "quote": test'

        script:Get-RoundTrippedEvidence -Value $original | Should -Be $original
    }

    It 'round-trips a value containing a single quote, a double quote, and a literal backslash' {
        $original = 'C:\path\to\file "quoted" isn''t simple'

        script:Get-RoundTrippedEvidence -Value $original | Should -Be $original
    }

    It 'round-trips a value requiring quoting but containing no quote characters (single-quote branch)' {
        # issue #813 finding N3: the original fixture ("it's a simple test")
        # contains an apostrophe, which per Escape-FCLScalar's logic ALWAYS
        # routes to the double-quote branch — it never reached the
        # single-quote-wrap branch this test's name claimed to cover, and
        # (having no ':', '#', or leading/trailing space/quote either) it
        # didn't trigger $needsQuoting at all, so it passed through
        # Escape-FCLScalar completely unmodified. A fixture that actually
        # exercises the single-quote-wrap branch must contain a quoting
        # trigger (here, ':') and no apostrophe.
        $original = 'plain: value with a colon'

        script:Get-RoundTrippedEvidence -Value $original | Should -Be $original
    }
}
