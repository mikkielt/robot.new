BeforeAll {
    Import-Module "$PSScriptRoot/../../../robot.psm1" -Force -WarningAction SilentlyContinue
    . "$PSScriptRoot/../private/api-token-helpers.ps1"
}

Describe 'Token Generation' {
    It 'generates rbt_ prefixed token' {
        $Token = New-CryptoToken
        $Token | Should -BeLike 'rbt_*'
    }

    It 'generates token of approximately 48 characters' {
        $Token = New-CryptoToken
        $Token.Length | Should -BeGreaterOrEqual 45
        $Token.Length | Should -BeLessOrEqual 50
    }

    It 'generates unique tokens on successive calls' {
        $Token1 = New-CryptoToken
        $Token2 = New-CryptoToken
        $Token1 | Should -Not -Be $Token2
    }
}

Describe 'Token Store File I/O' {
    BeforeEach {
        $TestDir = Join-Path ([System.IO.Path]::GetTempPath()) "robot-test-tokens-$(Get-Random)"
        [void][System.IO.Directory]::CreateDirectory($TestDir)
        $TestFile = Join-Path $TestDir 'api-tokens.psd1'
    }

    AfterEach {
        if ([System.IO.Directory]::Exists($TestDir)) {
            [System.IO.Directory]::Delete($TestDir, $true)
        }
    }

    It 'reads empty array when file does not exist' {
        $Result = Import-ApiTokenStore -Path (Join-Path $TestDir 'nonexistent.psd1')
        $Result.Count | Should -Be 0
    }

    It 'write then read round-trips correctly' {
        $Tokens = @(
            @{
                Name      = 'test-token'
                Token     = 'rbt_abc123def456'
                Scopes    = @('entity:read', 'session:read')
                CreatedAt = '2026-03-17T10:00:00Z'
            }
        )

        Export-ApiTokenStore -Tokens $Tokens -Path $TestFile
        $Result = Import-ApiTokenStore -Path $TestFile

        $Result.Count | Should -Be 1
        $Result[0].Name | Should -Be 'test-token'
        $Result[0].Token | Should -Be 'rbt_abc123def456'
        $Result[0].Scopes | Should -Contain 'entity:read'
        $Result[0].Scopes | Should -Contain 'session:read'
        $Result[0].CreatedAt | Should -Be '2026-03-17T10:00:00Z'
    }

    It 'round-trips multiple tokens' {
        $Tokens = @(
            @{
                Name = 'token-a'; Token = 'rbt_aaa'; Scopes = @('entity:read'); CreatedAt = '2026-01-01T00:00:00Z'
            }
            @{
                Name = 'token-b'; Token = 'rbt_bbb'; Scopes = @('admin:all'); CreatedAt = '2026-02-01T00:00:00Z'
            }
        )

        Export-ApiTokenStore -Tokens $Tokens -Path $TestFile
        $Result = Import-ApiTokenStore -Path $TestFile

        $Result.Count | Should -Be 2
        $Result[0].Name | Should -Be 'token-a'
        $Result[1].Name | Should -Be 'token-b'
    }

    It 'writes UTF-8 without BOM' {
        $Tokens = @(
            @{ Name = 'test'; Token = 'rbt_x'; Scopes = @('entity:read'); CreatedAt = '2026-01-01T00:00:00Z' }
        )

        Export-ApiTokenStore -Tokens $Tokens -Path $TestFile
        $Bytes = [System.IO.File]::ReadAllBytes($TestFile)
        # UTF-8 BOM would be 0xEF 0xBB 0xBF
        if ($Bytes.Length -ge 3) {
            ($Bytes[0] -eq 0xEF -and $Bytes[1] -eq 0xBB -and $Bytes[2] -eq 0xBF) | Should -BeFalse
        }
    }

    It 'writes empty store correctly' {
        Export-ApiTokenStore -Tokens @() -Path $TestFile
        $Result = Import-ApiTokenStore -Path $TestFile
        $Result.Count | Should -Be 0
    }
}

Describe 'Token Store Sync' {
    BeforeAll {
        if (-not ([System.Management.Automation.PSTypeName]'Robot.ApiTokenStore').Type) {
            Set-ItResult -Skipped -Because 'Robot.ApiTokenStore not compiled'
        }
    }

    It 'syncs tokens from file to C# store' {
        $TestDir = Join-Path ([System.IO.Path]::GetTempPath()) "robot-test-sync-$(Get-Random)"
        [void][System.IO.Directory]::CreateDirectory($TestDir)
        $TestFile = Join-Path $TestDir 'api-tokens.psd1'

        try {
            $Tokens = @(
                @{
                    Name = 'sync-test'; Token = 'rbt_synctoken123'
                    Scopes = @('entity:read'); CreatedAt = '2026-03-17T00:00:00Z'
                }
            )
            Export-ApiTokenStore -Tokens $Tokens -Path $TestFile

            $Store = [Robot.ApiTokenStore]::new()
            Sync-ApiTokenStore -TokenStore $Store -FilePath $TestFile

            $Store.Count | Should -Be 1
            $Info = $Store.Authenticate('rbt_synctoken123')
            $Info | Should -Not -BeNullOrEmpty
            $Info.Name | Should -Be 'sync-test'
        } finally {
            [System.IO.Directory]::Delete($TestDir, $true)
        }
    }
}
