<#
    .SYNOPSIS
    Parses session log content into structured, cross-referenced objects with
    optional name resolution for speakers and locations.

    .DESCRIPTION
    This file contains Get-SessionLog, which accepts session objects (typically
    from Get-Session) via pipeline or direct input. For each session with log
    URLs, it fetches the raw content (from res/logs/ or via HTTP), parses it
    into structured lines, and builds cross-referenced output objects.

    The function uses a collect-then-emit pattern: sessions are gathered during
    the process block, URLs are deduplicated and batch-fetched in the end block,
    then all results are emitted. This ensures each unique URL is fetched only
    once, even when shared across sessions.

    Dot-sources private helpers:
    - log-fetchhelpers.ps1: URL normalization, file caching, HTTP fetch
    - parse-logcontent.ps1: format detection, ChatLog/Prose parsers
    - admin-config.ps1: ResDir path resolution
#>

. "$script:ModuleRoot/private/log-fetchhelpers.ps1"
. "$script:ModuleRoot/private/parse-logcontent.ps1"
. "$script:ModuleRoot/private/admin-config.ps1"

function Get-SessionLog {
    <#
        .SYNOPSIS
        Fetches and parses session logs into structured objects.

        .PARAMETER Session
        One or more session objects (from Get-Session). Accepts pipeline input.

        .PARAMETER Index
        Pre-built name index (from Get-NameIndex) for resolving speakers and
        location headers against the entity registry. Optional.

        .PARAMETER Cache
        Shared resolution cache hashtable for Resolve-Name. Optional.

        .PARAMETER LogDirectory
        Override for the log storage directory. Defaults to ResDir/logs from
        Get-AdminConfig.

        .PARAMETER DelayMs
        Throttle delay in milliseconds between HTTP requests. Default 500.

        .PARAMETER SkipFetch
        When set, only reads logs from the local res/logs/ directory. URLs
        without a cached file are silently skipped (no HTTP requests).
    #>

    [CmdletBinding()] param(
        [Parameter(ValueFromPipeline, HelpMessage = "Session objects from Get-Session with .Logs URL array")]
        [PSObject[]]$Session,

        [Parameter(HelpMessage = "Pre-built name index from Get-NameIndex for speaker/location resolution")]
        [hashtable]$Index,

        [Parameter(HelpMessage = "Shared resolution cache hashtable for Resolve-Name")]
        [hashtable]$Cache,

        [Parameter(HelpMessage = "Override for the log storage directory (default: ResDir/logs)")]
        [string]$LogDirectory,

        [Parameter(HelpMessage = "Throttle delay in milliseconds between HTTP requests")]
        [int]$DelayMs = 500,

        [Parameter(HelpMessage = "Read only from disk cache, no HTTP requests")]
        [switch]$SkipFetch
    )

    begin {
        $CollectedSessions = [System.Collections.Generic.List[PSObject]]::new()
    }

    process {
        foreach ($S in $Session) {
            if ($null -ne $S) {
                $CollectedSessions.Add($S)
            }
        }
    }

    end {
        if ($CollectedSessions.Count -eq 0) { return }

        # Default to ResDir/logs so callers don't need to know the config structure
        if (-not $LogDirectory) {
            $Config = Get-AdminConfig
            $LogDirectory = [System.IO.Path]::Combine($Config.ResDir, 'logs')
        }

        # Separate HTTP URLs from local paths so we can batch-fetch remote ones
        # while reading local files directly (no HTTP overhead)
        $AllUrls = [System.Collections.Generic.List[string]]::new()
        $LocalPaths = [System.Collections.Generic.Dictionary[string,string]]::new(
            [System.StringComparer]::OrdinalIgnoreCase)
        $RepoRoot = Get-RepoRoot
        foreach ($S in $CollectedSessions) {
            if ($null -eq $S.Logs -or $S.Logs.Count -eq 0) { continue }
            foreach ($Url in $S.Logs) {
                if (-not $Url.StartsWith('http', [System.StringComparison]::OrdinalIgnoreCase)) {
                    # Local path (e.g. res/logs/pastebincomrawX)
                    if (-not $LocalPaths.ContainsKey($Url)) {
                        $FullPath = [System.IO.Path]::Combine($RepoRoot, '.robot', $Url)
                        if ([System.IO.File]::Exists($FullPath)) {
                            $LocalPaths[$Url] = [System.IO.File]::ReadAllText($FullPath)
                        }
                    }
                } else {
                    $AllUrls.Add($Url)
                }
            }
        }

        # Batch fetch deduplicates URLs so shared logs across sessions are downloaded once
        $FetchedContent = @{}
        if ($AllUrls.Count -gt 0) {
            if ($SkipFetch) {
                # Read only from disk, no HTTP
                foreach ($Url in $AllUrls) {
                    $NormalizedUrl = Normalize-LogUrl -Url $Url
                    $FileName = ConvertTo-LogFileName -NormalizedUrl $NormalizedUrl
                    $FilePath = [System.IO.Path]::Combine($LogDirectory, $FileName)
                    if ([System.IO.File]::Exists($FilePath)) {
                        $FetchedContent[$NormalizedUrl] = [System.IO.File]::ReadAllText($FilePath)
                    }
                }
            } else {
                $FetchedContent = Invoke-LogBatchFetch `
                    -Urls $AllUrls `
                    -LogDirectory $LogDirectory `
                    -DelayMs $DelayMs
            }
        }

        # Unify local and remote content into one lookup for uniform processing below
        foreach ($Entry in $LocalPaths.GetEnumerator()) {
            $FetchedContent[$Entry.Key] = $Entry.Value
        }

        # Build structured log objects with speaker/channel aggregation and optional name resolution
        $Results = [System.Collections.Generic.List[PSCustomObject]]::new()

        foreach ($S in $CollectedSessions) {
            if ($null -eq $S.Logs -or $S.Logs.Count -eq 0) { continue }

            $LogObjects = [System.Collections.Generic.List[PSCustomObject]]::new()

            foreach ($Url in $S.Logs) {
                $LookupKey = if ($Url.StartsWith('http', [System.StringComparison]::OrdinalIgnoreCase)) {
                    Normalize-LogUrl -Url $Url
                } else { $Url }
                $Content = $FetchedContent[$LookupKey]

                if ($null -eq $Content -or $Content.Length -eq 0) { continue }

                $Parsed = ConvertFrom-LogContent -Content $Content

                # Aggregate speaker line indices for participation analysis
                $SpeakerMap = [System.Collections.Generic.Dictionary[string, System.Collections.Generic.List[int]]]::new(
                    [System.StringComparer]::OrdinalIgnoreCase)

                # Aggregate channel line indices (ChatLog format only)
                $ChannelMap = [System.Collections.Generic.Dictionary[string, System.Collections.Generic.List[int]]]::new(
                    [System.StringComparer]::OrdinalIgnoreCase)

                foreach ($Line in $Parsed.Lines) {
                    if ($null -ne $Line.Speaker -and $Line.Speaker.Length -gt 0) {
                        if (-not $SpeakerMap.ContainsKey($Line.Speaker)) {
                            $SpeakerMap[$Line.Speaker] = [System.Collections.Generic.List[int]]::new()
                        }
                        $SpeakerMap[$Line.Speaker].Add($Line.Index)
                    }

                    if ($null -ne $Line.Channel -and $Line.Channel.Length -gt 0) {
                        if (-not $ChannelMap.ContainsKey($Line.Channel)) {
                            $ChannelMap[$Line.Channel] = [System.Collections.Generic.List[int]]::new()
                        }
                        $ChannelMap[$Line.Channel].Add($Line.Index)
                    }
                }

                # Map raw speaker names to canonical entity names via the 4-stage resolution pipeline
                $Speakers = [System.Collections.Generic.List[PSCustomObject]]::new()
                foreach ($Entry in $SpeakerMap.GetEnumerator()) {
                    $Resolved = $null
                    $Stage = $null

                    if ($null -ne $Index) {
                        $ResolveParams = @{ Query = $Entry.Key }
                        if ($Index.ContainsKey('Index'))     { $ResolveParams['Index']     = $Index['Index'] }
                        if ($Index.ContainsKey('StemIndex')) { $ResolveParams['StemIndex'] = $Index['StemIndex'] }
                        if ($Index.ContainsKey('BKTree'))    { $ResolveParams['BKTree']    = $Index['BKTree'] }
                        if ($null -ne $Cache) { $ResolveParams['Cache'] = $Cache }
                        $ResolveResult = Resolve-Name @ResolveParams
                        if ($null -ne $ResolveResult) {
                            $Resolved = $ResolveResult.Name
                            $Stage = $ResolveResult.Stage
                        }
                    }

                    $Speakers.Add([PSCustomObject]@{
                        Raw       = $Entry.Key
                        Resolved  = $Resolved
                        Stage     = $Stage
                        Lines     = [int[]]$Entry.Value.ToArray()
                        LineCount = $Entry.Value.Count
                    })
                }

                # Channels are only meaningful in ChatLog format (Prose has no channel concept)
                $Channels = $null
                if ($Parsed.Format -eq 'ChatLog' -and $ChannelMap.Count -gt 0) {
                    $Channels = [System.Collections.Generic.List[PSCustomObject]]::new()
                    foreach ($Entry in $ChannelMap.GetEnumerator()) {
                        $Channels.Add([PSCustomObject]@{
                            Name      = $Entry.Key
                            Lines     = [int[]]$Entry.Value.ToArray()
                            LineCount = $Entry.Value.Count
                        })
                    }
                    $Channels = [PSCustomObject[]]$Channels.ToArray()
                }

                # Resolve location headers against entity registry for cross-referencing
                $LocationSegments = $Parsed.LocationSegments
                if ($null -ne $Index -and $null -ne $LocationSegments) {
                    for ($i = 0; $i -lt $LocationSegments.Count; $i++) {
                        $Seg = $LocationSegments[$i]
                        $ResolveParams = @{ Query = $Seg.Raw }
                        if ($Index.ContainsKey('Index'))     { $ResolveParams['Index']     = $Index['Index'] }
                        if ($Index.ContainsKey('StemIndex')) { $ResolveParams['StemIndex'] = $Index['StemIndex'] }
                        if ($Index.ContainsKey('BKTree'))    { $ResolveParams['BKTree']    = $Index['BKTree'] }
                        if ($null -ne $Cache) { $ResolveParams['Cache'] = $Cache }
                        $ResolveResult = Resolve-Name @ResolveParams
                        if ($null -ne $ResolveResult) {
                            $Seg | Add-Member -NotePropertyName 'Resolved' -NotePropertyValue $ResolveResult.Name -Force
                            $Seg | Add-Member -NotePropertyName 'Stage' -NotePropertyValue $ResolveResult.Stage -Force
                        } else {
                            $Seg | Add-Member -NotePropertyName 'Resolved' -NotePropertyValue $null -Force
                            $Seg | Add-Member -NotePropertyName 'Stage' -NotePropertyValue $null -Force
                        }
                    }
                }

                $LogObjects.Add([PSCustomObject]@{
                    Url              = $NormalizedUrl
                    Format           = $Parsed.Format
                    Lines            = $Parsed.Lines
                    LocationSegments = $LocationSegments
                    Speakers         = [PSCustomObject[]]$Speakers.ToArray()
                    Channels         = $Channels
                })
            }

            if ($LogObjects.Count -gt 0) {
                $Results.Add([PSCustomObject]@{
                    Logs = [PSCustomObject[]]$LogObjects.ToArray()
                })
            }
        }

        return $Results
    }
}
