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

function Get-ReportVisibleUpgradeTargets {
    param([Parameter(Mandatory)][SoftwarePackage]$Package)

    return @($Package.UpgradeTargets | Where-Object {
        -not (Test-IsOlderPackageVersion -CandidateVersion $_.PackageVersion.Version -BaselineVersion $Package.InstalledVersion.Version) -and
        -not (Test-IsSamePackageVersion -CandidateVersion $_.PackageVersion.Version -BaselineVersion $Package.InstalledVersion.Version)
    })
}

function Get-ReportOutOfCooldownUpgradeTargets {
    param(
        [Parameter(Mandatory)][SoftwarePackage]$Package,
        [int]$CooldownHours = $script:DefaultCooldownHours
    )

    return @(Get-ReportVisibleUpgradeTargets -Package $Package | Where-Object {
        -not $_.PackageVersion.IsInCooldown($CooldownHours)
    })
}

function Test-ReportPackageHasOutOfCooldownTargets {
    param(
        [Parameter(Mandatory)][SoftwarePackage]$Package,
        [int]$CooldownHours = $script:DefaultCooldownHours
    )

    return (Get-ReportOutOfCooldownUpgradeTargets -Package $Package -CooldownHours $CooldownHours).Count -gt 0
}

function Get-ReportPackagesWithOutOfCooldownTargets {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][SoftwarePackage[]]$Packages,
        [int]$CooldownHours = $script:DefaultCooldownHours
    )

    return @($Packages | Where-Object {
        Test-ReportPackageHasOutOfCooldownTargets -Package $_ -CooldownHours $CooldownHours
    })
}

function Write-OutdatedPackageReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][SoftwarePackage[]]$Packages,
        [int]$CooldownHours = $script:DefaultCooldownHours,
        [ValidateSet('Console', 'Html')][string]$OutputFormat = 'Console',
        [switch]$OpenReport
    )

    if ($OpenReport -and $OutputFormat -ne 'Html') {
        throw '-OpenReport can only be used with -OutputFormat Html.'
    }

    if ($OutputFormat -eq 'Html') {
        $reportPath = Write-HtmlPackageReport -Packages $Packages -CooldownHours $CooldownHours
        Write-Host "HTML report saved to: $reportPath"
        if ($OpenReport) {
            Start-Process -FilePath $reportPath -ErrorAction Stop
        }
        return
    }

    Write-ConsolePackageReport -Packages $Packages -CooldownHours $CooldownHours
}

function Write-ConsolePackageReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][SoftwarePackage[]]$Packages,
        [int]$CooldownHours = $script:DefaultCooldownHours
    )

    if ($Packages.Count -eq 0) {
        Write-Host -ForegroundColor Green 'No upgradeable packages found.'
        return
    }

    $reportColumns = @{ Name = 'Manager'; Expression = { $_.PackageManagerId } },
        @{ Name = 'Name'; Expression = { Get-ReportPackageName -Package $_ } },
        @{ Name = 'InstalledVersion'; Expression = { $_.InstalledVersion.Version } },
        @{ Name = 'InstalledVersionReleaseDate'; Expression = { $_.InstalledVersion.GetEffectiveDateInfo().GetDateOnlyDisplay() } },
        @{ Name = 'InstalledVersionReleaseRelative'; Expression = { $_.InstalledVersion.GetEffectiveDateInfo().GetRelativeDisplayWithFallbackLabel() } },
        @{ Name = 'LatestVersion'; Expression = { $_.LatestVersion.Version } },
        @{ Name = 'LatestVersionReleaseDate'; Expression = { $_.LatestVersion.GetEffectiveDateInfo().GetDateOnlyDisplay() } },
        @{ Name = 'LatestVersionReleaseRelative'; Expression = { $_.LatestVersion.GetEffectiveDateInfo().GetRelativeDisplayWithFallbackLabel() } }
    $reportColumnNames = 'Manager', 'Name', 'InstalledVersion', 'InstalledVersionReleaseDate', 'InstalledVersionReleaseRelative', 'LatestVersion', 'LatestVersionReleaseDate', 'LatestVersionReleaseRelative'

    Write-Host '## Upgradeable packages (sorted by software name)'
    $Packages |
        Sort-Object DisplayName, CandidateSource |
        Select-Object -Property $reportColumns |
        Select-Object -Property $reportColumnNames |
        Format-Table -AutoSize |
        Out-String -Width 4096 |
        Out-Host

    Write-Host '## Upgradeable packages (sorted by installed version release date, oldest first)'
    $Packages |
        Sort-Object -Property @{ Expression = { $_.InstalledVersion.GetEffectiveDateInfo().Date } } |
        Select-Object -Property $reportColumns |
        Select-Object -Property $reportColumnNames |
        Format-Table -AutoSize |
        Out-String -Width 4096 |
        Out-Host

    $outOfCooldownPackages = @(Get-ReportPackagesWithOutOfCooldownTargets -Packages $Packages -CooldownHours $CooldownHours)
    Write-Host '## Upgradeable packages (outside cooldown)'
    if ($outOfCooldownPackages.Count -eq 0) {
        Write-Host -ForegroundColor Green 'No upgradeable packages outside cooldown.'
    }
    else {
        $outOfCooldownPackages |
            Sort-Object DisplayName, CandidateSource |
            ForEach-Object {
                [pscustomobject]@{
                    Manager = $_.PackageManagerId
                    Name = Get-ReportPackageName -Package $_
                    InstalledVersion = $_.InstalledVersion.Version
                    AvailableUpgradeVersions = (Get-ReportOutOfCooldownUpgradeTargets -Package $_ -CooldownHours $CooldownHours |
                        ForEach-Object { $_.PackageVersion.Version }) -join ', '
                }
            } |
            Format-Table -AutoSize |
            Out-String -Width 4096 |
            Out-Host
    }

    foreach ($package in ($Packages | Sort-Object DisplayName, CandidateSource)) {
            Write-Host "`n## $(Get-ReportPackageHeading -Package $package)"
        if (-not [string]::IsNullOrWhiteSpace($package.InfoUrl)) {
            Write-Host "<$($package.InfoUrl)>"
        }
        Write-Host "Package Manager: $($package.PackageManagerId), Candidate source: $($package.CandidateSource)"

        $visibleTargets = Get-ReportVisibleUpgradeTargets -Package $package
        $maxVersionLength = @($visibleTargets | ForEach-Object { $_.PackageVersion.Version.Length }) |
            Measure-Object -Maximum |
            Select-Object -ExpandProperty Maximum
        $maxDateDisplayLength = @($visibleTargets | ForEach-Object { $_.PackageVersion.GetEffectiveDateInfo().GetCombinedDisplay().Length }) |
            Measure-Object -Maximum |
            Select-Object -ExpandProperty Maximum

        Write-Host -NoNewline "- "
        Write-Host -ForegroundColor Red "$($package.InstalledVersion.Version) [$($package.InstalledVersion.GetEffectiveDateInfo().GetCombinedDisplay())]"

        foreach ($target in $visibleTargets) {
            $isInCooldown = $target.PackageVersion.IsInCooldown($CooldownHours)

            $targetColor = 'Green'
            Write-Host -NoNewline "  - "
            Write-Host -NoNewline -ForegroundColor $targetColor "$($target.PackageVersion.Version.PadRight($maxVersionLength)) [$($target.PackageVersion.GetEffectiveDateInfo().GetCombinedDisplay().PadRight($maxDateDisplayLength))]"
            if ($isInCooldown) {
                Write-Host -NoNewline -ForegroundColor DarkGray " 🧊 cooldown ($($target.PackageVersion.GetCooldownRemainingDisplay($CooldownHours)) remaining)"
            }
            Write-Host ": $($target.Command)"
        }
    }

    $usesFirstSeenFallback = @($Packages | ForEach-Object {
        @($_.InstalledVersion, $_.LatestVersion) + @($_.UpgradeTargets | ForEach-Object { $_.PackageVersion })
    } | ForEach-Object { $_.GetEffectiveDateInfo().IsFirstObservedFallback }) -contains $true
    if ($usesFirstSeenFallback) {
        Write-Host -ForegroundColor DarkGray "`nNote: a version marked 'first seen' has no known release date; the date shown is instead the date this tool first observed that version."
    }
}
