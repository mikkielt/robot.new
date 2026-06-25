@{
    Version              = '0.1.1'
    MajorName            = ''
    Slug                 = 'bootstrap-entities'
    Description          = 'Generates entities.md from the source Gracze.md; converts pu-sessions.md / discord-delivery.md state files to JSON; appends missing entity sections. Operator-supplied Config controls regeneration and section-fix behavior.'
    Requires             = '0.1.0'
    Author               = 'Robot.PowerShell'
    AffectsCategories    = @('EntitySchema','DataRewrite','StateFile')
    EstimatedDurationSec = 15
    RequiresNetwork      = $false
    Archetype            = 'Transform'
    ConfigSchema         = @{
        RegenerateEntities = @{
            Type        = 'Switch'
            Default     = $false
            Required    = $false
            Description = 'Force regenerate entities.md even if it already exists.'
        }
        AutoAddMissingSections = @{
            Type        = 'Switch'
            Default     = $true
            Required    = $false
            Description = 'Append missing ## NPC / ## Grupa / ## Lokacja / ## Przedmiot headers when entities.md is missing them.'
        }
    }
}
