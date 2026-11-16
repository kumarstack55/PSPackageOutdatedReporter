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

Describe 'Package manager summary' {
    It 'counts packages once per manager when at least one visible target is outside cooldown' {
        InModuleScope PSPackageOutdatedReporter {
            $installed = [PackageVersion]::new('1.0', $null, 'NotPublished', 'test')
            $old = [PackageVersion]::new('2.0', [datetime]::Now.AddDays(-10), 'Published', 'test')
            $older = [PackageVersion]::new('1.5', [datetime]::Now.AddDays(-10), 'Published', 'test')
            $recent = [PackageVersion]::new('3.0', [datetime]::Now, 'Published', 'test')
            $same = [PackageVersion]::new('1.0', [datetime]::Now.AddDays(-10), 'Published', 'test')
            $packages = @(
                [SoftwarePackage]::new('winget', 'a', 'A', 'winget', $null, $installed, $recent, @([UpgradeTarget]::new($recent, 'a'), [UpgradeTarget]::new($old, 'a'), [UpgradeTarget]::new($older, 'a')), $null)
                [SoftwarePackage]::new('winget', 'b', 'B', 'winget', $null, $installed, $recent, @([UpgradeTarget]::new($recent, 'b'), [UpgradeTarget]::new($same, 'b')), $null)
                [SoftwarePackage]::new('scoop', 'c', 'C', 'main', $null, $installed, $recent, @([UpgradeTarget]::new($recent, 'c')), $null)
            )

            $summary = @(Get-ReportPackageManagerSummary -Packages $packages -CooldownHours 168)

            $summary.Count | Should -Be 2
            $summary[0].Manager | Should -Be 'scoop'
            $summary[0].UpgradeablePackages | Should -Be 1
            $summary[0].OutsideCooldown | Should -Be 0
            $summary[1].Manager | Should -Be 'winget'
            $summary[1].UpgradeablePackages | Should -Be 2
            $summary[1].OutsideCooldown | Should -Be 1
            @(Get-ReportPackageManagerSummary -Packages @()).Count | Should -Be 0
        }
    }

    It 'writes the summary before the detailed console table' {
        InModuleScope PSPackageOutdatedReporter {
            $installed = [PackageVersion]::new('1.0', $null, 'NotPublished', 'test')
            $latest = [PackageVersion]::new('2.0', [datetime]::Now.AddDays(-10), 'Published', 'test')
            $package = [SoftwarePackage]::new('winget', 'demo', 'Demo', 'winget', $null, $installed, $latest, @([UpgradeTarget]::new($latest, 'upgrade demo')), $null)
            Mock Get-ReportPackageManagerSummary {
                [pscustomobject]@{ Manager = 'winget'; UpgradeablePackages = 1; OutsideCooldown = 1 }
            }

            $output = (Write-ConsolePackageReport -Packages @($package) -CooldownHours 168 6>&1 | Out-String)

            $output | Should -Match '(?s)## Package manager summary.*?## Upgradeable packages \(sorted by software name\)'
            Assert-MockCalled Get-ReportPackageManagerSummary -Times 1 -Exactly -ParameterFilter {
                $Packages.Count -eq 1 -and $CooldownHours -eq 168
            }
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
