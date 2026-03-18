<#
    .SYNOPSIS
    CLI workflow functions for the margoworld-datasource plugin.

    .DESCRIPTION
    Workflow functions registered via plugin manifest MenuItems.
    Dot-sourced at Layer 6.5 when Invoke-RobotCLI starts.

    Workflows:
    - Invoke-MargoWorldCheckupWorkflow:        runs map checkup with user options
    - Invoke-MargoWorldMapListWorkflow:         displays maps.json as table
    - Invoke-MargoWorldLocationReportWorkflow:  runs and displays location mapping report
    - Invoke-MargoWorldMigrateMapsWorkflow:     migrates legacy maps.md to maps.json
    - Invoke-MargoWorldCoordinatesWorkflow:     scrapes /world for tile coordinates
    - Invoke-MargoWorldTileDataWorkflow:        enriches maps.json with tile dimensions from PNG headers
#>

function Invoke-MargoWorldCheckupWorkflow {
    param(
        [Parameter(Mandatory)] [object]$State,
        [Parameter(Mandatory)] [hashtable]$Entry
    )

    Write-Host ''
    Write-CLILine -Text '  Opcje skanowania MargoWorld:' -Color (Get-CLIColor -Role 'Accent')
    Write-Host ''

    # Ask for diff-only mode
    $DiffItems = @(
        [PSCustomObject]@{ ID = 'diff';   Label = 'Tylko nowe/zmienione'; Description = 'Porównaj z rejestrem'; RoleTag = $null; InfoText = $null; Disabled = $false }
        [PSCustomObject]@{ ID = 'full';   Label = 'Pełne skanowanie';     Description = 'Wszystkie mapy';       RoleTag = $null; InfoText = $null; Disabled = $false }
    )
    $DiffChoice = Show-ArrowMenu -Items $DiffItems -Title 'Tryb skanowania' -ShowBack
    if ($DiffChoice -eq '__back__') { return }

    $DiffOnly = ($DiffChoice -eq 'diff')

    # Ask for update registry
    $UpdateItems = @(
        [PSCustomObject]@{ ID = 'yes'; Label = 'Tak'; Description = 'Zaktualizuj maps.json'; RoleTag = $null; InfoText = $null; Disabled = $false }
        [PSCustomObject]@{ ID = 'no';  Label = 'Nie'; Description = 'Tylko podgląd';          RoleTag = $null; InfoText = $null; Disabled = $false }
    )
    $UpdateChoice = Show-ArrowMenu -Items $UpdateItems -Title 'Zaktualizować rejestr?' -ShowBack
    if ($UpdateChoice -eq '__back__') { return }

    $UpdateRegistry = ($UpdateChoice -eq 'yes')

    Write-Host ''
    Write-CLILine -Text '  Skanowanie MargoWorld.pl...' -Color (Get-CLIColor -Role 'Accent')
    Write-Host ''

    try {
        $Params = @{
            ShowProgress = $true
            DiffOnly     = $DiffOnly
        }
        if ($UpdateRegistry) { $Params['UpdateRegistry'] = $true }

        $Results = Invoke-MargoWorldMapCheckup @Params

        Write-Host ''
        if (-not $Results -or $Results.Count -eq 0) {
            Write-CLILine -Text '  Brak nowych/zmienionych map.' -Color (Get-CLIColor -Role 'Success')
        } else {
            Write-CLILine -Text "  Znaleziono $($Results.Count) map:" -Color (Get-CLIColor -Role 'Info')
            Write-Host ''
            foreach ($R in $Results | Select-Object -First 30) {
                $Addon = if ($R.IsModifiedByNerthusAddon) { ' [NerthusAddon]' } else { '' }
                Write-CLILine -Text "    $($R.Id): $($R.Name)$Addon" -Color (Get-CLIColor -Role 'Accent')
            }
            if ($Results.Count -gt 30) {
                Write-CLILine -Text "    ... i $($Results.Count - 30) więcej" -Color (Get-CLIColor -Role 'Disabled')
            }
        }
    }
    catch {
        Write-CLILine -Text "  Błąd: $_" -Color (Get-CLIColor -Role 'Error')
    }

    Write-Host ''
    Write-CLILine -Text '  Naciśnij dowolny klawisz...' -Color (Get-CLIColor -Role 'Disabled')
    [void](Read-ArrowKey)
}

function Invoke-MargoWorldMapListWorkflow {
    param(
        [Parameter(Mandatory)] [object]$State,
        [Parameter(Mandatory)] [hashtable]$Entry
    )

    Write-Host ''
    Write-CLILine -Text '  Ładowanie rejestru map...' -Color (Get-CLIColor -Role 'Accent')

    try {
        $Maps = Get-MargoWorldMapList -Quiet

        if (-not $Maps -or $Maps.Count -eq 0) {
            Write-Host ''
            Write-CLILine -Text '  Rejestr maps.json jest pusty lub nie istnieje.' -Color (Get-CLIColor -Role 'Warning')
            Write-Host ''
            Write-CLILine -Text '  Naciśnij dowolny klawisz...' -Color (Get-CLIColor -Role 'Disabled')
            [void](Read-ArrowKey)
            return
        }

        # Display as result table
        $TableData = $Maps | ForEach-Object {
            [PSCustomObject]@{
                Id       = $_.Id
                Nazwa    = $_.Name
                BaseName = $_.BaseName
                Piętro   = if ($_.FloorNumber) { "p.$($_.FloorNumber)" } else { '-' }
            }
        }

        while ($true) {
            $Selected = Show-ResultTable -Data $TableData -Columns @('Id', 'Nazwa', 'BaseName', 'Piętro') `
                -Headers @('ID', 'Nazwa', 'Grupa', 'Piętro') -Title 'Rejestr map MargoWorld'
            if (-not $Selected) { break }

            # Show detail for selected map
            $FullEntry = $Maps | Where-Object { $_.Id -eq $Selected.Id } | Select-Object -First 1
            if ($FullEntry) {
                Show-DetailCard -Row $FullEntry -Title "Mapa: $($FullEntry.Name)"
            }
        }
    }
    catch {
        Write-CLILine -Text "  Błąd: $_" -Color (Get-CLIColor -Role 'Error')
        Write-Host ''
        Write-CLILine -Text '  Naciśnij dowolny klawisz...' -Color (Get-CLIColor -Role 'Disabled')
        [void](Read-ArrowKey)
    }
}

function Invoke-MargoWorldLocationReportWorkflow {
    param(
        [Parameter(Mandatory)] [object]$State,
        [Parameter(Mandatory)] [hashtable]$Entry
    )

    Write-Host ''
    Write-CLILine -Text '  Generowanie raportu mapowania lokacji...' -Color (Get-CLIColor -Role 'Accent')
    Write-Host ''

    try {
        $Report = Get-MargoWorldLocationReport -Entities $State.Entities -Quiet

        $AccentColor  = Get-CLIColor -Role 'Accent'
        $SuccessColor = Get-CLIColor -Role 'Success'
        $WarningColor = Get-CLIColor -Role 'Warning'
        $ErrorColor   = Get-CLIColor -Role 'Error'
        $InfoColor    = Get-CLIColor -Role 'Info'

        Write-CLILine -Text "  Łącznie map w rejestrze: $($Report.TotalRegistryMaps)" -Color $InfoColor
        Write-Host ''
        Write-CLILine -Text "  ✓ Zmapowane (entity + rejestr): $($Report.MappedCount)" -Color $SuccessColor
        Write-CLILine -Text "  ✗ Niezmapowane (entity bez rej): $($Report.UnmappedCount)" -Color $WarningColor
        Write-CLILine -Text "  ? Niezarejestrowane (rej bez ent): $($Report.UnregisteredCount)" -Color $ErrorColor
        Write-CLILine -Text "  ○ Bez ID (brak @margonemid):     $($Report.NoIdCount)" -Color $InfoColor

        # Show multi-floor candidates
        if ($Report.MultiFloorCandidates -and $Report.MultiFloorCandidates.Count -gt 0) {
            Write-Host ''
            Write-CLILine -Text '  Grupy wielopiętrowe (kandydaci na encje):' -Color $AccentColor
            foreach ($MF in $Report.MultiFloorCandidates | Select-Object -First 15) {
                Write-CLILine -Text "    $($MF.BaseName) ($($MF.MapCount) pięter, ID: $($MF.MapIds -join ', '))" -Color $InfoColor
            }
        }

        # Show ambiguous groups
        if ($Report.AmbiguousGroups -and $Report.AmbiguousGroups.Count -gt 0) {
            Write-Host ''
            Write-CLILine -Text "  Grupy niejednoznaczne (ta sama nazwa, różne lokacje): $($Report.AmbiguousGroupCount)" -Color $WarningColor
            foreach ($AG in $Report.AmbiguousGroups | Select-Object -First 15) {
                Write-CLILine -Text "    $($AG.BaseName) → $($AG.UrlContexts -join ', ')" -Color $InfoColor
            }
        }
    }
    catch {
        Write-CLILine -Text "  Błąd: $_" -Color (Get-CLIColor -Role 'Error')
    }

    Write-Host ''
    Write-CLILine -Text '  Naciśnij dowolny klawisz...' -Color (Get-CLIColor -Role 'Disabled')
    [void](Read-ArrowKey)
}

function Invoke-MargoWorldMigrateMapsWorkflow {
    param(
        [Parameter(Mandatory)] [object]$State,
        [Parameter(Mandatory)] [hashtable]$Entry
    )

    Write-Host ''
    Write-CLILine -Text '  Migracja maps.md → maps.json' -Color (Get-CLIColor -Role 'Accent')
    Write-Host ''

    try {
        $Config = Get-PluginConfig -PluginName 'margoworld-datasource'

        # Resolve source path from config or ResDir fallback
        $SourcePath = $Config.MapsMarkdownPath
        if (-not $SourcePath) {
            $AdminConfig = Get-AdminConfig
            if ($AdminConfig.ResDir) {
                $SourcePath = [System.IO.Path]::Combine($AdminConfig.ResDir, 'maps.md')
            }
        }

        if (-not $SourcePath -or -not [System.IO.File]::Exists($SourcePath)) {
            Write-CLILine -Text "  Nie znaleziono pliku maps.md: $SourcePath" -Color (Get-CLIColor -Role 'Error')
            Write-Host ''
            Write-CLILine -Text '  Naciśnij dowolny klawisz...' -Color (Get-CLIColor -Role 'Disabled')
            [void](Read-ArrowKey)
            return
        }

        Write-CLILine -Text "  Źródło: $SourcePath" -Color (Get-CLIColor -Role 'Info')

        $Result = ConvertTo-MapsJsonFromMarkdown -SourcePath $SourcePath

        Write-Host ''
        if ($Result.Success) {
            Write-CLILine -Text "  ✓ Migracja zakończona pomyślnie" -Color (Get-CLIColor -Role 'Success')
            Write-CLILine -Text "    Wpisów odczytanych:  $($Result.EntriesRead)" -Color (Get-CLIColor -Role 'Info')
            Write-CLILine -Text "    Wpisów zapisanych:   $($Result.EntriesWritten)" -Color (Get-CLIColor -Role 'Info')
            Write-CLILine -Text "    Ostatnia data:       $($Result.LastUpdated)" -Color (Get-CLIColor -Role 'Info')
            Write-CLILine -Text "    Cel: $($Result.DestinationPath)" -Color (Get-CLIColor -Role 'Info')
        } else {
            Write-CLILine -Text "  ✗ Migracja nie powiodła się (brak danych w pliku źródłowym?)" -Color (Get-CLIColor -Role 'Error')
        }
    }
    catch {
        Write-CLILine -Text "  Błąd: $_" -Color (Get-CLIColor -Role 'Error')
    }

    Write-Host ''
    Write-CLILine -Text '  Naciśnij dowolny klawisz...' -Color (Get-CLIColor -Role 'Disabled')
    [void](Read-ArrowKey)
}

function Invoke-MargoWorldCoordinatesWorkflow {
    param(
        [Parameter(Mandatory)] [object]$State,
        [Parameter(Mandatory)] [hashtable]$Entry
    )

    Write-Host ''
    Write-CLILine -Text '  Scrapowanie koordynatów z minimapy MargoWorld...' -Color (Get-CLIColor -Role 'Accent')
    Write-Host ''

    try {
        # Preview first (report-only)
        $Report = Invoke-MargoWorldMapCoordinates -Entities $State.Entities -ReportOnly -Quiet

        $AccentColor  = Get-CLIColor -Role 'Accent'
        $SuccessColor = Get-CLIColor -Role 'Success'
        $WarningColor = Get-CLIColor -Role 'Warning'
        $InfoColor    = Get-CLIColor -Role 'Info'

        Write-CLILine -Text "  Scrapowanych lokacji:  $($Report.ScrapedCount)" -Color $InfoColor
        Write-CLILine -Text "  Dopasowanych:          $($Report.MatchedCount)" -Color $InfoColor
        Write-CLILine -Text "  Niedopasowanych:       $($Report.UnmatchedCount)" -Color $WarningColor
        Write-Host ''
        Write-CLILine -Text "  ● Nowe (brak koordynatów):  $($Report.NewCount)" -Color $AccentColor
        Write-CLILine -Text "  ● Zmienione:                $($Report.ChangedCount)" -Color $WarningColor
        Write-CLILine -Text "  ● Bez zmian:                $($Report.UnchangedCount)" -Color $SuccessColor

        # Show changed entries in detail
        $Changes = @($Report.Results | Where-Object { $_.Status -ne 'Unchanged' })
        if ($Changes.Count -gt 0) {
            Write-Host ''
            Write-CLILine -Text '  Szczegóły zmian:' -Color $AccentColor
            foreach ($C in $Changes | Select-Object -First 20) {
                $OldCoord = if ($null -ne $C.ExistingX) { "$($C.ExistingX), $($C.ExistingY)" } else { 'brak' }
                Write-CLILine -Text "    $($C.EntityName): $OldCoord → $($C.ScrapedX), $($C.ScrapedY) [$($C.Status)]" -Color $InfoColor
            }
            if ($Changes.Count -gt 20) {
                Write-CLILine -Text "    ... i $($Changes.Count - 20) więcej" -Color (Get-CLIColor -Role 'Disabled')
            }
        }

        # If there are changes, ask for confirmation
        $WriteCount = $Report.NewCount + $Report.ChangedCount
        if ($WriteCount -gt 0) {
            Write-Host ''
            $ConfirmItems = @(
                [PSCustomObject]@{ ID = 'yes'; Label = 'Tak'; Description = "Zapisz $WriteCount zmian"; RoleTag = $null; InfoText = $null; Disabled = $false }
                [PSCustomObject]@{ ID = 'no';  Label = 'Nie'; Description = 'Anuluj';                   RoleTag = $null; InfoText = $null; Disabled = $false }
            )
            $Choice = Show-ArrowMenu -Items $ConfirmItems -Title 'Zapisać koordynaty?' -ShowBack
            if ($Choice -eq 'yes') {
                Write-Host ''
                Write-CLILine -Text '  Zapisywanie koordynatów...' -Color $AccentColor
                $WriteResult = Invoke-MargoWorldMapCoordinates -Entities $State.Entities -Quiet
                Write-Host ''
                Write-CLILine -Text "  ✓ Zapisano: $($WriteResult.NewCount) nowych, $($WriteResult.ChangedCount) zmienionych" -Color $SuccessColor
            }
        } else {
            Write-Host ''
            Write-CLILine -Text '  Brak zmian do zapisania.' -Color $SuccessColor
        }
    }
    catch {
        Write-CLILine -Text "  Błąd: $_" -Color (Get-CLIColor -Role 'Error')
    }

    Write-Host ''
    Write-CLILine -Text '  Naciśnij dowolny klawisz...' -Color (Get-CLIColor -Role 'Disabled')
    [void](Read-ArrowKey)
}

function Invoke-MargoWorldTileDataWorkflow {
    param(
        [Parameter(Mandatory)] [object]$State,
        [Parameter(Mandatory)] [hashtable]$Entry
    )

    Write-Host ''
    Write-CLILine -Text '  Wzbogacanie maps.json o wymiary tile:' -Color (Get-CLIColor -Role 'Accent')
    Write-Host ''

    # Ask for diff-only mode
    $ModeItems = @(
        [PSCustomObject]@{ ID = 'diff'; Label = 'Tylko brakujące'; Description = 'Pomiń mapy z istniejącymi wymiarami'; RoleTag = $null; InfoText = $null; Disabled = $false }
        [PSCustomObject]@{ ID = 'full'; Label = 'Pełne przetwarzanie'; Description = 'Wszystkie mapy exterior'; RoleTag = $null; InfoText = $null; Disabled = $false }
    )
    $ModeChoice = Show-ArrowMenu -Items $ModeItems -Title 'Tryb przetwarzania' -ShowBack
    if ($ModeChoice -eq '__back__') { return }

    $DiffOnly = ($ModeChoice -eq 'diff')

    Write-Host ''
    Write-CLILine -Text '  Pobieranie danych tile z CDN...' -Color (Get-CLIColor -Role 'Accent')
    Write-Host ''

    try {
        $Params = @{
            ShowProgress = $true
            DiffOnly     = $DiffOnly
        }

        $Result = Set-MargoWorldMapTileData @Params

        Write-Host ''
        if (-not $Result) {
            Write-CLILine -Text '  Błąd: nie udało się załadować maps.json.' -Color (Get-CLIColor -Role 'Error')
        } else {
            $AccentColor  = Get-CLIColor -Role 'Accent'
            $SuccessColor = Get-CLIColor -Role 'Success'
            $WarningColor = Get-CLIColor -Role 'Warning'
            $InfoColor    = Get-CLIColor -Role 'Info'

            Write-CLILine -Text "  Łącznie map w rejestrze:  $($Result.TotalMaps)" -Color $InfoColor
            Write-CLILine -Text "  Outerior (na minimapie):  $($Result.OuteriorCount)" -Color $InfoColor
            Write-CLILine -Text "  ✓ Wzbogacone:            $($Result.EnrichedCount)" -Color $SuccessColor
            Write-CLILine -Text "  ○ Pominięte (istniejące): $($Result.SkippedCount)" -Color $InfoColor
            Write-CLILine -Text "  ✗ Błędy (PNG/HTTP):       $($Result.FailedCount)" -Color $WarningColor

            if ($Result.Failed -and $Result.Failed.Count -gt 0) {
                Write-Host ''
                Write-CLILine -Text '  Nieudane pobrania:' -Color $WarningColor
                foreach ($F in $Result.Failed | Select-Object -First 15) {
                    Write-CLILine -Text "    $($F.Id): $($F.Name)" -Color $InfoColor
                }
                if ($Result.Failed.Count -gt 15) {
                    Write-CLILine -Text "    ... i $($Result.Failed.Count - 15) więcej" -Color (Get-CLIColor -Role 'Disabled')
                }
            }
        }
    }
    catch {
        Write-CLILine -Text "  Błąd: $_" -Color (Get-CLIColor -Role 'Error')
    }

    Write-Host ''
    Write-CLILine -Text '  Naciśnij dowolny klawisz...' -Color (Get-CLIColor -Role 'Disabled')
    [void](Read-ArrowKey)
}
