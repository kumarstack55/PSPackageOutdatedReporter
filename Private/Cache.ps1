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
        $cachedJson = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        $cache = @{
            schemaVersion = [int]$cachedJson.schemaVersion
            entries = @{}
        }
        foreach ($property in $cachedJson.entries.PSObject.Properties) {
            $entry = $property.Value
            $cache.entries[$property.Name] = @{
                version = [string]$entry.version
                releasedAt = [string]$entry.releasedAt
                status = [string]$entry.status
                metadataSource = [string]$entry.metadataSource
                cachedAt = [string]$entry.cachedAt
            }
        }
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
            $releasedAt = $parsedDate
        }
    }

    return [PackageVersion]::new([string]$Entry.version, $releasedAt, [string]$Entry.status, [string]$Entry.metadataSource)
}
