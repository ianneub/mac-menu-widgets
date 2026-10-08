#!/bin/bash
# Build, install to ~/Applications, and (re)start via a LaunchAgent so the
# widgets come up at login.
set -euo pipefail
cd "$(dirname "$0")/.."
scripts/build-app.sh
DEST="$HOME/Applications/MenuWidgets.app"
LABEL=com.ianneub.menu-widgets
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
pkill -x MenuWidgets 2>/dev/null || true
mkdir -p "$HOME/Applications" "$HOME/Library/LaunchAgents"
rm -rf "$DEST"
cp -R build/MenuWidgets.app "$DEST"
cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>$DEST/Contents/MacOS/MenuWidgets</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>ProcessType</key><string>Interactive</string>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/MenuWidgets.log</string>
  <key>StandardOutPath</key><string>$HOME/Library/Logs/MenuWidgets.log</string>
</dict>
</plist>
PLIST
launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "installed $DEST; running under launchd as $LABEL"
