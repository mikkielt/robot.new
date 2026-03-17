<#
    .SYNOPSIS
    SSE event broadcast hook handler for the robot-api plugin.

    .DESCRIPTION
    This file contains Invoke-ApiEventBroadcast — a plugin hook handler that
    broadcasts real-time Server-Sent Events to connected SSE clients when
    data-mutating operations occur in the Robot module.

    The handler is registered via plugin.psd1 Hooks entries for AfterWrite
    and AfterCreate phases. The module's Invoke-PluginHook call passes a
    $HookContext hashtable with an Operation key identifying the source
    command and operation-specific keys (Name, Path, Type, etc.).

    The switch on $HookContext.Operation maps each source command to a
    typed SSE event, populates a Dictionary<string,object> with the
    relevant fields, and calls ApiSseManager.Broadcast() to push the
    event to all connected /events SSE clients.

    Hook-to-event mapping:
    - Write-EntityFile    -> entity:write (path, entity name)
    - New-Entity          -> entity:create (name, entity type)
    - New-PlayerCharacter -> character:create (player, character name)
    - Remove-Entity       -> entity:delete (name)
    - Set-CurrencyEntity  -> currency:write (name)
    - New-Player          -> player:create (name)

    Early-exit guards skip broadcast when no server instance exists
    ($script:ApiServerInstance) or no SSE clients are connected
    (SseManager.ClientCount == 0), avoiding Dictionary allocation
    and switch evaluation on every write when nobody is listening.
#>

function Invoke-ApiEventBroadcast {
    <#
        .SYNOPSIS
        Broadcasts an SSE event to connected clients based on a plugin hook context.
    #>

    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$HookContext
    )

    # Skip if no API server is running — avoids work during module-only usage
    if (-not $script:ApiServerInstance -or
        -not $script:ApiServerInstance.IsRunning) {
        return
    }

    # Skip if nobody is listening on /events — no clients means no point broadcasting
    $SseManager = $script:ApiServerInstance.SseManager
    if (-not $SseManager -or $SseManager.ClientCount -eq 0) {
        return
    }

    # Typed dictionary for JSON-serializable event payload
    $EventData = [System.Collections.Generic.Dictionary[string, object]]::new()

    switch ($HookContext.Operation) {
        'Write-EntityFile' {
            if ($HookContext.Path) {
                $EventData['path'] = [string]$HookContext.Path
            }
            if ($HookContext.EntityName) {
                $EventData['entity'] = [string]$HookContext.EntityName
            }
            $SseManager.Broadcast('entity:write', $EventData)
        }
        'New-Entity' {
            if ($HookContext.Name) {
                $EventData['name'] = [string]$HookContext.Name
            }
            if ($HookContext.Type) {
                $EventData['entityType'] = [string]$HookContext.Type
            }
            $SseManager.Broadcast('entity:create', $EventData)
        }
        'New-PlayerCharacter' {
            if ($HookContext.PlayerName) {
                $EventData['player'] = [string]$HookContext.PlayerName
            }
            if ($HookContext.CharacterName) {
                $EventData['character'] = [string]$HookContext.CharacterName
            }
            $SseManager.Broadcast('character:create', $EventData)
        }
        'Remove-Entity' {
            if ($HookContext.Name) {
                $EventData['name'] = [string]$HookContext.Name
            }
            $SseManager.Broadcast('entity:delete', $EventData)
        }
        'Set-CurrencyEntity' {
            if ($HookContext.Name) {
                $EventData['name'] = [string]$HookContext.Name
            }
            $SseManager.Broadcast('currency:write', $EventData)
        }
        'New-Player' {
            if ($HookContext.Name) {
                $EventData['name'] = [string]$HookContext.Name
            }
            $SseManager.Broadcast('player:create', $EventData)
        }
    }
}
