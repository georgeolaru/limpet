# =============================================================================
# config.example.sh  ->  copiaza in  ~/.config/limpet/config.sh
#
# Acest fisier este "sourced" (inclus) de limpet.sh, deci este shell
# normal. Pune AICI doar valorile pe care vrei sa le schimbi fata de implicit.
# NU pune parole sensibile in clar daca poti evita -> foloseste Keychain
# (vezi README, sectiunea Keychain).
# =============================================================================

# --- Retele cunoscute, in ordinea preferintei (acasa, birou, etc.) ----------
# Trebuie sa fie deja salvate in macOS (te-ai conectat manual la ele macar o data,
# ca sa fie memorate cu parola). Editeaza cu numele tale reale.
PREFERRED_SSIDS=( "Numele_Wifi_Acasa" "Numele_Wifi_Birou" )

# --- Hotspot iPhone ---------------------------------------------------------
# SSID-ul hotspotului = de obicei numele iPhone-ului
# (Settings -> General -> About -> Name).
HOTSPOT_SSID="iPhone-ul meu"

# Parola hotspotului:
#   - RECOMANDAT: las-o goala aici si pune-o in Keychain (vezi README).
#   - Alternativ (mai putin sigur): o poti pune direct aici intre ghilimele.
HOTSPOT_PASSWORD=""

# Numele "service" sub care e salvata parola in Keychain (lasa asa daca ai
# urmat instructiunile din README).
HOTSPOT_KEYCHAIN_SERVICE="limpet-hotspot"

# Incearca hotspotul si fara parola (daca reteaua e deja salvata in macOS). 1=da.
TRY_REMEMBERED_HOTSPOT=1

# Cand esti pe hotspot si internetul merge, incearca periodic sa revii pe una
# dintre retelele din PREFERRED_SSIDS. Util cand ajungi acasa/la birou.
PREFER_WIFI_OVER_HOTSPOT=1
PREFER_WIFI_CHECK_INTERVAL=300

# iPhone Personal Hotspot foloseste de obicei gateway in 172.20.10.x. Asta ne
# ajuta sa detectam hotspotul chiar cand macOS ascunde SSID-ul ca "<redacted>".
HOTSPOT_GATEWAY_PREFIXES=( "172.20.10." )

# --- Interfata Wi-Fi --------------------------------------------------------
# Lasa gol pentru auto-detect (recomandat). Pune "en0" doar daca vrei s-o fortezi.
WIFI_INTERFACE=""

# --- Intervale / timing (secunde) -------------------------------------------
CHECK_INTERVAL=45      # cat de des verifica cand internetul merge
MAX_INTERVAL=300       # plafonul de backoff cand nu gaseste nimic
ASSOC_TIMEOUT=12       # cat asteapta link+IP dupa o conectare
INTERNET_TIMEOUT=20    # cat asteapta internetul dupa o conectare
CURL_TIMEOUT=5
PING_TIMEOUT=2

# --- Logging ----------------------------------------------------------------
LOG_FILE="$HOME/Library/Logs/limpet.log"
MAX_LOG_BYTES=1048576  # 1 MB, dupa care roteste (pastreaza un .1)

# --- Avansat ----------------------------------------------------------------
USE_SCAN=1             # 1 = incearca scan best-effort inainte de join

# Tinte pentru testul de internet (de obicei nu trebuie schimbate).
PING_HOSTS=( "1.1.1.1" "8.8.8.8" )
CAPTIVE_URL="http://captive.apple.com/hotspot-detect.html"
CAPTIVE_EXPECT="Success"
HTTPS_FALLBACK_URL="https://1.1.1.1"
