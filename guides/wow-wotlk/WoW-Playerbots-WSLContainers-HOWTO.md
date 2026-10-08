# Dad's MMO Lab — WoW Playerbots (Windows + WSL containers): How-To Guide

**Expansion:** World of Warcraft: Wrath of the Lich King (patch 3.3.5a)
**Server:** AzerothCore WotLK + mod-playerbots, compiled from source
**Platform:** Windows 10/11 with WSL **2.9.3 or newer** (built-in `wslc.exe`)
**Installer:** `Install-WoW-WotLK-WSLContainers.ps1` version 1.0.0 or newer

---

## What Is This?

Since September 2026, WSL ships its own container engine: **WSL containers**, driven by the `wslc.exe` command. It runs Linux containers on Windows without Docker Desktop and without installing a Linux distro.

This installer builds the same Playerbots server as the other Windows installers, using only `wslc`.

| You... | Use |
|---|---|
| Have an up-to-date Windows and want **nothing extra installed** | **This guide** — `Install-WoW-WotLK-WSLContainers.ps1` |
| Already use **Docker Desktop** | [WoW-Playerbots-DockerDesktop-HOWTO.md](./WoW-Playerbots-DockerDesktop-HOWTO.md) |
| Want the full DML setup (tray launcher, other games, LAN toggle) | [WoW-Playerbots-Windows-HOWTO.md](./WoW-Playerbots-Windows-HOWTO.md) |

> Don't run two of these servers at the same time — they use the same ports (3724, 8085).

### Good to know (wslc is brand new)

- **No Docker Compose yet.** `wslc` cannot read `docker-compose.yml` today, so this installer starts the five containers itself, in the right order. That is why you start and stop the server with the shortcuts it creates, not with `docker compose`.
- **No automatic restart.** `wslc` has no restart policy. If the world server crashes, it stays off until you run `Start-Server.cmd`. After a PC reboot, start it again the same way.
- **Run it as your normal user.** `wslc` keeps containers started from an *administrator* window separate from your normal ones. The installer refuses to run as administrator so the shortcuts always find your server.

---

## Requirements

| Requirement | Details |
|---|---|
| WSL | Version **2.9.3 or newer** — the installer offers to run `wsl --update` |
| Git for Windows | The installer offers to install it with `winget` if missing |
| Disk space | **~30 GB** on the drive of `%LOCALAPPDATA%` (usually `C:`) + ~3 GB for the source |
| RAM | 16 GB recommended. The container session gets half of your RAM by default |
| Time | 2-4 hours compile (hands-off) + first-boot database setup |
| Internet | Required during install |

Check your WSL version in PowerShell:

```powershell
wsl --version
wslc version
```

---

## Step 1 — Run the Installer

1. Save `Install-WoW-WotLK-WSLContainers.ps1` to `C:\DML\` (or anywhere you like)
2. Press the **Windows key**, type `PowerShell`, open **Windows PowerShell** — **not** as administrator
3. Paste and run:

```powershell
Set-ExecutionPolicy Bypass -Scope Process -Force
& "C:\DML\Install-WoW-WotLK-WSLContainers.ps1"
```

### Options

| Option | Default | What it does |
|---|---|---|
| `-InstallDir` | `C:\DML\games\wow-server-playerbots-wslc` | Where the source, config and logs go |
| `-MinBots` / `-MaxBots` | `200` / `250` | Number of random bots |
| `-Lan` | off | Lets other PCs on your network connect (see [LAN](#play-together--lan)) |

```powershell
& "C:\DML\Install-WoW-WotLK-WSLContainers.ps1" -MinBots 50 -MaxBots 100 -Lan
```

> ⚠️ **Do not click inside the PowerShell window while the installer is working.** Clicking selects text and Windows pauses the output — it looks frozen. Press **Enter** once to unfreeze it.

---

## What Happens During Install

### Preflight checks (~1 min)

| Check | What it's looking for |
|---|---|
| Not administrator | Normal PowerShell window |
| WSL / wslc | WSL 2.9.3+ and a working container session (offers `wsl --update`) |
| Git | Installed (offers `winget install Git.Git`) |
| RAM / disk | Warns below 12 GB RAM; ~30 GB free for wslc storage |
| Ports | 3724 and 8085 not taken by another server |
| Internet | Can reach github.com |

### Compile (2-4 hours)

- Clones [mod-playerbots/azerothcore-wotlk](https://github.com/mod-playerbots/azerothcore-wotlk) (Playerbot branch) and [mod-playerbots/mod-playerbots](https://github.com/mod-playerbots/mod-playerbots)
- Creates the container network `ac-network` and the volumes `ac-database` and `ac-client-data`
- Builds four images with `wslc image build`: worldserver (the long C++ compile), then authserver, db-import and client-data (a few minutes, they reuse the compile)

### First boot (varies — be patient!)

1. **Map data** — `ac-client-data-init` downloads the server map files (~1.5 GB) in the background
2. **Starting database** — `Database still starting...` every 30 s means it is working (waits up to 1 hour)
3. **Importing world databases** — 5-10 minutes (retried once with a clean database if it fails)
4. **Initializing acore_playerbots**, then the world server and auth server start
5. **Waiting for world server** — the first boot applies database updates and can take 30-60 minutes

Then the installer creates the playerbot config, restarts the world server once, and puts the management shortcuts into the install folder.

> **If anything fails:** run the installer again. It reuses the source and the compiled images, so you never compile twice.

---

## Step 2 — Create Your Account (Required)

Double-click `GM-Console.cmd` in the install folder, or run in a new PowerShell window:

```powershell
wslc container attach ac-worldserver
```

Press **Enter** once if you see no prompt. At the `AC>` prompt type:

```
account create player player
account set gmlevel player 3 -1
```

Replace `player` / `player` with your username and password.

Exit safely: **Ctrl+P then Ctrl+Q** — do **not** press Ctrl+C, that stops the server.

---

## Step 3 — Set Your Realmlist

In your WoW 3.3.5a client folder, open `Data\enUS\realmlist.wtf` (or `Data\deDE\realmlist.wtf` for a German client) and make sure it says:

```
set realmlist 127.0.0.1
```

---

## Daily Use

In the install folder (`C:\DML\games\wow-server-playerbots-wslc` by default), double-click:

| Shortcut | What it does |
|---|---|
| `Start-Server.cmd` | Starts database, world server and auth server in the right order |
| `Stop-Server.cmd` | Stops everything safely (characters are saved) |
| `GM-Console.cmd` | Opens the GM console |
| `Status.cmd` | Shows what is running |

The shortcuts call `Manage-WoW-Server.ps1` (a copy of the installer) in the same folder. You can also run it yourself:

```powershell
cd C:\DML\games\wow-server-playerbots-wslc
.\Manage-WoW-Server.ps1 -Action Start     # Start | Stop | Status | Console
```

---

## Useful Commands

```powershell
# What is running?
wslc container list --all

# Live log of the world server (Ctrl+C only stops watching)
wslc container logs --follow ac-worldserver

# Resource usage
wslc stats

# GM console (exit with Ctrl+P then Ctrl+Q)
wslc container attach ac-worldserver
```

---

## Files and Paths

| What | Where |
|---|---|
| Server source + config | `C:\DML\games\wow-server-playerbots-wslc` (or your `-InstallDir`) |
| Server config files | `<InstallDir>\env\dist\etc\` |
| Server logs | `<InstallDir>\env\dist\logs\` |
| Install settings (bots, LAN) | `<InstallDir>\dml-wslc.json` |
| Installer log / build log | `%TEMP%\dml-wow-wslc-install.log` / `%TEMP%\dml-wow-wslc-build.log` |
| Images, database, map data | wslc session storage (`%LOCALAPPDATA%\wslc\sessions\...`) |

---

## Bot Settings

Run the installer again with new values — it skips the compile and recreates the containers:

```powershell
& "C:\DML\Install-WoW-WotLK-WSLContainers.ps1" -MinBots 50 -MaxBots 100
```

Fewer bots = less CPU and RAM. Fine-tuning goes in `<InstallDir>\env\dist\etc\modules\playerbots.conf` (restart the server afterwards).

---

## Optional — Give the Container Session More Memory

If the compile fails with `Killed` / out of memory, open the wslc settings:

```powershell
wslc settings
```

Set `memorySize` under `session` (for example `memorySize: 12GB`), save, run `wsl --shutdown`, and run the installer again. Details: [aka.ms/wslc-settings](https://aka.ms/wslc-settings).

---

## Play Together — LAN

By default the server is only reachable from your own PC. Install with `-Lan` to publish the auth (3724) and world (8085) ports on your network. You also need the Windows firewall rules and the realmlist change from [WoW-Wotlk-NETWORKING.md](./WoW-Wotlk-NETWORKING.md). The database (3306) always stays local.

---

## Troubleshooting

### "Please run this script in a NORMAL (non-administrator) PowerShell window"
Close the window and open PowerShell without "Run as administrator".

### "WSL containers need WSL 2.9.3 or newer"
Run `wsl --update` (or `wsl --install` if WSL is missing), restart your PC, run the installer again.

### "wslc could not start its session"
Run `wsl --shutdown`, wait 10 seconds, run the installer again. Check `wslc version`.

### Compile failed
Look at the end of the build log: `notepad $env:TEMP\dml-wow-wslc-build.log`
- `Killed` / `signal 9` → [give the session more memory](#optional--give-the-container-session-more-memory)
- `no space left on device` → free disk space; `wslc image prune` removes unused images
- Network errors → check your internet and re-run

### World server stopped / "ready..." never appears
`wslc container logs --tail 100 ac-worldserver` shows why. Then run `Start-Server.cmd` — or re-run the installer, which repairs a failed database import automatically.

### Port 3724 / 8085 / 3306 already in use
Another WoW server (DML/WSL or Docker Desktop) or a local MySQL is running. Stop it and try again.

### Force a fresh compile
```powershell
wslc image rm acore/ac-wotlk-worldserver:master acore/ac-wotlk-authserver:master acore/ac-wotlk-db-import:master acore/ac-wotlk-client-data:master
```
Then run the installer again.

### Remove everything
```powershell
cd C:\DML\games\wow-server-playerbots-wslc
.\Manage-WoW-Server.ps1 -Action Stop
wslc container rm --force ac-worldserver ac-authserver ac-db-import ac-client-data-init ac-database
wslc volume rm ac-database ac-client-data
wslc network rm ac-network
wslc image rm acore/ac-wotlk-worldserver:master acore/ac-wotlk-authserver:master acore/ac-wotlk-db-import:master acore/ac-wotlk-client-data:master
cd \
Remove-Item -Recurse -Force C:\DML\games\wow-server-playerbots-wslc
```
This deletes the server, all characters, and the compiled images.

---

## Credits

- [AzerothCore](https://www.azerothcore.org/) — the open-source WotLK server core
- [mod-playerbots](https://github.com/mod-playerbots/mod-playerbots) — the AI player module
- [WSL containers](https://learn.microsoft.com/windows/wsl/wsl-container) — Microsoft's built-in container engine for WSL
