using System;
using System.Collections.Generic;
using System.Text.RegularExpressions;

namespace Robot {
    /// Compiled log content parser for ChatLog and Prose session log formats.
    ///
    /// Applies 3-5 precompiled regex operations per line in a single native pass
    /// with struct array output.
    ///
    /// Two format parsers:
    /// - ChatLog: [HH:MM] timestamped lines with optional [Channel] tags.
    ///   Uses a pending-timestamp state machine — a timestamp line with no content
    ///   after the channel tag is held pending until the next line resolves it
    ///   (continuation text, empty line, or next timestamp).
    /// - Prose: freeform text with location headers detected by heuristic
    ///   (short line <= 60 chars after empty line, no Speaker: pattern).
    ///
    /// Both parsers extract LocationSegments for location-based log partitioning.
    /// Format detection scans the first ~30 non-empty lines; 2+ timestamp matches
    /// selects ChatLog, otherwise Prose.
    ///
    /// Output uses struct arrays (LogLine[]) and class arrays (LocationSegment[])
    /// to minimize GC pressure. ParseResult is a class to allow null fields.
    /// LocationSegment is a class (not struct) because PowerShell consumers
    /// set Resolved/Stage properties after name resolution in Get-SessionLog;
    /// value-type boxing would lose mutations on array elements.
    ///
    /// Consumers: Parse-LogContent (parse-logcontent.ps1), Get-SessionLog (get-sessionlog.ps1)
    public sealed class LogParser {
        // ── Output types ────────────────────────────────────────────

        public class ParseResult {
            public string Format;
            public LogLine[] Lines;
            public LocationSegment[] LocationSegments;
        }

        public struct LogLine {
            public int Index;
            public string Time;
            public string Channel;
            public string Speaker;
            public string Text;
            public int Segment;
        }

        public sealed class LocationSegment {
            public int Index;
            public string Raw;
            public int StartLine;
            public int EndLine;
            public string Resolved;  // Set by Get-SessionLog after name resolution
            public string Stage;     // Set by Get-SessionLog after name resolution
        }

        // ── Precompiled patterns (match parse-logcontent.ps1 exactly) ─

        // [HH:MM] prefix with optional trailing whitespace
        private static readonly Regex TimestampRx = new Regex(
            @"^\[(\d{2}:\d{2})\]\s*",
            RegexOptions.Compiled);

        // [Channel] tag after timestamp
        private static readonly Regex ChannelRx = new Regex(
            @"^\[([^\]]+)\]\s*",
            RegexOptions.Compiled);

        // Speaker: text (non-greedy name, requires whitespace after colon)
        private static readonly Regex SpeakerRx = new Regex(
            @"^([^:]+?):\s+(.*)$",
            RegexOptions.Compiled);

        // Speaker: (no text, or only trailing whitespace)
        private static readonly Regex SpeakerOnlyRx = new Regex(
            @"^([^:]+?):\s*$",
            RegexOptions.Compiled);

        // Format detection: does line start with [HH:MM]?
        private static readonly Regex FormatDetectRx = new Regex(
            @"^\[\d{2}:\d{2}\]",
            RegexOptions.Compiled);

        // ── Public API ──────────────────────────────────────────────

        /// Detect format and parse content in one call.
        /// Returns ParseResult with Format, Lines, LocationSegments.
        public static ParseResult Parse(string content) {
            string[] rawLines = SplitLines(content);
            string format = DetectFormat(rawLines);
            if (format == "ChatLog")
                return ParseChatLog(rawLines);
            return ParseProse(rawLines);
        }

        /// Detect log format by scanning first ~30 non-empty lines.
        /// 2+ timestamp matches = ChatLog, otherwise Prose.
        public static string DetectFormat(string content) {
            return DetectFormat(SplitLines(content));
        }

        /// Parse ChatLog format content.
        public static ParseResult ParseChatLog(string content) {
            return ParseChatLog(SplitLines(content));
        }

        /// Parse Prose format content.
        public static ParseResult ParseProse(string content) {
            return ParseProse(SplitLines(content));
        }

        // ── Internal ────────────────────────────────────────────────

        private static string[] SplitLines(string content) {
            return content.Split(new[] { "\r\n", "\n" }, StringSplitOptions.None);
        }

        private static string DetectFormat(string[] lines) {
            int timestampCount = 0;
            int scannedCount = 0;
            for (int i = 0; i < lines.Length; i++) {
                string trimmed = lines[i].Trim();
                if (trimmed.Length == 0) continue;
                if (FormatDetectRx.IsMatch(trimmed)) {
                    timestampCount++;
                    if (timestampCount >= 2) return "ChatLog";
                }
                scannedCount++;
                if (scannedCount >= 30) break;  // 30 lines sufficient to distinguish formats
            }
            return "Prose";
        }

        private static ParseResult ParseChatLog(string[] rawLines) {
            var parsedLines = new List<LogLine>();
            var segments = new List<LocationSegment>();

            int currentSegment = -1;   // -1 = lines before first location header
            string pendingTime = null;
            string pendingChannel = null;

            for (int i = 0; i < rawLines.Length; i++) {
                string trimmed = rawLines[i].Trim();

                // Empty line: finalize pending timestamp as empty narration
                if (trimmed.Length == 0) {
                    if (pendingTime != null) {
                        parsedLines.Add(new LogLine {
                            Index = parsedLines.Count,
                            Time = pendingTime,
                            Channel = pendingChannel,
                            Speaker = null,
                            Text = "",
                            Segment = currentSegment
                        });
                        pendingTime = null;
                        pendingChannel = null;
                    }
                    continue;
                }

                // Check for timestamp
                Match tsMatch = TimestampRx.Match(trimmed);

                if (tsMatch.Success) {
                    // Finalize any pending timestamp first
                    if (pendingTime != null) {
                        parsedLines.Add(new LogLine {
                            Index = parsedLines.Count,
                            Time = pendingTime,
                            Channel = pendingChannel,
                            Speaker = null,
                            Text = "",
                            Segment = currentSegment
                        });
                        pendingTime = null;
                        pendingChannel = null;
                    }

                    string time = tsMatch.Groups[1].Value;
                    string rest = trimmed.Substring(tsMatch.Length);

                    // Extract channel tag
                    string channel = null;
                    Match chMatch = ChannelRx.Match(rest);
                    if (chMatch.Success) {
                        channel = chMatch.Groups[1].Value;
                        rest = rest.Substring(chMatch.Length);
                    }

                    // No content after channel: pending timestamp
                    if (rest.Length == 0) {
                        pendingTime = time;
                        pendingChannel = channel;
                        continue;
                    }

                    // Parse speaker:text or treat as narration
                    string speaker = null;
                    string text = rest;

                    Match spMatch = SpeakerRx.Match(rest);
                    if (spMatch.Success) {
                        speaker = spMatch.Groups[1].Value;
                        text = spMatch.Groups[2].Value;
                    } else {
                        Match spOnly = SpeakerOnlyRx.Match(rest);
                        if (spOnly.Success) {
                            speaker = spOnly.Groups[1].Value;
                            text = "";
                        }
                    }

                    parsedLines.Add(new LogLine {
                        Index = parsedLines.Count,
                        Time = time,
                        Channel = channel,
                        Speaker = speaker,
                        Text = text,
                        Segment = currentSegment
                    });
                    continue;
                }

                // Non-timestamped, non-empty line
                if (pendingTime != null) {
                    // Continuation of pending timestamp line
                    string speaker = null;
                    string text = trimmed;

                    Match spMatch = SpeakerRx.Match(trimmed);
                    if (spMatch.Success) {
                        speaker = spMatch.Groups[1].Value;
                        text = spMatch.Groups[2].Value;
                    }

                    parsedLines.Add(new LogLine {
                        Index = parsedLines.Count,
                        Time = pendingTime,
                        Channel = pendingChannel,
                        Speaker = speaker,
                        Text = text,
                        Segment = currentSegment
                    });
                    pendingTime = null;
                    pendingChannel = null;
                    continue;
                }

                // Location header (non-timestamped, no pending)
                currentSegment++;
                segments.Add(new LocationSegment {
                    Index = currentSegment,
                    Raw = trimmed,
                    StartLine = parsedLines.Count,
                    EndLine = -1
                });
            }

            // Finalize remaining pending timestamp
            if (pendingTime != null) {
                parsedLines.Add(new LogLine {
                    Index = parsedLines.Count,
                    Time = pendingTime,
                    Channel = pendingChannel,
                    Speaker = null,
                    Text = "",
                    Segment = currentSegment
                });
            }

            // Compute EndLine for segments
            ComputeEndLines(segments, parsedLines.Count);

            return new ParseResult {
                Format = "ChatLog",
                Lines = parsedLines.ToArray(),
                LocationSegments = segments.ToArray()
            };
        }

        private static ParseResult ParseProse(string[] rawLines) {
            var parsedLines = new List<LogLine>();
            var segments = new List<LocationSegment>();

            int currentSegment = -1;
            bool previousWasEmpty = true;

            for (int i = 0; i < rawLines.Length; i++) {
                string trimmed = rawLines[i].Trim();

                if (trimmed.Length == 0) {
                    previousWasEmpty = true;
                    continue;
                }

                // Heuristic: location header = short line after empty line, no Speaker: pattern
                bool isSpeaker = SpeakerRx.IsMatch(trimmed) || SpeakerOnlyRx.IsMatch(trimmed);

                if (previousWasEmpty && !isSpeaker && trimmed.Length <= 60) {  // 60 = max location header length heuristic
                    currentSegment++;
                    segments.Add(new LocationSegment {
                        Index = currentSegment,
                        Raw = trimmed,
                        StartLine = parsedLines.Count,
                        EndLine = -1
                    });
                    previousWasEmpty = false;
                    continue;
                }

                // Parse as dialogue or narration
                string speaker = null;
                string text = trimmed;

                Match spMatch = SpeakerRx.Match(trimmed);
                if (spMatch.Success) {
                    speaker = spMatch.Groups[1].Value;
                    text = spMatch.Groups[2].Value;
                } else {
                    Match spOnly = SpeakerOnlyRx.Match(trimmed);
                    if (spOnly.Success) {
                        speaker = spOnly.Groups[1].Value;
                        text = "";
                    }
                }

                parsedLines.Add(new LogLine {
                    Index = parsedLines.Count,
                    Time = null,
                    Channel = null,
                    Speaker = speaker,
                    Text = text,
                    Segment = currentSegment
                });
                previousWasEmpty = false;
            }

            // Compute EndLine for segments
            ComputeEndLines(segments, parsedLines.Count);

            return new ParseResult {
                Format = "Prose",
                Lines = parsedLines.ToArray(),
                LocationSegments = segments.ToArray()
            };
        }

        private static void ComputeEndLines(List<LocationSegment> segments, int lineCount) {
            for (int i = 0; i < segments.Count; i++) {
                if (i < segments.Count - 1) {
                    segments[i].EndLine = segments[i + 1].StartLine - 1;
                } else {
                    segments[i].EndLine = lineCount - 1;
                }
            }
        }
    }
}
