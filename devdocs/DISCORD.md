# Discord Messaging — Technical Reference

**Status**: Reference documentation.

---

## 1. Scope

This document covers `Send-DiscordMessage` (webhook sender), PU notification message construction in `Invoke-PlayerCharacterPUAssignment`, and Intel message dispatch via `Resolve-EntityWebhook`.

---

## 2. `Send-DiscordMessage`

### 2.1 Parameters

| Parameter | Type | Description |
|---|---|---|
| `Webhook` | string | Discord webhook URL |
| `Message` | string | Message content |
| `Username` | string | Optional bot display name |

### 2.2 Implementation

**Webhook validation**: Regex check against `https://discord.com/api/webhooks/*` pattern.

**JSON payload construction**:

```powershell
$Payload = [ordered]@{ content = $Message }
if ($Username) { $Payload.username = $Username }
$JSON = $Payload | ConvertTo-Json -Compress
```

**HTTP POST**: Uses `[System.Net.Http.HttpClient]` with UTF-8 encoded `StringContent`:

```powershell
$Content = [System.Net.Http.StringContent]::new($JSON, [System.Text.Encoding]::UTF8, "application/json")
$Response = $HttpClient.PostAsync($Webhook, $Content).GetAwaiter().GetResult()
```

`.GetAwaiter().GetResult()` provides synchronous execution within PowerShell.

**`SupportsShouldProcess`**: Returns a preview object when `-WhatIf` is used:

```powershell
[PSCustomObject]@{ Webhook = $Webhook; StatusCode = $null; Success = $true; WhatIf = $true }
```

### 2.3 Return Object

| Property | Type | Description |
|---|---|---|
| `Webhook` | string | Target webhook URL |
| `StatusCode` | int | HTTP response status code (`$null` if WhatIf) |
| `Success` | bool | Whether the message was sent successfully |
| `WhatIf` | bool | True if this was a preview |

### 2.4 Error Handling

- URL format validation before attempting POST
- HTTP status code checking with response body on error
- Resource cleanup in `finally` block (`HttpClient`, `StringContent`, `Response` all disposed)
- No retry logic at this level — delegated to future queue system

---

## 3. PU Notification Messages

### 3.1 Message Construction

In `Invoke-PlayerCharacterPUAssignment`, notifications are **grouped per player**:

```powershell
$PlayerGroups = Dictionary[string, List[object]] (OrdinalIgnoreCase)
# Group assignment results by PlayerName
```

Characters without a `PlayerName` are skipped.

### 3.2 Message Format (Polish, mandatory)

Per character:

```
Postać "<CharacterName>" (Gracz "<PlayerName>") otrzymuje <GrantedPU> PU.
Aktualna suma PU tej Postaci: <NewPUSum>
```

**Conditional suffixes** (appended to second line, comma-separated):
- If `UsedExceeded > 0`: `, wykorzystano PU nadmiarowe: <UsedExceeded>`
- If `RemainingPUExceeded > 0`: `, pozostałe PU nadmiarowe: <RemainingPUExceeded>`

**Numeric formatting**: `F2` format with `InvariantCulture` (period decimal separator, two decimal places).

Multiple characters for the same player are separated by `\n\n` (blank line).

### 3.3 Message Assembly

Uses `StringBuilder` with initial capacity 256 per character message, then joins with `\n\n`:

```powershell
$SB = [System.Text.StringBuilder]::new(256)
[void]$SB.Append("Postać `"$CharName`" ...")
# ... build message
$Messages.Add($SB.ToString())
$FinalMessage = $Messages -join "`n`n"
```

### 3.4 Bot Username

Hardcoded as `"Bothen"` in the PU assignment pipeline.

Note: `Get-AdminConfig` resolves a `BotUsername` from config, but it is **not used** by PU assignment — only the hardcoded value applies.

### 3.5 Webhook Resolution

Taken from `$Items[0].Character.Player.PRFWebhook` (first result's Character → Player → PRFWebhook path).

**Missing webhook**: If a player has no `PRFWebhook`, the notification is skipped with a `[WARN]` to stderr. This does **not** prevent other players' notifications from being sent.

### 3.6 Failure Handling

Individual `Send-DiscordMessage` failures are caught and logged to stderr as `[WARN]`. They do **not** abort the remaining notifications.

---

## 4. Intel Message Dispatch

### 4.1 Webhook Resolution (`Resolve-EntityWebhook`)

Priority chain for resolving a Discord webhook URL for any entity:

| Priority | Source |
|---|---|
| 1 | Entity's own `@prfwebhook` override (any entity type can have one) |
| 2 | For `Postać (Gracz)`: owning Player's `PRFWebhook` |
| 3 | `$null` (no webhook available) |

### 4.2 Dispatch Flow

Intel messages are constructed during `Get-Session` processing when `@Intel` blocks are present. Each `Intel` object carries:
- `RawTarget`: Original targeting string
- `Message`: Intel content
- `Recipients[]`: Resolved entities with webhook URLs

The actual sending is left to the consumer — `Get-Session` only resolves targets and webhooks.

---

## 5. Edge Cases

| Scenario | Behavior |
|---|---|
| Invalid webhook URL format | Validation error before POST |
| HTTP error response | Logged, but does not throw; returns `Success = $false` |
| Player with no webhook | PU still calculated and applied; notification skipped with warning |
| Character without PlayerName | Skipped in Discord grouping |
| Multiple characters, same player | Combined into single message |
| `Send-DiscordMessage` exception | Caught per-player; other notifications continue |
| `-WhatIf` mode | Returns preview object; no HTTP request made |

---

## 6. Testing

| Test file | Coverage |
|---|---|
| `tests/send-discordmessage.Tests.ps1` | URL validation, JSON construction, WhatIf, ShouldProcess |
| `tests/invoke-playercharacterpuassignment.Tests.ps1` | Message grouping, webhook resolution, notification format |

---

## 7. Related Documents

- [PU.md](PU.md) — §6.2 SendToDiscord side effect
- [SESSIONS.md](SESSIONS.md) — Intel resolution and webhook lookup
- [CONFIG-STATE.md](CONFIG-STATE.md) — Webhook configuration resolution
