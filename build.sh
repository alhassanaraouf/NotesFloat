#!/bin/sh
# Builds NotesFloat.app (universal, macOS 26+), runs the self-test, then installs to /Applications and relaunches.
#   ./build.sh               build + install + relaunch (local development)
#   ./build.sh --no-install  build + self-test only
#   ./build.sh --package     build + self-test + dist/ zip, dmg, checksums and Sparkle appcast (release workflow)
# VERSION=1.2.3 sets the app version (default: latest git tag). Packaging signs the update with the EdDSA key in
# $SPARKLE_ED_PRIVATE_KEY (CI) or, if SPARKLE_KEYCHAIN=1, the "me.raoufs.alhassan.NotesFloat" key in the login keychain.
set -e
cd "$(dirname "$0")"
APP=NotesFloat.app
VERSION=${VERSION:-$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//')}
VERSION=${VERSION:-0.0.0}
MIN_MACOS=26.0  # NSGlassEffectView / Liquid Glass
REPO=alhassanaraouf/NotesFloat
SPARKLE=2.10.1
SPARKLE_SHA256=1a856d2a9edb8e628de88121d7be04cf0e2167f8641650b78fca00b14244cf27
SPARKLE_PUBLIC_KEY=AEEvCN+evh+J+WKIQ/BlufWO72NLD3n4RGgdIJVQV8c=
SP=vendor/Sparkle-$SPARKLE

if [ ! -d "$SP/Sparkle.framework" ]; then  # pinned, checksum-verified download
  mkdir -p "$SP"
  curl -fsSL "https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE/Sparkle-$SPARKLE.tar.xz" -o "$SP.tar.xz"
  echo "$SPARKLE_SHA256  $SP.tar.xz" | shasum -a 256 -c -
  tar -xf "$SP.tar.xz" -C "$SP" && rm "$SP.tar.xz"
fi

rm -rf "$APP" build; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks" build
cp Artwork/AppIcon.icns "$APP/Contents/Resources/"  # regenerate with: swift Artwork/make-icon.swift
ditto "$SP/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
for arch in arm64 x86_64; do
  swiftc -O -target "$arch-apple-macos$MIN_MACOS" -F "$SP" -framework Sparkle \
    -Xlinker -rpath -Xlinker @executable_path/../Frameworks *.swift -o "build/NotesFloat-$arch"
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
  <key>NSServices</key><array><dict>
    <key>NSMenuItem</key><dict><key>default</key><string>Add to NotesFloat</string></dict>
    <key>NSMessage</key><string>captureService</string>
    <key>NSPortName</key><string>NotesFloat</string>
    <key>NSSendTypes</key><array><string>public.utf8-plain-text</string><string>NSStringPboardType</string></array>
  </dict></array>
  <key>SUFeedURL</key><string>https://github.com/$REPO/releases/latest/download/appcast.xml</string>
  <key>SUPublicEDKey</key><string>$SPARKLE_PUBLIC_KEY</string>
  <key>SUEnableAutomaticChecks</key><true/>
</dict></plist>
PLIST
# Sign with the stable "NotesFloat Self-Signed" identity so every build has the same designated requirement and macOS
# keeps the app's permissions across updates (ad-hoc signatures change per build, which resets them).
#   CI: base64 .p12 in $SIGNING_P12 + $SIGNING_P12_PASSWORD, loaded into a throwaway keychain.
#   Local: ~/Library/Keychains/NotesFloat-signing.keychain-db, unlocked from 1Password after a restart.
# Not an Apple Developer ID, so Gatekeeper still asks on first open.
IDENTITY="NotesFloat Self-Signed"
KC=""
if [ -n "$SIGNING_P12" ]; then
  KC="$PWD/build/signing.keychain-db"; KCPW=$(uuidgen)
  security create-keychain -p "$KCPW" "$KC" && security set-keychain-settings "$KC" && security unlock-keychain -p "$KCPW" "$KC"
  (umask 077; printf '%s' "$SIGNING_P12" | base64 -d > build/signing.p12)
  security import build/signing.p12 -k "$KC" -P "$SIGNING_P12_PASSWORD" -T /usr/bin/codesign >/dev/null
  rm -P build/signing.p12
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KCPW" "$KC" >/dev/null
elif [ -f "$HOME/Library/Keychains/NotesFloat-signing.keychain-db" ]; then
  KC="$HOME/Library/Keychains/NotesFloat-signing.keychain-db"
fi
if [ -n "$KC" ]; then
  sign() { codesign --force --deep --keychain "$KC" -s "$IDENTITY" "$APP" 2>/dev/null; }
  sign || { security unlock-keychain -p "$(op read 'op://Private/6eqzyc4il27hyqm4mj4gndc4lu/keychainpassword')" "$KC" && sign; } \
    || { echo "error: signing with $IDENTITY failed" >&2; exit 1; }
  echo "signed: $IDENTITY"
else
  [ "$1" = "--package" ] && [ -n "$CI" ] && { echo "error: release builds must be signed (SIGNING_P12 missing)" >&2; exit 1; }
  codesign -s - --force --deep "$APP"  # ad-hoc fallback for contributors; macOS re-asks for permissions after rebuilds
  echo "warning: ad-hoc signed (no NotesFloat signing identity found)" >&2
fi
[ -n "$SIGNING_P12" ] && security delete-keychain "$KC"
"$APP/Contents/MacOS/NotesFloat" --test

if [ "$1" = "--package" ]; then
  rm -rf dist; mkdir -p dist/dmg
  ZIP="NotesFloat-$VERSION.zip"
  ditto -c -k --keepParent "$APP" "dist/$ZIP"
  cp -R "$APP" dist/dmg/ && ln -s /Applications dist/dmg/Applications
  hdiutil create -quiet -volname "NotesFloat" -srcfolder dist/dmg -ov -format UDZO "dist/NotesFloat-$VERSION.dmg"
  rm -rf dist/dmg

  # Sparkle feed: one item pointing at this release's zip, signed with EdDSA. Served from the latest release.
  if [ -n "$SPARKLE_ED_PRIVATE_KEY" ]; then
    SIG=$(printf '%s' "$SPARKLE_ED_PRIVATE_KEY" | "$SP/bin/sign_update" --ed-key-file - "dist/$ZIP")
  elif [ "$SPARKLE_KEYCHAIN" = 1 ]; then
    SIG=$("$SP/bin/sign_update" --account me.raoufs.alhassan.NotesFloat "dist/$ZIP")
  fi
  if [ -n "$SIG" ]; then
    cat > dist/appcast.xml <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>NotesFloat</title>
    <item>
      <title>NotesFloat $VERSION</title>
      <pubDate>$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')</pubDate>
      <sparkle:version>$VERSION</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$MIN_MACOS</sparkle:minimumSystemVersion>
      <sparkle:fullReleaseNotesLink>https://github.com/$REPO/releases/tag/v$VERSION</sparkle:fullReleaseNotesLink>
      <enclosure url="https://github.com/$REPO/releases/download/v$VERSION/$ZIP" type="application/octet-stream" $SIG />
    </item>
  </channel>
</rss>
XML
    swift .github/verify-sparkle.swift "dist/$ZIP" "$(echo "$SIG" | sed -n 's/.*edSignature="\([^"]*\)".*/\1/p')" "$SPARKLE_PUBLIC_KEY"
  else
    echo "warning: no Sparkle key; dist/appcast.xml not created, so this release won't be offered as an update" >&2
  fi
  (cd dist && shasum -a 256 NotesFloat-* > SHA256SUMS.txt && cat SHA256SUMS.txt)
  exit 0
fi
[ "$1" = "--no-install" ] && exit 0
pkill -x NotesFloat && while pgrep -x NotesFloat >/dev/null; do sleep 0.1; done
rm -rf "/Applications/$APP"
cp -R "$APP" /Applications/
for _ in 1 2 3 4 5; do open "/Applications/$APP" 2>/dev/null && exit 0; sleep 1; done; echo "launch failed"; exit 1
