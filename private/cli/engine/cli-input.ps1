<#
    .SYNOPSIS
    Unified input loop and key routing for the Robot CLI TUI engine.

    .DESCRIPTION
    Central input handler that reads keystrokes, detects paste sequences,
    routes keys to the active component or global handlers (command palette,
    filter, navigation), and manages the render cycle.

    Helpers:
    - Start-InputLoop:       main loop — reads keys, routes, renders
    - Route-KeyPress:        decides action based on key + current mode
    - Update-Filter:         appends/removes characters from filter buffer
    - Split-FilterQuery:     parses "type:query" prefix syntax
    - Invoke-SlashCommand:   executes /h, /s, /r, /b, /q palette commands
    - Test-PasteSequence:    detects rapid keystroke sequences (< 20ms)
    - Invoke-FuzzyDebounce:  waits 300ms then triggers stage 3 fuzzy search

    Module-level data:
    - $script:FilterBuffer:       current filter text (StringBuilder)
    - $script:FilterActive:       $true when filter bar is shown
    - $script:CommandMode:        $true when / command palette is active
    - $script:CommandBuffer:      command text after /
    - $script:FilterHintShown:    $true after first filter hint has been displayed
    - $script:FilterHintPending:  $true for one render cycle after first filter activation
    - $script:LastKeyTimestamp:   for paste detection
    - $script:FuzzyDebounceMs:    300ms delay before stage-3 fuzzy triggers

    Key routing table:
        Key             Filter empty       Filter active       Command mode (/)   TextInputMode
        ─────────────   ──────────────     ───────────────     ──────────────────  ─────────────
        Printable       Enter filter       Append to filter    Append to command   TextInput
        Up/Down         Navigate content   Navigate filtered   N/A                 Navigate
        Left/Right      Page (tables)      N/A                 N/A                 N/A
        Enter           Select             Select top match    Execute command     Select
        Tab             Select top match   Select top match    N/A                 Select
        Backspace       N/A                Delete filter char  Delete command char  TextBackspace
        Escape          Go back            Clear filter        Exit command mode   Back
        /               Enter command      Literal /           N/A                 TextInput
#>

# ── Module-level data ────────────────────────────────────────────────────────

$script:FilterBuffer      = [System.Text.StringBuilder]::new()
$script:FilterActive      = $false
$script:CommandMode       = $false
$script:CommandBuffer     = [System.Text.StringBuilder]::new()
$script:FilterHintShown   = $false
$script:FilterHintPending = $false
$script:LastKeyTimestamp   = [datetime]::MinValue
$script:FuzzyDebounceMs   = 300
$script:FilterPrefixRegex = [regex]::new('^([a-zA-Z\u0105\u0107\u0119\u0142\u0144\u00F3\u015B\u017A\u017C\u0104\u0106\u0118\u0141\u0143\u00D3\u015A\u0179\u017B]+):(.*)$', [System.Text.RegularExpressions.RegexOptions]::Compiled)

# ── Action Types ─────────────────────────────────────────────────────────────

# Action objects returned by Route-KeyPress
function New-InputAction {
    param(
        [Parameter(Mandatory)] [string]$Type,
        $Value = $null
    )
    return @{
        Type  = $Type
        Value = $Value
    }
}

# ── Paste Detection ──────────────────────────────────────────────────────────

function Test-PasteSequence {
    param([datetime]$Now)
    $Elapsed = ($Now - $script:LastKeyTimestamp).TotalMilliseconds
    return ($Elapsed -lt 20)
}

# ── Filter Management ────────────────────────────────────────────────────────

function Reset-Filter {
    [void]$script:FilterBuffer.Clear()
    $script:FilterActive = $false
}

function Get-FilterText {
    return $script:FilterBuffer.ToString()
}

function Split-FilterQuery {
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string]$RawInput,
        [hashtable]$FilterPrefixes
    )

    # Polish-aware prefix pattern: "prefix:query"
    $M = $script:FilterPrefixRegex.Match($RawInput)
    if ($M.Success) {
        $PrefixKey = $M.Groups[1].Value
        $Query = $M.Groups[2].Value

        if ($FilterPrefixes -and $FilterPrefixes.ContainsKey($PrefixKey)) {
            return @{
                TypeFilter = $FilterPrefixes[$PrefixKey]
                Query      = $Query
                Prefix     = $PrefixKey
            }
        }
    }

    return @{
        TypeFilter = $null
        Query      = $RawInput
        Prefix     = $null
    }
}

# ── Command Palette ──────────────────────────────────────────────────────────

function Reset-CommandMode {
    [void]$script:CommandBuffer.Clear()
    $script:CommandMode = $false
}

# ── Route-KeyPress ───────────────────────────────────────────────────────────

function Route-KeyPress {
    param(
        [Parameter(Mandatory)] [System.ConsoleKeyInfo]$Key,
        [Parameter(Mandatory)] [object]$Component,
        [object]$State
    )

    $KeyEnum = $Key.Key
    $KeyChar = $Key.KeyChar

    # ── Command mode: / was typed ──
    if ($script:CommandMode) {
        switch ($KeyEnum) {
            'Escape' {
                Reset-CommandMode
                return (New-InputAction -Type 'Redraw')
            }
            'Backspace' {
                if ($script:CommandBuffer.Length -gt 0) {
                    [void]$script:CommandBuffer.Remove($script:CommandBuffer.Length - 1, 1)
                } else {
                    Reset-CommandMode
                }
                return (New-InputAction -Type 'Redraw')
            }
            'Enter' {
                $Cmd = $script:CommandBuffer.ToString()
                Reset-CommandMode
                return (New-InputAction -Type 'Command' -Value $Cmd)
            }
            default {
                if ([char]::IsLetterOrDigit($KeyChar) -or $KeyChar -eq ' ') {
                    [void]$script:CommandBuffer.Append($KeyChar)

                    # Single-letter commands execute immediately (not h — has sub-commands)
                    $CmdText = $script:CommandBuffer.ToString().Trim()
                    if ($CmdText.Length -eq 1 -and $CmdText -match '^[sSrRbBqQ]$') {
                        Reset-CommandMode
                        return (New-InputAction -Type 'Command' -Value $CmdText)
                    }

                    return (New-InputAction -Type 'Redraw')
                }
            }
        }
        return (New-InputAction -Type 'None')
    }

    # ── Filter active ──
    if ($script:FilterActive) {
        switch ($KeyEnum) {
            'Escape' {
                Reset-Filter
                return (New-InputAction -Type 'FilterClear')
            }
            'Backspace' {
                if ($script:FilterBuffer.Length -gt 0) {
                    [void]$script:FilterBuffer.Remove($script:FilterBuffer.Length - 1, 1)
                    if ($script:FilterBuffer.Length -eq 0) {
                        $script:FilterActive = $false
                        return (New-InputAction -Type 'FilterClear')
                    }
                    return (New-InputAction -Type 'FilterUpdate' -Value (Get-FilterText))
                }
                return (New-InputAction -Type 'None')
            }
            'UpArrow' {
                return (New-InputAction -Type 'Navigate' -Value 'Up')
            }
            'DownArrow' {
                return (New-InputAction -Type 'Navigate' -Value 'Down')
            }
            'Enter' {
                return (New-InputAction -Type 'Select')
            }
            'Tab' {
                return (New-InputAction -Type 'Select')
            }
            default {
                if (-not [char]::IsControl($KeyChar) -and $KeyChar -ne [char]0) {
                    [void]$script:FilterBuffer.Append($KeyChar)
                    return (New-InputAction -Type 'FilterUpdate' -Value (Get-FilterText))
                }
            }
        }
        return (New-InputAction -Type 'None')
    }

    # ── Text input mode (wizard text steps) ──
    if ($Component -and $Component.TextInputMode) {
        switch ($KeyEnum) {
            'Escape' {
                return (New-InputAction -Type 'Back')
            }
            'Enter' {
                return (New-InputAction -Type 'Select')
            }
            'Tab' {
                return (New-InputAction -Type 'Select')
            }
            'UpArrow' {
                return (New-InputAction -Type 'Navigate' -Value 'Up')
            }
            'DownArrow' {
                return (New-InputAction -Type 'Navigate' -Value 'Down')
            }
            'Backspace' {
                return (New-InputAction -Type 'TextBackspace')
            }
            default {
                if (-not [char]::IsControl($KeyChar) -and $KeyChar -ne [char]0) {
                    return (New-InputAction -Type 'TextInput' -Value ([string]$KeyChar))
                }
            }
        }
        return (New-InputAction -Type 'None')
    }

    # ── No filter, no command mode ──
    switch ($KeyEnum) {
        'UpArrow' {
            return (New-InputAction -Type 'Navigate' -Value 'Up')
        }
        'DownArrow' {
            return (New-InputAction -Type 'Navigate' -Value 'Down')
        }
        'LeftArrow' {
            return (New-InputAction -Type 'Navigate' -Value 'Left')
        }
        'RightArrow' {
            return (New-InputAction -Type 'Navigate' -Value 'Right')
        }
        'Enter' {
            return (New-InputAction -Type 'Select')
        }
        'Tab' {
            return (New-InputAction -Type 'Select')
        }
        'Escape' {
            return (New-InputAction -Type 'Back')
        }
        'Backspace' {
            return (New-InputAction -Type 'None')
        }
        default {
            # / enters command mode (only when filter is empty)
            if ($KeyChar -eq '/') {
                $script:CommandMode = $true
                [void]$script:CommandBuffer.Clear()
                return (New-InputAction -Type 'CommandStart')
            }

            # q/Q = back (same as Escape)
            if ($KeyChar -eq 'q' -or $KeyChar -eq 'Q') {
                return (New-InputAction -Type 'Back')
            }

            # Any other printable character starts filtering (if component supports it)
            if (-not [char]::IsControl($KeyChar) -and $KeyChar -ne [char]0) {
                $Filterable = $false
                if ($Component -and $Component.Filterable) {
                    $Filterable = $true
                }

                if ($Filterable) {
                    $script:FilterActive = $true
                    [void]$script:FilterBuffer.Clear()
                    [void]$script:FilterBuffer.Append($KeyChar)

                    if (-not $script:FilterHintShown) {
                        $script:FilterHintShown = $true
                        $script:FilterHintPending = $true
                    }

                    return (New-InputAction -Type 'FilterStart' -Value (Get-FilterText))
                }
            }
        }
    }

    return (New-InputAction -Type 'None')
}

# ── Invoke-SlashCommand ──────────────────────────────────────────────────────

function Invoke-SlashCommand {
    param(
        [Parameter(Mandatory)] [string]$Command,
        [object]$State
    )

    $Cmd = $Command.Trim().ToLowerInvariant()

    # Help commands
    if ($Cmd -eq 'h') {
        return (New-InputAction -Type 'Help')
    }
    if ($Cmd.StartsWith('h ')) {
        $SearchQuery = $Cmd.Substring(2).Trim()
        if ($SearchQuery.Length -eq 0) {
            return (New-InputAction -Type 'Help')
        }
        return (New-InputAction -Type 'HelpSearch' -Value $SearchQuery)
    }
    if ($Cmd -eq 'hh') {
        return (New-InputAction -Type 'HelpExtended')
    }

    # Status dashboard
    if ($Cmd -eq 's') {
        return (New-InputAction -Type 'HealthDashboard')
    }

    # Refresh data
    if ($Cmd -eq 'r') {
        return (New-InputAction -Type 'Refresh')
    }

    # Back
    if ($Cmd -eq 'b') {
        return (New-InputAction -Type 'Back')
    }

    # Quit
    if ($Cmd -eq 'q') {
        return (New-InputAction -Type 'Quit')
    }

    # Unknown command
    return (New-InputAction -Type 'None')
}

# ── Fuzzy Debounce ──────────────────────────────────────────────────────────

# Waits up to FuzzyDebounceMs for keystroke silence, then triggers stage 3
function Invoke-FuzzyDebounce {
    param(
        [object]$Component,
        [object]$State,
        [scriptblock]$RenderCallback
    )

    if (-not $Component.FuzzyCallback) { return }
    if (-not $script:FilterActive) { return }

    $Elapsed = 0
    while ($Elapsed -lt $script:FuzzyDebounceMs) {
        if ([System.Console]::KeyAvailable) { return }
        [System.Threading.Thread]::Sleep(50)
        $Elapsed += 50
    }

    # No keys for 300ms — run stage 3 fuzzy search
    $FilterText = Get-FilterText
    Invoke-MenuFuzzyExtend -Component $Component -FilterText $FilterText
    if ($RenderCallback) { & $RenderCallback $State $Component }
    Render-BufferDiff
}

# ── Start-InputLoop ──────────────────────────────────────────────────────────

function Start-InputLoop {
    param(
        [Parameter(Mandatory)] [object]$State,
        [Parameter(Mandatory)] [object]$Component,
        [scriptblock]$RenderCallback,
        [scriptblock]$CommandHandler
    )

    Reset-Filter
    Reset-CommandMode

    while ($true) {
        # Check resize
        if (Test-TerminalResized) {
            $Resized = Resize-Screen -State $State
            if ($Resized) {
                Initialize-Buffers
                if ($RenderCallback) { & $RenderCallback $State $Component }
                Render-FullBuffer
            }
        }

        # Read key
        $Key = [System.Console]::ReadKey($true)
        $Now = [datetime]::Now

        # Paste detection: ignore Enter during rapid keystrokes
        $IsPaste = Test-PasteSequence -Now $Now
        $script:LastKeyTimestamp = $Now

        if ($IsPaste -and $Key.Key -eq 'Enter') {
            continue
        }

        # Route key
        $Action = Route-KeyPress -Key $Key -Component $Component -State $State

        switch ($Action.Type) {
            'Navigate' {
                if ($Component.HandleKey) {
                    $Result = & $Component.HandleKey $Action $State $Component
                    if ($Result -and $Result.Type -eq 'Return') {
                        return $Result.Value
                    }
                }
                if ($RenderCallback) { & $RenderCallback $State $Component }
                Render-BufferDiff
            }

            'Select' {
                if ($Component.HandleKey) {
                    $Result = & $Component.HandleKey $Action $State $Component
                    if ($Result -and $Result.Type -eq 'Return') {
                        return $Result.Value
                    }
                }
            }

            'FilterStart' {
                if ($Component.HandleKey) {
                    & $Component.HandleKey $Action $State $Component | Out-Null
                }
                if ($RenderCallback) { & $RenderCallback $State $Component }
                Render-BufferDiff

                # Stage 3 fuzzy debounce
                Invoke-FuzzyDebounce -Component $Component -State $State -RenderCallback $RenderCallback
            }

            'FilterUpdate' {
                if ($Component.HandleKey) {
                    & $Component.HandleKey $Action $State $Component | Out-Null
                }
                if ($RenderCallback) { & $RenderCallback $State $Component }
                Render-BufferDiff

                # Stage 3 fuzzy debounce
                Invoke-FuzzyDebounce -Component $Component -State $State -RenderCallback $RenderCallback
            }

            'FilterClear' {
                if ($Component.HandleKey) {
                    & $Component.HandleKey $Action $State $Component | Out-Null
                }
                if ($RenderCallback) { & $RenderCallback $State $Component }
                Render-BufferDiff
            }

            'Command' {
                $CmdAction = Invoke-SlashCommand -Command $Action.Value -State $State
                if ($CmdAction.Type -eq 'Back') { return '__back__' }
                if ($CmdAction.Type -eq 'Quit') { return '__quit__' }

                # Route command to handler or component
                try {
                    if ($CommandHandler) {
                        $CmdResult = & $CommandHandler $CmdAction $State $Component $RenderCallback
                        if ($CmdResult -eq '__quit__') { return '__quit__' }
                    } elseif ($Component.HandleKey) {
                        & $Component.HandleKey $CmdAction $State $Component | Out-Null
                    }
                }
                catch {
                    Reset-CommandMode
                    # Silent log — stderr output corrupts the TUI screen buffer
                    if (Get-Command 'Add-OperationWarning' -ErrorAction SilentlyContinue) {
                        Add-OperationWarning -Message "Blad polecenia: $_" -Severity 'Warn'
                    }
                }

                if ($RenderCallback) { & $RenderCallback $State $Component }
                Render-BufferDiff
            }

            'TextInput' {
                if ($Component.HandleKey) {
                    & $Component.HandleKey $Action $State $Component | Out-Null
                }
                if ($RenderCallback) { & $RenderCallback $State $Component }
                Render-BufferDiff
            }

            'TextBackspace' {
                if ($Component.HandleKey) {
                    & $Component.HandleKey $Action $State $Component | Out-Null
                }
                if ($RenderCallback) { & $RenderCallback $State $Component }
                Render-BufferDiff
            }

            'CommandStart' {
                if ($RenderCallback) { & $RenderCallback $State $Component }
                Render-BufferDiff
            }

            'Back' {
                return '__back__'
            }

            'Redraw' {
                if ($RenderCallback) { & $RenderCallback $State $Component }
                Render-BufferDiff
            }

            'None' {
                # No-op
            }
        }
    }
}
