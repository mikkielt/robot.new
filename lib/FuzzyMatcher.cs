using System;
using System.Collections.Generic;

namespace Robot {
    /// Compiled fuzzy string matcher for CLI typeahead filtering.
    ///
    /// Pre-lowercases all candidate names at construction time. Filter uses Ordinal
    /// comparisons on pre-lowered strings, avoiding per-call case conversion overhead.
    ///
    /// Two-stage filtering:
    /// 1. Prefix match (highest relevance) — names starting with query
    /// 2. Contains match (broader) — names containing query anywhere
    /// Stage 3 (fuzzy/BK-tree) remains in PowerShell as it needs the BKTree instance
    /// from Get-NameIndex.
    ///
    /// Returns int[] of indices into the original name array, capped at maxResults.
    /// The caller retains the original array and maps indices back to display objects.
    ///
    /// FindHighlight provides match position for Split-HighlightSegments rendering
    /// (ANSI color highlighting of the matched substring in CLI output).
    ///
    /// Consumers: Invoke-FuzzyFilter (cli-fuzzy.ps1), Invoke-MenuFilter (cli-menulist.ps1)
    public sealed class FuzzyMatcher {
        private readonly string[] _normalizedNames;
        private readonly int _count;

        /// Build a matcher from candidate names. Names are lowered once at construction.
        /// Null names are normalized to empty string. The caller retains the original
        /// candidate array and maps returned indices back.
        public FuzzyMatcher(string[] names) {
            _count = names.Length;
            _normalizedNames = new string[_count];
            for (int i = 0; i < _count; i++)
                _normalizedNames[i] = names[i] != null ? names[i].ToLowerInvariant() : string.Empty;
        }

        /// Two-stage filter: prefix then contains.
        /// Returns indices into the original array (not copies).
        /// Stops at maxResults. Returns empty array for null/empty query.
        public int[] Filter(string query, int maxResults) {
            if (string.IsNullOrEmpty(query) || maxResults <= 0)
                return Array.Empty<int>();

            string lowerQuery = query.ToLowerInvariant();
            var results = new List<int>(Math.Min(maxResults, 32));  // cap initial capacity to avoid over-allocation

            // Stage 1: prefix match (Ordinal on pre-lowered strings)
            for (int i = 0; i < _count && results.Count < maxResults; i++) {
                if (_normalizedNames[i].StartsWith(lowerQuery, StringComparison.Ordinal))
                    results.Add(i);
            }

            if (results.Count >= maxResults)
                return results.ToArray();

            // Stage 2: contains match (skip already found)
            var seen = new HashSet<int>(results);
            for (int i = 0; i < _count && results.Count < maxResults; i++) {
                if (!seen.Contains(i) && _normalizedNames[i].IndexOf(lowerQuery, StringComparison.Ordinal) >= 0)
                    results.Add(i);
            }

            return results.ToArray();
        }

        /// Find the position and length of a substring match for highlight rendering.
        /// Returns int[2]: {startIndex, length}. startIndex is -1 if no match found.
        /// Used by Split-HighlightSegments for ANSI color highlight computation.
        public static int[] FindHighlight(string text, string query) {
            if (string.IsNullOrEmpty(text) || string.IsNullOrEmpty(query))
                return new int[] { -1, 0 };  // {startIndex, length} sentinel for no match
            int idx = text.IndexOf(query, StringComparison.OrdinalIgnoreCase);
            return idx >= 0 ? new int[] { idx, query.Length } : new int[] { -1, 0 };
        }
    }
}
