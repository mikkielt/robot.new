<#
    .SYNOPSIS
    Modifies existing session metadata and/or body content in Markdown files.

    .DESCRIPTION
    This file contains Set-Session. It dot-sources format-sessionblock.ps1
    for shared rendering helpers (ConvertTo-Gen4MetadataBlock,
    ConvertTo-SessionMetadata) and session-decomposehelpers.ps1 for section
    decomposition and format-conversion helpers (Find-SessionInFile,
    Split-SessionSection, ConvertTo-Gen4FromRawBlock, ConvertFrom-ItalicLocation,
    ConvertFrom-PlainTextLog, Get-FormatFromSplit).

    Processing pipeline:
    1. Resolve target session: pipeline Session objects carry the exact header
       and FilePaths; explicit -Date + -File mode scans a single file by date.
    2. Resolve effective values: explicit params take priority over -Properties
       hashtable over null (leave unchanged). This three-level priority chain
       allows both direct parameter binding and bulk property bags from CLI.
    3. Guard: fail early if no modifications were actually specified.
    4. Per file: read content, detect newline style (CRLF/LF), find the session
       section via Find-SessionInFile, decompose via Split-SessionSection.
    5. Format safety: metadata writes on pre-Gen4 sessions require -UpgradeFormat
       to prevent accidental format mixing.
    6. Build replacement: new metadata blocks (Gen4), body content, and preserved
       blocks (Objaśnienia, Efekty) are reassembled with consistent spacing.
    7. Splice: replace the session's lines in the original file array, write
       via ShouldProcess gate, fire BeforeWrite/AfterWrite plugin hooks.
    8. Cache invalidation: Clear-ParseCaches is called after each successful
       write to prevent stale cached data (WP-2 Markdown cache, WP-4 session
       file cache) from masking the mutation on subsequent Get-Session calls.
    9. Eager graph refresh: after non-batch writes, update the session graph
       index for Tiers 0+1 so the graph stays current without a full rebuild.

    Metadata replacement is always full-replace (not merge). Pass @() to clear
    a block. Pass $null (or omit) to leave a block unchanged.

    Format upgrade (-UpgradeFormat) converts Gen2/Gen3 metadata to Gen4
    @-prefixed syntax. During upgrade, narrator normalization is injected from
    migration/narrator-normalization.ps1 when no explicit narrator is provided.
    Non-metadata blocks (Objaśnienia, Efekty) are preserved as-is.

    Module-level data:
    - $script:HasOpCtx: operation context flag (from admin-config.ps1)
#>

. "$script:ModuleRoot/private/temporal-helpers.ps1"
. "$script:ModuleRoot/private/format-sessionblock.ps1"
. "$script:ModuleRoot/private/log-fetchhelpers.ps1"
. "$script:ModuleRoot/private/session-decomposehelpers.ps1"

function Set-Session {
    <#
        .SYNOPSIS
        Modifies existing session metadata and/or body content in Markdown files.
    #>

    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium', DefaultParameterSetName = 'Pipeline')] param(
        [Parameter(ParameterSetName = 'Pipeline', Mandatory, ValueFromPipeline, HelpMessage = "Session object from Get-Session pipeline")]
        [object]$Session,

        [Parameter(ParameterSetName = 'Explicit', Mandatory, HelpMessage = "Session date to locate")]
        [datetime]$Date,

        [Parameter(ParameterSetName = 'Explicit', Mandatory, HelpMessage = "Path to Markdown file containing the session")]
        [ValidateNotNullOrEmpty()]
        [string]$File,

        [Parameter(HelpMessage = "Location names to set (full-replace)")]
        [string[]]$Locations,

        [Parameter(HelpMessage = "PU award entries to set (Character + Value)")]
        [object[]]$PU,

        [Parameter(HelpMessage = "Session log URLs to set")]
        [string[]]$Logs,

        [Parameter(HelpMessage = "Entity state changes (Zmiany entries) to set")]
        [object[]]$Changes,

        [Parameter(HelpMessage = "Narrator canonical names for @Narrator metadata override")]
        [string[]]$Narrator,

        [Parameter(HelpMessage = "Date override in YYYY-MM-DD format for @Data metadata")]
        [string]$DateOverride,

        [Parameter(HelpMessage = "Intel targeting entries to set")]
        [object[]]$Intel,

        [Parameter(HelpMessage = "Body text content to replace")]
        [string]$Content,

        [Parameter(HelpMessage = "Hashtable of property overrides (alternative to individual parameters)")]
        [hashtable]$Properties,

        [Parameter(HelpMessage = "Convert Gen2/Gen3 metadata to Gen4 @-prefixed syntax")]
        [switch]$UpgradeFormat
    )

    process {
        if ($script:HasOpCtx) { Clear-OperationContext }

        # Pipeline sessions carry all file copies (multi-file sessions);
        # explicit mode scans a single file by date match.
        if ($PSCmdlet.ParameterSetName -eq 'Pipeline') {
            $TargetHeader = $Session.Header
            $TargetFiles = if ($Session.FilePaths) {
                @($Session.FilePaths)
            } else {
                @($Session.FilePath)
            }
        }
        else {
            $Root = Get-RepoRoot
            $FullPath = if ([System.IO.Path]::IsPathRooted($File)) { $File }
                        else { [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($Root, $File)) }
            if (-not [System.IO.File]::Exists($FullPath)) {
                throw "File not found: $FullPath"
            }
            $TargetHeader = $null
            $TargetFiles = @($FullPath)
        }

        # Priority chain: explicit param > Properties hashtable > null (leave unchanged)

        $EffLocations = if ($PSBoundParameters.ContainsKey('Locations')) { $Locations }
                        elseif ($Properties -and $Properties.ContainsKey('Locations')) { $Properties.Locations }
                        else { $null }

        $EffPU = if ($PSBoundParameters.ContainsKey('PU')) { $PU }
                 elseif ($Properties -and $Properties.ContainsKey('PU')) { $Properties.PU }
                 else { $null }

        $EffLogs = if ($PSBoundParameters.ContainsKey('Logs')) { $Logs }
                   elseif ($Properties -and $Properties.ContainsKey('Logs')) { $Properties.Logs }
                   else { $null }

        $EffChanges = if ($PSBoundParameters.ContainsKey('Changes')) { $Changes }
                      elseif ($Properties -and $Properties.ContainsKey('Changes')) { $Properties.Changes }
                      else { $null }

        $EffIntel = if ($PSBoundParameters.ContainsKey('Intel')) { $Intel }
                    elseif ($Properties -and $Properties.ContainsKey('Intel')) { $Properties.Intel }
                    else { $null }

        $EffContent = if ($PSBoundParameters.ContainsKey('Content')) { $Content }
                      elseif ($Properties -and $Properties.ContainsKey('Content')) { $Properties.Content }
                      else { $null }

        $EffNarrator = if ($PSBoundParameters.ContainsKey('Narrator')) { $Narrator }
                       elseif ($Properties -and $Properties.ContainsKey('Narrator')) { $Properties.Narrator }
                       else { $null }

        $EffDateOverride = if ($PSBoundParameters.ContainsKey('DateOverride')) { $DateOverride }
                           elseif ($Properties -and $Properties.ContainsKey('DateOverride')) { $Properties.DateOverride }
                           else { $null }

        # Guard: fail early if caller didn't actually specify any modifications
        $HasChanges = ($null -ne $EffLocations) -or ($null -ne $EffPU) -or ($null -ne $EffLogs) -or
                      ($null -ne $EffChanges) -or ($null -ne $EffIntel) -or ($null -ne $EffContent) -or
                      ($null -ne $EffNarrator) -or ($null -ne $EffDateOverride) -or $UpgradeFormat
        if (-not $HasChanges) {
            Write-Warning 'No changes specified. Use -Locations, -PU, -Logs, -Changes, -Intel, -Content, -DateOverride, -Properties, or -UpgradeFormat.'
            return
        }

        $UTF8NoBOM = [System.Text.UTF8Encoding]::new($false)

        # Upgrade rewrites remote log URLs to local res/logs/ paths via ConvertFrom-PlainTextLog
        $LogDir = $null
        if ($UpgradeFormat) {
            try {
                $Config = Get-AdminConfig
                $LogDir = [System.IO.Path]::Combine($Config.ResDir, 'logs')
            } catch { }
        }

        # Table-driven dispatch: each entry maps a metadata concept to its Gen4 tag,
        # its legacy format aliases, and the caller's effective value. This avoids
        # per-block if/else chains and makes adding new metadata blocks a one-line change.
        $MetaConfig = @(
            @{ Key = 'narrator';  Gen4Tag = 'Narrator'; OrigKeys = @('narrator');                      Effective = $EffNarrator }
            @{ Key = 'data';      Gen4Tag = 'Data';     OrigKeys = @('data');                          Effective = if ($EffDateOverride) { @($EffDateOverride) } else { $null } }
            @{ Key = 'locations'; Gen4Tag = 'Lokacje';  OrigKeys = @('locations', 'locations-italic'); Effective = $EffLocations }
            @{ Key = 'logs';      Gen4Tag = 'Logi';     OrigKeys = @('logs', 'logs-plain');            Effective = $EffLogs }
            @{ Key = 'pu';        Gen4Tag = 'PU';       OrigKeys = @('pu');                            Effective = $EffPU }
            @{ Key = 'changes';   Gen4Tag = 'Zmiany';   OrigKeys = @('changes');                       Effective = $EffChanges }
            @{ Key = 'intel';     Gen4Tag = 'Intel';     OrigKeys = @('intel');                         Effective = $EffIntel }
        )

        # Lazy-loaded: narrator normalization data is expensive to import, so defer until first use
        $NarratorMappings = $null

        foreach ($FilePath in $TargetFiles) {
            try {
                if (-not [System.IO.File]::Exists($FilePath)) {
                    Write-Error "File not found: $FilePath"
                    continue
                }

                $FileContent = [System.IO.File]::ReadAllText($FilePath, $UTF8NoBOM)
                $NL = if ($FileContent.Contains("`r`n")) { "`r`n" } else { "`n" }
                $FileLines = $FileContent.Split([string[]]@("`r`n", "`n"), [System.StringSplitOptions]::None)

                $Found = if ($TargetHeader) {
                    Find-SessionInFile -Lines $FileLines -TargetHeader $TargetHeader
                } else {
                    Find-SessionInFile -Lines $FileLines -TargetDate $Date
                }

                if ($Found.Count -eq 0) {
                    $Desc = if ($TargetHeader) { "header '$TargetHeader'" } else { "date $($Date.ToString('yyyy-MM-dd'))" }
                    throw "Session not found in '${FilePath}': no matching $Desc"
                }
                if ($Found.Count -gt 1 -and -not $TargetHeader) {
                    $Headers = ($Found | ForEach-Object { $_.HeaderText }) -join "', '"
                    throw "Ambiguous: $($Found.Count) sessions on $($Date.ToString('yyyy-MM-dd')) in '${FilePath}': '$Headers'. Use pipeline input to specify exact session."
                }

                $Match = $Found[0]

                # Extract just the session's content lines (between header and next header/EOF)
                $SecStart = $Match.SectionStartIdx
                $SecEnd   = $Match.SectionEndIdx - 1
                $SectionLines = if ($SecStart -le $SecEnd) { $FileLines[$SecStart..$SecEnd] } else { @() }

                # Decompose into body, metadata, and preserved blocks (Efekty/Objaśnienia)
                $Split = Split-SessionSection -Lines $SectionLines

                # Format safety guard: require -UpgradeFormat when modifying metadata on pre-Gen4 sessions
                $SessionFormat = if ($PSCmdlet.ParameterSetName -eq 'Pipeline' -and $Session.Format) {
                    $Session.Format
                } else {
                    Get-FormatFromSplit -MetaBlocks $Split.MetaBlocks
                }

                if ($SessionFormat -ne 'Gen4') {
                    $HasMetadataChanges = ($null -ne $EffLocations) -or ($null -ne $EffPU) -or
                                          ($null -ne $EffLogs) -or ($null -ne $EffChanges) -or
                                          ($null -ne $EffIntel) -or ($null -ne $EffNarrator) -or
                                          ($null -ne $EffDateOverride)
                    if ($HasMetadataChanges -and -not $UpgradeFormat) {
                        throw "Session '$($Match.HeaderText)' is in $SessionFormat format. Use -UpgradeFormat to convert metadata to Gen4."
                    }
                }

                # UpgradeFormat: inject @Narrator from normalization file when no explicit narrator was provided
                if ($UpgradeFormat -and $null -eq $EffNarrator -and -not $Split.MetaBlocks.Contains('narrator')) {
                    if ($null -eq $NarratorMappings) {
                        . "$script:ModuleRoot/migration/narrator-normalization.ps1"
                        $NarratorMappings = Import-NarratorMappings
                    }
                    if ($NarratorMappings.Count -gt 0) {
                        $HdrText = $Match.HeaderText
                        $LC = $HdrText.LastIndexOf(',')
                        if ($LC -ge 0 -and ($HdrText.Split(',').Length - 1) -ge 2) {
                            $RawNarr = $HdrText.Substring($LC + 1).Trim()
                            if ($NarratorMappings.ContainsKey($RawNarr)) {
                                foreach ($MC in $MetaConfig) {
                                    if ($MC.Key -eq 'narrator') { $MC.Effective = $NarratorMappings[$RawNarr]; break }
                                }
                            }
                        }
                    }
                }

                $MetaOutput = [System.Collections.Generic.List[string]]::new(5)

                foreach ($MC in $MetaConfig) {
                    $BlockText = $null

                    if ($null -ne $MC.Effective) {
                        # Caller-provided values always render as Gen4 regardless of source format
                        $BlockText = ConvertTo-Gen4MetadataBlock -Tag $MC.Gen4Tag -Items $MC.Effective -NL $NL
                    }
                    elseif ($UpgradeFormat) {
                        # Upgrade existing block to Gen4
                        foreach ($OrigKey in $MC.OrigKeys) {
                            if ($Split.MetaBlocks.Contains($OrigKey)) {
                                if ($OrigKey -eq 'locations-italic') {
                                    $BlockText = ConvertFrom-ItalicLocation -Line $Split.MetaBlocks[$OrigKey][0] -NL $NL
                                }
                                elseif ($OrigKey -eq 'logs-plain') {
                                    $BlockText = ConvertFrom-PlainTextLog -Lines $Split.MetaBlocks[$OrigKey] -NL $NL -LogDirectory $LogDir
                                }
                                else {
                                    $BlockText = ConvertTo-Gen4FromRawBlock -Tag $MC.Key -Lines $Split.MetaBlocks[$OrigKey] -NL $NL -LogDirectory $LogDir
                                }
                                break
                            }
                        }
                    }
                    else {
                        # Preserve original lines
                        foreach ($OrigKey in $MC.OrigKeys) {
                            if ($Split.MetaBlocks.Contains($OrigKey)) {
                                $BlockText = $Split.MetaBlocks[$OrigKey] -join $NL
                                break
                            }
                        }
                    }

                    if ($BlockText) { $MetaOutput.Add($BlockText) }
                }

                # Trim leading/trailing blanks so reassembly spacing is controlled below
                $Body = if ($null -ne $EffContent) {
                    $EffContent
                } else {
                    $BLines = [System.Collections.Generic.List[string]]::new($Split.BodyLines)
                    while ($BLines.Count -gt 0 -and [string]::IsNullOrWhiteSpace($BLines[0])) {
                        $BLines.RemoveAt(0)
                    }
                    while ($BLines.Count -gt 0 -and [string]::IsNullOrWhiteSpace($BLines[$BLines.Count - 1])) {
                        $BLines.RemoveAt($BLines.Count - 1)
                    }
                    if ($BLines.Count -gt 0) { $BLines -join $NL } else { '' }
                }

                # Objaśnienia/Efekty blocks are legacy hand-written content; preserve as-is
                $PreservedText = ''
                if ($Split.PreservedBlocks.Count -gt 0) {
                    $PBParts = [System.Collections.Generic.List[string]]::new()
                    foreach ($PB in $Split.PreservedBlocks) {
                        $PBParts.Add($PB.Lines -join $NL)
                    }
                    $PreservedText = $PBParts -join $NL
                }

                # Reassemble with double-newline separators between body/meta/preserved
                $NewSectionSB = [System.Text.StringBuilder]::new(1024)

                $MetaStr = if ($MetaOutput.Count -gt 0) { $MetaOutput -join $NL } else { '' }
                $HasMeta = $MetaStr.Length -gt 0
                $HasBody = $Body.Length -gt 0
                $HasPreserved = $PreservedText.Length -gt 0

                if ($HasBody) {
                    [void]$NewSectionSB.Append($NL)
                    [void]$NewSectionSB.Append($Body)
                }

                if ($HasMeta) {
                    [void]$NewSectionSB.Append($NL)
                    if ($HasBody) { [void]$NewSectionSB.Append($NL) }
                    [void]$NewSectionSB.Append($MetaStr)
                }

                if ($HasPreserved) {
                    [void]$NewSectionSB.Append($NL)
                    if ($HasMeta -or $HasBody) { [void]$NewSectionSB.Append($NL) }
                    [void]$NewSectionSB.Append($PreservedText)
                }

                [void]$NewSectionSB.Append($NL)

                # Splice: replace the session's lines while preserving everything else
                $NewLines = [System.Collections.Generic.List[string]]::new($FileLines.Count)

                for ($k = 0; $k -lt $Match.SectionStartIdx; $k++) {
                    $NewLines.Add($FileLines[$k])
                }

                $NewSectionStr = $NewSectionSB.ToString()
                $NewSectionLines = $NewSectionStr.Split([string[]]@("`r`n", "`n"), [System.StringSplitOptions]::None)
                foreach ($NSL in $NewSectionLines) {
                    $NewLines.Add($NSL)
                }

                for ($k = $Match.SectionEndIdx; $k -lt $FileLines.Count; $k++) {
                    $NewLines.Add($FileLines[$k])
                }

                $NewFileContent = $NewLines -join $NL

                if ($PSCmdlet.ShouldProcess($FilePath, "Set-Session: modify session '$($Match.HeaderText)'")) {
                    $HasHooks = Get-Command 'Invoke-PluginHook' -ErrorAction SilentlyContinue
                    if ($HasHooks) {
                        Invoke-PluginHook -Operation 'Set-Session' -Phase 'BeforeWrite' -Context @{
                            Operation  = 'Set-Session'
                            FilePath   = $FilePath
                            HeaderText = $Match.HeaderText
                            NewContent = $NewFileContent
                        }
                    }

                    [System.IO.File]::WriteAllText($FilePath, $NewFileContent, $UTF8NoBOM)

                    # Invalidate WP-2/WP-4 parse caches so the next Get-Session/Get-Markdown
                    # call re-reads this file instead of returning stale pre-mutation data
                    if ($ExecutionContext.InvokeCommand.GetCommand('Clear-ParseCaches', [System.Management.Automation.CommandTypes]::Function)) {
                        Clear-ParseCaches
                    }

                    if ($script:HasOpCtx) { Add-OperationFile -Path $FilePath }

                    if ($HasHooks) {
                        Invoke-PluginHook -Operation 'Set-Session' -Phase 'AfterWrite' -Context @{
                            Operation  = 'Set-Session'
                            FilePath   = $FilePath
                            HeaderText = $Match.HeaderText
                            NewContent = $NewFileContent
                        }
                    }

                    # Skip eager graph refresh during batch upgrades — caller rebuilds
                    # the full graph afterward, so per-session refresh would be O(n^2) waste.
                    if (-not $UpgradeFormat) {
                        try {
                            if (-not (Get-Command 'Read-SessionGraphMeta' -ErrorAction SilentlyContinue)) {
                                . "$script:ModuleRoot/private/session-graphhelpers.ps1"
                            }
                            if (-not (Get-Command 'Get-AdminConfig' -ErrorAction SilentlyContinue)) {
                                . "$script:ModuleRoot/private/admin-config.ps1"
                            }
                            $EagerConfig = Get-AdminConfig
                            $EagerGraphDir = [System.IO.Path]::Combine($EagerConfig.ResDir, 'session-graph')
                            $EagerMetaPath = [System.IO.Path]::Combine($EagerGraphDir, '_meta.json')
                            $EagerIndexPath = [System.IO.Path]::Combine($EagerGraphDir, '_index.json')
                            $EagerMeta = Read-SessionGraphMeta -MetaPath $EagerMetaPath
                            if ($EagerMeta -and $EagerMeta['SessionCount'] -gt 0 -and [System.IO.File]::Exists($EagerIndexPath)) {
                                $EagerIndex = Read-SessionGraphIndex -IndexPath $EagerIndexPath
                                $HeaderText = $Match.HeaderText

                                # Get current session data for the affected header
                                $AffectedSessions = @(Get-Session -File $FilePath | Where-Object { $_.Header -eq $HeaderText })
                                foreach ($AffSess in $AffectedSessions) {
                                    Update-SessionGraphEntry -SessionHeader $AffSess.Header -Session $AffSess -Index $EagerIndex
                                }

                                Write-SessionGraphIndex -IndexPath $EagerIndexPath -Index $EagerIndex
                                $EagerMeta['LastEagerRefresh'] = [datetime]::Now.ToString('yyyy-MM-dd HH:mm:ss')
                                $EagerMeta['EagerRefreshCount'] = $EagerMeta['EagerRefreshCount'] + 1
                                $EagerMeta['SessionCount'] = $EagerIndex.Count
                                Write-SessionGraphMeta -MetaPath $EagerMetaPath -Meta $EagerMeta
                            }
                        } catch {
                            # Eager refresh is best-effort; do not fail the session write
                            Write-RobotWarning "[WARN Set-Session] Eager graph refresh failed: $_"
                        }
                    }
                }
            }
            catch {
                if ($TargetFiles.Count -gt 1) {
                    Write-Error "Failed to process '${FilePath}': $_"
                }
                else {
                    throw
                }
            }
        }

        if ($script:HasOpCtx) {
            $SessName = if ($TargetHeader) { $TargetHeader } else { $Date.ToString('yyyy-MM-dd') }
            return (New-OperationResult -Success $true -Action 'Update' `
                -TargetType 'Sesja' -TargetName $SessName -UndoHint $null)
        }
    }
}
