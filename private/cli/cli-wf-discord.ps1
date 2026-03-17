<#
    .SYNOPSIS
    Discord-domain CLI workflows - PU notification re-send and structured announcement.

    .DESCRIPTION
    This file contains workflow functions for Discord integration, consumed by
    the CLI menu registry (Mode = 'Workflow'). Dot-sourced on demand.

    Helpers:
    - Invoke-DiscordPUNotificationWorkflow: re-send failed PU notification for a player
    - Invoke-DiscordAnnouncementWorkflow:   structured announcement via webhook

    PU notification workflow: queries Get-DiscordDeliveryLog for failed PU
    deliveries, lets user select one, reconstructs the notification message
    from context data and templates, previews, confirms, and re-sends.
    Logged as PU-Resend operation.

    Announcement workflow: 4-step pipeline (webhook URL, title, body, yesno
    confirmation) that formats the message as Markdown bold title + body and
    sends via Send-DiscordMessage. The webhook URL is entered manually each
    time because storing it would require per-channel configuration.

    Both workflows persist delivery results to discord-delivery.json via
    Add-DiscordDeliveryEntry (discord-state.ps1).

    Dependencies: cli-primitives.ps1, cli-fuzzy.ps1, cli-wizard.ps1,
    discord-state.ps1
#>

# ── Discord PU Notification Workflow ─────────────────────────────────────────

function Invoke-DiscordPUNotificationWorkflow {
    param([object]$State, [hashtable]$Entry)

    $Colors = Initialize-WorkflowScreen -Title 'Ponowne powiadomienie PU' -NoSeparator
    $AccentColor   = $Colors.Accent
    $SuccessColor  = $Colors.Success
    $ErrorColor    = $Colors.Error
    $DisabledColor = $Colors.Disabled

    . "$script:ModuleRoot/private/discord-state.ps1"

    # Step 1: Select player
    $PlayerCandidate = Invoke-EngineFuzzySearch -Prompt 'Wybierz gracza' -Source 'players' -State $State
    if (-not $PlayerCandidate) { return }

    $PlayerName = $PlayerCandidate.Name

    # Step 2: Query failed PU deliveries for this player
    $FailedDeliveries = Get-DiscordDeliveryLog -Recipient $PlayerName -Operation PU -FailedOnly -Quiet
    if (-not $FailedDeliveries -or $FailedDeliveries.Count -eq 0) {
        Write-CLILine -Text 'Brak nieudanych powiadomień PU dla tego gracza.' -Color $DisabledColor
        Write-CLILine -Text 'Naciśnij dowolny klawisz...' -Color $DisabledColor
        [void][System.Console]::ReadKey($true)
        return
    }

    # Step 3: Display failed deliveries
    [System.Console]::Clear()
    Write-CLILine -Text 'Ponowne powiadomienie PU' -Color $AccentColor
    Write-Host ''
    Write-CLILine -Text "Gracz: $PlayerName" -Color $DisabledColor
    Write-CLILine -Text "Nieudane powiadomienia ($($FailedDeliveries.Count)):" -Color $AccentColor
    Write-Host ''

    for ($i = 0; $i -lt $FailedDeliveries.Count; $i++) {
        $D = $FailedDeliveries[$i]
        $DateStr = $D.Timestamp.ToString('yyyy-MM-dd HH:mm')
        $CtxStr = if ($D.Context) { " $([char]0x2014) $($D.Context)" } else { '' }
        Write-CLILine -Text "  $($i + 1). [$DateStr]$CtxStr" -Color $ErrorColor
        if ($D.ErrorMessage) {
            Write-CLILine -Text "     Błąd: $($D.ErrorMessage)" -Color $DisabledColor
        }
    }

    Write-Host ''

    # Step 4: Let user select which delivery to re-send
    $SelectStep = New-WizardTextStep -Name 'Selection' -Label "Wybierz numer (1-$($FailedDeliveries.Count))" -Required
    $Selection = Invoke-WizardStep -Step $SelectStep -State $State
    if (-not $Selection -or $Selection -eq '__back__') { return }

    $SelIdx = 0
    if (-not [int]::TryParse($Selection, [ref]$SelIdx) -or $SelIdx -lt 1 -or $SelIdx -gt $FailedDeliveries.Count) {
        Write-CLILine -Text 'Nieprawidłowy numer.' -Color $ErrorColor
        Write-CLILine -Text 'Naciśnij dowolny klawisz...' -Color $DisabledColor
        [void][System.Console]::ReadKey($true)
        return
    }

    $Selected = $FailedDeliveries[$SelIdx - 1]

    # Step 5: Reconstruct PU message from context
    # Context format: "YYYY-MM PU: CharName +3.00, CharName2 +2.00"
    $PUMonth = $null
    $CharEntries = [System.Collections.Generic.List[object]]::new()

    if ($Selected.Context -match '^(\d{4}-\d{2})\s+PU:\s+(.+)$') {
        $PUMonth = $Matches[1]
        $CharParts = $Matches[2].Split(',')
        foreach ($Part in $CharParts) {
            $Trimmed = $Part.Trim()
            if ($Trimmed -match '^(.+?)\s+\+(\d+\.\d+)$') {
                [void]$CharEntries.Add([PSCustomObject]@{
                    CharacterName = $Matches[1]
                    GrantedPU     = [decimal]$Matches[2]
                })
            }
        }
    }

    if (-not $PUMonth -or $CharEntries.Count -eq 0) {
        Write-CLILine -Text 'Nie udało się odtworzyć danych PU z kontekstu.' -Color $ErrorColor
        Write-CLILine -Text 'Naciśnij dowolny klawisz...' -Color $DisabledColor
        [void][System.Console]::ReadKey($true)
        return
    }

    # Player must have a configured webhook for Discord delivery
    $Webhook = $PlayerCandidate.Owner.PRFWebhook
    if (-not $Webhook) {
        Write-CLILine -Text "Gracz '$PlayerName' nie ma skonfigurowanego webhooka." -Color $ErrorColor
        Write-CLILine -Text 'Naciśnij dowolny klawisz...' -Color $DisabledColor
        [void][System.Console]::ReadKey($true)
        return
    }

    # Rebuild notification from templates using current PU sums (may differ from original send)
    $AllCharacters = Get-PlayerCharacter -Quiet
    $Messages = [System.Collections.Generic.List[string]]::new()

    foreach ($CE in $CharEntries) {
        $Character = $AllCharacters | Where-Object {
            [string]::Equals($_.Name, $CE.CharacterName, [System.StringComparison]::OrdinalIgnoreCase)
        } | Select-Object -First 1

        $CurrentPUSum = if ($Character -and $null -ne $Character.PUSum) { [decimal]$Character.PUSum } else { [decimal]0 }

        $MsgVars = @{
            CharacterName = $CE.CharacterName
            PlayerName    = $PlayerName
            GrantedPU     = $CE.GrantedPU.ToString('F2', [System.Globalization.CultureInfo]::InvariantCulture)
            NewPUSum      = $CurrentPUSum.ToString('F2', [System.Globalization.CultureInfo]::InvariantCulture)
        }
        [void]$Messages.Add((Get-AdminTemplate -Name 'pu-notification-base.txt.template' -Variables $MsgVars))
    }

    $FullMessage = $Messages -join "`n`n"

    # Step 6: Preview and confirm
    [System.Console]::Clear()
    Write-CLILine -Text 'Ponowne powiadomienie PU' -Color $AccentColor
    Write-Host ''
    Write-CLILine -Text "Gracz: $PlayerName" -Color $DisabledColor
    Write-CLILine -Text "Miesiąc: $PUMonth" -Color $DisabledColor
    Write-Host ''
    Write-Host "  $([string][char]0x2500 * 50)" -ForegroundColor $DisabledColor
    Write-CLILine -Text 'Podgląd wiadomości:' -Color $AccentColor
    foreach ($MsgLine in $FullMessage.Split("`n")) {
        Write-CLILine -Text "  $MsgLine"
    }
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

    # Step 7: Send and log as PU-Resend
    $Config = Get-AdminConfig
    $DiscordLogPath = [System.IO.Path]::Combine($Config.ResDir, 'discord-delivery.json')
    $ContextStr = $Selected.Context

    try {
        $SendResult = Send-DiscordMessage -Webhook $Webhook -Message $FullMessage -Username 'Bothen'
        Add-DiscordDeliveryEntry -Path $DiscordLogPath `
            -Operation 'PU-Resend' -Recipient $PlayerName `
            -Success $SendResult.Success `
            -StatusCode $SendResult.StatusCode `
            -Context $ContextStr
        Write-CLILine -Text "$([char]0x2713) Wiadomość wysłana." -Color $SuccessColor
    } catch {
        $CaughtStatusCode = 0
        if ($_.Exception.Message -match 'HTTP\s+(\d+)') {
            $CaughtStatusCode = [int]$Matches[1]
        }
        Add-DiscordDeliveryEntry -Path $DiscordLogPath `
            -Operation 'PU-Resend' -Recipient $PlayerName `
            -Success $false `
            -StatusCode $CaughtStatusCode `
            -ErrorMessage $_.Exception.Message `
            -Context $ContextStr
        Write-CLILine -Text "$([char]0x2717) Błąd: $_" -Color $ErrorColor
    }

    Write-CLILine -Text 'Naciśnij dowolny klawisz...' -Color $DisabledColor
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

    . "$script:ModuleRoot/private/discord-state.ps1"
    $Config = Get-AdminConfig
    $DiscordLogPath = [System.IO.Path]::Combine($Config.ResDir, 'discord-delivery.json')

    try {
        $SendResult = Send-DiscordMessage -Webhook $Webhook -Message $Message
        Add-DiscordDeliveryEntry -Path $DiscordLogPath `
            -Operation 'Announcement' -Recipient 'Announcement' `
            -Success $SendResult.Success `
            -StatusCode $SendResult.StatusCode `
            -Context "Ogłoszenie: $Title"
        Write-CLILine -Text "$([char]0x2713) Wiadomość wysłana." -Color $SuccessColor
    }
    catch {
        if ($DiscordLogPath) {
            Add-DiscordDeliveryEntry -Path $DiscordLogPath `
                -Operation 'Announcement' -Recipient 'Announcement' `
                -Success $false `
                -ErrorMessage $_.Exception.Message `
                -Context "Ogłoszenie: $Title"
        }
        Write-CLILine -Text "$([char]0x2717) Błąd: $_" -Color $ErrorColor
    }

    Write-CLILine -Text 'Naciśnij dowolny klawisz...' -Color $DisabledColor
    [void][System.Console]::ReadKey($true)
}
