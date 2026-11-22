$modulePath = Join-Path $PSScriptRoot '..\PSPackageOutdatedReporter.psm1'
Import-Module $modulePath -Force

Describe 'HTML package report' {
    BeforeEach {
        $script:reportPath = Join-Path $TestDrive 'PSPackageOutdatedReporter\Reports\report.html'
    }

    It 'writes an HTML report with linked table entries and escaped package data' {
        InModuleScope PSPackageOutdatedReporter -Parameters @{ testReportPath = $script:reportPath } {
            Mock Get-HtmlReportPath { $testReportPath }
            $installed = [PackageVersion]::new('1.0', $null, 'NotPublished', 'test')
            $latest = [PackageVersion]::new('2.0', $null, 'NotPublished', 'test')
            $target = [UpgradeTarget]::new($latest, 'winget upgrade <demo>')
            $package = [SoftwarePackage]::new('winget', 'demo', 'Demo & <App>', 'winget', $null, $installed, $latest, @($target), 'https://example.com/demo')

            $path = Write-HtmlPackageReport -Packages @($package)
            $html = Get-Content -LiteralPath $path -Raw

            $path | Should -Be $testReportPath
            $html | Should -Match '(?s)<h1>Upgradeable packages</h1>\s*<nav aria-label="Table of contents">\s*<h2>Contents</h2>.*?<a href="#package-manager-summary">Package manager summary</a>.*?<a href="#packages-by-name">Upgradeable packages \(sorted by software name\)</a>.*?<a href="#packages-by-installed-date">Upgradeable packages \(sorted by installed version release date, oldest first\)</a>.*?<a href="#packages-outside-cooldown">Upgradeable packages \(outside cooldown\)</a>.*?<a href="#package-details">Package details</a>.*?<a href="#package-0">Demo &amp; &lt;App&gt;</a>'
            $html | Should -Match '<h2 id="packages-by-name">'
            $html | Should -Match '<h2 id="packages-by-installed-date">'
            $html | Should -Match '<h2 id="packages-outside-cooldown">'
            $html | Should -Match '<h2 id="package-details">Package details</h2>'
            $html | Should -Match '<tr><td>winget</td><td>Unknown</td><td>1</td><td>1</td></tr>'
            $html | Should -Match '<a href="#package-0">Demo &amp; &lt;App&gt;</a>'
            $html | Should -Match 'id="package-0"'
            $html | Should -Match 'winget upgrade &lt;demo&gt;'
            $html | Should -Match 'class="command-line"'
            $html | Should -Match 'class="copy-button" data-command="winget upgrade &lt;demo&gt;"'
            $html | Should -Match '\.command-line\s*\{[^}]*background:\s*#1e1e1e;\s*color:\s*#f5f5f5;'
            $html | Should -Match '\.package:target\s*\{[^}]*background:\s*#fff8cc;[^}]*outline:\s*3px solid #d6a800;[^}]*outline-offset:\s*0?\.3rem;[^}]*scroll-margin-top:\s*1rem;'
            $html | Should -Match '\.command-line\s*\{[^}]*gap:\s*0?\.3rem;[^}]*padding:\s*0?\.2rem\s+0?\.4rem;'
            $html | Should -Match '\.copy-button\s*\{[^}]*padding:\s*0\s+0?\.2rem;'
            $html | Should -Match '\.command-line\s*\{[^}]*display:\s*inline-flex;\s*vertical-align:\s*middle;'
            $html | Should -Match '\.command-line code\s*\{[^}]*white-space:\s*pre;\s*overflow-wrap:\s*normal;\s*overflow-x:\s*auto;'
            $html | Should -Match '&#x1F4CB;'
            $html | Should -Match 'var original="\\uD83D\\uDCCB"'
            $html | Should -Match 'Copied!'
            $html | Should -Match 'setTimeout\(function\(\)\{button\.textContent=original;\},1500\)'
        }
    }

    It 'writes a useful report when there are no packages' {
        InModuleScope PSPackageOutdatedReporter -Parameters @{ testReportPath = $script:reportPath } {
            Mock Get-HtmlReportPath { $testReportPath }
            $path = Write-HtmlPackageReport -Packages @()
            $html = Get-Content -LiteralPath $path -Raw

            $html | Should -Match 'No upgradeable packages found.'
        }
    }

    It 'shows installed counts and zero upgrades when there are no upgradeable packages' {
        InModuleScope PSPackageOutdatedReporter {
            $html = ConvertTo-HtmlPackageReport -Packages @() -InstalledCounts @{ scoop = 14; winget = 0 } -UpgradeCheckResults @{ scoop = $true; winget = $true }

            $html | Should -Match '(?s)<h2 id="package-manager-summary">.*?<tr><td>scoop</td><td>14</td><td>0</td><td>0</td></tr>.*?<tr><td>winget</td><td>0</td><td>0</td><td>0</td></tr>.*?No upgradeable packages found\.'
        }
    }

    It 'shows unknown instead of zero when the upgrade check fails' {
        InModuleScope PSPackageOutdatedReporter {
            $html = ConvertTo-HtmlPackageReport -Packages @() -InstalledCounts @{ scoop = 14 } -UpgradeCheckResults @{ scoop = $false }

            $html | Should -Match '<tr><td>scoop</td><td>14</td><td>Unknown</td><td>Unknown</td></tr>'
            $html | Should -Match 'some package managers could not be checked'
            $html | Should -Not -Match 'No upgradeable packages found\.'
        }
    }

    It 'renders upgrade targets as nested bullets and shows the cooldown icon' {
        InModuleScope PSPackageOutdatedReporter {
            $installed = [PackageVersion]::new('1.0', $null, 'NotPublished', 'test')
            $latest = [PackageVersion]::new('2.0', $null, 'NotPublished', 'test')
            $latest.FirstObservedAt = [datetime]::Now
            $target = [UpgradeTarget]::new($latest, 'winget upgrade demo')
            $package = [SoftwarePackage]::new('winget', 'demo', 'Demo', 'winget', $null, $installed, $latest, @($target), $null)

            $html = ConvertTo-HtmlPackageReport -Packages @($package) -CooldownHours 168

            $html | Should -Match '(?s)<ul class="versions">\s*<li class="installed">.*?<ul>\s*<li><span class="upgrade">2\.0 .*?</span> <span class="cooldown">&#x1F9CA; cooldown'
            $html | Should -Match '\.installed\s*\{\s*color:\s*red;\s*\}'
            $html | Should -Match '\.upgrade\s*\{\s*color:\s*green;\s*\}'
            $html | Should -Match '\.cooldown\s*\{\s*color:\s*darkgray;\s*\}'
        }
    }

    It 'lists only packages with at least one upgrade candidate outside cooldown' {
        InModuleScope PSPackageOutdatedReporter {
            $installed = [PackageVersion]::new('1.0', $null, 'NotPublished', 'test')
            $eligible = [PackageVersion]::new('2.0', $null, 'NotPublished', 'test')
            $eligible.FirstObservedAt = [datetime]::Now.AddDays(-10)
            $coolingDown = [PackageVersion]::new('2.0', $null, 'NotPublished', 'test')
            $coolingDown.FirstObservedAt = [datetime]::Now
            $eligiblePackage = [SoftwarePackage]::new('winget', 'eligible', 'Eligible App', 'winget', $null, $installed, $eligible, @([UpgradeTarget]::new($eligible, 'winget upgrade eligible')), $null)
            $coolingDownPackage = [SoftwarePackage]::new('winget', 'cooling', 'Cooling App', 'winget', $null, $installed, $coolingDown, @([UpgradeTarget]::new($coolingDown, 'winget upgrade cooling')), $null)
            $otherManagerPackage = [SoftwarePackage]::new('scoop&<test>', 'other', 'Other App', 'main', $null, $installed, $coolingDown, @([UpgradeTarget]::new($coolingDown, 'scoop update other')), $null)

            $packages = @($eligiblePackage, $coolingDownPackage, $otherManagerPackage)
            $html = ConvertTo-HtmlPackageReport -Packages $packages -InstalledCounts @{ chocolatey = 7; 'scoop&<test>' = 0; winget = 9 } -UpgradeCheckResults @{ chocolatey = $true } -CooldownHours 168
            $outsideCooldownPackages = @(Get-ReportPackagesWithOutOfCooldownTargets -Packages $packages -CooldownHours 168)

            $outsideCooldownPackages.Count | Should -Be 1
            $outsideCooldownPackages[0].PackageId | Should -Be 'eligible'
            $html | Should -Match '(?s)<a href="#package-manager-summary">Package manager summary</a>.*?<h2 id="package-manager-summary">Package manager summary</h2>.*?<th>Manager</th><th>Installed packages</th><th>Upgradeable packages</th><th>Outside cooldown</th>.*?<tr><td>chocolatey</td><td>7</td><td>0</td><td>0</td></tr>.*?<tr><td>scoop&amp;&lt;test&gt;</td><td>0</td><td>1</td><td>0</td></tr>.*?<tr><td>winget</td><td>9</td><td>2</td><td>1</td></tr>.*?<h2 id="packages-by-name">'
            $html | Should -Match '(?s)<h2 id="packages-outside-cooldown">.*?<th>Available upgrade versions</th>.*?</thead><tbody>\s*<tr>.*?Eligible App.*?<td>2\.0</td>.*?</tr>\s*</tbody>'
            $html | Should -Not -Match '(?s)<h2 id="packages-outside-cooldown">.*?Cooling App.*?</tbody>'
        }
    }

    It 'opens the report only after the HTML file was written' {
        InModuleScope PSPackageOutdatedReporter {
            Mock Write-HtmlPackageReport { 'C:\Reports\report.html' }
            Mock Start-Process {}

            Write-OutdatedPackageReport -Packages @() -OutputFormat Html -OpenReport

            Assert-MockCalled Start-Process -Times 1 -Exactly -ParameterFilter {
                $FilePath -eq 'C:\Reports\report.html'
            }
        }
    }

    It 'does not open a report when writing it fails' {
        InModuleScope PSPackageOutdatedReporter {
            Mock Write-HtmlPackageReport { throw 'Unable to write report.' }
            Mock Start-Process {}

            { Write-OutdatedPackageReport -Packages @() -OutputFormat Html -OpenReport } | Should -Throw 'Unable to write report.'

            Assert-MockCalled Start-Process -Times 0 -Exactly
        }
    }
}
