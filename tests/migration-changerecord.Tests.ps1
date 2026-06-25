<#
    .SYNOPSIS
    Pester tests for ChangeRecord factory and validators (WP-A7).

    .DESCRIPTION
    Covers New-MigrationChangeRecord (mandatory params, enum validation,
    rename requires NewFilePath), Test-MigrationChangeRecord (single-record
    shape), and Test-MigrationChangeRecordSet (cross-record uniqueness).
#>

BeforeAll {
    . "$PSScriptRoot/TestHelpers.ps1"
    Import-RobotModule
    . (Join-Path $script:ModuleRoot 'private' 'migration' 'migration-changerecord.ps1')
}

Describe 'New-MigrationChangeRecord' {
    It 'builds a minimal record' {
        $R = New-MigrationChangeRecord -Id 'a' -ObjectType 'EntityBullet' -ChangeKind 'Modify' -FilePath 'entities.md'
        $R.Id | Should -Be 'a'
        $R.ObjectType | Should -Be 'EntityBullet'
        $R.NewFilePath | Should -BeNullOrEmpty
        $R.OverrideKey | Should -BeNullOrEmpty
        $R.Notes.Count | Should -Be 0
    }

    It 'accepts Before/After/OverrideKey/Notes' {
        $R = New-MigrationChangeRecord -Id 'b' -ObjectType 'EntityBullet' -ChangeKind 'Modify' -FilePath 'entities.md' `
            -Before 'old' -After 'new' -OverrideKey 'k:b' -Notes @('hint1','hint2')
        $R.Before | Should -Be 'old'
        $R.After | Should -Be 'new'
        $R.OverrideKey | Should -Be 'k:b'
        $R.Notes.Count | Should -Be 2
    }

    It 'rejects unknown ChangeKind' {
        { New-MigrationChangeRecord -Id 'c' -ObjectType 'EntityBullet' -ChangeKind 'Mutate' -FilePath 'x' } | Should -Throw
    }

    It 'rejects unknown ObjectType' {
        { New-MigrationChangeRecord -Id 'd' -ObjectType 'Unknown' -ChangeKind 'Modify' -FilePath 'x' } | Should -Throw
    }

    It 'requires NewFilePath when ChangeKind is Rename' {
        { New-MigrationChangeRecord -Id 'e' -ObjectType 'FilePath' -ChangeKind 'Rename' -FilePath 'a.md' } | Should -Throw
        $R = New-MigrationChangeRecord -Id 'e' -ObjectType 'FilePath' -ChangeKind 'Rename' -FilePath 'a.md' -NewFilePath 'b.md'
        $R.NewFilePath | Should -Be 'b.md'
    }
}

Describe 'Test-MigrationChangeRecord' {
    It 'OK on well-formed record' {
        $R = New-MigrationChangeRecord -Id 'a' -ObjectType 'EntityBullet' -ChangeKind 'Modify' -FilePath 'entities.md'
        (Test-MigrationChangeRecord -Record $R).OK | Should -BeTrue
    }

    It 'fails on missing Id (hashtable form)' {
        $R = @{ ObjectType = 'EntityBullet'; ChangeKind = 'Modify'; FilePath = 'x' }
        (Test-MigrationChangeRecord -Record $R).OK | Should -BeFalse
    }

    It 'fails on unknown ChangeKind (hashtable form)' {
        $R = @{ Id = 'a'; ObjectType = 'EntityBullet'; ChangeKind = 'Mutate'; FilePath = 'x' }
        (Test-MigrationChangeRecord -Record $R).OK | Should -BeFalse
    }

    It 'fails on Rename without NewFilePath' {
        $R = @{ Id = 'a'; ObjectType = 'FilePath'; ChangeKind = 'Rename'; FilePath = 'x' }
        (Test-MigrationChangeRecord -Record $R).OK | Should -BeFalse
    }
}

Describe 'Test-MigrationChangeRecordSet' {
    It 'OK on unique IDs and OverrideKeys' {
        $Records = @(
            New-MigrationChangeRecord -Id 'a' -ObjectType 'EntityBullet' -ChangeKind 'Modify' -FilePath 'x' -OverrideKey 'k:a'
            New-MigrationChangeRecord -Id 'b' -ObjectType 'EntityBullet' -ChangeKind 'Modify' -FilePath 'x' -OverrideKey 'k:b'
        )
        (Test-MigrationChangeRecordSet -Records $Records).OK | Should -BeTrue
    }

    It 'flags duplicate Id' {
        $Records = @(
            New-MigrationChangeRecord -Id 'a' -ObjectType 'EntityBullet' -ChangeKind 'Modify' -FilePath 'x'
            New-MigrationChangeRecord -Id 'a' -ObjectType 'EntityBullet' -ChangeKind 'Modify' -FilePath 'y'
        )
        (Test-MigrationChangeRecordSet -Records $Records).OK | Should -BeFalse
    }

    It 'flags duplicate OverrideKey' {
        $Records = @(
            New-MigrationChangeRecord -Id 'a' -ObjectType 'EntityBullet' -ChangeKind 'Modify' -FilePath 'x' -OverrideKey 'shared'
            New-MigrationChangeRecord -Id 'b' -ObjectType 'EntityBullet' -ChangeKind 'Modify' -FilePath 'x' -OverrideKey 'shared'
        )
        (Test-MigrationChangeRecordSet -Records $Records).OK | Should -BeFalse
    }

    It 'permits records without OverrideKey (not all changes are overridable)' {
        $Records = @(
            New-MigrationChangeRecord -Id 'a' -ObjectType 'EntityBullet' -ChangeKind 'Modify' -FilePath 'x'
            New-MigrationChangeRecord -Id 'b' -ObjectType 'EntityBullet' -ChangeKind 'Modify' -FilePath 'y'
        )
        (Test-MigrationChangeRecordSet -Records $Records).OK | Should -BeTrue
    }
}
