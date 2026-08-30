[CmdletBinding()]
param(
    [ValidateRange(1, 100)]
    [int]$MaxUpgradeVersions = 10,

    [string]$Source,

    [ValidateRange(1, 168)]
    [int]$CacheTtlHours = 24,

    [string]$CachePath = (Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'PSPackageOutdatedReporter\release-date-cache.json'),

    [switch]$ClearCache
)

class PackageVersion {
    [string]$Version
    [Nullable[datetime]]$ReleasedAt
    [string]$ReleaseDateStatus
    [string]$MetadataSource

    PackageVersion([string]$Version, [Nullable[datetime]]$ReleasedAt, [string]$ReleaseDateStatus, [string]$MetadataSource) {
        $this.Version = $Version
        $this.ReleasedAt = $ReleasedAt
        $this.ReleaseDateStatus = $ReleaseDateStatus
        $this.MetadataSource = $MetadataSource
    }

    [string] GetReleaseDateDisplay() {
        if ($this.ReleasedAt.HasValue) {
            return $this.ReleasedAt.Value.ToString('yyyy-MM-dd')
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
        $cache = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -AsHashtable -ErrorAction Stop
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
            $releasedAt = [Nullable[datetime]]$parsedDate
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
                    $releasedAt = [Nullable[datetime]]$parsedDate
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
        releasedAt = if ($releasedAt.HasValue) { $releasedAt.Value.ToString('yyyy-MM-dd') } else { $null }
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

function Write-WinGetOutdatedReport {
    [CmdletBinding()]
    param([Parameter(Mandatory)][SoftwarePackage[]]$Packages)

    if ($Packages.Count -eq 0) {
        Write-Host -ForegroundColor Green 'No upgradeable WinGet packages found.'
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
            Write-Host -NoNewline -ForegroundColor Yellow "$($target.PackageVersion.Version) [$($target.PackageVersion.GetReleaseDateDisplay())]"
            Write-Host "  $($target.Command)"
        }
    }
}

$cache = Get-ReleaseDateCache -Path $CachePath -Clear:$ClearCache
$packages = @(Get-WinGetUpgradeablePackages -Cache $cache -CacheTtlHours $CacheTtlHours -MaxUpgradeVersions $MaxUpgradeVersions -SourceFilter $Source)
Save-ReleaseDateCache -Cache $cache -Path $CachePath
Write-WinGetOutdatedReport -Packages $packages
