<#
    .SYNOPSIS
    Pester tests for cli-primitives.ps1.

    .DESCRIPTION
    Tests for color scheme, theme resolution, and banner art.
    Interactive UI functions (Show-ArrowMenu, Show-ResultTable, etc.)
    are NOT tested here as they require a live terminal.
#>

BeforeAll {
    . "$PSScriptRoot/TestHelpers.ps1"
    Import-RobotModule

    # Dot-source CLI primitives (Layer 1)
    . (Join-Path $script:ModuleRoot 'private' 'cli' 'cli-primitives.ps1')

    # Create a minimal NavState for color resolution
    $script:NavState = [PSCustomObject]@{
        Theme = 'Dark'
    }
}

# ── Color Scheme ────────────────────────────────────────────────────────────

Describe 'Get-CLIColor' {
    It 'returns Cyan for Accent role in Dark theme' {
        $script:NavState.Theme = 'Dark'
        Get-CLIColor -Role 'Accent' | Should -Be 'Cyan'
    }

    It 'returns DarkCyan for Accent role in Light theme' {
        $script:NavState.Theme = 'Light'
        Get-CLIColor -Role 'Accent' | Should -Be 'DarkCyan'
    }

    It 'returns Magenta for Error role in Dark theme (never Red)' {
        $script:NavState.Theme = 'Dark'
        $Color = Get-CLIColor -Role 'Error'
        $Color | Should -Be 'Magenta'
        $Color | Should -Not -Be 'Red'
        $Color | Should -Not -Be 'Green'
    }

    It 'returns DarkMagenta for Error role in Light theme (never Red)' {
        $script:NavState.Theme = 'Light'
        $Color = Get-CLIColor -Role 'Error'
        $Color | Should -Be 'DarkMagenta'
        $Color | Should -Not -Be 'Red'
    }

    It 'returns Yellow for Warning role in Dark theme' {
        $script:NavState.Theme = 'Dark'
        Get-CLIColor -Role 'Warning' | Should -Be 'Yellow'
    }

    It 'never returns Red or Green for any role' {
        foreach ($Theme in @('Dark', 'Light')) {
            $script:NavState.Theme = $Theme
            foreach ($Role in @('Accent', 'Success', 'Warning', 'Error', 'Disabled', 'Info', 'RoleTag')) {
                $Color = Get-CLIColor -Role $Role
                $Color | Should -Not -Be 'Red' -Because "Red is not colorblind-safe ($Role, $Theme)"
                $Color | Should -Not -Be 'Green' -Because "Green is not colorblind-safe ($Role, $Theme)"
                $Color | Should -Not -Be 'DarkRed' -Because "DarkRed is not colorblind-safe ($Role, $Theme)"
                $Color | Should -Not -Be 'DarkGreen' -Because "DarkGreen is not colorblind-safe ($Role, $Theme)"
            }
        }
    }

    It 'returns White for unknown role' {
        $script:NavState.Theme = 'Dark'
        Get-CLIColor -Role 'NonExistent' | Should -Be 'White'
    }

    AfterAll {
        $script:NavState.Theme = 'Dark'
    }
}

Describe 'Resolve-CLITheme' {
    It 'returns Dark or Light string' {
        $Result = Resolve-CLITheme
        $Result | Should -BeIn @('Dark', 'Light')
    }
}

# ── Banner ──────────────────────────────────────────────────────────────────

Describe 'Banner art' {
    It 'BannerArt string is defined and multi-line' {
        $script:BannerArt | Should -Not -BeNullOrEmpty
        $script:BannerArt.Split("`n").Count | Should -BeGreaterOrEqual 4
    }

    It 'BannerArt contains ASCII art characters (slashes and underscores)' {
        $script:BannerArt | Should -Match '/'
        $script:BannerArt | Should -Match '_'
        $script:BannerArt | Should -Match '\\'
    }
}
