<#
    .SYNOPSIS
    Entity-domain CLI workflows - creation, editing, history, and search.

    .DESCRIPTION
    This file contains workflow functions for entity management, consumed by
    the CLI menu registry (Mode = 'Workflow'). Dot-sourced on demand.

    Display helpers (Format-ValidityRange, Show-EntityCard) live in
    cli-display-entity.ps1 and are chain-loaded via dot-source below.

    Workflows:
    - Invoke-NewEntityWorkflow:      guided tag entry for new entities
    - Invoke-EditEntityWorkflow:     diff review with context for entity edits
    - Invoke-EntityHistoryWorkflow:  fuzzy-pick then history timeline
    - Invoke-EntitySearchWorkflow:   fuzzy search then detail card

    Dependencies: cli-primitives.ps1, cli-fuzzy.ps1, cli-wizard.ps1, cli-display-entity.ps1
#>

. "$PSScriptRoot/cli-display-entity.ps1"

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
