#Requires -Version 7.0
<#
.SYNOPSIS
    Per-dispatch token attribution extraction (issue #975, D-975-2).
.DESCRIPTION
    Bounded extraction over Claude Code session subagent transcripts
    (subagents/agent-{toolUseId}.jsonl). Produces per-dispatch token
    attribution at the grain cost-attribution.ps1 cannot provide: that
    library maps every review dispatch into one aggregate "review" port,
    while this one reports each dispatch separately.

    Scope boundary (owner decision D-975-2): this is the sole exception to
    riding the #489 cost_summary machinery. It reads transcript files only;
    it does not touch the rate table, ports, or the PR-body metrics block.

    Grain notes grounded against live transcripts (2026-08-02):
    - One transcript file per dispatch; the toolUseId is the filename stem.
    - Assistant lines repeat per streaming chunk; usage must be deduplicated
      by message.id. Per-request input/cache token fields are constant across
      chunks of one message; output_tokens grows, so the maximum per
      message.id is the final value.
    - The first user line carries the dispatched prompt verbatim - the basis
      for prompt-prefix comparison (AC1) and selector identification.
#>

Set-StrictMode -Version Latest

function Read-DispatchTranscript {
    <#
    .SYNOPSIS
        Parse one subagent transcript file into a per-dispatch attribution record.
    .PARAMETER Path
        Path to an agent-{toolUseId}.jsonl transcript file.
    .OUTPUTS
        PSCustomObject with dispatch identity, prompt metadata, tool-call list,
        and deduplicated token usage sums.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Transcript file not found: $Path"
    }

    $agentId = [System.IO.Path]::GetFileNameWithoutExtension($Path) -replace '^agent-', ''

    $firstUserContent = $null
    $models = [System.Collections.Generic.HashSet[string]]::new()
    $toolCalls = [System.Collections.Generic.List[object]]::new()
    $firstTimestamp = $null
    $lastTimestamp = $null
    # message.id -> usage record with final (max) output_tokens
    $usageById = [ordered]@{}

    foreach ($line in [System.IO.File]::ReadLines($Path)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try {
            $obj = $line | ConvertFrom-Json
        }
        catch {
            continue  # tolerate malformed lines; attribution stays bounded to parseable rows
        }

        $ts = $null
        if ($obj.PSObject.Properties.Match('timestamp').Count -gt 0) { $ts = $obj.timestamp }
        if ($ts -is [datetime]) {
            # ConvertFrom-Json materializes ISO strings as DateTime; keep the
            # instant and a round-trippable UTC form so later parses do not
            # reinterpret the value in local time.
            $ts = $ts.ToUniversalTime().ToString('o')
        }
        elseif ($null -ne $ts) {
            $ts = [string]$ts
        }
        if ($ts) {
            if (-not $firstTimestamp) { $firstTimestamp = $ts }
            $lastTimestamp = $ts
        }

        $lineType = $null
        if ($obj.PSObject.Properties.Match('type').Count -gt 0) { $lineType = $obj.type }

        if ($lineType -eq 'user' -and $null -eq $firstUserContent) {
            $content = $obj.message.content
            if ($content -is [string]) {
                $firstUserContent = $content
            }
            elseif ($null -ne $content) {
                # content-block array form: concatenate text blocks
                $textParts = @($content | Where-Object { $_.PSObject.Properties.Match('text').Count -gt 0 } | ForEach-Object { $_.text })
                $firstUserContent = $textParts -join "`n"
            }
        }

        if ($lineType -ne 'assistant') { continue }

        $msg = $obj.message
        if ($null -eq $msg) { continue }

        if ($msg.PSObject.Properties.Match('model').Count -gt 0 -and $msg.model) {
            [void]$models.Add([string]$msg.model)
        }

        if ($msg.PSObject.Properties.Match('content').Count -gt 0 -and $msg.content -is [System.Array]) {
            foreach ($block in $msg.content) {
                if ($block.PSObject.Properties.Match('type').Count -gt 0 -and $block.type -eq 'tool_use') {
                    $inputSummary = ''
                    if ($block.PSObject.Properties.Match('input').Count -gt 0 -and $null -ne $block.input) {
                        foreach ($candidate in @('file_path', 'command', 'pattern', 'url', 'prompt', 'query')) {
                            if ($block.input.PSObject.Properties.Match($candidate).Count -gt 0 -and $block.input.$candidate) {
                                $val = [string]$block.input.$candidate
                                if ($val.Length -gt 200) { $val = $val.Substring(0, 200) }
                                $inputSummary = $val
                                break
                            }
                        }
                    }
                    $toolCalls.Add([pscustomobject]@{
                            tool  = [string]$block.name
                            input = $inputSummary
                        })
                }
            }
        }

        if ($msg.PSObject.Properties.Match('usage').Count -eq 0 -or $null -eq $msg.usage) { continue }
        $msgId = $null
        if ($msg.PSObject.Properties.Match('id').Count -gt 0) { $msgId = $msg.id }
        if (-not $msgId) { continue }

        $u = $msg.usage
        $rec = [pscustomobject]@{
            input_tokens                 = [long]($u.input_tokens ?? 0)
            cache_creation_input_tokens  = [long]($u.cache_creation_input_tokens ?? 0)
            cache_read_input_tokens      = [long]($u.cache_read_input_tokens ?? 0)
            output_tokens                = [long]($u.output_tokens ?? 0)
        }
        if ($usageById.Contains($msgId)) {
            # streaming chunk of the same request: keep the largest output_tokens
            if ($rec.output_tokens -gt $usageById[$msgId].output_tokens) {
                $usageById[$msgId] = $rec
            }
        }
        else {
            $usageById[$msgId] = $rec
        }
    }

    $sumInput = 0L; $sumCacheCreate = 0L; $sumCacheRead = 0L; $sumOutput = 0L
    foreach ($rec in $usageById.Values) {
        $sumInput += $rec.input_tokens
        $sumCacheCreate += $rec.cache_creation_input_tokens
        $sumCacheRead += $rec.cache_read_input_tokens
        $sumOutput += $rec.output_tokens
    }

    $selector = $null
    $handshakeIssuedAt = $null
    if ($firstUserContent) {
        $selMatch = [regex]::Match($firstUserContent, '(?m)^Review mode selector: "([^"]+)"')
        if ($selMatch.Success) { $selector = $selMatch.Groups[1].Value }
        $hsMatch = [regex]::Match($firstUserContent, '(?m)^handshake_issued_at: (\S+)')
        if ($hsMatch.Success) { $handshakeIssuedAt = $hsMatch.Groups[1].Value }
    }

    return [pscustomobject]@{
        agent_id            = $agentId
        transcript_path     = (Resolve-Path -LiteralPath $Path).Path
        models              = @($models) -join ','
        selector            = $selector
        handshake_issued_at = $handshakeIssuedAt
        prompt_chars        = ($firstUserContent ?? '').Length
        prompt_text         = $firstUserContent
        api_calls           = $usageById.Count
        tool_calls          = $toolCalls
        input_tokens        = $sumInput
        cache_creation_input_tokens = $sumCacheCreate
        cache_read_input_tokens     = $sumCacheRead
        output_tokens       = $sumOutput
        total_tokens        = $sumInput + $sumCacheCreate + $sumCacheRead + $sumOutput
        first_timestamp     = $firstTimestamp
        last_timestamp      = $lastTimestamp
    }
}

function Get-DispatchAttribution {
    <#
    .SYNOPSIS
        Extract per-dispatch attribution records for every subagent transcript in a directory.
    .PARAMETER TranscriptDir
        A session subagents directory containing agent-*.jsonl files, or any
        directory holding copied transcript files.
    .PARAMETER Since
        Optional ISO-8601 lower bound; dispatches whose first timestamp is
        older are excluded. Bounds the extraction to one run window.
    .OUTPUTS
        Array of per-dispatch records sorted by first timestamp.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$TranscriptDir,

        [Parameter(Mandatory = $false)]
        [string]$Since
    )

    if (-not (Test-Path -LiteralPath $TranscriptDir -PathType Container)) {
        throw "Transcript directory not found: $TranscriptDir"
    }

    $files = @(Get-ChildItem -LiteralPath $TranscriptDir -Filter 'agent-*.jsonl' -File)
    $records = @($files | ForEach-Object { Read-DispatchTranscript -Path $_.FullName })

    if ($Since) {
        $bound = [datetimeoffset]::Parse($Since, [cultureinfo]::InvariantCulture)
        $records = @($records | Where-Object {
                $_.first_timestamp -and ([datetimeoffset]::Parse($_.first_timestamp, [cultureinfo]::InvariantCulture) -ge $bound)
            })
    }

    return @($records | Sort-Object first_timestamp)
}

function Format-DispatchAttributionTable {
    <#
    .SYNOPSIS
        Render attribution records as a Markdown table with a totals row.
    .PARAMETER Records
        Records produced by Get-DispatchAttribution or Read-DispatchTranscript.
    .OUTPUTS
        String - GitHub-flavored Markdown.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$Records
    )

    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine('| dispatch | model(s) | selector | api calls | input | cache_write | cache_read | output | total |')
    [void]$sb.AppendLine('| --- | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |')

    $tInput = 0L; $tCacheW = 0L; $tCacheR = 0L; $tOutput = 0L; $tTotal = 0L; $tCalls = 0
    foreach ($r in $Records) {
        $sel = $r.selector ?? '(none)'
        [void]$sb.AppendLine("| $($r.agent_id) | $($r.models) | $sel | $($r.api_calls) | $($r.input_tokens) | $($r.cache_creation_input_tokens) | $($r.cache_read_input_tokens) | $($r.output_tokens) | $($r.total_tokens) |")
        $tInput += $r.input_tokens; $tCacheW += $r.cache_creation_input_tokens
        $tCacheR += $r.cache_read_input_tokens; $tOutput += $r.output_tokens
        $tTotal += $r.total_tokens; $tCalls += $r.api_calls
    }
    [void]$sb.AppendLine("| **total (n=$($Records.Count))** |  |  | $tCalls | $tInput | $tCacheW | $tCacheR | $tOutput | $tTotal |")
    return $sb.ToString()
}

function Compare-DispatchPrompts {
    <#
    .SYNOPSIS
        Byte-level common-prefix comparison across dispatch prompts (AC1 evidence).
    .DESCRIPTION
        Compares the UTF-8 byte sequences of each record's dispatched prompt
        against the first record's prompt and reports the first divergent byte
        offset per pair. A pair with no divergence reports the shorter length
        and identical=true.
    .PARAMETER Records
        Two or more records produced by Read-DispatchTranscript.
    .OUTPUTS
        Array of pairwise comparison objects.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Records
    )

    if ($Records.Count -lt 2) {
        throw 'Compare-DispatchPrompts requires at least two records.'
    }

    $base = $Records[0]
    $baseBytes = [System.Text.Encoding]::UTF8.GetBytes([string]($base.prompt_text ?? ''))
    $results = [System.Collections.Generic.List[object]]::new()

    for ($i = 1; $i -lt $Records.Count; $i++) {
        $other = $Records[$i]
        $otherBytes = [System.Text.Encoding]::UTF8.GetBytes([string]($other.prompt_text ?? ''))
        $limit = [Math]::Min($baseBytes.Length, $otherBytes.Length)
        $offset = -1
        for ($b = 0; $b -lt $limit; $b++) {
            if ($baseBytes[$b] -ne $otherBytes[$b]) { $offset = $b; break }
        }
        $identical = ($offset -lt 0 -and $baseBytes.Length -eq $otherBytes.Length)
        $sharedPrefix = if ($offset -ge 0) { $offset } else { $limit }
        $results.Add([pscustomobject]@{
                base_agent_id        = $base.agent_id
                other_agent_id       = $other.agent_id
                identical            = $identical
                shared_prefix_bytes  = $sharedPrefix
                first_divergent_byte = if ($identical) { $null } else { $sharedPrefix }
                base_length_bytes    = $baseBytes.Length
                other_length_bytes   = $otherBytes.Length
            })
    }

    return @($results)
}
