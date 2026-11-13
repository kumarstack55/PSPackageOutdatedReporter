$modulePath = Join-Path $PSScriptRoot '..\PSPackageOutdatedReporter.psm1'
Import-Module $modulePath -Force

Describe 'Package provider registry' {
    It 'returns built-in providers in collection order' {
        InModuleScope PSPackageOutdatedReporter {
            @(Get-PackageProviders | ForEach-Object { $_.Id }) | Should -Be @('WinGet', 'Chocolatey', 'Scoop', 'DotNetTool')
        }
    }

    It 'resolves provider IDs without regard to case' {
        InModuleScope PSPackageOutdatedReporter {
            (Get-PackageProvider -Id 'chocolatey').CollectorCommand | Should -Be 'Get-ChocolateyUpgradeablePackages'
        }
    }
}

Describe 'Outdated package report orchestration' {
    It 'uses the shared seven-day cooldown default' {
        InModuleScope PSPackageOutdatedReporter {
            $script:DefaultCooldownHours | Should -Be 168

            $cache = @{ schemaVersion = 1; entries = @{} }
            Mock Get-ReleaseDateCache { $cache }
            Mock Get-WinGetUpgradeablePackages { @() }
            Mock Save-ReleaseDateCache {}
            Mock Write-OutdatedPackageReport {}
            Mock Write-StageStatus {}

            Invoke-OutdatedPackageReport -PackageManager WinGet -CachePath (Join-Path $TestDrive 'cache.json')

            Assert-MockCalled Write-OutdatedPackageReport -Times 1 -Exactly -ParameterFilter {
                $CooldownHours -eq $script:DefaultCooldownHours
            }
        }
    }

    It 'collects selected providers and forwards their packages to the report' {
        InModuleScope PSPackageOutdatedReporter {
            $cache = @{ schemaVersion = 1; entries = @{} }

            Mock Get-ReleaseDateCache { $cache }
            Mock Get-WinGetUpgradeablePackages { @() }
            Mock Get-ChocolateyUpgradeablePackages { @() }
            Mock Get-ScoopUpgradeablePackages { @() }
            Mock Get-DotNetToolUpgradeablePackages { @() }
            Mock Save-ReleaseDateCache {}
            Mock Write-OutdatedPackageReport {}
            Mock Write-StageStatus {}

            Invoke-OutdatedPackageReport -PackageManager 'WinGet', 'Scoop' -Source 'main' -CacheTtlHours 12 -MaxUpgradeVersions 3 -CachePath (Join-Path $TestDrive 'cache.json') -CooldownHours 48

            Assert-MockCalled Get-WinGetUpgradeablePackages -Times 1 -Exactly -ParameterFilter {
                $CacheTtlHours -eq 12 -and $MaxUpgradeVersions -eq 3 -and $SourceFilter -eq 'main'
            }
            Assert-MockCalled Get-ScoopUpgradeablePackages -Times 1 -Exactly -ParameterFilter {
                $CacheTtlHours -eq 12 -and $MaxUpgradeVersions -eq 3 -and $SourceFilter -eq 'main'
            }
            Assert-MockCalled Get-ChocolateyUpgradeablePackages -Times 0 -Exactly
            Assert-MockCalled Save-ReleaseDateCache -Times 1 -Exactly
            Assert-MockCalled Write-OutdatedPackageReport -Times 1 -Exactly -ParameterFilter {
                $Packages.Count -eq 0 -and $CooldownHours -eq 48 -and $OutputFormat -eq 'Console' -and -not $OpenReport
            }
        }
    }

    It 'forwards the selected Html format to the report' {
        InModuleScope PSPackageOutdatedReporter {
            $cache = @{ schemaVersion = 1; entries = @{} }

            Mock Get-ReleaseDateCache { $cache }
            Mock Get-WinGetUpgradeablePackages { @() }
            Mock Save-ReleaseDateCache {}
            Mock Write-OutdatedPackageReport {}
            Mock Write-StageStatus {}

            Invoke-OutdatedPackageReport -PackageManager WinGet -CachePath (Join-Path $TestDrive 'cache.json') -OutputFormat Html

            Assert-MockCalled Write-OutdatedPackageReport -Times 1 -Exactly -ParameterFilter {
                $Packages.Count -eq 0 -and $OutputFormat -eq 'Html' -and -not $OpenReport
            }
        }
    }

    It 'rejects opening a report in Console format before reading the cache' {
        InModuleScope PSPackageOutdatedReporter {
            Mock Get-ReleaseDateCache {}

            {
                Invoke-OutdatedPackageReport -OpenReport -CachePath (Join-Path $TestDrive 'cache.json')
            } | Should -Throw '*-OpenReport can only be used with -OutputFormat Html*'

            Assert-MockCalled Get-ReleaseDateCache -Times 0 -Exactly
        }
    }

    It 'rejects an unregistered provider before reading the cache' {
        InModuleScope PSPackageOutdatedReporter {
            Mock Get-ReleaseDateCache {}

            {
                Invoke-OutdatedPackageReport -PackageManager 'Unknown' -CachePath (Join-Path $TestDrive 'cache.json')
            } | Should -Throw "*Unsupported package manager 'Unknown'*"

            Assert-MockCalled Get-ReleaseDateCache -Times 0 -Exactly
        }
    }
}