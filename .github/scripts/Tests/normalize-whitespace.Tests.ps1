#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
.SYNOPSIS
    Pester contract tests for normalize-whitespace.ps1 and the pre-commit allowlist boundary.

.DESCRIPTION
    Contract under test for issue #248:
      - A dedicated helper exists at .github/scripts/normalize-whitespace.ps1
      - The helper trims trailing horizontal whitespace
      - The helper removes trailing blank lines at EOF
      - The helper ensures exactly one final newline
      - Already-normalized files remain byte-for-byte no-ops
      - UTF-8 BOM/no-BOM state is preserved
      - Unsupported or failing files are treated non-fatally
      - The generic pre-commit whitespace lane is scoped exactly to:
          *.json, *.jsonc, *.yml, *.yaml, *.psd1, *.txt,
          .gitignore, .gitattributes, .editorconfig
      - The generic lane must not bleed into .md, .ps1, .psm1, or generic extensionless files

#>

Describe 'normalize-whitespace.ps1' {

    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
        $script:HelperPath = Join-Path $script:RepoRoot '.github\scripts\normalize-whitespace.ps1'

        $script:TempRoot = Join-Path ([System.IO.Path]::GetTempPath()) `
            "pester-normalize-whitespace-$([System.Guid]::NewGuid().ToString('N'))"
        New-Item -ItemType Directory -Path $script:TempRoot -Force | Out-Null

        $script:NewTempDir = {
            $dir = Join-Path $script:TempRoot ([System.Guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            return $dir
        }

        $script:WriteUtf8Text = {
            param(
                [string]$Path,
                [string]$Content,
                [bool]$WithBom = $false
            )

            $encoding = [System.Text.UTF8Encoding]::new($WithBom)
            [System.IO.File]::WriteAllText($Path, $Content, $encoding)
        }

        $script:ReadBytes = {
            param([string]$Path)
            return [System.IO.File]::ReadAllBytes($Path)
        }

        $script:ReadText = {
            param([string]$Path)
            return [System.IO.File]::ReadAllText($Path)
        }

        $script:HasUtf8Bom = {
            param([byte[]]$Bytes)
            return $Bytes.Length -ge 3 -and
            $Bytes[0] -eq 0xEF -and
            $Bytes[1] -eq 0xBB -and
            $Bytes[2] -eq 0xBF
        }

        $script:InvokeHelper = {
            param([string]$Path)

            $output = & pwsh -NoProfile -NonInteractive -File $script:HelperPath -Path $Path 2>&1
            $exitCode = $LASTEXITCODE
            $renderedOutput = ($output | ForEach-Object {
                    if ($_ -is [System.Management.Automation.ErrorRecord]) {
                        $_.ToString()
                    }
                    else {
                        "$_"
                    }
                }) -join "`n"

            return @{
                ExitCode = $exitCode
                Output   = $renderedOutput.Trim()
            }
        }
    }

    AfterAll {
        if (Test-Path $script:TempRoot) {
            Remove-Item -Path $script:TempRoot -Recurse -Force
        }
    }

    Context 'helper contract' {

        It 'exists at the planned helper path' {
            Test-Path $script:HelperPath | Should -BeTrue `
                -Because 'issue #248 introduces a dedicated helper at .github/scripts/normalize-whitespace.ps1 rather than embedding the behavior directly in the hook'
        }

        It 'trims trailing horizontal whitespace without rewriting existing indentation' {
            $dir = & $script:NewTempDir
            $path = Join-Path $dir 'sample.json'
            $original = (@(
                    '{',
                    '    "name": "alpha"   ',
                    ('      "keptIndent": true' + "`t "),
                    '}'
                ) -join "`n") + "`n"
            $expected = (@(
                    '{',
                    '    "name": "alpha"',
                    '      "keptIndent": true',
                    '}'
                ) -join "`n") + "`n"
            & $script:WriteUtf8Text -Path $path -Content $original -WithBom $false

            $result = & $script:InvokeHelper -Path $path
            $actual = & $script:ReadText -Path $path

            $result.ExitCode | Should -Be 0 -Because 'whitespace-only normalization should succeed for allowlisted text files'
            $actual | Should -Be $expected -Because 'the helper must remove only trailing horizontal whitespace while leaving existing indentation depth intact'
        }

        It 'removes trailing blank lines at EOF and leaves exactly one final newline' {
            $dir = & $script:NewTempDir
            $path = Join-Path $dir 'notes.txt'
            $original = "alpha`n`n`n"
            $expected = "alpha`n"
            & $script:WriteUtf8Text -Path $path -Content $original -WithBom $false

            $result = & $script:InvokeHelper -Path $path
            $actual = & $script:ReadText -Path $path

            $result.ExitCode | Should -Be 0 -Because 'EOF cleanup should be a successful normalization path'
            $actual | Should -Be $expected -Because 'the helper must remove trailing blank lines and normalize the file to a single final newline'
        }

        It 'preserves already-normalized files as byte-for-byte no-ops' {
            $dir = & $script:NewTempDir
            $path = Join-Path $dir 'already-clean.yaml'
            $original = (@(
                    'root:',
                    '  child: true'
                ) -join "`n") + "`n"
            & $script:WriteUtf8Text -Path $path -Content $original -WithBom $false
            $beforeHex = [System.Convert]::ToHexString((& $script:ReadBytes -Path $path))

            $result = & $script:InvokeHelper -Path $path
            $afterHex = [System.Convert]::ToHexString((& $script:ReadBytes -Path $path))

            $result.ExitCode | Should -Be 0 -Because 'already-normalized files should not be treated as errors'
            $afterHex | Should -Be $beforeHex -Because 'a normalized file should remain a no-op with no content or encoding churn'
        }

        It 'preserves a UTF-8 BOM when the file content changes' {
            $dir = & $script:NewTempDir
            $path = Join-Path $dir 'bom.jsonc'
            $original = "value   `n`n"
            $expected = "value`n"
            & $script:WriteUtf8Text -Path $path -Content $original -WithBom $true

            $result = & $script:InvokeHelper -Path $path
            $bytes = & $script:ReadBytes -Path $path
            $actual = & $script:ReadText -Path $path

            $result.ExitCode | Should -Be 0 -Because 'normalization should succeed for UTF-8 BOM files'
            (& $script:HasUtf8Bom -Bytes $bytes) | Should -BeTrue -Because 'the helper must preserve an existing UTF-8 BOM rather than stripping it as encoding-only churn'
            $actual | Should -Be $expected -Because 'the helper must still normalize content while preserving BOM state'
        }

        It 'preserves UTF-8 without BOM when the file content changes' {
            $dir = & $script:NewTempDir
            $path = Join-Path $dir '.editorconfig'
            $original = "root = true   `n`n"
            $expected = "root = true`n"
            & $script:WriteUtf8Text -Path $path -Content $original -WithBom $false

            $result = & $script:InvokeHelper -Path $path
            $bytes = & $script:ReadBytes -Path $path
            $actual = & $script:ReadText -Path $path

            $result.ExitCode | Should -Be 0 -Because 'normalization should succeed for UTF-8 files without BOM'
            (& $script:HasUtf8Bom -Bytes $bytes) | Should -BeFalse -Because 'the helper must not add a BOM to files that were already UTF-8 without BOM'
            $actual | Should -Be $expected -Because 'content normalization must not change no-BOM encoding state'
        }

        It 'treats missing files non-fatally' {
            $dir = & $script:NewTempDir
            $path = Join-Path $dir 'missing.txt'

            $result = & $script:InvokeHelper -Path $path

            $result.ExitCode | Should -Be 0 -Because 'hook callers must be able to continue when one normalization target cannot be processed'
        }

        It 'treats unsupported binary-like files non-fatally and leaves them unchanged' {
            $dir = & $script:NewTempDir
            $path = Join-Path $dir 'binary.txt'
            $originalBytes = [byte[]](0x00, 0x41, 0x42, 0x43, 0x09, 0x20, 0x0A)
            [System.IO.File]::WriteAllBytes($path, $originalBytes)
            $beforeHex = [System.Convert]::ToHexString((& $script:ReadBytes -Path $path))

            $result = & $script:InvokeHelper -Path $path
            $afterHex = [System.Convert]::ToHexString((& $script:ReadBytes -Path $path))

            $result.ExitCode | Should -Be 0 -Because 'unsupported files must not make the hook path fatal'
            $afterHex | Should -Be $beforeHex -Because 'unsupported files should be skipped rather than mutated'
        }
    }
}

Describe '.githooks/pre-commit whitespace-lane ownership contract' {

    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
        $script:HookPath = Join-Path $script:RepoRoot '.githooks\pre-commit'
        $script:HookContent = Get-Content -Path $script:HookPath -Raw

        $script:GetGenericSelectorPattern = {
            $match = [regex]::Match(
                $script:HookContent,
                "(?ms)grep -E '(?<pattern>[^']*(?:json|jsonc|yml|yaml|psd1|txt|gitignore|gitattributes|editorconfig)[^']*)'"
            )

            if ($match.Success) {
                return $match.Groups['pattern'].Value
            }

            return ''
        }
    }

    It 'keeps the Markdown lane scoped to .md files' {
        $script:HookContent | Should -Match "(?m)^\s*staged_md=.*grep -E '\\.md\$'" `
            -Because 'the existing semantic Markdown lane must keep owning only Markdown files'
    }

    It 'keeps the PowerShell lane scoped to .ps1 files only' {
        $script:HookContent | Should -Match "(?m)^staged_ps1=.*grep -E '\\.ps1\$'" `
            -Because 'the existing semantic PowerShell lane must keep owning only .ps1 files'
        $script:HookContent | Should -Not -Match '\\.psm1\$|\\.psd1\$' `
            -Because 'issue #248 must not widen the semantic PowerShell lane to .psm1 or .psd1'
    }

    It 'adds a generic whitespace-only selector for the exact allowlist without ownership bleed' {
        $pattern = & $script:GetGenericSelectorPattern

        $pattern | Should -Not -BeNullOrEmpty -Because 'the hook needs a third selector dedicated to the new generic whitespace lane'
        $pattern | Should -Match 'json' -Because 'the generic lane must include *.json'
        $pattern | Should -Match 'jsonc' -Because 'the generic lane must include *.jsonc'
        $pattern | Should -Match 'yml' -Because 'the generic lane must include *.yml'
        $pattern | Should -Match 'yaml' -Because 'the generic lane must include *.yaml'
        $pattern | Should -Match 'psd1' -Because 'the generic lane must include *.psd1'
        $pattern | Should -Match 'txt' -Because 'the generic lane must include *.txt'
        $pattern | Should -Match 'gitignore' -Because 'the generic lane must include .gitignore explicitly'
        $pattern | Should -Match 'gitattributes' -Because 'the generic lane must include .gitattributes explicitly'
        $pattern | Should -Match 'editorconfig' -Because 'the generic lane must include .editorconfig explicitly'
        $pattern | Should -Not -Match '\\.md\$|md\|' -Because 'the generic lane must not take ownership of Markdown files'
        $pattern | Should -Not -Match '\\.ps1\$|ps1\|' -Because 'the generic lane must not take ownership of .ps1 files'
        $pattern | Should -Not -Match 'psm1' -Because 'issue #248 explicitly leaves .psm1 support out of scope'
        $pattern | Should -Not -Match '\^\[\^\.]\+\$|\^\[\^\.\]\[\^/\]\*\$' -Because 'the generic lane must not broaden to generic extensionless-file handling beyond the explicit dotfile allowlist'
    }
}