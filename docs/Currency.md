# Currency Tracking

## Purpose

Currency in the Nerthus world is tracked as physical items that characters can carry, drop, trade, or store. The system records currency holdings, processes transfers between entities during sessions, and provides reconciliation tools to detect discrepancies.

## Scope

This guide covers denominations and exchange rates, how currency holdings are stored, recording transfers in sessions, the currency lifecycle, direct currency operations, the treasury and narrator budgets, and reconciliation checks.

For entity management (creating, updating, removing entities), see [World-State.md](World-State.md). For economic analysis (snapshots, timelines, materialization), see [Economy.md](Economy.md). For how entity names are matched in transfers, see [Name-Resolution.md](Name-Resolution.md).

## Actors and Responsibilities

The Coordinator manages currency reserves and distributes budgets to narrators, creates and adjusts currency holdings outside of sessions, runs reconciliation checks (monthly or as part of PU processing), and reviews currency reports for discrepancies.

The Narrator records currency transfers between characters during sessions using `@Transfer` directives, and for complex scenarios records manual quantity changes in `@Zmiany` blocks.

## Denominations and Exchange Rates

The three denominations are:

| Denomination | Tier | Common short forms |
|---|---|---|
| Korony Elanckie | Gold | koron, korony |
| Talary Hirońskie | Silver | talarów, talary |
| Kogi Skeltvorskie | Copper | kogi, kog |

Exchange rates: 100 Kog = 1 Talar, 100 Talarów = 1 Korona (so 1 Korona = 10,000 Kogi).

## How Currency Is Stored

Every currency holding is recorded as a separate Przedmiot (item) in the entity store. The item name follows the convention "{Denomination} {Owner}" — for example, "Korony Xeron Demonlorda" or "Kogi Gildi Kupców". Each currency item specifies who owns it (the character or group that carries the coins), or where it is (if the coins are dropped at a location instead of carried), and how many coins are held. Currency is either carried by someone or dropped somewhere — never both at the same time.

## Recording Currency Changes in Sessions

There are two ways to record that currency changed hands during a session.

The recommended approach for simple moves is the quick transfer using `@Transfer` when coins move from one character to another:

```markdown
### 2025-06-01, Handel na rynku, Solmyr

- @Transfer: 100 koron, Xeron Demonlord -> Kupiec Orrin
- @Transfer: 50 talarów, Kupiec Orrin -> Kyrre
```

The format is: `- @Transfer: {amount} {denomination}, {source} -> {destination}`

You can use colloquial denomination names ("koron", "talarów", "kogi") — the system recognizes them automatically. Multiple transfers per session are allowed. The system finds the right currency items for the source and destination and adjusts the counts automatically. If a character's currency item does not exist yet, the system warns you — create the item first.

For complex scenarios (e.g., coins found as loot, destroyed, or split across stacks), record changes manually in the Zmiany block:

```markdown
- Zmiany:
    - Korony Xeron Demonlorda
        - @ilość: -20
    - Korony Kupca Orrina
        - @ilość: +20
```

Use `+N` to add coins and `-N` to subtract coins.

## Currency Lifecycle

| Status | What it means |
|---|---|
| Aktywny | Currency is in play. Balance is tracked and reported. |
| Nieaktywny | Currency is out of play (lost account, confiscated, frozen). Balance is preserved but hidden from reports. Can be restored later. |
| Usunięty | The entry was a mistake. Ignored everywhere. |

## Currency Operations

The Coordinator can review currency across the world at any time. Holdings can be filtered by owner (who has the coins) or by denomination (which type of coin). Deleted or inactive entries are hidden by default but can be included when needed for auditing.

The Coordinator can also directly create, adjust, or remove currency holdings outside of sessions. Creating a new currency holding auto-generates the entity name from the denomination and owner (e.g., "Korony Erdamon"). Adjusting a holding's quantity works either to a specific value or by adding/subtracting a delta. Transferring ownership moves coins to a different character or group. Dropping currency places it at a location instead of being carried. Removing a holding performs a soft-delete with a warning if the balance is not zero. These actions are time-stamped and preserved in history, just like session changes.

## The Treasury

Coordinators maintain a reserve pool and distribute budgets to narrators before sessions. Narrators then award currency to player characters during gameplay. This out-of-game supply chain is modeled using a group entity as the treasury (e.g., "Skarbiec Koordynatorów"). The Coordinator creates currency holdings owned by the treasury, then distributes portions to narrators as needed.

The distribution flow works in three steps. First, the Coordinator creates the treasury — a one-time setup where a Grupa entity represents the currency reserve, with initial currency holdings for each denomination. Second, the Coordinator distributes to the narrator before a session by subtracting from the treasury's balance and adding to a narrator's budget, tracked through the entity history. Third, the narrator awards currency to player characters during the session by recording a `@Transfer` in the standard session format, and the system handles the balance adjustments automatically.

The total currency supply across all holders — treasury, narrators, and player characters — should remain constant over time. Monthly reconciliation detects any supply drift, which may indicate a recording error or forgotten adjustment.

## Reconciliation

A monthly reconciliation check flags problems automatically: negative balances (a character has fewer than zero coins, likely a recording error), stale balances (currency unchanged in over 3 months, may need review), orphaned currency (assigned to an inactive character), asymmetric transactions (coins left a character but did not arrive anywhere, or vice versa), and supply tracking (total coins per denomination across the entire world, for detecting drift over time).

Reconciliation can run as a standalone check or as part of the monthly PU process.

## Common Currency Risks

| Risk | What can happen | How to prevent it |
|---|---|---|
| Dual placement | Currency recorded as both carried and dropped at the same time | When moving currency, always end the previous placement before starting the new one |
| Negative quantities | More coins subtracted than available | Reconciliation flags this automatically |
| Phantom creation | Currency created without an in-game source | Only Coordinators should create new currency items |
| Quantity mismatch | Splitting or merging stacks without correct totals | Verify the total stays constant; use @Transfer for simple moves |
| Orphaned currency | Coins belonging to a deleted or inactive character | Reconciliation flags this automatically |
| Multiple stacks | Same character has multiple entries for the same denomination | Allowed — total wealth is the sum of all stacks |
| Accuracy drift | Physical items lost or transferred outside session scope | Monthly reconciliation + periodic baseline resets |

## Expected Outcomes

1. Every currency holding is traceable — ownership, location, and quantity are recorded with dates
2. Session transfers are processed automatically — `@Transfer` directives adjust balances without manual entity editing
3. Reconciliation catches discrepancies — negative balances, orphaned currency, and supply drift are flagged
4. Treasury flow is auditable — distribution from reserve to narrator to player is tracked through the entity history

## Exceptions and Recovery Actions

| Situation | What happens | Recovery |
|---|---|---|
| Transfer references unknown entity | The affected side of the transfer is skipped with a warning | Create the currency entity first, then re-process |
| Negative balance after transfer | Reconciliation flags the entity | Verify the transfer amounts and correct the balance |
| Currency entity has no owner or location | The entity exists but is not assigned | Set the owner or location |
| Non-zero balance on removal | A warning is emitted before soft-delete | Transfer or zero the balance first, or proceed if intentional |

## Related Documents

- [World-State.md](World-State.md) — Entity management and temporal scoping
- [Economy.md](Economy.md) — Economic analysis (snapshots, timelines, materialization)
- [Sessions.md](Sessions.md) — How to record sessions with @Transfer entries
- [Auditing.md](Auditing.md) — Transaction ledger and change history
- [Migration.md](Migration.md) — Currency enrollment during migration (Phase 7)
- [Glossary](Glossary.md) — Term definitions
