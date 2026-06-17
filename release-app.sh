#!/bin/bash
# =============================================================================
# release-app.sh — build, sign, notarize, and package Limpet.app for the Cask.
#
# Produces dist/Limpet-macos-universal-<version>.zip (a stapled, notarized,
# universal app) and prints its sha256 — the artifact the Homebrew Cask serves.
# Run this on your Mac (notarization needs your Apple credentials); it can't run
# in CI without the cert + notary secrets (see RELEASING-app.md).
#
# One-time setup:
#   1. A "Developer ID Application" certificate in your login keychain
#      (Xcode → Settings → Accounts → Manage Certificates, or developer.apple.com).
#   2. A stored notary profile so notarytool can authenticate without prompts:
#        xcrun notarytool store-credentials limpet-notary \
#          --apple-id "you@example.com" --team-id "TEAMID" \
#          --password "app-specific-password"
#
# Usage:
#   ./release-app.sh 1.1.0                 # explicit version
#   ./release-app.sh                       # derive from the current git tag
#
# Overrides (env):
#   SIGN_IDENTITY   codesign identity (default: auto-detected Developer ID Application)
#   NOTARY_PROFILE  notarytool keychain profile name (default: limpet-notary)
#   MIN_MACOS       deployment target (default: 13, matches the README)
# =============================================================================
set -euo pipefail

SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SRC_DIR"

VERSION="${1:-$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//')}"
[ -n "$VERSION" ] || { echo "error: no version given and no git tag found"; exit 1; }

NOTARY_PROFILE="${NOTARY_PROFILE:-limpet-notary}"
MIN_MACOS="${MIN_MACOS:-13}"
MENU_LABEL="com.georgeolaru.limpet.menu"
MENU_SRC="$SRC_DIR/limpet-menu.swift"

# Resolve the signing identity (first Developer ID Application in the keychain).
if [ -z "${SIGN_IDENTITY:-}" ]; then
  SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)"
fi
[ -n "$SIGN_IDENTITY" ] || {
  echo "error: no 'Developer ID Application' identity found. Set SIGN_IDENTITY or install the cert."
  exit 1
}
echo "==> Signing identity : $SIGN_IDENTITY"
echo "==> Version          : $VERSION"

BUILD="$(mktemp -d)"
trap 'rm -rf "$BUILD"' EXIT
APP="$BUILD/Limpet.app"
MACOS="$APP/Contents/MacOS"
RES="$APP/Contents/Resources"
mkdir -p "$MACOS" "$RES"

# 1. Universal binary (arm64 + x86_64) ----------------------------------------
echo "==> Building universal limpet-menu"
swiftc -O -target "arm64-apple-macos$MIN_MACOS"  "$MENU_SRC" -o "$BUILD/limpet-menu-arm64"
swiftc -O -target "x86_64-apple-macos$MIN_MACOS" "$MENU_SRC" -o "$BUILD/limpet-menu-x86_64"
lipo -create -output "$MACOS/limpet-menu" "$BUILD/limpet-menu-arm64" "$BUILD/limpet-menu-x86_64"

# 2. Bundle resources (mirrors install.sh) ------------------------------------
[ -f "$SRC_DIR/assets/AppIcon.icns" ] && cp "$SRC_DIR/assets/AppIcon.icns" "$RES/AppIcon.icns"
for icon in MenuBarIconTemplate MenuBarIconTemplateOK MenuBarIconTemplateDown \
            MenuBarIconTemplateCaptive MenuBarIconTemplateUnknown; do
  [ -f "$SRC_DIR/assets/$icon.png" ] && cp "$SRC_DIR/assets/$icon.png" "$RES/$icon.png"
done
[ -f "$SRC_DIR/docs/timeline.html" ] && cp "$SRC_DIR/docs/timeline.html" "$RES/timeline.html"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDisplayName</key><string>Limpet</string>
  <key>CFBundleExecutable</key><string>limpet-menu</string>
  <key>CFBundleIconFile</key><string>AppIcon.icns</string>
  <key>CFBundleIdentifier</key><string>$MENU_LABEL</string>
  <key>CFBundleName</key><string>Limpet</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# 3. Sign (hardened runtime + secure timestamp, required for notarization) -----
echo "==> Codesigning"
codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"
codesign --verify --strict --verbose=2 "$APP"

# 4. Notarize + staple --------------------------------------------------------
echo "==> Submitting to Apple notary service (this can take a few minutes)"
ditto -c -k --keepParent "$APP" "$BUILD/notarize.zip"
xcrun notarytool submit "$BUILD/notarize.zip" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

# 5. Final distributable zip --------------------------------------------------
DIST="$SRC_DIR/dist"
mkdir -p "$DIST"
ZIP="$DIST/Limpet-macos-universal-$VERSION.zip"
ditto -c -k --keepParent "$APP" "$ZIP"

echo
echo "==> Done: $ZIP"
echo "==> sha256: $(shasum -a 256 "$ZIP" | awk '{print $1}')"
echo
echo "Next: attach it to the release, e.g."
echo "  gh release upload v$VERSION \"$ZIP\""
echo "The tap's auto-bump then fills the Cask's version + sha256 from this asset."
