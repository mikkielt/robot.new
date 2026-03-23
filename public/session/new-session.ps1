<#
    .SYNOPSIS
    Generates a Gen4-format session markdown string.

    .DESCRIPTION
    This file contains New-Session. It dot-sources format-sessionblock.ps1 for
    shared rendering helpers (ConvertTo-Gen4MetadataBlock, ConvertTo-SessionMetadata).

    New-Session builds a complete session section in Gen4 @-prefixed markdown format.
    Returns the string — does NOT write to disk. The caller decides where to place
    the output (pipe to Out-File, Add-Content, etc.).

    Assembly pipeline:
    1. Build the "### YYYY-MM-DD, Title, Narrator" header line, with optional
       multi-day suffix ("YYYY-MM-DD/DD") when DateEnd is provided.
    2. Delegate metadata rendering to ConvertTo-SessionMetadata, which serializes
       @Lokacje, @PU, @Logi, @Zmiany, @Intel, and @Narrator blocks.
    3. Assemble header + optional body + optional metadata via StringBuilder,
       separated by double newlines for Markdown paragraph spacing.

    The output is round-trip compatible with Get-Session -IncludeContent: parsing
    the returned string produces the same structured objects that were passed in.

    DateEnd is restricted to the same calendar month as Date because the session
    header format encodes multi-day ranges as "YYYY-MM-DD/DD" (day-only suffix).
#>

. "$script:ModuleRoot/private/format-sessionblock.ps1"

function New-Session {
    <#
        .SYNOPSIS
        Generates a Gen4-format session markdown string.
    #>

    [CmdletBinding()] param(
        [Parameter(Mandatory, HelpMessage = "Session date")]
        [ValidateNotNull()]
        [datetime]$Date,

        [Parameter(HelpMessage = "End date for multi-day sessions (same month as Date)")]
        [datetime]$DateEnd,

        [Parameter(Mandatory, HelpMessage = "Session title")]
        [ValidateNotNullOrEmpty()]
        [string]$Title,

        [Parameter(Mandatory, HelpMessage = "Narrator name for session header")]
        [ValidateNotNullOrEmpty()]
        [string]$Narrator,

        [Parameter(HelpMessage = "Canonical narrator names for @Narrator metadata (when different from header)")]
        [string[]]$MetadataNarrators,

        [Parameter(HelpMessage = "Location names for the session")]
        [string[]]$Locations,

        [Parameter(HelpMessage = "PU award entries (Character + Value)")]
        [object[]]$PU,

        [Parameter(HelpMessage = "Session log URLs")]
        [string[]]$Logs,

        [Parameter(HelpMessage = "Entity state changes (Zmiany entries)")]
        [object[]]$Changes,

        [Parameter(HelpMessage = "Intel targeting entries (RawTarget + Message)")]
        [object[]]$Intel,

        [Parameter(HelpMessage = "Transfer entries (Amount + Denomination + Source + Destination)")]
        [object[]]$Transfers,

        [Parameter(HelpMessage = "Free-form body text content")]
        [string]$Content
    )

    $NL = [System.Environment]::NewLine
    $DateStr = $Date.ToString('yyyy-MM-dd')

    if ($PSBoundParameters.ContainsKey('DateEnd')) {
        if ($DateEnd.Year -ne $Date.Year -or $DateEnd.Month -ne $Date.Month) {
            throw "DateEnd must be in the same month as Date. Date: $DateStr, DateEnd: $($DateEnd.ToString('yyyy-MM-dd'))"
        }
        if ($DateEnd -le $Date) {
            throw "DateEnd must be later than Date. Date: $DateStr, DateEnd: $($DateEnd.ToString('yyyy-MM-dd'))"
        }
        $DateStr += "/$($DateEnd.ToString('dd'))"
    }

    $Header = "### ${DateStr}, ${Title}, ${Narrator}"

    $Meta = ConvertTo-SessionMetadata `
        -Narrator   $MetadataNarrators `
        -Locations  $Locations `
        -Logs       $Logs `
        -PU         $PU `
        -Changes    $Changes `
        -Intel      $Intel `
        -Transfers  $Transfers `
        -NL         $NL

    # Assemble with double-newline separators for Markdown paragraph breaks
    $SB = [System.Text.StringBuilder]::new(512)  # typical session section fits in 512 chars
    [void]$SB.Append($Header)

    if (-not [string]::IsNullOrEmpty($Content)) {
        [void]$SB.Append($NL)
        [void]$SB.Append($NL)
        [void]$SB.Append($Content)
    }

    if ($Meta.Length -gt 0) {
        [void]$SB.Append($NL)
        [void]$SB.Append($NL)
        [void]$SB.Append($Meta)
    }

    return $SB.ToString()
}
