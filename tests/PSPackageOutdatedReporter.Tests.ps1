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
            Should -Be "choco upgrade 'O''Reilly.App' --version '1.2.3' --yes"
    }

    It 'round-trips the release date cache' {
        $cachePath = Join-Path $TestDrive 'release-date-cache.json'
        $cache = @{ schemaVersion = 1; entries = @{ 'key' = @{ version = '1.2.3'; releasedAt = '2026-01-02'; status = 'Found'; metadataSource = 'test'; cachedAt = '2026-01-02T00:00:00Z' } } }

        Save-ReleaseDateCache -Cache $cache -Path $cachePath
        $loaded = Get-ReleaseDateCache -Path $cachePath

        $loaded.schemaVersion | Should -Be 1
        $loaded.entries['key'].version | Should -Be '1.2.3'
        $loaded.entries['key'].status | Should -Be 'Found'
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
