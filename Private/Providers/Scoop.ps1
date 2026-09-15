function Resolve-ScoopManifestRepository {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PackageId,
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

    return [pscustomobject]@{
        RepositoryPath = Split-Path $manifestItem.DirectoryName -Parent
        JsonPath = "bucket/${PackageId}.json"
    }
}

function Get-ScoopManifestReleaseDate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PackageId,
        [Parameter(Mandatory)][string]$Version,
        [string]$BucketName
    )

    $manifest = Resolve-ScoopManifestRepository -PackageId $PackageId -BucketName $BucketName
    if ($null -eq $manifest) {
        return $null
    }

    $repositoryPath = $manifest.RepositoryPath
    $jsonPath = $manifest.JsonPath

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

function Get-ScoopManifestVersionHistory {
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)][string]$PackageId,
        [string]$BucketName,
        [int]$Limit = 10
    )

    $manifest = Resolve-ScoopManifestRepository -PackageId $PackageId -BucketName $BucketName
    if ($null -eq $manifest) {
        return @()
    }

    $repositoryPath = $manifest.RepositoryPath
    $jsonPath = $manifest.JsonPath

    $hashDateArray = @(git -C $repositoryPath log --follow --format='%H%x09%cs' -- $jsonPath 2>$null)
    if ($LASTEXITCODE -ne 0 -or $hashDateArray.Count -eq 0) {
        return @()
    }

    $seen = [System.Collections.Generic.HashSet[string]]::new()
    $history = [System.Collections.Generic.List[pscustomobject]]::new()

    foreach ($hashDate in $hashDateArray) {
        $commitHash, $ymdString = $hashDate -split "`t", 2
        $gitShowOutputJson = git -C $repositoryPath show "${commitHash}:${jsonPath}" 2>$null
        if (-not $gitShowOutputJson) {
            continue
        }

        $data = $gitShowOutputJson | ConvertFrom-Json -ErrorAction SilentlyContinue
        $version = if ($null -ne $data) { [string]$data.version } else { $null }
        if (-not [string]::IsNullOrWhiteSpace($version) -and $seen.Add($version)) {
            $history.Add([pscustomobject]@{
                Version = $version
                ReleasedAt = [datetime]::ParseExact($ymdString, 'yyyy-MM-dd', $null)
            })

            if ($history.Count -ge $Limit) {
                break
            }
        }
    }

    return $history.ToArray()
}

function Get-ScoopAvailableVersions {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PackageId,
        [string]$BucketName,
        [Parameter(Mandatory)][string]$AvailableVersion,
        [Parameter(Mandatory)][int]$MaxUpgradeVersions
    )

    try {
        $history = @(Get-ScoopManifestVersionHistory -PackageId $PackageId -BucketName $BucketName -Limit $MaxUpgradeVersions)
        $versions = @($history | ForEach-Object { $_.Version })

        if ($versions -notcontains $AvailableVersion) {
            $versions = @($AvailableVersion) + $versions
        }

        return @($versions | Select-Object -Unique -First $MaxUpgradeVersions)
    } catch {
        Write-Verbose "Failed to retrieve Scoop version history for ${PackageId}: $($_.Exception.Message)"
        return @($AvailableVersion)
    }
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

    return Resolve-CachedPackageVersion -PackageManagerId 'scoop' -CandidateSource $CandidateSource -PackageId $PackageId -Version $Version -Cache $Cache -CacheTtlHours $CacheTtlHours -ResolveReleaseDate {
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

        [ReleaseDateResolution]::new($releasedAt, $status, $metadataSource)
    }
}

function New-ScoopUpgradeCommand {
    param(
        [Parameter(Mandatory)][string]$PackageId,
        [Parameter(Mandatory)][string]$Version
    )

    $quotedArgument = $(ConvertTo-PowerShellSingleQuotedArgument "${PackageId}@${Version}")
    return "scoop install $quotedArgument; scoop reset $quotedArgument"
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
        $statusRecords = @(scoop status 2>$null)
        if ($LASTEXITCODE -ne 0) {
            throw "scoop status exited with code $LASTEXITCODE."
        }
    } catch {
        Write-Warning "Unable to query Scoop packages: $($_.Exception.Message)"
        return @()
    }

    $outdatedEntries = [System.Collections.Generic.List[pscustomobject]]::new()
    foreach ($record in $statusRecords) {
        if ($null -ne $record.PSObject.Properties['Name'] -and
            $null -ne $record.PSObject.Properties['Installed Version'] -and
            $null -ne $record.PSObject.Properties['Latest Version']) {
            $packageId = [string]$record.Name
            $installedVersionText = [string]$record.'Installed Version'
            $availableVersionText = [string]$record.'Latest Version'
        } else {
            if ($record -notmatch '^\s*(?<packageId>\S+)\s+(?<installedVersion>\S+)\s+(?<availableVersion>\S+)(?:\s+.*)?$' -or
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
        $versionTexts = Get-ScoopAvailableVersions -PackageId $packageId -BucketName $candidateSource -AvailableVersion $availableVersionText -MaxUpgradeVersions $MaxUpgradeVersions
        $targets = [System.Collections.Generic.List[UpgradeTarget]]::new()
        foreach ($versionText in $versionTexts) {
            $availableVersion = Resolve-ScoopReleaseDate -PackageId $packageId -Version $versionText -CandidateSource $candidateSource -Cache $Cache -CacheTtlHours $CacheTtlHours
            $targets.Add([UpgradeTarget]::new($availableVersion, (New-ScoopUpgradeCommand -PackageId $packageId -Version $versionText)))
        }

        $latestTarget = $targets | Where-Object { $_.PackageVersion.Version -eq $availableVersionText } | Select-Object -First 1
        $latestVersion = if ($null -ne $latestTarget) { $latestTarget.PackageVersion } else { $targets[0].PackageVersion }
        $reportPackages.Add([SoftwarePackage]::new('scoop', $packageId, $packageId, $candidateSource, $null, $installedVersion, $latestVersion, $targets.ToArray()))
    }

    return $reportPackages.ToArray()
}
