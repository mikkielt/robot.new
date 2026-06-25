@{
    Version              = '0.5.0'
    MajorName            = ''
    Slug                 = 'download-logs'
    Description          = 'Bulk-downloads session log URLs to .robot.local/res/logs/. Idempotent: cached files are not re-fetched. Config controls whether failed URLs are retried on re-run.'
    Requires             = '0.4.0'
    Author               = 'Robot.PowerShell'
    AffectsCategories    = @('ExternalImport')
    EstimatedDurationSec = 300
    RequiresNetwork      = $true
    Archetype            = 'Transform'
    ConfigSchema         = @{
        DownloadLogs = @{
            Type        = 'Switch'
            Default     = $true
            Required    = $false
            Description = 'When false, the migration is a pure read; no HTTP requests are made.'
        }
        RetryFailedUrls = @{
            Type        = 'Switch'
            Default     = $false
            Required    = $false
            Description = 'On re-run, re-attempt URLs that left .failed marker files behind.'
        }
    }
}
