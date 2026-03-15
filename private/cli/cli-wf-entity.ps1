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

    $Colors = Initialize-WorkflowScreen -Title 'Kreator nowej encji'
    $AccentColor   = $Colors.Accent
    $DisabledColor = $Colors.Disabled
    $InfoColor     = $Colors.Info
    $Sep = [string][char]0x2500 * 50

    # Step 1: Entity type
    $TypeComponent = New-WizardStepComponent -Label 'Typ encji' `
        -StepNumber 0 -TotalSteps 0 -StepType 'selection' `
        -Options @('NPC', 'Grupa', 'Lokacja', 'Przedmiot')
    $Type = Invoke-EngineLifecycle -Component $TypeComponent -State $State
    if ($Type -eq '__quit__') { return '__quit__' }
    if ($Type -eq '__back__') { return }

    # Step 2: Name
    [System.Console]::Clear()
    Write-CLILine -Text 'Kreator nowej encji' -Color $AccentColor
    Write-Host "  $Sep" -ForegroundColor $DisabledColor
    Write-Host "  $('Typ'.PadRight(22))" -NoNewline -ForegroundColor $InfoColor
    Write-Host $Type
    Write-Host ''

    $NameStep = New-WizardTextStep -Name 'Name' -Label 'Nazwa encji' -Required
    $Name = Invoke-WizardStep -Step $NameStep -State $State
    if ($Name -eq '__back__' -or -not $Name) { return }

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

        $TagSelectOptions = @(($CommonTags | ForEach-Object { "@$_" })) + @('Inny tag (wpisz)', 'Zakończ dodawanie tagów')
        $TagSelectComponent = New-WizardStepComponent -Label 'Dodaj tag' `
            -StepNumber 0 -TotalSteps 0 -StepType 'selection' `
            -Options $TagSelectOptions
        $TagChoice = Invoke-EngineLifecycle -Component $TagSelectComponent -State $State
        if ($TagChoice -eq '__back__' -or $TagChoice -eq '__quit__' -or $TagChoice -eq 'Zakończ dodawanie tagów') { break }

        $TagName = if ($TagChoice -match '^@(.+)$') { $Matches[1] } else { $TagChoice }
        if ($TagChoice -eq 'Inny tag (wpisz)') {
            $CustomTagStep = New-WizardTextStep -Name 'Tag' -Label 'Nazwa tagu' -Required
            $TagName = Invoke-WizardStep -Step $CustomTagStep -State $State
            if (-not $TagName -or $TagName -eq '__back__') { continue }
        }

        # Tag value - use fuzzy for lokacja/grupa, text for others
        $ValueStep = if ($TagName -ieq 'lokacja') {
            New-WizardFuzzyStep -Name 'Value' -Label "Wartość @$TagName" -Source 'locations'
        } elseif ($TagName -ieq 'grupa') {
            New-WizardFuzzyStep -Name 'Value' -Label "Wartość @$TagName" -Source 'groups'
        } else {
            New-WizardTextStep -Name 'Value' -Label "Wartość @$TagName" -Required
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

    $Colors = Initialize-WorkflowScreen -Title 'Edycja encji'
    $AccentColor   = $Colors.Accent
    $DisabledColor = $Colors.Disabled
    $InfoColor     = $Colors.Info
    $Sep = [string][char]0x2500 * 50

    # Pick entity
    $Entity = Invoke-EngineFuzzySearch -Prompt 'Wybierz encję' -Source 'entities' -State $State
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

        $TagSelectOptions = @(($CommonTags | ForEach-Object { "@$_" })) + @('Inny tag (wpisz)', 'Zakończ')
        $TagSelectComponent = New-WizardStepComponent -Label 'Dodaj/zmień tag' `
            -StepNumber 0 -TotalSteps 0 -StepType 'selection' `
            -Options $TagSelectOptions
        $TagChoice = Invoke-EngineLifecycle -Component $TagSelectComponent -State $State
        if ($TagChoice -eq '__back__' -or $TagChoice -eq '__quit__' -or $TagChoice -eq 'Zakończ') { break }

        $TagName = if ($TagChoice -match '^@(.+)$') { $Matches[1] } else { $TagChoice }
        if ($TagChoice -eq 'Inny tag (wpisz)') {
            $CustomStep = New-WizardTextStep -Name 'Tag' -Label 'Nazwa tagu' -Required
            $TagName = Invoke-WizardStep -Step $CustomStep -State $State
            if (-not $TagName -or $TagName -eq '__back__') { continue }
        }

        # Tag value - use fuzzy for lokacja/grupa, text for others
        $ValueStep = if ($TagName -ieq 'lokacja') {
            New-WizardFuzzyStep -Name 'Value' -Label "Wartość @$TagName" -Source 'locations'
        } elseif ($TagName -ieq 'grupa') {
            New-WizardFuzzyStep -Name 'Value' -Label "Wartość @$TagName" -Source 'groups'
        } else {
            New-WizardTextStep -Name 'Value' -Label "Wartość @$TagName" -Required
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
        [void][System.Console]::ReadKey($true)
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

    $Entity = Invoke-EngineFuzzySearch -Prompt 'Wybierz encję' -Source 'entities' -State $State
    if (-not $Entity) { return }

    try {
        $History = Get-EntityHistory -EntityName $Entity.Name
        if (-not $History -or $History.Count -eq 0) {
            Write-CLILine -Text 'Brak historii dla tej encji.' -Color (Get-CLIColor -Role 'Disabled')
            Write-CLILine -Text 'Naciśnij dowolny klawisz...' -Color (Get-CLIColor -Role 'Disabled')
            [void][System.Console]::ReadKey($true)
            return
        }

        $TableComponent = New-ResultTableComponent -Data $History `
            -Columns @('Date', 'Property', 'Value', 'Source') `
            -Headers @('Data', 'Właściwość', 'Wartość', 'Źródło') `
            -Widths @(12, 15, 25, 20) `
            -Title "Historia: $($Entity.Name)"
        [void](Invoke-EngineLifecycle -Component $TableComponent -State $State)
    }
    catch {
        Write-CLILine -Text "Błąd: $_" -Color (Get-CLIColor -Role 'Error')
        Write-CLILine -Text 'Naciśnij dowolny klawisz...' -Color (Get-CLIColor -Role 'Disabled')
        [void][System.Console]::ReadKey($true)
    }
}

# ── Entity Search Workflow ───────────────────────────────────────────────────

function Invoke-EntitySearchWorkflow {
    param([object]$State, [hashtable]$Entry)

    $AccentColor = Get-CLIColor -Role 'Accent'

    Write-CLILine -Text 'Wyszukiwanie encji' -Color $AccentColor
    Write-Host ''

    $Result = Invoke-EngineFuzzySearch -Prompt 'Szukaj' -Source 'entities' -State $State
    if (-not $Result) { return }

    # Display entity detail card
    Show-EntityCard -Entity $Result.Owner -State $State
}
