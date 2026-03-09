<#
    .SYNOPSIS
    Tests for cli-input.ps1 — key routing and filter management.

    .DESCRIPTION
    Validates key routing decisions, filter management, command palette
    parsing, and paste detection. Uses Pattern C (standalone helper
    dot-sourcing).

    Tests the routing logic only — no interactive input is tested.
#>

BeforeAll {
    . "$PSScriptRoot/TestHelpers.ps1"

    # Dot-source dependencies in order
    . "$script:ModuleRoot/private/cli/cli-primitives.ps1"
    . "$script:ModuleRoot/private/cli/engine/cli-engine.ps1"
    . "$script:ModuleRoot/private/cli/engine/cli-buffer.ps1"
    . "$script:ModuleRoot/private/cli/engine/cli-input.ps1"

    $script:ScreenWidth  = 80
    $script:ScreenHeight = 24
    Build-Regions

    # Helper to create a mock ConsoleKeyInfo
    function New-MockKeyInfo {
        param(
            [char]$KeyChar = [char]0,
            [System.ConsoleKey]$Key = [System.ConsoleKey]::NoName,
            [switch]$Shift,
            [switch]$Alt,
            [switch]$Control
        )
        return [System.ConsoleKeyInfo]::new($KeyChar, $Key, [bool]$Shift, [bool]$Alt, [bool]$Control)
    }

    # Mock component for testing
    function New-MockComponent {
        param([switch]$Filterable)
        return @{
            Filterable     = [bool]$Filterable
            FilterPrefixes = @{ 'npc' = 'NPC'; 'lok' = 'Lokacja' }
        }
    }
}

Describe 'Route-KeyPress — No filter, no command mode' {

    BeforeEach {
        Reset-Filter
        Reset-CommandMode
    }

    It 'routes UpArrow to Navigate Up' {
        $Key = New-MockKeyInfo -Key 'UpArrow'
        $Component = New-MockComponent
        $Action = Route-KeyPress -Key $Key -Component $Component
        $Action.Type | Should -Be 'Navigate'
        $Action.Value | Should -Be 'Up'
    }

    It 'routes DownArrow to Navigate Down' {
        $Key = New-MockKeyInfo -Key 'DownArrow'
        $Component = New-MockComponent
        $Action = Route-KeyPress -Key $Key -Component $Component
        $Action.Type | Should -Be 'Navigate'
        $Action.Value | Should -Be 'Down'
    }

    It 'routes LeftArrow to Navigate Left' {
        $Key = New-MockKeyInfo -Key 'LeftArrow'
        $Component = New-MockComponent
        $Action = Route-KeyPress -Key $Key -Component $Component
        $Action.Type | Should -Be 'Navigate'
        $Action.Value | Should -Be 'Left'
    }

    It 'routes RightArrow to Navigate Right' {
        $Key = New-MockKeyInfo -Key 'RightArrow'
        $Component = New-MockComponent
        $Action = Route-KeyPress -Key $Key -Component $Component
        $Action.Type | Should -Be 'Navigate'
        $Action.Value | Should -Be 'Right'
    }

    It 'routes Enter to Select' {
        $Key = New-MockKeyInfo -Key 'Enter' -KeyChar ([char]13)
        $Component = New-MockComponent
        $Action = Route-KeyPress -Key $Key -Component $Component
        $Action.Type | Should -Be 'Select'
    }

    It 'routes Tab to Select' {
        $Key = New-MockKeyInfo -Key 'Tab' -KeyChar ([char]9)
        $Component = New-MockComponent
        $Action = Route-KeyPress -Key $Key -Component $Component
        $Action.Type | Should -Be 'Select'
    }

    It 'routes Escape to Back' {
        $Key = New-MockKeyInfo -Key 'Escape' -KeyChar ([char]27)
        $Component = New-MockComponent
        $Action = Route-KeyPress -Key $Key -Component $Component
        $Action.Type | Should -Be 'Back'
    }

    It 'routes q to Back' {
        $Key = New-MockKeyInfo -KeyChar 'q' -Key 'Q'
        $Component = New-MockComponent
        $Action = Route-KeyPress -Key $Key -Component $Component
        $Action.Type | Should -Be 'Back'
    }

    It 'routes / to CommandStart' {
        $Key = New-MockKeyInfo -KeyChar '/'
        $Component = New-MockComponent
        $Action = Route-KeyPress -Key $Key -Component $Component
        $Action.Type | Should -Be 'CommandStart'
        $script:CommandMode | Should -BeTrue
    }

    It 'routes printable char to FilterStart when component is filterable' {
        $Key = New-MockKeyInfo -KeyChar 'a' -Key 'A'
        $Component = New-MockComponent -Filterable
        $Action = Route-KeyPress -Key $Key -Component $Component
        $Action.Type | Should -Be 'FilterStart'
        $Action.Value | Should -Be 'a'
        $script:FilterActive | Should -BeTrue
    }

    It 'routes printable char to None when component is not filterable' {
        $Key = New-MockKeyInfo -KeyChar 'a' -Key 'A'
        $Component = New-MockComponent
        $Action = Route-KeyPress -Key $Key -Component $Component
        $Action.Type | Should -Be 'None'
    }
}

Describe 'Route-KeyPress — Filter active' {

    BeforeEach {
        Reset-Filter
        Reset-CommandMode
        $script:FilterActive = $true
        [void]$script:FilterBuffer.Append('abc')
    }

    It 'appends printable char to filter' {
        $Key = New-MockKeyInfo -KeyChar 'd' -Key 'D'
        $Component = New-MockComponent -Filterable
        $Action = Route-KeyPress -Key $Key -Component $Component
        $Action.Type | Should -Be 'FilterUpdate'
        $Action.Value | Should -Be 'abcd'
    }

    It 'routes Backspace to FilterUpdate (removes last char)' {
        $Key = New-MockKeyInfo -Key 'Backspace' -KeyChar ([char]8)
        $Component = New-MockComponent -Filterable
        $Action = Route-KeyPress -Key $Key -Component $Component
        $Action.Type | Should -Be 'FilterUpdate'
        $Action.Value | Should -Be 'ab'
    }

    It 'routes Backspace on single char to FilterClear' {
        Reset-Filter
        $script:FilterActive = $true
        [void]$script:FilterBuffer.Append('x')

        $Key = New-MockKeyInfo -Key 'Backspace' -KeyChar ([char]8)
        $Component = New-MockComponent -Filterable
        $Action = Route-KeyPress -Key $Key -Component $Component
        $Action.Type | Should -Be 'FilterClear'
        $script:FilterActive | Should -BeFalse
    }

    It 'routes Escape to FilterClear' {
        $Key = New-MockKeyInfo -Key 'Escape' -KeyChar ([char]27)
        $Component = New-MockComponent -Filterable
        $Action = Route-KeyPress -Key $Key -Component $Component
        $Action.Type | Should -Be 'FilterClear'
        $script:FilterActive | Should -BeFalse
    }

    It 'routes UpArrow to Navigate Up while filtering' {
        $Key = New-MockKeyInfo -Key 'UpArrow'
        $Component = New-MockComponent -Filterable
        $Action = Route-KeyPress -Key $Key -Component $Component
        $Action.Type | Should -Be 'Navigate'
        $Action.Value | Should -Be 'Up'
    }

    It 'routes Enter to Select while filtering' {
        $Key = New-MockKeyInfo -Key 'Enter' -KeyChar ([char]13)
        $Component = New-MockComponent -Filterable
        $Action = Route-KeyPress -Key $Key -Component $Component
        $Action.Type | Should -Be 'Select'
    }
}

Describe 'Route-KeyPress — Command mode' {

    BeforeEach {
        Reset-Filter
        $script:CommandMode = $true
        [void]$script:CommandBuffer.Clear()
    }

    It 'h buffers for sub-commands instead of auto-executing' {
        $Key = New-MockKeyInfo -KeyChar 'h' -Key 'H'
        $Component = New-MockComponent
        $Action = Route-KeyPress -Key $Key -Component $Component
        $Action.Type | Should -Be 'Redraw'
        $script:CommandMode | Should -BeTrue
        $script:CommandBuffer.ToString() | Should -Be 'h'
    }

    It 'single-letter s executes immediately' {
        $Key = New-MockKeyInfo -KeyChar 's' -Key 'S'
        $Component = New-MockComponent
        $Action = Route-KeyPress -Key $Key -Component $Component
        $Action.Type | Should -Be 'Command'
        $Action.Value | Should -Be 's'
    }

    It 'single-letter q executes immediately' {
        $Key = New-MockKeyInfo -KeyChar 'q' -Key 'Q'
        $Component = New-MockComponent
        $Action = Route-KeyPress -Key $Key -Component $Component
        $Action.Type | Should -Be 'Command'
        $Action.Value | Should -Be 'q'
    }

    It 'Escape exits command mode' {
        $Key = New-MockKeyInfo -Key 'Escape' -KeyChar ([char]27)
        $Component = New-MockComponent
        $Action = Route-KeyPress -Key $Key -Component $Component
        $Action.Type | Should -Be 'Redraw'
        $script:CommandMode | Should -BeFalse
    }

    It 'Backspace on empty buffer exits command mode' {
        $Key = New-MockKeyInfo -Key 'Backspace' -KeyChar ([char]8)
        $Component = New-MockComponent
        $Action = Route-KeyPress -Key $Key -Component $Component
        $Action.Type | Should -Be 'Redraw'
        $script:CommandMode | Should -BeFalse
    }
}

Describe 'Split-FilterQuery' {

    It 'parses simple query without prefix' {
        $Result = Split-FilterQuery -RawInput 'thar' -FilterPrefixes @{ 'npc' = 'NPC' }
        $Result.TypeFilter | Should -BeNullOrEmpty
        $Result.Query | Should -Be 'thar'
    }

    It 'parses known prefix:query' {
        $Prefixes = @{ 'npc' = 'NPC'; 'lok' = 'Lokacja' }
        $Result = Split-FilterQuery -RawInput 'npc:thar' -FilterPrefixes $Prefixes
        $Result.TypeFilter | Should -Be 'NPC'
        $Result.Query | Should -Be 'thar'
        $Result.Prefix | Should -Be 'npc'
    }

    It 'treats unknown prefix as regular query' {
        $Prefixes = @{ 'npc' = 'NPC' }
        $Result = Split-FilterQuery -RawInput 'xyz:thar' -FilterPrefixes $Prefixes
        $Result.TypeFilter | Should -BeNullOrEmpty
        $Result.Query | Should -Be 'xyz:thar'
    }

    It 'handles Polish prefix characters' {
        $Prefixes = @{ 'postac' = 'Postac' }
        $Result = Split-FilterQuery -RawInput 'postac:Jan' -FilterPrefixes $Prefixes
        $Result.TypeFilter | Should -Be 'Postac'
        $Result.Query | Should -Be 'Jan'
    }

    It 'handles empty query after prefix' {
        $Prefixes = @{ 'npc' = 'NPC' }
        $Result = Split-FilterQuery -RawInput 'npc:' -FilterPrefixes $Prefixes
        $Result.TypeFilter | Should -Be 'NPC'
        $Result.Query | Should -BeNullOrEmpty
    }

    It 'handles null filter prefixes' {
        $Result = Split-FilterQuery -RawInput 'npc:test' -FilterPrefixes $null
        $Result.TypeFilter | Should -BeNullOrEmpty
        $Result.Query | Should -Be 'npc:test'
    }
}

Describe 'Invoke-SlashCommand' {

    It 'returns Help for /h' {
        $Action = Invoke-SlashCommand -Command 'h'
        $Action.Type | Should -Be 'Help'
    }

    It 'returns HelpSearch for /h topic' {
        $Action = Invoke-SlashCommand -Command 'h session'
        $Action.Type | Should -Be 'HelpSearch'
        $Action.Value | Should -Be 'session'
    }

    It 'falls back to Help when /h has empty query' {
        $Action = Invoke-SlashCommand -Command 'h '
        $Action.Type | Should -Be 'Help'
    }

    It 'falls back to Help when /h has only spaces' {
        $Action = Invoke-SlashCommand -Command 'h   '
        $Action.Type | Should -Be 'Help'
    }

    It 'returns HelpExtended for /hh' {
        $Action = Invoke-SlashCommand -Command 'hh'
        $Action.Type | Should -Be 'HelpExtended'
    }

    It 'returns HealthDashboard for /s' {
        $Action = Invoke-SlashCommand -Command 's'
        $Action.Type | Should -Be 'HealthDashboard'
    }

    It 'returns Refresh for /r' {
        $Action = Invoke-SlashCommand -Command 'r'
        $Action.Type | Should -Be 'Refresh'
    }

    It 'returns Back for /b' {
        $Action = Invoke-SlashCommand -Command 'b'
        $Action.Type | Should -Be 'Back'
    }

    It 'returns Quit for /q' {
        $Action = Invoke-SlashCommand -Command 'q'
        $Action.Type | Should -Be 'Quit'
    }

    It 'returns None for unknown command' {
        $Action = Invoke-SlashCommand -Command 'xyz'
        $Action.Type | Should -Be 'None'
    }
}

Describe 'Test-PasteSequence' {

    It 'returns true for rapid keystrokes (< 20ms)' {
        $script:LastKeyTimestamp = [datetime]::Now
        Start-Sleep -Milliseconds 5
        $Result = Test-PasteSequence -Now ([datetime]::Now)
        $Result | Should -BeTrue
    }

    It 'returns false for slow keystrokes (> 20ms)' {
        $script:LastKeyTimestamp = [datetime]::Now.AddMilliseconds(-100)
        $Result = Test-PasteSequence -Now ([datetime]::Now)
        $Result | Should -BeFalse
    }
}

Describe 'Reset-Filter' {

    It 'clears filter buffer and deactivates filter' {
        $script:FilterActive = $true
        [void]$script:FilterBuffer.Clear()
        [void]$script:FilterBuffer.Append('test')

        Reset-Filter

        $script:FilterActive | Should -BeFalse
        Get-FilterText | Should -BeNullOrEmpty
    }
}

Describe 'Get-FilterText' {

    It 'returns current filter buffer as string' {
        [void]$script:FilterBuffer.Clear()
        [void]$script:FilterBuffer.Append('hello')
        Get-FilterText | Should -Be 'hello'
    }

    It 'returns empty string when buffer is empty' {
        [void]$script:FilterBuffer.Clear()
        Get-FilterText | Should -BeNullOrEmpty
    }
}

Describe 'FilterHintPending' {

    It 'sets FilterHintPending on first filter activation' {
        # Reset state
        $script:FilterActive = $false
        $script:FilterHintShown = $false
        $script:FilterHintPending = $false
        [void]$script:FilterBuffer.Clear()

        $Component = @{ Filterable = $true }
        $Key = [System.ConsoleKeyInfo]::new('a', [System.ConsoleKey]::A, $false, $false, $false)
        $Action = Route-KeyPress -Key $Key -Component $Component -State $null

        $Action.Type | Should -Be 'FilterStart'
        $script:FilterHintShown | Should -BeTrue
        $script:FilterHintPending | Should -BeTrue
    }

    It 'does not set FilterHintPending on subsequent filter activations' {
        # Reset with hint already shown
        $script:FilterActive = $false
        $script:FilterHintShown = $true
        $script:FilterHintPending = $false
        [void]$script:FilterBuffer.Clear()

        $Component = @{ Filterable = $true }
        $Key = [System.ConsoleKeyInfo]::new('b', [System.ConsoleKey]::B, $false, $false, $false)
        $Action = Route-KeyPress -Key $Key -Component $Component -State $null

        $Action.Type | Should -Be 'FilterStart'
        $script:FilterHintPending | Should -BeFalse
    }
}

Describe 'Route-KeyPress — TextInputMode' {

    BeforeEach {
        Reset-Filter
        Reset-CommandMode
    }

    It 'routes printable char as TextInput' {
        $Component = @{ TextInputMode = $true }
        $Key = New-MockKeyInfo -Key 'A' -KeyChar 'a'
        $Action = Route-KeyPress -Key $Key -Component $Component -State $null
        $Action.Type | Should -Be 'TextInput'
        $Action.Value | Should -Be 'a'
    }

    It 'routes slash as TextInput (not CommandStart)' {
        $Component = @{ TextInputMode = $true }
        $Key = New-MockKeyInfo -Key 'Oem2' -KeyChar '/'
        $Action = Route-KeyPress -Key $Key -Component $Component -State $null
        $Action.Type | Should -Be 'TextInput'
        $Action.Value | Should -Be '/'
    }

    It 'routes q as TextInput (not Back)' {
        $Component = @{ TextInputMode = $true }
        $Key = New-MockKeyInfo -Key 'Q' -KeyChar 'q'
        $Action = Route-KeyPress -Key $Key -Component $Component -State $null
        $Action.Type | Should -Be 'TextInput'
        $Action.Value | Should -Be 'q'
    }

    It 'routes Backspace as TextBackspace' {
        $Component = @{ TextInputMode = $true }
        $Key = New-MockKeyInfo -Key 'Backspace' -KeyChar ([char]8)
        $Action = Route-KeyPress -Key $Key -Component $Component -State $null
        $Action.Type | Should -Be 'TextBackspace'
    }

    It 'routes Enter as Select' {
        $Component = @{ TextInputMode = $true }
        $Key = New-MockKeyInfo -Key 'Enter' -KeyChar ([char]13)
        $Action = Route-KeyPress -Key $Key -Component $Component -State $null
        $Action.Type | Should -Be 'Select'
    }

    It 'routes Escape as Back' {
        $Component = @{ TextInputMode = $true }
        $Key = New-MockKeyInfo -Key 'Escape' -KeyChar ([char]27)
        $Action = Route-KeyPress -Key $Key -Component $Component -State $null
        $Action.Type | Should -Be 'Back'
    }

    It 'routes Up/Down arrows as Navigate' {
        $Component = @{ TextInputMode = $true }

        $Key = New-MockKeyInfo -Key 'UpArrow'
        $Action = Route-KeyPress -Key $Key -Component $Component -State $null
        $Action.Type | Should -Be 'Navigate'
        $Action.Value | Should -Be 'Up'

        $Key = New-MockKeyInfo -Key 'DownArrow'
        $Action = Route-KeyPress -Key $Key -Component $Component -State $null
        $Action.Type | Should -Be 'Navigate'
        $Action.Value | Should -Be 'Down'
    }

    It 'does not activate filter or command mode' {
        $Component = @{ TextInputMode = $true }
        $Key = New-MockKeyInfo -Key 'A' -KeyChar 'a'
        $Action = Route-KeyPress -Key $Key -Component $Component -State $null
        $script:FilterActive | Should -BeFalse
        $script:CommandMode | Should -BeFalse
    }
}
