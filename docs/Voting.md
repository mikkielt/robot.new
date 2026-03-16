# Voting Eligibility

## Scope

Before community votes or elections, the Coordinator can check which players qualify based on recent activity measured through PU assignment history.

This guide covers how eligibility is determined, what the lookback period means, and how to read the eligibility report.

For PU calculation mechanics, see [PU.md](PU.md). Voting procedures and rules are managed outside the system.

## Actors and Responsibilities

The Coordinator runs the eligibility check before a vote, reviews the results to confirm which players are eligible, and shares the eligibility list with the voting organizer.

## How Eligibility is Determined

The system replays actual PU assignment runs from the processing history to calculate how much PU each player earned in the recent period. This ensures the eligibility window reflects what was actually processed, not just raw session dates.

By default, the system looks at the last 6 months of PU assignment runs. Only runs whose processing date falls within this window are counted. A player is eligible to vote if the total PU granted to all their characters during the lookback period meets or exceeds the minimum threshold (default: 3.0 PU).

The process works as follows. The system reads the PU processing history to find assignment runs within the lookback period. Runs are grouped by calendar month and their sessions are merged. The PU computation is replayed month-by-month for each character, including overflow pool tracking. Granted PU is summed across all of a player's characters and all months. Players meeting the threshold are marked as eligible.

## Reading the Results

The report lists all players who received PU during the lookback period, showing:

- Player name — the registered player name
- Total PU — sum of all PU granted to all their characters
- Eligible — whether they meet the minimum threshold
- Margonem ID — the player's game account identifier (for cross-referencing)

Eligible players are listed first, followed by ineligible players. Both groups are sorted alphabetically.

## Exceptions and Recovery Actions

| Situation | What happens | Recovery |
|---|---|---|
| No PU history exists | No players are returned | Run PU assignments first |
| No runs in lookback period | Empty result | Extend the lookback period or run PU assignments for recent months |
| Unresolved character in history | That character's PU is silently skipped | Does not affect other characters or players |

## Related Documents

- [PU.md](PU.md) — Monthly PU assignment process
- [Glossary](Glossary.md) — Term definitions
