# PSPackageOutdatedReporter

Reports installed packages that WinGet or Chocolatey can upgrade. For each package it prints:

- Package manager, package name, and candidate source.
- Installed version and its manifest release date when available.
- The latest upgrade target and its manifest release date when available.
- Up to ten version-specific upgrade commands.

The script reports only. It never performs an upgrade.

## Requirements

- Windows with WinGet and/or Chocolatey available.
- Windows PowerShell 5.1.
- The `Microsoft.WinGet.Client` module when reporting WinGet packages.
- Network access to `raw.githubusercontent.com` and `community.chocolatey.org` for release dates.

Install the module for the current user:

```powershell
Install-Module Microsoft.WinGet.Client -Scope CurrentUser
```

## Usage

```powershell
.\Invoke-ReportPackageOutdated.ps1
.\Invoke-ReportPackageOutdated.ps1 -PackageManager Chocolatey
.\Invoke-ReportPackageOutdated.ps1 -PackageManager WinGet, Chocolatey
.\Invoke-ReportPackageOutdated.ps1 -Source winget -MaxUpgradeVersions 1
.\Invoke-ReportPackageOutdated.ps1 -ClearCache
```

`-PackageManager` defaults to `WinGet, Chocolatey`. `-Source` filters by the candidate catalog source. `-MaxUpgradeVersions` defaults to `10`; a manager may expose fewer available versions for a package. `-CacheTtlHours` defaults to `24`.

## Release dates

WinGet does not provide version release dates through `Microsoft.WinGet.Client`. For packages resolved from the official `winget` source, the script retrieves the optional `ReleaseDate` field from the matching version manifest in `microsoft/winget-pkgs`.

For Chocolatey packages, the script reads the `Published` field from the Chocolatey Community Package Repository OData endpoint. `choco outdated` does not identify the source that supplied an individual package, so Chocolatey results are treated as the public `chocolatey` source. A package supplied only by a private feed may therefore show `LookupFailed` or a date from a public package with the same ID and version. Private-feed source attribution is not implemented.

Dates are deliberately not inferred from Git commits, repository registration dates, or installer file timestamps. The report therefore shows one of these states when no date is available:

- `NotPublished`: the official manifest has no `ReleaseDate`.
- `UnsupportedSource`: the candidate came from a non-official source such as `msstore` or a private source.
- `LookupFailed`: the manifest could not be retrieved, including a version that has no matching official manifest.
- `InvalidReleaseDate`: the manifest date was not a valid `yyyy-MM-dd` value.

## Sources and identity

`PackageManagerId` identifies the package manager, such as `winget`, `chocolatey`, or `scoop`.

`CandidateSource` identifies the catalog used to resolve the upgrade candidate:

- WinGet: source name, for example `winget`, `msstore`, or an organization source.
- Chocolatey: currently the public `chocolatey` source. Chocolatey does not expose per-package feed provenance in `outdated --limit-output`.
- Scoop: bucket name, for example `main`, `extras`, or `nonportable`.

`InstalledSource` is separate because a package manager may not retain reliable installation provenance. The WinGet module does not expose it for the installed-package object, so it is currently empty. A package is identified internally by package manager, candidate source, package ID, and version.

## Cache

The default persistent cache is:

```text
%LOCALAPPDATA%\PSPackageOutdatedReporter\release-date-cache.json
```

It is a single JSON file with a versioned schema and entries keyed by `manager|candidateSource|packageId|version`. Positive and negative release-date results are cached. Writes use a temporary file followed by replacement to avoid partial JSON files.

## Roadmap

The report models are package-manager neutral. Scoop will be added as its own discovery and release-date resolver implementation; its source rules and metadata APIs remain manager-specific.
