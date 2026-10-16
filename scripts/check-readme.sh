#!/bin/zsh
# Fails when the README is out of date for a release. Run by scripts/release.sh (before the long build) and by
# scripts/publish-public.sh (as part of the gate), so a release cannot go out with a stale README.
#
#   scripts/check-readme.sh [tree] [version]     tree defaults to this repo, version to project.yml
#
# The README ends with two hidden stamps:
#   <!-- readme-reviewed-for: 0.17 -->       set BY HAND after reading the README against this release
#   <!-- screenshots-taken-with: 0.17 -->    set by scripts/readme-shots.sh when it retakes the pictures
# Both must equal the version being released. See docs/release-checklist.md.
set -uo pipefail
cd "$(dirname "$0")/.."
TREE=${1:-.}
VERSION=${2:-$(awk -F'"' '/MARKETING_VERSION/ {print $2; exit}' project.yml)}
README="$TREE/README.md"
fail=0

[ -f "$README" ] || { echo "✗ no README.md in $TREE"; exit 1; }

reviewed=$(grep -o 'readme-reviewed-for: [0-9][0-9.]*' "$README" | awk '{print $2}' | tail -1)
shots=$(grep -o 'screenshots-taken-with: [0-9][0-9.]*' "$README" | awk '{print $2}' | tail -1)
[ "$reviewed" = "$VERSION" ] || { echo "✗ README was not reviewed for $VERSION (stamp says: ${reviewed:-none})"; fail=1; }
[ "$shots" = "$VERSION" ] || { echo "✗ README screenshots were not retaken for $VERSION (stamp says: ${shots:-none})"; fail=1; }

# Every picture the README uses must exist.
for img in $(grep -o 'docs/images/[A-Za-z0-9._-]*\.png' "$README" | sort -u); do
  [ -f "$TREE/$img" ] || { echo "✗ the README shows $img but the file is missing"; fail=1; }
done

# The download link must be there.
grep -q 'releases/latest/download/Backline.dmg' "$README" || { echo "✗ the README has no download link"; fail=1; }

# Warnings (they don't block): unused pictures, old version numbers, a stale comparison page.
for f in "$TREE"/docs/images/*.png(N); do
  grep -q "docs/images/${f:t}" "$README" || echo "! docs/images/${f:t} is not used by the README (delete it?)"
done
for v in $(grep -o '`v[0-9][0-9]*\.[0-9][0-9.]*`' "$README" | tr -d '`v' | sort -u); do
  [ "$v" = "$VERSION" ] || echo "! the README mentions version $v: is that on purpose?"
done
if [ -f "$TREE/docs/comparison-stemdeck.md" ] && ! grep -q "for Backline $VERSION" "$TREE/docs/comparison-stemdeck.md"; then
  echo "! docs/comparison-stemdeck.md is not marked 'for Backline $VERSION': does it still match the app?"
fi

if [ $fail -ne 0 ]; then
  echo ""
  echo "Update the README before releasing $VERSION:"
  echo "  1. scripts/readme-shots.sh        retakes every picture from the real app"
  echo "  2. read README.md against the release notes; fix anything that changed"
  echo "  3. set <!-- readme-reviewed-for: $VERSION --> at the end of README.md"
  exit 1
fi
echo "✓ README is current for $VERSION"
