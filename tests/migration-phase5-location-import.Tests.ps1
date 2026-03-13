<#
    .SYNOPSIS
    Tests for Migration Phase 3: Import lokalizacji z mapy.
    Tests hierarchy inference logic and override file parsing.
#>

BeforeAll {
    . "$PSScriptRoot/TestHelpers.ps1"

    # Dot-source the migration location helpers (self-contained, no module needed)
    . (Join-Path $script:ModuleRoot 'migration' 'migration-location-helpers.ps1')

    # Load test fixture
    $script:FixtureMapsPath = Join-Path $script:FixturesRoot 'maps-test.json'
    $script:FixtureMaps = [System.IO.File]::ReadAllText($script:FixtureMapsPath) | ConvertFrom-Json
}

# ── Get-MapBaseNameDeterministic ────────────────────────────────────────────

Describe 'Get-MapBaseNameDeterministic' {
    It 'returns unchanged name for root locations' {
        Get-MapBaseNameDeterministic -Name 'Steadwick' | Should -Be 'Steadwick'
    }

    It 'returns unchanged name for hyphenated roots (no " - " subarea)' {
        Get-MapBaseNameDeterministic -Name 'Hammer-Fall' | Should -Be 'Hammer-Fall'
    }

    It 'strips floor suffix p.N' {
        Get-MapBaseNameDeterministic -Name 'Smocza Utopia p.2' | Should -Be 'Smocza Utopia'
    }

    It 'strips room suffix s.N' {
        Get-MapBaseNameDeterministic -Name 'Gaj Elfów s.2' | Should -Be 'Gaj Elfów'
    }

    It 'strips direction suffix' {
        Get-MapBaseNameDeterministic -Name 'Steadwick - północ' | Should -Be 'Steadwick'
        Get-MapBaseNameDeterministic -Name 'Steadwick - południe' | Should -Be 'Steadwick'
    }

    It 'strips difficulty parenthetical' {
        Get-MapBaseNameDeterministic -Name 'Siedlisko Behemotów (poziom: trudny)' | Should -Be 'Siedlisko Behemotów'
    }

    It 'strips sala N suffix' {
        Get-MapBaseNameDeterministic -Name 'Krypta p.3 - sala 2' | Should -Be 'Krypta'
    }

    It 'strips named Sala suffix' {
        Get-MapBaseNameDeterministic -Name 'Wieża Nighonu p.1 - Sala Złotego Smoka' | Should -Be 'Wieża Nighonu'
    }

    It 'strips compound suffixes iteratively' {
        Get-MapBaseNameDeterministic -Name 'Smocza Utopia p.3 - sala 2' | Should -Be 'Smocza Utopia'
    }

    It 'strips named subarea with lowercase start' {
        Get-MapBaseNameDeterministic -Name 'Zamek Gryphonheart - głębokie lochy' | Should -Be 'Zamek Gryphonheart'
    }

    It 'strips lochy subarea with floor suffix' {
        Get-MapBaseNameDeterministic -Name 'Zamek Gryphonheart - lochy wschodnie p.2' | Should -Be 'Zamek Gryphonheart'
    }
}

# ── Get-MapBaseNameIntermediates ──────────────────────────────────────────────

Describe 'Get-MapBaseNameIntermediates' {
    It 'returns empty array for root locations (no stripping)' {
        $Result = @(Get-MapBaseNameIntermediates -Name 'Steadwick')
        $Result.Count | Should -Be 0
    }

    It 'returns empty array for hyphenated roots' {
        $Result = @(Get-MapBaseNameIntermediates -Name 'Hammer-Fall')
        $Result.Count | Should -Be 0
    }

    It 'returns single intermediate for floor-only suffix' {
        $Result = @(Get-MapBaseNameIntermediates -Name 'Smocza Utopia p.2')
        $Result.Count | Should -Be 1
        $Result[0] | Should -Be 'Smocza Utopia'
    }

    It 'returns single intermediate for direction suffix' {
        $Result = @(Get-MapBaseNameIntermediates -Name 'Steadwick - północ')
        $Result.Count | Should -Be 1
        $Result[0] | Should -Be 'Steadwick'
    }

    It 'returns per-pattern intermediates for compound suffix (floor + sala)' {
        # "Smocza Utopia p.3 - sala 2"
        #   → strip sala → "Smocza Utopia p.3"
        #   → strip floor → "Smocza Utopia"
        $Result = @(Get-MapBaseNameIntermediates -Name 'Smocza Utopia p.3 - sala 2')
        $Result.Count | Should -Be 2
        $Result[0] | Should -Be 'Smocza Utopia p.3'
        $Result[1] | Should -Be 'Smocza Utopia'
    }

    It 'returns per-pattern intermediates for named subarea + floor' {
        # "Zamek Gryphonheart - lochy wschodnie p.2"
        #   → strip floor → "Zamek Gryphonheart - lochy wschodnie"
        #   → strip named subarea → "Zamek Gryphonheart"
        $Result = @(Get-MapBaseNameIntermediates -Name 'Zamek Gryphonheart - lochy wschodnie p.2')
        $Result.Count | Should -Be 2
        $Result[0] | Should -Be 'Zamek Gryphonheart - lochy wschodnie'
        $Result[1] | Should -Be 'Zamek Gryphonheart'
    }

    It 'returns per-pattern intermediates for tower + floor' {
        # "Cytadela AvLee - wieża płn.-wsch. p.1"
        #   → strip floor → "Cytadela AvLee - wieża płn.-wsch."
        #   → strip named subarea → "Cytadela AvLee"
        $Result = @(Get-MapBaseNameIntermediates -Name 'Cytadela AvLee - wieża płn.-wsch. p.1')
        $Result.Count | Should -Be 2
        $Result[0] | Should -Be 'Cytadela AvLee - wieża płn.-wsch.'
        $Result[1] | Should -Be 'Cytadela AvLee'
    }

    It 'returns per-pattern intermediates for Named Sala + floor' {
        # "Wieża Nighonu p.1 - Sala Złotego Smoka"
        #   → strip Named Sala → "Wieża Nighonu p.1"
        #   → strip floor → "Wieża Nighonu"
        $Result = @(Get-MapBaseNameIntermediates -Name 'Wieża Nighonu p.1 - Sala Złotego Smoka')
        $Result.Count | Should -Be 2
        $Result[0] | Should -Be 'Wieża Nighonu p.1'
        $Result[1] | Should -Be 'Wieża Nighonu'
    }

    It 'orders intermediates from most-specific to most-stripped' {
        $Result = @(Get-MapBaseNameIntermediates -Name 'Smocza Utopia p.3 - sala 2')
        # Most specific first
        $Result[0].Length | Should -BeGreaterThan $Result[1].Length
    }
}

# ── Get-MapBaseNameCandidates ───────────────────────────────────────────────

Describe 'Get-MapBaseNameCandidates' {
    It 'returns empty array for single-word names' {
        $Result = Get-MapBaseNameCandidates -Name 'Steadwick'
        $Result.Count | Should -Be 0
    }

    It 'strips difficulty and produces candidates' {
        $Result = Get-MapBaseNameCandidates -Name 'Siedlisko Behemotów (poziom: trudny)'
        $Result.Count | Should -BeGreaterThan 0
        $Result[0] | Should -Be 'Siedlisko Behemotów'
    }

    It 'produces progressive word-removal candidates' {
        $Result = Get-MapBaseNameCandidates -Name 'Zamek Gryphonheart - głębokie lochy'
        $Result.Count | Should -BeGreaterThan 1
        # Longest candidate first
        $Result[0] | Should -Be 'Zamek Gryphonheart - głębokie'
    }

    It 'strips trailing separators from candidates' {
        $Result = Get-MapBaseNameCandidates -Name 'Steadwick - północ'
        # Should contain 'Steadwick' (after stripping trailing ' -')
        $Result | Should -Contain 'Steadwick'
    }

    It 'does not include the original name in candidates' {
        $Result = Get-MapBaseNameCandidates -Name 'Smocza Utopia p.2'
        $Result | Should -Not -Contain 'Smocza Utopia p.2'
    }
}

# ── Hierarchy Inference (integration with fixture) ──────────────────────────

Describe 'Hierarchy inference from maps-test.json' {
    BeforeAll {
        $Maps = @($script:FixtureMaps.maps)

        # Build name set
        $NameSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($Map in $Maps) {
            [void]$NameSet.Add($Map.name)
        }

        # Compute parent map (same algorithm as phase3-location-import.ps1)
        $script:ParentMap = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($Map in $Maps) {
            $Name = $Map.name
            $Intermediates = @(Get-MapBaseNameIntermediates -Name $Name)

            if ($Intermediates.Count -eq 0) {
                $script:ParentMap[$Name] = $null
                continue
            }

            $Found = $false
            foreach ($Base in $Intermediates) {
                if ($NameSet.Contains($Base)) {
                    $script:ParentMap[$Name] = $Base
                    $Found = $true
                    break
                }
            }
            if ($Found) { continue }

            $Candidates = Get-MapBaseNameCandidates -Name $Name
            foreach ($Candidate in $Candidates) {
                if ($NameSet.Contains($Candidate)) {
                    $script:ParentMap[$Name] = $Candidate
                    $Found = $true
                    break
                }
            }
            if ($Found) { continue }

            # Virtual parent: use most-stripped deterministic base
            $script:ParentMap[$Name] = $Intermediates[$Intermediates.Count - 1]
        }

        # Confirmed parent self-linking (same as phase3 Step 2)
        $script:ConfirmedParents = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($Entry in $script:ParentMap.GetEnumerator()) {
            if (-not [string]::IsNullOrEmpty($Entry.Value)) {
                [void]$script:ConfirmedParents.Add($Entry.Value)
            }
        }
        foreach ($ParentName in $script:ConfirmedParents) {
            if ($script:ParentMap.ContainsKey($ParentName) -and [string]::IsNullOrEmpty($script:ParentMap[$ParentName])) {
                $script:ParentMap[$ParentName] = $ParentName
            }
        }

        # Orphan standalone self-linking (same as phase3 Step 2)
        $UrlIndex = [System.Collections.Generic.Dictionary[string, int]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($Map in $Maps) {
            if ($UrlIndex.ContainsKey($Map.url)) { $UrlIndex[$Map.url]++ }
            else { $UrlIndex[$Map.url] = 1 }
        }
        $NameToUrl = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($Map in $Maps) { $NameToUrl[$Map.name] = $Map.url }

        $script:SelfLinkedNames = [System.Collections.Generic.HashSet[string]]::new($script:ConfirmedParents, [System.StringComparer]::OrdinalIgnoreCase)
        $OrphanCandidates = [System.Collections.Generic.List[string]]::new()
        foreach ($Entry in $script:ParentMap.GetEnumerator()) {
            if (-not [string]::IsNullOrEmpty($Entry.Value)) { continue }
            if ($script:ConfirmedParents.Contains($Entry.Key)) { continue }
            $Url = $NameToUrl[$Entry.Key]
            if (-not $Url) { continue }
            if ($Url.Contains('/eve/')) { continue }
            if ($UrlIndex[$Url] -gt 1) { continue }
            $OrphanCandidates.Add($Entry.Key)
        }
        foreach ($OrphanName in $OrphanCandidates) {
            $script:ParentMap[$OrphanName] = $OrphanName
            [void]$script:SelfLinkedNames.Add($OrphanName)
        }
    }

    It 'classifies root exterior locations correctly' {
        # Steadwick is a confirmed parent (has children) → self-linked
        $script:ParentMap['Steadwick'] | Should -Be 'Steadwick'
        # Bracada has no children, unique URL → orphan standalone, self-linked
        $script:ParentMap['Bracada'] | Should -Be 'Bracada'
        # Hammer-Fall has no children, unique URL → orphan standalone, self-linked
        $script:ParentMap['Hammer-Fall'] | Should -Be 'Hammer-Fall'
    }

    It 'finds parent for direction children (Steadwick - północ → Steadwick)' {
        $script:ParentMap['Steadwick - północ'] | Should -Be 'Steadwick'
        $script:ParentMap['Steadwick - południe'] | Should -Be 'Steadwick'
    }

    It 'finds parent for floor children (Smocza Utopia p.2 → Smocza Utopia)' {
        $script:ParentMap['Smocza Utopia p.2'] | Should -Be 'Smocza Utopia'
    }

    It 'finds parent for compound children (Smocza Utopia p.3 - sala 2 → Smocza Utopia)' {
        $script:ParentMap['Smocza Utopia p.3 - sala 2'] | Should -Be 'Smocza Utopia'
    }

    It 'finds parent for named subarea children (Zamek Gryphonheart - głębokie lochy → Zamek Gryphonheart)' {
        $script:ParentMap['Zamek Gryphonheart - głębokie lochy'] | Should -Be 'Zamek Gryphonheart'
    }

    It 'finds parent for subarea + floor children (Zamek Gryphonheart - lochy wschodnie p.2 → Zamek Gryphonheart)' {
        $script:ParentMap['Zamek Gryphonheart - lochy wschodnie p.2'] | Should -Be 'Zamek Gryphonheart'
    }

    It 'finds parent for difficulty child (Siedlisko Behemotów (poziom: trudny) → Siedlisko Behemotów)' {
        $script:ParentMap['Siedlisko Behemotów (poziom: trudny)'] | Should -Be 'Siedlisko Behemotów'
    }

    It 'finds parent for compound Named Sala child (Wieża Nighonu p.1 - Sala Złotego Smoka → Wieża Nighonu)' {
        $script:ParentMap['Wieża Nighonu p.1 - Sala Złotego Smoka'] | Should -Be 'Wieża Nighonu'
    }

    It 'self-links standalone roots that are confirmed parents' {
        # All three have children → confirmed parents → self-linked
        $script:ParentMap['Zamek Gryphonheart'] | Should -Be 'Zamek Gryphonheart'
        $script:ParentMap['Smocza Utopia'] | Should -Be 'Smocza Utopia'
        $script:ParentMap['Wieża Nighonu'] | Should -Be 'Wieża Nighonu'
    }

    # ── Intermediate match: prefers most-specific existing parent ─────────

    It 'prefers intermediate parent over most-stripped (sala child → floor parent)' {
        # "Krypta Bohaterów p.1 - sala 1"
        #   intermediates: ["Krypta Bohaterów p.1", "Krypta Bohaterów"]
        #   "Krypta Bohaterów p.1" exists in fixture → preferred
        $script:ParentMap['Krypta Bohaterów p.1 - sala 1'] | Should -Be 'Krypta Bohaterów p.1'
        $script:ParentMap['Krypta Bohaterów p.1 - sala 2'] | Should -Be 'Krypta Bohaterów p.1'
    }

    # ── Virtual parent: base name not in NameSet ─────────────────────────

    It 'assigns virtual parent when no intermediate exists in NameSet' {
        # "Cytadela AvLee - wieża płn.-wsch. p.1"
        #   intermediates: ["Cytadela AvLee - wieża płn.-wsch.", "Cytadela AvLee"]
        #   neither exists in NameSet → virtual parent = "Cytadela AvLee"
        $script:ParentMap['Cytadela AvLee - wieża płn.-wsch. p.1'] | Should -Be 'Cytadela AvLee'
        $script:ParentMap['Cytadela AvLee - wieża płn.-wsch. p.2'] | Should -Be 'Cytadela AvLee'
    }

    It 'assigns virtual parent for simple named subarea with no base in set' {
        # "Cytadela AvLee - korytarz zachodni"
        #   intermediates: ["Cytadela AvLee"]
        #   not in NameSet → virtual parent = "Cytadela AvLee"
        $script:ParentMap['Cytadela AvLee - korytarz zachodni'] | Should -Be 'Cytadela AvLee'
    }

    It 'virtual parent for floor-only child groups siblings under same base' {
        # "Krypta Bohaterów p.1" → intermediates: ["Krypta Bohaterów"]
        # "Krypta Bohaterów" not in NameSet → virtual parent
        $script:ParentMap['Krypta Bohaterów p.1'] | Should -Be 'Krypta Bohaterów'
    }

    # ── Uppercase subarea stripping (LocNamedSubareaPattern fix) ───────

    It 'finds parent for uppercase-starting subarea (Tawerna Erathii - Komnata Magów)' {
        $script:ParentMap['Tawerna Erathii - Komnata Magów'] | Should -Be 'Tawerna Erathii'
    }

    It 'finds parent for floor child alongside uppercase subarea sibling' {
        $script:ParentMap['Tawerna Erathii p.1'] | Should -Be 'Tawerna Erathii'
    }

    # ── Confirmed parent self-linking ──────────────────────────────────

    It 'self-links confirmed parents to their own Lokacja' {
        # Steadwick has children (- północ, - południe) → confirmed parent
        $script:ParentMap['Steadwick'] | Should -Be 'Steadwick'
        # Tawerna Erathii has children → confirmed parent
        $script:ParentMap['Tawerna Erathii'] | Should -Be 'Tawerna Erathii'
    }

    It 'does not self-link shared-URL orphans or event maps' {
        # Shared-URL generic rooms remain null
        $script:ParentMap['Cela Więzienna 1'] | Should -BeNullOrEmpty
        # Event maps remain null
        $script:ParentMap['Festiwalowa Arena'] | Should -BeNullOrEmpty
    }

    # ── Orphan standalone self-linking (unique URL) ────────────────────

    It 'self-links orphan standalone maps with unique URLs' {
        $script:ParentMap['Kopalnia Kryształów'] | Should -Be 'Kopalnia Kryształów'
        $script:ParentMap['Chata Wiedźmy'] | Should -Be 'Chata Wiedźmy'
    }

    It 'does not self-link generic rooms with shared URLs' {
        $script:ParentMap['Cela Więzienna 1'] | Should -BeNullOrEmpty
        $script:ParentMap['Cela Więzienna 2'] | Should -BeNullOrEmpty
        $script:ParentMap['Cela Więzienna 3'] | Should -BeNullOrEmpty
    }

    It 'excludes event maps from self-linking' {
        $script:ParentMap['Festiwalowa Arena'] | Should -BeNullOrEmpty
    }

    It 'includes orphan standalones in SelfLinkedNames set' {
        $script:SelfLinkedNames | Should -Contain 'Kopalnia Kryształów'
        $script:SelfLinkedNames | Should -Contain 'Chata Wiedźmy'
        $script:SelfLinkedNames | Should -Not -Contain 'Cela Więzienna 1'
        $script:SelfLinkedNames | Should -Not -Contain 'Festiwalowa Arena'
    }
}

# ── Override file parsing ───────────────────────────────────────────────────

Describe 'Override file parsing' {
    BeforeAll {
        $script:TempDir = New-TestTempDir
        $script:OverridePath = Join-Path $script:TempDir 'location-overrides.txt'
    }

    It 'parses Section 1 nazwa_nerthus overrides' {
        $Content = @(
            '# Sekcja 1: Nazwy Nerthus (NazwaMargonem<TAB>NazwaNerthus)'
            "Steadwick`tSteadwick (Nerthus)"
            'Bracada'
            "Zamek Gryphonheart`tTwierdza Kreeganu"
        )
        [System.IO.File]::WriteAllLines($script:OverridePath, $Content, [System.Text.UTF8Encoding]::new($false))

        $Lines = [System.IO.File]::ReadAllLines($script:OverridePath, [System.Text.UTF8Encoding]::new($false))
        $InSection1 = $false
        $InSection2 = $false
        $Overrides = [System.Collections.Generic.List[object]]::new()

        foreach ($Line in $Lines) {
            $Trimmed = $Line.Trim()
            if ($Trimmed.Length -eq 0) { continue }
            if ($Trimmed.StartsWith('#')) {
                if ($Trimmed -match 'Sekcja 1') { $InSection1 = $true; $InSection2 = $false }
                elseif ($Trimmed -match 'Sekcja 2') { $InSection1 = $false; $InSection2 = $true }
                continue
            }

            if ($InSection1) {
                $Parts = $Line.Split("`t")
                $MapName = $Parts[0].Trim()
                $NerthusName = if ($Parts.Count -ge 2) { $Parts[1].Trim() } else { '' }
                if ($NerthusName.Length -gt 0) {
                    $Overrides.Add([PSCustomObject]@{ MapName = $MapName; NerthusName = $NerthusName })
                }
            }
        }

        $Overrides.Count | Should -Be 2
        $Overrides[0].MapName | Should -Be 'Steadwick'
        $Overrides[0].NerthusName | Should -Be 'Steadwick (Nerthus)'
        $Overrides[1].MapName | Should -Be 'Zamek Gryphonheart'
        $Overrides[1].NerthusName | Should -Be 'Twierdza Kreeganu'
    }

    It 'parses Section 2 virtual locations' {
        $Content = @(
            '# Sekcja 1: Nazwy Nerthus'
            ''
            '# Sekcja 2: Lokalizacje wirtualne (Nazwa<TAB>Rodzic<TAB>NazwaNerthus)'
            "Akademia Magii`tBracada"
            "Tawerna Pod Gryfem`tSteadwick`tKarczma"
        )
        [System.IO.File]::WriteAllLines($script:OverridePath, $Content, [System.Text.UTF8Encoding]::new($false))

        $Lines = [System.IO.File]::ReadAllLines($script:OverridePath, [System.Text.UTF8Encoding]::new($false))
        $InSection1 = $false
        $InSection2 = $false
        $VirtualLocations = [System.Collections.Generic.List[object]]::new()

        foreach ($Line in $Lines) {
            $Trimmed = $Line.Trim()
            if ($Trimmed.Length -eq 0) { continue }
            if ($Trimmed.StartsWith('#')) {
                if ($Trimmed -match 'Sekcja 1') { $InSection1 = $true; $InSection2 = $false }
                elseif ($Trimmed -match 'Sekcja 2') { $InSection1 = $false; $InSection2 = $true }
                continue
            }

            if ($InSection2) {
                $Parts = $Line.Split("`t")
                $VirtName = $Parts[0].Trim()
                $VirtParent = if ($Parts.Count -ge 2) { $Parts[1].Trim() } else { '' }
                $VirtNerthus = if ($Parts.Count -ge 3) { $Parts[2].Trim() } else { '' }
                if ($VirtName.Length -gt 0) {
                    $VirtualLocations.Add([PSCustomObject]@{
                        Name = $VirtName; Parent = $VirtParent; NerthusName = $VirtNerthus
                    })
                }
            }
        }

        $VirtualLocations.Count | Should -Be 2
        $VirtualLocations[0].Name | Should -Be 'Akademia Magii'
        $VirtualLocations[0].Parent | Should -Be 'Bracada'
        $VirtualLocations[0].NerthusName | Should -BeNullOrEmpty
        $VirtualLocations[1].Name | Should -Be 'Tawerna Pod Gryfem'
        $VirtualLocations[1].Parent | Should -Be 'Steadwick'
        $VirtualLocations[1].NerthusName | Should -Be 'Karczma'
    }

    AfterAll {
        if ($script:TempDir -and [System.IO.Directory]::Exists($script:TempDir)) {
            [System.IO.Directory]::Delete($script:TempDir, $true)
        }
    }
}
