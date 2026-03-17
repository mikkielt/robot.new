using System;
using System.Collections;
using System.Collections.Generic;
using System.Text;
using System.Text.RegularExpressions;

namespace Robot {
    /// Parses JSON:API-style query parameters (filter, fields, sort, page)
    /// and applies them to collections of objects. Used by API handlers to
    /// provide standard query capabilities without per-handler logic.
    ///
    /// Filter syntax: RSQL (field==value;field!=value,field=gt=value)
    ///   Semicolons are AND, commas are OR (within a group).
    ///   Groups are always ANDed at the top level.
    ///
    /// Filter values are resolved through ApiNameDictionary for known fields
    /// (type, status, season, etc.), allowing English labels in queries.
    ///
    /// Thread safety: stateless parser methods — safe for concurrent RunspacePool use.
    ///
    /// Consumers: Invoke-ApiGetEntities, Invoke-ApiGetSessions, and other list handlers
    public static class ApiQueryParser {

        // ── Filter alias resolution ──────────────────────────────────────

        /// Map filter field names to dictionary categories for alias resolution.
        private static readonly Dictionary<string, string> FieldToCategory =
            new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase) {
                ["type"]         = "type",
                ["status"]       = "status",
                ["season"]       = "season",
                ["format"]       = "format",
                ["source"]       = "source",
                ["directive"]    = "directive",
                ["ownertype"]    = "ownerType",
                ["denomination"] = "denomination",
                ["denomshort"]   = "denomination",
                ["tier"]         = "denomination"
            };

        /// Resolve a filter value through the name dictionary.
        /// If the field has a known category, tries label→canonical translation.
        /// Unknown fields or values pass through unchanged.
        private static string ResolveFilterAlias(string field, string value) {
            if (FieldToCategory.TryGetValue(field, out string category)) {
                return ApiNameDictionary.ResolveCanonical(category, value);
            }
            return value;
        }

        // ── Filter parsing ────────────────────────────────────────────────

        /// Parse RSQL filter string into a list of AND-joined filter groups.
        /// Each group contains OR-joined conditions.
        /// Example: "type==NPC;status!=Usunięty,status!=Nieaktywny"
        ///   → [ [type==NPC], [status!=Usunięty OR status!=Nieaktywny] ]
        ///   The semicolon splits into groups; commas split within a group.
        public static List<FilterGroup> ParseFilter(string filter) {
            if (string.IsNullOrWhiteSpace(filter))
                return new List<FilterGroup>();

            var groups = new List<FilterGroup>();

            // Split on semicolons (AND groups) — respecting parentheses
            var andParts = SplitRespectingParens(filter, ';');
            foreach (string andPart in andParts) {
                if (string.IsNullOrWhiteSpace(andPart)) continue;

                var group = new FilterGroup();
                // Split on commas (OR conditions) — respecting parentheses
                var orParts = SplitRespectingParens(andPart, ',');
                foreach (string orPart in orParts) {
                    var condition = ParseCondition(orPart.Trim());
                    if (condition != null) group.Conditions.Add(condition);
                }
                if (group.Conditions.Count > 0) groups.Add(group);
            }

            return groups;
        }

        /// Split a string by a delimiter, but skip delimiters inside parentheses.
        /// Handles =in=(a,b,c) correctly by not splitting on the inner commas.
        private static List<string> SplitRespectingParens(string input, char delimiter) {
            var parts = new List<string>();
            int depth = 0;
            int start = 0;
            for (int i = 0; i < input.Length; i++) {
                char c = input[i];
                if (c == '(') depth++;
                else if (c == ')') { if (depth > 0) depth--; }
                else if (c == delimiter && depth == 0) {
                    parts.Add(input.Substring(start, i - start));
                    start = i + 1;
                }
            }
            parts.Add(input.Substring(start));
            return parts;
        }

        /// Parse a single RSQL condition: "field==value", "field=gt=value",
        /// "field=in=(a,b,c)"
        private static FilterCondition ParseCondition(string expr) {
            // Try named operators first: =gt=, =ge=, =lt=, =le=, =in=, =out=, =like=
            var namedMatch = Regex.Match(expr,
                @"^(\w+)=(gt|ge|lt|le|in|out|like)=(.+)$",
                RegexOptions.IgnoreCase);
            if (namedMatch.Success) {
                string field = namedMatch.Groups[1].Value;
                string op = namedMatch.Groups[2].Value.ToLowerInvariant();
                string value = namedMatch.Groups[3].Value;

                // Parse set values for in/out: (a,b,c) → string[]
                if ((op == "in" || op == "out") &&
                    value.StartsWith("(") && value.EndsWith(")")) {
                    string inner = value.Substring(1, value.Length - 2);
                    return new FilterCondition {
                        Field = field,
                        Operator = op,
                        Values = inner.Split(',')
                    };
                }

                return new FilterCondition {
                    Field = field,
                    Operator = op,
                    Value = value
                };
            }

            // Try == and !=
            int neqIdx = expr.IndexOf("!=", StringComparison.Ordinal);
            if (neqIdx > 0) {
                return new FilterCondition {
                    Field = expr.Substring(0, neqIdx),
                    Operator = "neq",
                    Value = expr.Substring(neqIdx + 2)
                };
            }

            int eqIdx = expr.IndexOf("==", StringComparison.Ordinal);
            if (eqIdx > 0) {
                return new FilterCondition {
                    Field = expr.Substring(0, eqIdx),
                    Operator = "eq",
                    Value = expr.Substring(eqIdx + 2)
                };
            }

            return null; // Unparsable
        }

        /// Evaluate a filter condition against a property value (string).
        /// Values are resolved through the name dictionary for known field categories.
        public static bool EvaluateCondition(FilterCondition cond, string propertyValue) {
            if (propertyValue == null) propertyValue = "";
            string val = propertyValue;

            switch (cond.Operator) {
                case "eq": {
                    string resolved = ResolveFilterAlias(cond.Field, cond.Value ?? "");
                    return string.Equals(val, resolved, StringComparison.OrdinalIgnoreCase);
                }
                case "neq": {
                    string resolved = ResolveFilterAlias(cond.Field, cond.Value ?? "");
                    return !string.Equals(val, resolved, StringComparison.OrdinalIgnoreCase);
                }
                case "gt": {
                    string resolved = ResolveFilterAlias(cond.Field, cond.Value ?? "");
                    return string.Compare(val, resolved, StringComparison.OrdinalIgnoreCase) > 0;
                }
                case "ge": {
                    string resolved = ResolveFilterAlias(cond.Field, cond.Value ?? "");
                    return string.Compare(val, resolved, StringComparison.OrdinalIgnoreCase) >= 0;
                }
                case "lt": {
                    string resolved = ResolveFilterAlias(cond.Field, cond.Value ?? "");
                    return string.Compare(val, resolved, StringComparison.OrdinalIgnoreCase) < 0;
                }
                case "le": {
                    string resolved = ResolveFilterAlias(cond.Field, cond.Value ?? "");
                    return string.Compare(val, resolved, StringComparison.OrdinalIgnoreCase) <= 0;
                }
                case "in":
                    if (cond.Values == null) return false;
                    foreach (string v in cond.Values) {
                        string resolved = ResolveFilterAlias(cond.Field, v.Trim());
                        if (string.Equals(val, resolved, StringComparison.OrdinalIgnoreCase))
                            return true;
                    }
                    return false;
                case "out":
                    if (cond.Values == null) return true;
                    foreach (string v in cond.Values) {
                        string resolved = ResolveFilterAlias(cond.Field, v.Trim());
                        if (string.Equals(val, resolved, StringComparison.OrdinalIgnoreCase))
                            return false;
                    }
                    return true;
                case "like": {
                    string target = cond.Value ?? "";
                    string pattern = "^" + Regex.Escape(target)
                        .Replace("\\*", ".*").Replace("\\?", ".") + "$";
                    return Regex.IsMatch(val, pattern, RegexOptions.IgnoreCase);
                }
                default:
                    return false;
            }
        }

        // ── Sort parsing ──────────────────────────────────────────────────

        /// Parse sort parameter: "-date,name" → [{field:"date", desc:true}, {field:"name", desc:false}]
        public static List<SortField> ParseSort(string sort) {
            var result = new List<SortField>();
            if (string.IsNullOrWhiteSpace(sort)) return result;

            string[] parts = sort.Split(',');
            foreach (string part in parts) {
                string trimmed = part.Trim();
                if (string.IsNullOrEmpty(trimmed)) continue;

                if (trimmed.StartsWith("-")) {
                    result.Add(new SortField {
                        Field = trimmed.Substring(1),
                        Descending = true
                    });
                } else if (trimmed.StartsWith("+")) {
                    result.Add(new SortField {
                        Field = trimmed.Substring(1),
                        Descending = false
                    });
                } else {
                    result.Add(new SortField {
                        Field = trimmed,
                        Descending = false
                    });
                }
            }

            return result;
        }

        // ── Fields (sparse fieldset) parsing ──────────────────────────────

        /// Parse fields parameter: "name,type,status" → HashSet<string>
        public static HashSet<string> ParseFields(string fields) {
            if (string.IsNullOrWhiteSpace(fields))
                return null; // null = return all fields

            var result = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            string[] parts = fields.Split(',');
            foreach (string part in parts) {
                string trimmed = part.Trim();
                if (!string.IsNullOrEmpty(trimmed))
                    result.Add(trimmed);
            }

            return result.Count > 0 ? result : null;
        }

        // ── Pagination parsing ────────────────────────────────────────────

        /// Parse page parameters from query string dictionary.
        /// Returns (pageSize, afterCursor).
        public static PageParams ParsePage(Dictionary<string, string> queryParams) {
            var result = new PageParams { Size = 50 };

            if (queryParams.TryGetValue("page[size]", out string sizeStr)) {
                if (int.TryParse(sizeStr, out int size)) {
                    result.Size = Math.Max(1, Math.Min(500, size)); // clamp 1-500
                }
            }

            if (queryParams.TryGetValue("page[after]", out string afterStr)) {
                try {
                    result.AfterCursor = Encoding.UTF8.GetString(
                        Convert.FromBase64String(afterStr));
                } catch {
                    // Invalid cursor — ignore, start from beginning
                }
            }

            return result;
        }

        /// Encode a cursor value for the "next" link.
        public static string EncodeCursor(string value) {
            return Convert.ToBase64String(Encoding.UTF8.GetBytes(value));
        }

        // ── Entity-specific helpers ───────────────────────────────────────

        /// Get a string property value from a Robot.Entity by field name.
        /// Case-insensitive field lookup against known Entity properties.
        public static string GetEntityField(Entity entity, string field) {
            switch (field.ToLowerInvariant()) {
                case "name":         return entity.Name;
                case "cn":           return entity.CN;
                case "type":         return entity.Type;
                case "status":       return entity.Status;
                case "location":     return entity.Location;
                case "owner":        return entity.Owner;
                case "quantity":     return entity.Quantity;
                case "filepath":     return entity.FilePath;
                case "nerthusname":  return entity.NerthusName;
                default:             return null;
            }
        }

        /// Apply filter groups to a list of entities. Returns matching entities.
        /// All groups must match (AND). Within a group, any condition matches (OR).
        public static List<Entity> FilterEntities(
            List<Entity> entities, List<FilterGroup> groups) {
            if (groups == null || groups.Count == 0) return entities;

            var result = new List<Entity>(entities.Count);
            for (int i = 0; i < entities.Count; i++) {
                var entity = entities[i];
                bool allGroupsMatch = true;

                for (int g = 0; g < groups.Count; g++) {
                    bool anyConditionMatch = false;
                    var group = groups[g];

                    for (int c = 0; c < group.Conditions.Count; c++) {
                        var cond = group.Conditions[c];
                        string fieldValue = GetEntityField(entity, cond.Field);
                        if (EvaluateCondition(cond, fieldValue)) {
                            anyConditionMatch = true;
                            break;
                        }
                    }

                    if (!anyConditionMatch) {
                        allGroupsMatch = false;
                        break;
                    }
                }

                if (allGroupsMatch) result.Add(entity);
            }

            return result;
        }

        /// Sort entities by multiple fields.
        public static void SortEntities(List<Entity> entities, List<SortField> sortFields) {
            if (sortFields == null || sortFields.Count == 0) return;

            entities.Sort((a, b) => {
                for (int i = 0; i < sortFields.Count; i++) {
                    var sf = sortFields[i];
                    string va = GetEntityField(a, sf.Field) ?? "";
                    string vb = GetEntityField(b, sf.Field) ?? "";
                    int cmp = string.Compare(va, vb, StringComparison.OrdinalIgnoreCase);
                    if (cmp != 0) return sf.Descending ? -cmp : cmp;
                }
                return 0;
            });
        }

        /// Apply cursor-based pagination. Returns a page of items and the next cursor.
        public static PageResult<Entity> PaginateEntities(
            List<Entity> sorted, PageParams page, string cursorField = "name") {
            int startIdx = 0;

            // Find position after cursor
            if (!string.IsNullOrEmpty(page.AfterCursor)) {
                for (int i = 0; i < sorted.Count; i++) {
                    string val = GetEntityField(sorted[i], cursorField);
                    if (string.Equals(val, page.AfterCursor, StringComparison.OrdinalIgnoreCase)) {
                        startIdx = i + 1;
                        break;
                    }
                }
            }

            int count = Math.Min(page.Size, sorted.Count - startIdx);
            if (count <= 0) {
                return new PageResult<Entity> {
                    Items = new List<Entity>(),
                    TotalCount = sorted.Count,
                    HasMore = false,
                    NextCursor = null
                };
            }

            var items = sorted.GetRange(startIdx, count);
            bool hasMore = (startIdx + count) < sorted.Count;
            string nextCursor = hasMore
                ? EncodeCursor(GetEntityField(items[items.Count - 1], cursorField))
                : null;

            return new PageResult<Entity> {
                Items = items,
                TotalCount = sorted.Count,
                HasMore = hasMore,
                NextCursor = nextCursor
            };
        }
    }

    // ── Data types ────────────────────────────────────────────────────────

    /// AND-joined group of OR-joined filter conditions (one RSQL semicolon-delimited segment).
    public sealed class FilterGroup {
        public List<FilterCondition> Conditions { get; set; } =
            new List<FilterCondition>();
    }

    /// Single RSQL filter condition: field, operator (eq/neq/gt/ge/lt/le/in/out/like), value(s).
    public sealed class FilterCondition {
        public string Field { get; set; }
        public string Operator { get; set; }
        public string Value { get; set; }
        public string[] Values { get; set; } // For in/out operators
    }

    /// Sort directive: field name with ascending (default) or descending direction.
    public sealed class SortField {
        public string Field { get; set; }
        public bool Descending { get; set; }
    }

    /// Cursor-based pagination parameters parsed from page[size] and page[after] query params.
    public sealed class PageParams {
        public int Size { get; set; } = 50;
        public string AfterCursor { get; set; }
    }

    /// Paginated result slice with total count, continuation flag, and base64 cursor.
    public sealed class PageResult<T> {
        public List<T> Items { get; set; }
        public int TotalCount { get; set; }
        public bool HasMore { get; set; }
        public string NextCursor { get; set; }
    }
}
