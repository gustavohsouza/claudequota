#!/bin/zsh
# Claude Quota Monitor Bar — build & install script
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
APP="/Applications/Claude Quota Monitor Bar.app"
OLD="/Applications/ClaudeQuota.app"   # legacy bundle name, cleaned up on build

echo "→ compiling..."
cd "$DIR"
# Executable stays "ClaudeQuota" (no spaces) so process name / pkill stay stable;
# the user-visible name comes from Info.plist (CFBundleDisplayName).
swiftc -swift-version 5 -O -o ClaudeQuota main.swift

echo "→ assembling bundle..."
pkill -x ClaudeQuota 2>/dev/null || true
sleep 0.5
rm -rf "$APP" "$OLD"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ClaudeQuota "$APP/Contents/MacOS/ClaudeQuota"
cp Info.plist "$APP/Contents/Info.plist"
cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns" 2>/dev/null || true
cp setup_auth.py "$APP/Contents/Resources/setup_auth.py" 2>/dev/null || true

echo "→ signing (ad-hoc)..."
codesign --force --deep --sign - "$APP"

echo "→ refreshing Finder icon cache..."
touch "$APP"

echo "→ (re)launching..."
open "$APP"
echo "✓ installed at $APP"
