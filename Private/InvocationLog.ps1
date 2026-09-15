function Add-InvocationLogEntry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('ExternalCommand', 'WebRequest')][string]$Type,
        [Parameter(Mandatory)][string]$Detail
    )

    Write-Verbose "[$(Get-Date -Format 'HH:mm:ss')] [$Type] $Detail"
}
