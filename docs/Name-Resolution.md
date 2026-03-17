# Name Matching and Resolution

## Purpose

The system automatically matches entity names in session text — PU entries, Zmiany blocks, @Transfer directives, and Intel targets — to registered entities and players. It handles Polish grammatical forms, aliases, and small typos so that Narrators do not need to type exact canonical names every time.

## Scope

This guide covers how name matching works, what strategies the system uses, when matching fails, and how to fix unresolved names.

For registering entities and aliases, see [World-State.md](World-State.md). For diagnosing PU assignment failures caused by unresolved names, see [Troubleshooting.md](Troubleshooting.md). For player and character registration, see [Players.md](Players.md).

## Actors and Responsibilities

The Narrator writes entity names in sessions using registered names, aliases, or close approximations. The system handles common Polish grammatical forms automatically.

The Coordinator registers aliases for entities that are frequently referenced by alternative names, reviews unresolved name warnings, and adds missing entities or aliases when the system cannot match a name.

## How Name Matching Works

When the system encounters a name in session text, it tries four strategies in order. As soon as one succeeds, the match is returned.

The first strategy is exact matching. The system checks whether the name matches any registered entity name, alias, slug, or Nerthus name (case-insensitive). This handles the majority of cases.

> "Crag Hack" matches the registered character name "Crag Hack".
> "Mroczny Mag" matches the alias registered for "Sandro".
> "komnata-rady-ratusz" matches the slug for the correct "Komnata Rady" entity.

The second strategy is Polish declension stripping. Polish nouns change their endings based on grammatical case. The system strips common declension suffixes (such as -owi, -ami, -ach, -iem, -em, -a, -u, -y) and checks whether the resulting stem matches a known name.

> "Solmyra" (genitive of Solmyr) → stem "Solmyr" → matches.
> "Erathii" (genitive of Erathia) → stem "Erathi" → matches "Erathia" via stem index.

The third strategy is consonant alternation reversal. Polish has consonant changes where stem endings mutate in certain grammatical cases (e.g., k→c, g→dz, r→rz). The system reverses these mutations to recover the base form.

> "Valesce" (locative) → reverses ce→ka → "Valeska" → matches.
> "Solmyrze" (locative) → reverses rze→ra → "Solmyra" → stem "Solmyr" → matches.

The fourth strategy is fuzzy matching. For names that do not match through exact lookup or declension handling, the system uses edit distance (Levenshtein distance) to find the closest registered name within a tolerance threshold. Short names (under 5 characters) tolerate 1 character difference. Longer names tolerate up to one-third of the name's length.

> "Crag Hak" (typo, missing 'c') → distance 1 from "Crag Hack" → matches.
> "Sandero" (typo) → distance 1 from "Sandro" → matches.

## Aliases and Alternative Names

Entities can have multiple registered names. Aliases are added to the entity store and are matched at the same priority as the canonical name. Aliases can be time-scoped — valid only during a specific period. Narrators can use any registered alias in session text.

Nerthus names (`@nazwa_nerthus`) and slugs (`@slug`) are also searchable. When a location uses a different name in the Nerthus RP setting, both the Margonem name and the Nerthus name resolve to the same entity.

## When Ambiguity Prevents a Match

If a name matches multiple different entities at the same priority (e.g., two NPCs share a short name token), the system marks the name as ambiguous and skips the exact match. Declension and fuzzy stages also avoid ambiguous tokens. In this case, use a more specific name (the full name rather than a single word) or register a unique alias.

## When Resolution Fails

Name matching may fail despite a valid name in certain situations. Very short names (2-3 characters) have a narrow fuzzy tolerance, so even a single-character difference may not match. Unusual declension patterns with irregular Polish forms may not be covered by the built-in suffix list. Name collisions where a name closely resembles multiple entities may prevent confident resolution.

When a name fails to resolve, different parts of the system respond differently. PU processing stops entirely — all character names must resolve before any PU is awarded. World-state changes (Zmiany) skip the unresolved entity with a warning and continue processing. Currency transfers skip the unresolved side with a warning. Intel messages skip the unresolved target.

To fix an unresolved name, check the error or warning message for the exact unresolved name, compare it with the known entity roster, and correct the issue. If it is a typo in the session file, correct the name. If it is a name form that consistently fails, ask the Coordinator to register it as an alias. After the alias is registered, the system will match it exactly on future runs.

## Expected Outcomes

1. Natural language tolerance — Narrators can use Polish grammatical forms naturally without worrying about exact nominative case
2. Typo recovery — small misspellings are matched automatically via fuzzy matching
3. Alias flexibility — entities can be known by multiple names, all equally valid for matching
4. Fail-early for PU — unresolvable character names block PU assignment entirely, preventing incorrect awards

## Related Documents

- [World-State.md](World-State.md) — Entity management, aliases, and temporal scoping
- [Troubleshooting.md](Troubleshooting.md) — Diagnosing and fixing unresolved names
- [Sessions.md](Sessions.md) — Session recording format
- [Players.md](Players.md) — Player and character registration
- [Campaign Data API](REST-API.md) — Resolving names from external tools
- [Glossary](Glossary.md) — Term definitions
