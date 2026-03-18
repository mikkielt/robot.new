<#
    .SYNOPSIS
    Registers tab-completion for -Name parameters on entity, player, and
    session functions using fuzzy name resolution.

    .DESCRIPTION
    Dot-sourced during module import (robot.psm1). Registers
    Register-ArgumentCompleter for frequently used functions so that
    pressing Tab on -Name auto-suggests matching entities, players,
    or narrators via Resolve-Name with fuzzy matching.

    Entity completers use Get-Entity cached results when available,
    falling back to Resolve-Name for fuzzy matches. Player completers
    use Get-Player. Session-related completers use Resolve-Narrator.
#>

# ── Entity name completer ─────────────────────────────────────────
$EntityNameCompleter = {
    param($CommandName, $ParameterName, $WordToComplete, $CommandAst, $FakeBoundParameters)

    if (-not $WordToComplete) { return }

    # Try exact prefix match from cached entities first (fast path)
    try {
        $Entities = @(Get-Entity -Quiet)
        $Matches = @($Entities.Where({
            $_.Name -like "$WordToComplete*" -or $_.CN -like "$WordToComplete*"
        }))
        if ($Matches.Count -gt 20) { $Matches = $Matches[0..19] }

        if ($Matches.Count -gt 0) {
            foreach ($M in $Matches) {
                [System.Management.Automation.CompletionResult]::new(
                    $M.Name, $M.Name,
                    [System.Management.Automation.CompletionResultType]::ParameterValue,
                    "$($M.Type) - $($M.Status)")
            }
            return
        }
    } catch { }

    # Fuzzy fallback via Resolve-Name
    try {
        $Resolved = Resolve-Name -Query $WordToComplete -Quiet -MaxDistance 2
        if ($Resolved) {
            [System.Management.Automation.CompletionResult]::new(
                $Resolved.Name, $Resolved.Name,
                [System.Management.Automation.CompletionResultType]::ParameterValue,
                "Resolved: $($Resolved.MatchType)")
        }
    } catch { }
}

$EntityFunctions = @(
    'Get-Entity', 'Set-Entity', 'Remove-Entity',
    'Get-EntityState', 'Get-EntityDelta',
    'Set-CurrencyEntity'
)
foreach ($FuncName in $EntityFunctions) {
    Register-ArgumentCompleter -CommandName $FuncName -ParameterName 'Name' `
        -ScriptBlock $EntityNameCompleter
}

# ── Player name completer ─────────────────────────────────────────
$PlayerNameCompleter = {
    param($CommandName, $ParameterName, $WordToComplete, $CommandAst, $FakeBoundParameters)

    if (-not $WordToComplete) { return }

    try {
        $Players = @(Get-Player)
        $Matches = @($Players.Where({
            $_.Name -like "$WordToComplete*"
        }))
        if ($Matches.Count -gt 20) { $Matches = $Matches[0..19] }

        foreach ($P in $Matches) {
            $Chars = @($P.Characters).ForEach({ $_.Name }) -join ', '
            [System.Management.Automation.CompletionResult]::new(
                $P.Name, $P.Name,
                [System.Management.Automation.CompletionResultType]::ParameterValue,
                "Postacie: $Chars")
        }
    } catch { }
}

$PlayerFunctions = @('Get-Player', 'New-PlayerCharacter')
foreach ($FuncName in $PlayerFunctions) {
    Register-ArgumentCompleter -CommandName $FuncName -ParameterName 'Name' `
        -ScriptBlock $PlayerNameCompleter
}

# Register PlayerName param too (used by New-PlayerCharacter)
Register-ArgumentCompleter -CommandName 'New-PlayerCharacter' -ParameterName 'PlayerName' `
    -ScriptBlock $PlayerNameCompleter
