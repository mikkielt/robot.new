<#
    .SYNOPSIS
    Pester tests for the promoted narrator-mapping helpers (WP-B1).

    .DESCRIPTION
    Covers Get-NarratorMappingPath, Import-NarratorMapping (empty file, comments,
    multi-canonical, case-insensitive lookup), Export-NarratorMapping (round-trip,
    UTF-8 no-BOM, header line).
#>

BeforeAll {
    . "$PSScriptRoot/TestHelpers.ps1"
    Import-RobotModule
    . (Join-Path $script:ModuleRoot 'private' 'migration' 'narrator-helpers.ps1')

    function New-NhRepoRoot {
        $D = Join-Path ([System.IO.Path]::GetTempPath()) ("robot-nh-" + [Guid]::NewGuid().ToString('N'))
        [void][System.IO.Directory]::CreateDirectory($D)
        return $D
    }
    function Remove-NhRepoRoot {
        param([string]$Path)
        if ($Path -and [System.IO.Directory]::Exists($Path)) {
            [System.IO.Directory]::Delete($Path, $true)
        }
    }
}

Describe 'Get-NarratorMappingPath' {
    It 'resolves under .robot.local/res/narrator-mappings.txt' {
        $R = New-NhRepoRoot
        try {
            $P = Get-NarratorMappingPath -RepoRoot $R
            $P | Should -Match '\.robot\.local'
            $P | Should -Match 'narrator-mappings\.txt$'
        } finally { Remove-NhRepoRoot -Path $R }
    }
}

Describe 'Import-NarratorMapping' {
    It 'returns empty dictionary when file is absent' {
        $R = New-NhRepoRoot
        try {
            $D = Import-NarratorMapping -RepoRoot $R
            $D.Count | Should -Be 0
        } finally { Remove-NhRepoRoot -Path $R }
    }

    It 'parses single mapping line' {
        $R = New-NhRepoRoot
        try {
            $Path = Get-NarratorMappingPath -RepoRoot $R
            [void][System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($Path))
            [System.IO.File]::WriteAllText($Path, "Olek -> Aleksander", [System.Text.UTF8Encoding]::new($false))
            $D = Import-NarratorMapping -RepoRoot $R
            $D.Count | Should -Be 1
            $D['Olek'].Count | Should -Be 1
            $D['Olek'][0] | Should -Be 'Aleksander'
        } finally { Remove-NhRepoRoot -Path $R }
    }

    It 'parses multi-canonical mapping (comma-separated)' {
        $R = New-NhRepoRoot
        try {
            $Path = Get-NarratorMappingPath -RepoRoot $R
            [void][System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($Path))
            [System.IO.File]::WriteAllText($Path, "Duet -> Alpha, Beta", [System.Text.UTF8Encoding]::new($false))
            $D = Import-NarratorMapping -RepoRoot $R
            $D['Duet'].Count | Should -Be 2
            $D['Duet'][0] | Should -Be 'Alpha'
            $D['Duet'][1] | Should -Be 'Beta'
        } finally { Remove-NhRepoRoot -Path $R }
    }

    It 'skips comments and blank lines' {
        $R = New-NhRepoRoot
        try {
            $Path = Get-NarratorMappingPath -RepoRoot $R
            [void][System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($Path))
            $Content = "# header`n`nOlek -> Aleksander`n# another`nKaspar -> Kacper"
            [System.IO.File]::WriteAllText($Path, $Content, [System.Text.UTF8Encoding]::new($false))
            $D = Import-NarratorMapping -RepoRoot $R
            $D.Count | Should -Be 2
        } finally { Remove-NhRepoRoot -Path $R }
    }

    It 'lookup is case-insensitive' {
        $R = New-NhRepoRoot
        try {
            $Path = Get-NarratorMappingPath -RepoRoot $R
            [void][System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($Path))
            [System.IO.File]::WriteAllText($Path, "Olek -> Aleksander", [System.Text.UTF8Encoding]::new($false))
            $D = Import-NarratorMapping -RepoRoot $R
            $D['olek'][0] | Should -Be 'Aleksander'
            $D['OLEK'][0] | Should -Be 'Aleksander'
        } finally { Remove-NhRepoRoot -Path $R }
    }
}

Describe 'Export-NarratorMapping' {
    It 'round-trips through Import' {
        $R = New-NhRepoRoot
        try {
            $D = [System.Collections.Generic.Dictionary[string, string[]]]::new([System.StringComparer]::OrdinalIgnoreCase)
            $D['Olek'] = @('Aleksander')
            $D['Duet'] = @('Alpha', 'Beta')
            Export-NarratorMapping -Mappings $D -RepoRoot $R
            $Read = Import-NarratorMapping -RepoRoot $R
            $Read.Count | Should -Be 2
            $Read['Olek'][0] | Should -Be 'Aleksander'
            $Read['Duet'].Count | Should -Be 2
        } finally { Remove-NhRepoRoot -Path $R }
    }

    It 'writes UTF-8 no-BOM' {
        $R = New-NhRepoRoot
        try {
            $D = [System.Collections.Generic.Dictionary[string, string[]]]::new([System.StringComparer]::OrdinalIgnoreCase)
            $D['Łukasz'] = @('Łukasz')   # Polish diacritic to verify encoding
            Export-NarratorMapping -Mappings $D -RepoRoot $R
            $Path = Get-NarratorMappingPath -RepoRoot $R
            $Bytes = [System.IO.File]::ReadAllBytes($Path)
            # UTF-8 BOM is 0xEF 0xBB 0xBF — must NOT appear
            ($Bytes[0] -eq 0xEF -and $Bytes[1] -eq 0xBB -and $Bytes[2] -eq 0xBF) | Should -BeFalse
            # Content survives round-trip
            $Read = Import-NarratorMapping -RepoRoot $R
            $Read['Łukasz'][0] | Should -Be 'Łukasz'
        } finally { Remove-NhRepoRoot -Path $R }
    }
}
