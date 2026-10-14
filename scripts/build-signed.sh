#!/bin/bash
# Builds, exports and verifies a Developer ID signed Release app.
# Output: build/export/File Transfer for Android.app (gitignored). Notarize and package with scripts/release.sh.
set -euo pipefail

cd "$(dirname "$0")/.."

TEAM="XXY5KCMDAP"
APP="build/export/File Transfer for Android.app"

fail() { echo "FAIL: $*" >&2; exit 1; }

rm -rf build/AFT.xcarchive build/export

xcodebuild -project "File Transfer for Android.xcodeproj" -scheme "File Transfer for Android" -configuration Release \
  -archivePath build/AFT.xcarchive archive -allowProvisioningUpdates
xcodebuild -exportArchive -archivePath build/AFT.xcarchive -exportPath build/export \
  -exportOptionsPlist scripts/ExportOptions.plist -allowProvisioningUpdates

[ -d "$APP" ] || fail "export did not produce $APP"

codesign --verify --strict --deep -vvv "$APP" || fail "codesign --verify --strict --deep failed"

# Capture output first: grep -q on a pipe can SIGPIPE codesign and trip pipefail.
INFO=$(codesign -dvv "$APP" 2>&1)
grep -q "Authority=Developer ID Application" <<<"$INFO" || fail "not signed with Developer ID Application"
grep -q "TeamIdentifier=$TEAM" <<<"$INFO" || fail "TeamIdentifier is not $TEAM"
grep -q "flags=0x10000(runtime)" <<<"$INFO" || fail "hardened runtime flag missing"

ENTS=$(codesign -d --entitlements - "$APP" 2>/dev/null || true)
if grep -q "app-sandbox" <<<"$ENTS"; then fail "App Sandbox entitlement present"; fi
if grep -q "user-selected" <<<"$ENTS"; then fail "user-selected file entitlement present"; fi

ARCHS=$(lipo -archs "$APP/Contents/MacOS/File Transfer for Android")
[ "$ARCHS" = "arm64" ] || fail "expected arm64 only, got: $ARCHS"

echo "Note: Notarize and package with scripts/release.sh."
echo "Signed build OK: $APP"
