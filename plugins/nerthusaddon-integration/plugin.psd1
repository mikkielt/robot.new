@{
    Name              = 'nerthusaddon-integration'
    Version           = '0.1.0'
    Description       = 'Cross-references Robot entities with nerthusaddon map data (seasonal backgrounds, modified maps)'
    Author            = 'Nerthus Team'
    DependsOn         = @()
    ExportedFunctions = @('Import-NerthusAddonMaps', 'Get-NerthusLocationReport', 'Export-NerthusLocationData')
    Config            = @{
        NerthusAddonPath = @{
            Description = 'Path to local nerthusaddon repository'
            EnvVar      = 'ROBOT_NERTHUSADDON_PATH'
            Default     = $null
            Required    = $true
        }
        MapsJsonRelPath  = @{
            Description = 'Relative path to maps.json within nerthusaddon repo'
            EnvVar      = $null
            Default     = 'res/configs/maps.json'
            Required    = $false
        }
    }
    Hooks             = @()
    Scopes            = @('entity:read')
    MenuCategories    = @('Lokacje')
    MenuItems         = @(
        @{
            ID               = 'nerthusaddon:import-maps'
            Label            = 'Importuj mapy NerthusAddon'
            Menu             = 'Lokacje'
            Mode             = 'Workflow'
            WorkflowFunction = 'Invoke-NerthusAddonImportWorkflow'
            Description      = 'Parsuj maps.json z repozytorium nerthusaddon'
        }
        @{
            ID               = 'nerthusaddon:location-report'
            Label            = 'Raport pokrycia NerthusAddon'
            Menu             = 'Lokacje'
            Mode             = 'Workflow'
            WorkflowFunction = 'Invoke-NerthusAddonReportWorkflow'
            Description      = 'Porównaj encje z danymi nerthusaddon'
        }
    )
    HelpContent       = @{
        'Lokacje' = @{
            Title = 'Lokacje - Pomoc'
            Body  = @(
                'Narzędzia do zarządzania lokacjami i mapami Margonem.'
                ''
                'Importuj mapy NerthusAddon - parsuje maps.json z lokalnego repozytorium nerthusaddon.'
                'Raport pokrycia NerthusAddon - porównuje encje Lokacja z danymi map nerthusaddon.'
            )
        }
    }
}
