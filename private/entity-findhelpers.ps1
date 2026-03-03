<#
    .SYNOPSIS
    Entity file find helpers - locate sections, bullets, and tags in entity
    files (entities.md and *-NNN-ent.md).

    .DESCRIPTION
    Non-exported helper functions that provide read-only line-scanning
    primitives for entity files. Consumed by entity-writehelpers.ps1
    (via dot-source) and transitively by all entity CRUD commands.

    Contains:
    - Find-EntitySection:  locates ## Type section boundaries in file lines
    - Find-EntityBullet:   locates * EntityName bullet and its children range
    - Find-EntityTag:      locates - @tag: line within an entity's children

    Also defines script-scope precompiled regex patterns and type-mapping
    hashtables used by both find and write helpers:
    - $script:SectionHeaderPattern
    - $script:EntityBulletPattern
    - $script:TagPattern
    - $script:EntityTypeMap
    - $script:TypeToHeader

    All functions operate on raw line arrays (same approach as Set-Session).
    Parse boundaries by scanning lines, return hashtables with index ranges.
#>

# Precompiled patterns
$script:SectionHeaderPattern = [regex]::new('^##\s+(.+)$', [System.Text.RegularExpressions.RegexOptions]::Compiled)
$script:EntityBulletPattern  = [regex]::new('^\*\s+(.+)$', [System.Text.RegularExpressions.RegexOptions]::Compiled)
$script:TagPattern           = [regex]::new('^\s+[-\*]\s+@([^:]+):\s*(.*)', [System.Text.RegularExpressions.RegexOptions]::Compiled)

# Section header -> entity type normalization (same map as Get-Entity)
$script:EntityTypeMap = @{
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
}

# Reverse map: canonical type -> preferred section header text
$script:TypeToHeader = @{
    "NPC"              = "NPC"
    "Grupa"            = "Grupa"
    "Lokacja"          = "Lokacja"
    "Gracz"            = "Gracz"
    "Postać"           = "Postać"
    "Przedmiot"        = "Przedmiot"
}

# Helper: find a ## Type section in file lines
# Returns hashtable with HeaderIdx, StartIdx (first content line), EndIdx (exclusive),
# HeaderText, and EntityType. Returns $null if not found.
function Find-EntitySection {
    param(
        [string[]]$Lines,
        [string]$EntityType
    )

    for ($i = 0; $i -lt $Lines.Count; $i++) {
        $Match = $script:SectionHeaderPattern.Match($Lines[$i])
        if (-not $Match.Success) { continue }

        $HeaderText = $Match.Groups[1].Value.Trim()
        $Normalized = $script:EntityTypeMap[$HeaderText.ToLowerInvariant()]
        if (-not $Normalized) { continue }

        if (-not [string]::Equals($Normalized, $EntityType, [System.StringComparison]::OrdinalIgnoreCase)) { continue }

        # Find section end (next ## header or EOF)
        $EndIdx = $Lines.Count
        for ($j = $i + 1; $j -lt $Lines.Count; $j++) {
            if ($script:SectionHeaderPattern.IsMatch($Lines[$j])) {
                $EndIdx = $j
                break
            }
        }

        return @{
            HeaderIdx  = $i
            StartIdx   = $i + 1
            EndIdx     = $EndIdx
            HeaderText = $HeaderText
            EntityType = $Normalized
        }
    }

    return $null
}

# Helper: find a top-level * EntityName bullet within a section range
# Returns hashtable with BulletIdx, ChildrenStartIdx, ChildrenEndIdx (exclusive),
# EntityName. Returns $null if not found.
function Find-EntityBullet {
    param(
        [string[]]$Lines,
        [int]$SectionStart,
        [int]$SectionEnd,
        [string]$EntityName
    )

    for ($i = $SectionStart; $i -lt $SectionEnd; $i++) {
        $Match = $script:EntityBulletPattern.Match($Lines[$i])
        if (-not $Match.Success) { continue }

        $BulletName = $Match.Groups[1].Value.Trim()
        if (-not [string]::Equals($BulletName, $EntityName, [System.StringComparison]::OrdinalIgnoreCase)) { continue }

        # Children are indented lines following the bullet until next top-level bullet or blank line group
        $ChildEnd = $i + 1
        for ($j = $i + 1; $j -lt $SectionEnd; $j++) {
            $Line = $Lines[$j]
            # Next top-level bullet -> end of children
            if ($script:EntityBulletPattern.IsMatch($Line)) {
                $ChildEnd = $j
                break
            }
            # A non-indented, non-blank line that isn't a bullet -> also end
            if ($Line.Length -gt 0 -and $Line[0] -ne ' ' -and $Line[0] -ne "`t" -and -not [string]::IsNullOrWhiteSpace($Line)) {
                $ChildEnd = $j
                break
            }
            $ChildEnd = $j + 1
        }

        # Trim trailing blank lines from children range
        while ($ChildEnd -gt $i + 1 -and [string]::IsNullOrWhiteSpace($Lines[$ChildEnd - 1])) {
            $ChildEnd--
        }

        return @{
            BulletIdx        = $i
            ChildrenStartIdx = $i + 1
            ChildrenEndIdx   = $ChildEnd
            EntityName       = $BulletName
        }
    }

    return $null
}

# Helper: find a - @tag: line within an entity's children range
# Returns hashtable with TagIdx, Tag, Value. Returns $null if not found.
# If multiple occurrences exist, returns the last one (for update semantics).
function Find-EntityTag {
    param(
        [string[]]$Lines,
        [int]$ChildrenStart,
        [int]$ChildrenEnd,
        [string]$TagName
    )

    $LastMatch = $null
    $NormalizedTag = $TagName.ToLowerInvariant()
    if ($NormalizedTag.StartsWith('@')) { $NormalizedTag = $NormalizedTag.Substring(1) }

    for ($i = $ChildrenStart; $i -lt $ChildrenEnd; $i++) {
        $Match = $script:TagPattern.Match($Lines[$i])
        if (-not $Match.Success) { continue }

        $FoundTag = $Match.Groups[1].Value.Trim().ToLowerInvariant()
        if ($FoundTag -eq $NormalizedTag) {
            $LastMatch = @{
                TagIdx = $i
                Tag    = $FoundTag
                Value  = $Match.Groups[2].Value.Trim()
            }
        }
    }

    return $LastMatch
}
