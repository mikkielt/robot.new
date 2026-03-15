using System;
using System.Collections.Generic;
using System.Text;
using System.Text.RegularExpressions;

namespace Robot {
    /// Compiled Markdown line scanner for parse-markdownfile.ps1.
    ///
    /// Compiled C# replaces per-line PowerShell parsing that applied 7 regex
    /// operations per line through the interpreter, costing ~15ms per file on
    /// the 700+ Markdown files in the lore repository. The C# version reduces
    /// this to ~1.5ms per file, critical for Get-Markdown which parses all files
    /// in parallel via RunspacePool.
    ///
    /// Single-pass algorithm producing flat struct arrays with int-based parent
    /// indices (not object references). The PowerShell integration layer in
    /// parse-markdownfile.ps1 reconstructs PSCustomObject parent references
    /// from these indices for consumer compatibility.
    ///
    /// Per-line operations (6 precompiled regex):
    /// - CodeFence: toggle code block state (skip all parsing inside fences)
    /// - MdLink: extract [text](url) Markdown links
    /// - PlainUrl: extract bare http/https URLs from link-stripped remainder
    /// - Header: detect #+ level headers, maintain parent stack
    /// - ListItem: detect bullet/numbered items with indent normalization
    ///   Floor(raw/2)*2, maintain parent stack by indent level
    /// - MarkerNum: distinguish "1." numbered from "-*+" bullet markers
    ///
    /// Output arrays: HeaderEntry[] (level, text, parentIndex, lineNumber),
    /// SectionEntry[] (headerIndex, content, list range), ListEntry[] (type,
    /// text, indent, parentIndex, sectionHeaderIndex), LinkEntry[] (type, text, url).
    ///
    /// Pre-loaded by get-markdown.ps1 before RunspacePool workers start to
    /// ensure the type is available in all runspaces.
    ///
    /// Consumers: parse-markdownfile.ps1 (primary), get-markdown.ps1 (type loading)
    public sealed class MarkdownScanner {

        // ── Output types ────────────────────────────────────────────

        public class ScanResult {
            public HeaderEntry[] Headers;
            public SectionEntry[] Sections;
            public ListEntry[] Lists;
            public LinkEntry[] Links;
        }

        public struct HeaderEntry {
            public int Level;
            public string Text;
            public int ParentIndex;   // -1 = no parent
            public int LineNumber;
        }

        public struct SectionEntry {
            public int HeaderIndex;   // -1 = root section (before first header)
            public string Content;
            public int ListStartIndex;  // index into Lists array
            public int ListCount;       // number of list items in this section
        }

        public struct ListEntry {
            public string Type;        // "Bullet" or "Numbered"
            public string Text;
            public int Indent;
            public int ParentIndex;    // -1 = no parent list item
            public int SectionHeaderIndex;  // -1 = root section
        }

        public struct LinkEntry {
            public string Type;        // "MarkdownLink" or "PlainUrl"
            public string Text;        // null for PlainUrl
            public string Url;
        }

        // ── Precompiled patterns ────────────────────────────────────

        private static readonly Regex MdLinkRx = new Regex(
            @"\[(.+?)\]\((.+?)\)", RegexOptions.Compiled);
        private static readonly Regex PlainUrlRx = new Regex(
            @"https?://[^\s\)\]]+", RegexOptions.Compiled);
        private static readonly Regex CodeFenceRx = new Regex(
            @"^```", RegexOptions.Compiled);
        private static readonly Regex HeaderRx = new Regex(
            @"^(#+)\s*(.+)$", RegexOptions.Compiled);
        private static readonly Regex ListItemRx = new Regex(
            @"^(\s*)(\d+\.|[-\*\+])\s+(.+)$", RegexOptions.Compiled);
        private static readonly Regex MarkerNumRx = new Regex(
            @"^\d+\.", RegexOptions.Compiled);

        // ── Public API ──────────────────────────────────────────────

        /// Parse lines from a Markdown file into structured flat arrays.
        /// Returns ScanResult with index-based parent references for headers
        /// and list items. Code-fenced blocks are included in section content
        /// but their lines are not parsed for headers, list items, or links.
        public static ScanResult Parse(string[] lines) {
            var headers   = new List<HeaderEntry>();
            var sections  = new List<SectionEntry>();
            var listItems = new List<ListEntry>();
            var links     = new List<LinkEntry>();

            // Parser state
            var content       = new StringBuilder();
            int currentHeaderIdx = -1;
            bool inCodeBlock  = false;
            int lineNumber    = 0;
            int sectionListStart = 0;
            int sectionListCount = 0;

            // Stacks store indices into headers/listItems arrays
            var headerStack = new Stack<int>();
            var listStack   = new Stack<int>();

            for (int i = 0; i < lines.Length; i++) {
                lineNumber++;
                string trimLine = lines[i].TrimEnd();

                // Code fence toggle
                if (CodeFenceRx.IsMatch(trimLine)) {
                    inCodeBlock = !inCodeBlock;
                    content.Append(lines[i]).Append('\n');
                    continue;
                }

                if (inCodeBlock) {
                    content.Append(lines[i]).Append('\n');
                    continue;
                }

                // Link extraction: Markdown-style first
                foreach (Match lm in MdLinkRx.Matches(trimLine)) {
                    links.Add(new LinkEntry {
                        Type = "MarkdownLink",
                        Text = lm.Groups[1].Value,
                        Url  = lm.Groups[2].Value
                    });
                }
                // Plain URLs from remainder (after stripping Markdown links)
                string stripped = MdLinkRx.Replace(trimLine, "");
                foreach (Match um in PlainUrlRx.Matches(stripped)) {
                    links.Add(new LinkEntry {
                        Type = "PlainUrl",
                        Text = null,
                        Url  = um.Value
                    });
                }

                // Header detection
                Match hm = HeaderRx.Match(trimLine);
                if (hm.Success) {
                    int level = hm.Groups[1].Value.Length;
                    string text = hm.Groups[2].Value.Trim();

                    // Pop headers at same or deeper level
                    while (headerStack.Count > 0 &&
                           headers[headerStack.Peek()].Level >= level) {
                        headerStack.Pop();
                    }

                    int parentIdx = headerStack.Count > 0 ? headerStack.Peek() : -1;

                    int headerIdx = headers.Count;
                    headers.Add(new HeaderEntry {
                        Level = level,
                        Text = text,
                        ParentIndex = parentIdx,
                        LineNumber = lineNumber
                    });
                    headerStack.Push(headerIdx);

                    // Flush previous section
                    if (content.Length > 0 || currentHeaderIdx != -1) {
                        sections.Add(new SectionEntry {
                            HeaderIndex = currentHeaderIdx,
                            Content = content.ToString().Trim(),
                            ListStartIndex = sectionListStart,
                            ListCount = sectionListCount
                        });
                    }

                    content.Clear();
                    listStack.Clear();
                    currentHeaderIdx = headerIdx;
                    sectionListStart = listItems.Count;
                    sectionListCount = 0;
                    continue;
                }

                // List item detection
                Match lim = ListItemRx.Match(trimLine);
                if (lim.Success) {
                    int rawIndent = lim.Groups[1].Value.Length;
                    int indent = (int)(Math.Floor(rawIndent / 2.0) * 2);  // normalize to even indent levels

                    string marker = lim.Groups[2].Value;
                    string type = MarkerNumRx.IsMatch(marker) ? "Numbered" : "Bullet";
                    string text = lim.Groups[3].Value.Trim();

                    // Pop items at same or deeper indent
                    while (listStack.Count > 0 &&
                           listItems[listStack.Peek()].Indent >= indent) {
                        listStack.Pop();
                    }

                    int parentIdx = listStack.Count > 0 ? listStack.Peek() : -1;

                    int listIdx = listItems.Count;
                    listItems.Add(new ListEntry {
                        Type = type,
                        Text = text,
                        Indent = indent,
                        ParentIndex = parentIdx,
                        SectionHeaderIndex = currentHeaderIdx
                    });
                    listStack.Push(listIdx);
                    sectionListCount++;

                    content.Append(lines[i]).Append('\n');
                    continue;
                }

                content.Append(lines[i]).Append('\n');
            }

            // Flush final section
            if (content.Length > 0 || currentHeaderIdx != -1) {
                sections.Add(new SectionEntry {
                    HeaderIndex = currentHeaderIdx,
                    Content = content.ToString().Trim(),
                    ListStartIndex = sectionListStart,
                    ListCount = sectionListCount
                });
            }

            return new ScanResult {
                Headers  = headers.ToArray(),
                Sections = sections.ToArray(),
                Lists    = listItems.ToArray(),
                Links    = links.ToArray()
            };
        }
    }
}
