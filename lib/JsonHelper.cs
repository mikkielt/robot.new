using System;
using System.Collections;
using System.Collections.Generic;
using System.IO;
using System.Text;
using System.Text.Json;

namespace Robot {
    /// Fast JSON serializer/deserializer using System.Text.Json.
    ///
    /// Compiled C# replaces PowerShell's ConvertTo-Json / ConvertFrom-Json which
    /// allocated large intermediate PSObject trees and performed ~50ms of property
    /// enumeration per file. The C# version parses directly to Hashtable/Dictionary
    /// in ~2ms for typical 500-entry session graph index files.
    ///
    /// Read methods:
    /// - ReadAsHashtable: recursive conversion to case-insensitive Hashtable, matching
    ///   ConvertFrom-Json -AsHashtable semantics. Numbers try int -> long -> double.
    ///   No DateTime auto-conversion (strings preserved as-is for hash stability).
    /// - ReadAsStringDictionary: flat Dictionary<string, string> for hash sidecar files
    ///   (header -> SHA256 mapping).
    ///
    /// Write methods:
    /// - WriteSortedJson: Ordinal-sorted keys at all levels with 4-space indentation
    ///   to match ConvertTo-Json output format for clean git diffs. Creates parent
    ///   directories as needed. UTF-8 no BOM. maxDepth prevents infinite recursion
    ///   on circular references (stringifies beyond depth).
    ///
    /// String encoding handles JSON control characters and passes Unicode (including
    /// Polish diacritics) through unescaped.
    ///
    /// Consumers: session-graphhelpers.ps1 (index, metadata, cache),
    /// session-hashhelpers.ps1 (sidecar read/write, metadata)
    public sealed class JsonHelper {
        private static readonly UTF8Encoding Utf8NoBom = new UTF8Encoding(false);

        // ── Read ────────────────────────────────────────────────────────

        /// Read JSON file into a case-insensitive Hashtable (recursive).
        /// Nested objects become Hashtable, arrays become object[].
        /// Numbers: int if fits, else long, else double.
        /// Strings preserved as-is (no DateTime auto-conversion).
        /// Returns empty Hashtable if root element is not an object.
        public static Hashtable ReadAsHashtable(string path) {
            string json = File.ReadAllText(path, Utf8NoBom);
            using (JsonDocument doc = JsonDocument.Parse(json)) {
                if (doc.RootElement.ValueKind != JsonValueKind.Object)
                    return new Hashtable(StringComparer.OrdinalIgnoreCase);
                return ElementToHashtable(doc.RootElement);
            }
        }

        /// Read JSON file into a flat Dictionary<string, string>
        /// with OrdinalIgnoreCase comparer. Null values become empty string.
        /// Designed for hash sidecar files (header -> SHA256 mapping).
        public static Dictionary<string, string> ReadAsStringDictionary(string path) {
            string json = File.ReadAllText(path, Utf8NoBom);
            var result = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            using (JsonDocument doc = JsonDocument.Parse(json)) {
                if (doc.RootElement.ValueKind != JsonValueKind.Object)
                    return result;
                foreach (JsonProperty prop in doc.RootElement.EnumerateObject()) {
                    string val = prop.Value.ValueKind == JsonValueKind.Null
                        ? string.Empty
                        : (prop.Value.GetString() ?? string.Empty);
                    result[prop.Name] = val;
                }
            }
            return result;
        }

        // ── Write ───────────────────────────────────────────────────────

        /// Write IDictionary to JSON file with Ordinal-sorted keys at all levels.
        /// Uses 4-space indentation to match ConvertTo-Json output format for clean
        /// git diffs. Creates parent directories as needed. UTF-8 no BOM.
        /// maxDepth prevents runaway recursion — values beyond depth are stringified.
        public static void WriteSortedJson(string path, IDictionary data, int maxDepth) {
            string dir = Path.GetDirectoryName(path);
            if (!string.IsNullOrEmpty(dir) && !Directory.Exists(dir)) {
                Directory.CreateDirectory(dir);
            }
            var sb = new StringBuilder();
            WriteDict(sb, data, 0, maxDepth);
            File.WriteAllText(path, sb.ToString(), Utf8NoBom);
        }

        // ── Read helpers ────────────────────────────────────────────────

        private static Hashtable ElementToHashtable(JsonElement element) {
            var ht = new Hashtable(StringComparer.OrdinalIgnoreCase);
            foreach (JsonProperty prop in element.EnumerateObject()) {
                ht[prop.Name] = ConvertElement(prop.Value);
            }
            return ht;
        }

        private static object ConvertElement(JsonElement element) {
            switch (element.ValueKind) {
                case JsonValueKind.Object:
                    return ElementToHashtable(element);
                case JsonValueKind.Array:
                    int len = element.GetArrayLength();
                    var arr = new object[len];
                    int idx = 0;
                    foreach (JsonElement item in element.EnumerateArray()) {
                        arr[idx++] = ConvertElement(item);
                    }
                    return arr;
                case JsonValueKind.String:
                    return element.GetString();
                case JsonValueKind.Number:
                    if (element.TryGetInt32(out int intVal)) return intVal;
                    if (element.TryGetInt64(out long longVal)) return longVal;
                    return element.GetDouble();
                case JsonValueKind.True:
                    return true;
                case JsonValueKind.False:
                    return false;
                case JsonValueKind.Null:
                case JsonValueKind.Undefined:
                default:
                    return null;
            }
        }

        // ── Write helpers ───────────────────────────────────────────────

        private static void WriteDict(StringBuilder sb, IDictionary dict, int depth, int maxDepth) {
            // Sort keys with Ordinal comparer (matches PowerShell callers)
            var keys = new List<string>(dict.Count);
            foreach (var key in dict.Keys) keys.Add(key != null ? key.ToString() : "");
            keys.Sort(StringComparer.Ordinal);

            sb.Append('{');
            if (keys.Count == 0) { sb.Append('}'); return; }

            string propIndent = new string(' ', (depth + 1) * 4);
            string closeIndent = depth > 0 ? new string(' ', depth * 4) : "";

            for (int i = 0; i < keys.Count; i++) {
                if (i > 0) sb.Append(',');
                sb.Append('\n').Append(propIndent);
                WriteJsonString(sb, keys[i]);
                sb.Append(": ");
                WriteValue(sb, dict[keys[i]], depth + 1, maxDepth);
            }
            sb.Append('\n').Append(closeIndent).Append('}');
        }

        private static void WriteArray(StringBuilder sb, IList list, int depth, int maxDepth) {
            sb.Append('[');
            if (list.Count == 0) { sb.Append(']'); return; }

            string itemIndent = new string(' ', depth * 4);
            string closeIndent = new string(' ', (depth - 1) * 4);

            for (int i = 0; i < list.Count; i++) {
                if (i > 0) sb.Append(',');
                sb.Append('\n').Append(itemIndent);
                WriteValue(sb, list[i], depth, maxDepth);
            }
            sb.Append('\n').Append(closeIndent).Append(']');
        }

        private static void WriteValue(StringBuilder sb, object value, int depth, int maxDepth) {
            if (value == null || value is DBNull) { sb.Append("null"); return; }
            if (value is string s) { WriteJsonString(sb, s); return; }
            if (value is bool b) { sb.Append(b ? "true" : "false"); return; }
            if (value is int iv) { sb.Append(iv); return; }
            if (value is long lv) { sb.Append(lv); return; }
            if (value is double dv) {
                sb.Append(dv.ToString(System.Globalization.CultureInfo.InvariantCulture));
                return;
            }
            if (value is decimal decv) {
                sb.Append(decv.ToString(System.Globalization.CultureInfo.InvariantCulture));
                return;
            }
            if (value is float fv) {
                sb.Append(fv.ToString(System.Globalization.CultureInfo.InvariantCulture));
                return;
            }

            // Beyond max depth: stringify
            if (depth > maxDepth) { WriteJsonString(sb, value.ToString()); return; }

            if (value is IDictionary dict) { WriteDict(sb, dict, depth, maxDepth); return; }
            if (value is IList list) { WriteArray(sb, list, depth, maxDepth); return; }

            // Fallback: convert to string
            WriteJsonString(sb, value.ToString());
        }

        private static void WriteJsonString(StringBuilder sb, string s) {
            sb.Append('"');
            if (s != null) {
                for (int i = 0; i < s.Length; i++) {
                    char c = s[i];
                    switch (c) {
                        case '"': sb.Append("\\\""); break;
                        case '\\': sb.Append("\\\\"); break;
                        case '\n': sb.Append("\\n"); break;
                        case '\r': sb.Append("\\r"); break;
                        case '\t': sb.Append("\\t"); break;
                        case '\b': sb.Append("\\b"); break;
                        case '\f': sb.Append("\\f"); break;
                        default:
                            if (c < 0x20)  // control chars: Unicode escape; all others (including Polish diacritics) pass through
                                sb.AppendFormat("\\u{0:x4}", (int)c);
                            else
                                sb.Append(c);
                            break;
                    }
                }
            }
            sb.Append('"');
        }
    }
}
