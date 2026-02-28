<#
    .SYNOPSIS
    Parses entity registry files (entities.md, *-NNN-ent.md) into structured objects with
    time-scoped metadata, multi-file merge, and hierarchical canonical names.

    .DESCRIPTION
    This file contains Get-Entity and its helpers:

    Helpers:
    - ConvertFrom-ValidityString: splits "Value (2025-02:)" into { Text, ValidFrom, ValidTo }
    - Resolve-PartialDate:        expands partial dates (YYYY, YYYY-MM) to full datetime values
    - Test-TemporalActivity:      checks if an item falls within an -ActiveOn date window
    - Get-NestedBulletText:       collects text from child bullets that pass temporal filtering
    - Get-LastActiveValue:        returns the last active entry from a history list
    - Get-AllActiveValues:        returns all active entries from a history list as string[]
    - Resolve-EntityCN:           builds hierarchical canonical names for locations via @lokacja chain

    Module-level data:
    - $ValidityPattern: precompiled regex for parsing validity range syntax

    Get-Entity reads entity registry Markdown files and builds a unified collection of typed
    entity objects (NPCs, organizations, locations, players). Entities carry time-scoped
    aliases (@alias), location assignments and containment hierarchy (@lokacja), group
    memberships (@grupa), and generic key-value overrides (@<anything>).

    Multi-file support: files are processed in descending numeric order so the lowest number
    has highest override primacy. Same-name entities across files are merged, not replaced.

    After parsing, each entity receives a Canonical Name (CN). Non-location entities get
    "Type/Name". Locations get hierarchical paths built by walking the @lokacja chain upward
    (e.g. "Lokacja/Eder/Ithan/Ratusz Ithan"). Cycle detection prevents infinite recursion.
#>

# Helper: parse temporal validity range
# Splits text like "Value (2025-02:)" or "Value (:2025-01)" into structured
# components. Handles partial dates (YYYY, YYYY-MM, YYYY-MM-DD). Start dates
# resolve to first day of period, end dates to last day.
# Returns hashtable: @{ Text; ValidFrom; ValidTo }

# Precompiled regex - shared across all ConvertFrom-ValidityString calls
$script:ValidityPattern = [regex]::new('^(.*?)(?:\s*\(([^:)]*):([^)]*)\))?$', [System.Text.RegularExpressions.RegexOptions]::Compiled)

function ConvertFrom-ValidityString {
    param([string]$InputText)

    $Match = $script:ValidityPattern.Match($InputText.Trim())

    if (-not $Match.Success) {
        return @{ Text = $InputText.Trim(); ValidFrom = $null; ValidTo = $null }
    }

    $Name     = $Match.Groups[1].Value.Trim()
    $StartStr = $Match.Groups[2].Value.Trim()
    $EndStr   = $Match.Groups[3].Value.Trim()

    $ValidFrom = Resolve-PartialDate -DateStr $StartStr -IsEnd $false
    $ValidTo   = Resolve-PartialDate -DateStr $EndStr   -IsEnd $true

    return @{
        Text      = $Name
        ValidFrom = $ValidFrom
        ValidTo   = $ValidTo
    }
}

# Helper: parse partial date string
# Accepts YYYY, YYYY-MM, or YYYY-MM-DD. When -IsEnd is true, expands to the
# last day of the period (e.g. 2024-06 -> 2024-06-30); otherwise to the first
# day (e.g. 2024-06 -> 2024-06-01). Returns [datetime] or $null.
function Resolve-PartialDate {
    param(
        [string]$DateStr,
        [bool]$IsEnd = $false
    )

    if ([string]::IsNullOrWhiteSpace($DateStr)) { return $null }

    $Normalized = $DateStr
    if ($DateStr -match '^\d{4}$') {
        $Normalized = if ($IsEnd) { "$DateStr-12-31" } else { "$DateStr-01-01" }
    }
    elseif ($DateStr -match '^\d{4}-\d{2}$') {
        if ($IsEnd) {
            $Year    = [int]$DateStr.Split('-')[0]
            $Month   = [int]$DateStr.Split('-')[1]
            $LastDay = [DateTime]::DaysInMonth($Year, $Month)
            $Normalized = "$DateStr-$LastDay"
        }
        else {
            $Normalized = "$DateStr-01"
        }
    }

    try {
        return [datetime]::ParseExact($Normalized, "yyyy-MM-dd", [System.Globalization.CultureInfo]::InvariantCulture)
    }
    catch {
        return $null
    }
}

# Helper: temporal activity check
# Returns $true when $Item falls within the -ActiveOn window. Items without
# validity bounds are always active. When $ActiveOn is $null (not supplied),
# every item is considered active.
function Test-TemporalActivity {
    param(
        [object]$Item,
        [AllowNull()][Nullable[datetime]]$ActiveOn
    )

    if ($null -eq $ActiveOn)                                  { return $true }
    if ($Item.ValidFrom -and $ActiveOn -lt $Item.ValidFrom)   { return $false }
    if ($Item.ValidTo   -and $ActiveOn -gt $Item.ValidTo)     { return $false }
    return $true
}

# Helper: collect nested bullet text
# Given a parent list item and a ChildrenOf lookup, gathers text from
# all direct children that pass the temporal activity filter. Returns a single
# newline-joined string or $null when no children match.
function Get-NestedBulletText {
    param(
        [object]$ParentBullet,
        [hashtable]$ChildrenOf,
        [AllowNull()][Nullable[datetime]]$ActiveOn
    )

    $ParentId = [System.Runtime.CompilerServices.RuntimeHelpers]::GetHashCode($ParentBullet)
    if (-not $ChildrenOf.ContainsKey($ParentId)) { return $null }
    $Children = $ChildrenOf[$ParentId]
    if ($Children.Count -eq 0) { return $null }

    $Texts = [System.Collections.Generic.List[string]]::new()
    foreach ($Child in $Children) {
        $Parsed = ConvertFrom-ValidityString -InputText $Child.Text.Trim()
        if (Test-TemporalActivity -Item $Parsed -ActiveOn $ActiveOn) {
            $Texts.Add($Parsed.Text)
        }
    }

    if ($Texts.Count -eq 0) { return $null }
    return $Texts -join "`n"
}

# Helper: resolve last-active scalar from history list
# Filters a history list through Test-TemporalActivity and returns the property
# value of the last (most recently added) active entry, or $null.
function Get-LastActiveValue {
    param(
        [System.Collections.Generic.List[object]]$History,
        [string]$PropertyName,
        [AllowNull()][Nullable[datetime]]$ActiveOn
    )

    if ($History.Count -eq 0) { return $null }

    $Active = $History.Where({ Test-TemporalActivity -Item $_ -ActiveOn $ActiveOn })
    if ($Active.Count -eq 0) { return $null }
    return $Active[-1].$PropertyName
}

# Helper: resolve all active values from history as string[]
# Similar to Get-LastActiveValue but collects all active entries into an array.
# Used for multi-valued properties like Groups and Doors.
function Get-AllActiveValues {
    param(
        [System.Collections.Generic.List[object]]$History,
        [string]$PropertyName,
        [AllowNull()][Nullable[datetime]]$ActiveOn
    )

    if ($History.Count -eq 0) { return @() }

    $Active = $History.Where({ Test-TemporalActivity -Item $_ -ActiveOn $ActiveOn })
    if ($Active.Count -eq 0) { return @() }

    $Values = [System.Collections.Generic.List[string]]::new($Active.Count)
    foreach ($Entry in $Active) { $Values.Add($Entry.$PropertyName) }
    return $Values.ToArray()
}

# Helper: resolve canonical name for an entity
# Non-location entities get a flat "Type/Name" CN. Locations get a hierarchical
# path derived from the @lokacja history (e.g. "Lokacja/Eder/Ithan/Ratusz Ithan").
# Uses $Visited HashSet for cycle detection to prevent infinite recursion in
# circular @lokacja references. Falls back to first active @drzwi when no @lokacja exists.
function Resolve-EntityCN {
    param(
        [object]$Entity,
        [System.Collections.Generic.HashSet[string]]$Visited,
        [hashtable]$EntityByName,
        [AllowNull()][Nullable[datetime]]$ActiveOn,
        [hashtable]$CNCache
    )

    # Memoization: return cached CN if already resolved
    if ($CNCache -and $CNCache.ContainsKey($Entity.Name)) {
        return $CNCache[$Entity.Name]
    }

    # Non-locations always get a flat CN
    if ($Entity.Type -ne 'Lokacja') {
        $Result = "$($Entity.Type)/$($Entity.Name)"
        if ($CNCache) { $CNCache[$Entity.Name] = $Result }
        return $Result
    }

    # Cycle guard
    if (-not $Visited.Add($Entity.Name)) {
        [System.Console]::Error.WriteLine("[WARN Get-Entity] Cycle detected in @lokacja chain for '$($Entity.Name)'")
        return "Lokacja/$($Entity.Name)"
    }

    # Find the containment parent from the last active @lokacja entry
    $ParentName = Get-LastActiveValue -History $Entity.LocationHistory -PropertyName 'Location' -ActiveOn $ActiveOn

    # Fallback: first active @drzwi if no @lokacja history
    if (-not $ParentName -and $Entity.Doors.Count -gt 0) {
        $ParentName = $Entity.Doors[0]
    }

    # Top-level location - no parent found
    if (-not $ParentName) {
        $Result = "Lokacja/$($Entity.Name)"
        if ($CNCache) { $CNCache[$Entity.Name] = $Result }
        return $Result
    }

    # Recurse into parent entity
    $ParentEntity = $EntityByName[$ParentName]
    if (-not $ParentEntity) {
        # Parent not registered as an entity - use raw name as-is
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
        [string[]]$Path = @("$(Get-RepoRoot)/.robot.new"),

        [Parameter(HelpMessage = "Filter temporally-scoped data to entries active on this date")]
        [datetime]$ActiveOn
    )

    # Collect and sort input files
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

    # Deduplicate paths
    $UniqueSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($FileItem in $FilesToProcess) { [void]$UniqueSet.Add($FileItem) }

    # Build sortable entries with numeric keys extracted from filenames.
    # Processing order: highest key first -> lowest key last.
    # entities.md  = MaxValue   (processed first, lowest primacy)
    # unrecognised = MaxValue-1 (next-lowest primacy)
    # NNN-ent.md   = NNN        (lowest NNN processed last, highest primacy)
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

    # Batch-parse all entity files in a single Get-Markdown call
    $EntityFilePaths = [System.Collections.Generic.List[string]]::new($SortEntries.Count)
    foreach ($Entry in $SortEntries) { $EntityFilePaths.Add($Entry.Path) }

    $AllMarkdownResults = @(Get-Markdown -File ($EntityFilePaths.ToArray()))

    $MarkdownByPath = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($MarkdownResult in $AllMarkdownResults) { $MarkdownByPath[$MarkdownResult.FilePath] = $MarkdownResult }

    # Iterate in sort order to preserve override primacy
    $AllSections = [System.Collections.Generic.List[object]]::new()
    foreach ($Entry in $SortEntries) {
        $Markdown = if ($MarkdownByPath.ContainsKey($Entry.Path)) { $MarkdownByPath[$Entry.Path] } else { $null }
        if ($null -ne $Markdown -and $null -ne $Markdown.Sections) {
            $AllSections.AddRange($Markdown.Sections)
        }
    }

    # Section header -> entity type mapping
    # Supports singular and plural Polish forms. Headers not in this map
    # (e.g. "Instrukcja") default to the generic "Entity" type and are skipped
    # during entity extraction.

    $TypeMap = @{
        "npc"              = "NPC"
        "organizacje"      = "Organizacja"
        "organizacja"      = "Organizacja"
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
    }

    # Main parsing loop: iterate sections -> entities -> tags
    foreach ($Section in $AllSections) {
        # Determine entity type from section header
        $SectionType = "Entity"
        if ($Section.Header) {
            $HeaderLower = $Section.Header.Text.ToLowerInvariant().Trim()
            if ($TypeMap.ContainsKey($HeaderLower)) {
                $SectionType = $TypeMap[$HeaderLower]
            }
        }

        # Build parent->children lookup in one pass to avoid O(n²) repeated .Where() filtering
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

        # Top-level bullets are entity declarations
        $EntityBullets = $RootChildren

        foreach ($EntityBullet in $EntityBullets) {
            $EntityName = $EntityBullet.Text.Trim()

            # Per-entity collections - populated from nested @tag bullets below
            $Aliases         = [System.Collections.Generic.List[object]]::new()
            $Names           = [System.Collections.Generic.List[string]]::new()
            $Names.Add($EntityName)
            $LocationHistory = [System.Collections.Generic.List[object]]::new()
            $DoorHistory     = [System.Collections.Generic.List[object]]::new()
            $TypeHistory     = [System.Collections.Generic.List[object]]::new()
            $OwnerHistory    = [System.Collections.Generic.List[object]]::new()
            $GroupHistory    = [System.Collections.Generic.List[object]]::new()
            $ContainsList    = [System.Collections.Generic.List[string]]::new()
            $StatusHistory   = [System.Collections.Generic.List[object]]::new()
            $QuantityHistory = [System.Collections.Generic.List[object]]::new()
            $GenericNames    = [System.Collections.Generic.List[string]]::new()
            $Overrides       = @{}

            # Iterate child bullets belonging to this entity via lookup
            $EntityParentId = [System.Runtime.CompilerServices.RuntimeHelpers]::GetHashCode($EntityBullet)
            $ChildBullets = if ($ChildrenOf.ContainsKey($EntityParentId)) { $ChildrenOf[$EntityParentId] } else { @() }

            foreach ($Bullet in $ChildBullets) {
                $LineText = $Bullet.Text.Trim()

                # Non-@ lines are plain aliases (legacy format) - skip them here
                if (-not $LineText.StartsWith('@')) { continue }

                # Split "@tag: value"
                $ColonIdx = $LineText.IndexOf(':')
                if ($ColonIdx -lt 0) { continue }

                $Tag   = $LineText.Substring(0, $ColonIdx).Trim().ToLowerInvariant()
                $Value = $LineText.Substring($ColonIdx + 1).Trim()

                # Some tags accept multi-line values via nested bullets (e.g. @info)
                $NestedValue    = Get-NestedBulletText -ParentBullet $Bullet -ChildrenOf $ChildrenOf -ActiveOn $ActiveOn
                $EffectiveValue = if ([string]::IsNullOrWhiteSpace($Value) -and $NestedValue) { $NestedValue } else { $Value }

                # Dispatch by tag
                switch ($Tag) {
                    '@lokacja' {
                        $Parsed = ConvertFrom-ValidityString -InputText $Value
                        $LocationHistory.Add([PSCustomObject]@{
                            Location  = $Parsed.Text
                            ValidFrom = $Parsed.ValidFrom
                            ValidTo   = $Parsed.ValidTo
                        })
                    }
                    '@drzwi' {
                        $Parsed = ConvertFrom-ValidityString -InputText $Value
                        $DoorHistory.Add([PSCustomObject]@{
                            Location  = $Parsed.Text
                            ValidFrom = $Parsed.ValidFrom
                            ValidTo   = $Parsed.ValidTo
                        })
                    }
                    '@typ' {
                        $Parsed = ConvertFrom-ValidityString -InputText $Value
                        $TypeHistory.Add([PSCustomObject]@{
                            Type      = $Parsed.Text
                            ValidFrom = $Parsed.ValidFrom
                            ValidTo   = $Parsed.ValidTo
                        })
                    }
                    '@należy_do' {
                        $Parsed = ConvertFrom-ValidityString -InputText $Value
                        $OwnerHistory.Add([PSCustomObject]@{
                            OwnerName = $Parsed.Text
                            ValidFrom = $Parsed.ValidFrom
                            ValidTo   = $Parsed.ValidTo
                        })
                    }
                    '@grupa' {
                        $Parsed = ConvertFrom-ValidityString -InputText $Value
                        $GroupHistory.Add([PSCustomObject]@{
                            Group     = $Parsed.Text
                            ValidFrom = $Parsed.ValidFrom
                            ValidTo   = $Parsed.ValidTo
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
                        })
                    }
                    '@ilość' {
                        $Parsed = ConvertFrom-ValidityString -InputText $Value
                        $QuantityHistory.Add([PSCustomObject]@{
                            Quantity  = $Parsed.Text
                            ValidFrom = $Parsed.ValidFrom
                            ValidTo   = $Parsed.ValidTo
                        })
                    }
                    '@alias' {
                        $Parsed = ConvertFrom-ValidityString -InputText $EffectiveValue
                        if (Test-TemporalActivity -Item $Parsed -ActiveOn $ActiveOn) {
                            $Aliases.Add([PSCustomObject]@{
                                Text      = $Parsed.Text
                                ValidFrom = $Parsed.ValidFrom
                                ValidTo   = $Parsed.ValidTo
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
                    default {
                        # Any unrecognised @tag -> generic override (e.g. @pu_startowe, @info, @trigger)
                        $Parsed = ConvertFrom-ValidityString -InputText $EffectiveValue
                        if (Test-TemporalActivity -Item $Parsed -ActiveOn $ActiveOn) {
                            $PropName  = $Tag.Substring(1)  # strip leading '@'
                            $PropValue = if ([string]::IsNullOrWhiteSpace($Value) -and $NestedValue) { $NestedValue } else { $Parsed.Text }

                            if (-not $Overrides.ContainsKey($PropName)) {
                                $Overrides[$PropName] = [System.Collections.Generic.List[string]]::new()
                            }
                            $Overrides[$PropName].Add($PropValue)
                        }
                    }
                }
            }

            # Resolve active scalar values from histories
            $Names          = [System.Collections.Generic.HashSet[string]]::new($Names, [System.StringComparer]::OrdinalIgnoreCase)
            $ActiveLocation = Get-LastActiveValue  -History $LocationHistory -PropertyName 'Location'  -ActiveOn $ActiveOn
            $ActiveDoors    = Get-AllActiveValues   -History $DoorHistory     -PropertyName 'Location'  -ActiveOn $ActiveOn
            $ActiveType     = Get-LastActiveValue  -History $TypeHistory     -PropertyName 'Type'      -ActiveOn $ActiveOn
            if (-not $ActiveType) { $ActiveType = $SectionType }
            $ActiveOwner    = Get-LastActiveValue  -History $OwnerHistory    -PropertyName 'OwnerName' -ActiveOn $ActiveOn
            $ActiveGroups   = Get-AllActiveValues   -History $GroupHistory    -PropertyName 'Group'     -ActiveOn $ActiveOn
            $ActiveStatus   = Get-LastActiveValue  -History $StatusHistory   -PropertyName 'Status'    -ActiveOn $ActiveOn
            if (-not $ActiveStatus) { $ActiveStatus = 'Aktywny' }
            $ActiveQuantity = Get-LastActiveValue  -History $QuantityHistory -PropertyName 'Quantity'  -ActiveOn $ActiveOn

            # Merge or create entity
            if ($EntityMap.ContainsKey($EntityName)) {
                # Entity already seen in a previously-processed file - merge data
                $Existing = $EntityMap[$EntityName]

                foreach ($NameEntry in $Names) { [void]$Existing.Names.Add($NameEntry) }
                $Existing.Aliases.AddRange($Aliases)

                # Merge override dictionaries
                foreach ($Key in $Overrides.Keys) {
                    if (-not $Existing.Overrides.ContainsKey($Key)) {
                        $Existing.Overrides[$Key] = [System.Collections.Generic.List[string]]::new()
                    }
                    $Existing.Overrides[$Key].AddRange($Overrides[$Key])
                }

                # Merge all history lists
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

                # Recompute active scalar properties from merged histories
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
            }
            else {
                # First occurrence - create new entity object
                $Entity = [PSCustomObject]@{
                    Name            = $EntityName
                    CN              = $null           # resolved in post-parse pass below
                    Names           = $Names
                    Aliases         = $Aliases
                    Type            = $ActiveType
                    Owner           = $ActiveOwner
                    Groups          = $ActiveGroups
                    Overrides       = $Overrides
                    TypeHistory     = $TypeHistory
                    OwnerHistory    = $OwnerHistory
                    GroupHistory    = $GroupHistory
                    Location        = $ActiveLocation
                    LocationHistory = $LocationHistory
                    Doors           = $ActiveDoors
                    DoorHistory     = $DoorHistory
                    Status          = $ActiveStatus
                    StatusHistory   = $StatusHistory
                    Quantity        = $ActiveQuantity
                    QuantityHistory = $QuantityHistory
                    GenericNames    = $GenericNames
                    Contains        = $ContainsList
                }
                $EntityMap[$EntityName] = $Entity
                $Entities.Add($Entity)
            }
        }
    }

    # Post-parse: resolve canonical names
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
}
