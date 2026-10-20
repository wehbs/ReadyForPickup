#!/bin/zsh
# Build a Developer ID-signed, notarized, Sparkle-ready ReadyForPickup DMG.
#
# Flow: check the bundled data (Scripts/check-bundled-data.py) -> build
# Release (unsigned) -> sign Sparkle nested code then the app
# (entitlements with the bundle ID filled in, then checked) -> DMG ->
# notarize (notarytool --wait) -> staple -> generate/sign appcast.
# The script prints the DMG path, its SHA-256, and the generated appcast.xml
# path. It does NOT publish the GitHub release or commit appcast.xml; see
# README "Releasing" for those steps.
#
# Sparkle / notarization prerequisites:
#   * Developer ID Application cert in login Keychain (Account Holder only).
#   * App Store Connect API key in ~/.appstoreconnect/config.json.
#   * Sparkle EdDSA private key ONLY in login Keychain (Sparkle's
#     generate_keys; service https://sparkle-project.org, account ed25519).
#     Never commit/export/print it. Only SUPublicEDKey is in Info.plist.
#   * Sparkle tools come from the SPM artifact bundle resolved by Xcode;
#     this script fails safe (exits) if generate_appcast is missing.
set -euo pipefail
cd "$(dirname "$0")/.."

IDENTITY=$(security find-identity -v -p codesigning | grep "Developer ID Application" | head -1 | sed -E 's/.*"(.*)"/\1/' || true)
if [[ -z "${IDENTITY:-}" ]]; then
  echo "ERROR: No 'Developer ID Application' identity in the keychain." >&2
  exit 1
fi
echo "Signing identity: $IDENTITY"

VERSION=$(grep -m1 "MARKETING_VERSION" InventoryWatch.xcodeproj/project.pbxproj | sed -E 's/.*= ([0-9.]+);/\1/')
WORK=/tmp/readyforpickup-release
APP="$WORK/DerivedData/Build/Products/Release/ReadyForPickup.app"
DMG="$WORK/ReadyForPickup-$VERSION.dmg"
rm -rf "$WORK"; mkdir -p "$WORK"

# The app decodes each bundled data file as a whole, so one bad value in
# either would ship an app with no countries or no stores.
python3 -I Scripts/check-bundled-data.py

xcodebuild -project InventoryWatch.xcodeproj -scheme InventoryWatch \
  -configuration Release -derivedDataPath "$WORK/DerivedData" \
  build CODE_SIGNING_ALLOWED=NO | tail -2

# Locate Sparkle tools from the SPM artifact; fail safe if missing.
SPARKLE_BIN=$(find "$WORK/DerivedData/SourcePackages/artifacts" -path "*Sparkle/bin/generate_appcast" 2>/dev/null | head -1 || true)
if [[ -z "${SPARKLE_BIN:-}" ]]; then
  echo "ERROR: Sparkle generate_appcast not found under DerivedData; resolve SPM packages first." >&2
  exit 1
fi
SPARKLE_TOOLS=$(dirname "$SPARKLE_BIN")
echo "Sparkle tools: $SPARKLE_TOOLS"

# Sign Sparkle's nested code first (not --deep), then the app.
SPARKLE_FW="$APP/Contents/Frameworks/Sparkle.framework"
if [[ -d "$SPARKLE_FW" ]]; then
  for xpc in "$SPARKLE_FW"/Versions/B/XPCServices/*.xpc; do
    [[ -e "$xpc" ]] && codesign --force --timestamp --options runtime --sign "$IDENTITY" "$xpc"
  done
  [[ -e "$SPARKLE_FW/Versions/B/Autoupdate" ]] && codesign --force --timestamp --options runtime --sign "$IDENTITY" "$SPARKLE_FW/Versions/B/Autoupdate"
  [[ -e "$SPARKLE_FW/Versions/B/Updater.app" ]] && codesign --force --timestamp --options runtime --sign "$IDENTITY" "$SPARKLE_FW/Versions/B/Updater.app"
  codesign --force --timestamp --options runtime --sign "$IDENTITY" "$SPARKLE_FW"
fi
# Only Xcode's own signing step expands build settings in entitlements, so
# sign with a copy that has $(PRODUCT_BUNDLE_IDENTIFIER) filled in from the
# built app. 0.3.2 shipped the literal string, which blocks Sparkle installs.
BUNDLE_ID=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$APP/Contents/Info.plist")
ENTITLEMENTS="$WORK/ReadyForPickup.entitlements"
sed 's/\$(PRODUCT_BUNDLE_IDENTIFIER)/'"$BUNDLE_ID"'/g' InventoryWatch/InventoryWatch.entitlements > "$ENTITLEMENTS"
codesign --force --timestamp --options runtime \
  --entitlements "$ENTITLEMENTS" \
  --sign "$IDENTITY" "$APP"
codesign --verify --deep --strict "$APP"

# The sandboxed app must be allowed to look up Sparkle's installer services
# <bundle ID>-spks and <bundle ID>-spki, or updates fail at the install step.
SIGNED_ENTITLEMENTS=$(codesign -d --entitlements - --xml "$APP" 2>/dev/null)
if [[ "$SIGNED_ENTITLEMENTS" == *'$('* || "$SIGNED_ENTITLEMENTS" == *'${'* ]]; then
  echo "ERROR: The signed app's entitlements still contain an unexpanded build setting:" >&2
  echo "$SIGNED_ENTITLEMENTS" >&2
  exit 1
fi
for SERVICE in "$BUNDLE_ID-spks" "$BUNDLE_ID-spki"; do
  if [[ "$SIGNED_ENTITLEMENTS" != *"<string>$SERVICE</string>"* ]]; then
    echo "ERROR: The signed app's entitlements don't allow mach-lookup of $SERVICE." >&2
    exit 1
  fi
done
echo "Sparkle mach-lookup exceptions: $BUNDLE_ID-spks, $BUNDLE_ID-spki"

mkdir -p "$WORK/stage"; cp -R "$APP" "$WORK/stage/"
ln -s /Applications "$WORK/stage/Applications"
diskutil image create from --format UDZO --volumeName ReadyForPickup "$WORK/stage" "$DMG"

read KEY_ID ISSUER_ID KEY_PATH < <(python3 -c "
import json,pathlib
c=json.load(open(pathlib.Path.home()/'.appstoreconnect/config.json'))
print(c['keyID'], c['issuerID'], c['keyPath'])")
# NOTE: notarization can take hours. --wait blocks; submission ID is printed
# by notarytool. If detached, poll: notarytool info <id> ... (see README).
xcrun notarytool submit "$DMG" --key "$KEY_PATH" --key-id "$KEY_ID" --issuer "$ISSUER_ID" --wait
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
# A version-free copy of the stapled DMG for the site and README, which link to
# releases/latest/download/ReadyForPickup.dmg (always the latest release's copy).
cp "$DMG" "$WORK/ReadyForPickup.dmg"
spctl -a -vvv -t open --context context:primary-signature "$DMG" || true

# Generate + EdDSA-sign appcast entry for THIS version. Enclosure URL points
# at the GitHub Release asset (published separately via gh release create).
mkdir -p "$WORK/appcast"
cp "$DMG" "$WORK/appcast/"
cp appcast.xml "$WORK/appcast/appcast.xml" 2>/dev/null || true
# No -o: with it, generate_appcast reads the existing feed from the -o path
# (empty here), drops earlier items, and leaves the copy below stale.
"$SPARKLE_TOOLS/generate_appcast" \
  --download-url-prefix "https://github.com/wehbs/ReadyForPickup/releases/download/v$VERSION/" \
  "$WORK/appcast"
# generate_appcast updates appcast.xml in the archives dir; copy it back
if [[ -f "$WORK/appcast/appcast.xml" ]]; then cp "$WORK/appcast/appcast.xml" ./appcast.xml; fi
python3 -c "import xml.dom.minidom,sys; xml.dom.minidom.parse('appcast.xml'); print('appcast.xml: well-formed XML')"
shasum -a 256 "$DMG"
echo "Done: $DMG (and its version-free copy $WORK/ReadyForPickup.dmg; upload both)"
echo "Appcast updated: $(pwd)/appcast.xml (review it; create the GitHub release first, then commit + push it)"
