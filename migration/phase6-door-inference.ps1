<#
    .SYNOPSIS
    Phase 6: @Drzwi door inference from session logs.

    .DESCRIPTION
    Analyzes session log location transitions to discover physical connections
    (doors) between locations. Builds a location graph with movement edges,
    filters candidates by confidence, generates a review file, and applies
    bidirectional @drzwi tags to Lokacja and Mapa entities.

    Requires Phase 5 (logs on disk + Gen4 format for clean structural graph).

    Dependencies: migration-ui.ps1, migration-state.ps1,
                  entity-writehelpers.ps1, robot module imported.
#>

# Dot-source entity write/find helpers
. ([System.IO.Path]::Combine($PSScriptRoot, '..', 'private', 'entity-writehelpers.ps1'))

# Dot-source admin config
. ([System.IO.Path]::Combine($PSScriptRoot, '..', 'private', 'admin-config.ps1'))

# Dot-source log fetch helpers (for SkipFetch local path handling)
. ([System.IO.Path]::Combine($PSScriptRoot, '..', 'private', 'log-fetchhelpers.ps1'))

# ============================================================================
# PHASE 6 - @Drzwi door inference from session logs
# ============================================================================

function Invoke-MigrationPhase6 {
    param(
        [Parameter(Mandatory)] [hashtable]$State,
        [switch]$WhatIf
    )

    if (-not (Test-PhasePredecessor -State $State -Phase 6)) {
        Write-StepWarning 'Faza 5 nie jest ukończona.'
        if (-not (Request-YesNo -Prompt 'Kontynuować mimo to?' -Default $false)) { return }
    }

    $PhaseStatus = Get-PhaseStatus -State $State -Phase 6
    Write-PhaseHeader -Phase 6 -Status $PhaseStatus

    $RepoRoot = Get-RepoRoot
    $Checklist = if ($State.Phases['6'].ContainsKey('Checklist')) { $State.Phases['6'].Checklist } else { @{} }
    $Config = Get-AdminConfig

    # ── Step 1: Load entities and sessions ────────────────────────────────
    Write-Step -Number 1 -Text 'Wczytywanie encji i sesji...'

    $Entities = @(Get-Entity -Quiet)
    $Sessions = @(Get-Session -Quiet)
    $NameIdx = Get-NameIndex -Entities $Entities

    # Build entity lookup by name (case-insensitive)
    $EntityByName = [System.Collections.Generic.Dictionary[string,object]]::new(
        [System.StringComparer]::OrdinalIgnoreCase)
    foreach ($E in $Entities) {
        if (-not $EntityByName.ContainsKey($E.Name)) {
            $EntityByName[$E.Name] = $E
        }
    }

    Write-StepOK "Encje: $($Entities.Count)  |  Sesje: $($Sessions.Count)"

    # ── Step 2: Parse logs from disk ──────────────────────────────────────
    Write-Step -Number 2 -Text 'Parsowanie logów z dysku (bez HTTP)...'

    $SessionsWithLogs = @($Sessions.Where({ $null -ne $_.Logs -and $_.Logs.Count -gt 0 }))
    if ($SessionsWithLogs.Count -eq 0) {
        Write-StepWarning 'Brak sesji z logami.'
        Set-PhaseCompleted -State $State -Phase 6
        Write-PhaseSummary -Phase 6 -Status 'Completed' -Lines @('[OK] Brak logów do analizy')
        return
    }

    $LogData = @(Get-SessionLog -Session $SessionsWithLogs -Index $NameIdx -SkipFetch)
    Write-StepOK "Sparsowano logi z $($LogData.Count) sesji"

    # ── Step 3: Extract location transitions ──────────────────────────────
    Write-Step -Number 3 -Text 'Ekstrakcja przejść między lokacjami...'

    $Cache = @{}
    $LogReport = @(Get-NamedLogLocationReport -SessionLog $LogData -Index $NameIdx -Cache $Cache -Quiet)

    $TotalTransitions = 0
    foreach ($R in $LogReport) {
        if ($null -ne $R.Transitions) { $TotalTransitions += $R.Transitions.Count }
    }
    Write-StepOK "Znaleziono $TotalTransitions przejść w $($LogReport.Count) raportach"

    # ── Step 4: Build location graph with movement edges ──────────────────
    Write-Step -Number 4 -Text 'Budowanie grafu lokalizacji...'

    $Graph = Get-LocationGraph -Sessions $Sessions -Entities $Entities `
        -SessionLog $LogReport -IncludeMovementEdges -Quiet

    $MovementEdges = @($Graph.Edges.Where({ $_.Type -eq 'Movement' }))
    $ExistingDoors = @($Graph.Edges.Where({ $_.Type -eq 'Door' }))

    Write-StepOK "Krawędzie: $($Graph.Summary.EdgeCount) łącznie, $($MovementEdges.Count) Movement, $($ExistingDoors.Count) Door"

    # ── Step 5: Compute @drzwi candidates ─────────────────────────────────
    Write-Step -Number 5 -Text 'Wnioskowanie kandydatów @drzwi...'

    # Build sets for existing doors and containment
    $ExistingDoorPairs = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase)
    foreach ($Edge in $ExistingDoors) {
        [void]$ExistingDoorPairs.Add("$($Edge.Source)|$($Edge.Target)")
        [void]$ExistingDoorPairs.Add("$($Edge.Target)|$($Edge.Source)")
    }

    $ContainmentPairs = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase)
    foreach ($Edge in $Graph.Edges) {
        if ($Edge.Type -eq 'Containment') {
            [void]$ContainmentPairs.Add("$($Edge.Source)|$($Edge.Target)")
            [void]$ContainmentPairs.Add("$($Edge.Target)|$($Edge.Source)")
        }
    }

    # Aggregate movement edges into candidate pairs (deduplicate A→B and B→A)
    $CandidateMap = [System.Collections.Generic.Dictionary[string,object]]::new(
        [System.StringComparer]::OrdinalIgnoreCase)

    foreach ($Edge in $MovementEdges) {
        $S = $Edge.Source
        $T = $Edge.Target

        # Skip unresolved (entity must exist)
        if (-not $EntityByName.ContainsKey($S) -or -not $EntityByName.ContainsKey($T)) { continue }

        # Skip existing doors (either direction)
        if ($ExistingDoorPairs.Contains("$S|$T")) { continue }

        # Skip containment (parent/child ≠ door)
        if ($ContainmentPairs.Contains("$S|$T")) { continue }

        # Skip self-transitions
        if ([string]::Equals($S, $T, [System.StringComparison]::OrdinalIgnoreCase)) { continue }

        # Canonical key: alphabetical order to merge A→B and B→A
        $Key = if ([string]::Compare($S, $T, [System.StringComparison]::OrdinalIgnoreCase) -le 0) {
            "$S|$T"
        } else { "$T|$S" }

        if ($CandidateMap.ContainsKey($Key)) {
            $Existing = $CandidateMap[$Key]
            $Existing.Weight += $Edge.Weight
            if ($Edge.FirstSeen -lt $Existing.FirstSeen) { $Existing.FirstSeen = $Edge.FirstSeen }
            if ($Edge.LastSeen -gt $Existing.LastSeen) { $Existing.LastSeen = $Edge.LastSeen }
            if ($Edge.PossiblyStale) { $Existing.PossiblyStale = $true }
        } else {
            $Parts = $Key.Split('|')
            $CandidateMap[$Key] = @{
                Source        = $Parts[0]
                Target        = $Parts[1]
                Weight        = $Edge.Weight
                FirstSeen     = $Edge.FirstSeen
                LastSeen      = $Edge.LastSeen
                PossiblyStale = $Edge.PossiblyStale
            }
        }
    }

    $Candidates = [System.Collections.Generic.List[object]]::new()
    foreach ($Entry in $CandidateMap.Values) {
        $Action = if ($Entry.Weight -ge 2) { 'ADD' } else { 'REVIEW' }
        $Candidates.Add([PSCustomObject]@{
            Source        = $Entry.Source
            Target        = $Entry.Target
            Weight        = $Entry.Weight
            FirstSeen     = $Entry.FirstSeen
            LastSeen      = $Entry.LastSeen
            Action        = $Action
            PossiblyStale = $Entry.PossiblyStale
        })
    }

    # Sort by weight descending
    $Candidates = @([System.Linq.Enumerable]::OrderByDescending(
        [object[]]$Candidates, [Func[object,int]]{ param($X) $X.Weight }))

    $AddCount = @($Candidates.Where({ $_.Action -eq 'ADD' })).Count
    $ReviewCount = @($Candidates.Where({ $_.Action -eq 'REVIEW' })).Count

    Write-StepOK "Kandydaci: $($Candidates.Count) ($AddCount ADD, $ReviewCount REVIEW)"

    if ($Candidates.Count -eq 0) {
        Write-StepOK 'Brak nowych kandydatów @drzwi.'
        Set-PhaseCompleted -State $State -Phase 6
        Write-PhaseSummary -Phase 6 -Status 'Completed' -Lines @('[OK] Brak nowych drzwi do dodania')
        return
    }

    # ── Step 6: Generate review file ──────────────────────────────────────
    Write-Step -Number 6 -Text 'Generowanie pliku przeglądu...'

    $ReviewPath = [System.IO.Path]::Combine($Config.ResDir, 'drzwi-candidates.txt')

    $SB = [System.Text.StringBuilder]::new()
    [void]$SB.AppendLine("# @Drzwi Door Inference Review File")
    [void]$SB.AppendLine("# Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm')")
    [void]$SB.AppendLine("# Format: Source`tTarget`tWeight`tFirstSeen`tLastSeen`tAction")
    [void]$SB.AppendLine("# Actions: ADD (accept), SKIP (reject), REVIEW (needs manual check)")
    [void]$SB.AppendLine("#")
    [void]$SB.AppendLine("# Candidates with Weight >= 2 default to ADD")
    [void]$SB.AppendLine("# Candidates with Weight == 1 default to REVIEW")
    [void]$SB.AppendLine("# Lines starting with # are comments")
    [void]$SB.AppendLine("")

    foreach ($C in $Candidates) {
        $FirstStr = if ($null -ne $C.FirstSeen -and $C.FirstSeen -ne [datetime]::MinValue) { $C.FirstSeen.ToString('yyyy-MM-dd') } else { '?' }
        $LastStr = if ($null -ne $C.LastSeen -and $C.LastSeen -ne [datetime]::MinValue) { $C.LastSeen.ToString('yyyy-MM-dd') } else { '?' }
        $StaleNote = if ($C.PossiblyStale) { "`tSTALE" } else { '' }
        [void]$SB.AppendLine("$($C.Source)`t$($C.Target)`t$($C.Weight)`t$FirstStr`t$LastStr`t$($C.Action)$StaleNote")
    }

    [System.IO.File]::WriteAllText($ReviewPath, $SB.ToString())
    Write-StepOK "Plik przeglądu: $ReviewPath"

    Update-PhaseChecklist -State $State -Phase 6 -Item 'CandidatesGenerated' -Value $true

    # ── Step 7: User review ───────────────────────────────────────────────
    Write-Step -Number 7 -Text 'Przegląd kandydatów...'

    $ReviewChoice = Request-UserChoice -Prompt 'Co zrobić z kandydatami @drzwi?' -ValidChoices @('Z', 'E', 'P') `
        -Labels @{ 'Z' = "Zastosuj ($AddCount ADD)"; 'E' = 'Edytuj plik przeglądu'; 'P' = 'Pomiń (nie zapisuj)' }

    if ($ReviewChoice -eq 'P') {
        Write-Host '  Pominięto zapis @drzwi.' -ForegroundColor DarkGray
        Set-PhaseInProgress -State $State -Phase 6
        if (-not $WhatIf) { Save-MigrationState -State $State }
        return
    }

    if ($ReviewChoice -eq 'E') {
        Write-Host "  Edytuj plik: $ReviewPath" -ForegroundColor Cyan
        Write-Host '  Zmień kolumnę Action na ADD/SKIP/REVIEW, następnie uruchom fazę ponownie.' -ForegroundColor DarkGray
        Set-PhaseInProgress -State $State -Phase 6
        if (-not $WhatIf) { Save-MigrationState -State $State }
        return
    }

    # Re-read review file (in case it was edited before this run)
    $Accepted = [System.Collections.Generic.List[object]]::new()
    if ([System.IO.File]::Exists($ReviewPath)) {
        $ReviewLines = [System.IO.File]::ReadAllLines($ReviewPath)
        foreach ($Line in $ReviewLines) {
            if ([string]::IsNullOrWhiteSpace($Line) -or $Line.StartsWith('#')) { continue }
            $Parts = $Line.Split("`t")
            if ($Parts.Count -ge 6 -and [string]::Equals($Parts[5].Trim(), 'ADD', [System.StringComparison]::OrdinalIgnoreCase)) {
                $Accepted.Add([PSCustomObject]@{
                    Source   = $Parts[0].Trim()
                    Target   = $Parts[1].Trim()
                    FirstSeen = $Parts[3].Trim()
                })
            }
        }
    }

    if ($Accepted.Count -eq 0) {
        Write-StepOK 'Brak zaakceptowanych kandydatów.'
        Set-PhaseCompleted -State $State -Phase 6
        Write-PhaseSummary -Phase 6 -Status 'Completed' -Lines @('[OK] Brak drzwi do dodania (wszystkie pominięte)')
        return
    }

    Write-StepOK "Zaakceptowano $($Accepted.Count) par @drzwi do zapisu"

    # ── Step 8: Apply @drzwi tags ─────────────────────────────────────────
    Write-Step -Number 8 -Text 'Zapisywanie @drzwi do plików encji...'

    if ($WhatIf) {
        Write-Host "    [WhatIf] Zapisałbym $($Accepted.Count) par @drzwi" -ForegroundColor DarkGray
    } else {
        $AppliedCount = 0
        $SkippedCount = 0

        # Group insertions by file path to minimize file reads/writes
        $FileChanges = [System.Collections.Generic.Dictionary[string,System.Collections.Generic.List[object]]]::new(
            [System.StringComparer]::OrdinalIgnoreCase)

        foreach ($Pair in $Accepted) {
            # Each pair produces two tag insertions: A→B and B→A
            foreach ($Dir in @(
                @{ Entity = $Pair.Source; DoorTarget = $Pair.Target; FirstSeen = $Pair.FirstSeen }
                @{ Entity = $Pair.Target; DoorTarget = $Pair.Source; FirstSeen = $Pair.FirstSeen }
            )) {
                $E = $null
                if (-not $EntityByName.TryGetValue($Dir.Entity, [ref]$E)) { continue }
                $FilePath = $E.FilePath
                if ([string]::IsNullOrEmpty($FilePath)) { continue }

                # Check if door already exists
                $AlreadyExists = $false
                if ($null -ne $E.Doors) {
                    foreach ($D in $E.Doors) {
                        if ([string]::Equals($D, $Dir.DoorTarget, [System.StringComparison]::OrdinalIgnoreCase)) {
                            $AlreadyExists = $true
                            break
                        }
                    }
                }

                if ($AlreadyExists) {
                    $SkippedCount++
                    continue
                }

                if (-not $FileChanges.ContainsKey($FilePath)) {
                    $FileChanges[$FilePath] = [System.Collections.Generic.List[object]]::new()
                }
                $FileChanges[$FilePath].Add([PSCustomObject]@{
                    EntityName = $Dir.Entity
                    DoorTarget = $Dir.DoorTarget
                    FirstSeen  = $Dir.FirstSeen
                })
            }
        }

        # Apply changes per file
        foreach ($Entry in $FileChanges.GetEnumerator()) {
            $FilePath = $Entry.Key
            $Changes = $Entry.Value

            if (-not [System.IO.File]::Exists($FilePath)) {
                Write-StepWarning "Plik nie istnieje: $FilePath"
                continue
            }

            $FileData = Read-EntityFile -Path $FilePath
            $Lines = $FileData.Lines
            $NL = $FileData.NL

            # Sort changes by entity name so we process in order, apply from bottom to top
            # to avoid index shifting issues
            $IndexedChanges = [System.Collections.Generic.List[object]]::new()
            foreach ($Change in $Changes) {
                # Find entity bullet
                $SectionInfo = Find-EntitySection -Lines $Lines.ToArray() -SectionName ($EntityByName[$Change.EntityName].Type)
                if ($null -eq $SectionInfo) { continue }

                $BulletInfo = Find-EntityBullet -Lines $Lines.ToArray() `
                    -SectionStart $SectionInfo.SectionStart `
                    -SectionEnd $SectionInfo.SectionEnd `
                    -EntityName $Change.EntityName
                if ($null -eq $BulletInfo) { continue }

                # Verify tag doesn't already exist in raw lines
                $TagExists = $false
                for ($i = $BulletInfo.ChildrenStartIdx; $i -lt $BulletInfo.ChildrenEndIdx; $i++) {
                    $Line = $Lines[$i]
                    if ($Line -match '^\s+-\s+@drzwi:\s*(.+)') {
                        $ExistingTarget = $Matches[1].Trim()
                        # Strip temporal annotation for comparison
                        $ParenIdx = $ExistingTarget.IndexOf('(')
                        if ($ParenIdx -gt 0) { $ExistingTarget = $ExistingTarget.Substring(0, $ParenIdx).Trim() }
                        if ([string]::Equals($ExistingTarget, $Change.DoorTarget, [System.StringComparison]::OrdinalIgnoreCase)) {
                            $TagExists = $true
                            break
                        }
                    }
                }

                if ($TagExists) {
                    $SkippedCount++
                    continue
                }

                $IndexedChanges.Add([PSCustomObject]@{
                    InsertIdx  = $BulletInfo.ChildrenEndIdx
                    DoorTarget = $Change.DoorTarget
                    FirstSeen  = $Change.FirstSeen
                })
            }

            # Apply from bottom to top (descending insert index)
            $IndexedChanges = @([System.Linq.Enumerable]::OrderByDescending(
                [object[]]$IndexedChanges, [Func[object,int]]{ param($X) $X.InsertIdx }))

            foreach ($IC in $IndexedChanges) {
                $Temporal = ''
                if ($IC.FirstSeen -and $IC.FirstSeen -ne '?') {
                    # Use YYYY-MM format for temporal annotation
                    $DateStr = $IC.FirstSeen
                    if ($DateStr.Length -ge 7) { $DateStr = $DateStr.Substring(0, 7) }
                    $Temporal = " ($DateStr`:)"
                }
                $TagLine = "    - @drzwi: $($IC.DoorTarget)$Temporal"
                $Lines.Insert($IC.InsertIdx, $TagLine)
                $AppliedCount++
            }

            if ($IndexedChanges.Count -gt 0) {
                Write-EntityFile -Path $FilePath -Lines $Lines -NL $NL
            }
        }

        Write-StepOK "Zapisano: $AppliedCount tagów @drzwi  |  Pominięto: $SkippedCount (istniejące)"
        Update-PhaseChecklist -State $State -Phase 6 -Item 'DrzwiApplied' -Value $true
    }

    # ── Step 9: Verification ──────────────────────────────────────────────
    Write-Step -Number 9 -Text 'Weryfikacja...'

    $UpdatedEntities = @(Get-Entity -Quiet)
    $DrzwiEntities = @($UpdatedEntities.Where({ $null -ne $_.Doors -and $_.Doors.Count -gt 0 }))

    Write-Host "    Lokacje z @drzwi: $($DrzwiEntities.Count)" -ForegroundColor (Resolve-MigrationColor -Role 'Accent')
    Update-PhaseChecklist -State $State -Phase 6 -Item 'VerificationDone' -Value $true

    # ── Step 10: Rebuild graph ────────────────────────────────────────────
    Write-Step -Number 10 -Text 'Odbudowa grafu lokalizacji...'

    $NewGraph = Get-LocationGraph -Sessions $Sessions -Entities $UpdatedEntities `
        -SessionLog $LogReport -IncludeMovementEdges -Quiet
    $NewDoorCount = @($NewGraph.Edges.Where({ $_.Type -eq 'Door' })).Count

    Write-Host "    Door (przed): $($ExistingDoors.Count)  |  Door (po): $NewDoorCount  |  Nowe: $($NewDoorCount - $ExistingDoors.Count)" -ForegroundColor (Resolve-MigrationColor -Role 'Accent')
    Update-PhaseChecklist -State $State -Phase 6 -Item 'GraphRebuilt' -Value $true

    # ── Step 11: Optional commit ──────────────────────────────────────────
    if (-not $WhatIf) {
        Write-Step -Number 11 -Text 'Zapis zmian...'
        if (Request-YesNo -Prompt 'Zacommitować zmiany @drzwi?' -Default $true) {
            $CommitMsg = "Migration Phase 6: @drzwi door inference ($AppliedCount tags)"
            try {
                $null = & git -C $RepoRoot add -A
                $null = & git -C $RepoRoot commit -m $CommitMsg
                Write-StepOK "Commit: $CommitMsg"
                Update-PhaseChecklist -State $State -Phase 6 -Item 'Committed' -Value $true
            }
            catch {
                Write-StepWarning "Commit nieudany: $_"
            }
        }
    }

    # ── Mark complete ─────────────────────────────────────────────────────
    Set-PhaseCompleted -State $State -Phase 6
    Write-PhaseSummary -Phase 6 -Status 'Completed' -Lines @(
        "[OK] $($Candidates.Count) kandydatów wnioskowanych z logów"
        "[OK] $AppliedCount tagów @drzwi zapisanych"
        "[OK] Graf lokalizacji odbudowany"
    )
}
