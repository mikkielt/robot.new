<#
    .SYNOPSIS
    Tests for Migration Phase 5: Import lokalizacji z mapy.
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
        Get-MapBaseNameDeterministic -Name 'Ithan' | Should -Be 'Ithan'
    }

    It 'returns unchanged name for hyphenated roots (no " - " subarea)' {
        Get-MapBaseNameDeterministic -Name 'Karka-han' | Should -Be 'Karka-han'
    }

    It 'strips floor suffix p.N' {
        Get-MapBaseNameDeterministic -Name 'Piekielna Grota p.2' | Should -Be 'Piekielna Grota'
    }

    It 'strips room suffix s.N' {
        Get-MapBaseNameDeterministic -Name 'Grota Arbor s.2' | Should -Be 'Grota Arbor'
    }

    It 'strips direction suffix' {
        Get-MapBaseNameDeterministic -Name 'Ithan - północ' | Should -Be 'Ithan'
        Get-MapBaseNameDeterministic -Name 'Ithan - południe' | Should -Be 'Ithan'
    }

    It 'strips difficulty parenthetical' {
        Get-MapBaseNameDeterministic -Name 'Lezysko Baraniego Kanoniera (poziom: trudny)' | Should -Be 'Lezysko Baraniego Kanoniera'
    }

    It 'strips sala N suffix' {
        Get-MapBaseNameDeterministic -Name 'Grota p.3 - sala 2' | Should -Be 'Grota'
    }

    It 'strips named Sala suffix' {
        Get-MapBaseNameDeterministic -Name 'Erem Czarnego Słońca p.1 - Sala Magicznego Błota' | Should -Be 'Erem Czarnego Słońca'
    }

    It 'strips compound suffixes iteratively' {
        Get-MapBaseNameDeterministic -Name 'Piekielna Grota p.3 - sala 2' | Should -Be 'Piekielna Grota'
    }

    It 'strips named subarea with lowercase start' {
        Get-MapBaseNameDeterministic -Name 'Potępione Zamczysko - głębokie lochy' | Should -Be 'Potępione Zamczysko'
    }

    It 'strips lochy subarea with floor suffix' {
        Get-MapBaseNameDeterministic -Name 'Potępione Zamczysko - lochy wschodnie p.2' | Should -Be 'Potępione Zamczysko'
    }
}

# ── Get-MapBaseNameCandidates ───────────────────────────────────────────────

Describe 'Get-MapBaseNameCandidates' {
    It 'returns empty array for single-word names' {
        $Result = Get-MapBaseNameCandidates -Name 'Ithan'
        $Result.Count | Should -Be 0
    }

    It 'strips difficulty and produces candidates' {
        $Result = Get-MapBaseNameCandidates -Name 'Lezysko Baraniego Kanoniera (poziom: trudny)'
        $Result.Count | Should -BeGreaterThan 0
        $Result[0] | Should -Be 'Lezysko Baraniego Kanoniera'
    }

    It 'produces progressive word-removal candidates' {
        $Result = Get-MapBaseNameCandidates -Name 'Potępione Zamczysko - głębokie lochy'
        $Result.Count | Should -BeGreaterThan 1
        # Longest candidate first
        $Result[0] | Should -Be 'Potępione Zamczysko - głębokie'
    }

    It 'strips trailing separators from candidates' {
        $Result = Get-MapBaseNameCandidates -Name 'Ithan - północ'
        # Should contain 'Ithan' (after stripping trailing ' -')
        $Result | Should -Contain 'Ithan'
    }

    It 'does not include the original name in candidates' {
        $Result = Get-MapBaseNameCandidates -Name 'Piekielna Grota p.2'
        $Result | Should -Not -Contain 'Piekielna Grota p.2'
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
            $BaseName = Get-MapBaseNameDeterministic -Name $Name

            if ([string]::Equals($BaseName, $Name, [System.StringComparison]::OrdinalIgnoreCase)) {
                $script:ParentMap[$Name] = $null
                continue
            }

            if ($NameSet.Contains($BaseName)) {
                $script:ParentMap[$Name] = $BaseName
                continue
            }

            $Candidates = Get-MapBaseNameCandidates -Name $Name
            $Found = $false
            foreach ($Candidate in $Candidates) {
                if ($NameSet.Contains($Candidate)) {
                    $script:ParentMap[$Name] = $Candidate
                    $Found = $true
                    break
                }
            }

            if (-not $Found) {
                $script:ParentMap[$Name] = $null
            }
        }
    }

    It 'classifies root exterior locations correctly' {
        $script:ParentMap['Ithan'] | Should -BeNullOrEmpty
        $script:ParentMap['Bracada'] | Should -BeNullOrEmpty
        $script:ParentMap['Karka-han'] | Should -BeNullOrEmpty
    }

    It 'finds parent for direction children (Ithan - północ → Ithan)' {
        $script:ParentMap['Ithan - północ'] | Should -Be 'Ithan'
        $script:ParentMap['Ithan - południe'] | Should -Be 'Ithan'
    }

    It 'finds parent for floor children (Piekielna Grota p.2 → Piekielna Grota)' {
        $script:ParentMap['Piekielna Grota p.2'] | Should -Be 'Piekielna Grota'
    }

    It 'finds parent for compound children (Piekielna Grota p.3 - sala 2 → Piekielna Grota)' {
        $script:ParentMap['Piekielna Grota p.3 - sala 2'] | Should -Be 'Piekielna Grota'
    }

    It 'finds parent for named subarea children (Potępione Zamczysko - głębokie lochy → Potępione Zamczysko)' {
        $script:ParentMap['Potępione Zamczysko - głębokie lochy'] | Should -Be 'Potępione Zamczysko'
    }

    It 'finds parent for subarea + floor children (Potępione Zamczysko - lochy wschodnie p.2 → Potępione Zamczysko)' {
        $script:ParentMap['Potępione Zamczysko - lochy wschodnie p.2'] | Should -Be 'Potępione Zamczysko'
    }

    It 'finds parent for difficulty child (Lezysko Baraniego Kanoniera (poziom: trudny) → Lezysko Baraniego Kanoniera)' {
        $script:ParentMap['Lezysko Baraniego Kanoniera (poziom: trudny)'] | Should -Be 'Lezysko Baraniego Kanoniera'
    }

    It 'finds parent for compound Named Sala child (Erem Czarnego Słońca p.1 - Sala Magicznego Błota → Erem Czarnego Słońca)' {
        $script:ParentMap['Erem Czarnego Słońca p.1 - Sala Magicznego Błota'] | Should -Be 'Erem Czarnego Słońca'
    }

    It 'classifies standalone roots correctly' {
        $script:ParentMap['Potępione Zamczysko'] | Should -BeNullOrEmpty
        $script:ParentMap['Piekielna Grota'] | Should -BeNullOrEmpty
        $script:ParentMap['Erem Czarnego Słońca'] | Should -BeNullOrEmpty
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
            "Ithan`tIthan (Nerthus)"
            'Bracada'
            "Potępione Zamczysko`tPrzeklęty Zamek"
            ''
            '# Sekcja 2: Lokalizacje wirtualne'
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
        $Overrides[0].MapName | Should -Be 'Ithan'
        $Overrides[0].NerthusName | Should -Be 'Ithan (Nerthus)'
        $Overrides[1].MapName | Should -Be 'Potępione Zamczysko'
        $Overrides[1].NerthusName | Should -Be 'Przeklęty Zamek'
    }

    It 'parses Section 2 virtual locations' {
        $Content = @(
            '# Sekcja 1: Nazwy Nerthus'
            ''
            '# Sekcja 2: Lokalizacje wirtualne (Nazwa<TAB>Rodzic<TAB>NazwaNerthus)'
            "Akademia Magii`tBracada"
            "Tawerna Pod Smokiem`tIthan`tKarczma"
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
        $VirtualLocations[1].Name | Should -Be 'Tawerna Pod Smokiem'
        $VirtualLocations[1].Parent | Should -Be 'Ithan'
        $VirtualLocations[1].NerthusName | Should -Be 'Karczma'
    }

    AfterAll {
        if ($script:TempDir -and [System.IO.Directory]::Exists($script:TempDir)) {
            [System.IO.Directory]::Delete($script:TempDir, $true)
        }
    }
}
