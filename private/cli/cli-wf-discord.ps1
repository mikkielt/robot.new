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

    $Player = Show-FuzzySearch -Prompt 'Wybierz gracza' -Source 'players' -State $State
    if (-not $Player) { return }

    $MonthStep = [PSCustomObject]@{
        Name = 'Month'; Label = 'Miesiąc (RRRR-MM)'; StepType = 'text'; Required = $true
        Source = $null; Options = $null; SubSteps = $null; EntrySource = $null
        Condition = $null; Transform = $null; Default = $null
    }
    $Month = Invoke-WizardStep -Step $MonthStep -State $State
    if (-not $Month -or $Month -eq '__back__') { return }

    Write-CLILine -Text 'Nie zaimplementowano - wymaga integracji z logiem PU.' -Color (Get-CLIColor -Role 'Disabled')
    Write-CLILine -Text 'Naciśnij dowolny klawisz...' -Color (Get-CLIColor -Role 'Disabled')
    [void](Read-ArrowKey)
}

# ── Discord Announcement Workflow ────────────────────────────────────────────

function Invoke-DiscordAnnouncementWorkflow {
    param([object]$State, [hashtable]$Entry)

    $AccentColor = Get-CLIColor -Role 'Accent'
    $SuccessColor = Get-CLIColor -Role 'Success'
    $ErrorColor = Get-CLIColor -Role 'Error'
    $DisabledColor = Get-CLIColor -Role 'Disabled'

    # ── Step 1: Webhook URL ──
    [System.Console]::Clear()
    Write-CLILine -Text 'Ogłoszenie Discord' -Color $AccentColor
    Write-Host ''

    $WebhookStep = [PSCustomObject]@{
        Name = 'WebhookUrl'; Label = 'Webhook URL'; StepType = 'text'; Required = $true
        Source = $null; Options = $null; SubSteps = $null; EntrySource = $null
        Condition = $null; Transform = $null; Default = $null
    }
    $Webhook = Invoke-WizardStep -Step $WebhookStep -State $State
    if (-not $Webhook -or $Webhook -eq '__back__') { return }

    # ── Step 2: Title ──
    [System.Console]::Clear()
    Write-CLILine -Text 'Ogłoszenie Discord' -Color $AccentColor
    Write-Host ''
    Write-CLILine -Text "  Webhook: $($Webhook.Substring(0, [System.Math]::Min(50, $Webhook.Length)))..." -Color $DisabledColor
    Write-Host ''

    $TitleStep = [PSCustomObject]@{
        Name = 'Title'; Label = 'Tytuł ogłoszenia'; StepType = 'text'; Required = $true
        Source = $null; Options = $null; SubSteps = $null; EntrySource = $null
        Condition = $null; Transform = $null; Default = $null
    }
    $Title = Invoke-WizardStep -Step $TitleStep -State $State
    if (-not $Title -or $Title -eq '__back__') { return }

    # ── Step 3: Body ──
    [System.Console]::Clear()
    Write-CLILine -Text 'Ogłoszenie Discord' -Color $AccentColor
    Write-Host ''
    Write-CLILine -Text "  Webhook: $($Webhook.Substring(0, [System.Math]::Min(50, $Webhook.Length)))..." -Color $DisabledColor
    Write-CLILine -Text "  Tytuł: $Title" -Color $DisabledColor
    Write-Host ''

    $BodyStep = [PSCustomObject]@{
        Name = 'Body'; Label = 'Treść ogłoszenia'; StepType = 'text'; Required = $true
        Source = $null; Options = $null; SubSteps = $null; EntrySource = $null
        Condition = $null; Transform = $null; Default = $null
    }
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

    Write-CLILine -Text 'Wysłać?' -Color $AccentColor
    $Confirm = Show-ArrowMenu -Items @(
        [PSCustomObject]@{ ID = 'yes'; Label = 'Tak, wyślij'; Description = ''; RoleTag = $null; InfoText = $null; Disabled = $false }
        [PSCustomObject]@{ ID = 'no';  Label = 'Anuluj';      Description = ''; RoleTag = $null; InfoText = $null; Disabled = $false }
    ) -ShowBack

    if ($Confirm -ne 'yes') {
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
    [void](Read-ArrowKey)
}
