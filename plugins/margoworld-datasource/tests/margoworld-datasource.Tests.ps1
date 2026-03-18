<#
    .SYNOPSIS
    Tests for the margoworld-datasource plugin.

    .DESCRIPTION
    Tests for Get-MapBaseName, ConvertFrom-MargoWorldList, ConvertFrom-MargoWorldDetail,
    Read-MargoWorldMapsJson, Write-MargoWorldMapsJson, Get-MargoWorldMapsJsonPath,
    ConvertFrom-MapsMarkdown, Get-UrlLocationContext, ConvertTo-MapsJsonFromMarkdown,
    and ConvertFrom-PngHeaderBytes covering suffix stripping (9 iterative patterns),
    legacy maps.md parsing, URL context extraction, end-to-end migration, and PNG
    header byte parsing.
#>

Describe 'margoworld-datasource' {

    BeforeAll {
        # Dot-source helpers directly for unit testing
        . "$PSScriptRoot/../private/margoworld-helpers.ps1"
    }

    Context 'Get-MapBaseName' {
        It 'strips floor suffix "p.N"' {
            $Result = Get-MapBaseName -Name 'Świszcząca Grota p.1'
            $Result | Should -Be 'Świszcząca Grota'
        }

        It 'strips multi-digit floor suffix' {
            $Result = Get-MapBaseName -Name 'Wielka Jaskinia p.12'
            $Result | Should -Be 'Wielka Jaskinia'
        }

        It 'strips sala suffix' {
            $Result = Get-MapBaseName -Name 'Kopalnia - sala 3'
            $Result | Should -Be 'Kopalnia'
        }

        It 'strips direction suffix' {
            $Result = Get-MapBaseName -Name 'Jaskinia - północ'
            $Result | Should -Be 'Jaskinia'
        }

        It 'strips direction suffix południe' {
            $Result = Get-MapBaseName -Name 'Labirynt - południe'
            $Result | Should -Be 'Labirynt'
        }

        It 'returns unchanged name without suffix' {
            $Result = Get-MapBaseName -Name 'Ithan'
            $Result | Should -Be 'Ithan'
        }

        It 'handles name with no suffix but similar text' {
            $Result = Get-MapBaseName -Name 'Dolina p.niemowlęca'
            $Result | Should -Be 'Dolina p.niemowlęca'
        }

        It 'strips difficulty suffix (poziom: trudny)' {
            $Result = Get-MapBaseName -Name 'Katakumby (poziom: trudny)'
            $Result | Should -Be 'Katakumby'
        }

        It 'strips difficulty suffix (poziom: normalny)' {
            $Result = Get-MapBaseName -Name 'Podziemia (poziom: normalny)'
            $Result | Should -Be 'Podziemia'
        }

        It 'strips difficulty suffix (poziom: mistrzowski)' {
            $Result = Get-MapBaseName -Name 'Wieża Magów (poziom: mistrzowski)'
            $Result | Should -Be 'Wieża Magów'
        }

        It 'strips room suffix "s.N"' {
            $Result = Get-MapBaseName -Name 'Zamek Smoka s.2'
            $Result | Should -Be 'Zamek Smoka'
        }

        It 'strips piętro suffix' {
            $Result = Get-MapBaseName -Name 'Wieża - piętro'
            $Result | Should -Be 'Wieża'
        }

        It 'strips piętro N suffix' {
            $Result = Get-MapBaseName -Name 'Wieża - piętro 2'
            $Result | Should -Be 'Wieża'
        }

        It 'strips piwnica suffix' {
            $Result = Get-MapBaseName -Name 'Zamek - piwnica'
            $Result | Should -Be 'Zamek'
        }

        It 'strips piwnica with floor suffix' {
            $Result = Get-MapBaseName -Name 'Zamek - piwnica p.2'
            $Result | Should -Be 'Zamek'
        }

        It 'strips named subarea (lowercase)' {
            $Result = Get-MapBaseName -Name 'Pałac - kuchnia'
            $Result | Should -Be 'Pałac'
        }

        It 'strips named subarea gabinet' {
            $Result = Get-MapBaseName -Name 'Ratusz - gabinet'
            $Result | Should -Be 'Ratusz'
        }

        It 'strips named subarea lobby' {
            $Result = Get-MapBaseName -Name 'Hotel - lobby'
            $Result | Should -Be 'Hotel'
        }

        It 'strips named subarea biblioteka' {
            $Result = Get-MapBaseName -Name 'Akademia - biblioteka'
            $Result | Should -Be 'Akademia'
        }

        It 'strips Named Sala suffix' {
            $Result = Get-MapBaseName -Name 'Podziemia - Sala Magicznego Błota'
            $Result | Should -Be 'Podziemia'
        }

        It 'strips compound p.N + Named Sala (iterative)' {
            $Result = Get-MapBaseName -Name 'Świątynia p.2 - Sala Magicznego Błota'
            $Result | Should -Be 'Świątynia'
        }

        It 'strips compound p.N + direction (iterative)' {
            $Result = Get-MapBaseName -Name 'Jaskinia p.1 - północ'
            $Result | Should -Be 'Jaskinia'
        }

        It 'does NOT strip Karka-han (no space-dash-space)' {
            $Result = Get-MapBaseName -Name 'Karka-han'
            $Result | Should -Be 'Karka-han'
        }
    }

    Context 'ConvertFrom-MargoWorldList' {
        It 'parses map links from HTML' {
            $Html = @'
<ul>
<li><a href="/world/view/1/ithan">Ithan</a></li>
<li><a href="/world/view/117/swiszczaca-grota-p1">Świszcząca Grota p.1</a></li>
<li><a href="/world/view/200/targowisko">Targowisko</a></li>
</ul>
'@
            $Result = ConvertFrom-MargoWorldList -Html $Html
            $Result.Count | Should -Be 3
            $Result[0].Id | Should -Be 1
            $Result[0].Name | Should -Be 'Ithan'
            $Result[0].Slug | Should -Be 'ithan'
            $Result[1].Id | Should -Be 117
            $Result[2].Name | Should -Be 'Targowisko'
        }

        It 'returns empty list for HTML without map links' {
            $Result = ConvertFrom-MargoWorldList -Html '<html><body>No maps here</body></html>'
            $Result.Count | Should -Be 0
        }

        It 'handles HTML-encoded characters' {
            $Html = '<li><a href="/world/view/5/test">G&oacute;ry</a></li>'
            $Result = ConvertFrom-MargoWorldList -Html $Html
            $Result.Count | Should -Be 1
            $Result[0].Name | Should -Be 'Góry'
        }
    }

    Context 'ConvertFrom-MargoWorldDetail' {
        It 'extracts CDN image URL from detail page' {
            $Html = @'
<div class="map-view">
<a target="_blank" href="https://micc.garmory-cdn.cloud/obrazki/miasta/ithan.png">
View full size
</a>
</div>
'@
            $Result = ConvertFrom-MargoWorldDetail -Html $Html
            $Result | Should -Be 'https://micc.garmory-cdn.cloud/obrazki/miasta/ithan.png'
        }

        It 'returns null when no CDN URL found' {
            $Result = ConvertFrom-MargoWorldDetail -Html '<html><body>No image</body></html>'
            $Result | Should -BeNullOrEmpty
        }
    }

    Context 'Read-MargoWorldMapsJson' {
        It 'reads valid maps.json' {
            $JsonPath = Join-Path $TestDrive 'maps.json'
            $Data = [PSCustomObject]@{
                lastUpdated = '2024-03-21T20:40:00+01:00'
                maps = @(
                    [PSCustomObject]@{ id = 1; name = 'Ithan'; url = 'https://cdn/ithan.png'; lastChecked = '2024-03-21T20:40:00' }
                    [PSCustomObject]@{ id = 117; name = 'Świszcząca Grota p.1'; url = 'https://cdn/sg1.png'; lastChecked = '2024-03-21T20:40:00' }
                )
            }
            $Data | ConvertTo-Json -Depth 4 | Set-Content -Path $JsonPath -Encoding UTF8

            $Result = Read-MargoWorldMapsJson -Path $JsonPath
            $Result | Should -Not -BeNullOrEmpty
            $Result.maps.Count | Should -Be 2
            $Result.maps[0].name | Should -Be 'Ithan'
        }

        It 'returns null for missing file' {
            $Result = Read-MargoWorldMapsJson -Path (Join-Path $TestDrive 'nonexistent.json')
            $Result | Should -BeNullOrEmpty
        }
    }

    Context 'Write-MargoWorldMapsJson' {
        It 'writes UTF-8 no BOM JSON file' {
            $OutPath = Join-Path $TestDrive 'output.json'
            $Data = [PSCustomObject]@{
                lastUpdated = '2024-03-21'
                maps = @(
                    [PSCustomObject]@{ id = 1; name = 'Test' }
                )
            }

            Write-MargoWorldMapsJson -Data $Data -Path $OutPath

            [System.IO.File]::Exists($OutPath) | Should -BeTrue

            # Check no BOM
            $Bytes = [System.IO.File]::ReadAllBytes($OutPath)
            # UTF-8 BOM is EF BB BF
            if ($Bytes.Count -ge 3) {
                ($Bytes[0] -eq 0xEF -and $Bytes[1] -eq 0xBB -and $Bytes[2] -eq 0xBF) | Should -BeFalse
            }

            $ReadBack = [System.IO.File]::ReadAllText($OutPath) | ConvertFrom-Json
            $ReadBack.maps[0].name | Should -Be 'Test'
        }
    }

    Context 'Get-MargoWorldMapsJsonPath' {
        It 'returns explicit config path when set' {
            $Config = @{ MapsJsonPath = '/some/explicit/maps.json' }
            $Result = Get-MargoWorldMapsJsonPath -Config $Config
            $Result | Should -Be '/some/explicit/maps.json'
        }
    }

    Context 'ConvertFrom-MapsMarkdown' {
        BeforeAll {
            $script:MapsMdPath = Join-Path $TestDrive 'maps.md'
            $script:MapsMdContent = @'
# Maps

- 2024-03-20 14:30 Scan results:
    - Id: 1; Nazwa: Ithan, Url: https://cdn/ithan.png
    - Id: 117; Nazwa: Świszcząca Grota p.1, Url: https://cdn/sg-p1.png
    - Id: 200; Nazwa: Targowisko, Url: https://cdn/targowisko.png
    - Id: 300; Nazwa: Katakumby (poziom: trudny), Url: https://cdn/katakumby-hard.png
    - Id: 400; Nazwa: Zamek Smoka s.2, Url: https://cdn/zamek-smoka-s2.png
- 2024-03-21 20:40 Updated scan:
    - Id: 1; Nazwa: Ithan, Url: https://cdn/ithan-v2.png
    - Id: 500; Nazwa: Wieża Magów p.1 - północ, Url: https://cdn/wieza-magow-p1-n.png
    - Id: 501; Nazwa: Wieża Magów p.1 - południe, Url: https://cdn/wieza-magow-p1-s.png
    - Id: 600; Nazwa: Karka-han, Url: https://cdn/karka-han.png
'@
            [System.IO.File]::WriteAllText($script:MapsMdPath, $script:MapsMdContent,
                [System.Text.UTF8Encoding]::new($false))
        }

        It 'parses all unique entries after dedup' {
            $Result = ConvertFrom-MapsMarkdown -Path $script:MapsMdPath
            $Result | Should -Not -BeNullOrEmpty
            # IDs: 1(deduped), 117, 200, 300, 400, 500, 501, 600 = 8 unique
            $Result.maps.Count | Should -Be 8
        }

        It 'keeps latest group entry on ID collision' {
            $Result = ConvertFrom-MapsMarkdown -Path $script:MapsMdPath
            $Ithan = $Result.maps | Where-Object { $_.id -eq 1 }
            $Ithan.url | Should -Be 'https://cdn/ithan-v2.png'
            $Ithan.lastChecked | Should -Be '2024-03-21 20:40'
        }

        It 'preserves lastUpdated from latest group' {
            $Result = ConvertFrom-MapsMarkdown -Path $script:MapsMdPath
            $Result.lastUpdated | Should -Be '2024-03-21 20:40'
        }

        It 'returns null for missing file' {
            $Result = ConvertFrom-MapsMarkdown -Path (Join-Path $TestDrive 'nonexistent-maps.md')
            $Result | Should -BeNullOrEmpty
        }
    }

    Context 'Get-UrlLocationContext' {
        It 'extracts context from CDN URL' {
            $Result = Get-UrlLocationContext -Url 'https://micc.garmory-cdn.cloud/obrazki/miasta/torneg-umbar-top.2.png'
            $Result | Should -Be 'torneg-umbar'
        }

        It 'strips version suffix from filename' {
            $Result = Get-UrlLocationContext -Url 'https://cdn/obrazki/miasta/ithan.3.png'
            $Result | Should -Be 'ithan'
        }

        It 'returns null for empty URL' {
            $Result = Get-UrlLocationContext -Url ''
            $Result | Should -BeNullOrEmpty
        }

        It 'handles URL with floor markers' {
            $Result = Get-UrlLocationContext -Url 'https://cdn/obrazki/miasta/zamek-smoka-p2.png'
            $Result | Should -Be 'zamek-smoka'
        }
    }

    Context 'ConvertTo-MapsJsonFromMarkdown' {
        BeforeAll {
            . "$PSScriptRoot/../public/ConvertTo-MapsJsonFromMarkdown.ps1"
        }

        It 'converts maps.md to maps.json end-to-end' {
            $SrcPath = Join-Path $TestDrive 'migrate-src.md'
            $DstPath = Join-Path $TestDrive 'migrate-dst.json'

            $MdContent = @'
- 2024-06-01 10:00 Test scan:
    - Id: 10; Nazwa: Ithan, Url: https://cdn/ithan.png
    - Id: 20; Nazwa: Zamek p.1, Url: https://cdn/zamek-p1.png
'@
            [System.IO.File]::WriteAllText($SrcPath, $MdContent,
                [System.Text.UTF8Encoding]::new($false))

            $Result = ConvertTo-MapsJsonFromMarkdown -SourcePath $SrcPath -DestinationPath $DstPath
            $Result.Success | Should -BeTrue
            $Result.EntriesRead | Should -Be 2
            $Result.EntriesWritten | Should -Be 2

            # Verify output is readable by Read-MargoWorldMapsJson
            $ReadBack = Read-MargoWorldMapsJson -Path $DstPath
            $ReadBack | Should -Not -BeNullOrEmpty
            $ReadBack.maps.Count | Should -Be 2
            $ReadBack.maps[0].name | Should -Be 'Ithan'
        }

        It 'supports -WhatIf without writing file' {
            $SrcPath = Join-Path $TestDrive 'whatif-src.md'
            $DstPath = Join-Path $TestDrive 'whatif-dst.json'

            $MdContent = @'
- 2024-06-01 10:00 Test:
    - Id: 10; Nazwa: Ithan, Url: https://cdn/ithan.png
'@
            [System.IO.File]::WriteAllText($SrcPath, $MdContent,
                [System.Text.UTF8Encoding]::new($false))

            $Result = ConvertTo-MapsJsonFromMarkdown -SourcePath $SrcPath -DestinationPath $DstPath -WhatIf
            $Result.EntriesRead | Should -Be 1
            $Result.EntriesWritten | Should -Be 0
            [System.IO.File]::Exists($DstPath) | Should -BeFalse
        }
    }

    Context 'Disambiguation' {
        It 'same name different URLs get different URL contexts' {
            $Ctx1 = Get-UrlLocationContext -Url 'https://cdn/obrazki/miasta/dark-forest.png'
            $Ctx2 = Get-UrlLocationContext -Url 'https://cdn/obrazki/miasta/light-meadow.png'
            $Ctx1 | Should -Not -Be $Ctx2
        }
    }

    Context 'ConvertFrom-MargoWorldMap' {
        It 'parses coordinates from sample HTML with 2 entries' {
            $Html = @'
<div class="world-map">
<a href="/world/view/1/ithan" data-tip="Ithan" style="left: 64px; top: 96px; width: 32px; height: 32px;"></a>
<a href="/world/view/200/targowisko" data-tip="Targowisko" style="left: 128px; top: 160px; width: 32px; height: 32px;"></a>
</div>
'@
            $Result = ConvertFrom-MargoWorldMap -Html $Html
            $Result.Count | Should -Be 2
            $Result[0].Id | Should -Be 1
            $Result[0].Name | Should -Be 'Ithan'
            $Result[1].Id | Should -Be 200
            $Result[1].Name | Should -Be 'Targowisko'
        }

        It 'converts pixels to tiles with default padding (floor(64/32)+7=9)' {
            $Html = '<a href="/world/view/1/ithan" data-tip="Ithan" style="left: 64px; top: 96px; width: 32px; height: 32px;"></a>'
            $Result = ConvertFrom-MargoWorldMap -Html $Html
            $Result.Count | Should -Be 1
            $Result[0].TileX | Should -Be 9     # floor(64/32) + 7 = 2 + 7
            $Result[0].TileY | Should -Be 10    # floor(96/32) + 7 = 3 + 7
        }

        It 'handles fractional pixel values (floor(382.33/32)+7=18)' {
            $Html = '<a href="/world/view/5/test" data-tip="Test" style="left: 382.33px; top: 100.7px; width: 32px; height: 32px;"></a>'
            $Result = ConvertFrom-MargoWorldMap -Html $Html
            $Result.Count | Should -Be 1
            $Result[0].TileX | Should -Be 18    # floor(382.33/32) + 7 = 11 + 7
            $Result[0].TileY | Should -Be 10    # floor(100.7/32)  + 7 = 3 + 7
        }

        It 'supports custom padding override (padding=0)' {
            $Html = '<a href="/world/view/1/ithan" data-tip="Ithan" style="left: 64px; top: 96px; width: 32px; height: 32px;"></a>'
            $Result = ConvertFrom-MargoWorldMap -Html $Html -Padding 0
            $Result[0].TileX | Should -Be 2     # floor(64/32) + 0
            $Result[0].TileY | Should -Be 3     # floor(96/32) + 0
        }

        It 'returns empty list for empty HTML' {
            $Result = ConvertFrom-MargoWorldMap -Html ''
            $Result.Count | Should -Be 0
        }

        It 'decodes HTML-encoded data-tip names' {
            $Html = '<a href="/world/view/7/gory" data-tip="G&oacute;ry &amp; Lasy" style="left: 32px; top: 32px; width: 32px; height: 32px;"></a>'
            $Result = ConvertFrom-MargoWorldMap -Html $Html
            $Result.Count | Should -Be 1
            $Result[0].Name | Should -Be 'Góry & Lasy'
        }
    }

    Context 'ConvertFrom-PngHeaderBytes' {
        # Helper to build a minimal PNG header (24 bytes: 8 signature + 4 IHDR length + 4 IHDR type + 4 width + 4 height)
        BeforeAll {
            function New-PngHeader {
                param([int]$Width, [int]$Height)
                # PNG signature: 89 50 4E 47 0D 0A 1A 0A
                $Sig = [byte[]]@(0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A)
                # IHDR chunk length (13 bytes): 00 00 00 0D
                $Len = [byte[]]@(0x00, 0x00, 0x00, 0x0D)
                # IHDR chunk type: 49 48 44 52
                $Type = [byte[]]@(0x49, 0x48, 0x44, 0x52)
                # Width (big-endian uint32)
                $W = [byte[]]@(
                    [byte](($Width -shr 24) -band 0xFF),
                    [byte](($Width -shr 16) -band 0xFF),
                    [byte](($Width -shr 8)  -band 0xFF),
                    [byte]($Width -band 0xFF))
                # Height (big-endian uint32)
                $H = [byte[]]@(
                    [byte](($Height -shr 24) -band 0xFF),
                    [byte](($Height -shr 16) -band 0xFF),
                    [byte](($Height -shr 8)  -band 0xFF),
                    [byte]($Height -band 0xFF))
                return $Sig + $Len + $Type + $W + $H
            }
        }

        It '640x480 PNG yields 20x15 tiles (default 32px)' {
            $Bytes = New-PngHeader -Width 640 -Height 480
            $Result = ConvertFrom-PngHeaderBytes -Bytes $Bytes
            $Result | Should -Not -BeNullOrEmpty
            $Result.WidthPx | Should -Be 640
            $Result.HeightPx | Should -Be 480
            $Result.TileWidth | Should -Be 20
            $Result.TileHeight | Should -Be 15
        }

        It '1024x1024 PNG yields 32x32 tiles' {
            $Bytes = New-PngHeader -Width 1024 -Height 1024
            $Result = ConvertFrom-PngHeaderBytes -Bytes $Bytes
            $Result | Should -Not -BeNullOrEmpty
            $Result.TileWidth | Should -Be 32
            $Result.TileHeight | Should -Be 32
        }

        It 'rejects non-PNG signature (returns null)' {
            $Bytes = [byte[]]::new(24)  # all zeros
            $Result = ConvertFrom-PngHeaderBytes -Bytes $Bytes
            $Result | Should -BeNullOrEmpty
        }

        It 'rejects insufficient bytes (returns null)' {
            # Only 16 bytes — not enough for IHDR width/height
            $Bytes = [byte[]]@(0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
                               0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52)
            $Result = ConvertFrom-PngHeaderBytes -Bytes $Bytes
            $Result | Should -BeNullOrEmpty
        }

        It '640x480 PNG with custom tile size 16px yields 40x30 tiles' {
            $Bytes = New-PngHeader -Width 640 -Height 480
            $Result = ConvertFrom-PngHeaderBytes -Bytes $Bytes -TileSize 16
            $Result | Should -Not -BeNullOrEmpty
            $Result.TileWidth | Should -Be 40
            $Result.TileHeight | Should -Be 30
        }
    }

    Context 'Close-TemporalTag' {
        It 'closes open-ended temporal suffix (2020-01:) with ValidTo' {
            $Line = '    - @koordynaty: 10, 5 (2020-01:)'
            $Result = Close-TemporalTag -Line $Line -ValidTo '2024-06'
            $Result | Should -Be '    - @koordynaty: 10, 5 (2020-01:2024-06)'
        }

        It 'adds ValidTo to tag without temporal suffix' {
            $Line = '    - @koordynaty: 10, 5'
            $Result = Close-TemporalTag -Line $Line -ValidTo '2024-06'
            $Result | Should -Be '    - @koordynaty: 10, 5 (:2024-06)'
        }

        It 'does not modify already-closed temporal tag' {
            $Line = '    - @koordynaty: 10, 5 (2020-01:2023-12)'
            $Result = Close-TemporalTag -Line $Line -ValidTo '2024-06'
            $Result | Should -Be '    - @koordynaty: 10, 5 (2020-01:2023-12)'
        }
    }
}
