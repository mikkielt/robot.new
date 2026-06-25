@{
    Version              = '0.1.0'
    MajorName            = ''
    Slug                 = 'verify-environment'
    Description          = 'Inspect-only: read-only environment checks (git tag, submodule, state files, manifest). Produces env-report.json artifact for downstream migrations.'
    Requires             = '0.0.0'
    Author               = 'Robot.PowerShell'
    AffectsCategories    = @('StateFile')
    EstimatedDurationSec = 5
    RequiresNetwork      = $false
    Archetype            = 'Inspect'
    ConfigSchema         = @{}
}
