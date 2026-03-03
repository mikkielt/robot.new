<#
    .SYNOPSIS
    Pester tests for cli-help.ps1.

    .DESCRIPTION
    Tests for help content completeness: all menu categories are covered,
    every entry has a Title and Body, and keys match MenuOrder.
#>

BeforeAll {
    . "$PSScriptRoot/TestHelpers.ps1"
    Import-RobotModule

    # Dot-source CLI layers in dependency order
    . (Join-Path $script:ModuleRoot 'private' 'cli' 'cli-primitives.ps1')
    . (Join-Path $script:ModuleRoot 'private' 'cli' 'cli-help.ps1')
    . (Join-Path $script:ModuleRoot 'private' 'cli' 'cli-registry.ps1')

    $script:NavState = [PSCustomObject]@{
        Theme = 'Dark'
    }
}

Describe 'Help Content' {
    It 'has a root help entry' {
        $script:HelpContent['root'] | Should -Not -BeNullOrEmpty
    }

    It 'has help entries for all menu categories' {
        foreach ($Cat in $script:MenuOrder) {
            $script:HelpContent[$Cat] | Should -Not -BeNullOrEmpty `
                -Because "category '$Cat' should have a help entry"
        }
    }

    It 'all help entries have a Title' {
        foreach ($Key in $script:HelpContent.Keys) {
            $script:HelpContent[$Key].Title | Should -Not -BeNullOrEmpty `
                -Because "help entry '$Key' needs a Title"
        }
    }

    It 'all help entries have a non-empty Body array' {
        foreach ($Key in $script:HelpContent.Keys) {
            $script:HelpContent[$Key].Body | Should -Not -BeNullOrEmpty `
                -Because "help entry '$Key' needs a Body"
            $script:HelpContent[$Key].Body.Count | Should -BeGreaterThan 0 `
                -Because "help entry '$Key' Body should have at least one line"
        }
    }

    It 'help content keys match MenuOrder plus root' {
        $ExpectedKeys = @('root') + $script:MenuOrder
        foreach ($Key in $ExpectedKeys) {
            $script:HelpContent.ContainsKey($Key) | Should -BeTrue `
                -Because "help content should have key '$Key'"
        }
    }

    It 'has no extra keys beyond root and MenuOrder' {
        $ExpectedKeys = @('root') + $script:MenuOrder
        foreach ($Key in $script:HelpContent.Keys) {
            $Key | Should -BeIn $ExpectedKeys `
                -Because "unexpected help key '$Key'"
        }
    }
}
