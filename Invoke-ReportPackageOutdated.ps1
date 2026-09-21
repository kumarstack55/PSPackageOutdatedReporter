#Requires -Version 5.1
#Requires -PSEdition Desktop

[CmdletBinding()]
param(
    [ValidateRange(1, 100)]
    [int]$MaxUpgradeVersions = 10,

    [ValidateSet('WinGet', 'Chocolatey', 'Scoop', 'DotNetTool')]
    [string[]]$PackageManager = @('WinGet', 'Chocolatey', 'Scoop', 'DotNetTool'),

    [string]$Source,

    [ValidateRange(1, 168)]
    [int]$CacheTtlHours = 24,

    [string]$CachePath = (Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'PSPackageOutdatedReporter\release-date-cache.json'),

    [switch]$ClearCache,

    [ValidateRange(0, 8760)]
    [int]$CooldownHours = (7 * 24)
)

. "$PSScriptRoot\Private\Formatting.ps1"
. "$PSScriptRoot\Private\InvocationLog.ps1"
. "$PSScriptRoot\Private\Models.ps1"
. "$PSScriptRoot\Private\Cache.ps1"
. "$PSScriptRoot\Private\Version.ps1"
. "$PSScriptRoot\Private\Report.ps1"
. "$PSScriptRoot\Private\Providers.ps1"
. "$PSScriptRoot\Private\Providers\WinGet.ps1"
. "$PSScriptRoot\Private\Providers\Chocolatey.ps1"
. "$PSScriptRoot\Private\Providers\Scoop.ps1"
. "$PSScriptRoot\Private\Providers\DotNetTool.ps1"

function Invoke-OutdatedPackageReport {
    [CmdletBinding()]
    param(
        [ValidateRange(1, 100)][int]$MaxUpgradeVersions = 10,
        [ValidateSet('WinGet', 'Chocolatey', 'Scoop', 'DotNetTool')]
        [string[]]$PackageManager = @('WinGet', 'Chocolatey', 'Scoop', 'DotNetTool'),
        [string]$Source,
        [ValidateRange(1, 168)][int]$CacheTtlHours = 24,
        [string]$CachePath = (Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'PSPackageOutdatedReporter\release-date-cache.json'),
        [switch]$ClearCache,
        [ValidateRange(0, 8760)][int]$CooldownHours = (7 * 24)
    )

    $providers = foreach ($providerId in $PackageManager) {
        $provider = Get-PackageProvider -Id $providerId
        if ($null -eq $provider) {
            $supportedProviderIds = (Get-PackageProviders | ForEach-Object { $_.Id }) -join ', '
            throw "Unsupported package manager '$providerId'. Supported package managers: $supportedProviderIds."
        }

        $provider
    }

    Write-StageStatus 'Loading release date cache...'
    $cache = Get-ReleaseDateCache -Path $CachePath -Clear:$ClearCache
    $packages = [System.Collections.Generic.List[SoftwarePackage]]::new()
    foreach ($provider in $providers) {
        Write-StageStatus "Checking $($provider.DisplayName) packages..."
        foreach ($package in @(& $provider.CollectorCommand -Cache $cache -CacheTtlHours $CacheTtlHours -MaxUpgradeVersions $MaxUpgradeVersions -SourceFilter $Source)) {
            $packages.Add($package)
        }
    }

    Write-StageStatus 'Saving release date cache...'
    Save-ReleaseDateCache -Cache $cache -Path $CachePath
    Write-StageStatus 'Rendering report...'
    Write-OutdatedPackageReport -Packages $packages.ToArray() -CooldownHours $CooldownHours
    $global:LASTEXITCODE = 0
}

if ($MyInvocation.InvocationName -ne '.') {
    Invoke-OutdatedPackageReport @PSBoundParameters
}
