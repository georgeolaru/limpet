#!/bin/bash
# =============================================================================
# uninstall.sh - stops and uninstalls limpet.
#
# Keeps the config and the logs (so you don't lose your settings). Removes only
# the agent and the installed script. Run with --purge to also delete config+logs.
# =============================================================================
set -e

LABEL="com.georgeolaru.limpet"
MENU_LABEL="com.georgeolaru.limpet.menu"
UID_NUM="$(id -u)"
BIN_DST="$HOME/.local/bin/limpet.sh"
MENU_BIN_DST="$HOME/.local/bin/limpet-menu"
PLIST_DST="$HOME/Library/LaunchAgents/$LABEL.plist"
MENU_PLIST_DST="$HOME/Library/LaunchAgents/$MENU_LABEL.plist"
CONFIG_DIR="$HOME/.config/limpet"
LOG_DIR="$HOME/Library/Logs"

echo "==> Stopping launchd agent..."
launchctl bootout "gui/$UID_NUM/$LABEL" 2>/dev/null || \
  launchctl unload -w "$PLIST_DST" 2>/dev/null || true
launchctl bootout "gui/$UID_NUM/$MENU_LABEL" 2>/dev/null || \
  launchctl unload -w "$MENU_PLIST_DST" 2>/dev/null || true

echo "==> Removing files..."
rm -f "$PLIST_DST"      && echo "  - removed $PLIST_DST"
rm -f "$MENU_PLIST_DST" && echo "  - removed $MENU_PLIST_DST"
rm -f "$BIN_DST"        && echo "  - removed $BIN_DST"
rm -f "$MENU_BIN_DST"   && echo "  - removed $MENU_BIN_DST"
rm -rf "${TMPDIR:-/tmp}/limpet.lock" 2>/dev/null || true

if [ "${1:-}" = "--purge" ]; then
  rm -rf "$CONFIG_DIR" && echo "  - removed $CONFIG_DIR"
  rm -f "$LOG_DIR/limpet.log" "$LOG_DIR/limpet.log.1" \
        "$LOG_DIR/limpet.out.log" "$LOG_DIR/limpet.err.log" \
        "$LOG_DIR/limpet-menu.out.log" "$LOG_DIR/limpet-menu.err.log"
  echo "  - removed logs"
else
  echo "  - config & logs kept (run with --purge to delete them)"
fi

echo "Done."
