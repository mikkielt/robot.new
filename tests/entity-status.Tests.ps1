BeforeAll {
    $script:ModuleRoot = Split-Path $PSScriptRoot -Parent
    . "$script:ModuleRoot/get-entity.ps1"

    $script:TempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("robot-status-" + [System.Guid]::NewGuid().ToString('N'))
    [System.IO.Directory]::CreateDirectory($script:TempRoot) | Out-Null

    function script:Write-TestFile {
        param([string]$Path, [string]$Content)
        [System.IO.File]::WriteAllText($Path, $Content, [System.Text.UTF8Encoding]::new($false))
    }

    # Mock Get-RepoRoot to return temp dir
    function Get-RepoRoot { return $script:TempRoot }

    # Mock Get-Markdown for entity file parsing
    Import-Module $script:ModuleRoot/robot.psd1 -Force
}

AfterAll {
    if ($script:TempRoot -and [System.IO.Directory]::Exists($script:TempRoot)) {
        [System.IO.Directory]::Delete($script:TempRoot, $true)
    }
}

Describe '@status tag parsing in Get-Entity' {
    Context 'Basic @status parsing' {
        BeforeAll {
            $EntFile = Join-Path $script:TempRoot 'entities.md'
            Write-TestFile -Path $EntFile -Content @'
## NPC

* Test NPC
    - @status: Aktywny (2024-01:)

* Inactive NPC
    - @status: Nieaktywny (2025-01:)

* Deleted NPC
    - @status: Usunięty (2025-06:)
'@
            $script:Entities = Get-Entity -Path $script:TempRoot
        }

        It 'parses Aktywny status' {
            $E = $script:Entities | Where-Object { $_.Name -eq 'Test NPC' }
            $E.Status | Should -Be 'Aktywny'
        }

        It 'parses Nieaktywny status' {
            $E = $script:Entities | Where-Object { $_.Name -eq 'Inactive NPC' }
            $E.Status | Should -Be 'Nieaktywny'
        }

        It 'parses Usunięty status' {
            $E = $script:Entities | Where-Object { $_.Name -eq 'Deleted NPC' }
            $E.Status | Should -Be 'Usunięty'
        }

        It 'has StatusHistory entries' {
            $E = $script:Entities | Where-Object { $_.Name -eq 'Test NPC' }
            $E.StatusHistory.Count | Should -Be 1
            $E.StatusHistory[0].Status | Should -Be 'Aktywny'
        }
    }

    Context 'Default Aktywny when no @status' {
        BeforeAll {
            $EntFile = Join-Path $script:TempRoot 'entities.md'
            Write-TestFile -Path $EntFile -Content @'
## NPC

* No Status NPC
    - @lokacja: Erathia
'@
            $script:Entities = Get-Entity -Path $script:TempRoot
        }

        It 'defaults to Aktywny' {
            $E = $script:Entities | Where-Object { $_.Name -eq 'No Status NPC' }
            $E.Status | Should -Be 'Aktywny'
        }

        It 'has empty StatusHistory' {
            $E = $script:Entities | Where-Object { $_.Name -eq 'No Status NPC' }
            $E.StatusHistory.Count | Should -Be 0
        }
    }

    Context 'Temporal status transitions' {
        BeforeAll {
            $EntFile = Join-Path $script:TempRoot 'entities.md'
            Write-TestFile -Path $EntFile -Content @'
## NPC

* Transitioning NPC
    - @status: Aktywny (2024-01:2024-06)
    - @status: Nieaktywny (2024-07:2025-01)
    - @status: Aktywny (2025-02:)
'@
            $script:Entities = Get-Entity -Path $script:TempRoot
        }

        It 'resolves most recent status without date filter' {
            $E = $script:Entities | Where-Object { $_.Name -eq 'Transitioning NPC' }
            $E.Status | Should -Be 'Aktywny'
        }

        It 'resolves status at specific date (mid inactive period)' {
            $Entities = Get-Entity -Path $script:TempRoot -ActiveOn ([datetime]::ParseExact('2024-10-15', 'yyyy-MM-dd', $null))
            $E = $Entities | Where-Object { $_.Name -eq 'Transitioning NPC' }
            $E.Status | Should -Be 'Nieaktywny'
        }
    }

    Context 'Przedmiot entity type' {
        BeforeAll {
            $EntFile = Join-Path $script:TempRoot 'entities.md'
            Write-TestFile -Path $EntFile -Content @'
## Przedmiot

* Zaklęty kielich
    - @należy_do: Solmyr (2024-06:)
    - @status: Aktywny (2024-06:)
'@
            $script:Entities = Get-Entity -Path $script:TempRoot
        }

        It 'parses Przedmiot type' {
            $E = $script:Entities | Where-Object { $_.Name -eq 'Zaklęty kielich' }
            $E.Type | Should -Be 'Przedmiot'
        }

        It 'resolves ownership' {
            $E = $script:Entities | Where-Object { $_.Name -eq 'Zaklęty kielich' }
            $E.Owner | Should -Be 'Solmyr'
        }
    }
}
