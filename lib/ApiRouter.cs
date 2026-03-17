using System;
using System.Collections.Generic;
using System.Text.RegularExpressions;

namespace Robot {
    /// Compiled-regex URL route matcher. Routes are registered at startup and
    /// compiled once. Match() is O(N) over routes but N is small (~40) and
    /// regex matching is compiled to IL via RegexOptions.Compiled.
    ///
    /// Supports :param path segments (e.g. /entities/:name) that become named
    /// regex groups. Static routes (no params) use direct string comparison
    /// for O(1) lookup before falling through to regex routes.
    ///
    /// Two handler types:
    /// - StaticHandler: Func<RouteMatch, ApiServer, object> — executes entirely
    ///   in C# (used for /health, /metrics, /routes). No RunspacePool needed.
    /// - HandlerName: string — identifies a PowerShell function to invoke via
    ///   the RunspacePool worker bridge.
    ///
    /// Consumers: Start-RobotApi (route registration), ApiServer (request dispatch)
    public sealed class ApiRouter {
        private readonly List<ApiRoute> _routes = new List<ApiRoute>();
        private readonly Dictionary<string, ApiRoute> _staticRoutes =
            new Dictionary<string, ApiRoute>(StringComparer.OrdinalIgnoreCase);

        /// Register a route with a PowerShell handler (dispatched via RequestQueue).
        public void AddRoute(string method, string pattern, string handlerName,
                             string description, int statusCode = 200) {
            var route = BuildRoute(method, pattern, description, statusCode);
            route.HandlerName = handlerName;
            _routes.Add(route);
        }

        /// Register a route with a C#-only static handler (no PS invocation).
        public void AddStaticRoute(string method, string pattern,
                                   Func<RouteMatch, ApiServer, object> handler,
                                   string description, int statusCode = 200) {
            var route = BuildRoute(method, pattern, description, statusCode);
            route.StaticHandler = handler;
            _routes.Add(route);
        }

        /// Register the SSE endpoint.
        public void AddSseRoute(string pattern, string description) {
            var route = BuildRoute("GET", pattern, description, 200);
            route.IsSse = true;
            _routes.Add(route);
        }

        /// Match an incoming request to a registered route.
        /// Returns null if no route matches.
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
        public List<Dictionary<string, string>> ListRoutes() {
            var result = new List<Dictionary<string, string>>(_routes.Count);
            foreach (var route in _routes) {
                result.Add(new Dictionary<string, string> {
                    ["method"]      = route.Method,
                    ["pattern"]     = route.Pattern,
                    ["description"] = route.Description
                });
            }
            return result;
        }

        private ApiRoute BuildRoute(string method, string pattern,
                                     string description, int statusCode) {
            string id = method + ":" + pattern;

            // Extract parameter names from :param segments
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

    /// Compiled route definition: regex pattern, handler binding (PS name or C# delegate),
    /// and extracted parameter names for path segment capture.
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
    }

    /// Result of matching a request URL against the route table: matched route + captured path params.
    public sealed class RouteMatch {
        public ApiRoute Route { get; set; }
        public Dictionary<string, string> PathParams { get; set; }
    }
}
