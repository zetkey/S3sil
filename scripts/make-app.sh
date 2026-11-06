#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

CODE_SIGN_IDENTITY="${CODE_SIGN_IDENTITY:-"S3Sil Local"}"

# Usage: make-app.sh [--identity "Name" | "Name"]
while [[ $# -gt 0 ]]; do
    case "$1" in
        --identity=*) CODE_SIGN_IDENTITY="${1#--identity=}"; shift ;;
        --identity)   CODE_SIGN_IDENTITY="${2:?--identity requires a name}"; shift 2 ;;
        *)            CODE_SIGN_IDENTITY="$1"; shift ;;
    esac
done

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

# security find-identity exits 0 even when the named identity is absent — match the name in the list instead
if security find-identity -v -p codesigning 2>/dev/null | grep -q "\"$CODE_SIGN_IDENTITY\""; then
    codesign --force --sign "$CODE_SIGN_IDENTITY" "$APP" >/dev/null
    echo "Signed with stable identity: $CODE_SIGN_IDENTITY"
else
    codesign --force --sign - "$APP" >/dev/null
    echo "Identity \"$CODE_SIGN_IDENTITY\" not found — signed ad-hoc (Keychain may re-prompt after rebuilds)."
    echo "Create a Code Signing certificate named \"$CODE_SIGN_IDENTITY\" in Keychain Access →"
    echo "Certificate Assistant → Create a Certificate → type \"Code Signing\", or set CODE_SIGN_IDENTITY env var."
fi

echo
echo "Binary architecture:"
file "$CONTENTS/MacOS/S3Sil"
echo
echo "Code signature:"
codesign -dv "$APP" 2>&1 | sed -n '1,6p'
echo
echo "Built app: $APP"
