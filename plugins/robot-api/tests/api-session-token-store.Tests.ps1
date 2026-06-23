BeforeAll {
    Import-Module "$PSScriptRoot/../../../Robot.PowerShell.psm1" -Force -WarningAction SilentlyContinue
}

Describe 'Robot.ApiSessionTokenStore' {
    BeforeAll {
        if (-not ([System.Management.Automation.PSTypeName]'Robot.ApiSessionTokenStore').Type) {
            Set-ItResult -Skipped -Because 'Robot.ApiSessionTokenStore not compiled'
        }
    }

    function script:New-TokenInfo {
        param(
            [string]$Name = 'margonem:Test',
            [string]$Player = 'Test',
            [long]$UserId = 100,
            [string[]]$Scopes = @('entity:read'),
            [int]$TtlSeconds = 3600
        )
        $Now = [DateTimeOffset]::UtcNow
        $Info = [Robot.ApiTokenInfo]::new()
        $Info.Name           = $Name
        $Info.Scopes         = $Scopes
        $Info.CreatedAt      = $Now.ToString('o')
        $Info.CreatedAtTicks = $Now.UtcTicks
        $Info.ExpiresAt      = $Now.AddSeconds($TtlSeconds)
        $Info.PlayerName     = $Player
        $Info.MargonemUserId = $UserId
        return $Info
    }

    Context 'Add + Authenticate round-trip' {
        It 'authenticates a freshly added token' {
            $Store = [Robot.ApiSessionTokenStore]::new()
            $Info  = New-TokenInfo
            $Store.Add('rbs_test123', $Info) | Should -BeTrue
            $Back = $Store.Authenticate('rbs_test123')
            $Back | Should -Not -BeNullOrEmpty
            $Back.PlayerName | Should -Be 'Test'
            $Back.MargonemUserId | Should -Be 100
        }

        It 'returns null for unknown bearer' {
            $Store = [Robot.ApiSessionTokenStore]::new()
            $Store.Authenticate('rbs_nope') | Should -BeNullOrEmpty
        }

        It 'rejects empty bearer' {
            $Store = [Robot.ApiSessionTokenStore]::new()
            $Store.Authenticate('') | Should -BeNullOrEmpty
            $Store.Authenticate($null) | Should -BeNullOrEmpty
        }
    }

    Context 'Expiry' {
        It 'returns null and evicts on expired bearer' {
            $Store = [Robot.ApiSessionTokenStore]::new()
            $Info  = New-TokenInfo -TtlSeconds -1   # already expired
            $Store.Add('rbs_dead', $Info) | Should -BeTrue
            $Back = $Store.Authenticate('rbs_dead')
            $Back | Should -BeNullOrEmpty
            $Store.Count | Should -Be 0  # entry was evicted in-line
        }
    }

    Context 'Player revocation' {
        It 'RemoveByPlayer removes only that player' {
            $Store = [Robot.ApiSessionTokenStore]::new()
            $Store.Add('rbs_alice1', (New-TokenInfo -Name 'margonem:Alice' -Player 'Alice')) | Out-Null
            $Store.Add('rbs_alice2', (New-TokenInfo -Name 'margonem:Alice' -Player 'Alice')) | Out-Null
            $Store.Add('rbs_bob1',   (New-TokenInfo -Name 'margonem:Bob'   -Player 'Bob'))   | Out-Null

            $Removed = $Store.RemoveByPlayer('Alice')
            $Removed | Should -Be 2
            $Store.Count | Should -Be 1
            $Store.Authenticate('rbs_bob1') | Should -Not -BeNullOrEmpty
        }

        It 'RemoveByPlayer is case-insensitive on the player name' {
            $Store = [Robot.ApiSessionTokenStore]::new()
            $Store.Add('rbs_x', (New-TokenInfo -Player 'Alice')) | Out-Null
            $Store.RemoveByPlayer('alice') | Should -Be 1
        }
    }

    Context 'Capacity eviction (FIFO by CreatedAtTicks)' {
        It 'drops the oldest entry when MaxEntries is reached' {
            $Store = [Robot.ApiSessionTokenStore]::new()
            $Store.MaxEntries = 3

            # Build entries with strictly increasing CreatedAtTicks
            for ($i = 1; $i -le 3; $i++) {
                $Info = [Robot.ApiTokenInfo]::new()
                $Info.Name = "margonem:P$i"
                $Info.CreatedAtTicks = $i  # 1, 2, 3 — P1 is oldest
                $Info.ExpiresAt = [DateTimeOffset]::UtcNow.AddHours(1)
                $Info.PlayerName = "P$i"
                $Store.Add("rbs_$i", $Info) | Out-Null
            }
            $Store.Count | Should -Be 3

            # Adding a fourth should evict P1 (the oldest)
            $Info4 = [Robot.ApiTokenInfo]::new()
            $Info4.Name = 'margonem:P4'
            $Info4.CreatedAtTicks = 4
            $Info4.ExpiresAt = [DateTimeOffset]::UtcNow.AddHours(1)
            $Info4.PlayerName = 'P4'
            $Store.Add('rbs_4', $Info4) | Out-Null

            $Store.Count | Should -Be 3
            $Store.Authenticate('rbs_1') | Should -BeNullOrEmpty
            $Store.Authenticate('rbs_4') | Should -Not -BeNullOrEmpty
        }
    }

    Context 'ListSessions emits no raw bearers' {
        It 'returns metadata only, never the token string' {
            $Store = [Robot.ApiSessionTokenStore]::new()
            $Store.Add('rbs_secret', (New-TokenInfo)) | Out-Null
            $List = $Store.ListSessions()
            $List.Count | Should -Be 1
            $Entry = $List[0]
            # Sanity: present fields
            $Entry['name']           | Should -Not -BeNullOrEmpty
            $Entry['player']         | Should -Be 'Test'
            $Entry['margonemUserId'] | Should -Be 100
            # The raw bearer must NEVER appear in any field
            foreach ($V in $Entry.Values) {
                ([string]$V) | Should -Not -Match 'rbs_secret'
            }
        }
    }
}
