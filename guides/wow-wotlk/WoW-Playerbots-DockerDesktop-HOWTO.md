# Dad's MMO Lab — WoW Playerbots (Windows + Docker Desktop): How-To Guide

**Expansion:** World of Warcraft: Wrath of the Lich King (patch 3.3.5a)
**Server:** AzerothCore WotLK + mod-playerbots, compiled from source
**Platform:** Windows 10/11 with [Docker Desktop](https://www.docker.com/products/docker-desktop/)
**Installer:** `Install-WoW-WotLK-DockerDesktop.ps1` version 1.0.0 or newer

---

## Which Windows Installer Should I Use?

| You... | Use |
|---|---|
| Already use **Docker Desktop**, or just want the WoW server | **This guide** — `Install-WoW-WotLK-DockerDesktop.ps1` |
| Want the full DML setup (tray launcher, other games, LAN toggle) | [WoW-Playerbots-Windows-HOWTO.md](./WoW-Playerbots-Windows-HOWTO.md) — needs `Install-DML.ps1` first |

Both build the same server. This installer does **not** need `Install-DML.ps1`, and the server does **not** show up in the DML Launcher tray — you start and stop it with shortcuts in the install folder or from the Docker Desktop window.

> Don't run both servers at the same time — they use the same ports (3724, 8085).

---

## Requirements

| Requirement | Details |
|---|---|
| Docker Desktop | Installed, **WSL 2 backend**, **Linux containers** mode, "Engine running" |
| Git for Windows | The installer offers to install it with `winget` if missing |
| Disk space | **~30 GB** on the drive Docker Desktop stores its data (usually `C:`) + ~3 GB for the source |
| RAM | 16 GB recommended. Docker Desktop should get at least 6 GB (see [Make It Faster](#optional--give-docker-more-memory)) |
| Time | 2-4 hours compile (hands-off) + first-boot database setup |
| Internet | Required during install |

> **No Docker Desktop yet?** The installer can install it for you with `winget` (needs admin rights). After that, restart your PC, open Docker Desktop once, accept the terms, wait for **Engine running**, then run the installer again.

---

## Step 1 — Run the Installer

1. Save `Install-WoW-WotLK-DockerDesktop.ps1` to `C:\DML\` (or anywhere you like)
2. Start **Docker Desktop** and wait until the bottom bar says **Engine running**
3. Press the **Windows key**, type `PowerShell`, open **Windows PowerShell** (no administrator needed)
4. Paste and run:

```powershell
Set-ExecutionPolicy Bypass -Scope Process -Force
& "C:\DML\Install-WoW-WotLK-DockerDesktop.ps1"
```

### Options

| Option | Default | Example |
|---|---|---|
| `-InstallDir` | `C:\DML\games\wow-server-playerbots` | `-InstallDir 'D:\Games\wow-playerbots'` |
| `-MinBots` | `200` | `-MinBots 50` |
| `-MaxBots` | `250` | `-MaxBots 100` |

```powershell
& "C:\DML\Install-WoW-WotLK-DockerDesktop.ps1" -InstallDir 'D:\Games\wow-playerbots' -MinBots 50 -MaxBots 100
```

> ⚠️ **Do not click inside the PowerShell window while the installer is working.** Clicking selects text and Windows pauses the output — it looks frozen. Press **Enter** once to unfreeze it.

---

## What Happens During Install

### Preflight checks (~1 min)

| Check | What it's looking for |
|---|---|
| Docker Desktop | Installed and running (started automatically if not), Linux containers, Compose v2 |
| Memory | How much RAM Docker Desktop can use (warns below 6 GB) |
| Git | Installed (offers `winget install Git.Git`) |
| Disk space | ~30 GB on Docker's drive, ~3 GB in the install folder |
| Ports | 3724 and 8085 not taken by another server |
| Internet | Can reach github.com |

### Compile (2-4 hours)

- Clones [mod-playerbots/azerothcore-wotlk](https://github.com/mod-playerbots/azerothcore-wotlk) (Playerbot branch) and [mod-playerbots/mod-playerbots](https://github.com/mod-playerbots/mod-playerbots) into the install folder
- Writes `docker-compose.override.yml` (bot settings, restart policy, patient database health check)
- Writes `.env` so the database port is only reachable from **your own PC** (`127.0.0.1:3306`)
- Builds the images: worldserver, authserver, db-import, client-data

### First boot (varies — be patient!)

1. **Starting database** — MySQL sets itself up the first time. `Database still starting...` messages every 30 s mean it is working (waits up to 1 hour).
2. **Importing world databases** — 5-10 minutes.
3. **Map data** — the client-data container downloads the server's map files (~1.5 GB).
4. **Initializing acore_playerbots**, then the world and auth servers start.
5. **Waiting for world server** — the first boot applies database updates and can take 30-60 minutes. Later starts take ~30 seconds.

After that the installer creates the playerbot config file, restarts the world server once, and writes three shortcuts into the install folder.

> **If anything fails:** just run the installer again. It reuses the downloaded source and the compiled images, so you never compile twice.

---

## Step 2 — Create Your Account (Required)

The installer pauses and shows the commands. Open a **new** PowerShell window (or double-click `GM-Console.cmd` in the install folder) and run:

```powershell
docker attach ac-worldserver
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

Start `Wow.exe` and log in with the account you created.

---

## Daily Use

Docker Desktop must be running. Then, in the install folder (`C:\DML\games\wow-server-playerbots` by default), double-click:

| Shortcut | What it does |
|---|---|
| `Start-Server.cmd` | Starts the server (`docker compose up -d`) |
| `Stop-Server.cmd` | Stops the server safely (`docker compose down`) |
| `GM-Console.cmd` | Opens the GM console (accounts, GM commands) |

You can also start and stop the **wow-server-playerbots** group under **Containers** in the Docker Desktop window.

The server does **not** start automatically with Docker Desktop — on purpose, so it doesn't use CPU and RAM when you're not playing.

---

## Useful Commands

Run these in PowerShell from the install folder (`cd C:\DML\games\wow-server-playerbots`):

```powershell
# Start / stop
docker compose up -d
docker compose down

# Live logs of the world server (Ctrl+C only stops watching the log)
docker logs -f ac-worldserver

# Running containers
docker ps

# GM console (exit with Ctrl+P then Ctrl+Q)
docker attach ac-worldserver
```

---

## Files and Paths

| What | Where |
|---|---|
| Server source + config | `C:\DML\games\wow-server-playerbots` (or your `-InstallDir`) |
| Server config files | `<InstallDir>\env\dist\etc\` (`worldserver.conf`, `authserver.conf`, `modules\playerbots.conf`) |
| Server logs | `<InstallDir>\env\dist\logs\` |
| Bot settings / overrides | `<InstallDir>\docker-compose.override.yml` |
| Installer log | `%TEMP%\dml-wow-dockerdesktop-install.log` |
| Build log | `%TEMP%\dml-wow-dockerdesktop-build.log` |
| Database + map data | Docker volumes (managed by Docker Desktop) |

---

## Bot Settings

Edit `docker-compose.override.yml` in the install folder:

```yaml
      AC_AI_PLAYERBOT_MIN_RANDOM_BOTS: "200"
      AC_AI_PLAYERBOT_MAX_RANDOM_BOTS: "250"
```

Then restart: `Stop-Server.cmd`, then `Start-Server.cmd`. Fewer bots = less CPU and RAM.

---

## Optional — Give Docker More Memory

Docker Desktop (WSL 2 backend) gets half of your PC's RAM by default. If the compile fails with `Killed` / out of memory, create or edit `%UserProfile%\.wslconfig`:

```ini
[wsl2]
memory=12GB
```

Then run `wsl --shutdown` in PowerShell, restart Docker Desktop, and run the installer again.

---

## Play Together — LAN

The world and auth server ports (3724, 8085) are published on all network interfaces, so other PCs on your network can connect. See [WoW-Wotlk-NETWORKING.md](./WoW-Wotlk-NETWORKING.md) for the Windows firewall rules and the realmlist change needed for LAN play. The database (3306) stays local to your PC.

---

## Troubleshooting

### "Docker Desktop is in Windows-containers mode"
Right-click the whale icon in the system tray → **Switch to Linux containers...**, then run the installer again.

### "Docker Desktop did not start within 3 minutes"
Open Docker Desktop yourself, wait for **Engine running**, then re-run. If it never gets there: restart your PC, or in PowerShell run `wsl --shutdown` and start Docker Desktop again.

### Compile failed
Look at the end of the build log: `notepad $env:TEMP\dml-wow-dockerdesktop-build.log`
- `Killed` / `signal 9` / out of memory → see [Give Docker More Memory](#optional--give-docker-more-memory)
- `no space left on device` → free disk space, or in Docker Desktop: **Troubleshoot → Clean / Purge data** (deletes all Docker data)
- Network errors → check your internet and re-run

### Port 3724 / 8085 already in use
Another WoW server is running — for example the DML one inside `dml-arch`. Stop it (DML tray → Stop, or `wsl --shutdown`) and re-run.

### "ready..." never appears
The first boot can take up to an hour. Check what the world server is doing: `docker logs --tail 50 ac-worldserver`. If it keeps restarting, check `docker logs --tail 50 ac-database` and re-run the installer — it repairs a failed database import automatically.

### Can't log in / wrong realm
- Check `realmlist.wtf` says `set realmlist 127.0.0.1`
- Check both servers run: `docker ps` should list `ac-authserver` and `ac-worldserver`
- Did you create the account in the GM console?

### Force a fresh compile
```powershell
cd C:\DML\games\wow-server-playerbots
docker compose build --no-cache
```
Then run the installer again.

### Remove everything
```powershell
cd C:\DML\games\wow-server-playerbots
docker compose down -v --rmi all
cd \
Remove-Item -Recurse -Force C:\DML\games\wow-server-playerbots
```
This deletes the server, all characters, and the compiled images.

---

## Credits

- [AzerothCore](https://www.azerothcore.org/) — the open-source WotLK server core
- [mod-playerbots](https://github.com/mod-playerbots/mod-playerbots) — the AI player module
- [Docker Desktop](https://www.docker.com/products/docker-desktop/)
