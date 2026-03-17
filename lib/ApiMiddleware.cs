using System;
using System.Collections.Concurrent;
using System.Net;
using System.Threading;

namespace Robot {
    /// HTTP middleware pipeline: authentication, CORS, rate limiting, request
    /// size enforcement. All checks are compiled C# — zero PowerShell overhead
    /// per request.
    ///
    /// Rate limiter uses a per-IP token bucket with configurable capacity and
    /// refill rate. ConcurrentDictionary provides lock-free per-IP state.
    /// Stale entries (no requests for 10 minutes) are evicted on access.
    ///
    /// Auth supports Bearer token (constant-time comparison via FixedTimeEquals
    /// to prevent timing attacks).
    ///
    /// Consumers: ApiServer.HandleRequestAsync (middleware chain)
    public sealed class ApiMiddleware {
        public string AuthToken { get; set; }
        public string CorsOrigin { get; set; }
        public bool ReadOnly { get; set; }
        public int MaxRequestBody { get; set; } = 65536;
        public int RateLimitPerSecond { get; set; } = 100;
        public int RateLimitBurst { get; set; } = 200;

        private readonly ConcurrentDictionary<string, TokenBucket> _buckets =
            new ConcurrentDictionary<string, TokenBucket>();

        /// Check Bearer token. Returns true if auth passes.
        /// Null/empty AuthToken = open access (no auth required).
        public bool CheckAuth(HttpListenerRequest request) {
            if (string.IsNullOrEmpty(AuthToken)) return true;

            string header = request.Headers["Authorization"];
            if (string.IsNullOrEmpty(header)) return false;

            if (!header.StartsWith("Bearer ", StringComparison.Ordinal))
                return false;

            string token = header.Substring(7);
            return FixedTimeEquals(token, AuthToken);
        }

        /// Inject CORS headers. Returns true if headers were added.
        public bool HandleCors(HttpListenerRequest request,
                                HttpListenerResponse response) {
            if (string.IsNullOrEmpty(CorsOrigin)) return false;

            response.Headers.Add("Access-Control-Allow-Origin", CorsOrigin);
            response.Headers.Add("Access-Control-Allow-Methods",
                "GET, POST, PUT, DELETE, OPTIONS");
            response.Headers.Add("Access-Control-Allow-Headers",
                "Authorization, Content-Type");
            response.Headers.Add("Access-Control-Max-Age", "86400");
            return true;
        }

        /// Token bucket rate limiting per IP. Returns true if request is allowed.
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
        private static bool FixedTimeEquals(string a, string b) {
            if (a == null || b == null) return false;
            if (a.Length != b.Length) return false;
            int diff = 0;
            for (int i = 0; i < a.Length; i++)
                diff |= a[i] ^ b[i];
            return diff == 0;
        }

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

            public bool IsStale =>
                (DateTime.UtcNow.Ticks - Interlocked.Read(ref _lastRefillTicks))
                    > TimeSpan.FromMinutes(10).Ticks;

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
