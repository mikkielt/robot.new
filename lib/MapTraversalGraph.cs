using System;
using System.Collections.Generic;
using System.Text.RegularExpressions;

namespace Robot {
    /// Input entry for map traversal graph building. One entry per Mapa entity.
    /// Populated by Get-MapTraversalGraph from entity objects with @margonemid tag.
    ///
    /// Consumers: Get-MapTraversalGraph (PowerShell orchestrator)
    public sealed class MapEntry {
        public string Name;
        public string[] Aliases;
        public string MargonemId;
        public string ParentLocation;
        public string MapType;
    }

    /// Mapa-to-Mapa edge observed in session logs. Struct — built once, read-only.
    ///
    /// Consumers: Get-MapTraversalGraph, Get-LocationGraph (via TraversalResult)
    public struct MapEdge {
        public string Source;
        public string Target;
        public int Weight;
        public string FirstSeenDate;
        public string LastSeenDate;
    }

    /// Projected Lokacja-to-Lokacja edge derived from MapEdge via ParentLocation.
    /// Struct — built once, read-only.
    ///
    /// Consumers: Get-LocationGraph (MapTraversalGraph parameter)
    public struct LocationEdge {
        public string Source;
        public string Target;
        public int Weight;
        public string FirstSeenDate;
        public string LastSeenDate;
    }

    /// Per-segment resolution result tracking how each raw map name was resolved.
    /// Struct — built once, read-only.
    ///
    /// Consumers: Get-MapTraversalGraph (diagnostics output)
    public struct ResolvedSegment {
        public string Raw;
        public string Resolved;
        public string Stage;
        public string StrippedName;
        public string ParentLocation;
        public int SessionIndex;
    }

    /// Container for the complete map traversal graph output.
    ///
    /// Consumers: Get-MapTraversalGraph, Get-LocationGraph
    public sealed class TraversalResult {
        public MapEdge[] MapEdges;
        public LocationEdge[] LocationEdges;
        public ResolvedSegment[] Segments;
        public string[] UnresolvedNames;
        public int TotalSegments;
        public int ResolvedCount;
        public int UnresolvedCount;
    }

    /// Builds a map traversal graph from Mapa entities and session log segments.
    /// Compiled C# for performance: the PowerShell fallback in get-maptraversalgraph.ps1
    /// processes the same algorithm but crosses the PS/C# boundary per-segment for
    /// regex matching. This class keeps the entire resolution + edge-building pipeline
    /// in compiled code, processing all sessions in a single Build() call.
    ///
    /// Resolution pipeline (simplified vs Resolve-Name — game map names are not
    /// Polish-inflected prose, so declension/stem/fuzzy stages are omitted):
    /// 1. Exact match against case-insensitive map dictionary (Name + all Aliases)
    /// 2. SuffixStrip: iterative 9-pattern stripping (do..while stable), retry exact
    /// 3. WordDrop: progressive trailing-word removal, retry each candidate
    /// 4. Unresolved
    ///
    /// After resolution, consecutive resolved segments produce MapEdge entries
    /// (skip same-map self-transitions). MapEdges are projected to LocationEdges
    /// via ParentLocation (skip same-Lokacja self-transitions).
    ///
    /// The 9 suffix patterns mirror location-helpers.ps1 canonical patterns and
    /// the margoworld plugin's iterative do..while approach (not the core
    /// Get-MapBaseName word-drop algorithm).
    ///
    /// Consumers: Get-MapTraversalGraph (C# dispatch path), Get-LocationGraph
    /// (via TraversalResult.LocationEdges), Set-TraversalEntities (via full result)
    public static class MapTraversalBuilder {
        // 9 suffix patterns — mirror of location-helpers.ps1 canonical patterns.
        // Applied iteratively until stable (margoworld plugin do..while approach).
        private static readonly Regex LocDifficultyPattern = new Regex(
            @"\s*\(poziom:\s*[^)]+\)\s*$",
            RegexOptions.Compiled | RegexOptions.IgnoreCase);
        private static readonly Regex LocFloorPattern = new Regex(
            @"\s+p\.\d+$", RegexOptions.Compiled);
        private static readonly Regex LocRoomSuffixPattern = new Regex(
            @"\s+s\.\d+$", RegexOptions.Compiled);
        private static readonly Regex LocSalaPattern = new Regex(
            @"\s+-\s+sala\s+\d+$",
            RegexOptions.Compiled | RegexOptions.IgnoreCase);
        private static readonly Regex LocNamedSalaPattern = new Regex(
            @"\s+-\s+Sala\s+.+$", RegexOptions.Compiled);
        private static readonly Regex LocDirectionPattern = new Regex(
            @"\s+-\s+(północ|południe|wschód|zachód|góra|dół)$",
            RegexOptions.Compiled | RegexOptions.IgnoreCase);
        private static readonly Regex LocPietroPattern = new Regex(
            @"\s+-\s+piętro(\s+\d+)?$",
            RegexOptions.Compiled | RegexOptions.IgnoreCase);
        private static readonly Regex LocPiwnicaPattern = new Regex(
            @"\s+-\s+piwnica(\s+p\.\d+)?$",
            RegexOptions.Compiled | RegexOptions.IgnoreCase);
        private static readonly Regex LocNamedSubareaPattern = new Regex(
            @"\s+-\s+\S.+$", RegexOptions.Compiled);

        /// Apply all 9 suffix patterns iteratively until the result stabilizes.
        /// Matches the margoworld plugin do..while approach, not the core
        /// Get-MapBaseName word-drop algorithm.
        public static string StripMapSuffix(string name) {
            string result = name;
            string prev;
            do {
                prev = result;
                result = LocDifficultyPattern.Replace(result, "");
                result = LocFloorPattern.Replace(result, "");
                result = LocRoomSuffixPattern.Replace(result, "");
                result = LocSalaPattern.Replace(result, "");
                result = LocNamedSalaPattern.Replace(result, "");
                result = LocDirectionPattern.Replace(result, "");
                result = LocPietroPattern.Replace(result, "");
                result = LocPiwnicaPattern.Replace(result, "");
                result = LocNamedSubareaPattern.Replace(result, "");
            } while (!string.Equals(result, prev, StringComparison.Ordinal));
            return result;
        }

        /// Progressive word-drop fallback applied after StripMapSuffix when the
        /// suffix-stripped result still doesn't match. Returns candidates ordered
        /// longest-to-shortest, excluding the original name. Mirrors the core
        /// Get-MapBaseName algorithm from location-helpers.ps1.
        public static string[] GetMapBaseCandidates(string name) {
            string trimmed = name.Trim();
            if (trimmed.Length == 0) return Array.Empty<string>();

            var candidates = new List<string>();
            var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);

            string[] words = trimmed.Split(new[] { ' ' }, StringSplitOptions.RemoveEmptyEntries);
            if (words.Length <= 1) return Array.Empty<string>();

            for (int i = words.Length - 1; i >= 1; i--) {
                string candidate = string.Join(" ", words, 0, i).TrimEnd(' ', '-', '\u2013', '\u2014');
                if (candidate.Length > 0 &&
                    !string.Equals(candidate, trimmed, StringComparison.OrdinalIgnoreCase) &&
                    seen.Add(candidate)) {
                    candidates.Add(candidate);
                }
            }
            return candidates.ToArray();
        }

        /// Main entry point: build map traversal graph from Mapa entities and
        /// session log segments.
        ///
        /// mapEntries: flat array of MapEntry from Mapa entities
        /// sessionSegments: jagged array — sessionSegments[i] = raw names for session i
        /// sessionDates: parallel array — sessionDates[i] = "yyyy-MM-dd" for session i
        public static TraversalResult Build(
            MapEntry[] mapEntries,
            string[][] sessionSegments,
            string[] sessionDates) {

            // 1. Build case-insensitive map lookup from Name + all Aliases
            var mapLookup = new Dictionary<string, MapEntry>(StringComparer.OrdinalIgnoreCase);
            foreach (var entry in mapEntries) {
                if (entry.Name != null && !mapLookup.ContainsKey(entry.Name))
                    mapLookup[entry.Name] = entry;
                if (entry.Aliases != null) {
                    foreach (var alias in entry.Aliases) {
                        if (alias != null && !mapLookup.ContainsKey(alias))
                            mapLookup[alias] = entry;
                    }
                }
            }

            // 2. Resolve each segment and build consecutive-pair edges
            var segments = new List<ResolvedSegment>();
            var unresolvedSet = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            var mapEdgeDict = new Dictionary<string, MapEdge>(StringComparer.OrdinalIgnoreCase);
            int resolvedCount = 0;
            int unresolvedCount = 0;

            for (int si = 0; si < sessionSegments.Length; si++) {
                string[] rawNames = sessionSegments[si];
                string sessionDate = (si < sessionDates.Length) ? sessionDates[si] : "";
                string prevResolved = null;
                string prevParent = null;

                for (int ni = 0; ni < rawNames.Length; ni++) {
                    string raw = rawNames[ni];
                    if (string.IsNullOrWhiteSpace(raw)) continue;

                    MapEntry matched = null;
                    string stage = "Unresolved";
                    string strippedName = null;

                    // Stage 1: Exact match
                    if (mapLookup.TryGetValue(raw, out matched)) {
                        stage = "Exact";
                    }

                    // Stage 2: SuffixStrip
                    if (matched == null) {
                        string stripped = StripMapSuffix(raw);
                        if (!string.Equals(stripped, raw, StringComparison.OrdinalIgnoreCase) &&
                            stripped.Length > 0) {
                            if (mapLookup.TryGetValue(stripped, out matched)) {
                                stage = "SuffixStrip";
                                strippedName = stripped;
                            }
                        }

                        // Stage 3: WordDrop on suffix-stripped result
                        if (matched == null) {
                            string dropBase = (stripped.Length > 0 && !string.Equals(stripped, raw, StringComparison.OrdinalIgnoreCase))
                                ? stripped : raw;
                            string[] candidates = GetMapBaseCandidates(dropBase);
                            foreach (var candidate in candidates) {
                                if (mapLookup.TryGetValue(candidate, out matched)) {
                                    stage = "WordDrop";
                                    strippedName = candidate;
                                    break;
                                }
                            }
                        }
                    }

                    // Record segment
                    var seg = new ResolvedSegment {
                        Raw = raw,
                        Resolved = matched != null ? matched.Name : null,
                        Stage = stage,
                        StrippedName = strippedName,
                        ParentLocation = matched != null ? matched.ParentLocation : null,
                        SessionIndex = si
                    };
                    segments.Add(seg);

                    if (matched != null) {
                        resolvedCount++;
                        string curResolved = matched.Name;
                        string curParent = matched.ParentLocation;

                        // Build MapEdge from consecutive resolved segments (skip self-transitions)
                        if (prevResolved != null &&
                            !string.Equals(prevResolved, curResolved, StringComparison.OrdinalIgnoreCase)) {
                            string edgeKey = prevResolved + "|" + curResolved;
                            if (mapEdgeDict.TryGetValue(edgeKey, out MapEdge existing)) {
                                existing.Weight++;
                                if (string.CompareOrdinal(sessionDate, existing.FirstSeenDate) < 0)
                                    existing.FirstSeenDate = sessionDate;
                                if (string.CompareOrdinal(sessionDate, existing.LastSeenDate) > 0)
                                    existing.LastSeenDate = sessionDate;
                                mapEdgeDict[edgeKey] = existing;
                            } else {
                                mapEdgeDict[edgeKey] = new MapEdge {
                                    Source = prevResolved,
                                    Target = curResolved,
                                    Weight = 1,
                                    FirstSeenDate = sessionDate,
                                    LastSeenDate = sessionDate
                                };
                            }
                        }

                        prevResolved = curResolved;
                        prevParent = curParent;
                    } else {
                        unresolvedCount++;
                        unresolvedSet.Add(raw);
                        // Unresolved segment breaks the consecutive chain
                        prevResolved = null;
                        prevParent = null;
                    }
                }
            }

            // 3. Project MapEdges to LocationEdges via ParentLocation
            var locEdgeDict = new Dictionary<string, LocationEdge>(StringComparer.OrdinalIgnoreCase);
            foreach (var me in mapEdgeDict.Values) {
                // Look up parent locations for source and target
                string srcParent = null, tgtParent = null;
                if (mapLookup.TryGetValue(me.Source, out MapEntry srcEntry))
                    srcParent = srcEntry.ParentLocation;
                if (mapLookup.TryGetValue(me.Target, out MapEntry tgtEntry))
                    tgtParent = tgtEntry.ParentLocation;

                // Skip if either parent is missing or self-transition at Lokacja level
                if (string.IsNullOrEmpty(srcParent) || string.IsNullOrEmpty(tgtParent))
                    continue;
                if (string.Equals(srcParent, tgtParent, StringComparison.OrdinalIgnoreCase))
                    continue;

                string locKey = srcParent + "|" + tgtParent;
                if (locEdgeDict.TryGetValue(locKey, out LocationEdge existingLoc)) {
                    existingLoc.Weight += me.Weight;
                    if (string.CompareOrdinal(me.FirstSeenDate, existingLoc.FirstSeenDate) < 0)
                        existingLoc.FirstSeenDate = me.FirstSeenDate;
                    if (string.CompareOrdinal(me.LastSeenDate, existingLoc.LastSeenDate) > 0)
                        existingLoc.LastSeenDate = me.LastSeenDate;
                    locEdgeDict[locKey] = existingLoc;
                } else {
                    locEdgeDict[locKey] = new LocationEdge {
                        Source = srcParent,
                        Target = tgtParent,
                        Weight = me.Weight,
                        FirstSeenDate = me.FirstSeenDate,
                        LastSeenDate = me.LastSeenDate
                    };
                }
            }

            // 4. Build result
            var mapEdges = new MapEdge[mapEdgeDict.Count];
            int idx = 0;
            foreach (var me in mapEdgeDict.Values) mapEdges[idx++] = me;

            var locEdges = new LocationEdge[locEdgeDict.Count];
            idx = 0;
            foreach (var le in locEdgeDict.Values) locEdges[idx++] = le;

            var unresolvedArr = new string[unresolvedSet.Count];
            unresolvedSet.CopyTo(unresolvedArr);

            return new TraversalResult {
                MapEdges = mapEdges,
                LocationEdges = locEdges,
                Segments = segments.ToArray(),
                UnresolvedNames = unresolvedArr,
                TotalSegments = segments.Count,
                ResolvedCount = resolvedCount,
                UnresolvedCount = unresolvedCount
            };
        }
    }
}
