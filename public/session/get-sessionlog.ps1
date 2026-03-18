<#
    .SYNOPSIS
    Parses session log content into structured, cross-referenced objects with
    optional name resolution for speakers and locations.

    .DESCRIPTION
    This file contains Get-SessionLog, which accepts session objects (typically
    from Get-Session) via pipeline or direct input. For each session with log
    URLs, it fetches the raw content (from res/logs/ cache or via HTTP),
    parses it into structured lines, and builds cross-referenced output objects.

    The function uses a collect-then-emit pipeline pattern:
    - begin: initialize collection list
    - process: accumulate session objects (pipeline-friendly)
    - end: deduplicate URLs, batch-fetch, parse, and emit results

    This ensures each unique URL is fetched only once, even when shared
    across sessions. Local file paths (non-HTTP URLs in .Logs) are read
    directly from .robot/ directory without HTTP overhead.

    Output per session: a PSCustomObject with .Logs array containing:
    - Url: normalized source URL
    - Format: detected log format (ChatLog/Prose)
    - Lines: parsed structured lines with Speaker, Channel, Index, Text
    - LocationSegments: location header boundaries with optional
      Resolved entity name and Stage from name resolution
    - Speakers: aggregated speaker objects with Raw name, Resolved
      canonical name (via 4-stage name resolution pipeline), and
      per-speaker line indices for participation analysis
    - Channels: ChatLog-only channel aggregation (null for Prose)

    Name resolution is optional — when -Index is provided, speakers and
    location headers are resolved against the entity registry. Without it,
    only Raw speaker names and unresolved location segments are returned.

    LocationSegment handling detects the compiled C# path (Robot.LogParser)
    for direct property assignment on C# class instances vs Add-Member on
    PSCustomObject for the PowerShell fallback path.
#>

. "$script:ModuleRoot/private/log-fetchhelpers.ps1"
. "$script:ModuleRoot/private/parse-logcontent.ps1"
. "$script:ModuleRoot/private/admin-config.ps1"

function Get-SessionLog {
    <#
        .SYNOPSIS
        Fetches and parses session logs into structured objects with speaker/location resolution.
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

        # Default log directory from config so callers don't need config awareness
        if (-not $LogDirectory) {
            $Config = Get-AdminConfig
            $LogDirectory = [System.IO.Path]::Combine($Config.ResDir, 'logs')
        }

        # Partition URLs into HTTP (batch-fetchable) and local (direct file read)
        # to avoid unnecessary HTTP overhead for locally cached logs
        $AllUrls = [System.Collections.Generic.List[string]]::new()
        $LocalPaths = [System.Collections.Generic.Dictionary[string,string]]::new(
            [System.StringComparer]::OrdinalIgnoreCase)
        $RepoRoot = Get-RepoRoot
        foreach ($S in $CollectedSessions) {
            if ($null -eq $S.Logs -or $S.Logs.Count -eq 0) { continue }
            foreach ($Url in $S.Logs) {
                if (-not $Url.StartsWith('http', [System.StringComparison]::OrdinalIgnoreCase)) {
                    # Local path: read from .robot/ directory (legacy pre-HTTP log storage)
                    if (-not $LocalPaths.ContainsKey($Url)) {
                        $FullPath = [System.IO.Path]::Combine($RepoRoot, '.robot.local', $Url)
                        if ([System.IO.File]::Exists($FullPath)) {
                            $LocalPaths[$Url] = [System.IO.File]::ReadAllText($FullPath)
                        }
                    }
                } else {
                    $AllUrls.Add($Url)
                }
            }
        }

        # Batch fetch deduplicates URLs — shared logs across sessions are downloaded once
        $FetchedContent = @{}
        if ($AllUrls.Count -gt 0) {
            if ($SkipFetch) {
                # Disk-only mode: skip URLs without a cached file
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

        # Merge local and remote content into a single lookup for uniform processing
        foreach ($Entry in $LocalPaths.GetEnumerator()) {
            $FetchedContent[$Entry.Key] = $Entry.Value
        }

        # Build output objects: parse content, aggregate speakers/channels, resolve names
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

                # Track per-speaker line indices for participation frequency analysis
                $SpeakerMap = [System.Collections.Generic.Dictionary[string, System.Collections.Generic.List[int]]]::new(
                    [System.StringComparer]::OrdinalIgnoreCase)

                # Channel tracking (ChatLog format only — Prose has no channel concept)
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

                # 4-stage name resolution: exact > stem > fuzzy > BK-tree
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

                # Channel aggregation only emitted for ChatLog format
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

                # Resolve location segment headers against entity registry.
                # LocationSegment is a C# class with Resolved/Stage fields when on the
                # compiled path; PSCustomObject with Add-Member on the PS fallback path.
                $LocationSegments = $Parsed.LocationSegments
                if ($null -ne $Index -and $null -ne $LocationSegments) {
                    $IsCompiledPath = ([System.Management.Automation.PSTypeName]'Robot.LogParser').Type
                    for ($i = 0; $i -lt $LocationSegments.Count; $i++) {
                        $Seg = $LocationSegments[$i]
                        $ResolveParams = @{ Query = $Seg.Raw }
                        if ($Index.ContainsKey('Index'))     { $ResolveParams['Index']     = $Index['Index'] }
                        if ($Index.ContainsKey('StemIndex')) { $ResolveParams['StemIndex'] = $Index['StemIndex'] }
                        if ($Index.ContainsKey('BKTree'))    { $ResolveParams['BKTree']    = $Index['BKTree'] }
                        if ($null -ne $Cache) { $ResolveParams['Cache'] = $Cache }
                        $ResolveResult = Resolve-Name @ResolveParams
                        if ($IsCompiledPath) {
                            # C# class: direct field assignment (no boxing issues)
                            $Seg.Resolved = if ($null -ne $ResolveResult) { $ResolveResult.Name } else { $null }
                            $Seg.Stage    = if ($null -ne $ResolveResult) { $ResolveResult.Stage } else { $null }
                        } else {
                            # PS fallback: PSCustomObject needs Add-Member
                            if ($null -ne $ResolveResult) {
                                $Seg | Add-Member -NotePropertyName 'Resolved' -NotePropertyValue $ResolveResult.Name -Force
                                $Seg | Add-Member -NotePropertyName 'Stage' -NotePropertyValue $ResolveResult.Stage -Force
                            } else {
                                $Seg | Add-Member -NotePropertyName 'Resolved' -NotePropertyValue $null -Force
                                $Seg | Add-Member -NotePropertyName 'Stage' -NotePropertyValue $null -Force
                            }
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
