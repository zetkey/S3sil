#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP="$ROOT/build/S3Sil.app"
CONTENTS="$APP/Contents"

echo "Building S3Sil (release, arm64)…"
swift build -c release --arch arm64 --product S3Sil

BIN_DIR="$(swift build -c release --arch arm64 --show-bin-path)"
BIN="$BIN_DIR/S3Sil"
if [[ ! -x "$BIN" ]]; then
    echo "error: release binary not found at $BIN" >&2
    exit 1
fi

rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"

cp "$BIN" "$CONTENTS/MacOS/S3Sil"
chmod 755 "$CONTENTS/MacOS/S3Sil"

cp "$ROOT/Resources/AppIcon.icns" "$CONTENTS/Resources/AppIcon.icns"

cat > "$CONTENTS/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>S3Sil</string>
    <key>CFBundleIdentifier</key>
    <string>com.s3sil.app</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>S3Sil</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon.icns</string>
    <key>CFBundleDisplayName</key>
    <string>S3Sil</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.productivity</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsArbitraryLoads</key>
        <true/>
    </dict>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright © 2026 S3Sil</string>
</dict>
</plist>
PLIST

printf 'APPL????' > "$CONTENTS/PkgInfo"

codesign --force --sign - "$APP" >/dev/null

echo
echo "Binary architecture:"
file "$CONTENTS/MacOS/S3Sil"
echo
echo "Code signature:"
codesign -dv "$APP" 2>&1 | sed -n '1,6p'
echo
echo "Built app: $APP"
