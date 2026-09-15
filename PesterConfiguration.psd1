@{
    Run = @{
        Path = '.\tests'
    }

    CodeCoverage = @{
        Enabled = $true
        Path = @(
            '.\Invoke-ReportPackageOutdated.ps1'
            '.\Private\*.ps1'
            '.\Private\Providers\*.ps1'
        )
        CoveragePercentTarget = 0
    }
}