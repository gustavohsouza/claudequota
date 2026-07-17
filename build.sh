#!/bin/zsh
# ClaudeQuota build & install script
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
APP="/Applications/ClaudeQuota.app"

echo "→ compiling..."
cd "$DIR"
swiftc -swift-version 5 -O -o ClaudeQuota main.swift

echo "→ assembling bundle..."
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ClaudeQuota "$APP/Contents/MacOS/ClaudeQuota"
cp Info.plist "$APP/Contents/Info.plist"
cp setup_auth.py "$APP/Contents/Resources/setup_auth.py" 2>/dev/null || true

echo "→ signing (ad-hoc)..."
codesign --force --deep --sign - "$APP"

echo "→ (re)launching..."
pkill -x ClaudeQuota 2>/dev/null || true
sleep 0.5
open "$APP"
echo "✓ installed at $APP"
