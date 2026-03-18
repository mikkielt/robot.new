<#
    .SYNOPSIS
    Entity-domain CLI workflows - creation, editing, history, and search.

    .DESCRIPTION
    This file contains workflow functions for entity management, consumed by
    the CLI menu registry (Mode = 'Workflow'). Dot-sourced on demand.
    Chain-loads cli-display-entity.ps1 for display helpers (Format-ValidityRange,
    Show-EntityCard).

    Helpers:
    - Invoke-NewEntityWorkflow:      guided tag entry loop for new entities
    - Invoke-EditEntityWorkflow:     diff review with existing-tag context for entity edits
    - Invoke-EntityHistoryWorkflow:  fuzzy-pick entity then show change history timeline
    - Invoke-EntitySearchWorkflow:   fuzzy search then entity detail card

    New/Edit entity workflows use an interactive tag loop: the user picks
    a tag name from a common set (@lokacja, @grupa, @status, @alias, @typ,
    @info) or types a custom one, then enters a value. @lokacja and @grupa
    values use fuzzy entity search; all others use free-text input. The
    accumulated tags are passed to New-Entity / Set-Entity via Show-Preview
    which runs the operation with -WhatIf for review before confirming.

    When type is Lokacja, the new-entity workflow adds guided prompts for
    parent location (fuzzy), coordinates (X, Y with validation), Nerthus
    name, and door connections (multi-entry fuzzy). These are passed to
    New-LocationEntity instead of generic New-Entity.

    The screen is fully redrawn before each fuzzy search step because the
    engine's cursor positioning can overflow when a fuzzy search viewport
    follows an arrow-based selection menu on the same screen.

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

    # Step 1: Entity type (determines which @tags are relevant)
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

    # Step 2.5: Location-specific guided prompts (Lokacja type only)
    $LocParent      = $null
    $LocCoords      = $null
    $LocNerthusName = $null
    $LocDoors       = @()

    if ($Type -eq 'Lokacja') {
        # Parent location (optional fuzzy pick)
        $AskParent = New-WizardStepComponent -Label 'Dodać lokację nadrzędną?' `
            -StepNumber 0 -TotalSteps 0 -StepType 'yesno'
        $WantsParent = Invoke-EngineLifecycle -Component $AskParent -State $State
        if ($WantsParent -eq '__quit__') { return '__quit__' }
        if ($WantsParent -eq $true) {
            [System.Console]::Clear()
            Write-CLILine -Text 'Kreator nowej encji' -Color $AccentColor
            Write-Host "  $Sep" -ForegroundColor $DisabledColor
            Write-Host "  $('Typ'.PadRight(22))" -NoNewline -ForegroundColor $InfoColor
            Write-Host $Type
            Write-Host "  $('Nazwa'.PadRight(22))" -NoNewline -ForegroundColor $InfoColor
            Write-Host $Name
            Write-Host ''
            $ParentResult = Invoke-EngineFuzzySearch -Prompt 'Lokacja nadrzędna' -Source 'locations' -State $State
            if ($ParentResult) { $LocParent = $ParentResult.Name }
        }

        # Coordinates (optional text input with X, Y validation)
        [System.Console]::Clear()
        Write-CLILine -Text 'Kreator nowej encji' -Color $AccentColor
        Write-Host "  $Sep" -ForegroundColor $DisabledColor
        Write-Host "  $('Typ'.PadRight(22))" -NoNewline -ForegroundColor $InfoColor
        Write-Host $Type
        Write-Host "  $('Nazwa'.PadRight(22))" -NoNewline -ForegroundColor $InfoColor
        Write-Host $Name
        if ($LocParent) {
            Write-Host "  $('Lokacja'.PadRight(22))" -NoNewline -ForegroundColor $InfoColor
            Write-Host $LocParent
        }
        Write-Host ''
        $CoordsStep = New-WizardTextStep -Name 'Coords' -Label 'Koordynaty X, Y (puste = pomiń)'
        $CoordsInput = Invoke-WizardStep -Step $CoordsStep -State $State
        if ($CoordsInput -and $CoordsInput -ne '__back__') {
            if ($CoordsInput -match '^\s*(\d+)\s*,\s*(\d+)\s*$') {
                $LocCoords = $CoordsInput.Trim()
            } else {
                Write-CLILine -Text 'Nieprawidłowy format — pominięto (oczekiwano X, Y).' -Color (Get-CLIColor -Role 'Error')
                [System.Threading.Thread]::Sleep(1000)
            }
        }

        # NerthusName (optional text input)
        [System.Console]::Clear()
        Write-CLILine -Text 'Kreator nowej encji' -Color $AccentColor
        Write-Host "  $Sep" -ForegroundColor $DisabledColor
        Write-Host "  $('Typ'.PadRight(22))" -NoNewline -ForegroundColor $InfoColor
        Write-Host $Type
        Write-Host "  $('Nazwa'.PadRight(22))" -NoNewline -ForegroundColor $InfoColor
        Write-Host $Name
        if ($LocParent) {
            Write-Host "  $('Lokacja'.PadRight(22))" -NoNewline -ForegroundColor $InfoColor
            Write-Host $LocParent
        }
        if ($LocCoords) {
            Write-Host "  $('Koordynaty'.PadRight(22))" -NoNewline -ForegroundColor $InfoColor
            Write-Host $LocCoords
        }
        Write-Host ''
        $NerthusStep = New-WizardTextStep -Name 'NerthusName' -Label 'Nazwa Nerthus (puste = pomiń)'
        $NerthusInput = Invoke-WizardStep -Step $NerthusStep -State $State
        if ($NerthusInput -and $NerthusInput -ne '__back__') {
            $LocNerthusName = $NerthusInput
        }

        # Doors (multi-entry fuzzy from locations, optional)
        $AskDoors = New-WizardStepComponent -Label 'Dodać drzwi?' `
            -StepNumber 0 -TotalSteps 0 -StepType 'yesno'
        $WantsDoors = Invoke-EngineLifecycle -Component $AskDoors -State $State
        if ($WantsDoors -eq '__quit__') { return '__quit__' }
        if ($WantsDoors -eq $true) {
            $DoorList = [System.Collections.Generic.List[string]]::new()
            $DoorNum = 1
            while ($true) {
                [System.Console]::Clear()
                Write-CLILine -Text 'Kreator nowej encji' -Color $AccentColor
                Write-Host "  $Sep" -ForegroundColor $DisabledColor
                Write-Host "  $('Typ'.PadRight(22))" -NoNewline -ForegroundColor $InfoColor
                Write-Host $Type
                Write-Host "  $('Nazwa'.PadRight(22))" -NoNewline -ForegroundColor $InfoColor
                Write-Host $Name
                if ($LocParent) {
                    Write-Host "  $('Lokacja'.PadRight(22))" -NoNewline -ForegroundColor $InfoColor
                    Write-Host $LocParent
                }
                if ($DoorList.Count -gt 0) {
                    Write-Host "  $('Drzwi'.PadRight(22))" -NoNewline -ForegroundColor $InfoColor
                    Write-Host ($DoorList -join ', ')
                }
                Write-Host ''
                $DoorResult = Invoke-EngineFuzzySearch -Prompt "Drzwi ($DoorNum)" -Source 'locations' -State $State
                if (-not $DoorResult) { break }
                [void]$DoorList.Add($DoorResult.Name)
                $DoorNum++
                $AddMoreDoors = New-WizardStepComponent -Label 'Dodać kolejne drzwi?' `
                    -StepNumber 0 -TotalSteps 0 -StepType 'yesno'
                $MoreDoors = Invoke-EngineLifecycle -Component $AddMoreDoors -State $State
                if ($MoreDoors -ne $true) { break }
            }
            $LocDoors = $DoorList.ToArray()
        }
    }

    # Step 3: Guided tag entry loop (user adds tags until choosing 'Zakończ')
    $Tags = @{}
    # Skip @lokacja from common tags for Lokacja type — already handled by Parent prompt
    $CommonTags = if ($Type -eq 'Lokacja') {
        @('grupa', 'status', 'alias', 'typ', 'info')
    } else {
        @('lokacja', 'grupa', 'status', 'alias', 'typ', 'info')
    }

    while ($true) {
        # Redraw screen with current context
        [System.Console]::Clear()
        Write-CLILine -Text 'Kreator nowej encji' -Color $AccentColor
        Write-Host "  $Sep" -ForegroundColor $DisabledColor
        Write-Host "  $('Typ'.PadRight(22))" -NoNewline -ForegroundColor $InfoColor
        Write-Host $Type
        Write-Host "  $('Nazwa'.PadRight(22))" -NoNewline -ForegroundColor $InfoColor
        Write-Host $Name
        if ($LocParent) {
            Write-Host "  $('Lokacja'.PadRight(22))" -NoNewline -ForegroundColor $InfoColor
            Write-Host $LocParent
        }
        if ($LocCoords) {
            Write-Host "  $('Koordynaty'.PadRight(22))" -NoNewline -ForegroundColor $InfoColor
            Write-Host $LocCoords
        }
        if ($LocNerthusName) {
            Write-Host "  $('Nazwa Nerthus'.PadRight(22))" -NoNewline -ForegroundColor $InfoColor
            Write-Host $LocNerthusName
        }
        if ($LocDoors.Count -gt 0) {
            Write-Host "  $('Drzwi'.PadRight(22))" -NoNewline -ForegroundColor $InfoColor
            Write-Host ($LocDoors -join ', ')
        }
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

        # @lokacja/@grupa use fuzzy entity search; all others use free text
        $ValueStep = if ($TagName -ieq 'lokacja') {
            New-WizardFuzzyStep -Name 'Value' -Label "Wartość @$TagName" -Source 'locations'
        } elseif ($TagName -ieq 'grupa') {
            New-WizardFuzzyStep -Name 'Value' -Label "Wartość @$TagName" -Source 'groups'
        } else {
            New-WizardTextStep -Name 'Value' -Label "Wartość @$TagName" -Required
        }

        # Full redraw prevents cursor overflow when fuzzy viewport follows arrow menu
        [System.Console]::Clear()
        Write-CLILine -Text 'Kreator nowej encji' -Color $AccentColor
        Write-Host "  $Sep" -ForegroundColor $DisabledColor
        Write-Host "  $('Typ'.PadRight(22))" -NoNewline -ForegroundColor $InfoColor
        Write-Host $Type
        Write-Host "  $('Nazwa'.PadRight(22))" -NoNewline -ForegroundColor $InfoColor
        Write-Host $Name
        if ($LocParent) {
            Write-Host "  $('Lokacja'.PadRight(22))" -NoNewline -ForegroundColor $InfoColor
            Write-Host $LocParent
        }
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

    # Show-Preview runs the creation command with -WhatIf for review before confirming
    if ($Type -eq 'Lokacja') {
        $Params = [ordered]@{ 'Name' = $Name }
        if ($LocParent)      { $Params['Parent']      = $LocParent }
        if ($LocCoords)      { $Params['Coordinates'] = $LocCoords }
        if ($LocNerthusName) { $Params['NerthusName']  = $LocNerthusName }
        if ($LocDoors.Count -gt 0) { $Params['Doors'] = $LocDoors }
        if ($Tags.Count -gt 0) { $Params['Tags'] = $Tags }
        [void](Show-Preview -FunctionName 'New-LocationEntity' -Parameters $Params -State $State)
    } else {
        $Params = [ordered]@{
            'Type' = $Type
            'Name' = $Name
        }
        if ($Tags.Count -gt 0) { $Params['Tags'] = $Tags }
        [void](Show-Preview -FunctionName 'New-Entity' -Parameters $Params -State $State)
    }
}

# ── Edit Entity Workflow (Diff Review with Context) ──────────────────────────

function Invoke-EditEntityWorkflow {
    param([object]$State, [hashtable]$Entry)

    $Colors = Initialize-WorkflowScreen -Title 'Edycja encji'
    $AccentColor   = $Colors.Accent
    $DisabledColor = $Colors.Disabled
    $InfoColor     = $Colors.Info
    $Sep = [string][char]0x2500 * 50

    # Pick entity via fuzzy search (returns candidate with .Owner entity object)
    $Entity = Invoke-EngineFuzzySearch -Prompt 'Wybierz encję' -Source 'entities' -State $State
    if (-not $Entity) { return }

    $EntityObj = $Entity.Owner

    # Guided tag upsert loop (shows existing overrides as context for the user)
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

        # @lokacja/@grupa use fuzzy entity search; all others use free text
        $ValueStep = if ($TagName -ieq 'lokacja') {
            New-WizardFuzzyStep -Name 'Value' -Label "Wartość @$TagName" -Source 'locations'
        } elseif ($TagName -ieq 'grupa') {
            New-WizardFuzzyStep -Name 'Value' -Label "Wartość @$TagName" -Source 'groups'
        } else {
            New-WizardTextStep -Name 'Value' -Label "Wartość @$TagName" -Required
        }

        # Full redraw prevents cursor overflow when fuzzy viewport follows arrow menu
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

    # Show rich entity card (PU, aliases, locations, overrides)
    Show-EntityCard -Entity $Result.Owner -State $State
}
