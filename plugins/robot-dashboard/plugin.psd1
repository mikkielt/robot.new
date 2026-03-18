@{
    Name              = 'robot-dashboard'
    Version           = '0.1.0'
    Description       = 'Web dashboard for session creation and data browsing'
    Author            = 'Anward'
    MinCoreVersion    = '2.0.0'
    DependsOn         = @('robot-api')
    ExportedFunctions = @('Invoke-RobotDashboard')
    Config            = @{
        StaticApiUrl = @{
            Description = 'Fallback URL for static API (e.g. nerthus.pl)'
            EnvVar      = 'ROBOT_DASHBOARD_STATIC_URL'
            Default     = $null
            Required    = $false
        }
    }
    Hooks             = @()
    MenuItems         = @(
        @{
            ID               = 'dashboard:open'
            Label            = 'Otwórz Dashboard'
            Menu             = 'API'
            Mode             = 'Workflow'
            WorkflowFunction = 'Invoke-DashboardOpen'
        }
    )
}
