function ConvertTo-HtmlReportText {
    param([AllowNull()][string]$Value)

    if ($null -eq $Value) {
        return ''
    }

    return [System.Net.WebUtility]::HtmlEncode($Value)
}

function Get-HtmlReportPath {
    $documentsPath = [Environment]::GetFolderPath('MyDocuments')
    if ([string]::IsNullOrWhiteSpace($documentsPath)) {
        throw 'The Documents folder could not be resolved.'
    }

    return Join-Path $documentsPath 'PSPackageOutdatedReporter\Reports\report.html'
}

function Get-HtmlReportInfoLink {
    param([AllowNull()][string]$Url)

    if ([string]::IsNullOrWhiteSpace($Url)) {
        return ''
    }

    $uri = $null
    if (-not [uri]::TryCreate($Url, [System.UriKind]::Absolute, [ref]$uri) -or
        $uri.Scheme -notin @('http', 'https')) {
        return ''
    }

    $encodedUrl = ConvertTo-HtmlReportText -Value $uri.AbsoluteUri
    return "<a href=`"$encodedUrl`">$encodedUrl</a>"
}

function ConvertTo-HtmlPackageReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][SoftwarePackage[]]$Packages,
        [int]$CooldownHours = $script:DefaultCooldownHours
    )

    $entries = @()
    $sortedPackages = @($Packages | Sort-Object DisplayName, CandidateSource)
    for ($index = 0; $index -lt $sortedPackages.Count; $index++) {
        $entries += [pscustomobject]@{
            Package = $sortedPackages[$index]
            Anchor = "package-$index"
        }
    }

    $builder = [System.Text.StringBuilder]::new()
    $null = $builder.AppendLine('<!doctype html>')
    $null = $builder.AppendLine('<html lang="en">')
    $null = $builder.AppendLine('<head>')
    $null = $builder.AppendLine('<meta charset="utf-8">')
    $null = $builder.AppendLine('<meta name="viewport" content="width=device-width, initial-scale=1">')
    $null = $builder.AppendLine('<title>PSPackageOutdatedReporter</title>')
    $null = $builder.AppendLine('<style>')
    $null = $builder.AppendLine('body{font-family:Segoe UI,Arial,sans-serif;line-height:1.5;margin:2rem;color:#222}table{border-collapse:collapse;width:100%;margin:1rem 0 2rem}th,td{border:1px solid #ccc;padding:.4rem .6rem;text-align:left;vertical-align:top}th{background:#f2f2f2}.package{border-top:1px solid #aaa;margin-top:2rem;padding-top:1rem}.versions{padding-left:1.5rem}.installed{color:red}.upgrade{color:green}.cooldown{color:darkgray}.command-line{display:inline-flex;vertical-align:middle;align-items:center;gap:.3rem;background:#1e1e1e;color:#f5f5f5;padding:.2rem .4rem;border-radius:4px;max-width:calc(100% - 1rem);box-sizing:border-box;white-space:nowrap}.command-line code{color:inherit;white-space:pre;overflow-wrap:normal;overflow-x:auto;flex:1;min-width:0}.copy-button{flex:none;cursor:pointer;background:#333;color:#fff;border:1px solid #777;border-radius:3px;padding:0 .2rem}.copy-button:hover{background:#4b4b4b}.copy-button:focus-visible{outline:2px solid #8ab4f8;outline-offset:2px}')
    $null = $builder.AppendLine('</style>')
    $null = $builder.AppendLine('<script>')
    $null = $builder.AppendLine('function fallbackCopy(text){var field=document.createElement("textarea");field.value=text;field.setAttribute("readonly","");field.style.position="fixed";field.style.opacity="0";document.body.appendChild(field);field.select();var copied=false;try{copied=document.execCommand("copy");}finally{document.body.removeChild(field);}return copied;}')
    $null = $builder.AppendLine('function copyCommand(button){var command=button.getAttribute("data-command");var original="\uD83D\uDCCB";function showResult(copied){button.textContent=copied?"Copied!":"Copy failed";window.setTimeout(function(){button.textContent=original;},1500);}if(navigator.clipboard&&navigator.clipboard.writeText){navigator.clipboard.writeText(command).then(function(){showResult(true);},function(){showResult(fallbackCopy(command));});}else{showResult(fallbackCopy(command));}}')
    $null = $builder.AppendLine('</script>')
    $null = $builder.AppendLine('</head>')
    $null = $builder.AppendLine('<body>')
    $null = $builder.AppendLine('<h1>Upgradeable packages</h1>')

    if ($entries.Count -gt 0) {
        $tableSections = @(
            [pscustomobject]@{ Title = 'Upgradeable packages (sorted by software name)'; Anchor = 'packages-by-name'; SortByName = $true },
            [pscustomobject]@{ Title = 'Upgradeable packages (sorted by installed version release date, oldest first)'; Anchor = 'packages-by-installed-date'; SortByName = $false },
            [pscustomobject]@{ Title = 'Upgradeable packages (outside cooldown)'; Anchor = 'packages-outside-cooldown'; SortByName = $true; OutsideCooldownOnly = $true }
        )
        $null = $builder.AppendLine('<nav aria-label="Table of contents">')
        $null = $builder.AppendLine('<h2>Contents</h2>')
        $null = $builder.AppendLine('<ul>')
        foreach ($tableSection in $tableSections) {
            $sectionTitle = ConvertTo-HtmlReportText -Value $tableSection.Title
            $null = $builder.AppendLine("<li><a href=`"#$($tableSection.Anchor)`">$sectionTitle</a></li>")
        }
        $null = $builder.AppendLine('<li><a href="#package-details">Package details</a><ul>')
        foreach ($entry in $entries) {
            $heading = ConvertTo-HtmlReportText -Value (Get-ReportPackageHeading -Package $entry.Package)
            $null = $builder.AppendLine("<li><a href=`"#$($entry.Anchor)`">$heading</a></li>")
        }
        $null = $builder.AppendLine('</ul></li>')
        $null = $builder.AppendLine('</ul>')
        $null = $builder.AppendLine('</nav>')
    }

    if ($Packages.Count -eq 0) {
        $null = $builder.AppendLine('<p>No upgradeable packages found.</p>')
        $null = $builder.AppendLine('</body></html>')
        return $builder.ToString()
    }

    $columnHeaders = @(
        'Manager',
        'Name',
        'Installed version',
        'Installed release date',
        'Installed relative date',
        'Latest version',
        'Latest release date',
        'Latest relative date'
    )

    foreach ($tableSection in $tableSections) {
        $sectionColumnHeaders = $columnHeaders
        if ($tableSection.OutsideCooldownOnly) {
            $sectionColumnHeaders = @('Manager', 'Name', 'Installed version', 'Available upgrade versions')
        }
        $null = $builder.AppendLine("<h2 id=`"$($tableSection.Anchor)`">$(ConvertTo-HtmlReportText $tableSection.Title)</h2>")
        $null = $builder.AppendLine('<table><thead><tr>')
        foreach ($columnHeader in $sectionColumnHeaders) {
            $null = $builder.AppendLine("<th>$(ConvertTo-HtmlReportText $columnHeader)</th>")
        }
        $null = $builder.AppendLine('</tr></thead><tbody>')

        if ($tableSection.SortByName) {
            $tableEntries = $entries
        }
        else {
            $tableEntries = @($entries | Sort-Object -Property @{ Expression = { $_.Package.InstalledVersion.GetEffectiveDateInfo().Date } })
        }
        if ($tableSection.OutsideCooldownOnly) {
            $tableEntries = @($entries | Where-Object {
                Test-ReportPackageHasOutOfCooldownTargets -Package $_.Package -CooldownHours $CooldownHours
            })
        }

        if ($tableEntries.Count -eq 0) {
            $emptyMessage = 'No upgradeable packages outside cooldown.'
            $null = $builder.AppendLine("<tr><td colspan=`"$($sectionColumnHeaders.Count)`">$(ConvertTo-HtmlReportText -Value $emptyMessage)</td></tr>")
        }
        foreach ($entry in $tableEntries) {
            $package = $entry.Package
            if ($tableSection.OutsideCooldownOnly) {
                $availableUpgradeVersions = (Get-ReportOutOfCooldownUpgradeTargets -Package $package -CooldownHours $CooldownHours |
                    ForEach-Object { $_.PackageVersion.Version }) -join ', '
                $rowValues = @(
                    $package.PackageManagerId,
                    $package.DisplayName,
                    $package.InstalledVersion.Version,
                    $availableUpgradeVersions
                )
            }
            else {
                $rowValues = @(
                    $package.PackageManagerId,
                    $package.DisplayName,
                    $package.InstalledVersion.Version,
                    $package.InstalledVersion.GetEffectiveDateInfo().GetDateOnlyDisplay(),
                    $package.InstalledVersion.GetEffectiveDateInfo().GetRelativeDisplayWithFallbackLabel(),
                    $package.LatestVersion.Version,
                    $package.LatestVersion.GetEffectiveDateInfo().GetDateOnlyDisplay(),
                    $package.LatestVersion.GetEffectiveDateInfo().GetRelativeDisplayWithFallbackLabel()
                )
            }
            $null = $builder.AppendLine('<tr>')
            for ($columnIndex = 0; $columnIndex -lt $sectionColumnHeaders.Count; $columnIndex++) {
                $value = $rowValues[$columnIndex]
                if ($sectionColumnHeaders[$columnIndex] -eq 'Name') {
                    $encodedValue = ConvertTo-HtmlReportText -Value $value
                    $cell = "<a href=`"#$($entry.Anchor)`">$encodedValue</a>"
                }
                else {
                    $cell = ConvertTo-HtmlReportText -Value ([string]$value)
                }
                $null = $builder.AppendLine("<td>$cell</td>")
            }
            $null = $builder.AppendLine('</tr>')
        }
        $null = $builder.AppendLine('</tbody></table>')
    }

    $null = $builder.AppendLine('<h2 id="package-details">Package details</h2>')
    foreach ($entry in $entries) {
        $package = $entry.Package
        $heading = Get-ReportPackageHeading -Package $package
        $null = $builder.AppendLine("<section class=`"package`" id=`"$($entry.Anchor)`">")
        $null = $builder.AppendLine("<h3>$(ConvertTo-HtmlReportText -Value $heading)</h3>")
        $infoLink = Get-HtmlReportInfoLink -Url $package.InfoUrl
        if ($infoLink) {
            $null = $builder.AppendLine("<p>$infoLink</p>")
        }
        $null = $builder.AppendLine("<p>Package Manager: $(ConvertTo-HtmlReportText -Value $package.PackageManagerId), Candidate source: $(ConvertTo-HtmlReportText -Value $package.CandidateSource)</p>")
        $installedVersion = ConvertTo-HtmlReportText -Value $package.InstalledVersion.Version
        $installedDate = ConvertTo-HtmlReportText -Value $package.InstalledVersion.GetEffectiveDateInfo().GetCombinedDisplay()
        $null = $builder.AppendLine('<ul class="versions">')
        $null = $builder.AppendLine("<li class=`"installed`">$installedVersion [$installedDate]")

        $visibleTargets = Get-ReportVisibleUpgradeTargets -Package $package
        if ($visibleTargets.Count -gt 0) {
            $null = $builder.AppendLine('<ul>')
        }
        foreach ($target in $visibleTargets) {
            $version = ConvertTo-HtmlReportText -Value $target.PackageVersion.Version
            $date = ConvertTo-HtmlReportText -Value $target.PackageVersion.GetEffectiveDateInfo().GetCombinedDisplay()
            $command = ConvertTo-HtmlReportText -Value $target.Command
            $cooldown = ''
            if ($target.PackageVersion.IsInCooldown($CooldownHours)) {
                $cooldown = " <span class=`"cooldown`">&#x1F9CA; cooldown ($(ConvertTo-HtmlReportText -Value $target.PackageVersion.GetCooldownRemainingDisplay($CooldownHours)) remaining)</span>"
            }
            $null = $builder.AppendLine("<li><span class=`"upgrade`">$version [$date]</span>$cooldown`: <span class=`"command-line`"><code>$command</code><button type=`"button`" class=`"copy-button`" data-command=`"$command`" aria-label=`"Copy command`" title=`"Copy command`" onclick=`"copyCommand(this)`">&#x1F4CB;</button></span></li>")
        }
        if ($visibleTargets.Count -gt 0) {
            $null = $builder.AppendLine('</ul>')
        }
        $null = $builder.AppendLine('</li></ul>')
        $null = $builder.AppendLine('</section>')
    }

    $usesFirstSeenFallback = @($Packages | ForEach-Object {
        @($_.InstalledVersion, $_.LatestVersion) + @($_.UpgradeTargets | ForEach-Object { $_.PackageVersion })
    } | ForEach-Object { $_.GetEffectiveDateInfo().IsFirstObservedFallback }) -contains $true
    if ($usesFirstSeenFallback) {
        $note = "Note: a version marked 'first seen' has no known release date; the date shown is instead the date this tool first observed that version."
        $null = $builder.AppendLine("<p>$(ConvertTo-HtmlReportText -Value $note)</p>")
    }

    $null = $builder.AppendLine('</body></html>')
    return $builder.ToString()
}

function Write-HtmlPackageReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][SoftwarePackage[]]$Packages,
        [int]$CooldownHours = $script:DefaultCooldownHours
    )

    $reportPath = Get-HtmlReportPath
    $reportDirectory = Split-Path -Parent $reportPath
    New-Item -ItemType Directory -Path $reportDirectory -Force -ErrorAction Stop | Out-Null

    $temporaryPath = Join-Path $reportDirectory ([IO.Path]::GetRandomFileName())
    try {
        $html = ConvertTo-HtmlPackageReport -Packages $Packages -CooldownHours $CooldownHours
        $encoding = [System.Text.UTF8Encoding]::new($false)
        [IO.File]::WriteAllText($temporaryPath, $html, $encoding)
        Move-Item -LiteralPath $temporaryPath -Destination $reportPath -Force -ErrorAction Stop
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath) {
            Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction Stop
        }
    }

    return $reportPath
}
