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

            $summary = @(Get-ReportPackageManagerSummary -Packages $packages -InstalledCounts @{ scoop = 0; winget = 9 } -CooldownHours 168)

            $summary.Count | Should -Be 2
            $summary[0].Manager | Should -Be 'scoop'
            $summary[0].InstalledPackages | Should -Be 0
            $summary[0].UpgradeablePackages | Should -Be 1
            $summary[0].OutsideCooldown | Should -Be 0
            $summary[1].Manager | Should -Be 'winget'
            $summary[1].InstalledPackages | Should -Be 9
            $summary[1].UpgradeablePackages | Should -Be 2
            $summary[1].OutsideCooldown | Should -Be 1
            @(Get-ReportPackageManagerSummary -Packages @()).Count | Should -Be 0
            @(Get-ReportPackageManagerSummary -Packages $packages)[0].InstalledPackages | Should -Be 'Unknown'
        }
    }

    It 'writes the summary before the detailed console table' {
        InModuleScope PSPackageOutdatedReporter {
            $installed = [PackageVersion]::new('1.0', $null, 'NotPublished', 'test')
            $latest = [PackageVersion]::new('2.0', [datetime]::Now.AddDays(-10), 'Published', 'test')
            $package = [SoftwarePackage]::new('winget', 'demo', 'Demo', 'winget', $null, $installed, $latest, @([UpgradeTarget]::new($latest, 'upgrade demo')), $null)
            Mock Get-ReportPackageManagerSummary {
                [pscustomobject]@{ Manager = 'winget'; InstalledPackages = 5; UpgradeablePackages = 1; OutsideCooldown = 1 }
            }

            $output = (Write-ConsolePackageReport -Packages @($package) -InstalledCounts @{ winget = 5 } -CooldownHours 168 6>&1 | Out-String)

            $output | Should -Match '(?s)## Package manager summary.*?## Upgradeable packages \(sorted by software name\)'
            Assert-MockCalled Get-ReportPackageManagerSummary -Times 1 -Exactly -ParameterFilter {
                $Packages.Count -eq 1 -and $InstalledCounts.winget -eq 5 -and $CooldownHours -eq 168
            }
        }
    }

    It 'includes managers without upgrades and distinguishes failed checks' {
        InModuleScope PSPackageOutdatedReporter {
            $summary = @(Get-ReportPackageManagerSummary -Packages @() -InstalledCounts @{ scoop = 14; winget = $null; chocolatey = 5 } -UpgradeCheckResults @{ scoop = $true; winget = $false; chocolatey = $false })

            $summary.Count | Should -Be 3
            $summary[0].Manager | Should -Be 'chocolatey'
            $summary[0].InstalledPackages | Should -Be 5
            $summary[0].UpgradeablePackages | Should -Be 'Unknown'
            $summary[0].OutsideCooldown | Should -Be 'Unknown'
            $summary[1].Manager | Should -Be 'scoop'
            $summary[1].InstalledPackages | Should -Be 14
            $summary[1].UpgradeablePackages | Should -Be 0
            $summary[1].OutsideCooldown | Should -Be 0
            $summary[2].InstalledPackages | Should -Be 'Unknown'
            $summary[2].UpgradeablePackages | Should -Be 'Unknown'
        }
    }

    It 'writes a console summary even when there are no upgrades' {
        InModuleScope PSPackageOutdatedReporter {
            Mock Get-ReportPackageManagerSummary {
                [pscustomobject]@{ Manager = 'scoop'; InstalledPackages = 14; UpgradeablePackages = 0; OutsideCooldown = 0 }
            }

            $output = (Write-ConsolePackageReport -Packages @() -InstalledCounts @{ scoop = 14 } -UpgradeCheckResults @{ scoop = $true } 6>&1 | Out-String)

            $output | Should -Match '(?s)## Package manager summary.*No upgradeable packages found\.'
            Assert-MockCalled Get-ReportPackageManagerSummary -Times 1 -Exactly -ParameterFilter {
                $Packages.Count -eq 0 -and $InstalledCounts.scoop -eq 14 -and $UpgradeCheckResults.scoop
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

    It 'forwards installed counts with the collected packages to the report' {
        InModuleScope PSPackageOutdatedReporter {
            $cache = @{ schemaVersion = 1; entries = @{} }
            Mock Get-ReleaseDateCache { $cache }
            Mock Save-ReleaseDateCache {}
            Mock Write-StageStatus {}
            Mock Write-OutdatedPackageReport {}
            Mock Get-WinGetUpgradeablePackages {
                $InstalledCount.Value = 12
                $UpgradeCheckSucceeded.Value = $true
                $installed = [PackageVersion]::new('1.0', $null, 'NotPublished', 'test')
                $latest = [PackageVersion]::new('2.0', $null, 'NotPublished', 'test')
                [SoftwarePackage]::new('winget', 'demo', 'Demo', 'winget', $null, $installed, $latest, @([UpgradeTarget]::new($latest, 'upgrade demo')), $null)
            }

            Invoke-OutdatedPackageReport -PackageManager WinGet -CachePath (Join-Path $TestDrive 'cache.json')

            Assert-MockCalled Write-OutdatedPackageReport -Times 1 -Exactly -ParameterFilter {
                $Packages.Count -eq 1 -and $InstalledCounts.winget -eq 12 -and $UpgradeCheckResults.winget
            }
        }
    }

    It 'forwards counts and check results when a manager has no upgrades' {
        InModuleScope PSPackageOutdatedReporter {
            Mock Get-ReleaseDateCache { @{ schemaVersion = 1; entries = @{} } }
            Mock Save-ReleaseDateCache {}
            Mock Write-StageStatus {}
            Mock Write-OutdatedPackageReport {}
            Mock Get-ScoopUpgradeablePackages {
                $InstalledCount.Value = 14
                $UpgradeCheckSucceeded.Value = $true
            }
            Mock Get-DotNetToolUpgradeablePackages {
                $InstalledCount.Value = 3
                $UpgradeCheckSucceeded.Value = $false
            }

            Invoke-OutdatedPackageReport -PackageManager Scoop, DotNetTool -CachePath (Join-Path $TestDrive 'cache.json')

            Assert-MockCalled Write-OutdatedPackageReport -Times 1 -Exactly -ParameterFilter {
                $Packages.Count -eq 0 -and $InstalledCounts.scoop -eq 14 -and $UpgradeCheckResults.scoop -and
                $InstalledCounts['dotnet-tool'] -eq 3 -and -not $UpgradeCheckResults['dotnet-tool']
            }
        }
    }

    It 'writes a Scoop summary through the full HTML report path when no updates are available' {
        InModuleScope PSPackageOutdatedReporter {
            function scoop {}
            Mock Get-Command { [pscustomobject]@{ Name = 'scoop' } } -ParameterFilter { $Name -eq 'scoop' }
            Mock scoop {
                $global:LASTEXITCODE = 0
                if ($args[0] -eq 'list') {
                    [pscustomobject]@{ Name = 'one' }
                    [pscustomobject]@{ Name = 'two' }
                }
            }
            Mock Get-ReleaseDateCache { @{ schemaVersion = 1; entries = @{} } }
            Mock Save-ReleaseDateCache {}
            Mock Write-StageStatus {}
            Mock Get-HtmlReportPath { Join-Path $TestDrive 'summary.html' }

            Invoke-OutdatedPackageReport -PackageManager Scoop -OutputFormat Html -CachePath (Join-Path $TestDrive 'cache.json')
            $html = Get-Content -LiteralPath (Join-Path $TestDrive 'summary.html') -Raw

            $html | Should -Match '<tr><td>scoop</td><td>2</td><td>0</td><td>0</td></tr>'
            $html | Should -Match 'No upgradeable packages found\.'
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

    It 'rejects an invalid package manager before reading the cache' {
        InModuleScope PSPackageOutdatedReporter {
            Mock Get-ReleaseDateCache {}

            {
                Invoke-OutdatedPackageReport -PackageManager 'Unknown' -CachePath (Join-Path $TestDrive 'cache.json')
            } | Should -Throw -ErrorId 'ParameterArgumentValidationError,Invoke-OutdatedPackageReport'

            Assert-MockCalled Get-ReleaseDateCache -Times 0 -Exactly
        }
    }

    It 'rejects an unregistered provider before reading the cache' {
        InModuleScope PSPackageOutdatedReporter {
            Mock Get-PackageProvider { $null }
            Mock Get-ReleaseDateCache {}

            {
                Invoke-OutdatedPackageReport -PackageManager 'WinGet' -CachePath (Join-Path $TestDrive 'cache.json')
            } | Should -Throw "*Unsupported package manager 'WinGet'*"

            Assert-MockCalled Get-ReleaseDateCache -Times 0 -Exactly
        }
    }
}
