using System;
using System.Collections.Generic;

namespace Robot {
    /// Compiled economic analysis for snapshot and timeline reporting.
    ///
    /// Compiled C# replaces PowerShell ScriptBlock-based sorting and LINQ-style
    /// accumulation loops that incurred ~2ms overhead per snapshot from interpreter
    /// dispatch on the inner loops. The C# version handles 50-200 wealth holders
    /// in <0.1ms.
    ///
    /// Two operations:
    /// - ComputeGini: Gini coefficient from positive-wealth values using the
    ///   standard formula G = (2*SUM(i*w[i]))/(n*SUM(w)) - (n+1)/n. O(n log n)
    ///   from Array.Sort, O(n) accumulation. Mutates the input array (sorts in place).
    /// - GetTopHolders: top-N extraction via index-array sort. Uses full sort
    ///   (simpler than partial sort for typical sizes of 50-200 holders).
    ///   Returns parallel arrays for direct PowerShell consumption.
    ///
    /// Consumers: New-EconomicSnapshotData (economy-helpers.ps1)
    public sealed class EconomicAnalyzer {
        /// Compute Gini coefficient from a list of positive wealth values.
        /// G = (2 * SUM(i * w[i])) / (n * SUM(w)) - (n+1)/n
        /// Values are sorted ascending internally (mutates input array).
        /// Returns 0.0 for n <= 1 or sumW == 0.
        public static double ComputeGini(int[] positiveWealth) {
            if (positiveWealth == null || positiveWealth.Length <= 1) return 0.0;

            // Gini formula requires ascending order; mutates the input array
            Array.Sort(positiveWealth);

            int n = positiveWealth.Length;
            double sumW = 0.0;
            double sumIW = 0.0;
            for (int i = 0; i < n; i++) {
                sumW += positiveWealth[i];
                sumIW += (i + 1) * (double)positiveWealth[i];
            }
            if (sumW <= 0.0) return 0.0;
            return (2.0 * sumIW) / (n * sumW) - (n + 1.0) / n;
        }

        /// Extract top-N holders sorted by wealth descending.
        /// Returns parallel arrays via out parameters: names[], wealthValues[], categories[].
        /// Uses full index-array sort — simpler than partial sort for typical sizes of
        /// 50-200 holders. Returns empty arrays when input is null/empty or top <= 0.
        public static void GetTopHolders(
            string[] ownerNames, int[] ownerWealth, string[] ownerCategories,
            int top,
            out string[] topNames, out int[] topWealth, out string[] topCategories) {

            if (ownerNames == null || ownerNames.Length == 0 || top <= 0) {
                topNames = Array.Empty<string>();
                topWealth = Array.Empty<int>();
                topCategories = Array.Empty<string>();
                return;
            }

            // Sort by wealth descending via index indirection to preserve parallel array alignment
            int[] indices = new int[ownerNames.Length];
            for (int i = 0; i < indices.Length; i++) indices[i] = i;

            Array.Sort(indices, (a, b) => ownerWealth[b].CompareTo(ownerWealth[a]));

            int count = Math.Min(top, ownerNames.Length);
            topNames = new string[count];
            topWealth = new int[count];
            topCategories = new string[count];
            for (int i = 0; i < count; i++) {
                int idx = indices[i];
                topNames[i] = ownerNames[idx];
                topWealth[i] = ownerWealth[idx];
                topCategories[i] = ownerCategories[idx];
            }
        }
    }
}
