<#
    .SYNOPSIS
    Phase 5: Import lokalizacji z mapy.

    .DESCRIPTION
    Bulk-imports Margonem game locations from maps.json as Lokacja entities,
    infers parent-child hierarchy from naming conventions, exports a TSV
    override file for coordinator review (@nazwa_nerthus overrides and
    virtual locations), and applies overrides on re-entry.

    Two-pass workflow:
    1. Automated import: read maps.json, infer hierarchy, bulk-create entities
    2. Coordinator review: edit override file, re-run phase to apply

    Dependencies: migration-ui.ps1, migration-state.ps1,
                  migration-location-helpers.ps1, robot module imported.
#>

# Dot-source self-contained location helpers (no plugin dependency)
. ([System.IO.Path]::Combine($PSScriptRoot, 'migration-location-helpers.ps1'))

# ============================================================================
# PHASE 5 - Import lokalizacji z mapy
# ============================================================================

function Invoke-MigrationPhase5 {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [hashtable]$State,
        [switch]$WhatIf
    )

    $PhaseStatus = Get-PhaseStatus -State $State -Phase 5
    Write-PhaseHeader -Phase 5 -Status $PhaseStatus

    $RepoRoot = Get-RepoRoot
    $Checklist = if ($State.Phases['5'].ContainsKey('Checklist')) { $State.Phases['5'].Checklist } else { @{} }

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
    Update-PhaseChecklist -State $State -Phase 5 -Item 'MapsJsonLoaded' -Value $true

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
    Update-PhaseChecklist -State $State -Phase 5 -Item 'HierarchyInferred' -Value $true

    # ── Step 3: Check existing entities ─────────────────────────────────────
    Write-Step -Number 3 -Text 'Sprawdzanie istniejących encji Lokacja...'
    $Entities = Get-Entity
    $ExistingNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($E in $Entities) {
        if ([string]::Equals($E.EntityType, 'Lokacja', [System.StringComparison]::OrdinalIgnoreCase)) {
            [void]$ExistingNames.Add($E.Name)
        }
    }

    $ToImport = [System.Collections.Generic.List[object]]::new()
    $Skipped = 0
    foreach ($Map in $Maps) {
        if ($ExistingNames.Contains($Map.name)) {
            $Skipped++
        } else {
            $ToImport.Add($Map)
        }
    }

    Write-StepOK "Do importu: $($ToImport.Count) | Już istniejące: $Skipped"

    # ── Step 4: Bulk import ─────────────────────────────────────────────────
    $BulkDone = $Checklist.ContainsKey('BulkImportDone') -and $Checklist['BulkImportDone']
    if (-not $BulkDone -and $ToImport.Count -gt 0) {
        Write-Step -Number 4 -Text 'Import lokalizacji do entities.md...'

        if ($WhatIf) {
            Write-StepWarning "[SUCHY PRZEBIEG] Zaimportowałbym $($ToImport.Count) lokalizacji"
        } else {
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

            # Sort imports alphabetically
            $SortedImports = $ToImport | Sort-Object -Property { $_.name }

            # Track section end offset (shifts as we insert)
            $InsertOffset = 0
            foreach ($Map in $SortedImports) {
                $Tags = [ordered]@{}
                $Tags['margonemid'] = "$($Map.id)"

                $Parent = $ParentMap[$Map.name]
                if ($Parent) {
                    $Tags['lokacja'] = $Parent
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

            Write-EntityFile -Path $EntityPath -Lines $Lines -NL $NL
            Write-StepOK "Zaimportowano $($SortedImports.Count) lokalizacji"
            Update-PhaseChecklist -State $State -Phase 5 -Item 'BulkImportDone' -Value $true
        }
    } elseif ($BulkDone) {
        Write-Step -Number 4 -Text 'Import lokalizacji...'
        Write-StepOK 'Import już wykonany'
    } elseif ($ToImport.Count -eq 0) {
        Write-Step -Number 4 -Text 'Import lokalizacji...'
        Write-StepOK 'Wszystkie lokalizacje już istnieją w entities.md'
        Update-PhaseChecklist -State $State -Phase 5 -Item 'BulkImportDone' -Value $true
    }

    # ── Step 5: Export override file ────────────────────────────────────────
    $OverridePath = [System.IO.Path]::Combine($RepoRoot, '.robot', 'res', 'location-overrides.txt')
    $OverridesExported = $Checklist.ContainsKey('OverridesExported') -and $Checklist['OverridesExported']

    if (-not $OverridesExported -and -not $WhatIf) {
        Write-Step -Number 5 -Text 'Eksport pliku nadpisań lokalizacji...'

        $OverrideLines = [System.Collections.Generic.List[string]]::new()
        $OverrideLines.Add('# Plik nadpisań lokalizacji - edytuj i uruchom Fazę 5 ponownie')
        $OverrideLines.Add('# Wygenerowano: ' + [datetime]::Now.ToString('yyyy-MM-dd HH:mm'))
        $OverrideLines.Add('')
        $OverrideLines.Add('# Sekcja 1: Nazwy Nerthus (NazwaMargonem<TAB>NazwaNerthus)')
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
        Write-ActionRequired "Edytuj plik location-overrides.txt i uruchom Fazę 5 ponownie aby zastosować nadpisania."
        Update-PhaseChecklist -State $State -Phase 5 -Item 'OverridesExported' -Value $true
    } elseif ($OverridesExported) {
        Write-Step -Number 5 -Text 'Eksport nadpisań...'
        Write-StepOK 'Plik nadpisań już wyeksportowany'
    }

    # ── Step 6: Import overrides ────────────────────────────────────────────
    $OverridesImported = $Checklist.ContainsKey('OverridesImported') -and $Checklist['OverridesImported']

    if (-not $OverridesImported -and [System.IO.File]::Exists($OverridePath) -and -not $WhatIf) {
        Write-Step -Number 6 -Text 'Import nadpisań...'

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
                    "Nadpisania nazw Nerthus: $($NerthusOverrides.Count)",
                    "Nowe lokalizacje wirtualne: $($VirtualLocations.Count)",
                    '',
                    'Tak = zapisz zmiany w entities.md',
                    'Nie = pomiń, uruchom fazę ponownie po edycji pliku'
                ))) {
                    Write-Host '  Pominięto stosowanie nadpisań.' -ForegroundColor DarkGray
                    if (-not $WhatIf) { Save-MigrationState -State $State }
                    return
                }
            }

            # Read entity file for modifications
            $AdminConfig = Get-AdminConfig
            $EntityPath = $AdminConfig.EntityFile
            $FileData = Read-EntityFile -Path $EntityPath
            $Lines = $FileData.Lines
            $NL = $FileData.NL

            # Apply Section 1: nazwa_nerthus overrides
            foreach ($Override in $NerthusOverrides) {
                $Section = Find-EntitySection -Lines $Lines.ToArray() -EntityType 'Lokacja'
                if (-not $Section) { continue }

                $Bullet = Find-EntityBullet -Lines $Lines.ToArray() -SectionStart $Section.StartIdx -SectionEnd $Section.EndIdx -EntityName $Override.MapName
                if (-not $Bullet) {
                    Write-Host "    Ostrzeżenie: nie znaleziono encji '$($Override.MapName)'" -ForegroundColor Yellow
                    continue
                }

                Set-EntityTag -Lines $Lines -ChildrenStart $Bullet.ChildrenStartIdx -ChildrenEnd $Bullet.ChildrenEndIdx -TagName 'nazwa_nerthus' -Value $Override.NerthusName
                $AppliedOverrides++
            }

            # Apply Section 2: virtual locations
            if ($VirtualLocations.Count -gt 0) {
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
            }

            Write-EntityFile -Path $EntityPath -Lines $Lines -NL $NL
            Write-StepOK "Zastosowano nadpisania: $AppliedOverrides nazw, $AppliedVirtual wirtualnych lokalizacji"
            Update-PhaseChecklist -State $State -Phase 5 -Item 'OverridesImported' -Value $true
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
                Update-PhaseChecklist -State $State -Phase 5 -Item 'OverridesImported' -Value $true
            }
        }
    } elseif ($OverridesImported) {
        Write-Step -Number 6 -Text 'Import nadpisań...'
        Write-StepOK 'Nadpisania już zastosowane'
    } elseif (-not [System.IO.File]::Exists($OverridePath)) {
        Write-Step -Number 6 -Text 'Import nadpisań...'
        Write-StepWarning 'Plik nadpisań nie istnieje jeszcze — eksportuj go w kroku 5'
    }

    # ── Step 7: Verification ────────────────────────────────────────────────
    Write-Step -Number 7 -Text 'Weryfikacja importu...'
    $PostEntities = Get-Entity
    $LokacjaEntities = @($PostEntities | Where-Object { $_.EntityType -eq 'Lokacja' })
    $WithMargonemId = @($LokacjaEntities | Where-Object { $_.Tags -and $_.Tags.ContainsKey('margonemid') })
    $WithNazwaNerthus = @($LokacjaEntities | Where-Object { $_.Tags -and $_.Tags.ContainsKey('nazwa_nerthus') })
    $WithLokacja = @($LokacjaEntities | Where-Object { $_.Tags -and $_.Tags.ContainsKey('lokacja') })

    Write-Host "    Lokacja ogółem: $($LokacjaEntities.Count)" -ForegroundColor Cyan
    Write-Host "    Z @margonemid: $($WithMargonemId.Count)" -ForegroundColor DarkGray
    Write-Host "    Z @nazwa_nerthus: $($WithNazwaNerthus.Count)" -ForegroundColor DarkGray
    Write-Host "    Z @lokacja (rodzic): $($WithLokacja.Count)" -ForegroundColor DarkGray
    Write-StepOK 'Weryfikacja zakończona'

    # ── Step 8: Commit ──────────────────────────────────────────────────────
    $CommitDone = $Checklist.ContainsKey('Committed') -and $Checklist['Committed']
    if (-not $CommitDone -and -not $WhatIf) {
        Write-Step -Number 8 -Text 'Commit...'
        $GitDiff = & git -C $RepoRoot diff --name-only 'entities.md' 2>&1
        $OverrideExists = [System.IO.File]::Exists($OverridePath)

        if ($GitDiff -or $OverrideExists) {
            if (Request-YesNo -Prompt 'Czy zacommitować import lokalizacji?' -Default $true -HelpText @(
                'Zapisanie zmian do repozytorium git.',
                '',
                'Wykona: git add entities.md .robot/res/location-overrides.txt',
                '        git commit "Import lokalizacji z mapy"',
                '',
                'Tak = git add + git commit',
                'Nie = pominięcie, zmiany zostają niezacommitowane'
            )) {
                & git -C $RepoRoot add 'entities.md' 2>&1
                if ($OverrideExists) {
                    & git -C $RepoRoot add '.robot/res/location-overrides.txt' 2>&1
                }
                & git -C $RepoRoot commit -m 'Import lokalizacji z mapy (Faza 5 migracji)' 2>&1
                if ($LASTEXITCODE -eq 0) {
                    Write-StepOK 'Zacommitowano'
                    Update-PhaseChecklist -State $State -Phase 5 -Item 'Committed' -Value $true
                } else {
                    Write-StepError 'Nie udało się zacommitować'
                }
            }
        } else {
            Write-StepOK 'Brak zmian do zacommitowania'
        }
    } elseif ($CommitDone) {
        Write-Step -Number 8 -Text 'Commit...'
        Write-StepOK 'Już zacommitowano'
    }

    # ── Phase summary ───────────────────────────────────────────────────────
    $BulkOK = $State.Phases['5'].Checklist.ContainsKey('BulkImportDone') -and $State.Phases['5'].Checklist['BulkImportDone']
    $OverridesOK = $State.Phases['5'].Checklist.ContainsKey('OverridesImported') -and $State.Phases['5'].Checklist['OverridesImported']

    if ($BulkOK -and $OverridesOK) {
        Set-PhaseCompleted -State $State -Phase 5
        Write-PhaseSummary -Phase 5 -Status 'Completed' -Lines @(
            "[OK] $($LokacjaEntities.Count) encji Lokacja w entities.md",
            "[OK] $($WithMargonemId.Count) z @margonemid, $($WithLokacja.Count) z @lokacja"
        )
    } else {
        Set-PhaseInProgress -State $State -Phase 5
        $StatusLines = [System.Collections.Generic.List[string]]::new()
        if ($BulkOK) { $StatusLines.Add('[OK] Import zakończony') }
        else { $StatusLines.Add('[!!] Import niezakończony') }
        if ($OverridesOK) { $StatusLines.Add('[OK] Nadpisania zastosowane') }
        else { $StatusLines.Add('[!!] Nadpisania oczekują na zastosowanie') }
        Write-PhaseSummary -Phase 5 -Status 'InProgress' -Lines $StatusLines.ToArray()
    }

    if (-not $WhatIf) { Save-MigrationState -State $State }
}
