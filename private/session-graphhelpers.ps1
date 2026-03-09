<#
    .SYNOPSIS
    Session graph helpers - file path classification, participant record building,
    and persistent index I/O for the session participation graph.

    .DESCRIPTION
    Non-exported helper functions consumed by Set-SessionGraph and
    Get-SessionGraph via dot-sourcing. Not auto-loaded by robot.psm1
    (non-Verb-Noun filename).

    Contains:
    - Get-FilePathInvolvement:    classify a repo-relative file path into entity category/type
    - ConvertTo-ParticipantRecord: merge three-tier involvement data for a session
    - Read-SessionGraphIndex:     load persistent index from _index.json
    - Write-SessionGraphIndex:    persist index to _index.json
    - Read-SessionGraphMeta:      load operational metadata from _meta.json
    - Write-SessionGraphMeta:     persist operational metadata
    - Get-NameIndexVersion:       SHA256 of sorted entity names (detects name set changes)
    - ConvertFrom-GraphEntryDate: parse date string from graph index entry into [datetime]
    - Test-GraphEntryDateInRange: test whether a graph entry's date falls within a range

    Three-tier involvement model:
    - Tier 0 (Filesystem): session file is placed in an entity's directory
    - Tier 1 (Structured):  entity appears in PU, @Zmiany, @Transfer, or @Intel metadata
    - Tier 2 (Body Text):   entity name mentioned in session body text

    Tier 0 is available for all session format generations (Gen1-Gen4).
    Tier 1 is only available for Gen3+ sessions with structured metadata.
    Tier 2 requires cached body text and name resolution (-IncludeMentions).

    When the same entity appears at multiple tiers, the lowest tier (highest
    confidence) wins. If Tier 1 provides a Weight, it is preserved.
#>

# Shared UTF-8 no BOM encoding instance (reuse from session-hashhelpers if loaded)
if (-not (Test-Path variable:script:UTF8NoBOM)) {
    $script:UTF8NoBOM = [System.Text.UTF8Encoding]::new($false)
}

# Classify a repo-relative file path into an entity involvement record.
# Returns $null for Unknown category paths.
function Get-FilePathInvolvement {
    param(
        [Parameter(Mandatory, HelpMessage = "Repo-relative file path (forward slashes)")]
        [string]$RelPath
    )

    # Normalize to forward slashes
    $P = $RelPath.Replace('\', '/')

    # Rule 1: Postaci/Gracze/*.md → Player character
    if ($P.StartsWith('Postaci/Gracze/', [System.StringComparison]::OrdinalIgnoreCase) -and
        $P.IndexOf('/', 15) -eq -1) {
        $Name = [System.IO.Path]::GetFileNameWithoutExtension($P)
        return [PSCustomObject]@{
            Category = 'Player'
            Name     = $Name
            Type     = 'Postać'
        }
    }

    # Rule 2: Postaci/NPC/**/*.md → NPC
    if ($P.StartsWith('Postaci/NPC/', [System.StringComparison]::OrdinalIgnoreCase) -and
        $P.EndsWith('.md', [System.StringComparison]::OrdinalIgnoreCase)) {
        $Name = [System.IO.Path]::GetFileNameWithoutExtension($P)
        return [PSCustomObject]@{
            Category = 'NPC'
            Name     = $Name
            Type     = 'NPC'
        }
    }

    # Rule 3: Świat gry/**/Sesje lokalne.md → Location (name = parent dir)
    if ($P.StartsWith('Świat gry/', [System.StringComparison]::OrdinalIgnoreCase)) {
        $FileName = [System.IO.Path]::GetFileName($P)
        if ([string]::Equals($FileName, 'Sesje lokalne.md', [System.StringComparison]::OrdinalIgnoreCase)) {
            # Name = parent directory name
            $ParentDir = [System.IO.Path]::GetDirectoryName($P)
            if ($ParentDir) {
                $Name = [System.IO.Path]::GetFileName($ParentDir.Replace('\', '/'))
                return [PSCustomObject]@{
                    Category = 'Location'
                    Name     = $Name
                    Type     = 'Lokacja'
                }
            }
        }
    }

    # Rule 4: Wątki/*.md → Thread (graph-only classification)
    if ($P.StartsWith('Wątki/', [System.StringComparison]::OrdinalIgnoreCase) -and
        $P.EndsWith('.md', [System.StringComparison]::OrdinalIgnoreCase) -and
        $P.IndexOf('/', 6) -eq -1) {
        $Name = [System.IO.Path]::GetFileNameWithoutExtension($P)
        return [PSCustomObject]@{
            Category = 'Thread'
            Name     = $Name
            Type     = 'Wątek'
        }
    }

    # Rule 5: Organizacje/**/*.md → Org (maps to Grupa entity type)
    if ($P.StartsWith('Organizacje/', [System.StringComparison]::OrdinalIgnoreCase) -and
        $P.EndsWith('.md', [System.StringComparison]::OrdinalIgnoreCase)) {
        $Name = [System.IO.Path]::GetFileNameWithoutExtension($P)
        return [PSCustomObject]@{
            Category = 'Org'
            Name     = $Name
            Type     = 'Grupa'
        }
    }

    # Rule 6: Everything else → Unknown (skip)
    return $null
}

# Merge all three tiers of involvement for a single session into a
# deduplicated participant list. Same entity from multiple tiers keeps the
# lowest tier number (highest confidence). Tier 1 Weight is preserved.
function ConvertTo-ParticipantRecord {
    param(
        [Parameter(Mandatory, HelpMessage = "Session object from Get-Session")]
        [object]$Session
    )

    # Key = entity name (OrdinalIgnoreCase) → participant record
    $Participants = [System.Collections.Generic.Dictionary[string, object]]::new(
        [System.StringComparer]::OrdinalIgnoreCase)

    $MergeParticipant = {
        param([string]$Name, [string]$Type, [int]$Tier, [string]$Source, $Weight)
        if ([string]::IsNullOrWhiteSpace($Name)) { return }
        if ($Participants.ContainsKey($Name)) {
            $Existing = $Participants[$Name]
            if ($Tier -lt $Existing.Tier) {
                # Lower tier wins entirely
                $Existing.Tier = $Tier
                $Existing.Source = $Source
                if ($null -ne $Weight) { $Existing.Weight = $Weight }
            }
            elseif ($Tier -eq $Existing.Tier -and $null -ne $Weight -and $null -eq $Existing.Weight) {
                # Same tier, but new entry has weight — keep the weight
                $Existing.Weight = $Weight
            }
        }
        else {
            $Participants[$Name] = [PSCustomObject]@{
                Name   = $Name
                Type   = $Type
                Tier   = $Tier
                Source = $Source
                Weight = $Weight
            }
        }
    }

    # Tier 0: Filesystem placement
    if ($Session.FilePaths) {
        foreach ($FP in $Session.FilePaths) {
            $Inv = Get-FilePathInvolvement -RelPath $FP
            if ($null -ne $Inv) {
                & $MergeParticipant $Inv.Name $Inv.Type 0 'FilePath' $null
            }
        }
    }

    # Tier 1: Structured metadata (PU, Changes, Transfers, Intel)
    if ($Session.PU) {
        foreach ($PUEntry in $Session.PU) {
            if ($PUEntry.Character) {
                $W = if ($null -ne $PUEntry.Value) { $PUEntry.Value } else { $null }
                & $MergeParticipant $PUEntry.Character 'Postać' 1 'PU' $W
            }
        }
    }

    if ($Session.Changes) {
        foreach ($Change in $Session.Changes) {
            if ($Change.EntityName) {
                & $MergeParticipant $Change.EntityName $null 1 'Changes' $null
            }
        }
    }

    if ($Session.Transfers) {
        foreach ($Transfer in $Session.Transfers) {
            if ($Transfer.Source) {
                & $MergeParticipant $Transfer.Source $null 1 'Transfer' $null
            }
            if ($Transfer.Destination) {
                & $MergeParticipant $Transfer.Destination $null 1 'Transfer' $null
            }
        }
    }

    if ($Session.Intel) {
        foreach ($IntelEntry in $Session.Intel) {
            if ($IntelEntry.Recipients) {
                foreach ($Recipient in $IntelEntry.Recipients) {
                    if ($Recipient.Name) {
                        $RType = if ($Recipient.Type) { $Recipient.Type } else { $null }
                        & $MergeParticipant $Recipient.Name $RType 1 'Intel' $null
                    }
                }
            }
        }
    }

    # Tier 2: Body text mentions
    if ($Session.Mentions) {
        foreach ($Mention in $Session.Mentions) {
            if ($Mention.Name) {
                $MType = if ($Mention.Type) { $Mention.Type } else { $null }
                & $MergeParticipant $Mention.Name $MType 2 'BodyText' $null
            }
        }
    }

    return @($Participants.Values)
}

# Read the persistent session graph index from _index.json.
# Returns a hashtable (OrdinalIgnoreCase) keyed by session header.
# Returns empty hashtable if file does not exist or is corrupt.
function Read-SessionGraphIndex {
    param(
        [Parameter(Mandatory, HelpMessage = "Path to _index.json")]
        [string]$IndexPath
    )

    $Result = @{}

    if (-not [System.IO.File]::Exists($IndexPath)) {
        return $Result
    }

    try {
        $RawJson = [System.IO.File]::ReadAllText($IndexPath, $script:UTF8NoBOM)
        $Parsed = $RawJson | ConvertFrom-Json -AsHashtable
        if ($Parsed) {
            return $Parsed
        }
    } catch {
        Write-RobotWarning "[WARN Read-SessionGraphIndex] Failed to parse '$IndexPath': $_"
    }

    return $Result
}

# Write the session graph index to _index.json.
# Creates parent directories as needed. Keys are sorted for deterministic output.
function Write-SessionGraphIndex {
    param(
        [Parameter(Mandatory, HelpMessage = "Path to _index.json")]
        [string]$IndexPath,

        [Parameter(Mandatory, HelpMessage = "Index hashtable keyed by session header")]
        [hashtable]$Index
    )

    $Dir = [System.IO.Path]::GetDirectoryName($IndexPath)
    if (-not [System.IO.Directory]::Exists($Dir)) {
        [void][System.IO.Directory]::CreateDirectory($Dir)
    }

    # Sort keys for deterministic output
    $Ordered = [ordered]@{}
    $SortedKeys = [System.Collections.Generic.List[string]]::new()
    foreach ($K in $Index.Keys) { [void]$SortedKeys.Add([string]$K) }
    $SortedKeys.Sort([System.StringComparer]::Ordinal)
    foreach ($Key in $SortedKeys) {
        $Ordered[$Key] = $Index[$Key]
    }

    $Json = $Ordered | ConvertTo-Json -Depth 5
    [System.IO.File]::WriteAllText($IndexPath, $Json, $script:UTF8NoBOM)
}

# Read operational metadata from _meta.json.
# Returns hashtable with LastFullUpdate, LastIncrementalUpdate, NameIndexVersion, SessionCount, Version.
function Read-SessionGraphMeta {
    param(
        [Parameter(Mandatory, HelpMessage = "Path to _meta.json")]
        [string]$MetaPath
    )

    $Defaults = @{
        LastFullUpdate        = $null
        LastIncrementalUpdate = $null
        NameIndexVersion      = $null
        SessionCount          = 0
        Version               = 1
    }

    if (-not [System.IO.File]::Exists($MetaPath)) {
        return $Defaults
    }

    try {
        $RawJson = [System.IO.File]::ReadAllText($MetaPath, $script:UTF8NoBOM)
        # Use -AsHashtable to prevent automatic DateTime conversion
        $Parsed = $RawJson | ConvertFrom-Json -AsHashtable
        foreach ($Key in @('LastFullUpdate', 'LastIncrementalUpdate', 'NameIndexVersion')) {
            if ($Parsed.ContainsKey($Key) -and $null -ne $Parsed[$Key]) {
                $Defaults[$Key] = [string]$Parsed[$Key]
            }
        }
        if ($Parsed.ContainsKey('SessionCount') -and $null -ne $Parsed['SessionCount']) {
            $Defaults['SessionCount'] = [int]$Parsed['SessionCount']
        }
        if ($Parsed.ContainsKey('Version') -and $null -ne $Parsed['Version']) {
            $Defaults['Version'] = $Parsed['Version']
        }
    } catch {
        Write-RobotWarning "[WARN Read-SessionGraphMeta] Failed to parse '$MetaPath': $_"
    }

    return $Defaults
}

# Write operational metadata to _meta.json.
function Write-SessionGraphMeta {
    param(
        [Parameter(Mandatory, HelpMessage = "Path to _meta.json")]
        [string]$MetaPath,

        [Parameter(Mandatory, HelpMessage = "Metadata hashtable")]
        [hashtable]$Meta
    )

    $Dir = [System.IO.Path]::GetDirectoryName($MetaPath)
    if (-not [System.IO.Directory]::Exists($Dir)) {
        [void][System.IO.Directory]::CreateDirectory($Dir)
    }

    $Json = $Meta | ConvertTo-Json -Depth 1
    [System.IO.File]::WriteAllText($MetaPath, $Json, $script:UTF8NoBOM)
}

# Compute a version hash from sorted entity canonical names.
# Used to detect when the entity name set has changed, which would
# invalidate Tier 2 (body text) matches and require a full rebuild.
function Get-NameIndexVersion {
    param(
        [Parameter(Mandatory, HelpMessage = "Array of entity names")]
        [string[]]$Names
    )

    $Sorted = [System.Collections.Generic.List[string]]::new($Names)
    $Sorted.Sort([System.StringComparer]::Ordinal)
    $Joined = [string]::Join('|', $Sorted)

    # Reuse Get-ContentHash if available, otherwise inline SHA256
    if (Get-Command 'Get-ContentHash' -ErrorAction SilentlyContinue) {
        return Get-ContentHash -Content $Joined
    }

    $Bytes = $script:UTF8NoBOM.GetBytes($Joined)
    $SHA256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $HashBytes = $SHA256.ComputeHash($Bytes)
    } finally {
        $SHA256.Dispose()
    }

    return [System.BitConverter]::ToString($HashBytes).Replace('-', '').ToLowerInvariant()
}

# Parse date string from a graph index entry into [datetime].
# Returns $null if the entry has no Date key or the value is not valid yyyy-MM-dd.
function ConvertFrom-GraphEntryDate {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Entry
    )

    if (-not $Entry.ContainsKey('Date') -or -not $Entry['Date']) { return $null }

    [datetime]$Parsed = [datetime]::MinValue
    if ([datetime]::TryParseExact($Entry['Date'], 'yyyy-MM-dd',
        [System.Globalization.CultureInfo]::InvariantCulture,
        [System.Globalization.DateTimeStyles]::None,
        [ref]$Parsed)) {
        return $Parsed
    }

    return $null
}

# Test whether a graph entry's date falls within [MinDate, MaxDate].
# Entries with unparseable or missing dates are excluded when a bound is set.
function Test-GraphEntryDateInRange {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Entry,

        [Parameter()]
        [Nullable[datetime]]$MinDate,

        [Parameter()]
        [Nullable[datetime]]$MaxDate
    )

    $SessionDate = ConvertFrom-GraphEntryDate -Entry $Entry

    if ($MinDate -and ($null -eq $SessionDate -or $SessionDate -lt $MinDate)) { return $false }
    if ($MaxDate -and ($null -eq $SessionDate -or $SessionDate -gt $MaxDate)) { return $false }

    return $true
}
