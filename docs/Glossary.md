# Glossary

This glossary explains common English terms, Polish system terms, and Markdown tags used across the Robot documentation. Entries are grouped by topic.

When a Markdown tag appears below, it is shown exactly as it should be written in a session.

---

## Contents

- [Roles](#roles)
- [Entities & World State](#entities--world-state)
- [Sessions](#sessions)
- [Session Metadata Tags](#session-metadata-tags)
- [Session Analysis & Integrity](#session-analysis--integrity)
- [Skill Points (PU)](#skill-points-pu)
- [Currency](#currency)
- [Notifications & Intel](#notifications--intel)
- [System & Tooling](#system--tooling)

---

## Roles

People who interact with the campaign or operate the system.

| English term | Polish counterpart | Meaning in plain language |
|---|---|---|
| Coordinator | koordynator | The person responsible for operational workflows such as PU processing, audits, and repository maintenance. |
| Narrator | Narrator (Mistrz Gry) | The person leading or moderating a session. |
| Player | Gracz | A real person participating in the campaign. |

---

## Entities & World State

Named elements of the game world tracked by the system. Every entity lives in the entity store and its properties are recorded over time using temporal scoping.

| English term / tag | Polish counterpart | Meaning in plain language |
|---|---|---|
| Active Character | Aktywna postac | The player character currently treated as a player's main character. |
| Alias | Alias | An alternative name for the same entity, used for recognition and matching. |
| Character File | Plik postaci | A Markdown record holding character-specific details such as reputation, condition, and special items. |
| Entity | Encja (element swiata) | Any named world element tracked by the system, such as a character, location, group, map, player, or item. |
| Entity Store | Rejestr encji | The central registry that holds base properties and history for tracked world entities. |
| Entity Type | Typ encji | The category of an entity: Player (Gracz), Character (Postac), Location (Lokacja), Map (Mapa), Group (Grupa), or Item (Przedmiot). |
| Group | Grupa | A faction, organization, or other named collection of entities. |
| Location | Lokacja | A place in the game world where entities can be present. |
| Location Hierarchy | Hierarchia lokacji | The parent-child relationship between locations, where one location is contained inside another. |
| Map | Mapa | A concrete game map or interior floor tied to a location. |
| NPC | Postac niezalezna (NPC) | A character not controlled by a player. |
| Player Character | Postac gracza | A character controlled by a player. |
| Soft Delete | Miekkie usuniecie | Marking something as removed for future queries without erasing its history. |
| Status | Status | The lifecycle state of an entity, such as active, inactive, or removed. |
| Temporal Scoping | Zakres czasowy | Recording when a value is active so the system can answer historical state questions. |

---

## Sessions

A session is a single game event. The system reads sessions to extract PU awards, world-state changes, notifications, and other data.

| English term | Polish counterpart | Meaning in plain language |
|---|---|---|
| Processed Session | Przetworzona sesja | A session already counted in a workflow, usually PU processing, so it is not counted twice. |
| Session | Sesja | One game event with a date, title, narrator, metadata, and outcomes. |
| Session Format Generation | Generacja formatu sesji | One of the historical session-writing styles the system understands, from older formats to the current Gen4 format. |
| Session Header | Naglowek sesji | The unique session title line in the form `### YYYY-MM-DD, Title, Narrator`. |
| Session Log | Log sesji | A transcript or log link that records what happened during a session. |

---

## Session Metadata Tags

Fields written inside a session block. Each tag is introduced by a `@`-prefixed bullet and holds structured information that the system reads and processes.

| English term / tag | Polish counterpart | Meaning in plain language |
|---|---|---|
| Intel (`@Intel`) | `@Intel` | The session field for targeted in-world information such as rumors, warnings, or discoveries sent to chosen recipients. |
| PU Block (`@PU`) | `@PU` | The session field that lists one or more character PU entries for that session. |
| PU Entry | Wpis PU | A single line inside `@PU` that gives one character and the PU value earned in that session. |
| Quantity (`@ilosc`) | `@ilosc` | The quantity field used for stackable items such as currency. |
| Restricted Topic (Trigger) | Ograniczony temat (trigger) | A topic recorded for warnings or filtering so players can be alerted to sensitive content. |
| Session Date Override (`@Data`) | `@Data` | An explicit date field that replaces the date read from the session header. |
| Session Locations (`@Lokacje`) | `@Lokacje` | The list of meaningful locations where important action happened during a session. |
| Session Log Links (`@Logi`) | `@Logi` | The metadata field used to attach one or more session log links. |
| Session Narrator Override (`@Narrator`) | `@Narrator` | An explicit narrator field that replaces narrator resolution from the header. |
| Transfer (`@Transfer`) | `@Transfer` | A session entry that moves currency from one entity to another. |
| World-State Change (`@Zmiany`) | `@Zmiany` | A session entry that records lasting updates to entity data such as location, group, or status. |

---

## Session Analysis & Integrity

Tools that index and verify session data over the life of the campaign.

| English term | Polish counterpart | Meaning in plain language |
|---|---|---|
| Location Graph | Graf lokacji | A combined picture of how locations connect through hierarchy, doors, session metadata, and logs. |
| Map Suffix Stripping | Obcinanie sufiksow map | Automatic removal of floor numbers, room labels, and direction markers from game-map names so they can match a registered location entity. |
| Session Graph | Graf uczestnictwa sesji | An index of which entities took part in which sessions and how strong that participation was. |
| Session Hash / Fingerprint | Hash / odcisk sesji | The stored content signature used to detect unexpected edits to a session. |

---

## Skill Points (PU)

PU (Punkty Umiejetnosci) are skill points assigned to characters through campaign play. A monthly assignment run calculates how much each character earns and records it in the processing history.

| English term | Polish counterpart | Meaning in plain language |
|---|---|---|
| Earned PU | PU zdobyte | PU gained through activity during play. |
| Granted PU | Przyznane PU | The final PU a character receives for a month after caps and overflow are applied. |
| Lookback Period | Okres wsteczny | The recent time window used when checking voting eligibility. |
| Monthly Cap | Miesieczny limit PU | The maximum PU a character can receive in one month before overflow rules apply. |
| Monthly PU Assignment | Miesieczny przydzial PU | The regular process that calculates and grants PU for the selected period. |
| Overflow PU / Overflow Pool | PU nadmiarowe / pula nadmiarowa | PU carried forward when a month's result goes over the cap, and later used to supplement weaker months. |
| Processing History | Historia przetwarzania | The record of past PU processing runs and the sessions included in them. |
| PU (Skill Points) | Punkty Umiejetnosci (PU) | Skill points assigned to characters as part of campaign progression. |
| Starting PU | PU startowe | The baseline PU a character begins with. |
| Total PU | PU suma | The character's overall PU total. |
| Voting Eligibility | Uprawnienia do glosowania | Whether a player qualifies to vote based on recent PU history. |

---

## Currency

In-game money is tracked as item entities with quantities and ownership. Three denominations with fixed exchange rates make up the currency system.

| English term / tag | Polish counterpart | Meaning in plain language |
|---|---|---|
| Currency | Waluta | In-game money tracked as item entities with quantities and ownership or location. |
| Currency Denomination | Nominal waluty | One of the three money types: Korona, Talar, or Kog. |
| Currency Reconciliation | Uzgodnienie waluty | A consistency check that looks for impossible balances, missing links, or other currency-data problems. |
| Kog (Copper) | Kog Skeltvorski | The lowest-value currency denomination. |
| Korona (Gold) | Korona Elancka | The highest-value currency denomination. 1 Korona = 100 Talarow. |
| Narrator Budget | Budzet narratora | Currency distributed to a narrator before play so it can later be awarded in sessions. |
| Talar (Silver) | Talar Hironski | The mid-value currency denomination. 1 Talar = 100 Kogow. |
| Transaction Ledger | Rejestr transakcji | A chronological report of all currency transfers recorded in sessions. |
| Treasury | Skarbiec | A group representing the campaign's reserve pool of out-of-game currency. |

---

## Notifications & Intel

The system delivers automated notifications to players via Discord and routes targeted in-game messages (Intel) to the correct recipients.

| English term | Polish counterpart | Meaning in plain language |
|---|---|---|
| Group Targeting | Targetowanie grupy | Sending Intel to all entities that belong to a specific group at the session date. |
| Location Targeting | Targetowanie lokacji | Sending Intel to everyone present in a location and its sub-locations at the session date. |
| Notification | Powiadomienie | An automated or reconstructed message about PU, Intel, or other system events. |
| Webhook | Webhook | The delivery address used for automated notifications. |

---

## Related Documents

- [Auditing](Auditing.md)
- [CLI](CLI.md)
- [Location-Graph](Location-Graph.md)
- [Migration](Migration.md)
- [Notifications](Notifications.md)
- [Players](Players.md)
- [PU](PU.md)
- [Session-Graph](Session-Graph.md)
- [Session-Integrity](Session-Integrity.md)
- [Session-Logs](Session-Logs.md)
- [Sessions](Sessions.md)
- [Troubleshooting](Troubleshooting.md)
- [Voting](Voting.md)
- [World-State](World-State.md)
- [Currency](Currency.md)
- [Economy](Economy.md)
- [Name-Resolution](Name-Resolution.md)
