using System;
using System.Collections.Generic;

namespace Robot {
    /// Bidirectional mapping between canonical Polish domain terms and
    /// English API labels. Provides O(1) lookup in both directions for
    /// entity types, statuses, tags, seasons, denominations, and other
    /// domain enums.
    ///
    /// Design principles:
    /// - Canonical values are authoritative — always stored/returned by the module
    /// - API labels are aliases — accepted in queries, injected in responses
    /// - Bidirectional: Canonical→Label for serialization, Label→Canonical for filtering
    /// - Case-insensitive all lookups (OrdinalIgnoreCase)
    /// - Static readonly: zero allocation, thread-safe for RunspacePool
    ///
    /// Consumers: ApiQueryParser (filter alias resolution), ApiSerializer (label injection),
    ///            /schema endpoint (self-describing API discovery)
    public static class ApiNameDictionary {

        // ── Entity Types ──────────────────────────────────────────────────

        private static readonly Dictionary<string, string> _typeToLabel =
            new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase) {
                ["NPC"]       = "npc",
                ["Gracz"]     = "player",
                ["Postać"]    = "character",
                ["Grupa"]     = "group",
                ["Lokacja"]   = "location",
                ["Mapa"]      = "map",
                ["Przedmiot"] = "item"
            };

        private static readonly Dictionary<string, string> _labelToType =
            BuildReverse(_typeToLabel);

        // ── Entity Status ─────────────────────────────────────────────────

        private static readonly Dictionary<string, string> _statusToLabel =
            new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase) {
                ["Aktywny"]    = "active",
                ["Nieaktywny"] = "inactive",
                ["Usunięty"]   = "deleted"
            };

        private static readonly Dictionary<string, string> _labelToStatus =
            BuildReverse(_statusToLabel);

        // ── Entity Tags ───────────────────────────────────────────────────

        private static readonly Dictionary<string, string> _tagToLabel =
            new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase) {
                ["lokacja"]          = "location",
                ["drzwi"]            = "doors",
                ["typ"]              = "type",
                ["należy_do"]        = "owner",
                ["grupa"]            = "group",
                ["zawiera"]          = "contains",
                ["status"]           = "status",
                ["ilość"]            = "quantity",
                ["alias"]            = "alias",
                ["generyczne_nazwy"] = "genericNames",
                ["plik"]             = "filePath",
                ["nazwa_nerthus"]    = "displayName",
                ["slug"]             = "slug",
                ["koordynaty"]       = "coordinates"
            };

        private static readonly Dictionary<string, string> _labelToTag =
            BuildReverse(_tagToLabel);

        // ── Seasons ───────────────────────────────────────────────────────

        private static readonly Dictionary<string, string> _seasonToLabel =
            new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase) {
                ["wiosna"] = "spring",
                ["lato"]   = "summer",
                ["jesień"] = "autumn",
                ["zima"]   = "winter"
            };

        private static readonly Dictionary<string, string> _labelToSeason =
            BuildReverse(_seasonToLabel);

        // ── Currency Denominations ────────────────────────────────────────

        private static readonly Dictionary<string, string> _denomToLabel =
            new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase) {
                ["Korony Elanckie"]   = "gold",
                ["Korony"]            = "gold",
                ["Talary Hirońskie"]  = "silver",
                ["Talary"]            = "silver",
                ["Kogi Skeltvorskie"] = "copper",
                ["Kogi"]              = "copper"
            };

        private static readonly Dictionary<string, string> _labelToDenom =
            new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase) {
                ["gold"]   = "Korony Elanckie",
                ["silver"] = "Talary Hirońskie",
                ["copper"] = "Kogi Skeltvorskie"
            };

        // ── Session Formats ───────────────────────────────────────────────

        private static readonly Dictionary<string, string> _formatToLabel =
            new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase) {
                ["Gen1"] = "legacy",
                ["Gen2"] = "italic-location",
                ["Gen3"] = "pu-prefix",
                ["Gen4"] = "tagged"
            };

        private static readonly Dictionary<string, string> _labelToFormat =
            BuildReverse(_formatToLabel);

        // ── Participation Sources ─────────────────────────────────────────

        private static readonly Dictionary<string, string> _sourceToLabel =
            new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase) {
                ["FilePath"] = "filesystem",
                ["PU"]       = "skillPoints",
                ["Changes"]  = "entityChanges",
                ["Transfer"] = "transfer",
                ["Intel"]    = "intelligence"
            };

        private static readonly Dictionary<string, string> _labelToSource =
            BuildReverse(_sourceToLabel);

        // ── Intel Directives ──────────────────────────────────────────────

        private static readonly Dictionary<string, string> _directiveToLabel =
            new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase) {
                ["Direct"]  = "direct",
                ["Grupa"]   = "group",
                ["Lokacja"] = "location"
            };

        private static readonly Dictionary<string, string> _labelToDirective =
            BuildReverse(_directiveToLabel);

        // ── Owner Types ───────────────────────────────────────────────────

        private static readonly Dictionary<string, string> _ownerTypeToLabel =
            new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase) {
                ["Physical"] = "physical",
                ["Virtual"]  = "virtual",
                ["Unknown"]  = "unknown"
            };

        // ── Public API ────────────────────────────────────────────────────

        /// Resolve a filter value that may be either canonical or API label.
        /// Returns the canonical value. If neither match, returns the input unchanged.
        /// category: "type", "status", "tag", "season", "denomination", "format",
        ///           "source", "directive", "ownerType"
        public static string ResolveCanonical(string category, string value) {
            if (string.IsNullOrEmpty(value)) return value;

            switch (category.ToLowerInvariant()) {
                case "type":
                    if (_typeToLabel.ContainsKey(value)) return value;
                    if (_labelToType.TryGetValue(value, out string t)) return t;
                    break;
                case "status":
                    if (_statusToLabel.ContainsKey(value)) return value;
                    if (_labelToStatus.TryGetValue(value, out string s)) return s;
                    break;
                case "tag":
                    if (_tagToLabel.ContainsKey(value)) return value;
                    if (_labelToTag.TryGetValue(value, out string tg)) return tg;
                    break;
                case "season":
                    if (_seasonToLabel.ContainsKey(value)) return value;
                    if (_labelToSeason.TryGetValue(value, out string sn)) return sn;
                    break;
                case "denomination":
                    if (_denomToLabel.ContainsKey(value)) return value;
                    if (_labelToDenom.TryGetValue(value, out string d)) return d;
                    break;
                case "format":
                    if (_formatToLabel.ContainsKey(value)) return value;
                    if (_labelToFormat.TryGetValue(value, out string f)) return f;
                    break;
                case "source":
                    if (_sourceToLabel.ContainsKey(value)) return value;
                    if (_labelToSource.TryGetValue(value, out string src)) return src;
                    break;
                case "directive":
                    if (_directiveToLabel.ContainsKey(value)) return value;
                    if (_labelToDirective.TryGetValue(value, out string dir)) return dir;
                    break;
            }

            return value; // passthrough — unknown value
        }

        /// Get the API label for a canonical value.
        /// Returns null if no mapping exists (value is already API-safe or unknown).
        public static string GetLabel(string category, string canonicalValue) {
            if (string.IsNullOrEmpty(canonicalValue)) return null;

            switch (category.ToLowerInvariant()) {
                case "type":
                    return _typeToLabel.TryGetValue(canonicalValue, out string t) ? t : null;
                case "status":
                    return _statusToLabel.TryGetValue(canonicalValue, out string s) ? s : null;
                case "tag":
                    return _tagToLabel.TryGetValue(canonicalValue, out string tg) ? tg : null;
                case "season":
                    return _seasonToLabel.TryGetValue(canonicalValue, out string sn) ? sn : null;
                case "denomination":
                    return _denomToLabel.TryGetValue(canonicalValue, out string d) ? d : null;
                case "format":
                    return _formatToLabel.TryGetValue(canonicalValue, out string f) ? f : null;
                case "source":
                    return _sourceToLabel.TryGetValue(canonicalValue, out string src) ? src : null;
                case "directive":
                    return _directiveToLabel.TryGetValue(canonicalValue, out string dir) ? dir : null;
                case "ownertype":
                    return _ownerTypeToLabel.TryGetValue(canonicalValue, out string ot) ? ot : null;
            }

            return null;
        }

        /// Return the full schema for the /schema discovery endpoint.
        /// Returns a Dictionary keyed by category name, each containing
        /// a list of {canonical, label} pairs.
        public static Dictionary<string, List<Dictionary<string, string>>> GetSchema() {
            var schema = new Dictionary<string, List<Dictionary<string, string>>>(
                StringComparer.OrdinalIgnoreCase);

            schema["entityTypes"]  = ToDictList(_typeToLabel);
            schema["statuses"]     = ToDictList(_statusToLabel);
            schema["tags"]         = ToDictList(_tagToLabel);
            schema["seasons"]      = ToDictList(_seasonToLabel);
            schema["formats"]      = ToDictList(_formatToLabel);
            schema["sources"]      = ToDictList(_sourceToLabel);
            schema["directives"]   = ToDictList(_directiveToLabel);
            schema["ownerTypes"]   = ToDictList(_ownerTypeToLabel);

            // Denominations have extra fields — build manually
            var denoms = new List<Dictionary<string, string>> {
                new Dictionary<string, string> {
                    ["canonical"] = "Korony Elanckie", ["short"] = "Korony",
                    ["label"] = "gold", ["tier"] = "Gold", ["multiplier"] = "10000"
                },
                new Dictionary<string, string> {
                    ["canonical"] = "Talary Hirońskie", ["short"] = "Talary",
                    ["label"] = "silver", ["tier"] = "Silver", ["multiplier"] = "100"
                },
                new Dictionary<string, string> {
                    ["canonical"] = "Kogi Skeltvorskie", ["short"] = "Kogi",
                    ["label"] = "copper", ["tier"] = "Copper", ["multiplier"] = "1"
                }
            };
            schema["denominations"] = denoms;

            return schema;
        }

        // ── Helpers ───────────────────────────────────────────────────────

        private static Dictionary<string, string> BuildReverse(
            Dictionary<string, string> forward) {
            var reverse = new Dictionary<string, string>(
                forward.Count, StringComparer.OrdinalIgnoreCase);
            foreach (var kvp in forward) {
                // Only add first occurrence (canonical → label is 1:1,
                // but label → canonical may have duplicates like Korony/Korony Elanckie)
                if (!reverse.ContainsKey(kvp.Value))
                    reverse[kvp.Value] = kvp.Key;
            }
            return reverse;
        }

        private static List<Dictionary<string, string>> ToDictList(
            Dictionary<string, string> map) {
            var list = new List<Dictionary<string, string>>(map.Count);
            foreach (var kvp in map) {
                list.Add(new Dictionary<string, string> {
                    ["canonical"] = kvp.Key,
                    ["label"] = kvp.Value
                });
            }
            return list;
        }
    }
}
