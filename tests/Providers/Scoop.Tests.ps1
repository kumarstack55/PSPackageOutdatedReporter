$modulePath = Join-Path $PSScriptRoot '..\..\PSPackageOutdatedReporter.psm1'
Import-Module $modulePath -Force

Describe 'Scoop provider' {
    It 'counts installed Scoop apps from list output' {
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
            $count = $null
            $checkSucceeded = $false

            $result = @(Get-ScoopUpgradeablePackages -Cache @{} -CacheTtlHours 24 -MaxUpgradeVersions 1 -InstalledCount ([ref]$count) -UpgradeCheckSucceeded ([ref]$checkSucceeded))

            $result.Count | Should -Be 0
            $count | Should -Be 2
            $checkSucceeded | Should -BeTrue
        }
    }

    It 'reports an unsuccessful upgrade check separately from the installed count' {
        InModuleScope PSPackageOutdatedReporter {
            function scoop {}
            Mock Get-Command { [pscustomobject]@{ Name = 'scoop' } } -ParameterFilter { $Name -eq 'scoop' }
            Mock scoop {
                if ($args[0] -eq 'list') {
                    $global:LASTEXITCODE = 0
                    [pscustomobject]@{ Name = 'one' }
                }
                else {
                    $global:LASTEXITCODE = 1
                }
            }
            Mock Write-Warning {}
            $count = $null
            $checkSucceeded = $true

            Get-ScoopUpgradeablePackages -Cache @{} -CacheTtlHours 24 -MaxUpgradeVersions 1 -InstalledCount ([ref]$count) -UpgradeCheckSucceeded ([ref]$checkSucceeded)

            $count | Should -Be 1
            $checkSucceeded | Should -BeFalse
            Assert-MockCalled Write-Warning -Times 1 -ParameterFilter { $Message -like '*query Scoop packages*' }
        }
    }

    It 'counts zero when Scoop reports that no apps are installed' {
        InModuleScope PSPackageOutdatedReporter {
            function scoop {}
            Mock Get-Command { [pscustomobject]@{ Name = 'scoop' } } -ParameterFilter { $Name -eq 'scoop' }
            Mock scoop {
                if ($args[0] -eq 'list') {
                    $global:LASTEXITCODE = 1
                    Write-Host "WARN  There aren't any apps installed."
                }
                else {
                    $global:LASTEXITCODE = 0
                }
            }
            $count = $null
            $checkSucceeded = $false

            Get-ScoopUpgradeablePackages -Cache @{} -CacheTtlHours 24 -MaxUpgradeVersions 1 -InstalledCount ([ref]$count) -UpgradeCheckSucceeded ([ref]$checkSucceeded)

            $count | Should -Be 0
            $checkSucceeded | Should -BeTrue
        }
    }

    It 'warns and leaves the count unknown for malformed list output' {
        InModuleScope PSPackageOutdatedReporter {
            function scoop {}
            Mock Get-Command { [pscustomobject]@{ Name = 'scoop' } } -ParameterFilter { $Name -eq 'scoop' }
            Mock scoop {
                $global:LASTEXITCODE = 0
                if ($args[0] -eq 'list') { 'unexpected output' }
            }
            Mock Write-Warning {}
            $count = 9

            Get-ScoopUpgradeablePackages -Cache @{} -CacheTtlHours 24 -MaxUpgradeVersions 1 -InstalledCount ([ref]$count)

            $count | Should -BeNullOrEmpty
            Assert-MockCalled Write-Warning -Times 1 -ParameterFilter { $Message -like '*count installed Scoop packages*' }
        }
    }

    It 'builds a Scoop upgrade command' {
        New-ScoopUpgradeCommand -PackageId "O'Reilly.App" -Version '1.2.3' |
            Should -Be "scoop install 'O''Reilly.App@1.2.3'; scoop reset 'O''Reilly.App@1.2.3'"
    }

    It 'marks Scoop release dates as unpublished and caches the result' {
        $cache = @{ schemaVersion = 1; entries = @{} }

        $result = Resolve-ScoopReleaseDate -PackageId 'demo' -Version '1.2.3' -CandidateSource 'main' -Cache $cache -CacheTtlHours 24

        $result.ReleaseDateStatus | Should -Be 'NotPublished'
        $cache.entries.Count | Should -Be 1
        $cache.entries.Values[0].firstObservedAt | Should -Not -BeNullOrEmpty
        $result.FirstObservedAt | Should -Not -BeNullOrEmpty
    }
}