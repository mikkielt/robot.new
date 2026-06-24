<#
    .SYNOPSIS
    WP-5 CC-4 coverage: AST scan asserting every public mutating cmdlet calls Assert-WriteAllowed.

    .DESCRIPTION
    Walks the AST of each file in the CC-4 call-site table and asserts that
    Assert-WriteAllowed appears at least once. A future write-introducing
    refactor that forgets the guard will fail this test, preventing silent
    ReadOnly-mode bypasses.
#>

BeforeAll {
    . "$PSScriptRoot/TestHelpers.ps1"
    $script:ModuleRoot = Split-Path $PSScriptRoot -Parent

    function Test-FileCallsAssertWriteAllowed {
        param([string]$RelativePath)
        $FullPath = Join-Path $script:ModuleRoot $RelativePath
        if (-not [System.IO.File]::Exists($FullPath)) {
            throw "Coverage target file missing: $RelativePath"
        }
        $Tokens = $null; $Errors = $null
        $Ast = [System.Management.Automation.Language.Parser]::ParseFile($FullPath, [ref]$Tokens, [ref]$Errors)
        $Calls = $Ast.FindAll({
            param($N)
            $N -is [System.Management.Automation.Language.CommandAst] -and
            $N.GetCommandName() -eq 'Assert-WriteAllowed'
        }, $true)
        return $Calls.Count -gt 0
    }
}

Describe 'CC-4: write-gate coverage' {
    It 'private/entity-writehelpers.ps1 calls Assert-WriteAllowed' {
        Test-FileCallsAssertWriteAllowed -RelativePath 'private/entity-writehelpers.ps1' | Should -BeTrue
    }
    It 'private/charfile-helpers.ps1 calls Assert-WriteAllowed' {
        Test-FileCallsAssertWriteAllowed -RelativePath 'private/charfile-helpers.ps1' | Should -BeTrue
    }
    It 'private/discord-state.ps1 calls Assert-WriteAllowed' {
        Test-FileCallsAssertWriteAllowed -RelativePath 'private/discord-state.ps1' | Should -BeTrue
    }
    It 'public/session/set-session.ps1 calls Assert-WriteAllowed' {
        Test-FileCallsAssertWriteAllowed -RelativePath 'public/session/set-session.ps1' | Should -BeTrue
    }
    It 'public/workflow/invoke-playercharacterpuassignment.ps1 calls Assert-WriteAllowed' {
        Test-FileCallsAssertWriteAllowed -RelativePath 'public/workflow/invoke-playercharacterpuassignment.ps1' | Should -BeTrue
    }
}
