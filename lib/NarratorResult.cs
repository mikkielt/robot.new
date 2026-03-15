namespace Robot {
    /// Narrator resolution result for batch session processing.
    /// Outer result holds array of resolved narrators with confidence levels.
    /// Narrator sub-objects carry a backreference to the resolved Player object.
    /// Cached by raw narrator text in Resolve-Narrator to avoid redundant resolution.
    ///
    /// Consumers: resolve-narrator.ps1, get-session.ps1 (narrator override),
    /// PU assignment, CLI narrator display
    public sealed class NarratorResult {
        public Narrator[] Narrators { get; set; }
        public bool IsCouncil { get; set; }
        public string Confidence { get; set; }
        public string RawText { get; set; }

        public NarratorResult() {}

        public NarratorResult(Narrator[] narrators, bool isCouncil, string confidence, string rawText) {
            Narrators = narrators;
            IsCouncil = isCouncil;
            Confidence = confidence;
            RawText = rawText;
        }
    }

    /// Individual narrator entry within a NarratorResult.
    /// Player is typed as object because it holds a PowerShell PSCustomObject
    /// (Player domain object from Get-Player).
    public sealed class Narrator {
        public string Name { get; set; }
        public object Player { get; set; }
        public string Confidence { get; set; }

        public Narrator() {}

        public Narrator(string name, object player, string confidence) {
            Name = name;
            Player = player;
            Confidence = confidence;
        }
    }
}
