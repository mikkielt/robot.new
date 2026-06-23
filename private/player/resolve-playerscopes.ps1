<#
    .SYNOPSIS
    Resolves the effective scope list for a Margonem-authenticated player.

    .DESCRIPTION
    Today this returns the supplied DefaultScopes unchanged — there is no
    per-player scope overlay. The function exists so that future RBAC/ABAC
    work (out of scope for the current Margonem-auth plan; likely a new
    structured Player property or a role-table file) can plug in by
    replacing this body without touching Invoke-ApiAuthMargonem.

    The seam is intentionally narrow: it accepts a Player and the default
    list, returns the granted list. Anything richer (e.g. context-aware
    scope decisions per request) should be a NEW helper, not a widening
    of this one.

    Consumers: Invoke-ApiAuthMargonem (POST /auth/margonem).
#>

function Resolve-PlayerScopes {
    [CmdletBinding()] param(
        [Parameter(Mandatory)] $Player,
        [Parameter(Mandatory)] [string[]]$DefaultScopes
    )
    return $DefaultScopes
}
