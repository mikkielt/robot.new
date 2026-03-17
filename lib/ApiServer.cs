using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Net;
using System.Threading;
using System.Threading.Tasks;

namespace Robot {
    /// Async HTTP server backed by HttpListener with ThreadPool dispatch.
    ///
    /// Lifecycle: Start() begins accepting connections; Stop() gracefully
    /// drains in-flight requests. RequestQueue bridges C# HTTP threads to
    /// PowerShell RunspacePool workers via BlockingCollection + TaskCompletionSource.
    ///
    /// Static routes (health, metrics, route listing) are handled entirely in C#
    /// without touching the RequestQueue. Dynamic routes enqueue an ApiRequest
    /// and await the TaskCompletionSource set by the PowerShell worker.
    ///
    /// Thread safety: _requestCount uses Interlocked. CacheVersion is a shared
    /// monotonic counter incremented by write handlers and checked by read handlers
    /// for cross-runspace cache invalidation.
    ///
    /// Consumers: Start-RobotApi (plugins/robot-api/public/Start-RobotApi.ps1)
    public sealed class ApiServer : IDisposable {
        private HttpListener _listener;
        private CancellationTokenSource _cts;
        private ApiRouter _router;
        private ApiMiddleware _middleware;
        private ApiSseManager _sseManager;
        private Task _acceptTask;

        private long _requestCount;
        private DateTime _startedAt;
        private bool _isRunning;

        /// Thread-safe request queue for PowerShell worker consumption.
        /// Bounded capacity prevents memory exhaustion under load.
        public BlockingCollection<ApiRequest> RequestQueue { get; private set; }

        /// Monotonic cache version counter. Incremented after writes;
        /// read workers compare against their local version to trigger
        /// Clear-ParseCaches. Uses Interlocked for lock-free cross-thread access.
        public static long CacheVersion;

        public bool IsRunning => _isRunning;
        public long RequestCount => Interlocked.Read(ref _requestCount);
        public DateTime StartedAt => _startedAt;

        /// Start the HTTP listener on the given prefix (e.g. "http://localhost:8642/api/").
        /// router: compiled route table. middleware: auth/CORS/rate-limit config.
        /// boundedCapacity: max queued requests before backpressure (HTTP 503).
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

        /// Graceful shutdown: stop accepting, drain queue, close listener.
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

        /// SSE manager for event broadcasting from plugin hooks.
        public ApiSseManager SseManager => _sseManager;

        /// Server status snapshot for Get-RobotApiStatus.
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
                // ── Middleware pipeline (all C#, no PS) ──────────────
                // CORS preflight
                if (_middleware.HandleCors(request, response)) {
                    if (request.HttpMethod == "OPTIONS") {
                        response.StatusCode = 204;
                        response.Close();
                        return;
                    }
                }

                // Auth
                if (!_middleware.CheckAuth(request)) {
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
                // Strip /api prefix for routing
                if (path.StartsWith("/api", StringComparison.OrdinalIgnoreCase))
                    path = path.Substring(4);
                if (path.Length == 0) path = "/";

                var match = _router.Match(request.HttpMethod, path);
                if (match == null) {
                    ApiSerializer.WriteError(response, 404,
                        "Route not found: " + request.HttpMethod + " " + path);
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

                // ── Dynamic PS handler: enqueue to worker pool ──────
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
                    ResponseSource = new TaskCompletionSource<ApiResponse>(
                        TaskCreationOptions.RunContinuationsAsynchronously)
                };

                // Enqueue with timeout to prevent indefinite blocking
                if (!RequestQueue.TryAdd(apiRequest, TimeSpan.FromSeconds(5))) {
                    ApiSerializer.WriteError(response, 503,
                        "Server overloaded — request queue full");
                    return;
                }

                // Await PS worker result with timeout
                var completedTask = await Task.WhenAny(
                    apiRequest.ResponseSource.Task,
                    Task.Delay(TimeSpan.FromSeconds(60), ct)
                ).ConfigureAwait(false);

                if (completedTask != apiRequest.ResponseSource.Task) {
                    ApiSerializer.WriteError(response, 504, "Handler timeout (60s)");
                    return;
                }

                var apiResponse = await apiRequest.ResponseSource.Task.ConfigureAwait(false);

                // Serialize response
                if (apiResponse.RawJson != null) {
                    // Pre-serialized JSON from PS handler
                    ApiSerializer.WriteRaw(response, apiResponse.RawJson,
                        apiResponse.StatusCode);
                } else {
                    ApiSerializer.WriteObject(response, apiResponse.Body,
                        apiResponse.StatusCode, apiResponse.IncludeLabels);
                }

            } catch (Exception ex) {
                try {
                    ApiSerializer.WriteError(response, 500, ex.Message);
                } catch { }
            } finally {
                try { response.Close(); } catch { }
            }
        }

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

    /// Request object bridging C# HTTP thread to PowerShell worker.
    /// TaskCompletionSource allows the HTTP thread to await the PS result.
    public sealed class ApiRequest {
        public string RouteId { get; set; }
        public string HandlerName { get; set; }
        public string Method { get; set; }
        public string Path { get; set; }
        public Dictionary<string, string> PathParams { get; set; }
        public Dictionary<string, string> QueryParams { get; set; }
        public byte[] BodyBytes { get; set; }
        public TaskCompletionSource<ApiResponse> ResponseSource { get; set; }
    }

    /// Response from PowerShell handler back to C# HTTP thread.
    public sealed class ApiResponse {
        public int StatusCode { get; set; }
        public object Body { get; set; }      // hashtable/PSObject — serialized by ApiSerializer
        public string RawJson { get; set; }    // pre-serialized JSON string (bypasses ApiSerializer)
        public bool IncludeLabels { get; set; } // inject *Label companion fields via ApiNameDictionary
    }
}
