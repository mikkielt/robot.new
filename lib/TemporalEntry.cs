using System;

namespace Robot {
    /// Lightweight temporal value container for entity history lists.
    /// Unifies all domain-specific property names (Location, Type, OwnerName,
    /// Group, Status, Quantity, FilePath, NerthusName, Text) into a single
    /// Value property so all history lists share one entry type.
    ///
    /// Each entity carries multiple history lists (LocationHistory, TypeHistory, etc.)
    /// sorted by ValidFrom via Robot.TemporalSorter.
    ///
    /// Consumers: get-entity.ps1, get-entitystate.ps1, Get-EntityHistory,
    /// Get-LastActiveValue, Get-AllActiveValues, Robot.TemporalSorter
    public sealed class TemporalEntry {
        public string Value { get; set; }
        public DateTime? ValidFrom { get; set; }
        public DateTime? ValidTo { get; set; }
        public string Season { get; set; }

        public TemporalEntry() {}

        public TemporalEntry(string value, DateTime? validFrom, DateTime? validTo, string season) {
            Value = value;
            ValidFrom = validFrom;
            ValidTo = validTo;
            Season = season;
        }
    }

    /// Coordinate temporal entry with X/Y instead of string Value.
    /// Used only by @koordynaty history (get-entity.ps1, get-entitystate.ps1).
    /// Separate class because coordinate entries carry two integer fields
    /// instead of a single string Value.
    public sealed class CoordinateTemporalEntry {
        public int X { get; set; }
        public int Y { get; set; }
        public DateTime? ValidFrom { get; set; }
        public DateTime? ValidTo { get; set; }
        public string Season { get; set; }

        public CoordinateTemporalEntry() {}

        public CoordinateTemporalEntry(int x, int y, DateTime? validFrom, DateTime? validTo, string season) {
            X = x;
            Y = y;
            ValidFrom = validFrom;
            ValidTo = validTo;
            Season = season;
        }
    }
}
