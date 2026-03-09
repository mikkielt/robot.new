<#
    .SYNOPSIS
    Phase 0-6 implementation functions for the migration script - data-driven
    phase registry with dynamic dot-sourcing.

    .DESCRIPTION
    Provides $script:PhaseRegistry - a data-driven array of phase definitions
    consumed by migrate.ps1 and cli-wizard-migration.ps1. Each entry maps a
    phase ID to its name, script file, and entry-point function.

    The registry replaces the previous hardcoded dot-source list, making it
    trivial to add, remove, or reorder phases.

    Phases:
    - Phase 0: Setup & bootstrap (phase0-setup.ps1)
    - Phase 1: Session integrity hashes (phase1-session-hashes.ps1)
    - Phase 2: Data validation & repair (phase2-validation.ps1)
    - Phase 3: Import lokalizacji z mapy (phase3-location-import.ps1)
    - Phase 4: Session format upgrade to Gen4 (phase4-session-upgrade.ps1)
    - Phase 5: Currency enrollment (phase5-currency.ps1)
    - Phase 6: Cutover (phase6-cutover.ps1)

    Shared helpers: migration-shared.ps1

    All phases are idempotent: re-running a completed phase verifies without
    re-executing mutations.

    Dependencies: migration-ui.ps1, migration-state.ps1, robot module imported.
#>

# ── Phase Registry ──────────────────────────────────────────────────────────
# Adding/removing a phase = adding/removing a line here.
# The registry drives: dot-sourcing, CLI menu generation, and dispatch.

$script:PhaseRegistry = @(
    @{ ID = 0; Name = 'Przygotowanie i bootstrap';        Script = 'phase0-setup.ps1';             Function = 'Invoke-MigrationPhase0'; EstimatedMinutes = 5  }
    @{ ID = 1; Name = 'Baseline integralności sesji';      Script = 'phase1-session-hashes.ps1';    Function = 'Invoke-MigrationPhase1'; EstimatedMinutes = 15 }
    @{ ID = 2; Name = 'Walidacja i naprawa danych';        Script = 'phase2-validation.ps1';        Function = 'Invoke-MigrationPhase2'; EstimatedMinutes = 30 }
    @{ ID = 3; Name = 'Import lokalizacji z mapy';         Script = 'phase3-location-import.ps1';   Function = 'Invoke-MigrationPhase3'; EstimatedMinutes = 20 }
    @{ ID = 4; Name = 'Upgrade formatu sesji';             Script = 'phase4-session-upgrade.ps1';   Function = 'Invoke-MigrationPhase4'; EstimatedMinutes = 30 }
    @{ ID = 5; Name = 'Enrollment walut';                  Script = 'phase5-currency.ps1';          Function = 'Invoke-MigrationPhase5'; EstimatedMinutes = 60 }
    @{ ID = 6; Name = 'Przełączenie (cutover)';            Script = 'phase6-cutover.ps1';           Function = 'Invoke-MigrationPhase6'; EstimatedMinutes = 30 }
)

# ── Shared helpers ──────────────────────────────────────────────────────────
. ([System.IO.Path]::Combine($PSScriptRoot, 'migration-shared.ps1'))
. ([System.IO.Path]::Combine($PSScriptRoot, 'narrator-normalization.ps1'))

# ── Dynamic dot-sourcing from registry ──────────────────────────────────────
foreach ($PhaseEntry in $script:PhaseRegistry) {
    . ([System.IO.Path]::Combine($PSScriptRoot, $PhaseEntry.Script))
}
