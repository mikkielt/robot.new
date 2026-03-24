using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.IO;
using System.Net;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

namespace Robot {
    /// Async HTTP server backed by HttpListener with ThreadPool dispatch.
    /// Compiled C# because the accept loop, middleware pipeline, and response
    /// serialization all run on .NET thread pool threads — PowerShell cannot
    /// participate in async/await or ThreadPool dispatch efficiently.
    ///
    /// Request lifecycle:
    /// 1. AcceptLoopAsync receives connections and dispatches to ThreadPool
    /// 2. HandleRequestAsync runs the middleware pipeline (CORS, auth, rate limit)
    /// 2.5. Cacheable GET routes check the sidecar file cache (ResponseCache):
    ///      ETag match returns 304 Not Modified; sidecar HIT streams pre-serialized
    ///      JSON directly — both paths bypass the PowerShell RequestQueue entirely
    /// 3. Static routes (health, metrics, route listing) are handled entirely in
    ///    C# without touching the RequestQueue
    /// 4. Dynamic routes enqueue an ApiRequest with a TaskCompletionSource and
    ///    await the result set by a PowerShell RunspacePool worker (api-worker.ps1)
    ///
    /// Thread safety: _requestCount uses Interlocked. CacheVersion is a shared
    /// static monotonic counter incremented by write handlers (via api-worker.ps1)
    /// and checked by read handlers for cross-runspace cache invalidation.
    /// ResponseCache and RepoRoot are static fields set once at startup by
    /// Start-RobotApi, shared across all runspaces like CacheVersion.
    /// Properties (_router, _middleware) are set once in Start() before any HTTP
    /// threads begin.
    ///
    /// Consumers: Start-RobotApi (creates instance, calls Start/Stop),
    ///            api-worker.ps1 (dequeues from RequestQueue, sets CacheVersion),
    ///            api-handlers-write.ps1 (sidecar invalidation via ResponseCache),
    ///            Get-RobotApiStatus (reads GetStatus and CacheVersion)
    public sealed class ApiServer : IDisposable {
        private static readonly UTF8Encoding Utf8NoBom = new UTF8Encoding(false);
        private HttpListener _listener;
        private CancellationTokenSource _cts;
        private ApiRouter _router;
        private ApiMiddleware _middleware;
        private ApiSseManager _sseManager;
        private Task _acceptTask;

        private long _requestCount;
        private DateTime _startedAt;
        private bool _isRunning;

        /// Thread-safe request queue bridging C# HTTP threads to PowerShell
        /// workers. Bounded capacity (default 512) prevents memory exhaustion —
        /// TryAdd with timeout returns false when full, triggering HTTP 503.
        public BlockingCollection<ApiRequest> RequestQueue { get; private set; }

        /// Monotonic cache version counter shared across all threads/runspaces.
        /// Write handlers increment via Interlocked.Increment; read workers
        /// compare against their local snapshot to trigger Clear-ParseCaches
        /// when stale. Static field because RunspacePool workers each get
        /// their own ApiServer reference but must share cache state.
        public static long CacheVersion;

        /// Static response cache shared across all threads and runspaces.
        /// Static for the same reason as CacheVersion — worker runspaces are
        /// isolated and cannot access instance fields via $script: variables.
        /// Set by Start-RobotApi after server start.
        public static ApiResponseCache ResponseCache;

        /// Repository root path. Set by Start-RobotApi.ps1 after server start.
        /// Used by the response cache to compute domain fingerprints.
        public static string RepoRoot;

        public bool IsRunning => _isRunning;
        public long RequestCount => Interlocked.Read(ref _requestCount);
        public DateTime StartedAt => _startedAt;

        /// Start the HTTP listener on the given prefix (e.g. "http://localhost:8642/api/").
        /// Throws InvalidOperationException if already running. Spawns AcceptLoopAsync
        /// on the ThreadPool. router: precompiled route table from api-routes.ps1.
        /// middleware: auth/CORS/rate-limit config. boundedCapacity: max queued
        /// requests before backpressure (HTTP 503).
        public void Start(string prefix, ApiRouter router, ApiMiddleware middleware,
                          int boundedCapacity = 512) {
            if (_isRunning) throw new InvalidOperationException("Server already running");

            _router = router;
            _middleware = middleware;
            _sseManager = new ApiSseManager();
            RequestQueue = new BlockingCollection<ApiRequest>(boundedCapacity);
            _cts = new CancellationTokenSource();

            _listener = new HttpListener();
            _listener.Prefixes.Add(prefix);
            _listener.Start();

            _isRunning = true;
            _startedAt = DateTime.UtcNow;
            Interlocked.Exchange(ref _requestCount, 0);

            // Accept loop on dedicated thread pool task
            _acceptTask = Task.Run(() => AcceptLoopAsync(_cts.Token));
        }

        /// Graceful shutdown: cancel accept loop, drain queue (CompleteAdding),
        /// disconnect SSE clients, and close the listener. 5-second timeout on
        /// accept task prevents indefinite blocking on shutdown.
        public void Stop() {
            if (!_isRunning) return;
            _isRunning = false;
            _cts.Cancel();
            _listener.Stop();
            RequestQueue.CompleteAdding();
            _sseManager.DisconnectAll();
            try { _acceptTask?.Wait(TimeSpan.FromSeconds(5)); } catch { }
            _listener.Close();
        }

        /// SSE manager for event broadcasting. Plugin hooks call
        /// SseManager.BroadcastAsync to push entity/session change events.
        public ApiSseManager SseManager => _sseManager;

        /// Server status snapshot for Get-RobotApiStatus. Returns a dictionary
        /// with isRunning, requestCount, startedAt, uptimeSeconds, queuedRequests,
        /// sseClients, and cacheVersion.
        public Dictionary<string, object> GetStatus() {
            return new Dictionary<string, object>(StringComparer.OrdinalIgnoreCase) {
                ["isRunning"]    = _isRunning,
                ["requestCount"] = Interlocked.Read(ref _requestCount),
                ["startedAt"]    = _startedAt.ToString("o"),
                ["uptimeSeconds"] = _isRunning
                    ? (DateTime.UtcNow - _startedAt).TotalSeconds : 0,
                ["queuedRequests"] = RequestQueue?.Count ?? 0,
                ["sseClients"]   = _sseManager?.ClientCount ?? 0,
                ["cacheVersion"] = Interlocked.Read(ref CacheVersion)
            };
        }

        private async Task AcceptLoopAsync(CancellationToken ct) {
            while (!ct.IsCancellationRequested) {
                HttpListenerContext context;
                try {
                    context = await _listener.GetContextAsync().ConfigureAwait(false);
                } catch (HttpListenerException) {
                    break; // Listener stopped
                } catch (ObjectDisposedException) {
                    break;
                }

                Interlocked.Increment(ref _requestCount);

                // Dispatch to thread pool — don't block the accept loop
                _ = Task.Run(() => HandleRequestAsync(context, ct), ct);
            }
        }

        private async Task HandleRequestAsync(HttpListenerContext context, CancellationToken ct) {
            var request = context.Request;
            var response = context.Response;

            try {
                // ── Middleware pipeline (all C#, no PS overhead) ─────
                // CORS preflight
                if (_middleware.HandleCors(request, response)) {
                    if (request.HttpMethod == "OPTIONS") {
                        response.StatusCode = 204;
                        response.Close();
                        return;
                    }
                }

                // Auth — returns token info (null = unauthorized)
                var tokenInfo = _middleware.Authenticate(request);
                if (tokenInfo == null) {
                    ApiSerializer.WriteError(response, 401, "Unauthorized");
                    return;
                }

                // Rate limit
                string clientIp = request.RemoteEndPoint?.Address?.ToString() ?? "unknown";
                if (!_middleware.CheckRateLimit(clientIp)) {
                    response.Headers.Add("Retry-After", "1");
                    ApiSerializer.WriteError(response, 429, "Rate limit exceeded");
                    return;
                }

                // ── Route matching (C#) ─────────────────────────────
                string path = request.Url.AbsolutePath;
                // Strip /api prefix — routes are registered without it
                if (path.StartsWith("/api", StringComparison.OrdinalIgnoreCase))
                    path = path.Substring(4);
                if (path.Length == 0) path = "/";

                var match = _router.Match(request.HttpMethod, path);
                if (match == null) {
                    ApiSerializer.WriteError(response, 404,
                        "Route not found: " + request.HttpMethod + " " + path);
                    return;
                }

                // Scope enforcement — check token scopes against route requirement
                if (match.Route.RequiredScope != null &&
                    !ApiMiddleware.HasScope(tokenInfo, match.Route.RequiredScope)) {
                    ApiSerializer.WriteError(response, 403, "Forbidden");
                    return;
                }

                // Read-only mode blocks write methods
                if (_middleware.ReadOnly &&
                    (request.HttpMethod == "POST" || request.HttpMethod == "PUT" ||
                     request.HttpMethod == "DELETE")) {
                    ApiSerializer.WriteError(response, 403, "API is in read-only mode");
                    return;
                }

                // ── SSE endpoint ────────────────────────────────────
                if (match.Route.IsSse) {
                    _sseManager.AddClient(response);
                    return; // Response kept open for streaming
                }

                // ── Static C# handler (no PS) ───────────────────────
                if (match.Route.StaticHandler != null) {
                    var staticResult = match.Route.StaticHandler(match, this);
                    ApiSerializer.WriteObject(response, staticResult,
                        match.Route.StatusCode);
                    return;
                }

                // ── Response cache intercept (sidecar check) ────────
                var cache = ResponseCache;
                string repoRoot = RepoRoot;
                bool isCacheable = match.Route.CacheKey != null
                    && cache != null && repoRoot != null
                    && request.HttpMethod == "GET"
                    && request.QueryString.Count == 0;

                if (isCacheable) {
                    cache.RefreshFingerprints(repoRoot);
                    string etag = cache.BuildETag(match.Route.CacheDomains);

                    // ETag / 304 Not Modified
                    string ifNoneMatch = request.Headers["If-None-Match"];
                    if (ifNoneMatch != null && ifNoneMatch.Trim('"') == etag) {
                        response.StatusCode = 304;
                        response.Close();
                        return;
                    }

                    // Sidecar hit — stream cached JSON directly (no PS overhead)
                    if (cache.TryLoad(match.Route.CacheKey,
                            match.Route.CacheDomains, out byte[] cachedJson,
                            out string cachedEtag)) {
                        response.StatusCode = match.Route.StatusCode;
                        response.ContentType = "application/json; charset=utf-8";
                        response.Headers.Add("ETag", "\"" + cachedEtag + "\"");
                        response.Headers.Add("X-Cache", "HIT");
                        response.ContentLength64 = cachedJson.Length;
                        response.OutputStream.Write(cachedJson, 0, cachedJson.Length);
                        return;
                    }
                }

                // ── Dynamic PS handler: enqueue to worker pool ──────
                // Content-Type validation for requests with entity body
                if (request.HasEntityBody) {
                    string contentType = request.ContentType;
                    if (contentType == null || !contentType.StartsWith("application/json",
                            StringComparison.OrdinalIgnoreCase)) {
                        ApiSerializer.WriteError(response, 415,
                            "Content-Type must be application/json");
                        return;
                    }
                }

                // Parse body for POST/PUT
                byte[] bodyBytes = null;
                if (request.HasEntityBody) {
                    using (var ms = new System.IO.MemoryStream()) {
                        await request.InputStream.CopyToAsync(ms).ConfigureAwait(false);
                        bodyBytes = ms.ToArray();
                    }
                    if (bodyBytes.Length > _middleware.MaxRequestBody) {
                        ApiSerializer.WriteError(response, 413, "Request body too large");
                        return;
                    }
                }

                var apiRequest = new ApiRequest {
                    RouteId       = match.Route.Id,
                    HandlerName   = match.Route.HandlerName,
                    Method        = request.HttpMethod,
                    Path          = path,
                    PathParams    = match.PathParams,
                    QueryParams   = ParseQueryString(request.QueryString),
                    BodyBytes     = bodyBytes,
                    TokenName     = tokenInfo.Name,
                    TokenScopes   = tokenInfo.Scopes,
                    ResponseSource = new TaskCompletionSource<ApiResponse>(
                        TaskCreationOptions.RunContinuationsAsynchronously)
                };

                // Enqueue with 5s timeout — fails fast when queue is full
                if (!RequestQueue.TryAdd(apiRequest, TimeSpan.FromSeconds(5))) {
                    ApiSerializer.WriteError(response, 503,
                        "Server overloaded — request queue full");
                    return;
                }

                // Await PS worker result — 60s timeout prevents leaked requests
                var completedTask = await Task.WhenAny(
                    apiRequest.ResponseSource.Task,
                    Task.Delay(TimeSpan.FromSeconds(60), ct)
                ).ConfigureAwait(false);

                if (completedTask != apiRequest.ResponseSource.Task) {
                    ApiSerializer.WriteError(response, 504, "Handler timeout (60s)");
                    return;
                }

                var apiResponse = await apiRequest.ResponseSource.Task.ConfigureAwait(false);

                // Sidecar write: for cacheable routes with successful responses,
                // serialize via ApiSerializer.SerializeToBytes to guarantee byte-level
                // equality between cached and fresh responses (addresses V-5).
                byte[] sidecarBytes = null;
                bool shouldCache = isCacheable && apiResponse.StatusCode == 200
                    && apiResponse.RawBody == null;

                // Serialize response — three paths: raw bytes, raw JSON, or object
                if (apiResponse.RawBody != null) {
                    // Opaque byte payload (HTML, images, etc.) with explicit content type
                    response.StatusCode = apiResponse.StatusCode;
                    response.ContentType = apiResponse.ContentType ?? "application/octet-stream";
                    response.ContentLength64 = apiResponse.RawBody.Length;
                    response.OutputStream.Write(apiResponse.RawBody, 0, apiResponse.RawBody.Length);
                } else if (apiResponse.RawJson != null) {
                    // Pre-serialized JSON from PS handler
                    ApiSerializer.WriteRaw(response, apiResponse.RawJson,
                        apiResponse.StatusCode);
                    if (shouldCache) {
                        sidecarBytes = Utf8NoBom.GetBytes(apiResponse.RawJson);
                    }
                } else {
                    if (shouldCache) {
                        // Serialize to bytes first, then write to response + sidecar
                        sidecarBytes = ApiSerializer.SerializeToBytes(
                            apiResponse.Body, apiResponse.IncludeLabels);
                        response.StatusCode = apiResponse.StatusCode;
                        response.ContentType = "application/json; charset=utf-8";
                        response.ContentLength64 = sidecarBytes.Length;
                        response.OutputStream.Write(sidecarBytes, 0, sidecarBytes.Length);
                    } else {
                        ApiSerializer.WriteObject(response, apiResponse.Body,
                            apiResponse.StatusCode, apiResponse.IncludeLabels);
                    }
                }

                // ETag + sidecar persistence for cacheable route misses
                if (shouldCache && cache != null && sidecarBytes != null) {
                    string missEtag = cache.BuildETag(match.Route.CacheDomains);
                    response.Headers.Add("ETag", "\"" + missEtag + "\"");
                    response.Headers.Add("X-Cache", "MISS");
                    cache.Save(match.Route.CacheKey,
                        match.Route.CacheDomains, sidecarBytes);
                }

            } catch (Exception ex) {
                try {
                    ApiSerializer.WriteError(response, 500, ex.Message);
                } catch { }
            } finally {
                try { response.Close(); } catch { }
            }
        }

        /// Convert NameValueCollection query string to Dictionary for PowerShell
        /// consumption. Null keys (from malformed query strings) are skipped.
        private static Dictionary<string, string> ParseQueryString(
            System.Collections.Specialized.NameValueCollection qs) {
            var dict = new Dictionary<string, string>(
                qs.Count, StringComparer.OrdinalIgnoreCase);
            foreach (string key in qs.AllKeys) {
                if (key != null) dict[key] = qs[key];
            }
            return dict;
        }

        public void Dispose() {
            Stop();
            RequestQueue?.Dispose();
            _cts?.Dispose();
        }
    }

    /// Request object bridging C# HTTP thread to PowerShell RunspacePool worker.
    /// Enqueued into ApiServer.RequestQueue by HandleRequestAsync. The PS worker
    /// (api-worker.ps1) dequeues, invokes the handler, and sets ResponseSource
    /// to unblock the waiting HTTP thread. TokenName carries the authenticated
    /// identity for handler-level audit logging.
    public sealed class ApiRequest {
        public string RouteId { get; set; }
        public string HandlerName { get; set; }
        public string Method { get; set; }
        public string Path { get; set; }
        public Dictionary<string, string> PathParams { get; set; }
        public Dictionary<string, string> QueryParams { get; set; }
        public byte[] BodyBytes { get; set; }
        public string TokenName { get; set; }
        public string[] TokenScopes { get; set; }
        public TaskCompletionSource<ApiResponse> ResponseSource { get; set; }
    }

    /// Response from PowerShell handler back to C# HTTP thread. Set on the
    /// TaskCompletionSource by api-worker.ps1 after handler execution.
    /// Three serialization paths: RawBody (opaque bytes with explicit ContentType,
    /// e.g. HTML), RawJson (pre-serialized JSON string), or Body (object
    /// serialized by ApiSerializer).
    public sealed class ApiResponse {
        public int StatusCode { get; set; }
        public object Body { get; set; }        // hashtable/PSObject — serialized by ApiSerializer
        public string RawJson { get; set; }     // pre-serialized JSON string (bypasses ApiSerializer)
        public bool IncludeLabels { get; set; } // inject *Label companion fields via ApiNameDictionary
        public string ContentType { get; set; } // null = default application/json
        public byte[] RawBody { get; set; }     // null = use Body + serializer
    }
}
