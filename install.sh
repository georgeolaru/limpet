#!/bin/bash
# =============================================================================
# install.sh - installs limpet as a LaunchAgent (start at login).
#
# What it does:
#   1. Copies limpet.sh to ~/.local/bin/ and makes it executable.
#   2. Builds the menu-bar app as ~/Applications/Limpet.app.
#   3. Creates ~/.config/limpet/config.sh from the example (if it doesn't exist).
#   4. Generates the plists with the correct paths in ~/Library/LaunchAgents/.
#   5. Loads (bootstraps) the agents into launchd.
#
# Run:  bash install.sh
# =============================================================================
set -e

LABEL="com.georgeolaru.limpet"
MENU_LABEL="com.georgeolaru.limpet.menu"
SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
BIN_DIR="$HOME/.local/bin"
SCRIPT_DST="$BIN_DIR/limpet.sh"
MENU_SRC="$SRC_DIR/limpet-menu.swift"
MENU_APP_DIR="$HOME/Applications"
MENU_APP_DST="$MENU_APP_DIR/Limpet.app"
MENU_EXEC_DST="$MENU_APP_DST/Contents/MacOS/limpet-menu"
MENU_RESOURCES_DST="$MENU_APP_DST/Contents/Resources"
MENU_ICON_SRC="$SRC_DIR/assets/AppIcon.icns"
MENU_BAR_ICON_NAMES=(
  MenuBarIconTemplate
  MenuBarIconTemplateOK
  MenuBarIconTemplateDown
  MenuBarIconTemplateCaptive
  MenuBarIconTemplateUnknown
)
CONFIG_DIR="$HOME/.config/limpet"
CONFIG_DST="$CONFIG_DIR/config.sh"
AGENTS_DIR="$HOME/Library/LaunchAgents"
PLIST_DST="$AGENTS_DIR/$LABEL.plist"
MENU_PLIST_DST="$AGENTS_DIR/$MENU_LABEL.plist"
LOG_DIR="$HOME/Library/Logs"

echo "==> limpet installer"

# Remove the pre-rename bundle if it exists (the app used to be "Limpet Menu.app").
rm -rf "$MENU_APP_DIR/Limpet Menu.app" 2>/dev/null || true

# 1. Script
mkdir -p "$BIN_DIR"
cp "$SRC_DIR/limpet.sh" "$SCRIPT_DST"
chmod +x "$SCRIPT_DST"
echo "  - script        : $SCRIPT_DST"

# Installed uninstaller (also used by the menu app's "Uninstall Limpet…").
if [ -f "$SRC_DIR/uninstall.sh" ]; then
  cp "$SRC_DIR/uninstall.sh" "$BIN_DIR/limpet-uninstall.sh"
  chmod +x "$BIN_DIR/limpet-uninstall.sh"
  echo "  - uninstaller   : $BIN_DIR/limpet-uninstall.sh"
fi

# 2. Menu bar helper
if [ -f "$MENU_SRC" ] && command -v swiftc >/dev/null 2>&1; then
  mkdir -p "$MENU_APP_DIR" "$MENU_APP_DST/Contents/MacOS" "$MENU_RESOURCES_DST"
  swiftc -O "$MENU_SRC" -o "$MENU_EXEC_DST"
  chmod +x "$MENU_EXEC_DST"

  if [ -f "$MENU_ICON_SRC" ]; then
    cp "$MENU_ICON_SRC" "$MENU_RESOURCES_DST/AppIcon.icns"
  else
    echo "  - menu icon     : skipped (assets/AppIcon.icns missing)"
  fi
  for icon_name in "${MENU_BAR_ICON_NAMES[@]}"; do
    if [ -f "$SRC_DIR/assets/$icon_name.png" ]; then
      cp "$SRC_DIR/assets/$icon_name.png" "$MENU_RESOURCES_DST/$icon_name.png"
    else
      echo "  - menu bar icon : skipped (assets/$icon_name.png missing)"
    fi
  done

  cat > "$MENU_APP_DST/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDisplayName</key>
  <string>Limpet</string>
  <key>CFBundleExecutable</key>
  <string>limpet-menu</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon.icns</string>
  <key>CFBundleIdentifier</key>
  <string>$MENU_LABEL</string>
  <key>CFBundleName</key>
  <string>Limpet</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
PLIST
  echo "  - menu app      : $MENU_APP_DST"
elif [ -f "$MENU_SRC" ]; then
  echo "  - menu helper   : skipped (swiftc not found)"
else
  echo "  - menu helper   : skipped (source missing)"
fi

# 3. Config (don't overwrite an existing one)
mkdir -p "$CONFIG_DIR"
if [ -f "$CONFIG_DST" ]; then
  echo "  - config        : $CONFIG_DST (already exists, not overwriting)"
else
  cp "$SRC_DIR/config.example.sh" "$CONFIG_DST"
  echo "  - config        : $CONFIG_DST (created from the example - EDIT IT!)"
fi

# 4. Logs
mkdir -p "$LOG_DIR"

# 5. Daemon plist generated with the real paths
mkdir -p "$AGENTS_DIR"
cat > "$PLIST_DST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>$SCRIPT_DST</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>ThrottleInterval</key>
  <integer>10</integer>
  <key>ProcessType</key>
  <string>Background</string>
  <key>LowPriorityIO</key>
  <true/>
  <key>StandardOutPath</key>
  <string>$LOG_DIR/limpet.out.log</string>
  <key>StandardErrorPath</key>
  <string>$LOG_DIR/limpet.err.log</string>
</dict>
</plist>
PLIST
echo "  - LaunchAgent   : $PLIST_DST"

if [ -x "$MENU_EXEC_DST" ]; then
cat > "$MENU_PLIST_DST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$MENU_LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$MENU_EXEC_DST</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>StandardOutPath</key>
  <string>$LOG_DIR/limpet-menu.out.log</string>
  <key>StandardErrorPath</key>
  <string>$LOG_DIR/limpet-menu.err.log</string>
</dict>
</plist>
PLIST
  echo "  - MenuAgent     : $MENU_PLIST_DST"
fi

# 6. Load into launchd (modern: bootstrap; fallback: load -w)
UID_NUM="$(id -u)"

load_agent() {
  local label="$1"
  local plist="$2"
  local name="$3"
  local spec="gui/$UID_NUM/$label"
  local attempt=1

  launchctl bootout "$spec" 2>/dev/null || true

  while [ "$attempt" -le 5 ]; do
    if launchctl bootstrap "gui/$UID_NUM" "$plist" 2>/dev/null; then
      echo "  - $name bootstrap OK"
      launchctl enable "$spec" 2>/dev/null || true
      return 0
    fi
    sleep 1
    attempt=$((attempt + 1))
  done

  if launchctl print "$spec" >/dev/null 2>&1; then
    launchctl kickstart -k "$spec" 2>/dev/null || true
    echo "  - $name already loaded; kickstart requested"
    return 0
  fi

  echo "  - $name bootstrap failed, trying 'launchctl load -w'..."
  launchctl load -w "$plist"
  echo "  - $name load -w OK"
}

echo "==> Loading into launchd..."
load_agent "$LABEL" "$PLIST_DST" "daemon"

if [ -x "$MENU_EXEC_DST" ]; then
  load_agent "$MENU_LABEL" "$MENU_PLIST_DST" "menu"
fi

echo
echo "Done. Check the state with:"
echo "  launchctl print gui/$UID_NUM/$LABEL | grep -E 'state|pid'"
echo "  launchctl print gui/$UID_NUM/$MENU_LABEL | grep -E 'state|pid'"
echo "  tail -f \"$LOG_DIR/limpet.log\""
echo
echo "IMPORTANT:"
echo "  1. Edit the config:   $CONFIG_DST"
echo "  2. Put the hotspot password in the Keychain (see README) or in the config."
echo "  3. Connect to the hotspot manually once so it gets saved in macOS."
