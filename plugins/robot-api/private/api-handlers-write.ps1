<#
    .SYNOPSIS
    Write handler functions for the robot-api plugin.

    .DESCRIPTION
    This file defines handler functions for POST/PUT/DELETE endpoints,
    dot-sourced into each worker runspace at startup. Each handler accepts
    [hashtable]$ApiContext and returns @{ StatusCode; Body }.

    Handlers:
    - Invoke-ApiCreateEntity:   POST /entities — creates via New-Entity
    - Invoke-ApiUpdateEntity:   PUT /entities/:name — updates via Set-Entity
    - Invoke-ApiDeleteEntity:   DELETE /entities/:name — soft-deletes via Remove-Entity
    - Invoke-ApiCreateCurrency: POST /currency — creates Przedmiot with currency tags
    - Invoke-ApiUpdateCurrency: PUT /currency/:name — adjusts via Set-CurrencyEntity
    - Invoke-ApiCreatePlayer:   POST /players — creates player+character via New-Player
    - Invoke-ApiCreateCharacter: POST /players/:name/characters — adds via New-PlayerCharacter
    - Invoke-ApiRebuildGraph:   POST /workflow/session-graph — rebuilds index
    - Invoke-ApiRebuildHashes:  POST /workflow/session-hash — updates hashes

    All handlers pass -Confirm:$false to skip interactive prompts. After each
    successful write, Clear-ParseCaches is called to invalidate memory caches.
    The worker pool then increments CacheVersion so other runspaces detect
    the invalidation and refresh their caches on next request.

    PSCustomObject bodies from JSON are decomposed into PowerShell parameter
    hashtables with explicit [string]/[int]/[decimal] casts to avoid type
    ambiguity from ConvertFrom-Json's dynamic typing.
#>

# ═══════════════════════════════════════════════════════════════════════
# ENTITIES
# ═══════════════════════════════════════════════════════════════════════

function Invoke-ApiCreateEntity {
    param([hashtable]$ApiContext)

    $B = $ApiContext.Body
    if (-not $B) {
        return @{ StatusCode = 400; Body = @{ error = 'Request body required' } }
    }
    if (-not $B.name -or -not $B.type) {
        return @{ StatusCode = 400; Body = @{ error = 'name and type are required' } }
    }

    $Params = @{
        Name    = [string]$B.name
        Type    = [string]$B.type
        Confirm = $false
    }

    if ($B.tags -and $B.tags -is [System.Management.Automation.PSCustomObject]) {
        $Tags = @{}
        foreach ($P in $B.tags.PSObject.Properties) {
            $Tags[$P.Name] = $P.Value
        }
        $Params.Tags = $Tags
    }

    if ($B.validFrom) { $Params.ValidFrom = [string]$B.validFrom }

    try {
        $Result = New-Entity @Params
        Clear-ParseCaches
        return @{ StatusCode = 201; Body = $Result }
    } catch {
        return @{ StatusCode = 422; Body = @{ error = $_.Exception.Message } }
    }
}

function Invoke-ApiUpdateEntity {
    param([hashtable]$ApiContext)

    $Name = $ApiContext.PathParams['name']
    $B    = $ApiContext.Body

    if (-not $B) {
        return @{ StatusCode = 400; Body = @{ error = 'Request body required' } }
    }
    if (-not $B.tags -or $B.tags -isnot [System.Management.Automation.PSCustomObject]) {
        return @{ StatusCode = 400; Body = @{ error = 'tags object required in body' } }
    }

    $Tags = @{}
    foreach ($P in $B.tags.PSObject.Properties) {
        $Tags[$P.Name] = $P.Value
    }

    $Params = @{
        Name    = $Name
        Tags    = $Tags
        Confirm = $false
    }

    if ($B.type)      { $Params.Type      = [string]$B.type }
    if ($B.validFrom) { $Params.ValidFrom = [string]$B.validFrom }

    try {
        $Result = Set-Entity @Params
        Clear-ParseCaches
        return @{ StatusCode = 200; Body = $Result }
    } catch {
        return @{ StatusCode = 422; Body = @{ error = $_.Exception.Message } }
    }
}

function Invoke-ApiDeleteEntity {
    param([hashtable]$ApiContext)

    $Name = $ApiContext.PathParams['name']
    $B    = $ApiContext.Body

    $Params = @{
        Name    = $Name
        Confirm = $false
    }

    if ($B) {
        if ($B.type)      { $Params.Type      = [string]$B.type }
        if ($B.validFrom) { $Params.ValidFrom = [string]$B.validFrom }
    }

    try {
        $Result = Remove-Entity @Params
        Clear-ParseCaches
        return @{ StatusCode = 200; Body = $Result }
    } catch {
        return @{ StatusCode = 422; Body = @{ error = $_.Exception.Message } }
    }
}

# ═══════════════════════════════════════════════════════════════════════
# CURRENCY
# ═══════════════════════════════════════════════════════════════════════

function Invoke-ApiCreateCurrency {
    param([hashtable]$ApiContext)

    $B = $ApiContext.Body
    if (-not $B) {
        return @{ StatusCode = 400; Body = @{ error = 'Request body required' } }
    }
    if (-not $B.name) {
        return @{ StatusCode = 400; Body = @{ error = 'name is required' } }
    }

    # Currency entities are Przedmiot type with currency-related tags
    $Tags = @{}
    if ($B.owner)        { $Tags['należy_do'] = [string]$B.owner }
    if ($B.location)     { $Tags['lokacja']    = [string]$B.location }
    if ($null -ne $B.amount) { $Tags['ilość']  = [string]$B.amount }

    $Params = @{
        Name    = [string]$B.name
        Type    = 'Przedmiot'
        Tags    = $Tags
        Confirm = $false
    }

    if ($B.validFrom) { $Params.ValidFrom = [string]$B.validFrom }

    try {
        $Result = New-Entity @Params
        Clear-ParseCaches
        return @{ StatusCode = 201; Body = $Result }
    } catch {
        return @{ StatusCode = 422; Body = @{ error = $_.Exception.Message } }
    }
}

function Invoke-ApiUpdateCurrency {
    param([hashtable]$ApiContext)

    $Name = $ApiContext.PathParams['name']
    $B    = $ApiContext.Body

    if (-not $B) {
        return @{ StatusCode = 400; Body = @{ error = 'Request body required' } }
    }

    $Params = @{
        Name    = $Name
        Confirm = $false
    }

    if ($null -ne $B.amount)      { $Params.Amount      = [int]$B.amount }
    if ($null -ne $B.amountDelta) { $Params.AmountDelta  = [int]$B.amountDelta }
    if ($B.owner)                 { $Params.Owner        = [string]$B.owner }
    if ($B.location)              { $Params.Location     = [string]$B.location }
    if ($B.validFrom)             { $Params.ValidFrom    = [string]$B.validFrom }

    try {
        $Result = Set-CurrencyEntity @Params
        Clear-ParseCaches
        return @{ StatusCode = 200; Body = $Result }
    } catch {
        return @{ StatusCode = 422; Body = @{ error = $_.Exception.Message } }
    }
}

# ═══════════════════════════════════════════════════════════════════════
# PLAYERS
# ═══════════════════════════════════════════════════════════════════════

function Invoke-ApiCreatePlayer {
    param([hashtable]$ApiContext)

    $B = $ApiContext.Body
    if (-not $B) {
        return @{ StatusCode = 400; Body = @{ error = 'Request body required' } }
    }
    if (-not $B.name) {
        return @{ StatusCode = 400; Body = @{ error = 'name is required' } }
    }

    $Params = @{
        Name    = [string]$B.name
        Confirm = $false
    }

    if ($B.margonemId)       { $Params.MargonemID       = [string]$B.margonemId }
    if ($B.prfWebhook)       { $Params.PRFWebhook       = [string]$B.prfWebhook }
    if ($B.triggers)         { $Params.Triggers          = @($B.triggers) }
    if ($B.characterName)    { $Params.CharacterName     = [string]$B.characterName }
    if ($B.characterSheet)   { $Params.CharacterSheetUrl = [string]$B.characterSheet }
    if ($null -ne $B.initialPUStart) {
        $Params.InitialPUStart = [decimal]$B.initialPUStart
    }
    if ($B.noCharacterFile -eq $true) { $Params.NoCharacterFile = $true }

    try {
        $Result = New-Player @Params
        Clear-ParseCaches
        return @{ StatusCode = 201; Body = $Result }
    } catch {
        return @{ StatusCode = 422; Body = @{ error = $_.Exception.Message } }
    }
}

function Invoke-ApiCreateCharacter {
    param([hashtable]$ApiContext)

    $PlayerName = $ApiContext.PathParams['name']
    $B          = $ApiContext.Body

    if (-not $B) {
        return @{ StatusCode = 400; Body = @{ error = 'Request body required' } }
    }
    if (-not $B.characterName) {
        return @{ StatusCode = 400; Body = @{ error = 'characterName is required' } }
    }

    $Params = @{
        PlayerName    = $PlayerName
        CharacterName = [string]$B.characterName
        Confirm       = $false
        Quiet         = $true
    }

    if ($B.characterSheet) { $Params.CharacterSheetUrl = [string]$B.characterSheet }
    if ($null -ne $B.initialPUStart) {
        $Params.InitialPUStart = [decimal]$B.initialPUStart
    }
    if ($B.noCharacterFile -eq $true) { $Params.NoCharacterFile = $true }
    if ($B.condition)      { $Params.Condition    = [string]$B.condition }
    if ($B.specialItems)   { $Params.SpecialItems = @($B.specialItems) }
    if ($B.filePath)       { $Params.FilePath     = [string]$B.filePath }

    try {
        $Result = New-PlayerCharacter @Params
        Clear-ParseCaches
        return @{ StatusCode = 201; Body = $Result }
    } catch {
        return @{ StatusCode = 422; Body = @{ error = $_.Exception.Message } }
    }
}

# ═══════════════════════════════════════════════════════════════════════
# WORKFLOW
# ═══════════════════════════════════════════════════════════════════════

function Invoke-ApiRebuildGraph {
    param([hashtable]$ApiContext)

    $B      = $ApiContext.Body
    $Params = @{ Confirm = $false; Quiet = $true }

    if ($B) {
        if ($B.full -eq $true)      { $Params.Full      = $true }
        if ($B.eagerOnly -eq $true) { $Params.EagerOnly  = $true }
        if ($B.since)               { $Params.Since      = [string]$B.since }
    }

    try {
        $Result = Set-SessionGraph @Params
        return @{ StatusCode = 200; Body = $Result }
    } catch {
        return @{ StatusCode = 422; Body = @{ error = $_.Exception.Message } }
    }
}

function Invoke-ApiRebuildHashes {
    param([hashtable]$ApiContext)

    $B      = $ApiContext.Body
    $Params = @{ Confirm = $false; Quiet = $true }

    if ($B) {
        if ($B.full -eq $true) { $Params.Full = $true }
        if ($B.since)          { $Params.Since = [string]$B.since }
    }

    try {
        $Result = Set-SessionHash @Params
        return @{ StatusCode = 200; Body = $Result }
    } catch {
        return @{ StatusCode = 422; Body = @{ error = $_.Exception.Message } }
    }
}
