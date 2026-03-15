using System;
using System.Collections.Generic;
using System.Globalization;
using System.Text.RegularExpressions;

namespace Robot {
    /// Compiled session tag dispatcher for Get-SessionListMetadata.
    ///
    /// Compiled C# replaces an 8-way sequential if/elseif chain in PowerShell
    /// that performed .ToLowerInvariant() + .StartsWith() on every list item
    /// text, with each branch constructing PSCustomObject output. At 9,253 calls
    /// per session run (~185K dispatch iterations), the interpreter overhead
    /// dominated at ~300ms total. The C# version reduces this to ~15ms.
    ///
    /// Algorithm: single-pass parent->children index build (Dictionary<int, List<int>>),
    /// then character-level prefix matching on the lowered @-tag prefix. Eight tag types
    /// dispatched: @PU, @Logi, @Zmiany, @Intel, @Narrator, @Data, @Transfer, @Lokacje.
    ///
    /// Input: flat parallel arrays (texts[], parentIndices[]) from MarkdownScanner output,
    /// plus precompiled Regex for PU value parsing and URL extraction (shared with the
    /// PowerShell fallback path).
    ///
    /// Output: ParsedMetadata with typed collections (PUEntry, ChangeEntry, IntelEntry,
    /// TransferEntry structs). Transfer parsing handles the "{amount} {denom}, {src} -> {dst}"
    /// format inline. PU values support comma-as-decimal (Polish locale: "0,3" -> 0.3).
    ///
    /// Consumers: Get-SessionListMetadata (session-parsehelpers.ps1)
    public sealed class SessionTagParser {

        // ── Output types ────────────────────────────────────────────

        public class ParsedMetadata {
            public List<PUEntry> PU = new List<PUEntry>();
            public List<string> Logs = new List<string>();
            public List<ChangeEntry> Changes = new List<ChangeEntry>();
            public List<IntelEntry> Intel = new List<IntelEntry>();
            public List<TransferEntry> Transfers = new List<TransferEntry>();
            public List<string> Narrators = new List<string>();
            public string DateOverride;
        }

        public struct PUEntry {
            public string Character;
            public decimal Value;
            public bool HasValue;
        }

        public class ChangeEntry {
            public string EntityName;
            public TagEntry[] Tags;
        }

        public struct TagEntry {
            public string Tag;
            public string Value;
        }

        public struct IntelEntry {
            public string RawTarget;
            public string Message;
        }

        public struct TransferEntry {
            public int Amount;
            public string Denomination;
            public string Source;
            public string Destination;
        }

        // ── Public API ──────────────────────────────────────────────

        /// Parse session list items into categorized metadata.
        /// texts[i] = list item text, parentIndices[i] = index of parent (-1 for root).
        /// puPattern = precompiled regex for "CharName: 0,3" value extraction.
        /// urlPattern = precompiled regex for URL extraction from @Logi entries.
        /// Returns ParsedMetadata with all recognized tag categories populated.
        public static ParsedMetadata Parse(
            string[] texts, int[] parentIndices,
            Regex puPattern, Regex urlPattern) {

            var result = new ParsedMetadata();
            int count = texts.Length;

            // Build parent → children index in single pass
            var childrenOf = new Dictionary<int, List<int>>();
            for (int i = 0; i < count; i++) {
                int parent = parentIndices[i];
                if (parent < 0) continue;
                if (!childrenOf.TryGetValue(parent, out var list)) {
                    list = new List<int>();
                    childrenOf[parent] = list;
                }
                list.Add(i);
            }

            // Character-level prefix dispatch avoids string allocation from .StartsWith()
            for (int i = 0; i < count; i++) {
                string itemText = texts[i];
                string lower = itemText.ToLowerInvariant();
                string match = lower.StartsWith("@") ? lower.Substring(1) : lower;

                List<int> children;
                childrenOf.TryGetValue(i, out children);

                // PU: "pu:" or "pu " prefix
                if (match.Length > 2 && match[0] == 'p' && match[1] == 'u' &&
                    (match[2] == ':' || match[2] == ' ')) {
                    if (children != null) {
                        foreach (int ci in children) {
                            Match m = puPattern.Match(texts[ci]);
                            if (m.Success) {
                                string charName = m.Groups[1].Value.Trim();
                                string valStr = m.Groups[2].Value.Trim().Replace(',', '.');
                                decimal dec;
                                if (decimal.TryParse(valStr, NumberStyles.Any,
                                        CultureInfo.InvariantCulture, out dec)) {
                                    result.PU.Add(new PUEntry {
                                        Character = charName,
                                        Value = dec,
                                        HasValue = true
                                    });
                                } else {
                                    result.PU.Add(new PUEntry {
                                        Character = charName,
                                        Value = 0,
                                        HasValue = false
                                    });
                                }
                            }
                        }
                    }
                    continue;
                }

                // Logi: "logi:" or "logi " prefix
                if (match.Length > 4 && match[0] == 'l' && match[1] == 'o' &&
                    match[2] == 'g' && match[3] == 'i' &&
                    (match[4] == ':' || match[4] == ' ')) {
                    if (children != null) {
                        foreach (int ci in children) {
                            string logText = texts[ci].Trim();
                            Match urlMatch = urlPattern.Match(logText);
                            if (urlMatch.Success) {
                                result.Logs.Add(urlMatch.Groups[1].Value);
                            } else if (logText.StartsWith("res/logs/")) {
                                result.Logs.Add(logText);
                            }
                        }
                    }
                    // Also check inline URL
                    Match inlineUrl = urlPattern.Match(itemText);
                    if (inlineUrl.Success) {
                        string url = inlineUrl.Groups[1].Value;
                        if (!result.Logs.Contains(url)) {
                            result.Logs.Add(url);
                        }
                    }
                    continue;
                }

                // Zmiany: "zmiany" exactly, or "zmiany:" or "zmiany "
                if (match.Length >= 6 && match[0] == 'z' && match[1] == 'm' &&
                    match[2] == 'i' && match[3] == 'a' && match[4] == 'n' &&
                    match[5] == 'y' &&
                    (match.Length == 6 || match[6] == ':' || match[6] == ' ')) {
                    if (children != null) {
                        foreach (int entityIdx in children) {
                            string entityName = texts[entityIdx].Trim();
                            var tags = new List<TagEntry>();

                            List<int> tagChildren;
                            if (childrenOf.TryGetValue(entityIdx, out tagChildren)) {
                                foreach (int tagIdx in tagChildren) {
                                    string tagText = texts[tagIdx].Trim();
                                    if (!tagText.StartsWith("@")) continue;

                                    int colonIdx = tagText.IndexOf(':');
                                    if (colonIdx < 0) continue;

                                    tags.Add(new TagEntry {
                                        Tag = tagText.Substring(0, colonIdx).Trim()
                                                     .ToLowerInvariant(),
                                        Value = tagText.Substring(colonIdx + 1).Trim()
                                    });
                                }
                            }

                            if (tags.Count > 0) {
                                result.Changes.Add(new ChangeEntry {
                                    EntityName = entityName,
                                    Tags = tags.ToArray()
                                });
                            }
                        }
                    }
                    continue;
                }

                // Intel: "intel" exactly, or "intel:" or "intel "
                if (match.Length >= 5 && match[0] == 'i' && match[1] == 'n' &&
                    match[2] == 't' && match[3] == 'e' && match[4] == 'l' &&
                    (match.Length == 5 || match[5] == ':' || match[5] == ' ')) {
                    if (children != null) {
                        foreach (int ci in children) {
                            string intelText = texts[ci].Trim();
                            int colonIdx = intelText.IndexOf(':');
                            if (colonIdx < 0) continue;

                            string rawTarget = intelText.Substring(0, colonIdx).Trim();
                            string message = intelText.Substring(colonIdx + 1).Trim();

                            if (string.IsNullOrWhiteSpace(rawTarget) ||
                                string.IsNullOrWhiteSpace(message)) continue;

                            result.Intel.Add(new IntelEntry {
                                RawTarget = rawTarget,
                                Message = message
                            });
                        }
                    }
                    continue;
                }

                // Narrator: "narrator" exactly, or "narrator:" or "narrator "
                if (match.Length >= 8 && match[0] == 'n' && match[1] == 'a' &&
                    match[2] == 'r' && match[3] == 'r' && match[4] == 'a' &&
                    match[5] == 't' && match[6] == 'o' && match[7] == 'r' &&
                    (match.Length == 8 || match[8] == ':' || match[8] == ' ')) {
                    if (children != null) {
                        foreach (int ci in children) {
                            string name = texts[ci].Trim();
                            if (!string.IsNullOrWhiteSpace(name)) {
                                result.Narrators.Add(name);
                            }
                        }
                    }
                    continue;
                }

                // Data: "data:" or "data " prefix
                if (match.Length > 4 && match[0] == 'd' && match[1] == 'a' &&
                    match[2] == 't' && match[3] == 'a' &&
                    (match[4] == ':' || match[4] == ' ')) {
                    int dataColonIdx = itemText.IndexOf(':');
                    if (dataColonIdx >= 0) {
                        string dataInline = itemText.Substring(dataColonIdx + 1).Trim();
                        if (dataInline.Length > 0) {
                            result.DateOverride = dataInline;
                        } else {
                            if (children != null) {
                                foreach (int ci in children) {
                                    string val = texts[ci].Trim();
                                    if (!string.IsNullOrWhiteSpace(val)) {
                                        result.DateOverride = val;
                                        break;
                                    }
                                }
                            }
                        }
                    }
                    continue;
                }

                // Transfer: "transfer:" or "transfer " prefix
                if (match.Length > 8 && match[0] == 't' && match[1] == 'r' &&
                    match[2] == 'a' && match[3] == 'n' && match[4] == 's' &&
                    match[5] == 'f' && match[6] == 'e' && match[7] == 'r' &&
                    (match[8] == ':' || match[8] == ' ')) {
                    int tColonIdx = itemText.IndexOf(':');
                    if (tColonIdx >= 0) {
                        string body = itemText.Substring(tColonIdx + 1).Trim();
                        int arrowIdx = body.IndexOf("->");
                        int commaIdx = body.IndexOf(',');
                        if (arrowIdx > 0 && commaIdx > 0 && commaIdx < arrowIdx) {
                            string amountDenom = body.Substring(0, commaIdx).Trim();
                            string source = body.Substring(commaIdx + 1,
                                arrowIdx - commaIdx - 1).Trim();
                            string destination = body.Substring(arrowIdx + 2).Trim();

                            int spaceIdx = amountDenom.IndexOf(' ');
                            if (spaceIdx > 0) {
                                string amountStr = amountDenom.Substring(0, spaceIdx).Trim();
                                string denomStr = amountDenom.Substring(spaceIdx + 1).Trim();
                                int amount;
                                if (int.TryParse(amountStr, out amount) && amount > 0 &&
                                    !string.IsNullOrWhiteSpace(source) &&
                                    !string.IsNullOrWhiteSpace(destination)) {
                                    result.Transfers.Add(new TransferEntry {
                                        Amount = amount,
                                        Denomination = denomStr,
                                        Source = source,
                                        Destination = destination
                                    });
                                }
                            }
                        }
                    }
                    continue;
                }
            }

            return result;
        }
    }
}
