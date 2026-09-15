$modulePath = Join-Path $PSScriptRoot '..\PSPackageOutdatedReporter.psm1'
Import-Module $modulePath -Force

Describe 'PSPackageOutdatedReporter' {
    It 'does not invoke the report when the module is imported' {
        (Get-Command Get-ReleaseDateCacheKey -ErrorAction Stop).CommandType | Should -Be 'Function'
    }

    It 'builds a WinGet manifest URL' {
        Get-WinGetManifestUrl -PackageId 'Contoso.App' -Version '1.2.3' |
            Should -Be 'https://raw.githubusercontent.com/microsoft/winget-pkgs/master/manifests/c/Contoso/App/1.2.3/Contoso.App.yaml'
    }

    It 'quotes PowerShell arguments' {
        ConvertTo-PowerShellSingleQuotedArgument -Value "O'Reilly.App" | Should -Be "'O''Reilly.App'"
    }

    It 'builds upgrade commands with escaped arguments' {
        New-ChocolateyUpgradeCommand -PackageId "O'Reilly.App" -Version '1.2.3' |
            Should -Be "sudo choco upgrade 'O''Reilly.App' --version '1.2.3' --yes"
    }

    It 'builds a Scoop upgrade command' {
        New-ScoopUpgradeCommand -PackageId "O'Reilly.App" -Version '1.2.3' |
            Should -Be "scoop install 'O''Reilly.App@1.2.3'; scoop reset 'O''Reilly.App@1.2.3'"
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

    It 'marks Scoop release dates as unpublished and caches the result' {
        $cache = @{ schemaVersion = 1; entries = @{} }

        $result = Resolve-ScoopReleaseDate -PackageId 'demo' -Version '1.2.3' -CandidateSource 'main' -Cache $cache -CacheTtlHours 24

        $result.ReleaseDateStatus | Should -Be 'NotPublished'
        $cache.entries.Count | Should -Be 1
        $cache.entries.Values[0].firstObservedAt | Should -Not -BeNullOrEmpty
        $result.FirstObservedAt | Should -Not -BeNullOrEmpty
    }

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

    It 'returns UnsupportedSource without making an HTTP request' {
        InModuleScope PSPackageOutdatedReporter {
            Mock Invoke-WebRequest { throw 'HTTP must not be called' }
            $cache = @{ schemaVersion = 1; entries = @{} }

            $result = Resolve-WinGetReleaseDate -PackageId 'Contoso.App' -Version '1.2.3' -CandidateSource 'msstore' -Cache $cache -CacheTtlHours 24

            $result.ReleaseDateStatus | Should -Be 'UnsupportedSource'
            Assert-MockCalled Invoke-WebRequest -Times 0
        }
    }

    It 'parses a published Chocolatey date from the HTTP response' {
        InModuleScope PSPackageOutdatedReporter {
            Mock Invoke-WebRequest {
                [pscustomobject]@{ Content = @'
<entry xmlns:m="http://schemas.microsoft.com/ado/2007/08/dataservices/metadata" xmlns:d="http://schemas.microsoft.com/ado/2007/08/dataservices"><content><m:properties><d:Published>2026-01-02T03:04:05Z</d:Published></m:properties></content></entry>
'@ }
            }
            $cache = @{ schemaVersion = 1; entries = @{} }

            $result = Resolve-ChocolateyReleaseDate -PackageId 'demo' -Version '1.2.3' -CandidateSource 'chocolatey' -Cache $cache -CacheTtlHours 24

            $result.ReleaseDateStatus | Should -Be 'Found'
            $result.ReleasedAt.ToString('yyyy-MM-dd') | Should -Be '2026-01-02'
            Assert-MockCalled Invoke-WebRequest -Times 1
        }
    }
}
