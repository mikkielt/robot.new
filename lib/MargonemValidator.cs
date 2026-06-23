using System;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace Robot {
    /// Result of validating a Margonem signed payload. Sealed value object;
    /// IsValid is the discriminator — when false, FailureReason explains why.
    /// Mutable for property-bag construction; consumers should treat it as
    /// immutable after Validate returns.
    public sealed class MargonemValidationResult {
        public bool   IsValid       { get; set; }
        public long   UserId        { get; set; }
        public string Token         { get; set; }   // Margonem session token (opaque)
        public long   Timestamp     { get; set; }   // unix seconds, as supplied
        public string FailureReason { get; set; }   // null on success
    }

    /// Stateless verifier for Margonem /account/validate response payloads.
    /// Compiled C# because (a) every authentication request runs an RSA
    /// verify on the hot path and (b) the freshness check must use a
    /// single canonical clock (DateTimeOffset.UtcNow) — keeping it in C#
    /// avoids PowerShell timezone gotchas.
    ///
    /// Algorithm: RSA-SHA256 with PKCS#1 v1.5 padding — confirmed against
    /// real Margonem validation responses.
    ///
    /// Consumers: Invoke-ApiAuthMargonem (mint),
    ///            Invoke-ApiVerifyMargonem (cross-service verify).
    public static class MargonemValidator {
        /// Maximum allowed clock skew between Margonem-supplied ts and
        /// server UTC. Defends against replay of stale signed payloads
        /// while tolerating reasonable client/server clock drift.
        public const int DefaultFreshnessSeconds = 300;

        /// Validate a raw payload (the JSON string returned by
        /// public-api.margonem.pl/account/validate). The caller forwards
        /// the response verbatim; this method handles parsing, field
        /// extraction, reconstruction, signature verification, and
        /// freshness enforcement.
        ///
        /// Critically: the validatedString field in the payload is IGNORED.
        /// The validator reconstructs it from user_id+token+ts to defeat
        /// an attacker swapping components while keeping the original
        /// signature.
        public static MargonemValidationResult Validate(string payloadJson,
                                                        int freshnessSeconds) {
            if (string.IsNullOrWhiteSpace(payloadJson))
                return Fail("payload is empty");

            long userId; string token; long ts; string signatureB64;
            try {
                using (var doc = JsonDocument.Parse(payloadJson)) {
                    var root = doc.RootElement;
                    if (!root.TryGetProperty("user_id", out var uidEl) ||
                        !root.TryGetProperty("token",   out var tokEl) ||
                        !root.TryGetProperty("ts",      out var tsEl)  ||
                        !root.TryGetProperty("signatureBase64", out var sigEl))
                        return Fail("payload missing required fields");

                    userId       = uidEl.GetInt64();
                    token        = tokEl.GetString();
                    ts           = tsEl.GetInt64();
                    signatureB64 = sigEl.GetString();
                }
            } catch (JsonException) {
                return Fail("payload is not valid JSON");
            } catch (InvalidOperationException) {
                return Fail("payload field types are wrong");
            } catch (FormatException) {
                return Fail("payload field types are wrong");
            }

            if (string.IsNullOrEmpty(token))
                return Fail("token field is empty");
            if (string.IsNullOrEmpty(signatureB64))
                return Fail("signatureBase64 field is empty");

            // Freshness — anti-replay
            long nowUnix = DateTimeOffset.UtcNow.ToUnixTimeSeconds();
            long skew = Math.Abs(nowUnix - ts);
            if (skew > freshnessSeconds)
                return Fail("timestamp skew " + skew + "s exceeds limit " +
                            freshnessSeconds + "s");

            // Reconstruct validatedString — DO NOT trust the supplied one
            string reconstructed = userId.ToString() + "+" + token + "+" + ts.ToString();
            byte[] data = Encoding.UTF8.GetBytes(reconstructed);

            byte[] signature;
            try {
                signature = Convert.FromBase64String(signatureB64);
            } catch (FormatException) {
                return Fail("signatureBase64 is not valid base64");
            }

            RSA key = MargonemPublicKeyCache.GetKey();
            if (key == null)
                return Fail("Margonem public key is not loaded");

            bool ok;
            try {
                ok = key.VerifyData(data, signature,
                    HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
            } catch (CryptographicException) {
                return Fail("signature verification raised cryptographic error");
            }
            if (!ok)
                return Fail("signature does not verify");

            return new MargonemValidationResult {
                IsValid   = true,
                UserId    = userId,
                Token     = token,
                Timestamp = ts
            };
        }

        private static MargonemValidationResult Fail(string reason) {
            return new MargonemValidationResult {
                IsValid = false, FailureReason = reason
            };
        }
    }
}
