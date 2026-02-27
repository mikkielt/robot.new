<#
    .SYNOPSIS
    Shared markdown rendering helpers for session metadata blocks.

    .DESCRIPTION
    Non-exported helper functions consumed by New-Session and Set-Session via
    dot-sourcing. Not auto-loaded by robot.psm1 (non-Verb-Noun filename).

    Contains:
    - ConvertTo-Gen4MetadataBlock: renders a single Gen4 @-prefixed metadata block
    - ConvertTo-SessionMetadata: renders all metadata blocks in canonical order
#>

# Helper: renders a single Gen4 @-prefixed metadata block as a multi-line markdown string.
# Returns $null if $Items is empty or $null.
function ConvertTo-Gen4MetadataBlock {
    param(
        [string]$Tag,
        [object[]]$Items,
        [string]$NL = [System.Environment]::NewLine
    )

    if ($null -eq $Items -or $Items.Count -eq 0) { return $null }

    $SB = [System.Text.StringBuilder]::new(256)

    [void]$SB.Append("- @${Tag}:")

    switch ($Tag) {
        'Lokacje' {
            foreach ($Loc in $Items) {
                [void]$SB.Append($NL)
                [void]$SB.Append("    - $Loc")
            }
        }
        'Logi' {
            foreach ($Url in $Items) {
                [void]$SB.Append($NL)
                [void]$SB.Append("    - $Url")
            }
        }
        'PU' {
            foreach ($Entry in $Items) {
                [void]$SB.Append($NL)
                if ($null -ne $Entry.Value) {
                    $Formatted = ([decimal]$Entry.Value).ToString('G', [System.Globalization.CultureInfo]::InvariantCulture)
                    [void]$SB.Append("    - $($Entry.Character): $Formatted")
                } else {
                    [void]$SB.Append("    - $($Entry.Character):")
                }
            }
        }
        'Zmiany' {
            foreach ($Change in $Items) {
                [void]$SB.Append($NL)
                [void]$SB.Append("    - $($Change.EntityName)")
                if ($Change.Tags) {
                    foreach ($T in $Change.Tags) {
                        [void]$SB.Append($NL)
                        $TagName = if ($T.Tag.StartsWith('@')) { $T.Tag } else { "@$($T.Tag)" }
                        [void]$SB.Append("        - ${TagName}: $($T.Value)")
                    }
                }
            }
        }
        'Intel' {
            foreach ($Entry in $Items) {
                [void]$SB.Append($NL)
                [void]$SB.Append("    - $($Entry.RawTarget): $($Entry.Message)")
            }
        }
    }

    return $SB.ToString()
}

# Helper: renders all metadata blocks in canonical Gen4 order.
# Skips blocks where the value is $null. Returns a single multi-line string,
# or empty string if all blocks are empty.
function ConvertTo-SessionMetadata {
    param(
        [object]$Locations,
        [object]$Logs,
        [object]$PU,
        [object]$Changes,
        [object]$Intel,
        [string]$NL = [System.Environment]::NewLine
    )

    $Blocks = [System.Collections.Generic.List[string]]::new(5)

    $LocBlock = ConvertTo-Gen4MetadataBlock -Tag 'Lokacje' -Items $Locations -NL $NL
    if ($LocBlock) { $Blocks.Add($LocBlock) }

    $LogBlock = ConvertTo-Gen4MetadataBlock -Tag 'Logi' -Items $Logs -NL $NL
    if ($LogBlock) { $Blocks.Add($LogBlock) }

    $PUBlock = ConvertTo-Gen4MetadataBlock -Tag 'PU' -Items $PU -NL $NL
    if ($PUBlock) { $Blocks.Add($PUBlock) }

    $ZmianyBlock = ConvertTo-Gen4MetadataBlock -Tag 'Zmiany' -Items $Changes -NL $NL
    if ($ZmianyBlock) { $Blocks.Add($ZmianyBlock) }

    $IntelBlock = ConvertTo-Gen4MetadataBlock -Tag 'Intel' -Items $Intel -NL $NL
    if ($IntelBlock) { $Blocks.Add($IntelBlock) }

    if ($Blocks.Count -eq 0) { return '' }

    return [string]::Join($NL, $Blocks)
}
