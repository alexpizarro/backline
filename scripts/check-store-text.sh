#!/bin/zsh
# Checks the Mac App Store listing text in fastlane/metadata-mac against App Store Connect's limits, and the public
# fields against the words rule (no video site, music service or other platform named). The review notes are read
# only by App Review and name what the link feature opens, as the iOS notes do (guideline 2.5.19), so they are
# checked for length only.
#   scripts/check-store-text.sh
set -euo pipefail
cd "$(dirname "$0")/../fastlane/metadata-mac"
bad=0
limit() {  # file, most characters
    [ -f "$1" ] || { echo "✗ missing: $1"; bad=1; return; }
    local n; n=$(python3 -c 'import sys; print(len(open(sys.argv[1], encoding="utf-8").read().rstrip("\n")))' "$1")
    if [ "$n" -gt "$2" ]; then echo "✗ $1: $n characters, at most $2"; bad=1; else echo "  $1: $n of $2"; fi
}
limit en-AU/description.txt 4000
limit en-AU/keywords.txt 100
limit en-AU/promotional_text.txt 170
limit en-AU/release_notes.txt 4000
limit en-AU/support_url.txt 255
limit en-AU/marketing_url.txt 255
limit en-AU/copyright.txt 200
limit review_information/notes.txt 4000
words='youtube|spotify|vimeo|soundcloud|apple music|tidal|deezer|tiktok|instagram|iphone|ipad|android|google play|disk image|dmg'
if hits=$(grep -inE "$words" en-AU/*.txt); then echo "$hits" | sed 's/^/✗ names a service or platform: /'; bad=1; fi
[ "$bad" = 0 ] && echo "✓ listing text is within the limits" || exit 1
