# Limpet

> Keep your laptop online in your bag, using your phone hotspot after it leaves Wi-Fi.

Un script mic și robust pentru macOS care ține MacBook-ul conectat la internet cât
timp e deschis și treaz (ex: în rucsac, cu Amphetamine pornit). Dacă pierde
internetul, încearcă să se reconecteze la rețelele cunoscute și, în ultimă instanță,
la **hotspotul iPhone-ului** — automat, fără click-uri în UI.

Scop principal: agenții Claude / Codex care rulează pe Mac să aibă internet cât mai
mult timp posibil.

---

## 1. Cum funcționează

Rulează ca daemon (pornit de un LaunchAgent la login) și, în buclă:

1. **Verifică internet REAL** — nu se mulțumește cu „am IP / am gateway”. Folosește
   minim două metode:
   - `ping` direct pe `1.1.1.1` / `8.8.8.8` (reachability L3, fără DNS);
   - request HTTP la `captive.apple.com` (verifică DNS + HTTP + detectează captive portal);
   - fallback HTTPS direct pe `https://1.1.1.1` (verifică TLS fără DNS).
2. **Dacă merge → nu face nimic.** Nu schimbă rețeaua.
3. **Dacă nu merge → remediază**, în ordine:
   - A. lasă macOS să se re-conecteze singur la o rețea salvată și reverifică;
   - B. face un **Wi-Fi off/on** (repară multe cazuri „conectat dar mort”);
   - C. încearcă rețelele preferate din config (acasă, birou), în ordine;
   - D. încearcă **hotspotul iPhone** (parola din Keychain).
4. După fiecare încercare **reverifică** internetul real.
5. Dacă nimic nu merge → **retry cu backoff exponential** (45s → 90 → 180 → … → max 300s),
   ca să nu intre în loop agresiv și să nu consume CPU/baterie.
6. **Loguri clare** despre ce a încercat și ce a obținut.

Stările tratate separat: Wi-Fi conectat dar fără internet · Wi-Fi deconectat ·
hotspot indisponibil · hotspot prezent dar fără internet · captive portal.

### Adaptat pentru macOS modern (testat pe macOS 26 / Tahoe)
- **Nu se bazează pe citirea SSID-ului.** Pe macOS recent `networksetup -getairportnetwork`
  e nesigur (returnează „not associated” sau `<redacted>` deși ești conectat). Scriptul
  confirmă conectarea prin **link activ + IP + test real de internet**, nu prin nume.
- **Nu folosește binarul `airport`** (eliminat din macOS 14.4+). Scanarea e best-effort
  (`system_profiler`); dacă numele sunt ascunse, încearcă rețelele cunoscute „orb”.
- **Detectează automat interfața Wi-Fi** (nu presupune `en0`).
- Doar comenzi native: `networksetup`, `ifconfig`, `ipconfig`, `route`, `ping`, `curl`,
  `security`, `system_profiler`. Fără dependențe externe. Compatibil cu `bash 3.2` (cel din macOS).

---

## 2. Fișiere

| Fișier | Rol |
|---|---|
| `limpet.sh` | Scriptul principal (daemon + comenzi de diagnostic). |
| `limpet-menu.swift` | Companion nativ de menu bar (status + actiuni rapide). |
| `config.example.sh` | Șablon de configurare → copiat în `~/.config/limpet/config.sh`. |
| `com.georgeolaru.limpet.plist` | LaunchAgent (referință; `install.sh` generează unul cu căile corecte). |
| `install.sh` | Instalează și pornește totul. |
| `uninstall.sh` | Oprește și dezinstalează (`--purge` șterge și config + loguri). |

---

## 3. Instalare (rapidă)

```bash
cd limpet
bash install.sh
```

Instalatorul:
- copiază scriptul în `~/.local/bin/limpet.sh` (executabil);
- compilează status item-ul în `~/.local/bin/limpet-menu` dacă există `swiftc`;
- creează `~/.config/limpet/config.sh` din exemplu (dacă nu există);
- generează plist-urile cu căile reale în `~/Library/LaunchAgents/`;
- le încarcă în `launchd` (daemonul + menu bar-ul pornesc imediat și la fiecare login).

**Apoi obligatoriu:**
1. Editează configul (vezi secțiunea 6): `~/.config/limpet/config.sh`
2. Pune parola hotspotului în Keychain (secțiunea 5).
3. Conectează-te manual o dată la hotspot (secțiunea 4).

### Instalare manuală (dacă preferi pas cu pas)

```bash
# 1. Copiază scriptul și fă-l executabil
mkdir -p ~/.local/bin
cp limpet.sh ~/.local/bin/limpet.sh
chmod +x ~/.local/bin/limpet.sh

# 2. Configul
mkdir -p ~/.config/limpet
cp config.example.sh ~/.config/limpet/config.sh
# editează ~/.config/limpet/config.sh

# 3. Plist-ul în LaunchAgents (editează căile dacă user-ul tău nu e 'georgeolaru')
cp com.georgeolaru.limpet.plist ~/Library/LaunchAgents/

# 4. Încarcă-l
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.georgeolaru.limpet.plist
# (pe macOS mai vechi: launchctl load -w ~/Library/LaunchAgents/com.georgeolaru.limpet.plist)
```

---

## 4. Conectarea inițială la hotspot (o singură dată, manual)

Ca scriptul să se poată conecta automat, rețeaua hotspotului trebuie să existe în macOS:

1. Pe iPhone: **Settings → Personal Hotspot → Allow Others to Join = ON**.
   (Util și „Maximize Compatibility” dacă MacBook-ul nu-l vede.)
2. Numele hotspotului (SSID) = numele iPhone-ului: **Settings → General → About → Name**.
3. Pe MacBook: din meniul Wi-Fi conectează-te **o dată manual** la hotspot și
   bifează „Remember this network”. Așa macOS salvează rețeaua + parola.
4. Pune exact acel nume în config la `HOTSPOT_SSID`.

> Notă: și rețelele de acasă/birou din `PREFERRED_SSIDS` trebuie conectate manual o
> dată, ca să fie memorate cu parolă. Scriptul se bazează pe credențialele salvate.

---

## 5. Parola hotspotului în Keychain (recomandat)

Ca să nu ții parola în clar în fișier, pune-o în Keychain (numele „service” implicit e
`limpet-hotspot`, iar „account” = SSID-ul hotspotului):

```bash
# înlocuiește SSID-ul și parola
security add-generic-password \
  -s "limpet-hotspot" \
  -a "iPhone-ul meu" \
  -w "PAROLA_HOTSPOT" \
  -U
```

Scriptul o citește singur cu `security find-generic-password -w`. Lasă
`HOTSPOT_PASSWORD=""` în config.

- Verifică: `security find-generic-password -s "limpet-hotspot" -a "iPhone-ul meu" -w`
- Prima dată, macOS poate cere o confirmare „allow access”. Apasă **Always Allow**.
- Alternativă mai puțin sigură: pune parola direct în config la `HOTSPOT_PASSWORD`.
- Dacă te-ai conectat deja manual la hotspot (secțiunea 4), scriptul poate funcționa și
  fără parolă (folosește credențialele salvate de macOS) — `TRY_REMEMBERED_HOTSPOT=1`.

---

## 6. Configurare

Editează `~/.config/limpet/config.sh`. Cele mai importante:

```sh
PREFERRED_SSIDS=( "Wifi_Acasa" "Wifi_Birou" )   # în ordinea preferinței
HOTSPOT_SSID="iPhone-ul meu"                     # numele exact al hotspotului
HOTSPOT_PASSWORD=""                              # gol = ia din Keychain
PREFER_WIFI_OVER_HOTSPOT=1                       # revine automat de pe hotspot pe Wi-Fi
PREFER_WIFI_CHECK_INTERVAL=300                   # o data la 5 minute cand pare pe hotspot
HOTSPOT_GATEWAY_PREFIXES=( "172.20.10." )        # detectie iPhone cand SSID e redacted
CHECK_INTERVAL=45                                # secunde între verificări când merge
MAX_INTERVAL=300                                 # plafon backoff la eșec
LOG_FILE="$HOME/Library/Logs/limpet.log"
```

### Revenirea automată de pe hotspot pe Wi-Fi

Când internetul merge, daemonul nu schimbă rețeaua în mod normal. Excepția este
`PREFER_WIFI_OVER_HOTSPOT=1`: dacă conexiunea curentă pare a fi hotspotul iPhone-ului,
la fiecare `PREFER_WIFI_CHECK_INTERVAL` secunde încearcă rețelele din
`PREFERRED_SSIDS`, în ordine. Schimbă rețeaua doar dacă noua rețea are internet real.
Dacă nu găsește Wi-Fi bun, rămâne pe hotspot sau încearcă să revină pe hotspot.

Pe macOS recent SSID-ul poate apărea ca `<redacted>`. `sudo` nu rezolvă de obicei
asta, pentru că vizibilitatea SSID-ului este legată de Location Services, nu doar de
privilegii Unix. Pentru iPhone Personal Hotspot, scriptul detectează și gateway-ul
standard `172.20.10.x`, deci poate decide că e pe hotspot chiar când numele e ascuns.

După orice modificare în config, **repornește** agentul:

```bash
launchctl kickstart -k gui/$(id -u)/com.georgeolaru.limpet
```

---

## 7. Pornire / oprire / verificare

```bash
# Pornește (sau repornește) la cerere
launchctl kickstart -k gui/$(id -u)/com.georgeolaru.limpet

# Oprește temporar
launchctl bootout gui/$(id -u)/com.georgeolaru.limpet

# Pornește din nou
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.georgeolaru.limpet.plist

# Starea agentului (caută 'state' și 'pid')
launchctl print gui/$(id -u)/com.georgeolaru.limpet | grep -E 'state|pid|last exit'

# Logurile (cel mai util)
tail -f ~/Library/Logs/limpet.log
```

Exemplu de loguri:
```
2026-06-15 10:00:01 limpet started (iface=en0, interval=45s, ...).
2026-06-15 10:00:01 Internet OK (route=en0, ssid=<redacted>).
2026-06-15 10:42:13 No internet detected. ssid=(unknown).
2026-06-15 10:42:19 Cycling Wi-Fi power to force reassociation.
2026-06-15 10:42:35 Attempting to join 'iPhone-ul meu'.
2026-06-15 10:42:41   Internet OK via 'iPhone-ul meu' (ssid now: <redacted>).
2026-06-15 10:42:41 Remediation succeeded.
```

---

## 8. Menu bar status

Instalarea pornește și un companion mic în menu bar. El nu face monitorizarea direct;
doar citește statusul daemonului și rulează acțiuni sigure peste script/launchd.

Ce vezi în meniu:
- status internet: OK / DOWN / captive portal;
- starea LaunchAgent-ului și PID-ul daemonului;
- interfața Wi-Fi, IP-ul, ruta implicită și SSID-ul best-effort;
- ultima linie din log.

Acțiuni disponibile:
- **Refresh Status** — recitește statusul;
- **Check Internet Now** — rulează `limpet.sh --check`;
- **Prefer Wi-Fi Now** — dacă ești pe hotspot, încearcă imediat rețelele preferate;
- **Restart Agent** — face `launchctl kickstart -k` pentru daemon;
- **Stop Agent** — oprește daemonul, fără să șteargă instalarea;
- **Show Details**, **Open Log**, **Edit Config**.

Menu bar-ul are propriul LaunchAgent:

```bash
launchctl print gui/$(id -u)/com.georgeolaru.limpet.menu | grep -E 'state|pid'
```

Dacă închizi doar menu bar-ul din „Quit Menu”, daemonul continuă să ruleze. La următorul
login menu bar-ul pornește din nou.

---

## 9. Debugging

Scriptul are comenzi de diagnostic care **nu modifică nimic** (read-only), plus moduri
de test. Rulează direct binarul instalat:

```bash
SCRIPT=~/.local/bin/limpet.sh

"$SCRIPT" --check     # doar verifică internetul: OK / CAPTIVE / DOWN  (exit code 0/2/1)
"$SCRIPT" --status    # interfață, putere Wi-Fi, link, IP, rută, SSID, internet, config
"$SCRIPT" --scan      # rețele vizibile (best-effort; pot fi ascunse pe macOS recent)
"$SCRIPT" --prefer-wifi-now   # dacă ești pe hotspot, încearcă imediat Wi-Fi preferat
"$SCRIPT" --once      # o singură verificare + remediere, cu log pe ecran (test sigur)
"$SCRIPT" --test-join "SSID" "parola"   # testează manual conectarea la o rețea
"$SCRIPT" --help
```

Probleme frecvente:

- **„Internet OK” dar tot pierd netul în tranzit** — normal: scriptul reacționează la
  următoarea verificare (max `CHECK_INTERVAL` secunde) și apoi remediază.
- **`--scan` arată `<redacted>` / gol** — e privacy-ul macOS (lipsă permisiune Location).
  Nu e o problemă: daemonul încearcă rețelele cunoscute „orb”. Dacă vrei nume reale,
  acordă Location Services procesului.
- **Nu se conectează la hotspot** — verifică: Personal Hotspot e pornit pe iPhone;
  `HOTSPOT_SSID` e exact numele iPhone-ului; te-ai conectat manual o dată; parola e în
  Keychain. Testează: `"$SCRIPT" --test-join "iPhone-ul meu" "parola"`.
- **Join-ul eșuează cu „Could not find network”** — rețeaua nu e în rază sau numele e
  greșit. Pentru hotspot: deschide ecranul Personal Hotspot pe iPhone (îl face vizibil).
- **`networksetup` cere parolă de admin** — rar; rulează contul ca admin. Dacă persistă,
  poți permite comanda fără parolă, dar de obicei nu e necesar pentru join/power.
- **Agentul nu pornește** — vezi `~/Library/Logs/limpet.err.log` și
  `launchctl print gui/$(id -u)/com.georgeolaru.limpet`.
- **Vreau loguri mai puține/mai multe** — schimbă `CHECK_INTERVAL` / `MAX_INTERVAL`.
  Când netul merge, scriptul loghează doar la tranziții, ca să nu umple fișierul.

---

## 10. Dezinstalare

```bash
bash uninstall.sh           # oprește + șterge agentul și scriptul (păstrează config+loguri)
bash uninstall.sh --purge   # șterge tot, inclusiv config și loguri
```

---

## 11. Note de securitate / resurse

- Parola hotspotului stă în **Keychain**, nu în script.
- Daemonul stă „adormit” aproape tot timpul (un `sleep` lung între verificări) →
  consum CPU/baterie neglijabil. `ProcessType=Background` + `LowPriorityIO` în plist.
- Rulează ca **LaunchAgent** (per-utilizator), ca să aibă acces la Keychain-ul tău și să
  poată gestiona Wi-Fi fără sudo. Nu depinde de SSH sau de internet ca să pornească.
- Logul se rotește singur la ~1 MB (`limpet.log` → `limpet.log.1`).
