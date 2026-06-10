#!/bin/zsh
# Build Listen.app and install it to ~/Applications
set -e
cd "$(dirname "$0")"

swiftc -O -o Listen main.swift

APP="$HOME/Applications/Listen.app"
mkdir -p "$HOME/Applications"
pkill -x Listen 2>/dev/null || true
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Listen "$APP/Contents/MacOS/Listen"
cp Info.plist "$APP/Contents/Info.plist"
cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# If a stable "Listen Dev" code-signing identity is trusted in your keychain,
# permissions survive rebuilds; otherwise fall back to ad-hoc signing (macOS
# re-asks for the recording permission after each rebuild). See README.
if security find-identity -v -p codesigning 2>/dev/null | grep -q "Listen Dev"; then
  codesign --force -s "Listen Dev" "$APP"
  echo "Signed with: Listen Dev (stable)"
else
  codesign --force -s - "$APP"
  echo "Signed: ad-hoc (recording permission resets on each rebuild)"
fi

echo "Installed: $APP"
