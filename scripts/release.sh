#!/bin/zsh
# Build, Developer-ID sign, notarize, staple and package Backline for distribution.
#
# One-time setup (done by the account holder):
#   1. Xcode ▸ Settings ▸ Accounts ▸ add the Apple ID for team SBMJ9PMG22.
#      Then Manage Certificates ▸ + ▸ "Developer ID Application" (or download it from
#      developer.apple.com ▸ Certificates and double-click it).
#   2. Create an app-specific password at account.apple.com ▸ Sign-In and Security, then:
#        xcrun notarytool store-credentials backline-notary \
#            --apple-id <your-apple-id> --team-id SBMJ9PMG22 --password <app-specific-password>
#
# Usage:  scripts/release.sh            (version comes from project.yml MARKETING_VERSION)
set -euo pipefail
cd "$(dirname "$0")/.."

TEAM=SBMJ9PMG22
PROFILE=${NOTARY_PROFILE:-backline-notary}
VERSION=$(awk -F'"' '/MARKETING_VERSION/ {print $2; exit}' project.yml)
ARCHIVE=build/archive/Backline-$VERSION.xcarchive
EXPORT=build/export/$VERSION
DIST=dist

echo "▸ Backline $VERSION"
security find-identity -v -p codesigning | grep -q "Developer ID Application" || {
    echo "✗ No 'Developer ID Application' certificate in the keychain. See the setup notes at the top of this script."; exit 1; }
xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1 || {
    echo "✗ Notary profile '$PROFILE' missing. Run: xcrun notarytool store-credentials $PROFILE --apple-id … --team-id $TEAM --password …"; exit 1; }

XCODEGEN=${XCODEGEN:-$(command -v xcodegen || echo ~/.local/tools/xcodegen/bin/xcodegen)}
"$XCODEGEN" generate >/dev/null
git lfs pull >/dev/null 2>&1 || true

echo "▸ Archiving"
rm -rf "$ARCHIVE" "$EXPORT"
xcodebuild -project Backline.xcodeproj -scheme Backline -configuration Release \
    -derivedDataPath build/dd-archive -archivePath "$ARCHIVE" \
    -destination 'generic/platform=macOS' -allowProvisioningUpdates archive -quiet

echo "▸ Signing with Developer ID"
# xcodebuild -exportArchive rejects apps that embed yt-dlp's PyInstaller tree ("contains invalid
# products"), so the archived app is copied out and signed inside-out here instead.
rm -rf "$EXPORT"; mkdir -p "$EXPORT"
ditto "$ARCHIVE/Products/Applications/Backline.app" "$EXPORT/Backline.app"

APP="$EXPORT/Backline.app"
# Nested helper (yt-dlp) and LAME must carry Developer ID + secure timestamps for notarisation.
DEVID=$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/{print $2; exit}')
H="$APP/Contents/Resources/yt-dlp"
if [ -d "$H" ]; then
  find "$H" -type f ! -path "$H/yt-dlp" ! -path "$H/qjs" ! -path "*/Python.framework/*" | while read -r f; do
    kind=$(file "$f")
    if [[ "$kind" == *Mach-O* ]]; then codesign -f -s "$DEVID" --options runtime --timestamp "$f" >/dev/null; fi
  done
  FW="$H/_internal/Python.framework"
  if [ -d "$FW/Versions" ]; then
    V=$(ls "$FW/Versions" | grep -v '^Current$' | head -1)
    codesign -f -s "$DEVID" --options runtime --timestamp "$FW/Versions/$V"
    codesign -v --strict "$FW/Versions/$V"
  fi
  codesign -f -s "$DEVID" --options runtime --timestamp --entitlements scripts/ytdlp-helper.entitlements "$H/qjs"
  codesign -f -s "$DEVID" --options runtime --timestamp --entitlements scripts/ytdlp-helper.entitlements "$H/yt-dlp"
fi
codesign -f -s "$DEVID" --options runtime --timestamp "$APP/Contents/Frameworks/libmp3lame.0.dylib"
# Core ML models and any other nested code (none today) would be signed here too.
# Release entitlements: the project's plus nothing debug-only (no get-task-allow).
REL_ENT=$(mktemp -t backline-ent).plist
cp Backline/Backline.entitlements "$REL_ENT"
/usr/libexec/PlistBuddy -c "Delete :com.apple.security.get-task-allow" "$REL_ENT" 2>/dev/null || true
codesign -f -s "$DEVID" --options runtime --timestamp --entitlements "$REL_ENT" "$APP"
rm -f "$REL_ENT"
# Verify the app signature and every nested Mach-O individually (a --deep --strict pass trips over
# PyInstaller's loose Python.framework wrapper, which isn't a real bundle; notarisation checks binaries).
codesign --verify --strict --verbose=1 "$APP"
find "$APP/Contents" -type f ! -type l | while read -r f; do
  kind=$(file "$f")
  if [[ "$kind" == *Mach-O* ]]; then
    info=$(codesign -dvv "$f" 2>&1 || true)
    [[ "$info" == *"Authority=Developer ID Application"* ]] || { echo "✗ not Developer ID signed: $f"; exit 1; }
  fi
done
codesign -dv "$APP" 2>&1 | grep -E "Authority=Developer ID|TeamIdentifier"

echo "▸ Building DMG"
# Drag-to-install window: the app on the left, Applications on the right, and a background that says
# what to do. Built read-write, laid out with Finder, then compressed.
mkdir -p "$DIST"
DMG="$DIST/Backline-$VERSION.dmg"
VOL="Backline $VERSION"
RW=$(mktemp -u -t backline-rw).dmg
rm -f "$DMG"
hdiutil create -size 600m -fs APFS -volname "$VOL" -ov "$RW" >/dev/null
MNT=$(hdiutil attach -nobrowse -noverify -noautoopen "$RW" | awk -F'\t' '/\/Volumes\//{print $NF}')
ditto "$APP" "$MNT/Backline.app"
ln -s /Applications "$MNT/Applications"
mkdir "$MNT/.background" && cp scripts/dmg/background.tiff "$MNT/.background/background.tiff"
# Finder layout (best effort: a headless run without Finder automation just gets the default layout).
osascript <<OSA >/dev/null 2>&1 || echo "  (Finder layout skipped — allow Terminal to control Finder for the styled window)"
tell application "Finder"
  tell disk "$VOL"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set bounds of container window to {200, 120, 860, 560}
    set opts to the icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 112
    set text size of opts to 13
    set background picture of opts to file ".background:background.tiff"
    set position of item "Backline.app" of container window to {165, 205}
    set position of item "Applications" of container window to {495, 205}
    update without registering applications
    delay 1
    close
  end tell
end tell
OSA
SetFile -a V "$MNT/.background" 2>/dev/null || chflags hidden "$MNT/.background"
sync
hdiutil detach "$MNT" -quiet || { sleep 2; hdiutil detach "$MNT" -force -quiet; }
hdiutil convert "$RW" -format ULFO -o "$DMG" >/dev/null
rm -f "$RW"
codesign --sign "Developer ID Application" --timestamp "$DMG"

echo "▸ Notarizing (this takes a few minutes)"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$DMG"
spctl --assess --type open --context context:primary-signature -v "$DMG"

echo "✓ $DMG is signed, notarized and stapled — ready to share."
shasum -a 256 "$DMG" | tee "$DMG.sha256"
