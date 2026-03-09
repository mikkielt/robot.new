<#
    .SYNOPSIS
    Context-sensitive help content and display for the Robot CLI.

    .DESCRIPTION
    This file contains the help content dictionary and the display function
    consumed by the menu routing layer when the user presses H.

    Helpers:
    - Show-HelpScreen: renders a help page for a given context key

    Module-level data:
    - $script:HelpContent: hashtable mapping context keys to help page definitions

    Design:
    - Help content is pure data (Polish text). Each entry has a Title and a
      Body (string array of lines).
    - Show-HelpScreen clears the screen, renders the help page, and waits
      for any keypress before returning. No navigation state is changed.
    - Context keys: 'root' for main menu, category names (matching
      $script:MenuOrder values) for submenus.
#>

# ── Help Content ────────────────────────────────────────────────────────────

$script:HelpContent = @{

    'root' = @{
        Title = 'Robot CLI - Pomoc'
        Body  = @(
            'Robot CLI to interaktywne narzędzie do zarządzania'
            'światem gry Nerthus. Znajdziesz tu wszystko, czego'
            'potrzebujesz: sesje, postacie, NPC, lokacje, grupy,'
            'walutę i punkty umiejętności (PU).'
            ''
            'Jak się poruszać:'
            '  ↑↓        poruszanie się po menu'
            '  Enter     wybór zaznaczonej opcji'
            '  q/Esc     wstecz (w menu głównym: wyjście)'
            '  h         wyświetlenie pomocy'
            ''
            'Menu główne zawiera 7 kategorii tematycznych.'
            'Wybierz kategorię, aby zobaczyć dostępne operacje.'
            ''
            'Oznaczenia ról przy operacjach:'
            '  [N]   Narrator — osoba prowadząca sesje'
            '  [K]   Koordynator — osoba zarządzająca kampanią'
            '  Operacje bez oznaczenia są dostępne dla wszystkich.'
            ''
            'Odśwież dane — przeładuj informacje o postaciach,'
            'graczach i elementach świata gry. Przydatne, gdy dane'
            'zostały zmienione poza tym narzędziem.'
        )
    }

    'Sesje' = @{
        Title = 'Sesje - Pomoc'
        Body  = @(
            'Tutaj zarządzasz sesjami RPG — tworzysz nowe,'
            'edytujesz istniejące i przeglądasz historię rozgrywek.'
            ''
            'Nowa sesja        [N]  Kreator prowadzi krok po kroku:'
            '                       data, narrator, lokacje, PU,'
            '                       zmiany w świecie, powiadomienia.'
            'Edytuj sesję      [N]  Zmień dane istniejącej sesji'
            '                       (np. popraw datę lub narratora).'
            'Walidacja sesji   [N]  Sprawdź, czy wszystkie nazwy'
            '                       postaci i lokacji są poprawne.'
            'Przeglądaj sesje       Lista sesji z filtrem dat.'
            '                       Wybierz wiersz, aby zobaczyć'
            '                       szczegóły.'
            'Historia zmian         Przeglądaj historię zmian'
            '                       w repozytorium.'
            ''
            'Wskazówka: Po utworzeniu sesji sprawdź ją za pomocą'
            'Walidacji, aby upewnić się, że wszystkie nazwy'
            'zostały rozpoznane.'
        )
    }

    'Gracze i Postacie' = @{
        Title = 'Gracze i Postacie - Pomoc'
        Body  = @(
            'Rejestracja i edycja graczy oraz ich postaci'
            'w świecie gry.'
            ''
            'Nowy gracz        [K]  Dodaj nowego gracza do kampanii.'
            'Nowa postać       [K]  Stwórz postać dla gracza'
            '                       (opcjonalnie z walutą startową).'
            'Edytuj postać     [K]  Zmień dane istniejącej postaci.'
            'Edytuj gracza     [K]  Zmień dane gracza (wyzwalacze'
            '                       powiadomień, alternatywne nazwy).'
            'Usuń postać       [K]  Oznacz postać jako nieaktywną'
            '                       (dane nie są trwale usuwane).'
            'Przeglądaj graczy      Lista wszystkich graczy'
            '                       z podglądem ich postaci.'
            'Karta postaci          Szczegółowy widok wybranej'
            '                       postaci.'
            ''
            'Przy wyborze nazwy nie musisz wpisywać dokładnej'
            'nazwy — wystarczy wpisać początek, a system'
            'podpowie pasujące wyniki.'
        )
    }

    'Encje' = @{
        Title = 'Elementy świata gry - Pomoc'
        Body  = @(
            'Zarządzanie elementami świata gry: NPC, grupy,'
            'lokacje, przedmioty.'
            ''
            'Nowa encja        [K]  Stwórz nowy element — wybierz'
            '                       typ (np. NPC, Lokacja), podaj'
            '                       nazwę i dodaj właściwości.'
            'Edytuj encję      [K]  Zmień właściwości istniejącego'
            '                       elementu.'
            'Usuń encję        [K]  Oznacz element jako nieaktywny'
            '                       (dane nie są trwale usuwane).'
            'Przeglądaj encje       Lista elementów z filtrowaniem'
            '                       po typie.'
            'Historia encji         Zobacz, jak element zmieniał'
            '                       się w czasie (na podst. sesji).'
            'Szukaj                 Wyszukaj element po nazwie —'
            '                       wystarczy wpisać początek.'
            ''
            'Właściwości elementów mogą mieć zakresy czasowe,'
            'np. NPC może zmieniać lokację w różnych okresach gry.'
        )
    }

    'Waluta' = @{
        Title = 'Waluta - Pomoc'
        Body  = @(
            'Operacje na walutach w świecie gry.'
            ''
            'Nowa waluta       [K]  Utwórz nowy zapis walutowy'
            '                       (np. sakiewkę postaci).'
            'Zmień saldo       [K]  Zmień ilość waluty bezpośrednio.'
            'Przelej walutę    [K]  Przenieś walutę między dwoma'
            '                       właścicielami.'
            'Zmień lokalizację [K]  Przenieś walutę do innego'
            '                       miejsca.'
            'Usuń walutę       [K]  Usuń zapis walutowy.'
            'Salda walut            Przegląd aktualnych stanów walut.'
            'Raport walutowy        Zestawienie walut wg właściciela.'
            'Uzgodnienie       [K]  Sprawdź poprawność wszystkich'
            '                       walut.'
            ''
            'W świecie gry funkcjonują trzy nominały:'
            '  Korony Elanckie (KOR), Talary Hirońskie (TAL),'
            '  Kogi Skeltvorskie (KOG).'
        )
    }

    'PU' = @{
        Title = 'PU (Punkty Umiejętności) - Pomoc'
        Body  = @(
            'Przydzielanie i diagnostyka Punktów Umiejętności.'
            'PU to punkty rozwoju, które postacie otrzymują'
            'za udział w sesjach.'
            ''
            'Przydział miesięczny   [K]  Nalicz PU za wybrany'
            '                            okres. Najpierw zobaczysz'
            '                            podgląd zmian (nic nie'
            '                            zostanie zapisane), a dopiero'
            '                            po zatwierdzeniu — zapis.'
            'Diagnostyka przed      [K]  Sprawdź, czy wszystko jest'
            '  przydziałem               gotowe do przydziału: nazwy'
            '                            postaci, daty, poprawność.'
            'Historia przydziałów        Przeglądaj dziennik'
            '                            dotychczasowych przydziałów.'
            'Uprawnienia głosowania      Sprawdź, którzy gracze mają'
            '                            uprawnienia do głosowania.'
            'Diagnostyka PU              Szczegółowy raport'
            '                            poprawności PU.'
            ''
            'Przed przydziałem system musi rozpoznać nazwy'
            'wszystkich postaci. Jeśli któraś nazwa nie zostanie'
            'rozpoznana, cały przydział się zatrzyma — żadna'
            'postać nie dostanie PU, dopóki problem nie zostanie'
            'rozwiązany.'
        )
    }

    'Raporty i Narzędzia' = @{
        Title = 'Raporty i Narzędzia - Pomoc'
        Body  = @(
            'Raporty, narzędzia diagnostyczne, wiadomości Discord'
            'i inne.'
            ''
            'Log zmian                   Przeglądaj zmiany elementów'
            '                            świata gry z sesji.'
            'Raport narratorów           Statystyki prowadzących.'
            'Raport lokacji              Jak często używano lokacji.'
            'Powiadomienia               Dziennik wysłanych'
            '                            powiadomień.'
            'Transakcje                  Księga przelewów walutowych.'
            'Podgląd Intel         [N/K] Sprawdź, kto otrzyma jakie'
            '                            wiadomości z wybranej sesji.'
            'Discord: PU           [K]   Wyślij ponownie'
            '                            powiadomienie PU.'
            'Discord: Ogłoszenie   [K]   Opublikuj ogłoszenie'
            '                            na Discordzie.'
            'Discord: Wiadomość    [K]   Wyślij dowolną wiadomość'
            '                            na Discord.'
            'Szukaj nazwy                Wyszukaj element świata gry'
            '                            po nazwie.'
            'Pobierz logi          [K]   Pobierz zapisy rozmów'
            '                            z sesji (z adresów URL).'
            'Raport lokacji z logów [N]  Porównaj lokacje z zapisów'
            '                            rozmów z lokacjami w grze.'
        )
    }

    'Migracja' = @{
        Title = 'Migracja - Pomoc'
        Body  = @(
            'Narzędzia do przenoszenia danych ze starszego formatu'
            'kampanii do aktualnego.'
            ''
            'Migracja składa się z kilku kroków (faz 0-6),'
            'wykonywanych po kolei. Każdy krok można uruchomić'
            'wielokrotnie bez ryzyka — postęp jest zapamiętywany.'
            ''
            'Szybka diagnostyka     [K]  Podsumowanie: ile zostało'
            '                            do zrobienia.'
            'Pełny raport           [K]  Szczegółowy raport postępu'
            '                            migracji.'
            ''
            'Poszczególne fazy pojawiają się w menu tylko wtedy,'
            'gdy pliki migracji są dostępne.'
        )
    }
}

# ── Show-HelpScreen ─────────────────────────────────────────────────────────

function Show-HelpScreen {
    param(
        [Parameter(Mandatory)] [string]$ContextKey
    )

    $Entry = $script:HelpContent[$ContextKey]
    if (-not $Entry) {
        $Entry = $script:HelpContent['root']
    }

    $AccentColor   = Get-CLIColor -Role 'Accent'
    $DisabledColor = Get-CLIColor -Role 'Disabled'
    $InfoColor     = Get-CLIColor -Role 'Info'
    $Sep = [string][char]0x2500 * 50

    [System.Console]::Clear()

    Write-Host ''
    Write-CLILine -Text $Entry.Title -Color $AccentColor
    Write-Host "  $Sep" -ForegroundColor $AccentColor
    Write-Host ''

    foreach ($Line in $Entry.Body) {
        if ([string]::IsNullOrEmpty($Line)) {
            Write-Host ''
        }
        else {
            Write-CLILine -Text $Line -Color $InfoColor
        }
    }

    Write-Host ''
    Write-Host "  $Sep" -ForegroundColor $DisabledColor
    Write-Host ''
    Write-Host '  Naciśnij dowolny klawisz aby wrócić...' -ForegroundColor $DisabledColor

    [void][System.Console]::ReadKey($true)
}
