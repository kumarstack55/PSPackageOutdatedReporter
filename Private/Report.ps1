function Get-ReportPackageName {
    param([Parameter(Mandatory)][SoftwarePackage]$Package)

    return $Package.DisplayName
}

function Get-ReportPackageHeading {
    param([Parameter(Mandatory)][SoftwarePackage]$Package)

    if ($Package.DisplayName -ceq $Package.PackageId) {
        return $Package.DisplayName
    }

    return "$($Package.DisplayName) ($($Package.PackageId))"
}

function Write-OutdatedPackageReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][SoftwarePackage[]]$Packages,
        [int]$CooldownHours = (7 * 24)
    )

    if ($Packages.Count -eq 0) {
        Write-Host -ForegroundColor Green 'No upgradeable packages found.'
        return
    }

    Write-Host 'Upgradeable packages:'
    $Packages |
        Sort-Object DisplayName, CandidateSource |
        Select-Object @{ Name = 'Manager'; Expression = { $_.PackageManagerId } },
            @{ Name = 'Name'; Expression = { Get-ReportPackageName -Package $_ } },
            @{ Name = 'Source'; Expression = { $_.CandidateSource } },
            @{ Name = 'InstalledVersion'; Expression = { $_.InstalledVersion.Version } },
            @{ Name = 'InstalledVersionReleaseDate'; Expression = { $_.InstalledVersion.GetReleaseDateOnlyDisplay() } },
            @{ Name = 'InstalledVersionReleaseRelative'; Expression = { $_.InstalledVersion.GetReleaseDateRelativeDisplay() } },
            @{ Name = 'LatestVersion'; Expression = { $_.LatestVersion.Version } },
            @{ Name = 'LatestVersionReleaseDate'; Expression = { $_.LatestVersion.GetReleaseDateOnlyDisplay() } },
            @{ Name = 'LatestVersionReleaseRelative'; Expression = { $_.LatestVersion.GetReleaseDateRelativeDisplay() } } |
        Select-Object -Property Manager, Name, Source, InstalledVersion, InstalledVersionReleaseDate, InstalledVersionReleaseRelative, LatestVersion, LatestVersionReleaseDate, LatestVersionReleaseRelative |
        Format-Table -AutoSize |
        Out-String -Width 4096 |
        Out-Host

    foreach ($package in ($Packages | Sort-Object DisplayName, CandidateSource)) {
            Write-Host "`n## $(Get-ReportPackageHeading -Package $package)"
        Write-Host "Candidate source: $($package.CandidateSource)"
        Write-Host -ForegroundColor Red "$($package.InstalledVersion.Version) [$($package.InstalledVersion.GetReleaseDateDisplay())]"

        $targetIndex = 0
        foreach ($target in $package.UpgradeTargets) {
            $targetIndex++
            $targetPrefix = if ($targetIndex -lt $package.UpgradeTargets.Count) { '+-->' } else { '`-->' }
            Write-Host -NoNewline "  $targetPrefix "

            $isInCooldown = $target.PackageVersion.IsInCooldown($CooldownHours)
            $isDowngrade = Test-IsOlderPackageVersion -CandidateVersion $target.PackageVersion.Version -BaselineVersion $package.InstalledVersion.Version
            $targetColor = if ($isInCooldown -or $isDowngrade) { 'DarkGray' } else { 'Green' }
            Write-Host -NoNewline -ForegroundColor $targetColor "$($target.PackageVersion.Version) [$($target.PackageVersion.GetReleaseDateDisplay())]"
            if ($isDowngrade) {
                Write-Host -NoNewline -ForegroundColor DarkGray ' ⚠️ older than installed version'
            }
            if ($isInCooldown) {
                Write-Host -NoNewline -ForegroundColor DarkGray " 🧊 cooldown ($($target.PackageVersion.GetCooldownRemainingDisplay($CooldownHours)) remaining)"
            }
            Write-Host ": $($target.Command)"
        }
    }
}
