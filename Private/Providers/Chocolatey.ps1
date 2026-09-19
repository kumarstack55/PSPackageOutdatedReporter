function Resolve-ChocolateyReleaseDate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PackageId,
        [Parameter(Mandatory)][string]$Version,
        [Parameter(Mandatory)][string]$CandidateSource,
        [Parameter(Mandatory)][hashtable]$Cache,
        [Parameter(Mandatory)][int]$CacheTtlHours
    )

    return Resolve-CachedPackageVersion -PackageManagerId 'chocolatey' -CandidateSource $CandidateSource -PackageId $PackageId -Version $Version -Cache $Cache -CacheTtlHours $CacheTtlHours -ResolveReleaseDate {
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
                Add-InvocationLogEntry -Type WebRequest -Detail 'community.chocolatey.org Packages OData'
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

        [ReleaseDateResolution]::new($releasedAt, $status, $metadataSource)
    }
}

function New-ChocolateyUpgradeCommand {
    param(
        [Parameter(Mandatory)][string]$PackageId,
        [Parameter(Mandatory)][string]$Version
    )

    $sudoPrefix = if ($null -ne (Get-Command sudo -ErrorAction SilentlyContinue)) { 'sudo ' } else { '' }
    return "${sudoPrefix}choco upgrade $(ConvertTo-PowerShellSingleQuotedArgument $PackageId) --version $(ConvertTo-PowerShellSingleQuotedArgument $Version) --yes"
}

function Resolve-ChocolateyInfoUrl {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PackageId,
        [Parameter(Mandatory)][string]$Version,
        [Parameter(Mandatory)][string]$CandidateSource
        ,[Parameter(Mandatory)][hashtable]$Cache
        ,[Parameter(Mandatory)][int]$CacheTtlHours
    )

    $cacheKey = Get-ReleaseDateCacheKey -PackageManagerId 'chocolatey' -CandidateSource $CandidateSource -PackageId $PackageId -Version $Version
    $entry = $Cache.entries[$cacheKey]
    if ($null -ne $entry -and -not [string]::IsNullOrWhiteSpace([string]$entry.infoUrl)) {
        $cachedAt = [datetime]::MinValue
        if ([datetime]::TryParse([string]$entry.cachedAt, [ref]$cachedAt) -and $cachedAt.ToUniversalTime().AddHours($CacheTtlHours) -gt [datetime]::UtcNow) {
            Write-Verbose "Info URL cache hit: $cacheKey"
            return [string]$entry.infoUrl
        }
    }

    Write-Verbose "Info URL cache miss: $cacheKey"
    if ($CandidateSource -ine 'chocolatey') {
        return Get-PackageInfoUrlFallback -PackageId $PackageId
    }

    try {
        $escapedId = $PackageId.Replace("'", "''")
        $escapedVersion = $Version.Replace("'", "''")
        $uri = "https://community.chocolatey.org/api/v2/Packages(Id='$escapedId',Version='$escapedVersion')"
        Add-InvocationLogEntry -Type WebRequest -Detail 'community.chocolatey.org Packages OData'
        $response = & {
            $ProgressPreference = 'SilentlyContinue'
            Invoke-WebRequest -Uri $uri -TimeoutSec 15 -ErrorAction Stop -UseBasicParsing
        }
        $xml = [xml]$response.Content
        $namespace = [System.Xml.XmlNamespaceManager]::new($xml.NameTable)
        $namespace.AddNamespace('m', 'http://schemas.microsoft.com/ado/2007/08/dataservices/metadata')
        $namespace.AddNamespace('d', 'http://schemas.microsoft.com/ado/2007/08/dataservices')

        foreach ($fieldName in 'ProjectSourceUrl', 'PackageSourceUrl', 'ProjectUrl') {
            $node = $xml.SelectSingleNode("//m:properties/d:$fieldName", $namespace)
            if ($null -ne $node -and -not [string]::IsNullOrWhiteSpace($node.InnerText)) {
                if ($null -eq $Cache.entries[$cacheKey]) {
                    $Cache.entries[$cacheKey] = @{
                        version = $Version
                        releasedAt = $null
                        firstObservedAt = $null
                        status = 'Unknown'
                        metadataSource = 'chocolatey.org'
                        cachedAt = [datetime]::UtcNow.ToString('o')
                        infoUrl = $null
                    }
                }
                $Cache.entries[$cacheKey].infoUrl = $node.InnerText
                return $node.InnerText
            }
        }
    } catch {
        Write-Verbose "Failed to retrieve Chocolatey info URL for $PackageId ${Version}: $($_.Exception.Message)"
    }

    $fallbackUrl = Get-PackageInfoUrlFallback -PackageId $PackageId
    if ($null -eq $Cache.entries[$cacheKey]) {
        $Cache.entries[$cacheKey] = @{
            version = $Version
            releasedAt = $null
            firstObservedAt = $null
            status = 'Unknown'
            metadataSource = 'chocolatey.org'
            cachedAt = [datetime]::UtcNow.ToString('o')
            infoUrl = $fallbackUrl
        }
    } else {
        $Cache.entries[$cacheKey].infoUrl = $fallbackUrl
    }

    return $fallbackUrl
}

function Get-ChocolateyAvailableVersions {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PackageId,
        [Parameter(Mandatory)][string]$AvailableVersion,
        [Parameter(Mandatory)][int]$MaxUpgradeVersions
    )

    try {
        # --order-by=version is not a supported clause; sort by normalized version ourselves instead.
        Add-InvocationLogEntry -Type ExternalCommand -Detail 'choco search'
        $lines = @(choco search $PackageId --exact --all-versions --limit-output --no-color 2>$null)
        $versions = @($lines |
                Where-Object { $_ -match "^$([regex]::Escape($PackageId))\|" } |
                ForEach-Object { ($_ -split '\|', 3)[1] } |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                Select-Object -Unique |
                Sort-Object -Property @{ Expression = { Get-NormalizedPackageVersion -Version $_ } } -Descending |
                Select-Object -First $MaxUpgradeVersions)

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
        Add-InvocationLogEntry -Type ExternalCommand -Detail 'choco outdated'
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
        $infoUrl = Resolve-ChocolateyInfoUrl -PackageId $packageId -Version $latestVersion.Version -CandidateSource $candidateSource -Cache $Cache -CacheTtlHours $CacheTtlHours
        $reportPackages.Add([SoftwarePackage]::new('chocolatey', $packageId, $packageId, $candidateSource, $null, $installedVersion, $latestVersion, $targets.ToArray(), $infoUrl))
    }

    return $reportPackages.ToArray()
}

Register-PackageProvider -Id 'Chocolatey' -DisplayName 'Chocolatey' -CollectorCommand 'Get-ChocolateyUpgradeablePackages'
