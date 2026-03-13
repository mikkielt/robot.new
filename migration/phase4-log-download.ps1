<#
    .SYNOPSIS
    Phase 4: Bulk log download.

    .DESCRIPTION
    Fetches all session log URLs to res/logs/ so the lore repository has a
    complete local archive. This is a prerequisite for URL localization
    (Phase 5), @Drzwi door inference (Phase 6), and offline log analysis.

    Reuses Invoke-SessionLogFetch — no new HTTP fetching logic.

    Dependencies: migration-ui.ps1, migration-state.ps1, robot module imported.
#>

# Dot-source admin config (provides Get-AdminConfig for ResDir path)
. ([System.IO.Path]::Combine($PSScriptRoot, '..', 'private', 'admin-config.ps1'))

# Dot-source log fetch helpers (provides Normalize-LogUrl, ConvertTo-LogFileName)
. ([System.IO.Path]::Combine($PSScriptRoot, '..', 'private', 'log-fetchhelpers.ps1'))

# ============================================================================
# PHASE 4 - Bulk log download
# ============================================================================

function Invoke-MigrationPhase4 {
    param(
        [Parameter(Mandatory)] [hashtable]$State,
        [switch]$WhatIf
    )

    if (-not (Test-PhasePredecessor -State $State -Phase 4)) {
        Write-StepWarning 'Faza 3 nie jest ukończona.'
        if (-not (Request-YesNo -Prompt 'Kontynuować mimo to?' -Default $false)) { return }
    }

    $PhaseStatus = Get-PhaseStatus -State $State -Phase 4
    Write-PhaseHeader -Phase 4 -Status $PhaseStatus

    $RepoRoot = Get-RepoRoot
    $Checklist = if ($State.Phases['4'].ContainsKey('Checklist')) { $State.Phases['4'].Checklist } else { @{} }

    # Resolve log directory
    $Config = Get-AdminConfig
    $LogDirectory = [System.IO.Path]::Combine($Config.ResDir, 'logs')

    # ── Step 1: Load all sessions ─────────────────────────────────────────
    Write-Step -Number 1 -Text 'Wczytywanie sesji...'

    $Sessions = @(Get-Session -Quiet)
    Write-StepOK "Załadowano $($Sessions.Count) sesji"

    # ── Step 2: Count and classify URLs ───────────────────────────────────
    Write-Step -Number 2 -Text 'Zliczanie URL logów...'

    $UrlSet = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase)
    $UniqueUrls = [System.Collections.Generic.List[string]]::new()

    foreach ($S in $Sessions) {
        if ($null -eq $S.Logs) { continue }
        foreach ($Url in $S.Logs) {
            # Skip local paths (already localized)
            if (-not $Url.StartsWith('http', [System.StringComparison]::OrdinalIgnoreCase)) {
                continue
            }
            $Normalized = Normalize-LogUrl -Url $Url
            if ($UrlSet.Add($Normalized)) {
                $UniqueUrls.Add($Normalized)
            }
        }
    }

    $TotalUrls = $UniqueUrls.Count

    if ($TotalUrls -eq 0) {
        Write-StepOK 'Brak URL logów do pobrania.'
        Set-PhaseCompleted -State $State -Phase 4
        Write-PhaseSummary -Phase 4 -Status 'Completed' -Lines @('[OK] Brak URL logów w sesjach')
        if (-not $WhatIf) { Save-MigrationState -State $State }
        return
    }

    # Classify: cached, failed, pending
    $CachedCount = 0
    $FailedMarkerCount = 0
    $PendingCount = 0

    if (-not [System.IO.Directory]::Exists($LogDirectory)) {
        [void][System.IO.Directory]::CreateDirectory($LogDirectory)
    }

    foreach ($Url in $UniqueUrls) {
        $FileName = ConvertTo-LogFileName -NormalizedUrl $Url
        $FilePath = [System.IO.Path]::Combine($LogDirectory, $FileName)
        $FailedPath = "$FilePath.failed"

        if ([System.IO.File]::Exists($FilePath)) {
            $CachedCount++
        } elseif ([System.IO.File]::Exists($FailedPath)) {
            $FailedMarkerCount++
        } else {
            $PendingCount++
        }
    }

    Write-StepOK "Znaleziono $TotalUrls unikalnych URL"
    Write-Host "    Z cache: $CachedCount  |  Wcześniej nieudane: $FailedMarkerCount  |  Do pobrania: $($PendingCount + $FailedMarkerCount)" -ForegroundColor (Resolve-MigrationColor -Role 'Muted')

    Update-PhaseChecklist -State $State -Phase 4 -Item 'UrlsCounted' -Value $true

    # ── Step 3: Fetch logs ────────────────────────────────────────────────
    $ToFetch = $PendingCount + $FailedMarkerCount
    if ($ToFetch -eq 0 -and $CachedCount -eq $TotalUrls) {
        Write-Step -Number 3 -Text 'Wszystkie logi już pobrane.'
        Write-StepOK "Pełny cache: $CachedCount plików"
    } else {
        Write-Step -Number 3 -Text 'Pobieranie logów z internetu...'

        if ($WhatIf) {
            Write-Host "    [WhatIf] Pominięto pobieranie $ToFetch logów" -ForegroundColor (Resolve-MigrationColor -Role 'Muted')
        } else {
            if (-not (Request-YesNo -Prompt "Pobrać $ToFetch logów z internetu? To może zająć kilka minut." -Default $true)) {
                Write-StepWarning 'Pobieranie pominięte przez użytkownika.'
                Set-PhaseInProgress -State $State -Phase 4
                return
            }

            $Result = Invoke-SessionLogFetch -Session $Sessions -RetryFailed -Quiet
            Update-PhaseChecklist -State $State -Phase 4 -Item 'FetchCompleted' -Value $true

            # ── Step 4: Report results ────────────────────────────────────
            Write-Step -Number 4 -Text 'Raport pobierania:'

            Write-Host ''
            Write-Host "    Łącznie URL:     $($Result.Total)" -ForegroundColor (Resolve-MigrationColor -Role 'Accent')
            Write-Host "    Pobrane:         $($Result.Fetched)" -ForegroundColor (Resolve-MigrationColor -Role 'OK')
            Write-Host "    Z cache:         $($Result.Cached)" -ForegroundColor (Resolve-MigrationColor -Role 'Muted')
            Write-Host "    Pominięte:       $($Result.Skipped)" -ForegroundColor (Resolve-MigrationColor -Role 'Muted')

            if ($Result.Failed -gt 0) {
                Write-Host "    Niepowodzenia:   $($Result.Failed)" -ForegroundColor (Resolve-MigrationColor -Role 'Warning')
                Write-Host ''

                # Write failed URLs to file for manual review
                $FailedLogPath = [System.IO.Path]::Combine($Config.ResDir, 'migration-failed-logs.txt')
                $FailedContent = [System.Text.StringBuilder]::new()
                [void]$FailedContent.AppendLine("# Failed log URL downloads - $(Get-Date -Format 'yyyy-MM-dd HH:mm')")
                [void]$FailedContent.AppendLine("# $($Result.Failed) URLs could not be fetched")
                [void]$FailedContent.AppendLine('')
                foreach ($FailedUrl in $Result.FailedUrls) {
                    Write-Host "      $FailedUrl" -ForegroundColor (Resolve-MigrationColor -Role 'Warning')
                    [void]$FailedContent.AppendLine($FailedUrl)
                }
                [System.IO.File]::WriteAllText($FailedLogPath, $FailedContent.ToString())
                Write-Host ''
                Write-Host "    Lista zapisana w: $FailedLogPath" -ForegroundColor (Resolve-MigrationColor -Role 'Muted')
            } else {
                Write-Host "    Niepowodzenia:   0" -ForegroundColor (Resolve-MigrationColor -Role 'OK')
            }

            Update-PhaseChecklist -State $State -Phase 4 -Item 'ReportGenerated' -Value $true

            # ── Step 5: Retry prompt (if failures) ────────────────────────
            if ($Result.Failed -gt 0) {
                Write-Step -Number 5 -Text 'Ponowna próba...'
                if (Request-YesNo -Prompt "Czy ponowić próby dla $($Result.Failed) nieudanych URL?" -Default $false) {
                    $RetryResult = Invoke-SessionLogFetch -Session $Sessions -RetryFailed -Quiet
                    $NewlyFetched = $RetryResult.Fetched
                    Write-StepOK "Ponowna próba: pobrano $NewlyFetched z $($Result.Failed)"

                    if ($RetryResult.Failed -gt 0) {
                        Write-Host "    Nadal nieudane: $($RetryResult.Failed)" -ForegroundColor (Resolve-MigrationColor -Role 'Warning')
                    }
                }
                Update-PhaseChecklist -State $State -Phase 4 -Item 'RetryAttempted' -Value $true
            }
        }
    }

    # ── Mark complete ─────────────────────────────────────────────────────
    Set-PhaseCompleted -State $State -Phase 4
    Write-PhaseSummary -Phase 4 -Status 'Completed' -Lines @(
        "[OK] $TotalUrls unikalnych URL logów"
        "[OK] Logi zapisane w res/logs/"
    )
    if (-not $WhatIf) { Save-MigrationState -State $State }
}
