function ConvertTo-PowerShellSingleQuotedArgument {
    param([Parameter(Mandatory)][string]$Value)

    return "'$($Value.Replace("'", "''"))'"
}

function Get-NormalizedPackageVersion {
    param([Parameter(Mandatory)][string]$Version)

    $match = [regex]::Match($Version, '^\d+(\.\d+){0,3}')
    if (-not $match.Success) {
        return $null
    }

    $parts = @($match.Value -split '\.')
    while ($parts.Count -lt 4) {
        $parts += '0'
    }

    return [version]::new([int]$parts[0], [int]$parts[1], [int]$parts[2], [int]$parts[3])
}

function Test-IsOlderPackageVersion {
    param(
        [Parameter(Mandatory)][string]$CandidateVersion,
        [Parameter(Mandatory)][string]$BaselineVersion
    )

    $candidateNormalized = Get-NormalizedPackageVersion -Version $CandidateVersion
    $baselineNormalized = Get-NormalizedPackageVersion -Version $BaselineVersion
    if ($null -eq $candidateNormalized -or $null -eq $baselineNormalized) {
        return $false
    }

    return $candidateNormalized -lt $baselineNormalized
}
