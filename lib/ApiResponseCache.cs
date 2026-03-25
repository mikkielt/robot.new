using System;
using System.Collections.Generic;
using System.IO;
using System.Text;

namespace Robot {
    /// Fingerprint-based response cache for API endpoints. Stores pre-serialized
    /// JSON responses as sidecar files under .robot.local/.cache/api/. Each sidecar
    /// records which domain fingerprints (entity, session, graph) it depends on;
    /// a fingerprint mismatch triggers lazy invalidation on next read.
    ///
    /// Three domains track independent data lifecycles:
    ///   entity  — entities.md, *-NNN-ent.md overflow files, Gracze.md
    ///   session — all *.md files under Sesje/ directory tree
    ///   graph   — _index.json + _meta.json in .robot.local/res/session-graph/
    ///
    /// Thread safety: file I/O is not locked — concurrent writes to the same sidecar
    /// may race, but the worst case is a redundant recompute (no corruption, because
    /// writes use a temp-file-then-rename pattern). Fingerprint state is protected
    /// by _fpLock for cross-thread consistency.
    ///
    /// Access pattern: static field ApiServer.ResponseCache provides shared access
    /// across all runspaces (worker threads and main thread alike), mirroring how
    /// ApiServer.CacheVersion is shared.
    ///
    /// Consumers: ApiServer.HandleRequestAsync (middleware intercept + sidecar write),
    ///            api-handlers-write.ps1 (domain invalidation after mutations),
    ///            Clear-ParseCaches (full cache wipe)
    public sealed class ApiResponseCache {
        private static readonly UTF8Encoding Utf8NoBom = new UTF8Encoding(false);

        // Domain fingerprint snapshot — refreshed by RefreshFingerprints()
        private readonly Dictionary<string, string> _fingerprints =
            new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        private readonly object _fpLock = new object();

        // Cache directory: {RepoRoot}/.robot.local/.cache/api/
        public string CacheDirectory { get; set; }

        /// Refresh all domain fingerprints from file system timestamps.
        /// Called once per request cycle (before sidecar lookup).
        /// repoRoot: from Get-RepoRoot or Set-RepoRoot override.
        public void RefreshFingerprints(string repoRoot) {
            lock (_fpLock) {
                _fingerprints["entity"]  = ComputeEntityFingerprint(repoRoot);
                _fingerprints["session"] = ComputeSessionFingerprint(repoRoot);
                _fingerprints["graph"]   = ComputeGraphFingerprint(repoRoot);
            }
        }

        /// Get current fingerprint for a domain. Returns null if not yet computed.
        public string GetFingerprint(string domain) {
            lock (_fpLock) {
                return _fingerprints.TryGetValue(domain, out var fp) ? fp : null;
            }
        }

        /// Build a composite ETag from the domains this endpoint depends on.
        /// Format: "entity=<ticks>;session=<ticks>" — deterministic, stable.
        public string BuildETag(string[] domains) {
            lock (_fpLock) {
                var parts = new List<string>(domains.Length);
                foreach (var d in domains) {
                    if (_fingerprints.TryGetValue(d, out var fp))
                        parts.Add(d + "=" + fp);
                }
                parts.Sort(StringComparer.Ordinal);
                return string.Join(";", parts);
            }
        }

        /// Try to load a cached sidecar. Returns true if the sidecar exists,
        /// its fingerprints match current state, and JSON bytes are available.
        /// etag: the ETag value for the cached response (for 304 support).
        public bool TryLoad(string cacheKey, string[] domains,
                            out byte[] json, out string etag) {
            json = null;
            etag = null;
            if (string.IsNullOrEmpty(CacheDirectory)) return false;

            string jsonPath = Path.Combine(CacheDirectory, cacheKey + ".json");
            string metaPath = Path.Combine(CacheDirectory, cacheKey + ".meta");

            if (!File.Exists(jsonPath) || !File.Exists(metaPath)) return false;

            // Read meta and validate fingerprints
            try {
                string[] metaLines = File.ReadAllLines(metaPath, Utf8NoBom);
                var metaFp = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
                foreach (string line in metaLines) {
                    int eq = line.IndexOf('=');
                    if (eq > 0) metaFp[line.Substring(0, eq)] = line.Substring(eq + 1);
                }

                // Validate each required domain fingerprint
                lock (_fpLock) {
                    foreach (string domain in domains) {
                        if (!metaFp.TryGetValue(domain, out var savedFp)) return false;
                        if (!_fingerprints.TryGetValue(domain, out var currentFp)) return false;
                        if (savedFp != currentFp) return false;
                    }
                }

                json = File.ReadAllBytes(jsonPath);
                etag = BuildETag(domains);
                return true;
            } catch {
                return false; // Corrupt meta/json — treat as miss
            }
        }

        /// Save a computed response as a sidecar file. Uses temp-file-then-rename
        /// for atomic writes (prevents serving partial files on concurrent reads).
        /// Compatible with both .NET Framework 4.x and .NET Core.
        public void Save(string cacheKey, string[] domains, byte[] json) {
            if (string.IsNullOrEmpty(CacheDirectory)) return;

            try {
                if (!Directory.Exists(CacheDirectory))
                    Directory.CreateDirectory(CacheDirectory);

                // Write meta file (domain=fingerprint per line)
                string metaPath = Path.Combine(CacheDirectory, cacheKey + ".meta");
                var sb = new StringBuilder();
                sb.AppendLine("generatedAt=" + DateTime.UtcNow.ToString("o"));
                lock (_fpLock) {
                    foreach (string domain in domains) {
                        if (_fingerprints.TryGetValue(domain, out var fp))
                            sb.AppendLine(domain + "=" + fp);
                    }
                }
                File.WriteAllText(metaPath, sb.ToString(), Utf8NoBom);

                // Write JSON via temp file then rename (atomic on most filesystems)
                // Uses Delete+Move for .NET Framework 4.x compatibility
                string jsonPath = Path.Combine(CacheDirectory, cacheKey + ".json");
                string tmpPath  = jsonPath + ".tmp";
                File.WriteAllBytes(tmpPath, json);
                if (File.Exists(jsonPath)) File.Delete(jsonPath);
                File.Move(tmpPath, jsonPath);
            } catch {
                // Best-effort — cache write failure doesn't affect correctness
            }
        }

        /// Delete all sidecar files that depend on a specific domain. Called after
        /// writes that affect that domain (e.g., entity write → invalidate "entity").
        public void InvalidateDomain(string domain) {
            if (string.IsNullOrEmpty(CacheDirectory) || !Directory.Exists(CacheDirectory))
                return;

            try {
                foreach (string metaFile in Directory.GetFiles(CacheDirectory, "*.meta")) {
                    string[] lines = File.ReadAllLines(metaFile, Utf8NoBom);
                    foreach (string line in lines) {
                        if (line.StartsWith(domain + "=", StringComparison.OrdinalIgnoreCase)) {
                            // This sidecar depends on the invalidated domain
                            string baseName = Path.GetFileNameWithoutExtension(metaFile);
                            string jsonFile = Path.Combine(CacheDirectory, baseName + ".json");
                            try { File.Delete(metaFile); } catch { }
                            try { File.Delete(jsonFile); } catch { }
                            break;
                        }
                    }
                }
            } catch { }
        }

        /// Delete entire cache directory (called by Clear-ParseCaches fallback).
        public void Clear() {
            if (string.IsNullOrEmpty(CacheDirectory)) return;
            try {
                if (Directory.Exists(CacheDirectory))
                    Directory.Delete(CacheDirectory, true);
            } catch { }
        }

        // ── Fingerprint computation ────────────────────────────────────

        /// Entity fingerprint: ticks from entities.md + *-NNN-ent.md + Gracze.md.
        /// Mirrors get-entity.ps1 entity cache key and resolve-name.ps1
        /// Get-EntityFilesFingerprint logic.
        private static string ComputeEntityFingerprint(string repoRoot) {
            var sb = new StringBuilder();
            AppendFileTicks(sb, Path.Combine(repoRoot, "entities.md"));
            try {
                foreach (string f in Directory.GetFiles(repoRoot, "*-*-ent.md",
                    SearchOption.AllDirectories))
                    AppendFileTicks(sb, f);
            } catch { }
            AppendFileTicks(sb, Path.Combine(repoRoot, "Gracze.md"));
            return sb.Length > 0 ? sb.ToString() : "";
        }

        /// Session fingerprint: ticks from all session .md files in Sesje/ directory.
        private static string ComputeSessionFingerprint(string repoRoot) {
            var sb = new StringBuilder();
            string sesjeDir = Path.Combine(repoRoot, "Sesje");
            if (Directory.Exists(sesjeDir)) {
                try {
                    foreach (string f in Directory.GetFiles(sesjeDir, "*.md",
                        SearchOption.AllDirectories))
                        AppendFileTicks(sb, f);
                } catch { }
            }
            return sb.Length > 0 ? sb.ToString() : "";
        }

        /// Graph fingerprint: ticks from _index.json + _meta.json in
        /// .robot.local/res/session-graph/ (the session graph persistence directory).
        private static string ComputeGraphFingerprint(string repoRoot) {
            var sb = new StringBuilder();
            string graphDir = Path.Combine(repoRoot, ".robot.local", "res", "session-graph");
            AppendFileTicks(sb, Path.Combine(graphDir, "_index.json"));
            AppendFileTicks(sb, Path.Combine(graphDir, "_meta.json"));
            return sb.Length > 0 ? sb.ToString() : "";
        }

        private static void AppendFileTicks(StringBuilder sb, string path) {
            try {
                if (File.Exists(path)) {
                    var info = new FileInfo(path);
                    sb.Append(info.LastWriteTimeUtc.Ticks).Append(':');
                }
            } catch { }
        }
    }
}
