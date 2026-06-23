<#
    .SYNOPSIS
    Resolves a Margonem user_id integer to a Robot Player object.

    .DESCRIPTION
    Margonem-authenticated requests arrive with a verified integer user_id
    (from POST /auth/margonem). This helper maps that id to the Robot
    Player whose Gracze.md section declares the matching "ID Margonem:"
    line (surfaced by Get-Player as the .MargonemID string property).

    Behavior:
      - Status-agnostic. A player marked @status: Usunięty still resolves —
        revocation is via the @margonemid tag removal or DELETE
        /auth/sessions/:player, not via status.
      - Ambiguity (two players sharing the same id) is a data error and
        throws a terminating AmbiguousMargonemUserId — fail closed to
        avoid issuing a token bound to the wrong player.
      - O(1) per call after a one-time O(N) Dictionary<long,Player>
        build. The index is invalidated whenever the API server's
        CacheVersion advances (matches the existing parse-cache pattern).

    The compiled C# type Robot.ApiServer is optional — when absent
    (CLI-only contexts, tests without the API), CacheVersion is treated
    as 0 and the index is rebuilt only on the first call per process.
#>

# Module-scoped index — rebuilt on CacheVersion change
$script:MargonemUserIndex        = $null
$script:MargonemUserIndexVersion = -1

function Resolve-MargonemUser {
    [CmdletBinding()] param(
        [Parameter(Mandatory)] [long]$UserId
    )

    # Cache coherence: rebuild when the API server's CacheVersion advances
    $CurrentVersion = 0L
    if (([System.Management.Automation.PSTypeName]'Robot.ApiServer').Type) {
        $CurrentVersion = [long][Robot.ApiServer]::CacheVersion
    }

    if ($null -eq $script:MargonemUserIndex -or
        $script:MargonemUserIndexVersion -ne $CurrentVersion) {

        $Index     = [System.Collections.Generic.Dictionary[long, object]]::new()
        $Ambiguous = [System.Collections.Generic.HashSet[long]]::new()

        foreach ($P in (Get-Player)) {
            if (-not $P.MargonemID) { continue }
            $Raw = [string]$P.MargonemID
            $Id  = 0L
            if (-not [long]::TryParse($Raw, [ref]$Id)) {
                Write-RobotWarning "[Resolve-MargonemUser] Player '$($P.Name)' has non-integer MargonemID: '$Raw' — skipped"
                continue
            }
            if ($Index.ContainsKey($Id)) {
                [void]$Ambiguous.Add($Id)
            } else {
                $Index[$Id] = $P
            }
        }

        $script:MargonemUserIndex        = @{ Map = $Index; Ambiguous = $Ambiguous }
        $script:MargonemUserIndexVersion = $CurrentVersion
    }

    if ($script:MargonemUserIndex.Ambiguous.Contains($UserId)) {
        $PSCmdlet.ThrowTerminatingError(
            [System.Management.Automation.ErrorRecord]::new(
                [System.InvalidOperationException]::new(
                    "Margonem user_id $UserId maps to multiple players — fix MargonemID uniqueness in Gracze.md"),
                'AmbiguousMargonemUserId',
                [System.Management.Automation.ErrorCategory]::InvalidData,
                $UserId))
    }

    $Found = $null
    [void]$script:MargonemUserIndex.Map.TryGetValue($UserId, [ref]$Found)
    return $Found
}
