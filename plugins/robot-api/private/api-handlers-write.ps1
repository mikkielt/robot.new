<#
    .SYNOPSIS
    Write handler functions for the robot-api plugin.

    .DESCRIPTION
    This file defines handler functions for POST/PUT/DELETE endpoints,
    dot-sourced into each worker runspace at startup. Each handler accepts
    [hashtable]$ApiContext and returns @{ StatusCode; Body }.

    Helpers:
    - Invoke-SidecarInvalidation: invalidates response cache sidecars for a domain

    Handlers:
    - Invoke-ApiCreateEntity:   POST /entities — creates via New-Entity
    - Invoke-ApiUpdateEntity:   PUT /entities/:name — updates via Set-Entity
    - Invoke-ApiDeleteEntity:   DELETE /entities/:name — soft-deletes via Remove-Entity
    - Invoke-ApiCreateCurrency: POST /currency — creates Przedmiot with currency tags
    - Invoke-ApiUpdateCurrency: PUT /currency/:name — adjusts via Set-CurrencyEntity
    - Invoke-ApiCreatePlayer:   POST /players — creates player+character via New-Player
    - Invoke-ApiCreateCharacter: POST /players/:name/characters — adds via New-PlayerCharacter
    - Invoke-ApiCreateSession:  POST /sessions — creates session via Add-Session
    - Invoke-ApiRebuildGraph:   POST /workflow/session-graph — rebuilds index
    - Invoke-ApiRebuildHashes:  POST /workflow/session-hash — updates hashes
    - Invoke-ApiCreateLocation: POST /locations — creates via New-LocationEntity
    - Invoke-ApiUpdateLocation: PUT /locations/:name — updates via Set-LocationEntity
    - Invoke-ApiDeleteLocation: DELETE /locations/:name — soft-deletes location
    - Invoke-ApiCreateMap:      POST /maps — creates via New-MapEntity
    - Invoke-ApiUpdateMap:      PUT /maps/:name — updates via Set-MapEntity

    All handlers pass -Confirm:$false to skip interactive prompts. After each
    successful write, Clear-ParseCaches is called to invalidate memory caches
    (except Add-Session which handles its own cache invalidation), followed
    by Invoke-SidecarInvalidation to purge any sidecar-cached HTTP responses
    for the affected domain ('entity', 'session', or 'graph'). The worker
    pool then increments CacheVersion so other runspaces detect the
    invalidation and refresh their caches on next request.

    PSCustomObject bodies from JSON are decomposed into PowerShell parameter
    hashtables with explicit [string]/[int]/[decimal] casts to avoid type
    ambiguity from ConvertFrom-Json's dynamic typing.
#>

# ── Response cache invalidation helper ───────────────────────────────
# Uses static field [Robot.ApiServer]::ResponseCache — accessible from
# all runspaces (workers and main alike), unlike $script:ApiServerInstance
# which is only set in the main runspace.
function Invoke-SidecarInvalidation {
    param([string]$Domain)
    $Cache = [Robot.ApiServer]::ResponseCache
    if ($Cache) { $Cache.InvalidateDomain($Domain) }
}

# ═══════════════════════════════════════════════════════════════════════
# ENTITIES
# ═══════════════════════════════════════════════════════════════════════

function Invoke-ApiCreateEntity {
    <#
        .SYNOPSIS
        Creates a new entity with optional tags and temporal validity.
    #>

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
        Invoke-SidecarInvalidation -Domain 'entity'
        return @{ StatusCode = 201; Body = $Result }
    } catch {
        return @{ StatusCode = 422; Body = @{ error = $_.Exception.Message } }
    }
}

function Invoke-ApiUpdateEntity {
    <#
        .SYNOPSIS
        Updates entity tags via Set-Entity.
    #>

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
        Invoke-SidecarInvalidation -Domain 'entity'
        return @{ StatusCode = 200; Body = $Result }
    } catch {
        return @{ StatusCode = 422; Body = @{ error = $_.Exception.Message } }
    }
}

function Invoke-ApiDeleteEntity {
    <#
        .SYNOPSIS
        Soft-deletes an entity by marking it as Usunięty.
    #>

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
        Invoke-SidecarInvalidation -Domain 'entity'
        return @{ StatusCode = 200; Body = $Result }
    } catch {
        return @{ StatusCode = 422; Body = @{ error = $_.Exception.Message } }
    }
}

# ═══════════════════════════════════════════════════════════════════════
# CURRENCY
# ═══════════════════════════════════════════════════════════════════════

function Invoke-ApiCreateCurrency {
    <#
        .SYNOPSIS
        Creates a Przedmiot-type entity with currency tags.
    #>

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
        Invoke-SidecarInvalidation -Domain 'entity'
        return @{ StatusCode = 201; Body = $Result }
    } catch {
        return @{ StatusCode = 422; Body = @{ error = $_.Exception.Message } }
    }
}

function Invoke-ApiUpdateCurrency {
    <#
        .SYNOPSIS
        Adjusts currency amount or ownership via Set-CurrencyEntity.
    #>

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
        Invoke-SidecarInvalidation -Domain 'entity'
        return @{ StatusCode = 200; Body = $Result }
    } catch {
        return @{ StatusCode = 422; Body = @{ error = $_.Exception.Message } }
    }
}

# ═══════════════════════════════════════════════════════════════════════
# PLAYERS
# ═══════════════════════════════════════════════════════════════════════

function Invoke-ApiCreatePlayer {
    <#
        .SYNOPSIS
        Creates a new player with optional initial character.
    #>

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
        Invoke-SidecarInvalidation -Domain 'entity'
        return @{ StatusCode = 201; Body = $Result }
    } catch {
        return @{ StatusCode = 422; Body = @{ error = $_.Exception.Message } }
    }
}

function Invoke-ApiCreateCharacter {
    <#
        .SYNOPSIS
        Adds a new character to an existing player.
    #>

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
        Invoke-SidecarInvalidation -Domain 'entity'
        return @{ StatusCode = 201; Body = $Result }
    } catch {
        return @{ StatusCode = 422; Body = @{ error = $_.Exception.Message } }
    }
}

# ═══════════════════════════════════════════════════════════════════════
# SESSIONS
# ═══════════════════════════════════════════════════════════════════════

function Invoke-ApiCreateSession {
    <#
        .SYNOPSIS
        Creates one or more sessions via Add-Session. Supports single session
        (flat body fields) and batch mode (sessions array).
    #>

    [CmdletBinding()] param(
        [Parameter(Mandatory)] [hashtable]$ApiContext
    )

    $B = $ApiContext.Body
    if (-not $B) {
        return @{ StatusCode = 400; Body = @{ error = 'Request body required' } }
    }

    # Batch mode: body contains a "sessions" array
    if ($B.sessions) {
        if (-not $B.path) {
            return @{ StatusCode = 400; Body = @{ error = 'path is required' } }
        }

        $BatchSpecs = [System.Collections.Generic.List[hashtable]]::new()
        foreach ($S in $B.sessions) {
            if (-not $S.title -or -not $S.narrator -or -not $S.date) {
                return @{
                    StatusCode = 400
                    Body = @{ error = 'Each session requires title, narrator, and date' }
                }
            }
            $Spec = @{
                Date     = [datetime]::Parse([string]$S.date)
                Title    = [string]$S.title
                Narrator = [string]$S.narrator
            }
            if ($S.dateEnd)            { $Spec.DateEnd            = [datetime]::Parse([string]$S.dateEnd) }
            if ($S.metadataNarrators)  { $Spec.MetadataNarrators  = @($S.metadataNarrators) }
            if ($S.locations)          { $Spec.Locations          = @($S.locations) }
            if ($S.logs)               { $Spec.Logs               = @($S.logs) }
            if ($S.content)            { $Spec.Content            = [string]$S.content }
            if ($S.pu) {
                $Spec.PU = @($S.pu).ForEach({
                    [PSCustomObject]@{ Character = [string]$_.character; Value = [decimal]$_.value }
                })
            }
            if ($S.changes) {
                $Spec.Changes = @($S.changes).ForEach({
                    [PSCustomObject]@{
                        EntityName = [string]$_.entityName
                        Tags = @($_.tags).ForEach({
                            [PSCustomObject]@{ Tag = [string]$_.tag; Value = [string]$_.value }
                        })
                    }
                })
            }
            if ($S.intel) {
                $Spec.Intel = @($S.intel).ForEach({
                    [PSCustomObject]@{ RawTarget = [string]$_.rawTarget; Message = [string]$_.message }
                })
            }
            if ($S.transfers) {
                $Spec.Transfers = @($S.transfers).ForEach({
                    [PSCustomObject]@{ Amount = [int]($_.amount ?? 1); Denomination = [string]$_.denomination; Source = [string]$_.source; Destination = [string]$_.destination }
                })
            }
            [void]$BatchSpecs.Add($Spec)
        }

        try {
            $Headers = Add-Session -Path @($B.path) -Sessions $BatchSpecs.ToArray() -Confirm:$false
            Invoke-SidecarInvalidation -Domain 'session'
            return @{
                StatusCode = 201
                Body = @{
                    headers = @($Headers)
                    paths   = @($B.path)
                    count   = @($Headers).Count
                }
            }
        } catch {
            return @{ StatusCode = 422; Body = @{ error = $_.Exception.Message } }
        }
    }

    # Single mode: flat body fields
    if (-not $B.title -or -not $B.narrator -or -not $B.date -or -not $B.path) {
        return @{
            StatusCode = 400
            Body = @{ error = 'title, narrator, date, and path are required' }
        }
    }

    try {
        $ParsedDate = [datetime]::Parse([string]$B.date)
    } catch {
        return @{ StatusCode = 400; Body = @{ error = "Invalid date format: $($B.date)" } }
    }

    $Params = @{
        Path     = @($B.path)
        Date     = $ParsedDate
        Title    = [string]$B.title
        Narrator = [string]$B.narrator
        Confirm  = $false
    }

    if ($B.dateEnd) {
        try { $Params.DateEnd = [datetime]::Parse([string]$B.dateEnd) }
        catch { return @{ StatusCode = 400; Body = @{ error = "Invalid dateEnd format: $($B.dateEnd)" } } }
    }
    if ($B.metadataNarrators) { $Params.MetadataNarrators = @($B.metadataNarrators) }
    if ($B.locations)         { $Params.Locations         = @($B.locations) }
    if ($B.logs)              { $Params.Logs              = @($B.logs) }
    if ($B.content)           { $Params.Content           = [string]$B.content }

    if ($B.pu) {
        $Params.PU = @($B.pu).ForEach({
            [PSCustomObject]@{ Character = [string]$_.character; Value = [decimal]$_.value }
        })
    }

    if ($B.changes) {
        $Params.Changes = @($B.changes).ForEach({
            [PSCustomObject]@{
                EntityName = [string]$_.entityName
                Tags = @($_.tags).ForEach({
                    [PSCustomObject]@{ Tag = [string]$_.tag; Value = [string]$_.value }
                })
            }
        })
    }

    if ($B.intel) {
        $Params.Intel = @($B.intel).ForEach({
            [PSCustomObject]@{ RawTarget = [string]$_.rawTarget; Message = [string]$_.message }
        })
    }

    if ($B.transfers) {
        $Params.Transfers = @($B.transfers).ForEach({
            [PSCustomObject]@{ Amount = [int]($_.amount ?? 1); Denomination = [string]$_.denomination; Source = [string]$_.source; Destination = [string]$_.destination }
        })
    }

    try {
        $Headers = Add-Session @Params
        Invoke-SidecarInvalidation -Domain 'session'
        return @{
            StatusCode = 201
            Body = @{
                headers = @($Headers)
                paths   = @($B.path)
            }
        }
    } catch {
        return @{ StatusCode = 422; Body = @{ error = $_.Exception.Message } }
    }
}

# ═══════════════════════════════════════════════════════════════════════
# WORKFLOW
# ═══════════════════════════════════════════════════════════════════════

function Invoke-ApiRebuildGraph {
    <#
        .SYNOPSIS
        Triggers session graph index rebuild via Set-SessionGraph.
    #>

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
        Invoke-SidecarInvalidation -Domain 'graph'
        return @{ StatusCode = 200; Body = $Result }
    } catch {
        return @{ StatusCode = 422; Body = @{ error = $_.Exception.Message } }
    }
}

function Invoke-ApiRebuildHashes {
    <#
        .SYNOPSIS
        Updates session content hashes via Set-SessionHash.
    #>

    param([hashtable]$ApiContext)

    $B      = $ApiContext.Body
    $Params = @{ Confirm = $false; Quiet = $true }

    if ($B) {
        if ($B.full -eq $true) { $Params.Full = $true }
        if ($B.since)          { $Params.Since = [string]$B.since }
    }

    try {
        $Result = Set-SessionHash @Params
        Invoke-SidecarInvalidation -Domain 'session'
        return @{ StatusCode = 200; Body = $Result }
    } catch {
        return @{ StatusCode = 422; Body = @{ error = $_.Exception.Message } }
    }
}

# ═══════════════════════════════════════════════════════════════════════
# LOCATIONS
# ═══════════════════════════════════════════════════════════════════════

function Invoke-ApiCreateLocation {
    <#
        .SYNOPSIS
        Creates a location entity via New-LocationEntity with domain validation.
    #>

    param([hashtable]$ApiContext)

    $B = $ApiContext.Body
    if (-not $B -or -not $B.name) {
        return @{ StatusCode = 400; Body = @{ error = 'name is required' } }
    }
    $Params = @{ Name = [string]$B.name; Confirm = $false }
    if ($B.parent)      { $Params.Parent      = [string]$B.parent }
    if ($B.doors)       { $Params.Doors        = @($B.doors).ForEach({ [string]$_ }) }
    if ($B.coordinates) { $Params.Coordinates  = [string]$B.coordinates }
    if ($B.nerthusName) { $Params.NerthusName   = [string]$B.nerthusName }
    if ($B.margonemIds) { $Params.MargonemIds   = @($B.margonemIds).ForEach({ [int]$_ }) }
    if ($B.validFrom)   { $Params.ValidFrom    = [string]$B.validFrom }
    if ($B.tags -and $B.tags -is [System.Management.Automation.PSCustomObject]) {
        $Tags = @{}
        foreach ($P in $B.tags.PSObject.Properties) { $Tags[$P.Name] = $P.Value }
        $Params.Tags = $Tags
    }
    try {
        $Result = New-LocationEntity @Params
        Clear-ParseCaches
        Invoke-SidecarInvalidation -Domain 'entity'
        return @{ StatusCode = 201; Body = $Result }
    } catch {
        return @{ StatusCode = 422; Body = @{ error = $_.Exception.Message } }
    }
}

function Invoke-ApiUpdateLocation {
    <#
        .SYNOPSIS
        Updates a location entity via Set-LocationEntity with domain validation.
    #>

    param([hashtable]$ApiContext)

    $Name = $ApiContext.PathParams['name']
    $B = $ApiContext.Body
    if (-not $B) {
        return @{ StatusCode = 400; Body = @{ error = 'Request body required' } }
    }
    $Params = @{ Name = $Name; Confirm = $false }
    if ($B.type)        { $Params.Type         = [string]$B.type }
    if ($B.parent)      { $Params.Parent       = [string]$B.parent }
    if ($B.addDoors)    { $Params.AddDoors     = @($B.addDoors).ForEach({ [string]$_ }) }
    if ($B.removeDoors) { $Params.RemoveDoors  = @($B.removeDoors).ForEach({ [string]$_ }) }
    if ($B.coordinates) { $Params.Coordinates  = [string]$B.coordinates }
    if ($B.nerthusName) { $Params.NerthusName   = [string]$B.nerthusName }
    if ($B.validFrom)   { $Params.ValidFrom    = [string]$B.validFrom }
    if ($B.tags -and $B.tags -is [System.Management.Automation.PSCustomObject]) {
        $Tags = @{}
        foreach ($P in $B.tags.PSObject.Properties) { $Tags[$P.Name] = $P.Value }
        $Params.Tags = $Tags
    }
    try {
        $Result = Set-LocationEntity @Params
        Clear-ParseCaches
        Invoke-SidecarInvalidation -Domain 'entity'
        return @{ StatusCode = 200; Body = $Result }
    } catch {
        return @{ StatusCode = 422; Body = @{ error = $_.Exception.Message } }
    }
}

function Invoke-ApiDeleteLocation {
    <#
        .SYNOPSIS
        Soft-deletes a location entity via Remove-Entity.
    #>

    param([hashtable]$ApiContext)

    $Name = $ApiContext.PathParams['name']
    $B = $ApiContext.Body
    $Params = @{ Name = $Name; Type = 'Lokacja'; Confirm = $false }
    if ($B -and $B.validFrom) { $Params.ValidFrom = [string]$B.validFrom }
    try {
        $Result = Remove-Entity @Params
        Clear-ParseCaches
        Invoke-SidecarInvalidation -Domain 'entity'
        return @{ StatusCode = 200; Body = $Result }
    } catch {
        return @{ StatusCode = 422; Body = @{ error = $_.Exception.Message } }
    }
}

function Invoke-ApiCreateMap {
    <#
        .SYNOPSIS
        Creates a map entity via New-MapEntity with domain validation.
    #>

    param([hashtable]$ApiContext)

    $B = $ApiContext.Body
    if (-not $B -or -not $B.name -or -not $B.slug) {
        return @{ StatusCode = 400; Body = @{ error = 'name and slug are required' } }
    }
    $Params = @{ Name = [string]$B.name; Slug = [string]$B.slug; Confirm = $false }
    if ($B.parent)      { $Params.Parent     = [string]$B.parent }
    if ($B.url)         { $Params.Url        = [string]$B.url }
    if ($B.urlNerthus)  { $Params.UrlNerthus = [string]$B.urlNerthus }
    if ($B.dimensions)  { $Params.Dimensions = [string]$B.dimensions }
    if ($B.doors)       { $Params.Doors      = @($B.doors).ForEach({ [string]$_ }) }
    if ($B.info)        { $Params.Info       = [string]$B.info }
    if ($B.validFrom)   { $Params.ValidFrom  = [string]$B.validFrom }
    if ($B.tags -and $B.tags -is [System.Management.Automation.PSCustomObject]) {
        $Tags = @{}
        foreach ($P in $B.tags.PSObject.Properties) { $Tags[$P.Name] = $P.Value }
        $Params.Tags = $Tags
    }
    try {
        $Result = New-MapEntity @Params
        Clear-ParseCaches
        Invoke-SidecarInvalidation -Domain 'entity'
        return @{ StatusCode = 201; Body = $Result }
    } catch {
        return @{ StatusCode = 422; Body = @{ error = $_.Exception.Message } }
    }
}

function Invoke-ApiUpdateMap {
    <#
        .SYNOPSIS
        Updates a map entity via Set-MapEntity with domain validation.
    #>

    param([hashtable]$ApiContext)

    $Name = $ApiContext.PathParams['name']
    $B = $ApiContext.Body
    if (-not $B) {
        return @{ StatusCode = 400; Body = @{ error = 'Request body required' } }
    }
    $Params = @{ Name = $Name; Confirm = $false }
    if ($B.slug)        { $Params.Slug        = [string]$B.slug }
    if ($B.parent)      { $Params.Parent      = [string]$B.parent }
    if ($B.url)         { $Params.Url         = [string]$B.url }
    if ($B.urlNerthus)  { $Params.UrlNerthus  = [string]$B.urlNerthus }
    if ($B.dimensions)  { $Params.Dimensions  = [string]$B.dimensions }
    if ($B.info)        { $Params.Info        = [string]$B.info }
    if ($B.addDoors)    { $Params.AddDoors    = @($B.addDoors).ForEach({ [string]$_ }) }
    if ($B.removeDoors) { $Params.RemoveDoors = @($B.removeDoors).ForEach({ [string]$_ }) }
    if ($B.validFrom)   { $Params.ValidFrom   = [string]$B.validFrom }
    if ($B.tags -and $B.tags -is [System.Management.Automation.PSCustomObject]) {
        $Tags = @{}
        foreach ($P in $B.tags.PSObject.Properties) { $Tags[$P.Name] = $P.Value }
        $Params.Tags = $Tags
    }
    try {
        $Result = Set-MapEntity @Params
        Clear-ParseCaches
        Invoke-SidecarInvalidation -Domain 'entity'
        return @{ StatusCode = 200; Body = $Result }
    } catch {
        return @{ StatusCode = 422; Body = @{ error = $_.Exception.Message } }
    }
}
