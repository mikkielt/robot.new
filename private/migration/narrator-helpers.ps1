<#
    .SYNOPSIS
    Narrator-mapping file helpers.

    .DESCRIPTION
    Non-exported helpers consumed by Phase E (0.3.x — validate-parity migrations)
    and Phase H (0.6.x — session upgrade migrations). Promoted into the framework
    so multiple sibling migrations can share the helper without duplicating ~95 LOC.

    The original plural-noun forms (`Import-NarratorMappings` / `Export-NarratorMappings`)
    were renamed to singular-noun + verb per project conventions:
    `Import-NarratorMapping` / `Export-NarratorMapping` / `Get-NarratorMappingPath`.

    File format (narrator-mappings.txt):
        raw narrator text -> Canonical1, Canonical2

    Helpers:
    - Get-NarratorMappingPath: returns path to narrator-mappings.txt under
                               .robot.local/res/.
    - Import-NarratorMapping:  reads file into Dictionary[string, string[]].
    - Export-NarratorMapping:  writes Dictionary to file (UTF-8 no-BOM).

    Module-level data: none.

    Design:
    - The path is resolved via Get-RepoRoot + the standard .robot.local/res
      location. The helper is portable across micro-migrations that don't
      carry phase-state.
    - Comparer is OrdinalIgnoreCase so narrator-text variants ("Olek" vs "olek")
      collapse to one mapping entry.

    Dependencies: Get-RepoRoot (private/get-reporoot.ps1).
#>

function Get-NarratorMappingPath {
    [CmdletBinding()]
    param(
        [string]$RepoRoot
    )

    if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
        $RepoRoot = Get-RepoRoot
    }
    return [System.IO.Path]::Combine($RepoRoot, '.robot.local', 'res', 'narrator-mappings.txt')
}

function Import-NarratorMapping {
    [CmdletBinding()]
    param(
        [string]$Path,
        [string]$RepoRoot
    )

    if (-not $Path) {
        $Path = Get-NarratorMappingPath -RepoRoot $RepoRoot
    }

    $Dict = [System.Collections.Generic.Dictionary[string, string[]]]::new(
        [System.StringComparer]::OrdinalIgnoreCase)

    if (-not [System.IO.File]::Exists($Path)) {
        return $Dict
    }

    foreach ($Line in [System.IO.File]::ReadAllLines($Path)) {
        $Trimmed = $Line.Trim()
        if ($Trimmed.Length -eq 0 -or $Trimmed.StartsWith('#')) { continue }

        $ArrowIdx = $Trimmed.IndexOf(' -> ')
        if ($ArrowIdx -lt 0) { continue }

        $RawKey = $Trimmed.Substring(0, $ArrowIdx).Trim()
        $ValueStr = $Trimmed.Substring($ArrowIdx + 4).Trim()

        if ($RawKey.Length -eq 0 -or $ValueStr.Length -eq 0) { continue }

        $Canonicals = [System.Collections.Generic.List[string]]::new()
        foreach ($Part in $ValueStr.Split(',')) {
            $PartTrimmed = $Part.Trim()
            if ($PartTrimmed.Length -gt 0) {
                [void]$Canonicals.Add($PartTrimmed)
            }
        }

        if ($Canonicals.Count -gt 0) {
            $Dict[$RawKey] = $Canonicals.ToArray()
        }
    }

    return $Dict
}

function Export-NarratorMapping {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.Generic.Dictionary[string, string[]]]$Mappings,

        [string]$Path,
        [string]$RepoRoot
    )

    if (-not $Path) {
        $Path = Get-NarratorMappingPath -RepoRoot $RepoRoot
    }

    $Dir = [System.IO.Path]::GetDirectoryName($Path)
    if (-not [System.IO.Directory]::Exists($Dir)) {
        [void][System.IO.Directory]::CreateDirectory($Dir)
    }

    $Lines = [System.Collections.Generic.List[string]]::new($Mappings.Count + 2)
    [void]$Lines.Add('# Narrator-name normalization: raw header text -> canonical player names')
    [void]$Lines.Add('')

    $SortedKeys = [System.Linq.Enumerable]::OrderBy(
        $Mappings.Keys, [System.Func[string, string]]{ param($K) $K })
    foreach ($Key in $SortedKeys) {
        $Values = $Mappings[$Key]
        [void]$Lines.Add("$Key -> $($Values -join ', ')")
    }

    [System.IO.File]::WriteAllLines($Path, $Lines, [System.Text.UTF8Encoding]::new($false))
}
