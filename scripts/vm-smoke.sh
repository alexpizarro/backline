#!/bin/zsh
# Tests the notarized DMG inside a clean macOS VM (Tart), the way a new user gets it:
#   download → first-launch "Open" prompt → add a song → split (incl. lead/rhythm) → save a backing track,
#   plus the bundled YouTube downloader on that macOS version.
#   scripts/vm-smoke.sh <tart image> <dmg> <song.mp3>
#   VM_NO_QUARANTINE=1 skips the Gatekeeper download flag (only for testing a DMG that isn't notarized yet).
# The throwaway VM images log in as admin/admin and let the script click buttons like a user would.
set -uo pipefail
IMG=$1; DMG=$2; SONG=$3
TART=${TART:-$HOME/.local/tools/tart/tart.app/Contents/MacOS/tart}
VM="backline-test-$(basename "$IMG" | tr ':/' '--')"
SHARE=$(mktemp -d)
cp "$DMG" "$SHARE/Backline.dmg"; cp "$SONG" "$SHARE/song.mp3"
echo "${VM_NO_QUARANTINE:-0}" > "$SHARE/no-quarantine"

"$TART" delete "$VM" >/dev/null 2>&1
"$TART" clone "$IMG" "$VM" || exit 1
"$TART" set "$VM" --cpu ${VM_CPU:-6} --memory ${VM_MEMORY:-8192} >/dev/null
"$TART" run "$VM" --no-graphics --dir=share:"$SHARE" >/dev/null 2>&1 &
RUN=$!
for i in {1..90}; do IP=$("$TART" ip "$VM" 2>/dev/null) && [ -n "$IP" ] && break; sleep 2; done
ASK="$SHARE/askpass"; printf '#!/bin/sh\necho admin\n' > "$ASK"; chmod 700 "$ASK"
SSHO=(-q -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5
      -o PreferredAuthentications=password,keyboard-interactive -o PubkeyAuthentication=no -o NumberOfPasswordPrompts=1)
ssh_() { SSH_ASKPASS="$ASK" SSH_ASKPASS_REQUIRE=force DISPLAY=:0 ssh "${SSHO[@]}" admin@"$IP" "$@" </dev/null; }
ssh_in() { SSH_ASKPASS="$ASK" SSH_ASKPASS_REQUIRE=force DISPLAY=:0 ssh "${SSHO[@]}" admin@"$IP" "$@"; }
for i in {1..60}; do ssh_ true 2>/dev/null && break; sleep 3; done

ssh_in 'bash -s' <<'EOS'
set -u
S="/Volumes/My Shared Files/share"
ui() { osascript -e "tell application \"System Events\" to $1" 2>&1; }
echo "macOS $(sw_vers -productVersion) ($(sw_vers -buildVersion))"

# 1. Install like a user: open the DMG, copy the app, keep the browser's quarantine flag.
M=$(hdiutil attach -nobrowse -readonly "$S/Backline.dmg" | awk -F'\t' '/Volumes/{print $NF}')
ditto "$M/Backline.app" /Applications/Backline.app
[ "$(cat "$S/no-quarantine")" = 1 ] || xattr -w com.apple.quarantine "0081;$(printf %x $(date +%s));Safari;$(uuidgen)" /Applications/Backline.app
hdiutil detach "$M" -quiet
echo "gatekeeper: $(spctl --assess --type execute -v /Applications/Backline.app 2>&1 | head -2 | tr '\n' ' ')"

# 2. First launch: macOS asks "downloaded from the Internet… Open?" — click Open, like a user.
open /Applications/Backline.app &
for i in $(seq 1 30); do
  if ui 'exists button "Open" of window 1 of process "CoreServicesUIAgent"' | grep -q true; then
    echo "first-launch prompt: $(ui 'get value of static text 1 of window 1 of process "CoreServicesUIAgent"' | cut -c1-70)…"
    ui 'click button "Open" of window 1 of process "CoreServicesUIAgent"' >/dev/null; break
  fi; sleep 1
done
sleep 8
pgrep -x Backline >/dev/null && echo "launch: OK" || echo "launch: FAILED"
echo "windows: $(ui 'get name of every window of process "Backline"')"
for i in 1 2 3 4 5; do ui 'keystroke return' >/dev/null; sleep 0.6; done   # welcome: "What do you practise?" + 3 cards
ui 'key code 53' >/dev/null

# 3. Add a song (same path as dragging a file onto Backline).
cp "$S/song.mp3" ~/Music/song.mp3
t0=$(date +%s)
open -a /Applications/Backline.app ~/Music/song.mp3
SONGS="$HOME/Library/Containers/com.alexpizarro.backline/Data/Library/Application Support/Backline/Songs"
for i in $(seq 1 300); do ls "$SONGS"/*/song.json >/dev/null 2>&1 && break; sleep 1; done
J=$(ls "$SONGS"/*/song.json 2>/dev/null | head -1)
if [ -n "$J" ]; then
  echo "split: OK in $(( $(date +%s) - t0 ))s → $(ls "$(dirname "$J")" | grep caf | tr '\n' ' ')"
  plutil -extract guitarSplit.method raw "$J" 2>/dev/null | sed 's/^/lead\/rhythm split: /'
else
  echo "split: FAILED (no song after 300 s)"
fi

# 4. Save a backing track: ⌘E → Save → Save in the macOS save panel.
ui 'tell process "Backline" to set frontmost to true' >/dev/null; sleep 1
ui 'keystroke "e" using command down' >/dev/null; sleep 2
ui 'keystroke return' >/dev/null; sleep 3
ui 'keystroke return' >/dev/null
for i in $(seq 1 90); do ls ~/Music/Backline/*.wav >/dev/null 2>&1 && break; sleep 1; done
f=$(ls ~/Music/Backline/*.wav 2>/dev/null | head -1)
[ -n "$f" ] && echo "saved: OK → $(basename "$f") ($(du -h "$f" | cut -f1), $(afinfo "$f" | awk '/estimated duration/{print $3"s"}'))" || echo "saved: FAILED"

# 5. YouTube link, the way a user adds one: copy the link, then File ▸ Paste YouTube Link (⇧⌘V).
#    (The downloader only runs inside Backline's sandbox, so it's tested through the app.)
before=$(ls "$SONGS" | wc -l | tr -d ' ')
printf 'https://youtu.be/2pXa5jzaOBg' | pbcopy
ui 'tell process "Backline" to set frontmost to true' >/dev/null; sleep 1
t0=$(date +%s)
ui 'keystroke "v" using {command down, shift down}' >/dev/null
for i in $(seq 1 300); do [ "$(ls "$SONGS"/*/song.json 2>/dev/null | wc -l | tr -d ' ')" -gt "$before" ] && break; sleep 1; done
if [ "$(ls "$SONGS"/*/song.json 2>/dev/null | wc -l | tr -d ' ')" -gt "$before" ]; then
  J=$(ls -t "$SONGS"/*/song.json | head -1)
  echo "youtube: OK in $(( $(date +%s) - t0 ))s → \"$(plutil -extract title raw "$J")\" ($(plutil -extract sourceName raw "$J"))"
else
  echo "youtube: FAILED — screen says: $(ui 'get value of every static text of window 1 of process "Backline"' | cut -c1-240)"
fi

# 6. 0.17: the extra models download by themselves, the cleaner pass re-splits the YouTube song, Beats
#    splits its drum kit, and Dance remembers the 1.
MODELS="$HOME/Library/Containers/com.alexpizarro.backline/Data/Library/Application Support/Backline/Models"
t0=$(date +%s)
for i in $(seq 1 240); do [ "$(ls "$MODELS"/*.sha256 2>/dev/null | wc -l | tr -d ' ')" -ge 2 ] && break; sleep 5; done
echo "models: $(ls "$MODELS"/*.sha256 2>/dev/null | wc -l | tr -d ' ') of 2 in $(( $(date +%s) - t0 ))s ($(du -sh "$MODELS" 2>/dev/null | cut -f1))"
J=$(ls -t "$SONGS"/*/song.json 2>/dev/null | head -1); D=$(dirname "$J")
t0=$(date +%s)
for i in $(seq 1 240); do [ "$(plutil -extract separator raw "$D/song.json" 2>/dev/null)" = "bs-roformer-sw" ] && break; sleep 5; done
echo "cleaner parts: $(plutil -extract separator raw "$D/song.json" 2>/dev/null || echo none) after $(( $(date +%s) - t0 ))s"
ui 'tell process "Backline" to set frontmost to true' >/dev/null; sleep 1
ui 'keystroke space' >/dev/null; sleep 3; ui 'keystroke space' >/dev/null; sleep 1   # play then pause, so new parts load
ui 'keystroke "3" using command down' >/dev/null
t0=$(date +%s)
for i in $(seq 1 180); do [ -f "$D/kick.caf" ] && plutil -extract drumSplit.method raw "$D/song.json" >/dev/null 2>&1 && break; sleep 5; done
echo "beats drum kit: $(plutil -extract drumSplit.method raw "$D/song.json" 2>/dev/null || echo none) after $(( $(date +%s) - t0 ))s; mode=$(plutil -extract settings.mode raw "$D/song.json" 2>/dev/null)"
ui 'keystroke "2" using command down' >/dev/null; sleep 1
ui 'keystroke space' >/dev/null; sleep 2.5; ui 'keystroke "o"' >/dev/null; sleep 1; ui 'keystroke space' >/dev/null; sleep 2
echo "dance: mode=$(plutil -extract settings.mode raw "$D/song.json" 2>/dev/null) one=$(plutil -extract settings.countOne raw "$D/song.json" 2>/dev/null || echo unset)"

pgrep -x Backline >/dev/null && echo "still running at the end: yes" || echo "still running at the end: NO"
ls ~/Library/Logs/DiagnosticReports 2>/dev/null | grep -i -E "backline|yt-dlp|qjs" || echo "crash reports: none"
EOS

kill $RUN 2>/dev/null; "$TART" stop "$VM" >/dev/null 2>&1; "$TART" delete "$VM" >/dev/null 2>&1
rm -rf "$SHARE"
