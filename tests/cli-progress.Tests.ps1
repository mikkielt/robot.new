<#
    .SYNOPSIS
    Tests for Docker-style progress reporting functions in cli-primitives.ps1.

    .DESCRIPTION
    Validates state creation, step lifecycle, spinner cycling, and group
    completion. Uses Pattern C (standalone helper dot-sourcing).

    Tests only the data layer — no actual terminal rendering is validated.
    Write-Host and [Console]::SetCursorPosition are mocked to prevent output.
#>

BeforeAll {
    . "$PSScriptRoot/TestHelpers.ps1"

    # Mock console methods before dot-sourcing (prevents terminal output)
    Mock Write-Host {}
    Mock -CommandName 'Set-StrictMode' {}

    # Provide a NavState for Get-CLIColor
    $script:NavState = [PSCustomObject]@{ Theme = 'Dark' }

    # Dot-source the file under test
    . "$script:ModuleRoot/private/cli/cli-primitives.ps1"

    # Re-mock Write-Host after dot-source (chain-loads may reset it)
    Mock Write-Host {}
}

Describe 'New-ProgressState' {

    BeforeAll {
        Mock Write-Host {}
    }

    It 'returns a hashtable with all required keys' {
        $State = New-ProgressState -Title 'Test' -TotalSteps 3
        $State | Should -BeOfType [hashtable]
        $State.Keys | Should -Contain 'Title'
        $State.Keys | Should -Contain 'Steps'
        $State.Keys | Should -Contain 'TotalSteps'
        $State.Keys | Should -Contain 'CurrentStep'
        $State.Keys | Should -Contain 'StartRow'
        $State.Keys | Should -Contain 'GroupStart'
        $State.Keys | Should -Contain 'StepWatch'
        $State.Keys | Should -Contain 'SpinnerIdx'
        $State.Keys | Should -Contain 'Failed'
    }

    It 'sets Title and TotalSteps from parameters' {
        $State = New-ProgressState -Title 'Loading' -TotalSteps 5
        $State.Title | Should -Be 'Loading'
        $State.TotalSteps | Should -Be 5
    }

    It 'starts with CurrentStep at 0' {
        $State = New-ProgressState -Title 'Test' -TotalSteps 2
        $State.CurrentStep | Should -Be 0
    }

    It 'starts GroupStart stopwatch running' {
        $State = New-ProgressState -Title 'Test' -TotalSteps 1
        $State.GroupStart | Should -BeOfType [System.Diagnostics.Stopwatch]
        $State.GroupStart.IsRunning | Should -BeTrue
    }

    It 'initializes Steps as empty list' {
        $State = New-ProgressState -Title 'Test' -TotalSteps 2
        $State.Steps.Count | Should -Be 0
    }

    It 'initializes Failed as false' {
        $State = New-ProgressState -Title 'Test' -TotalSteps 1
        $State.Failed | Should -BeFalse
    }
}

Describe 'Start-ProgressStep' {

    BeforeAll {
        Mock Write-Host {}
    }

    It 'increments CurrentStep' {
        $State = New-ProgressState -Title 'Test' -TotalSteps 3
        Start-ProgressStep -State $State -Label 'Step1'
        $State.CurrentStep | Should -Be 1
        Start-ProgressStep -State $State -Label 'Step2'
        $State.CurrentStep | Should -Be 2
    }

    It 'adds a step entry to the Steps list' {
        $State = New-ProgressState -Title 'Test' -TotalSteps 2
        Start-ProgressStep -State $State -Label 'Entities'
        $State.Steps.Count | Should -Be 1
        $State.Steps[0].Label | Should -Be 'Entities'
        $State.Steps[0].Status | Should -Be 'Running'
    }

    It 'starts StepWatch running' {
        $State = New-ProgressState -Title 'Test' -TotalSteps 1
        Start-ProgressStep -State $State -Label 'Step1'
        $State.StepWatch | Should -BeOfType [System.Diagnostics.Stopwatch]
        $State.StepWatch.IsRunning | Should -BeTrue
    }

    It 'resets SpinnerIdx to 0' {
        $State = New-ProgressState -Title 'Test' -TotalSteps 2
        Start-ProgressStep -State $State -Label 'Step1'
        $State.SpinnerIdx = 5
        Start-ProgressStep -State $State -Label 'Step2'
        $State.SpinnerIdx | Should -Be 0
    }
}

Describe 'Update-ProgressStep' {

    BeforeAll {
        Mock Write-Host {}
    }

    It 'advances SpinnerIdx cyclically' {
        $State = New-ProgressState -Title 'Test' -TotalSteps 1
        Start-ProgressStep -State $State -Label 'Step1'

        for ($I = 1; $I -le 8; $I++) {
            Update-ProgressStep -State $State -Detail "$I/10"
            $Expected = $I % 8
            $State.SpinnerIdx | Should -Be $Expected
        }
    }

    It 'cycles back to 0 after frame 7' {
        $State = New-ProgressState -Title 'Test' -TotalSteps 1
        Start-ProgressStep -State $State -Label 'Step1'

        # Advance to frame 7
        for ($I = 0; $I -lt 7; $I++) {
            Update-ProgressStep -State $State
        }
        $State.SpinnerIdx | Should -Be 7

        # Next should wrap to 0
        Update-ProgressStep -State $State
        $State.SpinnerIdx | Should -Be 0
    }

    It 'updates Detail on current step' {
        $State = New-ProgressState -Title 'Test' -TotalSteps 1
        Start-ProgressStep -State $State -Label 'Step1'
        Update-ProgressStep -State $State -Detail '42/100'
        $State.Steps[0].Detail | Should -Be '42/100'
    }

    It 'does not error on empty Steps list' {
        $State = New-ProgressState -Title 'Test' -TotalSteps 1
        { Update-ProgressStep -State $State -Detail 'x' } | Should -Not -Throw
    }
}

Describe 'Complete-ProgressStep' {

    BeforeAll {
        Mock Write-Host {}
    }

    It 'sets Status to Done on success' {
        $State = New-ProgressState -Title 'Test' -TotalSteps 1
        Start-ProgressStep -State $State -Label 'Step1'
        Complete-ProgressStep -State $State -Detail '100'
        $State.Steps[0].Status | Should -Be 'Done'
    }

    It 'records Elapsed greater than 0' {
        $State = New-ProgressState -Title 'Test' -TotalSteps 1
        Start-ProgressStep -State $State -Label 'Step1'
        [System.Threading.Thread]::Sleep(10)
        Complete-ProgressStep -State $State
        $State.Steps[0].Elapsed | Should -BeGreaterThan 0
    }

    It 'stops StepWatch' {
        $State = New-ProgressState -Title 'Test' -TotalSteps 1
        Start-ProgressStep -State $State -Label 'Step1'
        Complete-ProgressStep -State $State
        $State.StepWatch.IsRunning | Should -BeFalse
    }

    It 'updates Detail when provided' {
        $State = New-ProgressState -Title 'Test' -TotalSteps 1
        Start-ProgressStep -State $State -Label 'Step1'
        Complete-ProgressStep -State $State -Detail '247'
        $State.Steps[0].Detail | Should -Be '247'
    }

    It 'sets Status to Error with -Failed' {
        $State = New-ProgressState -Title 'Test' -TotalSteps 1
        Start-ProgressStep -State $State -Label 'Step1'
        Complete-ProgressStep -State $State -Failed
        $State.Steps[0].Status | Should -Be 'Error'
    }

    It 'sets State.Failed to true with -Failed' {
        $State = New-ProgressState -Title 'Test' -TotalSteps 1
        Start-ProgressStep -State $State -Label 'Step1'
        Complete-ProgressStep -State $State -Failed
        $State.Failed | Should -BeTrue
    }

    It 'does not error on empty Steps list' {
        $State = New-ProgressState -Title 'Test' -TotalSteps 1
        { Complete-ProgressStep -State $State } | Should -Not -Throw
    }
}

Describe 'Complete-ProgressGroup' {

    BeforeAll {
        Mock Write-Host {}
    }

    It 'stops GroupStart stopwatch' {
        $State = New-ProgressState -Title 'Test' -TotalSteps 1
        Start-ProgressStep -State $State -Label 'Step1'
        Complete-ProgressStep -State $State
        Complete-ProgressGroup -State $State
        $State.GroupStart.IsRunning | Should -BeFalse
    }
}

Describe 'Full lifecycle integration' {

    BeforeAll {
        Mock Write-Host {}
    }

    It 'tracks 3-step sequence correctly' {
        $State = New-ProgressState -Title 'Integration' -TotalSteps 3

        Start-ProgressStep -State $State -Label 'Alpha'
        Update-ProgressStep -State $State -Detail '1/2'
        Update-ProgressStep -State $State -Detail '2/2'
        Complete-ProgressStep -State $State -Detail '2'

        Start-ProgressStep -State $State -Label 'Beta'
        Complete-ProgressStep -State $State -Detail 'OK'

        Start-ProgressStep -State $State -Label 'Gamma'
        Complete-ProgressStep -State $State -Detail 'FAIL' -Failed

        Complete-ProgressGroup -State $State

        $State.Steps.Count | Should -Be 3
        $State.CurrentStep | Should -Be 3
        $State.Steps[0].Status | Should -Be 'Done'
        $State.Steps[0].Detail | Should -Be '2'
        $State.Steps[1].Status | Should -Be 'Done'
        $State.Steps[1].Detail | Should -Be 'OK'
        $State.Steps[2].Status | Should -Be 'Error'
        $State.Steps[2].Detail | Should -Be 'FAIL'
        $State.Failed | Should -BeTrue
        $State.GroupStart.IsRunning | Should -BeFalse
    }

    It 'handles single-step group' {
        $State = New-ProgressState -Title 'Single' -TotalSteps 1
        Start-ProgressStep -State $State -Label 'Only'
        Complete-ProgressStep -State $State -Detail 'done'
        Complete-ProgressGroup -State $State

        $State.Steps.Count | Should -Be 1
        $State.CurrentStep | Should -Be 1
        $State.Failed | Should -BeFalse
    }

    It 'Complete without prior Update works' {
        $State = New-ProgressState -Title 'NoUpdate' -TotalSteps 1
        Start-ProgressStep -State $State -Label 'Direct'
        Complete-ProgressStep -State $State -Detail 'OK'

        $State.Steps[0].Status | Should -Be 'Done'
        $State.Steps[0].Detail | Should -Be 'OK'
    }

    It 'Failed step does not prevent next step' {
        $State = New-ProgressState -Title 'Recovery' -TotalSteps 2
        Start-ProgressStep -State $State -Label 'Fail'
        Complete-ProgressStep -State $State -Failed -Detail 'ERR'

        Start-ProgressStep -State $State -Label 'Continue'
        Complete-ProgressStep -State $State -Detail 'OK'

        $State.Steps[0].Status | Should -Be 'Error'
        $State.Steps[1].Status | Should -Be 'Done'
        $State.CurrentStep | Should -Be 2
    }
}
