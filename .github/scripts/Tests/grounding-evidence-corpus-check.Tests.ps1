#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
.SYNOPSIS
    Corpus-measurement classifier tests for issue #866 AC7.

.DESCRIPTION
    This file's charter is DISTINCT from design-grounding-discipline.Tests.ps1,
    whose docstring scopes it to the three-file producer/persist/consumer
    contract chain (skills/design-exploration/SKILL.md,
    agents/Solution-Designer.agent.md, skills/upstream-onboarding/SKILL.md).
    This file instead locks the behavior of a standalone CORPUS MEASUREMENT
    script that scans an arbitrary GitHub issue body and classifies it into
    exactly one of three buckets describing whether a persisted Grounding
    Evidence block is present:

      - canonical:     the <!-- grounding-evidence --> sentinel immediately
                        followed (blank lines allowed) by the
                        **Grounding Evidence** bold heading, outside any
                        fenced or inline code span.
      - non-canonical: some other Grounding Evidence heading shape is
                        present (e.g. a bare H2, or a bold heading with no
                        sentinel), but not the canonical sentinel+heading
                        pair.
      - absent:        neither of the above.

    Detection MUST be structural, not substring-counting: a body that
    merely MENTIONS the sentinel or bold literal multiple times in prose
    (acceptance criteria text, design-decision prose, quoted contract
    excerpts, etc.) without ever containing a real persisted block must
    classify `absent`. Fixture 5 below is the load-bearing anti-vacuity
    case that a naive `$body -match '<!-- grounding-evidence -->'`
    classifier would wrongly call `canonical`.

    Genuine-red (issue #866 plan step s4): the script under test,
    .github/scripts/grounding-evidence-corpus-check.ps1, does NOT exist
    yet -- it is implemented in a later step (s5). Every test below is
    expected to fail right now because dot-sourcing that path throws
    "cannot find path" / "does not exist". This file intentionally
    ships red so the s5 implementer has a locked, failing contract to
    turn green.

    CONTRACT for s5 (chosen so this test file is unambiguous):
      Script path:     .github/scripts/grounding-evidence-corpus-check.ps1
                        (top-level script, not under lib/ -- mirrors the
                        existing single-file, dot-sourceable convention
                        used by .github/scripts/reporting-economy-spotcheck.ps1,
                        which is dot-sourced directly by its sibling
                        Tests.ps1 rather than split into a lib/*-core.ps1
                        companion).
      Function:         Get-GroundingEvidenceBucket
      Signature:        Get-GroundingEvidenceBucket -BodyText <string>
      Return:            one of the literal strings 'canonical',
                        'non-canonical', 'absent' (a plain [string], not
                        an enum or object -- Should -Be does a literal
                        string comparison below).
      Dot-source safety: the script MUST guard its top-level/main
                        execution block behind the same
                        `$MyInvocation.InvocationName -eq '.'` idiom used
                        by .github/scripts/phase-containment-emission-check.ps1
                        (i.e. dot-sourcing this file for its function
                        MUST NOT trigger any CLI parsing, gh calls, or
                        exit statements -- only Get-GroundingEvidenceBucket
                        becomes available in the caller's scope).
#>

Describe 'grounding-evidence-corpus-check classifier' {

    BeforeAll {
        $script:RepoRoot   = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
        $script:ScriptPath = Join-Path $script:RepoRoot '.github/scripts/grounding-evidence-corpus-check.ps1'

        # Explicit `r`n literal (NOT a here-string, which PowerShell may
        # normalize to LF-only) -- used to build genuinely CRLF-terminated
        # fixture bodies below by joining line arrays with this separator.
        $script:CRLF = "`r`n"

        # NOTE (genuine-red, s4): this dot-source is expected to THROW right
        # now because $script:ScriptPath does not exist yet -- s5 implements
        # it. Wrapping in try/catch so Pester's discovery/BeforeAll phase
        # does not abort the whole file; each It block below independently
        # re-asserts the function is callable, which is what actually fails.
        try {
            . $script:ScriptPath
        }
        catch {
            $script:DotSourceError = $_
        }
    }

    # --- Fixture 1: canonical ---
    # Sentinel immediately followed (one blank line -- allowed per contract)
    # by the bold heading, with a real table underneath.
    It 'classifies a real persisted sentinel+bold-heading+table block as canonical' {
        $body = @'
## Design Decisions

Some ordinary design prose above the block.

<!-- grounding-evidence -->

**Grounding Evidence** (HEAD: abc1234)

| Claim | Evidence |
| --- | --- |
| The API returns 404 for missing users | src/api/users.py:42 |
| Retry logic caps at 3 attempts | src/api/retry.py:18 |

More ordinary design prose below the block.
'@
        Get-GroundingEvidenceBucket -BodyText $body | Should -Be 'canonical'
    }

    # --- Fixture 2: non-canonical, H2 form (mirrors issue #817's improvisation) ---
    # A bare H2 heading with a table, but no sentinel and no bold heading.
    It 'classifies a bare H2 "## Grounding Evidence" heading with a table (no sentinel, no bold heading) as non-canonical' {
        $body = @'
## Problem Statement

We need to track where design claims come from.

## Grounding Evidence

| Claim | Evidence |
| --- | --- |
| Config defaults to 30s timeout | config/defaults.yaml:9 |

## Acceptance Criteria

- AC1: timeouts are configurable
'@
        Get-GroundingEvidenceBucket -BodyText $body | Should -Be 'non-canonical'
    }

    # --- Fixture 3: non-canonical, bold-without-sentinel form (mirrors issue #842's improvisation) ---
    # The bold heading and a table are present, but the sentinel never appears anywhere.
    It 'classifies a bold "**Grounding Evidence**" heading with a table but NO sentinel anywhere as non-canonical' {
        $body = @'
## Design Decisions

D1: use exponential backoff for retries.

**Grounding Evidence** (HEAD: def5678)

| Claim | Evidence |
| --- | --- |
| Backoff base is 200ms | src/retry/backoff.py:11 |

D2: cap total retries at 5.
'@
        Get-GroundingEvidenceBucket -BodyText $body | Should -Be 'non-canonical'
    }

    # --- Fixture 4: absent ---
    # Normal design-issue content with no Grounding Evidence material of any kind.
    It 'classifies an ordinary design body with no Grounding Evidence material of any kind as absent' {
        $body = @'
## Problem Statement

Users cannot filter the dashboard by date range, which forces them to
scroll through the entire history to find recent events.

## Decisions

D1: add a date-range picker component to the dashboard toolbar.
D2: default the range to "last 7 days" on first load.

## Acceptance Criteria

- AC1: the picker persists the selected range across page reloads.
- AC2: an invalid range (end before start) shows an inline validation error.

## Rejected Alternatives

- A calendar-heatmap view was considered and rejected as higher effort for
  unclear benefit at this stage.
'@
        Get-GroundingEvidenceBucket -BodyText $body | Should -Be 'absent'
    }

    # --- Fixture 5: adversarial prose-mention (the anti-vacuity fixture) ---
    # The literal tokens '<!-- grounding-evidence -->' and '**Grounding
    # Evidence**' each appear multiple times, scattered across different
    # sentences discussing the CONTRACT itself -- but the sentinel is never
    # immediately followed by the bold heading and a real table. Loosely
    # based on issue #866's own body (which has exactly this problem: several
    # prose mentions around zero-to-one real instance). A naive
    # substring-count classifier would wrongly call this 'canonical'.
    It 'classifies a body that only discusses the Grounding Evidence CONTRACT in prose (sentinel and bold literal each mentioned multiple times, no real persisted block) as absent -- anti-vacuity regression test' {
        $body = @'
## Problem Statement

Grounding evidence is sometimes improvised into a non-canonical shape
(see #817's `## Grounding Evidence` H2 and #842's bare `**Grounding
Evidence**` bold heading), so downstream consumers cannot reliably find
the canonical `<!-- grounding-evidence -->` sentinel.

## Decisions

D2 canonical shape: the `<!-- grounding-evidence -->` sentinel line
immediately above the `**Grounding Evidence** (HEAD: {sha})` bold
heading, followed by a table of claim/evidence rows. Any body missing
the sentinel, or missing the bold heading, or where the two are not
adjacent, is non-canonical or absent -- never canonical.

## Acceptance Criteria

- AC4: a `<!-- grounding-evidence -->` sentinel exists in the canonical
  template shipped in skills/design-exploration/SKILL.md, immediately
  above a `**Grounding Evidence**` bold heading placeholder.
- AC7: a corpus-check script classifies real issue bodies into
  canonical / non-canonical / absent, and must not be fooled by prose
  that merely mentions `<!-- grounding-evidence -->` or
  `**Grounding Evidence**` without an actual persisted block -- this is
  itself such a body, used as the regression fixture for that rule.

## Rejected Alternatives

- A substring-count heuristic (mentions of `<!-- grounding-evidence -->`
  >= 1) was rejected: this exact paragraph would falsely register as
  canonical under that rule, which is the bug AC7 exists to prevent.
'@
        Get-GroundingEvidenceBucket -BodyText $body | Should -Be 'absent'
    }

    # --- Fixture 6: CRLF-fenced canonical pair (CM1 regression) ---
    # The same sentinel+bold-heading+table shape as Fixture 1, but wrapped
    # in a CRLF-terminated triple-backtick fence. Locks CM1: in .NET,
    # multiline `$` anchors immediately before `\n`, and `[^\r\n]*` stops
    # before `\r`, so a fence-line regex evaluated against unnormalized CRLF
    # text never matches the fence -- the block would then be treated as
    # unfenced prose and misclassify canonical instead of the correct
    # absent (both occurrences are inside a code fence).
    It 'classifies a canonical pair wrapped in a CRLF triple-backtick fence as absent (CM1 regression)' {
        $lines = @(
            '## Design Decisions',
            '',
            '```text',
            '<!-- grounding-evidence -->',
            '',
            '**Grounding Evidence** (HEAD: abc1234)',
            '',
            '| Claim | Evidence |',
            '| --- | --- |',
            '| The API returns 404 for missing users | src/api/users.py:42 |',
            '```',
            '',
            'More ordinary design prose below the block.'
        )
        $body = $lines -join $script:CRLF
        $body | Should -Match "`r`n"
        Get-GroundingEvidenceBucket -BodyText $body | Should -Be 'absent'
    }

    # --- Fixture 7: CRLF-fenced canonical pair, tilde fence (CM1 regression) ---
    # Same shape as Fixture 6, but with a `~~~` fence instead of triple
    # backticks -- locks that the fence-line regex's CRLF fix applies to
    # both fence characters, not just backticks.
    It 'classifies a canonical pair wrapped in a CRLF tilde fence as absent (CM1 regression)' {
        $lines = @(
            '## Design Decisions',
            '',
            '~~~text',
            '<!-- grounding-evidence -->',
            '',
            '**Grounding Evidence** (HEAD: abc1234)',
            '',
            '| Claim | Evidence |',
            '| --- | --- |',
            '| The API returns 404 for missing users | src/api/users.py:42 |',
            '~~~',
            '',
            'More ordinary design prose below the block.'
        )
        $body = $lines -join $script:CRLF
        $body | Should -Match "`r`n"
        Get-GroundingEvidenceBucket -BodyText $body | Should -Be 'absent'
    }

    # --- Fixture 8: CRLF version of Fixture 1, NOT fenced (CM1 no-regression check) ---
    # Confirms CRLF normalization does not break the normal, unfenced
    # canonical case -- the sentinel and bold heading are still detected as
    # adjacent once line endings are normalized.
    It 'classifies a CRLF-terminated (unfenced) sentinel+bold-heading+table block as canonical' {
        $lines = @(
            '## Design Decisions',
            '',
            'Some ordinary design prose above the block.',
            '',
            '<!-- grounding-evidence -->',
            '',
            '**Grounding Evidence** (HEAD: abc1234)',
            '',
            '| Claim | Evidence |',
            '| --- | --- |',
            '| The API returns 404 for missing users | src/api/users.py:42 |',
            '| Retry logic caps at 3 attempts | src/api/retry.py:18 |',
            '',
            'More ordinary design prose below the block.'
        )
        $body = $lines -join $script:CRLF
        $body | Should -Match "`r`n"
        Get-GroundingEvidenceBucket -BodyText $body | Should -Be 'canonical'
    }

    # --- Fixture 9: sentinel and bold heading present but paragraph-separated (issue #863 shape) ---
    # Both the sentinel and the bold heading are present, both outside any
    # code span, but a genuine prose paragraph sits between them -- so they
    # are not truly adjacent. This is the real issue #863 shape: the tokens
    # are present and unwrapped, but not persisted as the canonical pair.
    It 'classifies a sentinel and bold heading separated by an intervening prose paragraph as non-canonical' {
        $lines = @(
            '## Design Decisions',
            '',
            '<!-- grounding-evidence -->',
            '',
            'This paragraph of ordinary prose sits between the sentinel and the heading, so they are not truly adjacent.',
            '',
            '**Grounding Evidence** (HEAD: abc1234)',
            '',
            '| Claim | Evidence |',
            '| --- | --- |',
            '| The API returns 404 for missing users | src/api/users.py:42 |'
        )
        $body = $lines -join $script:CRLF
        Get-GroundingEvidenceBucket -BodyText $body | Should -Be 'non-canonical'
    }
}
