<#
    .SYNOPSIS
    Entity-domain CLI workflows - creation, editing, history, search, and card view.

    .DESCRIPTION
    This file contains workflow functions for entity management, consumed by
    the CLI menu registry (Mode = 'Workflow'). Dot-sourced on demand.

    Workflows:
    - Invoke-NewEntityWorkflow:      guided tag entry for new entities
    - Invoke-EditEntityWorkflow:     diff review with context for entity edits
    - Invoke-EntityHistoryWorkflow:  fuzzy-pick then history timeline
    - Invoke-EntitySearchWorkflow:   fuzzy search then detail card

    Helpers:
    - Format-ValidityRange:          formats temporal range as "YYYY-MM-DD – YYYY-MM-DD"
    - Show-EntityCard:               renders entity detail card with tags and history

    Dependencies: cli-primitives.ps1, cli-fuzzy.ps1, cli-wizard.ps1
#>

# ── New Entity Workflow (Guided Tag Entry) ───────────────────────────────────

function Invoke-NewEntityWorkflow {
    param([object]$State, [hashtable]$Entry)

    $AccentColor   = Get-CLIColor -Role 'Accent'
    $DisabledColor = Get-CLIColor -Role 'Disabled'
    $InfoColor     = Get-CLIColor -Role 'Info'
    $Sep = [string][char]0x2500 * 50

    # Step 1: Entity type
    [System.Console]::Clear()
    Write-CLILine -Text 'Kreator nowej encji' -Color $AccentColor
    Write-Host "  $Sep" -ForegroundColor $DisabledColor
    Write-Host ''
    Write-CLILine -Text 'Typ encji:' -Color $AccentColor

    $TypeItems = @(
        [PSCustomObject]@{ ID = 'NPC';       Label = 'NPC';       Description = 'Postać niezależna'; RoleTag = $null; InfoText = $null; Disabled = $false }
        [PSCustomObject]@{ ID = 'Grupa';     Label = 'Grupa';     Description = 'Frakcja lub organizacja'; RoleTag = $null; InfoText = $null; Disabled = $false }
        [PSCustomObject]@{ ID = 'Lokacja';   Label = 'Lokacja';   Description = 'Miejsce w świecie gry'; RoleTag = $null; InfoText = $null; Disabled = $false }
        [PSCustomObject]@{ ID = 'Przedmiot'; Label = 'Przedmiot'; Description = 'Przedmiot lub artefakt'; RoleTag = $null; InfoText = $null; Disabled = $false }
    )

    $Type = Show-ArrowMenu -Items $TypeItems -ShowBack
    if ($Type -eq '__back__' -or $Type -eq '__quit__') { return }

    # Step 2: Name
    [System.Console]::Clear()
    Write-CLILine -Text 'Kreator nowej encji' -Color $AccentColor
    Write-Host "  $Sep" -ForegroundColor $DisabledColor
    Write-Host "  $('Typ'.PadRight(22))" -NoNewline -ForegroundColor $InfoColor
    Write-Host $Type
    Write-Host ''

    $NameStep = [PSCustomObject]@{
        Name = 'Name'; Label = 'Nazwa encji'; StepType = 'text'; Required = $true
        Source = $null; Options = $null; SubSteps = $null; EntrySource = $null
        Condition = $null; Transform = $null; Default = $null
    }
    $Name = Invoke-WizardStep -Step $NameStep -State $State
    if ($Name -eq '__back__' -or $Name -eq '__quit__' -or -not $Name) { return }

    # Step 3: Guided tag entry loop
    $Tags = @{}
    $CommonTags = @('lokacja', 'grupa', 'status', 'alias', 'typ', 'info')

    while ($true) {
        # Redraw screen with current context
        [System.Console]::Clear()
        Write-CLILine -Text 'Kreator nowej encji' -Color $AccentColor
        Write-Host "  $Sep" -ForegroundColor $DisabledColor
        Write-Host "  $('Typ'.PadRight(22))" -NoNewline -ForegroundColor $InfoColor
        Write-Host $Type
        Write-Host "  $('Nazwa'.PadRight(22))" -NoNewline -ForegroundColor $InfoColor
        Write-Host $Name
        if ($Tags.Count -gt 0) {
            Write-Host ''
            Write-CLILine -Text 'Dodane tagi:' -Color $InfoColor
            foreach ($Key in $Tags.Keys) {
                Write-Host "    $("@$Key".PadRight(20))" -NoNewline -ForegroundColor $DisabledColor
                Write-Host $Tags[$Key]
            }
        }
        Write-Host ''

        Write-CLILine -Text 'Dodaj tag:' -Color $AccentColor

        $TagOptions = [System.Collections.Generic.List[PSCustomObject]]::new()
        foreach ($T in $CommonTags) {
            [void]$TagOptions.Add([PSCustomObject]@{
                ID = $T; Label = "@$T"; Description = ''; RoleTag = $null; InfoText = $null; Disabled = $false
            })
        }
        [void]$TagOptions.Add([PSCustomObject]@{
            ID = '__custom__'; Label = 'Inny tag (wpisz)'; Description = ''; RoleTag = $null; InfoText = $null; Disabled = $false
        })
        [void]$TagOptions.Add([PSCustomObject]@{
            ID = '__done__'; Label = 'Zakończ dodawanie tagów'; Description = ''; RoleTag = $null; InfoText = $null; Disabled = $false
        })

        $TagChoice = Show-ArrowMenu -Items $TagOptions -ShowBack
        if ($TagChoice -eq '__back__' -or $TagChoice -eq '__quit__' -or $TagChoice -eq '__done__') { break }

        $TagName = $TagChoice
        if ($TagChoice -eq '__custom__') {
            $CustomTagStep = [PSCustomObject]@{
                Name = 'Tag'; Label = 'Nazwa tagu'; StepType = 'text'; Required = $true
                Source = $null; Options = $null; SubSteps = $null; EntrySource = $null
                Condition = $null; Transform = $null; Default = $null
            }
            $TagName = Invoke-WizardStep -Step $CustomTagStep -State $State
            if (-not $TagName -or $TagName -eq '__back__') { continue }
        }

        # Tag value - use fuzzy for lokacja/grupa, text for others
        $ValueStep = if ($TagName -ieq 'lokacja') {
            [PSCustomObject]@{
                Name = 'Value'; Label = "Wartość @$TagName"; StepType = 'fuzzy'; Required = $true
                Source = 'locations'; Options = $null; SubSteps = $null; EntrySource = $null
                Condition = $null; Transform = $null; Default = $null
            }
        } elseif ($TagName -ieq 'grupa') {
            [PSCustomObject]@{
                Name = 'Value'; Label = "Wartość @$TagName"; StepType = 'fuzzy'; Required = $true
                Source = 'groups'; Options = $null; SubSteps = $null; EntrySource = $null
                Condition = $null; Transform = $null; Default = $null
            }
        } else {
            [PSCustomObject]@{
                Name = 'Value'; Label = "Wartość @$TagName"; StepType = 'text'; Required = $true
                Source = $null; Options = $null; SubSteps = $null; EntrySource = $null
                Condition = $null; Transform = $null; Default = $null
            }
        }

        # Redraw before value input - prevents screen overflow when fuzzy search follows arrow menu
        [System.Console]::Clear()
        Write-CLILine -Text 'Kreator nowej encji' -Color $AccentColor
        Write-Host "  $Sep" -ForegroundColor $DisabledColor
        Write-Host "  $('Typ'.PadRight(22))" -NoNewline -ForegroundColor $InfoColor
        Write-Host $Type
        Write-Host "  $('Nazwa'.PadRight(22))" -NoNewline -ForegroundColor $InfoColor
        Write-Host $Name
        Write-Host "  $('Tag'.PadRight(22))" -NoNewline -ForegroundColor $InfoColor
        Write-Host "@$TagName"
        if ($Tags.Count -gt 0) {
            Write-Host ''
            Write-CLILine -Text 'Dodane tagi:' -Color $InfoColor
            foreach ($Key in $Tags.Keys) {
                Write-Host "    $("@$Key".PadRight(20))" -NoNewline -ForegroundColor $DisabledColor
                Write-Host $Tags[$Key]
            }
        }
        Write-Host ''

        $TagValue = Invoke-WizardStep -Step $ValueStep -State $State
        if (-not $TagValue -or $TagValue -eq '__back__') { continue }

        $Tags[$TagName] = $TagValue
    }

    # Build params and preview
    $Params = [ordered]@{
        'Type' = $Type
        'Name' = $Name
    }
    if ($Tags.Count -gt 0) { $Params['Tags'] = $Tags }

    [void](Show-Preview -FunctionName 'New-Entity' -Parameters $Params -State $State)
}

# ── Edit Entity Workflow (Diff Review with Context) ──────────────────────────

function Invoke-EditEntityWorkflow {
    param([object]$State, [hashtable]$Entry)

    $AccentColor   = Get-CLIColor -Role 'Accent'
    $DisabledColor = Get-CLIColor -Role 'Disabled'
    $InfoColor     = Get-CLIColor -Role 'Info'
    $Sep = [string][char]0x2500 * 50

    [System.Console]::Clear()
    Write-CLILine -Text 'Edycja encji' -Color $AccentColor
    Write-Host "  $Sep" -ForegroundColor $DisabledColor
    Write-Host ''

    # Pick entity
    $Entity = Show-FuzzySearch -Prompt 'Wybierz encję' -Source 'entities' -State $State
    if (-not $Entity) { return }

    $EntityObj = $Entity.Owner

    # Guided tag upsert loop
    $Tags = @{}
    $CommonTags = @('lokacja', 'grupa', 'status', 'alias', 'typ', 'info')

    while ($true) {
        # Redraw with context: entity info + existing overrides + new tags
        [System.Console]::Clear()
        Write-CLILine -Text 'Edycja encji' -Color $AccentColor
        Write-Host "  $Sep" -ForegroundColor $DisabledColor
        Write-Host "  $('Encja'.PadRight(22))" -NoNewline -ForegroundColor $InfoColor
        Write-Host "$($EntityObj.Name) [$($EntityObj.Type)]"

        if ($EntityObj.Overrides -and $EntityObj.Overrides.Count -gt 0) {
            Write-Host ''
            Write-CLILine -Text 'Obecne tagi:' -Color $DisabledColor
            foreach ($Key in $EntityObj.Overrides.Keys) {
                $OVal = $EntityObj.Overrides[$Key]
                $ODisplay = if ($OVal -is [System.Collections.IList]) { $OVal -join ', ' } else { [string]$OVal }
                Write-Host "    $("@$Key".PadRight(20))" -NoNewline -ForegroundColor $DisabledColor
                Write-Host $ODisplay -ForegroundColor $DisabledColor
            }
        }

        if ($Tags.Count -gt 0) {
            Write-Host ''
            Write-CLILine -Text 'Nowe/zmienione tagi:' -Color $InfoColor
            foreach ($Key in $Tags.Keys) {
                Write-Host "    $("@$Key".PadRight(20))" -NoNewline -ForegroundColor $AccentColor
                Write-Host $Tags[$Key]
            }
        }
        Write-Host ''

        Write-CLILine -Text 'Dodaj/zmień tag:' -Color $AccentColor

        $TagOptions = [System.Collections.Generic.List[PSCustomObject]]::new()
        foreach ($T in $CommonTags) {
            [void]$TagOptions.Add([PSCustomObject]@{
                ID = $T; Label = "@$T"; Description = ''; RoleTag = $null; InfoText = $null; Disabled = $false
            })
        }
        [void]$TagOptions.Add([PSCustomObject]@{
            ID = '__custom__'; Label = 'Inny tag (wpisz)'; Description = ''; RoleTag = $null; InfoText = $null; Disabled = $false
        })
        [void]$TagOptions.Add([PSCustomObject]@{
            ID = '__done__'; Label = 'Zakończ'; Description = ''; RoleTag = $null; InfoText = $null; Disabled = $false
        })

        $TagChoice = Show-ArrowMenu -Items $TagOptions -ShowBack
        if ($TagChoice -eq '__back__' -or $TagChoice -eq '__quit__' -or $TagChoice -eq '__done__') { break }

        $TagName = $TagChoice
        if ($TagChoice -eq '__custom__') {
            $CustomStep = [PSCustomObject]@{
                Name = 'Tag'; Label = 'Nazwa tagu'; StepType = 'text'; Required = $true
                Source = $null; Options = $null; SubSteps = $null; EntrySource = $null
                Condition = $null; Transform = $null; Default = $null
            }
            $TagName = Invoke-WizardStep -Step $CustomStep -State $State
            if (-not $TagName -or $TagName -eq '__back__') { continue }
        }

        # Tag value - use fuzzy for lokacja/grupa, text for others
        $ValueStep = if ($TagName -ieq 'lokacja') {
            [PSCustomObject]@{
                Name = 'Value'; Label = "Wartość @$TagName"; StepType = 'fuzzy'; Required = $true
                Source = 'locations'; Options = $null; SubSteps = $null; EntrySource = $null
                Condition = $null; Transform = $null; Default = $null
            }
        } elseif ($TagName -ieq 'grupa') {
            [PSCustomObject]@{
                Name = 'Value'; Label = "Wartość @$TagName"; StepType = 'fuzzy'; Required = $true
                Source = 'groups'; Options = $null; SubSteps = $null; EntrySource = $null
                Condition = $null; Transform = $null; Default = $null
            }
        } else {
            [PSCustomObject]@{
                Name = 'Value'; Label = "Wartość @$TagName"; StepType = 'text'; Required = $true
                Source = $null; Options = $null; SubSteps = $null; EntrySource = $null
                Condition = $null; Transform = $null; Default = $null
            }
        }

        # Redraw before value input - prevents screen overflow when fuzzy search follows arrow menu
        [System.Console]::Clear()
        Write-CLILine -Text 'Edycja encji' -Color $AccentColor
        Write-Host "  $Sep" -ForegroundColor $DisabledColor
        Write-Host "  $('Encja'.PadRight(22))" -NoNewline -ForegroundColor $InfoColor
        Write-Host "$($EntityObj.Name) [$($EntityObj.Type)]"
        Write-Host "  $('Tag'.PadRight(22))" -NoNewline -ForegroundColor $InfoColor
        Write-Host "@$TagName"
        if ($Tags.Count -gt 0) {
            Write-Host ''
            Write-CLILine -Text 'Nowe/zmienione tagi:' -Color $InfoColor
            foreach ($Key in $Tags.Keys) {
                Write-Host "    $("@$Key".PadRight(20))" -NoNewline -ForegroundColor $AccentColor
                Write-Host $Tags[$Key]
            }
        }
        Write-Host ''

        $TagValue = Invoke-WizardStep -Step $ValueStep -State $State
        if (-not $TagValue -or $TagValue -eq '__back__') { continue }

        $Tags[$TagName] = $TagValue
    }

    if ($Tags.Count -eq 0) {
        Write-CLILine -Text 'Brak zmian do zapisania.' -Color $DisabledColor
        Write-CLILine -Text 'Naciśnij dowolny klawisz...' -Color $DisabledColor
        [void](Read-ArrowKey)
        return
    }

    $Params = [ordered]@{
        'Name' = $Entity.Name
        'Tags' = $Tags
    }

    [void](Show-Preview -FunctionName 'Set-Entity' -Parameters $Params -State $State)
}

# ── Entity History Workflow ──────────────────────────────────────────────────

function Invoke-EntityHistoryWorkflow {
    param([object]$State, [hashtable]$Entry)

    $AccentColor = Get-CLIColor -Role 'Accent'

    Write-CLILine -Text 'Historia encji' -Color $AccentColor
    Write-Host ''

    $Entity = Show-FuzzySearch -Prompt 'Wybierz encję' -Source 'entities' -State $State
    if (-not $Entity) { return }

    try {
        $History = Get-EntityHistory -EntityName $Entity.Name
        if (-not $History -or $History.Count -eq 0) {
            Write-CLILine -Text 'Brak historii dla tej encji.' -Color (Get-CLIColor -Role 'Disabled')
            Write-CLILine -Text 'Naciśnij dowolny klawisz...' -Color (Get-CLIColor -Role 'Disabled')
            [void](Read-ArrowKey)
            return
        }

        [void](Show-ResultTable -Data $History `
            -Columns @('Date', 'Property', 'Value', 'Source') `
            -Headers @('Data', 'Właściwość', 'Wartość', 'Źródło') `
            -Widths @(12, 15, 25, 20) `
            -Title "Historia: $($Entity.Name)")
    }
    catch {
        Write-CLILine -Text "Błąd: $_" -Color (Get-CLIColor -Role 'Error')
        Write-CLILine -Text 'Naciśnij dowolny klawisz...' -Color (Get-CLIColor -Role 'Disabled')
        [void](Read-ArrowKey)
    }
}

# ── Entity Search Workflow ───────────────────────────────────────────────────

function Invoke-EntitySearchWorkflow {
    param([object]$State, [hashtable]$Entry)

    $AccentColor = Get-CLIColor -Role 'Accent'

    Write-CLILine -Text 'Wyszukiwanie encji' -Color $AccentColor
    Write-Host ''

    $Result = Show-FuzzySearch -Prompt 'Szukaj' -Source 'entities' -State $State
    if (-not $Result) { return }

    # Display entity detail card
    Show-EntityCard -Entity $Result.Owner -State $State
}

# ── Entity Display Helpers ───────────────────────────────────────────────────

function Format-ValidityRange {
    param($ValidFrom, $ValidTo)
    $From = if ($ValidFrom) { ([datetime]$ValidFrom).ToString('yyyy-MM-dd') } else { $null }
    $To   = if ($ValidTo)   { ([datetime]$ValidTo).ToString('yyyy-MM-dd') }   else { $null }
    if ($From -and $To)   { return "$From $([char]0x2013) $To" }
    elseif ($From)        { return "od $From" }
    elseif ($To)          { return "do $To" }
    return $null
}

function Show-EntityCard {
    param(
        [object]$Entity,
        [object]$State,
        [object]$Row
    )

    # Support both direct entity and detail-card Row parameter
    if (-not $Entity -and $Row) { $Entity = $Row }

    $AccentColor   = Get-CLIColor -Role 'Accent'
    $DisabledColor = Get-CLIColor -Role 'Disabled'
    $InfoColor     = Get-CLIColor -Role 'Info'
    $Sep = [string][char]0x2500 * 50

    [System.Console]::Clear()

    Write-Host "  $Sep" -ForegroundColor $AccentColor
    Write-CLILine -Text "$($Entity.Name)" -Color $AccentColor
    Write-Host ''

    # Core fields
    Write-Host "  $('Typ'.PadRight(22))" -NoNewline -ForegroundColor $InfoColor
    Write-Host "$($Entity.Type)"
    Write-Host "  $('Status'.PadRight(22))" -NoNewline -ForegroundColor $InfoColor
    Write-Host "$($Entity.Status)"

    if ($Entity.Location) {
        Write-Host "  $('Lokalizacja'.PadRight(22))" -NoNewline -ForegroundColor $InfoColor
        Write-Host "$($Entity.Location)"
    }

    if ($Entity.Owner) {
        Write-Host "  $('Właściciel'.PadRight(22))" -NoNewline -ForegroundColor $InfoColor
        Write-Host "$($Entity.Owner)"
    }

    if ($Entity.Quantity) {
        Write-Host "  $('Ilość'.PadRight(22))" -NoNewline -ForegroundColor $InfoColor
        Write-Host "$($Entity.Quantity)"
    }

    # Groups
    if ($Entity.Groups -and $Entity.Groups.Count -gt 0) {
        Write-Host "  $('Grupy'.PadRight(22))" -NoNewline -ForegroundColor $InfoColor
        Write-Host ($Entity.Groups -join ', ')
    }

    # Doors
    if ($Entity.Doors -and $Entity.Doors.Count -gt 0) {
        Write-Host "  $('Drzwi'.PadRight(22))" -NoNewline -ForegroundColor $InfoColor
        Write-Host ($Entity.Doors -join ', ')
    }

    # Contains
    if ($Entity.Contains -and $Entity.Contains.Count -gt 0) {
        Write-Host "  $('Zawiera'.PadRight(22))" -NoNewline -ForegroundColor $InfoColor
        Write-Host ($Entity.Contains -join ', ')
    }

    # Aliases - format as "Text (ValidFrom–ValidTo)" or just "Text"
    if ($Entity.Aliases -and $Entity.Aliases.Count -gt 0) {
        Write-Host ''
        Write-CLILine -Text 'Aliasy' -Color $InfoColor
        foreach ($Alias in $Entity.Aliases) {
            $AliasText = if ($Alias -is [string]) { $Alias }
                         elseif ($Alias.Text) {
                             $Range = Format-ValidityRange -ValidFrom $Alias.ValidFrom -ValidTo $Alias.ValidTo
                             if ($Range) { "$($Alias.Text) ($Range)" } else { $Alias.Text }
                         }
                         else { [string]$Alias }
            Write-CLILine -Text "  $([char]0x2022) $AliasText"
        }
    }

    # Overrides (custom @tags)
    if ($Entity.Overrides -and $Entity.Overrides.Count -gt 0) {
        Write-Host ''
        Write-CLILine -Text 'Tagi' -Color $InfoColor
        foreach ($Key in $Entity.Overrides.Keys) {
            $Values = $Entity.Overrides[$Key]
            if ($Values -is [System.Collections.IList]) {
                Write-Host "    $("@$Key".PadRight(20))" -NoNewline -ForegroundColor $DisabledColor
                Write-Host ($Values -join ', ')
            }
            else {
                Write-Host "    $("@$Key".PadRight(20))" -NoNewline -ForegroundColor $DisabledColor
                Write-Host ([string]$Values)
            }
        }
    }

    # Location history
    if ($Entity.LocationHistory -and $Entity.LocationHistory.Count -gt 0) {
        Write-Host ''
        Write-CLILine -Text "Historia lokalizacji ($($Entity.LocationHistory.Count))" -Color $InfoColor
        $ShowMax = [Math]::Min($Entity.LocationHistory.Count, 5)
        for ($I = 0; $I -lt $ShowMax; $I++) {
            $H = $Entity.LocationHistory[$I]
            $Loc = if ($H.Location) { $H.Location } else { '?' }
            $Range = Format-ValidityRange -ValidFrom $H.ValidFrom -ValidTo $H.ValidTo
            $RangeText = if ($Range) { " ($Range)" } else { '' }
            Write-CLILine -Text "  $([char]0x2022) $Loc$RangeText"
        }
        if ($Entity.LocationHistory.Count -gt 5) {
            Write-CLILine -Text "  ... i $($Entity.LocationHistory.Count - 5) więcej" -Color $DisabledColor
        }
    }

    # Group history
    if ($Entity.GroupHistory -and $Entity.GroupHistory.Count -gt 0) {
        Write-Host ''
        Write-CLILine -Text "Historia grup ($($Entity.GroupHistory.Count))" -Color $InfoColor
        $ShowMax = [Math]::Min($Entity.GroupHistory.Count, 5)
        for ($I = 0; $I -lt $ShowMax; $I++) {
            $H = $Entity.GroupHistory[$I]
            $Grp = if ($H.Group) { $H.Group } else { '?' }
            $Range = Format-ValidityRange -ValidFrom $H.ValidFrom -ValidTo $H.ValidTo
            $RangeText = if ($Range) { " ($Range)" } else { '' }
            Write-CLILine -Text "  $([char]0x2022) $Grp$RangeText"
        }
        if ($Entity.GroupHistory.Count -gt 5) {
            Write-CLILine -Text "  ... i $($Entity.GroupHistory.Count - 5) więcej" -Color $DisabledColor
        }
    }

    Write-Host ''
    Write-Host "  $Sep" -ForegroundColor $DisabledColor
    Write-Host "  Esc wstecz" -ForegroundColor $DisabledColor
    [void](Read-ArrowKey)
}
