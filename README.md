# Robot PowerShell Module

## Overview

The `Robot` module is a set of PowerShell functions designed for parsing, managing, and resolving lore and metadata from the Nerthus repository. It extracts structured information from Markdown files (such as players, characters, sessions, entities, and locations) and enriches it using Git history.

### Core Design Principles
- **Minimal external dependencies**: The module relies on Git and native PowerShell/.NET features at runtime. [Pester](https://pester.dev/) (v5.0+) is required for the test suite.
- **Cross-platform**: Compatible with Windows PowerShell 5.1 and PowerShell Core 7.0+.
- **Performance-focused**: Uses .NET classes for file I/O, regex, and process execution for optimal performance.
- **Streaming architecture**: Git output is parsed line-by-line from `StandardOutput` to avoid materializing large diffs into memory.

## Getting Started

### Prerequisites
- PowerShell 5.1+ (Windows) or PowerShell Core 7.0+ (cross-platform)
- Git installed and available in `PATH`
- This module must be added as a Git submodule to the lore repository (at `.robot.new/`)

### Loading the Module

```powershell
Import-Module ./.robot.new/robot.psd1
```

## Quick Examples

```powershell
# Get all players with their characters and PU data
$Players = Get-Player

# Parse all entities with temporal filtering
$Entities = Get-Entity -ActiveOn (Get-Date "2024-06-15")

# Get all sessions from 2024
$Sessions = Get-Session -MinDate "2024-01-01" -MaxDate "2024-12-31"

# Get characters with full three-layer merged state
$Chars = Get-PlayerCharacter -IncludeState
$Chars | Format-Table Name, Status, Condition, CharacterSheet

# Resolve a name (handles declensions, typos, aliases)
$Index = Get-NameIndex -Players $Players -Entities $Entities
$Result = Resolve-Name -Query "Xerona" -Index $Index

# Create a new player with first character
New-Player -Name "NewPlayer" -MargonemID "12345" `
    -PRFWebhook "https://discord.com/api/webhooks/123/abc" `
    -CharacterName "NewHero" -InitialPUStart 30

# Update character data (dual-target: entities.md + character file)
Set-PlayerCharacter -PlayerName "Solmyr" -CharacterName "Solmyr" `
    -Condition "Ranny." -SpecialItems @("Miecz Ognia", "Tarcza Lodu")

# Soft-delete a character
Remove-PlayerCharacter -PlayerName "Solmyr" -CharacterName "OldChar"

# Create a generic entity (NPC, Grupa, Lokacja, Przedmiot)
New-Entity -Type NPC -Name "Lord Haart" -Tags @{ lokacja = "Erathia"; grupa = "Nekromanci" }

# Update an entity's tags
Set-Entity -Name "Lord Haart" -Tags @{ status = "Nieaktywny" } -ValidFrom "2026-02"

# Soft-delete an entity
Remove-Entity -Name "Lord Haart" -ValidFrom "2026-02"

# Create a currency entity (denomination-validated, auto-named)
New-CurrencyEntity -Denomination "Korony" -Owner "Erdamon" -Amount 500

# Adjust currency quantity (delta)
Set-CurrencyEntity -Name "Korony Erdamon" -AmountDelta +100 -ValidFrom "2026-02"

# Query currency holdings
Get-CurrencyEntity -Owner "Erdamon"
Get-CurrencyEntity -Denomination "Korony"

# Generate a new session in Gen4 format (returns string)
$SessionText = New-Session -Date (Get-Date "2025-06-15") -Title "Ucieczka z Erathii" `
    -Narrator "Dracon" -Locations @("Erathia", "Steadwick")

# Monthly PU assignment - compute only (dry run)
$Results = Invoke-PlayerCharacterPUAssignment -Year 2025 -Month 1
$Results | Format-Table CharacterName, PlayerName, BasePU, GrantedPU, NewPUSum

# Full monthly PU workflow: compute, write, notify, log
Invoke-PlayerCharacterPUAssignment -Year 2025 -Month 1 `
    -UpdatePlayerCharacters -SendToDiscord -AppendToLog

# Validate PU data correctness
$Diag = Test-PlayerCharacterPUAssignment
if (-not $Diag.OK) { $Diag.UnresolvedCharacters | Format-Table }
```

### Batch Processing Pattern

For resolving many names efficiently, pre-build the index and pass a shared cache:

```powershell
$Index = Get-NameIndex -Players (Get-Player) -Entities (Get-Entity)
$Cache = @{}

foreach ($Name in $NamesToResolve) {
    $Result = Resolve-Name -Query $Name -Index $Index -Cache $Cache
}
```

## Module Structure

### Module Core
`robot.psd1`, `robot.psm1`

### Directory Layout

```
.robot.new/
├── public/          # Exported Verb-Noun functions (auto-discovered by robot.psm1)
│   ├── player/      # Player & character CRUD
│   ├── entity/      # Generic entity CRUD (NPC, Grupa, Lokacja, Przedmiot)
│   ├── currency/    # Currency entity CRUD (denomination-aware)
│   ├── session/     # Session lifecycle & git history
│   ├── resolve/     # Name resolution
│   ├── workflow/    # PU assignment pipeline & Discord
│   └── reporting/   # Reports & validation
├── private/         # Shared helpers, dot-sourced on demand (not exported)
├── tests/           # Pester test suite
│   └── fixtures/    # Test data files
├── migration/       # Interactive migration wizard (.robot → .robot.new), 8-phase with state tracking
├── templates/       # Markdown/text templates for entity creation, notifications, scaffolding
├── docs/            # Documentation for narrators, coordinators, players
│   └── PL/          # Polish-language guides (team migration handbook, technical walkthrough)
└── devdocs/         # Technical documentation for developers
```

### Exported Functions (`public/`, 39)

| Category | Subdirectory | Functions |
|---|---|---|
| Core data | `public/` | `Get-Markdown`, `Get-Entity`, `Get-EntityState`, `Get-NameIndex`, `Get-RepoRoot` |
| Player & character | `public/player/` | `Get-Player`, `Get-PlayerCharacter`, `Get-NewPlayerCharacterPUCount`, `New-Player`, `New-PlayerCharacter`, `Set-Player`, `Set-PlayerCharacter`, `Remove-PlayerCharacter` |
| Entity CRUD | `public/entity/` | `New-Entity`, `Set-Entity`, `Remove-Entity` |
| Currency CRUD | `public/currency/` | `New-CurrencyEntity`, `Set-CurrencyEntity`, `Get-CurrencyEntity`, `Remove-CurrencyEntity` |
| Session | `public/session/` | `Get-Session`, `Get-GitChangeLog`, `New-Session`, `Set-Session` |
| Name resolution | `public/resolve/` | `Resolve-Name`, `Resolve-Narrator` |
| Workflow | `public/workflow/` | `Get-VotingEligibility`, `Invoke-PlayerCharacterPUAssignment`, `Send-DiscordMessage` |
| Reporting & validation | `public/reporting/` | `Get-ChangeLog`, `Get-CurrencyReport`, `Get-EntityHistory`, `Get-NamedLocationReport`, `Get-NarratorReport`, `Get-NotificationLog`, `Get-PUAssignmentLog`, `Get-TransactionLedger`, `Test-CurrencyReconciliation`, `Test-PlayerCharacterPUAssignment` |

### Shared Helpers (`private/`, dot-sourced, non-exported)
`entity-writehelpers.ps1`, `charfile-helpers.ps1`, `admin-config.ps1`, `admin-state.ps1`, `format-sessionblock.ps1`, `string-helpers.ps1`, `currency-helpers.ps1`, `parse-markdownfile.ps1`

### Templates
`templates/player-character-file.md.template`, `templates/player-entry.md.template`, `templates/entities-skeleton.md.template`, `templates/currency-entity.md.template`, `templates/pu-notification-base.txt.template`, `templates/pu-notification-overflow.txt.template`, `templates/pu-notification-remaining.txt.template`, `templates/pu-sessions-header.md.template`

## Testing

Install [Pester](https://pester.dev/) v5.0+:

```powershell
Install-Module Pester -MinimumVersion 5.0 -Force -SkipPublisherCheck
```

Run tests from the `.robot.new/` directory:

```powershell
Invoke-Pester ./tests/ -Output Detailed                # all tests
Invoke-Pester ./tests/get-entity.Tests.ps1 -Output Detailed  # single file
```

See [devdocs/TESTING.md](devdocs/TESTING.md) for test architecture, fixtures, loading patterns, and mock strategies.

## Documentation

### For Narrators, Coordinators & Players (`docs/`)

| Document | Description |
|---|---|
| [Auditing](docs/Auditing.md) | Audit trail guide: entity history, change log, transaction ledger, PU log, notification log |
| [Glossary](docs/Glossary.md) | Domain terminology reference (PU, Entity types, etc.) |
| [Migration](docs/Migration.md) | Transition guide from legacy system |
| [Notifications](docs/Notifications.md) | Intel targeting and Discord notifications |
| [Players](docs/Players.md) | Player and character lifecycle (registration, updates, deletion) |
| [PU](docs/PU.md) | Monthly PU assignment process and calculation rules |
| [Sessions](docs/Sessions.md) | Session recording format guide (Gen4 syntax, common mistakes) |
| [Troubleshooting](docs/Troubleshooting.md) | Diagnostics, common issues, and recovery actions |
| [World-State](docs/World-State.md) | Entity tracking, temporal scoping, and three-layer data model |
| [MIGRACJA](docs/PL/MIGRACJA.md) | Team migration handbook - role-by-role impact, timeline, FAQ (Polish) |
| [MIGRACJA-TECH](docs/PL/MIGRACJA-TECH.md) | Step-by-step technical migration walkthrough with commands (Polish) |

### For Developers (`devdocs/`)

| Document | Description |
|---|---|
| [AUDITING](devdocs/AUDITING.md) | Audit functions: five read-only reporting commands, algorithms, output schemas |
| [CHARFILE](devdocs/CHARFILE.md) | Character file format: reputation parsing, template rendering |
| [CONFIG-STATE](devdocs/CONFIG-STATE.md) | Configuration resolution, templates, append-only history |
| [CURRENCY](devdocs/CURRENCY.md) | Currency system: denominations, CRUD, @Transfer, reconciliation, treasury model |
| [DISCORD](devdocs/DISCORD.md) | Discord messaging: webhooks, PU notifications, Intel dispatch |
| [ENTITIES](devdocs/ENTITIES.md) | Entity system: parsing, state merge, three-layer model, output schemas |
| [ENTITY-WRITES](devdocs/ENTITY-WRITES.md) | Write operations: all five mutating commands, line-array primitives |
| [GIT](devdocs/GIT.md) | Git integration: streaming changelog parser, repo detection |
| [MIGRATION](devdocs/MIGRATION.md) | Full migration reference: data model, all subsystems |
| [NAME-RESOLUTION](devdocs/NAME-RESOLUTION.md) | Name resolution: index building, declension, stem alternation, Levenshtein |
| [PARSER](devdocs/PARSER.md) | Markdown parser: RunspacePool architecture, single-pass scanner |
| [PU](devdocs/PU.md) | Normative PU specification: algorithm, overflow pools, diagnostics |
| [SESSIONS](devdocs/SESSIONS.md) | Session pipeline: format detection Gen1-Gen4, deduplication, Intel |
| [SYNTAX](devdocs/SYNTAX.md) | Code style guide: naming, .NET patterns, entity file syntax |
| [TESTING](devdocs/TESTING.md) | Test infrastructure: fixtures, loading patterns, mock strategies |

## License

See [LICENSE](LICENSE).
