#Requires -Version 5.1
<#
.SYNOPSIS
    Dad's MMO Lab -- WoW Playerbots Installer for Windows (WSL containers / wslc)
.DESCRIPTION
    Installs AzerothCore WotLK + mod-playerbots with Microsoft's built-in
    WSL container engine (wslc.exe, WSL 2.9.3 or newer). No Docker Desktop,
    no DML substrate and no Linux distro are needed.

    wslc has no Compose support yet, so this script does the orchestration
    itself: it builds the images from AzerothCore's Dockerfile, creates the
    network and volumes, and starts the containers in the right order.

    The same script also manages the server after install:
      -Action Start | Stop | Status | Console
    The installer copies itself into the install folder and writes
    Start-Server.cmd / Stop-Server.cmd / GM-Console.cmd shortcuts.

    Version: 1.0.1

    What the install does:
      1. Verifies wslc, Git, disk space, ports
      2. Shows a summary before building
      3. Clones AzerothCore WotLK (Playerbot branch) + mod-playerbots
      4. Builds the server images with wslc (~2-4 hours)
      5. Imports the databases, initializes acore_playerbots, starts the server
      6. Creates the playerbot config and guides you through account creation

    Changelog:
      1.0.1 - Fix: acore_playerbots init failed with 'Could not copy the playerbots SQL
              files'. The base SQL is now imported by a short-lived mysql client
              container with a bind mount instead of 'wslc container cp'.
      1.0.0 - Initial WSL containers release
        - Mirrors the startup flow of Install-WoW-WotLK.ps1 / the Docker Desktop variant
        - Replaces docker compose with explicit wslc network/volume/run calls
        - Ports bound to 127.0.0.1 unless -Lan is given; the database is always local-only

.PARAMETER Action
    Install (default), Start, Stop, Status or Console.
.PARAMETER InstallDir
    Windows folder for the server source and config.
    Default: C:\DML\games\wow-server-playerbots-wslc
.PARAMETER MinBots
    Minimum number of random bots (default 200). Install only.
.PARAMETER MaxBots
    Maximum number of random bots (default 250). Install only.
.PARAMETER Lan
    Publish the auth/world ports on all network interfaces so other PCs can
    connect. Default: only this PC (127.0.0.1). Install only.
.EXAMPLE
    Set-ExecutionPolicy Bypass -Scope Process -Force
    & "C:\DML\Install-WoW-WotLK-WSLContainers.ps1"
.EXAMPLE
    & .\Install-WoW-WotLK-WSLContainers.ps1 -Action Start
#>

[CmdletBinding()]
param(
    [ValidateSet('Install', 'Start', 'Stop', 'Status', 'Console')]
    [string]$Action = 'Install',
    [string]$InstallDir = "$env:SystemDrive\DML\games\wow-server-playerbots-wslc",
    [ValidateRange(0, 5000)][int]$MinBots = 200,
    [ValidateRange(0, 5000)][int]$MaxBots = 250,
    [switch]$Lan
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# =============================================================================
# Config
# =============================================================================
$WizardVersion       = '1.0.1'
$MinWslVersion       = [version]'2.9.3'
$CoreRepo            = 'https://github.com/mod-playerbots/azerothcore-wotlk.git'
$CoreBranch          = 'Playerbot'
$ModuleRepo          = 'https://github.com/mod-playerbots/mod-playerbots.git'
$ModuleBranch        = 'master'
$DbRootPassword      = 'password'   # upstream default; the DB port is bound to 127.0.0.1 only
$ImageTag            = 'master'
$NetworkName         = 'ac-network'
$DbVolume            = 'ac-database'
$DataVolume          = 'ac-client-data'
$LogFile             = "$env:TEMP\dml-wow-wslc-install.log"
$BuildLog            = "$env:TEMP\dml-wow-wslc-build.log"
$Script:FailReported = $false

$Images = [ordered]@{
    'worldserver' = "acore/ac-wotlk-worldserver:$ImageTag"
    'authserver'  = "acore/ac-wotlk-authserver:$ImageTag"
    'db-import'   = "acore/ac-wotlk-db-import:$ImageTag"
    'client-data' = "acore/ac-wotlk-client-data:$ImageTag"
}

if ($MinBots -gt $MaxBots) { throw "-MinBots ($MinBots) must not be greater than -MaxBots ($MaxBots)." }
$InstallDir = [System.IO.Path]::GetFullPath($InstallDir)
$EtcDir     = Join-Path $InstallDir 'env\dist\etc'
$LogsDir    = Join-Path $InstallDir 'env\dist\logs'
$ConfigFile = Join-Path $InstallDir 'dml-wslc.json'

# =============================================================================
# Output helpers
# =============================================================================
function Write-Header {
    Clear-Host
    Write-Host ''
    Write-Host '  +==================================================+' -ForegroundColor Cyan
    Write-Host '  |  DAD''S MMO LAB                                   |' -ForegroundColor White
    Write-Host '  |  WoW Playerbots Installer (WSL containers)       |' -ForegroundColor White
    Write-Host '  |  github.com/DadsMmoLab/dads-mmo-lab              |' -ForegroundColor Blue
    Write-Host "  |  Version $WizardVersion                                   |" -ForegroundColor Yellow
    Write-Host '  +==================================================+' -ForegroundColor Cyan
    Write-Host ''
}

function Write-Step([string]$msg) {
    Write-Host ''
    Write-Host '  --------------------------------------------------' -ForegroundColor Cyan
    Write-Host "   $msg" -ForegroundColor White
    Write-Host '  --------------------------------------------------' -ForegroundColor Cyan
}

function Write-Log([string]$line) {
    Add-Content -Path $LogFile -Value "$(Get-Date -Format 'HH:mm:ss') $line" -ErrorAction SilentlyContinue
}
function Write-Ok([string]$msg)   { Write-Host "[ok]   $msg" -ForegroundColor Green;  Write-Log "[ok]   $msg" }
function Write-Warn([string]$msg) { Write-Host "[WARN] $msg" -ForegroundColor Yellow; Write-Log "[WARN] $msg" }
function Write-Info([string]$msg) { Write-Host "[info] $msg" -ForegroundColor Cyan;   Write-Log "[info] $msg" }
function Write-Diag([string]$msg) { Write-Log "[diag] $msg" }
function Write-Fail([string]$msg) {
    Write-Host "[FAIL] $msg" -ForegroundColor Red
    Write-Log "[FAIL] $msg"
    $Script:FailReported = $true
    throw $msg
}

function Invoke-YesNo([string]$prompt) {
    while ($true) {
        Write-Host "  $prompt (y/n): " -NoNewline -ForegroundColor White
        $ans = Read-Host
        if ($ans -match '^[Yy]') { return $true }
        if ($ans -match '^[Nn]') { return $false }
        Write-Host '  Please answer y or n.' -ForegroundColor Yellow
    }
}

# =============================================================================
# Native command helpers -- EAP-safe for PowerShell 5.1
# wslc and git write normal progress to stderr. With EAP=Stop and 2>&1,
# PS 5.1 turns those lines into terminating errors, so every native call
# runs with EAP lowered to Continue and stderr records converted to text.
# Arguments never contain double quotes: PS 5.1 does not escape embedded
# quotes when passing arguments to native commands.
# =============================================================================

# Run a native command, stream its output to the console (and optionally a
# log file), return the exit code.
function Invoke-Native {
    param(
        [Parameter(Mandatory)][string]$Exe,
        [string[]]$Arguments = @(),
        [string]$TeeFile,
        [switch]$Quiet
    )
    Write-Diag "exec: $Exe $($Arguments -join ' ')"
    $prevEap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try {
        if ($TeeFile) {
            & $Exe @Arguments 2>&1 | ForEach-Object { "$_" } | Tee-Object -FilePath $TeeFile -Append | Out-Host
        } elseif ($Quiet) {
            & $Exe @Arguments 2>&1 | Out-Null
        } else {
            & $Exe @Arguments 2>&1 | ForEach-Object { "$_" } | Out-Host
        }
        $exit = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prevEap
    }
    Write-Diag "exit: $exit"
    return $exit
}

# Run a native command and return its trimmed stdout (stderr discarded).
function Invoke-Capture {
    param(
        [Parameter(Mandatory)][string]$Exe,
        [string[]]$Arguments = @()
    )
    $prevEap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try {
        $raw = & $Exe @Arguments 2>$null
        $Script:LastCaptureExit = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prevEap
    }
    return ((@($raw) | Where-Object { $_ -is [string] }) -join "`n").Trim()
}

function Invoke-Wslc([string[]]$Arguments, [string]$TeeFile, [switch]$Quiet) {
    return (Invoke-Native -Exe 'wslc' -Arguments $Arguments -TeeFile $TeeFile -Quiet:$Quiet)
}

function Write-Utf8NoBom([string]$Path, [string]$Content) {
    [System.IO.File]::WriteAllBytes($Path, [System.Text.UTF8Encoding]::new($false).GetBytes($Content.Replace("`r`n", "`n")))
}

function Update-SessionPath {
    $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $user    = [Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path = "$machine;$user"
    foreach ($extra in @("$env:ProgramFiles\WSL", "$env:ProgramFiles\Git\cmd")) {
        if ((Test-Path $extra) -and ($env:Path -notlike "*$extra*")) { $env:Path = "$env:Path;$extra" }
    }
}

function Test-Command([string]$name) {
    return [bool](Get-Command $name -ErrorAction SilentlyContinue)
}

function Test-IsElevated {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-FreeGB([string]$path) {
    try {
        $drive = New-Object System.IO.DriveInfo([System.IO.Path]::GetPathRoot($path))
        return [math]::Floor($drive.AvailableFreeSpace / 1GB)
    } catch {
        return -1
    }
}

# =============================================================================
# wslc object helpers
# =============================================================================

# Returns Status ('running', 'exited', ... or '' if the container does not
# exist), Health ('healthy', 'starting', ... or '') and ExitCode.
# 'wslc container inspect' prints a JSON array (Docker-compatible schema).
function Get-ContainerState([string]$name) {
    $empty = [pscustomobject]@{ Status = ''; Health = ''; ExitCode = '' }
    $json = Invoke-Capture 'wslc' @('container', 'inspect', $name)
    if ($Script:LastCaptureExit -ne 0 -or -not $json) { return $empty }
    try {
        # PS 5.1 emits a JSON array as one Object[] item, PS 7 enumerates it
        $arr = @(ConvertFrom-Json -InputObject $json)
    } catch {
        return $empty
    }
    if ($arr.Count -eq 0) { return $empty }
    $info = $arr[0]
    if ($info -is [array]) { if ($info.Count -eq 0) { return $empty }; $info = $info[0] }
    if (-not $info -or -not $info.PSObject.Properties['State']) { return $empty }
    $state = $info.State
    $health = ''
    if ($state.PSObject.Properties['Health'] -and $state.Health) { $health = [string]$state.Health.Status }
    return [pscustomobject]@{ Status = [string]$state.Status; Health = $health; ExitCode = [string]$state.ExitCode }
}

function Test-ContainerExists([string]$name) { return [bool](Get-ContainerState $name).Status }

function Remove-ContainerIfExists([string]$name) {
    if (Test-ContainerExists $name) {
        Write-Diag "removing container $name"
        $null = Invoke-Wslc @('container', 'rm', '--force', $name) -Quiet
    }
}

function Test-ImageExists([string]$tag) {
    $null = Invoke-Capture 'wslc' @('image', 'inspect', $tag)
    return ($Script:LastCaptureExit -eq 0)
}

function Initialize-NetworkAndVolumes {
    $null = Invoke-Capture 'wslc' @('network', 'inspect', $NetworkName)
    if ($Script:LastCaptureExit -ne 0) {
        if ((Invoke-Wslc @('network', 'create', $NetworkName) -Quiet) -ne 0) { Write-Fail "Could not create the wslc network '$NetworkName'." }
        Write-Ok "Network $NetworkName created"
    }
    foreach ($vol in $DbVolume, $DataVolume) {
        $null = Invoke-Capture 'wslc' @('volume', 'inspect', $vol)
        if ($Script:LastCaptureExit -ne 0) {
            if ((Invoke-Wslc @('volume', 'create', $vol) -Quiet) -ne 0) { Write-Fail "Could not create the wslc volume '$vol'." }
            Write-Ok "Volume $vol created"
        }
    }
}

# Wipe the database volume (used after a failed import). Player data does not
# exist yet at that point.
function Reset-DatabaseVolume {
    foreach ($c in 'ac-worldserver', 'ac-authserver', 'ac-db-import', 'ac-database') { Remove-ContainerIfExists $c }
    $null = Invoke-Wslc @('volume', 'rm', $DbVolume) -Quiet
    $null = Invoke-Wslc @('volume', 'create', $DbVolume) -Quiet
}

# =============================================================================
# Container definitions -- the equivalent of AzerothCore's docker-compose.yml
# =============================================================================
function Get-Settings {
    # Settings chosen at install time are stored next to the server so that
    # -Action Start recreates containers with the same values.
    $s = [ordered]@{ MinBots = $MinBots; MaxBots = $MaxBots; Lan = [bool]$Lan }
    if ($Action -ne 'Install' -and (Test-Path $ConfigFile)) {
        try {
            $saved = Get-Content -Raw -Path $ConfigFile | ConvertFrom-Json
            foreach ($k in @($s.Keys)) { if ($saved.PSObject.Properties[$k]) { $s[$k] = $saved.$k } }
        } catch { Write-Diag "could not read $ConfigFile" }
    }
    return $s
}

function Save-Settings($s) {
    Write-Utf8NoBom $ConfigFile (($s | ConvertTo-Json) + "`n")
}

function Get-DbInfo([string]$database) {
    return "ac-database;3306;root;$DbRootPassword;$database"
}

function Get-ContainerArgs([string]$name, $s) {
    $bind = if ($s.Lan) { '0.0.0.0' } else { '127.0.0.1' }
    $envFile = Join-Path $InstallDir 'conf\dist\env.ac'
    switch ($name) {
        'ac-database' {
            return @('container', 'run', '--detach', '--name', 'ac-database', '--network', $NetworkName,
                '--publish', '127.0.0.1:3306:3306',
                '--env', "MYSQL_ROOT_PASSWORD=$DbRootPassword",
                '--volume', "${DbVolume}:/var/lib/mysql",
                # Plain TCP probe with a long budget: mysqladmin-based probes can
                # fail on MySQL 8.4 under WSL, and first-run init can be slow.
                '--health-cmd', "bash -c 'echo > /dev/tcp/127.0.0.1/3306'",
                '--health-interval', '5s', '--health-timeout', '5s',
                '--health-retries', '180', '--health-start-period', '60s',
                'mysql:8.4')
        }
        'ac-client-data-init' {
            return @('container', 'run', '--detach', '--name', 'ac-client-data-init',
                '--volume', "${DataVolume}:/azerothcore/env/dist/data",
                $Images['client-data'])
        }
        'ac-db-import' {
            return @('container', 'run', '--detach', '--name', 'ac-db-import', '--network', $NetworkName,
                '--env', 'AC_DATA_DIR=/azerothcore/env/dist/data',
                '--env', 'AC_LOGS_DIR=/azerothcore/env/dist/logs',
                '--env', "AC_LOGIN_DATABASE_INFO=$(Get-DbInfo 'acore_auth')",
                '--env', "AC_WORLD_DATABASE_INFO=$(Get-DbInfo 'acore_world')",
                '--env', "AC_CHARACTER_DATABASE_INFO=$(Get-DbInfo 'acore_characters')",
                '--volume', "${EtcDir}:/azerothcore/env/dist/etc",
                '--volume', "${LogsDir}:/azerothcore/env/dist/logs",
                $Images['db-import'])
        }
        'ac-worldserver' {
            return @('container', 'run', '--detach', '--interactive', '--tty', '--name', 'ac-worldserver', '--network', $NetworkName,
                '--publish', "${bind}:8085:8085",
                '--publish', '127.0.0.1:7878:7878',
                '--env-file', $envFile,
                '--env', 'AC_DATA_DIR=/azerothcore/env/dist/data',
                '--env', 'AC_LOGS_DIR=/azerothcore/env/dist/logs',
                '--env', "AC_LOGIN_DATABASE_INFO=$(Get-DbInfo 'acore_auth')",
                '--env', "AC_WORLD_DATABASE_INFO=$(Get-DbInfo 'acore_world')",
                '--env', "AC_CHARACTER_DATABASE_INFO=$(Get-DbInfo 'acore_characters')",
                '--env', "AC_PLAYERBOTS_DATABASE_INFO=$(Get-DbInfo 'acore_playerbots')",
                '--env', 'AC_PLAYERBOTS_UPDATES_ENABLE_DATABASES=1',
                '--env', 'AC_AI_PLAYERBOT_RANDOM_BOT_AUTOLOGIN=1',
                '--env', "AC_AI_PLAYERBOT_MIN_RANDOM_BOTS=$($s.MinBots)",
                '--env', "AC_AI_PLAYERBOT_MAX_RANDOM_BOTS=$($s.MaxBots)",
                '--env', 'AC_PLAYERBOTS_DATABASE_WORKER_THREADS=1',
                '--env', 'AC_PLAYERBOTS_DATABASE_SYNCH_THREADS=1',
                '--volume', "${EtcDir}:/azerothcore/env/dist/etc",
                '--volume', "${LogsDir}:/azerothcore/env/dist/logs",
                '--volume', "${DataVolume}:/azerothcore/env/dist/data:ro",
                '--volume', "$(Join-Path $InstallDir 'modules'):/azerothcore/modules",
                $Images['worldserver'])
        }
        'ac-authserver' {
            return @('container', 'run', '--detach', '--tty', '--name', 'ac-authserver', '--network', $NetworkName,
                '--publish', "${bind}:3724:3724",
                '--env-file', $envFile,
                '--env', 'AC_LOGS_DIR=/azerothcore/env/dist/logs',
                '--env', 'AC_TEMP_DIR=/azerothcore/env/dist/temp',
                '--env', "AC_LOGIN_DATABASE_INFO=$(Get-DbInfo 'acore_auth')",
                '--volume', "${EtcDir}:/azerothcore/env/dist/etc",
                '--volume', "${LogsDir}:/azerothcore/env/dist/logs",
                $Images['authserver'])
        }
    }
    throw "Unknown container: $name"
}

# (Re)create a container from its definition and start it.
function New-AcContainer([string]$name, $s) {
    Remove-ContainerIfExists $name
    return ((Invoke-Wslc (Get-ContainerArgs $name $s)) -eq 0)
}

# =============================================================================
# Prerequisites
# =============================================================================
function Get-WslVersion {
    # 'wsl --version' is localized ("WSL version: 2.9.3.0" / "WSL-Version: ...");
    # take the first version number of the first line. UTF-16 output -> strip NULs.
    $out = (Invoke-Capture 'wsl' @('--version')) -replace "`0", ''
    $first = ($out -split "`n" | Select-Object -First 1)
    if ($first -match '(\d+\.\d+\.\d+)') { return [version]$Matches[1] }
    return $null
}

function Assert-Wslc {
    Update-SessionPath

    $ver = Get-WslVersion
    if (-not (Test-Command 'wslc') -or -not $ver -or $ver -lt $MinWslVersion) {
        $shown = if ($ver) { $ver } else { 'not installed' }
        Write-Warn "WSL containers need WSL $MinWslVersion or newer (found: $shown)."
        if (Invoke-YesNo 'Update WSL now? (Windows may ask for admin permission)') {
            $exit = Invoke-Native -Exe 'wsl' -Arguments @('--update')
            Update-SessionPath
            $ver = Get-WslVersion
            if ($exit -ne 0 -or -not $ver -or $ver -lt $MinWslVersion -or -not (Test-Command 'wslc')) {
                Write-Fail "WSL update did not provide wslc.exe.`nRun 'wsl --update' (or 'wsl --install' if WSL is missing), restart your PC and re-run this installer."
            }
        } else {
            Write-Fail "Run 'wsl --update' in PowerShell, then re-run this installer."
        }
    }
    Write-Ok "WSL $ver with wslc"

    # First call boots the wslc session VM (can take ~30 s)
    Write-Info 'Starting the WSL container session...'
    $null = Invoke-Capture 'wslc' @('container', 'list')
    if ($Script:LastCaptureExit -ne 0) {
        Write-Fail "wslc could not start its session.`nTry 'wsl --shutdown', then re-run. Check 'wslc version' and https://aka.ms/wslc-settings."
    }
    Write-Ok 'WSL container session running'
}

function Assert-Git {
    Update-SessionPath
    if (Test-Command 'git') { Write-Ok 'Git found'; return }

    Write-Warn 'Git is not installed.'
    if ((Test-Command 'winget') -and (Invoke-YesNo 'Install Git now with winget?')) {
        $exit = Invoke-Native -Exe 'winget' -Arguments @('install', '-e', '--id', 'Git.Git', '--accept-source-agreements', '--accept-package-agreements')
        Update-SessionPath
        if ($exit -eq 0 -and (Test-Command 'git')) { Write-Ok 'Git installed'; return }
    }
    Write-Fail "Git is required. Install it from https://git-scm.com/download/win and re-run this installer."
}

function Assert-NotElevated {
    # wslc keeps a separate session (images, containers, volumes) for elevated
    # callers ('wslc-cli-admin'). Installing elevated would hide the server
    # from the normal, non-admin shortcuts.
    if (Test-IsElevated) {
        Write-Fail "Please run this script in a NORMAL (non-administrator) PowerShell window.`nwslc keeps admin and non-admin containers separate."
    }
}

function Assert-Prerequisites {
    Write-Step 'Checking Prerequisites'

    Assert-NotElevated
    Assert-Wslc
    Assert-Git

    # RAM: the wslc session gets half of the PC's memory by default; the C++
    # build runs nproc+1 compile jobs.
    try {
        $totalGB = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB, 1)
        if ($totalGB -lt 12) {
            Write-Warn "This PC has ${totalGB} GB RAM; the WSL container session gets about half by default."
            Write-Info 'If the compile fails with "Killed", raise session.memorySize in the wslc settings'
            Write-Info '(run: wslc settings) -- see https://aka.ms/wslc-settings'
            if (-not (Invoke-YesNo 'Continue anyway?')) { exit 0 }
        } else {
            Write-Ok "RAM: ${totalGB} GB"
        }
    } catch { Write-Diag 'could not read RAM size' }

    # Disk: the wslc session VHD lives under %LOCALAPPDATA%\wslc\sessions by
    # default (~30 GB for build cache + images), the source in InstallDir (~3 GB).
    $wslcDrive    = [System.IO.Path]::GetPathRoot($env:LOCALAPPDATA)
    $installDrive = [System.IO.Path]::GetPathRoot($InstallDir)
    if ($wslcDrive -eq $installDrive) {
        $free = Get-FreeGB $InstallDir
        if ($free -ge 0 -and $free -lt 33) { Write-Fail "Not enough space on ${installDrive}: ${free} GB free, need at least 33 GB." }
        if ($free -ge 0) { Write-Ok "Disk space OK (${free} GB free on $installDrive)" }
    } else {
        $freeW = Get-FreeGB $env:LOCALAPPDATA
        $freeI = Get-FreeGB $InstallDir
        if ($freeW -ge 0 -and $freeW -lt 30) {
            Write-Warn "Only ${freeW} GB free on $wslcDrive (default wslc storage). The build needs ~30 GB."
            Write-Info 'If you moved the wslc storage (session.storagePath), you can ignore this.'
            if (-not (Invoke-YesNo 'Continue anyway?')) { exit 0 }
        }
        if ($freeI -ge 0 -and $freeI -lt 3) { Write-Fail "Not enough space on ${installDrive}: ${freeI} GB free, need at least 3 GB." }
        Write-Ok "Disk space OK ($wslcDrive ${freeW} GB, $installDrive ${freeI} GB)"
    }

    # Ports -- another WoW server (DML/WSL, Docker Desktop) must not hold them
    foreach ($port in 3724, 8085) {
        $listener = Get-NetTCPConnection -State Listen -LocalPort $port -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($listener -and (Get-ContainerState 'ac-authserver').Status -ne 'running') {
            $proc = (Get-Process -Id $listener.OwningProcess -ErrorAction SilentlyContinue).ProcessName
            Write-Warn "Port $port is already in use (process: $proc)."
            Write-Info 'Another WoW server may be running (DML/WSL or Docker Desktop). Stop it first.'
            if (-not (Invoke-YesNo 'Continue anyway?')) { exit 0 }
        }
    }

    try {
        $null = Invoke-WebRequest -Uri 'https://github.com' -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop
        Write-Ok 'Internet connection OK'
    } catch {
        Write-Fail 'No internet connection detected. Connect and try again.'
    }
}

# =============================================================================
# Summary
# =============================================================================
function Show-Summary {
    Write-Header
    Write-Step 'STEP 1/3 -- What We''re Building'
    Write-Host ''
    Write-Host '  Server:    WoW Playerbots (AzerothCore WotLK + Playerbots)' -ForegroundColor Cyan
    Write-Host "  Location:  $InstallDir" -ForegroundColor Cyan
    Write-Host '  Engine:    WSL containers (wslc)' -ForegroundColor Cyan
    Write-Host "  Bots:      $MinBots - $MaxBots random bots" -ForegroundColor Cyan
    $reach = if ($Lan) { 'this PC + your network (LAN)' } else { 'this PC only (use -Lan for LAN play)' }
    Write-Host "  Reachable: $reach" -ForegroundColor Cyan
    Write-Host '  Install:   Compile from source (2-4 hours)' -ForegroundColor Yellow
    Write-Host ''
    Write-Host '  What you get:' -ForegroundColor White
    Write-Host '    + Hundreds of AI players roaming the world' -ForegroundColor Green
    Write-Host '    + Bots quest, dungeon, raid alongside you' -ForegroundColor Green
    Write-Host '    + Azeroth feels truly alive -- solo or co-op' -ForegroundColor Green
    Write-Host ''
    Write-Host '  COMPILATION WARNING:' -ForegroundColor Yellow
    Write-Host '  This will take 2-4 hours. Keep your PC running and plugged in.' -ForegroundColor White
    Write-Host "  Progress is logged to: $LogFile" -ForegroundColor White
    Write-Host "  Build output:          $BuildLog" -ForegroundColor White
    Write-Host ''
    if (-not (Invoke-YesNo 'Ready to build your Playerbots server?')) {
        Write-Host ''
        Write-Host "  No problem -- run this script again when you're ready." -ForegroundColor White
        exit 0
    }
}

# =============================================================================
# Source checkout
# =============================================================================
function Test-SourceComplete {
    return ((Test-Path (Join-Path $InstallDir 'apps\docker\Dockerfile')) -and
            (Test-Path (Join-Path $InstallDir 'conf\dist\env.ac')) -and
            (Test-Path (Join-Path $InstallDir 'modules\mod-playerbots\data\sql\playerbots\base')))
}

function Test-IsOurCheckout {
    if (-not (Test-Path (Join-Path $InstallDir '.git'))) { return $false }
    $origin = Invoke-Capture 'git' @('-C', $InstallDir, 'remote', 'get-url', 'origin')
    return ($origin -match 'azerothcore-wotlk')
}

function Get-Source {
    if (Test-SourceComplete) {
        Write-Ok "Source already present in $InstallDir -- skipping clone."
        return
    }

    if (Test-Path $InstallDir) {
        $isEmpty = -not (Get-ChildItem -Force -Path $InstallDir -ErrorAction SilentlyContinue | Select-Object -First 1)
        if (-not $isEmpty) {
            if (-not (Test-IsOurCheckout)) {
                Write-Fail "$InstallDir already exists and is not an AzerothCore checkout.`nChoose another folder with -InstallDir, or empty it first."
            }
            Write-Info 'Removing incomplete previous checkout...'
            Remove-Item -Recurse -Force -Path $InstallDir
        }
    }
    $parent = Split-Path -Parent $InstallDir
    if (-not (Test-Path $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }

    # core.autocrlf=false: Windows Git defaults to CRLF checkouts, which breaks
    # the shell scripts copied into the Linux images. core.longpaths=true:
    # some paths in the source tree exceed MAX_PATH.
    $gitCfg = @('-c', 'core.autocrlf=false', '-c', 'core.longpaths=true')

    Write-Info 'Cloning AzerothCore WotLK (Playerbot branch)...'
    $exit = Invoke-Native -Exe 'git' -Arguments ($gitCfg + @('clone', '--depth', '1', '--branch', $CoreBranch, $CoreRepo, $InstallDir))
    if ($exit -ne 0 -or -not (Test-Path (Join-Path $InstallDir 'apps\docker\Dockerfile'))) { Write-Fail "Clone failed (exit $exit). Check your internet connection." }
    $null = Invoke-Native -Exe 'git' -Arguments @('-C', $InstallDir, 'config', 'core.autocrlf', 'false') -Quiet
    $null = Invoke-Native -Exe 'git' -Arguments @('-C', $InstallDir, 'config', 'core.longpaths', 'true') -Quiet

    Write-Info 'Cloning mod-playerbots module...'
    $moduleDir = Join-Path $InstallDir 'modules\mod-playerbots'
    $exit = Invoke-Native -Exe 'git' -Arguments ($gitCfg + @('clone', '--depth', '1', '--branch', $ModuleBranch, $ModuleRepo, $moduleDir))
    if ($exit -ne 0 -or -not (Test-Path (Join-Path $moduleDir 'data'))) {
        Write-Fail 'mod-playerbots clone failed or incomplete -- worldserver cannot start without it.'
    }
    $null = Invoke-Native -Exe 'git' -Arguments @('-C', $moduleDir, 'config', 'core.autocrlf', 'false') -Quiet
    Write-Ok 'Source cloned'
}

# =============================================================================
# Build
# =============================================================================
function Build-Images {
    $missing = @($Images.Keys | Where-Object { -not (Test-ImageExists $Images[$_]) })
    if ($missing.Count -eq 0) {
        Write-Ok 'Compiled images already found -- skipping compile.'
        Write-Info 'To force a fresh compile, remove the images (wslc image rm acore/ac-wotlk-worldserver:master ...) and re-run.'
        return
    }

    Write-Info 'Compiling Playerbots server (2-4 hours)...'
    Write-Info 'Keep your PC running and plugged in.'
    Write-Info 'Go make a coffee -- this will take a while!'
    Remove-Item -Path $BuildLog -ErrorAction SilentlyContinue

    $dockerfile = Join-Path $InstallDir 'apps\docker\Dockerfile'
    # worldserver first: it runs the full C++ compile. The other targets reuse
    # the cached build stage, so they only take a few minutes.
    foreach ($target in @('worldserver', 'authserver', 'db-import', 'client-data')) {
        if ($missing -notcontains $target) { continue }
        Write-Info "Building image: $target"
        $buildArgs = @('image', 'build', '--progress', 'plain',
            '--file', $dockerfile, '--target', $target, '--tag', $Images[$target],
            '--build-arg', 'USER_ID=1000', '--build-arg', 'GROUP_ID=1000', '--build-arg', 'DOCKER_USER=acore',
            $InstallDir)
        $exit = Invoke-Wslc $buildArgs -TeeFile $BuildLog
        if ($exit -ne 0) {
            if (Select-String -Path $BuildLog -Pattern 'Killed|out of memory|signal 9' -Quiet -ErrorAction SilentlyContinue) {
                Write-Warn 'The compiler ran out of memory. Raise session.memorySize in the wslc settings (wslc settings) and re-run.'
            }
            Write-Fail "Building '$target' failed (exit $exit).`nCheck the build log: $BuildLog"
        }
        Write-Ok "Image built: $($Images[$target])"
    }
}

# =============================================================================
# Startup
# =============================================================================

# Start the database and poll its health ourselves -- first-run MySQL
# initialization can take a long time on slow disks.
function Start-DatabaseAndWait($s, [switch]$Recreate) {
    $st = Get-ContainerState 'ac-database'
    if ($Recreate -or -not $st.Status) {
        if (-not (New-AcContainer 'ac-database' $s)) { Write-Warn 'wslc failed to start the database container.'; return $false }
    } elseif ($st.Status -ne 'running') {
        if ((Invoke-Wslc @('container', 'start', 'ac-database') -Quiet) -ne 0) { Write-Warn 'wslc failed to start the database container.'; return $false }
    }

    $t0 = Get-Date
    $lastReport = -1
    while ($true) {
        $st = Get-ContainerState 'ac-database'
        $elapsed = [int]((Get-Date) - $t0).TotalSeconds
        if ($st.Health -eq 'healthy') { Write-Ok "Database is up (took ${elapsed}s)."; return $true }
        if ($st.Status -eq 'exited' -or $st.Status -eq 'dead' -or -not $st.Status) {
            Write-Warn "Database container stopped (exit $($st.ExitCode)). Check: wslc container logs ac-database"
            return $false
        }
        if ($elapsed -ge 3600) { Write-Warn 'Database did not come up within 60 minutes -- giving up.'; return $false }
        $bucket = [math]::Floor($elapsed / 30)
        if ($bucket -ne $lastReport) {
            Write-Info "Database still starting... (${elapsed}s elapsed, health: $($st.Health))"
            $lastReport = $bucket
        }
        Start-Sleep -Seconds 5
    }
}

# Wait for a one-shot container (db-import, client-data-init) to exit;
# returns $true on exit code 0.
function Wait-ContainerExit([string]$name, [int]$timeoutMin, [string]$what) {
    $t0 = Get-Date
    $lastReport = -1
    while ($true) {
        $st = Get-ContainerState $name
        if ($st.Status -eq 'exited' -or $st.Status -eq 'dead') { return ($st.ExitCode -eq '0') }
        if (-not $st.Status) { return $false }
        $min = [math]::Floor(((Get-Date) - $t0).TotalMinutes)
        if ($min -ge $timeoutMin) { Write-Warn "$what did not finish within $timeoutMin minutes."; return $false }
        if ($min -ne $lastReport) {
            Write-Info "$what... ($min min elapsed)"
            $lastReport = $min
        }
        Start-Sleep -Seconds 10
    }
}

function Test-ContainerSucceeded([string]$name) {
    $st = Get-ContainerState $name
    return ($st.Status -eq 'exited' -and $st.ExitCode -eq '0')
}

function Invoke-Mysql([string]$sql) {
    return (Invoke-Capture 'wslc' @('container', 'exec', 'ac-database', 'mysql', '-uroot', "-p$DbRootPassword", '-sN', '-e', $sql))
}

# Initialize the acore_playerbots base schema before worldserver starts.
# Without it the worldserver hits a missing table (update applied before base)
# and sends MySQL SHUTDOWN, which ends in an endless crash loop.
function Initialize-PlayerbotsDb {
    $baseDir = Join-Path $InstallDir 'modules\mod-playerbots\data\sql\playerbots\base'
    $sqlFiles = @(Get-ChildItem -Path $baseDir -Filter '*.sql' -ErrorAction SilentlyContinue)
    if ($sqlFiles.Count -eq 0) { Write-Fail "No playerbots base SQL found in $baseDir" }

    $expected = @($sqlFiles | Select-String -Pattern 'CREATE TABLE' -ErrorAction SilentlyContinue).Count
    if ($expected -lt 1) { $expected = 29 }
    $tablesStr = Invoke-Mysql "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA='acore_playerbots';"
    $tables = if ($tablesStr -match '^\d+$') { [int]$tablesStr } else { 0 }
    if ($tables -ge $expected) {
        Write-Ok "acore_playerbots already has $tables tables -- skipping init."
        return
    }

    Write-Info "Initializing acore_playerbots ($tables/$expected base tables present)..."
    $null = Invoke-Mysql 'DROP DATABASE IF EXISTS acore_playerbots; CREATE DATABASE acore_playerbots DEFAULT CHARSET utf8mb4 COLLATE utf8mb4_unicode_ci;'

    # Import through a short-lived mysql client container that bind-mounts the
    # SQL folder -- the same mechanism the db-import container uses. Piping SQL
    # from PowerShell 5.1 would re-encode it, and 'wslc container cp' needs an
    # existing target directory (Docker archive semantics).
    # MYSQL_PWD keeps the password out of the command line; no double quotes in
    # $importCmd because PS 5.1 does not escape them for native commands.
    $importCmd = 'for f in /pb-base/*.sql; do echo importing $(basename $f); mysql -h ac-database -uroot acore_playerbots < $f || { echo failed: $f; exit 1; }; done'
    Remove-ContainerIfExists 'ac-playerbots-init'
    $runArgs = @('container', 'run', '--detach', '--name', 'ac-playerbots-init', '--network', $NetworkName,
        '--env', "MYSQL_PWD=$DbRootPassword",
        '--volume', "${baseDir}:/pb-base:ro",
        'mysql:8.4', 'bash', '-c', $importCmd)
    $ok = ((Invoke-Wslc $runArgs -Quiet) -eq 0) -and (Wait-ContainerExit 'ac-playerbots-init' 30 'Importing playerbots tables')
    if (-not $ok) {
        Write-Warn 'Output of the playerbots import:'
        $null = Invoke-Wslc @('container', 'logs', '--tail', '30', 'ac-playerbots-init')
        Write-Fail "acore_playerbots initialization failed.`nRe-run the installer -- the compile and the world import are skipped."
    }
    Remove-ContainerIfExists 'ac-playerbots-init'

    $tablesStr = Invoke-Mysql "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA='acore_playerbots';"
    if ($tablesStr -match '^\d+$' -and [int]$tablesStr -lt $expected) {
        Write-Warn "acore_playerbots has $tablesStr tables, the base SQL defines $expected. If the worldserver keeps restarting, check: wslc container logs ac-worldserver"
    }
    Write-Ok 'acore_playerbots initialized.'
}

function Install-Server {
    Write-Header
    Write-Step 'STEP 2/3 -- Building Playerbots Server (2-4 hours)'

    Get-Source
    foreach ($d in $EtcDir, $LogsDir) { if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null } }
    $s = Get-Settings
    Save-Settings $s
    Initialize-NetworkAndVolumes
    Build-Images

    Write-Info 'Starting containers...'
    Remove-ContainerIfExists 'ac-worldserver'
    Remove-ContainerIfExists 'ac-authserver'

    # A failed import from a previous run leaves partial data -- start clean
    $imp = Get-ContainerState 'ac-db-import'
    if ($imp.Status -eq 'exited' -and $imp.ExitCode -ne '0') {
        Write-Warn 'Previous database import failed -- wiping the database volume for a clean import...'
        Reset-DatabaseVolume
    }

    # Map data download runs in parallel with the database setup
    if (-not (Test-ContainerSucceeded 'ac-client-data-init')) {
        Write-Info 'Starting map data download (client-data, ~1.5 GB)...'
        if (-not (New-AcContainer 'ac-client-data-init' $s)) { Write-Fail 'Could not start the client-data container.' }
    }

    # Phase 1: database + world DB import (skipped if a prior import succeeded)
    Write-Info 'Starting database (first-run initialization can take a long time on slow disks)...'
    if (-not (Start-DatabaseAndWait $s -Recreate)) { Write-Fail 'Database failed to start. Check: wslc container logs ac-database' }
    if (-not (Test-ContainerSucceeded 'ac-db-import')) {
        Write-Info 'Importing world databases (5-10 minutes)...'
        $ok = (New-AcContainer 'ac-db-import' $s) -and (Wait-ContainerExit 'ac-db-import' 120 'Importing world databases')
        if (-not $ok) {
            Write-Warn 'Database import failed -- wiping the database volume and retrying once...'
            Reset-DatabaseVolume
            Start-Sleep -Seconds 5
            if (-not (Start-DatabaseAndWait $s -Recreate)) { Write-Fail 'Database failed to start. Check: wslc container logs ac-database' }
            $ok = (New-AcContainer 'ac-db-import' $s) -and (Wait-ContainerExit 'ac-db-import' 120 'Importing world databases')
            if (-not $ok) { Write-Fail "Database import failed twice.`nCheck: wslc container logs ac-db-import" }
        }
        Write-Ok 'Database import complete.'
    }

    # Phase 2: playerbots schema
    Initialize-PlayerbotsDb

    # Phase 3: map data must be complete before the worldserver starts
    if (-not (Wait-ContainerExit 'ac-client-data-init' 120 'Downloading map data (client-data)')) {
        Write-Fail "Map data download failed.`nCheck: wslc container logs ac-client-data-init"
    }
    Write-Ok 'Map data ready.'

    foreach ($c in 'ac-worldserver', 'ac-authserver') {
        if (-not (New-AcContainer $c $s)) {
            Write-Warn "$c start failed -- retrying..."
            Start-Sleep -Seconds 10
            if (-not (New-AcContainer $c $s)) { Write-Fail "$c failed to start. Check: wslc container logs $c" }
        }
    }
    Write-Ok 'Playerbots server started!'
}

# =============================================================================
# Wait for server ready -- polls the worldserver log for "ready..."
# =============================================================================
function Wait-ForServer {
    param([string]$Message = 'First launch after compilation: 30-60 minutes. Subsequent starts: ~30 seconds.')

    Write-Info 'Waiting for world server to initialize...'
    Write-Info $Message
    Write-Host ''

    $t0 = Get-Date
    $lastReport = -1
    while (((Get-Date) - $t0).TotalMinutes -lt 60) {
        $prevEap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        $logs = (& wslc container logs --tail 50 ac-worldserver 2>&1 | ForEach-Object { "$_" }) -join "`n"
        $ErrorActionPreference = $prevEap
        if ($logs -match 'ready\.\.\.') {
            Write-Host ''
            Write-Ok 'Server is READY!'
            return $true
        }
        $st = Get-ContainerState 'ac-worldserver'
        if ($st.Status -ne 'running') {
            # wslc has no restart policy -- a crashed worldserver stays down
            Write-Warn "World server stopped (status: $($st.Status), exit $($st.ExitCode))."
            Write-Info 'Check: wslc container logs --tail 100 ac-worldserver'
            return $false
        }
        $min = [math]::Floor(((Get-Date) - $t0).TotalMinutes)
        if ($min -ne $lastReport) {
            Write-Info "Server still starting... ($min min elapsed -- first boot applies database updates, be patient)"
            $lastReport = $min
        }
        Start-Sleep -Seconds 15
    }
    Write-Host ''
    Write-Warn 'Server is taking longer than expected.'
    Write-Info 'Check: wslc container logs --follow ac-worldserver'
    return $false
}

# =============================================================================
# Playerbot config -- copy .dist to .conf, restart worldserver
# =============================================================================
function Set-PlayerbotConfig {
    Write-Step 'Configuring Playerbots'

    $dist = Join-Path $EtcDir 'modules\playerbots.conf.dist'
    if (-not (Test-Path $dist)) { $dist = Join-Path $EtcDir 'playerbot.conf.dist' }

    $found = $false
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        if (Test-Path $dist) { $found = $true; break }
        if ($attempt -lt 3) {
            Write-Info "playerbot config template not yet visible (attempt $attempt/3) -- waiting 10s..."
            Start-Sleep -Seconds 10
        }
    }
    if (-not $found) {
        $hit = Get-ChildItem -Path $EtcDir -Recurse -Filter 'playerbot*.conf.dist' -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($hit) {
            $dist = $hit.FullName
        } else {
            Write-Warn 'playerbot config template (.conf.dist) not found -- bots use built-in defaults.'
            Write-Info "Expected under: $EtcDir"
            return
        }
    }

    $conf = $dist -replace '\.dist$', ''
    if (Test-Path $conf) { Write-Ok "$(Split-Path -Leaf $conf) already present -- skipping"; return }

    Write-Info "Copying $(Split-Path -Leaf $dist) -> $(Split-Path -Leaf $conf)..."
    try {
        Copy-Item $dist $conf -ErrorAction Stop
        Write-Ok "$(Split-Path -Leaf $conf) created"
    } catch {
        Write-Warn "Failed to copy the playerbot config: $($_.Exception.Message)"
        Write-Info "Fix manually: copy `"$dist`" `"$conf`""
        return
    }

    Write-Info 'Restarting worldserver to load the playerbot config...'
    if ((Invoke-Wslc @('container', 'restart', 'ac-worldserver') -Quiet) -ne 0) {
        Write-Warn 'Worldserver restart failed -- the config loads on the next server start.'
        Write-Info 'Restart manually: wslc container restart ac-worldserver'
        return
    }
    $null = Wait-ForServer 'Restarting to load the playerbot config -- usually ready in ~30 seconds.'
}

# =============================================================================
# Management actions (Start / Stop / Status / Console)
# =============================================================================
function Start-WowServer {
    Assert-NotElevated
    Update-SessionPath
    if (-not (Test-Command 'wslc')) { Write-Fail "wslc not found. Run 'wsl --update' and try again." }
    if (-not (Test-ContainerExists 'ac-database') -and -not (Test-ImageExists $Images['worldserver'])) {
        Write-Fail 'The server is not installed yet. Run this script without -Action first.'
    }
    $s = Get-Settings

    Write-Info 'Starting database...'
    if (-not (Start-DatabaseAndWait $s)) { Write-Fail 'Database failed to start. Check: wslc container logs ac-database' }

    foreach ($c in 'ac-worldserver', 'ac-authserver') {
        $st = Get-ContainerState $c
        if ($st.Status -eq 'running') { Write-Ok "$c already running"; continue }
        $ok = if ($st.Status) { (Invoke-Wslc @('container', 'start', $c) -Quiet) -eq 0 } else { New-AcContainer $c $s }
        if (-not $ok) { Write-Fail "$c failed to start. Check: wslc container logs $c" }
        Write-Ok "$c started"
    }
    $null = Wait-ForServer 'Usually ready in ~30 seconds.'
}

function Stop-WowServer {
    Update-SessionPath
    Write-Info 'Stopping world and auth server (saving characters)...'
    foreach ($c in 'ac-worldserver', 'ac-authserver') {
        if ((Get-ContainerState $c).Status -eq 'running') { $null = Invoke-Wslc @('container', 'stop', '--time', '60', $c) -Quiet }
    }
    Write-Info 'Stopping database...'
    if ((Get-ContainerState 'ac-database').Status -eq 'running') { $null = Invoke-Wslc @('container', 'stop', '--time', '60', 'ac-database') -Quiet }
    Write-Ok 'Server stopped.'
}

function Show-Status {
    Update-SessionPath
    foreach ($c in 'ac-database', 'ac-worldserver', 'ac-authserver') {
        $st = Get-ContainerState $c
        $text = if (-not $st.Status) { 'not created' } elseif ($st.Health) { "$($st.Status) ($($st.Health))" } else { $st.Status }
        $color = if ($st.Status -eq 'running') { 'Green' } else { 'Yellow' }
        Write-Host ("  {0,-16} {1}" -f $c, $text) -ForegroundColor $color
    }
}

function Enter-Console {
    Update-SessionPath
    if ((Get-ContainerState 'ac-worldserver').Status -ne 'running') { Write-Fail 'The world server is not running. Start it first.' }
    Write-Host '  Attaching to the worldserver console.' -ForegroundColor White
    Write-Host '    Create an account:  account create USERNAME PASSWORD' -ForegroundColor Green
    Write-Host '    Make it GM:         account set gmlevel USERNAME 3 -1' -ForegroundColor Green
    Write-Host '    Leave the console:  Ctrl+P then Ctrl+Q   (NEVER Ctrl+C)' -ForegroundColor Yellow
    Write-Host '  Press Enter once if you see no prompt.' -ForegroundColor DarkGray
    Write-Host ''
    & wslc container attach ac-worldserver
}

# =============================================================================
# Shortcuts + management script in the install folder
# =============================================================================
function Write-Shortcuts {
    $self = Join-Path $InstallDir 'Manage-WoW-Server.ps1'
    if ($PSCommandPath -and ((Resolve-Path $PSCommandPath).Path -ne $self)) {
        Copy-Item -Path $PSCommandPath -Destination $self -Force
    }
    $ps = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Manage-WoW-Server.ps1" -InstallDir "%~dp0."'
    $files = [ordered]@{
        'Start-Server.cmd' = "@echo off`n$ps -Action Start`npause"
        'Stop-Server.cmd'  = "@echo off`n$ps -Action Stop`npause"
        'GM-Console.cmd'   = "@echo off`n$ps -Action Console"
        'Status.cmd'       = "@echo off`n$ps -Action Status`npause"
    }
    foreach ($name in $files.Keys) {
        $text = $files[$name].Replace("`n", "`r`n") + "`r`n"
        [System.IO.File]::WriteAllText((Join-Path $InstallDir $name), $text, [System.Text.Encoding]::ASCII)
    }
    Write-Ok 'Shortcuts written: Start-Server.cmd, Stop-Server.cmd, GM-Console.cmd, Status.cmd'
}

# =============================================================================
# Account creation guidance + completion
# =============================================================================
function Show-AccountCreation {
    Write-Header
    Write-Step 'STEP 3/3 -- Create Your Accounts'
    Write-Host ''
    Write-Host '  Your server is running!' -ForegroundColor Green
    Write-Host ''
    Write-Host '  Open a NEW PowerShell window (or double-click GM-Console.cmd in' -ForegroundColor White
    Write-Host "  $InstallDir) and follow these steps:" -ForegroundColor White
    Write-Host ''
    Write-Host '  --------------------------------------------------' -ForegroundColor Cyan
    Write-Host ''
    Write-Host '  1. Open the GM Console:' -ForegroundColor White
    Write-Host '     wslc container attach ac-worldserver' -ForegroundColor Cyan
    Write-Host '     (press Enter once if you see no prompt)' -ForegroundColor DarkGray
    Write-Host ''
    Write-Host '  2. Create your account (replace USERNAME and PASSWORD):' -ForegroundColor White
    Write-Host '     account create USERNAME PASSWORD' -ForegroundColor Green
    Write-Host '     account set gmlevel USERNAME 3 -1' -ForegroundColor Green
    Write-Host ''
    Write-Host '  3. Exit the console safely:' -ForegroundColor White
    Write-Host '     Ctrl+P then Ctrl+Q' -ForegroundColor Yellow
    Write-Host '     Never press Ctrl+C -- that stops the server!' -ForegroundColor Red
    Write-Host ''
    Write-Host '  --------------------------------------------------' -ForegroundColor Cyan
    Write-Host ''
    Write-Host '  Press ENTER when done creating accounts...' -ForegroundColor White
    $null = Read-Host
}

function Show-Completion {
    Write-Host ''
    Write-Host '  +==================================================+' -ForegroundColor Green
    Write-Host '  |   YOUR PLAYERBOTS SERVER IS READY!               |' -ForegroundColor Green
    Write-Host '  +==================================================+' -ForegroundColor Green
    Write-Host ''
    Write-Host '  Server:   wow-server-playerbots (AzerothCore WotLK, WSL containers)' -ForegroundColor Cyan
    Write-Host "  Location: $InstallDir" -ForegroundColor Cyan
    Write-Host ''
    Write-Host '  --------------------------------------------------' -ForegroundColor Cyan
    Write-Host '  STEP A -- Set Your WoW Realmlist' -ForegroundColor White
    Write-Host '  --------------------------------------------------' -ForegroundColor Cyan
    Write-Host ''
    Write-Host '  1. Open your WoW client folder' -ForegroundColor White
    Write-Host '  2. Find and open: realmlist.wtf (Data\enUS or Data\deDE)' -ForegroundColor White
    Write-Host '  3. Make sure it says: set realmlist 127.0.0.1' -ForegroundColor Green
    Write-Host '  4. Save the file' -ForegroundColor White
    Write-Host ''
    Write-Host '  --------------------------------------------------' -ForegroundColor Cyan
    Write-Host '  STEP B -- Start / Stop Your Server' -ForegroundColor White
    Write-Host '  --------------------------------------------------' -ForegroundColor Cyan
    Write-Host ''
    Write-Host "  Double-click in $InstallDir :" -ForegroundColor White
    Write-Host '    Start-Server.cmd   -- start the server' -ForegroundColor Green
    Write-Host '    Stop-Server.cmd    -- stop the server (saves characters)' -ForegroundColor Green
    Write-Host '    GM-Console.cmd     -- GM console (accounts, commands)' -ForegroundColor Green
    Write-Host '    Status.cmd         -- is it running?' -ForegroundColor Green
    Write-Host ''
    Write-Host '  The server does not start by itself after a reboot, and it is not' -ForegroundColor White
    Write-Host '  restarted automatically if it crashes -- just use Start-Server.cmd.' -ForegroundColor White
    Write-Host ''
    Write-Host '  --------------------------------------------------' -ForegroundColor Yellow
    Write-Host '  youtube.com/@DadsMmoLab' -ForegroundColor White
    Write-Host '  github.com/DadsMmoLab/dads-mmo-lab' -ForegroundColor White
    Write-Host '  ko-fi.com/dadsmmolab' -ForegroundColor White
    Write-Host '  --------------------------------------------------' -ForegroundColor Yellow
    Write-Host ''
    Write-Host "  Welcome to Azeroth. It's yours now. Forever." -ForegroundColor Green
    Write-Host ''
    Write-Host '  Your server is still running right now!' -ForegroundColor Yellow
    Write-Host ''
    if (Invoke-YesNo 'Stop the server now?') {
        Stop-WowServer
        Write-Info 'Use Start-Server.cmd to start it next time.'
    } else {
        Write-Info 'Server left running -- enjoy Azeroth!'
    }
    Write-Host ''
}

# =============================================================================
# Main
# =============================================================================
try {
    switch ($Action) {
        'Start'   { Start-WowServer; exit 0 }
        'Stop'    { Stop-WowServer; exit 0 }
        'Status'  { Show-Status; exit 0 }
        'Console' { Enter-Console; exit 0 }
    }

    Write-Header
    Write-Host '  Welcome to the WoW Playerbots installer for WSL containers!' -ForegroundColor White
    Write-Host '  Hundreds of AI players will roam your Azeroth,' -ForegroundColor White
    Write-Host '  quest, run dungeons, and make the world feel alive.' -ForegroundColor White
    Write-Host ''
    Write-Host '  This takes about 5 minutes to set up, then' -ForegroundColor Blue
    Write-Host '  compiles itself over 2-4 hours. Walk away and let it run.' -ForegroundColor Blue
    Write-Host ''
    if (-not (Invoke-YesNo 'Ready to begin?')) {
        Write-Host "  No problem -- run this script again when you're ready."
        exit 0
    }

    Write-Log "=== Install-WoW-WotLK-WSLContainers.ps1 v$WizardVersion -- InstallDir=$InstallDir ==="
    Assert-Prerequisites
    Show-Summary
    Install-Server
    $null = Wait-ForServer
    Set-PlayerbotConfig
    Write-Shortcuts
    Show-AccountCreation
    Show-Completion
} catch {
    if (-not $Script:FailReported) {
        Write-Host ''
        Write-Host "[FAIL] $($_.Exception.Message)" -ForegroundColor Red
        Write-Log "[FAIL] $($_.Exception.Message)"
    }
    Write-Host ''
    Write-Host "  Full log: $LogFile" -ForegroundColor Yellow
    exit 1
}
