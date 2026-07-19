#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
.SYNOPSIS
    RED tests for .github/scripts/lib/goal-contract-core.ps1 (issue #872, frame-slice s1).

.DESCRIPTION
    Contract under test (per the 872-D2/872-D3/872-D6 design decisions and the
    plan step-2 lib-surface listing):

      Get-GCContractBlock -CommentBody <string>
        Returns the goal-contract block payload, or $null when absent.
        Multi-block arity FAILS rather than first-winning.

      ConvertFrom-GCContractBlock -Payload <string> -RepoRoot <string>
        Returns [pscustomobject]@{ Contract; Violations }. Returns violations,
        never throws, on schema failure. Pipeline: pre-parse alias/anchor
        guard -> size cap -> Import-Module powershell-yaml (loud throw on
        module-missing) -> ConvertFrom-Yaml -> ConvertTo-Json -Depth 20 ->
        Test-Json.

      Get-GCContractHash -Payload <string>
        Returns a 64-hex sha256 digest over the canonicalized payload body
        (contract_hash: line elided at column 0, CRLF/CR normalized to LF,
        per-line trailing whitespace stripped, single final LF, UTF-8 no BOM).

      Test-GCContractHash -Payload <string> -Expected <string>
        Returns boolean.

    These tests are RED until goal-contract-core.ps1 lands in frame-slice s2;
    every failure here must be because the lib file (or one of its exported
    functions) is absent, not a syntax error in this test file. Each
    behavioral It therefore guards on function existence via
    script:Assert-GCFunctionExists before invoking anything.

.NOTES
    Independent-oracle hash vectors: two fixtures under
    .github/scripts/Tests/fixtures/goal-contract-core/ were canonicalized by
    hand and digested with `sha256sum` outside of this repo's own code, so
    the golden digests below are not merely self-consistent with whatever
    Get-GCContractHash's implementation happens to do:

        sha256sum .github/scripts/Tests/fixtures/goal-contract-core/ascii-baseline-canonical.txt
          -> 01d11f3b2221980ae6f30633a2a3316fa51fabdafcbd5ae424320d06c6b83759

        sha256sum .github/scripts/Tests/fixtures/goal-contract-core/non-ascii-baseline-canonical.txt
          -> fb7aee5ee39ff49aa7426ed586199016aa74b7cf6fa7522b1869dab82fae1089
#>

Describe 'goal-contract-core.ps1' -Tag 'unit' {

    BeforeAll {
        $script:RepoRoot     = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
        $script:LibFile      = Join-Path $script:RepoRoot '.github/scripts/lib/goal-contract-core.ps1'
        $script:SchemaFile   = Join-Path $script:RepoRoot 'skills/plan-authoring/schemas/goal-contract.schema.json'
        $script:FixturesDir  = Join-Path $script:RepoRoot '.github/scripts/Tests/fixtures/goal-contract-core'

        if (Test-Path -LiteralPath $script:LibFile) {
            . $script:LibFile
        }

        function script:Assert-GCFunctionExists {
            param([Parameter(Mandatory)][string]$Name)
            (Get-Command -Name $Name -ErrorAction SilentlyContinue) | Should -Not -BeNullOrEmpty -Because "goal-contract-core.ps1 must define $Name before this behavior can be verified"
        }

        # --- Independently-derived oracle digests (see .NOTES above) ---
        $script:AsciiBaselineOracleDigest    = '01d11f3b2221980ae6f30633a2a3316fa51fabdafcbd5ae424320d06c6b83759'
        $script:NonAsciiBaselineOracleDigest = 'fb7aee5ee39ff49aa7426ed586199016aa74b7cf6fa7522b1869dab82fae1089'

        $script:AsciiBaselineInputPath    = Join-Path $script:FixturesDir 'ascii-baseline-input.txt'
        $script:NonAsciiBaselineInputPath = Join-Path $script:FixturesDir 'non-ascii-baseline-input.txt'

        # Baseline body lines with NO contract_hash line at all (used to build
        # the elision-invariant and final-newline-arity/whitespace/CRLF/CR
        # variants below without depending on the fixture files' exact bytes).
        $script:AsciiBaselineLines = @(
            'schema_version: 1',
            'issue: 872',
            'note: ascii baseline oracle vector for Get-GCContractHash'
        )
    }

    Context 'Get-GCContractBlock — extraction' {
        It 'extracts the payload when a single block is present' {
            script:Assert-GCFunctionExists -Name 'Get-GCContractBlock'
            $body = "Some prose above.`n`n<!-- goal-contract`nschema_version: 1`nissue: 872`n-->`n`nSome prose below."
            Get-GCContractBlock -CommentBody $body | Should -Be "schema_version: 1`nissue: 872"
        }

        It 'returns $null when no block is present' {
            script:Assert-GCFunctionExists -Name 'Get-GCContractBlock'
            $body = "Just a plan comment with no goal-contract block at all."
            Get-GCContractBlock -CommentBody $body | Should -BeNullOrEmpty
        }

        It 'returns $null for a malformed (unterminated) block' {
            script:Assert-GCFunctionExists -Name 'Get-GCContractBlock'
            $body = "<!-- goal-contract`nschema_version: 1`nissue: 872`n"
            Get-GCContractBlock -CommentBody $body | Should -BeNullOrEmpty -Because 'a block with no closing terminator before EOF is not a parseable block'
        }

        It 'returns an empty string for an empty block (head immediately followed by the terminator)' {
            script:Assert-GCFunctionExists -Name 'Get-GCContractBlock'
            $body = "<!-- goal-contract`n-->"
            $result = Get-GCContractBlock -CommentBody $body
            ($null -eq $result) | Should -BeFalse -Because 'an empty-but-present block must be distinguishable from an absent block ($null)'
            $result | Should -Be '' -Because 'the block exists but carries no payload text'
        }

        It 'does not silently first-win when two blocks are present' {
            script:Assert-GCFunctionExists -Name 'Get-GCContractBlock'
            $body = "<!-- goal-contract`nblock-one-content`n-->`n`n<!-- goal-contract`nblock-two-content`n-->"

            $threw = $false
            $result = $null
            try {
                $result = Get-GCContractBlock -CommentBody $body
            } catch {
                $threw = $true
            }

            $firstWon = (-not $threw) -and ($result -eq 'block-one-content')
            $firstWon | Should -BeFalse -Because 'multi-block arity must fail rather than silently prefer the first block over the real contract'
        }

        It 'does not silently extract a fenced documentation example above the real block' {
            script:Assert-GCFunctionExists -Name 'Get-GCContractBlock'
            $body = @'
Here is what a goal-contract block looks like:

```
<!-- goal-contract
documentation-example-content
-->
```

<!-- goal-contract
real-block-content
-->
'@
            $threw = $false
            $result = $null
            try {
                $result = Get-GCContractBlock -CommentBody $body
            } catch {
                $threw = $true
            }

            $exampleWon = (-not $threw) -and ($result -eq 'documentation-example-content')
            $exampleWon | Should -BeFalse -Because 'extraction is markdown-blind, so a fenced documentation example textually matches the block pattern too; it must not be silently preferred over (or merged with) the real block'
        }

        It 'extracts the payload from a CRLF-authored comment body' {
            script:Assert-GCFunctionExists -Name 'Get-GCContractBlock'
            $body = "Some prose above.`r`n`r`n<!-- goal-contract`r`nschema_version: 1`r`nissue: 872`r`n-->`r`n`r`nSome prose below."
            Get-GCContractBlock -CommentBody $body | Should -Be "schema_version: 1`nissue: 872" -Because 'the raw comment body sourced from the GitHub API is never CRLF-normalized by the caller (M1); Get-GCContractBlock must normalize it internally, consistent with Get-GCContractHash and Test-GCVariantFrontmatter'
        }

        It 'extracts the payload when the head marker has trailing whitespace before its newline' {
            script:Assert-GCFunctionExists -Name 'Get-GCContractBlock'
            $body = "<!-- goal-contract `nschema_version: 1`nissue: 872`n-->"
            Get-GCContractBlock -CommentBody $body | Should -Be "schema_version: 1`nissue: 872" -Because 'a stray trailing space before the marker newline must not hide an otherwise well-formed block (M16b)'
        }

        It 'does not truncate a payload at an indented --> inside a block scalar' {
            script:Assert-GCFunctionExists -Name 'Get-GCContractBlock'
            $body = @"
<!-- goal-contract
general_experience_standard: |
  first guardrail line
    --> this indented arrow is prose content, not the terminator
  third guardrail line
tail_marker: GC-TAIL-MARKER-8B2F
-->
"@
            $result = Get-GCContractBlock -CommentBody $body
            $result | Should -Match 'GC-TAIL-MARKER-8B2F' -Because 'the terminator must be column-0-anchored so an indented --> inside a block scalar cannot truncate the contract'
        }
    }

    Context 'ConvertFrom-GCContractBlock — schema pipeline guardrails' {
        It 'rejects an anchor/alias payload pre-parse without expanding it' {
            script:Assert-GCFunctionExists -Name 'ConvertFrom-GCContractBlock'
            # Anchor/alias fan-out payload (illustrative of the class described in
            # the 872 design findings: a handful of anchors aliased repeatedly
            # expand to tens of thousands of YAML nodes if handed to
            # ConvertFrom-Yaml). The guard must reject this before parsing, not
            # merely fail slowly after parsing.
            $aliasPayload = @'
a: &a [1,1,1,1,1,1,1,1,1]
b: &b [*a,*a,*a,*a,*a,*a,*a,*a,*a]
c: &c [*b,*b,*b,*b,*b,*b,*b,*b,*b]
d: [*c,*c,*c,*c,*c,*c,*c,*c,*c]
'@
            $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
            $outcome = ConvertFrom-GCContractBlock -Payload $aliasPayload -RepoRoot $script:RepoRoot
            $stopwatch.Stop()

            $outcome.Violations | Should -Not -BeNullOrEmpty -Because 'anchor/alias syntax must be rejected as a violation, not silently expanded'
            $stopwatch.Elapsed.TotalSeconds | Should -BeLessThan 2 -Because 'a pre-parse guard must reject the payload before it ever reaches ConvertFrom-Yaml, so this must return quickly rather than expanding tens of thousands of nodes'
        }

        It 'rejects a dot-prefixed anchor/alias name pre-parse (M2 bypass class)' {
            script:Assert-GCFunctionExists -Name 'ConvertFrom-GCContractBlock'
            # powershell-yaml accepts and expands a dot-prefixed anchor name.
            # The old `[A-Za-z0-9_-]` name character class missed this
            # entirely, letting it bypass the exact guard meant to prevent
            # alias-expansion DoS (design-challenge finding M2).
            $dotAnchorPayload = @'
a: &.a [1,1,1,1,1,1,1,1,1]
b: &.b [*.a,*.a,*.a,*.a,*.a,*.a,*.a,*.a,*.a]
c: &.c [*.b,*.b,*.b,*.b,*.b,*.b,*.b,*.b,*.b]
d: [*.c,*.c,*.c,*.c,*.c,*.c,*.c,*.c,*.c]
'@
            $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
            $outcome = ConvertFrom-GCContractBlock -Payload $dotAnchorPayload -RepoRoot $script:RepoRoot
            $stopwatch.Stop()

            $outcome.Violations | Should -Not -BeNullOrEmpty -Because 'a dot-prefixed anchor/alias name must be rejected exactly like an ASCII-named one; the guard must not be name-charset-limited'
            $stopwatch.Elapsed.TotalSeconds | Should -BeLessThan 2 -Because 'the pre-parse guard must reject this before it ever reaches ConvertFrom-Yaml, so this must return quickly rather than expanding tens of thousands of nodes'
        }

        It 'does not reject markdown emphasis asterisks in mandated prose content' {
            script:Assert-GCFunctionExists -Name 'ConvertFrom-GCContractBlock'
            # general_experience_standard is mandated verbatim content
            # (#848 D8); the author has no way to avoid this shape if the
            # guard over-matches on bare whitespace before an asterisk
            # (design-challenge finding M8).
            $emphasisPayload = @'
schema_version: 1
issue: 872
general_experience_standard: "Users must see *clear* feedback."
'@
            $outcome = ConvertFrom-GCContractBlock -Payload $emphasisPayload -RepoRoot $script:RepoRoot
            ($outcome.Violations -join ' ') | Should -Not -Match '(?i)anchor|alias' -Because 'markdown emphasis asterisks around a word in prose must not be misread as a YAML alias token'
        }

        It 'does not reject a glob-style token that follows a keyword and space' {
            script:Assert-GCFunctionExists -Name 'ConvertFrom-GCContractBlock'
            $globPayload = @'
schema_version: 1
issue: 872
check: "Get-ChildItem -Filter *contract*"
'@
            $outcome = ConvertFrom-GCContractBlock -Payload $globPayload -RepoRoot $script:RepoRoot
            ($outcome.Violations -join ' ') | Should -Not -Match '(?i)anchor|alias' -Because 'a glob-style token following a keyword and space (not a real YAML value-start position) must not be misread as a YAML alias token'
        }

        It 'rejects an oversized payload using a literal test-owned byte count' {
            script:Assert-GCFunctionExists -Name 'ConvertFrom-GCContractBlock'
            # 1,048,576 bytes (1 MiB), chosen independently in this test file --
            # NOT derived from whatever size-cap constant goal-contract-core.ps1
            # defines internally. A real goal contract (prose-sized YAML) is
            # nowhere near this size, so any conforming implementation's cap
            # must reject a payload at or above this literal threshold.
            $oversizedPayload = 'schema_version: 1' + "`n" + ('#' * 1048576)
            $outcome = ConvertFrom-GCContractBlock -Payload $oversizedPayload -RepoRoot $script:RepoRoot
            $outcome.Violations | Should -Not -BeNullOrEmpty -Because 'the size cap must reject an oversized payload as a violation, not throw'
        }

        It 'reports the cap error, not a parse error, when a payload is both oversized and malformed' {
            script:Assert-GCFunctionExists -Name 'ConvertFrom-GCContractBlock'
            # Same literal 1 MiB threshold as the previous test, combined with
            # syntactically invalid YAML, so the cap-precedes-parse ordering is
            # actually exercised rather than incidentally true.
            $oversizedMalformedPayload = 'schema_version: [1, 2' + ('#' * 1048576)
            $outcome = ConvertFrom-GCContractBlock -Payload $oversizedMalformedPayload -RepoRoot $script:RepoRoot
            $outcome.Violations | Should -Not -BeNullOrEmpty -Because 'an oversized-and-malformed payload must still be rejected'
            ($outcome.Violations -join ' ') | Should -Match '(?i)cap|size|byte' -Because 'the cap must be checked before parsing, so the reported violation should name the size/cap reason'
            ($outcome.Violations -join ' ') | Should -Not -Match '(?i)yaml pars|parse error' -Because 'a cap-precedes-parse pipeline must never let the malformed YAML reach the parser and surface a parse error instead'
        }

        It 'throws a loud InvalidOperationException when the powershell-yaml module is unavailable' {
            script:Assert-GCFunctionExists -Name 'ConvertFrom-GCContractBlock'
            Mock Import-Module { }
            Mock Import-Module -ParameterFilter { $Name -eq 'powershell-yaml' } -MockWith { throw 'simulated: powershell-yaml module not found' }

            { ConvertFrom-GCContractBlock -Payload "schema_version: 1`nissue: 872" -RepoRoot $script:RepoRoot } |
                Should -Throw -ExceptionType ([System.InvalidOperationException]) -Because 'frame-validate plan mode is manual-only, so a missing local module must fail loudly, never silently'
            Should -Invoke Import-Module -Times 1 -ParameterFilter { $Name -eq 'powershell-yaml' }
        }

        It 'requires -RepoRoot' {
            script:Assert-GCFunctionExists -Name 'ConvertFrom-GCContractBlock'
            { ConvertFrom-GCContractBlock -Payload "schema_version: 1`nissue: 872" } | Should -Throw -Because '-RepoRoot is mandatory per the phase-containment-core.ps1:577-584 precedent for reading a skills/**/schemas/*.json file'
        }

        It 'round-trips a well-formed contract with zero violations' {
            script:Assert-GCFunctionExists -Name 'ConvertFrom-GCContractBlock'
            $script:SchemaFile | Should -Exist -Because 'the schema file must exist for a real round-trip to validate against'

            $wellFormedPayload = @'
schema_version: 1
issue: 872
contract_hash: "0000000000000000000000000000000000000000000000000000000000000000"
targets:
  - id: T1
    ac_ref: AC1
    category: structure-presence
    check: "pwsh -NoProfile -File .github/scripts/example-check.ps1"
    expected: "exit 0; example check passes"
    falsifier: "A vacuous pass would look like an accumulator silently resetting null to zero."
    source: null
invariants:
  - full-pester-suite-no-new-failures
  - test-diff-integrity
evidence_obligations:
  checkpoint_commits: per-target-green
  run_log: deviation entries + experience observations per checkpoint
  experience_obligations:
    - scenario: S2
      surface: cli
  required_markers: [pipeline-metrics-credits, goal-run-class]
general_experience_standard: |
  Canonical clause and four guardrails, verbatim from #848 D8.
halt_conditions: [unachievable-target, invariant-conflict, budget-exhausted, gate-input-needed, chain-stage-failure]
budget:
  tokens: 100000
  wall_clock: "4h"
  chain_sub_ceiling: 2
  non_convergence: halt-report
'@
            $outcome = ConvertFrom-GCContractBlock -Payload $wellFormedPayload -RepoRoot $script:RepoRoot
            $outcome.Violations | Should -BeNullOrEmpty -Because "a well-formed contract must round-trip cleanly: $($outcome.Violations -join '; ')"
            $outcome.Contract | Should -Not -BeNullOrEmpty
        }

        It 'returns a Violations entry instead of throwing for a comment-only payload that parses to an empty document' {
            script:Assert-GCFunctionExists -Name 'ConvertFrom-GCContractBlock'
            # A comment-only payload makes ConvertFrom-Yaml emit nothing at
            # all (not even an explicit $null document), so piping the
            # result into ConvertTo-Json/Test-Json would throw a
            # ParameterBindingValidationException on a $null -Json argument
            # -- breaching the never-throws-on-schema-failure contract (M4).
            $threw = $false
            $outcome = $null
            try {
                $outcome = ConvertFrom-GCContractBlock -Payload '# just a comment' -RepoRoot $script:RepoRoot
            } catch {
                $threw = $true
            }

            $threw | Should -BeFalse -Because 'a comment-only payload must return a Violations entry, never throw'
            $outcome.Violations | Should -Not -BeNullOrEmpty -Because 'a comment-only payload parses to an empty document, which is a schema-pipeline violation'
        }

        It 'rejects a payload containing a YAML document separator pre-parse (M13)' {
            script:Assert-GCFunctionExists -Name 'ConvertFrom-GCContractBlock'
            # ConvertFrom-Yaml only returns the FIRST document of a
            # multi-document payload; a second document would otherwise ride
            # along unvalidated inside whatever Get-GCContractHash hashes.
            $multiDocPayload = @'
schema_version: 1
issue: 872
---
arbitrary_unvalidated_content: this must not silently ride along
'@
            $outcome = ConvertFrom-GCContractBlock -Payload $multiDocPayload -RepoRoot $script:RepoRoot
            $outcome.Violations | Should -Not -BeNullOrEmpty -Because 'a payload containing a column-0 document separator must be rejected pre-parse, not silently truncated to its first document'
            ($outcome.Violations -join ' ') | Should -Match '(?i)document separator' -Because 'the violation should name the document-separator reason'
        }
    }

    Context 'Get-GCContractHash — golden vectors' {
        It 'hashes the ASCII baseline payload to the independently-derived oracle digest' {
            script:Assert-GCFunctionExists -Name 'Get-GCContractHash'
            $payload = Get-Content -LiteralPath $script:AsciiBaselineInputPath -Raw
            Get-GCContractHash -Payload $payload | Should -Be $script:AsciiBaselineOracleDigest
        }

        It 'hashes the combining-accent (em-dash, section sign) payload to its independently-derived oracle digest' {
            script:Assert-GCFunctionExists -Name 'Get-GCContractHash'
            # Per the frame-slice requirement contract: em-dash and section sign are
            # each single-codepoint in both NFC and NFD, so this vector cannot by
            # itself detect an NFC/NFD normalization gap -- it only pins that this
            # non-ASCII payload hashes to a stable, independently-derived digest.
            $payload = Get-Content -LiteralPath $script:NonAsciiBaselineInputPath -Raw
            Get-GCContractHash -Payload $payload | Should -Be $script:NonAsciiBaselineOracleDigest
        }

        It 'produces the same digest whether contract_hash: is absent, present, or holds a different value (elision invariant)' {
            script:Assert-GCFunctionExists -Name 'Get-GCContractHash'
            $noHashLine       = ($script:AsciiBaselineLines -join "`n") + "`n"
            $hashLinePresent  = Get-Content -LiteralPath $script:AsciiBaselineInputPath -Raw
            $hashLineDifferent = ($hashLinePresent -replace ('0' * 64), ('f' * 64))

            $digestNoHash      = Get-GCContractHash -Payload $noHashLine
            $digestHashPresent = Get-GCContractHash -Payload $hashLinePresent
            $digestHashDiffers = Get-GCContractHash -Payload $hashLineDifferent

            $digestNoHash | Should -Be $script:AsciiBaselineOracleDigest
            $digestHashPresent | Should -Be $script:AsciiBaselineOracleDigest
            $digestHashDiffers | Should -Be $script:AsciiBaselineOracleDigest
        }

        It 'produces the same digest for 0, 1, and 3 trailing newlines (final-newline arity)' {
            script:Assert-GCFunctionExists -Name 'Get-GCContractHash'
            $noTrailingLf    = ($script:AsciiBaselineLines -join "`n")
            $oneTrailingLf   = ($script:AsciiBaselineLines -join "`n") + "`n"
            $threeTrailingLf = ($script:AsciiBaselineLines -join "`n") + "`n`n`n"

            Get-GCContractHash -Payload $noTrailingLf | Should -Be $script:AsciiBaselineOracleDigest
            Get-GCContractHash -Payload $oneTrailingLf | Should -Be $script:AsciiBaselineOracleDigest
            Get-GCContractHash -Payload $threeTrailingLf | Should -Be $script:AsciiBaselineOracleDigest
        }

        It 'strips per-line trailing whitespace before hashing' {
            script:Assert-GCFunctionExists -Name 'Get-GCContractHash'
            $withTrailingWhitespace = @(
                'schema_version: 1   ',
                "issue: 872`t",
                'note: ascii baseline oracle vector for Get-GCContractHash  '
            ) -join "`n"
            $withTrailingWhitespace += "`n"

            Get-GCContractHash -Payload $withTrailingWhitespace | Should -Be $script:AsciiBaselineOracleDigest
        }

        It 'normalizes CRLF line endings to the same digest as LF' {
            script:Assert-GCFunctionExists -Name 'Get-GCContractHash'
            $crlfPayload = ($script:AsciiBaselineLines -join "`r`n") + "`r`n"
            Get-GCContractHash -Payload $crlfPayload | Should -Be $script:AsciiBaselineOracleDigest
        }

        It 'normalizes CR-only line endings to the same digest as LF' {
            script:Assert-GCFunctionExists -Name 'Get-GCContractHash'
            $crOnlyPayload = ($script:AsciiBaselineLines -join "`r") + "`r"
            Get-GCContractHash -Payload $crOnlyPayload | Should -Be $script:AsciiBaselineOracleDigest
        }

        It 'produces the same digest for a BOM-prefixed payload as for the same payload without a BOM' {
            script:Assert-GCFunctionExists -Name 'Get-GCContractHash'
            $withoutBom = Get-Content -LiteralPath $script:AsciiBaselineInputPath -Raw
            $withBom = [string]([char]0xFEFF) + $withoutBom
            Get-GCContractHash -Payload $withBom | Should -Be $script:AsciiBaselineOracleDigest
        }

        It 'does not elide a "contract_hash:" line that is indented inside a block scalar (column-0 disambiguation)' {
            script:Assert-GCFunctionExists -Name 'Get-GCContractHash'
            $variantOne = @"
schema_version: 1
issue: 872
general_experience_standard: |
  first guardrail line
  contract_hash: this-is-prose-not-a-real-field-alpha
  third guardrail line
"@
            $variantTwo = @"
schema_version: 1
issue: 872
general_experience_standard: |
  first guardrail line
  contract_hash: this-is-prose-not-a-real-field-beta
  third guardrail line
"@
            $digestOne = Get-GCContractHash -Payload $variantOne
            $digestTwo = Get-GCContractHash -Payload $variantTwo
            $digestOne | Should -Not -Be $digestTwo -Because 'an indented contract_hash: line is prose content, not the elided field, so differing prose must change the digest'
        }

        It 'elides a "contract_hash :" line with a space before the colon identically to the tight spelling (M14)' {
            script:Assert-GCFunctionExists -Name 'Get-GCContractHash'
            $variantA = @"
schema_version: 1
issue: 872
contract_hash : A
"@
            $variantB = @"
schema_version: 1
issue: 872
contract_hash : B
"@
            $digestA = Get-GCContractHash -Payload $variantA
            $digestB = Get-GCContractHash -Payload $variantB
            $digestA | Should -Be $digestB -Because 'the elision regex must tolerate optional whitespace before the colon, so the digest must be identical whether the field value is A or B'
        }

        It 'reflects the full payload past an indented --> inside a block scalar (no truncation)' {
            script:Assert-GCFunctionExists -Name 'Get-GCContractHash'
            $fullPayload = @"
general_experience_standard: |
  first guardrail line
    --> this indented arrow is prose content, not the terminator
  third guardrail line
tail_marker: GC-TAIL-MARKER-8B2F
"@
            $naivelyTruncatedPayload = @"
general_experience_standard: |
  first guardrail line
    --> this indented arrow is prose content, not the terminator
"@
            $fullDigest = Get-GCContractHash -Payload $fullPayload
            $truncatedDigest = Get-GCContractHash -Payload $naivelyTruncatedPayload
            $fullDigest | Should -Not -Be $truncatedDigest -Because 'a truncated payload must hash differently from the full payload, proving the hash reflects content past an indented -->'
        }
    }

    Context 'Test-GCContractHash' {
        It 'returns $true when the computed hash matches Expected' {
            script:Assert-GCFunctionExists -Name 'Test-GCContractHash'
            $payload = Get-Content -LiteralPath $script:AsciiBaselineInputPath -Raw
            Test-GCContractHash -Payload $payload -Expected $script:AsciiBaselineOracleDigest | Should -BeTrue
        }

        It 'returns $false when the computed hash does not match Expected' {
            script:Assert-GCFunctionExists -Name 'Test-GCContractHash'
            $payload = Get-Content -LiteralPath $script:AsciiBaselineInputPath -Raw
            Test-GCContractHash -Payload $payload -Expected ('f' * 64) | Should -BeFalse
        }
    }
}
