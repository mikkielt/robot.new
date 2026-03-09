<#
    .SYNOPSIS
    Currency reconciliation checks - flags discrepancies in currency tracking.

    .DESCRIPTION
    Runs five validation checks against currency entities:
    1. Negative balance detection
    2. Stale balance warning (no changes in >3 months for owned currencies)
    3. Orphaned currency (owner entity is Nieaktywny/Usunięty)
    4. Symmetric transaction check (per-session denomination deltas sum to zero)
    5. Total supply tracking per denomination

    Designed to run as part of the monthly PU assignment workflow or standalone.
    Dot-sources currency-helpers.ps1 for denomination constants and identification.
#>

. "$script:ModuleRoot/private/currency-helpers.ps1"

function Test-CurrencyReconciliation {
    <#
        .SYNOPSIS
        Report command that flags currency discrepancies.
    #>

    [CmdletBinding()] param(
        [Parameter(HelpMessage = "Pre-fetched entity list from Get-EntityState")]
        [object[]]$Entities,

        [Parameter(HelpMessage = "Pre-fetched session list from Get-Session")]
        [object[]]$Sessions,

        [Parameter(HelpMessage = "Only check changes since this date")]
        [datetime]$Since
    )

    if (-not $PSBoundParameters.ContainsKey('Entities')) {
        $Entities = Get-EntityState
    }
    if (-not $PSBoundParameters.ContainsKey('Sessions')) {
        $Sessions = Get-Session
    }

    $Warnings = [System.Collections.Generic.List[object]]::new()
    $Now = [datetime]::Now

    # Collect all currency entities with enriched data (include all statuses for per-check filtering)
    $CurrencyItems = Get-CurrencyEntitiesFiltered -Entities $Entities -IncludeInactive -IncludeDeleted

    # Build entity status lookup for orphan check
    $EntityStatusByName = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($Entity in $Entities) {
        $Status = if ($Entity.Status) { $Entity.Status } else { 'Aktywny' }
        $EntityStatusByName[$Entity.Name] = $Status
    }

    # Check 1: Negative balance detection
    foreach ($Item in $CurrencyItems) {
        if ($Item.Status -eq 'Usunięty') { continue }

        if ($Item.Quantity -lt 0) {
            $Warnings.Add([PSCustomObject]@{
                Check      = 'NegativeBalance'
                Severity   = 'Error'
                Entity     = $Item.Entity.Name
                Detail     = "Balance is $($Item.Quantity)"
            })
        }
    }

    # Check 2: Stale balance warning
    $StaleThreshold = $Now.AddMonths(-3)
    foreach ($Item in $CurrencyItems) {
        if ($Item.Status -ne 'Aktywny') { continue }
        if (-not $Item.Owner) { continue }

        $LastChangeDate = $null
        if ($Item.Entity.QuantityHistory -and $Item.Entity.QuantityHistory.Count -gt 0) {
            $LastEntry = $Item.Entity.QuantityHistory[-1]
            $LastChangeDate = $LastEntry.ValidFrom
        }

        if ($LastChangeDate -and $LastChangeDate -lt $StaleThreshold) {
            $Warnings.Add([PSCustomObject]@{
                Check      = 'StaleBalance'
                Severity   = 'Warning'
                Entity     = $Item.Entity.Name
                Detail     = "Last change on $($LastChangeDate.ToString('yyyy-MM-dd')), owner: $($Item.Owner)"
            })
        }
    }

    # Check 3: Orphaned currency
    foreach ($Item in $CurrencyItems) {
        if ($Item.Status -ne 'Aktywny') { continue }
        if (-not $Item.Owner) { continue }

        if ($EntityStatusByName.ContainsKey($Item.Owner)) {
            $OwnerStatus = $EntityStatusByName[$Item.Owner]
            if ($OwnerStatus -eq 'Usunięty' -or $OwnerStatus -eq 'Nieaktywny') {
                $Warnings.Add([PSCustomObject]@{
                    Check      = 'OrphanedCurrency'
                    Severity   = 'Warning'
                    Entity     = $Item.Entity.Name
                    Detail     = "Owner '$($Item.Owner)' has status '$OwnerStatus'"
                })
            }
        }
    }

    # Check 4: Symmetric transaction check (per-session per-denomination deltas should sum to zero)
    foreach ($Session in $Sessions) {
        if ($null -eq $Session.Date) { continue }
        if ($Since -and $Session.Date -lt $Since) { continue }
        if (-not $Session.Changes -or $Session.Changes.Count -eq 0) { continue }

        # Track deltas per denomination within this session
        $DenomDeltas = [System.Collections.Generic.Dictionary[string, int]]::new([System.StringComparer]::OrdinalIgnoreCase)

        foreach ($Change in $Session.Changes) {
            # Find matching enriched currency item
            $MatchItem = $null
            foreach ($Item in $CurrencyItems) {
                if ([string]::Equals($Item.Entity.Name, $Change.EntityName, [System.StringComparison]::OrdinalIgnoreCase)) {
                    $MatchItem = $Item
                    break
                }
            }
            if (-not $MatchItem) { continue }

            # Find @ilość tag in changes
            foreach ($TagEntry in $Change.Tags) {
                if ($TagEntry.Tag -ne '@ilość') { continue }
                $ValText = $TagEntry.Value.Trim()
                # Only count explicit deltas (+N/-N), not absolute values
                if ($ValText -match '^[+-]\d+$') {
                    $Delta = [int]$ValText
                    if (-not $DenomDeltas.ContainsKey($MatchItem.Denomination.Name)) {
                        $DenomDeltas[$MatchItem.Denomination.Name] = 0
                    }
                    $DenomDeltas[$MatchItem.Denomination.Name] += $Delta
                }
            }
        }

        # Also check @Transfer directives (these are inherently symmetric by construction,
        # but included for completeness if transfers exist alongside manual deltas)
        # Transfers are +N/-N by design, so they always net to 0 - skip checking them.

        foreach ($Entry in $DenomDeltas.GetEnumerator()) {
            if ($Entry.Value -ne 0) {
                $Warnings.Add([PSCustomObject]@{
                    Check      = 'AsymmetricTransaction'
                    Severity   = 'Warning'
                    Entity     = $Session.Header
                    Detail     = "Denomination '$($Entry.Key)' has net delta of $($Entry.Value) (expected 0)"
                })
            }
        }
    }

    # Check 5: Total supply tracking per denomination
    $Supply = [System.Collections.Generic.Dictionary[string, int]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($Item in $CurrencyItems) {
        if ($Item.Status -eq 'Usunięty') { continue }

        if (-not $Supply.ContainsKey($Item.Denomination.Name)) {
            $Supply[$Item.Denomination.Name] = 0
        }
        $Supply[$Item.Denomination.Name] += $Item.Quantity
    }

    return [PSCustomObject]@{
        Warnings     = @($Warnings)
        WarningCount = $Warnings.Count
        Supply       = $Supply
        EntityCount  = $CurrencyItems.Count
        CheckedAt    = $Now
    }
}
