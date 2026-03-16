using System;
using System.Buffers;
using System.Collections.Generic;

namespace Robot {
    /// BK-tree with integrated case-insensitive Levenshtein distance for fuzzy name matching.
    ///
    /// Algorithm: metric tree keyed on Levenshtein distance. Search prunes children outside
    /// [d-threshold, d+threshold] range, yielding O(log N) average lookup vs O(N) linear scan.
    /// Tree is built once per module load and reused across all Resolve-Name calls.
    ///
    /// FindFuzzyPairs provides batch O(n^2) pairwise comparison for Get-NamedLocationReport
    /// deduplication. Uses ArrayPool<int> to rent work arrays once, avoiding per-pair allocation
    /// across all pair comparisons.
    ///
    /// Thread safety: instance methods (Add, Search) are not thread-safe — tree is built
    /// single-threaded during Get-NameIndex. Static FindFuzzyPairs and LevenshteinDistance
    /// are stateless and thread-safe.
    ///
    /// Consumers: Get-NameIndex (build + search), Resolve-Name (search),
    /// Get-NamedLocationReport (FindFuzzyPairs)
    public sealed class BKTree {
        private readonly string _key;
        private readonly Dictionary<int, BKTree> _children = new Dictionary<int, BKTree>();

        public BKTree(string key) { _key = key; }

        public void Add(string word) {
            int d = LevenshteinDistance(_key, word, int.MaxValue);
            if (d == 0) return;
            if (_children.TryGetValue(d, out var child))
                child.Add(word);
            else
                _children[d] = new BKTree(word);
        }

        public List<KeyValuePair<string, int>> Search(string query, int threshold) {
            var results = new List<KeyValuePair<string, int>>();
            var stack = new Stack<BKTree>();
            stack.Push(this);
            while (stack.Count > 0) {
                var node = stack.Pop();
                // Full distance needed for correct lo/hi child pruning.
                // Early-exit threshold would underestimate d, causing missed children.
                int d = LevenshteinDistance(query, node._key, int.MaxValue);
                if (d <= threshold)
                    results.Add(new KeyValuePair<string, int>(node._key, d));
                int lo = d - threshold, hi = d + threshold;
                foreach (var kv in node._children)
                    if (kv.Key >= lo && kv.Key <= hi)
                        stack.Push(kv.Value);
            }
            return results;
        }

        /// Find all fuzzy pairs within threshold from a list of strings.
        /// Returns List of (indexA, indexB, distance) tuples where 0 < distance <= threshold.
        /// Uses ArrayPool for work arrays — zero per-pair allocation.
        /// Distance computation is inlined to reuse rented arrays across all pairs.
        /// Keys shorter than 3 chars are skipped (too short for meaningful fuzzy matching).
        public static List<int[]> FindFuzzyPairs(string[] keys, int threshold) {
            var results = new List<int[]>();
            if (keys.Length < 2) return results;

            // Find max key length for buffer sizing
            int maxLen = 0;
            foreach (var k in keys)
                if (k.Length > maxLen) maxLen = k.Length;

            // Rent work arrays from pool — shared across ALL pairs
            int[] prev = ArrayPool<int>.Shared.Rent(maxLen + 1);
            int[] curr = ArrayPool<int>.Shared.Rent(maxLen + 1);
            try {
                for (int i = 0; i < keys.Length; i++) {
                    string s = keys[i];
                    if (s.Length < 3) continue;  // too short for meaningful fuzzy matching
                    for (int j = i + 1; j < keys.Length; j++) {
                        string t = keys[j];
                        if (t.Length < 3) continue;  // same minimum as outer loop
                        // Early exit: length difference exceeds threshold
                        if (Math.Abs(s.Length - t.Length) > threshold) continue;

                        // Inlined Levenshtein with early-exit threshold
                        int sLen = s.Length, tLen = t.Length;
                        for (int x = 0; x <= tLen; x++) prev[x] = x;

                        bool exceeded = false;
                        for (int si = 1; si <= sLen; si++) {
                            curr[0] = si;
                            int rowMin = si;
                            char sc = char.ToLowerInvariant(s[si - 1]);
                            for (int ti = 1; ti <= tLen; ti++) {
                                int cost = char.ToLowerInvariant(t[ti - 1]) == sc ? 0 : 1;
                                int ins = curr[ti - 1] + 1;
                                int del = prev[ti] + 1;
                                int sub = prev[ti - 1] + cost;
                                int val = ins < del ? (ins < sub ? ins : sub) : (del < sub ? del : sub);
                                curr[ti] = val;
                                if (val < rowMin) rowMin = val;
                            }
                            if (rowMin > threshold) { exceeded = true; break; }
                            // Swap prev/curr pointers (no array copy)
                            var tmp = prev; prev = curr; curr = tmp;
                        }
                        int dist = exceeded ? threshold + 1 : prev[tLen];

                        if (dist > 0 && dist <= threshold)
                            results.Add(new int[] { i, j, dist });
                    }
                }
            } finally {
                ArrayPool<int>.Shared.Return(prev);
                ArrayPool<int>.Shared.Return(curr);
            }
            return results;
        }

        /// Two-row Levenshtein distance, case-insensitive, with early-exit threshold.
        /// Returns maxDist+1 when the true distance exceeds maxDist.
        /// Allocates two int[] per call — acceptable for Search (few nodes visited)
        /// but FindFuzzyPairs inlines the algorithm to reuse rented arrays.
        public static int LevenshteinDistance(string s, string t, int maxDist) {
            if (s.Length == 0) return t.Length;
            if (t.Length == 0) return s.Length;
            if (Math.Abs(s.Length - t.Length) > maxDist) return maxDist + 1;

            var prev = new int[t.Length + 1];
            var curr = new int[t.Length + 1];
            for (int j = 0; j <= t.Length; j++) prev[j] = j;

            for (int i = 1; i <= s.Length; i++) {
                curr[0] = i;
                int rowMin = i;
                char sc = char.ToLowerInvariant(s[i - 1]);
                for (int j = 1; j <= t.Length; j++) {
                    int cost = sc == char.ToLowerInvariant(t[j - 1]) ? 0 : 1;
                    curr[j] = Math.Min(Math.Min(curr[j - 1] + 1, prev[j] + 1), prev[j - 1] + cost);
                    if (curr[j] < rowMin) rowMin = curr[j];
                }
                if (rowMin > maxDist) return maxDist + 1;
                var tmp = prev; prev = curr; curr = tmp;
            }
            return prev[t.Length];
        }
    }
}
