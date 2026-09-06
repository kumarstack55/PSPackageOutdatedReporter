# PSPackageOutdatedReporter

Reports installed packages that WinGet, Chocolatey, or Scoop can upgrade. For each package it prints:

- Package manager, package name, and candidate source.
- Installed version and its manifest release date when available.
- The latest upgrade target and its manifest release date when available.
- Up to ten version-specific upgrade commands.

The script reports only. It never performs an upgrade.

## Requirements

- Windows with WinGet, Chocolatey, and/or Scoop available.
- Windows PowerShell 5.1.
- The `Microsoft.WinGet.Client` module when reporting WinGet packages.
- Network access to `raw.githubusercontent.com` and `community.chocolatey.org` for release dates.

Install the module for the current user:

```powershell
Install-Module Microsoft.WinGet.Client -Scope CurrentUser
```

## Installation

Clone the repository and create a shortcut in the current user's Startup folder. The shortcut runs the report at sign-in and keeps the PowerShell window open for 60 seconds after the report finishes.

Run the following in Windows PowerShell 5.1. Replace the repository URL if your repository is hosted elsewhere.

```powershell
$repoPath = Join-Path $HOME 'PSPackageOutdatedReporter'
git clone https://github.com/wabik/PSPackageOutdatedReporter.git $repoPath
Set-Location $repoPath

$startupPath = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup'
$shortcutPath = Join-Path $startupPath 'PSPackageOutdatedReporter.lnk'
$scriptPath = Join-Path $repoPath 'Invoke-ReportPackageOutdated.ps1'
$powershellPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut($shortcutPath)
$shortcut.TargetPath = $powershellPath
$shortcut.Arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "& ''{0}''; Start-Sleep -Seconds 60"' -f $scriptPath
$shortcut.WorkingDirectory = $repoPath
$shortcut.Description = 'Report outdated packages'
$shortcut.Save()
```

To remove the automatic execution, delete the shortcut:

```powershell
Remove-Item (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup\PSPackageOutdatedReporter.lnk')
```

## Usage

```powershell
.\Invoke-ReportPackageOutdated.ps1
.\Invoke-ReportPackageOutdated.ps1 -PackageManager Chocolatey
.\Invoke-ReportPackageOutdated.ps1 -PackageManager WinGet, Chocolatey
.\Invoke-ReportPackageOutdated.ps1 -PackageManager Scoop
.\Invoke-ReportPackageOutdated.ps1 -Source winget -MaxUpgradeVersions 1
.\Invoke-ReportPackageOutdated.ps1 -ClearCache

# or

powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command ".\Invoke-ReportPackageOutdated.ps1"
```

`-PackageManager` defaults to `WinGet, Chocolatey, Scoop`. `-Source` filters by the candidate catalog source. `-MaxUpgradeVersions` defaults to `10`; a manager may expose fewer available versions for a package. `-CacheTtlHours` defaults to `24`.

## Tests

The internal functions are exposed through `PSPackageOutdatedReporter.psm1`. Importing the module does not run a report, so the functions can be tested without invoking WinGet, Chocolatey, or the network.

Install Pester 5 if needed, then run the tests from Windows PowerShell 5.1:

```powershell
Install-Module Pester -Scope CurrentUser -MinimumVersion 5.0

Invoke-Pester .\tests
# or
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "Invoke-Pester -Path .\tests"
```

The user-facing interface remains `Invoke-ReportPackageOutdated.ps1`; the module is an internal testability boundary.

## Release dates

WinGet does not provide version release dates through `Microsoft.WinGet.Client`. For packages resolved from the official `winget` source, the script retrieves the optional `ReleaseDate` field from the matching version manifest in `microsoft/winget-pkgs`.

For Chocolatey packages, the script reads the `Published` field from the Chocolatey Community Package Repository OData endpoint. `choco outdated` does not identify the source that supplied an individual package, so Chocolatey results are treated as the public `chocolatey` source. A package supplied only by a private feed may therefore show `LookupFailed` or a date from a public package with the same ID and version. Private-feed source attribution is not implemented.

Scoop packages are discovered by parsing `scoop status`; the bucket name is obtained from `scoop info`. Scoop manifests do not provide a reliable release date, so Scoop versions are reported as `NotPublished`.

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
