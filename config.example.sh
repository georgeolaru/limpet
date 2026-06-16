# =============================================================================
# config.example.sh  ->  copy to  ~/.config/limpet/config.sh
#
# This file is "sourced" (included) by limpet.sh, so it is a normal shell
# file. Put ONLY the values you want to change from the defaults here.
# Do NOT keep sensitive passwords in cleartext if you can avoid it -> use the
# Keychain (see the README, Keychain section).
# =============================================================================

# --- Known networks, in order of preference (home, office, etc.) ------------
# They must already be saved in macOS (you connected to them manually at least
# once, so they're remembered with their password). Edit with your real names.
PREFERRED_SSIDS=( "Home_WiFi" "Office_WiFi" )

# --- Phone hotspot (iPhone, Android, anything) ------------------------------
# The hotspot SSID = the network name your phone broadcasts.
#   - iPhone: the iPhone's name (Settings -> General -> About -> Name).
#   - Android: the hotspot name you set under Settings -> Hotspot & tethering.
# It just has to be a network macOS has already saved (connected once).
HOTSPOT_SSID="My iPhone"

# Hotspot password:
#   - RECOMMENDED: leave it empty here and put it in the Keychain (see README).
#   - Alternatively (less secure): you can put it directly here, in quotes.
HOTSPOT_PASSWORD=""

# The "service" name under which the password is saved in the Keychain (leave
# as-is if you followed the README instructions).
HOTSPOT_KEYCHAIN_SERVICE="limpet-hotspot"

# Also try the hotspot without a password (if the network is already saved in
# macOS). 1=yes.
TRY_REMEMBERED_HOTSPOT=1

# When you're on hotspot and the internet works, periodically try to move back
# to one of the PREFERRED_SSIDS networks. Useful when you get home/to the office.
PREFER_WIFI_OVER_HOTSPOT=1
PREFER_WIFI_CHECK_INTERVAL=300

# Recognize the hotspot by its gateway range, so it works even when macOS hides
# the SSID as "<redacted>". iPhone uses 172.20.10.x; Android is commonly
# 192.168.43.x (varies by phone). Add your phone's range here -- find it by
# connecting once and running:  ~/.local/bin/limpet.sh --status
HOTSPOT_GATEWAY_PREFIXES=( "172.20.10." )

# --- macOS native Auto-Join Hotspot (same Apple ID) -------------------------
# If your Mac and iPhone share an Apple ID on macOS 26+ / iOS 26+, let macOS do
# the joining: Wi-Fi Settings > "Ask to join hotspots" > Automatic, Bluetooth on.
# macOS then joins your iPhone's hotspot over Bluetooth -- even a dormant one,
# which a password join can't wake. With this on, Limpet yields AUTOJOIN_WAIT_SECS
# to macOS before doing its own password join. Android / other Apple ID: set 0.
PREFER_AUTOJOIN_HOTSPOT=1
AUTOJOIN_WAIT_SECS=15

# --- Wi-Fi interface --------------------------------------------------------
# Leave empty for auto-detect (recommended). Set "en0" only to force it.
WIFI_INTERFACE=""

# --- Intervals / timing (seconds) -------------------------------------------
CHECK_INTERVAL=45      # how often it checks when the internet works
MAX_INTERVAL=300       # the backoff cap when it finds nothing
ASSOC_TIMEOUT=12       # how long it waits for link+IP after a connection
INTERNET_TIMEOUT=20    # how long it waits for the internet after a connection
CURL_TIMEOUT=5
PING_TIMEOUT=2

# --- Logging ----------------------------------------------------------------
LOG_FILE="$HOME/Library/Logs/limpet.log"
MAX_LOG_BYTES=1048576  # 1 MB, after which it rotates (keeps a .1)

# --- Advanced ---------------------------------------------------------------
USE_SCAN=1             # 1 = try a best-effort scan before a join

# Targets for the internet test (usually no need to change these).
PING_HOSTS=( "1.1.1.1" "8.8.8.8" )
CAPTIVE_URL="http://captive.apple.com/hotspot-detect.html"
CAPTIVE_EXPECT="Success"
HTTPS_FALLBACK_URL="https://1.1.1.1"
