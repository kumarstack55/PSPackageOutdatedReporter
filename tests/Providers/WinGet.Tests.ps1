$modulePath = Join-Path $PSScriptRoot '..\..\PSPackageOutdatedReporter.psm1'
Import-Module $modulePath -Force

Describe 'WinGet provider' {
    It 'builds a WinGet manifest URL' {
        Get-WinGetManifestUrl -PackageId 'Contoso.App' -Version '1.2.3' |
            Should -Be 'https://raw.githubusercontent.com/microsoft/winget-pkgs/master/manifests/c/Contoso/App/1.2.3/Contoso.App.yaml'
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

    It 'caches the info URL after reading the manifests' {
        InModuleScope PSPackageOutdatedReporter {
            Mock Invoke-WebRequest {
                [pscustomobject]@{ Content = "DefaultLocale: en-US`nPackageUrl: https://example.com/teraterm" }
            }
            $cache = @{ schemaVersion = 1; entries = @{} }

            $firstUrl = Resolve-WinGetInfoUrl -PackageId 'Contoso.App' -Version '1.2.3' -CandidateSource 'winget' -Cache $cache -CacheTtlHours 24
            $secondUrl = Resolve-WinGetInfoUrl -PackageId 'Contoso.App' -Version '1.2.3' -CandidateSource 'winget' -Cache $cache -CacheTtlHours 24

            $firstUrl | Should -Be 'https://example.com/teraterm'
            $secondUrl | Should -Be 'https://example.com/teraterm'
            Assert-MockCalled Invoke-WebRequest -Times 2
        }
    }
}