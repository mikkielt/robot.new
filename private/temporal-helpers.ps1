<#
    .SYNOPSIS
    Temporal validity helpers for time-scoped entity metadata.

    .DESCRIPTION
    Shared temporal utility functions extracted from get-entity.ps1 so they
    can be consumed by multiple subsystems without circular dot-source
    dependencies. Not auto-loaded by Robot.PowerShell.psm1 (non-Verb-Noun filename).

    Helpers:
    - ConvertFrom-ValidityString:   splits "Value (2025-02:)" into { Text, ValidFrom, ValidTo, Season }
    - Resolve-PartialDate:          expands partial dates (YYYY, YYYY-MM) to full datetime values
    - Resolve-SeasonForDate:        returns Polish season name for a given date
    - Test-TemporalActivity:        checks if an item falls within an -ActiveOn date window (date + season)
    - Get-NestedBulletText:         collects text from child bullets via LocalIndex-keyed
                                     ChildrenOf lookup, with temporal filtering
    - Get-LastActiveValue:          returns the last active entry from a history list (reverse scan)
    - Get-AllActiveValues:          returns all active entries from a history list as string[]
    - ConvertTo-SessionDate:        parses yyyy-MM-dd string into [datetime] or $null
    - ConvertFrom-CoordinateString: parses "X, Y" coordinate pair into @{ X; Y } or $null

    Module-level data:
    - $script:ValidityPattern:      precompiled regex for parsing validity range syntax "text (range)"
    - $script:SeasonKeywords:       HashSet of valid Polish season keywords (wiosna, lato, jesień, zima)
    - $script:DateRangePattern:     precompiled regex for detecting "start:end" date range components
    - $script:SessionDatePattern:   precompiled regex for YYYY-MM-DD with optional /DD range suffix
    - $script:AnnotationKeywords:   HashSet of non-temporal parenthetical keywords (teleport)
                                     parsed into the Annotation field instead of Season

    ConvertFrom-ValidityString is the central parser for entity @tag values.
    It returns a hashtable with Text, ValidFrom, ValidTo, Season, and Annotation fields.
    It handles five syntactic forms:
    1. Plain value: "Erathia" -> no temporal bounds
    2. Date range: "Erathia (2021-01:2024-06)" -> ValidFrom/ValidTo set
    3. Season only: "ithan-zima.png (zima)" -> Season set, no dates
    4. Annotation only: "Port (teleport)" -> Annotation set, no dates or season
    5. Combined: "Targowisko (2024-01:, lato)" -> both date range and season;
       "Port (teleport, 2023-06:)" -> annotation and date range
    Non-temporal parentheticals (no colon, not a season/annotation keyword)
    are treated as literal name parts for backward compatibility (e.g. "Rada (Ithan)").

    Test-TemporalActivity is the hot-path filter: it checks date bounds and
    season constraints. Season resolution is cached per date in script-scope
    variables ($script:CachedSeasonDate/$script:CachedSeasonResult) to avoid
    thousands of redundant Resolve-SeasonForDate calls when filtering a large
    entity list against a single -ActiveOn date.

    Get-LastActiveValue uses reverse-scan instead of .Where() filtering
    because history lists are ordered by ValidFrom ascending, so the last
    active entry (most recent) is found fastest from the end.

    Consumers: Get-Entity, Get-EntityState, Get-Session (via
    Resolve-IntelTargets), session-decomposehelpers.ps1, and reporting
    commands. All dot-source this file on demand.
#>

$script:ValidityPattern = [regex]::new('^(.*?)(?:\s*\(([^)]+)\))?$', [System.Text.RegularExpressions.RegexOptions]::Compiled)
$script:DateRangePattern = [regex]::new('^([^:]*):(.*)$', [System.Text.RegularExpressions.RegexOptions]::Compiled)
$script:SessionDatePattern = [regex]::new('\b(\d{4}-\d{2}-\d{2})(?:/(\d{2}))?\b', [System.Text.RegularExpressions.RegexOptions]::Compiled)
$script:SeasonKeywords = [System.Collections.Generic.HashSet[string]]::new(
    [string[]]@('wiosna', 'lato', 'jesień', 'zima'),
    [System.StringComparer]::OrdinalIgnoreCase)
$script:AnnotationKeywords = [System.Collections.Generic.HashSet[string]]::new(
    [string[]]@('teleport'),
    [System.StringComparer]::OrdinalIgnoreCase)

function ConvertFrom-ValidityString {
    param([string]$InputText)

    $Match = $script:ValidityPattern.Match($InputText.Trim())

    if (-not $Match.Success) {
        return @{ Text = $InputText.Trim(); ValidFrom = $null; ValidTo = $null; Season = $null; Annotation = $null }
    }

    $Name       = $Match.Groups[1].Value.Trim()
    $ParenGroup = $Match.Groups[2]

    if (-not $ParenGroup.Success) {
            return @{ Text = $Name; ValidFrom = $null; ValidTo = $null; Season = $null; Annotation = $null }
    }

    $ParenContent = $ParenGroup.Value.Trim()

    # Comma-separated: season/annotation + date range in any order (e.g. "2024-01:, lato" or "teleport, 2024-03:")
    if ($ParenContent.Contains(',')) {
        $Parts = $ParenContent.Split(',')
        $Season     = $null
        $Annotation = $null
        $DatePart   = $null

        foreach ($Part in $Parts) {
            $Trimmed = $Part.Trim()
            if ($script:SeasonKeywords.Contains($Trimmed)) {
                $Season = $Trimmed.ToLowerInvariant()
            } elseif ($script:AnnotationKeywords.Contains($Trimmed)) {
                $Annotation = $Trimmed.ToLowerInvariant()
            } else {
                $DatePart = $Trimmed
            }
        }

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
            Text       = $Name
            ValidFrom  = $ValidFrom
            ValidTo    = $ValidTo
            Season     = $Season
            Annotation = $Annotation
        }
    }

    if ($script:SeasonKeywords.Contains($ParenContent)) {
        return @{
            Text       = $Name
            ValidFrom  = $null
            ValidTo    = $null
            Season     = $ParenContent.ToLowerInvariant()
            Annotation = $null
        }
    }

    if ($script:AnnotationKeywords.Contains($ParenContent)) {
        return @{
            Text       = $Name
            ValidFrom  = $null
            ValidTo    = $null
            Season     = $null
            Annotation = $ParenContent.ToLowerInvariant()
        }
    }

    $DateMatch = $script:DateRangePattern.Match($ParenContent)
    if ($DateMatch.Success) {
        $ValidFrom = Resolve-PartialDate -DateStr $DateMatch.Groups[1].Value.Trim() -IsEnd $false
        $ValidTo   = Resolve-PartialDate -DateStr $DateMatch.Groups[2].Value.Trim() -IsEnd $true
        return @{
            Text       = $Name
            ValidFrom  = $ValidFrom
            ValidTo    = $ValidTo
            Season     = $null
            Annotation = $null
        }
    }

    # Non-temporal parenthetical: literal name part (e.g. "Rada (Ithan)")
    return @{
        Text       = "$Name ($ParenContent)"
        ValidFrom  = $null
        ValidTo    = $null
        Season     = $null
        Annotation = $null
    }
}

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

function Resolve-SeasonForDate {
    param(
        [Parameter(Mandatory)]
        [datetime]$Date
    )

    # Custom mapping from local.config.psd1 overrides meteorological defaults
    if ($script:CachedSeasonMapping) {
        foreach ($Entry in $script:CachedSeasonMapping.GetEnumerator()) {
            $Months = $Entry.Value
            if ($Months -contains $Date.Month) {
                return $Entry.Key
            }
        }
    }

    switch ($Date.Month) {
        { $_ -ge 3 -and $_ -le 5 }  { return 'wiosna' }
        { $_ -ge 6 -and $_ -le 8 }  { return 'lato' }
        { $_ -ge 9 -and $_ -le 11 } { return 'jesień' }
        default                       { return 'zima' }
    }
}

function Test-TemporalActivity {
    param(
        [object]$Item,
        [AllowNull()][Nullable[datetime]]$ActiveOn
    )

    if ($null -eq $ActiveOn)                                  { return $true }
    if ($Item.ValidFrom -and $ActiveOn -lt $Item.ValidFrom)   { return $false }
    if ($Item.ValidTo   -and $ActiveOn -gt $Item.ValidTo)     { return $false }

    # Per-date season cache avoids redundant Resolve-SeasonForDate calls across large entity lists
    if ($Item.Season) {
        if ($script:CachedSeasonDate -ne $ActiveOn) {
            $script:CachedSeasonDate   = $ActiveOn
            $script:CachedSeasonResult = Resolve-SeasonForDate -Date $ActiveOn
        }
        if (-not [string]::Equals($Item.Season, $script:CachedSeasonResult, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $false
        }
    }

    return $true
}

function Get-NestedBulletText {
    param(
        [object]$ParentBullet,
        [hashtable]$ChildrenOf,
        [AllowNull()][Nullable[datetime]]$ActiveOn
    )

    $ParentIdx = $ParentBullet.LocalIndex
    if (-not $ChildrenOf.ContainsKey($ParentIdx)) { return $null }
    $Children = $ChildrenOf[$ParentIdx]
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

function Get-LastActiveValue {
    param(
        [System.Collections.Generic.List[object]]$History,
        [string]$PropertyName,
        [AllowNull()][Nullable[datetime]]$ActiveOn
    )

    if ($History.Count -eq 0) { return $null }

    # Reverse scan: history is ValidFrom-ascending, so most recent active entry is near the end
    for ($i = $History.Count - 1; $i -ge 0; $i--) {
        if (Test-TemporalActivity -Item $History[$i] -ActiveOn $ActiveOn) {
            return $History[$i].$PropertyName
        }
    }
    return $null
}

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

function ConvertTo-SessionDate {
    param([Parameter(Mandatory)] [string]$DateString)

    [datetime]$Parsed = [datetime]::MinValue
    if ([datetime]::TryParseExact($DateString, 'yyyy-MM-dd',
            [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::None,
            [ref]$Parsed)) {
        return $Parsed
    }
    return $null
}

function ConvertFrom-CoordinateString {
    param([Parameter(Mandatory)] [string]$Text)

    $Parts = $Text.Split(',')
    if ($Parts.Length -ge 2) {
        [int]$X = 0
        [int]$Y = 0
        if ([int]::TryParse($Parts[0].Trim(), [ref]$X) -and [int]::TryParse($Parts[1].Trim(), [ref]$Y)) {
            return @{ X = $X; Y = $Y }
        }
    }
    return $null
}
