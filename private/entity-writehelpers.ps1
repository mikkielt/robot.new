<#
    .SYNOPSIS
    Entity file writing helpers - locate, append, update, and create entity
    entries in entities.md and *-NNN-ent.md files.

    .DESCRIPTION
    Non-exported helper functions consumed by Set-Player, Set-PlayerCharacter,
    and New-PlayerCharacter via dot-sourcing. Not auto-loaded by robot.psm1
    (non-Verb-Noun filename).

    Contains:
    - Find-EntitySection:             locates ## Type section boundaries in file lines
    - Find-EntityBullet:              locates * EntityName bullet and its children range
    - Find-EntityTag:                 locates - @tag: line within an entity's children
    - Set-EntityTag:                  adds or updates a @tag: value under an entity
    - New-EntityBullet:               creates a new * EntityName entry with optional tags
    - ConvertFrom-EntityTemplate:     parses a rendered entity template into name + tags
    - Invoke-EnsureEntityFile:        ensures entities.md exists with required sections
    - Write-EntityFile:               writes updated lines to file (UTF-8 no BOM)
    - ConvertTo-EntitiesFromPlayers:  bootstraps entities.md from Gracze.md data

    All functions operate on raw line arrays (same approach as Set-Session).
    Parse boundaries by scanning lines, manipulate via List[string], write
    with [System.IO.File]::WriteAllText.
#>

# Precompiled patterns
$script:SectionHeaderPattern = [regex]::new('^##\s+(.+)$', [System.Text.RegularExpressions.RegexOptions]::Compiled)
$script:EntityBulletPattern  = [regex]::new('^\*\s+(.+)$', [System.Text.RegularExpressions.RegexOptions]::Compiled)
$script:TagPattern           = [regex]::new('^\s+[-\*]\s+@([^:]+):\s*(.*)', [System.Text.RegularExpressions.RegexOptions]::Compiled)

# Section header -> entity type normalization (same map as Get-Entity)
$script:EntityTypeMap = @{
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

# Reverse map: canonical type -> preferred section header text
$script:TypeToHeader = @{
    "NPC"              = "NPC"
    "Organizacja"      = "Organizacja"
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

# Helper: add or update a @tag: value line under an entity
# Operates on a List[string] of file lines, modifying in-place.
# Returns the updated children end index.
function Set-EntityTag {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Internal helper modifying in-memory List[string], not system state')]
    param(
        [System.Collections.Generic.List[string]]$Lines,
        [int]$ChildrenStart,
        [int]$ChildrenEnd,
        [string]$TagName,
        [string]$Value
    )

    $NormalizedTag = $TagName.ToLowerInvariant()
    if ($NormalizedTag.StartsWith('@')) { $NormalizedTag = $NormalizedTag.Substring(1) }

    $TagLine = "    - @${NormalizedTag}: $Value"
    $Existing = Find-EntityTag -Lines $Lines.ToArray() -ChildrenStart $ChildrenStart -ChildrenEnd $ChildrenEnd -TagName $NormalizedTag

    if ($Existing) {
        # Update existing tag (replace the line)
        $Lines[$Existing.TagIdx] = $TagLine
        return $ChildrenEnd
    } else {
        # Append new tag at end of children
        $Lines.Insert($ChildrenEnd, $TagLine)
        return $ChildrenEnd + 1
    }
}

# Helper: create a new * EntityName entry with optional @tag children
# Inserts at the end of the section (before section end).
# Returns the new children end index.
function New-EntityBullet {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Internal helper modifying in-memory List[string], not system state')]
    param(
        [System.Collections.Generic.List[string]]$Lines,
        [int]$SectionEnd,
        [string]$EntityName,
        [hashtable]$Tags = @{}
    )

    $InsertIdx = $SectionEnd

    # Ensure a blank line before the new entity if the previous line isn't blank
    if ($InsertIdx -gt 0 -and -not [string]::IsNullOrWhiteSpace($Lines[$InsertIdx - 1])) {
        $Lines.Insert($InsertIdx, '')
        $InsertIdx++
    }

    $Lines.Insert($InsertIdx, "* $EntityName")
    $InsertIdx++

    # Add tags in deterministic order
    $SortedKeys = [System.Collections.Generic.List[string]]::new()
    foreach ($K in $Tags.Keys) { $SortedKeys.Add($K) }
    $SortedKeys.Sort()
    foreach ($Key in $SortedKeys) {
        $TagValues = $Tags[$Key]
        # Support both single value and array of values
        if ($TagValues -is [System.Collections.IEnumerable] -and $TagValues -isnot [string]) {
            foreach ($Val in $TagValues) {
                $Lines.Insert($InsertIdx, "    - @${Key}: $Val")
                $InsertIdx++
            }
        } else {
            $Lines.Insert($InsertIdx, "    - @${Key}: $TagValues")
            $InsertIdx++
        }
    }

    return $InsertIdx
}

# Parses a rendered entity template string into entity name and tag hashtable.
# Template format: first line is "* EntityName", subsequent lines are "    - @tag: value".
# Returns @{ Name = string; Tags = [ordered]hashtable }.
function ConvertFrom-EntityTemplate {
    param(
        [Parameter(Mandatory, HelpMessage = "Rendered template content")]
        [string]$Content
    )

    $Lines = $Content.Split([string[]]@("`r`n", "`n"), [System.StringSplitOptions]::RemoveEmptyEntries)
    $EntityName = $null
    $Tags = [ordered]@{}

    foreach ($Line in $Lines) {
        $BulletMatch = $script:EntityBulletPattern.Match($Line)
        if ($BulletMatch.Success -and -not $EntityName) {
            $EntityName = $BulletMatch.Groups[1].Value.Trim()
            continue
        }

        $TagMatch = $script:TagPattern.Match($Line)
        if ($TagMatch.Success) {
            $TagName = $TagMatch.Groups[1].Value.Trim()
            $TagValue = $TagMatch.Groups[2].Value.Trim()
            # Support multiple values for the same tag
            if ($Tags.Contains($TagName)) {
                $Existing = $Tags[$TagName]
                if ($Existing -is [System.Collections.Generic.List[string]]) {
                    [void]$Existing.Add($TagValue)
                } else {
                    $NewList = [System.Collections.Generic.List[string]]::new()
                    [void]$NewList.Add($Existing)
                    [void]$NewList.Add($TagValue)
                    $Tags[$TagName] = $NewList
                }
            } else {
                $Tags[$TagName] = $TagValue
            }
        }
    }

    return @{
        Name = $EntityName
        Tags = $Tags
    }
}

# Helper: ensures entities.md exists with required type sections.
# Loads the skeleton from entities-skeleton.md.template when creating a new file.
# Returns the file path.
function Invoke-EnsureEntityFile {
    param(
        [Parameter(HelpMessage = "Path to entities.md")]
        [string]$Path
    )

    if (-not $Path) {
        $Path = [System.IO.Path]::Combine($PSScriptRoot, 'entities.md')
    }

    if (-not [System.IO.File]::Exists($Path)) {
        # Load admin-config helpers if not already available
        if (-not (Get-Command 'Get-AdminTemplate' -ErrorAction SilentlyContinue)) {
            . "$PSScriptRoot/admin-config.ps1"
        }

        $Content = Get-AdminTemplate -Name 'entities-skeleton.md.template'

        $UTF8NoBOM = [System.Text.UTF8Encoding]::new($false)
        [System.IO.File]::WriteAllText($Path, $Content, $UTF8NoBOM)
    }

    return $Path
}

# Helper: write updated lines to file (UTF-8 no BOM, preserve newline style)
function Write-EntityFile {
    param(
        [string]$Path,
        [System.Collections.Generic.List[string]]$Lines,
        [string]$NL = "`n"
    )

    $Content = [string]::Join($NL, $Lines)
    $UTF8NoBOM = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($Path, $Content, $UTF8NoBOM)
}

# Helper: read entity file into lines and detect newline style
# Returns hashtable with Lines (List[string]) and NL (newline string)
function Read-EntityFile {
    param([string]$Path)

    $UTF8NoBOM = [System.Text.UTF8Encoding]::new($false)
    $RawContent = [System.IO.File]::ReadAllText($Path, $UTF8NoBOM)
    $NL = if ($RawContent.Contains("`r`n")) { "`r`n" } else { "`n" }
    $LineArray = $RawContent.Split([string[]]@("`r`n", "`n"), [System.StringSplitOptions]::None)
    $Lines = [System.Collections.Generic.List[string]]::new($LineArray)

    return @{
        Lines = $Lines
        NL    = $NL
    }
}

# High-level: ensure an entity exists in the file, creating section/bullet as needed.
# Returns hashtable with Lines (List[string]), NL, BulletIdx, ChildrenStart, ChildrenEnd, FilePath, Created (bool)
function Resolve-EntityTarget {
    param(
        [string]$FilePath,
        [string]$EntityType,
        [string]$EntityName,
        [hashtable]$InitialTags = @{}
    )

    $FilePath = Invoke-EnsureEntityFile -Path $FilePath
    $File = Read-EntityFile -Path $FilePath
    $Lines = $File.Lines
    $NL = $File.NL
    $Created = $false

    # Find or create section
    $Section = Find-EntitySection -Lines $Lines.ToArray() -EntityType $EntityType
    if (-not $Section) {
        # Add section at end of file
        $HeaderText = $script:TypeToHeader[$EntityType]
        if (-not $HeaderText) { $HeaderText = $EntityType }

        # Ensure trailing newline before new section
        if ($Lines.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace($Lines[$Lines.Count - 1])) {
            $Lines.Add('')
        }
        $Lines.Add("## $HeaderText")
        $Lines.Add('')

        $Section = Find-EntitySection -Lines $Lines.ToArray() -EntityType $EntityType
    }

    # Find or create entity bullet
    $Bullet = Find-EntityBullet -Lines $Lines.ToArray() -SectionStart $Section.StartIdx -SectionEnd $Section.EndIdx -EntityName $EntityName
    if (-not $Bullet) {
        $null = New-EntityBullet -Lines $Lines -SectionEnd $Section.EndIdx -EntityName $EntityName -Tags $InitialTags
        $Created = $true

        # Re-find after insertion
        $Section = Find-EntitySection -Lines $Lines.ToArray() -EntityType $EntityType
        $Bullet = Find-EntityBullet -Lines $Lines.ToArray() -SectionStart $Section.StartIdx -SectionEnd $Section.EndIdx -EntityName $EntityName
    }

    return @{
        Lines         = $Lines
        NL            = $NL
        BulletIdx     = $Bullet.BulletIdx
        ChildrenStart = $Bullet.ChildrenStartIdx
        ChildrenEnd   = $Bullet.ChildrenEndIdx
        FilePath      = $FilePath
        Created       = $Created
    }
}

# Bootstraps entities.md from Gracze.md player data.
# Reads Get-Player output and generates entity entries for all players
# and their characters in the entities.md format.
function ConvertTo-EntitiesFromPlayers {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '',
        Justification = 'Plural noun is intentional - converts multiple entities from multiple players')]
    param(
        [Parameter(HelpMessage = "Path to output entities.md file")]
        [string]$OutputPath,

        [Parameter(HelpMessage = "Pre-fetched player list from Get-Player")]
        [object[]]$Players
    )

    if (-not $OutputPath) {
        $OutputPath = [System.IO.Path]::Combine($PSScriptRoot, 'entities.md')
    }

    if (-not $Players) {
        $Players = Get-Player -Entities @()
    }

    $SB = [System.Text.StringBuilder]::new(4096)

    # Gracz section
    [void]$SB.Append("## Gracz")
    [void]$SB.Append("`n")

    foreach ($Player in $Players) {
        if ([string]::IsNullOrWhiteSpace($Player.Name)) { continue }

        [void]$SB.Append("`n")
        [void]$SB.Append("* $($Player.Name)")
        [void]$SB.Append("`n")

        if (-not [string]::IsNullOrWhiteSpace($Player.MargonemID)) {
            [void]$SB.Append("    - @margonemid: $($Player.MargonemID)")
            [void]$SB.Append("`n")
        }

        if (-not [string]::IsNullOrWhiteSpace($Player.PRFWebhook)) {
            [void]$SB.Append("    - @prfwebhook: $($Player.PRFWebhook)")
            [void]$SB.Append("`n")
        }

        if ($Player.Triggers -and $Player.Triggers.Count -gt 0) {
            foreach ($Trigger in $Player.Triggers) {
                if (-not [string]::IsNullOrWhiteSpace($Trigger)) {
                    [void]$SB.Append("    - @trigger: $($Trigger.Trim())")
                    [void]$SB.Append("`n")
                }
            }
        }
    }

    # Postać section
    [void]$SB.Append("`n")
    [void]$SB.Append("## Postać")
    [void]$SB.Append("`n")

    foreach ($Player in $Players) {
        foreach ($Character in $Player.Characters) {
            [void]$SB.Append("`n")
            [void]$SB.Append("* $($Character.Name)")
            [void]$SB.Append("`n")
            [void]$SB.Append("    - @należy_do: $($Player.Name)")
            [void]$SB.Append("`n")

            if ($Character.Aliases -and $Character.Aliases.Count -gt 0) {
                foreach ($Alias in $Character.Aliases) {
                    if (-not [string]::IsNullOrWhiteSpace($Alias)) {
                        [void]$SB.Append("    - @alias: $Alias")
                        [void]$SB.Append("`n")
                    }
                }
            }

            if ($null -ne $Character.PUStart) {
                $Val = ([decimal]$Character.PUStart).ToString('G', [System.Globalization.CultureInfo]::InvariantCulture)
                [void]$SB.Append("    - @pu_startowe: $Val")
                [void]$SB.Append("`n")
            }

            if ($null -ne $Character.PUExceeded -and $Character.PUExceeded -ne 0) {
                $Val = ([decimal]$Character.PUExceeded).ToString('G', [System.Globalization.CultureInfo]::InvariantCulture)
                [void]$SB.Append("    - @pu_nadmiar: $Val")
                [void]$SB.Append("`n")
            }

            if ($null -ne $Character.PUSum) {
                $Val = ([decimal]$Character.PUSum).ToString('G', [System.Globalization.CultureInfo]::InvariantCulture)
                [void]$SB.Append("    - @pu_suma: $Val")
                [void]$SB.Append("`n")
            }

            if ($null -ne $Character.PUTaken) {
                $Val = ([decimal]$Character.PUTaken).ToString('G', [System.Globalization.CultureInfo]::InvariantCulture)
                [void]$SB.Append("    - @pu_zdobyte: $Val")
                [void]$SB.Append("`n")
            }

            if ($Character.AdditionalInfo) {
                $InfoParts = if ($Character.AdditionalInfo -is [System.Collections.IEnumerable] -and $Character.AdditionalInfo -isnot [string]) {
                    $Character.AdditionalInfo
                } else {
                    @($Character.AdditionalInfo)
                }
                foreach ($Info in $InfoParts) {
                    if (-not [string]::IsNullOrWhiteSpace($Info)) {
                        [void]$SB.Append("    - @info: $($Info.Trim())")
                        [void]$SB.Append("`n")
                    }
                }
            }
        }
    }

    $UTF8NoBOM = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($OutputPath, $SB.ToString(), $UTF8NoBOM)

    return $OutputPath
}
