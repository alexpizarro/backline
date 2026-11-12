#!/bin/zsh
# Fails when BacklineKit, or the link engine, here differs from the sibling app's repository (iOS and Mac share
# both byte for byte: the kit, and from 1.1 the link engine in Backline/App/YouTube, Backline/App/Links and
# Backline/App/YouTubeImport.swift, decision D10). Run by scripts/release.sh and scripts/publish-public.sh, so drift is caught at release instead
# of in an audit. The same script lives in both repositories.
#
#   scripts/kit-sync-check.sh [other-repo]
#
# other-repo defaults to KIT_SYNC_OTHER, then to the sibling checkout next to this repository's main checkout
# (backline-ios for the Mac, backline-mac for iOS). Works from a worktree too.
set -uo pipefail
cd "$(dirname "$0")/.."
HERE=$PWD

main_checkout=$(dirname "$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null || echo "$HERE/.git")")
case "$(basename "$main_checkout")" in
  backline-mac) sibling=backline-ios ;;
  backline-ios) sibling=backline-mac ;;
  *) sibling="" ;;
esac
OTHER=${1:-${KIT_SYNC_OTHER:-${sibling:+$(dirname "$main_checkout")/$sibling}}}

[ -n "$OTHER" ] && [ -d "$OTHER/BacklineKit" ] || {
  echo "✗ kit sync: no sibling BacklineKit found (pass the other repository's path, or set KIT_SYNC_OTHER)"; exit 1; }

fail=0
out=$(diff -rq -x .build -x .DS_Store -x .swiftpm "$HERE/BacklineKit" "$OTHER/BacklineKit" 2>&1)
if [ -n "$out" ]; then
  echo "✗ BacklineKit differs from $OTHER/BacklineKit:"
  echo "$out" | sed "s|$HERE/||; s|$OTHER/|other: |"
  fail=1
else
  echo "✓ BacklineKit is identical to $OTHER/BacklineKit"
fi

# The link engine. A file in either repository's folders must be in both and the same, except the few that are
# one platform's own (the iOS sign-in web view is UIKit; the Mac's sign-in lives outside these folders).
LINK_DIRS=(Backline/App/YouTube Backline/App/Links)
LINK_FILES=(Backline/App/YouTubeImport.swift)
PLATFORM_ONLY=(Backline/App/YouTube/SignInWebView.swift)
typeset -U names
names=($LINK_FILES)
for d in $LINK_DIRS; do
  for side in "$HERE" "$OTHER"; do
    [ -d "$side/$d" ] && for f in "$side/$d"/*.swift(N); do names+=("$d/${f:t}"); done
  done
done
link_bad=(); compared=0
for f in ${(o)names}; do
  (( ${PLATFORM_ONLY[(Ie)$f]} )) && continue
  compared=$((compared + 1))
  if [ ! -f "$HERE/$f" ]; then link_bad+=("only in other: $f")
  elif [ ! -f "$OTHER/$f" ]; then link_bad+=("only here: $f")
  elif ! cmp -s "$HERE/$f" "$OTHER/$f"; then link_bad+=("differs: $f")
  fi
done
if (( ${#link_bad} )); then
  echo "✗ the link engine differs from $OTHER:"
  printf '  %s\n' $link_bad
  fail=1
else
  echo "✓ the link engine ($compared files) is identical to $OTHER"
fi
exit $fail
