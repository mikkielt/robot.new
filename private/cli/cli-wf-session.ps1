<#
    .SYNOPSIS
    Session-domain CLI workflows - edit and validation operations.

    .DESCRIPTION
    This file contains workflow functions for session management, consumed by
    the CLI menu registry (Mode = 'Workflow'). Dot-sourced on demand.

    Helpers:
    - Invoke-EditSessionWorkflow: auto-generated wizard for Set-Session with UI overrides
    - Invoke-SessionValidation:   session name/date validation with name resolution

    Edit workflow: delegates to Invoke-Wizard with Set-Session overrides that
    hide internal parameters (Session, UpgradeFormat, Properties, DateOverride)
    and type-hint user-facing ones (multi-entry for Locations, multitext for
    Narrator, date picker for Date).

    Validation: iterates all sessions in the date range and attempts
    Resolve-Name on every @PU character name and @Zmiany entity name.
    Unresolvable names are reported per-session with cross marks (errors)
    for PU names and warning marks for entity changes. This pre-flight
    check catches typos before they cause PU assignment failures (fail-early
    policy: unresolved names abort the entire PU assignment).

    Dependencies: cli-primitives.ps1, cli-wizard.ps1
#>

# ── Edit Session Workflow (Diff Review) ──────────────────────────────────────

function Invoke-EditSessionWorkflow {
    param([object]$State, [hashtable]$Entry)

    $AccentColor = Get-CLIColor -Role 'Accent'

    Write-CLILine -Text 'Edycja sesji' -Color $AccentColor
    Write-Host ''
    Write-CLILine -Text 'Wyszukaj sesję do edycji:' -Color $AccentColor

    # Delegate to auto-generated wizard with overrides that hide internal params
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

    # Date range scopes which sessions to validate
    $MinDateStep = New-WizardDateStep -Name 'MinDate' -Label 'Od daty'
    $MinDate = Invoke-WizardStep -Step $MinDateStep -State $State
    if ($MinDate -eq '__back__') { return }

    $MaxDateStep = New-WizardDateStep -Name 'MaxDate' -Label 'Do daty'
    $MaxDate = Invoke-WizardStep -Step $MaxDateStep -State $State
    if ($MaxDate -eq '__back__') { return }

    $ValProg = New-ProgressState -Title 'Walidacja sesji' -TotalSteps 1
    Start-ProgressStep -State $ValProg -Label 'Sesje'

    $SessionParams = @{}
    if ($MinDate) { $SessionParams['MinDate'] = $MinDate }
    if ($MaxDate) { $SessionParams['MaxDate'] = $MaxDate }

    try {
        $SessCB = { param($C,$T,$D); Update-ProgressStep -State $ValProg -Detail "$C/$T" }.GetNewClosure()
        $SessionParams['ProgressCallback'] = $SessCB
        $Sessions = Get-Session @SessionParams
        Complete-ProgressStep -State $ValProg -Detail "$($Sessions.Count)"
        Complete-ProgressGroup -State $ValProg
        $IssuesFound = $false

        Write-Host ''
        Write-CLILine -Text "Znaleziono $($Sessions.Count) sesji." -Color $AccentColor
        Write-Host ''

        foreach ($Session in $Sessions) {
            $HasIssue = $false
            $Issues = [System.Collections.Generic.List[string]]::new()

            # Validate @PU character names against the name index
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

            # Validate @Zmiany entity names against the name index
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
        Complete-ProgressStep -State $ValProg -Detail 'BŁĄD' -Failed
        Complete-ProgressGroup -State $ValProg
        Write-CLILine -Text "$([char]0x2717) Błąd walidacji: $_" -Color $ErrorColor
    }

    Write-Host ''
    Write-CLILine -Text 'Naciśnij dowolny klawisz...' -Color (Get-CLIColor -Role 'Disabled')
    [void][System.Console]::ReadKey($true)
}
