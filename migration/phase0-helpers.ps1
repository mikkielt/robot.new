<#
    .SYNOPSIS
    Migration converter functions extracted from admin-state.ps1 and discord-state.ps1.

    .DESCRIPTION
    One-shot migration converters for converting legacy Markdown state files to JSON.
    These functions and their regex patterns are only used by phase0-setup.ps1 during
    repository migration, so they live here rather than in the core state files that
    are loaded at every module import.

    Converters:
    - Convert-PUHistoryToJson:       converts legacy pu-sessions.md to pu-sessions.json
    - Convert-DiscordDeliveryToJson: converts legacy discord-delivery.md to discord-delivery.json

    Dependencies: admin-state.ps1 (Save-JsonStateFile, $script:MultiSpacePattern),
                  discord-state.ps1 (loaded for completeness but no direct dependency)
#>

# Dot-source state files for Save-JsonStateFile and $script:MultiSpacePattern
. ([System.IO.Path]::Combine($PSScriptRoot, '..', 'private', 'admin-state.ps1'))
. ([System.IO.Path]::Combine($PSScriptRoot, '..', 'private', 'discord-state.ps1'))

# ── Migration-only regex patterns ─────────────────────────────────────────────

$script:HistoryEntryPattern = [regex]::new('^\s+-\s+###\s+(.+)$', [System.Text.RegularExpressions.RegexOptions]::Compiled)
$script:AdminHistoryTimestampPattern = [regex]::new(
    '^\s*-\s+(\d{4}-\d{2}-\d{2}\s+\d{2}:\d{2})\s+\(([^)]+)\)\s*:\s*$',
    [System.Text.RegularExpressions.RegexOptions]::Compiled
)

$script:DiscordDeliveryPattern = [regex]::new(
    '^\s*-\s+(\d{4}-\d{2}-\d{2}\s+\d{2}:\d{2}:\d{2})\s+\(([^)]+)\)\s+\[(OK|FAIL)\]\s+(\w+(?:-\w+)*)\s+->\s+(.+?)(?:\s+\(HTTP\s+(\d+)\))?\s*$',
    [System.Text.RegularExpressions.RegexOptions]::Compiled
)
$script:DiscordDeliveryContextPattern = [regex]::new(
    '^\s+-\s+(?!ERROR:\s)(.+)$',
    [System.Text.RegularExpressions.RegexOptions]::Compiled
)
$script:DiscordDeliveryErrorPattern = [regex]::new(
    '^\s+-\s+ERROR:\s+(.+)$',
    [System.Text.RegularExpressions.RegexOptions]::Compiled
)

# ── Convert-PUHistoryToJson ───────────────────────────────────────────────────

function Convert-PUHistoryToJson {
    param(
        [Parameter(Mandatory)] [string]$SourcePath,
        [Parameter(Mandatory)] [string]$TargetPath,
        [switch]$Force
    )

    if ([System.IO.File]::Exists($TargetPath) -and -not $Force) {
        Write-RobotWarning "[WARN Convert-PUHistoryToJson] Target file already exists: '$TargetPath'. Use -Force to overwrite."
        return $false
    }

    if (-not [System.IO.File]::Exists($SourcePath)) {
        Write-RobotWarning "[WARN Convert-PUHistoryToJson] Source file not found: '$SourcePath'"
        return $false
    }

    $UTF8NoBOM = [System.Text.UTF8Encoding]::new($false)
    $Content = [System.IO.File]::ReadAllText($SourcePath, $UTF8NoBOM)
    $Lines = $Content.Split([string[]]@("`r`n", "`n"), [System.StringSplitOptions]::None)

    $Runs = [System.Collections.Generic.List[object]]::new()
    $CurrentTimestamp = $null
    $CurrentTimezone = $null
    $CurrentHeaders = $null

    foreach ($Line in $Lines) {
        $TsMatch = $script:AdminHistoryTimestampPattern.Match($Line)
        if ($TsMatch.Success) {
            if ($null -ne $CurrentTimestamp -and $null -ne $CurrentHeaders -and $CurrentHeaders.Count -gt 0) {
                [void]$Runs.Add([ordered]@{
                    processedAt = $CurrentTimestamp
                    timezone    = $CurrentTimezone
                    sessions    = @($CurrentHeaders)
                })
            }
            $DateStr = $TsMatch.Groups[1].Value
            $Parsed = [datetime]::ParseExact($DateStr, 'yyyy-MM-dd HH:mm',
                [System.Globalization.CultureInfo]::InvariantCulture)
            $CurrentTimestamp = $Parsed.ToString('yyyy-MM-ddTHH:mm:ss')
            $CurrentTimezone = $TsMatch.Groups[2].Value
            $CurrentHeaders = [System.Collections.Generic.List[string]]::new()
            continue
        }

        $HdrMatch = $script:HistoryEntryPattern.Match($Line)
        if ($HdrMatch.Success -and $null -ne $CurrentHeaders) {
            $Header = $HdrMatch.Groups[1].Value.Trim()
            $Header = $script:MultiSpacePattern.Replace($Header, ' ')
            if ($Header.Length -gt 0) {
                [void]$CurrentHeaders.Add($Header)
            }
        }
    }

    # Flush last run
    if ($null -ne $CurrentTimestamp -and $null -ne $CurrentHeaders -and $CurrentHeaders.Count -gt 0) {
        [void]$Runs.Add([ordered]@{
            processedAt = $CurrentTimestamp
            timezone    = $CurrentTimezone
            sessions    = @($CurrentHeaders)
        })
    }

    $State = [ordered]@{
        version = 2
        runs    = @($Runs)
    }

    Save-JsonStateFile -Path $TargetPath -Data $State
    return $true
}

# ── Convert-DiscordDeliveryToJson ─────────────────────────────────────────────

function Convert-DiscordDeliveryToJson {
    param(
        [Parameter(Mandatory)] [string]$SourcePath,
        [Parameter(Mandatory)] [string]$TargetPath,
        [switch]$Force
    )

    if ([System.IO.File]::Exists($TargetPath) -and -not $Force) {
        Write-RobotWarning "[WARN Convert-DiscordDeliveryToJson] Target file already exists: '$TargetPath'. Use -Force to overwrite."
        return $false
    }

    if (-not [System.IO.File]::Exists($SourcePath)) {
        # No delivery history yet — not an error
        return $true
    }

    # Parse existing Markdown using legacy regex patterns
    $UTF8NoBOM = [System.Text.UTF8Encoding]::new($false)
    $Content = [System.IO.File]::ReadAllText($SourcePath, $UTF8NoBOM)
    $Lines = $Content.Split([string[]]@("`r`n", "`n"), [System.StringSplitOptions]::None)

    $MdEntries = [System.Collections.Generic.List[object]]::new()
    $Current = $null

    foreach ($Line in $Lines) {
        $Match = $script:DiscordDeliveryPattern.Match($Line)
        if ($Match.Success) {
            if ($null -ne $Current) { [void]$MdEntries.Add($Current) }

            $TsStr = $Match.Groups[1].Value
            $Current = [PSCustomObject]@{
                Timestamp    = [datetime]::ParseExact($TsStr, 'yyyy-MM-dd HH:mm:ss',
                    [System.Globalization.CultureInfo]::InvariantCulture)
                Timezone     = $Match.Groups[2].Value
                Status       = $Match.Groups[3].Value
                Operation    = $Match.Groups[4].Value
                Recipient    = $Match.Groups[5].Value
                StatusCode   = if ($Match.Groups[6].Success) { [int]$Match.Groups[6].Value } else { $null }
                Context      = $null
                ErrorMessage = $null
            }
            continue
        }

        if ($null -eq $Current) { continue }

        $ErrMatch = $script:DiscordDeliveryErrorPattern.Match($Line)
        if ($ErrMatch.Success) {
            $Current.ErrorMessage = $ErrMatch.Groups[1].Value
            continue
        }

        $CtxMatch = $script:DiscordDeliveryContextPattern.Match($Line)
        if ($CtxMatch.Success) {
            $Current.Context = $CtxMatch.Groups[1].Value
        }
    }

    if ($null -ne $Current) { [void]$MdEntries.Add($Current) }

    $Entries = [System.Collections.Generic.List[object]]::new()
    foreach ($E in $MdEntries) {
        [void]$Entries.Add([ordered]@{
            timestamp    = $E.Timestamp.ToString('yyyy-MM-ddTHH:mm:ss')
            timezone     = $E.Timezone
            status       = $E.Status
            operation    = $E.Operation
            recipient    = $E.Recipient
            statusCode   = $E.StatusCode
            context      = $E.Context
            errorMessage = $E.ErrorMessage
        })
    }

    $State = [ordered]@{
        version = 1
        entries = @($Entries)
    }

    Save-JsonStateFile -Path $TargetPath -Data $State
    return $true
}
