#Requires -Version 5.1
#Requires -PSEdition Desktop

[CmdletBinding()]
param(
    [ValidateRange(1, 100)]
    [int]$MaxUpgradeVersions = 10,

    [ValidateSet('WinGet', 'Chocolatey')]
    [string[]]$PackageManager = @('WinGet', 'Chocolatey'),

    [string]$Source,

    [ValidateRange(1, 168)]
    [int]$CacheTtlHours = 24,

    [string]$CachePath = (Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'PSPackageOutdatedReporter\release-date-cache.json'),

    [switch]$ClearCache
)

function Get-RelativeReleaseDateDisplay {
    param([Parameter(Mandatory)][datetime]$ReleasedAt)

    $releaseDate = $ReleasedAt.Date
    $daysFromToday = ([datetime]::Today - $releaseDate).Days
    if ($daysFromToday -gt 0) {
        return "$daysFromToday`d ago"
    }

    if ($daysFromToday -lt 0) {
        return "in $(-$daysFromToday)`d"
    }

    $hoursFromNow = [math]::Floor(([datetime]::Now - $ReleasedAt).TotalHours)
    if ($hoursFromNow -ge 0) {
        return "$hoursFromNow`h ago"
    }

    return "in $(-$hoursFromNow)`h"
}

class PackageVersion {
    [string]$Version
    [object]$ReleasedAt
    [string]$ReleaseDateStatus
    [string]$MetadataSource

    PackageVersion([string]$Version, [object]$ReleasedAt, [string]$ReleaseDateStatus, [string]$MetadataSource) {
        $this.Version = $Version
        $this.ReleasedAt = $ReleasedAt
        $this.ReleaseDateStatus = $ReleaseDateStatus
        $this.MetadataSource = $MetadataSource
    }

    [string] GetReleaseDateDisplay() {
        if ($null -ne $this.ReleasedAt) {
            $releaseTimestamp = [datetime]$this.ReleasedAt
            $releaseDate = $releaseTimestamp.Date
            $relativeDate = Get-RelativeReleaseDateDisplay -ReleasedAt $releaseTimestamp

            return "$($releaseDate.ToString('yyyy-MM-dd')) ($relativeDate)"
        }

        return "Unknown ($($this.ReleaseDateStatus))"
    }
}

class UpgradeTarget {
    [PackageVersion]$PackageVersion
    [string]$Command

    UpgradeTarget([PackageVersion]$PackageVersion, [string]$Command) {
        $this.PackageVersion = $PackageVersion
        $this.Command = $Command
    }
}

class SoftwarePackage {
    [string]$PackageManagerId
    [string]$PackageId
    [string]$DisplayName
    [string]$CandidateSource
    [string]$InstalledSource
    [PackageVersion]$InstalledVersion
    [PackageVersion]$LatestVersion
    [UpgradeTarget[]]$UpgradeTargets

    SoftwarePackage(
        [string]$PackageManagerId,
        [string]$PackageId,
        [string]$DisplayName,
        [string]$CandidateSource,
        [string]$InstalledSource,
        [PackageVersion]$InstalledVersion,
        [PackageVersion]$LatestVersion,
        [UpgradeTarget[]]$UpgradeTargets
    ) {
        $this.PackageManagerId = $PackageManagerId
        $this.PackageId = $PackageId
        $this.DisplayName = $DisplayName
        $this.CandidateSource = $CandidateSource
        $this.InstalledSource = $InstalledSource
        $this.InstalledVersion = $InstalledVersion
        $this.LatestVersion = $LatestVersion
        $this.UpgradeTargets = $UpgradeTargets
    }
}

function Get-ReleaseDateCache {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [switch]$Clear
    )

    if ($Clear -and (Test-Path -LiteralPath $Path)) {
        Remove-Item -LiteralPath $Path -Force
    }

    if (-not (Test-Path -LiteralPath $Path)) {
        return @{ schemaVersion = 1; entries = @{} }
    }

    try {
        $cachedJson = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        $cache = @{
            schemaVersion = [int]$cachedJson.schemaVersion
            entries = @{}
        }
        foreach ($property in $cachedJson.entries.PSObject.Properties) {
            $entry = $property.Value
            $cache.entries[$property.Name] = @{
                version = [string]$entry.version
                releasedAt = [string]$entry.releasedAt
                status = [string]$entry.status
                metadataSource = [string]$entry.metadataSource
                cachedAt = [string]$entry.cachedAt
            }
        }
        if ($cache.schemaVersion -ne 1 -or $null -eq $cache.entries) {
            throw 'Unsupported cache schema.'
        }

        return $cache
    } catch {
        Write-Warning "Ignoring invalid release-date cache '$Path': $($_.Exception.Message)"
        return @{ schemaVersion = 1; entries = @{} }
    }
}

function Save-ReleaseDateCache {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Cache,

        [Parameter(Mandatory)]
        [string]$Path
    )

    $directory = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    $temporaryPath = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        $Cache | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $temporaryPath -Encoding utf8 -NoNewline
        Move-Item -LiteralPath $temporaryPath -Destination $Path -Force
    } finally {
        if (Test-Path -LiteralPath $temporaryPath) {
            Remove-Item -LiteralPath $temporaryPath -Force
        }
    }
}

function Get-ReleaseDateCacheKey {
    param(
        [Parameter(Mandatory)][string]$PackageManagerId,
        [Parameter(Mandatory)][string]$CandidateSource,
        [Parameter(Mandatory)][string]$PackageId,
        [Parameter(Mandatory)][string]$Version
    )

    return "$PackageManagerId|$CandidateSource|$PackageId|$Version"
}

function ConvertTo-PackageVersionFromCacheEntry {
    param([Parameter(Mandatory)][hashtable]$Entry)

    $releasedAt = $null
    if (-not [string]::IsNullOrWhiteSpace([string]$Entry.releasedAt)) {
        $parsedDate = [datetime]::MinValue
        if ([datetime]::TryParseExact([string]$Entry.releasedAt, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$parsedDate)) {
            $releasedAt = $parsedDate
        }
    }

    return [PackageVersion]::new([string]$Entry.version, $releasedAt, [string]$Entry.status, [string]$Entry.metadataSource)
}

function Get-WinGetManifestUrl {
    param(
        [Parameter(Mandatory)][string]$PackageId,
        [Parameter(Mandatory)][string]$Version
    )

    $firstCharacter = $PackageId.Substring(0, 1).ToLowerInvariant()
    $packagePath = ($PackageId -split '\.') -join '/'
    $escapedVersion = [uri]::EscapeDataString($Version)
    return "https://raw.githubusercontent.com/microsoft/winget-pkgs/master/manifests/$firstCharacter/$packagePath/$escapedVersion/$PackageId.yaml"
}

function Resolve-WinGetReleaseDate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PackageId,
        [Parameter(Mandatory)][string]$Version,
        [Parameter(Mandatory)][string]$CandidateSource,
        [Parameter(Mandatory)][hashtable]$Cache,
        [Parameter(Mandatory)][int]$CacheTtlHours
    )

    $cacheKey = Get-ReleaseDateCacheKey -PackageManagerId 'winget' -CandidateSource $CandidateSource -PackageId $PackageId -Version $Version
    $entry = $Cache.entries[$cacheKey]
    if ($null -ne $entry) {
        $cachedAt = [datetime]::MinValue
        if ([datetime]::TryParse([string]$entry.cachedAt, [ref]$cachedAt) -and $cachedAt.ToUniversalTime().AddHours($CacheTtlHours) -gt [datetime]::UtcNow) {
            return ConvertTo-PackageVersionFromCacheEntry -Entry $entry
        }
    }

    $metadataSource = 'winget-pkgs'
    $status = 'Found'
    $releasedAt = $null

    if ($CandidateSource -ine 'winget') {
        $metadataSource = 'None'
        $status = 'UnsupportedSource'
    } else {
        try {
            $manifest = Invoke-WebRequest -Uri (Get-WinGetManifestUrl -PackageId $PackageId -Version $Version) -TimeoutSec 15 -ErrorAction Stop
            $releaseDateMatch = [regex]::Match($manifest.Content, '(?m)^ReleaseDate:\s*["'']?(?<value>\d{4}-\d{2}-\d{2})')
            if ($releaseDateMatch.Success) {
                $parsedDate = [datetime]::MinValue
                if ([datetime]::TryParseExact($releaseDateMatch.Groups['value'].Value, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$parsedDate)) {
                    $releasedAt = $parsedDate
                } else {
                    $status = 'InvalidReleaseDate'
                }
            } else {
                $status = 'NotPublished'
            }
        } catch {
            $status = 'LookupFailed'
            Write-Verbose "Failed to retrieve release date for $PackageId ${Version}: $($_.Exception.Message)"
        }
    }

    $Cache.entries[$cacheKey] = @{
        version = $Version
        releasedAt = if ($null -ne $releasedAt) { ([datetime]$releasedAt).ToString('yyyy-MM-dd') } else { $null }
        status = $status
        metadataSource = $metadataSource
        cachedAt = [datetime]::UtcNow.ToString('o')
    }

    return [PackageVersion]::new($Version, $releasedAt, $status, $metadataSource)
}

function Resolve-ChocolateyReleaseDate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PackageId,
        [Parameter(Mandatory)][string]$Version,
        [Parameter(Mandatory)][string]$CandidateSource,
        [Parameter(Mandatory)][hashtable]$Cache,
        [Parameter(Mandatory)][int]$CacheTtlHours
    )

    $cacheKey = Get-ReleaseDateCacheKey -PackageManagerId 'chocolatey' -CandidateSource $CandidateSource -PackageId $PackageId -Version $Version
    $entry = $Cache.entries[$cacheKey]
    if ($null -ne $entry) {
        $cachedAt = [datetime]::MinValue
        if ([datetime]::TryParse([string]$entry.cachedAt, [ref]$cachedAt) -and $cachedAt.ToUniversalTime().AddHours($CacheTtlHours) -gt [datetime]::UtcNow) {
            return ConvertTo-PackageVersionFromCacheEntry -Entry $entry
        }
    }

    $metadataSource = 'chocolatey.org'
    $status = 'Found'
    $releasedAt = $null

    if ($CandidateSource -ine 'chocolatey') {
        $metadataSource = 'None'
        $status = 'UnsupportedSource'
    } else {
        try {
            $escapedId = $PackageId.Replace("'", "''")
            $escapedVersion = $Version.Replace("'", "''")
            $uri = "https://community.chocolatey.org/api/v2/Packages(Id='$escapedId',Version='$escapedVersion')"
            $response = Invoke-WebRequest -Uri $uri -TimeoutSec 15 -ErrorAction Stop
            $xml = [xml]$response.Content
            $namespace = [System.Xml.XmlNamespaceManager]::new($xml.NameTable)
            $namespace.AddNamespace('m', 'http://schemas.microsoft.com/ado/2007/08/dataservices/metadata')
            $namespace.AddNamespace('d', 'http://schemas.microsoft.com/ado/2007/08/dataservices')
            $publishedNode = $xml.SelectSingleNode('//m:properties/d:Published', $namespace)

            $parsedDate = [datetime]::MinValue
            if ($null -eq $publishedNode -or -not [datetime]::TryParse($publishedNode.InnerText, [ref]$parsedDate)) {
                $status = 'NotPublished'
            } else {
                $releasedAt = $parsedDate.ToUniversalTime()
            }
        } catch {
            $status = 'LookupFailed'
            Write-Verbose "Failed to retrieve Chocolatey release date for $PackageId ${Version}: $($_.Exception.Message)"
        }
    }

    $Cache.entries[$cacheKey] = @{
        version = $Version
        releasedAt = if ($null -ne $releasedAt) { ([datetime]$releasedAt).ToString('yyyy-MM-dd') } else { $null }
        status = $status
        metadataSource = $metadataSource
        cachedAt = [datetime]::UtcNow.ToString('o')
    }

    return [PackageVersion]::new($Version, $releasedAt, $status, $metadataSource)
}

function ConvertTo-PowerShellSingleQuotedArgument {
    param([Parameter(Mandatory)][string]$Value)

    return "'$($Value.Replace("'", "''"))'"
}

function New-WinGetUpgradeCommand {
    param(
        [Parameter(Mandatory)][string]$PackageId,
        [Parameter(Mandatory)][string]$Version,
        [Parameter(Mandatory)][string]$CandidateSource
    )

    return "winget upgrade --id $(ConvertTo-PowerShellSingleQuotedArgument $PackageId) --exact --version $(ConvertTo-PowerShellSingleQuotedArgument $Version) --source $(ConvertTo-PowerShellSingleQuotedArgument $CandidateSource)"
}

function New-ChocolateyUpgradeCommand {
    param(
        [Parameter(Mandatory)][string]$PackageId,
        [Parameter(Mandatory)][string]$Version
    )

    return "choco upgrade $(ConvertTo-PowerShellSingleQuotedArgument $PackageId) --version $(ConvertTo-PowerShellSingleQuotedArgument $Version) --yes"
}

function Get-WinGetUpgradeablePackages {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Cache,
        [Parameter(Mandatory)][int]$CacheTtlHours,
        [Parameter(Mandatory)][int]$MaxUpgradeVersions,
        [string]$SourceFilter
    )

    $module = Get-Module -ListAvailable Microsoft.WinGet.Client | Sort-Object Version -Descending | Select-Object -First 1
    if ($null -eq $module) {
        Write-Warning 'Microsoft.WinGet.Client is not installed. Run: Install-Module Microsoft.WinGet.Client -Scope CurrentUser'
        return @()
    }

    try {
        Import-Module $module.Path -ErrorAction Stop
        $installedPackages = Get-WinGetPackage -ErrorAction Stop
    } catch {
        Write-Warning "Unable to query WinGet packages: $($_.Exception.Message)"
        return @()
    }

    $reportPackages = [System.Collections.Generic.List[SoftwarePackage]]::new()
    foreach ($installedPackage in $installedPackages) {
        if (-not $installedPackage.IsUpdateAvailable) {
            continue
        }

        $candidateSource = [string]$installedPackage.Source
        if (-not [string]::IsNullOrWhiteSpace($SourceFilter) -and $candidateSource -ine $SourceFilter) {
            continue
        }

        $versions = @($installedPackage.AvailableVersions | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -First $MaxUpgradeVersions)
        if ($versions.Count -eq 0) {
            Write-Warning "WinGet reported an update for '$($installedPackage.Id)' but supplied no available version."
            continue
        }

        $installedVersion = Resolve-WinGetReleaseDate -PackageId $installedPackage.Id -Version ([string]$installedPackage.InstalledVersion) -CandidateSource $candidateSource -Cache $Cache -CacheTtlHours $CacheTtlHours
        $targets = [System.Collections.Generic.List[UpgradeTarget]]::new()
        foreach ($version in $versions) {
            $availableVersion = Resolve-WinGetReleaseDate -PackageId $installedPackage.Id -Version ([string]$version) -CandidateSource $candidateSource -Cache $Cache -CacheTtlHours $CacheTtlHours
            $command = New-WinGetUpgradeCommand -PackageId $installedPackage.Id -Version ([string]$version) -CandidateSource $candidateSource
            $targets.Add([UpgradeTarget]::new($availableVersion, $command))
        }

        $latestVersion = $targets[0].PackageVersion
        $reportPackages.Add([SoftwarePackage]::new('winget', $installedPackage.Id, $installedPackage.Name, $candidateSource, $null, $installedVersion, $latestVersion, $targets.ToArray()))
    }

    return $reportPackages.ToArray()
}

function Get-ChocolateyAvailableVersions {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PackageId,
        [Parameter(Mandatory)][string]$AvailableVersion,
        [Parameter(Mandatory)][int]$MaxUpgradeVersions
    )

    try {
        $lines = @(choco search $PackageId --exact --all-versions --limit-output --order-by=version --descending --no-color 2>$null)
        $versions = @($lines |
                Where-Object { $_ -match "^$([regex]::Escape($PackageId))\|" } |
                ForEach-Object { ($_ -split '\|', 3)[1] } |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                Select-Object -Unique -First $MaxUpgradeVersions)

        if ($versions -notcontains $AvailableVersion) {
            $versions = @($AvailableVersion) + $versions
        }

        return @($versions | Select-Object -Unique -First $MaxUpgradeVersions)
    } catch {
        Write-Verbose "Failed to retrieve Chocolatey version history for ${PackageId}: $($_.Exception.Message)"
        return @($AvailableVersion)
    }
}

function Get-ChocolateyUpgradeablePackages {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Cache,
        [Parameter(Mandatory)][int]$CacheTtlHours,
        [Parameter(Mandatory)][int]$MaxUpgradeVersions,
        [string]$SourceFilter
    )

    if ($null -eq (Get-Command choco -ErrorAction SilentlyContinue)) {
        Write-Warning 'Chocolatey is not installed or is not on PATH.'
        return @()
    }

    $candidateSource = 'chocolatey'
    if (-not [string]::IsNullOrWhiteSpace($SourceFilter) -and $candidateSource -ine $SourceFilter) {
        return @()
    }

    try {
        $lines = @(choco outdated --no-color --limit-output 2>$null)
        if ($LASTEXITCODE -ne 0) {
            throw "choco outdated exited with code $LASTEXITCODE."
        }
    } catch {
        Write-Warning "Unable to query Chocolatey packages: $($_.Exception.Message)"
        return @()
    }

    $reportPackages = [System.Collections.Generic.List[SoftwarePackage]]::new()
    foreach ($line in $lines) {
        $parts = $line -split '\|', 4
        if ($parts.Count -ne 4 -or [string]::IsNullOrWhiteSpace($parts[0])) {
            continue
        }

        $packageId = $parts[0]
        $installedVersionText = $parts[1]
        $availableVersionText = $parts[2]
        $versionTexts = Get-ChocolateyAvailableVersions -PackageId $packageId -AvailableVersion $availableVersionText -MaxUpgradeVersions $MaxUpgradeVersions
        $installedVersion = Resolve-ChocolateyReleaseDate -PackageId $packageId -Version $installedVersionText -CandidateSource $candidateSource -Cache $Cache -CacheTtlHours $CacheTtlHours
        $targets = [System.Collections.Generic.List[UpgradeTarget]]::new()
        foreach ($versionText in $versionTexts) {
            $availableVersion = Resolve-ChocolateyReleaseDate -PackageId $packageId -Version $versionText -CandidateSource $candidateSource -Cache $Cache -CacheTtlHours $CacheTtlHours
            $targets.Add([UpgradeTarget]::new($availableVersion, (New-ChocolateyUpgradeCommand -PackageId $packageId -Version $versionText)))
        }

        $latestTarget = $targets | Where-Object { $_.PackageVersion.Version -eq $availableVersionText } | Select-Object -First 1
        $latestVersion = if ($null -ne $latestTarget) { $latestTarget.PackageVersion } else { $targets[0].PackageVersion }
        $reportPackages.Add([SoftwarePackage]::new('chocolatey', $packageId, $packageId, $candidateSource, $null, $installedVersion, $latestVersion, $targets.ToArray()))
    }

    return $reportPackages.ToArray()
}

function Write-OutdatedPackageReport {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][SoftwarePackage[]]$Packages)

    if ($Packages.Count -eq 0) {
        Write-Host -ForegroundColor Green 'No upgradeable packages found.'
        return
    }

    Write-Host 'Upgradeable packages:'
    $Packages |
        Sort-Object DisplayName, CandidateSource |
        Select-Object @{ Name = 'Manager'; Expression = { $_.PackageManagerId } },
            @{ Name = 'Name'; Expression = { "$($_.DisplayName) ($($_.PackageId))" } },
            @{ Name = 'Source'; Expression = { $_.CandidateSource } },
            @{ Name = 'Installed'; Expression = { "$($_.InstalledVersion.Version) [$($_.InstalledVersion.GetReleaseDateDisplay())]" } },
            @{ Name = 'Latest'; Expression = { "$($_.LatestVersion.Version) [$($_.LatestVersion.GetReleaseDateDisplay())]" } } |
        Select-Object -Property Manager, Name, Installed, Latest |
        Format-Table -AutoSize -Wrap |
        Out-Host

    foreach ($package in ($Packages | Sort-Object DisplayName, CandidateSource)) {
        Write-Host "`n## $($package.DisplayName) ($($package.PackageId))"
        Write-Host "Candidate source: $($package.CandidateSource)"
        Write-Host -NoNewline 'Installed: '
        Write-Host -ForegroundColor Red "$($package.InstalledVersion.Version) [$($package.InstalledVersion.GetReleaseDateDisplay())]"
        Write-Host 'Upgrade targets:'

        foreach ($target in $package.UpgradeTargets) {
            Write-Host -NoNewline '  '
            Write-Host -NoNewline -ForegroundColor Red "$($package.InstalledVersion.Version) [$($package.InstalledVersion.GetReleaseDateDisplay())]"
            Write-Host -NoNewline ' --> '
            Write-Host -NoNewline -ForegroundColor Yellow "$($target.PackageVersion.Version) [$($target.PackageVersion.GetReleaseDateDisplay())]"
            Write-Host ": $($target.Command)"
        }
    }
}

$cache = Get-ReleaseDateCache -Path $CachePath -Clear:$ClearCache
$packages = [System.Collections.Generic.List[SoftwarePackage]]::new()
if ($PackageManager -contains 'WinGet') {
    foreach ($package in @(Get-WinGetUpgradeablePackages -Cache $cache -CacheTtlHours $CacheTtlHours -MaxUpgradeVersions $MaxUpgradeVersions -SourceFilter $Source)) {
        $packages.Add($package)
    }
}
if ($PackageManager -contains 'Chocolatey') {
    foreach ($package in @(Get-ChocolateyUpgradeablePackages -Cache $cache -CacheTtlHours $CacheTtlHours -MaxUpgradeVersions $MaxUpgradeVersions -SourceFilter $Source)) {
        $packages.Add($package)
    }
}
Save-ReleaseDateCache -Cache $cache -Path $CachePath
Write-OutdatedPackageReport -Packages $packages.ToArray()
$global:LASTEXITCODE = 0
