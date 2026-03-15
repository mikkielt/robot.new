<#
    .SYNOPSIS
    Currency reconciliation checks - flags discrepancies in currency tracking.

    .DESCRIPTION
    Runs seven validation checks against currency entities and session
    transaction data:

    1. NegativeBalance:        active currency with quantity < 0 (Error)
    2. StaleBalance:           owned currency with no quantity change in
                               >3 months (Warning)
    3. OrphanedCurrency:       active currency whose owner entity is
                               Nieaktywny or Usunięty (Warning; physical
                               items flagged for coordinator return)
    4. AsymmetricTransaction:  per-session per-denomination @ilość deltas
                               that don't sum to zero, indicating an
                               unbalanced manual edit (Warning)
    5. TotalSupplyTracking:    aggregate supply per denomination (Info)
    6. PhysicalSupplyTracking: Postać-owned supply per denomination (Info)
    7. VirtualSupplyTracking:  NPC/Grupa/Gracz-owned supply per
                               denomination (Info)

    Pipeline:
    1. Build entity name lookup for owner type classification
    2. Collect all currency entities via Get-CurrencyEntitiesFiltered
       (including inactive/deleted for per-check filtering)
    3. Run checks 1-3 against currency entities
    4. Run check 4 by scanning session Changes for @ilość delta patterns,
       using a pre-built O(1) name-to-currency dictionary
    5. Run checks 5-7 by aggregating quantities into supply dictionaries

    The O(1) CurrencyByName dictionary (check 4) avoids O(n*m) nested
    scanning where n=sessions and m=currency items. Only explicit delta
    values (+N/-N) are counted; absolute values are ignored because they
    represent balance snapshots, not transfers.

    @Transfer directives are inherently symmetric by construction and are
    not included in the asymmetric check.

    Designed to run as part of the monthly PU assignment workflow or
    standalone via CLI.
#>

. "$script:ModuleRoot/private/currency-helpers.ps1"

function Test-CurrencyReconciliation {
    <#
        .SYNOPSIS
        Validates currency entity integrity and flags balance discrepancies.
    #>

    [CmdletBinding()] param(
        [Parameter(HelpMessage = "Pre-fetched entity list from Get-EntityState")]
        [object[]]$Entities,

        [Parameter(HelpMessage = "Pre-fetched session list from Get-Session")]
        [object[]]$Sessions,

        [Parameter(HelpMessage = "Only check changes since this date")]
        [datetime]$Since,

        [Parameter(HelpMessage = "Optional callback for CLI progress reporting (receives Current, Total, ItemDetail)")]
        [scriptblock]$ProgressCallback,

        [Parameter(HelpMessage = "Suppress warning output to stderr")]
        [switch]$Quiet
    )

    $PrevSuppress = $script:SuppressWarnings
    if ($Quiet) { $script:SuppressWarnings = $true }
    try {

    if (-not $PSBoundParameters.ContainsKey('Entities')) {
        $Entities = Get-EntityState
    }
    if (-not $PSBoundParameters.ContainsKey('Sessions')) {
        $Sessions = Get-Session
    }

    $Warnings = [System.Collections.Generic.List[object]]::new()
    $Now = [datetime]::Now

    # O(1) name-to-entity lookup for classifying currency owners by type
    $EntityLookup = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($Entity in $Entities) {
        foreach ($Name in $Entity.Names) {
            if (-not $EntityLookup.ContainsKey($Name)) {
                $EntityLookup[$Name] = $Entity
            }
        }
    }

    # Include all statuses so each check can apply its own status filter
    $CurrencyItems = Get-CurrencyEntitiesFiltered -Entities $Entities -IncludeInactive -IncludeDeleted -EntityLookup $EntityLookup

    # Separate status lookup keyed by primary name for orphan detection
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
    $StaleThreshold = $Now.AddMonths(-3)  # 3-month inactivity threshold for owned currencies
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

    # Check 3: Orphaned currency — physical items need explicit coordinator return
    foreach ($Item in $CurrencyItems) {
        if ($Item.Status -ne 'Aktywny') { continue }
        if (-not $Item.Owner) { continue }

        if ($EntityStatusByName.ContainsKey($Item.Owner)) {
            $OwnerStatus = $EntityStatusByName[$Item.Owner]
            if ($OwnerStatus -eq 'Usunięty' -or $OwnerStatus -eq 'Nieaktywny') {
                $OwnerCat = if ($Item.OwnerCategory) { $Item.OwnerCategory } else { 'Unknown' }
                $Detail = "Owner '$($Item.Owner)' has status '$OwnerStatus'"
                if ($OwnerCat -eq 'Physical') {
                    $Detail += ' — physical items need return to coordinators'
                }
                $Warnings.Add([PSCustomObject]@{
                    Check         = 'OrphanedCurrency'
                    Severity      = 'Warning'
                    Entity        = $Item.Entity.Name
                    Detail        = $Detail
                    OwnerCategory = $OwnerCat
                })
            }
        }
    }

    # Check 4: Symmetric transaction check — manual @ilość deltas should net to zero per denomination
    # Pre-build O(1) lookup from entity name to currency item (avoids O(n*m) nested scan)
    $CurrencyByName = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($Item in $CurrencyItems) {
        if (-not $CurrencyByName.ContainsKey($Item.Entity.Name)) {
            $CurrencyByName[$Item.Entity.Name] = $Item
        }
    }

    $script:ProgressSessIdx = 0
    $script:ProgressSessTotal = $Sessions.Count

    foreach ($Session in $Sessions) {
        $script:ProgressSessIdx++
        if ($ProgressCallback -and ($script:ProgressSessIdx % 10 -eq 0 -or $script:ProgressSessIdx -eq $script:ProgressSessTotal)) {
            & $ProgressCallback $script:ProgressSessIdx $script:ProgressSessTotal $null
        }

        if ($null -eq $Session.Date) { continue }
        if ($Since -and $Session.Date -lt $Since) { continue }
        if (-not $Session.Changes -or $Session.Changes.Count -eq 0) { continue }

        # Track deltas per denomination within this session
        $DenomDeltas = [System.Collections.Generic.Dictionary[string, int]]::new([System.StringComparer]::OrdinalIgnoreCase)

        foreach ($Change in $Session.Changes) {
            # O(1) currency item lookup by entity name
            $MatchItem = $null
            if ($Change.EntityName -and $CurrencyByName.ContainsKey($Change.EntityName)) {
                $MatchItem = $CurrencyByName[$Change.EntityName]
            }
            if (-not $MatchItem) { continue }

            # Scan for @ilość delta tags (+N/-N pattern only)
            foreach ($TagEntry in $Change.Tags) {
                if ($TagEntry.Tag -ne '@ilość') { continue }
                $ValText = $TagEntry.Value.Trim()
                # Absolute values are balance snapshots, not transfers — skip them
                if ($ValText -match '^[+-]\d+$') {
                    $Delta = [int]$ValText
                    if (-not $DenomDeltas.ContainsKey($MatchItem.Denomination.Name)) {
                        $DenomDeltas[$MatchItem.Denomination.Name] = 0
                    }
                    $DenomDeltas[$MatchItem.Denomination.Name] += $Delta
                }
            }
        }

        # @Transfer directives always net to zero by construction — not checked here

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

    # Check 6: Physical supply — Postać-owned currencies (player characters)
    $PhysicalSupply = [System.Collections.Generic.Dictionary[string, int]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($Item in $CurrencyItems) {
        if ($Item.Status -eq 'Usunięty') { continue }
        if ($Item.OwnerCategory -ne 'Physical') { continue }

        if (-not $PhysicalSupply.ContainsKey($Item.Denomination.Name)) {
            $PhysicalSupply[$Item.Denomination.Name] = 0
        }
        $PhysicalSupply[$Item.Denomination.Name] += $Item.Quantity
    }
    foreach ($Entry in $PhysicalSupply.GetEnumerator()) {
        $Warnings.Add([PSCustomObject]@{
            Check      = 'PhysicalSupplyTracking'
            Severity   = 'Info'
            Entity     = $Entry.Key
            Detail     = "Physical supply: $($Entry.Value)"
        })
    }

    # Check 7: Virtual supply — NPC/Grupa/Gracz-owned currencies
    $VirtualSupply = [System.Collections.Generic.Dictionary[string, int]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($Item in $CurrencyItems) {
        if ($Item.Status -eq 'Usunięty') { continue }
        if ($Item.OwnerCategory -ne 'Virtual') { continue }

        if (-not $VirtualSupply.ContainsKey($Item.Denomination.Name)) {
            $VirtualSupply[$Item.Denomination.Name] = 0
        }
        $VirtualSupply[$Item.Denomination.Name] += $Item.Quantity
    }
    foreach ($Entry in $VirtualSupply.GetEnumerator()) {
        $Warnings.Add([PSCustomObject]@{
            Check      = 'VirtualSupplyTracking'
            Severity   = 'Info'
            Entity     = $Entry.Key
            Detail     = "Virtual supply: $($Entry.Value)"
        })
    }

    return [PSCustomObject]@{
        Warnings       = @($Warnings)
        WarningCount   = $Warnings.Count
        Supply         = $Supply
        PhysicalSupply = $PhysicalSupply
        VirtualSupply  = $VirtualSupply
        EntityCount    = $CurrencyItems.Count
        CheckedAt      = $Now
    }

    } finally { $script:SuppressWarnings = $PrevSuppress }
}
