<#
    .SYNOPSIS
    REST handlers for the WP-7 migration control plane.

    .DESCRIPTION
    Each handler accepts [hashtable]$ApiContext (the project's standard handler
    signature) with PathParams, QueryParams, Body, Method, Path, TokenName,
    TokenScopes fields.

    Route namespace decision:
    The existing static C# route /schema serves the domain name dictionary
    (api-routes.ps1). To avoid conflict, this file's /schema-* endpoints live
    under /schema/version, /schema/lock, /schema/restore.

    Helpers:
    - Invoke-ApiGetSchemaVersion:    GET /schema/version
    - Invoke-ApiGetMigrations:       GET /migrations
    - Invoke-ApiGetPendingMigrations: GET /migrations/pending
    - Invoke-ApiGetMigration:        GET /migrations/:id
    - Invoke-ApiGetMigrationPreview: GET /migrations/:id/preview
    - Invoke-ApiPostMigrationApply:  POST /migrations/apply
    - Invoke-ApiDeleteSchemaLock:    DELETE /schema/lock
    - Invoke-ApiPostSchemaRestore:   POST /schema/restore
    - Invoke-ApiGetMigrationJob:     GET /migrations/jobs/:jobId
#>

function Resolve-MigrationFromRoute {
    <#
        .SYNOPSIS
        Resolves a migration by id (slug or full id) from the catalog.
    #>
    param([string]$IdOrVersion)

    $Catalog = Get-MigrationCatalog
    $Match = $Catalog | Where-Object {
        $_.Id -eq $IdOrVersion -or
        $_.Version -eq $IdOrVersion -or
        $_.Slug -eq $IdOrVersion
    } | Select-Object -First 1
    return $Match
}

function Read-ApiJsonBody {
    param($Body)
    if (-not $Body) { return $null }
    if ($Body -is [string]) {
        if ([string]::IsNullOrWhiteSpace($Body)) { return $null }
        try { return $Body | ConvertFrom-Json } catch {
            throw "Invalid JSON body: $($_.Exception.Message)"
        }
    }
    return $Body     # already parsed by middleware
}

function Invoke-ApiGetSchemaVersion {
    param([hashtable]$ApiContext)
    $Schema = Get-SchemaVersion
    $State = Get-SchemaState
    return [PSCustomObject]@{
        current        = $Schema.Current
        majorName      = $Schema.MajorName
        supportedRange = @{ min = $State.SupportedMin; max = $State.SupportedMax }
        mode           = $State.Mode
        pendingCount   = $State.PendingCount
        lockedBy       = $Schema.LockedBy
        lockedAt       = $Schema.LockedAt
        lockStale      = $Schema.LockStale
        appliedAt      = $Schema.AppliedAt
        appliedBy      = $Schema.AppliedBy
        history        = @($Schema.History)
    }
}

function Invoke-ApiGetMigrations {
    param([hashtable]$ApiContext)
    return @(Get-Migration -IncludeInvalid)
}

function Invoke-ApiGetPendingMigrations {
    param([hashtable]$ApiContext)
    return @(Get-Migration -Pending)
}

function Invoke-ApiGetMigration {
    param([hashtable]$ApiContext)
    $Id = $ApiContext.PathParams['id']
    $M = Resolve-MigrationFromRoute -IdOrVersion $Id
    if (-not $M) {
        return @{ status = 404; body = @{ error = 'migration-not-found'; id = $Id } }
    }
    return $M
}

function Invoke-ApiGetMigrationPreview {
    param([hashtable]$ApiContext)
    $Id = $ApiContext.PathParams['id']
    $M = Resolve-MigrationFromRoute -IdOrVersion $Id
    if (-not $M) {
        return @{ status = 404; body = @{ error = 'migration-not-found'; id = $Id } }
    }
    $AllowNet = $false
    if ($ApiContext.QueryParams -and $ApiContext.QueryParams['allowNetwork'] -eq 'true') {
        $AllowNet = $true
    }
    try {
        return Get-MigrationPreview -Version $M.Version -AllowNetworkInPreview:$AllowNet
    } catch {
        return @{ status = 500; body = @{ error = 'preview-failed'; message = $_.Exception.Message } }
    }
}

function Invoke-ApiPostMigrationApply {
    param([hashtable]$ApiContext)

    $Body = $null
    try { $Body = Read-ApiJsonBody $ApiContext.Body } catch {
        return @{ status = 400; body = @{ error = 'invalid-json'; message = $_.Exception.Message } }
    }
    if (-not $Body -or -not $Body.target) {
        return @{ status = 400; body = @{ error = 'missing-target' } }
    }

    $TargetId      = $Body.target.id
    $TargetVersion = $Body.target.version
    $Mode          = if ($Body.mode) { $Body.mode } else { 'sync' }
    $BranchMode    = if ($Body.branchMode) { $Body.branchMode } else { 'InPlace' }
    $AllowUnsigned = [bool]$Body.allowUnsigned
    $AllowNetwork  = [bool]$Body.allowNetwork

    $M = $null
    if ($TargetId) {
        $M = Resolve-MigrationFromRoute -IdOrVersion $TargetId
        if (-not $M) {
            return @{ status = 404; body = @{ error = 'migration-not-found'; id = $TargetId } }
        }
        if ($Mode -eq 'sync' -and $M.EstimatedDurationSec -gt 10) {
            return @{
                status = 409
                body = @{ error = 'duration-exceeds-sync-limit'
                         estimatedSec = $M.EstimatedDurationSec
                         hint = 'Re-submit with mode=async' }
            }
        }
    } elseif (-not $TargetVersion) {
        return @{ status = 400; body = @{ error = 'target-requires-id-or-version' } }
    }

    $Schema = Get-SchemaVersion
    if ($Schema.LockedBy) {
        return @{
            status = 409
            body = @{ error = 'schema-locked'; lockedBy = $Schema.LockedBy
                     lockedAt = $Schema.LockedAt; lockStale = $Schema.LockStale }
        }
    }

    if ($Mode -eq 'async') {
        if (Get-Command 'Start-ApiMigrationJob' -ErrorAction SilentlyContinue) {
            $JobId = Start-ApiMigrationJob -Target $Body.target -BranchMode $BranchMode `
                -AllowUnsigned:$AllowUnsigned -AllowNetwork:$AllowNetwork
            return @{ status = 202; body = @{ jobId = $JobId; statusUrl = "/migrations/jobs/$JobId" } }
        }
        return @{ status = 501; body = @{ error = 'async-not-yet-implemented' } }
    }

    try {
        if ($TargetId) {
            return Invoke-Migration -Version $M.Version -BranchMode $BranchMode `
                -AllowUnsigned:$AllowUnsigned -Confirm:$false
        }
        return Invoke-MigrationChain -To $TargetVersion -BranchMode $BranchMode `
            -AllowUnsigned:$AllowUnsigned -Confirm:$false
    } catch {
        $Eid = $_.FullyQualifiedErrorId
        if ($Eid -like '*UnsignedMigrationBlocked*') {
            return @{ status = 422; body = @{ error = 'unsigned-migration-blocked' } }
        }
        if ($Eid -like '*PrerequisiteNotMet*') {
            return @{ status = 422; body = @{ error = 'prerequisite-not-met'; message = $_.Exception.Message } }
        }
        if ($Eid -like '*WorkingTreeDirty*') {
            return @{ status = 409; body = @{ error = 'working-tree-dirty' } }
        }
        return @{ status = 500; body = @{ error = 'apply-failed'; message = $_.Exception.Message } }
    }
}

function Invoke-ApiDeleteSchemaLock {
    param([hashtable]$ApiContext)
    try {
        return Reset-MigrationLock -Force -Confirm:$false
    } catch {
        return @{ status = 500; body = @{ error = 'unlock-failed'; message = $_.Exception.Message } }
    }
}

function Invoke-ApiPostSchemaRestore {
    param([hashtable]$ApiContext)
    $Body = $null
    try { $Body = Read-ApiJsonBody $ApiContext.Body } catch {
        return @{ status = 400; body = @{ error = 'invalid-json' } }
    }
    if (-not $Body -or -not $Body.to) {
        return @{ status = 400; body = @{ error = 'missing-to' } }
    }
    try {
        return Reset-SchemaVersion -To $Body.to -Reason $Body.reason -Confirm:$false
    } catch {
        if ($_.FullyQualifiedErrorId -like '*VersionNotInHistory*') {
            $Schema = Get-SchemaVersion
            return @{
                status = 422
                body = @{ error = 'version-not-in-history'
                         available = @($Schema.History | ForEach-Object { $_.version }) }
            }
        }
        return @{ status = 500; body = @{ error = 'restore-failed'; message = $_.Exception.Message } }
    }
}

function Invoke-ApiGetMigrationJob {
    param([hashtable]$ApiContext)
    $JobId = $ApiContext.PathParams['jobId']
    if (Get-Command 'Get-ApiMigrationJob' -ErrorAction SilentlyContinue) {
        $J = Get-ApiMigrationJob -Id $JobId
        if (-not $J) { return @{ status = 404; body = @{ error = 'job-not-found' } } }
        return $J
    }
    return @{ status = 501; body = @{ error = 'async-not-yet-implemented' } }
}
