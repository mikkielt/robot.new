@{
    Name              = 'margoworld-datasource'
    Version           = '0.1.0'
    Description       = 'Pulls canonical map data from MargoWorld.pl. Replaces legacy invoke-mapcheckup-legacy.ps1'
    Author            = 'Nerthus Team'
    DependsOn         = @()
    ExportedFunctions = @('Invoke-MargoWorldMapCheckup', 'Get-MargoWorldMapList', 'Get-MargoWorldLocationReport', 'ConvertTo-MapsJsonFromMarkdown', 'Invoke-MargoWorldMapCoordinates', 'Set-MargoWorldMapTileData', 'Export-MargoWorldAsciiMap')
    Config            = @{
        MargoWorldDomain = @{
            Description = 'MargoWorld.pl base URL'
            EnvVar      = 'ROBOT_MARGOWORLD_DOMAIN'
            Default     = 'https://margoworld.pl'
            Required    = $false
        }
        GarmoryDomain    = @{
            Description = 'Garmory CDN base URL'
            EnvVar      = 'ROBOT_GARMORY_DOMAIN'
            Default     = 'https://micc.garmory-cdn.cloud'
            Required    = $false
        }
        MapsJsonPath     = @{
            Description = 'Path to maps.json registry file'
            EnvVar      = $null
            Default     = $null
            Required    = $false
        }
        MapsMarkdownPath = @{
            Description = 'Path to legacy maps.md file (for migration)'
            EnvVar      = $null
            Default     = $null
            Required    = $false
        }
        CoordPadding     = @{
            Description = 'Tile offset for coordinate padding'
            EnvVar      = $null
            Default     = 7
            Required    = $false
        }
    }
    Hooks             = @()
    Scopes            = @('entity:read', 'entity:write')
    MenuItems         = @(
        @{
            ID               = 'margoworld:map-checkup'
            Label            = 'Sprawdź mapy MargoWorld'
            Menu             = 'Lokacje'
            Mode             = 'Workflow'
            WorkflowFunction = 'Invoke-MargoWorldCheckupWorkflow'
            Description      = 'Skanuj MargoWorld.pl i porównaj z rejestrem'
        }
        @{
            ID               = 'margoworld:map-list'
            Label            = 'Lista map (rejestr)'
            Menu             = 'Lokacje'
            Mode             = 'Workflow'
            WorkflowFunction = 'Invoke-MargoWorldMapListWorkflow'
            Description      = 'Wyświetl maps.json jako tabelę'
        }
        @{
            ID               = 'margoworld:location-report'
            Label            = 'Raport mapowania lokacji'
            Menu             = 'Lokacje'
            Mode             = 'Workflow'
            WorkflowFunction = 'Invoke-MargoWorldLocationReportWorkflow'
            Description      = 'Porównaj encje z rejestrem MargoWorld'
        }
        @{
            ID               = 'margoworld:migrate-maps-md'
            Label            = 'Migruj maps.md → maps.json'
            Menu             = 'Lokacje'
            Mode             = 'Workflow'
            WorkflowFunction = 'Invoke-MargoWorldMigrateMapsWorkflow'
            Description      = 'Konwertuj legacy maps.md do formatu maps.json'
        }
        @{
            ID               = 'margoworld:map-coordinates'
            Label            = 'Koordynaty z minimapy'
            Menu             = 'Lokacje'
            Mode             = 'Workflow'
            WorkflowFunction = 'Invoke-MargoWorldCoordinatesWorkflow'
            Description      = 'Scrapuj koordynaty z minimapy /world i zapisz @koordynaty'
        }
        @{
            ID               = 'margoworld:map-tile-data'
            Label            = 'Wymiary tile map'
            Menu             = 'Lokacje'
            Mode             = 'Workflow'
            WorkflowFunction = 'Invoke-MargoWorldTileDataWorkflow'
            Description      = 'Pobierz wymiary tile z nagłówków PNG i zapisz w maps.json'
        }
    )
    HelpContent       = @{
        'Lokacje' = @{
            Body = @(
                'Sprawdź mapy MargoWorld - skanuje MargoWorld.pl, porównuje z rejestrem maps.json.'
                'Lista map - wyświetla zawartość rejestru maps.json.'
                'Raport mapowania lokacji - porównuje encje Lokacja z danymi MargoWorld.'
                'Migruj maps.md - konwertuje legacy maps.md do formatu maps.json.'
                'Koordynaty z minimapy - scrapuje koordynaty tile z /world i zapisuje @koordynaty na encjach Lokacja.'
                'Wymiary tile map - pobiera wymiary tile z nagłówków PNG (CDN) i wzbogaca maps.json o tileX/Y/Width/Height.'
            )
        }
    }
}
