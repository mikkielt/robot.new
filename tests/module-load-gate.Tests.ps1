<#
    .SYNOPSIS
    Pester tests for the WP-5 module load gate.
#>

BeforeAll {
    . "$PSScriptRoot/TestHelpers.ps1"
    Import-RobotModule
}

Describe 'Module load gate (CC-5 sentinel matrix)' {
    It 'exposes Get-SchemaState with a Mode field' {
        $S = Get-SchemaState
        $S | Should -Not -BeNullOrEmpty
        $S.Mode | Should -BeIn @('Unknown', 'Normal', 'ReadOnly', 'Refused')
    }

    It 'SupportedMin and SupportedMax come from the manifest' {
        $S = Get-SchemaState
        $S.SupportedMin | Should -Be '0.0.0'
        $S.SupportedMax | Should -Be '1.99.99'
    }

    It 'fresh-repo (no schema.json) loads in Normal mode' {
        # Test harness firewall installs a temp Get-RepoRoot — fresh repo path.
        $S = Get-SchemaState
        $S.Mode | Should -Be 'Normal'
        $S.Current | Should -Be '0.0.0'
    }
}

Describe 'Assert-WriteAllowed' {
    AfterEach {
        # Restore Normal so other tests are unaffected
        $State = Get-SchemaState
        $State.Mode = 'Normal'
    }

    It 'does not throw in Normal mode' {
        $State = Get-SchemaState
        $State.Mode = 'Normal'
        { Assert-WriteAllowed } | Should -Not -Throw
    }

    It 'does not throw in Unknown mode (no repo)' {
        $State = Get-SchemaState
        $State.Mode = 'Unknown'
        { Assert-WriteAllowed } | Should -Not -Throw
    }

    It 'throws SchemaTooOld in ReadOnly mode' {
        $State = Get-SchemaState
        $State.Mode = 'ReadOnly'
        $State.Current = '0.0.0'
        $State.SupportedMin = '1.0.0'
        { Assert-WriteAllowed } | Should -Throw -ErrorId 'SchemaTooOld'
    }

    It '-BypassSchemaGate suppresses the throw' {
        $State = Get-SchemaState
        $State.Mode = 'ReadOnly'
        { Assert-WriteAllowed -BypassSchemaGate } | Should -Not -Throw
    }
}
