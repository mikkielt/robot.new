using System;
using System.Management.Automation;

namespace Robot {
    /// Compiled temporal sort comparers for entity history lists.
    ///
    /// Compiled C# replaces PowerShell ScriptBlock comparers that crossed the
    /// .NET interop boundary on every comparison. For O(n log n) sort on lists
    /// of 5-50 items, that meant ~30-300 interpreter invocations per sort.
    /// Across 9 history lists per entity and ~200 entities processed by
    /// Get-EntityState (~1,800 sorts total), the aggregate overhead was ~500ms.
    /// The C# Comparison<object> delegate eliminates interpreter dispatch entirely.
    ///
    /// The delegate is created once per property name ("ValidFrom" for entity state,
    /// "Date" for changelog) and reused across all sorts in the same Get-EntityState call.
    /// Uses PSObject property access (System.Management.Automation reference required)
    /// to read DateTime? values from PowerShell objects.
    ///
    /// Null dates sort before dated entries (ascending chronological order),
    /// placing entries with unknown temporal validity at the beginning.
    ///
    /// Consumers: Get-EntityState (get-entitystate.ps1)
    public sealed class TemporalSorter {
        /// Create a Comparison<object> delegate that sorts by the named DateTime?
        /// property. Null values sort before dated entries (ascending chronological).
        /// Call once per property name and reuse the returned delegate across all sorts.
        public static Comparison<object> CreateComparer(string propertyName) {
            return (a, b) => {
                DateTime? aDate = GetDateProperty(a, propertyName);
                DateTime? bDate = GetDateProperty(b, propertyName);
                if (!aDate.HasValue && !bDate.HasValue) return 0;
                if (!aDate.HasValue) return -1;
                if (!bDate.HasValue) return 1;
                return aDate.Value.CompareTo(bDate.Value);
            };
        }

        private static DateTime? GetDateProperty(object obj, string propertyName) {
            if (obj is PSObject pso) {
                var prop = pso.Properties[propertyName];
                if (prop != null && prop.Value is DateTime dt) return dt;
            }
            return null;
        }
    }
}
