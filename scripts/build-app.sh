#!/bin/zsh
# Builds dist/Snowdrift.app (universal: Apple Silicon + Intel), signs it, and zips it for a release.
#   scripts/build-app.sh [version]            ad-hoc signed (friends approve it once: Open Anyway)
#   SIGN_ID="Developer ID Application: …" scripts/build-app.sh 1.0.0    with a paid Apple developer ID
# Needs only the Xcode Command Line Tools.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=${1:-1.0.0}
SIGN_ID=${SIGN_ID:--}                     # "-" = ad-hoc
APP=dist/Snowdrift.app

echo "› Building (arm64 + x86_64)…"
swift build -c release --triple arm64-apple-macosx14.0
swift build -c release --triple x86_64-apple-macosx14.0

echo "› Assembling $APP"
rm -rf dist
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create .build/arm64-apple-macosx/release/Snowdrift .build/x86_64-apple-macosx/release/Snowdrift \
     -output "$APP/Contents/MacOS/Snowdrift"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Snowdrift</string>
    <key>CFBundleDisplayName</key><string>Snowdrift</string>
    <key>CFBundleIdentifier</key><string>com.mhbemani.snowdrift</string>
    <key>CFBundleExecutable</key><string>Snowdrift</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>© 2026 mhbemani</string>
</dict>
</plist>
PLIST
plutil -lint "$APP/Contents/Info.plist" >/dev/null

echo "› Signing (${SIGN_ID})"
# Hardened runtime; no entitlements needed (no network, no sandbox exceptions, no permissions).
codesign --force --options runtime --timestamp=none --sign "$SIGN_ID" "$APP"
codesign --verify --strict --verbose=1 "$APP"

echo "› Zipping"
ditto -c -k --keepParent "$APP" "dist/Snowdrift-$VERSION.zip"
lipo -archs "$APP/Contents/MacOS/Snowdrift"
ls -lh "dist/Snowdrift-$VERSION.zip"
