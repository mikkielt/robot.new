<#
    .SYNOPSIS
    Computes property differences for an entity between two points in time.

    .DESCRIPTION
    This file contains Get-EntityDelta which resolves entity state at two
    dates via Get-EntityState -ActiveOn and compares scalar and multi-valued
    properties. Returns only changed properties with before/after values.

    Performance note: Get-EntityState is expensive (full session merge).
    Calling it twice with different -ActiveOn values doubles the cost.
    Callers with pre-computed entity states should pass them via
    -FromEntities / -ToEntities to avoid redundant work.

    Compared properties:
    - Scalar: Location, Owner, Type, Status, Quantity, NerthusName
    - Multi-valued: Groups (set diff), Doors (set diff)

    Entity name resolution tries exact primary name match first, then
    falls back to scanning the Names collection (aliases, generic names).
#>

function Get-EntityDelta {
    <#
        .SYNOPSIS
        Computes property differences for an entity between two points in time.
    #>

    [CmdletBinding()] param(
        [Parameter(Mandatory, Position = 0, HelpMessage = "Entity name to diff")]
        [string]$Name,

        [Parameter(Mandatory, HelpMessage = "Start of diff range")]
        [datetime]$FromDate,

        [Parameter(Mandatory, HelpMessage = "End of diff range")]
        [datetime]$ToDate,

        [Parameter(HelpMessage = "Pre-fetched entity list at FromDate (from Get-EntityState -ActiveOn)")]
        [object[]]$FromEntities,

        [Parameter(HelpMessage = "Pre-fetched entity list at ToDate (from Get-EntityState -ActiveOn)")]
        [object[]]$ToEntities,

        [Parameter(HelpMessage = "Pre-fetched session list from Get-Session (passed to Get-EntityState)")]
        [object[]]$Sessions,

        [Parameter(HelpMessage = "Suppress warning output to stderr")]
        [switch]$Quiet
    )

    $PrevSuppress = $script:SuppressWarnings
    if ($Quiet) { $script:SuppressWarnings = $true }
    try {

    # Resolve entity state at both dates
    if (-not $PSBoundParameters.ContainsKey('FromEntities')) {
        $SessionParam = @{}
        if ($PSBoundParameters.ContainsKey('Sessions')) { $SessionParam['Sessions'] = $Sessions }
        $FromEntities = Get-EntityState -ActiveOn $FromDate -Quiet:$Quiet @SessionParam
    }
    if (-not $PSBoundParameters.ContainsKey('ToEntities')) {
        $SessionParam = @{}
        if ($PSBoundParameters.ContainsKey('Sessions')) { $SessionParam['Sessions'] = $Sessions }
        $ToEntities = Get-EntityState -ActiveOn $ToDate -Quiet:$Quiet @SessionParam
    }

    # Resolve entity by name in both snapshots
    $FromEntity = Find-EntityByName -Entities $FromEntities -Name $Name
    $ToEntity = Find-EntityByName -Entities $ToEntities -Name $Name

    if (-not $FromEntity -and -not $ToEntity) {
        Write-RobotWarning "[WARN Get-EntityDelta] Entity '$Name' not found in either snapshot"
        return @()
    }

    $Results = [System.Collections.Generic.List[object]]::new()

    # Scalar properties to compare
    $ScalarProps = @(
        @{ Property = 'Location'; Display = 'Lokacja' }
        @{ Property = 'Owner';    Display = 'Właściciel' }
        @{ Property = 'Type';     Display = 'Typ' }
        @{ Property = 'Status';   Display = 'Status' }
        @{ Property = 'Quantity'; Display = 'Ilość' }
        @{ Property = 'NerthusName'; Display = 'NazwaNerthus' }
    )

    foreach ($Prop in $ScalarProps) {
        $BeforeVal = if ($FromEntity) { $FromEntity.($Prop.Property) } else { $null }
        $AfterVal = if ($ToEntity) { $ToEntity.($Prop.Property) } else { $null }

        # Normalize nulls to empty string for comparison
        $BeforeStr = if ($null -ne $BeforeVal) { [string]$BeforeVal } else { '' }
        $AfterStr = if ($null -ne $AfterVal) { [string]$AfterVal } else { '' }

        if (-not [string]::Equals($BeforeStr, $AfterStr, [System.StringComparison]::OrdinalIgnoreCase)) {
            $Results.Add([PSCustomObject]@{
                Property = $Prop.Display
                Before   = $BeforeVal
                After    = $AfterVal
            })
        }
    }

    # Multi-valued properties: Groups
    $FromGroups = if ($FromEntity -and $FromEntity.Groups) { @($FromEntity.Groups) } else { @() }
    $ToGroups = if ($ToEntity -and $ToEntity.Groups) { @($ToEntity.Groups) } else { @() }

    $GroupsDiffer = $false
    if ($FromGroups.Count -ne $ToGroups.Count) {
        $GroupsDiffer = $true
    } else {
        $FromSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($G in $FromGroups) { [void]$FromSet.Add($G) }
        foreach ($G in $ToGroups) {
            if (-not $FromSet.Contains($G)) { $GroupsDiffer = $true; break }
        }
    }

    if ($GroupsDiffer) {
        $Results.Add([PSCustomObject]@{
            Property = 'Grupy'
            Before   = $FromGroups
            After    = $ToGroups
        })
    }

    # Multi-valued properties: Doors
    $FromDoors = if ($FromEntity -and $FromEntity.Doors) { @($FromEntity.Doors) } else { @() }
    $ToDoors = if ($ToEntity -and $ToEntity.Doors) { @($ToEntity.Doors) } else { @() }

    $DoorsDiffer = $false
    if ($FromDoors.Count -ne $ToDoors.Count) {
        $DoorsDiffer = $true
    } else {
        $FromDoorSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($D in $FromDoors) { [void]$FromDoorSet.Add($D) }
        foreach ($D in $ToDoors) {
            if (-not $FromDoorSet.Contains($D)) { $DoorsDiffer = $true; break }
        }
    }

    if ($DoorsDiffer) {
        $Results.Add([PSCustomObject]@{
            Property = 'Drzwi'
            Before   = $FromDoors
            After    = $ToDoors
        })
    }

    return @($Results)

    } finally { $script:SuppressWarnings = $PrevSuppress }
}

# Helper: find entity by primary name or alias in entity collection
function Find-EntityByName {
    param(
        [object[]]$Entities,
        [string]$Name
    )

    if (-not $Entities) { return $null }

    # Try primary name first
    foreach ($E in $Entities) {
        if ([string]::Equals($E.Name, $Name, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $E
        }
    }

    # Fall back to alias scanning
    foreach ($E in $Entities) {
        if ($E.Names) {
            foreach ($N in $E.Names) {
                if ([string]::Equals($N, $Name, [System.StringComparison]::OrdinalIgnoreCase)) {
                    return $E
                }
            }
        }
    }

    return $null
}
