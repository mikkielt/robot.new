<#
    .SYNOPSIS
    Narrator normalization file helpers for migration.

    .DESCRIPTION
    Non-exported helpers consumed by migration-phases.ps1 and Set-Session
    via dot-sourcing. Manages the narrator-mappings.txt file that maps
    raw session header narrator text to canonical player names.

    File format (narrator-mappings.txt):
        raw narrator text -> Canonical1, Canonical2

    Helpers:
    - Get-NarratorMappingsPath: returns path to narrator-mappings.txt
    - Import-NarratorMappings:  reads file into Dictionary[string, string[]]
    - Export-NarratorMappings:  writes Dictionary to file
#>

function Get-NarratorMappingsPath {
    $RepoRoot = Get-RepoRoot
    return [System.IO.Path]::Combine($RepoRoot, '.robot', 'res', 'narrator-mappings.txt')
}

function Import-NarratorMappings {
    param(
        [string]$Path
    )

    if (-not $Path) {
        $Path = Get-NarratorMappingsPath
    }

    $Dict = [System.Collections.Generic.Dictionary[string, string[]]]::new([System.StringComparer]::OrdinalIgnoreCase)

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
                $Canonicals.Add($PartTrimmed)
            }
        }

        if ($Canonicals.Count -gt 0) {
            $Dict[$RawKey] = $Canonicals.ToArray()
        }
    }

    return $Dict
}

function Export-NarratorMappings {
    param(
        [Parameter(Mandatory)]
        [System.Collections.Generic.Dictionary[string, string[]]]$Mappings,

        [string]$Path
    )

    if (-not $Path) {
        $Path = Get-NarratorMappingsPath
    }

    $Dir = [System.IO.Path]::GetDirectoryName($Path)
    if (-not [System.IO.Directory]::Exists($Dir)) {
        [void][System.IO.Directory]::CreateDirectory($Dir)
    }

    $Lines = [System.Collections.Generic.List[string]]::new($Mappings.Count + 2)
    $Lines.Add('# Normalizacja narratorów - mapowanie z nagłówka sesji na kanoniczne nazwy')
    $Lines.Add('')

    $SortedKeys = [System.Linq.Enumerable]::OrderBy($Mappings.Keys, [System.Func[string, string]]{ param($K) $K })
    foreach ($Key in $SortedKeys) {
        $Values = $Mappings[$Key]
        $Lines.Add("$Key -> $($Values -join ', ')")
    }

    [System.IO.File]::WriteAllLines($Path, $Lines, [System.Text.UTF8Encoding]::new($false))
}
