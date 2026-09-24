#!/bin/zsh
# Builds a universal CaffeineBar.app.
#   ./build.sh install  - also copies it to ~/Applications and (re)starts it
#   ./build.sh zip      - also packs it into build/CaffeineBar-<version>.zip for a GitHub release
set -euo pipefail
cd "$(dirname "$0")"

VERSION=1.0.0
APP=build/CaffeineBar.app

rm -rf build
mkdir -p "$APP/Contents/MacOS"

for arch in arm64 x86_64; do
    swiftc -O -target "$arch-apple-macos15.0" -o "build/CaffeineBar-$arch" main.swift
done
lipo -create -output "$APP/Contents/MacOS/CaffeineBar" build/CaffeineBar-arm64 build/CaffeineBar-x86_64

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>io.github.anton-vinogradov.CaffeineBar</string>
    <key>CFBundleName</key><string>CaffeineBar</string>
    <key>CFBundleExecutable</key><string>CaffeineBar</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>LSUIElement</key><true/>
</dict>
</plist>
EOF

codesign --force --sign - "$APP"

case "${1:-}" in
    install)
        pkill -x CaffeineBar || true
        mkdir -p ~/Applications
        rm -rf ~/Applications/CaffeineBar.app
        cp -R "$APP" ~/Applications/
        open ~/Applications/CaffeineBar.app
        ;;
    zip)
        # ditto keeps the bundle layout and code signature; extended attributes are local noise.
        ditto -c -k --norsrc --noextattr --keepParent "$APP" "build/CaffeineBar-$VERSION.zip"
        echo "build/CaffeineBar-$VERSION.zip"
        ;;
esac
