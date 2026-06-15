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

[ -f "$MENU_SRC" ] || fail "limpet-menu.swift is missing"
swiftc -O "$MENU_SRC" -o "${TMPDIR:-/tmp}/limpet-menu-test"
pass "menu bar Swift source compiles"

grep -q 'limpet-menu' "$INSTALLER" || fail "install.sh does not install the menu helper"
grep -q 'com.georgeolaru.limpet.menu' "$INSTALLER" || fail "install.sh does not create/load the menu LaunchAgent"
pass "installer wires menu helper"

grep -q 'limpet-menu' "$UNINSTALLER" || fail "uninstall.sh does not remove the menu helper"
grep -q 'com.georgeolaru.limpet.menu' "$UNINSTALLER" || fail "uninstall.sh does not unload/remove the menu LaunchAgent"
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
