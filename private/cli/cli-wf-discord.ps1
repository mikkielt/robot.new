<#
    .SYNOPSIS
    Discord-domain CLI workflows - PU notification and structured announcement.

    .DESCRIPTION
    This file contains workflow functions for Discord integration, consumed by
    the CLI menu registry (Mode = 'Workflow'). Dot-sourced on demand.

    Workflows:
    - Invoke-DiscordPUNotificationWorkflow: re-send PU notification for a player
    - Invoke-DiscordAnnouncementWorkflow:   structured announcement via webhook

    Dependencies: cli-primitives.ps1, cli-fuzzy.ps1, cli-wizard.ps1
#>

# ── Discord PU Notification Workflow ─────────────────────────────────────────

function Invoke-DiscordPUNotificationWorkflow {
    param([object]$State, [hashtable]$Entry)

    $AccentColor = Get-CLIColor -Role 'Accent'

    Write-CLILine -Text 'Ponowne powiadomienie PU' -Color $AccentColor
    Write-Host ''

    $Player = Invoke-EngineFuzzySearch -Prompt 'Wybierz gracza' -Source 'players' -State $State
    if (-not $Player) { return }

    $MonthStep = New-WizardTextStep -Name 'Month' -Label 'Miesiąc (RRRR-MM)' -Required
    $Month = Invoke-WizardStep -Step $MonthStep -State $State
    if (-not $Month -or $Month -eq '__back__') { return }

    Write-CLILine -Text 'Nie zaimplementowano - wymaga integracji z logiem PU.' -Color (Get-CLIColor -Role 'Disabled')
    Write-CLILine -Text 'Naciśnij dowolny klawisz...' -Color (Get-CLIColor -Role 'Disabled')
    [void][System.Console]::ReadKey($true)
}

# ── Discord Announcement Workflow ────────────────────────────────────────────

function Invoke-DiscordAnnouncementWorkflow {
    param([object]$State, [hashtable]$Entry)

    $Colors = Initialize-WorkflowScreen -Title 'Ogłoszenie Discord' -NoSeparator
    $AccentColor   = $Colors.Accent
    $SuccessColor  = $Colors.Success
    $ErrorColor    = $Colors.Error
    $DisabledColor = $Colors.Disabled

    # ── Step 1: Webhook URL ──

    $WebhookStep = New-WizardTextStep -Name 'WebhookUrl' -Label 'Webhook URL' -Required
    $Webhook = Invoke-WizardStep -Step $WebhookStep -State $State
    if (-not $Webhook -or $Webhook -eq '__back__') { return }

    # ── Step 2: Title ──
    [System.Console]::Clear()
    Write-CLILine -Text 'Ogłoszenie Discord' -Color $AccentColor
    Write-Host ''
    Write-CLILine -Text "  Webhook: $($Webhook.Substring(0, [System.Math]::Min(50, $Webhook.Length)))..." -Color $DisabledColor
    Write-Host ''

    $TitleStep = New-WizardTextStep -Name 'Title' -Label 'Tytuł ogłoszenia' -Required
    $Title = Invoke-WizardStep -Step $TitleStep -State $State
    if (-not $Title -or $Title -eq '__back__') { return }

    # ── Step 3: Body ──
    [System.Console]::Clear()
    Write-CLILine -Text 'Ogłoszenie Discord' -Color $AccentColor
    Write-Host ''
    Write-CLILine -Text "  Webhook: $($Webhook.Substring(0, [System.Math]::Min(50, $Webhook.Length)))..." -Color $DisabledColor
    Write-CLILine -Text "  Tytuł: $Title" -Color $DisabledColor
    Write-Host ''

    $BodyStep = New-WizardTextStep -Name 'Body' -Label 'Treść ogłoszenia' -Required
    $Body = Invoke-WizardStep -Step $BodyStep -State $State
    if (-not $Body -or $Body -eq '__back__') { return }

    $Message = "**$Title**`n`n$Body"

    # ── Step 4: Preview + Confirm ──
    [System.Console]::Clear()
    Write-CLILine -Text 'Ogłoszenie Discord' -Color $AccentColor
    Write-Host ''
    Write-Host "  $([string][char]0x2500 * 50)" -ForegroundColor $DisabledColor
    Write-CLILine -Text 'Podgląd wiadomości:' -Color $AccentColor
    Write-CLILine -Text "  **$Title**"
    Write-CLILine -Text "  $Body"
    Write-Host "  $([string][char]0x2500 * 50)" -ForegroundColor $DisabledColor
    Write-Host ''

    $ConfirmComponent = New-WizardStepComponent -Label 'Wysłać wiadomość?' `
        -StepNumber 0 -TotalSteps 0 -StepType 'yesno'
    $Confirm = Invoke-EngineLifecycle -Component $ConfirmComponent -State $State
    if ($Confirm -eq '__quit__') { return '__quit__' }

    if ($Confirm -ne $true) {
        Write-CLILine -Text 'Anulowano.' -Color $DisabledColor
        return
    }

    try {
        Send-DiscordMessage -WebhookUrl $Webhook -Message $Message
        Write-CLILine -Text "$([char]0x2713) Wiadomość wysłana." -Color $SuccessColor
    }
    catch {
        Write-CLILine -Text "$([char]0x2717) Błąd: $_" -Color $ErrorColor
    }

    Write-CLILine -Text 'Naciśnij dowolny klawisz...' -Color $DisabledColor
    [void][System.Console]::ReadKey($true)
}
