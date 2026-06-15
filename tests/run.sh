#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

pass() {
  printf 'PASS: %s\n' "$*"
}

MENU_SRC="$ROOT_DIR/limpet-menu.swift"
INSTALLER="$ROOT_DIR/install.sh"
UNINSTALLER="$ROOT_DIR/uninstall.sh"
ICON_SVG="$ROOT_DIR/assets/limpet-icon.svg"
ICON_ICNS="$ROOT_DIR/assets/AppIcon.icns"
MENU_BAR_ICON_NAMES=(
  MenuBarIconTemplate
  MenuBarIconTemplateOK
  MenuBarIconTemplateDown
  MenuBarIconTemplateCaptive
  MenuBarIconTemplateUnknown
)

[ -f "$MENU_SRC" ] || fail "limpet-menu.swift is missing"
swiftc -O "$MENU_SRC" -o "${TMPDIR:-/tmp}/limpet-menu-test"
pass "menu bar Swift source compiles"

grep -q 'NSStatusItem.squareLength' "$MENU_SRC" || fail "menu bar status item is not icon-sized"
grep -q 'MenuBarIconTemplateOK' "$MENU_SRC" || fail "menu bar status item does not load the OK template icon"
grep -q 'MenuBarIconTemplateDown' "$MENU_SRC" || fail "menu bar status item does not load the down template icon"
grep -q 'MenuBarIconTemplateCaptive' "$MENU_SRC" || fail "menu bar status item does not load the captive template icon"
grep -q 'MenuBarIconTemplateUnknown' "$MENU_SRC" || fail "menu bar status item does not load the unknown template icon"
grep -q 'menuBarIconState' "$MENU_SRC" || fail "menu bar status item does not map internet status to icon state"
grep -q 'image.isTemplate = true' "$MENU_SRC" || fail "menu bar status item does not use a template image"
if grep -q 'wifi.slash' "$MENU_SRC"; then
  fail "menu bar status item still uses SF Wi-Fi status symbols"
fi
pass "menu bar uses the template app icon"

[ -f "$ICON_SVG" ] || fail "app icon SVG is missing"
grep -q 'width="1254" height="1254"' "$ICON_SVG" || fail "app icon SVG does not preserve the 1254x1254 source canvas"
grep -q 'data:image/png;base64,' "$ICON_SVG" || fail "app icon SVG is not a pixel-exact embedded PNG"
[ -f "$ICON_ICNS" ] || fail "app icon icns is missing"
file "$ICON_ICNS" | grep -q 'Mac OS X icon' || fail "app icon icns is invalid"
for icon_name in "${MENU_BAR_ICON_NAMES[@]}"; do
  icon_path="$ROOT_DIR/assets/$icon_name.png"
  [ -f "$icon_path" ] || fail "menu bar template icon is missing: $icon_name"
  file "$icon_path" | grep -q 'gray+alpha' || fail "menu bar template icon is not transparent gray+alpha: $icon_name"
done
pass "app icon assets are present"

grep -q 'limpet-menu' "$INSTALLER" || fail "install.sh does not install the menu helper"
grep -q 'com.georgeolaru.limpet.menu' "$INSTALLER" || fail "install.sh does not create/load the menu LaunchAgent"
grep -q 'Limpet Menu.app' "$INSTALLER" || fail "install.sh does not install the menu helper as an app bundle"
grep -q 'AppIcon.icns' "$INSTALLER" || fail "install.sh does not install the app icon"
grep -q 'MenuBarIconTemplateOK' "$INSTALLER" || fail "install.sh does not install the OK menu bar template icon"
grep -q 'MenuBarIconTemplateDown' "$INSTALLER" || fail "install.sh does not install the down menu bar template icon"
grep -q 'MenuBarIconTemplateCaptive' "$INSTALLER" || fail "install.sh does not install the captive menu bar template icon"
grep -q 'MenuBarIconTemplateUnknown' "$INSTALLER" || fail "install.sh does not install the unknown menu bar template icon"
pass "installer wires menu helper"

grep -q 'limpet-menu' "$UNINSTALLER" || fail "uninstall.sh does not remove the menu helper"
grep -q 'com.georgeolaru.limpet.menu' "$UNINSTALLER" || fail "uninstall.sh does not unload/remove the menu LaunchAgent"
grep -q 'Limpet Menu.app' "$UNINSTALLER" || fail "uninstall.sh does not remove the menu app bundle"
pass "uninstaller wires menu helper"

for script in "$ROOT_DIR/limpet.sh" "$INSTALLER" "$UNINSTALLER" "$0"; do
  bash -n "$script"
done
pass "shell scripts parse"

plutil -lint "$ROOT_DIR/com.georgeolaru.limpet.plist" >/dev/null
pass "daemon plist is valid"

grep -q '^PREFER_WIFI_OVER_HOTSPOT=' "$ROOT_DIR/config.example.sh" || fail "config.example.sh lacks PREFER_WIFI_OVER_HOTSPOT"
grep -q '^PREFER_WIFI_CHECK_INTERVAL=' "$ROOT_DIR/config.example.sh" || fail "config.example.sh lacks PREFER_WIFI_CHECK_INTERVAL"
grep -q '^HOTSPOT_GATEWAY_PREFIXES=' "$ROOT_DIR/config.example.sh" || fail "config.example.sh lacks HOTSPOT_GATEWAY_PREFIXES"
pass "config exposes prefer-wifi-over-hotspot controls"

grep -q 'prefer_wifi_over_hotspot' "$ROOT_DIR/limpet.sh" || fail "limpet.sh lacks prefer_wifi_over_hotspot implementation"
grep -q -- '--prefer-wifi-now' "$ROOT_DIR/limpet.sh" || fail "limpet.sh lacks --prefer-wifi-now command"
grep -q 'Preferred Wi-Fi check ended on non-hotspot connection' "$ROOT_DIR/limpet.sh" || fail "prefer-wifi does not treat macOS auto-roam off hotspot as success"
grep -q 'Prefer Wi-Fi Now' "$MENU_SRC" || fail "menu helper lacks Prefer Wi-Fi Now action"
pass "prefer-wifi command surface is wired"
