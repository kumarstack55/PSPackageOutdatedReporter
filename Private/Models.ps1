class ReleaseDateResolution {
    [object]$ReleasedAt
    [string]$Status
    [string]$MetadataSource

    ReleaseDateResolution([object]$ReleasedAt, [string]$Status, [string]$MetadataSource) {
        $this.ReleasedAt = $ReleasedAt
        $this.Status = $Status
        $this.MetadataSource = $MetadataSource
    }
}

class PackageVersion {
    [string]$Version
    [object]$ReleasedAt
    [object]$FirstObservedAt
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

    [string] GetReleaseDateOnlyDisplay() {
        if ($null -eq $this.ReleasedAt) {
            return 'Unknown'
        }

        return ([datetime]$this.ReleasedAt).ToString('yyyy-MM-dd')
    }

    [string] GetReleaseDateRelativeDisplay() {
        if ($null -eq $this.ReleasedAt) {
            return "Unknown ($($this.ReleaseDateStatus))"
        }

        return Get-RelativeReleaseDateDisplay -ReleasedAt ([datetime]$this.ReleasedAt)
    }

    [bool] IsInCooldown([int]$CooldownHours) {
        if ($CooldownHours -le 0 -or $null -eq $this.ReleasedAt) {
            return $false
        }

        return ([datetime]::Now - [datetime]$this.ReleasedAt).TotalHours -lt $CooldownHours
    }

    [string] GetCooldownRemainingDisplay([int]$CooldownHours) {
        $remainingHours = $CooldownHours - ([datetime]::Now - [datetime]$this.ReleasedAt).TotalHours
        if ($remainingHours -le 0) {
            return '0h'
        }

        $remainingDays = [math]::Floor($remainingHours / 24)
        $remainingHoursPart = [math]::Ceiling($remainingHours % 24)
        if ($remainingDays -gt 0) {
            return "${remainingDays}d ${remainingHoursPart}h"
        }

        return "${remainingHoursPart}h"
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
