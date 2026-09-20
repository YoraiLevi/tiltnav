#!/bin/bash
# Build tiltnav and install it as ~/Applications/Tiltnav.app plus a CLI symlink.
#
# The app bundle exists for one reason: macOS ties an Accessibility grant to a code identity,
# and a bare binary is a poor one. Ad-hoc signing pins the grant to the binary's cdhash, so
# EVERY REBUILD REVOKES THE GRANT -- see the README section "Re-granting after a rebuild".
set -euo pipefail

APP="$HOME/Applications/Tiltnav.app"
BIN="$APP/Contents/MacOS/tiltnav"

echo "==> compiling"
swiftc -O tiltnav.swift -o /tmp/tiltnav.build.$$

echo "==> installing to $APP"
launchctl bootout "gui/$(id -u)/com.m5air.tiltnav" 2>/dev/null || true
pkill -f "Tiltnav.app/Contents/MacOS/tiltnav" 2>/dev/null || true
sleep 1

mkdir -p "$APP/Contents/MacOS"
mv /tmp/tiltnav.build.$$ "$BIN"
chmod +x "$BIN"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>        <string>tiltnav</string>
  <key>CFBundleIdentifier</key>        <string>com.m5air.tiltnav</string>
  <key>CFBundleName</key>              <string>Tiltnav</string>
  <key>CFBundlePackageType</key>       <string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.1</string>
  <key>LSUIElement</key>               <true/>
  <key>LSMinimumSystemVersion</key>    <string>13.0</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
mkdir -p "$HOME/.local/bin"
ln -sfn "$BIN" "$HOME/.local/bin/tiltnav"

echo "==> cdhash: $(codesign -d --verbose=4 "$APP" 2>&1 | grep '^CDHash=')"
echo
echo "Next:"
echo "  1. open -a Tiltnav"
echo "  2. Click the menu bar item -> it will tell you if Accessibility is missing."
echo "     In System Settings > Privacy & Security > Accessibility:"
echo "     REMOVE any existing Tiltnav entry first, then add $APP and switch it on."
echo "  3. tiltnav --status     (expect: state healthy, self-test PASSED, exit 0)"
echo "  4. Enable 'Start at Login' from the menu if you want it to survive a reboot."
