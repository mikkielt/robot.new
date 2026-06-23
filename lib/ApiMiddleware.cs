using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Net;
using System.Threading;

namespace Robot {
    /// Token metadata returned by authentication: display name, granted scopes,
    /// and ISO 8601 creation timestamp. Properties are mutable for PowerShell
    /// property-bag construction in New-RobotApiToken / api-token-helpers.ps1.
    ///
    /// Session-token fields (ExpiresAt / PlayerName / MargonemUserId / CreatedAtTicks)
    /// are null/zero for persistent operator tokens — they only carry values for
    /// tokens minted by Invoke-ApiAuthMargonem (see ApiSessionTokenStore).
    public sealed class ApiTokenInfo {
        public string Name { get; set; }
        public string[] Scopes { get; set; }
        public string CreatedAt { get; set; }

        // ── Session-token fields (null for persistent tokens) ──────────
        public DateTimeOffset? ExpiresAt      { get; set; }
        public string          PlayerName     { get; set; }
        public long?           MargonemUserId { get; set; }
        public long            CreatedAtTicks { get; set; } // for FIFO eviction
    }

    /// Thread-safe token store for bearer token authentication. Backed by
    /// ConcurrentDictionary for lock-free concurrent Add/Remove from PowerShell
    /// cmdlets while Authenticate runs on HTTP threads. Compiled C# because
    /// FixedTimeEquals must iterate every stored token in constant time
    /// (no short-circuit) to prevent timing side-channel attacks.
    ///
    /// Consumers: api-token-helpers.ps1 (Add/RemoveByName/ListTokens),
    ///            ApiMiddleware.Authenticate (token lookup on every request)
    public sealed class ApiTokenStore {
        private readonly ConcurrentDictionary<string, ApiTokenInfo> _tokens =
            new ConcurrentDictionary<string, ApiTokenInfo>(StringComparer.Ordinal);

        public bool IsEmpty => _tokens.IsEmpty;
        public int Count => _tokens.Count;

        /// Store a token-to-info mapping. Returns false if the token string
        /// already exists (duplicate raw token values are rejected).
        public bool Add(string token, ApiTokenInfo info) {
            return _tokens.TryAdd(token, info);
        }

        /// Remove a token by its display name (case-insensitive match on ApiTokenInfo.Name).
        /// Outputs the raw token string via removedToken for caller confirmation.
        /// Returns false if no token with that name exists.
        public bool RemoveByName(string name, out string removedToken) {
            removedToken = null;
            foreach (var kvp in _tokens) {
                if (string.Equals(kvp.Value.Name, name, StringComparison.OrdinalIgnoreCase)) {
                    removedToken = kvp.Key;
                    return _tokens.TryRemove(kvp.Key, out _);
                }
            }
            return false;
        }

        /// O(N) scan with FixedTimeEquals per token — every token is compared
        /// regardless of early match to maintain constant-time behavior.
        public ApiTokenInfo Authenticate(string bearerToken) {
            if (string.IsNullOrEmpty(bearerToken)) return null;
            ApiTokenInfo matched = null;
            foreach (var kvp in _tokens) {
                if (ApiMiddleware.FixedTimeEquals(kvp.Key, bearerToken)) {
                    matched = kvp.Value;
                }
            }
            return matched;
        }

        /// Returns token metadata (name, scopes, createdAt) without raw token values.
        /// Used by Get-RobotApiToken to list registered tokens safely.
        public List<Dictionary<string, object>> ListTokens() {
            var result = new List<Dictionary<string, object>>();
            foreach (var kvp in _tokens) {
                result.Add(new Dictionary<string, object> {
                    ["name"]      = kvp.Value.Name,
                    ["scopes"]    = kvp.Value.Scopes,
                    ["createdAt"] = kvp.Value.CreatedAt
                });
            }
            return result;
        }

        public void Clear() { _tokens.Clear(); }
    }

    /// HTTP middleware pipeline: authentication, CORS, rate limiting, and request
    /// size enforcement. Compiled C# because every HTTP request passes through
    /// these checks before reaching PowerShell handlers — interpreted overhead
    /// on the hot path would dominate request latency.
    ///
    /// Rate limiter: per-IP token bucket with configurable capacity and refill
    /// rate. ConcurrentDictionary provides lock-free per-IP state; stale buckets
    /// (no requests for 10 minutes) are lazily evicted on next access.
    ///
    /// Auth pipeline (two tiers, checked in order):
    /// 1. Multi-token store (ApiTokenStore) — preferred, scope-aware
    /// 2. Open access (no auth configured) — grants admin:all to all requests
    /// All token comparisons use FixedTimeEquals to prevent timing attacks.
    ///
    /// Thread safety: all mutable state is in ConcurrentDictionary (_buckets)
    /// or Interlocked-accessed. Properties (AuthToken, CorsOrigin, etc.) are
    /// set once at startup before HTTP threads begin.
    ///
    /// Consumers: ApiServer.HandleRequestAsync (middleware chain),
    ///            Start-RobotApi (creates instance, sets properties)
    public sealed class ApiMiddleware {
        public string AuthToken { get; set; }
        public ApiTokenStore TokenStore { get; set; }
        public ApiSessionTokenStore SessionStore { get; set; }
        public bool ReadOnly { get; set; }
        public int MaxRequestBody { get; set; } = 65536;    // 64 KB — sufficient for JSON entity payloads
        public int RateLimitPerSecond { get; set; } = 100; // refill rate per IP
        public int RateLimitBurst { get; set; } = 200;     // max burst capacity per IP

        /// Allowed CORS origins. Entries may be exact origins
        /// ("https://www.margonem.pl"), patterns with a single '*'
        /// in the host segment ("https://*.margonem.pl"), or the
        /// literal "*" (allow any; incompatible with credentials).
        ///
        /// Populated either directly (Add to the list) or via the
        /// CorsOrigin setter which splits on ',' for plugin-config
        /// compatibility.
        public List<string> CorsOrigins { get; set; } = new List<string>();

        /// Comma-separated string view of CorsOrigins for plugin-config
        /// compatibility (Start-RobotApi.ps1 reads $Config.CorsOrigin as
        /// a string from plugin.psd1). Setting this replaces CorsOrigins;
        /// getting it joins them with ','. Empty/null clears the list.
        public string CorsOrigin {
            get { return CorsOrigins == null ? null : string.Join(",", CorsOrigins); }
            set {
                CorsOrigins = new List<string>();
                if (string.IsNullOrWhiteSpace(value)) return;
                foreach (string raw in value.Split(',')) {
                    string trimmed = raw.Trim();
                    if (trimmed.Length > 0) CorsOrigins.Add(trimmed);
                }
            }
        }

        private readonly ConcurrentDictionary<string, TokenBucket> _buckets =
            new ConcurrentDictionary<string, TokenBucket>();

        /// Per-route token buckets keyed by "{routeId}:{clientIp}". Used
        /// by CheckRouteRateLimit (WP-17). Bucket capacity == perMinute;
        /// refill rate == perMinute / 60 tokens/sec. Stale eviction is
        /// handled lazily on access via the existing IsStale check.
        private readonly ConcurrentDictionary<string, TokenBucket> _routeBuckets =
            new ConcurrentDictionary<string, TokenBucket>();

        /// Authenticate request and return token info.
        /// Returns null if authentication fails (caller should 401).
        ///
        /// Resolution order:
        ///   1. Session token store (Margonem-minted) — common path for
        ///      browser add-on requests after the silent-refresh flow.
        ///   2. Persistent multi-token store (operator-issued).
        ///   3. Open-access fallback — preserved ONLY for localhost dev
        ///      (Start-RobotApi enforces this via Option D startup guards
        ///      when Margonem auth or non-loopback bind is configured).
        public ApiTokenInfo Authenticate(HttpListenerRequest request) {
            string header = request.Headers["Authorization"];
            string bearer = null;
            if (!string.IsNullOrEmpty(header)
                && header.StartsWith("Bearer ", StringComparison.Ordinal)) {
                bearer = header.Substring(7);
            }

            // Session tokens first — interactive (browser add-on) clients
            if (bearer != null && SessionStore != null && SessionStore.Count > 0) {
                var sessionInfo = SessionStore.Authenticate(bearer);
                if (sessionInfo != null) return sessionInfo;
            }

            // Persistent multi-token store
            if (TokenStore != null && !TokenStore.IsEmpty) {
                if (bearer == null) return null;
                return TokenStore.Authenticate(bearer);
            }

            // Open access — synthetic identity tagged _open_local so audit
            // log distinguishes dev requests from real authenticated traffic.
            // Start-RobotApi (WP-14) prevents this path from ever firing in
            // production-shaped deployments.
            if (string.IsNullOrEmpty(AuthToken))
                return new ApiTokenInfo { Name = "_open_local", Scopes = new[] { "admin:all" } };

            // AuthToken set but no TokenStore — reject (fail-closed)
            return null;
        }

        /// Check whether a token has a required scope.
        /// admin:all is a wildcard. Hierarchical: "entity:read" covers "entity:read:own".
        public static bool HasScope(ApiTokenInfo token, string requiredScope) {
            if (token == null || token.Scopes == null) return false;
            if (string.IsNullOrEmpty(requiredScope)) return true;
            foreach (string scope in token.Scopes) {
                if (string.Equals(scope, "admin:all", StringComparison.OrdinalIgnoreCase))
                    return true;
                if (string.Equals(scope, requiredScope, StringComparison.OrdinalIgnoreCase))
                    return true;
                if (requiredScope.StartsWith(scope + ":", StringComparison.OrdinalIgnoreCase))
                    return true;
            }
            return false;
        }

        /// Inject CORS headers if the request Origin matches any configured
        /// pattern in CorsOrigins. Returns true if headers were added.
        ///
        /// Matching:
        ///   - Literal "*" → echoes "*" (incompatible with credentials)
        ///   - Exact origin match (case-insensitive) → echoes request Origin
        ///   - Single-* host wildcard ("https://*.margonem.pl") → echoes
        ///     request Origin if the wildcard slot contains no '/' and
        ///     head/tail match. The echoed value (NOT the pattern) keeps
        ///     credentialed requests working.
        public bool HandleCors(HttpListenerRequest request,
                                HttpListenerResponse response) {
            if (CorsOrigins == null || CorsOrigins.Count == 0) return false;
            string origin = request.Headers["Origin"];
            if (string.IsNullOrEmpty(origin)) return false;

            string allow = null;
            foreach (string pattern in CorsOrigins) {
                if (pattern == "*") { allow = "*"; break; }
                if (string.Equals(pattern, origin, StringComparison.OrdinalIgnoreCase)) {
                    allow = origin; break;
                }
                if (MatchesWildcard(pattern, origin)) { allow = origin; break; }
            }
            if (allow == null) return false;

            response.Headers.Add("Access-Control-Allow-Origin", allow);
            if (allow != "*") response.Headers.Add("Vary", "Origin");
            response.Headers.Add("Access-Control-Allow-Methods",
                "GET, POST, PUT, DELETE, OPTIONS");
            response.Headers.Add("Access-Control-Allow-Headers",
                "Authorization, Content-Type");
            response.Headers.Add("Access-Control-Expose-Headers",
                "ETag, X-Cache, WWW-Authenticate");
            if (allow != "*") response.Headers.Add("Access-Control-Allow-Credentials", "true");
            response.Headers.Add("Access-Control-Max-Age", "86400");
            return true;
        }

        private static bool MatchesWildcard(string pattern, string origin) {
            int star = pattern.IndexOf('*');
            if (star < 0) return false;
            string head = pattern.Substring(0, star);
            string tail = pattern.Substring(star + 1);
            if (!origin.StartsWith(head, StringComparison.OrdinalIgnoreCase)) return false;
            if (!origin.EndsWith(tail, StringComparison.OrdinalIgnoreCase))   return false;
            int wildLen = origin.Length - head.Length - tail.Length;
            if (wildLen < 1) return false;
            // The wildcard must not span a '/' (don't let *.margonem.pl
            // match https://evil.pl/.margonem.pl)
            string wild = origin.Substring(head.Length, wildLen);
            if (wild.IndexOf('/') >= 0) return false;
            return true;
        }

        /// Token bucket rate limiting per IP. Returns true if the request is
        /// allowed; false triggers HTTP 429 in ApiServer. Disabled when
        /// RateLimitPerSecond <= 0.
        public bool CheckRateLimit(string clientIp) {
            if (RateLimitPerSecond <= 0) return true; // disabled

            var bucket = _buckets.GetOrAdd(clientIp,
                _ => new TokenBucket(RateLimitBurst, RateLimitPerSecond));

            // Evict stale entries (>10 min since last request)
            if (bucket.IsStale) {
                _buckets.TryRemove(clientIp, out _);
                bucket = _buckets.GetOrAdd(clientIp,
                    _ => new TokenBucket(RateLimitBurst, RateLimitPerSecond));
            }

            return bucket.TryConsume();
        }

        /// Per-route, per-IP rate limit (WP-17). Bucket key is
        /// "{routeId}:{clientIp}" so routes have independent budgets.
        /// Capacity == perMinute; refill rate == perMinute / 60 tokens/sec.
        /// Returns true to allow, false to 429.
        public bool CheckRouteRateLimit(string clientIp, string routeId, int perMinute) {
            if (perMinute <= 0) return true;
            string key = routeId + ":" + clientIp;
            double refillPerSec = perMinute / 60.0;

            var bucket = _routeBuckets.GetOrAdd(key,
                _ => new TokenBucket(perMinute, refillPerSec));

            if (bucket.IsStale) {
                _routeBuckets.TryRemove(key, out _);
                bucket = _routeBuckets.GetOrAdd(key,
                    _ => new TokenBucket(perMinute, refillPerSec));
            }
            return bucket.TryConsume();
        }

        /// Constant-time string comparison to prevent timing side-channel attacks.
        /// Seeding diff with length XOR and iterating to max length avoids
        /// leaking token length via early return on mismatched lengths.
        public static bool FixedTimeEquals(string a, string b) {
            if (a == null || b == null) return false;
            int maxLen = Math.Max(a.Length, b.Length);
            int diff = a.Length ^ b.Length;
            for (int i = 0; i < maxLen; i++) {
                char ca = i < a.Length ? a[i] : '\0';
                char cb = i < b.Length ? b[i] : '\0';
                diff |= ca ^ cb;
            }
            return diff == 0;
        }

        /// Per-IP token bucket for rate limiting. Refills continuously based on
        /// elapsed time. Lock serializes Refill+TryConsume within a single bucket;
        /// different IPs are independent (ConcurrentDictionary in parent class).
        private sealed class TokenBucket {
            private double _tokens;
            private long _lastRefillTicks;
            private readonly int _capacity;
            private readonly double _refillRate;   // tokens/sec; double for sub-1/sec rates (per-route, WP-17)
            private readonly object _lock = new object();

            public TokenBucket(int capacity, double refillRate) {
                _capacity = capacity;
                _refillRate = refillRate;
                _tokens = capacity;
                _lastRefillTicks = DateTime.UtcNow.Ticks;
            }

            /// True when no requests have arrived for 10+ minutes — signals
            /// CheckRateLimit to evict and recreate the bucket.
            public bool IsStale =>
                (DateTime.UtcNow.Ticks - Interlocked.Read(ref _lastRefillTicks))
                    > TimeSpan.FromMinutes(10).Ticks;

            /// Refill based on elapsed time, then try to consume one token.
            /// Returns false when the bucket is empty (rate limit exceeded).
            public bool TryConsume() {
                lock (_lock) {
                    Refill();
                    if (_tokens < 1.0) return false;
                    _tokens -= 1.0;
                    return true;
                }
            }

            private void Refill() {
                long now = DateTime.UtcNow.Ticks;
                long last = _lastRefillTicks;
                double elapsed = (now - last) / (double)TimeSpan.TicksPerSecond;
                if (elapsed <= 0) return;

                _tokens = Math.Min(_capacity, _tokens + elapsed * _refillRate);
                _lastRefillTicks = now;
            }
        }
    }
}
