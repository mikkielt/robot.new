# Session Participation Graph

## Purpose

The session participation graph records which entities (characters, NPCs, locations, organizations, story threads) took part in which sessions. Coordinators use it to answer questions like "which sessions did Xeron appear in?" and "who did Xeron co-participate with most often?"

## Scope

**What is included:**

- Building and updating a participation index across all sessions in the repository
- Querying which sessions an entity participated in, with confidence levels
- Finding entities that frequently co-participated with a given entity
- Listing all participants of a specific session
- Aggregate statistics on session participation by format generation

**What is excluded:**

- Session content and formatting (see [Sessions.md](Sessions.md))
- PU assignment and calculation (see [PU.md](PU.md))
- Session integrity and tamper detection (see [Session-Integrity.md](Session-Integrity.md))
- Location connections and spatial relationships (see [Location-Graph.md](Location-Graph.md))

## Actors and Responsibilities

### Coordinator

- Builds the participation index after setting up the repository or after significant changes
- Queries the graph to investigate entity relationships across sessions
- Rebuilds the index periodically to account for new entities or name changes

### Narrator

- Queries entity session profiles to understand character history
- Views narrator session statistics to review own sessions
- Compares participation of multiple entities to analyze relationships
- Session file placements and metadata (PU, @Zmiany, @Transfer) are automatically analyzed

## Inputs Required

- A complete set of session files in the repository
- For best results: session files placed in entity directories (character, NPC, location folders)
- For Gen3+ sessions: structured metadata (@PU, @Zmiany, @Transfer) provides richer involvement data

## How Involvement Is Detected

The system detects entity involvement at three confidence levels:

| Level | What it means | Available for |
|---|---|---|
| **High confidence** | The session file is physically placed in the entity's directory | All session formats |
| **Structured data** | The entity appears in PU awards, @Zmiany directives, @Transfer operations, or @Intel targets | Gen3 and Gen4 sessions only |
| **Text mention** | The entity's name appears in the session body text | All session formats |

When an entity is detected at multiple levels, the highest-confidence detection is used. PU weights (when available) indicate the relative importance of an entity's involvement in that session.

### Why Older Sessions Show Less Detail

Sessions from before 2024 (Gen1 and Gen2 formats) only support two detection methods: file placement and text mentions. These sessions show binary participation — the entity was either present or not. There is no weight information.

Sessions from 2024 onward (Gen3 and Gen4) include structured metadata that provides graduated involvement weights and richer relationship data.

## Querying the Graph

The graph supports four query modes:

### Sessions for an Entity

Shows all sessions where a given entity participated, ordered with involvement details. Each result includes the session date, format generation, detection level, and PU weight (if available).

> Querying sessions for "Xeron" might show: 3 sessions at high confidence (file placement), 2 with PU weights of 0.3 and 0.5, and 1 where Xeron was only mentioned in the body text.

### Co-Participants

Shows all entities that co-participated with a given entity, ranked by the number of shared sessions. This answers "who does this entity interact with most?"

> Querying co-participants for "Xeron" might show: Erathia (shared 3 sessions), Sandro (shared 2 sessions), Borimdir (shared 1 session).

### Session Participants

Shows all entities that participated in a specific session, with their detection level and weight. This answers "who was involved in this session?"

### Summary Statistics

Shows aggregate statistics: total sessions indexed, total participations, breakdown by detection level, and distribution across format generations.

### Entity Session Profile

A single-call comprehensive profile for an entity: total sessions, date range, tier breakdown, total PU weight, top 5 co-participants, and monthly activity trend. Ideal for quickly understanding a character's full session history.

### Narrator Session Profile

Statistics for a narrator: how many sessions they narrated, date range, unique participants, participant type distribution, and average party size. Answers "what is my track record as narrator?"

### Participation Comparison

Compares 2+ entities: finds sessions they share, sessions exclusive to each, and pairwise overlap percentages. Answers "how much do these characters' stories intertwine?"

### Participation Leaderboard

Entities ranked by session count with tier breakdown. Filters by entity type and date range. Answers "who are the most active characters/locations/NPCs?"

## Verifying Index Integrity

The integrity check (`Test-SessionGraphIntegrity`) validates the index against current repository state:

- **Stale name version**: entity names changed since last build (Tier 2 matches may be wrong)
- **Orphaned sessions**: indexed sessions no longer in the repository
- **Missing sessions**: repository sessions not yet indexed
- **Empty sessions**: indexed sessions with zero participants

Run this check before trusting graph results, especially after entity changes or session edits.

## Keeping the Index Current

The index needs to be rebuilt when:

- The system is set up for the first time (full build required)
- New sessions are added or existing sessions are edited (incremental update)
- New entities are added to the entity store (the system detects name set changes and triggers a full rebuild automatically)

Incremental updates only reprocess sessions affected by recent changes, making routine updates fast. If the system detects that the set of known entity names has changed, it automatically performs a full rebuild to ensure text mentions are re-evaluated against the updated name list.

## Expected Outcomes

1. After building the index, every session in the repository has a participation record
2. Entities that appear in session file placements are always detected (regardless of format generation)
3. Entities with PU awards, @Zmiany, or @Transfer entries in Gen3+ sessions are detected with their structured data
4. Entity name mentions in body text are detected as lower-confidence participation
5. Co-participation queries correctly reflect shared session counts across the full session history

## Exceptions and Recovery Actions

| Situation | What happens | Recovery |
|---|---|---|
| **No index exists** | Queries return empty results with a warning | Build the index with a full scan |
| **Entity not found in any session** | Query returns no results | Verify the entity name; try searching with aliases. Check whether sessions exist for this entity |
| **Older sessions show no weights** | Gen1/Gen2 sessions only have binary (yes/no) participation | This is expected — structured metadata was not available before Gen3 |
| **Entity appears unexpectedly** | Low-confidence text mention may be a false positive (common name matched in body text) | Filter to high-confidence results only by restricting to the file-placement level |
| **Index seems stale after adding entities** | New entity names are not matched in old session body text | Rebuild the index fully — the system should detect name set changes automatically, but a manual full rebuild resolves edge cases |
| **Git history unavailable** | Incremental mode falls back to a full scan automatically | No action needed |

## Related Documents

- [Sessions.md](Sessions.md) — session formats and recording rules
- [PU.md](PU.md) — PU assignment and weights
- [Location-Graph.md](Location-Graph.md) — location relationship analysis
- [Session-Integrity.md](Session-Integrity.md) — session content verification
