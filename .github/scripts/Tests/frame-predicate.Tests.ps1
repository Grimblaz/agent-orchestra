#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
.SYNOPSIS
    Pester 5 tests for frame predicate parsing.

.DESCRIPTION
    Contract under test:
      ConvertTo-FVPredicate parses well-formed frame predicates into an AST
      and returns parse error objects with Position and Message for malformed
      predicates. These tests verify parse shape only; semantic validation such
      as field existence, literal allowed values, and type consistency belongs
      to issue #428.
#>

Describe 'ConvertTo-FVPredicate' -Tag 'unit' {

    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
        $script:LibFile = Join-Path $script:RepoRoot '.github/scripts/lib/frame-predicate-core.ps1'
        . $script:LibFile

        $script:GetAstKinds = {
            param($Node)

            $kinds = [System.Collections.Generic.List[string]]::new()
            $visit = {
                param($Value)

                if ($null -eq $Value) {
                    return
                }

                if ($Value -is [string] -or $Value -is [ValueType]) {
                    return
                }

                if ($Value -is [System.Collections.IEnumerable]) {
                    foreach ($item in $Value) {
                        & $visit $item
                    }
                    return
                }

                $kindProperty = $Value.PSObject.Properties['Kind']
                if ($null -ne $kindProperty) {
                    $kinds.Add([string]$kindProperty.Value)
                }

                foreach ($property in @($Value.PSObject.Properties)) {
                    if ($property.Name -ne 'Kind') {
                        & $visit $property.Value
                    }
                }
            }

            & $visit $Node
            return $kinds.ToArray()
        }

        $script:GetAstScalarValues = {
            param($Node)

            $values = [System.Collections.Generic.List[object]]::new()
            $visit = {
                param($Value)

                if ($null -eq $Value) {
                    return
                }

                if ($Value -is [string] -or $Value -is [ValueType]) {
                    $values.Add($Value)
                    return
                }

                if ($Value -is [System.Collections.IEnumerable]) {
                    foreach ($item in $Value) {
                        & $visit $item
                    }
                    return
                }

                foreach ($property in @($Value.PSObject.Properties)) {
                    & $visit $property.Value
                }
            }

            & $visit $Node
            return $values.ToArray()
        }

        $script:AssertAst = {
            param($Result)

            $Result | Should -Not -BeNullOrEmpty
            $Result.PSObject.Properties['Kind'] | Should -Not -BeNullOrEmpty
            $Result.Kind | Should -Not -Be 'ParseError'
        }

        $script:AssertParseError = {
            param(
                $Result,
                [int]$Position,
                [string]$MessagePattern
            )

            $Result | Should -Not -BeNullOrEmpty
            $Result.PSObject.Properties['Kind'] | Should -Not -BeNullOrEmpty
            $Result.PSObject.Properties['Position'] | Should -Not -BeNullOrEmpty
            $Result.PSObject.Properties['Message'] | Should -Not -BeNullOrEmpty
            $Result.Kind | Should -Be 'ParseError'
            $Result.Position | Should -Be $Position
            $Result.Message | Should -Not -BeNullOrEmpty
            $Result.Message | Should -Match $MessagePattern
        }
    }

    It 'ships the in-process frame predicate parser library' {
        $script:LibFile | Should -Exist
        Get-Command ConvertTo-FVPredicate -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }

    Context 'well-formed predicates' {

        It 'returns a comparison AST for comparator <Operator>' -ForEach @(
            @{ Predicate = "port == 'experience'"; Operator = '==' }
            @{ Predicate = "port != 'review'"; Operator = '!=' }
            @{ Predicate = 'score < 3'; Operator = '<' }
            @{ Predicate = 'score > 1'; Operator = '>' }
            @{ Predicate = 'score <= 10'; Operator = '<=' }
            @{ Predicate = 'score >= 0'; Operator = '>=' }
            @{ Predicate = "port in ['experience', 'review']"; Operator = 'in' }
        ) {
            param($Predicate, $Operator)

            $ast = ConvertTo-FVPredicate -Predicate $Predicate

            & $script:AssertAst -Result $ast
            $kinds = & $script:GetAstKinds -Node $ast
            $values = & $script:GetAstScalarValues -Node $ast

            $kinds | Should -Contain 'Comparison'
            $kinds | Should -Contain 'Identifier'
            $kinds | Should -Contain 'Literal'
            $values | Should -Contain $Operator
        }

        It 'returns a logical AST for <Operator> predicates' -ForEach @(
            @{ Predicate = "port == 'experience' AND status == 'stable'"; Operator = 'AND' }
            @{ Predicate = "port == 'experience' OR status == 'experimental'"; Operator = 'OR' }
        ) {
            param($Predicate, $Operator)

            $ast = ConvertTo-FVPredicate -Predicate $Predicate

            & $script:AssertAst -Result $ast
            $kinds = & $script:GetAstKinds -Node $ast
            $values = & $script:GetAstScalarValues -Node $ast

            $kinds | Should -Contain 'Logical'
            $kinds | Should -Contain 'Comparison'
            $values | Should -Contain $Operator
        }

        It 'returns a NOT AST when a predicate negates a comparison' {
            $ast = ConvertTo-FVPredicate -Predicate "NOT port == 'deprecated'"

            & $script:AssertAst -Result $ast
            $kinds = & $script:GetAstKinds -Node $ast

            $kinds | Should -Contain 'Not'
            $kinds | Should -Contain 'Comparison'
            $kinds | Should -Contain 'Identifier'
            $kinds | Should -Contain 'Literal'
        }

        It 'accepts dotted paths inside grouped predicates' {
            $ast = ConvertTo-FVPredicate -Predicate "(adapter.kind == 'agent' AND metadata.priority >= 2)"

            & $script:AssertAst -Result $ast
            $kinds = & $script:GetAstKinds -Node $ast
            $values = & $script:GetAstScalarValues -Node $ast

            $kinds | Should -Contain 'Logical'
            $kinds | Should -Contain 'Comparison'
            $values | Should -Contain 'adapter.kind'
            $values | Should -Contain 'metadata.priority'
        }

        It 'accepts documented parse-only frame DSL predicate <Predicate>' -ForEach @(
            @{ Predicate = 'scope.isReReview'; ExpectedKinds = @('Identifier'); ExpectedValues = @('scope.isReReview') }
            @{ Predicate = "changeset.touches('src/ui/**')"; ExpectedKinds = @('Call', 'Literal'); ExpectedValues = @('changeset.touches', 'src/ui/**') }
            @{ Predicate = 'not changeset.touchesSource()'; ExpectedKinds = @('Not', 'Call'); ExpectedValues = @('changeset.touchesSource') }
            @{ Predicate = "changeset.touches('docs/**') and changeset.behaviorChanged()"; ExpectedKinds = @('Logical', 'Call'); ExpectedValues = @('AND', 'changeset.touches', 'docs/**', 'changeset.behaviorChanged') }
        ) {
            param($Predicate, $ExpectedKinds, $ExpectedValues)

            $ast = ConvertTo-FVPredicate -Predicate $Predicate

            & $script:AssertAst -Result $ast
            $kinds = & $script:GetAstKinds -Node $ast
            $values = & $script:GetAstScalarValues -Node $ast

            foreach ($expectedKind in $ExpectedKinds) {
                $kinds | Should -Contain $expectedKind
            }

            foreach ($expectedValue in $ExpectedValues) {
                $values | Should -Contain $expectedValue
            }
        }

        It 'does not perform semantic field validation in parse-only mode' {
            $ast = ConvertTo-FVPredicate -Predicate "unknown.future_field == 'anything'"

            & $script:AssertAst -Result $ast
            $kinds = & $script:GetAstKinds -Node $ast
            $values = & $script:GetAstScalarValues -Node $ast

            $kinds | Should -Contain 'Comparison'
            $values | Should -Contain 'unknown.future_field'
        }

        It 'does not perform semantic function validation in parse-only mode' {
            $ast = ConvertTo-FVPredicate -Predicate "unknown.futureFunction('anything')"

            & $script:AssertAst -Result $ast
            $kinds = & $script:GetAstKinds -Node $ast
            $values = & $script:GetAstScalarValues -Node $ast

            $kinds | Should -Contain 'Call'
            $values | Should -Contain 'unknown.futureFunction'
        }

        It 'accepts <LiteralType> literals' -ForEach @(
            @{ LiteralType = 'string'; Predicate = "port == 'experience'"; ExpectedValue = 'experience' }
            @{ LiteralType = 'number'; Predicate = 'score >= 2.5'; ExpectedValue = '2.5' }
            @{ LiteralType = 'boolean'; Predicate = 'enabled == true'; ExpectedValue = $true }
            @{ LiteralType = 'array'; Predicate = "port in ['experience', 'review', true, 3]"; ExpectedValue = 'Array' }
        ) {
            param($LiteralType, $Predicate, $ExpectedValue)

            $ast = ConvertTo-FVPredicate -Predicate $Predicate

            & $script:AssertAst -Result $ast
            $kinds = & $script:GetAstKinds -Node $ast
            $values = & $script:GetAstScalarValues -Node $ast

            $kinds | Should -Contain 'Literal'
            $values | Should -Contain $ExpectedValue
        }
    }

    Context 'malformed predicates' {

        It 'returns parse error details for <Case>' -ForEach @(
            @{
                Case           = 'trailing operator'
                Predicate      = "port == 'experience' AND"
                Position       = 21
                MessagePattern = 'Trailing operator'
            }
            @{
                Case           = 'unbalanced parens'
                Predicate      = "(port == 'experience'"
                Position       = 0
                MessagePattern = "Unclosed '\('"
            }
            @{
                Case           = 'missing right-hand side'
                Predicate      = 'port =='
                Position       = 7
                MessagePattern = 'Missing right-hand literal'
            }
            @{
                Case           = 'double operator'
                Predicate      = "port == == 'experience'"
                Position       = 8
                MessagePattern = 'Expected literal'
            }
            @{
                Case           = 'consecutive operators'
                Predicate      = "port == 'experience' AND OR status == 'stable'"
                Position       = 25
                MessagePattern = 'Unexpected operator'
            }
            @{
                Case           = 'invalid hyphenated identifier'
                Predicate      = "port-name == 'experience'"
                Position       = 4
                MessagePattern = "Unexpected character '-'"
            }
        ) {
            param($Case, $Predicate, $Position, $MessagePattern)

            $result = ConvertTo-FVPredicate -Predicate $Predicate

            & $script:AssertParseError -Result $result -Position $Position -MessagePattern $MessagePattern
        }
    }
}
