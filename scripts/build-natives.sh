#!/bin/zsh
# Builds the two small native helpers Backline bundles, from source, for macOS 15 and later (arm64):
#   Vendor/lame/libmp3lame.0.dylib     LAME 3.100 (MP3 export)
#   Vendor/quickjs/qjs-darwin-arm64    QuickJS-NG 0.17.0 (JavaScript engine for YouTube's checks)
# Sources are pinned and checksum-verified. Needs only Xcode's command-line tools (no cmake, no Homebrew).
set -euo pipefail
cd "$(dirname "$0")/.."
MIN=15.0
WORK=${WORK:-$PWD/build/natives}
mkdir -p "$WORK"
export MACOSX_DEPLOYMENT_TARGET=$MIN
CFLAGS_COMMON="-arch arm64 -mmacosx-version-min=$MIN -O3"

fetch() { # url sha256 out
  [ -f "$3" ] || curl -fsSL -o "$3" "$1"
  echo "$2  $3" | shasum -a 256 -c - >/dev/null || { echo "✗ checksum mismatch: $1"; exit 1; }
}

echo "▸ LAME 3.100"
LAME_TGZ="$WORK/lame-3.100.tar.gz"
fetch https://downloads.sourceforge.net/project/lame/lame/3.100/lame-3.100.tar.gz \
      ddfe36cab873794038ae2c1210557ad34857a4b6bdc515785d1da9e175b1da1e "$LAME_TGZ"
rm -rf "$WORK/lame-3.100"; tar -xzf "$LAME_TGZ" -C "$WORK"
# 3.100 exports a symbol that no longer exists; drop it from the export list (upstream fix, unreleased).
sed -i '' '/lame_init_old/d' "$WORK/lame-3.100/include/libmp3lame.sym"
( cd "$WORK/lame-3.100" && CFLAGS="$CFLAGS_COMMON" LDFLAGS="-arch arm64 -mmacosx-version-min=$MIN" \
    ./configure --host=aarch64-apple-darwin --disable-frontend --disable-static --enable-shared \
    --disable-dependency-tracking --prefix="$WORK/lame-out" >/dev/null && make -j"$(sysctl -n hw.ncpu)" >/dev/null && make install >/dev/null )
cp "$WORK/lame-out/lib/libmp3lame.0.dylib" Vendor/lame/libmp3lame.0.dylib
install_name_tool -id "@rpath/libmp3lame.0.dylib" Vendor/lame/libmp3lame.0.dylib
codesign -f -s - Vendor/lame/libmp3lame.0.dylib >/dev/null

echo "▸ QuickJS-NG 0.17.0"
QJS_TGZ="$WORK/quickjs-ng-0.17.0.tar.gz"
fetch https://github.com/quickjs-ng/quickjs/archive/refs/tags/v0.17.0.tar.gz \
      "$(cat Vendor/quickjs/SOURCE_SHA256)" "$QJS_TGZ"
rm -rf "$WORK/quickjs-0.17.0"; tar -xzf "$QJS_TGZ" -C "$WORK"
( cd "$WORK/quickjs-0.17.0" && xcrun clang $=CFLAGS_COMMON -funsigned-char -D_GNU_SOURCE -DQUICKJS_NG_BUILD -DQJS_BUILD_LIBC \
    -I. -w dtoa.c libregexp.c libunicode.c quickjs.c quickjs-libc.c gen/repl.c gen/standalone.c qjs.c -lm -o qjs )
cp "$WORK/quickjs-0.17.0/qjs" Vendor/quickjs/qjs-darwin-arm64
chmod 755 Vendor/quickjs/qjs-darwin-arm64
codesign -f -s - Vendor/quickjs/qjs-darwin-arm64 >/dev/null
shasum -a 256 Vendor/quickjs/qjs-darwin-arm64 | awk '{print $1"  qjs-darwin-arm64"}' > Vendor/quickjs/SHA256

echo "▸ Check"
for f in Vendor/lame/libmp3lame.0.dylib Vendor/quickjs/qjs-darwin-arm64; do
  m=$(vtool -show-build "$f" | awk '/minos/{print $2}')
  deps=$(otool -L "$f" | awk 'NR>1{print $1}' | grep -v -E "^(/usr/lib/|/System/|@rpath)" || true)
  echo "  $(basename "$f"): minos $m ${deps:+(external: $deps)}"
  [ "$m" = "$MIN" ] && [ -z "$deps" ] || { echo "✗ $f"; exit 1; }
done
Vendor/quickjs/qjs-darwin-arm64 -e 'print("qjs ok")'
echo "✓ native helpers built for macOS $MIN+"
