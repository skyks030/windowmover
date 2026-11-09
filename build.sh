#!/bin/bash
# Baut "WindowMover.app" in ./build (Release, universal arm64 + x86_64).
#   APP_VERSION    – Version überschreiben (sonst scripts/version.sh)
#   SIGN_IDENTITY  – Signatur-Identität (sonst ad-hoc "-")
#   SIGN_KEYCHAIN  – Schlüsselbund, in dem die Identität liegt (optional)
set -euo pipefail
cd "$(dirname "$0")"

APP="build/WindowMover.app"
VERSION="${APP_VERSION:-$(scripts/version.sh)}"
BUILD="$(git rev-list --count HEAD 2>/dev/null || echo 1)"

echo "▸ Kompiliere …"
swift build -c release --arch arm64 --arch x86_64 --product WindowMover
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/WindowMover"

if [ ! -f Resources/AppIcon.icns ]; then
  echo "▸ Erzeuge App-Icon …"
  TMP="$(mktemp -d)"
  swift scripts/make-icon.swift "$TMP/AppIcon.iconset"
  iconutil -c icns "$TMP/AppIcon.iconset" -o Resources/AppIcon.icns
  rm -rf "$TMP"
fi

echo "▸ Erstelle App-Bundle …"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/WindowMover"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" Resources/Info.plist > "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

SIGN_ARGS=(--force --deep --sign "${SIGN_IDENTITY:--}")
[ -n "${SIGN_KEYCHAIN:-}" ] && SIGN_ARGS+=(--keychain "$SIGN_KEYCHAIN")
codesign "${SIGN_ARGS[@]}" "$APP"
echo "✓ Fertig: $APP ($VERSION, Build $BUILD)"
