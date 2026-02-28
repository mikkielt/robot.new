# Intel & Notifications

## Purpose

This guide explains how the notification system works: how narrators send targeted in-game information (Intel) to specific recipients, how players receive monthly PU updates via Discord, and what happens when notifications fail.

## Scope

**What is included:**

- How Intel targeting works in sessions
- What recipients receive and in what format
- How PU notifications are generated and sent
- What happens when a webhook is missing or a message fails

**What is excluded:**

- PU calculation mechanics (see [PU.md](PU.md))
- Session recording format details (see [Sessions.md](Sessions.md))
- Technical webhook configuration (see the coordinator)

## Actors and Responsibilities

### Narrator

- Adds `@Intel` entries to sessions when targeted information needs to reach specific recipients
- Uses correct targeting syntax (group, location, or direct)

### Coordinator

- Maintains player webhook addresses
- Runs the monthly PU assignment, which triggers PU notifications
- Monitors notification failures and retries manually when needed

### Player

- Receives Discord notifications automatically
- Does not need to take any action

## Intel Notifications

### What is Intel?

Intel is targeted in-game information that a narrator sends to specific recipients as part of a session. It represents things like rumors, discoveries, warnings, or secret information that should reach certain characters, groups, or locations.

### How to write Intel entries

Intel entries are added to the session metadata under `@Intel`:

```markdown
### 2025-06-15, Session Title, Narrator
- @Intel:
    - Solmyr: Usłyszałeś plotkę o skarbie w Smoczej Utopii.
    - Grupa/Nekromanci: Wasza siedziba została odkryta przez straż miejską.
    - Lokacja/Erathia: Burmistrz ogłosił nowe prawo handlowe.
    - Gem, Vidomina: Spotkaliście tajemniczego posłańca.
```

### Targeting options

| Targeting type | Syntax | Who receives the message |
|---|---|---|
| **Direct** | `Name` | The named entity (character, NPC, or player) |
| **Multiple direct** | `Name1, Name2` | Each named entity receives the message |
| **Group** | `Grupa/GroupName` | All entities that are members of the named organization at the session date |
| **Location** | `Lokacja/LocationName` | All entities present in the named location and its sub-locations at the session date |

### How targeting works

- **Group targeting** (`Grupa/Nekromanci`): The system finds all entities with an active `@grupa` membership in the named organization at the time of the session. Each member receives the message.
- **Location targeting** (`Lokacja/Erathia`): The system finds all entities with an active `@lokacja` in Erathia or any location contained within Erathia. This includes sub-locations.
- **Direct targeting** (`Solmyr`): The system resolves the name to a specific entity and sends the message to that entity's webhook.

### Where messages are delivered

Messages are sent via Discord webhooks:
1. If the target entity has its own webhook address configured, that is used
2. For player characters, the owning player's webhook is used as a fallback
3. If no webhook is found, the message is skipped (with a warning)

Organizations, locations, and NPCs can also have their own webhook addresses configured.

## PU Notifications

### When they are sent

PU notifications are sent as part of the monthly PU assignment process, when the coordinator applies results with the notification option enabled.

### What players receive

Each player receives a **single Discord message** covering all their characters:

> Postać "Crag Hack" (Gracz "Roland") otrzymuje 3.50 PU.
> Aktualna suma PU tej Postaci: 48.50, wykorzystano PU nadmiarowe: 1.50

If a player has multiple characters, each one appears as a separate paragraph in the same message.

### Message content

For each character, the notification includes:
- Character name and player name
- Amount of PU awarded this month
- Current total PU after the award
- If overflow PU was consumed: how much was used
- If overflow PU remains: how much is stored for future months

### Bot identity

PU notifications are sent with the bot name "Bothen".

## What Happens When Things Go Wrong

### Missing webhook address

| Notification type | What happens |
|---|---|
| **PU notification** | PU is still calculated and applied to the character. The Discord message is skipped with a warning. Other players' notifications continue normally. |
| **Intel message** | The message is skipped for that recipient. Other recipients still receive their messages. |

The coordinator can add the webhook address later and re-send manually if needed.

### Message delivery failure

If a Discord message fails to send (network error, invalid webhook, etc.):
- The failure is logged
- Other messages continue sending - one failure does not block the rest
- The coordinator can retry manually

### Name resolution failure

If an Intel target name cannot be resolved to a known entity:
- A warning is generated
- The message is skipped for that target
- Other Intel entries in the same session are processed normally

## Expected Outcomes

1. **Intel reaches the right people** - group and location fan-out ensures all relevant entities are notified
2. **PU notifications are comprehensive** - each player gets a single message covering all their characters
3. **Failures are isolated** - one failed notification does not prevent others from being sent
4. **Missing webhooks are non-blocking** - the system continues processing and logs warnings

## Related Documents

- [PU.md](PU.md) - Monthly PU assignment process
- [Sessions.md](Sessions.md) - How to record sessions with Intel entries
- [Players.md](Players.md) - How to configure webhook addresses
- [Glossary](Glossary.md) - Term definitions
