<#
    .SYNOPSIS
    Verifies that every line in templates/gitignore.required appears
    literally in the module's .gitignore, and that no negative pattern
    (`!...`) un-ignores a protected path.

    .DESCRIPTION
    Returns @{ Ok = $true } on success or
    @{ Ok = $false; Missing = @(...); Unignored = @(...) } on failure.

    The mtime cache means steady-state callers pay one File.GetLastWriteTimeUtc
    call (~microseconds). Pass -ForceRefresh to bypass.

    Resolves the module root from $script:ModuleRoot (set by
    Robot.PowerShell.psm1 in Phase 2) or via a fallback walk from
    $PSScriptRoot — so the helper works during module-load tests too.
#>

$script:GitignoreCache = $null

function Test-GitignoreIntegrity {
    [CmdletBinding()] param(
        [string]$ModuleRoot,
        [switch]$ForceRefresh
    )

    if (-not $ModuleRoot) {
        $ModuleRoot = if ($script:ModuleRoot) {
            $script:ModuleRoot
        } else {
            # Fallback: walk up from this file's dir (private/admin → module root)
            [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, '..', '..'))
        }
    }

    $GitignoreF = [System.IO.Path]::Combine($ModuleRoot, '.gitignore')
    $RequiredF  = [System.IO.Path]::Combine($ModuleRoot, 'templates', 'gitignore.required')

    if (-not [System.IO.File]::Exists($GitignoreF)) {
        return @{ Ok = $false; Missing = @('(.gitignore file is absent)'); Unignored = @() }
    }
    if (-not [System.IO.File]::Exists($RequiredF)) {
        # No requirements file shipped — nothing to enforce
        return @{ Ok = $true; Missing = @(); Unignored = @() }
    }

    # mtime cache — re-read only when .gitignore changes
    $Mtime = [System.IO.File]::GetLastWriteTimeUtc($GitignoreF).Ticks
    if (-not $ForceRefresh -and $script:GitignoreCache -and
        $script:GitignoreCache.Mtime -eq $Mtime -and
        $script:GitignoreCache.Path -eq $GitignoreF) {
        return $script:GitignoreCache.Result
    }

    $Required = @([System.IO.File]::ReadAllLines($RequiredF) |
        Where-Object { $_ -notmatch '^\s*(#|$)' } |
        ForEach-Object { $_.Trim() })

    $Live = @([System.IO.File]::ReadAllLines($GitignoreF) |
        ForEach-Object { $_.Trim() })

    $LiveSet = [System.Collections.Generic.HashSet[string]]::new(
        [string[]]$Live, [System.StringComparer]::Ordinal)

    $Missing = @($Required | Where-Object { -not $LiveSet.Contains($_) })

    # Negative-pattern check: a `!...` line in .gitignore that un-ignores
    # any path covered by a required rule is a hidden bypass.
    $Unignored = @()
    foreach ($L in $Live) {
        if ($L -notmatch '^\s*!') { continue }
        $Bare = $L.TrimStart('!').Trim()
        foreach ($R in $Required) {
            # Strip leading **/ and trailing / for prefix comparison
            $RBare = $R.TrimEnd('/').Replace('**/', '')
            if ($Bare -like "$RBare*" -or $RBare -like "$Bare*") {
                $Unignored += $L
                break
            }
        }
    }

    $Result = @{
        Ok        = ($Missing.Count -eq 0 -and $Unignored.Count -eq 0)
        Missing   = $Missing
        Unignored = $Unignored
    }
    $script:GitignoreCache = @{ Mtime = $Mtime; Path = $GitignoreF; Result = $Result }
    return $Result
}
