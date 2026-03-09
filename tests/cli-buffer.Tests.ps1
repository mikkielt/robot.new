<#
    .SYNOPSIS
    Tests for cli-buffer.ps1 — virtual buffer and diff-based rendering.

    .DESCRIPTION
    Validates buffer creation, line setting, segment comparison,
    snapshot/restore, and segment builder helpers. Uses Pattern C
    (standalone helper dot-sourcing).

    Tests only the data layer — no actual terminal rendering is validated.
#>

BeforeAll {
    . "$PSScriptRoot/TestHelpers.ps1"

    # Dot-source dependencies in order
    . "$script:ModuleRoot/private/cli/cli-primitives.ps1"
    . "$script:ModuleRoot/private/cli/engine/cli-engine.ps1"
    . "$script:ModuleRoot/private/cli/engine/cli-buffer.ps1"

    # Set up known screen dimensions
    $script:ScreenWidth  = 80
    $script:ScreenHeight = 24
    Build-Regions
}

Describe 'New-ScreenBuffer' {

    It 'creates buffer with specified height' {
        $Buffer = New-ScreenBuffer -Height 10
        $Buffer.Count | Should -Be 10
    }

    It 'initializes all lines as empty arrays' {
        $Buffer = New-ScreenBuffer -Height 5
        for ($I = 0; $I -lt 5; $I++) {
            $Buffer[$I] | Should -HaveCount 0
        }
    }

    It 'creates independent line arrays' {
        $Buffer = New-ScreenBuffer -Height 3
        $Buffer[0] = @(@{ Text = 'A'; Color = $null; Bold = $false })
        $Buffer[1].Count | Should -Be 0
    }
}

Describe 'Set-BufferLine' {

    It 'sets segments at specified row' {
        $Buffer = New-ScreenBuffer -Height 5
        $Segments = @(
            @{ Text = 'Hello'; Color = 'Cyan'; Bold = $true }
            @{ Text = ' World'; Color = 'White'; Bold = $false }
        )
        Set-BufferLine -Buffer $Buffer -Row 2 -Segments $Segments
        $Buffer[2].Count | Should -Be 2
        $Buffer[2][0].Text | Should -Be 'Hello'
        $Buffer[2][1].Text | Should -Be ' World'
    }

    It 'does not modify other rows' {
        $Buffer = New-ScreenBuffer -Height 5
        $Segments = @(@{ Text = 'X'; Color = $null; Bold = $false })
        Set-BufferLine -Buffer $Buffer -Row 3 -Segments $Segments
        $Buffer[0].Count | Should -Be 0
        $Buffer[1].Count | Should -Be 0
        $Buffer[2].Count | Should -Be 0
        $Buffer[4].Count | Should -Be 0
    }

    It 'ignores out-of-bounds row (negative)' {
        $Buffer = New-ScreenBuffer -Height 3
        { Set-BufferLine -Buffer $Buffer -Row -1 -Segments @() } | Should -Not -Throw
    }

    It 'ignores out-of-bounds row (too large)' {
        $Buffer = New-ScreenBuffer -Height 3
        { Set-BufferLine -Buffer $Buffer -Row 10 -Segments @() } | Should -Not -Throw
    }
}

Describe 'Compare-BufferLine' {

    It 'returns true for identical lines' {
        $A = @(@{ Text = 'Hello'; Color = 'Cyan'; Bold = $true })
        $B = @(@{ Text = 'Hello'; Color = 'Cyan'; Bold = $true })
        Compare-BufferLine -LineA $A -LineB $B | Should -BeTrue
    }

    It 'returns true for two empty lines' {
        Compare-BufferLine -LineA @() -LineB @() | Should -BeTrue
    }

    It 'returns true for two null lines' {
        Compare-BufferLine -LineA $null -LineB $null | Should -BeTrue
    }

    It 'returns false when text differs' {
        $A = @(@{ Text = 'Hello'; Color = 'Cyan'; Bold = $false })
        $B = @(@{ Text = 'World'; Color = 'Cyan'; Bold = $false })
        Compare-BufferLine -LineA $A -LineB $B | Should -BeFalse
    }

    It 'returns false when color differs' {
        $A = @(@{ Text = 'Hello'; Color = 'Cyan'; Bold = $false })
        $B = @(@{ Text = 'Hello'; Color = 'White'; Bold = $false })
        Compare-BufferLine -LineA $A -LineB $B | Should -BeFalse
    }

    It 'returns false when bold differs' {
        $A = @(@{ Text = 'Hello'; Color = 'Cyan'; Bold = $true })
        $B = @(@{ Text = 'Hello'; Color = 'Cyan'; Bold = $false })
        Compare-BufferLine -LineA $A -LineB $B | Should -BeFalse
    }

    It 'returns false when segment count differs' {
        $A = @(@{ Text = 'A'; Color = $null; Bold = $false })
        $B = @(
            @{ Text = 'A'; Color = $null; Bold = $false }
            @{ Text = 'B'; Color = $null; Bold = $false }
        )
        Compare-BufferLine -LineA $A -LineB $B | Should -BeFalse
    }

    It 'handles multi-segment comparison' {
        $A = @(
            @{ Text = 'A'; Color = 'Cyan'; Bold = $true }
            @{ Text = 'B'; Color = 'White'; Bold = $false }
        )
        $B = @(
            @{ Text = 'A'; Color = 'Cyan'; Bold = $true }
            @{ Text = 'B'; Color = 'White'; Bold = $false }
        )
        Compare-BufferLine -LineA $A -LineB $B | Should -BeTrue
    }
}

Describe 'Clear-BufferRegion' {

    It 'clears lines within region boundaries' {
        $Buffer = New-ScreenBuffer -Height 10
        Set-BufferLine -Buffer $Buffer -Row 3 -Segments @(@{ Text = 'X'; Color = $null; Bold = $false })
        Set-BufferLine -Buffer $Buffer -Row 4 -Segments @(@{ Text = 'Y'; Color = $null; Bold = $false })

        $Region = [PSCustomObject]@{ StartRow = 3; EndRow = 6 }
        Clear-BufferRegion -Buffer $Buffer -Region $Region

        $Buffer[3].Count | Should -Be 0
        $Buffer[4].Count | Should -Be 0
        $Buffer[5].Count | Should -Be 0
    }

    It 'does not clear lines outside region' {
        $Buffer = New-ScreenBuffer -Height 10
        Set-BufferLine -Buffer $Buffer -Row 2 -Segments @(@{ Text = 'Keep'; Color = $null; Bold = $false })
        Set-BufferLine -Buffer $Buffer -Row 6 -Segments @(@{ Text = 'Keep'; Color = $null; Bold = $false })

        $Region = [PSCustomObject]@{ StartRow = 3; EndRow = 6 }
        Clear-BufferRegion -Buffer $Buffer -Region $Region

        $Buffer[2].Count | Should -Be 1
        $Buffer[6].Count | Should -Be 1
    }
}

Describe 'Snapshot-Region and Restore-Region' {

    It 'captures and restores region content' {
        $Buffer = New-ScreenBuffer -Height 10
        Set-BufferLine -Buffer $Buffer -Row 3 -Segments @(@{ Text = 'Hello'; Color = 'Cyan'; Bold = $true })
        Set-BufferLine -Buffer $Buffer -Row 4 -Segments @(@{ Text = 'World'; Color = 'White'; Bold = $false })

        $Region = [PSCustomObject]@{ Name = 'Test'; StartRow = 3; EndRow = 6; Width = 80 }

        $Snapshot = Snapshot-Region -Buffer $Buffer -Region $Region
        $Snapshot | Should -Not -BeNullOrEmpty
        $Snapshot.StartRow | Should -Be 3
        $Snapshot.Lines.Count | Should -Be 3

        # Overwrite buffer
        Clear-BufferRegion -Buffer $Buffer -Region $Region
        $Buffer[3].Count | Should -Be 0

        # Restore
        Restore-Region -Buffer $Buffer -Snapshot $Snapshot
        $Buffer[3].Count | Should -Be 1
        $Buffer[3][0].Text | Should -Be 'Hello'
        $Buffer[4][0].Text | Should -Be 'World'
    }
}

Describe 'New-Segment' {

    It 'creates segment with all properties' {
        $Seg = New-Segment -Text 'Test' -Color 'Cyan' -Bold
        $Seg.Text  | Should -Be 'Test'
        $Seg.Color | Should -Be 'Cyan'
        $Seg.Bold  | Should -BeTrue
    }

    It 'creates segment without bold' {
        $Seg = New-Segment -Text 'Test' -Color 'White'
        $Seg.Bold | Should -BeFalse
    }

    It 'creates segment without color' {
        $Seg = New-Segment -Text 'Plain'
        $Seg.Color | Should -BeNullOrEmpty
    }

    It 'creates segment with Dim flag' {
        $Seg = New-Segment -Text 'Dimmed' -Color 'DarkGray' -Dim
        $Seg.Dim | Should -BeTrue
        $Seg.Bold | Should -BeFalse
    }

    It 'defaults Dim to false' {
        $Seg = New-Segment -Text 'Normal'
        $Seg.Dim | Should -BeFalse
    }

    It 'accepts empty string' {
        $Seg = New-Segment -Text '' -Color 'Cyan'
        $Seg.Text | Should -Be ''
        $Seg.Color | Should -Be 'Cyan'
    }

    It 'supports both Bold and Dim simultaneously' {
        $Seg = New-Segment -Text 'BoldDim' -Color 'Cyan' -Bold -Dim
        $Seg.Bold | Should -BeTrue
        $Seg.Dim | Should -BeTrue
    }
}

Describe 'Compare-BufferLine — Dim property' {

    It 'returns false when Dim differs' {
        $A = @(@{ Text = 'X'; Color = 'DarkGray'; Bold = $false; Dim = $true })
        $B = @(@{ Text = 'X'; Color = 'DarkGray'; Bold = $false; Dim = $false })
        Compare-BufferLine -LineA $A -LineB $B | Should -BeFalse
    }

    It 'returns true when Dim matches' {
        $A = @(@{ Text = 'X'; Color = 'DarkGray'; Bold = $false; Dim = $true })
        $B = @(@{ Text = 'X'; Color = 'DarkGray'; Bold = $false; Dim = $true })
        Compare-BufferLine -LineA $A -LineB $B | Should -BeTrue
    }
}

Describe 'New-PaddedLine' {

    It 'pads short line to target width' {
        $Segs = @(@{ Text = 'Hi'; Color = $null; Bold = $false })
        $Result = New-PaddedLine -Segments $Segs -Width 10
        $TotalLen = 0
        foreach ($S in $Result) { $TotalLen += $S.Text.Length }
        $TotalLen | Should -Be 10
    }

    It 'does not add padding when line equals target width' {
        $Segs = @(@{ Text = 'X' * 10; Color = $null; Bold = $false })
        $Result = @(New-PaddedLine -Segments $Segs -Width 10)
        # Should return 1 segment (no padding added)
        $Result.Count | Should -Be 1
        $Result[0].Text | Should -Be ('X' * 10)
    }
}

Describe 'Initialize-Buffers' {

    It 'creates front and back buffers of screen height' {
        $script:ScreenHeight = 20
        Initialize-Buffers
        $script:FrontBuffer.Count | Should -Be 20
        $script:BackBuffer.Count  | Should -Be 20
    }
}
