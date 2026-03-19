namespace Robot {
    /// Central 28-property entity domain model. Each entity carries temporal
    /// history lists (containing TemporalEntry/CoordinateTemporalEntry from
    /// lib/TemporalEntry.cs), current scalar values, and identity metadata.
    ///
    /// Each instance carries 10 history lists (LocationHistory through
    /// NerthusNameHistory) plus CoordinateHistory and Aliases.
    ///
    /// Collection properties are typed as object to preserve compatibility with
    /// PowerShell's List[object] creation pattern and Comparison[object] sort delegates
    /// used by TemporalSorter. PowerShell accesses properties via dynamic dispatch
    /// (.Count, .Add(), .Sort(), indexer) which works identically on object-typed properties.
    ///
    /// Consumers: Get-EntityState, Get-Player, Get-NameIndex, Resolve-Name,
    /// Get-EntityHistory, CLI entity display, all reporting functions
    public sealed class Entity {
        // Identity
        public string Name { get; set; }
        public string CN { get; set; }
        public object Names { get; set; }
        public object Aliases { get; set; }

        // Current scalar state (last-active values)
        public string Type { get; set; }
        public string Owner { get; set; }
        public object Groups { get; set; }
        public string Location { get; set; }
        public object Doors { get; set; }
        public string Status { get; set; }
        public string Quantity { get; set; }
        public string FilePath { get; set; }
        public string NerthusName { get; set; }
        public object Coordinates { get; set; }

        // Temporal histories (List[object] containing TemporalEntry instances)
        public object TypeHistory { get; set; }
        public object OwnerHistory { get; set; }
        public object GroupHistory { get; set; }
        public object LocationHistory { get; set; }
        public object DoorHistory { get; set; }
        public object StatusHistory { get; set; }
        public object QuantityHistory { get; set; }
        public object FilePathHistory { get; set; }
        public object NerthusNameHistory { get; set; }
        public object CoordinateHistory { get; set; }

        // Computed classification (post-parse, not from tag parsing)
        public bool? IsExterior { get; set; }

        // Metadata
        public object Overrides { get; set; }
        public object GenericNames { get; set; }
        public object Contains { get; set; }

        // Diagnostics (populated by Get-EntityState on unresolved @Transfer)
        public object UnresolvedTransfers { get; set; }
    }
}
