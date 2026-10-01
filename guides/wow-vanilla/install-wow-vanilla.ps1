#Requires -Version 5.1
<#
.SYNOPSIS
    Dad's MMO Lab -- Vanilla WoW (1.12.1) Server Installer for Windows
    CMaNGOS Classic + Playerbots + AHBot, compiled from source
    using Docker Desktop.

.DESCRIPTION
    https://github.com/DadsMmoLab/dads-mmo-lab

    Windows / Docker Desktop port of install-wow-vanilla.sh (v1.2.4).
    Does NOT need WSL distros, Install-DML.ps1 or anything else from this
    repo -- only Docker Desktop (which the installer offers to install).

    Usage (from the folder you downloaded it to):
      powershell -ExecutionPolicy Bypass -File .\install-wow-vanilla.ps1

    What this does (fully automated, ~1-3 hours total on a desktop PC):
      1. Validates your WoW 1.12.1 client before any slow work
      2. Checks Docker Desktop (offers to install / start it)
      3. Compiles CMaNGOS Classic + Playerbots (~30-120 min)
      4. Extracts map/dbc/vmap data from your client (~10-20 min)
      5. Generates pathfinding mesh files (~15-30 min)
      6. Sets up MariaDB with all 4 databases + content + updates
      7. Imports Playerbots SQL (so bots actually work)
      8. Starts the compiled server with bots enabled
      9. Shows how to create the player/player account
     10. Configures realmlist and creates a desktop launcher

    Powered by:
      - cmangos/mangos-classic -- github.com/cmangos/mangos-classic
      - cmangos/playerbots     -- github.com/cmangos/playerbots
      - cmangos/classic-db     -- github.com/cmangos/classic-db

    Requirements:
      - Windows 10/11 64-bit with Docker Desktop (WSL2 backend recommended)
      - WoW Vanilla 1.12.1 (build 5875) client folder
      - 20GB free disk space (Docker's disk image usually lives on C:)
      - 8GB+ RAM available to Docker Desktop

    Differences from the Steam Deck .sh (deliberate):
      - No pacman / SteamOS / sudo logic: Docker comes from Docker Desktop
        (winget install offered); git/curl are not needed on the host
        because all source cloning happens inside the build container.
      - Extracted game data (maps/vmaps/mmaps) lives in the Docker named
        volume 'wow-vanilla-data' instead of a Windows folder. Windows bind
        mounts are slow and mangosd reads these files constantly; a named
        volume also removes the need for the chown step.
      - make -j and MoveMapGen threads are sized from the CPUs/RAM Docker
        Desktop actually has (the Deck pinned -j2 / --threads 2).
      - Every script that runs inside a container is written to
        <server>\scripts\*.sh with LF line endings and mounted read-only,
        instead of being passed inline -- PowerShell 5.1 mangles quotes in
        native arguments and adds CRLF when piping.
      - Existing extracted data is detected and can be reused on re-runs.
      - Gaming Mode launcher -> Start-WoW-Vanilla.ps1 + desktop shortcut
        (starts Docker Desktop if needed, boots the server, launches WoW,
        shuts the server down when WoW closes).
      - realmlist.wtf is locked with the Windows ReadOnly attribute instead
        of chmod 444.

    This file is intentionally pure ASCII so Windows PowerShell 5.1 reads it
    correctly no matter which encoding it was saved/downloaded with.
#>

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
# Continue (not Stop): in PS 5.1, native stderr redirected with 2>&1 becomes
# an ErrorRecord and would abort the script under 'Stop'. Docker writes
# normal progress output to stderr, so we check $LASTEXITCODE instead.
$ErrorActionPreference = 'Continue'

# =============================================================================
# CONFIGURATION
# =============================================================================
$InstallerVersion = '1.2.4-win'

$ServerDir    = Join-Path $env:USERPROFILE 'wow-vanilla-server'
$ScriptsDir   = Join-Path $ServerDir 'scripts'
$DockerCtxDir = Join-Path $ServerDir 'docker'
$EtcDir       = Join-Path $ServerDir 'etc'
$ComposeFile  = Join-Path $ServerDir 'compose.yml'
$PwFile       = Join-Path $ServerDir '.db_password'
$LauncherPath = Join-Path $ServerDir 'Start-WoW-Vanilla.ps1'

# Image names -- these are LOCAL builds, not pulled from anywhere
$ServerImage    = 'dml/cmangos-vanilla-server:local'
$ComposeProject = 'wow-vanilla-server'
$DbVolume       = "${ComposeProject}_db-data"
$DataVolume     = 'wow-vanilla-data'

$BuildLog   = Join-Path $env:TEMP 'wow-vanilla-build.log'
$ExtractLog = Join-Path $env:TEMP 'wow-vanilla-extract.log'
$VmapLog    = Join-Path $env:TEMP 'wow-vanilla-vmap-retry.log'
$MmapLog    = Join-Path $env:TEMP 'wow-vanilla-mmap-gen.log'

$DockerDesktopExe = Join-Path $env:ProgramFiles 'Docker\Docker\Docker Desktop.exe'
$DockerCliExe     = Join-Path $env:ProgramFiles 'Docker\Docker\DockerCli.exe'
$DockerBinDir     = Join-Path $env:ProgramFiles 'Docker\Docker\resources\bin'

$Script:ClientDir        = ''
$Script:DbPassword       = ''
$Script:DbPasswordLoaded = $false
$Script:MakeJobs         = 2
$Script:MmapThreads      = 2
$Script:InstallLog       = ''
$Script:ReuseData        = $false

try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false } catch { }
$OutputEncoding = New-Object System.Text.UTF8Encoding $false

# =============================================================================
# OUTPUT HELPERS
# =============================================================================
function Write-Header {
    Clear-Host
    Write-Host ''
    Write-Host '  +==================================================+' -ForegroundColor DarkYellow
    Write-Host '  |  DAD''S MMO LAB                                   |' -ForegroundColor White
    Write-Host '  |  Vanilla WoW Server (source-compile)             |' -ForegroundColor White
    Write-Host '  |  CMaNGOS Classic + Playerbots                    |' -ForegroundColor Blue
    Write-Host '  |  Windows + Docker Desktop                        |' -ForegroundColor Blue
    Write-Host ('  |  Version ' + $InstallerVersion.PadRight(40) + '|') -ForegroundColor Yellow
    Write-Host '  +==================================================+' -ForegroundColor DarkYellow
    Write-Host ''
}

function Write-Step([string]$Msg) {
    Write-Host ''
    Write-Host '  --------------------------------------------------' -ForegroundColor DarkYellow
    Write-Host "   $Msg" -ForegroundColor White
    Write-Host '  --------------------------------------------------' -ForegroundColor DarkYellow
}

function Write-Ok([string]$Msg)   { Write-Host "[ok]   $Msg" -ForegroundColor Green }
function Write-Warn([string]$Msg) { Write-Host "[WARN] $Msg" -ForegroundColor Yellow }
function Write-Err([string]$Msg)  { Write-Host "[FAIL] $Msg" -ForegroundColor Red }
function Write-Info([string]$Msg) { Write-Host "[info] $Msg" -ForegroundColor Cyan }

function Read-YesNo([string]$Question) {
    while ($true) {
        Write-Host "$Question (y/n): " -ForegroundColor White -NoNewline
        $answer = Read-Host
        if ($answer -match '^[Yy]') { return $true }
        if ($answer -match '^[Nn]') { return $false }
        Write-Host 'Please answer y or n.'
    }
}

function Exit-Installer([int]$Code) {
    # 'exit' inside a function still runs the main try/finally (transcript,
    # "press ENTER" so a double-clicked window doesn't vanish).
    exit $Code
}

# =============================================================================
# FILE + DOCKER HELPERS
# =============================================================================

# Linux-side files (Dockerfile, compose.yml, *.sh) must be LF and BOM-free.
function Write-LfFile([string]$Path, [string]$Content) {
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $lf = $Content -replace "`r`n", "`n"
    if (-not $lf.EndsWith("`n")) { $lf += "`n" }
    [System.IO.File]::WriteAllText($Path, $lf, (New-Object System.Text.UTF8Encoding $false))
}

# Windows-side files (launcher .ps1, txt). BOM so PS 5.1 reads non-ASCII
# paths (e.g. a user name with umlauts) correctly.
function Write-WinFile([string]$Path, [string]$Content) {
    $crlf = ($Content -replace "`r`n", "`n") -replace "`n", "`r`n"
    [System.IO.File]::WriteAllText($Path, $crlf, (New-Object System.Text.UTF8Encoding $true))
}

# Run docker quietly, return its output as strings. Exit code in $LASTEXITCODE.
# Arguments are always passed as ONE explicit array, e.g.
#   Invoke-Docker @('exec', '-e', 'X=1', 'vanilla-db', ...)
# so PowerShell never mistakes docker flags like -e / -f for its own
# parameters.
function Test-DockerCli {
    if (Get-Command docker -ErrorAction SilentlyContinue) { return $true }
    # Missing command leaves $LASTEXITCODE stale -- force a failure code
    $global:LASTEXITCODE = 127
    return $false
}

function Invoke-Docker([string[]]$DockerArgs) {
    if (-not (Test-DockerCli)) { return @() }
    $out = & docker @DockerArgs 2>&1 | ForEach-Object { "$_" }
    return $out
}

function Test-DockerOk([string[]]$DockerArgs) {
    if (-not (Test-DockerCli)) { return $false }
    & docker @DockerArgs *> $null
    return ($LASTEXITCODE -eq 0)
}

# Run docker, stream output to the console AND a log file.
# Returns docker's exit code. Optional heartbeat every N minutes.
function Invoke-DockerStream {
    param(
        [string[]]$DockerArgs,
        [string]$LogPath,
        [int]$HeartbeatMinutes = 0,
        [string]$HeartbeatText = 'Still working'
    )
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $nextBeat = $HeartbeatMinutes
    $writer = New-Object System.IO.StreamWriter($LogPath, $false, (New-Object System.Text.UTF8Encoding $false))
    $code = 1
    try {
        & docker @DockerArgs 2>&1 | ForEach-Object {
            $line = "$_"
            Write-Host $line
            $writer.WriteLine($line)
            if ($HeartbeatMinutes -gt 0 -and $sw.Elapsed.TotalMinutes -ge $nextBeat) {
                Write-Host "  ... $HeartbeatText -- $nextBeat minutes elapsed." -ForegroundColor Yellow
                $nextBeat += $HeartbeatMinutes
            }
        }
        $code = $LASTEXITCODE
    } finally {
        $writer.Close()
    }
    return $code
}

# Write a bash script to <server>\scripts and run it inside the server image.
#   -RunArgs   extra 'docker run' args (volumes, network, env)
#   -LogPath   stream output to console + log; otherwise output is captured
#              into $Script:LastOutput (string[])
# Returns the container's exit code.
$Script:LastOutput = @()
function Invoke-ImageScript {
    param(
        [string]$Name,
        [string]$Body,
        [string[]]$RunArgs = @(),
        [string]$LogPath = '',
        [int]$HeartbeatMinutes = 0,
        [string]$HeartbeatText = 'Still working'
    )
    Write-LfFile (Join-Path $ScriptsDir "$Name.sh") $Body
    $dargs = @('run', '--rm', '-v', "${ScriptsDir}:/dml-scripts:ro") + $RunArgs +
             @('--entrypoint', '/bin/bash', $ServerImage, "/dml-scripts/$Name.sh")
    if ($LogPath) {
        return (Invoke-DockerStream -DockerArgs $dargs -LogPath $LogPath `
                    -HeartbeatMinutes $HeartbeatMinutes -HeartbeatText $HeartbeatText)
    }
    $Script:LastOutput = @(Invoke-Docker $dargs)
    return $LASTEXITCODE
}

# Pipe SQL into the running MariaDB container as root.
function Invoke-DbSql([string]$Sql, [string]$Database = '') {
    $dargs = @('exec', '-i', '-e', "MYSQL_PWD=$($Script:DbPassword)", 'vanilla-db', 'mariadb', '-u', 'root')
    if ($Database) { $dargs += $Database }
    $out = $Sql | & docker @dargs 2>&1 | ForEach-Object { "$_" }
    $Script:LastOutput = @($out)
    return $LASTEXITCODE
}

function Get-DbScalar([string]$Database, [string]$Query) {
    $out = Invoke-Docker @('exec', '-e', "MYSQL_PWD=$($Script:DbPassword)", 'vanilla-db',
        'mariadb', '-u', 'root', $Database, '-sN', '-e', $Query)
    if ($LASTEXITCODE -ne 0) { return $null }
    $first = @($out | Where-Object { $_ -match '^\s*\d+\s*$' } | Select-Object -First 1)
    if ($first.Count -eq 0) { return $null }
    return [int]($first[0].Trim())
}

function Show-Tail([string[]]$Lines, [int]$Count = 3) {
    @($Lines) | Select-Object -Last $Count | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
}

function Invoke-Compose([string[]]$ComposeArgs) {
    $dargs = @('compose', '-f', $ComposeFile) + $ComposeArgs
    $out = & docker @dargs 2>&1 | ForEach-Object { "$_" }
    $out | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
    return $LASTEXITCODE
}

function Get-FreeGB([string]$Path) {
    try {
        $root = [System.IO.Path]::GetPathRoot($Path)
        $drive = New-Object System.IO.DriveInfo($root)
        return [int][math]::Floor($drive.AvailableFreeSpace / 1GB)
    } catch {
        return $null
    }
}

# =============================================================================
# SYSTEM CHECKS
# =============================================================================
function Test-System {
    Write-Step 'Checking System Requirements'

    if ([Environment]::OSVersion.Platform -ne 'Win32NT') {
        Write-Err 'This installer is for Windows. On Linux / Steam Deck use install-wow-vanilla.sh.'
        Exit-Installer 1
    }
    if (-not [Environment]::Is64BitOperatingSystem) {
        Write-Err 'Docker Desktop needs 64-bit Windows.'
        Exit-Installer 1
    }
    Write-Ok "Windows detected ($([Environment]::OSVersion.Version))"

    # Docker Desktop keeps its disk image (all images, the compile, the data
    # volume) under %LOCALAPPDATA%\Docker by default -- that's the drive
    # that needs the space, not necessarily the one the server folder is on.
    $dockerDiskGB = Get-FreeGB $env:LOCALAPPDATA
    if ($null -ne $dockerDiskGB -and $dockerDiskGB -lt 20) {
        Write-Err "Need 20GB free for compile + client data. Drive of $env:LOCALAPPDATA has ${dockerDiskGB}GB."
        Write-Info 'If you moved Docker Desktop''s disk image (Settings -> Resources -> Advanced),'
        Write-Info 'make sure THAT drive has 20GB free.'
        Exit-Installer 1
    }
    Write-Ok "Disk space OK ($(if ($null -ne $dockerDiskGB) { "${dockerDiskGB}GB" } else { 'unknown' }) available for Docker)"

    $online = $false
    try {
        $null = Invoke-WebRequest -Uri 'https://github.com' -Method Head -UseBasicParsing -TimeoutSec 15
        $online = $true
    } catch {
        # Some proxies reject HEAD -- fall back to a plain TCP check
        try {
            $tcp = New-Object System.Net.Sockets.TcpClient
            $tcp.Connect('github.com', 443)
            $online = $tcp.Connected
            $tcp.Close()
        } catch { $online = $false }
    }
    if (-not $online) {
        Write-Err 'No internet (github.com unreachable). Please connect and try again.'
        Exit-Installer 1
    }
    Write-Ok 'Internet connection OK'

    try {
        $ramMB = [int]((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1MB)
        if ($ramMB -lt 8000) {
            Write-Warn "RAM is low (${ramMB}MB). Compile and 600+ bots may be slow."
        } else {
            Write-Ok "RAM OK (${ramMB}MB total)"
        }
    } catch {
        Write-Warn 'Could not read installed RAM -- continuing.'
    }
}

# =============================================================================
# DOCKER DESKTOP
# =============================================================================
function Add-DockerToPath {
    if (-not (Get-Command docker -ErrorAction SilentlyContinue) -and (Test-Path -LiteralPath $DockerBinDir)) {
        $env:Path = "$env:Path;$DockerBinDir"
    }
}

function Wait-DockerEngine([int]$TimeoutSec = 240) {
    $elapsed = 0
    while ($elapsed -lt $TimeoutSec) {
        if (Test-DockerOk @('info')) { Write-Host ''; return $true }
        Write-Host '.' -NoNewline
        Start-Sleep -Seconds 5
        $elapsed += 5
    }
    Write-Host ''
    return $false
}

function Start-DockerDesktop {
    if (-not (Test-Path -LiteralPath $DockerDesktopExe)) { return $false }
    Write-Info 'Starting Docker Desktop (first start can take 1-3 minutes)...'
    Start-Process -FilePath $DockerDesktopExe | Out-Null
    return (Wait-DockerEngine 240)
}

function Install-DockerDesktop {
    Write-Warn 'Docker Desktop is not installed.'
    Write-Info ''
    Write-Info 'Docker Desktop runs the Linux containers this server is built in.'
    Write-Info 'Docker Desktop is free for personal use.'
    Write-Info ''
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Write-Err 'winget is not available, so I cannot install Docker Desktop for you.'
        Write-Info 'Install it manually: https://www.docker.com/products/docker-desktop/'
        Write-Info 'Then start Docker Desktop once, accept the terms, and re-run this installer.'
        Exit-Installer 1
    }
    if (-not (Read-YesNo 'Install Docker Desktop now via winget? (needs admin approval)')) {
        Write-Info 'Install it from https://www.docker.com/products/docker-desktop/ and re-run.'
        Exit-Installer 0
    }
    & winget install -e --id Docker.DockerDesktop --accept-package-agreements --accept-source-agreements
    if ($LASTEXITCODE -ne 0) {
        Write-Err "winget install failed (exit code $LASTEXITCODE)."
        Write-Info 'Install manually: https://www.docker.com/products/docker-desktop/'
        Exit-Installer 1
    }
    Write-Ok 'Docker Desktop installed.'
    Write-Host ''
    Write-Host '  Next steps (one time only):' -ForegroundColor Yellow
    Write-Host '   1. RESTART Windows (WSL2 / virtualization gets enabled on reboot)' -ForegroundColor Yellow
    Write-Host '   2. Start "Docker Desktop" from the Start menu and accept the terms' -ForegroundColor Yellow
    Write-Host '   3. Wait until it says "Engine running"' -ForegroundColor Yellow
    Write-Host '   4. Re-run this installer' -ForegroundColor Yellow
    Exit-Installer 0
}

function Test-LinuxEngine {
    $os = (Invoke-Docker @('info', '--format', '{{.OSType}}') | Select-Object -First 1)
    if ($os -eq 'linux') { return $true }
    if ($os -eq 'windows' -and (Test-Path -LiteralPath $DockerCliExe)) {
        Write-Warn 'Docker Desktop is in Windows-containers mode -- switching to Linux containers...'
        & $DockerCliExe -SwitchLinuxEngine | Out-Null
        if (Wait-DockerEngine 120) {
            $os = (Invoke-Docker @('info', '--format', '{{.OSType}}') | Select-Object -First 1)
            return ($os -eq 'linux')
        }
    }
    return $false
}

# Size the compile + mmap generation to what Docker Desktop's VM really has.
# gcc with PCH needs ~2GB per job on this codebase; running out of memory
# kills the compiler hours in, so we stay conservative.
function Set-BuildParallelism {
    $ncpu = 2; $memGB = 4
    $n = Invoke-Docker @('info', '--format', '{{.NCPU}}') | Select-Object -First 1
    $m = Invoke-Docker @('info', '--format', '{{.MemTotal}}') | Select-Object -First 1
    if ($n -match '^\d+$') { $ncpu = [int]$n }
    if ($m -match '^\d+$') { $memGB = [math]::Floor([double]$m / 1GB) }

    $byRam = [math]::Max(1, [math]::Floor($memGB / 2))
    $Script:MakeJobs    = [int][math]::Max(1, [math]::Min($ncpu, $byRam))
    $Script:MmapThreads = [int][math]::Max(1, [math]::Min([math]::Min($ncpu, $byRam), 8))

    Write-Ok "Docker Desktop resources: $ncpu CPUs, ${memGB}GB RAM -> make -j$($Script:MakeJobs), mmap threads $($Script:MmapThreads)"
    if ($memGB -lt 6) {
        Write-Warn "Docker Desktop only has ${memGB}GB RAM. Compile will be slow and 600+ bots may not fit."
        Write-Info 'WSL2 backend: create %USERPROFILE%\.wslconfig with'
        Write-Info '    [wsl2]'
        Write-Info '    memory=8GB'
        Write-Info 'then run "wsl --shutdown" and restart Docker Desktop.'
        Write-Info 'Hyper-V backend: Docker Desktop -> Settings -> Resources -> Memory.'
    }
}

# =============================================================================
# DEPENDENCY DIAGNOSTIC
# =============================================================================
function Show-DependencyDiagnostic([string[]]$Failed) {
    Write-Host ''
    Write-Host '  --------------------------------------------------' -ForegroundColor Yellow
    Write-Host '   Dependency Diagnostic Report' -ForegroundColor White
    Write-Host '  --------------------------------------------------' -ForegroundColor Yellow
    Write-Host "  Failed: $($Failed -join ', ')" -ForegroundColor Red

    Write-Host ''
    Write-Host '-- System environment ------------------------------' -ForegroundColor White
    Write-Host "  Windows:        $([Environment]::OSVersion.VersionString)"
    Write-Host "  USERPROFILE:    $env:USERPROFILE"
    Write-Host "  DOCKER_HOST:    $(if ($env:DOCKER_HOST) { $env:DOCKER_HOST } else { '(not set)' })"
    Write-Host "  DOCKER_CONFIG:  $(if ($env:DOCKER_CONFIG) { $env:DOCKER_CONFIG } else { '(not set, defaults to %USERPROFILE%\.docker)' })"
    $cmd = Get-Command docker -ErrorAction SilentlyContinue
    Write-Host "  docker.exe:     $(if ($cmd) { $cmd.Source } else { 'NOT in PATH' })"
    Write-Host "  Docker Desktop: $(if (Test-Path -LiteralPath $DockerDesktopExe) { $DockerDesktopExe } else { 'not found in Program Files' })"
    $proc = Get-Process -Name 'Docker Desktop' -ErrorAction SilentlyContinue
    Write-Host "  Desktop running: $(if ($proc) { 'yes' } else { 'no' })"

    foreach ($dep in $Failed) {
        Write-Host ''
        Write-Host "-- Diagnosing: $dep ------------------------------" -ForegroundColor White
        switch ($dep) {
            'docker engine' {
                Write-Host '  docker version:' -ForegroundColor White
                Invoke-Docker @('version') | ForEach-Object { Write-Host "    $_" }
                Write-Host '  docker context ls:' -ForegroundColor White
                Invoke-Docker @('context', 'ls') | ForEach-Object { Write-Host "    $_" }
                Write-Host '  wsl --status:' -ForegroundColor White
                (& wsl.exe --status 2>&1 | ForEach-Object { "$_" }) -replace "`0", '' |
                    Where-Object { $_.Trim() } | ForEach-Object { Write-Host "    $_" }
                Write-Host '  wsl -l -v:' -ForegroundColor White
                (& wsl.exe -l -v 2>&1 | ForEach-Object { "$_" }) -replace "`0", '' |
                    Where-Object { $_.Trim() } | ForEach-Object { Write-Host "    $_" }
            }
            'linux containers' {
                Write-Host "  OSType: $(Invoke-Docker @('info', '--format', '{{.OSType}}') | Select-Object -First 1)"
                Write-Host '  Fix: right-click the Docker tray icon -> "Switch to Linux containers..."' -ForegroundColor Yellow
            }
            'docker compose' {
                Write-Host '  Raw output:' -ForegroundColor White
                Invoke-Docker @('compose', 'version') | ForEach-Object { Write-Host "    $_" }
                Write-Host '  Fix: update Docker Desktop (compose v2 ships with it).' -ForegroundColor Yellow
            }
            'docker buildx' {
                Write-Host '  Raw output:' -ForegroundColor White
                Invoke-Docker @('buildx', 'version') | ForEach-Object { Write-Host "    $_" }
                $userPlugin = Join-Path $env:USERPROFILE '.docker\cli-plugins\docker-buildx.exe'
                if (Test-Path -LiteralPath $userPlugin) {
                    Write-Host "  User-level plugin found: $userPlugin" -ForegroundColor Yellow
                    Write-Host '  It may shadow Docker Desktop''s own buildx. If broken, delete it and re-run.' -ForegroundColor Yellow
                }
                Write-Host '  Fix: update / reinstall Docker Desktop (buildx ships with it).' -ForegroundColor Yellow
            }
            default {
                Write-Host "  '$dep' -- no specific diagnostic available."
            }
        }
    }

    Write-Host ''
    Write-Host '  --------------------------------------------------' -ForegroundColor Yellow
    Write-Host '  Install log saved to:' -ForegroundColor White
    Write-Host "  $($Script:InstallLog)" -ForegroundColor Cyan
    Write-Host ''
    Write-Host '  To report this issue, upload the log file to:' -ForegroundColor White
    Write-Host '  https://github.com/DadsMmoLab/dads-mmo-lab/issues' -ForegroundColor Cyan
    Write-Host '  --------------------------------------------------' -ForegroundColor Yellow
    Write-Host ''
}

# =============================================================================
# PREFLIGHT CHECK -- DOCKER DESKTOP
# =============================================================================
function Test-Preflight {
    Write-Step 'Preflight Check -- Docker Desktop'

    Add-DockerToPath
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
        if (Test-Path -LiteralPath $DockerDesktopExe) {
            Write-Warn 'Docker Desktop is installed but docker.exe is not in PATH -- starting it...'
        } else {
            Install-DockerDesktop
        }
    }

    if (-not (Test-DockerOk @('info'))) {
        Write-Info 'Docker engine is not running.'
        if (-not (Start-DockerDesktop)) {
            Add-DockerToPath
        }
    }
    Add-DockerToPath

    $engineOk  = (Get-Command docker -ErrorAction SilentlyContinue) -and (Test-DockerOk @('info'))
    $linuxOk   = $false
    if ($engineOk) { $linuxOk = Test-LinuxEngine }
    $composeOk = $engineOk -and (Test-DockerOk @('compose', 'version'))
    $buildxOk  = $engineOk -and (Test-DockerOk @('buildx', 'version'))

    Write-Host ''
    Write-Host ('  {0,-28} {1}' -f 'Dependency', 'Status') -ForegroundColor White
    Write-Host '  --------------------------------------' -ForegroundColor DarkGray
    $rows = @(
        @('docker engine (running)', $engineOk),
        @('linux containers mode',   $linuxOk),
        @('docker compose',          $composeOk),
        @('docker buildx',           $buildxOk)
    )
    foreach ($r in $rows) {
        if ($r[1]) {
            Write-Host ('  [ok]  {0,-26} OK' -f $r[0]) -ForegroundColor Green
        } else {
            Write-Host ('  [!!]  {0,-26} MISSING' -f $r[0]) -ForegroundColor Red
        }
    }
    Write-Host ''

    $failed = @()
    if (-not $engineOk)  { $failed += 'docker engine' }
    if (-not $linuxOk)   { $failed += 'linux containers' }
    if (-not $composeOk) { $failed += 'docker compose' }
    if (-not $buildxOk)  { $failed += 'docker buildx' }

    if ($failed.Count -gt 0) {
        Write-Err "The following dependencies are not working: $($failed -join ', ')"
        Write-Warn 'Running diagnostics...'
        Show-DependencyDiagnostic $failed
        Write-Info 'Common fixes:'
        Write-Info '  - Start Docker Desktop and wait for "Engine running", then re-run'
        Write-Info '  - Run "wsl --update" in an admin PowerShell, reboot, re-run'
        Write-Info '  - Enable virtualization (VT-x / AMD-V / SVM) in your BIOS'
        Exit-Installer 1
    }

    $composeVer = Invoke-Docker @('compose', 'version') | Select-Object -First 1
    $buildxVer  = Invoke-Docker @('buildx', 'version') | Select-Object -First 1
    Write-Ok "docker compose: $composeVer"
    Write-Ok "docker buildx:  $buildxVer"
    Set-BuildParallelism
    Write-Ok 'All dependencies satisfied -- ready to build!'
}

# =============================================================================
# WELCOME
# =============================================================================
function Show-Welcome {
    Write-Header
    Write-Host 'Welcome to the Vanilla WoW installer!' -ForegroundColor White
    Write-Host ''
    Write-Host 'This installs a full offline World of Warcraft' -ForegroundColor White
    Write-Host 'Vanilla (1.12.1) server using CMaNGOS Classic' -ForegroundColor White
    Write-Host 'compiled from source with Playerbots enabled,' -ForegroundColor White
    Write-Host 'running in Docker Desktop on Windows.' -ForegroundColor White
    Write-Host ''
    Write-Host 'Playerbots + AHBot are included.' -ForegroundColor Green
    Write-Host 'AI players roam Azeroth, form parties with you,' -ForegroundColor White
    Write-Host 'run dungeons, and populate the auction house.' -ForegroundColor White
    Write-Host 'You''re never alone in Vanilla.' -ForegroundColor White
    Write-Host ''
    Write-Host 'HONEST TIME COMMITMENT:' -ForegroundColor Red
    Write-Host '  - Total time: 1-3 hours (mostly hands-off)' -ForegroundColor Yellow
    Write-Host '  - Compile: 30-120 minutes (depends on your CPU)' -ForegroundColor Yellow
    Write-Host '  - Extraction: 10-20 minutes' -ForegroundColor Yellow
    Write-Host '  - Pathfinding mesh gen: 15-30 minutes' -ForegroundColor Yellow
    Write-Host '  - You can walk away -- a heartbeat shows progress' -ForegroundColor Yellow
    Write-Host '  - First run only -- future starts are seconds' -ForegroundColor Yellow
    Write-Host ''
    Write-Host 'Laptop? Plug it in and disable sleep while this runs.' -ForegroundColor Red
    Write-Host ''
    Write-Host 'Client required: WoW 1.12.1 (build 5875)' -ForegroundColor Cyan
    Write-Host 'Default account: player / player' -ForegroundColor Cyan
    Write-Host "Build log: $BuildLog" -ForegroundColor Cyan
    Write-Host ''

    if (-not (Read-YesNo 'Ready to build your own Azeroth?')) {
        Write-Host 'No problem -- come back when you''re ready!'
        Exit-Installer 0
    }
}

# =============================================================================
# LOCATE CLIENT
# =============================================================================
function Find-Client {
    Write-Header
    Write-Step 'STEP 1/5 -- Locating & Validating Your WoW Client'

    Write-Host 'I need the path to your Vanilla 1.12.1 client folder.' -ForegroundColor White
    Write-Host 'The folder must contain:' -ForegroundColor White
    Write-Host '  - WoW.exe'
    Write-Host '  - Data\ folder with .MPQ files inside'
    Write-Host '  - Data\dbc.MPQ specifically (the DBC archive -- required)'
    Write-Host ''
    Write-Host 'Examples of valid paths:' -ForegroundColor Blue
    Write-Host '  C:\Games\WoW-1.12.1' -ForegroundColor Cyan
    Write-Host '  D:\World of Warcraft Classic   (quotes optional)' -ForegroundColor Cyan
    Write-Host '  Tip: Shift+right-click the folder in Explorer -> "Copy as path", then paste.' -ForegroundColor DarkGray
    Write-Host ''

    while ($true) {
        Write-Host 'Enter path to your WoW client folder:' -ForegroundColor White
        $raw = Read-Host
        if ($null -eq $raw) { $raw = '' }

        # Strip surrounding quotes ("Copy as path" adds them)
        $raw = $raw.Trim().Trim('"').Trim("'").Trim()
        if (-not $raw) { continue }
        if ($raw.StartsWith('~')) { $raw = $env:USERPROFILE + $raw.Substring(1) }
        $raw = [Environment]::ExpandEnvironmentVariables($raw)

        # Accept a pasted path to WoW.exe itself
        if ((Test-Path -LiteralPath $raw -PathType Leaf) -and ($raw -match '(?i)\\wow\.exe$')) {
            $raw = Split-Path -Parent $raw
        }

        # -- Validation gate 1: folder exists -------------------------
        if (-not (Test-Path -LiteralPath $raw -PathType Container)) {
            Write-Err "Folder doesn't exist: $raw"
            Write-Info 'Use the full path, e.g. C:\Games\WoW-1.12.1'
            Write-Host ''
            continue
        }
        $clientDir = (Resolve-Path -LiteralPath $raw).ProviderPath.TrimEnd('\')

        # Docker Desktop can't mount network shares / mapped network drives
        if ($clientDir.StartsWith('\\')) {
            Write-Err 'Network paths (\\server\share) cannot be mounted into Docker.'
            Write-Info 'Copy the client to a local drive and use that path.'
            Write-Host ''
            continue
        }
        try {
            $letter = $clientDir.Substring(0, 2)
            $disk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$letter'" -ErrorAction Stop
            if ($disk -and $disk.DriveType -eq 4) {
                Write-Err "$letter is a mapped network drive -- Docker cannot mount it."
                Write-Info 'Copy the client to a local drive and use that path.'
                Write-Host ''
                continue
            }
        } catch { }

        # -- Validation gate 2: Data\ subfolder -----------------------
        $dataDir = Join-Path $clientDir 'Data'
        if (-not (Test-Path -LiteralPath $dataDir -PathType Container)) {
            Write-Err "No Data\ folder inside $clientDir"
            Write-Info 'This doesn''t look like a WoW client. The Data\ folder'
            Write-Info 'is where all the .MPQ game files live.'
            Write-Host ''
            continue
        }

        # -- Validation gate 3: MPQ count sanity check ----------------
        $mpqCount = @(Get-ChildItem -LiteralPath $dataDir -Filter '*.mpq' -File -ErrorAction SilentlyContinue).Count
        if ($mpqCount -lt 5) {
            Write-Err "Only $mpqCount .MPQ files in Data\."
            Write-Info 'Vanilla 1.12.1 typically has 10-14 MPQ files.'
            Write-Info 'If you have fewer, this might be:'
            Write-Info '  - A wrong WoW version (TBC, WotLK, Retail)'
            Write-Info '  - An incomplete download'
            Write-Info '  - A non-standard repack'
            Write-Host ''
            if (-not (Read-YesNo 'Continue anyway? (NOT recommended -- extraction will likely fail)')) {
                continue
            }
        }

        # -- Validation gate 4: dbc.MPQ CRITICAL CHECK ----------------
        # Without dbc.MPQ the extractor cannot produce Map.dbc etc. The
        # compile would finish and extraction would fail at the very end.
        if (-not (Test-Path -LiteralPath (Join-Path $dataDir 'dbc.MPQ') -PathType Leaf)) {
            Write-Err 'Data\dbc.MPQ is MISSING.'
            Write-Info ''
            Write-Info 'This file is required for server-side data extraction.'
            Write-Info 'Without it, the install will fail after the long compile.'
            Write-Info ''
            Write-Info 'Likely causes:'
            Write-Info '  - This client is heavily stripped (some repacks remove dbc.MPQ)'
            Write-Info '  - Wrong WoW version'
            Write-Info '  - Incomplete download'
            Write-Info ''
            Write-Info 'Find a more complete 1.12.1 client (~5GB total) and try again.'
            Write-Host ''
            if (-not (Read-YesNo 'Continue anyway? (NOT recommended)')) {
                continue
            }
        }

        # -- Validation gate 5: WoW.exe (needed for the launcher) -----
        if (-not (Test-Path -LiteralPath (Join-Path $clientDir 'WoW.exe') -PathType Leaf)) {
            Write-Warn 'No WoW.exe in that folder. The server will still work, but the'
            Write-Warn 'desktop launcher won''t be able to start the game for you.'
        }

        # -- Validation gate 6: Disk space for extraction -------------
        # Extraction writes temp folders (~3-5GB) into the client folder.
        $clientFree = Get-FreeGB $clientDir
        if ($null -ne $clientFree -and $clientFree -lt 8) {
            Write-Warn "Only ${clientFree}GB free where the client lives."
            Write-Warn 'Extraction writes temp files into the client folder (needs ~5GB).'
        }

        # -- Validation gate 7: repack signatures (warning only) ------
        $repackSignals = 0
        if (Test-Path -LiteralPath (Join-Path $clientDir 'realmlist.wtf')) { $repackSignals++ }
        if (-not (Test-Path -LiteralPath (Join-Path $dataDir 'enUS')) -and
            -not (Test-Path -LiteralPath (Join-Path $dataDir 'enGB'))) { $repackSignals++ }
        if ($repackSignals -ge 2) {
            Write-Info 'This client looks like a community repack (realmlist at top level, no locale folder).'
            Write-Info 'That''s USUALLY fine -- server extraction works with stripped repacks'
            Write-Info 'as long as Data\dbc.MPQ exists.'
        }

        $Script:ClientDir = $clientDir
        Write-Ok "WoW client validated: $clientDir"
        Write-Ok "Found $mpqCount .MPQ files"
        break
    }
}

# =============================================================================
# SHOW SUMMARY BEFORE COMPILE
# =============================================================================
function Show-Summary {
    Write-Header
    Write-Step 'STEP 2/5 -- Pre-Compile Summary'
    Write-Host ''
    Write-Host '  Expansion: ' -ForegroundColor White -NoNewline; Write-Host 'Vanilla (1.12.1, build 5875)' -ForegroundColor DarkYellow
    Write-Host '  Build:     ' -ForegroundColor White -NoNewline; Write-Host 'Source compile (CMaNGOS + Playerbots)' -ForegroundColor DarkYellow
    Write-Host '  Folder:    ' -ForegroundColor White -NoNewline; Write-Host $ServerDir -ForegroundColor DarkYellow
    Write-Host '  Client:    ' -ForegroundColor White -NoNewline; Write-Host $Script:ClientDir -ForegroundColor DarkYellow
    Write-Host '  Map data:  ' -ForegroundColor White -NoNewline; Write-Host "Docker volume '$DataVolume'" -ForegroundColor DarkYellow
    Write-Host ''
    Write-Host '  Bots:' -ForegroundColor White
    Write-Host '    [ok] Playerbots -- AI players roam Azeroth' -ForegroundColor Green
    Write-Host '    [ok] AHBot -- populates the Auction House' -ForegroundColor Green
    Write-Host ''
    Write-Host '  Default account: player / player' -ForegroundColor White
    Write-Host ''
    Write-Host '  The installer will:' -ForegroundColor Yellow
    Write-Host '  1. Build a compile container (~5 min)' -ForegroundColor Yellow
    Write-Host '  2. Clone CMaNGOS + Playerbots source (~5 min)' -ForegroundColor Yellow
    Write-Host '  3. Compile mangosd + realmd + tools (30-120 MINUTES)' -ForegroundColor Yellow
    Write-Host '  4. Extract maps from your client (~10-20 min)' -ForegroundColor Yellow
    Write-Host '  5. Generate pathfinding mesh files (~15-30 min)' -ForegroundColor Yellow
    Write-Host '  6. Set up databases and content (~5 min)' -ForegroundColor Yellow
    Write-Host '  7. Start the server (~1-5 min first boot)' -ForegroundColor Yellow
    Write-Host ''
    Write-Host '  Your PC will be busy and the fans loud. This is normal.' -ForegroundColor Red
    Write-Host ''
    if (-not (Read-YesNo 'Start the build?')) {
        Write-Host 'No problem -- come back when you have time!'
        Exit-Installer 0
    }
}

# =============================================================================
# DOCKERFILE (identical build to the .sh, make -j is a build arg)
# =============================================================================
$DockerfileContent = @'
# --------------------------------------------------------------
# Stage 1: Build CMaNGOS Classic + Playerbots from source
# --------------------------------------------------------------
FROM ubuntu:22.04 AS builder

ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=UTC

# ca-certificates is required because --no-install-recommends strips it.
# gcc-12 is required because gcc-11.4 has an internal compiler error
# on TileAssembler.cpp (CMaNGOS warns about this in its CMake config).
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    ca-certificates \
    cmake \
    g++-12 \
    gcc-12 \
    git \
    libssl-dev \
    default-libmysqlclient-dev \
    libace-dev \
    libtbb-dev \
    libboost-all-dev \
    libreadline-dev \
    zlib1g-dev \
    openssl \
    p7zip-full \
    && rm -rf /var/lib/apt/lists/*

ENV CC=/usr/bin/gcc-12
ENV CXX=/usr/bin/g++-12

WORKDIR /src

# Clone CMaNGOS Classic core
RUN git clone --depth 1 https://github.com/cmangos/mangos-classic.git /src/mangos-classic

# Playerbots live at src/modules/Bots (per cmangos/playerbots README)
RUN git clone --depth 1 https://github.com/cmangos/playerbots.git \
    /src/mangos-classic/src/modules/Bots

# Clone classic-db (world content database)
RUN git clone --depth 1 https://github.com/cmangos/classic-db.git /src/classic-db

# Separate playerbots clone for its sql/ tree
RUN git clone --depth 1 https://github.com/cmangos/playerbots.git /src/playerbots-fresh

WORKDIR /src/mangos-classic
RUN mkdir -p build && cd build && \
    cmake .. \
        -DCMAKE_INSTALL_PREFIX=/opt/mangos \
        -DBUILD_PLAYERBOTS=1 \
        -DBUILD_AHBOT=1 \
        -DBUILD_EXTRACTORS=1 \
        -DBUILD_GAME_SERVER=1 \
        -DBUILD_LOGIN_SERVER=1 \
        -DBUILD_TOOLS=1 \
        -DPCH=1

# Parallelism is chosen by the installer from Docker Desktop's CPUs/RAM
ARG MAKE_JOBS=2
RUN cd build && make -j${MAKE_JOBS} && make install

# Keep the SQL trees -- the runtime image needs them for DB init
RUN mkdir -p /opt/mangos/sql && \
    cp -r /src/mangos-classic/sql/* /opt/mangos/sql/ && \
    mkdir -p /opt/mangos/classic-db && \
    cp -r /src/classic-db/* /opt/mangos/classic-db/ && \
    mkdir -p /opt/mangos/playerbots-sql && \
    cp -r /src/playerbots-fresh/sql/* /opt/mangos/playerbots-sql/

# --------------------------------------------------------------
# Stage 2: Runtime -- minimal image with binaries + SQL bundled
# --------------------------------------------------------------
FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=UTC

RUN apt-get update && apt-get install -y --no-install-recommends \
    libssl3 \
    libmysqlclient21 \
    libace-dev \
    libtbb12 \
    libboost-system1.74.0 \
    libboost-filesystem1.74.0 \
    libboost-program-options1.74.0 \
    libreadline8 \
    netcat-openbsd \
    mariadb-client \
    gzip \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /opt/mangos /opt/mangos

WORKDIR /opt/mangos/bin

CMD ["./mangosd"]
'@

# =============================================================================
# CREATE BUILD CONTAINER + COMPILE
# =============================================================================
function Invoke-Compile {
    Write-Header
    Write-Step 'STEP 3/5 -- Compiling CMaNGOS (30-120 minutes)'

    $imageExists = Test-DockerOk @('image', 'inspect', $ServerImage)
    $dirExists = Test-Path -LiteralPath $ServerDir

    if ($dirExists -and $imageExists) {
        Write-Ok "Compiled image found: $ServerImage"
        Write-Info 'Skipping the compile -- previous build is ready.'
        Write-Host ''
        if (Read-YesNo 'Start completely fresh instead? (wipes all files + data + re-compiles)') {
            Remove-Install -AlsoImage
            Write-Ok 'Wiped -- starting fresh compile'
        } else {
            Write-Info 'Keeping existing build -- skipping compile.'
            New-Item -ItemType Directory -Path $ServerDir, $ScriptsDir, $EtcDir -Force | Out-Null
            return
        }
    } elseif ($dirExists) {
        Write-Warn "Existing install folder found at $ServerDir (no compiled image present)"
        if (Read-YesNo 'Remove it and start fresh?') {
            Remove-Install
            Write-Ok 'Old install removed'
        } else {
            Write-Info 'Keeping existing install -- exiting.'
            Exit-Installer 0
        }
    } elseif ($imageExists) {
        Write-Ok "Compiled image found: $ServerImage"
        Write-Info 'Skipping compile -- reusing existing build.'
        New-Item -ItemType Directory -Path $ServerDir, $ScriptsDir, $EtcDir -Force | Out-Null
        return
    }

    New-Item -ItemType Directory -Path $ServerDir, $ScriptsDir, $EtcDir, $DockerCtxDir -Force | Out-Null

    Write-Info 'Writing Dockerfile...'
    Write-LfFile (Join-Path $DockerCtxDir 'Dockerfile') $DockerfileContent
    Write-Ok 'Dockerfile written (with sql/ preservation baked in)'

    Write-Info "Starting compile. Logs streaming to $BuildLog"
    Write-Info "Follow it from another window: Get-Content '$BuildLog' -Wait -Tail 20"
    Write-Info ''
    Write-Warn 'Expected duration: 30-120 minutes. Walk away if you need to.'
    Write-Info ''

    $code = Invoke-DockerStream -LogPath $BuildLog -HeartbeatMinutes 5 -HeartbeatText 'Still compiling' -DockerArgs @(
        'build', '--progress=plain',
        '--build-arg', "MAKE_JOBS=$($Script:MakeJobs)",
        '-t', $ServerImage, $DockerCtxDir)

    if ($code -ne 0) {
        Write-Err 'Compile failed!'
        Write-Info 'Last 30 lines of build log:'
        Get-Content -LiteralPath $BuildLog -Tail 30 | ForEach-Object { Write-Host "    $_" }
        Write-Info ''
        Write-Info "Full log: $BuildLog"
        Write-Info 'Common causes:'
        Write-Info '  - Out of disk space (compile produces 5+ GB of artifacts)'
        Write-Info '  - Network drop during dependency fetch (re-run the installer)'
        Write-Info '  - Docker Desktop ran out of memory and killed gcc'
        Write-Info '    ("Killed" / "signal 9" in the log) -- give Docker more RAM'
        Exit-Installer 1
    }
    Write-Ok 'CMaNGOS compiled with Playerbots!'
}

function Remove-Install([switch]$AlsoImage) {
    Write-Info 'Removing existing install...'
    if (Test-Path -LiteralPath $ComposeFile) {
        $null = Invoke-Docker @('compose', '-f', $ComposeFile, 'down', '-v')
    }
    foreach ($c in 'vanilla-mangosd', 'vanilla-realmd', 'vanilla-db') {
        $null = Invoke-Docker @('rm', '-f', $c)
    }
    $null = Invoke-Docker @('volume', 'rm', $DbVolume)
    $null = Invoke-Docker @('volume', 'rm', $DataVolume)
    if ($AlsoImage) { $null = Invoke-Docker @('rmi', $ServerImage) }
    if (Test-Path -LiteralPath $ServerDir) {
        Remove-Item -LiteralPath $ServerDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# =============================================================================
# EXTRACT CLIENT DATA
# =============================================================================
$CountScript = @'
for d in maps dbc vmaps mmaps; do
    echo "$d=$(ls /data/$d 2>/dev/null | wc -l)"
done
'@

function Get-DataCounts {
    $counts = @{ maps = 0; dbc = 0; vmaps = 0; mmaps = 0 }
    $null = Invoke-ImageScript -Name 'count-data' -Body $CountScript -RunArgs @('-v', "${DataVolume}:/data")
    foreach ($line in $Script:LastOutput) {
        if ($line -match '^(maps|dbc|vmaps|mmaps)=(\d+)$') { $counts[$Matches[1]] = [int]$Matches[2] }
    }
    return $counts
}

$ExtractScript = @'
set -e
ulimit -s unlimited 2>/dev/null || true
echo "=== Extraction starting at $(date) ==="
cd /client
echo "Working directory: $(pwd)"
echo ""
echo "=== Running ExtractResources.sh a (non-interactive, all data) ==="
# "a" = extract all, non-interactive. CWD must be the client folder;
# the script finds its sibling binaries via dirname "$0".
/opt/mangos/bin/tools/ExtractResources.sh a || true
echo ""
echo "=== Moving outputs to /extracted ==="
for d in dbc maps vmaps Buildings Cameras CreatureModels; do
    if [ -d "/client/$d" ]; then
        echo "Moving /client/$d -> /extracted/$d"
        rm -rf "/extracted/$d" 2>/dev/null
        mv "/client/$d" "/extracted/$d"
    fi
done
for f in /client/MaNGOSExtractor.log /client/MaNGOSExtractor_detailed.log; do
    [ -f "$f" ] && mv "$f" /extracted/
done
echo "=== Extraction phase complete! ==="
'@

$VmapRetryScript = @'
ulimit -s unlimited 2>/dev/null || true
cd /client
echo "=== Vmap retry starting at $(date) ==="
/opt/mangos/bin/tools/vmap_extractor || true
if [ -d "/client/Buildings" ]; then
    mkdir -p /client/vmaps
    /opt/mangos/bin/tools/vmap_assembler Buildings vmaps 2>&1 || true
    rm -rf /client/Buildings
fi
if [ -d "/client/vmaps" ] && [ "$(ls /client/vmaps 2>/dev/null | wc -l)" -gt 0 ]; then
    echo "Moving /client/vmaps -> /extracted/vmaps"
    rm -rf /extracted/vmaps
    mv /client/vmaps /extracted/vmaps
fi
echo "=== Vmap retry complete at $(date) ==="
echo "Vmap file count: $(ls /extracted/vmaps 2>/dev/null | wc -l)"
'@

$MmapScript = @'
ulimit -s unlimited 2>/dev/null || true
cd /data
rm -rf /data/mmaps
mkdir -p /data/mmaps
/opt/mangos/bin/tools/MoveMapGen --silent --threads "${MMAP_THREADS:-2}"
echo ""
echo "=== Generation done at $(date) ==="
echo "Final mmap file count: $(ls /data/mmaps | wc -l)"
'@

function Invoke-Extraction {
    Write-Header
    Write-Step 'STEP 4/5 -- Extracting Map Data (10-20 minutes)'

    $null = Invoke-Docker @('volume', 'create', $DataVolume)

    # -- Re-run shortcut: reuse good data already in the volume ----------
    $c = Get-DataCounts
    if ($c.maps -ge 100 -and $c.dbc -ge 100 -and $c.vmaps -ge 100 -and $c.mmaps -ge 500) {
        Write-Ok "Existing extracted data found in volume '$DataVolume':"
        Write-Info "  maps: $($c.maps)  dbc: $($c.dbc)  vmaps: $($c.vmaps)  mmaps: $($c.mmaps)"
        if (Read-YesNo 'Reuse it and skip extraction + mmap generation? (saves ~30-50 min)') {
            Write-Ok 'Reusing existing client data.'
            return
        }
    }

    Write-Info 'Running the extractors compiled into our server image...'
    Write-Info 'This reads your WoW client and extracts:'
    Write-Info '  - Map data (dbc + maps)'
    Write-Info '  - Vmaps (visual obstructions for line-of-sight)'
    Write-Info '  - Mmaps (movement pathfinding -- required for Playerbots)'
    Write-Host ''
    # The client folder is mounted directly at /client: the extractor writes
    # its outputs into the CWD, and we move them into the data volume.
    Write-Info "Extraction logs: $ExtractLog"
    Write-Warn 'NOTE: Extraction writes temp folders into your client folder.'
    Write-Warn '      They get moved out automatically when extraction finishes.'
    Write-Host ''

    $clientMount = @('-v', "$($Script:ClientDir):/client", '-v', "${DataVolume}:/extracted")
    $code = Invoke-ImageScript -Name 'extract' -Body $ExtractScript -RunArgs $clientMount `
        -LogPath $ExtractLog -HeartbeatMinutes 5 -HeartbeatText 'Still extracting'
    if ($code -ne 0) {
        Write-Warn 'Extraction reported errors -- checking output anyway'
    }

    # "exit code 0" doesn't mean success -- extraction can silently
    # produce empty folders. Count files.
    $c = Get-DataCounts
    Write-Info '  Extraction outputs:'
    Write-Info "    maps:  $($c.maps) files (expect ~2000-4000)"
    Write-Info "    dbc:   $($c.dbc) files (expect ~150)"
    Write-Info "    vmaps: $($c.vmaps) files (expect ~3000+)"

    $segfault = (Test-Path -LiteralPath $ExtractLog) -and
                (Select-String -LiteralPath $ExtractLog -Pattern 'Segmentation fault|core dumped' -Quiet)

    # -- Segfault recovery: retry vmap extraction separately ------------
    # A map-extractor segfault (known on some Kalimdor tiles) exits before
    # the vmap tool runs. vmaps read the MPQs directly, so retry just those.
    if ($c.vmaps -lt 100 -and $c.dbc -ge 100 -and $segfault) {
        Write-Warn 'Extractor crashed with a segmentation fault during map extraction.'
        Write-Info 'Retrying vmap extraction separately -- vmaps read MPQ files directly'
        Write-Info 'and can succeed even after the map extractor crashes.'
        Write-Host ''
        $code = Invoke-ImageScript -Name 'vmap-retry' -Body $VmapRetryScript -RunArgs $clientMount -LogPath $VmapLog
        if ($code -ne 0) { Write-Warn 'Vmap retry reported errors -- checking output anyway' }
        $c = Get-DataCounts
        if ($c.vmaps -ge 100) {
            Write-Ok "Vmap retry succeeded! ($($c.vmaps) vmap files recovered)"
        } else {
            Write-Warn "Vmap retry produced $($c.vmaps) files -- still below threshold."
            Write-Info "Retry log: $VmapLog"
        }
    }

    if ($c.maps -lt 100 -or $c.dbc -lt 100 -or $c.vmaps -lt 100) {
        Write-Err 'Extraction did not produce enough output files!'
        Write-Info ''
        if ($segfault) {
            Write-Info '  DETECTED: Extractor crashed with a segmentation fault.'
            Write-Info '     This is a known CMaNGOS issue on certain Kalimdor map tiles.'
            Write-Info '     Common fix: close other apps to free RAM and re-run.'
        }
        if ($c.dbc -lt 100)   { Write-Info "  - DBC files low ($($c.dbc)):   Check that Data\dbc.MPQ exists in your client" }
        if ($c.maps -lt 100)  { Write-Info "  - Map files low ($($c.maps)):  Extraction failed before maps were written" }
        if ($c.vmaps -lt 100) { Write-Info "  - Vmap files low ($($c.vmaps)): Vmap tool crashed or was skipped" }
        Write-Info ''
        Write-Info "Full extract log: $ExtractLog"
        if (-not (Read-YesNo 'Continue anyway? (server WILL fail to load maps)')) {
            Exit-Installer 1
        }
    } else {
        Write-Ok 'Extraction outputs validated!'
    }

    # -- MMAP GENERATION -- required, not optional -----------------------
    # With Playerbots compiled in, bots iterate all maps for travel nodes
    # and crash on missing mmap files even with mmap.enabled = 0.
    Write-Step 'Generating mmap pathfinding (~15-30 min -- last big wait!)'
    Write-Info 'Progress streams to your terminal. Walk away if you want.'
    Write-Info "When you see '=== Generation done ===', it's finished."
    Write-Host ''

    $code = Invoke-ImageScript -Name 'mmap-gen' -Body $MmapScript `
        -RunArgs @('-v', "${DataVolume}:/data", '-e', "MMAP_THREADS=$($Script:MmapThreads)") `
        -LogPath $MmapLog -HeartbeatMinutes 5 -HeartbeatText 'Still generating mmaps'
    if ($code -ne 0) { Write-Warn 'Mmap generation reported errors -- checking output anyway' }

    $c = Get-DataCounts
    Write-Info "  mmap files generated: $($c.mmaps) (expect ~2000)"
    if ($c.mmaps -lt 500) {
        Write-Warn 'Mmap count is lower than expected.'
        Write-Warn 'Server may still boot, but bots will pathfind poorly.'
    } else {
        Write-Ok "Mmaps generated! ($($c.mmaps) files)"
    }
    Write-Ok 'Client data extraction complete!'
}

# =============================================================================
# WRITE COMPOSE + CONFIGS
# =============================================================================
$ComposeTemplate = @'
name: __PROJECT__

services:
  db:
    image: mariadb:11
    container_name: vanilla-db
    restart: unless-stopped
    environment:
      MARIADB_ROOT_PASSWORD: __DB_PASSWORD__
      MARIADB_DATABASE: characters
    volumes:
      - db-data:/var/lib/mysql
    networks:
      - vanilla-net
    healthcheck:
      test: ["CMD-SHELL", "MYSQL_PWD=$$MARIADB_ROOT_PASSWORD mariadb -u root -e 'SELECT 1'"]
      interval: 10s
      timeout: 5s
      retries: 30
      start_period: 60s

  realmd:
    image: __SERVER_IMAGE__
    container_name: vanilla-realmd
    restart: unless-stopped
    depends_on:
      db:
        condition: service_healthy
    ports:
      - "3724:3724"
    volumes:
      - ./etc:/opt/mangos/etc
      - vanilla-data:/opt/mangos/data
    networks:
      - vanilla-net
    command: ["./realmd"]

  mangosd:
    image: __SERVER_IMAGE__
    container_name: vanilla-mangosd
    restart: unless-stopped
    depends_on:
      db:
        condition: service_healthy
    ports:
      - "8085:8085"
    volumes:
      - ./etc:/opt/mangos/etc
      - vanilla-data:/opt/mangos/data
    networks:
      - vanilla-net
    stdin_open: true
    tty: true
    command: ["./mangosd"]

volumes:
  db-data:
  vanilla-data:
    external: true
    name: __DATA_VOLUME__

networks:
  vanilla-net:
    driver: bridge
'@

# Runs inside the server image with <server>\etc mounted at /out.
# Copies the .dist templates and patches them -- same sed lines as the .sh.
$ConfigureScript = @'
cp /opt/mangos/etc/mangosd.conf.dist /out/mangosd.conf 2>/dev/null || true
cp /opt/mangos/etc/realmd.conf.dist /out/realmd.conf 2>/dev/null || true
cp /opt/mangos/etc/ahbot.conf.dist /out/ahbot.conf 2>/dev/null || true
cp -r /opt/mangos/etc/*aiplayerbot*.dist /out/ 2>/dev/null || true
cd /out
for f in *.dist; do
    [ -f "$f" ] && mv "$f" "${f%.dist}"
done

if [ ! -f /out/mangosd.conf ]; then
    echo "MANGOSD_CONF=missing"
    exit 1
fi

# Five lines -- missing any of them silently breaks boot
C=/out/mangosd.conf
sed -i "s|^LoginDatabaseInfo.*|LoginDatabaseInfo = \"db;3306;mangos;${DB_PASSWORD};realmd\"|" "$C"
sed -i "s|^WorldDatabaseInfo.*|WorldDatabaseInfo = \"db;3306;mangos;${DB_PASSWORD};mangos\"|" "$C"
sed -i "s|^CharacterDatabaseInfo.*|CharacterDatabaseInfo = \"db;3306;mangos;${DB_PASSWORD};characters\"|" "$C"
sed -i "s|^LogsDatabaseInfo.*|LogsDatabaseInfo = \"db;3306;mangos;${DB_PASSWORD};logs\"|" "$C"
sed -i "s|^DataDir\s*=.*|DataDir = \"/opt/mangos/data\"|" "$C"

ok=0
for pattern in "LoginDatabaseInfo.*${DB_PASSWORD}" \
               "WorldDatabaseInfo.*${DB_PASSWORD}" \
               "CharacterDatabaseInfo.*${DB_PASSWORD}" \
               "LogsDatabaseInfo.*${DB_PASSWORD}" \
               "DataDir.*/opt/mangos/data"; do
    if grep -q "^${pattern%%.*}" "$C" 2>/dev/null && grep -qE "$pattern" "$C" 2>/dev/null; then
        ok=$((ok + 1))
    fi
done
echo "MANGOSD_PATCHES=$ok"

if [ -f /out/realmd.conf ]; then
    sed -i "s|^LoginDatabaseInfo.*|LoginDatabaseInfo = \"db;3306;mangos;${DB_PASSWORD};realmd\"|" /out/realmd.conf
    echo "REALMD_CONF=patched"
fi

# Playerbots: 600-800 random bots
B=/out/aiplayerbot.conf
if [ -f "$B" ]; then
    sed -i "s|^AiPlayerbot\.MinRandomBots .*|AiPlayerbot.MinRandomBots = 600|" "$B"
    sed -i "s|^AiPlayerbot\.MaxRandomBots .*|AiPlayerbot.MaxRandomBots = 800|" "$B"
    sed -i "s|^AiPlayerbot\.RandomBotAccountCount .*|AiPlayerbot.RandomBotAccountCount = 200|" "$B"
    sed -i "s|^#\? *AiPlayerbot\.SyncLevelWithPlayers .*|AiPlayerbot.SyncLevelWithPlayers = 1|" "$B"
    sed -i "s|^#\? *AiPlayerbot\.SyncLevelMaxAbove .*|AiPlayerbot.SyncLevelMaxAbove = 5|" "$B"
    sed -i "s|^#\? *AiPlayerbot\.SyncLevelNoPlayer .*|AiPlayerbot.SyncLevelNoPlayer = 1|" "$B"
    echo "AIPLAYERBOT_CONF=patched"
fi

# AHBot: high-volume auction house (~15k items target)
A=/out/ahbot.conf
if [ -f "$A" ]; then
    sed -i "s|^AuctionHouseBot\.Chance\.Sell .*|AuctionHouseBot.Chance.Sell = 75|" "$A"
    sed -i "s|^AuctionHouseBot\.Loot\.Creature\.Normal .*|AuctionHouseBot.Loot.Creature.Normal    =   90, 100, 30, 40|" "$A"
    sed -i "s|^AuctionHouseBot\.Loot\.Creature\.Rare .*|AuctionHouseBot.Loot.Creature.Rare      =    0,  30,  1,  2|" "$A"
    sed -i "s|^AuctionHouseBot\.Loot\.Creature\.Elite .*|AuctionHouseBot.Loot.Creature.Elite     =   80,  90,  4,  6|" "$A"
    sed -i "s|^AuctionHouseBot\.Loot\.Creature\.RareElite .*|AuctionHouseBot.Loot.Creature.RareElite =    0,  15,  1,  2|" "$A"
    sed -i "s|^AuctionHouseBot\.Loot\.Creature\.WorldBoss .*|AuctionHouseBot.Loot.Creature.WorldBoss =  -10,   2,  1,  1|" "$A"
    sed -i "s|^AuctionHouseBot\.Loot\.Disenchant .*|AuctionHouseBot.Loot.Disenchant =   40,  50,  2,  3|" "$A"
    sed -i "s|^AuctionHouseBot\.Loot\.Fishing .*|AuctionHouseBot.Loot.Fishing    =   12,  18,100,150|" "$A"
    sed -i "s|^AuctionHouseBot\.Loot\.Gameobject .*|AuctionHouseBot.Loot.Gameobject =   50,  60, 30, 45|" "$A"
    sed -i "s|^AuctionHouseBot\.Loot\.Skinning .*|AuctionHouseBot.Loot.Skinning   =   12,  18,200,250|" "$A"
    sed -i "s|^AuctionHouseBot\.Items\.Profession .*|AuctionHouseBot.Items.Profession = 250, 300, 0, 50|" "$A"
    echo "AHBOT_CONF=patched"
fi
'@

function New-DbPassword {
    $bytes = New-Object byte[] 8
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $rng.GetBytes($bytes)
    $rng.Dispose()
    return 'vanilla' + (($bytes | ForEach-Object { $_.ToString('x2') }) -join '')
}

function Write-ComposeAndConfigs {
    Write-Step 'Writing compose.yml and configs'

    # -- Persist DB password across re-runs ------------------------------
    # An existing MariaDB volume was initialized with the old password; a
    # new random one would get "Access denied for root".
    if (Test-Path -LiteralPath $PwFile) {
        $Script:DbPassword = (Get-Content -LiteralPath $PwFile -Raw).Trim()
        $Script:DbPasswordLoaded = $true
        Write-Info 'Loaded existing database password from previous install.'
    }
    if (-not $Script:DbPassword) {
        $Script:DbPassword = New-DbPassword
        $Script:DbPasswordLoaded = $false
        [System.IO.File]::WriteAllText($PwFile, $Script:DbPassword, (New-Object System.Text.UTF8Encoding $false))
        try {
            $pwItem = Get-Item -LiteralPath $PwFile -Force
            $pwItem.Attributes = $pwItem.Attributes -bor [System.IO.FileAttributes]::Hidden
        } catch { }
    }

    $compose = $ComposeTemplate.
        Replace('__PROJECT__', $ComposeProject).
        Replace('__DB_PASSWORD__', $Script:DbPassword).
        Replace('__SERVER_IMAGE__', $ServerImage).
        Replace('__DATA_VOLUME__', $DataVolume)
    Write-LfFile $ComposeFile $compose
    Write-Ok 'compose.yml written'

    New-Item -ItemType Directory -Path $EtcDir -Force | Out-Null
    Write-Info 'Extracting config templates from compiled image and patching them...'
    $code = Invoke-ImageScript -Name 'configure' -Body $ConfigureScript `
        -RunArgs @('-v', "${EtcDir}:/out", '-e', "DB_PASSWORD=$($Script:DbPassword)")
    $out = $Script:LastOutput -join "`n"

    if ($code -ne 0 -or $out -match 'MANGOSD_CONF=missing') {
        Write-Err 'mangosd.conf not extracted from image!'
        Show-Tail $Script:LastOutput 10
        Exit-Installer 1
    }

    $patches = 0
    if ($out -match 'MANGOSD_PATCHES=(\d+)') { $patches = [int]$Matches[1] }
    if ($patches -eq 5) {
        Write-Ok 'mangosd.conf patched (all 5/5 verified)'
    } else {
        Write-Warn "mangosd.conf patching incomplete -- only $patches/5 verified."
        Write-Warn 'Server will likely fail to connect to the database.'
        Write-Info "Check $EtcDir\mangosd.conf before starting."
    }
    if ($out -match 'REALMD_CONF=patched')      { Write-Ok 'realmd.conf patched' }
    if ($out -match 'AIPLAYERBOT_CONF=patched') { Write-Ok 'aiplayerbot.conf patched (600-800 bots, 200 accounts, level-synced to player+5)' }
    if ($out -match 'AHBOT_CONF=patched')       { Write-Ok 'ahbot.conf patched (Chance.Sell=75, high-volume loot)' }
    Write-Ok 'Configs written and patched'
}

# =============================================================================
# SETUP DATABASE
# =============================================================================
function Wait-DbReady([int]$TimeoutSec = 300, [switch]$UseHealth) {
    $elapsed = 0
    while ($elapsed -lt $TimeoutSec) {
        if ($UseHealth) {
            $health = Invoke-Docker @('inspect', '--format', '{{.State.Health.Status}}', 'vanilla-db') | Select-Object -First 1
            if ($health -eq 'healthy') { Write-Host ''; return 'ready' }
            if ($health -eq 'unhealthy') { Write-Host ''; return 'unhealthy' }
        }
        # Fallback: a direct connection in case the healthcheck is slow
        if (Test-DockerOk @('exec', '-e', "MYSQL_PWD=$($Script:DbPassword)", 'vanilla-db', 'mariadb', '-u', 'root', '-e', 'SELECT 1')) {
            Write-Host ''
            return 'ready'
        }
        Write-Host '.' -NoNewline
        Start-Sleep -Seconds 5
        $elapsed += 5
    }
    Write-Host ''
    return 'timeout'
}

$SchemaScript = @'
mariadb -h db -u root "$SCHEMA" < "/opt/mangos/sql/base/$SCHEMA.sql"
'@

$FullDbScript = @'
set -o pipefail
gunzip -c /opt/mangos/classic-db/Full_DB/ClassicDB_*.sql.gz | mariadb -h db -u root mangos
'@

$ContentUpdatesScript = @'
cd /opt/mangos/classic-db/Updates
for sql in $(ls -v *.sql); do
    mariadb -h db -u root mangos < "$sql" 2>/dev/null
done
echo "Done"
'@

$AcidScript = @'
mariadb -h db -u root mangos < /opt/mangos/classic-db/ACID/acid_classic.sql
'@

$CoreUpdatesScript = @'
for db in mangos realmd characters logs; do
    cd /opt/mangos/sql/updates/$db 2>/dev/null || continue
    for sql in $(ls -v *.sql 2>/dev/null); do
        mariadb -h db -u root "$db" < "$sql" 2>/dev/null
    done
done
echo "Done"
'@

$PlayerbotsSqlScript = @'
for sql in /opt/mangos/playerbots-sql/characters/*.sql; do
    mariadb -h db -u root characters < "$sql" 2>/dev/null
done
for sql in /opt/mangos/playerbots-sql/world/*.sql; do
    mariadb -h db -u root mangos < "$sql" 2>/dev/null
done
for sql in /opt/mangos/playerbots-sql/world/classic/*.sql; do
    mariadb -h db -u root mangos < "$sql" 2>/dev/null
done
echo "Done"
'@

function Initialize-Database {
    Write-Header
    Write-Step 'Setting up databases (~2-5 min)'

    # Remove any stale container so 'compose up' doesn't hit "name already in use"
    $null = Invoke-Docker @('rm', '-f', 'vanilla-db')

    # -- Stale volume detection ------------------------------------------
    # New password + existing volume = volume initialized with a different
    # password. Wipe it so MariaDB re-initializes cleanly.
    if (-not $Script:DbPasswordLoaded) {
        $vols = Invoke-Docker @('volume', 'ls', '-q')
        if ($vols -contains $DbVolume) {
            Write-Warn 'Found stale MariaDB volume with unknown password -- removing so DB re-initializes cleanly...'
            $null = Invoke-Docker @('volume', 'rm', $DbVolume)
        }
    }

    Write-Info 'Pulling MariaDB image...'
    $pull = Invoke-Docker @('pull', 'mariadb:11')
    if ($LASTEXITCODE -ne 0) { Write-Warn 'Image pull had warnings -- continuing' }
    Show-Tail $pull 3

    Write-Info 'Starting MariaDB container...'
    if ((Invoke-Compose @('up', '-d', 'db')) -ne 0) {
        Write-Err 'Failed to start db container.'
        Write-Info "Check: docker compose -f `"$ComposeFile`" logs db"
        Exit-Installer 1
    }

    Write-Info 'Waiting for MariaDB to be ready (up to 5 min on first run)...'
    $state = Wait-DbReady -TimeoutSec 300 -UseHealth
    if ($state -ne 'ready') {
        if ($state -eq 'unhealthy') {
            Write-Err 'MariaDB healthcheck failed -- container is unhealthy.'
        } else {
            Write-Err 'MariaDB didn''t respond within 5 minutes.'
        }
        Write-Info 'Last 20 lines from the container:'
        Invoke-Docker @('logs', 'vanilla-db', '--tail', '20') | ForEach-Object { Write-Host "    $_" }
        Write-Info 'Full logs: docker logs vanilla-db'
        Exit-Installer 1
    }
    Write-Ok 'MariaDB ready'

    # -- Credential check: "healthy" is liveness only ---------------------
    if (-not (Test-DockerOk @('exec', '-e', "MYSQL_PWD=$($Script:DbPassword)", 'vanilla-db', 'mariadb', '-u', 'root', '-e', 'SELECT 1'))) {
        Write-Warn 'Password mismatch -- volume initialized with a different password.'
        Write-Warn 'Removing stale volume and reinitializing (data will be re-imported)...'
        $null = Invoke-Compose @('down')
        $null = Invoke-Docker @('volume', 'rm', $DbVolume)
        Write-Info 'Restarting MariaDB with correct password...'
        if ((Invoke-Compose @('up', '-d', 'db')) -ne 0) {
            Write-Err 'Failed to restart db container after volume reset.'
            Exit-Installer 1
        }
        if ((Wait-DbReady -TimeoutSec 300) -ne 'ready') {
            Write-Err 'MariaDB didn''t respond within 5 minutes after volume reset.'
            Invoke-Docker @('logs', 'vanilla-db', '--tail', '20') | ForEach-Object { Write-Host "    $_" }
            Exit-Installer 1
        }
        Write-Ok 'MariaDB reinitialized with correct password'
    }

    # -- Phase 1: mangos user with grants on all 4 DBs --------------------
    Write-Info 'Creating mangos database user with grants...'
    $sql = @"
CREATE DATABASE IF NOT EXISTS mangos CHARACTER SET utf8mb4;
CREATE DATABASE IF NOT EXISTS realmd CHARACTER SET utf8mb4;
CREATE DATABASE IF NOT EXISTS characters CHARACTER SET utf8mb4;
CREATE DATABASE IF NOT EXISTS logs CHARACTER SET utf8mb4;
CREATE USER IF NOT EXISTS 'mangos'@'%' IDENTIFIED BY '$($Script:DbPassword)';
GRANT ALL PRIVILEGES ON mangos.* TO 'mangos'@'%';
GRANT ALL PRIVILEGES ON realmd.* TO 'mangos'@'%';
GRANT ALL PRIVILEGES ON characters.* TO 'mangos'@'%';
GRANT ALL PRIVILEGES ON logs.* TO 'mangos'@'%';
FLUSH PRIVILEGES;
"@
    if ((Invoke-DbSql $sql) -ne 0) {
        Show-Tail $Script:LastOutput 3
        Write-Err 'Failed to create mangos user'
        Exit-Installer 1
    }
    Write-Ok 'Created 4 databases + mangos@% user'

    # -- Detect the compose network name at runtime ----------------------
    $net = Invoke-Docker @('network', 'ls', '--format', '{{.Name}}') | Where-Object { $_ -match 'vanilla-net' } | Select-Object -First 1
    if (-not $net) {
        Write-Err 'Couldn''t find the vanilla-net Docker network.'
        Write-Info 'Run: docker network ls'
        Write-Info 'If you see no vanilla-net, the db container failed to start.'
        Exit-Installer 1
    }
    Write-Info "Using Docker network: $net"
    $dbArgs = @('--network', $net, '-e', "MYSQL_PWD=$($Script:DbPassword)")

    # -- Phase 2: base schemas (mangos comes via Full_DB) -----------------
    Write-Info 'Importing base schemas (realmd, characters, logs -- mangos comes via Full_DB)...'
    foreach ($schema in 'realmd', 'characters', 'logs') {
        $code = Invoke-ImageScript -Name 'schema' -Body $SchemaScript -RunArgs ($dbArgs + @('-e', "SCHEMA=$schema"))
        if ($code -ne 0) {
            Show-Tail $Script:LastOutput 3
            Write-Warn "Schema $schema.sql had errors (may be OK if already imported)"
        } else {
            Write-Ok "  $schema schema imported"
        }
    }

    # -- Phase 3: classic-db Full World Database -------------------------
    Write-Info 'Importing world content (creatures/items/quests)...'
    $code = Invoke-ImageScript -Name 'full-db' -Body $FullDbScript -RunArgs $dbArgs
    Show-Tail $Script:LastOutput 3
    if ($code -ne 0) {
        Write-Err 'Full DB import failed'
        Exit-Installer 1
    }
    Write-Ok 'World content imported (~17K items, 10K creatures, 4K quests)'

    # -- Phase 4: classic-db content Updates ------------------------------
    Write-Info 'Applying classic-db content updates (300+ files)...'
    $null = Invoke-ImageScript -Name 'content-updates' -Body $ContentUpdatesScript -RunArgs $dbArgs
    Show-Tail $Script:LastOutput 2
    Write-Ok 'Content updates applied'

    # -- Phase 5: ACID scripts (creature AI behaviors) --------------------
    Write-Info 'Importing ACID creature AI scripts...'
    if ((Invoke-ImageScript -Name 'acid' -Body $AcidScript -RunArgs $dbArgs) -ne 0) {
        Show-Tail $Script:LastOutput 2
        Write-Warn 'ACID had errors (may be OK)'
    }
    Write-Ok 'ACID scripts imported'

    # -- Phase 6: core schema updates -------------------------------------
    Write-Info 'Applying core schema updates (mangos, realmd, characters, logs)...'
    $null = Invoke-ImageScript -Name 'core-updates' -Body $CoreUpdatesScript -RunArgs $dbArgs
    Show-Tail $Script:LastOutput 2
    Write-Ok 'Core schema updates applied'

    # -- Phase 7: spell_template column fixes, explicitly -----------------
    # z2817/z2818 abort on their first statement when piped; without these
    # 6 columns mangosd refuses to load spell_template.
    Write-Info 'Applying spell_template column extension (6 columns)...'
    $spellSql = @'
ALTER TABLE spell_template
    ADD COLUMN IF NOT EXISTS EffectBonusCoefficient1 FLOAT NOT NULL DEFAULT '0' AFTER RequiredAuraVision,
    ADD COLUMN IF NOT EXISTS EffectBonusCoefficient2 FLOAT NOT NULL DEFAULT '0' AFTER EffectBonusCoefficient1,
    ADD COLUMN IF NOT EXISTS EffectBonusCoefficient3 FLOAT NOT NULL DEFAULT '0' AFTER EffectBonusCoefficient2,
    ADD COLUMN IF NOT EXISTS EffectBonusCoefficientFromAP1 FLOAT NOT NULL DEFAULT '0' AFTER EffectBonusCoefficient3,
    ADD COLUMN IF NOT EXISTS EffectBonusCoefficientFromAP2 FLOAT NOT NULL DEFAULT '0' AFTER EffectBonusCoefficientFromAP1,
    ADD COLUMN IF NOT EXISTS EffectBonusCoefficientFromAP3 FLOAT NOT NULL DEFAULT '0' AFTER EffectBonusCoefficientFromAP2;
'@
    $null = Invoke-DbSql $spellSql 'mangos'
    Show-Tail $Script:LastOutput 3
    Write-Ok 'spell_template extended'

    # -- Phase 8: Playerbots SQL ------------------------------------------
    # Without it: "Table 'mangos.ai_playerbot_help_texts' doesn't exist"
    Write-Info 'Importing Playerbots SQL (14 files, ~23 tables)...'
    $null = Invoke-ImageScript -Name 'playerbots-sql' -Body $PlayerbotsSqlScript -RunArgs $dbArgs
    Show-Tail $Script:LastOutput 2
    Write-Ok 'Playerbots SQL imported'

    # -- Phase 9: verify ---------------------------------------------------
    Write-Info 'Verifying database setup...'
    $itemCount = Get-DbScalar 'mangos' 'SELECT COUNT(*) FROM item_template'
    $botTables = Get-DbScalar 'mangos' "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='mangos' AND table_name LIKE 'ai_playerbot%'"
    Write-Info "  item_template rows: $(if ($null -ne $itemCount) { $itemCount } else { 'unknown' }) (expect ~17,718)"
    Write-Info "  ai_playerbot_* tables: $(if ($null -ne $botTables) { $botTables } else { 'unknown' }) (expect ~12)"

    if ($null -ne $itemCount -and $itemCount -ge 17000 -and $null -ne $botTables -and $botTables -ge 10) {
        Write-Ok 'Database setup looks healthy!'
    } else {
        Write-Warn 'Database setup may be incomplete -- see warnings above'
        Write-Info 'You can proceed, but mangosd may fail to boot.'
    }
}

# =============================================================================
# FIRST START + READY WAIT
# =============================================================================
function Get-RestartCount {
    $v = Invoke-Docker @('inspect', '--format', '{{.RestartCount}}', 'vanilla-mangosd') | Select-Object -First 1
    if ($v -match '^\d+$') { return [int]$v }
    return 0
}

function Start-Server {
    Write-Header
    Write-Step 'Starting world & login servers'

    Write-Info 'Starting mangosd (world) and realmd (login)...'
    if ((Invoke-Compose @('up', '-d', 'mangosd', 'realmd')) -ne 0) {
        Write-Err 'Failed to start mangosd/realmd.'
        Write-Info "Check: docker compose -f `"$ComposeFile`" logs"
        Write-Info 'If it says a port is already in use / forbidden: something else uses'
        Write-Info '3724 or 8085, or Windows reserved it. Check with:'
        Write-Info '  netsh interface ipv4 show excludedportrange protocol=tcp'
        Exit-Installer 1
    }

    Write-Info 'Containers started. Waiting for world server to be ready...'
    Write-Info '(Vanilla + Playerbots loads 200+ bots -- first boot takes 2-8 min.)'
    Write-Host ''

    # Only count NEW restarts from this session
    $baseRestarts = Get-RestartCount
    $timeout = 600; $elapsed = 0
    $ready = $false; $restartLoop = $false

    while ($elapsed -lt $timeout) {
        # mangosd prints "Avg Diff:" once it enters its main update loop
        $logs = Invoke-Docker @('logs', 'vanilla-mangosd', '--since', '15m')
        if ($logs | Select-String -SimpleMatch 'Avg Diff:' -Quiet) { $ready = $true; break }

        if ((Get-RestartCount) - $baseRestarts -ge 4) { $restartLoop = $true; break }

        Write-Host '.' -NoNewline
        Start-Sleep -Seconds 10
        $elapsed += 10
    }
    Write-Host ''
    Write-Host ''

    if ($ready) {
        Write-Ok 'World server is online!'
        Write-Info '  Port 8085 (world) and 3724 (login) are listening'
    } elseif ($restartLoop) {
        Write-Err 'mangosd is in a restart loop -- boot failed.'
        Write-Info 'Check: docker logs vanilla-mangosd --tail 100'
        Write-Info ''
        Write-Info 'Most common causes at this point:'
        Write-Info '  - A schema update didn''t apply (check spell_template column count)'
        Write-Info '  - Playerbots SQL didn''t import (check ai_playerbot_* tables)'
        Write-Info '  - Mmap files missing (check mmaps count above, expect 2000+)'
        Write-Info ''
        if (-not (Read-YesNo 'Continue to account creation anyway? (server won''t be usable)')) {
            Exit-Installer 1
        }
    } else {
        Write-Warn 'Server taking longer than 10 min to initialize.'
        Write-Info 'It may still be loading -- check: docker logs vanilla-mangosd -f'
        Write-Info 'Look for ''Avg Diff:'' to confirm it''s running.'
    }
}

# =============================================================================
# CREATE DEFAULT ACCOUNT
# =============================================================================
function Show-AccountStep {
    Write-Step 'Account creation -- quick post-install step'
    # Same reasoning as the .sh: CMaNGOS uses SRP6 verifiers; the mangosd
    # console command is the reliable way to create the account.
    Write-Info 'Account creation is a quick manual step after install completes.'
    Write-Info 'See the next screen for the exact commands (it''s two lines).'
    Write-Info 'The mangosd console handles SRP6 password hashing correctly.'
}

# =============================================================================
# DESKTOP LAUNCHER (replaces the Steam Deck Gaming Mode launcher)
# =============================================================================
$LauncherTemplate = @'
# Dad's MMO Lab -- Vanilla WoW Server Launcher (Windows / Docker Desktop)
# Starts Docker Desktop if needed, boots the server, launches WoW,
# and shuts the server down again when WoW closes.
# Generated by install-wow-vanilla.ps1 -- re-running the installer overwrites it.

$ErrorActionPreference = 'Continue'
$ServerDir   = '__SERVER_DIR__'
$ClientDir   = '__CLIENT_DIR__'
$ComposeFile = Join-Path $ServerDir 'compose.yml'
$LogFile     = Join-Path $env:TEMP 'wow-vanilla-launcher.log'
$DockerDesktopExe = Join-Path $env:ProgramFiles 'Docker\Docker\Docker Desktop.exe'
$DockerBinDir     = Join-Path $env:ProgramFiles 'Docker\Docker\resources\bin'

"=== Vanilla WoW Launcher started $(Get-Date) ===" | Set-Content -Path $LogFile

function Test-DockerUp { & docker info *> $null; return ($LASTEXITCODE -eq 0) }
function Test-KeyPressed {
    try {
        if ([Console]::KeyAvailable) {
            $k = [Console]::ReadKey($true)
            return ($k.Key -eq 'Enter')
        }
    } catch { }
    return $false
}
function Stop-Server {
    & docker compose -f $ComposeFile down *>> $LogFile
}

Clear-Host
Write-Host ''
Write-Host ' ==================================================' -ForegroundColor DarkYellow
Write-Host "   Dad's MMO Lab  *  Vanilla WoW" -ForegroundColor Gray
Write-Host ' ==================================================' -ForegroundColor DarkYellow
Write-Host ''

if (-not (Get-Command docker -ErrorAction SilentlyContinue) -and (Test-Path -LiteralPath $DockerBinDir)) {
    $env:Path = "$env:Path;$DockerBinDir"
}

if (-not (Test-DockerUp)) {
    Write-Host '  Starting Docker Desktop...' -ForegroundColor Yellow
    if (Test-Path -LiteralPath $DockerDesktopExe) { Start-Process -FilePath $DockerDesktopExe | Out-Null }
    $t = 0
    while (-not (Test-DockerUp) -and $t -lt 240) { Write-Host '.' -NoNewline -ForegroundColor DarkYellow; Start-Sleep 5; $t += 5 }
    Write-Host ''
    if (-not (Test-DockerUp)) {
        Write-Host '  Docker Desktop did not start. Start it manually and try again.' -ForegroundColor Red
        Read-Host '  Press ENTER to close'
        exit 1
    }
}

Write-Host '  Starting server...' -ForegroundColor White
Write-Host ''

# Stop any conflicting WoW containers from other expansions (same ports)
$other = @(& docker ps --format '{{.Names}}' 2>$null | Where-Object { $_ -match '(?i)tbc|wotlk|azeroth' })
if ($other.Count -gt 0) {
    Write-Host '  Stopping other expansion containers...' -ForegroundColor Yellow
    & docker stop @other *>> $LogFile
    Start-Sleep 2
}

& docker compose -f $ComposeFile up -d *>> $LogFile
if ($LASTEXITCODE -ne 0) {
    Write-Host "  Failed to start. Check: $LogFile" -ForegroundColor Red
    Read-Host '  Press ENTER to close'
    exit 1
}
Write-Host '  [ok] Containers started!' -ForegroundColor Green
Write-Host ''
Write-Host ' --------------------------------------------------' -ForegroundColor DarkYellow
Write-Host '  Waiting for Azeroth to open... (ENTER = shut down)' -ForegroundColor White
Write-Host ' --------------------------------------------------' -ForegroundColor DarkYellow

$manual = $false; $ready = $false; $elapsed = 0
while ($elapsed -lt 480) {
    $logs = & docker logs vanilla-mangosd --since 15m 2>&1 | ForEach-Object { "$_" }
    if ($logs | Select-String -SimpleMatch 'Avg Diff:' -Quiet) { $ready = $true; break }
    for ($i = 0; $i -lt 10; $i++) {
        if (Test-KeyPressed) { $manual = $true; break }
        Start-Sleep -Milliseconds 500
    }
    if ($manual) { break }
    Write-Host '.' -NoNewline -ForegroundColor DarkYellow
    $elapsed += 5
}
Write-Host ''
Write-Host ''

if (-not $manual) {
    if ($ready) {
        Write-Host '  AZEROTH IS READY!' -ForegroundColor Green
        Write-Host '  Login: player / player  *  Realmlist: 127.0.0.1' -ForegroundColor Gray
    } else {
        Write-Host '  Server still warming up -- check logs if needed:' -ForegroundColor Yellow
        Write-Host '    docker logs vanilla-mangosd -f' -ForegroundColor Yellow
    }
    Write-Host ''

    $wowExe = Join-Path $ClientDir 'WoW.exe'
    if (Test-Path -LiteralPath $wowExe) {
        Write-Host '  Launching WoW...' -ForegroundColor White
        Start-Process -FilePath $wowExe -WorkingDirectory $ClientDir | Out-Null
    } else {
        Write-Host '  Start WoW now.' -ForegroundColor White
    }
    Write-Host '  Server AUTO-SHUTS DOWN when WoW closes' -ForegroundColor Gray
    Write-Host '  -- or press ENTER to shut down manually --' -ForegroundColor Gray
    Write-Host ''

    $started = $false
    for ($i = 0; $i -lt 120 -and -not $manual; $i++) {
        if (Get-Process -Name 'WoW' -ErrorAction SilentlyContinue) { $started = $true; break }
        if (Test-KeyPressed) { $manual = $true; break }
        Start-Sleep -Milliseconds 2500
    }

    if (-not $manual) {
        if ($started) {
            Write-Host '  WoW detected! Enjoy Azeroth!' -ForegroundColor Green
            while (Get-Process -Name 'WoW' -ErrorAction SilentlyContinue) {
                if (Test-KeyPressed) { $manual = $true; break }
                Start-Sleep -Seconds 2
            }
            if (-not $manual) {
                Start-Sleep -Seconds 5
                Write-Host '  WoW closed -- shutting down...' -ForegroundColor Yellow
            }
        } else {
            Write-Host '  WoW not detected -- press ENTER to shut down.' -ForegroundColor Gray
            Read-Host | Out-Null
        }
    }
}

if ($manual) { Write-Host '  Manual shutdown -- shutting down...' -ForegroundColor Yellow }

Stop-Server
Write-Host ''
Write-Host ' --------------------------------------------------' -ForegroundColor DarkYellow
Write-Host '  Server stopped! Safe to close.' -ForegroundColor Green
Write-Host '  Thanks for playing! youtube.com/@DadsMmoLab' -ForegroundColor Gray
Write-Host ' --------------------------------------------------' -ForegroundColor DarkYellow
Write-Host ''
Start-Sleep -Seconds 5
'@

function New-Launcher {
    Write-Step 'Setting up desktop launcher'

    $launcher = $LauncherTemplate.
        Replace('__SERVER_DIR__', $ServerDir.Replace("'", "''")).
        Replace('__CLIENT_DIR__', $Script:ClientDir.Replace("'", "''"))
    Write-WinFile $LauncherPath $launcher
    Write-Ok "Launcher created: $LauncherPath"

    $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $Script:ShortcutPath = ''
    try {
        $desktop = [Environment]::GetFolderPath('Desktop')
        $lnkPath = Join-Path $desktop 'Vanilla WoW Server.lnk'
        $shell = New-Object -ComObject WScript.Shell
        $lnk = $shell.CreateShortcut($lnkPath)
        $lnk.TargetPath = $psExe
        $lnk.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$LauncherPath`""
        $lnk.WorkingDirectory = $ServerDir
        $wowExe = Join-Path $Script:ClientDir 'WoW.exe'
        if (Test-Path -LiteralPath $wowExe) { $lnk.IconLocation = "$wowExe,0" }
        $lnk.Description = 'Dad''s MMO Lab -- start the Vanilla WoW server and play'
        $lnk.Save()
        $Script:ShortcutPath = $lnkPath
        Write-Ok 'Desktop shortcut created: "Vanilla WoW Server"'
    } catch {
        Write-Warn "Could not create desktop shortcut: $($_.Exception.Message)"
    }

    $info = @"
====================================
  Dad's MMO Lab -- Vanilla WoW
  CMaNGOS Classic + Playerbots
  (source compile, Docker Desktop)
====================================

SERVER:
  Folder:    $ServerDir
  Map data:  Docker volume '$DataVolume'
  Realmlist: 127.0.0.1
  World:     127.0.0.1:8085
  Login:     127.0.0.1:3724
  Account:   player / player

LAUNCHER:
  Desktop shortcut "Vanilla WoW Server"
  (or: powershell -ExecutionPolicy Bypass -File "$LauncherPath")
  Starts Docker Desktop + server, launches WoW,
  shuts the server down when WoW closes.

REALMLIST (in your Vanilla client folder):
  File:    realmlist.wtf
  Content: set realmlist 127.0.0.1
  Lock it: right-click -> Properties -> Read-only

USEFUL COMMANDS (PowerShell):
  Start:   docker compose -f "$ComposeFile" up -d
  Stop:    docker compose -f "$ComposeFile" down
  Logs:    docker compose -f "$ComposeFile" logs -f
  Status:  docker ps --filter name=vanilla
  Console: docker attach vanilla-mangosd
    (Exit safely: Ctrl+P then Ctrl+Q. NOT Ctrl+C.)

CREATE MORE ACCOUNTS:
  docker attach vanilla-mangosd
  account create USERNAME PASSWORD
  account set gmlevel USERNAME 3 -1   (optional: makes account GM)
  [Ctrl+P then Ctrl+Q to exit safely]

CONFIG FILES (edit, then restart the server):
  $EtcDir\mangosd.conf
  $EtcDir\aiplayerbot.conf
  $EtcDir\ahbot.conf
"@
    Write-WinFile (Join-Path $ServerDir 'MY_SERVER.txt') $info
    Write-Ok "MY_SERVER.txt saved to $ServerDir"
}

# =============================================================================
# COMPLETION
# =============================================================================
function Set-Realmlist {
    # Some repacks put realmlist at top level; standard installs inside
    # Data\<locale>\. Write wherever it lives, else at top level.
    $path = Join-Path $Script:ClientDir 'realmlist.wtf'
    foreach ($loc in 'enUS', 'enGB', 'deDE', 'frFR', 'esES') {
        $p = Join-Path $Script:ClientDir "Data\$loc\realmlist.wtf"
        if (Test-Path -LiteralPath $p) { $path = $p; break }
    }
    try {
        if (Test-Path -LiteralPath $path) {
            $item = Get-Item -LiteralPath $path -Force
            $item.Attributes = $item.Attributes -band (-bnot [System.IO.FileAttributes]::ReadOnly)
        }
        [System.IO.File]::WriteAllText($path, "set realmlist 127.0.0.1`r`n", (New-Object System.Text.ASCIIEncoding))
        # Lock it so the client can't overwrite it (chmod 444 equivalent)
        $item = Get-Item -LiteralPath $path -Force
        $item.Attributes = $item.Attributes -bor [System.IO.FileAttributes]::ReadOnly
        return @($true, $path)
    } catch {
        return @($false, $path)
    }
}

function Show-Completion {
    Write-Header
    $rl = Set-Realmlist
    $realmlistWritten = $rl[0]; $realmlistPath = $rl[1]

    Write-Host ''
    Write-Host '  +==================================================+' -ForegroundColor Yellow
    Write-Host '  |           VANILLA WOW INSTALLED!                 |' -ForegroundColor Yellow
    Write-Host '  +==================================================+' -ForegroundColor Yellow
    Write-Host ''
    Write-Host 'You compiled CMaNGOS Classic from source on your own PC.' -ForegroundColor White
    Write-Host 'That''s real engineering work. Welcome to the club.' -ForegroundColor White
    Write-Host ''
    Write-Host '  --------------------------------------------------' -ForegroundColor Yellow
    Write-Host "  Expansion:  Vanilla (1.12.1)"
    Write-Host "  Server dir: $ServerDir"
    Write-Host "  Launcher:   Desktop shortcut 'Vanilla WoW Server'"
    Write-Host '  Bots:       Playerbots + AHBot active' -ForegroundColor Green
    Write-Host '  Account:    player / player (create in step A below)' -ForegroundColor Yellow
    if ($realmlistWritten) {
        Write-Host '  Realmlist:  auto-configured (locked to 127.0.0.1)' -ForegroundColor Green
    } else {
        Write-Host '  Realmlist:  NOT auto-written -- see step B below' -ForegroundColor Yellow
    }
    Write-Host '  --------------------------------------------------' -ForegroundColor Yellow
    Write-Host ''
    Write-Host 'NEXT STEPS -- finish setup (~5 min):' -ForegroundColor Yellow
    Write-Host ''

    Write-Host 'A. Create your player account (REQUIRED -- 30 seconds):' -ForegroundColor Green
    Write-Host ''
    Write-Host '   In PowerShell run:'
    Write-Host '      docker attach vanilla-mangosd' -ForegroundColor DarkYellow
    Write-Host ''
    Write-Host '   You''ll see a blinking cursor (the mangosd console; press Enter once'
    Write-Host '   if it looks empty). Type each of these and press Enter:'
    Write-Host '      account create player player' -ForegroundColor DarkYellow
    Write-Host '      account set gmlevel player 3 -1' -ForegroundColor DarkYellow
    Write-Host ''
    Write-Host '   To exit safely, press Ctrl+P then Ctrl+Q (sequential).'
    Write-Host '   NEVER press Ctrl+C -- that kills the server!' -ForegroundColor Red
    Write-Host ''

    if (-not $realmlistWritten) {
        Write-Host 'B. Set up realmlist (auto-write failed):' -ForegroundColor White
        Write-Host "   Edit $realmlistPath"
        Write-Host '   Contents: set realmlist 127.0.0.1'
        Write-Host '   Lock it:  right-click -> Properties -> Read-only'
        Write-Host ''
    }

    Write-Host 'C. Play:' -ForegroundColor White
    Write-Host '   1. Double-click "Vanilla WoW Server" on your desktop'
    Write-Host '   2. Wait for AZEROTH IS READY! -- WoW starts automatically'
    Write-Host '   3. Login: player / player'
    Write-Host '   4. Bots populate the world within 5-10 min -- be patient!'
    Write-Host '   5. Close WoW and the server shuts itself down'
    Write-Host ''
    Write-Host '   NOTE: the server is running right now (from this install).' -ForegroundColor Gray
    Write-Host "   Stop it with: docker compose -f `"$ComposeFile`" down" -ForegroundColor Gray
    Write-Host ''
    Write-Host "Server info: $ServerDir\MY_SERVER.txt" -ForegroundColor Cyan
    Write-Host "Build log:   $BuildLog" -ForegroundColor Cyan
    Write-Host "Install log: $($Script:InstallLog)" -ForegroundColor Cyan
    Write-Host ''

    if (Read-YesNo 'Open the mangosd console in a new window now to create the account?') {
        $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $cmd = "Write-Host 'mangosd console -- type: account create player player' -ForegroundColor Yellow; " +
               "Write-Host 'then: account set gmlevel player 3 -1   |   exit: Ctrl+P then Ctrl+Q (NOT Ctrl+C)' -ForegroundColor Yellow; " +
               'docker attach vanilla-mangosd'
        Start-Process -FilePath $psExe -ArgumentList @('-NoProfile', '-NoExit', '-Command', $cmd) | Out-Null
    }
}

# =============================================================================
# MAIN
# =============================================================================
$Script:InstallLog = Join-Path $env:USERPROFILE ("dads-mmo-lab-install-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
$transcribing = $false
try {
    Start-Transcript -Path $Script:InstallLog -Force | Out-Null
    $transcribing = $true
} catch {
    Write-Warn "Could not create log file at $($Script:InstallLog) -- continuing without logging."
}

try {
    Test-System
    Show-Welcome
    if ($transcribing) {
        Write-Host "Logging this session to: $($Script:InstallLog)" -ForegroundColor DarkGray
        Write-Host '   Upload this file if you need help at: github.com/DadsMmoLab/dads-mmo-lab/issues' -ForegroundColor DarkGray
    }
    Find-Client
    Show-Summary
    Test-Preflight
    Invoke-Compile
    Invoke-Extraction
    Write-ComposeAndConfigs
    Initialize-Database
    Start-Server
    Show-AccountStep
    New-Launcher
    Show-Completion
} finally {
    if ($transcribing) { try { Stop-Transcript | Out-Null } catch { } }
    Write-Host ''
    Read-Host 'Press ENTER to close' | Out-Null
}
