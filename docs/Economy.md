# Economic Analysis

## Purpose

Beyond tracking individual currency holdings and transfers, the system provides tools for analyzing the broader economic picture. These tools help the Coordinator answer strategic questions about the game economy — how much currency is in play, whether the supply is growing or shrinking, and whether physical game items match the bookkeeping records.

## Scope

This guide covers the economic snapshot, economic timeline, and materialization report.

For currency holdings, transfers, and reconciliation, see [Currency.md](Currency.md). For entity management, see [World-State.md](World-State.md).

## Actors and Responsibilities

The Coordinator uses economic analysis tools to monitor the health of the game economy, plan budget distributions, investigate anomalies, and audit the relationship between physical and virtual currency.

## Economic Snapshot

The economic snapshot answers "What does the economy look like right now?" It gives the Coordinator a complete picture of the economy at a specific point in time: supply breakdown by denomination and by physical vs virtual, wealth distribution including the Gini coefficient (0 means everyone has equal wealth, 1 means one entity holds everything), top holders ranked by total wealth, and transaction volume from @Transfer directives.

Physical currency is owned by player characters (actual Margonem items), while virtual currency is held by NPCs, groups, or treasuries (RP bookkeeping only).

Use the snapshot before distributing new budgets, before creating new currency holdings, or at the start of each month alongside reconciliation. A high Gini coefficient may indicate wealth concentrating in too few hands. A large gap between physical and virtual supply is normal for NPC and treasury holdings but unexpected for player characters. If top holders are dominated by treasury or narrator accounts, currency may not be reaching players effectively. Snapshots can be scoped to a specific denomination, owner, or point in time.

## Economic Timeline

The economic timeline answers "How has the economy changed over time?" It shows monthly trend data over a date range: total supply in circulation (in Kogi base units), physical vs virtual supply split, and number of @Transfer transactions per month.

Use it during quarterly reviews, when planning long-term economic policy, or when investigating a suspected anomaly such as a sudden supply jump. Steady supply growth is expected if the treasury regularly distributes budgets, but sudden spikes may indicate a recording error. A month with zero transactions may mean currency changes were recorded as manual Zmiany instead of @Transfer. A shift from virtual-heavy to physical-heavy supply means more currency is reaching player characters.

## Materialization Report

The materialization report answers "Does the physical currency in the game match what the books say?" It analyzes the relationship between physical and virtual currency: per-denomination breakdown (what percentage is physically held vs virtual bookkeeping), per-player breakdown (how much physical currency each player holds across all characters), and orphaned physical currency (assigned to inactive or removed player characters, representing physical Margonem items that may need to be returned to the Coordinator).

Use this report when onboarding or offboarding players, during periodic audits, or when a player reports a discrepancy. Orphaned physical currency is the most actionable finding — each entry represents real game items that a departing player's character still holds and the Coordinator should arrange recovery.

## Expected Outcomes

1. Supply visibility — the Coordinator can see total currency in circulation, broken down by denomination, owner type, and physical vs virtual
2. Trend tracking — monthly timelines reveal supply growth, transaction volume changes, and shifts between physical and virtual currency
3. Player accountability — per-player physical currency breakdowns ensure game items match bookkeeping records
4. Orphan detection — inactive characters holding physical currency are surfaced for recovery

## Related Documents

- [Currency.md](Currency.md) — Currency holdings, transfers, and reconciliation
- [World-State.md](World-State.md) — Entity management and temporal scoping
- [Auditing.md](Auditing.md) — Transaction ledger and change history
- [Glossary](Glossary.md) — Term definitions
