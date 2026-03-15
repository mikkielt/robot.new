<#
    .SYNOPSIS
    Extracts all @Intel directives from sessions into a notification audit log.

    .DESCRIPTION
    Scans sessions for @Intel entries and returns a flat, chronologically
    sorted list of notification intents with session context. Supports
    filtering by target name, directive type, and date range.

    Pipeline:
    1. Fetch sessions via Get-SessionsForReport (shared reporting helper
       that handles date filtering and optional pre-fetched session lists)
    2. Extract Intel directive entries via Get-SessionDirectiveEntries
    3. Apply directive type filter (Direct/Grupa/Lokacja)
    4. Apply target name filter against both TargetName and resolved
       Recipients (OrdinalIgnoreCase), so filtering by a player name
       finds Intel directed at their group or location
    5. Sort chronologically by session date

    This shows what was intended to be sent, not actual delivery status.
    Delivery confirmation is not tracked in the session data model.

    Each output object includes the session context (Date, Title, Narrator)
    alongside the Intel payload (Directive type, TargetName, Message,
    Recipients array).
#>

. "$script:ModuleRoot/private/reporting-helpers.ps1"

function Get-NotificationLog {
    <#
        .SYNOPSIS
        Returns a chronological audit log of @Intel notification intents from sessions.
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

    $ExtraFetch = @{}
    if ($Entities) { $ExtraFetch['Entities'] = $Entities }
    $Sessions = Get-SessionsForReport -Sessions $Sessions -MinDate $MinDate -MaxDate $MaxDate -ExtraFetchArgs $ExtraFetch

    $EntryArgs = @{ Sessions = $Sessions; DirectiveName = 'Intel' }
    if ($MinDate) { $EntryArgs['MinDate'] = $MinDate }
    if ($MaxDate) { $EntryArgs['MaxDate'] = $MaxDate }
    $Entries = Get-SessionDirectiveEntries @EntryArgs

    $Report = [System.Collections.Generic.List[object]]::new()

    foreach ($E in $Entries) {
        $Intel = $E.Directive

        # Skip entries that don't match the requested directive type
        if ($Directive -and -not [string]::Equals($Intel.Directive, $Directive, [System.StringComparison]::OrdinalIgnoreCase)) {
            continue
        }

        # Flatten recipient objects to name strings for target matching and output
        $RecipientNames = @()
        if ($Intel.Recipients) {
            $RecipientNames = @($Intel.Recipients | ForEach-Object { $_.Name })
        }

        # Match target against both the direct TargetName and resolved recipients
        # so filtering by a player name catches group/location-routed Intel too
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
            Date           = $E.Session.Date
            SessionTitle   = $E.Session.Title
            Narrator       = $E.Session.Narrator
            Directive      = $Intel.Directive
            TargetName     = $Intel.TargetName
            Message        = $Intel.Message
            RecipientCount = $RecipientNames.Count
            Recipients     = $RecipientNames
        })
    }

    # Chronological sort for audit trail readability
    $Report.Sort([System.Comparison[object]]{
        param($a, $b)
        return $a.Date.CompareTo($b.Date)
    })

    return @($Report)
}
