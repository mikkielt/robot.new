using System;
using System.Buffers;
using System.Collections.Generic;
using System.Security.Cryptography;
using System.Text;

namespace Robot {
    /// SHA256 content hasher with zero-allocation inner loop for session graph
    /// staleness detection.
    ///
    /// Compiled C# replaces a PowerShell pipeline of [regex]'\s+'.Replace($Content, '') +
    /// [System.Text.Encoding]::UTF8.GetBytes() + SHA256.ComputeHash() that allocated three
    /// intermediate strings/arrays per call. The C# version fuses whitespace stripping and
    /// UTF-8 encoding into a single pass, renting the byte buffer from ArrayPool<byte>.
    ///
    /// Called by Get-SessionContentHash for every session section (~500-700 sections per run).
    /// HashSections batches header+body pairs for sidecar file generation.
    ///
    /// Whitespace semantics: char.IsWhiteSpace matches the same set as .NET regex \s
    /// (tabs, spaces, CR, LF, form feeds, non-breaking spaces, etc.), ensuring hash
    /// stability across line-ending normalization.
    ///
    /// Thread safety: static SHA256 instance guarded by lock — safe for RunspacePool
    /// parallel markdown parsing in Get-Markdown.
    ///
    /// Allocation strategy: ArrayPool<byte>.Shared.Rent for the encoding buffer,
    /// single char[] for hex output. No per-call GC pressure on the hot path.
    ///
    /// Consumers: Get-SessionContentHash, Save-SessionHashSidecar (session-hashhelpers.ps1)
    public sealed class ContentHasher {
        private static readonly SHA256 _sha256 = SHA256.Create();
        private static readonly object _lock = new object();

        /// Compute SHA256 of whitespace-stripped content.
        /// Returns lowercase 64-char hex string. Empty/whitespace-only content
        /// returns the SHA256 of an empty byte array (stable sentinel value).
        public static string Hash(string content) {
            if (string.IsNullOrEmpty(content)) return HashEmpty();

            // Pre-count to size the ArrayPool rental exactly
            int nonWsCount = 0;
            for (int i = 0; i < content.Length; i++)
                if (!char.IsWhiteSpace(content[i])) nonWsCount++;

            if (nonWsCount == 0) return HashEmpty();

            // Rent buffer from pool (avoids GC pressure on repeated calls)
            int maxBytes = Encoding.UTF8.GetMaxByteCount(nonWsCount);
            byte[] buffer = ArrayPool<byte>.Shared.Rent(maxBytes);
            try {
                // Single-pass: strip whitespace + encode to UTF-8
                int byteCount = 0;
                for (int i = 0; i < content.Length; i++) {
                    char c = content[i];
                    if (!char.IsWhiteSpace(c)) {
                        if (c < 128) {  // single-byte ASCII: direct cast avoids Encoding.GetBytes overhead
                            buffer[byteCount++] = (byte)c;
                        } else if (char.IsHighSurrogate(c) && i + 1 < content.Length &&
                                   char.IsLowSurrogate(content[i + 1])) {
                            // Surrogate pair: must encode both chars as one unit for valid UTF-8
                            byteCount += Encoding.UTF8.GetBytes(content, i, 2, buffer, byteCount);
                            i++;
                        } else {
                            // Multi-byte BMP char (e.g. Polish diacritics: ąęćłńóśźż)
                            byteCount += Encoding.UTF8.GetBytes(content, i, 1, buffer, byteCount);
                        }
                    }
                }

                // Hash with lock (SHA256 is not thread-safe)
                byte[] hash;
                lock (_lock) {
                    hash = _sha256.ComputeHash(buffer, 0, byteCount);
                }

                return ToHexString(hash);
            } finally {
                ArrayPool<byte>.Shared.Return(buffer);
            }
        }

        /// Batch-hash sections: headerLines[i] + "\n" + bodies[i].
        /// Returns Dictionary<string, string> keyed by header line (OrdinalIgnoreCase).
        /// Used by Save-SessionHashSidecar to generate per-section hashes in one call.
        public static Dictionary<string, string> HashSections(
            string[] headerLines, string[] bodies) {
            var result = new Dictionary<string, string>(headerLines.Length,
                StringComparer.OrdinalIgnoreCase);
            for (int i = 0; i < headerLines.Length; i++) {
                string fullContent = headerLines[i] + "\n" + bodies[i];
                result[headerLines[i]] = Hash(fullContent);
            }
            return result;
        }

        private static string ToHexString(byte[] bytes) {
            char[] chars = new char[bytes.Length * 2];  // 32 bytes -> 64 hex chars
            for (int i = 0; i < bytes.Length; i++) {
                chars[i * 2] = "0123456789abcdef"[bytes[i] >> 4];      // high nibble
                chars[i * 2 + 1] = "0123456789abcdef"[bytes[i] & 0xF]; // low nibble
            }
            return new string(chars);
        }

        private static string HashEmpty() {
            lock (_lock) {
                return ToHexString(_sha256.ComputeHash(Array.Empty<byte>()));
            }
        }
    }
}
