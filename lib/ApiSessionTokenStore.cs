using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Threading;

namespace Robot {
    /// In-memory store of short-lived, identity-bound bearer tokens minted
    /// after Margonem session verification (see Invoke-ApiAuthMargonem).
    /// Independent of ApiTokenStore because (a) entries expire and
    /// (b) every entry is bound to a Player.
    ///
    /// Eviction policy:
    ///   - Per-call: an expired entry encountered during Authenticate is
    ///     removed in-line and the call returns null.
    ///   - Amortised sweep: every SweepInterval Authenticate calls, scan
    ///     all entries and remove expired ones. Avoids a background timer.
    ///   - Capacity guard: when Count >= MaxEntries, the oldest entry
    ///     (lowest CreatedAtTicks) is evicted on the next Add.
    ///
    /// Thread safety: backed by ConcurrentDictionary plus an Interlocked
    /// sweep counter. Add and Authenticate are lock-free in the fast path;
    /// EvictOldest takes O(N) but only fires when over capacity.
    ///
    /// Consumers: ApiMiddleware.Authenticate (request-time lookup),
    ///            Invoke-ApiAuthMargonem (Add after mint),
    ///            Invoke-ApiGetAuthSessions (operator list),
    ///            Invoke-ApiRevokePlayerSessions (operator revoke).
    public sealed class ApiSessionTokenStore {
        private readonly ConcurrentDictionary<string, ApiTokenInfo> _tokens
            = new ConcurrentDictionary<string, ApiTokenInfo>(StringComparer.Ordinal);

        private long _sweepCounter;

        public int SweepInterval { get; set; } = 1000;
        public int MaxEntries    { get; set; } = 10000;

        public int Count => _tokens.Count;

        /// Add a new session token. Returns false if the token string
        /// already exists (collision — astronomically unlikely with a
        /// 32-byte RNG, but the contract mirrors ApiTokenStore.Add).
        public bool Add(string token, ApiTokenInfo info) {
            if (_tokens.Count >= MaxEntries) EvictOldest();
            return _tokens.TryAdd(token, info);
        }

        /// O(N) scan with FixedTimeEquals per token (constant-time wrt.
        /// matching), plus inline expiry removal. Returns null when:
        ///   - bearerToken is missing / not found
        ///   - matched token has expired (entry removed)
        public ApiTokenInfo Authenticate(string bearerToken) {
            if (string.IsNullOrEmpty(bearerToken)) return null;
            MaybeSweep();

            ApiTokenInfo matched = null;
            string matchedKey = null;
            foreach (var kvp in _tokens) {
                if (ApiMiddleware.FixedTimeEquals(kvp.Key, bearerToken)) {
                    matched = kvp.Value;
                    matchedKey = kvp.Key;
                }
            }
            if (matched == null) return null;

            if (matched.ExpiresAt != null
                && DateTimeOffset.UtcNow >= matched.ExpiresAt.Value) {
                _tokens.TryRemove(matchedKey, out _);
                return null;
            }
            return matched;
        }

        /// Remove all tokens issued for a given PlayerName. Used by
        /// /auth/sessions/:player and by the Gracze.md write hook.
        /// Returns the number of tokens removed.
        public int RemoveByPlayer(string playerName) {
            int removed = 0;
            foreach (var kvp in _tokens) {
                if (string.Equals(kvp.Value.PlayerName, playerName,
                        StringComparison.OrdinalIgnoreCase)) {
                    if (_tokens.TryRemove(kvp.Key, out _)) removed++;
                }
            }
            return removed;
        }

        /// Metadata listing for /auth/sessions. Returns no raw token values.
        public List<Dictionary<string, object>> ListSessions() {
            var result = new List<Dictionary<string, object>>();
            foreach (var kvp in _tokens) {
                var info = kvp.Value;
                result.Add(new Dictionary<string, object> {
                    ["name"]           = info.Name,
                    ["player"]         = info.PlayerName,
                    ["margonemUserId"] = info.MargonemUserId,
                    ["scopes"]         = info.Scopes,
                    ["createdAt"]      = info.CreatedAt,
                    ["expiresAt"]      = info.ExpiresAt != null
                        ? info.ExpiresAt.Value.ToString("o") : null
                });
            }
            return result;
        }

        public void Clear() { _tokens.Clear(); }

        private void MaybeSweep() {
            long n = Interlocked.Increment(ref _sweepCounter);
            if (SweepInterval <= 0 || n % SweepInterval != 0) return;
            var now = DateTimeOffset.UtcNow;
            foreach (var kvp in _tokens) {
                if (kvp.Value.ExpiresAt != null
                    && now >= kvp.Value.ExpiresAt.Value) {
                    _tokens.TryRemove(kvp.Key, out _);
                }
            }
        }

        private void EvictOldest() {
            string oldestKey = null;
            long oldestTicks = long.MaxValue;
            foreach (var kvp in _tokens) {
                long t = kvp.Value.CreatedAtTicks;
                if (t < oldestTicks) { oldestTicks = t; oldestKey = kvp.Key; }
            }
            if (oldestKey != null) _tokens.TryRemove(oldestKey, out _);
        }
    }
}
