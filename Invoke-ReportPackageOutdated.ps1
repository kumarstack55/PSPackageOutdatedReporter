#Requires -Version 5.1
#Requires -PSEdition Desktop

[CmdletBinding()]
param(
    [ValidateRange(1, 100)]
    [int]$MaxUpgradeVersions = 10,

    [ValidateSet('WinGet', 'Chocolatey', 'Scoop')]
    [string[]]$PackageManager = @('WinGet', 'Chocolatey', 'Scoop'),

    [string]$Source,

    [ValidateRange(1, 168)]
    [int]$CacheTtlHours = 24,

    [string]$CachePath = (Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'PSPackageOutdatedReporter\release-date-cache.json'),

    [switch]$ClearCache,

    [ValidateRange(0, 8760)]
    [int]$CooldownHours = (7 * 24)
)

. "$PSScriptRoot\Private\Formatting.ps1"
. "$PSScriptRoot\Private\Models.ps1"
. "$PSScriptRoot\Private\Cache.ps1"
. "$PSScriptRoot\Private\Version.ps1"
. "$PSScriptRoot\Private\Report.ps1"
. "$PSScriptRoot\Private\Providers\WinGet.ps1"
. "$PSScriptRoot\Private\Providers\Chocolatey.ps1"
. "$PSScriptRoot\Private\Providers\Scoop.ps1"

if ($MyInvocation.InvocationName -ne '.') {
    Write-StageStatus 'Loading release date cache...'
    $cache = Get-ReleaseDateCache -Path $CachePath -Clear:$ClearCache
    $packages = [System.Collections.Generic.List[SoftwarePackage]]::new()
    if ($PackageManager -contains 'WinGet') {
        Write-StageStatus 'Checking WinGet packages...'
        foreach ($package in @(Get-WinGetUpgradeablePackages -Cache $cache -CacheTtlHours $CacheTtlHours -MaxUpgradeVersions $MaxUpgradeVersions -SourceFilter $Source)) {
            $packages.Add($package)
        }
    }
    if ($PackageManager -contains 'Chocolatey') {
        Write-StageStatus 'Checking Chocolatey packages...'
        foreach ($package in @(Get-ChocolateyUpgradeablePackages -Cache $cache -CacheTtlHours $CacheTtlHours -MaxUpgradeVersions $MaxUpgradeVersions -SourceFilter $Source)) {
            $packages.Add($package)
        }
    }
    if ($PackageManager -contains 'Scoop') {
        Write-StageStatus 'Checking Scoop packages...'
        foreach ($package in @(Get-ScoopUpgradeablePackages -Cache $cache -CacheTtlHours $CacheTtlHours -MaxUpgradeVersions $MaxUpgradeVersions -SourceFilter $Source)) {
            $packages.Add($package)
        }
    }

    Write-StageStatus 'Saving release date cache...'
    Save-ReleaseDateCache -Cache $cache -Path $CachePath
    Write-StageStatus 'Rendering report...'
    Write-OutdatedPackageReport -Packages $packages.ToArray() -CooldownHours $CooldownHours
    $global:LASTEXITCODE = 0
}
