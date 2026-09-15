$modulePath = Join-Path $PSScriptRoot '..\..\PSPackageOutdatedReporter.psm1'
Import-Module $modulePath -Force

Describe 'Scoop provider' {
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