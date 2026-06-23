using System;
using System.Collections.Generic;
using System.Text.RegularExpressions;

namespace Robot {
    /// Compiled-regex URL route matcher. Routes are registered once at startup
    /// and compiled to IL via RegexOptions.Compiled — no interpretation overhead
    /// at match time. Compiled C# because route matching runs on every HTTP
    /// request before PowerShell handlers; regex compilation and dictionary
    /// lookup are significantly faster in compiled code.
    ///
    /// Two-tier matching strategy:
    /// 1. Static routes (no :param segments) — O(1) dictionary lookup by
    ///    "METHOD:path" key, covering most built-in endpoints.
    /// 2. Regex routes (with :param) — O(N) linear scan; N is small and each
    ///    regex is precompiled to IL.
    ///
    /// :param path segments (e.g. /entities/:name) are converted to named
    /// regex capture groups and extracted into RouteMatch.PathParams.
    ///
    /// Two handler types:
    /// - StaticHandler: Func<RouteMatch, ApiServer, object> — executes entirely
    ///   in C# (used for /health, /metrics, /routes). No RunspacePool needed.
    /// - HandlerName: string — identifies a PowerShell function to invoke via
    ///   the RequestQueue/RunspacePool worker bridge.
    ///
    /// Per-route scope enforcement: each route may declare a RequiredScope
    /// string checked by ApiMiddleware.HasScope in ApiServer before dispatch.
    ///
    /// Consumers: Start-RobotApi (route registration via api-routes.ps1),
    ///            ApiServer.HandleRequestAsync (request dispatch)
    public sealed class ApiRouter {
        private readonly List<ApiRoute> _routes = new List<ApiRoute>();
        private readonly Dictionary<string, ApiRoute> _staticRoutes =
            new Dictionary<string, ApiRoute>(StringComparer.OrdinalIgnoreCase);

        /// Register a route with a PowerShell handler name (dispatched via
        /// RequestQueue to RunspacePool workers). scope: required permission
        /// string checked by ApiMiddleware.HasScope before handler invocation.
        public void AddRoute(string method, string pattern, string handlerName,
                             string description, int statusCode = 200,
                             string scope = null) {
            var route = BuildRoute(method, pattern, description, statusCode);
            route.HandlerName = handlerName;
            route.RequiredScope = scope;
            _routes.Add(route);
        }

        /// Register a cacheable PS handler route with sidecar metadata.
        /// cacheKey: sidecar filename stem (e.g. "economy-snapshot").
        /// cacheDomains: fingerprint domains this route depends on.
        public void AddCacheableRoute(string method, string pattern,
            string handlerName, string description, int statusCode,
            string scope, string cacheKey, string[] cacheDomains) {
            var route = BuildRoute(method, pattern, description, statusCode);
            route.HandlerName = handlerName;
            route.RequiredScope = scope;
            route.CacheKey = cacheKey;
            route.CacheDomains = cacheDomains;
            _routes.Add(route);
        }

        /// Register a route with a C#-only static handler delegate (no PowerShell
        /// invocation). Used for /health, /metrics, /routes endpoints.
        public void AddStaticRoute(string method, string pattern,
                                   Func<RouteMatch, ApiServer, object> handler,
                                   string description, int statusCode = 200,
                                   string scope = null) {
            var route = BuildRoute(method, pattern, description, statusCode);
            route.StaticHandler = handler;
            route.RequiredScope = scope;
            _routes.Add(route);
        }

        /// Mutate a previously-registered route to set a per-minute
        /// rate limit. Looked up by method + pattern. Silently no-op if
        /// the route is not found (callers should treat that as a
        /// configuration error caught by tests).
        public void SetRouteRateLimit(string method, string pattern,
                                       int perMinute) {
            foreach (var route in _routes) {
                if (string.Equals(route.Method, method, StringComparison.OrdinalIgnoreCase)
                    && string.Equals(route.Pattern, pattern, StringComparison.Ordinal)) {
                    route.RateLimitPerMinute = perMinute;
                    return;
                }
            }
        }

        /// Register a Server-Sent Events endpoint. SSE routes keep the
        /// HttpListenerResponse open for streaming via ApiSseManager.
        public void AddSseRoute(string pattern, string description,
                                string scope = null) {
            var route = BuildRoute("GET", pattern, description, 200);
            route.IsSse = true;
            route.RequiredScope = scope;
            _routes.Add(route);
        }

        /// Match an incoming HTTP method + path against the route table.
        /// Returns RouteMatch with captured path params, or null if no
        /// route matches (caller should return 404).
        public RouteMatch Match(string method, string path) {
            // Fast path: static route lookup (no regex)
            string key = method + ":" + path;
            if (_staticRoutes.TryGetValue(key, out var staticRoute)) {
                return new RouteMatch {
                    Route = staticRoute,
                    PathParams = new Dictionary<string, string>()
                };
            }

            // Regex routes
            for (int i = 0; i < _routes.Count; i++) {
                var route = _routes[i];
                if (!string.Equals(route.Method, method, StringComparison.OrdinalIgnoreCase))
                    continue;

                var match = route.CompiledRegex.Match(path);
                if (!match.Success) continue;

                var pathParams = new Dictionary<string, string>(
                    StringComparer.OrdinalIgnoreCase);
                foreach (string groupName in route.ParamNames) {
                    var group = match.Groups[groupName];
                    if (group.Success)
                        pathParams[groupName] = Uri.UnescapeDataString(group.Value);
                }

                return new RouteMatch { Route = route, PathParams = pathParams };
            }

            return null;
        }

        /// Return all registered routes for the /routes discovery endpoint.
        /// Includes scope field on every entry for client-side scope discovery.
        public List<Dictionary<string, string>> ListRoutes() {
            var result = new List<Dictionary<string, string>>(_routes.Count);
            foreach (var route in _routes) {
                result.Add(new Dictionary<string, string> {
                    ["method"]      = route.Method,
                    ["pattern"]     = route.Pattern,
                    ["description"] = route.Description,
                    ["scope"]       = route.RequiredScope
                });
            }
            return result;
        }

        /// Build an ApiRoute: convert :param segments to named regex groups,
        /// compile the regex, and cache parameterless routes for O(1) lookup.
        private ApiRoute BuildRoute(string method, string pattern,
                                     string description, int statusCode) {
            string id = method + ":" + pattern;

            // Convert :param segments to named capture groups (?<param>[^/]+)
            var paramNames = new List<string>();
            var regexPattern = "^" + Regex.Replace(pattern, @":(\w+)", m => {
                paramNames.Add(m.Groups[1].Value);
                return "(?<" + m.Groups[1].Value + ">[^/]+)";
            }) + "$";

            var route = new ApiRoute {
                Id            = id,
                Method        = method,
                Pattern       = pattern,
                Description   = description,
                StatusCode    = statusCode,
                CompiledRegex = new Regex(regexPattern,
                    RegexOptions.Compiled | RegexOptions.IgnoreCase),
                ParamNames    = paramNames.ToArray()
            };

            // Cache exact-match routes (no params) for O(1) lookup
            if (paramNames.Count == 0) {
                _staticRoutes[id] = route;
            }

            return route;
        }
    }

    /// Compiled route definition: precompiled regex, handler binding (PowerShell
    /// function name or C# Func delegate), extracted parameter names for path
    /// capture, and optional RequiredScope for permission enforcement.
    public sealed class ApiRoute {
        public string Id { get; set; }
        public string Method { get; set; }
        public string Pattern { get; set; }
        public string Description { get; set; }
        public int StatusCode { get; set; }
        public Regex CompiledRegex { get; set; }
        public string[] ParamNames { get; set; }
        public string HandlerName { get; set; }
        public Func<RouteMatch, ApiServer, object> StaticHandler { get; set; }
        public bool IsSse { get; set; }
        public string RequiredScope { get; set; }

        // Response cache metadata — null means not cacheable
        public string CacheKey { get; set; }         // sidecar filename stem
        public string[] CacheDomains { get; set; }   // fingerprint domains: "entity", "session", "graph"

        // Per-route rate limit (WP-17). 0 = use only the global limit.
        // Enforced by ApiMiddleware.CheckRouteRateLimit, called after the
        // global CheckRateLimit in ApiServer.HandleRequestAsync.
        public int RateLimitPerMinute { get; set; }
    }

    /// Result of matching a request URL against the route table: matched route + captured path params.
    /// QueryParams is populated by ApiServer.HandleRequestAsync before dispatch (static or dynamic).
    public sealed class RouteMatch {
        public ApiRoute Route { get; set; }
        public Dictionary<string, string> PathParams { get; set; }
        public Dictionary<string, string> QueryParams { get; set; }
    }
}
