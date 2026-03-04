<#
    .SYNOPSIS
    Interaktywny skrypt migracji z systemu .robot na .robot.new.

    .DESCRIPTION
    Prowadzi koordynatora przez 10 faz migracji (Fazy 0-9) z polskojęzycznym
    interfejsem, śledzeniem postępu i idempotentnym ponawianiem.

    Można uruchamiać wielokrotnie - każda faza sprawdza swój stan
    i pomija już ukończone kroki.

    Stan migracji zapisywany w .robot/res/migration-state.json.

    Użycie:
        .\.robot.new\migration\migrate.ps1              # Menu interaktywne
        .\.robot.new\migration\migrate.ps1 -Phase 3     # Uruchom konkretną fazę
        .\.robot.new\migration\migrate.ps1 -WhatIf      # Tryb suchy (bez zmian)

    .PARAMETER Phase
    Uruchom konkretną fazę (0-9) bez wyświetlania menu.

    .PARAMETER WhatIf
    Tryb suchy - nie wykonuje zmian, tylko pokazuje co by się stało.

    .PARAMETER SkipModuleImport
    Pomiń import modułu robot (do testowania).
#>
[CmdletBinding()] param(
    [ValidateRange(0, 9)]
    [int]$Phase = -1,

    [switch]$WhatIf,

    [switch]$SkipModuleImport
)

# Resolve paths
$MigrationRoot = $PSScriptRoot
$ModuleRoot = [System.IO.Path]::GetDirectoryName($MigrationRoot)
$ModuleManifest = [System.IO.Path]::Combine($ModuleRoot, 'robot.psd1')

# Import the robot module
if (-not $SkipModuleImport) {
    try {
        Import-Module $ModuleManifest -Force -ErrorAction Stop
    }
    catch {
        Write-Host ''
        Write-Host '  [XX] Nie udało się załadować modułu robot.' -ForegroundColor Red
        Write-Host "  Szczegóły: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host ''
        Write-Host '  Upewnij się, że:' -ForegroundColor Yellow
        Write-Host '    1. Submoduł .robot.new jest zainicjalizowany' -ForegroundColor Yellow
        Write-Host '    2. PowerShell 5.1+ lub 7.0+ jest zainstalowany' -ForegroundColor Yellow
        Write-Host '    3. Uruchamiasz skrypt z katalogu repozytorium' -ForegroundColor Yellow
        exit 1
    }
}

# Exclude .robot.new/ from session and data scanning during migration
$script:MigrationExcludeDirs = @($ModuleRoot)

# Dot-source helper files
. ([System.IO.Path]::Combine($MigrationRoot, 'migration-ui.ps1'))
. ([System.IO.Path]::Combine($MigrationRoot, 'migration-state.ps1'))
. ([System.IO.Path]::Combine($MigrationRoot, 'migration-phases.ps1'))

# Load migration state
$MigrationState = Get-MigrationState

# Registry-driven phase dispatch
function Invoke-PhaseByNumber {
    param(
        [Parameter(Mandatory)] [int]$Phase,
        [Parameter(Mandatory)] [hashtable]$State,
        [switch]$WhatIf
    )

    # Look up in registry
    $Entry = $script:PhaseRegistry | Where-Object { $_.ID -eq $Phase } | Select-Object -First 1
    if (-not $Entry) {
        Write-Host ''
        Write-Host "  $([char]0x2717) Nieznana faza: $Phase" -ForegroundColor Red
        return
    }

    $FunctionName = $Entry.Function
    $Cmd = Get-Command $FunctionName -ErrorAction SilentlyContinue
    if (-not $Cmd) {
        Write-Host ''
        Write-Host "  $([char]0x2717) Funkcja '$FunctionName' nie jest dostępna." -ForegroundColor Red
        return
    }

    try {
        & $FunctionName -State $State -WhatIf:$WhatIf
    }
    catch {
        Write-Host ''
        Write-Host "  $([char]0x2717) Błąd w Fazie $Phase`: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host ''
        Write-Host '  Szczegóły:' -ForegroundColor DarkGray
        Write-Host "  $($_.ScriptStackTrace)" -ForegroundColor DarkGray
    }
}

# WhatIf badge
if ($WhatIf) {
    Write-Host ''
    Write-Host '  *** TRYB SUCHY (WhatIf) - żadne zmiany nie zostaną wprowadzone ***' -ForegroundColor Yellow
}

# Direct phase execution (no menu)
if ($Phase -ge 0) {
    Invoke-PhaseByNumber -Phase $Phase -State $MigrationState -WhatIf:$WhatIf
    exit 0
}

# Main menu loop
while ($true) {
    $Selection = Show-ProgressSummary -State $MigrationState

    if ($script:CLIEngineAvailable -and $Selection) {
        # Arrow-key menu mode: Show-ProgressSummary returned a selection ID
        switch -Wildcard ($Selection) {
            '__back__' {
                Write-Host ''
                Write-Host '  Do zobaczenia!' -ForegroundColor Cyan
                Write-Host ''
                exit 0
            }
            'diagnostics' {
                Invoke-QuickDiagnostics
                Request-Confirmation
            }
            'report' {
                Invoke-FullReport -State $MigrationState
                Request-Confirmation
            }
            'phase-*' {
                if ($Selection -match 'phase-(\d+)') {
                    $PhaseNum = [int]$Matches[1]
                    Invoke-PhaseByNumber -Phase $PhaseNum -State $MigrationState -WhatIf:$WhatIf
                    Request-Confirmation -Text 'Naciśnij dowolny klawisz aby wrócić do menu...'
                }
            }
        }
    } else {
        # Fallback: Read-Host numbered menu
        $ValidChoices = @('0', '1', '2', '3', '4', '5', '6', '7', '8', '9', 'D', 'R', 'Q')
        $Choice = Request-UserChoice -Prompt 'Wybierz opcję:' -ValidChoices $ValidChoices

        switch ($Choice) {
            'Q' {
                Write-Host ''
                Write-Host '  Do zobaczenia!' -ForegroundColor Cyan
                Write-Host ''
                exit 0
            }
            'D' {
                Invoke-QuickDiagnostics
                Request-Confirmation
            }
            'R' {
                Invoke-FullReport -State $MigrationState
                Request-Confirmation
            }
            default {
                $PhaseNum = [int]$Choice
                Invoke-PhaseByNumber -Phase $PhaseNum -State $MigrationState -WhatIf:$WhatIf
                Request-Confirmation -Text 'Naciśnij Enter aby wrócić do menu...'
            }
        }
    }
}
