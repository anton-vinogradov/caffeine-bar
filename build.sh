#!/bin/zsh
# Builds CaffeineBar.app; with "install" also copies it to ~/Applications and (re)starts it.
set -euo pipefail
cd "$(dirname "$0")"

APP=build/CaffeineBar.app

rm -rf build
mkdir -p "$APP/Contents/MacOS"

swiftc -O -target "$(uname -m)-apple-macos15.0" -o "$APP/Contents/MacOS/CaffeineBar" main.swift

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>io.github.anton-vinogradov.CaffeineBar</string>
    <key>CFBundleName</key><string>CaffeineBar</string>
    <key>CFBundleExecutable</key><string>CaffeineBar</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>LSUIElement</key><true/>
</dict>
</plist>
EOF

codesign --force --sign - "$APP"

if [[ "${1:-}" == install ]]; then
    pkill -x CaffeineBar || true
    mkdir -p ~/Applications
    rm -rf ~/Applications/CaffeineBar.app
    cp -R "$APP" ~/Applications/
    open ~/Applications/CaffeineBar.app
fi
