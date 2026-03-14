<#
    .SYNOPSIS
    Help overlay, health dashboard, and help search for the Robot CLI TUI engine.

    .DESCRIPTION
    Overlay components that render on top of the content region: bordered
    help overlay with scrolling and progressive content, health dashboard
    with system status sections, and help topic search across registry.

    Helpers:
    - New-HelpOverlayComponent:     bordered help overlay with scroll, LiveContext support
    - New-HealthDashboardComponent: full system health status view
    - Render-HealthSection:         renders a single health check section row
    - Search-HelpTopics:            searches across registry help content for matching topics
    - Get-AutoStepHelp:             generates help text from function parameter metadata

    Component contract (HelpOverlay):
    - Render:    draws bordered box in Content region with scrollable text
    - HandleKey: Navigate (Up/Down scroll), dismissed by Escape from caller
    - Filterable: false

    Component contract (HealthDashboard):
    - Render:    lists PU/Currency/Integrity/Graph status with icons
    - HandleKey: Navigate (Up/Down scroll), dismissed by Escape from caller
    - Filterable: false

    Dependencies:
    - cli-engine.ps1:  Get-Region, Get-RegionHeight, Get-CLIColor, $script:ScreenWidth
    - cli-buffer.ps1:  New-Segment, Set-BufferLine, Clear-BufferRegion, $script:BackBuffer
#>

# ── HelpOverlayComponent ────────────────────────────────────────────────────

function New-HelpOverlayComponent {
    param(
        [string]$Title = 'Pomoc',
        [Parameter(Mandatory)] [AllowEmptyString()] [string[]]$Content,
        [scriptblock]$LiveContext
    )

    # Inject live context if available
    $DisplayContent = [System.Collections.Generic.List[string]]::new($Content)

    if ($LiveContext) {
        try {
            # LiveContext runs synchronously — callers should keep scriptblocks fast
            $ContextLines = & $LiveContext
            if ($ContextLines) {
                [void]$DisplayContent.Add('')
                [void]$DisplayContent.Add([string][char]0x2500 * 30)
                foreach ($CLine in $ContextLines) {
                    [void]$DisplayContent.Add($CLine)
                }
            }
        }
        catch {
            [void]$DisplayContent.Add('')
            [void]$DisplayContent.Add('(nie mozna zaladowac aktualnego stanu)')
        }
    }

    $Component = @{
        Type         = 'HelpOverlay'
        Title        = $Title
        Content      = @($DisplayContent)
        ScrollOffset = 0
        Filterable   = $false
        StatusHints  = "$([char]0x2191)$([char]0x2193) przewijanie  Esc zamknij"

        Render = {
            param($State, $ComponentRef)

            $Region = Get-Region -Name 'Content'
            if ($null -eq $Region) { return }

            Clear-BufferRegion -Buffer $script:BackBuffer -Region $Region

            $AccentColor   = Get-CLIColor -Role 'Accent'
            $DisabledColor = Get-CLIColor -Role 'Disabled'
            $InfoColor     = Get-CLIColor -Role 'Info'

            $ContentHeight = Get-RegionHeight -Name 'Content'
            $Content = $ComponentRef.Content
            $Offset = $ComponentRef.ScrollOffset

            # Box-drawing
            $BorderH = [char]0x2500
            $BorderV = [char]0x2502
            $BorderTL = [char]0x250C
            $BorderTR = [char]0x2510
            $BorderBL = [char]0x2514
            $BorderBR = [char]0x2518

            $BoxLeft = 3
            $BoxInnerWidth = [Math]::Min(($script:ScreenWidth - 10), 70)
            $BoxInnerWidth = [Math]::Max($BoxInnerWidth, 20)
            $BoxWidth = $BoxInnerWidth + 4

            $VisibleLines = $ContentHeight - 4  # top border + bottom border + footer + margin
            $VisibleLines = [Math]::Max($VisibleLines, 1)

            $MaxOffset = [Math]::Max(0, $Content.Count - $VisibleLines)
            if ($Offset -gt $MaxOffset) { $ComponentRef.ScrollOffset = $MaxOffset; $Offset = $MaxOffset }

            $Row = $Region.StartRow

            # Top border
            $TitleStr = if ($ComponentRef.Title) { " $($ComponentRef.Title) " } else { '' }
            $FillLen = $BoxWidth - 2 - $TitleStr.Length
            $LeftFill = [Math]::Max(0, [Math]::Floor($FillLen / 2))
            $RightFill = [Math]::Max(0, $FillLen - $LeftFill)
            $TopLine = "$(' ' * $BoxLeft)$BorderTL$([string]$BorderH * $LeftFill)$TitleStr$([string]$BorderH * $RightFill)$BorderTR"
            Set-BufferLine -Buffer $script:BackBuffer -Row $Row -Segments @(
                (New-Segment -Text $TopLine -Color $AccentColor)
            )
            $Row++

            # Content lines
            for ($I = 0; $I -lt $VisibleLines; $I++) {
                if (($Row - $Region.StartRow) -ge ($ContentHeight - 2)) { break }

                $ContentIdx = $Offset + $I
                $LineText = if ($ContentIdx -lt $Content.Count) { $Content[$ContentIdx] } else { '' }
                if ($LineText.Length -gt $BoxInnerWidth) {
                    $LineText = $LineText.Substring(0, $BoxInnerWidth - 3) + '...'
                }
                $PaddedLine = $LineText.PadRight($BoxInnerWidth)

                $Segs = @(
                    (New-Segment -Text "$(' ' * $BoxLeft)$BorderV " -Color $DisabledColor -Dim)
                    (New-Segment -Text $PaddedLine -Color $InfoColor)
                    (New-Segment -Text " $BorderV" -Color $DisabledColor -Dim)
                )
                Set-BufferLine -Buffer $script:BackBuffer -Row $Row -Segments $Segs
                $Row++
            }

            # Footer with scroll indicators
            $NeedsScroll = $Content.Count -gt $VisibleLines
            $ScrollHint = ''
            if ($NeedsScroll) {
                $UpArrow = if ($Offset -gt 0) { [string][char]0x2191 } else { ' ' }
                $DownArrow = if ($Offset -lt $MaxOffset) { [string][char]0x2193 } else { ' ' }
                $ScrollHint = "$UpArrow$DownArrow  "
            }
            $DismissHint = 'Esc = zamknij'
            $FooterContent = "$ScrollHint$DismissHint".PadRight($BoxInnerWidth)

            Set-BufferLine -Buffer $script:BackBuffer -Row $Row -Segments @(
                (New-Segment -Text "$(' ' * $BoxLeft)$BorderV " -Color $DisabledColor -Dim)
                (New-Segment -Text $FooterContent -Color $DisabledColor)
                (New-Segment -Text " $BorderV" -Color $DisabledColor -Dim)
            )
            $Row++

            # Bottom border
            $BottomLine = "$(' ' * $BoxLeft)$BorderBL$([string]$BorderH * ($BoxWidth - 2))$BorderBR"
            Set-BufferLine -Buffer $script:BackBuffer -Row $Row -Segments @(
                (New-Segment -Text $BottomLine -Color $DisabledColor -Dim)
            )
        }

        HandleKey = {
            param($Action, $State, $ComponentRef)

            switch ($Action.Type) {
                'Navigate' {
                    if ($Action.Value -eq 'Up') {
                        if ($ComponentRef.ScrollOffset -gt 0) { $ComponentRef.ScrollOffset-- }
                    }
                    elseif ($Action.Value -eq 'Down') {
                        $ComponentRef.ScrollOffset++
                    }
                }
            }

            return $null
        }
    }

    return $Component
}

# ── HealthDashboardComponent ─────────────────────────────────────────────────

function New-HealthDashboardComponent {
    param([Parameter(Mandatory)] [object]$State)

    $Component = @{
        Type         = 'HealthDashboard'
        State        = $State
        ScrollOffset = 0
        Filterable   = $false
        StatusHints  = "$([char]0x2191)$([char]0x2193) przewijanie  Esc wstecz"

        Render = {
            param($State, $ComponentRef)

            $Region = Get-Region -Name 'Content'
            if ($null -eq $Region) { return }

            Clear-BufferRegion -Buffer $script:BackBuffer -Region $Region

            $AccentColor   = Get-CLIColor -Role 'Accent'
            $SuccessColor  = Get-CLIColor -Role 'Success'
            $WarningColor  = Get-CLIColor -Role 'Warning'
            $ErrorColor    = Get-CLIColor -Role 'Error'
            $DisabledColor = Get-CLIColor -Role 'Disabled'

            $HC = $State.HealthCache
            $Row = $Region.StartRow

            Set-BufferLine -Buffer $script:BackBuffer -Row $Row -Segments @(
                (New-Segment -Text '  Stan systemu' -Color $AccentColor -Bold)
            )
            $Row += 2

            # Show skip notice when health checks were bypassed via -NoHealthCheck
            if ($HC.Skipped) {
                Set-BufferLine -Buffer $script:BackBuffer -Row $Row -Segments @(
                    (New-Segment -Text '    Sprawdzanie pominiete (-NoHealthCheck)' -Color $DisabledColor)
                )
                $Row++
                Set-BufferLine -Buffer $script:BackBuffer -Row $Row -Segments @(
                    (New-Segment -Text '    Nacisnij Enter aby uruchomic sprawdzanie' -Color $DisabledColor)
                )
                return
            }

            # Check timestamp
            if ($HC.CheckedAt) {
                $CheckAge = ([datetime]::Now - $HC.CheckedAt).TotalMinutes
                $AgeStr = if ($CheckAge -lt 1) { 'przed chwila' }
                          elseif ($CheckAge -lt 60) { "$([int]$CheckAge) min temu" }
                          else { "$([int]($CheckAge / 60)) godz. temu" }
                Set-BufferLine -Buffer $script:BackBuffer -Row $Row -Segments @(
                    (New-Segment -Text "    Ostatnie sprawdzenie: $AgeStr" -Color $DisabledColor)
                )
                $Row += 2
            }

            # PU section
            $Row = Render-HealthSection -Row $Row -Label 'PU' -Data $HC.PU `
                -CheckFn { param($D) $C = 0; foreach ($Item in $D) { if ($Item.Status -ne 'OK') { $C++ } }; return $C }
            $Row++

            # Currency section
            $Row = Render-HealthSection -Row $Row -Label 'Waluta' -Data $HC.Currency `
                -CheckFn { param($D) if ($D.WarningCount) { $D.WarningCount } else { 0 } }
            $Row++

            # Integrity section
            $Row = Render-HealthSection -Row $Row -Label 'Integralnosc sesji' -Data $HC.Integrity `
                -CheckFn { param($D) $C = 0; foreach ($Item in $D) { if (-not $Item.IsValid) { $C++ } }; return $C }
            $Row++

            # Graph section
            $Row = Render-HealthSection -Row $Row -Label 'Graf sesji' -Data $HC.Graph `
                -CheckFn { param($D) if ($D.WarningCount) { $D.WarningCount } else { 0 } }

            # Errors
            if ($HC.Errors -and $HC.Errors.Count -gt 0) {
                $Row += 2
                Set-BufferLine -Buffer $script:BackBuffer -Row $Row -Segments @(
                    (New-Segment -Text "    $([char]0x26A0) Bledy podczas sprawdzania:" -Color $WarningColor)
                )
                $Row++
                foreach ($Err in $HC.Errors) {
                    Set-BufferLine -Buffer $script:BackBuffer -Row $Row -Segments @(
                        (New-Segment -Text "      $([char]0x2022) $Err" -Color $ErrorColor)
                    )
                    $Row++
                }
            }
        }

        HandleKey = {
            param($Action, $State, $ComponentRef)

            switch ($Action.Type) {
                'Navigate' {
                    if ($Action.Value -eq 'Up' -and $ComponentRef.ScrollOffset -gt 0) {
                        $ComponentRef.ScrollOffset--
                    }
                    elseif ($Action.Value -eq 'Down') {
                        $ComponentRef.ScrollOffset++
                    }
                }
                'Select' {
                    # Enter triggers health checks when they were skipped
                    if ($State.HealthCache.Skipped -or -not $State.HealthCache.CheckedAt) {
                        Refresh-HealthChecks -State $State
                    }
                }
            }

            return $null
        }
    }

    return $Component
}

# ── Health Section Renderer ──────────────────────────────────────────────────

function Render-HealthSection {
    param(
        [int]$Row,
        [string]$Label,
        $Data,
        [scriptblock]$CheckFn
    )

    $SuccessColor  = Get-CLIColor -Role 'Success'
    $WarningColor  = Get-CLIColor -Role 'Warning'
    $DisabledColor = Get-CLIColor -Role 'Disabled'

    if ($null -eq $Data) {
        Set-BufferLine -Buffer $script:BackBuffer -Row $Row -Segments @(
            (New-Segment -Text "    $Label`: " -Color $DisabledColor)
            (New-Segment -Text '(brak danych)' -Color $DisabledColor)
        )
        return ($Row + 1)
    }

    $WarnCount = & $CheckFn $Data
    $StatusIcon = if ($WarnCount -eq 0) { [char]0x2713 } else { [char]0x26A0 }
    $StatusColor = if ($WarnCount -eq 0) { $SuccessColor } else { $WarningColor }
    $StatusText = if ($WarnCount -eq 0) { 'OK' } else { "$WarnCount ostrzezen" }

    Set-BufferLine -Buffer $script:BackBuffer -Row $Row -Segments @(
        (New-Segment -Text "    $Label`: " -Color $DisabledColor)
        (New-Segment -Text "$StatusIcon $StatusText" -Color $StatusColor)
    )

    return ($Row + 1)
}

# ── Help Topic Search ───────────────────────────────────────────────────────

# Searches across registry help content for matching topics
# Returns an array of matching help entries with context lines
function Search-HelpTopics {
    param(
        [Parameter(Mandatory)] [string]$Query,
        [Parameter(Mandatory)] [object[]]$Registry
    )

    $Results = [System.Collections.Generic.List[object]]::new()
    $QueryLower = $Query.ToLowerInvariant()

    foreach ($Entry in $Registry) {
        $Overrides = $Entry.Overrides
        if (-not $Overrides) { continue }

        $Label = if ($Entry.Label) { $Entry.Label } else { $Entry.ID }
        $Matched = $false
        $ContextLines = [System.Collections.Generic.List[string]]::new()

        # Search in entry-level HelpFull
        if ($Overrides.HelpFull) {
            foreach ($Line in $Overrides.HelpFull) {
                if ($Line -and $Line.IndexOf($QueryLower, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
                    $Matched = $true
                    [void]$ContextLines.Add($Line)
                }
            }
        }

        # Search in step-level help
        foreach ($Key in $Overrides.Keys) {
            $Step = $Overrides[$Key]
            if ($Step -is [hashtable]) {
                if ($Step.HelpBrief -and $Step.HelpBrief.IndexOf($QueryLower, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
                    $Matched = $true
                    [void]$ContextLines.Add("$Key`: $($Step.HelpBrief)")
                }
                if ($Step.HelpFull) {
                    foreach ($Line in $Step.HelpFull) {
                        if ($Line -and $Line.IndexOf($QueryLower, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
                            $Matched = $true
                            [void]$ContextLines.Add("$Key`: $Line")
                        }
                    }
                }
            }
        }

        if ($Matched) {
            [void]$Results.Add(@{
                Label   = $Label
                ID      = $Entry.ID
                Context = @($ContextLines)
            })
        }
    }

    return ,$Results.ToArray()
}

# ── Auto-Generated Step Help ────────────────────────────────────────────────

# Generates help text from function parameter metadata when no explicit
# HelpBrief/HelpFull is provided in registry Overrides
function Get-AutoStepHelp {
    param(
        [Parameter(Mandatory)] [string]$FunctionName,
        [Parameter(Mandatory)] [string]$ParameterName
    )

    $Lines = [System.Collections.Generic.List[string]]::new()

    try {
        $CmdInfo = Get-Command $FunctionName -ErrorAction SilentlyContinue
        if (-not $CmdInfo) { return @() }

        $ParamInfo = $CmdInfo.Parameters[$ParameterName]
        if (-not $ParamInfo) { return @() }

        # Parameter type
        $TypeName = $ParamInfo.ParameterType.Name
        switch ($TypeName) {
            'Int32'    { [void]$Lines.Add('Liczba calkowita') }
            'Int64'    { [void]$Lines.Add('Liczba calkowita') }
            'Decimal'  { [void]$Lines.Add('Liczba dziesietna') }
            'DateTime' { [void]$Lines.Add('Data w formacie RRRR-MM-DD') }
            'String'   { }  # no special hint for strings
            'SwitchParameter' { [void]$Lines.Add('Tak/Nie') }
            default    { [void]$Lines.Add("Typ: $TypeName") }
        }

        # Mandatory check
        foreach ($Attr in $ParamInfo.Attributes) {
            if ($Attr -is [System.Management.Automation.ParameterAttribute]) {
                if ($Attr.Mandatory) {
                    [void]$Lines.Add('Pole wymagane')
                }
                if ($Attr.HelpMessage) {
                    [void]$Lines.Add($Attr.HelpMessage)
                }
            }

            # ValidateSet
            if ($Attr -is [System.Management.Automation.ValidateSetAttribute]) {
                $Vals = $Attr.ValidValues -join ', '
                [void]$Lines.Add("Dozwolone wartosci: $Vals")
            }
        }

        # Default value (from DefaultParameterValues if available)
        if ($ParamInfo.PSObject.Properties['DefaultValue'] -and $null -ne $ParamInfo.DefaultValue) {
            [void]$Lines.Add("Domyslnie: $($ParamInfo.DefaultValue)")
        }
    }
    catch {
        # Silently ignore — auto-help is best-effort
    }

    return ,$Lines.ToArray()
}
