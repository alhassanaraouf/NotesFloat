#!/bin/sh
# Builds NotesFloat.app (universal, macOS 26+), runs the self-test, then installs to /Applications and relaunches.
#   ./build.sh               build + install + relaunch (local development)
#   ./build.sh --no-install  build + self-test only
#   ./build.sh --package     build + self-test + dist/ zip and dmg (used by the release workflow)
# VERSION=1.2.3 sets the app version (defaults to 0.0.0-dev).
set -e
cd "$(dirname "$0")"
APP=NotesFloat.app
VERSION=${VERSION:-0.0.0-dev}
MIN_MACOS=26.0  # NSGlassEffectView / Liquid Glass

rm -rf "$APP" build; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build
cp Artwork/AppIcon.icns "$APP/Contents/Resources/"  # regenerate with: swift Artwork/make-icon.swift
for arch in arm64 x86_64; do
  swiftc -O -target "$arch-apple-macos$MIN_MACOS" *.swift -o "build/NotesFloat-$arch"
done
lipo -create build/NotesFloat-arm64 build/NotesFloat-x86_64 -output "$APP/Contents/MacOS/NotesFloat"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>me.raoufs.alhassan.NotesFloat</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleName</key><string>NotesFloat</string>
  <key>CFBundleDisplayName</key><string>NotesFloat</string>
  <key>CFBundleExecutable</key><string>NotesFloat</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>$MIN_MACOS</string>
  <key>LSUIElement</key><true/>
  <key>NSHumanReadableCopyright</key><string>Copyright © 2026 Al-Hassan Abdel-Raouf. Apache License 2.0.</string>
  <key>NSAppleEventsUsageDescription</key><string>NotesFloat reads and edits your notes in Apple Notes.</string>
  <key>CFBundleURLTypes</key><array><dict>
    <key>CFBundleURLName</key><string>NotesFloat link</string>
    <key>CFBundleURLSchemes</key><array><string>notesfloat</string></array>
  </dict></array>
</dict></plist>
PLIST
codesign -s - --force "$APP"  # ad-hoc: required to run on Apple silicon; not a Developer ID signature
"$APP/Contents/MacOS/NotesFloat" --test

if [ "$1" = "--package" ]; then
  rm -rf dist; mkdir -p dist/dmg
  ditto -c -k --keepParent "$APP" "dist/NotesFloat-$VERSION.zip"
  cp -R "$APP" dist/dmg/ && ln -s /Applications dist/dmg/Applications
  hdiutil create -quiet -volname "NotesFloat" -srcfolder dist/dmg -ov -format UDZO "dist/NotesFloat-$VERSION.dmg"
  rm -rf dist/dmg
  (cd dist && shasum -a 256 NotesFloat-* > SHA256SUMS.txt && cat SHA256SUMS.txt)
  exit 0
fi
[ "$1" = "--no-install" ] && exit 0
pkill -x NotesFloat && while pgrep -x NotesFloat >/dev/null; do sleep 0.1; done
rm -rf "/Applications/$APP"
cp -R "$APP" /Applications/
for _ in 1 2 3 4 5; do open "/Applications/$APP" 2>/dev/null && exit 0; sleep 1; done; echo "launch failed"; exit 1
