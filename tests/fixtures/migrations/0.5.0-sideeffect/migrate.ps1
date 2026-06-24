Write-Host "I am a side-effect that runs at parse time"
Set-Location /tmp

function Get-MigrationPreview {
    [CmdletBinding()] param([Parameter(Mandatory)][hashtable]$Config)
    return [PSCustomObject]@{ Migration = '0.5.0-sideeffect' }
}

function Invoke-Migration {
    [CmdletBinding(SupportsShouldProcess)] param([hashtable]$Config)
    return [PSCustomObject]@{ OK = $true }
}
