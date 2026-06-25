@{
    Version              = '0.1.2'
    MajorName            = ''
    Slug                 = 'commit-bootstrap'
    Description          = 'Commit-archetype: stages and commits bootstrap output (entities.md, state files, manifest). No-ops if no diff.'
    Requires             = '0.1.1'
    Author               = 'Robot.PowerShell'
    AffectsCategories    = @('RepoLayout')
    EstimatedDurationSec = 2
    RequiresNetwork      = $false
    Archetype            = 'Commit'
    ConfigSchema         = @{
        CommitMessage = @{
            Type        = 'String'
            Default     = 'Bootstrap entities.md from Gracze.md'
            Required    = $false
            Description = 'Commit message for the bootstrap commit.'
        }
        SkipCommit = @{
            Type        = 'Switch'
            Default     = $false
            Required    = $false
            Description = 'Skip the git commit; useful in fixture-mode tests with no git repo.'
        }
    }
}
