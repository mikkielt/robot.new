# Intel & Notifications

## Scope

This guide explains how the notification system works: how narrators send targeted in-game information (Intel) to specific recipients, how players receive monthly PU updates via Discord, and what happens when notifications fail.

The guide covers Intel targeting in sessions, what recipients receive and in what format, how PU notifications are generated and sent, and what happens when a webhook is missing or a message fails.

For PU calculation mechanics, see [PU.md](PU.md). For session recording format details, see [Sessions.md](Sessions.md). For technical webhook configuration, see the Coordinator.

## Actors and Responsibilities

The Narrator adds `@Intel` entries to sessions when targeted information needs to reach specific recipients, using the correct targeting syntax (group, location, or direct).

The Coordinator maintains player webhook addresses, runs the monthly PU assignment (which triggers PU notifications), and monitors notification failures and retries manually when needed.

The Player receives Discord notifications automatically and does not need to take any action.

## Intel Notifications

Intel is targeted in-game information that a narrator sends to specific recipients as part of a session. It represents things like rumors, discoveries, warnings, or secret information that should reach certain characters, groups, or locations.

Intel entries are added to the session metadata under `@Intel`:

```markdown
### 2025-06-15, Session Title, Narrator
- @Intel:
    - Solmyr: Usłyszałeś plotkę o skarbie w Smoczej Utopii.
    - Grupa/Nekromanci: Wasza siedziba została odkryta przez straż miejską.
    - Lokacja/Erathia: Burmistrz ogłosił nowe prawo handlowe.
    - Gem, Vidomina: Spotkaliście tajemniczego posłańca.
```

| Targeting type | Syntax | Who receives the message |
|---|---|---|
| Direct | `Name` | The named entity (character, NPC, or player) |
| Multiple direct | `Name1, Name2` | Each named entity receives the message |
| Group | `Grupa/GroupName` | All entities that are members of the named group at the session date |
| Location | `Lokacja/LocationName` | All entities present in the named location and its sub-locations at the session date |

Group targeting (`Grupa/Nekromanci`) finds all entities with an active `@grupa` membership in the named group at the time of the session. Each member receives the message. Location targeting (`Lokacja/Erathia`) finds all entities with an active `@lokacja` in Erathia or any location contained within Erathia, including sub-locations. Direct targeting (`Solmyr`) resolves the name to a specific entity and sends the message to that entity's webhook.

Messages are sent via Discord webhooks. If the target entity has its own webhook address configured, that is used. For player characters, the owning player's webhook is used as a fallback. If no webhook is found, the message is skipped with a warning. Groups, locations, and NPCs can also have their own webhook addresses configured.

## PU Notifications

PU notifications are sent as part of the monthly PU assignment process, when the Coordinator applies results with the notification option enabled.

Each player receives a single Discord message covering all their characters:

> Postać "Crag Hack" (Gracz "Roland") otrzymuje 3.50 PU.
> Aktualna suma PU tej Postaci: 48.50, wykorzystano PU nadmiarowe: 1.50

If a player has multiple characters, each one appears as a separate paragraph in the same message.

For each character, the notification includes the character name and player name, amount of PU awarded this month, current total PU after the award, how much overflow PU was consumed (if applicable), and how much overflow PU remains stored for future months (if applicable).

PU notifications are sent with the bot name "Bothen".

## Manual Announcements

The Coordinator can send a one-off announcement to any Discord channel via webhook, independent of PU or Intel processing.

This is useful for campaign-wide announcements (rule changes, schedule updates), ad-hoc messages that are not tied to a specific session, or re-sending a previously failed notification to a specific webhook.

The Coordinator provides a target webhook URL, enters a title and message body, and the system shows a preview for confirmation. On confirmation, the message is sent immediately. The announcement is formatted with the title in bold, followed by the message body. It is a one-time send with no automatic retry — if the delivery fails, the Coordinator sees an error and can retry manually.

## What Happens When Things Go Wrong

| Notification type | What happens when the webhook address is missing |
|---|---|
| PU notification | PU is still calculated and applied to the character. The Discord message is skipped with a warning. Other players' notifications continue normally. |
| Intel message | The message is skipped for that recipient. Other recipients still receive their messages. |

The Coordinator can add the webhook address later and re-send manually if needed.

If a Discord message fails to send (network error, invalid webhook, etc.), the failure is logged, other messages continue sending (one failure does not block the rest), and the Coordinator can retry manually.

## Delivery Tracking

Every Discord message sent by the system — PU notifications, Intel, announcements, and re-sends — is recorded in a delivery log with a timestamp, outcome (success or failure), the operation type, the recipient, and the HTTP status code. The Coordinator can review delivery history filtered by recipient, operation, date range, or failure status. Failed PU notifications can be re-sent from the CLI: the system identifies the failed delivery, reconstructs the original notification, and sends it again. Re-sends are recorded as separate entries in the delivery log. The delivery history is also available through the Campaign Data API.

If an Intel target name cannot be resolved to a known entity, a warning is generated, the message is skipped for that target, and other Intel entries in the same session are processed normally. Intel uses stricter name matching than PU processing. Small typos that PU matching would tolerate via fuzzy correction will cause Intel to skip the target entirely. Narrators should ensure that Intel target names match a registered name or alias exactly, or at least closely enough for declension matching to work.

## Expected Outcomes

- Intel reaches the right people — group and location fan-out ensures all relevant entities are notified
- PU notifications are comprehensive — each player gets a single message covering all their characters
- Failures are isolated — one failed notification does not prevent others from being sent
- Missing webhooks are non-blocking — the system continues processing and logs warnings

## Related Documents

- [PU.md](PU.md) — Monthly PU assignment process
- [Sessions.md](Sessions.md) — How to record sessions with Intel entries
- [Players.md](Players.md) — How to configure webhook addresses
- [Campaign Data API](REST-API.md) — Delivery history available through the API
- [Glossary](Glossary.md) — Term definitions
