#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
.SYNOPSIS
    Pester 5 RED-phase unit tests for measure-guidance-complexity.ps1.

.DESCRIPTION
    Contract under test:
    - Accepts -ConfigPath (default skills/calibration-pipeline/assets/guidance-complexity.json)
      - Accepts -AgentsPath (default agents/*.agent.md)
      - Counts directive keywords case-insensitively, whole-word only:
          MUST, NEVER, ALWAYS, REQUIRED, MANDATORY
      - "mustard" and "should" do NOT count (not whole-word directive keywords)
      - Counts checklist items: - [ ], - [x], - [X]
      - Checklist items contribute to total_directives
      - Fenced code block exclusion: lines between ``` or ```lang fences NOT counted
      - 4-space indented blocks ARE counted
      - Inline single-backtick code on normal lines IS counted
      - Override comments: lines containing <!-- complexity-override: ... --> are skipped
      - JSON output to stdout:
          agents_over_ceiling  — array of filenames exceeding the ceiling
          agents               — array of per-agent detail:
              file, total_directives, checklist_items,
              section_count, max_nesting_depth, sections
          sections             — array of { heading, directives } per ## heading
      - Always exits 0 (soft ceilings — advisory only)
      - Missing config: uses built-in default ceiling (150), does not throw,
        output includes some field/text indicating default was used

    Isolation: all tests write temp .agent.md files to a session-scoped temp
    root. No real agents/*.agent.md files are used.
#>

Describe 'measure-guidance-complexity.ps1' {

    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
        $script:LibFile = Join-Path $script:RepoRoot 'skills\guidance-measurement\scripts\measure-guidance-complexity-core.ps1'
        . $script:LibFile

        # Session-scoped temp root — all per-test dirs live under here
        $script:TempRoot = Join-Path ([System.IO.Path]::GetTempPath()) `
            "pester-complexity-$([System.Guid]::NewGuid().ToString('N'))"
        New-Item -ItemType Directory -Path $script:TempRoot -Force | Out-Null

        # ---------------------------------------------------------------
        # Helper: fresh isolated temp dir for a single test
        # ---------------------------------------------------------------
        $script:NewTempDir = {
            $dir = Join-Path $script:TempRoot ([System.Guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            return $dir
        }

        # ---------------------------------------------------------------
        # Helper: write a temp agent .md file; returns its full path
        # ---------------------------------------------------------------
        $script:NewAgentFile = {
            param([string]$Dir, [string]$Name, [string]$Content)
            $path = Join-Path $Dir $Name
            Set-Content -Path $path -Value $Content -Encoding UTF8
            return $path
        }

        # ---------------------------------------------------------------
        # Helper: write a guidance-complexity.json config; returns path
        # ---------------------------------------------------------------
        $script:WriteConfig = {
            param([string]$Dir, [hashtable]$Config)
            $path = Join-Path $Dir 'guidance-complexity.json'
            $Config | ConvertTo-Json -Depth 10 | Set-Content -Path $path -Encoding UTF8
            return $path
        }

        # ---------------------------------------------------------------
        # Helper: invoke Invoke-MeasureGuidanceComplexity in-process.
        # Returns @{ ExitCode; Raw (stdout JSON) }
        # ---------------------------------------------------------------
        $script:Invoke = {
            param(
                [string]$AgentsPath,
                [string]$ConfigPath = ''
            )
            $params = @{ AgentsPath = $AgentsPath }
            if ($ConfigPath) { $params['ConfigPath'] = $ConfigPath }
            $invokeResult = $null
            try {
                $invokeResult = Invoke-MeasureGuidanceComplexity @params
            }
            catch {
                $invokeResult = @{ ExitCode = 0; Output = '{"config_source":"error","agents_over_ceiling":[],"agents":[]}'; Error = $_.ToString() }
            }
            return @{ ExitCode = $invokeResult.ExitCode; Raw = $invokeResult.Output.Trim() }
        }

        # ---------------------------------------------------------------
        # Shared high-ceiling config (ceiling 1000 — never triggers)
        # Used by tests that only care about counting, not ceiling enforcement
        # ---------------------------------------------------------------
        $script:SharedConfigDir = & $script:NewTempDir
        $script:SharedConfigPath = & $script:WriteConfig -Dir $script:SharedConfigDir -Config @{
            version         = 1
            default_ceiling = @{ max_directives = 1000 }
            ceilings        = @{}
        }
    }

    AfterAll {
        try {
            if (Test-Path $script:TempRoot) {
                Remove-Item -Recurse -Force -Path $script:TempRoot
            }
        }
        finally {
            # Suppress removal errors so AfterAll never throws
        }
    }

    # ==================================================================
    # 1. Directive keyword counting
    # ==================================================================
    Context 'directive keyword counting' {

        It 'counts one occurrence each of MUST, NEVER, ALWAYS, REQUIRED, MANDATORY as five directives' {
            $dir = & $script:NewTempDir
            $content = @'
# Test Agent

You MUST do this.
You NEVER do that.
You ALWAYS consider this.
This step is REQUIRED.
This step is MANDATORY.
'@
            & $script:NewAgentFile -Dir $dir -Name 'Test.agent.md' -Content $content | Out-Null

            $result = & $script:Invoke -AgentsPath "$dir\*.agent.md" -ConfigPath $script:SharedConfigPath
            $json = $result.Raw | ConvertFrom-Json
            $agent = @($json.agents) | Where-Object { $_.file -match 'Test\.agent\.md' }

            $agent.total_directives | Should -Be 5 -Because 'MUST + NEVER + ALWAYS + REQUIRED + MANDATORY = 5 distinct directive keywords'
        }

        It 'does not count "mustard" as MUST because it is not a whole-word match' {
            $dir = & $script:NewTempDir
            # "mustard" embeds the letters MUST but is not the whole word MUST
            $content = @'
# Test Agent

Put mustard on the sandwich.
Wholegrain mustard is never acceptable here.
'@
            & $script:NewAgentFile -Dir $dir -Name 'Test.agent.md' -Content $content | Out-Null

            $result = & $script:Invoke -AgentsPath "$dir\*.agent.md" -ConfigPath $script:SharedConfigPath
            $json = $result.Raw | ConvertFrom-Json
            $agent = @($json.agents) | Where-Object { $_.file -match 'Test\.agent\.md' }

            # NEVER is a directive (whole word); MUST is NOT (only appears inside "mustard")
            $agent.total_directives | Should -Be 1 -Because '"mustard" must not match MUST; only standalone NEVER counts'
        }

        It 'does not count "should" as a directive keyword' {
            $dir = & $script:NewTempDir
            $content = @'
# Test Agent

You should consider this.
You probably should try that too.
'@
            & $script:NewAgentFile -Dir $dir -Name 'Test.agent.md' -Content $content | Out-Null

            $result = & $script:Invoke -AgentsPath "$dir\*.agent.md" -ConfigPath $script:SharedConfigPath
            $json = $result.Raw | ConvertFrom-Json
            $agent = @($json.agents) | Where-Object { $_.file -match 'Test\.agent\.md' }

            $agent.total_directives | Should -Be 0 -Because '"should" is not in the counted keyword set'
        }

        It 'counts directive keywords case-insensitively' {
            $dir = & $script:NewTempDir
            $content = @'
# Test Agent

must do this (lowercase).
Must do that (sentence case).
MUST also do this (uppercase).
'@
            & $script:NewAgentFile -Dir $dir -Name 'Test.agent.md' -Content $content | Out-Null

            $result = & $script:Invoke -AgentsPath "$dir\*.agent.md" -ConfigPath $script:SharedConfigPath
            $json = $result.Raw | ConvertFrom-Json
            $agent = @($json.agents) | Where-Object { $_.file -match 'Test\.agent\.md' }

            $agent.total_directives | Should -Be 3 -Because 'must/Must/MUST are the same keyword; all three must be counted'
        }
    }

    # ==================================================================
    # 2. Checklist item counting
    # ==================================================================
    Context 'checklist item counting' {

        It 'counts - [ ] unchecked items' {
            $dir = & $script:NewTempDir
            $content = @'
# Test Agent

- [ ] unchecked item one
- [ ] unchecked item two
'@
            & $script:NewAgentFile -Dir $dir -Name 'Test.agent.md' -Content $content | Out-Null

            $result = & $script:Invoke -AgentsPath "$dir\*.agent.md" -ConfigPath $script:SharedConfigPath
            $json = $result.Raw | ConvertFrom-Json
            $agent = @($json.agents) | Where-Object { $_.file -match 'Test\.agent\.md' }

            $agent.checklist_items | Should -Be 2 -Because '- [ ] items must be counted as checklist items'
        }

        It 'counts - [x] and - [X] checked items' {
            $dir = & $script:NewTempDir
            $content = @'
# Test Agent

- [x] lowercase-x checked item
- [X] uppercase-X checked item
'@
            & $script:NewAgentFile -Dir $dir -Name 'Test.agent.md' -Content $content | Out-Null

            $result = & $script:Invoke -AgentsPath "$dir\*.agent.md" -ConfigPath $script:SharedConfigPath
            $json = $result.Raw | ConvertFrom-Json
            $agent = @($json.agents) | Where-Object { $_.file -match 'Test\.agent\.md' }

            $agent.checklist_items | Should -Be 2 -Because '- [x] and - [X] must both count as checklist items'
        }

        It 'includes checklist items in total_directives alongside keyword directives' {
            $dir = & $script:NewTempDir
            $content = @'
# Test Agent

You MUST do this.
- [ ] verify step one
- [x] verify step two
'@
            & $script:NewAgentFile -Dir $dir -Name 'Test.agent.md' -Content $content | Out-Null

            $result = & $script:Invoke -AgentsPath "$dir\*.agent.md" -ConfigPath $script:SharedConfigPath
            $json = $result.Raw | ConvertFrom-Json
            $agent = @($json.agents) | Where-Object { $_.file -match 'Test\.agent\.md' }

            $agent.checklist_items  | Should -Be 2 -Because '2 checklist items'
            $agent.total_directives | Should -Be 3 -Because '1 MUST + 2 checklist items = 3 total_directives'
        }
    }

    # ==================================================================
    # 2a. Checklist + keyword overlap (design-intent documentation)
    # ==================================================================
    Context 'checklist line that also contains a directive keyword' {

        It 'counts a checklist line with a directive keyword as 2 directives (checklist + keyword signals are cumulative)' {
            $dir = & $script:NewTempDir
            $content = @'
# Test Agent

- [ ] MUST verify this.
'@
            & $script:NewAgentFile -Dir $dir -Name 'Test.agent.md' -Content $content | Out-Null

            $result = & $script:Invoke -AgentsPath "$dir\*.agent.md" -ConfigPath $script:SharedConfigPath
            $json = $result.Raw | ConvertFrom-Json
            $agent = @($json.agents) | Where-Object { $_.file -match 'Test\.agent\.md' }

            # Design intent: checklist signal (1) + keyword signal (1) = 2 total_directives.
            # This documents that the counting is cumulative, not deduplicated.
            $agent.total_directives | Should -Be 2 -Because 'a checklist line containing MUST counts as 2 directives: 1 checklist item + 1 keyword'
            $agent.checklist_items  | Should -Be 1 -Because 'the line is still one checklist item'
        }
    }

    # ==================================================================
    # 3. Fenced code block exclusion
    # ==================================================================
    Context 'fenced code block exclusion' {

        It 'does not count a directive keyword inside a plain fenced code block' {
            $dir = & $script:NewTempDir
            # Single-quoted heredoc: triple backticks are literal characters
            $content = @'
# Test Agent

```
You MUST not count this directive inside the fence.
```
'@
            & $script:NewAgentFile -Dir $dir -Name 'Test.agent.md' -Content $content | Out-Null

            $result = & $script:Invoke -AgentsPath "$dir\*.agent.md" -ConfigPath $script:SharedConfigPath
            $json = $result.Raw | ConvertFrom-Json
            $agent = @($json.agents) | Where-Object { $_.file -match 'Test\.agent\.md' }

            $agent.total_directives | Should -Be 0 -Because 'MUST between ``` fences must not be counted'
        }

        It 'does not count directives inside a language-tagged fenced code block' {
            $dir = & $script:NewTempDir
            $content = @'
# Test Agent

```powershell
You MUST not count this.
ALWAYS skip this too.
```
'@
            & $script:NewAgentFile -Dir $dir -Name 'Test.agent.md' -Content $content | Out-Null

            $result = & $script:Invoke -AgentsPath "$dir\*.agent.md" -ConfigPath $script:SharedConfigPath
            $json = $result.Raw | ConvertFrom-Json
            $agent = @($json.agents) | Where-Object { $_.file -match 'Test\.agent\.md' }

            $agent.total_directives | Should -Be 0 -Because 'MUST and ALWAYS inside a ```powershell fence must not be counted'
        }

        It 'counts a directive on a normal line that also contains inline single-backtick code' {
            $dir = & $script:NewTempDir
            $content = @'
# Test Agent

You MUST call `SomeFunction()` to proceed.
'@
            & $script:NewAgentFile -Dir $dir -Name 'Test.agent.md' -Content $content | Out-Null

            $result = & $script:Invoke -AgentsPath "$dir\*.agent.md" -ConfigPath $script:SharedConfigPath
            $json = $result.Raw | ConvertFrom-Json
            $agent = @($json.agents) | Where-Object { $_.file -match 'Test\.agent\.md' }

            $agent.total_directives | Should -Be 1 -Because 'MUST on a line with inline backtick code is still a normal line and must be counted'
        }

        It 'counts a directive in a 4-space indented block' {
            $dir = & $script:NewTempDir
            $content = @'
# Test Agent

Normal line before.
    You MUST do this (4-space indent is not a fenced block).
Normal line after.
'@
            & $script:NewAgentFile -Dir $dir -Name 'Test.agent.md' -Content $content | Out-Null

            $result = & $script:Invoke -AgentsPath "$dir\*.agent.md" -ConfigPath $script:SharedConfigPath
            $json = $result.Raw | ConvertFrom-Json
            $agent = @($json.agents) | Where-Object { $_.file -match 'Test\.agent\.md' }

            $agent.total_directives | Should -Be 1 -Because '4-space indented lines are NOT excluded; MUST must be counted'
        }

        It 'does not count directives inside a 4-backtick fenced code block' {
            $dir = & $script:NewTempDir
            $content = @'
# Test Agent

````markdown
You MUST not count this inside a 4-backtick fence.
ALWAYS skip this too.
````
'@
            & $script:NewAgentFile -Dir $dir -Name 'Test.agent.md' -Content $content | Out-Null

            $result = & $script:Invoke -AgentsPath "$dir\*.agent.md" -ConfigPath $script:SharedConfigPath
            $json = $result.Raw | ConvertFrom-Json
            $agent = @($json.agents) | Where-Object { $_.file -match 'Test\.agent\.md' }

            $agent.total_directives | Should -Be 0 -Because 'MUST and ALWAYS inside a ```` fence must not be counted'
        }

        It 'does not count directives after a nested ``` inside a 4-backtick fence' {
            $dir = & $script:NewTempDir
            $content = @'
# Test Agent

````markdown
Here is an example fence:
```
You MUST not count this — inside nested ``` within ````.
```
Still inside the 4-backtick fence — ALWAYS skip this too.
````

You MUST count this — outside the 4-backtick fence.
'@
            & $script:NewAgentFile -Dir $dir -Name 'Test.agent.md' -Content $content | Out-Null

            $result = & $script:Invoke -AgentsPath "$dir\*.agent.md" -ConfigPath $script:SharedConfigPath
            $json = $result.Raw | ConvertFrom-Json
            $agent = @($json.agents) | Where-Object { $_.file -match 'Test\.agent\.md' }

            $agent.total_directives | Should -Be 1 -Because 'only the MUST outside the 4-backtick fence should be counted; nested ``` must not prematurely close the outer fence'
        }

        It 'does not count directives inside a tilde fenced code block' {
            $dir = & $script:NewTempDir
            $content = @'
# Test Agent

~~~
You MUST do this.
ALWAYS verify.
~~~
'@
            & $script:NewAgentFile -Dir $dir -Name 'Test.agent.md' -Content $content | Out-Null

            $result = & $script:Invoke -AgentsPath "$dir\*.agent.md" -ConfigPath $script:SharedConfigPath
            $json = $result.Raw | ConvertFrom-Json
            $agent = @($json.agents) | Where-Object { $_.file -match 'Test\.agent\.md' }

            $agent.total_directives | Should -Be 0 -Because 'MUST and ALWAYS inside a ~~~ tilde fence must not be counted'
        }

        It 'does not count directives inside an indented fence opener block' {
            $dir = & $script:NewTempDir
            $content = @'
# Test Agent

   ```powershell
You MUST not.
ALWAYS check.
   ```
'@
            & $script:NewAgentFile -Dir $dir -Name 'Test.agent.md' -Content $content | Out-Null

            $result = & $script:Invoke -AgentsPath "$dir\*.agent.md" -ConfigPath $script:SharedConfigPath
            $json = $result.Raw | ConvertFrom-Json
            $agent = @($json.agents) | Where-Object { $_.file -match 'Test\.agent\.md' }

            $agent.total_directives | Should -Be 0 -Because 'MUST and ALWAYS inside an indented fence opener block must not be counted'
        }
    }

    # ==================================================================
    # 4. Per-agent breakdown
    # ==================================================================
    Context 'per-agent breakdown' {

        It 'produces one agents entry per input file when multiple files are provided' {
            $dir = & $script:NewTempDir
            & $script:NewAgentFile -Dir $dir -Name 'AgentA.agent.md' -Content "# A`nYou MUST do this." | Out-Null
            & $script:NewAgentFile -Dir $dir -Name 'AgentB.agent.md' -Content "# B`nYou NEVER do that." | Out-Null

            $result = & $script:Invoke -AgentsPath "$dir\*.agent.md" -ConfigPath $script:SharedConfigPath
            $json = $result.Raw | ConvertFrom-Json

            @($json.agents).Count | Should -Be 2 -Because 'two input files must produce two agent entries in the agents array'
        }

        It 'each agent entry includes file, total_directives, and checklist_items properties' {
            $dir = & $script:NewTempDir
            $content = @'
# Test Agent

You MUST do this.
- [ ] verify this
'@
            & $script:NewAgentFile -Dir $dir -Name 'MyAgent.agent.md' -Content $content | Out-Null

            $result = & $script:Invoke -AgentsPath "$dir\*.agent.md" -ConfigPath $script:SharedConfigPath
            $json = $result.Raw | ConvertFrom-Json
            $agent = @($json.agents) | Where-Object { $_.file -match 'MyAgent\.agent\.md' }

            $agent                           | Should -Not -BeNullOrEmpty -Because 'agents array must have an entry matching the input filename'
            $agent.PSObject.Properties.Name  | Should -Contain 'file'            -Because 'each agent entry must include a file property'
            $agent.PSObject.Properties.Name  | Should -Contain 'total_directives' -Because 'each agent entry must include total_directives'
            $agent.PSObject.Properties.Name  | Should -Contain 'checklist_items'  -Because 'each agent entry must include checklist_items'
            $agent.total_directives          | Should -Be 2 -Because '1 MUST + 1 checklist item = 2 total_directives'
            $agent.checklist_items           | Should -Be 1 -Because '1 checklist item'
        }
    }

    # ==================================================================
    # 5. Per-section breakdown
    # ==================================================================
    Context 'per-section breakdown' {

        It 'captures directives grouped by ## heading in the sections array' {
            $dir = & $script:NewTempDir
            $content = @'
# Test Agent

## Section One

You MUST do this.

## Section Two

You NEVER do that.
You ALWAYS consider this.
'@
            & $script:NewAgentFile -Dir $dir -Name 'Test.agent.md' -Content $content | Out-Null

            $result = & $script:Invoke -AgentsPath "$dir\*.agent.md" -ConfigPath $script:SharedConfigPath
            $json = $result.Raw | ConvertFrom-Json
            $agent = @($json.agents) | Where-Object { $_.file -match 'Test\.agent\.md' }

            $agent.sections | Should -Not -BeNullOrEmpty -Because 'sections array must be populated when ## headings are present'

            $sec1 = @($agent.sections) | Where-Object { $_.heading -match 'Section One' }
            $sec1 | Should -Not -BeNullOrEmpty -Because 'sections must include an entry for Section One'
            $sec1.directives | Should -Be 1 -Because 'Section One contains 1 MUST'

            $sec2 = @($agent.sections) | Where-Object { $_.heading -match 'Section Two' }
            $sec2 | Should -Not -BeNullOrEmpty -Because 'sections must include an entry for Section Two'
            $sec2.directives | Should -Be 2 -Because 'Section Two contains NEVER + ALWAYS = 2 directives'
        }

        It 'captures preamble directives (before first ## heading) in the total and sections tally' {
            $dir = & $script:NewTempDir
            $content = @'
# Test Agent

You MUST read this preamble first.

## First Section

Nothing directive-worthy here.
'@
            & $script:NewAgentFile -Dir $dir -Name 'Test.agent.md' -Content $content | Out-Null

            $result = & $script:Invoke -AgentsPath "$dir\*.agent.md" -ConfigPath $script:SharedConfigPath
            $json = $result.Raw | ConvertFrom-Json
            $agent = @($json.agents) | Where-Object { $_.file -match 'Test\.agent\.md' }

            $agent.total_directives | Should -Be 1 -Because 'preamble MUST must contribute to total_directives'

            # Preamble directive must be captured somewhere in sections so the sum matches total
            $sectionSum = (@($agent.sections) | Measure-Object -Property directives -Sum).Sum
            $sectionSum | Should -Be 1 -Because 'preamble directive must appear in the sections tally'
        }
    }

    # ==================================================================
    # 6. Ceiling comparison
    # ==================================================================
    Context 'ceiling comparison' {

        It 'includes agent filename in agents_over_ceiling when directive count exceeds the ceiling' {
            $dir = & $script:NewTempDir
            $content = @'
# Heavy Agent

You MUST do this.
You NEVER do that.
You ALWAYS consider this.
'@
            & $script:NewAgentFile -Dir $dir -Name 'HeavyAgent.agent.md' -Content $content | Out-Null
            $configPath = & $script:WriteConfig -Dir $dir -Config @{
                version         = 1
                default_ceiling = @{ max_directives = 2 }
                ceilings        = @{}
            }

            $result = & $script:Invoke -AgentsPath "$dir\*.agent.md" -ConfigPath $configPath
            $json = $result.Raw | ConvertFrom-Json

            @($json.agents_over_ceiling) | Should -Contain 'HeavyAgent.agent.md' `
                -Because '3 directives exceeds the ceiling of 2; filename must appear in agents_over_ceiling'
        }

        It 'does not include agent filename in agents_over_ceiling when directive count is within the ceiling' {
            $dir = & $script:NewTempDir
            $content = @'
# Light Agent

You MUST do this.
'@
            & $script:NewAgentFile -Dir $dir -Name 'LightAgent.agent.md' -Content $content | Out-Null
            $configPath = & $script:WriteConfig -Dir $dir -Config @{
                version         = 1
                default_ceiling = @{ max_directives = 100 }
                ceilings        = @{}
            }

            $result = & $script:Invoke -AgentsPath "$dir\*.agent.md" -ConfigPath $configPath
            $json = $result.Raw | ConvertFrom-Json

            @($json.agents_over_ceiling) | Should -Not -Contain 'LightAgent.agent.md' `
                -Because '1 directive is well under the ceiling of 100'
        }

        It 'exits 0 even when agents exceed the ceiling' {
            $dir = & $script:NewTempDir
            # 11 MUSTs — well above a ceiling of 1
            $content = "# Over-Ceiling Agent`nMUST MUST MUST MUST MUST MUST MUST MUST MUST MUST MUST"
            & $script:NewAgentFile -Dir $dir -Name 'OverAgent.agent.md' -Content $content | Out-Null
            $configPath = & $script:WriteConfig -Dir $dir -Config @{
                version         = 1
                default_ceiling = @{ max_directives = 1 }
                ceilings        = @{}
            }

            $result = & $script:Invoke -AgentsPath "$dir\*.agent.md" -ConfigPath $configPath

            $result.ExitCode | Should -Be 0 -Because 'ceilings are advisory (soft) — the script must always exit 0'
        }

        It 'uses per-agent override ceiling instead of default when a named entry exists in ceilings' {
            $dir = & $script:NewTempDir
            # 6 MUSTs — exceeds the per-agent ceiling of 5, well under default of 1000
            $content = "# Test Agent`nMUST. MUST. MUST. MUST. MUST. MUST."
            & $script:NewAgentFile -Dir $dir -Name 'MyAgent.agent.md' -Content $content | Out-Null
            $configPath = & $script:WriteConfig -Dir $dir -Config @{
                version         = 1
                default_ceiling = @{ max_directives = 1000 }
                ceilings        = @{ 'MyAgent.agent.md' = @{ max_directives = 5 } }
            }

            $result = & $script:Invoke -AgentsPath "$dir\*.agent.md" -ConfigPath $configPath
            $json = $result.Raw | ConvertFrom-Json

            @($json.agents_over_ceiling) | Should -Contain 'MyAgent.agent.md' `
                -Because '6 directives exceeds the per-agent ceiling of 5; the per-agent override must take precedence over the default of 1000'
        }

        It 'falls through to default ceiling when per-agent entry exists but has no max_directives field' {
            $dir = & $script:NewTempDir
            # 6 MUSTs — exceeds the default ceiling of 5
            $content = "# Test Agent`nMUST. MUST. MUST. MUST. MUST. MUST."
            & $script:NewAgentFile -Dir $dir -Name 'MyAgent.agent.md' -Content $content | Out-Null
            $configPath = & $script:WriteConfig -Dir $dir -Config @{
                version         = 1
                default_ceiling = @{ max_directives = 5 }
                ceilings        = @{ 'MyAgent.agent.md' = @{} }
            }

            $result = & $script:Invoke -AgentsPath "$dir\*.agent.md" -ConfigPath $configPath
            $json = $result.Raw | ConvertFrom-Json

            @($json.agents_over_ceiling) | Should -Contain 'MyAgent.agent.md' `
                -Because '6 directives exceeds the default ceiling of 5; a per-agent entry with no max_directives must fall through to the default ceiling'
        }
    }

    # ==================================================================
    # 7. Section count and nesting depth
    # ==================================================================
    Context 'section count and nesting depth' {

        It 'section_count equals the number of ##+ headings (all depths)' {
            $dir = & $script:NewTempDir
            $content = @'
# Test Agent

## Section A

Content.

## Section B

Content.

## Section C

Content.
'@
            & $script:NewAgentFile -Dir $dir -Name 'Test.agent.md' -Content $content | Out-Null

            $result = & $script:Invoke -AgentsPath "$dir\*.agent.md" -ConfigPath $script:SharedConfigPath
            $json = $result.Raw | ConvertFrom-Json
            $agent = @($json.agents) | Where-Object { $_.file -match 'Test\.agent\.md' }

            $agent.section_count | Should -Be 3 -Because 'three ## headings must yield section_count of 3'
        }

        It 'section_count includes ### and deeper headings alongside ## headings' {
            $dir = & $script:NewTempDir
            $content = @'
# Test Agent

## Intro

Top-level section content.

### Details

Subsection content.
'@
            & $script:NewAgentFile -Dir $dir -Name 'Test.agent.md' -Content $content | Out-Null

            $result = & $script:Invoke -AgentsPath "$dir\*.agent.md" -ConfigPath $script:SharedConfigPath
            $json = $result.Raw | ConvertFrom-Json
            $agent = @($json.agents) | Where-Object { $_.file -match 'Test\.agent\.md' }

            $agent.section_count | Should -Be 2 -Because '## Intro and ### Details are both ##+ headings; section_count must be 2'
        }

        It 'reports max_nesting_depth of 1 when only ## headings are present' {
            $dir = & $script:NewTempDir
            $content = @'
# Test Agent

## Section A

Content.

## Section B

Content.
'@
            & $script:NewAgentFile -Dir $dir -Name 'Test.agent.md' -Content $content | Out-Null

            $result = & $script:Invoke -AgentsPath "$dir\*.agent.md" -ConfigPath $script:SharedConfigPath
            $json = $result.Raw | ConvertFrom-Json
            $agent = @($json.agents) | Where-Object { $_.file -match 'Test\.agent\.md' }

            $agent.max_nesting_depth | Should -Be 1 -Because '## headings represent depth 1; no deeper headings present'
        }

        It 'reports max_nesting_depth of 2 when ## and ### headings are both present' {
            $dir = & $script:NewTempDir
            $content = @'
# Test Agent

## Section A

### Subsection A1

Content.

## Section B

Content.
'@
            & $script:NewAgentFile -Dir $dir -Name 'Test.agent.md' -Content $content | Out-Null

            $result = & $script:Invoke -AgentsPath "$dir\*.agent.md" -ConfigPath $script:SharedConfigPath
            $json = $result.Raw | ConvertFrom-Json
            $agent = @($json.agents) | Where-Object { $_.file -match 'Test\.agent\.md' }

            $agent.max_nesting_depth | Should -Be 2 -Because '### inside ## represents a second level of nesting; depth must be 2'
        }
    }

    # ==================================================================
    # 8. Override comment exclusion
    # ==================================================================
    Context 'override comment exclusion' {

        It 'does not count directives on lines containing an override comment' {
            $dir = & $script:NewTempDir
            $content = @'
# Test Agent

You MUST do this (no override — counted normally).
You MUST NOT count this line <!-- complexity-override: intentional pattern language -->
'@
            & $script:NewAgentFile -Dir $dir -Name 'Test.agent.md' -Content $content | Out-Null

            $result = & $script:Invoke -AgentsPath "$dir\*.agent.md" -ConfigPath $script:SharedConfigPath
            $json = $result.Raw | ConvertFrom-Json
            $agent = @($json.agents) | Where-Object { $_.file -match 'Test\.agent\.md' }

            $agent.total_directives | Should -Be 1 `
                -Because 'the override-comment line must be skipped entirely; only the first line MUST counts'
        }
    }

    # ==================================================================
    # 9. Missing config graceful handling
    # ==================================================================
    Context 'missing config graceful handling' {

        It 'exits 0 when -ConfigPath points to a nonexistent file' {
            $dir = & $script:NewTempDir
            & $script:NewAgentFile -Dir $dir -Name 'Test.agent.md' -Content "# Agent`nYou MUST do this." | Out-Null
            $missingConfig = Join-Path $dir 'nonexistent-config.json'

            $result = & $script:Invoke -AgentsPath "$dir\*.agent.md" -ConfigPath $missingConfig

            $result.ExitCode | Should -Be 0 -Because 'a missing config file must not cause a non-zero exit'
        }

        It 'still includes agents_over_ceiling in JSON output when config is missing' {
            $dir = & $script:NewTempDir
            & $script:NewAgentFile -Dir $dir -Name 'Test.agent.md' -Content "# Agent`nYou MUST do this." | Out-Null
            $missingConfig = Join-Path $dir 'nonexistent-config.json'

            $result = & $script:Invoke -AgentsPath "$dir\*.agent.md" -ConfigPath $missingConfig
            $json = $result.Raw | ConvertFrom-Json

            $json.PSObject.Properties.Name | Should -Contain 'agents_over_ceiling' `
                -Because 'agents_over_ceiling must appear in output even when config is missing'
        }

        It 'indicates in output that the default ceiling was used when config is missing' {
            $dir = & $script:NewTempDir
            & $script:NewAgentFile -Dir $dir -Name 'Test.agent.md' -Content "# Agent`nYou MUST do this." | Out-Null
            $missingConfig = Join-Path $dir 'nonexistent-config.json'

            $result = & $script:Invoke -AgentsPath "$dir\*.agent.md" -ConfigPath $missingConfig
            $json = $result.Raw | ConvertFrom-Json

            # Accept any reasonable implementation of "indicates default was used":
            # a JSON field whose value references 'default', or a 'using_default_ceiling' boolean, or
            # a match in the raw output. Exact field name is implementation-defined.
            $indicatesDefault = (
                ($json.PSObject.Properties.Name -contains 'config_source' -and ($json.config_source -match 'default')) -or
                ($json.PSObject.Properties.Name -contains 'using_default_ceiling' -and $json.using_default_ceiling -eq $true) -or
                ($result.Raw -match '(?i)default.{0,40}ceiling|using default')
            )
            $indicatesDefault | Should -Be $true `
                -Because 'output must indicate that the built-in default ceiling was used when the config file is missing'
        }
    }
}
