<#
    .SYNOPSIS
    Mass-fetches session log content from URLs with CDN-safe throttling and
    graceful error handling.

    .DESCRIPTION
    This file contains Invoke-SessionLogFetch - the recommended entry point
    for populating the res/logs/ directory before running Get-SessionLog for
    analysis.

    Fetches logs sequentially with configurable throttle delay. Handles HTTP
    errors gracefully:
    - 429 Too Many Requests: exponential backoff + retry
    - 404 Not Found: writes .failed marker, skips
    - 5xx Server Error: retry with backoff, then .failed marker
    - Network timeout: same retry logic as 5xx

    Never aborts the batch on individual failures. Previously-failed URLs
    (with .failed markers) are skipped unless -RetryFailed is set.

    Supports -WhatIf for dry-run inspection.

    Dot-sources log-fetchhelpers.ps1 and admin-config.ps1.
#>

. "$script:ModuleRoot/private/log-fetchhelpers.ps1"
. "$script:ModuleRoot/private/admin-config.ps1"

function Invoke-SessionLogFetch {
    <#
        .SYNOPSIS
        Bulk-fetches session logs with CDN-safe throttling and error handling.
    #>

    [CmdletBinding(SupportsShouldProcess)] param(
        [Parameter(ValueFromPipeline, HelpMessage = "Session objects from Get-Session")]
        [PSObject[]]$Session,

        [Parameter(HelpMessage = "Start date filter (uses Get-Session internally if -Session not provided)")]
        [datetime]$MinDate,

        [Parameter(HelpMessage = "End date filter")]
        [datetime]$MaxDate,

        [Parameter(HelpMessage = "Throttle delay in milliseconds between HTTP requests")]
        [int]$DelayMs = 500,

        [Parameter(HelpMessage = "Maximum retry attempts for transient failures (429, 5xx, timeout)")]
        [int]$MaxRetries = 2,

        [Parameter(HelpMessage = "Initial delay before retry in milliseconds (doubled each attempt)")]
        [int]$RetryDelayMs = 2000,

        [Parameter(HelpMessage = "Re-attempt URLs that previously failed (have .failed markers)")]
        [switch]$RetryFailed,

        [Parameter(HelpMessage = "Override log storage directory (default: ResDir/logs)")]
        [string]$LogDirectory,

        [Parameter(HelpMessage = "Suppress warning output to stderr")]
        [switch]$Quiet
    )

    begin {
        $script:PrevSuppressLogFetch = $script:SuppressWarnings
        if ($Quiet) { $script:SuppressWarnings = $true }
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
        # If no sessions provided via pipeline, fetch them
        if ($CollectedSessions.Count -eq 0) {
            $GetParams = @{}
            if ($PSBoundParameters.ContainsKey('MinDate')) { $GetParams['MinDate'] = $MinDate }
            if ($PSBoundParameters.ContainsKey('MaxDate')) { $GetParams['MaxDate'] = $MaxDate }
            $CollectedSessions = [System.Collections.Generic.List[PSObject]]::new(
                [PSObject[]]@(Get-Session @GetParams))
        }

        # Resolve log directory
        if (-not $LogDirectory) {
            $Config = Get-AdminConfig
            $LogDirectory = [System.IO.Path]::Combine($Config.ResDir, 'logs')
        }

        # Collect and deduplicate all log URLs
        $UrlSet = [System.Collections.Generic.HashSet[string]]::new(
            [System.StringComparer]::OrdinalIgnoreCase)
        $UniqueUrls = [System.Collections.Generic.List[string]]::new()

        foreach ($S in $CollectedSessions) {
            if ($null -eq $S.Logs) { continue }
            foreach ($Url in $S.Logs) {
                $Normalized = Normalize-LogUrl -Url $Url
                if ($UrlSet.Add($Normalized)) {
                    $UniqueUrls.Add($Normalized)
                }
            }
        }

        $Total = $UniqueUrls.Count
        if ($Total -eq 0) {
            Write-RobotWarning '[WARN Invoke-SessionLogFetch] No log URLs found in the provided sessions.'
            return [PSCustomObject]@{
                Total      = 0
                Fetched    = 0
                Cached     = 0
                Failed     = 0
                Skipped    = 0
                FailedUrls = @()
            }
        }

        # Partition into cached, failed/skipped, and pending
        $Cached = 0
        $Skipped = 0
        $Pending = [System.Collections.Generic.List[string]]::new()
        $FailedUrls = [System.Collections.Generic.List[string]]::new()

        foreach ($Url in $UniqueUrls) {
            $FileName = ConvertTo-LogFileName -NormalizedUrl $Url
            $FilePath = [System.IO.Path]::Combine($LogDirectory, $FileName)
            $FailedPath = "$FilePath.failed"

            if ([System.IO.File]::Exists($FilePath)) {
                $Cached++
            } elseif ([System.IO.File]::Exists($FailedPath) -and -not $RetryFailed) {
                $Skipped++
            } else {
                $Pending.Add($Url)
            }
        }

        [System.Console]::Out.WriteLine("Znaleziono $Total URL logów (pobrane: $Cached, wcześniej nieudane: $Skipped, do pobrania: $($Pending.Count))")

        # WhatIf: report what would be fetched
        if (-not $PSCmdlet.ShouldProcess(
            "$($Pending.Count) log URLs",
            "Fetch from web and save to '$LogDirectory'")) {
            return [PSCustomObject]@{
                Total      = $Total
                Fetched    = 0
                Cached     = $Cached
                Failed     = 0
                Skipped    = $Skipped
                FailedUrls = @()
            }
        }

        # Ensure directory exists
        if (-not [System.IO.Directory]::Exists($LogDirectory)) {
            [void][System.IO.Directory]::CreateDirectory($LogDirectory)
        }

        # Fetch pending URLs with throttling and retry
        $Client = Get-LogHttpClient
        $FetchedCount = 0
        $FailedCount = 0
        $Current = 0

        foreach ($Url in $Pending) {
            $Current++
            $FileName = ConvertTo-LogFileName -NormalizedUrl $Url
            $FilePath = [System.IO.Path]::Combine($LogDirectory, $FileName)
            $FailedPath = "$FilePath.failed"

            $Remaining = $Pending.Count - $Current
            Write-Progress -Activity 'Pobieranie logów sesji' `
                -Status "[$Current / $($Pending.Count)] Pobrane:$FetchedCount Błędy:$FailedCount Pozostało:$Remaining — $FileName" `
                -PercentComplete ([math]::Min(100, [int](($Current / $Pending.Count) * 100)))

            $Success = $false
            $LastError = $null
            $LastStatusCode = 0

            for ($Attempt = 0; $Attempt -le $MaxRetries; $Attempt++) {
                if ($Attempt -gt 0) {
                    $BackoffMs = $RetryDelayMs * [math]::Pow(2, $Attempt - 1)
                    Write-RobotWarning "[WARN Invoke-SessionLogFetch] Retrying '$FileName' (attempt $($Attempt + 1)/$($MaxRetries + 1)) after ${BackoffMs}ms..."
                    [System.Threading.Thread]::Sleep([int]$BackoffMs)
                }

                try {
                    $Response = $Client.GetAsync($Url).GetAwaiter().GetResult()
                }
                catch {
                    $LastError = "$_"
                    continue
                }

                $StatusCode = [int]$Response.StatusCode
                $LastStatusCode = $StatusCode

                # Success
                if ($Response.IsSuccessStatusCode) {
                    $Content = $Response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
                    [System.IO.File]::WriteAllText($FilePath, $Content)

                    # Remove .failed marker if present
                    if ([System.IO.File]::Exists($FailedPath)) {
                        [System.IO.File]::Delete($FailedPath)
                    }

                    $Success = $true
                    $FetchedCount++
                    break
                }

                # 404: permanent failure, no retry
                if ($StatusCode -eq 404) {
                    $LastError = "HTTP 404 Not Found"
                    break
                }

                # 429: rate limited — always retry with backoff
                if ($StatusCode -eq 429) {
                    $LastError = "HTTP 429 Too Many Requests"
                    continue
                }

                # 5xx: server error — retry
                if ($StatusCode -ge 500) {
                    $LastError = "HTTP $StatusCode"
                    continue
                }

                # Other error codes: don't retry
                $LastError = "HTTP $StatusCode"
                break
            }

            if (-not $Success) {
                $FailedCount++
                $FailedUrls.Add($Url)
                Write-RobotWarning "[WARN Invoke-SessionLogFetch] Failed to fetch '$Url': $LastError"

                # Write .failed marker
                $FailedContent = "URL: $Url`nError: $LastError`nHTTP Status: $LastStatusCode`nTimestamp: $([System.DateTime]::UtcNow.ToString('o'))"
                [System.IO.File]::WriteAllText($FailedPath, $FailedContent)
            }

            # Throttle between HTTP requests
            if ($DelayMs -gt 0 -and $Current -lt $Pending.Count) {
                [System.Threading.Thread]::Sleep($DelayMs)
            }
        }

        Write-Progress -Activity 'Pobieranie logów sesji' -Completed

        return [PSCustomObject]@{
            Total      = $Total
            Fetched    = $FetchedCount
            Cached     = $Cached
            Failed     = $FailedCount
            Skipped    = $Skipped
            FailedUrls = [string[]]$FailedUrls.ToArray()
        }

        $script:SuppressWarnings = $script:PrevSuppressLogFetch
    }
}
