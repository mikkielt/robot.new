<#
    .SYNOPSIS
    Pester tests for migration artifact I/O (WP-A2).

    .DESCRIPTION
    Covers Resolve-MigrationArtifactPath, Get-MigrationArtifact,
    Set-MigrationArtifact, and Save-MigrationPreviewCache.
#>

BeforeAll {
    . "$PSScriptRoot/TestHelpers.ps1"
    Import-RobotModule
    . (Join-Path $script:ModuleRoot 'private' 'admin-state.ps1')
    . (Join-Path $script:ModuleRoot 'private' 'migration' 'migration-artifact.ps1')

    function New-ArtifactRepoRoot {
        $D = Join-Path ([System.IO.Path]::GetTempPath()) ("robot-art-" + [Guid]::NewGuid().ToString('N'))
        [void][System.IO.Directory]::CreateDirectory($D)
        return $D
    }
    function Remove-ArtifactRepoRoot {
        param([string]$Path)
        if ($Path -and [System.IO.Directory]::Exists($Path)) {
            [System.IO.Directory]::Delete($Path, $true)
        }
    }
}

Describe 'Resolve-MigrationArtifactPath' {
    It 'builds the expected path under .robot.local/migration-artifacts' {
        $R = New-ArtifactRepoRoot
        try {
            $Path = Resolve-MigrationArtifactPath -MigrationId '0.3.0-validate-parity' -Name 'brak-characters' -RepoRoot $R
            $Path | Should -Match '\.robot\.local'
            $Path | Should -Match '0\.3\.0-validate-parity'
            $Path | Should -Match 'brak-characters\.json$'
        } finally { Remove-ArtifactRepoRoot -Path $R }
    }
}

Describe 'Set-MigrationArtifact / Get-MigrationArtifact (round-trip)' {
    It 'writes and reads a hashtable artifact' {
        $R = New-ArtifactRepoRoot
        try {
            $Data = @{ Characters = @('Alpha', 'Beta'); Count = 2 }
            $WriteResult = Set-MigrationArtifact -SourceMigration '0.3.0-test' -Name 'sample' -Value $Data -RepoRoot $R -Confirm:$false
            $WriteResult.Path | Should -Exist
            $Read = Get-MigrationArtifact -SourceMigration '0.3.0-test' -Name 'sample' -RepoRoot $R
            $Read.Count | Should -Be 2
            $Read.Characters.Count | Should -Be 2
            $Read.Characters[0] | Should -Be 'Alpha'
        } finally { Remove-ArtifactRepoRoot -Path $R }
    }

    It 'creates the artifact subtree on demand' {
        $R = New-ArtifactRepoRoot
        try {
            $Dir = [System.IO.Path]::Combine($R, '.robot.local', 'migration-artifacts')
            [System.IO.Directory]::Exists($Dir) | Should -BeFalse
            Set-MigrationArtifact -SourceMigration '0.1.0-x' -Name 'y' -Value @{ Hi = 1 } -RepoRoot $R -Confirm:$false | Out-Null
            [System.IO.Directory]::Exists([System.IO.Path]::Combine($Dir, '0.1.0-x')) | Should -BeTrue
        } finally { Remove-ArtifactRepoRoot -Path $R }
    }

    It 'throws MigrationArtifactNotFound when missing' {
        $R = New-ArtifactRepoRoot
        try {
            { Get-MigrationArtifact -SourceMigration 'nope' -Name 'absent' -RepoRoot $R } | Should -Throw
        } finally { Remove-ArtifactRepoRoot -Path $R }
    }

    It 'overwrites cleanly (atomic temp+bak swap)' {
        $R = New-ArtifactRepoRoot
        try {
            Set-MigrationArtifact -SourceMigration '0.5.0-x' -Name 'art' -Value @{ V = 1 } -RepoRoot $R -Confirm:$false | Out-Null
            Set-MigrationArtifact -SourceMigration '0.5.0-x' -Name 'art' -Value @{ V = 2 } -RepoRoot $R -Confirm:$false | Out-Null
            $Read = Get-MigrationArtifact -SourceMigration '0.5.0-x' -Name 'art' -RepoRoot $R
            $Read.V | Should -Be 2
        } finally { Remove-ArtifactRepoRoot -Path $R }
    }
}

Describe 'Save-MigrationPreviewCache' {
    It 'extracts OverrideKeys from ChangeRecord hashtables' {
        $R = New-ArtifactRepoRoot
        try {
            $Records = @(
                @{ Id = 'A'; OverrideKey = 'key:A'; ChangeKind = 'Modify' }
                @{ Id = 'B'; OverrideKey = 'key:B'; ChangeKind = 'Modify' }
                @{ Id = 'C'; ChangeKind = 'Delete' }     # no OverrideKey
            )
            Save-MigrationPreviewCache -MigrationId '0.4.0-import' -ChangeRecords $Records -RepoRoot $R | Out-Null
            $Cache = Get-MigrationArtifact -SourceMigration '0.4.0-import' -Name '.preview-cache' -RepoRoot $R
            $Cache.ChangeRecordCount | Should -Be 3
            $Cache.OverrideKeys.Count | Should -Be 2
            $Cache.OverrideKeys -contains 'key:A' | Should -BeTrue
            $Cache.OverrideKeys -contains 'key:B' | Should -BeTrue
        } finally { Remove-ArtifactRepoRoot -Path $R }
    }

    It 'handles PSCustomObject ChangeRecords' {
        $R = New-ArtifactRepoRoot
        try {
            $Records = @(
                [PSCustomObject]@{ Id = 'X'; OverrideKey = 'key:X'; ChangeKind = 'Create' }
            )
            Save-MigrationPreviewCache -MigrationId '0.6.0-x' -ChangeRecords $Records -RepoRoot $R | Out-Null
            $Cache = Get-MigrationArtifact -SourceMigration '0.6.0-x' -Name '.preview-cache' -RepoRoot $R
            $Cache.OverrideKeys.Count | Should -Be 1
            $Cache.OverrideKeys[0] | Should -Be 'key:X'
        } finally { Remove-ArtifactRepoRoot -Path $R }
    }
}

Describe 'Public cmdlet exports' -Tag 'Integration' {
    It 'exports Get-MigrationArtifact and Set-MigrationArtifact' {
        Get-Command -Module Robot.PowerShell -Name 'Get-MigrationArtifact' -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        Get-Command -Module Robot.PowerShell -Name 'Set-MigrationArtifact' -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }
}
