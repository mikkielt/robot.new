<#
    .SYNOPSIS
    SSE event broadcast hook handler for the robot-api plugin.

    .DESCRIPTION
    This file contains Invoke-ApiEventBroadcast — a plugin hook handler that
    broadcasts real-time Server-Sent Events to connected SSE clients when
    data-mutating operations occur.

    The handler is registered via plugin.psd1 Hooks entries for AfterWrite
    and AfterCreate phases. When triggered, it maps the hook operation to
    an SSE event type, populates a typed Dictionary<string,object> with
    operation-specific fields, and calls ApiSseManager.Broadcast().

    Hook-to-event mapping:
    - Write-EntityFile  → entity:write (path, entity name)
    - New-Entity        → entity:create (name, entity type)
    - New-PlayerCharacter → character:create (player, character name)

    Early-exit guards skip broadcast when no server instance exists or no
    SSE clients are connected, avoiding unnecessary Dictionary allocation.
#>

function Invoke-ApiEventBroadcast {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$HookContext
    )

    if (-not $script:ApiServerInstance -or
        -not $script:ApiServerInstance.IsRunning) {
        return
    }

    $SseManager = $script:ApiServerInstance.SseManager
    if (-not $SseManager -or $SseManager.ClientCount -eq 0) {
        return
    }

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
    }
}
