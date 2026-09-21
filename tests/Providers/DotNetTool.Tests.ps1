$modulePath = Join-Path $PSScriptRoot '..\..\PSPackageOutdatedReporter.psm1'
Import-Module $modulePath -Force

Describe 'dotnet tool provider' {
    It 'builds an update command' {
        New-DotNetToolUpgradeCommand -PackageId 'demo.tool' -Version '1.2.3' |
            Should -Be "dotnet tool update --global 'demo.tool' --version '1.2.3'"
    }

    It 'reports a globally installed tool when NuGet has a newer stable version' {
        InModuleScope PSPackageOutdatedReporter {
            Mock Get-Command { [pscustomobject]@{ Name = 'dotnet' } }
            Mock dotnet {
                $global:LASTEXITCODE = 0
                '{"version":1,"data":[{"packageId":"demo.tool","version":"1.0.0","commands":["demo"]}]}'
            }
            Mock Invoke-WebRequest {
                [pscustomobject]@{ Content = '{"versions":["0.9.0","1.0.0","1.2.0","1.1.0-beta"]}' }
            }
            $cache = @{ schemaVersion = 1; entries = @{} }

            $result = @(Get-DotNetToolUpgradeablePackages -Cache $cache -CacheTtlHours 24 -MaxUpgradeVersions 2)

            $result.Count | Should -Be 1
            $result[0].PackageManagerId | Should -Be 'dotnet-tool'
            $result[0].InstalledVersion.Version | Should -Be '1.0.0'
            $result[0].LatestVersion.Version | Should -Be '1.2.0'
            $result[0].UpgradeTargets.Count | Should -Be 1
            $result[0].UpgradeTargets[0].Command | Should -Be "dotnet tool update --global 'demo.tool' --version '1.2.0'"
        }
    }

    It 'marks dotnet tool versions as not published and caches the result' {
        $cache = @{ schemaVersion = 1; entries = @{} }

        $result = Resolve-DotNetToolReleaseDate -PackageId 'demo.tool' -Version '1.2.0' -CandidateSource 'nuget.org' -Cache $cache -CacheTtlHours 24

        $result.ReleaseDateStatus | Should -Be 'NotPublished'
        $cache.entries.Count | Should -Be 1
    }
}