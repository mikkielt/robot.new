# Migracja systemu administracyjnego Nerthus — przewodnik dla zespołu

## Dla kogo jest ten dokument

Ten dokument jest przeznaczony dla **wszystkich osób zaangażowanych w Nerthus**: graczy, narratorów i koordynatorów. Wyjaśnia co się zmienia, dlaczego, jak wpłynie to na codzienną pracę, i czego oczekujemy od poszczególnych ról.

Szczegółowy przewodnik techniczny (z komendami i procedurami krok po kroku) znajduje się w osobnym dokumencie: [migr.md](migr.md).

---

## Spis treści

1. [Co się zmienia i dlaczego](#1-co-się-zmienia-i-dlaczego)
2. [Harmonogram migracji](#2-harmonogram-migracji)
3. [Co zmienia się dla graczy](#3-co-zmienia-się-dla-graczy)
4. [Co zmienia się dla narratorów](#4-co-zmienia-się-dla-narratorów)
5. [Co zmienia się dla koordynatorów](#5-co-zmienia-się-dla-koordynatorów)
6. [Nowa funkcjonalność: system walut](#6-nowa-funkcjonalność-system-walut)
7. [Okres przejściowy](#7-okres-przejściowy)
8. [Najczęściej zadawane pytania](#8-najczęściej-zadawane-pytania)

---

## 1. Co się zmienia i dlaczego

### Problem

Dotychczasowy system administracyjny Nerthus (znany jako „robot") działa od lat, ale ma ograniczenia, które coraz bardziej utrudniają pracę:

- **Ciche pomijanie błędów** — jeśli nazwa postaci w sesji jest źle zapisana (literówka, odmiana), system po prostu ją ignoruje. Gracz nie dostaje PU, a nikt nie wie dlaczego.
- **Ręczna edycja danych** — każda zmiana w danych graczy wymaga bezpośredniej edycji dużego pliku tekstowego. Łatwo o pomyłkę.
- **Brak śledzenia walut** — waluta w grze nie jest formalnie rejestrowana, co utrudnia kontrolę i bilansowanie.
- **Brak diagnostyki** — nie ma prostego sposobu, żeby sprawdzić czy dane są spójne zanim uruchomi się przydział PU.

### Rozwiązanie

Nowy system zastępuje pojedynczy skrypt zestawem wyspecjalizowanych narzędzi, które:

- **Walidują dane** — jeśli nazwa postaci nie pasuje do żadnej zarejestrowanej postaci, system zatrzymuje się i informuje o problemie. Żadne PU nie zostanie przyznane ani pominięte bez wiedzy koordynatora.
- **Automatyzują operacje** — tworzenie postaci, aktualizacja PU, wysyłanie powiadomień Discord — wszystko przez dedykowane komendy zamiast ręcznej edycji plików.
- **Śledzą waluty** — trzy denominacje (Korony, Talary, Kogi) z pełnym rejestrem posiadania, transferów i raportowaniem.
- **Oferują diagnostykę** — przed każdym przydziałem PU można uruchomić sprawdzenie, które wykrywa problemy zawczasu.
- **Zachowują historię** — każda zmiana jest śledzona, z pełnym audytem kto, co i kiedy zmienił.

### Co pozostaje bez zmian

- **Mechanizm PU** — zasady przydziału Punktów Umiejętności nie zmieniają się. Bazowe 1 PU miesięcznie, plus PU za sesje, limit 5, nadmiar przenoszony — wszystko działa tak samo.
- **Powiadomienia Discord** — format i sposób dostarczania powiadomień nie zmienia się.
- **Pliki postaci** — karty postaci w repozytorium (`Postaci/Gracze/*.md`) pozostają w tym samym formacie.
- **Treść sesji** — opisy fabularne, objaśnienia, efekty — nic z tego nie jest zmieniane ani usuwane.

---

## 2. Harmonogram migracji

Migracja jest podzielona na etapy. Nie wszystkie wymagają zaangażowania całego zespołu.

| Etap | Co się dzieje | Kto jest zaangażowany | Szacowany czas |
|---|---|---|---|
| **Przygotowanie** | Koordynator tworzy kopie bezpieczeństwa i konfiguruje nowy system | Koordynator | 1–2 dni |
| **Przeniesienie danych** | Dane graczy i postaci przenoszone do nowego formatu | Koordynator | 1 dzień |
| **Naprawa danych** | Poprawki literówek w sesjach, uzupełnienie brakujących danych | Koordynator, narratorzy | 2–3 dni |
| **Aktualizacja sesji** | Aktywne pliki sesji aktualizowane do nowego formatu zapisu | Koordynator | 1–2 dni |
| **Rejestracja walut** | Zbieranie informacji o stanie walut postaci | Wszyscy | ~1 tydzień |
| **Okres równoległy** | Oba systemy działają jednocześnie, wyniki porównywane | Koordynator | 2–4 tygodnie |
| **Przełączenie** | Oficjalne przejście na nowy system | Koordynator | 1 dzień |

**Łączny czas**: 4–6 tygodni, z czego większość to okres równoległy (oba systemy działają jednocześnie jako zabezpieczenie).

---

## 3. Co zmienia się dla graczy

### Krótka odpowiedź: prawie nic

Z Twojej perspektywy jako gracza, codzienna rozgrywka i interakcje z systemem wyglądają tak samo:

| Aspekt | Przed | Po |
|---|---|---|
| Powiadomienia PU na Discordzie | Tak | Tak, bez zmian |
| Format powiadomień | Tekst z podsumowaniem PU | Taki sam |
| Karta postaci w repozytorium | Aktualizowana przez koordynatora | Aktualizowana przez koordynatora (nowym narzędziem) |
| Zgłaszanie problemów | Kontakt z koordynatorem | Kontakt z koordynatorem |

### Co może się zmienić

1. **Formularz walut** — w ramach migracji możesz zostać poproszony o podanie aktualnego stanu walut Twojej postaci (ile Koron, Talarów i Kogów posiada). To jednorazowa ankieta.

2. **Lepsza wykrywalność błędów** — jeśli Twoja postać nie dostała PU za sesję, koordynator dowie się o tym natychmiast (system go ostrzeże), zamiast odkryć to tygodnie później.

3. **Nowy format deklaracji (zgłaszanie alternatywne)** — jeśli korzystasz z możliwości samodzielnego zgłaszania deklaracji w formacie repozytorium, obowiązuje nowy format z prefiksem `@` przy polach metadanych. Zmienia się wyłącznie zapis metadanych — treść i struktura nagłówka pozostają takie same.

**Dotychczasowy format zgłoszenia alternatywnego:**

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

**Różnice:**
- Pola metadanych mają prefiks `@` (`@Lokacje`, `@PU`, `@Logi`)
- `Lokalizacje` zmienia się na `@Lokacje`
- Logi wpisywane w osobnej linii pod nagłówkiem `@Logi:` (zamiast w jednej linii z `Logi: URL`)
- Reszta — nagłówek, treść, format daty, nazwy postaci — **bez zmian**

> **Uwaga**: Stary format nadal działa — system go rozpoznaje. Nowy format jest jednak preferowany dla nowych zgłoszeń.

### Czego oczekujemy od graczy

- Wypełnienie formularza stanu walut postaci (gdy zostanie rozesłany)
- Zgłaszanie koordynatorowi, jeśli coś wygląda nieprawidłowo w powiadomieniach PU
- Stosowanie nowego formatu z `@` przy samodzielnym zgłaszaniu deklaracji (zgłaszanie alternatywne)

---

## 4. Co zmienia się dla narratorów

### Nowy format zapisu sesji

To **najważniejsza zmiana** dotycząca narratorów. Nowe sesje powinny być zapisywane w zaktualizowanym formacie, który używa prefiksu `@` przy polach metadanych.

**Dotychczasowy format:**

```markdown
### 2025-06-15, Ucieczka z Erathii, Catherine

Opis sesji...

- Lokalizacje:
    - Erathia
    - Bracada
- Logi: https://krisaphalon.ct8.pl/get/sesja
- PU:
    - Crag Hack: 0.3
    - Gem: 0.5
```

**Nowy format:**

```markdown
### 2025-06-15, Ucieczka z Erathii, Catherine

Opis sesji...

- @Lokacje:
    - Erathia
    - Bracada
- @Logi:
    - https://krisaphalon.ct8.pl/get/sesja
- @PU:
    - Crag Hack: 0.3
    - Gem: 0.5
```

**Różnice:**
- Pola metadanych mają prefiks `@` (np. `@Lokacje`, `@PU`, `@Logi`)
- Logi wpisywane w osobnej linii pod nagłówkiem `@Logi:` (zamiast w jednej linii)
- Reszta — treść narracyjna, daty, nagłówki — **bez zmian**

### Nowe możliwości

Nowy format pozwala na dodatkowe pola, których wcześniej nie było:

**Zmiany w świecie gry (`@Zmiany`)** — rejestrowanie trwałych zmian po sesji:

```markdown
- @Zmiany:
    - Crag Hack
        - @lokacja: Bracada (2026-03:)
        - @grupa: Bractwo Miecza (2026-03:)
    - Sandro
        - @status: Nieaktywny (2026-03:)
```

**Informacje celowane (`@Intel`)** — wiadomości do konkretnych osób, grup lub lokacji:

```markdown
- @Intel:
    - Grupa/Nekromanci: Uwaga, Sandro planuje atak na Erathię
    - Solmyr: Prywatna wiadomość
    - Lokacja/Erathia: Ogólna wiadomość dla obecnych w Erathii
```

**Transfery walut (`@Transfer`)** — rejestrowanie transakcji walutowych:

```markdown
- @Transfer: 100 koron, Xeron Demonlord -> Kupiec Orrin
- @Transfer: 50 talarów, Kupiec Orrin -> Kyrre
```

### Najważniejsze zasady

| Zasada | Dlaczego |
|---|---|
| Data zawsze w formacie `YYYY-MM-DD` (np. `2026-03-15`) | Błędny format powoduje pominięcie sesji przy przydziale PU |
| Nazwy postaci w PU muszą dokładnie odpowiadać zarejestrowanym nazwom | Nierozpoznana nazwa zatrzymuje cały przydział PU |
| Wcięcia: 4 spacje na każdy poziom | Mniejsze wcięcie powoduje, że podelementy nie są rozpoznawane |
| Nowe sesje w formacie z `@` | Stary format nadal działa, ale nowy jest preferowany |

### Najczęstsze błędy i jak ich unikać

| Błąd | Skutek | Jak unikać |
|---|---|---|
| `2026-3-15` zamiast `2026-03-15` | Sesja cicho pomijana | Zawsze dwie cyfry: miesiąc i dzień |
| `Krag Hack` zamiast `Crag Hack` | Przydział PU zatrzymany | Sprawdź nazwę z rejestrem postaci |
| Brak dwukropka po nazwie w PU | Wartość PU nierozpoznana | `NazwaPostaci: 0.3` — dwukropek obowiązkowy |
| 2 spacje zamiast 4 we wcięciu | Podelementy nierozpoznane | Używaj 4 spacji na poziom |

### Czego oczekujemy od narratorów

- Przejście na nowy format `@` przy zapisywaniu **nowych** sesji
- Sprawdzanie nazw postaci w PU (czy nie ma literówek)
- Korzystanie z `@Zmiany` do rejestrowania trwałych zmian w świecie
- Zgłaszanie koordynatorowi problemów z formatem

> **Ważne**: Stare sesje **nie muszą** być przepisywane. System automatycznie rozpoznaje i parsuje wszystkie cztery generacje formatu. Aktualizacja jest wymagana tylko dla nowych sesji.

---

## 5. Co zmienia się dla koordynatorów

### Nowy sposób pracy

Zamiast bezpośredniej edycji pliku `Gracze.md` i uruchamiania monolitycznego skryptu, koordynator korzysta z zestawu dedykowanych komend. Każda operacja ma swoją komendę, która waliduje dane i zapobiega typowym błędom.

### Przydział PU — co się zmienia

| Aspekt | Stary system | Nowy system |
|---|---|---|
| Uruchomienie | Menu interaktywne w skrypcie | Komenda z parametrami |
| Walidacja nazw | Brak (ciche pomijanie) | Natychmiastowe zatrzymanie z listą problemów |
| Diagnostyka | Brak | Komenda diagnostyczna do uruchomienia przed przydziałem |
| Duplikaty sesji | Ręczna kontrola | Automatyczna deduplikacja |
| Powiadomienia Discord | Tak | Tak, bez zmian |
| Historia | Plik `pu-sessions.md` | Ten sam plik, kontynuacja |

### Zarządzanie graczami i postaciami

| Operacja | Stary system | Nowy system |
|---|---|---|
| Dodanie gracza | Ręczna edycja `Gracze.md` | Dedykowana komenda |
| Dodanie postaci | Opcja w menu + edycja pliku | Dedykowana komenda (automatyczne PU, plik postaci) |
| Usunięcie postaci | Ręczna edycja | Komenda (soft-delete, zachowuje historię) |
| Zmiana webhooka | Ręczna edycja | Komenda z walidacją URL |
| Dodanie aliasu | Ręczna edycja | Komenda |

### Kluczowa zmiana: `Gracze.md` staje się archiwum

Po migracji plik `Gracze.md` jest **zamrożony** — staje się archiwum historycznym, tylko do odczytu. Wszystkie nowe dane trafiają do pliku `entities.md`, który ma ustrukturyzowany format i jest obsługiwany przez dedykowane komendy.

System przy odczycie **scala oba pliki** automatycznie — żadne dane nie giną. Po prostu nowe zmiany zapisywane są w nowym miejscu.

### Diagnostyka — nowe narzędzie

Przed każdym przydziałem PU koordynator może (i powinien) uruchomić diagnostykę, która sprawdza:

| Co sprawdza | Co to oznacza |
|---|---|
| Nierozwiązane nazwy postaci | Nazwy w PU które nie pasują do żadnej zarejestrowanej postaci |
| Błędne wartości PU | Brakujące lub nienumeryczne wartości |
| Duplikaty | Ta sama postać wymieniona wielokrotnie w jednej sesji |
| Sesje z błędnymi datami | Sesje z danymi PU, które nie zostaną przetworzone z powodu złego formatu daty |
| Przestarzałe wpisy historii | Stare nagłówki sesji w pliku historii, które już nie istnieją w repozytorium |

Diagnostyka daje jasny wynik: **tak/nie** — czy wszystko jest w porządku.

### Czego oczekujemy od koordynatorów

- Przeprowadzenie migracji technicznej zgodnie z [migr.md](migr.md)
- Uruchomienie diagnostyki przed każdym przydziałem PU
- Komunikacja z zespołem o zmianach
- Szkolenie narratorów z nowego formatu sesji

---

## 6. Nowa funkcjonalność: system walut

### Co to jest

Nowy system wprowadza formalne śledzenie walut w grze. Do tej pory waluta nie była rejestrowana centralnie — teraz każda postać, NPC i lokacja mogą mieć przypisane konkretne ilości walut.

### Denominacje

W świecie Nerthus istnieją trzy denominacje walut:

| Waluta | Typ | Wartość |
|---|---|---|
| **Korona Elancka** | Złoto | 1 Korona = 100 Talarów |
| **Talar Hiroński** | Srebro | 1 Talar = 100 Kogów |
| **Kog Skeltvorski** | Miedź | Jednostka bazowa |

### Jak to działa

- **Każda postać** może mieć przypisane waluty w dowolnych denominacjach
- **Transfery** między postaciami rejestrowane są w sesjach (przez narratora) lub bezpośrednio (przez koordynatora)
- **Raporty** pokazują stan posiadania walut w dowolnym momencie
- **Rekoncyliacja** automatycznie wykrywa niespójności (np. ujemny bilans, zagubione transfery)

### Jak zbierzemy początkowe dane

Ponieważ waluta nie była wcześniej formalnie śledzona, musimy zebrać dane o aktualnym stanie posiadania:

1. **Gracze** — otrzymają krótki formularz z pytaniem o stan walut swoich postaci
2. **Narratorzy** — podadzą informacje o budżetach walutowych, którymi dysponują
3. **Koordynatorzy** — ustalą ogólne rezerwy i początkowy stan skarbca

Formularz dla graczy będzie prosty:

```
Nazwa postaci: _______________
Korony (złoto):  _____ sztuk
Talary (srebro): _____ sztuk
Kogi (miedź):    _____ sztuk
```

### Jak waluta będzie rejestrowana w sesjach

Narratorzy będą mogli rejestrować transfery walut bezpośrednio w opisie sesji:

```markdown
- @Transfer: 100 koron, Xeron Demonlord -> Kupiec Orrin
```

System automatycznie odejmie walutę od źródła i doda do celu.

---

## 7. Okres przejściowy

### Jak będzie wyglądał

Przez 2–4 tygodnie oba systemy (stary i nowy) będą działać równolegle. To zabezpieczenie — pozwala porównać wyniki i upewnić się, że nowy system działa poprawnie.

W tym czasie:

- **Przydział PU** — koordynator uruchomi oba systemy i porówna wyniki
- **Nowe sesje** — narratorzy zaczynają pisać w nowym formacie (z `@`)
- **Nowe postacie** — tworzone wyłącznie przez nowy system
- **Stare sesje** — nadal czytelne, nie wymagają zmian

### Kiedy nastąpi przełączenie

Przełączenie na nowy system nastąpi, gdy:

- Co najmniej jeden pełny cykl PU da identyczne wyniki w obu systemach
- Wszyscy aktywni narratorzy będą stosować nowy format
- Nie wystąpią niewyjaśnione rozbieżności

### Czy jest plan awaryjny

Tak. Stary plik danych (`Gracze.md`) nigdy nie jest modyfikowany przez nowy system. Oznacza to, że **w każdej chwili** można wrócić do starego systemu bez utraty oryginalnych danych. Nowy system wyłącznie dopisuje do nowego pliku (`entities.md`).

---

## 8. Najczęściej zadawane pytania

### Ogólne

**P: Czy stracę jakieś dane w wyniku migracji?**

O: Nie. Migracja nie usuwa ani nie modyfikuje istniejących danych. Stary plik `Gracze.md` pozostaje nietknięty jako archiwum. Nowy system czyta dane z obu źródeł jednocześnie.

**P: Czy muszę coś robić od razu?**

O: To zależy od Twojej roli:
- **Gracz** — poczekaj na formularz walut. Poza tym nic się nie zmienia.
- **Narrator** — zacznij pisać nowe sesje w formacie z `@` (stary format nadal działa, ale nowy jest preferowany).
- **Koordynator** — postępuj zgodnie z [migr.md](migr.md).

**P: Co jeśli coś pójdzie nie tak?**

O: Istnieje pełen plan awaryjny z możliwością powrotu do starego systemu na każdym etapie. Dane oryginalne nie są modyfikowane — zawsze można się cofnąć.

### Dla graczy

**P: Czy moje PU się zmienią?**

O: Nie. Mechanizm przydziału PU (1 bazowe + sesyjne, limit 5, nadmiar przenoszony) pozostaje identyczny. Zmieniają się tylko narzędzia, którymi koordynator go obsługuje.

**P: Czy muszę znać nowy format sesji?**

O: Jeśli korzystasz ze [zgłaszania alternatywnego deklaracji](https://nerthus.pl/Mechanika/Deklaracje/#zgłaszanie-alternatywne) (samodzielne wpisywanie deklaracji w formacie repozytorium), to tak — nowe zgłoszenia powinny używać formatu z prefiksem `@` przy polach metadanych (`@Lokacje`, `@PU`, `@Logi`). Jeśli nie korzystasz z tej opcji, format sesji Cię nie dotyczy.

**P: Co z moją kartą postaci?**

O: Karta postaci (plik `.md` w `Postaci/Gracze/`) pozostaje w tym samym formacie. Nowy system aktualizuje ją w ten sam sposób co stary.

**P: Po co pytają mnie o waluty?**

O: Nowy system formalnie śledzi waluty postaci. Żeby mieć poprawny punkt startowy, musimy zebrać informacje o aktualnym stanie posiadania. To jednorazowa ankieta.

### Dla narratorów

**P: Czy muszę przepisać stare sesje?**

O: Nie. System automatycznie rozpoznaje cztery generacje formatu zapisu sesji. Stare sesje działają bez zmian. Nowy format obowiązuje tylko przy pisaniu **nowych** sesji.

**P: Co jeśli zapomnę prefiksu `@`?**

O: Sesja nadal zostanie rozpoznana (jako starszy format), ale nie będą dostępne nowe funkcje (`@Zmiany`, `@Intel`, `@Transfer`). Staraj się używać `@` w nowych sesjach.

**P: Jak sprawdzić, czy nazwa postaci jest poprawna?**

O: Zapytaj koordynatora o aktualną listę zarejestrowanych postaci i ich aliasów. Nazwy są dopasowywane bez rozróżniania wielkich/małych liter, ale muszą być poprawne ortograficznie.

**P: Co to jest `@Intel`?**

O: Intel to mechanizm wysyłania celowanych wiadomości do konkretnych osób, grup lub lokacji przez Discord. Jeśli Twoja sesja generuje informację, którą powinni otrzymać konkretni gracze — wpisz ją jako `@Intel`.

**P: Jak działa `@Transfer`?**

O: `@Transfer` rejestruje transakcję walutową między postaciami. System automatycznie odejmuje walutę od jednej postaci i dodaje drugiej. Format: `@Transfer: ilość denominacja, źródło -> cel`.

### Dla koordynatorów

**P: Czy stary system przestanie działać?**

O: Nie natychmiast. Podczas okresu równoległego oba systemy działają jednocześnie. Stary system zostanie wycofany dopiero po pomyślnej walidacji nowego.

**P: Skąd wezmą się dane w nowym systemie?**

O: Dane zostaną automatycznie wygenerowane z istniejącego pliku `Gracze.md`. To jednorazowy proces (bootstrap), który przenosi wszystkich graczy, postacie, wartości PU, aliasy i webhooki.

**P: Co z historią przydziałów PU?**

O: Nowy system korzysta z **tego samego** pliku historii (`pu-sessions.md`). Żadne przetworzone sesje nie zostaną przetworzone ponownie.

**P: Czy muszę znać PowerShell?**

O: Podstawowa znajomość wystarczy — komendy są zaprojektowane tak, żeby można je skopiować i uruchomić. Dokument techniczny [migr.md](migr.md) zawiera dokładne komendy do skopiowania na każdym etapie.

---

## Dokumenty powiązane

| Dokument | Dla kogo | Opis |
|---|---|---|
| [migr.md](migr.md) | Koordynator | Techniczny przewodnik migracji krok po kroku |
| [docs/Sessions.md](docs/Sessions.md) | Narratorzy | Przewodnik zapisu sesji w nowym formacie |
| [docs/PU.md](docs/PU.md) | Koordynator | Proces miesięcznego przydziału PU |
| [docs/Players.md](docs/Players.md) | Koordynator | Zarządzanie graczami i postaciami |
| [docs/Troubleshooting.md](docs/Troubleshooting.md) | Koordynator, narratorzy | Rozwiązywanie problemów |
| [docs/Glossary.md](docs/Glossary.md) | Wszyscy | Słownik terminów |
