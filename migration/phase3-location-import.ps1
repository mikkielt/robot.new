<#
    .SYNOPSIS
    Phase 3: Import lokalizacji z mapy.

    .DESCRIPTION
    Two-entity-type import from maps.json:
    1. Mapa entities — every maps.json entry becomes a Mapa (concrete game map
       with metadata: @margonemid, @typ, @url, @wymiary, @lokacja parent).
       Written to a dedicated overflow file maps-100-ent.md.
    2. Lokacja entities — deduplicated location names derived from the Mapa
       hierarchy. Written to entities.md ## Lokacja section.

    Two-pass workflow:
    1. Automated import: read maps.json, infer hierarchy, bulk-create Mapa,
       derive Lokacja from unique base names.
    2. Coordinator review: edit override file, re-run phase to apply
       (@nazwa_nerthus on Mapa, virtual Lokacja).

    Dependencies: migration-ui.ps1, migration-state.ps1,
                  migration-location-helpers.ps1, robot module imported.
#>

# Dot-source entity write/find helpers (provides Read-EntityFile, Write-EntityFile,
# Find-EntitySection, Find-EntityBullet, New-EntityBullet, Set-EntityTag, etc.)
. ([System.IO.Path]::Combine($PSScriptRoot, '..', 'private', 'entity-writehelpers.ps1'))

# Dot-source admin config (provides Get-AdminConfig for entity file paths)
. ([System.IO.Path]::Combine($PSScriptRoot, '..', 'private', 'admin-config.ps1'))

# Dot-source self-contained location helpers (no plugin dependency)
. ([System.IO.Path]::Combine($PSScriptRoot, 'migration-location-helpers.ps1'))

# ============================================================================
# PHASE 3 - Import lokalizacji z mapy
# ============================================================================

function Invoke-MigrationPhase3 {
    param(
        [Parameter(Mandatory)] [hashtable]$State,
        [switch]$WhatIf
    )

    if (-not (Test-PhasePredecessor -State $State -Phase 3)) {
        Write-StepWarning 'Faza 2 nie jest ukończona.'
        if (-not (Request-YesNo -Prompt 'Kontynuować mimo to?' -Default $false)) { return }
    }

    $PhaseStatus = Get-PhaseStatus -State $State -Phase 3
    Write-PhaseHeader -Phase 3 -Status $PhaseStatus

    $RepoRoot = Get-RepoRoot
    $Checklist = if ($State.Phases['3'].ContainsKey('Checklist')) { $State.Phases['3'].Checklist } else { @{} }

    # ── Step 1: Load maps.json ──────────────────────────────────────────────
    Write-Step -Number 1 -Text 'Wczytywanie maps.json...'

    $MapsJsonPath = [System.IO.Path]::Combine($script:MigrationResDir, 'maps.json')
    if (-not [System.IO.File]::Exists($MapsJsonPath)) {
        Write-StepError "Nie znaleziono pliku: $MapsJsonPath"
        Write-ActionRequired 'Umieść plik maps.json w .robot.local/res/ i uruchom fazę ponownie.'
        if (-not $WhatIf) { Save-MigrationState -State $State }
        return
    }

    $UTF8NoBOM = [System.Text.UTF8Encoding]::new($false)
    $MapsJson = [System.IO.File]::ReadAllText($MapsJsonPath, $UTF8NoBOM) | ConvertFrom-Json

    if (-not $MapsJson.maps -or $MapsJson.maps.Count -eq 0) {
        Write-StepError 'Plik maps.json nie zawiera tablicy .maps lub jest pusty.'
        if (-not $WhatIf) { Save-MigrationState -State $State }
        return
    }

    $Maps = @($MapsJson.maps)
    $Exterior = @($Maps | Where-Object { $_.outerior -eq $true })
    $Interior = @($Maps | Where-Object { $_.outerior -ne $true })

    Write-StepOK "Wczytano $($Maps.Count) lokalizacji (exterior: $($Exterior.Count), interior: $($Interior.Count))"
    Update-PhaseChecklist -State $State -Phase 3 -Item 'MapsJsonLoaded' -Value $true

    # ── Step 2: Infer hierarchy ─────────────────────────────────────────────
    Write-Step -Number 2 -Text 'Wnioskowanie hierarchii lokalizacji...'

    # Build name set for parent lookup
    $NameSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($Map in $Maps) {
        [void]$NameSet.Add($Map.name)
    }

    # Compute parent for each map using per-pattern intermediates.
    # Intermediates are checked from most-specific to most-stripped,
    # so "X - wieża p.1" prefers parent "X - wieża" over "X" when both exist.
    # When no intermediate matches the NameSet, the most-stripped result is
    # still used as a virtual parent (it will become a Lokacja entity).
    $ParentMap = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $RootCount = 0
    $ChildCount = 0
    $VirtualParentCount = 0

    foreach ($Map in $Maps) {
        $Name = $Map.name
        $Intermediates = @(Get-MapBaseNameIntermediates -Name $Name)

        if ($Intermediates.Count -eq 0) {
            # No stripping happened → root location
            $ParentMap[$Name] = $null
            $RootCount++
            continue
        }

        # Check intermediates from most-specific to most-stripped
        $Found = $false
        foreach ($Base in $Intermediates) {
            if ($NameSet.Contains($Base)) {
                $ParentMap[$Name] = $Base
                $ChildCount++
                $Found = $true
                break
            }
        }
        if ($Found) { continue }

        # Fallback: progressive word removal candidates
        $Candidates = Get-MapBaseNameCandidates -Name $Name
        foreach ($Candidate in $Candidates) {
            if ($NameSet.Contains($Candidate)) {
                $ParentMap[$Name] = $Candidate
                $ChildCount++
                $Found = $true
                break
            }
        }
        if ($Found) { continue }

        # No existing map matches — use the most-stripped deterministic
        # base as a virtual parent (will become a Lokacja entity)
        $ParentMap[$Name] = $Intermediates[$Intermediates.Count - 1]
        $ChildCount++
        $VirtualParentCount++
    }

    # Maps confirmed as parents (other maps strip to them) should also
    # get @lokacja pointing to the Lokacja entity of the same name.
    # This links the parent Mapa to its corresponding Lokacja.
    $ConfirmedParents = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($Entry in $ParentMap.GetEnumerator()) {
        if (-not [string]::IsNullOrEmpty($Entry.Value)) {
            [void]$ConfirmedParents.Add($Entry.Value)
        }
    }
    $ParentSelfLinked = 0
    foreach ($ParentName in $ConfirmedParents) {
        if ($ParentMap.ContainsKey($ParentName) -and [string]::IsNullOrEmpty($ParentMap[$ParentName])) {
            $ParentMap[$ParentName] = $ParentName
            $ParentSelfLinked++
        }
    }

    # Standalone orphan maps (no children, no parent) with unique URLs
    # also get @lokacja self-link. Shared-URL maps are generic room instances
    # (e.g. "Apartament 101") reusing the same tile — skip those.
    # Event maps (URL contains /eve/) are excluded entirely.
    $UrlIndex = [System.Collections.Generic.Dictionary[string, int]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($Map in $Maps) {
        if ($UrlIndex.ContainsKey($Map.url)) {
            $UrlIndex[$Map.url] = $UrlIndex[$Map.url] + 1
        } else {
            $UrlIndex[$Map.url] = 1
        }
    }

    # Build a lookup from name → url for orphan checks
    $NameToUrl = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($Map in $Maps) {
        $NameToUrl[$Map.name] = $Map.url
    }

    $OrphanSelfLinked = 0
    $SelfLinkedNames = [System.Collections.Generic.HashSet[string]]::new($ConfirmedParents, [System.StringComparer]::OrdinalIgnoreCase)
    # Collect orphan candidates first (cannot modify $ParentMap during enumeration)
    $OrphanCandidates = [System.Collections.Generic.List[string]]::new()
    foreach ($Entry in $ParentMap.GetEnumerator()) {
        if (-not [string]::IsNullOrEmpty($Entry.Value)) { continue }
        if ($ConfirmedParents.Contains($Entry.Key)) { continue }
        $Url = $NameToUrl[$Entry.Key]
        if (-not $Url) { continue }
        if ($Url.Contains('/eve/')) { continue }
        if ($UrlIndex[$Url] -gt 1) { continue }
        $OrphanCandidates.Add($Entry.Key)
    }
    foreach ($OrphanName in $OrphanCandidates) {
        $ParentMap[$OrphanName] = $OrphanName
        $OrphanSelfLinked++
        [void]$SelfLinkedNames.Add($OrphanName)
    }

    $VirtualMsg = if ($VirtualParentCount -gt 0) { " ($VirtualParentCount wirtualnych rodziców)" } else { '' }
    $SelfLinkMsg = if (($ParentSelfLinked + $OrphanSelfLinked) -gt 0) {
        ", $ParentSelfLinked rodziców + $OrphanSelfLinked samodzielnych z @lokacja"
    } else { '' }
    Write-StepOK "Hierarchia: $RootCount korzeni, $ChildCount dzieci$VirtualMsg$SelfLinkMsg"
    Update-PhaseChecklist -State $State -Phase 3 -Item 'HierarchyInferred' -Value $true

    # ── Step 3: Check existing entities ─────────────────────────────────────
    Write-Step -Number 3 -Text 'Sprawdzanie istniejących encji Mapa i Lokacja...'
    $AdminConfig = Get-AdminConfig
    $EntityDir = [System.IO.Path]::GetDirectoryName($AdminConfig.EntitiesFile)
    $Entities = Get-Entity -Path $EntityDir -Quiet

    $ExistingMapaNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $ExistingLokacjaNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($E in $Entities) {
        # Mapa entities: @typ overrides Type to 'zewnętrzna'/'wewnętrzna',
        # so detect by @margonemid presence in Overrides
        if ($E.Overrides -and $E.Overrides.ContainsKey('margonemid')) {
            [void]$ExistingMapaNames.Add($E.Name)
        }
        elseif ([string]::Equals($E.Type, 'Lokacja', [System.StringComparison]::OrdinalIgnoreCase)) {
            [void]$ExistingLokacjaNames.Add($E.Name)
        }
    }

    $MapaToImport = [System.Collections.Generic.List[object]]::new()
    $MapaSkipped = 0
    foreach ($Map in $Maps) {
        if ($ExistingMapaNames.Contains($Map.name)) {
            $MapaSkipped++
        } else {
            $MapaToImport.Add($Map)
        }
    }

    Write-StepOK "Mapa do importu: $($MapaToImport.Count) | Już istniejące: $MapaSkipped | Lokacja istniejące: $($ExistingLokacjaNames.Count)"

    # ── Step 4: Bulk import Mapa entities to overflow file ──────────────────
    $MapaBulkDone = ($Checklist.ContainsKey('MapaBulkImportDone') -and $Checklist['MapaBulkImportDone']) -or
                    ($Checklist.ContainsKey('BulkImportDone') -and $Checklist['BulkImportDone'])

    if (-not $MapaBulkDone -and $MapaToImport.Count -gt 0) {
        Write-Step -Number 4 -Text 'Import encji Mapa do maps-100-ent.md...'

        if ($WhatIf) {
            Write-StepWarning "[SUCHY PRZEBIEG] Zaimportowałbym $($MapaToImport.Count) encji Mapa"
        } else {
            # Determine overflow file path (alongside entities.md)
            $AdminConfig = Get-AdminConfig
            $EntityDir = [System.IO.Path]::GetDirectoryName($AdminConfig.EntitiesFile)
            $OverflowPath = [System.IO.Path]::Combine($EntityDir, 'maps-100-ent.md')

            # Create or read overflow file
            if ([System.IO.File]::Exists($OverflowPath)) {
                $FileData = Read-EntityFile -Path $OverflowPath
                $Lines = $FileData.Lines
                $NL = $FileData.NL
            } else {
                # Create new file with ## Mapa section header
                $Lines = [System.Collections.Generic.List[string]]::new()
                $Lines.Add('## Mapa')
                $Lines.Add('')
                $NL = "`n"
            }

            # Find Mapa section
            $Section = Find-EntitySection -Lines $Lines.ToArray() -EntityType 'Mapa'
            if (-not $Section) {
                # Add Mapa section at end
                if ($Lines.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace($Lines[$Lines.Count - 1])) {
                    $Lines.Add('')
                }
                $Lines.Add('## Mapa')
                $Lines.Add('')
                $Section = Find-EntitySection -Lines $Lines.ToArray() -EntityType 'Mapa'
            }

            # Sort imports alphabetically
            $SortedImports = $MapaToImport | Sort-Object -Property { $_.name }

            # Track section end offset (shifts as we insert)
            $InsertOffset = 0
            foreach ($Map in $SortedImports) {
                $Tags = [ordered]@{}
                $Tags['margonemid'] = "$($Map.id)"

                $Parent = $ParentMap[$Map.name]
                if ($Parent) {
                    $Tags['lokacja'] = $Parent
                }

                $Tags['typ'] = if ($Map.outerior) { 'zewnętrzna' } else { 'wewnętrzna' }
                $Tags['url'] = $Map.url

                # Add @wymiary only if both dimensions are present
                if ($null -ne $Map.tileWidth -and $null -ne $Map.tileHeight -and
                    "$($Map.tileWidth)" -ne '' -and "$($Map.tileHeight)" -ne '') {
                    $Tags['wymiary'] = "$($Map.tileWidth), $($Map.tileHeight)"
                }

                $BeforeIdx = $Section.EndIdx + $InsertOffset
                $AfterIdx = New-EntityBullet -Lines $Lines -SectionEnd $BeforeIdx -EntityName $Map.name -Tags $Tags
                $InsertOffset += ($AfterIdx - $BeforeIdx)
            }

            Write-EntityFile -Path $OverflowPath -Lines $Lines -NL $NL
            Write-StepOK "Zaimportowano $($SortedImports.Count) encji Mapa do maps-100-ent.md"
            Update-PhaseChecklist -State $State -Phase 3 -Item 'MapaBulkImportDone' -Value $true
        }
    } elseif ($MapaBulkDone) {
        Write-Step -Number 4 -Text 'Import encji Mapa...'
        Write-StepOK 'Import Mapa już wykonany'
    } elseif ($MapaToImport.Count -eq 0) {
        Write-Step -Number 4 -Text 'Import encji Mapa...'
        Write-StepOK 'Wszystkie encje Mapa już istnieją'
        Update-PhaseChecklist -State $State -Phase 3 -Item 'MapaBulkImportDone' -Value $true
    }

    # ── Step 4b: Patch @lokacja on existing self-linked Mapa entities ────
    # Parent maps and standalone orphans that already exist in maps-100-ent.md
    # may lack @lokacja (imported before self-linking logic was added).
    if ($SelfLinkedNames.Count -gt 0 -and -not $WhatIf) {
        $AdminConfig = Get-AdminConfig
        $EntityDir = [System.IO.Path]::GetDirectoryName($AdminConfig.EntitiesFile)
        $OverflowPath = [System.IO.Path]::Combine($EntityDir, 'maps-100-ent.md')

        if ([System.IO.File]::Exists($OverflowPath)) {
            $OverflowData = Read-EntityFile -Path $OverflowPath
            $OverflowLines = $OverflowData.Lines
            $OverflowNL = $OverflowData.NL
            $Section = Find-EntitySection -Lines $OverflowLines.ToArray() -EntityType 'Mapa'

            if ($Section) {
                $PatchCount = 0
                foreach ($ParentName in $SelfLinkedNames) {
                    # Only patch maps that exist in the file
                    if (-not $NameSet.Contains($ParentName)) { continue }

                    $Bullet = Find-EntityBullet -Lines $OverflowLines.ToArray() `
                        -SectionStart $Section.StartIdx -SectionEnd $Section.EndIdx `
                        -EntityName $ParentName
                    if (-not $Bullet) { continue }

                    # Check if @lokacja already present
                    $HasLokacja = $false
                    for ($li = $Bullet.ChildrenStartIdx; $li -lt $Bullet.ChildrenEndIdx; $li++) {
                        if ($OverflowLines[$li] -match '^\s+-\s+@lokacja:') {
                            $HasLokacja = $true
                            break
                        }
                    }
                    if ($HasLokacja) { continue }

                    Set-EntityTag -Lines $OverflowLines `
                        -ChildrenStart $Bullet.ChildrenStartIdx `
                        -ChildrenEnd $Bullet.ChildrenEndIdx `
                        -TagName 'lokacja' -Value $ParentName
                    $PatchCount++
                }

                if ($PatchCount -gt 0) {
                    Write-EntityFile -Path $OverflowPath -Lines $OverflowLines -NL $OverflowNL
                    Write-StepOK "Uzupełniono @lokacja na $PatchCount istniejących rodzicach Mapa"
                }
            }
        }
    }

    # ── Step 5: Derive Lokacja entities from hierarchy ──────────────────────
    $LokacjaDone = $Checklist.ContainsKey('LokacjaDerivationDone') -and $Checklist['LokacjaDerivationDone']

    if (-not $LokacjaDone) {
        Write-Step -Number 5 -Text 'Wyprowadzanie encji Lokacja z hierarchii...'

        # Collect unique location names from the hierarchy:
        # 1. All parent values (non-null) from ParentMap → these are location names
        # 2. All root names (maps with no parent) → these are also locations
        $UniqueLocationNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

        foreach ($Entry in $ParentMap.GetEnumerator()) {
            if ([string]::IsNullOrEmpty($Entry.Value)) {
                # Unlinked root — only create Lokacja if it was NOT excluded
                # (shared-URL generics and event maps stay without Lokacja)
                # Self-linked maps already have Value = Key, so they hit the else branch.
                # This branch catches only truly unlinked roots — skip them.
                continue
            } else {
                # The parent/self-link value is a location name
                [void]$UniqueLocationNames.Add($Entry.Value)
            }
        }

        # Build parent-of-parent map: for each location name, find its parent
        # by walking the hierarchy (a location's parent is found by looking up
        # the location name in ParentMap — if the location itself was a map entry)
        $LocationParent = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($LocName in $UniqueLocationNames) {
            if ($ParentMap.ContainsKey($LocName)) {
                $LocParent = $ParentMap[$LocName]
                if (-not [string]::IsNullOrEmpty($LocParent) -and -not [string]::Equals($LocParent, $LocName, [System.StringComparison]::OrdinalIgnoreCase)) {
                    $LocationParent[$LocName] = $LocParent
                }
            }
        }

        # Filter out already existing Lokacja entities
        $LokacjaToCreate = [System.Collections.Generic.List[string]]::new()
        foreach ($LocName in $UniqueLocationNames) {
            if (-not $ExistingLokacjaNames.Contains($LocName)) {
                $LokacjaToCreate.Add($LocName)
            }
        }

        Write-Host "    Unikalne nazwy lokalizacji: $($UniqueLocationNames.Count) | Do utworzenia: $($LokacjaToCreate.Count)" -ForegroundColor Cyan

        if ($LokacjaToCreate.Count -gt 0 -and -not $WhatIf) {
            # Read entity file
            $AdminConfig = Get-AdminConfig
            $EntityPath = $AdminConfig.EntitiesFile
            Invoke-EnsureEntityFile -Path $EntityPath
            $FileData = Read-EntityFile -Path $EntityPath
            $Lines = $FileData.Lines
            $NL = $FileData.NL

            # Find Lokacja section
            $Section = Find-EntitySection -Lines $Lines.ToArray() -EntityType 'Lokacja'
            if (-not $Section) {
                Write-StepError 'Nie znaleziono sekcji ## Lokacja w entities.md'
                if (-not $WhatIf) { Save-MigrationState -State $State }
                return
            }

            # Sort alphabetically
            $SortedLokacje = $LokacjaToCreate | Sort-Object

            $InsertOffset = 0
            foreach ($LocName in $SortedLokacje) {
                $Tags = [ordered]@{}

                if ($LocationParent.ContainsKey($LocName)) {
                    $Tags['lokacja'] = $LocationParent[$LocName]
                }

                $BeforeIdx = $Section.EndIdx + $InsertOffset
                $AfterIdx = New-EntityBullet -Lines $Lines -SectionEnd $BeforeIdx -EntityName $LocName -Tags $Tags
                $InsertOffset += ($AfterIdx - $BeforeIdx)
            }

            Write-EntityFile -Path $EntityPath -Lines $Lines -NL $NL
            Write-StepOK "Utworzono $($SortedLokacje.Count) encji Lokacja w entities.md"
        } elseif ($WhatIf -and $LokacjaToCreate.Count -gt 0) {
            Write-StepWarning "[SUCHY PRZEBIEG] Utworzyłbym $($LokacjaToCreate.Count) encji Lokacja"
        } elseif ($LokacjaToCreate.Count -eq 0) {
            Write-StepOK 'Wszystkie encje Lokacja już istnieją'
        }

        if (-not $WhatIf) {
            Update-PhaseChecklist -State $State -Phase 3 -Item 'LokacjaDerivationDone' -Value $true
        }
    } else {
        Write-Step -Number 5 -Text 'Wyprowadzanie encji Lokacja...'
        Write-StepOK 'Lokacja już wyprowadzone'
    }

    # ── Step 6: Export override file ────────────────────────────────────────
    $OverridePath = [System.IO.Path]::Combine($script:MigrationResDir, 'location-overrides.txt')
    $OverridesExported = $Checklist.ContainsKey('OverridesExported') -and $Checklist['OverridesExported']

    if (-not $OverridesExported -and -not $WhatIf) {
        Write-Step -Number 6 -Text 'Eksport pliku nadpisań lokalizacji...'

        $OverrideLines = [System.Collections.Generic.List[string]]::new()
        $OverrideLines.Add('# Plik nadpisań lokalizacji - edytuj i uruchom Fazę 3 ponownie')
        $OverrideLines.Add('# Wygenerowano: ' + [datetime]::Now.ToString('yyyy-MM-dd HH:mm'))
        $OverrideLines.Add('')
        $OverrideLines.Add('# Sekcja 1: Nazwy Nerthus dla encji Mapa (NazwaMargonem<TAB>NazwaNerthus)')
        $OverrideLines.Add('# Zostaw NazwaNerthus pustą jeśli nazwa Margonem jest poprawna.')

        # Sort maps for override file
        $SortedMaps = $Maps | Sort-Object -Property { $_.name }
        foreach ($Map in $SortedMaps) {
            $OuteriorComment = if ($Map.outerior) { '  # exterior' } else { '' }
            $OverrideLines.Add("$($Map.name)$OuteriorComment")
        }

        $OverrideLines.Add('')
        $OverrideLines.Add('# Sekcja 2: Lokalizacje wirtualne (Nazwa<TAB>Rodzic<TAB>NazwaNerthus)')
        $OverrideLines.Add('# Dodaj lokalizacje istniejące tylko w Nerthus (nie w Margonem).')
        $OverrideLines.Add('# Przykład:')
        $OverrideLines.Add("# Akademia Magii`tBracada")

        $ResDir = [System.IO.Path]::GetDirectoryName($OverridePath)
        if (-not [System.IO.Directory]::Exists($ResDir)) {
            [void][System.IO.Directory]::CreateDirectory($ResDir)
        }
        [System.IO.File]::WriteAllLines($OverridePath, $OverrideLines, $UTF8NoBOM)

        Write-StepOK "Wyeksportowano plik nadpisań: $OverridePath"
        Write-ActionRequired "Edytuj plik location-overrides.txt i uruchom Fazę 3 ponownie aby zastosować nadpisania."
        Update-PhaseChecklist -State $State -Phase 3 -Item 'OverridesExported' -Value $true
    } elseif ($OverridesExported) {
        Write-Step -Number 6 -Text 'Eksport nadpisań...'
        Write-StepOK 'Plik nadpisań już wyeksportowany'
    }

    # ── Step 7: Import overrides ────────────────────────────────────────────
    $OverridesImported = $Checklist.ContainsKey('OverridesImported') -and $Checklist['OverridesImported']

    if (-not $OverridesImported -and [System.IO.File]::Exists($OverridePath) -and -not $WhatIf) {
        Write-Step -Number 7 -Text 'Import nadpisań...'

        $OverrideContent = [System.IO.File]::ReadAllLines($OverridePath, $UTF8NoBOM)

        # Parse overrides: section 1 (nazwa_nerthus) and section 2 (virtual locations)
        $InSection1 = $false
        $InSection2 = $false
        $NerthusOverrides = [System.Collections.Generic.List[object]]::new()
        $VirtualLocations = [System.Collections.Generic.List[object]]::new()

        foreach ($Line in $OverrideContent) {
            $Trimmed = $Line.Trim()
            if ($Trimmed.Length -eq 0) { continue }
            if ($Trimmed.StartsWith('#')) {
                if ($Trimmed -match 'Sekcja 1') { $InSection1 = $true; $InSection2 = $false }
                elseif ($Trimmed -match 'Sekcja 2') { $InSection1 = $false; $InSection2 = $true }
                continue
            }

            # Strip trailing comments
            $CleanLine = $Line
            $CommentIdx = $CleanLine.IndexOf('  #')
            if ($CommentIdx -ge 0) { $CleanLine = $CleanLine.Substring(0, $CommentIdx) }

            if ($InSection1) {
                $Parts = $CleanLine.Split("`t")
                $MapName = $Parts[0].Trim()
                $NerthusName = if ($Parts.Count -ge 2) { $Parts[1].Trim() } else { '' }
                if ($NerthusName.Length -gt 0) {
                    $NerthusOverrides.Add([PSCustomObject]@{ MapName = $MapName; NerthusName = $NerthusName })
                }
            }
            elseif ($InSection2) {
                $Parts = $CleanLine.Split("`t")
                $VirtName = $Parts[0].Trim()
                $VirtParent = if ($Parts.Count -ge 2) { $Parts[1].Trim() } else { '' }
                $VirtNerthus = if ($Parts.Count -ge 3) { $Parts[2].Trim() } else { '' }
                if ($VirtName.Length -gt 0) {
                    $VirtualLocations.Add([PSCustomObject]@{
                        Name = $VirtName; Parent = $VirtParent; NerthusName = $VirtNerthus
                    })
                }
            }
        }

        $AppliedOverrides = 0
        $AppliedVirtual = 0

        if ($NerthusOverrides.Count -gt 0 -or $VirtualLocations.Count -gt 0) {
            # Prompt before applying
            $HasEdits = $NerthusOverrides.Count -gt 0 -or $VirtualLocations.Count -gt 0
            if ($HasEdits) {
                Write-Host "    Nadpisania nazw: $($NerthusOverrides.Count) | Lokalizacje wirtualne: $($VirtualLocations.Count)" -ForegroundColor Cyan

                if (-not (Request-YesNo -Prompt 'Czy zastosować nadpisania?' -Default $true -HelpText @(
                    "Nadpisania nazw Nerthus (Mapa): $($NerthusOverrides.Count)",
                    "Nowe lokalizacje wirtualne (Lokacja): $($VirtualLocations.Count)",
                    '',
                    'Tak = zapisz zmiany',
                    'Nie = pomiń, uruchom fazę ponownie po edycji pliku'
                ))) {
                    Write-Host '  Pominięto stosowanie nadpisań.' -ForegroundColor DarkGray
                    if (-not $WhatIf) { Save-MigrationState -State $State }
                    return
                }
            }

            # Apply Section 1: nazwa_nerthus overrides → Mapa entities in overflow file
            if ($NerthusOverrides.Count -gt 0) {
                $AdminConfig = Get-AdminConfig
                $EntityDir = [System.IO.Path]::GetDirectoryName($AdminConfig.EntitiesFile)
                $OverflowPath = [System.IO.Path]::Combine($EntityDir, 'maps-100-ent.md')

                if ([System.IO.File]::Exists($OverflowPath)) {
                    $OverflowData = Read-EntityFile -Path $OverflowPath
                    $OverflowLines = $OverflowData.Lines
                    $OverflowNL = $OverflowData.NL

                    foreach ($Override in $NerthusOverrides) {
                        $Section = Find-EntitySection -Lines $OverflowLines.ToArray() -EntityType 'Mapa'
                        if (-not $Section) { continue }

                        $Bullet = Find-EntityBullet -Lines $OverflowLines.ToArray() -SectionStart $Section.StartIdx -SectionEnd $Section.EndIdx -EntityName $Override.MapName
                        if (-not $Bullet) {
                            Write-Host "    Ostrzeżenie: nie znaleziono encji Mapa '$($Override.MapName)'" -ForegroundColor Yellow
                            continue
                        }

                        Set-EntityTag -Lines $OverflowLines -ChildrenStart $Bullet.ChildrenStartIdx -ChildrenEnd $Bullet.ChildrenEndIdx -TagName 'nazwa_nerthus' -Value $Override.NerthusName
                        $AppliedOverrides++
                    }

                    Write-EntityFile -Path $OverflowPath -Lines $OverflowLines -NL $OverflowNL
                } else {
                    Write-Host "    Ostrzeżenie: nie znaleziono pliku maps-100-ent.md — pomijam nadpisania nazw" -ForegroundColor Yellow
                }
            }

            # Apply Section 2: virtual locations → Lokacja entities in entities.md
            if ($VirtualLocations.Count -gt 0) {
                $AdminConfig = Get-AdminConfig
                $EntityPath = $AdminConfig.EntitiesFile
                $FileData = Read-EntityFile -Path $EntityPath
                $Lines = $FileData.Lines
                $NL = $FileData.NL

                $Section = Find-EntitySection -Lines $Lines.ToArray() -EntityType 'Lokacja'
                if ($Section) {
                    $InsertOffset = 0
                    foreach ($Virt in $VirtualLocations) {
                        # Check if already exists
                        $ExistingBullet = Find-EntityBullet -Lines $Lines.ToArray() -SectionStart $Section.StartIdx -SectionEnd ($Section.EndIdx + $InsertOffset) -EntityName $Virt.Name
                        if ($ExistingBullet) {
                            Write-Host "    Pominięto istniejącą wirtualną: $($Virt.Name)" -ForegroundColor DarkGray
                            continue
                        }

                        $Tags = [ordered]@{}
                        if ($Virt.Parent.Length -gt 0) {
                            $Tags['lokacja'] = $Virt.Parent
                        }
                        if ($Virt.NerthusName.Length -gt 0) {
                            $Tags['nazwa_nerthus'] = $Virt.NerthusName
                        }

                        New-EntityBullet -Lines $Lines -SectionEnd ($Section.EndIdx + $InsertOffset) -EntityName $Virt.Name -Tags $Tags

                        $TagCount = $Tags.Count
                        $InsertedLines = 1 + $TagCount
                        if (($Section.EndIdx + $InsertOffset) -gt 0 -and
                            -not [string]::IsNullOrWhiteSpace($Lines[$Section.EndIdx + $InsertOffset - 1 - $InsertedLines])) {
                            $InsertedLines++
                        }
                        $InsertOffset += $InsertedLines
                        $AppliedVirtual++
                    }
                }

                Write-EntityFile -Path $EntityPath -Lines $Lines -NL $NL
            }

            Write-StepOK "Zastosowano nadpisania: $AppliedOverrides nazw Mapa, $AppliedVirtual wirtualnych Lokacja"
            Update-PhaseChecklist -State $State -Phase 3 -Item 'OverridesImported' -Value $true
        } else {
            Write-StepOK 'Brak nadpisań w pliku (plik nie został edytowany lub jest pusty)'
            # Allow phase to proceed without overrides if coordinator confirms
            if (Request-YesNo -Prompt 'Czy oznaczyć nadpisania jako ukończone (brak zmian do zastosowania)?' -Default $false -HelpText @(
                'Plik location-overrides.txt nie zawiera żadnych nadpisań.',
                'Jeśli nie planujesz dodawać nadpisań, potwierdź aby kontynuować.',
                '',
                'Tak = oznacz krok jako ukończony',
                'Nie = wróć, edytuj plik i uruchom fazę ponownie'
            )) {
                Update-PhaseChecklist -State $State -Phase 3 -Item 'OverridesImported' -Value $true
            }
        }
    } elseif ($OverridesImported) {
        Write-Step -Number 7 -Text 'Import nadpisań...'
        Write-StepOK 'Nadpisania już zastosowane'
    } elseif (-not [System.IO.File]::Exists($OverridePath)) {
        Write-Step -Number 7 -Text 'Import nadpisań...'
        Write-StepWarning 'Plik nadpisań nie istnieje jeszcze — eksportuj go w kroku 6'
    }

    # ── Step 8: Verification ──────────────────────────────────────────────
    Write-Step -Number 8 -Text 'Weryfikacja importu...'

    # Load entities from the actual data directory (not the module directory)
    $AdminConfig = Get-AdminConfig
    $EntityDir = [System.IO.Path]::GetDirectoryName($AdminConfig.EntitiesFile)
    $PostEntities = Get-Entity -Path $EntityDir -Quiet

    # Mapa entities: @typ overrides entity Type to 'zewnętrzna'/'wewnętrzna',
    # so identify Mapa entities by @margonemid presence in Overrides
    $MapaEntities = @($PostEntities.Where({ $_.Overrides -and $_.Overrides.ContainsKey('margonemid') }))
    $MapaWithMargonemId = $MapaEntities
    $MapaWithUrl = @($MapaEntities.Where({ $_.Overrides.ContainsKey('url') }))
    $MapaWithLokacja = @($MapaEntities.Where({ $null -ne $_.Location }))
    $MapaWithTyp = @($MapaEntities.Where({ $_.TypeHistory.Count -gt 0 }))

    $LokacjaEntities = @($PostEntities.Where({ $_.Type -eq 'Lokacja' }))
    $LokacjaWithLokacja = @($LokacjaEntities.Where({ $null -ne $_.Location }))

    Write-Host "    Mapa ogółem: $($MapaEntities.Count)" -ForegroundColor Cyan
    Write-Host "      Z @margonemid: $($MapaWithMargonemId.Count)" -ForegroundColor DarkGray
    Write-Host "      Z @url: $($MapaWithUrl.Count)" -ForegroundColor DarkGray
    Write-Host "      Z @lokacja (rodzic): $($MapaWithLokacja.Count)" -ForegroundColor DarkGray
    Write-Host "      Z @typ: $($MapaWithTyp.Count)" -ForegroundColor DarkGray
    Write-Host "    Lokacja ogółem: $($LokacjaEntities.Count)" -ForegroundColor Cyan
    Write-Host "      Z @lokacja (rodzic): $($LokacjaWithLokacja.Count)" -ForegroundColor DarkGray
    Write-StepOK 'Weryfikacja zakończona'

    # ── Step 9: Commit ────────────────────────────────────────────────────
    $CommitDone = $Checklist.ContainsKey('Committed') -and $Checklist['Committed']
    if (-not $CommitDone -and -not $WhatIf) {
        Write-Step -Number 9 -Text 'Commit...'

        $AdminConfig = Get-AdminConfig
        $EntityDir = [System.IO.Path]::GetDirectoryName($AdminConfig.EntitiesFile)
        $OverflowPath = [System.IO.Path]::Combine($EntityDir, 'maps-100-ent.md')
        $OverflowExists = [System.IO.File]::Exists($OverflowPath)

        $GitDiff = & git -C $RepoRoot diff --name-only 'entities.md' 2>&1
        $OverrideExists = [System.IO.File]::Exists($OverridePath)

        if ($GitDiff -or $OverflowExists -or $OverrideExists) {
            if (Request-YesNo -Prompt 'Czy zacommitować import lokalizacji?' -Default $true -HelpText @(
                'Zapisanie zmian do repozytorium git.',
                '',
                'Wykona: git add entities.md maps-*-ent.md .robot.local/res/location-overrides.txt',
                '        git commit "Import lokalizacji z mapy (Mapa + Lokacja)"',
                '',
                'Tak = git add + git commit',
                'Nie = pominięcie, zmiany zostają niezacommitowane'
            )) {
                & git -C $RepoRoot add 'entities.md' 2>&1
                if ($OverflowExists) {
                    & git -C $RepoRoot add 'maps-100-ent.md' 2>&1
                }
                if ($OverrideExists) {
                    & git -C $RepoRoot add '.robot.local/res/location-overrides.txt' 2>&1
                }
                & git -C $RepoRoot commit -m 'Import lokalizacji z mapy — Mapa + Lokacja (Faza 3 migracji)' 2>&1
                if ($LASTEXITCODE -eq 0) {
                    Write-StepOK 'Zacommitowano'
                    Update-PhaseChecklist -State $State -Phase 3 -Item 'Committed' -Value $true
                } else {
                    Write-StepError 'Nie udało się zacommitować'
                }
            }
        } else {
            Write-StepOK 'Brak zmian do zacommitowania'
        }
    } elseif ($CommitDone) {
        Write-Step -Number 9 -Text 'Commit...'
        Write-StepOK 'Już zacommitowano'
    }

    # ── Phase summary ───────────────────────────────────────────────────────
    $MapaOK = ($State.Phases['3'].Checklist.ContainsKey('MapaBulkImportDone') -and $State.Phases['3'].Checklist['MapaBulkImportDone']) -or
              ($State.Phases['3'].Checklist.ContainsKey('BulkImportDone') -and $State.Phases['3'].Checklist['BulkImportDone'])
    $LokacjaOK = $State.Phases['3'].Checklist.ContainsKey('LokacjaDerivationDone') -and $State.Phases['3'].Checklist['LokacjaDerivationDone']
    $OverridesOK = $State.Phases['3'].Checklist.ContainsKey('OverridesImported') -and $State.Phases['3'].Checklist['OverridesImported']

    if ($MapaOK -and $LokacjaOK -and $OverridesOK) {
        Set-PhaseCompleted -State $State -Phase 3
        Write-PhaseSummary -Phase 3 -Status 'Completed' -Lines @(
            "[OK] $($MapaEntities.Count) encji Mapa w maps-100-ent.md",
            "[OK] $($LokacjaEntities.Count) encji Lokacja w entities.md",
            "[OK] $($MapaWithMargonemId.Count) z @margonemid, $($MapaWithLokacja.Count) z @lokacja"
        )
    } else {
        Set-PhaseInProgress -State $State -Phase 3
        $StatusLines = [System.Collections.Generic.List[string]]::new()
        if ($MapaOK) { $StatusLines.Add('[OK] Import Mapa zakończony') }
        else { $StatusLines.Add('[!!] Import Mapa niezakończony') }
        if ($LokacjaOK) { $StatusLines.Add('[OK] Wyprowadzanie Lokacja zakończone') }
        else { $StatusLines.Add('[!!] Wyprowadzanie Lokacja niezakończone') }
        if ($OverridesOK) { $StatusLines.Add('[OK] Nadpisania zastosowane') }
        else { $StatusLines.Add('[!!] Nadpisania oczekują na zastosowanie') }
        Write-PhaseSummary -Phase 3 -Status 'InProgress' -Lines $StatusLines.ToArray()
    }

    if (-not $WhatIf) { Save-MigrationState -State $State }
}
