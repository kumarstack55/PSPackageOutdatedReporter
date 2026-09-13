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

function Write-StageStatus {
    param([Parameter(Mandatory)][string]$Message)

    Write-Host -ForegroundColor Cyan "[$(Get-Date -Format 'HH:mm:ss')] $Message"
}
