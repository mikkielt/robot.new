# margoworld-datasource

Plugin for the Robot module that pulls canonical map data from [MargoWorld.pl](https://margoworld.pl). Replaces the legacy `invoke-mapcheckup-legacy.ps1` script.

**Version:** 0.1.0
**Scopes:** `entity:read`, `entity:write`
**Dependencies:** none

## What It Does

- Scrapes MargoWorld.pl for map names, CDN image URLs, and world minimap coordinates
- Maintains a local `maps.json` registry of all known maps
- Cross-references scraped data with Lokacja entities via `@margonemid` tags
- Writes `@koordynaty` tile coordinates onto entities with full temporal support
- Provides CLI workflows for all operations under the **Lokacje** menu

## Exported Functions

### Invoke-MargoWorldMapCheckup

Scrapes `/world/list` for all maps, visits each detail page to extract CDN image URLs.

```powershell
Invoke-MargoWorldMapCheckup [-Id <int[]>] [-DiffOnly] [-UpdateRegistry]
    [-SendDiscordNotification] [-ShowProgress] [-Quiet] [-WhatIf] [-Confirm]
```

| Parameter | Description |
|-----------|-------------|
| `-Id` | Filter to specific map IDs |
| `-DiffOnly` | Return only new/changed entries vs maps.json |
| `-UpdateRegistry` | Merge results into maps.json |
| `-SendDiscordNotification` | Send results via Discord webhook |
| `-ShowProgress` | Print progress to stdout |

Cross-references with `nerthusaddon-integration` plugin when loaded (flags `IsModifiedByNerthusAddon`).

### Get-MargoWorldMapList

Reads the local maps.json registry (or legacy maps.md) into structured objects.

```powershell
Get-MargoWorldMapList [-Path <string>] [-SourcePath <string>]
    [-GroupByFloor] [-DisambiguateNames] [-Quiet]
```

| Parameter | Description |
|-----------|-------------|
| `-Path` | Override path to maps.json |
| `-SourcePath` | Path to maps.md or maps.json (auto-detect by extension) |
| `-GroupByFloor` | Group results by base name (returns dictionary) |
| `-DisambiguateNames` | Append URL context to entries with ambiguous base names |

Returns objects with: `Id`, `Name`, `Url`, `LastChecked`, `FloorNumber`, `BaseName`.

### Get-MargoWorldLocationReport

Cross-references Lokacja entities with maps.json data by `@margonemid`.

```powershell
Get-MargoWorldLocationReport [-MapsJsonPath <string>] [-Entities <object[]>] [-Quiet]
```

Classifies every entity/map pair into one of four statuses:

| Status | Meaning |
|--------|---------|
| **Mapped** | Entity has `@margonemid` matching a maps.json entry |
| **Unmapped** | Entity has `@margonemid` but no maps.json entry |
| **Unregistered** | maps.json entry with no matching entity |
| **NoId** | Lokacja entity without any `@margonemid` |

Also identifies multi-floor groups and ambiguous groups (same base name, different physical locations).

### Invoke-MargoWorldMapCoordinates

Scrapes the `/world` page for CSS-positioned minimap elements, converts pixel positions to tile coordinates, and writes `@koordynaty` tags on matched Lokacja entities.

```powershell
Invoke-MargoWorldMapCoordinates [-Entities <object[]>] [-EntitiesFile <string>]
    [-ValidFrom <string>] [-Id <int[]>] [-ReportOnly] [-Quiet] [-WhatIf] [-Confirm]
```

| Parameter | Description |
|-----------|-------------|
| `-Entities` | Pre-fetched entity data (skips `Get-Entity` call) |
| `-EntitiesFile` | Override path to entities.md |
| `-ValidFrom` | Temporal validity start date (`YYYY-MM` format) |
| `-Id` | Filter to specific MargoWorld map IDs |
| `-ReportOnly` | Preview matches without writing changes |

**Coordinate conversion:** `TileX = floor(LeftPx / 32) + Padding`, same for Y. Default padding is 7 (configurable via `CoordPadding`).

**Entity matching:** looks up Lokacja entities by their `@margonemid` override values. Each match is classified as:

| Status | Action |
|--------|--------|
| **New** | Entity exists but has no `@koordynaty` — writes new tag via `Set-Entity` |
| **Changed** | Entity has different coordinates — closes old tag temporally, inserts new one |
| **Unchanged** | Coordinates already match — no write |

When a single entity has multiple `@margonemid` values, the first matching map's coordinates are used as canonical. A warning is emitted if different IDs yield different coordinates.

**Return object:**

```
ScrapedCount, MatchedCount, UnmatchedCount, NewCount, ChangedCount, UnchangedCount
Results = @( @{ EntityName; CN; MargonemId; MapName; ScrapedX; ScrapedY; ExistingX; ExistingY; Status } )
Unmatched = @( @{ Id; Name; TileX; TileY } )
```

### Set-MargoWorldMapTileData

Enriches maps.json entries with tile coordinates and dimensions for exterior maps by scraping the `/world` minimap and fetching PNG headers from the CDN.

```powershell
Set-MargoWorldMapTileData [-WorldMapData <object[]>] [-DiffOnly]
    [-ShowProgress] [-Quiet] [-WhatIf] [-Confirm]
```

| Parameter | Description |
|-----------|-------------|
| `-WorldMapData` | Pre-fetched `/world` minimap data (skips scrape) |
| `-DiffOnly` | Skip entries that already have `tileWidth` and `tileHeight` |
| `-ShowProgress` | Print progress to stdout |

Fetches each exterior map's CDN PNG header via HTTP Range request (bytes 0-31) to read pixel dimensions from the IHDR chunk, then divides by 32 to get tile counts. Merges `tileX`, `tileY`, `tileWidth`, `tileHeight` into maps.json entries. Interior maps pass through unchanged.

**Return object:**

```
TotalMaps, ExteriorCount, EnrichedCount, SkippedCount, FailedCount
Results = @( @{ Id; Name; TileX; TileY; TileWidth; TileHeight; WidthPx; HeightPx } )
Failed  = @( @{ Id; Name; Url } )
```

### ConvertTo-MapsJsonFromMarkdown

One-time migration from legacy `maps.md` to `maps.json` format.

```powershell
ConvertTo-MapsJsonFromMarkdown -SourcePath <string> [-DestinationPath <string>]
    [-Quiet] [-WhatIf] [-Confirm]
```

## Configuration

All config keys are optional. Set in `local.config.psd1` under the `margoworld-datasource` plugin section, or via environment variables where noted.

| Key | Default | Env Var | Description |
|-----|---------|---------|-------------|
| `MargoWorldDomain` | `https://margoworld.pl` | `ROBOT_MARGOWORLD_DOMAIN` | Base URL for scraping |
| `GarmoryDomain` | `https://micc.garmory-cdn.cloud` | `ROBOT_GARMORY_DOMAIN` | CDN base URL |
| `MapsJsonPath` | `{ResDir}/maps.json` | — | Path to maps.json registry |
| `MapsMarkdownPath` | — | — | Path to legacy maps.md (for migration) |
| `CoordPadding` | `7` | — | Tile offset added to pixel-to-tile coordinate conversion |

## CLI Menu Items

All items appear under the **Lokacje** menu in `Invoke-RobotCLI`:

| Menu Entry | Workflow | Description |
|------------|----------|-------------|
| Sprawdź mapy MargoWorld | `Invoke-MargoWorldCheckupWorkflow` | Scrape MargoWorld.pl and diff against maps.json |
| Lista map (rejestr) | `Invoke-MargoWorldMapListWorkflow` | Browse maps.json as interactive table |
| Raport mapowania lokacji | `Invoke-MargoWorldLocationReportWorkflow` | Cross-reference entities with maps.json |
| Migruj maps.md → maps.json | `Invoke-MargoWorldMigrateMapsWorkflow` | One-time legacy migration |
| Koordynaty z minimapy | `Invoke-MargoWorldCoordinatesWorkflow` | Scrape /world minimap coordinates |
| Wymiary tile map | `Invoke-MargoWorldTileDataWorkflow` | Fetch tile dimensions from PNG headers into maps.json |

## Internal Helpers

Private functions in `private/margoworld-helpers.ps1` (not exported):

| Function | Purpose |
|----------|---------|
| `Get-MargoWorldMapsJsonPath` | Resolves maps.json path from config or ResDir fallback |
| `Read-MargoWorldMapsJson` | Reads and validates maps.json |
| `Write-MargoWorldMapsJson` | Writes maps.json (UTF-8 no BOM) |
| `ConvertFrom-MargoWorldList` | Parses `/world/list` HTML into map entries (Id, Name, Slug) |
| `ConvertFrom-MargoWorldDetail` | Extracts CDN image URL from `/world/view/{id}` HTML |
| `ConvertFrom-MargoWorldMap` | Parses `/world` minimap HTML for positioned elements with pixel coordinates |
| `Get-MapBaseName` | Strips floor/room/direction/difficulty suffixes (9 iterative patterns) |
| `ConvertFrom-MapsMarkdown` | Parses legacy maps.md into maps.json structure |
| `Get-UrlLocationContext` | Extracts location slug from CDN URL for disambiguation |
| `ConvertFrom-PngHeaderBytes` | Parses PNG IHDR chunk to extract pixel dimensions and tile counts |
| `Get-PngTileDimensions` | Fetches PNG header via HTTP Range request for tile dimensions |
| `Close-TemporalTag` | Closes an open-ended temporal tag line by inserting a ValidTo date |

## File Layout

```
plugins/margoworld-datasource/
├── plugin.psd1                                  # Manifest
├── README.md                                    # This file
├── cli/
│   └── cli-wf-margoworld.ps1                    # CLI workflow functions (6)
├── private/
│   └── margoworld-helpers.ps1                   # Internal helpers (12 functions, 7 regex patterns)
├── public/
│   ├── Invoke-MargoWorldMapCheckup.ps1          # Scrape + diff maps
│   ├── Get-MargoWorldMapList.ps1                # Read maps.json registry
│   ├── Get-MargoWorldLocationReport.ps1         # Entity ↔ map cross-reference
│   ├── Invoke-MargoWorldMapCoordinates.ps1      # Scrape + write @koordynaty
│   ├── Set-MargoWorldMapTileData.ps1            # Enrich maps.json with tile dimensions
│   └── ConvertTo-MapsJsonFromMarkdown.ps1       # Legacy migration
└── tests/
    └── margoworld-datasource.Tests.ps1          # 57 Pester tests
```

## Data Files

| File | Written By | Read By |
|------|-----------|---------|
| `.robot/res/maps.json` | `Invoke-MargoWorldMapCheckup`, `ConvertTo-MapsJsonFromMarkdown`, `Set-MargoWorldMapTileData` | `Get-MargoWorldMapList`, `Get-MargoWorldLocationReport`, `Set-MargoWorldMapTileData` |

Entity data (`entities.md`, `*-*-ent.md`) is read via `Get-Entity` and written via `Set-Entity` / direct file manipulation by `Invoke-MargoWorldMapCoordinates`.

## Testing

```powershell
Invoke-Pester ./plugins/margoworld-datasource/tests/ -Output Detailed
```

57 test cases covering:
- `Get-MapBaseName` — 23 cases (9 suffix patterns, iterative stripping, edge cases)
- `ConvertFrom-MargoWorldList` — 3 cases (parsing, empty HTML, HTML entities)
- `ConvertFrom-MargoWorldDetail` — 2 cases (CDN URL extraction)
- `Read-MargoWorldMapsJson` / `Write-MargoWorldMapsJson` — 3 cases (roundtrip, BOM check, missing file)
- `Get-MargoWorldMapsJsonPath` — 1 case
- `ConvertFrom-MapsMarkdown` — 4 cases (dedup, collision, lastUpdated, missing file)
- `Get-UrlLocationContext` — 4 cases (CDN URL slug extraction, version stripping, floor markers)
- `ConvertTo-MapsJsonFromMarkdown` — 2 cases (end-to-end, WhatIf)
- `ConvertFrom-MargoWorldMap` — 6 cases (coordinate parsing, pixel-to-tile conversion, fractional values, custom padding, empty HTML, HTML decode)
- `ConvertFrom-PngHeaderBytes` — 5 cases (640x480, 1024x1024, non-PNG, truncated, custom tile size)
- `Close-TemporalTag` — 3 cases (open-ended, no suffix, already closed)
- Disambiguation — 1 case
