using System;
using System.Collections.Generic;

namespace Robot {
    /// <summary>
    /// BK-tree with integrated case-insensitive Levenshtein distance.
    /// Used by Get-NameIndex / Resolve-Name for O(log N) fuzzy matching
    /// on the 4,700+ token name index (16,500+ lookups per session run).
    /// </summary>
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

        /// <summary>
        /// Two-row Levenshtein distance, case-insensitive, with early-exit threshold.
        /// Returns maxDist+1 when the true distance exceeds maxDist.
        /// </summary>
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
