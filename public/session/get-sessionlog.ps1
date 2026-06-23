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
        [switch]$SkipFetch,

        [Parameter(HelpMessage = "Skip in-message entity mention extraction (Mentions/MentionsByLine fields)")]
        [switch]$SkipMentions
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
                $LogObject = New-ResolvedLogObject `
                    -Url $NormalizedUrl `
                    -Parsed $Parsed `
                    -Index $Index `
                    -Cache $Cache `
                    -SkipMentions:$SkipMentions
                $LogObjects.Add($LogObject)
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
