#!/bin/zsh
# Compares two yt-dlp builds on the things Backline does: start-up, metadata for a YouTube video
# (includes the JS challenge via the bundled QuickJS), and a full audio download.
#   scripts/bench-ytdlp.sh <yt-dlp A> <yt-dlp B> [runs]
set -uo pipefail
A=$1; B=$2; RUNS=${3:-5}
QJS=${QJS:-$(cd "$(dirname "$0")/.." && pwd)/Vendor/quickjs/qjs-darwin-arm64}
URL=https://www.youtube.com/watch?v=2pXa5jzaOBg     # Kevin MacLeod, "Volatile Reaction" (CC BY)
common=(--ignore-config --no-plugin-dirs --no-cookies-from-browser --no-cookies --no-js-runtimes --js-runtimes "quickjs:$QJS" --no-warnings)
now() { perl -MTime::HiRes=time -e 'printf "%.3f\n", time'; }
median() { sort -n | awk '{a[NR]=$1} END{print (NR%2 ? a[(NR+1)/2] : (a[NR/2]+a[NR/2+1])/2)}'; }

bench() { # name bin kind
  local bin=$2 kind=$3 t0 t1
  for i in $(seq $RUNS); do
    T=$(mktemp -d)
    t0=$(now)
    case $kind in
      startup) env -i HOME=$HOME PATH=/usr/bin:/bin "$bin" --version >/dev/null 2>&1 ;;
      meta)    env -i HOME=$HOME PATH=/usr/bin:/bin "$bin" "${common[@]}" --cache-dir "$T/c" --skip-download --print id "$URL" >/dev/null 2>&1 ;;
      download) env -i HOME=$HOME PATH=/usr/bin:/bin "$bin" "${common[@]}" --cache-dir "$T/c" -f "bestaudio[ext=m4a]/bestaudio[acodec^=mp4a]" -o "$T/%(id)s.%(ext)s" "$URL" >/dev/null 2>&1 ;;
    esac
    rc=$?
    t1=$(now)
    [ $rc -eq 0 ] || echo "  ($1 $kind run $i failed rc=$rc)" >&2
    echo "$t1 - $t0" | bc
    rm -rf "$T"
  done | median
}

printf "%-10s %12s %12s\n" "" "A" "B"
for k in startup meta download; do
  a=$(bench A "$A" $k); b=$(bench B "$B" $k)
  printf "%-10s %11.2fs %11.2fs\n" $k $a $b
done
