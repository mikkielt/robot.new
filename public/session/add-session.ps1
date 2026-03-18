<#
    .SYNOPSIS
    Appends new Gen4-format sessions to Markdown files in chronological order.

    .DESCRIPTION
    This file contains Add-Session and the private helper Find-SessionInsertionPoint.
    It dot-sources format-sessionblock.ps1 (rendering), session-decomposehelpers.ps1
    (duplicate detection via Find-SessionInFile), temporal-helpers.ps1 (date parsing
    for chronological insertion), and admin-config.ps1 (path validation, config).

    Add-Session bridges the gap between New-Session (generates markdown but does not
    write) and Set-Session (modifies existing sessions but cannot create new ones).
    It generates session markdown via New-Session, validates uniqueness, and inserts
    each session at the correct chronological position within target files.

    Supports two modes via ParameterSets:
    - Single: individual session parameters (Date, Title, Narrator, ...)
    - Batch:  -Sessions hashtable[] for multiple sessions in one call

    Batch mode is O(1) file I/O per target file regardless of session count: one
    read, one write, one cache clear, one graph refresh. Sessions are sorted by
    date and inserted bottom-to-top to preserve index validity.

    Processing pipeline:
    1. Normalize input into session specs (single wraps into one-element list)
    2. Generate markdown for each session via New-Session (fail-early on invalid params)
    3. Per file: validate path under repo root, read content, detect NL style,
       check for duplicate headers, find chronological insertion points,
       splice bottom-to-top, write UTF-8 no BOM
    4. Fire plugin hooks (BeforeWrite, AfterWrite, AfterCreate), clear parse caches,
       register operation file, eager graph refresh

    Module-level data:
    - $script:HasOpCtx: operation context flag (from admin-config.ps1)
#>

. "$script:ModuleRoot/private/format-sessionblock.ps1"
. "$script:ModuleRoot/private/session-decomposehelpers.ps1"
. "$script:ModuleRoot/private/temporal-helpers.ps1"
. "$script:ModuleRoot/private/admin-config.ps1"

$script:HasOpCtx = $null -ne (Get-Command 'Add-OperationFile' -ErrorAction SilentlyContinue)

# Helper: returns the line index where a new session should be inserted to maintain
# chronological order. The session is placed after all existing sessions with date <=
# the new session's date (same-date sessions: new goes after existing). Returns
# $Lines.Count if appending at end.
function Find-SessionInsertionPoint {
    param(
        [string[]]$Lines,
        [Parameter(Mandatory)] [datetime]$SessionDate
    )

    $DateRegex = $script:SessionDatePattern
    $InsertBeforeIdx = $Lines.Count  # default: append at end

    for ($i = 0; $i -lt $Lines.Count; $i++) {
        if (-not $Lines[$i].StartsWith('### ')) { continue }

        $HeaderText = $Lines[$i].Substring(4).Trim()
        $DMatch = $DateRegex.Match($HeaderText)
        if (-not $DMatch.Success) { continue }

        $Parsed = ConvertTo-SessionDate -DateString $DMatch.Groups[1].Value
        if (-not $Parsed) { continue }

        if ($Parsed.Date -gt $SessionDate.Date) {
            $InsertBeforeIdx = $i
            break
        }
    }

    return $InsertBeforeIdx
}

function Add-Session {
    <#
        .SYNOPSIS
        Appends new Gen4-format sessions to one or more Markdown files in
        chronological order.
    #>

    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium',
                   DefaultParameterSetName = 'Single')]
    param(
        [Parameter(Mandatory, HelpMessage = "Target file path(s) to write the session(s) to")]
        [ValidateNotNullOrEmpty()]
        [string[]]$Path,

        # ── Single session parameters ──────────────────────────────────
        [Parameter(ParameterSetName = 'Single', Mandatory, HelpMessage = "Session date")]
        [ValidateNotNull()]
        [datetime]$Date,

        [Parameter(ParameterSetName = 'Single', Mandatory, HelpMessage = "Session title")]
        [ValidateNotNullOrEmpty()]
        [string]$Title,

        [Parameter(ParameterSetName = 'Single', Mandatory, HelpMessage = "Narrator name for session header")]
        [ValidateNotNullOrEmpty()]
        [string]$Narrator,

        [Parameter(ParameterSetName = 'Single', HelpMessage = "End date for multi-day sessions (same month as Date)")]
        [datetime]$DateEnd,

        [Parameter(ParameterSetName = 'Single', HelpMessage = "Canonical narrator names for @Narrator metadata")]
        [string[]]$MetadataNarrators,

        [Parameter(ParameterSetName = 'Single', HelpMessage = "Location names for the session")]
        [string[]]$Locations,

        [Parameter(ParameterSetName = 'Single', HelpMessage = "PU award entries (Character + Value)")]
        [object[]]$PU,

        [Parameter(ParameterSetName = 'Single', HelpMessage = "Session log URLs")]
        [string[]]$Logs,

        [Parameter(ParameterSetName = 'Single', HelpMessage = "Entity state changes (Zmiany entries)")]
        [object[]]$Changes,

        [Parameter(ParameterSetName = 'Single', HelpMessage = "Intel targeting entries (RawTarget + Message)")]
        [object[]]$Intel,

        [Parameter(ParameterSetName = 'Single', HelpMessage = "Free-form body text content")]
        [string]$Content,

        # ── Batch mode ─────────────────────────────────────────────────
        [Parameter(ParameterSetName = 'Batch', Mandatory,
                   HelpMessage = "Array of session hashtables, each with Date/Title/Narrator keys")]
        [ValidateNotNullOrEmpty()]
        [hashtable[]]$Sessions
    )

    # ── 1. Build session specs list ────────────────────────────────────
    if ($PSCmdlet.ParameterSetName -eq 'Single') {
        $Specs = @(@{
            Date     = $Date
            Title    = $Title
            Narrator = $Narrator
        })
        foreach ($Key in @('DateEnd', 'MetadataNarrators', 'Locations', 'PU',
                           'Logs', 'Changes', 'Intel', 'Content')) {
            if ($PSBoundParameters.ContainsKey($Key)) {
                $Specs[0][$Key] = $PSBoundParameters[$Key]
            }
        }
    }
    else {
        $Specs = $Sessions
    }

    # ── 2. Generate markdown for each spec (fail-early) ────────────────
    $Generated = [System.Collections.Generic.List[hashtable]]::new($Specs.Count)
    $OptionalKeys = @('DateEnd', 'MetadataNarrators', 'Locations', 'PU',
                      'Logs', 'Changes', 'Intel', 'Content')

    foreach ($Spec in $Specs) {
        $NewParams = @{
            Date     = $Spec.Date
            Title    = $Spec.Title
            Narrator = $Spec.Narrator
        }
        foreach ($Key in $OptionalKeys) {
            if ($Spec.ContainsKey($Key)) { $NewParams[$Key] = $Spec[$Key] }
        }

        $Markdown = New-Session @NewParams

        # Extract header text from the first line (strip "### " prefix)
        $FirstNL = $Markdown.IndexOf([char]10)
        $HeaderLine = if ($FirstNL -ge 0) { $Markdown.Substring(0, $FirstNL).TrimEnd([char]13) }
                      else                 { $Markdown }
        $HeaderText = $HeaderLine.Substring(4).Trim()

        $Generated.Add(@{
            Markdown   = $Markdown
            HeaderText = $HeaderText
            Date       = $Spec.Date
        })
    }

    # Sort by date (preserves input order for same dates via SeqIdx)
    $Sorted = $Generated.ToArray()
    [Array]::Sort($Sorted, [System.Comparison[object]]{ param($A, $B) [datetime]::Compare($A.Date, $B.Date) })

    # ── 3. Process each target file ────────────────────────────────────
    $UTF8NoBOM = [System.Text.UTF8Encoding]::new($false)
    $HasHooks  = Get-Command 'Invoke-PluginHook' -ErrorAction SilentlyContinue
    $RepoRoot  = Get-RepoRoot

    $AllHeaders = [System.Collections.Generic.List[string]]::new($Sorted.Count)
    foreach ($S in $Sorted) { $AllHeaders.Add($S.HeaderText) }

    foreach ($FilePath in $Path) {
        $FullPath = if ([System.IO.Path]::IsPathRooted($FilePath)) { $FilePath }
                    else { [System.IO.Path]::GetFullPath($FilePath) }

        # Path validation — reject writes outside repository root
        if (-not (Test-PathUnderRoot -Path $FullPath -Root $RepoRoot)) {
            $ErrRecord = [System.Management.Automation.ErrorRecord]::new(
                [System.InvalidOperationException]::new(
                    "Path '$FullPath' is outside repository root '$RepoRoot'"),
                'PathOutsideRepo',
                [System.Management.Automation.ErrorCategory]::InvalidArgument,
                $FullPath)
            $PSCmdlet.ThrowTerminatingError($ErrRecord)
        }

        $FileExists = [System.IO.File]::Exists($FullPath)

        if ($FileExists) {
            $FileContent = [System.IO.File]::ReadAllText($FullPath, $UTF8NoBOM)
            $NL = if ($FileContent.Contains("`r`n")) { "`r`n" } else { "`n" }
            $FileLines = [System.Collections.Generic.List[string]]::new(
                [string[]]($FileContent.Split(
                    [string[]]@("`r`n", "`n"), [System.StringSplitOptions]::None)))
            $LinesSnapshot = $FileLines.ToArray()

            # Duplicate check — session headers are unique identifiers
            foreach ($S in $Sorted) {
                $Existing = Find-SessionInFile -Lines $LinesSnapshot -TargetHeader $S.HeaderText
                if ($Existing.Count -gt 0) {
                    $ErrRecord = [System.Management.Automation.ErrorRecord]::new(
                        [System.InvalidOperationException]::new(
                            "Session '$($S.HeaderText)' already exists in '$FullPath'"),
                        'DuplicateSessionHeader',
                        [System.Management.Automation.ErrorCategory]::ResourceExists,
                        $FullPath)
                    $PSCmdlet.ThrowTerminatingError($ErrRecord)
                }
            }

            # Find insertion points against the original (unmodified) lines.
            # SeqIdx tracks original order for stable tie-breaking.
            $Insertions = [System.Collections.Generic.List[hashtable]]::new($Sorted.Count)
            for ($si = 0; $si -lt $Sorted.Count; $si++) {
                $Idx = Find-SessionInsertionPoint -Lines $LinesSnapshot -SessionDate $Sorted[$si].Date
                $Insertions.Add(@{ Session = $Sorted[$si]; InsertIdx = $Idx; SeqIdx = $si })
            }

            # Sort descending by InsertIdx, then by SeqIdx for bottom-to-top insertion.
            # Processing highest indices first ensures lower indices remain valid.
            # For same InsertIdx: descending SeqIdx means later-sequenced sessions are
            # inserted first at the same position, so earlier-sequenced ones end up
            # before them — preserving chronological + input order.
            $InsArr = $Insertions.ToArray()
            [Array]::Sort($InsArr, [System.Comparison[object]]{
                param($A, $B)
                $CmpIdx = [int]$B.InsertIdx - [int]$A.InsertIdx
                if ($CmpIdx -ne 0) { return $CmpIdx }
                return [int]$B.SeqIdx - [int]$A.SeqIdx
            })
            $Insertions = $InsArr

            foreach ($Ins in $Insertions) {
                $NormMarkdown = $Ins.Session.Markdown.Replace("`r`n", "`n").Replace("`n", $NL)
                $SessionLines = $NormMarkdown.Split(
                    [string[]]@($NL), [System.StringSplitOptions]::None)

                $Idx = $Ins.InsertIdx
                $LinesToInsert = [System.Collections.Generic.List[string]]::new()

                # Separator before: ensure empty line before new session header
                if ($Idx -gt 0 -and $FileLines[$Idx - 1] -ne '') {
                    $LinesToInsert.Add('')
                }

                foreach ($L in $SessionLines) { $LinesToInsert.Add($L) }

                # Separator after: ensure empty line between this and next content
                if ($Idx -lt $FileLines.Count -and $FileLines[$Idx] -ne '') {
                    $LinesToInsert.Add('')
                }

                $FileLines.InsertRange($Idx, $LinesToInsert)
            }

            $NewContent = [string]::Join($NL, $FileLines)
            if (-not $NewContent.EndsWith($NL)) { $NewContent += $NL }
        }
        else {
            # New file — use system newline, sessions in date order
            $NL = [System.Environment]::NewLine
            $Parts = [System.Collections.Generic.List[string]]::new($Sorted.Count)
            foreach ($S in $Sorted) {
                $Parts.Add($S.Markdown.Replace("`r`n", "`n").Replace("`n", $NL))
            }
            $NewContent = [string]::Join($NL + $NL, $Parts) + $NL

            # Ensure parent directory exists
            $ParentDir = [System.IO.Path]::GetDirectoryName($FullPath)
            if (-not [System.IO.Directory]::Exists($ParentDir)) {
                [void][System.IO.Directory]::CreateDirectory($ParentDir)
            }
        }

        $WhatIfDesc = if ($Sorted.Count -eq 1) { "Add-Session: add session '$($Sorted[0].HeaderText)'" }
                      else { "Add-Session: add $($Sorted.Count) sessions" }

        if ($PSCmdlet.ShouldProcess($FullPath, $WhatIfDesc)) {
            # BeforeWrite hook — can abort via throw
            if ($HasHooks) {
                Invoke-PluginHook -Operation 'Add-Session' -Phase 'BeforeWrite' -Context @{
                    Operation  = 'Add-Session'
                    FilePath   = $FullPath
                    Headers    = $AllHeaders.ToArray()
                    NewContent = $NewContent
                }
            }

            [System.IO.File]::WriteAllText($FullPath, $NewContent, $UTF8NoBOM)

            # Invalidate parse caches
            if ($ExecutionContext.InvokeCommand.GetCommand('Clear-ParseCaches',
                    [System.Management.Automation.CommandTypes]::Function)) {
                Clear-ParseCaches
            }

            # Operation context tracking
            if ($script:HasOpCtx) { Add-OperationFile -Path $FullPath }

            # AfterWrite hook — side effects only, errors logged but don't abort
            if ($HasHooks) {
                Invoke-PluginHook -Operation 'Add-Session' -Phase 'AfterWrite' -Context @{
                    Operation  = 'Add-Session'
                    FilePath   = $FullPath
                    Headers    = $AllHeaders.ToArray()
                    NewContent = $NewContent
                }
                Invoke-PluginHook -Operation 'Add-Session' -Phase 'AfterCreate' -Context @{
                    Operation  = 'Add-Session'
                    FilePath   = $FullPath
                    Headers    = $AllHeaders.ToArray()
                }
            }

            # Eager session graph refresh (best-effort, same pattern as Set-Session)
            try {
                if (-not (Get-Command 'Read-SessionGraphMeta' -ErrorAction SilentlyContinue)) {
                    . "$script:ModuleRoot/private/session-graphhelpers.ps1"
                }
                $EagerConfig   = Get-AdminConfig
                $EagerGraphDir = [System.IO.Path]::Combine($EagerConfig.ResDir, 'session-graph')
                $EagerMetaPath = [System.IO.Path]::Combine($EagerGraphDir, '_meta.json')
                $EagerIndexPath = [System.IO.Path]::Combine($EagerGraphDir, '_index.json')
                $EagerMeta = Read-SessionGraphMeta -MetaPath $EagerMetaPath
                if ($EagerMeta -and $EagerMeta['SessionCount'] -gt 0 -and
                    [System.IO.File]::Exists($EagerIndexPath)) {
                    $EagerIndex = Read-SessionGraphIndex -IndexPath $EagerIndexPath
                    foreach ($S in $Sorted) {
                        $AffectedSessions = @(Get-Session -File $FullPath).Where(
                            { $_.Header -eq $S.HeaderText })
                        foreach ($AffSess in $AffectedSessions) {
                            Update-SessionGraphEntry -SessionHeader $AffSess.Header `
                                -Session $AffSess -Index $EagerIndex
                        }
                    }
                    Write-SessionGraphIndex -IndexPath $EagerIndexPath -Index $EagerIndex
                    $EagerMeta['LastEagerRefresh'] = [datetime]::Now.ToString('yyyy-MM-dd HH:mm:ss')
                    $EagerMeta['EagerRefreshCount'] = $EagerMeta['EagerRefreshCount'] + 1
                    $EagerMeta['SessionCount'] = $EagerIndex.Count
                    Write-SessionGraphMeta -MetaPath $EagerMetaPath -Meta $EagerMeta
                }
            } catch {
                Write-RobotWarning "[WARN Add-Session] Eager graph refresh failed: $_"
            }
        }
    }

    return ,$AllHeaders.ToArray()
}
