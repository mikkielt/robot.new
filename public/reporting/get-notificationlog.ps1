<#
    .SYNOPSIS
    Extracts all @Intel directives from sessions into a notification audit log.

    .DESCRIPTION
    Scans sessions for Intel entries and returns a flat, chronologically sorted
    list of notification intents with session context. Supports filtering by
    target name, directive type, and date range.

    Reconstructs notification intent from session data. Note: this shows what
    was intended to be sent, not actual delivery status (delivery logging is
    not yet implemented).
#>

function Get-NotificationLog {
    <#
        .SYNOPSIS
        View Intel notification history from sessions.
    #>

    [CmdletBinding()] param(
        [Parameter(HelpMessage = "Filter by recipient or target name")]
        [string]$Target,

        [Parameter(HelpMessage = "Filter by directive type: 'Direct', 'Grupa', 'Lokacja'")]
        [ValidateSet('Direct', 'Grupa', 'Lokacja')]
        [string]$Directive,

        [Parameter(HelpMessage = "Include only notifications on or after this date")]
        [datetime]$MinDate,

        [Parameter(HelpMessage = "Include only notifications on or before this date")]
        [datetime]$MaxDate,

        [Parameter(HelpMessage = "Pre-fetched session list from Get-Session")]
        [object[]]$Sessions,

        [Parameter(HelpMessage = "Pre-fetched entity list from Get-EntityState")]
        [object[]]$Entities
    )

    if (-not $Sessions) {
        $FetchArgs = @{}
        if ($MinDate) { $FetchArgs['MinDate'] = $MinDate }
        if ($MaxDate) { $FetchArgs['MaxDate'] = $MaxDate }
        if ($Entities) { $FetchArgs['Entities'] = $Entities }
        $Sessions = Get-Session @FetchArgs
    }

    $Report = [System.Collections.Generic.List[object]]::new()

    foreach ($Session in $Sessions) {
        if (-not $Session.Intel -or $Session.Intel.Count -eq 0) { continue }
        if ($null -eq $Session.Date) { continue }

        # Date range filtering
        if ($MinDate -and $Session.Date -lt $MinDate) { continue }
        if ($MaxDate -and $Session.Date -gt $MaxDate) { continue }

        $NarratorName = if ($Session.Narrator) { $Session.Narrator.Name } else { $null }

        foreach ($Intel in $Session.Intel) {
            # Directive filter
            if ($Directive -and -not [string]::Equals($Intel.Directive, $Directive, [System.StringComparison]::OrdinalIgnoreCase)) {
                continue
            }

            # Resolve recipient names
            $RecipientNames = @()
            if ($Intel.Recipients) {
                $RecipientNames = @($Intel.Recipients | ForEach-Object { $_.Name })
            }

            # Target filter: match against TargetName or any recipient
            if ($Target) {
                $TargetMatch = [string]::Equals($Intel.TargetName, $Target, [System.StringComparison]::OrdinalIgnoreCase)
                if (-not $TargetMatch) {
                    $TargetMatch = $false
                    foreach ($RName in $RecipientNames) {
                        if ([string]::Equals($RName, $Target, [System.StringComparison]::OrdinalIgnoreCase)) {
                            $TargetMatch = $true
                            break
                        }
                    }
                }
                if (-not $TargetMatch) { continue }
            }

            $Report.Add([PSCustomObject]@{
                Date           = $Session.Date
                SessionTitle   = $Session.Title
                Narrator       = $NarratorName
                Directive      = $Intel.Directive
                TargetName     = $Intel.TargetName
                Message        = $Intel.Message
                RecipientCount = $RecipientNames.Count
                Recipients     = $RecipientNames
            })
        }
    }

    # Sort chronologically
    $Report.Sort([System.Comparison[object]]{
        param($a, $b)
        return $a.Date.CompareTo($b.Date)
    })

    return @($Report)
}
