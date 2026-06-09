#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
.SYNOPSIS
    Contract tests preventing Pester sources from mutating committed skill assets.

.DESCRIPTION
    Locks issue #402 AC6. Pester test sources may create and mutate temporary
    fixtures, but they must not write committed files under skills/*/assets/.
    The contract parses test sources hermetically and excludes this file so the
    write-call literals used by the detector do not self-trigger.
#>

Describe 'test source mutation contract' -Tag 'no-gh' {

    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
        $script:TestsRoot = Join-Path $script:RepoRoot '.github/scripts/Tests'
        $script:ThisFile = (Resolve-Path $PSCommandPath).Path
        $script:AssetPathPattern = 'skills[/\\][^/\\]+[/\\]assets(?:[/\\]|$)'

        $script:WriteCommandPathParameters = @{
            'Set-Content' = @('Path', 'LiteralPath')
            'Out-File'    = @('FilePath', 'LiteralPath')
            'Add-Content' = @('Path', 'LiteralPath')
            'Move-Item'   = @('Path', 'LiteralPath', 'Destination')
            'Copy-Item'   = @('Destination')
            'Rename-Item' = @('Path', 'LiteralPath', 'NewName')
        }

        $script:PositionalPathArgumentCounts = @{
            'Set-Content' = 1
            'Out-File'    = 1
            'Add-Content' = 1
            'Move-Item'   = 2
            'Copy-Item'   = 2
            'Rename-Item' = 2
        }

        $script:SwitchOnlyParameterNames = @(
            'AsByteStream', 'Confirm', 'Force', 'NoClobber', 'NoNewline',
            'PassThru', 'Recurse', 'WhatIf'
        )

        $script:NormalizeVariableName = {
            param([System.Management.Automation.Language.VariableExpressionAst]$VariableAst)

            if ($null -eq $VariableAst) {
                return ''
            }

            return ($VariableAst.VariablePath.UserPath -replace '^(global|local|private|script|using):', '')
        }

        $script:JoinStaticPath = {
            param([string]$Parent, [string]$Child)

            if ([string]::IsNullOrWhiteSpace($Parent)) {
                return $Child
            }
            if ([string]::IsNullOrWhiteSpace($Child)) {
                return $Parent
            }

            return (($Parent.TrimEnd('/\')) + '/' + ($Child.TrimStart('/\')))
        }

        $script:GetJoinPathArgumentAsts = {
            param([System.Management.Automation.Language.CommandAst]$CommandAst)

            $pathParameterNames = @('Path', 'LiteralPath', 'ChildPath', 'AdditionalChildPath')
            $argumentAsts = [System.Collections.Generic.List[System.Management.Automation.Language.Ast]]::new()
            $pendingPathParameter = $false
            $pendingNonPathParameter = $false

            for ($index = 1; $index -lt $CommandAst.CommandElements.Count; $index++) {
                $element = $CommandAst.CommandElements[$index]

                if ($element -is [System.Management.Automation.Language.CommandParameterAst]) {
                    $parameterName = $element.ParameterName
                    $pendingPathParameter = $false
                    $pendingNonPathParameter = $false

                    if ($pathParameterNames -contains $parameterName) {
                        if ($null -ne $element.Argument) {
                            [void]$argumentAsts.Add($element.Argument)
                        }
                        else {
                            $pendingPathParameter = $true
                        }

                        continue
                    }

                    if (($script:SwitchOnlyParameterNames -notcontains $parameterName) -and $null -eq $element.Argument) {
                        $pendingNonPathParameter = $true
                    }

                    continue
                }

                if ($element -isnot [System.Management.Automation.Language.ExpressionAst]) {
                    continue
                }

                if ($pendingPathParameter) {
                    [void]$argumentAsts.Add($element)
                    $pendingPathParameter = $false
                    continue
                }

                if ($pendingNonPathParameter) {
                    $pendingNonPathParameter = $false
                    continue
                }

                [void]$argumentAsts.Add($element)
            }

            return @($argumentAsts)
        }

        $script:GetStaticPathValuesFromAst = {
            param(
                [System.Management.Automation.Language.Ast]$Ast,
                [hashtable]$VariableValues
            )

            if ($null -eq $Ast) {
                return @()
            }

            $candidateValues = [System.Collections.Generic.List[string]]::new()

            if ($Ast -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
                [void]$candidateValues.Add($Ast.Value)
            }

            if ($Ast -is [System.Management.Automation.Language.ExpandableStringExpressionAst]) {
                [void]$candidateValues.Add($Ast.Value)
                [void]$candidateValues.Add($Ast.Extent.Text)
            }

            if ($Ast -is [System.Management.Automation.Language.VariableExpressionAst]) {
                $name = & $script:NormalizeVariableName -VariableAst $Ast
                if ($VariableValues.ContainsKey($name)) {
                    [void]$candidateValues.Add($VariableValues[$name])
                }
            }

            $joinPathCommands = @($Ast.FindAll({
                        param($Node)
                        $Node -is [System.Management.Automation.Language.CommandAst] -and
                        $Node.GetCommandName() -eq 'Join-Path'
                    }, $true))

            foreach ($joinPathCommand in $joinPathCommands) {
                $composedValues = @('')
                $argumentAsts = @(& $script:GetJoinPathArgumentAsts -CommandAst $joinPathCommand)

                foreach ($argumentAst in $argumentAsts) {
                    $argumentValues = @(
                        & $script:GetStaticPathValuesFromAst -Ast $argumentAst -VariableValues $VariableValues |
                            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
                    )
                    if ($argumentValues.Count -eq 0) {
                        continue
                    }

                    $nextValues = [System.Collections.Generic.List[string]]::new()
                    foreach ($parentValue in $composedValues) {
                        foreach ($childValue in $argumentValues) {
                            [void]$nextValues.Add((& $script:JoinStaticPath -Parent $parentValue -Child $childValue))
                        }
                    }
                    $composedValues = @($nextValues)
                }

                foreach ($composedValue in $composedValues) {
                    [void]$candidateValues.Add($composedValue)
                }
            }

            $nodes = @($Ast.FindAll({
                        param($Node)
                        $Node -is [System.Management.Automation.Language.StringConstantExpressionAst] -or
                        $Node -is [System.Management.Automation.Language.ExpandableStringExpressionAst] -or
                        $Node -is [System.Management.Automation.Language.VariableExpressionAst]
                    }, $true))

            if ($nodes.Count -eq 0 -and $Ast -is [System.Management.Automation.Language.VariableExpressionAst]) {
                $nodes = @($Ast)
            }

            foreach ($node in $nodes) {
                if ($node -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
                    [void]$candidateValues.Add($node.Value)
                    [void]$candidateValues.Add($node.Extent.Text)
                    continue
                }

                if ($node -is [System.Management.Automation.Language.ExpandableStringExpressionAst]) {
                    [void]$candidateValues.Add($node.Value)
                    [void]$candidateValues.Add($node.Extent.Text)
                    continue
                }

                if ($node -is [System.Management.Automation.Language.VariableExpressionAst]) {
                    $name = & $script:NormalizeVariableName -VariableAst $node
                    if ($VariableValues.ContainsKey($name)) {
                        [void]$candidateValues.Add($VariableValues[$name])
                    }
                }
            }

            return @(
                $candidateValues |
                    Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                    Select-Object -Unique
            )
        }

        $script:GetAssetPathMatchesFromAst = {
            param(
                [System.Management.Automation.Language.Ast]$Ast,
                [hashtable]$VariableValues
            )

            return @(
                & $script:GetStaticPathValuesFromAst -Ast $Ast -VariableValues $VariableValues |
                    Where-Object { $_ -match $script:AssetPathPattern } |
                    Select-Object -Unique
            )
        }

        $script:GetVariableAssetPathMap = {
            param([System.Management.Automation.Language.Ast]$Ast)

            $variableValues = [hashtable]::new([System.StringComparer]::OrdinalIgnoreCase)
            $assignments = @($Ast.FindAll({
                        param($Node)
                        $Node -is [System.Management.Automation.Language.AssignmentStatementAst]
                    }, $true))

            foreach ($assignment in $assignments) {
                if ($assignment.Left -isnot [System.Management.Automation.Language.VariableExpressionAst]) {
                    continue
                }

                $variableName = & $script:NormalizeVariableName -VariableAst $assignment.Left
                $pathCandidates = @(& $script:GetStaticPathValuesFromAst -Ast $assignment.Right -VariableValues $variableValues)
                $assetMatches = @($pathCandidates | Where-Object { $_ -match $script:AssetPathPattern })
                if ($assetMatches.Count -gt 0) {
                    $variableValues[$variableName] = $assetMatches[0]
                    continue
                }

                $pathLikeCandidates = @($pathCandidates |
                        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                        Where-Object { $_ -ne 'Join-Path' })
                if ($pathLikeCandidates.Count -gt 0) {
                    $variableValues[$variableName] = $pathLikeCandidates[0]
                }
            }

            return $variableValues
        }

        $script:GetCommandPathArgumentAsts = {
            param(
                [System.Management.Automation.Language.CommandAst]$CommandAst,
                [string]$CommandName
            )

            $pathParameters = @($script:WriteCommandPathParameters[$CommandName])
            $positionalLimit = [int]$script:PositionalPathArgumentCounts[$CommandName]
            $pathArguments = [System.Collections.Generic.List[System.Management.Automation.Language.Ast]]::new()
            $pendingPathParameter = $false
            $pendingCopyItemSourceParameter = $false
            $pendingNonPathParameter = $false
            $copyItemNamedSourceBound = $false
            $copyItemNamedDestinationBound = $false
            $positionalIndex = 0

            for ($index = 1; $index -lt $CommandAst.CommandElements.Count; $index++) {
                $element = $CommandAst.CommandElements[$index]

                if ($element -is [System.Management.Automation.Language.CommandParameterAst]) {
                    $parameterName = $element.ParameterName
                    $pendingPathParameter = $false
                    $pendingCopyItemSourceParameter = $false
                    $pendingNonPathParameter = $false

                    if ($CommandName -eq 'Copy-Item' -and $parameterName -in @('Path', 'LiteralPath')) {
                        $copyItemNamedSourceBound = $true
                        if ($null -eq $element.Argument) {
                            $pendingCopyItemSourceParameter = $true
                        }

                        continue
                    }

                    if ($pathParameters -contains $parameterName) {
                        if ($CommandName -eq 'Copy-Item' -and $parameterName -eq 'Destination') {
                            $copyItemNamedDestinationBound = $true
                        }

                        if ($null -ne $element.Argument) {
                            [void]$pathArguments.Add($element.Argument)
                        }
                        else {
                            $pendingPathParameter = $true
                        }

                        continue
                    }

                    if (($script:SwitchOnlyParameterNames -notcontains $parameterName) -and $null -eq $element.Argument) {
                        $pendingNonPathParameter = $true
                    }

                    continue
                }

                if ($element -isnot [System.Management.Automation.Language.ExpressionAst]) {
                    continue
                }

                if ($pendingPathParameter) {
                    [void]$pathArguments.Add($element)
                    $pendingPathParameter = $false
                    continue
                }

                if ($pendingCopyItemSourceParameter) {
                    $pendingCopyItemSourceParameter = $false
                    continue
                }

                if ($pendingNonPathParameter) {
                    $pendingNonPathParameter = $false
                    continue
                }

                $positionalIndex++
                if ($CommandName -eq 'Copy-Item') {
                    if ($copyItemNamedDestinationBound) {
                        continue
                    }

                    $destinationPosition = if ($copyItemNamedSourceBound) { 1 } else { 2 }
                    if ($positionalIndex -eq $destinationPosition) {
                        [void]$pathArguments.Add($element)
                    }
                    continue
                }

                if ($positionalIndex -le $positionalLimit) {
                    [void]$pathArguments.Add($element)
                }
            }

            return @($pathArguments)
        }

        $script:NewViolation = {
            param(
                [string]$SourcePath,
                [System.Management.Automation.Language.Ast]$Ast,
                [string]$Command,
                [string]$ResolvedPath
            )

            $relativePath = $SourcePath
            if (Test-Path -LiteralPath $SourcePath) {
                $relativePath = [System.IO.Path]::GetRelativePath($script:RepoRoot, (Resolve-Path $SourcePath).Path)
            }
            return [pscustomobject]@{
                File         = ($relativePath -replace '\\', '/')
                Line         = $Ast.Extent.StartLineNumber
                Command      = $Command
                PathArgument = $Ast.Extent.Text
                ResolvedPath = $ResolvedPath
            }
        }

        $script:GetCommandViolations = {
            param(
                [System.Management.Automation.Language.Ast]$Ast,
                [hashtable]$VariableValues,
                [string]$SourcePath
            )

            $violations = [System.Collections.Generic.List[object]]::new()
            $commands = @($Ast.FindAll({
                        param($Node)
                        $Node -is [System.Management.Automation.Language.CommandAst]
                    }, $true))

            foreach ($commandAst in $commands) {
                $commandName = $commandAst.GetCommandName()
                if ([string]::IsNullOrWhiteSpace($commandName)) {
                    continue
                }

                if (-not $script:WriteCommandPathParameters.ContainsKey($commandName)) {
                    continue
                }

                foreach ($argumentAst in (& $script:GetCommandPathArgumentAsts -CommandAst $commandAst -CommandName $commandName)) {
                    $assetMatches = & $script:GetAssetPathMatchesFromAst -Ast $argumentAst -VariableValues $VariableValues
                    foreach ($assetMatch in $assetMatches) {
                        [void]$violations.Add((& $script:NewViolation -SourcePath $SourcePath -Ast $argumentAst -Command $commandName -ResolvedPath $assetMatch))
                    }
                }
            }

            return @($violations)
        }

        $script:GetStaticFileWriteViolations = {
            param(
                [System.Management.Automation.Language.Ast]$Ast,
                [hashtable]$VariableValues,
                [string]$SourcePath
            )

            $violations = [System.Collections.Generic.List[object]]::new()
            $methodCalls = @($Ast.FindAll({
                        param($Node)
                        $Node -is [System.Management.Automation.Language.InvokeMemberExpressionAst]
                    }, $true))

            foreach ($methodCall in $methodCalls) {
                if (-not $methodCall.Static) {
                    continue
                }

                $targetType = $methodCall.Expression.Extent.Text
                if ($targetType -notmatch '(?i)^\[(System\.)?IO\.File\]$') {
                    continue
                }

                $methodName = $methodCall.Member.Extent.Text.Trim('''"')
                if ($methodName -notin @('WriteAllText', 'WriteAllBytes')) {
                    continue
                }

                $arguments = @($methodCall.Arguments)
                if ($arguments.Count -eq 0) {
                    continue
                }

                $assetMatches = & $script:GetAssetPathMatchesFromAst -Ast $arguments[0] -VariableValues $VariableValues
                foreach ($assetMatch in $assetMatches) {
                    [void]$violations.Add((& $script:NewViolation -SourcePath $SourcePath -Ast $arguments[0] -Command "[IO.File]::$methodName" -ResolvedPath $assetMatch))
                }
            }

            return @($violations)
        }

        $script:GetAssetWriteViolationsFromAst = {
            param(
                [System.Management.Automation.Language.Ast]$Ast,
                [string]$SourcePath
            )

            $variableValues = & $script:GetVariableAssetPathMap -Ast $Ast
            return @(
                & $script:GetCommandViolations -Ast $Ast -VariableValues $variableValues -SourcePath $SourcePath
                & $script:GetStaticFileWriteViolations -Ast $Ast -VariableValues $variableValues -SourcePath $SourcePath
            )
        }

        $script:GetAssetWriteViolationsFromContent = {
            param(
                [string]$Content,
                [string]$SourcePath = 'inline-fixture.Tests.ps1'
            )

            $tokens = $null
            $parseErrors = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseInput($Content, [ref]$tokens, [ref]$parseErrors)
            if ($parseErrors.Count -gt 0) {
                throw "Failed to parse $SourcePath fixture: $($parseErrors[0].Message)"
            }

            return & $script:GetAssetWriteViolationsFromAst -Ast $ast -SourcePath $SourcePath
        }

        $script:GetAssetWriteViolationsFromFile = {
            param([string]$SourcePath)

            $tokens = $null
            $parseErrors = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($SourcePath, [ref]$tokens, [ref]$parseErrors)
            if ($parseErrors.Count -gt 0) {
                throw "Failed to parse ${SourcePath}: $($parseErrors[0].Message)"
            }

            return & $script:GetAssetWriteViolationsFromAst -Ast $ast -SourcePath $SourcePath
        }
    }

    It 'detects committed skill asset writes through simple variable resolution in inline fixtures' {
        $fixture = @'
$configPath = Join-Path $script:RepoRoot 'skills/calibration-pipeline/assets/guidance-complexity.json'
Set-Content -Path $configPath -Value '{}'
'@

        $violations = & $script:GetAssetWriteViolationsFromContent -Content $fixture

        $violations | Should -HaveCount 1 -Because 'a write through a variable assigned from a skills/*/assets/ Join-Path must be rejected'
        $violations[0].Command | Should -Be 'Set-Content'
        $violations[0].ResolvedPath | Should -Match $script:AssetPathPattern
    }

    It 'allows writes through variables resolved to temporary fixture paths' {
        $fixture = @'
$configPath = Join-Path $workDir 'foo.json'
Set-Content -Path $configPath -Value '{}'
'@

        $violations = & $script:GetAssetWriteViolationsFromContent -Content $fixture

        $violations | Should -HaveCount 0 -Because 'temporary fixture paths outside skills/*/assets/ remain valid test setup writes'
    }

    It 'treats Copy-Item destination as a write target without requiring Force' {
        $fixture = @'
$assetPath = Join-Path $script:RepoRoot 'skills/calibration-pipeline/assets/guidance-complexity.json'
$temp = Join-Path $workDir 'source.json'
Copy-Item -Path $temp -Destination $assetPath
'@

        $violations = & $script:GetAssetWriteViolationsFromContent -Content $fixture

        $violations | Should -HaveCount 1 -Because 'Copy-Item writes to its destination even when -Force is omitted'
        $violations[0].Command | Should -Be 'Copy-Item'
        $violations[0].PathArgument | Should -Be '$assetPath'
    }

    It 'detects Copy-Item positional destination when source is bound by named Path' {
        $fixture = @'
$assetPath = Join-Path $script:RepoRoot 'skills/calibration-pipeline/assets/guidance-complexity.json'
$temp = Join-Path $workDir 'source.json'
Copy-Item -Path $temp $assetPath
'@

        $violations = & $script:GetAssetWriteViolationsFromContent -Content $fixture

        $violations | Should -HaveCount 1 -Because 'when Copy-Item source is bound by -Path, the next positional argument is the destination write target'
        $violations[0].Command | Should -Be 'Copy-Item'
        $violations[0].PathArgument | Should -Be '$assetPath'
    }

    It 'detects Copy-Item positional destination when source is bound by named LiteralPath' {
        $fixture = @'
$assetPath = Join-Path $script:RepoRoot 'skills/calibration-pipeline/assets/guidance-complexity.json'
$temp = Join-Path $workDir 'source.json'
Copy-Item -LiteralPath $temp $assetPath
'@

        $violations = & $script:GetAssetWriteViolationsFromContent -Content $fixture

        $violations | Should -HaveCount 1 -Because 'when Copy-Item source is bound by -LiteralPath, the next positional argument is the destination write target'
        $violations[0].Command | Should -Be 'Copy-Item'
        $violations[0].PathArgument | Should -Be '$assetPath'
    }

    It 'allows Copy-Item to read a committed asset source into a temporary destination' {
        $fixture = @'
$assetPath = Join-Path $script:RepoRoot 'skills/calibration-pipeline/assets/guidance-complexity.json'
$temp = Join-Path $workDir 'copied.json'
Copy-Item -LiteralPath $assetPath -Destination $temp -Force
'@

        $violations = & $script:GetAssetWriteViolationsFromContent -Content $fixture

        $violations | Should -HaveCount 0 -Because 'Copy-Item source Path/LiteralPath arguments read assets but do not write them'
    }

    It 'detects committed asset writes assembled through split Join-Path roots' {
        $fixture = @'
$skillsRoot = Join-Path $script:RepoRoot 'skills'
$skillRoot = Join-Path $skillsRoot 'calibration-pipeline'
$assetPath = Join-Path (Join-Path $skillRoot 'assets') 'guidance-complexity.json'
Set-Content -Path $assetPath -Value '{}'
'@

        $violations = & $script:GetAssetWriteViolationsFromContent -Content $fixture

        $violations | Should -HaveCount 1 -Because 'common Join-Path chains must resolve to skills/*/assets/ write targets'
        $violations[0].ResolvedPath | Should -Match 'skills[/\\]calibration-pipeline[/\\]assets[/\\]guidance-complexity\.json'
    }

    It 'detects committed asset writes assembled from an asset directory and file name' {
        $fixture = @'
$assetDir = Join-Path $script:RepoRoot 'skills/calibration-pipeline/assets'
$fileName = 'guidance-complexity.json'
$assetPath = Join-Path $assetDir $fileName
Set-Content -Path $assetPath -Value '{}'
'@

        $violations = & $script:GetAssetWriteViolationsFromContent -Content $fixture

        $violations | Should -HaveCount 1 -Because 'assets as a directory plus a filename must still resolve to a committed asset write'
        $violations[0].ResolvedPath | Should -Match 'skills[/\\]calibration-pipeline[/\\]assets[/\\]guidance-complexity\.json'
    }

    It 'recognizes every prohibited write-call form in inline fixtures' {
        $fixture = @'
$assetPath = Join-Path $script:RepoRoot 'skills/calibration-pipeline/assets/guidance-complexity.json'
Set-Content -Path $assetPath -Value '{}'
'{}' | Out-File -FilePath $assetPath
Add-Content -Path $assetPath -Value '{}'
[IO.File]::WriteAllText($assetPath, '{}')
[IO.File]::WriteAllBytes($assetPath, [byte[]]@())
Move-Item -Path $assetPath -Destination (Join-Path $workDir 'moved.json')
Copy-Item -Path (Join-Path $workDir 'source.json') -Destination $assetPath -Force
Rename-Item -Path $assetPath -NewName 'guidance-complexity-renamed.json'
'@

        $commands = @(
            & $script:GetAssetWriteViolationsFromContent -Content $fixture |
                ForEach-Object { $_.Command } |
                Sort-Object -Unique
        )

        $commands | Should -Be @(
            '[IO.File]::WriteAllBytes',
            '[IO.File]::WriteAllText',
            'Add-Content',
            'Copy-Item',
            'Move-Item',
            'Out-File',
            'Rename-Item',
            'Set-Content'
        ) -Because 'the contract must cover the full AC6 write-call set'
    }

    It 'Pester test sources do not write committed skills assets' -Tag 'no-gh' {
        $testSources = Get-ChildItem -Path $script:TestsRoot -Recurse -Filter '*.Tests.ps1' -File |
            Where-Object { (Resolve-Path $_.FullName).Path -ne $script:ThisFile } |
            Sort-Object -Property FullName

        $violations = @(
            foreach ($testSource in $testSources) {
                & $script:GetAssetWriteViolationsFromFile -SourcePath $testSource.FullName
            }
        )

        $violationSummary = @(
            $violations |
                Sort-Object -Property File, Line, Command |
                ForEach-Object { "$($_.File):$($_.Line) $($_.Command) targets $($_.PathArgument) resolved as $($_.ResolvedPath)" }
        )

        $violations | Should -HaveCount 0 -Because "Pester tests must not write committed assets under skills/*/assets/. Use temporary fixtures and explicit config-path injection instead.`n$($violationSummary -join "`n")"
    }
}
