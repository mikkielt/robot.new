BeforeAll {
    . "$PSScriptRoot/TestHelpers.ps1"
    . "$script:ModuleRoot/private/operation-context.ps1"
}

Describe 'Clear-OperationContext' {
    It 'Resets all accumulators' {
        Add-OperationChange -Property '@lokacja' -OldValue 'A' -NewValue 'B'
        Add-OperationWarning -Message 'test'
        Add-OperationFile -Path '/tmp/test.md'

        Clear-OperationContext

        $script:OpChanges.Count | Should -Be 0
        $script:OpWarnings.Count | Should -Be 0
        $script:OpFiles.Count | Should -Be 0
    }
}

Describe 'Add-OperationChange' {
    BeforeEach { Clear-OperationContext }

    It 'Accumulates multiple changes in order' {
        Add-OperationChange -Property '@status' -OldValue 'Aktywny' -NewValue 'Nieaktywny'
        Add-OperationChange -Property '@lokacja' -OldValue $null -NewValue 'Twierdza'

        $script:OpChanges.Count | Should -Be 2
        $script:OpChanges[0].Property | Should -Be '@status'
        $script:OpChanges[0].OldValue | Should -Be 'Aktywny'
        $script:OpChanges[0].NewValue | Should -Be 'Nieaktywny'
        $script:OpChanges[1].Property | Should -Be '@lokacja'
        $script:OpChanges[1].OldValue | Should -BeNullOrEmpty
        $script:OpChanges[1].NewValue | Should -Be 'Twierdza'
    }
}

Describe 'Add-OperationWarning' {
    BeforeEach { Clear-OperationContext }

    It 'Defaults Severity to Info and ActionHint to null' {
        Add-OperationWarning -Message 'Test warning'

        $script:OpWarnings.Count | Should -Be 1
        $script:OpWarnings[0].Message | Should -Be 'Test warning'
        $script:OpWarnings[0].Severity | Should -Be 'Info'
        $script:OpWarnings[0].ActionHint | Should -BeNullOrEmpty
    }

    It 'Accepts custom Severity and ActionHint' {
        Add-OperationWarning -Message 'Warn msg' -Severity 'Warn' -ActionHint 'Fix it'

        $script:OpWarnings[0].Severity | Should -Be 'Warn'
        $script:OpWarnings[0].ActionHint | Should -Be 'Fix it'
    }
}

Describe 'Add-OperationFile' {
    BeforeEach { Clear-OperationContext }

    It 'Deduplicates same path added twice' {
        Add-OperationFile -Path '/tmp/entities.md'
        Add-OperationFile -Path '/tmp/entities.md'

        $script:OpFiles.Count | Should -Be 1
    }

    It 'Deduplicates case-insensitively' {
        Add-OperationFile -Path '/tmp/Entities.md'
        Add-OperationFile -Path '/tmp/entities.md'

        $script:OpFiles.Count | Should -Be 1
    }

    It 'Keeps distinct paths' {
        Add-OperationFile -Path '/tmp/entities.md'
        Add-OperationFile -Path '/tmp/charfile.md'

        $script:OpFiles.Count | Should -Be 2
    }
}

Describe 'New-OperationResult' {
    BeforeEach { Clear-OperationContext }

    It 'Returns correct PSTypeName and all properties' {
        $Result = New-OperationResult -Success $true -Action 'Create' -TargetType 'NPC' -TargetName 'Sandro' -UndoHint 'Remove-Entity'

        $Result.PSObject.TypeNames | Should -Contain 'Robot.OperationResult'
        $Result.Success | Should -Be $true
        $Result.Action | Should -Be 'Create'
        $Result.TargetType | Should -Be 'NPC'
        $Result.TargetName | Should -Be 'Sandro'
        $Result.UndoHint | Should -Be 'Remove-Entity'
        $Result.Timestamp | Should -BeOfType [datetime]
    }

    It 'Drains accumulators after call' {
        Add-OperationChange -Property '@status' -OldValue 'A' -NewValue 'B'
        Add-OperationWarning -Message 'test'
        Add-OperationFile -Path '/tmp/test.md'

        $null = New-OperationResult -Success $true -Action 'Update' -TargetType 'NPC' -TargetName 'X'

        $script:OpChanges.Count | Should -Be 0
        $script:OpWarnings.Count | Should -Be 0
        $script:OpFiles.Count | Should -Be 0
    }

    It 'Returns single file as scalar string' {
        Add-OperationFile -Path '/tmp/entities.md'

        $Result = New-OperationResult -Success $true -Action 'Update' -TargetType 'NPC' -TargetName 'X'

        $Result.FilePath | Should -BeOfType [string]
        $Result.FilePath | Should -Be '/tmp/entities.md'
    }

    It 'Returns multiple files as string array' {
        Add-OperationFile -Path '/tmp/entities.md'
        Add-OperationFile -Path '/tmp/charfile.md'

        $Result = New-OperationResult -Success $true -Action 'Update' -TargetType 'Postać' -TargetName 'X'

        $Result.FilePath | Should -HaveCount 2
    }

    It 'Returns null FilePath when no files touched' {
        $Result = New-OperationResult -Success $true -Action 'Skipped' -TargetType 'NPC' -TargetName 'X'

        $Result.FilePath | Should -BeNullOrEmpty
    }

    It 'Returns empty arrays for Changes/Warnings when none accumulated' {
        $Result = New-OperationResult -Success $true -Action 'Update' -TargetType 'NPC' -TargetName 'X'

        $Result.Changes | Should -HaveCount 0
        $Result.Warnings | Should -HaveCount 0
    }

    It 'Changes from call 1 do not leak into call 2' {
        Add-OperationChange -Property '@status' -OldValue 'A' -NewValue 'B'
        $Result1 = New-OperationResult -Success $true -Action 'Update' -TargetType 'NPC' -TargetName 'X'

        Add-OperationChange -Property '@lokacja' -OldValue $null -NewValue 'Y'
        $Result2 = New-OperationResult -Success $true -Action 'Update' -TargetType 'NPC' -TargetName 'Z'

        $Result1.Changes | Should -HaveCount 1
        $Result1.Changes[0].Property | Should -Be '@status'

        $Result2.Changes | Should -HaveCount 1
        $Result2.Changes[0].Property | Should -Be '@lokacja'
    }
}
