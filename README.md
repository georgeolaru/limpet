# Limpet

> Keep your laptop online in your bag, using your phone hotspot after it leaves Wi-Fi.

A small, robust macOS script that keeps a MacBook connected to the internet while it
is open and awake (e.g. in a backpack, with Amphetamine running). If it loses
connectivity, it tries to reconnect to known networks and, as a last resort, to the
**iPhone Personal Hotspot** — automatically, with no clicking in the UI.

Main use case: AI coding agents, SSH sessions, and other long-running work on the Mac
stay online for as long as possible.

---

## 1. How it works

It runs as a daemon (started by a LaunchAgent at login) and, in a loop:

1. **Checks for REAL internet** — it isn't satisfied with "I have an IP / a gateway". It
   uses at least two methods:
   - a direct `ping` to `1.1.1.1` / `8.8.8.8` (L3 reachability, no DNS);
   - an HTTP request to `captive.apple.com` (checks DNS + HTTP + detects captive portals);
   - an HTTPS fallback straight to `https://1.1.1.1` (checks TLS without DNS).
2. **If it works → it does nothing.** It does not change the network.
3. **If it doesn't work → it remediates**, in order:
   - A. let macOS reconnect to a saved network on its own, then re-check;
   - B. cycle **Wi-Fi off/on** (fixes many "connected but dead" cases);
   - C. try the preferred networks from the config (home, office), in order;
   - D. try the **iPhone hotspot** (password from the Keychain).
4. After each attempt it **re-checks** real internet.
5. If nothing works → **retry with exponential backoff** (45s → 90 → 180 → … → max 300s),
   so it doesn't spin in an aggressive loop or burn CPU/battery.
6. **Clear logs** about what it tried and what it got.

States handled separately: Wi-Fi connected but no internet · Wi-Fi disconnected ·
hotspot unavailable · hotspot present but no internet · captive portal.

### Built for modern macOS (tested on macOS 26 / Tahoe)
- **Does not rely on reading the SSID.** On recent macOS, `networksetup -getairportnetwork`
  is unreliable (it returns "not associated" or `<redacted>` even when you are connected).
  The script confirms connectivity via **active link + IP + a real internet test**, not by name.
- **Does not use the `airport` binary** (removed in macOS 14.4+). Scanning is best-effort
  (`system_profiler`); if names are hidden, it tries known networks "blind".
- **Auto-detects the Wi-Fi interface** (does not assume `en0`).
- Native commands only: `networksetup`, `ifconfig`, `ipconfig`, `route`, `ping`, `curl`,
  `security`, `system_profiler`. No external dependencies. Compatible with `bash 3.2` (the one shipped with macOS).

---

## 2. Files

| File | Role |
|---|---|
| `limpet.sh` | The main script (daemon + diagnostic commands). |
| `limpet-menu.swift` | Native menu-bar companion (status + quick actions). |
| `assets/limpet-icon.png` | Original 1254×1254 app icon source copied from the downloaded image. |
| `assets/limpet-icon.svg` | Pixel-exact SVG wrapper for the app icon source image. |
| `assets/AppIcon.icns` | macOS app icon installed into the menu-bar app bundle. |
| `assets/MenuBarIconTemplate*.png` | Transparent template glyph variants used for macOS menu-bar status states. |
| `config.example.sh` | Configuration template → copied to `~/.config/limpet/config.sh`. |
| `com.georgeolaru.limpet.plist` | LaunchAgent (reference; `install.sh` generates one with the correct paths). |
| `install.sh` | Installs and starts everything. |
| `uninstall.sh` | Stops and uninstalls (`--purge` also removes config + logs). |

---

## 3. Install (quick)

```bash
cd limpet
bash install.sh
```

The installer:
- copies the script to `~/.local/bin/limpet.sh` (executable);
- compiles the status item to `~/Applications/Limpet.app` if `swiftc` is available;
- installs the app icon into the menu-bar app bundle;
- creates `~/.config/limpet/config.sh` from the example (if it doesn't exist);
- generates the plists with real paths in `~/Library/LaunchAgents/`;
- loads them into `launchd` (the daemon + menu bar start immediately and at every login).

**Then, required:**
1. Edit the config (see section 6): `~/.config/limpet/config.sh`
2. Put the hotspot password in the Keychain (section 5).
3. Connect to the hotspot manually once (section 4).

### Manual install (if you prefer step by step)

```bash
# 1. Copy the script and make it executable
mkdir -p ~/.local/bin
cp limpet.sh ~/.local/bin/limpet.sh
chmod +x ~/.local/bin/limpet.sh

# 2. The config
mkdir -p ~/.config/limpet
cp config.example.sh ~/.config/limpet/config.sh
# edit ~/.config/limpet/config.sh

# 3. The plist in LaunchAgents (edit the paths if your user isn't 'georgeolaru')
cp com.georgeolaru.limpet.plist ~/Library/LaunchAgents/

# 4. Load it
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.georgeolaru.limpet.plist
# (on older macOS: launchctl load -w ~/Library/LaunchAgents/com.georgeolaru.limpet.plist)
```

---

## 4. First-time hotspot connection (once, manually)

For the script to connect automatically, the hotspot network must already exist in macOS:

1. On the iPhone: **Settings → Personal Hotspot → Allow Others to Join = ON**.
   ("Maximize Compatibility" also helps if the MacBook can't see it.)
2. The hotspot name (SSID) = the iPhone's name: **Settings → General → About → Name**.
3. On the MacBook: from the Wi-Fi menu, connect to the hotspot **once, manually**, and
   tick "Remember this network". That way macOS saves the network + password.
4. Put that exact name in the config under `HOTSPOT_SSID`.

> Note: the home/office networks in `PREFERRED_SSIDS` must also be connected manually
> once, so they're remembered with their password. The script relies on saved credentials.

---

## 5. Hotspot password in the Keychain (recommended)

So you don't keep the password in cleartext in a file, store it in the Keychain (the
default "service" name is `limpet-hotspot`, and "account" = the hotspot SSID):

```bash
# replace the SSID and the password
security add-generic-password \
  -s "limpet-hotspot" \
  -a "My iPhone" \
  -w "HOTSPOT_PASSWORD" \
  -U
```

The script reads it on its own with `security find-generic-password -w`. Leave
`HOTSPOT_PASSWORD=""` in the config.

- Verify: `security find-generic-password -s "limpet-hotspot" -a "My iPhone" -w`
- The first time, macOS may ask for an "allow access" confirmation. Click **Always Allow**.
- Less secure alternative: put the password directly in the config under `HOTSPOT_PASSWORD`.
- If you already connected to the hotspot manually (section 4), the script can work even
  without a password (it uses the credentials saved by macOS) — `TRY_REMEMBERED_HOTSPOT=1`.

---

## 6. Configuration

Edit `~/.config/limpet/config.sh`. The most important settings:

```sh
PREFERRED_SSIDS=( "Home_WiFi" "Office_WiFi" )    # in order of preference
HOTSPOT_SSID="My iPhone"                          # the exact hotspot name
HOTSPOT_PASSWORD=""                               # empty = read from the Keychain
PREFER_WIFI_OVER_HOTSPOT=1                         # automatically move back from hotspot to Wi-Fi
PREFER_WIFI_CHECK_INTERVAL=300                     # every 5 minutes when it looks like it's on hotspot
HOTSPOT_GATEWAY_PREFIXES=( "172.20.10." )         # iPhone detection when the SSID is redacted
CHECK_INTERVAL=45                                 # seconds between checks while online
MAX_INTERVAL=300                                  # backoff cap on failure
LOG_FILE="$HOME/Library/Logs/limpet.log"
```

### Automatically moving back from hotspot to Wi-Fi

When the internet works, the daemon normally doesn't change the network. The exception is
`PREFER_WIFI_OVER_HOTSPOT=1`: if the current connection looks like the iPhone hotspot,
every `PREFER_WIFI_CHECK_INTERVAL` seconds it tries the networks in `PREFERRED_SSIDS`,
in order. It only switches if the new network has real internet. If it doesn't find a
good Wi-Fi, it stays on the hotspot or tries to return to it.

On recent macOS, the SSID may show up as `<redacted>`. `sudo` usually doesn't fix this,
because SSID visibility is tied to Location Services, not just Unix privileges. For the
iPhone Personal Hotspot, the script also detects the standard `172.20.10.x` gateway, so
it can decide it's on the hotspot even when the name is hidden.

After any config change, **restart** the agent:

```bash
launchctl kickstart -k gui/$(id -u)/com.georgeolaru.limpet
```

---

## 7. Start / stop / check

```bash
# Start (or restart) on demand
launchctl kickstart -k gui/$(id -u)/com.georgeolaru.limpet

# Stop temporarily
launchctl bootout gui/$(id -u)/com.georgeolaru.limpet

# Start again
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.georgeolaru.limpet.plist

# Agent state (look for 'state' and 'pid')
launchctl print gui/$(id -u)/com.georgeolaru.limpet | grep -E 'state|pid|last exit'

# Logs (most useful)
tail -f ~/Library/Logs/limpet.log
```

Example logs:
```
2026-06-15 10:00:01 limpet started (iface=en0, interval=45s, ...).
2026-06-15 10:00:01 Internet OK (route=en0, ssid=<redacted>).
2026-06-15 10:42:13 No internet detected. ssid=(unknown).
2026-06-15 10:42:19 Cycling Wi-Fi power to force reassociation.
2026-06-15 10:42:35 Attempting to join 'My iPhone'.
2026-06-15 10:42:41   Internet OK via 'My iPhone' (ssid now: <redacted>).
2026-06-15 10:42:41 Remediation succeeded.
```

---

## 8. Menu bar status

Installation also starts a small companion in the menu bar. It doesn't do the monitoring
itself; it only reads the daemon's status and runs safe actions on top of the script/launchd.
The menu bar shows a Limpet template icon variant for OK, down, captive portal, or unknown status.

What you see in the menu:
- internet status: OK / DOWN / captive portal;
- the LaunchAgent state and the daemon PID;
- the Wi-Fi interface, the IP, the default route and the best-effort SSID;
- the last line from the log.

Available actions:
- **Pause Limpet / Resume Limpet** — stops or restarts the background daemon;
- **Check Internet Now** — runs `limpet.sh --check`;
- **Prefer Wi-Fi Now** — if you're on the hotspot, immediately try the preferred networks;
- **Settings…** — opens the Settings window (see below);
- **Open Log**, **Show Details**;
- **Quit Limpet**, **Uninstall Limpet…** — Uninstall runs the bundled uninstaller (keeps config + logs).

### Settings window

Instead of hand-editing the config, open **Settings…** to configure Limpet:

- **Phone hotspot** — pick your hotspot from your saved Wi-Fi networks, set its password
  (stored in the Keychain), and **Test hotspot now** to confirm it actually connects.
- **Behavior** — toggle "Automatically return to Wi-Fi when available", and set the check
  interval and max backoff.

Changes apply immediately and restart the daemon. Under the hood the window edits the same
`~/.config/limpet/config.sh` and Keychain entry the daemon already uses — so the CLI and the
UI never disagree.

The menu bar has its own LaunchAgent:

```bash
launchctl print gui/$(id -u)/com.georgeolaru.limpet.menu | grep -E 'state|pid'
```

If you only close the menu bar via "Quit Limpet", the daemon keeps running. At the next
login the menu bar starts again.

---

## 9. Debugging

The script has diagnostic commands that **change nothing** (read-only), plus test modes.
Run the installed binary directly:

```bash
SCRIPT=~/.local/bin/limpet.sh

"$SCRIPT" --check     # just check the internet: OK / CAPTIVE / DOWN  (exit code 0/2/1)
"$SCRIPT" --status    # interface, Wi-Fi power, link, IP, route, SSID, internet, config
"$SCRIPT" --scan      # visible networks (best-effort; may be hidden on recent macOS)
"$SCRIPT" --prefer-wifi-now   # if you're on hotspot, immediately try preferred Wi-Fi
"$SCRIPT" --once      # a single check + remediation, with the log on screen (safe test)
"$SCRIPT" --test-join "SSID" "password"   # manually test connecting to a network
"$SCRIPT" --help
```

Common problems:

- **"Internet OK" but I still lose the net in transit** — normal: the script reacts on
  the next check (at most `CHECK_INTERVAL` seconds) and then remediates.
- **`--scan` shows `<redacted>` / empty** — that's macOS privacy (missing Location
  permission). It's not a problem: the daemon tries known networks "blind". If you want
  real names, grant Location Services to the process.
- **It won't connect to the hotspot** — check: Personal Hotspot is on on the iPhone;
  `HOTSPOT_SSID` is exactly the iPhone's name; you connected manually once; the password
  is in the Keychain. Test: `"$SCRIPT" --test-join "My iPhone" "password"`.
- **The join fails with "Could not find network"** — the network is out of range or the
  name is wrong. For the hotspot: open the Personal Hotspot screen on the iPhone (it makes
  it visible).
- **`networksetup` asks for an admin password** — rare; run the account as admin. If it
  persists, you can allow the command without a password, but it's usually not needed for
  join/power.
- **The agent won't start** — see `~/Library/Logs/limpet.err.log` and
  `launchctl print gui/$(id -u)/com.georgeolaru.limpet`.
- **I want fewer/more logs** — change `CHECK_INTERVAL` / `MAX_INTERVAL`. When the net
  works, the script only logs on transitions, so the file doesn't fill up.

---

## 10. Uninstall

```bash
bash uninstall.sh           # stops + removes the agent and the script (keeps config + logs)
bash uninstall.sh --purge   # removes everything, including config and logs
```

---

## 11. Security notes / resources

- The hotspot password lives in the **Keychain**, not in the script.
- The daemon stays "asleep" almost all the time (a long `sleep` between checks) →
  negligible CPU/battery use. `ProcessType=Background` + `LowPriorityIO` in the plist.
- It runs as a **LaunchAgent** (per-user), so it has access to your Keychain and can
  manage Wi-Fi without sudo. It does not depend on SSH or the internet to start.
- The log rotates itself at ~1 MB (`limpet.log` → `limpet.log.1`).
