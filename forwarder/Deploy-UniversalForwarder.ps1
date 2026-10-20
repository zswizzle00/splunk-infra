#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Installs and configures a Splunk Universal Forwarder (UF) on Windows and
    points it at an on-prem Splunk Enterprise deployment.

.DESCRIPTION
    Windows counterpart of deploy-universal-forwarder.sh.

    - Installs the UF MSI silently (from a local file or a URL).
    - Seeds the local admin account via user-seed.conf, so the password is
      never placed on the msiexec command line or in the MSI log.
    - Writes outputs.conf, deploymentclient.conf and inputs.conf into a
      dedicated app (etc\apps\org_uf_base\local) so a deployment server can
      take over later.
    - Optionally collects Windows Event Logs and monitors files/directories.
    - Sets the SplunkForwarder service to start automatically and verifies it.

    Safe to re-run: config files are rewritten; the MSI is only run if the UF
    is not already installed (use -Force to reinstall/upgrade).

.PARAMETER PackageFile
    Path to a local splunkforwarder-*.msi.

.PARAMETER PackageUrl
    URL to download the MSI from.

.PARAMETER Indexers
    One or more host:port receivers, e.g. 'idx01.corp.local:9997','idx02.corp.local:9997'.

.PARAMETER DeploymentServer
    Deployment server management URI as host:port (usually port 8089).

.PARAMETER Monitor
    Files/directories to monitor, as 'PATH|INDEX|SOURCETYPE' (index and
    sourcetype optional). '|' is used because Windows paths contain ':'.

.PARAMETER WinEventLogs
    Windows Event Log channels to collect, e.g. Application,System,Security.

.PARAMETER EventLogIndex
    Index for the event log inputs (defaults to the indexer's default index).

.PARAMETER AdminPassword
    Admin password for the UF as a SecureString. Prompted for if omitted on a
    fresh install.

.EXAMPLE
    .\Deploy-UniversalForwarder.ps1 `
        -PackageFile .\splunkforwarder-9.3.1-0b8d769cb912-x64-release.msi `
        -Indexers 'splunk-idx01.corp.local:9997','splunk-idx02.corp.local:9997' `
        -DeploymentServer 'splunk-ds.corp.local:8089' `
        -WinEventLogs Application,System,Security -EventLogIndex wineventlog `
        -Monitor 'C:\inetpub\logs\LogFiles|iis|ms:iis:auto'
#>
[CmdletBinding()]
param(
    [string]   $PackageFile,
    [string]   $PackageUrl,
    [string[]] $Indexers = @(),
    [string]   $DeploymentServer,
    [string[]] $Monitor = @(),
    [string[]] $WinEventLogs = @(),
    [string]   $EventLogIndex,
    [string]   $ClientName,
    [string]   $InstallDir = "$env:ProgramFiles\SplunkUniversalForwarder",
    [string]   $AdminUser = 'admin',
    [securestring] $AdminPassword,
    [switch]   $UseLocalSystem,
    [switch]   $Tls,
    [string]   $CaCert,
    [switch]   $Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$AppName     = 'org_uf_base'
$ServiceName = 'SplunkForwarder'
$SplunkExe   = Join-Path $InstallDir 'bin\splunk.exe'

function Write-Log  { param([string]$Message) Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $Message" }
function Write-Warn { param([string]$Message) Write-Warning "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $Message" }
function Stop-WithError { param([string]$Message) throw "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] ERROR: $Message" }

# Splunk .conf files should be UTF-8 without a BOM; Set-Content on Windows
# PowerShell 5.1 always writes one, so write the bytes directly.
function Write-ConfFile {
    param([string]$Path, [string[]]$Lines)
    $text = ($Lines -join "`r`n") + "`r`n"
    [System.IO.File]::WriteAllText($Path, $text, (New-Object System.Text.UTF8Encoding($false)))
}

function Test-HostPort {
    param([string]$Value)
    if ($Value -notmatch '^[A-Za-z0-9._-]+:\d{1,5}$') { Stop-WithError "Invalid host:port '$Value'" }
}

# Warn (don't fail) if a destination isn't reachable yet - firewalls are often
# opened after the forwarder is staged.
function Test-Reachable {
    param([string]$HostPort)
    $h, $p = $HostPort -split ':'
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $async = $client.BeginConnect($h, [int]$p, $null, $null)
        if ($async.AsyncWaitHandle.WaitOne(5000) -and $client.Connected) {
            Write-Log "Reachable: $HostPort"
        } else {
            Write-Warn "Cannot reach $HostPort - check DNS/firewall."
        }
    } catch {
        Write-Warn "Cannot reach $HostPort - $($_.Exception.Message)"
    } finally {
        $client.Close()
    }
}

# ----------------------------------------------------------------------------
# Pre-flight checks
# ----------------------------------------------------------------------------
if (-not $Indexers -and -not $DeploymentServer) { Stop-WithError 'Specify -Indexers and/or -DeploymentServer.' }
if ($PackageFile -and $PackageUrl)             { Stop-WithError 'Use only one of -PackageFile or -PackageUrl.' }
if ($CaCert) {
    if (-not (Test-Path -LiteralPath $CaCert -PathType Leaf)) { Stop-WithError "CA cert not found: $CaCert" }
    $Tls = [switch]$true
}

# Accept both -Indexers a,b and -Indexers 'a,b'.
$Indexers = @($Indexers | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$Indexers | ForEach-Object { Test-HostPort $_ }
if ($DeploymentServer) { Test-HostPort $DeploymentServer }

$alreadyInstalled = Test-Path -LiteralPath $SplunkExe
$doInstall = (-not $alreadyInstalled) -or $Force

if ($doInstall -and -not $PackageFile -and -not $PackageUrl) {
    Stop-WithError 'No package given. Use -PackageFile or -PackageUrl.'
}

$needsSeed = $doInstall -or -not (Test-Path -LiteralPath (Join-Path $InstallDir 'etc\passwd'))
if ($needsSeed -and -not $AdminPassword) {
    $AdminPassword = Read-Host -AsSecureString 'Enter admin password for the forwarder (min 8 chars)'
    $confirm       = Read-Host -AsSecureString 'Confirm password'
    $a = [System.Net.NetworkCredential]::new('', $AdminPassword).Password
    $b = [System.Net.NetworkCredential]::new('', $confirm).Password
    if ($a -ne $b) { Stop-WithError 'Passwords do not match.' }
}
$plainPassword = if ($AdminPassword) { [System.Net.NetworkCredential]::new('', $AdminPassword).Password } else { $null }
if ($plainPassword -and $plainPassword.Length -lt 8) { Stop-WithError 'Password must be at least 8 characters.' }

$Indexers | ForEach-Object { Test-Reachable $_ }
if ($DeploymentServer) { Test-Reachable $DeploymentServer }

# ----------------------------------------------------------------------------
# Install
# ----------------------------------------------------------------------------
$downloadDir = $null
try {
    if ($doInstall) {
        $msi = $PackageFile
        if ($PackageUrl) {
            $downloadDir = Join-Path $env:TEMP ("splunkuf-" + [guid]::NewGuid())
            New-Item -ItemType Directory -Path $downloadDir | Out-Null
            $msi = Join-Path $downloadDir ([System.IO.Path]::GetFileName(([uri]$PackageUrl).AbsolutePath))
            Write-Log "Downloading $PackageUrl"
            [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
            $ProgressPreference = 'SilentlyContinue'   # makes Invoke-WebRequest far faster on 5.1
            Invoke-WebRequest -Uri $PackageUrl -OutFile $msi -UseBasicParsing
        }

        if (-not (Test-Path -LiteralPath $msi -PathType Leaf)) { Stop-WithError "Package not found: $msi" }
        $msi = (Resolve-Path -LiteralPath $msi).Path
        if ($msi -notmatch '\.msi$') { Stop-WithError "Expected an .msi package: $msi" }

        $sig = Get-AuthenticodeSignature -FilePath $msi
        if ($sig.Status -ne 'Valid') {
            Stop-WithError "MSI signature is not valid ($($sig.Status)). Refusing to install."
        }
        Write-Log "MSI signed by: $($sig.SignerCertificate.Subject)"

        if (Get-Service -Name $ServiceName -ErrorAction SilentlyContinue) {
            Write-Log 'Stopping existing forwarder service'
            Stop-Service -Name $ServiceName -Force -ErrorAction SilentlyContinue
        }

        # LAUNCHSPLUNK=0: don't start yet - outputs/inputs and the admin seed
        # are written first. Destinations are configured in our app below
        # rather than via RECEIVING_INDEXER (which only takes one indexer).
        $msiLog = Join-Path $env:TEMP 'splunkforwarder-install.log'
        $msiArgs = @(
            '/i', "`"$msi`"",
            'AGREETOLICENSE=Yes',
            "INSTALLDIR=`"$InstallDir`"",
            'LAUNCHSPLUNK=0',
            'SERVICESTARTTYPE=auto',
            '/quiet', '/norestart',
            '/L*v', "`"$msiLog`""
        )
        if ($UseLocalSystem) { $msiArgs += 'USE_LOCAL_SYSTEM=1' }

        Write-Log "Installing $msi (log: $msiLog)"
        $proc = Start-Process -FilePath 'msiexec.exe' -ArgumentList $msiArgs -Wait -PassThru
        switch ($proc.ExitCode) {
            0       { Write-Log 'MSI install succeeded.' }
            3010    { Write-Warn 'MSI install succeeded; a reboot is required to complete it.' }
            default { Stop-WithError "msiexec failed with exit code $($proc.ExitCode). See $msiLog" }
        }
        if (-not (Test-Path -LiteralPath $SplunkExe)) { Stop-WithError "Install failed: $SplunkExe not found." }
    } else {
        Write-Log "Forwarder already installed at $InstallDir (use -Force to reinstall)"
        Stop-Service -Name $ServiceName -Force -ErrorAction SilentlyContinue
    }
} finally {
    if ($downloadDir) { Remove-Item -LiteralPath $downloadDir -Recurse -Force -ErrorAction SilentlyContinue }
}

# ----------------------------------------------------------------------------
# Configuration
# ----------------------------------------------------------------------------
$appDir   = Join-Path $InstallDir "etc\apps\$AppName"
$appLocal = Join-Path $appDir 'local'
New-Item -ItemType Directory -Force -Path $appLocal, (Join-Path $appDir 'metadata') | Out-Null

Write-ConfFile (Join-Path $appDir 'metadata\local.meta') @(
    '[]'
    'access = read : [ * ], write : [ admin ]'
    'export = system'
)

# Seed the admin account on first start only (Splunk deletes this file once
# it has been consumed).
if ($needsSeed -and $plainPassword) {
    Write-Log 'Writing user-seed.conf'
    $seed = Join-Path $InstallDir 'etc\system\local\user-seed.conf'
    New-Item -ItemType Directory -Force -Path (Split-Path $seed) | Out-Null
    Write-ConfFile $seed @(
        '[user_info]'
        "USERNAME = $AdminUser"
        "PASSWORD = $plainPassword"
    )
}

$outputsConf = Join-Path $appLocal 'outputs.conf'
if ($Indexers) {
    Write-Log "Writing outputs.conf -> $($Indexers -join ',')"
    $lines = @(
        '[tcpout]'
        'defaultGroup = primary_indexers'
        ''
        '[tcpout:primary_indexers]'
        "server = $($Indexers -join ',')"
        'useACK = true'
        'autoLBFrequency = 30'
    )
    if ($Tls) {
        $lines += 'useSSL = true'
        if ($CaCert) {
            Copy-Item -LiteralPath $CaCert -Destination (Join-Path $InstallDir 'etc\auth\org_ca.pem') -Force
            $lines += 'sslVerifyServerCert = true'
            $lines += 'sslRootCAPath = $SPLUNK_HOME\etc\auth\org_ca.pem'
        } else {
            $lines += 'sslVerifyServerCert = false'
        }
    }
    Write-ConfFile $outputsConf $lines
} else {
    Remove-Item -LiteralPath $outputsConf -ErrorAction SilentlyContinue
}

$dcConf = Join-Path $appLocal 'deploymentclient.conf'
if ($DeploymentServer) {
    Write-Log "Writing deploymentclient.conf -> $DeploymentServer"
    $lines = @('[deployment-client]')
    if ($ClientName) { $lines += "clientName = $ClientName" }
    $lines += @('', '[target-broker:deploymentServer]', "targetUri = $DeploymentServer")
    Write-ConfFile $dcConf $lines
} else {
    Remove-Item -LiteralPath $dcConf -ErrorAction SilentlyContinue
}

$inputsConf = Join-Path $appLocal 'inputs.conf'
if ($Monitor -or $WinEventLogs) {
    Write-Log "Writing inputs.conf ($($Monitor.Count) monitor(s), $($WinEventLogs.Count) event log(s))"
    $lines = @()
    foreach ($spec in $Monitor) {
        $path, $index, $sourcetype = $spec -split '\|', 3
        if (-not (Test-Path -LiteralPath $path)) { Write-Warn "Monitor path does not exist yet: $path" }
        $lines += "[monitor://$path]"
        $lines += 'disabled = false'
        if ($index)      { $lines += "index = $index" }
        if ($sourcetype) { $lines += "sourcetype = $sourcetype" }
        $lines += ''
    }
    foreach ($channel in $WinEventLogs) {
        $lines += "[WinEventLog://$channel]"
        $lines += 'disabled = false'
        $lines += 'start_from = oldest'
        $lines += 'current_only = 0'
        $lines += 'renderXml = true'
        if ($EventLogIndex) { $lines += "index = $EventLogIndex" }
        $lines += ''
    }
    Write-ConfFile $inputsConf $lines
} else {
    Remove-Item -LiteralPath $inputsConf -ErrorAction SilentlyContinue
}

# The default service account since UF 9.1 is the low-privilege virtual
# account 'NT SERVICE\SplunkForwarder'. Reading the Security log needs
# membership of 'Event Log Readers'; monitored files need read access.
$svc = Get-CimInstance Win32_Service -Filter "Name='$ServiceName'" -ErrorAction SilentlyContinue
$runAs = if ($svc) { $svc.StartName } else { $null }
if ($runAs -and $runAs -ne 'LocalSystem') {
    if ($WinEventLogs -contains 'Security') {
        try {
            Add-LocalGroupMember -SID 'S-1-5-32-573' -Member $runAs -ErrorAction Stop   # Event Log Readers
            Write-Log "Added $runAs to Event Log Readers"
        } catch {
            if ($_.Exception.Message -notmatch 'already a member') {
                Write-Warn "Could not add $runAs to Event Log Readers: $($_.Exception.Message)"
            }
        }
    }
    foreach ($spec in $Monitor) {
        $path = ($spec -split '\|', 2)[0]
        if (-not (Test-Path -LiteralPath $path)) { continue }
        $out = & icacls.exe $path /grant "${runAs}:(OI)(CI)RX" /T /C /Q 2>&1
        if ($LASTEXITCODE -ne 0) { Write-Warn "Could not grant $runAs read on ${path}: $out" }
    }
}

# ----------------------------------------------------------------------------
# Start + verify
# ----------------------------------------------------------------------------
Set-Service -Name $ServiceName -StartupType Automatic
Write-Log 'Starting SplunkForwarder service'
Start-Service -Name $ServiceName
(Get-Service -Name $ServiceName).WaitForStatus('Running', [TimeSpan]::FromSeconds(60))
Write-Log "Forwarder is running as $runAs."

if ($Indexers) {
    Start-Sleep -Seconds 10
    $splunkdLog = Join-Path $InstallDir 'var\log\splunk\splunkd.log'
    if (Test-Path -LiteralPath $splunkdLog) {
        Write-Log 'Connection status (may take ~30s to establish):'
        Select-String -LiteralPath $splunkdLog -Pattern 'TcpOutputProc|Connected to idx' |
            Select-Object -Last 5 | ForEach-Object { $_.Line }
    }
}

@"

Deployment complete.
  Install dir : $InstallDir
  Run as      : $runAs
  Config app  : $appLocal
  Indexers    : $(if ($Indexers) { $Indexers -join ',' } else { '<none - expecting outputs from deployment server>' })
  Deploy srv  : $(if ($DeploymentServer) { $DeploymentServer } else { '<none>' })

Verify on the Splunk Enterprise side:
  index=_internal host=$env:COMPUTERNAME sourcetype=splunkd | head 10
"@ | Write-Host
