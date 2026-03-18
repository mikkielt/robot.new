<#
    .SYNOPSIS
    CLI workflow functions for the nerthusaddon-integration plugin.

    .DESCRIPTION
    Workflow functions registered via plugin manifest MenuItems.
    Dot-sourced at Layer 6.5 when Invoke-RobotCLI starts.

    Workflows:
    - Invoke-NerthusAddonImportWorkflow:  imports and displays nerthusaddon maps
    - Invoke-NerthusAddonReportWorkflow:  runs and displays location coverage report
#>

function Invoke-NerthusAddonImportWorkflow {
    param(
        [Parameter(Mandatory)] [object]$State,
        [Parameter(Mandatory)] [hashtable]$Entry
    )

    Write-Host ''
    Write-CLILine -Text '  Importowanie map NerthusAddon...' -Color (Get-CLIColor -Role 'Accent')
    Write-Host ''

    try {
        $Maps = Import-NerthusAddonMaps

        if (-not $Maps -or $Maps.Count -eq 0) {
            Write-CLILine -Text '  Brak danych map w maps.json.' -Color (Get-CLIColor -Role 'Warning')
            Write-Host ''
            Write-CLILine -Text '  Naciśnij dowolny klawisz...' -Color (Get-CLIColor -Role 'Disabled')
            [void](Read-ArrowKey)
            return
        }

        # Group by season for display
        $BySeason = @{}
        foreach ($Map in $Maps) {
            if (-not $BySeason.ContainsKey($Map.Season)) {
                $BySeason[$Map.Season] = [System.Collections.Generic.List[object]]::new()
            }
            [void]$BySeason[$Map.Season].Add($Map)
        }

        Write-CLILine -Text "  Znaleziono $($Maps.Count) wpisów map w $($BySeason.Count) sezonach:" -Color (Get-CLIColor -Role 'Info')
        Write-Host ''

        foreach ($Season in $BySeason.Keys | Sort-Object) {
            $Count = $BySeason[$Season].Count
            Write-CLILine -Text "    $Season`: $Count map" -Color (Get-CLIColor -Role 'Accent')
        }

        Write-Host ''
        Write-CLILine -Text "  Łącznie unikalnych ID: $(($Maps | Select-Object -Property Id -Unique).Count)" -Color (Get-CLIColor -Role 'Info')
    }
    catch {
        Write-CLILine -Text "  Błąd: $_" -Color (Get-CLIColor -Role 'Error')
    }

    Write-Host ''
    Write-CLILine -Text '  Naciśnij dowolny klawisz...' -Color (Get-CLIColor -Role 'Disabled')
    [void](Read-ArrowKey)
}

function Invoke-NerthusAddonReportWorkflow {
    param(
        [Parameter(Mandatory)] [object]$State,
        [Parameter(Mandatory)] [hashtable]$Entry
    )

    Write-Host ''
    Write-CLILine -Text '  Generowanie raportu pokrycia NerthusAddon...' -Color (Get-CLIColor -Role 'Accent')
    Write-Host ''

    try {
        $Report = Get-NerthusLocationReport -Entities $State.Entities -Quiet

        $AccentColor  = Get-CLIColor -Role 'Accent'
        $SuccessColor = Get-CLIColor -Role 'Success'
        $WarningColor = Get-CLIColor -Role 'Warning'
        $ErrorColor   = Get-CLIColor -Role 'Error'
        $InfoColor    = Get-CLIColor -Role 'Info'

        Write-CLILine -Text "  Łącznie map w addon: $($Report.TotalAddonMaps)" -Color $InfoColor
        Write-Host ''
        Write-CLILine -Text "  ✓ Pokryte (entity + addon):  $($Report.CoveredCount)" -Color $SuccessColor
        Write-CLILine -Text "  ✗ Luki (entity bez addon):   $($Report.GapCount)" -Color $WarningColor
        Write-CLILine -Text "  ? Osierocone (addon bez ent): $($Report.OrphanCount)" -Color $ErrorColor
        Write-CLILine -Text "  ○ Niepowiązane (brak ID):     $($Report.UnlinkedCount)" -Color $InfoColor

        # Show orphan details if any
        if ($Report.OrphanCount -gt 0 -and $Report.OrphanCount -le 20) {
            Write-Host ''
            Write-CLILine -Text '  Osierocone ID (bez encji):' -Color $WarningColor
            foreach ($Orphan in $Report.Orphans) {
                $Seasons = $Orphan.Seasons -join ', '
                Write-CLILine -Text "    ID $($Orphan.MargonemId) ($Seasons)" -Color $InfoColor
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
