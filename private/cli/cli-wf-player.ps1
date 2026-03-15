<#
    .SYNOPSIS
    Player/character-domain CLI workflows - creation, editing, and card views.

    .DESCRIPTION
    This file contains workflow functions for player and character management,
    consumed by the CLI menu registry (Mode = 'Workflow'). Dot-sourced on demand.

    Helpers:
    - Invoke-NewPlayerWorkflow:       new player + optional inline character onboarding
    - Invoke-NewCharacterWorkflow:    new character + optional starting currency loop
    - Invoke-EditCharacterWorkflow:   diff review with step-by-step parameter walk
    - Invoke-CharacterCardWorkflow:   fuzzy-pick character then show detail card
    - Show-CharacterCard:             renders character detail card (PU, aliases, info)
    - Show-PlayerCard:                renders player detail card (characters, triggers)

    New-Player and New-Character workflows chain together: creating a player
    can optionally inline-create a first character, and creating a character
    can optionally inline-create starting currency entries in a loop. Each
    stage re-uses Invoke-Wizard with override hashtables that hide internal
    parameters (EntitiesFile, NoCharacterFile) and type-hint user-facing ones
    (fuzzy source for PlayerName, multitext for Triggers/SpecialItems).

    Edit-Character walks Set-PlayerCharacter parameters one by one, skipping
    Hidden overrides and pre-filling PlayerName/CharacterName from the fuzzy
    pick. Empty values are omitted so only changed fields are submitted.

    Show-CharacterCard and Show-PlayerCard accept a $Row parameter for
    compatibility with the engine's DetailFunction callback pattern.

    Dependencies: cli-primitives.ps1, cli-fuzzy.ps1, cli-wizard.ps1
#>

# ── New Player Workflow ──────────────────────────────────────────────────────

function Invoke-NewPlayerWorkflow {
    param([object]$State, [hashtable]$Entry)

    $AccentColor = Get-CLIColor -Role 'Accent'

    # Step 1: Player basics via auto-generated wizard (hides character sub-params)
    $PlayerEntry = @{
        Function = 'New-Player'
        Overrides = @{
            'Triggers' = @{ Type = 'multitext'; Label = 'Triggery (po jednym)' }
            'CharacterName' = @{ Hidden = $true }
            'CharacterSheetUrl' = @{ Hidden = $true }
            'InitialPUStart' = @{ Hidden = $true }
            'NoCharacterFile' = @{ Hidden = $true }
            'EntitiesFile' = @{ Hidden = $true }
        }
    }

    $PlayerResult = Invoke-Wizard -RegistryEntry $PlayerEntry -State $State
    if ($PlayerResult -eq '__quit__') { return '__quit__' }
    if (-not $PlayerResult) { return }

    # Step 2: Optional inline character creation (chains into New-Character workflow)
    [System.Console]::Clear()
    Write-CLILine -Text "$([char]0x2713) Gracz utworzony pomyślnie." -Color (Get-CLIColor -Role 'Success')
    Write-Host ''
    $AddCharComponent = New-WizardStepComponent -Label 'Dodać pierwszą postać?' `
        -StepNumber 0 -TotalSteps 0 -StepType 'yesno'
    $AddCharChoice = Invoke-EngineLifecycle -Component $AddCharComponent -State $State
    if ($AddCharChoice -eq '__quit__') { return '__quit__' }

    if ($AddCharChoice -eq $true) {
        $CharWfResult = Invoke-NewCharacterWorkflow -State $State -Entry $Entry
        if ($CharWfResult -eq '__quit__') { return '__quit__' }
    }
}

# ── New Character Workflow ───────────────────────────────────────────────────

function Invoke-NewCharacterWorkflow {
    param([object]$State, [hashtable]$Entry)

    $AccentColor = Get-CLIColor -Role 'Accent'

    # Step 1: Character basics via auto-generated wizard (hides file/reputation params)
    $CharEntry = @{
        Function = 'New-PlayerCharacter'
        Overrides = @{
            'PlayerName'   = @{ Type = 'fuzzy'; Source = 'players' }
            'SpecialItems' = @{ Type = 'multitext'; Label = 'Przedmioty specjalne (po jednym)' }
            'ReputationPositive' = @{ Hidden = $true }
            'ReputationNeutral'  = @{ Hidden = $true }
            'ReputationNegative' = @{ Hidden = $true }
            'AdditionalNotes'    = @{ Type = 'multitext'; Label = 'Dodatkowe notatki' }
            'NoCharacterFile' = @{ Hidden = $true }
            'EntitiesFile'    = @{ Hidden = $true }
            'FilePath'        = @{ Hidden = $true }
        }
    }

    $CharResult = Invoke-Wizard -RegistryEntry $CharEntry -State $State
    if ($CharResult -eq '__quit__') { return '__quit__' }
    if (-not $CharResult) { return }

    # Step 2: Optional starting currency loop (creates New-CurrencyEntity entries)
    [System.Console]::Clear()
    Write-CLILine -Text "$([char]0x2713) Postać utworzona pomyślnie." -Color (Get-CLIColor -Role 'Success')
    Write-Host ''
    $AddCurrencyComponent = New-WizardStepComponent -Label 'Dodać walutę startową?' `
        -StepNumber 0 -TotalSteps 0 -StepType 'yesno'
    $AddCurrencyChoice = Invoke-EngineLifecycle -Component $AddCurrencyComponent -State $State
    if ($AddCurrencyChoice -eq '__quit__') { return '__quit__' }

    if ($AddCurrencyChoice -eq $true) {
        # Repeat until user declines "add another" prompt
        while ($true) {
            $CurrEntry = @{
                Function = 'New-CurrencyEntity'
                Overrides = @{
                    'Denomination' = @{ Type = 'selection'; Options = @('Korony Elanckie', 'Talary Hirońskie', 'Kogi Skeltvorskie') }
                    'Owner'        = @{ Type = 'fuzzy'; Source = 'entities' }
                    'EntitiesFile' = @{ Hidden = $true }
                }
            }

            $CurrResult = Invoke-Wizard -RegistryEntry $CurrEntry -State $State
            if ($CurrResult -eq '__quit__') { return '__quit__' }
            if (-not $CurrResult) { break }

            [System.Console]::Clear()
            Write-CLILine -Text "$([char]0x2713) Waluta dodana." -Color (Get-CLIColor -Role 'Success')
            Write-Host ''
            $MoreComponent = New-WizardStepComponent -Label 'Dodaj kolejną walutę?' `
                -StepNumber 0 -TotalSteps 0 -StepType 'yesno'
            $MoreCurrency = Invoke-EngineLifecycle -Component $MoreComponent -State $State
            if ($MoreCurrency -eq '__quit__') { return '__quit__' }

            if ($MoreCurrency -ne $true) { break }
        }
    }
}

# ── Edit Character Workflow (Diff Review) ────────────────────────────────────

function Invoke-EditCharacterWorkflow {
    param([object]$State, [hashtable]$Entry)

    $AccentColor = Get-CLIColor -Role 'Accent'
    $DisabledColor = Get-CLIColor -Role 'Disabled'

    Write-CLILine -Text 'Edycja postaci' -Color $AccentColor
    Write-Host ''

    # Two-stage fuzzy pick: player first, then character within that player
    $Player = Invoke-EngineFuzzySearch -Prompt 'Wybierz gracza' -Source 'players' -State $State
    if (-not $Player) { return }

    $Character = Invoke-EngineFuzzySearch -Prompt 'Wybierz postać' -Source 'characters' -State $State
    if (-not $Character) { return }

    # Override hashtable hides pre-filled and internal params from the wizard
    $EditEntry = @{
        Function = 'Set-PlayerCharacter'
        Overrides = @{
            'PlayerName'    = @{ Hidden = $true }
            'CharacterName' = @{ Hidden = $true }
            'EntitiesFile'  = @{ Hidden = $true }
            'CharacterFile' = @{ Hidden = $true }
            'FilePath'      = @{ Label = 'Ścieżka do pliku postaci (względna)' }
            'SpecialItems'  = @{ Type = 'multitext'; Label = 'Przedmioty specjalne (po jednym)' }
            'Aliases'       = @{ Type = 'multitext'; Label = 'Aliasy (po jednym)' }
            'AdditionalNotes' = @{ Type = 'multitext'; Label = 'Dodatkowe notatki (po jednym)' }
            'ReputationPositive' = @{ Hidden = $true }
            'ReputationNeutral'  = @{ Hidden = $true }
            'ReputationNegative' = @{ Hidden = $true }
        }
    }

    # Resolve Set-PlayerCharacter command metadata to build wizard steps dynamically
    $Cmd = Get-Command 'Set-PlayerCharacter' -ErrorAction SilentlyContinue
    if (-not $Cmd) {
        Write-CLILine -Text "Funkcja 'Set-PlayerCharacter' nie jest dostępna." -Color (Get-CLIColor -Role 'Error')
        [void][System.Console]::ReadKey($true)
        return
    }

    # Build wizard steps from command parameters, excluding pre-filled and hidden ones
    $Steps = [System.Collections.Generic.List[PSCustomObject]]::new()
    $Overrides = $EditEntry.Overrides
    $CollectedParams = [ordered]@{
        'PlayerName'    = $Player.Name
        'CharacterName' = $Character.Name
    }

    foreach ($ParamEntry in $Cmd.Parameters.GetEnumerator()) {
        $ParamName = $ParamEntry.Key
        $ParamInfo = $ParamEntry.Value
        if ($script:CommonParams.Contains($ParamName)) { continue }
        if ($Overrides.ContainsKey($ParamName) -and $Overrides[$ParamName].Hidden) { continue }
        if ($ParamName -eq 'PlayerName' -or $ParamName -eq 'CharacterName') { continue }

        $Override = if ($Overrides.ContainsKey($ParamName)) { $Overrides[$ParamName] } else { $null }
        $StepDef = Resolve-StepType -ParamInfo $ParamInfo -Override $Override
        [void]$Steps.Add($StepDef)
    }

    # Walk steps with back-navigation support (stepIndex-- on __back__)
    Write-Host ''
    Write-CLILine -Text "Edycja: $($Character.Name) ($($Player.Name))" -Color $AccentColor
    Write-CLILine -Text 'Pomiń pola Enter aby nie zmieniać.' -Color $DisabledColor
    Write-Host ''

    $StepIndex = 0
    while ($StepIndex -lt $Steps.Count) {
        $CurrentStep = $Steps[$StepIndex]
        $PrevValue = if ($CollectedParams.Contains($CurrentStep.Name)) { $CollectedParams[$CurrentStep.Name] } else { $null }

        $Result = Invoke-WizardStep -Step $CurrentStep -State $State -CurrentValue $PrevValue
        if ($Result -eq '__back__') {
            if ($StepIndex -gt 0) { $StepIndex-- } else { return }
            continue
        }
        if ($null -ne $Result) {
            $CollectedParams[$CurrentStep.Name] = $Result
        }
        $StepIndex++
    }

    # Only send fields the user actually modified (null = unchanged)
    $FinalParams = [ordered]@{
        'PlayerName'    = $Player.Name
        'CharacterName' = $Character.Name
    }
    foreach ($Key in $CollectedParams.Keys) {
        if ($Key -eq 'PlayerName' -or $Key -eq 'CharacterName') { continue }
        if ($null -ne $CollectedParams[$Key]) {
            $FinalParams[$Key] = $CollectedParams[$Key]
        }
    }

    if ($FinalParams.Count -le 2) {
        Write-CLILine -Text 'Brak zmian do zapisania.' -Color $DisabledColor
        Write-CLILine -Text 'Naciśnij dowolny klawisz...' -Color $DisabledColor
        [void][System.Console]::ReadKey($true)
        return
    }

    [void](Show-Preview -FunctionName 'Set-PlayerCharacter' -Parameters $FinalParams -State $State)
}

# ── Character Card Workflow ──────────────────────────────────────────────────

function Invoke-CharacterCardWorkflow {
    param([object]$State, [hashtable]$Entry)

    $AccentColor   = Get-CLIColor -Role 'Accent'

    Write-CLILine -Text 'Karta postaci' -Color $AccentColor
    Write-Host ''

    $Candidate = Invoke-EngineFuzzySearch -Prompt 'Wybierz postać' -Source 'characters' -State $State
    if (-not $Candidate) { return }

    $Ch = $Candidate.Owner  # Character sub-object
    Show-CharacterCard -Character $Ch -PlayerType $Candidate.Type -State $State
}

function Show-CharacterCard {
    param(
        [object]$Character,
        [string]$PlayerType,
        [object]$State,
        [object]$Row
    )

    # $Row fallback supports the engine's DetailFunction callback pattern
    if (-not $Character -and $Row) { $Character = $Row }

    $AccentColor   = Get-CLIColor -Role 'Accent'
    $DisabledColor = Get-CLIColor -Role 'Disabled'
    $InfoColor     = Get-CLIColor -Role 'Info'
    $Sep = [string][char]0x2500 * 50

    [System.Console]::Clear()

    Write-Host "  $Sep" -ForegroundColor $AccentColor
    $CharName = if ($Character.Name) { $Character.Name } else { [string]$Character }
    Write-CLILine -Text $CharName -Color $AccentColor
    Write-Host ''

    if ($PlayerType) {
        Write-Host "  $('Typ'.PadRight(22))" -NoNewline -ForegroundColor $InfoColor
        Write-Host $PlayerType
    }

    # Activity flag (Tak/Nie)
    if ($null -ne $Character.IsActive) {
        Write-Host "  $('Aktywna'.PadRight(22))" -NoNewline -ForegroundColor $InfoColor
        $ActiveText = if ($Character.IsActive) { 'Tak' } else { 'Nie' }
        Write-Host $ActiveText
    }

    # PU stats: show only fields present on the character object
    $PUFields = @(
        @{ Name = 'PUSum';      Label = 'PU Suma' }
        @{ Name = 'PUTaken';    Label = 'PU Zdobyte' }
        @{ Name = 'PUStart';    Label = 'PU Startowe' }
        @{ Name = 'PUExceeded'; Label = 'PU Nadmiar' }
    )
    $HasPU = $false
    foreach ($PF in $PUFields) {
        if ($Character.PSObject.Properties[$PF.Name] -and $null -ne $Character.($PF.Name)) {
            if (-not $HasPU) {
                Write-Host ''
                Write-CLILine -Text 'Punkty Umiejętności' -Color $InfoColor
                $HasPU = $true
            }
            Write-Host "    $($PF.Label.PadRight(20))" -NoNewline -ForegroundColor $DisabledColor
            Write-Host ([string]$Character.($PF.Name))
        }
    }

    # Alias list (may contain plain strings or objects with .Text property)
    if ($Character.Aliases -and $Character.Aliases.Count -gt 0) {
        Write-Host ''
        Write-CLILine -Text 'Aliasy' -Color $InfoColor
        foreach ($Alias in $Character.Aliases) {
            $AliasText = if ($Alias -is [string]) { $Alias }
                         elseif ($Alias.Text) { $Alias.Text }
                         else { [string]$Alias }
            Write-CLILine -Text "  $([char]0x2022) $AliasText"
        }
    }

    # Free-text notes from the character file
    if ($Character.AdditionalInfo -and $Character.AdditionalInfo.Count -gt 0) {
        Write-Host ''
        Write-CLILine -Text 'Dodatkowe informacje' -Color $InfoColor
        foreach ($Info in $Character.AdditionalInfo) {
            Write-CLILine -Text "  $([char]0x2022) $Info"
        }
    }

    Write-Host ''
    Write-Host "  $Sep" -ForegroundColor $DisabledColor
    Write-Host "  Esc wstecz" -ForegroundColor $DisabledColor
    [void][System.Console]::ReadKey($true)
}

function Show-PlayerCard {
    param(
        [object]$Player,
        [object]$State,
        [object]$Row
    )

    if (-not $Player -and $Row) { $Player = $Row }

    $AccentColor   = Get-CLIColor -Role 'Accent'
    $DisabledColor = Get-CLIColor -Role 'Disabled'
    $InfoColor     = Get-CLIColor -Role 'Info'
    $Sep = [string][char]0x2500 * 50

    [System.Console]::Clear()

    Write-Host "  $Sep" -ForegroundColor $AccentColor
    Write-CLILine -Text "$($Player.Name)" -Color $AccentColor
    Write-Host ''

    if ($Player.MargonemID) {
        Write-Host "  $('MargonemID'.PadRight(22))" -NoNewline -ForegroundColor $InfoColor
        Write-Host "$($Player.MargonemID)"
    }

    if ($Player.PRFWebhook) {
        Write-Host "  $('Webhook'.PadRight(22))" -NoNewline -ForegroundColor $InfoColor
        Write-Host "$($Player.PRFWebhook)"
    }

    if ($Player.Triggers -and $Player.Triggers.Count -gt 0) {
        Write-Host "  $('Triggery'.PadRight(22))" -NoNewline -ForegroundColor $InfoColor
        Write-Host ($Player.Triggers -join ', ')
    }

    # Character roster with active/PU summary per character
    if ($Player.Characters -and $Player.Characters.Count -gt 0) {
        Write-Host ''
        Write-CLILine -Text "Postacie ($($Player.Characters.Count))" -Color $InfoColor
        foreach ($Ch in $Player.Characters) {
            $CharName = if ($Ch.Name) { $Ch.Name } else { [string]$Ch }
            $ActiveMark = if ($Ch.IsActive) { " $([char]0x2713)" } else { '' }
            $PUText = if ($null -ne $Ch.PUSum) { "  PU: $($Ch.PUSum)" } else { '' }
            Write-Host "    $([char]0x2022) $CharName$ActiveMark$PUText"

            if ($Ch.Aliases -and $Ch.Aliases.Count -gt 0) {
                $AliasList = $Ch.Aliases | ForEach-Object { if ($_ -is [string]) { $_ } elseif ($_.Text) { $_.Text } else { [string]$_ } }
                Write-Host "      Aliasy: $($AliasList -join ', ')" -ForegroundColor $DisabledColor
            }
        }
    }

    Write-Host ''
    Write-Host "  $Sep" -ForegroundColor $DisabledColor
    Write-Host "  Esc wstecz" -ForegroundColor $DisabledColor
    [void][System.Console]::ReadKey($true)
}
