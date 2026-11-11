#!/bin/bash
# Сборка «VPN Guard.app» в build/. Запуск от пользователя: app/build.sh
set -euo pipefail
DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$DIR/build/VPN Guard.app"
rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"
cp "$DIR/app/Info.plist" "$OUT/Contents/Info.plist"
swiftc -swift-version 5 -O -o "$OUT/Contents/MacOS/VPNGuard" "$DIR/app/VPNGuard.swift"
codesign --force --sign - "$OUT" >/dev/null
echo "$OUT"
