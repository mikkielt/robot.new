# Session Participation Graph

## Overview

The session participation graph records which entities (characters, NPCs, locations, organizations, story threads) took part in which sessions. Coordinators use it to answer questions like "which sessions did Xeron appear in?" and "who did Xeron co-participate with most often?"

## Actors and Responsibilities

The Coordinator builds the participation index after setting up the repository or after significant changes, queries the graph to investigate entity relationships across sessions, and rebuilds the index periodically to account for new entities or name changes.

The Narrator queries entity session profiles to understand character history, views narrator session statistics to review own sessions, and compares participation of multiple entities to analyze relationships. Session file placements and metadata (PU, @Zmiany, @Transfer) are automatically analyzed.

## Inputs Required

- A complete set of session files in the repository
- For best results, session files placed in entity directories (character, NPC, location folders)
- For Gen3+ sessions, structured metadata (@PU, @Zmiany, @Transfer) provides richer involvement data

## How Involvement Is Detected

The system detects entity involvement at three confidence levels:

| Level | What it means | Available for |
|---|---|---|
| High confidence | The session file is physically placed in the entity's directory | All session formats |
| Structured data | The entity appears in PU awards, @Zmiany directives, @Transfer operations, or @Intel targets | Gen3 and Gen4 sessions only |
| Text mention | The entity's name appears in the session body text | All session formats |

When an entity is detected at multiple levels, the highest-confidence detection is used. PU weights (when available) indicate the relative importance of an entity's involvement in that session.

Sessions from before 2024 (Gen1 and Gen2 formats) only support two detection methods: file placement and text mentions. These sessions show binary participation — the entity was either present or absent, with no weight information. Sessions from 2024 onward (Gen3 and Gen4) include structured metadata that provides graduated involvement weights and richer relationship data.

## Query Modes

The graph supports eight query modes.

Sessions for an entity shows all sessions where a given entity participated, ordered with involvement details. Each result includes the session date, format generation, detection level, and PU weight (if available). For example, querying sessions for "Xeron" might show 3 sessions at high confidence (file placement), 2 with PU weights of 0.3 and 0.5, and 1 where Xeron was only mentioned in the body text.

Co-participants shows all entities that co-participated with a given entity, ranked by the number of shared sessions. This answers "who does this entity interact with most?" For example, querying co-participants for "Xeron" might show Erathia (shared 3 sessions), Sandro (shared 2 sessions), Borimdir (shared 1 session).

Session participants shows all entities that participated in a specific session, with their detection level and weight. This answers "who was involved in this session?"

Summary statistics shows aggregate statistics: total sessions indexed, total participations, breakdown by detection level, and distribution across format generations.

Entity session profile is a single-call comprehensive profile for an entity: total sessions, date range, tier breakdown, total PU weight, top 5 co-participants, and monthly activity trend. Ideal for quickly understanding a character's full session history.

Narrator session profile shows statistics for a narrator: how many sessions they narrated, date range, unique participants, participant type distribution, and average party size. Answers "what is my track record as narrator?"

Participation comparison compares 2+ entities: finds sessions they share, sessions exclusive to each, and pairwise overlap percentages. Answers "how much do these characters' stories intertwine?"

Participation leaderboard ranks entities by session count with tier breakdown. Filters by entity type and date range. Answers "who are the most active characters/locations/NPCs?"

## Staleness Tracking

When entity data changes — such as a name change, a new alias, or entity removal — the system automatically marks the session graph index as potentially stale. This means that text-based mentions (the lowest confidence tier) may no longer reflect the current entity names.

When the index is stale, the CLI displays a warning at the top of the session graph screen advising the Coordinator to rebuild the index, the health dashboard badge for the session graph may show a warning indicator, and query results remain available but may include outdated text-mention matches. The staleness flag is cleared automatically when the Coordinator performs a full index rebuild.

## Verifying Index Integrity

The integrity check validates the index against the current repository state, looking for stale name versions (entity names changed since last build, so text-mention matches may be wrong), orphaned sessions (indexed sessions no longer in the repository), missing sessions (repository sessions not yet indexed), and empty sessions (indexed sessions with zero participants).

Run this check before trusting graph results, especially after entity changes or session edits.

## Keeping the Index Current

The index needs to be rebuilt when the system is set up for the first time (full build required), when new sessions are added or existing sessions are edited (incremental update), or when new entities are added to the entity store (the system detects name set changes and triggers a full rebuild automatically).

Incremental updates only reprocess sessions affected by recent changes, making routine updates fast. If the system detects that the set of known entity names has changed, it automatically performs a full rebuild to ensure text mentions are re-evaluated against the updated name list.

Additionally, when a session is edited through the system, an eager refresh automatically updates the file-placement and structured-metadata tiers (high confidence and structured data) for the affected session in the graph index. This keeps the index up-to-date for day-to-day edits without requiring a full rebuild. The text-mention tier requires a full rebuild to update.

## Expected Outcomes

1. After building the index, every session in the repository has a participation record
2. Entities that appear in session file placements are always detected (regardless of format generation)
3. Entities with PU awards, @Zmiany, or @Transfer entries in Gen3+ sessions are detected with their structured data
4. Entity name mentions in body text are detected as lower-confidence participation
5. Co-participation queries correctly reflect shared session counts across the full session history

## Exceptions and Recovery Actions

| Situation | What happens | Recovery |
|---|---|---|
| No index exists | Queries return empty results with a warning | Build the index with a full scan |
| Entity not found in any session | Query returns no results | Verify the entity name; try searching with aliases. Check whether sessions exist for this entity |
| Older sessions show no weights | Gen1/Gen2 sessions only have binary (yes/no) participation | This is expected — structured metadata was available starting from Gen3 |
| Entity appears unexpectedly | Low-confidence text mention may be a false positive (common name matched in body text) | Filter to high-confidence results only by restricting to the file-placement level |
| Staleness warning shown in CLI | Entity names changed since the last full rebuild; text-mention results may be outdated | Perform a full index rebuild to clear the staleness flag and re-evaluate text mentions against updated entity names |
| Index seems stale after adding entities | New entity names are not matched in old session body text | Rebuild the index fully — the system should detect name set changes automatically, but a manual full rebuild resolves edge cases |
| Git history unavailable | Incremental mode falls back to a full scan automatically | No action needed |

## Related Documents

- [Sessions.md](Sessions.md) — Session formats and recording rules
- [PU.md](PU.md) — PU assignment and weights
- [Location-Graph.md](Location-Graph.md) — Location relationship analysis
- [Session-Integrity.md](Session-Integrity.md) — Session content verification
