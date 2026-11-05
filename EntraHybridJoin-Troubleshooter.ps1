<# 
Entra Join Whisperer
Copyright (c) 2026 Michael Blanchard
License: MIT (https://opensource.org/licenses/MIT)
#>
[CmdletBinding()]
param(
    [switch]$NoMenu,
    [switch]$RefreshLearn,
    [switch]$Analyze,
    [switch]$ApplyFixes,
    [string[]]$FixIds,
    [switch]$ExportReport,
    [string]$ReportPath,
    [switch]$JsonReport,
    [switch]$Force,
    [switch]$CheckUpdate,
    [switch]$UpdateSelf,
    [switch]$PublishToGitHub,
    [string]$GitHubRepoUrl,
    [string]$GitHubBranch = "main",
    [string]$GitHubToken
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$Script:ToolName = "Entra Join Whisperer"
$Script:ToolVersion = "1.1.0"
$Script:LicenseName = "MIT"
$Script:LicenseUrl = "https://opensource.org/licenses/MIT"
$Script:RepositoryUrl = "https://github.com/homelabber/entra-join-whisperer"
$Script:DownloadSource = "https://raw.githubusercontent.com/homelabber/entra-join-whisperer/main/EntraHybridJoin-Troubleshooter.ps1"
$Script:DownloadedFrom = $Script:DownloadSource
$Script:PublishScriptPath = Join-Path -Path $PSScriptRoot -ChildPath "Publish-EntraJoinWhisperer.ps1"

$Script:LearnUrls = @(
    "https://learn.microsoft.com/en-us/entra/identity/devices/troubleshoot-hybrid-join-windows-current",
    "https://learn.microsoft.com/en-us/entra/identity/devices/troubleshoot-intermittent-status-account-disabled",
    "https://learn.microsoft.com/en-us/troubleshoot/entra/entra-id/dir-dmns-obj/pending-devices?context=%2Fentra%2Fidentity%2Fdevices%2Fcontext%2Fdevices-context.json",
    "https://learn.microsoft.com/en-us/entra/identity/devices/troubleshoot-device-dsregcmd"
)

$Script:CachePath = Join-Path -Path $PSScriptRoot -ChildPath "EntraHybridJoin-LearnCache.json"
$Script:LastAnalysis = $null

function Write-Info([string]$Message) { Write-Host "[INFO] $Message" -ForegroundColor Cyan }
function Write-Warn([string]$Message) { Write-Host "[WARN] $Message" -ForegroundColor Yellow }
function Write-Err([string]$Message) { Write-Host "[ERR ] $Message" -ForegroundColor Red }

function Write-BrandHeader {
    try { Clear-Host } catch { }
    Write-Host "============================================================" -ForegroundColor DarkCyan
    Write-Host "  $Script:ToolName" -ForegroundColor Cyan
    Write-Host "  Version: $Script:ToolVersion" -ForegroundColor Gray
    Write-Host "  Downloaded from: $Script:DownloadedFrom" -ForegroundColor Gray
    Write-Host "  License: $Script:LicenseName ($Script:LicenseUrl)" -ForegroundColor DarkGray
    Write-Host "============================================================" -ForegroundColor DarkCyan
    Write-Host ""
}

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($id)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Convert-HtmlToText {
    param([Parameter(Mandatory = $true)][string]$Html)
    $text = [regex]::Replace($Html, "(?is)<script.*?</script>", " ")
    $text = [regex]::Replace($text, "(?is)<style.*?</style>", " ")
    $text = [regex]::Replace($text, "(?is)<main[^>]*>(.*?)</main>", '$1')
    $text = [regex]::Replace($text, "(?is)<[^>]+>", " ")
    $text = $text -replace "&nbsp;", " "
    $text = [System.Net.WebUtility]::HtmlDecode($text)
    $text = [regex]::Replace($text, "\s+", " ").Trim()
    return $text
}

function Update-LearnCache {
    Write-Info "Downloading Microsoft Learn troubleshooting content..."
    $pages = foreach ($url in $Script:LearnUrls) {
        try {
            $resp = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 60
            $text = Convert-HtmlToText -Html $resp.Content
            [pscustomobject]@{
                Url         = $url
                Downloaded  = (Get-Date).ToString("o")
                Content     = $text
                CharCount   = $text.Length
            }
        }
        catch {
            [pscustomobject]@{
                Url         = $url
                Downloaded  = (Get-Date).ToString("o")
                Content     = ""
                CharCount   = 0
                Error       = $_.Exception.Message
            }
            Write-Warn "Could not download $url : $($_.Exception.Message)"
        }
    }

    $payload = [pscustomobject]@{
        Generated = (Get-Date).ToString("o")
        Pages     = $pages
    }
    $payload | ConvertTo-Json -Depth 6 | Set-Content -Path $Script:CachePath -Encoding UTF8
    Write-Info "Learn cache updated: $Script:CachePath"
    return $payload
}

function Get-LearnCache {
    if (-not (Test-Path $Script:CachePath)) {
        return Update-LearnCache
    }
    return Get-Content -Path $Script:CachePath -Raw | ConvertFrom-Json
}

function Get-ScriptVersionFromContent {
    param([Parameter(Mandatory = $true)][string]$Content)
    $m = [regex]::Match($Content, '\$Script:ToolVersion\s*=\s*"([^"]+)"')
    if ($m.Success) { return $m.Groups[1].Value }
    return "0.0.0"
}

function Get-UpdateStatus {
    $currentVersion = [version]$Script:ToolVersion
    try {
        $remote = Invoke-WebRequest -Uri $Script:DownloadSource -UseBasicParsing -TimeoutSec 60
        $remoteContent = [string]$remote.Content
        $remoteVersion = [version](Get-ScriptVersionFromContent -Content $remoteContent)
        return [pscustomobject]@{
            CurrentVersion = $currentVersion
            RemoteVersion  = $remoteVersion
            HasUpdate      = ($remoteVersion -gt $currentVersion)
            RemoteContent  = $remoteContent
        }
    }
    catch {
        throw "Could not check updates at $Script:DownloadSource. $($_.Exception.Message)"
    }
}

function Invoke-SelfUpdate {
    param([switch]$Force)
    if ($Script:DownloadSource -match "<your-account>|<your-repo>") {
        throw "Set a real GitHub raw download URL in `$Script:DownloadSource before using auto-update."
    }
    $status = Get-UpdateStatus
    if (-not $status.HasUpdate) {
        Write-Info "No update available. Current version is $($status.CurrentVersion)."
        return
    }

    Write-Warn "Update available: $($status.CurrentVersion) -> $($status.RemoteVersion)"
    Write-Warn "The script file will be replaced in-place with content from GitHub."
    if (-not $Force) {
        $answer = Read-Host "Proceed with self-update? (Y/N)"
        if ($answer -notin @("Y", "y", "Yes", "YES")) {
            Write-Info "Self-update canceled."
            return
        }
    }

    $target = if ($PSCommandPath) { $PSCommandPath } else { $MyInvocation.MyCommand.Path }
    $backup = "$target.bak"
    Copy-Item -Path $target -Destination $backup -Force
    Set-Content -Path $target -Value $status.RemoteContent -Encoding UTF8
    Write-Info "Updated script: $target"
    Write-Info "Backup created: $backup"
}

function Publish-ScriptToGitHub {
    param(
        [string]$RepoUrl,
        [string]$Branch = "main",
        [string]$Token
    )

    if (-not $RepoUrl) {
        throw "GitHubRepoUrl is required for publishing."
    }
    if ($RepoUrl -notmatch "^https://github\.com/.+/.+(\.git)?$") {
        throw "GitHubRepoUrl must be a standard GitHub repository URL."
    }

    $licensePath = Join-Path -Path $PSScriptRoot -ChildPath "LICENSE"
    if (-not (Test-Path $licensePath)) {
        @"
MIT License

Copyright (c) 2026 Michael Blanchard

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
"@ | Set-Content -Path $licensePath -Encoding UTF8
    }

    $publishScript = @"
param(
    [Parameter(Mandatory = `$true)][string]`$RepoUrl,
    [Parameter(Mandatory = `$true)][string]`$Branch,
    [string]`$Token
)
`$ErrorActionPreference = 'Stop'
function Assert-LastExit([string]`$Step) {
    if (`$LASTEXITCODE -ne 0) {
        throw "Git command failed during: `$Step"
    }
}
`$temp = Join-Path `$env:TEMP ('entra-join-whisperer-publish-' + [guid]::NewGuid().ToString('N'))
New-Item -Path `$temp -ItemType Directory -Force | Out-Null
Copy-Item -Path '$($PSCommandPath.Replace("'", "''"))' -Destination (Join-Path `$temp 'EntraHybridJoin-Troubleshooter.ps1') -Force
Copy-Item -Path '$($licensePath.Replace("'", "''"))' -Destination (Join-Path `$temp 'LICENSE') -Force
Push-Location `$temp
git init | Out-Null; Assert-LastExit 'git init'
git checkout -b `$Branch | Out-Null; Assert-LastExit 'git checkout'
git add . | Out-Null; Assert-LastExit 'git add'
git -c user.name='Entra Join Whisperer' -c user.email='noreply@localhost' commit -m 'Publish Entra Join Whisperer script' | Out-Null; Assert-LastExit 'git commit'
`$remote = `$RepoUrl
if (`$Token) {
    `$remote = `$RepoUrl -replace '^https://', ('https://' + `$Token + '@')
}
git remote add origin `$remote
Assert-LastExit 'git remote add origin'
git push -u origin `$Branch --force
Assert-LastExit 'git push'
Pop-Location
Remove-Item -Path `$temp -Recurse -Force
"@
    Set-Content -Path $Script:PublishScriptPath -Value $publishScript -Encoding UTF8
    Write-Info "Publish helper generated: $Script:PublishScriptPath"
    Write-Info "Running publish helper..."
    & $Script:PublishScriptPath -RepoUrl $RepoUrl -Branch $Branch -Token $Token
    Write-Info "Publish complete to $RepoUrl ($Branch)"
}

function Get-LearnExcerpt {
    param(
        [Parameter(Mandatory = $true)]$Cache,
        [Parameter(Mandatory = $true)][string[]]$Keywords,
        [int]$MaxExcerpts = 2
    )
    $snippets = @()
    foreach ($page in $Cache.Pages) {
        if (-not $page.Content) { continue }
        foreach ($k in $Keywords) {
            $i = $page.Content.IndexOf($k, [System.StringComparison]::OrdinalIgnoreCase)
            if ($i -ge 0) {
                $start = [Math]::Max(0, $i - 140)
                $len = [Math]::Min(360, $page.Content.Length - $start)
                $clip = $page.Content.Substring($start, $len)
                $snippets += [pscustomobject]@{
                    Keyword = $k
                    Url     = $page.Url
                    Snippet = $clip
                }
                break
            }
        }
        if ($snippets.Count -ge $MaxExcerpts) { break }
    }
    return $snippets
}

function Get-DsregStatusRaw {
    try {
        $raw = dsregcmd /status 2>&1
        if (-not $raw) { throw "dsregcmd returned no output." }
        return ($raw | Out-String)
    }
    catch {
        throw "Failed to run dsregcmd /status. $($_.Exception.Message)"
    }
}

function Parse-DsregStatus {
    param([Parameter(Mandatory = $true)][string]$Raw)

    $map = @{}
    $section = "General"
    foreach ($line in ($Raw -split "`r?`n")) {
        if ($line -match "^\s*\|\s*(.+?)\s*\|\s*$") {
            $candidate = ($matches[1]).Trim()
            if ($candidate -and $candidate -notmatch "^\+|-+$") {
                $section = $candidate
            }
            continue
        }

        if ($line -match "^\s*([A-Za-z0-9\-\(\)\/\.\s]+?)\s*:\s*(.*?)\s*$") {
            $k = "$section.$(($matches[1]).Trim())"
            $v = ($matches[2]).Trim()
            if ($v) { $map[$k] = $v }
        }
    }
    return $map
}

function Find-StatusAccountDisabledEvidence {
    $evidence = @()
    $logSets = @(
        @{ Log = "Microsoft-Windows-AAD/Operational"; Id = 1081; Pattern = "AADSTS50034|does not exist in the" },
        @{ Log = "Microsoft-Windows-HelloForBusiness/Operational"; Id = 7001; Pattern = "0xC000006D|0xC0000072|STATUS_ACCOUNT_DISABLED" }
    )
    foreach ($set in $logSets) {
        try {
            $events = Get-WinEvent -FilterHashtable @{ LogName = $set.Log; Id = $set.Id; StartTime = (Get-Date).AddDays(-7) } -ErrorAction Stop
            foreach ($evt in $events) {
                if ($evt.Message -match $set.Pattern) {
                    $evidence += "$($set.Log) ID $($set.Id) @ $($evt.TimeCreated.ToString("s"))"
                    break
                }
            }
        }
        catch {
            continue
        }
    }
    return $evidence
}

function New-Issue {
    param(
        [string]$Id,
        [string]$Severity,
        [string]$Title,
        [string]$Evidence,
        [string]$Guidance,
        [string]$FixId = "",
        [string]$Risk = "Low"
    )
    [pscustomobject]@{
        Id       = $Id
        Severity = $Severity
        Title    = $Title
        Evidence = $Evidence
        Guidance = $Guidance
        FixId    = $FixId
        Risk     = $Risk
    }
}

function Get-IssuesFromStatus {
    param(
        [Parameter(Mandatory = $true)]$Map,
        [Parameter(Mandatory = $true)]$Cache
    )

    $issues = New-Object System.Collections.Generic.List[object]

    $azureAdJoined = $Map["Device State.AzureAdJoined"]
    $domainJoined = $Map["Device State.DomainJoined"]
    $deviceAuthStatus = $Map["Device Details.DeviceAuthStatus"]
    $azureAdPrt = $Map["SSO State.AzureAdPrt"]
    $wamDefaultSet = $Map["SSO State.WamDefaultSet"]
    $errorPhase = $Map["Diagnostic Data.Error Phase"]
    $clientError = $Map["Diagnostic Data.Client ErrorCode"]
    $drsDiscovery = $Map["Diagnostic Data.DRS Discovery Test"]

    if ($domainJoined -and $domainJoined -ne "YES") {
        $issues.Add((New-Issue -Id "not-domain-joined" -Severity "High" -Title "Device is not domain joined." -Evidence "DomainJoined=$domainJoined" -Guidance "Microsoft Entra hybrid join requires the device to be joined to on-premises AD first." -FixId "" -Risk "High"))
    }

    if ($azureAdJoined -and $azureAdJoined -ne "YES") {
        $issues.Add((New-Issue -Id "not-entra-joined" -Severity "High" -Title "Device is not Microsoft Entra joined." -Evidence "AzureAdJoined=$azureAdJoined" -Guidance "Check SCP configuration, network access to enterpriseregistration.windows.net, and trigger Automatic-Device-Join task." -FixId "run-device-join-task" -Risk "Low"))
    }

    if ($deviceAuthStatus -and $deviceAuthStatus -ne "SUCCESS") {
        $issues.Add((New-Issue -Id "device-auth-failed" -Severity "High" -Title "Device authentication status is not healthy." -Evidence "DeviceAuthStatus=$deviceAuthStatus" -Guidance "If device is disabled/deleted in Entra, re-enable it or re-register: dsregcmd /debug /leave then reboot and rejoin." -FixId "leave-and-rejoin" -Risk "High"))
    }

    if ($azureAdPrt -and $azureAdPrt -ne "YES") {
        $issues.Add((New-Issue -Id "missing-prt" -Severity "Medium" -Title "Primary Refresh Token (PRT) is missing." -Evidence "AzureAdPrt=$azureAdPrt" -Guidance "Sign in with network connectivity, lock/unlock, run dsregcmd /refreshprt, and verify WAM defaults and token acquisition." -FixId "refresh-prt" -Risk "Low"))
    }

    if ($wamDefaultSet -and $wamDefaultSet -notin @("YES", "AzureAd")) {
        $issues.Add((New-Issue -Id "wam-default" -Severity "Medium" -Title "WAM default account/provider does not look healthy." -Evidence "WamDefaultSet=$wamDefaultSet" -Guidance "Review WAM and user sign-in state. A bad WAM state commonly blocks PRT refresh." -FixId "refresh-prt" -Risk "Low"))
    }

    if ($drsDiscovery -and $drsDiscovery -match "FAIL") {
        $issues.Add((New-Issue -Id "drs-discovery-fail" -Severity "High" -Title "DRS discovery test failed." -Evidence "DRS Discovery Test=$drsDiscovery" -Guidance "Validate system-context network connectivity and proxy for enterpriseregistration.windows.net. Error 0x801c0021/0x80072ee2 often indicates timeout." -FixId "run-device-join-task" -Risk "Low"))
    }

    if ($errorPhase -or $clientError) {
        $guidance = "Join diagnostics show Error Phase='$errorPhase' and Client ErrorCode='$clientError'. Investigate SCP and directory registration flow."
        switch -Regex ($clientError) {
            "0x801c001d" { $guidance = "Cannot read SCP (DSREG_AUTOJOIN_ADCONFIG_READ_FAILED). Verify SCP tenant ID/domain settings and AD replication."; break }
            "0x801c0021" { $guidance = "Discovery failure (DSREG_AUTOJOIN_DISC_FAILED). Check DRS metadata reachability and proxy/TLS path."; break }
            "0x801c001f" { $guidance = "Discovery timeout. Ensure enterpriseregistration.windows.net is reachable in SYSTEM context."; break }
            "0x801c03f2" { $guidance = "Directory failure from DRS. Validate tenant/device object consistency and stale/pending device cleanup."; break }
        }
        $issues.Add((New-Issue -Id "join-diagnostics-error" -Severity "High" -Title "Join diagnostics contain an explicit client error code." -Evidence "ErrorPhase=$errorPhase ; ClientErrorCode=$clientError" -Guidance $guidance -FixId "run-device-join-task" -Risk "Low"))
    }

    $statusDisabledEvidence = @(Find-StatusAccountDisabledEvidence)
    if ($statusDisabledEvidence.Count -gt 0) {
        $issues.Add((New-Issue -Id "status-account-disabled-intermittent" -Severity "Medium" -Title "Intermittent STATUS_ACCOUNT_DISABLED pattern detected in event logs." -Evidence ($statusDisabledEvidence -join "; ") -Guidance "This usually indicates stale local user cache after resume/network transition. Use sign-out/sign-in (not unlock), ensure DC/VPN is up at sign-in, and prefer device tunnel VPN for hybrid join estates." -FixId "signout-reboot" -Risk "Medium"))
    }

    if ($issues.Count -eq 0) {
        $issues.Add((New-Issue -Id "no-findings" -Severity "Info" -Title "No obvious dsregcmd health issue found." -Evidence "Core status fields look healthy." -Guidance "If users still fail sign-in, inspect AAD and Hello for Business logs and tenant-side device state." -FixId "" -Risk "Low"))
    }

    foreach ($issue in $issues) {
        if ($issue.Id -eq "no-findings") { continue }
        $keywords = @($issue.Id.Replace("-", " "), "hybrid join", "dsregcmd", "pending", "DeviceAuthStatus")
        $issue | Add-Member -MemberType NoteProperty -Name LearnExcerpts -Value (Get-LearnExcerpt -Cache $Cache -Keywords $keywords -MaxExcerpts 2)
    }
    return $issues
}

function Invoke-Fix {
    param(
        [Parameter(Mandatory = $true)][string]$FixId,
        [switch]$Force
    )

    $catalog = @{
        "refresh-prt" = @{
            Name    = "Refresh PRT"
            Risk    = "Low"
            Warning = "This refreshes the current user's token state."
            Action  = { dsregcmd /refreshprt | Out-Host }
        }
        "run-device-join-task" = @{
            Name    = "Run Automatic-Device-Join task"
            Risk    = "Low"
            Warning = "This starts Workplace Join scheduled task to retry hybrid join."
            Action  = { schtasks /Run /TN "\Microsoft\Windows\Workplace Join\Automatic-Device-Join" | Out-Host }
        }
        "signout-reboot" = @{
            Name    = "Recommend sign-out/reboot workflow"
            Risk    = "Medium"
            Warning = "Reboot/sign-out interrupts active sessions and unsaved work."
            Action  = {
                Write-Warn "Please save work. Recommended workflow:"
                Write-Host "1) Sign out completely" -ForegroundColor Gray
                Write-Host "2) Sign in again after VPN/domain connectivity is available" -ForegroundColor Gray
                Write-Host "3) If still failing, reboot then sign in" -ForegroundColor Gray
            }
        }
        "leave-and-rejoin" = @{
            Name    = "Leave and re-register device"
            Risk    = "High"
            Warning = "This can break SSO/Conditional Access until the device re-registers. You may need admin rights and a reboot."
            Action  = {
                dsregcmd /debug /leave | Out-Host
                Write-Warn "Device left registration. Reboot is strongly recommended."
                schtasks /Run /TN "\Microsoft\Windows\Workplace Join\Automatic-Device-Join" | Out-Host
            }
        }
        "gpupdate-computer" = @{
            Name    = "Refresh computer GPO"
            Risk    = "Medium"
            Warning = "Policy refresh can modify workstation behavior and mapped settings."
            Action  = { gpupdate /target:computer /force | Out-Host }
        }
        "purge-kerberos" = @{
            Name    = "Purge Kerberos tickets"
            Risk    = "Medium"
            Warning = "Kerberos sessions will reset; active resource access may break until re-authentication."
            Action  = { klist purge | Out-Host }
        }
    }

    if (-not $catalog.ContainsKey($FixId)) {
        throw "Unknown FixId: $FixId"
    }

    $entry = $catalog[$FixId]
    Write-Host ""
    Write-Warn "$($entry.Name) | Risk: $($entry.Risk)"
    Write-Warn $entry.Warning
    if (-not $Force) {
        $answer = Read-Host "Proceed? (Y/N)"
        if ($answer -notin @("Y", "y", "Yes", "YES")) {
            Write-Info "Skipped $FixId"
            return
        }
    }
    & $entry.Action
}

function Invoke-Analysis {
    $cache = Get-LearnCache
    $raw = Get-DsregStatusRaw
    $map = Parse-DsregStatus -Raw $raw
    $issues = Get-IssuesFromStatus -Map $map -Cache $cache

    $result = [pscustomobject]@{
        RunAt        = (Get-Date).ToString("o")
        IsAdmin      = (Test-IsAdmin)
        SourceUrls   = $Script:LearnUrls
        DsregMap     = $map
        IssueCount   = @($issues | Where-Object { $_.Severity -ne "Info" }).Count
        Issues       = $issues
        RawDsregcmd  = $raw
    }
    $Script:LastAnalysis = $result
    return $result
}

function Format-AnalysisReport {
    param([Parameter(Mandatory = $true)]$Analysis)
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("Microsoft Entra Hybrid Join Troubleshooting Report")
    $lines.Add("Generated: $($Analysis.RunAt)")
    $lines.Add("Admin Session: $($Analysis.IsAdmin)")
    $lines.Add("")
    $lines.Add("Referenced Microsoft Learn URLs:")
    foreach ($u in $Analysis.SourceUrls) { $lines.Add(" - $u") }
    $lines.Add("")
    $lines.Add("Detected Issues: $($Analysis.IssueCount)")
    $lines.Add("")

    foreach ($issue in $Analysis.Issues) {
        $lines.Add("[$($issue.Severity)] $($issue.Title)")
        $lines.Add("  Id: $($issue.Id)")
        $lines.Add("  Evidence: $($issue.Evidence)")
        $lines.Add("  Guidance: $($issue.Guidance)")
        if ($issue.FixId) {
            $lines.Add("  Suggested FixId: $($issue.FixId) (Risk: $($issue.Risk))")
        }
        if ($issue.PSObject.Properties.Name -contains "LearnExcerpts") {
            foreach ($ex in $issue.LearnExcerpts) {
                $lines.Add("  Learn Ref: $($ex.Url)")
                $lines.Add("  Snippet: $($ex.Snippet)")
            }
        }
        $lines.Add("")
    }
    return ($lines -join [Environment]::NewLine)
}

function Write-AnalysisToScreen {
    param([Parameter(Mandatory = $true)]$Analysis)
    Write-Host ""
    Write-Host "==== dsregcmd Troubleshooting Summary ====" -ForegroundColor Green
    Write-Host "Run: $($Analysis.RunAt)"
    Write-Host "Issues: $($Analysis.IssueCount)"
    Write-Host ""
    foreach ($i in $Analysis.Issues) {
        $color = switch ($i.Severity) {
            "High" { "Red" }
            "Medium" { "Yellow" }
            "Info" { "Gray" }
            default { "White" }
        }
        Write-Host "[$($i.Severity)] $($i.Title)" -ForegroundColor $color
        Write-Host "  Evidence: $($i.Evidence)"
        Write-Host "  Guidance: $($i.Guidance)"
        if ($i.FixId) {
            Write-Host "  FixId: $($i.FixId) (Risk: $($i.Risk))" -ForegroundColor DarkCyan
        }
        Write-Host ""
    }
}

function Export-Analysis {
    param(
        [Parameter(Mandatory = $true)]$Analysis,
        [string]$Path,
        [switch]$JsonReport
    )
    if (-not $Path) {
        $Path = Join-Path -Path $PSScriptRoot -ChildPath ("EntraHybridJoin-Report-{0}.txt" -f (Get-Date -Format "yyyyMMdd-HHmmss"))
    }
    if ($JsonReport) {
        if (-not $Path.ToLowerInvariant().EndsWith(".json")) {
            $Path = [System.IO.Path]::ChangeExtension($Path, ".json")
        }
        $Analysis | ConvertTo-Json -Depth 8 | Set-Content -Path $Path -Encoding UTF8
    }
    else {
        $text = Format-AnalysisReport -Analysis $Analysis
        Set-Content -Path $Path -Value $text -Encoding UTF8
    }
    Write-Info "Report written to: $Path"
}

function Show-LightBarMenu {
    param([string[]]$Items)
    $index = 0
    while ($true) {
        Write-BrandHeader
        Write-Host "Interactive Menu" -ForegroundColor Cyan
        Write-Host "Use Up/Down arrows and Enter." -ForegroundColor DarkGray
        Write-Host ""
        for ($i = 0; $i -lt $Items.Count; $i++) {
            if ($i -eq $index) {
                Write-Host ("  > " + $Items[$i]) -ForegroundColor Black -BackgroundColor White
            }
            else {
                Write-Host ("    " + $Items[$i]) -ForegroundColor Gray
            }
        }
        $key = [Console]::ReadKey($true)
        switch ($key.Key) {
            "UpArrow" { if ($index -gt 0) { $index-- } }
            "DownArrow" { if ($index -lt ($Items.Count - 1)) { $index++ } }
            "Enter" { return $index }
            default { }
        }
    }
}

function Start-InteractiveMode {
    $menu = @(
        "Refresh Microsoft Learn troubleshooting cache",
        "Run dsregcmd analysis and show report",
        "Apply fixes for current findings",
        "Check for script updates from GitHub",
        "Update script from GitHub",
        "Publish script to GitHub",
        "Export last report",
        "Exit"
    )

    while ($true) {
        $choice = Show-LightBarMenu -Items $menu
        switch ($choice) {
            0 {
                Update-LearnCache | Out-Null
                Read-Host "Press Enter to continue" | Out-Null
            }
            1 {
                $a = Invoke-Analysis
                Write-AnalysisToScreen -Analysis $a
                Read-Host "Press Enter to continue" | Out-Null
            }
            2 {
                if (-not $Script:LastAnalysis) {
                    Write-Warn "Run analysis first."
                    Start-Sleep -Seconds 1
                    continue
                }
                $fixes = $Script:LastAnalysis.Issues | Where-Object { $_.FixId } | Select-Object -ExpandProperty FixId -Unique
                if (-not $fixes) {
                    Write-Info "No auto-fix candidates for current findings."
                    Start-Sleep -Seconds 1
                    continue
                }
                foreach ($f in $fixes) {
                    try { Invoke-Fix -FixId $f }
                    catch { Write-Err $_.Exception.Message }
                }
                Read-Host "Press Enter to continue" | Out-Null
            }
            3 {
                try {
                    $u = Get-UpdateStatus
                    if ($u.HasUpdate) {
                        Write-Warn "Update available: $($u.CurrentVersion) -> $($u.RemoteVersion)"
                    }
                    else {
                        Write-Info "No update available. Current version: $($u.CurrentVersion)"
                    }
                }
                catch {
                    Write-Err $_.Exception.Message
                }
                Read-Host "Press Enter to continue" | Out-Null
            }
            4 {
                try { Invoke-SelfUpdate }
                catch { Write-Err $_.Exception.Message }
                Read-Host "Press Enter to continue" | Out-Null
            }
            5 {
                try {
                    if (-not $GitHubRepoUrl) {
                        $GitHubRepoUrl = Read-Host "Enter GitHub repo URL (https://github.com/<owner>/<repo>)"
                    }
                    Publish-ScriptToGitHub -RepoUrl $GitHubRepoUrl -Branch $GitHubBranch -Token $GitHubToken
                }
                catch {
                    Write-Err $_.Exception.Message
                }
                Read-Host "Press Enter to continue" | Out-Null
            }
            6 {
                if (-not $Script:LastAnalysis) {
                    Write-Warn "Run analysis first."
                    Start-Sleep -Seconds 1
                    continue
                }
                Export-Analysis -Analysis $Script:LastAnalysis -Path $ReportPath -JsonReport:$JsonReport
                Read-Host "Press Enter to continue" | Out-Null
            }
            7 { break }
        }
    }
}

function Show-Usage {
@"
Usage examples:
  .\EntraHybridJoin-Troubleshooter.ps1
  .\EntraHybridJoin-Troubleshooter.ps1 -NoMenu -RefreshLearn -Analyze
  .\EntraHybridJoin-Troubleshooter.ps1 -NoMenu -Analyze -ApplyFixes
  .\EntraHybridJoin-Troubleshooter.ps1 -NoMenu -Analyze -ApplyFixes -FixIds refresh-prt,run-device-join-task
  .\EntraHybridJoin-Troubleshooter.ps1 -NoMenu -Analyze -ExportReport -ReportPath C:\Temp\entra-report.txt
  .\EntraHybridJoin-Troubleshooter.ps1 -NoMenu -CheckUpdate
  .\EntraHybridJoin-Troubleshooter.ps1 -NoMenu -UpdateSelf
  .\EntraHybridJoin-Troubleshooter.ps1 -NoMenu -PublishToGitHub -GitHubRepoUrl https://github.com/<owner>/<repo>

Switches:
  -NoMenu        Bypass interactive light-bar menu.
  -RefreshLearn  Pull the configured Microsoft Learn troubleshooting pages and refresh local cache.
  -Analyze       Run dsregcmd /status analysis and produce issue guidance.
  -ApplyFixes    Offer/execute suggested fixes (with risk warnings).
  -FixIds        Optional explicit fix IDs to apply.
  -ExportReport  Write report to file.
  -ReportPath    Target report path (.txt default, .json when -JsonReport is set).
  -JsonReport    Export as JSON.
  -Force         Skip confirmation prompts before fix execution.
  -CheckUpdate   Check GitHub source for a newer script version.
  -UpdateSelf    Replace local script with latest from GitHub source.
  -PublishToGitHub  Publish current script and LICENSE to a GitHub repository.
  -GitHubRepoUrl GitHub repository URL (https://github.com/<owner>/<repo>).
  -GitHubBranch  Target branch for publish (default: main).
  -GitHubToken   Optional PAT for non-interactive publish.
"@ | Write-Host
}

try {
    $didAnything = $false
    Write-BrandHeader

    if (-not $NoMenu -and -not ($RefreshLearn -or $Analyze -or $ApplyFixes -or $ExportReport -or $FixIds -or $CheckUpdate -or $UpdateSelf -or $PublishToGitHub)) {
        Start-InteractiveMode
        return
    }

    if ($RefreshLearn) {
        Update-LearnCache | Out-Null
        $didAnything = $true
    }

    if ($Analyze) {
        $analysis = Invoke-Analysis
        Write-AnalysisToScreen -Analysis $analysis
        $didAnything = $true
    }

    if ($ApplyFixes) {
        if (-not $Script:LastAnalysis) {
            $Script:LastAnalysis = Invoke-Analysis
            Write-AnalysisToScreen -Analysis $Script:LastAnalysis
        }
        $ids = @()
        if ($FixIds) {
            $ids = $FixIds
        }
        else {
            $ids = $Script:LastAnalysis.Issues | Where-Object { $_.FixId } | Select-Object -ExpandProperty FixId -Unique
        }

        $ids = @($ids)
        if ($ids.Count -eq 0) {
            Write-Info "No available fix IDs from current findings."
        }
        else {
            foreach ($id in $ids) {
                try {
                    Invoke-Fix -FixId $id -Force:$Force
                }
                catch {
                    Write-Err $_.Exception.Message
                }
            }
        }
        $didAnything = $true
    }

    if ($ExportReport) {
        if (-not $Script:LastAnalysis) {
            $Script:LastAnalysis = Invoke-Analysis
        }
        Export-Analysis -Analysis $Script:LastAnalysis -Path $ReportPath -JsonReport:$JsonReport
        $didAnything = $true
    }

    if ($CheckUpdate) {
        $u = Get-UpdateStatus
        if ($u.HasUpdate) {
            Write-Warn "Update available: $($u.CurrentVersion) -> $($u.RemoteVersion)"
        }
        else {
            Write-Info "No update available. Current version: $($u.CurrentVersion)"
        }
        $didAnything = $true
    }

    if ($UpdateSelf) {
        Invoke-SelfUpdate -Force:$Force
        $didAnything = $true
    }

    if ($PublishToGitHub) {
        Publish-ScriptToGitHub -RepoUrl $GitHubRepoUrl -Branch $GitHubBranch -Token $GitHubToken
        $didAnything = $true
    }

    if (-not $didAnything) {
        Show-Usage
    }
}
catch {
    Write-Err $_.Exception.Message
    exit 1
}
