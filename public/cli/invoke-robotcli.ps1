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
    1. Primitives  - colors, arrow menu, result table (leaf, no CLI deps)
    2. Fuzzy       - fuzzy search (depends on primitives)
    3. Display     - detail card, NavState refresh (depends on primitives)
    4. Wizard      - auto-gen wizard system (depends on primitives + fuzzy + display)
    5. Registry    - menu entries, pure data
    6. Routing     - menu dispatch + main/sub loops (depends on all above)
    7. Workflows   - domain-specific composite operations
    8. Migration   - phase integration (overrides stubs from routing)
#>

function Invoke-RobotCLI {
    <#
        .SYNOPSIS
        Launches the interactive Robot CLI menu.
    #>

    [CmdletBinding()] param()

    # Dot-source CLI helpers (loaded on demand, not at module import)
    $CLIRoot = [System.IO.Path]::Combine($script:ModuleRoot, 'private', 'cli')

    # Layer 1: Primitives (leaf - no CLI dependencies)
    . "$CLIRoot/cli-primitives.ps1"

    # Layer 2: Core systems (depend on primitives)
    . "$CLIRoot/cli-fuzzy.ps1"
    . "$CLIRoot/cli-display.ps1"
    . "$CLIRoot/cli-help.ps1"

    # Layer 3: Wizard (depends on primitives + fuzzy + display)
    . "$CLIRoot/cli-wizard.ps1"

    # Layer 4: Registry (pure data)
    . "$CLIRoot/cli-registry.ps1"

    # Layer 5: Routing (depends on all above)
    . "$CLIRoot/cli-routing.ps1"

    # Layer 6: Workflows (depend on primitives, fuzzy, wizard, display)
    foreach ($WF in @('cli-wf-session','cli-wf-player','cli-wf-entity',
                       'cli-wf-currency','cli-wf-pu','cli-wf-discord','cli-wf-reporting')) {
        $WFPath = [System.IO.Path]::Combine($CLIRoot, "$WF.ps1")
        if ([System.IO.File]::Exists($WFPath)) { . $WFPath }
    }

    # Layer 7: Migration integration (overrides stubs from routing)
    $MigPath = [System.IO.Path]::Combine($CLIRoot, 'cli-wizard-migration.ps1')
    if ([System.IO.File]::Exists($MigPath)) { . $MigPath }

    # Validate terminal supports interactive mode
    try {
        $null = [System.Console]::KeyAvailable
    }
    catch {
        throw "Terminal nie wspiera trybu interaktywnego. Użyj standardowego terminala (nie ISE)."
    }

    # Detect theme
    $Theme = Resolve-CLITheme

    # Pre-load shared data for fuzzy search
    Write-Host ''
    Write-Host "  Ładowanie danych..." -ForegroundColor DarkGray

    $Entities = Get-Entity
    $Players  = Get-Player
    $NameIdx  = Get-NameIndex -Players $Players -Entities $Entities

    $NavState = [PSCustomObject]@{
        BreadcrumbStack = [System.Collections.Generic.Stack[string]]::new()
        NameIndex       = $NameIdx
        Players         = $Players
        Entities        = $Entities
        ResolveCache    = @{}
        Theme           = $Theme
    }
    [void]$NavState.BreadcrumbStack.Push('Robot')

    Show-MainMenu -State $NavState
}
