using System;

namespace Robot {
    /// Lightweight session metadata types used by both C# SessionTagParser
    /// output path and PowerShell fallback path in Get-SessionListMetadata.
    ///
    /// These types are separate from SessionTagParser's internal structs
    /// (PUEntry, ChangeEntry, etc.) because those use value-type semantics
    /// and non-nullable fields, while consumers expect reference-type
    /// semantics with nullable Value (e.g. PU entries without explicit value).
    ///
    /// Consumers: Get-Session, Get-EntityState, Invoke-PlayerCharacterPUAssignment
    public sealed class SessionPU {
        public string Character { get; set; }
        public object Value { get; set; }

        public SessionPU() {}

        public SessionPU(string character, object value) {
            Character = character;
            Value = value;
        }
    }

    /// Entity change directive from @Zmiany block: entity name + tag overrides.
    public sealed class SessionChange {
        public string EntityName { get; set; }
        public SessionTag[] Tags { get; set; }

        public SessionChange() {}

        public SessionChange(string entityName, SessionTag[] tags) {
            EntityName = entityName;
            Tags = tags;
        }
    }

    /// Single @tag: value pair within a SessionChange directive.
    public sealed class SessionTag {
        public string Tag { get; set; }
        public string Value { get; set; }

        public SessionTag() {}

        public SessionTag(string tag, string value) {
            Tag = tag;
            Value = value;
        }
    }

    /// Targeted intelligence message from @Intel block: raw target + message.
    public sealed class SessionIntel {
        public string RawTarget { get; set; }
        public string Message { get; set; }

        public SessionIntel() {}

        public SessionIntel(string rawTarget, string message) {
            RawTarget = rawTarget;
            Message = message;
        }
    }

    /// Currency transfer directive from @Transfer block: amount, denomination, source, destination.
    public sealed class SessionTransfer {
        public int Amount { get; set; }
        public string Denomination { get; set; }
        public string Source { get; set; }
        public string Destination { get; set; }

        public SessionTransfer() {}

        public SessionTransfer(int amount, string denomination, string source, string destination) {
            Amount = amount;
            Denomination = denomination;
            Source = source;
            Destination = destination;
        }
    }
}
