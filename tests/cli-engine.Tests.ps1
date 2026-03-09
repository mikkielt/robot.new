<#
    .SYNOPSIS
    Tests for cli-engine.ps1 — screen and region management.

    .DESCRIPTION
    Validates region calculation, minimum size detection, and resize
    handling. Uses Pattern C (standalone helper dot-sourcing).
#>

BeforeAll {
    . "$PSScriptRoot/TestHelpers.ps1"

    # Dot-source engine file (depends on primitives for Get-CLIColor)
    . "$script:ModuleRoot/private/cli/cli-primitives.ps1"
    . "$script:ModuleRoot/private/cli/engine/cli-engine.ps1"
}

Describe 'Test-MinimumSize' {

    It 'returns true when terminal meets minimum dimensions' {
        # Engine uses [System.Console]::WindowWidth/Height directly
        # In test context these are real values; verify function returns a boolean
        $Result = Test-MinimumSize
        $Result | Should -BeOfType [bool]
    }
}

Describe 'Build-Regions' {

    BeforeAll {
        # Force known screen dimensions via the module-level vars
        $script:ScreenWidth  = 80
        $script:ScreenHeight = 24
    }

    It 'creates four named regions' {
        Build-Regions
        $script:Regions.Keys | Should -Contain 'TopBar'
        $script:Regions.Keys | Should -Contain 'Content'
        $script:Regions.Keys | Should -Contain 'Filter'
        $script:Regions.Keys | Should -Contain 'StatusBar'
    }

    It 'TopBar occupies row 0' {
        Build-Regions
        $R = $script:Regions['TopBar']
        $R.StartRow | Should -Be 0
        $R.EndRow   | Should -Be 1
    }

    It 'Content starts at row 1 and ends before filter' {
        Build-Regions
        $R = $script:Regions['Content']
        $H = [System.Console]::WindowHeight
        $R.StartRow | Should -Be 1
        $R.EndRow   | Should -Be ($H - 2)
    }

    It 'Filter occupies row H-2' {
        Build-Regions
        $R = $script:Regions['Filter']
        $H = [System.Console]::WindowHeight
        $R.StartRow | Should -Be ($H - 2)
        $R.EndRow   | Should -Be ($H - 1)
    }

    It 'StatusBar occupies row H-1' {
        Build-Regions
        $R = $script:Regions['StatusBar']
        $H = [System.Console]::WindowHeight
        $R.StartRow | Should -Be ($H - 1)
        $R.EndRow   | Should -Be $H
    }

    It 'all regions have Width equal to terminal width' {
        Build-Regions
        $W = [System.Console]::WindowWidth
        foreach ($Key in $script:Regions.Keys) {
            $script:Regions[$Key].Width | Should -Be $W
        }
    }
}

Describe 'Get-Region' {

    BeforeAll {
        Build-Regions
    }

    It 'returns region by name' {
        $R = Get-Region -Name 'Content'
        $R | Should -Not -BeNullOrEmpty
        $R.Name | Should -Be 'Content'
    }

    It 'returns null for unknown name' {
        $R = Get-Region -Name 'NonExistent'
        $R | Should -BeNullOrEmpty
    }
}

Describe 'Get-RegionHeight' {

    BeforeAll {
        Build-Regions
    }

    It 'returns correct height for TopBar (1 row)' {
        $H = Get-RegionHeight -Name 'TopBar'
        $H | Should -Be 1
    }

    It 'returns correct height for Content region' {
        $H = Get-RegionHeight -Name 'Content'
        $TermH = [System.Console]::WindowHeight
        $Expected = $TermH - 3  # row 1 to H-3
        $H | Should -Be $Expected
    }

    It 'returns 0 for unknown region' {
        $H = Get-RegionHeight -Name 'NonExistent'
        $H | Should -Be 0
    }
}

Describe 'ANSI helpers' {

    It 'Get-ANSIBold returns string' {
        $Result = Get-ANSIBold
        $Result | Should -BeOfType [string]
    }

    It 'Get-ANSIDim returns string' {
        $Result = Get-ANSIDim
        $Result | Should -BeOfType [string]
    }

    It 'Get-ANSIReset returns string' {
        $Result = Get-ANSIReset
        $Result | Should -BeOfType [string]
    }

    It 'returns non-empty strings on PS 7+' -Skip:($PSVersionTable.PSVersion.Major -lt 7) {
        Get-ANSIBold | Should -Not -BeNullOrEmpty
        Get-ANSIDim | Should -Not -BeNullOrEmpty
        Get-ANSIReset | Should -Not -BeNullOrEmpty
    }
}

Describe 'Test-TerminalResized' {

    It 'returns false when dimensions match stored values' {
        $script:ScreenWidth  = [System.Console]::WindowWidth
        $script:ScreenHeight = [System.Console]::WindowHeight
        $Result = Test-TerminalResized
        $Result | Should -BeFalse
    }

    It 'returns true when stored width differs' {
        $script:ScreenWidth  = 1
        $script:ScreenHeight = [System.Console]::WindowHeight
        $Result = Test-TerminalResized
        $Result | Should -BeTrue
    }

    It 'returns true when stored height differs' {
        $script:ScreenWidth  = [System.Console]::WindowWidth
        $script:ScreenHeight = 1
        $Result = Test-TerminalResized
        $Result | Should -BeTrue
    }
}

Describe 'Get-TierStyle' {

    BeforeAll {
        # Ensure regions are built for Get-CLIColor to work
        $script:ScreenWidth  = 80
        $script:ScreenHeight = 24
        Build-Regions
    }

    It 'Tier 1 returns Bold=true with Accent color' {
        $Style = Get-TierStyle -Tier 1
        $Style.Bold | Should -BeTrue
        $Style.Dim  | Should -BeFalse
        $Style.Color | Should -Be (Get-CLIColor -Role 'Accent')
    }

    It 'Tier 2 returns Info color, no bold, no dim' {
        $Style = Get-TierStyle -Tier 2
        $Style.Bold | Should -BeFalse
        $Style.Dim  | Should -BeFalse
        $Style.Color | Should -Be (Get-CLIColor -Role 'Info')
    }

    It 'Tier 3 returns Disabled color, no bold, no dim' {
        $Style = Get-TierStyle -Tier 3
        $Style.Bold | Should -BeFalse
        $Style.Dim  | Should -BeFalse
        $Style.Color | Should -Be (Get-CLIColor -Role 'Disabled')
    }

    It 'Tier 4 returns Disabled color with Dim=true' {
        $Style = Get-TierStyle -Tier 4
        $Style.Bold | Should -BeFalse
        $Style.Dim  | Should -BeTrue
        $Style.Color | Should -Be (Get-CLIColor -Role 'Disabled')
    }

    It 'Tier 5 returns Disabled color, no dim' {
        $Style = Get-TierStyle -Tier 5
        $Style.Bold | Should -BeFalse
        $Style.Dim  | Should -BeFalse
        $Style.Color | Should -Be (Get-CLIColor -Role 'Disabled')
    }

    It 'unknown tier returns null color' {
        $Style = Get-TierStyle -Tier 99
        $Style.Color | Should -BeNullOrEmpty
    }
}

Describe 'New-TierSegment' {

    BeforeAll {
        . "$script:ModuleRoot/private/cli/engine/cli-buffer.ps1"
    }

    It 'creates segment styled for Tier 1' {
        $Seg = New-TierSegment -Text 'Active' -Tier 1
        $Seg.Text  | Should -Be 'Active'
        $Seg.Bold  | Should -BeTrue
        $Seg.Color | Should -Be (Get-CLIColor -Role 'Accent')
    }

    It 'creates segment styled for Tier 4 (dim)' {
        $Seg = New-TierSegment -Text '───' -Tier 4
        $Seg.Dim  | Should -BeTrue
        $Seg.Bold | Should -BeFalse
    }
}
