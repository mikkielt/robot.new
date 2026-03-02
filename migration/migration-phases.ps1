<#
    .SYNOPSIS
    Phase 0-7 implementation functions for the migration script - data-driven
    phase registry with dynamic dot-sourcing.

    .DESCRIPTION
    Provides $script:PhaseRegistry - a data-driven array of phase definitions
    consumed by migrate.ps1 and cli-wizard-migration.ps1. Each entry maps a
    phase ID to its name, script file, and entry-point function.

    The registry replaces the previous hardcoded dot-source list, making it
    trivial to add, remove, or reorder phases.

    Phases:
    - Phase 0: Preparation & backup (phase0-preparation.ps1)
    - Phase 1: Bootstrap entities.md from Gracze.md (phase1-bootstrap.ps1)
    - Phase 2: Data parity validation (phase2-validation.ps1)
    - Phase 3: Diagnostics & data repair (phase3-diagnostics.ps1)
    - Phase 4: Session format upgrade to Gen4 (phase4-session-upgrade.ps1)
    - Phase 5: Currency enrollment (phase5-currency.ps1)
    - Phase 6: Parallel operation monitoring dashboard (phase6-parallel.ps1)
    - Phase 7: Cutover (phase7-cutover.ps1)

    Shared helpers: migration-shared.ps1

    All phases are idempotent: re-running a completed phase verifies without
    re-executing mutations.

    Dependencies: migration-ui.ps1, migration-state.ps1, robot module imported.
#>

# ── Phase Registry ──────────────────────────────────────────────────────────
# Adding/removing a phase = adding/removing a line here.
# The registry drives: dot-sourcing, CLI menu generation, and dispatch.

$script:PhaseRegistry = @(
    @{ ID = 0; Name = 'Przygotowanie i backup';           Script = 'phase0-preparation.ps1';      Function = 'Invoke-MigrationPhase0' }
    @{ ID = 1; Name = 'Bootstrap entities.md';             Script = 'phase1-bootstrap.ps1';         Function = 'Invoke-MigrationPhase1' }
    @{ ID = 2; Name = 'Walidacja parzystości danych';      Script = 'phase2-validation.ps1';        Function = 'Invoke-MigrationPhase2' }
    @{ ID = 3; Name = 'Diagnostyka i naprawa danych';      Script = 'phase3-diagnostics.ps1';       Function = 'Invoke-MigrationPhase3' }
    @{ ID = 4; Name = 'Upgrade formatu sesji';             Script = 'phase4-session-upgrade.ps1';   Function = 'Invoke-MigrationPhase4' }
    @{ ID = 5; Name = 'Enrollment walut';                  Script = 'phase5-currency.ps1';          Function = 'Invoke-MigrationPhase5' }
    @{ ID = 6; Name = 'Okres równoległy';                  Script = 'phase6-parallel.ps1';          Function = 'Invoke-MigrationPhase6' }
    @{ ID = 7; Name = 'Przełączenie (cutover)';            Script = 'phase7-cutover.ps1';           Function = 'Invoke-MigrationPhase7' }
)

# ── Shared helpers ──────────────────────────────────────────────────────────
. ([System.IO.Path]::Combine($PSScriptRoot, 'migration-shared.ps1'))

# ── Dynamic dot-sourcing from registry ──────────────────────────────────────
foreach ($Phase in $script:PhaseRegistry) {
    . ([System.IO.Path]::Combine($PSScriptRoot, $Phase.Script))
}
