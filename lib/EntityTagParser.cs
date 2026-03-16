using System;
using System.Collections.Generic;
using System.Globalization;
using System.Text;
using System.Text.RegularExpressions;

namespace Robot {
    /// Compiled 14-way entity tag dispatcher that categorizes Markdown list bullets
    /// into typed entity property bags with temporal history fields.
    ///
    /// Processes all entity definition bullets in a single compiled pass, performing
    /// regex-based validity string parsing and 14-way tag prefix dispatch per bullet.
    ///
    /// Algorithm: two-phase processing. Phase 1 builds a parent->children index
    /// (Dictionary<int, List<int>>) in a single O(n) pass over the flat parallel
    /// arrays from MarkdownScanner. Phase 2 iterates root bullets (indent level 0),
    /// dispatching each child bullet through a 14-way tag prefix match (@lokacja,
    /// @drzwi, @typ, @nalezy_do, @grupa, @zawiera, @status, @ilosc, @alias,
    /// @generyczne_nazwy, @plik, @nazwa_nerthus, @slug, @koordynaty) with a
    /// fallback bucket for unrecognized @-prefixed tags stored as generic overrides.
    ///
    /// ConvertFrom-ValidityString logic is inlined as ParseValidity, handling four
    /// syntactic forms: plain value, date range (YYYY-MM:YYYY-MM), season keyword,
    /// and combined date+season. The regex patterns are passed from the PowerShell
    /// caller (shared with the fallback path) and compiled once per Parse call.
    /// Non-temporal parentheticals (no colon, not a season keyword) are preserved
    /// as literal name parts for backward compatibility with entity names like
    /// "Rada (Ithan)".
    ///
    /// Nested bullet text extraction supports multi-line tags (e.g. @alias with
    /// child bullets) by collecting temporally-active children into newline-joined
    /// strings. Temporal filtering via activeOn applies to @alias, @slug, and
    /// override tags at parse time; all other temporal tags are returned unfiltered
    /// for downstream resolution by the PowerShell merge path.
    ///
    /// Input: flat parallel arrays (texts[], parentIndices[], indents[]) from
    /// MarkdownScanner output for a single entity section, plus regex pattern
    /// strings for validity parsing and date range extraction.
    ///
    /// Output: EntityParseResult with one EntityTagEntry per root entity bullet.
    /// Each entry carries List<TemporalEntry> for all temporal history fields
    /// (compatible with .AddRange() in the merge path) and List<string> for
    /// non-temporal tags (GenericNames, Contains, SlugNames).
    ///
    /// Season keywords (wiosna, lato, jesien, zima) are matched case-insensitively,
    /// consistent with the PowerShell $script:SeasonKeywords HashSet.
    ///
    /// Consumers: get-entity.ps1 line 258 via [Robot.EntityTagParser]::Parse
    public sealed class EntityTagParser {

        // ── Output types ────────────────────────────────────────────

        /// Container for the full parse output: one EntityTagEntry per root entity bullet
        /// found in the section. Entries array is pre-sized to root count.
        public sealed class EntityParseResult {
            public EntityTagEntry[] Entries;
        }

        /// Per-entity property bag with typed temporal history lists and non-temporal
        /// string lists. Fields map 1:1 to Robot.Entity properties — the PowerShell
        /// merge path calls .AddRange() on each history list to accumulate across
        /// multiple entity definition file sections.
        public sealed class EntityTagEntry {
            public string EntityName;
            public List<TemporalEntry> LocationHistory = new List<TemporalEntry>();
            public List<TemporalEntry> DoorHistory = new List<TemporalEntry>();
            public List<TemporalEntry> TypeHistory = new List<TemporalEntry>();
            public List<TemporalEntry> OwnerHistory = new List<TemporalEntry>();
            public List<TemporalEntry> GroupHistory = new List<TemporalEntry>();
            public List<TemporalEntry> StatusHistory = new List<TemporalEntry>();
            public List<TemporalEntry> QuantityHistory = new List<TemporalEntry>();
            public List<TemporalEntry> FilePathHistory = new List<TemporalEntry>();
            public List<TemporalEntry> NerthusNameHistory = new List<TemporalEntry>();
            public List<CoordinateTemporalEntry> CoordinateHistory = new List<CoordinateTemporalEntry>();
            public List<TemporalEntry> Aliases = new List<TemporalEntry>();
            public List<string> GenericNames = new List<string>();
            public List<string> Contains = new List<string>();
            public List<string> SlugNames = new List<string>();
            // Overrides: key -> list of values (tag name without '@' prefix)
            public Dictionary<string, List<string>> Overrides = new Dictionary<string, List<string>>(StringComparer.OrdinalIgnoreCase);
        }

        // ── Internal validity parse result ──────────────────────────
        // Carries decomposed validity string fields between ParseValidity and callers.
        // Struct to avoid heap allocation in the hot per-bullet loop.

        private struct ValidityResult {
            public string Text;
            public DateTime? ValidFrom;
            public DateTime? ValidTo;
            public string Season;
        }

        // ── Season keywords ─────────────────────────────────────────

        private static readonly HashSet<string> SeasonKeywords = new HashSet<string>(
            StringComparer.OrdinalIgnoreCase) { "wiosna", "lato", "jesień", "zima" };

        // ── Public API ──────────────────────────────────────────────

        /// Parse entity section list items into categorized tag data per entity.
        /// texts[i] = list item text from MarkdownScanner.ListEntry.
        /// parentIndices[i] = section-local parent index (-1 for root items).
        /// indents[i] = normalized indent level (0 = root entity bullet).
        /// validityPattern = regex string for "text (range)" extraction — shared
        /// with the PowerShell fallback path to ensure identical parsing.
        /// dateRangePattern = regex string for "start:end" date pair extraction.
        /// activeOn = optional temporal filter date; when set, @alias, @slug, and
        /// override tags are filtered to only temporally active entries. Null skips
        /// all temporal filtering.
        /// Returns EntityParseResult with one EntityTagEntry per root entity bullet.
        public static EntityParseResult Parse(
            string[] texts, int[] parentIndices, int[] indents,
            string validityPattern, string dateRangePattern,
            DateTime? activeOn) {

            int count = texts.Length;
            var validityRx = new Regex(validityPattern, RegexOptions.Compiled);
            var dateRangeRx = new Regex(dateRangePattern, RegexOptions.Compiled);

            // Build parent->children index in O(n) to avoid O(n^2) repeated filtering
            // when dispatching child bullets per root entity
            var childrenOf = new Dictionary<int, List<int>>();
            var roots = new List<int>();

            for (int i = 0; i < count; i++) {
                int parent = parentIndices[i];
                if (parent < 0 && indents[i] == 0) {
                    roots.Add(i);
                } else if (parent >= 0) {
                    List<int> list;
                    if (!childrenOf.TryGetValue(parent, out list)) {
                        list = new List<int>();
                        childrenOf[parent] = list;
                    }
                    list.Add(i);
                }
            }

            var entries = new List<EntityTagEntry>(roots.Count);

            foreach (int rootIdx in roots) {
                string entityName = texts[rootIdx].Trim();
                var entry = new EntityTagEntry();
                entry.EntityName = entityName;

                // Entities with no child bullets (name-only entries) are valid — add and skip
                List<int> childIndices;
                if (!childrenOf.TryGetValue(rootIdx, out childIndices)) {
                    entries.Add(entry);
                    continue;
                }

                foreach (int bulletIdx in childIndices) {
                    string lineText = texts[bulletIdx].Trim();

                    // Skip non-@ lines: legacy plain-text aliases are handled in PS layer
                    if (lineText.Length == 0 || lineText[0] != '@') continue;

                    int colonIdx = lineText.IndexOf(':');
                    if (colonIdx < 0) continue;

                    string tag = lineText.Substring(0, colonIdx).Trim().ToLowerInvariant();
                    string value = lineText.Substring(colonIdx + 1).Trim();

                    // Multi-line tags (e.g. @alias) carry values in nested child bullets
                    // rather than inline — collect and join them for effective value
                    string nestedValue = GetNestedBulletText(bulletIdx, childrenOf, texts,
                        validityRx, dateRangeRx, activeOn);
                    string effectiveValue = (string.IsNullOrWhiteSpace(value) && nestedValue != null)
                        ? nestedValue : value;

                    // 14-way tag dispatch: each branch maps to a specific Robot.Entity
                    // property. Temporal tags go through ParseValidity; non-temporal
                    // tags are stored directly.
                    if (tag == "@lokacja") {
                        var parsed = ParseValidity(value, validityRx, dateRangeRx);
                        entry.LocationHistory.Add(new TemporalEntry(
                            parsed.Text, parsed.ValidFrom, parsed.ValidTo, parsed.Season));
                    }
                    else if (tag == "@drzwi") {
                        var parsed = ParseValidity(value, validityRx, dateRangeRx);
                        entry.DoorHistory.Add(new TemporalEntry(
                            parsed.Text, parsed.ValidFrom, parsed.ValidTo, parsed.Season));
                    }
                    else if (tag == "@typ") {
                        var parsed = ParseValidity(value, validityRx, dateRangeRx);
                        entry.TypeHistory.Add(new TemporalEntry(
                            parsed.Text, parsed.ValidFrom, parsed.ValidTo, parsed.Season));
                    }
                    else if (tag == "@należy_do") {
                        var parsed = ParseValidity(value, validityRx, dateRangeRx);
                        entry.OwnerHistory.Add(new TemporalEntry(
                            parsed.Text, parsed.ValidFrom, parsed.ValidTo, parsed.Season));
                    }
                    else if (tag == "@grupa") {
                        var parsed = ParseValidity(value, validityRx, dateRangeRx);
                        entry.GroupHistory.Add(new TemporalEntry(
                            parsed.Text, parsed.ValidFrom, parsed.ValidTo, parsed.Season));
                    }
                    else if (tag == "@zawiera") {
                        entry.Contains.Add(value);
                    }
                    else if (tag == "@status") {
                        var parsed = ParseValidity(value, validityRx, dateRangeRx);
                        entry.StatusHistory.Add(new TemporalEntry(
                            parsed.Text, parsed.ValidFrom, parsed.ValidTo, parsed.Season));
                    }
                    else if (tag == "@ilość") {
                        var parsed = ParseValidity(value, validityRx, dateRangeRx);
                        entry.QuantityHistory.Add(new TemporalEntry(
                            parsed.Text, parsed.ValidFrom, parsed.ValidTo, parsed.Season));
                    }
                    else if (tag == "@alias") {
                        var parsed = ParseValidity(effectiveValue, validityRx, dateRangeRx);
                        if (IsTemporallyActive(parsed, activeOn)) {
                            entry.Aliases.Add(new TemporalEntry(
                                parsed.Text, parsed.ValidFrom, parsed.ValidTo, parsed.Season));
                        }
                    }
                    else if (tag == "@generyczne_nazwy") {
                        string[] parts = value.Split(',');
                        foreach (string gn in parts) {
                            string trimmed = gn.Trim();
                            if (trimmed.Length > 0) {
                                entry.GenericNames.Add(trimmed);
                            }
                        }
                    }
                    else if (tag == "@plik") {
                        var parsed = ParseValidity(value, validityRx, dateRangeRx);
                        entry.FilePathHistory.Add(new TemporalEntry(
                            parsed.Text, parsed.ValidFrom, parsed.ValidTo, parsed.Season));
                    }
                    else if (tag == "@nazwa_nerthus") {
                        var parsed = ParseValidity(value, validityRx, dateRangeRx);
                        entry.NerthusNameHistory.Add(new TemporalEntry(
                            parsed.Text, parsed.ValidFrom, parsed.ValidTo, parsed.Season));
                    }
                    else if (tag == "@slug") {
                        var parsed = ParseValidity(value, validityRx, dateRangeRx);
                        if (IsTemporallyActive(parsed, activeOn)) {
                            entry.SlugNames.Add(parsed.Text);
                        }
                    }
                    else if (tag == "@koordynaty") {
                        var parsed = ParseValidity(value, validityRx, dateRangeRx);
                        int[] coords = ParseCoordinate(parsed.Text);
                        if (coords != null) {
                            entry.CoordinateHistory.Add(new CoordinateTemporalEntry(
                                coords[0], coords[1], parsed.ValidFrom, parsed.ValidTo, parsed.Season));
                        }
                    }
                    else {
                        // Unrecognized @tags go into generic overrides dictionary,
                        // enabling extensibility without code changes
                        var parsed = ParseValidity(effectiveValue, validityRx, dateRangeRx);
                        if (IsTemporallyActive(parsed, activeOn)) {
                            string propName = tag.Substring(1); // strip leading '@'
                            string propValue;
                            if (string.IsNullOrWhiteSpace(value) && nestedValue != null) {
                                propValue = nestedValue;
                            } else if (!string.IsNullOrWhiteSpace(value) && nestedValue != null) {
                                propValue = parsed.Text + "\n" + nestedValue;
                            } else {
                                propValue = parsed.Text;
                            }

                            List<string> overrideList;
                            if (!entry.Overrides.TryGetValue(propName, out overrideList)) {
                                overrideList = new List<string>();
                                entry.Overrides[propName] = overrideList;
                            }
                            overrideList.Add(propValue);
                        }
                    }
                }

                entries.Add(entry);
            }

            return new EntityParseResult { Entries = entries.ToArray() };
        }

        // ── Validity string decomposition ─────────────────────────────
        // Inlines the logic of PowerShell ConvertFrom-ValidityString for zero-interop
        // parsing in the hot loop. Uses the same regex patterns passed from PS caller.

        /// Decompose "Value (2021-01:2024-06)" into text + temporal bounds + season.
        /// Four syntactic forms are recognized:
        /// 1. Plain value: "Erathia" -> no temporal bounds
        /// 2. Date range: "Erathia (2021-01:2024-06)" -> ValidFrom/ValidTo set
        /// 3. Season only: "ithan-zima.png (zima)" -> Season set, no dates
        /// 4. Combined: "Targowisko (2024-01:, lato)" -> both date range and season
        /// Non-temporal parentheticals (no colon, not a season keyword) are treated
        /// as literal name parts for backward compatibility with entity names that
        /// contain parentheses (e.g. "Rada (Ithan)").
        private static ValidityResult ParseValidity(string inputText, Regex validityRx, Regex dateRangeRx) {
            string trimmed = inputText.Trim();
            Match match = validityRx.Match(trimmed);

            if (!match.Success) {
                return new ValidityResult { Text = trimmed, ValidFrom = null, ValidTo = null, Season = null };
            }

            string name = match.Groups[1].Value.Trim();
            Group parenGroup = match.Groups[2];

            if (!parenGroup.Success) {
                return new ValidityResult { Text = name, ValidFrom = null, ValidTo = null, Season = null };
            }

            string parenContent = parenGroup.Value.Trim();

            // Comma-separated: combined form allows season + date range in any order
            // e.g. "Targowisko (2024-01:, lato)" or "Port (zima, 2023-06:2024-01)"
            if (parenContent.IndexOf(',') >= 0) {
                string[] parts = parenContent.Split(',');
                string season = null;
                string datePart = null;

                foreach (string part in parts) {
                    string p = part.Trim();
                    if (SeasonKeywords.Contains(p)) {
                        season = p.ToLowerInvariant();
                    } else {
                        datePart = p;
                    }
                }

                DateTime? validFrom = null;
                DateTime? validTo = null;
                if (datePart != null) {
                    Match dateMatch = dateRangeRx.Match(datePart);
                    if (dateMatch.Success) {
                        validFrom = ResolvePartialDate(dateMatch.Groups[1].Value.Trim(), false);
                        validTo = ResolvePartialDate(dateMatch.Groups[2].Value.Trim(), true);
                    }
                }

                return new ValidityResult { Text = name, ValidFrom = validFrom, ValidTo = validTo, Season = season };
            }

            // Season-only
            if (SeasonKeywords.Contains(parenContent)) {
                return new ValidityResult {
                    Text = name, ValidFrom = null, ValidTo = null,
                    Season = parenContent.ToLowerInvariant()
                };
            }

            // Date range
            Match dateRangeMatch = dateRangeRx.Match(parenContent);
            if (dateRangeMatch.Success) {
                DateTime? vf = ResolvePartialDate(dateRangeMatch.Groups[1].Value.Trim(), false);
                DateTime? vt = ResolvePartialDate(dateRangeMatch.Groups[2].Value.Trim(), true);
                return new ValidityResult { Text = name, ValidFrom = vf, ValidTo = vt, Season = null };
            }

            // Non-temporal parenthetical: literal name part (e.g. "Rada (Ithan)")
            return new ValidityResult {
                Text = name + " (" + parenContent + ")",
                ValidFrom = null, ValidTo = null, Season = null
            };
        }

        // ── Partial date expansion ──────────────────────────────────
        // Entity validity ranges use abbreviated dates (YYYY or YYYY-MM) that need
        // expansion to full DateTime for comparison. Start dates expand to first-of-period,
        // end dates to last-of-period, giving inclusive range semantics.

        private static readonly Regex YearOnlyRx = new Regex(@"^\d{4}$", RegexOptions.Compiled);
        private static readonly Regex YearMonthRx = new Regex(@"^\d{4}-\d{2}$", RegexOptions.Compiled);

        /// Expands partial dates (YYYY, YYYY-MM) to full DateTime values.
        /// isEnd=false: "2024" -> 2024-01-01, "2024-06" -> 2024-06-01.
        /// isEnd=true:  "2024" -> 2024-12-31, "2024-06" -> 2024-06-30.
        /// Returns null for empty/whitespace input or unparseable strings.
        private static DateTime? ResolvePartialDate(string dateStr, bool isEnd) {
            if (string.IsNullOrWhiteSpace(dateStr)) return null;

            string normalized = dateStr;

            if (YearOnlyRx.IsMatch(dateStr)) {
                normalized = isEnd ? dateStr + "-12-31" : dateStr + "-01-01";
            }
            else if (YearMonthRx.IsMatch(dateStr)) {
                if (isEnd) {
                    int year = int.Parse(dateStr.Substring(0, 4));
                    int month = int.Parse(dateStr.Substring(5, 2));
                    int lastDay = DateTime.DaysInMonth(year, month);
                    normalized = dateStr + "-" + lastDay.ToString("D2");
                } else {
                    normalized = dateStr + "-01";
                }
            }

            DateTime result;
            if (DateTime.TryParseExact(normalized, "yyyy-MM-dd",
                    CultureInfo.InvariantCulture, DateTimeStyles.None, out result)) {
                return result;
            }
            return null;
        }

        // ── Temporal activity check ──────────────────────────────────
        // Applies date-range and season filtering in C# to avoid crossing back to
        // PowerShell for each bullet. Uses default meteorological season mapping only —
        // custom season boundaries from local.config.psd1 are not accessible from C#.

        /// Returns true if the parsed validity result is active at the given date.
        /// Checks date bounds first (short-circuit on out-of-range), then season.
        /// Season check uses default meteorological mapping; the PowerShell layer
        /// re-checks season for @alias and @nazwa_nerthus where custom mapping matters.
        private static bool IsTemporallyActive(ValidityResult item, DateTime? activeOn) {
            if (!activeOn.HasValue) return true;
            if (item.ValidFrom.HasValue && activeOn.Value < item.ValidFrom.Value) return false;
            if (item.ValidTo.HasValue && activeOn.Value > item.ValidTo.Value) return false;

            if (item.Season != null) {
                string season = ResolveSeasonForDate(activeOn.Value);
                if (!string.Equals(item.Season, season, StringComparison.OrdinalIgnoreCase)) {
                    return false;
                }
            }

            return true;
        }

        /// Default meteorological season mapping: Mar-May=wiosna, Jun-Aug=lato,
        /// Sep-Nov=jesien, Dec-Feb=zima. Returns lowercase Polish season name.
        private static string ResolveSeasonForDate(DateTime date) {
            int month = date.Month;
            if (month >= 3 && month <= 5) return "wiosna";
            if (month >= 6 && month <= 8) return "lato";
            if (month >= 9 && month <= 11) return "jesień";
            return "zima";
        }

        // ── Nested bullet text collection ──────────────────────────────
        // Multi-line tags store their values as child bullets rather than inline.
        // Each child is parsed for validity and filtered by activeOn before joining.

        /// Collects temporally-active text from child bullets of a tag bullet.
        /// Returns newline-joined string of active children, or null if none found.
        private static string GetNestedBulletText(int parentIdx,
            Dictionary<int, List<int>> childrenOf, string[] texts,
            Regex validityRx, Regex dateRangeRx, DateTime? activeOn) {

            List<int> children;
            if (!childrenOf.TryGetValue(parentIdx, out children) || children.Count == 0) {
                return null;
            }

            var result = new List<string>();
            foreach (int ci in children) {
                string childText = texts[ci].Trim();
                var parsed = ParseValidity(childText, validityRx, dateRangeRx);
                if (IsTemporallyActive(parsed, activeOn)) {
                    result.Add(parsed.Text);
                }
            }

            if (result.Count == 0) return null;
            return string.Join("\n", result);
        }

        // ── Coordinate parsing ──────────────────────────────────────

        /// Parses "X, Y" coordinate pair from @koordynaty tag value.
        /// Returns int[2] {x, y} or null if the value is malformed.
        private static int[] ParseCoordinate(string text) {
            string[] parts = text.Split(',');
            if (parts.Length < 2) return null;

            int x, y;
            if (int.TryParse(parts[0].Trim(), out x) && int.TryParse(parts[1].Trim(), out y)) {
                return new int[] { x, y };
            }
            return null;
        }
    }
}
