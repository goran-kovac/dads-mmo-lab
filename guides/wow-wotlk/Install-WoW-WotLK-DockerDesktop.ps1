#Requires -Version 5.1
<#
.SYNOPSIS
    Dad's MMO Lab -- WoW Playerbots Installer for Windows (Docker Desktop)
.DESCRIPTION
    Installs AzerothCore WotLK + mod-playerbots on Windows using Docker Desktop.
    This is the Docker Desktop alternative to Install-WoW-WotLK.ps1, which
    needs the DML substrate (dml-arch + its own Docker Engine) instead.
    Install-DML.ps1 is NOT required for this script.

    Version: 1.0.1

    What this does:
      1. Verifies Docker Desktop (Linux containers), Git, disk space, ports
      2. Shows a summary before building
      3. Clones AzerothCore WotLK (Playerbot branch) + mod-playerbots
      4. Compiles the server images with Docker Desktop (~2-4 hours)
      5. Imports the databases, initializes acore_playerbots, starts the server
      6. Creates playerbot.conf and guides you through account creation
      7. Writes Start/Stop/Console shortcuts into the install folder

    Changelog:
      1.0.1 - Fix: ready detection searched only the last 50 log lines, which the
              playerbots stats output fills within seconds; the whole log since
              the current container start is searched now.
      1.0.0 - Initial Docker Desktop release
        - Mirrors the build/startup flow of Install-WoW-WotLK.ps1 v1.3.1
        - Runs docker / git natively from PowerShell (no WSL distro needed)
        - Clones with core.autocrlf=false so container scripts keep LF endings
        - Database port bound to 127.0.0.1 only (not exposed to the LAN)

.PARAMETER InstallDir
    Windows folder for the server source and config.
    Default: C:\DML\games\wow-server-playerbots
.PARAMETER MinBots
    Minimum number of random bots (default 200).
.PARAMETER MaxBots
    Maximum number of random bots (default 250).
.EXAMPLE
    Set-ExecutionPolicy Bypass -Scope Process -Force
    & "C:\DML\Install-WoW-WotLK-DockerDesktop.ps1"
.EXAMPLE
    & .\Install-WoW-WotLK-DockerDesktop.ps1 -InstallDir 'D:\Games\wow-playerbots' -MaxBots 100 -MinBots 50
#>

[CmdletBinding()]
param(
    [string]$InstallDir = "$env:SystemDrive\DML\games\wow-server-playerbots",
    [ValidateRange(0, 5000)][int]$MinBots = 200,
    [ValidateRange(0, 5000)][int]$MaxBots = 250
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# =============================================================================
# Config
# =============================================================================
$WizardVersion       = '1.0.1'
$CoreRepo            = 'https://github.com/mod-playerbots/azerothcore-wotlk.git'
$CoreBranch          = 'Playerbot'
$ModuleRepo          = 'https://github.com/mod-playerbots/mod-playerbots.git'
$ModuleBranch        = 'master'
$DbRootPassword      = 'password'   # upstream default; DB port is bound to 127.0.0.1 only
$LogFile             = "$env:TEMP\dml-wow-dockerdesktop-install.log"
$BuildLog            = "$env:TEMP\dml-wow-dockerdesktop-build.log"
$DockerDesktopExe    = "$env:ProgramFiles\Docker\Docker\Docker Desktop.exe"
$Script:FailReported = $false

if ($MinBots -gt $MaxBots) { throw "-MinBots ($MinBots) must not be greater than -MaxBots ($MaxBots)." }
$InstallDir = [System.IO.Path]::GetFullPath($InstallDir)
$ComposeFile = Join-Path $InstallDir 'docker-compose.yml'

# =============================================================================
# Output helpers
# =============================================================================
function Write-Header {
    Clear-Host
    Write-Host ''
    Write-Host '  +==================================================+' -ForegroundColor Cyan
    Write-Host '  |  DAD''S MMO LAB                                   |' -ForegroundColor White
    Write-Host '  |  WoW Playerbots Installer (Docker Desktop)       |' -ForegroundColor White
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
# docker and git write normal progress to stderr. With EAP=Stop and 2>&1,
# PS 5.1 turns those lines into terminating errors, so every native call
# runs with EAP lowered to Continue and stderr records converted to text.
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
# Only for short checks -- not for long-running streaming operations.
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

function Invoke-Compose {
    param([string[]]$Arguments, [string]$TeeFile, [switch]$Quiet)
    $all = @('compose', '--project-directory', $InstallDir, '-f', $ComposeFile, '-f', (Join-Path $InstallDir 'docker-compose.override.yml')) + $Arguments
    return (Invoke-Native -Exe 'docker' -Arguments $all -TeeFile $TeeFile -Quiet:$Quiet)
}

function Write-Utf8NoBom([string]$Path, [string]$Content) {
    [System.IO.File]::WriteAllBytes($Path, [System.Text.UTF8Encoding]::new($false).GetBytes($Content.Replace("`r`n", "`n")))
}

function Update-SessionPath {
    $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $user    = [Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path = "$machine;$user"
    foreach ($extra in @("$env:ProgramFiles\Docker\Docker\resources\bin", "$env:ProgramFiles\Git\cmd")) {
        if ((Test-Path $extra) -and ($env:Path -notlike "*$extra*")) { $env:Path = "$env:Path;$extra" }
    }
}

function Test-Command([string]$name) {
    return [bool](Get-Command $name -ErrorAction SilentlyContinue)
}

# Returns Status ('running', 'exited', ... or '' if the container does not
# exist), Health ('healthy', 'starting', ... or '') and ExitCode.
function Get-ContainerState([string]$name) {
    $raw = Invoke-Capture 'docker' @('inspect', $name, '--format', '{{.State.Status}}|{{if .State.Health}}{{.State.Health.Status}}{{end}}|{{.State.ExitCode}}')
    $parts = @($raw -split '\|') + @('', '', '')
    return [pscustomobject]@{ Status = $parts[0]; Health = $parts[1]; ExitCode = $parts[2] }
}

function Get-FreeGB([string]$path) {
    try {
        $root = [System.IO.Path]::GetPathRoot($path)
        $drive = New-Object System.IO.DriveInfo($root)
        return [math]::Floor($drive.AvailableFreeSpace / 1GB)
    } catch {
        return -1
    }
}

# =============================================================================
# Step 0 -- Prerequisites
# =============================================================================
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

function Assert-DockerDesktop {
    Update-SessionPath

    if (-not (Test-Command 'docker')) {
        Write-Warn 'Docker Desktop is not installed (docker command not found).'
        if ((Test-Command 'winget') -and (Invoke-YesNo 'Install Docker Desktop now with winget? (needs admin rights + a restart afterwards)')) {
            $exit = Invoke-Native -Exe 'winget' -Arguments @('install', '-e', '--id', 'Docker.DockerDesktop', '--accept-source-agreements', '--accept-package-agreements')
            if ($exit -eq 0) {
                Write-Host ''
                Write-Ok 'Docker Desktop installed.'
                Write-Info 'Please RESTART your PC, open Docker Desktop once (accept the terms),'
                Write-Info 'wait until it says "Engine running", then run this installer again.'
                exit 0
            }
        }
        Write-Fail "Install Docker Desktop from https://www.docker.com/products/docker-desktop/ (use the WSL 2 backend), then re-run this installer."
    }
    Write-Ok 'Docker CLI found'

    # Engine running? If not, start Docker Desktop and wait up to 3 minutes.
    $null = Invoke-Capture 'docker' @('info', '--format', '{{.ServerVersion}}')
    if ($Script:LastCaptureExit -ne 0) {
        if (-not (Test-Path $DockerDesktopExe)) {
            Write-Fail "Docker engine is not running and Docker Desktop was not found at:`n  $DockerDesktopExe`nStart Docker Desktop manually and re-run this installer."
        }
        Write-Info 'Docker Desktop is not running -- starting it...'
        Start-Process -FilePath $DockerDesktopExe | Out-Null
        $deadline = (Get-Date).AddMinutes(3)
        do {
            Start-Sleep -Seconds 5
            $null = Invoke-Capture 'docker' @('info', '--format', '{{.ServerVersion}}')
            if ($Script:LastCaptureExit -eq 0) { break }
            Write-Host '.' -NoNewline -ForegroundColor DarkGray
        } while ((Get-Date) -lt $deadline)
        Write-Host ''
        if ($Script:LastCaptureExit -ne 0) {
            Write-Fail "Docker Desktop did not start within 3 minutes.`nOpen Docker Desktop, wait for 'Engine running', then re-run this installer."
        }
    }
    Write-Ok 'Docker engine running'

    # Linux containers (not Windows containers)
    $osType = Invoke-Capture 'docker' @('info', '--format', '{{.OSType}}')
    if ($osType -ne 'linux') {
        Write-Fail "Docker Desktop is in Windows-containers mode.`nRight-click the whale icon in the tray -> 'Switch to Linux containers...', then re-run."
    }
    Write-Ok 'Linux containers mode'

    # Compose v2
    $composeVer = Invoke-Capture 'docker' @('compose', 'version', '--short')
    if ($Script:LastCaptureExit -ne 0 -or -not $composeVer) {
        Write-Fail 'docker compose (v2) is not available. Update Docker Desktop and re-run.'
    }
    Write-Ok "Docker Compose $composeVer"

    # Memory available to Docker Desktop's VM -- the C++ build runs nproc+1 jobs
    $memStr = Invoke-Capture 'docker' @('info', '--format', '{{.MemTotal}}')
    if ($memStr -match '^\d+$') {
        $memGB = [math]::Round([double]$memStr / 1GB, 1)
        if ($memGB -lt 6) {
            Write-Warn "Docker Desktop only has ${memGB} GB RAM. Compiling may fail with 'killed' / out-of-memory."
            Write-Info 'Give WSL more memory in %UserProfile%\.wslconfig, e.g.:'
            Write-Info '  [wsl2]'
            Write-Info '  memory=12GB'
            Write-Info 'then run "wsl --shutdown", restart Docker Desktop and re-run this installer.'
            if (-not (Invoke-YesNo 'Continue anyway?')) { exit 0 }
        } else {
            Write-Ok "Docker Desktop memory: ${memGB} GB"
        }
    }
}

function Assert-Prerequisites {
    Write-Step 'Checking Prerequisites'

    Assert-DockerDesktop
    Assert-Git

    # Disk space: Docker Desktop stores images/volumes on the drive of
    # %LOCALAPPDATA% by default (~30 GB for build cache + images), the source
    # checkout lives in InstallDir (~3 GB).
    $dockerDrive  = [System.IO.Path]::GetPathRoot($env:LOCALAPPDATA)
    $installDrive = [System.IO.Path]::GetPathRoot($InstallDir)
    $needDocker   = 30
    $needInstall  = 3
    if ($dockerDrive -eq $installDrive) {
        $free = Get-FreeGB $InstallDir
        $need = $needDocker + $needInstall
        if ($free -ge 0 -and $free -lt $need) { Write-Fail "Not enough space on ${installDrive}: ${free} GB free, need at least ${need} GB." }
        if ($free -ge 0) { Write-Ok "Disk space OK (${free} GB free on $installDrive)" }
    } else {
        $freeD = Get-FreeGB $env:LOCALAPPDATA
        $freeI = Get-FreeGB $InstallDir
        if ($freeD -ge 0 -and $freeD -lt $needDocker) {
            Write-Warn "Only ${freeD} GB free on $dockerDrive (Docker Desktop's default data drive). The build needs ~${needDocker} GB."
            Write-Info 'If you moved Docker Desktop''s disk image (Settings -> Resources -> Advanced), you can ignore this.'
            if (-not (Invoke-YesNo 'Continue anyway?')) { exit 0 }
        }
        if ($freeI -ge 0 -and $freeI -lt $needInstall) { Write-Fail "Not enough space on ${installDrive}: ${freeI} GB free, need at least ${needInstall} GB." }
        Write-Ok "Disk space OK ($dockerDrive ${freeD} GB, $installDrive ${freeI} GB)"
    }

    # Ports -- something else (another WoW server, e.g. the dml-arch one) must not hold them
    $ourContainers = Invoke-Capture 'docker' @('ps', '--format', '{{.Names}}')
    foreach ($port in 3724, 8085) {
        $listener = Get-NetTCPConnection -State Listen -LocalPort $port -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($listener -and ($ourContainers -notmatch 'ac-(auth|world)server')) {
            $proc = (Get-Process -Id $listener.OwningProcess -ErrorAction SilentlyContinue).ProcessName
            Write-Warn "Port $port is already in use (process: $proc)."
            Write-Info 'Another WoW server may be running (e.g. the DML/WSL one). Stop it first.'
            if (-not (Invoke-YesNo 'Continue anyway?')) { exit 0 }
        }
    }

    # Internet
    try {
        $null = Invoke-WebRequest -Uri 'https://github.com' -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop
        Write-Ok 'Internet connection OK'
    } catch {
        Write-Fail 'No internet connection detected. Connect and try again.'
    }
}

# =============================================================================
# Step 1 -- Summary
# =============================================================================
function Show-Summary {
    Write-Header
    Write-Step 'STEP 1/3 -- What We''re Building'
    Write-Host ''
    Write-Host '  Server:    WoW Playerbots (AzerothCore WotLK + Playerbots)' -ForegroundColor Cyan
    Write-Host "  Location:  $InstallDir" -ForegroundColor Cyan
    Write-Host '  Docker:    Docker Desktop' -ForegroundColor Cyan
    Write-Host "  Bots:      $MinBots - $MaxBots random bots" -ForegroundColor Cyan
    Write-Host '  Install:   Compile from source (2-4 hours)' -ForegroundColor Yellow
    Write-Host ''
    Write-Host '  What you get:' -ForegroundColor White
    Write-Host '    + Hundreds of AI players roaming the world' -ForegroundColor Green
    Write-Host '    + Bots quest, dungeon, raid alongside you' -ForegroundColor Green
    Write-Host '    + Azeroth feels truly alive -- solo or co-op' -ForegroundColor Green
    Write-Host ''
    Write-Host '  COMPILATION WARNING:' -ForegroundColor Yellow
    Write-Host '  This will take 2-4 hours. Keep your PC running and plugged in,' -ForegroundColor White
    Write-Host '  and do not quit Docker Desktop while it builds.' -ForegroundColor White
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
    return ((Test-Path $ComposeFile) -and
            (Test-Path (Join-Path $InstallDir 'apps\docker\Dockerfile')) -and
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
            $null = Invoke-Compose -Arguments @('down', '-v') -Quiet
            Remove-Item -Recurse -Force -Path $InstallDir
        }
    }
    $parent = Split-Path -Parent $InstallDir
    if (-not (Test-Path $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }

    # core.autocrlf=false: Windows Git defaults to CRLF checkouts, which breaks
    # the shell scripts copied into the Linux containers. core.longpaths=true:
    # some paths in the source tree exceed MAX_PATH.
    $gitCfg = @('-c', 'core.autocrlf=false', '-c', 'core.longpaths=true')

    Write-Info 'Cloning AzerothCore WotLK (Playerbot branch)...'
    $exit = Invoke-Native -Exe 'git' -Arguments ($gitCfg + @('clone', '--depth', '1', '--branch', $CoreBranch, $CoreRepo, $InstallDir))
    if ($exit -ne 0 -or -not (Test-Path $ComposeFile)) { Write-Fail "Clone failed (exit $exit). Check your internet connection." }
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
# Compose configuration
# =============================================================================
function Write-ComposeConfig {
    # restart: on-failure replaces upstream's unless-stopped so the servers still
    # recover from crashes, but do NOT auto-boot every time Docker Desktop starts.
    # The health check override replaces upstream's mysql query with a plain TCP
    # probe and a much longer budget for slow first-run MySQL initialization.
    $override = @"
services:
  ac-worldserver:
    restart: on-failure
    volumes:
      - ./modules:/azerothcore/modules
    environment:
      AC_PLAYERBOTS_UPDATES_ENABLE_DATABASES: "1"
      AC_AI_PLAYERBOT_RANDOM_BOT_AUTOLOGIN: "1"
      AC_AI_PLAYERBOT_MIN_RANDOM_BOTS: "$MinBots"
      AC_AI_PLAYERBOT_MAX_RANDOM_BOTS: "$MaxBots"
      AC_PLAYERBOTS_DATABASE_WORKER_THREADS: "1"
      AC_PLAYERBOTS_DATABASE_SYNCH_THREADS: "1"
  ac-authserver:
    restart: on-failure
  ac-database:
    restart: on-failure
    healthcheck:
      test: ["CMD-SHELL", "bash -c 'echo > /dev/tcp/127.0.0.1/3306' 2>/dev/null && echo ok || exit 1"]
      interval: 5s
      timeout: 5s
      retries: 180
      start_period: 60s
"@
    Write-Utf8NoBom (Join-Path $InstallDir 'docker-compose.override.yml') $override
    Write-Ok 'docker-compose.override.yml written'

    # .env -- bind the database port to localhost only. Upstream publishes 3306
    # on all interfaces with root/password; that must not be reachable from the
    # LAN. Existing keys in .env are kept.
    $envFile = Join-Path $InstallDir '.env'
    $existing = if (Test-Path $envFile) { [System.IO.File]::ReadAllText($envFile) } else { '' }
    $add = @()
    if ($existing -notmatch '(?m)^\s*DOCKER_DB_EXTERNAL_PORT\s*=') { $add += 'DOCKER_DB_EXTERNAL_PORT=127.0.0.1:3306' }
    if ($existing -notmatch '(?m)^\s*COMPOSE_PROJECT_NAME\s*=')    { $add += 'COMPOSE_PROJECT_NAME=wow-server-playerbots' }
    if ($add.Count -gt 0) {
        $content = $existing
        if ($content -and -not $content.EndsWith("`n")) { $content += "`n" }
        $content += ($add -join "`n") + "`n"
        Write-Utf8NoBom $envFile $content
        Write-Ok '.env written (database bound to 127.0.0.1)'
    }
}

# =============================================================================
# Build + start
# =============================================================================
function Test-ImagesBuilt {
    $repos = Invoke-Capture 'docker' @('images', '--format', '{{.Repository}}')
    return (($repos -match 'ac-wotlk-worldserver') -and ($repos -match 'ac-wotlk-authserver') -and
            ($repos -match 'ac-wotlk-db-import') -and ($repos -match 'ac-wotlk-client-data'))
}

function Build-Images {
    if (Test-ImagesBuilt) {
        Write-Ok 'Compiled images already found -- skipping compile.'
        Write-Info 'To force a fresh compile run:'
        Write-Info "  cd `"$InstallDir`"; docker compose build --no-cache"
        return
    }
    Write-Info 'Compiling Playerbots server (2-4 hours)...'
    Write-Info 'Keep your PC running and plugged in.'
    Write-Info 'Go make a coffee -- this will take a while!'
    Remove-Item -Path $BuildLog -ErrorAction SilentlyContinue
    $env:BUILDKIT_PROGRESS = 'plain'
    $exit = Invoke-Compose -Arguments @('build', 'ac-worldserver', 'ac-authserver', 'ac-db-import', 'ac-client-data-init') -TeeFile $BuildLog
    if ($exit -ne 0) {
        if (Select-String -Path $BuildLog -Pattern 'Killed|out of memory|signal 9' -Quiet -ErrorAction SilentlyContinue) {
            Write-Warn 'The compiler ran out of memory. Give WSL more RAM in %UserProfile%\.wslconfig (memory=12GB), run "wsl --shutdown", restart Docker Desktop and re-run.'
        }
        Write-Fail "Compilation failed (exit $exit).`nCheck the build log: $BuildLog"
    }
    Write-Ok 'Images compiled'
}

# Start the database and poll its health ourselves. compose's dependency wait
# aborts permanently the moment Docker marks the container unhealthy, but
# MySQL's first-run initialization can outlast any fixed healthcheck budget.
function Start-DatabaseAndWait {
    $exit = Invoke-Compose -Arguments @('up', '-d', '--no-deps', 'ac-database', 'ac-client-data-init')
    if ($exit -ne 0) { Write-Warn 'docker compose failed to start the database container.'; return $false }

    $t0 = Get-Date
    $lastReport = -1
    while ($true) {
        $health = (Get-ContainerState 'ac-database').Health
        $elapsed = [int]((Get-Date) - $t0).TotalSeconds
        if ($health -eq 'healthy') { Write-Ok "Database is up (took ${elapsed}s)."; return $true }
        if ($elapsed -ge 3600) { Write-Warn 'Database did not come up within 60 minutes -- giving up.'; return $false }
        $bucket = [math]::Floor($elapsed / 30)
        if ($bucket -ne $lastReport) {
            Write-Info "Database still starting... (${elapsed}s elapsed, health: $health)"
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

# Run ac-db-import and wait for it to exit; returns $true on exit code 0.
function Invoke-DbImport {
    $exit = Invoke-Compose -Arguments @('up', '-d', '--no-deps', 'ac-db-import')
    if ($exit -ne 0) { return $false }
    return (Wait-ContainerExit 'ac-db-import' 120 'Importing world databases')
}

function Invoke-Mysql([string]$sql, [string]$database) {
    $mysqlArgs = @('exec', 'ac-database', 'mysql', '-uroot', "-p$DbRootPassword", '-sN', '-e', $sql)
    if ($database) { $mysqlArgs += $database }
    return (Invoke-Capture 'docker' $mysqlArgs)
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

    # Copy the files into the container and import them there. Piping SQL from
    # PowerShell 5.1 into a native command would re-encode it (non-UTF-8).
    # No double quotes in $importCmd: PS 5.1 does not escape embedded quotes
    # when passing arguments to native commands.
    $null = Invoke-Native -Exe 'docker' -Arguments @('exec', 'ac-database', 'rm', '-rf', '/tmp/pb-base') -Quiet
    $exit = Invoke-Native -Exe 'docker' -Arguments @('cp', $baseDir, 'ac-database:/tmp/pb-base') -Quiet
    if ($exit -ne 0) { Write-Fail 'Could not copy the playerbots SQL files into the database container.' }
    $importCmd = 'for f in /tmp/pb-base/*.sql; do mysql -uroot -p$MYSQL_ROOT_PASSWORD acore_playerbots < $f || { echo failed: $f; exit 1; }; done; rm -rf /tmp/pb-base'
    $exit = Invoke-Native -Exe 'docker' -Arguments @('exec', 'ac-database', 'bash', '-c', $importCmd)
    if ($exit -ne 0) { Write-Fail 'acore_playerbots initialization failed.' }
    Write-Ok 'acore_playerbots initialized.'
}

function Install-Server {
    Write-Header
    Write-Step 'STEP 2/3 -- Building Playerbots Server (2-4 hours)'

    Get-Source
    Write-ComposeConfig
    Build-Images

    Write-Info 'Starting containers...'
    # Clean up bad state from a previous run: unhealthy containers, or a failed db-import
    $dbState = Get-ContainerState 'ac-db-import'
    $importFailed = ($dbState.Status -eq 'exited' -and $dbState.ExitCode -ne '0')
    $unhealthy = (Invoke-Capture 'docker' @('ps', '-a', '--filter', 'health=unhealthy', '--format', '{{.Names}}')) -match '(?m)^ac-'
    if ($importFailed) {
        Write-Warn 'Previous database import failed -- wiping volumes for a clean import...'
        $null = Invoke-Compose -Arguments @('down', '-v')
        Start-Sleep -Seconds 10
    } elseif ($unhealthy) {
        Write-Warn 'Found unhealthy containers from a previous run -- cleaning up...'
        $null = Invoke-Compose -Arguments @('down')
        Start-Sleep -Seconds 5
    }

    # Phase 1: database + world DB import (skipped if a prior import succeeded)
    $dbState = Get-ContainerState 'ac-db-import'
    $importDone = ($dbState.Status -eq 'exited' -and $dbState.ExitCode -eq '0')
    if (-not $importDone) {
        Write-Info 'Starting database (first-run initialization can take a long time on slow disks)...'
        if (-not (Start-DatabaseAndWait)) { Write-Fail 'Database failed to start. Check: docker logs ac-database --tail 50' }
        Write-Info 'Importing world databases (5-10 minutes)...'
        if (-not (Invoke-DbImport)) {
            Write-Warn 'Database import failed -- wiping volumes and retrying once...'
            $null = Invoke-Compose -Arguments @('down', '-v')
            Start-Sleep -Seconds 15
            if (-not (Start-DatabaseAndWait)) { Write-Fail 'Database failed to start. Check: docker logs ac-database --tail 50' }
            if (-not (Invoke-DbImport)) {
                Write-Fail "Database import failed twice.`nCheck: docker logs ac-db-import --tail 50"
            }
        }
        Write-Ok 'Database import complete.'
    } else {
        if (-not (Start-DatabaseAndWait)) { Write-Fail 'Database failed to start. Check: docker logs ac-database --tail 50' }
    }

    # Phase 2: playerbots schema
    Initialize-PlayerbotsDb

    # Phase 3: world + auth server. The worldserver needs the map data that
    # ac-client-data-init downloads (~1.5 GB) -- wait for it to finish first.
    if (-not (Wait-ContainerExit 'ac-client-data-init' 120 'Downloading map data (client-data)')) {
        Write-Fail "Map data download failed.`nCheck: docker logs ac-client-data-init --tail 50"
    }
    Write-Ok 'Map data ready.'

    $exit = Invoke-Compose -Arguments @('up', '-d', '--no-deps', 'ac-worldserver', 'ac-authserver')
    if ($exit -ne 0) {
        Write-Warn 'Worldserver start failed -- retrying...'
        Start-Sleep -Seconds 10
        $exit = Invoke-Compose -Arguments @('up', '-d', '--no-deps', 'ac-worldserver', 'ac-authserver')
        if ($exit -ne 0) { Write-Fail 'Worldserver/authserver failed to start. Check: docker logs ac-worldserver --tail 50' }
    }
    Write-Ok 'Playerbots server started!'
}

# =============================================================================
# Wait for server ready -- polls docker logs for "ready..."
# =============================================================================
function Wait-ForServer {
    param([string]$Message = 'First launch after compilation: 30-60 minutes. Subsequent starts: ~30 seconds.')

    Write-Info 'Waiting for world server to initialize...'
    Write-Info $Message
    Write-Host ''

    $t0 = Get-Date
    $lastReport = -1
    while (((Get-Date) - $t0).TotalMinutes -lt 60) {
        # Search the whole log since the current start: the playerbots stats
        # blocks push 'ready...' out of any short --tail window within seconds,
        # and an older 'ready...' from before a restart must not count.
        $startedAt = Invoke-Capture 'docker' @('inspect', 'ac-worldserver', '--format', '{{.State.StartedAt}}')
        $logArgs = @('logs')
        if ($startedAt -and $startedAt -notmatch '^0001-') { $logArgs += @('--since', $startedAt) }
        $logArgs += 'ac-worldserver'
        $prevEap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        $isReady = [bool](& docker @logArgs 2>&1 | ForEach-Object { "$_" } | Select-String -Pattern 'ready\.\.\.' -Quiet)
        $ErrorActionPreference = $prevEap
        if ($isReady) {
            Write-Host ''
            Write-Ok 'Server is READY!'
            return $true
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
    Write-Info 'Check: docker logs -f ac-worldserver'
    return $false
}

# =============================================================================
# Playerbot config -- copy .dist to .conf, restart worldserver
# =============================================================================
function Set-PlayerbotConfig {
    Write-Step 'Configuring Playerbots'

    $etcDir = Join-Path $InstallDir 'env\dist\etc'
    $dist = Join-Path $etcDir 'modules\playerbots.conf.dist'
    if (-not (Test-Path $dist)) { $dist = Join-Path $etcDir 'playerbot.conf.dist' }

    $found = $false
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        if (Test-Path $dist) { $found = $true; break }
        if ($attempt -lt 3) {
            Write-Info "playerbot config template not yet visible (attempt $attempt/3) -- waiting 10s..."
            Start-Sleep -Seconds 10
        }
    }
    if (-not $found) {
        $hit = Get-ChildItem -Path $etcDir -Recurse -Filter 'playerbot*.conf.dist' -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($hit) {
            $dist = $hit.FullName
        } else {
            Write-Warn 'playerbot config template (.conf.dist) not found -- bots use built-in defaults.'
            Write-Info "Expected under: $etcDir"
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
    $exit = Invoke-Native -Exe 'docker' -Arguments @('restart', 'ac-worldserver') -Quiet
    if ($exit -ne 0) {
        Write-Warn 'Worldserver restart failed -- the config loads on the next server start.'
        Write-Info 'Restart manually: docker restart ac-worldserver'
        return
    }
    $null = Wait-ForServer 'Restarting to load the playerbot config -- usually ready in ~30 seconds.'
}

# =============================================================================
# Shortcuts in the install folder
# =============================================================================
function Write-Shortcuts {
    $compose = 'cd /d "%~dp0" && docker compose'
    $files = @{
        'Start-Server.cmd' = @"
@echo off
echo Starting WoW Playerbots server (Docker Desktop must be running)...
$compose up -d
if errorlevel 1 ( echo. & echo Start failed. Is Docker Desktop running? & pause & exit /b 1 )
echo.
echo Server is starting. The world server needs about 30 seconds (longer on first boot).
echo Watch it with: docker logs -f ac-worldserver
pause
"@
        'Stop-Server.cmd' = @"
@echo off
echo Stopping WoW Playerbots server...
$compose down
pause
"@
        'GM-Console.cmd' = @"
@echo off
echo Attaching to the worldserver console.
echo   Create an account:  account create USERNAME PASSWORD
echo   Make it GM:         account set gmlevel USERNAME 3 -1
echo   Leave the console:  Ctrl+P then Ctrl+Q   (NEVER Ctrl+C -- that stops the server)
echo.
docker attach ac-worldserver
"@
    }
    foreach ($name in $files.Keys) {
        $text = $files[$name].Replace("`r`n", "`n").Replace("`n", "`r`n") + "`r`n"
        [System.IO.File]::WriteAllText((Join-Path $InstallDir $name), $text, [System.Text.Encoding]::ASCII)
    }
    Write-Ok "Shortcuts written: Start-Server.cmd, Stop-Server.cmd, GM-Console.cmd"
}

# =============================================================================
# Step 3 -- Account creation guidance
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
    Write-Host '     docker attach ac-worldserver' -ForegroundColor Cyan
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

# =============================================================================
# Completion
# =============================================================================
function Show-Completion {
    Write-Host ''
    Write-Host '  +==================================================+' -ForegroundColor Green
    Write-Host '  |   YOUR PLAYERBOTS SERVER IS READY!               |' -ForegroundColor Green
    Write-Host '  +==================================================+' -ForegroundColor Green
    Write-Host ''
    Write-Host '  Server:   wow-server-playerbots (AzerothCore WotLK, Docker Desktop)' -ForegroundColor Cyan
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
    Write-Host '  Make sure Docker Desktop is running, then double-click in' -ForegroundColor White
    Write-Host "  $InstallDir :" -ForegroundColor White
    Write-Host '    Start-Server.cmd   -- start the server' -ForegroundColor Green
    Write-Host '    Stop-Server.cmd    -- stop the server' -ForegroundColor Green
    Write-Host '    GM-Console.cmd     -- GM console (accounts, commands)' -ForegroundColor Green
    Write-Host ''
    Write-Host '  You can also start/stop the containers in the Docker Desktop' -ForegroundColor White
    Write-Host '  window (Containers -> wow-server-playerbots).' -ForegroundColor White
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
        Write-Info 'Stopping server...'
        $exit = Invoke-Compose -Arguments @('down')
        if ($exit -eq 0) {
            Write-Ok 'Server stopped. Use Start-Server.cmd to start it next time.'
        } else {
            Write-Warn 'Stop command returned an error -- stop the containers in Docker Desktop instead.'
        }
    } else {
        Write-Info 'Server left running -- enjoy Azeroth!'
    }
    Write-Host ''
}

# =============================================================================
# Main
# =============================================================================
Write-Header

Write-Host '  Welcome to the WoW Playerbots installer for Docker Desktop!' -ForegroundColor White
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

try {
    Write-Log "=== Install-WoW-WotLK-DockerDesktop.ps1 v$WizardVersion -- InstallDir=$InstallDir ==="
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
