<#
    .SYNOPSIS
    Filters entities by property value for reverse-lookup queries.

    .DESCRIPTION
    This file contains Resolve-Entity which provides property-based filtering
    over entity collections. Answers questions like "what entities are at
    location Y?", "what does character X own?", "who is in group Z?"

    Processing pipeline:
    1. Fetches entities via Get-EntityState (or uses pre-fetched -Entities)
    2. Single-pass scan with continue-gate filtering (same pattern as
       get-currencyentity.ps1)
    3. Each parameter is an optional AND filter. No filter = return all
       active entities.
    4. Returns original Robot.Entity objects (passthrough, no enrichment)

    Status defaults: excludes Usunięty by default (use -IncludeDeleted).
    Excludes Nieaktywny by default (use -IncludeInactive).

    Resolve verb is consistent with the project's approved verb list and
    has precedent (Resolve-Name, Resolve-Narrator). Semantics: resolving
    a set of filter criteria to matching entity objects.
#>

function Resolve-Entity {
    <#
        .SYNOPSIS
        Filters entities by property value for reverse-lookup queries.
    #>

    [CmdletBinding()] param(
        [Parameter(HelpMessage = "Filter by @należy_do owner name")]
        [string]$Owner,

        [Parameter(HelpMessage = "Filter by @lokacja location name")]
        [string]$Location,

        [Parameter(HelpMessage = "Filter by @grupa active membership")]
        [string]$Group,

        [Parameter(HelpMessage = "Filter by entity type")]
        [string]$Type,

        [Parameter(HelpMessage = "Filter by @status value")]
        [string]$Status,

        [Parameter(HelpMessage = "Filter by name (substring, case-insensitive)")]
        [string]$Name,

        [Parameter(HelpMessage = "Filter temporally-scoped data to entries active on this date")]
        [datetime]$ActiveOn,

        [Parameter(HelpMessage = "Include Nieaktywny entities")]
        [switch]$IncludeInactive,

        [Parameter(HelpMessage = "Include Usunięty entities")]
        [switch]$IncludeDeleted,

        [Parameter(HelpMessage = "Pre-fetched entity list from Get-Entity or Get-EntityState")]
        [object[]]$Entities,

        [Parameter(HelpMessage = "Suppress warning output to stderr")]
        [switch]$Quiet
    )

    $PrevSuppress = $script:SuppressWarnings
    if ($Quiet) { $script:SuppressWarnings = $true }
    try {

    if (-not $PSBoundParameters.ContainsKey('Entities')) {
        $Entities = if ($ActiveOn) { Get-EntityState -ActiveOn $ActiveOn } else { Get-EntityState }
    }

    $Results = [System.Collections.Generic.List[object]]::new()

    foreach ($Entity in $Entities) {
        # Status gate (default: exclude Usunięty and Nieaktywny)
        $EntityStatus = if ($Entity.Status) { $Entity.Status } else { 'Aktywny' }
        if ([string]::Equals($EntityStatus, 'Usunięty', [System.StringComparison]::OrdinalIgnoreCase) -and -not $IncludeDeleted) { continue }
        if ([string]::Equals($EntityStatus, 'Nieaktywny', [System.StringComparison]::OrdinalIgnoreCase) -and -not $IncludeInactive) { continue }

        # Explicit Status filter (matches exact value)
        if ($Status) {
            if (-not [string]::Equals($EntityStatus, $Status, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
        }

        # Type filter
        if ($Type) {
            if (-not $Entity.Type -or -not [string]::Equals($Entity.Type, $Type, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
        }

        # Owner filter
        if ($Owner) {
            if (-not $Entity.Owner -or -not [string]::Equals($Entity.Owner, $Owner, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
        }

        # Location filter
        if ($Location) {
            if (-not $Entity.Location -or -not [string]::Equals($Entity.Location, $Location, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
        }

        # Group filter — checks active Groups list for membership
        if ($Group) {
            $HasGroup = $false
            if ($Entity.Groups -and $Entity.Groups.Count -gt 0) {
                foreach ($G in $Entity.Groups) {
                    if ([string]::Equals($G, $Group, [System.StringComparison]::OrdinalIgnoreCase)) {
                        $HasGroup = $true
                        break
                    }
                }
            }
            if (-not $HasGroup) { continue }
        }

        # Name filter (substring, case-insensitive)
        if ($Name) {
            if (-not $Entity.Name -or $Entity.Name.IndexOf($Name, [System.StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }
        }

        $Results.Add($Entity)
    }

    return @($Results)

    } finally { $script:SuppressWarnings = $PrevSuppress }
}
