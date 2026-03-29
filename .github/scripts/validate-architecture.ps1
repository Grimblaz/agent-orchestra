# validate-architecture.ps1
#
# Template PowerShell validation script for architecture rules and code quality checks.
# This script demonstrates patterns for implementing custom validations for your project.
#
# Exit Codes:
#   0  = All validations passed
#   1+ = One or more validations failed
#
# Usage:
#   .\validate-architecture.ps1
#   .\validate-architecture.ps1 -Verbose

[CmdletBinding()]
param()

# Track validation failures
$script:FailureCount = 0

# ANSI color codes for output formatting
$Red = "`e[31m"
$Green = "`e[32m"
$Yellow = "`e[33m"
$Reset = "`e[0m"

function Write-ValidationHeader {
    param([string]$Message)
    Write-Host "`n=== $Message ===" -ForegroundColor Cyan
}

function Write-Success {
    param([string]$Message)
    Write-Host "${Green}✓${Reset} $Message"
}

function Write-Failure {
    param([string]$Message)
    Write-Host "${Red}✗${Reset} $Message"
    $script:FailureCount++
}

function Write-ValidationWarning {
    param([string]$Message)
    Write-Host "${Yellow}⚠${Reset} $Message"
}

# ============================================================================
# VALIDATION FUNCTIONS
# ============================================================================

function Test-DirectoryStructure {
    <#
    .SYNOPSIS
    Validates that required directories exist in the project.

    .DESCRIPTION
    [CUSTOMIZE] Add your project-specific directory requirements.
    Examples: src/, tests/, docs/, config/
    #>

    Write-ValidationHeader "Directory Structure"

    # [CUSTOMIZE] Define your required directories
    $RequiredDirectories = @(
        ".github/agents"
        ".github/skills"
        "examples"
        ".github"
    )

    foreach ($dir in $RequiredDirectories) {
        if (Test-Path $dir) {
            Write-Success "Directory exists: $dir"
        }
        else {
            Write-Failure "Missing required directory: $dir"
        }
    }
}

function Test-RequiredFiles {
    <#
    .SYNOPSIS
    Validates that required files exist in the project.

    .DESCRIPTION
    [CUSTOMIZE] Add your project-specific file requirements.
    Examples: package.json, README.md, .gitignore
    #>

    Write-ValidationHeader "Required Files"

    # [CUSTOMIZE] Define your required files
    $RequiredFiles = @(
        "README.md"
        "CONTRIBUTING.md"
        "CUSTOMIZATION.md"
    )

    foreach ($file in $RequiredFiles) {
        if (Test-Path $file) {
            Write-Success "File exists: $file"
        }
        else {
            Write-Failure "Missing required file: $file"
        }
    }
}

function Test-LayerViolations {
    <#
    .SYNOPSIS
    Checks for architecture layer violations (e.g., forbidden imports).

    .DESCRIPTION
    [CUSTOMIZE] Implement your layer dependency rules.
    Example: Presentation layer should not directly import from Data layer.
    This is a template - adapt the logic for your architecture.
    #>

    Write-ValidationHeader "Layer Violations"

    # [CUSTOMIZE] Example: Check for forbidden import patterns
    # This is a template - replace with your actual architecture rules

    # Example: Controllers shouldn't import repositories directly
    # $ControllerFiles = Get-ChildItem -Path "src/controllers" -Filter "*.cs" -Recurse -ErrorAction SilentlyContinue
    # foreach ($file in $ControllerFiles) {
    #     $content = Get-Content $file.FullName -Raw
    #     if ($content -match 'using.*\.Repositories') {
    #         Write-Failure "Layer violation in $($file.Name): Controllers should not import Repositories directly"
    #     }
    # }

    # Example: Domain layer shouldn't reference infrastructure
    # $DomainFiles = Get-ChildItem -Path "src/domain" -Filter "*.java" -Recurse -ErrorAction SilentlyContinue
    # foreach ($file in $DomainFiles) {
    #     $content = Get-Content $file.FullName -Raw
    #     if ($content -match 'import.*\.infrastructure\.') {
    #         Write-Failure "Layer violation in $($file.Name): Domain should not import Infrastructure"
    #     }
    # }

    Write-ValidationWarning "[CUSTOMIZE] Implement your layer violation checks here"
}

function Test-ForbiddenDependencies {
    <#
    .SYNOPSIS
    Checks for forbidden dependencies or imports.

    .DESCRIPTION
    [CUSTOMIZE] Define forbidden libraries or patterns for your project.
    Examples: outdated libraries, security vulnerabilities, banned packages
    #>

    Write-ValidationHeader "Forbidden Dependencies"

    # [CUSTOMIZE] Example: Check package.json for forbidden dependencies
    # if (Test-Path "package.json") {
    #     $packageJson = Get-Content "package.json" | ConvertFrom-Json
    #     $ForbiddenPackages = @("moment", "lodash")  # Example: prefer date-fns and native methods
    #
    #     foreach ($forbidden in $ForbiddenPackages) {
    #         if ($packageJson.dependencies.$forbidden -or $packageJson.devDependencies.$forbidden) {
    #             Write-Failure "Forbidden dependency found: $forbidden"
    #         }
    #     }
    # }

    # [CUSTOMIZE] Example: Check for forbidden imports in code
    # $SourceFiles = Get-ChildItem -Path "src" -Filter "*.ts" -Recurse -ErrorAction SilentlyContinue
    # foreach ($file in $SourceFiles) {
    #     $content = Get-Content $file.FullName -Raw
    #     if ($content -match 'require\(') {
    #         Write-Failure "CommonJS require() found in $($file.Name) - use ES6 imports"
    #     }
    # }

    Write-ValidationWarning "[CUSTOMIZE] Implement your forbidden dependency checks here"
}

function Test-NamingConventions {
    <#
    .SYNOPSIS
    Validates file and directory naming conventions.

    .DESCRIPTION
    [CUSTOMIZE] Implement your project's naming standards.
    Examples: PascalCase for classes, kebab-case for files, etc.
    #>

    Write-ValidationHeader "Naming Conventions"

    # [CUSTOMIZE] Example: Check for consistent file naming
    # $SourceFiles = Get-ChildItem -Path "src" -Filter "*.ts" -Recurse -ErrorAction SilentlyContinue
    # foreach ($file in $SourceFiles) {
    #     # Example: TypeScript files should be kebab-case
    #     if ($file.BaseName -cmatch '[A-Z]') {
    #         Write-Failure "File name should be kebab-case: $($file.Name)"
    #     }
    # }

    # [CUSTOMIZE] Example: Check for test file naming
    # $TestFiles = Get-ChildItem -Path "tests" -Filter "*.test.*" -Recurse -ErrorAction SilentlyContinue
    # foreach ($file in $TestFiles) {
    #     if ($file.Name -notmatch '\.test\.(js|ts)$') {
    #         Write-Failure "Test file should end with .test.js or .test.ts: $($file.Name)"
    #     }
    # }

    Write-ValidationWarning "[CUSTOMIZE] Implement your naming convention checks here"
}

function Test-CodeComplexity {
    <#
    .SYNOPSIS
    Checks for code complexity metrics and quality indicators.

    .DESCRIPTION
    [CUSTOMIZE] Implement complexity checks for your language.
    Examples: cyclomatic complexity, file size limits, function length
    #>

    Write-ValidationHeader "Code Complexity"

    # [CUSTOMIZE] Example: Check file sizes
    # $MaxFileSizeKB = 500
    # $SourceFiles = Get-ChildItem -Path "src" -Filter "*.cs" -Recurse -ErrorAction SilentlyContinue
    # foreach ($file in $SourceFiles) {
    #     $sizeKB = ($file.Length / 1KB)
    #     if ($sizeKB -gt $MaxFileSizeKB) {
    #         Write-Failure "File too large ($([int]$sizeKB) KB): $($file.Name)"
    #     }
    # }

    # [CUSTOMIZE] Example: Check for long functions (simplified example)
    # $SourceFiles = Get-ChildItem -Path "src" -Filter "*.py" -Recurse -ErrorAction SilentlyContinue
    # foreach ($file in $SourceFiles) {
    #     $content = Get-Content $file.FullName
    #     $inFunction = $false
    #     $functionLines = 0
    #     foreach ($line in $content) {
    #         if ($line -match '^\s*def\s+') {
    #             $inFunction = $true
    #             $functionLines = 0
    #         } elseif ($inFunction) {
    #             $functionLines++
    #             if ($line -match '^\s*def\s+' -or $line -match '^\s*class\s+') {
    #                 $inFunction = $false
    #             }
    #             if ($functionLines -gt 50) {
    #                 Write-Failure "Function too long in $($file.Name)"
    #                 $inFunction = $false
    #             }
    #         }
    #     }
    # }

    Write-ValidationWarning "[CUSTOMIZE] Implement your complexity checks here"
}

function Test-DocumentationCoverage {
    <#
    .SYNOPSIS
    Validates documentation requirements.

    .DESCRIPTION
    [CUSTOMIZE] Implement documentation standards for your project.
    Examples: JSDoc comments, README updates, API documentation
    #>

    Write-ValidationHeader "Documentation Coverage"

    # [CUSTOMIZE] Example: Check for README in each major directory
    # $MajorDirectories = @("src", "tests", "docs")
    # foreach ($dir in $MajorDirectories) {
    #     if (Test-Path $dir) {
    #         $readmePath = Join-Path $dir "README.md"
    #         if (Test-Path $readmePath) {
    #             Write-Success "Documentation exists: $readmePath"
    #         } else {
    #             Write-ValidationWarning "Missing README in: $dir"
    #         }
    #     }
    # }

    # [CUSTOMIZE] Example: Check for public API documentation
    # $PublicClasses = Get-ChildItem -Path "src/api" -Filter "*.cs" -Recurse -ErrorAction SilentlyContinue
    # foreach ($file in $PublicClasses) {
    #     $content = Get-Content $file.FullName -Raw
    #     if ($content -match 'public\s+class\s+' -and $content -notmatch '///\s*<summary>') {
    #         Write-ValidationWarning "Missing XML documentation in: $($file.Name)"
    #     }
    # }

    Write-ValidationWarning "[CUSTOMIZE] Implement your documentation checks here"
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================

try {
    Write-Host "`n╔════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "║   Architecture Validation - Copilot Orchestra        ║" -ForegroundColor Cyan
    Write-Host "╚════════════════════════════════════════════════════════╝`n" -ForegroundColor Cyan

    Write-Host "Starting validation at $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')`n"

    # Run all validation functions
    Test-DirectoryStructure
    Test-RequiredFiles
    Test-LayerViolations
    Test-ForbiddenDependencies
    Test-NamingConventions
    Test-CodeComplexity
    Test-DocumentationCoverage

    # Summary
    Write-Host ("`n" + ("=" * 60))
    Write-Host "VALIDATION SUMMARY" -ForegroundColor Cyan
    Write-Host ("=" * 60)

    if ($script:FailureCount -eq 0) {
        Write-Host "${Green}✓ All validations passed!${Reset}`n"
        exit 0
    }
    else {
        Write-Host "${Red}✗ $script:FailureCount validation(s) failed${Reset}`n"
        exit 1
    }

}
catch {
    Write-Host "`n${Red}ERROR: Validation script encountered an error${Reset}" -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    Write-Host $_.ScriptStackTrace -ForegroundColor Red
    exit 2
}
