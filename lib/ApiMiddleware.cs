using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Net;
using System.Threading;

namespace Robot {
    /// Token metadata returned by authentication: display name, granted scopes,
    /// and ISO 8601 creation timestamp. Properties are mutable for PowerShell
    /// property-bag construction in New-RobotApiToken / api-token-helpers.ps1.
    public sealed class ApiTokenInfo {
        public string Name { get; set; }
        public string[] Scopes { get; set; }
        public string CreatedAt { get; set; }
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
        public string CorsOrigin { get; set; }
        public bool ReadOnly { get; set; }
        public int MaxRequestBody { get; set; } = 65536;    // 64 KB — sufficient for JSON entity payloads
        public int RateLimitPerSecond { get; set; } = 100; // refill rate per IP
        public int RateLimitBurst { get; set; } = 200;     // max burst capacity per IP

        private readonly ConcurrentDictionary<string, TokenBucket> _buckets =
            new ConcurrentDictionary<string, TokenBucket>();

        /// Authenticate request and return token info.
        /// Returns null if authentication fails (caller should 401).
        public ApiTokenInfo Authenticate(HttpListenerRequest request) {
            // Multi-token store (preferred)
            if (TokenStore != null && !TokenStore.IsEmpty) {
                string header = request.Headers["Authorization"];
                if (string.IsNullOrEmpty(header) ||
                    !header.StartsWith("Bearer ", StringComparison.Ordinal))
                    return null;
                return TokenStore.Authenticate(header.Substring(7));
            }

            // Open access (no auth configured)
            if (string.IsNullOrEmpty(AuthToken))
                return new ApiTokenInfo { Name = "_open", Scopes = new[] { "admin:all" } };

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

        /// Inject CORS headers if CorsOrigin is configured. Returns true if
        /// headers were added (caller should handle OPTIONS preflight separately).
        public bool HandleCors(HttpListenerRequest request,
                                HttpListenerResponse response) {
            if (string.IsNullOrEmpty(CorsOrigin)) return false;

            response.Headers.Add("Access-Control-Allow-Origin", CorsOrigin);
            response.Headers.Add("Access-Control-Allow-Methods",
                "GET, POST, PUT, DELETE, OPTIONS");
            response.Headers.Add("Access-Control-Allow-Headers",
                "Authorization, Content-Type");
            response.Headers.Add("Access-Control-Max-Age", "86400"); // 24 hours — preflight cache
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
            private readonly int _refillRate;
            private readonly object _lock = new object();

            public TokenBucket(int capacity, int refillRate) {
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
