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
            $manifest = & {
                $ProgressPreference = 'SilentlyContinue'
                Invoke-WebRequest -Uri (Get-WinGetManifestUrl -PackageId $PackageId -Version $Version) -TimeoutSec 15 -ErrorAction Stop -UseBasicParsing
            }

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
        Write-StageStatus 'WinGet: loading Microsoft.WinGet.Client module...'
        Import-Module $module.Path -ErrorAction Stop
        Write-StageStatus 'WinGet: querying installed packages...'
        $installedPackages = Get-WinGetPackage -ErrorAction Stop
    } catch {
        Write-Warning "Unable to query WinGet packages: $($_.Exception.Message)"
        return @()
    }

    $updatablePackages = @($installedPackages | Where-Object { $_.IsUpdateAvailable })
    Write-StageStatus "WinGet: found $($updatablePackages.Count) package(s) with updates available."

    $reportPackages = [System.Collections.Generic.List[SoftwarePackage]]::new()
    $packageIndex = 0
    foreach ($installedPackage in $updatablePackages) {
        $packageIndex++

        $candidateSource = [string]$installedPackage.Source
        if (-not [string]::IsNullOrWhiteSpace($SourceFilter) -and $candidateSource -ine $SourceFilter) {
            continue
        }

        $versions = @($installedPackage.AvailableVersions | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -First $MaxUpgradeVersions)
        if ($versions.Count -eq 0) {
            Write-Warning "WinGet reported an update for '$($installedPackage.Id)' but supplied no available version."
            continue
        }

        Write-StageStatus "WinGet ($packageIndex/$($updatablePackages.Count)): resolving release dates for $($installedPackage.Id)..."
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
