<#
    .SYNOPSIS
    Reports location resolution quality from parsed session log content.

    .DESCRIPTION
    This file contains Get-NamedLogLocationReport.

    Accepts output from Get-SessionLog (via pipeline or direct input) and
    analyzes how well log location headers resolve against the entity registry.

    For each location segment found in logs:
    - Attempts resolution via Resolve-Name (all 4 stages: exact, declension,
      stem alternation, fuzzy/Levenshtein)
    - Compares against the source session's @Lokalizacje metadata
    - Flags unresolved locations and provides near-match candidates

    Dot-sources string-helpers.ps1 for Get-LevenshteinDistance and
    location-helpers.ps1 for Get-MapBaseName (map suffix stripping).
#>

. "$script:ModuleRoot/private/string-helpers.ps1"
. "$script:ModuleRoot/private/location-helpers.ps1"

function Get-NamedLogLocationReport {
    <#
        .SYNOPSIS
        Analyze location header resolution from parsed session logs.

        .PARAMETER SessionLog
        Output objects from Get-SessionLog. Each should have a Logs array
        containing LocationSegments. Accepts pipeline input.

        .PARAMETER Session
        Corresponding session objects (from Get-Session) to cross-reference
        against @Lokalizacje metadata. When SessionLog comes from pipeline
        and sessions were collected separately, pass them here.

        .PARAMETER Index
        Pre-built name index (from Get-NameIndex) for resolving location
        headers against the entity registry. Required.

        .PARAMETER Cache
        Shared resolution cache hashtable for Resolve-Name. Optional.

        .PARAMETER MaxNearMatches
        Maximum number of near-match candidates to report for unresolved
        locations. Default 3.
    #>

    [CmdletBinding()] param(
        [Parameter(ValueFromPipeline, HelpMessage = "Output objects from Get-SessionLog")]
        [PSObject[]]$SessionLog,

        [Parameter(HelpMessage = "Session objects for @Lokalizacje cross-reference")]
        [PSObject[]]$Session,

        [Parameter(Mandatory, HelpMessage = "Pre-built name index from Get-NameIndex")]
        $Index,

        [Parameter(HelpMessage = "Shared resolution cache hashtable for Resolve-Name")]
        [hashtable]$Cache,

        [Parameter(HelpMessage = "Maximum near-match candidates for unresolved locations")]
        [int]$MaxNearMatches = 3,

        [Parameter(HelpMessage = "Suppress warning output to stderr")]
        [switch]$Quiet
    )

    begin {
        $CollectedLogs = [System.Collections.Generic.List[PSObject]]::new()
    }

    process {
        foreach ($Log in $SessionLog) {
            if ($null -ne $Log) {
                $CollectedLogs.Add($Log)
            }
        }
    }

    end {
        $PrevSuppress = $script:SuppressWarnings
        if ($Quiet) { $script:SuppressWarnings = $true }
        try {

        if ($CollectedLogs.Count -eq 0) { return }

        # Build session lookup by index (if sessions provided separately)
        $SessionLookup = @{}
        if ($null -ne $Session) {
            for ($i = 0; $i -lt $Session.Count -and $i -lt $CollectedLogs.Count; $i++) {
                $SessionLookup[$i] = $Session[$i]
            }
        }

        # Build entity locations set for near-match search
        $AllLocationEntities = [System.Collections.Generic.List[string]]::new()
        $InnerIndex = if ($null -ne $Index -and $Index.ContainsKey('Index')) { $Index['Index'] } else { $null }
        if ($null -ne $InnerIndex) {
            $SeenNames = [System.Collections.Generic.HashSet[string]]::new(
                [System.StringComparer]::OrdinalIgnoreCase)
            foreach ($Key in $InnerIndex.Keys) {
                $IdxEntry = $InnerIndex[$Key]
                if ($null -ne $IdxEntry -and $null -ne $IdxEntry.OwnerType -and $IdxEntry.OwnerType -eq 'Lokacja') {
                    if ($null -ne $IdxEntry.Owner -and $SeenNames.Add($IdxEntry.Owner.Name)) {
                        $AllLocationEntities.Add($IdxEntry.Owner.Name)
                    }
                }
            }
        }

        $Results = [System.Collections.Generic.List[PSCustomObject]]::new()

        for ($LogIdx = 0; $LogIdx -lt $CollectedLogs.Count; $LogIdx++) {
            $LogResult = $CollectedLogs[$LogIdx]
            $SourceSession = $SessionLookup[$LogIdx]

            # Get session locations for cross-reference
            $SessionLocations = [System.Collections.Generic.HashSet[string]]::new(
                [System.StringComparer]::OrdinalIgnoreCase)
            if ($null -ne $SourceSession -and $null -ne $SourceSession.Locations) {
                foreach ($Loc in $SourceSession.Locations) {
                    # Handle slash-separated paths: add both full path and leaf
                    [void]$SessionLocations.Add($Loc)
                    $SlashIdx = $Loc.LastIndexOf('/')
                    if ($SlashIdx -ge 0 -and $SlashIdx -lt $Loc.Length - 1) {
                        [void]$SessionLocations.Add($Loc.Substring($SlashIdx + 1).Trim())
                    }
                }
            }

            if ($null -eq $LogResult.Logs) { continue }

            $LocationEntries = [System.Collections.Generic.List[PSCustomObject]]::new()
            $TotalCount = 0
            $ResolvedCount = 0
            $UnresolvedCount = 0
            $InMetaCount = 0
            $NotInMetaCount = 0

            foreach ($Log in $LogResult.Logs) {
                if ($null -eq $Log.LocationSegments) { continue }

                foreach ($Seg in $Log.LocationSegments) {
                    $TotalCount++
                    $Raw = $Seg.Raw

                    # Resolve via Resolve-Name (all stages including fuzzy)
                    $Resolved = $null
                    $Stage = $null
                    $StrippedName = $null
                    $ResolveParams = @{ Query = $Raw }
                    if ($Index.ContainsKey('Index') -and $null -ne $Index['Index'])         { $ResolveParams['Index']     = $Index['Index'] }
                    if ($Index.ContainsKey('StemIndex') -and $null -ne $Index['StemIndex']) { $ResolveParams['StemIndex'] = $Index['StemIndex'] }
                    if ($Index.ContainsKey('BKTree') -and $null -ne $Index['BKTree'])       { $ResolveParams['BKTree']    = $Index['BKTree'] }
                    if ($null -ne $Cache) { $ResolveParams['Cache'] = $Cache }
                    $ResolveResult = Resolve-Name @ResolveParams
                    if ($null -ne $ResolveResult) {
                        $Resolved = $ResolveResult.Name
                        $Stage = $ResolveResult.Stage
                        $ResolvedCount++
                    } else {
                        # Fallback: strip map suffixes (p.N, s.N, sala, etc.) and retry
                        $BaseCandidates = Get-MapBaseName -Name $Raw
                        foreach ($Candidate in $BaseCandidates) {
                            $ResolveParams['Query'] = $Candidate
                            $ResolveResult = Resolve-Name @ResolveParams
                            if ($null -ne $ResolveResult) {
                                $Resolved = $ResolveResult.Name
                                $Stage = 'MapStrip'
                                $StrippedName = $Candidate
                                $ResolvedCount++
                                break
                            }
                        }
                        if ($null -eq $Resolved) {
                            $UnresolvedCount++
                        }
                    }

                    # Check if in session metadata
                    $InSessionMeta = $SessionLocations.Contains($Raw)
                    if (-not $InSessionMeta -and $null -ne $Resolved) {
                        $InSessionMeta = $SessionLocations.Contains($Resolved)
                    }
                    if ($InSessionMeta) { $InMetaCount++ } else { $NotInMetaCount++ }

                    # Find near-matches for unresolved locations
                    $NearMatches = @()
                    if ($null -eq $Resolved -and $AllLocationEntities.Count -gt 0) {
                        $NearMatchList = [System.Collections.Generic.List[PSCustomObject]]::new()
                        $QueryLower = $Raw.ToLowerInvariant()
                        $Threshold = if ($QueryLower.Length -lt 5) { 1 } else { [math]::Floor($QueryLower.Length / 3) }

                        foreach ($EntityName in $AllLocationEntities) {
                            $Distance = Get-LevenshteinDistance -Source $Raw -Target $EntityName
                            if ($Distance -le $Threshold -and $Distance -gt 0) {
                                $NearMatchList.Add([PSCustomObject]@{
                                    Name     = $EntityName
                                    Distance = $Distance
                                })
                            }
                        }

                        if ($NearMatchList.Count -gt 0) {
                            $NearMatchList.Sort({ param($A, $B) $A.Distance.CompareTo($B.Distance) })
                            $TakeCount = [math]::Min($MaxNearMatches, $NearMatchList.Count)
                            $NearMatches = [PSCustomObject[]]$NearMatchList.GetRange(0, $TakeCount).ToArray()
                        }
                    }

                    $LocationEntries.Add([PSCustomObject]@{
                        Raw           = $Raw
                        Resolved      = $Resolved
                        StrippedName  = $StrippedName
                        Stage         = $Stage
                        InSessionMeta = $InSessionMeta
                        NearMatches   = $NearMatches
                        LogUrl        = $Log.Url
                        StartLine     = $Seg.StartLine
                        EndLine       = $Seg.EndLine
                    })
                }
            }

            $SessionTitle = if ($null -ne $SourceSession) { $SourceSession.Title } else { $null }
            $SessionDate = if ($null -ne $SourceSession) { $SourceSession.Date } else { $null }

            # Build transition edges from consecutive location segments
            $Transitions = [System.Collections.Generic.List[object]]::new()
            if ($LocationEntries.Count -gt 1) {
                for ($i = 0; $i -lt $LocationEntries.Count - 1; $i++) {
                    $SourceLoc = $LocationEntries[$i]
                    $TargetLoc = $LocationEntries[$i + 1]
                    # Skip self-transitions
                    $SrcName = if ($SourceLoc.Resolved) { $SourceLoc.Resolved } else { $SourceLoc.Raw }
                    $TgtName = if ($TargetLoc.Resolved) { $TargetLoc.Resolved } else { $TargetLoc.Raw }
                    if ([string]::Equals($SrcName, $TgtName, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
                    $Transitions.Add([PSCustomObject]@{
                        Source       = $SrcName
                        Target       = $TgtName
                        SourceRaw    = $SourceLoc.Raw
                        TargetRaw    = $TargetLoc.Raw
                        LogUrl       = $SourceLoc.LogUrl
                        SessionTitle = $SessionTitle
                        SessionDate  = $SessionDate
                    })
                }
            }

            $Results.Add([PSCustomObject]@{
                SessionTitle = $SessionTitle
                SessionDate  = $SessionDate
                Locations    = [PSCustomObject[]]$LocationEntries.ToArray()
                Transitions  = [PSCustomObject[]]$Transitions.ToArray()
                Summary      = [PSCustomObject]@{
                    Total           = $TotalCount
                    Resolved        = $ResolvedCount
                    Unresolved      = $UnresolvedCount
                    InMeta          = $InMetaCount
                    NotInMeta       = $NotInMetaCount
                    TransitionCount = $Transitions.Count
                }
            })
        }

        return $Results

        } finally { $script:SuppressWarnings = $PrevSuppress }
    }
}
