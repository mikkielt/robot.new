# Syntax & Comment Style Guide

## Comment Styles

### File-Level Documentation

Every `.ps1` file opens with a `<# ... #>` block comment containing `.SYNOPSIS` and `.DESCRIPTION` sections. This block appears before any code and describes the file's purpose, its helpers, module-level data, and architectural rationale.

```powershell
<#
    .SYNOPSIS
    One-line summary of what the file provides.

    .DESCRIPTION
    This file contains FunctionName and its helpers:

    Helpers:
    - HelperName: brief description of what the helper does

    Module-level data:
    - $VariableName: what it stores and why

    Multi-paragraph explanation of the function's design, processing
    pipeline, and key implementation decisions.
#>
```

### Function-Level Documentation

Exported functions (Verb-Noun) carry a minimal `<# .SYNOPSIS #>` block inside the function body, immediately after the opening brace. Helpers do not repeat a block comment - their purpose is documented in the file-level `.DESCRIPTION`.

```powershell
function Get-Example {
    <#
        .SYNOPSIS
        One-line summary of what the function does.
    #>

    [CmdletBinding()] param(
        ...
    )
    ...
}
```

### Section Comments

Single-line `#` comments precede logical code blocks to explain intent or group related operations. They describe *why*, not *what*.

```powershell
# Build parent->children lookup in one pass (avoids O(n²) repeated .Where() filtering)
$ChildrenOf = @{}
```

### Inline Comments

End-of-line `#` comments clarify non-obvious values, flags, or decisions.

```powershell
$ParallelThreshold = 4  # RunspacePool setup has fixed overhead (~50ms)
```

### Warning/Error Messages

Warnings to stderr use a `[WARN FunctionName]` prefix pattern:

```powershell
[System.Console]::Error.WriteLine("[WARN Get-Entity] Cycle detected in @lokacja chain for '$($Entity.Name)'")
```

---

## Naming Conventions

### Variables

PascalCase for all variables, no exceptions:

```powershell
$CurrentDir        # local variable
$RepoRoot          # local variable
$AllResults        # local variable
$script:ModuleRoot # script-scoped variable
```

Script-scope (`$script:`) is used for module-level data shared across functions within the same file or module.

### Functions

Verb-Noun pattern with approved verbs (`Get`, `Set`, `New`, `Remove`, `Resolve`, `Test`, `Invoke`):

```powershell
Get-RepoRoot
Get-Markdown
Resolve-Name
Get-NameIndex
```

Helpers also follow Verb-Noun or descriptive Verb-Object naming:

```powershell
Complete-PUData
ConvertFrom-ValidityString
Add-BKTreeNode
Search-BKTree
Test-TemporalActivity
```

### Parameters

PascalCase, typed, with `[Parameter()]` attributes containing `HelpMessage`:

```powershell
[Parameter(Mandatory, HelpMessage = "Name string to resolve")]
[string]$Query,

[Parameter(HelpMessage = "Pre-fetched player roster from Get-Player")]
[object[]]$Players
```

---

## Code Patterns

### .NET Over Cmdlets

The codebase prefers .NET static methods over PowerShell cmdlets for performance and cross-platform consistency:

```powershell
# File I/O
[System.IO.File]::ReadAllLines($FilePath)
[System.IO.File]::Exists($Path)
[System.IO.Directory]::GetFiles($Dir, "*.md", [System.IO.SearchOption]::AllDirectories)
[System.IO.Directory]::Exists($Path)
[System.IO.Path]::Combine($A, $B)
[System.IO.Path]::GetFileName($FilePath)
[System.IO.Path]::GetFileNameWithoutExtension($FilePath)

# String operations
[string]::IsNullOrWhiteSpace($Value)
[string]::Equals($A, $B, [System.StringComparison]::OrdinalIgnoreCase)

# Collections
[System.Collections.Generic.List[object]]::new()
[System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::OrdinalIgnoreCase)
[System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
[System.Collections.Generic.Stack[object]]::new()
[System.Collections.Generic.Queue[string]]::new()

# StringBuilder
[System.Text.StringBuilder]::new()

# Regex
[regex]::new($Pattern, [System.Text.RegularExpressions.RegexOptions]::Compiled)

# Process execution
[System.Diagnostics.ProcessStartInfo]::new()
[System.Diagnostics.Process]::new()

# Date parsing
[datetime]::TryParseExact($Str, "yyyy-MM-dd", [System.Globalization.CultureInfo]::InvariantCulture, ...)
[System.DateTimeOffset]::Parse($DateString, [System.Globalization.CultureInfo]::InvariantCulture)
```

### Output Suppression

`[void]` cast is used to suppress unwanted return values:

```powershell
[void]$CurrentSectionContent.Append($Line).Append("`n")
[void]$FilesToProcess.Add($FilePath)
[void]$ExcludedListItems.Add($LIId)
```

### Object Creation

`[PSCustomObject]@{}` for structured output objects:

```powershell
$HeaderObj = [PSCustomObject]@{
    Level        = $Level
    Text         = $Text
    ParentHeader = $ParentHeader
    LineNumber   = $LineNumber
}
```

`[ordered]@{}` for hashtables where key order matters:

```powershell
$SessionProps = [ordered]@{
    FilePath  = $FilePath
    Header    = $Header
    Date      = $DateInfo.Date
    ...
}
```

### String Comparison

Case-insensitive comparison uses .NET comparers, not `-ieq` (except for simple guards):

```powershell
# Dictionary/HashSet construction
[System.StringComparer]::OrdinalIgnoreCase

# Explicit string comparison
[string]::Equals($A, $B, [System.StringComparison]::OrdinalIgnoreCase)

# String methods with comparison type
$Text.EndsWith($Suffix, [System.StringComparison]::OrdinalIgnoreCase)
$Text.StartsWith($Prefix)  # ordinal by default, acceptable for known-ASCII prefixes
```

`-ieq` is used for simple single-value guards:

```powershell
if ($FileName -ieq 'robot.psm1') { continue }
```

### Parameter Declarations

`[CmdletBinding()]` precedes `param()` on the same line for exported functions. Parameters include type annotations and validation:

```powershell
[CmdletBinding()] param(
    [Parameter(ParameterSetName = "File", HelpMessage = "...")] [ValidateScript({
        ...
    })]
    [string[]]$File,

    [Parameter(Mandatory, HelpMessage = "...")]
    [string]$Query,

    [Parameter(HelpMessage = "...")]
    [ValidateSet("Player", "NPC", "Organizacja", "Lokacja")]
    [string]$OwnerType
)
```

Standalone scripts use bare `param()`:

```powershell
param([string]$FilePath)
```

### Return Convention

Explicit `return` keyword is always used:

```powershell
return $CurrentDir          # single value
return $AllResults          # List/collection
return @{                   # hashtable
    Index     = $Index
    StemIndex = $StemIndex
    BKTree    = $BKTree
}
```

Single-item results from `-File` parameter sets are returned unwrapped (not in a list):

```powershell
if ($FilesToProcess.Count -eq 1 -and $PSCmdlet.ParameterSetName -eq "File") {
    return $AllResults[0]
} else {
    return $AllResults
}
```

### Error Handling

`throw` for fatal/unrecoverable errors:

```powershell
throw "No git repository found in any parent directory."
throw "Directory is outside repository."
```

`try/catch` with `continue` for non-fatal per-item failures:

```powershell
try {
    . "$FilePath"
} catch {
    [System.Console]::Error.WriteLine("Failed to load function file '$FileName': $_")
    continue
}
```

`[System.Console]::Error.WriteLine()` for warnings that should not interrupt execution:

```powershell
[System.Console]::Error.WriteLine("[WARN Get-EntityState] Unresolved entity '$($Change.EntityName)' in session '$($Session.Header)'")
```

`$PSCmdlet.ThrowTerminatingError()` with structured `ErrorRecord` for fail-early validation errors where the caller needs to inspect structured data:

```powershell
# Build structured data that callers can extract from TargetObject
$UnresolvedList = @(
    [PSCustomObject]@{ CharacterName = $Name; Sessions = $Headers }
)

$ErrorRecord = [System.Management.Automation.ErrorRecord]::new(
    [System.InvalidOperationException]::new("Unresolved character name(s): '$Names'"),
    'UnresolvedPUCharacters',                                  # ErrorId (used by callers to identify the error type)
    [System.Management.Automation.ErrorCategory]::InvalidData,
    $UnresolvedList                                            # TargetObject (structured data for callers)
)
$PSCmdlet.ThrowTerminatingError($ErrorRecord)
```

Callers catch by matching `FullyQualifiedErrorId` and extract `TargetObject`:

```powershell
try {
    $Results = Invoke-PlayerCharacterPUAssignment @Params -WhatIf
} catch {
    if ($_.FullyQualifiedErrorId -eq 'UnresolvedPUCharacters,Invoke-PlayerCharacterPUAssignment') {
        $UnresolvedData = $_.TargetObject  # structured array from the throw site
    } else {
        throw  # re-throw unexpected errors
    }
}
```

### Caching and Memoization

Caches use `[hashtable]` with `[DBNull]::Value` as a sentinel for "looked up, found nothing":

```powershell
if ($Cache -and $Cache.ContainsKey($CacheKey)) {
    $Cached = $Cache[$CacheKey]
    if ($Cached -is [System.DBNull]) { return $null }
    return $Cached
}

# ... resolution logic ...

# Cache miss sentinel
if ($Cache) { $Cache[$CacheKey] = [System.DBNull]::Value }
```

### Precompiled Regex

Regex patterns used across multiple calls are compiled and stored at script scope or as local variables before loops:

```powershell
# Script-scope (shared across function calls within the module)
$script:ValidityPattern = [regex]::new('^(.*?)(?:\s*\(([^:)]*):([^)]*)\))?$', [System.Text.RegularExpressions.RegexOptions]::Compiled)

# Local (shared across iterations within a function)
$CommitRegex = [regex]'^COMMIT\x1F(.+?)\x1F(.+?)\x1F(.+?)\x1F(.+)$'
$MdLinkPattern = [regex]'\[(.+?)\]\((.+?)\)'
```

### Identity-Based Lookups

`RuntimeHelpers.GetHashCode()` is used to get stable object identity hashes for parent-child lookups:

```powershell
$ParentId = [System.Runtime.CompilerServices.RuntimeHelpers]::GetHashCode($LI.ParentListItem)
if (-not $ChildrenOf.ContainsKey($ParentId)) {
    $ChildrenOf[$ParentId] = [System.Collections.Generic.List[object]]::new()
}
$ChildrenOf[$ParentId].Add($LI)
```

---

## Entity File Syntax (Markdown)

Entity registry files (`entities.md`, `*-NNN-ent.md`) use a structured Markdown format:

### Section Headers

Level-2 headers define entity type sections:

```markdown
## NPC
## Organizacja
## Lokacja
## Gracz
## Postać
```

### Entity Declarations

Top-level bullet items declare entities:

```markdown
* Sandro
* Nocturnus Oris Custodia
* Erathia
```

### @Tag Metadata

Nested bullets with `@tag: value` syntax attach metadata to entities:

```markdown
* Sandro
    - @alias: Mroczny Mag
    - @lokacja: Erathia (2021-01:2024-06)
    - @lokacja: Bracada (2024-07:)
    - @grupa: Bractwo Miecza (2021-01:)
```

### Temporal Validity Ranges

Values support optional `(YYYY-MM:YYYY-MM)` or `(YYYY-MM:)` or `(:YYYY-MM)` suffixes for time-scoping:

```markdown
- @alias: Lich z Deyji (2023-01:2024-06)   # active Jan 2023 – Jun 2024
- @lokacja: Bracada (2024-07:)                   # active from Jul 2024 onward
- @alias: Władca Deyji (:2024-03)            # active until Mar 2024
```

Partial dates are supported: `YYYY` (full year), `YYYY-MM` (full month), `YYYY-MM-DD` (exact day).

### Recognized @Tags

| Tag           | Description                                      |
|---------------|--------------------------------------------------|
| `@alias`      | Time-scoped alternative name                     |
| `@lokacja`    | Time-scoped location assignment / containment     |
| `@drzwi`      | Time-scoped physical access connection            |
| `@zawiera`    | Declares child containment (no temporal scope)    |
| `@typ`        | Time-scoped entity type override                  |
| `@należy_do`  | Time-scoped ownership (entity -> player)           |
| `@grupa`      | Time-scoped group/faction membership              |
| Any other     | Generic override stored in Overrides dictionary   |

### Multi-line Values

Some tags accept nested bullets for multi-line content:

```markdown
* Lord Haart
    - @info:
        - Były rycerz, podniesiony jako Rycerz Śmierci
        - Dowodzi legionem nieumarłych
```

---

## Module Manifest (.psd1)

The manifest uses PowerShell data syntax (`@{ }`) with inline `#` comments for field documentation:

```powershell
@{
    # Script module or binary module file associated with this manifest
    RootModule = 'Robot.psm1'

    # Version number of this module
    ModuleVersion = '1.0.0'

    FunctionsToExport = '*'
    CmdletsToExport = @()
    VariablesToExport = @()
    AliasesToExport = @()
}
```

---

## Module Loader (.psm1)

The root module uses the same file-level `<# .SYNOPSIS .DESCRIPTION #>` block comment as `.ps1` files. It auto-discovers Verb-Noun `.ps1` files via .NET directory enumeration and dot-sources them:

```powershell
$VerbNounPattern = [regex]::new('^(Get|Set|New|Remove|Resolve|Test|Invoke)-\w+$', ...)

foreach ($FilePath in $FunctionFiles) {
    $FuncName = [System.IO.Path]::GetFileNameWithoutExtension($FilePath)
    if (-not $VerbNounPattern.IsMatch($FuncName)) { continue }
    . "$FilePath"
    $ExportedFunctions.Add($FuncName)
}

Export-ModuleMember -Function $ExportedFunctions
```

Non-Verb-Noun scripts (e.g., `private/parse-markdownfile.ps1`) are helper scripts loaded on demand by consuming functions, not at module import time.
