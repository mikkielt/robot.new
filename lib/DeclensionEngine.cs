using System;
using System.Collections.Generic;

namespace Robot {
    /// Polish declension engine (nouns and adjectives) for name resolution.
    ///
    /// Iterates suffix and alternation arrays using .EndsWith() + .Substring() with
    /// OrdinalIgnoreCase comparison. Called on every unresolved name during resolution,
    /// with each call checking all configured suffix entries then all alternation entries.
    ///
    /// Two operations:
    /// - GetStem: strips the first matching inflection suffix (e.g. "Erathii" -> "Erathi")
    /// - GetAlternationCandidates: reverses stem changes (e.g. "Valesce" -> "Valeska")
    ///
    /// Suffix order is preserved from constructor input — longest-first ordering is
    /// critical to prevent partial stripping (e.g. "ami" must be tried before "i").
    /// Minimum stem length of 3 prevents over-stripping short names.
    ///
    /// Constructed once at module load by resolve-name.ps1 with Polish noun and
    /// adjective declension tables (noun: locative, genitive, instrumental, dative;
    /// adjective: genitive, dative, instrumental, locative, feminine; plus consonant
    /// alternation pairs).
    ///
    /// Consumers: Resolve-Name Stage 2 (suffix strip) and Stage 2b (alternation reversal)
    public sealed class DeclensionEngine {
        private readonly string[] _suffixes;
        private readonly string[] _altInflected;
        private readonly string[] _altBase;

        public DeclensionEngine(string[] suffixes, string[] altInflected, string[] altBase) {
            _suffixes = suffixes;
            _altInflected = altInflected;
            _altBase = altBase;
        }

        /// Strip the first matching declension suffix from text.
        /// Suffixes are tried in input order (longest-first).
        /// Minimum stem length of 3 (text.Length must exceed suffix.Length + 2).
        /// Returns original text if no suffix matches.
        public string GetStem(string text) {
            for (int i = 0; i < _suffixes.Length; i++) {
                string suffix = _suffixes[i];
                if (text.Length > suffix.Length + 2 &&  // +2 ensures at least 3-char stem remains
                    text.EndsWith(suffix, StringComparison.OrdinalIgnoreCase)) {
                    return text.Substring(0, text.Length - suffix.Length);
                }
            }
            return text;
        }

        /// Reverse stem alternations to produce candidate base forms.
        /// For "Valesce": strip "ce", append "ka" -> "Valeska".
        /// Returns empty array if no alternation matches.
        /// May return multiple candidates when multiple alternations match.
        public string[] GetAlternationCandidates(string text) {
            var results = new List<string>();
            for (int i = 0; i < _altInflected.Length; i++) {
                string inflected = _altInflected[i];
                if (text.Length > inflected.Length + 2 &&  // same minimum stem guard as GetStem
                    text.EndsWith(inflected, StringComparison.OrdinalIgnoreCase)) {
                    results.Add(text.Substring(0, text.Length - inflected.Length) + _altBase[i]);
                }
            }
            return results.ToArray();
        }
    }
}
