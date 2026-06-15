#!/bin/bash
# =============================================================================
# limpet.sh
#
# Mentine MacBook-ul conectat la internet cat timp este deschis si treaz.
#
# Logica, pe scurt:
#   1. Verifica daca exista internet REAL (nu doar IP / gateway).
#   2. Daca merge -> nu face nimic (NU schimba reteaua).
#   3. Daca nu merge -> incearca, in ordine:
#        a) lasa macOS sa se reconecteze singur la o retea salvata;
#        b) face un "Wi-Fi off/on" ca sa forteze re-asocierea;
#        c) incearca retelele cunoscute preferate (acasa / birou);
#        d) incearca hotspotul iPhone-ului (parola din Keychain).
#   4. Dupa fiecare incercare reverifica internetul.
#   5. Daca nimic nu merge -> retry cu backoff (nu loop agresiv).
#   6. Scrie loguri clare despre ce a incercat si ce a obtinut.
#
# Proiectat pentru macOS modern (testat pe macOS 26 / Tahoe, bash 3.2):
#   - NU se bazeaza pe citirea SSID-ului (networksetup -getairportnetwork e
#     nesigur / "redacted" pe macOS recent).
#   - NU foloseste binarul "airport" (eliminat din macOS 14.4+).
#   - Detecteaza interfata Wi-Fi automat (nu presupune en0).
#   - Foloseste doar comenzi native macOS: networksetup, ifconfig, ipconfig,
#     route, ping, curl, security, system_profiler.
#
# Moduri de rulare:
#   limpet.sh                 -> ruleaza ca daemon (bucla cu backoff)
#   limpet.sh --once          -> o singura verificare + remediere
#   limpet.sh --check         -> doar verifica internetul (read-only)
#   limpet.sh --status        -> afiseaza starea curenta (read-only)
#   limpet.sh --scan          -> retele Wi-Fi vizibile (best-effort)
#   limpet.sh --prefer-wifi-now -> daca esti pe hotspot, incearca Wi-Fi preferat
#   limpet.sh --test-join SSID [parola]  -> testeaza conectarea manuala
#   limpet.sh --help
# =============================================================================

# ------------------------------------------------------------------------------
# 1) VALORI IMPLICITE (pot fi suprascrise din fisierul de config)
# ------------------------------------------------------------------------------
# Retele cunoscute, in ordinea preferintei (acasa, birou ...). Trebuie sa fie
# deja salvate in macOS (conectate manual o data).
PREFERRED_SSIDS=( "HomeWiFi" "OfficeWiFi" )

# Hotspotul iPhone-ului.
HOTSPOT_SSID="iPhone"
HOTSPOT_PASSWORD=""                       # lasa gol; ideal pui parola in Keychain
HOTSPOT_KEYCHAIN_SERVICE="limpet-hotspot"
TRY_REMEMBERED_HOTSPOT=1                   # 1 = incearca si fara parola (retea salvata)

# Daca esti pe hotspot, incearca periodic sa revii pe Wi-Fi real preferat.
# Pe macOS recent SSID-ul poate fi "<redacted>", asa ca detectam iPhone hotspot
# si dupa gateway-ul standard folosit de Personal Hotspot (172.20.10.x).
PREFER_WIFI_OVER_HOTSPOT=1
PREFER_WIFI_CHECK_INTERVAL=300             # cat de des incearca upgrade-ul de pe hotspot
HOTSPOT_GATEWAY_PREFIXES=( "172.20.10." )

# Interfata Wi-Fi. Gol = auto-detect din networksetup -listallhardwareports.
WIFI_INTERFACE=""

# Intervale / timeouts (secunde).
CHECK_INTERVAL=45                          # cat de des verifica cand totul e ok
MAX_INTERVAL=300                           # plafonul de backoff la esec repetat
ASSOC_TIMEOUT=12                           # asteptare link+IP dupa join
INTERNET_TIMEOUT=20                        # asteptare internet dupa join
CURL_TIMEOUT=5
PING_TIMEOUT=2

# Logging.
LOG_FILE="$HOME/Library/Logs/limpet.log"
MAX_LOG_BYTES=1048576                      # 1 MB -> rotatie simpla (pastreaza .1)
VERBOSE=0                                  # 1 = scrie si pe stderr (util la --once)

# Comportament scanare.
USE_SCAN=1                                 # 1 = best-effort scan ca sa evite join inutil

# Tinte pentru testul de conectivitate.
PING_HOSTS=( "1.1.1.1" "8.8.8.8" )
CAPTIVE_URL="http://captive.apple.com/hotspot-detect.html"
CAPTIVE_EXPECT="Success"
HTTPS_FALLBACK_URL="https://1.1.1.1"       # HTTPS direct pe IP (nu necesita DNS)

# ------------------------------------------------------------------------------
# 2) INCARCA CONFIGURAREA UTILIZATORULUI (suprascrie valorile de mai sus)
# ------------------------------------------------------------------------------
CONFIG_FILE="${LIMPET_CONFIG:-$HOME/.config/limpet/config.sh}"
if [ -f "$CONFIG_FILE" ]; then
  # shellcheck disable=SC1090
  . "$CONFIG_FILE"
fi

# Coduri de stare pentru testul de internet.
INET_OK=0        # internet real
INET_DOWN=1      # nicio conectivitate
INET_CAPTIVE=2   # conectat, dar captive portal / fara internet real

# ------------------------------------------------------------------------------
# 3) UTILITARE: logging
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
# 4) UTILITARE: interfata Wi-Fi / stare link
# ------------------------------------------------------------------------------
detect_iface() {
  if [ -n "$WIFI_INTERFACE" ]; then
    printf '%s' "$WIFI_INTERFACE"
    return 0
  fi
  networksetup -listallhardwareports 2>/dev/null \
    | awk '/Hardware Port: (Wi-Fi|AirPort)/{getline; print $2; exit}'
}

# Link Wi-Fi activ (asociat la o retea, indiferent de internet)?
link_active() {
  ifconfig "$IFACE" 2>/dev/null | grep -q "status: active"
}

# Are IP pe interfata?
has_ip() {
  ipconfig getifaddr "$IFACE" >/dev/null 2>&1
}

# Interfata folosita pentru ruta default (en0, en7 ethernet, etc.) - doar info.
default_iface() {
  route -n get default 2>/dev/null | awk '/interface:/{print $2; exit}'
}

default_gateway() {
  route -n get default 2>/dev/null | awk '/gateway:/{print $2; exit}'
}

# SSID curent - BEST EFFORT. Pe macOS recent poate fi gol/"redacted".
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

# Off/On rapid ca sa forteze re-asocierea (repara multe cazuri "conectat dar mort").
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
# 5) TESTUL DE INTERNET (minim doua metode + detectie captive portal)
#    Returneaza: 0 = internet real, 1 = down, 2 = captive portal.
# ------------------------------------------------------------------------------
probe_internet() {
  local body l3=1 h

  # (a) Reachability L3, fara DNS: ping direct pe IP-uri stabile.
  for h in "${PING_HOSTS[@]}"; do
    if ping -c1 -t"$PING_TIMEOUT" "$h" >/dev/null 2>&1; then
      l3=0
      break
    fi
  done

  # (b) Test HTTP captive-portal Apple (exercita si DNS, si HTTP).
  body=$(curl -s -m "$CURL_TIMEOUT" "$CAPTIVE_URL" 2>/dev/null)
  if [ -n "$body" ]; then
    case "$body" in
      *"$CAPTIVE_EXPECT"*) return $INET_OK ;;     # raspuns corect -> internet real
      *)                   return $INET_CAPTIVE ;; # alt continut -> captive portal
    esac
  fi

  # (c) HTTP a esuat (DNS rupt sau apple blocat). Daca avem L3 + HTTPS pe IP -> ok.
  if [ "$l3" -eq 0 ] && curl -fs -m "$CURL_TIMEOUT" -o /dev/null "$HTTPS_FALLBACK_URL" 2>/dev/null; then
    return $INET_OK
  fi

  return $INET_DOWN
}

# ------------------------------------------------------------------------------
# 6) SCANARE (best-effort). Pe macOS recent poate fi goala -> atunci incercam orb.
# ------------------------------------------------------------------------------
scan_networks() {
  [ "$USE_SCAN" -eq 1 ] || return 0
  # Extrage numele retelelor: o linie "Nume:" urmata imediat de "PHY Mode:".
  system_profiler SPAirPortDataType 2>/dev/null | awk '
    /Current Network Information:|Other Local Wi-Fi Networks:/ { grab=1 }
    grab {
      if (prev ~ /:[[:space:]]*$/ && $0 ~ /PHY Mode:/) {
        name = prev
        sub(/^[[:space:]]+/, "", name)
        sub(/:[[:space:]]*$/, "", name)
        # Pe macOS recent, fara permisiune Location, numele apar "<redacted>".
        # Le ignoram -> lista devine goala -> incercam retelele cunoscute "orb".
        if (name != "" && name != "<redacted>") print name
      }
      prev = $0
    }'
}

network_visible() {
  local ssid="$1" list="$2"
  [ -z "$list" ] && return 0                  # scan necunoscut -> permite incercarea
  printf '%s\n' "$list" | grep -Fxq "$ssid"
}

# ------------------------------------------------------------------------------
# 7) CONECTARE + VERIFICARE
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
# 8) REMEDIERE (rulata DOAR cand nu exista internet)
# ------------------------------------------------------------------------------
remediate() {
  ensure_wifi_on

  # Faza A: lasa macOS sa se auto-reconecteze la o retea salvata, apoi reverifica.
  if wait_for_link 6; then
    if probe_internet; then
      log "Recovered via existing/auto-joined network."
      return 0
    fi
  fi

  # Faza B: bounce Wi-Fi o data (repara multe "conectat dar fara internet").
  wifi_bounce
  if probe_internet; then
    log "Recovered after Wi-Fi power cycle."
    return 0
  fi

  # Faza C: scan best-effort + join explicit.
  local visible
  visible=$(scan_networks)
  log_visible_networks "$visible"

  # C1: retele preferate cunoscute, in ordinea preferintei (folosesc parola salvata).
  try_preferred_networks "$visible" && return 0

  # C2: hotspot iPhone (ultima solutie). Instant Hotspot poate sa nu apara in scan,
  # asa ca incercam oricum.
  if [ -n "$HOTSPOT_SSID" ]; then
    if ! network_visible "$HOTSPOT_SSID" "$visible"; then
      log "Hotspot '$HOTSPOT_SSID' not seen in scan (instant hotspot may be hidden); trying anyway."
    fi
    try_hotspot && return 0
  fi

  return 1
}

# ------------------------------------------------------------------------------
# 9) BUCLA PRINCIPALA (daemon) cu backoff exponential
# ------------------------------------------------------------------------------
main_loop() {
  log "limpet started (iface=$IFACE, interval=${CHECK_INTERVAL}s, config=$CONFIG_FILE)."
  local interval="$CHECK_INTERVAL" fails=0 rc prev="unknown" shift_n now last_prefer_wifi_check=0

  while true; do
    rotate_log_if_big
    probe_internet; rc=$?

    if [ "$rc" -eq "$INET_OK" ]; then
      # Internet ok -> NU atingem reteaua. Logam doar la tranzitie (loguri curate).
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
# 10) LOCK: o singura instanta (pentru daemon / --once)
# ------------------------------------------------------------------------------
LOCK_DIR=""
acquire_lock() {
  LOCK_DIR="${TMPDIR:-/tmp}/limpet.lock"
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    printf '%s' "$$" > "$LOCK_DIR/pid" 2>/dev/null
    trap 'release_lock' EXIT INT TERM
    return 0
  fi
  # Exista lock - mai e viu procesul?
  local oldpid
  oldpid=$(cat "$LOCK_DIR/pid" 2>/dev/null)
  if [ -n "$oldpid" ] && kill -0 "$oldpid" 2>/dev/null; then
    return 1
  fi
  # Lock vechi (stale) -> il preluam.
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
  sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'
}

# ------------------------------------------------------------------------------
# 11) PORNIRE
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
      echo "Numele retelelor sunt probabil ascunse ('<redacted>') fara permisiune"
      echo "Location Services. Nu e o problema: daemonul va incerca retelele cunoscute"
      echo "din config 'orb' (oricum cea mai robusta cale). Daca vrei optimizarea prin"
      echo "scan, activeaza Location Services pentru procesul care ruleaza scriptul."
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
