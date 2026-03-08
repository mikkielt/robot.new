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

# Dot-source self-contained location helpers (no plugin dependency)
. ([System.IO.Path]::Combine($PSScriptRoot, 'migration-location-helpers.ps1'))

# ============================================================================
# PHASE 3 - Import lokalizacji z mapy
# ============================================================================

function Invoke-MigrationPhase3 {
    [CmdletBinding(SupportsShouldProcess)]
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

    $MapsJsonPath = [System.IO.Path]::Combine($RepoRoot, '.robot', 'res', 'maps.json')
    if (-not [System.IO.File]::Exists($MapsJsonPath)) {
        Write-StepError "Nie znaleziono pliku: $MapsJsonPath"
        Write-ActionRequired 'Umieść plik maps.json w .robot/res/ i uruchom fazę ponownie.'
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

    # Compute parent for each map
    $ParentMap = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $RootCount = 0
    $ChildCount = 0

    foreach ($Map in $Maps) {
        $Name = $Map.name
        $BaseName = Get-MapBaseNameDeterministic -Name $Name

        if ([string]::Equals($BaseName, $Name, [System.StringComparison]::OrdinalIgnoreCase)) {
            # No stripping happened → root location
            $ParentMap[$Name] = $null
            $RootCount++
            continue
        }

        if ($NameSet.Contains($BaseName)) {
            # Deterministic base name exists → parent found
            $ParentMap[$Name] = $BaseName
            $ChildCount++
            continue
        }

        # Fallback: progressive word removal candidates
        $Candidates = Get-MapBaseNameCandidates -Name $Name
        $Found = $false
        foreach ($Candidate in $Candidates) {
            if ($NameSet.Contains($Candidate)) {
                $ParentMap[$Name] = $Candidate
                $ChildCount++
                $Found = $true
                break
            }
        }

        if (-not $Found) {
            $ParentMap[$Name] = $null
            $RootCount++
        }
    }

    Write-StepOK "Hierarchia: $RootCount korzeni, $ChildCount dzieci"
    Update-PhaseChecklist -State $State -Phase 3 -Item 'HierarchyInferred' -Value $true

    # ── Step 3: Check existing entities ─────────────────────────────────────
    Write-Step -Number 3 -Text 'Sprawdzanie istniejących encji Mapa i Lokacja...'
    $Entities = Get-Entity

    $ExistingMapaNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $ExistingLokacjaNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($E in $Entities) {
        if ([string]::Equals($E.EntityType, 'Mapa', [System.StringComparison]::OrdinalIgnoreCase)) {
            [void]$ExistingMapaNames.Add($E.Name)
        }
        elseif ([string]::Equals($E.EntityType, 'Lokacja', [System.StringComparison]::OrdinalIgnoreCase)) {
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
            # Determine overflow file path
            $RobotNewDir = [System.IO.Path]::Combine($RepoRoot, '.robot.new')
            $OverflowPath = [System.IO.Path]::Combine($RobotNewDir, 'maps-100-ent.md')

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

                New-EntityBullet -Lines $Lines -SectionEnd ($Section.EndIdx + $InsertOffset) -EntityName $Map.name -Tags $Tags

                # Count inserted lines: bullet + tags + possible blank line
                $TagCount = $Tags.Count
                $InsertedLines = 1 + $TagCount  # bullet + tag lines
                # New-EntityBullet may add a blank line before the entity
                if (($Section.EndIdx + $InsertOffset) -gt 0 -and
                    -not [string]::IsNullOrWhiteSpace($Lines[$Section.EndIdx + $InsertOffset - 1 - $InsertedLines])) {
                    $InsertedLines++
                }
                $InsertOffset += $InsertedLines
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

    # ── Step 5: Derive Lokacja entities from hierarchy ──────────────────────
    $LokacjaDone = $Checklist.ContainsKey('LokacjaDerivationDone') -and $Checklist['LokacjaDerivationDone']

    if (-not $LokacjaDone) {
        Write-Step -Number 5 -Text 'Wyprowadzanie encji Lokacja z hierarchii...'

        # Collect unique location names from the hierarchy:
        # 1. All parent values (non-null) from ParentMap → these are location names
        # 2. All root names (maps with no parent) → these are also locations
        $UniqueLocationNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

        foreach ($Entry in $ParentMap.GetEnumerator()) {
            # Root maps (no parent) are locations themselves
            if ($null -eq $Entry.Value) {
                [void]$UniqueLocationNames.Add($Entry.Key)
            } else {
                # The parent is a location
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
                if ($null -ne $LocParent) {
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
            $EntityPath = $AdminConfig.EntityFile
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

                New-EntityBullet -Lines $Lines -SectionEnd ($Section.EndIdx + $InsertOffset) -EntityName $LocName -Tags $Tags

                $TagCount = $Tags.Count
                $InsertedLines = 1 + $TagCount
                if (($Section.EndIdx + $InsertOffset) -gt 0 -and
                    -not [string]::IsNullOrWhiteSpace($Lines[$Section.EndIdx + $InsertOffset - 1 - $InsertedLines])) {
                    $InsertedLines++
                }
                $InsertOffset += $InsertedLines
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
    $OverridePath = [System.IO.Path]::Combine($RepoRoot, '.robot', 'res', 'location-overrides.txt')
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
                $RobotNewDir = [System.IO.Path]::Combine($RepoRoot, '.robot.new')
                $OverflowPath = [System.IO.Path]::Combine($RobotNewDir, 'maps-100-ent.md')

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
                $EntityPath = $AdminConfig.EntityFile
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
    $PostEntities = Get-Entity

    $MapaEntities = @($PostEntities | Where-Object { $_.EntityType -eq 'Mapa' })
    $MapaWithMargonemId = @($MapaEntities | Where-Object { $_.Tags -and $_.Tags.ContainsKey('margonemid') })
    $MapaWithUrl = @($MapaEntities | Where-Object { $_.Overrides -and $_.Overrides.ContainsKey('url') })
    $MapaWithLokacja = @($MapaEntities | Where-Object { $_.Tags -and $_.Tags.ContainsKey('lokacja') })
    $MapaWithTyp = @($MapaEntities | Where-Object { $_.Tags -and $_.Tags.ContainsKey('typ') })

    $LokacjaEntities = @($PostEntities | Where-Object { $_.EntityType -eq 'Lokacja' })
    $LokacjaWithLokacja = @($LokacjaEntities | Where-Object { $_.Tags -and $_.Tags.ContainsKey('lokacja') })

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

        $RobotNewDir = [System.IO.Path]::Combine($RepoRoot, '.robot.new')
        $OverflowPath = [System.IO.Path]::Combine($RobotNewDir, 'maps-100-ent.md')
        $OverflowExists = [System.IO.File]::Exists($OverflowPath)

        $GitDiff = & git -C $RepoRoot diff --name-only 'entities.md' 2>&1
        $OverrideExists = [System.IO.File]::Exists($OverridePath)

        if ($GitDiff -or $OverflowExists -or $OverrideExists) {
            if (Request-YesNo -Prompt 'Czy zacommitować import lokalizacji?' -Default $true -HelpText @(
                'Zapisanie zmian do repozytorium git.',
                '',
                'Wykona: git add entities.md .robot.new/maps-*-ent.md .robot/res/location-overrides.txt',
                '        git commit "Import lokalizacji z mapy (Mapa + Lokacja)"',
                '',
                'Tak = git add + git commit',
                'Nie = pominięcie, zmiany zostają niezacommitowane'
            )) {
                & git -C $RepoRoot add 'entities.md' 2>&1
                if ($OverflowExists) {
                    & git -C $RepoRoot add '.robot.new/maps-100-ent.md' 2>&1
                }
                if ($OverrideExists) {
                    & git -C $RepoRoot add '.robot/res/location-overrides.txt' 2>&1
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
