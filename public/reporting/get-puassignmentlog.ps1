<#
    .SYNOPSIS
    Parses the PU assignment state file into structured processing history.

    .DESCRIPTION
    Reads the JSON pu-sessions.json state file and returns structured
    objects showing when PU was processed and which sessions were included
    in each run.

    Module-level data:
    - $script:MultiSpacePattern: precompiled regex from admin-state.ps1 for
      normalizing multiple consecutive spaces in header text

    Pipeline:
    1. Read pu-sessions.json via Read-JsonStateFile (returns $null on missing
       or corrupt file — both treated as empty history).
    2. Iterate runs array; parse each run's processedAt ISO timestamp.
       Handles PowerShell's auto-conversion of ISO strings to DateTime on
       some PS versions by checking the runtime type before parsing.
    3. Decompose each session header into Date/Title/Narrator fields
       by splitting on comma separators (header format: "YYYY-MM-DD, Title, Narrator").
    4. Apply ProcessedAt date range filters (MinDate/MaxDate).
    5. Sort descending by ProcessedAt (most recent first) for display.

    Returns: array of PSCustomObject with ProcessedAt (DateTime),
    Timezone (string), SessionCount (int), Sessions (array of
    PSCustomObject with Header/Date/Title/Narrator).
#>

. "$script:ModuleRoot/private/admin-state.ps1"

function Get-PUAssignmentLog {
    <#
        .SYNOPSIS
        Returns structured PU assignment processing history from the state file.
    #>

    [CmdletBinding()] param(
        [Parameter(HelpMessage = "Path to the PU sessions state file")]
        [string]$Path,

        [Parameter(HelpMessage = "Include only runs on or after this date")]
        [datetime]$MinDate,

        [Parameter(HelpMessage = "Include only runs on or before this date")]
        [datetime]$MaxDate,

        [Parameter(HelpMessage = "Suppress warning output to stderr")]
        [switch]$Quiet
    )

    $PrevSuppress = $script:SuppressWarnings
    if ($Quiet) { $script:SuppressWarnings = $true }
    try {

    if (-not $Path) {
        $Config = Get-AdminConfig
        $Path = [System.IO.Path]::Combine($Config.ResDir, 'pu-sessions.json')
    }

    if (-not [System.IO.File]::Exists($Path)) {
        Write-RobotWarning "[WARN Get-PUAssignmentLog] State file not found: '$Path'"
        return @()
    }

    $State = Read-JsonStateFile -Path $Path
    if ($null -eq $State -or -not $State.runs) {
        return @()
    }

    $Entries = [System.Collections.Generic.List[object]]::new()
    foreach ($Run in @($State.runs)) {
        # ConvertFrom-Json auto-converts ISO timestamps to DateTime on some PS versions
        $TsRaw = $Run.processedAt
        $Timestamp = if ($TsRaw -is [datetime]) {
            $TsRaw
        } else {
            [datetime]::ParseExact($TsRaw, 'yyyy-MM-ddTHH:mm:ss',
                [System.Globalization.CultureInfo]::InvariantCulture)
        }

        $SessionHeaders = [System.Collections.Generic.List[object]]::new()
        foreach ($Header in @($Run.sessions)) {
            $Normalized = $Header.Trim()
            $Normalized = $script:MultiSpacePattern.Replace($Normalized, ' ')
            if ($Normalized.Length -eq 0) { continue }

            $Parts = $Normalized.Split(',')
            $SessionDate = $null
            $SessionTitle = $null
            $SessionNarrator = $null
            if ($Parts.Count -ge 1) {
                $DateStr = $Parts[0].Trim()
                try { $SessionDate = [datetime]::ParseExact($DateStr, 'yyyy-MM-dd',
                    [System.Globalization.CultureInfo]::InvariantCulture) } catch {}
            }
            if ($Parts.Count -ge 2) { $SessionTitle = $Parts[1].Trim() }
            if ($Parts.Count -ge 3) { $SessionNarrator = $Parts[2].Trim() }

            [void]$SessionHeaders.Add([PSCustomObject]@{
                Header   = $Normalized
                Date     = $SessionDate
                Title    = $SessionTitle
                Narrator = $SessionNarrator
            })
        }

        [void]$Entries.Add([PSCustomObject]@{
            ProcessedAt  = $Timestamp
            Timezone     = $Run.timezone
            SessionCount = $SessionHeaders.Count
            Sessions     = @($SessionHeaders)
        })
    }

    # Post-parse filtering on the processing timestamp (not session dates)
    if ($MinDate -or $MaxDate) {
        $Filtered = [System.Collections.Generic.List[object]]::new()
        foreach ($Entry in $Entries) {
            if ($MinDate -and $Entry.ProcessedAt -lt $MinDate) { continue }
            if ($MaxDate -and $Entry.ProcessedAt -gt $MaxDate) { continue }
            $Filtered.Add($Entry)
        }
        $Entries = $Filtered
    }

    # Most recent runs first for typical "what happened last?" queries
    $Entries.Sort([System.Comparison[object]]{
        param($a, $b)
        return $b.ProcessedAt.CompareTo($a.ProcessedAt)
    })

    return @($Entries)

    } finally { $script:SuppressWarnings = $PrevSuppress }
}
