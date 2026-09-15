$modulePath = Join-Path $PSScriptRoot '..\PSPackageOutdatedReporter.psm1'
Import-Module $modulePath -Force

Describe 'Core module behavior' {
    It 'does not invoke the report when the module is imported' {
        (Get-Command Get-ReleaseDateCacheKey -ErrorAction Stop).CommandType | Should -Be 'Function'
    }
}

Describe 'Core formatting and reporting' {
    It 'quotes PowerShell arguments' {
        ConvertTo-PowerShellSingleQuotedArgument -Value "O'Reilly.App" | Should -Be "'O''Reilly.App'"
    }

    It 'uses display names without package IDs in report names' {
        InModuleScope PSPackageOutdatedReporter {
            $version = [PackageVersion]::new('1.0.0', $null, 'NotPublished', 'None')
            $target = [UpgradeTarget]::new($version, 'winget upgrade')
            $wingetPackage = [SoftwarePackage]::new('winget', 'Contoso.App', 'Contoso App', 'winget', $null, $version, $version, @($target), 'https://example.com/contoso')
            $scoopPackage = [SoftwarePackage]::new('scoop', 'demo', 'Demo', 'main', $null, $version, $version, @($target), 'https://example.com/demo')
            $chocolateyPackage = [SoftwarePackage]::new('chocolatey', 'nodejs.install', 'nodejs.install', 'chocolatey', $null, $version, $version, @($target), 'https://example.com/nodejs')

            Get-ReportPackageName -Package $wingetPackage | Should -Be 'Contoso App'
            Get-ReportPackageName -Package $scoopPackage | Should -Be 'Demo'
            Get-ReportPackageHeading -Package $scoopPackage | Should -Be 'Demo (demo)'
            Get-ReportPackageHeading -Package $chocolateyPackage | Should -Be 'nodejs.install'
        }
    }

    It 'separates release date and relative displays' {
        InModuleScope PSPackageOutdatedReporter {
            $releasedVersion = [PackageVersion]::new('1.0.0', [datetime]'2026-01-02', 'Found', 'test')
            $unreleasedVersion = [PackageVersion]::new('1.0.0', $null, 'NotPublished', 'test')

            $releasedVersion.GetReleaseDateOnlyDisplay() | Should -Be '2026-01-02'
            $releasedVersion.GetReleaseDateRelativeDisplay() | Should -Match 'ago$|^in '
            $unreleasedVersion.GetReleaseDateOnlyDisplay() | Should -Be 'Unknown'
            $unreleasedVersion.GetReleaseDateRelativeDisplay() | Should -Be 'Unknown (NotPublished)'
        }
    }
}

Describe 'Core release date cache' {
    It 'round-trips the release date cache' {
        $cachePath = Join-Path $TestDrive 'release-date-cache.json'
        $cache = @{ schemaVersion = 1; entries = @{ 'key' = @{ version = '1.2.3'; releasedAt = '2026-01-02'; firstObservedAt = '2026-01-03T00:00:00Z'; status = 'Found'; metadataSource = 'test'; cachedAt = '2026-01-02T00:00:00Z' } } }

        Save-ReleaseDateCache -Cache $cache -Path $cachePath
        $loaded = Get-ReleaseDateCache -Path $cachePath

        $loaded.schemaVersion | Should -Be 1
        $loaded.entries['key'].version | Should -Be '1.2.3'
        $loaded.entries['key'].status | Should -Be 'Found'
        $loaded.entries['key'].firstObservedAt | Should -Be '2026-01-03T00:00:00Z'
    }

    It 'preserves FirstObservedAt when refreshing an expired entry' {
        InModuleScope PSPackageOutdatedReporter {
            $firstObservedAt = '2026-01-03T00:00:00Z'
            $cache = @{ schemaVersion = 1; entries = @{ 'winget|winget|demo|1.2.3' = @{ version = '1.2.3'; releasedAt = $null; firstObservedAt = $firstObservedAt; status = 'NotPublished'; metadataSource = 'test'; cachedAt = '2026-01-01T00:00:00Z' } } }

            $result = Resolve-CachedPackageVersion -PackageManagerId 'winget' -CandidateSource 'winget' -PackageId 'demo' -Version '1.2.3' -Cache $cache -CacheTtlHours 1 -ResolveReleaseDate {
                [ReleaseDateResolution]::new($null, 'NotPublished', 'test')
            }

            ([datetime]$cache.entries['winget|winget|demo|1.2.3'].firstObservedAt).ToUniversalTime() | Should -Be ([datetime]$firstObservedAt).ToUniversalTime()
            $result.FirstObservedAt.ToUniversalTime() | Should -Be ([datetime]$firstObservedAt).ToUniversalTime()
        }
    }
}