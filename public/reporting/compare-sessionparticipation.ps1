<#
    .SYNOPSIS
    Compares session participation across multiple entities.

    .DESCRIPTION
    Finds sessions shared between the given entities and sessions exclusive
    to each. Returns common sessions, exclusive sessions per entity, and
    an overlap matrix with pairwise overlap percentages.
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

    # Collect session headers for each entity
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

    # Common sessions: intersection of all sets
    $CommonHeaders = [System.Collections.Generic.HashSet[string]]::new(
        $EntitySessionSets[$EntityNames[0]],
        [System.StringComparer]::OrdinalIgnoreCase)
    for ($i = 1; $i -lt $EntityNames.Count; $i++) {
        $CommonHeaders.IntersectWith($EntitySessionSets[$EntityNames[$i]])
    }

    # Exclusive sessions: per entity, sessions not shared with ANY other entity
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

    # Overlap matrix (pairwise)
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
