#!/bin/zsh
# Build, sign and check Backline for the Mac App Store, and (only when asked) upload it.
# The guide is docs/release-mac-app-store.md. The disk image for the website is scripts/release.sh; both can ship.
#
# One-time setup (done by the account holder):
#   Xcode ▸ Settings ▸ Accounts lists the Apple ID for team SBMJ9PMG22. Xcode signs with the distribution and
#   installer certificates Apple keeps for that account (-allowProvisioningUpdates), as the iOS uploads do.
#
# Usage:
#   scripts/appstore.sh                   archive, export the installer package, check it. Uploads nothing.
#   scripts/appstore.sh --upload          the same, then upload that archive to App Store Connect.
#   scripts/appstore.sh --upload-newest   upload the newest archive this script made and checked, without building;
#                                         it refuses when that archive is gone or isn't project.yml's version and build.
#   scripts/appstore.sh --check <pkg>     run the checks again on a package this script exported.
#
# Switches:
#   NO_SONG_SERVICE=1  build without the song service even when this Mac has its key
#   ALLOW_DIRTY=1      rehearsal only: build with uncommitted changes (never upload such a build)
#   SKIP_KIT_CHECK=1   rehearsal only: skip the kit check against the iOS app
#   ARCHIVE_DIR=…      rehearsal only: put the archive here instead of Xcode's Archives folder
#   DERIVED_DATA=…     where the build's intermediate files go (default build/dd-appstore)
set -euo pipefail
cd "$(dirname "$0")/.."

TEAM=SBMJ9PMG22
BUNDLE_ID=com.alexpizarro.backline
OPTIONS=scripts/ExportOptions-app-store.plist
OUT=build/appstore
MODE=${1:-build}
case "$MODE" in build|--upload|--upload-newest|--check) ;; *) echo "✗ Unknown option: $MODE (see the top of this script)"; exit 1 ;; esac

fail() { echo "✗ $*"; exit 1; }

# Uploads the archive at $1 through Xcode's signed-in account (as iOS build 150 was uploaded on 23 October).
upload() {
    local archive=$1 opts tmp
    opts=$(mktemp -t backline-upload).plist
    cp "$OPTIONS" "$opts"
    /usr/libexec/PlistBuddy -c "Set :destination upload" "$opts"
    tmp=$(mktemp -d -t backline-upload)
    echo "▸ Uploading $archive to App Store Connect"
    xcodebuild -exportArchive -archivePath "$archive" -exportOptionsPlist "$opts" -exportPath "$tmp" \
        -allowProvisioningUpdates
    rm -rf "$opts" "$tmp"
    echo "✓ Uploaded. App Store Connect emails you when the build has been processed (usually 15 to 60 minutes)."
}

VERSION=$(awk -F'"' '/MARKETING_VERSION/ && !v {v=$2} END {print v}' project.yml)
BUILD=$(awk -F'"' '/CURRENT_PROJECT_VERSION/ && !v {v=$2} END {print v}' project.yml)

if [ "$MODE" = --upload-newest ]; then
    # Each checked build leaves a note naming its archive. Only the newest is ever uploaded: if its archive is
    # gone, or it isn't this commit's version and build, nothing older is uploaded in its place.
    notes=("$OUT"/*.checked(Nom))
    [ ${#notes} -gt 0 ] || fail "No checked build in $OUT. Run scripts/appstore.sh first."
    note=${notes[1]}
    archive=$(head -1 "$note")
    [ -d "$archive" ] || fail "The newest checked build ($(basename "$note" .checked)) has no archive any more ($archive). Run scripts/appstore.sh again; an older build is never uploaded instead."
    ! grep -q '^rehearsal$' "$note" || fail "The newest checked build ($note) was a rehearsal; build again without the rehearsal switches."
    props() { plutil -extract "$1" raw -o - "$archive/Info.plist" 2>/dev/null || echo "?"; }
    AV=$(props ApplicationProperties.CFBundleShortVersionString)
    AB=$(props ApplicationProperties.CFBundleVersion)
    echo "▸ Newest checked build: Backline $AV ($AB), archived $(props CreationDate)"
    echo "  $archive"
    [ "$AV" = "$VERSION" ] && [ "$AB" = "$BUILD" ] \
        || fail "That archive is $AV ($AB), but project.yml says $VERSION ($BUILD). Run scripts/appstore.sh again."
    upload "$archive"; exit 0
fi

echo "▸ Backline $VERSION ($BUILD) for the Mac App Store"

if [ "$MODE" = --check ]; then
    PKG=${2:-}; [ -f "$PKG" ] || fail "Usage: scripts/appstore.sh --check build/appstore/Backline-<version>-<build>.pkg"
    ARCHIVE=""; REHEARSAL=1
    if [ "${NO_SONG_SERVICE:-0}" != 1 ] && [ -f Config/SongService.prod.local.xcconfig ]; then WANT_SERVICE=1; else WANT_SERVICE=0; fi
else

# --- Refusals -----------------------------------------------------------------------------------------------
[ -z "${BACKLINE_YTDLP:-}" ] || fail "BACKLINE_YTDLP is set. The Mac App Store build never carries yt-dlp: unset it and run again."
REHEARSAL=0
if [ -n "$(git status --porcelain)" ]; then
    if [ "${ALLOW_DIRTY:-0}" = 1 ]; then echo "! Uncommitted changes (ALLOW_DIRTY=1): a rehearsal, not for upload."; REHEARSAL=1
    else git status --short; fail "There are uncommitted changes. Commit them first (ALLOW_DIRTY=1 is for a rehearsal only)."; fi
fi
if [ "${SKIP_KIT_CHECK:-0}" = 1 ]; then echo "! Kit check skipped (SKIP_KIT_CHECK=1): a rehearsal, not for upload."; REHEARSAL=1
else zsh scripts/kit-sync-check.sh || fail "The kit differs from the iOS app's (scripts/kit-sync-check.sh)."; fi
[ -z "${ARCHIVE_DIR:-}" ] || REHEARSAL=1
[ "$REHEARSAL" = 0 ] || [ "$MODE" != --upload ] || fail "--upload can't be used with a rehearsal switch (ALLOW_DIRTY, SKIP_KIT_CHECK, ARCHIVE_DIR)."

# --- The song service ---------------------------------------------------------------------------------------
# As for the disk image: Config/Release.xcconfig includes the git-ignored file song-service-config.sh writes from
# ~/.config/audiointel/prod.env. The key is never printed here.
SERVICE_ARGS=()
if [ "${NO_SONG_SERVICE:-0}" = 1 ]; then
    WANT_SERVICE=0; SERVICE_ARGS=(BL_SONG_SERVICE_URL= BL_SONG_SERVICE_KEY=)
    echo "▸ Song service: left out (NO_SONG_SERVICE=1)"
else
    if [ -x scripts/song-service-config.sh ] && [ -f "$HOME/.config/audiointel/prod.env" ]; then
        bash scripts/song-service-config.sh | sed 's/^/  /'
    fi
    if [ -f Config/SongService.prod.local.xcconfig ]; then WANT_SERVICE=1; echo "▸ Song service: in this build"
    else WANT_SERVICE=0; echo "▸ Song service: not on this Mac, so not in this build"; fi
fi

XCODEGEN=${XCODEGEN:-$(command -v xcodegen || echo ~/.local/tools/xcodegen/bin/xcodegen)}
"$XCODEGEN" generate >/dev/null
git lfs pull >/dev/null 2>&1 || true

# --- Archive ------------------------------------------------------------------------------------------------
STAMP=$(date +%Y-%m-%d)
DIR=${ARCHIVE_DIR:-$HOME/Library/Developer/Xcode/Archives/$STAMP}
mkdir -p "$DIR" "$OUT"
ARCHIVE="$DIR/Backline Mac App Store $VERSION ($BUILD) $(date +%H.%M.%S).xcarchive"
DD=${DERIVED_DATA:-build/dd-appstore}
echo "▸ Archiving into $ARCHIVE"
# BACKLINE_APP_STORE=1 leaves out the private function the disk image uses to name a web page's audio (2.5.1).
xcodebuild -project Backline.xcodeproj -scheme Backline -configuration Release \
    -derivedDataPath "$DD" -archivePath "$ARCHIVE" -destination 'generic/platform=macOS' -allowProvisioningUpdates \
    BACKLINE_APP_STORE=1 BACKLINE_YTDLP= BACKLINE_ID_SUFFIX= "${SERVICE_ARGS[@]}" archive -quiet
# The Organizer lists it with this comment beside the iOS archives.
/usr/libexec/PlistBuddy -c "Add :Comment string Mac App Store" "$ARCHIVE/Info.plist" 2>/dev/null || true

# --- Export the installer package ---------------------------------------------------------------------------
echo "▸ Exporting the installer package"
EXPORT=$(mktemp -d -t backline-export)
LOG="$OUT/export-$VERSION-$BUILD.log"
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist "$OPTIONS" -exportPath "$EXPORT" \
    -allowProvisioningUpdates > "$LOG" 2>&1 || { tail -30 "$LOG"; fail "The export failed (full log: $LOG)."; }
grep -iE "warning" "$LOG" | sed 's/^/  export: /' || true
PKG="$OUT/Backline-$VERSION-$BUILD.pkg"
[ -f "$EXPORT/Backline.pkg" ] || { ls -la "$EXPORT"; fail "The export made no Backline.pkg."; }
mv -f "$EXPORT/Backline.pkg" "$PKG"
rm -rf "$EXPORT"
fi

# --- Checks, without running anything -----------------------------------------------------------------------
echo "▸ Checking $PKG"
SIG=$(pkgutil --check-signature "$PKG" 2>&1) || { echo "$SIG"; fail "The package's signature doesn't check out."; }
echo "$SIG" | sed -n '/Status/,$p' | sed 's/^/  /'
[[ "$SIG" == *"Status: signed"* ]] || fail "The package is not signed."
FIRST=$(echo "$SIG" | awk '/^ *1\. / && !n {sub(/^ *1\. /, ""); print; n=1}')
[[ "$FIRST" == *Installer* ]] || fail "The package is signed by '$FIRST', not an installer certificate."

WORK=$(mktemp -d -t backline-pkg)
trap 'rm -rf "$WORK"' EXIT
pkgutil --expand-full "$PKG" "$WORK/x" >/dev/null
APP=$(find "$WORK/x" -maxdepth 4 -type d -name Backline.app -print -quit)
[ -n "$APP" ] || fail "No Backline.app inside the package."
BIN="$APP/Contents/MacOS/Backline"

codesign --verify --deep --strict --verbose=1 "$APP" 2>&1 | sed 's/^/  /'
codesign --verify --deep --strict "$APP" 2>/dev/null || fail "The app's code signature does not verify."

# Every Mach-O file (the app, the LAME library in Contents/Frameworks, anything else) is signed by one identity.
authority() { awk -F= '/^Authority=/ && !n {print $2; n=1}'; }
LEAF=$(codesign -dvv "$APP" 2>&1 | authority)
[[ "$LEAF" == "Apple Distribution"* || "$LEAF" == "3rd Party Mac Developer Application"* ]] \
    || fail "The app is signed by '$LEAF', not a distribution identity."
COUNT=0
while IFS= read -r f; do
    [[ "$(file -b "$f")" == *Mach-O* ]] || continue
    info=$(codesign -dvv "$f" 2>&1 || true)
    a=$(echo "$info" | authority)
    [ "$a" = "$LEAF" ] || fail "${f#$APP/} is signed by '$a', not '$LEAF'."
    [[ "$info" == *$'\n'"TeamIdentifier=$TEAM"$'\n'* ]] || fail "${f#$APP/} has another team."
    COUNT=$((COUNT + 1))
done < <(find "$APP/Contents" -type f)
echo "  $COUNT Mach-O files, all signed by $LEAF"
[ -f "$APP/Contents/Frameworks/libmp3lame.0.dylib" ] || fail "The LAME library is missing from Contents/Frameworks."

ENT="$WORK/entitlements.plist"
codesign -d --entitlements - --xml "$APP" > "$ENT" 2>/dev/null
ent() { /usr/libexec/PlistBuddy -c "Print :$1" "$ENT" 2>/dev/null || true; }
[ "$(ent com.apple.security.app-sandbox)" = true ] || fail "The app sandbox is not on."
[ "$(ent com.apple.application-identifier)" = "$TEAM.$BUNDLE_ID" ] || fail "The application identifier is not $TEAM.$BUNDLE_ID."
[ "$(ent com.apple.developer.team-identifier)" = "$TEAM" ] || fail "The team identifier is not $TEAM."
[ "$(ent com.apple.security.get-task-allow)" != true ] || fail "get-task-allow is on (a debug entitlement)."
[ "$(ent com.apple.security.files.bookmarks.app-scope)" = true ] \
    || fail "The app-scope bookmark entitlement is missing (Try again on a person's own file needs it)."
echo "  entitlements: $(plutil -convert json -o - "$ENT" | tr -d '\n')"

PROFILE="$APP/Contents/embedded.provisionprofile"
[ -f "$PROFILE" ] || fail "embedded.provisionprofile is missing."
PROF="$WORK/profile.plist"
security cms -D -i "$PROFILE" > "$PROF" 2>/dev/null || fail "embedded.provisionprofile can't be read."
! plutil -extract ProvisionedDevices raw -o - "$PROF" >/dev/null 2>&1 \
    || fail "The embedded profile lists devices: a development profile, not the App Store's."
echo "  profile: $(plutil -extract Name raw -o - "$PROF" 2>/dev/null), until $(plutil -extract ExpirationDate raw -o - "$PROF" 2>/dev/null)"

[ ! -e "$APP/Contents/Resources/yt-dlp" ] || fail "Contents/Resources/yt-dlp is in the app."
! grep -q responsibility_get_pid_responsible_for_pid "$BIN" \
    || fail "The binary names a private function (built without BACKLINE_APP_STORE=1?)."
ARCHS=$(lipo -archs "$BIN")
[ "$ARCHS" = arm64 ] || fail "The binary is '$ARCHS', not arm64 only."

PL="$APP/Contents/Info.plist"
key() { plutil -extract "$1" raw -o - "$PL" 2>/dev/null || true; }
[ "$(key CFBundleIdentifier)" = "$BUNDLE_ID" ] || fail "The bundle id is $(key CFBundleIdentifier)."
[ "$(key CFBundleShortVersionString)" = "$VERSION" ] || fail "The version is $(key CFBundleShortVersionString), not $VERSION."
[ "$(key CFBundleVersion)" = "$BUILD" ] || fail "The build number is $(key CFBundleVersion), not $BUILD."
[ "$(key LSApplicationCategoryType)" = public.app-category.music ] || fail "The category is '$(key LSApplicationCategoryType)'."
[ "$(key LSMinimumSystemVersion)" = 15.0 ] || fail "LSMinimumSystemVersion is '$(key LSMinimumSystemVersion)'."
[ "$(key ITSAppUsesNonExemptEncryption)" = false ] || fail "ITSAppUsesNonExemptEncryption is not false."
# Apple's required-reason APIs: the app's own privacy manifest declares what the binary uses (ITMS-91053).
PRIV="$APP/Contents/Resources/PrivacyInfo.xcprivacy"
[ -f "$PRIV" ] || fail "Contents/Resources/PrivacyInfo.xcprivacy is missing (Backline/PrivacyInfo.xcprivacy)."
DECLARED=$(plutil -convert json -o - "$PRIV" 2>/dev/null | python3 -c '
import json, sys
for t in json.load(sys.stdin).get("NSPrivacyAccessedAPITypes", []):
    if t.get("NSPrivacyAccessedAPITypeReasons"): print(t["NSPrivacyAccessedAPIType"].replace("NSPrivacyAccessedAPICategory", ""))
') || fail "PrivacyInfo.xcprivacy can't be read."
for c in UserDefaults FileTimestamp DiskSpace; do
    grep -qx "$c" <<< "$DECLARED" || fail "PrivacyInfo.xcprivacy doesn't declare $c with a reason."
done
if grep -q -a systemUptime "$BIN" && ! grep -qx SystemBootTime <<< "$DECLARED"; then
    fail "The binary uses systemUptime (a boot-time API) and the privacy manifest doesn't declare SystemBootTime."
fi
echo "  privacy manifest: $(echo "$DECLARED" | tr '\n' ' ')"

URL=$(key BLSongServiceBaseURL)
if [ "$WANT_SERVICE" = 1 ]; then
    # The address this Mac's git-ignored config holds (scripts/song-service-config.sh writes "/$()/" for "//").
    WANT_URL=$(sed -n 's/^BL_SONG_SERVICE_URL = //p' Config/SongService.prod.local.xcconfig | head -1 | sed 's#/\$()/#//#')
    [ -n "$URL" ] && [ "$URL" = "$WANT_URL" ] || fail "The song service's prod address is missing or isn't this Mac's."
    [ -n "$(key BLSongServiceKey)" ] || fail "The song service's key is missing."
    echo "  song service: present (prod address; key present, not shown)"
else
    [ -z "$URL" ] && [ -z "$(key BLSongServiceKey)" ] || fail "The song service is in a build that was told to leave it out."
    echo "  song service: absent, as asked"
fi

echo "  package: $(du -h "$PKG" | cut -f1)  app: $(du -sh "$APP" | cut -f1)${ARCHIVE:+  archive: $(du -sh "$ARCHIVE" | cut -f1)}"
echo "✓ $PKG passed every check."
[ "$MODE" != --check ] || exit 0
{ echo "$ARCHIVE"; [ "$REHEARSAL" = 0 ] || echo rehearsal; } > "$OUT/Backline-$VERSION-$BUILD.checked"
echo "  Archive: $ARCHIVE"

if [ "$MODE" = --upload ]; then upload "$ARCHIVE"
else echo "  Nothing was uploaded. To upload this build: scripts/appstore.sh --upload-newest"; fi
