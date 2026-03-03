<#
    .SYNOPSIS
    Temporal validity helpers for time-scoped entity metadata.

    .DESCRIPTION
    This file contains shared temporal utility functions extracted from get-entity.ps1:

    Helpers:
    - ConvertFrom-ValidityString: splits "Value (2025-02:)" into { Text, ValidFrom, ValidTo, Season }
    - Resolve-PartialDate:        expands partial dates (YYYY, YYYY-MM) to full datetime values
    - Resolve-SeasonForDate:      returns Polish season name for a given date
    - Test-TemporalActivity:      checks if an item falls within an -ActiveOn date window (date + season)
    - Get-NestedBulletText:       collects text from child bullets that pass temporal filtering
    - Get-LastActiveValue:        returns the last active entry from a history list
    - Get-AllActiveValues:        returns all active entries from a history list as string[]

    Module-level data:
    - $ValidityPattern:    precompiled regex for parsing validity range syntax
    - $SeasonKeywords:     HashSet of valid Polish season keywords
    - $DateRangePattern:   precompiled regex for detecting date range components

    These helpers are used by Get-Entity, Get-EntityState, Get-Session (via
    Resolve-IntelTargets), and various reporting commands. They are dot-sourced
    by consuming files (get-entity.ps1, etc.) rather than auto-loaded by the
    module loader.
#>

# Precompiled regex - captures text and optional parenthetical content
$script:ValidityPattern = [regex]::new('^(.*?)(?:\s*\(([^)]+)\))?$', [System.Text.RegularExpressions.RegexOptions]::Compiled)

# Date range component detector - matches start:end patterns
$script:DateRangePattern = [regex]::new('^([^:]*):(.*)$', [System.Text.RegularExpressions.RegexOptions]::Compiled)

# Valid Polish season keywords (case-insensitive matching via OrdinalIgnoreCase)
$script:SeasonKeywords = [System.Collections.Generic.HashSet[string]]::new(
    [string[]]@('wiosna', 'lato', 'jesień', 'zima'),
    [System.StringComparer]::OrdinalIgnoreCase)

# Helper: parse temporal validity range
# Splits text like "Value (2025-02:)" or "Value (:2025-01)" or "Value (zima)"
# or "Value (2024-01:, zima)" into structured components.
# Handles partial dates (YYYY, YYYY-MM, YYYY-MM-DD). Start dates resolve to
# first day of period, end dates to last day.
# Season keywords: wiosna, lato, jesień, zima (Polish, case-insensitive).
# Returns hashtable: @{ Text; ValidFrom; ValidTo; Season }
function ConvertFrom-ValidityString {
    param([string]$InputText)

    $Match = $script:ValidityPattern.Match($InputText.Trim())

    if (-not $Match.Success) {
        return @{ Text = $InputText.Trim(); ValidFrom = $null; ValidTo = $null; Season = $null }
    }

    $Name       = $Match.Groups[1].Value.Trim()
    $ParenGroup = $Match.Groups[2]

    if (-not $ParenGroup.Success) {
        # No parenthetical content
        return @{ Text = $Name; ValidFrom = $null; ValidTo = $null; Season = $null }
    }

    $ParenContent = $ParenGroup.Value.Trim()

    # Check for comma-separated components (season + date range in any order)
    if ($ParenContent.Contains(',')) {
        $Parts = $ParenContent.Split(',')
        $Season    = $null
        $DatePart  = $null

        foreach ($Part in $Parts) {
            $Trimmed = $Part.Trim()
            if ($script:SeasonKeywords.Contains($Trimmed)) {
                $Season = $Trimmed.ToLowerInvariant()
            } else {
                $DatePart = $Trimmed
            }
        }

        # Parse date range part if found
        $ValidFrom = $null
        $ValidTo   = $null
        if ($DatePart) {
            $DateMatch = $script:DateRangePattern.Match($DatePart)
            if ($DateMatch.Success) {
                $ValidFrom = Resolve-PartialDate -DateStr $DateMatch.Groups[1].Value.Trim() -IsEnd $false
                $ValidTo   = Resolve-PartialDate -DateStr $DateMatch.Groups[2].Value.Trim() -IsEnd $true
            }
        }

        return @{
            Text      = $Name
            ValidFrom = $ValidFrom
            ValidTo   = $ValidTo
            Season    = $Season
        }
    }

    # Single component: season keyword, date range, or literal text
    if ($script:SeasonKeywords.Contains($ParenContent)) {
        # Season-only
        return @{
            Text      = $Name
            ValidFrom = $null
            ValidTo   = $null
            Season    = $ParenContent.ToLowerInvariant()
        }
    }

    $DateMatch = $script:DateRangePattern.Match($ParenContent)
    if ($DateMatch.Success) {
        # Date range only (existing behavior)
        $ValidFrom = Resolve-PartialDate -DateStr $DateMatch.Groups[1].Value.Trim() -IsEnd $false
        $ValidTo   = Resolve-PartialDate -DateStr $DateMatch.Groups[2].Value.Trim() -IsEnd $true
        return @{
            Text      = $Name
            ValidFrom = $ValidFrom
            ValidTo   = $ValidTo
            Season    = $null
        }
    }

    # Not temporal - restore parenthetical as literal text (backward compat)
    return @{
        Text      = "$Name ($ParenContent)"
        ValidFrom = $null
        ValidTo   = $null
        Season    = $null
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

# Helper: resolve season name for a given date
# Default meteorological mapping: Mar-May=wiosna, Jun-Aug=lato, Sep-Nov=jesień, Dec-Feb=zima.
# Custom mapping from $script:CachedSeasonMapping (loaded from local.config.psd1) overrides defaults.
function Resolve-SeasonForDate {
    param(
        [Parameter(Mandatory)]
        [datetime]$Date
    )

    # Check for custom mapping from local.config.psd1
    if ($script:CachedSeasonMapping) {
        foreach ($Entry in $script:CachedSeasonMapping.GetEnumerator()) {
            $Months = $Entry.Value
            if ($Months -contains $Date.Month) {
                return $Entry.Key
            }
        }
    }

    # Default meteorological seasons
    switch ($Date.Month) {
        { $_ -ge 3 -and $_ -le 5 }  { return 'wiosna' }
        { $_ -ge 6 -and $_ -le 8 }  { return 'lato' }
        { $_ -ge 9 -and $_ -le 11 } { return 'jesień' }
        default                       { return 'zima' }
    }
}

# Helper: temporal activity check
# Returns $true when $Item falls within the -ActiveOn window. Items without
# validity bounds are always active. When $ActiveOn is $null (not supplied),
# every item is considered active. Also checks seasonal constraint when present.
function Test-TemporalActivity {
    param(
        [object]$Item,
        [AllowNull()][Nullable[datetime]]$ActiveOn
    )

    if ($null -eq $ActiveOn)                                  { return $true }
    if ($Item.ValidFrom -and $ActiveOn -lt $Item.ValidFrom)   { return $false }
    if ($Item.ValidTo   -and $ActiveOn -gt $Item.ValidTo)     { return $false }

    # Season check: if item has a Season constraint, verify it matches the ActiveOn date
    if ($Item.Season) {
        $CurrentSeason = Resolve-SeasonForDate -Date $ActiveOn
        if (-not [string]::Equals($Item.Season, $CurrentSeason, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $false
        }
    }

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
