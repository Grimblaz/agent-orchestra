#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
.SYNOPSIS
    Pester 5 unit tests for write-calibration-entry.ps1.

.DESCRIPTION
    Contract under test:
      - Accepts -EntryJson (mandatory JSON string)
      - Creates .copilot-tracking/calibration/ directory if missing
      - Creates/reads review-data.json in that directory
      - Deduplicates by pr_number (overwrite on match)
      - Appends entry on no match
      - Atomic write: .tmp → validate JSON → rename to review-data.json
      - Validates required top-level fields: pr_number, created_at
      - Validates required finding fields: id, category, judge_ruling
      - Validates required summary subfields:
          prosecution_findings, pass_1_findings, pass_2_findings,
          pass_3_findings, defense_disproved, judge_accepted,
          judge_rejected, judge_deferred
      - systemic_fix_type in findings: passthrough (not validated)
      - review_stage in findings: any non-empty string accepted
      - On validation failure: exits non-zero, does not write the file
      - Output file always has calibration_version: 1
      - On success: exits 0

    Tests are written to pass once the implementation is created.

    Isolation strategy: each Context uses Push-Location into a fresh temp
    subdirectory so the script's default relative path
    (.copilot-tracking/calibration/review-data.json) is scoped per test.
#>

Describe 'write-calibration-entry.ps1' {

    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
        $script:ScriptFile = Join-Path $script:RepoRoot '.github\scripts\write-calibration-entry.ps1'

        # Master temp root — all per-test dirs live under here
        $script:TempRoot = Join-Path ([System.IO.Path]::GetTempPath()) "pester-calibration-$([System.Guid]::NewGuid().ToString('N'))"
        New-Item -ItemType Directory -Path $script:TempRoot -Force | Out-Null

        # ------------------------------------------------------------------
        # Canonical valid entry JSON used across tests
        # ------------------------------------------------------------------
        $script:ValidEntry = [ordered]@{
            pr_number  = 100
            created_at = '2026-03-20T12:00:00Z'
            findings   = @(
                [ordered]@{
                    id               = 'F1'
                    category         = 'architecture'
                    severity         = 'high'
                    points           = 10
                    pass             = 1
                    defense_verdict  = 'conceded'
                    judge_ruling     = 'sustained'
                    judge_confidence = 'high'
                    review_stage     = 'main'
                }
            )
            summary    = [ordered]@{
                prosecution_findings = 3
                pass_1_findings      = 1
                pass_2_findings      = 1
                pass_3_findings      = 1
                defense_disproved    = 1
                judge_accepted       = 2
                judge_rejected       = 1
                judge_deferred       = 0
            }
        }

        # ------------------------------------------------------------------
        # Helper: invoke the script from a given working directory.
        # Returns @{ ExitCode; Output (stdout); Error (stderr) }
        # ------------------------------------------------------------------
        $script:Invoke = {
            param(
                [string]$WorkDir,
                [string]$EntryJson
            )
            Push-Location $WorkDir
            try {
                $stdout = & pwsh -NoProfile -NonInteractive -File $script:ScriptFile `
                    -EntryJson $EntryJson 2>&1
                $exitCode = $LASTEXITCODE
                # Separate ErrorRecord objects (stderr) from plain strings (stdout)
                $errLines = ($stdout | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] }) -join "`n"
                $outLines = ($stdout | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] }) -join "`n"
                return @{ ExitCode = $exitCode; Output = $outLines; Error = $errLines }
            }
            finally {
                Pop-Location
            }
        }

        # ------------------------------------------------------------------
        # Helper: make a fresh isolated temp dir for a single test
        # ------------------------------------------------------------------
        $script:NewWorkDir = {
            $dir = Join-Path $script:TempRoot ([System.Guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            return $dir
        }

        # ------------------------------------------------------------------
        # Helper: pre-seed review-data.json in a work dir with one entry
        # ------------------------------------------------------------------
        $script:SeedFile = {
            param([string]$WorkDir, [object]$Entry)
            $calibDir = Join-Path $WorkDir '.copilot-tracking\calibration'
            New-Item -ItemType Directory -Path $calibDir -Force | Out-Null
            $data = [ordered]@{
                calibration_version = 1
                entries             = @($Entry)
            }
            $data | ConvertTo-Json -Depth 10 | Set-Content -Path (Join-Path $calibDir 'review-data.json') -Encoding UTF8
        }
    }

    AfterAll {
        try {
            if (Test-Path $script:TempRoot) {
                Remove-Item -Recurse -Force -Path $script:TempRoot
            }
        }
        finally {
            # No-op — suppress any removal errors so AfterAll never throws
        }
    }

    # ==================================================================
    # Context: directory and file creation
    # ==================================================================
    Context 'directory and file creation' {

        It 'creates the .copilot-tracking/calibration/ directory if it does not exist' {
            $workDir = & $script:NewWorkDir
            $entryJson = $script:ValidEntry | ConvertTo-Json -Depth 10 -Compress

            & $script:Invoke -WorkDir $workDir -EntryJson $entryJson

            $calibDir = Join-Path $workDir '.copilot-tracking\calibration'
            $calibDir | Should -Exist -Because 'the script must create the calibration directory on first run'
        }

        It 'creates review-data.json with calibration_version 1 on first run' {
            $workDir = & $script:NewWorkDir
            $entryJson = $script:ValidEntry | ConvertTo-Json -Depth 10 -Compress

            & $script:Invoke -WorkDir $workDir -EntryJson $entryJson

            $dataFile = Join-Path $workDir '.copilot-tracking\calibration\review-data.json'
            $dataFile | Should -Exist -Because 'review-data.json must be created'

            $data = Get-Content $dataFile -Raw | ConvertFrom-Json
            $data.calibration_version | Should -Be 1 -Because 'calibration_version must always be 1'
            $data.entries.Count | Should -Be 1 -Because 'first run with one entry must produce exactly one entry'
        }
    }

    # ==================================================================
    # Context: entry appending and deduplication
    # ==================================================================
    Context 'entry appending and deduplication' {

        It 'appends a second entry to an existing file' {
            $workDir = & $script:NewWorkDir

            # Seed with pr_number 100
            & $script:SeedFile -WorkDir $workDir -Entry $script:ValidEntry

            # Run with pr_number 200
            $newEntry = [ordered]@{
                pr_number  = 200
                created_at = '2026-03-21T09:00:00Z'
                findings   = @(
                    [ordered]@{
                        id           = 'F2'
                        category     = 'security'
                        judge_ruling = 'rejected'
                        review_stage = 'main'
                    }
                )
                summary    = [ordered]@{
                    prosecution_findings = 1
                    pass_1_findings      = 1
                    pass_2_findings      = 0
                    pass_3_findings      = 0
                    defense_disproved    = 0
                    judge_accepted       = 0
                    judge_rejected       = 1
                    judge_deferred       = 0
                }
            }
            $entryJson = $newEntry | ConvertTo-Json -Depth 10 -Compress
            & $script:Invoke -WorkDir $workDir -EntryJson $entryJson

            $dataFile = Join-Path $workDir '.copilot-tracking\calibration\review-data.json'
            $data = Get-Content $dataFile -Raw | ConvertFrom-Json
            $data.entries.Count | Should -Be 2 -Because 'appending a different pr_number must result in two entries'
        }

        It 'overwrites an existing entry for the same pr_number' {
            $workDir = & $script:NewWorkDir

            # Seed with pr_number 100
            & $script:SeedFile -WorkDir $workDir -Entry $script:ValidEntry

            # Run again with pr_number 100 but different created_at
            $updatedEntry = [ordered]@{
                pr_number  = 100
                created_at = '2026-03-22T10:00:00Z'
                findings   = @(
                    [ordered]@{
                        id           = 'F99'
                        category     = 'performance'
                        judge_ruling = 'sustained'
                        review_stage = 'main'
                    }
                )
                summary    = [ordered]@{
                    prosecution_findings = 1
                    pass_1_findings      = 1
                    pass_2_findings      = 0
                    pass_3_findings      = 0
                    defense_disproved    = 0
                    judge_accepted       = 1
                    judge_rejected       = 0
                    judge_deferred       = 0
                }
            }
            $entryJson = $updatedEntry | ConvertTo-Json -Depth 10 -Compress
            & $script:Invoke -WorkDir $workDir -EntryJson $entryJson

            $dataFile = Join-Path $workDir '.copilot-tracking\calibration\review-data.json'
            $data = Get-Content $dataFile -Raw | ConvertFrom-Json
            $data.entries.Count | Should -Be 1 -Because 'same pr_number must be overwritten, not duplicated'
            # ConvertFrom-Json returns created_at as DateTime; normalise to UTC string for comparison
            ([datetime]$data.entries[0].created_at).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss') |
            Should -Be '2026-03-22T10:00:00' -Because 'the new entry data must replace the old one'
        }
    }

    # ==================================================================
    # Context: validation — required fields
    # ==================================================================
    Context 'validation — required fields' {

        It 'exits non-zero and emits an error when pr_number is missing' {
            $workDir = & $script:NewWorkDir
            $bad = [ordered]@{
                # pr_number omitted
                created_at = '2026-03-20T12:00:00Z'
                findings   = @()
                summary    = [ordered]@{
                    prosecution_findings = 0
                    pass_1_findings      = 0
                    pass_2_findings      = 0
                    pass_3_findings      = 0
                    defense_disproved    = 0
                    judge_accepted       = 0
                    judge_rejected       = 0
                    judge_deferred       = 0
                }
            }
            $entryJson = $bad | ConvertTo-Json -Depth 10 -Compress
            $result = & $script:Invoke -WorkDir $workDir -EntryJson $entryJson

            $result.ExitCode | Should -Not -Be 0 -Because 'missing pr_number must cause a non-zero exit'
        }

        It 'exits non-zero and emits an error when created_at is missing' {
            $workDir = & $script:NewWorkDir
            $bad = [ordered]@{
                pr_number = 100
                # created_at omitted
                findings  = @()
                summary   = [ordered]@{
                    prosecution_findings = 0
                    pass_1_findings      = 0
                    pass_2_findings      = 0
                    pass_3_findings      = 0
                    defense_disproved    = 0
                    judge_accepted       = 0
                    judge_rejected       = 0
                    judge_deferred       = 0
                }
            }
            $entryJson = $bad | ConvertTo-Json -Depth 10 -Compress
            $result = & $script:Invoke -WorkDir $workDir -EntryJson $entryJson

            $result.ExitCode | Should -Not -Be 0 -Because 'missing created_at must cause a non-zero exit'
        }

        It 'exits non-zero and emits an error when a finding is missing id' {
            $workDir = & $script:NewWorkDir
            $bad = [ordered]@{
                pr_number  = 100
                created_at = '2026-03-20T12:00:00Z'
                findings   = @(
                    [ordered]@{
                        # id omitted
                        category     = 'architecture'
                        judge_ruling = 'sustained'
                        review_stage = 'main'
                    }
                )
                summary    = [ordered]@{
                    prosecution_findings = 1
                    pass_1_findings      = 1
                    pass_2_findings      = 0
                    pass_3_findings      = 0
                    defense_disproved    = 0
                    judge_accepted       = 1
                    judge_rejected       = 0
                    judge_deferred       = 0
                }
            }
            $entryJson = $bad | ConvertTo-Json -Depth 10 -Compress
            $result = & $script:Invoke -WorkDir $workDir -EntryJson $entryJson

            $result.ExitCode | Should -Not -Be 0 -Because 'a finding missing id must cause a non-zero exit'
        }

        It 'exits non-zero and emits an error when a finding is missing judge_ruling' {
            $workDir = & $script:NewWorkDir
            $bad = [ordered]@{
                pr_number  = 100
                created_at = '2026-03-20T12:00:00Z'
                findings   = @(
                    [ordered]@{
                        id           = 'F1'
                        category     = 'architecture'
                        # judge_ruling omitted
                        review_stage = 'main'
                    }
                )
                summary    = [ordered]@{
                    prosecution_findings = 1
                    pass_1_findings      = 1
                    pass_2_findings      = 0
                    pass_3_findings      = 0
                    defense_disproved    = 0
                    judge_accepted       = 1
                    judge_rejected       = 0
                    judge_deferred       = 0
                }
            }
            $entryJson = $bad | ConvertTo-Json -Depth 10 -Compress
            $result = & $script:Invoke -WorkDir $workDir -EntryJson $entryJson

            $result.ExitCode | Should -Not -Be 0 -Because 'a finding missing judge_ruling must cause a non-zero exit'
        }

        It 'exits non-zero and emits an error when summary is missing prosecution_findings' {
            $workDir = & $script:NewWorkDir
            $bad = [ordered]@{
                pr_number  = 100
                created_at = '2026-03-20T12:00:00Z'
                findings   = @(
                    [ordered]@{
                        id           = 'F1'
                        category     = 'architecture'
                        judge_ruling = 'sustained'
                        review_stage = 'main'
                    }
                )
                summary    = [ordered]@{
                    # prosecution_findings omitted
                    pass_1_findings   = 1
                    pass_2_findings   = 0
                    pass_3_findings   = 0
                    defense_disproved = 0
                    judge_accepted    = 1
                    judge_rejected    = 0
                    judge_deferred    = 0
                }
            }
            $entryJson = $bad | ConvertTo-Json -Depth 10 -Compress
            $result = & $script:Invoke -WorkDir $workDir -EntryJson $entryJson

            $result.ExitCode | Should -Not -Be 0 `
                -Because 'summary missing prosecution_findings must cause a non-zero exit'
        }

        It 'does not write to the file when validation fails' {
            $workDir = & $script:NewWorkDir
            # Missing pr_number — guaranteed validation failure
            $bad = [ordered]@{
                created_at = '2026-03-20T12:00:00Z'
                findings   = @()
                summary    = [ordered]@{
                    prosecution_findings = 0
                    pass_1_findings      = 0
                    pass_2_findings      = 0
                    pass_3_findings      = 0
                    defense_disproved    = 0
                    judge_accepted       = 0
                    judge_rejected       = 0
                    judge_deferred       = 0
                }
            }
            $entryJson = $bad | ConvertTo-Json -Depth 10 -Compress
            & $script:Invoke -WorkDir $workDir -EntryJson $entryJson

            $dataFile = Join-Path $workDir '.copilot-tracking\calibration\review-data.json'
            $dataFile | Should -Not -Exist `
                -Because 'no file should be created or modified when validation fails'
        }
    }

    # ==================================================================
    # Context: field passthrough
    # ==================================================================
    Context 'field passthrough' {

        It 'stores systemic_fix_type if present in a finding' {
            $workDir = & $script:NewWorkDir
            $entry = [ordered]@{
                pr_number  = 100
                created_at = '2026-03-20T12:00:00Z'
                findings   = @(
                    [ordered]@{
                        id                = 'F1'
                        category          = 'architecture'
                        judge_ruling      = 'sustained'
                        review_stage      = 'main'
                        systemic_fix_type = 'refactor-extract-method'
                    }
                )
                summary    = [ordered]@{
                    prosecution_findings = 1
                    pass_1_findings      = 1
                    pass_2_findings      = 0
                    pass_3_findings      = 0
                    defense_disproved    = 0
                    judge_accepted       = 1
                    judge_rejected       = 0
                    judge_deferred       = 0
                }
            }
            $entryJson = $entry | ConvertTo-Json -Depth 10 -Compress
            & $script:Invoke -WorkDir $workDir -EntryJson $entryJson

            $dataFile = Join-Path $workDir '.copilot-tracking\calibration\review-data.json'
            $data = Get-Content $dataFile -Raw | ConvertFrom-Json
            $data.entries[0].findings[0].systemic_fix_type | Should -Be 'refactor-extract-method' `
                -Because 'systemic_fix_type must be stored as a passthrough field'
        }

        It 'stores the entry successfully when systemic_fix_type is absent from a finding' {
            $workDir = & $script:NewWorkDir
            # Use the canonical valid entry (no systemic_fix_type)
            $entryJson = $script:ValidEntry | ConvertTo-Json -Depth 10 -Compress
            $result = & $script:Invoke -WorkDir $workDir -EntryJson $entryJson

            $result.ExitCode | Should -Be 0 `
                -Because 'absence of systemic_fix_type must not cause failure'

            $dataFile = Join-Path $workDir '.copilot-tracking\calibration\review-data.json'
            $data = Get-Content $dataFile -Raw | ConvertFrom-Json
            $data.entries.Count | Should -Be 1 -Because 'entry without systemic_fix_type must be stored'
        }

        It 'accepts any non-empty string for review_stage' {
            $workDir = & $script:NewWorkDir
            $entry = [ordered]@{
                pr_number  = 100
                created_at = '2026-03-20T12:00:00Z'
                findings   = @(
                    [ordered]@{
                        id           = 'F1'
                        category     = 'architecture'
                        judge_ruling = 'sustained'
                        review_stage = 'custom-stage'   # non-standard value
                    }
                )
                summary    = [ordered]@{
                    prosecution_findings = 1
                    pass_1_findings      = 1
                    pass_2_findings      = 0
                    pass_3_findings      = 0
                    defense_disproved    = 0
                    judge_accepted       = 1
                    judge_rejected       = 0
                    judge_deferred       = 0
                }
            }
            $entryJson = $entry | ConvertTo-Json -Depth 10 -Compress
            $result = & $script:Invoke -WorkDir $workDir -EntryJson $entryJson

            $result.ExitCode | Should -Be 0 `
                -Because 'review_stage accepts any non-empty string — no enum restriction'

            $dataFile = Join-Path $workDir '.copilot-tracking\calibration\review-data.json'
            $data = Get-Content $dataFile -Raw | ConvertFrom-Json
            $data.entries[0].findings[0].review_stage | Should -Be 'custom-stage' `
                -Because 'custom review_stage value must be stored verbatim'
        }

        It 'serializes single-element findings as a JSON array, not an object' {
            # Regression test for CE-F4: ConvertTo-NormalizedObject must not collapse
            # a single-element findings array to a plain JSON object due to pipeline unrolling.
            $workDir = & $script:NewWorkDir
            $entryJson = $script:ValidEntry | ConvertTo-Json -Depth 10 -Compress
            & $script:Invoke -WorkDir $workDir -EntryJson $entryJson

            $dataFile = Join-Path $workDir '.copilot-tracking\calibration\review-data.json'
            $data = Get-Content $dataFile -Raw | ConvertFrom-Json
            $findings = $data.entries[0].findings
            $findings.GetType().IsArray | Should -BeTrue `
                -Because 'findings must be a JSON array even with one element'
            $findings.Count | Should -Be 1 -Because 'exactly one finding was written'
        }
    }

    # ==================================================================
    # Context: atomic write
    # ==================================================================
    Context 'atomic write' {

        It 'exits 0 and produces valid JSON output file' {
            $workDir = & $script:NewWorkDir
            $entryJson = $script:ValidEntry | ConvertTo-Json -Depth 10 -Compress
            $result = & $script:Invoke -WorkDir $workDir -EntryJson $entryJson

            $result.ExitCode | Should -Be 0 -Because 'successful write must exit 0'

            $dataFile = Join-Path $workDir '.copilot-tracking\calibration\review-data.json'
            $dataFile | Should -Exist -Because 'review-data.json must exist after a successful write'

            $raw = Get-Content $dataFile -Raw
            { $raw | ConvertFrom-Json } | Should -Not -Throw `
                -Because 'review-data.json must contain valid JSON'

            # No leftover .tmp file
            $tmpFiles = Get-ChildItem -Path (Join-Path $workDir '.copilot-tracking\calibration') `
                -Filter '*.tmp' -ErrorAction SilentlyContinue
            $tmpFiles | Should -BeNullOrEmpty `
                -Because 'atomic write must not leave .tmp files behind after success'
        }
    }
}
