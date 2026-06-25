@{
    Version              = '0.3.0'
    MajorName            = ''
    Slug                 = 'validate-parity'
    Description          = 'Phase 2 port: parity diagnostics (long-running)'
    Requires             = '0.2.0'
    Author               = 'Robot.PowerShell'
    AffectsCategories    = @('DataRewrite')
    EstimatedDurationSec = 120
    RequiresNetwork      = $false
    Archetype            = 'Transform'
    ConfigSchema         = @{}
}
