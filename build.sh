#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p "Claude Panel.app/Contents/MacOS" "Claude Panel.app/Contents/Resources"
cp Info.plist "Claude Panel.app/Contents/Info.plist"
cp Resources/mascota.png "Claude Panel.app/Contents/Resources/mascota.png"
swiftc -parse-as-library -O -o "Claude Panel.app/Contents/MacOS/claude-panel" Sources/ClaudePanel/*.swift
codesign --force --deep --sign - "Claude Panel.app"
echo "Listo: Claude Panel.app"
