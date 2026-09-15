$script:ProviderRegistry = [System.Collections.Specialized.OrderedDictionary]::new()

function Register-PackageProvider {
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$DisplayName,
        [Parameter(Mandatory)][string]$CollectorCommand
    )

    if ($script:ProviderRegistry.Contains($Id)) {
        throw "A package provider with ID '$Id' is already registered."
    }
    if ($null -eq (Get-Command $CollectorCommand -CommandType Function -ErrorAction SilentlyContinue)) {
        throw "The collector command '$CollectorCommand' for provider '$Id' was not found."
    }

    $script:ProviderRegistry.Add($Id, [pscustomobject]@{
            Id = $Id
            DisplayName = $DisplayName
            CollectorCommand = $CollectorCommand
        })
}

function Get-PackageProvider {
    param([Parameter(Mandatory)][string]$Id)

    foreach ($provider in $script:ProviderRegistry.Values) {
        if ($provider.Id -ieq $Id) {
            return $provider
        }
    }

    return $null
}

function Get-PackageProviders {
    return @($script:ProviderRegistry.Values)
}