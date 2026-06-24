function Get-MigrationPreview {
    [CmdletBinding()] param([Parameter(Mandatory)][hashtable]$Config)
    return [PSCustomObject]@{ Migration = '0.4.0-broken' }
}
# Intentionally missing Invoke-Migration
