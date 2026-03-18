# Discord Messaging - Technical Reference

---

## Scope

This document covers `Send-DiscordMessage` (webhook sender), PU notification message construction in `Invoke-PlayerCharacterPUAssignment`, Intel message dispatch via `Resolve-EntityWebhook`, and delivery tracking via `discord-state.ps1`.

---

## `Send-DiscordMessage`

Parameters:

| Parameter | Type | Description |
|---|---|---|
| `Webhook` | string | Discord webhook URL |
| `Message` | string | Message content |
| `Username` | string | Optional bot display name |

Webhook validation uses a regex check against the `https://discord.com/api/webhooks/*` pattern.

JSON payload construction:

```powershell
$Payload = [ordered]@{ content = $Message }
if ($Username) { $Payload.username = $Username }
$JSON = $Payload | ConvertTo-Json -Compress
```

HTTP POST uses `[System.Net.Http.HttpClient]` with UTF-8 encoded `ByteArrayContent` (avoids double-encoding from `StringContent`):

```powershell
$JsonBytes = [System.Text.Encoding]::UTF8.GetBytes($JSON)
$Content = [System.Net.Http.ByteArrayContent]::new($JsonBytes)
$Content.Headers.ContentType = [System.Net.Http.Headers.MediaTypeHeaderValue]::new('application/json')
$Response = $Client.PostAsync($Webhook, $Content).GetAwaiter().GetResult()
```

`.GetAwaiter().GetResult()` provides synchronous execution within PowerShell.

`SupportsShouldProcess` returns a preview object when `-WhatIf` is used:

```powershell
[PSCustomObject]@{ Webhook = $Webhook; StatusCode = $null; Success = $true; WhatIf = $true }
```

Return object:

| Property | Type | Description |
|---|---|---|
| `Webhook` | string | Target webhook URL |
| `StatusCode` | int | HTTP response status code (`$null` if WhatIf) |
| `Success` | bool | Whether the message was sent successfully |
| `WhatIf` | bool | True if this was a preview |

Error handling: URL format is validated before attempting POST. HTTP errors throw with the status code and response body in the exception message (format: `"Discord webhook returned HTTP NNN: body"`). Resource cleanup runs in a `finally` block (`HttpClient`, `ByteArrayContent`, `Response` all disposed). Delivery tracking is handled by callers via `Add-DiscordDeliveryEntry` (see Delivery Tracking section below).

---

## PU Notification Messages

In `Invoke-PlayerCharacterPUAssignment`, notifications are grouped per player:

```powershell
$PlayerGroups = Dictionary[string, List[object]] (OrdinalIgnoreCase)
# Group assignment results by PlayerName
```

Characters without a `PlayerName` are skipped.

Message format (Polish, mandatory) per character:

```
Postac "<CharacterName>" (Gracz "<PlayerName>") otrzymuje <GrantedPU> PU.
Aktualna suma PU tej Postaci: <NewPUSum>
```

Conditional suffixes (appended to second line, comma-separated):
- If `UsedExceeded > 0`: `, wykorzystano PU nadmiarowe: <UsedExceeded>`
- If `RemainingPUExceeded > 0`: `, pozostale PU nadmiarowe: <RemainingPUExceeded>`

Numeric formatting uses `F2` format with `InvariantCulture` (period decimal separator, two decimal places).

Multiple characters for the same player are separated by `\n\n` (blank line).

Message assembly uses `Get-AdminTemplate` with template files for each character's message:

- `pu-notification-base.txt.template` -- base message with `{CharacterName}`, `{PlayerName}`, `{GrantedPU}`, `{NewPUSum}` placeholders
- `pu-notification-overflow.txt.template` -- appended when `UsedExceeded > 0`, with `{UsedExceeded}` placeholder
- `pu-notification-remaining.txt.template` -- appended when `RemainingPUExceeded > 0`, with `{RemainingPUExceeded}` placeholder

Multiple characters for the same player are joined with `\n\n`:

```powershell
$FullMessage = ($Items | ForEach-Object { $_.Message }) -join "`n`n"
```

Bot username is hardcoded as `"Bothen"` in the PU assignment pipeline. `Get-AdminConfig` resolves a `BotUsername` from config, but only the hardcoded value is used by PU assignment.

Webhook is resolved from `$Items[0].Character.Player.PRFWebhook` (first result's Character -> Player -> PRFWebhook path). If a player has no `PRFWebhook`, the notification is skipped with a `[WARN]` to stderr. Other players' notifications are still sent.

Individual `Send-DiscordMessage` failures are caught and logged to stderr as `[WARN]`. They do not abort the remaining notifications. Both successes and failures are persisted to the delivery state file via `Add-DiscordDeliveryEntry`.

---

## Intel Message Dispatch

Webhook resolution priority chain (`Resolve-EntityWebhook`):

| Priority | Source |
|---|---|
| 1 | Entity's own `@prfwebhook` override (any entity type can have one) |
| 2 | For `Postac`: owning Player's `PRFWebhook` |
| 3 | `$null` (no webhook available) |

Intel messages are constructed during `Get-Session` processing when `@Intel` blocks are present. Each `Intel` object carries:
- `RawTarget` -- original targeting string
- `Message` -- Intel content
- `Recipients[]` -- resolved entities with webhook URLs

The actual sending is left to the consumer -- `Get-Session` only resolves targets and webhooks.

---

## Edge Cases

| Scenario | Behavior |
|---|---|
| Invalid webhook URL format | Validation error before POST |
| HTTP error response | Throws with status code and body in exception message |
| Player with no webhook | PU still calculated and applied; notification skipped with warning |
| Character without PlayerName | Skipped in Discord grouping |
| Multiple characters, same player | Combined into single message |
| `Send-DiscordMessage` exception | Caught per-player; other notifications continue |
| `-WhatIf` mode | Returns preview object; no HTTP request made |

---

## Delivery Tracking

Delivery state is persisted to `.robot.local/res/discord-delivery.json` as a JSON log. `Get-NotificationLog` reconstructs notification intent from `@Intel` directives; delivery tracking records actual send outcomes.

State file helpers in `private/discord-state.ps1`:

| Function | Purpose |
|---|---|
| `Add-DiscordDeliveryEntry` | Appends timestamped delivery record (OK or FAIL) to JSON state file |
| `Get-DiscordDeliveryEntries` | Parses JSON state file into structured PSCustomObject array |

The state file uses a structured JSON format (version 1):

```json
{
  "version": 1,
  "entries": [
    {
      "timestamp": "2026-03-01T09:15:22",
      "timezone": "UTC+01:00",
      "status": "OK",
      "operation": "PU",
      "recipient": "Jan",
      "statusCode": 204,
      "context": "2026-02 PU: Solmyr +3.00",
      "errorMessage": null
    }
  ]
}
```

`Add-DiscordDeliveryEntry` reads or initializes the JSON state, rebuilds the entries list as mutable `List[object]` (since `ConvertFrom-Json` yields immutable PSCustomObjects), appends a new entry, and writes back via `Save-JsonStateFile`. Depends on `Save-JsonStateFile` / `Read-JsonStateFile` from `admin-state.ps1`.

The legacy Markdown entry format (`- YYYY-MM-dd HH:mm:ss (timezone) [OK|FAIL] Operation -> Recipient (HTTP NNN)`) is no longer written. Migration Phase 0 converts the legacy `discord-delivery.md` to `discord-delivery.json` via `Convert-DiscordDeliveryToJson` in `migration/phase0-helpers.ps1`.

Callers that persist delivery results:

| Source | Operation | When |
|---|---|---|
| `Invoke-PlayerCharacterPUAssignment` | `PU` | After each per-player `Send-DiscordMessage` |
| `Invoke-DiscordAnnouncementWorkflow` | `Announcement` | After announcement send |
| `Invoke-DiscordPUNotificationWorkflow` | `PU-Resend` | After re-send of failed PU notification |

HTTP status codes in FAIL entries are extracted from the exception message via regex (`HTTP\s+(\d+)`), since `Send-DiscordMessage` throws on HTTP errors rather than returning a failure object.

`Get-DiscordDeliveryLog` reads and filters the delivery state file. Supports filtering by operation, recipient, date range, and failed-only. Returns entries sorted most-recent-first.

`Invoke-DiscordPUNotificationWorkflow` (CLI workflow) queries `Get-DiscordDeliveryLog -FailedOnly -Operation PU` for a selected player, reconstructs the notification from the context string (format: `"YYYY-MM PU: CharName +3.00"`), and re-sends via `Send-DiscordMessage`. Re-sends are logged as `PU-Resend` operations.

---

## Testing

| Test file | Coverage |
|---|---|
| `tests/send-discordmessage.Tests.ps1` | URL validation, JSON construction, WhatIf, ShouldProcess |
| `tests/invoke-playercharacterpuassignment.Tests.ps1` | Message grouping, webhook resolution, notification format |
| `tests/discord-state.Tests.ps1` | State file write/read round-trip, regex parsing |
| `tests/get-discorddeliverylog.Tests.ps1` | Filtering, sorting, edge cases |

---

## Related Documents

- [PU.md](PU.md) — SendToDiscord side effect
- [SESSIONS.md](SESSIONS.md) — Intel resolution and webhook lookup
- [CONFIG-STATE.md](CONFIG-STATE.md) — Webhook configuration resolution
- [AUDITING.md](AUDITING.md) — Notification intent vs delivery status
