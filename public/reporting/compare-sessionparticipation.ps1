<#
    .SYNOPSIS
    Compares session participation across multiple entities.

    .DESCRIPTION
    Compare-SessionParticipation finds sessions shared between the given
    entities and sessions exclusive to each. It uses HashSet intersection
    and union operations to efficiently compute pairwise overlap without
    repeated linear scans.

    Processing pipeline:
    1. Collect session headers per entity via Get-SessionGraph (Sessions mode)
    2. Compute the global intersection (sessions where ALL entities appear)
    3. Compute exclusive sessions per entity (sessions not shared with ANY other)
    4. Build an overlap matrix with pairwise Jaccard-style percentages
       (SharedCount / UnionCount * 100) for every unique entity pair

    The overlap matrix uses upper-triangle iteration (i < j) so each pair
    appears exactly once. Overlap percentage is Jaccard similarity scaled
    to 0-100, with zero returned when both sets are empty.

    Returns a PSCustomObject with EntityNames, CommonSessions (headers
    present in all sets), ExclusiveSessions (ordered hashtable of per-entity
    exclusive header arrays), and OverlapMatrix (list of pairwise objects).

    Requires at least 2 entity names; emits a warning and returns $null
    if fewer are provided.
#>

function Compare-SessionParticipation {
    <#
        .SYNOPSIS
        Compare session participation across multiple entities.
    #>

    [CmdletBinding()] param(
        [Parameter(Mandatory, Position = 0, HelpMessage = "Entity names to compare")]
        [string[]]$EntityNames,

        [Parameter(HelpMessage = "Maximum tier to include (0-2)")]
        [ValidateRange(0, 2)]
        [int]$MinTier = 2,

        [Parameter(HelpMessage = "Suppress warning output to stderr")]
        [switch]$Quiet
    )

    $PrevSuppress = $script:SuppressWarnings
    if ($Quiet) { $script:SuppressWarnings = $true }
    try {

    if ($EntityNames.Count -lt 2) {
        Write-RobotWarning "[WARN Compare-SessionParticipation] At least 2 entity names required."
        return $null
    }

    # Build per-entity HashSets of session headers for O(1) membership testing
    $EntitySessionSets = [ordered]@{}
    foreach ($Name in $EntityNames) {
        $Sessions = @(Get-SessionGraph -EntityName $Name -MinTier $MinTier -Mode Sessions -Quiet)
        $Headers = [System.Collections.Generic.HashSet[string]]::new(
            [System.StringComparer]::OrdinalIgnoreCase)
        foreach ($S in $Sessions) {
            [void]$Headers.Add($S.Header)
        }
        $EntitySessionSets[$Name] = $Headers
    }

    # Start with the first entity's set and progressively intersect with remaining sets
    $CommonHeaders = [System.Collections.Generic.HashSet[string]]::new(
        $EntitySessionSets[$EntityNames[0]],
        [System.StringComparer]::OrdinalIgnoreCase)
    for ($i = 1; $i -lt $EntityNames.Count; $i++) {
        $CommonHeaders.IntersectWith($EntitySessionSets[$EntityNames[$i]])
    }

    # For each entity, collect headers that appear in no other entity's set
    $ExclusiveSessions = [ordered]@{}
    foreach ($Name in $EntityNames) {
        $OwnHeaders = $EntitySessionSets[$Name]
        $OtherHeaders = [System.Collections.Generic.HashSet[string]]::new(
            [System.StringComparer]::OrdinalIgnoreCase)
        foreach ($OtherName in $EntityNames) {
            if ([string]::Equals($OtherName, $Name, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
            foreach ($H in $EntitySessionSets[$OtherName]) {
                [void]$OtherHeaders.Add($H)
            }
        }
        $Exclusive = [System.Collections.Generic.List[string]]::new()
        foreach ($H in $OwnHeaders) {
            if (-not $OtherHeaders.Contains($H)) {
                [void]$Exclusive.Add($H)
            }
        }
        $ExclusiveSessions[$Name] = @($Exclusive)
    }

    # Upper-triangle pairwise overlap: Jaccard similarity as percentage
    $OverlapMatrix = [System.Collections.Generic.List[object]]::new()
    for ($i = 0; $i -lt $EntityNames.Count; $i++) {
        for ($j = $i + 1; $j -lt $EntityNames.Count; $j++) {
            $A = $EntitySessionSets[$EntityNames[$i]]
            $B = $EntitySessionSets[$EntityNames[$j]]

            $Intersection = [System.Collections.Generic.HashSet[string]]::new(
                $A, [System.StringComparer]::OrdinalIgnoreCase)
            $Intersection.IntersectWith($B)

            $Union = [System.Collections.Generic.HashSet[string]]::new(
                $A, [System.StringComparer]::OrdinalIgnoreCase)
            $Union.UnionWith($B)

            $Pct = if ($Union.Count -gt 0) {
                [math]::Round(($Intersection.Count / $Union.Count) * 100, 1)
            } else { 0 }

            $OverlapMatrix.Add([PSCustomObject]@{
                EntityA       = $EntityNames[$i]
                EntityB       = $EntityNames[$j]
                SharedCount   = $Intersection.Count
                UnionCount    = $Union.Count
                OverlapPct    = $Pct
            })
        }
    }

    return [PSCustomObject]@{
        EntityNames      = $EntityNames
        CommonSessions   = @($CommonHeaders)
        ExclusiveSessions = $ExclusiveSessions
        OverlapMatrix    = @($OverlapMatrix)
    }

    } finally { $script:SuppressWarnings = $PrevSuppress }
}
