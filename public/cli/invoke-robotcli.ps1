<#
    .SYNOPSIS
    Interactive CLI menu for the Robot module - Polish-language, arrow-key navigated
    interface with guided wizards, fuzzy name search, and -WhatIf preview.

    .DESCRIPTION
    Entry point for the Robot CLI. Dot-sources private CLI helpers from private/cli/
    on demand, pre-loads entities/players/name index, and launches the main menu loop.

    Target users: Narratorzy (Mistrze Gry) and Koordynatorzy who need guided
    interaction with the Robot module without knowing PowerShell commands.

    Design:
    - Arrow-key navigation via [Console]::ReadKey (not Read-Host)
    - Auto-generated wizards from function [Parameter] metadata
    - Live fuzzy typeahead for name inputs (4-stage Resolve-Name pipeline)
    - -WhatIf preview before every write operation
    - Colorblind-friendly, background-adaptive color scheme
    - No external dependencies (pure PowerShell + .NET classes)

    Loading order (later layers depend on earlier ones):
    1. Primitives     - colors, arrow menu, result table (leaf, no CLI deps)
    2. Fuzzy + Help   - fuzzy search, help system (depend on primitives)
    3. Wizard         - auto-gen wizard system (depends on primitives + fuzzy)
    4. Registry       - menu entries, pure data
    5. Routing        - menu dispatch + main/sub loops (depends on all above)
    5.5 Plugin merge  - merge plugin menu items, categories, help into CLI state
    6. Workflows      - domain-specific composite operations
    6.5 Plugin CLI    - dot-source plugin cli/*.ps1 workflow files
    7. Migration      - phase integration (overrides stubs from routing)
#>

function Invoke-RobotCLI {
    <#
        .SYNOPSIS
        Launches the interactive Robot CLI menu.
    #>

    [CmdletBinding()]
    param(
        [switch]$NoHealthCheck
    )

    # CLI helpers dot-sourced on demand — not at module import to keep startup fast.
    # Layers must load in order: later layers depend on earlier ones.
    $CLIRoot = [System.IO.Path]::Combine($script:ModuleRoot, 'private', 'cli')

    # Layer 1: Primitives (leaf — no CLI dependencies)
    . "$CLIRoot/cli-primitives.ps1"

    # Layer 2: Core systems (depend on primitives)
    . "$CLIRoot/cli-fuzzy.ps1"
    . "$CLIRoot/cli-help.ps1"

    # Layer 3: Wizard (depends on primitives + fuzzy + display)
    . "$CLIRoot/cli-wizard.ps1"

    # Layer 4: Registry (pure data)
    . "$CLIRoot/cli-registry.ps1"

    # Layer 5: Routing (depends on all above)
    . "$CLIRoot/cli-routing.ps1"

    # Layer 5.5: Merge plugin-contributed menu items into routing tables
    Merge-PluginMenuItems

    # Layer 6: Workflows (depend on primitives, fuzzy, wizard)
    foreach ($WF in @('cli-wf-session','cli-wf-player','cli-wf-entity',
                       'cli-wf-currency','cli-wf-economy','cli-wf-pu','cli-wf-discord','cli-wf-reporting')) {
        $WFPath = [System.IO.Path]::Combine($CLIRoot, "$WF.ps1")
        if ([System.IO.File]::Exists($WFPath)) { . $WFPath }
    }

    # Layer 6.5: Plugin-provided CLI workflows
    if ($script:LoadedPlugins) {
        foreach ($PluginEntry in $script:LoadedPlugins.GetEnumerator()) {
            $PluginCLIDir = [System.IO.Path]::Combine(
                $script:ModuleRoot, 'plugins', $PluginEntry.Key, 'cli')
            if ([System.IO.Directory]::Exists($PluginCLIDir)) {
                $CLIFiles = [System.IO.Directory]::GetFiles($PluginCLIDir, '*.ps1')
                foreach ($CLIFile in $CLIFiles) {
                    try {
                        . $CLIFile
                    }
                    catch {
                        [System.Console]::Error.WriteLine(
                            "[WARN Invoke-RobotCLI] Failed to load plugin CLI file '$CLIFile': $_")
                    }
                }
            }
        }
    }

    # ISE and non-interactive terminals lack [Console]::KeyAvailable
    try {
        $null = [System.Console]::KeyAvailable
    }
    catch {
        throw "Terminal nie wspiera trybu interaktywnego. Użyj standardowego terminala (nie ISE)."
    }

    $Theme = Resolve-CLITheme

    # Pre-load shared data — entities, players, name index needed by all workflows
    Write-Host ''
    $LoadProgress = New-ProgressState -Title 'Ładowanie danych' -TotalSteps 4

    Start-ProgressStep -State $LoadProgress -Label 'Encje'
    $Entities = Get-Entity -Quiet
    Complete-ProgressStep -State $LoadProgress -Detail "$($Entities.Count)"

    Start-ProgressStep -State $LoadProgress -Label 'Gracze'
    $Players  = Get-Player
    Complete-ProgressStep -State $LoadProgress -Detail "$($Players.Count)"

    Start-ProgressStep -State $LoadProgress -Label 'Indeks nazw'
    $NameIdx  = Get-NameIndex -Players $Players -Entities $Entities
    Complete-ProgressStep -State $LoadProgress -Detail "$($NameIdx.Count) wpisów"

    # O(1) type-filtered lookups avoid linear scans in fuzzy search typeahead
    Start-ProgressStep -State $LoadProgress -Label 'Indeks typów'
    $EntityTypeIdx = @{}
    foreach ($E in $Entities) {
        if (-not $EntityTypeIdx.ContainsKey($E.Type)) {
            $EntityTypeIdx[$E.Type] = [System.Collections.Generic.List[object]]::new()
        }
        [void]$EntityTypeIdx[$E.Type].Add($E)
    }
    Complete-ProgressStep -State $LoadProgress -Detail "$($EntityTypeIdx.Count) typów"

    Complete-ProgressGroup -State $LoadProgress

    # Health dashboard: cached validation results shown on main menu
    $HealthCache = @{
        PU        = $null
        Currency  = $null
        Integrity = $null
        Graph     = $null
        CheckedAt = $null
        Errors    = @()
        Skipped   = $false
    }
    if ($NoHealthCheck) {
        $HealthCache.Skipped = $true
    }
    else {
        $HCProgress = New-ProgressState -Title 'Sprawdzanie stanu systemu' -TotalSteps 6
        $HealthCache.CheckedAt = Get-Date

        # SilentlyContinue prevents health-check errors (e.g. missing Gracze.md)
        # from corrupting the CLI display; errors go to $HealthCache.Errors instead
        $PrevEAP = $ErrorActionPreference
        $ErrorActionPreference = 'SilentlyContinue'

        # Load sessions and entity state once — shared across PU, Currency, and Graph checks
        Start-ProgressStep -State $HCProgress -Label 'Sesje'
        $SessCB = { param($C,$T,$D); Update-ProgressStep -State $HCProgress -Detail "$C/$T" }.GetNewClosure()
        $SharedSessions = Get-Session -Quiet -Entities $Entities -Players $Players -NameIndex $NameIdx -ProgressCallback $SessCB
        Complete-ProgressStep -State $HCProgress -Detail "$($SharedSessions.Count)"

        Start-ProgressStep -State $HCProgress -Label 'Stan encji'
        $EntCB = { param($C,$T,$D); Update-ProgressStep -State $HCProgress -Detail "$C/$T" }.GetNewClosure()
        $SharedEntityState = Get-EntityState -Quiet `
            -Entities $Entities -Sessions $SharedSessions `
            -Players $Players -NameIndex $NameIdx `
            -ProgressCallback $EntCB
        Complete-ProgressStep -State $HCProgress

        Start-ProgressStep -State $HCProgress -Label 'Walidacja PU'
        $PUCB = { param($C,$T,$D); Update-ProgressStep -State $HCProgress -Detail "$C/$T" }.GetNewClosure()
        try { $HealthCache.PU = Test-PlayerCharacterPUAssignment -Quiet -AllSessions $SharedSessions -ProgressCallback $PUCB
              Complete-ProgressStep -State $HCProgress -Detail 'OK' }
        catch { $HealthCache.Errors += "PU: $($_.Exception.Message)"
                Complete-ProgressStep -State $HCProgress -Detail 'BŁĄD' -Failed }

        Start-ProgressStep -State $HCProgress -Label 'Walidacja walut'
        $CurCB = { param($C,$T,$D); Update-ProgressStep -State $HCProgress -Detail "$C/$T" }.GetNewClosure()
        try { $HealthCache.Currency = Test-CurrencyReconciliation -Quiet -Entities $SharedEntityState -Sessions $SharedSessions -ProgressCallback $CurCB
              Complete-ProgressStep -State $HCProgress -Detail 'OK' }
        catch { $HealthCache.Errors += "Waluta: $($_.Exception.Message)"
                Complete-ProgressStep -State $HCProgress -Detail 'BŁĄD' -Failed }

        Start-ProgressStep -State $HCProgress -Label 'Integralność sesji'
        $IntCB = { param($C,$T,$D); Update-ProgressStep -State $HCProgress -Detail "$C/$T" }.GetNewClosure()
        try { $HealthCache.Integrity = Test-SessionIntegrity -Quiet -Since (Get-Date).AddMonths(-2) -ProgressCallback $IntCB
              Complete-ProgressStep -State $HCProgress -Detail 'OK' }
        catch { $HealthCache.Errors += "Sesje: $($_.Exception.Message)"
                Complete-ProgressStep -State $HCProgress -Detail 'BŁĄD' -Failed }

        Start-ProgressStep -State $HCProgress -Label 'Graf sesji'
        $GrCB = { param($C,$T,$D); Update-ProgressStep -State $HCProgress -Detail "$C/$T" }.GetNewClosure()
        try { $HealthCache.Graph = Test-SessionGraphIntegrity -Quiet -Sessions $SharedSessions -NameIndex $NameIdx -ProgressCallback $GrCB
              Complete-ProgressStep -State $HCProgress -Detail 'OK' }
        catch { $HealthCache.Errors += "Graf: $($_.Exception.Message)"
                Complete-ProgressStep -State $HCProgress -Detail 'BŁĄD' -Failed }

        $ErrorActionPreference = $PrevEAP

        Complete-ProgressGroup -State $HCProgress
    }

    $NavState = [PSCustomObject]@{
        BreadcrumbStack = [System.Collections.Generic.Stack[string]]::new()
        NameIndex       = $NameIdx
        Players         = $Players
        Entities        = $Entities
        EntityTypeIndex = $EntityTypeIdx
        ResolveCache    = @{}
        Theme           = $Theme
        HealthCache     = $HealthCache
    }
    [void]$NavState.BreadcrumbStack.Push('Robot')

    Show-MainMenu -State $NavState
}
