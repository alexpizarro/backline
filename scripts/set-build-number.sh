#!/bin/zsh
# Sets the build number (CURRENT_PROJECT_VERSION in project.yml) to the commit count of HEAD, the way iOS does
# it (R04): run after the last commit of a release, then commit project.yml. The number only has to go up.
#   scripts/set-build-number.sh          writes `git rev-list --count HEAD` and prints it
#   scripts/set-build-number.sh --check  prints what it would write, changes nothing
set -euo pipefail
cd "$(dirname "$0")/.."
n=$(git rev-list --count HEAD)
old=$(awk -F'"' '/CURRENT_PROJECT_VERSION/ {print $2; exit}' project.yml)
if [ "${1:-}" = "--check" ]; then echo "build number now $old; would be $n"; exit 0; fi
if [ "$n" -le "$old" ]; then echo "✗ build number $old is not below the commit count $n: it must go up" >&2; exit 1; fi
sed -i '' -E "s/^(    CURRENT_PROJECT_VERSION: )\"[0-9]+\"/\1\"$n\"/" project.yml
echo "✓ CURRENT_PROJECT_VERSION $old → $n (git rev-list --count HEAD). Run xcodegen, then commit project.yml."
