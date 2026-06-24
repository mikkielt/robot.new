<#
    .SYNOPSIS
    Pointer-only schema downgrade. Records the downgrade in history.
#>

function Reset-SchemaVersion {
    <#
        .SYNOPSIS
        Downgrades the schema version pointer to a prior entry from history.

        .DESCRIPTION
        Refuses if the target is not present in history[]. Does NOT run any
        migration script — this is a pointer-only operation, intended for
        recovery after a git revert. The downgrade is logged as a new history
        entry tagged 'schema-restore:<previous>-><target>'.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact='High')]
    param(
        [Parameter(Mandatory)] [string]$To,
        [string]$Reason,
        [string]$RepoRoot
    )

    $Schema = Get-SchemaVersion -RepoRoot $RepoRoot
    if (-not $Schema.Exists) {
        $Ex = [System.InvalidOperationException]::new("No schema.json exists; nothing to downgrade.")
        $Err = [System.Management.Automation.ErrorRecord]::new(
            $Ex, 'NoSchema',
            [System.Management.Automation.ErrorCategory]::ObjectNotFound, $null)
        $PSCmdlet.ThrowTerminatingError($Err)
    }
    $HistoryVersions = @($Schema.History | ForEach-Object { $_.version })
    if ($To -notin $HistoryVersions -and $To -ne $Schema.Current) {
        $Ex = [System.ArgumentException]::new(
            "Target version '$To' is not in history. Available: $($HistoryVersions -join ', ')")
        $Err = [System.Management.Automation.ErrorRecord]::new(
            $Ex, 'VersionNotInHistory',
            [System.Management.Automation.ErrorCategory]::InvalidArgument, $To)
        $PSCmdlet.ThrowTerminatingError($Err)
    }

    if ($To -eq $Schema.Current) {
        return [PSCustomObject]@{ OK = $true; From = $Schema.Current; To = $To; NoOp = $true }
    }

    if (-not $PSCmdlet.ShouldProcess($Schema.FilePath, "Restore schema pointer to '$To'")) {
        return
    }

    # Find the target entry to recover its majorName
    $TargetEntry = $Schema.History | Where-Object { $_.version -eq $To } | Select-Object -First 1
    $MajorName = if ($TargetEntry -and $TargetEntry.majorName) { $TargetEntry.majorName } else { '' }
    $RestoreId = "schema-restore:$($Schema.Current)->-$To"
    if ($Reason) { $RestoreId = "$RestoreId reason=`"$Reason`"" }

    Set-SchemaVersion -Version $To -MajorName $MajorName -MigrationId $RestoreId -RepoRoot $RepoRoot
    return [PSCustomObject]@{
        OK = $true; From = $Schema.Current; To = $To; NoOp = $false
        AppliedAt = [datetime]::UtcNow.ToString('o')
    }
}
