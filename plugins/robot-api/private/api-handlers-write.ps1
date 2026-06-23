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

function Invoke-ApiDeleteCurrency {
    <#
        .SYNOPSIS
        Soft-deletes a currency entity via Remove-CurrencyEntity. When the
        entity has a non-zero balance, the backing function still proceeds
        and warns; the handler surfaces that warning in the response body
        by checking the balance before delegating.
    #>

    param([hashtable]$ApiContext)

    $Name = $ApiContext.PathParams['name']
    $QP   = $ApiContext.QueryParams

    $Warning = $null
    try {
        $Existing = @(Get-CurrencyEntity -Name $Name -IncludeInactive -ErrorAction SilentlyContinue)
        if ($Existing.Count -gt 0 -and $Existing[0].Balance -ne 0) {
            $Warning = "Currency '$Name' still has a non-zero balance ($($Existing[0].Balance)) at deletion."
        }
    } catch {
        # Balance lookup is best-effort; failures should not block delete.
    }

    $Params = @{ Name = $Name; Confirm = $false; Quiet = $true }
    if ($QP['validFrom']) { $Params.ValidFrom = [string]$QP['validFrom'] }

    try {
        $Result = Remove-CurrencyEntity @Params
        Clear-ParseCaches
        Invoke-SidecarInvalidation -Domain 'entity'
        $Body = if ($Warning) {
            [PSCustomObject]@{ result = $Result; warning = $Warning }
        } else {
            $Result
        }
        return @{ StatusCode = 200; Body = $Body }
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

function Invoke-ApiUpdatePlayer {
    <#
        .SYNOPSIS
        Updates player metadata (MargonemID, webhook, triggers, aliases, status)
        via Set-Player. Fields omitted from the body are preserved.
    #>

    param([hashtable]$ApiContext)

    $Name = $ApiContext.PathParams['name']
    $B    = $ApiContext.Body
    if (-not $B) {
        return @{ StatusCode = 400; Body = @{ error = 'Request body required' } }
    }

    $Params = @{ Name = $Name; Confirm = $false }
    if ($B.margonemId) { $Params.MargonemID = [string]$B.margonemId }
    if ($B.prfWebhook) { $Params.PRFWebhook = [string]$B.prfWebhook }
    if ($B.triggers)   { $Params.Triggers   = @($B.triggers).ForEach({ [string]$_ }) }
    if ($B.aliases)    { $Params.Aliases    = @($B.aliases).ForEach({ [string]$_ }) }
    if ($B.status)     { $Params.Status     = [string]$B.status }

    try {
        $Result = Set-Player @Params
        Clear-ParseCaches
        Invoke-SidecarInvalidation -Domain 'entity'
        return @{ StatusCode = 200; Body = $Result }
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

function Invoke-ApiUpdateCharacter {
    <#
        .SYNOPSIS
        Updates a character's PU, reputation, profile or status via
        Set-PlayerCharacter. Nullable decimal PU fields are distinguished
        from omission so that a body containing `"puExceeded": null` is
        treated as "clear", not "leave unchanged".
    #>

    param([hashtable]$ApiContext)

    $PlayerName    = $ApiContext.PathParams['name']
    $CharacterName = $ApiContext.PathParams['character']
    $B             = $ApiContext.Body
    if (-not $B) {
        return @{ StatusCode = 400; Body = @{ error = 'Request body required' } }
    }

    $Params = @{
        PlayerName    = $PlayerName
        CharacterName = $CharacterName
        Confirm       = $false
        Quiet         = $true
    }

    # PU fields are Nullable[decimal] in Set-PlayerCharacter; null/omitted
    # bodies both mean "preserve". Pass only when a non-null value is given.
    if ($null -ne $B.puExceeded) { $Params.PUExceeded = [decimal]$B.puExceeded }
    if ($null -ne $B.puStart)    { $Params.PUStart    = [decimal]$B.puStart }
    if ($null -ne $B.puSum)      { $Params.PUSum      = [decimal]$B.puSum }
    if ($null -ne $B.puTaken)    { $Params.PUTaken    = [decimal]$B.puTaken }

    if ($B.aliases)            { $Params.Aliases          = @($B.aliases).ForEach({ [string]$_ }) }
    if ($B.status)             { $Params.Status           = [string]$B.status }
    if ($B.filePath)           { $Params.FilePath         = [string]$B.filePath }
    if ($B.characterSheet)     { $Params.CharacterSheet   = [string]$B.characterSheet }
    if ($B.restrictedTopics)   { $Params.RestrictedTopics = [string]$B.restrictedTopics }
    if ($B.condition)          { $Params.Condition        = [string]$B.condition }
    if ($B.specialItems)       { $Params.SpecialItems     = @($B.specialItems).ForEach({ [string]$_ }) }
    if ($B.reputationPositive) { $Params.ReputationPositive = @($B.reputationPositive) }
    if ($B.reputationNeutral)  { $Params.ReputationNeutral  = @($B.reputationNeutral)  }
    if ($B.reputationNegative) { $Params.ReputationNegative = @($B.reputationNegative) }
    if ($B.additionalNotes)    { $Params.AdditionalNotes  = @($B.additionalNotes).ForEach({ [string]$_ }) }

    try {
        $Result = Set-PlayerCharacter @Params
        Clear-ParseCaches
        Invoke-SidecarInvalidation -Domain 'entity'
        return @{ StatusCode = 200; Body = $Result }
    } catch {
        return @{ StatusCode = 422; Body = @{ error = $_.Exception.Message } }
    }
}

function Invoke-ApiDeleteCharacter {
    <#
        .SYNOPSIS
        Soft-deletes a character via Remove-PlayerCharacter. Optional
        ?validFrom=YYYY-MM query parameter sets the deletion month;
        otherwise the current month is used by the backing function.
    #>

    param([hashtable]$ApiContext)

    $PlayerName    = $ApiContext.PathParams['name']
    $CharacterName = $ApiContext.PathParams['character']
    $QP            = $ApiContext.QueryParams

    $Params = @{
        PlayerName    = $PlayerName
        CharacterName = $CharacterName
        Confirm       = $false
    }
    if ($QP['validFrom']) { $Params.ValidFrom = [string]$QP['validFrom'] }

    try {
        $Result = Remove-PlayerCharacter @Params
        Clear-ParseCaches
        Invoke-SidecarInvalidation -Domain 'entity'
        return @{ StatusCode = 200; Body = $Result }
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
            if ($S.files) { $Spec.Files = @($S.files) }
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

function Invoke-ApiUpdateSession {
    <#
        .SYNOPSIS
        Updates an existing session via Set-Session. The target session is
        identified by `date` (YYYY-MM-DD) and `file` (repo-relative path)
        in the body — these map to Set-Session's `Explicit` parameter set.
        Optional `locations`, `pu`, `logs`, `changes`, `narrator`, `intel`,
        `content`, `properties`, `dateOverride`, and `upgradeFormat` are
        forwarded as-is. Sessions are full-replace on metadata, so callers
        MUST send the complete intended state for each array field they
        wish to modify.
    #>

    param([hashtable]$ApiContext)

    $B = $ApiContext.Body
    if (-not $B) {
        return @{ StatusCode = 400; Body = @{ error = 'Request body required' } }
    }
    if (-not $B.date -or -not $B.file) {
        return @{ StatusCode = 400; Body = @{ error = 'date and file are required to identify the session' } }
    }

    $Params = @{
        Date    = [datetime]::Parse([string]$B.date)
        File    = [string]$B.file
        Confirm = $false
    }

    if ($B.locations) { $Params.Locations = @($B.locations).ForEach({ [string]$_ }) }
    if ($B.logs)      { $Params.Logs      = @($B.logs).ForEach({ [string]$_ }) }
    if ($B.narrator)  { $Params.Narrator  = @($B.narrator).ForEach({ [string]$_ }) }
    if ($B.pu)        { $Params.PU        = @($B.pu) }
    if ($B.changes)   { $Params.Changes   = @($B.changes) }
    if ($B.intel)     { $Params.Intel     = @($B.intel) }
    if ($B.content)        { $Params.Content      = [string]$B.content }
    if ($B.dateOverride)   { $Params.DateOverride = [string]$B.dateOverride }
    if ($B.upgradeFormat -eq $true) { $Params.UpgradeFormat = $true }

    if ($B.properties -and $B.properties -is [System.Management.Automation.PSCustomObject]) {
        $Props = @{}
        foreach ($P in $B.properties.PSObject.Properties) { $Props[$P.Name] = $P.Value }
        $Params.Properties = $Props
    }

    try {
        $Result = Set-Session @Params
        Clear-ParseCaches
        Invoke-SidecarInvalidation -Domain 'session'
        Invoke-SidecarInvalidation -Domain 'graph'
        Invoke-SidecarInvalidation -Domain 'entity'
        return @{ StatusCode = 200; Body = $Result }
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

function Invoke-ApiRebuildNameIndex {
    <#
        .SYNOPSIS
        Force-rebuilds the module's cached name index. Returns build duration
        and index stats. Companion to /workflow/session-graph and
        /workflow/session-hash.
    #>

    [CmdletBinding()] param(
        [Parameter(Mandatory)] [hashtable]$ApiContext
    )

    $Stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        # Drop in-memory caches so the rebuild sees fresh entity/player data
        Clear-ParseCaches

        $Entities = Get-Entity -Quiet
        $Players  = Get-Player
        $Idx      = Get-NameIndex -Entities $Entities -Players $Players
    } catch {
        return @{ StatusCode = 422; Body = @{ error = "Failed to rebuild name index: $($_.Exception.Message)" } }
    }
    $Stopwatch.Stop()

    # Single-pass scan for ambiguous tokens
    $AmbiguousCount = 0
    foreach ($KV in $Idx.Index.GetEnumerator()) {
        if ($KV.Value.Ambiguous) { $AmbiguousCount++ }
    }

    return @{
        StatusCode = 200
        Body = [ordered]@{
            rebuiltAt  = [datetime]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss")
            buildMs    = [int]$Stopwatch.ElapsedMilliseconds
            indexStats = [ordered]@{
                tokenCount     = $Idx.Index.Count
                stemCount      = $Idx.StemIndex.Count
                ambiguousCount = $AmbiguousCount
            }
        }
    }
}

function Invoke-ApiRunLogFetch {
    <#
        .SYNOPSIS
        Fetches missing session logs via Invoke-SessionLogFetch. Runs
        synchronously in the worker — large repos may take minutes. The
        function deduplicates URLs, honors .failed markers (unless
        retryFailed=true), and applies exponential backoff on retries.
    #>

    param([hashtable]$ApiContext)

    $B = $ApiContext.Body
    $Params = @{ Confirm = $false }

    if ($B) {
        if ($B.minDate)      { $Params.MinDate      = [datetime]::Parse([string]$B.minDate) }
        if ($B.maxDate)      { $Params.MaxDate      = [datetime]::Parse([string]$B.maxDate) }
        if ($null -ne $B.delayMs)      { $Params.DelayMs      = [int]$B.delayMs }
        if ($null -ne $B.maxRetries)   { $Params.MaxRetries   = [int]$B.maxRetries }
        if ($null -ne $B.retryDelayMs) { $Params.RetryDelayMs = [int]$B.retryDelayMs }
        if ($B.retryFailed -eq $true)  { $Params.RetryFailed  = $true }
        if ($B.logDirectory)           { $Params.LogDirectory = [string]$B.logDirectory }
    }

    try {
        $Summary = Invoke-SessionLogFetch @Params
        Invoke-SidecarInvalidation -Domain 'session'
        return @{ StatusCode = 200; Body = $Summary }
    } catch {
        return @{ StatusCode = 422; Body = @{ error = $_.Exception.Message } }
    }
}

function Invoke-ApiRunPuAssignment {
    <#
        .SYNOPSIS
        Runs the monthly PU assignment workflow via
        Invoke-PlayerCharacterPUAssignment. Fail-early — if any character
        name does not resolve, no writes happen. Body flags
        (updatePlayerCharacters, sendToDiscord, appendToLog,
        reconcileCurrency) are forwarded as switches.
    #>

    param([hashtable]$ApiContext)

    $B = $ApiContext.Body
    $Params = @{ Confirm = $false }

    if ($B) {
        if ($null -ne $B.year)  { $Params.Year  = [int]$B.year }
        if ($null -ne $B.month) { $Params.Month = [int]$B.month }
        if ($B.minDate)         { $Params.MinDate = [datetime]::Parse([string]$B.minDate) }
        if ($B.maxDate)         { $Params.MaxDate = [datetime]::Parse([string]$B.maxDate) }
        if ($B.playerName)      { $Params.PlayerName = @($B.playerName).ForEach({ [string]$_ }) }
        if ($B.updatePlayerCharacters -eq $true) { $Params.UpdatePlayerCharacters = $true }
        if ($B.sendToDiscord           -eq $true) { $Params.SendToDiscord         = $true }
        if ($B.appendToLog             -eq $true) { $Params.AppendToLog           = $true }
        if ($B.reconcileCurrency       -eq $true) { $Params.ReconcileCurrency     = $true }
        if ($B.excludeDirectory) { $Params.ExcludeDirectory = @($B.excludeDirectory).ForEach({ [string]$_ }) }
    }

    try {
        $Result = @(Invoke-PlayerCharacterPUAssignment @Params)
        Clear-ParseCaches
        # PU assignment may write entities, sessions, and refresh graphs; bump all three.
        Invoke-SidecarInvalidation -Domain 'entity'
        Invoke-SidecarInvalidation -Domain 'session'
        Invoke-SidecarInvalidation -Domain 'graph'
        return @{
            StatusCode = 200
            Body       = @{ count = $Result.Count; items = $Result }
        }
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
