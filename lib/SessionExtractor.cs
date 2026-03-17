using System;
using System.Collections.Generic;
using System.Globalization;
using System.Text.RegularExpressions;

namespace Robot {
    /// Per-section session structural extractor that consolidates header parsing,
    /// format detection, parent->children index build, tag dispatch, and tag-based
    /// location extraction into a single compiled call.
    ///
    /// Consolidates per-section processing into a single compiled call: header date
    /// parsing, format classification, children-of index construction, and multi-way
    /// tag dispatch are all performed natively for each session section.
    ///
    /// "Structural extraction" means all processing that can be done from the
    /// Markdown structure alone, without access to the entity database or name
    /// index. This is the design boundary: C# handles structure, PowerShell
    /// handles entity-dependent post-processing:
    /// - Narrator resolution (Resolve-Narrator via name index)
    /// - Intel target resolution (Resolve-IntelTargets via name index)
    /// - Location Strategy 1 (entity-name-based Lokacja detection)
    /// - @Narrator override resolution (name index dependent)
    /// - Entity mention extraction (name index dependent)
    ///
    /// The C# extractor returns NarratorRawText (last comma segment of the
    /// header) instead of resolved narrator objects. PowerShell post-processing
    /// resolves these via the name index.
    ///
    /// Format detection classifies sessions into four generations:
    /// - Gen1: fallback (no structural markers), oldest sessions
    /// - Gen2: italic location prefix (*Lokalizacja:...*) in first content line
    /// - Gen3: root list items starting with "pu:" or "pu " prefix
    /// - Gen4: root list items with @-prefixed tag names (current standard)
    /// Format determines which location extraction strategy applies.
    ///
    /// Location extraction uses Strategy 2 only (tag-name matching for
    /// Lokalizacj*/Lokacj* prefixes in Gen3/Gen4, italic regex in Gen2).
    /// Strategy 1 (entity resolution) runs in PowerShell post-processing
    /// when Strategy 2 yields no results.
    ///
    /// Input: per-section flat arrays (texts[], parentIndices[]) from parsed
    /// Markdown section list items (section-local indices, same as
    /// SessionTagParser), plus header text and section content.
    ///
    /// Output: ExtractedSession with all structurally-extractable fields
    /// populated. PowerShell wraps these into session objects after applying
    /// entity-dependent post-processing.
    ///
    /// Consumers: get-session.ps1 line 537 via [Robot.SessionExtractor]::ExtractSection
    public sealed class SessionExtractor {

        // ── Output types ────────────────────────────────────────────

        /// Structurally extracted session data before entity-dependent post-processing.
        /// NarratorRawText and MetaNarrators are raw strings awaiting Resolve-Narrator;
        /// RawIntel targets are unresolved names awaiting Resolve-IntelTargets.
        public sealed class ExtractedSession {
            public string Header;
            public DateTime Date;
            public DateTime? DateEnd;
            public string DateStr;
            public string EndDayStr;
            public string Title;
            public string Format;          // "Gen1", "Gen2", "Gen3", "Gen4"
            public string[] Locations;
            public List<string> Logs;
            public List<SessionPU> PU;
            public List<SessionChange> Changes;
            public List<SessionTransfer> Transfers;
            public List<SessionIntel> RawIntel;
            public string NarratorRawText; // unresolved, for PS post-processing
            public List<string> MetaNarrators; // from @Narrator tag, for PS override
            public string Content;         // null unless requested
            public string FirstNonEmptyLine;
        }

        // ── Precompiled patterns ────────────────────────────────────

        private static readonly Regex LocItalicRx = new Regex(
            @"\*Lokalizacj[ae]?:\s*(.+?)\*", RegexOptions.Compiled);

        private static readonly Regex LogiLineRx = new Regex(
            @"^Logi:\s*(https?://\S+)", RegexOptions.Compiled);

        // ── Public API ──────────────────────────────────────────────

        /// Extract structural session data from a single Markdown section.
        /// header = section header text (e.g. "2024-01-15, Tytuł sesji, Narrator").
        /// content = raw section content string (text between headers).
        /// texts[] = section-local list item texts from MarkdownScanner.
        /// parentIndices[] = section-local parent indices (-1 for root items).
        /// sessionDatePattern = precompiled regex for YYYY-MM-DD(/DD) extraction
        /// from headers (supports multi-day sessions with /DD suffix).
        /// puPattern = precompiled regex for "CharName - Value" PU line parsing.
        /// urlPattern = precompiled regex for URL extraction from log entries.
        /// includeContent = whether to populate the Content field (false saves
        /// memory when content is not needed by the caller).
        /// Returns ExtractedSession or null if the header contains no valid date.
        public static ExtractedSession ExtractSection(
            string header,
            string content,
            string[] texts,
            int[] parentIndices,
            Regex sessionDatePattern,
            Regex puPattern,
            Regex urlPattern,
            bool includeContent) {

            // Date is the primary key — sessions without a valid date are skipped
            Match dateMatch = sessionDatePattern.Match(header);
            if (!dateMatch.Success) {
                return null;
            }

            string dateStr = dateMatch.Groups[1].Value;
            string endDayStr = dateMatch.Groups.Count > 2 ? dateMatch.Groups[2].Value : null;

            DateTime parsedDate;
            if (!DateTime.TryParseExact(dateStr, "yyyy-MM-dd",
                    CultureInfo.InvariantCulture, DateTimeStyles.None, out parsedDate)) {
                return null;
            }

            DateTime? dateEnd = null;
            if (!string.IsNullOrEmpty(endDayStr)) {
                string endStr = dateStr.Substring(0, 8) + endDayStr;
                DateTime endParsed;
                if (DateTime.TryParseExact(endStr, "yyyy-MM-dd",
                        CultureInfo.InvariantCulture, DateTimeStyles.None, out endParsed)) {
                    dateEnd = endParsed;
                }
            }

            int listCount = texts.Length;

            // Build section-local children-of index for O(1) child lookup during
            // tag dispatch, avoiding O(n^2) repeated linear scans
            var childrenOf = new Dictionary<int, List<int>>();
            for (int li = 0; li < listCount; li++) {
                int parent = parentIndices[li];
                if (parent < 0) continue;
                List<int> children;
                if (!childrenOf.TryGetValue(parent, out children)) {
                    children = new List<int>();
                    childrenOf[parent] = children;
                }
                children.Add(li);
            }

            // First non-empty line determines Gen2 format detection and carries
            // the italic location prefix when present
            string firstNonEmptyLine = null;
            if (content != null) {
                int pos = 0;
                int contentLen = content.Length;
                while (pos < contentLen) {
                    int lineEnd = content.IndexOf('\n', pos);
                    if (lineEnd < 0) lineEnd = contentLen;
                    int len = lineEnd - pos;
                    // Trim trailing whitespace inline
                    while (len > 0 && (content[pos + len - 1] == ' ' || content[pos + len - 1] == '\r')) len--;
                    if (len > 0) {
                        firstNonEmptyLine = content.Substring(pos, len);
                        break;
                    }
                    pos = lineEnd + 1;
                }
            }

            // Format detection must run before tag dispatch — it determines which
            // location extraction strategy applies
            string format = DetectFormat(firstNonEmptyLine, texts, parentIndices, listCount);

            // Title is the header minus date prefix and trailing narrator segment
            string title = ExtractTitle(header, dateStr, endDayStr);

            // Raw narrator text stays unresolved — PS post-processing maps it via name index
            string narratorRawText = ExtractNarratorRawText(header);

            // Tag dispatch extracts all structured metadata from list items in one pass
            var tagResult = DispatchTags(texts, parentIndices, childrenOf, listCount,
                puPattern, urlPattern);

            // @Data tag overrides the header date — used for sessions with corrected dates
            if (tagResult.DateOverride != null) {
                DateTime doParsed;
                if (DateTime.TryParseExact(tagResult.DateOverride, "yyyy-MM-dd",
                        CultureInfo.InvariantCulture, DateTimeStyles.None, out doParsed)) {
                    parsedDate = doParsed;
                    dateStr = tagResult.DateOverride;
                }
            }

            // Location extraction uses Strategy 2 (tag-based) — Strategy 1 (entity
            // resolution) runs in PS post-processing when this yields no results
            string[] locations = ExtractLocations(format, firstNonEmptyLine,
                texts, parentIndices, childrenOf, listCount);

            // Convert internal tag parser types to public session metadata types
            // that the PowerShell layer consumes directly
            var puList = new List<SessionPU>();
            foreach (var p in tagResult.PU) {
                puList.Add(new SessionPU(p.Character,
                    p.HasValue ? (object)p.Value : null));
            }

            var changeList = new List<SessionChange>();
            foreach (var c in tagResult.Changes) {
                var tags = new SessionTag[c.Tags.Length];
                for (int ti = 0; ti < c.Tags.Length; ti++) {
                    tags[ti] = new SessionTag(c.Tags[ti].Tag, c.Tags[ti].Value);
                }
                changeList.Add(new SessionChange(c.EntityName, tags));
            }

            var intelList = new List<SessionIntel>();
            foreach (var intel in tagResult.Intel) {
                intelList.Add(new SessionIntel(intel.RawTarget, intel.Message));
            }

            var transferList = new List<SessionTransfer>();
            foreach (var tr in tagResult.Transfers) {
                transferList.Add(new SessionTransfer(tr.Amount, tr.Denomination,
                    tr.Source, tr.Destination));
            }

            // Gen1/Gen2 sessions lack structured @Logi tags — fall back to scanning
            // raw content for plain-text "Logi: <url>" lines
            if (tagResult.Logs.Count == 0 && content != null) {
                ExtractPlainTextLogs(content, tagResult.Logs);
            }

            return new ExtractedSession {
                Header = header,
                Date = parsedDate,
                DateEnd = dateEnd,
                DateStr = dateStr,
                EndDayStr = endDayStr,
                Title = title,
                Format = format,
                Locations = locations,
                Logs = tagResult.Logs,
                PU = puList,
                Changes = changeList,
                Transfers = transferList,
                RawIntel = intelList,
                NarratorRawText = narratorRawText,
                MetaNarrators = tagResult.Narrators,
                Content = includeContent ? content : null,
                FirstNonEmptyLine = firstNonEmptyLine
            };
        }

        // ── Format detection ────────────────────────────────────────

        /// Classifies session format generation from content heuristics.
        /// Detection order matters: Gen2 is checked first (italic prefix is
        /// unambiguous), then Gen4 (@-prefix is definitive), then Gen3 (pu:
        /// prefix), with Gen1 as fallback for sessions predating structured tags.
        private static string DetectFormat(string firstNonEmptyLine,
            string[] texts, int[] parentIndices, int count) {

            if (firstNonEmptyLine != null && firstNonEmptyLine.StartsWith("*Lokalizacj")) {
                return "Gen2";
            }

            for (int i = 0; i < count; i++) {
                if (parentIndices[i] >= 0) continue; // only root items
                string lower = texts[i].ToLowerInvariant();
                if (lower.Length > 1 && lower[0] == '@' && char.IsLetter(lower[1])) {
                    return "Gen4";
                }
                if (lower.Length > 2 && lower[0] == 'p' && lower[1] == 'u' &&
                    (lower[2] == ':' || lower[2] == ' ')) {
                    return "Gen3";
                }
            }

            return "Gen1";
        }

        // ── Title extraction ────────────────────────────────────────

        /// Strips date prefix and trailing narrator segment from the header to
        /// extract the session title. Handles multi-day date suffixes (/DD).
        private static string ExtractTitle(string header, string dateStr, string endDayStr) {
            int dateIdx = header.IndexOf(dateStr);
            if (dateIdx < 0) return header;

            int dateLen = 10; // "yyyy-MM-dd"
            if (!string.IsNullOrEmpty(endDayStr)) {
                dateLen += 1 + endDayStr.Length; // "/DD"
            }

            string titlePart = header.Substring(dateIdx + dateLen).Trim();

            // Remove narrator part (last comma-delimited segment)
            int lastComma = titlePart.LastIndexOf(',');
            if (lastComma > 0) {
                return titlePart.Substring(0, lastComma).Trim(' ', ',', '-');
            }
            return titlePart.Trim(' ', ',', '-');
        }

        // ── Narrator raw text extraction ────────────────────────────

        /// Extracts the raw narrator text from the last comma segment of the header.
        /// Requires at least 2 commas (date, title, narrator). Single-comma headers
        /// (date, title) have no narrator segment — returns null.
        private static string ExtractNarratorRawText(string header) {
            int lastComma = header.LastIndexOf(',');
            if (lastComma < 0) return null;

            // Count commas
            int commaCount = 0;
            for (int i = 0; i < header.Length; i++) {
                if (header[i] == ',') commaCount++;
            }
            if (commaCount < 2) return null;

            return header.Substring(lastComma + 1).Trim();
        }

        // ── Tag dispatch ────────────────────────────────────────────

        /// 8-way tag dispatch reusing SessionTagParser types for structured output.
        /// Processes root list items only (parentIndices[i] < 0), dispatching on
        /// lowercased tag prefix: PU, Logi, Zmiany, Intel, Narrator, Data, Transfer.
        /// Children of each root tag provide the actual values.
        private static SessionTagParser.ParsedMetadata DispatchTags(
            string[] texts, int[] parentIndices,
            Dictionary<int, List<int>> childrenOf,
            int count, Regex puPattern, Regex urlPattern) {

            var result = new SessionTagParser.ParsedMetadata();

            for (int i = 0; i < count; i++) {
                if (parentIndices[i] >= 0) continue; // only root items

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
                                    result.PU.Add(new SessionTagParser.PUEntry {
                                        Character = charName, Value = dec, HasValue = true
                                    });
                                } else {
                                    result.PU.Add(new SessionTagParser.PUEntry {
                                        Character = charName, Value = 0, HasValue = false
                                    });
                                }
                            }
                        }
                    }
                    continue;
                }

                // Logi
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
                    Match inlineUrl = urlPattern.Match(itemText);
                    if (inlineUrl.Success) {
                        string url = inlineUrl.Groups[1].Value;
                        if (!result.Logs.Contains(url)) {
                            result.Logs.Add(url);
                        }
                    }
                    continue;
                }

                // Zmiany
                if (match.Length >= 6 && match[0] == 'z' && match[1] == 'm' &&
                    match[2] == 'i' && match[3] == 'a' && match[4] == 'n' &&
                    match[5] == 'y' &&
                    (match.Length == 6 || match[6] == ':' || match[6] == ' ')) {
                    if (children != null) {
                        foreach (int entityIdx in children) {
                            string entityName = texts[entityIdx].Trim();
                            var tags = new List<SessionTagParser.TagEntry>();

                            List<int> tagChildren;
                            if (childrenOf.TryGetValue(entityIdx, out tagChildren)) {
                                foreach (int tagIdx in tagChildren) {
                                    string tagText = texts[tagIdx].Trim();
                                    if (!tagText.StartsWith("@")) continue;
                                    int colonIdx = tagText.IndexOf(':');
                                    if (colonIdx < 0) continue;
                                    tags.Add(new SessionTagParser.TagEntry {
                                        Tag = tagText.Substring(0, colonIdx).Trim().ToLowerInvariant(),
                                        Value = tagText.Substring(colonIdx + 1).Trim()
                                    });
                                }
                            }

                            if (tags.Count > 0) {
                                result.Changes.Add(new SessionTagParser.ChangeEntry {
                                    EntityName = entityName,
                                    Tags = tags.ToArray()
                                });
                            }
                        }
                    }
                    continue;
                }

                // Intel
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
                            result.Intel.Add(new SessionTagParser.IntelEntry {
                                RawTarget = rawTarget, Message = message
                            });
                        }
                    }
                    continue;
                }

                // Narrator
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

                // Data
                if (match.Length > 4 && match[0] == 'd' && match[1] == 'a' &&
                    match[2] == 't' && match[3] == 'a' &&
                    (match[4] == ':' || match[4] == ' ')) {
                    int dataColonIdx = itemText.IndexOf(':');
                    if (dataColonIdx >= 0) {
                        string dataInline = itemText.Substring(dataColonIdx + 1).Trim();
                        if (dataInline.Length > 0) {
                            result.DateOverride = dataInline;
                        } else if (children != null) {
                            foreach (int ci in children) {
                                string val = texts[ci].Trim();
                                if (!string.IsNullOrWhiteSpace(val)) {
                                    result.DateOverride = val;
                                    break;
                                }
                            }
                        }
                    }
                    continue;
                }

                // Transfer
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
                            // Amount-optional: if first token is a positive integer,
                            // it is the amount and the rest is the identifier.
                            // Otherwise entire string is the identifier with amount=1.
                            int spaceIdx = amountDenom.IndexOf(' ');
                            int amount;
                            string denomStr;
                            if (spaceIdx > 0 && int.TryParse(amountDenom.Substring(0, spaceIdx), out amount) && amount > 0) {
                                denomStr = amountDenom.Substring(spaceIdx + 1).Trim();
                            } else {
                                amount = 1;
                                denomStr = amountDenom.Trim();
                            }
                            if (!string.IsNullOrEmpty(denomStr) &&
                                !string.IsNullOrWhiteSpace(source) &&
                                !string.IsNullOrWhiteSpace(destination)) {
                                result.Transfers.Add(new SessionTagParser.TransferEntry {
                                    Amount = amount, Denomination = denomStr,
                                    Source = source, Destination = destination
                                });
                            }
                        }
                    }
                    continue;
                }
            }

            return result;
        }

        // ── Location extraction (Strategy 2: tag-based) ─────────────

        /// Extracts locations using the format-appropriate Strategy 2 approach.
        /// Gen2: italic regex on first content line (*Lokalizacja: Place1, Place2*).
        /// Gen3/Gen4: root list item prefix matching for Lokalizacj*/Lokacj* tags
        /// with child bullets or inline comma-separated values.
        /// Gen1: no tag-based locations available — returns empty array.
        /// Strategy 1 (entity name resolution) stays in PowerShell post-processing.
        private static string[] ExtractLocations(string format,
            string firstNonEmptyLine, string[] texts, int[] parentIndices,
            Dictionary<int, List<int>> childrenOf, int count) {

            var locations = new List<string>();

            if (format == "Gen2") {
                if (firstNonEmptyLine != null) {
                    Match locMatch = LocItalicRx.Match(firstNonEmptyLine);
                    if (locMatch.Success) {
                        foreach (string part in locMatch.Groups[1].Value.Split(',')) {
                            string trimmed = part.Trim();
                            if (trimmed.Length > 0) locations.Add(trimmed);
                        }
                    }
                }
                return locations.ToArray();
            }

            if (format == "Gen3" || format == "Gen4") {
                // Strategy 2: find the root list item whose text starts with a location
                // tag prefix, then extract locations from its children or inline value
                int locItemIdx = -1;
                for (int i = 0; i < count; i++) {
                    if (parentIndices[i] >= 0) continue; // only root items
                    string testText = texts[i];
                    if (testText.StartsWith("@")) testText = testText.Substring(1);
                    if (testText.StartsWith("Lokalizacj") || testText.StartsWith("Lokacj")) {
                        locItemIdx = i;
                        break;
                    }
                }

                if (locItemIdx >= 0) {
                    List<int> children;
                    if (childrenOf.TryGetValue(locItemIdx, out children)) {
                        foreach (int ci in children) {
                            locations.Add(texts[ci].Trim());
                        }
                    }

                    if (locations.Count == 0) {
                        // No child bullets — try inline comma-separated values after colon
                        int colonIdx = texts[locItemIdx].IndexOf(':');
                        if (colonIdx >= 0) {
                            foreach (string part in texts[locItemIdx].Substring(colonIdx + 1).Trim().Split(',')) {
                                string trimmed = part.Trim();
                                if (trimmed.Length > 0) locations.Add(trimmed);
                            }
                        }
                    }
                }
            }

            return locations.ToArray();
        }

        // ── Plain text log extraction (Gen1/Gen2 fallback) ──────────

        /// Scans raw content line-by-line for "Logi: <url>" patterns as Gen1/Gen2
        /// fallback when no structured @Logi tags were found in list items.
        private static void ExtractPlainTextLogs(string content, List<string> logs) {
            int pos = 0;
            int contentLen = content.Length;
            while (pos < contentLen) {
                int lineEnd = content.IndexOf('\n', pos);
                if (lineEnd < 0) lineEnd = contentLen;
                string line = content.Substring(pos, lineEnd - pos).TrimEnd();
                pos = lineEnd + 1;

                Match m = LogiLineRx.Match(line);
                if (m.Success) {
                    logs.Add(m.Groups[1].Value);
                }
            }
        }
    }
}
