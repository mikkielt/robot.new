<#
    .SYNOPSIS
    Tests for the nerthusaddon-integration plugin.
#>

Describe 'nerthusaddon-integration' {

    BeforeAll {
        # Stub Write-RobotWarning (defined in robot.psm1, unavailable standalone)
        function Write-RobotWarning { param([string]$Message) }

        # Dot-source helpers directly for unit testing
        . "$PSScriptRoot/../private/nerthusaddon-helpers.ps1"

        # Create fixture maps.json
        $script:FixtureDir = Join-Path $TestDrive 'nerthusaddon'
        $script:FixtureMapsDir = Join-Path $script:FixtureDir 'res' 'configs'
        New-Item -Path $script:FixtureMapsDir -ItemType Directory -Force | Out-Null

        $script:FixtureMapsJson = Join-Path $script:FixtureMapsDir 'maps.json'

        # nerthusaddon maps.json format: { season: { numericId: "imagePath" } }
        $MapsData = @{
            'default' = @{
                '1'   = 'obrazki/miasta/ithan.png'
                '117' = 'obrazki/miasta/swiszczaca-grota-p1.png'
                '118' = 'obrazki/miasta/swiszczaca-grota-p2.png'
                '200' = 'obrazki/miasta/targowisko.png'
            }
            'zima' = @{
                '1'   = 'obrazki/miasta/ithan-zima.png'
                '200' = 'obrazki/miasta/targowisko-zima.png'
            }
        }
        $MapsData | ConvertTo-Json -Depth 4 | Set-Content -Path $script:FixtureMapsJson -Encoding UTF8
    }

    Context 'Get-NerthusAddonMapsJsonPath' {
        It 'returns full path from config' {
            $Config = @{
                NerthusAddonPath = $script:FixtureDir
                MapsJsonRelPath  = 'res/configs/maps.json'
            }
            $Result = Get-NerthusAddonMapsJsonPath -Config $Config
            $Result | Should -Be $script:FixtureMapsJson
        }

        It 'returns null when NerthusAddonPath is missing' {
            $Config = @{ NerthusAddonPath = $null }
            $Result = Get-NerthusAddonMapsJsonPath -Config $Config
            $Result | Should -BeNullOrEmpty
        }

        It 'uses default relative path when MapsJsonRelPath not set' {
            $Config = @{
                NerthusAddonPath = $script:FixtureDir
            }
            $Result = Get-NerthusAddonMapsJsonPath -Config $Config
            $Result | Should -BeLike '*res*configs*maps.json'
        }
    }

    Context 'Read-NerthusAddonMapsJson' {
        It 'parses valid maps.json' {
            $Result = Read-NerthusAddonMapsJson -Path $script:FixtureMapsJson
            $Result | Should -Not -BeNullOrEmpty
            $Result.default | Should -Not -BeNullOrEmpty
            $Result.zima | Should -Not -BeNullOrEmpty
        }

        It 'returns null for missing file' {
            $Result = Read-NerthusAddonMapsJson -Path (Join-Path $TestDrive 'nonexistent.json')
            $Result | Should -BeNullOrEmpty
        }

        It 'returns null for invalid JSON' {
            $BadJson = Join-Path $TestDrive 'bad.json'
            'not valid json{{{' | Set-Content -Path $BadJson -Encoding UTF8
            $Result = Read-NerthusAddonMapsJson -Path $BadJson
            $Result | Should -BeNullOrEmpty
        }
    }

    Context 'Group-NerthusAddonFloors' {
        It 'groups entries by base name, stripping floor suffixes' {
            $Entries = @(
                [PSCustomObject]@{ Id = 117; Name = 'Świszcząca Grota p.1'; Season = 'default' }
                [PSCustomObject]@{ Id = 118; Name = 'Świszcząca Grota p.2'; Season = 'default' }
                [PSCustomObject]@{ Id = 119; Name = 'Świszcząca Grota p.3'; Season = 'default' }
                [PSCustomObject]@{ Id = 1;   Name = 'Ithan';                Season = 'default' }
            )

            $Result = Group-NerthusAddonFloors -Entries $Entries
            $Result.Keys.Count | Should -Be 2
            $Result['Świszcząca Grota'].Count | Should -Be 3
            $Result['Ithan'].Count | Should -Be 1
        }
    }
}
