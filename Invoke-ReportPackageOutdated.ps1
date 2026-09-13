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
            $response = & {
                $ProgressPreference = 'SilentlyContinue'
                Invoke-WebRequest -Uri $uri -TimeoutSec 15 -ErrorAction Stop -UseBasicParsing
            }
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

function New-ChocolateyUpgradeCommand {
    param(
        [Parameter(Mandatory)][string]$PackageId,
        [Parameter(Mandatory)][string]$Version
    )

    return "choco upgrade $(ConvertTo-PowerShellSingleQuotedArgument $PackageId) --version $(ConvertTo-PowerShellSingleQuotedArgument $Version) --yes"
}

function Get-ScoopManifestReleaseDate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PackageId,
        [Parameter(Mandatory)][string]$Version,
        [string]$BucketName
    )

    $manifestSearchPath = if (-not [string]::IsNullOrWhiteSpace($BucketName) -and $BucketName -ine 'unknown') {
        "$env:USERPROFILE\scoop\buckets\$BucketName\bucket\${PackageId}.json"
    } else {
        "$env:USERPROFILE\scoop\buckets\*\bucket\${PackageId}.json"
    }

    $manifestItem = Get-ChildItem $manifestSearchPath -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $manifestItem) {
        return $null
    }

    $repositoryPath = Split-Path $manifestItem.DirectoryName -Parent
    $jsonPath = "bucket/${PackageId}.json"

    $hashDateArray = @(git -C $repositoryPath log --follow --format='%H%x09%cs' -- $jsonPath 2>$null)
    if ($LASTEXITCODE -ne 0 -or $hashDateArray.Count -eq 0) {
        return $null
    }

    foreach ($hashDate in $hashDateArray) {
        $commitHash, $ymdString = $hashDate -split "`t", 2
        $gitShowOutputJson = git -C $repositoryPath show "${commitHash}:${jsonPath}" 2>$null
        if (-not $gitShowOutputJson) {
            continue
        }

        $data = $gitShowOutputJson | ConvertFrom-Json -ErrorAction SilentlyContinue
        # each commit corresponds to a version bump, so the first match found (newest-first) is the publish date
        if ($null -ne $data -and [string]$data.version -eq $Version) {
            return [datetime]::ParseExact($ymdString, 'yyyy-MM-dd', $null)
        }
    }

    return $null
}

function Resolve-ScoopReleaseDate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PackageId,
        [Parameter(Mandatory)][string]$Version,
        [Parameter(Mandatory)][string]$CandidateSource,
        [Parameter(Mandatory)][hashtable]$Cache,
        [Parameter(Mandatory)][int]$CacheTtlHours
    )

    $cacheKey = Get-ReleaseDateCacheKey -PackageManagerId 'scoop' -CandidateSource $CandidateSource -PackageId $PackageId -Version $Version
    $entry = $Cache.entries[$cacheKey]
    if ($null -ne $entry) {
        $cachedAt = [datetime]::MinValue
        if ([datetime]::TryParse([string]$entry.cachedAt, [ref]$cachedAt) -and $cachedAt.ToUniversalTime().AddHours($CacheTtlHours) -gt [datetime]::UtcNow) {
            return ConvertTo-PackageVersionFromCacheEntry -Entry $entry
        }
    }

    $metadataSource = 'Scoop manifest (git history)'
    $status = 'NotPublished'
    $releasedAt = $null

    if ($null -eq (Get-Command git -ErrorAction SilentlyContinue)) {
        $metadataSource = 'None'
        $status = 'UnsupportedSource'
    } else {
        try {
            $releasedAt = Get-ScoopManifestReleaseDate -PackageId $PackageId -Version $Version -BucketName $CandidateSource
            if ($null -eq $releasedAt) {
                $status = 'NotPublished'
            } else {
                $status = 'Found'
            }
        } catch {
            $status = 'LookupFailed'
            Write-Verbose "Failed to retrieve Scoop release date for $PackageId ${Version}: $($_.Exception.Message)"
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

function New-ScoopUpgradeCommand {
    param(
        [Parameter(Mandatory)][string]$PackageId,
        [Parameter(Mandatory)][string]$Version
    )

    return "scoop update $(ConvertTo-PowerShellSingleQuotedArgument $PackageId)"
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
        Write-StageStatus 'Chocolatey: querying outdated packages...'
        $lines = @(choco outdated --no-color --limit-output 2>$null)
        if ($LASTEXITCODE -ne 0) {
            throw "choco outdated exited with code $LASTEXITCODE."
        }
    } catch {
        Write-Warning "Unable to query Chocolatey packages: $($_.Exception.Message)"
        return @()
    }

    $outdatedEntries = [System.Collections.Generic.List[string[]]]::new()
    foreach ($line in $lines) {
        $parts = $line -split '\|', 4
        if ($parts.Count -ne 4 -or [string]::IsNullOrWhiteSpace($parts[0])) {
            continue
        }

        $outdatedEntries.Add($parts)
    }

    Write-StageStatus "Chocolatey: found $($outdatedEntries.Count) outdated package(s)."

    $reportPackages = [System.Collections.Generic.List[SoftwarePackage]]::new()
    $packageIndex = 0
    foreach ($parts in $outdatedEntries) {
        $packageIndex++

        $packageId = $parts[0]
        $installedVersionText = $parts[1]
        $availableVersionText = $parts[2]
        Write-StageStatus "Chocolatey ($packageIndex/$($outdatedEntries.Count)): resolving release dates for $packageId..."
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

function Get-ScoopUpgradeablePackages {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Cache,
        [Parameter(Mandatory)][int]$CacheTtlHours,
        [Parameter(Mandatory)][int]$MaxUpgradeVersions,
        [string]$SourceFilter
    )

    if ($null -eq (Get-Command scoop -ErrorAction SilentlyContinue)) {
        Write-Warning 'Scoop is not installed or is not on PATH.'
        return @()
    }

    try {
        Write-StageStatus 'Scoop: querying package status...'
        $statusLines = @(scoop status 2>$null)
        if ($LASTEXITCODE -ne 0) {
            throw "scoop status exited with code $LASTEXITCODE."
        }
    } catch {
        Write-Warning "Unable to query Scoop packages: $($_.Exception.Message)"
        return @()
    }

    $outdatedEntries = [System.Collections.Generic.List[pscustomobject]]::new()
    foreach ($line in $statusLines) {
        if ($null -ne $line.PSObject.Properties['Name'] -and
            $null -ne $line.PSObject.Properties['Installed Version'] -and
            $null -ne $line.PSObject.Properties['Latest Version']) {
            $packageId = [string]$line.Name
            $installedVersionText = [string]$line.'Installed Version'
            $availableVersionText = [string]$line.'Latest Version'
        } else {
            if ($line -notmatch '^\s*(?<packageId>\S+)\s+(?<installedVersion>\S+)\s+(?<availableVersion>\S+)(?:\s+.*)?$' -or
                $Matches.packageId -eq 'Name' -or
                $Matches.installedVersion -eq 'Installed') {
                continue
            }

            $packageId = $Matches.packageId
            $installedVersionText = $Matches.installedVersion
            $availableVersionText = $Matches.availableVersion
        }

        $outdatedEntries.Add([pscustomobject]@{
            PackageId = $packageId
            InstalledVersionText = $installedVersionText
            AvailableVersionText = $availableVersionText
        })
    }

    Write-StageStatus "Scoop: found $($outdatedEntries.Count) candidate package(s) to check."

    $reportPackages = [System.Collections.Generic.List[SoftwarePackage]]::new()
    $packageIndex = 0
    foreach ($entry in $outdatedEntries) {
        $packageIndex++

        $packageId = $entry.PackageId
        $installedVersionText = $entry.InstalledVersionText
        $availableVersionText = $entry.AvailableVersionText
        Write-StageStatus "Scoop ($packageIndex/$($outdatedEntries.Count)): resolving release dates for $packageId..."

        $candidateSource = ''
        try {
            $infoLines = @(scoop info $packageId 2>$null)
            $sourceInfo = $infoLines | Where-Object { $null -ne $_.PSObject.Properties['Source'] } | Select-Object -First 1
            if ($null -ne $sourceInfo) {
                $candidateSource = [string]$sourceInfo.Source
            } else {
                $sourceLine = $infoLines | Where-Object { $_ -match '^\s*Source\s*:\s*(?<source>\S+)' } | Select-Object -First 1
                if ($null -ne $sourceLine -and $sourceLine -match '^\s*Source\s*:\s*(?<source>\S+)') {
                    $candidateSource = $Matches.source
                }
            }
        } catch {
            Write-Verbose "Failed to retrieve Scoop source for ${packageId}: $($_.Exception.Message)"
        }
        if ([string]::IsNullOrWhiteSpace($candidateSource)) {
            $candidateSource = 'unknown'
        }

        if ([string]::IsNullOrWhiteSpace($packageId) -or
            [string]::IsNullOrWhiteSpace($installedVersionText) -or
            [string]::IsNullOrWhiteSpace($availableVersionText) -or
            $installedVersionText -eq $availableVersionText) {
            continue
        }
        if (-not [string]::IsNullOrWhiteSpace($SourceFilter) -and $candidateSource -ine $SourceFilter) {
            continue
        }

        $installedVersion = Resolve-ScoopReleaseDate -PackageId $packageId -Version $installedVersionText -CandidateSource $candidateSource -Cache $Cache -CacheTtlHours $CacheTtlHours
        $availableVersion = Resolve-ScoopReleaseDate -PackageId $packageId -Version $availableVersionText -CandidateSource $candidateSource -Cache $Cache -CacheTtlHours $CacheTtlHours
        $target = [UpgradeTarget]::new($availableVersion, (New-ScoopUpgradeCommand -PackageId $packageId -Version $availableVersionText))
        $reportPackages.Add([SoftwarePackage]::new('scoop', $packageId, $packageId, $candidateSource, $null, $installedVersion, $availableVersion, @($target)))
    }

    return $reportPackages.ToArray()
}

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
