#!/bin/zsh
# Xcode build phase: unpack the YouTube downloader into the app and sign it for the sandbox.
#
# Default: our own native build of yt-dlp (compiled from source with Nuitka by scripts/build-ytdlp.sh,
# Vendor/yt-dlp/yt-dlp-native-arm64.zip). Rollback: YTDLP_FLAVOR=pyinstaller uses the official
# PyInstaller release (Vendor/yt-dlp/yt-dlp_macos.zip). Either way the launcher is Resources/yt-dlp/yt-dlp.
set -euo pipefail
SRC="${SRCROOT}/Vendor/yt-dlp"
DST="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/yt-dlp"
FLAVOR=${YTDLP_FLAVOR:-native}
[ "$FLAVOR" = native ] && [ ! -f "$SRC/yt-dlp-native-arm64.zip" ] && FLAVOR=pyinstaller

if [ "$FLAVOR" = native ]; then
  ZIP="$SRC/yt-dlp-native-arm64.zip"
  expected=$(cat "$ZIP.sha256")
else
  ZIP="$SRC/yt-dlp_macos.zip"
  expected=$(awk '$2=="yt-dlp_macos.zip"{print $1}' "$SRC/SHA2-256SUMS")
fi
actual=$(shasum -a 256 "$ZIP" | awk '{print $1}')
[ "$expected" = "$actual" ] || { echo "error: $(basename "$ZIP") checksum mismatch"; exit 1; }
# QuickJS-NG: the JS runtime yt-dlp uses for YouTube's challenge solver (never the user's Deno/Node).
QJS="${SRCROOT}/Vendor/quickjs/qjs-darwin-arm64"
qjs_expected=$(awk '{print $1}' "${SRCROOT}/Vendor/quickjs/SHA256")
qjs_actual=$(shasum -a 256 "$QJS" | awk '{print $1}')
[ "$qjs_expected" = "$qjs_actual" ] || { echo "error: qjs checksum mismatch"; exit 1; }
STAMP="$DST/.sha256"
if [ -f "$STAMP" ] && [ "$(cat "$STAMP")" = "$FLAVOR-$actual-$qjs_actual-${EXPANDED_CODE_SIGN_IDENTITY:--}" ]; then exit 0; fi
rm -rf "$DST"; mkdir -p "$DST"

if [ "$FLAVOR" = native ]; then
  ditto -x -k "$ZIP" "$DST/.."          # the zip holds a top-level yt-dlp/ folder
else
  ditto -x -k "$ZIP" "$DST"
  mv "$DST/yt-dlp_macos" "$DST/yt-dlp"
  # The release zip stores Python.framework's symlinks as duplicate copies, which makes the framework
  # malformed (its signature can't validate, so notarisation rejects it). Rebuild the canonical layout.
  FW="$DST/_internal/Python.framework"
  if [ -d "$FW/Versions" ]; then
    V=$(ls "$FW/Versions" | grep -v '^Current$' | head -1)
    rm -rf "$FW/Versions/Current" "$FW/Python" "$FW/Resources"
    ln -s "$V" "$FW/Versions/Current"
    ln -s "Versions/Current/Python" "$FW/Python"
    ln -s "Versions/Current/Resources" "$FW/Resources"
    rm -f "$DST/_internal/Python"
    ln -s "Python.framework/Versions/$V/Python" "$DST/_internal/Python"
  fi
fi
cp "$QJS" "$DST/qjs"; chmod 755 "$DST/qjs"
cp "${SRCROOT}/Vendor/quickjs/LICENSE" "$DST/QuickJS-LICENSE.txt"

ID="${EXPANDED_CODE_SIGN_IDENTITY:--}"
[ -z "$ID" ] && ID="-"
ENT="${SRCROOT}/scripts/ytdlp-helper.entitlements"
# Inside-out: every library first, then the framework bundle (PyInstaller only), then the executables
# that run as processes (launcher, qjs) with sandbox inheritance.
find "$DST" -type f ! -path "$DST/yt-dlp" ! -path "$DST/qjs" ! -path "*/Python.framework/*" | while read -r f; do
  if file "$f" | grep -q "Mach-O"; then
    codesign -f -s "$ID" --options runtime --timestamp=none "$f" >/dev/null 2>&1 || true
    codesign -d "$f" >/dev/null 2>&1 || { echo "error: signing $f"; exit 1; }
  fi
done
FW="$DST/_internal/Python.framework"
if [ -d "$FW/Versions" ]; then
  V=$(ls "$FW/Versions" | grep -v '^Current$' | head -1)
  codesign -f -s "$ID" --options runtime --timestamp=none "$FW/Versions/$V" >/dev/null
  codesign -v --strict "$FW/Versions/$V" >/dev/null 2>&1 || { echo "error: Python.framework signature"; exit 1; }
fi
codesign -f -s "$ID" --options runtime --timestamp=none --entitlements "$ENT" "$DST/qjs" >/dev/null
codesign -f -s "$ID" --options runtime --timestamp=none --entitlements "$ENT" "$DST/yt-dlp" >/dev/null
echo "$FLAVOR-$actual-$qjs_actual-$ID" > "$STAMP"
