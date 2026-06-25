@{
    Version              = '0.2.0'
    MajorName            = ''
    Slug                 = 'session-hash-baseline'
    Description          = 'Generates SHA256 baseline hashes for all session Markdown headers so Test-SessionIntegrity can detect later tampering. Idempotent: skips re-hashing unless Config.ForceRecompute is true.'
    Requires             = '0.1.2'
    Author               = 'Robot.PowerShell'
    AffectsCategories    = @('StateFile')
    EstimatedDurationSec = 10
    RequiresNetwork      = $false
    Archetype            = 'Transform'
    ConfigSchema         = @{
        ForceRecompute = @{
            Type        = 'Switch'
            Default     = $false
            Required    = $false
            Description = 'Force regenerate all session hashes even if the baseline already exists.'
        }
    }
}
