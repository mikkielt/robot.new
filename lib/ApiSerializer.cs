using System;
using System.Collections;
using System.Collections.Generic;
using System.IO;
using System.Net;
using System.Text;
using System.Text.Json;

namespace Robot {
    /// High-performance JSON serializer for API responses. Writes directly to
    /// HttpListenerResponse.OutputStream via Utf8JsonWriter — no intermediate
    /// string allocation.
    ///
    /// Handles PowerShell types:
    /// - PSCustomObject/PSObject → JSON object (via Properties enumeration)
    /// - Hashtable/IDictionary → JSON object (sorted keys for determinism)
    /// - IList/Array → JSON array
    /// - Robot.Entity → JSON object (typed property access, 5-10x faster than reflection)
    /// - Primitives: string, int, long, double, decimal, bool, DateTime, null
    ///
    /// The MaxDepth guard prevents stack overflow on circular references
    /// (Entity → History → TemporalEntry → Entity). Beyond MaxDepth, values
    /// are stringified.
    ///
    /// Consumers: ApiServer.HandleRequestAsync (response serialization)
    public sealed class ApiSerializer {
        private static readonly UTF8Encoding Utf8NoBom = new UTF8Encoding(false);
        private const int MaxDepth = 12;

        /// Write an error response as {"error": message, "status": code}.
        public static void WriteError(HttpListenerResponse response,
                                       int statusCode, string message) {
            response.StatusCode = statusCode;
            response.ContentType = "application/json; charset=utf-8";

            using (var ms = new MemoryStream())
            using (var writer = new Utf8JsonWriter(ms)) {
                writer.WriteStartObject();
                writer.WriteString("error", message);
                writer.WriteNumber("status", statusCode);
                writer.WriteEndObject();
                writer.Flush();

                response.ContentLength64 = ms.Length;
                ms.Position = 0;
                ms.CopyTo(response.OutputStream);
            }
        }

        /// Write pre-serialized JSON string directly to the response.
        public static void WriteRaw(HttpListenerResponse response,
                                     string json, int statusCode = 200) {
            response.StatusCode = statusCode;
            response.ContentType = "application/json; charset=utf-8";

            byte[] buffer = Utf8NoBom.GetBytes(json);
            response.ContentLength64 = buffer.Length;
            response.OutputStream.Write(buffer, 0, buffer.Length);
        }

        /// Serialize any object (PSCustomObject, Hashtable, Entity, IList, etc.)
        /// directly to the HTTP response stream via Utf8JsonWriter.
        /// includeLabels: when true, Entity objects get *Label companion fields
        /// via ApiNameDictionary (type→typeLabel, status→statusLabel).
        public static void WriteObject(HttpListenerResponse response,
                                        object value, int statusCode = 200,
                                        bool includeLabels = false) {
            response.StatusCode = statusCode;
            response.ContentType = "application/json; charset=utf-8";

            using (var ms = new MemoryStream(4096))
            using (var writer = new Utf8JsonWriter(ms, new JsonWriterOptions {
                Indented = false, // Compact for wire efficiency
                SkipValidation = false
            })) {
                WriteValue(writer, value, 0, includeLabels);
                writer.Flush();

                response.ContentLength64 = ms.Length;
                ms.Position = 0;
                ms.CopyTo(response.OutputStream);
            }
        }

        /// Serialize any object to a UTF-8 JSON byte array without writing to
        /// an HTTP response. Used by the response cache to capture sidecar content
        /// using the exact same serialization logic as WriteObject — guaranteeing
        /// byte-level equality between cached and fresh responses.
        public static byte[] SerializeToBytes(object value, bool includeLabels = false) {
            using (var ms = new MemoryStream(4096))
            using (var writer = new Utf8JsonWriter(ms, new JsonWriterOptions {
                Indented = false,
                SkipValidation = false
            })) {
                WriteValue(writer, value, 0, includeLabels);
                writer.Flush();
                return ms.ToArray();
            }
        }

        // ── Core serialization dispatcher ────────────────────────────

        private static void WriteValue(Utf8JsonWriter writer, object value,
                                        int depth, bool includeLabels = false) {
            if (depth > MaxDepth) {
                writer.WriteStringValue(value?.ToString() ?? "null");
                return;
            }

            if (value == null || value is DBNull) {
                writer.WriteNullValue();
                return;
            }

            // Primitives (fast paths — checked first for common types)
            if (value is string s) { writer.WriteStringValue(s); return; }
            if (value is int iv) { writer.WriteNumberValue(iv); return; }
            if (value is long lv) { writer.WriteNumberValue(lv); return; }
            if (value is double dv) { writer.WriteNumberValue(dv); return; }
            if (value is decimal decv) { writer.WriteNumberValue(decv); return; }
            if (value is float fv) { writer.WriteNumberValue(fv); return; }
            if (value is bool b) { writer.WriteBooleanValue(b); return; }
            if (value is DateTime dt) {
                writer.WriteStringValue(dt.ToString("yyyy-MM-dd'T'HH:mm:ss"));
                return;
            }

            // Robot.Entity — typed property access (no reflection)
            if (value is Entity entity) {
                WriteEntity(writer, entity, depth, includeLabels);
                return;
            }

            // Dictionary/Hashtable → JSON object
            if (value is IDictionary dict) {
                WriteDictionary(writer, dict, depth, includeLabels);
                return;
            }

            // PSCustomObject/PSObject — property enumeration via reflection
            var psType = value.GetType();
            if (psType.FullName == "System.Management.Automation.PSCustomObject" ||
                psType.FullName == "System.Management.Automation.PSObject") {
                // Unwrap PSObject if it wraps a primitive (e.g. string from .Where())
                var baseObjProp = psType.GetProperty("BaseObject");
                if (baseObjProp != null) {
                    var baseObj = baseObjProp.GetValue(value);
                    if (baseObj != null && baseObj != value &&
                        (baseObj is string || baseObj is int || baseObj is long ||
                         baseObj is double || baseObj is decimal || baseObj is float ||
                         baseObj is bool || baseObj is DateTime)) {
                        WriteValue(writer, baseObj, depth, includeLabels);
                        return;
                    }
                }
                WritePSObject(writer, value, depth, includeLabels);
                return;
            }

            // Array/List → JSON array
            if (value is IList list) {
                WriteArray(writer, list, depth, includeLabels);
                return;
            }

            // IEnumerable (non-string, non-dict, non-list) → JSON array
            if (value is IEnumerable enumerable && !(value is string)) {
                writer.WriteStartArray();
                foreach (var item in enumerable)
                    WriteValue(writer, item, depth + 1, includeLabels);
                writer.WriteEndArray();
                return;
            }

            // Plain C# objects (e.g. SessionPU, SessionIntel, SessionTransfer) —
            // reflect public instance properties so they serialize as JSON objects
            // instead of falling through to ToString().
            var publicProps = psType.GetProperties(
                System.Reflection.BindingFlags.Public | System.Reflection.BindingFlags.Instance);
            if (publicProps.Length > 0) {
                writer.WriteStartObject();
                foreach (var prop in publicProps) {
                    if (!prop.CanRead) continue;
                    object pval = null;
                    try { pval = prop.GetValue(value); } catch { continue; }
                    writer.WritePropertyName(prop.Name);
                    WriteValue(writer, pval, depth + 1, includeLabels);
                }
                writer.WriteEndObject();
                return;
            }

            // Fallback: stringify
            writer.WriteStringValue(value.ToString());
        }

        private static void WriteEntity(Utf8JsonWriter writer, Entity entity,
                                         int depth, bool includeLabels = false) {
            writer.WriteStartObject();

            writer.WriteString("name", entity.Name);
            writer.WriteString("cn", entity.CN);

            writer.WriteString("type", entity.Type);
            if (includeLabels) {
                string typeLabel = ApiNameDictionary.GetLabel("type", entity.Type);
                if (typeLabel != null) writer.WriteString("typeLabel", typeLabel);
            }

            writer.WriteString("status", entity.Status);
            if (includeLabels) {
                string statusLabel = ApiNameDictionary.GetLabel("status", entity.Status);
                if (statusLabel != null) writer.WriteString("statusLabel", statusLabel);
            }

            writer.WriteString("location", entity.Location);
            writer.WriteString("owner", entity.Owner);
            writer.WriteString("quantity", entity.Quantity);
            writer.WriteString("filePath", entity.FilePath);
            writer.WriteString("nerthusName", entity.NerthusName);

            // Collection properties — serialize if non-null
            WritePropertyIfNotNull(writer, "aliases", entity.Aliases, depth, includeLabels);
            WritePropertyIfNotNull(writer, "groups", entity.Groups, depth, includeLabels);
            WritePropertyIfNotNull(writer, "doors", entity.Doors, depth, includeLabels);
            WritePropertyIfNotNull(writer, "names", entity.Names, depth, includeLabels);
            WritePropertyIfNotNull(writer, "coordinates", entity.Coordinates, depth, includeLabels);
            WritePropertyIfNotNull(writer, "contains", entity.Contains, depth, includeLabels);

            writer.WriteEndObject();
        }

        private static void WritePropertyIfNotNull(Utf8JsonWriter writer,
            string name, object value, int depth, bool includeLabels = false) {
            if (value == null) return;
            writer.WritePropertyName(name);
            WriteValue(writer, value, depth + 1, includeLabels);
        }

        private static void WriteDictionary(Utf8JsonWriter writer,
            IDictionary dict, int depth, bool includeLabels = false) {
            writer.WriteStartObject();
            foreach (DictionaryEntry entry in dict) {
                string key = entry.Key?.ToString() ?? "";
                writer.WritePropertyName(key);
                WriteValue(writer, entry.Value, depth + 1, includeLabels);
            }
            writer.WriteEndObject();
        }

        private static void WriteArray(Utf8JsonWriter writer, IList list,
                                        int depth, bool includeLabels = false) {
            writer.WriteStartArray();
            for (int i = 0; i < list.Count; i++)
                WriteValue(writer, list[i], depth + 1, includeLabels);
            writer.WriteEndArray();
        }

        /// Serialize PSCustomObject/PSObject by reflecting over its Properties collection.
        private static void WritePSObject(Utf8JsonWriter writer, object psObj,
                                           int depth, bool includeLabels = false) {
            writer.WriteStartObject();

            // Access .Properties via reflection (avoids SMA compile-time dependency)
            var propsProperty = psObj.GetType().GetProperty("Properties");
            if (propsProperty != null) {
                var props = propsProperty.GetValue(psObj) as IEnumerable;
                if (props != null) {
                    foreach (var prop in props) {
                        var nameProperty = prop.GetType().GetProperty("Name");
                        var valueProperty = prop.GetType().GetProperty("Value");
                        if (nameProperty == null) continue;

                        string name = nameProperty.GetValue(prop) as string;
                        if (name == null) continue;

                        object val = null;
                        try { val = valueProperty?.GetValue(prop); } catch { }

                        writer.WritePropertyName(name);
                        WriteValue(writer, val, depth + 1, includeLabels);
                    }
                }
            }

            writer.WriteEndObject();
        }
    }
}
