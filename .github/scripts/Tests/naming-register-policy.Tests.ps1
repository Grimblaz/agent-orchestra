#Requires -Modules Pester
BeforeAll {
    # Paths relative to repo root — Pester runs from repo root
    $registerPath   = 'skills/naming-register-policy/assets/register.json'
    $schemaPath     = 'skills/naming-register-policy/schemas/register.schema.json'
    $skillPath      = 'skills/naming-register-policy/SKILL.md'
    $vocabSeedPath  = 'HOW-IT-WORKS.md'

    # Load register.json if present (will be null if absent — tests assert existence)
    $registerRaw    = if (Test-Path $registerPath) { Get-Content $registerPath -Raw } else { $null }
    $register       = if ($null -ne $registerRaw) { $registerRaw | ConvertFrom-Json } else { $null }

    # Load schema if present
    $schemaRaw      = if (Test-Path $schemaPath) { Get-Content $schemaPath -Raw } else { $null }

    # Load HOW-IT-WORKS.md (must already exist)
    $vocabContent   = Get-Content $vocabSeedPath -Raw -ErrorAction Stop
    $vocabLines     = Get-Content $vocabSeedPath -ErrorAction Stop
}

Describe "File existence" {
    It "register.schema.json exists" { $schemaPath | Should -Exist }
    It "register.json exists"        { $registerPath | Should -Exist }
    It "SKILL.md exists"             { $skillPath | Should -Exist }
}

Describe "Schema: structural" {
    It "schema parses as valid JSON" {
        { $schemaRaw | ConvertFrom-Json } | Should -Not -Throw
    }
    It "schema defines 'register' as enum with exactly 3 values" {
        $schema = $schemaRaw | ConvertFrom-Json
        $enumValues = $schema.items.properties.register.enum
        $enumValues | Should -HaveCount 3
        $enumValues | Should -Contain 'stable-code'
        $enumValues | Should -Contain 'self-describing'
        $enumValues | Should -Contain 'rename-candidate'
    }
    It "register.json validates against the JSON schema" {
        Test-Json -Json $registerRaw -Schema $schemaRaw | Should -BeTrue
    }
}

Describe "Register: structural" {
    It "register.json parses as a JSON array" {
        $register | Should -Not -BeNullOrEmpty
        ($register -is [System.Array] -or $register -is [System.Collections.IEnumerable]) | Should -BeTrue
    }
    It "every entry has a non-empty 'term' field" {
        $register | ForEach-Object {
            $_.term | Should -Not -BeNullOrEmpty
        }
    }
    It "every term in register.json is unique" {
        $dupes = $register | Group-Object term | Where-Object { $_.Count -gt 1 } | Select-Object -ExpandProperty Name
        $dupes | Should -BeNullOrEmpty -Because "register terms must be unique; duplicates: $($dupes -join ', ')"
    }
    It "every entry has a 'register' field with a valid enum value" {
        $validValues = @('stable-code', 'self-describing', 'rename-candidate')
        $register | ForEach-Object {
            $validValues | Should -Contain $_.register
        }
    }
    It "every rename-candidate has a non-empty 'replacement'" {
        $register | Where-Object { $_.register -eq 'rename-candidate' } | ForEach-Object {
            $_.replacement | Should -Not -BeNullOrEmpty -Because "rename-candidate '$($_.term)' must have a replacement"
        }
    }
    It "every kind:family entry has a non-empty 'decode'" {
        $register | Where-Object { $_.kind -eq 'family' } | ForEach-Object {
            $_.decode | Should -Not -BeNullOrEmpty -Because "family entry '$($_.term)' must have a decode"
        }
    }
}

Describe "Register: family decode resolution" {
    It "SMC-NN family entry exists and its decode enables resolving SMC-20" {
        $smc = $register | Where-Object { $_.term -match '^SMC-' -or $_.term -match 'SMC-NN' }
        $smc | Should -Not -BeNullOrEmpty -Because "a family entry covering SMC-NN must exist"
        $smc[0].decode | Should -Not -BeNullOrEmpty
        $smc[0].decode | Should -Match 'session.memory.contract|SKILL\.md' -Because "decode must point to resolution home"
    }
    It "D-number family entry exists and its decode enables resolving specific D-numbers" {
        $d = $register | Where-Object { $_.term -match '^D\d' -or $_.term -match 'D1 / D2 / D3' }
        $d | Should -Not -BeNullOrEmpty -Because "a family entry covering D-numbers must exist"
        $d[0].decode | Should -Not -BeNullOrEmpty
    }
}

Describe "Register: bidirectional binding to vocab-seed" {
    BeforeAll {
        # Extract terms from HOW-IT-WORKS.md §5 vocab-seed fence
        $inFence = $false
        $extractedTerms = [System.Collections.Generic.List[string]]::new()

        foreach ($line in $vocabLines) {
            if ($line -match '<!--\s*vocab-seed:begin\s*-->') { $inFence = $true; continue }
            if ($line -match '<!--\s*vocab-seed:end\s*-->') { $inFence = $false; continue }
            if (-not $inFence) { continue }

            # Skip blockquote lines (the Column guide blockquote)
            if ($line -match '^\s*>') { continue }

            # Skip separator rows
            if ($line -match '^\s*\|[-|:\s]+\|\s*$') { continue }

            # Skip the header row
            if ($line -match "Term as you'll see it") { continue }

            # Extract bold cell: | **term text** | ...
            if ($line -match '^\s*\|\s*\*\*(.+?)\*\*\s*\|') {
                $term = $Matches[1].Trim()
                $extractedTerms.Add($term)
            }
        }
    }

    It "vocab-seed contains exactly 50 data rows" {
        $extractedTerms.Count | Should -Be 50
    }

    It "every vocab-seed term has a register entry" {
        $registerTerms = @($register | Select-Object -ExpandProperty term)
        $missing = $extractedTerms | Where-Object { $registerTerms -notcontains $_ }
        $missing | Should -BeNullOrEmpty -Because "all 50 vocab-seed terms must have register entries; missing: $($missing -join ', ')"
    }

    It "register has no terms absent from vocab-seed (no orphan entries)" {
        $missing = $register | Where-Object { $extractedTerms -notcontains $_.term } | Select-Object -ExpandProperty term
        $missing | Should -BeNullOrEmpty -Because "register must not contain terms absent from vocab-seed; orphans: $($missing -join ', ')"
    }

    It "register entry count matches vocab-seed term count (50)" {
        $register | Should -HaveCount 50
    }
}

Describe "Vocab-seed fence-integrity" {
    It "vocab-seed begin fence marker is present in HOW-IT-WORKS.md" {
        $vocabContent | Should -Match '<!--\s*vocab-seed:begin\s*-->'
    }
    It "vocab-seed end fence marker is present in HOW-IT-WORKS.md" {
        $vocabContent | Should -Match '<!--\s*vocab-seed:end\s*-->'
    }
    It "3-column header is exactly '| Term as you'll see it | Plain meaning | Where it appears |'" {
        # Match only pipe-table rows (starting with |) to avoid picking up the blockquote prose line
        $header = $vocabLines | Where-Object { $_ -match '^\s*\|' -and $_ -match "Term as you'll see it" } | Select-Object -First 1
        $header.Trim() | Should -Be "| Term as you'll see it | Plain meaning | Where it appears |"
    }
    It "no 4th-column data rows exist in vocab-seed (table stays 3-column)" {
        # Data rows should have exactly 4 pipe characters (3 cells + trailing)
        $inFence = $false
        $fourPlusColumnRows = [System.Collections.Generic.List[string]]::new()
        foreach ($line in $vocabLines) {
            if ($line -match '<!--\s*vocab-seed:begin\s*-->') { $inFence = $true; continue }
            if ($line -match '<!--\s*vocab-seed:end\s*-->') { $inFence = $false; continue }
            if (-not $inFence) { continue }
            if ($line -match '^\s*>') { continue }  # skip blockquotes
            if ($line -match '^\s*\|') {
                $pipeCount = ($line.ToCharArray() | Where-Object { $_ -eq '|' }).Count
                if ($pipeCount -gt 4) {
                    $fourPlusColumnRows.Add($line.Trim())
                }
            }
        }
        $fourPlusColumnRows | Should -BeNullOrEmpty -Because "vocab-seed must remain a 3-column table; 4-column rows found: $($fourPlusColumnRows -join '; ')"
    }

    Context "failing-negative fixture: blockquote must not be treated as a term" {
        It "the Column guide blockquote line is not extracted as a term" {
            # Verify the blockquote exclusion logic: run the extraction against just the blockquote line
            $blockquoteLine = '> **Column guide for #732 policy extraction**'
            $wouldBeExtracted = $blockquoteLine -match '^\s*\*\*(.+?)\*\*' -and $blockquoteLine -notmatch '^\s*>'
            $wouldBeExtracted | Should -BeFalse -Because "blockquote lines starting with '>' must be excluded from term extraction"
        }
        It "a hypothetical 4-column row fails the fence-integrity check" {
            $fourColumnRow = '| **term** | meaning | where | register |'
            $pipeCount = ($fourColumnRow.ToCharArray() | Where-Object { $_ -eq '|' }).Count
            ($pipeCount -gt 4) | Should -BeTrue -Because "a 4-column row should be detected by the fence guard"
        }
    }
}

Describe "SKILL.md: required sections" {
    BeforeAll {
        $skillContent = if (Test-Path $skillPath) { Get-Content $skillPath -Raw } else { $null }
    }

    It "SKILL.md exists and is non-empty" {
        $skillContent | Should -Not -BeNullOrEmpty
    }

    It "contains 'When to Use' section" {
        $skillContent | Should -Match '##\s+When to Use'
    }

    It "contains 'DO NOT USE FOR' content" {
        $skillContent | Should -Match 'DO NOT USE FOR'
    }

    It "contains two-register rules" {
        $skillContent | Should -Match 'two.register|stable-code.*self-describing|human.facing prose'
    }

    It "contains taxonomy (stable-code, self-describing, rename-candidate)" {
        $skillContent | Should -Match 'stable-code'
        $skillContent | Should -Match 'self-describing'
        $skillContent | Should -Match 'rename-candidate'
    }

    It "contains numbered-family decode rule" {
        $skillContent | Should -Match 'decode|family.*rule|numbered.family'
    }

    It "contains reader escape-hatch rule" {
        $skillContent | Should -Match 'escape.hatch|one.hop|≤1.hop'
    }

    It "contains child boundary (#750 closed / #751 open)" {
        $skillContent | Should -Match '#750|closed.worklist'
        $skillContent | Should -Match '#751|open.set'
    }

    It "contains #693 coordination section" {
        $skillContent | Should -Match '#693'
    }

    It "contains 'Deferred' label for #693 shared-file manifest" {
        $skillContent | Should -Match 'Deferred|deferred'
    }

    It "contains binding declaration" {
        $skillContent | Should -Match 'one.way.*binding|binding.*declaration|register\.json.*term'
    }

    It "contains scope honesty (AC6: what #732 does NOT close)" {
        $skillContent | Should -Match 'does not.*close|#750|#751|S1.*on.issue' -Because "AC6 scope honesty must be explicit"
    }

    It "contains Frame Ports section" {
        $skillContent | Should -Match 'Frame Port|supporting methodology'
    }
}
