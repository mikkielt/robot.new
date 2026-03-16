# Discord Messaging - Technical Reference

---

## Scope

This document covers `Send-DiscordMessage` (webhook sender), PU notification message construction in `Invoke-PlayerCharacterPUAssignment`, and Intel message dispatch via `Resolve-EntityWebhook`.

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

HTTP POST uses `[System.Net.Http.HttpClient]` with UTF-8 encoded `StringContent`:

```powershell
$Content = [System.Net.Http.StringContent]::new($JSON, [System.Text.Encoding]::UTF8, "application/json")
$Response = $HttpClient.PostAsync($Webhook, $Content).GetAwaiter().GetResult()
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

Error handling: URL format is validated before attempting POST. HTTP status code is checked with response body on error. Resource cleanup runs in a `finally` block (`HttpClient`, `StringContent`, `Response` all disposed). Retry logic is delegated to a future queue system.

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

Individual `Send-DiscordMessage` failures are caught and logged to stderr as `[WARN]`. They do not abort the remaining notifications.

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
| HTTP error response | Logged, returns `Success = $false` |
| Player with no webhook | PU still calculated and applied; notification skipped with warning |
| Character without PlayerName | Skipped in Discord grouping |
| Multiple characters, same player | Combined into single message |
| `Send-DiscordMessage` exception | Caught per-player; other notifications continue |
| `-WhatIf` mode | Returns preview object; no HTTP request made |

---

## Testing

| Test file | Coverage |
|---|---|
| `tests/send-discordmessage.Tests.ps1` | URL validation, JSON construction, WhatIf, ShouldProcess |
| `tests/invoke-playercharacterpuassignment.Tests.ps1` | Message grouping, webhook resolution, notification format |

---

## Related Documents

- [PU.md](PU.md) - SendToDiscord side effect
- [SESSIONS.md](SESSIONS.md) - Intel resolution and webhook lookup
- [CONFIG-STATE.md](CONFIG-STATE.md) - Webhook configuration resolution
