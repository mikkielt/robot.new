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
│   ├── session/     # Session lifecycle & git history
│   ├── resolve/     # Name resolution
│   ├── workflow/    # PU assignment pipeline & Discord
│   └── reporting/   # Reports & validation
├── private/         # Shared helpers, dot-sourced on demand (not exported)
├── tests/           # Pester test suite
│   └── fixtures/    # Test data files
├── templates/       # Markdown templates for player/character creation
├── docs/            # Documentation for narrators, coordinators, players
└── devdocs/         # Technical documentation for developers
```

### Exported Functions (`public/`, 25)

| Category | Subdirectory | Functions |
|---|---|---|
| Core data | `public/` | `Get-Markdown`, `Get-Entity`, `Get-EntityState`, `Get-NameIndex`, `Get-RepoRoot` |
| Player & character | `public/player/` | `Get-Player`, `Get-PlayerCharacter`, `Get-NewPlayerCharacterPUCount`, `New-Player`, `New-PlayerCharacter`, `Set-Player`, `Set-PlayerCharacter`, `Remove-PlayerCharacter` |
| Session | `public/session/` | `Get-Session`, `Get-GitChangeLog`, `New-Session`, `Set-Session` |
| Name resolution | `public/resolve/` | `Resolve-Name`, `Resolve-Narrator` |
| Workflow | `public/workflow/` | `Invoke-PlayerCharacterPUAssignment`, `Send-DiscordMessage` |
| Reporting & validation | `public/reporting/` | `Get-CurrencyReport`, `Get-NamedLocationReport`, `Test-CurrencyReconciliation`, `Test-PlayerCharacterPUAssignment` |

### Shared Helpers (`private/`, dot-sourced, non-exported)
`entity-writehelpers.ps1`, `charfile-helpers.ps1`, `admin-config.ps1`, `admin-state.ps1`, `format-sessionblock.ps1`, `string-helpers.ps1`, `currency-helpers.ps1`, `parse-markdownfile.ps1`

### Templates
`templates/player-character-file.md.template`, `templates/player-entry.md.template`

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
| [Glossary](docs/Glossary.md) | Domain terminology reference (PU, Entity types, etc.) |
| [Sessions](docs/Sessions.md) | Session recording format guide (Gen4 syntax, common mistakes) |
| [PU](docs/PU.md) | Monthly PU assignment process and calculation rules |
| [Players](docs/Players.md) | Player and character lifecycle (registration, updates, deletion) |
| [World-State](docs/World-State.md) | Entity tracking, temporal scoping, and three-layer data model |
| [Notifications](docs/Notifications.md) | Intel targeting and Discord notifications |
| [Migration](docs/Migration.md) | Transition guide from legacy system |
| [Troubleshooting](docs/Troubleshooting.md) | Diagnostics, common issues, and recovery actions |

### For Developers (`devdocs/`)

| Document | Description |
|---|---|
| [ENTITIES](devdocs/ENTITIES.md) | Entity system: parsing, state merge, three-layer model, output schemas |
| [ENTITY-WRITES](devdocs/ENTITY-WRITES.md) | Write operations: all five mutating commands, line-array primitives |
| [SESSIONS](devdocs/SESSIONS.md) | Session pipeline: format detection Gen1-Gen4, deduplication, Intel |
| [PU](devdocs/PU.md) | Normative PU specification: algorithm, overflow pools, diagnostics |
| [NAME-RESOLUTION](devdocs/NAME-RESOLUTION.md) | Name resolution: index building, declension, stem alternation, Levenshtein |
| [PARSER](devdocs/PARSER.md) | Markdown parser: RunspacePool architecture, single-pass scanner |
| [CHARFILE](devdocs/CHARFILE.md) | Character file format: reputation parsing, template rendering |
| [CONFIG-STATE](devdocs/CONFIG-STATE.md) | Configuration resolution, templates, append-only history |
| [GIT](devdocs/GIT.md) | Git integration: streaming changelog parser, repo detection |
| [DISCORD](devdocs/DISCORD.md) | Discord messaging: webhooks, PU notifications, Intel dispatch |
| [MIGRATION](devdocs/MIGRATION.md) | Full migration reference: data model, all subsystems |
| [SYNTAX](devdocs/SYNTAX.md) | Code style guide: naming, .NET patterns, entity file syntax |
| [TESTING](devdocs/TESTING.md) | Test infrastructure: fixtures, loading patterns, mock strategies |

## License

See [LICENSE](LICENSE).
