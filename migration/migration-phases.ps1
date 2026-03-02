<#
    .SYNOPSIS
    Phase 0-7 implementation functions for the migration script.

    .DESCRIPTION
    Loader that dot-sources individual phase files consumed by migrate.ps1.
    Each phase is implemented as Invoke-MigrationPhaseN in its own file.

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

# Shared helpers (Show-DiagnosticResults, Invoke-QuickDiagnostics, Invoke-FullReport)
. ([System.IO.Path]::Combine($PSScriptRoot, 'migration-shared.ps1'))

# Individual phase implementations
. ([System.IO.Path]::Combine($PSScriptRoot, 'phase0-preparation.ps1'))
. ([System.IO.Path]::Combine($PSScriptRoot, 'phase1-bootstrap.ps1'))
. ([System.IO.Path]::Combine($PSScriptRoot, 'phase2-validation.ps1'))
. ([System.IO.Path]::Combine($PSScriptRoot, 'phase3-diagnostics.ps1'))
. ([System.IO.Path]::Combine($PSScriptRoot, 'phase4-session-upgrade.ps1'))
. ([System.IO.Path]::Combine($PSScriptRoot, 'phase5-currency.ps1'))
. ([System.IO.Path]::Combine($PSScriptRoot, 'phase6-parallel.ps1'))
. ([System.IO.Path]::Combine($PSScriptRoot, 'phase7-cutover.ps1'))
