<#
    .SYNOPSIS
    Pester tests for cli-wizard.ps1.

    .DESCRIPTION
    Tests for CommonParams HashSet and Resolve-StepType logic.
    Interactive wizard functions (Invoke-WizardStep, Invoke-Wizard, Show-Preview)
    are NOT tested here as they require a live terminal.
#>

BeforeAll {
    . "$PSScriptRoot/TestHelpers.ps1"
    Import-RobotModule

    # Dot-source CLI layers in dependency order
    . (Join-Path $script:ModuleRoot 'private' 'cli' 'cli-primitives.ps1')
    . (Join-Path $script:ModuleRoot 'private' 'cli' 'cli-fuzzy.ps1')
    . (Join-Path $script:ModuleRoot 'private' 'cli' 'cli-display.ps1')
    . (Join-Path $script:ModuleRoot 'private' 'cli' 'cli-wizard.ps1')

    # Create a minimal NavState for color resolution
    $script:NavState = [PSCustomObject]@{
        Theme = 'Dark'
    }
}

# ── CommonParams ────────────────────────────────────────────────────────────

Describe 'CommonParams HashSet' {
    It 'contains WhatIf' {
        $script:CommonParams.Contains('WhatIf') | Should -BeTrue
    }

    It 'contains Confirm' {
        $script:CommonParams.Contains('Confirm') | Should -BeTrue
    }

    It 'contains ErrorAction' {
        $script:CommonParams.Contains('ErrorAction') | Should -BeTrue
    }

    It 'does not contain custom parameter names' {
        $script:CommonParams.Contains('Name') | Should -BeFalse
        $script:CommonParams.Contains('PlayerName') | Should -BeFalse
    }

    It 'is case-insensitive' {
        $script:CommonParams.Contains('whatif') | Should -BeTrue
        $script:CommonParams.Contains('WHATIF') | Should -BeTrue
    }
}

# ── Resolve-StepType ────────────────────────────────────────────────────────

Describe 'Resolve-StepType' {
    It 'resolves [string] parameter to text step' {
        $Cmd = Get-Command 'New-Player' -ErrorAction SilentlyContinue
        if (-not $Cmd) { Set-ItResult -Skipped -Because 'New-Player not available'; return }

        $NameParam = $Cmd.Parameters['Name']
        $Step = Resolve-StepType -ParamInfo $NameParam
        $Step.StepType | Should -Be 'text'
        $Step.Name | Should -Be 'Name'
    }

    It 'resolves [switch] parameter to yesno step' {
        $Cmd = Get-Command 'Get-Player' -ErrorAction SilentlyContinue
        if (-not $Cmd) { Set-ItResult -Skipped -Because 'Get-Player not available'; return }

        # Find a switch parameter
        $SwitchParam = $null
        foreach ($P in $Cmd.Parameters.GetEnumerator()) {
            if ($P.Value.ParameterType -eq [switch] -and -not $script:CommonParams.Contains($P.Key)) {
                $SwitchParam = $P.Value
                break
            }
        }

        if (-not $SwitchParam) { Set-ItResult -Skipped -Because 'no switch params found'; return }

        $Step = Resolve-StepType -ParamInfo $SwitchParam
        $Step.StepType | Should -Be 'yesno'
    }

    It 'applies override Type to change step type' {
        $Cmd = Get-Command 'New-Player' -ErrorAction SilentlyContinue
        if (-not $Cmd) { Set-ItResult -Skipped -Because 'New-Player not available'; return }

        $NameParam = $Cmd.Parameters['Name']
        $Override = @{ Type = 'fuzzy'; Source = 'players' }
        $Step = Resolve-StepType -ParamInfo $NameParam -Override $Override
        $Step.StepType | Should -Be 'fuzzy'
        $Step.Source | Should -Be 'players'
    }

    It 'applies override Hidden flag' {
        $Cmd = Get-Command 'New-Player' -ErrorAction SilentlyContinue
        if (-not $Cmd) { Set-ItResult -Skipped -Because 'New-Player not available'; return }

        $NameParam = $Cmd.Parameters['Name']
        $Override = @{ Hidden = $true }
        # Hidden is checked before Resolve-StepType is called; verify it passes through
        $Step = Resolve-StepType -ParamInfo $NameParam -Override $Override
        $Step | Should -Not -BeNullOrEmpty
    }

    It 'auto-detects ValidateSet as selection' {
        # Build a mock ParamInfo with ValidateSet
        $MockParam = @{
            Name          = 'TestParam'
            ParameterType = [string]
            Attributes    = @(
                [System.Management.Automation.ParameterAttribute]@{ Mandatory = $false }
                [System.Management.Automation.ValidateSetAttribute]::new('Alpha', 'Beta', 'Gamma')
            )
        }
        $Step = Resolve-StepType -ParamInfo ([PSCustomObject]$MockParam)
        $Step.StepType | Should -Be 'selection'
        $Step.Options | Should -Contain 'Alpha'
        $Step.Options | Should -Contain 'Beta'
    }

    It 'auto-detects [string[]] as multitext' {
        $MockParam = @{
            Name          = 'Items'
            ParameterType = [string[]]
            Attributes    = @(
                [System.Management.Automation.ParameterAttribute]@{ Mandatory = $false }
            )
        }
        $Step = Resolve-StepType -ParamInfo ([PSCustomObject]$MockParam)
        $Step.StepType | Should -Be 'multitext'
    }

    It 'auto-detects [int] as number' {
        $MockParam = @{
            Name          = 'Count'
            ParameterType = [int]
            Attributes    = @(
                [System.Management.Automation.ParameterAttribute]@{ Mandatory = $true }
            )
        }
        $Step = Resolve-StepType -ParamInfo ([PSCustomObject]$MockParam)
        $Step.StepType | Should -Be 'number'
    }

    It 'auto-detects [decimal] as decimal' {
        $MockParam = @{
            Name          = 'Amount'
            ParameterType = [decimal]
            Attributes    = @(
                [System.Management.Automation.ParameterAttribute]@{ Mandatory = $true }
            )
        }
        $Step = Resolve-StepType -ParamInfo ([PSCustomObject]$MockParam)
        $Step.StepType | Should -Be 'decimal'
    }
}
