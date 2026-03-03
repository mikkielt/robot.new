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
            'Robot CLI to interaktywne narzędzie do zarządzania światem gry Nerthus.'
            ''
            'Nawigacja:'
            '  ↑↓        poruszanie się po menu'
            '  Enter     wybór zaznaczonej opcji'
            '  Esc       powrót do poprzedniego menu'
            '  h         wyświetlenie pomocy kontekstowej'
            '  q         wyjście z CLI'
            ''
            'Menu główne zawiera 7 kategorii tematycznych. Wybierz kategorię,'
            'aby zobaczyć dostępne operacje.'
            ''
            'Role:'
            '  [N]   Narrator - prowadzący sesje'
            '  [K]   Koordynator - zarządzanie techniczne'
            '  Operacje bez oznaczenia roli są dostępne dla wszystkich.'
            ''
            'Odśwież dane - przeładuj encje, graczy i indeks nazw.'
            'Dane są ładowane przy starcie CLI i mogą wymagać odświeżenia'
            'po zmianach dokonanych poza CLI.'
        )
    }

    'Sesje' = @{
        Title = 'Sesje - Pomoc'
        Body  = @(
            'Zarządzanie sesjami RPG w formacie Gen4.'
            ''
            'Nowa sesja        [N]  Kreator nowej sesji: plik, data, narrator,'
            '                       lokacje, PU, zmiany encji, Intel, logi.'
            'Edytuj sesję      [N]  Zmiana metadanych istniejącej sesji.'
            'Walidacja sesji   [N]  Sprawdza poprawność: format dat, nazwy'
            '                       postaci w PU, nazwy encji, lokacje.'
            'Przeglądaj sesje       Lista sesji z filtrem dat. Wybierz wiersz'
            '                       aby zobaczyć szczegóły.'
            'Historia zmian         Logi commitów git z repozytorium.'
        )
    }

    'Gracze i Postacie' = @{
        Title = 'Gracze i Postacie - Pomoc'
        Body  = @(
            'Rejestracja i edycja graczy oraz ich postaci.'
            ''
            'Nowy gracz        [K]  Rejestracja gracza w entities.md.'
            'Nowa postać       [K]  Kreator postaci z opcjonalną walutą startową.'
            'Edytuj postać     [K]  Zmiana danych istniejącej postaci.'
            'Edytuj gracza     [K]  Zmiana danych gracza (triggery, aliasy).'
            'Usuń postać       [K]  Oznaczenie postaci jako usuniętej (soft-delete).'
            'Przeglądaj graczy      Lista wszystkich graczy z podglądem postaci.'
            'Karta postaci          Szczegółowy widok wybranej postaci.'
            ''
            'Wyszukiwanie nazw korzysta z fuzzy matching - zacznij pisać,'
            'a system podpowie pasujące wyniki.'
        )
    }

    'Encje' = @{
        Title = 'Encje - Pomoc'
        Body  = @(
            'Zarządzanie encjami świata gry: NPC, Grupy, Lokacje, Przedmioty.'
            ''
            'Nowa encja        [K]  Wybierz typ, nazwę i tagi (@lokacja, @grupa, itp.).'
            'Edytuj encję      [K]  Zmiana tagów istniejącej encji.'
            'Usuń encję        [K]  Soft-delete: oznaczenie @status: Usunięty.'
            'Przeglądaj encje       Lista encji z filtrowaniem po typie.'
            'Historia encji         Chronologia zmian encji z sesji.'
            'Szukaj                 Wyszukiwanie encji po nazwie (fuzzy matching).'
            ''
            'Tagi wspierają zakresy czasowe:'
            '  @lokacja: Erathia (2024-01:2024-06)'
        )
    }

    'Waluta' = @{
        Title = 'Waluta - Pomoc'
        Body  = @(
            'Operacje na walutach świata gry.'
            ''
            'Nowa waluta            [K]  Utworzenie encji walutowej.'
            'Zmień saldo            [K]  Bezpośrednia zmiana ilości waluty.'
            'Przelej walutę         [K]  Transfer między dwiema encjami walutowymi.'
            'Zmień lokalizację      [K]  Przeniesienie waluty do innej lokacji.'
            'Usuń walutę            [K]  Usunięcie encji walutowej.'
            'Salda walut                 Przegląd sald wszystkich walut.'
            'Raport walutowy             Zestawienie walut wg właściciela.'
            'Uzgodnienie            [K]  Walidacja spójności walut.'
            ''
            'Waluty są encjami typu Przedmiot z tagiem @ilość.'
            'Nominały: Korony (KOR), Talary (TAL), Kogi (KOG).'
        )
    }

    'PU' = @{
        Title = 'PU (Punkty Umiejętności) - Pomoc'
        Body  = @(
            'Przydzielanie i diagnostyka Punktów Umiejętności.'
            ''
            'Przydział miesięczny   [K]  Naliczenie PU za wybrany okres.'
            '                            Podgląd (dry-run) przed zatwierdzeniem.'
            'Diagnostyka przed      [K]  Sprawdzenie gotowości do przydziału:'
            '  przydziałem               walidacja nazw, dat, spójności.'
            'Historia przydziałów        Dziennik naliczonych PU.'
            'Uprawnienia głosowania      Status uprawnień graczy.'
            'Diagnostyka PU              Szczegółowy raport spójności PU.'
            ''
            'Każdy przydział wymaga rozpoznania wszystkich nazw postaci.'
            'Nierozpoznane nazwy blokują cały przydział (fail-early).'
        )
    }

    'Raporty i Narzędzia' = @{
        Title = 'Raporty i Narzędzia - Pomoc'
        Body  = @(
            'Raporty, narzędzia diagnostyczne, Discord, logi.'
            ''
            'Log zmian                    Zmiany stanów encji z sesji.'
            'Raport narratorów            Statystyki narratorów.'
            'Raport lokacji               Statystyki użycia lokacji.'
            'Powiadomienia                Dziennik powiadomień Discord.'
            'Transakcje                   Księga transakcji walutowych.'
            'Podgląd Intel          [N/K] Podgląd routingu informacji z sesji.'
            'Discord: PU            [K]   Ponowne wysłanie powiadomienia PU.'
            'Discord: Ogłoszenie    [K]   Strukturalne ogłoszenie na Discord.'
            'Discord: Wiadomość     [K]   Dowolna wiadomość na Discord.'
            'Szukaj nazwy                 Wyszukiwanie po nazwie (fuzzy).'
            'Pobierz logi           [K]   Masowe pobieranie logów z Pastebin.'
            'Raport lokacji z logów [N]   Analiza lokacji w logach sesji.'
        )
    }

    'Migracja' = @{
        Title = 'Migracja - Pomoc'
        Body  = @(
            'Narzędzia migracji danych z formatu legacy do Gen4.'
            ''
            'Fazy migracji (0-7) są wykonywane sekwencyjnie.'
            'Każda faza jest idempotentna - można ją uruchomić wielokrotnie.'
            'Postęp jest zapisywany w .robot/res/migration-state.json.'
            ''
            'Szybka diagnostyka     [K]  Podsumowanie stanu migracji.'
            'Pełny raport           [K]  Szczegółowy raport migracji.'
            ''
            'Fazy dynamiczne pojawiają się tylko gdy pliki migracji'
            'są dostępne w repozytorium.'
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

    [void](Read-ArrowKey)
}
