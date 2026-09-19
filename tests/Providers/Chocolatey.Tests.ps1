$modulePath = Join-Path $PSScriptRoot '..\..\PSPackageOutdatedReporter.psm1'
Import-Module $modulePath -Force

Describe 'Chocolatey provider' {
    It 'builds upgrade commands with escaped arguments' {
        New-ChocolateyUpgradeCommand -PackageId "O'Reilly.App" -Version '1.2.3' |
            Should -Be "sudo choco upgrade 'O''Reilly.App' --version '1.2.3' --yes"
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

    It 'caches the Chocolatey info URL' {
        InModuleScope PSPackageOutdatedReporter {
            Mock Invoke-WebRequest {
                [pscustomobject]@{ Content = @'
<entry xmlns:m="http://schemas.microsoft.com/ado/2007/08/dataservices/metadata" xmlns:d="http://schemas.microsoft.com/ado/2007/08/dataservices"><content><m:properties><d:ProjectUrl>https://example.com/demo</d:ProjectUrl></m:properties></content></entry>
'@ }
            }
            $cache = @{ schemaVersion = 1; entries = @{} }

            $firstUrl = Resolve-ChocolateyInfoUrl -PackageId 'demo' -Version '1.2.3' -CandidateSource 'chocolatey' -Cache $cache -CacheTtlHours 24
            $secondUrl = Resolve-ChocolateyInfoUrl -PackageId 'demo' -Version '1.2.3' -CandidateSource 'chocolatey' -Cache $cache -CacheTtlHours 24

            $firstUrl | Should -Be 'https://example.com/demo'
            $secondUrl | Should -Be 'https://example.com/demo'
            Assert-MockCalled Invoke-WebRequest -Times 1
        }
    }
}
