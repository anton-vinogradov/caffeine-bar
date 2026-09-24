#!/bin/zsh
# Builds a universal CaffeineBar.app.
#   ./build.sh test     - also runs the checks in tests/
#   ./build.sh install  - also copies it to ~/Applications and (re)starts it
#   ./build.sh zip      - also runs the checks, then packs and signs build/CaffeineBar-<version>.zip(.sig) for a GitHub release
set -euo pipefail
cd "$(dirname "$0")"

VERSION=1.2.1
APP=build/CaffeineBar.app

rm -rf build
mkdir -p "$APP/Contents/MacOS"

for arch in arm64 x86_64; do
    swiftc -O -target "$arch-apple-macos15.0" -o "build/CaffeineBar-$arch" main.swift App.swift Power.swift Updater.swift
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
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleLocalizations</key><array><string>en</string><string>ru</string></array>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>LSUIElement</key><true/>
</dict>
</plist>
EOF

codesign --force --sign - "$APP"

check() {
    swiftc -O -o build/tests tests/main.swift tests/Support.swift Power.swift Updater.swift
    build/tests "$APP/Contents/MacOS/CaffeineBar"

    # The app must get through its launch: a crash there would reach every installed copy.
    "$APP/Contents/MacOS/CaffeineBar" --smoke
    echo "ok   the app starts"
}

case "${1:-}" in
    test)
        check
        ;;
    install)
        pkill -x CaffeineBar || true
        mkdir -p ~/Applications
        rm -rf ~/Applications/CaffeineBar.app
        cp -R "$APP" ~/Applications/
        open ~/Applications/CaffeineBar.app
        ;;
    zip)
        check
        # ditto keeps the bundle layout and code signature; extended attributes are local noise.
        ditto -c -k --norsrc --noextattr --keepParent "$APP" "build/CaffeineBar-$VERSION.zip"
        # The updater installs only zips signed with the key from the maintainer's Keychain.
        # macOS asks for the Keychain password here: no app is trusted to read the key silently.
        # Press "Allow", never "Always Allow": that would trust swift-frontend, which runs every `swift x.swift`.
        swift -suppress-warnings scripts/update-key.swift sign "build/CaffeineBar-$VERSION.zip"
        ;;
esac
