<#
    .SYNOPSIS
    Virtual buffer and diff-based rendering for the Robot CLI TUI engine.

    .DESCRIPTION
    Maintains two screen buffers (front and back). Each buffer is an array
    of lines, and each line is an array of styled segments. On each render
    cycle the engine builds the new frame into the back buffer, then diffs
    it against the front buffer to emit only changed rows.

    Segment structure:
        @{ Text = [string]; Color = [string]; Bold = [bool]; Dim = [bool] }

    Helpers:
    - New-ScreenBuffer:    creates empty buffer of N rows
    - Initialize-Buffers:  allocates front/back buffers and hash arrays from ScreenHeight
    - Clear-BufferRegion:  clears lines in a specific region
    - Set-BufferLine:      writes segments to a specific row, updates hash array
    - Compare-BufferLine:  compares two lines segment-by-segment
    - Render-BufferDiff:   diffs old vs new buffer, re-renders changed rows
    - Render-FullBuffer:   forces full re-render (used after terminal resize)
    - Render-Line:         outputs a single line's segments to the terminal
    - Render-Segment:      outputs a single segment (ANSI on PS7, Write-Host on PS5.1)
    - Snapshot-Region:     copies region lines for overlay save/restore
    - Restore-Region:      restores region from snapshot
    - New-Segment:         creates a segment hashtable with Text/Color/Bold/Dim
    - New-PaddedLine:      builds a segment array padded to terminal width

    Each line in the buffer is an array of segment hashtables. A null or
    empty array means "blank line" (filled with spaces on render).

    Module-level data:
    - $script:FrontBuffer:     currently displayed frame
    - $script:BackBuffer:      frame being assembled for next render
    - $script:FrontBufferHash: per-row XOR hash of front buffer (fast diff path)
    - $script:BackBufferHash:  per-row XOR hash of back buffer (fast diff path)
    - $script:BlankBuffer:     pre-allocated char[300] of spaces for zero-allocation padding
#>

# ── Module-level data ────────────────────────────────────────────────────────

$script:FrontBuffer     = $null
$script:BackBuffer      = $null
$script:FrontBufferHash = $null
$script:BackBufferHash  = $null

# Pre-allocated blank char buffer for zero-allocation padding in Render-Line.
# Covers terminal widths up to 300 columns; wider terminals fall back to string allocation.
$script:BlankBuffer = [char[]]::new(300)
for ($i = 0; $i -lt 300; $i++) { $script:BlankBuffer[$i] = ' ' }

# ── New-ScreenBuffer ─────────────────────────────────────────────────────────

function New-ScreenBuffer {
    param([Parameter(Mandatory)] [int]$Height)

    $Buffer = [object[]]::new($Height)
    for ($I = 0; $I -lt $Height; $I++) {
        $Buffer[$I] = @()
    }
    return $Buffer
}

# ── Initialize-Buffers ──────────────────────────────────────────────────────

function Initialize-Buffers {
    $H = $script:ScreenHeight
    $script:FrontBuffer     = New-ScreenBuffer -Height $H
    $script:BackBuffer      = New-ScreenBuffer -Height $H
    $script:FrontBufferHash = [int[]]::new($H)
    $script:BackBufferHash  = [int[]]::new($H)
}

# ── Clear-BufferRegion ───────────────────────────────────────────────────────

function Clear-BufferRegion {
    param(
        [Parameter(Mandatory)] [object[]]$Buffer,
        [Parameter(Mandatory)] [object]$Region
    )

    for ($I = $Region.StartRow; $I -lt $Region.EndRow; $I++) {
        if ($I -ge 0 -and $I -lt $Buffer.Count) {
            $Buffer[$I] = @()
        }
    }
}

# ── Set-BufferLine ───────────────────────────────────────────────────────────

function Set-BufferLine {
    param(
        [Parameter(Mandatory)] [object[]]$Buffer,
        [Parameter(Mandatory)] [int]$Row,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]]$Segments
    )

    if ($Row -ge 0 -and $Row -lt $Buffer.Count) {
        $Buffer[$Row] = $Segments

        # Update parallel hash array so Render-BufferDiff can skip unchanged rows
        # without segment-by-segment comparison. Uses pure XOR (no multiply/shift)
        # to stay within [int] range and avoid overflow on PS 5.1.
        if ($null -ne $script:BackBufferHash -and $Row -lt $script:BackBufferHash.Count) {
            [int]$Hash = $Segments.Count
            foreach ($Seg in $Segments) {
                if ($null -ne $Seg -and $Seg.Text) {
                    $Hash = $Hash -bxor $Seg.Text.GetHashCode()
                    if ($Seg.Color) { $Hash = $Hash -bxor $Seg.Color.GetHashCode() }
                    if ($Seg.Bold)  { $Hash = $Hash -bxor 0x1A2B3C4D }  # arbitrary sentinel — differentiates bold from non-bold segments
                    if ($Seg.Dim)   { $Hash = $Hash -bxor 0x5E6F7A8B }  # arbitrary sentinel — differentiates dim from non-dim segments
                }
            }
            $script:BackBufferHash[$Row] = $Hash
        }
    }
}

# ── Compare-BufferLine ───────────────────────────────────────────────────────

# Returns $true if lines are identical, $false if they differ
function Compare-BufferLine {
    param(
        [object[]]$LineA,
        [object[]]$LineB
    )

    if ($null -eq $LineA) { $LineA = @() }
    if ($null -eq $LineB) { $LineB = @() }

    if ($LineA.Count -ne $LineB.Count) { return $false }

    for ($I = 0; $I -lt $LineA.Count; $I++) {
        $A = $LineA[$I]
        $B = $LineB[$I]

        if ($A.Text -ne $B.Text) { return $false }
        if ($A.Color -ne $B.Color) { return $false }
        if ($A.Bold -ne $B.Bold) { return $false }
        if ($A.Dim -ne $B.Dim) { return $false }
    }

    return $true
}

# ── Render-Segment ───────────────────────────────────────────────────────────

function Render-Segment {
    param([Parameter(Mandatory)] [hashtable]$Segment)

    $Text  = $Segment.Text
    $Color = $Segment.Color
    $Bold  = $Segment.Bold
    $Dim   = $Segment.Dim

    if ($script:SupportsANSI) {
        # PS 7+: Use ANSI sequences for bold/dim
        $Prefix = ''
        $Suffix = ''
        if ($Bold) {
            $Prefix += "`e[1m"
            $Suffix = "`e[0m"
        }
        if ($Dim) {
            $Prefix += "`e[2m"
            $Suffix = "`e[0m"
        }
        if ($Color) {
            [System.Console]::Write($Prefix)
            Write-Host $Text -NoNewline -ForegroundColor $Color
            if ($Suffix) { [System.Console]::Write($Suffix) }
        } else {
            [System.Console]::Write("$Prefix$Text$Suffix")
        }
    } else {
        # PS 5.1 lacks ANSI support — use Write-Host with color only.
        # Simulate bold by promoting to Accent color, giving selected items
        # visual distinction even without true bold weight.
        $RenderColor = $Color
        $InfoColor = Get-CLIColor -Role 'Info'
        if ($Bold -and (-not $Color -or $Color -eq 'White' -or $Color -eq $InfoColor)) {
            $RenderColor = Get-CLIColor -Role 'Accent'
        }
        if ($RenderColor) {
            Write-Host $Text -NoNewline -ForegroundColor $RenderColor
        } else {
            Write-Host $Text -NoNewline
        }
    }
}

# ── Render-Line ──────────────────────────────────────────────────────────────

# Renders a full line at the given row. Pads to terminal width to overwrite old content.
function Render-Line {
    param(
        [Parameter(Mandatory)] [int]$Row,
        [object[]]$Segments
    )

    [System.Console]::SetCursorPosition(0, $Row)

    $Written = 0
    $Width = $script:ScreenWidth

    if ($null -eq $Segments -or $Segments.Count -eq 0) {
        # Blank line — clear the row (zero-allocation via pre-allocated char buffer)
        if ($Width -le 300) {
            [System.Console]::Out.Write($script:BlankBuffer, 0, $Width)
        } else {
            [System.Console]::Write(' ' * $Width)
        }
        return
    }

    foreach ($Seg in $Segments) {
        if ($null -eq $Seg) { continue }
        $SegText = $Seg.Text
        if ([string]::IsNullOrEmpty($SegText)) { continue }

        # Clamp to remaining width
        $Remaining = $Width - $Written
        if ($Remaining -le 0) { break }
        if ($SegText.Length -gt $Remaining) {
            $SegText = $SegText.Substring(0, $Remaining)
        }

        Render-Segment @{ Text = $SegText; Color = $Seg.Color; Bold = $Seg.Bold; Dim = $Seg.Dim }
        $Written += $SegText.Length
    }

    # Pad rest of line with spaces to clear old content (zero-allocation path)
    $Pad = $Width - $Written
    if ($Pad -gt 0) {
        if ($Pad -le 300) {
            [System.Console]::Out.Write($script:BlankBuffer, 0, $Pad)
        } else {
            [System.Console]::Write(' ' * $Pad)
        }
    }
}

# ── Render-BufferDiff ────────────────────────────────────────────────────────

# Compares back buffer against front buffer. Only re-renders rows that changed.
# After rendering, copies back buffer to front buffer.
function Render-BufferDiff {
    if ($null -eq $script:FrontBuffer -or $null -eq $script:BackBuffer) { return }

    $Height = [Math]::Min($script:FrontBuffer.Count, $script:BackBuffer.Count)
    $HasHash = ($null -ne $script:FrontBufferHash -and $null -ne $script:BackBufferHash)

    for ($Row = 0; $Row -lt $Height; $Row++) {
        $Changed = $false

        if ($HasHash) {
            if ($script:FrontBufferHash[$Row] -ne $script:BackBufferHash[$Row]) {
                # Hash mismatch — definitely changed, skip full comparison
                $Changed = $true
            } elseif ($script:FrontBufferHash[$Row] -eq 0 -and $script:BackBufferHash[$Row] -eq 0) {
                # Both empty/unset — skip
                continue
            } else {
                # Hash match — verify (hash collision possible)
                if (Compare-BufferLine -LineA $script:FrontBuffer[$Row] -LineB $script:BackBuffer[$Row]) {
                    continue
                }
                $Changed = $true
            }
        } else {
            $Changed = -not (Compare-BufferLine -LineA $script:FrontBuffer[$Row] -LineB $script:BackBuffer[$Row])
        }

        if ($Changed) {
            $NewLine = $script:BackBuffer[$Row]
            Render-Line -Row $Row -Segments $NewLine
            $script:FrontBuffer[$Row] = $NewLine
            if ($HasHash) { $script:FrontBufferHash[$Row] = $script:BackBufferHash[$Row] }
        }
    }
}

# ── Render-FullBuffer ────────────────────────────────────────────────────────

# Forces full re-render of the back buffer (used after resize)
function Render-FullBuffer {
    if ($null -eq $script:BackBuffer) { return }

    for ($Row = 0; $Row -lt $script:BackBuffer.Count; $Row++) {
        Render-Line -Row $Row -Segments $script:BackBuffer[$Row]
    }

    # Copy back to front (including hash arrays)
    for ($Row = 0; $Row -lt $script:BackBuffer.Count; $Row++) {
        $script:FrontBuffer[$Row] = $script:BackBuffer[$Row]
    }
    if ($null -ne $script:BackBufferHash -and $null -ne $script:FrontBufferHash) {
        [System.Array]::Copy($script:BackBufferHash, $script:FrontBufferHash, $script:BackBufferHash.Count)
    }
}

# ── Snapshot-Region ──────────────────────────────────────────────────────────

function Snapshot-Region {
    param(
        [Parameter(Mandatory)] [object[]]$Buffer,
        [Parameter(Mandatory)] [object]$Region
    )

    $Lines = [System.Collections.Generic.List[object]]::new()
    for ($I = $Region.StartRow; $I -lt $Region.EndRow; $I++) {
        if ($I -ge 0 -and $I -lt $Buffer.Count) {
            # Shallow copy of the segment array
            $LineCopy = @() + $Buffer[$I]
            [void]$Lines.Add($LineCopy)
        }
    }

    return [PSCustomObject]@{
        StartRow = $Region.StartRow
        EndRow   = $Region.EndRow
        Lines    = $Lines
    }
}

# ── Restore-Region ──────────────────────────────────────────────────────────

function Restore-Region {
    param(
        [Parameter(Mandatory)] [object[]]$Buffer,
        [Parameter(Mandatory)] [object]$Snapshot
    )

    $Idx = 0
    for ($I = $Snapshot.StartRow; $I -lt $Snapshot.EndRow; $I++) {
        if ($I -ge 0 -and $I -lt $Buffer.Count -and $Idx -lt $Snapshot.Lines.Count) {
            $Buffer[$I] = $Snapshot.Lines[$Idx]
            $Idx++
        }
    }
}

# ── Segment Builder Helpers ──────────────────────────────────────────────────

# Convenience function for creating a single segment
function New-Segment {
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string]$Text,
        [string]$Color,
        [switch]$Bold,
        [switch]$Dim
    )
    return @{
        Text  = $Text
        Color = $Color
        Bold  = [bool]$Bold
        Dim   = [bool]$Dim
    }
}

# Builds a line of segments that together form padded text at a given width
function New-PaddedLine {
    param(
        [Parameter(Mandatory)] [object[]]$Segments,
        [int]$Width = $script:ScreenWidth
    )

    # Calculate total text length
    $TotalLen = 0
    foreach ($Seg in $Segments) {
        if ($Seg -and $Seg.Text) { $TotalLen += $Seg.Text.Length }
    }

    # If under width, add padding segment
    $Pad = $Width - $TotalLen
    if ($Pad -gt 0) {
        $Result = @() + $Segments + @(@{ Text = ' ' * $Pad; Color = $null; Bold = $false })
        return $Result
    }

    return $Segments
}
