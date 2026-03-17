<#
    .SYNOPSIS
    Menu registry - single-source-of-truth definition of all CLI menu items.

    .DESCRIPTION
    This file defines $script:MenuOrder (top-level category list) and
    $script:MenuRegistry (flat array of menu item hashtables). It is pure
    data with zero logic - consumed by the routing layer (cli-routing.ps1).

    Adding a new feature = adding one hashtable to $script:MenuRegistry.

    Module-level data:
    - $script:MenuOrder:              ordered list of top-level menu category names
    - $script:MenuRegistry:           flat array of menu item definitions
    - $script:MenuRegistryByID:       O(1) lookup dictionary keyed by entry ID
    - $script:MenuRegistryByCategory: O(1) lookup dictionary keyed by category name, values are List[hashtable]

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
    - ColumnPriority:   int[] for responsive column hiding (1=always, 2=medium, 3=hide first)
    - FilterPrefixes:   hashtable mapping prefix names to column names (e.g. @{ 'typ' = 'Type' })
    - HelpBrief:        short 1-line help shown in wizard steps and search results
    - HelpFull:         string[] multi-line help content for /h overlay
    - PreChecks:        string array of pre-check descriptions
    - InfoText:         info text shown when item is selected
#>

# ── Menu Category Order ──────────────────────────────────────────────────────

$script:MenuOrder = @(
    'Sesje'
    'Gracze i Postacie'
    'Encje'
    'Waluta'
    'Przedmioty'
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
        HelpBrief = 'Kreator sesji: data, narrator, lokacje, PU, zmiany.'
        HelpFull = @(
            'Kreator nowej sesji prowadzi krok po kroku:'
            '  1. Data sesji (i opcjonalnie data końcowa)'
            '  2. Narrator — wyszukiwanie przybliżone po graczach'
            '  3. Lokacje — wielokrotne dodawanie z przybliżonym wyszukiwaniem'
            '  4. PU — przypisanie punktów umiejętności postaciom'
            '  5. Zmiany — modyfikacje encji (tagi @lokacja, @grupa itp.)'
            '  6. Intel — wiadomości kierowane do graczy/grup/lokacji'
            '  7. Logi — URL-e do logów sesji'
            ''
            'Na końcu podgląd zmian z potwierdzeniem.'
            'Format nagłówka: ### RRRR-MM-DD, Tytuł, Narrator'
        )
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
        HelpBrief = 'Edycja istniejącej sesji: data, narrator, lokacje.'
        HelpFull = @(
            'Pozwala zmienić dowolne dane istniejącej sesji:'
            '  - Data, narrator, lokacje'
            '  - Pominięte pola pozostają bez zmian'
            '  - Podgląd diff przed zapisem'
        )
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
        HelpBrief = 'Sprawdza nazwy postaci i encji w sesjach.'
        HelpFull = @(
            'Walidacja sesji sprawdza:'
            '  - Czy daty są w poprawnym formacie'
            '  - Czy nazwy postaci w sekcji PU istnieją w rejestrze'
            '  - Czy nazwy elementów w sekcji Zmian są rozpoznawalne'
            '  - Czy podane lokacje istnieją jako encje'
            ''
            'Możesz ograniczyć zakres dat (od/do).'
            'Problemy wyświetlane są z sugestiami poprawnych nazw.'
        )
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
        ColumnPriority = @(1, 1, 2)
        FilterPrefixes = @{ 'narrator' = 'NarratorName' }
        ColumnResolvers = @{
            'NarratorName' = { param($R) if ($R.Narrator) { $R.Narrator.RawText } else { '' } }
        }
        FilterOverrides = @{
            'MinDate' = @{ Type = 'date'; Label = 'Od daty'; Required = $false }
            'MaxDate' = @{ Type = 'date'; Label = 'Do daty'; Required = $false }
        }
        HelpBrief = 'Lista sesji z datami i narratorami.'
        HelpFull = @(
            'Przeglądaj wszystkie sesje w tabeli.'
            'Filtrowanie: wpisz tekst aby szukać w tytule'
            '  narrator:imię — filtruj po narratorze'
            'Wybierz wiersz Enter aby zobaczyć szczegóły.'
        )
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
        ColumnPriority = @(1, 2, 3)
        ColumnResolvers = @{
            'FileCount' = { param($R) if ($R.Files) { [string]$R.Files.Count } else { '0' } }
        }
        FilterOverrides = @{
            'MinDate' = @{ Type = 'text'; Label = 'Od daty (RRRR-MM-DD)'; Required = $false }
            'MaxDate' = @{ Type = 'text'; Label = 'Do daty (RRRR-MM-DD)'; Required = $false }
        }
        HelpBrief = 'Historia commitów git z datami i autorami.'
        HelpFull = @(
            'Pokazuje historię zmian (git commits) w repozytorium.'
            'Kolumny: data commitu, autor, liczba zmienionych plików.'
            'Wybierz wiersz Enter aby zobaczyć szczegóły commitu.'
        )
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
        HelpBrief = 'Dodaje gracza z opcjonalnym tworzeniem pierwszej postaci.'
        HelpFull = @(
            'Kreator nowego gracza:'
            '  1. Nazwa gracza'
            '  2. Triggery powiadomień (opcjonalne)'
            '  3. Opcja dodania pierwszej postaci od razu'
            ''
            'Po utworzeniu gracza możesz kontynuować z postacią.'
        )
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
        HelpBrief = 'Tworzy postać z opcjonalną walutą startową.'
        HelpFull = @(
            'Kreator nowej postaci:'
            '  1. Gracz (wyszukiwanie przybliżone)'
            '  2. Nazwa postaci, przedmioty specjalne'
            '  3. Opcja dodania walut startowych'
            ''
            'Automatycznie tworzy plik postaci i wpis w entities.md.'
        )
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
        HelpBrief = 'Zmiana danych istniejącej postaci z podglądem diff.'
        HelpFull = @(
            'Edycja postaci:'
            '  1. Wybierz gracza i postać'
            '  2. Zmień dowolne pola (puste = bez zmian)'
            '  3. Podgląd różnic przed zapisem'
        )
        InfoText = @('Wybierz postać, a potem zmień jej dane.')
    }

    @{
        ID       = 'edit-player'
        Label    = 'Edytuj gracza'
        Description = 'Zmień dane gracza'
        Function = 'Set-Player'
        Menu     = 'Gracze i Postacie'
        Role     = 'K'
        HelpBrief = 'Zmiana triggerów, aliasów i danych gracza.'
        HelpFull = @(
            'Zmiana danych gracza:'
            '  - Triggery powiadomień'
            '  - Aliasy (alternatywne nazwy)'
            '  - Inne właściwości'
        )
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
        HelpBrief = 'Dezaktywacja postaci (soft delete).'
        HelpFull = @(
            'Oznacza postać jako nieaktywną.'
            'Dane nie są usuwane — postać jest zachowana w rejestrze.'
            'Operacja jest odwracalna przez ponowną edycję.'
        )
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
        ColumnPriority = @(1, 2, 2)
        FilterPrefixes = @{ 'postac' = 'ActiveCharacter'; 'character' = 'ActiveCharacter' }
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
        HelpBrief = 'Lista graczy z liczbą postaci.'
        HelpFull = @(
            'Tabela graczy kampanii.'
            'Filtrowanie: wpisz tekst aby szukać po nazwie'
            '  postac:imię — filtruj po aktywnej postaci'
            'Wybierz wiersz Enter aby zobaczyć kartę gracza.'
        )
        InfoText = @('Wybierz gracza z listy, aby zobaczyć jego postacie.')
    }

    @{
        ID       = 'character-card'
        Label    = 'Karta postaci'
        Description = 'Wyświetl kartę postaci'
        Menu     = 'Gracze i Postacie'
        Mode     = 'Workflow'
        WorkflowFunction = 'Invoke-CharacterCardWorkflow'
        HelpBrief = 'Wyświetla pełną kartę postaci z PU i aliasami.'
        HelpFull = @(
            'Karta postaci zawiera:'
            '  - Status aktywności, typ gracza'
            '  - Punkty Umiejętności (suma, zdobyte, startowe)'
            '  - Aliasy i dodatkowe informacje'
        )
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
        HelpBrief = 'Kreator encji z wyborem typu i tagów.'
        HelpFull = @(
            'Kreator nowej encji:'
            '  1. Typ: NPC, Grupa, Lokacja lub Przedmiot'
            '  2. Nazwa encji'
            '  3. Tagi: @lokacja, @grupa, @status, @alias itp.'
            '  4. Podgląd i potwierdzenie'
            ''
            'Tagi @lokacja i @grupa używają wyszukiwania przybliżonego.'
        )
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
        HelpBrief = 'Dodaj lub zmień tagi istniejącej encji.'
        HelpFull = @(
            'Edycja encji:'
            '  1. Wyszukaj encję (przybliżone)'
            '  2. Dodaj/zmień tagi w pętli'
            '  3. Podgląd diff przed zapisem'
            ''
            'Istniejące tagi wyświetlane jako kontekst.'
        )
        InfoText = @('Wybierz element, a potem zmień jego właściwości.')
    }

    @{
        ID       = 'remove-entity'
        Label    = 'Usuń encję'
        Description = 'Oznacz element jako nieaktywny'
        Function = 'Remove-Entity'
        Menu     = 'Encje'
        Role     = 'K'
        HelpBrief = 'Soft delete: ustawia @status: Usunięty.'
        HelpFull = @(
            'Oznacza element jako nieaktywny (@status: Usunięty).'
            'Dane nie są fizycznie usuwane z entities.md.'
            'Operacja jest odwracalna przez edycję encji.'
        )
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
        ColumnPriority = @(1, 1, 2)
        FilterPrefixes = @{ 'typ' = 'Type'; 'type' = 'Type'; 'status' = 'Status' }
        DetailFunction = 'Show-EntityCard'
        HelpBrief = 'Lista encji świata gry.'
        HelpFull = @(
            'Tabela wszystkich encji (NPC, lokacje, grupy, przedmioty).'
            'Filtrowanie: wpisz tekst aby szukać po nazwie'
            '  typ:NPC — filtruj po typie'
            '  status:Aktywny — filtruj po statusie'
            'Wybierz wiersz Enter aby zobaczyć kartę encji.'
        )
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
        HelpBrief = 'Oś czasu zmian encji z kolejnych sesji.'
        HelpFull = @(
            'Pokazuje historię zmian wybranej encji:'
            '  - Data, właściwość, nowa wartość, źródło'
            '  - Dane z sekcji Zmian w sesjach'
        )
        InfoText = @('Pokazuje, jak element zmieniał się w kolejnych sesjach.')
    }

    @{
        ID       = 'search-entity'
        Label    = 'Szukaj'
        Description = 'Szukaj elementu po nazwie'
        Menu     = 'Encje'
        Mode     = 'Workflow'
        WorkflowFunction = 'Invoke-EntitySearchWorkflow'
        HelpBrief = 'Przybliżone wyszukiwanie encji z kartą szczegółów.'
        HelpFull = @(
            'Wyszukiwanie przybliżone (fuzzy) po nazwach encji.'
            'Obsługuje odmianę (deklinację) i literówki.'
            'Po wybraniu wyświetla pełną kartę encji.'
        )
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
        HelpBrief = 'Tworzy zapis walutowy z wybranym nominałem.'
        HelpFull = @(
            'Utwórz nowy zapis walutowy (sakiewkę):'
            '  1. Nominał: Korony Elanckie, Talary Hirońskie, Kogi Skeltvorskie'
            '  2. Właściciel (wyszukiwanie przybliżone)'
            '  3. Ilość początkowa'
        )
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
        HelpBrief = 'Zmiana salda waluty (bezwzględna lub delta).'
        HelpFull = @(
            'Zmień ilość waluty:'
            '  - Amount: ustaw nową wartość bezwzględną'
            '  - AmountDelta: dodaj/odejmij od obecnego salda'
        )
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
        HelpBrief = 'Transfer waluty: źródło → kwota → cel.'
        HelpFull = @(
            'Kreator transferu walutowego:'
            '  1. Waluta źródłowa (obciążenie)'
            '  2. Kwota do przelania'
            '  3. Waluta docelowa (zasilenie)'
            '  4. Podgląd i potwierdzenie'
            ''
            'Obie strony muszą mieć ten sam nominał.'
        )
        InfoText = @('Przenieś walutę z jednego właściciela do drugiego.')
    }

    @{
        ID       = 'move-currency-location'
        Label    = 'Zmień lokalizację'
        Description = 'Przenieś walutę do innego miejsca'
        Function = 'Set-CurrencyEntity'
        Menu     = 'Waluta'
        Role     = 'K'
        HelpBrief = 'Zmiana lokalizacji przechowywania waluty.'
        HelpFull = @(
            'Przenieś walutę do innego miejsca:'
            '  - Np. z sakiewki do skarbca'
            '  - Tylko zmiana lokalizacji, saldo bez zmian'
        )
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
        HelpBrief = 'Trwałe usunięcie zapisu walutowego.'
        HelpFull = @(
            'Trwale usuwa zapis walutowy z entities.md.'
            'UWAGA: ta operacja jest nieodwracalna.'
            'Nie dotyczy walut z @Transfer w sesjach.'
        )
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
        ColumnPriority = @(1, 2, 1, 3)
        FilterPrefixes = @{ 'nominal' = 'Denomination'; 'denomination' = 'Denomination'; 'wlasciciel' = 'Owner'; 'owner' = 'Owner' }
        HelpBrief = 'Lista walut z saldami i właścicielami.'
        HelpFull = @(
            'Tabela wszystkich zapisów walutowych.'
            'Filtrowanie: wpisz tekst aby szukać po nazwie'
            '  nominal:Korony — filtruj po nominale'
            '  wlasciciel:imię — filtruj po właścicielu'
            'Wybierz wiersz Enter aby zobaczyć szczegóły.'
        )
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
        ColumnPriority = @(1, 2, 1)
        HelpBrief = 'Zestawienie walut pogrupowane wg właścicieli.'
        HelpFull = @(
            'Raport walutowy pogrupowany wg właścicieli.'
            'Każdy wiersz = jeden nominał jednego właściciela.'
        )
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
        HelpBrief = 'Weryfikacja spójności sald walutowych.'
        HelpFull = @(
            'Sprawdza spójność walut:'
            '  - Czy salda zgadzają się z historią transakcji'
            '  - Podaż walut wg nominałów'
            '  - Ostrzeżenia o anomaliach'
        )
        InfoText = @('Sprawdza, czy salda walut zgadzają się z historią transakcji.')
    }

    @{
        ID       = 'economic-snapshot'
        Label    = 'Obraz gospodarki'
        Description = 'Analiza podaży i dystrybucji walut'
        Menu     = 'Waluta'
        Role     = 'K'
        Mode     = 'Workflow'
        WorkflowFunction = 'Invoke-EconomicSnapshotWorkflow'
        HelpBrief = 'Podaż fizyczna/wirtualna, Gini, top holders.'
        HelpFull = @(
            'Obraz gospodarki:'
            '  - Podaż wg nominałów (fizyczna vs wirtualna)'
            '  - Współczynnik Gini (nierówność majątkowa)'
            '  - Ranking najbogatszych właścicieli'
            '  - Wolumen transakcji'
        )
        InfoText = @('Punkt-w-czasie analiza ekonomiczna świata gry.')
    }

    @{
        ID       = 'economic-timeline'
        Label    = 'Oś czasu gospodarki'
        Description = 'Trendy gospodarcze w czasie'
        Menu     = 'Waluta'
        Role     = 'K'
        Mode     = 'Workflow'
        WorkflowFunction = 'Invoke-EconomicTimelineWorkflow'
        HelpBrief = 'Miesięczne trendy podaży i transakcji.'
        HelpFull = @(
            'Oś czasu gospodarki:'
            '  - Miesięczna podaż (fizyczna/wirtualna)'
            '  - Liczba transferów w miesiącu'
            '  - Zakres dat: od-do'
        )
        InfoText = @('Analiza trendów gospodarczych w wybranym zakresie dat.')
    }

    @{
        ID       = 'materialization-report'
        Label    = 'Raport materializacji'
        Description = 'Fizyczna vs wirtualna waluta'
        Menu     = 'Waluta'
        Role     = 'K'
        Mode     = 'Workflow'
        WorkflowFunction = 'Invoke-MaterializationReportWorkflow'
        HelpBrief = 'Podział walut: fizyczne (Postać) vs wirtualne (NPC/Grupa).'
        HelpFull = @(
            'Raport materializacji walut:'
            '  - Podział wg nominałów'
            '  - Majątek fizyczny wg graczy'
            '  - Osierocona waluta (nieaktywne Postacie z aktywną walutą)'
        )
        InfoText = @('Analiza fizycznej vs wirtualnej waluty z detekcją osieroconych pozycji.')
    }

    # ─── Przedmioty ──────────────────────────────────────────────────────────

    @{
        ID       = 'browse-items'
        Label    = 'Przeglądaj przedmioty'
        Description = 'Lista przedmiotów (bez waluty)'
        Function = 'Get-ItemEntity'
        Menu     = 'Przedmioty'
        Mode     = 'Query'
        Columns  = @('EntityName', 'Owner', 'Location', 'Quantity', 'Status')
        Headers  = @('Nazwa', 'Właściciel', 'Lokacja', 'Ilość', 'Status')
        Widths   = @(25, 18, 18, 8, 12)
        ColumnPriority = @(1, 1, 2, 3, 3)
        FilterPrefixes = @{
            'właściciel' = 'Owner'; 'owner' = 'Owner'
            'lokacja' = 'Location'; 'location' = 'Location'
        }
        HelpBrief = 'Lista przedmiotów (Przedmiot) z filtrami.'
        HelpFull = @(
            'Przeglądanie przedmiotów (encje typu Przedmiot).'
            'Domyślnie wyklucza walutę — użyj parametru IncludeCurrency.'
            'Filtrowanie:'
            '  właściciel:nazwa — filtruj po właścicielu'
            '  lokacja:nazwa — filtruj po lokacji'
        )
        InfoText = @('Lista przedmiotów z właścicielem, lokacją i ilością.')
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
        HelpBrief = 'Pełny kreator przydziału PU z podglądem i flagami.'
        HelpFull = @(
            'Przydział miesięczny PU:'
            '  1. Rok i miesiąc'
            '  2. Sprawdzenie integralności sesji'
            '  3. Próbny przebieg (dry run)'
            '  4. Flagi: aktualizacja postaci, Discord, log, uzgodnienie walut'
            '  5. Potwierdzenie i wykonanie'
            ''
            'Fail-early: nierozwiązana nazwa postaci przerywa cały przydział.'
            'Zalecenie: najpierw uruchom Diagnostykę PU.'
        )
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
        HelpBrief = 'Sprawdza gotowość do przydziału PU z sugestiami nazw.'
        HelpFull = @(
            'Diagnostyka przed przydziałem PU:'
            '  - Nierozwiązane postacie z sugestiami poprawnych nazw'
            '  - Ostrzeżenia o niespójnościach'
            ''
            'Uruchom przed każdym przydziałem PU.'
        )
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
        ColumnPriority = @(1, 2, 3)
        HelpBrief = 'Lista dotychczasowych przydziałów PU.'
        HelpFull = @(
            'Dziennik wszystkich wykonanych przydziałów PU.'
            'Kolumny: data przetworzenia, liczba sesji, strefa czasowa.'
            'Dane z pliku .robot/res/pu-sessions.json.'
        )
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
        ColumnPriority = @(1, 1, 2)
        HelpBrief = 'Lista graczy z uprawnieniami do głosowania.'
        HelpFull = @(
            'Kto spełnia warunki do głosowania.'
            'Uprawnienie zależy od sumy PU aktywnych postaci gracza.'
        )
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
        HelpBrief = 'Raport: nierozpoznane nazwy, duplikaty, niespójności PU.'
        HelpFull = @(
            'Szczegółowy raport poprawności PU:'
            '  - Nierozwiązane nazwy postaci'
            '  - Błędne wartości PU'
            '  - Duplikaty wpisów PU'
            '  - Sesje z błędną datą'
            '  - Przestarzałe wpisy historii'
        )
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
        ColumnPriority = @(1, 1, 2, 3)
        FilterPrefixes = @{ 'encja' = 'EntityName'; 'entity' = 'EntityName'; 'tag' = 'Property' }
        FilterOverrides = @{
            'MinDate' = @{ Type = 'date'; Label = 'Od daty'; Required = $false }
            'MaxDate' = @{ Type = 'date'; Label = 'Do daty'; Required = $false }
        }
        HelpBrief = 'Log zmian encji z sesji (tagi @lokacja, @grupa itp.).'
        HelpFull = @(
            'Zmiany właściwości elementów świata gry z sesji.'
            'Filtrowanie: wpisz tekst aby szukać'
            '  encja:nazwa — filtruj po nazwie encji'
            '  tag:lokacja — filtruj po właściwości'
            'Zakres dat ustawiany na początku.'
        )
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
        ColumnPriority = @(1, 1, 3)
        HelpBrief = 'Ile sesji poprowadził każdy narrator.'
        HelpFull = @(
            'Statystyki narratorów z normalizacją nazw.'
            'Pewność: High/Medium/Low — jakość dopasowania nazwy.'
            'Dane z plików narrator-mappings.txt + sesje.'
        )
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
        ColumnPriority = @(1, 1, 3)
        FilterPrefixes = @{ 'encja' = 'EntityMatch'; 'entity' = 'EntityMatch' }
        HelpBrief = 'Częstość użycia lokacji w sesjach.'
        HelpFull = @(
            'Ile razy każda lokacja pojawiła się w sesjach.'
            'Kolumna Encja pokazuje dopasowanie do zarejestrowanej encji.'
            '  encja:nazwa — filtruj po encji'
        )
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
        HelpBrief        = 'Graf połączeń między lokacjami.'
        HelpFull         = @(
            'Buduje unified graf lokacji z wielu źródeł:'
            '  - Encje (@lokacja, drzwi, zawiera)'
            '  - Trasy sesyjne (@Trasa w sesjach)'
            '  - Opcjonalnie: ruch z logów sesji'
            ''
            'Węzły = lokacje, krawędzie = relacje.'
            'Stopień (In/Out) pokazuje liczbę połączeń.'
        )
        InfoText         = @('Buduje graf lokacji z encji, tras sesyjnych i logów.')
    }

    @{
        ID               = 'session-graph'
        Label            = 'Graf sesji'
        Description      = 'Graf uczestnictwa encji w sesjach'
        Menu             = 'Raporty i Narzędzia'
        Mode             = 'Workflow'
        WorkflowFunction = 'Invoke-SessionGraphWorkflow'
        HelpBrief        = 'Indeks powiązań sesje ↔ encje (3 tiery).'
        HelpFull         = @(
            'Graf sesji — 4 tryby zapytań:'
            '  Sesje encji — w których sesjach uczestniczyła encja'
            '  Współuczestnicy — kto pojawiał się razem z encją'
            '  Uczestnicy sesji — kto uczestniczył w danej sesji'
            '  Podsumowanie — statystyki ogólne'
            ''
            'Tier 0 = zmiana w pliku, Tier 1 = metadane, Tier 2 = wzmianka w tekście.'
        )
        InfoText         = @('Indeks powiązań między sesjami a encjami (3 poziomy pewności).')
    }

    @{
        ID               = 'entity-session-profile'
        Label            = 'Profil encji w sesjach'
        Description      = 'Pełny profil uczestnictwa encji'
        Function         = 'Get-EntitySessionProfile'
        Menu             = 'Raporty i Narzędzia'
        Mode             = 'Wizard'
        HelpBrief        = 'Podsumowanie uczestnictwa encji: sesje, PU, trend.'
        HelpFull         = @(
            'Pełny profil uczestnictwa wybranej encji:'
            '  - Łączna liczba sesji i rozkład tierów'
            '  - Data pierwszej/ostatniej sesji'
            '  - Suma PU (jeśli dotyczy)'
            '  - Top 5 współuczestników'
            '  - Trend aktywności'
        )
        Overrides        = @{
            'EntityName' = @{ Type = 'fuzzy'; Source = 'entities' }
        }
        InfoText         = @('Podsumowanie sesji, daty, tier, PU, top współuczestnicy, trend aktywności.')
    }

    @{
        ID               = 'narrator-session-profile'
        Label            = 'Profil narratora w sesjach'
        Description      = 'Statystyki sesji narratora'
        Function         = 'Get-NarratorSessionProfile'
        Menu             = 'Raporty i Narzędzia'
        Mode             = 'Wizard'
        HelpBrief        = 'Statystyki narratora: sesje, uczestnicy, rozkład typów.'
        HelpFull         = @(
            'Profil narratora:'
            '  - Łączna liczba sesji'
            '  - Liczba unikalnych uczestników'
            '  - Rozkład typów encji'
            '  - Średnia wielkość grupy'
        )
        Overrides        = @{
            'NarratorName' = @{ Type = 'fuzzy'; Source = 'players' }
            'MinDate'      = @{ Type = 'date' }
            'MaxDate'      = @{ Type = 'date' }
        }
        InfoText         = @('Ile sesji, ilu uczestników, rozkład typów, średnia wielkość grupy.')
    }

    @{
        ID               = 'compare-participation'
        Label            = 'Porównanie uczestnictwa'
        Description      = 'Wspólne i unikalne sesje encji'
        Menu             = 'Raporty i Narzędzia'
        Mode             = 'Workflow'
        WorkflowFunction = 'Invoke-CompareParticipationWorkflow'
        HelpBrief        = 'Porównanie 2+ encji: wspólne sesje, pokrycie.'
        HelpFull         = @(
            'Porównanie uczestnictwa 2 lub więcej encji:'
            '  - Wspólne sesje'
            '  - Sesje unikalne dla każdej encji'
            '  - Macierz pokrycia (% wspólnych sesji)'
        )
        InfoText         = @('Porównuje uczestnictwo 2+ encji: wspólne sesje, unikalne, procent pokrycia.')
    }

    @{
        ID               = 'session-leaderboard'
        Label            = 'Ranking uczestnictwa'
        Description      = 'Encje wg liczby sesji'
        Menu             = 'Raporty i Narzędzia'
        Mode             = 'Workflow'
        WorkflowFunction = 'Invoke-SessionLeaderboardWorkflow'
        HelpBrief        = 'Top N encji wg liczby sesji z podziałem na tier.'
        HelpFull         = @(
            'Ranking encji po liczbie sesji.'
            '  - Opcjonalny filtr po typie encji'
            '  - Konfigurowalna liczba pozycji (domyślnie 20)'
            '  - Kolumny T0/T1/T2 = rozkład tierów'
        )
        InfoText         = @('Ranking encji po liczbie sesji z podziałem na tier.')
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
        ColumnPriority = @(1, 1, 3, 3)
        FilterPrefixes = @{ 'cel' = 'TargetName'; 'target' = 'TargetName'; 'typ' = 'Directive'; 'type' = 'Directive' }
        HelpBrief = 'Historia wysłanych powiadomień Discord.'
        HelpFull = @(
            'Dziennik wysłanych powiadomień.'
            '  cel:nazwa — filtruj po celu powiadomienia'
            '  typ:Intel — filtruj po typie'
        )
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
        ColumnPriority = @(1, 1, 1, 2, 3)
        HelpBrief = 'Pełna lista przelewów walutowych.'
        HelpFull = @(
            'Księga transakcji walutowych z sesji (@Transfer).'
            'Kolumny: data, źródło, cel, kwota, waluta.'
        )
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
        HelpBrief = 'Podgląd routingu wiadomości Intel z sesji.'
        HelpFull = @(
            'Podgląd Intel:'
            '  - Filtr po dacie (opcjonalny)'
            '  - Tabela: data sesji, cel, wiadomość'
            '  - Pokazuje jak wiadomości zostaną rozesłane'
        )
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
        HelpBrief = 'Ponowne wysłanie powiadomienia PU na Discord.'
        HelpFull = @(
            'Ponowne wysłanie powiadomienia PU:'
            '  1. Wybierz gracza'
            '  2. Wyświetla nieudane powiadomienia PU'
            '  3. Wybierz powiadomienie do ponownego wysłania'
            '  4. Podgląd i potwierdzenie'
        )
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
        HelpBrief = 'Sformatowane ogłoszenie na kanale Discord.'
        HelpFull = @(
            'Kreator ogłoszenia Discord:'
            '  1. Webhook URL'
            '  2. Tytuł ogłoszenia'
            '  3. Treść wiadomości'
            '  4. Podgląd i potwierdzenie'
        )
        InfoText = @('Opublikuj sformatowane ogłoszenie na kanale Discord.')
    }

    @{
        ID       = 'discord-custom'
        Label    = 'Discord: Wiadomość'
        Description = 'Wyślij dowolną wiadomość na Discord'
        Function = 'Send-DiscordMessage'
        Menu     = 'Raporty i Narzędzia'
        Role     = 'K'
        HelpBrief = 'Wysłanie dowolnej wiadomości na Discord.'
        HelpFull = @(
            'Wysyła dowolną wiadomość na wybrany kanał Discord.'
            'Wymaga podania webhook URL i treści wiadomości.'
        )
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
        HelpBrief = 'Przybliżone wyszukiwanie nazw w rejestrze encji.'
        HelpFull = @(
            'Wyszukiwanie przybliżone (fuzzy) po nazwie:'
            '  - Obsługuje odmianę (deklinację polską)'
            '  - Toleruje literówki (Levenshtein)'
            '  - Wyświetla kartę znalezionej encji'
        )
        InfoText = @('Wyszukaj dowolny element świata gry po nazwie — przybliżone dopasowanie.')
    }

    @{
        ID       = 'resolve-entity'
        Label    = 'Odwrotne wyszukiwanie'
        Description = 'Filtruj encje po właściciel/lokacja/grupa'
        Function = 'Resolve-Entity'
        Menu     = 'Raporty i Narzędzia'
        Mode     = 'Query'
        Columns  = @('Name', 'Type', 'Location', 'Owner', 'Status')
        Headers  = @('Nazwa', 'Typ', 'Lokacja', 'Właściciel', 'Status')
        Widths   = @(25, 12, 18, 18, 12)
        ColumnPriority = @(1, 1, 2, 2, 3)
        FilterPrefixes = @{
            'typ' = 'Type'; 'type' = 'Type'
            'lokacja' = 'Location'; 'location' = 'Location'
            'właściciel' = 'Owner'; 'owner' = 'Owner'
        }
        FilterOverrides = @{
            'Owner'    = @{ Type = 'fuzzy'; Source = 'entities'; Label = 'Właściciel'; Required = $false }
            'Location' = @{ Type = 'fuzzy'; Source = 'locations'; Label = 'Lokacja'; Required = $false }
            'Group'    = @{ Type = 'fuzzy'; Source = 'groups'; Label = 'Grupa'; Required = $false }
            'Type'     = @{ Type = 'selection'; Label = 'Typ'; Required = $false; Options = @('NPC', 'Grupa', 'Lokacja', 'Przedmiot', 'Postać') }
        }
        HelpBrief = 'Znajdź encje po właścicielu, lokacji lub grupie.'
        HelpFull = @(
            'Odwrotne wyszukiwanie encji — „co jest w lokacji X?",'
            '„co posiada postać Y?", „kto jest w grupie Z?"'
            'Filtry ustawiane na początku (opcjonalne).'
            '  typ:NPC — filtruj po typie'
            '  lokacja:nazwa — filtruj po lokacji'
            '  właściciel:nazwa — filtruj po właścicielu'
        )
        InfoText = @('Filtruj encje po właścicielu, lokacji, grupie lub typie.')
    }

    @{
        ID               = 'dormancy-report'
        Label            = 'Raport uśpionych'
        Description      = 'Encje bez aktywności od N miesięcy'
        Menu             = 'Raporty i Narzędzia'
        Mode             = 'Workflow'
        WorkflowFunction = 'Invoke-DormancyReportWorkflow'
        HelpBrief        = 'Lista encji nieaktywnych od zadanej liczby miesięcy.'
        HelpFull         = @(
            'Raport uśpionych encji:'
            '  - Próg nieaktywności (domyślnie 6 miesięcy)'
            '  - Opcjonalny filtr po typie'
            '  - Sortowanie: najdłużej uśpione na górze'
            '  - Źródła aktywności: zmiany tagów + graf sesji'
        )
        InfoText         = @('Wykrywa encje bez aktywności od zadanej liczby miesięcy.')
    }

    @{
        ID       = 'session-frequency'
        Label    = 'Trend częstotliwości sesji'
        Description = 'Sesje pogrupowane po miesiącach'
        Function = 'Get-SessionFrequencyTrend'
        Menu     = 'Raporty i Narzędzia'
        Mode     = 'Query'
        Columns  = @('Month', 'SessionCount', 'NarratorCount')
        Headers  = @('Miesiąc', 'Sesje', 'Narratorzy')
        Widths   = @(12, 10, 12)
        ColumnPriority = @(1, 1, 2)
        FilterOverrides = @{
            'MinDate' = @{ Type = 'date'; Label = 'Od daty'; Required = $false }
            'MaxDate' = @{ Type = 'date'; Label = 'Do daty'; Required = $false }
        }
        HelpBrief = 'Miesięczna agregacja sesji z rozbiciem na formaty.'
        HelpFull = @(
            'Trend częstotliwości sesji:'
            '  - Sesje pogrupowane po miesiącach'
            '  - Liczba unikalnych narratorów'
            '  - Rozbicie na formaty (Gen1-Gen4)'
            '  - Opcjonalny zakres dat'
        )
        InfoText = @('Miesięczna agregacja sesji z liczbą narratorów i rozbiciem formatów.')
    }

    @{
        ID               = 'entity-delta'
        Label            = 'Porównanie stanu encji'
        Description      = 'Diff właściwości encji między datami'
        Menu             = 'Raporty i Narzędzia'
        Mode             = 'Workflow'
        WorkflowFunction = 'Invoke-EntityDeltaWorkflow'
        HelpBrief        = 'Porównuje stan encji w dwóch punktach czasu.'
        HelpFull         = @(
            'Porównanie stanu encji między datami:'
            '  1. Wybierz encję (fuzzy search)'
            '  2. Podaj datę „od"'
            '  3. Podaj datę „do"'
            '  - Porównuje: lokację, właściciela, typ, status, ilość, grupy, drzwi'
        )
        InfoText         = @('Pokazuje co zmieniło się w encji między dwiema datami.')
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
        HelpBrief = 'Masowe pobieranie logów sesji z URL z throttlingiem.'
        HelpFull = @(
            'Pobieranie logów sesji z adresów URL:'
            '  1. Opcjonalny zakres dat'
            '  2. Potwierdzenie (CDN throttling 500ms)'
            '  3. Raport: pobrano / z cache / błędy'
            ''
            'Wymaga połączenia z internetem.'
            'Logi zapisywane w .robot/res/logs/.'
        )
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
        HelpBrief = 'Analiza lokacji z logów sesji vs zarejestrowane encje.'
        HelpFull = @(
            'Porównanie lokacji z logów sesji z encjami:'
            '  - Rozpoznane vs nierozpoznane lokacje'
            '  - Etap rozpoznania (exact, stem, fuzzy)'
            '  - Czy lokacja jest w metadanych sesji'
            '  - Podobne nazwy (near matches)'
            ''
            'Wymaga wcześniejszego pobrania logów.'
        )
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
        HelpBrief = 'Szybki podgląd postępu migracji.'
        HelpFull = @(
            'Szybka diagnostyka migracji:'
            '  - Które fazy zostały ukończone'
            '  - Szacunkowy postęp'
        )
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
        HelpBrief = 'Szczegółowy raport postępu migracji.'
        HelpFull = @(
            'Pełny raport migracji:'
            '  - Wyniki każdej z 7 faz (0-6)'
            '  - Szczegółowe statystyki i błędy'
        )
        InfoText = @('Pełny raport z wynikami każdej fazy migracji.')
    }
)

# ── Registry Indexes (built once, updated by Merge-PluginMenuItems) ─────────
# Pre-built dictionaries avoid linear scans in Get-RegistryEntry and
# Get-MenuItems; Merge-PluginMenuItems keeps them in sync when plugins add items.

$script:MenuRegistryByID = [System.Collections.Generic.Dictionary[string,hashtable]]::new(
    [System.StringComparer]::OrdinalIgnoreCase)
$script:MenuRegistryByCategory = [System.Collections.Generic.Dictionary[string,System.Collections.Generic.List[hashtable]]]::new(
    [System.StringComparer]::OrdinalIgnoreCase)

foreach ($Entry in $script:MenuRegistry) {
    $script:MenuRegistryByID[$Entry.ID] = $Entry
    if (-not $script:MenuRegistryByCategory.ContainsKey($Entry.Menu)) {
        $script:MenuRegistryByCategory[$Entry.Menu] = [System.Collections.Generic.List[hashtable]]::new()
    }
    [void]$script:MenuRegistryByCategory[$Entry.Menu].Add($Entry)
}
