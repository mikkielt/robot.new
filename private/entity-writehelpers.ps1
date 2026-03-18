<#
    .SYNOPSIS
    Entity file writing helpers -- append, update, and create entity
    entries in entities.md and *-NNN-ent.md files.

    .DESCRIPTION
    Non-exported helper functions consumed by Set-Player, Set-PlayerCharacter,
    and New-PlayerCharacter via dot-sourcing. Not auto-loaded by Robot.PowerShell.psm1
    (non-Verb-Noun filename).

    Helpers:
    - Set-EntityTag:              adds or updates a @tag: value under an entity bullet
    - New-EntityBullet:           creates a new * EntityName entry with optional tags
    - ConvertFrom-EntityTemplate: parses a rendered entity template into name + tags
    - Invoke-EnsureEntityFile:    ensures entities.md exists with required sections
    - Write-EntityFile:           writes updated lines to file (UTF-8 no BOM, plugin hooks)
    - Read-EntityFile:            reads entity file into lines and detects newline style
    - Resolve-EntityTarget:       ensures entity exists, creating section/bullet as needed
    - Set-SessionGraphStale:      flags Tier 2 session graph as stale after entity mutations

    Module-level data:
    - $script:HasOpCtx: whether operation-context helpers (Add-OperationChange etc.) are available

    Find helpers (Find-EntitySection, Find-EntityBullet, Find-EntityTag) and
    script-scope patterns/maps are in entity-findhelpers.ps1 (dot-sourced at
    the top of this file). Migration helper (ConvertTo-EntitiesFromPlayers)
    is in entity-migrationhelpers.ps1, dot-sourced separately by phase0-setup.ps1.

    All functions operate on in-memory List[string] line arrays (same approach
    as Set-Session). The read-modify-write pipeline is:
    1. Read-EntityFile loads file into List[string] + detects NL style
    2. Find-* helpers locate boundaries by index scanning
    3. Set-EntityTag / New-EntityBullet modify the list via Insert/indexer
    4. Write-EntityFile joins with the detected NL and writes UTF-8 no BOM

    Set-EntityTag records property changes through operation-context when
    available ($script:HasOpCtx). Write-EntityFile fires BeforeWrite/AfterWrite
    plugin hooks and registers the path via Add-OperationFile.

    Resolve-EntityTarget orchestrates the full "ensure entity exists" workflow:
    it creates the file (via Invoke-EnsureEntityFile), creates the section
    (appends ## Header at EOF), and creates the bullet (via New-EntityBullet)
    as needed, re-scanning after each insertion to get updated indices.

    Set-SessionGraphStale is a best-effort helper called after entity mutations
    that affect session graph resolution (e.g. location or group changes). It
    invalidates parse caches via Clear-ParseCaches before attempting to set
    Tier2Stale in _meta.json — cache clearing is positioned before the try block
    to guarantee invalidation even if session graph staleness tracking fails
    (F10: cache must never serve stale data after an entity mutation). It loads
    session-graphhelpers.ps1 on demand for the graph metadata update.
#>

. "$PSScriptRoot/entity-findhelpers.ps1"

# Operation context is optional; allows tracking changes without hard dependency
$OpCtxPath = [System.IO.Path]::Combine($PSScriptRoot, 'operation-context.ps1')
if ([System.IO.File]::Exists($OpCtxPath)) { . $OpCtxPath }
$script:HasOpCtx = $null -ne (Get-Command 'Add-OperationChange' -ErrorAction SilentlyContinue)

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

    if ($script:HasOpCtx) {
        Add-OperationChange -Property "@$NormalizedTag" `
            -OldValue $(if ($Existing) { $Existing.Value } else { $null }) `
            -NewValue $Value
    }

    if ($Existing) {
        $Lines[$Existing.TagIdx] = $TagLine
        return $ChildrenEnd
    } else {
        $Lines.Insert($ChildrenEnd, $TagLine)
        return $ChildrenEnd + 1
    }
}

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

    # Maintain blank-line separation between entity bullets
    if ($InsertIdx -gt 0 -and -not [string]::IsNullOrWhiteSpace($Lines[$InsertIdx - 1])) {
        $Lines.Insert($InsertIdx, '')
        $InsertIdx++
    }

    $Lines.Insert($InsertIdx, "* $EntityName")
    $InsertIdx++

    # Deterministic tag order for reproducible diffs
    $SortedKeys = [System.Collections.Generic.List[string]]::new()
    foreach ($K in $Tags.Keys) { $SortedKeys.Add($K) }
    $SortedKeys.Sort()
    foreach ($Key in $SortedKeys) {
        $TagValues = $Tags[$Key]
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
            # Multi-valued tags (e.g. multiple @alias) promote to List[string]
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

function Invoke-EnsureEntityFile {
    param(
        [Parameter(HelpMessage = "Path to entities.md")]
        [string]$Path
    )

    if (-not $Path) {
        $Path = (Get-AdminConfig).EntitiesFile
    }

    if (-not [System.IO.File]::Exists($Path)) {
        if (-not (Get-Command 'Get-AdminTemplate' -ErrorAction SilentlyContinue)) {
            . "$PSScriptRoot/admin-config.ps1"
        }

        $Content = Get-AdminTemplate -Name 'entities-skeleton.md.template'

        $UTF8NoBOM = [System.Text.UTF8Encoding]::new($false)
        [System.IO.File]::WriteAllText($Path, $Content, $UTF8NoBOM)
    }

    return $Path
}

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

    if ($script:HasOpCtx) { Add-OperationFile -Path $Path }

    if ($HasHooks) {
        Invoke-PluginHook -Operation 'Write-EntityFile' -Phase 'AfterWrite' -Context @{
            Operation = 'Write-EntityFile'
            Path      = $Path
            Lines     = $Lines
            NL        = $NL
        }
    }
}

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

    $Section = Find-EntitySection -Lines $Lines.ToArray() -EntityType $EntityType
    if (-not $Section) {
        $HeaderText = $script:TypeToHeader[$EntityType]
        if (-not $HeaderText) { $HeaderText = $EntityType }

        if ($Lines.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace($Lines[$Lines.Count - 1])) {
            $Lines.Add('')
        }
        $Lines.Add("## $HeaderText")
        $Lines.Add('')

        $Section = Find-EntitySection -Lines $Lines.ToArray() -EntityType $EntityType
    }

    $Bullet = Find-EntityBullet -Lines $Lines.ToArray() -SectionStart $Section.StartIdx -SectionEnd $Section.EndIdx -EntityName $EntityName
    if (-not $Bullet) {
        $null = New-EntityBullet -Lines $Lines -SectionEnd $Section.EndIdx -EntityName $EntityName -Tags $InitialTags
        $Created = $true

        # Re-scan after insertion shifted all indices
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

function Set-SessionGraphStale {
    param(
        [Parameter(Mandatory)] [string]$Reason,
        [Parameter(Mandatory)] [string]$ResDir
    )

    # Invalidate all parse caches before the try block so cache clearing
    # is guaranteed even if session graph staleness tracking fails (F10)
    if ($ExecutionContext.InvokeCommand.GetCommand('Clear-ParseCaches', [System.Management.Automation.CommandTypes]::Function)) {
        Clear-ParseCaches
    }

    try {
        if (-not (Get-Command 'Read-SessionGraphMeta' -ErrorAction SilentlyContinue)) {
            . "$script:ModuleRoot/private/session-graphhelpers.ps1"
        }
        $GraphDir = [System.IO.Path]::Combine($ResDir, 'session-graph')
        $MetaPath = [System.IO.Path]::Combine($GraphDir, '_meta.json')
        if ([System.IO.File]::Exists($MetaPath)) {
            $GraphMeta = Read-SessionGraphMeta -MetaPath $MetaPath
            $GraphMeta['Tier2Stale'] = $true
            $GraphMeta['Tier2StaleReason'] = $Reason
            Write-SessionGraphMeta -MetaPath $MetaPath -Meta $GraphMeta
        }
    } catch {
        # Non-fatal: staleness tracking must not abort the entity write
    }
}
