#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
.SYNOPSIS
    Contract tests for BDD structured scenario wording across agents.

.DESCRIPTION
    Locks the Phase 1 (issue #223) and Phase 2 (issue #227) BDD framework contracts in:
      - .github/agents/Experience-Owner.agent.md
      - .github/agents/Issue-Planner.agent.md
      - .github/agents/Code-Conductor.agent.md
      - .github/agents/Code-Critic.agent.md
      - .github/agents/Test-Writer.agent.md
      - .github/skills/bdd-scenarios/SKILL.md

        Phase 1 contracts (issue #223):
            - Conditional G/W/T authoring when ## BDD Framework section is present
            - Scenario ID convention (S1, S2...) with ### SN heading pattern
            - Natural-language fallback when BDD not enabled
            - [auto]/[manual] classification (Issue-Planner)
            - Pre-flight coverage check and recovery path (Code-Conductor)
            - Per-scenario evidence mapping (Code-Critic)

        Phase 2 contracts (issue #227):
            - Framework mapping table and Gherkin conversion rules (bdd-scenarios skill)
            - Gherkin .feature file generation for [auto] scenarios (Test-Writer)
            - Runner dispatch, evidence capture, and conditional EO delegation (Code-Conductor)
            - Runner evidence evaluation keyed on source field (Code-Critic)

        Update these tests only when the contract semantics intentionally change.
#>

Describe 'Experience-Owner BDD scenario contract' {

    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
        $script:ExperienceOwner = Join-Path $script:RepoRoot '.github\agents\Experience-Owner.agent.md'
        $script:Content = Get-Content -Path $script:ExperienceOwner -Raw

        $script:GwtConditionalPattern = '(?is)(## BDD Framework).{0,300}(G/W/T|Given.{0,10}When.{0,10}Then|structured scenario).{0,300}(natural.{0,30}language|fallback)'
        $script:ScenarioIdHeadingPattern = '(?is)(###\s+S\d+|###\s+SN|### S1|S\d+\s+—\s+\{title\}|SN\s+—\s+\{title\}).{0,200}(Type|Functional|Intent)'
        $script:BddSkillReferencePattern = 'bdd-scenarios'
        $script:CustomerLanguagePattern = '(?is)(customer.{0,30}(language|terms|vocabulary)|no (technical|jargon|implementation detail|code term)).{0,300}(G/W/T|Given|When|Then|scenario clause)'
    }

    It 'Experience-Owner activates G/W/T authoring when BDD Framework section present, with natural-language fallback' {
        $script:Content | Should -Match $script:GwtConditionalPattern -Because 'issue #223 requires Experience-Owner to detect ## BDD Framework and author structured G/W/T scenarios with a natural-language fallback when not enabled'
    }

    It 'Experience-Owner uses SN heading convention with Type tag' {
        $script:Content | Should -Match $script:ScenarioIdHeadingPattern -Because 'issue #223 requires Experience-Owner to use ### SN heading convention and include a Type tag in scenarios'
    }

    It 'Experience-Owner references bdd-scenarios skill' {
        $script:Content | Should -Match $script:BddSkillReferencePattern -Because 'issue #223 requires Experience-Owner to load and reference the bdd-scenarios skill for scenario authoring guidance'
    }

    It 'Experience-Owner specifies customer-language principle for G/W/T clauses' {
        $script:Content | Should -Match $script:CustomerLanguagePattern -Because 'issue #223 requires Experience-Owner to apply customer-facing language (no technical/implementation terms) in Given/When/Then clauses'
    }

    It 'instructs ## Scenarios H2 heading for issue body updates' {
        $script:Content | Should -Match '(?s)use\s+`## Scenarios`\s*\(H2\)' -Because 'issue #223 requires Experience-Owner to instruct using ## Scenarios (H2) as the section heading in the issue body for Code-Conductor pre-flight extraction'
    }
}

Describe 'Issue-Planner BDD classification contract' {

    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
        $script:IssuePlanner = Join-Path $script:RepoRoot '.github\agents\Issue-Planner.agent.md'
        $script:IPContent = Get-Content -Path $script:IssuePlanner -Raw
    }

    It 'Issue-Planner classification rubric maps Functional+observable to [auto] and Intent+subjective to [manual]' {
        $script:IPContent | Should -Match '(?is)(Functional.{0,100}observable.{0,100}\[auto\]).{0,200}(Intent.{0,100}subjective.{0,100}\[manual\])' -Because 'issue #223 requires Issue-Planner to document a classification rubric table mapping Functional+observable to [auto] and Intent+subjective to [manual]'
    }

    It 'Issue-Planner extends CE GATE format with scenario IDs and classification tags when BDD enabled' {
        $script:IPContent | Should -Match '(?is)(## BDD Framework|BDD.{0,30}enabled|BDD.{0,30}active).{0,500}(SN|S\d+|scenario ID).{0,300}(\[auto\]|\[manual\])' -Because 'issue #223 requires Issue-Planner to include scenario IDs and classification tags in the CE GATE step when BDD is enabled'
    }

    It 'Issue-Planner documents Test-Writer reclassification of [auto]/[manual] during implementation' {
        $script:IPContent | Should -Match '(?is)(Test-Writer|test writer).{0,200}(reclassif|reclassify).{0,200}(auto.{0,20}manual|manual.{0,20}auto|\[auto\].{0,20}\[manual\])' -Because 'issue #223 requires Issue-Planner to document that Test-Writer may reclassify [auto]/[manual] scenarios during implementation'
    }

    It 'Issue-Planner references bdd-scenarios skill' {
        $script:IPContent | Should -Match 'bdd-scenarios' -Because 'issue #223 requires Issue-Planner to load and reference the bdd-scenarios skill'
    }
}

Describe 'Code-Conductor BDD CE Gate pre-flight contract' {

    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
        $script:CodeConductor = Join-Path $script:RepoRoot '.github\agents\Code-Conductor.agent.md'
        $script:CCContent = Get-Content -Path $script:CodeConductor -Raw
    }

    It 'Code-Conductor CE Gate pre-flight reads scenario IDs from issue body using S\d+ pattern' {
        $script:CCContent | Should -Match '(?is)(pre-flight|preflight|pre flight).{0,400}(### S\\d\+|S\\d\+|scenario ID).{0,300}(issue body|## Scenarios)' -Because 'issue #223 requires Code-Conductor CE Gate pre-flight to read scenario IDs from the issue body using the ### S\d+ heading pattern'
    }

    It 'Code-Conductor CE Gate pre-flight recovery offers Re-exercise, Waive, and Abort options' {
        $script:CCContent | Should -Match '(?is)(Re-exercise missing scenario|re-exercise.{0,30}missing|re.{0,5}exercise.{0,50}missing).{0,300}(Waive with documented reason|waive.{0,20}documented).{0,300}(Abort CE Gate|abort.{0,20}CE Gate)' -Because 'issue #223 requires Code-Conductor CE Gate pre-flight to offer Re-exercise, Waive with documented reason, and Abort CE Gate recovery options'
    }

    It 'Code-Conductor CE Gate pre-flight has independent cycle budget from Track 1' {
        $script:CCContent | Should -Match '(?is)(pre-flight|preflight).{0,500}(independent.{0,30}(Track 1|track 1 budget)|separate.{0,30}budget)' -Because 'issue #223 requires Code-Conductor to document that the CE Gate pre-flight cycle budget is independent of the Track 1 budget'
    }

    It 'Code-Conductor PR body includes per-scenario coverage table with ID, Type, Class, Result, Evidence columns' {
        $script:CCContent | Should -Match '(?is)\|\s*ID\s*\|\s*Type\s*\|\s*Class\s*\|\s*Result\s*\|\s*Evidence\s*\|' -Because 'issue #223 requires Code-Conductor to include a per-scenario coverage table with ID, Type, Class, Result, and Evidence columns in the PR body'
    }

    It 'Code-Conductor CE Gate pre-flight scopes S\d+ extraction between ## Scenarios and next H2' {
        $script:CCContent | Should -Match '(?is)Scope.{0,100}extraction.{0,100}(## Scenarios|Scenarios heading).{0,100}next H2' -Because 'issue #223 requires Code-Conductor to scope ### S\d+ extraction to content between ## Scenarios and the next H2 heading, preventing false-positive matches outside this boundary'
    }
}

Describe 'Code-Critic BDD CE prosecution contract' {

    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
        $script:CodeCritic = Join-Path $script:RepoRoot '.github\agents\Code-Critic.agent.md'
        $script:CriticContent = Get-Content -Path $script:CodeCritic -Raw
    }

    It 'Code-Critic evaluates each scenario individually when BDD scenario IDs present in evidence' {
        $script:CriticContent | Should -Match '(?is)(BDD.{0,30}scenario ID|scenario ID.{0,30}BDD|S\d+.{0,100}evidence|evidence.{0,100}S\d+).{0,300}(evaluate each|each scenario|individually)' -Because 'issue #223 requires Code-Critic to evaluate each scenario individually when BDD scenario IDs appear in evidence'
    }

    It 'Code-Critic includes scenario ID in finding references (e.g., S2: Intent — partial match)' {
        $script:CriticContent | Should -Match '(?is)(S\d+:\s*(Functional|Intent|Error|finding)|scenario ID.{0,200}finding reference|finding reference.{0,200}scenario ID)' -Because 'issue #223 requires Code-Critic to include scenario ID in finding references such as S2: Intent — partial match'
    }

    It 'Code-Critic applies all three lenses per BDD scenario evaluation' {
        $script:CriticContent | Should -Match '(?is)(BDD.{0,400}(three lenses|3 lenses|Functional.{0,30}Intent.{0,30}Error)|(three lenses|3 lenses).{0,400}BDD)' -Because 'issue #223 requires Code-Critic to apply all three lenses (Functional, Intent, Error States) when evaluating each BDD scenario'
    }

    It 'Code-Critic per-scenario evaluation is conditional on BDD scenario IDs present in evidence' {
        $script:CriticContent | Should -Match '(?is)(when.{0,60}(BDD.{0,30}scenario ID|scenario ID.{0,30}BDD|S\d+.{0,30}ID).{0,100}(present|found|available|contain)|BDD.{0,100}conditional)' -Because 'issue #223 requires Code-Critic to specify that per-scenario evaluation is conditional on BDD scenario IDs being present in evidence'
    }
}

Describe 'bdd-scenarios SKILL.md Phase 2 contract' {

    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
        $script:SkillFile = Join-Path $script:RepoRoot '.github\skills\bdd-scenarios\SKILL.md'
        $script:SkillContent = Get-Content -Path $script:SkillFile -Raw
    }

    It 'SKILL.md Phase 2 section documents all four supported frameworks including JVM cucumber' {
        $script:SkillContent | Should -Match '(?is)cucumber\.js.{0,500}behave.{0,500}jest-cucumber.{0,500}cucumber' -Because 'issue #227 requires the bdd-scenarios skill Phase 2 section to document all four supported frameworks: cucumber.js, behave, jest-cucumber, and cucumber (JVM)'
    }

    It 'SKILL.md documents unified evidence record with source, result, detail, and raw_exit_code fields' {
        $script:SkillContent | Should -Match '(?is)(source.{0,50}result.{0,50}detail.{0,50}raw_exit_code)' -Because 'issue #227 requires the bdd-scenarios skill to document the unified evidence record schema with source, result, detail, and raw_exit_code fields'
    }

    It 'SKILL.md documents runner dispatch protocol with pre-check step' {
        $script:SkillContent | Should -Match '(?is)(runner.{0,20}dispatch|dispatch.{0,20}runner).{0,300}(pre.{0,5}check|version check)' -Because 'issue #227 requires the bdd-scenarios skill to document the runner dispatch protocol including a pre-check (version verification) step'
    }

    It 'SKILL.md Phase 2 detection requires both BDD Framework heading and bdd: {framework} line' {
        $script:SkillContent | Should -Match '(?is)(Phase 2.{0,200}(both|heading.{0,50}bdd:|bdd:.{0,50}heading)|activation.{0,100}both)' -Because 'issue #227 requires Phase 2 to activate only when both the ## BDD Framework heading AND a bdd: {framework} line are present'
    }

    It 'SKILL.md documents bdd: true warning and fallback to Phase 1' {
        $script:SkillContent | Should -Match '(?is)(bdd:\s*true.{0,300}(warning|warn|fallback|Phase 1))' -Because 'issue #227 requires SKILL.md to document that bdd: true emits a warning and falls back to Phase 1 behavior'
    }
}

Describe 'Test-Writer BDD Phase 2 Gherkin generation contract' {

    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
        $script:TestWriter = Join-Path $script:RepoRoot '.github\agents\Test-Writer.agent.md'
        $script:TWContent = Get-Content -Path $script:TestWriter -Raw
    }

    It 'Test-Writer documents BDD Gherkin generation activated by bdd: {framework}' {
        $script:TWContent | Should -Match '(?is)(bdd:\s*.{0,20}(framework|\{framework\}|cucumber\.js|behave|jest-cucumber|cucumber)).{0,300}(Gherkin|\.feature)' -Because 'issue #227 requires Test-Writer to document BDD Phase 2 Gherkin generation activated by bdd: {framework}'
    }

    It 'Test-Writer generates .feature files for [auto] scenarios only, excluding [manual]' {
        $script:TWContent | Should -Match '(?is)(\[auto\].{0,200}(\.feature|Gherkin|only)|(\.feature|Gherkin).{0,200}\[auto\])' -Because 'issue #227 requires Test-Writer to generate Gherkin .feature files for [auto] scenarios only'
    }

    It 'Test-Writer uses @S{N} tags in generated Gherkin scenarios' {
        $script:TWContent | Should -Match '(?is)(@S\d+|@S\{N\}|@SN).{0,100}(tag|Gherkin|\.feature|scenario)' -Because 'issue #227 requires Test-Writer to tag each generated Gherkin scenario with @S{N} for per-scenario runner dispatch filtering'
    }

    It 'Test-Writer references bdd-scenarios skill for framework mapping table' {
        $script:TWContent | Should -Match '(?is)bdd-scenarios.{0,200}(framework|mapping|table)' -Because 'issue #227 requires Test-Writer to reference the bdd-scenarios skill to determine the framework mapping (output directory) for generated files'
    }
}

Describe 'Code-Conductor BDD Phase 2 runner dispatch contract' {

    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
        $script:CodeConductor = Join-Path $script:RepoRoot '.github\agents\Code-Conductor.agent.md'
        $script:CCContent = Get-Content -Path $script:CodeConductor -Raw
    }

    It 'Code-Conductor runner dispatch activates only when bdd: {framework} is a recognized value' {
        $script:CCContent | Should -Match '(?is)(runner.{0,30}dispatch|Phase 2.{0,30}runner).{0,300}(bdd:.{0,100}(recognized|framework)|recognized.{0,100}framework)' -Because 'issue #227 requires Code-Conductor runner dispatch to check that bdd: {framework} is set to a recognized framework value before dispatching'
    }

    It 'Code-Conductor runner dispatch conditionally delegates [manual]-only or all scenarios to Experience-Owner' {
        $script:CCContent | Should -Match '(?is)(all.{0,5}\[auto\].{0,100}pass.{0,200}only.{0,5}\[manual\]|only.{0,5}\[manual\].{0,200}(pass|runner).{0,100}\[auto\])' -Because 'issue #227 requires Code-Conductor to delegate only [manual] scenarios to EO when all [auto] runners passed'
    }

    It 'Code-Conductor runner dispatch adds failed [auto] scenarios to EO delegation list on partial failure' {
        $script:CCContent | Should -Match '(?is)any.{0,30}\[auto\].{0,30}runner.{0,20}fail.{0,200}add.{0,50}failed.{0,30}\[auto\].{0,100}(EO delegation list|delegation list)' -Because 'issue #227 requires Code-Conductor to add failed [auto] scenarios to the EO delegation list when some (but not all) [auto] runners fail, so EO exercises both the failed [auto] and all [manual] scenarios'
    }

    It 'Code-Conductor PR body per-scenario coverage table includes a Source column' {
        $script:CCContent | Should -Match '(?is)\|\s*Source\s*\|' -Because 'issue #227 requires Code-Conductor to add a Source column to the per-scenario PR coverage table to distinguish runner evidence from EO evidence'
    }

    It 'Code-Conductor runner dispatch falls back to Phase 1 (all scenarios to EO) when pre-check fails' {
        $script:CCContent | Should -Match '(?is)(pre.{0,5}check.{0,200}(fail|fail.{0,20}warning).{0,200}(Phase 1|fall.{0,5}back|all scenarios))' -Because 'issue #227 requires Code-Conductor to fall back to Phase 1 behavior (delegate all scenarios to EO) when the runner version pre-check fails'
    }
}

Describe 'Code-Critic BDD Phase 2 runner evidence evaluation contract' {

    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
        $script:CodeCritic = Join-Path $script:RepoRoot '.github\agents\Code-Critic.agent.md'
        $script:CriticContent = Get-Content -Path $script:CodeCritic -Raw
    }

    It 'Code-Critic treats source:runner result:pass as strong Functional lens evidence' {
        $script:CriticContent | Should -Match '(?is)(source:\s*runner.{0,100}result:\s*pass|runner.{0,30}pass).{0,300}(strong.{0,50}Functional|Functional.{0,100}strong)' -Because 'issue #227 requires Code-Critic to treat source:runner, result:pass as strong Functional lens evidence'
    }

    It 'Code-Critic classifies source:runner result:fail as Concern under Functional lens' {
        $script:CriticContent | Should -Match '(?is)(source:\s*runner.{0,100}result:\s*fail|runner.{0,30}fail).{0,300}Concern' -Because 'issue #227 requires Code-Critic to classify source:runner, result:fail as a Concern'
    }

    It 'Code-Critic classifies runner+eo conflicts as Concern (not Issue or automatic failure)' {
        $script:CriticContent | Should -Match '(?is)(source:\s*runner\+eo|runner\+eo.{0,50}conflict|conflict.{0,50}runner\+eo).{0,300}(Concern.{0,50}(not|no).{0,20}Issue)' -Because 'issue #227 requires Code-Critic to classify runner+eo conflicts as Concern — not Issue — to avoid automatic failure escalation'
    }

    It 'Code-Critic runner evidence evaluation is keyed on presence of source field in unified evidence record' {
        $script:CriticContent | Should -Match '(?is)(`source`.{0,100}field.{0,100}(present|contains|unified evidence|source field)|(unified evidence.{0,50}source|source field.{0,50}unified))' -Because 'issue #227 requires Code-Critic to key runner evidence evaluation on the presence of a source field in the unified evidence record'
    }
}
