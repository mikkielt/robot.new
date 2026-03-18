using System;
using System.Collections.Generic;
using System.IO;
using System.Text;
using System.Text.Json;

namespace Robot {
    /// Disk sidecar persistence layer for MarkdownScanner.ScanResult objects,
    /// enabling cross-session and cross-process cache reuse without re-parsing
    /// Markdown files.
    ///
    /// Uses hand-rolled StringBuilder serialization with compact single-character JSON
    /// keys ("L", "T", "P", "N" for Level, Text, ParentIndex,
    /// LineNumber) to minimize disk footprint and parse time. System.Text.Json
    /// is used for meta/index files; ScanResult uses manual StringBuilder
    /// serialization for maximum control over key naming and null handling.
    ///
    /// The disk cache lives at {RepoRoot}/.robot.local/.cache/markdown/ and is populated
    /// lazily on parse, checked on cache miss before re-parsing. ScanResult uses
    /// index-based parent references (int ParentIndex, int HeaderIndex) which
    /// serialize cleanly as JSON integers. The PowerShell layer
    /// (parse-markdownfile.ps1) reconstructs object references from indices on
    /// deserialization — the same code path as fresh MarkdownScanner output.
    ///
    /// Version gating: CacheVersion constant in meta gates compatibility.
    /// Mismatched versions invalidate the entire cache tier, forcing a full
    /// re-parse. Bump CacheVersion when ScanResult schema changes.
    ///
    /// Meta/index files use Dictionary<string, object> with nested hashtables
    /// for flexible schema evolution. WriteSortedJson ensures deterministic key
    /// ordering for diff-friendly output.
    ///
    /// Thread safety: all methods are static and stateless. File I/O is not
    /// locked — callers must ensure no concurrent writes to the same path.
    /// All written files use UTF-8 no BOM encoding, consistent with the
    /// module-wide convention.
    ///
    /// Consumers: get-markdown.ps1 (6 call sites for disk cache tier),
    /// Robot.PowerShell.psm1 (2 call sites for cache clear on module reload)
    public sealed class ParseCacheHelper {
        private static readonly UTF8Encoding Utf8NoBom = new UTF8Encoding(false);
        private static readonly JsonSerializerOptions WriteOptions = new JsonSerializerOptions {
            WriteIndented = false
        };

        // ── Cache format version ──────────────────────────────────────
        // Stored in meta.json; mismatched versions trigger full cache invalidation.
        // Bump when ScanResult schema changes (new fields, renamed keys, etc.).
        public const int CacheVersion = 1;

        // ── ScanResult serialization ─────────────────────────────────

        /// Serialize a MarkdownScanner.ScanResult to a compact JSON string using
        /// manual StringBuilder construction with single-character keys.
        /// Initial capacity of 4096 avoids reallocations for typical file sizes.
        /// Null-safe: returns "null" for null input.
        public static string SerializeScanResult(MarkdownScanner.ScanResult result) {
            if (result == null) return "null";

            var sb = new StringBuilder(4096);
            sb.Append("{\"Headers\":");
            WriteHeaderArray(sb, result.Headers);
            sb.Append(",\"Sections\":");
            WriteSectionArray(sb, result.Sections);
            sb.Append(",\"Lists\":");
            WriteListArray(sb, result.Lists);
            sb.Append(",\"Links\":");
            WriteLinkArray(sb, result.Links);
            sb.Append('}');
            return sb.ToString();
        }

        /// Deserialize a JSON string back to MarkdownScanner.ScanResult.
        /// Returns null on invalid/empty input or corrupt JSON (catch-all
        /// ensures a bad cache file triggers a full re-parse, not an error).
        /// Missing fields gracefully default to empty arrays for forward
        /// compatibility when new ScanResult fields are added.
        public static MarkdownScanner.ScanResult DeserializeScanResult(string json) {
            if (string.IsNullOrEmpty(json) || json == "null") return null;

            try {
                using (JsonDocument doc = JsonDocument.Parse(json)) {
                    var root = doc.RootElement;
                    var result = new MarkdownScanner.ScanResult();

                    result.Headers = root.TryGetProperty("Headers", out JsonElement hElem)
                        ? ReadHeaderArray(hElem)
                        : Array.Empty<MarkdownScanner.HeaderEntry>();

                    result.Sections = root.TryGetProperty("Sections", out JsonElement sElem)
                        ? ReadSectionArray(sElem)
                        : Array.Empty<MarkdownScanner.SectionEntry>();

                    result.Lists = root.TryGetProperty("Lists", out JsonElement lElem)
                        ? ReadListArray(lElem)
                        : Array.Empty<MarkdownScanner.ListEntry>();

                    result.Links = root.TryGetProperty("Links", out JsonElement linkElem)
                        ? ReadLinkArray(linkElem)
                        : Array.Empty<MarkdownScanner.LinkEntry>();

                    return result;
                }
            } catch {
                // Corrupt cache file — return null so caller falls through to full parse
                return null;
            }
        }

        // ── File-level helpers ───────────────────────────────────────

        /// Write ScanResult JSON to a file path. Creates parent directories
        /// as needed for first-time cache population. UTF-8 no BOM.
        public static void WriteScanResultToFile(string path, MarkdownScanner.ScanResult result) {
            string dir = Path.GetDirectoryName(path);
            if (!string.IsNullOrEmpty(dir) && !Directory.Exists(dir)) {
                Directory.CreateDirectory(dir);
            }
            string json = SerializeScanResult(result);
            File.WriteAllText(path, json, Utf8NoBom);
        }

        /// Read ScanResult from a JSON cache file. Returns null if the file
        /// doesn't exist or contains invalid data, signaling the caller to
        /// fall through to a full Markdown parse.
        public static MarkdownScanner.ScanResult ReadScanResultFromFile(string path) {
            if (!File.Exists(path)) return null;
            try {
                string json = File.ReadAllText(path, Utf8NoBom);
                return DeserializeScanResult(json);
            } catch {
                return null;
            }
        }

        /// Write a meta or index dictionary to JSON file with deterministic
        /// sorted keys via Robot.JsonHelper.WriteSortedJson, ensuring
        /// diff-friendly output. Creates parent directories as needed.
        public static void WriteMetaFile(string path, System.Collections.IDictionary data) {
            JsonHelper.WriteSortedJson(path, data, 4);
        }

        /// Read a meta or index file as a case-insensitive Hashtable.
        /// Returns empty Hashtable on missing or corrupt file to avoid null
        /// propagation in the PowerShell cache validation logic.
        public static System.Collections.Hashtable ReadMetaFile(string path) {
            if (!File.Exists(path)) {
                return new System.Collections.Hashtable(StringComparer.OrdinalIgnoreCase);
            }
            try {
                return JsonHelper.ReadAsHashtable(path);
            } catch {
                return new System.Collections.Hashtable(StringComparer.OrdinalIgnoreCase);
            }
        }

        /// Delete the entire .cache directory tree for full cache invalidation.
        /// Silently succeeds if directory doesn't exist. Best-effort on Windows
        /// where locked files may prevent complete removal.
        public static void DeleteCacheDirectory(string cacheDir) {
            if (Directory.Exists(cacheDir)) {
                try {
                    Directory.Delete(cacheDir, true);
                } catch {
                    // Best-effort deletion — locked files on Windows may prevent full removal
                }
            }
        }

        // ── Header serialization ─────────────────────────────────────

        private static void WriteHeaderArray(StringBuilder sb, MarkdownScanner.HeaderEntry[] headers) {
            sb.Append('[');
            if (headers != null) {
                for (int i = 0; i < headers.Length; i++) {
                    if (i > 0) sb.Append(',');
                    sb.Append("{\"L\":");
                    sb.Append(headers[i].Level);
                    sb.Append(",\"T\":");
                    WriteJsonString(sb, headers[i].Text);
                    sb.Append(",\"P\":");
                    sb.Append(headers[i].ParentIndex);
                    sb.Append(",\"N\":");
                    sb.Append(headers[i].LineNumber);
                    sb.Append('}');
                }
            }
            sb.Append(']');
        }

        private static MarkdownScanner.HeaderEntry[] ReadHeaderArray(JsonElement elem) {
            if (elem.ValueKind != JsonValueKind.Array) return Array.Empty<MarkdownScanner.HeaderEntry>();
            int len = elem.GetArrayLength();
            var arr = new MarkdownScanner.HeaderEntry[len];
            int idx = 0;
            foreach (JsonElement item in elem.EnumerateArray()) {
                arr[idx].Level = item.TryGetProperty("L", out JsonElement lv) ? lv.GetInt32() : 0;
                arr[idx].Text = item.TryGetProperty("T", out JsonElement tv) ? tv.GetString() : "";
                arr[idx].ParentIndex = item.TryGetProperty("P", out JsonElement pv) ? pv.GetInt32() : -1;
                arr[idx].LineNumber = item.TryGetProperty("N", out JsonElement nv) ? nv.GetInt32() : 0;
                idx++;
            }
            return arr;
        }

        // ── Section serialization ────────────────────────────────────

        private static void WriteSectionArray(StringBuilder sb, MarkdownScanner.SectionEntry[] sections) {
            sb.Append('[');
            if (sections != null) {
                for (int i = 0; i < sections.Length; i++) {
                    if (i > 0) sb.Append(',');
                    sb.Append("{\"H\":");
                    sb.Append(sections[i].HeaderIndex);
                    sb.Append(",\"C\":");
                    WriteJsonString(sb, sections[i].Content);
                    sb.Append(",\"LS\":");
                    sb.Append(sections[i].ListStartIndex);
                    sb.Append(",\"LC\":");
                    sb.Append(sections[i].ListCount);
                    sb.Append('}');
                }
            }
            sb.Append(']');
        }

        private static MarkdownScanner.SectionEntry[] ReadSectionArray(JsonElement elem) {
            if (elem.ValueKind != JsonValueKind.Array) return Array.Empty<MarkdownScanner.SectionEntry>();
            int len = elem.GetArrayLength();
            var arr = new MarkdownScanner.SectionEntry[len];
            int idx = 0;
            foreach (JsonElement item in elem.EnumerateArray()) {
                arr[idx].HeaderIndex = item.TryGetProperty("H", out JsonElement hv) ? hv.GetInt32() : -1;
                arr[idx].Content = item.TryGetProperty("C", out JsonElement cv) ? cv.GetString() : "";
                arr[idx].ListStartIndex = item.TryGetProperty("LS", out JsonElement lsv) ? lsv.GetInt32() : 0;
                arr[idx].ListCount = item.TryGetProperty("LC", out JsonElement lcv) ? lcv.GetInt32() : 0;
                idx++;
            }
            return arr;
        }

        // ── List item serialization ──────────────────────────────────

        private static void WriteListArray(StringBuilder sb, MarkdownScanner.ListEntry[] lists) {
            sb.Append('[');
            if (lists != null) {
                for (int i = 0; i < lists.Length; i++) {
                    if (i > 0) sb.Append(',');
                    sb.Append("{\"Y\":");
                    WriteJsonString(sb, lists[i].Type);
                    sb.Append(",\"T\":");
                    WriteJsonString(sb, lists[i].Text);
                    sb.Append(",\"I\":");
                    sb.Append(lists[i].Indent);
                    sb.Append(",\"P\":");
                    sb.Append(lists[i].ParentIndex);
                    sb.Append(",\"S\":");
                    sb.Append(lists[i].SectionHeaderIndex);
                    sb.Append('}');
                }
            }
            sb.Append(']');
        }

        private static MarkdownScanner.ListEntry[] ReadListArray(JsonElement elem) {
            if (elem.ValueKind != JsonValueKind.Array) return Array.Empty<MarkdownScanner.ListEntry>();
            int len = elem.GetArrayLength();
            var arr = new MarkdownScanner.ListEntry[len];
            int idx = 0;
            foreach (JsonElement item in elem.EnumerateArray()) {
                arr[idx] = new MarkdownScanner.ListEntry();
                arr[idx].Type = item.TryGetProperty("Y", out JsonElement yv) ? yv.GetString() : "Bullet";
                arr[idx].Text = item.TryGetProperty("T", out JsonElement tv) ? tv.GetString() : "";
                arr[idx].Indent = item.TryGetProperty("I", out JsonElement iv) ? iv.GetInt32() : 0;
                arr[idx].ParentIndex = item.TryGetProperty("P", out JsonElement pv) ? pv.GetInt32() : -1;
                arr[idx].SectionHeaderIndex = item.TryGetProperty("S", out JsonElement sv) ? sv.GetInt32() : -1;
                idx++;
            }
            return arr;
        }

        // ── Link serialization ───────────────────────────────────────

        private static void WriteLinkArray(StringBuilder sb, MarkdownScanner.LinkEntry[] links) {
            sb.Append('[');
            if (links != null) {
                for (int i = 0; i < links.Length; i++) {
                    if (i > 0) sb.Append(',');
                    sb.Append("{\"Y\":");
                    WriteJsonString(sb, links[i].Type);
                    sb.Append(",\"T\":");
                    WriteJsonString(sb, links[i].Text);
                    sb.Append(",\"U\":");
                    WriteJsonString(sb, links[i].Url);
                    sb.Append('}');
                }
            }
            sb.Append(']');
        }

        private static MarkdownScanner.LinkEntry[] ReadLinkArray(JsonElement elem) {
            if (elem.ValueKind != JsonValueKind.Array) return Array.Empty<MarkdownScanner.LinkEntry>();
            int len = elem.GetArrayLength();
            var arr = new MarkdownScanner.LinkEntry[len];
            int idx = 0;
            foreach (JsonElement item in elem.EnumerateArray()) {
                arr[idx].Type = item.TryGetProperty("Y", out JsonElement yv) ? yv.GetString() : "PlainUrl";
                arr[idx].Text = item.TryGetProperty("T", out JsonElement tv) ? tv.GetString() : null;
                arr[idx].Url = item.TryGetProperty("U", out JsonElement uv) ? uv.GetString() : "";
                idx++;
            }
            return arr;
        }

        // ── JSON string encoding ─────────────────────────────────────
        // Manual escape loop instead of JsonSerializer to keep Polish diacritics
        // (ą, ę, ó, ś, ź, ż, ć, ń, ł) unescaped for human readability in cache
        // files. Only ASCII control characters and JSON-special characters are
        // escaped.

        private static void WriteJsonString(StringBuilder sb, string s) {
            if (s == null) { sb.Append("null"); return; }
            sb.Append('"');
            for (int i = 0; i < s.Length; i++) {
                char c = s[i];
                switch (c) {
                    case '"':  sb.Append("\\\""); break;
                    case '\\': sb.Append("\\\\"); break;
                    case '\n': sb.Append("\\n"); break;
                    case '\r': sb.Append("\\r"); break;
                    case '\t': sb.Append("\\t"); break;
                    case '\b': sb.Append("\\b"); break;
                    case '\f': sb.Append("\\f"); break;
                    default:
                        if (c < 0x20)
                            sb.AppendFormat("\\u{0:x4}", (int)c);
                        else
                            sb.Append(c);
                        break;
                }
            }
            sb.Append('"');
        }
    }
}
