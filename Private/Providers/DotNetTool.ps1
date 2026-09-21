function Get-DotNetToolPackageVersions {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PackageId
    )

    $packageIdPath = [uri]::EscapeDataString($PackageId.ToLowerInvariant())
    $uri = "https://api.nuget.org/v3-flatcontainer/$packageIdPath/index.json"
    try {
        Add-InvocationLogEntry -Type WebRequest -Detail 'api.nuget.org package versions'
        $response = & {
            $ProgressPreference = 'SilentlyContinue'
            Invoke-WebRequest -Uri $uri -TimeoutSec 15 -ErrorAction Stop -UseBasicParsing
        }
        $data = $response.Content | ConvertFrom-Json -ErrorAction Stop
        return @($data.versions | Where-Object { $_ -match '^[0-9]+(\.[0-9]+){0,3}$' })
    } catch {
        Write-Verbose "Failed to retrieve NuGet versions for ${PackageId}: $($_.Exception.Message)"
        return @()
    }
}

function New-DotNetToolUpgradeCommand {
    param(
        [Parameter(Mandatory)][string]$PackageId,
        [Parameter(Mandatory)][string]$Version
    )

    return "dotnet tool update --global $(ConvertTo-PowerShellSingleQuotedArgument $PackageId) --version $(ConvertTo-PowerShellSingleQuotedArgument $Version)"
}

function Resolve-DotNetToolReleaseDate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PackageId,
        [Parameter(Mandatory)][string]$Version,
        [Parameter(Mandatory)][string]$CandidateSource,
        [Parameter(Mandatory)][hashtable]$Cache,
        [Parameter(Mandatory)][int]$CacheTtlHours
    )

    return Resolve-CachedPackageVersion -PackageManagerId 'dotnet-tool' -CandidateSource $CandidateSource -PackageId $PackageId -Version $Version -Cache $Cache -CacheTtlHours $CacheTtlHours -ResolveReleaseDate {
        [ReleaseDateResolution]::new($null, 'NotPublished', 'NuGet')
    }
}

function Get-DotNetToolUpgradeablePackages {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Cache,
        [Parameter(Mandatory)][int]$CacheTtlHours,
        [Parameter(Mandatory)][int]$MaxUpgradeVersions,
        [string]$SourceFilter
    )

    $candidateSource = 'nuget.org'
    if (-not [string]::IsNullOrWhiteSpace($SourceFilter) -and $candidateSource -ine $SourceFilter) {
        return @()
    }

    if ($null -eq (Get-Command dotnet -ErrorAction SilentlyContinue)) {
        Write-Warning 'The dotnet command is not installed or is not on PATH.'
        return @()
    }

    try {
        Write-StageStatus 'dotnet tool: querying globally installed tools...'
        Add-InvocationLogEntry -Type ExternalCommand -Detail 'dotnet tool list --global --format json'
        $jsonLines = @(dotnet tool list --global --format json 2>$null)
        if ($LASTEXITCODE -ne 0) {
            throw "dotnet tool list exited with code $LASTEXITCODE."
        }
        $installedTools = @((($jsonLines -join [Environment]::NewLine) | ConvertFrom-Json -ErrorAction Stop).data)
    } catch {
        Write-Warning "Unable to query globally installed dotnet tools: $($_.Exception.Message)"
        return @()
    }

    $reportPackages = [System.Collections.Generic.List[SoftwarePackage]]::new()
    $packageIndex = 0
    foreach ($installedTool in $installedTools) {
        $packageIndex++
        $packageId = [string]$installedTool.packageId
        $installedVersionText = [string]$installedTool.version
        if ([string]::IsNullOrWhiteSpace($packageId) -or [string]::IsNullOrWhiteSpace($installedVersionText)) {
            continue
        }

        $versions = @(Get-DotNetToolPackageVersions -PackageId $packageId)
        $versionTexts = @($versions |
                Sort-Object -Property @{ Expression = { Get-NormalizedPackageVersion -Version $_ } } -Descending |
                Select-Object -First $MaxUpgradeVersions)
        if ($versionTexts.Count -eq 0 -or (Test-IsOlderPackageVersion -CandidateVersion $versionTexts[0] -BaselineVersion $installedVersionText) -or (Test-IsSamePackageVersion -CandidateVersion $versionTexts[0] -BaselineVersion $installedVersionText)) {
            continue
        }

        Write-StageStatus "dotnet tool ($packageIndex/$($installedTools.Count)): resolving versions for $packageId..."
        $installedVersion = Resolve-DotNetToolReleaseDate -PackageId $packageId -Version $installedVersionText -CandidateSource $candidateSource -Cache $Cache -CacheTtlHours $CacheTtlHours
        $targets = [System.Collections.Generic.List[UpgradeTarget]]::new()
        foreach ($versionText in $versionTexts) {
            $isOlder = Test-IsOlderPackageVersion -CandidateVersion $versionText -BaselineVersion $installedVersionText
            $isSame = Test-IsSamePackageVersion -CandidateVersion $versionText -BaselineVersion $installedVersionText
            if ($isOlder -or $isSame) {
                continue
            }

            $availableVersion = Resolve-DotNetToolReleaseDate -PackageId $packageId -Version $versionText -CandidateSource $candidateSource -Cache $Cache -CacheTtlHours $CacheTtlHours
            $command = New-DotNetToolUpgradeCommand -PackageId $packageId -Version $versionText
            $targets.Add([UpgradeTarget]::new($availableVersion, $command))
        }

        if ($targets.Count -eq 0) {
            continue
        }

        $latestVersion = $targets[0].PackageVersion
        $infoUrl = "https://www.nuget.org/packages/$([uri]::EscapeDataString($packageId))"
        $reportPackages.Add([SoftwarePackage]::new('dotnet-tool', $packageId, $packageId, $candidateSource, $null, $installedVersion, $latestVersion, $targets.ToArray(), $infoUrl))
    }

    Write-StageStatus "dotnet tool: found $($reportPackages.Count) upgradeable package(s)."
    return $reportPackages.ToArray()
}

Register-PackageProvider -Id 'DotNetTool' -DisplayName 'dotnet tool' -CollectorCommand 'Get-DotNetToolUpgradeablePackages'