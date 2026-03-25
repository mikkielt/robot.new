using System;
using System.Collections.Generic;
using System.IO;
using System.Text.Json;

namespace Robot {
    /// Loads help sidecar files from a directory and serves field-level help queries.
    /// Static after Load() — thread-safe for RunspacePool.
    ///
    /// Data layout: plugins/robot-api/help/*.help.json — one file per component.
    /// Each file is a JSON object with "component" and "endpoints" (or "zones"/"categories").
    ///
    /// Query API:
    ///   GetComponents() → list of component names
    ///   GetHelp(component, lang, include) → filtered help object
    ///
    /// Consumers: /help static route (api-routes.ps1),
    ///            future CLI help unification
    public static class ApiHelpRegistry {
        private static Dictionary<string, JsonElement> _registry;
        private static string[] _componentNames;

        /// Load help data from a directory of *.help.json files.
        /// Called once by Start-RobotApi.
        /// directoryPath: absolute path to the help/ directory.
        public static void Load(string directoryPath) {
            _registry = new Dictionary<string, JsonElement>(
                StringComparer.OrdinalIgnoreCase);
            var names = new List<string>();
            foreach (var file in Directory.GetFiles(directoryPath, "*.help.json")) {
                using (var doc = JsonDocument.Parse(File.ReadAllText(file))) {
                    string componentName;
                    if (doc.RootElement.TryGetProperty("component", out var compProp)
                        && compProp.ValueKind == JsonValueKind.String) {
                        componentName = compProp.GetString();
                    } else {
                        componentName = Path.GetFileNameWithoutExtension(file)
                            .Replace(".help", "");
                    }
                    _registry[componentName] = doc.RootElement.Clone();
                    names.Add(componentName);
                }
            }
            names.Sort(StringComparer.OrdinalIgnoreCase);
            _componentNames = names.ToArray();
        }

        /// List all available help component names.
        public static string[] GetComponents() {
            return _componentNames ?? Array.Empty<string>();
        }

        /// Get help for a component with optional language and field filtering.
        /// lang: "pl" or "en" (null = return all languages).
        /// include: comma-separated field property names to keep
        ///          (e.g. "description,format"); null = return all.
        /// Returns a Dictionary suitable for JSON serialization, or null
        /// if component not found.
        public static object GetHelp(string component, string lang,
                                      string include) {
            if (_registry == null || !_registry.TryGetValue(
                    component, out JsonElement root))
                return null;

            // Parse include filter
            HashSet<string> includeSet = null;
            if (!string.IsNullOrEmpty(include)) {
                includeSet = new HashSet<string>(
                    include.Split(','),
                    StringComparer.OrdinalIgnoreCase);
                includeSet.Add("name");
            }

            var result = new Dictionary<string, object>(
                StringComparer.OrdinalIgnoreCase);
            result["component"] = component;

            // Standard API components have "endpoints" array
            if (root.TryGetProperty("endpoints", out var endpoints)
                && endpoints.ValueKind == JsonValueKind.Array) {
                result["endpoints"] = FilterEndpoints(endpoints, lang, includeSet);
                return result;
            }

            // Editor component uses "zones" object
            if (root.TryGetProperty("zones", out var zones)
                && zones.ValueKind == JsonValueKind.Object) {
                result["zones"] = FilterLangObject(zones, lang, includeSet);
                return result;
            }

            // CLI component uses "categories" object
            if (root.TryGetProperty("categories", out var cats)
                && cats.ValueKind == JsonValueKind.Object) {
                result["categories"] = FilterLangObject(cats, lang, includeSet);
                return result;
            }

            // Unknown structure — return raw
            result["data"] = JsonToObject(root);
            return result;
        }

        /// Filter endpoints array by language and include set.
        /// Each endpoint has method, path, handler, scope, pl{}, en{}.
        private static List<object> FilterEndpoints(JsonElement endpoints,
            string lang, HashSet<string> includeSet) {
            var list = new List<object>();
            foreach (var ep in endpoints.EnumerateArray()) {
                var entry = new Dictionary<string, object>(
                    StringComparer.OrdinalIgnoreCase);

                // Always include structural fields
                if (ep.TryGetProperty("method", out var m))
                    entry["method"] = m.GetString();
                if (ep.TryGetProperty("path", out var p))
                    entry["path"] = p.GetString();
                if (ep.TryGetProperty("handler", out var h))
                    entry["handler"] = h.GetString();
                if (ep.TryGetProperty("scope", out var s))
                    entry["scope"] = s.ValueKind == JsonValueKind.Null
                        ? null : s.GetString();

                // Language content
                string[] langs = !string.IsNullOrEmpty(lang)
                    ? new[] { lang }
                    : new[] { "pl", "en" };

                foreach (var l in langs) {
                    if (ep.TryGetProperty(l, out var langObj)
                        && langObj.ValueKind == JsonValueKind.Object) {
                        entry[l] = includeSet != null
                            ? FilterLangContent(langObj, includeSet)
                            : JsonToObject(langObj);
                    }
                }

                list.Add(entry);
            }
            return list;
        }

        /// Filter language content object (description + bodyFields/queryParams arrays).
        /// Keeps only properties in the include set within field/param objects.
        private static object FilterLangContent(JsonElement langObj,
            HashSet<string> includeSet) {
            var filtered = new Dictionary<string, object>(
                StringComparer.OrdinalIgnoreCase);

            foreach (var prop in langObj.EnumerateObject()) {
                if (string.Equals(prop.Name, "description",
                        StringComparison.OrdinalIgnoreCase)) {
                    // Always include description
                    filtered["description"] = prop.Value.GetString();
                } else if (prop.Value.ValueKind == JsonValueKind.Array) {
                    // bodyFields or queryParams — filter properties within each item
                    var items = new List<Dictionary<string, object>>();
                    foreach (var item in prop.Value.EnumerateArray()) {
                        if (item.ValueKind != JsonValueKind.Object) continue;
                        var f = new Dictionary<string, object>(
                            StringComparer.OrdinalIgnoreCase);
                        foreach (var fp in item.EnumerateObject()) {
                            if (includeSet.Contains(fp.Name))
                                f[fp.Name] = JsonToObject(fp.Value);
                        }
                        if (f.Count > 0) items.Add(f);
                    }
                    filtered[prop.Name] = items;
                } else {
                    // Pass through other keys
                    filtered[prop.Name] = JsonToObject(prop.Value);
                }
            }

            return filtered;
        }

        /// Filter zones/categories object by language.
        /// Structure: { "zoneName": { "pl": {...}, "en": {...} }, ... }
        private static object FilterLangObject(JsonElement obj, string lang,
            HashSet<string> includeSet) {
            var result = new Dictionary<string, object>(
                StringComparer.OrdinalIgnoreCase);

            foreach (var item in obj.EnumerateObject()) {
                if (item.Value.ValueKind == JsonValueKind.Object) {
                    var entry = new Dictionary<string, object>(
                        StringComparer.OrdinalIgnoreCase);
                    string[] langs = !string.IsNullOrEmpty(lang)
                        ? new[] { lang }
                        : new[] { "pl", "en" };

                    foreach (var l in langs) {
                        if (item.Value.TryGetProperty(l, out var langObj)) {
                            entry[l] = JsonToObject(langObj);
                        }
                    }
                    if (entry.Count > 0)
                        result[item.Name] = entry;
                } else {
                    result[item.Name] = JsonToObject(item.Value);
                }
            }

            return result;
        }

        /// Convert System.Text.Json element to serialization-friendly object.
        private static object JsonToObject(JsonElement el) {
            switch (el.ValueKind) {
                case JsonValueKind.String:  return el.GetString();
                case JsonValueKind.Number:  return el.GetDecimal();
                case JsonValueKind.True:    return true;
                case JsonValueKind.False:   return false;
                case JsonValueKind.Null:    return null;
                case JsonValueKind.Array:
                    var list = new List<object>();
                    foreach (var item in el.EnumerateArray())
                        list.Add(JsonToObject(item));
                    return list;
                case JsonValueKind.Object:
                    var dict = new Dictionary<string, object>(
                        StringComparer.OrdinalIgnoreCase);
                    foreach (var prop in el.EnumerateObject())
                        dict[prop.Name] = JsonToObject(prop.Value);
                    return dict;
                default: return el.ToString();
            }
        }
    }
}
