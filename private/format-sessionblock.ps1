<#
    .SYNOPSIS
    Shared markdown rendering helpers for session metadata blocks.

    .DESCRIPTION
    Non-exported helper functions consumed by New-Session and Set-Session via
    dot-sourcing. Not auto-loaded by Robot.PowerShell.psm1 (non-Verb-Noun filename).

    Helpers:
    - ConvertTo-Gen4MetadataBlock: renders a single Gen4 @-prefixed metadata block
    - ConvertTo-SessionMetadata:   renders all metadata blocks in canonical order

    ConvertTo-Gen4MetadataBlock handles the tag-specific formatting rules for
    each Gen4 metadata tag. Most tags render as nested bullets under a "- @Tag:"
    header, but @Data with a single value renders inline ("- @Data: 2024-01-15")
    and @PU entries format decimal values with InvariantCulture 'G' specifier.
    @Zmiany blocks support two-level nesting (entity name + tag children).

    ConvertTo-SessionMetadata orchestrates the canonical rendering order:
    @Narrator, @Data, @Lokacje, @Logi, @PU, @Zmiany, @Intel, @Transfer,
    @Pliki. Each block is rendered via ConvertTo-Gen4MetadataBlock and
    skipped when its input is $null or empty. @Pliki renders last because
    file paths are operational metadata, not session content. The blocks
    are joined with the caller-supplied newline style (NL parameter) to
    preserve the file's original line endings.

    Both functions use StringBuilder for efficient string assembly. The
    output is consumed directly by session file writers that splice it
    into the session section content.
#>

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
        'Narrator' {
            foreach ($Name in $Items) {
                [void]$SB.Append($NL)
                [void]$SB.Append("    - $Name")
            }
        }
        'Data' {
            # Single date renders inline; multiple dates use nested bullets
            if ($Items.Count -eq 1) {
                [void]$SB.Clear()
                [void]$SB.Append("- @Data: $($Items[0])")
            } else {
                foreach ($D in $Items) {
                    [void]$SB.Append($NL)
                    [void]$SB.Append("    - $D")
                }
            }
        }
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
        'Transfer' {
            foreach ($Entry in $Items) {
                [void]$SB.Append($NL)
                $Prefix = if ($Entry.Amount -gt 1) { "$($Entry.Amount) " } else { '' }
                [void]$SB.Append("    - $($Prefix)$($Entry.Denomination), $($Entry.Source) -> $($Entry.Destination)")
            }
        }
        'Pliki' {
            foreach ($Path in $Items) {
                [void]$SB.Append($NL)
                [void]$SB.Append("    - $Path")
            }
        }
    }

    return $SB.ToString()
}

function ConvertTo-SessionMetadata {
    param(
        [object]$Narrator,
        [object]$DateOverride,
        [object]$Locations,
        [object]$Logs,
        [object]$PU,
        [object]$Changes,
        [object]$Intel,
        [object]$Transfers,
        [object]$Files,
        [string]$NL = [System.Environment]::NewLine
    )

    $Blocks = [System.Collections.Generic.List[string]]::new(7)

    $NarrBlock = ConvertTo-Gen4MetadataBlock -Tag 'Narrator' -Items $Narrator -NL $NL
    if ($NarrBlock) { $Blocks.Add($NarrBlock) }

    $DataBlock = ConvertTo-Gen4MetadataBlock -Tag 'Data' -Items $DateOverride -NL $NL
    if ($DataBlock) { $Blocks.Add($DataBlock) }

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

    $TransferBlock = ConvertTo-Gen4MetadataBlock -Tag 'Transfer' -Items $Transfers -NL $NL
    if ($TransferBlock) { $Blocks.Add($TransferBlock) }

    $PlikiBlock = ConvertTo-Gen4MetadataBlock -Tag 'Pliki' -Items $Files -NL $NL
    if ($PlikiBlock) { $Blocks.Add($PlikiBlock) }

    if ($Blocks.Count -eq 0) { return '' }

    return [string]::Join($NL, $Blocks)
}
