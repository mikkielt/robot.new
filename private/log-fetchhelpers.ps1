<#
    .SYNOPSIS
    Private helper functions for fetching and caching session log content.

    .DESCRIPTION
    Provides URL normalization, filesystem-safe filename generation, single-URL
    fetch with local caching, and batch fetch with CDN-safe throttling.

    Fetched logs are persisted in the res/logs/ directory (via Get-AdminConfig ResDir)
    as raw text files with URL-derived filenames. A .failed marker is written for
    URLs that permanently fail, preventing redundant retries on subsequent runs.

    Helpers:
    - Normalize-LogUrl: converts Pastebin URLs to /raw/ variant, normalizes protocol
    - ConvertTo-LogFileName: URL to filesystem-safe filename (strip protocol, remove non-alphanumeric)
    - Get-LogHttpClient: lazily-initialized shared HttpClient with 30s timeout
    - Invoke-LogFetch: single URL fetch with disk cache read-through
    - Invoke-LogBatchFetch: sequential batch fetch with deduplication and CDN throttle

    Module-level data:
    - $script:PastebinUrlPattern: compiled regex for non-raw pastebin URLs
    - $script:PastebinRawPattern: compiled regex for raw pastebin URLs
    - $script:UrlUnsafeChars: compiled regex for non-alphanumeric characters
    - $script:LogHttpClient: lazily-initialized shared HttpClient instance
#>

# ── Precompiled Regex ─────────────────────────────────────────────────────────

$script:PastebinUrlPattern = [regex]::new(
    '^https?://(?:www\.)?pastebin\.com/(?!raw/)([A-Za-z0-9]+)/?$',
    [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)

$script:PastebinRawPattern = [regex]::new(
    '^https?://(?:www\.)?pastebin\.com/raw/([A-Za-z0-9]+)/?$',
    [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)

$script:UrlUnsafeChars = [regex]::new('[^A-Za-z0-9]')

# ── Shared HttpClient ─────────────────────────────────────────────────────────
# Lazily initialized; reused across calls within the same module session.

$script:LogHttpClient = $null

function Get-LogHttpClient {
    if ($null -eq $script:LogHttpClient) {
        $script:LogHttpClient = [System.Net.Http.HttpClient]::new()
        $script:LogHttpClient.Timeout = [System.TimeSpan]::FromSeconds(30)
        [void]$script:LogHttpClient.DefaultRequestHeaders.Add(
            'User-Agent', 'Robot-PowerShell/1.0')
    }
    return $script:LogHttpClient
}

# ── Functions ─────────────────────────────────────────────────────────────────

function Normalize-LogUrl {
    <#
        .SYNOPSIS
        Normalizes a log URL, converting Pastebin URLs to their /raw/ variant.
    #>
    [CmdletBinding()] param(
        [Parameter(Mandatory, HelpMessage = "Raw or normalized URL to normalize")]
        [string]$Url
    )

    $Url = $Url.Trim().TrimEnd('/')

    # Already a raw pastebin URL — ensure https
    $RawMatch = $script:PastebinRawPattern.Match($Url)
    if ($RawMatch.Success) {
        return "https://pastebin.com/raw/$($RawMatch.Groups[1].Value)"
    }

    # Non-raw pastebin URL — convert to raw
    $Match = $script:PastebinUrlPattern.Match($Url)
    if ($Match.Success) {
        return "https://pastebin.com/raw/$($Match.Groups[1].Value)"
    }

    # Other URLs — normalize protocol to https if http
    if ($Url.StartsWith('http://', [System.StringComparison]::OrdinalIgnoreCase)) {
        $Url = 'https://' + $Url.Substring(7)
    }

    return $Url
}


function ConvertTo-LogFileName {
    <#
        .SYNOPSIS
        Converts a normalized URL to a filesystem-safe filename.

        .DESCRIPTION
        Strips the protocol prefix and replaces all non-alphanumeric characters with
        empty string, producing a compact human-readable filename.
        Example: https://pastebin.com/raw/wqhtQ5Wq → pastebincomrawwqhtQ5Wq
    #>
    [CmdletBinding()] param(
        [Parameter(Mandatory, HelpMessage = "Normalized URL to convert to filename")]
        [string]$NormalizedUrl
    )

    # Strip protocol
    $Name = $NormalizedUrl
    if ($Name.StartsWith('https://', [System.StringComparison]::OrdinalIgnoreCase)) {
        $Name = $Name.Substring(8)
    } elseif ($Name.StartsWith('http://', [System.StringComparison]::OrdinalIgnoreCase)) {
        $Name = $Name.Substring(7)
    }

    # Replace all non-alphanumeric characters
    $Name = $script:UrlUnsafeChars.Replace($Name, '')

    return $Name
}


function Invoke-LogFetch {
    <#
        .SYNOPSIS
        Fetches a single log URL, using local file cache in the log directory.

        .DESCRIPTION
        Returns the raw text content. If the file already exists in LogDirectory,
        reads from disk. If a .failed marker exists and -RetryFailed is not set,
        returns $null. Otherwise fetches via HTTP and writes to disk on success.
        Caller is responsible for writing .failed markers on permanent failure.
    #>
    [CmdletBinding()] param(
        [Parameter(Mandatory, HelpMessage = "URL to fetch")]
        [string]$Url,

        [Parameter(Mandatory, HelpMessage = "Directory for cached log files")]
        [string]$LogDirectory,

        [Parameter(HelpMessage = "Re-attempt URLs with existing .failed markers")]
        [switch]$RetryFailed
    )

    $NormalizedUrl = Normalize-LogUrl -Url $Url
    $FileName = ConvertTo-LogFileName -NormalizedUrl $NormalizedUrl
    $FilePath = [System.IO.Path]::Combine($LogDirectory, $FileName)
    $FailedPath = "$FilePath.failed"

    # Cache hit — file already exists
    if ([System.IO.File]::Exists($FilePath)) {
        return [System.IO.File]::ReadAllText($FilePath)
    }

    # Previously failed — skip unless retrying
    if ([System.IO.File]::Exists($FailedPath) -and -not $RetryFailed) {
        return $null
    }

    # Fetch via HTTP
    $Client = Get-LogHttpClient

    try {
        $Response = $Client.GetAsync($NormalizedUrl).GetAwaiter().GetResult()
    }
    catch {
        Write-RobotWarning "[WARN Invoke-LogFetch] Network error fetching '$NormalizedUrl': $_"
        return $null
    }

    if (-not $Response.IsSuccessStatusCode) {
        $StatusCode = [int]$Response.StatusCode
        Write-RobotWarning "[WARN Invoke-LogFetch] HTTP $StatusCode fetching '$NormalizedUrl'"
        return $null
    }

    $Content = $Response.Content.ReadAsStringAsync().GetAwaiter().GetResult()

    # Ensure directory exists
    if (-not [System.IO.Directory]::Exists($LogDirectory)) {
        [void][System.IO.Directory]::CreateDirectory($LogDirectory)
    }

    # Write content to file
    [System.IO.File]::WriteAllText($FilePath, $Content)

    # Remove .failed marker if it existed (successful retry)
    if ([System.IO.File]::Exists($FailedPath)) {
        [System.IO.File]::Delete($FailedPath)
    }

    return $Content
}


function Invoke-LogBatchFetch {
    <#
        .SYNOPSIS
        Fetches multiple log URLs sequentially with CDN-safe throttling.

        .DESCRIPTION
        Accepts an array of URLs, deduplicates and normalizes them, then fetches
        each sequentially. Already-cached files are read instantly (no delay).
        HTTP requests are spaced by DelayMs to avoid CDN rate limiting.

        Returns a hashtable mapping normalized URLs to their text content.
        URLs that fail are mapped to $null.
    #>
    [CmdletBinding()] param(
        [Parameter(Mandatory, HelpMessage = "Array of URLs to fetch")]
        [string[]]$Urls,

        [Parameter(Mandatory, HelpMessage = "Directory for cached log files")]
        [string]$LogDirectory,

        [Parameter(HelpMessage = "Throttle delay in milliseconds between HTTP requests")]
        [int]$DelayMs = 500,

        [Parameter(HelpMessage = "Re-attempt URLs with existing .failed markers")]
        [switch]$RetryFailed
    )

    $Results = @{}
    $SeenUrls = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase)

    $Total = $Urls.Count
    $Current = 0
    $FetchedCount = 0

    foreach ($Url in $Urls) {
        $NormalizedUrl = Normalize-LogUrl -Url $Url
        if (-not $SeenUrls.Add($NormalizedUrl)) { continue }

        $Current++
        $FileName = ConvertTo-LogFileName -NormalizedUrl $NormalizedUrl
        $FilePath = [System.IO.Path]::Combine($LogDirectory, $FileName)
        $IsCached = [System.IO.File]::Exists($FilePath)

        Write-Progress -Activity 'Fetching session logs' `
            -Status "$Current / $Total - $(if ($IsCached) { 'cached' } else { 'fetching' })" `
            -PercentComplete ([math]::Min(100, [int](($Current / $Total) * 100)))

        $Content = Invoke-LogFetch -Url $NormalizedUrl -LogDirectory $LogDirectory -RetryFailed:$RetryFailed
        $Results[$NormalizedUrl] = $Content

        # Throttle only actual HTTP requests (not cache hits)
        if (-not $IsCached -and $Content -ne $null -and $DelayMs -gt 0) {
            $FetchedCount++
            [System.Threading.Thread]::Sleep($DelayMs)
        }
    }

    Write-Progress -Activity 'Fetching session logs' -Completed

    return $Results
}
