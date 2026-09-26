#!/bin/zsh
# Builds Backline's YouTube downloader from source: yt-dlp (pinned release tarball, SHA-256 checked)
# compiled to native arm64 code with Nuitka (Python → C → clang), standalone, with every dependency
# baked in. The result needs nothing installed on the Mac — no Python, no Homebrew, no pip.
#
#   scripts/build-ytdlp.sh            → Vendor/yt-dlp/yt-dlp-native-arm64.zip (+ .sha256, BUILD-INFO.txt)
#
# Build-machine requirements (developer only, never the user's Mac): Xcode command-line tools and `uv`.
# Upstream: https://github.com/yt-dlp/yt-dlp (Unlicense) · Nuitka: https://nuitka.net (AGPL compiler;
# compiled output is not covered by the AGPL — see Nuitka's license FAQ).
set -euo pipefail
cd "$(dirname "$0")/.."

YTDLP_VERSION=2026.08.19
YTDLP_SHA256=072aad4f2a7604e92155f61a275a4752dc64046c8f6d90df3710525d94cd37c1   # yt-dlp.tar.gz from SHA2-256SUMS
PYTHON_VERSION=3.13
NUITKA_VERSION=4.2.2
# yt-dlp's "default" extras, pinned — minus curl_cffi (YouTube doesn't need it; it would add a native curl
# build) and mutagen (GPL; only used to embed thumbnails/tags into media, which Backline never asks for).
DEPS=(certifi==2026.7.22 pycryptodomex==3.23.0 brotli==1.2.0 "websockets==17.1" "yt-dlp-ejs==0.8.0"
      "requests==2.34.2" "urllib3==2.8.0")

WORK=${WORK:-$PWD/build/ytdlp}
OUT=Vendor/yt-dlp/yt-dlp-native-arm64.zip
mkdir -p "$WORK" Vendor/yt-dlp

echo "▸ Source yt-dlp $YTDLP_VERSION"
TAR="$WORK/yt-dlp-$YTDLP_VERSION.tar.gz"
[ -f "$TAR" ] || curl -fsSL -o "$TAR" "https://github.com/yt-dlp/yt-dlp/releases/download/$YTDLP_VERSION/yt-dlp.tar.gz"
echo "$YTDLP_SHA256  $TAR" | shasum -a 256 -c - >/dev/null || { echo "✗ source checksum mismatch"; exit 1; }
rm -rf "$WORK/src"; mkdir -p "$WORK/src"; tar -xzf "$TAR" -C "$WORK/src"
SRC="$WORK/src/yt-dlp"

echo "▸ Build environment (Python $PYTHON_VERSION, Nuitka $NUITKA_VERSION)"
PIN="managed-$PYTHON_VERSION nuitka==$NUITKA_VERSION ${DEPS[*]}"
if [ ! -f "$WORK/venv/.pin" ] || [ "$(cat "$WORK/venv/.pin")" != "$PIN" ]; then
  rm -rf "$WORK/venv"
  # A standalone CPython (python-build-standalone, managed by uv), never Homebrew or the system Python,
  # so nothing in the output links to libraries on the build Mac.
  UV_PYTHON_PREFERENCE=only-managed uv python install -q "$PYTHON_VERSION"
  UV_PYTHON_PREFERENCE=only-managed uv venv -q --python "$PYTHON_VERSION" "$WORK/venv"
  VIRTUAL_ENV="$WORK/venv" uv pip install -q "nuitka==$NUITKA_VERSION" ordered-set zstandard "${DEPS[@]}"
  echo "$PIN" > "$WORK/venv/.pin"
fi
source "$WORK/venv/bin/activate"
# mutagen may be left from an earlier pin; make sure it's gone so it can't be picked up.
uv pip uninstall -q mutagen 2>/dev/null || true

echo "▸ YouTube-only extractor set"
# Backline only ever passes a canonical https://www.youtube.com/watch?v=<id> URL (rebuilt from the id), so
# the compiled downloader carries yt-dlp's YouTube extractors plus the generic fallback, not all ~2000 sites.
# That removes >90 % of the code to compile and load (the full lazy-extractor table alone is 66 MB of C).
# yt-dlp's own module layout is unchanged; only the registry module that lists extractors is narrowed.
python - "$SRC/yt_dlp/extractor/_extractors.py" <<'PY'
import re, sys, pathlib
p = pathlib.Path(sys.argv[1]); src = p.read_text()
blocks = re.findall(r"^from \.(\w+) import (?:\([^)]*\)|[^\n]+)\n", src, flags=re.M)
keep = {"youtube", "generic"}
kept = [m.group(0) for m in re.finditer(r"^from \.(\w+) import (?:\([^)]*\)|[^\n]+)\n", src, flags=re.M) if m.group(1) in keep]
assert any("from .youtube import" in k for k in kept) and any("GenericIE" in k for k in kept), "registry layout changed"
p.write_text("# flake8: noqa: F401\n# Narrowed for Backline: YouTube + generic fallback only (see scripts/build-ytdlp.sh).\n" + "".join(kept))
print(f"  kept {len(kept)} of {len(blocks)} extractor modules")
PY
rm -f "$SRC/yt_dlp/extractor/lazy_extractors.py"

echo "▸ Compiling (this takes a while)"
rm -rf "$WORK/out"
( cd "$SRC" && python -m nuitka \
    --mode=standalone \
    --output-dir="$WORK/out" \
    --output-filename=yt-dlp \
    --include-module=yt_dlp.extractor.youtube \
    --include-module=yt_dlp.extractor.generic \
    --include-package=yt_dlp.extractor.youtube \
    --include-package=yt_dlp.postprocessor \
    --include-package=yt_dlp.downloader \
    --include-package=yt_dlp.networking \
    --include-package-data=yt_dlp_ejs \
    --include-package-data=certifi \
    --include-package=Cryptodome \
    --include-module=brotli \
    --include-package=websockets \
    --nofollow-import-to=curl_cffi,mutagen,secretstorage,xattr,pyxattr,Crypto,tkinter,test,unittest,pydoc \
    --python-flag=no_site \
    --macos-target-arch=arm64 \
    --lto=no \
    --jobs="$(sysctl -n hw.ncpu)" \
    --assume-yes-for-downloads \
    --quiet \
    yt_dlp )
DIST=$(ls -d "$WORK/out"/*.dist | head -1)

# Give every bundled dylib a neutral install name (the build machine's path is only an ID label, but it
# must not leak into the app), then check nothing outside the bundle is linked (macOS system libraries only).
find "$DIST" -type f -name "*.dylib" | while read -r f; do
  install_name_tool -id "@executable_path/$(basename "$f")" "$f" 2>/dev/null
  codesign -f -s - "$f" >/dev/null 2>&1    # ad-hoc re-seal after editing; the app build re-signs for real
done
ext=$(find "$DIST" -type f \( -perm +111 -o -name "*.so" -o -name "*.dylib" \) | while read -r f; do
  otool -L "$f" 2>/dev/null | awk 'NR>1 && /^\t/{print $1}' | { grep -v -E "^(/usr/lib/|/System/|@rpath|@loader_path|@executable_path)" || true; } \
    | sed "s|^|$(basename "$f"): |"
done | sort -u)
[ -z "$ext" ] || { echo "$ext"; echo "✗ external library references above"; exit 1; }
grep -rlq "$HOME" "$DIST" 2>/dev/null && echo "  note: build-machine paths remain only as debug strings" || true

echo "▸ Self-test"
"$DIST/yt-dlp" --version | grep -qx "$YTDLP_VERSION" || { echo "✗ version self-test failed"; exit 1; }
QJS_TEST="$WORK/qjs"; cp Vendor/quickjs/qjs-darwin-arm64 "$QJS_TEST"; chmod +x "$QJS_TEST"
"$DIST/yt-dlp" -v --ignore-config --no-js-runtimes --js-runtimes "quickjs:$QJS_TEST" \
    --skip-download --print "title" "https://www.youtube.com/watch?v=2pXa5jzaOBg" 2>&1 \
  | tee "$WORK/selftest.log" | grep -E "Optional libraries|JS runtimes|^Volatile Reaction" | head -3
grep -q "^Volatile Reaction" "$WORK/selftest.log" || { echo "✗ YouTube self-test failed"; tail -20 "$WORK/selftest.log"; exit 1; }
grep -q "JS runtimes: quickjs" "$WORK/selftest.log" || { echo "✗ bundled QuickJS not detected"; exit 1; }

echo "▸ Packaging"
rm -f "$OUT"
rm -rf "$WORK/pkg"; mkdir -p "$WORK/pkg/yt-dlp/licenses"; ditto "$DIST" "$WORK/pkg/yt-dlp"
cp "$SRC/LICENSE" "$WORK/pkg/yt-dlp/licenses/yt-dlp.txt"
# Licence texts of everything compiled in (from the installed distributions' metadata) + CPython.
python - "$WORK/pkg/yt-dlp/licenses" <<'PY'
import importlib.metadata as md, pathlib, sys, sysconfig
out = pathlib.Path(sys.argv[1])
for dist in ["certifi", "pycryptodomex", "brotli", "websockets", "requests", "urllib3", "yt-dlp-ejs"]:
    d = md.distribution(dist)
    files = [f for f in (d.files or []) if any(k in f.name.upper() for k in ("LICENSE", "LICENCE", "COPYING", "NOTICE"))]
    text = "\n\n".join(f.read_text() for f in files if f.locate().exists()) or (d.metadata.get("License") or "see project page")
    (out / f"{dist}.txt").write_text(f"{dist} {d.version}\n\n{text}")
lic = pathlib.Path(sysconfig.get_paths()["stdlib"]) / "LICENSE.txt"
(out / "cpython.txt").write_text(lic.read_text() if lic.exists() else "Python Software Foundation License")
PY
( cd "$WORK/pkg" && ditto -c -k --norsrc . "$OLDPWD/$OUT" )
shasum -a 256 "$OUT" | awk '{print $1}' > "$OUT.sha256"
cat > Vendor/yt-dlp/BUILD-INFO.txt <<EOF
yt-dlp $YTDLP_VERSION (source $YTDLP_SHA256)
compiled with Nuitka $NUITKA_VERSION, CPython $(python -c 'import platform;print(platform.python_version())'), $(xcrun clang --version | head -1)
target arm64, macOS $(sw_vers -productVersion) build host
deps: ${DEPS[*]}
output: $(basename "$OUT") sha256 $(cat "$OUT.sha256")
EOF
du -sh "$DIST" "$OUT"
echo "✓ $OUT"
