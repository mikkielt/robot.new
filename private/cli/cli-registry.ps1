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
        Description = 'Stwórz nową sesję krok po kroku'
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
        InfoText = @('Kreator prowadzi krok po kroku: data, narrator, lokacje, PU, zmiany, powiadomienia.')
    }

    @{
        ID       = 'edit-session'
        Label    = 'Edytuj sesję'
        Description = 'Zmień dane istniejącej sesji'
        Function = 'Set-Session'
        Menu     = 'Sesje'
        Role     = 'N'
        Mode     = 'Workflow'
        WorkflowFunction = 'Invoke-EditSessionWorkflow'
        InfoText = @('Pozwala zmienić datę, narratora, lokacje i inne dane sesji.')
    }

    @{
        ID       = 'validate-session'
        Label    = 'Walidacja sesji'
        Description = 'Sprawdź poprawność nazw i dat w sesji'
        Menu     = 'Sesje'
        Role     = 'N'
        Mode     = 'Workflow'
        WorkflowFunction = 'Invoke-SessionValidation'
        PreChecks = @('Czy daty są w poprawnym formacie', 'Czy nazwy postaci w sekcji PU są rozpoznawalne', 'Czy nazwy elementów w sekcji Zmian są rozpoznawalne', 'Czy podane lokacje istnieją')
        InfoText = @('Sprawdzi: czy daty są poprawne, czy nazwy postaci i elementów świata są rozpoznawalne.')
    }

    @{
        ID       = 'browse-sessions'
        Label    = 'Przeglądaj sesje'
        Description = 'Przeglądaj listę sesji'
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
        InfoText = @('Możesz filtrować po dacie. Wybierz wiersz, aby zobaczyć szczegóły.')
    }

    @{
        ID       = 'git-changelog'
        Label    = 'Historia zmian (git)'
        Description = 'Historia zmian w repozytorium'
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
        InfoText = @('Pokazuje historię zapisów w repozytorium z datami i autorami.')
    }

    # ─── Gracze i Postacie ────────────────────────────────────────────────────

    @{
        ID       = 'new-player'
        Label    = 'Nowy gracz'
        Description = 'Dodaj nowego gracza do kampanii'
        Function = 'New-Player'
        Menu     = 'Gracze i Postacie'
        Role     = 'K'
        Mode     = 'Workflow'
        WorkflowFunction = 'Invoke-NewPlayerWorkflow'
        Overrides = @{
            'Triggers' = @{ Type = 'multitext'; Label = 'Triggery (po jednym)' }
            'EntitiesFile' = @{ Hidden = $true }
        }
        InfoText = @('Kreator poprosi o nazwę gracza i wyzwalacze powiadomień.')
    }

    @{
        ID       = 'new-character'
        Label    = 'Nowa postać'
        Description = 'Stwórz postać (opcjonalnie z walutą)'
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
        InfoText = @('Kreator poprosi o gracza, nazwę postaci i opcjonalnie walutę startową.')
    }

    @{
        ID       = 'edit-character'
        Label    = 'Edytuj postać'
        Description = 'Zmień dane istniejącej postaci'
        Function = 'Set-PlayerCharacter'
        Menu     = 'Gracze i Postacie'
        Role     = 'K'
        Mode     = 'Workflow'
        WorkflowFunction = 'Invoke-EditCharacterWorkflow'
        InfoText = @('Wybierz postać, a potem zmień jej dane.')
    }

    @{
        ID       = 'edit-player'
        Label    = 'Edytuj gracza'
        Description = 'Zmień dane gracza'
        Function = 'Set-Player'
        Menu     = 'Gracze i Postacie'
        Role     = 'K'
        Overrides = @{
            'Name'     = @{ Type = 'fuzzy'; Source = 'players' }
            'Triggers' = @{ Type = 'multitext'; Label = 'Triggery (po jednym)' }
            'Aliases'  = @{ Type = 'multitext'; Label = 'Aliasy (po jednym)' }
            'EntitiesFile' = @{ Hidden = $true }
        }
        InfoText = @('Zmień wyzwalacze powiadomień lub alternatywne nazwy gracza.')
    }

    @{
        ID       = 'remove-character'
        Label    = 'Usuń postać'
        Description = 'Oznacz postać jako nieaktywną'
        Function = 'Remove-PlayerCharacter'
        Menu     = 'Gracze i Postacie'
        Role     = 'K'
        Overrides = @{
            'PlayerName'    = @{ Type = 'fuzzy'; Source = 'players' }
            'CharacterName' = @{ Type = 'fuzzy'; Source = 'characters' }
            'EntitiesFile'  = @{ Hidden = $true }
        }
        InfoText = @('Postać zostanie oznaczona jako nieaktywna. Dane nie zostaną usunięte.')
    }

    @{
        ID       = 'browse-players'
        Label    = 'Przeglądaj graczy'
        Description = 'Przeglądaj graczy i ich postacie'
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
        InfoText = @('Wybierz gracza z listy, aby zobaczyć jego postacie.')
    }

    @{
        ID       = 'character-card'
        Label    = 'Karta postaci'
        Description = 'Wyświetl kartę postaci'
        Menu     = 'Gracze i Postacie'
        Mode     = 'Workflow'
        WorkflowFunction = 'Invoke-CharacterCardWorkflow'
        InfoText = @('Wyświetla wszystkie informacje o postaci w jednym widoku.')
    }

    # ─── Encje ────────────────────────────────────────────────────────────────

    @{
        ID       = 'new-entity'
        Label    = 'Nowa encja'
        Description = 'Stwórz NPC, lokację, grupę lub przedmiot'
        Function = 'New-Entity'
        Menu     = 'Encje'
        Role     = 'K'
        Mode     = 'Workflow'
        WorkflowFunction = 'Invoke-NewEntityWorkflow'
        InfoText = @('Wybierz typ (NPC, Lokacja, Grupa, Przedmiot), podaj nazwę i dodaj właściwości.')
    }

    @{
        ID       = 'edit-entity'
        Label    = 'Edytuj encję'
        Description = 'Zmień właściwości elementu świata gry'
        Function = 'Set-Entity'
        Menu     = 'Encje'
        Role     = 'K'
        Mode     = 'Workflow'
        WorkflowFunction = 'Invoke-EditEntityWorkflow'
        InfoText = @('Wybierz element, a potem zmień jego właściwości.')
    }

    @{
        ID       = 'remove-entity'
        Label    = 'Usuń encję'
        Description = 'Oznacz element jako nieaktywny'
        Function = 'Remove-Entity'
        Menu     = 'Encje'
        Role     = 'K'
        Overrides = @{
            'Name' = @{ Type = 'fuzzy'; Source = 'entities' }
            'EntitiesFile' = @{ Hidden = $true }
        }
        InfoText = @('Element zostanie oznaczony jako nieaktywny. Dane nie zostaną usunięte.')
    }

    @{
        ID       = 'browse-entities'
        Label    = 'Przeglądaj encje'
        Description = 'Przeglądaj elementy świata gry'
        Function = 'Get-Entity'
        Menu     = 'Encje'
        Mode     = 'Query'
        Columns  = @('Name', 'Type', 'Status')
        Headers  = @('Nazwa', 'Typ', 'Status')
        Widths   = @(30, 15, 12)
        DetailFunction = 'Show-EntityCard'
        InfoText = @('Wybierz element z listy, aby zobaczyć jego kartę z pełnymi informacjami.')
    }

    @{
        ID       = 'entity-history'
        Label    = 'Historia encji'
        Description = 'Historia zmian elementu z sesji'
        Function = 'Get-EntityHistory'
        Menu     = 'Encje'
        Mode     = 'Workflow'
        WorkflowFunction = 'Invoke-EntityHistoryWorkflow'
        InfoText = @('Pokazuje, jak element zmieniał się w kolejnych sesjach.')
    }

    @{
        ID       = 'search-entity'
        Label    = 'Szukaj'
        Description = 'Szukaj elementu po nazwie'
        Menu     = 'Encje'
        Mode     = 'Workflow'
        WorkflowFunction = 'Invoke-EntitySearchWorkflow'
        InfoText = @('Wpisz początek nazwy — nie musisz znać dokładnej pisowni.')
    }

    # ─── Waluta ───────────────────────────────────────────────────────────────

    @{
        ID       = 'new-currency'
        Label    = 'Nowa waluta'
        Description = 'Utwórz nowy zapis walutowy'
        Function = 'New-CurrencyEntity'
        Menu     = 'Waluta'
        Role     = 'K'
        Overrides = @{
            'Denomination' = @{ Type = 'selection'; Options = @('Korony Elanckie', 'Talary Hirońskie', 'Kogi Skeltvorskie') }
            'Owner'        = @{ Type = 'fuzzy'; Source = 'entities' }
            'EntitiesFile' = @{ Hidden = $true }
        }
        InfoText = @('Utwórz zapis walutowy, np. sakiewkę postaci, z wybranym nominałem.')
    }

    @{
        ID       = 'set-currency-balance'
        Label    = 'Zmień saldo'
        Description = 'Zmień ilość waluty'
        Function = 'Set-CurrencyEntity'
        Menu     = 'Waluta'
        Role     = 'K'
        Overrides = @{
            'Name'     = @{ Type = 'fuzzy'; Source = 'currency' }
            'EntitiesFile' = @{ Hidden = $true }
            'Owner'    = @{ Hidden = $true }
            'Location' = @{ Hidden = $true }
        }
        InfoText = @('Zmień ilość waluty bezpośrednio (np. po znalezieniu skarbu).')
    }

    @{
        ID       = 'transfer-currency'
        Label    = 'Przelej walutę'
        Description = 'Przenieś walutę między właścicielami'
        Menu     = 'Waluta'
        Role     = 'K'
        Mode     = 'Workflow'
        WorkflowFunction = 'Invoke-CurrencyTransferWorkflow'
        InfoText = @('Przenieś walutę z jednego właściciela do drugiego.')
    }

    @{
        ID       = 'move-currency-location'
        Label    = 'Zmień lokalizację'
        Description = 'Przenieś walutę do innego miejsca'
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
        InfoText = @('Zmień miejsce przechowywania waluty (np. z sakiewki do skarbca).')
    }

    @{
        ID       = 'remove-currency'
        Label    = 'Usuń walutę'
        Description = 'Usuń zapis walutowy'
        Function = 'Remove-CurrencyEntity'
        Menu     = 'Waluta'
        Role     = 'K'
        Overrides = @{
            'Name' = @{ Type = 'fuzzy'; Source = 'currency' }
            'EntitiesFile' = @{ Hidden = $true }
        }
        InfoText = @('Trwale usuwa zapis walutowy.')
    }

    @{
        ID       = 'browse-currency'
        Label    = 'Salda walut'
        Description = 'Przegląd aktualnych stanów walut'
        Function = 'Get-CurrencyEntity'
        Menu     = 'Waluta'
        Mode     = 'Query'
        Columns  = @('EntityName', 'Denomination', 'Balance', 'Owner')
        Headers  = @('Nazwa', 'Nominał', 'Saldo', 'Właściciel')
        Widths   = @(28, 18, 8, 20)
        InfoText = @('Lista wszystkich walut z aktualnymi saldami.')
    }

    @{
        ID       = 'currency-report'
        Label    = 'Raport walutowy'
        Description = 'Zestawienie walut wg właściciela'
        Function = 'Get-CurrencyReport'
        Menu     = 'Waluta'
        Mode     = 'Query'
        Columns  = @('Owner', 'Denomination', 'Balance')
        Headers  = @('Właściciel', 'Nominał', 'Saldo')
        Widths   = @(25, 20, 10)
        InfoText = @('Zestawienie walut pogrupowane według właścicieli.')
    }

    @{
        ID       = 'currency-reconciliation'
        Label    = 'Uzgodnienie'
        Description = 'Sprawdź poprawność walut'
        Menu     = 'Waluta'
        Role     = 'K'
        Mode     = 'Workflow'
        WorkflowFunction = 'Invoke-CurrencyReconciliationDisplay'
        InfoText = @('Sprawdza, czy salda walut zgadzają się z historią transakcji.')
    }

    # ─── PU ───────────────────────────────────────────────────────────────────

    @{
        ID       = 'pu-assignment'
        Label    = 'Przydział miesięczny'
        Description = 'Nalicz PU za wybrany miesiąc'
        Function = 'Invoke-PlayerCharacterPUAssignment'
        Menu     = 'PU'
        Role     = 'K'
        Mode     = 'Workflow'
        WorkflowFunction = 'Invoke-PUAssignmentWorkflow'
        PreChecks = @('Czy nazwy postaci są rozpoznawalne', 'Czy daty sesji są poprawne', 'Czy nie ma zduplikowanych wpisów', 'Czy nadmiarowe PU się zgadzają')
        InfoText = @('Najpierw podgląd (nic nie zostanie zapisane), potem zatwierdzenie.')
    }

    @{
        ID       = 'pre-pu-diagnostics'
        Label    = 'Diagnostyka przed przydziałem'
        Description = 'Sprawdź gotowość do przydziału PU'
        Menu     = 'PU'
        Role     = 'K'
        Mode     = 'Workflow'
        WorkflowFunction = 'Invoke-PrePUDiagnostics'
        PreChecks = @('Czy nazwy postaci są rozpoznawalne', 'Czy daty sesji są poprawne', 'Czy PU są poprawne i spójne', 'Raport ewentualnych problemów')
        InfoText = @('Sprawdzi: nazwy postaci, daty sesji, poprawność PU. Pokaże raport problemów.')
    }

    @{
        ID       = 'pu-history'
        Label    = 'Historia przydziałów'
        Description = 'Dziennik dotychczasowych przydziałów'
        Function = 'Get-PUAssignmentLog'
        Menu     = 'PU'
        Mode     = 'Query'
        Columns  = @('ProcessedAt', 'SessionCount', 'Timezone')
        Headers  = @('Przetworzono', 'Sesje', 'Strefa')
        Widths   = @(25, 10, 15)
        InfoText = @('Lista dotychczasowych przydziałów z datami i liczbą sesji.')
    }

    @{
        ID       = 'voting-eligibility'
        Label    = 'Uprawnienia głosowania'
        Description = 'Kto może głosować'
        Function = 'Get-VotingEligibility'
        Menu     = 'PU'
        Mode     = 'Query'
        Columns  = @('PlayerName', 'VotingEligible', 'PU')
        Headers  = @('Gracz', 'Uprawniony', 'PU')
        Widths   = @(20, 12, 10)
        InfoText = @('Pokazuje, którzy gracze spełniają warunki do głosowania.')
    }

    @{
        ID       = 'pu-diagnostics'
        Label    = 'Diagnostyka PU'
        Description = 'Szczegółowy raport poprawności PU'
        Menu     = 'PU'
        Role     = 'K'
        Mode     = 'Workflow'
        WorkflowFunction = 'Invoke-PUDiagnosticsDisplay'
        InfoText = @('Szczegółowy raport: nierozpoznane nazwy, duplikaty, niespójności.')
    }

    # ─── Raporty i Narzędzia ─────────────────────────────────────────────────

    @{
        ID       = 'changelog'
        Label    = 'Log zmian'
        Description = 'Zmiany w świecie gry z sesji'
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
        InfoText = @('Pokazuje zmiany właściwości elementów świata gry z kolejnych sesji.')
    }

    @{
        ID       = 'narrator-report'
        Label    = 'Raport narratorów'
        Description = 'Statystyki prowadzących sesje'
        Function = 'Get-NarratorReport'
        Menu     = 'Raporty i Narzędzia'
        Mode     = 'Query'
        Columns  = @('NormalizedText', 'OccurrenceCount', 'Confidence')
        Headers  = @('Narrator', 'Liczba sesji', 'Pewność')
        Widths   = @(25, 15, 12)
        InfoText = @('Ile sesji poprowadził każdy narrator.')
    }

    @{
        ID       = 'location-report'
        Label    = 'Raport lokacji'
        Description = 'Jak często używano poszczególnych lokacji'
        Function = 'Get-NamedLocationReport'
        Menu     = 'Raporty i Narzędzia'
        Mode     = 'Query'
        Columns  = @('Name', 'OccurrenceCount', 'EntityMatch')
        Headers  = @('Lokacja', 'Wystąpienia', 'Encja')
        Widths   = @(25, 12, 20)
        InfoText = @('Ile razy każda lokacja pojawiła się w sesjach.')
        DataTransform = { param($R) $R.Locations }
    }

    @{
        ID               = 'location-graph'
        Label            = 'Graf lokacji'
        Description      = 'Unified graf relacji między lokacjami'
        Menu             = 'Raporty i Narzędzia'
        Mode             = 'Workflow'
        WorkflowFunction = 'Invoke-LocationGraphWorkflow'
        InfoText         = @('Buduje graf lokacji z encji, tras sesyjnych i logów.')
    }

    @{
        ID       = 'notification-log'
        Label    = 'Powiadomienia'
        Description = 'Dziennik wysłanych powiadomień'
        Function = 'Get-NotificationLog'
        Menu     = 'Raporty i Narzędzia'
        Mode     = 'Query'
        Columns  = @('Date', 'TargetName', 'Directive', 'RecipientCount')
        Headers  = @('Data', 'Cel', 'Typ', 'Odbiorców')
        Widths   = @(12, 20, 12, 10)
        InfoText = @('Historia wysłanych powiadomień z datami i odbiorcami.')
    }

    @{
        ID       = 'transaction-ledger'
        Label    = 'Transakcje'
        Description = 'Księga przelewów walutowych'
        Function = 'Get-TransactionLedger'
        Menu     = 'Raporty i Narzędzia'
        Mode     = 'Query'
        Columns  = @('Date', 'Source', 'Destination', 'Amount', 'Denomination')
        Headers  = @('Data', 'Źródło', 'Cel', 'Kwota', 'Waluta')
        Widths   = @(12, 18, 18, 8, 15)
        InfoText = @('Pełna lista przelewów walutowych z kwotami i stronami.')
    }

    @{
        ID       = 'intel-preview'
        Label    = 'Podgląd Intel'
        Description = 'Kto otrzyma wiadomości z sesji'
        Menu     = 'Raporty i Narzędzia'
        Role     = 'N/K'
        Mode     = 'Workflow'
        WorkflowFunction = 'Invoke-IntelPreviewWorkflow'
        InfoText = @('Pokaże, kto otrzyma jakie wiadomości na podstawie wybranej sesji.')
    }

    @{
        ID       = 'discord-pu-notification'
        Label    = 'Discord: Powiadomienie PU'
        Description = 'Wyślij ponownie powiadomienie PU'
        Function = 'Send-DiscordMessage'
        Menu     = 'Raporty i Narzędzia'
        Role     = 'K'
        Mode     = 'Workflow'
        WorkflowFunction = 'Invoke-DiscordPUNotificationWorkflow'
        InfoText = @('Ponownie wysyła powiadomienie PU na Discord (np. po awarii).')
    }

    @{
        ID       = 'discord-announcement'
        Label    = 'Discord: Ogłoszenie'
        Description = 'Opublikuj ogłoszenie na Discordzie'
        Function = 'Send-DiscordMessage'
        Menu     = 'Raporty i Narzędzia'
        Role     = 'K'
        Mode     = 'Workflow'
        WorkflowFunction = 'Invoke-DiscordAnnouncementWorkflow'
        InfoText = @('Opublikuj sformatowane ogłoszenie na kanale Discord.')
    }

    @{
        ID       = 'discord-custom'
        Label    = 'Discord: Wiadomość'
        Description = 'Wyślij dowolną wiadomość na Discord'
        Function = 'Send-DiscordMessage'
        Menu     = 'Raporty i Narzędzia'
        Role     = 'K'
        Overrides = @{}
        InfoText = @('Wyślij dowolną wiadomość na wybrany kanał Discord.')
    }

    @{
        ID       = 'name-search'
        Label    = 'Szukaj nazwy'
        Description = 'Wyszukaj po nazwie (przybliżone)'
        Menu     = 'Raporty i Narzędzia'
        Mode     = 'Workflow'
        WorkflowFunction = 'Invoke-NameSearchWorkflow'
        InfoText = @('Wyszukaj dowolny element świata gry po nazwie — przybliżone dopasowanie.')
    }

    # ─── Logi ────────────────────────────────────────────────────────────────

    @{
        ID       = 'fetch-logs'
        Label    = 'Pobierz logi sesji'
        Description = 'Pobierz zapisy rozmów z sesji'
        Menu     = 'Raporty i Narzędzia'
        Role     = 'K'
        Mode     = 'Workflow'
        WorkflowFunction = 'Invoke-FetchLogsWorkflow'
        PreChecks = @('Wymaga połączenia z internetem', 'Pobieranie odbywa się z przerwą między zapytaniami')
        InfoText = @('Pobiera zapisy rozmów z adresów URL podanych w sesjach. Wymaga internetu.')
    }

    @{
        ID       = 'log-location-report'
        Label    = 'Raport lokacji z logów'
        Description = 'Porównaj lokacje w logach z elementami gry'
        Menu     = 'Raporty i Narzędzia'
        Role     = 'N'
        Mode     = 'Workflow'
        WorkflowFunction = 'Invoke-LogLocationReportWorkflow'
        InfoText = @('Porównuje lokacje z zapisów rozmów z lokacjami zarejestrowanymi w świecie gry.')
    }

    # ─── Migracja ─────────────────────────────────────────────────────────────
    # (Dynamic entries built by cli-wizard-migration.ps1 at runtime)

    @{
        ID       = 'migration-quick-check'
        Label    = 'Szybka diagnostyka'
        Description = 'Ile zostało do zrobienia'
        Menu     = 'Migracja'
        Role     = 'K'
        Mode     = 'Workflow'
        WorkflowFunction = 'Invoke-MigrationQuickCheck'
        InfoText = @('Szybki podgląd: które fazy migracji zostały ukończone.')
    }

    @{
        ID       = 'migration-full-report'
        Label    = 'Pełny raport'
        Description = 'Szczegółowy raport postępu'
        Menu     = 'Migracja'
        Role     = 'K'
        Mode     = 'Workflow'
        WorkflowFunction = 'Invoke-MigrationFullReport'
        InfoText = @('Pełny raport z wynikami każdej fazy migracji.')
    }
)
