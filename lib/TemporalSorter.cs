using System;
using System.Management.Automation;

namespace Robot {
    /// Compiled temporal sort comparers for entity history lists.
    ///
    /// The C# Comparison<object> delegate avoids per-comparison interpreter
    /// dispatch. For O(n log n) sorts on lists of 5-50 items, Get-EntityState
    /// sorts 9 history lists per entity across the full entity set.
    ///
    /// The delegate is created once per property name ("ValidFrom" for entity state,
    /// "Date" for changelog) and reused across all sorts in the same Get-EntityState call.
    ///
    /// Objects are accessed via PSObject property reflection. PowerShell
    /// automatically wraps all .NET objects (including TemporalEntry and
    /// CoordinateTemporalEntry) in PSObject, so property access works
    /// uniformly without cross-assembly type dependencies.
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
            // PSObject wraps all .NET objects in PowerShell, so this handles
            // TemporalEntry, CoordinateTemporalEntry, PSCustomObject, and any
            // other type uniformly without cross-assembly type dependencies
            if (obj is PSObject pso) {
                var prop = pso.Properties[propertyName];
                if (prop != null && prop.Value is DateTime dt) return dt;
            }
            return null;
        }
    }
}
