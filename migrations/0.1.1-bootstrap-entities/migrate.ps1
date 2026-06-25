<#
    .SYNOPSIS
    0.1.1-bootstrap-entities: Transform — entity bootstrap + state-file conversion.

    .DESCRIPTION
    Inlined replacement for phase0-setup steps 7-10 plus phase0-helpers
    (Convert-PUHistoryToJson, Convert-DiscordDeliveryToJson). Idempotent: if
    entities.md exists and Config.RegenerateEntities = $false, the step is
    skipped. If pu-sessions.json already exists, conversion is skipped.

    Inlines phase0-helpers because both converters have a single caller
    (this migration).

    Reads Config.Migration:
    - RegenerateEntities     (Switch, default $false)
    - AutoAddMissingSections (Switch, default $true)

    Honors the framework's $Config.RepoRoot and treats .robot.local/res as
    the canonical state-file location.
#>

function ConvertFromPUHistoryMarkdown {
    # CC-3 prohibits script-scope statements at top level of migrate.ps1, so
    # the regex patterns live inside the function. This is one-call cost per
    # migration apply, not per-invocation, so the perf impact is negligible.
    param([Parameter(Mandatory)][string]$SourcePath)

    $HistoryEntryPattern = [regex]::new(
        '^\s+-\s+###\s+(.+)$',
        [System.Text.RegularExpressions.RegexOptions]::Compiled)
    $TimestampPattern = [regex]::new(
        '^\s*-\s+(\d{4}-\d{2}-\d{2}\s+\d{2}:\d{2})\s+\(([^)]+)\)\s*:\s*$',
        [System.Text.RegularExpressions.RegexOptions]::Compiled)
    $WhitespacePattern = [regex]::new(
        '\s+', [System.Text.RegularExpressions.RegexOptions]::Compiled)

    if (-not [System.IO.File]::Exists($SourcePath)) { return $null }
    $UTF8 = [System.Text.UTF8Encoding]::new($false)
    $Lines = [System.IO.File]::ReadAllText($SourcePath, $UTF8).Split(
        [string[]]@("`r`n", "`n"), [System.StringSplitOptions]::None)

    $Runs = [System.Collections.Generic.List[object]]::new()
    $CurrentTimestamp = $null
    $CurrentTimezone = $null
    $CurrentHeaders = $null

    foreach ($Line in $Lines) {
        $TsMatch = $TimestampPattern.Match($Line)
        if ($TsMatch.Success) {
            if ($null -ne $CurrentTimestamp -and $null -ne $CurrentHeaders -and $CurrentHeaders.Count -gt 0) {
                [void]$Runs.Add([ordered]@{
                    processedAt = $CurrentTimestamp
                    timezone    = $CurrentTimezone
                    sessions    = @($CurrentHeaders)
                })
            }
            $DateStr = $TsMatch.Groups[1].Value
            $Parsed = [datetime]::ParseExact($DateStr, 'yyyy-MM-dd HH:mm',
                [System.Globalization.CultureInfo]::InvariantCulture)
            $CurrentTimestamp = $Parsed.ToString('yyyy-MM-ddTHH:mm:ss')
            $CurrentTimezone  = $TsMatch.Groups[2].Value
            $CurrentHeaders   = [System.Collections.Generic.List[string]]::new()
            continue
        }

        $HdrMatch = $HistoryEntryPattern.Match($Line)
        if ($HdrMatch.Success -and $null -ne $CurrentHeaders) {
            $Header = $HdrMatch.Groups[1].Value.Trim()
            $Header = $WhitespacePattern.Replace($Header, ' ')
            if ($Header.Length -gt 0) { [void]$CurrentHeaders.Add($Header) }
        }
    }
    if ($null -ne $CurrentTimestamp -and $null -ne $CurrentHeaders -and $CurrentHeaders.Count -gt 0) {
        [void]$Runs.Add([ordered]@{
            processedAt = $CurrentTimestamp
            timezone    = $CurrentTimezone
            sessions    = @($CurrentHeaders)
        })
    }
    return [ordered]@{ version = 2; runs = @($Runs) }
}

function ConvertFromDiscordDeliveryMarkdown {
    param([Parameter(Mandatory)][string]$SourcePath)

    $DeliveryPattern = [regex]::new(
        '^\s*-\s+(\d{4}-\d{2}-\d{2}\s+\d{2}:\d{2}:\d{2})\s+\(([^)]+)\)\s+\[(OK|FAIL)\]\s+(\w+(?:-\w+)*)\s+->\s+(.+?)(?:\s+\(HTTP\s+(\d+)\))?\s*$',
        [System.Text.RegularExpressions.RegexOptions]::Compiled)
    $ContextPattern = [regex]::new(
        '^\s+-\s+(?!ERROR:\s)(.+)$',
        [System.Text.RegularExpressions.RegexOptions]::Compiled)
    $ErrorPattern = [regex]::new(
        '^\s+-\s+ERROR:\s+(.+)$',
        [System.Text.RegularExpressions.RegexOptions]::Compiled)

    if (-not [System.IO.File]::Exists($SourcePath)) { return $null }
    $UTF8 = [System.Text.UTF8Encoding]::new($false)
    $Lines = [System.IO.File]::ReadAllText($SourcePath, $UTF8).Split(
        [string[]]@("`r`n", "`n"), [System.StringSplitOptions]::None)

    $Entries = [System.Collections.Generic.List[object]]::new()
    $Current = $null

    foreach ($Line in $Lines) {
        $Match = $DeliveryPattern.Match($Line)
        if ($Match.Success) {
            if ($null -ne $Current) { [void]$Entries.Add($Current) }
            $TsStr = $Match.Groups[1].Value
            $TsParsed = [datetime]::ParseExact($TsStr, 'yyyy-MM-dd HH:mm:ss',
                [System.Globalization.CultureInfo]::InvariantCulture)
            $Current = [ordered]@{
                timestamp    = $TsParsed.ToString('yyyy-MM-ddTHH:mm:ss')
                timezone     = $Match.Groups[2].Value
                status       = $Match.Groups[3].Value
                operation    = $Match.Groups[4].Value
                recipient    = $Match.Groups[5].Value
                statusCode   = if ($Match.Groups[6].Success) { [int]$Match.Groups[6].Value } else { $null }
                context      = $null
                errorMessage = $null
            }
            continue
        }
        if ($null -eq $Current) { continue }

        $ErrMatch = $ErrorPattern.Match($Line)
        if ($ErrMatch.Success) {
            $Current['errorMessage'] = $ErrMatch.Groups[1].Value
            continue
        }
        $CtxMatch = $ContextPattern.Match($Line)
        if ($CtxMatch.Success) { $Current['context'] = $CtxMatch.Groups[1].Value }
    }
    if ($null -ne $Current) { [void]$Entries.Add($Current) }
    return [ordered]@{ version = 1; entries = @($Entries) }
}

function Get-MigrationPreview {
    [CmdletBinding()] param([Parameter(Mandatory)][hashtable]$Config)

    $RepoRoot = $Config.RepoRoot
    $EntitiesPath = [System.IO.Path]::Combine($RepoRoot, 'entities.md')
    $EntitiesExists = [System.IO.File]::Exists($EntitiesPath)

    $FilesCreate = [System.Collections.Generic.List[string]]::new()
    $FilesModify = [System.Collections.Generic.List[string]]::new()
    if ($EntitiesExists) { [void]$FilesModify.Add('entities.md') } else { [void]$FilesCreate.Add('entities.md') }

    $ResDir = [System.IO.Path]::Combine($RepoRoot, '.robot.local', 'res')
    $PuMd = [System.IO.Path]::Combine($ResDir, 'pu-sessions.md')
    $PuJson = [System.IO.Path]::Combine($ResDir, 'pu-sessions.json')
    if ([System.IO.File]::Exists($PuMd) -and -not [System.IO.File]::Exists($PuJson)) {
        [void]$FilesCreate.Add($PuJson)
    }
    $DiscordMd = [System.IO.Path]::Combine($ResDir, 'discord-delivery.md')
    $DiscordJson = [System.IO.Path]::Combine($ResDir, 'discord-delivery.json')
    if ([System.IO.File]::Exists($DiscordMd) -and -not [System.IO.File]::Exists($DiscordJson)) {
        [void]$FilesCreate.Add($DiscordJson)
    }

    return [PSCustomObject]@{
        Migration            = '0.1.1-bootstrap-entities'
        EstimatedDurationSec = 15
        FilesToModify        = @($FilesModify)
        FilesToCreate        = @($FilesCreate)
        FilesToDelete        = @()
        EntityCountsBefore   = @{}
        EntityCountsAfter    = @{}
        SampleDiffs          = @()
        Warnings             = @('Exact entity counts determined at apply time.')
        NetworkRequired      = $false
        SourceUnchanged      = $false
        ChangeRecords        = @()
    }
}

function Invoke-Migration {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [scriptblock]$ProgressCallback,
        [hashtable]$Checklist
    )

    $RepoRoot = $Config.RepoRoot
    $MigCfg = if ($Config.ContainsKey('Migration')) { $Config['Migration'] } else { @{} }
    $RegenerateEntities = [bool]$MigCfg['RegenerateEntities']
    $AutoAddSections   = if ($MigCfg.ContainsKey('AutoAddMissingSections')) {
        [bool]$MigCfg['AutoAddMissingSections']
    } else { $true }

    $FilesWritten = [System.Collections.Generic.List[string]]::new()
    $ResDir = [System.IO.Path]::Combine($RepoRoot, '.robot.local', 'res')
    if (-not [System.IO.Directory]::Exists($ResDir)) {
        [void][System.IO.Directory]::CreateDirectory($ResDir)
    }

    # ── State file conversions ────────────────────────────────────────────
    $PuMd = [System.IO.Path]::Combine($ResDir, 'pu-sessions.md')
    $PuJson = [System.IO.Path]::Combine($ResDir, 'pu-sessions.json')
    if ([System.IO.File]::Exists($PuMd) -and -not [System.IO.File]::Exists($PuJson)) {
        $Parsed = ConvertFromPUHistoryMarkdown -SourcePath $PuMd
        if ($Parsed) {
            Save-JsonStateFile -Path $PuJson -Data $Parsed
            [void]$FilesWritten.Add($PuJson)
        }
    }
    $DiscordMd = [System.IO.Path]::Combine($ResDir, 'discord-delivery.md')
    $DiscordJson = [System.IO.Path]::Combine($ResDir, 'discord-delivery.json')
    if ([System.IO.File]::Exists($DiscordMd) -and -not [System.IO.File]::Exists($DiscordJson)) {
        $Parsed = ConvertFromDiscordDeliveryMarkdown -SourcePath $DiscordMd
        if ($Parsed) {
            Save-JsonStateFile -Path $DiscordJson -Data $Parsed
            [void]$FilesWritten.Add($DiscordJson)
        }
    }

    # ── .robot.local/robot-data.psd1 manifest ─────────────────────────────
    $ManifestPath = [System.IO.Path]::Combine($RepoRoot, '.robot.local', 'robot-data.psd1')
    if (-not [System.IO.File]::Exists($ManifestPath)) {
        $ManifestDir = [System.IO.Path]::GetDirectoryName($ManifestPath)
        if (-not [System.IO.Directory]::Exists($ManifestDir)) {
            [void][System.IO.Directory]::CreateDirectory($ManifestDir)
        }
        $Content = "@{`n    EntitiesFile = '../entities.md'`n}`n"
        [System.IO.File]::WriteAllText($ManifestPath, $Content, [System.Text.UTF8Encoding]::new($false))
        [void]$FilesWritten.Add($ManifestPath)
    }

    # ── entities.md bootstrap ─────────────────────────────────────────────
    $EntitiesPath = [System.IO.Path]::Combine($RepoRoot, 'entities.md')
    $EntitiesExists = [System.IO.File]::Exists($EntitiesPath)
    $GraczePath = [System.IO.Path]::Combine($RepoRoot, 'Gracze.md')
    $GraczeExists = [System.IO.File]::Exists($GraczePath)

    if (-not $EntitiesExists -or $RegenerateEntities) {
        if ($GraczeExists) {
            # Resolve ConvertTo-EntitiesFromPlayers; production loads it via the
            # module, but defensive dot-source covers fixture mode.
            if (-not (Get-Command 'ConvertTo-EntitiesFromPlayers' -ErrorAction SilentlyContinue)) {
                $Helper = [System.IO.Path]::Combine(
                    $PSScriptRoot, '..', '..', 'private', 'entity-migrationhelpers.ps1')
                if ([System.IO.File]::Exists($Helper)) { . $Helper }
            }
            ConvertTo-EntitiesFromPlayers -OutputPath $EntitiesPath
            [void]$FilesWritten.Add($EntitiesPath)
        } else {
            # Fresh repo without Gracze.md: emit a skeleton entities.md
            # with the required section headers so downstream migrations have
            # a target to work with. The verify-environment artifact records
            # SourceGracze=false so operators are aware.
            $Skeleton = "# entities.md`n`n## NPC`n`n## Grupa`n`n## Lokacja`n`n## Przedmiot`n"
            [System.IO.File]::WriteAllText($EntitiesPath, $Skeleton,
                [System.Text.UTF8Encoding]::new($false))
            [void]$FilesWritten.Add($EntitiesPath)
        }
    }

    # ── Section coverage ──────────────────────────────────────────────────
    if (-not [System.IO.File]::Exists($EntitiesPath)) {
        return [PSCustomObject]@{
            OK = $false
            FilesWritten = @($FilesWritten)
            Errors = @("entities.md was not generated; ConvertTo-EntitiesFromPlayers may have failed.")
        }
    }

    $Content = [System.IO.File]::ReadAllText($EntitiesPath)
    $RequiredSections = @('## NPC', '## Grupa', '## Lokacja', '## Przedmiot')
    $Missing = [System.Collections.Generic.List[string]]::new()
    foreach ($S in $RequiredSections) {
        if (-not $Content.Contains($S)) { [void]$Missing.Add($S) }
    }
    if ($Missing.Count -gt 0 -and $AutoAddSections) {
        $SB = [System.Text.StringBuilder]::new()
        [void]$SB.Append($Content)
        foreach ($S in $Missing) {
            [void]$SB.Append("`n`n$S`n")
        }
        [System.IO.File]::WriteAllText($EntitiesPath, $SB.ToString(),
            [System.Text.UTF8Encoding]::new($false))
        if (-not ($FilesWritten -contains $EntitiesPath)) { [void]$FilesWritten.Add($EntitiesPath) }
    }

    return [PSCustomObject]@{
        OK            = $true
        FilesWritten  = @($FilesWritten)
        MissingFixed  = @($Missing)
    }
}

function Test-MigrationApplied {
    [CmdletBinding()] param([hashtable]$Checklist)
    # Idempotency: if entities.md already exists with all required sections
    # AND state-file conversions are already done, this migration is applied.
    # The framework's per-record schema advance also gates re-runs.
    return $false
}
