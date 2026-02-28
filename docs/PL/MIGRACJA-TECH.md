# Przewodnik migracji: `.robot` → `.robot.new`

## Spis treści

1. [Cel i kontekst](#1-cel-i-kontekst)
2. [Wymagania wstępne](#2-wymagania-wstępne)
3. [Sugerowany harmonogram](#3-sugerowany-harmonogram)
4. [Faza 0 — Przygotowanie i backup](#4-faza-0--przygotowanie-i-backup)
5. [Faza 1 — Bootstrap entities.md](#5-faza-1--bootstrap-entitiesmd)
6. [Faza 2 — Walidacja parzystości danych](#6-faza-2--walidacja-parzystości-danych)
7. [Faza 3 — Diagnostyka i naprawa danych](#7-faza-3--diagnostyka-i-naprawa-danych)
8. [Faza 4 — Upgrade formatu sesji](#8-faza-4--upgrade-formatu-sesji)
9. [Faza 5 — Enrollment walut](#9-faza-5--enrollment-walut)
10. [Faza 6 — Okres równoległy](#10-faza-6--okres-równoległy)
11. [Faza 7 — Przełączenie (cutover)](#11-faza-7--przełączenie-cutover)
12. [Plan awaryjny (rollback)](#12-plan-awaryjny-rollback)
13. [Szkolenie zespołu](#13-szkolenie-zespołu)
14. [Weryfikacja końcowa](#14-weryfikacja-końcowa)
15. [FAQ / Rozwiązywanie problemów](#15-faq--rozwiązywanie-problemów)
16. [Dokumenty powiązane](#16-dokumenty-powiązane)

---

## 1. Cel i kontekst

### Dlaczego migracja

Dotychczasowy system `.robot/robot.ps1` to monolityczny skrypt PowerShell obsługujący zarządzanie graczami, postaciami i sesjami w repozytorium fabularnym Nerthus. Choć działa stabilnie, ma istotne ograniczenia:

- **Brak walidacji danych** — błędne nazwy postaci w PU, złe formaty dat w sesjach i inne niespójności przechodzą bez ostrzeżenia.
- **Ręczna edycja pliku `Gracze.md`** — każda zmiana wymaga bezpośredniej modyfikacji dużego pliku Markdown, co jest podatne na błędy.
- **Brak systemu walut** — waluta w grze nie jest formalnie śledzona.
- **Brak śladu audytowego** — trudno ustalić kto, kiedy i co zmienił.
- **Monolityczna architektura** — cały kod w jednym pliku, bez testów, trudny do rozbudowy.

### Co oferuje nowy system

Moduł `.robot.new` (wersja 2.0.0) to modularny system PowerShell z 32 eksportowanymi komendami, obszernym zestawem testów (43 pliki testowe), i szczegółową dokumentacją. Kluczowe ulepszenia:

- **Walidacja nazw postaci** — PU assignment zatrzymuje się natychmiast jeśli jakakolwiek nazwa nie zostanie rozwiązana, zamiast cicho pomijać.
- **CRUD przez komendy** — zamiast ręcznej edycji plików, operacje przez `New-Player`, `Set-PlayerCharacter`, `Remove-PlayerCharacter` itp.
- **Automatyczne rozwiązywanie nazw** — wielostopniowy system (dokładne dopasowanie → deklinacja → alternacja rdzeni → odległość Levenshteina).
- **System walut** — trzy denominacje (Korony, Talary, Kogi), śledzenie ilości, transfery, raportowanie, rekoncyliacja.
- **Audit trail** — plik historii przetworzonych sesji z timestampami, pełna historia git.
- **Diagnostyka** — `Test-PlayerCharacterPUAssignment` wykrywa problemy przed właściwym przetwarzaniem.
- **Cztery generacje formatu sesji** — automatyczne wykrywanie i parsowanie Gen1–Gen4 bez utraty danych.
- **Kompatybilność wsteczna** — nowy system czyta zarówno `Gracze.md` (read-only) jak i `entities.md`, nakładając dane w warstwy.

### Architektura dwóch magazynów danych

Nowy system operuje na **dwóch źródłach danych jednocześnie**:

| Magazyn | Plik(i) | Dostęp | Rola |
|---|---|---|---|
| **Legacy** | `Gracze.md` | Tylko odczyt | Historyczna baza graczy. Nigdy nie modyfikowana przez nowy system. |
| **Rejestr encji** | `entities.md` | Odczyt + Zapis | Kanoniczny cel zapisu dla wszystkich operacji CRUD. |

Przy odczycie (np. `Get-Player`) dane z obu magazynów są scalane w pamięci — encje z `entities.md` nadpisują wartości z `Gracze.md` tam, gdzie istnieją. Dzięki temu:
- Żadne dane nie giną podczas migracji
- Przejście jest stopniowe — nowe zmiany idą do `entities.md`, stary plik zostaje jako archiwum

---

## 2. Wymagania wstępne

### Oprogramowanie

| Składnik | Minimalna wersja | Jak sprawdzić |
|---|---|---|
| **PowerShell** | 5.1 (Windows) lub 7.0+ (Core, cross-platform) | `$PSVersionTable.PSVersion` |
| **Git** | Dowolna współczesna | `git --version` |
| **Pester** | 5.7+ (opcjonalnie, do testów) | `Get-Module Pester -ListAvailable` |

Jeśli Pester nie jest zainstalowany lub jest w zbyt starej wersji:

```powershell
Install-Module -Name Pester -MinimumVersion 5.7.0 -Force -SkipPublisherCheck
```

### Dostęp

- Repozytorium główne (`repozytorium-fabularne`) z uprawnieniami push
- Repozytorium modułu (`robot.new`) z uprawnieniami pull
- Dostęp do internetu (dla powiadomień Discord — opcjonalny na etapie migracji)

### Dodanie submodułu `.robot.new`

Moduł `.robot.new` jest osobnym repozytorium git, które musi być dodane jako **submoduł** repozytorium głównego. Dzięki temu wersja modułu jest powiązana z konkretnym commitem, a aktualizacje są kontrolowane.

> **Uwaga**: Tę operację wykonuje się **jednorazowo** w repozytorium głównym. Pozostali członkowie zespołu po `git pull` wykonują jedynie `git submodule update --init`.

**Jednorazowe dodanie submodułu (koordynator):**

```powershell
cd /ścieżka/do/repozytorium-fabularne

# Usuń istniejący katalog .robot.new jeśli nie jest jeszcze submodułem
# (np. jeśli był sklonowany ręcznie)
# UWAGA: upewnij się, że nie masz tam niezacommitowanych zmian!

# Dodaj submoduł
git submodule add git@github.com:mikkielt/robot.new.git .robot.new

# Zacommituj rejestrację submodułu
git add .gitmodules .robot.new
git commit -m "Dodanie .robot.new jako submodułu git"
git push
```

Po tej operacji w repozytorium pojawi się plik `.gitmodules` z konfiguracją:

```ini
[submodule ".robot.new"]
    path = .robot.new
    url = git@github.com:mikkielt/robot.new.git
```

**Inicjalizacja submodułu (pozostali członkowie zespołu):**

Każda osoba, która klonuje repozytorium lub wykonuje `git pull` po dodaniu submodułu:

```powershell
# Przy klonowaniu — od razu z submodułami
git clone --recurse-submodules git@github.com:mikkielt/repozytorium-fabularne.git

# Lub jeśli repozytorium jest już sklonowane
git pull
git submodule update --init --recursive
```

**Aktualizacja submodułu do najnowszej wersji:**

```powershell
cd .robot.new
git checkout main
git pull origin main
cd ..

# Zacommituj nową wersję submodułu w repozytorium głównym
git add .robot.new
git commit -m "Aktualizacja .robot.new do najnowszej wersji"
```

> **Ważne**: Po aktualizacji submodułu **musisz zacommitować** zmianę w repozytorium głównym. W przeciwnym razie inni członkowie zespołu po `git submodule update` cofną się do starej wersji.

### Weryfikacja instalacji

Po zainicjalizowaniu submodułu, uruchom testy:

```powershell
# Uruchomienie testów
Invoke-Pester ./.robot.new/tests/ -Output Detailed
```

Wszystkie testy powinny przejść (zielone). Jeśli jakikolwiek test nie przechodzi, rozwiąż problem przed kontynuowaniem migracji.

### Konfiguracja lokalna (opcjonalna)

Moduł szuka konfiguracji w następującej kolejności:
1. Jawny parametr w komendzie
2. Zmienna środowiskowa (`$env:NERTHUS_REPO_WEBHOOK`, `$env:NERTHUS_BOT_USERNAME`)
3. Plik konfiguracyjny `.robot.new/local.config.psd1` (ignorowany przez git)
4. Błąd jeśli wartość nie została znaleziona

Jeśli chcesz ustawić domyślne wartości, utwórz plik `.robot.new/local.config.psd1`:

```powershell
@{
    RepoWebhook = 'https://discord.com/api/webhooks/...'
    BotUsername  = 'Bothen'
}
```

---

## 3. Sugerowany harmonogram

| Faza | Nazwa | Szacowany czas | Zależności | Kto wykonuje |
|---|---|---|---|---|
| 0 | Przygotowanie i backup | 1 dzień | Brak | Koordynator |
| 1 | Bootstrap entities.md | 1 dzień | Faza 0 | Koordynator |
| 2 | Walidacja parzystości | 1 dzień | Faza 1 | Koordynator |
| 3 | Diagnostyka i naprawa | 2–3 dni | Faza 2 | Koordynator + narratorzy |
| 4 | Upgrade formatu sesji | 1–2 dni | Faza 3 | Koordynator |
| 5 | Enrollment walut | 1 tydzień (zbieranie danych) | Faza 1 | Koordynator + narratorzy + gracze |
| 6 | Okres równoległy | 2–4 tygodnie | Fazy 1–5 | Koordynator |
| 7 | Przełączenie (cutover) | 1 dzień | Faza 6 przeszła walidację | Koordynator |
| — | Szkolenie | Równolegle z Fazą 6 | Brak | Koordynator → zespół |

**Łączny szacowany czas**: 4–6 tygodni (w tym okres równoległy).

Fazy 4 i 5 mogą być realizowane równolegle z Fazami 2–3.

---

## 4. Faza 0 — Przygotowanie i backup

### Cel

Zabezpieczenie aktualnego stanu danych przed jakąkolwiek zmianą. Stworzenie punktu powrotu.

### Kroki

**Krok 1 — Sprawdź czysty stan repozytorium:**

```powershell
cd /ścieżka/do/repozytorium-fabularne
git status
```

Upewnij się, że nie ma niezacommitowanych zmian. Jeśli są — najpierw je zacommituj lub schowaj (`git stash`).

**Krok 2 — Utwórz tag bezpieczeństwa:**

```powershell
git tag pre-migration -m "Stan repozytorium przed migracją na .robot.new"
```

Ten tag pozwoli na powrót do dokładnego stanu sprzed migracji.

**Krok 3 — Kopia zapasowa pliku stanu PU:**

```powershell
# Sprawdź aktualny rozmiar pliku stanu
wc -l .robot/res/pu-sessions.md
```

Plik `.robot/res/pu-sessions.md` zawiera historię przetworzonych sesji (~1587 linii). Nowy system będzie **kontynuował** korzystanie z tego pliku — żadne dane nie zostaną utracone.

**Krok 4 — Zarejestruj lub zaktualizuj submoduł `.robot.new`:**

Jeśli submoduł **nie został jeszcze dodany** (brak pliku `.gitmodules`) — wykonaj jednorazową rejestrację zgodnie z instrukcją w sekcji [Dodanie submodułu .robot.new](#dodanie-submodułu-robotnew) w rozdziale „Wymagania wstępne".

Jeśli submoduł jest już zarejestrowany — zaktualizuj go:

```powershell
git submodule update --init --recursive
cd .robot.new
git checkout main
git pull origin main
cd ..
```

**Krok 5 — Weryfikacja modułu:**

```powershell
Import-Module ./.robot.new/robot.psd1 -Force
Get-Command -Module robot
```

Powinno wyświetlić listę ~32 eksportowanych komend. Jeśli komenda `Import-Module` kończy się błędem — rozwiąż problem przed kontynuowaniem.

**Krok 6 — Manifest danych `.robot-data.psd1`:**

Manifest informuje moduł gdzie szukać pliku `entities.md`. Bez niego komendy takie jak `New-Entity` zapisują dane do `.robot.new/entities.md` zamiast do katalogu głównego repozytorium (gdzie bootstrap w Fazie 1 tworzy plik).

Skrypt migracyjny tworzy manifest automatycznie. Jeśli wykonujesz kroki ręcznie:

```powershell
# Sprawdź czy manifest już istnieje
Test-Path .robot-data.psd1

# Jeśli nie — utwórz go
@"
@{
    EntitiesFile = 'entities.md'
}
"@ | Set-Content -Path .robot-data.psd1 -Encoding UTF8
```

Manifest jest prostym plikiem PowerShell Data File (`.psd1`) z kluczem `EntitiesFile` wskazującym ścieżkę względną do pliku encji. Moduł szuka go automatycznie w katalogu repozytorium.

### Checklist Fazy 0

- [ ] Repozytorium w czystym stanie (brak niezacommitowanych zmian)
- [ ] Tag `pre-migration` utworzony
- [ ] Plik `.robot/res/pu-sessions.md` istnieje i jest nienaruszony
- [ ] Submoduł `.robot.new` zarejestrowany (plik `.gitmodules` istnieje) i aktualny
- [ ] `Import-Module` wykonany pomyślnie
- [ ] Lista komend `Get-Command -Module robot` zwraca ~32 pozycje
- [ ] Manifest `.robot-data.psd1` istnieje w katalogu głównym repozytorium

---

## 5. Faza 1 — Bootstrap entities.md

### Cel

Wygenerowanie pliku `entities.md` na podstawie istniejącego `Gracze.md`. To jednorazowa operacja, która tworzy nowy magazyn danych z aktualną bazą graczy i postaci.

### Co robi bootstrap

Funkcja `ConvertTo-EntitiesFromPlayers` czyta wszystkich graczy z `Gracze.md` (przez `Get-Player -Entities @()` — pomijając puste entities, żeby uniknąć cyklicznej zależności) i generuje plik `entities.md` z dwoma sekcjami:

- **`## Gracz`** — wpisy z `@margonemid`, `@prfwebhook`, `@trigger`
- **`## Postać`** — wpisy z `@należy_do`, `@alias`, `@pu_startowe`, `@pu_nadmiar`, `@pu_suma`, `@pu_zdobyte`, `@info`

### Kroki

**Krok 1 — Załaduj moduł i helpery:**

```powershell
Import-Module ./.robot.new/robot.psd1 -Force
. ./.robot.new/private/entity-writehelpers.ps1
```

**Krok 2 — Uruchom bootstrap:**

```powershell
ConvertTo-EntitiesFromPlayers -OutputPath ./entities.md
```

> **Uwaga**: Domyślna ścieżka wyjścia (bez parametru `-OutputPath`) to katalog `private/` modułu. Podaj jawnie `./entities.md` żeby umieścić plik w katalogu głównym repozytorium.

**Krok 3 — Sprawdź wygenerowany plik:**

```powershell
# Szybki podgląd
Get-Content ./entities.md | Select-Object -First 40

# Policz wpisy
(Select-String -Path ./entities.md -Pattern '^\* ').Count
```

Liczba wpisów powinna odpowiadać sumie graczy i postaci w `Gracze.md`.

**Krok 4 — Dodaj brakujące sekcje:**

Wygenerowany plik zawiera sekcje `## Gracz` i `## Postać`. Dodaj ręcznie lub przez system brakujące sekcje na potrzeby przyszłych operacji:

```markdown
## NPC

## Organizacja

## Lokacja

## Przedmiot
```

Możesz to zrobić ręcznie, edytując plik, lub zostawić — sekcje zostaną utworzone automatycznie przy pierwszym użyciu `New-Entity`.

**Krok 5 — Zacommituj:**

```powershell
git add entities.md
git commit -m "Bootstrap entities.md z Gracze.md"
```

### Checklist Fazy 1

- [ ] `ConvertTo-EntitiesFromPlayers` wykonany bez błędów
- [ ] Plik `entities.md` istnieje w katalogu głównym repozytorium
- [ ] Liczba wpisów `* Nazwa` odpowiada oczekiwaniom (~97 graczy + ~200+ postaci)
- [ ] Plik zacommitowany do repozytorium

---

## 6. Faza 2 — Walidacja parzystości danych

### Cel

Upewnienie się, że nowy system poprawnie odczytuje i scala dane z obu magazynów (`Gracze.md` + `entities.md`).

### Kroki

**Krok 1 — Sprawdź scalanie danych graczy:**

```powershell
Import-Module ./.robot.new/robot.psd1 -Force

$Players = Get-Player
$Players | ForEach-Object {
    $Chars = $_.Characters | Measure-Object | Select-Object -ExpandProperty Count
    "$($_.Name): $Chars postaci"
}
```

Każdy gracz powinien mieć tę samą liczbę postaci co w oryginalnym `Gracze.md`.

**Krok 2 — Sprawdź wartości PU:**

```powershell
$Players | ForEach-Object {
    foreach ($Char in $_.Characters) {
        if ($null -ne $Char.PUSum) {
            "$($Char.Name): SUMA=$($Char.PUSum) STARTOWE=$($Char.PUStart) NADMIAR=$($Char.PUExceeded)"
        }
    }
}
```

Porównaj wyrywkowo z wartościami w `Gracze.md`. Wartości powinny się zgadzać.

**Krok 3 — Sprawdź aliasy:**

```powershell
$Players | ForEach-Object {
    foreach ($Char in $_.Characters) {
        if ($Char.Aliases.Count -gt 0) {
            "$($Char.Name): Aliasy = $($Char.Aliases -join ', ')"
        }
    }
}
```

**Krok 4 — Sprawdź webhooki:**

```powershell
$PlayersWithoutWebhook = $Players | Where-Object {
    [string]::IsNullOrWhiteSpace($_.PRFWebhook) -or $_.PRFWebhook -eq 'BRAK'
}
"Graczy bez webhooka: $($PlayersWithoutWebhook.Count)"
$PlayersWithoutWebhook | ForEach-Object { "  - $($_.Name)" }
```

**Krok 5 — Uruchom diagnostykę PU:**

```powershell
$Diag = Test-PlayerCharacterPUAssignment
$Diag | Format-List
```

Wynik diagnostyki zawiera:

| Pole | Znaczenie | Pożądana wartość |
|---|---|---|
| `OK` | Czy wszystko w porządku | `$true` |
| `UnresolvedCharacters` | Nazwy postaci które nie pasują do żadnej zarejestrowanej postaci | Pusta tablica |
| `MalformedPU` | Wpisy PU z brakującą lub nienumeryczną wartością | Pusta tablica |
| `DuplicateEntries` | Postać wymieniona wielokrotnie w jednej sesji | Pusta tablica |
| `FailedSessionsWithPU` | Sesje z błędną datą, które zawierają dane PU | Pusta tablica |
| `StaleHistoryEntries` | Nagłówki w pu-sessions.md nieodpowiadające żadnej sesji | Pusta tablica |

Jeśli `OK` to `$false` — przejdź do Fazy 3 (Diagnostyka i naprawa).

### Checklist Fazy 2

- [ ] `Get-Player` zwraca poprawną liczbę graczy i postaci
- [ ] Wartości PU zgadzają się z `Gracze.md` (wyrywkowa weryfikacja)
- [ ] Aliasy przeniosły się poprawnie
- [ ] Lista graczy bez webhooka jest znana
- [ ] `Test-PlayerCharacterPUAssignment` uruchomione — wynik zapisany

---

## 7. Faza 3 — Diagnostyka i naprawa danych

### Cel

Naprawienie znanych problemów w danych przed przejściem na nowy system. Nowy system jest bardziej rygorystyczny w walidacji — problemy które stary system cicho pomijał, nowy traktuje jako błędy.

### 7.1 Błędne nazwy postaci w PU

**Jak znaleźć:**

```powershell
$Diag = Test-PlayerCharacterPUAssignment
if ($Diag.UnresolvedCharacters.Count -gt 0) {
    $Diag.UnresolvedCharacters | ForEach-Object {
        "Nierozwiązana nazwa: '$($_.Character)' w sesji: $($_.SessionHeader)"
    }
}
```

**Jak naprawić — opcja A (poprawka w pliku sesji):**

Otwórz plik sesji i popraw literówkę w nazwie postaci.

**Jak naprawić — opcja B (dodanie aliasu):**

Jeśli nazwa jest poprawna, ale jest to alternatywna forma (np. zdrobnienie, odmiana), zarejestruj ją jako alias:

```powershell
Set-PlayerCharacter -PlayerName "NazwaGracza" -CharacterName "NazwaPostaci" -Aliases @("AlternatywnaNazwa")
```

Po naprawie uruchom diagnostykę ponownie, aby potwierdzić:

```powershell
$Diag = Test-PlayerCharacterPUAssignment
$Diag.UnresolvedCharacters.Count  # Powinno być 0
```

### 7.2 Niespójne formaty sesji

**Jak znaleźć sesje z błędami parsowania:**

```powershell
$Diag = Test-PlayerCharacterPUAssignment
if ($Diag.FailedSessionsWithPU.Count -gt 0) {
    $Diag.FailedSessionsWithPU | ForEach-Object {
        "Sesja z błędem: $($_.Header)"
        "  Plik: $($_.FilePath)"
        "  Błąd: $($_.ParseError)"
        "  Znalezione PU: $($_.PUCandidates -join ', ')"
    }
}
```

**Najczęstsze problemy z formatem dat:**

| Błędny format | Poprawny format |
|---|---|
| `2025-6-15` | `2025-06-15` |
| `15-06-2025` | `2025-06-15` |
| `2025/06/15` | `2025-06-15` |
| `2025-13-01` | (nieprawidłowy miesiąc) |

**Jak naprawić:**

Otwórz plik wskazany w `FilePath` i popraw nagłówek sesji do formatu:

```markdown
### YYYY-MM-DD, Tytuł Sesji, Imię Narratora
```

### 7.3 Duplikaty PU

```powershell
if ($Diag.DuplicateEntries.Count -gt 0) {
    $Diag.DuplicateEntries | ForEach-Object {
        "Duplikat: $($_.CharacterName) x$($_.Count) w sesji: $($_.SessionHeader)"
    }
}
```

Otwórz plik sesji i usuń zduplikowane wpisy PU (zachowaj poprawną wartość).

### 7.4 Wartości PU = BRAK

Niektóre postacie w `Gracze.md` mają PU oznaczone jako `BRAK`. To zazwyczaj postacie nieaktywne lub usunięte. Podczas bootstrapu te wartości nie zostaną przeniesione do `entities.md` (pola będą puste).

**Decyzja**: Czy oznaczyć te postacie jako usunięte?

```powershell
# Znajdź postacie bez PU
$Players | ForEach-Object {
    foreach ($Char in $_.Characters) {
        if ($null -eq $Char.PUSum -or $null -eq $Char.PUStart) {
            "$($_.Name) / $($Char.Name): PU BRAK"
        }
    }
}
```

Jeśli postać jest faktycznie usunięta:

```powershell
Remove-PlayerCharacter -PlayerName "NazwaGracza" -CharacterName "NazwaPostaci" -Confirm
```

### 7.5 Stale history entries

```powershell
if ($Diag.StaleHistoryEntries.Count -gt 0) {
    $Diag.StaleHistoryEntries | ForEach-Object {
        "Przestarzały wpis: $($_.Header)"
    }
}
```

Stale entries nie powodują błędów operacyjnych — to nagłówki w `pu-sessions.md` które nie pasują do żadnej istniejącej sesji (sesja mogła zostać przemianowana lub usunięta). Mogą być bezpiecznie zignorowane, chyba że chcesz wyczyścić plik historii.

### 7.6 Webhooks Discord — ujednolicenie URL-i

Starsze wpisy mogą używać formatu `discordapp.com`:

```powershell
$Players | Where-Object { $_.PRFWebhook -like '*discordapp.com*' } | ForEach-Object {
    "Stary format webhooka: $($_.Name) -> $($_.PRFWebhook)"
}
```

Oba formaty (`discordapp.com` i `discord.com`) działają, ale warto ujednolicić:

```powershell
Set-Player -Name "NazwaGracza" -PRFWebhook "https://discord.com/api/webhooks/..."
```

### Wzorzec pracy w Fazie 3

```
1. Uruchom diagnostykę
2. Napraw znalezione problemy
3. Uruchom diagnostykę ponownie
4. Powtarzaj aż OK = $true
5. Zacommituj naprawki
```

### Checklist Fazy 3

- [ ] `UnresolvedCharacters` — wszystkie naprawione (literówki poprawione lub aliasy dodane)
- [ ] `FailedSessionsWithPU` — wszystkie sesje z PU mają poprawne daty
- [ ] `DuplicateEntries` — brak duplikatów
- [ ] `MalformedPU` — brak błędnych wartości PU
- [ ] Postacie z `BRAK` PU — decyzja podjęta (soft-delete lub uzupełnienie)
- [ ] `Test-PlayerCharacterPUAssignment` zwraca `OK = $true`
- [ ] Naprawki zacommitowane

---

## 8. Faza 4 — Upgrade formatu sesji

### Cel

Zaktualizowanie aktywnych plików sesji z formatów Gen1/Gen2/Gen3 do bieżącego formatu Gen4 (z prefiksem `@`). Pliki archiwalne można zostawić w starym formacie — system czyta wszystkie cztery generacje automatycznie.

### Co zmienia upgrade

Upgrade zmienia **wyłącznie strukturę metadanych** — treść narracyjna i bloki specjalne (`Objaśnienia`, `Efekty`, `Komunikaty`, `Straty`, `Nagrody`) pozostają nietknięte.

| Przed (Gen3) | Po (Gen4) |
|---|---|
| `- Lokalizacje:` | `- @Lokacje:` |
| `- Logi: URL` | `- @Logi:` + `    - URL` |
| `- PU:` | `- @PU:` |
| `- Zmiany:` | `- @Zmiany:` |
| `*Lokalizacja: A, B*` (Gen2) | `- @Lokacje:` + `    - A` + `    - B` |
| `Logi: URL` (Gen1) | `- @Logi:` + `    - URL` |

### Obsługa błędów

Upgrade przetwarza pliki pojedynczo. Jeśli `Set-Session -UpgradeFormat` napotka błąd w konkretnym pliku (np. nagłówek sesji, który nie daje się zlokalizować), plik jest pomijany z komunikatem błędu, a przetwarzanie pozostałych plików kontynuowane. Po zakończeniu wyświetlana jest lista plików, które nie zostały zaktualizowane.

Nagłówki sesji z nietypowym formatowaniem (np. podwójna spacja po `###`) są normalizowane automatycznie — system dopasowuje je poprawnie niezależnie od ilości białych znaków po znaku nagłówka.

### Kroki

**Krok 1 — Sprawdź dystrybucję formatów:**

```powershell
Import-Module ./.robot.new/robot.psd1 -Force
Get-Session | Group-Object Format | Sort-Object Name | Format-Table Name, Count
```

Spodziewany wynik (przykład):

```
Name  Count
----  -----
Gen1     15
Gen2     48
Gen3    120
Gen4     30
```

**Krok 2 — Zdecyduj, które pliki są aktywne:**

Sugerowane kryterium: pliki z sesjami od 2024 roku wzwyż są aktywne. Starsze pliki (wątki zamknięte, archiwalne) mogą zostać w starym formacie.

```powershell
# Znajdź pliki z sesjami z 2024+
$ActiveFiles = Get-Session | Where-Object {
    $_.Date -ge [datetime]::new(2024, 1, 1)
} | Select-Object -ExpandProperty FilePath -Unique

"Plików do upgrade'u: $($ActiveFiles.Count)"
$ActiveFiles | ForEach-Object { "  $_" }
```

**Krok 3 — Upgrade plik po pliku:**

```powershell
foreach ($File in $ActiveFiles) {
    Write-Host "Upgrading: $File" -ForegroundColor Cyan
    Get-Session -File $File | Where-Object { $_.Format -ne 'Gen4' } | Set-Session -UpgradeFormat
}
```

Lub pojedynczy plik:

```powershell
Get-Session -File 'Wątki/nazwa-wątku.md' | Where-Object { $_.Format -ne 'Gen4' } | Set-Session -UpgradeFormat
```

**Krok 4 — Weryfikacja po upgrade:**

```powershell
# Sprawdź czy wszystkie sesje w zaktualizowanych plikach są teraz Gen4
Get-Session | Where-Object { $ActiveFiles -contains $_.FilePath } |
    Group-Object Format | Format-Table Name, Count
```

Wszystkie powinny być `Gen4`.

**Krok 5 — Przegląd nazw lokalizacji:**

Po upgrade wszystkie aktywne sesje mają ustrukturyzowane bloki `@Lokacje`. To dobry moment na przegląd nazw lokalizacji — raport analizuje wszystkie użyte nazwy, porównuje je z zarejestrowanymi encjami typu Lokacja, i wykrywa konflikty.

```powershell
# Wygeneruj raport lokalizacji
$ActiveSessions = Get-Session | Where-Object { $_.Date -ge [datetime]::new(2024, 1, 1) }
$Report = Get-NamedLocationReport -Sessions $ActiveSessions -Entities (Get-Entity)

# Podsumowanie
$Unresolved = $Report | Where-Object { $null -eq $_.EntityMatch }
$WithConflicts = $Report | Where-Object { $_.Conflicts.Count -gt 0 }

"Lokacji ogółem: $($Report.Count)"
"Rozwiązanych: $($Report.Count - $Unresolved.Count - $WithConflicts.Count)"
"Ostrzeżeń (konflikty): $($WithConflicts.Count)"
"Nierozwiązanych: $($Unresolved.Count)"
```

Raport dla każdej lokalizacji zawiera:

| Pole | Opis |
|---|---|
| `Name` | Najczęściej używana forma nazwy |
| `Variants` | Inne formy pisowni (np. odmienione nazwy) |
| `OccurrenceCount` | Ile razy lokalizacja pojawiła się w sesjach |
| `EntityMatch` | Dopasowana encja typu Lokacja (jeśli istnieje) |
| `Conflicts` | Wykryte konflikty (różna pisownia, niespójna hierarchia) |

**Nierozwiązane lokalizacje** to nazwy, które nie pasują do żadnej zarejestrowanej encji typu Lokacja. Dla każdej z nich decydujesz:

- **Utwórz encję** — jeśli to prawdziwa lokalizacja, dodaj ją: `New-Entity -Type Lokacja -Name "NazwaLokacji"`
- **Oznacz jako nie-lokację** — jeśli to nie jest lokalizacja (np. „na zewnątrz", „w drodze"), dodaj do pliku wykluczeń

Plik wykluczeń (`.robot/res/location-exclusions.txt`) zawiera nazwy oznaczone jako nie-lokacje — po jednej na linię:

```
# Wartości oznaczone jako nie-lokacje podczas migracji
na zewnątrz
w drodze
```

Skrypt migracyjny (`Invoke-Migration -Phase 4`) obsługuje ten proces interaktywnie — wyświetla nierozwiązane lokalizacje i pozwala oznaczyć je jako nie-lokacje bezpośrednio. Commit jest blokowany dopóki istnieją nierozwiązane lokalizacje (te, które nie zostały ani zarejestrowane jako encje, ani oznaczone jako nie-lokacje).

**Krok 6 — Zacommituj:**

```powershell
git add Wątki/
git commit -m "Upgrade aktywnych sesji do formatu Gen4"
```

### Checklist Fazy 4

- [ ] Dystrybucja formatów przed upgrade'em udokumentowana
- [ ] Lista aktywnych vs archiwalnych plików ustalona
- [ ] Aktywne pliki zaktualizowane do Gen4
- [ ] Weryfikacja po upgrade — zero sesji nie-Gen4 w aktywnych plikach
- [ ] Raport lokalizacji przejrzany — nierozwiązane lokalizacje obsłużone
- [ ] Zacommitowane

---

## 9. Faza 5 — Enrollment walut

### Cel

System walut jest **całkowicie nową funkcjonalnością**. W starym systemie waluta nie była śledzona formalnie. Ta faza wymaga zebrania danych o stanie posiadania walut od graczy, narratorów i koordynatorów.

### Denominacje

| Nazwa pełna | Nazwa krótka | Tier | Wartość w Kogach | Przelicznik |
|---|---|---|---|---|
| Korony Elanckie | Korony | Złoto | 10 000 | 1 Korona = 100 Talarów |
| Talary Hirońskie | Talary | Srebro | 100 | 1 Talar = 100 Kogów |
| Kogi Skeltvorskie | Kogi | Miedź | 1 | Jednostka bazowa |

### Krok 1 — Utworzenie skarbca koordynatorów

Skarbiec to organizacja (Organizacja) reprezentująca ogólną rezerwę walut administrowaną przez koordynatorów:

```powershell
Import-Module ./.robot.new/robot.psd1 -Force

# Utwórz organizację skarbca
New-Entity -Type Organizacja -Name "Skarbiec Koordynatorów"

# Utwórz walutę w skarbcu (początkowe ilości — dostosuj do aktualnych rezerw)
New-CurrencyEntity -Denomination Korony -Owner "Skarbiec Koordynatorów" -Amount 10000
New-CurrencyEntity -Denomination Talary -Owner "Skarbiec Koordynatorów" -Amount 50000
New-CurrencyEntity -Denomination Kogi   -Owner "Skarbiec Koordynatorów" -Amount 100000
```

Kwoty początkowe powinny odzwierciedlać rzeczywiste rezerwy. Jeśli nie są znane — ustal je z koordynatorami.

### Krok 2 — Zbieranie danych od graczy

**Metoda: sesja inicjalizacyjna (sesja-dummy)**

Najłatwiejszy sposób rejestracji początkowego stanu walut graczy to utworzenie specjalnej sesji inicjalizacyjnej, która przypisuje waluty przez blok `@Zmiany`:

```markdown
### YYYY-MM-DD, Inicjalizacja walut, Koordynator

Sesja techniczna — rejestracja początkowego stanu walut postaci graczy.

- @Zmiany:
    - Korony NazwaPostaci1
        - @generyczne_nazwy: Korony Elanckie
        - @należy_do: NazwaPostaci1
        - @ilość: 50
        - @status: Aktywny
    - Talary NazwaPostaci1
        - @generyczne_nazwy: Talary Hirońskie
        - @należy_do: NazwaPostaci1
        - @ilość: 200
        - @status: Aktywny
```

**Alternatywna metoda: bezpośrednie komendy**

Dla mniejszej liczby postaci, użyj komend bezpośrednio:

```powershell
New-CurrencyEntity -Denomination Korony -Owner "NazwaPostaci" -Amount 50
New-CurrencyEntity -Denomination Talary -Owner "NazwaPostaci" -Amount 200
New-CurrencyEntity -Denomination Kogi   -Owner "NazwaPostaci" -Amount 1500
```

**Wzór formularza do wysłania graczom:**

```
Formularz stanu walut postaci:
- Nazwa postaci: _______________
- Korony (złoto): _____ sztuk
- Talary (srebro): _____ sztuk
- Kogi (miedź): _____ sztuk
```

### Krok 3 — Budżety narratorów i koordynatorów

Narratorzy mogą posiadać „budżety" walut do rozdawania na sesjach. Te walutowe encje reprezentują walutę w posiadaniu narratora (poza postacią gracza):

```powershell
# Utworzenie budżetu narratora
New-CurrencyEntity -Denomination Korony -Owner "Narrator Dracon" -Amount 0

# Dystrybucja ze skarbca do narratora
Set-CurrencyEntity -Name "Korony Skarbiec Koordynatorów" -AmountDelta -500 -ValidFrom "2026-03"
Set-CurrencyEntity -Name "Korony Narrator Dracon" -AmountDelta +500 -ValidFrom "2026-03"
```

> **Ważne**: Dystrybucja administratora (skarbiec → narrator) to para komend `Set-CurrencyEntity` z przeciwnymi deltami. System nie linkuje ich automatycznie — jeśli zapomnisz jednej strony, `Test-CurrencyReconciliation` wykryje to przy najbliższym sprawdzeniu.

### Krok 4 — Waluta przy lokacjach

Waluta może być „porzucona" w lokacji zamiast należeć do postaci:

```powershell
New-CurrencyEntity -Denomination Talary -Owner "Ruiny Erathii" -Amount 300
```

W tym przypadku `@należy_do` wskazuje na lokację. Encja lokacji musi istnieć w `entities.md` (utwórz ją przez `New-Entity -Type Lokacja -Name "Ruiny Erathii"` jeśli nie istnieje).

### Krok 5 — Weryfikacja

```powershell
# Raport walut
Get-CurrencyReport | Format-Table EntityName, Denomination, Balance, Owner

# Rekoncyliacja
$Reconciliation = Test-CurrencyReconciliation
$Reconciliation.Warnings | Format-Table Check, Severity, Entity, Detail
"Supply: $($Reconciliation.Supply | Out-String)"
"Warning count: $($Reconciliation.WarningCount)"
```

### Krok 6 — Zacommituj

```powershell
git add entities.md
git commit -m "Enrollment walut - stan początkowy"
```

### Checklist Fazy 5

- [ ] Skarbiec koordynatorów utworzony z początkowymi rezerwami
- [ ] Dane o walutach zebrane od graczy
- [ ] Waluty postaci graczy zarejestrowane (sesja-dummy lub komendy bezpośrednie)
- [ ] Budżety narratorów ustalone (jeśli dotyczy)
- [ ] `Get-CurrencyReport` pokazuje oczekiwane dane
- [ ] `Test-CurrencyReconciliation` — brak krytycznych ostrzeżeń
- [ ] Zacommitowane

---

## 10. Faza 6 — Okres równoległy

### Cel

Uruchomienie nowego systemu obok starego na 2–4 tygodnie w celu walidacji poprawności i budowania zaufania do nowego narzędzia.

### Workflow podczas okresu równoległego

#### Miesięczny przydział PU

Uruchom **oba systemy** i porównaj wyniki:

**Stary system:**

```powershell
. .robot/robot.ps1
# Użyj opcji menu lub komendy starego systemu
```

**Nowy system (w trybie suchym — bez efektów ubocznych):**

```powershell
Import-Module ./.robot.new/robot.psd1 -Force

# Tryb suchy (dry-run) — oblicza PU ale nic nie zapisuje
$Results = Invoke-PlayerCharacterPUAssignment -Year YYYY -Month MM -WhatIf
$Results | ForEach-Object {
    "$($_.CharacterName): Granted=$($_.GrantedPU), Overflow=$($_.OverflowPU)"
}
```

Porównaj wyniki. Jeśli się różnią — zbadaj przyczynę (najprawdopodobniej różnica w rozwiązywaniu nazw lub obsłudze duplikatów sesji).

#### Nowe sesje

Narrtorzy powinni zacząć pisać nowe sesje w **formacie Gen4** (z prefiksem `@`). Format jest w pełni kompatybilny wstecz — stary system nadal go parsuje.

Przykład nowej sesji:

```markdown
### 2026-03-15, Tytuł Sesji, Narrator

Treść narracyjna sesji.

- @Lokacje:
    - Erathia
    - Bracada
- @Logi:
    - https://krisaphalon.ct8.pl/get/sesja-przykladowa
- @PU:
    - Crag Hack: 0.3
    - Gem: 0.5
- @Zmiany:
    - Crag Hack
        - @lokacja: Bracada (2026-03:)
- @Intel:
    - Solmyr: Wiadomość prywatna
```

#### Nowe postacie

Twórz nowe postacie **wyłącznie przez nowy system**:

```powershell
New-PlayerCharacter -PlayerName "NazwaGracza" -CharacterName "NazwaPostaci" -CharacterSheetUrl "https://..."
```

System automatycznie:
- Obliczy PU startowe (na podstawie PU istniejących postaci gracza)
- Utworzy plik postaci z szablonu
- Zarejestruje postać w `entities.md`

#### Operacje na postaciach

Aktualizacje postaci przez nowy system:

```powershell
# Zmiana statusu
Set-PlayerCharacter -PlayerName "Gracz" -CharacterName "Postać" -Status "Nieaktywny"

# Aktualizacja PU
Set-PlayerCharacter -PlayerName "Gracz" -CharacterName "Postać" -PUSum 45.5

# Dodanie aliasu
Set-PlayerCharacter -PlayerName "Gracz" -CharacterName "Postać" -Aliases @("NowyAlias")
```

### Co monitorować

| Aspekt | Jak sprawdzić | Oczekiwany wynik |
|---|---|---|
| Parzystość PU | Porównanie wyników obu systemów | Identyczne wartości |
| Parsowanie sesji | `Get-Session \| Where-Object { $null -ne $_.ParseError }` | Brak błędów |
| Diagnostyka | `Test-PlayerCharacterPUAssignment` | `OK = $true` |
| Rekoncyliacja walut | `Test-CurrencyReconciliation` | Brak krytycznych ostrzeżeń |

### Kryteria sukcesu

Przed przejściem do Fazy 7 (przełączenie) upewnij się, że:

- [ ] Minimum **1 pełny cykl** miesięcznego PU assignment bez rozbieżności między starym a nowym systemem
- [ ] `Test-PlayerCharacterPUAssignment` zwraca `OK = $true`
- [ ] Wszyscy aktywni narratorzy znają format Gen4 i potrafią go stosować
- [ ] `Test-CurrencyReconciliation` nie zgłasza błędów krytycznych

### Checklist Fazy 6

- [ ] PU assignment porównany — wyniki zgodne
- [ ] Narratorzy piszą w Gen4
- [ ] Nowe postacie tworzone przez nowy system
- [ ] Diagnostyka czysta (`OK = $true`)
- [ ] Kryteria sukcesu spełnione

---

## 11. Faza 7 — Przełączenie (cutover)

### Cel

Oficjalne przejście na nowy system jako jedyne narzędzie operacyjne. Zamrożenie `Gracze.md` i dezaktywacja starego systemu.

### Kroki

**Krok 1 — Ostatnia synchronizacja:**

Upewnij się, że ostatni przydział PU został wykonany przez nowy system i wyniki są poprawne:

```powershell
Import-Module ./.robot.new/robot.psd1 -Force
Test-PlayerCharacterPUAssignment | Format-List OK
```

**Krok 2 — Zamrożenie `Gracze.md`:**

Dodaj komentarz na początku pliku `Gracze.md` informujący o statusie:

```markdown
<!-- UWAGA: Ten plik jest zamrożony (read-only) od [DATA].
     Wszelkie zmiany w danych graczy i postaci wprowadzaj przez
     moduł .robot.new i plik entities.md.
     Ten plik zachowany jest wyłącznie jako archiwum historyczne. -->
```

```powershell
git add Gracze.md
git commit -m "Zamrożenie Gracze.md - migracja zakończona"
```

**Krok 3 — Oznaczenie starego systemu jako deprecated:**

```powershell
# Dodaj notatkę do README starego systemu
git add .robot/README.md
git commit -m "Oznaczenie .robot jako deprecated"
```

**Krok 4 — Pierwsze samodzielne uruchomienie PU:**

```powershell
Import-Module ./.robot.new/robot.psd1 -Force
Invoke-PlayerCharacterPUAssignment -Year YYYY -Month MM `
    -UpdatePlayerCharacters `
    -SendToDiscord `
    -AppendToLog `
    -Confirm
```

> **Parametry**:
> - `-UpdatePlayerCharacters` — zapisuje zaktualizowane wartości PU do `entities.md`
> - `-SendToDiscord` — wysyła powiadomienia Discord do graczy
> - `-AppendToLog` — zapisuje przetworzone sesje w historii (`pu-sessions.md`)
> - `-Confirm` — wymaga potwierdzenia przed wykonaniem (ConfirmImpact = High)

Jeśli chcesz dodatkowo sprawdzić walutę:

```powershell
Invoke-PlayerCharacterPUAssignment -Year YYYY -Month MM `
    -UpdatePlayerCharacters `
    -SendToDiscord `
    -AppendToLog `
    -ReconcileCurrency `
    -Confirm
```

**Krok 5 — Ogłoszenie:**

Poinformuj zespół o oficjalnym przełączeniu:
- Od teraz wszystkie operacje przez nowy moduł `.robot.new`
- Sesje w formacie Gen4
- Stary `.robot/robot.ps1` nie jest już używany

**Krok 6 — Tagowanie:**

```powershell
git tag post-migration -m "Migracja na .robot.new zakończona"
```

### Checklist Fazy 7

- [ ] Ostatni PU assignment przetestowany i poprawny
- [ ] `Gracze.md` zamrożony (komentarz + commit)
- [ ] Stary system oznaczony jako deprecated
- [ ] Pierwsze samodzielne uruchomienie PU przez nowy system — sukces
- [ ] Zespół poinformowany
- [ ] Tag `post-migration` utworzony

---

## 12. Plan awaryjny (rollback)

### Kiedy użyć rollbacku

- Nowy system generuje **konsystentnie inne** wyniki PU niż stary
- Wykryto **utratę danych** która nie da się naprawić
- Krytyczny **błąd w module** uniemożliwiający pracę

### Poziomy rollbacku

#### Poziom 1: Rollback jednej operacji

Jeśli pojedyncza operacja (np. PU assignment) dała złe wyniki:

```powershell
git revert HEAD  # Cofnij ostatni commit
```

Nowy system **nie modyfikuje** `Gracze.md` — stary system nadal ma dostęp do nienaruszonej bazy danych.

#### Poziom 2: Rollback do stanu sprzed konkretnej fazy

```powershell
# Sprawdź logi aby znaleźć commit
git log --oneline

# Cofnij do konkretnego commitu (tworzy nowy commit odwracający zmiany)
git revert <hash-commitu>
```

#### Poziom 3: Rollback session upgrade

Jeśli upgrade formatu sesji spowodował problemy:

```powershell
# Przywróć oryginalne pliki sesji
git checkout pre-migration -- "Wątki/nazwa-pliku.md"
```

#### Poziom 4: Pełny rollback do stanu sprzed migracji

> **UWAGA**: Ta operacja jest **destrukcyjna** — wszystkie zmiany po tagu `pre-migration` zostaną utracone!

```powershell
git reset --hard pre-migration
```

Użyj tego tylko jako ostateczność, po upewnieniu się że żadne ważne dane nie zostaną utracone.

### Bezpieczeństwo: co nowy system NIE modyfikuje

| Plik/katalog | Modyfikowany? | Konsekwencje |
|---|---|---|
| `Gracze.md` | **Nigdy** | Stary system zawsze ma dostęp do nienaruszonej bazy |
| `.robot/res/pu-sessions.md` | Tylko dopisywanie | Nowe wpisy na końcu pliku; stare wpisy nietknięte |
| Pliki postaci (`Postaci/Gracze/*.md`) | Tak, sekcje | `Set-PlayerCharacter` modyfikuje sekcje w plikach postaci |
| `entities.md` | Tak | Wszystkie operacje CRUD piszą tutaj |
| Pliki sesji (`Wątki/*.md`) | Tak, przy upgrade | `Set-Session -UpgradeFormat` modyfikuje metadane |

Dzięki temu, że `Gracze.md` nigdy nie jest modyfikowany, **zawsze można wrócić do starego systemu** bez utraty oryginalnych danych.

---

## 13. Szkolenie zespołu

### 13.1 Dla koordynatorów

#### Podstawy — import modułu

Za każdym razem gdy otwierasz nową sesję PowerShell:

```powershell
cd /ścieżka/do/repozytorium-fabularne
Import-Module ./.robot.new/robot.psd1 -Force
```

Aby zobaczyć wszystkie dostępne komendy:

```powershell
Get-Command -Module robot
```

#### Miesięczny przydział PU

1. **Przed przydziałem — diagnostyka:**

```powershell
$Diag = Test-PlayerCharacterPUAssignment -Year YYYY -Month MM
$Diag | Format-List
```

Jeśli `OK = $false` — napraw problemy przed kontynuowaniem.

2. **Suchy przebieg (dry-run):**

```powershell
$Results = Invoke-PlayerCharacterPUAssignment -Year YYYY -Month MM -WhatIf
$Results | Format-Table CharacterName, GrantedPU, OverflowPU, UsedExceeded
```

3. **Właściwy przydział:**

```powershell
Invoke-PlayerCharacterPUAssignment -Year YYYY -Month MM `
    -UpdatePlayerCharacters `
    -SendToDiscord `
    -AppendToLog `
    -Confirm
```

#### Zarządzanie graczami i postaciami

```powershell
# Nowy gracz
New-Player -Name "NowyGracz" -MargonemID "1234567" -PRFWebhook "https://discord.com/api/webhooks/..."

# Nowa postać
New-PlayerCharacter -PlayerName "NowyGracz" -CharacterName "NowaPostać" -CharacterSheetUrl "https://..."

# Aktualizacja danych gracza
Set-Player -Name "Gracz" -PRFWebhook "https://discord.com/api/webhooks/nowy-webhook"

# Aktualizacja postaci
Set-PlayerCharacter -PlayerName "Gracz" -CharacterName "Postać" -Aliases @("Alias1", "Alias2")

# Usunięcie postaci (soft-delete)
Remove-PlayerCharacter -PlayerName "Gracz" -CharacterName "Postać" -Confirm
```

#### Raportowanie walut

```powershell
# Raport wszystkich walut
Get-CurrencyReport | Format-Table EntityName, Denomination, Balance, Owner

# Raport dla konkretnego gracza
Get-CurrencyReport -Owner "NazwaPostaci"

# Rekoncyliacja
Test-CurrencyReconciliation | Format-List
```

#### Tworzenie/modyfikacja walut

```powershell
# Nowa waluta
New-CurrencyEntity -Denomination Korony -Owner "NazwaPostaci" -Amount 100

# Zmiana ilości (wartość bezwzględna)
Set-CurrencyEntity -Name "Korony NazwaPostaci" -Amount 150 -ValidFrom "2026-03"

# Zmiana ilości (delta)
Set-CurrencyEntity -Name "Korony NazwaPostaci" -AmountDelta +50 -ValidFrom "2026-03"

# Transfer między postaciami (rejestracja w sesji — preferowana metoda)
# Użyj @Transfer w sesji (patrz sekcja dla narratorów)
```

---

### 13.2 Dla narratorów

#### Format sesji Gen4

Każda sesja powinna być zapisana w następującym formacie:

```markdown
### YYYY-MM-DD, Tytuł Sesji, Imię Narratora

Treść narracyjna — opis sesji, wnioski, wydarzenia.
Ten tekst jest zachowywany ale nie parsowany automatycznie.

- @Lokacje:
    - NazwaLokacji1
    - NazwaLokacji2
- @Logi:
    - https://link-do-logów-sesji
- @PU:
    - NazwaPostaci1: 0.3
    - NazwaPostaci2: 0.5
- @Zmiany:
    - NazwaEncji
        - @lokacja: NowaLokacja (YYYY-MM:)
        - @status: Aktywny (YYYY-MM:)
        - @grupa: NowaGrupa (YYYY-MM:)
- @Intel:
    - Grupa/NazwaOrganizacji: Wiadomość do członków
    - Lokacja/NazwaLokacji: Wiadomość do obecnych
    - NazwaOdbiorca: Prywatna wiadomość
- @Transfer: 100 koron, ŹródłoPostać -> CelPostać
```

#### Najczęstsze błędy

| Błąd | Konsekwencja | Poprawka |
|---|---|---|
| `2026-3-15` zamiast `2026-03-15` | Sesja cicho pomijana w PU | Zawsze dwie cyfry na miesiąc i dzień |
| `Krag Hack: 0.3` zamiast `Crag Hack: 0.3` | PU assignment zatrzymany | Sprawdź nazwę postaci z rejestrem |
| Brak `:` po nazwie postaci w PU | Wartość PU nie rozpoznana | `- NazwaPostaci: 0.3` (dwukropek obowiązkowy) |
| Tagi bez `@` w nowych sesjach | Parsowanie jako Gen3 zamiast Gen4 | Zawsze `@Lokacje`, `@PU`, `@Logi` itd. |
| Wcięcie 2 spacje zamiast 4 | Podelementy nie rozpoznane | Używaj 4 spacji na każdy poziom wcięcia |

#### Transfery walut w sesji

Zamiast ręcznych komend, preferowaną metodą transferu walut jest dyrektywa `@Transfer` w sesji:

```markdown
- @Transfer: 100 koron, Xeron Demonlord -> Kupiec Orrin
- @Transfer: 50 talarów, Kupiec Orrin -> Kyrre
```

Format: `@Transfer: {ilość} {denominacja}, {źródło} -> {cel}`

System automatycznie:
- Rozpoznaje denominację (korony/talary/kogi — akceptowane formy odmiany)
- Znajduje encje walutowe źródła i celu
- Odejmuje od źródła i dodaje do celu
- Ostrzega jeśli encja walutowa nie istnieje

---

### 13.3 Dla graczy

#### Co się zmienia

Z perspektywy gracza **niewiele się zmienia**:

- **Powiadomienia Discord** — wyglądają tak samo, nadal przychodzą na webhook gracza
- **Karta postaci** — plik `.md` w `Postaci/Gracze/` nadal jest aktualizowany
- **PU** — mechanizm przydziału pozostaje taki sam (1 bazowe + sesyjne, limit 5/miesiąc, nadmiar przenoszony)
- **Nowe**: Waluta postaci jest teraz formalnie śledzona — gracz może zostać poproszony o podanie stanu walut

#### Zgłaszanie alternatywne deklaracji — nowy format

Gracze korzystający z możliwości samodzielnego zgłaszania deklaracji w formacie repozytorium ([zgłaszanie alternatywne](https://nerthus.pl/Mechanika/Deklaracje/#zgłaszanie-alternatywne)) powinni stosować nowy format z prefiksem `@` przy polach metadanych:

**Dotychczasowy format:**

```markdown
### 2025-04-20, Sandro i Thant dzień święty święcą, Rada

>    Opis deklaracji.

- Logi: https://link-do-logów
- Lokalizacje:
    - Mokradła
    - Mokradła/Zajazd pod Zielonym Jednorożcem
- PU:
    - Sandro: 0.3
    - Thant: 0.3
```

**Nowy format:**

```markdown
### 2025-04-20, Sandro i Thant dzień święty święcą, Rada

>    Opis deklaracji.

- @Logi:
    - https://link-do-logów
- @Lokacje:
    - Mokradła
    - Mokradła/Zajazd pod Zielonym Jednorożcem
- @PU:
    - Sandro: 0.3
    - Thant: 0.3
```

Różnice: pola metadanych mają prefiks `@`, `Lokalizacje` zmienia się na `@Lokacje`, logi wpisywane w osobnej linii pod nagłówkiem `@Logi:`. Stary format nadal jest rozpoznawany, ale nowy jest preferowany.

#### Zgłaszanie problemów

Jeśli zauważysz problem:
1. Sprawdź czy Twoja nazwa postaci lub alias jest poprawnie zapisana w sesji
2. Skontaktuj się z koordynatorem, podając:
   - Nazwę postaci
   - Datę sesji
   - Oczekiwany wynik vs. faktyczny wynik

---

## 14. Weryfikacja końcowa

Po zakończeniu wszystkich faz migracji, upewnij się że **wszystkie** poniższe warunki są spełnione:

### Checklist końcowy

| # | Warunek | Status |
|---|---|---|
| 1 | `entities.md` wygenerowany i zacommitowany | [ ] |
| 2 | `Test-PlayerCharacterPUAssignment` zwraca `OK = $true` | [ ] |
| 3 | Aktywne pliki sesji w formacie Gen4 | [ ] |
| 4 | Waluty zarejestrowane | [ ] |
| 5 | `Test-CurrencyReconciliation` — brak błędów krytycznych | [ ] |
| 6 | Min. 1 pełny cykl PU bez rozbieżności z starym systemem | [ ] |
| 7 | Wszyscy aktywni narratorzy przeszkoleni z Gen4 | [ ] |
| 8 | `Gracze.md` zamrożony (komentarz read-only) | [ ] |
| 9 | Stary system `.robot/robot.ps1` oznaczony jako deprecated | [ ] |
| 10 | Tagi git `pre-migration` i `post-migration` istnieją | [ ] |
| 11 | Pierwszego samodzielny PU assignment przez nowy system — sukces | [ ] |
| 12 | Zespół poinformowany o przełączeniu | [ ] |

---

## 15. FAQ / Rozwiązywanie problemów

### Ogólne

**P: Czy muszę zaktualizować wszystkie sesje do Gen4?**

O: Nie. System automatycznie czyta wszystkie cztery generacje formatów. Upgrade do Gen4 jest zalecany dla aktywnych plików (aby ujednolicić format), ale pliki archiwalne mogą zostać w starym formacie bezterminowo.

**P: Co się stanie jeśli zapomnę `-Force` przy `Import-Module`?**

O: Bez `-Force`, PowerShell użyje wcześniej załadowanej wersji modułu (jeśli istnieje). Dodawaj `-Force` za każdym razem, szczególnie po aktualizacji submodułu.

**P: Czy mogę cofnąć się do starego systemu po przełączeniu?**

O: Tak. Stary system czyta `Gracze.md` który nigdy nie jest modyfikowany przez nowy system. Jedyne co stracisz to zmiany zapisane wyłącznie w `entities.md`. Git tag `pre-migration` pozwala na pełny rollback.

**P: Czy nowy system zmienia pliki postaci (`Postaci/Gracze/*.md`)?**

O: Tak — komenda `Set-PlayerCharacter` modyfikuje sekcje w plikach postaci (Stan, Przedmioty specjalne, Reputacja itp.). Treść sekcji „Opisane sesje" nigdy nie jest modyfikowana automatycznie.

### PU

**P: PU assignment zatrzymuje się z błędem „UnresolvedPUCharacters" — co robić?**

O: Jedna lub więcej nazw postaci w sesjach nie pasuje do żadnej zarejestrowanej postaci. Sprawdź literówki i brakujące aliasy. Komenda `Test-PlayerCharacterPUAssignment` wyświetli listę problematycznych nazw z lokalizacją w plikach sesji.

**P: Sesja nie pojawia się w PU assignment — dlaczego?**

O: Możliwe przyczyny:

| Przyczyna | Jak sprawdzić |
|---|---|
| Błędny format daty | Nagłówek to `### YYYY-MM-DD, ...`? |
| Poza zakresem dat | Sesja mieści się w podanym roku/miesiącu? |
| Brak bloku PU | Sesja zawiera `- @PU:` lub `- PU:`? |
| Już przetworzona | Nagłówek widnieje w `.robot/res/pu-sessions.md`? |

**P: Wartość PU w wynikach różni się od oczekiwanej — dlaczego?**

O: Algorytm PU:
1. `BasePU = 1 + sum(PU za sesje w danym miesiącu)`
2. Jeśli `BasePU < 5` i istnieje nadmiar → uzupełnienie z nadmiaru (max do 5)
3. Jeśli `BasePU > 5` → nadwyżka trafia do puli nadmiaru
4. Przyznane PU = `min(BasePU + uzupełnienie, 5)` — **limit 5 na miesiąc**

### Waluty

**P: Jak sprawdzić stan walut konkretnej postaci?**

```powershell
Get-CurrencyReport -Owner "NazwaPostaci" | Format-Table Denomination, Balance
```

**P: `Test-CurrencyReconciliation` zgłasza „AsymmetricTransaction" — co to znaczy?**

O: W ramach jednej sesji, zmiany ilości danej denominacji nie sumują się do zera. Oznacza to, że waluta została stworzona lub zniszczona (celowo lub przez pomyłkę). Jeśli to zamierzone — zignoruj. Jeśli nie — sprawdź wpisy `@ilość` w bloku `@Zmiany` sesji.

**P: `Test-CurrencyReconciliation` zgłasza „OrphanedCurrency" — co to znaczy?**

O: Waluta należy do encji o statusie `Nieaktywny` lub `Usunięty`. Zdecyduj czy przenieść walutę do innej encji, czy oznaczyć ją jako nieaktywną.

### Sesje

**P: Bloki `Objaśnienia`, `Efekty` itp. zniknęły po upgrade — czy to normalne?**

O: Nie — te bloki powinny być zachowane przy upgrade. Jeśli zniknęły, użyj `git diff` żeby sprawdzić co się zmieniło i przywróć brakujący fragment z `git checkout pre-migration -- "Wątki/plik.md"`.

**P: Moja sesja ma dwóch narratorów — jak to zapisać?**

O: Użyj słowa „i" jako separatora:

```markdown
### 2026-03-15, Wspólna sesja, Solmyr i Crag Hack
```

### Dodatkowa pomoc

Szczegółowa dokumentacja rozwiązywania problemów: [docs/Troubleshooting.md](docs/Troubleshooting.md)

---

## 16. Dokumenty powiązane

### Dokumentacja użytkownika (`docs/`)

| Dokument | Opis |
|---|---|
| [Migration.md](docs/Migration.md) | Koncepcyjny przewodnik migracji (co się zmienia, role, przepływy) |
| [Sessions.md](docs/Sessions.md) | Przewodnik zapisu sesji (format Gen4, pola metadanych) |
| [PU.md](docs/PU.md) | Proces miesięcznego przydziału PU |
| [Players.md](docs/Players.md) | Cykl życia gracza i postaci |
| [World-State.md](docs/World-State.md) | Śledzenie encji i zakres temporalny |
| [Notifications.md](docs/Notifications.md) | Intel, targeting, powiadomienia Discord |
| [Glossary.md](docs/Glossary.md) | Terminologia PL/EN |
| [Troubleshooting.md](docs/Troubleshooting.md) | Diagnostyka i rozwiązywanie problemów |

### Dokumentacja techniczna (`devdocs/`)

| Dokument | Opis |
|---|---|
| [MIGRATION.md](devdocs/MIGRATION.md) | Techniczna referencja migracji (model danych, składnia komend) |
| [ENTITIES.md](devdocs/ENTITIES.md) | System encji (parsowanie, scalanie, pipeline) |
| [SESSIONS.md](devdocs/SESSIONS.md) | Formaty sesji Gen1–Gen4, algorytmy detekcji |
| [PU.md](devdocs/PU.md) | Normatywna specyfikacja algorytmu PU |
| [CURRENCY.md](devdocs/CURRENCY.md) | System walut (denominacje, transfery, rekoncyliacja) |
| [CHARFILE.md](devdocs/CHARFILE.md) | Format pliku postaci |
| [CONFIG-STATE.md](devdocs/CONFIG-STATE.md) | Konfiguracja i pliki stanu |
| [NAME-RESOLUTION.md](devdocs/NAME-RESOLUTION.md) | Rozwiązywanie nazw (deklinacja, Levenshtein) |
