<#
    .SYNOPSIS
    Session-domain CLI workflows - edit and validation operations.

    .DESCRIPTION
    This file contains workflow functions for session management, consumed by
    the CLI menu registry (Mode = 'Workflow'). Dot-sourced on demand.

    Workflows:
    - Invoke-EditSessionWorkflow: diff review pattern for session edits
    - Invoke-SessionValidation:   session name/date validation with name resolution

    Dependencies: cli-primitives.ps1, cli-wizard.ps1, cli-display.ps1
#>

# ── Edit Session Workflow (Diff Review) ──────────────────────────────────────

function Invoke-EditSessionWorkflow {
    param([object]$State, [hashtable]$Entry)

    $AccentColor = Get-CLIColor -Role 'Accent'

    Write-CLILine -Text 'Edycja sesji' -Color $AccentColor
    Write-Host ''
    Write-CLILine -Text 'Wyszukaj sesję do edycji:' -Color $AccentColor

    # For now: use Set-Session wizard with overrides
    $EditEntry = @{
        Function = 'Set-Session'
        Overrides = @{
            'Session'        = @{ Hidden = $true }
            'File'           = @{ Type = 'text'; Label = 'Ścieżka do pliku sesji' }
            'Date'           = @{ Type = 'date'; Label = 'Data sesji' }
            'Locations'      = @{ Type = 'multi-entry'; EntrySource = 'locations' }
            'Narrator'       = @{ Type = 'multitext'; Label = 'Narratorzy (po jednym)' }
            'UpgradeFormat'  = @{ Hidden = $true }
            'Properties'     = @{ Hidden = $true }
            'DateOverride'   = @{ Hidden = $true }
        }
    }

    $WizResult = Invoke-Wizard -RegistryEntry $EditEntry -State $State
    if ($WizResult -eq '__quit__') { return '__quit__' }
}

# ── Session Validation ───────────────────────────────────────────────────────

function Invoke-SessionValidation {
    param([object]$State, [hashtable]$Entry)

    $AccentColor = Get-CLIColor -Role 'Accent'
    $SuccessColor = Get-CLIColor -Role 'Success'
    $WarningColor = Get-CLIColor -Role 'Warning'
    $ErrorColor = Get-CLIColor -Role 'Error'

    Write-CLILine -Text 'Walidacja sesji' -Color $AccentColor

    if ($Entry.PreChecks) {
        Show-InfoBox -Checks $Entry.PreChecks
    }

    # Get date range
    $MinDateStep = [PSCustomObject]@{
        Name = 'MinDate'; Label = 'Od daty'; StepType = 'date'; Required = $false
        Source = $null; Options = $null; SubSteps = $null; EntrySource = $null
        Condition = $null; Transform = $null; Default = $null
    }
    $MinDate = Invoke-WizardStep -Step $MinDateStep -State $State
    if ($MinDate -eq '__back__') { return }

    $MaxDateStep = [PSCustomObject]@{
        Name = 'MaxDate'; Label = 'Do daty'; StepType = 'date'; Required = $false
        Source = $null; Options = $null; SubSteps = $null; EntrySource = $null
        Condition = $null; Transform = $null; Default = $null
    }
    $MaxDate = Invoke-WizardStep -Step $MaxDateStep -State $State
    if ($MaxDate -eq '__back__') { return }

    Write-Host '  Pobieranie sesji...' -ForegroundColor (Get-CLIColor -Role 'Disabled')

    $SessionParams = @{}
    if ($MinDate) { $SessionParams['MinDate'] = $MinDate }
    if ($MaxDate) { $SessionParams['MaxDate'] = $MaxDate }

    try {
        $Sessions = Get-Session @SessionParams
        $IssuesFound = $false

        Write-Host ''
        Write-CLILine -Text "Znaleziono $($Sessions.Count) sesji." -Color $AccentColor
        Write-Host ''

        foreach ($Session in $Sessions) {
            $HasIssue = $false
            $Issues = [System.Collections.Generic.List[string]]::new()

            # Check PU character names
            if ($Session.PU) {
                foreach ($PUEntry in $Session.PU) {
                    $CharName = if ($PUEntry.Character) { $PUEntry.Character } elseif ($PUEntry.Name) { $PUEntry.Name } else { $null }
                    if (-not $CharName) { continue }

                    $Resolved = Resolve-Name -Query $CharName `
                        -Index $State.NameIndex.Index `
                        -StemIndex $State.NameIndex.StemIndex `
                        -BKTree $State.NameIndex.BKTree `
                        -Cache $State.ResolveCache

                    if (-not $Resolved) {
                        [void]$Issues.Add("PU: Nierozwiązana postać '$CharName'")
                        $HasIssue = $true
                    }
                }
            }

            # Check Changes entity names
            if ($Session.Changes) {
                foreach ($Change in $Session.Changes) {
                    $EntityName = $Change.EntityName
                    if (-not $EntityName) { continue }

                    $Resolved = Resolve-Name -Query $EntityName `
                        -Index $State.NameIndex.Index `
                        -StemIndex $State.NameIndex.StemIndex `
                        -BKTree $State.NameIndex.BKTree `
                        -Cache $State.ResolveCache

                    if (-not $Resolved) {
                        [void]$Issues.Add("Zmiany: Nierozwiązana encja '$EntityName'")
                        $HasIssue = $true
                    }
                }
            }

            if ($HasIssue) {
                $IssuesFound = $true
                $Title = if ($Session.Title) { $Session.Title } else { $Session.Header }
                Write-CLILine -Text "$([char]0x2717) $Title" -Color $ErrorColor
                foreach ($Issue in $Issues) {
                    Write-CLILine -Text "    $Issue" -Color $WarningColor
                }
            }
        }

        if (-not $IssuesFound) {
            Write-CLILine -Text "$([char]0x2713) Wszystkie sesje przeszły walidację." -Color $SuccessColor
        }
    }
    catch {
        Write-CLILine -Text "$([char]0x2717) Błąd walidacji: $_" -Color $ErrorColor
    }

    Write-Host ''
    Write-CLILine -Text 'Naciśnij dowolny klawisz...' -Color (Get-CLIColor -Role 'Disabled')
    [void][System.Console]::ReadKey($true)
}
