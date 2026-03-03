<#
    .SYNOPSIS
    Entity file writing helpers - append, update, and create entity
    entries in entities.md and *-NNN-ent.md files.

    .DESCRIPTION
    Non-exported helper functions consumed by Set-Player, Set-PlayerCharacter,
    and New-PlayerCharacter via dot-sourcing. Not auto-loaded by robot.psm1
    (non-Verb-Noun filename).

    Contains:
    - Set-EntityTag:                  adds or updates a @tag: value under an entity
    - New-EntityBullet:               creates a new * EntityName entry with optional tags
    - ConvertFrom-EntityTemplate:     parses a rendered entity template into name + tags
    - Invoke-EnsureEntityFile:        ensures entities.md exists with required sections
    - Write-EntityFile:               writes updated lines to file (UTF-8 no BOM)
    - Read-EntityFile:                reads entity file into lines and detects newline style
    - Resolve-EntityTarget:           ensures entity exists, creating section/bullet as needed

    Find helpers (Find-EntitySection, Find-EntityBullet, Find-EntityTag) and
    script-scope patterns/maps are in entity-findhelpers.ps1 (dot-sourced below).

    Migration helper (ConvertTo-EntitiesFromPlayers) is in
    entity-migrationhelpers.ps1, dot-sourced separately by phase1-bootstrap.ps1.

    All functions operate on raw line arrays (same approach as Set-Session).
    Parse boundaries by scanning lines, manipulate via List[string], write
    with [System.IO.File]::WriteAllText.
#>

# Load find helpers (patterns, type maps, Find-EntitySection/Bullet/Tag)
. "$PSScriptRoot/entity-findhelpers.ps1"

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
        $Path = [System.IO.Path]::Combine((Get-RepoRoot), '.robot.new', 'entities.md')
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
# Invokes BeforeWrite/AfterWrite plugin hooks when the plugin system is loaded.
function Write-EntityFile {
    param(
        [string]$Path,
        [System.Collections.Generic.List[string]]$Lines,
        [string]$NL = "`n"
    )

    $HasHooks = Get-Command 'Invoke-PluginHook' -ErrorAction SilentlyContinue

    if ($HasHooks) {
        Invoke-PluginHook -Operation 'Write-EntityFile' -Phase 'BeforeWrite' -Context @{
            Operation = 'Write-EntityFile'
            Path      = $Path
            Lines     = $Lines
            NL        = $NL
        }
    }

    $Content = [string]::Join($NL, $Lines)
    $UTF8NoBOM = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($Path, $Content, $UTF8NoBOM)

    if ($HasHooks) {
        Invoke-PluginHook -Operation 'Write-EntityFile' -Phase 'AfterWrite' -Context @{
            Operation = 'Write-EntityFile'
            Path      = $Path
            Lines     = $Lines
            NL        = $NL
        }
    }
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
