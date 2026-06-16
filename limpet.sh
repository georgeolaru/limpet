#!/bin/bash
# =============================================================================
# limpet.sh
#
# Keeps a MacBook connected to the internet while it is open and awake.
#
# Logic, in short:
#   1. Check whether there is REAL internet (not just an IP / gateway).
#   2. If it works -> do nothing (do NOT change the network).
#   3. If it doesn't work -> try, in order:
#        a) let macOS reconnect to a saved network on its own;
#        b) cycle "Wi-Fi off/on" to force re-association;
#        c) try the preferred known networks (home / office);
#        d) try the phone hotspot (iPhone, Android, ...; password from the Keychain).
#   4. After each attempt, re-check the internet.
#   5. If nothing works -> retry with backoff (no aggressive loop).
#   6. Write clear logs about what it tried and what it got.
#
# Built for modern macOS (tested on macOS 26 / Tahoe, bash 3.2):
#   - Does NOT rely on reading the SSID (networksetup -getairportnetwork is
#     unreliable / "redacted" on recent macOS).
#   - Does NOT use the "airport" binary (removed in macOS 14.4+).
#   - Auto-detects the Wi-Fi interface (does not assume en0).
#   - Uses only native macOS commands: networksetup, ifconfig, ipconfig,
#     route, ping, curl, security, system_profiler.
#
# Run modes:
#   limpet.sh                 -> run as a daemon (loop with backoff)
#   limpet.sh --once          -> a single check + remediation
#   limpet.sh --check         -> just check the internet (read-only)
#   limpet.sh --status        -> show the current state (read-only)
#   limpet.sh --scan          -> visible Wi-Fi networks (best-effort)
#   limpet.sh --prefer-wifi-now -> if on hotspot, try preferred Wi-Fi
#   limpet.sh --test-hotspot  -> test the configured hotspot fallback
#   limpet.sh --test-join SSID [password]  -> test connecting manually
#   limpet.sh --list-saved-networks -> remembered Wi-Fi networks
#   limpet.sh --help
# =============================================================================

# ------------------------------------------------------------------------------
# 1) DEFAULT VALUES (can be overridden from the config file)
# ------------------------------------------------------------------------------
# Known networks, in order of preference (home, office ...). They must already
# be saved in macOS (connected manually once).
PREFERRED_SSIDS=( "Home_WiFi" "Office_WiFi" )

# The phone hotspot (iPhone, Android, anything). HOTSPOT_SSID is just the
# network name the phone broadcasts; it must be saved in macOS (connected once).
HOTSPOT_SSID="My iPhone"
HOTSPOT_PASSWORD=""                       # leave empty; ideally put the password in the Keychain
HOTSPOT_KEYCHAIN_SERVICE="limpet-hotspot"
TRY_REMEMBERED_HOTSPOT=1                   # 1 = also try without a password (saved network)

# If you're on hotspot, periodically try to move back to the preferred real Wi-Fi.
# On recent macOS the SSID may be "<redacted>", so we also detect the hotspot by its
# gateway range (iPhone uses 172.20.10.x; Android is commonly 192.168.43.x).
PREFER_WIFI_OVER_HOTSPOT=1
PREFER_WIFI_CHECK_INTERVAL=300             # how often to try the upgrade off hotspot
HOTSPOT_GATEWAY_PREFIXES=( "172.20.10." )

# Wi-Fi interface. Empty = auto-detect from networksetup -listallhardwareports.
WIFI_INTERFACE=""

# Intervals / timeouts (seconds).
CHECK_INTERVAL=45                          # how often to check when everything is ok
MAX_INTERVAL=300                           # the backoff cap on repeated failure
ASSOC_TIMEOUT=12                           # wait for link+IP after a join
INTERNET_TIMEOUT=20                        # wait for internet after a join
CURL_TIMEOUT=5
PING_TIMEOUT=2

# Logging.
LOG_FILE="$HOME/Library/Logs/limpet.log"
MAX_LOG_BYTES=1048576                      # 1 MB -> simple rotation (keeps .1)
VERBOSE=0                                  # 1 = also write to stderr (useful with --once)

# Scan behavior.
USE_SCAN=1                                 # 1 = best-effort scan to avoid a pointless join

# Targets for the connectivity test.
PING_HOSTS=( "1.1.1.1" "8.8.8.8" )
CAPTIVE_URL="http://captive.apple.com/hotspot-detect.html"
CAPTIVE_EXPECT="Success"
HTTPS_FALLBACK_URL="https://1.1.1.1"       # HTTPS directly to IP (no DNS needed)

# ------------------------------------------------------------------------------
# 2) LOAD THE USER CONFIGURATION (overrides the values above)
# ------------------------------------------------------------------------------
CONFIG_FILE="${LIMPET_CONFIG:-$HOME/.config/limpet/config.sh}"
if [ -f "$CONFIG_FILE" ]; then
  # shellcheck disable=SC1090
  . "$CONFIG_FILE"
fi

# Status codes for the internet test.
INET_OK=0        # real internet
INET_DOWN=1      # no connectivity
INET_CAPTIVE=2   # connected, but captive portal / no real internet

# ------------------------------------------------------------------------------
# 3) UTILITIES: logging
# ------------------------------------------------------------------------------
log() {
  local ts
  ts=$(date '+%Y-%m-%d %H:%M:%S')
  printf '%s %s\n' "$ts" "$*" >> "$LOG_FILE" 2>/dev/null
  if [ "${VERBOSE:-0}" = "1" ]; then
    printf '%s %s\n' "$ts" "$*" >&2
  fi
}

rotate_log_if_big() {
  [ -f "$LOG_FILE" ] || return 0
  local size
  size=$(stat -f%z "$LOG_FILE" 2>/dev/null || echo 0)
  if [ "$size" -gt "$MAX_LOG_BYTES" ]; then
    mv -f "$LOG_FILE" "$LOG_FILE.1" 2>/dev/null
    log "Log rotated (previous saved to $LOG_FILE.1)."
  fi
}

# ------------------------------------------------------------------------------
# 4) UTILITIES: Wi-Fi interface / link state
# ------------------------------------------------------------------------------
detect_iface() {
  if [ -n "$WIFI_INTERFACE" ]; then
    printf '%s' "$WIFI_INTERFACE"
    return 0
  fi
  networksetup -listallhardwareports 2>/dev/null \
    | awk '/Hardware Port: (Wi-Fi|AirPort)/{getline; print $2; exit}'
}

# Active Wi-Fi link (associated to a network, regardless of internet)?
link_active() {
  ifconfig "$IFACE" 2>/dev/null | grep -q "status: active"
}

# Does the interface have an IP?
has_ip() {
  ipconfig getifaddr "$IFACE" >/dev/null 2>&1
}

# Interface used for the default route (en0, en7 ethernet, etc.) - info only.
default_iface() {
  route -n get default 2>/dev/null | awk '/interface:/{print $2; exit}'
}

default_gateway() {
  route -n get default 2>/dev/null | awk '/gateway:/{print $2; exit}'
}

# Current SSID - BEST EFFORT. On recent macOS it may be empty/"redacted".
current_ssid() {
  local s
  s=$(networksetup -getairportnetwork "$IFACE" 2>/dev/null \
        | sed -n 's/^Current Wi-Fi Network: //p')
  if [ -n "$s" ]; then printf '%s' "$s"; return 0; fi
  s=$(ipconfig getsummary "$IFACE" 2>/dev/null \
        | sed -n 's/^[[:space:]]*SSID : //p' | head -1)
  printf '%s' "$s"
}

current_ssid_or_unknown() {
  local s
  s=$(current_ssid)
  if [ -n "$s" ]; then printf '%s' "$s"; else printf '(unknown)'; fi
}

gateway_looks_like_hotspot() {
  local gw="$1" prefix
  [ -n "$gw" ] || return 1
  for prefix in "${HOTSPOT_GATEWAY_PREFIXES[@]:-}"; do
    [ -z "$prefix" ] && continue
    case "$gw" in
      "$prefix"*) return 0 ;;
    esac
  done
  return 1
}

current_network_is_hotspot() {
  local ssid gw
  ssid=$(current_ssid)
  if [ -n "$HOTSPOT_SSID" ] && [ "$ssid" = "$HOTSPOT_SSID" ]; then
    return 0
  fi
  gw=$(default_gateway)
  gateway_looks_like_hotspot "$gw"
}

ensure_wifi_on() {
  local st
  st=$(networksetup -getairportpower "$IFACE" 2>/dev/null)
  case "$st" in
    *": On") return 0 ;;
    *)
      log "Wi-Fi power is OFF -> turning it on."
      networksetup -setairportpower "$IFACE" on >/dev/null 2>&1
      sleep 3
      ;;
  esac
}

# Quick off/on to force re-association (fixes many "connected but dead" cases).
wifi_bounce() {
  log "Cycling Wi-Fi power to force reassociation."
  networksetup -setairportpower "$IFACE" off >/dev/null 2>&1
  sleep 2
  networksetup -setairportpower "$IFACE" on  >/dev/null 2>&1
  wait_for_link "$ASSOC_TIMEOUT"
}

wait_for_link() {
  local timeout="$1" i=0
  while [ "$i" -lt "$timeout" ]; do
    if link_active && has_ip; then return 0; fi
    sleep 1
    i=$((i + 1))
  done
  return 1
}

# ------------------------------------------------------------------------------
# 5) THE INTERNET TEST (at least two methods + captive-portal detection)
#    Returns: 0 = real internet, 1 = down, 2 = captive portal.
# ------------------------------------------------------------------------------
probe_internet() {
  local body l3=1 h

  # (a) L3 reachability, no DNS: ping stable IPs directly.
  for h in "${PING_HOSTS[@]}"; do
    if ping -c1 -t"$PING_TIMEOUT" "$h" >/dev/null 2>&1; then
      l3=0
      break
    fi
  done

  # (b) Apple captive-portal HTTP test (exercises both DNS and HTTP).
  body=$(curl -s -m "$CURL_TIMEOUT" "$CAPTIVE_URL" 2>/dev/null)
  if [ -n "$body" ]; then
    case "$body" in
      *"$CAPTIVE_EXPECT"*) return $INET_OK ;;     # correct response -> real internet
      *)                   return $INET_CAPTIVE ;; # other content -> captive portal
    esac
  fi

  # (c) HTTP failed (DNS broken or Apple blocked). If we have L3 + HTTPS over IP -> ok.
  if [ "$l3" -eq 0 ] && curl -fs -m "$CURL_TIMEOUT" -o /dev/null "$HTTPS_FALLBACK_URL" 2>/dev/null; then
    return $INET_OK
  fi

  return $INET_DOWN
}

# ------------------------------------------------------------------------------
# 6) SCANNING (best-effort). On recent macOS it may be empty -> then we try blind.
# ------------------------------------------------------------------------------
scan_networks() {
  [ "$USE_SCAN" -eq 1 ] || return 0
  # Extract network names: a "Name:" line immediately followed by "PHY Mode:".
  system_profiler SPAirPortDataType 2>/dev/null | awk '
    /Current Network Information:|Other Local Wi-Fi Networks:/ { grab=1 }
    grab {
      if (prev ~ /:[[:space:]]*$/ && $0 ~ /PHY Mode:/) {
        name = prev
        sub(/^[[:space:]]+/, "", name)
        sub(/:[[:space:]]*$/, "", name)
        # On recent macOS, without Location permission, names show up as "<redacted>".
        # We ignore them -> the list becomes empty -> we try known networks "blind".
        if (name != "" && name != "<redacted>") print name
      }
      prev = $0
    }'
}

network_visible() {
  local ssid="$1" list="$2"
  [ -z "$list" ] && return 0                  # unknown scan -> allow the attempt
  printf '%s\n' "$list" | grep -Fxq "$ssid"
}

# ------------------------------------------------------------------------------
# 7) CONNECT + VERIFY
# ------------------------------------------------------------------------------
try_join_and_verify() {
  local ssid="$1" pass="$2" out rc i=0
  log "Attempting to join '$ssid'."

  if [ -n "$pass" ]; then
    out=$(networksetup -setairportnetwork "$IFACE" "$ssid" "$pass" 2>&1)
  else
    out=$(networksetup -setairportnetwork "$IFACE" "$ssid" 2>&1)
  fi
  [ -n "$out" ] && log "  networksetup: $out"

  case "$out" in
    *"Could not find network"*|*"not be found"*|*"Failed to join"*)
      log "  '$ssid' not in range / join failed."
      return 1
      ;;
  esac

  if ! wait_for_link "$ASSOC_TIMEOUT"; then
    log "  No link/IP after joining '$ssid'."
    return 1
  fi

  while [ "$i" -lt "$INTERNET_TIMEOUT" ]; do
    probe_internet; rc=$?
    if [ "$rc" -eq "$INET_OK" ]; then
      log "  Internet OK via '$ssid' (ssid now: $(current_ssid_or_unknown))."
      return 0
    fi
    if [ "$rc" -eq "$INET_CAPTIVE" ]; then
      log "  Captive portal on '$ssid' (needs login) -> skipping."
      return 1
    fi
    sleep 2
    i=$((i + 2))
  done

  log "  Joined '$ssid' but still no internet."
  return 1
}

get_hotspot_password() {
  if [ -n "$HOTSPOT_PASSWORD" ]; then
    printf '%s' "$HOTSPOT_PASSWORD"
    return 0
  fi
  security find-generic-password \
    -s "$HOTSPOT_KEYCHAIN_SERVICE" -a "$HOTSPOT_SSID" -w 2>/dev/null
}

try_hotspot() {
  local pass
  pass=$(get_hotspot_password)
  if [ -n "$pass" ]; then
    try_join_and_verify "$HOTSPOT_SSID" "$pass" && return 0
  else
    log "No hotspot password (config/Keychain). Trying remembered credentials."
  fi
  if [ "$TRY_REMEMBERED_HOTSPOT" -eq 1 ]; then
    try_join_and_verify "$HOTSPOT_SSID" "" && return 0
  fi
  return 1
}

log_visible_networks() {
  local visible="$1"
  if [ -n "$visible" ]; then
    log "Visible networks: $(printf '%s' "$visible" | tr '\n' ',' | sed 's/,$//')"
  else
    log "Scan unavailable/empty -> trying known networks blindly."
  fi
}

try_preferred_networks() {
  local visible="$1" ssid
  for ssid in "${PREFERRED_SSIDS[@]:-}"; do
    [ -z "$ssid" ] && continue
    if network_visible "$ssid" "$visible"; then
      try_join_and_verify "$ssid" "" && return 0
    else
      log "Preferred '$ssid' not visible -> skipping."
    fi
  done
  return 1
}

prefer_wifi_over_hotspot() {
  local visible rc
  ensure_wifi_on

  if ! current_network_is_hotspot; then
    log "Prefer Wi-Fi check skipped; current network does not look like hotspot (ssid=$(current_ssid_or_unknown), gateway=$(default_gateway))."
    return 0
  fi

  log "Current connection looks like hotspot (ssid=$(current_ssid_or_unknown), gateway=$(default_gateway)) -> checking preferred Wi-Fi."
  visible=$(scan_networks)
  log_visible_networks "$visible"

  if try_preferred_networks "$visible"; then
    log "Switched from hotspot to preferred Wi-Fi."
    return 0
  fi

  log "No preferred Wi-Fi with real internet found while on hotspot."
  probe_internet; rc=$?
  if [ "$rc" -eq "$INET_OK" ]; then
    if ! current_network_is_hotspot; then
      log "Preferred Wi-Fi check ended on non-hotspot connection with internet OK."
      return 0
    fi
    log "Internet still OK after preferred Wi-Fi check; staying on current connection."
    return 1
  fi

  log "Internet lost during preferred Wi-Fi check -> trying hotspot again."
  try_hotspot && return 1
  log "Could not restore hotspot after preferred Wi-Fi check."
  return 1
}

# ------------------------------------------------------------------------------
# 8) REMEDIATION (run ONLY when there is no internet)
# ------------------------------------------------------------------------------
remediate() {
  ensure_wifi_on

  # Phase A: let macOS auto-reconnect to a saved network, then re-check.
  if wait_for_link 6; then
    if probe_internet; then
      log "Recovered via existing/auto-joined network."
      return 0
    fi
  fi

  # Phase B: bounce Wi-Fi once (fixes many "connected but no internet").
  wifi_bounce
  if probe_internet; then
    log "Recovered after Wi-Fi power cycle."
    return 0
  fi

  # Phase C: best-effort scan + explicit join.
  local visible
  visible=$(scan_networks)
  log_visible_networks "$visible"

  # C1: known preferred networks, in order of preference (use the saved password).
  try_preferred_networks "$visible" && return 0

  # C2: phone hotspot (last resort). It may not appear in the scan (e.g. iPhone
  # Instant Hotspot can stay hidden), so we try anyway.
  if [ -n "$HOTSPOT_SSID" ]; then
    if ! network_visible "$HOTSPOT_SSID" "$visible"; then
      log "Hotspot '$HOTSPOT_SSID' not seen in scan (instant hotspot may be hidden); trying anyway."
    fi
    try_hotspot && return 0
  fi

  return 1
}

# ------------------------------------------------------------------------------
# 9) MAIN LOOP (daemon) with exponential backoff
# ------------------------------------------------------------------------------
main_loop() {
  log "limpet started (iface=$IFACE, interval=${CHECK_INTERVAL}s, config=$CONFIG_FILE)."
  local interval="$CHECK_INTERVAL" fails=0 rc prev="unknown" shift_n now last_prefer_wifi_check=0

  while true; do
    rotate_log_if_big
    probe_internet; rc=$?

    if [ "$rc" -eq "$INET_OK" ]; then
      # Internet ok -> do NOT touch the network. Log only on transition (clean logs).
      if [ "$prev" != "ok" ]; then
        log "Internet OK (route=$(default_iface), ssid=$(current_ssid_or_unknown))."
      fi
      prev="ok"; fails=0; interval="$CHECK_INTERVAL"
      if [ "${PREFER_WIFI_OVER_HOTSPOT:-0}" -eq 1 ]; then
        now=$(date +%s)
        if [ $((now - last_prefer_wifi_check)) -ge "${PREFER_WIFI_CHECK_INTERVAL:-300}" ]; then
          last_prefer_wifi_check="$now"
          prefer_wifi_over_hotspot || true
        fi
      fi
    else
      if [ "$rc" -eq "$INET_CAPTIVE" ]; then
        log "Connected but no real internet (captive portal). ssid=$(current_ssid_or_unknown)."
      else
        log "No internet detected. ssid=$(current_ssid_or_unknown)."
      fi
      prev="down"

      if remediate; then
        log "Remediation succeeded."
        prev="ok"; fails=0; interval="$CHECK_INTERVAL"
      else
        fails=$((fails + 1))
        shift_n=$fails
        [ "$shift_n" -gt 4 ] && shift_n=4
        interval=$(( CHECK_INTERVAL * (1 << shift_n) ))
        [ "$interval" -gt "$MAX_INTERVAL" ] && interval="$MAX_INTERVAL"
        log "Remediation failed (attempt $fails). Backing off ${interval}s."
      fi
    fi

    sleep "$interval"
  done
}

# ------------------------------------------------------------------------------
# 10) LOCK: a single instance (for daemon / --once)
# ------------------------------------------------------------------------------
LOCK_DIR=""
acquire_lock() {
  LOCK_DIR="${TMPDIR:-/tmp}/limpet.lock"
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    printf '%s' "$$" > "$LOCK_DIR/pid" 2>/dev/null
    trap 'release_lock' EXIT INT TERM
    return 0
  fi
  # A lock exists - is the process still alive?
  local oldpid
  oldpid=$(cat "$LOCK_DIR/pid" 2>/dev/null)
  if [ -n "$oldpid" ] && kill -0 "$oldpid" 2>/dev/null; then
    return 1
  fi
  # Stale lock -> we take it over.
  rm -rf "$LOCK_DIR" 2>/dev/null
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    printf '%s' "$$" > "$LOCK_DIR/pid" 2>/dev/null
    trap 'release_lock' EXIT INT TERM
    return 0
  fi
  return 1
}
release_lock() {
  [ -n "$LOCK_DIR" ] && rm -rf "$LOCK_DIR" 2>/dev/null
}

usage() {
  awk 'NR>=2 && /^# ={5,}/ {c++} c>=1 {print} c>=2 {exit}' "$0" | sed 's/^# \{0,1\}//'
}

# ------------------------------------------------------------------------------
# 11) STARTUP
# ------------------------------------------------------------------------------
mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null
IFACE="$(detect_iface)"

case "${1:-}" in
  --check)
    if [ -z "$IFACE" ]; then echo "No Wi-Fi interface found."; fi
    probe_internet; rc=$?
    case "$rc" in
      0) echo "internet: OK" ;;
      2) echo "internet: CAPTIVE PORTAL (connected, no real internet)" ;;
      *) echo "internet: DOWN" ;;
    esac
    exit "$rc"
    ;;

  --status)
    echo "Wi-Fi interface : ${IFACE:-<none>}"
    echo "Wi-Fi power     : $(networksetup -getairportpower "$IFACE" 2>/dev/null | sed 's/.*: //')"
    echo "Link active     : $(link_active && echo yes || echo no)"
    echo "IP address      : $(ipconfig getifaddr "$IFACE" 2>/dev/null || echo none)"
    echo "Default route   : $(default_iface)"
    echo "Default gateway : $(default_gateway)"
    echo "SSID (best eff.): $(current_ssid_or_unknown)"
    echo "Hotspot guess   : $(current_network_is_hotspot && echo yes || echo no)"
    probe_internet; rc=$?
    case "$rc" in
      0) echo "Internet        : OK" ;;
      2) echo "Internet        : CAPTIVE PORTAL" ;;
      *) echo "Internet        : DOWN" ;;
    esac
    echo "Config file     : $CONFIG_FILE $( [ -f "$CONFIG_FILE" ] && echo '(loaded)' || echo '(not found, using defaults)')"
    echo "Log file        : $LOG_FILE"
    echo "Prefer Wi-Fi    : ${PREFER_WIFI_OVER_HOTSPOT:-0} (every ${PREFER_WIFI_CHECK_INTERVAL:-300}s)"
    exit 0
    ;;

  --scan)
    out=$(scan_networks)
    if [ -n "$out" ]; then
      echo "$out"
    else
      echo "(no usable scan results on this macOS)"
      echo "Network names are probably hidden ('<redacted>') without Location"
      echo "Services permission. That's not a problem: the daemon will try the known"
      echo "networks from the config 'blind' (the most robust path anyway). If you want"
      echo "the scan optimization, enable Location Services for the process running the script."
    fi
    exit 0
    ;;

  --test-join)
    [ -z "$IFACE" ] && { echo "No Wi-Fi interface found."; exit 1; }
    [ -z "${2:-}" ] && { echo "usage: $0 --test-join SSID [password]"; exit 1; }
    VERBOSE=1
    ensure_wifi_on
    try_join_and_verify "$2" "${3:-}"
    exit $?
    ;;

  --once)
    [ -z "$IFACE" ] && { echo "No Wi-Fi interface found."; exit 1; }
    acquire_lock || { echo "Another instance is running."; exit 0; }
    VERBOSE=1
    rotate_log_if_big
    probe_internet; rc=$?
    if [ "$rc" -eq "$INET_OK" ]; then
      log "[once] Internet OK -> nothing to do."
      exit 0
    fi
    log "[once] No internet (code $rc) -> remediating."
    if remediate; then log "[once] Remediation succeeded."; exit 0; fi
    log "[once] Remediation failed."
    exit 1
    ;;

  --prefer-wifi-now)
    [ -z "$IFACE" ] && { echo "No Wi-Fi interface found."; exit 1; }
    VERBOSE=1
    rotate_log_if_big
    prefer_wifi_over_hotspot
    exit $?
    ;;

  --test-hotspot)
    [ -z "$IFACE" ] && { echo "No Wi-Fi interface found."; exit 1; }
    [ -z "$HOTSPOT_SSID" ] && { echo "No hotspot configured."; exit 1; }
    VERBOSE=1
    rotate_log_if_big
    ensure_wifi_on
    if try_hotspot; then echo "Hotspot OK: internet via '$HOTSPOT_SSID'."; exit 0; fi
    echo "Hotspot test failed for '$HOTSPOT_SSID'."
    exit 1
    ;;

  # --- UI helpers (used by the menu-bar app; safe to run manually) ----------
  --list-saved-networks)
    [ -z "$IFACE" ] && { echo "No Wi-Fi interface found." >&2; exit 1; }
    # Saved/remembered networks. Works even when the live scan is redacted.
    networksetup -listpreferredwirelessnetworks "$IFACE" 2>/dev/null \
      | sed '1d; s/^[[:space:]]*//'
    exit 0
    ;;

  --print-config)
    # Emit the UI-managed settings as KEY=VALUE (the menu-bar app reads these).
    echo "HOTSPOT_SSID=$HOTSPOT_SSID"
    echo "TRY_REMEMBERED_HOTSPOT=$TRY_REMEMBERED_HOTSPOT"
    echo "PREFER_WIFI_OVER_HOTSPOT=$PREFER_WIFI_OVER_HOTSPOT"
    echo "CHECK_INTERVAL=$CHECK_INTERVAL"
    echo "MAX_INTERVAL=$MAX_INTERVAL"
    if [ -n "$HOTSPOT_PASSWORD" ] || \
       security find-generic-password -s "$HOTSPOT_KEYCHAIN_SERVICE" -a "$HOTSPOT_SSID" -w >/dev/null 2>&1; then
      echo "HOTSPOT_PASSWORD_SET=1"
    else
      echo "HOTSPOT_PASSWORD_SET=0"
    fi
    echo "CONFIG_FILE=$CONFIG_FILE"
    exit 0
    ;;

  --set-config)
    # --set-config KEY VALUE : upsert one whitelisted key in the user config.
    key="${2:-}"; value="${3:-}"
    case "$key" in
      HOTSPOT_SSID|TRY_REMEMBERED_HOTSPOT|PREFER_WIFI_OVER_HOTSPOT|CHECK_INTERVAL|MAX_INTERVAL) ;;
      *) echo "Refusing to set unknown key: '$key'" >&2; exit 1 ;;
    esac
    case "$key" in
      HOTSPOT_SSID) line="$key=\"$value\"" ;;
      *)            line="$key=$value" ;;
    esac
    mkdir -p "$(dirname "$CONFIG_FILE")"
    tmp="$(mktemp "${TMPDIR:-/tmp}/limpet-cfg.XXXXXX")" || exit 1
    if [ -f "$CONFIG_FILE" ] && grep -qE "^[[:space:]]*$key=" "$CONFIG_FILE"; then
      awk -v k="$key" -v repl="$line" '
        $0 ~ ("^[[:space:]]*" k "=") { print repl; next }
        { print }
      ' "$CONFIG_FILE" > "$tmp"
    else
      [ -f "$CONFIG_FILE" ] && cat "$CONFIG_FILE" >> "$tmp"
      printf '%s\n' "$line" >> "$tmp"
    fi
    mv "$tmp" "$CONFIG_FILE"
    echo "set $key"
    exit 0
    ;;

  --set-hotspot-password)
    # Reads the password from STDIN so it never appears in argv / ps output.
    # Usage: printf '%s' "secret" | limpet.sh --set-hotspot-password [SSID]
    ssid="${2:-$HOTSPOT_SSID}"
    IFS= read -r pass || true
    [ -z "$ssid" ] && { echo "No hotspot SSID set." >&2; exit 1; }
    if [ -z "$pass" ]; then
      security delete-generic-password -s "$HOTSPOT_KEYCHAIN_SERVICE" -a "$ssid" >/dev/null 2>&1 || true
      echo "cleared"
      exit 0
    fi
    if security add-generic-password -U -s "$HOTSPOT_KEYCHAIN_SERVICE" -a "$ssid" -w "$pass" >/dev/null 2>&1; then
      echo "saved"
      exit 0
    fi
    echo "keychain error" >&2
    exit 1
    ;;

  -h|--help)
    usage
    exit 0
    ;;

  ""|--daemon)
    [ -z "$IFACE" ] && { log "No Wi-Fi interface found - exiting."; exit 1; }
    acquire_lock || { echo "Another instance is already running."; exit 0; }
    main_loop
    ;;

  *)
    echo "Unknown option: $1"
    usage
    exit 1
    ;;
esac
