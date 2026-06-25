@{
    Version              = '0.4.0'
    MajorName            = ''
    Slug                 = 'import-locations'
    Description          = 'Phase 3 port: import locations from maps.json (idempotent)'
    Requires             = '0.3.0'
    Author               = 'Robot.PowerShell'
    AffectsCategories    = @('ExternalImport','EntitySchema')
    EstimatedDurationSec = 30
    RequiresNetwork      = $false
    Archetype            = 'Transform'
    ConfigSchema         = @{}
}
