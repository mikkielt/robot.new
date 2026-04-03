<#
    .SYNOPSIS
    Entity file find helpers -- locate sections, bullets, and tags in entity
    files (entities.md and *-NNN-ent.md).

    .DESCRIPTION
    Non-exported helper functions that provide read-only line-scanning
    primitives for entity files. Consumed by entity-writehelpers.ps1
    (via dot-source) and transitively by all entity CRUD commands.

    Helpers:
    - Find-EntitySection:  locates ## Type section boundaries in file lines
    - Find-EntityBullet:   locates * EntityName bullet and its children range
    - Find-EntityTag:      locates - @tag: line within an entity's children (returns last match for update semantics)

    Module-level data:
    - $script:SectionHeaderPattern: precompiled regex matching "## SectionName" headers
    - $script:EntityBulletPattern:  precompiled regex matching "* EntityName" top-level bullets
    - $script:TagPattern:           precompiled regex matching indented "- @tag: value" lines
    - $script:EntityTypeMap:        Polish section header -> canonical entity type normalization (handles singular/plural)
    - $script:TypeToHeader:         reverse map: canonical type -> preferred section header text

    All three functions operate on raw string[] line arrays (same approach
    as Set-Session) and return hashtables with boundary indices:

    - Find-EntitySection scans for "## Header" lines, normalizes the header
      text through EntityTypeMap, and returns HeaderIdx/StartIdx/EndIdx
      (exclusive) bounding the section. EndIdx is the next ## header or EOF.

    - Find-EntityBullet scans within a section range for "* Name" lines,
      compares case-insensitively, and determines children range by walking
      forward until the next top-level bullet or non-indented content.
      Trailing blank lines are trimmed from the children range.

    - Find-EntityTag scans within a children range for "- @tag:" lines.
      When multiple occurrences exist (e.g. multiple @lokacja entries),
      it returns the last match so callers get update-in-place semantics
      for scalar tags.
#>

$script:SectionHeaderPattern = [regex]::new('^##\s+(.+)$', [System.Text.RegularExpressions.RegexOptions]::Compiled)
$script:EntityBulletPattern  = [regex]::new('^\*\s+(.+)$', [System.Text.RegularExpressions.RegexOptions]::Compiled)
$script:TagPattern           = [regex]::new('^\s+[-\*]\s+@([^:]+):\s*(.*)', [System.Text.RegularExpressions.RegexOptions]::Compiled)

# Canonical section header -> entity type normalization map.
# Consumed by Get-Entity (section dispatch) and Find-EntitySection (type matching).
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
    "mapa"             = "Mapa"
    "mapy"             = "Mapa"
}

$script:TypeToHeader = @{
    "NPC"              = "NPC"
    "Grupa"            = "Grupa"
    "Lokacja"          = "Lokacja"
    "Gracz"            = "Gracz"
    "Postać"           = "Postać"
    "Przedmiot"        = "Przedmiot"
    "Mapa"             = "Mapa"
}

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

        # Walk forward to find children boundary: indented lines until next bullet or unindented content
        $ChildEnd = $i + 1
        for ($j = $i + 1; $j -lt $SectionEnd; $j++) {
            $Line = $Lines[$j]
            if ($script:EntityBulletPattern.IsMatch($Line)) {
                $ChildEnd = $j
                break
            }
            if ($Line.Length -gt 0 -and $Line[0] -ne ' ' -and $Line[0] -ne "`t" -and -not [string]::IsNullOrWhiteSpace($Line)) {
                $ChildEnd = $j
                break
            }
            $ChildEnd = $j + 1
        }

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
