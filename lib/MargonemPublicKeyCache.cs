using System;
using System.IO;
using System.Security.Cryptography;
using System.Text;
using System.Threading;

namespace Robot {
    /// Caches the Margonem account-signing RSA public key. The key is
    /// loaded once at Start-RobotApi time from a PEM file on disk
    /// (X.509 SubjectPublicKeyInfo, "-----BEGIN PUBLIC KEY-----" header).
    ///
    /// Operators refresh the key by POSTing to /auth/margonem/refresh-key
    /// (handler: Invoke-ApiRefreshMargonemKey), which fetches the upstream
    /// PEM, validates it, atomically swaps the on-disk file, and calls
    /// Load(path) again. The server itself NEVER fetches the key from
    /// upstream on the request hot path.
    ///
    /// Thread safety: _key is published via Interlocked.Exchange because Load
    /// may be invoked concurrently with verification on HTTP threads. Verification
    /// reads the reference once, so a torn read is impossible (object references
    /// are atomically read/written on all .NET target platforms).
    ///
    /// Consumers: MargonemValidator (request-time verify),
    ///            Invoke-ApiRefreshMargonemKey (operator refresh),
    ///            Invoke-ApiGetMargonemHealth (status probe),
    ///            Invoke-ApiGetMargonemInfo (public discovery).
    public static class MargonemPublicKeyCache {
        private static RSA _key;
        private static DateTime _loadedAt;
        private static string _loadedFromPath;

        public static bool IsLoaded => _key != null;
        public static DateTime LoadedAt => _loadedAt;
        public static string LoadedFromPath => _loadedFromPath;

        /// Load (or reload) the public key from a PEM file. Throws on
        /// missing file, malformed PEM, or unsupported key encoding —
        /// the caller (Start-RobotApi or /auth/margonem/refresh-key)
        /// decides whether to fail-closed or warn-and-degrade.
        ///
        /// Accepts both X.509 SubjectPublicKeyInfo ("BEGIN PUBLIC KEY")
        /// and PKCS#1 ("BEGIN RSA PUBLIC KEY") — ImportFromPem dispatches.
        public static void Load(string pemPath) {
            if (string.IsNullOrEmpty(pemPath))
                throw new ArgumentNullException("pemPath");
            if (!File.Exists(pemPath))
                throw new FileNotFoundException(
                    "Margonem public key not found", pemPath);

            string pem = File.ReadAllText(pemPath, Encoding.UTF8);
            var rsa = RSA.Create();
            try {
                rsa.ImportFromPem(pem);
            } catch {
                rsa.Dispose();
                throw;
            }

            var prev = Interlocked.Exchange(ref _key, rsa);
            _loadedAt = DateTime.UtcNow;
            _loadedFromPath = pemPath;
            if (prev != null) prev.Dispose();
        }

        /// Returns the loaded key reference for verification. Returns null
        /// if Load has not been called — the verifier MUST treat null as
        /// fail-closed (no signature can be verified without a key).
        public static RSA GetKey() {
            return _key;
        }

        /// Reset to unloaded state. Used by tests; not exposed via API.
        public static void Reset() {
            var prev = Interlocked.Exchange(ref _key, null);
            if (prev != null) prev.Dispose();
            _loadedAt = default(DateTime);
            _loadedFromPath = null;
        }
    }
}
