<#
    .SYNOPSIS
    Menu registry - single-source-of-truth definition of all CLI menu items.

    .DESCRIPTION
    This file defines $script:MenuOrder (top-level category list) and
    $script:MenuRegistry (flat array of menu item hashtables). It is pure
    data with zero logic - consumed by the routing layer (cli-routing.ps1).

    Adding a new feature = adding one hashtable to $script:MenuRegistry.

    Module-level data:
    - $script:MenuOrder:    ordered list of top-level menu category names
    - $script:MenuRegistry: flat array of menu item definitions

    Entry schema:
    - ID:               unique string identifier
    - Label:            display name in the menu
    - Description:      short description shown next to label
    - Function:         PowerShell function name to invoke
    - Menu:             parent category (must be in $script:MenuOrder)
    - Role:             'N' (Narrator), 'K' (Koordinator), or 'N/K' (optional)
    - Mode:             'Wizard' (default), 'Query', or 'Workflow'
    - Overrides:        hashtable of parameter overrides for wizard auto-gen
    - WorkflowFunction: function name for Mode = 'Workflow'
    - Columns/Headers/Widths: table config for Mode = 'Query'
    - PreChecks:        string array of pre-check descriptions
    - InfoText:         info text shown when item is selected
#>

# ── Menu Category Order ──────────────────────────────────────────────────────

$script:MenuOrder = @(
    'Sesje'
    'Gracze i Postacie'
    'Encje'
    'Waluta'
    'PU'
    'Raporty i Narzędzia'
    'Migracja'
)

# ── Menu Registry ────────────────────────────────────────────────────────────

$script:MenuRegistry = @(

    # ─── Sesje ────────────────────────────────────────────────────────────────

    @{
        ID       = 'new-session'
        Label    = 'Nowa sesja'
        Description = 'Kreator nowej sesji Gen4'
        Function = 'New-Session'
        Menu     = 'Sesje'
        Role     = 'N'
        Overrides = @{
            'Date'      = @{ Type = 'date' }
            'DateEnd'   = @{ Type = 'date' }
            'Narrator'  = @{ Type = 'fuzzy'; Source = 'players' }
            'MetadataNarrators' = @{ Hidden = $true }
            'Locations' = @{ Type = 'multi-entry'; EntrySource = 'locations' }
            'PU'        = @{ Type = 'multi-entry-nested'; SubSteps = @(
                              @{ Param = 'Character'; Label = 'Postać'; Type = 'fuzzy'; Source = 'characters' }
                              @{ Param = 'Value'; Label = 'Wartość PU'; Type = 'decimal' }
                          )}
            'Changes'   = @{ Type = 'multi-entry-nested'; SubSteps = @(
                              @{ Param = 'EntityName'; Label = 'Encja'; Type = 'fuzzy'; Source = 'entities' }
                              @{ Param = 'Tags'; Label = 'Tagi'; Type = 'text' }
                          )}
            'Intel'     = @{ Type = 'multi-entry-nested'; SubSteps = @(
                              @{ Param = 'Target'; Label = 'Typ celu'; Type = 'selection'; Options = @('Bezpośrednio','Grupa','Lokacja') }
                              @{ Param = 'Name'; Label = 'Nazwa'; Type = 'fuzzy'; Source = 'entities' }
                              @{ Param = 'Message'; Label = 'Wiadomość'; Type = 'text' }
                          )}
            'Logs'      = @{ Type = 'multitext'; Label = 'URL logów sesji' }
            'Content'   = @{ Type = 'text'; Label = 'Treść sesji' }
        }
    }

    @{
        ID       = 'edit-session'
        Label    = 'Edytuj sesję'
        Description = 'Zmiana metadanych sesji'
        Function = 'Set-Session'
        Menu     = 'Sesje'
        Role     = 'N'
        Mode     = 'Workflow'
        WorkflowFunction = 'Invoke-EditSessionWorkflow'
    }

    @{
        ID       = 'validate-session'
        Label    = 'Walidacja sesji'
        Description = 'Sprawdzenie poprawności sesji'
        Menu     = 'Sesje'
        Role     = 'N'
        Mode     = 'Workflow'
        WorkflowFunction = 'Invoke-SessionValidation'
        PreChecks = @('Format daty', 'Nazwy postaci w PU', 'Nazwy encji w Zmiany', 'Nazwy lokacji')
        InfoText = @('Sprawdzi: daty, nazwy postaci, nazwy encji, lokacje')
    }

    @{
        ID       = 'browse-sessions'
        Label    = 'Przeglądaj sesje'
        Description = 'Lista sesji z filtrowaniem'
        Function = 'Get-Session'
        Menu     = 'Sesje'
        Mode     = 'Query'
        Columns  = @('Date', 'Title', 'NarratorName')
        Headers  = @('Data', 'Tytuł', 'Narrator')
        Widths   = @(12, 35, 15)
        ColumnResolvers = @{
            'NarratorName' = { param($R) if ($R.Narrator) { $R.Narrator.RawText } else { '' } }
        }
        FilterOverrides = @{
            'MinDate' = @{ Type = 'date'; Label = 'Od daty'; Required = $false }
            'MaxDate' = @{ Type = 'date'; Label = 'Do daty'; Required = $false }
        }
    }

    @{
        ID       = 'git-changelog'
        Label    = 'Historia zmian (git)'
        Description = 'Logi git z repozytorium'
        Function = 'Get-GitChangeLog'
        Menu     = 'Sesje'
        Mode     = 'Query'
        Columns  = @('CommitDate', 'AuthorName', 'FileCount')
        Headers  = @('Data', 'Autor', 'Pliki')
        Widths   = @(12, 20, 8)
        ColumnResolvers = @{
            'FileCount' = { param($R) if ($R.Files) { [string]$R.Files.Count } else { '0' } }
        }
        FilterOverrides = @{
            'MinDate' = @{ Type = 'text'; Label = 'Od daty (RRRR-MM-DD)'; Required = $false }
            'MaxDate' = @{ Type = 'text'; Label = 'Do daty (RRRR-MM-DD)'; Required = $false }
        }
    }

    # ─── Gracze i Postacie ────────────────────────────────────────────────────

    @{
        ID       = 'new-player'
        Label    = 'Nowy gracz'
        Description = 'Rejestracja nowego gracza'
        Function = 'New-Player'
        Menu     = 'Gracze i Postacie'
        Role     = 'K'
        Mode     = 'Workflow'
        WorkflowFunction = 'Invoke-NewPlayerWorkflow'
        Overrides = @{
            'Triggers' = @{ Type = 'multitext'; Label = 'Triggery (po jednym)' }
            'EntitiesFile' = @{ Hidden = $true }
        }
    }

    @{
        ID       = 'new-character'
        Label    = 'Nowa postać'
        Description = 'Kreator nowej postaci z walutą'
        Function = 'New-PlayerCharacter'
        Menu     = 'Gracze i Postacie'
        Role     = 'K'
        Mode     = 'Workflow'
        WorkflowFunction = 'Invoke-NewCharacterWorkflow'
        Overrides = @{
            'PlayerName' = @{ Type = 'fuzzy'; Source = 'players' }
            'SpecialItems' = @{ Type = 'multitext'; Label = 'Przedmioty specjalne (po jednym)' }
            'NoCharacterFile' = @{ Hidden = $true }
            'EntitiesFile' = @{ Hidden = $true }
        }
    }

    @{
        ID       = 'edit-character'
        Label    = 'Edytuj postać'
        Description = 'Zmiana danych postaci'
        Function = 'Set-PlayerCharacter'
        Menu     = 'Gracze i Postacie'
        Role     = 'K'
        Mode     = 'Workflow'
        WorkflowFunction = 'Invoke-EditCharacterWorkflow'
    }

    @{
        ID       = 'edit-player'
        Label    = 'Edytuj gracza'
        Description = 'Zmiana danych gracza'
        Function = 'Set-Player'
        Menu     = 'Gracze i Postacie'
        Role     = 'K'
        Overrides = @{
            'Name'     = @{ Type = 'fuzzy'; Source = 'players' }
            'Triggers' = @{ Type = 'multitext'; Label = 'Triggery (po jednym)' }
            'Aliases'  = @{ Type = 'multitext'; Label = 'Aliasy (po jednym)' }
            'EntitiesFile' = @{ Hidden = $true }
        }
    }

    @{
        ID       = 'remove-character'
        Label    = 'Usuń postać'
        Description = 'Oznaczenie postaci jako usuniętej'
        Function = 'Remove-PlayerCharacter'
        Menu     = 'Gracze i Postacie'
        Role     = 'K'
        Overrides = @{
            'PlayerName'    = @{ Type = 'fuzzy'; Source = 'players' }
            'CharacterName' = @{ Type = 'fuzzy'; Source = 'characters' }
            'EntitiesFile'  = @{ Hidden = $true }
        }
    }

    @{
        ID       = 'browse-players'
        Label    = 'Przeglądaj graczy'
        Description = 'Lista graczy i postaci'
        Function = 'Get-Player'
        Menu     = 'Gracze i Postacie'
        Mode     = 'Query'
        Columns  = @('Name', 'CharacterCount', 'ActiveCharacter')
        Headers  = @('Nazwa', 'Postacie', 'Aktywna postać')
        Widths   = @(20, 10, 25)
        ColumnResolvers = @{
            'CharacterCount'  = { param($R) if ($R.Characters) { [string]$R.Characters.Count } else { '0' } }
            'ActiveCharacter' = { param($R)
                if ($R.Characters) {
                    $Active = $R.Characters | Where-Object { $_.IsActive } | Select-Object -First 1
                    if ($Active) { $Active.Name } else { '-' }
                } else { '-' }
            }
        }
        DetailFunction = 'Show-PlayerCard'
    }

    @{
        ID       = 'character-card'
        Label    = 'Karta postaci'
        Description = 'Szczegółowy widok postaci'
        Menu     = 'Gracze i Postacie'
        Mode     = 'Workflow'
        WorkflowFunction = 'Invoke-CharacterCardWorkflow'
    }

    # ─── Encje ────────────────────────────────────────────────────────────────

    @{
        ID       = 'new-entity'
        Label    = 'Nowa encja'
        Description = 'Kreator nowej encji (NPC/Grupa/Lokacja/Przedmiot)'
        Function = 'New-Entity'
        Menu     = 'Encje'
        Role     = 'K'
        Mode     = 'Workflow'
        WorkflowFunction = 'Invoke-NewEntityWorkflow'
    }

    @{
        ID       = 'edit-entity'
        Label    = 'Edytuj encję'
        Description = 'Zmiana tagów encji'
        Function = 'Set-Entity'
        Menu     = 'Encje'
        Role     = 'K'
        Mode     = 'Workflow'
        WorkflowFunction = 'Invoke-EditEntityWorkflow'
    }

    @{
        ID       = 'remove-entity'
        Label    = 'Usuń encję'
        Description = 'Oznaczenie encji jako usuniętej'
        Function = 'Remove-Entity'
        Menu     = 'Encje'
        Role     = 'K'
        Overrides = @{
            'Name' = @{ Type = 'fuzzy'; Source = 'entities' }
            'EntitiesFile' = @{ Hidden = $true }
        }
    }

    @{
        ID       = 'browse-entities'
        Label    = 'Przeglądaj encje'
        Description = 'Lista encji z filtrem typu'
        Function = 'Get-Entity'
        Menu     = 'Encje'
        Mode     = 'Query'
        Columns  = @('Name', 'Type', 'Status')
        Headers  = @('Nazwa', 'Typ', 'Status')
        Widths   = @(30, 15, 12)
        DetailFunction = 'Show-EntityCard'
    }

    @{
        ID       = 'entity-history'
        Label    = 'Historia encji'
        Description = 'Chronologia zmian encji'
        Function = 'Get-EntityHistory'
        Menu     = 'Encje'
        Mode     = 'Workflow'
        WorkflowFunction = 'Invoke-EntityHistoryWorkflow'
    }

    @{
        ID       = 'search-entity'
        Label    = 'Szukaj'
        Description = 'Wyszukiwanie encji po nazwie'
        Menu     = 'Encje'
        Mode     = 'Workflow'
        WorkflowFunction = 'Invoke-EntitySearchWorkflow'
    }

    # ─── Waluta ───────────────────────────────────────────────────────────────

    @{
        ID       = 'new-currency'
        Label    = 'Nowa waluta'
        Description = 'Utworzenie encji walutowej'
        Function = 'New-CurrencyEntity'
        Menu     = 'Waluta'
        Role     = 'K'
        Overrides = @{
            'Denomination' = @{ Type = 'selection'; Options = @('Korony Elanckie', 'Talary Hirońskie', 'Kogi Skeltvorskie') }
            'Owner'        = @{ Type = 'fuzzy'; Source = 'entities' }
            'EntitiesFile' = @{ Hidden = $true }
        }
    }

    @{
        ID       = 'set-currency-balance'
        Label    = 'Zmień saldo'
        Description = 'Zmiana ilości waluty'
        Function = 'Set-CurrencyEntity'
        Menu     = 'Waluta'
        Role     = 'K'
        Overrides = @{
            'Name'     = @{ Type = 'fuzzy'; Source = 'currency' }
            'EntitiesFile' = @{ Hidden = $true }
            'Owner'    = @{ Hidden = $true }
            'Location' = @{ Hidden = $true }
        }
    }

    @{
        ID       = 'transfer-currency'
        Label    = 'Przelej walutę'
        Description = 'Transfer walutowy między encjami'
        Menu     = 'Waluta'
        Role     = 'K'
        Mode     = 'Workflow'
        WorkflowFunction = 'Invoke-CurrencyTransferWorkflow'
    }

    @{
        ID       = 'move-currency-location'
        Label    = 'Zmień lokalizację'
        Description = 'Przeniesienie waluty do lokacji'
        Function = 'Set-CurrencyEntity'
        Menu     = 'Waluta'
        Role     = 'K'
        Overrides = @{
            'Name'     = @{ Type = 'fuzzy'; Source = 'currency' }
            'Location' = @{ Type = 'fuzzy'; Source = 'locations' }
            'EntitiesFile' = @{ Hidden = $true }
            'Amount'      = @{ Hidden = $true }
            'AmountDelta' = @{ Hidden = $true }
            'Owner'       = @{ Hidden = $true }
        }
    }

    @{
        ID       = 'remove-currency'
        Label    = 'Usuń walutę'
        Description = 'Usunięcie encji walutowej'
        Function = 'Remove-CurrencyEntity'
        Menu     = 'Waluta'
        Role     = 'K'
        Overrides = @{
            'Name' = @{ Type = 'fuzzy'; Source = 'currency' }
            'EntitiesFile' = @{ Hidden = $true }
        }
    }

    @{
        ID       = 'browse-currency'
        Label    = 'Salda walut'
        Description = 'Przegląd sald walutowych'
        Function = 'Get-CurrencyEntity'
        Menu     = 'Waluta'
        Mode     = 'Query'
        Columns  = @('EntityName', 'Denomination', 'Balance', 'Owner')
        Headers  = @('Nazwa', 'Nominał', 'Saldo', 'Właściciel')
        Widths   = @(28, 18, 8, 20)
    }

    @{
        ID       = 'currency-report'
        Label    = 'Raport walutowy'
        Description = 'Zestawienie walut'
        Function = 'Get-CurrencyReport'
        Menu     = 'Waluta'
        Mode     = 'Query'
        Columns  = @('Owner', 'Denomination', 'Balance')
        Headers  = @('Właściciel', 'Nominał', 'Saldo')
        Widths   = @(25, 20, 10)
    }

    @{
        ID       = 'currency-reconciliation'
        Label    = 'Uzgodnienie'
        Description = 'Walidacja spójności walut'
        Menu     = 'Waluta'
        Role     = 'K'
        Mode     = 'Workflow'
        WorkflowFunction = 'Invoke-CurrencyReconciliationDisplay'
    }

    # ─── PU ───────────────────────────────────────────────────────────────────

    @{
        ID       = 'pu-assignment'
        Label    = 'Przydział miesięczny'
        Description = 'Naliczenie PU za okres'
        Function = 'Invoke-PlayerCharacterPUAssignment'
        Menu     = 'PU'
        Role     = 'K'
        Mode     = 'Workflow'
        WorkflowFunction = 'Invoke-PUAssignmentWorkflow'
        PreChecks = @('Nazwy postaci', 'Daty sesji', 'Duplikaty', 'PU nadmiarowe')
        InfoText = @('Sprawdzi nazwy postaci, daty sesji, duplikaty, PU nadmiarowe')
    }

    @{
        ID       = 'pre-pu-diagnostics'
        Label    = 'Diagnostyka przed przydziałem'
        Description = 'Sprawdzenie gotowości do przydziału PU'
        Menu     = 'PU'
        Role     = 'K'
        Mode     = 'Workflow'
        WorkflowFunction = 'Invoke-PrePUDiagnostics'
        PreChecks = @('Walidacja nazw postaci', 'Sprawdzenie dat sesji', 'Spójność PU', 'Raport problemów')
        InfoText = @('Sprawdzi: walidacja nazw, dat sesji, spójność PU, raport problemów')
    }

    @{
        ID       = 'pu-history'
        Label    = 'Historia przydziałów'
        Description = 'Dziennik naliczonych PU'
        Function = 'Get-PUAssignmentLog'
        Menu     = 'PU'
        Mode     = 'Query'
        Columns  = @('ProcessedAt', 'SessionCount', 'Timezone')
        Headers  = @('Przetworzono', 'Sesje', 'Strefa')
        Widths   = @(25, 10, 15)
    }

    @{
        ID       = 'voting-eligibility'
        Label    = 'Uprawnienia głosowania'
        Description = 'Status uprawnień graczy'
        Function = 'Get-VotingEligibility'
        Menu     = 'PU'
        Mode     = 'Query'
        Columns  = @('PlayerName', 'VotingEligible', 'PU')
        Headers  = @('Gracz', 'Uprawniony', 'PU')
        Widths   = @(20, 12, 10)
    }

    @{
        ID       = 'pu-diagnostics'
        Label    = 'Diagnostyka PU'
        Description = 'Szczegółowy raport spójności PU'
        Menu     = 'PU'
        Role     = 'K'
        Mode     = 'Workflow'
        WorkflowFunction = 'Invoke-PUDiagnosticsDisplay'
    }

    # ─── Raporty i Narzędzia ─────────────────────────────────────────────────

    @{
        ID       = 'changelog'
        Label    = 'Log zmian'
        Description = 'Zmiany stanów encji z sesji'
        Function = 'Get-ChangeLog'
        Menu     = 'Raporty i Narzędzia'
        Mode     = 'Query'
        Columns  = @('Date', 'EntityName', 'Property', 'Value')
        Headers  = @('Data', 'Encja', 'Właściwość', 'Wartość')
        Widths   = @(12, 20, 15, 25)
        FilterOverrides = @{
            'MinDate' = @{ Type = 'date'; Label = 'Od daty'; Required = $false }
            'MaxDate' = @{ Type = 'date'; Label = 'Do daty'; Required = $false }
        }
    }

    @{
        ID       = 'narrator-report'
        Label    = 'Raport narratorów'
        Description = 'Statystyki narratorów'
        Function = 'Get-NarratorReport'
        Menu     = 'Raporty i Narzędzia'
        Mode     = 'Query'
        Columns  = @('NormalizedText', 'OccurrenceCount', 'Confidence')
        Headers  = @('Narrator', 'Liczba sesji', 'Pewność')
        Widths   = @(25, 15, 12)
    }

    @{
        ID       = 'location-report'
        Label    = 'Raport lokacji'
        Description = 'Statystyki użycia lokacji'
        Function = 'Get-NamedLocationReport'
        Menu     = 'Raporty i Narzędzia'
        Mode     = 'Query'
        Columns  = @('Name', 'OccurrenceCount', 'EntityMatch')
        Headers  = @('Lokacja', 'Wystąpienia', 'Encja')
        Widths   = @(25, 12, 20)
    }

    @{
        ID       = 'notification-log'
        Label    = 'Powiadomienia'
        Description = 'Dziennik powiadomień'
        Function = 'Get-NotificationLog'
        Menu     = 'Raporty i Narzędzia'
        Mode     = 'Query'
        Columns  = @('Date', 'TargetName', 'Directive', 'RecipientCount')
        Headers  = @('Data', 'Cel', 'Typ', 'Odbiorców')
        Widths   = @(12, 20, 12, 10)
    }

    @{
        ID       = 'transaction-ledger'
        Label    = 'Transakcje'
        Description = 'Księga transakcji walutowych'
        Function = 'Get-TransactionLedger'
        Menu     = 'Raporty i Narzędzia'
        Mode     = 'Query'
        Columns  = @('Date', 'Source', 'Destination', 'Amount', 'Denomination')
        Headers  = @('Data', 'Źródło', 'Cel', 'Kwota', 'Waluta')
        Widths   = @(12, 18, 18, 8, 15)
    }

    @{
        ID       = 'intel-preview'
        Label    = 'Podgląd Intel'
        Description = 'Podgląd routingu informacji'
        Menu     = 'Raporty i Narzędzia'
        Role     = 'N/K'
        Mode     = 'Workflow'
        WorkflowFunction = 'Invoke-IntelPreviewWorkflow'
        InfoText = @('Pokaże: kto otrzyma jakie wiadomości z sesji')
    }

    @{
        ID       = 'discord-pu-notification'
        Label    = 'Discord: Powiadomienie PU'
        Description = 'Ponowne wysłanie powiadomienia PU'
        Function = 'Send-DiscordMessage'
        Menu     = 'Raporty i Narzędzia'
        Role     = 'K'
        Mode     = 'Workflow'
        WorkflowFunction = 'Invoke-DiscordPUNotificationWorkflow'
    }

    @{
        ID       = 'discord-announcement'
        Label    = 'Discord: Ogłoszenie'
        Description = 'Strukturalne ogłoszenie na Discord'
        Function = 'Send-DiscordMessage'
        Menu     = 'Raporty i Narzędzia'
        Role     = 'K'
        Mode     = 'Workflow'
        WorkflowFunction = 'Invoke-DiscordAnnouncementWorkflow'
    }

    @{
        ID       = 'discord-custom'
        Label    = 'Discord: Wiadomość'
        Description = 'Dowolna wiadomość na Discord'
        Function = 'Send-DiscordMessage'
        Menu     = 'Raporty i Narzędzia'
        Role     = 'K'
        Overrides = @{}
    }

    @{
        ID       = 'name-search'
        Label    = 'Szukaj nazwy'
        Description = 'Wyszukiwanie po nazwie (z fuzzy matching)'
        Menu     = 'Raporty i Narzędzia'
        Mode     = 'Workflow'
        WorkflowFunction = 'Invoke-NameSearchWorkflow'
    }

    # ─── Migracja ─────────────────────────────────────────────────────────────
    # (Dynamic entries built by cli-wizard-migration.ps1 at runtime)

    @{
        ID       = 'migration-quick-check'
        Label    = 'Szybka diagnostyka'
        Description = 'Podsumowanie stanu migracji'
        Menu     = 'Migracja'
        Role     = 'K'
        Mode     = 'Workflow'
        WorkflowFunction = 'Invoke-MigrationQuickCheck'
    }

    @{
        ID       = 'migration-full-report'
        Label    = 'Pełny raport'
        Description = 'Szczegółowy raport migracji'
        Menu     = 'Migracja'
        Role     = 'K'
        Mode     = 'Workflow'
        WorkflowFunction = 'Invoke-MigrationFullReport'
    }
)
