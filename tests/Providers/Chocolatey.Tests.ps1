$modulePath = Join-Path $PSScriptRoot '..\..\PSPackageOutdatedReporter.psm1'
Import-Module $modulePath -Force

Describe 'Chocolatey provider' {
    It 'counts installed packages independently of outdated packages' {
        InModuleScope PSPackageOutdatedReporter {
            function choco {}
            Mock Get-Command { [pscustomobject]@{ Name = 'choco' } } -ParameterFilter { $Name -eq 'choco' }
            Mock choco {
                $global:LASTEXITCODE = 0
                if ($args[0] -eq 'list') { 'one|1.0'; 'two|2.0' }
            }
            $count = $null

            $result = @(Get-ChocolateyUpgradeablePackages -Cache @{} -CacheTtlHours 24 -MaxUpgradeVersions 1 -InstalledCount ([ref]$count))

            $result.Count | Should -Be 0
            $count | Should -Be 2
        }
    }

    It 'warns and leaves the count unknown when the installed list fails' {
        InModuleScope PSPackageOutdatedReporter {
            function choco {}
            Mock Get-Command { [pscustomobject]@{ Name = 'choco' } } -ParameterFilter { $Name -eq 'choco' }
            Mock choco {
                $global:LASTEXITCODE = if ($args[0] -eq 'list') { 1 } else { 0 }
                if ($args[0] -eq 'outdated') { 'demo|1.0|2.0|false' }
            }
            Mock Get-ChocolateyAvailableVersions { @('2.0') }
            Mock Resolve-ChocolateyReleaseDate { [PackageVersion]::new($Version, $null, 'NotPublished', 'test') }
            Mock Resolve-ChocolateyInfoUrl { '' }
            Mock Write-Warning {}
            $count = 9

            $result = @(Get-ChocolateyUpgradeablePackages -Cache @{} -CacheTtlHours 24 -MaxUpgradeVersions 1 -InstalledCount ([ref]$count))

            $count | Should -BeNullOrEmpty
            $result.Count | Should -Be 1
            $result[0].PackageId | Should -Be 'demo'
            Assert-MockCalled Write-Warning -Times 1 -ParameterFilter { $Message -like '*count installed Chocolatey packages*' }
        }
    }

    It 'builds upgrade commands with escaped arguments' {
        New-ChocolateyUpgradeCommand -PackageId "O'Reilly.App" -Version '1.2.3' |
            Should -Be "choco upgrade 'O''Reilly.App' --version '1.2.3' --yes"
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
