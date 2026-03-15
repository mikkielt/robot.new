<#
    .SYNOPSIS
    Parses entity registry files (entities.md, *-NNN-ent.md) into structured objects with
    time-scoped metadata, multi-file merge, and hierarchical canonical names.

    .DESCRIPTION
    This file contains Get-Entity and its helpers. It dot-sources
    temporal-helpers.ps1 for shared temporal utility functions
    (ConvertFrom-ValidityString, Test-TemporalActivity, Get-LastActiveValue,
    Get-AllActiveValues, Get-NestedBulletText, ConvertFrom-CoordinateString).

    Helpers:
    - Resolve-EntityCN: builds hierarchical canonical names for locations via @lokacja
      chain traversal, with memoization via $CNCache and cycle detection via $Visited HashSet

    Get-Entity reads entity registry Markdown files and builds a unified collection of typed
    entity objects (NPCs, groups, locations, players, maps, items). Entities carry time-scoped
    aliases (@alias), location assignments and containment hierarchy (@lokacja), group
    memberships (@grupa), door connections (@drzwi), ownership (@należy_do), quantity
    (@ilość), coordinates (@koordynaty), and generic key-value overrides (@<anything>).

    Processing pipeline:
    1. Input collection: resolves -Path to individual entity files (entities.md + *-NNN-ent.md)
    2. Sort ordering: files processed highest-key-first so lowest-numbered file wins on merge
       (entities.md = MaxValue, unrecognised = MaxValue-1, NNN-ent.md = NNN)
    3. Batch parse: single Get-Markdown call parses all files, results keyed by path
    4. Section dispatch: section headers mapped to entity types via Polish singular/plural forms
    5. Tag dispatch: nested @tag bullets dispatched via switch to typed history lists
    6. Entity merge: same-name entities across files have their histories concatenated
    7. CN resolution: post-parse pass builds hierarchical canonical names via Resolve-EntityCN

    Multi-file support: files are processed in descending numeric order so the lowest number
    has highest override primacy. Same-name entities across files are merged, not replaced.

    After parsing, each entity receives a Canonical Name (CN). Non-location entities get
    "Type/Name". Locations and maps get hierarchical paths built by walking the @lokacja
    chain upward (e.g. "Lokacja/Eder/Ithan/Ratusz Ithan"). Cycle detection prevents
    infinite recursion. Locations with active @drzwi also receive path-qualified names
    (e.g. "Ithan/Ratusz Ithan") for resolution convenience.
#>

. "$script:ModuleRoot/private/temporal-helpers.ps1"
function Resolve-EntityCN {
    param(
        [object]$Entity,
        [System.Collections.Generic.HashSet[string]]$Visited,
        [hashtable]$EntityByName,
        [AllowNull()][Nullable[datetime]]$ActiveOn,
        [hashtable]$CNCache
    )

    if ($CNCache -and $CNCache.ContainsKey($Entity.Name)) {
        return $CNCache[$Entity.Name]
    }

    # Mapa shares hierarchical CN logic with Lokacja; all others get flat "Type/Name"
    if ($Entity.Type -ne 'Lokacja' -and $Entity.Type -ne 'Mapa') {
        $Result = "$($Entity.Type)/$($Entity.Name)"
        if ($CNCache) { $CNCache[$Entity.Name] = $Result }
        return $Result
    }

    # HashSet.Add returns false if already present — detects circular @lokacja chains
    if (-not $Visited.Add($Entity.Name)) {
        Write-RobotWarning "[WARN Get-Entity] Cycle detected in @lokacja chain for '$($Entity.Name)'"
        return "Lokacja/$($Entity.Name)"
    }

    # Walk upward: last active @lokacja defines the containment parent
    $ParentName = Get-LastActiveValue -History $Entity.LocationHistory -PropertyName 'Location' -ActiveOn $ActiveOn

    # @drzwi provides a physical-access parent when no @lokacja history exists
    if (-not $ParentName -and $Entity.Doors.Count -gt 0) {
        $ParentName = $Entity.Doors[0]
    }

    # Root location — no containment parent
    if (-not $ParentName) {
        $Result = "Lokacja/$($Entity.Name)"
        if ($CNCache) { $CNCache[$Entity.Name] = $Result }
        return $Result
    }

    $ParentEntity = $EntityByName[$ParentName]
    if (-not $ParentEntity) {
        # Parent name from @lokacja not in the entity registry — treat as literal path segment
        $Result = "Lokacja/$ParentName/$($Entity.Name)"
        if ($CNCache) { $CNCache[$Entity.Name] = $Result }
        return $Result
    }

    $ParentCN = Resolve-EntityCN -Entity $ParentEntity -Visited $Visited -EntityByName $EntityByName -ActiveOn $ActiveOn -CNCache $CNCache
    $Result = "$ParentCN/$($Entity.Name)"
    if ($CNCache) { $CNCache[$Entity.Name] = $Result }
    return $Result
}

function Get-Entity {
    <#
        .SYNOPSIS
        Parses entity registry files (entities.md, *-NNN-ent.md) into structured objects
        with time-scoped metadata, multi-file merge, and hierarchical canonical names.
    #>

    [CmdletBinding()] param(
        [Parameter(HelpMessage = "Path(s) to entity files or directories containing entities.md / *-*-ent.md")]
        [string[]]$Path = @("$(Get-RepoRoot)"),

        [Parameter(HelpMessage = "Filter temporally-scoped data to entries active on this date")]
        [datetime]$ActiveOn,

        [Parameter(HelpMessage = "Suppress warning output to stderr")]
        [switch]$Quiet
    )

    $PrevSuppress = $script:SuppressWarnings
    if ($Quiet) { $script:SuppressWarnings = $true }
    try {

    $Entities  = [System.Collections.Generic.List[object]]::new()
    $EntityMap = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::OrdinalIgnoreCase)

    # Discover all candidate files from supplied paths
    $FilesToProcess = [System.Collections.Generic.List[string]]::new()
    foreach ($InputPath in $Path) {
        if ([System.IO.Directory]::Exists($InputPath)) {
            $BaseFile = [System.IO.Path]::Combine($InputPath, "entities.md")
            if ([System.IO.File]::Exists($BaseFile)) { $FilesToProcess.Add($BaseFile) }
            $FilesToProcess.AddRange([System.IO.Directory]::GetFiles($InputPath, "*-*-ent.md", [System.IO.SearchOption]::AllDirectories))
        }
        elseif ([System.IO.File]::Exists($InputPath)) {
            $FilesToProcess.Add($InputPath)
        }
    }

    # Deduplicate — directory + explicit file args can overlap
    $UniqueSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($FileItem in $FilesToProcess) { [void]$UniqueSet.Add($FileItem) }

    # Sort by numeric key so lowest-numbered file is processed last (highest override primacy).
    # entities.md = MaxValue (first/lowest), unrecognised = MaxValue-1, NNN-ent.md = NNN.
    $NumberPattern = [regex]::new('-(?<number>\d+)-ent\.md$')
    $SortEntries = [System.Collections.Generic.List[object]]::new($UniqueSet.Count)

    foreach ($FilePath in $UniqueSet) {
        $FileName = [System.IO.Path]::GetFileName($FilePath)
        $SortKey = if ($FileName -eq "entities.md") {
            [int]::MaxValue
        }
        else {
            $NumMatch = $NumberPattern.Match($FileName)
            if ($NumMatch.Success) { [int]$NumMatch.Groups["number"].Value } else { [int]::MaxValue - 1 }
        }
        $SortEntries.Add([PSCustomObject]@{ Path = $FilePath; Key = $SortKey })
    }

    $SortEntries.Sort([System.Comparison[object]]{ param($a, $b) $b.Key.CompareTo($a.Key) })

    if ($SortEntries.Count -eq 0) {
        return $Entities
    }

    # Single batch parse amortizes RunspacePool overhead across all entity files
    $EntityFilePaths = [System.Collections.Generic.List[string]]::new($SortEntries.Count)
    foreach ($Entry in $SortEntries) { $EntityFilePaths.Add($Entry.Path) }

    $AllMarkdownResults = @(Get-Markdown -File ($EntityFilePaths.ToArray()))

    $MarkdownByPath = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($MarkdownResult in $AllMarkdownResults) { $MarkdownByPath[$MarkdownResult.FilePath] = $MarkdownResult }

    # Collect sections in sort order so later entities overwrite earlier ones on merge
    $AllSections = [System.Collections.Generic.List[object]]::new()
    foreach ($Entry in $SortEntries) {
        $Markdown = if ($MarkdownByPath.ContainsKey($Entry.Path)) { $MarkdownByPath[$Entry.Path] } else { $null }
        if ($null -ne $Markdown -and $null -ne $Markdown.Sections) {
            $AllSections.AddRange($Markdown.Sections)
        }
    }

    # Polish singular/plural section headers -> canonical type names.
    # Unmatched headers (e.g. "Instrukcja") default to "Entity" and are skipped.
    $TypeMap = @{
        "npc"              = "NPC"
        "grupy"            = "Grupa"
        "grupa"            = "Grupa"
        "lokacje"          = "Lokacja"
        "lokacja"          = "Lokacja"
        "gracz"            = "Gracz"
        "gracze"           = "Gracz"
        "postać (gracz)"   = "Postać"
        "postaci (gracze)" = "Postać"
        "postać"           = "Postać"
        "postaci"          = "Postać"
        "przedmiot"        = "Przedmiot"
        "przedmioty"       = "Przedmiot"
        "mapa"             = "Mapa"
        "mapy"             = "Mapa"
    }

    foreach ($Section in $AllSections) {
        $SectionType = "Entity"
        if ($Section.Header) {
            $HeaderLower = $Section.Header.Text.ToLowerInvariant().Trim()
            if ($TypeMap.ContainsKey($HeaderLower)) {
                $SectionType = $TypeMap[$HeaderLower]
            }
        }

        # O(1) parent->children lookup avoids O(n²) repeated .Where() filtering
        $ChildrenOf = @{}
        $RootChildren = [System.Collections.Generic.List[object]]::new()
        foreach ($LI in $Section.Lists) {
            if ($null -eq $LI.ParentListItem -and $LI.Indent -eq 0) {
                $RootChildren.Add($LI)
            }
            elseif ($null -ne $LI.ParentListItem) {
                $ParentId = [System.Runtime.CompilerServices.RuntimeHelpers]::GetHashCode($LI.ParentListItem)
                if (-not $ChildrenOf.ContainsKey($ParentId)) {
                    $ChildrenOf[$ParentId] = [System.Collections.Generic.List[object]]::new()
                }
                $ChildrenOf[$ParentId].Add($LI)
            }
        }

        foreach ($EntityBullet in $RootChildren) {
            $EntityName = $EntityBullet.Text.Trim()

            # Typed history lists — each @tag switch branch appends to its corresponding list
            $Aliases            = [System.Collections.Generic.List[object]]::new()
            $Names              = [System.Collections.Generic.List[string]]::new()
            $Names.Add($EntityName)
            $LocationHistory    = [System.Collections.Generic.List[object]]::new()
            $DoorHistory        = [System.Collections.Generic.List[object]]::new()
            $TypeHistory        = [System.Collections.Generic.List[object]]::new()
            $OwnerHistory       = [System.Collections.Generic.List[object]]::new()
            $GroupHistory        = [System.Collections.Generic.List[object]]::new()
            $ContainsList       = [System.Collections.Generic.List[string]]::new()
            $StatusHistory      = [System.Collections.Generic.List[object]]::new()
            $QuantityHistory    = [System.Collections.Generic.List[object]]::new()
            $GenericNames       = [System.Collections.Generic.List[string]]::new()
            $FilePathHistory    = [System.Collections.Generic.List[object]]::new()
            $NerthusNameHistory = [System.Collections.Generic.List[object]]::new()
            $CoordinateHistory  = [System.Collections.Generic.List[object]]::new()
            $Overrides          = @{}

            # Identity-hash lookup for child bullets belonging to this entity
            $EntityParentId = [System.Runtime.CompilerServices.RuntimeHelpers]::GetHashCode($EntityBullet)
            $ChildBullets = if ($ChildrenOf.ContainsKey($EntityParentId)) { $ChildrenOf[$EntityParentId] } else { @() }

            foreach ($Bullet in $ChildBullets) {
                $LineText = $Bullet.Text.Trim()

                # Legacy plain-text aliases (non-@ lines) are not parsed here
                if (-not $LineText.StartsWith('@')) { continue }

                $ColonIdx = $LineText.IndexOf(':')
                if ($ColonIdx -lt 0) { continue }

                $Tag   = $LineText.Substring(0, $ColonIdx).Trim().ToLowerInvariant()
                $Value = $LineText.Substring($ColonIdx + 1).Trim()

                # Multi-line tags (e.g. @info) carry values in nested child bullets
                $NestedValue    = Get-NestedBulletText -ParentBullet $Bullet -ChildrenOf $ChildrenOf -ActiveOn $ActiveOn
                $EffectiveValue = if ([string]::IsNullOrWhiteSpace($Value) -and $NestedValue) { $NestedValue } else { $Value }

                switch ($Tag) {
                    '@lokacja' {
                        $Parsed = ConvertFrom-ValidityString -InputText $Value
                        $LocationHistory.Add([PSCustomObject]@{
                            Location  = $Parsed.Text
                            ValidFrom = $Parsed.ValidFrom
                            ValidTo   = $Parsed.ValidTo
                            Season    = $Parsed.Season
                        })
                    }
                    '@drzwi' {
                        $Parsed = ConvertFrom-ValidityString -InputText $Value
                        $DoorHistory.Add([PSCustomObject]@{
                            Location  = $Parsed.Text
                            ValidFrom = $Parsed.ValidFrom
                            ValidTo   = $Parsed.ValidTo
                            Season    = $Parsed.Season
                        })
                    }
                    '@typ' {
                        $Parsed = ConvertFrom-ValidityString -InputText $Value
                        $TypeHistory.Add([PSCustomObject]@{
                            Type      = $Parsed.Text
                            ValidFrom = $Parsed.ValidFrom
                            ValidTo   = $Parsed.ValidTo
                            Season    = $Parsed.Season
                        })
                    }
                    '@należy_do' {
                        $Parsed = ConvertFrom-ValidityString -InputText $Value
                        $OwnerHistory.Add([PSCustomObject]@{
                            OwnerName = $Parsed.Text
                            ValidFrom = $Parsed.ValidFrom
                            ValidTo   = $Parsed.ValidTo
                            Season    = $Parsed.Season
                        })
                    }
                    '@grupa' {
                        $Parsed = ConvertFrom-ValidityString -InputText $Value
                        $GroupHistory.Add([PSCustomObject]@{
                            Group     = $Parsed.Text
                            ValidFrom = $Parsed.ValidFrom
                            ValidTo   = $Parsed.ValidTo
                            Season    = $Parsed.Season
                        })
                    }
                    '@zawiera' {
                        $ContainsList.Add($Value)
                    }
                    '@status' {
                        $Parsed = ConvertFrom-ValidityString -InputText $Value
                        $StatusHistory.Add([PSCustomObject]@{
                            Status    = $Parsed.Text
                            ValidFrom = $Parsed.ValidFrom
                            ValidTo   = $Parsed.ValidTo
                            Season    = $Parsed.Season
                        })
                    }
                    '@ilość' {
                        $Parsed = ConvertFrom-ValidityString -InputText $Value
                        $QuantityHistory.Add([PSCustomObject]@{
                            Quantity  = $Parsed.Text
                            ValidFrom = $Parsed.ValidFrom
                            ValidTo   = $Parsed.ValidTo
                            Season    = $Parsed.Season
                        })
                    }
                    '@alias' {
                        $Parsed = ConvertFrom-ValidityString -InputText $EffectiveValue
                        if (Test-TemporalActivity -Item $Parsed -ActiveOn $ActiveOn) {
                            $Aliases.Add([PSCustomObject]@{
                                Text      = $Parsed.Text
                                ValidFrom = $Parsed.ValidFrom
                                ValidTo   = $Parsed.ValidTo
                                Season    = $Parsed.Season
                            })
                            $Names.Add($Parsed.Text)
                        }
                    }
                    '@generyczne_nazwy' {
                        foreach ($GN in $Value.Split(',')) {
                            $Trimmed = $GN.Trim()
                            if ($Trimmed.Length -gt 0) {
                                $GenericNames.Add($Trimmed)
                                $Names.Add($Trimmed)
                            }
                        }
                    }
                    '@plik' {
                        $Parsed = ConvertFrom-ValidityString -InputText $Value
                        $FilePathHistory.Add([PSCustomObject]@{
                            FilePath  = $Parsed.Text
                            ValidFrom = $Parsed.ValidFrom
                            ValidTo   = $Parsed.ValidTo
                            Season    = $Parsed.Season
                        })
                    }
                    '@nazwa_nerthus' {
                        $Parsed = ConvertFrom-ValidityString -InputText $Value
                        $NerthusNameHistory.Add([PSCustomObject]@{
                            NerthusName = $Parsed.Text
                            ValidFrom   = $Parsed.ValidFrom
                            ValidTo     = $Parsed.ValidTo
                            Season      = $Parsed.Season
                        })
                        # Add active Nerthus name to Names for resolution
                        if (Test-TemporalActivity -Item $Parsed -ActiveOn $ActiveOn) {
                            $Names.Add($Parsed.Text)
                        }
                    }
                    '@slug' {
                        $Parsed = ConvertFrom-ValidityString -InputText $Value
                        if (Test-TemporalActivity -Item $Parsed -ActiveOn $ActiveOn) {
                            $Names.Add($Parsed.Text)
                        }
                    }
                    '@koordynaty' {
                        $Parsed = ConvertFrom-ValidityString -InputText $Value
                        $Coord = ConvertFrom-CoordinateString -Text $Parsed.Text
                        if ($Coord) {
                            $CoordinateHistory.Add([PSCustomObject]@{
                                X         = $Coord.X
                                Y         = $Coord.Y
                                ValidFrom = $Parsed.ValidFrom
                                ValidTo   = $Parsed.ValidTo
                                Season    = $Parsed.Season
                            })
                        }
                    }
                    default {
                        # Unrecognised @tags stored as generic overrides (e.g. @pu_startowe, @info, @trigger)
                        $Parsed = ConvertFrom-ValidityString -InputText $EffectiveValue
                        if (Test-TemporalActivity -Item $Parsed -ActiveOn $ActiveOn) {
                            $PropName  = $Tag.Substring(1)  # strip leading '@'
                            $PropValue = if ([string]::IsNullOrWhiteSpace($Value) -and $NestedValue) {
                                $NestedValue
                            } elseif (-not [string]::IsNullOrWhiteSpace($Value) -and $NestedValue) {
                                $Parsed.Text + "`n" + $NestedValue
                            } else {
                                $Parsed.Text
                            }

                            if (-not $Overrides.ContainsKey($PropName)) {
                                $Overrides[$PropName] = [System.Collections.Generic.List[string]]::new()
                            }
                            $Overrides[$PropName].Add($PropValue)
                        }
                    }
                }
            }

            # Deduplicate names and resolve scalar values from temporal histories
            $Names          = [System.Collections.Generic.HashSet[string]]::new($Names, [System.StringComparer]::OrdinalIgnoreCase)
            $ActiveLocation = Get-LastActiveValue  -History $LocationHistory -PropertyName 'Location'  -ActiveOn $ActiveOn
            $ActiveDoors    = Get-AllActiveValues   -History $DoorHistory     -PropertyName 'Location'  -ActiveOn $ActiveOn
            $ActiveType     = Get-LastActiveValue  -History $TypeHistory     -PropertyName 'Type'      -ActiveOn $ActiveOn
            if (-not $ActiveType) { $ActiveType = $SectionType }
            $ActiveOwner    = Get-LastActiveValue  -History $OwnerHistory    -PropertyName 'OwnerName' -ActiveOn $ActiveOn
            $ActiveGroups   = Get-AllActiveValues   -History $GroupHistory    -PropertyName 'Group'     -ActiveOn $ActiveOn
            $ActiveStatus   = Get-LastActiveValue  -History $StatusHistory   -PropertyName 'Status'    -ActiveOn $ActiveOn
            if (-not $ActiveStatus) { $ActiveStatus = 'Aktywny' }  # default: all entities are active
            $ActiveQuantity = Get-LastActiveValue  -History $QuantityHistory -PropertyName 'Quantity'  -ActiveOn $ActiveOn
            $ActiveFilePath = Get-LastActiveValue  -History $FilePathHistory -PropertyName 'FilePath'  -ActiveOn $ActiveOn
            $ActiveNerthusName = Get-LastActiveValue -History $NerthusNameHistory -PropertyName 'NerthusName' -ActiveOn $ActiveOn

            $ActiveCoordinates = $null
            if ($CoordinateHistory.Count -gt 0) {
                $ActiveCoordEntries = $CoordinateHistory.Where({ Test-TemporalActivity -Item $_ -ActiveOn $ActiveOn })
                if ($ActiveCoordEntries.Count -gt 0) {
                    $LastCoord = $ActiveCoordEntries[-1]
                    $ActiveCoordinates = @{ X = $LastCoord.X; Y = $LastCoord.Y }
                }
            }

            # Path-qualified names (e.g. "Ithan/Ratusz") enable unambiguous resolution via door context
            if (($SectionType -eq 'Lokacja' -or $SectionType -eq 'Mapa') -and $ActiveDoors.Count -gt 0) {
                foreach ($DoorName in $ActiveDoors) {
                    [void]$Names.Add("$DoorName/$EntityName")
                }
            }

            $EntityKey = "$SectionType/$EntityName"
            if ($EntityMap.ContainsKey($EntityKey)) {
                # Same-name entity from another file — merge all histories and recompute scalars
                $Existing = $EntityMap[$EntityKey]

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

                # Recompute active scalars from merged histories — latest active entry wins
                if ($SectionType -ne "Entity") { $Existing.Type = $SectionType }
                $MergedType = Get-LastActiveValue -History $Existing.TypeHistory -PropertyName 'Type' -ActiveOn $ActiveOn
                if ($MergedType) { $Existing.Type = $MergedType }

                $MergedOwner = Get-LastActiveValue -History $Existing.OwnerHistory -PropertyName 'OwnerName' -ActiveOn $ActiveOn
                if ($MergedOwner) { $Existing.Owner = $MergedOwner }

                $Existing.Groups = Get-AllActiveValues -History $Existing.GroupHistory -PropertyName 'Group' -ActiveOn $ActiveOn

                $MergedLoc = Get-LastActiveValue -History $Existing.LocationHistory -PropertyName 'Location' -ActiveOn $ActiveOn
                if ($MergedLoc) { $Existing.Location = $MergedLoc }

                $Existing.Doors = Get-AllActiveValues -History $Existing.DoorHistory -PropertyName 'Location' -ActiveOn $ActiveOn

                $MergedStatus = Get-LastActiveValue -History $Existing.StatusHistory -PropertyName 'Status' -ActiveOn $ActiveOn
                if ($MergedStatus) { $Existing.Status = $MergedStatus }

                $MergedQuantity = Get-LastActiveValue -History $Existing.QuantityHistory -PropertyName 'Quantity' -ActiveOn $ActiveOn
                if ($MergedQuantity) { $Existing.Quantity = $MergedQuantity }

                $MergedFilePath = Get-LastActiveValue -History $Existing.FilePathHistory -PropertyName 'FilePath' -ActiveOn $ActiveOn
                if ($MergedFilePath) { $Existing.FilePath = $MergedFilePath }

                $MergedNerthusName = Get-LastActiveValue -History $Existing.NerthusNameHistory -PropertyName 'NerthusName' -ActiveOn $ActiveOn
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
            else {
                $Entity = [PSCustomObject]@{
                    Name               = $EntityName
                    CN                 = $null  # resolved in post-parse CN pass
                    Names              = $Names
                    Aliases            = $Aliases
                    Type               = $ActiveType
                    Owner              = $ActiveOwner
                    Groups             = $ActiveGroups
                    Overrides          = $Overrides
                    TypeHistory        = $TypeHistory
                    OwnerHistory       = $OwnerHistory
                    GroupHistory       = $GroupHistory
                    Location           = $ActiveLocation
                    LocationHistory    = $LocationHistory
                    Doors              = $ActiveDoors
                    DoorHistory        = $DoorHistory
                    Status             = $ActiveStatus
                    StatusHistory      = $StatusHistory
                    Quantity           = $ActiveQuantity
                    QuantityHistory    = $QuantityHistory
                    GenericNames       = $GenericNames
                    FilePath           = $ActiveFilePath
                    FilePathHistory    = $FilePathHistory
                    NerthusName        = $ActiveNerthusName
                    NerthusNameHistory = $NerthusNameHistory
                    Coordinates        = $ActiveCoordinates
                    CoordinateHistory  = $CoordinateHistory
                    Contains           = $ContainsList
                }
                $EntityMap[$EntityKey] = $Entity
                $Entities.Add($Entity)
            }
        }
    }

    # Post-parse CN resolution — walks @lokacja chains to build hierarchical paths
    $EntityByName = @{}
    foreach ($Entity in $Entities) {
        $EntityByName[$Entity.Name] = $Entity
    }

    $CNCache = @{}
    foreach ($Entity in $Entities) {
        $Visited = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        $Entity.CN = Resolve-EntityCN -Entity $Entity -Visited $Visited -EntityByName $EntityByName -ActiveOn $ActiveOn -CNCache $CNCache
    }

    return $Entities

    } finally { $script:SuppressWarnings = $PrevSuppress }
}
