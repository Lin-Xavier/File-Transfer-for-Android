#!/bin/bash
# Release build (D-23). Without NOTARY_PROFILE: build, sign and run Apple's pre-notarization check only.
# With NOTARY_PROFILE (a `notarytool store-credentials` keychain profile name): notarize and staple the app,
# build the DMG, then sign, notarize and staple the DMG. Never publishes anything.
set -euo pipefail

cd "$(dirname "$0")/.."

NAME="File Transfer for Android"
APP="build/export/$NAME.app"
BUNDLE_ID="com.xianglin.File-Transfer-for-Android"
TEAM="XXY5KCMDAP"
PROFILE="${NOTARY_PROFILE:-}"

fail() { echo "FAIL: $*" >&2; exit 1; }

# Ship committed sources only: the synchronized app folder compiles every file in it, untracked ones included.
if [ -n "$PROFILE" ] && [ -n "$(git status --porcelain -- "$NAME" "$NAME.xcodeproj" MTPKit scripts)" ]; then
  fail "uncommitted or untracked changes in the app, project, MTPKit or scripts; commit or remove them first"
fi

scripts/build-signed.sh

# Pitfall 12: the About/Help link must point at the real repo before anything is notarized.
if grep -q "github.com/OWNER/REPO" "$APP/Contents/MacOS/$NAME"; then
  fail "the Help link still holds the placeholder repo URL; set it to the real GitHub repo first"
fi

# syspolicy_check also asks Gatekeeper, which rejects the main executable until a notary ticket exists (seen on
# macOS 27: "ticket not available"); allow only that finding and warnings, fail on anything else or unparsable output.
if ! PRECHECK=$(syspolicy_check notary-submission "$APP" --json 2>/dev/null); then
  BLOCKING=$(jq -c --arg exe "/Contents/MacOS/$NAME" '[.output[]
    | select(.SyspolicyCheckErrorLevel != "Warning")
    | select(((.SyspolicyCheckLongError | startswith("Gatekeeper rejected this file"))
              and (.SyspolicyCheckErrorFile | endswith($exe))) | not)]' <<<"$PRECHECK") \
    || fail "syspolicy_check notary-submission failed: $PRECHECK"
  [ "$BLOCKING" = "[]" ] || fail "syspolicy_check notary-submission: $BLOCKING"
  echo "syspolicy_check notary-submission: only the expected pre-notarization Gatekeeper rejection"
fi

if [ -z "$PROFILE" ]; then
  echo "Pre-flight OK: $APP. Set NOTARY_PROFILE to a notarytool keychain profile to notarize and build the DMG."
  exit 0
fi

notarize() {
  local out id status
  out=$(xcrun notarytool submit "$1" --keychain-profile "$PROFILE" --wait --output-format json) || true
  id=$(jq -r '.id // empty' <<<"$out" 2>/dev/null || true)
  status=$(jq -r '.status // empty' <<<"$out" 2>/dev/null || true)
  [ -n "$id" ] || fail "notarytool submit of $1 returned no submission id: $out"
  # Apple: always read the log, even on Accepted (it lists warnings).
  xcrun notarytool log "$id" --keychain-profile "$PROFILE" "build/notary-$id.json" || echo "warning: could not fetch notary log $id" >&2
  [ "$status" = "Accepted" ] || fail "notarization of $1: ${status:-unknown} (log build/notary-$id.json)"
}

# App: notarize, then staple. Nothing is signed after a staple (Pitfall 1: re-signing drops the ticket).
rm -f build/app.zip
ditto -c -k --keepParent "$APP" build/app.zip
notarize build/app.zip
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
syspolicy_check distribution "$APP" || fail "syspolicy_check distribution reported problems"
# Capture first: grep -q on a pipe can SIGPIPE spctl and trip pipefail.
CHECK=$(spctl -a -vvv -t exec "$APP" 2>&1 || true)
grep -q "source=Notarized Developer ID" <<<"$CHECK" || fail "spctl does not accept the app: $CHECK"

# DMG (UI-SPEC S8): the app plus an Applications link, plain UDZO.
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
DMG="build/File-Transfer-for-Android-$VERSION.dmg"
STAGE=build/dmg-stage
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/$NAME.app" # ditto keeps the stapled ticket
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "$NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG" # macOS 27 prints a deprecation warning
hdiutil verify "$DMG"
# The keychain's Developer ID Application identity for TEAM, by SHA-1, so the script names no person.
IDENTITY=$(security find-identity -v -p codesigning | awk -v t="($TEAM)\"" '/"Developer ID Application: / && index($0, t) { print $2; exit }')
[ -n "$IDENTITY" ] || fail "no valid Developer ID Application identity for team $TEAM in the keychain"
codesign -s "$IDENTITY" --timestamp -i "$BUNDLE_ID.dmg" "$DMG"
notarize "$DMG"
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
CHECK=$(spctl -a -t open --context context:primary-signature -vvv "$DMG" 2>&1 || true)
grep -q "source=Notarized Developer ID" <<<"$CHECK" || fail "spctl does not accept the DMG: $CHECK"

echo "Release DMG OK: $DMG"
shasum -a 256 "$DMG"
