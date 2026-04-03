<#
    .SYNOPSIS
    Shared helpers for entity scalar resolution, history merge, and construction.

    .DESCRIPTION
    Extracted from get-entity.ps1 to eliminate ~260 LOC duplication between the
    C# fast path and PowerShell fallback path. Both paths now call these helpers
    for post-dispatch processing (scalar resolution, merge, construction).

    Three functions:
    - Resolve-EntityScalars:  resolves current scalar values from temporal histories
    - Merge-EntityHistories:  merges incoming histories into an existing entity
    - New-EntityFromParsed:   constructs a [Robot.Entity] from parsed data

    Dependencies: temporal-helpers.ps1 (Get-LastActiveValue, Get-AllActiveValues,
    Test-TemporalActivity) — must be dot-sourced before this file.
#>

function Resolve-EntityScalars {
    param(
        [System.Collections.Generic.List[object]]$LocationHistory,
        [System.Collections.Generic.List[object]]$DoorHistory,
        [System.Collections.Generic.List[object]]$TypeHistory,
        [System.Collections.Generic.List[object]]$OwnerHistory,
        [System.Collections.Generic.List[object]]$GroupHistory,
        [System.Collections.Generic.List[object]]$StatusHistory,
        [System.Collections.Generic.List[object]]$QuantityHistory,
        [System.Collections.Generic.List[object]]$FilePathHistory,
        [System.Collections.Generic.List[object]]$NerthusNameHistory,
        [System.Collections.Generic.List[object]]$CoordinateHistory,
        [string]$DefaultType,
        [AllowNull()][Nullable[datetime]]$ActiveOn
    )

    $ActiveType = Get-LastActiveValue -History $TypeHistory -PropertyName 'Value' -ActiveOn $ActiveOn
    if (-not $ActiveType) { $ActiveType = $DefaultType }
    $ActiveStatus = Get-LastActiveValue -History $StatusHistory -PropertyName 'Value' -ActiveOn $ActiveOn
    if (-not $ActiveStatus) { $ActiveStatus = 'Aktywny' }

    $ActiveCoordinates = $null
    if ($CoordinateHistory.Count -gt 0) {
        $ActiveCoordEntries = $CoordinateHistory.Where({ Test-TemporalActivity -Item $_ -ActiveOn $ActiveOn })
        if ($ActiveCoordEntries.Count -gt 0) {
            $LastCoord = $ActiveCoordEntries[-1]
            $ActiveCoordinates = @{ X = $LastCoord.X; Y = $LastCoord.Y }
        }
    }

    return @{
        Location    = Get-LastActiveValue -History $LocationHistory -PropertyName 'Value' -ActiveOn $ActiveOn
        Doors       = Get-AllActiveValues -History $DoorHistory -PropertyName 'Value' -ActiveOn $ActiveOn
        Type        = $ActiveType
        Owner       = Get-LastActiveValue -History $OwnerHistory -PropertyName 'Value' -ActiveOn $ActiveOn
        Groups      = Get-AllActiveValues -History $GroupHistory -PropertyName 'Value' -ActiveOn $ActiveOn
        Status      = $ActiveStatus
        Quantity    = Get-LastActiveValue -History $QuantityHistory -PropertyName 'Value' -ActiveOn $ActiveOn
        FilePath    = Get-LastActiveValue -History $FilePathHistory -PropertyName 'Value' -ActiveOn $ActiveOn
        NerthusName = Get-LastActiveValue -History $NerthusNameHistory -PropertyName 'Value' -ActiveOn $ActiveOn
        Coordinates = $ActiveCoordinates
    }
}

function Merge-EntityHistories {
    param(
        [Robot.Entity]$Existing,
        [object]$Names,
        [System.Collections.Generic.List[object]]$Aliases,
        [hashtable]$Overrides,
        [System.Collections.Generic.List[object]]$TypeHistory,
        [System.Collections.Generic.List[object]]$OwnerHistory,
        [System.Collections.Generic.List[object]]$GroupHistory,
        [System.Collections.Generic.List[object]]$LocationHistory,
        [System.Collections.Generic.List[object]]$DoorHistory,
        [System.Collections.Generic.List[object]]$StatusHistory,
        [System.Collections.Generic.List[object]]$QuantityHistory,
        [System.Collections.Generic.List[string]]$GenericNames,
        [System.Collections.Generic.List[string]]$ContainsList,
        [System.Collections.Generic.List[object]]$FilePathHistory,
        [System.Collections.Generic.List[object]]$NerthusNameHistory,
        [System.Collections.Generic.List[object]]$CoordinateHistory,
        [string]$SectionType,
        [AllowNull()][Nullable[datetime]]$ActiveOn
    )

    foreach ($NameEntry in $Names) { [void]$Existing.Names.Add($NameEntry) }
    $Existing.Aliases.AddRange($Aliases)

    foreach ($Key in $Overrides.Keys) {
        if (-not $Existing.Overrides.ContainsKey($Key)) {
            $Existing.Overrides[$Key] = [System.Collections.Generic.List[string]]::new()
        }
        $Existing.Overrides[$Key].AddRange($Overrides[$Key])
    }

    $Existing.TypeHistory.AddRange($TypeHistory)
    $Existing.OwnerHistory.AddRange($OwnerHistory)
    $Existing.GroupHistory.AddRange($GroupHistory)
    $Existing.LocationHistory.AddRange($LocationHistory)
    $Existing.DoorHistory.AddRange($DoorHistory)
    $Existing.StatusHistory.AddRange($StatusHistory)
    $Existing.QuantityHistory.AddRange($QuantityHistory)
    $Existing.GenericNames.AddRange($GenericNames)
    foreach ($GN in $GenericNames) { [void]$Existing.Names.Add($GN) }
    $Existing.Contains.AddRange($ContainsList)
    $Existing.FilePathHistory.AddRange($FilePathHistory)
    $Existing.NerthusNameHistory.AddRange($NerthusNameHistory)
    $Existing.CoordinateHistory.AddRange($CoordinateHistory)

    # Recompute scalars from merged histories
    if ($SectionType -ne "Entity") { $Existing.Type = $SectionType }
    $MergedType = Get-LastActiveValue -History $Existing.TypeHistory -PropertyName 'Value' -ActiveOn $ActiveOn
    if ($MergedType) { $Existing.Type = $MergedType }

    $MergedOwner = Get-LastActiveValue -History $Existing.OwnerHistory -PropertyName 'Value' -ActiveOn $ActiveOn
    if ($MergedOwner) { $Existing.Owner = $MergedOwner }

    $Existing.Groups = Get-AllActiveValues -History $Existing.GroupHistory -PropertyName 'Value' -ActiveOn $ActiveOn

    $MergedLoc = Get-LastActiveValue -History $Existing.LocationHistory -PropertyName 'Value' -ActiveOn $ActiveOn
    if ($MergedLoc) { $Existing.Location = $MergedLoc }

    $Existing.Doors = Get-AllActiveValues -History $Existing.DoorHistory -PropertyName 'Value' -ActiveOn $ActiveOn

    $MergedStatus = Get-LastActiveValue -History $Existing.StatusHistory -PropertyName 'Value' -ActiveOn $ActiveOn
    if ($MergedStatus) { $Existing.Status = $MergedStatus }

    $MergedQuantity = Get-LastActiveValue -History $Existing.QuantityHistory -PropertyName 'Value' -ActiveOn $ActiveOn
    if ($MergedQuantity) { $Existing.Quantity = $MergedQuantity }

    $MergedFilePath = Get-LastActiveValue -History $Existing.FilePathHistory -PropertyName 'Value' -ActiveOn $ActiveOn
    if ($MergedFilePath) { $Existing.FilePath = $MergedFilePath }

    $MergedNerthusName = Get-LastActiveValue -History $Existing.NerthusNameHistory -PropertyName 'Value' -ActiveOn $ActiveOn
    if ($MergedNerthusName) { $Existing.NerthusName = $MergedNerthusName }

    if ($Existing.CoordinateHistory.Count -gt 0) {
        $MergedCoordEntries = $Existing.CoordinateHistory.Where({ Test-TemporalActivity -Item $_ -ActiveOn $ActiveOn })
        if ($MergedCoordEntries.Count -gt 0) {
            $LastCoord = $MergedCoordEntries[-1]
            $Existing.Coordinates = @{ X = $LastCoord.X; Y = $LastCoord.Y }
        }
    }

    # Regenerate path-qualified names after door list merge
    if (($Existing.Type -eq 'Lokacja' -or $Existing.Type -eq 'Mapa') -and $Existing.Doors.Count -gt 0) {
        foreach ($DoorName in $Existing.Doors) {
            [void]$Existing.Names.Add("$DoorName/$($Existing.Name)")
        }
    }
}

function New-EntityFromParsed {
    param(
        [string]$EntityName,
        [object]$Names,
        [System.Collections.Generic.List[object]]$Aliases,
        [hashtable]$Overrides,
        [hashtable]$Scalars,
        [System.Collections.Generic.List[object]]$TypeHistory,
        [System.Collections.Generic.List[object]]$OwnerHistory,
        [System.Collections.Generic.List[object]]$GroupHistory,
        [System.Collections.Generic.List[object]]$LocationHistory,
        [System.Collections.Generic.List[object]]$DoorHistory,
        [System.Collections.Generic.List[object]]$StatusHistory,
        [System.Collections.Generic.List[object]]$QuantityHistory,
        [System.Collections.Generic.List[string]]$GenericNames,
        [System.Collections.Generic.List[string]]$ContainsList,
        [System.Collections.Generic.List[object]]$FilePathHistory,
        [System.Collections.Generic.List[object]]$NerthusNameHistory,
        [System.Collections.Generic.List[object]]$CoordinateHistory
    )

    $Entity = [Robot.Entity]::new()
    $Entity.Name               = $EntityName
    $Entity.CN                 = $null
    $Entity.Names              = $Names
    $Entity.Aliases            = $Aliases
    $Entity.Type               = $Scalars.Type
    $Entity.Owner              = $Scalars.Owner
    $Entity.Groups             = $Scalars.Groups
    $Entity.Overrides          = $Overrides
    $Entity.TypeHistory        = $TypeHistory
    $Entity.OwnerHistory       = $OwnerHistory
    $Entity.GroupHistory       = $GroupHistory
    $Entity.Location           = $Scalars.Location
    $Entity.LocationHistory    = $LocationHistory
    $Entity.Doors              = $Scalars.Doors
    $Entity.DoorHistory        = $DoorHistory
    $Entity.Status             = $Scalars.Status
    $Entity.StatusHistory      = $StatusHistory
    $Entity.Quantity           = $Scalars.Quantity
    $Entity.QuantityHistory    = $QuantityHistory
    $Entity.GenericNames       = $GenericNames
    $Entity.FilePath           = $Scalars.FilePath
    $Entity.FilePathHistory    = $FilePathHistory
    $Entity.NerthusName        = $Scalars.NerthusName
    $Entity.NerthusNameHistory = $NerthusNameHistory
    $Entity.Coordinates        = $Scalars.Coordinates
    $Entity.CoordinateHistory  = $CoordinateHistory
    $Entity.Contains           = $ContainsList
    return $Entity
}
