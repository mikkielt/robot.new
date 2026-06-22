BeforeAll {
    Import-Module "$PSScriptRoot/../../../Robot.PowerShell.psm1" -Force -WarningAction SilentlyContinue
}

Describe 'Robot.ApiHelpRegistry' {
    BeforeAll {
        if (-not ([System.Management.Automation.PSTypeName]'Robot.ApiHelpRegistry').Type) {
            Set-ItResult -Skipped -Because 'Robot.ApiHelpRegistry not compiled'
        }
        $HelpDir = Join-Path $PSScriptRoot '..' 'help'
        if (-not (Test-Path $HelpDir)) {
            Set-ItResult -Skipped -Because 'help/ directory not found'
        }
        [Robot.ApiHelpRegistry]::Load($HelpDir)
    }

    Context 'Load and GetComponents' {
        It 'loads help directory without error' {
            $HelpDir = Join-Path $PSScriptRoot '..' 'help'
            { [Robot.ApiHelpRegistry]::Load($HelpDir) } | Should -Not -Throw
        }

        It 'returns all expected API components' {
            $Components = [Robot.ApiHelpRegistry]::GetComponents()
            $Components | Should -Contain 'sessions'
            $Components | Should -Contain 'entities'
            $Components | Should -Contain 'locations'
            $Components | Should -Contain 'currency'
            $Components | Should -Contain 'economy'
            $Components | Should -Contain 'reports'
            $Components | Should -Contain 'players'
            $Components | Should -Contain 'maps'
            $Components | Should -Contain 'session-graph'
            $Components | Should -Contain 'validate'
            $Components | Should -Contain 'resolve'
            $Components | Should -Contain 'parse'
            $Components | Should -Contain 'workflow'
            $Components | Should -Contain 'auth'
            $Components | Should -Contain 'files'
        }

        It 'returns non-API components (editor, cli)' {
            $Components = [Robot.ApiHelpRegistry]::GetComponents()
            $Components | Should -Contain 'editor'
            $Components | Should -Contain 'cli'
        }

        It 'returns exactly 18 components' {
            $Components = [Robot.ApiHelpRegistry]::GetComponents()
            $Components.Count | Should -Be 18
        }

        It 'includes the analytics component' {
            $Components = [Robot.ApiHelpRegistry]::GetComponents()
            $Components | Should -Contain 'analytics'
        }
    }

    Context 'GetHelp — basic queries' {
        It 'returns null for nonexistent component' {
            $Result = [Robot.ApiHelpRegistry]::GetHelp('nonexistent', $null, $null)
            $Result | Should -BeNullOrEmpty
        }

        It 'returns data for existing component' {
            $Result = [Robot.ApiHelpRegistry]::GetHelp('sessions', $null, $null)
            $Result | Should -Not -BeNullOrEmpty
            $Result['component'] | Should -Be 'sessions'
        }

        It 'returns endpoints array for API components' {
            $Result = [Robot.ApiHelpRegistry]::GetHelp('entities', $null, $null)
            $Result['endpoints'] | Should -Not -BeNullOrEmpty
            $Result['endpoints'].Count | Should -BeGreaterThan 0
        }

        It 'returns zones object for editor component' {
            $Result = [Robot.ApiHelpRegistry]::GetHelp('editor', $null, $null)
            $Result['zones'] | Should -Not -BeNullOrEmpty
        }

        It 'returns categories object for cli component' {
            $Result = [Robot.ApiHelpRegistry]::GetHelp('cli', $null, $null)
            $Result['categories'] | Should -Not -BeNullOrEmpty
        }
    }

    Context 'GetHelp — language filtering' {
        It 'filters to Polish only' {
            $Result = [Robot.ApiHelpRegistry]::GetHelp('sessions', 'pl', $null)
            $Result['endpoints'] | Should -Not -BeNullOrEmpty
            $Ep = $Result['endpoints'][0]
            $Ep['pl'] | Should -Not -BeNullOrEmpty
            $Ep.Keys | Should -Not -Contain 'en'
        }

        It 'filters to English only' {
            $Result = [Robot.ApiHelpRegistry]::GetHelp('sessions', 'en', $null)
            $Result['endpoints'] | Should -Not -BeNullOrEmpty
            $Ep = $Result['endpoints'][0]
            $Ep['en'] | Should -Not -BeNullOrEmpty
            $Ep.Keys | Should -Not -Contain 'pl'
        }
    }

    Context 'GetHelp — include filtering' {
        It 'filters fields by include parameter' {
            $Result = [Robot.ApiHelpRegistry]::GetHelp('sessions', 'pl', 'description,format')
            $Result['endpoints'] | Should -Not -BeNullOrEmpty
            $PlData = $Result['endpoints'][0]['pl']
            $PlData | Should -Not -BeNullOrEmpty
            $PlData['description'] | Should -Not -BeNullOrEmpty
        }
    }

    Context 'GetHelp — content validation' {
        It 'entity GET endpoint has query params documented' {
            $Result = [Robot.ApiHelpRegistry]::GetHelp('entities', $null, $null)
            $GetEndpoint = $Result['endpoints'] | Where-Object {
                $_['method'] -eq 'GET' -and $_['path'] -eq '/entities'
            }
            $GetEndpoint | Should -Not -BeNullOrEmpty
            $PlData = $GetEndpoint['pl']
            $PlData['queryParams'] | Should -Not -BeNullOrEmpty
            $ParamNames = $PlData['queryParams'] | ForEach-Object { $_['name'] }
            $ParamNames | Should -Contain 'filter'
            $ParamNames | Should -Contain 'sort'
        }

        It 'entity POST endpoint has required body fields' {
            $Result = [Robot.ApiHelpRegistry]::GetHelp('entities', $null, $null)
            $PostEndpoint = $Result['endpoints'] | Where-Object {
                $_['method'] -eq 'POST' -and $_['path'] -eq '/entities'
            }
            $PostEndpoint | Should -Not -BeNullOrEmpty
            $PlData = $PostEndpoint['pl']
            $PlData['bodyFields'] | Should -Not -BeNullOrEmpty
            $FieldNames = $PlData['bodyFields'] | ForEach-Object { $_['name'] }
            $FieldNames | Should -Contain 'name'
            $FieldNames | Should -Contain 'type'
        }

        It 'session POST endpoint has required body fields' {
            $Result = [Robot.ApiHelpRegistry]::GetHelp('sessions', 'pl', $null)
            $PostEndpoint = $Result['endpoints'] | Where-Object {
                $_['method'] -eq 'POST'
            }
            $PostEndpoint | Should -Not -BeNullOrEmpty
            $PlData = $PostEndpoint['pl']
            $FieldNames = $PlData['bodyFields'] | ForEach-Object { $_['name'] }
            $FieldNames | Should -Contain 'date'
            $FieldNames | Should -Contain 'title'
            $FieldNames | Should -Contain 'narrator'
            $FieldNames | Should -Contain 'path'
        }

        It 'every API component endpoint has both pl and en' {
            $ApiComponents = @('entities', 'sessions', 'players', 'locations', 'maps',
                'currency', 'economy', 'session-graph', 'reports', 'validate',
                'resolve', 'parse', 'workflow', 'auth', 'files')
            foreach ($C in $ApiComponents) {
                $Result = [Robot.ApiHelpRegistry]::GetHelp($C, $null, $null)
                $Result | Should -Not -BeNullOrEmpty -Because "$C should return data"
                foreach ($Ep in $Result['endpoints']) {
                    $Ep['pl'] | Should -Not -BeNullOrEmpty `
                        -Because "$C $($Ep['method']) $($Ep['path']) should have pl"
                    $Ep['en'] | Should -Not -BeNullOrEmpty `
                        -Because "$C $($Ep['method']) $($Ep['path']) should have en"
                }
            }
        }

        It 'every API endpoint has method and path' {
            foreach ($C in [Robot.ApiHelpRegistry]::GetComponents()) {
                $Result = [Robot.ApiHelpRegistry]::GetHelp($C, $null, $null)
                if (-not $Result['endpoints']) { continue }
                foreach ($Ep in $Result['endpoints']) {
                    $Ep['method'] | Should -Not -BeNullOrEmpty `
                        -Because "$C endpoint should have method"
                    $Ep['path'] | Should -Not -BeNullOrEmpty `
                        -Because "$C endpoint should have path"
                }
            }
        }
    }
}
