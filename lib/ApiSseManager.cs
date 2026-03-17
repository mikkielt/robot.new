using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Net;
using System.Text;
using System.Text.Json;
using System.Threading;

namespace Robot {
    /// Thread-safe Server-Sent Events (SSE) manager. Maintains a collection of
    /// open HttpListenerResponse streams and broadcasts events to all connected
    /// clients.
    ///
    /// Dead clients (broken pipe, closed connection) are detected during broadcast
    /// and removed. A heartbeat comment (": keepalive") is sent every 30 seconds
    /// to detect stale connections proactively.
    ///
    /// Thread safety: ConcurrentDictionary keyed by monotonic client ID for
    /// lock-free add/remove. Broadcast iterates a snapshot of values.
    ///
    /// Consumers: ApiServer (SSE route), Invoke-ApiEventBroadcast (plugin hook)
    public sealed class ApiSseManager : IDisposable {
        private readonly ConcurrentDictionary<long, SseClient> _clients =
            new ConcurrentDictionary<long, SseClient>();
        private long _nextId;
        private Timer _heartbeatTimer;

        public int ClientCount => _clients.Count;

        public ApiSseManager() {
            // Heartbeat every 30 seconds
            _heartbeatTimer = new Timer(_ => SendHeartbeat(), null,
                TimeSpan.FromSeconds(30), TimeSpan.FromSeconds(30));
        }

        /// Register a new SSE client. Sends initial connection event.
        public void AddClient(HttpListenerResponse response) {
            long id = Interlocked.Increment(ref _nextId);

            response.ContentType = "text/event-stream";
            response.Headers.Add("Cache-Control", "no-cache");
            response.Headers.Add("Connection", "keep-alive");
            // Disable buffering for immediate delivery
            response.SendChunked = true;

            var client = new SseClient { Id = id, Response = response };

            if (_clients.TryAdd(id, client)) {
                // Send connection event
                string hello = "data: {\"type\":\"connected\",\"clientId\":" + id +
                    ",\"timestamp\":\"" + DateTime.UtcNow.ToString("o") + "\"}\n\n";
                TryWrite(client, hello);
            }
        }

        /// Broadcast an event to all connected clients.
        /// eventType: SSE event name (e.g. "entity:write").
        /// data: dictionary serialized to JSON.
        public void Broadcast(string eventType, Dictionary<string, object> data) {
            if (_clients.IsEmpty) return;

            data["timestamp"] = DateTime.UtcNow.ToString("o");

            string json;
            using (var ms = new System.IO.MemoryStream())
            using (var writer = new Utf8JsonWriter(ms, new JsonWriterOptions { Indented = false })) {
                writer.WriteStartObject();
                foreach (var kvp in data) {
                    writer.WritePropertyName(kvp.Key);
                    if (kvp.Value is string s) writer.WriteStringValue(s);
                    else if (kvp.Value is int i) writer.WriteNumberValue(i);
                    else if (kvp.Value is long l) writer.WriteNumberValue(l);
                    else writer.WriteStringValue(kvp.Value?.ToString());
                }
                writer.WriteEndObject();
                writer.Flush();
                json = Encoding.UTF8.GetString(ms.ToArray());
            }

            string message = "event: " + eventType + "\ndata: " + json + "\n\n";
            var deadIds = new List<long>();

            foreach (var kvp in _clients) {
                if (!TryWrite(kvp.Value, message))
                    deadIds.Add(kvp.Key);
            }

            // Remove dead clients
            foreach (long id in deadIds)
                _clients.TryRemove(id, out _);
        }

        /// Disconnect all clients (called on server shutdown).
        public void DisconnectAll() {
            foreach (var kvp in _clients) {
                try { kvp.Value.Response.Close(); } catch { }
            }
            _clients.Clear();
        }

        private void SendHeartbeat() {
            if (_clients.IsEmpty) return;

            string comment = ": keepalive\n\n";
            var deadIds = new List<long>();

            foreach (var kvp in _clients) {
                if (!TryWrite(kvp.Value, comment))
                    deadIds.Add(kvp.Key);
            }

            foreach (long id in deadIds)
                _clients.TryRemove(id, out _);
        }

        private static bool TryWrite(SseClient client, string message) {
            try {
                byte[] bytes = Encoding.UTF8.GetBytes(message);
                client.Response.OutputStream.Write(bytes, 0, bytes.Length);
                client.Response.OutputStream.Flush();
                return true;
            } catch {
                return false;
            }
        }

        public void Dispose() {
            _heartbeatTimer?.Dispose();
            DisconnectAll();
        }

        private sealed class SseClient {
            public long Id { get; set; }
            public HttpListenerResponse Response { get; set; }
        }
    }
}
