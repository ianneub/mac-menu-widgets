#!/bin/bash
# Build MenuWidgets.app into ./build (release). Signed ad hoc unless
# MENU_WIDGETS_SIGN_IDENTITY (or ~/.config/menu-widgets/sign-identity) names a
# code-signing identity: macOS ties the Reminders permission to the signature,
# so an ad-hoc build asks again after every rebuild, and a stable identity
# (even a self-signed one) keeps it.
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
BIN=$(swift build -c release --show-bin-path)
APP=build/MenuWidgets.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/MenuWidgets" "$APP/Contents/MacOS/"
for b in "$BIN"/*.bundle; do [ -e "$b" ] && cp -R "$b" "$APP/Contents/Resources/"; done
# App icon: Assets/AppIcon.png (from scripts/make-icon.swift) → AppIcon.icns.
ICONSET=$(mktemp -d)/AppIcon.iconset
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s Assets/AppIcon.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s * 2)) $((s * 2)) Assets/AppIcon.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$(dirname "$ICONSET")"
VERSION=$(git describe --tags --always --dirty 2>/dev/null || echo dev)
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>com.ianneub.menu-widgets</string>
  <key>CFBundleName</key><string>MenuWidgets</string>
  <key>CFBundleExecutable</key><string>MenuWidgets</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSLocationUsageDescription</key><string>MenuWidgets uses your approximate location to show the weather where you are.</string>
  <key>NSLocationWhenInUseUsageDescription</key><string>MenuWidgets uses your approximate location to show the weather where you are.</string>
  <key>NSRemindersFullAccessUsageDescription</key><string>MenuWidgets shows your reminders due today and tomorrow in the menu bar, and lets you add, edit and check them off.</string>
</dict>
</plist>
PLIST
IDENTITY_FILE="$HOME/.config/menu-widgets/sign-identity"
IDENTITY="${MENU_WIDGETS_SIGN_IDENTITY:-$( [ -f "$IDENTITY_FILE" ] && head -n1 "$IDENTITY_FILE" || echo -)}"
codesign --force --deep --sign "$IDENTITY" --identifier com.ianneub.menu-widgets "$APP"
echo "built $APP ($VERSION)"
